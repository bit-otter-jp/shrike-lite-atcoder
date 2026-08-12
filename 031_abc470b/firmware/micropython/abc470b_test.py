from machine import Pin, SPI
import time
import shrike


# ===== 共通部分：bitstream名とShrike-Liteのピン設定 =====
BITSTREAM = "abc470b.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

# ===== SPI転送設定 =====
SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 256
MAX_REPLY_POLLS = 16

CMD_NOP = 0x00
CMD_RESET = 0xFF
CMD_START = 0xFE
RESET_ACK = 0x5A
START_ACK = 0xA5
VALID_MASK = 0x80
ANSWER_MASK = 0x7F


# ===== 共通部分：FPGAへのbitstream書き込みとリセット =====
# FPGAへの書き込みは最初の1回だけ行い、各ケースではSPI RESETを使用する。
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)


def reset_fpga_pin():
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)


reset_fpga_pin()


# ===== 共通部分：SPI Masterの初期化 =====
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
# コマンドと、Nを含む最大101byteの問題データで再利用する。
tx_buffer = bytearray(MAX_PACKAGE_SIZE)
rx_buffer = bytearray(MAX_PACKAGE_SIZE)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)


# ===== 1～256byteの可変長SPIバースト転送 =====
def spi_transfer(length):
    # 範囲外の長さはCSを操作する前に拒否する。
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("SPI transfer length must be between 1 and 256")

    # 実際の長さだけを1回で転送し、パッケージ中はCSをLowに保持する。
    cs.value(0)
    try:
        spi.write_readinto(tx_view[:length], rx_view[:length])
    finally:
        # SPIで例外が発生しても、パッケージ間は必ずCSをHighへ戻す。
        cs.value(1)


def spi_exchange_1byte(value):
    # 1byte転送でも同じ256byteバッファの先頭を再利用する。
    tx_buffer[0] = value
    spi_transfer(1)
    return rx_buffer[0]


TEST_CASES = (
    ("sample1", (3, 1, 2, 1), 2, True),
    ("sample2", (3, 3, 3, 3, 3), 0, True),
    ("sample3", (4, 2, 3, 3, 4, 1, 2, 7, 1), 7, True),
    ("min", (1,), 0, True),
    ("all_same_max", (100,) * 100, 0, True),
    ("all_different", tuple(range(1, 101)), 99, True),
    ("two_colors_equal", (1,) * 50 + (2,) * 50, 50, True),
    ("max_updates_late", (1, 2, 3, 4, 5, 6, 7, 8, 9, 9), 8, True),
    ("repeated_consecutive", (1, 1, 1, 1, 2, 2, 2, 2), 4, True),
    ("start_reuse_first", (1, 1, 1, 2), 1, True),
    ("start_reuse_second", (1, 2, 3, 4), 3, False),
)


def validate_case(name, colors, expected):
    n = len(colors)
    if n < 1 or n > 100:
        raise ValueError("{}: N is out of range".format(name))
    if expected < 0 or expected >= n:
        raise ValueError("{}: EXPECT is out of range".format(name))
    for color in colors:
        if color < 1 or color > n:
            raise ValueError("{}: color is out of range".format(name))


def summarize_colors(colors):
    if len(colors) <= 16:
        return " ".join(str(color) for color in colors)
    head = " ".join(str(color) for color in colors[:8])
    tail = " ".join(str(color) for color in colors[-8:])
    return "{} ... {} (count={})".format(head, tail, len(colors))


def poll_answer():
    # 最後のread-modify-writeと回答確定を、上限付きNOPポーリングで待つ。
    answer_rx = 0
    for poll_count in range(1, MAX_REPLY_POLLS + 1):
        answer_rx = spi_exchange_1byte(CMD_NOP)
        if answer_rx & VALID_MASK:
            return answer_rx, poll_count
    return answer_rx, MAX_REPLY_POLLS


def run_case(name, colors, expected, reset_before):
    start_us = time.ticks_us()
    n = len(colors)
    result = -1
    valid = False
    passed = False
    answer_rx = 0
    poll_count = 0
    reset_command_rx = -1
    reset_ack_rx = -1
    start_command_rx = 0
    start_ack_rx = 0
    data_reply_ok = False
    error_text = ""

    try:
        validate_case(name, colors, expected)

        # コマンドへの応答は次の1byteで受信する。
        if reset_before:
            reset_command_rx = spi_exchange_1byte(CMD_RESET)
            reset_ack_rx = spi_exchange_1byte(CMD_NOP)

        start_command_rx = spi_exchange_1byte(CMD_START)

        # NとC全体を、順序を保った1回のCS Lowバーストとして送信する。
        tx_buffer[0] = n
        for index in range(n):
            tx_buffer[index + 1] = colors[index]
        spi_transfer(n + 1)
        start_ack_rx = rx_buffer[0]

        data_reply_ok = True
        for index in range(1, n + 1):
            if rx_buffer[index] != 0x00:
                data_reply_ok = False
                break

        answer_rx, poll_count = poll_answer()
        valid = (answer_rx & VALID_MASK) != 0
        result = answer_rx & ANSWER_MASK

        passed = (
            (not reset_before or reset_ack_rx == RESET_ACK)
            and start_ack_rx == START_ACK
            and data_reply_ok
            and valid
            and result == expected
        )
    except Exception as error:
        # 1ケースの通信失敗で、後続ケースの試験を止めない。
        error_text = "{}: {}".format(type(error).__name__, error)

    elapsed_us = time.ticks_diff(time.ticks_us(), start_us)

    print("NAME={}".format(name))
    print("N={}".format(n))
    print("C={}".format(summarize_colors(colors)))
    print("RESULT={}".format(result))
    print("EXPECT={}".format(expected))
    print("VALID={}".format(1 if valid else 0))
    print("PASS={}".format(1 if passed else 0))
    print("TIME_US={}".format(elapsed_us))
    print("RX=0x{:02X}".format(answer_rx))
    print("POLL_COUNT={}".format(poll_count))
    if reset_before:
        print("RESET_ACK_RX=0x{:02X}".format(reset_ack_rx))
    else:
        print("RESET_ACK_RX=SKIP")
    print("START_ACK_RX=0x{:02X}".format(start_ack_rx))
    print("DATA_REPLY_OK={}".format(1 if data_reply_ok else 0))
    if error_text:
        print("ERROR={}".format(error_text))
    if not passed:
        print(
            "DIAG RESET_COMMAND_RX=0x{:02X} "
            "START_COMMAND_RX=0x{:02X}".format(
                reset_command_rx & 0xFF,
                start_command_rx
            )
        )
    print("")

    return passed


print(
    "CONFIG BITSTREAM={} SPI_BAUDRATE={} MAX_REPLY_POLLS={}".format(
        BITSTREAM,
        SPI_BAUDRATE,
        MAX_REPLY_POLLS
    )
)

pass_count = 0
for test_case in TEST_CASES:
    if run_case(
        test_case[0],
        test_case[1],
        test_case[2],
        test_case[3]
    ):
        pass_count += 1

fail_count = len(TEST_CASES) - pass_count
print(
    "SUMMARY PASS={} FAIL={} RESULT={}".format(
        pass_count,
        fail_count,
        "PASS" if fail_count == 0 else "FAIL"
    )
)
