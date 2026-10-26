# =============================================================================
# Plan-validation gate -- the dev-flag wiring for `validate_plan` +
# `validate_plan_integrity`
# =============================================================================
#
# BACKGROUND. `plan_validator.validate_plan` (recursive column-reference
# resolution with "Available: [...]" messages, per-side join-key existence,
# sort / distinct / partition key checks) and
# `plan_helpers.validate_plan_integrity` (tag <-> variant-payload
# agreement, sentinel-tag-255 / consumed-plan detection) were both written for
# the production path and both had ZERO callers in `src/` -- every call site was
# a test. This module is the wiring, and the gate that keeps it off the hot
# path.
#
# THE GATE IS TWO-TIER, deliberately:
#
#   1. `PLAN_VALIDATION_COMPILED_IN` -- a module-level `comptime Bool`. Every
#      call site wraps its body in `@parameter if PLAN_VALIDATION_COMPILED_IN:`,
#      so flipping this to False elides the branch, the flag test, and the
#      validator's monomorph from the binary entirely (nothing is emitted,
#      nothing is named). Ships True.
#
#   2. `plan_validation_enabled(armed)` -- the runtime switch. It is a value the
#      caller passes from its own configuration, and it defaults to OFF. This
#      module reads no environment variable.
#
# COST WHEN OFF: with tier 1 compiled in, an OFF run pays exactly ONE flag test
# per gate site per PLAN-COMPILE -- never per row, never per morsel, never per
# batch. The gate sites are enumerated in `plan_validation_routes.mojo` and each
# fires once per materialize / optimize. It is NOT zero instructions; only
# flipping `PLAN_VALIDATION_COMPILED_IN` to False is zero.
#
# -----------------------------------------------------------------------------
# WHAT THE THREE-LENS REVIEW OF THE LANDING COMMIT CHANGED HERE
# -----------------------------------------------------------------------------
#
# FINDING 1 -- THE COVERAGE CLAIM. The landing commit said wiring
# `_prepare_plan` meant "every materialize route inherits it". It does not;
# `_prepare_plan` is reached by 5 of the 14 terminal execution routes on
# `EngineContext`. The re-derived enumeration, the additional wiring, and the
# routes that remain UNCOVERED are in `plan_validation_routes.mojo`. That ledger
# is ENFORCED here: `entry` is looked up in it and an unregistered token RAISES,
# so a new wiring site cannot be added without declaring what it covers.
#
# FINDING 2 -- THE SKIP WAS SILENT. `validate_plan_at_entry` used to `return`
# with NO output when the plan carried a tag the validator does not model. A
# developer who armed the gate to chase a bad column reference in a query
# containing a CTE, view, union, asof-join or cast got silence and concluded the
# plan was valid. THE GATE NOW ALWAYS SAYS WHAT IT DID: every run prints one
# `[PLAN_VALIDATION]` line naming the entry and one of VALIDATED / NOT VALIDATED
# / FAILED, and a NOT VALIDATED line names the tag that caused it.
# `plan_validation_outcome` returns the same thing as a value so a test can
# assert on it without scraping stdout.
#
# WHY THE UNMODELED-TAG SKIP STILL EXISTS (it is a skip, not a pass).
# `plan_validator._validate_plan_node` models only some of the `PLAN_*` tags and
# `raise`s "validate_plan: unknown plan tag N" on the rest (ASOF_JOIN=11,
# UNION=12, VIEW_REF=13, CSE_REF=14, CAST_TO_VARCHAR=15). Two of those
# (VIEW_REF / CSE_REF) are opaque LEAF references whose subtree is not yet
# spliced in, so an enclosing Project/Filter's column refs cannot be resolved
# against a real child schema even in principle before `view_resolution_pass`
# runs. Turning the validator's own incompleteness into a user-visible hard
# failure would make a legitimate `with_cte` / `ctx.view` / union / asof / cast
# query fail the moment an operator armed the gate -- a dev gate that cries wolf
# gets turned off and stops finding real bugs. So the gate SKIPS such a plan,
# SAYS SO, and validates everything else. When the validator covers those five
# tags, `_first_unmodeled_plan_tag` shrinks to `return -1` and is deleted.
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
)
from komira_sdk_exec.plan_validation_routes import route_index_for_entry


# -----------------------------------------------------------------------------
# Tier 1: the comptime kill-switch
# -----------------------------------------------------------------------------

comptime PLAN_VALIDATION_COMPILED_IN: Bool = True
"""Compile the plan-validation gate into the binary at all.

True (shipped): each gate site emits `if plan_validation_enabled(armed): ...` --
one flag test per plan-compile when the switch is off.

False: `@parameter if` drops the whole block at every gate site, so neither
the flag test nor `validate_plan` / `validate_plan_integrity` is emitted or named.
This is the only setting for which the "zero instructions" claim holds.
"""


# -----------------------------------------------------------------------------
# Tier 2: the runtime dev flag
# -----------------------------------------------------------------------------


@always_inline
def plan_validation_enabled(armed: Bool = False) -> Bool:
    """True iff the dev plan-validation gate is armed.

    `armed` is the caller's own configuration value. Default OFF. Pass True to
    make the wired entries (see `plan_validation_routes.mojo`) validate the plan
    they were handed and `EngineContext.optimize_full` assert post-optimizer plan
    integrity.

    The test is paid at PLAN-COMPILE time only (never per-row / per-morsel).
    """
    return armed


# -----------------------------------------------------------------------------
# Plan-tag naming -- so a NOT VALIDATED line names a tag a human recognises
# -----------------------------------------------------------------------------


def _write_plan_tag_name[W: Writer](mut writer: W, tag: UInt8):
    """WRITE what `plan_tag_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shipped library once
    bound such a pair CROSSED."""
    if tag == PLAN_SCAN:
        writer.write(String("PLAN_SCAN"))
        return
    elif tag == PLAN_FILTER:
        writer.write(String("PLAN_FILTER"))
        return
    elif tag == PLAN_PROJECT:
        writer.write(String("PLAN_PROJECT"))
        return
    elif tag == PLAN_AGGREGATE:
        writer.write(String("PLAN_AGGREGATE"))
        return
    elif tag == PLAN_JOIN:
        writer.write(String("PLAN_JOIN"))
        return
    elif tag == PLAN_SORT:
        writer.write(String("PLAN_SORT"))
        return
    elif tag == PLAN_LIMIT:
        writer.write(String("PLAN_LIMIT"))
        return
    elif tag == PLAN_DISTINCT:
        writer.write(String("PLAN_DISTINCT"))
        return
    elif tag == PLAN_TOPN:
        writer.write(String("PLAN_TOPN"))
        return
    elif tag == PLAN_PARTITION_BY:
        writer.write(String("PLAN_PARTITION_BY"))
        return
    elif tag == PLAN_PARTITION_TOPN:
        writer.write(String("PLAN_PARTITION_TOPN"))
        return
    elif tag == PLAN_ASOF_JOIN:
        writer.write(String("PLAN_ASOF_JOIN"))
        return
    elif tag == PLAN_UNION:
        writer.write(String("PLAN_UNION"))
        return
    elif tag == PLAN_VIEW_REF:
        writer.write(String("PLAN_VIEW_REF"))
        return
    elif tag == PLAN_CSE_REF:
        writer.write(String("PLAN_CSE_REF"))
        return
    elif tag == PLAN_CAST_TO_VARCHAR:
        writer.write(String("PLAN_CAST_TO_VARCHAR"))
        return
    writer.write(String("<unnamed plan tag " + String(Int(tag)) + ">"))
    return


def plan_tag_name(tag: UInt8) -> String:
    """The `PLAN_*` constant name for `tag`, for each of the 16 tags 0..15
    declared in `logical_plan.mojo`. Any other tag comes back as
    `<unnamed plan tag N>`."""
    var out = String()
    _write_plan_tag_name(out, tag)
    return out^


# -----------------------------------------------------------------------------
# The unmodeled-tag scan -- returns WHICH tag, so the skip can name it
# -----------------------------------------------------------------------------


def _first_unmodeled_plan_tag(plan: LogicalPlan) -> Int:
    """The first tag in this subtree that `validate_plan` does not model, or -1.

    `_validate_plan_node` handles SCAN / FILTER / PROJECT / AGGREGATE / JOIN /
    SORT / LIMIT / DISTINCT / TOPN / PARTITION_BY / PARTITION_TOPN and raises
    "unknown plan tag" for everything else. Traversal is complete over every
    child-bearing modeled tag (same shape as
    `plan_validator._subtree_has_offset_limit`) so an unmodeled tag cannot hide
    under a modeled one.

    Returns the TAG rather than a Bool because the gate has to NAME it -- a skip
    that does not say what it skipped is the silence this whole file exists to
    stop producing.
    """
    if plan.tag == PLAN_SCAN:
        return -1
    elif plan.tag == PLAN_FILTER:
        return _first_unmodeled_plan_tag(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _first_unmodeled_plan_tag(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return _first_unmodeled_plan_tag(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        var l = _first_unmodeled_plan_tag(plan._join.value()[].left[])
        if l >= 0:
            return l
        return _first_unmodeled_plan_tag(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return _first_unmodeled_plan_tag(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return _first_unmodeled_plan_tag(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _first_unmodeled_plan_tag(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _first_unmodeled_plan_tag(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        return _first_unmodeled_plan_tag(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        return _first_unmodeled_plan_tag(plan._partition_topn.value()[].child[])
    # ASOF_JOIN / UNION / VIEW_REF / CSE_REF / CAST_TO_VARCHAR (and any tag
    # added later without a validator arm) land here.
    return Int(plan.tag)


def _plan_has_unmodeled_tag(plan: LogicalPlan) -> Bool:
    """True iff this subtree contains a tag `validate_plan` does not model.
    Thin predicate over `_first_unmodeled_plan_tag`, kept because callers that
    only need the yes/no read better for it."""
    return _first_unmodeled_plan_tag(plan) >= 0


# -----------------------------------------------------------------------------
# The OUTCOME -- what the gate did, as a value
# -----------------------------------------------------------------------------

comptime PV_STATUS_VALIDATED: UInt8 = 0
"""The whole plan tree was walked and no violation was found."""

comptime PV_STATUS_NOT_VALIDATED: UInt8 = 1
"""VALIDATION DID NOT RUN -- the plan carries a tag the validator does not
model. This is NOT a pass. `unmodeled_tag` names the tag."""

comptime PV_STATUS_FAILED: UInt8 = 2
"""A violation was found; `message` carries the validator's finding."""


struct PlanGateOutcome(Movable):
    """What one run of the entry gate did, as a value rather than as stdout.

    Exists because FINDING 2 was precisely that the gate had no way to say "I
    did not run" -- a `None`-returning function that also printed nothing gives
    a caller (and a test) nothing to distinguish from success.
    """

    var status: UInt8
    var entry: String
    var unmodeled_tag: Int
    """The plan tag that stopped validation, or -1."""
    var message: String
    """The exact one-line report `validate_plan_at_entry` prints."""
    var num_unvalidated_exprs: Int
    """Expression sites the walk reached but could not check (see
    `plan_validator.PlanValidationReport`). Zero means the walk was complete."""
    var detail: String
    """The validator's finding (FAILED) or the not-validated notes; empty when
    the plan validated cleanly and completely."""

    def __init__(
        out self,
        status: UInt8,
        entry: String,
        unmodeled_tag: Int,
        message: String,
        num_unvalidated_exprs: Int,
        detail: String,
    ):
        self.status = status
        self.entry = entry
        self.unmodeled_tag = unmodeled_tag
        self.message = message
        self.num_unvalidated_exprs = num_unvalidated_exprs
        self.detail = detail

    @always_inline
    def validated(self) -> Bool:
        return self.status == PV_STATUS_VALIDATED

    @always_inline
    def ran_at_all(self) -> Bool:
        """False iff the gate declined to validate this plan. The distinction
        `validated()` alone cannot express."""
        return self.status != PV_STATUS_NOT_VALIDATED


# -----------------------------------------------------------------------------
# The two gate entries
# -----------------------------------------------------------------------------


def plan_validation_outcome(
    plan: LogicalPlan, entry: StaticString
) raises -> PlanGateOutcome:
    """Run the entry gate and RETURN what happened. Does not print and does not
    raise on a validation failure -- the failure is IN the outcome, so a caller
    (or a test) can inspect all three results uniformly.

    Raises only if `entry` is not a token in `plan_validation_routes`. That is
    the ledger enforcement: a wiring site that has not declared what route it
    covers fails loudly at the first plan it sees, rather than quietly adding
    coverage nobody wrote down.

    Args:
        plan: The plan the executor was handed.
        entry: The route's ledger entry token.

    Returns:
        What the gate did.

    Raises:
        Error if `entry` is not registered in the route ledger.
    """
    from komira_sdk.plan_validator import PlanValidationReport, validate_plan_report

    var entry_s = String(entry)
    if route_index_for_entry(entry_s) < 0:
        raise Error(
            "PLAN_VALIDATION_UNREGISTERED_ENTRY: '"
            + entry_s
            + "' is not a row in `plan_validation_routes.plan_validation_routes"
            "()`. Every gate site must declare the route it covers there --"
            " that ledger is what stops the gate claiming coverage it does not"
            " have (FINDING 1)."
        )

    var unmodeled = _first_unmodeled_plan_tag(plan)
    if unmodeled >= 0:
        var msg = String(
            "[PLAN_VALIDATION] NOT VALIDATED at "
            + entry_s
            + ": validation DID NOT RUN. The plan contains "
            + plan_tag_name(UInt8(unmodeled))
            + " (tag "
            + String(unmodeled)
            + "), which `plan_validator._validate_plan_node` does not model, so"
            " NO column reference in this plan was checked. This is not a clean"
            " bill of health."
        )
        return PlanGateOutcome(
            PV_STATUS_NOT_VALIDATED, entry_s, unmodeled, msg, 0, String("")
        )

    var report: PlanValidationReport
    try:
        report = validate_plan_report(plan)
    except e:
        var detail = String(e)
        var fmsg = String(
            "[PLAN_VALIDATION] FAILED at " + entry_s + ": " + detail
        )
        return PlanGateOutcome(
            PV_STATUS_FAILED, entry_s, -1, fmsg, 0, detail
        )

    var notes = report.summary()
    var n_notes = report.num_unvalidated()
    var ok = String(
        "[PLAN_VALIDATION] VALIDATED at "
        + entry_s
        + ": every plan node walked, no violation found"
    )
    if n_notes > 0:
        ok += " -- but " + notes
    return PlanGateOutcome(
        PV_STATUS_VALIDATED, entry_s, -1, ok, n_notes, notes
    )


def validate_plan_at_entry(plan: LogicalPlan, entry: StaticString) raises:
    """Dev-gate body for a wired execution route: run `validate_plan` on the
    plan the executor was handed, SAY WHAT IT DID, and re-raise any finding
    named as a plan-validation failure at `entry`.

    The caller is responsible for the `@parameter if PLAN_VALIDATION_COMPILED_IN`
    + `plan_validation_enabled(armed)` guards -- this function is the body, not the
    gate, so a test can drive it directly without arming the gate.

    ALWAYS PRINTS EXACTLY ONE LINE. That is deliberate and is the FINDING 2 fix:
    the previous version returned in silence when it declined to validate, which
    is indistinguishable from success at the only place it matters (a developer
    reading their terminal). One line per plan-compile is the cost of a dev flag
    the user opted into; silence was the cost of a diagnostic that lies.

    `entry` MUST be a token in `plan_validation_routes` -- see
    `plan_validation_outcome`.
    """
    var outcome = plan_validation_outcome(plan, entry)
    print(outcome.message)
    if outcome.status == PV_STATUS_FAILED:
        raise Error(
            "plan validation failed at "
            + String(entry)
            + ": "
            + outcome.detail
        )
    _ = outcome^


def assert_plan_integrity(plan: LogicalPlan, stage: StaticString) raises:
    """Dev-gate body for the post-optimizer check: raise if
    `validate_plan_integrity` reports the plan is structurally corrupt.

    `validate_plan_integrity` returns a Bool and prints the specific violation;
    this turns that into a raise so the corrupt plan never reaches the executor.
    The caller owns the `@parameter if` + `plan_validation_enabled` guards.
    """
    from komira_plan_ir.plan_helpers import validate_plan_integrity

    if not validate_plan_integrity(plan):
        raise Error(
            "plan integrity failed after "
            + String(stage)
            + ": the plan is structurally corrupt (tag <-> payload disagreement"
            " or a consumed/moved-from node). The specific violation was"
            " printed above."
        )
