from machine import Pin, SPI
import time
import shrike


BITSTREAM = "abc472b_debug_work6_exp01.bin"
SPI_HZ = 2_000_000
RUNS = 10

SCK = 2
CS = 1
MOSI = 3
MISO = 0
FPGA_RESET = 14

INPUT = bytes((3, 0, 0, 100, 0, 0, 1, 0, 0, 1))
RESPONSE_BYTES = 27


def raw_hex(values):
    return ":".join("{:02X}".format(value) for value in values)


def u17(values, offset):
    return ((values[offset] & 1) << 16) | (values[offset + 1] << 8) | values[offset + 2]


def u24(values, offset):
    return (values[offset] << 16) | (values[offset + 1] << 8) | values[offset + 2]


reset_pin = Pin(FPGA_RESET, Pin.OUT, value=1)
cs_pin = Pin(CS, Pin.OUT, value=1)
spi = SPI(
    0,
    baudrate=SPI_HZ,
    polarity=0,
    phase=0,
    bits=8,
    firstbit=SPI.MSB,
    sck=Pin(SCK),
    mosi=Pin(MOSI),
    miso=Pin(MISO),
)


def pulse_reset():
    reset_pin.value(0)
    time.sleep_ms(100)
    reset_pin.value(1)
    time.sleep_ms(100)


def transfer(tx):
    rx = bytearray(len(tx))
    cs_pin.value(0)
    try:
        spi.write_readinto(tx, rx)
    finally:
        cs_pin.value(1)
    return bytes(rx)


def one_run(suite, run_number, reset_each):
    if reset_each:
        pulse_reset()

    transfer(INPUT)
    time.sleep_us(20)
    raw = transfer(bytes(RESPONSE_BYTES))

    shadow = (u17(raw, 6), u17(raw, 9), u17(raw, 12))
    ram = (u17(raw, 15), u17(raw, 18), u17(raw, 21))
    total = u24(raw, 24)
    ok = (
        raw[0] == 0
        and raw[1] == 0xA6
        and raw[2] == 1
        and raw[3] == 3
        and raw[4] == 3
        and raw[5] == 0
        and shadow == (100, 1, 1)
        and ram == (100, 1, 1)
        and total == 102
    )
    print(
        "REC EXP=01 SUITE={} RUN={} RESET={} RAW={} N={} COUNT={} "
        "BYTE_INDEX={} SHADOW={},{},{} RAM={},{},{} TOTAL={} STATUS={}".format(
            suite,
            run_number,
            "EACH" if reset_each else "ONCE",
            raw_hex(raw),
            raw[3],
            raw[4],
            raw[5],
            shadow[0],
            shadow[1],
            shadow[2],
            ram[0],
            ram[1],
            ram[2],
            total,
            "PASS" if ok else "FAIL",
        )
    )
    time.sleep_ms(5)
    return ok


def run_suite(name, reset_each):
    passed = 0
    for run_number in range(1, RUNS + 1):
        if one_run(name, run_number, reset_each):
            passed += 1
    failed = RUNS - passed
    print(
        "SUMMARY EXP=01 SUITE={} PASS={} FAIL={} TOTAL={} RESULT={}".format(
            name,
            passed,
            failed,
            RUNS,
            "PASS" if failed == 0 else "FAIL",
        )
    )
    return passed, failed


print("WORK6_EXP01_BEGIN BITSTREAM={} SPI_HZ={}".format(BITSTREAM, SPI_HZ))
shrike.reset()
shrike.flash(BITSTREAM)
pulse_reset()

total_passed = 0
total_failed = 0
passed, failed = run_suite("CONTINUOUS", False)
total_passed += passed
total_failed += failed
passed, failed = run_suite("RESET_EACH", True)
total_passed += passed
total_failed += failed

print(
    "WORK6_EXP01_DONE PASS={} FAIL={} TOTAL={} RESULT={}".format(
        total_passed,
        total_failed,
        total_passed + total_failed,
        "PASS" if total_failed == 0 else "FAIL",
    )
)
