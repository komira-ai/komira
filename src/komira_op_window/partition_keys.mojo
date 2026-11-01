# =============================================================================
# partition_keys -- how a window orders its rows and where its groups break
# =============================================================================
#
# A window sorts its input by (partition keys ++ order keys), then walks the
# sorted rows: a PARTITION starts where a partition key changes, and a PEER
# GROUP (the rows that tie on every order key) starts where a partition or an
# order key changes. This module is the one place both decisions are made,
# and both follow DuckDB (docs/design/query_semantics.md §4, §9):
#
#   * Order. Partition keys ascending, order keys in their own direction,
#     NULLs last in both directions (`derived_nulls_first`, §4.1), floats in
#     the total order of `sort_key_lt` (NaN above +inf, -0.0 equal to +0.0,
#     §4.3). A DICTIONARY key sorts by the VALUES its codes stand for, not by
#     the codes.
#   * Equality. NULL equals NULL (§9.7, §9.9); floats compare under §2.6 (every
#     NaN equals every NaN, -0.0 equals +0.0); a dictionary key compares by
#     value. `key_cells_equal` is that rule, and every boundary of the
#     package (partitions, peers, RANK ties) goes through it.
#
# `sort_partition_batch` takes the multi-key sort of `komira_op_sort`
# (`sort_batch_by_keys`) whenever no key carries a NULL and no key is a
# dictionary. Otherwise it sorts a small batch of the key columns alone,
# one stable pass per key from the last to the first: each pass sorts the
# key's non-NULL rows and puts its NULL rows after them (or before, if the
# policy says so) in their current order. It then gathers the input by the
# resulting permutation.
# =============================================================================

from std.math import isnan

from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width
from komira_arrow.column import Column
from komira_arrow.copy_column_ref import copy_column_ref
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import gather_batch
from komira_op_sort.sort import (
    sort_indices_float64,
    sort_indices_int64,
)
from komira_op_sort.sort_multi import sort_batch_by_keys
from komira_op_sort.sort_string import sort_indices_string
from komira_operator_api.sink_batch_fold import fold_batches_into_one
from komira_plan_expr.null_order_policy import derived_nulls_first


# =============================================================================
# Cell equality
# =============================================================================


def column_has_nulls(col: Column[HeapRegion]) -> Bool:
    """True iff some row of `col` is NULL (a scan; no bitmap means none)."""
    if not col.has_validity_buffer():
        return False
    for r in range(col.length()):
        if col.is_null_at(r):
            return True
    return False


@always_inline
def _f64_same(a: Float64, b: Float64) -> Bool:
    """Float equality under §2.6: NaN equals NaN, -0.0 equals +0.0."""
    return a == b or (isnan(a) and isnan(b))


@always_inline
def _f32_same(a: Float32, b: Float32) -> Bool:
    return a == b or (isnan(a) and isnan(b))


def _bytes_same(col: Column[HeapRegion], a: Int, b: Int) raises -> Bool:
    """STRING / BINARY equality of rows `a` and `b` (int32 offsets)."""
    ref off_buf = col._offsets.value()
    var a_start = Int(off_buf.get_typed[Int32](col._offset + a))
    var a_end = Int(off_buf.get_typed[Int32](col._offset + a + 1))
    var b_start = Int(off_buf.get_typed[Int32](col._offset + b))
    var b_end = Int(off_buf.get_typed[Int32](col._offset + b + 1))
    if a_end - a_start != b_end - b_start:
        return False
    for i in range(a_end - a_start):
        if col._data.read_u8_at(a_start + i) != col._data.read_u8_at(
            b_start + i
        ):
            return False
    return True


def _string_dict_same(col: Column[HeapRegion], a: Int, b: Int) raises -> Bool:
    """STRING dictionary equality: the same code, or two codes whose entries
    hold the same bytes (a dictionary need not be unique)."""
    var ca = col.string_dict_code_at(a)
    var cb = col.string_dict_code_at(b)
    if ca == cb:
        return True
    var va = col.string_dict_value_at(ca)
    var vb = col.string_dict_value_at(cb)
    if va.len() != vb.len():
        return False
    for i in range(va.len()):
        if va.read_u8_at(i) != vb.read_u8_at(i):
            return False
    return True


def _numeric_dict_same(col: Column[HeapRegion], a: Int, b: Int) -> Bool:
    """Numeric dictionary equality, by the values the codes stand for."""
    var ca = col.dict_code_at(a)
    var cb = col.dict_code_at(b)
    if ca == cb:
        return True
    var vdt = col.dict_value_dtype()
    if vdt == DType.float64 or vdt == DType.float32:
        return _f64_same(col.dict_value_f64(ca), col.dict_value_f64(cb))
    return col.dict_value_i64(ca) == col.dict_value_i64(cb)


def key_cells_equal(col: Column[HeapRegion], a: Int, b: Int) raises -> Bool:
    """True iff rows `a` and `b` of key column `col` are the same key.

    NULL equals NULL and nothing else; floats compare under §2.6; a
    dictionary compares by value; STRING / BINARY by bytes; BOOL by bit;
    every other fixed-width type by its stored bytes. A type with none of
    these layouts (nested, view, large offsets) raises: reporting "equal"
    would merge partitions, and reporting "different" would split them.
    """
    var na = col.is_null_at(a)
    var nb = col.is_null_at(b)
    if na or nb:
        return na and nb
    var at = col.arrow_type
    var ia = col._offset + a
    var ib = col._offset + b
    if at == ArrowType.INT64:
        return col._data.get_typed[Scalar[DType.int64]](ia) == col._data.get_typed[
            Scalar[DType.int64]
        ](ib)
    elif at == ArrowType.INT32 or at == ArrowType.DATE32:
        return col._data.get_typed[Scalar[DType.int32]](ia) == col._data.get_typed[
            Scalar[DType.int32]
        ](ib)
    elif at == ArrowType.FLOAT64:
        return _f64_same(
            col._data.get_typed[Scalar[DType.float64]](ia),
            col._data.get_typed[Scalar[DType.float64]](ib),
        )
    elif at == ArrowType.FLOAT32:
        return _f32_same(
            col._data.get_typed[Scalar[DType.float32]](ia),
            col._data.get_typed[Scalar[DType.float32]](ib),
        )
    elif col.is_numeric_dict():
        # Checked before the STRING dictionary arm: a numeric dictionary's
        # codes may be 8 bytes wide, which an int32 read would misread.
        return _numeric_dict_same(col, a, b)
    elif col.is_string_dict():
        return _string_dict_same(col, a, b)
    elif at == ArrowType.STRING or at == ArrowType.BINARY:
        return _bytes_same(col, a, b)
    elif at == ArrowType.BOOL:
        var ba = (col._data.read_u8_at(ia >> 3) >> UInt8(ia & 7)) & 1
        var bb = (col._data.read_u8_at(ib >> 3) >> UInt8(ib & 7)) & 1
        return ba == bb
    var w: Int
    try:
        w = arrow_fixed_byte_width(at)
    except:
        raise Error(
            "partition_keys: unsupported key type " + String(at)
            + " (no equality for this layout)"
        )
    for i in range(w):
        if col._data.read_u8_at(ia * w + i) != col._data.read_u8_at(ib * w + i):
            return False
    return True


# =============================================================================
# Boundaries
# =============================================================================


def _detect_partition_boundaries(
    batch: RecordBatch,
    partition_keys: List[String],
) raises -> List[Int]:
    """The rows at which a new group starts, the first row included.

    `batch` is sorted by `partition_keys` (and maybe more keys after them).
    A row starts a group iff some key differs from the row before it under
    `key_cells_equal`. With no keys the whole batch is one group. An empty
    batch has no groups.
    """
    var num_rows = batch.num_rows()
    var bounds = List[Int]()
    if num_rows == 0:
        return bounds^
    bounds.append(0)
    if len(partition_keys) == 0:
        return bounds^

    var key_indices = List[Int]()
    for k in partition_keys:
        key_indices.append(batch.schema.column_index(k))

    for row in range(1, num_rows):
        for ki in range(len(key_indices)):
            ref col = batch.column_at(key_indices[ki])
            if not key_cells_equal(col, row, row - 1):
                bounds.append(row)
                break
    return bounds^


def _merge_bounds(a: List[Int], b: List[Int]) -> List[Int]:
    """The sorted union of two ascending lists of row indices."""
    var merged = List[Int]()
    var i = 0
    var j = 0
    while i < len(a) and j < len(b):
        if a[i] < b[j]:
            merged.append(a[i])
            i += 1
        elif b[j] < a[i]:
            merged.append(b[j])
            j += 1
        else:
            merged.append(a[i])
            i += 1
            j += 1
    while i < len(a):
        merged.append(a[i])
        i += 1
    while j < len(b):
        merged.append(b[j])
        j += 1
    return merged^


def _peer_bounds(
    batch: RecordBatch,
    bounds: List[Int],
    order_keys: List[String],
) raises -> List[Int]:
    """The rows at which a peer group starts.

    A row starts a peer group iff it starts a partition or an order key
    differs from the row before it. With no order keys every row of a
    partition is a peer of every other, so the peer groups are the
    partitions.
    """
    if len(order_keys) == 0:
        return bounds.copy()
    var okb = _detect_partition_boundaries(batch, order_keys)
    return _merge_bounds(bounds, okb)


def _segment_ends(bounds: List[Int], num_rows: Int) -> List[Int]:
    """The exclusive end row of each group that starts at `bounds[i]`."""
    var ends = List[Int]()
    for i in range(len(bounds)):
        if i + 1 < len(bounds):
            ends.append(bounds[i + 1])
        else:
            ends.append(num_rows)
    return ends^


# =============================================================================
# The sort
# =============================================================================


def _dict_rank_column(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """An INT32 column holding, per row, the rank of its dictionary entry in
    VALUE order (equal values share a rank), NULL where `col` is NULL.

    Sorting by it orders the rows as their values order: STRING entries by
    bytes, numeric entries by `sort_key_lt`.
    """
    var n = col.length()
    var d = col.dict_size()
    var rank_of_code = List[Int32](capacity=d)
    for _ in range(d):
        rank_of_code.append(0)
    if col.is_numeric_dict():
        var vdt = col.dict_value_dtype()
        var is_float = vdt == DType.float64 or vdt == DType.float32
        var perm: PrimitiveArray[DType.int32]
        if is_float:
            var vals = List[Scalar[DType.float64]](capacity=d)
            for c in range(d):
                vals.append(col.dict_value_f64(c))
            perm = sort_indices_float64(
                PrimitiveArray[DType.float64].from_list(vals)
            )
        else:
            var ivals = List[Scalar[DType.int64]](capacity=d)
            for c in range(d):
                ivals.append(col.dict_value_i64(c))
            perm = sort_indices_int64(PrimitiveArray[DType.int64].from_list(ivals))
        var rank = Int32(0)
        for i in range(d):
            var c = Int(perm.get(i))
            if i > 0:
                var p = Int(perm.get(i - 1))
                var same: Bool
                if is_float:
                    same = _f64_same(col.dict_value_f64(c), col.dict_value_f64(p))
                else:
                    same = col.dict_value_i64(c) == col.dict_value_i64(p)
                if not same:
                    rank += 1
            rank_of_code[c] = rank
    else:
        var dict_arr = col.as_dictionary()
        var entries = Column.from_string(dict_arr.dictionary)
        var perm = sort_indices_string(entries)
        var rank = Int32(0)
        for i in range(d):
            var c = Int(perm.get(i))
            if i > 0:
                var p = Int(perm.get(i - 1))
                if dict_arr.dictionary.get(c) != dict_arr.dictionary.get(p):
                    rank += 1
            rank_of_code[c] = rank

    var nullable = col.has_validity_buffer()
    var out: PrimitiveArray[DType.int32]
    if nullable:
        out = PrimitiveArray[DType.int32].allocate_nullable(n)
    else:
        out = PrimitiveArray[DType.int32].allocate(n)
    for r in range(n):
        if nullable and col.is_null_at(r):
            out.store[1](r, Int32(0))
            out._set_null(r)
            continue
        var code: Int
        if col.is_numeric_dict():
            code = col.dict_code_at(r)
        else:
            code = col.string_dict_code_at(r)
        out.store[1](r, rank_of_code[code])
    return Column.from_primitive[DType.int32](out)


def _stable_pass(
    var kb: RecordBatch, key: String, descending: Bool
) raises -> RecordBatch:
    """One stable pass of the key-at-a-time sort: order `kb` by `key`, NULLs
    where `derived_nulls_first` puts them, keeping every tie (and the NULL
    rows among themselves) in its current order."""
    var col_idx = kb.schema.column_index(key)
    var nulls = False
    if kb.column_at(col_idx).has_validity_buffer():
        nulls = column_has_nulls(kb.column_at(col_idx))
    var keys = List[String]()
    keys.append(key)
    var desc = List[Bool]()
    desc.append(descending)
    if not nulls:
        return sort_batch_by_keys(kb^, keys, desc)

    var valid_rows = List[Int]()
    var null_rows = List[Int]()
    ref col = kb.column_at(col_idx)
    for r in range(kb.num_rows()):
        if col.is_null_at(r):
            null_rows.append(r)
        else:
            valid_rows.append(r)
    var valid = gather_batch(kb, valid_rows)
    var nulls_part = gather_batch(kb, null_rows)
    _ = kb^
    if valid.num_rows() > 1:
        valid = sort_batch_by_keys(valid^, keys, desc)
    var staged = Slab[RecordBatch]()
    if derived_nulls_first(descending):
        if nulls_part.num_rows() > 0:
            staged.append(nulls_part^)
        if valid.num_rows() > 0:
            staged.append(valid^)
    else:
        if valid.num_rows() > 0:
            staged.append(valid^)
        if nulls_part.num_rows() > 0:
            staged.append(nulls_part^)
    return fold_batches_into_one(staged^)


def sort_partition_batch(
    var batch: RecordBatch,
    partition_keys: List[String],
    order_keys: List[String],
    descending: List[Bool],
) raises -> RecordBatch:
    """Sort `batch` by (partition keys ascending ++ order keys per
    `descending`), NULLs last, floats by `sort_key_lt`, dictionaries by value.

    Stable: rows equal on every key keep their input order. With no keys the
    batch is returned as it is.
    """
    var keys = List[String]()
    var desc = List[Bool]()
    for k in partition_keys:
        keys.append(k)
        desc.append(False)
    for i in range(len(order_keys)):
        keys.append(order_keys[i])
        desc.append(descending[i])
    if len(keys) == 0 or batch.num_rows() <= 1:
        return batch^

    var special = False
    for k in keys:
        ref col = batch.column_at(batch.schema.column_index(k))
        if col.arrow_type == ArrowType.DICTIONARY or column_has_nulls(col):
            special = True
            break
    if not special:
        return sort_batch_by_keys(batch^, keys, desc)

    # The key batch: one column per key (a value-rank column for a
    # dictionary) and the input row number.
    var n = batch.num_rows()
    var sb = SchemaBuilder()
    var kbb = RecordBatchBuilder()
    for i in range(len(keys)):
        var idx = batch.schema.column_index(keys[i])
        ref col = batch.column_at(idx)
        var name = String("k") + String(i)
        if col.arrow_type == ArrowType.DICTIONARY:
            sb.add_field(Field(name, ArrowType.INT32, True))
            kbb.add_column(_dict_rank_column(col))
        else:
            var f = batch.schema.field_at(idx)
            f.name = name
            sb.add_field(f^)
            kbb.add_column(copy_column_ref(col, col.length()))
    var rows = List[Scalar[DType.int64]](capacity=n)
    for r in range(n):
        rows.append(Int64(r))
    sb.add_field(Field(String("row"), ArrowType.INT64, False))
    kbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(rows)
        )
    )
    var kb = kbb.build(sb.build())

    for i in range(len(keys) - 1, -1, -1):
        kb = _stable_pass(kb^, String("k") + String(i), desc[i])

    ref row_col = kb.column_at(kb.schema.column_index("row"))
    var perm = List[Int](capacity=n)
    for r in range(n):
        perm.append(
            Int(row_col._data.get_typed[Scalar[DType.int64]](row_col._offset + r))
        )
    return gather_batch(batch, perm)
