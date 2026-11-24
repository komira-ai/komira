# =============================================================================
# FFI-BOUNDARY: the three readers of native/komira_test_rss.c. Each takes no
# argument and returns a C `long long`; no pointer crosses, so nothing is
# owned or freed on either side.
# =============================================================================
# The process's resident and virtual sizes in KiB, for a welded test that
# bounds how much memory a loop may grow. Linux reads /proc/self/status
# (VmRSS, VmHWM, VmPeak); macOS reads task_info (resident_size and
# resident_size_max), and keeps no peak virtual size, so
# `peak_virtual_kib` returns None there and a test checks that ceiling on
# Linux only.
#
# A value that cannot be read raises `RssUnreadable: <what>`, so a test never
# compares a sentinel as a size.
# =============================================================================

from std.ffi import external_call

comptime _NOT_KEPT: Int64 = -2


def _checked(v: Int64, what: StaticString) raises -> Int:
    """`v` as an Int; raises `RssUnreadable: <what>` for the C's -1, and for
    any other negative value, which no reader returns as a size."""
    if v < 0:
        raise Error("RssUnreadable: " + String(what))
    return Int(v)


def _kept(v: Int64, what: StaticString) raises -> Optional[Int]:
    """None for the C's `not kept` (-2); otherwise as `_checked`."""
    if v == _NOT_KEPT:
        return None
    return _checked(v, what)


def resident_kib() raises -> Int:
    """The resident set now, in KiB (Linux VmRSS; macOS resident_size)."""
    return _checked(
        external_call["komira_test_rss_resident_kib", Int64](), "resident set"
    )


def peak_resident_kib() raises -> Int:
    """The largest resident set so far, in KiB (Linux VmHWM; macOS
    resident_size_max)."""
    return _checked(
        external_call["komira_test_rss_peak_resident_kib", Int64](),
        "peak resident set",
    )


def peak_virtual_kib() raises -> Optional[Int]:
    """The largest virtual size so far, in KiB (Linux VmPeak); None on macOS,
    which keeps no such peak."""
    return _kept(
        external_call["komira_test_rss_peak_virtual_kib", Int64](),
        "peak virtual size",
    )
