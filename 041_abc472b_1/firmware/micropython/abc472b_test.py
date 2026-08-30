from machine import Pin, SPI
import time
import shrike


BITSTREAM = "abc472b.bin"
SPI_BAUDRATE = 4_000_000

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

MAX_N = 100
MAX_LENGTH = 100_000
MAX_INPUT_BYTES = 1 + 3 * MAX_N
MAX_PACKAGE_SIZE = 256
ANSWER_BURST_BYTES = 4
CALC_WAIT_US = 10

# V3形式の再利用buffer。input最大301byteと4byte answer readで共用する。
tx_buffer = bytearray(MAX_INPUT_BYTES)
rx_buffer = bytearray(MAX_INPUT_BYTES)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)


def reset_and_open_spi():
    """Flash the later-generated bitstream, reset FPGA, and open SPI Mode 0."""
    shrike.reset()
    shrike.flash(BITSTREAM)

    reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)

    cs_pin = Pin(CS, Pin.OUT, value=1)
    spi_bus = SPI(
        0,
        baudrate=SPI_BAUDRATE,
        polarity=0,
        phase=0,
        bits=8,
        firstbit=SPI.MSB,
        sck=Pin(SCK),
        mosi=Pin(MOSI),
        miso=Pin(MISO),
    )
    return spi_bus, cs_pin


def spi_transfer_window(spi_bus, cs_pin, start, count):
    """Transfer one V3 package while always restoring CS High."""
    if count < 1 or count > MAX_PACKAGE_SIZE:
        raise ValueError("SPI package size must be 1..256")

    end = start + count
    cs_pin.value(0)
    try:
        spi_bus.write_readinto(tx_view[start:end], rx_view[start:end])
    finally:
        cs_pin.value(1)


def fpga_solve(spi_bus, cs_pin, lengths):
    """Serialize only N/L_i, then return the FPGA's 24bit answer."""
    n_value = len(lengths)
    if n_value < 2 or n_value > MAX_N:
        raise ValueError("N must be 2..100")

    tx_buffer[0] = n_value
    offset = 1
    for value in lengths:
        if value < 1 or value > MAX_LENGTH:
            raise ValueError("each L_i must be 1..100000")
        tx_buffer[offset] = (value >> 16) & 0xFF
        tx_buffer[offset + 1] = (value >> 8) & 0xFF
        tx_buffer[offset + 2] = value & 0xFF
        offset += 3

    # 301byteの論理入力を最大256byteずつのCS区間へ分割する。
    input_size = offset
    offset = 0
    while offset < input_size:
        count = min(MAX_PACKAGE_SIZE, input_size - offset)
        spi_transfer_window(spi_bus, cs_pin, offset, count)
        offset += count

    # 最大CALCは198clock=3.96us @ 50MHz。10us待って別burstで読む。
    time.sleep_us(CALC_WAIT_US)

    for index in range(ANSWER_BURST_BYTES):
        tx_buffer[index] = 0
    spi_transfer_window(spi_bus, cs_pin, 0, ANSWER_BURST_BYTES)

    # MISOは1byte遅延: rx[0]はdummy、rx[1:4]が24bit big-endian回答。
    if rx_buffer[0] != 0:
        raise RuntimeError("answer burst dummy byte was not zero")
    return (
        (rx_buffer[1] << 16)
        | (rx_buffer[2] << 8)
        | rx_buffer[3]
    )


def test_expected_answer(lengths):
    """Test-only software oracle; production transfer does not use it."""
    total = sum(lengths)
    prefix = 0
    best = 0xFFFFFF
    for value in lengths[:-1]:
        prefix += value
        right = total - prefix
        difference = prefix - right
        if difference < 0:
            difference = -difference
        if difference < best:
            best = difference
    return best


def make_random_lengths(n_value, seed):
    """Create deterministic vectors for hardware testing."""
    values = []
    state = seed & 0xFFFFFFFF
    for _ in range(n_value):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        values.append(1 + (state % MAX_LENGTH))
    return values


def build_test_cases():
    cases = [
        ("official_sample_1", [5, 2, 3, 8]),
        ("official_sample_2", [31, 41, 59, 26, 53, 58, 97]),
        (
            "official_sample_3",
            [
                67011, 35764, 33042, 24098, 63738,
                98760, 17199, 68579, 21812, 45408,
            ],
        ),
        ("n2_minimum", [1, 1]),
        ("answer_24bit", [1, 100000]),
        ("best_at_first_cut", [100, 1, 1]),
        ("best_at_last_cut", [1, 1, 100]),
        ("equal_best_cuts", [1, 1, 1]),
        ("burst_boundary_256", [1 + ((i * 97) % MAX_LENGTH) for i in range(85)]),
        ("burst_boundary_259", [1 + ((i * 193) % MAX_LENGTH) for i in range(86)]),
        ("n100_all_one", [1] * 100),
        ("maximum_total", [MAX_LENGTH] * 100),
    ]

    for index, n_value in enumerate((2, 7, 31, 64, 85, 86, 100)):
        cases.append(
            (
                "deterministic_random_%d" % n_value,
                make_random_lengths(n_value, 0x472B2026 + index),
            )
        )
    return cases


def run_all_tests():
    spi_bus, cs_pin = reset_and_open_spi()
    passed = 0
    failed = 0

    # FPGA resetは最初の1回だけ。連続transactionで前回状態の混入も確認する。
    for name, lengths in build_test_cases():
        expected = test_expected_answer(lengths)
        result = fpga_solve(spi_bus, cs_pin, lengths)
        ok = result == expected
        if ok:
            passed += 1
        else:
            failed += 1

        input_bytes = 1 + 3 * len(lengths)
        bursts = (input_bytes + MAX_PACKAGE_SIZE - 1) // MAX_PACKAGE_SIZE
        print(
            "NAME={} N={} BYTES={} BURSTS={} RESULT={} EXPECT={} {}".format(
                name,
                len(lengths),
                input_bytes,
                bursts,
                result,
                expected,
                "PASS" if ok else "FAIL",
            )
        )

    final_ok = failed == 0
    print(
        "SUMMARY PASS={} FAIL={} TOTAL={} RESULT={}".format(
            passed,
            failed,
            passed + failed,
            "PASS" if final_ok else "FAIL",
        )
    )
    return final_ok


if __name__ == "__main__":
    run_all_tests()
