# The s2n-tls feature probes (tests/features/<name>.c) that pass for this
# build: linux x86_64, glibc 2.34, the zig C toolchain and aws-lc 1.39
# (//third_party/aws-lc:crypto). Each name becomes -D<name> on every s2n-tls
# compile, as CMake's feature_probe does.
#
# Not a guess: tools/build/checks/c_libs_checks.sh compiles every probe
# (checks//s2n_probes) and fails unless exactly the probes named here pass.
S2N_FEATURES = [
    "S2N_ATOMIC_SUPPORTED",
    "S2N_CLOEXEC_SUPPORTED",
    "S2N_CLOEXEC_XOPEN_SUPPORTED",
    "S2N_CLONE_SUPPORTED",
    "S2N_CPUID_AVAILABLE",
    "S2N_DIAGNOSTICS_POP_SUPPORTED",
    "S2N_DIAGNOSTICS_PUSH_SUPPORTED",
    "S2N_EXECINFO_AVAILABLE",
    "S2N_FALL_THROUGH_SUPPORTED",
    "S2N_FEATURES_AVAILABLE",
    "S2N_KTLS_SUPPORTED",
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
    "S2N_LINUX_SENDFILE",
    "S2N_MADVISE_SUPPORTED",
]
