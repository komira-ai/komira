# =============================================================================
# scan_binding_gate_wiring — MECHANISM 2 at every terminal execution route
# =============================================================================
#
# WHAT THIS IS. The wiring for `komira_plan_ir/scan_binding_gate
# .check_plan_scan_bindings`, which is the wiring for `scan_resolver
# .check_binding`, which had ZERO PRODUCTION CALLERS. Read that module's header
# first: it states the defect and why it had to be closed BEFORE the in-memory
# payload migration rather than after.
#
# THIS FILE IS SHAPED AFTER THE PLAN VALIDATION GATE ON PURPOSE, INCLUDING ITS
# LEDGER. That gate is the tree's previous instance of exactly this defect (a
# validator with zero callers outside tests, until a module wired it), and the
# review of its landing found that the obvious claim, "wire `_prepare_plan` and
# every materialize route inherits it", WAS FALSE: `_prepare_plan` is reached by
# 5 of the 14 terminal routes. The re-derived enumeration is
# `plan_validation_routes.mojo`, and it is ENFORCED (an unregistered entry token
# raises). Reusing that ledger means this gate inherits a measured coverage story
# instead of inventing an unmeasured one, and means the two gates cannot
# silently disagree about what a "terminal execution route" is.
#
# THE ONE PLACE THE TWO GATES DELIBERATELY DIFFER: THE FLAG.
# `validate_plan_at_entry` is wrapped by every caller in
# `@parameter if PLAN_VALIDATION_COMPILED_IN: if plan_validation_enabled():`,
# which is correct for a DIAGNOSTIC: it should cost nothing unless a developer
# asks for it. This gate is NOT wrapped, in either tier. A memory-safety check
# that is off by default is not a check; it is a comment that compiles. The cost
# is stated and bounded (see `check_plan_scan_bindings`): one tree walk per
# PLAN-COMPILE whose per-leaf work is a single `Int` compare that returns
# immediately for an UNBOUND binding.
#
# THE RESOLVER IS THE CALLER'S, AND IT IS A REAL REGISTRY.
#
# An earlier shape hard-coded `UnboundScanResolver()` on the argument that this
# was the TRUE STATEMENT ABOUT THE TREE at the time. What that actually meant,
# stated plainly:
#
#   `UnboundScanResolver.epoch()` is `SCAN_EPOCH_NONE`, so EVERY handle raised
#   at EVERY terminal route, INCLUDING a handle minted one frame earlier by the
#   very `EngineContext` running the query. There was no such thing as a VALID
#   handle in production, only an absent one.
#
# That is not a safe default. The engine context owns a `ScanRegistry`
# (`komira_scan_source/scan_registry.mojo`) and passes it here, so the gate
# distinguishes the cases it was designed to distinguish instead of collapsing
# three of them onto one error:
#
#   | binding                                   | with Unbound    | with a registry  |
#   |-------------------------------------------|-----------------|------------------|
#   | UNBOUND (a legacy source arm)             | passes          | passes           |
#   | handle from THIS context's registry       | EPOCH_MISMATCH  | PASSES           |
#   | handle from a dead / foreign registry     | EPOCH_MISMATCH  | EPOCH_MISMATCH   |
#   | handle from this registry, slot evicted   | EPOCH_MISMATCH  | HANDLE_NOT_BOUND |
#
# Row 2 is the one that was impossible without a registry; rows 3 and 4 are what
# keeps it safe, and row 1 is the no-regression row.
#
# The resolver is a COMPTIME parameter, so a caller with no registry still
# passes `UnboundScanResolver()` and monomorphizes to the constant-folded
# branch.
# =============================================================================

from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_ir.scan_binding_gate import check_plan_scan_bindings
from komira_scan_source.scan_resolver import ScanResolver, UnboundScanResolver

from .plan_validation_routes import route_index_for_entry


def check_scan_bindings_at_entry[
    RES: ScanResolver
](resolver: RES, plan: LogicalPlan, entry: StaticString) raises -> Int:
    """Run MECHANISM 2 over `plan` at a terminal execution route, against
    `resolver` — the registry the executing context OWNS (mechanism 3).

    Returns the number of binding-backed scan leaves inspected — 0 is the
    correct and expected answer for a plan over legacy (unmigrated) source arms,
    and returning it rather than nothing is what lets a test tell "checked,
    clean" apart from "walked nothing".

    `entry` MUST be a token in `plan_validation_routes`. Unregistered tokens
    raise, so a wiring site cannot be added without declaring, in that ledger,
    which route it covers — the same enforcement `validate_plan_at_entry` has,
    against the same ledger, so the two gates cannot drift apart on what the
    terminal routes are.

    RAISES `SCAN_BINDING_EPOCH_MISMATCH` / `SCAN_BINDING_HANDLE_NOT_BOUND` /
    `SCAN_BINDING_GATE_UNMODELLED_TAG` — see `scan_binding_gate.mojo`.

    ⚠ `resolver` IS AN ARGUMENT RATHER THAN A CONSTRUCTED DEFAULT, and that is
    the whole of this change. A gate that constructs its own resolver can only
    ever answer questions about a resolver that binds nothing.
    """
    if route_index_for_entry(String(entry)) < 0:
        raise Error(
            String("check_scan_bindings_at_entry: unregistered entry token '")
            + String(entry)
            + String("'. Every wiring site must declare which terminal")
            + String(" execution route it covers by adding a row to")
            + String(" komira_sdk_exec/plan_validation_routes.mojo. An")
            + String(" undeclared site is coverage nobody can audit, the")
            + String(" exact claim a review found to be false when it was")
            + String(" assumed rather than enumerated.")
        )
    return check_plan_scan_bindings(resolver, plan)


def check_scan_bindings_at_entry_unbound(
    plan: LogicalPlan, entry: StaticString
) raises -> Int:
    """`check_scan_bindings_at_entry` for a caller that owns no registry.

    Kept as a NAMED entry point rather than a defaulted parameter so that "this
    route has no registry" is a statement someone wrote, greppable, instead of
    an omission that reads identically to the wired form. Every terminal route
    on `EngineContext` uses the resolver-taking form above; this exists for the
    falsifiers and for any future route that genuinely predates a context.
    """
    return check_scan_bindings_at_entry(UnboundScanResolver(), plan, entry)
