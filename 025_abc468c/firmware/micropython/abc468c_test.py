from machine import Pin, SPI
import time
import shrike


# ===== ビットストリーム名とShrike-Liteのピン設定 =====
BITSTREAM = "abc468c.bin"

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
    # 送信値を共通バッファへ格納し、受信値を通常のリストで返す。
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


def pack_permutation(permutation):
    # 順列を上位ニブル、下位ニブルの順で2要素ずつ格納する。
    packed = bytearray((len(permutation) + 1) // 2)

    for index in range(0, len(permutation), 2):
        upper = permutation[index]
        lower = 0
        if index + 1 < len(permutation):
            lower = permutation[index + 1]
        packed[index // 2] = (upper << 4) | lower

    return packed


# ===== FPGAとは異なる方法で期待値を求める参照実装 =====
def factorial(value):
    result = 1
    for number in range(2, value + 1):
        result *= number
    return result


def reference_rank(permutation):
    # 未使用数字のリスト内位置を使い、各桁の寄与を乗算で求める。
    available = list(range(1, len(permutation) + 1))
    rank = 0

    for index in range(len(permutation)):
        value = permutation[index]
        smaller_count = available.index(value)
        rank += smaller_count * factorial(len(permutation) - index - 1)
        available.pop(smaller_count)

    return rank


def reference_answer(p, q):
    difference = reference_rank(q) - reference_rank(p) - 1
    if difference > 0:
        return difference
    return 0


def format_hex_bytes(values):
    fields = []
    for value in values:
        fields.append("0x{:02X}".format(value))
    return "[" + ", ".join(fields) + "]"


def poll_status(rx_log):
    # 1バイト遅延を考慮し、受信STATUSのVALIDが立つまでNOPを送信する。
    started = time.ticks_us()
    poll_count = 0
    status = 0

    while time.ticks_diff(time.ticks_us(), started) < POLL_TIMEOUT_US:
        status = spi_exchange_1byte(CMD_NOP)
        rx_log.append(status)
        poll_count += 1
        if status & STATUS_VALID:
            break

    return status, poll_count


def run_case(name, n, p, q):
    rx_log = []
    started = time.ticks_us()

    # RESETの応答は次のNOPで受信する。
    rx_log.append(spi_exchange_1byte(CMD_RESET))
    reset_ack_rx = spi_exchange_1byte(CMD_NOP)
    rx_log.append(reset_ack_rx)

    # STARTの応答も次のNOPで受信する。
    rx_log.append(spi_exchange_1byte(CMD_START))
    start_ack_rx = spi_exchange_1byte(CMD_NOP)
    rx_log.append(start_ack_rx)

    # N、P、Qの順で送る。PとQはそれぞれ1回のバーストにする。
    rx_log.append(spi_exchange_1byte(n & 0x0F))

    packed_p = pack_permutation(p)
    packed_q = pack_permutation(q)

    p_rx = spi_exchange_burst(packed_p)
    q_rx = spi_exchange_burst(packed_q)
    rx_log.extend(p_rx)
    rx_log.extend(q_rx)

    status, poll_count = poll_status(rx_log)
    valid = (status & STATUS_VALID) != 0
    error = (status & STATUS_ERROR) != 0

    answer_rx = []
    result = -1
    reply_format_ok = False

    if valid:
        # STATUSを受信したNOPで先頭回答バイトが準備されるため、
        # 続く3バイトのNOPバーストから回答をそのまま受信できる。
        answer_rx = spi_exchange_burst((CMD_NOP, CMD_NOP, CMD_NOP))
        rx_log.extend(answer_rx)
        result = (
            (answer_rx[0] << 16) |
            (answer_rx[1] << 8) |
            answer_rx[2]
        )
        reply_format_ok = (answer_rx[0] & 0xC0) == 0

    expect = reference_answer(p, q)
    elapsed_us = time.ticks_diff(time.ticks_us(), started)

    passed = (
        reset_ack_rx == RESET_ACK and
        start_ack_rx == START_ACK and
        valid and
        not error and
        reply_format_ok and
        result == expect
    )

    print("NAME={}".format(name))
    print("N={}".format(n))
    print("P={}".format(p))
    print("Q={}".format(q))
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


# ===== 公式サンプル、必須境界、追加境界のテストケース =====
TEST_CASES = (
    (
        "n1",
        1,
        (1,),
        (1,)
    ),
    (
        "same_permutation",
        4,
        (2, 1, 4, 3),
        (2, 1, 4, 3)
    ),
    (
        "lexicographic_adjacent",
        3,
        (1, 2, 3),
        (1, 3, 2)
    ),
    (
        "official_sample_1_p_lt_q",
        3,
        (1, 3, 2),
        (3, 1, 2)
    ),
    (
        "official_sample_2_p_gt_q",
        5,
        (5, 4, 2, 1, 3),
        (5, 1, 2, 3, 4)
    ),
    (
        "official_sample_3",
        7,
        (3, 6, 5, 2, 7, 1, 4),
        (4, 1, 5, 7, 2, 3, 6)
    ),
    (
        "p_is_minimum",
        5,
        (1, 2, 3, 4, 5),
        (2, 1, 3, 4, 5)
    ),
    (
        "q_is_maximum",
        5,
        (2, 1, 3, 4, 5),
        (5, 4, 3, 2, 1)
    ),
    (
        "n10_minimum_to_maximum",
        10,
        (1, 2, 3, 4, 5, 6, 7, 8, 9, 10),
        (10, 9, 8, 7, 6, 5, 4, 3, 2, 1)
    ),
    (
        "near_maximum_adjacent",
        4,
        (4, 3, 1, 2),
        (4, 3, 2, 1)
    ),
    (
        "additional_mixed",
        6,
        (2, 6, 1, 5, 3, 4),
        (5, 1, 6, 2, 4, 3)
    )
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
        test_case[3]
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
