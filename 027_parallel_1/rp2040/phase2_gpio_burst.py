from machine import Pin
from time import sleep_us, ticks_diff, ticks_us
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
CLK_PIN_NUMBER = 15
REQ_PIN_NUMBER = 14


# ===== 通信タイミング =====
CLK_HALF_PERIOD_US = 0
TURNAROUND_GUARD_US = 0

# 通常GPIOの最大長バーストに対して十分なタイムアウトを設ける
REQ_ASSERT_TIMEOUT_US = 100_000
REQ_RELEASE_TIMEOUT_US = 100_000
REPLY_START_TIMEOUT_US = 100_000
REPLY_COMPLETE_TIMEOUT_US = 100_000
POLL_INTERVAL_US = 10

BURST_INVERT = 0x02
INVERT_TEST_VALUES = (0x00, 0x01, 0x0F, 0x10, 0x55, 0xAA, 0xFE, 0xFF)
LOOP_TEST_COUNT = 1000
BURST_LENGTHS = (1, 2, 31, 32, 255, 256)
MAX_BURST_LENGTH = 256
BURST_LOOP_COUNT = 1000
BURST_LOOP_LENGTH = 32


class ProtocolTimeout(Exception):
    pass


data_pins = ()
clk_pin = None
req_pin = None

# ループごとの大きな割り当てを避けるため、最大長バッファを再利用する
burst_tx = bytearray(MAX_BURST_LENGTH)
burst_expected = bytearray(MAX_BURST_LENGTH)
request_buffer = bytearray(MAX_BURST_LENGTH + 2)
response_buffer = bytearray(MAX_BURST_LENGTH + 1)


def program_fpga():
    """指定bitstreamをFPGAへ書き込む。"""
    shrike.reset()
    shrike.flash(BITSTREAM)


def initialize_bus():
    """構成用端子を解放し、通信バスを安全な初期状態にする。"""
    global data_pins, clk_pin, req_pin

    # 共有データ端子はまず入力として解放する
    data_pins = tuple(Pin(number, Pin.IN) for number in DATA_PIN_NUMBERS)

    # RP2040がクロックマスター。アイドル時は必ずLow
    clk_pin = Pin(CLK_PIN_NUMBER, Pin.OUT, value=0)

    # REQはFPGAだけが駆動する
    req_pin = Pin(REQ_PIN_NUMBER, Pin.IN)


def set_data_input():
    """RP2040側の4本をまとめて入力へ切り替える。"""
    for pin in data_pins:
        pin.init(Pin.IN)


def set_data_output():
    """FPGAがバスを解放済みのときだけRP2040側を出力へ切り替える。"""
    for pin in data_pins:
        pin.init(Pin.OUT, value=0)


def write_nibble(value):
    """data[3:0]へ下位4bitを出力する。"""
    value &= 0x0F
    for bit_index, pin in enumerate(data_pins):
        pin.value((value >> bit_index) & 1)


def read_nibble():
    """data[3:0]を論理ニブルへ組み立てる。"""
    value = 0
    for bit_index, pin in enumerate(data_pins):
        value |= pin.value() << bit_index
    return value


def clock_pulse():
    """Low期間を確保してからクロックパルスを1回生成する。"""
    sleep_us(CLK_HALF_PERIOD_US)
    clk_pin.value(1)
    sleep_us(CLK_HALF_PERIOD_US)
    clk_pin.value(0)


def write_nibble_clocked(value):
    """Low期間にニブルを設定し、立ち上がりでFPGAへ渡す。"""
    write_nibble(value)
    clock_pulse()


def read_nibble_clocked():
    """立ち上がり後にFPGAのニブルを読み、Lowへ戻す。"""
    clk_pin.value(1)
    sleep_us(CLK_HALF_PERIOD_US)
    value = read_nibble()
    clk_pin.value(0)
    sleep_us(CLK_HALF_PERIOD_US)
    return value


def send_byte(value):
    """上位ニブル、下位ニブルの順に1byteを送る。"""
    write_nibble_clocked((value >> 4) & 0x0F)
    write_nibble_clocked(value & 0x0F)


def receive_byte():
    """上位ニブル、下位ニブルの順に1byteを受け取る。"""
    high_nibble = read_nibble_clocked()
    low_nibble = read_nibble_clocked()
    return (high_nibble << 4) | low_nibble


def grant_clock():
    """データとして数えないGrant Clockを1回生成する。"""
    clock_pulse()


def wait_req_level(level, timeout_us, context):
    """REQが指定レベルになるまでwraparound安全に待つ。"""
    start = ticks_us()
    while req_pin.value() != level:
        if ticks_diff(ticks_us(), start) >= timeout_us:
            raise ProtocolTimeout(context)
        sleep_us(POLL_INTERVAL_US)


def recover_bus():
    """タイムアウト時はRP2040の出力を先に解放してCLKをLowへ戻す。"""
    set_data_input()
    clk_pin.value(0)


def transfer(request_bytes, request_length, response_bytes, response_length):
    """固定長要求を送信し、Grant後に応答を事前確保バッファへ受信する。"""
    clk_pin.value(0)

    try:
        # REQ解除後にもガード時間を置いてからRP2040が所有する
        wait_req_level(0, REQ_RELEASE_TIMEOUT_US, "REQ解除待ちタイムアウト")
        sleep_us(TURNAROUND_GUARD_US)
        set_data_output()

        for index in range(request_length):
            send_byte(request_bytes[index])

        # FPGAは要求byte境界でREQをアサートする
        wait_req_level(1, REQ_ASSERT_TIMEOUT_US, "REQ待ちタイムアウト")

        # RP2040をHi-ZにしてからGrant Clockを送る
        set_data_input()
        sleep_us(TURNAROUND_GUARD_US)
        grant_clock()
        sleep_us(TURNAROUND_GUARD_US)

        # data_oeはRP2040から見えないため、REQ保持を返信開始条件とする
        wait_req_level(1, REPLY_START_TIMEOUT_US, "FPGA返信開始待ちタイムアウト")

        for index in range(response_length):
            response_bytes[index] = receive_byte()

        # 最後の返信ニブル後にFPGAがdataとREQを解放する
        wait_req_level(0, REPLY_COMPLETE_TIMEOUT_US, "FPGA返信完了待ちタイムアウト")
        wait_req_level(0, REQ_RELEASE_TIMEOUT_US, "REQ解除待ちタイムアウト")
        sleep_us(TURNAROUND_GUARD_US)
    except ProtocolTimeout:
        recover_bus()
        raise


def format_byte(value):
    if value is None:
        return "--"
    return "0x{:02X}".format(value)


def run_soft_reset_test():
    start = ticks_us()
    status = None
    error = None

    try:
        request_buffer[0] = 0x00
        transfer(request_buffer, 1, response_buffer, 1)
        status = response_buffer[0]
    except ProtocolTimeout as caught:
        error = caught

    elapsed = ticks_diff(ticks_us(), start)
    passed = error is None and status == 0x00
    print(
        "COMMAND=SOFT_RESET TX=0x00 RX={} EXPECT=0x00 STATUS={} PASS={} TIME_US={}".format(
            format_byte(status),
            format_byte(status),
            "PASS" if passed else "FAIL",
            elapsed,
        )
    )
    if error is not None:
        print("ERROR COMMAND=SOFT_RESET DETAIL={}".format(error))
    return passed


def run_invert_test(value, print_result=True):
    start = ticks_us()
    status = None
    result = None
    error = None

    try:
        request_buffer[0] = 0x01
        request_buffer[1] = value
        transfer(request_buffer, 2, response_buffer, 2)
        status = response_buffer[0]
        result = response_buffer[1]
    except ProtocolTimeout as caught:
        error = caught

    expected = value ^ 0xFF
    elapsed = ticks_diff(ticks_us(), start)
    passed = error is None and status == 0x00 and result == expected

    if print_result:
        print(
            "COMMAND=INVERT TX={} RX={} EXPECT={} STATUS={} PASS={} TIME_US={}".format(
                format_byte(value),
                format_byte(result),
                format_byte(expected),
                format_byte(status),
                "PASS" if passed else "FAIL",
                elapsed,
            )
        )
        if error is not None:
            print("ERROR COMMAND=INVERT TX={} DETAIL={}".format(format_byte(value), error))

    return passed, error


def run_loop_test():
    start = ticks_us()
    loop_pass = 0
    loop_fail = 0
    loop_count = 0

    for index in range(LOOP_TEST_COUNT):
        value = index & 0xFF
        passed, error = run_invert_test(value, print_result=False)
        loop_count += 1
        if passed:
            loop_pass += 1
        else:
            loop_fail += 1
            if error is not None:
                print(
                    "LOOP_ERROR INDEX={} TX={} DETAIL={}".format(
                        index, format_byte(value), error
                    )
                )
                # タイムアウト後は連続性が失われるため、その場で終了する
                break

    elapsed = ticks_diff(ticks_us(), start)
    print(
        "LOOP COUNT={} PASS={} FAIL={} TIME_US={}".format(
            loop_count, loop_pass, loop_fail, elapsed
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
    except ProtocolTimeout as caught:
        error = caught

    elapsed = ticks_diff(ticks_us(), start)
    data_ok = error is None and first_mismatch is None
    passed = data_ok and status == 0x00

    print(
        "COMMAND=BURST_INVERT LENGTH={} STATUS={} DATA_OK={} FIRST_MISMATCH={} PASS={} TIME_US={}".format(
            length,
            format_byte(status),
            "PASS" if data_ok else "FAIL",
            "NONE" if first_mismatch is None else first_mismatch,
            "PASS" if passed else "FAIL",
            elapsed,
        )
    )

    if first_mismatch is not None:
        print(
            "INDEX={} TX={} RX={} EXPECT={}".format(
                first_mismatch,
                format_byte(burst_tx[first_mismatch]),
                format_byte(response_buffer[first_mismatch + 1]),
                format_byte(burst_expected[first_mismatch]),
            )
        )
    if error is not None:
        print(
            "ERROR COMMAND=BURST_INVERT LENGTH={} DETAIL={}".format(length, error)
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
        except ProtocolTimeout as caught:
            error = caught

        loop_count += 1
        passed = error is None and status == 0x00 and first_mismatch is None
        if passed:
            loop_pass += 1
        else:
            loop_fail += 1
            if first_mismatch is not None:
                print(
                    "BURST_LOOP_ERROR PACKET={} INDEX={} TX={} RX={} EXPECT={}".format(
                        packet_index,
                        first_mismatch,
                        format_byte(burst_tx[first_mismatch]),
                        format_byte(response_buffer[first_mismatch + 1]),
                        format_byte(burst_expected[first_mismatch]),
                    )
                )
            elif error is None:
                print(
                    "BURST_LOOP_ERROR PACKET={} STATUS={}".format(
                        packet_index, format_byte(status)
                    )
                )

            if error is not None:
                print(
                    "BURST_LOOP_ERROR PACKET={} DETAIL={}".format(packet_index, error)
                )
                # タイムアウト後は連続性が失われるため、その場で終了する
                break

    elapsed = ticks_diff(ticks_us(), start)
    print(
        "BURST_LOOP COUNT={} PASS={} FAIL={} TIME_US={}".format(
            loop_count, loop_pass, loop_fail, elapsed
        )
    )
    return loop_count, loop_pass, loop_fail


def main():
    total_start = ticks_us()
    program_fpga()
    initialize_bus()

    print(
        "CONFIG BITSTREAM={} DATA_PINS={} CLK_PIN={} REQ_PIN={} CLK_HALF_PERIOD_US={} TURNAROUND_GUARD_US={}".format(
            BITSTREAM,
            DATA_PIN_NUMBERS,
            CLK_PIN_NUMBER,
            REQ_PIN_NUMBER,
            CLK_HALF_PERIOD_US,
            TURNAROUND_GUARD_US,
        )
    )

    soft_reset_pass = run_soft_reset_test()

    invert_pass = 0
    invert_fail = 0
    for value in INVERT_TEST_VALUES:
        passed, _ = run_invert_test(value)
        if passed:
            invert_pass += 1
        else:
            invert_fail += 1

    loop_count, loop_pass, loop_fail = run_loop_test()

    burst_pass = 0
    burst_fail = 0
    for length in BURST_LENGTHS:
        passed, _ = run_burst_test(length)
        if passed:
            burst_pass += 1
        else:
            burst_fail += 1

    burst_loop_count, burst_loop_pass, burst_loop_fail = run_burst_loop_test()
    overall_pass = (
        soft_reset_pass
        and invert_fail == 0
        and loop_count == LOOP_TEST_COUNT
        and loop_fail == 0
        and burst_pass == len(BURST_LENGTHS)
        and burst_fail == 0
        and burst_loop_count == BURST_LOOP_COUNT
        and burst_loop_fail == 0
    )
    total_elapsed = ticks_diff(ticks_us(), total_start)

    print(
        "SUMMARY SOFT_RESET={} INVERT_PASS={} INVERT_FAIL={} LOOP_COUNT={} LOOP_PASS={} LOOP_FAIL={} BURST_PASS={} BURST_FAIL={} BURST_LOOP_COUNT={} BURST_LOOP_PASS={} BURST_LOOP_FAIL={} {} TIME_US={}".format(
            "PASS" if soft_reset_pass else "FAIL",
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
            "PASS" if overall_pass else "FAIL",
            total_elapsed,
        )
    )


if __name__ == "__main__":
    main()
