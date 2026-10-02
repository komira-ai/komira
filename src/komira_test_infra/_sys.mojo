# =============================================================================
# komira_test_infra/_sys.mojo -- the wall clock in whole seconds and chmod(2).
# Package-private: imported only by modules of komira_test_infra.
# =============================================================================
#
# These two libc declarations live here, not in komira_core_ffi, so that this
# library touches only its own package. Each wrapper returns a plain value;
# the `external_call` and its stack-local pointer stay inside this file, so no
# `UnsafePointer` crosses a module boundary.
#
# ONE DECLARATION PER SYMBOL PER LINK UNIT. komira_uuid/clock.mojo also
# declares `clock_gettime`. If a binary or test ever links both packages, the
# two declarations must stay IDENTICAL -- `external_call["clock_gettime",
# Int32](Int32, UnsafePointer[Int64, <origin>])` -- or the link sees two
# conflicting signatures for one symbol. Change neither without the other.
# `chmod` is declared nowhere else in the tree; if a second site ever needs
# it, move both declarations to komira_core_ffi in one change instead.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# CLOCK_REALTIME is 0 on Linux and on Darwin.
comptime _CLOCK_REALTIME: Int32 = 0


def _clock_realtime_unix_seconds() -> Int:
    """Whole seconds since the Unix epoch, read from `CLOCK_REALTIME`.

    The WALL clock, not a monotonic one: callers stamp it on things other
    processes and other machines read (a creation time, a deadline). Only
    differences between two readings on one machine are free of clock skew.

    Returns 0 when `clock_gettime` fails, which it does not for
    `CLOCK_REALTIME` on Linux or Darwin; a caller that cannot accept 0 checks
    for it.
    """
    # struct timespec { time_t tv_sec; long tv_nsec; } is two 8-byte fields
    # on x86_64, aarch64 and Darwin, so a stack-local Array[Int64, 2] is
    # layout-compatible.
    var ts = Array[Int64, 2](fill=Int64(0))
    # SAFETY: the pointer carries `ts`'s own origin. `ts` is stack-local and
    # outlives the synchronous call; the kernel keeps no address.
    var ts_ptr = UnsafePointer(to=ts).bitcast[Int64]()
    var rc = external_call["clock_gettime", Int32](_CLOCK_REALTIME, ts_ptr)
    if rc != 0:
        return 0
    return Int(ts[0])


def _chmod(path: String, mode: Int) -> Bool:
    """Set the permission bits of `path` to `mode` (for example `0o600`).

    Returns True on success. `mode` is passed as a 32-bit value: `mode_t` is
    32 bits on Linux and 16 on Darwin, where the callee reads the low 16 bits
    of the register, so one declaration serves both.

    `as_c_string_slice()` is a mutating method (appends a NUL), so it runs on
    an owned local that outlives the call.
    """
    var p = path
    var rc = external_call["chmod", Int32](
        p.as_c_string_slice().unsafe_ptr(), UInt32(mode)
    )
    return rc == 0
