# =============================================================================
# asof_walker -- the ASOF two-cursor merge: every left row's best right row
# =============================================================================
#
#   * `compare_equi_keys`: the multi-column equi-key comparison, returning an
#     `EquiKeyCmp` (the sort order AND the join match; see asof_equi_key).
#     `compare_keys` is its order alone. Key columns: INT32, INT64, FLOAT64,
#     STRING and DICTIONARY (a STRING key may meet a DICTIONARY one; both
#     compare as UTF-8 bytes).
#   * `asof_merge_into[strategy, dtype]`: the walker. Both sides arrive sorted
#     on `(equi_keys..., asof)` ascending; it emits one output pair per left
#     row (four parallel lists), with -1 on the right for a left row without a
#     match (the left join).
#   * `asof_merge_dispatch`: the run-time (strategy, dtype) switch onto the
#     nine monomorphs.
#
# MATCHING (DuckDB's ASOF JOIN):
#   * a left row whose equi key holds a NULL matches nothing; neither does a
#     right row whose equi key holds one;
#   * a NULL ASOF value matches nothing, on either side;
#   * float keys and float ASOF values compare in `sort_key_lt` order: NaN
#     equals NaN and sorts above +inf, -0.0 equals +0.0.
#
# THE INPUT ORDER IS ONLY TRUSTED FOR NON-NULL KEYS. The sort that prepares
# the sides (`komira_op_sort.sort_multi.sort_batch_by_keys`) places a NULL
# numeric key by whatever value its slot holds, not first, so a NULL-keyed
# row can sit inside a run of equal keys (a NULL whose slot holds 0 among the
# 0 keys). The walker does not let such a row move the cursor or end a group:
# a left row with a NULL key is emitted unmatched without touching the cursor
# or the cached group, and a right row with a NULL key is stepped over inside
# a group. Ordered by `compare_equi_keys`, a NULL-keyed right row is behind
# every non-NULL left key, so the search loop also steps over it.
#
# Equal (key, asof) pairs on the right keep their input order (the sort is
# stable): BACKWARD takes the last of them and FORWARD the first. DuckDB
# leaves the choice among exact duplicates unspecified.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_op_sort.sort import sort_key_lt
from komira_plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    AsofTolerance,
)

from komira_op_asof.asof_equi_key import EquiKeyCmp
from komira_op_asof.asof_kernel import _find_best_asof


# =============================================================================
# Cell reads
# =============================================================================


@always_inline
def _column_is_null(col: Column[HeapRegion], row: Int) -> Bool:
    """True iff `col[row]` is NULL."""
    if col._validity:
        return not col._validity.value().test(col._offset + row)
    return False


@always_inline
def _read_value[dtype: DType](col: Column[HeapRegion], row: Int) -> Scalar[dtype]:
    """`col[row]` at `dtype`, read in place. The caller has checked that the
    column's storage is `dtype` (`_check_storage`)."""
    return col._data.view_ro().get_typed[Scalar[dtype]](col._offset + row)


def _check_storage[dtype: DType](col: Column[HeapRegion]) raises:
    """Raise unless `col` stores `dtype` values (its own type, or a temporal
    type stored as `dtype`)."""
    _ = col.as_primitive[dtype]()


@always_inline
def _cmp_scalar[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) -> Int:
    """-1 / 0 / +1 in `sort_key_lt` order."""
    if sort_key_lt[dtype](a, b):
        return -1
    if sort_key_lt[dtype](b, a):
        return 1
    return 0


# A STRING cell is `data[offsets[i] .. offsets[i + 1]]`; a DICTIONARY cell is
# the dictionary entry its INT32 index names. Both are read as UTF-8 bytes.


def _string_bounds(col: Column[HeapRegion], row: Int) raises -> Tuple[Int, Int]:
    """(start, length) of the bytes of `col[row]` (non-NULL) in its data
    buffer (STRING) or its dictionary data (DICTIONARY)."""
    if col.arrow_type == ArrowType.STRING:
        if not col._offsets:
            raise Error("asof_walker: STRING column without offsets")
        var offs = col._offsets.value().view_ro()
        var r = col._offset + row
        var start = Int(offs.read_i32_le_at(r * 4))
        var end = Int(offs.read_i32_le_at((r + 1) * 4))
        return (start, end - start)
    elif col.arrow_type == ArrowType.DICTIONARY:
        if col.is_numeric_dict() or not col._offsets or not col._dict_data:
            raise Error(
                "asof_walker: a DICTIONARY equi key must be a string"
                " dictionary"
            )
        var idx = Int(
            col._data.view_ro().read_i32_le_at((col._offset + row) * 4)
        )
        if idx < 0 or idx >= col._dict_size:
            raise Error(
                "asof_walker: dictionary index " + String(idx)
                + " out of range [0, " + String(col._dict_size) + ")"
            )
        var doffs = col._offsets.value().view_ro()
        var start = Int(doffs.read_i32_le_at(idx * 4))
        var end = Int(doffs.read_i32_le_at((idx + 1) * 4))
        return (start, end - start)
    raise Error(
        "asof_walker: unsupported string key type " + String(col.arrow_type)
    )


@always_inline
def _string_byte(col: Column[HeapRegion], at: Int) -> UInt8:
    """Byte `at` of the column's string bytes (dictionary data for a
    DICTIONARY column)."""
    if col.arrow_type == ArrowType.DICTIONARY:
        return col._dict_data.value().view_ro().read_u8_at(at)
    return col._data.view_ro().read_u8_at(at)


def _cmp_strings(
    lc: Column[HeapRegion], lr: Int, rc: Column[HeapRegion], rr: Int
) raises -> Int:
    """Byte-wise lexicographic -1 / 0 / +1 of two non-NULL string cells."""
    var lb = _string_bounds(lc, lr)
    var rb = _string_bounds(rc, rr)
    var l_len = lb[1]
    var r_len = rb[1]
    var n = l_len if l_len < r_len else r_len
    for i in range(n):
        var a = _string_byte(lc, lb[0] + i)
        var b = _string_byte(rc, rb[0] + i)
        if a < b:
            return -1
        if a > b:
            return 1
    if l_len < r_len:
        return -1
    if l_len > r_len:
        return 1
    return 0


# =============================================================================
# Equi-key comparison
# =============================================================================


@always_inline
def _verdict(order: Int) -> EquiKeyCmp:
    """An `EquiKeyCmp` for two non-NULL values: there, order 0 is a match."""
    if order == 0:
        return EquiKeyCmp.equal_and_matched()
    return EquiKeyCmp.ordered(order)


def _cmp_one_column(
    left_col: Column[HeapRegion],
    left_row: Int,
    right_col: Column[HeapRegion],
    right_row: Int,
) raises -> EquiKeyCmp:
    """One key column: NULL sorts before every non-NULL and two NULLs are
    adjacent (order 0), but a NULL on either side never matches."""
    var l_null = _column_is_null(left_col, left_row)
    var r_null = _column_is_null(right_col, right_row)
    if l_null and r_null:
        return EquiKeyCmp.unknown()
    if l_null:
        return EquiKeyCmp.ordered(-1)
    if r_null:
        return EquiKeyCmp.ordered(1)

    var lt = left_col.arrow_type
    var rt = right_col.arrow_type
    var l_str = lt == ArrowType.STRING or lt == ArrowType.DICTIONARY
    var r_str = rt == ArrowType.STRING or rt == ArrowType.DICTIONARY
    if l_str and r_str:
        return _verdict(_cmp_strings(left_col, left_row, right_col, right_row))
    if lt != rt:
        raise Error(
            "compare_equi_keys: left key type " + String(lt)
            + " != right key type " + String(rt)
        )
    if lt == ArrowType.INT64:
        return _verdict(
            _cmp_scalar[DType.int64](
                _read_value[DType.int64](left_col, left_row),
                _read_value[DType.int64](right_col, right_row),
            )
        )
    elif lt == ArrowType.INT32:
        return _verdict(
            _cmp_scalar[DType.int32](
                _read_value[DType.int32](left_col, left_row),
                _read_value[DType.int32](right_col, right_row),
            )
        )
    elif lt == ArrowType.FLOAT64:
        return _verdict(
            _cmp_scalar[DType.float64](
                _read_value[DType.float64](left_col, left_row),
                _read_value[DType.float64](right_col, right_row),
            )
        )
    raise Error(
        "compare_equi_keys: unsupported equi-key type " + String(lt)
        + " (INT32, INT64, FLOAT64, STRING and DICTIONARY are)"
    )


def compare_equi_keys(
    left_batch: RecordBatch,
    left_row: Int,
    right_batch: RecordBatch,
    right_row: Int,
    left_key_cols: List[Int],
    right_key_cols: List[Int],
) raises -> EquiKeyCmp:
    """The equi-key tuples of a left and a right row: their order
    (lexicographic over the columns, NULL first) and whether they match
    (every column equal and non-NULL on both sides). The match, not
    `order == 0`, is the join predicate."""
    if len(left_key_cols) != len(right_key_cols):
        raise Error(
            "compare_equi_keys: key column count mismatch ("
            + String(len(left_key_cols)) + " vs "
            + String(len(right_key_cols)) + ")"
        )
    # A NULL in an earlier column does not end the walk: a later column can
    # still order the tuples, so the unmatched verdict is carried forward.
    var unmatched = False
    for i in range(len(left_key_cols)):
        ref lc = left_batch.column_at(left_key_cols[i])
        ref rc = right_batch.column_at(right_key_cols[i])
        var c = _cmp_one_column(lc, left_row, rc, right_row)
        if c.order != 0:
            return EquiKeyCmp.ordered(c.order)
        if not c.matched:
            unmatched = True
    if unmatched:
        return EquiKeyCmp.unknown()
    return EquiKeyCmp.equal_and_matched()


def compare_keys(
    left_batch: RecordBatch,
    left_row: Int,
    right_batch: RecordBatch,
    right_row: Int,
    left_key_cols: List[Int],
    right_key_cols: List[Int],
) raises -> Int:
    """The ORDER of two equi-key tuples (-1 / 0 / +1); two NULL tuples give 0.
    Not a join predicate: use `compare_equi_keys(...).matched`."""
    return compare_equi_keys(
        left_batch, left_row, right_batch, right_row,
        left_key_cols, right_key_cols,
    ).order


def _key_has_null(batch: RecordBatch, row: Int, key_cols: List[Int]) -> Bool:
    """True iff some equi-key column of `batch` is NULL at `row`."""
    for i in range(len(key_cols)):
        if _column_is_null(batch.column_at(key_cols[i]), row):
            return True
    return False


# =============================================================================
# The walker
# =============================================================================


def asof_merge_into[strategy: UInt8, dtype: DType](
    left_batches: Slab[RecordBatch],
    right_batches: Slab[RecordBatch],
    left_key_cols: List[Int],
    right_key_cols: List[Int],
    left_asof_col: Int,
    right_asof_col: Int,
    tolerance: AsofTolerance,
    mut left_batch_out: List[Int],
    mut left_row_out: List[Int],
    mut right_batch_out: List[Int],
    mut right_row_out: List[Int],
) raises:
    """The two-cursor ASOF merge (see the module header for the matching
    rules). Both sides sorted on `(equi_keys..., asof)` ascending. Appends one
    entry per left row, in left order, to the four output lists; an unmatched
    left row gets -1 in `right_batch_out` and `right_row_out`.

    Raises if an ASOF column does not store `dtype`."""
    var n_left_batches = len(left_batches)
    var n_right_batches = len(right_batches)
    for b in range(n_left_batches):
        _check_storage[dtype](left_batches[b].column_at(left_asof_col))
    for b in range(n_right_batches):
        _check_storage[dtype](right_batches[b].column_at(right_asof_col))

    # The current group: its right rows with a non-NULL ASOF value, as
    # (batch, row) pairs, and their ASOF values in `group_asof`.
    var rg_batch = List[Int]()
    var rg_row = List[Int]()
    var group_asof = List[Scalar[dtype]]()
    # The group's first right row, the key a later left row is checked
    # against (-1: no group).
    var rg_key_batch = -1
    var rg_key_row = -1
    # The right cursor: it only moves forward.
    var rb = 0
    var rr = 0
    var lo_hint = 0

    for lb in range(n_left_batches):
        var lbatch_rows = left_batches[lb].num_rows()
        for lr in range(lbatch_rows):
            # A NULL in the left key matches nothing, and its position in the
            # input says nothing about the cursor: emit it unmatched and leave
            # the cursor and the cached group as they are.
            if _key_has_null(left_batches[lb], lr, left_key_cols):
                left_batch_out.append(lb)
                left_row_out.append(lr)
                right_batch_out.append(-1)
                right_row_out.append(-1)
                continue

            # 1. Does the cached group still serve this left row?
            var need_rebuild = rg_key_batch < 0
            if not need_rebuild:
                var c = compare_equi_keys(
                    left_batches[lb], lr,
                    right_batches[rg_key_batch], rg_key_row,
                    left_key_cols, right_key_cols,
                )
                if not c.matched:
                    need_rebuild = True

            if need_rebuild:
                rg_batch.clear()
                rg_row.clear()
                group_asof.clear()
                rg_key_batch = -1
                rg_key_row = -1
                lo_hint = 0
                # Move the cursor to this left key's group, if there is one.
                while rb < n_right_batches:
                    if rr >= right_batches[rb].num_rows():
                        rb += 1
                        rr = 0
                        continue
                    var c = compare_equi_keys(
                        left_batches[lb], lr,
                        right_batches[rb], rr,
                        left_key_cols, right_key_cols,
                    )
                    if c.order > 0:
                        # The right row is behind the left key (a NULL-keyed
                        # right row always is): step over it.
                        rr += 1
                        continue
                    if c.order < 0 or not c.matched:
                        # Past the left key: no group for it.
                        break
                    # The group starts here. Collect its rows; a NULL-keyed
                    # right row inside the run is stepped over (see the
                    # module header), a NULL ASOF value is left out.
                    rg_key_batch = rb
                    rg_key_row = rr
                    while rb < n_right_batches:
                        if rr >= right_batches[rb].num_rows():
                            rb += 1
                            rr = 0
                            continue
                        var c2 = compare_equi_keys(
                            left_batches[lb], lr,
                            right_batches[rb], rr,
                            left_key_cols, right_key_cols,
                        )
                        if not c2.matched:
                            if _key_has_null(
                                right_batches[rb], rr, right_key_cols
                            ):
                                rr += 1
                                continue
                            break
                        ref rcol = right_batches[rb].column_at(right_asof_col)
                        if not _column_is_null(rcol, rr):
                            rg_batch.append(rb)
                            rg_row.append(rr)
                            group_asof.append(_read_value[dtype](rcol, rr))
                        rr += 1
                    break

            # 2. Probe the group; a NULL left ASOF value matches nothing.
            var best_idx = -1
            ref lcol = left_batches[lb].column_at(left_asof_col)
            if len(group_asof) > 0 and not _column_is_null(lcol, lr):
                _find_best_asof[strategy, dtype](
                    _read_value[dtype](lcol, lr),
                    group_asof,
                    len(group_asof),
                    tolerance,
                    lo_hint,
                    best_idx,
                )

            # 3. Emit.
            left_batch_out.append(lb)
            left_row_out.append(lr)
            if best_idx < 0:
                right_batch_out.append(-1)
                right_row_out.append(-1)
            else:
                right_batch_out.append(rg_batch[best_idx])
                right_row_out.append(rg_row[best_idx])


def _merge_strategy[strategy: UInt8](
    asof_dtype: DType,
    left_batches: Slab[RecordBatch],
    right_batches: Slab[RecordBatch],
    left_key_cols: List[Int],
    right_key_cols: List[Int],
    left_asof_col: Int,
    right_asof_col: Int,
    tolerance: AsofTolerance,
    mut left_batch_out: List[Int],
    mut left_row_out: List[Int],
    mut right_batch_out: List[Int],
    mut right_row_out: List[Int],
) raises:
    """The dtype switch of one strategy."""
    if asof_dtype == DType.int32:
        asof_merge_into[strategy, DType.int32](
            left_batches, right_batches, left_key_cols, right_key_cols,
            left_asof_col, right_asof_col, tolerance,
            left_batch_out, left_row_out, right_batch_out, right_row_out,
        )
    elif asof_dtype == DType.int64:
        asof_merge_into[strategy, DType.int64](
            left_batches, right_batches, left_key_cols, right_key_cols,
            left_asof_col, right_asof_col, tolerance,
            left_batch_out, left_row_out, right_batch_out, right_row_out,
        )
    elif asof_dtype == DType.float64:
        asof_merge_into[strategy, DType.float64](
            left_batches, right_batches, left_key_cols, right_key_cols,
            left_asof_col, right_asof_col, tolerance,
            left_batch_out, left_row_out, right_batch_out, right_row_out,
        )
    else:
        raise Error(
            "asof_merge_dispatch: unsupported asof_dtype " + String(asof_dtype)
            + " (int32, int64 and float64 are)"
        )


def asof_merge_dispatch(
    strategy: UInt8,
    asof_dtype: DType,
    left_batches: Slab[RecordBatch],
    right_batches: Slab[RecordBatch],
    left_key_cols: List[Int],
    right_key_cols: List[Int],
    left_asof_col: Int,
    right_asof_col: Int,
    tolerance: AsofTolerance,
    mut left_batch_out: List[Int],
    mut left_row_out: List[Int],
    mut right_batch_out: List[Int],
    mut right_row_out: List[Int],
) raises:
    """`asof_merge_into` at a run-time strategy (ASOF_BACKWARD, ASOF_FORWARD,
    ASOF_NEAREST) and ASOF dtype (int32, int64, float64); raises on any
    other."""
    if strategy == ASOF_BACKWARD:
        _merge_strategy[ASOF_BACKWARD](
            asof_dtype, left_batches, right_batches, left_key_cols,
            right_key_cols, left_asof_col, right_asof_col, tolerance,
            left_batch_out, left_row_out, right_batch_out, right_row_out,
        )
    elif strategy == ASOF_FORWARD:
        _merge_strategy[ASOF_FORWARD](
            asof_dtype, left_batches, right_batches, left_key_cols,
            right_key_cols, left_asof_col, right_asof_col, tolerance,
            left_batch_out, left_row_out, right_batch_out, right_row_out,
        )
    elif strategy == ASOF_NEAREST:
        _merge_strategy[ASOF_NEAREST](
            asof_dtype, left_batches, right_batches, left_key_cols,
            right_key_cols, left_asof_col, right_asof_col, tolerance,
            left_batch_out, left_row_out, right_batch_out, right_row_out,
        )
    else:
        raise Error(
            "asof_merge_dispatch: unknown strategy " + String(strategy)
            + " (ASOF_BACKWARD, ASOF_FORWARD and ASOF_NEAREST are)"
        )
