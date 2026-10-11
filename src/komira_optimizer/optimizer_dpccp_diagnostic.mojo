# =============================================================================
# Optimizer DPccp -- a trace of one solve: the passes, the scored pairs that
# land on a target subset, and the final DP table
# =============================================================================
#
# `solve_dpccp_with_dp_trace` runs the solver core (`optimizer_dpccp.
# solve_dpccp_observed`) with a recording observer, `DPccpTrace`, and returns
# the plan `solve_dpccp_with_cost` would return for the same chain and cost
# override. The trace answers questions a plan alone cannot: which partitions
# of a subset the enumerator priced and at what cost (the losers included),
# which partition the DP table kept, and how many pairs each pass emitted.
#
# The trace is taken inside the production enumerator, not from a copy of it:
# `emit_pair` and `_run_dpccp_passes` call the observer, so a change to the
# enumeration shows up in the trace.
#
# Repeated emits (komira-ai/komira#1176). This enumerator grows a csg or a
# complement one neighbour at a time and excludes only that neighbour, so on
# dense graphs it scores the same csg-cmp pair more than once (the complete
# graph on four relations: 40 emits, 18 of them for the full set, which has
# 7 partitions). The trace reports them as they happen:
#
#   - `candidates` holds every scored pair whose union is the target subset,
#     in emission order, each repeat as its own entry;
#   - `DPccpPassReport.scored_pairs` counts every scored pair of the pass,
#     repeats included, and `emit_calls` every `emit_pair` call (scored or
#     refused by its guards: the iteration counter's value);
#   - `distinct_target_partitions()` collapses the repeats: it counts the
#     distinct unordered {left, right} partitions among `candidates`, and
#     `repeated_target_emits()` is the difference.
#
# The DP table keeps the first cheapest candidate (a later pair replaces the
# entry only when strictly cheaper), so a repeat never changes the table.
# =============================================================================

from std.collections import Dict

from komira_plan_ir.logical_plan import LogicalPlan
from .optimizer_reorder import JoinChain
from .optimizer_dpccp import DPNode, solve_dpccp_observed
from .optimizer_dpccp_observer import DPCandidate, DPccpObserver


struct DPccpPassReport(Copyable, Movable):
    """What one enumeration pass did.

    Fields:
        allow_cross: True for the cross-product pass, False for the
            literal-edge pass.
        emit_calls: the `emit_pair` calls the pass made, refused ones
            included (the iteration counter's value when it returned).
        scored_pairs: the pairs `emit_pair` scored, repeats included.
        completed: False iff the pass stopped at the iteration cap.
    """

    var allow_cross: Bool
    var emit_calls: UInt64
    var scored_pairs: Int
    var completed: Bool

    def __init__(out self, allow_cross: Bool):
        self.allow_cross = allow_cross
        self.emit_calls = UInt64(0)
        self.scored_pairs = 0
        self.completed = False


struct DPccpTrace(DPccpObserver, Movable):
    """A recording `DPccpObserver` for one target relation subset.

    `solve_dpccp_with_dp_trace` resets it and fills `passes` (one report
    per pass, in order), `candidates` (every scored pair whose union is
    `target_set_bits`) and `dp` (the table the solver read).
    """

    var target_set_bits: UInt64
    var candidates: List[DPCandidate]
    var passes: List[DPccpPassReport]
    var dp: Dict[UInt64, DPNode]

    def __init__(out self, target_set_bits: UInt64):
        self.target_set_bits = target_set_bits
        self.candidates = List[DPCandidate]()
        self.passes = List[DPccpPassReport]()
        self.dp = Dict[UInt64, DPNode]()

    def reset(mut self):
        """Drop everything recorded; keep the target."""
        self.candidates.clear()
        self.passes.clear()
        self.dp.clear()

    def on_pass_begin(mut self, allow_cross: Bool):
        self.passes.append(DPccpPassReport(allow_cross))

    def on_pair_scored(mut self, candidate: DPCandidate):
        self.passes[len(self.passes) - 1].scored_pairs += 1
        if candidate.combined_bits() == self.target_set_bits:
            self.candidates.append(candidate.copy())

    def on_pass_end(mut self, emit_calls: UInt64, completed: Bool):
        ref report = self.passes[len(self.passes) - 1]
        report.emit_calls = emit_calls
        report.completed = completed

    def distinct_target_partitions(self) -> Int:
        """The distinct unordered {left, right} partitions among
        `candidates`: (A, B) and (B, A) count once, and so does every repeat
        of either."""
        var seen = List[Tuple[UInt64, UInt64]]()
        for i in range(len(self.candidates)):
            var left = self.candidates[i].left_set_bits
            var right = self.candidates[i].right_set_bits
            var lo = min(left, right)
            var hi = max(left, right)
            var found = False
            for j in range(len(seen)):
                if seen[j][0] == lo and seen[j][1] == hi:
                    found = True
                    break
            if not found:
                seen.append((lo, hi))
        return len(seen)

    def repeated_target_emits(self) -> Int:
        """`candidates` entries beyond the first of each partition."""
        return len(self.candidates) - self.distinct_target_partitions()

    def entry_for(self, set_bits: UInt64) -> Optional[DPNode]:
        """The DP entry the solve kept for `set_bits`, or None. Its
        `best_left` / `best_right` name the partition that won."""
        return self.dp.get(set_bits)


def solve_dpccp_with_dp_trace(
    chain: JoinChain,
    cost_override: Dict[UInt64, Int],
    mut trace: DPccpTrace,
) raises -> Optional[LogicalPlan]:
    """Solve `chain` as `solve_dpccp_with_cost(chain, cost_override)` does
    and record the solve in `trace` (reset first).

    A chain of fewer than two or more than `DPCCP_MAX_RELATIONS` relations
    is not enumerated: the result is None and the trace stays empty.
    """
    trace.reset()
    var dp = Dict[UInt64, DPNode]()
    var plan = solve_dpccp_observed(chain, cost_override, dp, trace)
    trace.dp = dp^
    return plan^
