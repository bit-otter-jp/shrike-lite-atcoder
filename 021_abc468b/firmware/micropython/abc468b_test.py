from machine import Pin, SPI
import time
import shrike


# Shrike-Liteのbitstreamと端子割り当て。
BITSTREAM = "abc468b.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 256

CMD_NOP = 0x00
CMD_RESET = 0xFF
CMD_START = 0xFE
RESET_ACK = 0x5A
START_ACK = 0xA5
VALID_MASK = 0x80
ANSWER_MASK = 0x7F


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


# 各コマンドとSのバーストで再利用する。Mは最大100。
tx_buffer = bytearray(MAX_PACKAGE_SIZE)
rx_buffer = bytearray(MAX_PACKAGE_SIZE)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)


def spi_transfer(length):
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("SPI transfer length must be between 1 and 256")

    cs.value(0)
    try:
        spi.write_readinto(tx_view[:length], rx_view[:length])
    finally:
        cs.value(1)


def spi_exchange_1byte(value):
    tx_buffer[0] = value
    spi_transfer(1)
    return rx_buffer[0]


def reference_answer(m, d, s):
    # テスト期待値の生成だけに使用する単純参照実装。
    answer = 0
    for cell in range(m):
        watched = False
        for guard_position in range(m):
            if (
                s[guard_position] == "G"
                and abs(cell - guard_position) <= d
            ):
                watched = True
                break
        if not watched:
            answer += 1
    return answer


TEST_CASES = (
    ("official_sample_1", 7, 1, ".G...GG"),
    ("official_sample_2", 6, 5, "......"),
    ("official_sample_3", 21, 2, "....G...GG.....G....."),
    ("m1_dot", 1, 0, "."),
    ("m1_guard", 1, 0, "G"),
    ("all_dots", 20, 7, "." * 20),
    ("all_guards", 20, 7, "G" * 20),
    ("d_zero", 12, 0, ".G..G....G.."),
    ("leading_guard", 12, 4, "G..........."),
    ("trailing_guard", 12, 4, "...........G"),
    ("separated_guards", 20, 2, "..G.......G.......G."),
    ("overlapping_intervals", 12, 2, "...G..G....."),
    ("touching_intervals", 12, 2, "..G....G...."),
    ("one_cell_gap", 12, 2, "..G.....G..."),
    ("final_character_guard", 10, 1, "..G......G"),
    ("maximum_m_100", 100, 9, "G........." * 10),
)


def validate_case(name, m, d, s):
    if m < 1 or m > 100:
        raise ValueError("{}: M is out of range".format(name))
    if d < 0 or d >= m:
        raise ValueError("{}: D is out of range".format(name))
    if len(s) != m:
        raise ValueError(
            "{}: len(S)={} but M={}".format(name, len(s), m)
        )
    for character in s:
        if character != "." and character != "G":
            raise ValueError("{}: invalid S character".format(name))


def run_case(name, m, d, s):
    validate_case(name, m, d, s)
    expected = reference_answer(m, d, s)

    start_us = time.ticks_us()

    # コマンドへの応答は次の1byteで受信する。
    reset_command_rx = spi_exchange_1byte(CMD_RESET)
    reset_ack_rx = spi_exchange_1byte(CMD_NOP)

    start_command_rx = spi_exchange_1byte(CMD_START)
    start_ack_rx = spi_exchange_1byte(m)

    d_rx = spi_exchange_1byte(d)

    # Sの順序を保ったまま、各文字を直接送信値へ変換する。
    for index in range(m):
        tx_buffer[index] = 0x01 if s[index] == "G" else 0x00
    spi_transfer(m)

    data_reply_ok = True
    for index in range(m):
        if rx_buffer[index] != 0x00:
            data_reply_ok = False
            break

    answer_rx = spi_exchange_1byte(CMD_NOP)
    elapsed_us = time.ticks_diff(time.ticks_us(), start_us)

    valid = (answer_rx & VALID_MASK) != 0
    result = answer_rx & ANSWER_MASK
    reset_ack_ok = reset_ack_rx == RESET_ACK
    start_ack_ok = start_ack_rx == START_ACK
    pre_reply_ok = (
        start_command_rx == 0x00
        and d_rx == 0x00
        and data_reply_ok
    )
    passed = (
        reset_ack_ok
        and start_ack_ok
        and pre_reply_ok
        and valid
        and result == expected
    )

    print("NAME={}".format(name))
    print("M={}".format(m))
    print("D={}".format(d))
    print("S={}".format(s))
    print("RX=0x{:02X}".format(answer_rx))
    print("VALID={}".format(1 if valid else 0))
    print("RESULT={}".format(result))
    print("EXPECT={}".format(expected))
    print("RESET_ACK_RX=0x{:02X}".format(reset_ack_rx))
    print("START_ACK_RX=0x{:02X}".format(start_ack_rx))
    print("PRE_REPLY_OK={}".format(1 if pre_reply_ok else 0))
    print("PASS" if passed else "FAIL")
    print("TIME_US={}".format(elapsed_us))
    print("")

    # コマンド送信時の応答には直前のテスト結果が残る場合があるため判定には使わず、
    # 障害解析用の情報として保持する。
    if not passed:
        print(
            "DIAG RESET_COMMAND_RX=0x{:02X} START_COMMAND_RX=0x{:02X}".format(
                reset_command_rx,
                start_command_rx
            )
        )

    return passed


print(
    "CONFIG BITSTREAM={} SPI_BAUDRATE={}".format(
        BITSTREAM,
        SPI_BAUDRATE
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
    "SUMMARY PASS={} FAIL={} {}".format(
        pass_count,
        fail_count,
        "PASS" if fail_count == 0 else "FAIL"
    )
)
