from machine import Pin, SPI
import time
import shrike


# ===== 共通部分：bitstream名とShrike-Liteのピン設定 =====
BITSTREAM = "abc468a.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

# ===== SPI転送設定 =====
SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 256

NOP = 0x00
DEBUG = 0xFD
START = 0xFE
SPI_RESET = 0xFF

RESET_ACK = 0x5A
START_ACK = 0xA5


# ===== 共通部分：FPGAへのbitstream書き込みとリセット =====
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)


def reset_fpga():
    # 初回動作を既知の状態にするため、bitstreamを書き直さずFPGAだけをリセットする。
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)


reset_fpga()


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
tx_buffer = bytearray(MAX_PACKAGE_SIZE)
rx_buffer = bytearray(MAX_PACKAGE_SIZE)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)

tx_one = bytearray(1)
rx_one = bytearray(1)


# ===== 1～256byteの可変長SPIバースト転送 =====
def spi_transfer(length):
    # 範囲外の長さはCSを操作する前に拒否する。
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("length must be between 1 and 256")

    # 実際の長さだけを1回で転送し、バースト中はCSをLowに保持する。
    cs.value(0)
    try:
        spi.write_readinto(tx_view[:length], rx_view[:length])
    finally:
        # SPIで例外が発生しても、トランザクション間は必ずCSをHighへ戻す。
        cs.value(1)


def spi_exchange_1byte(value):
    # 制御byteと読出し用ダミーbyteには1byteバッファを再利用する。
    tx_one[0] = value
    cs.value(0)
    try:
        spi.write_readinto(tx_one, rx_one)
    finally:
        cs.value(1)
    return rx_one[0]


# ===== Python側の参照計算 =====
def reference_answer(a):
    n = len(a)
    answer = 0
    for i in range(n - 2):
        if a[i] < a[i + 1] and a[i + 1] > a[i + 2]:
            answer += 1
    return answer


def format_byte(value):
    if value < 0:
        return "NA"
    return "0x{:02X}".format(value)


def print_result(
    name,
    n,
    reset_text,
    start_text,
    reply,
    expected,
    passed,
    elapsed_us,
    error
):
    if reply < 0:
        valid = -1
        answer = -1
    else:
        valid = (reply >> 7) & 0x01
        answer = reply & 0x7F

    print("NAME={}".format(name))
    print("N={}".format(n))
    print("RESET_ACK={}".format(reset_text))
    print("START_ACK={}".format(start_text))
    print("RX={}".format(format_byte(reply)))
    print("VALID={}".format("NA" if valid < 0 else valid))
    print("ANSWER={}".format("NA" if answer < 0 else answer))
    print("EXPECT={}".format(expected))
    print("PASS" if passed else "FAIL")
    print("TIME_US={}".format(elapsed_us))
    if error is not None:
        print("ERROR={}".format(error))
    print("")


# ===== RESET、START、N送信までの共通処理 =====
def begin_protocol(n, before_start):
    # RESETへの返信は次のNOP転送中に受け取る。
    spi_exchange_1byte(SPI_RESET)
    reset_ack = spi_exchange_1byte(NOP)
    if reset_ack != RESET_ACK:
        return reset_ack, -1

    # START前に指定値を送り、WAIT_STARTから遷移しないことも確認できる。
    for value in before_start:
        spi_exchange_1byte(value)

    # STARTへの返信は、その次のN転送中に受け取る。
    spi_exchange_1byte(START)
    start_ack = spi_exchange_1byte(n)
    return reset_ack, start_ack


# ===== ABC468Aの通常テストケース =====
def run_case(name, a, before_start=()):
    n = len(a)
    expected = reference_answer(a)
    started_us = time.ticks_us()
    reset_ack = -1
    start_ack = -1
    reply = -1
    error = None

    try:
        reset_ack, start_ack = begin_protocol(n, before_start)

        # ACKが不正なら配列を送らず、通信開始失敗として扱う。
        if reset_ack == RESET_ACK and start_ack == START_ACK:
            for index in range(n):
                tx_buffer[index] = a[index]

            # A_1～A_NはCS Lowを保持した1回のバーストで送る。
            spi_transfer(n)

            # 回答は配列バーストとは別のトランザクションで読み出す。
            reply = spi_exchange_1byte(NOP)
    except Exception as caught:
        error = caught

    elapsed_us = time.ticks_diff(time.ticks_us(), started_us)
    valid = (reply >> 7) & 0x01 if reply >= 0 else 0
    answer = reply & 0x7F if reply >= 0 else -1
    passed = (
        error is None
        and reset_ack == RESET_ACK
        and start_ack == START_ACK
        and valid == 1
        and answer == expected
    )

    print_result(
        name,
        n,
        format_byte(reset_ack),
        format_byte(start_ack),
        reply,
        expected,
        passed,
        elapsed_us,
        error
    )
    return passed


# ===== 配列受信途中のSPI RESET確認 =====
def run_interrupted_reset_case():
    name = "RESET_DURING_ARRAY"
    interrupted_a = (1, 4, 2, 5, 1)
    recovery_a = (1, 3, 2, 4, 1)
    n = len(recovery_a)
    expected = reference_answer(recovery_a)
    started_us = time.ticks_us()

    reset_ack_1 = -1
    start_ack_1 = -1
    reset_ack_2 = -1
    start_ack_2 = -1
    reply = -1
    error = None

    try:
        reset_ack_1, start_ack_1 = begin_protocol(
            len(interrupted_a),
            ()
        )

        if reset_ack_1 == RESET_ACK and start_ack_1 == START_ACK:
            # 最初の配列を2要素だけ送り、RECEIVE_Aの途中でRESETする。
            tx_buffer[0] = interrupted_a[0]
            tx_buffer[1] = interrupted_a[1]
            spi_transfer(2)
            spi_exchange_1byte(SPI_RESET)
            reset_ack_2 = spi_exchange_1byte(NOP)

            if reset_ack_2 == RESET_ACK:
                spi_exchange_1byte(START)
                start_ack_2 = spi_exchange_1byte(n)

                # 再開時のACKが不正なら回復確認用配列を送らない。
                if start_ack_2 == START_ACK:
                    for index in range(n):
                        tx_buffer[index] = recovery_a[index]
                    spi_transfer(n)
                    reply = spi_exchange_1byte(NOP)
    except Exception as caught:
        error = caught

    elapsed_us = time.ticks_diff(time.ticks_us(), started_us)
    valid = (reply >> 7) & 0x01 if reply >= 0 else 0
    answer = reply & 0x7F if reply >= 0 else -1
    passed = (
        error is None
        and reset_ack_1 == RESET_ACK
        and start_ack_1 == START_ACK
        and reset_ack_2 == RESET_ACK
        and start_ack_2 == START_ACK
        and valid == 1
        and answer == expected
    )

    print_result(
        name,
        n,
        "{}/{}".format(
            format_byte(reset_ack_1),
            format_byte(reset_ack_2)
        ),
        "{}/{}".format(
            format_byte(start_ack_1),
            format_byte(start_ack_2)
        ),
        reply,
        expected,
        passed,
        elapsed_us,
        error
    )
    return passed


# ===== 長い入力を決定的に生成する補助処理 =====
def make_n100_case():
    result = []
    for index in range(100):
        result.append(((index * 29 + 17) % 100) + 1)
    return result


def make_alternating_case():
    result = []
    for index in range(100):
        result.append(1 if (index & 1) == 0 else 100)
    return result


def make_pseudorandom_case(length):
    # 実行ごとに同じ入力になる単純な合同法を使う。
    result = []
    value = 23
    for unused in range(length):
        value = (value * 37 + 11) % 100
        result.append(value + 1)
    return result


# AtCoder公式問題ページで確認した3件のサンプルも含める。
test_cases = (
    ("N3_NO_PEAK", (1, 2, 3), ()),
    ("N3_ONE_PEAK", (1, 3, 2), ()),
    ("ALL_EQUAL", (7, 7, 7, 7, 7, 7), ()),
    ("MONOTONIC_INCREASE", (1, 2, 3, 4, 5, 6), ()),
    ("MONOTONIC_DECREASE", (6, 5, 4, 3, 2, 1), ()),
    ("FIRST_THREE_PEAK", (1, 5, 2, 3, 4), ()),
    ("LAST_THREE_PEAK", (1, 2, 3, 5, 4), ()),
    ("MULTIPLE_PEAKS", (1, 3, 1, 4, 2, 5, 1), ()),
    ("LAST_A_ADDS", (1, 2, 3, 1), ()),
    ("SENTINEL_NO_FALSE_ADD", (100, 1, 1), ()),
    ("N100_MIXED", make_n100_case(), ()),
    ("ALTERNATING_1_100", make_alternating_case(), ()),
    ("DETERMINISTIC_RANDOM", make_pseudorandom_case(37), ()),
    ("OFFICIAL_SAMPLE_1", (3, 1, 4, 1, 5, 2), ()),
    ("OFFICIAL_SAMPLE_2", (1, 1, 1, 2, 1), ()),
    ("OFFICIAL_SAMPLE_3", (7, 3, 9, 8, 10, 3, 1, 5, 5, 4), ()),
    # DEBUGと通常値をSTART前に送っても、N受信へ進まないことを確認する。
    ("DEBUG_BEFORE_START", (1, 3, 2), (DEBUG, 0x03))
)


print(
    "CONFIG SPI_BAUDRATE={} MAX_PACKAGE_SIZE={} CASES={}".format(
        SPI_BAUDRATE,
        MAX_PACKAGE_SIZE,
        len(test_cases) + 1
    )
)

pass_count = 0
fail_count = 0

for case_name, case_a, before_start in test_cases:
    if run_case(case_name, case_a, before_start):
        pass_count += 1
    else:
        fail_count += 1

if run_interrupted_reset_case():
    pass_count += 1
else:
    fail_count += 1

print(
    "SUMMARY PASS={} FAIL={} RESULT={}".format(
        pass_count,
        fail_count,
        "PASS" if fail_count == 0 else "FAIL"
    )
)
