# =============================================================================
# record_batch.mojo: the refusals, the zero-row shapes, the Schema/Column
# reconciliation and the two decoding arms of `column_as_string`.
# =============================================================================
#
# Oracles:
#   * a zero-length variable-width array has one offset, 0 (Arrow columnar
#     format: `length + 1` offsets), Int32 for STRING / BINARY / LIST / MAP /
#     LIST_VIEW and Int64 for the LARGE_* layouts; no validity buffer;
#   * a dictionary-encoded array decodes to the array whose slot i is
#     `dictionary[codes[i]]`, null where the codes are null;
#   * a LargeUtf8 array whose data fits Int32 narrows to the Utf8 array with
#     the same slots: the same data bytes, every offset the same number;
#   * every other expectation is the contract the method's docstring states
#     (which refusal names what, which tag disagreement is repaired and which
#     refused).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab


# =============================================================================
# Builders
# =============================================================================


def _i64_col(vals: List[Int], at: ArrowType) -> Column[HeapRegion]:
    var n = len(vals)
    var d = OwnedAlignedBuffer(n * 8)
    for i in range(n):
        d.set_typed[Int64](i, Int64(vals[i]))
    return Column[HeapRegion](
        arrow_type=at,
        data=d^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _validity(n: Int, nulls: List[Int]) -> Optional[Bitmap[HeapRegion]]:
    if len(nulls) == 0:
        return Optional[Bitmap[HeapRegion]](None)
    var bm = Bitmap.create_all_valid(n)
    for j in range(len(nulls)):
        bm.clear(nulls[j])
    return Optional[Bitmap[HeapRegion]](bm^)


def _large_string_col(values: List[String], nulls: List[Int]) -> Column[HeapRegion]:
    var n = len(values)
    var total = 0
    for i in range(n):
        total += len(values[i].as_bytes())
    var offs = OwnedAlignedBuffer((n + 1) * 8)
    var data = OwnedAlignedBuffer(total)
    offs.set_typed[Int64](0, Int64(0))
    var cur = 0
    for i in range(n):
        var bs = values[i].as_bytes()
        for k in range(len(bs)):
            data.write_u8_at(cur + k, bs[k])
        cur += len(bs)
        offs.set_typed[Int64](i + 1, Int64(cur))
    return Column[HeapRegion](
        arrow_type=ArrowType.LARGE_STRING,
        data=data^,
        offsets=offs^,
        validity=_validity(n, nulls),
        length=n,
        null_count=len(nulls),
        offset=0,
    )


def _dict_col(
    entries: List[String], codes: List[Int], nulls: List[Int]
) -> Column[HeapRegion]:
    """A string DICTIONARY column: Int32 codes, dictionary as VarBinary."""
    var n = len(codes)
    var d = OwnedAlignedBuffer(n * 4)
    for i in range(n):
        d.set_typed[Int32](i, Int32(codes[i]))
    var total = 0
    for i in range(len(entries)):
        total += len(entries[i].as_bytes())
    var data = OwnedAlignedBuffer(total)
    var ob = OwnedAlignedBuffer((len(entries) + 1) * 4)
    ob.set_typed[Int32](0, Int32(0))
    var cur = 0
    for i in range(len(entries)):
        var bs = entries[i].as_bytes()
        for k in range(len(bs)):
            data.write_u8_at(cur + k, bs[k])
        cur += len(bs)
        ob.set_typed[Int32](i + 1, Int32(cur))
    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=d^,
        offsets=ob^,
        validity=_validity(n, nulls),
        length=n,
        null_count=len(nulls),
        offset=0,
    )
    col._set_dict_data_from_oab(data^)
    col._dict_size = len(entries)
    return col^


def _one(at: ArrowType) -> Schema:
    return Schema.from_fields_1(Field("c", at, True))


def _two(at: ArrowType) -> Schema:
    return Schema.from_fields_2(Field("a", at, True), Field("b", at, True))


def _three(at: ArrowType) -> Schema:
    return Schema.from_fields_3(
        Field("a", at, True), Field("b", at, True), Field("c", at, True)
    )


def _i64_arr(vals: List[Int]) raises -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        a.set(i, Int64(vals[i]))
    return a^


def _assert_utf8_slots(
    a: StringArray[HeapRegion], expected: List[String], nulls: List[Int]
) raises:
    """Slot i is data[offsets[i] : offsets[i + 1]] (Int32 offsets); null
    slots are those in `nulls`, and only those."""
    assert_equal(a.length, len(expected))
    assert_equal(Int(a.offsets.get_typed[Int32](0)), 0)
    if len(nulls) > 0:
        assert_true(Bool(a.validity), msg="nulls expected but no validity buffer")
    for i in range(len(expected)):
        var is_null = False
        for j in range(len(nulls)):
            if nulls[j] == i:
                is_null = True
        if len(nulls) > 0:
            assert_equal(a.validity.value().test(i), not is_null)
        if is_null:
            continue
        var s = Int(a.offsets.get_typed[Int32](i))
        var e = Int(a.offsets.get_typed[Int32](i + 1))
        var bs = expected[i].as_bytes()
        assert_equal(e - s, len(bs), msg=String("slot ") + String(i))
        for k in range(len(bs)):
            assert_equal(Int(a.data.read_u8_at(s + k)), Int(bs[k]))
    assert_equal(a.null_count, len(nulls))


def _raises_with(msg_part: String, err: Error) raises:
    assert_true(
        String(err).find(msg_part) >= 0,
        msg=String("expected '") + msg_part + "' in: " + String(err),
    )


# =============================================================================
# Zero-row batches
# =============================================================================


def test_empty_from_schema_offsets_per_layout() raises:
    """One zero-length column per field: Int32 offset [0] for STRING /
    BINARY / LIST / MAP / LIST_VIEW, Int64 offset [0] for LARGE_STRING /
    LARGE_BINARY / LARGE_LIST / LARGE_LIST_VIEW, no offsets for INT64, no
    validity anywhere."""
    var sch = SchemaBuilder()
    sch.add_field(Field("s", ArrowType.STRING, True))
    sch.add_field(Field("b", ArrowType.BINARY, True))
    sch.add_field(Field("l", ArrowType.LIST, True))
    sch.add_field(Field("m", ArrowType.MAP, True))
    sch.add_field(Field("lv", ArrowType.LIST_VIEW, True))
    sch.add_field(Field("ls", ArrowType.LARGE_STRING, True))
    sch.add_field(Field("lb", ArrowType.LARGE_BINARY, True))
    sch.add_field(Field("ll", ArrowType.LARGE_LIST, True))
    sch.add_field(Field("llv", ArrowType.LARGE_LIST_VIEW, True))
    sch.add_field(Field("i", ArrowType.INT64, True))
    var rb = RecordBatch.empty_from_schema(sch.build())
    assert_equal(rb.num_rows(), 0)
    assert_equal(rb.num_columns(), 10)
    var widths: List[Int] = [4, 4, 4, 4, 4, 8, 8, 8, 8, 0]
    for i in range(10):
        ref c = rb.column_at(i)
        assert_equal(c._length, 0)
        assert_false(Bool(c._validity))
        assert_true(c.arrow_type == rb.schema.field_arrow_type(i))
        if widths[i] == 0:
            assert_false(Bool(c._offsets))
            continue
        assert_true(Bool(c._offsets), msg=String("no offsets, column ") + String(i))
        assert_equal(c._offsets.value().len(), widths[i])
        for k in range(widths[i]):
            assert_equal(Int(c._offsets.value().read_u8_at(k)), 0)


def test_empty_from_schema_of_no_fields() raises:
    """A schema with no field gives a batch of no column and no row."""
    var rb = RecordBatch.empty_from_schema(Schema())
    assert_equal(rb.num_columns(), 0)
    assert_equal(rb.num_rows(), 0)
    assert_equal(rb.schema.num_columns(), 0)


# =============================================================================
# Constructor refusals: field count and column lengths
# =============================================================================


def test_from_columns_0_refuses_fields() raises:
    try:
        _ = RecordBatch.from_columns_0(_one(ArrowType.INT64))
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_columns_0: schema has 1 fields, expected 0", e)


def test_from_typed_columns_field_counts() raises:
    """Each fixed-arity constructor names its arity and the schema's."""
    try:
        _ = RecordBatch.from_typed_columns_1(
            _two(ArrowType.INT64), _i64_col([1], ArrowType.INT64)
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_typed_columns_1: schema has 2 fields, expected 1", e)
    try:
        _ = RecordBatch.from_typed_columns_2(
            _one(ArrowType.INT64),
            _i64_col([1], ArrowType.INT64),
            _i64_col([2], ArrowType.INT64),
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_typed_columns_2: schema has 1 fields, expected 2", e)
    try:
        _ = RecordBatch.from_typed_columns_3(
            _two(ArrowType.INT64),
            _i64_col([1], ArrowType.INT64),
            _i64_col([2], ArrowType.INT64),
            _i64_col([3], ArrowType.INT64),
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_typed_columns_3: schema has 2 fields, expected 3", e)


def test_from_typed_columns_length_mismatch() raises:
    """Columns of 2 and 1 rows cannot form a batch."""
    try:
        _ = RecordBatch.from_typed_columns_2(
            _two(ArrowType.INT64),
            _i64_col([1, 2], ArrowType.INT64),
            _i64_col([3], ArrowType.INT64),
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_typed_columns_2: column lengths differ: 2 vs 1", e)
    try:
        _ = RecordBatch.from_typed_columns_3(
            _three(ArrowType.INT64),
            _i64_col([1, 2], ArrowType.INT64),
            _i64_col([3, 4], ArrowType.INT64),
            _i64_col([5], ArrowType.INT64),
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_typed_columns_3: column lengths differ", e)
    # The second column disagrees: refused on the first comparison.
    try:
        _ = RecordBatch.from_typed_columns_3(
            _three(ArrowType.INT64),
            _i64_col([1, 2], ArrowType.INT64),
            _i64_col([3], ArrowType.INT64),
            _i64_col([5, 6], ArrowType.INT64),
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_typed_columns_3: column lengths differ", e)


def test_from_columns_2_refusals() raises:
    """The Int64 backward-compatible constructor: field count, then lengths."""
    try:
        _ = RecordBatch.from_columns_2(
            _one(ArrowType.INT64), _i64_arr([1]), _i64_arr([2])
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_columns_2: schema has 1 fields, expected 2", e)
    try:
        _ = RecordBatch.from_columns_2(
            _two(ArrowType.INT64), _i64_arr([1, 2, 3]), _i64_arr([4])
        )
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("from_columns_2: column lengths differ: 3 vs 1", e)
    var ok = RecordBatch.from_columns_2(
        _two(ArrowType.INT64), _i64_arr([7, 8]), _i64_arr([9, 10])
    )
    assert_equal(ok.num_rows(), 2)
    assert_equal(Int(ok.column_value(1, 1)), 10)


# =============================================================================
# Accessor refusals: index out of range
# =============================================================================


def test_accessors_refuse_index_out_of_range() raises:
    """Each accessor refuses index 1 of a one-column batch, and index -1,
    naming itself and the range [0, 1)."""
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.INT64), _i64_col([5], ArrowType.INT64)
    )
    var bad: List[Int] = [1, -1]
    for j in range(2):
        var i = bad[j]
        try:
            _ = rb.column_arrow_type(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_arrow_type: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_by_index(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_by_index: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_value(i, 0)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_value: col_index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_as_dictionary(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_as_dictionary: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_as_boolean(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_as_boolean: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb._column_ref(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("_column_ref: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_as_string(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_as_string: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_as_primitive[DType.int64](i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_as_primitive: index " + String(i) + " out of range [0, 1)", e)
        try:
            _ = rb.column_length(i)
            assert_true(False, msg="expected a refusal")
        except e:
            _raises_with("column_length: index " + String(i) + " out of range [0, 1)", e)
    assert_equal(rb.column_by_index(0), 1)
    assert_equal(rb.column_length(0), 1)
    assert_equal(Int(rb._column_ref(0)[]._data.get_typed[Int64](0)), 5)


# =============================================================================
# Schema/Column tag disagreement
# =============================================================================


def test_same_layout_disagreement_reads_through_schema() raises:
    """A TIMESTAMP_US column under an INT64 field: the same 8-byte layout, so
    `column_arrow_type` answers the field's type and `column_value` repairs
    the tag to it and reads the value."""
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.INT64), _i64_col([41, 42], ArrowType.TIMESTAMP_US)
    )
    assert_true(rb.column_arrow_type(0) == ArrowType.INT64)
    assert_true(rb.column_at(0).arrow_type == ArrowType.TIMESTAMP_US)
    assert_equal(Int(rb.column_value(0, 1)), 42)
    assert_true(rb.column_at(0).arrow_type == ArrowType.INT64)


def test_cross_layout_disagreement_is_refused() raises:
    """A LARGE_STRING column under a STRING field: Int64 against Int32
    offsets. Both the read-only and the repairing accessor refuse, naming
    the field and both types, and the column's tag is left as it was."""
    var v: List[String] = [String("a")]
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.STRING), _large_string_col(v, [])
    )
    try:
        _ = rb.column_arrow_type(0)
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("column_arrow_type: PHYSICAL LAYOUT CONFLICT at column index 0 (name 'c')", e)
        _raises_with("the Column carries large_string", e)
    try:
        _ = rb.column_as_dictionary(0)
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("_ensure_column_type: PHYSICAL LAYOUT CONFLICT", e)
    assert_true(rb.column_at(0).arrow_type == ArrowType.LARGE_STRING)


def test_builder_widens_schema_to_a_real_wide_column() raises:
    """`RecordBatchBuilder.build`: a LARGE_STRING column whose offsets are
    really Int64 under a STRING field, and a LARGE_BINARY one under BINARY,
    widen the field (the column is authoritative about its buffers)."""
    var v: List[String] = [String("xy"), String("")]
    var lb = _large_string_col(v, [])
    lb.arrow_type = ArrowType.LARGE_BINARY
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_large_string_col(v, []))
    b.add_column(lb^)
    var rb = b.build(
        Schema.from_fields_2(
            Field("s", ArrowType.STRING, True), Field("b", ArrowType.BINARY, True)
        )
    )
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.LARGE_STRING)
    assert_true(rb.schema.field_arrow_type(1) == ArrowType.LARGE_BINARY)


# =============================================================================
# column_as_string: dictionary decode and LargeUtf8 narrowing
# =============================================================================


def test_column_as_string_decodes_dictionary() raises:
    """Dictionary ["red", "green", ""] with codes 1, 0, 2, 1: slots green,
    red, "", green, no validity buffer."""
    var d: List[String] = [String("red"), String("green"), String("")]
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.DICTIONARY), _dict_col(d, [1, 0, 2, 1], [])
    )
    var s = rb.column_as_string(0)
    var want: List[String] = [
        String("green"), String("red"), String(""), String("green")
    ]
    _assert_utf8_slots(s, want, [])
    assert_false(Bool(s.validity))


def test_column_as_string_decodes_dictionary_with_nulls() raises:
    """The same dictionary, codes 0, _, 1 with slot 1 null: slots red, null,
    green; the null is in the validity bitmap."""
    var d: List[String] = [String("red"), String("green"), String("")]
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.STRING), _dict_col(d, [0, 0, 1], [1])
    )
    var s = rb.column_as_string(0)
    var want: List[String] = [String("red"), String(""), String("green")]
    _assert_utf8_slots(s, want, [1])


def test_column_as_string_narrows_large_string() raises:
    """LargeUtf8 ["joe", null, null, "mark"] (the format's VarBinary example
    at Int64 offsets) reads as Utf8 with offsets 0, 3, 3, 3, 7, data
    "joemark" and nulls at 1 and 2."""
    var v: List[String] = [
        String("joe"), String(""), String(""), String("mark")
    ]
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.LARGE_STRING), _large_string_col(v, [1, 2])
    )
    var s = rb.column_as_string(0)
    _assert_utf8_slots(s, v, [1, 2])
    var offs: List[Int] = [0, 3, 3, 3, 7]
    for i in range(5):
        assert_equal(Int(s.offsets.get_typed[Int32](i)), offs[i])
    assert_equal(s.data_length, 7)
    assert_equal(Int(s.validity.value().buffer.read_u8_at(0)) & 0x0F, 0b00001001)


def test_column_as_string_narrows_empty_large_string() raises:
    """A LargeUtf8 of two empty values and no nulls: two empty Utf8 slots,
    no data, no validity buffer."""
    var v: List[String] = [String(""), String("")]
    var rb = RecordBatch.from_typed_columns_1(
        _one(ArrowType.LARGE_STRING), _large_string_col(v, [])
    )
    var s = rb.column_as_string(0)
    _assert_utf8_slots(s, v, [])
    assert_equal(s.data_length, 0)
    assert_false(Bool(s.validity))


# =============================================================================
# RecordBatchBuilder.build refusals and reconciliations; a BOOL read
# =============================================================================


def test_builder_refusals_and_empty_build() raises:
    """`build` refuses a schema whose field count differs from its column
    count and columns of different lengths; with no column it builds an empty
    batch carrying the (empty) schema. `with_capacity(0)` is a plain empty
    builder."""
    var b1 = RecordBatchBuilder.with_capacity(1)
    b1.add_column(_i64_col([1], ArrowType.INT64))
    try:
        _ = b1.build(_two(ArrowType.INT64))
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("schema has 2 fields, but builder has 1 columns", e)
    var b2 = RecordBatchBuilder.with_capacity(2)
    b2.add_column(_i64_col([1, 2], ArrowType.INT64))
    b2.add_column(_i64_col([3], ArrowType.INT64))
    try:
        _ = b2.build(_two(ArrowType.INT64))
        assert_true(False, msg="expected a refusal")
    except e:
        _raises_with("column 1 has length 1, expected 2", e)
    var b3 = RecordBatchBuilder.with_capacity(0)
    var rb = b3.build(Schema())
    assert_equal(rb.num_columns(), 0)
    assert_equal(rb.num_rows(), 0)


def test_builder_dictionary_under_large_string_field() raises:
    """A DICTIONARY column under a LARGE_STRING field: the field becomes
    DICTIONARY (the column is authoritative), and the rows decode."""
    var d: List[String] = [String("p"), String("qq")]
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(_dict_col(d, [1, 0], []))
    var rb = b.build(_one(ArrowType.LARGE_STRING))
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.DICTIONARY)
    var s = rb.column_as_string(0)
    var want: List[String] = [String("qq"), String("p")]
    _assert_utf8_slots(s, want, [])


def test_column_as_boolean_reads_bits() raises:
    """A boolean column [T, F, T] (bits LSB first, byte 0b00000101)."""
    var d = OwnedAlignedBuffer(1)
    d.write_u8_at(0, UInt8(0b00000101))
    var c = Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=d^,
        offsets=None,
        validity=None,
        length=3,
        null_count=0,
        offset=0,
    )
    var rb = RecordBatch.from_typed_columns_1(_one(ArrowType.BOOL), c^)
    var a = rb.column_as_boolean(0)
    assert_equal(a.length, 3)
    assert_true(a.get(0))
    assert_false(a.get(1))
    assert_true(a.get(2))


def test_column_as_string_narrows_zero_row_large_string_with_bitmap() raises:
    """A zero-length LargeUtf8 carrying a zero-length validity bitmap
    narrows to a zero-length Utf8 with offsets [0]."""
    var offs = OwnedAlignedBuffer(8)
    offs.set_typed[Int64](0, Int64(0))
    var c = Column[HeapRegion](
        arrow_type=ArrowType.LARGE_STRING,
        data=OwnedAlignedBuffer(0),
        offsets=offs^,
        validity=Optional[Bitmap[HeapRegion]](Bitmap.create_all_valid(0)),
        length=0,
        null_count=0,
        offset=0,
    )
    var rb = RecordBatch.from_typed_columns_1(_one(ArrowType.LARGE_STRING), c^)
    var s = rb.column_as_string(0)
    assert_equal(s.length, 0)
    assert_equal(s.data_length, 0)
    assert_equal(s.null_count, 0)
    assert_equal(Int(s.offsets.get_typed[Int32](0)), 0)


def main() raises:
    var t = TestSuite()
    t.test[test_empty_from_schema_offsets_per_layout]()
    t.test[test_empty_from_schema_of_no_fields]()
    t.test[test_from_columns_0_refuses_fields]()
    t.test[test_from_typed_columns_field_counts]()
    t.test[test_from_typed_columns_length_mismatch]()
    t.test[test_from_columns_2_refusals]()
    t.test[test_accessors_refuse_index_out_of_range]()
    t.test[test_same_layout_disagreement_reads_through_schema]()
    t.test[test_cross_layout_disagreement_is_refused]()
    t.test[test_builder_widens_schema_to_a_real_wide_column]()
    t.test[test_column_as_string_decodes_dictionary]()
    t.test[test_column_as_string_decodes_dictionary_with_nulls]()
    t.test[test_column_as_string_narrows_large_string]()
    t.test[test_column_as_string_narrows_empty_large_string]()
    t.test[test_builder_refusals_and_empty_build]()
    t.test[test_builder_dictionary_under_large_string_field]()
    t.test[test_column_as_boolean_reads_bits]()
    t.test[test_column_as_string_narrows_zero_row_large_string_with_bitmap]()
    t^.run()
