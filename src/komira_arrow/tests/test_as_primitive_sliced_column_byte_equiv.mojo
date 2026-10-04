# =============================================================================
# test_as_primitive_sliced_column_byte_equiv.mojo
#
# REGRESSION GUARD — `as_primitive` on a sliced column must copy the WINDOW.
#
# `Column.as_primitive()` must copy only the WINDOW [_offset, _offset+_length),
# NOT the [0, _offset+_length) PREFIX. On an Arc-sliced morsel (`Column.slice`)
# `_offset` marches monotonically across the morsels of a resident probe
# batch, so a prefix copy makes per-morsel join-key extraction
# O(total_rows^2 / morsel_rows) in DRAM traffic (on the order of 10x wall and
# ~140 GB copied through `as_primitive` on a TPC-H-scale join). The window
# copy moves only `_length` elems (mirrors `_slice_fixed_width`) and rebases
# the result to offset=0.
#
# MECHANISM GUARD (the anti-quadratic assertion): the PrimitiveArray returned by
# `as_primitive` on a sliced column holds ONLY `length` elems of data
# (`arr.data.len() == length * elem_size`), NOT `(offset+length)` elems. A
# prefix copy makes the buffer `(offset+length)*elem_size` bytes, so the
# assertion trips for any start > 0.
#
# VALUE GUARD (independent oracle): `as_primitive` on `Column.slice(start,len)`
# reads value-identical to the SOURCE list at [start, start+len) — the source
# is read directly (no reuse of the slice/as_primitive path), so a bug in the
# window offset or validity rebasing is caught, not masked.
#
# ---------------------------------------------------------------------------
# THE CONTRACT HAS TWO HALVES
# ---------------------------------------------------------------------------
#
# The MECHANISM GUARD above is not only an anti-quadratic assertion about the
# COPY. It is the EXTENT half of `as_primitive`'s contract, and the contract
# has two halves that must be asserted together:
#
#     arr.offset == 0                      (the result is REBASED)
#     arr.data.len() == length * elem       (the buffer IS the window)
#
# A zero-copy arm that Arc-shares the WHOLE source buffer and carries
# `Column._offset` onto `PrimitiveArray.offset` breaks BOTH, while values stay
# correct — every `PrimitiveArray` value accessor indexes `self.offset + i` —
# so no value oracle fires. The buffer-size assert is what catches it
# (`left: 2048, right: 512`), and `offset == 0` is pinned on the NON-nullable
# path as well.
#
# WHY THAT MATTERS, i.e. why the right fix is to narrow the share and not to
# relax this assertion: two ordinary continuations of an `as_primitive` result
# copy `[0, offset + length)` FROM BYTE 0 —
#
#     Column.from_primitive   (data_bytes = (arr.offset + arr.length) * elem)
#     PrimitiveArray.slice    (total_elems = self.offset + start + length)
#
# so handing them an offset-carrying whole-buffer share turns a WINDOW copy
# into a PREFIX copy: the same O(total_rows^2 / morsel_rows) shape, one level
# downstream, on the same marching per-morsel `_offset`.
# `partition_scan_sink._clone_column` and `partition_topn_sink` compose
# exactly that way, 4 dtype arms each.
#
# The two `_compose` cases below therefore assert the contract THROUGH those
# two continuations, not just on the array itself — a future zero-copy arm can
# satisfy an extent assert on `arr` and still be prefix-copying downstream if
# it hands back a non-zero `offset`.
#
# ⚠ Every assertion is written against an independently computed spec, never
# against whichever branch is compiled: it pins the copy path's contract and
# that any share is INDISTINGUISHABLE from it.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion


def _source_i64(n: Int) -> List[Int64]:
    var v = List[Int64]()
    for r in range(n):
        v.append(Int64(100000 + r * 7))
    return v^


def _assert_as_primitive_window(
    imm src_col: Column[HeapRegion],
    imm src_vals: List[Int64],
    start: Int,
    length: Int,
) raises:
    comptime elem = size_of[Scalar[DType.int64]]()
    var sliced = src_col.slice(start, length)
    var arr = sliced.as_primitive[DType.int64]()

    # length is the window length.
    assert_equal(arr.length, length, "as_primitive length == window length")

    # MECHANISM GUARD: the buffer holds ONLY `length` elems (not offset+length).
    # A prefix copy makes this (start+length)*elem -> trips for any start > 0.
    assert_equal(
        arr.data.len(),
        length * elem,
        "as_primitive copies only the window (anti-quadratic guard)",
    )

    # CONTRACT GUARD, the OTHER half. `offset == 0` is what makes the
    # buffer-size assert above MEAN "this buffer is the window": an array can
    # hold exactly `length` elems and still be mis-based (a zero-copy arm
    # returning `offset == start`).
    assert_equal(
        arr.offset,
        0,
        "as_primitive rebases the window to offset 0",
    )

    # VALUE GUARD: independent oracle against the source list.
    for i in range(length):
        assert_equal(
            Int(arr.get(i)),
            Int(src_vals[start + i]),
            "as_primitive window value == source[start+i]",
        )


def test_as_primitive_sliced_int64_window_only() raises:
    var n = 256
    var vals = _source_i64(n)
    var col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )
    # Non-zero-start windows: the probe-batch shape (offset marches forward across the
    # morsels of one resident probe batch).
    _assert_as_primitive_window(col, vals, 0, n)  # full column, offset 0
    _assert_as_primitive_window(col, vals, 64, 64)  # interior window
    _assert_as_primitive_window(col, vals, 192, 64)  # far window (large offset)
    _assert_as_primitive_window(col, vals, 255, 1)  # last row, max offset


def test_as_primitive_sliced_nullable_validity_rebased() raises:
    # Exercise the validity-rebasing path: nullable INT64, some nulls inside and
    # outside the sliced window. The window null_count + is_null pattern must
    # rebase to [0, len).
    comptime elem = size_of[Scalar[DType.int64]]()
    var n = 128
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var vals = List[Int64]()
    for r in range(n):
        var val = Int64(500 + r)
        arr.set(r, val)
        vals.append(val)
    # Null out a few positions; 85 and 100 fall inside the window [80,110), 10
    # is outside and must NOT count post-rebase.
    arr._set_null(85)
    arr._set_null(100)
    arr._set_null(10)
    var col = Column.from_primitive[DType.int64](arr^)

    var start = 80
    var length = 30
    var sliced = col.slice(start, length)
    var pa = sliced.as_primitive[DType.int64]()
    assert_equal(
        pa.data.len(), length * elem, "nullable window buffer size (anti-quadratic)"
    )
    # Two nulls fall inside [80,110): global positions 85 and 100.
    assert_equal(
        pa.null_count, 2, "window null_count rebased to the window"
    )
    for i in range(length):
        var global_idx = start + i
        var expect_null = (global_idx == 85) or (global_idx == 100)
        assert_equal(
            pa.is_null(i), expect_null, "is_null rebased to [0, len)"
        )
        if not expect_null:
            assert_equal(
                Int(pa.get(i)), Int(vals[global_idx]), "nullable window value"
            )


def test_as_primitive_compose_from_primitive_no_prefix_copy() raises:
    """`Column.from_primitive(sliced.as_primitive())` must copy the WINDOW.

    THE DOWNSTREAM HALF of the anti-quadratic guard, and the one an
    extent assert on `arr` alone cannot cover. `Column.from_primitive` sizes
    its copy `(arr.offset + arr.length) * elem` and reads it from BYTE 0, so an
    `as_primitive` result carrying a non-zero `offset` makes it copy the
    PREFIX — quadratic on a marching per-morsel offset, with correct values and
    no crash. Live compose sites: `partition_scan_sink._clone_column` and
    `partition_topn_sink`, 4 dtype arms each.

    FAILS IN THE DIRECTION IT GUARDS: make `Column.as_primitive` share the
    whole buffer (`share_as[HeapRegion]()` + `offset=self._offset`) and the
    cloned column's buffer comes back 2048 bytes for a 64-row window instead
    of 512.
    """
    comptime elem = size_of[Scalar[DType.int64]]()
    var n = 256
    var vals = _source_i64(n)
    var col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )
    var start = 192
    var length = 64
    var sliced = col.slice(start, length)
    assert_equal(sliced._offset, start, "fixture: Column.slice carries _offset")

    var cloned = Column.from_primitive[DType.int64](
        sliced.as_primitive[DType.int64]()
    )
    assert_equal(cloned.length(), length, "cloned column length == window")
    assert_equal(
        cloned._offset, 0, "cloned column must be rebased, not prefix-based"
    )
    assert_equal(
        cloned._data.len(),
        length * elem,
        "from_primitive(as_primitive(sliced)) must copy only the window",
    )
    # Values survive the round trip, read against the SOURCE list.
    var back = cloned.as_primitive[DType.int64]()
    for i in range(length):
        assert_equal(
            Int(back.get(i)),
            Int(vals[start + i]),
            "cloned window value == source[start+i]",
        )


def test_as_primitive_compose_slice_no_prefix_copy() raises:
    """`sliced.as_primitive().slice(...)` must not copy the column's prefix.

    Second downstream continuation, same mechanism: `PrimitiveArray.slice`
    sizes its buffer `(self.offset + start + length) * elem` and copies from
    byte 0. With `as_primitive` rebasing to 0 that is `(start + length)` elems
    — the array's own accepted behaviour. With an `as_primitive` result that
    carries the COLUMN's offset it becomes `(col_offset + start + length)`,
    which is the prefix copy again.

    FAILS IN THE DIRECTION IT GUARDS: same restoration as the case above; the
    sub-slice buffer comes back 2048 bytes instead of 384.
    """
    comptime elem = size_of[Scalar[DType.int64]]()
    var n = 256
    var vals = _source_i64(n)
    var col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )
    var col_start = 192
    var col_len = 64
    var sliced = col.slice(col_start, col_len)
    var arr = sliced.as_primitive[DType.int64]()

    var sub_start = 16
    var sub_len = 32
    var sub = arr.slice(sub_start, sub_len)
    assert_equal(sub.length, sub_len, "sub-slice length")
    assert_equal(
        sub.data.len(),
        (sub_start + sub_len) * elem,
        "PrimitiveArray.slice of an as_primitive result must not carry the"
        " COLUMN's prefix",
    )
    for i in range(sub_len):
        assert_equal(
            Int(sub.get(i)),
            Int(vals[col_start + sub_start + i]),
            "sub-slice value == source[col_start+sub_start+i]",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_as_primitive_sliced_int64_window_only]()
    suite.test[test_as_primitive_sliced_nullable_validity_rebased]()
    suite.test[test_as_primitive_compose_from_primitive_no_prefix_copy]()
    suite.test[test_as_primitive_compose_slice_no_prefix_copy]()
    suite^.run()
