# =============================================================================
# test_mmap_region_willneed.mojo — MADV_WILLNEED readahead-advice guard.
# =============================================================================
#
# WHAT THIS PINS, and why a timing change needs a non-timing oracle.
#
# `MmapRegion.open_readonly` issues `madvise(MADV_WILLNEED)` over the whole
# mapping. The entire OBSERVABLE effect of that syscall is on WALL TIME: the
# mapping's contents, length, and address are identical whether or not it is
# issued. So a regression that silently stopped issuing it — a refactor that
# drops the call, a shim rename, an `#ifdef` that compiles it out on one
# platform — would be invisible to every existing test, and would look in a
# benchmark exactly like "the optimisation stopped paying off on this box".
# That is the failure mode this file exists to make loud.
#
# The oracle is `MmapRegion.advice_rc()`, which distinguishes THREE states that
# a bare boolean could not:
#
#     0                    issued, and the kernel accepted it
#    -1                    issued, and the syscall FAILED
#     ADVICE_NOT_ISSUED    never called (a region with no mapping)
#
# The third value is the load-bearing one. Without it, "we deleted the call"
# and "the call succeeded" would both read as 0 and this test would pass on
# code that does nothing.
#
# FAILS BEFORE / PASSES AFTER (each breakage below fails this file):
#   * Delete the `komira_madvise_willneed` call from `open_readonly` and the
#     field keeps its constructor value `ADVICE_NOT_ISSUED` ->
#     `test_willneed_is_issued_on_a_real_mapping` fails on a real mapping.
#   * Make the C shim `return -1;` -> the same test fails with rc=-1, which is
#     a DIFFERENT message, so the two breakages are distinguishable.
#
# The byte-oracle below is the second half of the guard: `madvise` is
# documented not to modify page contents (man 2 madvise), and this test pins
# that rather than citing it — the same discipline `owned_aligned_buffer.mojo`
# applies to its own `MADV_HUGEPAGE` / `MADV_POPULATE_WRITE` calls.
#
# Meaningful under AOT — the config the shipped engine is built in, and the
# one where an FFI symbol that failed to link shows up.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_not_equal, assert_true

from komira_libc.chunked_write import write_chunked
from komira_buffer.mmap_region import ADVICE_NOT_ISSUED, MmapRegion
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# The same test can run more than once at a time on one host. A fixed `/tmp`
# path is shared by every one of those executions, and no `TMPDIR` /
# `TEST_TMPDIR` the runner sets can redirect it. `TEST_TMPDIR` is private to
# each test execution, which is what keeps them disjoint.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_libc.posix` is
# the canonical one.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        return String("/tmp")
    return d


# =============================================================================
# Helpers
# =============================================================================


def _make_tmp_path(name: String) -> String:
    return (_scratch_dir() + String("/komira_test_mmap_willneed_")) + name


def _write_file_bytes(path: String, bytes: List[UInt8]) raises:
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^


def _build_pattern(n: Int) -> List[UInt8]:
    """A pattern whose period (251, prime) does not divide the 4096-byte page
    size, so a byte that came from the WRONG PAGE is a value mismatch rather
    than an accidental match."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i % 251))
    return out^


# =============================================================================
# Tests
# =============================================================================


def test_willneed_is_issued_on_a_real_mapping() raises:
    """THE FALSIFIER. A real mapping must carry `advice_rc() == 0` — the
    advice was issued AND the kernel accepted it.

    A 256 KiB file (64 pages) rather than a 1-byte one: `MADV_WILLNEED` on a
    sub-page range is the degenerate case a kernel is most likely to accept
    without doing anything, and this test is meant to exercise the shape the
    engine actually uses — a whole-file mapping spanning many pages."""
    var path = _make_tmp_path("issued_256k")
    var n = 256 * 1024
    _write_file_bytes(path, _build_pattern(n))

    var region = MmapRegion.open_readonly(path)
    assert_equal(region.len(), n, "mmap'd length must equal file size")
    assert_not_equal(
        region.advice_rc(),
        ADVICE_NOT_ISSUED,
        "madvise(MADV_WILLNEED) was NEVER ISSUED for a live mapping —"
        " open_readonly no longer calls komira_madvise_willneed. The cold"
        " readahead win is silently gone.",
    )
    assert_equal(
        region.advice_rc(),
        0,
        "madvise(MADV_WILLNEED) was issued but the syscall FAILED (rc=-1)."
        " The mapping is still usable (demand-paged), but the readahead hint"
        " is not reaching the kernel on this platform.",
    )
    _ = region^


def test_empty_region_reports_advice_not_issued() raises:
    """A default-constructed region has no mapping to advise, and must say so
    with the third state rather than the success value.

    This is what makes the falsifier above sharp: if `ADVICE_NOT_ISSUED` were
    0, deleting the `madvise` call would leave every region reporting
    "success" and the guard would pass on code that does nothing."""
    var region = MmapRegion()
    assert_true(region.is_empty(), "default-constructed region must be empty")
    assert_equal(
        region.advice_rc(),
        ADVICE_NOT_ISSUED,
        "a region with no mapping must report ADVICE_NOT_ISSUED, never 0 —"
        " 'we never called it' must not be readable as 'it worked'",
    )
    assert_not_equal(
        ADVICE_NOT_ISSUED,
        0,
        "ADVICE_NOT_ISSUED must be distinguishable from a successful madvise",
    )
    assert_not_equal(
        ADVICE_NOT_ISSUED,
        -1,
        "ADVICE_NOT_ISSUED must be distinguishable from a failed madvise",
    )


def test_willneed_does_not_alter_the_bytes() raises:
    """BYTE-ORACLE. `madvise` is a hint about page RESIDENCY and must not
    change page CONTENTS (man 2 madvise). Pinned, not cited.

    Every byte of a 256 KiB (64-page) mapping is compared, so a hint that
    populated the wrong pages — or zero-filled them — cannot hide in the gaps
    a sampled comparison would leave."""
    var path = _make_tmp_path("bytes_256k")
    var n = 256 * 1024
    var src = _build_pattern(n)
    _write_file_bytes(path, src)

    var region = MmapRegion.open_readonly(path)
    assert_equal(region.len(), n, "mmap'd length must equal file size")
    var view = region.data()
    var mismatches = 0
    var first_bad = -1
    for i in range(n):
        if Int(view.read_u8_at(i)) != Int(src[i]):
            mismatches += 1
            if first_bad < 0:
                first_bad = i
    assert_equal(
        mismatches,
        0,
        "madvise(MADV_WILLNEED) altered mapped contents: "
        + String(mismatches)
        + " byte(s) differ, first at offset "
        + String(first_bad),
    )
    _ = region^


def test_willneed_survives_a_single_page_file() raises:
    """A file SMALLER than one page. The mapping's length is not page-aligned,
    which is the argument shape most likely to make `madvise` return EINVAL —
    and an EINVAL here would mean the engine's small-file reads (footers,
    tiny fixtures) all carry a failed syscall nobody noticed."""
    var path = _make_tmp_path("subpage_100")
    var n = 100
    var src = _build_pattern(n)
    _write_file_bytes(path, src)

    var region = MmapRegion.open_readonly(path)
    assert_equal(region.len(), n, "mmap'd length must equal file size")
    assert_equal(
        region.advice_rc(),
        0,
        "madvise(MADV_WILLNEED) must accept a sub-page, non-page-aligned"
        " length — it rounds the range out to page boundaries itself",
    )
    var view = region.data()
    for i in range(n):
        assert_equal(
            Int(view.read_u8_at(i)),
            Int(src[i]),
            "byte mismatch at offset " + String(i),
        )
    _ = region^


# =============================================================================
# The RANGE form of the advice and its counter
# =============================================================================
#
# WHAT CHANGED AND WHY IT NEEDS ITS OWN ORACLE. `open_readonly` now takes
# `advise_whole_file`, and the Parquet read path passes `False` and advises the
# column-chunk ranges it borrows instead. The advice is a HINT: the mapping's
# bytes, length and address are identical whether it covers many GB or 16 KiB,
# so "the reader advises ranges now" and "the reader advises nothing now" are
# indistinguishable to every value-based test and look the same in a benchmark.
#
# `MmapRegion.willneed_advised_bytes()` is the discriminator — a process-wide
# monotone count of bytes handed to `madvise(MADV_WILLNEED)` by BOTH forms. The
# tests below assert on its DELTA, which is the only way to tell "sized by the
# range" from "sized by the file" from "not issued at all".
#
# FAILS BEFORE / PASSES AFTER (proved by mutation, both directions):
#   * Make `advise_whole_file=False` issue the whole-file advice anyway ->
#     `test_declined_whole_file_advice_advises_nothing` fails on the delta.
#   * Make `advise_willneed_range` `return ADVICE_NOT_ISSUED` without calling ->
#     `test_range_advice_is_sized_by_the_range` fails on delta == 0, and NOT on
#     the upper bound, so a no-op cannot pass as a tight advice.


def test_declined_whole_file_advice_advises_nothing() raises:
    """`advise_whole_file=False` must issue NO advice at the open — not a
    smaller one, none — and must say so with `ADVICE_NOT_ISSUED` on a LIVE
    mapping.

    The byte delta is the load-bearing half. `advice_rc()` alone would pass
    against an implementation that issued the advice and then forgot to record
    the rc; the counter cannot be satisfied that way."""
    var path = _make_tmp_path("declined_256k")
    var n = 256 * 1024
    var src = _build_pattern(n)
    _write_file_bytes(path, src)

    var before = MmapRegion.willneed_advised_bytes()
    var region = MmapRegion.open_readonly(path, advise_whole_file=False)
    var delta = MmapRegion.willneed_advised_bytes() - before

    assert_equal(region.len(), n, "mmap'd length must equal file size")
    assert_equal(
        delta,
        0,
        "open_readonly(advise_whole_file=False) advised "
        + String(delta)
        + " bytes — it must advise NONE. A projecting consumer asked to size"
        " the advice itself and was overruled by the open.",
    )
    assert_equal(
        region.advice_rc(),
        ADVICE_NOT_ISSUED,
        "a mapping opened with advise_whole_file=False must report"
        " ADVICE_NOT_ISSUED — the whole-file advice was not issued",
    )
    # ...and it is a REAL mapping, not a failed one: every byte readable.
    var view = region.data()
    for i in range(n):
        assert_equal(
            Int(view.read_u8_at(i)),
            Int(src[i]),
            "byte mismatch at offset " + String(i),
        )
    _ = region^


def test_whole_file_advice_is_sized_by_the_file() raises:
    """THE DIFFERENTIAL ORACLE. The default arm must move the counter by the
    FILE SIZE (rounded out to whole pages), which is what makes the two tests
    around it falsifiers rather than tautologies: the same probe reads ~0 on the
    declined arm, ~one page on the range arm, and ~the file here."""
    var path = _make_tmp_path("wholefile_256k")
    var n = 256 * 1024
    _write_file_bytes(path, _build_pattern(n))

    var before = MmapRegion.willneed_advised_bytes()
    var region = MmapRegion.open_readonly(path)
    var delta = MmapRegion.willneed_advised_bytes() - before

    assert_equal(region.advice_rc(), 0, "default arm issues the advice")
    assert_true(
        delta >= n,
        "the whole-file arm advised "
        + String(delta)
        + " bytes for a "
        + String(n)
        + "-byte file — it must advise at least the whole file",
    )
    _ = region^


def test_range_advice_is_sized_by_the_range() raises:
    """The range form must advise A PAGE OR TWO for a 1-byte request over a
    256 KiB mapping — not the mapping, and not nothing.

    Both bounds are load-bearing. The LOWER one (delta > 0) fails a refactor
    that turns `advise_willneed_range` into a no-op, which is the failure mode
    that would look in a benchmark exactly like the win evaporating. The UPPER
    one fails an implementation that quietly advises the whole mapping, which is
    the defect this whole lever exists to remove.

    The bound is 64 KiB because the PAGE SIZE is a platform property resolved in
    C (`sysconf(_SC_PAGESIZE)`: 16 KiB on macOS arm64, 4 KiB on linux x86_64)
    and this test must not hardcode either. 64 KiB clears both by 4x and is
    still 4x below the mapping."""
    var path = _make_tmp_path("range_256k")
    var n = 256 * 1024
    var src = _build_pattern(n)
    _write_file_bytes(path, src)

    var region = MmapRegion.open_readonly(path, advise_whole_file=False)
    var before = MmapRegion.willneed_advised_bytes()
    var rc = region.advise_willneed_range(0, 1)
    var delta = MmapRegion.willneed_advised_bytes() - before

    assert_equal(
        rc,
        0,
        "advise_willneed_range must be ISSUED AND ACCEPTED (rc=0); got "
        + String(rc)
        + " — ADVICE_NOT_ISSUED(2) means it declined a range it should have"
        " taken, -1 means the syscall failed on this platform",
    )
    assert_true(
        delta > 0,
        "advise_willneed_range advised ZERO bytes — it is a no-op, and a"
        " no-op here is indistinguishable in a benchmark from the readahead"
        " win never having existed",
    )
    assert_true(
        delta <= 64 * 1024,
        "a 1-byte range advised "
        + String(delta)
        + " bytes; it must be page-sized, not mapping-sized (mapping is "
        + String(n)
        + ")",
    )
    # BYTE-ORACLE, same discipline as the whole-file arm above.
    var view = region.data()
    for i in range(n):
        assert_equal(
            Int(view.read_u8_at(i)),
            Int(src[i]),
            "range advice altered mapped contents at offset " + String(i),
        )
    _ = region^


def test_range_advice_refuses_what_it_cannot_advise() raises:
    """A range with nothing in it must report `ADVICE_NOT_ISSUED` and issue no
    syscall — never 0, which would read as "it worked", and never -1, which
    would read as "the platform rejected it"."""
    var empty = MmapRegion()
    assert_equal(
        empty.advise_willneed_range(0, 4096),
        ADVICE_NOT_ISSUED,
        "a region with no mapping has nothing to advise",
    )

    var path = _make_tmp_path("refuse_100")
    var n = 100
    _write_file_bytes(path, _build_pattern(n))
    var region = MmapRegion.open_readonly(path, advise_whole_file=False)

    var before = MmapRegion.willneed_advised_bytes()
    assert_equal(
        region.advise_willneed_range(n, 8),
        ADVICE_NOT_ISSUED,
        "an offset AT the end of the mapping has nothing to advise",
    )
    assert_equal(
        region.advise_willneed_range(0, 0),
        ADVICE_NOT_ISSUED,
        "a zero-length range has nothing to advise",
    )
    assert_equal(
        region.advise_willneed_range(-1, 8),
        ADVICE_NOT_ISSUED,
        "a negative offset has nothing to advise",
    )
    assert_equal(
        MmapRegion.willneed_advised_bytes() - before,
        0,
        "a refused range must issue no syscall at all",
    )

    # A range that RUNS PAST the end is CLAMPED, not refused — a column chunk
    # at the tail of a file is the ordinary case, and refusing it would silently
    # drop the advice for exactly the last chunk of every column.
    assert_equal(
        region.advise_willneed_range(0, n * 100),
        0,
        "a range overrunning the mapping must be CLAMPED and issued",
    )
    _ = region^


def main() raises:
    var suite = TestSuite()
    suite.test[test_willneed_is_issued_on_a_real_mapping]()
    suite.test[test_empty_region_reports_advice_not_issued]()
    suite.test[test_willneed_does_not_alter_the_bytes]()
    suite.test[test_willneed_survives_a_single_page_file]()
    suite.test[test_declined_whole_file_advice_advises_nothing]()
    suite.test[test_whole_file_advice_is_sized_by_the_file]()
    suite.test[test_range_advice_is_sized_by_the_range]()
    suite.test[test_range_advice_refuses_what_it_cannot_advise]()
    suite^.run()
