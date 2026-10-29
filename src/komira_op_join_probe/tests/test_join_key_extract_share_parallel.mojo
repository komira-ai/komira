# The string-key extract: a shareable STRING key column is borrowed, not
# copied (`share_as_string` reads the same bytes and aliases the buffers;
# offset windows and non-string columns decline), and its hash wave tiles rows
# exactly, matches a per-row oracle, writes the NULL sentinel only on NULL
# rows, and joins like brute force.

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
    extract_join_key_columns_typed,
    hash_string_keys,
    key_hash_chunk_bounds,
)
from komira_op_join_probe.join_multi_key import _NAN_SENTINEL_BITS
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)


comptime _PAR_ROWS: Int = 70_000

comptime _BUILD_ROWS: Int = 24


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_string_col(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _make_int64_col(values: List[Int]) raises -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](values[i]))
    return Column.from_primitive(arr^)


def _make_nullable_string_array(
    values: List[String], null_mask: List[Bool]
) raises -> StringArray[HeapRegion]:
    """Nullable StringArray built byte-by-byte (no `from_strings_with_validity`
    dependency, so the fixture's layout is fully stated here).
    """
    var n = len(values)
    var total_bytes = 0
    for i in range(n):
        if not null_mask[i]:
            total_bytes += values[i].byte_length()
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var offset = 0
    var null_count = 0
    var bm = Bitmap.create(n)
    for i in range(n):
        if null_mask[i]:
            bm.clear(i)
            null_count += 1
        else:
            bm.set(i)
            var s = values[i]
            var s_len = s.byte_length()
            if s_len > 0:
                var src_view = ByteView(s.unsafe_ptr().bitcast[UInt8](), s_len)
                data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                    0, src_view
                )
            offset += s_len
        offsets_buf.set_typed[Int32](i + 1, Int32(offset))
    offsets_buf.set_length(Int64((n + 1) * int32_size))
    data_buf.set_length(Int64(total_bytes))
    return StringArray[HeapRegion](
        offsets=offsets_buf^,
        data=data_buf^,
        validity=bm^,
        length=n,
        data_length=total_bytes,
        null_count=null_count,
    )


def _column_over_shared(
    imm sa: StringArray[HeapRegion], arrow_type: ArrowType, offset: Int
) raises -> Column[HeapRegion]:
    """A Column whose buffers ALIAS `sa`'s (Arc refcount bump, no copy)."""
    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=sa.data.share(),
        offsets=Optional[SharedAlignedBuffer[HeapRegion]](sa.offsets.share()),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=sa.length - offset,
        null_count=0,
        offset=offset,
    )


def _key_strings(n: Int) -> List[String]:
    """Row r -> a distinct, variable-length string that ENCODES r."""
    var out = List[String]()
    for r in range(n):
        var s = String("k-") + String(r)
        var pad = r % 13
        for _ in range(pad):
            s += "x"
        out.append(s^)
    return out^


def test_share_as_string_reads_identically_to_as_string() raises:
    """Every element, every length, and the null mask must match the copy."""
    var vals: List[String] = [
        "alpha", "", "éè-accented", "z", "", "the-longest-key-here",
    ]
    var mask: List[Bool] = [False, False, False, True, False, False]
    var sa = _make_nullable_string_array(vals, mask)
    var col = Column.from_string(sa^)

    var copied = col.as_string()
    var shared = col.share_as_string()

    assert_equal(shared.length, copied.length, "length")
    assert_equal(shared.data_length, copied.data_length, "data_length")
    assert_equal(shared.null_count, copied.null_count, "null_count")
    for i in range(copied.length):
        assert_equal(
            shared.is_null(i), copied.is_null(i), "validity bit differs"
        )
        if not copied.is_null(i):
            assert_equal(
                shared.get(i), copied.get(i), "string value differs at a row"
            )
            assert_equal(
                shared.get_length(i),
                copied.get_length(i),
                "string byte length differs at a row",
            )
    assert_true(copied.length == 6 and copied.data_length > 0)


def test_share_as_string_on_zero_rows() raises:
    """A zero-row STRING column shares without touching `offsets[length]` past
    its own buffer (the `data_length = offsets[_length]` read is at index 0).
    """
    var vals = List[String]()
    var sa = StringArray.from_strings(vals)
    var col = Column.from_string(sa^)
    var shared = col.share_as_string()
    assert_equal(shared.length, 0, "zero-row length")
    assert_equal(shared.data_length, 0, "zero-row data_length")


def test_share_as_string_aliases_and_as_string_copies() raises:
    """`share_as_string` aliases the column's buffers; `as_string` copies."""
    var vals: List[String] = ["AAAA", "BBBB", "CCCC"]
    var sa = StringArray.from_strings(vals)
    var data_alias = sa.data.share()  # third owner of the same bytes
    var col = _column_over_shared(sa, ArrowType.STRING, 0)

    var copied = col.as_string()
    var shared = col.share_as_string()
    assert_equal(copied.get(0), String("AAAA"), "pre-mutation copy")
    assert_equal(shared.get(0), String("AAAA"), "pre-mutation share")

    data_alias.write_u8_at(0, UInt8(ord("Z")))

    assert_equal(
        shared.get(0),
        String("ZAAA"),
        "share_as_string did NOT alias the source buffer -- it copied. The"
        " whole point of EXTRACT-SHARE is that the 1,119,993,445-byte probe"
        " key allocation is gone; if this reads 'AAAA' the copy is back.",
    )
    assert_equal(
        copied.get(0),
        String("AAAA"),
        "as_string() is no longer copying -- it must stay the owning entry."
        " Callers that mutate an as_string() result would start writing"
        " through to the source column.",
    )
    _ = sa^
    _ = data_alias^


def test_can_share_declines_non_string_and_offset_windows() raises:
    """`can_share_as_string()` must be FALSE wherever `as_string()`'s bytes and
    a share's bytes would differ, and `share_as_string()` must RAISE there.
    """
    var ints: List[Int] = [1, 2, 3]
    var icol = _make_int64_col(ints)
    assert_false(
        icol.can_share_as_string(), "INT64 column claimed to be shareable"
    )
    var i_raised = False
    try:
        _ = icol.share_as_string()
    except:
        i_raised = True
    assert_true(i_raised, "share_as_string on an INT64 column must raise")

    var vals: List[String] = ["AA", "BB", "CC"]
    var sa = StringArray.from_strings(vals)
    var windowed = _column_over_shared(sa, ArrowType.STRING, 1)
    assert_false(
        windowed.can_share_as_string(),
        "a STRING column with _offset > 0 claimed to be shareable -- a share"
        " would read a different window than as_string() does.",
    )
    var w_raised = False
    try:
        _ = windowed.share_as_string()
    except:
        w_raised = True
    assert_true(w_raised, "share_as_string on an _offset > 0 column must raise")

    var plain = _column_over_shared(sa, ArrowType.STRING, 0)
    assert_true(
        plain.can_share_as_string(),
        "the ordinary _offset == 0 STRING column must be shareable -- without"
        " this control, a gate stuck at False passes every assertion above.",
    )
    _ = sa^


def test_key_hash_chunk_bounds_tile_exactly() raises:
    """Monotone, starts at 0, ends at n, and every row is in exactly one chunk."""
    var sizes: List[Int] = [
        0, 1, 2, 4095, 4096, 65535, 65536, 65537, 70000, 1_000_000,
    ]
    for si in range(len(sizes)):
        var n = sizes[si]
        var b = key_hash_chunk_bounds(n)
        assert_true(len(b) >= 1, "bounds must always contain at least 0")
        assert_equal(b[0], 0, "bounds must start at 0")
        if n == 0:
            assert_equal(len(b), 1, "zero rows -> no chunks")
            continue
        assert_equal(b[len(b) - 1], n, "bounds must end at n")
        var covered = 0
        for c in range(len(b) - 1):
            assert_true(
                b[c + 1] > b[c],
                "a chunk bound was not strictly increasing -- an EMPTY or"
                " NEGATIVE chunk range",
            )
            covered += b[c + 1] - b[c]
        assert_equal(
            covered, n, "the chunks do not cover exactly n rows"
        )
        if n < 65536:
            assert_equal(
                len(b) - 1, 1, "below the row gate the tiling must be 1 chunk"
            )
        else:
            assert_true(
                len(b) - 1 >= 2,
                "at or above the row gate the tiling must admit a fork -- 1"
                " chunk runs inline and the wave would never dispatch.",
            )


def test_parallel_key_hash_matches_independent_per_row_oracle() raises:
    """The parallel key hash equals a per-row oracle, across chunk boundaries."""
    var vals = _key_strings(_PAR_ROWS)
    var sa = StringArray.from_strings(vals)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var slots = hash_string_keys[
        origin_of(sa), True, LocalDispatcher[NoopSink], origin_of(disp)
    ](sa, Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
        Pointer(to=disp)
    ))
    rt.shutdown()

    assert_equal(slots.length, _PAR_ROWS, "slot count != row count")

    var bounds = key_hash_chunk_bounds(_PAR_ROWS)
    assert_true(
        len(bounds) - 1 >= 2,
        "the fixture tiled to one chunk -- raise _PAR_ROWS above"
        " _KEYHASH_MIN_PARALLEL_ROWS or this leg is vacuous.",
    )

    var probes = List[Int]()
    for c in range(len(bounds)):
        var b = bounds[c]
        if b - 1 >= 0:
            probes.append(b - 1)
        if b < _PAR_ROWS:
            probes.append(b)
    var r = 0
    while r < _PAR_ROWS:
        probes.append(r)
        r += 4409  # coprime-ish stride, lands off every chunk boundary
    probes.append(_PAR_ROWS - 1)

    for pi in range(len(probes)):
        var row = probes[pi]
        var one: List[String] = [vals[row]]
        var one_slot = _hash_serial(one)
        assert_equal(
            Int64(slots.get(row)),
            one_slot[0],
            "the parallel wave put the wrong hash in a row's slot -- the"
            " string at that row hashes to a different value when hashed"
            " alone, so a chunk wrote outside its own range or its bounds are"
            " off by one.",
        )

    var seen_a = slots.get(0)
    var seen_b = slots.get(_PAR_ROWS // 2)
    var seen_c = slots.get(_PAR_ROWS - 1)
    assert_true(
        seen_a != seen_b and seen_b != seen_c and seen_a != seen_c,
        "three distinct keys produced equal hash slots -- a chunk left its"
        " range unwritten (allocate() memory) or wrote a constant.",
    )
    _ = sa^


def test_parallel_key_hash_marks_nulls_with_the_sentinel() raises:
    """NULL rows must carry the skip sentinel, and non-null rows must not."""
    var n = _PAR_ROWS
    var bounds = key_hash_chunk_bounds(n)
    assert_true(len(bounds) - 1 >= 2, "fixture must tile to >= 2 chunks")
    var edge = bounds[1]

    var vals = _key_strings(n)
    var mask = List[Bool]()
    for _ in range(n):
        mask.append(False)
    var null_rows: List[Int] = [0, edge - 1, edge, edge + 1, n - 1]
    for i in range(len(null_rows)):
        mask[null_rows[i]] = True
    var sa = _make_nullable_string_array(vals, mask)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var slots = hash_string_keys[
        origin_of(sa), True, LocalDispatcher[NoopSink], origin_of(disp)
    ](sa, Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
        Pointer(to=disp)
    ))
    rt.shutdown()

    var sentinel = slots.get(null_rows[0])
    assert_equal(
        sentinel,
        _NAN_SENTINEL_BITS,
        "a NULL-keyed row carries something other than the NULL key slot"
        " value (an empty string's hash, if the validity bitmap is ignored).",
    )
    for i in range(len(null_rows)):
        assert_equal(
            slots.get(null_rows[i]),
            sentinel,
            "a NULL-keyed row did not get the skip sentinel -- it would JOIN,"
            " violating SQL NULL semantics, with no change in row count.",
        )
    var checked = 0
    var r = 1
    while r < n - 1:
        var is_null = False
        for i in range(len(null_rows)):
            if null_rows[i] == r:
                is_null = True
        if not is_null:
            assert_true(
                slots.get(r) != sentinel,
                "a non-null row was marked with the skip sentinel -- real"
                " matches would be silently dropped.",
            )
            checked += 1
        r += 3407
    assert_true(checked > 8, "the non-null sweep must not be vacuous")
    _ = sa^


def _hash_serial(values: List[String]) raises -> List[Int64]:
    """The small-array oracle: the same kernel reached with NO dispatcher, so
    the tiling is one inline chunk and a different offsets layout.
    """
    var b = RecordBatchBuilder()
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    var schema = sb.build()
    b.add_column(_make_string_col(values))
    var batch = b.build(schema^)
    var keys: List[String] = ["k"]
    var bundle = extract_join_key_columns_serial(batch, keys)
    var out = List[Int64]()
    ref arr = bundle.int_keys.value()[0]
    for i in range(arr.length):
        out.append(Int64(arr.get(i)))
    return out^


def test_composite_string_join_pairs_match_brute_force() raises:
    """A composite string join over shared, parallel-hashed keys returns the
    brute-force (build_row, probe_row) pair multiset."""
    var build_keys_s = List[String]()
    var build_vals = List[Int]()
    for i in range(_BUILD_ROWS):
        build_keys_s.append(String("key-") + String(i % 8))
        build_vals.append(i % 3)

    var probe_keys_s = List[String]()
    var probe_vals = List[Int]()
    for r in range(_PAR_ROWS):
        probe_keys_s.append(String("key-") + String(r % 11))
        probe_vals.append(r % 4)

    var bsb = SchemaBuilder()
    bsb.add_field(Field("bs", ArrowType.STRING, False))
    bsb.add_field(Field("bv", ArrowType.INT64, False))
    var bsch = bsb.build()
    var bb = RecordBatchBuilder()
    bb.add_column(_make_string_col(build_keys_s))
    bb.add_column(_make_int64_col(build_vals))
    var build_batch = bb.build(bsch^)

    var psb = SchemaBuilder()
    psb.add_field(Field("ps", ArrowType.STRING, False))
    psb.add_field(Field("pv", ArrowType.INT64, False))
    var psch = psb.build()
    var pb = RecordBatchBuilder()
    pb.add_column(_make_string_col(probe_keys_s))
    pb.add_column(_make_int64_col(probe_vals))
    var probe_batch = pb.build(psch^)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var bk: List[String] = ["bs", "bv"]
    var pk: List[String] = ["ps", "pv"]
    var bkeys = extract_join_key_columns_typed[
        True, LocalDispatcher[NoopSink], origin_of(disp)
    ](
        build_batch, bk,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        ),
    )
    var pkeys = extract_join_key_columns_typed[
        True, LocalDispatcher[NoopSink], origin_of(disp)
    ](
        probe_batch, pk,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        ),
    )
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    builder.probe_inner_into(pkeys, build_matches, probe_matches)
    rt.shutdown()

    var n_expected = 0
    for p in range(_PAR_ROWS):
        for b in range(_BUILD_ROWS):
            if (
                probe_keys_s[p] == build_keys_s[b]
                and probe_vals[p] == build_vals[b]
            ):
                n_expected += 1
    assert_true(
        n_expected > 0,
        "the fixture produced ZERO expected matches -- the leg would pass"
        " vacuously. Check the key overlap between the two key generators.",
    )
    assert_equal(
        len(build_matches),
        n_expected,
        "match COUNT differs from the brute-force reference",
    )
    assert_equal(
        len(probe_matches), len(build_matches), "ragged match lists"
    )

    var got_per_probe = List[Int]()
    for _ in range(_PAR_ROWS):
        got_per_probe.append(0)
    for i in range(len(build_matches)):
        var b = build_matches[i]
        var p = probe_matches[i]
        assert_true(
            b >= 0 and b < _BUILD_ROWS and p >= 0 and p < _PAR_ROWS,
            "an emitted index is out of range",
        )
        assert_equal(
            probe_keys_s[p],
            build_keys_s[b],
            "an emitted pair does not satisfy the STRING key predicate --"
            " the byte-compare validated the wrong row.",
        )
        assert_equal(
            probe_vals[p],
            build_vals[b],
            "an emitted pair does not satisfy the INT64 key predicate",
        )
        got_per_probe[p] += 1
    for p in range(_PAR_ROWS):
        var want = 0
        for b in range(_BUILD_ROWS):
            if (
                probe_keys_s[p] == build_keys_s[b]
                and probe_vals[p] == build_vals[b]
            ):
                want += 1
        assert_equal(
            got_per_probe[p],
            want,
            "a probe row emitted the wrong NUMBER of matches -- dropped or"
            " duplicated matches that a total count can hide.",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_share_as_string_reads_identically_to_as_string]()
    suite.test[test_share_as_string_on_zero_rows]()
    suite.test[test_share_as_string_aliases_and_as_string_copies]()
    suite.test[test_can_share_declines_non_string_and_offset_windows]()
    suite.test[test_key_hash_chunk_bounds_tile_exactly]()
    suite.test[test_parallel_key_hash_matches_independent_per_row_oracle]()
    suite.test[test_parallel_key_hash_marks_nulls_with_the_sentinel]()
    suite.test[test_composite_string_join_pairs_match_brute_force]()
    suite^.run()
