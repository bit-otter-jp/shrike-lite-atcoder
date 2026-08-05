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
)
