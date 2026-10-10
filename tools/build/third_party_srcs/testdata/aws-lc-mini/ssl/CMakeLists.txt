add_library(
  ssl

  s3_lib.cc
  ssl_decrepit.c # the one C source
)
target_compile_definitions(ssl PRIVATE BORINGSSL_IMPLEMENTATION)

if(BUILD_TESTING)
  add_executable(
    ssl_test

    ssl_test.cc
  )
endif()
