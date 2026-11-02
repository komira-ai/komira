# =============================================================================
# test_log_arg_blob_writer_overflow.mojo — the tag table of a five-argument
# record written when the inline blob is already full, or fills part-way
# through the table.
# =============================================================================
#
# The emit path writes one tag byte per argument with `ArgBlobWriter.append`
# (`@always_inline`), so an emit with five arguments holds five copies of its
# `pos < ARG_INLINE_BYTES` decision. A real emit writes its tags first, from
# position 0, so those five copies only ever take the inline arm; the overflow
# arm of each copy is reached only when the writer already holds bytes. These
# cases give the writer a prefix first: the tag table written after the inline
# blob is full, one that crosses the boundary, and one that ends exactly on it.
# Each asserts the bytes and the counters of the writer, so an append that
# wrote to the wrong side of the boundary, dropped a byte or miscounted fails.
# =============================================================================

from komira_log.engine.log_event_record import (
    LogEventRecord,
    ArgBlobWriter,
    ARG_INLINE_BYTES,
)
from komira_log.log_arg import (
    ArgI64,
    ArgU64,
    ArgStr,
    ArgF64,
    ArgBool,
    LogArg,
    ARG_I64,
    ARG_F64,
    ARG_STR,
    ARG_BOOL,
    ARG_U64,
)

from std.testing import assert_equal, assert_true, assert_false


@fieldwise_init
struct _Written(Copyable, Movable):
    """What a writer holds after a run: the full blob and its counters."""

    var blob: List[UInt8]
    var total: Int
    var inline_len: Int
    var overflowed: Bool


def _fill[o: Origin[mut=True]](mut w: ArgBlobWriter[o], n: Int):
    """Append `n` bytes whose values are their own positions."""
    for i in range(n):
        w.append(UInt8(i))


def _tags_after_prefix[*ArgTs: LogArg](prefix: Int, *args: *ArgTs) -> _Written:
    """A fresh writer given `prefix` bytes (their own positions), then one tag
    byte per argument, as the emit path writes its tag table."""
    var rec = LogEventRecord()
    var w = ArgBlobWriter(rec.arg_blob)
    _fill(w, prefix)
    comptime n = args.__len__()

    comptime for i in range(n):
        w.append(args[i].arg_tag())

    return _Written(
        w.full_blob(), w.total_len(), w.inline_len(), w.overflowed()
    )


def _five_tags_after_prefix(prefix: Int) -> _Written:
    return _tags_after_prefix(
        prefix, ArgI64(1), ArgF64(2.0), ArgStr("s"), ArgBool(True), ArgU64(5)
    )


def test_tag_table_after_the_inline_blob_is_full_all_spills() raises:
    """Five tags written at position 48 all go to the overflow tail: the inline
    bytes stay the 48 filled ones, `overflowed()` is True, `inline_len()` stays
    48, `total_len()` is 53 and the full blob is the 48 inline bytes followed
    by the five tags in argument order."""
    var r = _five_tags_after_prefix(ARG_INLINE_BYTES)
    assert_true(r.overflowed)
    assert_equal(r.inline_len, ARG_INLINE_BYTES)
    assert_equal(r.total, ARG_INLINE_BYTES + 5)
    assert_equal(len(r.blob), ARG_INLINE_BYTES + 5)
    for i in range(ARG_INLINE_BYTES):
        assert_equal(r.blob[i], UInt8(i))
    assert_equal(r.blob[48], ARG_I64)
    assert_equal(r.blob[49], ARG_F64)
    assert_equal(r.blob[50], ARG_STR)
    assert_equal(r.blob[51], ARG_BOOL)
    assert_equal(r.blob[52], ARG_U64)


def test_tag_table_across_the_boundary_splits_inline_and_overflow() raises:
    """Five tags written at position 46: the first two fill the last two inline
    bytes and the other three spill, in order. The inline blob holds positions
    0 to 47 exactly, the tail holds the rest, and the counters say the writer
    overflowed by three."""
    var r = _five_tags_after_prefix(ARG_INLINE_BYTES - 2)
    assert_true(r.overflowed)
    assert_equal(r.inline_len, ARG_INLINE_BYTES)
    assert_equal(r.total, ARG_INLINE_BYTES + 3)
    assert_equal(len(r.blob), ARG_INLINE_BYTES + 3)
    for i in range(ARG_INLINE_BYTES - 2):
        assert_equal(r.blob[i], UInt8(i))
    assert_equal(r.blob[46], ARG_I64)
    assert_equal(r.blob[47], ARG_F64)
    assert_equal(r.blob[48], ARG_STR)
    assert_equal(r.blob[49], ARG_BOOL)
    assert_equal(r.blob[50], ARG_U64)


def test_tag_table_that_ends_exactly_at_the_boundary_does_not_overflow() raises:
    """Five tags written at position 43 end at position 48: every byte is
    inline, `overflowed()` is False (it is true only past 48) and the full blob
    is exactly the 48 inline bytes."""
    var r = _five_tags_after_prefix(ARG_INLINE_BYTES - 5)
    assert_false(r.overflowed)
    assert_equal(r.inline_len, ARG_INLINE_BYTES)
    assert_equal(r.total, ARG_INLINE_BYTES)
    assert_equal(len(r.blob), ARG_INLINE_BYTES)
    assert_equal(r.blob[43], ARG_I64)
    assert_equal(r.blob[44], ARG_F64)
    assert_equal(r.blob[45], ARG_STR)
    assert_equal(r.blob[46], ARG_BOOL)
    assert_equal(r.blob[47], ARG_U64)


def main() raises:
    test_tag_table_after_the_inline_blob_is_full_all_spills()
    test_tag_table_across_the_boundary_splits_inline_and_overflow()
    test_tag_table_that_ends_exactly_at_the_boundary_does_not_overflow()
    print("test_log_arg_blob_writer_overflow: OK")
