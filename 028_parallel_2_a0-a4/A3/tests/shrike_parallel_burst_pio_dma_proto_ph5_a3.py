from array import array
from machine import Pin
from time import sleep_us, ticks_diff, ticks_us
import gc
import rp2
import shrike
import shrike_parallel_c


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
PIO_BLOCK = "PIO0"
PIO_NUMBER = 0
PIO_LOCAL_SM_NUMBER = 0


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
# X/Yは毎回の制御wordで上書きされ、ISRはdata/marker push後、OSRは次のpullで上書きされる。
# DMA countをdata+markerへ厳密に合わせれば両FIFOも空になるため、周波数内は常駐SMとする。
PERSISTENT_SM = True

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
TX_DMA_TIMEOUT_US = 250_000
RX_DMA_FIRST_TIMEOUT_US = 250_000
RX_DMA_PROGRESS_TIMEOUT_US = 250_000
RX_DMA_COMPLETE_TIMEOUT_US = 500_000
MARKER_TIMEOUT_US = 250_000
DMA_STOP_TIMEOUT_US = 100_000
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
DMA_BULK_LOOP_COUNT = 1000
DMA_BULK_LOOP_LENGTH = 256
PHASE2_GPIO_32X1000_US = 28_310_660
PHASE3_PIO_4MHZ_32X1000_US = 12_328_483
PHASE3_PIO_4MHZ_WIRE_BPS = 5_434
PHASE3_PIO_4MHZ_PAYLOAD_BPS = 5_191
GC_MODE = "ENABLED"


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
TX_DMA_BUFFER_WORDS = TX_CONTROL_WORDS + MAX_TX_DATA_WORDS
TX_WORD_BUFFER_COUNT = TX_DMA_BUFFER_WORDS
RX_COMPLETION_WORDS = 1
RX_DMA_BUFFER_WORDS = MAX_RX_DATA_WORDS + RX_COMPLETION_WORDS
RX_WORD_BUFFER_COUNT = RX_DMA_BUFFER_WORDS
COMPLETION_MARKER = 0xFFFFFFFF
PIO_FIFO_DEPTH = 4
PULL_NOBLOCK_INSTRUCTION = rp2.asm_pio_encode("pull(noblock)", 0)


# ===== DMA構成 =====
# RP2040 DatasheetのPIO0 SM0 DREQ表に対応する。
DREQ_PIO0_TX0 = 0
DREQ_PIO0_RX0 = 4
DMA_TRANSFER_BITS = 32
DMA_TRANSFER_BYTES = 4
DMA_TRANSFER_SIZE = 2
DMA_RX_STATE_DIAGNOSTICS = True


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
tx_dma = None
rx_dma = None
tx_dma_channel = None
rx_dma_channel = None
tx_dma_ctrl = None
rx_dma_ctrl = None
tx_dma_error_clear_ctrl = None
rx_dma_error_clear_ctrl = None
current_parallel_clk_hz = PARALLEL_CLK_HZ
current_pio_sm_freq_hz = PARALLEL_CLK_HZ * PIO_CYCLES_PER_NIBBLE
data_bus_input_software_state = False
error_stage = "IDLE"
current_command = None
current_length = 0
last_tx_dma_word_count = 0
last_rx_dma_word_count = 0
last_expected_rx_words = 0
last_marker_index = 0
last_marker_ok = False
last_dma_transfer_time_us = 0
last_transaction_end_to_end_time_us = 0
last_burst_loop_dma_time_us = 0
last_bulk_count = 0
last_bulk_pass = 0
last_bulk_fail = 0
last_bulk_end_to_end_time_us = 0
last_bulk_dma_transfer_time_us = 0

# ループごとの大きな割り当てを避けるため、最大長バッファを再利用する
burst_tx = bytearray(MAX_BURST_LENGTH)
burst_expected = bytearray(MAX_BURST_LENGTH)
request_buffer = bytearray(MAX_REQUEST_BYTES)
response_buffer = bytearray(MAX_RESPONSE_BYTES)
response_raw_gpio_nibbles = bytearray(MAX_RX_NIBBLES)
tx_words = array("I", [0] * TX_WORD_BUFFER_COUNT)
rx_words = array("I", [0] * RX_WORD_BUFFER_COUNT)
# DMAへは配列全体の固定viewを渡し、countだけをpacketごとに必要word数へ設定する。
tx_dma_words_view = memoryview(tx_words)
rx_dma_words_view = memoryview(rx_words)


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


def _validate_dma_control(ctrl, is_tx):
    """pack_ctrl結果がPhase 4固定条件と一致することを起動時に確認する。"""
    fields = rp2.DMA.unpack_ctrl(ctrl)
    expected_treq = DREQ_PIO0_TX0 if is_tx else DREQ_PIO0_RX0
    expected_inc_read = True if is_tx else False
    expected_inc_write = False if is_tx else True
    expected_chain_to = tx_dma_channel if is_tx else rx_dma_channel

    if fields["enable"] != 1:
        raise ProtocolError("DMA control enable不一致")
    if fields["size"] != DMA_TRANSFER_SIZE:
        raise ProtocolError("DMA control size不一致")
    if fields["inc_read"] != expected_inc_read:
        raise ProtocolError("DMA control inc_read不一致")
    if fields["inc_write"] != expected_inc_write:
        raise ProtocolError("DMA control inc_write不一致")
    if fields["treq_sel"] != expected_treq:
        raise ProtocolError("DMA control treq_sel不一致")
    if fields["bswap"] != 0:
        raise ProtocolError("DMA control bswapが無効でない")
    if fields["ring_size"] != 0:
        raise ProtocolError("DMA control ringが無効でない")
    if fields["chain_to"] != expected_chain_to:
        raise ProtocolError("DMA control chainingが無効でない")
    if fields["sniff_en"] != 0:
        raise ProtocolError("DMA control sniffが無効でない")
    if fields["irq_quiet"] != 1:
        raise ProtocolError("DMA control IRQ quiet不一致")
    if fields["high_pri"] != 0:
        raise ProtocolError("DMA control high priority不一致")
    if fields["read_err"] != 0 or fields["write_err"] != 0:
        raise ProtocolError("DMA通常controlにW1C error bitが混在")


def initialize_dma_channels():
    """TX/RX DMAを起動時に各1channelだけ確保し、全試験で再利用する。"""
    global tx_dma, rx_dma, tx_dma_channel, rx_dma_channel
    global tx_dma_ctrl, rx_dma_ctrl
    global tx_dma_error_clear_ctrl, rx_dma_error_clear_ctrl

    if tx_dma is not None or rx_dma is not None:
        raise ProtocolError("DMA channelの二重初期化")
    if DREQ_PIO0_TX0 != (PIO_NUMBER << 3) + PIO_LOCAL_SM_NUMBER:
        raise ProtocolError("PIO0 SM0 TX DREQ計算不一致")
    if DREQ_PIO0_RX0 != (PIO_NUMBER << 3) + 4 + PIO_LOCAL_SM_NUMBER:
        raise ProtocolError("PIO0 SM0 RX DREQ計算不一致")

    try:
        tx_dma = rp2.DMA()
        tx_dma_channel = tx_dma.channel
        rx_dma = rp2.DMA()
        rx_dma_channel = rx_dma.channel
        if tx_dma_channel == rx_dma_channel:
            raise ProtocolError("TX/RX DMA channelが同一")

        # chain_toへ自channelを指定するとchainingは無効。ring/sniff/bswapも明示的に無効化する。
        tx_dma_ctrl = tx_dma.pack_ctrl(
            enable=True,
            high_pri=False,
            size=DMA_TRANSFER_SIZE,
            inc_read=True,
            inc_write=False,
            ring_size=0,
            ring_sel=False,
            chain_to=tx_dma_channel,
            treq_sel=DREQ_PIO0_TX0,
            irq_quiet=True,
            bswap=False,
            sniff_en=False,
            write_err=False,
            read_err=False,
        )
        rx_dma_ctrl = rx_dma.pack_ctrl(
            enable=True,
            high_pri=False,
            size=DMA_TRANSFER_SIZE,
            inc_read=False,
            inc_write=True,
            ring_size=0,
            ring_sel=False,
            chain_to=rx_dma_channel,
            treq_sel=DREQ_PIO0_RX0,
            irq_quiet=True,
            bswap=False,
            sniff_en=False,
            write_err=False,
            read_err=False,
        )
        _validate_dma_control(tx_dma_ctrl, True)
        _validate_dma_control(rx_dma_ctrl, False)
        # READ_ERROR/WRITE_ERRORはW1Cなので、通常設定用controlへ混在させない。
        # error発生後、channel停止済みの安全復帰処理だけで使用する。
        tx_dma_error_clear_ctrl = tx_dma.pack_ctrl(
            default=tx_dma_ctrl,
            enable=False,
            write_err=True,
            read_err=True,
        )
        rx_dma_error_clear_ctrl = rx_dma.pack_ctrl(
            default=rx_dma_ctrl,
            enable=False,
            write_err=True,
            read_err=True,
        )
    except Exception:
        # 片側だけ確保できた場合もclaimを残さない。元例外はそのまま上位へ返す。
        if rx_dma is not None:
            try:
                rx_dma.active(0)
                rx_dma.close()
            except Exception as cleanup_error:
                print("DMA_INIT_CLEANUP_ERROR SIDE=RX DETAIL={}".format(
                    format_error(cleanup_error)
                ))
            rx_dma = None
        if tx_dma is not None:
            try:
                tx_dma.active(0)
                tx_dma.close()
            except Exception as cleanup_error:
                print("DMA_INIT_CLEANUP_ERROR SIDE=TX DETAIL={}".format(
                    format_error(cleanup_error)
                ))
            tx_dma = None
        raise

    print(
        "DMA_INIT MODE=PIO_DMA TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "TX_DREQ={} RX_DREQ={} TRANSFER_BITS={} "
        "TX_CTRL=0x{:08X} RX_CTRL=0x{:08X} "
        "TX_BUFFER_WORDS={} RX_BUFFER_WORDS={} PASS".format(
            tx_dma_channel,
            rx_dma_channel,
            DREQ_PIO0_TX0,
            DREQ_PIO0_RX0,
            DMA_TRANSFER_BITS,
            tx_dma_ctrl,
            rx_dma_ctrl,
            TX_DMA_BUFFER_WORDS,
            RX_DMA_BUFFER_WORDS,
        )
    )


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
    """周波数ごとに1回だけ初期化し、制御word待ちでactiveを維持する。"""
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
    # Phase 3命令列の先頭pull(block).side(0)で待つため、制御word受信前にCLKは出ない。
    sm.active(1)


def pack_tx_words(
    request_bytes,
    request_length,
    response_length,
):
    """事前確保済みTX word bufferへC User C Moduleでpackする。"""
    return shrike_parallel_c.pack_tx_words(
        request_bytes,
        request_length,
        response_length,
        tx_words,
    )

def unpack_rx_words(
    response_bytes,
    response_length,
):
    """事前確保済みRX word bufferをC User C Moduleでunpackする。"""
    return shrike_parallel_c.unpack_rx_words(
        rx_words,
        response_bytes,
        response_length,
        response_raw_gpio_nibbles,
    )

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
    """実機不要の全packet長、word境界、DMA count、marker位置自己試験。"""
    for logical_nibble in range(16):
        gpio_nibble = logical_to_gpio[logical_nibble]
        if gpio_to_logical[gpio_nibble] != logical_nibble:
            raise AssertionError("nibble相互変換失敗")

    for request_length in range(1, MAX_REQUEST_BYTES + 1):
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
        if total_words < 3 or total_words > TX_DMA_BUFFER_WORDS:
            raise AssertionError("TX DMA count範囲失敗")

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

    for response_length in range(1, MAX_RESPONSE_BYTES + 1):
        for index in range(response_length):
            response_buffer[index] = (index * 53 + response_length) & 0xFF

        data_words = _selftest_build_rx_words(response_length)
        marker_index = data_words
        rx_dma_word_count = data_words + RX_COMPLETION_WORDS
        if marker_index != rx_dma_word_count - 1:
            raise AssertionError("marker位置とRX DMA count不一致")
        if rx_dma_word_count < 2 or rx_dma_word_count > RX_DMA_BUFFER_WORDS:
            raise AssertionError("RX DMA count範囲失敗")
        rx_words[marker_index] = COMPLETION_MARKER
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
        if rx_words[marker_index] != COMPLETION_MARKER:
            raise AssertionError("期待位置marker失敗")

    if MAX_TX_NIBBLES != 516 or MAX_TX_DATA_WORDS != 65:
        raise AssertionError("最大TX境界失敗")
    if MAX_RX_NIBBLES != 514 or MAX_RX_DATA_WORDS != 65:
        raise AssertionError("最大RX境界失敗")
    if TX_WORD_BUFFER_COUNT != 67 or RX_WORD_BUFFER_COUNT != 66:
        raise AssertionError("制御word/marker領域失敗")
    if TX_DMA_BUFFER_WORDS != 67 or RX_DMA_BUFFER_WORDS != 66:
        raise AssertionError("DMA buffer最大word数失敗")
    if PIO_INSTRUCTION_COUNT != 21:
        raise AssertionError("PIO命令数失敗")
    if (
        TX_CYCLES_PER_NIBBLE != 4
        or RX_CYCLES_PER_NIBBLE != 4
        or PIO_CYCLES_PER_NIBBLE != 4
    ):
        raise AssertionError("PIOサイクル数失敗")

    # data wordに同値があっても検索せず、計算済みmarker位置だけを見る。
    rx_words[0] = COMPLETION_MARKER
    collision_marker_index = (
        MAX_RX_NIBBLES + RX_NIBBLES_PER_WORD - 1
    ) // RX_NIBBLES_PER_WORD
    rx_words[collision_marker_index] = COMPLETION_MARKER
    if collision_marker_index != MAX_RX_DATA_WORDS:
        raise AssertionError("marker衝突回避位置失敗")

    if print_result:
        print(
            "SELFTEST NIBBLE_CONVERSION=PASS "
            "REQUEST_LENGTHS=1..258 RESPONSE_LENGTHS=1..257 "
            "PACKET_WORD_BOUNDARY=PASS DMA_COUNT=PASS MARKER_POSITION=PASS "
            "TX_MAX_NIBBLES=516 TX_MAX_DATA_WORDS=65 "
            "RX_MAX_NIBBLES=514 RX_MAX_DATA_WORDS=65 "
            "TX_BUFFER_WORDS=67 RX_BUFFER_WORDS=66 PASS"
        )
    return True


def _raise_timeout(stage, message):
    global error_stage
    error_stage = stage
    raise ProtocolTimeout(message)


def _raise_protocol_error(stage, message):
    global error_stage
    error_stage = stage
    raise ProtocolError(message)


def _dma_error_flags(dma):
    """公開ctrl/unpack_ctrl APIからAHB/read/write errorを返す。"""
    fields = rp2.DMA.unpack_ctrl(dma.ctrl)
    return fields["ahb_err"], fields["read_err"], fields["write_err"]


def _check_dma_errors(stage):
    tx_ahb, tx_read, tx_write = _dma_error_flags(tx_dma)
    rx_ahb, rx_read, rx_write = _dma_error_flags(rx_dma)
    if tx_ahb or tx_read or tx_write:
        _raise_protocol_error(
            stage,
            "TX DMA bus error AHB={} READ={} WRITE={}".format(
                tx_ahb, tx_read, tx_write
            ),
        )
    if rx_ahb or rx_read or rx_write:
        _raise_protocol_error(
            stage,
            "RX DMA bus error AHB={} READ={} WRITE={}".format(
                rx_ahb, rx_read, rx_write
            ),
        )


def _ensure_transaction_start_state():
    """DMA設定前にpersistent SMとbusが既知のpacket境界にあることを確認する。"""
    global error_stage
    error_stage = "PRE_REQ_LOW"
    wait_req_level(
        0,
        REQ_RELEASE_TIMEOUT_US,
        "DMA開始前REQ Low待ちタイムアウト",
    )
    if tx_dma.active() or rx_dma.active():
        _raise_protocol_error("PRE_DMA_INACTIVE", "開始前にDMAがactive")
    if tx_dma.count != 0 or rx_dma.count != 0:
        _raise_protocol_error("PRE_DMA_COUNT", "開始前DMA countが0でない")
    if not sm.active():
        _raise_protocol_error("PRE_SM_ACTIVE", "persistent SMが停止中")
    if sm.tx_fifo() != 0 or sm.rx_fifo() != 0:
        _raise_protocol_error("PRE_FIFO_EMPTY", "開始前PIO FIFOに残存word")
    if clk_pin.value() != 0:
        _raise_protocol_error("PRE_CLK_LOW", "DMA開始前CLKがLowでない")
    if not data_bus_input_software_state:
        _raise_protocol_error("PRE_DATA_INPUT", "DMA開始前data input状態でない")


def _rx_dma_diagnostics_enabled():
    return DMA_RX_STATE_DIAGNOSTICS and current_command == SOFT_RESET


def _print_rx_dma_state(
    label,
    expected_count,
    count_value,
    active_value,
    register_count,
):
    """SOFT_RESETのRX DMA count設定順序を公開APIの値だけで一時診断する。"""
    print(
        "{} EXPECTED={} COUNT={} ACTIVE={} REGISTER_COUNT={}".format(
            label,
            expected_count,
            count_value,
            active_value,
            register_count,
        )
    )


def _configure_transaction_dma(total_tx_words, total_rx_words):
    """RX→TXの順に設定し、まだtriggerせず開始順序を分離する。"""
    global error_stage
    expected_tx_words = int(total_tx_words)
    expected_rx_words = int(total_rx_words)
    if expected_tx_words < 1 or expected_tx_words > TX_DMA_BUFFER_WORDS:
        _raise_protocol_error("TX_DMA_COUNT_RANGE", "TX DMA countがbuffer範囲外")
    if expected_rx_words < 1 or expected_rx_words > RX_DMA_BUFFER_WORDS:
        _raise_protocol_error("RX_DMA_COUNT_RANGE", "RX DMA countがbuffer範囲外")

    # RX DMA中にPythonがRX bufferを触らないよう、使用範囲は開始前に初期化する。
    error_stage = "CLEAR_RX_BUFFER"
    for word_index in range(expected_rx_words):
        rx_words[word_index] = 0

    error_stage = "CONFIG_RX_DMA"
    rx_diagnostics = _rx_dma_diagnostics_enabled()
    if rx_diagnostics:
        _print_rx_dma_state(
            "RX_BEFORE_CONFIG",
            expected_rx_words,
            rx_dma.count,
            rx_dma.active(),
            int(rx_dma.registers[2]),
        )
        print(
            "RX_CONFIG_COUNT_VALUE EXPECTED={} TYPE={}".format(
                expected_rx_words,
                type(expected_rx_words),
            )
        )

    rx_dma.config(
        read=sm,
        write=rx_dma_words_view,
        ctrl=rx_dma_ctrl,
        trigger=False,
    )

    # config直後に、他のDMA操作を挟まず整数化済みcountを属性設定する。
    # count setterは「次のtransfer sequenceの総transfer数」を設定する。
    # 停止中のcount getterとregisters[2]は「現在sequenceの残数」なので、
    # 設定直後にexpected_rx_wordsと一致することは要求しない。
    rx_dma.count = expected_rx_words

    if rx_diagnostics:
        # registers[2]は現在sequenceのTRANS_COUNT読出し診断だけに使う。
        rx_count_after_config = rx_dma.count
        rx_active_after_config = rx_dma.active()
        rx_register_count = int(rx_dma.registers[2])
        _print_rx_dma_state(
            "RX_AFTER_CONFIG",
            expected_rx_words,
            rx_count_after_config,
            rx_active_after_config,
            rx_register_count,
        )

    error_stage = "CONFIG_TX_DMA"
    tx_dma.config(
        read=tx_dma_words_view,
        write=sm,
        ctrl=tx_dma_ctrl,
        trigger=False,
    )
    # TXもsetterで次回sequenceの総transfer数を設定する。開始前getterとの
    # 一致は要求しない。開始直後もPIO TX DREQで既に進行し得る。
    tx_dma.count = expected_tx_words
    _check_dma_errors("CONFIG_DMA_ERROR")


def _run_dma_transaction(total_rx_words):
    """RX DMAを先に開始し、2channelのactive/countと個別timeoutをpollする。"""
    global data_bus_input_software_state, error_stage
    global last_dma_transfer_time_us
    expected_rx_words = int(total_rx_words)

    # RXを先に待機させて返信先を保証し、TX制御wordの到着をtransaction開始にする。
    error_stage = "START_RX_DMA"
    dma_start = ticks_us()
    rx_dma.active(1)

    # TX DMA開始前なので、SOFT_RESETではcount=2のままactiveになる。
    # active()は引数なしの状態取得であり、active(0)によるabortではない。
    rx_count_after_start = rx_dma.count
    rx_active_after_start = rx_dma.active()
    rx_register_count_after_start = None
    if _rx_dma_diagnostics_enabled():
        rx_register_count_after_start = int(rx_dma.registers[2])
        _print_rx_dma_state(
            "RX_AFTER_START",
            expected_rx_words,
            rx_count_after_start,
            rx_active_after_start,
            rx_register_count_after_start,
        )
    if rx_count_after_start != expected_rx_words:
        _raise_protocol_error("START_RX_DMA_COUNT", "RX DMA開始直後count不一致")
    if not rx_active_after_start:
        _raise_protocol_error("START_RX_DMA_ACTIVE", "RX DMA開始直後inactive")
    if (
        rx_register_count_after_start is not None
        and rx_register_count_after_start != rx_count_after_start
    ):
        _raise_protocol_error(
            "START_RX_DMA_COUNT_REGISTER",
            "RX DMA開始直後のcount属性とTRANS_COUNT不一致",
        )

    error_stage = "START_TX_DMA"
    data_bus_input_software_state = False
    tx_dma.active(1)

    req_high_seen = False
    rx_progress_seen = False
    reply_start = dma_start
    last_rx_progress = dma_start
    last_rx_remaining = expected_rx_words
    marker_wait_start = None

    while True:
        error_stage = "POLL_DMA"
        now = ticks_us()
        elapsed = ticks_diff(now, dma_start)
        tx_active = tx_dma.active()
        rx_active = rx_dma.active()
        tx_remaining = tx_dma.count
        rx_remaining = rx_dma.count

        if req_pin.value() == 1 and not req_high_seen:
            req_high_seen = True
            reply_start = now

        if rx_remaining < last_rx_remaining:
            last_rx_remaining = rx_remaining
            last_rx_progress = now
            rx_progress_seen = True
            req_high_seen = True

        if rx_remaining == 1 and marker_wait_start is None:
            marker_wait_start = now

        if not tx_active and tx_remaining != 0:
            _check_dma_errors("TX_DMA_STOPPED_EARLY")
            _raise_protocol_error(
                "TX_DMA_STOPPED_EARLY",
                "TX DMA inactiveだがcountが残存",
            )
        if not rx_active and rx_remaining != 0:
            _check_dma_errors("RX_DMA_STOPPED_EARLY")
            _raise_protocol_error(
                "RX_DMA_STOPPED_EARLY",
                "RX DMA inactiveだがcountが残存",
            )

        if tx_active and elapsed >= TX_DMA_TIMEOUT_US:
            _raise_timeout("WAIT_TX_DMA", "TX DMA完了待ちタイムアウト")
        if (
            not req_high_seen
            and not rx_progress_seen
            and elapsed >= REQ_ASSERT_TIMEOUT_US
        ):
            _raise_timeout("WAIT_REQ_HIGH", "FPGAのREQ High待ちタイムアウト")
        if (
            req_high_seen
            and not rx_progress_seen
            and ticks_diff(now, reply_start) >= RX_DMA_FIRST_TIMEOUT_US
        ):
            _raise_timeout(
                "WAIT_RX_FIRST_WORD",
                "RX DMA先頭word待ちタイムアウト",
            )
        if (
            rx_progress_seen
            and rx_remaining > 0
            and ticks_diff(now, last_rx_progress) >= RX_DMA_PROGRESS_TIMEOUT_US
        ):
            _raise_timeout(
                "WAIT_RX_PROGRESS",
                "RX DMA進行待ちタイムアウト",
            )
        if rx_active and elapsed >= RX_DMA_COMPLETE_TIMEOUT_US:
            _raise_timeout("WAIT_RX_COMPLETE", "RX DMA全量完了待ちタイムアウト")
        if (
            marker_wait_start is not None
            and rx_remaining == 1
            and ticks_diff(now, marker_wait_start) >= MARKER_TIMEOUT_US
        ):
            _raise_timeout("WAIT_MARKER_WORD", "marker word DMA待ちタイムアウト")

        if (
            not tx_active
            and not rx_active
            and tx_remaining == 0
            and rx_remaining == 0
        ):
            break
        sleep_us(POLL_INTERVAL_US)

    last_dma_transfer_time_us = ticks_diff(ticks_us(), dma_start)
    _check_dma_errors("DMA_COMPLETE_ERROR")


def _confirm_persistent_boundary():
    """marker後の公開観測可能状態から次のpull(block)待ちを確認する。"""
    global data_bus_input_software_state
    # marker push解除後、次のpullへ進む1 SM cycle以上を確保する。
    settle_us = (
        1_000_000 + current_pio_sm_freq_hz - 1
    ) // current_pio_sm_freq_hz + 1
    sleep_us(settle_us)
    if tx_dma.active() or rx_dma.active():
        _raise_protocol_error("POST_DMA_INACTIVE", "完了後DMAがactive")
    if tx_dma.count != 0 or rx_dma.count != 0:
        _raise_protocol_error("POST_DMA_COUNT", "完了後DMA countが0でない")
    if not sm.active():
        _raise_protocol_error("POST_SM_ACTIVE", "完了後persistent SMが停止")
    if sm.tx_fifo() != 0 or sm.rx_fifo() != 0:
        _raise_protocol_error("POST_FIFO_EMPTY", "完了後PIO FIFOに残存word")
    if clk_pin.value() != 0:
        _raise_protocol_error("POST_CLK_LOW", "完了後CLKがLowでない")
    # PIO命令列ではdata input化後にmarkerをpushする。公開APIでpindirsのreadbackはない。
    data_bus_input_software_state = True


def _print_transaction_error(caught):
    """復帰前の取得可能なDMA/FIFO/GPIO状態を失敗ログへ残す。"""
    diagnostics = []
    try:
        tx_active = tx_dma.active() if tx_dma is not None else "UNAVAILABLE"
        tx_count = tx_dma.count if tx_dma is not None else "UNAVAILABLE"
    except Exception as diagnostic_error:
        tx_active = "UNAVAILABLE"
        tx_count = "UNAVAILABLE"
        diagnostics.append("TX_DMA={}".format(format_error(diagnostic_error)))
    try:
        rx_active = rx_dma.active() if rx_dma is not None else "UNAVAILABLE"
        rx_count = rx_dma.count if rx_dma is not None else "UNAVAILABLE"
    except Exception as diagnostic_error:
        rx_active = "UNAVAILABLE"
        rx_count = "UNAVAILABLE"
        diagnostics.append("RX_DMA={}".format(format_error(diagnostic_error)))

    # DMA所有中はFIFO data registerへCPUから触れず、levelも保守的に取得不能とする。
    if tx_active is True or rx_active is True:
        tx_fifo_level = "UNAVAILABLE_DURING_DMA"
        rx_fifo_level = "UNAVAILABLE_DURING_DMA"
    else:
        try:
            tx_fifo_level = sm.tx_fifo()
            rx_fifo_level = sm.rx_fifo()
        except Exception as diagnostic_error:
            tx_fifo_level = "UNAVAILABLE"
            rx_fifo_level = "UNAVAILABLE"
            diagnostics.append("PIO_FIFO={}".format(format_error(diagnostic_error)))

    try:
        req_level = req_pin.value()
    except Exception as diagnostic_error:
        req_level = "UNAVAILABLE"
        diagnostics.append("REQ={}".format(format_error(diagnostic_error)))
    try:
        clk_level = clk_pin.value()
    except Exception as diagnostic_error:
        clk_level = "UNAVAILABLE"
        diagnostics.append("CLK={}".format(format_error(diagnostic_error)))

    print(
        "ERROR_STAGE={} EXCEPTION_TYPE={} EXCEPTION_MESSAGE={} "
        "PARALLEL_CLK_HZ={} COMMAND={} LENGTH={} "
        "TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "TX_DMA_ACTIVE={} RX_DMA_ACTIVE={} "
        "TX_DMA_COUNT={} RX_DMA_COUNT={} "
        "TX_FIFO_LEVEL={} RX_FIFO_LEVEL={} "
        "REQ_LEVEL={} CLK_LEVEL={} EXPECTED_RX_WORDS={} MARKER_INDEX={}".format(
            error_stage,
            type(caught).__name__,
            caught,
            current_parallel_clk_hz,
            format_byte(current_command),
            current_length,
            tx_dma_channel,
            rx_dma_channel,
            tx_active,
            rx_active,
            tx_count,
            rx_count,
            tx_fifo_level,
            rx_fifo_level,
            req_level,
            clk_level,
            last_expected_rx_words,
            last_marker_index,
        )
    )
    for diagnostic in diagnostics:
        print("ERROR_DIAGNOSTIC {}".format(diagnostic))


def _wait_dma_stopped_after_abort():
    start = ticks_us()
    while tx_dma.active() or rx_dma.active():
        if ticks_diff(ticks_us(), start) >= DMA_STOP_TIMEOUT_US:
            raise ProtocolTimeout("DMA停止確認タイムアウト")
        sleep_us(POLL_INTERVAL_US)


def _recover_transaction():
    """TX DMA→RX DMA→SM→GPIO→RX/TX FIFO→DMAの順で安全復帰する。"""
    recovery_failed = False

    # 1. TX DMA停止
    try:
        if tx_dma is not None:
            tx_dma.active(0)
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=STOP_TX_DMA DETAIL={}".format(
            format_error(recovery_error)
        ))

    # 2. RX DMA停止
    try:
        if rx_dma is not None:
            rx_dma.active(0)
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=STOP_RX_DMA DETAIL={}".format(
            format_error(recovery_error)
        ))

    try:
        if tx_dma is not None and rx_dma is not None:
            _wait_dma_stopped_after_abort()
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=CONFIRM_DMA_STOP DETAIL={}".format(
            format_error(recovery_error)
        ))

    # 3. State Machine停止
    try:
        if sm is not None:
            sm.active(0)
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=STOP_SM DETAIL={}".format(
            format_error(recovery_error)
        ))

    # 4. GP15 Low、5. GP0～GP3 input
    try:
        force_safe_gpio()
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=SAFE_GPIO DETAIL={}".format(
            format_error(recovery_error)
        ))

    # 6. RX FIFO排出、7. TX FIFO排出（停止中だけget/execを使用する）
    try:
        drain_state_machine_fifos()
        if sm is not None:
            sm.restart()
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=DRAIN_FIFO DETAIL={}".format(
            format_error(recovery_error)
        ))

    # 8. 停止後だけW1C専用controlでerror flagをclearし、count=0へ戻す。
    # 通常設定用controlにはREAD_ERROR/WRITE_ERRORを混在させない。
    try:
        if tx_dma is not None:
            tx_dma.config(
                count=0,
                ctrl=tx_dma_error_clear_ctrl,
                trigger=False,
            )
        if rx_dma is not None:
            rx_dma.config(
                count=0,
                ctrl=rx_dma_error_clear_ctrl,
                trigger=False,
            )
    except Exception as recovery_error:
        recovery_failed = True
        print("RECOVERY_ERROR STAGE=RESET_DMA DETAIL={}".format(
            format_error(recovery_error)
        ))

    print(
        "RECOVERY COMPLETE={} PERSISTENT_SM_REUSE=NO "
        "FPGA_REINIT_OR_BITSTREAM_REWRITE_REQUIRED=YES".format(
            "FAIL" if recovery_failed else "PASS"
        )
    )


def transfer(request_bytes, request_length, response_bytes, response_length):
    """DMAで固定長要求を送信し、応答を事前確保バッファへ受信する。"""
    global error_stage, current_command, current_length
    global last_tx_dma_word_count, last_rx_dma_word_count
    global last_expected_rx_words, last_marker_index, last_marker_ok
    global last_dma_transfer_time_us, last_transaction_end_to_end_time_us

    transaction_start = ticks_us()
    current_command = request_bytes[0] if request_length > 0 else None
    if current_command == BURST_INVERT and request_length >= 2:
        current_length = request_length - 2
    elif current_command == INVERT and request_length >= 1:
        current_length = request_length - 1
    else:
        current_length = 0
    last_tx_dma_word_count = 0
    last_rx_dma_word_count = 0
    last_expected_rx_words = 0
    last_marker_index = 0
    last_marker_ok = False
    last_dma_transfer_time_us = 0
    error_stage = "PACK_TX_WORDS"

    try:
        total_tx_words, _, _ = pack_tx_words(
            request_bytes, request_length, response_length
        )
        response_nibble_count = response_length * 2
        rx_data_word_count = (
            response_nibble_count + RX_NIBBLES_PER_WORD - 1
        ) // RX_NIBBLES_PER_WORD
        marker_index = rx_data_word_count
        total_rx_words = rx_data_word_count + RX_COMPLETION_WORDS

        last_tx_dma_word_count = total_tx_words
        last_rx_dma_word_count = total_rx_words
        last_expected_rx_words = total_rx_words
        last_marker_index = marker_index

        if marker_index != total_rx_words - 1:
            _raise_protocol_error("MARKER_COUNT_RELATION", "marker位置とRX count不一致")

        _ensure_transaction_start_state()
        _configure_transaction_dma(total_tx_words, total_rx_words)
        _run_dma_transaction(total_rx_words)

        error_stage = "CHECK_MARKER"
        marker_value = rx_words[marker_index]
        if marker_value != COMPLETION_MARKER:
            _raise_protocol_error(
                "CHECK_MARKER",
                "期待位置PIO完了marker不一致: 0x{:08X}".format(marker_value),
            )
        last_marker_ok = True

        error_stage = "WAIT_REQ_LOW"
        wait_req_level(
            0,
            REQ_RELEASE_TIMEOUT_US,
            "FPGAの最終REQ Low待ちタイムアウト",
        )
        error_stage = "CHECK_PIO_BOUNDARY"
        _confirm_persistent_boundary()
        error_stage = "UNPACK_RX"
        unpacked_word_count = unpack_rx_words(response_bytes, response_length)
        if unpacked_word_count != rx_data_word_count:
            _raise_protocol_error("UNPACK_RX_COUNT", "RX data word数不一致")
        error_stage = "IDLE"
    except Exception as caught:
        _print_transaction_error(caught)
        _recover_transaction()
        raise
    finally:
        last_transaction_end_to_end_time_us = ticks_diff(
            ticks_us(), transaction_start
        )


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
    response_byte_index = byte_index + 1
    raw_high, logical_high, raw_low, logical_low = mismatch_nibble_fields(
        response_byte_index
    )
    rx_word_index = (response_byte_index * 2) // RX_NIBBLES_PER_WORD
    print(
        "PACKET_INDEX={} BYTE_INDEX={} TX={} RX={} EXPECT={} "
        "RAW_GPIO_NIBBLE=0x{:X} LOGICAL_NIBBLE=0x{:X} "
        "RAW_GPIO_NIBBLE_LOW=0x{:X} LOGICAL_NIBBLE_LOW=0x{:X} "
        "RX_WORD_INDEX={} RX_WORD_VALUE=0x{:08X} "
        "MARKER_INDEX={} MARKER_VALUE=0x{:08X} "
        "TX_DMA_ACTIVE={} RX_DMA_ACTIVE={} MARKER_OK={} "
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
            rx_word_index,
            rx_words[rx_word_index],
            last_marker_index,
            rx_words[last_marker_index],
            tx_dma.active(),
            rx_dma.active(),
            last_marker_ok,
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
        "MODE=PIO_DMA COMMAND=SOFT_RESET TX=0x00 RX={} EXPECT=0x00 "
        "STATUS={} MARKER_OK={} TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "TX_DMA_WORDS={} RX_DMA_WORDS={} PASS={} "
        "END_TO_END_TIME_US={} DMA_TRANSFER_TIME_US={} "
        "PARALLEL_CLK_HZ={}".format(
            format_byte(status),
            format_byte(status),
            "PASS" if last_marker_ok else "FAIL",
            tx_dma_channel,
            rx_dma_channel,
            last_tx_dma_word_count,
            last_rx_dma_word_count,
            "PASS" if passed else "FAIL",
            elapsed,
            last_dma_transfer_time_us,
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
            "MODE=PIO_DMA COMMAND=INVERT TX={} RX={} EXPECT={} STATUS={} "
            "MARKER_OK={} TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
            "TX_DMA_WORDS={} RX_DMA_WORDS={} PASS={} "
            "END_TO_END_TIME_US={} DMA_TRANSFER_TIME_US={} "
            "PARALLEL_CLK_HZ={}".format(
                format_byte(value),
                format_byte(result),
                format_byte(expected),
                format_byte(status),
                "PASS" if last_marker_ok else "FAIL",
                tx_dma_channel,
                rx_dma_channel,
                last_tx_dma_word_count,
                last_rx_dma_word_count,
                "PASS" if passed else "FAIL",
                elapsed,
                last_dma_transfer_time_us,
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
        "MODE=PIO_DMA PIO_SM_FREQ_HZ={} PIO_CYCLES_PER_NIBBLE={} "
        "TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "TX_DMA_WORDS={} RX_DMA_WORDS={} "
        "COMMAND=BURST_INVERT LENGTH={} STATUS={} DATA_OK={} MARKER_OK={} "
        "FIRST_MISMATCH={} PASS={} TIME_US={} "
        "END_TO_END_TIME_US={} DMA_TRANSFER_TIME_US={} "
        "PARALLEL_CLK_HZ={}".format(
            current_pio_sm_freq_hz,
            PIO_CYCLES_PER_NIBBLE,
            tx_dma_channel,
            rx_dma_channel,
            last_tx_dma_word_count,
            last_rx_dma_word_count,
            length,
            format_byte(status),
            "PASS" if data_ok else "FAIL",
            "PASS" if last_marker_ok else "FAIL",
            "NONE" if first_mismatch is None else first_mismatch,
            "PASS" if passed else "FAIL",
            elapsed,
            elapsed,
            last_dma_transfer_time_us,
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
    global last_burst_loop_dma_time_us
    gc.collect()
    start = ticks_us()
    loop_count = 0
    loop_pass = 0
    loop_fail = 0
    last_burst_loop_dma_time_us = 0

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
            last_burst_loop_dma_time_us += last_dma_transfer_time_us
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
                    "TX_DMA_ACTIVE={} RX_DMA_ACTIVE={} MARKER_OK={} "
                    "PARALLEL_CLK_HZ={}".format(
                        packet_index,
                        format_byte(status),
                        tx_dma.active(),
                        rx_dma.active(),
                        last_marker_ok,
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
        "BURST_LOOP MODE=PIO_DMA COUNT={} PASS={} FAIL={} TIME_US={} "
        "DMA_TRANSFER_TIME_US={} GC_MODE={} PARALLEL_CLK_HZ={}".format(
            loop_count,
            loop_pass,
            loop_fail,
            elapsed,
            last_burst_loop_dma_time_us,
            GC_MODE,
            current_parallel_clk_hz,
        )
    )
    return loop_count, loop_pass, loop_fail, elapsed


def _calculate_throughput(length, packet_count, time_us):
    if time_us <= 0 or packet_count <= 0:
        return 0, 0, 0
    wire_bytes_per_packet = 3 + 2 * length
    wire_bps = (
        wire_bytes_per_packet * packet_count * 1_000_000 // time_us
    )
    payload_bps = 2 * length * packet_count * 1_000_000 // time_us
    us_per_packet = time_us / packet_count
    return us_per_packet, wire_bps, payload_bps


def run_dma_bulk_loop_test():
    """4MHzで固定256byteを1000packet転送し、毎回全byteを照合する。"""
    global last_bulk_count, last_bulk_pass, last_bulk_fail
    global last_bulk_end_to_end_time_us, last_bulk_dma_transfer_time_us

    for index in range(DMA_BULK_LOOP_LENGTH):
        value = (index * 29 + 7) & 0xFF
        burst_tx[index] = value
        burst_expected[index] = value ^ 0xFF

    last_bulk_count = 0
    last_bulk_pass = 0
    last_bulk_fail = 0
    last_bulk_dma_transfer_time_us = 0
    gc.collect()
    start = ticks_us()

    for packet_index in range(DMA_BULK_LOOP_COUNT):
        status = None
        error = None
        first_mismatch = None
        try:
            transfer_burst(DMA_BULK_LOOP_LENGTH)
            last_bulk_dma_transfer_time_us += last_dma_transfer_time_us
            status = response_buffer[0]

            # 性能測定でも検証を省略せず、全256byteを毎packet照合する。
            for index in range(DMA_BULK_LOOP_LENGTH):
                if (
                    response_buffer[index + 1] != burst_expected[index]
                    and first_mismatch is None
                ):
                    first_mismatch = index
        except Exception as caught:
            error = caught

        last_bulk_count += 1
        passed = error is None and status == 0x00 and first_mismatch is None
        if passed:
            last_bulk_pass += 1
        else:
            last_bulk_fail += 1
            if first_mismatch is not None:
                print_mismatch(
                    packet_index,
                    first_mismatch,
                    burst_tx[first_mismatch],
                    response_buffer[first_mismatch + 1],
                    burst_expected[first_mismatch],
                )
            else:
                print(
                    "DMA_BULK_ERROR PACKET_INDEX={} STATUS={} DETAIL={} "
                    "TX_DMA_ACTIVE={} RX_DMA_ACTIVE={} MARKER_OK={} "
                    "PARALLEL_CLK_HZ={}".format(
                        packet_index,
                        format_byte(status),
                        format_error(error),
                        tx_dma.active(),
                        rx_dma.active(),
                        last_marker_ok,
                        current_parallel_clk_hz,
                    )
                )
            break

    last_bulk_end_to_end_time_us = ticks_diff(ticks_us(), start)
    end_us_per_packet, end_wire_bps, end_payload_bps = _calculate_throughput(
        DMA_BULK_LOOP_LENGTH,
        last_bulk_count,
        last_bulk_end_to_end_time_us,
    )
    dma_us_per_packet, dma_wire_bps, dma_payload_bps = _calculate_throughput(
        DMA_BULK_LOOP_LENGTH,
        last_bulk_count,
        last_bulk_dma_transfer_time_us,
    )
    theoretical_raw_bps = current_parallel_clk_hz // 2
    end_efficiency = (
        end_wire_bps * 100 / theoretical_raw_bps
        if theoretical_raw_bps > 0
        else 0
    )
    dma_efficiency = (
        dma_wire_bps * 100 / theoretical_raw_bps
        if theoretical_raw_bps > 0
        else 0
    )
    end_vs_phase3_wire = (
        end_wire_bps / PHASE3_PIO_4MHZ_WIRE_BPS
        if PHASE3_PIO_4MHZ_WIRE_BPS > 0
        else 0
    )
    dma_vs_phase3_wire = (
        dma_wire_bps / PHASE3_PIO_4MHZ_WIRE_BPS
        if PHASE3_PIO_4MHZ_WIRE_BPS > 0
        else 0
    )
    bulk_tx_dma_words = TX_CONTROL_WORDS + (
        (DMA_BULK_LOOP_LENGTH + 2) * 2 + TX_NIBBLES_PER_WORD - 1
    ) // TX_NIBBLES_PER_WORD
    bulk_rx_dma_words = (
        (DMA_BULK_LOOP_LENGTH + 1) * 2 + RX_NIBBLES_PER_WORD - 1
    ) // RX_NIBBLES_PER_WORD + RX_COMPLETION_WORDS
    bulk_passed = (
        last_bulk_count == DMA_BULK_LOOP_COUNT
        and last_bulk_pass == DMA_BULK_LOOP_COUNT
        and last_bulk_fail == 0
    )

    print(
        "DMA_BULK MODE=PIO_DMA PARALLEL_CLK_HZ={} LENGTH={} "
        "COUNT={} TARGET={} PASS_COUNT={} FAIL_COUNT={} "
        "TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "TX_DMA_WORDS={} RX_DMA_WORDS={} GC_MODE={} "
        "BULK_END_TO_END_TIME_US={} "
        "BULK_END_TO_END_US_PER_PACKET={:.3f} "
        "BULK_END_TO_END_WIRE_BPS={} BULK_END_TO_END_PAYLOAD_BPS={} "
        "BULK_END_TO_END_LINK_EFFICIENCY_PERCENT={:.3f} "
        "BULK_DMA_TRANSFER_TIME_US={} "
        "BULK_DMA_TRANSFER_US_PER_PACKET={:.3f} "
        "BULK_DMA_TRANSFER_WIRE_BPS={} BULK_DMA_TRANSFER_PAYLOAD_BPS={} "
        "BULK_DMA_LINK_EFFICIENCY_PERCENT={:.3f} "
        "THEORETICAL_RAW_BPS={} "
        "END_TO_END_WIRE_BPS_VS_PHASE3_4MHZ={:.3f} "
        "DMA_WIRE_BPS_VS_PHASE3_4MHZ={:.3f} "
        "PHASE3_256X1000_BASELINE=UNAVAILABLE {}".format(
            current_parallel_clk_hz,
            DMA_BULK_LOOP_LENGTH,
            last_bulk_count,
            DMA_BULK_LOOP_COUNT,
            last_bulk_pass,
            last_bulk_fail,
            tx_dma_channel,
            rx_dma_channel,
            bulk_tx_dma_words,
            bulk_rx_dma_words,
            GC_MODE,
            last_bulk_end_to_end_time_us,
            end_us_per_packet,
            end_wire_bps,
            end_payload_bps,
            end_efficiency,
            last_bulk_dma_transfer_time_us,
            dma_us_per_packet,
            dma_wire_bps,
            dma_payload_bps,
            dma_efficiency,
            theoretical_raw_bps,
            end_vs_phase3_wire,
            dma_vs_phase3_wire,
            "PASS" if bulk_passed else "FAIL",
        )
    )
    return bulk_passed


def check_idle_state():
    """通信終了後のREQ Low、CLK Low、data入力設定を確認する。"""
    req_low = req_pin.value() == 0
    clk_low = clk_pin.value() == 0
    data_input = data_bus_input_software_state
    passed = req_low and clk_low and data_input
    print(
        "IDLE_CHECK PARALLEL_CLK_HZ={} REQ_LOW={} CLK_LOW={} "
        "DATA_INPUT_SW={} DATA_INPUT_WAVEFORM=NOT_TESTED "
        "FIFO_STALL_WAVEFORM=NOT_TESTED BUS_CONTENTION_WAVEFORM=NOT_TESTED "
        "PIO_CONTROL_WAIT=STATIC_INFERRED PASS={}".format(
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
    """32byte×1000のend-to-end/DMA区間とPhase 2/3比をSUMMARY表示する。"""
    end_us_per_packet, end_wire_bps, end_payload_bps = _calculate_throughput(
        BURST_LOOP_LENGTH,
        burst_loop_count,
        burst_loop_time_us,
    )
    dma_us_per_packet, dma_wire_bps, dma_payload_bps = _calculate_throughput(
        BURST_LOOP_LENGTH,
        burst_loop_count,
        last_burst_loop_dma_time_us,
    )
    comparable = burst_loop_count == BURST_LOOP_COUNT and burst_loop_time_us > 0
    speedup_phase2 = (
        PHASE2_GPIO_32X1000_US / burst_loop_time_us if comparable else 0
    )
    speedup_phase3 = (
        PHASE3_PIO_4MHZ_32X1000_US / burst_loop_time_us if comparable else 0
    )
    theoretical_raw_bps = current_parallel_clk_hz // 2
    end_efficiency = (
        end_wire_bps * 100 / theoretical_raw_bps
        if theoretical_raw_bps > 0
        else 0
    )
    dma_efficiency = (
        dma_wire_bps * 100 / theoretical_raw_bps
        if theoretical_raw_bps > 0
        else 0
    )
    summary_tx_dma_words = TX_CONTROL_WORDS + (
        (BURST_LOOP_LENGTH + 2) * 2 + TX_NIBBLES_PER_WORD - 1
    ) // TX_NIBBLES_PER_WORD
    summary_rx_dma_words = (
        (BURST_LOOP_LENGTH + 1) * 2 + RX_NIBBLES_PER_WORD - 1
    ) // RX_NIBBLES_PER_WORD + RX_COMPLETION_WORDS
    bulk_required = current_parallel_clk_hz == 4_000_000
    bulk_result = (
        "PASS"
        if bulk_required
        and last_bulk_count == DMA_BULK_LOOP_COUNT
        and last_bulk_fail == 0
        else "FAIL" if bulk_required else "NOT_RUN"
    )

    print(
        "SUMMARY MODE=PIO_DMA BITSTREAM={} PARALLEL_CLK_HZ={} "
        "PIO_SM_FREQ_HZ={} PIO_CYCLES_PER_NIBBLE={} "
        "TX_CYCLES_PER_NIBBLE={} RX_CYCLES_PER_NIBBLE={} "
        "PIO_BLOCK={} SM_ID={} PERSISTENT_SM={} "
        "TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} TX_DREQ={} RX_DREQ={} "
        "DMA_TRANSFER_BITS={} TX_DMA_WORDS={} RX_DMA_WORDS={} "
        "NORMAL_SM_PUT_COUNT=0 NORMAL_SM_GET_COUNT=0 GC_MODE={} "
        "SOFT_RESET={} INVERT_PASS={} INVERT_FAIL={} "
        "LOOP_COUNT={} LOOP_PASS={} LOOP_FAIL={} "
        "BURST_PASS={} BURST_FAIL={} BURST_LOOP_COUNT={} "
        "BURST_LOOP_TARGET={} BURST_LOOP_LENGTH={} "
        "BURST_LOOP_PASS={} BURST_LOOP_FAIL={} TIME_US={} "
        "US_PER_PACKET={:.3f} WIRE_BPS={} PAYLOAD_BPS={} "
        "END_TO_END_TIME_US={} END_TO_END_US_PER_PACKET={:.3f} "
        "END_TO_END_WIRE_BPS={} END_TO_END_PAYLOAD_BPS={} "
        "END_TO_END_LINK_EFFICIENCY_PERCENT={:.3f} "
        "DMA_TRANSFER_TIME_US={} DMA_TRANSFER_US_PER_PACKET={:.3f} "
        "DMA_TRANSFER_WIRE_BPS={} DMA_TRANSFER_PAYLOAD_BPS={} "
        "DMA_TRANSFER_LINK_EFFICIENCY_PERCENT={:.3f} "
        "THEORETICAL_RAW_BPS={} "
        "SPEEDUP_VS_GPIO={:.3f} SPEEDUP_VS_PHASE2_GPIO={:.3f} "
        "SPEEDUP_VS_PHASE3_PIO={:.3f} "
        "PHASE2_GPIO_32X1000_US={} PHASE3_PIO_4MHZ_32X1000_US={} "
        "PHASE3_PIO_4MHZ_WIRE_BPS={} PHASE3_PIO_4MHZ_PAYLOAD_BPS={} "
        "DMA_BULK_REQUIRED={} DMA_BULK_RESULT={} {}".format(
            BITSTREAM,
            current_parallel_clk_hz,
            current_pio_sm_freq_hz,
            PIO_CYCLES_PER_NIBBLE,
            TX_CYCLES_PER_NIBBLE,
            RX_CYCLES_PER_NIBBLE,
            PIO_BLOCK,
            SM_ID,
            PERSISTENT_SM,
            tx_dma_channel,
            rx_dma_channel,
            DREQ_PIO0_TX0,
            DREQ_PIO0_RX0,
            DMA_TRANSFER_BITS,
            summary_tx_dma_words,
            summary_rx_dma_words,
            GC_MODE,
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
            end_us_per_packet,
            end_wire_bps,
            end_payload_bps,
            burst_loop_time_us,
            end_us_per_packet,
            end_wire_bps,
            end_payload_bps,
            end_efficiency,
            last_burst_loop_dma_time_us,
            dma_us_per_packet,
            dma_wire_bps,
            dma_payload_bps,
            dma_efficiency,
            theoretical_raw_bps,
            speedup_phase2,
            speedup_phase2,
            speedup_phase3,
            PHASE2_GPIO_32X1000_US,
            PHASE3_PIO_4MHZ_32X1000_US,
            PHASE3_PIO_4MHZ_WIRE_BPS,
            PHASE3_PIO_4MHZ_PAYLOAD_BPS,
            bulk_required,
            bulk_result,
            "PASS" if suite_pass else "FAIL",
        )
    )


def run_frequency_suite(parallel_clk_hz):
    """1周波数分を実行し、最初の失敗で同周波数の残りも停止する。"""
    global last_bulk_count, last_bulk_pass, last_bulk_fail
    global last_bulk_end_to_end_time_us, last_bulk_dma_transfer_time_us
    last_bulk_count = 0
    last_bulk_pass = 0
    last_bulk_fail = 0
    last_bulk_end_to_end_time_us = 0
    last_bulk_dma_transfer_time_us = 0
    init_state_machine(parallel_clk_hz)
    print(
        "CONFIG MODE=PIO_DMA BITSTREAM={} DATA_PINS={} CLK_PIN={} REQ_PIN={} "
        "PIO_BLOCK={} SM_ID={} PERSISTENT_SM={} "
        "PARALLEL_CLK_HZ={} PIO_SM_FREQ_HZ={} "
        "PIO_CYCLES_PER_NIBBLE={} TX_CYCLES_PER_NIBBLE={} "
        "RX_CYCLES_PER_NIBBLE={} PIO_INSTRUCTION_COUNT={} "
        "TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "TX_DREQ={} RX_DREQ={} DMA_TRANSFER_BITS={} "
        "TX_INC_READ=True TX_INC_WRITE=False "
        "RX_INC_READ=False RX_INC_WRITE=True BSWAP=False "
        "RING=False CHAIN=False SNIFF=False "
        "DMA_START_ORDER=RX_THEN_TX GC_MODE={}".format(
            BITSTREAM,
            DATA_PIN_NUMBERS,
            CLK_PIN_NUMBER,
            REQ_PIN_NUMBER,
            PIO_BLOCK,
            SM_ID,
            PERSISTENT_SM,
            current_parallel_clk_hz,
            current_pio_sm_freq_hz,
            PIO_CYCLES_PER_NIBBLE,
            TX_CYCLES_PER_NIBBLE,
            RX_CYCLES_PER_NIBBLE,
            PIO_INSTRUCTION_COUNT,
            tx_dma_channel,
            rx_dma_channel,
            DREQ_PIO0_TX0,
            DREQ_PIO0_RX0,
            DMA_TRANSFER_BITS,
            GC_MODE,
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
    burst_loop_idle_passed = check_idle_state()
    if (
        burst_loop_count != BURST_LOOP_COUNT
        or burst_loop_fail
        or not burst_loop_idle_passed
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

    if parallel_clk_hz == 4_000_000:
        bulk_passed = run_dma_bulk_loop_test()
        bulk_idle_passed = check_idle_state()
        if not bulk_passed or not bulk_idle_passed:
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


def stop_dma_channels_safely():
    """終了時もTX→RXの順で停止し、両channelのinactiveを確認する。"""
    stopped = True
    if tx_dma is not None:
        try:
            tx_dma.active(0)
        except Exception as cleanup_error:
            stopped = False
            print("CLEANUP_ERROR STAGE=STOP_TX_DMA DETAIL={}".format(
                format_error(cleanup_error)
            ))
    if rx_dma is not None:
        try:
            rx_dma.active(0)
        except Exception as cleanup_error:
            stopped = False
            print("CLEANUP_ERROR STAGE=STOP_RX_DMA DETAIL={}".format(
                format_error(cleanup_error)
            ))
    if tx_dma is not None and rx_dma is not None:
        try:
            _wait_dma_stopped_after_abort()
        except Exception as cleanup_error:
            stopped = False
            print("CLEANUP_ERROR STAGE=CONFIRM_DMA_STOP DETAIL={}".format(
                format_error(cleanup_error)
            ))
    return stopped


def close_dma_channels():
    """停止済みのTX/RX channelを公開close()で必ず解放する。"""
    global tx_dma, rx_dma
    closed = True
    if tx_dma is not None:
        try:
            tx_dma.close()
        except Exception as cleanup_error:
            closed = False
            print("CLEANUP_ERROR STAGE=CLOSE_TX_DMA DETAIL={}".format(
                format_error(cleanup_error)
            ))
        tx_dma = None
    if rx_dma is not None:
        try:
            rx_dma.close()
        except Exception as cleanup_error:
            closed = False
            print("CLEANUP_ERROR STAGE=CLOSE_RX_DMA DETAIL={}".format(
                format_error(cleanup_error)
            ))
        rx_dma = None
    return closed


def main():
    total_start = ticks_us()
    completed_frequencies = 0
    overall_pass = False

    try:
        # 機能試験をGC無効化へ依存させない。性能loopでもGCは有効のまま維持する。
        gc.enable()
        program_fpga()
        initialize_bus()
        initialize_dma_channels()
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
        if not stop_dma_channels_safely():
            overall_pass = False
        if sm is not None:
            try:
                stop_state_machine_safely()
            except Exception as cleanup_error:
                overall_pass = False
                print(
                    "CLEANUP_ERROR DETAIL={}".format(format_error(cleanup_error))
                )
        if not close_dma_channels():
            overall_pass = False

    total_elapsed = ticks_diff(ticks_us(), total_start)
    print(
        "CLOCK_SWEEP_SUMMARY MODE=PIO_DMA COMPLETED_FREQUENCIES={} "
        "REQUIRED_FREQUENCIES={} TX_DMA_CHANNEL={} RX_DMA_CHANNEL={} "
        "GC_MODE={} {} TIME_US={}".format(
            completed_frequencies,
            len(PIO_CLOCKS_HZ),
            tx_dma_channel,
            rx_dma_channel,
            GC_MODE,
            "PASS" if overall_pass and completed_frequencies == len(PIO_CLOCKS_HZ)
            else "FAIL",
            total_elapsed,
        )
    )


if __name__ == "__main__":
    main()
