#include <stdint.h>
#include <string.h>

// MicroPython API
#include "py/binary.h"
#include "py/runtime.h"

// Phase 5-A3では純粋なpack/unpackだけをC化し、PIO、DMA、GPIOには触れない。
enum {
    TX_CONTROL_WORDS = 2,
    NIBBLES_PER_WORD = 8,
    MAX_REQUEST_BYTES = 258,
    MAX_RESPONSE_BYTES = 257,
    MAX_TX_NIBBLES = 516,
    MAX_RX_NIBBLES = 514,
    MAX_TX_DATA_WORDS = 65,
    MAX_RX_DATA_WORDS = 65,
    MAX_TX_TOTAL_WORDS = 67,
};

static const uint8_t logical_to_gpio[16] = {
    0x0, 0x4, 0x2, 0x6,
    0x8, 0xC, 0xA, 0xE,
    0x1, 0x5, 0x3, 0x7,
    0x9, 0xD, 0xB, 0xF,
};

static const uint8_t gpio_to_logical[16] = {
    0x0, 0x8, 0x2, 0xA,
    0x1, 0x9, 0x3, 0xB,
    0x4, 0xC, 0x6, 0xE,
    0x5, 0xD, 0x7, 0xF,
};

static const char shrike_parallel_c_version_string[] = "0.1.0-a3";

// bytearrayは専用typecodeを使うため、要素サイズだけでなく明示的に受理する。
static bool shrike_parallel_c_is_byte_typecode(int typecode) {
    return typecode == BYTEARRAY_TYPECODE || typecode == 'b' || typecode == 'B';
}

static void shrike_parallel_c_get_byte_buffer(
    mp_obj_t object,
    mp_buffer_info_t *buffer,
    mp_uint_t flags
) {
    mp_get_buffer_raise(object, buffer, flags);
    if (!shrike_parallel_c_is_byte_typecode(buffer->typecode)) {
        mp_raise_TypeError(MP_ERROR_TEXT("byte-oriented buffer required"));
    }
}

static void shrike_parallel_c_get_word_buffer(
    mp_obj_t object,
    mp_buffer_info_t *buffer,
    mp_uint_t flags
) {
    mp_get_buffer_raise(object, buffer, flags);

    // 4byte単位でないbufferは32bit word列として境界を定義できない。
    if ((buffer->len % sizeof(uint32_t)) != 0) {
        mp_raise_ValueError(MP_ERROR_TEXT("word buffer size must be a multiple of 4"));
    }
    if (
        buffer->typecode != 'I'
        || mp_binary_get_size('@', buffer->typecode, NULL) != sizeof(uint32_t)
    ) {
        mp_raise_TypeError(MP_ERROR_TEXT("array('I') compatible buffer required"));
    }
}

// raw pointerをuint32_tポインタへcastせず、未整列アクセスを避ける。
static uint32_t shrike_parallel_c_load_word(
    const mp_buffer_info_t *buffer,
    size_t word_index
) {
    uint32_t value;
    memcpy(
        &value,
        (const uint8_t *)buffer->buf + word_index * sizeof(value),
        sizeof(value)
    );
    return value;
}

static void shrike_parallel_c_store_word(
    const mp_buffer_info_t *buffer,
    size_t word_index,
    uint32_t value
) {
    memcpy(
        (uint8_t *)buffer->buf + word_index * sizeof(value),
        &value,
        sizeof(value)
    );
}

static mp_int_t shrike_parallel_c_get_request_length(mp_obj_t object) {
    mp_int_t length = mp_obj_get_int(object);
    if (length < 1 || length > MAX_REQUEST_BYTES) {
        mp_raise_ValueError(MP_ERROR_TEXT("request_length out of range"));
    }
    return length;
}

static mp_int_t shrike_parallel_c_get_response_length(mp_obj_t object) {
    mp_int_t length = mp_obj_get_int(object);
    if (length < 1 || length > MAX_RESPONSE_BYTES) {
        mp_raise_ValueError(MP_ERROR_TEXT("response_length out of range"));
    }
    return length;
}

// shrike_parallel_c.version()
static mp_obj_t shrike_parallel_c_version(void) {
    return mp_obj_new_str(
        shrike_parallel_c_version_string,
        sizeof(shrike_parallel_c_version_string) - 1
    );
}
static MP_DEFINE_CONST_FUN_OBJ_0(
    shrike_parallel_c_version_obj,
    shrike_parallel_c_version
);

// shrike_parallel_c.pack_tx_words(request_bytes, request_length, response_length, tx_words)
static mp_obj_t shrike_parallel_c_pack_tx_words(
    mp_obj_t request_bytes_object,
    mp_obj_t request_length_object,
    mp_obj_t response_length_object,
    mp_obj_t tx_words_object
) {
    // length変換、全buffer検証、戻り値生成を完了するまで出力へ書き込まない。
    mp_int_t request_length_value =
        shrike_parallel_c_get_request_length(request_length_object);
    mp_int_t response_length_value =
        shrike_parallel_c_get_response_length(response_length_object);
    size_t request_length = (size_t)request_length_value;
    size_t response_length = (size_t)response_length_value;
    size_t nibble_count = request_length * 2;
    size_t response_nibble_count = response_length * 2;
    size_t data_words =
        (nibble_count + NIBBLES_PER_WORD - 1) / NIBBLES_PER_WORD;
    size_t total_words = TX_CONTROL_WORDS + data_words;

    if (
        nibble_count > MAX_TX_NIBBLES
        || response_nibble_count > MAX_RX_NIBBLES
        || data_words > MAX_TX_DATA_WORDS
        || total_words > MAX_TX_TOTAL_WORDS
    ) {
        mp_raise_ValueError(MP_ERROR_TEXT("pack result exceeds A3 limit"));
    }

    mp_buffer_info_t request_buffer;
    mp_buffer_info_t tx_buffer;
    shrike_parallel_c_get_byte_buffer(
        request_bytes_object,
        &request_buffer,
        MP_BUFFER_READ
    );
    shrike_parallel_c_get_word_buffer(
        tx_words_object,
        &tx_buffer,
        MP_BUFFER_WRITE
    );

    if (request_buffer.len < request_length) {
        mp_raise_ValueError(MP_ERROR_TEXT("request buffer is too short"));
    }
    if (tx_buffer.len / sizeof(uint32_t) < total_words) {
        mp_raise_ValueError(MP_ERROR_TEXT("tx word buffer is too short"));
    }

    mp_obj_t tuple_items[3] = {
        mp_obj_new_int_from_uint(total_words),
        mp_obj_new_int_from_uint(data_words),
        mp_obj_new_int_from_uint(nibble_count),
    };
    mp_obj_t result = mp_obj_new_tuple(3, tuple_items);

    const uint8_t *request_bytes = (const uint8_t *)request_buffer.buf;

    // JMP X--/Y--は初期値0でも1回実行されるため、ニブル数-1を設定する。
    shrike_parallel_c_store_word(
        &tx_buffer,
        0,
        (uint32_t)(nibble_count - 1)
    );
    shrike_parallel_c_store_word(
        &tx_buffer,
        1,
        (uint32_t)(response_nibble_count - 1)
    );

    for (size_t word_index = 0; word_index < data_words; ++word_index) {
        uint32_t word = 0;
        size_t first_nibble = word_index * NIBBLES_PER_WORD;
        size_t remaining = nibble_count - first_nibble;
        size_t valid_nibbles =
            remaining < NIBBLES_PER_WORD ? remaining : NIBBLES_PER_WORD;

        for (
            size_t word_nibble_index = 0;
            word_nibble_index < valid_nibbles;
            ++word_nibble_index
        ) {
            size_t nibble_index = first_nibble + word_nibble_index;
            uint8_t byte_value = request_bytes[nibble_index >> 1];
            uint8_t logical_nibble =
                (nibble_index & 1)
                ? byte_value & 0x0f
                : (byte_value >> 4) & 0x0f;
            uint32_t gpio_nibble = logical_to_gpio[logical_nibble];
            word |= gpio_nibble << (word_nibble_index * 4);
        }

        // ローカルwordは0初期化済みなので、末尾の未使用ニブルも0になる。
        shrike_parallel_c_store_word(
            &tx_buffer,
            TX_CONTROL_WORDS + word_index,
            word
        );
    }

    return result;
}
static mp_obj_t shrike_parallel_c_pack_tx_words_wrapper(
    size_t n_args,
    const mp_obj_t *args
) {
    (void)n_args;
    return shrike_parallel_c_pack_tx_words(
        args[0],
        args[1],
        args[2],
        args[3]
    );
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(
    shrike_parallel_c_pack_tx_words_obj,
    4,
    4,
    shrike_parallel_c_pack_tx_words_wrapper
);

// shrike_parallel_c.unpack_rx_words(rx_words, response_bytes, response_length, raw_nibbles)
static mp_obj_t shrike_parallel_c_unpack_rx_words(
    mp_obj_t rx_words_object,
    mp_obj_t response_bytes_object,
    mp_obj_t response_length_object,
    mp_obj_t raw_nibbles_object
) {
    // 戻り値生成を含む全準備を終えるまで、2つの出力bufferへ書き込まない。
    mp_int_t response_length_value =
        shrike_parallel_c_get_response_length(response_length_object);
    size_t response_length = (size_t)response_length_value;
    size_t response_nibble_count = response_length * 2;
    size_t data_words =
        (response_nibble_count + NIBBLES_PER_WORD - 1) / NIBBLES_PER_WORD;

    if (
        response_nibble_count > MAX_RX_NIBBLES
        || data_words > MAX_RX_DATA_WORDS
    ) {
        mp_raise_ValueError(MP_ERROR_TEXT("unpack result exceeds A3 limit"));
    }

    mp_buffer_info_t rx_buffer;
    mp_buffer_info_t response_buffer;
    mp_buffer_info_t raw_buffer;
    shrike_parallel_c_get_word_buffer(
        rx_words_object,
        &rx_buffer,
        MP_BUFFER_READ
    );
    shrike_parallel_c_get_byte_buffer(
        response_bytes_object,
        &response_buffer,
        MP_BUFFER_WRITE
    );
    shrike_parallel_c_get_byte_buffer(
        raw_nibbles_object,
        &raw_buffer,
        MP_BUFFER_WRITE
    );

    if (rx_buffer.len / sizeof(uint32_t) < data_words) {
        mp_raise_ValueError(MP_ERROR_TEXT("rx word buffer is too short"));
    }
    if (response_buffer.len < response_length) {
        mp_raise_ValueError(MP_ERROR_TEXT("response buffer is too short"));
    }
    if (raw_buffer.len < response_nibble_count) {
        mp_raise_ValueError(MP_ERROR_TEXT("raw nibble buffer is too short"));
    }

    mp_obj_t result = mp_obj_new_int_from_uint(data_words);
    uint8_t *response_bytes = (uint8_t *)response_buffer.buf;
    uint8_t *raw_nibbles = (uint8_t *)raw_buffer.buf;

    for (size_t word_index = 0; word_index < data_words; ++word_index) {
        uint32_t word = shrike_parallel_c_load_word(&rx_buffer, word_index);
        size_t first_nibble = word_index * NIBBLES_PER_WORD;
        size_t remaining = response_nibble_count - first_nibble;
        size_t valid_nibbles =
            remaining < NIBBLES_PER_WORD ? remaining : NIBBLES_PER_WORD;

        for (
            size_t word_nibble_index = 0;
            word_nibble_index < valid_nibbles;
            ++word_nibble_index
        ) {
            size_t shift;
            if (valid_nibbles == NIBBLES_PER_WORD) {
                shift = word_nibble_index * 4;
            } else {
                // SHIFT_RIGHTの端数wordは有効ニブルが上位側へ寄る。
                shift =
                    (NIBBLES_PER_WORD - valid_nibbles + word_nibble_index) * 4;
            }

            size_t nibble_index = first_nibble + word_nibble_index;
            uint8_t gpio_nibble = (word >> shift) & 0x0f;
            uint8_t logical_nibble = gpio_to_logical[gpio_nibble];
            size_t byte_index = nibble_index >> 1;

            raw_nibbles[nibble_index] = gpio_nibble;
            if (nibble_index & 1) {
                response_bytes[byte_index] |= logical_nibble;
            } else {
                response_bytes[byte_index] = logical_nibble << 4;
            }
        }
    }

    return result;
}
static mp_obj_t shrike_parallel_c_unpack_rx_words_wrapper(
    size_t n_args,
    const mp_obj_t *args
) {
    (void)n_args;
    return shrike_parallel_c_unpack_rx_words(
        args[0],
        args[1],
        args[2],
        args[3]
    );
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(
    shrike_parallel_c_unpack_rx_words_obj,
    4,
    4,
    shrike_parallel_c_unpack_rx_words_wrapper
);

// モジュール属性
static const mp_rom_map_elem_t shrike_parallel_c_module_globals_table[] = {
    {
        MP_ROM_QSTR(MP_QSTR___name__),
        MP_ROM_QSTR(MP_QSTR_shrike_parallel_c)
    },
    {
        MP_ROM_QSTR(MP_QSTR_version),
        MP_ROM_PTR(&shrike_parallel_c_version_obj)
    },
    {
        MP_ROM_QSTR(MP_QSTR_pack_tx_words),
        MP_ROM_PTR(&shrike_parallel_c_pack_tx_words_obj)
    },
    {
        MP_ROM_QSTR(MP_QSTR_unpack_rx_words),
        MP_ROM_PTR(&shrike_parallel_c_unpack_rx_words_obj)
    },
};
static MP_DEFINE_CONST_DICT(
    shrike_parallel_c_module_globals,
    shrike_parallel_c_module_globals_table
);

// モジュール本体
const mp_obj_module_t shrike_parallel_c_user_cmodule = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&shrike_parallel_c_module_globals,
};

// MicroPythonへ登録
MP_REGISTER_MODULE(MP_QSTR_shrike_parallel_c, shrike_parallel_c_user_cmodule);
