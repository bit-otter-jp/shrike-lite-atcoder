from machine import Pin, SPI
import time
import shrike


# ===== ビットストリーム名とShrike-Liteのピン設定 =====
BITSTREAM = "abc471a.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14


# ===== SPIプロトコルと転送設定 =====
SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 32
POLL_TIMEOUT_US = 100_000

CMD_NOP = 0x00
CMD_START = 0xFE
CMD_RESET = 0xFF
RESET_ACK = 0x5A
START_ACK = 0xA5

STATUS_VALID = 0x80
STATUS_ERROR = 0x40
STATUS_ANSWER = 0x01
STATUS_RESERVED = 0x3E


# ===== FPGAへのビットストリーム書き込みと外部リセット =====
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)


def reset_fpga_pin():
    # ビットストリームを書き直さず、FPGA全体を外部リセットする。
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)


reset_fpga_pin()


# ===== SPIマスターの初期化 =====
cs = Pin(CS, Pin.OUT, value=1)

spi = SPI(
    0,
    baudrate=SPI_BAUDRATE,
    polarity=0,
    phase=0,
    bits=8,
    firstbit=SPI.MSB,
    sck=Pin(SCK),
    mosi=Pin(MOSI),
    miso=Pin(MISO)
)


# ===== 再利用するSPI送受信バッファ =====
tx_buffer = bytearray(MAX_PACKAGE_SIZE)
rx_buffer = bytearray(MAX_PACKAGE_SIZE)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)


def spi_transfer(length):
    # 指定された範囲を、CSをLowに保った1回のバーストで転送する。
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("invalid SPI transfer length")

    cs.value(0)
    try:
        spi.write_readinto(tx_view[:length], rx_view[:length])
    finally:
        cs.value(1)


def spi_exchange_burst(values):
    length = len(values)
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("invalid SPI burst length")

    for index in range(length):
        tx_buffer[index] = values[index]

    spi_transfer(length)

    received = []
    for index in range(length):
        received.append(rx_buffer[index])
    return received


def spi_exchange_1byte(value):
    return spi_exchange_burst((value,))[0]


# ===== FPGAとは独立した期待値計算 =====
def reference_nine(a, b):
    return (
        a + b == 9 or
        a - b == 9 or
        a * b == 9 or
        a == 9 * b
    )


def format_hex_bytes(values):
    fields = []
    for value in values:
        fields.append("0x{:02X}".format(value))
    return "[" + ", ".join(fields) + "]"


def poll_reply(rx_log):
    # SPIの1バイト応答遅延を考慮してVALID付き回答を待つ。
    started = time.ticks_us()
    poll_count = 0
    reply = 0

    while time.ticks_diff(time.ticks_us(), started) < POLL_TIMEOUT_US:
        reply = spi_exchange_1byte(CMD_NOP)
        rx_log.append(reply)
        poll_count += 1
        if reply & STATUS_VALID:
            break

    return reply, poll_count


def run_case(name, a, b, expect_error=False, pre_start_byte=None):
    rx_log = []
    started = time.ticks_us()

    # RESETとSTARTの応答は、それぞれ次のNOPで受信する。
    rx_log.append(spi_exchange_1byte(CMD_RESET))
    reset_ack_rx = spi_exchange_1byte(CMD_NOP)
    rx_log.append(reset_ack_rx)

    # WAIT_STARTでの想定外データをsticky errorテストに利用できる。
    if pre_start_byte is not None:
        rx_log.append(spi_exchange_1byte(pre_start_byte))

    rx_log.append(spi_exchange_1byte(CMD_START))
    start_ack_rx = spi_exchange_1byte(CMD_NOP)
    rx_log.append(start_ack_rx)

    # AとBは、仕様どおりCSをLowに保った1回の2byteバーストで送る。
    rx_log.extend(spi_exchange_burst((a, b)))

    reply, poll_count = poll_reply(rx_log)
    valid = (reply & STATUS_VALID) != 0
    error = (reply & STATUS_ERROR) != 0
    answer = (reply & STATUS_ANSWER) != 0
    reserved_ok = (reply & STATUS_RESERVED) == 0

    expected_nine = reference_nine(a, b)
    result = "Nine" if answer else "Nein"
    expect = "ERROR" if expect_error else (
        "Nine" if expected_nine else "Nein"
    )
    elapsed_us = time.ticks_diff(time.ticks_us(), started)

    passed = (
        reset_ack_rx == RESET_ACK and
        start_ack_rx == START_ACK and
        valid and
        error == expect_error and
        reserved_ok and
        (expect_error or answer == expected_nine)
    )

    print("NAME={}".format(name))
    print("A={}".format(a))
    print("B={}".format(b))
    print("RESULT={}".format(result))
    print("EXPECT={}".format(expect))
    print("VALID={}".format(1 if valid else 0))
    print("ERROR={}".format(1 if error else 0))
    print("PASS={}".format(1 if passed else 0))
    print("TIME_US={}".format(elapsed_us))
    print("RX={}".format(format_hex_bytes(rx_log)))
    print("POLL_COUNT={}".format(poll_count))
    print("RESET_ACK_RX=0x{:02X}".format(reset_ack_rx))
    print("START_ACK_RX=0x{:02X}".format(start_ack_rx))
    print("")

    return passed


# ===== 公式サンプル、各条件、境界、エラー検出 =====
TEST_CASES = (
    ("official_sample_1", 16, 7, False, None),
    ("official_sample_2", 66, 7, False, None),
    ("official_sample_3", 9, 1, False, None),
    ("official_sample_4", 9, 9, False, None),
    ("sum_only", 4, 5, False, None),
    ("sub_only", 16, 7, False, None),
    ("mul_only", 3, 3, False, None),
    ("div_only", 18, 2, False, None),
    ("minimum", 1, 1, False, None),
    ("a_min_b_max", 1, 100, False, None),
    ("a_max_b_min", 100, 1, False, None),
    ("maximum", 100, 100, False, None),
    ("sum_boundary", 8, 1, False, None),
    ("sub_boundary", 10, 1, False, None),
    ("div_larger", 90, 10, False, None),
    ("invalid_a_zero", 0, 1, True, None),
    ("invalid_a_large", 101, 1, True, None),
    ("invalid_b_zero", 1, 0, True, None),
    ("invalid_b_large", 1, 101, True, None),
    ("unexpected_before_start", 66, 7, True, 0x01)
)


print(
    "CONFIG BITSTREAM={} SPI_BAUDRATE={} POLL_TIMEOUT_US={}".format(
        BITSTREAM,
        SPI_BAUDRATE,
        POLL_TIMEOUT_US
    )
)

pass_count = 0
for test_case in TEST_CASES:
    if run_case(
        test_case[0],
        test_case[1],
        test_case[2],
        test_case[3],
        test_case[4]
    ):
        pass_count += 1

fail_count = len(TEST_CASES) - pass_count
print(
    "SUMMARY TOTAL={} PASS={} FAIL={} {}".format(
        len(TEST_CASES),
        pass_count,
        fail_count,
        "PASS" if fail_count == 0 else "FAIL"
    )
)
