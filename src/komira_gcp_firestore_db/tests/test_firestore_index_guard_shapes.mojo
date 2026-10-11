# =============================================================================
# test_firestore_index_guard_shapes.mojo — the index guard's pieces, each
#   against an exact answer: the shape a filter + order derives, its
#   rendering in the refusal message, which shapes need a composite index,
#   and, field by field, why a declared index does or does not serve a shape.
#   Plus the declaration-table parser's malformed lines and the value copies.
#   Pure functions only: no driver, no mock.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true, assert_false

from komira_db import DbValue, Pred, Filter, Order

from komira_gcp_firestore_db import (
    DeclaredIndex,
    DeclaredIndexField,
    DeclaredIndexSet,
    QueryIndexShape,
    query_index_shape,
    needs_composite_index,
    declared_set_serves,
    require_declared_index,
)
from komira_gcp_firestore_db.firestore_index_guard import _same_set


def _f(col: String, desc: Bool = False, contains: Bool = False) -> DeclaredIndexField:
    return DeclaredIndexField(String(col), desc, contains)


def _set1(coll: String, var a: DeclaredIndexField) -> DeclaredIndexSet:
    var fs = List[DeclaredIndexField]()
    fs.append(a^)
    var out = DeclaredIndexSet()
    out.declare(DeclaredIndex(String(coll), fs^))
    return out^


def _set2(
    coll: String, var a: DeclaredIndexField, var b: DeclaredIndexField
) -> DeclaredIndexSet:
    var fs = List[DeclaredIndexField]()
    fs.append(a^)
    fs.append(b^)
    var out = DeclaredIndexSet()
    out.declare(DeclaredIndex(String(coll), fs^))
    return out^


def _strs(a: String, b: String) -> List[String]:
    """[a] when `b` is empty, else [a, b]."""
    var out = List[String]()
    out.append(String(a))
    if b.byte_length() > 0:
        out.append(String(b))
    return out^


def _v() -> DbValue:
    return DbValue.text("v")


def _shape(var preds: List[Pred], var order: List[Order]) -> QueryIndexShape:
    return query_index_shape(Filter.all_of(preds^), order)


# =============================================================================
# 1. The shape, its description and the index it needs.
# =============================================================================
def test_shape_description_and_required_index() raises:
    var p = List[Pred]()
    p.append(Pred.eq(String("a"), _v()))
    p.append(Pred.eq(String("b"), _v()))
    p.append(Pred.lt(String("r"), _v()))
    p.append(Pred.array_contains(String("t"), _v()))
    var in_vals = List[DbValue]()
    in_vals.append(_v())
    p.append(Pred.in_list(String("x"), in_vals^))  # never on the wire
    var o = List[Order]()
    o.append(Order.asc(String("a")))  # pinned by the equality: free
    o.append(Order.descending(String("r")))
    var s = _shape(p^, o^)
    assert_equal(
        s.describe(),
        String("a == AND b == AND r <range> AND t array-contains ORDER BY r DESC"),
    )
    assert_equal(s.required_index(), String("(a ASC, b ASC, t CONTAINS, r DESC)"))
    assert_true(needs_composite_index(s))
    var c = s.copy()
    assert_equal(c.describe(), s.describe(), "a copy describes the same shape")
    assert_equal(c.required_index(), s.required_index())

    # A range on a field an equality already pins adds no index field.
    var q = List[Pred]()
    q.append(Pred.eq(String("a"), _v()))
    q.append(Pred.lt(String("a"), _v()))
    q.append(Pred.lt(String("r"), _v()))
    var s2 = _shape(q^, List[Order]())
    assert_equal(s2.describe(), String("a == AND a <range> AND r <range>"))
    assert_equal(s2.required_index(), String("(a ASC, r ASC)"))

    # No filter, two order terms.
    var o2 = List[Order]()
    o2.append(Order.asc(String("x")))
    o2.append(Order.descending(String("y")))
    var s3 = _shape(List[Pred](), o2^)
    assert_equal(s3.describe(), String("<no filter> ORDER BY x ASC, y DESC"))
    assert_equal(s3.required_index(), String("(x ASC, y DESC)"))
    assert_true(needs_composite_index(s3), "two ordered fields need a composite")

    # The refusal names the collection, the shape and the index.
    var r = List[Pred]()
    r.append(Pred.eq(String("a"), _v()))
    r.append(Pred.array_contains(String("t"), _v()))
    with assert_raises(contains="WHERE a == AND t array-contains` cannot"):
        require_declared_index(DeclaredIndexSet(), String("c"), Filter.all_of(r.copy()), List[Order]())
    with assert_raises(contains="Declare c (a ASC, t CONTAINS) in the"):
        require_declared_index(DeclaredIndexSet(), String("c"), Filter.all_of(r^), List[Order]())
    print("    [PASS] shape, description and required index")


# =============================================================================
# 2. needs_composite_index: the array-membership and range clauses.
# =============================================================================
def test_needs_composite_index_clauses() raises:
    var one = List[Pred]()
    one.append(Pred.array_contains(String("t"), _v()))
    assert_false(needs_composite_index(_shape(one.copy(), List[Order]())), "array alone")

    var two = one.copy()
    two.append(Pred.array_contains(String("u"), _v()))
    assert_true(needs_composite_index(_shape(two^, List[Order]())), "two arrays")

    var with_range = one.copy()
    with_range.append(Pred.lt(String("r"), _v()))
    assert_true(needs_composite_index(_shape(with_range^, List[Order]())), "array + range")

    var o = List[Order]()
    o.append(Order.asc(String("z")))
    assert_true(needs_composite_index(_shape(one^, o.copy())), "array + order")

    var rng = List[Pred]()
    rng.append(Pred.lt(String("r"), _v()))
    assert_true(
        needs_composite_index(_shape(rng.copy(), o^)), "a range ordered by another field"
    )
    var same = List[Order]()
    same.append(Order.asc(String("r")))
    assert_false(
        needs_composite_index(_shape(rng^, same^)), "a range ordered by itself is free"
    )
    print("    [PASS] needs_composite_index clauses")


# =============================================================================
# 3. _index_serves, one reason per case, through declared_set_serves.
# =============================================================================
def test_why_a_declared_index_does_or_does_not_serve() raises:
    # eq a + range r, no ORDER BY: the ranges are matched as a set.
    var p = List[Pred]()
    p.append(Pred.eq(String("a"), _v()))
    p.append(Pred.lt(String("r"), _v()))
    var s = _shape(p^, List[Order]())
    var c = String("c")
    assert_true(declared_set_serves(_set2(c, _f("a"), _f("r")), c, s))
    assert_false(
        declared_set_serves(_set2(String("other"), _f("a"), _f("r")), c, s),
        "an index of another collection",
    )
    assert_false(declared_set_serves(_set1(c, _f("a")), c, s), "too few fields")
    assert_false(
        declared_set_serves(_set2(c, _f("a", contains=True), _f("r")), c, s),
        "an array key in the equality prefix",
    )
    assert_false(declared_set_serves(_set2(c, _f("b"), _f("r")), c, s), "other equality")
    assert_false(
        declared_set_serves(_set2(c, _f("a"), _f("r", contains=True)), c, s),
        "an array key for a range",
    )
    assert_false(declared_set_serves(_set2(c, _f("a"), _f("q")), c, s), "other range")

    # eq a + array t: position and key mode both matter.
    var q = List[Pred]()
    q.append(Pred.eq(String("a"), _v()))
    q.append(Pred.array_contains(String("t"), _v()))
    var sa = _shape(q^, List[Order]())
    assert_true(declared_set_serves(_set2(c, _f("a"), _f("t", contains=True)), c, sa))
    assert_false(
        declared_set_serves(_set2(c, _f("a"), _f("u", contains=True)), c, sa),
        "another array field",
    )
    assert_false(
        declared_set_serves(_set2(c, _f("a"), _f("t")), c, sa), "an ordered key for an array"
    )

    # eq a + ORDER BY o.
    var o = List[Order]()
    o.append(Order.asc(String("o")))
    var e = List[Pred]()
    e.append(Pred.eq(String("a"), _v()))
    var so = _shape(e^, o^)
    assert_true(declared_set_serves(_set2(c, _f("a"), _f("o")), c, so))
    assert_false(declared_set_serves(_set1(c, _f("a")), c, so), "no field for the order")
    assert_false(
        declared_set_serves(_set2(c, _f("a"), _f("o", contains=True)), c, so),
        "an array key for the order",
    )

    assert_false(_same_set(_strs("a", ""), _strs("a", "b")), "sizes differ")
    assert_true(_same_set(_strs("b", "a"), _strs("a", "b")), "order does not matter")
    print("    [PASS] each reason a declared index does or does not serve")


# =============================================================================
# 4. A pushed multi-field OR is out of the guard's scope: not refused.
# =============================================================================
def test_a_disjunction_is_not_judged() raises:
    var p = List[Pred]()
    p.append(Pred.eq(String("a"), _v()))
    p.append(Pred.lt(String("r"), _v()))
    var o = List[Order]()
    o.append(Order.asc(String("z")))
    require_declared_index(DeclaredIndexSet(), String("c"), Filter.any_of(p.copy()), o.copy())
    # The same shape as a conjunction IS refused.
    with assert_raises(contains="UNDECLARED COMPOSITE INDEX"):
        require_declared_index(DeclaredIndexSet(), String("c"), Filter.all_of(p^), o^)
    print("    [PASS] a disjunction is not judged")


# =============================================================================
# 5. The declaration table's malformed lines, and the value copies.
# =============================================================================
def test_table_malformed_lines_and_copies() raises:
    var t = String("a|x:A\nnopipe\nb|y\nc|z:D|w:C")
    var lenient = DeclaredIndexSet.parse_table_lenient(t)
    assert_equal(lenient.__len__(), 2, "a pipe-less line and a colon-less field are skipped")
    assert_equal(lenient.indexes[0].collection, String("a"))
    assert_equal(lenient.indexes[1].collection, String("c"))

    var strict = DeclaredIndexSet.parse_table(String("nopipe\na|x:A"))
    assert_equal(strict.__len__(), 1, "the strict parse skips a pipe-less line too")
    with assert_raises(contains="malformed field 'y' (want `col:A|D|C`)"):
        _ = DeclaredIndexSet.parse_table(t)

    var copy = lenient.copy()
    lenient.declare_asc(String("d"), String("p"), String("q"))
    lenient.indexes[1].fields[0].col = String("changed")
    assert_equal(copy.__len__(), 2, "a copy is independent of later declarations")
    assert_equal(copy.indexes[1].collection, String("c"))
    assert_equal(len(copy.indexes[1].fields), 2)
    assert_equal(copy.indexes[1].fields[0].col, String("z"), "a deep copy")
    assert_true(copy.indexes[1].fields[0].desc)
    assert_false(copy.indexes[1].fields[0].array_contains)
    assert_equal(copy.indexes[1].fields[1].col, String("w"))
    assert_false(copy.indexes[1].fields[1].desc)
    assert_true(copy.indexes[1].fields[1].array_contains)
    print("    [PASS] malformed table lines and copies")


def main() raises:
    test_shape_description_and_required_index()
    test_needs_composite_index_clauses()
    test_why_a_declared_index_does_or_does_not_serve()
    test_a_disjunction_is_not_judged()
    test_table_malformed_lines_and_copies()
    print("PASS test_firestore_index_guard_shapes")
