"""The four gather kernels against an absolute oracle: `gather_unrolled` and
`gather_pair_unrolled` (`join_gather_unrolled`), `gather_narrow_rolled` and
`gather_pair_narrow_rolled` (`join_gather_narrow`).

Every kernel writes `dst[dst_row + i] = src[src._offset + idx[idx_start + i]]`.
Each case checks every written element against the value the source row holds,
that no byte outside `[dst_row, dst_row + num)` is written (sentinels on both
sides), and the counter the kernel reports to.

The row counts are chosen around the loop boundaries of the unrolled kernels
(`GATHER_PF` = 16, unroll 4): 0 and 15 run only the last loop, 16 is the
boundary, 17 runs one prefetched element, 20 one unrolled block, 23 one block
and three prefetched elements, 99 many blocks. The source column starts at
offset 3 and the index list at `idx_start` 5, so a kernel that ignored either
reads the wrong row. Values are distinct over the source rows and differ from
the sentinels. Every combination of index type (`Int32` and `Int`), payload
width and store kind (`nt`) is instantiated.
"""

from std.sys import size_of
from std.testing import assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_column_kernels.gather_width_counter import (
    gather_narrow_typed_colrows,
)

from komira_dispatch_join_kernels.join_gather_narrow import (
    gather_narrow_rolled,
    gather_pair_narrow_rolled,
)
from komira_dispatch_join_kernels.join_gather_unrolled import (
    GATHER_PF,
    gather_pair_unrolled,
    gather_unrolled,
    join_gather_unrolled_colrows,
)


comptime SRC_ROWS: Int = 101
"""Prime, so the index walk below visits rows in a scrambled order."""

comptime SRC_OFFSET: Int = 3
comptime IDX_START: Int = 5
comptime DST_ROW: Int = 2
comptime SENTINEL: Int = 99
"""Outside every value `_val` returns (-50 .. 50 for column a, -40 .. 60 for
column b), and fits in one byte."""


def _val[VT: DType](row: Int, col_b: Bool) -> Scalar[VT]:
    if col_b:
        return Scalar[VT](row - 40)
    return Scalar[VT](50 - row)


def _arrow_type[VT: DType]() -> ArrowType:
    comptime if VT == DType.int64:
        return ArrowType.INT64
    elif VT == DType.int32:
        return ArrowType.INT32
    elif VT == DType.int16:
        return ArrowType.INT16
    else:
        return ArrowType.INT8


def _src_col[VT: DType](col_b: Bool) raises -> Column[HeapRegion]:
    """`SRC_ROWS` values behind `SRC_OFFSET` sentinel elements."""
    comptime sz = size_of[Scalar[VT]]()
    var n = SRC_OFFSET + SRC_ROWS
    var buf = OwnedAlignedBuffer(n * sz)
    buf.set_length(Int64(n * sz))
    for i in range(SRC_OFFSET):
        buf.set_typed[Scalar[VT]](i, Scalar[VT](SENTINEL))
    for r in range(SRC_ROWS):
        buf.set_typed[Scalar[VT]](SRC_OFFSET + r, _val[VT](r, col_b))
    return Column[HeapRegion](
        arrow_type=_arrow_type[VT](),
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=SRC_ROWS,
        null_count=0,
        offset=SRC_OFFSET,
    )


def _dst[VT: DType](num: Int) -> OwnedAlignedBuffer:
    """Room for `DST_ROW + num + 1` elements, all sentinel."""
    comptime sz = size_of[Scalar[VT]]()
    var n = DST_ROW + num + 1
    var buf = OwnedAlignedBuffer(n * sz)
    buf.set_length(Int64(n * sz))
    for i in range(n):
        buf.set_typed[Scalar[VT]](i, Scalar[VT](SENTINEL))
    return buf^


def _idx[IT: DType](num: Int) -> List[Scalar[IT]]:
    var idx = List[Scalar[IT]](capacity=IDX_START + num)
    for i in range(IDX_START):
        idx.append(Scalar[IT](SRC_ROWS - 1))
    for i in range(num):
        idx.append(Scalar[IT]((i * 37 + 11) % SRC_ROWS))
    return idx^


def _check_dst[IT: DType, VT: DType](
    imm dst: OwnedAlignedBuffer,
    imm idx: List[Scalar[IT]],
    num: Int,
    col_b: Bool,
    imm tag: String,
) raises:
    for i in range(DST_ROW):
        assert_equal(
            Int(dst.get_typed[Scalar[VT]](i)), SENTINEL, tag + " wrote before"
        )
    assert_equal(
        Int(dst.get_typed[Scalar[VT]](DST_ROW + num)),
        SENTINEL,
        tag + " wrote past the end",
    )
    for i in range(num):
        var row = Int(idx[IDX_START + i])
        assert_equal(
            Int(dst.get_typed[Scalar[VT]](DST_ROW + i)),
            Int(_val[VT](row, col_b)),
            tag + " element " + String(i),
        )


def _tag[IT: DType, VT: DType, nt: Bool](kernel: String, num: Int) -> String:
    return (
        kernel + " IT=" + String(IT) + " VT=" + String(VT) + " nt="
        + String(nt) + " num=" + String(num)
    )


def _nums() -> List[Int]:
    var n = List[Int]()
    n.append(0)
    n.append(1)
    n.append(15)
    n.append(16)
    n.append(17)
    n.append(20)
    n.append(23)
    n.append(99)
    return n^


def _single_unrolled[IT: DType, VT: DType, nt: Bool]() raises:
    var src = _src_col[VT](False)
    var nums = _nums()
    for n in range(len(nums)):
        var num = nums[n]
        var idx = _idx[IT](num)
        var dst = _dst[VT](num)
        var before = join_gather_unrolled_colrows()
        gather_unrolled[IT, VT, nt](src, idx, IDX_START, num, DST_ROW, dst)
        var tag = _tag[IT, VT, nt]("gather_unrolled", num)
        assert_equal(join_gather_unrolled_colrows() - before, num, tag + " count")
        _check_dst[IT, VT](dst, idx, num, False, tag)


def _pair_unrolled[IT: DType, VT: DType, nt: Bool]() raises:
    var src_a = _src_col[VT](False)
    var src_b = _src_col[VT](True)
    var nums = _nums()
    for n in range(len(nums)):
        var num = nums[n]
        var idx = _idx[IT](num)
        var dst_a = _dst[VT](num)
        var dst_b = _dst[VT](num)
        var before = join_gather_unrolled_colrows()
        gather_pair_unrolled[IT, VT, nt](
            src_a, src_b, idx, IDX_START, num, DST_ROW, dst_a, dst_b
        )
        var tag = _tag[IT, VT, nt]("gather_pair_unrolled", num)
        assert_equal(
            join_gather_unrolled_colrows() - before, 2 * num, tag + " count"
        )
        _check_dst[IT, VT](dst_a, idx, num, False, tag + " a")
        _check_dst[IT, VT](dst_b, idx, num, True, tag + " b")


def _single_narrow[IT: DType, VT: DType, nt: Bool]() raises:
    var src = _src_col[VT](False)
    var nums = _nums()
    for n in range(len(nums)):
        var num = nums[n]
        var idx = _idx[IT](num)
        var dst = _dst[VT](num)
        var before = gather_narrow_typed_colrows()
        gather_narrow_rolled[IT, VT, nt](src, idx, IDX_START, num, DST_ROW, dst)
        var tag = _tag[IT, VT, nt]("gather_narrow_rolled", num)
        assert_equal(gather_narrow_typed_colrows() - before, num, tag + " count")
        _check_dst[IT, VT](dst, idx, num, False, tag)


def _pair_narrow[IT: DType, VT: DType, nt: Bool]() raises:
    var src_a = _src_col[VT](False)
    var src_b = _src_col[VT](True)
    var nums = _nums()
    for n in range(len(nums)):
        var num = nums[n]
        var idx = _idx[IT](num)
        var dst_a = _dst[VT](num)
        var dst_b = _dst[VT](num)
        var before = gather_narrow_typed_colrows()
        gather_pair_narrow_rolled[IT, VT, nt](
            src_a, src_b, idx, IDX_START, num, DST_ROW, dst_a, dst_b
        )
        var tag = _tag[IT, VT, nt]("gather_pair_narrow_rolled", num)
        assert_equal(
            gather_narrow_typed_colrows() - before, 2 * num, tag + " count"
        )
        _check_dst[IT, VT](dst_a, idx, num, False, tag + " a")
        _check_dst[IT, VT](dst_b, idx, num, True, tag + " b")


def test_the_unrolled_kernels() raises:
    """Every index type, the 8- and 4-byte payloads, both store kinds.
    MUTANT: in `gather_unrolled`'s unrolled block, `sp[Int(ip[i + k])]`
    changed to `sp[Int(ip[i])]`: element 1 of every block reads row
    `idx[0]`, red from num=20 on."""
    _single_unrolled[DType.int32, DType.int64, False]()
    _single_unrolled[DType.int32, DType.int64, True]()
    _single_unrolled[DType.int, DType.int64, False]()
    _single_unrolled[DType.int, DType.int64, True]()
    _single_unrolled[DType.int32, DType.int32, False]()
    _single_unrolled[DType.int32, DType.int32, True]()
    _single_unrolled[DType.int, DType.int32, False]()
    _single_unrolled[DType.int, DType.int32, True]()


def test_the_unrolled_pair_kernels() raises:
    """The fused pair fills both columns from one index walk.
    MUTANT: `db[i + k] = sb[ix]` changed to `db[i + k] = sa[ix]`: column b
    reads column a's values."""
    _pair_unrolled[DType.int32, DType.int64, False]()
    _pair_unrolled[DType.int32, DType.int64, True]()
    _pair_unrolled[DType.int, DType.int64, False]()
    _pair_unrolled[DType.int, DType.int64, True]()
    _pair_unrolled[DType.int32, DType.int32, False]()
    _pair_unrolled[DType.int32, DType.int32, True]()
    _pair_unrolled[DType.int, DType.int32, False]()
    _pair_unrolled[DType.int, DType.int32, True]()


def test_the_narrow_kernels() raises:
    """Widths 2 and 1, every index type, both store kinds.
    MUTANT: `+ src_col._offset` dropped: every element reads three rows
    early (the first three read the sentinels)."""
    _single_narrow[DType.int32, DType.int16, False]()
    _single_narrow[DType.int32, DType.int16, True]()
    _single_narrow[DType.int, DType.int16, False]()
    _single_narrow[DType.int, DType.int16, True]()
    _single_narrow[DType.int32, DType.int8, False]()
    _single_narrow[DType.int32, DType.int8, True]()
    _single_narrow[DType.int, DType.int8, False]()
    _single_narrow[DType.int, DType.int8, True]()


def test_the_narrow_pair_kernels() raises:
    """MUTANT: the pair kernel's counter note of `2 * num` changed to `num`:
    the count assertion goes red."""
    _pair_narrow[DType.int32, DType.int16, False]()
    _pair_narrow[DType.int32, DType.int16, True]()
    _pair_narrow[DType.int, DType.int16, False]()
    _pair_narrow[DType.int, DType.int16, True]()
    _pair_narrow[DType.int32, DType.int8, False]()
    _pair_narrow[DType.int32, DType.int8, True]()
    _pair_narrow[DType.int, DType.int8, False]()
    _pair_narrow[DType.int, DType.int8, True]()


def main() raises:
    assert_equal(GATHER_PF, 16, "the row counts above are chosen for 16")
    test_the_unrolled_kernels()
    test_the_unrolled_pair_kernels()
    test_the_narrow_kernels()
    test_the_narrow_pair_kernels()
    print("All 4 gather kernel tests passed.")
