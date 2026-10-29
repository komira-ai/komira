/* snappy configuration for the arm64 platforms (BUCK selects it by cpu): what
 * CMake writes for aarch64 with clang on Linux or macOS. NEON is baseline on
 * aarch64. The compile targets zig's generic arm64 CPU, which has no CRC32
 * extension, so <arm_acle.h> offers no __crc32cw and SNAPPY_HAVE_NEON_CRC32
 * is 0. The linux-arm64 row of the platform table names target_cpu generic; the
 * darwin-arm64 row names apple-m1, and the claim holds there only because
 * tools/build/mojo/cxx.bzl passes -mcpu=generic for macOS whatever the row says.
 * No x86 intrinsic header is available here.
 * Compressed bytes differ between x86_64 (CRC32C hash) and arm64 (multiplicative
 * hash): both are valid snappy streams that decode identically, so no golden of
 * compressed bytes may be shared across cpus. */
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
