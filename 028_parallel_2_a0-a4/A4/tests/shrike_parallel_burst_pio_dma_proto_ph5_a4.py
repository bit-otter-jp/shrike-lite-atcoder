"""Phase 5-A4 hardware acceptance adapter.

This deliberately imports the unchanged A3 test harness so its PIO program,
payloads, boundary checks, recovery sequence, logging, and frequency suite stay
the comparison reference.  Only the packet DMA operation and ownership are
replaced by shrike_parallel_c.
"""
from array import array
from time import ticks_diff, ticks_us
import gc
import shrike_parallel_burst_pio_dma_proto_ph5_a3 as a3
import shrike_parallel_c as c

EVENT_POLL_INTERVAL_US = 250  # repeat the run with 50, 250, and 10000
PERFORMANCE_MODE = False
PERFORMANCE_WARMUP_COUNT = 10
PERFORMANCE_PIO_HZ = 4_000_000
PERFORMANCE_REQUEST_LENGTH = a3.DMA_BULK_LOOP_LENGTH + 2
PERFORMANCE_RESPONSE_LENGTH = a3.DMA_BULK_LOOP_LENGTH + 1
# Measurement starts immediately before transfer_dma() and ends after Python
# REQ/PIO boundary checks. Payload generation and expected-value comparison are
# outside this boundary, matching the A3 DMA-oriented comparison boundary.
PERF_SAMPLES = None
PERF_METRIC_NAMES = (
    "pack_us", "rx_clear_us", "dma_config_us", "poll_us", "marker_us",
    "unpack_us", "transfer_us", "dma_time_us", "event_poll_count",
)
PERF_METRIC_TOTALS = None
perf_sample_count = 0
performance_capture_armed = False
performance_capture_expected_count = 0
performance_capture_label = ""
performance_capture_pio_hz = 0
performance_capture_request_length = 0
performance_capture_response_length = 0


class _OwnedDMAView:
    """Read-only compatibility placeholders for unchanged A3 diagnostics.

    count and active() are not C DMA register samples. Diagnose A4 failures
    from dma_status(), dma_last_metrics(), and the C exception stage instead.
    """
    def __init__(self, channel):
        self.channel = channel
        self.count = 0
        self.registers = (0, 0, 0, 0)

    def active(self, value=None):
        if value not in (None, 0):
            raise RuntimeError("A4 channels are controlled only by transfer_dma")
        return False

    def config(self, **kwargs):
        if kwargs.get("trigger", False):
            raise RuntimeError("A4 compatibility view cannot trigger DMA")

    def close(self):
        return None


def transfer_a4(request_bytes, request_length, response_bytes, response_length):
    """A3-compatible transfer boundary backed by the synchronous A4 C API."""
    global perf_sample_count
    if performance_capture_armed:
        if not PERFORMANCE_MODE:
            raise AssertionError("performance capture armed outside performance mode")
        if perf_sample_count >= performance_capture_expected_count:
            raise AssertionError("performance capture received excess packet")
        if a3.current_parallel_clk_hz != performance_capture_pio_hz:
            raise AssertionError("performance capture PIO frequency mismatch")
        if request_length != performance_capture_request_length:
            raise AssertionError("performance capture request length mismatch")
        if response_length != performance_capture_response_length:
            raise AssertionError("performance capture response length mismatch")
    start = ticks_us()
    response_nibbles = response_length * 2
    rx_data_words = (response_nibbles + 7) // 8
    try:
        a3._ensure_transaction_start_state()
        total_tx, received_data_words, dma_us, polls = c.transfer_dma(
            request_bytes,
            request_length,
            response_bytes,
            response_length,
            a3.tx_words,
            a3.rx_words,
            a3.response_raw_gpio_nibbles,
        )
        if received_data_words != rx_data_words:
            raise c.ProtocolError("STAGE=UNPACK_RX DETAIL=RX data word count")
        a3.last_tx_dma_word_count = total_tx
        a3.last_rx_dma_word_count = received_data_words + 1
        a3.last_expected_rx_words = received_data_words + 1
        a3.last_marker_index = received_data_words
        a3.last_marker_ok = a3.rx_words[received_data_words] == a3.COMPLETION_MARKER
        a3.last_dma_transfer_time_us = dma_us
        a3.wait_req_level(0, a3.REQ_RELEASE_TIMEOUT_US, "FPGA final REQ Low timeout")
        a3._confirm_persistent_boundary()
        a3.error_stage = "IDLE"
        if PERFORMANCE_MODE and performance_capture_armed:
            assert PERF_SAMPLES is not None
            assert PERF_METRIC_TOTALS is not None
            elapsed = ticks_diff(ticks_us(), start)
            PERF_SAMPLES[perf_sample_count] = elapsed
            metrics = c.dma_last_metrics()
            for index, name in enumerate(PERF_METRIC_NAMES):
                PERF_METRIC_TOTALS[index] += metrics[name]
            perf_sample_count += 1
        return polls
    except BaseException as caught:
        a3._print_transaction_error(caught)
        # The integration suite stops on its first error. Attempt Python-side
        # safety recovery, but never rearm here: transfer_dma may already be
        # IDLE, and the A3 helper reports some failures instead of proving full
        # recovery. Preserve and re-raise the original BaseException; main's
        # finally closes the owned channels.
        try:
            a3._recover_transaction()
        except BaseException as recovery_error:
            print("A4_RECOVERY_HELPER_ERROR ORIGINAL={} RECOVERY={}".format(
                a3.format_error(caught), a3.format_error(recovery_error)))
        raise
    finally:
        a3.last_transaction_end_to_end_time_us = ticks_diff(ticks_us(), start)


def _percentile(sorted_values, numerator, denominator):
    index = (len(sorted_values) * numerator + denominator - 1) // denominator - 1
    if index < 0:
        index = 0
    return sorted_values[index]


def reset_performance_capture():
    global perf_sample_count, performance_capture_armed
    global performance_capture_expected_count, performance_capture_label
    global performance_capture_pio_hz, performance_capture_request_length
    global performance_capture_response_length
    perf_sample_count = 0
    if PERF_SAMPLES is not None:
        for index in range(len(PERF_SAMPLES)):
            PERF_SAMPLES[index] = 0
    if PERF_METRIC_TOTALS is not None:
        for index in range(len(PERF_METRIC_TOTALS)):
            PERF_METRIC_TOTALS[index] = 0
    performance_capture_armed = False
    performance_capture_expected_count = 0
    performance_capture_label = ""
    performance_capture_pio_hz = 0
    performance_capture_request_length = 0
    performance_capture_response_length = 0


def begin_performance_capture(label, expected_count, pio_hz,
                              request_length, response_length):
    global PERF_SAMPLES, PERF_METRIC_TOTALS
    global performance_capture_armed, performance_capture_expected_count
    global performance_capture_label, performance_capture_pio_hz
    global performance_capture_request_length, performance_capture_response_length
    if not PERFORMANCE_MODE:
        raise RuntimeError("performance mode is disabled")
    if expected_count < 1 or expected_count > a3.DMA_BULK_LOOP_COUNT:
        raise ValueError("performance expected_count out of range")
    reset_performance_capture()
    if PERF_SAMPLES is None or len(PERF_SAMPLES) != expected_count:
        PERF_SAMPLES = array("I", [0] * expected_count)
    if PERF_METRIC_TOTALS is None:
        PERF_METRIC_TOTALS = array("I", [0] * len(PERF_METRIC_NAMES))
    performance_capture_expected_count = expected_count
    performance_capture_label = label
    performance_capture_pio_hz = pio_hz
    performance_capture_request_length = request_length
    performance_capture_response_length = response_length
    performance_capture_armed = True


def end_performance_capture():
    global performance_capture_armed
    performance_capture_armed = False
    if perf_sample_count != performance_capture_expected_count:
        raise AssertionError("performance capture count mismatch: {} != {}".format(
            perf_sample_count, performance_capture_expected_count))


def print_performance_summary():
    """Aggregate preallocated samples; call only after the timed packet loop."""
    count = perf_sample_count
    if not PERFORMANCE_MODE or count == 0 or performance_capture_armed:
        print("A4_PERFORMANCE_SUMMARY STATUS=DISABLED_OR_EMPTY")
        return
    samples = sorted(PERF_SAMPLES[:count])
    total = sum(samples)
    print(
        "A4_PERFORMANCE_SUMMARY LABEL={} COUNT={} EXPECTED_COUNT={} "
        "PIO_HZ={} REQUEST_LENGTH={} RESPONSE_LENGTH={} TOTAL_US={} "
        "AVERAGE_US={} MEDIAN_US={} P95_US={} MAX_US={} "
        "PAYLOAD_AND_COMPARE_INCLUDED=NO WARMUP_COUNT={}".format(
            performance_capture_label, count, performance_capture_expected_count,
            performance_capture_pio_hz, performance_capture_request_length,
            performance_capture_response_length, total, total / count,
            _percentile(samples, 1, 2), _percentile(samples, 95, 100),
            samples[-1], PERFORMANCE_WARMUP_COUNT))
    assert PERF_METRIC_TOTALS is not None
    for total_value, name in zip(PERF_METRIC_TOTALS, PERF_METRIC_NAMES):
        print("A4_METRIC NAME={} TOTAL={} AVERAGE={}".format(
            name, total_value, total_value / count))


def run_performance_suite():
    """Run only 4MHz/256-byte/1000-packet A3-compatible bulk capture."""
    a3.init_state_machine(PERFORMANCE_PIO_HZ)
    for index in range(a3.DMA_BULK_LOOP_LENGTH):
        value = (index * 29 + 7) & 0xff
        a3.burst_tx[index] = value
        a3.burst_expected[index] = value ^ 0xff
    # Warm-up is deliberately complete before capture is armed.
    for _ in range(PERFORMANCE_WARMUP_COUNT):
        a3.transfer_burst(a3.DMA_BULK_LOOP_LENGTH)
        assert a3.response_buffer[0] == 0
        for index in range(a3.DMA_BULK_LOOP_LENGTH):
            assert a3.response_buffer[index + 1] == a3.burst_expected[index]
    begin_performance_capture(
        "A4_4MHZ_256BYTE_1000PACKET",
        a3.DMA_BULK_LOOP_COUNT,
        PERFORMANCE_PIO_HZ,
        PERFORMANCE_REQUEST_LENGTH,
        PERFORMANCE_RESPONSE_LENGTH,
    )
    passed = False
    body_error = None
    capture_error = None
    try:
        passed = a3.run_dma_bulk_loop_test()
    except BaseException as error:
        body_error = error
    finally:
        try:
            end_performance_capture()
        except BaseException as error:
            capture_error = error
            print("A4_CAPTURE_END_ERROR DETAIL={}".format(a3.format_error(error)))
    if body_error is not None:
        raise body_error
    if capture_error is not None:
        raise capture_error
    print_performance_summary()
    return passed


def shutdown_a4():
    """Attempt every cleanup and return the first BaseException, if any."""
    first_error = None
    try:
        if a3.sm is not None:
            a3.stop_state_machine_safely()
    except BaseException as error:
        first_error = error
        print("A4_STOP_SM_ERROR DETAIL={}".format(a3.format_error(error)))
    try:
        c.dma_close()
    except BaseException as error:
        if first_error is None:
            first_error = error
        print("A4_DMA_CLOSE_ERROR DETAIL={}".format(a3.format_error(error)))
    else:
        try:
            status = c.dma_status()
            assert status["state"] == "CLOSED"
            assert status["tx_channel"] == -1
            assert status["rx_channel"] == -1
            assert status["tx_claimed"] is False
            assert status["rx_claimed"] is False
        except BaseException as error:
            if first_error is None:
                first_error = error
            print("A4_CLOSED_VERIFY_ERROR DETAIL={}".format(a3.format_error(error)))
    return first_error


def run_marker_mismatch_hardware_test(request, request_length, response, response_length):
    """Terminal test: call only after this adapter initialized PIO and FPGA."""
    before_response = bytes(response)
    before_raw = bytes(a3.response_raw_gpio_nibbles)
    print("INJECTION_KIND=HARDWARE_DEPENDENT FAULT=MARKER_MISMATCH")
    c.config(7)
    try:
        transfer_a4(request, request_length, response, response_length)
        raise AssertionError("MARKER_MISMATCH did not raise")
    except c.ProtocolError:
        status = c.dma_status()
        assert status["state"] == "ABORTED"
        assert status["last_stage"] == "CHECK_MARKER"
        assert bytes(response) == before_response
        assert bytes(a3.response_raw_gpio_nibbles) == before_raw
    finally:
        c.config(0)


def main():
    if c.version() != "0.1.0-a4":
        raise RuntimeError("wrong shrike_parallel_c version")
    gc.enable()

    # Must precede FPGA/bus/PIO initialization, including after soft reboot.
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
        event_poll_interval_us=EVENT_POLL_INTERVAL_US,
    )
    a3.tx_dma_channel, a3.rx_dma_channel = tx_channel, rx_channel
    a3.tx_dma, a3.rx_dma = _OwnedDMAView(tx_channel), _OwnedDMAView(rx_channel)
    a3.transfer = transfer_a4

    passed = False
    body_error = None
    cleanup_error = None
    try:
        # recover=True invalidates all former peripheral assumptions.
        gc.collect()
        a3.program_fpga()
        gc.collect()
        a3.initialize_bus()
        a3.run_local_self_tests()
        if PERFORMANCE_MODE:
            passed = run_performance_suite()
        else:
            passed = True
            for frequency in a3.PIO_CLOCKS_HZ:
                if not a3.run_frequency_suite(frequency):
                    passed = False
                    break
    except BaseException as caught:
        passed = False
        body_error = caught
        print("A4_FATAL ERROR={}".format(a3.format_error(caught)))
    finally:
        cleanup_error = shutdown_a4()
        if cleanup_error is not None:
            passed = False
        print("A4_SUMMARY RESULT={} EVENT_POLL_INTERVAL_US={} PERFORMANCE_MODE={}".format(
            "PASS" if passed else "FAIL", EVENT_POLL_INTERVAL_US, PERFORMANCE_MODE))
    if body_error is not None:
        raise body_error
    if cleanup_error is not None:
        raise cleanup_error


if __name__ == "__main__":
    main()
