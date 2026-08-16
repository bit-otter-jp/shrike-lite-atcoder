from machine import Pin, SPI
import time
import shrike


# ===== 共通部分：bitstream名とShrike-Liteのピン設定 =====
BITSTREAM = "atcoder_spi_template_v3.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

# ===== SPI転送設定 =====
SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 256
BURST_LENGTHS = (1, 2, 31, 32, 255, 256)


# ===== 共通部分：FPGAへのbitstream書き込みとリセット =====
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)


def reset_fpga():
    # 各テストを独立させるため、bitstreamを書き直さずFPGAだけをリセットする。
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


# ===== 1～256byteの可変長SPIバースト転送 =====
def spi_transfer(length):
    # 範囲外の長さはCSを操作する前に拒否する。
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("length must be between 1 and 256")

    # 実際の長さだけを1回で転送し、パッケージ中はCSをLowに保持する。
    cs.value(0)
    try:
        spi.write_readinto(tx_view[:length], rx_view[:length])
    finally:
        # SPIで例外が発生しても、パッケージ間は必ずCSをHighへ戻す。
        cs.value(1)

    return length


def spi_exchange_1byte(value):
    # 1byte転送でも同じ256byteバッファの先頭を再利用する。
    tx_buffer[0] = value
    spi_transfer(1)
    return rx_buffer[0]


# ===== V3の1byte互換テスト =====
def run_1byte_compatibility_test():
    reset_fpga()

    patterns = [0x00, 0x12, 0x7F, 0xFF]
    expected_rx = 0x00
    all_ok = True

    for value in patterns:
        received = spi_exchange_1byte(value)
        passed = received == expected_rx
        all_ok = all_ok and passed

        print(
            "TX=0x{:02X} RX=0x{:02X} EXPECT=0x{:02X} {}".format(
                value,
                received,
                expected_rx,
                "PASS" if passed else "FAIL"
            )
        )

        # MISOは1byte遅延するため、今回の送信結果を次回の期待値にする。
        expected_rx = (value + 1) & 0xFF
        time.sleep_ms(100)

    # 最後に送った0xFFへの返信を、別の1byte転送で読み出す。
    received = spi_exchange_1byte(0x00)
    passed = received == expected_rx
    all_ok = all_ok and passed

    print(
        "TX=0x00 RX=0x{:02X} EXPECT=0x{:02X} {}".format(
            received,
            expected_rx,
            "PASS" if passed else "FAIL"
        )
    )

    return all_ok


# ===== 可変長バースト転送テスト =====
def find_first_burst_mismatch(length):
    # リセット直後の最初のMISOは0x00になる。
    if rx_buffer[0] != 0x00:
        return 0, rx_buffer[0], 0x00

    for index in range(1, length):
        expected = (tx_buffer[index - 1] + 1) & 0xFF
        if rx_buffer[index] != expected:
            return index, rx_buffer[index], expected

    return -1, 0x00, 0x00


def run_burst_test(length):
    reset_fpga()

    # 期待値を簡単に計算できる決定的な送信値を設定する。
    for index in range(length):
        tx_buffer[index] = index & 0xFF

    # 端数転送では転送範囲の直後を番兵にして、境界越えを検出する。
    if length < MAX_PACKAGE_SIZE:
        tx_buffer[length] = 0xA5
        rx_buffer[length] = 0x5A

    last_tx = tx_buffer[length - 1]
    sent_length = spi_transfer(length)

    mismatch_index, mismatch_rx, mismatch_expected = (
        find_first_burst_mismatch(length)
    )
    data_ok = mismatch_index < 0
    length_ok = sent_length == length

    bounds_ok = (
        len(tx_buffer) == MAX_PACKAGE_SIZE
        and len(rx_buffer) == MAX_PACKAGE_SIZE
    )

    if length < MAX_PACKAGE_SIZE:
        bounds_ok = (
            bounds_ok
            and tx_buffer[length] == 0xA5
            and rx_buffer[length] == 0x5A
        )

    # CSを一度Highへ戻した後、別の1byte転送で末尾の返信を読む。
    time.sleep_ms(1)
    tail_received = spi_exchange_1byte(0x00)
    tail_expected = (last_tx + 1) & 0xFF
    tail_ok = tail_received == tail_expected

    case_ok = data_ok and tail_ok and length_ok and bounds_ok

    print(
        "BURST LENGTH={} DATA_OK={} TAIL_OK={} LENGTH_OK={} "
        "BOUNDS_OK={} {}".format(
            length,
            1 if data_ok else 0,
            1 if tail_ok else 0,
            1 if length_ok else 0,
            1 if bounds_ok else 0,
            "PASS" if case_ok else "FAIL"
        )
    )

    if not data_ok:
        print(
            "BURST_MISMATCH INDEX={} RX=0x{:02X} EXPECT=0x{:02X}".format(
                mismatch_index,
                mismatch_rx,
                mismatch_expected
            )
        )

    if not tail_ok:
        print(
            "BURST_TAIL_MISMATCH RX=0x{:02X} EXPECT=0x{:02X}".format(
                tail_received,
                tail_expected
            )
        )

    if not length_ok:
        print(
            "BURST_LENGTH_MISMATCH SENT={} EXPECT={}".format(
                sent_length,
                length
            )
        )

    if not bounds_ok:
        print("BURST_BOUNDS_FAIL LENGTH={}".format(length))

    return case_ok


print(
    "CONFIG SPI_BAUDRATE={} MAX_PACKAGE_SIZE={}".format(
        SPI_BAUDRATE,
        MAX_PACKAGE_SIZE
    )
)

compatibility_ok = run_1byte_compatibility_test()

burst_pass_count = 0
for burst_length in BURST_LENGTHS:
    if run_burst_test(burst_length):
        burst_pass_count += 1

burst_fail_count = len(BURST_LENGTHS) - burst_pass_count
all_tests_ok = compatibility_ok and burst_fail_count == 0

print(
    "SUMMARY 1BYTE={} BURST_PASS={} BURST_FAIL={} {}".format(
        "PASS" if compatibility_ok else "FAIL",
        burst_pass_count,
        burst_fail_count,
        "PASS" if all_tests_ok else "FAIL"
    )
)
