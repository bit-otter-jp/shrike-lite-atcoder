from array import array
import shrike_parallel_c


TX_CONTROL_WORDS = 2
NIBBLES_PER_WORD = 8
MAX_REQUEST_BYTES = 258
MAX_RESPONSE_BYTES = 257
MAX_TX_DATA_WORDS = 65
MAX_RX_DATA_WORDS = 65
TX_TEST_WORDS = 68
RX_TEST_WORDS = 67
COMPLETION_MARKER = 0xFFFFFFFF
TX_SENTINEL = 0xA5A55A5A
RX_SENTINEL = 0x13579BDF
RESPONSE_SENTINEL = 0xA5
RAW_SENTINEL = 0x5A

logical_to_gpio = (
    0x0, 0x4, 0x2, 0x6,
    0x8, 0xC, 0xA, 0xE,
    0x1, 0x5, 0x3, 0x7,
    0x9, 0xD, 0xB, 0xF,
)
gpio_to_logical = (
    0x0, 0x8, 0x2, 0xA,
    0x1, 0x9, 0x3, 0xB,
    0x4, 0xC, 0x6, 0xE,
    0x5, 0xD, 0x7, 0xF,
)


def fail(label, length=None, index=None, python_value=None, c_value=None,
         expected_exception=None, actual_exception=None):
    print(
        "A3_FAIL label={} length={} index={} python={} c={} "
        "expected_exception={} actual_exception={}".format(
            label,
            length,
            index,
            python_value,
            c_value,
            expected_exception,
            actual_exception,
        )
    )
    raise AssertionError(label)


def check_equal(label, python_value, c_value, length=None, index=None):
    if python_value != c_value:
        fail(
            label,
            length=length,
            index=index,
            python_value=python_value,
            c_value=c_value,
        )


def fill_words(buffer, value):
    for index in range(len(buffer)):
        buffer[index] = value


def fill_bytes(buffer, value):
    for index in range(len(buffer)):
        buffer[index] = value


def python_pack_tx_words(
    request_bytes,
    request_length,
    response_length,
    output_words,
):
    request_nibble_count = request_length * 2
    response_nibble_count = response_length * 2
    data_word_count = (
        request_nibble_count + NIBBLES_PER_WORD - 1
    ) // NIBBLES_PER_WORD

    output_words[0] = request_nibble_count - 1
    output_words[1] = response_nibble_count - 1

    for word_index in range(data_word_count):
        output_words[TX_CONTROL_WORDS + word_index] = 0

    for nibble_index in range(request_nibble_count):
        byte_value = request_bytes[nibble_index >> 1]
        if nibble_index & 1:
            logical_nibble = byte_value & 0x0F
        else:
            logical_nibble = (byte_value >> 4) & 0x0F

        gpio_nibble = logical_to_gpio[logical_nibble]
        word_index = nibble_index // NIBBLES_PER_WORD
        word_nibble_index = nibble_index & (NIBBLES_PER_WORD - 1)
        output_words[TX_CONTROL_WORDS + word_index] |= (
            gpio_nibble << (word_nibble_index * 4)
        )

    return (
        TX_CONTROL_WORDS + data_word_count,
        data_word_count,
        request_nibble_count,
    )


def python_unpack_rx_words(
    input_words,
    response_bytes,
    response_length,
    raw_gpio_nibbles,
):
    response_nibble_count = response_length * 2
    data_word_count = (
        response_nibble_count + NIBBLES_PER_WORD - 1
    ) // NIBBLES_PER_WORD

    for nibble_index in range(response_nibble_count):
        word_index = nibble_index // NIBBLES_PER_WORD
        word_nibble_index = nibble_index & (NIBBLES_PER_WORD - 1)
        remaining = response_nibble_count - word_index * NIBBLES_PER_WORD
        valid_nibbles = (
            NIBBLES_PER_WORD
            if remaining >= NIBBLES_PER_WORD
            else remaining
        )

        if valid_nibbles == NIBBLES_PER_WORD:
            shift = word_nibble_index * 4
        else:
            shift = (
                NIBBLES_PER_WORD - valid_nibbles + word_nibble_index
            ) * 4

        gpio_nibble = (input_words[word_index] >> shift) & 0x0F
        logical_nibble = gpio_to_logical[gpio_nibble]
        raw_gpio_nibbles[nibble_index] = gpio_nibble

        byte_index = nibble_index >> 1
        if nibble_index & 1:
            response_bytes[byte_index] |= logical_nibble
        else:
            response_bytes[byte_index] = logical_nibble << 4

    return data_word_count


def build_rx_words(source_bytes, response_length, output_words):
    response_nibble_count = response_length * 2
    data_word_count = (
        response_nibble_count + NIBBLES_PER_WORD - 1
    ) // NIBBLES_PER_WORD

    for word_index in range(data_word_count):
        output_words[word_index] = 0
        first_nibble = word_index * NIBBLES_PER_WORD
        remaining = response_nibble_count - first_nibble
        valid_nibbles = (
            NIBBLES_PER_WORD
            if remaining >= NIBBLES_PER_WORD
            else remaining
        )

        for word_nibble_index in range(valid_nibbles):
            nibble_index = first_nibble + word_nibble_index
            byte_value = source_bytes[nibble_index >> 1]
            if nibble_index & 1:
                logical_nibble = byte_value & 0x0F
            else:
                logical_nibble = (byte_value >> 4) & 0x0F
            gpio_nibble = logical_to_gpio[logical_nibble]

            if valid_nibbles == NIBBLES_PER_WORD:
                shift = word_nibble_index * 4
            else:
                shift = (
                    NIBBLES_PER_WORD - valid_nibbles + word_nibble_index
                ) * 4
            output_words[word_index] |= gpio_nibble << shift

    return data_word_count


def snapshot(buffer):
    return tuple(buffer)


def expect_exception(
    label,
    expected_type,
    function,
    arguments,
    unchanged_buffers=(),
):
    before = tuple(snapshot(buffer) for buffer in unchanged_buffers)
    try:
        function(*arguments)
    except Exception as caught:
        if not isinstance(caught, expected_type):
            fail(
                label,
                expected_exception=expected_type.__name__,
                actual_exception=type(caught).__name__,
            )
    else:
        fail(
            label,
            expected_exception=expected_type.__name__,
            actual_exception="NONE",
        )

    for index in range(len(unchanged_buffers)):
        after = snapshot(unchanged_buffers[index])
        if after != before[index]:
            fail(
                label + "_BUFFER_CHANGED",
                index=index,
                python_value=before[index],
                c_value=after,
            )


def run_nibble_conversion_test():
    for logical_nibble in range(16):
        gpio_nibble = logical_to_gpio[logical_nibble]
        check_equal(
            "NIBBLE_ROUNDTRIP",
            logical_nibble,
            gpio_to_logical[gpio_nibble],
            index=logical_nibble,
        )


def run_pack_full_length_test():
    request = bytearray(MAX_REQUEST_BYTES)
    python_words = array("I", [TX_SENTINEL] * TX_TEST_WORDS)
    c_words = array("I", [TX_SENTINEL] * TX_TEST_WORDS)

    for request_length in range(1, MAX_REQUEST_BYTES + 1):
        for index in range(request_length):
            request[index] = (index * 37 + request_length) & 0xFF

        response_length = ((request_length * 29) % MAX_RESPONSE_BYTES) + 1
        fill_words(python_words, TX_SENTINEL)
        fill_words(c_words, TX_SENTINEL)
        python_result = python_pack_tx_words(
            request,
            request_length,
            response_length,
            python_words,
        )
        c_result = shrike_parallel_c.pack_tx_words(
            request,
            request_length,
            response_length,
            c_words,
        )
        check_equal("PACK_RETURN", python_result, c_result, request_length)

        total_words, data_words, nibble_count = python_result
        for index in range(total_words):
            check_equal(
                "PACK_WORD",
                python_words[index],
                c_words[index],
                request_length,
                index,
            )
        for index in range(total_words, len(c_words)):
            check_equal(
                "PACK_TAIL",
                TX_SENTINEL,
                c_words[index],
                request_length,
                index,
            )

        valid_last_nibbles = nibble_count % NIBBLES_PER_WORD
        if valid_last_nibbles:
            unused_mask = (
                0xFFFFFFFF << (valid_last_nibbles * 4)
            ) & 0xFFFFFFFF
            last_word = c_words[TX_CONTROL_WORDS + data_words - 1]
            check_equal(
                "PACK_UNUSED_NIBBLES",
                0,
                last_word & unused_mask,
                request_length,
                data_words - 1,
            )


def run_response_control_word_test():
    tx_words = array("I", [TX_SENTINEL] * TX_TEST_WORDS)
    request = bytes((0xA5,))
    for response_length in range(1, MAX_RESPONSE_BYTES + 1):
        fill_words(tx_words, TX_SENTINEL)
        result = shrike_parallel_c.pack_tx_words(
            request,
            1,
            response_length,
            tx_words,
        )
        check_equal(
            "PACK_RESPONSE_CONTROL",
            response_length * 2 - 1,
            tx_words[1],
            response_length,
            1,
        )
        for index in range(result[0], len(tx_words)):
            check_equal(
                "PACK_RESPONSE_CONTROL_TAIL",
                TX_SENTINEL,
                tx_words[index],
                response_length,
                index,
            )


def run_byte_input_and_word_memoryview_test():
    request_values = bytes((0x12, 0x34, 0xAB, 0xCD))
    request_bytearray = bytearray(request_values)
    variants = (
        ("bytes", request_values),
        ("bytearray", request_bytearray),
        ("memoryview_bytes", memoryview(request_values)),
        ("memoryview_bytearray", memoryview(request_bytearray)),
    )
    expected_words = array("I", [TX_SENTINEL] * 8)
    expected_result = python_pack_tx_words(
        request_values,
        len(request_values),
        7,
        expected_words,
    )

    for label, request in variants:
        backing_words = array("I", [TX_SENTINEL] * 8)
        output_view = memoryview(backing_words)
        result = shrike_parallel_c.pack_tx_words(
            request,
            len(request_values),
            7,
            output_view,
        )
        check_equal(label + "_RETURN", expected_result, result)
        for index in range(expected_result[0]):
            check_equal(
                label + "_WORD",
                expected_words[index],
                backing_words[index],
                index=index,
            )


def run_unpack_full_length_test():
    source = bytearray(MAX_RESPONSE_BYTES)
    rx_words = array("I", [RX_SENTINEL] * RX_TEST_WORDS)
    python_response = bytearray(MAX_RESPONSE_BYTES + 2)
    c_response = bytearray(MAX_RESPONSE_BYTES + 2)
    python_raw = bytearray(MAX_RESPONSE_BYTES * 2 + 2)
    c_raw = bytearray(MAX_RESPONSE_BYTES * 2 + 2)

    for response_length in range(1, MAX_RESPONSE_BYTES + 1):
        for index in range(response_length):
            source[index] = (index * 53 + response_length) & 0xFF

        fill_words(rx_words, RX_SENTINEL)
        data_words = build_rx_words(source, response_length, rx_words)
        marker_index = data_words
        rx_words[marker_index] = COMPLETION_MARKER

        fill_bytes(python_response, RESPONSE_SENTINEL)
        fill_bytes(c_response, RESPONSE_SENTINEL)
        fill_bytes(python_raw, RAW_SENTINEL)
        fill_bytes(c_raw, RAW_SENTINEL)

        python_result = python_unpack_rx_words(
            rx_words,
            python_response,
            response_length,
            python_raw,
        )
        c_result = shrike_parallel_c.unpack_rx_words(
            rx_words,
            c_response,
            response_length,
            c_raw,
        )
        check_equal(
            "UNPACK_RETURN",
            python_result,
            c_result,
            response_length,
        )

        for index in range(response_length):
            check_equal(
                "UNPACK_RESPONSE",
                python_response[index],
                c_response[index],
                response_length,
                index,
            )
        for index in range(response_length, len(c_response)):
            check_equal(
                "UNPACK_RESPONSE_TAIL",
                RESPONSE_SENTINEL,
                c_response[index],
                response_length,
                index,
            )

        nibble_count = response_length * 2
        for index in range(nibble_count):
            check_equal(
                "UNPACK_RAW",
                python_raw[index],
                c_raw[index],
                response_length,
                index,
            )
        for index in range(nibble_count, len(c_raw)):
            check_equal(
                "UNPACK_RAW_TAIL",
                RAW_SENTINEL,
                c_raw[index],
                response_length,
                index,
            )

        check_equal(
            "UNPACK_MARKER",
            COMPLETION_MARKER,
            rx_words[marker_index],
            response_length,
            marker_index,
        )
        for index in range(marker_index + 1, len(rx_words)):
            check_equal(
                "UNPACK_RX_TAIL",
                RX_SENTINEL,
                rx_words[index],
                response_length,
                index,
            )


def run_writable_output_memoryview_test():
    source = bytes((0x12, 0x34, 0xAB))
    rx_backing = array("I", [0] * 4)
    data_words = build_rx_words(source, len(source), rx_backing)
    rx_backing[data_words] = COMPLETION_MARKER
    rx_view = memoryview(rx_backing)

    response_backing = bytearray((RESPONSE_SENTINEL,) * 5)
    raw_backing = bytearray((RAW_SENTINEL,) * 8)
    result = shrike_parallel_c.unpack_rx_words(
        rx_view,
        memoryview(response_backing),
        len(source),
        memoryview(raw_backing),
    )
    check_equal("MEMORYVIEW_UNPACK_RETURN", data_words, result)

    for index in range(len(source)):
        check_equal(
            "MEMORYVIEW_UNPACK_RESPONSE",
            source[index],
            response_backing[index],
            index=index,
        )
    check_equal(
        "MEMORYVIEW_UNPACK_RESPONSE_TAIL",
        RESPONSE_SENTINEL,
        response_backing[len(source)],
    )
    check_equal(
        "MEMORYVIEW_UNPACK_RESPONSE_TAIL",
        RESPONSE_SENTINEL,
        response_backing[len(source) + 1],
    )


def run_exception_tests():
    request = bytes((0x12, 0x34, 0x56, 0x78))
    tx_words = array("I", [TX_SENTINEL] * 8)

    for label, request_length in (
        ("REQUEST_LENGTH_ZERO", 0),
        ("REQUEST_LENGTH_HIGH", 259),
        ("REQUEST_LENGTH_NEGATIVE", -1),
    ):
        fill_words(tx_words, TX_SENTINEL)
        expect_exception(
            label,
            ValueError,
            shrike_parallel_c.pack_tx_words,
            (request, request_length, 1, tx_words),
            (tx_words,),
        )

    for label, response_length in (
        ("PACK_RESPONSE_LENGTH_ZERO", 0),
        ("PACK_RESPONSE_LENGTH_HIGH", 258),
        ("PACK_RESPONSE_LENGTH_NEGATIVE", -1),
    ):
        fill_words(tx_words, TX_SENTINEL)
        expect_exception(
            label,
            ValueError,
            shrike_parallel_c.pack_tx_words,
            (request, 1, response_length, tx_words),
            (tx_words,),
        )

    expect_exception(
        "PACK_LENGTH_TYPE",
        TypeError,
        shrike_parallel_c.pack_tx_words,
        (request, "1", 1, tx_words),
        (tx_words,),
    )
    expect_exception(
        "PACK_REQUEST_NONBUFFER",
        TypeError,
        shrike_parallel_c.pack_tx_words,
        (object(), 1, 1, tx_words),
        (tx_words,),
    )
    expect_exception(
        "PACK_REQUEST_WRONG_ITEMSIZE",
        TypeError,
        shrike_parallel_c.pack_tx_words,
        (array("H", [0]), 1, 1, tx_words),
        (tx_words,),
    )
    expect_exception(
        "PACK_REQUEST_SHORT",
        ValueError,
        shrike_parallel_c.pack_tx_words,
        (bytes(1), 2, 1, tx_words),
        (tx_words,),
    )
    expect_exception(
        "PACK_TX_READONLY",
        TypeError,
        shrike_parallel_c.pack_tx_words,
        (request, 1, 1, memoryview(bytes(12))),
    )
    expect_exception(
        "PACK_TX_NONBUFFER",
        TypeError,
        shrike_parallel_c.pack_tx_words,
        (request, 1, 1, object()),
    )
    expect_exception(
        "PACK_TX_WRONG_TYPECODE",
        TypeError,
        shrike_parallel_c.pack_tx_words,
        (request, 1, 1, array("H", [0] * 6)),
    )
    expect_exception(
        "PACK_TX_ODD_BYTE_COUNT",
        ValueError,
        shrike_parallel_c.pack_tx_words,
        (request, 1, 1, bytearray(3)),
    )
    short_tx = array("I", [TX_SENTINEL] * 2)
    expect_exception(
        "PACK_TX_SHORT",
        ValueError,
        shrike_parallel_c.pack_tx_words,
        (request, 1, 1, short_tx),
        (short_tx,),
    )

    response_length = 5
    rx_words = array("I", [0] * 4)
    build_rx_words(request + bytes((0x9A,)), response_length, rx_words)
    response = bytearray((RESPONSE_SENTINEL,) * response_length)
    raw = bytearray((RAW_SENTINEL,) * (response_length * 2))

    for label, invalid_length in (
        ("UNPACK_RESPONSE_LENGTH_ZERO", 0),
        ("UNPACK_RESPONSE_LENGTH_HIGH", 258),
        ("UNPACK_RESPONSE_LENGTH_NEGATIVE", -1),
    ):
        fill_bytes(response, RESPONSE_SENTINEL)
        fill_bytes(raw, RAW_SENTINEL)
        expect_exception(
            label,
            ValueError,
            shrike_parallel_c.unpack_rx_words,
            (rx_words, response, invalid_length, raw),
            (response, raw),
        )

    expect_exception(
        "UNPACK_LENGTH_TYPE",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, response, "5", raw),
        (response, raw),
    )
    expect_exception(
        "UNPACK_RX_NONBUFFER",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (object(), response, response_length, raw),
        (response, raw),
    )
    expect_exception(
        "UNPACK_RX_WRONG_TYPECODE",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (array("H", [0] * 4), response, response_length, raw),
        (response, raw),
    )
    expect_exception(
        "UNPACK_RX_ODD_BYTE_COUNT",
        ValueError,
        shrike_parallel_c.unpack_rx_words,
        (bytearray(3), response, response_length, raw),
        (response, raw),
    )
    short_rx = array("I", [0])
    expect_exception(
        "UNPACK_RX_SHORT",
        ValueError,
        shrike_parallel_c.unpack_rx_words,
        (short_rx, response, response_length, raw),
        (response, raw),
    )
    expect_exception(
        "UNPACK_RESPONSE_READONLY",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, memoryview(bytes(response_length)), response_length, raw),
        (raw,),
    )
    expect_exception(
        "UNPACK_RESPONSE_NONBUFFER",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, object(), response_length, raw),
        (raw,),
    )
    expect_exception(
        "UNPACK_RESPONSE_WRONG_ITEMSIZE",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, array("H", [0] * 3), response_length, raw),
        (raw,),
    )
    short_response = bytearray((RESPONSE_SENTINEL,) * (response_length - 1))
    expect_exception(
        "UNPACK_RESPONSE_SHORT",
        ValueError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, short_response, response_length, raw),
        (short_response, raw),
    )
    expect_exception(
        "UNPACK_RAW_READONLY",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, response, response_length, memoryview(bytes(response_length * 2))),
        (response,),
    )
    expect_exception(
        "UNPACK_RAW_NONBUFFER",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, response, response_length, object()),
        (response,),
    )
    expect_exception(
        "UNPACK_RAW_WRONG_ITEMSIZE",
        TypeError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, response, response_length, array("H", [0] * 5)),
        (response,),
    )
    short_raw = bytearray((RAW_SENTINEL,) * (response_length * 2 - 1))
    expect_exception(
        "UNPACK_RAW_SHORT",
        ValueError,
        shrike_parallel_c.unpack_rx_words,
        (rx_words, response, response_length, short_raw),
        (response, short_raw),
    )


def print_boundaries():
    boundaries = (
        1, 2, 3, 4, 5, 15, 16, 17, 31, 32, 33,
        63, 64, 65, 127, 128, 129, 255, 256, 257, 258,
    )
    for length in boundaries:
        request_status = "PASS" if length <= MAX_REQUEST_BYTES else "N/A"
        response_status = "PASS" if length <= MAX_RESPONSE_BYTES else "N/A"
        print(
            "A3_BOUNDARY LENGTH={} REQUEST={} RESPONSE={}".format(
                length,
                request_status,
                response_status,
            )
        )


def main():
    check_equal("VERSION", "0.1.0-a4", shrike_parallel_c.version())
    run_nibble_conversion_test()
    run_pack_full_length_test()
    run_response_control_word_test()
    run_byte_input_and_word_memoryview_test()
    run_unpack_full_length_test()
    run_writable_output_memoryview_test()
    run_exception_tests()
    print_boundaries()
    print(
        "A3_PACK_UNPACK_DETAIL "
        "REQUEST_LENGTHS=1..258 RESPONSE_LENGTHS=1..257 "
        "BYTE_BUFFERS=PASS WORD_MEMORYVIEW=PASS "
        "TAIL_SENTINELS=PASS MARKER=PASS EXCEPTIONS=PASS"
    )
    print("A3_SOFT_REBOOT_REEXECUTE_REQUIRED")
    print("A4_PACK_UNPACK_REGRESSION_SUMMARY PASS")


main()
