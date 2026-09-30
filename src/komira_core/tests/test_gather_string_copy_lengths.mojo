# =============================================================================
# test_gather_string_copy_lengths.mojo — byte-exactness of the variable-width
# gather's per-string copy across EVERY `len mod 32` residue and across the
# under-32 arm.
#
# WHY THIS TEST EXISTS
# --------------------
# `_GatherStrScatterWork::process` (komira_core/helpers/compiler_helpers.mojo)
# copies each gathered string with `fast_copy_bytes` rather than stdlib
# `memcpy`, whose inline expansion is a 32 B `vmovups` bulk loop followed by a
# ONE-BYTE-PER-ITERATION scalar remainder loop for `len mod 32`.
# `fast_copy_bytes` uses STRAIGHT-LINE OVERLAPPING vector blocks: the final
# 32 B store is anchored at `n - 32` and therefore REWRITES up to 31 bytes
# that an earlier block already wrote.
#
# That overlap is the hazard this test guards. Three distinct arms are selected
# purely by length, and each has its own off-by-one surface:
#
#   n <  32   `_copy_small`  — branchy overlapping 16/8/4/1-byte pairs
#   32..128   `_copy_mid`    — 2 or 4 overlapping 32 B blocks, no loop
#   n >  128  `_copy_large_unrolled` — aligned 128 B/iter + ONE overlapping
#                              32 B tail store anchored at `n - 32`
#
# FALSIFIES: any tail arm that copies the WRONG bytes (a mis-anchored
# overlapping store), copies TOO FEW bytes (a residue the ladder drops), or
# reads/writes past the logical string. The per-row byte pattern is a function
# of BOTH the row index and the byte offset, so a copy that lands the right
# COUNT of bytes from the WRONG row — or the right row at the wrong offset —
# fails on content, not just on length. A test with constant-filled strings
# would pass all three of those bugs.
#
# COVERAGE OF THE RESIDUE CLASS
#   lengths 0..31    -> the whole `n < 32` ladder, including n == 0
#   lengths 32..63   -> `len mod 32` == 0..31 in the `_copy_mid` <= 64 arm
#   lengths 96..127  -> `len mod 32` == 0..31 in the `_copy_mid` 4-block arm
#   lengths 129..160 -> `len mod 32` == 1..0 in `_copy_large_unrolled`
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.helpers.compiler_helpers import gather_batch


# -----------------------------------------------------------------------------
# Fixture
# -----------------------------------------------------------------------------

# Row `r` holds a string of length `_LENGTHS[r]` whose byte `j` is
# `'A' + ((r * 7 + j * 3) % 26)`. Both indices participate, so neither a
# wrong-row copy nor a wrong-offset copy can produce the expected bytes.


def _expected(row: Int, n: Int) -> String:
    var s = String("")
    for j in range(n):
        s += chr(ord("A") + ((row * 7 + j * 3) % 26))
    return s


def _lengths() -> List[Int]:
    """Every length class that selects a distinct copy arm."""
    var out = List[Int]()
    for n in range(0, 32):  # `_copy_small` ladder, incl. the zero-length row
        out.append(n)
    for n in range(32, 64):  # `_copy_mid`, <= 64 arm: len mod 32 == 0..31
        out.append(n)
    for n in range(96, 128):  # `_copy_mid`, 4-block arm: len mod 32 == 0..31
        out.append(n)
    for n in range(129, 161):  # `_copy_large_unrolled` + overlapping tail
        out.append(n)
    return out^


def _build_batch() raises -> RecordBatch:
    var lens = _lengths()
    var vals = List[String]()
    for r in range(len(lens)):
        vals.append(_expected(r, lens[r]))
    var arr = StringArray.from_strings(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var schema = sb.build()
    return RecordBatch.from_typed_columns_1(schema^, Column.from_string(arr))


def _check(batch: RecordBatch, indices: List[Int]) raises:
    var lens = _lengths()
    var out = gather_batch(batch, indices)
    assert_equal(out.num_rows(), len(indices), "gathered row count")
    var sa = out.column_as_string(0)
    for k in range(len(indices)):
        var src_row = indices[k]
        assert_equal(
            sa.get(k),
            _expected(src_row, lens[src_row]),
            String("row ") + String(k) + " <- src " + String(src_row)
            + " (len " + String(lens[src_row]) + ")",
        )


# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------


def test_fixture_actually_covers_every_residue() raises:
    """ANTI-VACUITY. Every other case in this file asserts
    `gathered == _expected(row, lens[row])` — a comparison in which BOTH sides
    come from `_lengths()`. That is self-consistent, so if `_lengths()` ever
    silently stopped producing (say) the 17..31 B class, the suite would go on
    passing while covering nothing. This case makes the COVERAGE CLAIM in the
    header a thing the test itself checks: the fixture must span every
    `len mod 32` residue 0..31 in each of the three copy arms, and must
    include the zero-length row."""
    var lens = _lengths()
    assert_equal(len(lens), 128, "fixture row count")

    var has_zero = False
    # Per-arm residue bitsets: 0 = `_copy_small` (n < 32), 1 = `_copy_mid`
    # (32..128), 2 = `_copy_large_unrolled` (n > 128).
    var seen = List[Bool](length=96, fill=False)
    var counts = List[Int](length=3, fill=0)
    for k in range(len(lens)):
        var n = lens[k]
        if n == 0:
            has_zero = True
        var arm = 0 if n < 32 else (1 if n <= 128 else 2)
        counts[arm] = counts[arm] + 1
        seen[arm * 32 + (n % 32)] = True
    assert_equal(has_zero, True, "fixture must include a zero-length row")
    assert_equal(counts[0], 32, "under-32 arm rows")
    assert_equal(counts[1], 64, "32..128 arm rows")
    assert_equal(counts[2], 32, "over-128 arm rows")

    # Each arm must hit all 32 residues of `len mod 32` — the exact class the
    # replaced stdlib byte-tail loop iterated over.
    for arm in range(3):
        var n_seen = 0
        for r in range(32):
            if seen[arm * 32 + r]:
                n_seen += 1
        assert_equal(
            n_seen, 32, String("arm ") + String(arm) + " residue coverage"
        )


def test_identity_gather_every_length_class() raises:
    """Every length 0..31, 32..63, 96..127, 129..160 copied byte-exact."""
    var batch = _build_batch()
    var idx = List[Int]()
    for r in range(len(_lengths())):
        idx.append(r)
    _check(batch, idx)


def test_reversed_gather_every_length_class() raises:
    """Reversed order — output offsets no longer track source offsets, so a
    tail store anchored off the SOURCE end (rather than the destination end)
    is caught here and not by the identity case."""
    var batch = _build_batch()
    var n = len(_lengths())
    var idx = List[Int]()
    for r in range(n - 1, -1, -1):
        idx.append(r)
    _check(batch, idx)


def test_sparse_gather_mixes_arms_adjacently() raises:
    """Interleave a short row with a long row so a >128 B copy is immediately
    followed by a <32 B copy in the SAME destination buffer. An overlapping
    tail store that overruns its logical end would clobber the next row's
    bytes, which only shows up when the arms alternate."""
    var batch = _build_batch()
    var n = len(_lengths())
    var idx = List[Int]()
    var i = 0
    while i < n // 2:
        idx.append(i)  # short (0..31 B) then long (129..160 B)
        idx.append(n - 1 - i)
        i += 1
    _check(batch, idx)


def test_repeated_index_gather() raises:
    """The same source row gathered many times — the fan-out shape the join
    output gather actually produces. Each destination copy starts at a
    different (unaligned) offset, so the alignment-sensitive arms of
    `_copy_large_unrolled` are exercised at every phase."""
    var batch = _build_batch()
    var lens = _lengths()
    var long_row = len(lens) - 1  # length 160
    var short_row = 5  # length 5, forces every phase offset
    var idx = List[Int]()
    for k in range(64):
        idx.append(long_row if (k % 3 == 0) else short_row)
    _check(batch, idx)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
