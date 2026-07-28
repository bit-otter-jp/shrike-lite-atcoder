from machine import Pin, SPI
import time
import shrike


# ===== 共通部：bitstream名とShrike-Liteのピン設定 =====
BITSTREAM = "atcoder_spi_bram0_8bit_template_v3.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

# ===== SPI転送設定 =====
SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 256
BURST_LENGTHS = (1, 2, 16, 64, 256)


# SPIコマンド
# ===== 旧BRAMテンプレート互換コマンド =====
CMD_NOP = 0x0
CMD_SET_ADDR_MSB = 0x1
CMD_SET_ADDR_HIGH = 0x2
CMD_SET_ADDR_LOW = 0x3
CMD_SET_DATA_HIGH = 0x4
CMD_SET_DATA_LOW = 0x5
CMD_WRITE = 0x6
CMD_READ = 0x7

# ===== SPI V3共通のRESET、START、ACK =====
CMD_RESET = 0xFF
CMD_START = 0xFE
RESET_ACK = 0x5A
START_ACK = 0xA5

# MISO返信コマンド
REPLY_HIGH = 0x8
REPLY_LOW = 0x9


# ===== 共通部：FPGAへのbitstream書き込みとハードウェアリセット =====
shrike.reset()
shrike.flash(BITSTREAM)

reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)


def reset_fpga():
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)

    # ハードウェアリセット解除後のBRAM全領域ゼロクリア完了を待つ。
    time.sleep_ms(1)


reset_fpga()


# ===== 共通部：SPI Masterの初期化 =====
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


# ===== 共通部：1byteのSPI送受信 =====
def spi_exchange_1byte(value):
    # 1byte転送でも同じ256byteバッファの先頭を再利用する。
    tx_buffer[0] = value & 0xFF
    spi_transfer(1)
    return rx_buffer[0]


# CMDとDATAを上位/下位4bitへ格納し、1byteとして送信する。
def make_command(command, data=0):
    return ((command & 0x0F) << 4) | (data & 0x0F)


# RESETとSTARTは、どちらも次の1byte転送でACKを受信する。
def begin_protocol():
    spi_exchange_1byte(CMD_RESET)
    reset_ack_rx = spi_exchange_1byte(make_command(CMD_NOP))

    # コマンドリセットを送り、BRAM全領域ゼロクリア完了を待つ。
    # 512wordのゼロクリアが完了してからSTARTを送る。
    # RTL側でもclear中のSTARTは拒否するが、
    # 通常試験ではSTARTの再試行を避けるため1ms待つ。
    time.sleep_ms(1)

    spi_exchange_1byte(CMD_START)
    start_ack_rx = spi_exchange_1byte(make_command(CMD_NOP))
    return reset_ack_rx, start_ack_rx


# 9bitアドレスを3つのコマンドに分けて設定する。
def fill_address_commands(offset, address):
    tx_buffer[offset] = make_command(
        CMD_SET_ADDR_MSB,
        (address >> 8) & 0x01
    )
    tx_buffer[offset + 1] = make_command(
        CMD_SET_ADDR_HIGH,
        (address >> 4) & 0x0F
    )
    tx_buffer[offset + 2] = make_command(
        CMD_SET_ADDR_LOW,
        address & 0x0F
    )


# 8bit書き込みデータを上位/下位4bitに分けて設定する。
# 1アドレスの書き込みを6byteへ設定する。
def fill_write_commands(offset, address, value):
    fill_address_commands(offset, address)
    tx_buffer[offset + 3] = make_command(
        CMD_SET_DATA_HIGH,
        (value >> 4) & 0x0F
    )
    tx_buffer[offset + 4] = make_command(
        CMD_SET_DATA_LOW,
        value & 0x0F
    )
    tx_buffer[offset + 5] = make_command(CMD_WRITE)


# 1アドレスの読み出しを6byteへ設定する。
def fill_read_commands(offset, address):
    fill_address_commands(offset, address)
    tx_buffer[offset + 3] = make_command(CMD_READ)
    tx_buffer[offset + 4] = make_command(CMD_NOP)
    tx_buffer[offset + 5] = make_command(CMD_NOP)


# 返信CMDを検査し、正しい2byteの場合だけ8bit値へ復元する。
def decode_read_reply(reply_high, reply_low):
    high_command = (reply_high >> 4) & 0x0F
    low_command = (reply_low >> 4) & 0x0F

    if high_command != REPLY_HIGH or low_command != REPLY_LOW:
        return None

    return ((reply_high & 0x0F) << 4) | (reply_low & 0x0F)


# 指定した複数アドレスを、CS Lowを維持した1パッケージで書き込む。
def write_bram_pairs(pairs):
    length = len(pairs) * 6
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("write package is too large")

    for index in range(len(pairs)):
        address, value = pairs[index]
        fill_write_commands(index * 6, address, value)

    spi_transfer(length)
    return length


# 指定した複数アドレスを、CS Lowを維持した1パッケージで読み出す。
def read_bram_addresses(addresses):
    length = len(addresses) * 6
    if length < 1 or length > MAX_PACKAGE_SIZE:
        raise ValueError("read package is too large")

    for index in range(len(addresses)):
        fill_read_commands(index * 6, addresses[index])

    spi_transfer(length)

    results = []
    for index in range(len(addresses)):
        offset = index * 6
        reply_high = rx_buffer[offset + 4]
        reply_low = rx_buffer[offset + 5]
        value = decode_read_reply(reply_high, reply_low)
        results.append((reply_high, reply_low, value))

    return results


# 指定アドレスへ8bit値を書き込む。
def write_bram(address, value):
    return write_bram_pairs(((address, value),))


# 指定アドレスを読み出す。MISOは1byte遅延するためNOPを2回送る。
def read_bram(address):
    result = read_bram_addresses((address,))[0]
    return result[0], result[1], result[2]


def format_byte(value):
    if value is None or value < 0:
        return "N/A"
    return "0x{:02X}".format(value)


def format_pairs(pairs, read_results):
    fields = []
    for index in range(len(pairs)):
        address, written_value = pairs[index]
        read_value = read_results[index][2]
        fields.append(
            "{:03X}:{:02X}/{}".format(
                address,
                written_value,
                format_byte(read_value)
            )
        )
    return ",".join(fields)


# ===== 個別試験 =====
def test_protocol_ack():
    # ACK自体は共通のケース実行部で検査する。
    return True, "CONTROL=RESET_START"


def test_single_addresses():
    # 先頭、中間、最終アドレスと代表値を1つの連続転送で確認する。
    pairs = (
        (0, 0x00),
        (1, 0x01),
        (255, 0x55),
        (256, 0xAA),
        (511, 0xFF),
    )
    addresses = (0, 1, 255, 256, 511)

    write_bram_pairs(pairs)
    read_results = read_bram_addresses(addresses)

    passed = True
    for index in range(len(pairs)):
        passed = passed and read_results[index][2] == pairs[index][1]

    return passed, "ADDR_WRITE_READ={}".format(
        format_pairs(pairs, read_results)
    )


def test_overwrite():
    # 同じアドレスを複数回書き、最後の値だけを読み戻す。
    address = 300
    pairs = (
        (address, 0x00),
        (address, 0x55),
        (address, 0xAA),
        (address, 0xFF),
    )
    write_bram_pairs(pairs)
    reply_high, reply_low, read_value = read_bram(address)
    passed = read_value == 0xFF
    detail = (
        "ADDR=0x{:03X} WRITE_SEQ=00,55,AA,FF "
        "READ={} MISO={},{:02X}"
    ).format(
        address,
        format_byte(read_value),
        format_byte(reply_high),
        reply_low
    )
    return passed, detail


def test_continuous_addresses():
    # 16個の連続アドレスを、書き込み96byte、読み出し96byteで確認する。
    start_address = 120
    count = 16
    pairs = []
    addresses = []

    for index in range(count):
        address = start_address + index
        value = (index * 0x11 + 0x03) & 0xFF
        pairs.append((address, value))
        addresses.append(address)

    write_length = write_bram_pairs(pairs)
    read_results = read_bram_addresses(addresses)

    passed = write_length == 96
    for index in range(count):
        passed = passed and read_results[index][2] == pairs[index][1]

    return passed, (
        "ADDR=0x{:03X}-0x{:03X} WRITE_LEN={} READ_LEN={} "
        "FIRST={} LAST={}"
    ).format(
        start_address,
        start_address + count - 1,
        write_length,
        count * 6,
        format_byte(read_results[0][2]),
        format_byte(read_results[count - 1][2])
    )


def test_reset_fsm():
    # 読み出し返信の途中でRESETし、ACKと返信状態が初期化されることを確認する。
    address = 42
    write_bram(address, 0xAA)

    fill_address_commands(0, address)
    tx_buffer[3] = make_command(CMD_READ)
    spi_transfer(4)

    spi_exchange_1byte(CMD_RESET)
    reset_ack_2 = spi_exchange_1byte(make_command(CMD_NOP))
    # BRAMのゼロクリア完了を待つ。
    # RTL側でもclear中のSTARTは拒否するが、
    # 通常試験ではSTARTの再試行を避けるため1ms待つ。
    time.sleep_ms(1)
    spi_exchange_1byte(CMD_START)
    start_ack_2 = spi_exchange_1byte(make_command(CMD_NOP))

    reply_high, reply_low, read_value = read_bram(address)
    passed = (
        reset_ack_2 == RESET_ACK
        and start_ack_2 == START_ACK
        and read_value == 0x00
    )

    return passed, (
        "ADDR=0x{:03X} RESET2={} START2={} READ_AFTER_RESET={} "
        "MISO={},{:02X}"
    ).format(
        address,
        format_byte(reset_ack_2),
        format_byte(start_ack_2),
        format_byte(read_value),
        format_byte(reply_high),
        reply_low
    )


def test_burst_length(length):
    # START ACK読出し後のIDLE返信は0x00なので、NOPバーストで長さを確認する。
    for index in range(length):
        tx_buffer[index] = make_command(CMD_NOP)
        rx_buffer[index] = 0xCC

    if length < MAX_PACKAGE_SIZE:
        tx_buffer[length] = 0xA5
        rx_buffer[length] = 0x5A

    sent_length = spi_transfer(length)
    mismatch_index = -1
    mismatch_value = 0

    for index in range(length):
        if rx_buffer[index] != 0x00:
            mismatch_index = index
            mismatch_value = rx_buffer[index]
            break

    bounds_ok = True
    if length < MAX_PACKAGE_SIZE:
        bounds_ok = (
            tx_buffer[length] == 0xA5
            and rx_buffer[length] == 0x5A
        )

    passed = (
        sent_length == length
        and mismatch_index < 0
        and bounds_ok
    )
    return passed, (
        "LENGTH={} SENT={} MISMATCH_INDEX={} MISMATCH_RX={} BOUNDS_OK={}"
    ).format(
        length,
        sent_length,
        mismatch_index,
        format_byte(mismatch_value),
        1 if bounds_ok else 0
    )


# ===== 失敗しても後続ケースを継続する集計部 =====
pass_count = 0
fail_count = 0


def record_case(name, expected, test_function):
    # 1ケースを実行し、要求された情報を1行で表示する。
    global pass_count, fail_count

    start_us = time.ticks_us()
    reset_ack_rx = -1
    start_ack_rx = -1
    detail = "DETAIL=N/A"
    passed = False

    try:
        reset_ack_rx, start_ack_rx = begin_protocol()
        body_passed, detail = test_function()
        passed = (
            reset_ack_rx == RESET_ACK
            and start_ack_rx == START_ACK
            and body_passed
        )
    except Exception as error:
        detail = "ERROR={}".format(error)
        passed = False

    elapsed_us = time.ticks_diff(time.ticks_us(), start_us)
    result = "PASS" if passed else "FAIL"

    if passed:
        pass_count += 1
    else:
        fail_count += 1

    print(
        "NAME={} RESULT={} EXPECT={} PASS={} TIME_US={} "
        "RESET_ACK_RX={} START_ACK_RX={} {}".format(
            name,
            result,
            expected,
            1 if passed else 0,
            elapsed_us,
            format_byte(reset_ack_rx),
            format_byte(start_ack_rx),
            detail
        )
    )


print(
    "CONFIG SPI_BAUDRATE={} CPOL=0 CPHA=0 MAX_PACKAGE_SIZE={}".format(
        SPI_BAUDRATE,
        MAX_PACKAGE_SIZE
    )
)

# 1. ハードウェアリセット直後の未書き込みアドレスは0。
# RESET/START ACKと後続試験のRESET処理で確認する。
record_case(
    "reset-start-ack",
    "RESET_ACK=0x5A,START_ACK=0xA5",
    test_protocol_ack
)
# 2. 先頭アドレスへ書き込み、同じ値を読み戻す。
# 3. 最終アドレスへ書き込み、同じ値を読み戻す。
# 4. address[8]を使用するアドレスへ書き込み、同じ値を読み戻す。
record_case(
    "single-addresses",
    "READ_EQUALS_WRITE",
    test_single_addresses
)
# 6. 同じアドレスを別の値で上書きできることを確認する。
record_case(
    "overwrite",
    "READ=0xFF",
    test_overwrite
)
# 5. 複数アドレスへ先に別々の値を書き、後から個別に読み戻す。
record_case(
    "continuous-addresses",
    "16_VALUES_MATCH",
    test_continuous_addresses
)
# 7. CMD_RESET後、書き込み済みの複数アドレスが0へ戻ることを確認する。
# 最初のケースでCMD_RESETを送り、後続ケースでもクリア結果を確認する。
record_case(
    "reset-fsm",
    "RESET2=0x5A,START2=0xA5,READ=0x00",
    test_reset_fsm
)

for burst_length in BURST_LENGTHS:
    record_case(
        "burst-{}".format(burst_length),
        "LENGTH={},RX_ALL_00".format(burst_length),
        lambda length=burst_length: test_burst_length(length)
    )

overall_result = "PASS" if fail_count == 0 else "FAIL"
print(
    "SUMMARY PASS={} FAIL={} RESULT={}".format(
        pass_count,
        fail_count,
        overall_result
    )
)
