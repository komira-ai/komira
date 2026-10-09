# komira_libc — canonical libc / POSIX FFI helpers.
#
# Houses one source-of-truth declaration for each libc/POSIX
# `external_call` symbol the libraries share. Mojo's MLIR FFI legalization
# aborts with `existing function with conflicting signature` when more
# than one package in a single link unit declares the same C symbol
# independently. By concentrating every `external_call["getenv", ...]`
# call in one source file (this package), every downstream consumer pulls
# the symbol declaration through an import, so MLIR sees ONE getenv
# declaration per binary regardless of how many packages call it.
#
# Currently houses:
#   * posix.mojo — the one `getenv(3)` declaration and its two readers:
#     `_read_env` (platform handshake values and test-runner variables only;
#     configuration is never read from the environment) and `_read_env_into`
#     (secret material only, copied into a caller's byte buffer so it can be
#     wiped); the one `unsetenv(3)` declaration, `_unset_env` (removes a
#     secret's variable once it is read); the `access(2)` path probes; and
#     `_thread_self`.
#
# DO NOT add inline `external_call["getenv", ...]` calls anywhere
# else, and do not add configuration readers here: configuration is a
# parameter or a command-line flag.
