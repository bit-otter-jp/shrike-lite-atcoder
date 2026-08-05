// MicroPython API
#include "py/runtime.h"

// Phase 5-A2 最小User C Module。
// この段階ではPIO、DMA、GPIOには触れない。

static const char shrike_parallel_c_version_string[] = "0.1.0-a2";

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
