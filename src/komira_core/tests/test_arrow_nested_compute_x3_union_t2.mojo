# =============================================================================
# UnionArray compute kernels.
# =============================================================================
#
# Validates filter / take / hash / equality kernels for UNION_SPARSE +
# UNION_DENSE Columns (beyond the round-trip and the copy_column UNION arm).
#
# Test list:
#   T1: Sparse UNION<Int32, Utf8> — filter by Bitmap.  Filtered column
#       has correct length, types_buf, every child preserved at parent
#       length (sparse invariant).
#   T2: Dense UNION<Int32, Utf8> — filter by Bitmap.  Filtered column
#       has correct length, types_buf, offsets buffer rewritten, child
#       lengths reduced to per-child surviving count.
#   T3: Sparse UNION<Int32, LargeString> — take by index list.  Child
#       indices follow the same indices list as parent (sparse invariant).
#   T4: Dense UNION<Struct, List> — take by index list.  Two-level
#       nesting via _children + per-child sub-index lists.
#   T5: hash_union — same value-bytes under different type-ids hash to
#       different values (type-id disambiguation prevents collisions).
#   T6: eval_eq_union — same type-id + equal child = TRUE; different
#       type-id = FALSE; same type-id + unequal child = FALSE.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Column,
    LargeStringArray,
    ListArray,
    PrimitiveArray,
    StringArray,
    StructArray,
    UnionArray,
)
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_core.eval.union_compute import (
    take_union,
    filter_union,
    hash_union,
    eval_eq_union,
)
from komira_core.helpers.compiler_helpers import gather_batch
from komira_core.io.heap_region import HeapRegion


# --- Helpers -----------------------------------------------------------------


def _make_int32_col(values: List[Int32]) -> Column[HeapRegion]:
    """Build an INT32 Column[HeapRegion] from a list of values."""
    var arr = PrimitiveArray[DType.int32].from_list(values)
    return Column.from_primitive[DType.int32](arr)


def _make_string_col(values: List[String]) raises -> Column[HeapRegion]:
    var arr = StringArray.from_strings(values)
    return Column.from_string(arr^)


def _make_large_string_col(values: List[String]) raises -> Column[HeapRegion]:
    var arr = LargeStringArray.from_strings(values)
    return Column.from_large_string(arr^)


def _bitmap_from_bools(values: List[Bool]) raises -> Bitmap[HeapRegion]:
    """Build a Bitmap[HeapRegion] from a list of booleans (length == len(values))."""
    var bm = Bitmap.create(len(values))
    for i in range(len(values)):
        if values[i]:
            bm.set(i)
    return bm^


# --- T1: Sparse UNION<Int32, Utf8> filter ------------------------------------


def test_x3_sparse_int_string_filter() raises:
    """Sparse union filter — every child has parent length, same mask
    applies uniformly to types_buf + each child."""
    # 4 rows: types=[0,1,0,1].  type-id 0 = int32 child, type-id 1 = utf8.
    var int_col = _make_int32_col(
        [Int32(10), Int32(0), Int32(30), Int32(0)]
    )
    var str_col = _make_string_col(
        [String(""), String("beta"), String(""), String("delta")]
    )
    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0)); types.append(Int8(1))
    types.append(Int8(0)); types.append(Int8(1))
    var ua = UnionArray.sparse_from_children_2(
        type_ids, types, int_col^, str_col^
    )
    var col = Column.from_union(ua)

    # Mask: keep rows 0 and 3 (int=10, str="delta") — 2 surviving.
    var bools = List[Bool]()
    bools.append(True); bools.append(False)
    bools.append(False); bools.append(True)
    var mask = _bitmap_from_bools(bools)
    var out = filter_union(col, mask)

    assert_equal(out.length(), 2, "filtered length 2")
    assert_equal(
        Int(out.arrow_type.type_id),
        Int(ArrowType.UNION_SPARSE.type_id),
        "still sparse",
    )
    assert_equal(out.num_children(), 2, "2 children preserved")
    # Sparse invariant: every child has parent length.
    assert_equal(out.child_at(0).length(), 2, "int32 child length 2 (parent)")
    assert_equal(out.child_at(1).length(), 2, "utf8 child length 2 (parent)")
    # types_buf preserved.
    var ua_out = out.as_union()
    assert_equal(Int(ua_out.type_id_at(0)), 0, "row 0 type-id 0")
    assert_equal(Int(ua_out.type_id_at(1)), 1, "row 1 type-id 1")
    # Child values for the selected rows.
    var c0 = ua_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(c0.get(0)), 10, "int child row 0 = 10")
    var c1 = ua_out.child_at(1).as_string()
    assert_true(c1.get(1) == String("delta"), "str child row 1 = delta")
    # No validity bitmap (Arrow spec).
    var out_has_validity = False
    if out._validity:
        out_has_validity = True
    assert_false(out_has_validity, "sparse filter output has no validity")


# --- T2: Dense UNION<Int32, Utf8> filter -------------------------------------


def test_x3_dense_int_string_filter_offsets_rewrite() raises:
    """Dense union filter — children have independent lengths; the
    offsets buffer is rewritten so that the surviving rows point at the
    new (smaller) child indices."""
    # 4 parent rows: types=[0,1,0,1]; offsets=[0,0,1,1].
    # int32-child = [10, 30]; utf8-child = ["beta", "delta"].
    var int_col = _make_int32_col([Int32(10), Int32(30)])
    var str_col = _make_string_col([String("beta"), String("delta")])
    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0)); types.append(Int8(1))
    types.append(Int8(0)); types.append(Int8(1))
    var offsets = List[Int32]()
    offsets.append(Int32(0)); offsets.append(Int32(0))
    offsets.append(Int32(1)); offsets.append(Int32(1))
    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, int_col^, str_col^
    )
    var col = Column.from_union(ua)

    # Mask: keep rows 0 and 1 (int=10, str="beta").
    var bools = List[Bool]()
    bools.append(True); bools.append(True)
    bools.append(False); bools.append(False)
    var mask = _bitmap_from_bools(bools)
    var out = filter_union(col, mask)

    assert_equal(out.length(), 2, "filtered parent length 2")
    assert_equal(
        Int(out.arrow_type.type_id),
        Int(ArrowType.UNION_DENSE.type_id),
        "still dense",
    )
    assert_equal(out.num_children(), 2, "2 children")
    # Child lengths are now per-child surviving counts.
    assert_equal(out.child_at(0).length(), 1, "int child len 1 (only row 0)")
    assert_equal(out.child_at(1).length(), 1, "utf8 child len 1 (only row 1)")
    # Offsets rewritten to new (smaller) child-row indices.
    var ua_out = out.as_union()
    assert_equal(Int(ua_out.offset_at(0)), 0, "row 0 new offset 0")
    assert_equal(Int(ua_out.offset_at(1)), 0, "row 1 new offset 0")
    # Child values for surviving rows.
    var c0 = ua_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(c0.get(0)), 10, "int child[0] = 10")
    var c1 = ua_out.child_at(1).as_string()
    assert_true(c1.get(0) == String("beta"), "utf8 child[0] = beta")


# --- T3: Sparse UNION<Int32, LargeString> take by indices --------------------


def test_x3_sparse_int_large_string_take() raises:
    """Sparse union take — same indices list applies uniformly across
    types_buf + each child.  Exercises LARGE_STRING (Int64 offsets) child."""
    var int_col = _make_int32_col([Int32(7), Int32(8), Int32(9)])
    var lstr_col = _make_large_string_col(
        [String("alpha"), String("beta"), String("gamma")]
    )
    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0)); types.append(Int8(1)); types.append(Int8(0))
    var ua = UnionArray.sparse_from_children_2(
        type_ids, types, int_col^, lstr_col^
    )
    var col = Column.from_union(ua)

    # Take rows [2, 0].
    var indices = List[Int]()
    indices.append(2); indices.append(0)
    var out = take_union(col, indices)

    assert_equal(out.length(), 2, "take output length 2")
    assert_equal(out.num_children(), 2, "2 children preserved")
    assert_equal(out.child_at(0).length(), 2, "int child parent-len 2 (sparse)")
    assert_equal(out.child_at(1).length(), 2, "large-str child parent-len 2")
    var ua_out = out.as_union()
    assert_equal(Int(ua_out.type_id_at(0)), 0, "row 0 type 0 (was row 2)")
    assert_equal(Int(ua_out.type_id_at(1)), 0, "row 1 type 0 (was row 0)")
    # Child values gathered.
    var c0 = ua_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(c0.get(0)), 9, "int child[0] (was row 2) = 9")
    assert_equal(Int(c0.get(1)), 7, "int child[1] (was row 0) = 7")
    var c1 = ua_out.child_at(1).as_large_string()
    assert_true(c1.get(0) == String("gamma"), "lstr child[0] (was row 2)")
    assert_true(c1.get(1) == String("alpha"), "lstr child[1] (was row 0)")


# --- T4: Dense UNION<Struct, List> take --------------------------------------


def test_x3_dense_struct_list_take() raises:
    """Dense union take with 2-level nesting.  Children of the union are
    themselves nested types (STRUCT + LIST); the per-child sub-index
    lists must produce correctly-rebuilt nested child columns."""
    # Struct child: STRUCT<a: Int32, b: Utf8>, 2 rows.
    var sa_a = _make_int32_col([Int32(1), Int32(2)])
    var sa_b = _make_string_col([String("hello"), String("world")])
    var names = List[String]()
    names.append(String("a")); names.append(String("b"))
    var inner_struct = StructArray.from_columns_2(names, sa_a^, sa_b^)
    var struct_col = inner_struct.to_column()

    # List child: LIST<Int64>, 2 rows.
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(11); l0.append(12); l0.append(13)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(21)
    lists.append(l1^)
    var list_arr = ListArray.from_int_lists(lists)
    var list_col = Column.from_list(list_arr)

    # 3 parent rows: types=[0,1,0]; offsets=[0,0,1]
    # struct rows 0, 1; list rows 0, 1.
    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0)); types.append(Int8(1)); types.append(Int8(0))
    var offsets = List[Int32]()
    offsets.append(Int32(0)); offsets.append(Int32(0)); offsets.append(Int32(1))
    var ua = UnionArray.dense_from_children_2(
        type_ids, types, offsets, struct_col^, list_col^
    )
    var col = Column.from_union(ua)

    # Take rows [2, 1, 0] — reverse parent order.
    # Expected: types=[0,1,0]; struct sub-indices = [1, 0] (rows that select 0 in
    # the take output, parent rows 2 and 0); list sub-index = [0] (parent row 1).
    var indices = List[Int]()
    indices.append(2); indices.append(1); indices.append(0)
    var out = take_union(col, indices)

    assert_equal(out.length(), 3, "take output length 3")
    var ua_out = out.as_union()
    assert_equal(Int(ua_out.type_id_at(0)), 0, "out row 0 type 0")
    assert_equal(Int(ua_out.type_id_at(1)), 1, "out row 1 type 1")
    assert_equal(Int(ua_out.type_id_at(2)), 0, "out row 2 type 0")
    # Struct sub-child: 2 surviving rows (orig rows 1 then 0).
    var struct_out = ua_out.child_at(0).as_struct()
    assert_equal(struct_out.length, 2, "struct sub-child len 2")
    var st_a = struct_out.child_at(0).as_primitive[DType.int32]()
    assert_equal(Int(st_a.get(0)), 2, "struct.a[0] (was struct row 1)")
    assert_equal(Int(st_a.get(1)), 1, "struct.a[1] (was struct row 0)")
    # List sub-child: 1 surviving row (orig row 0; the only parent row of type 1).
    var list_out = ua_out.child_at(1).as_list()
    assert_equal(len(list_out), 1, "list sub-child len 1")
    assert_equal(list_out.get_length(0), 3, "list[0] has 3 items")


# --- T5: hash_union — type-id disambiguation prevents cross-type collisions ---


def test_x3_hash_disambiguates_by_type_id() raises:
    """Two sparse unions, byte-identical INT32 children but DIFFERENT
    declared per-row type-ids, must hash differently.  Hash spec:
    h(value) = h_child(child_row) XOR mix64(type_id)."""
    # Both unions: child 0 = [42], child 1 = [42 as int32 too] (identical bytes
    # but different declared type-ids).  We use a sparse union so the same
    # parent row's child slot exists in both children.  By selecting type-id
    # 0 in one union and type-id 1 in the other, the same byte payload (42)
    # produces different hashes because of the type-id XOR-mix.
    var a_c0 = _make_int32_col([Int32(42)])
    var a_c1 = _make_int32_col([Int32(42)])
    var b_c0 = _make_int32_col([Int32(42)])
    var b_c1 = _make_int32_col([Int32(42)])

    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types_a = List[Int8]()
    types_a.append(Int8(0))  # union A selects type-id 0
    var types_b = List[Int8]()
    types_b.append(Int8(1))  # union B selects type-id 1

    var ua_a = UnionArray.sparse_from_children_2(
        type_ids, types_a, a_c0^, a_c1^
    )
    var ua_b = UnionArray.sparse_from_children_2(
        type_ids, types_b, b_c0^, b_c1^
    )
    var col_a = Column.from_union(ua_a)
    var col_b = Column.from_union(ua_b)

    var h_a = hash_union(col_a)
    var h_b = hash_union(col_b)
    assert_equal(len(h_a), 1, "hash A length 1")
    assert_equal(len(h_b), 1, "hash B length 1")
    # Both children carry the same Int32 bytes (42).  Without the type-id mix,
    # h_a[0] would equal h_b[0].  With the mix, they MUST differ.
    assert_true(
        h_a[0] != h_b[0],
        "hash disambiguates by type-id (same value bytes, different type-id)",
    )


# --- T6: eval_eq_union — same type AND child eq -------------------------------


def test_x3_eval_eq_union_arrow_semantics() raises:
    """Arrow eq semantics on a union: equal iff same type-id AND child
    element-equal at the selected child row.  Three pairs:
       row 0 — same type-id (0), same int value      -> TRUE
       row 1 — different type-id (0 vs 1)            -> FALSE
       row 2 — same type-id (1), different string    -> FALSE
    """
    # LHS: types = [0, 0, 1]; int_lhs = [10, 20, _]; str_lhs = [_, _, "x"]
    # RHS: types = [0, 1, 1]; int_rhs = [10, 30, _]; str_rhs = [_, _, "y"]
    var lhs_int = _make_int32_col([Int32(10), Int32(20), Int32(0)])
    var lhs_str = _make_string_col(
        [String(""), String(""), String("x")]
    )
    var rhs_int = _make_int32_col([Int32(10), Int32(30), Int32(0)])
    var rhs_str = _make_string_col(
        [String(""), String(""), String("y")]
    )

    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types_l = List[Int8]()
    types_l.append(Int8(0)); types_l.append(Int8(0)); types_l.append(Int8(1))
    var types_r = List[Int8]()
    types_r.append(Int8(0)); types_r.append(Int8(1)); types_r.append(Int8(1))

    var ua_l = UnionArray.sparse_from_children_2(
        type_ids, types_l, lhs_int^, lhs_str^
    )
    var ua_r = UnionArray.sparse_from_children_2(
        type_ids, types_r, rhs_int^, rhs_str^
    )
    var col_l = Column.from_union(ua_l)
    var col_r = Column.from_union(ua_r)

    var bm = eval_eq_union(col_l, col_r)
    assert_equal(bm.length, 3, "eq bitmap length 3")
    assert_true(bm.test(0), "row 0 (same type, same int) -> TRUE")
    assert_false(bm.test(1), "row 1 (different type-id) -> FALSE")
    assert_false(bm.test(2), "row 2 (same type, different string) -> FALSE")


# --- T7: gather_batch on UNION column -----------------------------------------


def test_x3_gather_batch_union_column_bug_k() raises:
    """`gather_batch` must handle a UNION column. Without a
    LIST/STRUCT/MAP/UNION arm it falls through to `else: fixed-width`, and
    `element_size(UNION_*)` returns 8 (default fallback), so the output
    Column would have arrow_type=UNION_SPARSE but `_data` = count*8 bytes of
    garbage, ZERO children, ZERO _type_ids — a silent corruption for any
    engine-side path that calls `gather_batch` on a batch containing a union
    column (the same shape as a `copy_column` without a UNION arm). The
    UNION arm delegates to the `take_union` kernel."""
    # Build a single-column RecordBatch holding a sparse union<int32, utf8>.
    var int_col = _make_int32_col([Int32(100), Int32(200), Int32(300)])
    var str_col = _make_string_col(
        [String(""), String(""), String("zzz")]
    )
    var type_ids = List[Int]()
    type_ids.append(0); type_ids.append(1)
    var types = List[Int8]()
    types.append(Int8(0)); types.append(Int8(0)); types.append(Int8(1))
    var ua = UnionArray.sparse_from_children_2(
        type_ids, types, int_col^, str_col^
    )
    var col = Column.from_union(ua)

    var sb = SchemaBuilder()
    sb.add_field(Field(String("u"), ArrowType.UNION_SPARSE, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    # Gather rows [2, 0] — reverse order, drop row 1.
    var indices = List[Int]()
    indices.append(2); indices.append(0)
    var out_batch = gather_batch(batch, indices)
    assert_equal(out_batch.num_rows(), 2, "gathered batch length 2")
    ref out_col = out_batch.column_at(0)
    assert_equal(
        Int(out_col.arrow_type.type_id),
        Int(ArrowType.UNION_SPARSE.type_id),
        "out col arrow_type preserved (NOT corrupted to fixed-width)",
    )
    assert_equal(out_col.num_children(), 2, "out col has 2 children")
    var out_type_ids = out_col.type_ids()
    assert_equal(len(out_type_ids), 2, "out col preserves _type_ids")
    assert_equal(out_type_ids[0], 0, "type-id 0 preserved")
    assert_equal(out_type_ids[1], 1, "type-id 1 preserved")
    # Sparse invariant: every child has parent length.
    assert_equal(out_col.child_at(0).length(), 2, "int child length 2")
    assert_equal(out_col.child_at(1).length(), 2, "utf8 child length 2")
    # Round-trip via as_union + verify types_buf bytes.
    var ua_out = out_col.as_union()
    assert_equal(Int(ua_out.type_id_at(0)), 1, "out row 0 (was row 2) type 1")
    assert_equal(Int(ua_out.type_id_at(1)), 0, "out row 1 (was row 0) type 0")


# --- Test runner -------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_x3_sparse_int_string_filter]()
    suite.test[test_x3_dense_int_string_filter_offsets_rewrite]()
    suite.test[test_x3_sparse_int_large_string_take]()
    suite.test[test_x3_dense_struct_list_take]()
    suite.test[test_x3_hash_disambiguates_by_type_id]()
    suite.test[test_x3_eval_eq_union_arrow_semantics]()
    suite.test[test_x3_gather_batch_union_column_bug_k]()
    suite^.run()
