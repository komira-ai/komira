if(ARCH STREQUAL "x86_64")
  if(MY_ASSEMBLER_IS_TOO_OLD_FOR_AVX)
    set(CRYPTO_ARCH_SOURCES too_old.${ASM_EXT})
  else()
    set(
      CRYPTO_ARCH_SOURCES

      chacha/chacha-x86_64.${ASM_EXT}  # shipped under generated-src
      aes/aes-x86_64.${ASM_EXT}
    )
  endif()
endif()

if(ARCH STREQUAL "aarch64")
  set(CRYPTO_ARCH_SOURCES chacha/chacha-armv8.${ASM_EXT} aes/aesv8-armx.${ASM_EXT})
endif()

add_library(
  crypto_objects
  OBJECT

  err_data.c
  mem.c # the allocator
  ${DILITHIUM_SOURCES}
  ${CRYPTO_ARCH_SOURCES}
)
