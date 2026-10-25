# =============================================================================
# test_zone_values_and_loading.mojo -- the small value types of zone.mojo and
# `load_zone`'s success path
# =============================================================================
#
# The policy and kind structs are built from run-time integers (a constant
# would be folded at the call), so their `==`, `!=` and `LocalKind.name` run.
# The zone's accessors are read on a zone read from a TZif file written here
# byte by byte: `load_zone` reads that file from a directory, as it reads the
# system's zoneinfo.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_datetime import FoldPolicy, GapPolicy, LocalKind, load_zone, parse_tzif, posix_zone


def _ints() -> List[Int]:
    """Values built at run time."""
    var out = List[Int]()
    out.append(0)
    out.append(1)
    out.append(2)
    return out^


def test_policies_and_kinds_compare_by_their_value() raises:
    for a in _ints():
        for b in _ints():
            var same = a == b
            assert_equal(GapPolicy(a) == GapPolicy(b), same)
            assert_equal(GapPolicy(a) != GapPolicy(b), not same)
            assert_equal(FoldPolicy(a) == FoldPolicy(b), same)
            assert_equal(FoldPolicy(a) != FoldPolicy(b), not same)
            assert_equal(LocalKind(a) == LocalKind(b), same)
            assert_equal(LocalKind(a) != LocalKind(b), not same)


def test_a_local_kind_names_itself() raises:
    var names = List[String]()
    names.append("UNIQUE")
    names.append("GAP")
    names.append("FOLD")
    for k in _ints():
        assert_equal(LocalKind(k).name(), names[k])
    # A value that is none of the three is UNIQUE, the kind with no event to report.
    var other = _ints()[2] + 5
    assert_equal(LocalKind(other).name(), "UNIQUE")


def _be4(mut out: List[UInt8], v: Int):
    for k in range(4):
        out.append(UInt8((v >> ((3 - k) * 8)) & 0xFF))


def _tzif_v1() -> List[UInt8]:
    """A version 1 file: AAA at +0 until instant 1000, BBB at +1h from it on; no footer."""
    var out = List[UInt8]()
    for c in "TZif".as_bytes():
        out.append(c)
    for _ in range(16):
        out.append(0)
    _be4(out, 0)  # isutcnt
    _be4(out, 0)  # isstdcnt
    _be4(out, 0)  # leapcnt
    _be4(out, 1)  # timecnt
    _be4(out, 2)  # typecnt
    _be4(out, 8)  # charcnt
    _be4(out, 1000)  # the transition time
    out.append(1)  # to type 1
    _be4(out, 0)  # type 0: AAA, +0, standard
    out.append(0)
    out.append(0)
    _be4(out, 3600)  # type 1: BBB, +1h, DST
    out.append(1)
    out.append(4)
    for c in "AAA".as_bytes():
        out.append(c)
    out.append(0)
    for c in "BBB".as_bytes():
        out.append(c)
    out.append(0)
    return out^


def test_a_zone_reports_its_last_listed_transition_and_its_offset() raises:
    var z = parse_tzif(Span(_tzif_v1()), "Test/Zone")
    var last = z.last_listed_transition()
    assert_true(Bool(last))
    assert_equal(last.value(), 1000)
    assert_equal(z.utc_offset_at(999), 0)
    assert_equal(z.utc_offset_at(1000), 3600)
    # A zone given by a TZ string lists no transition.
    var p = posix_zone("P", "EST5")
    assert_false(Bool(p.last_listed_transition()))
    assert_equal(p.utc_offset_at(0), -5 * 3600)


def _scratch() raises -> String:
    """A directory of this process's own: under the runner's `TEST_TMPDIR` (the test and coverage runs set it:
    empty, writable, removed when the run ends), else `TMPDIR`, else `/tmp` (the branch-coverage run sets none)."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        base = String("/tmp")
    var d = base + "/komira_datetime_zone_" + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def test_load_zone_reads_the_named_file_of_a_directory() raises:
    var root = _scratch() + "/zoneinfo"
    makedirs(root + "/Test", exist_ok=True)
    var data = _tzif_v1()
    Path(root + "/Test/Zone").write_bytes(Span(data))
    var z = load_zone(root, "Test/Zone")
    assert_equal(z.name, "Test/Zone")
    assert_equal(z.transition_count(), 1)
    assert_equal(z.utc_offset_at(5000), 3600)


def test_load_zone_refuses_a_name_with_no_file() raises:
    var got = String()
    try:
        _ = load_zone(_scratch() + "/zoneinfo", "Test/None")
    except e:
        got = String(e)
    assert_true('unknown time zone "Test/None"' in got)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
