# =============================================================================
# test_udf_apply_expr.mojo — `UdfType`, its `Field` bridge, `EXPR_UDF_APPLY`
# and `AGG_UDF` (docs/design/optimized_plan_udfs.md §10.3-§10.5)
# =============================================================================
#
# Each test names the defect it catches. The render tests matter beyond
# display: an expression's render is plan identity (`structural_hash` is
# FNV-1a over it), so a fact the render leaves out lets two different calls
# share a compiled plan.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_UDF
from komira_plan_expr.expr import Expr, EXPR_UDF_APPLY, EXPR_TAG_COUNT, expr_tag_name
from komira_plan_expr.expr_walk import (
    PlanColRefFields,
    ordered_name_sink,
    walk_expr_column_refs,
    walk_expr_field,
)
from komira_plan_expr.udf_type import UdfType, udf_type_same
from komira_plan_expr.udf_type_field import field_to_udf_type, udf_type_to_field


def _leaf(name: String, t: ArrowType) -> UdfType:
    return UdfType(name, t, Field(name, t, True).dtype, True)


def _full() -> UdfType:
    """Every fact set, and a child with a grandchild."""
    var gkids = List[UdfType]()
    gkids.append(_leaf("g", ArrowType.FLOAT32))
    var kid = UdfType("c", ArrowType.LIST, Field("c", ArrowType.LIST, True).dtype, False, gkids^)
    var kids = List[UdfType]()
    kids.append(kid^)
    kids.append(_leaf("d", ArrowType.INT64))
    var t = UdfType("s", ArrowType.STRUCT, Field("s", ArrowType.STRUCT, True).dtype, True, kids^)
    t.decimal_precision = 18
    t.decimal_scale = 4
    t.tz = "UTC"
    t.dict_index_type = ArrowType.INT32
    t.union_type_ids = [3, 5]
    t.flags = 9
    t.metadata_keys = ["unit"]
    t.metadata_values = ["cents"]
    return t^


def _text(t: UdfType) -> String:
    var out = String()
    t.write_to(out)
    return out^


# ---- UdfType ----------------------------------------------------------------------


def test_copy_is_deep_and_keeps_every_fact() raises:
    """Defect: a `copy()` that drops a fact or shares children with the
    original (an edit of the copy's child would then change the original)."""
    var t = _full()
    var c = t.copy()
    assert_true(udf_type_same(c, t, True), "the copy differs from the original")
    assert_equal(_text(c), _text(t), "render of the copy")
    c.children[0].children[0].name = "changed"
    assert_equal(t.children[0].children[0].name, "g", "the copy shares its grandchild")


def test_depth() raises:
    """Defect: a depth that counts the widest level instead of the deepest."""
    assert_equal(_leaf("x", ArrowType.INT64).depth(), 1, "a leaf")
    assert_equal(_full().depth(), 3, "struct<list<float32>, int64>")


def test_render_shows_every_fact() raises:
    """Defect: a render that leaves a fact out, so two calls differing only in
    it share one plan identity."""
    var base = _text(_full())
    for i in range(9):
        var t = _full()
        if i == 0:
            t.name = "other"
        elif i == 1:
            t.nullable = False
        elif i == 2:
            t.decimal_scale = 5
        elif i == 3:
            t.tz = "Asia/Tokyo"
        elif i == 4:
            t.dict_index_type = ArrowType.INT16
        elif i == 5:
            t.union_type_ids = [3]
        elif i == 6:
            t.flags = 1
        elif i == 7:
            t.metadata_values = ["dollars"]
        else:
            t.children[0].children[0].arrow_type = ArrowType.FLOAT64
        assert_true(_text(t) != base, "fact " + String(i) + " is not rendered")
    var plain = _text(_leaf("x", ArrowType.INT64))
    assert_false("/d" in plain or "/tz" in plain or "<" in plain, "a leaf renders defaults: " + plain)


def test_same_compares_every_fact_and_names_as_asked() raises:
    """Defect: a comparison that ignores a fact, a child name, the child count
    or nullability, or that compares the root name when told not to."""
    var base = _full()
    assert_true(udf_type_same(base, _full(), True), "equal types")
    var renamed = _full()
    renamed.name = "t"
    assert_false(udf_type_same(renamed, base, True), "root name compared when asked")
    assert_true(udf_type_same(renamed, base, False), "root name ignored when not asked")
    for i in range(12):
        var t = _full()
        if i == 0:
            t.arrow_type = ArrowType.LIST
        elif i == 1:
            t.dtype = DType.int8
        elif i == 2:
            t.nullable = False
        elif i == 3:
            t.decimal_precision = 19
        elif i == 4:
            t.tz = ""
        elif i == 5:
            t.flags = 0
        elif i == 6:
            t.decimal_scale = 0
        elif i == 7:
            t.union_type_ids = [3, 6]
        elif i == 8:
            t.metadata_keys = ["scale"]
        elif i == 9:
            _ = t.children.pop()
        elif i == 10:
            t.children[1].name = "e"
        else:
            t.union_type_ids = [3]
        assert_false(udf_type_same(t, base, False), "difference " + String(i) + " not seen")
    var m = _full()
    m.metadata_values = ["dollars"]
    assert_false(udf_type_same(m, base, False), "metadata value not seen")
    var keys = _full()
    keys.metadata_keys = ["unit", "scale"]
    assert_false(udf_type_same(keys, base, False), "a longer metadata key list not seen")


def test_dictionary_index_type_counts_only_on_a_dictionary() raises:
    """Defects: an index-type difference ignored on a DICTIONARY, and one
    counted on any other type (the engine's `Field` defaults it to INT32 on
    every column and a foreign producer writes 0, so the same struct would
    never compare equal to itself across the two)."""
    var d1 = _leaf("d", ArrowType.DICTIONARY)
    d1.dict_index_type = ArrowType.INT32
    var d2 = d1.copy()
    d2.dict_index_type = ArrowType.INT8
    assert_false(udf_type_same(d1, d2, True), "a dictionary's index type not seen")
    var s1 = _full()
    var s2 = _full()
    s2.dict_index_type = ArrowType.NULL
    assert_true(udf_type_same(s1, s2, True), "an index type counted on a struct")


# ---- the Field bridge ----------------------------------------------------------------


def test_field_bridge_is_exact_to_two_levels() raises:
    """Defects: a conversion that drops a fact either way, or flattens a
    child's name, type or nullability."""
    var f = Field("col", ArrowType.STRUCT, False)
    f._child_names = ["a", "b"]
    f._child_types = [ArrowType.INT64.type_id, ArrowType.STRING.type_id]
    f._child_nullables = [True, False]
    f.decimal_precision = 7
    f.decimal_scale = 2
    f._tz = "UTC"
    f._dict_index_type = ArrowType.INT8
    f._union_type_ids = [1]
    f._flags = 4
    f._metadata_keys = ["k"]
    f._metadata_values = ["v"]
    var t = field_to_udf_type(f)
    assert_equal(len(t.children), 2, "children")
    assert_equal(t.children[1].name, "b", "child name")
    assert_equal(Int(t.children[1].arrow_type.type_id), Int(ArrowType.STRING.type_id), "child type")
    assert_false(t.children[1].nullable, "child nullability")
    assert_equal(t.children[0].dtype, Field("a", ArrowType.INT64, True).dtype, "child dtype")
    var back = udf_type_to_field(t)
    assert_equal(back.name, "col", "name")
    assert_false(back.nullable, "nullable")
    assert_equal(back.decimal_precision, 7, "precision")
    assert_equal(back.decimal_scale, 2, "scale")
    assert_equal(back._tz, "UTC", "tz")
    assert_equal(Int(back._dict_index_type.type_id), Int(ArrowType.INT8.type_id), "dict index")
    assert_equal(len(back._union_type_ids), 1, "union ids")
    assert_equal(back._flags, 4, "flags")
    assert_equal(len(back._metadata_values), 1, "metadata values")
    assert_equal(back._metadata_values[0], "v", "metadata")
    assert_equal(len(back._child_names), 2, "flat children")
    assert_equal(back._child_names[1], "b", "flat child name")
    assert_equal(Int(back._child_types[1]), Int(ArrowType.STRING.type_id), "flat child type")
    assert_false(back._child_nullables[1], "flat child nullability")
    assert_true(udf_type_same(field_to_udf_type(back), t, True), "two levels round-trip exactly")


# ---- EXPR_UDF_APPLY ------------------------------------------------------------------


def _call(index: Int, ret: UdfType) -> Expr:
    var args = List[Expr]()
    args.append(Expr.col_ref("a"))
    args.append(Expr.col_ref("b"))
    return Expr.udf_apply(index, ret.copy(), args^)


def test_udf_apply_is_named_and_counted() raises:
    """Defect: a tag added without its name or without growing the count, so
    every walker that sizes itself from `EXPR_TAG_COUNT` skips it."""
    assert_equal(Int(EXPR_UDF_APPLY), 27, "the design's engine tag")
    assert_equal(EXPR_TAG_COUNT, 28, "the count covers the new tag")
    assert_equal(expr_tag_name(EXPR_UDF_APPLY), "EXPR_UDF_APPLY", "its name")


def test_udf_apply_copy_and_accessors() raises:
    """Defect: a copy that drops the index, the type or an argument."""
    var e = _call(3, _full())
    var c = e.copy()
    assert_equal(Int(c.tag), Int(EXPR_UDF_APPLY), "tag")
    assert_equal(c.udf_apply_index(), 3, "index")
    assert_equal(c.udf_apply_num_args(), 2, "argument count")
    assert_equal(c.udf_apply_arg_ref(1).col_ref_name(), "b", "argument 1")
    assert_true(udf_type_same(c.udf_apply_return_type_ref(), _full(), True), "return type")


def test_udf_apply_render_is_identity() raises:
    """Defect: a render without the index, the type, the argument count or an
    argument, so two different calls share one compiled plan."""
    var base = String(_call(3, _full()))
    assert_true(String(_call(4, _full())) != base, "the index is not rendered")
    assert_true(String(_call(3, _leaf("y", ArrowType.FLOAT64))) != base, "the type is not rendered")
    var one = List[Expr]()
    one.append(Expr.col_ref("a"))
    assert_true(String(Expr.udf_apply(3, _full(), one^)) != base, "a dropped argument is not seen")
    assert_true("UdfApply(i=3" in base, base)


def test_walks_reach_the_arguments_and_the_type() raises:
    """Defects: a column walk that skips the arguments (a scan would prune a
    column the call reads) and a field inference that does not return the
    call's type (the output column would be typed null)."""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(_call(0, _full()), sink)
    assert_equal(len(names), 2, "argument columns")
    assert_equal(names[1], "b", "argument 1's column")
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var missing = String("")
    var f = walk_expr_field[PlanColRefFields](_call(0, _full()), sb.build(), missing)
    assert_equal(Int(f.arrow_type.type_id), Int(ArrowType.STRUCT.type_id), "the call's type")
    assert_equal(f.name, "s", "the type's name")
    assert_equal(len(f._child_names), 2, "its first level of children")


def test_agg_udf_renders_by_name() raises:
    """Defect: AGG_UDF rendering as UNKNOWN, so two aggregates share a plan
    identity with any other unnamed function."""
    var a = AggExpr(AGG_UDF, Optional(_call(0, _leaf("p95", ArrowType.FLOAT64))), None)
    var s = String(a)
    assert_true("UDF(" in s, s)
    assert_equal(Int(AGG_UDF), 37, "the design's engine tag")


def main() raises:
    var suite = TestSuite()
    suite.test[test_copy_is_deep_and_keeps_every_fact]()
    suite.test[test_depth]()
    suite.test[test_render_shows_every_fact]()
    suite.test[test_same_compares_every_fact_and_names_as_asked]()
    suite.test[test_dictionary_index_type_counts_only_on_a_dictionary]()
    suite.test[test_field_bridge_is_exact_to_two_levels]()
    suite.test[test_udf_apply_is_named_and_counted]()
    suite.test[test_udf_apply_copy_and_accessors]()
    suite.test[test_udf_apply_render_is_identity]()
    suite.test[test_walks_reach_the_arguments_and_the_type]()
    suite.test[test_agg_udf_renders_by_name]()
    suite^.run()
