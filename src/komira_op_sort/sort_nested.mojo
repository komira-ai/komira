# =============================================================================
# Sort Engine — sort_indices for nested types (LIST, STRUCT, UNION)
# =============================================================================
#
# Type-erased nested-key sort kernel.  Returns a permutation of [0, N) such
# that gathering the column by those indices yields the rows in lex order.
#
# Coverage:
#   * STRUCT — per-field-then-recurse, ordered by Schema field index;
#              recursive lex through each child Column.  ASC NULLS FIRST.
#   * LIST   — element-by-element lex over the child child range
#              [offsets[i], offsets[i+1]); shorter prefix sorts first
#              when common positions are equal.  ASC NULLS FIRST.
#   * UNION  — sparse + dense.  Cross-type ordering is by type-id (per
#              Arrow spec + PostgreSQL convention); within-type rows
#              recurse on the selected child.  Dense honors offsets[i].
#   * MAP    — RAISES with a clear "MAP sort is undefined per Arrow spec"
#              message.  Mirrors Arrow C++ / pyarrow / DuckDB / DataFusion
#              behavior; the spec leaves Map ordering undefined.
#
# Null collation matches `sort_indices_string`:
#   ASC  (descending=False) -> NULLS FIRST
#   DESC (descending=True)  -> NULLS LAST
#
# Algorithm: stable insertion sort over the index permutation.  Insertion
# sort is O(N^2) but the constant factor is tiny and nested-type sort
# keys are typically small N (struct + list keys aren't the hot path for
# big batches; they're metadata-shaped).  If a hot workload appears that
# requires nested-key sort on large N, swap in a merge sort body — the
# comparator interface (`_lex_lt_one_col`) is the same.
#
# Encapsulation: all pointer arithmetic stays inside private helpers.
# The public surface (`sort_indices_nested`) accepts a `Column` and
# returns a `PrimitiveArray[DType.int32]`.  No UnsafePointer crosses
# the module boundary.
# =============================================================================

from std.memory import alloc, memcpy
from std.sys import size_of

from komira_arrow.column import Column
from komira_arrow.bitmap import Bitmap, read_bit_aligned_buffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion

from .sort import sort_key_lt


# Maximum recursion depth for nested-type comparators.  Mojo lacks a hard
# comptime recursion limit on `def` fns but a runtime cap matches DuckDB +
# DataFusion's pragmatic bound.  No realistic workload nests this deep.
comptime _MAX_NESTED_DEPTH: Int = 32


# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------


def sort_indices_nested(
    col: Column[HeapRegion],
    descending: Bool = False,
) raises -> PrimitiveArray[DType.int32]:
    """Sort a nested-type column and return permutation indices.

    The data is NOT moved -- the caller uses the indices to gather all
    columns of the parent batch (typically via `gather_batch_by_sort_
    indices`).

    Supported nested types: STRUCT, LIST, UNION_SPARSE, UNION_DENSE.
    MAP raises (Arrow spec leaves Map ordering undefined; Arrow C++ /
    pyarrow / DuckDB / DataFusion all reject MAP sort keys).

    Null collation:
      ASC  (descending=False) -> NULLS FIRST
      DESC (descending=True)  -> NULLS LAST

    Args:
        col: Column to sort.  Must be STRUCT / LIST / UNION_SPARSE / UNION_DENSE.
        descending: If True, sort in descending order.  Default ascending.

    Returns:
        A PrimitiveArray[DType.int32] of permutation indices.

    Raises:
        Error if `col.arrow_type` is MAP (undefined ordering per Arrow spec).
        Error if `col.arrow_type` is not a nested type covered by this kernel.
    """
    var at = col.arrow_type
    if at == ArrowType.MAP:
        raise Error(
            "sort_indices_nested: MAP sort key is undefined per Arrow spec"
            " (Arrow Columnar Format does not specify a total order on Map);"
            " project key/value to sort by them instead"
        )
    if not (
        at == ArrowType.STRUCT
        or at == ArrowType.LIST
        or at == ArrowType.UNION_SPARSE
        or at == ArrowType.UNION_DENSE
    ):
        raise Error(
            "sort_indices_nested: unsupported arrow_type "
            + String(at)
            + " (expected STRUCT, LIST, UNION_SPARSE, or UNION_DENSE)"
        )

    var n = col.length()
    var indices = PrimitiveArray[DType.int32].allocate(n)
    if n == 0:
        return indices^

    var indices_view = indices.view_mut()
    var idx_ptr = indices_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    for i in range(n):
        (idx_ptr + i)[] = Scalar[DType.int32](i)

    if n == 1:
        return indices^

    # Stable insertion sort over the index permutation.
    # The comparator (`_lex_lt_one_col`) returns True iff row `a` sorts
    # strictly before row `b` for the given direction (with NULL
    # collation absorbed).  Equality -> False (preserves stability).
    _insertion_sort_nested(idx_ptr, Pointer(to=col), 0, n, descending)
    return indices^


# -----------------------------------------------------------------------------
# Insertion sort (stable; preserves original order on key equality)
# -----------------------------------------------------------------------------


def _insertion_sort_nested[
    o_idx: Origin[mut=True], o_col: Origin
](
    idx_ptr: UnsafePointer[Scalar[DType.int32], o_idx],
    col: Pointer[Column[HeapRegion], o_col],
    lo: Int,
    hi: Int,
    descending: Bool,
) raises:
    """Stable insertion sort over [lo, hi).  Comparator absorbs the direction."""
    for i in range(lo + 1, hi):
        var key_idx = (idx_ptr + i)[]
        var j = i
        while j > lo:
            var prev_idx = (idx_ptr + j - 1)[]
            # Move only if strict order: key_idx should sort BEFORE prev_idx.
            var should_move = _col_compare_null_aware(
                col, Int(key_idx), Int(prev_idx), descending, 0
            )
            if not should_move:
                break
            (idx_ptr + j)[] = prev_idx
            j -= 1
        (idx_ptr + j)[] = key_idx


def _col_compare_null_aware[
    o_col: Origin
](
    col: Pointer[Column[HeapRegion], o_col],
    a: Int,
    b: Int,
    descending: Bool,
    depth: Int,
) raises -> Bool:
    """Top-level row comparator with NULL collation.  Returns True iff row
    `a` should sort BEFORE row `b` for the given direction."""
    # Read validity at the outer level (unions have no validity bitmap;
    # children carry it).  ASC NULLS FIRST / DESC NULLS LAST.
    var a_valid = _col_row_valid(col, a)
    var b_valid = _col_row_valid(col, b)
    if not a_valid and not b_valid:
        return False  # stable: keep original order
    if not a_valid:
        # `a` is null.  ASC -> NULL first -> a < b -> True.
        # DESC -> NULL last -> a > b -> False.
        return not descending
    if not b_valid:
        # `b` is null.  ASC -> b < a -> a not before b -> False.
        # DESC -> b > a -> a before b -> True.
        return descending
    # Both valid -- recurse on the per-type lex comparator.
    if descending:
        return _lex_lt_one_col(col, b, a, depth)
    return _lex_lt_one_col(col, a, b, depth)


@always_inline
def _col_row_valid[
    o_col: Origin
](col: Pointer[Column[HeapRegion], o_col], row: Int) -> Bool:
    """Return True iff Column[HeapRegion] row `row` is valid (non-null).  Unions have
    no validity bitmap at the outer level -- always returns True for them
    (child-level validity is handled in the recursive comparator)."""
    if col[].arrow_type == ArrowType.UNION_SPARSE \
       or col[].arrow_type == ArrowType.UNION_DENSE:
        return True
    if not col[]._validity:
        return True
    # Validity is bit-addressed at logical offset col._offset + row.
    return col[]._validity.value().test(col[]._offset + row)


# -----------------------------------------------------------------------------
# Per-type lex comparators (ascending; direction is applied at the top level)
# -----------------------------------------------------------------------------


def _lex_lt_one_col[
    o_col: Origin
](
    col: Pointer[Column[HeapRegion], o_col],
    a: Int,
    b: Int,
    depth: Int,
) raises -> Bool:
    """Dispatch comparator: returns True iff `col[a] < col[b]` (ASC).

    Validity is the caller's responsibility for the OUTER level; this
    function handles validity for CHILD recursion (within structs, lists,
    unions) where each child has its own validity bitmap.
    """
    if depth > _MAX_NESTED_DEPTH:
        raise Error(
            "sort_indices_nested: nested depth exceeds "
            + String(_MAX_NESTED_DEPTH)
            + " (likely a malformed schema)"
        )

    var at = col[].arrow_type
    if at == ArrowType.STRUCT:
        return _lex_lt_struct(col, a, b, depth)
    if at == ArrowType.LIST:
        return _lex_lt_list(col, a, b, depth)
    if at == ArrowType.UNION_SPARSE or at == ArrowType.UNION_DENSE:
        return _lex_lt_union(col, a, b, depth)
    if at == ArrowType.MAP:
        raise Error(
            "sort_indices_nested: MAP sort key is undefined per Arrow spec"
        )
    # Primitive / string / binary leaves.
    return _lex_lt_leaf(col, a, b)


# --- STRUCT ------------------------------------------------------------------


def _lex_lt_struct[
    o_col: Origin
](
    col: Pointer[Column[HeapRegion], o_col],
    a: Int,
    b: Int,
    depth: Int,
) raises -> Bool:
    """Per-field-then-recurse.  Equal-on-current-field -> recurse to next."""
    var nch = col[].num_children()
    var off = col[]._offset
    for k in range(nch):
        ref ach = col[].child_at(k)
        ref bch = col[].child_at(k)  # same column; refs into the same child
        # NULL handling per child: ASC NULLS FIRST (child-level).
        var a_valid = _child_row_valid(Pointer(to=ach), off + a)
        var b_valid = _child_row_valid(Pointer(to=bch), off + b)
        if not a_valid and not b_valid:
            continue  # equal NULL -> next field decides
        if not a_valid:
            return True  # NULL < non-NULL (ASC NULLS FIRST)
        if not b_valid:
            return False  # non-NULL > NULL (ASC NULLS FIRST)
        # Both valid -> field-level lex.
        if _lex_lt_one_col(Pointer(to=ach), off + a, off + b, depth + 1):
            return True
        if _lex_lt_one_col(Pointer(to=bch), off + b, off + a, depth + 1):
            return False
        # equal on this field -> next field
    return False  # all fields equal -> not strictly less


@always_inline
def _child_row_valid[
    o_col: Origin
](col: Pointer[Column[HeapRegion], o_col], row: Int) -> Bool:
    """Row-level validity check on a CHILD Column[HeapRegion] (already offset-resolved)."""
    if not col[]._validity:
        return True
    return col[]._validity.value().test(row)


# --- LIST --------------------------------------------------------------------


def _lex_lt_list[
    o_col: Origin
](
    col: Pointer[Column[HeapRegion], o_col],
    a: Int,
    b: Int,
    depth: Int,
) raises -> Bool:
    """Element-by-element lex.  Shorter prefix sorts first when equal."""
    if not col[]._offsets:
        raise Error("sort_indices_nested: LIST column missing offsets buffer")
    var offs_view = col[]._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var off = col[]._offset
    var a_lo = Int((offs_ptr + off + a)[])
    var a_hi = Int((offs_ptr + off + a + 1)[])
    var b_lo = Int((offs_ptr + off + b)[])
    var b_hi = Int((offs_ptr + off + b + 1)[])
    var a_len = a_hi - a_lo
    var b_len = b_hi - b_lo
    var m = a_len if a_len < b_len else b_len

    ref child = col[].child_at(0)
    for k in range(m):
        # Per-element validity.
        var ai = a_lo + k
        var bi = b_lo + k
        var av = _child_row_valid(Pointer(to=child), ai)
        var bv = _child_row_valid(Pointer(to=child), bi)
        if not av and not bv:
            continue
        if not av:
            return True  # NULL element < non-NULL (ASC NULLS FIRST)
        if not bv:
            return False
        if _lex_lt_one_col(Pointer(to=child), ai, bi, depth + 1):
            return True
        if _lex_lt_one_col(Pointer(to=child), bi, ai, depth + 1):
            return False
    return a_len < b_len  # common prefix equal -> shorter sorts first


# --- UNION -------------------------------------------------------------------


def _lex_lt_union[
    o_col: Origin
](
    col: Pointer[Column[HeapRegion], o_col],
    a: Int,
    b: Int,
    depth: Int,
) raises -> Bool:
    """Sparse + dense.  Cross-type ordering by declared type-id; same-type
    rows dispatch to the selected child."""
    var types_view = col[]._data.view_ro()
    var types_ptr = types_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
    var off = col[]._offset
    var a_tid = Int((types_ptr + off + a)[])
    var b_tid = Int((types_ptr + off + b)[])
    if a_tid != b_tid:
        return a_tid < b_tid  # cross-type: type-id order dominates

    # Same type-id -> map to child index, then recurse.
    var cidx = _union_type_id_to_child_index(col, a_tid)
    if cidx < 0:
        raise Error(
            "sort_indices_nested: UNION row has type-id "
            + String(a_tid)
            + " not in declared _type_ids list"
        )

    var a_row = a
    var b_row = b
    if col[].arrow_type == ArrowType.UNION_DENSE:
        if not col[]._offsets:
            raise Error(
                "sort_indices_nested: UNION_DENSE column missing offsets buffer"
            )
        var off_view = col[]._offsets.value().view_ro()
        var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        a_row = Int((off_ptr + off + a)[])
        b_row = Int((off_ptr + off + b)[])

    ref child = col[].child_at(cidx)
    # Per-child validity check (mirrors STRUCT field-level NULL handling).
    var av = _child_row_valid(Pointer(to=child), a_row)
    var bv = _child_row_valid(Pointer(to=child), b_row)
    if not av and not bv:
        return False
    if not av:
        return True
    if not bv:
        return False
    return _lex_lt_one_col(Pointer(to=child), a_row, b_row, depth + 1)


@always_inline
def _union_type_id_to_child_index[
    o_col: Origin
](col: Pointer[Column[HeapRegion], o_col], type_id: Int) -> Int:
    """Linear-scan the declared _type_ids list for the child index.  N is
    typically 2-4, so linear is fine.  Returns -1 if not found."""
    ref ids = col[]._type_ids
    for i in range(len(ids)):
        if ids[i] == type_id:
            return i
    return -1


# --- Primitive / string / binary leaves --------------------------------------


def _lex_lt_leaf[
    o_col: Origin
](
    col: Pointer[Column[HeapRegion], o_col],
    a: Int,
    b: Int,
) raises -> Bool:
    """Leaf lex comparator.  Dispatches on the scalar arrow_type."""
    var at = col[].arrow_type
    var off = col[]._offset
    if at == ArrowType.INT32:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.INT64:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.INT16:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.INT8:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.UINT32:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.uint32]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.UINT64:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.uint64]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.UINT16:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.uint16]]()
        return (p + off + a)[] < (p + off + b)[]
    if at == ArrowType.UINT8:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        return (p + off + a)[] < (p + off + b)[]
    # Floats order by `sort_key_lt`: NaN above +inf, as the flat kernels.
    if at == ArrowType.FLOAT32:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.float32]]()
        return sort_key_lt((p + off + a)[], (p + off + b)[])
    if at == ArrowType.FLOAT64:
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
        return sort_key_lt((p + off + a)[], (p + off + b)[])
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        return _string_leaf_lt(col, a, b)
    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        return _large_string_leaf_lt(col, a, b)
    if at == ArrowType.BOOL:
        # false < true. BOOL is bit-packed: row r is BIT `off + r` of the
        # buffer, not a byte.
        var av = read_bit_aligned_buffer(col[]._data, off + a)
        var bv = read_bit_aligned_buffer(col[]._data, off + b)
        return (not av) and bv
    # Storage-compatible temporal / interval types share Int32 / Int64 paths.
    if (
        at == ArrowType.DATE32
        or at == ArrowType.TIME32_S
        or at == ArrowType.TIME32_MS
        or at == ArrowType.INTERVAL_YEAR_MONTH
    ):
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        return (p + off + a)[] < (p + off + b)[]
    if (
        at == ArrowType.DATE64
        or at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
        or at == ArrowType.INTERVAL_DAY_TIME
        or at.is_duration()
        or at.is_timestamp()
    ):
        var p_view = col[]._data.view_ro()
        var p = p_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        return (p + off + a)[] < (p + off + b)[]
    raise Error(
        "sort_indices_nested: leaf type "
        + String(at)
        + " not yet supported by the nested sort kernel"
    )


def _string_leaf_lt[
    o_col: Origin
](col: Pointer[Column[HeapRegion], o_col], a: Int, b: Int) raises -> Bool:
    """STRING / BINARY byte-wise lex with length tie-break (shorter first)."""
    if not col[]._offsets:
        raise Error(
            "sort_indices_nested: STRING/BINARY column missing offsets buffer"
        )
    var offs_view = col[]._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var data_view = col[]._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var off = col[]._offset
    var a_lo = Int((offs_ptr + off + a)[])
    var a_hi = Int((offs_ptr + off + a + 1)[])
    var b_lo = Int((offs_ptr + off + b)[])
    var b_hi = Int((offs_ptr + off + b + 1)[])
    var a_len = a_hi - a_lo
    var b_len = b_hi - b_lo
    var m = a_len if a_len < b_len else b_len
    var i = 0
    while i < m:
        var ca = (data_ptr + a_lo + i)[]
        var cb = (data_ptr + b_lo + i)[]
        if ca != cb:
            return ca < cb
        i += 1
    return a_len < b_len


def _large_string_leaf_lt[
    o_col: Origin
](col: Pointer[Column[HeapRegion], o_col], a: Int, b: Int) raises -> Bool:
    """LARGE_STRING / LARGE_BINARY byte-wise lex (Int64 offsets)."""
    if not col[]._offsets:
        raise Error(
            "sort_indices_nested: LARGE_STRING/LARGE_BINARY column"
            " missing offsets buffer"
        )
    var offs_view = col[]._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var data_view = col[]._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var off = col[]._offset
    var a_lo = Int((offs_ptr + off + a)[])
    var a_hi = Int((offs_ptr + off + a + 1)[])
    var b_lo = Int((offs_ptr + off + b)[])
    var b_hi = Int((offs_ptr + off + b + 1)[])
    var a_len = a_hi - a_lo
    var b_len = b_hi - b_lo
    var m = a_len if a_len < b_len else b_len
    var i = 0
    while i < m:
        var ca = (data_ptr + a_lo + i)[]
        var cb = (data_ptr + b_lo + i)[]
        if ca != cb:
            return ca < cb
        i += 1
    return a_len < b_len
