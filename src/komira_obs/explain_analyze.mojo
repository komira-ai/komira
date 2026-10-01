# =============================================================================
# explain_analyze.mojo — EXPLAIN ANALYZE rendering
# =============================================================================
#
# Per-operator metrics rendered in operator order.
#
# SCOPE (this module):
#   * Data model: ExecutionReport — ordered list of (operator_label,
#     MetricsSnapshot) pairs. POD-friendly; embedders pass it across
#     thread boundaries safely.
#   * Renderer: format_metric_value, format_operator_block,
#     format_execution_report. Translates name_id back to a human-readable
#     name via a small well-known-names table (the metric names the engine
#     emits; the FNV-1a hash is comptime-derived from the same StringLiteral
#     so the table cannot drift).
#   * Wiring helpers: record_operator_metrics(report, label, snap) — the
#     single touchpoint executors use to push a per-operator snapshot.
#
# HOW THE REPORT IS FILLED. By-parameter threading of the ExecutionReport
# cannot reach the engine's pipeline breakers: every one is dispatched through
# an erased POD fn-ptr thunk (`komira_sdk`'s walker thunk), whose signature is
# the firewall that stops the heavy executors co-elaborating and wedging the
# compiler. The report is therefore COLLECTED PROCESS-GLOBALLY by
# `explain_analyze_collect.mojo` — a `_Global` table plus an arm flag — from
# the engine's collection seams (every breaker, the scan leaf, and the
# streaming sinks). `build_execution_report()` folds that table back into the
# `ExecutionReport` below, so THIS module's data model and renderer are exactly
# what `ctx.explain_analyze(...)` prints. Rationale in that module's header.
#
# Out-of-scope (still):
#   * EXPLAIN ANALYZE rendering at MorselSegment granularity (showing
#     source / operator chain / sink as distinct nodes within one
#     segment). The current model renders one block per operator
#     instance; segment-tree rendering can layer on top.
#
# Design choices:
#   * Static label per operator instance (the operator class name +
#     optional config hint, e.g. "MapOp(2 exprs)"). The operator passes
#     its own label when recording — no reflection / vtable dispatch.
#   * Well-known metric name table is a small `if/else` ladder keyed on
#     the FNV-1a digest. Adding a new metric name is one entry; the
#     comptime hash check guarantees the digest matches the registration
#     site. Falling through prints the raw `name_id` as a hex string —
#     diagnostic, never silent.
#   * Time values render in microseconds (or milliseconds when >1ms).
#     Counter values render as plain integers. Gauge values render as
#     plain integers (gauge-of-gauges = maximum across workers).
# =============================================================================

from komira_obs.metrics_set import (
    MetricsSnapshot,
    MetricsSnapshotEntry,
    METRIC_KIND_COUNTER,
    METRIC_KIND_TIME,
    METRIC_KIND_GAUGE,
)
from komira_obs.name_registry import _fnv1a_compute


# -----------------------------------------------------------------------------
# OperatorMetricsBlock — one entry in the ExecutionReport
# -----------------------------------------------------------------------------


struct OperatorMetricsBlock(Copyable, Movable, Deinitable):
    """One operator's reduced metrics + a human-readable label.

    `label` is a free-form string the executor passes when recording —
    typically the operator class name plus a one-line config hint
    (e.g. "MapOp(2 exprs)" or "JoinProbeOp(INNER)"). Render order in the
    final report matches insertion order.

    `snapshot` is a MetricsSnapshot summed across every per-worker
    instance of the operator (via `MetricsSnapshot.merge_sum`).
    """

    var label: String
    var snapshot: MetricsSnapshot

    def __init__(out self, var label: String, var snapshot: MetricsSnapshot):
        self.label = label^
        self.snapshot = snapshot^


# -----------------------------------------------------------------------------
# ExecutionReport — top-level container, threaded through the executor
# -----------------------------------------------------------------------------


struct ExecutionReport(Movable, Deinitable):
    """Ordered list of per-operator metrics blocks.

    Built incrementally by the executor as it tears down each operator's
    per-worker slab. The SDK's `DataFrame.explain(analyze=True)` reads
    the report and renders it via `format_execution_report`.

    Append order MUST be the operator order in the segment chain
    (source → first op → ... → sink). Operators only are captured;
    segment / source / sink rendering can layer on top.
    """

    var blocks: List[OperatorMetricsBlock]

    def __init__(out self):
        self.blocks = List[OperatorMetricsBlock]()

    @always_inline
    def count(self) -> Int:
        return len(self.blocks)


def record_operator_metrics(
    mut report: ExecutionReport,
    var label: String,
    var snapshot: MetricsSnapshot,
):
    """Append a per-operator metrics block to the report.

    Called by the executor for each operator after its per-worker slab
    has been reduced/merged. `label` MUST be a stable, human-readable
    operator identifier (class name + optional config hint).
    """
    report.blocks.append(OperatorMetricsBlock(label^, snapshot^))


# -----------------------------------------------------------------------------
# Well-known metric name table
# -----------------------------------------------------------------------------
#
# The engine registers a small fixed set of metric names today
# (rows_processed, rows_emitted, elapsed_compute, groups_built). We
# precompute their FNV-1a digests at comptime via `_fnv1a_compute` —
# same digest the operator registered, by construction. The render
# function does a single linear-scan match against this table.
#
# Adding a new metric name: add ONE entry below + the operator's
# registration site. The comptime hash check ensures the table cannot
# silently drift from the registration sites (a typo on either side
# falls through to the hex-id diagnostic path).


comptime _NAME_ID_ROWS_PROCESSED: UInt32 = _fnv1a_compute("rows_processed")
comptime _NAME_ID_ROWS_EMITTED: UInt32 = _fnv1a_compute("rows_emitted")
comptime _NAME_ID_ROWS_CONSUMED: UInt32 = _fnv1a_compute("rows_consumed")
comptime _NAME_ID_ELAPSED_COMPUTE: UInt32 = _fnv1a_compute("elapsed_compute")
comptime _NAME_ID_GROUPS_BUILT: UInt32 = _fnv1a_compute("groups_built")
comptime _NAME_ID_PEAK_GROUPS_IN_FLIGHT: UInt32 = _fnv1a_compute(
    "peak_groups_in_flight"
)


def _write_name_for_id[W: Writer](mut writer: W, name_id: UInt32):
    """WRITE what `_name_for_id` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library can
    bind such a pair CROSSED, and the host process crashes with it."""
    if name_id == _NAME_ID_ROWS_PROCESSED:
        writer.write(String("rows_processed"))
        return
    if name_id == _NAME_ID_ROWS_EMITTED:
        writer.write(String("rows_emitted"))
        return
    if name_id == _NAME_ID_ROWS_CONSUMED:
        writer.write(String("rows_consumed"))
        return
    if name_id == _NAME_ID_ELAPSED_COMPUTE:
        writer.write(String("elapsed_compute"))
        return
    if name_id == _NAME_ID_GROUPS_BUILT:
        writer.write(String("groups_built"))
        return
    if name_id == _NAME_ID_PEAK_GROUPS_IN_FLIGHT:
        writer.write(String("peak_groups_in_flight"))
        return
    writer.write(String("name#") + String(Int(name_id)))
    return


def _name_for_id(name_id: UInt32) -> String:
    """Translate a comptime FNV-1a metric `name_id` back to its source
    literal. Returns `name#<hex>` for unknown digests so the renderer
    never silently drops a metric.
    """
    var out = String()
    _write_name_for_id(out, name_id)
    return out^


# -----------------------------------------------------------------------------
# Renderers
# -----------------------------------------------------------------------------


def _format_time_value(ns: Int64) -> String:
    """Render a nanosecond duration as us / ms with sensible precision.

    Heuristic:
      * < 1us   → "<1 us"
      * < 1000us → "NNN us"
      * >= 1ms  → "X.YYY ms"
    The renderer is for human eyeballs, not machine consumption.
    """
    if ns <= 0:
        return String("0 us")
    var us_total = ns // Int64(1000)
    if us_total < Int64(1):
        return String("<1 us")
    if us_total < Int64(1000):
        return String(us_total) + " us"
    # >=1ms: render millis with 3-digit micro fraction.
    var ms_whole = us_total // Int64(1000)
    var us_frac = us_total - ms_whole * Int64(1000)
    var frac_str = String(us_frac)
    # Pad to 3 digits.
    while frac_str.byte_length() < 3:
        frac_str = "0" + frac_str
    return String(ms_whole) + "." + frac_str + " ms"


def format_metric_value(name_id: UInt32, kind: UInt8, value: Int64) -> String:
    """Render one (name_id, kind, value) triple as a single-line string.

    Format: `<name>: <value-with-unit>`. Time entries render as
    microseconds / milliseconds; counters and gauges render as plain
    integers.
    """
    var name = _name_for_id(name_id)
    if kind == METRIC_KIND_TIME:
        return name + ": " + _format_time_value(value)
    return name + ": " + String(value)


def format_operator_block(block: OperatorMetricsBlock) -> String:
    """Render a single operator's metrics block as a multi-line string.

    Format:
        <label>
          metrics:
            <name>: <value>
            ...

    A block with zero entries still renders the header so the operator's
    presence is visible (operators that have not yet adopted MetricsSet
    surface as zero-entry blocks today).
    """
    var out = String(block.label) + "\n"
    out += "  metrics:\n"
    var n = block.snapshot.count()
    if n == 0:
        out += "    (no metrics registered)\n"
        return out^
    for i in range(n):
        ref entry = block.snapshot.entries[i]
        out += "    " + format_metric_value(
            entry.name_id, entry.kind, entry.value
        ) + "\n"
    return out^


def format_execution_report(report: ExecutionReport) -> String:
    """Render the full execution report as a multi-line string.

    Format:
        EXPLAIN ANALYZE
        ===============
        <block 1>
        <block 2>
        ...

    Operators render in the order they were appended (segment-chain
    order). Empty report renders the header with "(no operator metrics
    captured)" — diagnostic, never silently empty.
    """
    var out = String("EXPLAIN ANALYZE\n")
    out += "===============\n"
    var n = report.count()
    if n == 0:
        out += "(no operator metrics captured)\n"
        return out^
    for i in range(n):
        out += format_operator_block(report.blocks[i])
    return out^
