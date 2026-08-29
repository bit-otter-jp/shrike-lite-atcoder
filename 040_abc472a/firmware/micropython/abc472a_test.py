from machine import Pin, SPI
import time
import shrike


BITSTREAM = "abc472a.bin"
SPI_BAUDRATE = 4_000_000

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

DUMMY_BYTE = 0x00
FLUSH_BYTE = 0x00
MAX_LENGTH = 100
BENCHMARK_RUNS = 20

# V3-style reusable buffers: N source bytes plus one flush byte.
tx_buffer = bytearray(MAX_LENGTH + 1)
rx_buffer = bytearray(MAX_LENGTH + 1)
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


def fpga_convert(spi_bus, cs_pin, source):
    """Return the FPGA result; RP2040 does not perform the conversion."""
    length = len(source)
    if length < 1 or length > MAX_LENGTH:
        raise ValueError("source length must be 1..100")

    # Input validation and ASCII serialization only.
    for index in range(length):
        value = ord(source[index])
        if value < 0x41 or value > 0x5A:
            raise ValueError("source must contain uppercase A-Z only")
        tx_buffer[index] = value
    tx_buffer[length] = FLUSH_BYTE

    count = length + 1
    # Keep CS low for the complete source+flush burst. MISO is one byte late:
    # rx[0] is dummy, and rx[1:length+1] is the complete result.
    cs_pin.value(0)
    try:
        spi_bus.write_readinto(tx_view[:count], rx_view[:count])
    finally:
        cs_pin.value(1)

    dummy_ok = rx_buffer[0] == DUMMY_BYTE
    result = bytes(memoryview(rx_buffer)[1:count]).decode("ascii")
    return result, dummy_ok


def make_random_case(length, seed):
    """Create a repeatable random test vector and its test-only oracle."""
    state = seed & 0xFFFF
    source_chars = []
    expected_chars = []
    for _ in range(length):
        feedback = ((state >> 15) ^ (state >> 13) ^
                    (state >> 12) ^ (state >> 10)) & 1
        state = ((state << 1) & 0xFFFF) | feedback
        value = 0x41 + (state % 26)
        source_chars.append(chr(value))
        expected_chars.append("A" if value == 0x41 else ".")
    return "".join(source_chars), "".join(expected_chars)


def build_test_cases():
    cases = [
        ("official_sample_1", "ATCODER", "A......"),
        ("official_sample_2", "BANANA", ".A.A.A"),
        ("official_sample_3", "CORRECT", "......."),
        ("length_1_A", "A", "A"),
        ("length_1_non_A", "Z", "."),
        ("all_A", "A" * 100, "A" * 100),
        ("no_A", "B" * 100, "." * 100),
        ("multiple_A", "ABACADA", "A.A.A.A"),
        ("leading_A_only", "A" + "B" * 99, "A" + "." * 99),
        ("trailing_A_only", "B" * 99 + "A", "." * 99 + "A"),
        (
            "all_A_to_Z",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "A" + "." * 25,
        ),
        (
            "length_100_mixed",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ" * 3 + "ABCDEFGHIJKLMNOPQRSTUV",
            ("A" + "." * 25) * 3 + "A" + "." * 21,
        ),
    ]

    for index, length in enumerate((1, 7, 31, 64, 100)):
        source, expected = make_random_case(length, 0x1ACE + index)
        cases.append(("random_%d" % length, source, expected))
    return cases


def run_benchmark(spi_bus, cs_pin):
    """Measure only fpga_convert() for the existing 100-character case."""
    for name, source, expected in build_test_cases():
        if name == "length_100_mixed":
            break

    # One unmeasured warm-up transfer in the same SPI session.
    result, dummy_ok = fpga_convert(spi_bus, cs_pin, source)
    benchmark_ok = dummy_ok and result == expected

    elapsed_values = []
    for _ in range(BENCHMARK_RUNS):
        start = time.ticks_us()
        result, dummy_ok = fpga_convert(spi_bus, cs_pin, source)
        elapsed_us = time.ticks_diff(time.ticks_us(), start)

        elapsed_values.append(elapsed_us)
        if not dummy_ok or result != expected:
            benchmark_ok = False

    min_us = min(elapsed_values)
    avg_us = sum(elapsed_values) // BENCHMARK_RUNS
    max_us = max(elapsed_values)
    print(
        "BENCHMARK LEN=%d RUNS=%d MIN_US=%d AVG_US=%d MAX_US=%d RESULT=%s"
        % (len(source), BENCHMARK_RUNS, min_us, avg_us, max_us,
           "PASS" if benchmark_ok else "FAIL")
    )
    return benchmark_ok


def run_all_tests():
    spi_bus, cs_pin = reset_and_open_spi()
    passed = 0
    failed = 0

    # The FPGA is reset only once. Running all cases back-to-back also tests
    # that separate CS transactions never reuse a previous result as dummy.
    for name, source, expected in build_test_cases():
        result, dummy_ok = fpga_convert(spi_bus, cs_pin, source)
        ok = dummy_ok and result == expected
        if ok:
            passed += 1
        else:
            failed += 1
        print(
            "NAME=%s LEN=%d DUMMY_OK=%d RX=%s EXPECT=%s %s"
            % (name, len(source), dummy_ok, result, expected,
               "PASS" if ok else "FAIL")
        )

    final_ok = failed == 0
    print(
        "SUMMARY PASS=%d FAIL=%d TOTAL=%d RESULT=%s"
        % (passed, failed, passed + failed, "PASS" if final_ok else "FAIL")
    )
    if not final_ok:
        return False
    return run_benchmark(spi_bus, cs_pin)


if __name__ == "__main__":
    run_all_tests()
