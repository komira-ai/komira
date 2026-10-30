# =============================================================================
# staged_filter — decode a pushed filter's columns conjunct by conjunct
# =============================================================================
#
# A row group's decode filter is one conjunction. Decoding every filter column
# for every row and only then evaluating the predicate materialises values the
# first selective conjunct throws away. This module follows DuckDB's Parquet
# scan (one filter per column, in order, carrying a selection vector):
#   1. The decode-filter stages are split into their top-level AND conjuncts,
#      left to right (`split_and_conjuncts`), the order the evaluator's
#      short-circuit AND uses.
#   2. The LEAD (every column the conjuncts before the first DEFERRED column
#      read) is decoded in full, in one call. Each later conjunct decodes only
#      the columns no earlier one needed, for the rows still alive: a column
#      whose selective decode pays (`SELECTION_VAR_WIDTH`) row-selectively,
#      any other by full decode and gather (`decode_rows_of`).
#   3. Conjuncts are evaluated in GROUPS (a conjunct that needs new columns
#      plus the run after it that needs none), each group as one left-deep
#      AND; after each group the working batch is compacted to its survivors
#      and the row-group survivor mask is refined (`compose_survivors`).
#
# WHEN (`staged_filter_worthwhile`): only when a conjunct after the first
# introduces a column the reader classes `SELECTION_VAR_WIDTH`. A chain of
# fixed-width columns keeps the one-shot decode.
#
# ⛔ SEMANTICS. A WHERE clause keeps a row iff every conjunct is TRUE. Each
# conjunct's mask is reduced to DEFINITE TRUE (`definite_true`: data AND
# validity) before it selects, so UNKNOWN never survives: the answer the
# one-shot three-valued AND gives. A conjunct is only evaluated on rows every
# earlier conjunct kept, the subset the short-circuit AND evaluates it on, so
# it never raises where the one-shot evaluation would not. Conjunct order is
# never changed.
#
# The gate (`staged_filter_enabled`) and the counters live in
# `komira_parquet.staged_filter_trace`.
# =============================================================================

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_batch_eval.evaluate import evaluate_predicate
from komira_column_kernels.comparison import filter_to_indices
from komira_column_kernels.compiler_helpers import collect_expr_cols, gather_batch
from komira_parquet.payload_sel_trace import (
    PAYLOAD_SEL_ALL,
    PAYLOAD_SEL_OFF,
    incr_payload_sel_hit,
)
from komira_parquet.staged_filter_trace import (
    incr_staged_filter_gather,
    incr_staged_filter_sel,
)
from komira_phase_timers.phase_timers import (
    PH_DECODE_FILTER_COLS,
    PH_DECODE_PAYLOAD,
    PH_FILTER,
    PH_STAGED_COMPACT,
    PH_STAGED_DECODE_LATER,
    pt_now,
    pt_record,
)
from komira_plan_expr.expr import BIN_AND, Expr
from komira_scan_planning.reader_factory import (
    Reader,
    SELECTION_FIXED_WIDTH,
    SELECTION_VAR_WIDTH,
)


# -----------------------------------------------------------------------------
# Planning: pure functions over expressions and resolved column indices
# -----------------------------------------------------------------------------


def split_and_conjuncts(expr: Expr, mut out: List[Expr]):
    """Append the top-level AND conjuncts of `expr` to `out`, left to right.
    A non-AND node (an OR, a NOT, a comparison) is one conjunct."""
    if expr.is_binary() and expr.binary_op() == BIN_AND:
        split_and_conjuncts(expr.binary_left_ref(), out)
        split_and_conjuncts(expr.binary_right_ref(), out)
    else:
        out.append(expr.copy())


def _contains(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _index_of(xs: List[Int], v: Int) -> Int:
    for i in range(len(xs)):
        if xs[i] == v:
            return i
    return -1


@fieldwise_init
struct SelectionPlan(Copyable, Movable):
    """Which columns a row-selective decode is asked for.

    Fields:
        pays: the columns the reader classes `SELECTION_VAR_WIDTH`, plus,
              when the caller selects fixed-width too, those it classes
              `SELECTION_FIXED_WIDTH`. Every other column is decoded in full
              and gathered.
    """

    var pays: List[Int]


def first_deferred_conjunct(conjunct_cols: List[List[Int]], plan: SelectionPlan) -> Int:
    """The first conjunct (index >= 1) that introduces a column in
    `plan.pays` no earlier conjunct read; -1 when there is none. Everything
    before it is the LEAD, decoded in full in one call."""
    if len(conjunct_cols) < 2 or len(conjunct_cols[0]) == 0:
        return -1
    var decoded = conjunct_cols[0].copy()
    for j in range(1, len(conjunct_cols)):
        ref cols = conjunct_cols[j]
        for k in range(len(cols)):
            var c = cols[k]
            if _contains(decoded, c):
                continue
            if _contains(plan.pays, c):
                return j
            decoded.append(c)
    return -1


def staged_filter_worthwhile(conjunct_cols: List[List[Int]], plan: SelectionPlan) -> Bool:
    """True when staging defers at least one column whose selective decode
    pays. False when the first conjunct reads no column (no row count to
    stage from) or nothing worth deferring comes after it."""
    return first_deferred_conjunct(conjunct_cols, plan) >= 1


# -----------------------------------------------------------------------------
# Masks
# -----------------------------------------------------------------------------


def definite_true(var m: BooleanArray) raises -> BooleanArray:
    """The rows `m` says are TRUE: data bit set AND valid. An UNKNOWN row
    whose data bit happens to be set cannot leak through."""
    if not m.validity:
        return m^
    var bits = m.data.and_(m.validity.value())
    return BooleanArray.from_bitmap(bits^)


def compose_survivors(outer: BooleanArray, inner: BooleanArray) raises -> BooleanArray:
    """Refine a row-group survivor mask by a mask over its survivors: bit `p`
    of the result is set iff `p` is `outer`'s k-th set bit and `inner[k]` is
    set.

    Raises:
        If `inner.length` is not `outer.true_count()`.
    """
    var idx = filter_to_indices(outer)
    if len(idx) != inner.length:
        raise Error(
            "compose_survivors: inner mask has "
            + String(inner.length)
            + " rows, outer mask keeps "
            + String(len(idx))
        )
    var out = BooleanArray.allocate(outer.length)
    for k in range(len(idx)):
        if inner.data.test(k):
            out.data.set(idx[k])
    return out^


# -----------------------------------------------------------------------------
# Batches
# -----------------------------------------------------------------------------


def hconcat_share(a: RecordBatch, b: RecordBatch) raises -> RecordBatch:
    """`a`'s columns then `b`'s, shared (no byte copy).

    Raises:
        If the two batches have different row counts.
    """
    if a.num_rows() != b.num_rows():
        raise Error(
            "hconcat_share: row counts differ: " + String(a.num_rows()) + " vs " + String(b.num_rows())
        )
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder.with_capacity(a.num_columns() + b.num_columns())
    for i in range(a.num_columns()):
        sb.add_field(a.schema.field_at_unchecked(i))
        builder.add_column(a.column_at(i).share())
    for i in range(b.num_columns()):
        sb.add_field(b.schema.field_at_unchecked(i))
        builder.add_column(b.column_at(i).share())
    return builder.build(sb.build())


def pick_share(
    cols: List[Int],
    a_cols: List[Int],
    a: Optional[RecordBatch],
    b_cols: List[Int],
    b: Optional[RecordBatch],
) raises -> RecordBatch:
    """`cols`, in that order, each taken (shared) from whichever of the two
    partial batches decoded it (`a_cols[i]` names `a`'s column i).

    Raises:
        If a column of `cols` is in neither batch.
    """
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder.with_capacity(len(cols))
    for i in range(len(cols)):
        var at = _index_of(a_cols, cols[i])
        if at >= 0 and a:
            ref ab = a.value()
            sb.add_field(ab.schema.field_at_unchecked(at))
            builder.add_column(ab.column_at(at).share())
            continue
        var bt = _index_of(b_cols, cols[i])
        if bt < 0 or not b:
            raise Error("staged filter: column " + String(cols[i]) + " was decoded by neither partial batch")
        ref bb = b.value()
        sb.add_field(bb.schema.field_at_unchecked(bt))
        builder.add_column(bb.column_at(bt).share())
    return builder.build(sb.build())


# -----------------------------------------------------------------------------
# Execution: generic over the per-file `Reader`
# -----------------------------------------------------------------------------


def selection_plan_for[R: Reader](
    reader: R,
    unit_in_file: Int,
    cols: List[Int],
    preserve_dict: Bool,
    select_fixed_width: Bool,
) -> SelectionPlan:
    """Ask the reader, per column, whether a row-selective decode pays."""
    var pays = List[Int]()
    for i in range(len(cols)):
        var cls = reader.unit_column_selection_class(unit_in_file, cols[i], preserve_dict)
        if cls == SELECTION_VAR_WIDTH or (select_fixed_width and cls == SELECTION_FIXED_WIDTH):
            pays.append(cols[i])
    return SelectionPlan(pays^)


def decode_rows_of[R: Reader](
    reader: R,
    unit_in_file: Int,
    cols: List[Int],
    alive: Optional[BooleanArray],
    plan: SelectionPlan,
    preserve_dict: Bool,
    mut n_selective: Int,
    mut n_gathered: Int,
) raises -> RecordBatch:
    """`cols` of one row group, in `cols` order, for the rows `alive` keeps
    (every row when `alive` is None). The columns in `plan.pays` are asked of
    the row-selective decode as one call; if it declines, they join the rest,
    which are decoded in full and gathered. Adds 1 to `n_selective` /
    `n_gathered` when the call took that leg."""
    if not alive:
        return reader.decode_columns_subset(unit_in_file, cols.copy(), preserve_dict)
    var sel_cols = List[Int]()
    var rest_cols = List[Int]()
    for i in range(len(cols)):
        if _contains(plan.pays, cols[i]):
            sel_cols.append(cols[i])
        else:
            rest_cols.append(cols[i])
    var sel_b: Optional[RecordBatch] = None
    if len(sel_cols) > 0:
        sel_b = reader.decode_columns_subset_selected(unit_in_file, sel_cols.copy(), preserve_dict, alive.value())
        if sel_b:
            n_selective += 1
        else:
            for i in range(len(sel_cols)):
                rest_cols.append(sel_cols[i])
            sel_cols = List[Int]()
    var rest_b: Optional[RecordBatch] = None
    if len(rest_cols) > 0:
        var full = reader.decode_columns_subset(unit_in_file, rest_cols.copy(), preserve_dict)
        rest_b = Optional[RecordBatch](gather_batch(full, filter_to_indices(alive.value())))
        n_gathered += 1
    if not rest_b:
        return sel_b.take()
    if not sel_b:
        # The declined columns were appended to `rest_cols`, so its batch is
        # not in `cols` order; take `cols` from it one by one.
        return pick_share(cols, rest_cols, rest_b, List[Int](), None)
    return pick_share(cols, sel_cols, sel_b, rest_cols, rest_b)


struct StagedFilterOutcome(Movable):
    """What the staged filter leaves for the emit.

    Fields:
        batch:    the filter columns, compacted to the survivors, in `decoded`
                  order (None only when `rows == 0`). When `declined`: the
                  LEAD columns for every row, uncompacted.
        alive:    the row-group survivor mask; None = every row survived.
                  When `declined`: the lead group's mask.
        rows:     the survivor count (0 = nothing survived).
        decoded:  file column indices, in `batch` column order.
        declined: the lead group kept at least half the row group, so staging
                  stopped before compacting anything (`staged_handoff`).
        next_conjunct: when `declined`, the first conjunct not yet evaluated.
    """

    var batch: Optional[RecordBatch]
    var alive: Optional[BooleanArray]
    var rows: Int
    var decoded: List[Int]
    var declined: Bool
    var next_conjunct: Int

    def __init__(
        out self,
        var batch: Optional[RecordBatch],
        var alive: Optional[BooleanArray],
        rows: Int,
        var decoded: List[Int],
        declined: Bool = False,
        next_conjunct: Int = 0,
    ):
        self.batch = batch^
        self.alive = alive^
        self.rows = rows
        self.decoded = decoded^
        self.declined = declined
        self.next_conjunct = next_conjunct


def _and_of(conjuncts: List[Expr], start: Int, end: Int) -> Expr:
    """The left-deep AND of `conjuncts[start:end]` (`end > start`)."""
    var e = conjuncts[start].copy()
    for j in range(start + 1, end):
        e = Expr.binary(BIN_AND, e^, conjuncts[j].copy())
    return e^


def run_staged_filter[R: Reader](
    reader: R,
    unit_in_file: Int,
    conjuncts: List[Expr],
    conjunct_cols: List[List[Int]],
    plan: SelectionPlan,
    preserve_dict: Bool,
) raises -> StagedFilterOutcome:
    """Evaluate `conjuncts` in order, in groups. The LEAD group decodes its
    columns in full, in one call; each later group starts at a conjunct that
    needs new columns and decodes only those, for the rows every earlier group
    kept. A group is evaluated as one left-deep AND of its conjuncts, and the
    working batch is compacted once per group. A lead that keeps at least half
    the rows stops before compacting (`declined`). The caller has checked
    `staged_filter_worthwhile`."""
    var total = reader.unit_num_rows(unit_in_file)
    var first_def = first_deferred_conjunct(conjunct_cols, plan)
    var lead = List[Int]()
    for j in range(max(first_def, 1)):
        ref cj = conjunct_cols[j]
        for k in range(len(cj)):
            if not _contains(lead, cj[k]):
                lead.append(cj[k])
    var decoded = lead.copy()
    var t_lead = pt_now()
    var batch: Optional[RecordBatch] = Optional[RecordBatch](
        reader.decode_columns_subset(unit_in_file, lead.copy(), preserve_dict)
    )
    pt_record[PH_DECODE_FILTER_COLS](t_lead)
    var alive: Optional[BooleanArray] = None
    var rows = total
    var j = 0
    while j < len(conjuncts):
        var need = List[Int]()
        ref cj = conjunct_cols[j]
        for k in range(len(cj)):
            if not _contains(decoded, cj[k]):
                need.append(cj[k])
        if len(need) > 0:
            var n_sel = 0
            var n_gat = 0
            var t_later = pt_now()
            var part = decode_rows_of(reader, unit_in_file, need, alive, plan, preserve_dict, n_sel, n_gat)
            pt_record[PH_STAGED_DECODE_LATER](t_later)
            if n_sel > 0:
                incr_staged_filter_sel(rows, total)
            if n_gat > 0:
                incr_staged_filter_gather()
            var prev = batch.take()
            batch = Optional[RecordBatch](hconcat_share(prev, part))
            for k in range(len(need)):
                decoded.append(need[k])
        var end = j + 1
        while end < len(conjuncts):
            var fits = True
            ref ce = conjunct_cols[end]
            for k in range(len(ce)):
                if not _contains(decoded, ce[k]):
                    fits = False
                    break
            if not fits:
                break
            end += 1
        var t_eval = pt_now()
        var m = definite_true(evaluate_predicate(_and_of(conjuncts, j, end), batch.value()))
        var s = m.true_count()
        pt_record[PH_FILTER](t_eval)
        if s == 0:
            return StagedFilterOutcome(None, None, 0, decoded^)
        if j == 0 and s * 2 >= total:
            # A non-selective lead: compacting now would pay a gather of the
            # lead and of every deferred column that the one-shot route never
            # pays. The caller finishes one-shot, reusing the lead's columns
            # and mask (`staged_handoff`).
            return StagedFilterOutcome(batch^, Optional[BooleanArray](m^), s, decoded^, True, end)
        if s < rows:
            var t_compact = pt_now()
            var prev_b = batch.take()
            batch = Optional[RecordBatch](gather_batch(prev_b, filter_to_indices(m)))
            if alive:
                var outer = alive.take()
                alive = Optional[BooleanArray](compose_survivors(outer, m))
            else:
                alive = Optional[BooleanArray](m^)
            rows = s
            pt_record[PH_STAGED_COMPACT](t_compact)
        j = end
    return StagedFilterOutcome(batch^, alive^, rows, decoded^)


def staged_handoff[R: Reader](
    reader: R,
    unit_in_file: Int,
    mut res: StagedFilterOutcome,
    filter_cols: List[Int],
    conjuncts: List[Expr],
    preserve_dict: Bool,
    mut out_batch: Optional[RecordBatch],
    mut out_mask: Optional[BooleanArray],
) raises:
    """Finish a DECLINED staged filter the one-shot way: decode the filter
    columns the lead did not (full, one call), evaluate the conjuncts after
    the lead group on the full batch, and AND their definite-TRUE mask with
    the lead's. Writes every filter column for every row, in `filter_cols`
    order, to `out_batch`, and the whole predicate's mask to `out_mask`.
    Nothing the lead decoded or evaluated is repeated."""
    var lead_b = res.batch.take()
    var lead_m = res.alive.take()
    var rest = List[Int]()
    for i in range(len(filter_cols)):
        if not _contains(res.decoded, filter_cols[i]):
            rest.append(filter_cols[i])
    var rest_b: Optional[RecordBatch] = None
    if len(rest) > 0:
        var t_rest = pt_now()
        rest_b = Optional[RecordBatch](reader.decode_columns_subset(unit_in_file, rest.copy(), preserve_dict))
        pt_record[PH_DECODE_FILTER_COLS](t_rest)
    var full = pick_share(filter_cols, res.decoded, Optional[RecordBatch](lead_b^), rest, rest_b)
    if res.next_conjunct >= len(conjuncts):
        out_mask = Optional[BooleanArray](lead_m^)
        out_batch = Optional[RecordBatch](full^)
        return
    var t_rest_eval = pt_now()
    var rest_m = definite_true(evaluate_predicate(_and_of(conjuncts, res.next_conjunct, len(conjuncts)), full))
    pt_record[PH_FILTER](t_rest_eval)
    var both = lead_m.data.and_(rest_m.data)
    out_mask = Optional[BooleanArray](BooleanArray.from_bitmap(both^))
    out_batch = Optional[RecordBatch](full^)


def resolve_conjunct_columns[R: Reader](
    reader: R,
    conjuncts: List[Expr],
    mut conjunct_cols: List[List[Int]],
    mut all_cols: List[Int],
) raises -> Bool:
    """Resolve each conjunct's column names to this file's column indices
    (`all_cols` collects the distinct ones). False when a name does not
    resolve (the caller then keeps the one-shot decode)."""
    for j in range(len(conjuncts)):
        var names = List[String]()
        collect_expr_cols(conjuncts[j], names)
        var cs = List[Int]()
        for k in range(len(names)):
            var ci = reader.column_name_to_idx_for_file(names[k])
            if ci < 0:
                return False
            if not _contains(cs, ci):
                cs.append(ci)
            if not _contains(all_cols, ci):
                all_cols.append(ci)
        conjunct_cols.append(cs^)
    return True


def payload_selection_pays[R: Reader](
    reader: R,
    unit_in_file: Int,
    cols: List[Int],
    preserve_dict: Bool,
    payload_mode: Int,
) -> Bool:
    """The all-or-nothing payload selection policy: every column must be one
    the kernel accepts, and, unless the mode is `PAYLOAD_SEL_ALL`, at least
    one must be variable-width."""
    if payload_mode == PAYLOAD_SEL_OFF:
        return False
    var any_var = False
    for i in range(len(cols)):
        var cls = reader.unit_column_selection_class(unit_in_file, cols[i], preserve_dict)
        if cls != SELECTION_VAR_WIDTH and cls != SELECTION_FIXED_WIDTH:
            return False
        if cls == SELECTION_VAR_WIDTH:
            any_var = True
    return any_var or payload_mode == PAYLOAD_SEL_ALL


def staged_emit_batch[R: Reader](
    reader: R,
    unit_in_file: Int,
    mut res: StagedFilterOutcome,
    projection: List[Int],
    payload_mode: Int,
    preserve_dict: Bool,
) raises -> RecordBatch:
    """The survivors' projection, in projection order: filter columns from the
    staged batch, the rest (the payload) decoded for the surviving rows under
    the payload selection mode. Columns are shared, not copied."""
    var fb = res.batch.take()
    var pay = List[Int]()
    for i in range(len(projection)):
        if not _contains(res.decoded, projection[i]):
            pay.append(projection[i])
    var pb_opt: Optional[RecordBatch] = None
    if len(pay) > 0:
        var pplan = SelectionPlan(List[Int]())
        if payload_mode != PAYLOAD_SEL_OFF:
            pplan = selection_plan_for(reader, unit_in_file, pay, preserve_dict, payload_mode == PAYLOAD_SEL_ALL)
        var n_sel = 0
        var n_gat = 0
        var t_pay = pt_now()
        pb_opt = Optional[RecordBatch](
            decode_rows_of(reader, unit_in_file, pay, res.alive, pplan, preserve_dict, n_sel, n_gat)
        )
        pt_record[PH_DECODE_PAYLOAD](t_pay)
        if n_sel > 0:
            incr_payload_sel_hit(res.rows, reader.unit_num_rows(unit_in_file))
    return pick_share(projection, res.decoded, Optional[RecordBatch](fb^), pay, pb_opt)
