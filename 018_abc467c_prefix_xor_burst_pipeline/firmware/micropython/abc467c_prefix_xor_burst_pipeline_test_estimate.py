from machine import Pin, SPI
import gc
import time
import shrike


# ===== 共通部分：bitstream名とShrike-Liteのピン設定 =====
BITSTREAM = "abc467c_prefix_xor_burst_pipeline.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

# ===== SPI転送設定 =====
SPI_BAUDRATE = 4_000_000
PACKAGE_SIZE = 256

# ===== ベンチマーク設定 =====
TIME_LIMIT_US = 2_000_000
MIN_N = 2

# 現在の通信形式では、Nを18bitで送信する。
# そのため、FPGA側を変更せずに扱える最大値は2^18-1。
PROTOCOL_MAX_N = (1 << 18) - 1
MAX_N = PROTOCOL_MAX_N

INITIAL_N = 1_024
ESTIMATE_UNIT = 100


# ===== 共通部分：FPGAへのbitstream書き込みとリセット =====
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)
reset_pin.value(0)
time.sleep_ms(100)
reset_pin.value(1)
time.sleep_ms(100)


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


# ===== ABC467C固有処理 =====
NOP = 0b000
SEND_N_17_15 = 0b001
SEND_N_14_10 = 0b010
SEND_N_9_5 = 0b011
SEND_N_4_0 = 0b100
SEND_A1 = 0b101
RESET = 0b111


def make_command(command, data=0):
    return (command << 5) | (data & 0x1F)


NOP_BYTE = make_command(NOP)
RESET_BYTE = make_command(RESET)
PACKED_ZERO = 0x00


# ===== 再利用するSPI送受信バッファ =====

# RESETと答え受信に使用する1byteバッファ
single_tx = bytearray(1)
single_rx = bytearray(1)

# NとA_1を送る5byteヘッダ
header_tx = bytearray(5)
header_rx = bytearray(5)

# ベンチマーク用の4組ゼロデータパッケージ
packed_zero_tx = bytearray(PACKAGE_SIZE)
packed_zero_rx = bytearray(PACKAGE_SIZE)

for i in range(PACKAGE_SIZE):
    packed_zero_tx[i] = PACKED_ZERO


# ===== SPI送受信 =====

def spi_transfer(tx_buffer, rx_buffer):
    # 複数byteを一度のwrite_readinto()で転送する。
    cs.value(0)
    spi.write_readinto(tx_buffer, rx_buffer)
    cs.value(1)


def spi_exchange_1byte(value):
    # RESETと答え受信では、再利用する1byteバッファを使用する。
    single_tx[0] = value
    spi_transfer(single_tx, single_rx)
    return single_rx[0]


# ===== ABC467C固有の通信処理 =====

def set_header(n, a_first):
    if n < MIN_N or n > PROTOCOL_MAX_N:
        raise ValueError("N is outside the 18bit protocol range")

    header_tx[0] = make_command(
        SEND_N_17_15,
        (n >> 15) & 0x07
    )
    header_tx[1] = make_command(
        SEND_N_14_10,
        (n >> 10) & 0x1F
    )
    header_tx[2] = make_command(
        SEND_N_9_5,
        (n >> 5) & 0x1F
    )
    header_tx[3] = make_command(
        SEND_N_4_0,
        n & 0x1F
    )
    header_tx[4] = make_command(
        SEND_A1,
        a_first
    )


def reset_problem():
    # RESETの処理結果を次のNOPでSPI送信側へ反映させる。
    spi_exchange_1byte(RESET_BYTE)
    spi_exchange_1byte(NOP_BYTE)


def receive_answer():
    rx_hi = spi_exchange_1byte(NOP_BYTE)
    rx_mid = spi_exchange_1byte(NOP_BYTE)
    rx_lo = spi_exchange_1byte(NOP_BYTE)

    valid = (rx_hi >> 7) & 0x01
    count_ok = (rx_hi >> 6) & 0x01
    protocol_error = (rx_hi >> 5) & 0x01
    answer = (
        ((rx_hi & 0x03) << 16)
        | (rx_mid << 8)
        | rx_lo
    )

    return (
        valid,
        count_ok,
        protocol_error,
        answer,
        (rx_hi, rx_mid, rx_lo)
    )


# ===== 機能テスト用の入力stream作成 =====

def build_input_stream(a_values, b_values):
    n = len(a_values)

    if n < MIN_N:
        raise ValueError("N must be at least 2")

    if n > PROTOCOL_MAX_N:
        raise ValueError("N exceeds the 18bit protocol range")

    if len(b_values) != n - 1:
        raise ValueError("len(B) must be N - 1")

    # N送信4byte、A_1送信1byte、4組データ送信
    data_byte_count = (n - 1 + 3) // 4
    tx_stream = bytearray(5 + data_byte_count)
    index = 0

    tx_stream[index] = make_command(
        SEND_N_17_15,
        (n >> 15) & 0x07
    )
    index += 1

    tx_stream[index] = make_command(
        SEND_N_14_10,
        (n >> 10) & 0x1F
    )
    index += 1

    tx_stream[index] = make_command(
        SEND_N_9_5,
        (n >> 5) & 0x1F
    )
    index += 1

    tx_stream[index] = make_command(
        SEND_N_4_0,
        n & 0x1F
    )
    index += 1

    tx_stream[index] = make_command(
        SEND_A1,
        a_values[0]
    )
    index += 1

    pair_index = 0

    while pair_index < n - 1:
        packed_data = 0

        # 上位側から順に、各2bitをA、Bの順で格納する。
        for position in range(4):
            if pair_index < n - 1:
                pair_data = (
                    ((a_values[pair_index + 1] & 0x01) << 1)
                    | (b_values[pair_index] & 0x01)
                )
                shift = 6 - (position * 2)
                packed_data |= pair_data << shift
                pair_index += 1

        tx_stream[index] = packed_data
        index += 1

    return tx_stream


def make_packages(tx_stream):
    # パッケージ生成は測定前に行う。
    packages = []
    start = 0
    stream_length = len(tx_stream)

    while start < stream_length:
        end = start + PACKAGE_SIZE

        if end > stream_length:
            end = stream_length

        tx_package = tx_stream[start:end]
        rx_package = bytearray(len(tx_package))
        packages.append((tx_package, rx_package))

        start = end

    return packages


def send_packages(packages):
    for tx_package, rx_package in packages:
        spi_transfer(tx_package, rx_package)


def run_test_case(name, a_values, b_values):
    n = len(a_values)
    expected = solve_reference(a_values, b_values)

    # 入力streamとパッケージは測定前に作る。
    tx_stream = build_input_stream(
        a_values,
        b_values
    )
    packages = make_packages(tx_stream)

    reset_problem()

    # GCの実行時間はTIME_USに含めない。
    gc.collect()

    start_us = time.ticks_us()

    send_packages(packages)
    (
        valid,
        count_ok,
        protocol_error,
        result,
        rx_bytes
    ) = receive_answer()

    elapsed_us = time.ticks_diff(
        time.ticks_us(),
        start_us
    )

    passed = (
        valid == 1
        and count_ok == 1
        and protocol_error == 0
        and result == expected
    )
    status = "PASS" if passed else "FAIL"

    print(
        "NAME={} N={} STREAM_BYTES={} PACKAGES={} "
        "RX=[0x{:02X},0x{:02X},0x{:02X}] "
        "VALID={} COUNT_OK={} PROTOCOL_ERROR={} "
        "EXPECT={} RESULT={} {} TIME_US={}".format(
            name,
            n,
            len(tx_stream),
            len(packages),
            rx_bytes[0],
            rx_bytes[1],
            rx_bytes[2],
            valid,
            count_ok,
            protocol_error,
            expected,
            result,
            status,
            elapsed_us
        )
    )

    return passed


# ===== 参照用のABC467C計算 =====

def solve_reference(a_values, b_values):
    value0 = 0
    value1 = 1

    cost0 = 1 if value0 != a_values[0] else 0
    cost1 = 1 if value1 != a_values[0] else 0

    for i in range(len(b_values)):
        value0 ^= b_values[i]
        value1 ^= b_values[i]

        if value0 != a_values[i + 1]:
            cost0 += 1

        if value1 != a_values[i + 1]:
            cost1 += 1

    return cost0 if cost0 < cost1 else cost1


def make_boundary_test_case(n):
    # 256byte送信境界を確認する機能テストを作る。
    a_values = [0] * n
    b_values = [0] * (n - 1)

    for i in range(n):
        a_values[i] = (
            i
            ^ (i >> 2)
            ^ (i >> 5)
        ) & 0x01

    for i in range(n - 1):
        b_values[i] = (
            (i * 3)
            ^ (i >> 1)
            ^ 1
        ) & 0x01

    return (
        "package_boundary_n{}".format(n),
        a_values,
        b_values
    )


def make_pseudo_random_test_case(n, seed):
    # 固定seedの疑似乱数で再現可能な機能テストを作る。
    a_values = [0] * n
    b_values = [0] * (n - 1)
    state = seed & 0x7FFFFFFF

    for i in range(n):
        state = (
            (state * 1103515245 + 12345)
            & 0x7FFFFFFF
        )
        a_values[i] = (state >> 15) & 0x01

    for i in range(n - 1):
        state = (
            (state * 1103515245 + 12345)
            & 0x7FFFFFFF
        )
        b_values[i] = (state >> 15) & 0x01

    return (
        "pseudo_random_n{}".format(n),
        a_values,
        b_values
    )


# ===== ベンチマーク用のゼロ入力転送 =====

def prepare_zero_case(n):
    # 測定中にバッファを生成しないよう、
    # ヘッダと最終パッケージを測定前に準備する。
    set_header(n, 0)

    data_byte_count = (n - 1 + 3) // 4
    full_package_count = data_byte_count // PACKAGE_SIZE
    tail_count = data_byte_count % PACKAGE_SIZE

    if tail_count == 0:
        tail_tx = None
        tail_rx = None
    else:
        tail_tx = bytearray(tail_count)
        tail_rx = bytearray(tail_count)

        for i in range(tail_count):
            tail_tx[i] = PACKED_ZERO

    return (
        full_package_count,
        tail_count,
        tail_tx,
        tail_rx
    )


def send_zero_case(
    full_package_count,
    tail_count,
    tail_tx,
    tail_rx
):
    # NとA_1を5byteまとめて送信する。
    spi_transfer(header_tx, header_rx)

    # 4組ゼロデータを256byte単位で繰り返し送信する。
    for _ in range(full_package_count):
        spi_transfer(packed_zero_tx, packed_zero_rx)

    # 最後の端数だけ短いパッケージで送信する。
    if tail_count != 0:
        spi_transfer(tail_tx, tail_rx)


def measure_zero_case(n, label="SEARCH"):
    (
        full_package_count,
        tail_count,
        tail_tx,
        tail_rx
    ) = prepare_zero_case(n)

    reset_problem()

    # 各測定の直前にGCを実行する。
    # バッファ生成時間とGC時間はTIME_USに含めない。
    gc.collect()

    start_us = time.ticks_us()

    send_zero_case(
        full_package_count,
        tail_count,
        tail_tx,
        tail_rx
    )

    (
        valid,
        count_ok,
        protocol_error,
        answer,
        _
    ) = receive_answer()

    elapsed_us = time.ticks_diff(
        time.ticks_us(),
        start_us
    )

    correct = (
        valid == 1
        and count_ok == 1
        and protocol_error == 0
        and answer == 0
    )
    within_limit = (
        correct
        and elapsed_us <= TIME_LIMIT_US
    )

    package_count = (
        1
        + full_package_count
        + (1 if tail_count != 0 else 0)
    )

    print(
        "{} N={} PACKAGES={} TIME_US={} VALID={} COUNT_OK={} "
        "PROTOCOL_ERROR={} ANSWER={} {}".format(
            label,
            n,
            package_count,
            elapsed_us,
            valid,
            count_ok,
            protocol_error,
            answer,
            "PASS" if within_limit else "FAIL"
        )
    )

    return within_limit, elapsed_us, correct


# ===== 指数探索と二分探索 =====

def find_upper_bound():
    # まず指数探索で2秒を超える最初のNを探す。
    # 現在の18bit通信形式で扱える最大値まで探索する。
    n = INITIAL_N
    last_pass = MIN_N

    while True:
        if n > MAX_N:
            n = MAX_N

        passed, _, correct = measure_zero_case(
            n,
            "EXPAND"
        )

        if not correct:
            raise RuntimeError(
                "FPGA reply error during benchmark"
            )

        if not passed:
            return last_pass, n

        last_pass = n

        if n == MAX_N:
            # 2秒境界へ到達する前に18bit上限へ到達した。
            return MAX_N, MAX_N

        n *= 2


def binary_search_limit(low_pass, high_fail):
    if low_pass == MAX_N:
        return MAX_N, None

    low = low_pass
    high = high_fail

    # 実測値にはばらつきがあるため、厳密な最大値ではなく
    # おおよその2秒境界を得る目的で二分探索する。
    while high - low > 1:
        mid = (low + high) // 2

        passed, _, correct = measure_zero_case(
            mid,
            "BINARY"
        )

        if not correct:
            raise RuntimeError(
                "FPGA reply error during benchmark"
            )

        if passed:
            low = mid
        else:
            high = mid

    return low, high


def round_to_estimate_unit(value):
    estimated = (
        (value + (ESTIMATE_UNIT // 2))
        // ESTIMATE_UNIT
    ) * ESTIMATE_UNIT

    if estimated < MIN_N:
        return MIN_N

    if estimated > MAX_N:
        return MAX_N

    return estimated


# ===== 機能テスト =====

TEST_CASES = [
    (
        "official_sample_1",
        [1, 1, 1],
        [1, 1]
    ),
    (
        "official_sample_2",
        [1, 1],
        [0]
    ),
    (
        "official_sample_3",
        [0, 0, 0, 1, 1, 0, 1, 0, 1, 0],
        [0, 1, 0, 1, 0, 1, 0, 1, 0]
    ),
    (
        "all_zero",
        [0, 0, 0, 0, 0],
        [0, 0, 0, 0]
    ),
    (
        "two_elements_mismatch",
        [0, 1],
        [0]
    ),
    (
        "tail_valid_2",
        [0, 1, 0],
        [1, 0]
    ),
    (
        "tail_valid_3",
        [0, 1, 1, 1],
        [1, 0, 1]
    ),
    (
        "tail_valid_4",
        [0, 1, 1, 0, 0],
        [1, 0, 1, 1]
    ),
    (
        "second_package_tail_valid_1",
        [0, 1, 1, 0, 1, 0],
        [1, 0, 1, 1, 0]
    ),
    make_boundary_test_case(1005),
    make_boundary_test_case(1006),
    make_pseudo_random_test_case(73, 0x467C),
]


print(
    "CONFIG "
    "SPI_BAUDRATE={} "
    "PACKAGE_SIZE={} "
    "TIME_LIMIT_US={} "
    "MAX_N={} "
    "PROTOCOL_BITS=18".format(
        SPI_BAUDRATE,
        PACKAGE_SIZE,
        TIME_LIMIT_US,
        MAX_N
    )
)

reset_problem()

pass_count = 0

for name, a_values, b_values in TEST_CASES:
    if run_test_case(
        name,
        a_values,
        b_values
    ):
        pass_count += 1

fail_count = len(TEST_CASES) - pass_count

print(
    "FUNCTION_SUMMARY PASS={} FAIL={} TOTAL={}".format(
        pass_count,
        fail_count,
        len(TEST_CASES)
    )
)

if fail_count != 0:
    raise RuntimeError("Functional test failed")


# ===== 2秒前後となるNの推定 =====

# MicroPythonの実行時間にはばらつきがあるため、
# 厳密な最大値ではなく、おおよその目安として扱う。
low_pass, high_fail = find_upper_bound()

raw_pass_n, raw_fail_n = binary_search_limit(
    low_pass,
    high_fail
)

if raw_fail_n is None:
    print(
        "SEARCH_BOUNDARY "
        "PASS_N={} "
        "FAIL_N=NONE "
        "LIMIT_REASON=18BIT_PROTOCOL_MAX".format(
            raw_pass_n
        )
    )

    print(
        "BENCHMARK_ESTIMATE "
        "TIME_LIMIT_US={} "
        "AT_LEAST_N={} "
        "PROTOCOL_MAX_REACHED=1".format(
            TIME_LIMIT_US,
            raw_pass_n
        )
    )
else:
    estimated_n = round_to_estimate_unit(
        raw_pass_n
    )

    print(
        "SEARCH_BOUNDARY PASS_N={} FAIL_N={}".format(
            raw_pass_n,
            raw_fail_n
        )
    )

    print(
        "BENCHMARK_ESTIMATE "
        "ESTIMATED_N_AROUND_2S={} "
        "ROUND_UNIT={} "
        "PROTOCOL_MAX_REACHED=0".format(
            estimated_n,
            ESTIMATE_UNIT
        )
    )
