# =============================================================================
# share_batch — byte equivalence, source-lifetime and mutation-isolation guards
# =============================================================================
#
# `share_batch` (komira_column_kernels.compiler_helpers) is the zero-copy dual
# of `copy_batch`: it rebuilds a RecordBatch whose every column-buffer ALIASES
# the source's Arc-backed bytes (refcount++, no memcpy) instead of deep-copying.
# The cached-scan resolution site `ScanDedupCache.lookup_copy` shares by
# default; the cache takes the switch as its `share_on` argument, and
# `copy_batch` stays its OFF arm, the differential oracle. These tests are the
# byte-equivalence / lifetime correctness guard of the share primitive.
#
# The whole hazard of a share primitive is a missed field (share a
# subset of the ~20 Column fields → latent wrong data or UAF). These tests are
# the guard:
#
#   1. Byte-equivalence oracle (test_share_batch_byte_equiv_dtype_zoo)
#      share_batch(b) == copy_batch(b) cell-for-cell across a dtype zoo
#      (int64 / f64 / string / bool / date32 / decimal128 / dictionary /
#      nullable-int64-with-validity / nullable-string), AND share_batch(b) ==
#      the ORIGINAL b (an INDEPENDENT oracle — b is built from raw input values,
#      not from the copy/share path, so it catches a bug where BOTH copy and
#      share are wrong).
#
#   2. Source-lifetime falsifier (destroy one side, read the other)
#      * test_share_survives_source_destroy — build+share in a helper whose
#        local SOURCE drops on return; churn the allocator; read every cell
#        through the share → must be byte-stable (the Arc keeps the regions
#        alive; a missed refcount would read freed/reused bytes).
#      * test_source_survives_share_destroy — drop the SHARE; the source stays
#        fully readable (the source keeps its own Arc ref).
#      * test_share_of_share_chain — share(share(share(b))); drop the
#        intermediates; the tail still reads correctly (refcount chain).
#
#   3. Mutation isolation (test_share_immutable_under_split_consumer)
#      Run the REAL consumer path (`split_record_batch`, the BatchMorselSource
#      substrate) over a SHARE of a source, then re-read the source — it MUST
#      be unchanged. Proves the consumer treats Arrow buffers as immutable
#      (READ + emit NEW batches), the invariant `share_batch` relies on. A
#      regression to zero-copy-slice + in-place mutation would corrupt the
#      source and fail this.
#
# Audit result: every consumer of a resolved cached-scan batch is read-only —
# `split_record_batch`/`_slice_column` deep-copy, the resident-batch filter
# gathers into a NEW batch, `project_batch_by_names` copies. Plus the zero-copy mmap decode already
# aliases these buffers under PROT_READ. Sharing is therefore SOUND.
#
# Encapsulation: tests use ONLY the public Column / typed-array / batch surface.
# No UnsafePointer, no wildcard origin, no unsafe_from_address.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.bitmap import Bitmap
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import (
    copy_batch,
    project_batch_by_names,
    project_batch_by_names_arm,
    project_batch_by_src_out_pairs,
    project_batch_by_src_out_pairs_arm,
    project_column_share_eligible,
    share_batch,
)
from komira_dispatch_scan.scan_dedup_cache import ScanDedupCache
from komira_morsel.morsel import split_record_batch


# --- shared expected-value helpers (ONE source of truth for build + assert) ---

comptime _N: Int = 6
comptime _DEC_P: Int = 18
comptime _DEC_S: Int = 2


def _exp_i64() -> List[Int64]:
    var v = List[Int64]()
    v.append(10); v.append(20); v.append(30)
    v.append(40); v.append(50); v.append(60)
    return v^


def _exp_f64() -> List[Float64]:
    var v = List[Float64]()
    # all exactly representable → exact bit equality holds through copy/share
    v.append(1.5); v.append(2.5); v.append(-3.25)
    v.append(0.0); v.append(100.125); v.append(-0.5)
    return v^


def _exp_str() -> List[String]:
    var v = List[String]()
    v.append(String("alpha")); v.append(String(""))
    v.append(String("gamma")); v.append(String("delta is a longer string"))
    v.append(String("e")); v.append(String("final"))
    return v^


def _exp_bool() -> List[Bool]:
    var v = List[Bool]()
    v.append(True); v.append(False); v.append(True)
    v.append(True); v.append(False); v.append(False)
    return v^


def _exp_date32() -> List[Int32]:
    var v = List[Int32]()
    v.append(18000); v.append(18001); v.append(0)
    v.append(25000); v.append(-5); v.append(19999)
    return v^


def _exp_dec_phys() -> List[Int]:
    # physical stored integers (set_from_int / get_as_int are self-consistent)
    var v = List[Int]()
    v.append(12345); v.append(-6789); v.append(0)
    v.append(100); v.append(999999); v.append(-1)
    return v^


def _exp_dict_vals() -> List[String]:
    # resolved dictionary values for indices [0,1,2,0,1,2] over ["red","green","blue"]
    var v = List[String]()
    v.append(String("red")); v.append(String("green")); v.append(String("blue"))
    v.append(String("red")); v.append(String("green")); v.append(String("blue"))
    return v^


# nullable int64: rows 1 and 3 are NULL.
def _exp_nint_val() -> List[Int64]:
    var v = List[Int64]()
    v.append(100); v.append(0); v.append(300)
    v.append(0); v.append(500); v.append(600)
    return v^


def _exp_nint_null() -> List[Bool]:
    var v = List[Bool]()
    v.append(False); v.append(True); v.append(False)
    v.append(True); v.append(False); v.append(False)
    return v^


# nullable string: rows 1 and 4 are NULL.
def _exp_nstr_val() -> List[String]:
    var v = List[String]()
    v.append(String("x")); v.append(String("")); v.append(String("zzz"))
    v.append(String("w")); v.append(String("")); v.append(String("vv"))
    return v^


def _exp_nstr_null() -> List[Bool]:
    var v = List[Bool]()
    v.append(False); v.append(True); v.append(False)
    v.append(False); v.append(True); v.append(False)
    return v^


# --- fixture builders ---


def _build_zoo() raises -> RecordBatch:
    """Build the 9-column dtype-zoo RecordBatch (all columns length _N)."""
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()

    # 0: int64
    sb.add_field(Field(String("c_i64"), ArrowType.INT64, False))
    builder.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(_exp_i64())
        )
    )

    # 1: float64
    sb.add_field(Field(String("c_f64"), ArrowType.FLOAT64, False))
    builder.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(_exp_f64())
        )
    )

    # 2: string
    sb.add_field(Field(String("c_str"), ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(_exp_str())))

    # 3: bool
    sb.add_field(Field(String("c_bool"), ArrowType.BOOL, False))
    var bools = _exp_bool()
    var barr = BooleanArray.allocate(_N)
    for i in range(_N):
        barr.set(i, bools[i])
    builder.add_column(Column.from_boolean(barr^))

    # 4: date32 (int32 storage, DATE32 tag)
    sb.add_field(Field(String("c_date"), ArrowType.DATE32, False))
    var date_vals = _exp_date32()
    var date_col = Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(date_vals)
    )
    date_col.arrow_type = ArrowType.DATE32
    builder.add_column(date_col^)

    # 5: decimal128 (p=18, s=2)
    var dec_field = Field(String("c_dec"), ArrowType.DECIMAL128, False)
    dec_field.decimal_precision = _DEC_P
    dec_field.decimal_scale = _DEC_S
    sb.add_field(dec_field)
    var dec_arr = Decimal128Array.allocate(_N, _DEC_P, _DEC_S)
    var dec_phys = _exp_dec_phys()
    for i in range(_N):
        dec_arr.set_from_int(i, dec_phys[i])
    builder.add_column(Column.from_decimal128(dec_arr^))

    # 6: dictionary (string) — schema field STRING; build() reconciles to DICTIONARY
    sb.add_field(Field(String("c_dict"), ArrowType.STRING, False))
    var dict_vals = List[String]()
    dict_vals.append(String("red")); dict_vals.append(String("green"))
    dict_vals.append(String("blue"))
    var dict_idx = List[Int32]()
    dict_idx.append(0); dict_idx.append(1); dict_idx.append(2)
    dict_idx.append(0); dict_idx.append(1); dict_idx.append(2)
    var dict_arr = StringDictionaryArray.from_parts(
        PrimitiveArray[DType.int32].from_list(dict_idx),
        StringArray.from_strings(dict_vals),
    )
    builder.add_column(Column.from_dictionary(dict_arr^))

    # 7: nullable int64 (validity: rows 1,3 null) — built via OAB + Bitmap
    sb.add_field(Field(String("c_ni64"), ArrowType.INT64, True))
    comptime esz = size_of[Int64]()
    var nvals = _exp_nint_val()
    var ndata = OwnedAlignedBuffer(_N * esz)
    for i in range(_N):
        ndata.set_typed[Int64](i, nvals[i])
    ndata.set_length(Int64(_N * esz))
    var nbm = Bitmap.create_all_valid(_N)
    nbm.clear(1)
    nbm.clear(3)
    builder.add_column(
        Column[HeapRegion](
            arrow_type=ArrowType.INT64,
            data=ndata^,
            offsets=Optional[OwnedAlignedBuffer](None),
            validity=Optional[Bitmap[HeapRegion]](nbm^),
            length=_N,
            null_count=2,
            offset=0,
        )
    )

    # 8: nullable string (validity: rows 1,4 null)
    sb.add_field(Field(String("c_nstr"), ArrowType.STRING, True))
    builder.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(
                _exp_nstr_val(), _exp_nstr_null_valid()
            )
        )
    )

    var schema = sb.build()
    return builder.build(schema^)


def _exp_nstr_null_valid() -> List[Bool]:
    # from_strings_with_validity takes a per-row VALID mask (True == real value)
    var nulls = _exp_nstr_null()
    var valid = List[Bool]()
    for i in range(len(nulls)):
        valid.append(not nulls[i])
    return valid^


def _build_simple() raises -> RecordBatch:
    """A split-friendly int64 + string batch for the consumer/cache tests."""
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    builder.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(_exp_i64())
        )
    )
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(_exp_str())))
    var schema = sb.build()
    return builder.build(schema^)


# --- oracle: cell-for-cell equality of two batches across the dtype zoo ---


def _assert_batches_cell_equal(imm x: RecordBatch, imm y: RecordBatch) raises:
    """Assert x and y are cell-for-cell identical across every supported dtype.

    Used both as the SPECIFIED oracle (share == copy) and the INDEPENDENT
    oracle (share == original-input batch).
    """
    assert_equal(x.num_columns(), y.num_columns(), "num_columns mismatch")
    assert_equal(x.num_rows(), y.num_rows(), "num_rows mismatch")
    var n = x.num_rows()
    for c in range(x.num_columns()):
        ref cx = x.column_at(c)
        ref cy = y.column_at(c)
        var at = cx.arrow_type
        assert_equal(
            Int(at.type_id), Int(cy.arrow_type.type_id),
            "col " + String(c) + " arrow_type mismatch",
        )
        if at == ArrowType.INT64:
            var ax = cx.as_primitive[DType.int64]()
            var ay = cy.as_primitive[DType.int64]()
            for i in range(n):
                assert_equal(ax.is_null(i), ay.is_null(i))
                if not ax.is_null(i):
                    assert_equal(ax.get(i), ay.get(i))
        elif at == ArrowType.FLOAT64:
            var ax = cx.as_primitive[DType.float64]()
            var ay = cy.as_primitive[DType.float64]()
            for i in range(n):
                assert_equal(ax.is_null(i), ay.is_null(i))
                if not ax.is_null(i):
                    assert_equal(ax.get(i), ay.get(i))
        elif at == ArrowType.DATE32:
            var ax = cx.as_primitive[DType.int32]()
            var ay = cy.as_primitive[DType.int32]()
            for i in range(n):
                assert_equal(ax.is_null(i), ay.is_null(i))
                if not ax.is_null(i):
                    assert_equal(ax.get(i), ay.get(i))
        elif at == ArrowType.STRING:
            var ax = cx.as_string()
            var ay = cy.as_string()
            for i in range(n):
                assert_equal(ax.is_null(i), ay.is_null(i))
                if not ax.is_null(i):
                    assert_equal(ax.get(i), ay.get(i))
        elif at == ArrowType.BOOL:
            var ax = cx.as_boolean()
            var ay = cy.as_boolean()
            for i in range(n):
                assert_equal(ax.is_null(i), ay.is_null(i))
                if not ax.is_null(i):
                    assert_equal(ax.get(i), ay.get(i))
        elif at == ArrowType.DECIMAL128:
            var ax = cx.as_decimal128()
            var ay = cy.as_decimal128()
            assert_equal(ax.precision, ay.precision, "decimal precision")
            assert_equal(ax.scale, ay.scale, "decimal scale")
            for i in range(n):
                assert_equal(ax.is_null(i), ay.is_null(i))
                if not ax.is_null(i):
                    assert_equal(ax.get_as_int(i), ay.get_as_int(i))
        elif at == ArrowType.DICTIONARY:
            var ax = cx.as_dictionary()
            var ay = cy.as_dictionary()
            for i in range(n):
                assert_equal(ax.get_index(i), ay.get_index(i), "dict index")
                assert_equal(ax.get(i), ay.get(i), "dict value")
        else:
            raise Error("oracle: unhandled arrow_type in col " + String(c))


def _assert_zoo_values(imm b: RecordBatch) raises:
    """Assert `b` matches the KNOWN zoo input values (INDEPENDENT of copy/share).
    """
    assert_equal(b.num_columns(), 9, "zoo num_columns")
    assert_equal(b.num_rows(), _N, "zoo num_rows")

    var i64 = b.column_at(0).as_primitive[DType.int64]()
    var ei64 = _exp_i64()
    for i in range(_N):
        assert_equal(i64.get(i), ei64[i], "i64 row " + String(i))

    var f64 = b.column_at(1).as_primitive[DType.float64]()
    var ef64 = _exp_f64()
    for i in range(_N):
        assert_equal(f64.get(i), ef64[i], "f64 row " + String(i))

    var s = b.column_at(2).as_string()
    var es = _exp_str()
    for i in range(_N):
        assert_equal(s.get(i), es[i], "str row " + String(i))

    var bl = b.column_at(3).as_boolean()
    var ebl = _exp_bool()
    for i in range(_N):
        assert_equal(bl.get(i), ebl[i], "bool row " + String(i))

    var dt = b.column_at(4).as_primitive[DType.int32]()
    var edt = _exp_date32()
    for i in range(_N):
        assert_equal(dt.get(i), edt[i], "date row " + String(i))

    var dc = b.column_at(5).as_decimal128()
    assert_equal(dc.precision, _DEC_P, "decimal precision")
    assert_equal(dc.scale, _DEC_S, "decimal scale")
    var edc = _exp_dec_phys()
    for i in range(_N):
        assert_equal(dc.get_as_int(i), edc[i], "dec row " + String(i))

    var dk = b.column_at(6).as_dictionary()
    var edk = _exp_dict_vals()
    for i in range(_N):
        assert_equal(dk.get(i), edk[i], "dict row " + String(i))

    var ni = b.column_at(7).as_primitive[DType.int64]()
    var eniv = _exp_nint_val()
    var enin = _exp_nint_null()
    for i in range(_N):
        assert_equal(ni.is_null(i), enin[i], "nint null row " + String(i))
        if not enin[i]:
            assert_equal(ni.get(i), eniv[i], "nint val row " + String(i))

    var ns = b.column_at(8).as_string()
    var ensv = _exp_nstr_val()
    var ensn = _exp_nstr_null()
    for i in range(_N):
        assert_equal(ns.is_null(i), ensn[i], "nstr null row " + String(i))
        if not ensn[i]:
            assert_equal(ns.get(i), ensv[i], "nstr val row " + String(i))


# --- lifetime helper: build + share where the SOURCE drops on return ---


def _build_and_share_zoo() raises -> RecordBatch:
    """Build a zoo batch as a LOCAL, share it, and return ONLY the share. The
    local source drops on return — the shared batch's Arc must keep the
    underlying regions alive."""
    var src = _build_zoo()
    var shared = share_batch(src)
    return shared^  # `src` drops here; `shared` survives via refcount


# =============================================================================
# Tests
# =============================================================================


def test_share_batch_byte_equiv_dtype_zoo() raises:
    """share_batch(b) == copy_batch(b) == b, cell-for-cell, across the zoo."""
    var b = _build_zoo()
    var c = copy_batch(b)
    var s = share_batch(b)
    # SPECIFIED oracle: share == copy.
    _assert_batches_cell_equal(s, c)
    # INDEPENDENT oracle: share == the original input batch.
    _assert_batches_cell_equal(s, b)
    # Sanity: copy == original (proves the fixture + copy_batch itself).
    _assert_batches_cell_equal(c, b)
    # And the explicit known-value check on the share.
    _assert_zoo_values(s)


def test_share_batch_empty_and_zero_row() raises:
    """Zero-column and zero-row batches share == copy."""
    # Zero columns.
    var empty = RecordBatch()
    var s_empty = share_batch(empty)
    assert_equal(s_empty.num_columns(), 0, "empty share num_columns")

    # Zero rows, non-empty schema (int64 + string), share preserves the schema.
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    builder.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(List[Int64]())
        )
    )
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(List[String]())))
    var zr = builder.build(sb.build())
    var s_zr = share_batch(zr)
    var c_zr = copy_batch(zr)
    assert_equal(s_zr.num_columns(), 2, "zero-row share num_columns")
    assert_equal(s_zr.num_rows(), 0, "zero-row share num_rows")
    assert_equal(s_zr.num_columns(), c_zr.num_columns(), "zero-row share vs copy cols")
    assert_equal(s_zr.num_rows(), c_zr.num_rows(), "zero-row share vs copy rows")


def test_share_survives_source_destroy() raises:
    """Lifetime: destroy the SOURCE, churn the allocator, read the share — stable."""
    var shared = _build_and_share_zoo()  # source dropped inside the helper
    # Churn tcmalloc: allocate + drop several zoo batches to encourage byte
    # reuse of the freed source's struct/region bytes. A missed Arc refcount
    # would let this overwrite the shared column bytes.
    for _ in range(8):
        var churn = _build_zoo()
        _ = churn^
    # The share must still read the KNOWN values byte-for-byte.
    _assert_zoo_values(shared)


def test_source_survives_share_destroy() raises:
    """Lifetime, reversed: drop the SHARE; the source stays fully readable."""
    var src = _build_zoo()
    var sh = share_batch(src)
    _ = sh^  # drop the share; the source keeps its own Arc ref
    # Churn, then assert the source is intact.
    for _ in range(4):
        var churn = _build_zoo()
        _ = churn^
    _assert_zoo_values(src)


def test_share_of_share_chain() raises:
    """Lifetime through a refcount chain: share(share(share(b))); drop intermediates."""
    var src = _build_zoo()
    var s1 = share_batch(src)
    var s2 = share_batch(s1)
    _ = src^  # drop the original; s1/s2 keep the regions alive
    var s3 = share_batch(s2)
    _ = s1^
    _ = s2^  # drop both intermediates; only s3 remains
    for _ in range(4):
        var churn = _build_zoo()
        _ = churn^
    _assert_zoo_values(s3)


def test_share_immutable_under_split_consumer() raises:
    """mutation-isolation: run the REAL split consumer over a SHARE of a source;
    the source must be byte-stable afterward (consumer is read-only)."""
    var src = _build_simple()
    var s_split = share_batch(src)  # aliases src's buffers
    # split_record_batch consumes its input and READS src's buffers into new
    # per-morsel columns; it must not write through the shared buffers.
    var morsels = split_record_batch(s_split^, 2)
    assert_true(len(morsels) > 0, "split produced no morsels")
    _ = morsels^  # drop the morsels
    # Re-read the source — every cell must be unchanged.
    var i64 = src.column_at(0).as_primitive[DType.int64]()
    var ei64 = _exp_i64()
    var strc = src.column_at(1).as_string()
    var es = _exp_str()
    for i in range(_N):
        assert_equal(i64.get(i), ei64[i], "src i64 corrupted at row " + String(i))
        assert_equal(strc.get(i), es[i], "src str corrupted at row " + String(i))


def test_share_preserves_slice_offset() raises:
    """A SLICED column (`_offset != 0`): share PRESERVES the offset (aliases the
    whole buffer), copy_batch REBASES it (offset=0) — both must read the SAME
    logical cells. Guards the `_offset` field of the share (a dropped offset
    would read the wrong physical rows)."""
    comptime esz = size_of[Int64]()
    # 8 physical int64s [0..8); the column views logical rows [2..8).
    var data = OwnedAlignedBuffer(8 * esz)
    for i in range(8):
        data.set_typed[Int64](i, Int64(i))
    data.set_length(Int64(8 * esz))
    var col = Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=data^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=6,
        null_count=0,
        offset=2,
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("sliced"), ArrowType.INT64, False))
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var b = builder.build(sb.build())

    var s = share_batch(b)
    var c = copy_batch(b)
    # share == copy, cell-for-cell.
    _assert_batches_cell_equal(s, c)
    # Independent: logical rows [2..8) == [2,3,4,5,6,7].
    var sa = s.column_at(0).as_primitive[DType.int64]()
    for i in range(6):
        assert_equal(sa.get(i), Int64(i + 2), "sliced share row " + String(i))


def test_scan_dedup_cache_lookup_roundtrip() raises:
    """Guard the scan-dedup resolution site: ScanDedupCache.insert + lookup_copy
    round-trips the cached batch cell-for-cell (through the default share
    arm)."""
    var cache = ScanDedupCache()
    var b = _build_zoo()
    cache.insert(String("key0"), copy_batch(b))  # cache owns a copy
    assert_true(cache.has(String("key0")), "cache missing inserted key")
    var got = cache.lookup_copy(String("key0"))
    assert_true(got.__bool__(), "lookup_copy returned None on a present key")
    var g = got.take()
    # The resolved batch equals the input.
    _assert_batches_cell_equal(g, b)
    _assert_zoo_values(g)
    # A miss returns None.
    var miss = cache.lookup_copy(String("absent"))
    assert_false(miss.__bool__(), "lookup_copy on absent key should be None")


# =============================================================================
# Projection sharing — `project_batch_by_src_out_pairs` shares instead of copying
# =============================================================================
#
# The pure-col-ref SELECT-and-RENAME primitive Arc-SHARES its carried
# columns wherever `project_column_share_eligible` holds. These tests guard
# that sharing. `share_on=False` selects the unconditional `copy_column` arm,
# so the two arms are driven here through `share_on` explicitly — one process
# runs both.


def _proj_names(imm names: List[String]) -> List[String]:
    var v = List[String]()
    for i in range(len(names)):
        v.append(names[i])
    return v^


def _zoo_all_names() -> List[String]:
    var v = List[String]()
    v.append(String("c_i64")); v.append(String("c_f64"))
    v.append(String("c_str")); v.append(String("c_bool"))
    v.append(String("c_date")); v.append(String("c_dec"))
    v.append(String("c_dict")); v.append(String("c_ni64"))
    v.append(String("c_nstr"))
    return v^


def _zoo_renamed_names() -> List[String]:
    """Every output RENAMED — the rename-only shape, where the only semantic content of
    the projection is the relabel."""
    var src = _zoo_all_names()
    var v = List[String]()
    for i in range(len(src)):
        v.append(src[i] + "_out")
    return v^


def test_project_share_equals_copy_dtype_zoo() raises:
    """THE ORACLE. `project_batch_by_src_out_pairs` with sharing ON == with
    sharing OFF (the `copy_column` arm), cell-for-cell, over the full
    dtype zoo under a rename of every column. Also equals the ORIGINAL batch's
    known values — an INDEPENDENT oracle that would catch both arms being
    wrong together."""
    var b = _build_zoo()
    var srcs = _zoo_all_names()
    var outs = _zoo_renamed_names()
    var shared = project_batch_by_src_out_pairs(
        b, _proj_names(srcs), _proj_names(outs)
    )
    var copied = project_batch_by_src_out_pairs_arm(
        b, _proj_names(srcs), _proj_names(outs), False
    )
    _assert_batches_cell_equal(shared, copied)
    # Column ORDER is preserved, so the zoo value oracle applies directly.
    _assert_zoo_values(shared)
    # The RENAME actually happened (the projection's only semantic content).
    for i in range(len(outs)):
        assert_equal(
            shared.schema.field_name(i), outs[i],
            "output field " + String(i) + " not renamed",
        )
    # ...and the eligibility gate FIRED on every zoo column, so this test is
    # exercising the share arm and not silently re-running the copy arm. A
    # share arm that never fires is how a differential test goes vacuous.
    for c in range(b.num_columns()):
        assert_true(
            project_column_share_eligible(b, c),
            "zoo column " + String(c) + " unexpectedly ineligible — the share"
            " arm did not fire and this test is vacuous",
        )


def test_project_share_declines_sliced_string_column() raises:
    """THE FALSIFIER — the blast-radius case the gate exists for.

    `Column.share()` PRESERVES `_offset`, and plain STRING / BINARY accessors
    IGNORE `_offset` (`Column.supports_zero_copy_slice`'s note). So sharing a
    ROW-SLICED string column reads from physical row 0 — a SILENT WRONG ANSWER,
    not a crash.

    This test asserts three things, in the order that makes the gate's
    necessity a CHECKED fact rather than a claim:
      1. a raw `share()` of the sliced column DOES read the wrong cells (so the
         hazard is real on this build, not hypothetical);
      2. `project_column_share_eligible` therefore returns False;
      3. the projection consequently returns the CORRECT (rebased) cells with
         sharing on."""
    comptime i32sz = size_of[Int32]()
    # 6 physical strings; the column views logical rows [2..6) == 4 rows.
    var all_vals = List[String]()
    all_vals.append(String("row0")); all_vals.append(String("row1"))
    all_vals.append(String("row2")); all_vals.append(String("row3"))
    all_vals.append(String("row4")); all_vals.append(String("row5"))
    var flat = String("")
    var offs = OwnedAlignedBuffer((6 + 1) * i32sz)
    var acc = 0
    offs.set_typed[Int32](0, Int32(0))
    for i in range(6):
        flat += all_vals[i]
        acc += all_vals[i].byte_length()
        offs.set_typed[Int32](i + 1, Int32(acc))
    offs.set_length(Int64((6 + 1) * i32sz))
    var fb = flat.as_bytes()
    var data = OwnedAlignedBuffer(len(fb))
    for i in range(len(fb)):
        data.set_typed[UInt8](i, fb[i])
    data.set_length(Int64(len(fb)))

    var col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data^,
        offsets=Optional[OwnedAlignedBuffer](offs^),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=4,
        null_count=0,
        offset=2,
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var b = builder.build(sb.build())
    assert_equal(b.num_rows(), 4, "sliced string batch num_rows")

    # (1) A RAW share reads the WRONG cells — rows 0..3, not 2..5.
    var raw_shared = b.column_at(0).share()
    var raw_arr = raw_shared.as_string()
    assert_equal(
        raw_arr.get(0), String("row0"),
        "premise broken: a raw share() of a sliced STRING column no longer"
        " reads from physical row 0 — re-derive the gate before trusting it",
    )

    # (2) So the gate must decline it.
    assert_false(
        project_column_share_eligible(b, 0),
        "sliced STRING column must NOT be share-eligible",
    )

    # (3) And the projection returns the CORRECT logical window either way.
    var srcs = List[String](); srcs.append(String("s"))
    var outs = List[String](); outs.append(String("s_out"))
    var shared = project_batch_by_src_out_pairs(
        b, _proj_names(srcs), _proj_names(outs)
    )
    var copied = project_batch_by_src_out_pairs_arm(
        b, _proj_names(srcs), _proj_names(outs), False
    )
    _assert_batches_cell_equal(shared, copied)
    var got = shared.column_at(0).as_string()
    for i in range(4):
        assert_equal(
            got.get(i), all_vals[i + 2],
            "sliced-string projection row " + String(i),
        )


def _project_zoo_and_drop_source() raises -> RecordBatch:
    """Build the zoo as a LOCAL, project it (sharing), return ONLY the
    projection. The source batch drops on return — every carried buffer is
    kept alive solely by the projection's Arc refs."""
    var src = _build_zoo()
    var srcs = _zoo_all_names()
    var outs = _zoo_renamed_names()
    return project_batch_by_src_out_pairs(src, srcs^, outs^)


def test_project_share_survives_source_destroy() raises:
    """Lifetime: the projected batch outlives the batch it was projected FROM.

    This is the lifetime claim projection sharing rests on — a join terminal
    that drops its pre-projection chunk list right after projecting turns a
    missed refcount here into a use-after-free on the whole result."""
    var projected = _project_zoo_and_drop_source()
    for _ in range(8):
        var churn = _build_zoo()
        _ = churn^
    _assert_zoo_values(projected)


def test_project_share_duplicate_source_column() raises:
    """`SELECT a, a AS b` — one source column feeding TWO outputs, which under
    sharing means two output columns ALIASING one buffer. Both must read
    correctly, and both must agree with the copy arm."""
    var b = _build_zoo()
    var srcs = List[String]()
    srcs.append(String("c_str")); srcs.append(String("c_str"))
    srcs.append(String("c_ni64")); srcs.append(String("c_ni64"))
    var outs = List[String]()
    outs.append(String("s1")); outs.append(String("s2"))
    outs.append(String("n1")); outs.append(String("n2"))
    var shared = project_batch_by_src_out_pairs(
        b, _proj_names(srcs), _proj_names(outs)
    )
    var copied = project_batch_by_src_out_pairs_arm(
        b, _proj_names(srcs), _proj_names(outs), False
    )
    _assert_batches_cell_equal(shared, copied)
    var es = _exp_str()
    var a1 = shared.column_at(0).as_string()
    var a2 = shared.column_at(1).as_string()
    for i in range(_N):
        assert_equal(a1.get(i), es[i], "dup-src col0 row " + String(i))
        assert_equal(a2.get(i), es[i], "dup-src col1 row " + String(i))


def test_project_share_structural_parity_with_copy() raises:
    """The share result must be structurally — not merely logically — what
    `copy_column` would have produced, because downstream code branches on
    `if col._validity:` and on DECIMAL (p, s).

      * an ALL-VALID bitmap (`null_count == 0`) is DROPPED by `copy_column`'s
        Path 2; the share arm must drop it too, or a consumer takes a
        bitmap branch the copy arm never sends it down;
      * a bitmap with REAL nulls is kept by both, with the same null_count;
      * DECIMAL (p, s) survives."""
    var b = _build_zoo()
    var srcs = _zoo_all_names()
    var outs = _zoo_renamed_names()
    var shared = project_batch_by_src_out_pairs(
        b, _proj_names(srcs), _proj_names(outs)
    )
    var copied = project_batch_by_src_out_pairs_arm(
        b, _proj_names(srcs), _proj_names(outs), False
    )
    for c in range(shared.num_columns()):
        ref cs = shared.column_at(c)
        ref cc = copied.column_at(c)
        assert_equal(
            cs._validity.__bool__(), cc._validity.__bool__(),
            "validity PRESENCE differs at column " + String(c),
        )
        assert_equal(
            cs._null_count, cc._null_count,
            "null_count differs at column " + String(c),
        )
        assert_equal(
            cs._length, cc._length, "length differs at column " + String(c)
        )
        assert_equal(
            cs._offset, cc._offset, "offset differs at column " + String(c)
        )
        assert_equal(
            cs._decimal_p, cc._decimal_p,
            "decimal precision differs at column " + String(c),
        )
        assert_equal(
            cs._decimal_s, cc._decimal_s,
            "decimal scale differs at column " + String(c),
        )
    # Column 5 is the decimal; assert the metadata is the real one, not 0 == 0.
    assert_equal(shared.column_at(5)._decimal_p, _DEC_P, "decimal p lost")
    assert_equal(shared.column_at(5)._decimal_s, _DEC_S, "decimal s lost")
    # Column 7 is nullable-int64 with 2 real nulls: BOTH arms keep the bitmap.
    assert_true(
        shared.column_at(7)._validity.__bool__(),
        "nullable column lost its validity bitmap",
    )
    assert_equal(shared.column_at(7)._null_count, 2, "null_count lost")


def test_project_share_empty_from_schema_shaped_column() raises:
    """`RecordBatch.empty_from_schema`'s zero-length STRING column, projected.

    That helper (used for the disjoint-key empty join) allocates a 4-byte
    offsets buffer and `zero()`s it WITHOUT calling `set_length`. A downstream
    projection REACHES those empty batches, so this shape is a live input here.

    One might expect the gate to DECLINE the column, on the reasoning that a
    length-less buffer gives `view_ro()` a [0, 0) span and probing
    `offsets[0]` would read out of bounds. It does not:
    `OwnedAlignedBuffer(capacity)`'s documented post-condition is
    `length() == max(capacity, 0)` — the bytes are admitted at construction and
    `set_length` is not required — so the view is a full 4 bytes and there is no
    out-of-bounds read to guard against. (The bounds check in
    `project_column_share_eligible` is defence: it costs one compare and the
    predicate must not be able to fault if that post-condition ever moves.)

    So the property pinned is the one below: this shape is eligible, and
    sharing it agrees with copying it."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("n"), ArrowType.INT64, False))
    var builder = RecordBatchBuilder()
    # Mirror `_zero_length_column` EXACTLY.
    var offs = OwnedAlignedBuffer(4)
    offs.zero()
    builder.add_column(
        Column[HeapRegion](
            arrow_type=ArrowType.STRING,
            data=OwnedAlignedBuffer(0),
            offsets=Optional[OwnedAlignedBuffer](offs^),
            validity=Optional[Bitmap[HeapRegion]](None),
            length=0,
            null_count=0,
            offset=0,
        )
    )
    builder.add_column(
        Column[HeapRegion](
            arrow_type=ArrowType.INT64,
            data=OwnedAlignedBuffer(0),
            offsets=Optional[OwnedAlignedBuffer](None),
            validity=Optional[Bitmap[HeapRegion]](None),
            length=0,
            null_count=0,
            offset=0,
        )
    )
    var b = builder.build(sb.build())
    assert_equal(b.num_rows(), 0, "empty_from_schema-shaped batch num_rows")

    # The predicate answers without faulting, on both layouts.
    assert_true(
        project_column_share_eligible(b, 0),
        "zero-length STRING column should be share-eligible",
    )
    assert_true(
        project_column_share_eligible(b, 1),
        "zero-length INT64 column should be share-eligible",
    )

    # And the projection agrees arm-for-arm, schema and all. An empty result
    # still has a schema — the whole point of the batch shape being tested.
    var srcs = List[String](); srcs.append(String("s")); srcs.append(String("n"))
    var outs = List[String](); outs.append(String("s2")); outs.append(String("n2"))
    var shared = project_batch_by_src_out_pairs(
        b, _proj_names(srcs), _proj_names(outs)
    )
    var copied = project_batch_by_src_out_pairs_arm(
        b, _proj_names(srcs), _proj_names(outs), False
    )
    _assert_batches_cell_equal(shared, copied)
    assert_equal(shared.num_columns(), 2, "empty projection lost its schema")
    assert_equal(shared.num_rows(), 0, "empty projection grew rows")
    assert_equal(shared.schema.field_name(0), String("s2"), "rename lost")
    assert_equal(shared.schema.field_name(1), String("n2"), "rename lost")


def test_share_gates_default_on() raises:
    """The share switch defaults ON: a constructor whose `share_on`
    defaulted to False would silently select the copy arm on every cache
    built without the argument, so both constructors are checked. (The by-name projection has no switch: its
    default entry point always passes `share_on=True` to its `_arm` form.)"""
    assert_true(
        ScanDedupCache().share_on(),
        "the scan-dedup cache must share by default — a hit would"
        " silently keep memcpy'ing",
    )
    assert_true(
        ScanDedupCache(4, 1 << 20).share_on(),
        "the capped constructor must share by default too",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
