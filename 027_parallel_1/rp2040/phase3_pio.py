from array import array
from machine import Pin
from time import sleep_us, ticks_diff, ticks_us
import rp2
import shrike


# ===== bitstream =====
BITSTREAM = "shrike_parallel_burst_proto.bin"


# ===== Shrike-Lite基板内RP2040–FPGA接続 =====
# D[0] : RP2040 GP2  <-> FPGA GPIO03
# D[1] : RP2040 GP1  <-> FPGA GPIO04
# D[2] : RP2040 GP3  <-> FPGA GPIO05
# D[3] : RP2040 GP0  <-> FPGA GPIO06
# CLK  : RP2040 GP15  -> FPGA GPIO17
# REQ  : RP2040 GP14 <-  FPGA GPIO18
DATA_PIN_NUMBERS = (2, 1, 3, 0)
PIO_DATA_BASE_PIN_NUMBER = 0
CLK_PIN_NUMBER = 15
REQ_PIN_NUMBER = 14
SM_ID = 0


# ===== PIO通信タイミング =====
# TX:
#   pull(ifempty) Low -> out(pins, 4) Low -> nop High -> jmp High
#   データ設定からCLK立ち上がりまで1cycle、High 2cycle、Low 2cycle、
#   1ニブル4cycle。TX FIFO不足時は次のニブル前のpullでLow停止する。
# RX:
#   push(iffull) Low -> nop High -> in(pins, 4) High -> jmp Low
#   CLK立ち上がりの次cycleに取得、High 2cycle、Low 2cycle、
#   1ニブル4cycle。RX FIFO満杯時は次のクロック前のpushでLow停止する。
# Grant Clock:
#   nop High [1] -> nop Low [1] の4cycleで、返信データには数えない。
TX_CYCLES_PER_NIBBLE = 4
RX_CYCLES_PER_NIBBLE = 4
PIO_CYCLES_PER_NIBBLE = 4
GRANT_CYCLES = 4
PIO_INSTRUCTION_COUNT = 21

PARALLEL_CLK_HZ = 100_000
PIO_CLOCKS_HZ = (
    100_000,
    500_000,
    1_000_000,
    2_000_000,
    4_000_000,
)

# 最大長かつ100kHzの往復に十分な余裕を持たせる
REQ_ASSERT_TIMEOUT_US = 100_000
REQ_RELEASE_TIMEOUT_US = 100_000
REPLY_START_TIMEOUT_US = 100_000
RX_FIFO_TIMEOUT_US = 100_000
PIO_COMPLETE_TIMEOUT_US = 250_000
POLL_INTERVAL_US = 1


# ===== プロトコルと試験条件 =====
SOFT_RESET = 0x00
INVERT = 0x01
BURST_INVERT = 0x02
INVERT_TEST_VALUES = (0x00, 0x01, 0x0F, 0x10, 0x55, 0xAA, 0xFE, 0xFF)
LOOP_TEST_COUNT = 1000
BURST_LENGTHS = (1, 2, 31, 32, 255, 256)
MAX_BURST_LENGTH = 256
BURST_LOOP_COUNT = 1000
BURST_LOOP_LENGTH = 32
GPIO_BASELINE_TIME_US = 28_310_660


# ===== GPIO物理順変換 =====
# GP0=data[3], GP1=data[1], GP2=data[0], GP3=data[2]
logical_to_gpio = (
    0x0,
    0x4,
    0x2,
    0x6,
    0x8,
    0xC,
    0xA,
    0xE,
    0x1,
    0x5,
    0x3,
    0x7,
    0x9,
    0xD,
    0xB,
    0xF,
)
gpio_to_logical = (
    0x0,
    0x8,
    0x2,
    0xA,
    0x1,
    0x9,
    0x3,
    0xB,
    0x4,
    0xC,
    0x6,
    0xE,
    0x5,
    0xD,
    0x7,
    0xF,
)


# ===== PIO FIFO word =====
TX_NIBBLES_PER_WORD = 8
RX_NIBBLES_PER_WORD = 8
MAX_REQUEST_BYTES = MAX_BURST_LENGTH + 2
MAX_RESPONSE_BYTES = MAX_BURST_LENGTH + 1
MAX_TX_NIBBLES = MAX_REQUEST_BYTES * 2
MAX_RX_NIBBLES = MAX_RESPONSE_BYTES * 2
MAX_TX_DATA_WORDS = (MAX_TX_NIBBLES + TX_NIBBLES_PER_WORD - 1) // TX_NIBBLES_PER_WORD
MAX_RX_DATA_WORDS = (MAX_RX_NIBBLES + RX_NIBBLES_PER_WORD - 1) // RX_NIBBLES_PER_WORD
TX_CONTROL_WORDS = 2
TX_WORD_BUFFER_COUNT = TX_CONTROL_WORDS + MAX_TX_DATA_WORDS
RX_COMPLETION_WORDS = 1
RX_WORD_BUFFER_COUNT = MAX_RX_DATA_WORDS + RX_COMPLETION_WORDS
COMPLETION_MARKER = 0xFFFFFFFF
PIO_FIFO_DEPTH = 4
PULL_NOBLOCK_INSTRUCTION = rp2.asm_pio_encode("pull(noblock)", 0)


class ProtocolTimeout(Exception):
    pass


class ProtocolError(Exception):
    pass


# SHIFT_RIGHTでは最初のTXニブルをword[3:0]へ置く。
# RXの完全wordも最初のニブルがword[3:0]になる。端数RX wordだけは
# ISR上位側へ寄るため、Python側で有効ニブル数に応じて位置を補正する。
@rp2.asm_pio(
    out_init=(
        rp2.PIO.IN_LOW,
        rp2.PIO.IN_LOW,
        rp2.PIO.IN_LOW,
        rp2.PIO.IN_LOW,
    ),
    set_init=(
        rp2.PIO.IN_LOW,
        rp2.PIO.IN_LOW,
        rp2.PIO.IN_LOW,
        rp2.PIO.IN_LOW,
    ),
    sideset_init=rp2.PIO.OUT_LOW,
    in_shiftdir=rp2.PIO.SHIFT_RIGHT,
    out_shiftdir=rp2.PIO.SHIFT_RIGHT,
    autopush=False,
    autopull=False,
    push_thresh=32,
    pull_thresh=32,
    fifo_join=rp2.PIO.JOIN_NONE,
)
def parallel_burst_transaction():
    wrap_target()

    # 制御word 0: 要求ニブル数-1
    pull(block).side(0)
    out(x, 32).side(0)

    # 制御word 1: 返信ニブル数-1
    pull(block).side(0)
    out(y, 32).side(0)

    # FPGAがHi-ZかつREQ LowであることをPython側で確認してから出力化する
    set(pindirs, 0b1111).side(0)

    label("tx_nibble")
    # OSRが空のときだけpullし、TX不足なら次のニブル前にCLK Lowで停止する
    pull(ifempty, block).side(0)
    out(pins, 4).side(0)
    nop().side(1)
    jmp(x_dec, "tx_nibble").side(1)

    # 要求送信完了後、CLK LowにしてRP2040側を先にHi-Zへ戻す
    set(pindirs, 0b0000).side(0)

    # WAIT GPIOは絶対GPIO番号。待機中もCLK Lowを維持する
    wait(1, gpio, 14).side(0)

    # Grant ClockはHigh 2cycle、Low 2cycleの1パルス
    nop().side(1)[1]
    nop().side(0)[1]

    label("rx_nibble")
    # 前wordが32bitなら先にpushし、満杯時は次のCLK前にLowで停止する
    push(iffull, block).side(0)
    nop().side(1)
    in_(pins, 4).side(1)
    jmp(y_dec, "rx_nibble").side(0)

    # 完全32bit境界と端数wordのどちらも、最終data wordをここで1回だけpushする
    push(block).side(0)
    set(pindirs, 0b0000).side(0)

    # data wordとは別の完了markerをpushし、Pythonが受け取るまでCLK Lowを維持する
    mov(isr, invert(null)).side(0)
    push(block).side(0)
    wrap()


data_pins = ()
clk_pin = None
req_pin = None
sm = None
current_parallel_clk_hz = PARALLEL_CLK_HZ
current_pio_sm_freq_hz = PARALLEL_CLK_HZ * PIO_CYCLES_PER_NIBBLE
data_bus_input_software_state = False

# ループごとの大きな割り当てを避けるため、最大長バッファを再利用する
burst_tx = bytearray(MAX_BURST_LENGTH)
burst_expected = bytearray(MAX_BURST_LENGTH)
request_buffer = bytearray(MAX_REQUEST_BYTES)
response_buffer = bytearray(MAX_RESPONSE_BYTES)
response_raw_gpio_nibbles = bytearray(MAX_RX_NIBBLES)
tx_words = array("I", [0] * TX_WORD_BUFFER_COUNT)
rx_words = array("I", [0] * RX_WORD_BUFFER_COUNT)


def program_fpga():
    """指定bitstreamをFPGAへ書き込む。"""
    shrike.reset()
    shrike.flash(BITSTREAM)


def initialize_bus():
    """構成用端子を解放し、通信バスを安全な初期状態にする。"""
    global data_pins, clk_pin, req_pin, sm

    # 共有データ端子はまず入力として解放する
    data_pins = tuple(Pin(number, Pin.IN) for number in DATA_PIN_NUMBERS)

    # RP2040がクロックマスター。アイドル時は必ずLow
    clk_pin = Pin(CLK_PIN_NUMBER, Pin.OUT, value=0)

    # REQはFPGAだけが駆動する
    req_pin = Pin(REQ_PIN_NUMBER, Pin.IN)
    sm = rp2.StateMachine(SM_ID)
    force_safe_gpio()


def force_safe_gpio():
    """SM停止後にSIOからCLK Low・data入力を明示的に保証する。"""
    global data_bus_input_software_state

    if clk_pin is not None:
        clk_pin.init(Pin.OUT, value=0)
    for pin in data_pins:
        pin.init(Pin.IN)
    data_bus_input_software_state = True


def wait_req_level(level, timeout_us, context):
    """REQが指定レベルになるまでwraparound安全に待つ。"""
    start = ticks_us()
    while req_pin.value() != level:
        if ticks_diff(ticks_us(), start) >= timeout_us:
            raise ProtocolTimeout(context)
        sleep_us(POLL_INTERVAL_US)


def drain_state_machine_fifos():
    """残存RXをgetし、残存TXをnonblocking PULLで破棄する。"""
    if sm is None:
        return

    # rx_fifo()確認後のget()は、他にreaderがいないためblockingしない
    while sm.rx_fifo() > 0:
        sm.get()

    # TX FIFOにはread APIがないため、停止中SMへnonblocking PULLを実行する
    while sm.tx_fifo() > 0:
        sm.exec(PULL_NOBLOCK_INSTRUCTION)


def stop_state_machine_safely():
    """SMを停止し、物理ピンを安全化してFIFOとシフト状態を掃除する。"""
    if sm is None:
        force_safe_gpio()
        return

    sm.active(0)
    force_safe_gpio()
    drain_state_machine_fifos()
    # restart()はFIFO、X、Y、OSRを消す前提にはしない。
    # ISRとshift counterをクリアし、次回は再init後にX/Y/OSRを上書きする。
    sm.restart()


def init_state_machine(parallel_clk_hz):
    """トランザクションごとに同じプログラムと安全な初期pin状態で再initする。"""
    global current_parallel_clk_hz, current_pio_sm_freq_hz
    global data_bus_input_software_state

    current_parallel_clk_hz = parallel_clk_hz
    current_pio_sm_freq_hz = parallel_clk_hz * PIO_CYCLES_PER_NIBBLE

    sm.active(0)
    force_safe_gpio()
    drain_state_machine_fifos()
    sm.restart()
    sm.init(
        parallel_burst_transaction,
        freq=current_pio_sm_freq_hz,
        in_base=Pin(PIO_DATA_BASE_PIN_NUMBER),
        out_base=Pin(PIO_DATA_BASE_PIN_NUMBER),
        set_base=Pin(PIO_DATA_BASE_PIN_NUMBER),
        sideset_base=Pin(CLK_PIN_NUMBER),
    )
    sm.restart()
    data_bus_input_software_state = True


def pack_tx_words(request_bytes, request_length, response_length):
    """制御2wordと、物理GPIO順へ変換した8ニブル/wordの要求を作る。"""
    request_nibble_count = request_length * 2
    response_nibble_count = response_length * 2
    data_word_count = (
        request_nibble_count + TX_NIBBLES_PER_WORD - 1
    ) // TX_NIBBLES_PER_WORD

    if request_nibble_count < 1 or request_nibble_count > MAX_TX_NIBBLES:
        raise ValueError("要求ニブル数が範囲外")
    if response_nibble_count < 1 or response_nibble_count > MAX_RX_NIBBLES:
        raise ValueError("返信ニブル数が範囲外")

    # JMP X--/Y--は初期値0で1回実行するため、ニブル数-1を渡す
    tx_words[0] = request_nibble_count - 1
    tx_words[1] = response_nibble_count - 1

    for word_index in range(data_word_count):
        tx_words[TX_CONTROL_WORDS + word_index] = 0

    for nibble_index in range(request_nibble_count):
        byte_value = request_bytes[nibble_index >> 1]
        if nibble_index & 1:
            logical_nibble = byte_value & 0x0F
        else:
            logical_nibble = (byte_value >> 4) & 0x0F

        gpio_nibble = logical_to_gpio[logical_nibble]
        word_index = nibble_index // TX_NIBBLES_PER_WORD
        word_nibble_index = nibble_index & (TX_NIBBLES_PER_WORD - 1)
        tx_words[TX_CONTROL_WORDS + word_index] |= (
            gpio_nibble << (word_nibble_index * 4)
        )

    return TX_CONTROL_WORDS + data_word_count, data_word_count, request_nibble_count


def unpack_rx_words(response_bytes, response_length):
    """SHIFT_RIGHTのRX wordを物理順から論理順へ戻し、byteへ結合する。"""
    response_nibble_count = response_length * 2
    data_word_count = (
        response_nibble_count + RX_NIBBLES_PER_WORD - 1
    ) // RX_NIBBLES_PER_WORD

    for nibble_index in range(response_nibble_count):
        word_index = nibble_index // RX_NIBBLES_PER_WORD
        word_nibble_index = nibble_index & (RX_NIBBLES_PER_WORD - 1)
        remaining = response_nibble_count - word_index * RX_NIBBLES_PER_WORD
        valid_nibbles = (
            RX_NIBBLES_PER_WORD
            if remaining >= RX_NIBBLES_PER_WORD
            else remaining
        )

        # SHIFT_RIGHTの端数wordは有効ニブルがISR上位側へ寄っている
        if valid_nibbles == RX_NIBBLES_PER_WORD:
            shift = word_nibble_index * 4
        else:
            shift = (RX_NIBBLES_PER_WORD - valid_nibbles + word_nibble_index) * 4

        gpio_nibble = (rx_words[word_index] >> shift) & 0x0F
        logical_nibble = gpio_to_logical[gpio_nibble]
        response_raw_gpio_nibbles[nibble_index] = gpio_nibble

        byte_index = nibble_index >> 1
        if nibble_index & 1:
            response_bytes[byte_index] |= logical_nibble
        else:
            response_bytes[byte_index] = logical_nibble << 4

    return data_word_count


def _selftest_build_rx_words(response_length):
    """ローカル自己試験用に、PIO SHIFT_RIGHTと同じRX配置を作る。"""
    response_nibble_count = response_length * 2
    data_word_count = (
        response_nibble_count + RX_NIBBLES_PER_WORD - 1
    ) // RX_NIBBLES_PER_WORD

    for word_index in range(data_word_count):
        rx_words[word_index] = 0
        first_nibble = word_index * RX_NIBBLES_PER_WORD
        remaining = response_nibble_count - first_nibble
        valid_nibbles = (
            RX_NIBBLES_PER_WORD
            if remaining >= RX_NIBBLES_PER_WORD
            else remaining
        )

        for word_nibble_index in range(valid_nibbles):
            nibble_index = first_nibble + word_nibble_index
            byte_value = response_buffer[nibble_index >> 1]
            if nibble_index & 1:
                logical_nibble = byte_value & 0x0F
            else:
                logical_nibble = (byte_value >> 4) & 0x0F
            gpio_nibble = logical_to_gpio[logical_nibble]

            if valid_nibbles == RX_NIBBLES_PER_WORD:
                shift = word_nibble_index * 4
            else:
                shift = (
                    RX_NIBBLES_PER_WORD - valid_nibbles + word_nibble_index
                ) * 4
            rx_words[word_index] |= gpio_nibble << shift

    return data_word_count


def run_local_self_tests(print_result=True):
    """実機不要のnibble変換、packet長、word境界、最大長自己試験。"""
    for logical_nibble in range(16):
        gpio_nibble = logical_to_gpio[logical_nibble]
        if gpio_to_logical[gpio_nibble] != logical_nibble:
            raise AssertionError("nibble相互変換失敗")

    request_lengths = (1, 2, 4, 31, 32, 255, 256, 258)
    for request_length in request_lengths:
        for index in range(request_length):
            request_buffer[index] = (index * 37 + request_length) & 0xFF

        total_words, data_words, nibble_count = pack_tx_words(
            request_buffer, request_length, 1
        )
        expected_data_words = (
            nibble_count + TX_NIBBLES_PER_WORD - 1
        ) // TX_NIBBLES_PER_WORD
        if data_words != expected_data_words:
            raise AssertionError("TX data word数失敗")
        if total_words != TX_CONTROL_WORDS + expected_data_words:
            raise AssertionError("TX制御word加算失敗")

        for nibble_index in range(nibble_count):
            word_index = nibble_index // TX_NIBBLES_PER_WORD
            word_nibble_index = nibble_index & (TX_NIBBLES_PER_WORD - 1)
            gpio_nibble = (
                tx_words[TX_CONTROL_WORDS + word_index]
                >> (word_nibble_index * 4)
            ) & 0x0F
            logical_nibble = gpio_to_logical[gpio_nibble]
            byte_value = request_buffer[nibble_index >> 1]
            expected_nibble = (
                byte_value & 0x0F
                if nibble_index & 1
                else (byte_value >> 4) & 0x0F
            )
            if logical_nibble != expected_nibble:
                raise AssertionError("TX pack順序失敗")

    response_lengths = (1, 2, 4, 31, 32, 255, 256, 257)
    for response_length in response_lengths:
        for index in range(response_length):
            response_buffer[index] = (index * 53 + response_length) & 0xFF

        data_words = _selftest_build_rx_words(response_length)
        unpack_rx_words(response_buffer, response_length)
        expected_words = (
            response_length * 2 + RX_NIBBLES_PER_WORD - 1
        ) // RX_NIBBLES_PER_WORD
        if data_words != expected_words:
            raise AssertionError("RX data word数失敗")

        for index in range(response_length):
            expected_value = (index * 53 + response_length) & 0xFF
            if response_buffer[index] != expected_value:
                raise AssertionError("RX unpack順序失敗")

    if MAX_TX_NIBBLES != 516 or MAX_TX_DATA_WORDS != 65:
        raise AssertionError("最大TX境界失敗")
    if MAX_RX_NIBBLES != 514 or MAX_RX_DATA_WORDS != 65:
        raise AssertionError("最大RX境界失敗")
    if TX_WORD_BUFFER_COUNT != 67 or RX_WORD_BUFFER_COUNT != 66:
        raise AssertionError("制御word/marker領域失敗")

    if print_result:
        print(
            "SELFTEST NIBBLE_CONVERSION=PASS PACKET_WORD_BOUNDARY=PASS "
            "TX_MAX_NIBBLES=516 TX_MAX_DATA_WORDS=65 "
            "RX_MAX_NIBBLES=514 RX_MAX_DATA_WORDS=65 "
            "TX_BUFFER_WORDS=67 RX_BUFFER_WORDS=66 PASS"
        )
    return True


def _prefill_tx_fifo(total_tx_word_count):
    """SM停止中に4wordまで先行投入し、残りの先頭indexを返す。"""
    tx_index = 0
    while (
        tx_index < total_tx_word_count
        and sm.tx_fifo() < PIO_FIFO_DEPTH
    ):
        sm.put(int(tx_words[tx_index]))
        tx_index += 1
    return tx_index


def _service_transaction(total_tx_word_count, rx_data_word_count):
    """FIFOをpollし、timeout可能な1word単位put/getで完了markerまで処理する。"""
    tx_index = _prefill_tx_fifo(total_tx_word_count)
    rx_index = 0
    completion_seen = False
    req_high_seen = False
    start = ticks_us()
    reply_start = start
    last_rx = start

    sm.active(1)

    while not completion_seen:
        progressed = False

        if (
            tx_index < total_tx_word_count
            and sm.tx_fifo() < PIO_FIFO_DEPTH
        ):
            # 空き確認後はSMが消費する側なので、この1word putはblockingしない
            sm.put(int(tx_words[tx_index]))
            tx_index += 1
            progressed = True

        if req_pin.value() == 1 and not req_high_seen:
            req_high_seen = True
            reply_start = ticks_us()

        if sm.rx_fifo() > 0:
            # 残量確認後は他にreaderがいないため、このgetはblockingしない
            word = sm.get()
            now = ticks_us()
            last_rx = now
            progressed = True
            req_high_seen = True

            if rx_index < rx_data_word_count:
                rx_words[rx_index] = word
                rx_index += 1
            else:
                rx_words[rx_data_word_count] = word
                if word != COMPLETION_MARKER:
                    raise ProtocolError(
                        "PIO完了marker不一致: 0x{:08X}".format(word)
                    )
                completion_seen = True

        now = ticks_us()
        elapsed = ticks_diff(now, start)

        if (
            not req_high_seen
            and tx_index >= total_tx_word_count
            and elapsed >= REQ_ASSERT_TIMEOUT_US
        ):
            raise ProtocolTimeout("FPGAのREQ High待ちタイムアウト")

        if (
            req_high_seen
            and rx_index == 0
            and ticks_diff(now, reply_start) >= REPLY_START_TIMEOUT_US
        ):
            raise ProtocolTimeout("RX FIFO先頭word待ちタイムアウト")

        if (
            req_high_seen
            and not completion_seen
            and ticks_diff(now, last_rx) >= RX_FIFO_TIMEOUT_US
        ):
            raise ProtocolTimeout("RX FIFOデータ待ちタイムアウト")

        if elapsed >= PIO_COMPLETE_TIMEOUT_US:
            raise ProtocolTimeout("PIOトランザクション完了待ちタイムアウト")

        if not progressed:
            sleep_us(POLL_INTERVAL_US)

    if tx_index != total_tx_word_count:
        raise ProtocolError("PIO完了時に未投入TX wordが残存")
    if rx_index != rx_data_word_count:
        raise ProtocolError("PIO完了時のRX data word数不一致")


def transfer(request_bytes, request_length, response_bytes, response_length):
    """固定長要求をPIO送信し、応答を事前確保バッファへ受信する。"""
    total_tx_words, _, _ = pack_tx_words(
        request_bytes, request_length, response_length
    )
    response_nibble_count = response_length * 2
    rx_data_word_count = (
        response_nibble_count + RX_NIBBLES_PER_WORD - 1
    ) // RX_NIBBLES_PER_WORD

    transfer_error = None
    try:
        # FPGAが前回バスを解放済みであることをSM開始前に確認する
        wait_req_level(
            0,
            REQ_RELEASE_TIMEOUT_US,
            "SM開始前REQ Low待ちタイムアウト",
        )
        init_state_machine(current_parallel_clk_hz)
        _service_transaction(total_tx_words, rx_data_word_count)
        unpack_rx_words(response_bytes, response_length)
    except Exception as caught:
        transfer_error = caught
    finally:
        # 成否にかかわらずSM停止、CLK Low、data入力、FIFO破棄を実行する
        try:
            stop_state_machine_safely()
        except Exception as cleanup_error:
            if transfer_error is None:
                transfer_error = cleanup_error
            else:
                print(
                    "RECOVERY_ERROR ORIGINAL={} CLEANUP={}".format(
                        format_error(transfer_error),
                        format_error(cleanup_error),
                    )
                )

    if transfer_error is not None:
        raise transfer_error

    # 最終返信ニブル後のFPGA側OE/REQ解放を確認する
    wait_req_level(0, REQ_RELEASE_TIMEOUT_US, "FPGAのREQ Low待ちタイムアウト")


def format_byte(value):
    if value is None:
        return "--"
    return "0x{:02X}".format(value)


def format_error(error):
    if error is None:
        return "NONE"
    return "{}: {}".format(type(error).__name__, error)


def mismatch_nibble_fields(response_byte_index):
    """不一致byteの上位/下位についてraw GPIO順とlogical値を返す。"""
    high_index = response_byte_index * 2
    low_index = high_index + 1
    raw_high = response_raw_gpio_nibbles[high_index]
    raw_low = response_raw_gpio_nibbles[low_index]
    return (
        raw_high,
        gpio_to_logical[raw_high],
        raw_low,
        gpio_to_logical[raw_low],
    )


def print_mismatch(packet_index, byte_index, tx_value, rx_value, expected_value):
    """bit順不具合を切り分けられる不一致ログを表示する。"""
    raw_high, logical_high, raw_low, logical_low = mismatch_nibble_fields(
        byte_index + 1
    )
    print(
        "PACKET_INDEX={} BYTE_INDEX={} TX={} RX={} EXPECT={} "
        "RAW_GPIO_NIBBLE=0x{:X} LOGICAL_NIBBLE=0x{:X} "
        "RAW_GPIO_NIBBLE_LOW=0x{:X} LOGICAL_NIBBLE_LOW=0x{:X} "
        "PARALLEL_CLK_HZ={}".format(
            packet_index,
            byte_index,
            format_byte(tx_value),
            format_byte(rx_value),
            format_byte(expected_value),
            raw_high,
            logical_high,
            raw_low,
            logical_low,
            current_parallel_clk_hz,
        )
    )


def run_soft_reset_test():
    start = ticks_us()
    status = None
    error = None

    try:
        request_buffer[0] = SOFT_RESET
        transfer(request_buffer, 1, response_buffer, 1)
        status = response_buffer[0]
    except Exception as caught:
        error = caught

    elapsed = ticks_diff(ticks_us(), start)
    passed = error is None and status == 0x00
    print(
        "MODE=PIO COMMAND=SOFT_RESET TX=0x00 RX={} EXPECT=0x00 "
        "STATUS={} PASS={} TIME_US={} PARALLEL_CLK_HZ={}".format(
            format_byte(status),
            format_byte(status),
            "PASS" if passed else "FAIL",
            elapsed,
            current_parallel_clk_hz,
        )
    )
    if error is not None:
        print("ERROR COMMAND=SOFT_RESET DETAIL={}".format(format_error(error)))
    return passed


def run_invert_test(value, print_result=True, packet_index="INVERT"):
    start = ticks_us()
    status = None
    result = None
    error = None

    try:
        request_buffer[0] = INVERT
        request_buffer[1] = value
        transfer(request_buffer, 2, response_buffer, 2)
        status = response_buffer[0]
        result = response_buffer[1]
    except Exception as caught:
        error = caught

    expected = value ^ 0xFF
    elapsed = ticks_diff(ticks_us(), start)
    passed = error is None and status == 0x00 and result == expected

    if print_result:
        print(
            "MODE=PIO COMMAND=INVERT TX={} RX={} EXPECT={} STATUS={} "
            "PASS={} TIME_US={} PARALLEL_CLK_HZ={}".format(
                format_byte(value),
                format_byte(result),
                format_byte(expected),
                format_byte(status),
                "PASS" if passed else "FAIL",
                elapsed,
                current_parallel_clk_hz,
            )
        )
        if error is not None:
            print(
                "ERROR COMMAND=INVERT TX={} DETAIL={}".format(
                    format_byte(value), format_error(error)
                )
            )
    if not passed and error is None and result is not None:
        print_mismatch(packet_index, 0, value, result, expected)

    return passed, error


def run_loop_test():
    """Phase 1互換のINVERT 1000回連続試験を維持する。"""
    start = ticks_us()
    loop_pass = 0
    loop_fail = 0
    loop_count = 0

    for index in range(LOOP_TEST_COUNT):
        value = index & 0xFF
        passed, error = run_invert_test(
            value,
            print_result=False,
            packet_index=index,
        )
        loop_count += 1
        if passed:
            loop_pass += 1
        else:
            loop_fail += 1
            print(
                "LOOP_ERROR INDEX={} TX={} DETAIL={} PARALLEL_CLK_HZ={}".format(
                    index,
                    format_byte(value),
                    format_error(error),
                    current_parallel_clk_hz,
                )
            )
            # 最初の失敗で同一周波数の連続試験も停止する
            break

    elapsed = ticks_diff(ticks_us(), start)
    print(
        "LOOP COUNT={} PASS={} FAIL={} TIME_US={} PARALLEL_CLK_HZ={}".format(
            loop_count,
            loop_pass,
            loop_fail,
            elapsed,
            current_parallel_clk_hz,
        )
    )
    return loop_count, loop_pass, loop_fail


def transfer_burst(length):
    """準備済みのburst_txをLength Code付きで送信する。"""
    if length < 1 or length > MAX_BURST_LENGTH:
        raise ValueError("バースト長は1～256byte")

    request_buffer[0] = BURST_INVERT
    request_buffer[1] = 0x00 if length == MAX_BURST_LENGTH else length
    for index in range(length):
        request_buffer[index + 2] = burst_tx[index]

    transfer(request_buffer, length + 2, response_buffer, length + 1)


def run_burst_test(length):
    """固定パターンのBURST_INVERTを実行し、全byteを照合する。"""
    start = ticks_us()
    status = None
    error = None
    first_mismatch = None

    for index in range(length):
        value = index & 0xFF
        burst_tx[index] = value
        burst_expected[index] = value ^ 0xFF

    try:
        transfer_burst(length)
        status = response_buffer[0]

        # 最初の不一致を記録した後も、残りを含む全byteを照合する
        for index in range(length):
            if (
                response_buffer[index + 1] != burst_expected[index]
                and first_mismatch is None
            ):
                first_mismatch = index
    except Exception as caught:
        error = caught

    elapsed = ticks_diff(ticks_us(), start)
    data_ok = error is None and first_mismatch is None
    passed = data_ok and status == 0x00

    print(
        "MODE=PIO PIO_SM_FREQ_HZ={} PIO_CYCLES_PER_NIBBLE={} "
        "COMMAND=BURST_INVERT LENGTH={} STATUS={} DATA_OK={} "
        "FIRST_MISMATCH={} PASS={} TIME_US={} PARALLEL_CLK_HZ={}".format(
            current_pio_sm_freq_hz,
            PIO_CYCLES_PER_NIBBLE,
            length,
            format_byte(status),
            "PASS" if data_ok else "FAIL",
            "NONE" if first_mismatch is None else first_mismatch,
            "PASS" if passed else "FAIL",
            elapsed,
            current_parallel_clk_hz,
        )
    )

    if first_mismatch is not None:
        print_mismatch(
            "FIXED",
            first_mismatch,
            burst_tx[first_mismatch],
            response_buffer[first_mismatch + 1],
            burst_expected[first_mismatch],
        )
    if error is not None:
        print(
            "ERROR COMMAND=BURST_INVERT LENGTH={} DETAIL={}".format(
                length, format_error(error)
            )
        )

    return passed, error


def run_burst_loop_test():
    """32byteのBURST_INVERTを1000パケット連続実行する。"""
    start = ticks_us()
    loop_count = 0
    loop_pass = 0
    loop_fail = 0

    for packet_index in range(BURST_LOOP_COUNT):
        status = None
        error = None
        first_mismatch = None

        for index in range(BURST_LOOP_LENGTH):
            value = (packet_index + index) & 0xFF
            burst_tx[index] = value
            burst_expected[index] = value ^ 0xFF

        try:
            transfer_burst(BURST_LOOP_LENGTH)
            status = response_buffer[0]

            # 連続試験でも毎回32byteすべてを照合する
            for index in range(BURST_LOOP_LENGTH):
                if (
                    response_buffer[index + 1] != burst_expected[index]
                    and first_mismatch is None
                ):
                    first_mismatch = index
        except Exception as caught:
            error = caught

        loop_count += 1
        passed = error is None and status == 0x00 and first_mismatch is None
        if passed:
            loop_pass += 1
        else:
            loop_fail += 1
            if first_mismatch is not None:
                print_mismatch(
                    packet_index,
                    first_mismatch,
                    burst_tx[first_mismatch],
                    response_buffer[first_mismatch + 1],
                    burst_expected[first_mismatch],
                )
            elif error is None:
                print(
                    "BURST_LOOP_ERROR PACKET_INDEX={} STATUS={} "
                    "PARALLEL_CLK_HZ={}".format(
                        packet_index,
                        format_byte(status),
                        current_parallel_clk_hz,
                    )
                )

            if error is not None:
                print(
                    "BURST_LOOP_ERROR PACKET_INDEX={} DETAIL={} "
                    "PARALLEL_CLK_HZ={}".format(
                        packet_index,
                        format_error(error),
                        current_parallel_clk_hz,
                    )
                )
            # 最初の失敗で同一周波数の連続試験を停止する
            break

    elapsed = ticks_diff(ticks_us(), start)
    print(
        "BURST_LOOP COUNT={} PASS={} FAIL={} TIME_US={} "
        "PARALLEL_CLK_HZ={}".format(
            loop_count,
            loop_pass,
            loop_fail,
            elapsed,
            current_parallel_clk_hz,
        )
    )
    return loop_count, loop_pass, loop_fail, elapsed


def check_idle_state():
    """通信終了後のREQ Low、CLK Low、data入力設定を確認する。"""
    req_low = req_pin.value() == 0
    clk_low = clk_pin.value() == 0
    data_input = data_bus_input_software_state
    passed = req_low and clk_low and data_input
    print(
        "IDLE_CHECK PARALLEL_CLK_HZ={} REQ_LOW={} CLK_LOW={} "
        "DATA_INPUT_SW={} DATA_INPUT_WAVEFORM=VERIFY PASS={}".format(
            current_parallel_clk_hz,
            "PASS" if req_low else "FAIL",
            "PASS" if clk_low else "FAIL",
            "PASS" if data_input else "FAIL",
            "PASS" if passed else "FAIL",
        )
    )
    return passed


def print_frequency_summary(
    suite_pass,
    soft_reset_pass,
    invert_pass,
    invert_fail,
    loop_count,
    loop_pass,
    loop_fail,
    burst_pass,
    burst_fail,
    burst_loop_count,
    burst_loop_pass,
    burst_loop_fail,
    burst_loop_time_us,
):
    """SPECの式でthroughputと通常GPIO版比を計算してSUMMARY表示する。"""
    if burst_loop_time_us > 0 and burst_loop_count > 0:
        wire_bytes_per_packet = 3 + 2 * BURST_LOOP_LENGTH
        wire_bps = (
            wire_bytes_per_packet
            * burst_loop_count
            * 1_000_000
            // burst_loop_time_us
        )
        payload_bps = (
            2
            * BURST_LOOP_LENGTH
            * burst_loop_count
            * 1_000_000
            // burst_loop_time_us
        )
        us_per_packet = burst_loop_time_us / burst_loop_count
        speedup = GPIO_BASELINE_TIME_US / burst_loop_time_us
    else:
        wire_bps = 0
        payload_bps = 0
        us_per_packet = 0
        speedup = 0

    print(
        "SUMMARY MODE=PIO BITSTREAM={} PARALLEL_CLK_HZ={} "
        "PIO_SM_FREQ_HZ={} PIO_CYCLES_PER_NIBBLE={} "
        "TX_CYCLES_PER_NIBBLE={} RX_CYCLES_PER_NIBBLE={} "
        "SOFT_RESET={} INVERT_PASS={} INVERT_FAIL={} "
        "LOOP_COUNT={} LOOP_PASS={} LOOP_FAIL={} "
        "BURST_PASS={} BURST_FAIL={} BURST_LOOP_COUNT={} "
        "BURST_LOOP_TARGET={} BURST_LOOP_LENGTH={} "
        "BURST_LOOP_PASS={} BURST_LOOP_FAIL={} TIME_US={} "
        "US_PER_PACKET={:.3f} WIRE_BPS={} PAYLOAD_BPS={} "
        "SPEEDUP_VS_GPIO={:.3f} {}".format(
            BITSTREAM,
            current_parallel_clk_hz,
            current_pio_sm_freq_hz,
            PIO_CYCLES_PER_NIBBLE,
            TX_CYCLES_PER_NIBBLE,
            RX_CYCLES_PER_NIBBLE,
            "PASS" if soft_reset_pass else "FAIL",
            invert_pass,
            invert_fail,
            loop_count,
            loop_pass,
            loop_fail,
            burst_pass,
            burst_fail,
            burst_loop_count,
            BURST_LOOP_COUNT,
            BURST_LOOP_LENGTH,
            burst_loop_pass,
            burst_loop_fail,
            burst_loop_time_us,
            us_per_packet,
            wire_bps,
            payload_bps,
            speedup,
            "PASS" if suite_pass else "FAIL",
        )
    )


def run_frequency_suite(parallel_clk_hz):
    """1周波数分を実行し、最初の失敗で同周波数の残りも停止する。"""
    init_state_machine(parallel_clk_hz)
    print(
        "CONFIG MODE=PIO BITSTREAM={} DATA_PINS={} CLK_PIN={} REQ_PIN={} "
        "SM_ID={} PARALLEL_CLK_HZ={} PIO_SM_FREQ_HZ={} "
        "PIO_CYCLES_PER_NIBBLE={} TX_CYCLES_PER_NIBBLE={} "
        "RX_CYCLES_PER_NIBBLE={} PIO_INSTRUCTION_COUNT={}".format(
            BITSTREAM,
            DATA_PIN_NUMBERS,
            CLK_PIN_NUMBER,
            REQ_PIN_NUMBER,
            SM_ID,
            current_parallel_clk_hz,
            current_pio_sm_freq_hz,
            PIO_CYCLES_PER_NIBBLE,
            TX_CYCLES_PER_NIBBLE,
            RX_CYCLES_PER_NIBBLE,
            PIO_INSTRUCTION_COUNT,
        )
    )

    soft_reset_pass = False
    invert_pass = 0
    invert_fail = 0
    loop_count = 0
    loop_pass = 0
    loop_fail = 0
    burst_pass = 0
    burst_fail = 0
    burst_loop_count = 0
    burst_loop_pass = 0
    burst_loop_fail = 0
    burst_loop_time_us = 0
    suite_pass = False

    soft_reset_pass = run_soft_reset_test()
    if not soft_reset_pass:
        print_frequency_summary(
            False,
            soft_reset_pass,
            invert_pass,
            invert_fail,
            loop_count,
            loop_pass,
            loop_fail,
            burst_pass,
            burst_fail,
            burst_loop_count,
            burst_loop_pass,
            burst_loop_fail,
            burst_loop_time_us,
        )
        return False

    for value in INVERT_TEST_VALUES:
        passed, _ = run_invert_test(value)
        if passed:
            invert_pass += 1
        else:
            invert_fail += 1
            break
    if invert_fail:
        print_frequency_summary(
            False,
            soft_reset_pass,
            invert_pass,
            invert_fail,
            loop_count,
            loop_pass,
            loop_fail,
            burst_pass,
            burst_fail,
            burst_loop_count,
            burst_loop_pass,
            burst_loop_fail,
            burst_loop_time_us,
        )
        return False

    loop_count, loop_pass, loop_fail = run_loop_test()
    if loop_count != LOOP_TEST_COUNT or loop_fail:
        print_frequency_summary(
            False,
            soft_reset_pass,
            invert_pass,
            invert_fail,
            loop_count,
            loop_pass,
            loop_fail,
            burst_pass,
            burst_fail,
            burst_loop_count,
            burst_loop_pass,
            burst_loop_fail,
            burst_loop_time_us,
        )
        return False

    for length in BURST_LENGTHS:
        passed, _ = run_burst_test(length)
        if passed:
            burst_pass += 1
        else:
            burst_fail += 1
            break
    if burst_fail:
        print_frequency_summary(
            False,
            soft_reset_pass,
            invert_pass,
            invert_fail,
            loop_count,
            loop_pass,
            loop_fail,
            burst_pass,
            burst_fail,
            burst_loop_count,
            burst_loop_pass,
            burst_loop_fail,
            burst_loop_time_us,
        )
        return False

    (
        burst_loop_count,
        burst_loop_pass,
        burst_loop_fail,
        burst_loop_time_us,
    ) = run_burst_loop_test()
    if (
        burst_loop_count != BURST_LOOP_COUNT
        or burst_loop_fail
        or not check_idle_state()
    ):
        print_frequency_summary(
            False,
            soft_reset_pass,
            invert_pass,
            invert_fail,
            loop_count,
            loop_pass,
            loop_fail,
            burst_pass,
            burst_fail,
            burst_loop_count,
            burst_loop_pass,
            burst_loop_fail,
            burst_loop_time_us,
        )
        return False

    suite_pass = True
    print_frequency_summary(
        suite_pass,
        soft_reset_pass,
        invert_pass,
        invert_fail,
        loop_count,
        loop_pass,
        loop_fail,
        burst_pass,
        burst_fail,
        burst_loop_count,
        burst_loop_pass,
        burst_loop_fail,
        burst_loop_time_us,
    )
    return True


def main():
    total_start = ticks_us()
    completed_frequencies = 0
    overall_pass = False

    try:
        program_fpga()
        initialize_bus()
        run_local_self_tests()

        overall_pass = True
        for parallel_clk_hz in PIO_CLOCKS_HZ:
            if not run_frequency_suite(parallel_clk_hz):
                overall_pass = False
                print(
                    "CLOCK_SWEEP_STOP PARALLEL_CLK_HZ={} REASON=FIRST_FAILURE".format(
                        parallel_clk_hz
                    )
                )
                break
            completed_frequencies += 1
    except Exception as caught:
        overall_pass = False
        print("FATAL ERROR={}".format(format_error(caught)))
    finally:
        if sm is not None:
            try:
                stop_state_machine_safely()
            except Exception as cleanup_error:
                overall_pass = False
                print(
                    "CLEANUP_ERROR DETAIL={}".format(format_error(cleanup_error))
                )

    total_elapsed = ticks_diff(ticks_us(), total_start)
    print(
        "CLOCK_SWEEP_SUMMARY MODE=PIO COMPLETED_FREQUENCIES={} "
        "REQUIRED_FREQUENCIES={} {} TIME_US={}".format(
            completed_frequencies,
            len(PIO_CLOCKS_HZ),
            "PASS" if overall_pass and completed_frequencies == len(PIO_CLOCKS_HZ)
            else "FAIL",
            total_elapsed,
        )
    )


if __name__ == "__main__":
    main()
