# =============================================================================
# test_dict_materialize_offset_honoring — the DICTIONARY string-op materializer
# must honor `Column._offset`
# =============================================================================
#
# REGRESSION GUARD for a SILENT-WRONG-ANSWER defect.
# Sibling of `tests/test_in_list_offset_honoring.mojo` (same defect class,
# different kernel family).
#
# ROOT CAUSE (pre-fix): `_materialize_dict_to_string` in
# `komira_compiler/compiler_eval_dict.mojo` took its per-row CODE pointer from
# `col._data.view_ro` — a view over the WHOLE int32 code buffer starting at
# BYTE 0 — and then read `(idx_ptr + i)[]` for `i in [0, col._length)`.
# `col._offset` was referenced NOWHERE in the function. Every other DICTIONARY
# code accessor on Column (`dict_code_at`, `string_dict_code_at`,
# `as_dictionary`) indexes `self._offset + row`, so this one violated the
# column's own contract.
#
# WHY IT IS LIVE: `ArrowType.DICTIONARY` IS on the `supports_zero_copy_slice`
# whitelist, `Column.slice` Arc-shares every buffer and carries `_offset > 0`,
# and `split_record_batch` Arc-reslices UNCONDITIONALLY (there is no switch
# to turn it off). So any
# mid-stream morsel of a dictionary-encoded string column arrives with
# `_offset > 0`, and the four string-op call sites
# (`compiler_eval_predicate.mojo` LIKE / CONTAINS / STARTS_WITH / ENDS_WITH,
# `compiler_eval_column.mojo` regexp_*) pass that RAW column straight in.
# Pre-fix the materializer resolved the codes of rows `[0, length)` instead of
# `[_offset, _offset+length)` -> WRONG dictionary entries -> WRONG STRINGS ->
# wrong predicate mask, silently, with no raise.
#
# FAILS ON CURRENT CODE (pre-fix): every fixture below builds a 24-row
# dictionary column and takes the window `[5, 18)` via `Column.slice` (so
# `_offset == 5`, `_length == 13`). The per-row code ladder is
# `code(i) = (3*i + 1) % 7`; because `3*5 = 15` is NOT `0 (mod 7)`, the
# offset-blind window `codes[0..13)` and the correct window `codes[5..18)`
# differ at EVERY row, and all 7 dictionary entries are distinct strings — so
# pre-fix the resolved string is wrong on every single row and the predicate
# masks differ too.
#
# The `*_offset_zero_control` cases pin that the fix is a NO-OP at
# `_offset == 0` (today's non-sliced shape) — they pass both pre- and post-fix.
#
# INDEPENDENT ORACLE: expected values are computed in this file from the
# ABSOLUTE row index (`_value_at_row(start + j)`) via the ladder + the stdlib
# `String.find` / `startswith` / `endswith`, never by re-reading whatever
# pointer base the code under test happened to use. So the file is a live guard
# regardless of how the materializer is implemented.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion

from komira_core.eval.regexp_functions import eval_regexp_like
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.string_comparison import (
    eval_string_contains,
    eval_string_ends_with,
    eval_string_like,
    eval_string_starts_with,
)

from komira_compiler.compiler_eval_dict import _materialize_dict_to_string


# =============================================================================
# Fixture shape
# =============================================================================
#
# 24 absolute rows over a 7-entry dictionary; the logical window is
# [_WIN_START, _WIN_START + _WIN_LEN). `_WIN_START == 5` is deliberately not a
# multiple of the dictionary period, so the offset-blind and correct windows
# disagree on every row.

comptime _N_TOTAL = 24
comptime _WIN_START = 5
comptime _WIN_LEN = 13
comptime _DICT_SIZE = 7


def _dict_value(e: Int) -> String:
    """Dictionary entry `e`. All 7 entries are distinct; the `_cat` / `_dog` /
    `_cow` suffix makes the CONTAINS / ENDS_WITH / LIKE oracles non-trivial."""
    if e % 3 == 0:
        return String("v") + String(e) + String("_cat")
    if e % 3 == 1:
        return String("v") + String(e) + String("_dog")
    return String("v") + String(e) + String("_cow")


def _code_at(i: Int) -> Int:
    """Per-row dictionary CODE at ABSOLUTE row `i`."""
    return (i * 3 + 1) % _DICT_SIZE


def _value_at_row(i: Int) -> String:
    """The string the column logically holds at ABSOLUTE row `i`."""
    return _dict_value(_code_at(i))


def _full_dict_column() raises -> Column[HeapRegion]:
    """A 24-row DICTIONARY(string) Column, `_offset == 0`."""
    var codes = List[Int32]()
    for i in range(_N_TOTAL):
        codes.append(Int32(_code_at(i)))
    var dict_vals = List[String]()
    for e in range(_DICT_SIZE):
        dict_vals.append(_dict_value(e))
    return Column.from_dictionary(
        StringDictionaryArray(
            PrimitiveArray[DType.int32].from_list(codes),
            StringArray.from_strings(dict_vals),
            _N_TOTAL,
        )
    )


def _window_col(start: Int, length: Int) raises -> Column[HeapRegion]:
    """The zero-copy row window `[start, start+length)` of the 24-row dict
    column — exactly the shape `split_record_batch` produces by default
    (Arc-share + `_offset = start`)."""
    var full = _full_dict_column()
    return full.slice(start, length)


# =============================================================================
# Oracles (independent of the code under test)
# =============================================================================


def _assert_values(
    imm arr: StringArray[HeapRegion],
    start: Int,
    length: Int,
    label: String,
) raises:
    """Assert the materialized StringArray equals the ABSOLUTE row values."""
    assert_equal(arr.length, length, label + ": length")
    for j in range(length):
        var want = _value_at_row(start + j)
        var got = arr.get(j)
        assert_equal(
            got,
            want,
            label
            + ": row "
            + String(j)
            + " (abs row "
            + String(start + j)
            + ")",
        )


def _assert_mask(
    imm got: BooleanArray,
    start: Int,
    length: Int,
    imm want: List[Bool],
    label: String,
) raises:
    assert_equal(got.length, length, label + ": mask length")
    for j in range(length):
        assert_true(
            got.get(j) == want[j],
            label
            + ": row "
            + String(j)
            + " (abs row "
            + String(start + j)
            + ", val "
            + _value_at_row(start + j)
            + ", want "
            + String(want[j])
            + ", got "
            + String(got.get(j))
            + ")",
        )


def _oracle_contains(start: Int, length: Int, needle: String) -> List[Bool]:
    var out = List[Bool]()
    for j in range(length):
        out.append(_value_at_row(start + j).find(needle) != -1)
    return out^


def _oracle_starts_with(start: Int, length: Int, prefix: String) -> List[Bool]:
    var out = List[Bool]()
    for j in range(length):
        out.append(_value_at_row(start + j).startswith(prefix))
    return out^


def _oracle_ends_with(start: Int, length: Int, suffix: String) -> List[Bool]:
    var out = List[Bool]()
    for j in range(length):
        out.append(_value_at_row(start + j).endswith(suffix))
    return out^


# =============================================================================
# 0. Fixture self-check — the window really does carry `_offset > 0`, and the
#    two windows really do disagree (so the guard cannot be vacuous).
# =============================================================================


def test_fixture_window_is_offset_bearing_and_discriminating() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    assert_equal(col.arrow_type, ArrowType.DICTIONARY, "fixture arrow_type")
    assert_equal(col.offset(), _WIN_START, "fixture must carry _offset > 0")
    assert_equal(col.length(), _WIN_LEN, "fixture window length")
    # Column's own offset-honoring code accessor agrees with the ladder.
    for j in range(_WIN_LEN):
        assert_equal(
            col.string_dict_code_at(j),
            _code_at(_WIN_START + j),
            "string_dict_code_at honors _offset",
        )
    # The offset-blind window differs from the correct one at EVERY row.
    for j in range(_WIN_LEN):
        assert_true(
            _value_at_row(j) != _value_at_row(_WIN_START + j),
            "windows must disagree at row " + String(j),
        )


# =============================================================================
# 1. Materialized VALUES — the direct read of the defect
# =============================================================================


def test_dict_materialize_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    _assert_values(
        arr, _WIN_START, _WIN_LEN, String("dict materialize @ offset 5")
    )


def test_dict_materialize_offset_zero_control() raises:
    var col = _window_col(0, _WIN_LEN)
    assert_equal(col.offset(), 0, "control fixture offset")
    var arr = _materialize_dict_to_string(col)
    _assert_values(
        arr, 0, _WIN_LEN, String("dict materialize @ offset 0 (control)")
    )


# =============================================================================
# 2. CONTAINS / STARTS_WITH / ENDS_WITH — `compiler_eval_predicate.mojo:1493`
# =============================================================================


def test_dict_contains_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_contains(arr, String("cat"))
    _assert_mask(
        mask,
        _WIN_START,
        _WIN_LEN,
        _oracle_contains(_WIN_START, _WIN_LEN, String("cat")),
        String("dict CONTAINS 'cat' @ offset 5"),
    )


def test_dict_contains_offset_zero_control() raises:
    var col = _window_col(0, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_contains(arr, String("cat"))
    _assert_mask(
        mask,
        0,
        _WIN_LEN,
        _oracle_contains(0, _WIN_LEN, String("cat")),
        String("dict CONTAINS 'cat' @ offset 0 (control)"),
    )


def test_dict_starts_with_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_starts_with(arr, String("v1"))
    _assert_mask(
        mask,
        _WIN_START,
        _WIN_LEN,
        _oracle_starts_with(_WIN_START, _WIN_LEN, String("v1")),
        String("dict STARTS_WITH 'v1' @ offset 5"),
    )


def test_dict_ends_with_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_ends_with(arr, String("dog"))
    _assert_mask(
        mask,
        _WIN_START,
        _WIN_LEN,
        _oracle_ends_with(_WIN_START, _WIN_LEN, String("dog")),
        String("dict ENDS_WITH 'dog' @ offset 5"),
    )


# =============================================================================
# 3. LIKE — the memmem fast-path shape (`%lit%`) AND a prefix
#    pattern. Both route through `_materialize_dict_to_string` FIRST: the
#    fastpath lives INSIDE `_string_like_kernel`, which takes an already-
#    materialized StringArray, so it does NOT bypass this defect.
# =============================================================================


def test_dict_like_contains_pattern_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_like(arr, String("%cat%"))
    _assert_mask(
        mask,
        _WIN_START,
        _WIN_LEN,
        _oracle_contains(_WIN_START, _WIN_LEN, String("cat")),
        String("dict LIKE '%cat%' @ offset 5"),
    )


def test_dict_like_prefix_pattern_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_like(arr, String("v2%"))
    _assert_mask(
        mask,
        _WIN_START,
        _WIN_LEN,
        _oracle_starts_with(_WIN_START, _WIN_LEN, String("v2")),
        String("dict LIKE 'v2%' @ offset 5"),
    )


def test_dict_like_offset_zero_control() raises:
    var col = _window_col(0, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var mask = eval_string_like(arr, String("%cat%"))
    _assert_mask(
        mask,
        0,
        _WIN_LEN,
        _oracle_contains(0, _WIN_LEN, String("cat")),
        String("dict LIKE '%cat%' @ offset 0 (control)"),
    )


# =============================================================================
# 4. regexp_like — `compiler_eval_column.mojo:1868 / :1929`
# =============================================================================


def test_dict_regexp_like_honors_offset() raises:
    var col = _window_col(_WIN_START, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var prog = RegexProgram.compile(String("^v[0-2]_"), String(""))
    var mask = eval_regexp_like(arr, prog)

    # Independent oracle: "^v[0-2]_" matches iff the value starts with one of
    # "v0_" / "v1_" / "v2_".
    var want = List[Bool]()
    for j in range(_WIN_LEN):
        var v = _value_at_row(_WIN_START + j)
        want.append(
            v.startswith(String("v0_"))
            or v.startswith(String("v1_"))
            or v.startswith(String("v2_"))
        )
    _assert_mask(
        mask, _WIN_START, _WIN_LEN, want, String("dict REGEXP '^v[0-2]_' @ offset 5")
    )


def test_dict_regexp_like_offset_zero_control() raises:
    var col = _window_col(0, _WIN_LEN)
    var arr = _materialize_dict_to_string(col)
    var prog = RegexProgram.compile(String("^v[0-2]_"), String(""))
    var mask = eval_regexp_like(arr, prog)

    var want = List[Bool]()
    for j in range(_WIN_LEN):
        var v = _value_at_row(j)
        want.append(
            v.startswith(String("v0_"))
            or v.startswith(String("v1_"))
            or v.startswith(String("v2_"))
        )
    _assert_mask(
        mask, 0, _WIN_LEN, want, String("dict REGEXP '^v[0-2]_' @ offset 0 (control)")
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_fixture_window_is_offset_bearing_and_discriminating]()
    suite.test[test_dict_materialize_honors_offset]()
    suite.test[test_dict_materialize_offset_zero_control]()
    suite.test[test_dict_contains_honors_offset]()
    suite.test[test_dict_contains_offset_zero_control]()
    suite.test[test_dict_starts_with_honors_offset]()
    suite.test[test_dict_ends_with_honors_offset]()
    suite.test[test_dict_like_contains_pattern_honors_offset]()
    suite.test[test_dict_like_prefix_pattern_honors_offset]()
    suite.test[test_dict_like_offset_zero_control]()
    suite.test[test_dict_regexp_like_honors_offset]()
    suite.test[test_dict_regexp_like_offset_zero_control]()
    suite^.run()
