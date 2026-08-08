from time import ticks_diff, ticks_us
import gc
import shrike_parallel_burst_pio_dma_proto_ph5_a3 as a3
import shrike_parallel_burst_pio_dma_proto_ph5_a4 as a4
import shrike_parallel_c as c


BITSTREAM = "abc469a.bin"
ABC469A = 0x03
STATUS_OK = 0x00
STATUS_PROTOCOL_ERROR = 0xE2
PARALLEL_CLK_HZ = 4_000_000

# Trueにすると4MHzでN=1..100、K=1..Nの全5050ケースも実行する。
RUN_ALL_VALID_INPUTS = False

VALID_CASES = (
    ("sample1", 5, 2, 4),
    ("sample2", 1, 1, 1),
    ("sample3", 99, 50, 50),
    ("first_car", 100, 1, 100),
    ("last_car", 100, 100, 1),
)

INVALID_CASES = (
    ("invalid_n_zero", 0, 1),
    ("invalid_k_zero", 5, 0),
    ("invalid_k_gt_n", 5, 6),
    ("invalid_n_gt_100", 101, 1),
)

# A3 harnessが事前確保したbufferを全packetで再利用する。
request = a3.request_buffer
response = a3.response_buffer


def format_byte(value):
    if value is None:
        return "--"
    return "0x{:02X}".format(value)


def format_value(value):
    if value is None:
        return "--"
    return str(value)


def print_diagnostics(name, error):
    print(
        "ABC469A_DIAGNOSTICS NAME={} ERROR_STAGE={} LAST_MARKER_OK={} "
        "LAST_TX_DMA_WORD_COUNT={} LAST_RX_DMA_WORD_COUNT={} "
        "LAST_DMA_TRANSFER_TIME_US={} ERROR={}".format(
            name,
            a3.error_stage,
            a3.last_marker_ok,
            a3.last_tx_dma_word_count,
            a3.last_rx_dma_word_count,
            a3.last_dma_transfer_time_us,
            a3.format_error(error),
        )
    )
    try:
        print("ABC469A_DMA_STATUS NAME={} STATUS={}".format(
            name, c.dma_status()))
        print("ABC469A_DMA_METRICS NAME={} METRICS={}".format(
            name, c.dma_last_metrics()))
    except BaseException as diagnostic_error:
        print("ABC469A_DIAGNOSTIC_ERROR NAME={} DETAIL={}".format(
            name, a3.format_error(diagnostic_error)))


def run_abc469a_case(name, n, k, expect, expected_status=STATUS_OK):
    request[0] = ABC469A
    request[1] = n
    request[2] = k
    response[0] = 0xFF
    response[1] = 0xFF

    status = None
    result = None
    error = None
    started = ticks_us()
    try:
        a3.transfer(request, 3, response, 2)
        status = response[0]
        result = response[1]
    except BaseException as caught:
        error = caught
    elapsed_us = ticks_diff(ticks_us(), started)

    passed = (
        error is None and
        status == expected_status and
        result == expect
    )
    print(
        "NAME={} N={} K={} RESULT={} EXPECT={} STATUS={} {} TIME_US={} "
        "PARALLEL_CLK_HZ={}".format(
            name,
            n,
            k,
            format_value(result),
            expect,
            format_byte(status),
            "PASS" if passed else "FAIL",
            elapsed_us,
            a3.current_parallel_clk_hz,
        )
    )
    if not passed:
        print_diagnostics(name, error)
    return passed, error is None


def run_soft_reset(name):
    request[0] = a3.SOFT_RESET
    response[0] = 0xFF

    status = None
    error = None
    started = ticks_us()
    try:
        a3.transfer(request, 1, response, 1)
        status = response[0]
    except BaseException as caught:
        error = caught
    elapsed_us = ticks_diff(ticks_us(), started)

    passed = error is None and status == STATUS_OK
    print(
        "NAME={} N=- K=- RESULT={} EXPECT=0 STATUS={} {} TIME_US={} "
        "PARALLEL_CLK_HZ={}".format(
            name,
            format_value(status),
            format_byte(status),
            "PASS" if passed else "FAIL",
            elapsed_us,
            a3.current_parallel_clk_hz,
        )
    )
    if not passed:
        print_diagnostics(name, error)
    return passed, error is None


def record_result(counters, passed):
    counters[0] += 1
    if passed:
        counters[1] += 1
    else:
        counters[2] += 1


def require_transport(healthy, name):
    if not healthy:
        raise RuntimeError("transport failed during {}".format(name))


def run_test_suite(counters):
    for name, n, k, expect in VALID_CASES:
        passed, healthy = run_abc469a_case(name, n, k, expect)
        record_result(counters, passed)
        require_transport(healthy, name)

    for name, n, k in INVALID_CASES:
        passed, healthy = run_abc469a_case(
            name, n, k, 0, STATUS_PROTOCOL_ERROR)
        record_result(counters, passed)
        require_transport(healthy, name)

        reset_name = "soft_reset_after_{}".format(name)
        passed, healthy = run_soft_reset(reset_name)
        record_result(counters, passed)
        require_transport(healthy, reset_name)

        recovery_name = "recover_after_{}".format(name)
        passed, healthy = run_abc469a_case(recovery_name, 5, 2, 4)
        record_result(counters, passed)
        require_transport(healthy, recovery_name)

    if RUN_ALL_VALID_INPUTS:
        for n in range(1, 101):
            for k in range(1, n + 1):
                name = "all_n{}_k{}".format(n, k)
                passed, healthy = run_abc469a_case(
                    name, n, k, n - k + 1)
                record_result(counters, passed)
                require_transport(healthy, name)

    return counters[2] == 0 and a3.check_idle_state()


def main():
    counters = [0, 0, 0]  # COUNT, PASS, FAIL
    body_passed = False
    body_error = None
    cleanup_error = None
    dma_opened = False

    try:
        version = c.version()
        if version != "0.1.0-a4":
            raise RuntimeError(
                "wrong shrike_parallel_c version: {}".format(version))

        gc.enable()
        tx_channel, rx_channel = c.dma_open(
            recover=True,
            pio=a3.PIO_NUMBER,
            sm=a3.PIO_LOCAL_SM_NUMBER,
            req_pin=a3.REQ_PIN_NUMBER,
            req_assert_timeout_us=a3.REQ_ASSERT_TIMEOUT_US,
            tx_timeout_us=a3.TX_DMA_TIMEOUT_US,
            rx_first_timeout_us=a3.RX_DMA_FIRST_TIMEOUT_US,
            rx_progress_timeout_us=a3.RX_DMA_PROGRESS_TIMEOUT_US,
            rx_complete_timeout_us=a3.RX_DMA_COMPLETE_TIMEOUT_US,
            marker_timeout_us=a3.MARKER_TIMEOUT_US,
            event_poll_interval_us=a4.EVENT_POLL_INTERVAL_US,
        )
        dma_opened = True

        # A4 adapterのmain()と同じA3互換viewと転送関数を設定する。
        a3.tx_dma_channel, a3.rx_dma_channel = tx_channel, rx_channel
        a3.tx_dma = a4._OwnedDMAView(tx_channel)
        a3.rx_dma = a4._OwnedDMAView(rx_channel)
        a3.transfer = a4.transfer_a4
        a3.BITSTREAM = BITSTREAM

        gc.collect()
        a3.program_fpga()
        gc.collect()
        a3.initialize_bus()
        a3.run_local_self_tests()
        a3.init_state_machine(PARALLEL_CLK_HZ)

        print(
            "ABC469A_CONFIG BITSTREAM={} SHRIKE_PARALLEL_C_VERSION={} "
            "PARALLEL_CLK_HZ={} RUN_ALL_VALID_INPUTS={}".format(
                BITSTREAM,
                version,
                PARALLEL_CLK_HZ,
                RUN_ALL_VALID_INPUTS,
            )
        )
        body_passed = run_test_suite(counters)
    except BaseException as caught:
        body_error = caught
        body_passed = False
        print("ABC469A_FATAL ERROR={}".format(a3.format_error(caught)))
    finally:
        if dma_opened or a3.sm is not None:
            cleanup_error = a4.shutdown_a4()
        overall_passed = body_passed and cleanup_error is None
        print(
            "ABC469A_SUMMARY COUNT={} PASS={} FAIL={} RESULT={}".format(
                counters[0],
                counters[1],
                counters[2],
                "PASS" if overall_passed else "FAIL",
            )
        )

    if body_error is not None:
        raise body_error
    if cleanup_error is not None:
        raise cleanup_error


if __name__ == "__main__":
    main()
