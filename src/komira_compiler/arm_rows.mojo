# =============================================================================
# arm_rows.mojo — evaluate an expression over ONLY the rows that ask for it,
# when the whole-batch evaluation raised an integer OVERFLOW.
# =============================================================================
#
# Integer `+ - *` RAISE on overflow
# (`komira_core/eval/int_overflow.mojo`, DuckDB 1.5.3's rule). DuckDB
# evaluates a CASE arm only over the rows its WHEN selects, and the right side of
# an AND / OR only over the rows the left side has not already decided — so
#
#     CASE WHEN a < 100 THEN a + b ELSE 0 END
#     WHERE a < 100 AND a + b > 0
#
# ANSWER there even when `a + b` would overflow on a row the guard excludes.
# This engine evaluates both sides over the whole batch and blends, which was
# exact while nothing could raise — the wrap on an excluded row was never read.
# MEASURED after the checked kernels landed, before this module: both shapes
# above REFUSED where DuckDB answers, and the skins' floor `%`
# (`CASE WHEN <wrong sign> THEN tm + r ELSE tm END`) turned four
# `proj_int_divmod_wide` units at the polars / pandas doors from PASS to REFUSED.
#
# ★ THE FAST PATH IS UNTOUCHED. Callers evaluate over the whole batch exactly as
#   before; only an OVERFLOW raise (`is_int_overflow_error`) takes the retry,
#   which re-evaluates over `batch_nulled_outside(batch, rows)` — the same
#   buffers with every row the arm does NOT answer made NULL. The checked
#   kernels never raise for a NULL row, so a raise on the retry is an overflow on
#   a row the arm really answers (DuckDB raises there too). The caller's blend /
#   Kleene combine reads only the rows it asked for, so the NULLs it introduced
#   are never seen: FALSE AND NULL is FALSE, TRUE OR NULL is TRUE, and a CASE
#   overlay copies only its selected rows.
# ⚠ Any OTHER raise is re-raised unchanged by the callers.
# =============================================================================

from komira_core.arrow.schema import RecordBatch, RecordBatchBuilder
from komira_core.arrow.column import Column
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.io.heap_region import HeapRegion


def batch_nulled_outside(batch: RecordBatch, imm rows: Bitmap[HeapRegion]) raises -> RecordBatch:
    """`batch` with every row NOT set in `rows` made NULL in every column — a
    zero-copy share of each column's buffers with a NEW validity bitmap
    (existing validity AND `rows`), honouring the column's `_offset` (a slice
    shares its parent's bitmap, indexed from `_offset`)."""
    var n = batch.num_rows()
    var ncols = batch.num_columns()
    var rbb = RecordBatchBuilder.with_capacity(ncols)
    for c in range(ncols):
        ref src = batch.column_at(c)
        var col = src.share()
        var off = col._offset
        var bm = Bitmap.create(off + n)
        var nulls = 0
        for i in range(n):
            if rows.test(i) and not src.is_null_at(i):
                bm.set(off + i)
            else:
                nulls += 1
        col._validity = Optional[Bitmap[HeapRegion]](bm^)
        col._null_count = nulls
        rbb.add_column(col^)
    return rbb.build(batch.schema.copy())


def undecided_rows(imm left: BooleanArray, is_or: Bool) -> Bitmap[HeapRegion]:
    """The rows whose AND (`is_or=False`) / OR (`is_or=True`) the LEFT side has
    NOT decided — the only rows DuckDB evaluates the right side on. AND: left
    TRUE or UNKNOWN. OR: left FALSE or UNKNOWN. UNKNOWN is a cleared validity
    bit (this repo's three-valued encoding; its data bit is not read)."""
    var n = left.length
    var rows = Bitmap.create(n)
    var has_validity = Bool(left.validity)
    for i in range(n):
        var unknown = has_validity and not left.validity.value().test(i)
        if unknown or (left.data.test(i) != is_or):
            rows.set(i)
    return rows^
