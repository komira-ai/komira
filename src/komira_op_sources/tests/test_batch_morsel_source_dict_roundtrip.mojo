# =============================================================================
# BatchMorselSource DICTIONARY round-trip test (Phase 5d-A)
# =============================================================================
#
# Hazard being guarded: silent DICTIONARY -> flat fallback in
# split_record_batch. Prior to Phase 5d-A, _slice_column routed DICTIONARY
# columns to an 8-byte fixed-width memcpy which (a) read past the int32
# index buffer and (b) dropped _dict_data / _dict_size -- the downstream
# consumer then raised "Column.as_dictionary: missing dictionary data"
# or silently fell back to flat string hashing in dict-aware agg strategy
# selection. See project_unfuse_phase5d_review.md hazard #1.
#
# Test construction:
#   1. Build a single-column DICTIONARY RecordBatch of N rows with a
#      known dict payload (4 unique strings) and a known index pattern.
#   2. Register it in a BatchMorselSource with a morsel_rows value that
#      forces multiple morsels (intra-batch slicing exercise).
#   3. Drain every morsel. For each column returned, assert:
#        (a) arrow_type is still DICTIONARY (schema tag matches --
#            the batch_morsel_source hazard-#1 guard would raise
#            otherwise),
#        (b) dict_size matches the source dict,
#        (c) resolving each row via the index reproduces the original
#            string, byte-equal.
#   4. End-of-stream returns None.
#
# Fixture is in-memory; no Parquet file required.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)

from komira_op_sources.batch_morsel_source import BatchMorselSource
from komira_buffer.heap_region import HeapRegion


# ---------------------------------------------------------------------------
# Fixture helpers (same shapes as test_dict_preservation_combine.mojo)
# ---------------------------------------------------------------------------


def _mk_string_array(values: List[String]) raises -> StringArray[HeapRegion]:
    comptime int32_size = size_of[Int32]()
    var n = len(values)
    var offs = OwnedAlignedBuffer((n + 1) * int32_size)
    var offs_ptr = offs.view_typed_ro[DType.int32]()
    (offs_ptr + 0)[] = Int32(0)
    var total = 0
    for i in range(n):
        total += values[i].byte_length()
        (offs_ptr + i + 1)[] = Int32(total)
    offs.set_length(Int64((n + 1) * int32_size))


    var data = OwnedAlignedBuffer(max(total, 1))
    var w = 0
    for i in range(n):
        var s = values[i]
        var slen = s.byte_length()
        if slen > 0:
            unsafe_memcpy(
                dest=data.view_typed_mut[DType.uint8]() + w,
                src=s.unsafe_ptr(),
                count=slen,
            )
        w += slen
    data.set_length(Int64(total))

    return StringArray[HeapRegion](offs^, data^, None, n, total, 0)


def _mk_dict_batch(
    dict_values: List[String],
    indices: List[Int32],
) raises -> RecordBatch:
    """Build a 1-column RecordBatch of DICTIONARY type."""
    comptime int32_size = size_of[Int32]()
    var dict_arr = _mk_string_array(dict_values)
    var n = len(indices)
    var idx_buf = OwnedAlignedBuffer(max(n * int32_size, 1))
    var idx_ptr = idx_buf.view_typed_ro[DType.int32]()
    for i in range(n):
        (idx_ptr + i)[] = indices[i]
    idx_buf.set_length(Int64(n * int32_size))

    var idx_arr = PrimitiveArray[DType.int32](idx_buf^, n, None, 0, 0)
    var sda = StringDictionaryArray(idx_arr^, dict_arr^, n)

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.DICTIONARY, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_dictionary(sda))
    return b.build(sb.build())


def _resolve_col_row(ref c: Column[HeapRegion], row: Int) raises -> String:
    """Resolve a single row of a DICTIONARY column back to its string.

    Honors `_offset` (): the
    BatchMorselSource split zero-copy-slices the dict column, so a mid-stream
    morsel carries `_offset > 0` and the int32 CODE for logical row `row` lives
    at code-buffer position `_offset + row` (like `string_dict_code_at`). The
    dict payload (`_offsets` / `_dict_data`) is addressed by the resolved CODE,
    NOT by `_offset`, so it is read whole."""
    var idx_ptr = c._data.view_typed_ro[DType.int32]()
    var offs_ptr = c._offsets.value().view_typed_ro[DType.int32]()
    var data_ptr = c._dict_data.value().view_typed_ro[DType.uint8]()
    var k = Int((idx_ptr + c._offset + row)[])
    var s = Int((offs_ptr + k)[])
    var e = Int((offs_ptr + k + 1)[])
    var out = String()
    for i in range(s, e):
        out += chr(Int((data_ptr + i)[]))
    return out


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_batch_morsel_source_preserves_dictionary() raises:
    """Multi-morsel drain must preserve DICTIONARY type + resolvable payload."""
    # 12 rows across 4 unique strings -- index pattern chosen so every
    # morsel slice (with morsel_rows=5) covers multiple dict keys.
    var dict_values = List[String]()
    dict_values.append(String("alpha"))
    dict_values.append(String("beta"))
    dict_values.append(String("gamma"))
    dict_values.append(String("delta"))

    var indices = List[Int32]()
    # 12 rows: [0,1,2,3, 0,1,2,3, 0,1,2,3]
    for _ in range(3):
        indices.append(Int32(0))
        indices.append(Int32(1))
        indices.append(Int32(2))
        indices.append(Int32(3))

    # Oracle: materialise expected string per row before moving batch.
    var expected = List[String]()
    for i in range(len(indices)):
        expected.append(dict_values[Int(indices[i])])

    var batch = _mk_dict_batch(dict_values, indices)
    var total_rows = batch.num_rows()

    # morsel_rows=5 => 3 morsels (5, 5, 2). Forces intra-batch slice.
    var src = BatchMorselSource(batch^, 5)

    # Drain every morsel in partition_id order. Because the source is
    # single-threaded here, fetch_add allocates contiguous partition_ids;
    # we pull until None.
    var seen_rows = 0
    var morsel_count = 0
    var check_ptr = 0  # cursor into expected[]
    while True:
        var m_opt = src.next_morsel(0)
        if not m_opt:
            break
        var m = m_opt.take()
        if m.batch.num_columns() != 1:
            raise Error("expected 1 column, got " + String(m.batch.num_columns()))

        ref col = m.batch.column_at(0)
        # (a) schema tag survives slicing.
        if col.arrow_type != ArrowType.DICTIONARY:
            raise Error(
                "DICTIONARY preservation lost: morsel "
                + String(morsel_count)
                + " column arrow_type != DICTIONARY"
            )
        # (b) dict_size preserved.
        if col._dict_size != len(dict_values):
            raise Error(
                "dict_size mismatch: got "
                + String(col._dict_size)
                + " expected "
                + String(len(dict_values))
            )
        # (c) per-row byte-equal resolve against oracle.
        var rows = col._length
        for r in range(rows):
            var got = _resolve_col_row(col, r)
            var want = expected[check_ptr + r]
            if got != want:
                raise Error(
                    "row "
                    + String(check_ptr + r)
                    + " resolve mismatch: got '"
                    + got
                    + "' want '"
                    + want
                    + "'"
                )
        # (d) DIFFERENTIAL: `as_dictionary()` must reconstruct the SAME strings
        # as the offset-honoring raw resolve above (). This morsel column may carry `_offset > 0`; pre-fix
        # `as_dictionary()` copied codes from position 0 (ignoring `_offset`), so
        # the round-tripped column resolved the WRONG strings on a mid-stream
        # morsel — the real corruption reachable via `dict_clone()`. A fresh
        # (offset==0) column round-tripped through `as_dictionary()` must resolve
        # byte-identically. FAILS ON pre-fix code.
        var rt_col = Column.from_dictionary(col.as_dictionary())
        for r in range(rows):
            var raw = _resolve_col_row(col, r)  # offset-honoring on the morsel
            var via_ad = _resolve_col_row(rt_col, r)  # offset==0 round-trip
            if raw != via_ad:
                raise Error(
                    "as_dictionary offset mismatch at row "
                    + String(check_ptr + r)
                    + ": raw='"
                    + raw
                    + "' via_as_dictionary='"
                    + via_ad
                    + "'"
                )
        check_ptr += rows
        seen_rows += rows
        morsel_count += 1

    if seen_rows != total_rows:
        raise Error(
            "row count mismatch after drain: got "
            + String(seen_rows)
            + " expected "
            + String(total_rows)
        )
    if morsel_count < 2:
        raise Error(
            "expected >= 2 morsels to exercise intra-batch slicing, got "
            + String(morsel_count)
        )
    # EOF is sticky.
    var again = src.next_morsel(0)
    if again:
        raise Error("next_morsel returned a value past EOF")


def main() raises:
    test_batch_morsel_source_preserves_dictionary()
    print("PASS: test_batch_morsel_source_preserves_dictionary")
