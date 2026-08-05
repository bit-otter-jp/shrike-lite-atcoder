#include <errno.h>
#include <stdint.h>
#include <string.h>

#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/pio.h"
#include "hardware/regs/dma.h"
#include "pico/time.h"

#include "py/binary.h"
#include "py/mperrno.h"
#include "py/nlr.h"
#include "py/objexcept.h"
#include "py/objtuple.h"
#include "py/runtime.h"

#if MICROPY_ENABLE_VM_ABORT
#error "Phase 5-A4 DMA engine requires MICROPY_ENABLE_VM_ABORT=0"
#endif

#ifndef SHRIKE_PARALLEL_C_TEST_HOOKS
#define SHRIKE_PARALLEL_C_TEST_HOOKS (0)
#endif

enum {
    TX_CONTROL_WORDS = 2,
    NIBBLES_PER_WORD = 8,
    MAX_REQUEST_BYTES = 258,
    MAX_RESPONSE_BYTES = 257,
    MAX_TX_NIBBLES = 516,
    MAX_RX_NIBBLES = 514,
    MAX_TX_DATA_WORDS = 65,
    MAX_RX_DATA_WORDS = 65,
    TX_WORD_BUFFER_WORDS = 67,
    RX_WORD_BUFFER_WORDS = 66,
};

#define COMPLETION_MARKER UINT32_C(0xffffffff)
#define ENGINE_MAGIC UINT32_C(0x53483441)
#define ENGINE_ABI UINT32_C(1)
#define MAX_TIMEOUT_US UINT32_C(60000000)

typedef enum { ENGINE_CLOSED, ENGINE_IDLE, ENGINE_RUNNING, ENGINE_ABORTED } engine_state_t;
typedef enum {
    STAGE_CLOSED, STAGE_OPEN_VALIDATE, STAGE_OPEN_RECOVERY, STAGE_OPEN_CLAIM_TX,
    STAGE_OPEN_CLAIM_RX, STAGE_IDLE, STAGE_VALIDATE, STAGE_ALLOCATE_RESULT,
    STAGE_PACK_TX, STAGE_CLEAR_RX, STAGE_CONFIG_RX_DMA, STAGE_CONFIG_TX_DMA,
    STAGE_START_RX_DMA, STAGE_START_TX_DMA, STAGE_POLL_DMA, STAGE_WAIT_TX_DMA,
    STAGE_WAIT_REQ_HIGH, STAGE_WAIT_RX_FIRST_WORD, STAGE_WAIT_RX_PROGRESS,
    STAGE_WAIT_RX_COMPLETE, STAGE_WAIT_MARKER_WORD, STAGE_CHECK_DMA_ERROR,
    STAGE_CHECK_MARKER, STAGE_UNPACK_RX, STAGE_ABORTED, STAGE_CLOSE, STAGE_REARM
} stage_t;
typedef enum {
    ERR_NONE, ERR_TIMEOUT, ERR_MARKER, ERR_COUNT, ERR_DMA_READ, ERR_DMA_WRITE,
    ERR_DMA_AHB, ERR_CLEANUP_CLEAR
} dma_error_t;

typedef struct {
    uint32_t magic, abi_version, state;
    int32_t tx_channel, rx_channel;
    uint32_t owned_mask, pio_index, sm_index, req_pin;
    uint32_t req_assert_timeout_us, tx_timeout_us, rx_first_timeout_us;
    uint32_t rx_progress_timeout_us, rx_complete_timeout_us, marker_timeout_us;
    uint32_t event_poll_interval_us, last_stage, last_error_code;
    uint32_t last_cleanup_error_code, last_tx_words, last_rx_words;
    uint32_t pack_us, rx_clear_us, dma_config_us, poll_us, marker_us, unpack_us;
    uint32_t transfer_us, dma_time_us, event_poll_count;
} engine_t;

static engine_t engine;

#if SHRIKE_PARALLEL_C_TEST_HOOKS
typedef enum {
    HOOK_NONE, HOOK_WAIT_TX_DMA, HOOK_WAIT_REQ_HIGH, HOOK_WAIT_RX_FIRST_WORD,
    HOOK_WAIT_RX_PROGRESS, HOOK_WAIT_RX_COMPLETE, HOOK_WAIT_MARKER_WORD,
    HOOK_MARKER_MISMATCH, HOOK_SCHEDULER_EXCEPTION, HOOK_CLEANUP_ERROR_CLEAR
} hook_t;
static uint32_t test_hook;
#endif

static const uint8_t logical_to_gpio[16] = {
    0x0, 0x4, 0x2, 0x6, 0x8, 0xc, 0xa, 0xe,
    0x1, 0x5, 0x3, 0x7, 0x9, 0xd, 0xb, 0xf,
};
static const uint8_t gpio_to_logical[16] = {
    0x0, 0x8, 0x2, 0xa, 0x1, 0x9, 0x3, 0xb,
    0x4, 0xc, 0x6, 0xe, 0x5, 0xd, 0x7, 0xf,
};
static const char version_string[] = "0.1.0-a4";

MP_DEFINE_EXCEPTION(ProtocolError, Exception)
MP_DEFINE_EXCEPTION(ProtocolTimeout, ProtocolError)
MP_DEFINE_EXCEPTION(DMAError, ProtocolError)

static bool is_byte_typecode(int typecode) {
    return typecode == BYTEARRAY_TYPECODE || typecode == 'b' || typecode == 'B';
}

static void get_byte_buffer(mp_obj_t obj, mp_buffer_info_t *buf, mp_uint_t flags) {
    mp_get_buffer_raise(obj, buf, flags);
    if (!is_byte_typecode(buf->typecode)) {
        mp_raise_TypeError(MP_ERROR_TEXT("byte-oriented buffer required"));
    }
}

static void get_word_buffer(mp_obj_t obj, mp_buffer_info_t *buf, mp_uint_t flags) {
    mp_get_buffer_raise(obj, buf, flags);
    if ((buf->len % 4) != 0) {
        mp_raise_ValueError(MP_ERROR_TEXT("word buffer size must be a multiple of 4"));
    }
    if (buf->typecode != 'I' || mp_binary_get_size('@', buf->typecode, NULL) != 4) {
        mp_raise_TypeError(MP_ERROR_TEXT("array('I') compatible buffer required"));
    }
}

static uint32_t load_word(const mp_buffer_info_t *buf, size_t i) {
    uint32_t v;
    memcpy(&v, (const uint8_t *)buf->buf + i * 4, 4);
    return v;
}

static void store_word(const mp_buffer_info_t *buf, size_t i, uint32_t v) {
    memcpy((uint8_t *)buf->buf + i * 4, &v, 4);
}

static size_t get_length(mp_obj_t obj, size_t maximum, mp_rom_error_text_t message) {
    mp_int_t v = mp_obj_get_int(obj);
    if (v < 1 || (mp_uint_t)v > maximum) {
        mp_raise_ValueError(message);
    }
    return (size_t)v;
}

static void pack_no_raise(const uint8_t *request, size_t request_len,
    size_t response_len, const mp_buffer_info_t *tx) {
    size_t nibbles = request_len * 2;
    size_t words = (nibbles + 7) / 8;
    store_word(tx, 0, (uint32_t)nibbles - 1);
    store_word(tx, 1, (uint32_t)(response_len * 2) - 1);
    for (size_t wi = 0; wi < words; ++wi) {
        uint32_t word = 0;
        size_t valid = nibbles - wi * 8;
        if (valid > 8) valid = 8;
        for (size_t ni = 0; ni < valid; ++ni) {
            size_t i = wi * 8 + ni;
            uint8_t b = request[i >> 1];
            uint8_t n = (i & 1) ? b & 15 : (b >> 4) & 15;
            word |= (uint32_t)logical_to_gpio[n] << (ni * 4);
        }
        store_word(tx, TX_CONTROL_WORDS + wi, word);
    }
}

static void unpack_no_raise(const mp_buffer_info_t *rx, uint8_t *response,
    size_t response_len, uint8_t *raw) {
    size_t nibbles = response_len * 2;
    size_t words = (nibbles + 7) / 8;
    for (size_t wi = 0; wi < words; ++wi) {
        uint32_t word = load_word(rx, wi);
        size_t valid = nibbles - wi * 8;
        if (valid > 8) valid = 8;
        for (size_t ni = 0; ni < valid; ++ni) {
            size_t shift = valid == 8 ? ni * 4 : (8 - valid + ni) * 4;
            size_t i = wi * 8 + ni;
            uint8_t gpio_n = (word >> shift) & 15;
            uint8_t logical_n = gpio_to_logical[gpio_n];
            raw[i] = gpio_n;
            if (i & 1) response[i >> 1] |= logical_n;
            else response[i >> 1] = logical_n << 4;
        }
    }
}

static bool range_ok(const void *ptr, size_t len) {
    uintptr_t start = (uintptr_t)ptr;
    if (len == 0 || start > UINT32_MAX) return false;
    return len - 1 <= UINT32_MAX - start;
}

static bool ranges_overlap(const void *ap, size_t al, const void *bp, size_t bl) {
    uintptr_t a = (uintptr_t)ap, b = (uintptr_t)bp;
    return a < b + bl && b < a + al;
}

static void clear_metrics(void) {
    engine.pack_us = 0;
    engine.rx_clear_us = 0;
    engine.dma_config_us = 0;
    engine.poll_us = 0;
    engine.marker_us = 0;
    engine.unpack_us = 0;
    engine.transfer_us = 0;
    engine.dma_time_us = 0;
    engine.event_poll_count = 0;
}

static bool valid_channel(int32_t ch) { return ch >= 0 && ch < NUM_DMA_CHANNELS; }
static bool known_state(uint32_t s) { return s <= ENGINE_ABORTED; }
static bool has_record(void) { return engine.magic != 0 || engine.owned_mask != 0; }

static bool claim_shape_consistent(void) {
    if (!has_record()) return engine.magic == 0 && engine.owned_mask == 0;
    if (engine.magic != ENGINE_MAGIC || engine.abi_version != ENGINE_ABI ||
        !known_state(engine.state) || engine.state == ENGINE_CLOSED ||
        !valid_channel(engine.tx_channel) || !valid_channel(engine.rx_channel) ||
        engine.tx_channel == engine.rx_channel) return false;
    uint32_t mask = (1u << engine.tx_channel) | (1u << engine.rx_channel);
    return engine.owned_mask == mask && dma_channel_is_claimed(engine.tx_channel) &&
        dma_channel_is_claimed(engine.rx_channel);
}

static void cleanup_channel_no_raise(uint ch) {
    dma_channel_set_irq0_enabled(ch, false);
    dma_channel_set_irq1_enabled(ch, false);
    dma_channel_cleanup(ch);
    dma_channel_abort(ch);
    dma_hw->ints0 = 1u << ch;
    dma_hw->ints1 = 1u << ch;
    dma_channel_config safe = dma_channel_get_default_config(ch);
    channel_config_set_enable(&safe, false);
    channel_config_set_chain_to(&safe, ch);
    dma_hw->ch[ch].ctrl_trig = safe.ctrl | DMA_CH0_CTRL_TRIG_READ_ERROR_BITS |
        DMA_CH0_CTRL_TRIG_WRITE_ERROR_BITS;
    uint32_t ctrl = dma_hw->ch[ch].ctrl_trig;
    if (ctrl & (DMA_CH0_CTRL_TRIG_READ_ERROR_BITS | DMA_CH0_CTRL_TRIG_WRITE_ERROR_BITS |
        DMA_CH0_CTRL_TRIG_AHB_ERROR_BITS)) engine.last_cleanup_error_code = ERR_CLEANUP_CLEAR;
    dma_hw->ch[ch].transfer_count = 0;
    dma_hw->ch[ch].read_addr = 0;
    dma_hw->ch[ch].write_addr = 0;
}

static void cleanup_owned_no_raise(void) {
    engine.last_cleanup_error_code = ERR_NONE;
    if (!claim_shape_consistent()) return;
    cleanup_channel_no_raise((uint)engine.tx_channel);
    cleanup_channel_no_raise((uint)engine.rx_channel);
#if SHRIKE_PARALLEL_C_TEST_HOOKS
    if (test_hook == HOOK_CLEANUP_ERROR_CLEAR) engine.last_cleanup_error_code = ERR_CLEANUP_CLEAR;
#endif
}

static void clear_record(void) {
    memset(&engine, 0, sizeof(engine));
    engine.tx_channel = -1;
    engine.rx_channel = -1;
    engine.state = ENGINE_CLOSED;
    engine.last_stage = STAGE_CLOSED;
}

static const char *state_name(uint32_t v) {
    static const char *const names[] = { "CLOSED", "IDLE", "RUNNING", "ABORTED" };
    return v < MP_ARRAY_SIZE(names) ? names[v] : "UNKNOWN";
}

static const char *stage_name(uint32_t v) {
    static const char *const names[] = {
        "CLOSED", "OPEN_VALIDATE", "OPEN_RECOVERY", "OPEN_CLAIM_TX", "OPEN_CLAIM_RX",
        "IDLE", "VALIDATE", "ALLOCATE_RESULT", "PACK_TX", "CLEAR_RX", "CONFIG_RX_DMA",
        "CONFIG_TX_DMA", "START_RX_DMA", "START_TX_DMA", "POLL_DMA", "WAIT_TX_DMA",
        "WAIT_REQ_HIGH", "WAIT_RX_FIRST_WORD", "WAIT_RX_PROGRESS", "WAIT_RX_COMPLETE",
        "WAIT_MARKER_WORD", "CHECK_DMA_ERROR", "CHECK_MARKER", "UNPACK_RX", "ABORTED",
        "CLOSE", "REARM"
    };
    return v < MP_ARRAY_SIZE(names) ? names[v] : "UNKNOWN";
}

static const char *error_name(uint32_t v) {
    static const char *const names[] = {
        "NONE", "TIMEOUT", "MARKER_MISMATCH", "COUNT_INCONSISTENT", "DMA_READ_ERROR",
        "DMA_WRITE_ERROR", "DMA_AHB_ERROR", "CLEANUP_ERROR_CLEAR"
    };
    return v < MP_ARRAY_SIZE(names) ? names[v] : "UNKNOWN";
}

static void raise_transfer_error(void) {
    const char *stage = stage_name(engine.last_stage);
    const char *detail = error_name(engine.last_error_code);
    const mp_obj_type_t *type = &mp_type_ProtocolError;
    if (engine.last_error_code == ERR_TIMEOUT) type = &mp_type_ProtocolTimeout;
    else if (engine.last_error_code == ERR_DMA_READ || engine.last_error_code == ERR_DMA_WRITE ||
        engine.last_error_code == ERR_DMA_AHB || engine.last_error_code == ERR_CLEANUP_CLEAR) {
        type = &mp_type_DMAError;
    }
    mp_raise_msg_varg(type, MP_ERROR_TEXT("STAGE=%s DETAIL=%s"), stage, detail);
}

static mp_obj_t version(void) { return mp_obj_new_str(version_string, sizeof(version_string) - 1); }
static MP_DEFINE_CONST_FUN_OBJ_0(version_obj, version);

static mp_obj_t pack_tx_words(size_t n_args, const mp_obj_t *args) {
    (void)n_args;
    size_t request_len = get_length(args[1], MAX_REQUEST_BYTES, MP_ERROR_TEXT("request_length out of range"));
    size_t response_len = get_length(args[2], MAX_RESPONSE_BYTES, MP_ERROR_TEXT("response_length out of range"));
    size_t data_words = (request_len * 2 + 7) / 8;
    size_t total_words = TX_CONTROL_WORDS + data_words;
    mp_buffer_info_t request, tx;
    get_byte_buffer(args[0], &request, MP_BUFFER_READ);
    get_word_buffer(args[3], &tx, MP_BUFFER_WRITE);
    if (request.len < request_len) mp_raise_ValueError(MP_ERROR_TEXT("request buffer is too short"));
    if (tx.len / 4 < total_words) mp_raise_ValueError(MP_ERROR_TEXT("tx word buffer is too short"));
    mp_obj_t items[3] = { mp_obj_new_int_from_uint(total_words), mp_obj_new_int_from_uint(data_words),
        mp_obj_new_int_from_uint(request_len * 2) };
    mp_obj_t result = mp_obj_new_tuple(3, items);
    pack_no_raise(request.buf, request_len, response_len, &tx);
    return result;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(pack_tx_words_obj, 4, 4, pack_tx_words);

static mp_obj_t unpack_rx_words(size_t n_args, const mp_obj_t *args) {
    (void)n_args;
    size_t response_len = get_length(args[2], MAX_RESPONSE_BYTES, MP_ERROR_TEXT("response_length out of range"));
    size_t nibbles = response_len * 2, words = (nibbles + 7) / 8;
    mp_buffer_info_t rx, response, raw;
    get_word_buffer(args[0], &rx, MP_BUFFER_READ);
    get_byte_buffer(args[1], &response, MP_BUFFER_WRITE);
    get_byte_buffer(args[3], &raw, MP_BUFFER_WRITE);
    if (rx.len / 4 < words) mp_raise_ValueError(MP_ERROR_TEXT("rx word buffer is too short"));
    if (response.len < response_len) mp_raise_ValueError(MP_ERROR_TEXT("response buffer is too short"));
    if (raw.len < nibbles) mp_raise_ValueError(MP_ERROR_TEXT("raw nibble buffer is too short"));
    mp_obj_t result = mp_obj_new_int_from_uint(words);
    unpack_no_raise(&rx, response.buf, response_len, raw.buf);
    return result;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(unpack_rx_words_obj, 4, 4, unpack_rx_words);

static uint32_t checked_int(mp_int_t v, uint32_t lo, uint32_t hi, mp_rom_error_text_t msg) {
    if (v < (mp_int_t)lo || (mp_uint_t)v > hi) mp_raise_ValueError(msg);
    return (uint32_t)v;
}

static mp_obj_t dma_open(size_t n_args, const mp_obj_t *pos_args, mp_map_t *kw_args) {
    enum { ARG_recover, ARG_pio, ARG_sm, ARG_req_pin, ARG_req_assert, ARG_tx, ARG_first,
        ARG_progress, ARG_complete, ARG_marker, ARG_poll };
    static const mp_arg_t allowed[] = {
        { MP_QSTR_recover, MP_ARG_KW_ONLY | MP_ARG_BOOL, {.u_bool = false} },
        { MP_QSTR_pio, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 0} },
        { MP_QSTR_sm, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 0} },
        { MP_QSTR_req_pin, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 14} },
        { MP_QSTR_req_assert_timeout_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 100000} },
        { MP_QSTR_tx_timeout_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 250000} },
        { MP_QSTR_rx_first_timeout_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 250000} },
        { MP_QSTR_rx_progress_timeout_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 250000} },
        { MP_QSTR_rx_complete_timeout_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 500000} },
        { MP_QSTR_marker_timeout_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 250000} },
        { MP_QSTR_event_poll_interval_us, MP_ARG_KW_ONLY | MP_ARG_INT, {.u_int = 250} },
    };
    mp_arg_val_t a[MP_ARRAY_SIZE(allowed)];
    mp_arg_parse_all(n_args, pos_args, kw_args, MP_ARRAY_SIZE(allowed), allowed, a);
    uint32_t pio_i = checked_int(a[ARG_pio].u_int, 0, 1, MP_ERROR_TEXT("pio out of range"));
    uint32_t sm = checked_int(a[ARG_sm].u_int, 0, 3, MP_ERROR_TEXT("sm out of range"));
    uint32_t pin = checked_int(a[ARG_req_pin].u_int, 0, 29, MP_ERROR_TEXT("req_pin out of range"));
    uint32_t values[7];
    for (size_t i = 0; i < 6; ++i) values[i] = checked_int(a[ARG_req_assert + i].u_int, 1, MAX_TIMEOUT_US,
        MP_ERROR_TEXT("timeout out of range"));
    values[6] = checked_int(a[ARG_poll].u_int, 50, 10000, MP_ERROR_TEXT("event_poll_interval_us out of range"));

    if (has_record()) {
        if (!claim_shape_consistent() || !a[ARG_recover].u_bool) mp_raise_OSError(MP_EBUSY);
        engine.last_stage = STAGE_OPEN_RECOVERY;
        cleanup_owned_no_raise();
        if (engine.last_cleanup_error_code != ERR_NONE) {
            engine.last_error_code = ERR_CLEANUP_CLEAR;
            engine.state = ENGINE_ABORTED;
            raise_transfer_error();
        }
        dma_channel_unclaim((uint)engine.tx_channel);
        dma_channel_unclaim((uint)engine.rx_channel);
        clear_record();
    }
    int tx = dma_claim_unused_channel(false);
    if (tx < 0) mp_raise_OSError(MP_EBUSY);
    int rx = dma_claim_unused_channel(false);
    if (rx < 0) {
        cleanup_channel_no_raise((uint)tx);
        dma_channel_unclaim((uint)tx);
        mp_raise_OSError(MP_EBUSY);
    }
    memset(&engine, 0, sizeof(engine));
    engine.magic = ENGINE_MAGIC; engine.abi_version = ENGINE_ABI; engine.state = ENGINE_IDLE;
    engine.tx_channel = tx; engine.rx_channel = rx;
    engine.owned_mask = (1u << tx) | (1u << rx);
    engine.pio_index = pio_i; engine.sm_index = sm; engine.req_pin = pin;
    engine.req_assert_timeout_us = values[0]; engine.tx_timeout_us = values[1];
    engine.rx_first_timeout_us = values[2]; engine.rx_progress_timeout_us = values[3];
    engine.rx_complete_timeout_us = values[4]; engine.marker_timeout_us = values[5];
    engine.event_poll_interval_us = values[6]; engine.last_stage = STAGE_IDLE;
    mp_obj_t out[2] = { MP_OBJ_NEW_SMALL_INT(tx), MP_OBJ_NEW_SMALL_INT(rx) };
    return mp_obj_new_tuple(2, out);
}
static MP_DEFINE_CONST_FUN_OBJ_KW(dma_open_obj, 0, dma_open);

static void set_error(stage_t stage, dma_error_t error) {
    engine.last_stage = stage; engine.last_error_code = error;
}

static mp_obj_t transfer_dma(size_t n_args, const mp_obj_t *args) {
    (void)n_args;
    volatile mp_obj_t roots[6] = { args[0], args[2], args[4], args[5], args[6], MP_OBJ_NULL };
    if (!claim_shape_consistent() || engine.state != ENGINE_IDLE) {
        mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("DMA engine is not IDLE"));
    }
    // A valid IDLE engine accepts a new attempt here. Even a later validation
    // failure must not leave metrics from the preceding transfer visible.
    clear_metrics();
    engine.last_stage = STAGE_VALIDATE;
    size_t request_len = get_length(args[1], MAX_REQUEST_BYTES, MP_ERROR_TEXT("request_length out of range"));
    size_t response_len = get_length(args[3], MAX_RESPONSE_BYTES, MP_ERROR_TEXT("response_length out of range"));
    size_t tx_words_n = TX_CONTROL_WORDS + (request_len * 2 + 7) / 8;
    size_t rx_data_n = (response_len * 2 + 7) / 8;
    size_t rx_words_n = rx_data_n + 1;
    mp_buffer_info_t request, response, tx, rx, raw;
    get_byte_buffer(roots[0], &request, MP_BUFFER_READ);
    get_byte_buffer(roots[1], &response, MP_BUFFER_WRITE);
    get_word_buffer(roots[2], &tx, MP_BUFFER_WRITE);
    get_word_buffer(roots[3], &rx, MP_BUFFER_WRITE);
    get_byte_buffer(roots[4], &raw, MP_BUFFER_WRITE);
    if (request.len < request_len || response.len < response_len || raw.len < response_len * 2 ||
        tx.len / 4 < TX_WORD_BUFFER_WORDS || rx.len / 4 < RX_WORD_BUFFER_WORDS) {
        mp_raise_ValueError(MP_ERROR_TEXT("buffer is too short"));
    }
    if (((uintptr_t)tx.buf & 3) || ((uintptr_t)rx.buf & 3)) mp_raise_ValueError(MP_ERROR_TEXT("word buffer is unaligned"));
    const void *ptrs[5] = { request.buf, response.buf, raw.buf, tx.buf, rx.buf };
    size_t lens[5] = { request_len, response_len, response_len * 2, tx_words_n * 4, rx_words_n * 4 };
    for (size_t i = 0; i < 5; ++i) {
        if (!range_ok(ptrs[i], lens[i])) mp_raise_ValueError(MP_ERROR_TEXT("DMA address out of range"));
        for (size_t j = 0; j < i; ++j) if (ranges_overlap(ptrs[i], lens[i], ptrs[j], lens[j]))
            mp_raise_ValueError(MP_ERROR_TEXT("buffer ranges overlap"));
    }
    mp_obj_t initial[4] = { MP_OBJ_NEW_SMALL_INT(0), MP_OBJ_NEW_SMALL_INT(0),
        MP_OBJ_NEW_SMALL_INT(0), MP_OBJ_NEW_SMALL_INT(0) };
    engine.last_stage = STAGE_ALLOCATE_RESULT;
    mp_obj_t result = mp_obj_new_tuple(4, initial);
    roots[5] = result;

    uint64_t transfer_start = time_us_64();
    uint64_t t = transfer_start;
    engine.last_stage = STAGE_PACK_TX;
    pack_no_raise(request.buf, request_len, response_len, &tx);
    uint64_t now = time_us_64(); engine.pack_us = (uint32_t)(now - t); t = now;
    engine.last_stage = STAGE_CLEAR_RX;
    memset(rx.buf, 0, rx_words_n * 4);
    now = time_us_64(); engine.rx_clear_us = (uint32_t)(now - t); t = now;

    PIO pio = engine.pio_index == 0 ? pio0 : pio1;
    dma_channel_config rc = dma_channel_get_default_config((uint)engine.rx_channel);
    channel_config_set_transfer_data_size(&rc, DMA_SIZE_32);
    channel_config_set_read_increment(&rc, false); channel_config_set_write_increment(&rc, true);
    channel_config_set_dreq(&rc, pio_get_dreq(pio, engine.sm_index, false));
    channel_config_set_chain_to(&rc, (uint)engine.rx_channel);
    dma_channel_config tc = dma_channel_get_default_config((uint)engine.tx_channel);
    channel_config_set_transfer_data_size(&tc, DMA_SIZE_32);
    channel_config_set_read_increment(&tc, true); channel_config_set_write_increment(&tc, false);
    channel_config_set_dreq(&tc, pio_get_dreq(pio, engine.sm_index, true));
    channel_config_set_chain_to(&tc, (uint)engine.tx_channel);

    engine.state = ENGINE_RUNNING; engine.last_error_code = ERR_NONE;
    engine.last_cleanup_error_code = ERR_NONE; engine.last_tx_words = tx_words_n;
    engine.last_rx_words = rx_words_n; engine.event_poll_count = 0;
    nlr_buf_t nlr;
    if (nlr_push(&nlr) == 0) {
        engine.last_stage = STAGE_CONFIG_RX_DMA;
        dma_channel_configure((uint)engine.rx_channel, &rc, rx.buf, &pio->rxf[engine.sm_index], rx_words_n, false);
        engine.last_stage = STAGE_CONFIG_TX_DMA;
        dma_channel_configure((uint)engine.tx_channel, &tc, &pio->txf[engine.sm_index], tx.buf, tx_words_n, false);
        now = time_us_64(); engine.dma_config_us = (uint32_t)(now - t);
        engine.last_stage = STAGE_START_RX_DMA; dma_start_channel_mask(1u << engine.rx_channel);
        engine.last_stage = STAGE_START_TX_DMA; dma_start_channel_mask(1u << engine.tx_channel);
        uint64_t dma_start = time_us_64(), next_poll = dma_start + engine.event_poll_interval_us;
        uint64_t req_start = 0, last_progress = dma_start, marker_start = 0;
        uint32_t last_remaining = rx_words_n;
        bool req_seen = false, rx_seen = false, marker_wait = false;
        engine.last_stage = STAGE_POLL_DMA;
        while (engine.last_error_code == ERR_NONE) {
            now = time_us_64();
#if SHRIKE_PARALLEL_C_TEST_HOOKS
            if (test_hook == HOOK_SCHEDULER_EXCEPTION) mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("A4 test scheduler exception"));
            if (test_hook >= HOOK_WAIT_TX_DMA && test_hook <= HOOK_WAIT_MARKER_WORD) {
                static const stage_t injected[] = { STAGE_WAIT_TX_DMA, STAGE_WAIT_REQ_HIGH,
                    STAGE_WAIT_RX_FIRST_WORD, STAGE_WAIT_RX_PROGRESS, STAGE_WAIT_RX_COMPLETE,
                    STAGE_WAIT_MARKER_WORD };
                set_error(injected[test_hook - HOOK_WAIT_TX_DMA], ERR_TIMEOUT); break;
            }
#endif
            uint32_t remaining = dma_hw->ch[engine.rx_channel].transfer_count;
            bool tx_busy = dma_channel_is_busy((uint)engine.tx_channel);
            bool rx_busy = dma_channel_is_busy((uint)engine.rx_channel);
            if (remaining < last_remaining) {
                if (!req_seen) { req_seen = true; req_start = now; }
                rx_seen = true; last_progress = now; last_remaining = remaining;
                if (remaining == 1) { marker_wait = true; marker_start = now; }
            }
            if (!req_seen && gpio_get(engine.req_pin)) { req_seen = true; req_start = now; }
            uint32_t ctrl = dma_hw->ch[engine.tx_channel].ctrl_trig | dma_hw->ch[engine.rx_channel].ctrl_trig;
            if (ctrl & DMA_CH0_CTRL_TRIG_READ_ERROR_BITS) { set_error(STAGE_CHECK_DMA_ERROR, ERR_DMA_READ); break; }
            if (ctrl & DMA_CH0_CTRL_TRIG_WRITE_ERROR_BITS) { set_error(STAGE_CHECK_DMA_ERROR, ERR_DMA_WRITE); break; }
            if (ctrl & DMA_CH0_CTRL_TRIG_AHB_ERROR_BITS) { set_error(STAGE_CHECK_DMA_ERROR, ERR_DMA_AHB); break; }
            // BUSY goes low when the last transfer completes. Once both channels
            // are no longer busy, reread both volatile counters: the earlier RX
            // progress sample may predate completion of the final transfer.
            if (!tx_busy && !rx_busy) {
                uint32_t final_tx_remaining = dma_hw->ch[engine.tx_channel].transfer_count;
                uint32_t final_rx_remaining = dma_hw->ch[engine.rx_channel].transfer_count;
                if (final_tx_remaining != 0 || final_rx_remaining != 0) {
                    set_error(STAGE_WAIT_RX_COMPLETE, ERR_COUNT);
                }
                break;
            }
            if (tx_busy && now - dma_start > engine.tx_timeout_us &&
                dma_channel_is_busy((uint)engine.tx_channel)) {
                set_error(STAGE_WAIT_TX_DMA, ERR_TIMEOUT); break;
            }
            if (!req_seen && now - dma_start > engine.req_assert_timeout_us &&
                !gpio_get(engine.req_pin)) {
                set_error(STAGE_WAIT_REQ_HIGH, ERR_TIMEOUT); break;
            }
            if (req_seen && !rx_seen && now - req_start > engine.rx_first_timeout_us &&
                dma_hw->ch[engine.rx_channel].transfer_count == rx_words_n) {
                set_error(STAGE_WAIT_RX_FIRST_WORD, ERR_TIMEOUT); break;
            }
            if (rx_seen && remaining > 1 && now - last_progress > engine.rx_progress_timeout_us &&
                dma_hw->ch[engine.rx_channel].transfer_count >= remaining) {
                set_error(STAGE_WAIT_RX_PROGRESS, ERR_TIMEOUT); break;
            }
            if (rx_busy && now - dma_start > engine.rx_complete_timeout_us &&
                dma_channel_is_busy((uint)engine.rx_channel)) {
                set_error(STAGE_WAIT_RX_COMPLETE, ERR_TIMEOUT); break;
            }
            if (marker_wait && remaining > 0 && now - marker_start > engine.marker_timeout_us &&
                dma_hw->ch[engine.rx_channel].transfer_count > 0) {
                set_error(STAGE_WAIT_MARKER_WORD, ERR_TIMEOUT); break;
            }
            if (now >= next_poll) { mp_event_handle_nowait(); engine.event_poll_count++; next_poll = time_us_64() + engine.event_poll_interval_us; }
        }
        engine.dma_time_us = (uint32_t)(time_us_64() - dma_start);
        nlr_pop();
    } else {
        mp_obj_t original_exc = MP_OBJ_FROM_PTR(nlr.ret_val);
        cleanup_owned_no_raise(); engine.state = ENGINE_ABORTED; engine.last_stage = STAGE_ABORTED;
        (void)roots; nlr_raise(original_exc);
    }
    now = time_us_64(); engine.poll_us = (uint32_t)(now - t - engine.dma_config_us); t = now;
    if (engine.last_error_code != ERR_NONE) {
        cleanup_owned_no_raise(); engine.state = ENGINE_ABORTED; raise_transfer_error();
    }
    engine.last_stage = STAGE_CHECK_MARKER;
#if SHRIKE_PARALLEL_C_TEST_HOOKS
    if (test_hook == HOOK_MARKER_MISMATCH) store_word(&rx, rx_data_n, 0);
#endif
    if (load_word(&rx, rx_data_n) != COMPLETION_MARKER) {
        set_error(STAGE_CHECK_MARKER, ERR_MARKER); cleanup_owned_no_raise();
        engine.state = ENGINE_ABORTED; raise_transfer_error();
    }
    now = time_us_64(); engine.marker_us = (uint32_t)(now - t); t = now;
    engine.last_stage = STAGE_UNPACK_RX;
    unpack_no_raise(&rx, response.buf, response_len, raw.buf);
    now = time_us_64(); engine.unpack_us = (uint32_t)(now - t);
    engine.transfer_us = (uint32_t)(now - transfer_start);
    mp_obj_tuple_t *tuple = MP_OBJ_TO_PTR(result);
    tuple->items[0] = MP_OBJ_NEW_SMALL_INT(tx_words_n);
    tuple->items[1] = MP_OBJ_NEW_SMALL_INT(rx_data_n);
    tuple->items[2] = MP_OBJ_NEW_SMALL_INT(engine.dma_time_us);
    tuple->items[3] = MP_OBJ_NEW_SMALL_INT(engine.event_poll_count);
    engine.state = ENGINE_IDLE; engine.last_stage = STAGE_IDLE;
    (void)roots;
    return result;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(transfer_dma_obj, 7, 7, transfer_dma);

static mp_obj_t dma_rearm(void) {
    if (!claim_shape_consistent() || engine.state != ENGINE_ABORTED) mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("DMA engine is not ABORTED"));
    engine.last_stage = STAGE_REARM; cleanup_owned_no_raise();
    if (engine.last_cleanup_error_code != ERR_NONE) { engine.last_error_code = ERR_CLEANUP_CLEAR; raise_transfer_error(); }
    engine.state = ENGINE_IDLE; engine.last_stage = STAGE_IDLE; engine.last_error_code = ERR_NONE;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(dma_rearm_obj, dma_rearm);

static mp_obj_t dma_close(void) {
    if (!has_record()) { clear_record(); return mp_const_none; }
    if (!claim_shape_consistent()) mp_raise_OSError(MP_EBUSY);
    if (engine.state == ENGINE_RUNNING) mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("DMA engine is RUNNING"));
    engine.last_stage = STAGE_CLOSE; cleanup_owned_no_raise();
    if (engine.last_cleanup_error_code != ERR_NONE) { engine.last_error_code = ERR_CLEANUP_CLEAR; engine.state = ENGINE_ABORTED; raise_transfer_error(); }
    dma_channel_unclaim((uint)engine.tx_channel); dma_channel_unclaim((uint)engine.rx_channel);
    clear_record(); return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(dma_close_obj, dma_close);

static void dict_set(mp_obj_t d, qstr key, mp_obj_t value) { mp_obj_dict_store(d, MP_OBJ_NEW_QSTR(key), value); }
static void dict_int(mp_obj_t d, qstr key, mp_int_t v) { dict_set(d, key, mp_obj_new_int(v)); }
static void dict_str(mp_obj_t d, qstr key, const char *v) { dict_set(d, key, mp_obj_new_str(v, strlen(v))); }

static mp_obj_t dma_status(void) {
    bool record = has_record();
    bool shape = claim_shape_consistent();
    bool tx_claimed = record && shape && valid_channel(engine.tx_channel)
        && dma_channel_is_claimed((uint)engine.tx_channel);
    bool rx_claimed = record && shape && valid_channel(engine.rx_channel)
        && dma_channel_is_claimed((uint)engine.rx_channel);
    mp_obj_t d = mp_obj_new_dict(20);
    dict_str(d, MP_QSTR_state, state_name(engine.state));
    dict_int(d, MP_QSTR_tx_channel, record ? engine.tx_channel : -1);
    dict_int(d, MP_QSTR_rx_channel, record ? engine.rx_channel : -1);
    dict_set(d, MP_QSTR_tx_claimed, mp_obj_new_bool(tx_claimed));
    dict_set(d, MP_QSTR_rx_claimed, mp_obj_new_bool(rx_claimed));
    dict_set(d, MP_QSTR_claim_shape_consistent, mp_obj_new_bool(shape));
    dict_int(d, MP_QSTR_pio, engine.pio_index); dict_int(d, MP_QSTR_sm, engine.sm_index);
    dict_int(d, MP_QSTR_req_pin, engine.req_pin); dict_str(d, MP_QSTR_last_stage, stage_name(engine.last_stage));
    dict_int(d, MP_QSTR_last_error_code, engine.last_error_code); dict_str(d, MP_QSTR_last_error, error_name(engine.last_error_code));
    dict_int(d, MP_QSTR_last_cleanup_error_code, engine.last_cleanup_error_code);
    dict_str(d, MP_QSTR_last_cleanup_error, error_name(engine.last_cleanup_error_code));
    dict_int(d, MP_QSTR_last_tx_words, engine.last_tx_words); dict_int(d, MP_QSTR_last_rx_words, engine.last_rx_words);
    dict_int(d, MP_QSTR_last_dma_time_us, engine.dma_time_us); dict_int(d, MP_QSTR_last_event_poll_count, engine.event_poll_count);
    return d;
}
static MP_DEFINE_CONST_FUN_OBJ_0(dma_status_obj, dma_status);

static mp_obj_t dma_last_metrics(void) {
    mp_obj_t d = mp_obj_new_dict(9);
    dict_int(d, MP_QSTR_pack_us, engine.pack_us); dict_int(d, MP_QSTR_rx_clear_us, engine.rx_clear_us);
    dict_int(d, MP_QSTR_dma_config_us, engine.dma_config_us); dict_int(d, MP_QSTR_poll_us, engine.poll_us);
    dict_int(d, MP_QSTR_marker_us, engine.marker_us); dict_int(d, MP_QSTR_unpack_us, engine.unpack_us);
    dict_int(d, MP_QSTR_transfer_us, engine.transfer_us); dict_int(d, MP_QSTR_dma_time_us, engine.dma_time_us);
    dict_int(d, MP_QSTR_event_poll_count, engine.event_poll_count); return d;
}
static MP_DEFINE_CONST_FUN_OBJ_0(dma_last_metrics_obj, dma_last_metrics);

#if SHRIKE_PARALLEL_C_TEST_HOOKS
// The test-only API name is intentionally visible to qstr generation only in this build.
static mp_obj_t dma_test_set_fault(mp_obj_t value) {
    mp_int_t v = mp_obj_get_int(value);
    if (v < HOOK_NONE || v > HOOK_CLEANUP_ERROR_CLEAR) mp_raise_ValueError(MP_ERROR_TEXT("test fault out of range"));
    test_hook = v; return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(dma_test_set_fault_obj, dma_test_set_fault);
#endif

static const mp_rom_map_elem_t globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__), MP_ROM_QSTR(MP_QSTR_shrike_parallel_c) },
    { MP_ROM_QSTR(MP_QSTR_version), MP_ROM_PTR(&version_obj) },
    { MP_ROM_QSTR(MP_QSTR_pack_tx_words), MP_ROM_PTR(&pack_tx_words_obj) },
    { MP_ROM_QSTR(MP_QSTR_unpack_rx_words), MP_ROM_PTR(&unpack_rx_words_obj) },
    { MP_ROM_QSTR(MP_QSTR_dma_open), MP_ROM_PTR(&dma_open_obj) },
    { MP_ROM_QSTR(MP_QSTR_transfer_dma), MP_ROM_PTR(&transfer_dma_obj) },
    { MP_ROM_QSTR(MP_QSTR_dma_rearm), MP_ROM_PTR(&dma_rearm_obj) },
    { MP_ROM_QSTR(MP_QSTR_dma_close), MP_ROM_PTR(&dma_close_obj) },
    { MP_ROM_QSTR(MP_QSTR_dma_status), MP_ROM_PTR(&dma_status_obj) },
    { MP_ROM_QSTR(MP_QSTR_dma_last_metrics), MP_ROM_PTR(&dma_last_metrics_obj) },
    { MP_ROM_QSTR(MP_QSTR_ProtocolError), MP_ROM_PTR(&mp_type_ProtocolError) },
    { MP_ROM_QSTR(MP_QSTR_ProtocolTimeout), MP_ROM_PTR(&mp_type_ProtocolTimeout) },
    { MP_ROM_QSTR(MP_QSTR_DMAError), MP_ROM_PTR(&mp_type_DMAError) },
#if SHRIKE_PARALLEL_C_TEST_HOOKS
    { MP_ROM_QSTR(MP_QSTR_config), MP_ROM_PTR(&dma_test_set_fault_obj) },
#endif
};
static MP_DEFINE_CONST_DICT(globals, globals_table);
const mp_obj_module_t shrike_parallel_c_user_cmodule = { .base = { &mp_type_module }, .globals = (mp_obj_dict_t *)&globals };
MP_REGISTER_MODULE(MP_QSTR_shrike_parallel_c, shrike_parallel_c_user_cmodule);
