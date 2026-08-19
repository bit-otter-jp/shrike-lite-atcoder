from machine import Pin, SPI
import time
import shrike


BITSTREAM = "abc471e_s1s2.bin"

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

SPI_BAUDRATE = 4_000_000
MAX_PACKAGE_SIZE = 32
POLL_TIMEOUT_US = 2_000_000

CMD_NOP = 0x00
CMD_START = 0xFE
CMD_RESET = 0xFF
RESET_ACK = 0x5A
START_ACK = 0xA5

STATUS_VALID = 0x80
STATUS_ERROR = 0x40
MOD = 998244353


# This script is for the user's later hardware run.  Codex does not invoke
# shrike.flash() while implementing and simulating the baseline.
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

tx_buffer = bytearray(MAX_PACKAGE_SIZE)
rx_buffer = bytearray(MAX_PACKAGE_SIZE)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)


def spi_transfer(length):
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


def pack_u32(value):
    value &= 0xFFFFFFFF
    return (
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF
    )


def send_a_stream(values):
    # Pack up to eight 32-bit values in each 32-byte SPI burst.  No command or
    # CS boundary is inserted between logical A values.
    value_index = 0
    while value_index < len(values):
        chunk_values = min(
            (MAX_PACKAGE_SIZE // 4),
            len(values) - value_index
        )
        byte_count = chunk_values * 4

        for chunk_index in range(chunk_values):
            value = values[value_index + chunk_index] & 0xFFFFFFFF
            byte_index = chunk_index * 4
            tx_buffer[byte_index] = (value >> 24) & 0xFF
            tx_buffer[byte_index + 1] = (value >> 16) & 0xFF
            tx_buffer[byte_index + 2] = (value >> 8) & 0xFF
            tx_buffer[byte_index + 3] = value & 0xFF

        spi_transfer(byte_count)
        value_index += chunk_values


def brute_force_expected(values, k):
    # Independent reference: enumerate subsets instead of reproducing the
    # FPGA's prefix/square/pair formula.
    n = len(values)
    total = 0
    for mask in range(1 << n):
        selected_count = 0
        selected_sum = 0
        for index in range(n):
            if mask & (1 << index):
                selected_count += 1
                selected_sum += values[index]
        if selected_count == k:
            selected_sum %= MOD
            total = (total + selected_sum * selected_sum) % MOD
    return total


def poll_status():
    started = time.ticks_us()
    poll_count = 0
    status = 0

    while time.ticks_diff(time.ticks_us(), started) < POLL_TIMEOUT_US:
        status = spi_exchange_1byte(CMD_NOP)
        poll_count += 1
        if status & STATUS_VALID:
            break

    return status, poll_count


def run_case(name, values, k):
    n = len(values)
    started = time.ticks_us()

    # RESET_ACK and START_ACK are returned one SPI byte after their commands.
    spi_exchange_1byte(CMD_RESET)
    reset_ack_rx = spi_exchange_1byte(CMD_NOP)
    spi_exchange_1byte(CMD_START)
    start_ack_rx = spi_exchange_1byte(CMD_NOP)

    spi_exchange_burst(pack_u32(n))
    spi_exchange_burst(pack_u32(k))
    send_a_stream(values)

    status, poll_count = poll_status()
    valid = (status & STATUS_VALID) != 0
    error = (status & STATUS_ERROR) != 0

    result = -1
    if valid:
        answer_rx = spi_exchange_burst(
            (CMD_NOP, CMD_NOP, CMD_NOP, CMD_NOP)
        )
        result = (
            (answer_rx[0] << 24) |
            (answer_rx[1] << 16) |
            (answer_rx[2] << 8) |
            answer_rx[3]
        )

    expect = brute_force_expected(values, k)
    elapsed_us = time.ticks_diff(time.ticks_us(), started)
    passed = (
        reset_ack_rx == RESET_ACK and
        start_ack_rx == START_ACK and
        valid and
        not error and
        result == expect
    )

    print("NAME={}".format(name))
    print("N={}".format(n))
    print("K={}".format(k))
    print("RESULT={}".format(result))
    print("EXPECT={}".format(expect))
    print("VALID={}".format(1 if valid else 0))
    print("ERROR={}".format(1 if error else 0))
    print("PASS={}".format(1 if passed else 0))
    print("TIME_US={}".format(elapsed_us))
    print("POLL_COUNT={}".format(poll_count))
    print("RESET_ACK_RX=0x{:02X}".format(reset_ack_rx))
    print("START_ACK_RX=0x{:02X}".format(start_ack_rx))
    print("")
    return passed


TEST_CASES = [
    ("n1_k1", (123456789,), 1),
    ("hand_example", (1, 2, 3), 2),
    ("k1", (1, 2, 3, 4), 1),
    ("k_equals_n", (1, 2, 3, 4), 4),
    (
        "mod_boundaries",
        (MOD - 1, MOD, MOD + 1, 2 * MOD, 0xFFFFFFFF),
        3
    ),
    # Includes every reserved payload byte.  They must remain raw data.
    ("reserved_payload_bytes", (0x00FDFEFF, 0xFFFEFD00, 7), 2),
]

# Deterministic small random-style cases, still checked by subset enumeration.
lcg = 0x471E2026
for case_index in range(16):
    lcg = (1664525 * lcg + 1013904223) & 0xFFFFFFFF
    n = 1 + (lcg % 8)
    lcg = (1664525 * lcg + 1013904223) & 0xFFFFFFFF
    k = 1 + (lcg % n)
    values = []
    for unused in range(n):
        lcg = (1664525 * lcg + 1013904223) & 0xFFFFFFFF
        values.append(lcg)
    TEST_CASES.append(("generated_{}".format(case_index), tuple(values), k))


print(
    "CONFIG BITSTREAM={} SPI_BAUDRATE={} POLL_TIMEOUT_US={}".format(
        BITSTREAM,
        SPI_BAUDRATE,
        POLL_TIMEOUT_US
    )
)

pass_count = 0
for test_case in TEST_CASES:
    if run_case(test_case[0], test_case[1], test_case[2]):
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
