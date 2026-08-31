from machine import Pin, SPI
import time
import shrike


# Thonnyで変更する場合は、この設定ブロックだけを編集する。
RUN_PLAN = "ALL"  # ALL / A1 / A2 / B / C / SINGLE
SINGLE_MODE = "B1"
SINGLE_CASE = "best_at_first_cut"
SINGLE_RUNS = 10

A_RUNS = 20
B_RUNS = 10
C_RUNS = 1

BITSTREAM = "abc472b_debug_work6_exp03.bin"
INPUT_4MHZ = 4_000_000
INPUT_2MHZ = 2_000_000
ANSWER_4MHZ = 4_000_000
ANSWER_2MHZ = 2_000_000

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


tx_buffer = bytearray(MAX_INPUT_BYTES)
rx_buffer = bytearray(MAX_INPUT_BYTES)
tx_view = memoryview(tx_buffer)
rx_view = memoryview(rx_buffer)

reset_pin = None
cs_pin = None
spi_bus = None
spi_baudrate = None


def make_random_lengths(n_value, seed):
    values = []
    state = seed & 0xFFFFFFFF
    for _ in range(n_value):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        values.append(1 + (state % MAX_LENGTH))
    return values


def build_cases():
    cases = {
        "best_at_first_cut": [100, 1, 1],
        "burst_boundary_259": [
            1 + ((i * 193) % MAX_LENGTH) for i in range(86)
        ],
        "deterministic_random_100": make_random_lengths(
            100, 0x472B2026 + 6
        ),
        "official_sample_1": [5, 2, 3, 8],
        "best_at_last_cut": [1, 1, 100],
        "burst_boundary_256": [
            1 + ((i * 97) % MAX_LENGTH) for i in range(85)
        ],
        "n100_all_one": [1] * 100,
        "deterministic_random_86": make_random_lengths(
            86, 0x472B2026 + 5
        ),
    }
    return cases


CASES = build_cases()

FAIL_REPRESENTATIVES = (
    "best_at_first_cut",
    "burst_boundary_259",
    "deterministic_random_100",
)

PASS_REPRESENTATIVES = (
    "official_sample_1",
    "best_at_last_cut",
    "burst_boundary_256",
    "n100_all_one",
    "deterministic_random_86",
)

SPI_MODES = {
    "B1": (INPUT_4MHZ, ANSWER_4MHZ),
    "B2": (INPUT_2MHZ, ANSWER_4MHZ),
    "B3": (INPUT_4MHZ, ANSWER_2MHZ),
    "B4": (INPUT_2MHZ, ANSWER_2MHZ),
}


def test_expected_answer(lengths):
    """Software oracle only. FPGA computation is never replaced."""
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


def create_spi(baudrate):
    return SPI(
        0,
        baudrate=baudrate,
        polarity=0,
        phase=0,
        bits=8,
        firstbit=SPI.MSB,
        sck=Pin(SCK),
        mosi=Pin(MOSI),
        miso=Pin(MISO),
    )


def set_spi_baudrate(baudrate):
    """Use public MicroPython APIs only; prefer SPI.init()."""
    global spi_bus, spi_baudrate

    if spi_bus is not None and spi_baudrate == baudrate:
        return

    if spi_bus is not None:
        try:
            spi_bus.init(
                baudrate=baudrate,
                polarity=0,
                phase=0,
                bits=8,
                firstbit=SPI.MSB,
            )
            spi_baudrate = baudrate
            return
        except (AttributeError, OSError, TypeError, ValueError):
            try:
                spi_bus.deinit()
            except (AttributeError, OSError):
                pass

    spi_bus = create_spi(baudrate)
    spi_baudrate = baudrate


def pulse_fpga_reset():
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)


def setup_hardware():
    global reset_pin, cs_pin, spi_bus, spi_baudrate

    print("WORK6_EXP03_SETUP BITSTREAM={} ACTION=FLASH".format(BITSTREAM))
    shrike.reset()
    shrike.flash(BITSTREAM)

    reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)
    cs_pin = Pin(CS, Pin.OUT, value=1)
    pulse_fpga_reset()

    spi_bus = create_spi(INPUT_4MHZ)
    spi_baudrate = INPUT_4MHZ
    print("WORK6_EXP03_SETUP RESULT=READY SPI_HZ={}".format(spi_baudrate))


def spi_transfer_window(start, count):
    if count < 1 or count > MAX_PACKAGE_SIZE:
        raise ValueError("SPI package size must be 1..256")

    end = start + count
    cs_pin.value(0)
    try:
        spi_bus.write_readinto(tx_view[start:end], rx_view[start:end])
    finally:
        cs_pin.value(1)


def serialize_input(lengths):
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
    return offset


def raw_hex(raw_bytes):
    return ":".join("{:02X}".format(value) for value in raw_bytes)


def fpga_solve_raw(lengths, input_hz, answer_hz):
    input_size = serialize_input(lengths)

    set_spi_baudrate(input_hz)
    offset = 0
    while offset < input_size:
        count = min(MAX_PACKAGE_SIZE, input_size - offset)
        spi_transfer_window(offset, count)
        offset += count

    time.sleep_us(CALC_WAIT_US)
    set_spi_baudrate(answer_hz)

    for index in range(ANSWER_BURST_BYTES):
        tx_buffer[index] = 0
        rx_buffer[index] = 0
    spi_transfer_window(0, ANSWER_BURST_BYTES)

    raw = bytes(rx_buffer[0:ANSWER_BURST_BYTES])
    result = (raw[1] << 16) | (raw[2] << 8) | raw[3]
    return raw, result


def print_record(
    suite,
    mode,
    case_name,
    run_number,
    reset_mode,
    input_hz,
    answer_hz,
    raw,
    result,
    expected,
):
    status = "PASS" if result == expected and raw[0] == 0 else "FAIL"
    print(
        "REC SUITE={} MODE={} CASE={} RUN={} RESET={} INPUT_HZ={} "
        "ANSWER_HZ={} RAW_RX={} RESULT={} EXPECT={} DUMMY={} STATUS={}".format(
            suite,
            mode,
            case_name,
            run_number,
            reset_mode,
            input_hz,
            answer_hz,
            raw_hex(raw),
            result,
            expected,
            raw[0],
            status,
        )
    )
    return status == "PASS"


def run_case_series(
    suite,
    mode,
    case_name,
    runs,
    reset_each_run,
    input_hz,
    answer_hz,
    reset_before_series=True,
):
    lengths = CASES[case_name]
    expected = test_expected_answer(lengths)
    passed = 0
    failed = 0

    if not reset_each_run and reset_before_series:
        pulse_fpga_reset()

    print(
        "BEGIN SUITE={} MODE={} CASE={} RUNS={} RESET_EACH={} "
        "INPUT_HZ={} ANSWER_HZ={} EXPECT={}".format(
            suite,
            mode,
            case_name,
            runs,
            1 if reset_each_run else 0,
            input_hz,
            answer_hz,
            expected,
        )
    )

    for run_number in range(1, runs + 1):
        if reset_each_run:
            pulse_fpga_reset()
        try:
            raw, result = fpga_solve_raw(lengths, input_hz, answer_hz)
            ok = print_record(
                suite,
                mode,
                case_name,
                run_number,
                "EACH" if reset_each_run else "ONCE",
                input_hz,
                answer_hz,
                raw,
                result,
                expected,
            )
        except Exception as error:
            ok = False
            print(
                "REC SUITE={} MODE={} CASE={} RUN={} RESET={} INPUT_HZ={} "
                "ANSWER_HZ={} RAW_RX=NA RESULT=NA EXPECT={} DUMMY=NA "
                "STATUS=ERROR ERROR={}".format(
                    suite,
                    mode,
                    case_name,
                    run_number,
                    "EACH" if reset_each_run else "ONCE",
                    input_hz,
                    answer_hz,
                    expected,
                    repr(error).replace(" ", "_"),
                )
            )
            pulse_fpga_reset()

        if ok:
            passed += 1
        else:
            failed += 1

    print(
        "SUMMARY SUITE={} MODE={} CASE={} PASS={} FAIL={} TOTAL={} RESULT={}".format(
            suite,
            mode,
            case_name,
            passed,
            failed,
            passed + failed,
            "PASS" if failed == 0 else "FAIL",
        )
    )
    return passed, failed


def run_a1():
    return run_case_series(
        "A1",
        "4M_4M",
        "best_at_first_cut",
        A_RUNS,
        False,
        INPUT_4MHZ,
        ANSWER_4MHZ,
        False,
    )


def run_a2():
    return run_case_series(
        "A2",
        "4M_4M",
        "best_at_first_cut",
        A_RUNS,
        True,
        INPUT_4MHZ,
        ANSWER_4MHZ,
    )


def run_b():
    passed = 0
    failed = 0
    for mode in ("B1", "B2", "B3", "B4"):
        input_hz, answer_hz = SPI_MODES[mode]
        mode_passed, mode_failed = run_case_series(
            "B",
            mode,
            "best_at_first_cut",
            B_RUNS,
            False,
            input_hz,
            answer_hz,
        )
        passed += mode_passed
        failed += mode_failed
    return passed, failed


def run_c():
    passed = 0
    failed = 0
    representative_names = FAIL_REPRESENTATIVES + PASS_REPRESENTATIVES

    for mode in ("B1", "B2", "B3", "B4"):
        input_hz, answer_hz = SPI_MODES[mode]
        for case_name in representative_names:
            case_passed, case_failed = run_case_series(
                "C",
                mode,
                case_name,
                C_RUNS,
                False,
                input_hz,
                answer_hz,
            )
            passed += case_passed
            failed += case_failed
    return passed, failed


def run_single():
    if SINGLE_MODE not in SPI_MODES:
        raise ValueError("SINGLE_MODE must be B1..B4")
    if SINGLE_CASE not in CASES:
        raise ValueError("unknown SINGLE_CASE")
    input_hz, answer_hz = SPI_MODES[SINGLE_MODE]
    return run_case_series(
        "SINGLE",
        SINGLE_MODE,
        SINGLE_CASE,
        SINGLE_RUNS,
        False,
        input_hz,
        answer_hz,
    )


def main():
    print("WORK5_BEGIN PLAN={}".format(RUN_PLAN))
    setup_hardware()
    total_passed = 0
    total_failed = 0

    if RUN_PLAN in ("ALL", "A1"):
        passed, failed = run_a1()
        total_passed += passed
        total_failed += failed

    if RUN_PLAN in ("ALL", "A2"):
        passed, failed = run_a2()
        total_passed += passed
        total_failed += failed

    if RUN_PLAN in ("ALL", "B"):
        passed, failed = run_b()
        total_passed += passed
        total_failed += failed

    if RUN_PLAN in ("ALL", "C"):
        passed, failed = run_c()
        total_passed += passed
        total_failed += failed

    if RUN_PLAN == "SINGLE":
        passed, failed = run_single()
        total_passed += passed
        total_failed += failed

    if RUN_PLAN not in ("ALL", "A1", "A2", "B", "C", "SINGLE"):
        raise ValueError("RUN_PLAN must be ALL/A1/A2/B/C/SINGLE")

    print(
        "WORK6_EXP03_DONE PLAN={} PASS={} FAIL={} TOTAL={} RESULT={}".format(
            RUN_PLAN,
            total_passed,
            total_failed,
            total_passed + total_failed,
            "PASS" if total_failed == 0 else "FAIL",
        )
    )


if __name__ == "__main__":
    main()
