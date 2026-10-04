# =============================================================================
# test_dict_materialize_nulls_and_wide_codes — the DICTIONARY string-op
# materializer must carry VALIDITY and must honor the CODE BYTE WIDTH
# =============================================================================
#
# REGRESSION GUARD for two SILENT-WRONG-ANSWER defects, both
# in `_materialize_dict_to_string` (`komira_compiler/compiler_eval_dict.mojo`)
# — the same function that carries the offset-aware CODE read pinned by
# test_dict_materialize_offset_honoring. This file is the sibling guard for
# its two other defects.
#
# DEFECT 1 — VALIDITY IS DROPPED.
#   The materializer built its output as
#   `StringArray(out_offsets^, out_data^, None, num_rows, total_bytes, 0)`:
#   validity `None`, null_count `0`, unconditionally. `col._validity` was
#   referenced NOWHERE. So every NULL row of a nullable DICTIONARY column came
#   out of the materializer as a NON-NULL string — specifically, whatever
#   dictionary entry the null row's placeholder code happened to address.
#
#   That is a FABRICATED VALUE, and it is consumed. Every `eval_regexp_*`
#   kernel in `komira_core/eval/regexp_functions.mojo` propagates input nulls
#   (`var has_nulls = col.null_count > 0 and col.validity`; `if has_nulls and
#   col.is_null(i): -> NULL`), and the `EXPR_SUBSTRING` arm in
#   `komira_compiler/compiler_eval_column.mojo` branches on
#   `sarr.is_null(i)`. Both are reached with the RAW batch column via the
#   `_materialize_dict_to_string` DICTIONARY arm, so on a nullable dictionary
#   column both silently produced a NON-NULL answer for a NULL input row.
#
#   FAILS ON CURRENT CODE (pre-fix): `test_dict_materialize_carries_validity`
#   asserts `arr.is_null(j)` / `arr.null_count`; pre-fix `arr.validity` is
#   `None` so `is_null` is False on every row and `null_count` is 0.
#   `test_regexp_like_over_nullable_dict_propagates_null` asserts the same
#   through the REAL `eval_regexp_like` consumer: pre-fix the returned mask has
#   no validity at all and reports a fabricated True/False for the null rows.
#
# DEFECT 2 — INT32 CODE WIDTH IS HARD-ASSUMED.
#   The code pointer was `col._data.view_range_ro(col._offset * 4, num_rows * 4)`
#   bitcast to `Int32`, with the `4` a `size_of[Int32]` comptime constant.
#   `Column._dict_index_byte_width` (4 for `from_dictionary`, 8 for
#   `from_int64_dict_indices`) was referenced NOWHERE, even though the column's
#   own canonical accessor `Column.dict_code_at` routes on it. On an
#   Int64-indexed dictionary column the int32 read at element `i` lands on byte
#   `4*i` of an 8-byte-stride buffer: even `i` reads the LOW half of code
#   `i/2`, odd `i` reads the HIGH half (0 for every real code) — so the row
#   values are interleaved-and-halved garbage, silently.
#
#   Int64-indexed DICTIONARY columns are NOT hypothetical and NOT test-only:
#   `komira_search/fast_fields.mojo:_materialize_keyword` builds every keyword
#   fast-field column via `Column.from_int64_dict_indices(...)`, WITH a
#   validity bitmap, WITH null rows carrying a placeholder code 0 — i.e. it
#   produces exactly the shape that trips BOTH defects at once.
#
#   FAILS ON CURRENT CODE (pre-fix): `test_dict_materialize_int64_codes`
#   asserts row 1 == "v4_dog" (code ladder `(3i+1) % 7`); pre-fix row 1 reads
#   the high half of code 0 == 0 -> "v0_cat".
#
# INDEPENDENT ORACLE: every expected value is computed in this file from the
# ABSOLUTE row index via the `_code_at` / `_dict_value` ladder, never by
# re-reading whatever pointer base or width the code under test happened to
# use.
#
# NULL-ROW STRING CONTRACT: a null row materializes as a ZERO-LENGTH string
# with its validity bit CLEAR. This mirrors the sibling dictionary expander
# `ipc_decoder_dispatch.expand_dict_indices_to_string` ("Bit-clear means the
# OUTPUT row at that position is NULL (its expanded string is empty + validity
# propagates)"). It also means a null row's placeholder code is never used to
# index the dictionary payload — see
# `test_null_row_with_out_of_range_code_is_not_resolved`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion

from komira_core.eval.regexp_functions import eval_regexp_like
from komira_core.eval.regexp_nfa import RegexProgram

from komira_compiler.compiler_eval_dict import _materialize_dict_to_string


# =============================================================================
# Fixture shape
# =============================================================================

comptime _N_TOTAL = 20
# `_WIN_START` must NOT be a multiple of the null period (5) — otherwise the
# window's LOCAL null positions coincide with its ABSOLUTE ones and an
# offset-blind validity copy would pass. `test_fixture_is_null_bearing_and_
# discriminating` enforces this (it caught `_WIN_START = 5`).
comptime _WIN_START = 3
comptime _WIN_LEN = 11
comptime _DICT_SIZE = 7


def _dict_value(e: Int) -> String:
    """Dictionary entry `e`. All 7 entries are distinct."""
    if e % 3 == 0:
        return String("v") + String(e) + String("_cat")
    if e % 3 == 1:
        return String("v") + String(e) + String("_dog")
    return String("v") + String(e) + String("_cow")


def _code_at(i: Int) -> Int:
    """Per-row dictionary CODE at ABSOLUTE row `i`. `_code_at(1) == 4`, which
    is what makes the Int64 misread detectable at row 1."""
    return (i * 3 + 1) % _DICT_SIZE


def _is_null_row(i: Int) -> Bool:
    """ABSOLUTE rows 2, 7, 12, 17 are NULL. The `[3, 14)` window therefore
    holds nulls at LOCAL rows 4 and 9, while an offset-blind validity copy
    would place them at LOCAL rows 2 and 7 — so a validity copy that ignores
    `_offset` is caught too."""
    return i % 5 == 2


def _value_at_row(i: Int) -> String:
    """The string the column logically holds at ABSOLUTE row `i` (empty for a
    NULL row, per the null-row string contract above)."""
    if _is_null_row(i):
        return String("")
    return _dict_value(_code_at(i))


def _dict_values() -> List[String]:
    var out = List[String]()
    for e in range(_DICT_SIZE):
        out.append(_dict_value(e))
    return out^


# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------


def _validity_for_rows(n: Int) -> Bitmap[HeapRegion]:
    var bm = Bitmap.create_all_valid(n)
    for i in range(n):
        if _is_null_row(i):
            bm.clear(i)
    return bm^


def _null_count_for_rows(n: Int) -> Int:
    var c = 0
    for i in range(n):
        if _is_null_row(i):
            c += 1
    return c


def _nullable_int32_dict_column() raises -> Column[HeapRegion]:
    """A 20-row DICTIONARY(string) Column with Int32 codes and a validity
    bitmap. Null rows carry an IN-RANGE placeholder code (the real ladder
    code), the same way `fast_fields._materialize_keyword` carries code 0."""
    comptime int32_size = 4
    var buf = OwnedAlignedBuffer(_N_TOTAL * int32_size)
    for i in range(_N_TOTAL):
        buf.set_typed[Scalar[DType.int32]](i, Int32(_code_at(i)))
    buf.set_length(_N_TOTAL * int32_size)
    var idx = PrimitiveArray[DType.int32](
        buf^,
        _N_TOTAL,
        Optional[Bitmap[HeapRegion]](_validity_for_rows(_N_TOTAL)),
        _null_count_for_rows(_N_TOTAL),
        0,
    )
    return Column.from_dictionary(
        StringDictionaryArray(
            idx^, StringArray.from_strings(_dict_values()), _N_TOTAL
        )
    )


def _nullable_int64_dict_column() raises -> Column[HeapRegion]:
    """The `fast_fields._materialize_keyword` shape: Int64 codes + validity."""
    var indices = List[Int64]()
    for i in range(_N_TOTAL):
        indices.append(Int64(_code_at(i)))
    return Column.from_int64_dict_indices(
        indices^,
        _dict_values(),
        Optional[Bitmap[HeapRegion]](_validity_for_rows(_N_TOTAL)),
        _null_count_for_rows(_N_TOTAL),
    )


def _plain_int64_dict_column() raises -> Column[HeapRegion]:
    """Int64 codes, NO validity — isolates defect 2 from defect 1."""
    var indices = List[Int64]()
    for i in range(_N_TOTAL):
        indices.append(Int64(_code_at(i)))
    return Column.from_int64_dict_indices(indices^, _dict_values(), None, 0)


def _plain_int32_dict_column() raises -> Column[HeapRegion]:
    """Int32 codes, NO validity — today's corpus shape; the control."""
    var codes = List[Int32]()
    for i in range(_N_TOTAL):
        codes.append(Int32(_code_at(i)))
    return Column.from_dictionary(
        StringDictionaryArray(
            PrimitiveArray[DType.int32].from_list(codes),
            StringArray.from_strings(_dict_values()),
            _N_TOTAL,
        )
    )


# =============================================================================
# Oracles
# =============================================================================


def _assert_values(
    imm arr: StringArray[HeapRegion],
    start: Int,
    length: Int,
    label: String,
    nullable: Bool = True,
) raises:
    """`nullable=False` for the fixtures built WITHOUT a validity bitmap: there
    every row is valid, so the oracle is the raw dictionary entry (the
    `_is_null_row` ladder does not apply)."""
    assert_equal(arr.length, length, label + ": length")
    for j in range(length):
        var want = (
            _value_at_row(start + j) if nullable
            else _dict_value(_code_at(start + j))
        )
        assert_equal(
            arr.get(j),
            want,
            label + ": value at local row " + String(j)
            + " (abs " + String(start + j) + ")",
        )


def _assert_nulls(
    imm arr: StringArray[HeapRegion],
    start: Int,
    length: Int,
    label: String,
) raises:
    var want_nulls = 0
    for j in range(length):
        var want = _is_null_row(start + j)
        if want:
            want_nulls += 1
        assert_true(
            arr.is_null(j) == want,
            label + ": is_null at local row " + String(j)
            + " (abs " + String(start + j) + ") — want "
            + String(want) + ", got " + String(arr.is_null(j)),
        )
    assert_equal(arr.null_count, want_nulls, label + ": null_count")


# =============================================================================
# DEFECT 1 — validity
# =============================================================================


def test_fixture_is_null_bearing_and_discriminating() raises:
    """Guard the guard: the fixture must actually contain nulls, and the
    window's LOCAL null positions must differ from its ABSOLUTE ones (so an
    offset-blind validity copy is caught)."""
    assert_equal(_null_count_for_rows(_N_TOTAL), 4, "fixture null count")
    var local_matches_absolute = True
    for j in range(_WIN_LEN):
        if _is_null_row(j) != _is_null_row(_WIN_START + j):
            local_matches_absolute = False
    assert_true(
        not local_matches_absolute,
        "fixture window must discriminate offset-blind validity",
    )
    # The Int64 misread must be detectable: row 1's high half is 0, and
    # dictionary entry 0 differs from the true value at row 1.
    assert_true(
        _dict_value(0) != _dict_value(_code_at(1)),
        "fixture must discriminate the int64->int32 half-word misread",
    )


def test_dict_materialize_carries_validity() raises:
    var col = _nullable_int32_dict_column()
    var arr = _materialize_dict_to_string(col)
    _assert_nulls(arr, 0, _N_TOTAL, String("int32 dict @ offset 0"))
    _assert_values(arr, 0, _N_TOTAL, String("int32 dict @ offset 0"))


def test_dict_materialize_validity_honors_offset() raises:
    var full = _nullable_int32_dict_column()
    var col = full.slice(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    _assert_nulls(arr, _WIN_START, _WIN_LEN, String("int32 dict @ window"))
    _assert_values(arr, _WIN_START, _WIN_LEN, String("int32 dict @ window"))


def test_regexp_like_over_nullable_dict_propagates_null() raises:
    """The REAL consumer. `eval_regexp_like` gates on
    `col.null_count > 0 and col.validity`, so a materializer that drops
    validity makes `NULL ~ 'pattern'` return a fabricated boolean instead of
    NULL."""
    var col = _nullable_int32_dict_column()
    var arr = _materialize_dict_to_string(col)
    var prog = RegexProgram.compile(String("_dog$"), String(""))
    var mask = eval_regexp_like(arr, prog)
    assert_equal(mask.length, _N_TOTAL, "mask length")
    for i in range(_N_TOTAL):
        if _is_null_row(i):
            assert_true(
                mask.is_null(i),
                "NULL ~ '_dog$' must be NULL at row " + String(i),
            )
        else:
            assert_true(
                not mask.is_null(i),
                "non-null row " + String(i) + " must not be NULL",
            )
            assert_true(
                mask.get(i) == _value_at_row(i).endswith(String("_dog")),
                "mask value at row " + String(i),
            )


def test_null_row_with_out_of_range_code_is_not_resolved() raises:
    """HARDENING. Arrow does not constrain the index value at a NULL slot, and
    `Column.from_dictionary` does not validate it. Pre-fix the materializer
    resolved EVERY row's code against the dictionary payload, so an
    out-of-range code at a null slot was an out-of-bounds read of the dict
    offsets buffer (`dict_offsets_ptr + dict_idx`) — a garbage
    (start, end) pair feeding `memcpy`. Post-fix a null row's code is never
    dereferenced."""
    comptime int32_size = 4
    var buf = OwnedAlignedBuffer(_N_TOTAL * int32_size)
    for i in range(_N_TOTAL):
        # Null slots carry a wildly out-of-range placeholder.
        var c = 1_000_003 if _is_null_row(i) else _code_at(i)
        buf.set_typed[Scalar[DType.int32]](i, Int32(c))
    buf.set_length(_N_TOTAL * int32_size)
    var idx = PrimitiveArray[DType.int32](
        buf^,
        _N_TOTAL,
        Optional[Bitmap[HeapRegion]](_validity_for_rows(_N_TOTAL)),
        _null_count_for_rows(_N_TOTAL),
        0,
    )
    var col = Column.from_dictionary(
        StringDictionaryArray(
            idx^, StringArray.from_strings(_dict_values()), _N_TOTAL
        )
    )
    var arr = _materialize_dict_to_string(col)
    _assert_nulls(arr, 0, _N_TOTAL, String("oob-null-code dict"))
    _assert_values(arr, 0, _N_TOTAL, String("oob-null-code dict"))


# =============================================================================
# DEFECT 2 — code byte width
# =============================================================================


def test_dict_materialize_int64_codes() raises:
    var col = _plain_int64_dict_column()
    var arr = _materialize_dict_to_string(col)
    _assert_values(arr, 0, _N_TOTAL, String("int64 dict @ offset 0"), False)


def test_dict_materialize_int64_codes_honor_offset() raises:
    """The code window for an Int64-indexed column is
    `[_offset * 8, (_offset + _length) * 8)` — an `_offset * 4` byte skip is a
    HALF-window skip, so this also pins that the offset fix scales with the
    code width."""
    var full = _plain_int64_dict_column()
    var col = full.slice(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    _assert_values(
        arr, _WIN_START, _WIN_LEN, String("int64 dict @ window"), False
    )


def test_dict_materialize_int64_codes_with_nulls() raises:
    """Both defects at once — the `fast_fields._materialize_keyword` shape."""
    var col = _nullable_int64_dict_column()
    var arr = _materialize_dict_to_string(col)
    _assert_nulls(arr, 0, _N_TOTAL, String("int64 nullable dict"))
    _assert_values(arr, 0, _N_TOTAL, String("int64 nullable dict"))


def test_dict_materialize_int64_codes_with_nulls_sliced() raises:
    var full = _nullable_int64_dict_column()
    var col = full.slice(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    _assert_nulls(arr, _WIN_START, _WIN_LEN, String("int64 nullable dict @ window"))
    _assert_values(arr, _WIN_START, _WIN_LEN, String("int64 nullable dict @ window"))


# =============================================================================
# Control — today's corpus shape must be byte-identical
# =============================================================================


def test_plain_int32_dict_control() raises:
    """Non-nullable Int32 codes at `_offset == 0`: the shape every corpus cell
    produces. Must be unchanged by both fixes — no validity attached, all rows
    resolved."""
    var col = _plain_int32_dict_column()
    var arr = _materialize_dict_to_string(col)
    assert_equal(arr.length, _N_TOTAL, "control: length")
    assert_equal(arr.null_count, 0, "control: null_count")
    assert_true(not arr.validity, "control: no validity bitmap attached")
    for j in range(_N_TOTAL):
        assert_equal(
            arr.get(j), _dict_value(_code_at(j)), "control: row " + String(j)
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_fixture_is_null_bearing_and_discriminating]()
    suite.test[test_dict_materialize_carries_validity]()
    suite.test[test_dict_materialize_validity_honors_offset]()
    suite.test[test_regexp_like_over_nullable_dict_propagates_null]()
    suite.test[test_dict_materialize_int64_codes]()
    suite.test[test_dict_materialize_int64_codes_honor_offset]()
    suite.test[test_dict_materialize_int64_codes_with_nulls]()
    suite.test[test_dict_materialize_int64_codes_with_nulls_sliced]()
    suite.test[test_plain_int32_dict_control]()
    # Registered LAST on purpose: pre-fix this case SIGSEGVs (the out-of-range
    # placeholder code at a null slot indexes the dict offsets buffer out of
    # bounds), and a crash kills the process before TestSuite flushes the
    # earlier results.
    suite.test[test_null_row_with_out_of_range_code_is_not_resolved]()
    suite^.run()
