# Shrike-Lite parallel User C Module

add_library(usermod_shrike_parallel_c INTERFACE)

target_sources(usermod_shrike_parallel_c INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}/mod_shrike_parallel_c.c
)

target_include_directories(usermod_shrike_parallel_c INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}
)

target_link_libraries(usermod INTERFACE
    usermod_shrike_parallel_c
    hardware_dma
    hardware_gpio
    hardware_pio
    pico_time
)

if(SHRIKE_PARALLEL_C_TEST_HOOKS OR
   "$ENV{SHRIKE_PARALLEL_C_TEST_HOOKS}" STREQUAL "1")
    target_compile_definitions(usermod_shrike_parallel_c INTERFACE
        SHRIKE_PARALLEL_C_TEST_HOOKS=1
    )
    target_compile_definitions(usermod INTERFACE
        SHRIKE_PARALLEL_C_TEST_HOOKS=1
    )
endif()
