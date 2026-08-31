from machine import Pin, SPI
import time
import shrike


BITSTREAM = "abc472b.bin"
BITSTREAM_SHA256 = (
    "4BCBCBC4DBF0B3C678BE398A31710464"
    "C509A81A581DBE98D08282A5758F49A4"
)
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
RUNS = 20

tx_buffer = bytearray(MAX_INPUT_BYTES)
rx_buffer = bytearray(MAX_INPUT_BYTES)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)


def setup_hardware():
    """Flash, reset, and SPI construction are deliberately outside timing."""
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
    if count < 1 or count > MAX_PACKAGE_SIZE:
        raise ValueError("SPI package size must be 1..256")

    end = start + count
    cs_pin.value(0)
    try:
        spi_bus.write_readinto(tx_view[start:end], rx_view[start:end])
    finally:
        cs_pin.value(1)


def fpga_solve_timed_scope(spi_bus, cs_pin, lengths):
    """The complete per-problem scope measured by WORK7."""
    # RP2040 input validation and N/L_i serialization are measured.
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

    # N=100 is 301 bytes, transferred as two V3 bursts: 256 + 45.
    input_size = offset
    offset = 0
    while offset < input_size:
        count = min(MAX_PACKAGE_SIZE, input_size - offset)
        spi_transfer_window(spi_bus, cs_pin, offset, count)
        offset += count

    time.sleep_us(CALC_WAIT_US)

    for index in range(ANSWER_BURST_BYTES):
        tx_buffer[index] = 0
    spi_transfer_window(spi_bus, cs_pin, 0, ANSWER_BURST_BYTES)

    if rx_buffer[0] != 0:
        raise RuntimeError("answer burst dummy byte was not zero")
    return (
        (rx_buffer[1] << 16)
        | (rx_buffer[2] << 8)
        | rx_buffer[3]
    )


def test_expected_answer(lengths):
    """Test oracle only; called once before the timed runs."""
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


def format_tenths(value_times_ten):
    return "{}.{}".format(value_times_ten // 10, value_times_ten % 10)


def main():
    # Case construction and oracle evaluation are deliberately outside timing.
    lengths = [MAX_LENGTH] * MAX_N
    expected = test_expected_answer(lengths)
    elapsed_us = [0] * RUNS
    answers = [0] * RUNS

    print(
        "WORK7_BENCHMARK_BEGIN BITSTREAM={} SHA256={}".format(
            BITSTREAM, BITSTREAM_SHA256
        )
    )
    spi_bus, cs_pin = setup_hardware()
    print(
        "WORK7_BENCHMARK_SETUP INPUT=maximum_total VALUE={} "
        "SPI_HZ={} BYTES=301 BURSTS=256+45 CALC_WAIT_US={}".format(
            MAX_LENGTH, SPI_BAUDRATE, CALC_WAIT_US
        )
    )

    all_passed = True
    for index in range(RUNS):
        start_us = time.ticks_us()
        answer = fpga_solve_timed_scope(spi_bus, cs_pin, lengths)
        end_us = time.ticks_us()

        elapsed_us[index] = time.ticks_diff(end_us, start_us)
        answers[index] = answer
        if answer != expected:
            all_passed = False

    # All printing is after all measurements and therefore outside timing.
    for index in range(RUNS):
        print(
            "RUN={:02d} ELAPSED_US={} ANSWER={} EXPECT={} STATUS={}".format(
                index + 1,
                elapsed_us[index],
                answers[index],
                expected,
                "PASS" if answers[index] == expected else "FAIL",
            )
        )

    minimum_us = min(elapsed_us)
    maximum_us = max(elapsed_us)
    average_times_ten = (sum(elapsed_us) * 10 + RUNS // 2) // RUNS

    print("BENCHMARK N={} RUNS={}".format(MAX_N, RUNS))
    print("MIN_US={}".format(minimum_us))
    print("AVG_US={}".format(format_tenths(average_times_ten)))
    print("MAX_US={}".format(maximum_us))
    print("RESULT={}".format("PASS" if all_passed else "FAIL"))
    print(
        "WORK7_BENCHMARK_DONE RESULT={}".format(
            "PASS" if all_passed else "FAIL"
        )
    )


if __name__ == "__main__":
    main()
