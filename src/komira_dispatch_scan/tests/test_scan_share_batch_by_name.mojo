"""Projection sharing, the by-name sibling: `project_batch_by_names` Arc-shares
the columns it carries wherever `project_column_share_eligible` holds, and
equals its copy arm (`project_batch_by_names_arm(..., False)`) cell for cell
and structurally.

These are the by-name half of the projection-sharing tests in
`test_scan_share_batch.mojo`, in a file of their own so each file stays under
1,000 lines; the fixtures below are copies of that file's.
"""

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
    project_batch_by_names,
    project_batch_by_names_arm,
    project_batch_by_src_out_pairs,
    project_column_share_eligible,
)


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


# =============================================================================
# PROJECTION SHARING, THE BY-NAME SIBLING
# =============================================================================
#
# `project_batch_by_names` is `project_batch_by_src_out_pairs`'s by-name twin —
# select-and-NARROW where the other is select-and-RENAME — behind the same
# share gate. Its common case is an IDENTITY projection (every column, in
# schema order), on the driver thread.
#
# THE IDENTITY SHAPE GETS ITS OWN TEST. The pairs tests in
# `test_scan_share_batch.mojo` all RENAME every column, so none of them
# exercises an IDENTITY projection.


def _project_by_name_zoo_and_drop_source() raises -> RecordBatch:
    """Build the zoo as a LOCAL, project it BY NAME (sharing), return ONLY the
    projection. The source drops on return — every carried buffer is kept
    alive solely by the projection's Arc refs. This is the in-memory leaf
    resolve's exact lifetime: it projects its batch and drops it next line."""
    var src = _build_zoo()
    var names = _zoo_all_names()
    return project_batch_by_names(src, names^)


def test_project_by_name_share_identity_projection() raises:
    """THE IDENTITY SHAPE. Every column, in schema order — the projection that is a
    no-op in everything but allocation. Sharing ON must equal sharing OFF
    cell-for-cell AND equal the zoo's known values (the independent oracle
    that catches both arms being wrong together)."""
    var b = _build_zoo()
    var names = _zoo_all_names()
    var shared = project_batch_by_names(b, _proj_names(names))
    var copied = project_batch_by_names_arm(b, _proj_names(names), False)
    _assert_batches_cell_equal(shared, copied)
    _assert_zoo_values(shared)
    assert_equal(
        shared.num_columns(), b.num_columns(),
        "identity projection lost a column",
    )
    # ...and the gate FIRED on every column, so this is exercising the share
    # arm and not silently re-running the copy arm. A share arm that never
    # fires is how a differential test goes vacuous.
    for c in range(b.num_columns()):
        assert_true(
            project_column_share_eligible(b, c),
            "zoo column " + String(c) + " unexpectedly ineligible — the share"
            " arm did not fire and this test is vacuous",
        )


def test_project_by_name_share_narrows_and_reorders() raises:
    """The genuine narrow: a SUBSET, in an order that is not schema order.
    `project_batch_by_names` is a reorder primitive as well as a narrow one,
    and a share arm that returned the input batch unchanged would pass the
    identity test above while silently breaking this one."""
    var b = _build_zoo()
    var names = List[String]()
    names.append(String("c_dec")); names.append(String("c_str"))
    names.append(String("c_i64"))
    var shared = project_batch_by_names(b, _proj_names(names))
    var copied = project_batch_by_names_arm(b, _proj_names(names), False)
    _assert_batches_cell_equal(shared, copied)
    assert_equal(shared.num_columns(), 3, "narrow did not narrow")
    assert_equal(shared.schema.field_name(0), String("c_dec"), "reorder lost")
    assert_equal(shared.schema.field_name(1), String("c_str"), "reorder lost")
    assert_equal(shared.schema.field_name(2), String("c_i64"), "reorder lost")
    # The reordered STRING column reads its own values, not column 0's.
    var es = _exp_str()
    var got = shared.column_at(1).as_string()
    for i in range(_N):
        assert_equal(got.get(i), es[i], "reordered string row " + String(i))


def test_project_by_name_share_declines_sliced_string_column() raises:
    """THE FALSIFIER on the by-name entry point — the silent-wrong-answer case
    the gate exists for. A STRING column viewing logical rows [2..6): a raw
    `share()` reads from physical row 0, so the gate must decline, and the
    projection must return the CORRECT rebased window with sharing ON."""
    comptime i32sz = size_of[Int32]()
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

    # (1) The hazard is real on THIS build, not hypothetical.
    var raw_arr = b.column_at(0).share().as_string()
    assert_equal(
        raw_arr.get(0), String("row0"),
        "premise broken: a raw share() of a sliced STRING column no longer"
        " reads from physical row 0 — re-derive the gate before trusting it",
    )
    # (2) So the gate declines it.
    assert_false(
        project_column_share_eligible(b, 0),
        "sliced STRING column must NOT be share-eligible",
    )
    # (3) And BOTH arms return the correct logical window.
    var names = List[String](); names.append(String("s"))
    var shared = project_batch_by_names(b, _proj_names(names))
    var copied = project_batch_by_names_arm(b, _proj_names(names), False)
    _assert_batches_cell_equal(shared, copied)
    var got = shared.column_at(0).as_string()
    for i in range(4):
        assert_equal(
            got.get(i), all_vals[i + 2],
            "sliced-string by-name projection row " + String(i),
        )


def test_project_by_name_share_survives_source_destroy() raises:
    """Lifetime: the projection outlives the batch it was projected FROM.

    This is the in-memory leaf resolve's exact lifetime — it projects
    its batch and lets it drop — so a missed refcount here is a
    use-after-free on the whole resident leaf batch."""
    var projected = _project_by_name_zoo_and_drop_source()
    for _ in range(8):
        var churn = _build_zoo()
        _ = churn^
    _assert_zoo_values(projected)


def test_project_by_name_share_duplicate_name() raises:
    """`SELECT a, a` — one source column feeding TWO outputs, which under
    sharing means two output columns ALIASING ONE buffer."""
    var b = _build_zoo()
    var names = List[String]()
    names.append(String("c_str")); names.append(String("c_str"))
    names.append(String("c_ni64")); names.append(String("c_ni64"))
    var shared = project_batch_by_names(b, _proj_names(names))
    var copied = project_batch_by_names_arm(b, _proj_names(names), False)
    _assert_batches_cell_equal(shared, copied)
    var es = _exp_str()
    var a1 = shared.column_at(0).as_string()
    var a2 = shared.column_at(1).as_string()
    for i in range(_N):
        assert_equal(a1.get(i), es[i], "dup-name col0 row " + String(i))
        assert_equal(a2.get(i), es[i], "dup-name col1 row " + String(i))


def test_project_by_name_share_structural_parity_with_copy() raises:
    """The share result must be STRUCTURALLY what `copy_column` produced, not
    merely logically equal — downstream code branches on `if col._validity:`
    and on DECIMAL (p, s), so an all-valid bitmap surviving the share sends a
    consumer down a branch the copy arm never sends it down."""
    var b = _build_zoo()
    var names = _zoo_all_names()
    var shared = project_batch_by_names(b, _proj_names(names))
    var copied = project_batch_by_names_arm(b, _proj_names(names), False)
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
