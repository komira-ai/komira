# =============================================================================
# test_string_col_share_read_in_place — string predicates and string functions
# read a plain STRING column IN PLACE instead of copying it
# =============================================================================
#
# WHAT CHANGED (`bench/results/worst10_0923/PLAN.md` §2 G). Three copies of the
# whole string column fed kernels that only READ it:
#   L1  `_eval_predicate`'s string arms called `Column.as_string` (a memcpy of
#       offsets + data + validity). They now call `string_array_of`, which
#       Arc-shares where `can_share_as_string` holds.
#   L2  a string function over a COLUMN REFERENCE child evaluated the child
#       through `_eval_column_expr` -> `copy_column` and THEN `as_string` —
#       two copies. `try_share_string_col_ref` replaces the pair with one share
#       where that is provably equal.
#
# The swap must be invisible: same values, same NULLs, same validity LAYOUT.
#
# WHAT THIS FILE PINS
#   A1  `string_array_of` ALIASES a shareable column (a write through a retained
#       third handle is visible through it) and equals `as_string`
#       field-for-field.
#   A2  `try_share_string_col_ref` ALIASES the batch column for a bare col-ref,
#       and equals the `copy_column(...).as_string` pair it replaces —
#       including the one normalisation it must mirror: `copy_column` DROPS an
#       all-valid bitmap (null_count == 0), so the share must too.
#   A3  it keeps a bitmap that carries real NULLs, bit-for-bit.
#   A4  it DECLINES (returns None) for a non-column child and for a column whose
#       offsets do not start at 0 (`copy_column` rebases those, a share would
#       not), and the string function still answers correctly there.
#   A5  end to end: `length` / `strlen` / `upper` / `substring` over a col-ref
#       are value-identical to the expected answers, and `length` over an
#       all-valid-bitmap column comes out with NO validity bitmap (the layout
#       the copy path produced).
#   A6  end to end: `<> ''` and LIKE predicates give the SQL three-valued answer
#       over a column with NULLs (NULL -> data bit 0 AND validity bit 0).
#
# MUTATIONS (each verified RED by hand before landing):
#   M1  `string_array_of` returns `col.as_string` unconditionally -> A1 RED
#       (the retained write is not visible: it copied).
#   M2  `try_share_string_col_ref`'s `sa.validity = None` deleted -> A2 RED and
#       A5 RED (the output of `length(s)` grows a validity bitmap).
#   M3  the `project_column_share_eligible` gate deleted -> A4 RED.
#
# Encapsulation: no `UnsafePointer`. The aliasing proof is a write through a
# retained `SharedAlignedBuffer.share` handle, the same witness
# `test_join_key_extract_share_parallel` uses.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_core.arrow.string_array import StringArray
from komira_core.helpers.compiler_helpers import copy_column
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import (
    Expr,
    BIN_NE,
    STR_LIKE,
    STRFN_LENGTH,
    STRFN_STRLEN,
    STRFN_UPPER,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_column import (
    _eval_column_expr,
    string_array_of,
    try_share_string_col_ref,
)
from komira_compiler.compiler_eval_predicate import _eval_predicate


# =============================================================================
# Fixtures
# =============================================================================


def _batch_of(var sa: StringArray[HeapRegion]) raises -> RecordBatch:
    """A one-column batch `s` whose column Arc-SHARES `sa`'s buffers
    (`from_string_shared`), so a handle retained on `sa` before the call
    aliases the batch column."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_string_shared(sa^))
    return rb.build(sb.build())


def _vals() -> List[String]:
    return ["abc", "", "Straße", "😀x", "google.com", "zz"]


def _nullable_sa() raises -> StringArray[HeapRegion]:
    """Rows 1 and 4 NULL (their placeholder bytes are empty)."""
    var valid: List[Bool] = [True, False, True, True, False, True]
    return StringArray.from_strings_with_validity(_vals(), valid)


def _all_valid_bitmap_sa() raises -> StringArray[HeapRegion]:
    """No NULLs, but a validity bitmap IS attached (null_count == 0) — the
    Arrow-legal layout `copy_column`'s Path 2 normalises away."""
    var sa = StringArray.from_strings(_vals())
    sa.validity = Bitmap.create_all_valid(sa.length)
    sa.null_count = 0
    return sa^


def _assert_same_strings(
    got: StringArray[HeapRegion], want: StringArray[HeapRegion], what: String
) raises:
    assert_equal(got.length, want.length, what + ": length")
    assert_equal(got.data_length, want.data_length, what + ": data_length")
    assert_equal(got.null_count, want.null_count, what + ": null_count")
    assert_equal(
        Bool(got.validity), Bool(want.validity), what + ": validity PRESENCE"
    )
    for i in range(want.length):
        assert_equal(got.is_null(i), want.is_null(i), what + ": null @" + String(i))
        if not want.is_null(i):
            assert_equal(got.get(i), want.get(i), what + ": value @" + String(i))


# =============================================================================
# A1 — string_array_of aliases, and equals as_string
# =============================================================================


def test_string_array_of_aliases_and_matches_as_string() raises:
    var sa = _nullable_sa()
    var data_alias = sa.data.share()  # a third owner of the same bytes
    var batch = _batch_of(sa^)
    ref col = batch.column_at(0)

    var want = col.as_string()  # the COPY, taken before the write
    var got = string_array_of(col)
    _assert_same_strings(got, want, "string_array_of vs as_string")

    # Row 0 is "abc" at data byte 0. Write through the retained alias.
    data_alias.write_u8_at(0, UInt8(ord("Z")))
    assert_equal(
        got.get(0), String("Zbc"),
        "string_array_of did NOT alias the column -- it copied (L1 inert)",
    )
    assert_equal(want.get(0), String("abc"), "as_string must stay a copy")
    _ = data_alias^


# =============================================================================
# A2 / A3 — try_share_string_col_ref aliases, and equals copy_column+as_string
# =============================================================================


def test_col_ref_share_aliases_and_drops_an_all_valid_bitmap() raises:
    var sa = _all_valid_bitmap_sa()
    var data_alias = sa.data.share()
    var batch = _batch_of(sa^)

    var want = copy_column(batch, 0).as_string()  # the pair L2 replaces
    assert_false(
        Bool(want.validity),
        "fixture premise: copy_column drops an all-valid bitmap (its Path 2)",
    )
    var got_opt = try_share_string_col_ref(Expr.col_ref(String("s")), batch)
    assert_true(Bool(got_opt), "a bare col-ref over plain STRING must share")
    var got = got_opt.take()
    _assert_same_strings(got, want, "col-ref share vs copy_column+as_string")

    data_alias.write_u8_at(0, UInt8(ord("Z")))
    assert_equal(
        got.get(0), String("Zbc"),
        "try_share_string_col_ref did NOT alias the batch column (L2 inert)",
    )
    _ = data_alias^


def test_col_ref_share_keeps_a_real_null_bitmap() raises:
    var batch = _batch_of(_nullable_sa())
    var want = copy_column(batch, 0).as_string()
    var got_opt = try_share_string_col_ref(Expr.col_ref(String("s")), batch)
    assert_true(Bool(got_opt), "a nullable plain STRING col-ref must share")
    var got = got_opt.take()
    assert_equal(got.null_count, 2, "two NULL rows")
    _assert_same_strings(got, want, "nullable col-ref share vs copy pair")


# =============================================================================
# A4 — the refusals, and the old path still answers there
# =============================================================================


def _offsets_not_at_zero_batch() raises -> RecordBatch:
    """Two rows "abc", "de" whose offsets are [2, 5, 7] over data "xxabcde":
    Arrow-legal, and exactly the layout `copy_column` REBASES (gate 3 of
    `project_column_share_eligible`)."""
    var offs = OwnedAlignedBuffer(12)
    var ol: List[Int32] = [Int32(2), Int32(5), Int32(7)]
    offs.copy_from_int32_list(ol)
    offs.set_length(Int64(12))
    var data = OwnedAlignedBuffer(7)
    var dl: List[UInt8] = [
        UInt8(ord("x")), UInt8(ord("x")), UInt8(ord("a")), UInt8(ord("b")),
        UInt8(ord("c")), UInt8(ord("d")), UInt8(ord("e")),
    ]
    data.copy_from_bytes_list(dl)
    var sa = StringArray[HeapRegion](
        offsets=offs^,
        data=data^,
        validity=None,
        length=2,
        data_length=7,
        null_count=0,
    )
    return _batch_of(sa^)


def test_col_ref_share_declines_where_it_is_not_the_copy() raises:
    var batch = _batch_of(_nullable_sa())
    assert_false(
        Bool(
            try_share_string_col_ref(
                Expr.string_fn(STRFN_UPPER, Expr.col_ref(String("s"))), batch
            )
        ),
        "a non-column child must decline (it is computed, not borrowed)",
    )

    var shifted = _offsets_not_at_zero_batch()
    assert_false(
        Bool(try_share_string_col_ref(Expr.col_ref(String("s")), shifted)),
        "offsets[0] != 0 must decline: copy_column rebases, a share would not",
    )
    # ...and the declined path still answers.
    var out = _eval_column_expr(
        Expr.string_fn(STRFN_LENGTH, Expr.col_ref(String("s"))), shifted
    )
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 3, "length('abc') on the declined path")
    assert_equal(Int(arr.get(1)), 2, "length('de') on the declined path")


# =============================================================================
# A5 — end to end: string functions over a col-ref
# =============================================================================


def test_string_functions_over_col_ref_are_value_identical() raises:
    var batch = _batch_of(_nullable_sa())
    var s = Expr.col_ref(String("s"))
    # rows: "abc", NULL, "Straße", "😀x", NULL, "zz"
    var want_len: List[Int] = [3, -1, 6, 2, -1, 2]
    var want_oct: List[Int] = [3, -1, 7, 5, -1, 2]
    # upper of row 2 ("Straße") is not asserted: whether `ß` maps to "SS"
    # is the case-mapping table's business, not this file's. Every other row
    # has one unambiguous upper-case form.
    var want_up: List[String] = ["ABC", "", "", "😀X", "", "ZZ"]

    var l = _eval_column_expr(Expr.string_fn(STRFN_LENGTH, s.copy()), batch)
    var o = _eval_column_expr(Expr.string_fn(STRFN_STRLEN, s.copy()), batch)
    var la = l.as_primitive[DType.int64]()
    var oa = o.as_primitive[DType.int64]()
    for i in range(6):
        if want_len[i] < 0:
            assert_true(la.is_null(i), "length(NULL) is NULL @" + String(i))
            assert_true(oa.is_null(i), "strlen(NULL) is NULL @" + String(i))
        else:
            assert_equal(Int(la.get(i)), want_len[i], "length @" + String(i))
            assert_equal(Int(oa.get(i)), want_oct[i], "strlen @" + String(i))

    var u = _eval_column_expr(Expr.string_fn(STRFN_UPPER, s.copy()), batch)
    var ua = u.as_string()
    var sub = _eval_column_expr(Expr.substring(s.copy(), 2, 2), batch)
    var suba = sub.as_string()
    var want_sub: List[String] = ["bc", "", "tr", "x", "", "z"]
    for i in range(6):
        if want_len[i] < 0:
            assert_true(ua.is_null(i), "upper(NULL) is NULL @" + String(i))
            assert_true(suba.is_null(i), "substring(NULL) is NULL @" + String(i))
        else:
            if i != 2:
                assert_equal(ua.get(i), want_up[i], "upper @" + String(i))
            assert_equal(suba.get(i), want_sub[i], "substring @" + String(i))


def test_length_over_all_valid_bitmap_column_has_no_validity() raises:
    """The LAYOUT half of the equivalence. Through the copy pair, the child
    reached the kernel with NO bitmap (`copy_column` dropped it), so
    `length(s)` came out non-nullable. The share must reproduce that."""
    var batch = _batch_of(_all_valid_bitmap_sa())
    var out = _eval_column_expr(
        Expr.string_fn(STRFN_LENGTH, Expr.col_ref(String("s"))), batch
    )
    assert_false(
        out.has_validity_buffer(),
        "length(s) over an all-valid-bitmap column grew a validity bitmap:"
        + " the share kept the bitmap copy_column drops (M2)",
    )
    assert_equal(out.null_count(), 0, "no NULLs")


# =============================================================================
# A6 — end to end: string predicates, three-valued
# =============================================================================


def test_string_predicates_over_nullable_column() raises:
    var batch = _batch_of(_nullable_sa())
    # rows: "abc", NULL, "Straße", "😀x", NULL, "zz"
    var ne = _eval_predicate(
        Expr.binary(
            BIN_NE,
            Expr.col_ref(String("s")),
            Expr.literal(ScalarValue.from_string(String(""))),
        ),
        batch,
    )
    var like = _eval_predicate(
        Expr.string_op(STR_LIKE, Expr.col_ref(String("s")), String("%a%")),
        batch,
    )
    var want_ne: List[Bool] = [True, False, True, True, False, True]
    var want_like: List[Bool] = [True, False, True, False, False, False]
    var nulls: List[Bool] = [False, True, False, False, True, False]
    for i in range(6):
        assert_equal(ne.get(i), want_ne[i], "<> '' data bit @" + String(i))
        assert_equal(like.get(i), want_like[i], "LIKE data bit @" + String(i))
        assert_equal(ne.is_null(i), nulls[i], "<> '' UNKNOWN @" + String(i))
        assert_equal(like.is_null(i), nulls[i], "LIKE UNKNOWN @" + String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
