/* snappy configuration for the arm64 platforms (BUCK selects it by cpu): what
 * CMake writes for aarch64 with clang on Linux or macOS. NEON is baseline on
 * aarch64. The compile targets zig's generic arm64 CPU (the target_cpu of the
 * linux-arm64 row and the macOS arm64 compile of tools/build/mojo/cxx.bzl), which
 * has no CRC32 extension, so <arm_acle.h> offers no __crc32cw and
 * SNAPPY_HAVE_NEON_CRC32 is 0. No x86 intrinsic header is available here. */
#ifndef THIRD_PARTY_SNAPPY_CONFIG_H_
#define THIRD_PARTY_SNAPPY_CONFIG_H_

#define HAVE_ATTRIBUTE_ALWAYS_INLINE 1
#define HAVE_BUILTIN_CTZ 1
#define HAVE_BUILTIN_EXPECT 1
#define HAVE_BUILTIN_PREFETCH 1
#define HAVE_FUNC_MMAP 1
#define HAVE_FUNC_SYSCONF 1
#define HAVE_LIBLZO2 0
#define HAVE_LIBZ 0
#define HAVE_LIBLZ4 0
#define HAVE_SYS_MMAN_H 1
#define HAVE_SYS_RESOURCE_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_UNISTD_H 1
#define HAVE_WINDOWS_H 0
#define SNAPPY_HAVE_SSSE3 0
#define SNAPPY_HAVE_X86_CRC32 0
#define SNAPPY_HAVE_BMI2 0
#define SNAPPY_HAVE_NEON 1
#define SNAPPY_HAVE_NEON_CRC32 0
#define SNAPPY_IS_BIG_ENDIAN 0

#endif  /* THIRD_PARTY_SNAPPY_CONFIG_H_ */
