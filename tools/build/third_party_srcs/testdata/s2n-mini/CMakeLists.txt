cmake_minimum_required(VERSION 3.9)
project(s2n-mini C)

file(GLOB CRYPTO_SRC "crypto/*.c")
file(GLOB ERROR_SRC "error/*.c")
file(GLOB STUFFER_SRC "stuffer/*.c")
file(GLOB_RECURSE TLS_SRC "tls/*.c")
file(GLOB UTILS_SRC "utils/*.c")

file(GLOB FEATURE_SRCS "${CMAKE_CURRENT_LIST_DIR}/tests/features/*.c")
