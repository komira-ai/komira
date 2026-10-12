# =============================================================================
# subrg_filter_gather — the filtered-chunk arms of the sub-row-group agg route
# =============================================================================
#
# The sub-row-group aggregate route evaluates the WHERE predicate once per
# chunk, as a SelectionVector over the DICTIONARY-PRESERVED chunk. These are
# the decisions and kernels that let it use that selection as the answer
# instead of resolving the dictionary columns to flat values and evaluating
# the predicate a second time:
#
#   * `pred_is_dict_select_safe`: is the selection over the dict-preserved
#     chunk the answer? True only for an AND/OR tree whose every leaf is
#     `column <cmp> literal`, the shape `evaluate_filter_narrowed` answers over
#     a numeric dictionary through its per-code lookup table. Any other shape
#     (arithmetic, a CAST, a function, IN, a literal on the left) keeps the
#     resolve-then-filter arm.
#   * `gather_selected`: the survivors, gathered straight out of the chunk.
#     A dictionary column gathers only its codes and shares its dictionary.
#   * `build_dict_keep_lut` / `compact_codes_by_lut`: when the predicate reads
#     only the group key, evaluate it once per DISTINCT value (the
#     dictionary) into a byte keep-table and compact each chunk's codes in one
#     pass (DuckDB filters a dictionary the same way when it loads it).
#
# A chunk with no survivor is skipped by the caller, not gathered: it folds no
# group and emits no row.
#
# Counters (process-global, relaxed, recorded once per row group by the
# caller): chunks gathered, chunks skipped as empty, chunks compacted from
# codes.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector import SelectionVector
from komira_batch_eval.conjunction import evaluate_filter_narrowed
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_column_kernels.compiler_helpers import gather_batch
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    Expr,
)


def pred_is_dict_select_safe(pred: Expr) -> Bool:
    """True iff `pred` is an AND/OR tree whose every leaf is
    `column <cmp> literal` (cmp in =, <>, <, <=, >, >=) with the column on
    the left."""
    if pred.tag != EXPR_BINARY_OP:
        return False
    var op = pred.binary_op()
    if op == BIN_AND or op == BIN_OR:
        return pred_is_dict_select_safe(pred.binary_left_ref()) and pred_is_dict_select_safe(
            pred.binary_right_ref()
        )
    if op == BIN_EQ or op == BIN_NE or op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE:
        return pred.binary_left_ref().tag == EXPR_COL_REF and pred.binary_right_ref().tag == EXPR_LITERAL
    return False


def pred_refs_only_column(pred: Expr, name: String) -> Bool:
    """True iff every column `pred` reads is `name`. Precondition:
    `pred_is_dict_select_safe(pred)`, so every leaf is `col <cmp> lit`."""
    var op = pred.binary_op()
    if op == BIN_AND or op == BIN_OR:
        return pred_refs_only_column(pred.binary_left_ref(), name) and pred_refs_only_column(
            pred.binary_right_ref(), name
        )
    return pred.binary_left_ref().col_ref_name() == name


def build_dict_keep_lut(
    key_dict: List[Int64],
    name: String,
    arrow_type: ArrowType,
    pred: Expr,
) raises -> List[UInt8]:
    """Evaluate `pred` over the dictionary (entry `i` is row `i` of a
    one-column batch named `name`, typed `arrow_type`) and return a byte
    table of `len(key_dict) + 1` entries: 1 where the entry passes, and a
    trailing 0 sentinel every out-of-range code is clamped onto.

    Raises:
        If `arrow_type` is not INT32 or INT64, or the evaluator raises.
    """
    var d = len(key_dict)
    var col: Column[HeapRegion]
    if arrow_type == ArrowType.INT32:
        var arr = PrimitiveArray[DType.int32].allocate(d)
        for i in range(d):
            arr.set_typed[Scalar[DType.int32]](i, key_dict[i].cast[DType.int32]())
        col = Column.from_primitive(arr^)
    elif arrow_type == ArrowType.INT64:
        var arr = PrimitiveArray[DType.int64].allocate(d)
        for i in range(d):
            arr.set_typed[Scalar[DType.int64]](i, key_dict[i])
        col = Column.from_primitive(arr^)
    else:
        raise Error("build_dict_keep_lut: key type must be INT32 or INT64, got " + String(arrow_type))
    var sb = SchemaBuilder()
    sb.add_field(Field(name, arrow_type, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var batch = rbb.build(sb.build())
    var sel = evaluate_filter_narrowed(batch, pred)
    var lut = List[UInt8](capacity=d + 1)
    for _ in range(d + 1):
        lut.append(UInt8(0))
    for i in range(sel.length()):
        var e = Int(sel.indices.get_typed[Scalar[DType.int32]](i))
        if e >= 0 and e < d:
            lut[e] = UInt8(1)
    return lut^


def compact_codes_by_lut(
    codes: OwnedAlignedBuffer,
    n: Int,
    lut: List[UInt8],
    mut out: OwnedAlignedBuffer,
) raises -> Int:
    """Write the int32 codes of `codes[0:n]` whose `lut` entry is 1 into
    `out`, in order, and return how many; -1 when any code lies outside the
    dictionary (`len(lut) - 1` entries) or the dictionary is empty, so the
    caller takes the arm that names the malformed file.

    `out` must hold `(n + 1) * 4` bytes: the compaction stores every code and
    advances by its keep bit (branch-free).

    Raises:
        If `codes` holds fewer than `n` codes or `out` is smaller than
        `(n + 1) * 4` bytes.
    """
    if n <= 0:
        return 0
    var d = len(lut) - 1
    if codes.len() < n * 4 or out.len() < (n + 1) * 4:
        raise Error("compact_codes_by_lut: buffers too small for " + String(n) + " codes")
    var cview = codes.view_range_ro(0, n * 4)
    var oview = out.view_mut()
    # SAFETY: `cp` reads `n` int32 codes inside `cview` (checked above:
    # `codes.len() >= n * 4`); `op` writes at most `n` int32 slots inside
    # `oview` (`out.len() >= (n + 1) * 4`, and `w <= r + j < n` at every
    # store); `lp` reads `lut[min(code, d)]`, an index in `[0, d]`. The three
    # pointers never leave this function, and the views keep the buffers
    # alive until it returns.
    var cp = cview._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var op = oview._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var lp = lut.unsafe_ptr()
    var ud = UInt32(d)
    var mx = UInt32(0)
    var w = 0
    comptime W = 16
    var r = 0
    while r + W <= n:
        var v = cp.load[width=W](r)
        var uv = v.cast[DType.uint32]()
        var lo = uv.reduce_min()
        var hi = uv.reduce_max()
        mx = max(mx, hi)
        if lo == hi:
            if (lp + Int(min(lo, ud)))[] != 0:
                op.store(w, v)
                w += W
        else:
            for j in range(W):
                var c = (cp + r + j)[]
                var uc = c.cast[DType.uint32]()
                (op + w)[] = c
                w += Int((lp + Int(min(uc, ud)))[])
        r += W
    while r < n:
        var c = (cp + r)[]
        var uc = c.cast[DType.uint32]()
        mx = max(mx, uc)
        (op + w)[] = c
        w += Int((lp + Int(min(uc, ud)))[])
        r += 1
    _ = cview
    _ = oview
    if d == 0 or mx >= ud:
        return -1
    return w


def gather_selected(batch: RecordBatch, sel: SelectionVector) raises -> RecordBatch:
    """The rows of `batch` at `sel`'s indices, in order. Dictionary columns
    stay dictionary-encoded (codes gathered, dictionary shared)."""
    var n = sel.length()
    var idx = List[Int](capacity=n)
    for i in range(n):
        idx.append(Int(sel.indices.get_typed[Scalar[DType.int32]](i)))
    return gather_batch(batch, idx)


# -----------------------------------------------------------------------------
# Counters
# -----------------------------------------------------------------------------


def _init_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is the one fresh allocation above; the scalar is written
    # in place before `OwnedPointer` takes ownership, and `raw` never leaves
    # this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _SUBRG_FILTER_GATHERED = _Global["komira_parquet_subrg_filter_gathered", _init_counter]
comptime _SUBRG_FILTER_SKIPPED = _Global["komira_parquet_subrg_filter_skipped", _init_counter]
comptime _SUBRG_FILTER_KEYLUT = _Global["komira_parquet_subrg_filter_keylut", _init_counter]


def subrg_filter_record(gathered: Int, skipped: Int, keylut: Int) raises:
    """Record one row group's chunk counts (the caller sums per row group)."""
    if gathered > 0:
        _ = _SUBRG_FILTER_GATHERED.get_or_create_ptr()[][].fetch_add(Int64(gathered))
    if skipped > 0:
        _ = _SUBRG_FILTER_SKIPPED.get_or_create_ptr()[][].fetch_add(Int64(skipped))
    if keylut > 0:
        _ = _SUBRG_FILTER_KEYLUT.get_or_create_ptr()[][].fetch_add(Int64(keylut))


def subrg_filter_keylut_count() raises -> Int:
    """Chunks whose survivors were compacted from the decoded codes."""
    return Int(_SUBRG_FILTER_KEYLUT.get_or_create_ptr()[][].load())


def subrg_filter_gathered_count() raises -> Int:
    """Chunks whose survivors were gathered straight from the dict chunk."""
    return Int(_SUBRG_FILTER_GATHERED.get_or_create_ptr()[][].load())


def subrg_filter_skipped_count() raises -> Int:
    """Chunks skipped because no row survived the predicate."""
    return Int(_SUBRG_FILTER_SKIPPED.get_or_create_ptr()[][].load())
