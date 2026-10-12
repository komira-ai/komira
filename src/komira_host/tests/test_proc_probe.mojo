# =============================================================================
# test_proc_probe.mojo — the memory-basis probe and its text primitives.
# =============================================================================
#
# The primitives (`_parse_decimal_int`, `_find_substring_bytes`,
# `_parent_cgroup_path`) are pure and are asserted from literals. The reader is
# asserted against files written under `TEST_TMPDIR`: missing, empty, a lone
# newline, the trailing-newline strip, and both sides of the 4 KiB cap. The
# basis rule (`_min_of_readable`) is pure and asserted from literals. The probe
# itself reads this host's `/proc/meminfo` and cgroup files, whose
# MemAvailable moves between reads, so it is asserted only by bounds that hold
# on every read: never above the cgroup cap, positive on Linux.
# =============================================================================

from std.os import getenv
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_host.proc_probe import (
    _cgroup_v2_self_rel_path,
    _find_substring_bytes,
    _linux_read_cgroup_v2_mem_max_bytes,
    _linux_read_meminfo_available_bytes,
    _min_of_readable,
    _parent_cgroup_path,
    _parse_decimal_int,
    _read_small_file_to_string,
    detect_scan_cache_ram_basis_bytes,
)


def _scratch(name: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set")
    return base + String("/") + name


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write_bytes(text.as_bytes())


def _repeat(c: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += c
    return out^


# -----------------------------------------------------------------------------
# Pure primitives
# -----------------------------------------------------------------------------


def test_parse_decimal_int_reads_the_leading_digits() raises:
    assert_equal(_parse_decimal_int(""), 0)
    assert_equal(_parse_decimal_int("max"), 0)
    assert_equal(_parse_decimal_int("x12"), 0)
    assert_equal(_parse_decimal_int("0"), 0)
    assert_equal(_parse_decimal_int("17179869184"), 17179869184)
    assert_equal(_parse_decimal_int("4096 kB"), 4096)
    assert_equal(_parse_decimal_int("90/"), 90)


def test_find_substring_bytes() raises:
    var s = String("MemTotal: 1 kB\nMemAvailable: 2 kB\n")
    var bs = s.as_bytes()
    assert_equal(_find_substring_bytes(bs, ""), 0)
    assert_equal(_find_substring_bytes(bs, "MemTotal:"), 0)
    # "Mem" matches at 0 and 15 before "MemAvailable:" matches whole at 15.
    assert_equal(_find_substring_bytes(bs, "MemAvailable:"), 15)
    assert_equal(_find_substring_bytes(bs, "kB\n"), 12)
    # The last possible start (stop = h_len - n_len) is searched.
    assert_equal(_find_substring_bytes(bs, "2 kB\n"), s.byte_length() - 5)
    assert_equal(_find_substring_bytes(bs, "MemFree:"), -1)
    var short = String("0:")
    assert_equal(_find_substring_bytes(short.as_bytes(), "0::"), -1)
    var exact = String("0::")
    assert_equal(_find_substring_bytes(exact.as_bytes(), "0::"), 0)


def test_parent_cgroup_path() raises:
    assert_equal(_parent_cgroup_path(""), "/")
    assert_equal(_parent_cgroup_path("/"), "/")
    assert_equal(_parent_cgroup_path("/a"), "/")
    assert_equal(_parent_cgroup_path("/a/b"), "/a")
    assert_equal(_parent_cgroup_path("/user.slice/u.slice/s.scope"), "/user.slice/u.slice")
    # No slash at all: the walk goes straight to the root.
    assert_equal(_parent_cgroup_path("ab"), "/")


# -----------------------------------------------------------------------------
# _read_small_file_to_string
# -----------------------------------------------------------------------------


def test_reader_missing_empty_and_newline_files() raises:
    var empty = _scratch("pp_empty")
    var newline = _scratch("pp_newline")
    var one = _scratch("pp_one")
    var bare = _scratch("pp_bare")
    var inner = _scratch("pp_inner")
    _write(empty, "")
    _write(newline, "\n")
    _write(one, "max\n")
    _write(bare, "123")
    _write(inner, "a\nb\n")
    assert_equal(_read_small_file_to_string(_scratch("pp_missing")), "")
    assert_equal(_read_small_file_to_string(empty), "")
    assert_equal(_read_small_file_to_string(newline), "")
    comptime if CompilationTarget.is_linux():
        assert_equal(_read_small_file_to_string(one), "max")
        assert_equal(_read_small_file_to_string(bare), "123")
        # Only the LAST newline is stripped.
        assert_equal(_read_small_file_to_string(inner), "a\nb")
    else:
        assert_equal(_read_small_file_to_string(one), "")


def test_reader_caps_at_4_kib() raises:
    var at_cap = _scratch("pp_4096")
    var over = _scratch("pp_5000")
    var nl_at_cap = _scratch("pp_nl_at_cap")
    _write(at_cap, _repeat("a", 4096))
    _write(over, _repeat("b", 5000))
    # Byte 4096 (the last one read) is a newline; byte 4097 is not read.
    _write(nl_at_cap, _repeat("c", 4095) + "\nd")
    comptime if CompilationTarget.is_linux():
        assert_equal(_read_small_file_to_string(at_cap).byte_length(), 4096)
        assert_equal(_read_small_file_to_string(over).byte_length(), 4096)
        assert_equal(_read_small_file_to_string(nl_at_cap), _repeat("c", 4095))
    else:
        assert_equal(_read_small_file_to_string(at_cap), "")


# -----------------------------------------------------------------------------
# The memory basis on this host
# -----------------------------------------------------------------------------


def test_min_of_readable_takes_the_smaller_readable_signal() raises:
    # 0 means unreadable. Both readable: the smaller one, either order.
    assert_equal(_min_of_readable(5 << 30, 7 << 30), 5 << 30)
    assert_equal(_min_of_readable(7 << 30, 5 << 30), 5 << 30)
    assert_equal(_min_of_readable(4096, 4096), 4096)
    # Only one readable: that one, whichever side it is on.
    assert_equal(_min_of_readable(5 << 30, 0), 5 << 30)
    assert_equal(_min_of_readable(0, 7 << 30), 7 << 30)
    # Neither readable: 0, so the caller falls back to its fixed default.
    assert_equal(_min_of_readable(0, 0), 0)


def test_basis_on_this_host_is_bounded_by_the_signals() raises:
    # MemAvailable moves between any two reads on a busy host, so the live
    # basis is not compared with a second reading here (the rule itself is
    # pinned above from literals). What must hold on every read: the basis
    # never exceeds a cgroup cap, and on Linux it is a positive byte count.
    var cg = _linux_read_cgroup_v2_mem_max_bytes()
    var basis = detect_scan_cache_ram_basis_bytes()
    assert_true(cg >= 0)
    if cg > 0:
        assert_true(basis <= cg, "the basis never exceeds the cgroup cap")
    comptime if CompilationTarget.is_linux():
        var avail = _linux_read_meminfo_available_bytes()
        assert_true(avail > 0, "/proc/meminfo has MemAvailable on Linux")
        assert_equal(avail % 1024, 0, "kibibytes are scaled to bytes")
        assert_true(basis > 0, "MemAvailable is readable, so the basis is")


def test_cgroup_path_is_the_unified_line() raises:
    var rel = _cgroup_v2_self_rel_path()
    var raw = _read_small_file_to_string("/proc/self/cgroup")
    var at = raw.find("0::")
    if at < 0:
        assert_equal(rel, "")
    else:
        var rest = String(raw[byte = at + 3 :])
        var nl = rest.find("\n")
        var want = rest if nl < 0 else String(rest[byte = 0:nl])
        assert_equal(rel, want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
