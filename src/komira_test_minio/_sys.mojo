# =============================================================================
# komira_test_minio/_sys.mojo -- chmod(2). Package-private: imported only by
# `_private_files`.
# =============================================================================
#
# The libc declaration lives here, not in komira_libc, so that this
# library touches only its own package. The wrapper returns a plain value;
# the `external_call` and its pointer stay inside this file, so no
# `UnsafePointer` crosses a module boundary.
#
# `chmod` is declared nowhere else in the tree; if a second site ever needs
# it, move the declaration to komira_libc in one change instead. (The
# wall clock this file used to declare is komira_clock's, through
# komira_test_run_id's `SystemClock`.)
# =============================================================================

from std.ffi import external_call


def _chmod(path: String, mode: Int) -> Bool:
    """Set the permission bits of `path` to `mode` (for example `0o600`).

    Returns True on success. `mode` is passed as a 32-bit value: `mode_t` is
    32 bits on Linux and 16 on Darwin, where the callee reads the low 16 bits
    of the register, so one declaration serves both.

    `as_c_string_slice()` is a mutating method (appends a NUL), so it runs on
    an owned local that outlives the call.
    """
    var p = path
    # `chmod` reads the path during the call and keeps no pointer to it.
    # SAFETY: `p` owns the NUL-terminated buffer and lives to the end of this
    # function, past the synchronous call; the pointer does not escape.
    var rc = external_call["chmod", Int32](
        p.as_c_string_slice().unsafe_ptr(), UInt32(mode)
    )
    return rc == 0
