# The s2n-tls feature probes (tests/features/<name>.c) that pass on macOS
# arm64, kept apart from features.bzl (linux x86_64), whose names
# tools/build/tests/c_libs_tests.sh reads as the Linux list. The zig C
# toolchain with its macOS libc headers, and aws-lc 1.39 as //src/awslc
# builds it (what //third_party/aws-lc:crypto is on macOS). Each name becomes
# -D<name> on every s2n-tls compile for macOS. Linux's list without the five
# that need Linux or x86 (clone, kTLS, Linux sendfile, glibc's features.h,
# cpuid.h), and with minherit, which macOS has and Linux does not.
# tests//functional/s2n_probes compiles the probe of each name here for
# macOS (a darwin-arm64 build of that package), and third_party/s2n-tls/BUCK
# refuses a name with no probe at load.
S2N_FEATURES_MACOS = [
    "S2N_ATOMIC_SUPPORTED",
    "S2N_CLOEXEC_SUPPORTED",
    "S2N_CLOEXEC_XOPEN_SUPPORTED",
    "S2N_DIAGNOSTICS_POP_SUPPORTED",
    "S2N_DIAGNOSTICS_PUSH_SUPPORTED",
    "S2N_EXECINFO_AVAILABLE",
    "S2N_FALL_THROUGH_SUPPORTED",
    "S2N_LIBCRYPTO_SUPPORTS_EC_KEY_CHECK_FIPS",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_AEAD_TLS",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_KEM",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_MD5_SHA1_HASH",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_MD_CTX_SET_PKEY_CTX",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_RC4",
    "S2N_LIBCRYPTO_SUPPORTS_FLAG_NO_CHECK_TIME",
    "S2N_LIBCRYPTO_SUPPORTS_HKDF",
    "S2N_LIBCRYPTO_SUPPORTS_MLKEM",
    "S2N_LIBCRYPTO_SUPPORTS_RSA_PSS_SIGNING",
    "S2N_LIBCRYPTO_SUPPORTS_X509_STORE_LIST",
    "S2N_MADVISE_SUPPORTED",
    "S2N_MINHERIT_SUPPORTED",
]
