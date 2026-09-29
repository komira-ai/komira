if(ARCH STREQUAL "x86_64")
  set(BCM_ASM_SOURCES aesni-x86_64.${ASM_EXT})
endif()
if(ARCH STREQUAL "aarch64")
  set(
    BCM_ASM_SOURCES
    aesv8-gcm-armv8.${ASM_EXT}
  )
endif()

set(S2N_BIGNUM_ASM_SOURCES generic/bignum_mul.S)
if(ARCH STREQUAL "x86_64")
  # Only x86_64 has these.
  list(APPEND S2N_BIGNUM_ASM_SOURCES
    curve25519/curve25519_x25519.S
  )
endif()

if(FIPS_DELOCATE)
  add_library(bcm_c_generated_asm STATIC bcm.c)
else()
  set(BCM_ASM_OBJECTS "")
  add_library(
    fipsmodule
    OBJECT

    bcm.c
    ${BCM_ASM_SOURCES}
  )
endif()
