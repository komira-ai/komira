# =============================================================================
# test_case_over_dictionary_column — a CASE/WHEN arm that reads a
# DICTIONARY-encoded string column must EVALUATE, not refuse
# =============================================================================
#
# REGRESSION GUARD: ClickBench Q39 needs it. Its group key is
#
#     CASE WHEN (search_engine_id = 0 AND adv_engine_id = 0) THEN referer ELSE '' END
#
# and the GROUPED parquet agg leaf evaluates a computed group key by
# `_eval_column_expr` over the leaf's OWN decoded batch. That batch carries the
# file's NATIVE encoding — a low-cardinality BYTE_ARRAY column such as
# `referer` arrives DICTIONARY-encoded — so the CASE evaluator is a
# type-checked builder that sees a dictionary, and without densifying it fails
# with
#
#     CASE/WHEN Utf8 THEN type mismatch at case 0: expected STRING, got dictionary
#
# ⛔ THE TWO GUARDS IT TRIPPED ARE CORRECT AND ARE NOT RELAXED BY THE FIX.
# `compiler_eval_case.mojo` refuses rather than reinterprets — its own comment
# says "Without this, a ByteArray reinterpret is a silent correctness bug".
# Densifying dictionary indices into string BYTES is what the fix does, and it
# does it where every other string kernel in this engine already does it
# (`_materialize_dict_to_string`, the SAME fallback the `EXPR_REGEXP`,
# `EXPR_SUBSTRING`, `EXPR_STRING_FN` and `EXPR_STRING_FN_N` arms take). The
# refusals stay: a THEN arm that is genuinely not string-shaped still raises.
#
# THE TWO REFUSAL SITES, WHICH ARE DIFFERENT SITES (this is why there are two
# families of test below, not one):
#   (1) a DICTIONARY **THEN** arm under a STRING default  -> the per-arm dtype
#       guard in `_run_case_overlay_utf8`  ("THEN type mismatch at case N").
#       ⭐ THIS IS cbq39's.
#   (2) a DICTIONARY **default/ELSE**                     -> `out_type` is read
#       off `default_col`, so the dispatch ladder in `_eval_when_expr` refuses
#       the whole expression ("only supports INT64, FLOAT64, and STRING output,
#       got dictionary"). Nothing in the corpus reached this one; it is the
#       same defect one operand over, and fixing only (1) would have left a
#       live refusal behind.
#
# INDEPENDENT ORACLE. Every expected value is recomputed in this file from the
# ABSOLUTE row index through `_code_at` / `_dict_value` / `_takes_then`, never
# by re-reading the column under test. The dictionary CODES are deliberately
# NON-MONOTONE (`(3i + 1) % 4`) and the four entries have FOUR DIFFERENT BYTE
# LENGTHS, so an off-by-one in either the code read or the offset write lands
# on a different string rather than on an adjacent-but-equal one.
#
# THE CONTROL. `test_control_plain_string_then_is_byte_identical` runs the
# SAME fixture with `referer` built as a PLAIN STRING column and asserts the
# two results agree row for row, nulls included. Without it, a fix that
# silently changed the STRING path (or that produced *some* string for every
# row) would still be green.
#
# MUTATION RECORD. Each mutant was applied to the fixed code and this suite
# re-run. Unmutated: 10 tests run, 10 passed.
#
#   M1  `_materialize_dict_to_string`: `has_validity = False` (densify, drop
#       the null mask)                          -> 6 FAILED, 4 passed.
#   M2  `_materialize_dict_to_string`: `dict_idx = 0` in both passes (resolve
#       every row to entry 0)                   -> 7 FAILED, 3 passed.
#   M5  `_materialize_dict_to_string`: resolve entry `(dict_idx + 1) % 4` —
#       the ADJACENT entry, still in bounds     -> 7 FAILED, 3 passed.
#
# ⭐ THE TWO THAT MATTER MOST ARE M3 AND M4: they remove ONE of the fix's two
# `_densify_dict_column` calls each, and they are killed by DISJOINT test sets.
# That is the evidence that the two refusal sites above are covered
# INDEPENDENTLY rather than by one test that happens to touch both.
#
#   M3  densify the THEN arms but NOT the default
#         -> exactly 2 FAILED: test_case_else_is_dictionary,
#            test_case_both_arms_dictionary.          (8 passed)
#   M4  densify the default but NOT the THEN arms
#         -> exactly 8 FAILED, and test_case_else_is_dictionary PASSES.
#            This is the pre-fix cbq39 state.         (2 passed)
#
# And the null mutant is the pre-fix tree itself, captured before the fix
# landed: 10 tests run, 0 passed, 10 failed — 8 of them with cbq39's verbatim
# `CASE/WHEN Utf8 THEN type mismatch at case 0: expected STRING, got
# dictionary` and 2 with the default-side `only supports INT64, FLOAT64, and
# STRING output, got dictionary`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.col_expr import col, lit, when_expr
from komira_core.plan.expr import Expr

from komira_compiler.compiler_eval_case import _eval_when_expr
from komira_compiler.compiler_eval_dict import _materialize_dict_to_string
from komira_compiler.compiler_eval_column import _eval_column_expr


# =============================================================================
# Fixture — a 12-row cbq39-shaped batch
# =============================================================================

comptime _N = 12
comptime _DICT_SIZE = 4


def _dict_value(e: Int) -> String:
    """Dictionary entry `e`. FOUR DISTINCT BYTE LENGTHS (24 / 1 / 11 / 8), so a
    one-entry slip in the code read or the offset write changes the STRING, not
    just its bytes."""
    if e == 0:
        return String("https://ref.example/aaa")
    if e == 1:
        return String("b")
    if e == 2:
        return String("mid_len_ref")
    return String("zzz_four")


def _code_at(i: Int) -> Int:
    """Per-row dictionary CODE at ABSOLUTE row `i`. NON-MONOTONE on purpose:
    `(3i + 1) % 4` = 1,0,3,2,1,0,3,2,... so `_code_at(i) != i` at EVERY row and
    an off-by-one in either direction lands on a different dictionary entry.
    (`(3i + 2) % 4`, the first draft, collides with the row index at rows 1 and
    3 — `test_fixture_is_discriminating` caught it.)"""
    return (i * 3 + 1) % _DICT_SIZE


def _is_null_row(i: Int) -> Bool:
    """ABSOLUTE rows 4 and 9 are NULL.

    ⭐ THE PAIR IS CHOSEN SO ONE NULL FALLS ON EACH SIDE OF THE BRANCH:
    row 9 takes the THEN arm (so a dropped THEN validity is caught) and row 4
    takes the ELSE arm (so a NULL that leaks *out* of an unselected dictionary
    row is caught)."""
    return i % 5 == 4


def _takes_then(i: Int) -> Bool:
    """`search_engine_id == 0` — rows 0, 3, 6, 9."""
    return i % 3 == 0


def _sei_at(i: Int) -> Int:
    return 0 if _takes_then(i) else 7


def _dict_values() -> List[String]:
    var out = List[String]()
    for e in range(_DICT_SIZE):
        out.append(_dict_value(e))
    return out^


def _validity() -> Bitmap[HeapRegion]:
    var bm = Bitmap.create_all_valid(_N)
    for i in range(_N):
        if _is_null_row(i):
            bm.clear(i)
    return bm^


def _null_count() -> Int:
    var c = 0
    for i in range(_N):
        if _is_null_row(i):
            c += 1
    return c


def _referer_dict_column() raises -> Column[HeapRegion]:
    """`referer` as the parquet leaf now presents it: DICTIONARY, Int32 codes,
    WITH a validity bitmap. NULL rows carry an in-range placeholder code (the
    same shape a real dictionary page produces)."""
    comptime int32_size = 4
    var buf = OwnedAlignedBuffer(_N * int32_size)
    for i in range(_N):
        buf.set_typed[Scalar[DType.int32]](i, Int32(_code_at(i)))
    buf.set_length(_N * int32_size)
    var idx = PrimitiveArray[DType.int32](
        buf^, _N, Optional[Bitmap[HeapRegion]](_validity()), _null_count(), 0
    )
    return Column.from_dictionary(
        StringDictionaryArray(idx^, StringArray.from_strings(_dict_values()), _N)
    )


def _referer_string_column() raises -> Column[HeapRegion]:
    """THE CONTROL COLUMN: the SAME logical cells as `_referer_dict_column`,
    presented as a plain nullable STRING — i.e. what the route this regression
    replaced used to hand the CASE evaluator."""
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(_N):
        vals.append(_dict_value(_code_at(i)))
        valid.append(not _is_null_row(i))
    return Column.from_string(
        StringArray.from_strings_with_validity(vals, valid)
    )


def _second_dict_column() raises -> Column[HeapRegion]:
    """A SECOND dictionary column with a DISJOINT value space, so a test whose
    THEN and ELSE are both dictionaries cannot pass by reading one of them
    twice."""
    comptime int32_size = 4
    var buf = OwnedAlignedBuffer(_N * int32_size)
    for i in range(_N):
        buf.set_typed[Scalar[DType.int32]](i, Int32(_code_at(i)))
    buf.set_length(_N * int32_size)
    var idx = PrimitiveArray[DType.int32](buf^, _N, None, 0, 0)
    var vals = List[String]()
    for e in range(_DICT_SIZE):
        vals.append(String("DST_") + String(e))
    return Column.from_dictionary(
        StringDictionaryArray(idx^, StringArray.from_strings(vals), _N)
    )


def _sei_column() raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate(_N)
    var p = a._typed_ptr_mut()
    for i in range(_N):
        p.unsafe_store[width=1](i, Scalar[DType.int64](_sei_at(i)))
    return Column.from_primitive[DType.int64](a)


def _batch(var referer: Column[HeapRegion]) raises -> RecordBatch:
    """`search_engine_id` (INT64) + `referer` + `dst` (a 2nd dictionary)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("search_engine_id", ArrowType.INT64, False))
    sb.add_field(Field("referer", referer.arrow_type, True))
    sb.add_field(Field("dst", ArrowType.DICTIONARY, False))
    var schema = sb.build()
    var bb = RecordBatchBuilder()
    bb.add_column(_sei_column())
    bb.add_column(referer^)
    bb.add_column(_second_dict_column())
    return bb.build(schema^)


# -----------------------------------------------------------------------------
# Result readers
# -----------------------------------------------------------------------------


def _row(c: Column[HeapRegion], j: Int) raises -> String:
    return c.as_string().get(j)


def _row_is_null(c: Column[HeapRegion], j: Int) -> Bool:
    if c._validity:
        return not c._validity.value().test(j)
    return False


def _cbq39_expr() raises -> Expr:
    """cbq39's group key, one predicate narrower:
    `CASE WHEN search_engine_id = 0 THEN referer ELSE '' END`."""
    var wb = when_expr(col("search_engine_id") == 0, col("referer").take_expr())
    return wb.otherwise(lit(String("")).take_expr())


# =============================================================================
# 0. The fixture itself must be discriminating
# =============================================================================


def test_fixture_is_discriminating() raises:
    """A fixture whose nulls all land on one branch, or whose codes are the row
    index, cannot fail for the reasons this file exists to catch."""
    var then_nulls = 0
    var else_nulls = 0
    var code_equals_row = 0
    for i in range(_N):
        if _is_null_row(i):
            if _takes_then(i):
                then_nulls += 1
            else:
                else_nulls += 1
        if _code_at(i) == i:
            code_equals_row += 1
    assert_true(then_nulls >= 1, "need a NULL on the THEN branch (row 9)")
    assert_true(else_nulls >= 1, "need a NULL on the ELSE branch (row 4)")
    assert_true(
        code_equals_row == 0,
        "codes must not track the row index; got " + String(code_equals_row),
    )
    # All four dictionary entries have distinct byte lengths.
    var lens = List[Int]()
    for e in range(_DICT_SIZE):
        lens.append(len(_dict_value(e).as_bytes()))
    for a in range(_DICT_SIZE):
        for b in range(a + 1, _DICT_SIZE):
            assert_true(
                lens[a] != lens[b],
                "dict entries " + String(a) + "/" + String(b)
                + " share a byte length",
            )


# =============================================================================
# 1. THE cbq39 SHAPE — a DICTIONARY THEN arm under a STRING default
# =============================================================================


def test_case_then_dictionary_values() raises:
    """PRE-FIX THIS RAISES `CASE/WHEN Utf8 THEN type mismatch at case 0:
    expected STRING, got dictionary` — the exact refusal cbq39 hit."""
    var batch = _batch(_referer_dict_column())
    var out = _eval_when_expr(_cbq39_expr(), batch)
    for i in range(_N):
        if _takes_then(i) and _is_null_row(i):
            continue  # asserted by test_case_then_dictionary_propagates_null
        var want = _dict_value(_code_at(i)) if _takes_then(i) else String("")
        assert_equal(_row(out, i), want, "row " + String(i))


def test_case_then_dictionary_propagates_null() raises:
    """Row 9 takes THEN and its dictionary cell is NULL, so the CASE output
    must be NULL — not the string its placeholder code addresses. Row 4 takes
    ELSE and is NULL in the dictionary, so it must come back the NON-NULL
    default."""
    var batch = _batch(_referer_dict_column())
    var out = _eval_when_expr(_cbq39_expr(), batch)
    assert_true(_row_is_null(out, 9), "row 9 must be NULL (THEN over a NULL)")
    assert_false(
        _row_is_null(out, 4), "row 4 takes ELSE; the NULL must not leak out"
    )
    assert_equal(_row(out, 4), String(""), "row 4 value")
    var nulls = 0
    for i in range(_N):
        if _row_is_null(out, i):
            nulls += 1
    assert_equal(nulls, 1, "exactly one output NULL")


def test_case_result_is_string_typed() raises:
    """The CASE output is a STRING column, not a dictionary passed through."""
    var batch = _batch(_referer_dict_column())
    var out = _eval_when_expr(_cbq39_expr(), batch)
    assert_true(
        out.arrow_type == ArrowType.STRING,
        "expected STRING, got " + String(out.arrow_type),
    )
    assert_equal(out._length, _N, "row count")


def test_case_all_rows_take_the_dictionary_arm() raises:
    """A condition true on every row, so all four dictionary entries and both
    NULL rows are resolved through the THEN arm."""
    var batch = _batch(_referer_dict_column())
    var wb = when_expr(col("search_engine_id") >= 0, col("referer").take_expr())
    var e = wb.otherwise(lit(String("UNREACHED")).take_expr())
    var out = _eval_when_expr(e, batch)
    var seen = List[Bool](length=_DICT_SIZE, fill=False)
    for i in range(_N):
        if _is_null_row(i):
            assert_true(_row_is_null(out, i), "row " + String(i) + " NULL")
            continue
        assert_equal(_row(out, i), _dict_value(_code_at(i)), "row " + String(i))
        seen[_code_at(i)] = True
    for e in range(_DICT_SIZE):
        assert_true(seen[e], "dict entry " + String(e) + " was never resolved")


# =============================================================================
# 2. THE SECOND REFUSAL SITE — a DICTIONARY default/ELSE
# =============================================================================


def test_case_else_is_dictionary() raises:
    """PRE-FIX THIS RAISES `CASE/WHEN only supports INT64, FLOAT64, and STRING
    output, got dictionary` — `out_type` is read off the DEFAULT column, so a
    dictionary ELSE refuses the whole expression before any THEN arm is seen."""
    var batch = _batch(_referer_dict_column())
    var wb = when_expr(
        col("search_engine_id") == 0, lit(String("LITERAL")).take_expr()
    )
    var e = wb.otherwise(col("referer").take_expr())
    var out = _eval_when_expr(e, batch)
    assert_true(out.arrow_type == ArrowType.STRING, "output type")
    for i in range(_N):
        if _takes_then(i):
            assert_equal(_row(out, i), String("LITERAL"), "row " + String(i))
            assert_false(_row_is_null(out, i), "row " + String(i) + " not null")
        elif _is_null_row(i):
            assert_true(_row_is_null(out, i), "row " + String(i) + " NULL")
        else:
            assert_equal(
                _row(out, i), _dict_value(_code_at(i)), "row " + String(i)
            )


def test_case_both_arms_dictionary() raises:
    """THEN and ELSE are two DIFFERENT dictionary columns with disjoint value
    spaces, so reading one of them twice cannot pass."""
    var batch = _batch(_referer_dict_column())
    var wb = when_expr(col("search_engine_id") == 0, col("referer").take_expr())
    var e = wb.otherwise(col("dst").take_expr())
    var out = _eval_when_expr(e, batch)
    assert_true(out.arrow_type == ArrowType.STRING, "output type")
    for i in range(_N):
        if _takes_then(i):
            if _is_null_row(i):
                assert_true(_row_is_null(out, i), "row " + String(i) + " NULL")
            else:
                assert_equal(
                    _row(out, i), _dict_value(_code_at(i)), "row " + String(i)
                )
        else:
            assert_equal(
                _row(out, i),
                String("DST_") + String(_code_at(i)),
                "row " + String(i),
            )


# =============================================================================
# 3. THE CONTROL — the plain-STRING path is unchanged
# =============================================================================


def test_control_plain_string_then_is_byte_identical() raises:
    """The SAME logical cells presented as a plain STRING column must produce
    the SAME result, row for row and null for null. This is what makes the
    dictionary assertions above mean "the dictionary path agrees with the
    string path" rather than "the dictionary path returned some string"."""
    var dict_out = _eval_when_expr(
        _cbq39_expr(), _batch(_referer_dict_column())
    )
    var str_out = _eval_when_expr(
        _cbq39_expr(), _batch(_referer_string_column())
    )
    assert_true(
        str_out.arrow_type == ArrowType.STRING, "control output type"
    )
    assert_equal(dict_out._length, str_out._length, "row counts")
    for i in range(_N):
        assert_true(
            _row_is_null(dict_out, i) == _row_is_null(str_out, i),
            "null flag row " + String(i),
        )
        if not _row_is_null(str_out, i):
            assert_equal(
                _row(dict_out, i), _row(str_out, i), "value row " + String(i)
            )


# =============================================================================
# 4. THE PROJECTION DOOR — the same expression through `_eval_column_expr`
# =============================================================================


def test_projection_door_evaluates_the_case() raises:
    """ClickBench cbq39 does not call `_eval_when_expr` directly: the agg leaf's `MapOp`
    evaluates the project entry through `_eval_column_expr`'s `EXPR_WHEN` arm.
    Assert the wired door, not only the helper."""
    var batch = _batch(_referer_dict_column())
    var out = _eval_column_expr(_cbq39_expr(), batch)
    assert_true(out.arrow_type == ArrowType.STRING, "output type")
    assert_equal(_row(out, 0), _dict_value(_code_at(0)), "row 0")
    assert_equal(_row(out, 1), String(""), "row 1")
    assert_true(_row_is_null(out, 9), "row 9 NULL")


def test_alias_wrapped_case_evaluates() raises:
    """The binder wraps a computed group key in an ALIAS (`... AS src`); the
    alias arm must reach the same evaluation."""
    var batch = _batch(_referer_dict_column())
    var aliased = Expr.alias(_cbq39_expr(), String("src"))
    var out = _eval_column_expr(aliased, batch)
    assert_true(out.arrow_type == ArrowType.STRING, "output type")
    assert_equal(_row(out, 3), _dict_value(_code_at(3)), "row 3")


# =============================================================================
# 5. THE OTHER DICTIONARY — a NUMERIC dictionary must still REFUSE
# =============================================================================
#
# ⛔ A NUMERIC DICTIONARY CARRIES THE SAME `ArrowType.DICTIONARY` TAG. It is
# built on the PRODUCTION parquet decode path (`column_decoder.mojo`'s
# `Column.from_numeric_dict{,_codes_view}` arms, under `preserve_dict` +
# dict-vec), so it reaches the very same leaf this regression is about. Its
# `_offsets` / `_dict_data` are None — a "densify to string" would resolve
# integer codes against a dictionary payload that does not exist.
#
# THE FIX MUST THEREFORE NOT WIDEN: it keys on `is_string_dict`, not on the
# tag, so a numeric dictionary passes through UNTOUCHED and meets the dtype
# guard that was already refusing it. These two tests are what stop a future
# "just handle DICTIONARY" edit from turning this engine's safest failure mode
# into a fabricated value.


def _numeric_dict_column() raises -> Column[HeapRegion]:
    """INT64-valued dictionary, int32 codes — `from_numeric_dict`'s shape."""
    var a = PrimitiveArray[DType.int32].allocate(_N)
    var p = a._typed_ptr_mut()
    for i in range(_N):
        p.unsafe_store[width=1](i, Int32(_code_at(i)))
    var vals = List[Int64]()
    for e in range(_DICT_SIZE):
        vals.append(Int64(100 + e))
    return Column.from_numeric_dict[DType.int32, DType.int64](a^, vals^)


def test_numeric_dict_is_not_densified_to_a_string() raises:
    """The shared materializer REFUSES BY NAME rather than reading through the
    empty `_offsets` Optional a numeric dictionary carries."""
    var col = _numeric_dict_column()
    assert_true(col.is_dictionary(), "fixture carries the DICTIONARY tag")
    assert_true(col.is_numeric_dict(), "fixture is a NUMERIC dictionary")
    assert_false(col.is_string_dict(), "fixture is not a STRING dictionary")
    var raised = False
    try:
        var _unused = _materialize_dict_to_string(col)
    except:
        raised = True
    assert_true(raised, "a numeric dictionary must not materialize as a string")


def test_case_over_a_numeric_dict_still_refuses() raises:
    """`CASE WHEN ... THEN <numeric dict> ELSE '' END` must still RAISE. The
    fix serves STRING dictionaries only; a refusal here is the correct answer
    and NOT a gap this file is asking anyone to close by relaxing a guard."""
    var sb = SchemaBuilder()
    sb.add_field(Field("search_engine_id", ArrowType.INT64, False))
    sb.add_field(Field("ndict", ArrowType.DICTIONARY, False))
    var schema = sb.build()
    var bb = RecordBatchBuilder()
    bb.add_column(_sei_column())
    bb.add_column(_numeric_dict_column())
    var batch = bb.build(schema^)
    var wb = when_expr(col("search_engine_id") == 0, col("ndict").take_expr())
    var e = wb.otherwise(lit(String("")).take_expr())
    var raised = False
    try:
        var _unused = _eval_when_expr(e, batch)
    except:
        raised = True
    assert_true(raised, "a numeric-dictionary THEN arm must still refuse")



def main() raises:
    var ts = TestSuite()
    ts.test[test_fixture_is_discriminating]()
    ts.test[test_case_then_dictionary_values]()
    ts.test[test_case_then_dictionary_propagates_null]()
    ts.test[test_case_result_is_string_typed]()
    ts.test[test_case_all_rows_take_the_dictionary_arm]()
    ts.test[test_case_else_is_dictionary]()
    ts.test[test_case_both_arms_dictionary]()
    ts.test[test_control_plain_string_then_is_byte_identical]()
    ts.test[test_projection_door_evaluates_the_case]()
    ts.test[test_alias_wrapped_case_evaluates]()
    ts.test[test_numeric_dict_is_not_densified_to_a_string]()
    ts.test[test_case_over_a_numeric_dict_still_refuses]()
    ts^.run()
