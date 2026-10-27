# =============================================================================
# project_dense_f64.mojo: a column-at-a-time evaluator for the FLOAT64
# arithmetic subset of the computed-projection walker
# =============================================================================
#
# `ExpressionExecutor.eval_to_list_f64_from_view` evaluates a translated pool
# recursively: at every node it appends one value per row to a fresh
# `List[Float64]`, and at every column leaf it first copies the column. This
# module evaluates the same pool, in the same node order, with the same
# IEEE-754 operation per element, a chunk of rows per node with SIMD loads and
# stores, and keeps a literal as a scalar operand. Nothing is fused across
# nodes (each operator writes its own chunk), so no FMA contraction can occur
# and the bits are the walker's bits; the differential test checks that bit
# for bit against the walker in the same process.
#
# Evaluation is chunked: `_CHUNK` rows at a time over one scratch buffer
# allocated per column (pool slot `k`'s chunk lives at elements
# `[k * _CHUNK, k * _CHUNK + m)`). A node's region is disjoint from its
# children's because pool slots are distinct, so a kernel never reads the
# region it writes.
#
# The envelope is the walker's arithmetic core and nothing else:
#   * `EXPR_COL` over a FLOAT64 column, or an INT64 column widened to float64
#     with the walker's conversion (the translator puts an INT64 leaf under an
#     F64 operator for mixed INT64/FLOAT64 arithmetic; it refuses mixed
#     INT32/FLOAT64, so an INT32 leaf cannot arrive here);
#   * `EXPR_LIT_F64`, and `EXPR_LIT_I64` widened as the walker widens it;
#   * `EXPR_ADD_F64`, `EXPR_SUB_F64`, `EXPR_MUL_F64`, `EXPR_DIV_F64` (IEEE
#     default: NaN and Inf propagate, x/0 is +-Inf or NaN, no raise).
# Any other node, a column of any other type, or a column name the batch does
# not hold is not admitted, and the caller runs the walker unchanged. The
# admission walk runs before any evaluation, so a decline costs a tree walk.
#
# Input columns are read in place: a borrowed `ref` to the batch's Column,
# loads at `(_offset + row) * 8`, the window the walker's copying accessor
# hands it. The walker ignores validity, and so does this (a NULL slot's
# payload is read in both). A leaf is admitted only when the Column's own type
# equals the schema's (FLOAT64 or INT64), it is not a numeric dictionary, and
# it holds at least the batch's row count.
#
# No UnsafePointer anywhere in this file: the SIMD loops go through
# `PrimitiveArray.load[W]` / `store[W]` and `load_simd` on a borrowed
# Column's buffer.
# =============================================================================

from std.collections import Optional, List
from std.sys.info import simd_width_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_async.runtime.parallel_fork_join_shared import (
    SharedForkJoinHandle,
)
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_buffer.heap_region import HeapRegion
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    EXPR_COL,
    EXPR_LIT_F64,
    EXPR_LIT_I64,
    EXPR_ADD_F64,
    EXPR_SUB_F64,
    EXPR_MUL_F64,
    EXPR_DIV_F64,
)


comptime _W: Int = simd_width_of[DType.float64]()
comptime _CHUNK: Int = 2048
"""Rows per evaluation chunk: 16 KiB per float64 intermediate, so a tree of a
dozen nodes stays cache-resident. A multiple of every SIMD width."""
comptime _LEAF_F64: Int = 1
comptime _LEAF_I64: Int = 2


@always_inline
def _is_dense_binop(kind: Int) -> Bool:
    return (
        kind == EXPR_ADD_F64
        or kind == EXPR_SUB_F64
        or kind == EXPR_MUL_F64
        or kind == EXPR_DIV_F64
    )


def _leaf_kind(imm batch: RecordBatch, ci: Int) raises -> Int:
    """`_LEAF_F64` / `_LEAF_I64` when column `ci` can be read in place as the
    type the walker would read it as, else 0 (not admitted)."""
    var at = batch.column_arrow_type(ci)
    ref col = batch.column_at(ci)
    if col.arrow_type != at or col.is_numeric_dict():
        return 0
    if col._length < batch.num_rows():
        return 0
    if at == ArrowType.FLOAT64:
        return _LEAF_F64
    if at == ArrowType.INT64:
        return _LEAF_I64
    return 0


def _dense_f64_admits(
    imm pool: List[RuntimeExpr],
    idx: Int,
    imm col_names: List[String],
    imm batch: RecordBatch,
    depth: Int,
    mut leaf_ci: List[Int],
    mut leaf_kind: List[Int],
) -> Bool:
    """True iff the subtree at `idx` is entirely inside the envelope (see the
    header), recording each EXPR_COL leaf's batch column position and read
    kind in `leaf_ci` / `leaf_kind` (indexed by pool slot) so the chunk loop
    resolves no name. Reads the pool, the name table and the batch's schema
    and column types; touches no column data. A lookup that would raise
    answers False, so the caller runs the walker, which raises or declines as
    it would have."""
    # A malformed pool (a cycle, a slot out of range) must not recurse
    # forever; the walker would fail on the same pool.
    if depth > 256 or idx < 0 or idx >= len(pool):
        return False
    var node = pool[idx]
    var kind = node.kind
    if kind == EXPR_LIT_F64 or kind == EXPR_LIT_I64:
        return True
    if kind == EXPR_COL:
        if node.col_idx < 0 or node.col_idx >= len(col_names):
            return False
        try:
            var ci = batch.column_by_name(col_names[node.col_idx])
            var lk = _leaf_kind(batch, ci)
            if lk == 0:
                return False
            leaf_ci[idx] = ci
            leaf_kind[idx] = lk
            return True
        except:
            return False
    if _is_dense_binop(kind):
        return _dense_f64_admits(
            pool, node.left, col_names, batch, depth + 1, leaf_ci, leaf_kind
        ) and _dense_f64_admits(
            pool, node.right, col_names, batch, depth + 1, leaf_ci, leaf_kind
        )
    return False


@fieldwise_init
struct _Val(Copyable, ImplicitlyCopyable, Movable):
    """One evaluated node over the current chunk: a scalar that stands for a
    chunk of identical values (a literal, or an operator over two literals),
    or the element offset `slot` of the node's chunk in the scratch buffer."""

    var is_scalar: Bool
    var scalar: Float64
    var slot: Int


@always_inline
def _apply[
    op: Int, width: Int
](
    a: SIMD[DType.float64, width], b: SIMD[DType.float64, width]
) -> SIMD[DType.float64, width]:
    comptime if op == EXPR_ADD_F64:
        return a + b
    elif op == EXPR_SUB_F64:
        return a - b
    elif op == EXPR_MUL_F64:
        return a * b
    else:
        # IEEE-754: x/0 -> +-Inf, 0/0 -> NaN, no raise (the walker's rule).
        return a / b


def _kernel[
    op: Int
](
    mut scratch: PrimitiveArray[DType.float64],
    l: _Val,
    r: _Val,
    dst: Int,
    m: Int,
):
    """`scratch[dst + i] = l[i] op r[i]` for `i` in `[0, m)`; at most one of
    `l` / `r` is a scalar (the caller folds scalar op scalar). Every element of
    the destination window is written by exactly one of the two loops."""
    var vec_end = m - (m % _W)
    var i = 0
    if l.is_scalar:
        var sv = SIMD[DType.float64, _W](l.scalar)
        var s1 = SIMD[DType.float64, 1](l.scalar)
        while i < vec_end:
            scratch.store[_W](
                dst + i, _apply[op, _W](sv, scratch.load[_W](r.slot + i))
            )
            i += _W
        while i < m:
            scratch.store[1](
                dst + i, _apply[op, 1](s1, scratch.load[1](r.slot + i))
            )
            i += 1
    elif r.is_scalar:
        var sv = SIMD[DType.float64, _W](r.scalar)
        var s1 = SIMD[DType.float64, 1](r.scalar)
        while i < vec_end:
            scratch.store[_W](
                dst + i, _apply[op, _W](scratch.load[_W](l.slot + i), sv)
            )
            i += _W
        while i < m:
            scratch.store[1](
                dst + i, _apply[op, 1](scratch.load[1](l.slot + i), s1)
            )
            i += 1
    else:
        while i < vec_end:
            scratch.store[_W](
                dst + i,
                _apply[op, _W](
                    scratch.load[_W](l.slot + i), scratch.load[_W](r.slot + i)
                ),
            )
            i += _W
        while i < m:
            scratch.store[1](
                dst + i,
                _apply[op, 1](
                    scratch.load[1](l.slot + i), scratch.load[1](r.slot + i)
                ),
            )
            i += 1


def _leaf_chunk(
    mut scratch: PrimitiveArray[DType.float64],
    dst: Int,
    imm batch: RecordBatch,
    ci: Int,
    lk: Int,
    lo: Int,
    m: Int,
):
    """Rows `[lo, lo + m)` of column `ci` as float64 into `scratch[dst ...]`,
    read in place (see the header). INT64 is widened with the walker's
    conversion (a numeric cast, round to nearest)."""
    ref col = batch.column_at(ci)
    var base = col._offset + lo
    var vec_end = m - (m % _W)
    var i = 0
    if lk == _LEAF_F64:
        while i < vec_end:
            scratch.store[_W](
                dst + i,
                col._data.load_simd[DType.float64, _W]((base + i) * 8),
            )
            i += _W
        while i < m:
            scratch.store[1](
                dst + i, col._data.load_simd[DType.float64, 1]((base + i) * 8)
            )
            i += 1
    else:
        while i < vec_end:
            scratch.store[_W](
                dst + i,
                col._data.load_simd[DType.int64, _W]((base + i) * 8).cast[
                    DType.float64
                ](),
            )
            i += _W
        while i < m:
            scratch.store[1](
                dst + i,
                col._data.load_simd[DType.int64, 1]((base + i) * 8).cast[
                    DType.float64
                ](),
            )
            i += 1


def _eval_chunk(
    imm pool: List[RuntimeExpr],
    idx: Int,
    imm leaf_ci: List[Int],
    imm leaf_kind: List[Int],
    imm batch: RecordBatch,
    lo: Int,
    m: Int,
    mut scratch: PrimitiveArray[DType.float64],
) raises -> _Val:
    """Evaluate an admitted subtree over rows `[lo, lo + m)`. A non-scalar
    node's chunk lands at `scratch[idx * _CHUNK ...]`."""
    var node = pool[idx]
    var kind = node.kind
    if kind == EXPR_LIT_F64:
        return _Val(True, node.f64, -1)
    if kind == EXPR_LIT_I64:
        return _Val(True, Float64(node.i64), -1)
    var dst = idx * _CHUNK
    if kind == EXPR_COL:
        _leaf_chunk(scratch, dst, batch, leaf_ci[idx], leaf_kind[idx], lo, m)
        return _Val(False, 0.0, dst)
    var l = _eval_chunk(
        pool, node.left, leaf_ci, leaf_kind, batch, lo, m, scratch
    )
    var r = _eval_chunk(
        pool, node.right, leaf_ci, leaf_kind, batch, lo, m, scratch
    )
    if l.is_scalar and r.is_scalar:
        # The walker computes `lhs[k] op rhs[k]` with both lists holding one
        # value in every slot: one scalar op yields that same value.
        var v: Float64
        if kind == EXPR_ADD_F64:
            v = _apply[EXPR_ADD_F64, 1](l.scalar, r.scalar)[0]
        elif kind == EXPR_SUB_F64:
            v = _apply[EXPR_SUB_F64, 1](l.scalar, r.scalar)[0]
        elif kind == EXPR_MUL_F64:
            v = _apply[EXPR_MUL_F64, 1](l.scalar, r.scalar)[0]
        else:
            v = _apply[EXPR_DIV_F64, 1](l.scalar, r.scalar)[0]
        return _Val(True, v, -1)
    if kind == EXPR_ADD_F64:
        _kernel[EXPR_ADD_F64](scratch, l, r, dst, m)
    elif kind == EXPR_SUB_F64:
        _kernel[EXPR_SUB_F64](scratch, l, r, dst, m)
    elif kind == EXPR_MUL_F64:
        _kernel[EXPR_MUL_F64](scratch, l, r, dst, m)
    else:
        _kernel[EXPR_DIV_F64](scratch, l, r, dst, m)
    return _Val(False, 0.0, dst)


def _eval_range(
    imm pool: List[RuntimeExpr],
    root_idx: Int,
    imm leaf_ci: List[Int],
    imm leaf_kind: List[Int],
    imm batch: RecordBatch,
    row_lo: Int,
    row_hi: Int,
    mut scratch: PrimitiveArray[DType.float64],
    mut out: PrimitiveArray[DType.float64],
) raises:
    """Evaluate an admitted expression over rows `[row_lo, row_hi)` into
    `out[row_lo, row_hi)`, `_CHUNK` rows at a time over `scratch` (`len(pool)
    * _CHUNK` doubles). The chunks tile the window with no gap and each writes
    its whole `[lo, lo + m)`, so every element is written exactly once.
    Nothing outside the window is read or written in `out`."""
    var lo = row_lo
    while lo < row_hi:
        var m = min(_CHUNK, row_hi - lo)
        var res = _eval_chunk(
            pool, root_idx, leaf_ci, leaf_kind, batch, lo, m, scratch
        )
        var vec_end = m - (m % _W)
        var i = 0
        if res.is_scalar:
            # A literal-only expression: the walker appends the value per row.
            var sv = SIMD[DType.float64, _W](res.scalar)
            var s1 = SIMD[DType.float64, 1](res.scalar)
            while i < vec_end:
                out.store[_W](lo + i, sv)
                i += _W
            while i < m:
                out.store[1](lo + i, s1)
                i += 1
        else:
            while i < vec_end:
                out.store[_W](lo + i, scratch.load[_W](res.slot + i))
                i += _W
            while i < m:
                out.store[1](lo + i, scratch.load[1](res.slot + i))
                i += 1
        lo += m


def _admit(
    imm pool: List[RuntimeExpr],
    root_idx: Int,
    imm col_names: List[String],
    imm batch: RecordBatch,
    mut leaf_ci: List[Int],
    mut leaf_kind: List[Int],
) -> Bool:
    """Size the per-slot leaf tables and run the admission walk."""
    var np = len(pool)
    leaf_ci = List[Int](capacity=np)
    leaf_kind = List[Int](capacity=np)
    for _ in range(np):
        leaf_ci.append(-1)
        leaf_kind.append(0)
    return _dense_f64_admits(
        pool, root_idx, col_names, batch, 0, leaf_ci, leaf_kind
    )


def try_eval_dense_f64(
    imm pool: List[RuntimeExpr],
    root_idx: Int,
    imm col_names: List[String],
    imm batch: RecordBatch,
) raises -> Optional[Column[HeapRegion]]:
    """The FLOAT64 column of the translated expression rooted at `root_idx`,
    or None when any node is outside the envelope (the caller then runs the
    walker). `col_names` is the walker's column name table: a column leaf's
    `col_idx` names a column, resolved against `batch` by name, as
    `ExpressionExecutor` resolves it.

    The result is a FLOAT64 column of `batch.num_rows()` values with no
    validity bitmap, bit-identical to `eval_to_list_f64_from_view` over the
    identity selection followed by `PrimitiveArray.from_list` (the walker
    drops validity too).

    Runs on the calling thread; `try_eval_dense_f64_pooled` answers the same
    bits over a dispatcher's workers."""
    var leaf_ci = List[Int]()
    var leaf_kind = List[Int]()
    if not _admit(pool, root_idx, col_names, batch, leaf_ci, leaf_kind):
        return None
    var n = batch.num_rows()
    # One scratch allocation per column: `len(pool) * _CHUNK` doubles,
    # zeroed; a region nobody writes is never read.
    var scratch = PrimitiveArray[DType.float64].allocate(len(pool) * _CHUNK)
    var out = PrimitiveArray[DType.float64].allocate_uninitialized(n)
    _eval_range(pool, root_idx, leaf_ci, leaf_kind, batch, 0, n, scratch, out)
    return Optional[Column[HeapRegion]](
        Column.from_primitive[DType.float64](out^)
    )


# =============================================================================
# The pooled form: a row range per task
# =============================================================================
#
# `[0, n)` is split into `_CHUNK`-aligned row ranges, each evaluated on a pool
# task with its own scratch. Every element is computed by the same
# `_eval_chunk` over the same `_CHUNK`-row windows at the same row offsets as
# the serial form (a task boundary is always a chunk boundary), so the bits
# are the serial form's bits.
#
# The `SharedChunkWork` contract (`_DenseF64Work`):
#   * Disjointness: task `t` writes only `out[t * task_rows, min((t + 1) *
#     task_rows, n))`; the ranges tile `[0, n)` exactly. `task_rows` is a
#     multiple of `_CHUNK` (2,048 doubles, 16 KiB), so two tasks never write
#     the same cache line. The input batch is read-only and shared; each
#     task's scratch is its own allocation.
#   * Liveness: the batch is the caller's `imm` borrow, passed as the wave's
#     `input` at its concrete origin; `SharedForkJoinHandle.run` joins every
#     task before it returns, so no task outlives the borrow or the payload.
#   * No reallocation: `out` is allocated at its final length before the
#     wave; tasks only store into live slots.
# No UnsafePointer: `process` recovers its concrete `In` / `P` with `rebind`
# (both are fixed at the one dispatch site, `_dense_run`); the shared input is
# a `Pointer` at the batch's concrete origin (`_DenseIn`).
# =============================================================================


comptime DENSE_PAR_MIN_ROWS: Int = 65_536
"""Below this row count the serial form runs: the work is smaller than one
dispatch of the pool."""
comptime _PAR_MIN_TASK_ROWS: Int = 4 * _CHUNK
"""The smallest per-task range (8,192 rows): a smaller task costs more in
dispatch and scratch than it saves."""


def dense_par_task_rows(n: Int, nw: Int) -> Int:
    """Rows per pool task for an `n`-row column over `nw` workers: one task
    per worker, rounded up to a whole number of `_CHUNK`s and never below
    `_PAR_MIN_TASK_ROWS`, so every task boundary is a chunk boundary (the
    bit-identity argument) and a cache-line boundary (no false sharing).
    Task `t` covers `[t * task_rows, min((t + 1) * task_rows, n))`; the
    ranges tile `[0, n)` exactly. Pure."""
    var per = (n + max(nw, 1) - 1) // max(nw, 1)
    var task_rows = ((per + _CHUNK - 1) // _CHUNK) * _CHUNK
    if task_rows < _PAR_MIN_TASK_ROWS:
        task_rows = _PAR_MIN_TASK_ROWS
    return task_rows


struct _DenseIn[b_o: ImmOrigin](Deinitable):
    """The read-only input every task shares: the caller's batch, borrowed at
    a concrete immutable origin pinned to the driver frame. The wave joins
    before that frame returns, so the batch cannot be dropped under a
    worker."""

    var batch: Pointer[RecordBatch, Self.b_o]

    def __init__(out self, ref [Self.b_o] batch: RecordBatch):
        self.batch = Pointer(to=batch)


struct _DenseOut(Movable, Deinitable):
    """The shared destination: the FLOAT64 output, allocated at its final
    length before the wave. `Optional` so the driver reclaims it with
    `Optional.take()` rather than a partial move."""

    var arr: Optional[PrimitiveArray[DType.float64]]

    def __init__(out self, var arr: PrimitiveArray[DType.float64]):
        self.arr = Optional[PrimitiveArray[DType.float64]](arr^)


@fieldwise_init
struct _DenseF64Work[b_o: ImmOrigin](SharedChunkWork):
    """One pool task: rows `[t * task_rows, min((t + 1) * task_rows, n))`.
    See the contract above."""

    var pool: List[RuntimeExpr]
    var leaf_ci: List[Int]
    var leaf_kind: List[Int]
    var root_idx: Int
    var n: Int
    var task_rows: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # In = _DenseIn[b_o], P = _DenseOut: both fixed at the one dispatch
        # site, `_dense_run`; `rebind` asserts exactly that at instantiation.
        ref inp = rebind[_DenseIn[Self.b_o]](input)
        ref buf = rebind[_DenseOut](payload)
        var lo = chunk_id * self.task_rows
        var hi = min(lo + self.task_rows, self.n)
        if lo >= hi:
            return
        var scratch = PrimitiveArray[DType.float64].allocate(
            len(self.pool) * _CHUNK
        )
        _eval_range(
            self.pool, self.root_idx, self.leaf_ci, self.leaf_kind,
            inp.batch[], lo, hi, scratch, buf.arr.value(),
        )


def _dense_run[
    has_pool: Bool, disp_o: Origin[mut=True], b_o: ImmOrigin
](
    imm inp: _DenseIn[b_o],
    pool_h: SharedForkJoinHandle[has_pool, disp_o],
    var work: _DenseF64Work[b_o],
    var buf: _DenseOut,
    n_tasks: Int,
) raises -> _DenseOut:
    """The wave itself, a function of its own so that the shared input
    arrives as an `imm` argument and `origin_of(inp)` is immutable (the wave
    takes its input at an `ImmOrigin`)."""
    return pool_h.run[
        _DenseF64Work[b_o], _DenseIn[b_o], _DenseOut, origin_of(inp)
    ](work^, inp, buf^, n_tasks)


def try_eval_dense_f64_pooled[
    has_pool: Bool, disp_o: Origin[mut=True]
](
    pool_h: SharedForkJoinHandle[has_pool, disp_o],
    imm pool: List[RuntimeExpr],
    root_idx: Int,
    imm col_names: List[String],
    imm batch: RecordBatch,
    par_on: Bool = True,
) raises -> Optional[Column[HeapRegion]]:
    """`try_eval_dense_f64`, fanned over `pool_h`'s workers when the handle
    carries a pool of at least two workers, the column has at least
    `DENSE_PAR_MIN_ROWS` rows and `par_on` is set. Same admission, same
    answer, bit for bit. `has_pool = False` compiles the fan-out out and is
    `try_eval_dense_f64`."""
    comptime if not has_pool:
        return try_eval_dense_f64(pool, root_idx, col_names, batch)
    else:
        var n = batch.num_rows()
        var nw = pool_h.ptr.value()[].worker_count()
        if n < DENSE_PAR_MIN_ROWS or nw < 2 or not par_on:
            return try_eval_dense_f64(pool, root_idx, col_names, batch)
        var leaf_ci = List[Int]()
        var leaf_kind = List[Int]()
        if not _admit(pool, root_idx, col_names, batch, leaf_ci, leaf_kind):
            return None
        var task_rows = dense_par_task_rows(n, nw)
        var n_tasks = (n + task_rows - 1) // task_rows
        var inp = _DenseIn[origin_of(batch)](batch)
        var res = _dense_run(
            inp,
            pool_h,
            _DenseF64Work[origin_of(batch)](
                pool.copy(), leaf_ci^, leaf_kind^, root_idx, n, task_rows
            ),
            _DenseOut(PrimitiveArray[DType.float64].allocate_uninitialized(n)),
            n_tasks,
        )
        return Optional[Column[HeapRegion]](
            Column.from_primitive[DType.float64](res.arr.take())
        )
