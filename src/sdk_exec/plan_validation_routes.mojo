# =============================================================================
# The plan-validation ROUTE LEDGER -- what the dev gate covers, and what it
# does not
# =============================================================================
#
# WHY THIS FILE EXISTS. `validate_plan` was wired at ONE site --
# `EngineContext._prepare_plan` -- and the landing commit said that site was
# the fast-path chokepoint, "so both optimizer doors and every materialize
# route inherit it". THAT CLAIM WAS FALSE. Re-deriving the terminal execution
# routes on `EngineContext` from the source (not from the claim) gives:
#
#   ROUTE                                       reaches _prepare_plan?
#   1  materialize_plan                          YES  (the reference caller)
#   2  materialize_plan_chunked                  YES  (same door)
#   3  materialize_plan_resolved[REG]            YES  (delegates to #1)
#   4  materialize_column_carrier (local/CTE)    YES  (delegates to #1)
#   5  the breaker frames (agg / typed_agg)      YES  (BREAKER door)
#   6  materialize_column_carrier (cloud arm)    NO   -> the cloud-plan route
#   7  materialize_row_plan  (genuine-row arm)   NO   -> execute_row_streaming
#   8  the cloud-plan route                      NO   -> registry leaves
#   9  materialize_single_fs_cloud_plan[FS]      NO   -> SingleFsResolver leaf
#  10  run(*Specs)  N == 1, arrow-IPC arm        NO   -> collect_batches leaf
#  11  run(*Specs)  N >= 2, the forest switch    NO   -> forest executor
#  12  run(IoWriteSpec[S, Snk])                  NO   -> io_run typed leaf
#  13  run(BreakerWriteSpec[B, Snk])             NO   -> breaker_run
#  14  run_typed_collect_fast                    NO   -> takes a SHAPE, no plan
#  15  materialize_inmem_plan                    NO   -> optimize_for_breaker
#  16  materialize_inmem_agg_plan                NO   -> optimize_for_breaker
#
# The cloud-plan route (rows 6 and 8) has no ledger row in this file yet: its
# wiring and its row come with the registry-backed cloud leaf.
#
# ROWS 15 AND 16 ARE NOT ON `EngineContext`: they are free functions in
# `inmem_source_frame.mojo`, which is why an enumeration of "terminal execution
# routes ON EngineContext" did not have them. That framing is what let the
# SCAN-BINDING gate be route-dependent: both bind in-memory payloads (and the
# bind pass REBINDS a stale handle), so a foreign handle was LAUNDERED at these
# two doors and REFUSED at the fourteen above.
#
# WHAT THAT PASS DID **NOT** VERIFY. The typed-frame bind doors (`sort_frame`,
# `join_frame`, `distinct_frame`, `cross_frame`, `window_frame`,
# `partition_topn_frame`, `agg_frame`, `typed_*_frame`, `io_surface`,
# `sort_node`) ALSO open `optimize_for_breaker`, which gates nothing. They were
# believed covered because their CALLERS reach `optimize_full` -- the same
# "covered transitively" claim the `run(*Specs) N==1` row below already flags as
# "exactly the kind of claim that rots silently". It was checked by READING, not
# by driving a foreign handle through each terminal.
#
# Prose is not an accountability mechanism: nothing goes red when a door is
# added or when a sentence here becomes false, and a reader who believed it
# stopped looking. The scan-binding door universe is therefore not enumerated
# here; deriving it from source is not part of this package. The property
# that matters is THE BODY RUNS THE BIND PASS, not "is a method on
# `EngineContext`", which is the framing that hid rows 15 and 16. This file is the ledger of what the plan
# VALIDATION gate covers.
#
# Routes 10 and 11 both pass their RAW plan through `optimize_query` ->
# `optimize_full`, and so does every typed materialize; wiring the gate INSIDE
# `optimize_full` (both overloads) therefore covers them at the door rather than
# at fourteen call sites. Routes 7, 8 and 9 are wired individually because they
# execute without optimizing at all.
#
# WHAT THIS LEDGER IS FOR. Route 14 takes a `_TParquetCollectShape`, not a
# plan -- there is nothing for a plan validator to look at. Routes 12/13 resolve
# a typed source through a leaf that never builds a `LogicalPlan` this entry can
# see. Those are REAL HOLES and the honest thing is to name them, not to let the
# gate imply it covers them.
#
# THE LEDGER IS ENFORCED, NOT DECORATIVE. The plan validation gate looks its
# `entry` argument up here and RAISES on a token that is not a row -- so a new
# wiring site cannot be added without declaring it, and a row cannot be quietly
# deleted while its wiring still runs. `ledger_self_check()` additionally
# requires every COVERED row to name the test that proves it and every
# UNCOVERED row to say what closes it ("Closes when: ...").
# =============================================================================


# -----------------------------------------------------------------------------
# Statuses
# -----------------------------------------------------------------------------

comptime PV_ROUTE_COVERED: UInt8 = 0
"""Wired AND proven: a test in this repo drives the route and shows the gate
raising the validator's finding. `guard` names that test."""

comptime PV_ROUTE_WIRED_UNPROVEN: UInt8 = 1
"""Wired, but no test drives it end-to-end here because the route needs a live
dependency this suite does not have (a cloud object store). `note` says which.
This is weaker than COVERED and is spelled differently on purpose."""

comptime PV_ROUTE_UNCOVERED: UInt8 = 2
"""NOT wired. `note` says why and says what will close it
("Closes when: ...")."""

comptime PV_ROUTE_TEST_HARNESS: UInt8 = 3
"""Not a production route: a token tests use to drive the gate body directly."""


def _write_pv_status_name[W: Writer](mut writer: W, status: UInt8):
    """WRITE what `pv_status_name` returns. THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shipped extension
    module once bound such a pair CROSSED. The arms are therefore written to a
    Writer."""
    if status == PV_ROUTE_COVERED:
        writer.write(String("COVERED"))
        return
    if status == PV_ROUTE_WIRED_UNPROVEN:
        writer.write(String("WIRED_UNPROVEN"))
        return
    if status == PV_ROUTE_UNCOVERED:
        writer.write(String("UNCOVERED"))
        return
    if status == PV_ROUTE_TEST_HARNESS:
        writer.write(String("TEST_HARNESS"))
        return
    writer.write(String("UNKNOWN(" + String(Int(status)) + ")"))
    return


def pv_status_name(status: UInt8) -> String:
    var out = String()
    _write_pv_status_name(out, status)
    return out^


# -----------------------------------------------------------------------------
# A row
# -----------------------------------------------------------------------------


struct PlanValidationRoute(Movable, Copyable):
    """One terminal execution route on `EngineContext`, and what the plan
    validation gate does about it."""

    var route: String
    """The route as a reader would name it, e.g. `EngineContext.optimize_full`."""

    var entry: String
    """The token the wiring passes to `validate_plan_at_entry`. EMPTY for an
    UNCOVERED route (there is no wiring, so there is no token). Unique."""

    var status: UInt8
    var note: String
    """Why this row has the status it has. For UNCOVERED this MUST contain
    "Closes when: ..."; for WIRED_UNPROVEN it MUST say what the missing fixture is."""

    var guard: String
    """The test that proves a COVERED row. Empty otherwise."""

    def __init__(
        out self,
        route: String,
        entry: String,
        status: UInt8,
        note: String,
        guard: String,
    ):
        self.route = route
        self.entry = entry
        self.status = status
        self.note = note
        self.guard = guard

    def copy(self) -> Self:
        return Self(self.route, self.entry, self.status, self.note, self.guard)


# -----------------------------------------------------------------------------
# The ledger
# -----------------------------------------------------------------------------

comptime PV_ENTRY_PREPARE_PLAN: StaticString = "EngineContext._prepare_plan"
comptime PV_ENTRY_OPTIMIZE_FULL: StaticString = "EngineContext.optimize_full"
comptime PV_ENTRY_OPTIMIZE_FULL_CTE: StaticString = (
    "EngineContext.optimize_full(cte)"
)
comptime PV_ENTRY_ROW_PLAN: StaticString = "EngineContext.materialize_row_plan"
comptime PV_ENTRY_SINGLE_FS_CLOUD_PLAN: StaticString = (
    "EngineContext.materialize_single_fs_cloud_plan"
)
comptime PV_ENTRY_INMEM_PLAN: StaticString = (
    "inmem_source_frame.materialize_inmem_plan"
)
comptime PV_ENTRY_INMEM_AGG_PLAN: StaticString = (
    "inmem_source_frame.materialize_inmem_agg_plan"
)
comptime PV_ENTRY_TEST_HARNESS: StaticString = "unit-test"


def plan_validation_routes() -> List[PlanValidationRoute]:
    """THE LEDGER. Every row is a terminal execution route on `EngineContext`
    (plus one test-harness token). Adding a wiring site means adding a row --
    the gate raises on an entry token that is not here."""
    var rows = List[PlanValidationRoute]()

    rows.append(
        PlanValidationRoute(
            String("EngineContext._prepare_plan (materialize_plan,"
                   " materialize_plan_chunked, materialize_plan_resolved,"
                   " materialize_column_carrier local+CTE arms, and both"
                   " breaker-frame doors)"),
            String(PV_ENTRY_PREPARE_PLAN),
            PV_ROUTE_WIRED_UNPROVEN,
            String("The chokepoint. Covers the five routes that reach"
                   " it, on the RAW plan, before optimize. No test in this"
                   " package drives this entry with the validator yet; the"
                   " guard arrives with the slice that holds the context."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.optimize_full (the door optimize_query opens"
                   " for every ctx.run(...) arm -- arrow-IPC multi-RB, text"
                   " sink, binary sink, the N>=2 forest -- and for every typed"
                   " materialize)"),
            String(PV_ENTRY_OPTIMIZE_FULL),
            PV_ROUTE_WIRED_UNPROVEN,
            String("Wired at the top of the no-arg overload, on the plan as"
                   " submitted. This is what makes ctx.run route-covered"
                   " without fourteen separate wirings. No test drives this"
                   " entry with the validator yet."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.optimize_full(plan, cte) -- the 5-arg CTE"
                   " overload, a separate body"),
            String(PV_ENTRY_OPTIMIZE_FULL_CTE),
            PV_ROUTE_WIRED_UNPROVEN,
            String("A separate function body, so it needs its own wiring and"
                   " its own guard; the no-arg overload having one proves"
                   " nothing about this one. No test drives this entry with"
                   " the validator yet."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.materialize_row_plan -- the GENUINE-ROW arm"
                   " (execute_row_streaming direct; never optimizes, never"
                   " reaches _prepare_plan)"),
            String(PV_ENTRY_ROW_PLAN),
            PV_ROUTE_WIRED_UNPROVEN,
            String("Wired at the top, before the three-arm split, so arm 1 (the"
                   " one that bypasses everything) is covered too. No test"
                   " drives this entry with the validator yet."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.materialize_single_fs_cloud_plan[FS] -- the"
                   " SingleFsResolver[FS] arm"),
            String(PV_ENTRY_SINGLE_FS_CLOUD_PLAN),
            PV_ROUTE_WIRED_UNPROVEN,
            String("Wired, but no falsifier here: the route needs a live typed"
                   " filesystem over an object store, which this unit suite"
                   " has no fixture for."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.run(IoWriteSpec[S, Snk]) and"
                   " run(BreakerWriteSpec[B, Snk]) -- the IO-surface write"
                   " terminals"),
            String(""),
            PV_ROUTE_UNCOVERED,
            String("NOT WIRED. Both resolve a source-TYPED frame through a leaf"
                   " (io_run -> materialize_typed_source[S]; breaker_run) that"
                   " never hands a LogicalPlan to a validatable entry, and the"
                   " module header calls that severance load-bearing: naming"
                   " materialize_plan from io_surface would pull the full"
                   " thunk table into every IO-only binary. Closing this needs"
                   " a plan-shaped seam inside those leaves, not a call."
                   " Closes when: a plan-shaped seam exists inside io_run and"
                   " breaker_run."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.run_typed_collect_fast"),
            String(""),
            PV_ROUTE_UNCOVERED,
            String("NOT WIRED, and not wireable as it stands: the parameter is"
                   " a _TParquetCollectShape, not a LogicalPlan -- the plan was"
                   " consumed by the shape detector upstream. Its CALLER"
                   " (materialize_typed_body) does reach optimize_full, so the"
                   " plan is validated one level up; this row exists so that"
                   " fact is written down rather than assumed."
                   " Closes when: the shape carries its plan to a validatable"
                   " entry."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("EngineContext.run(*Specs) N==1, the single-arrow-IPC-sink"
                   " arm that returns from the collect-batches leaf"),
            String(""),
            PV_ROUTE_UNCOVERED,
            String("Not wired DIRECTLY -- but it calls optimize_query ->"
                   " optimize_full BEFORE detecting the collect shape, so it is"
                   " covered transitively by the optimize_full row above. Kept"
                   " as an explicit row because 'covered by something else' is"
                   " exactly the kind of claim that rots silently."
                   " Closes when: a test drives this arm and shows the gate"
                   " firing."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("inmem_source_frame.materialize_inmem_plan -- the TYPED"
                   " IN-MEM terminal (ScanFrame[InMemSource], io_surface's"
                   " in-mem write leg, scan_frame_view)"),
            String(PV_ENTRY_INMEM_PLAN),
            PV_ROUTE_WIRED_UNPROVEN,
            String("This route opens `optimize_for_breaker`"
                   " and NEVER reaches `_prepare_plan` or `optimize_full`, so"
                   " it ran the entry-time BIND with no gate in front of it --"
                   " and the bind pass REBINDS a handle that is not valid"
                   " against the executing registry. A plan carrying another"
                   " context's handle was therefore LAUNDERED here and REFUSED"
                   " at every other door: the same plan, two answers, decided"
                   " by which terminal it entered. The gate now runs at the top,"
                   " BEFORE the bind. No test in this package drives this"
                   " door yet; the guard arrives with the slice that holds it."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("inmem_source_frame.materialize_inmem_agg_plan -- the TYPED"
                   " IN-MEM grouped-agg terminal (InMemAggFrame, agg_frame's"
                   " in-mem arm)"),
            String(PV_ENTRY_INMEM_AGG_PLAN),
            PV_ROUTE_WIRED_UNPROVEN,
            String("Same defect as the row above and a"
                   " SEPARATE function body -- which is the point: the refusal"
                   " was ROUTE-DEPENDENT, so one falsifier cannot show it. This"
                   " row's guard will drive THIS door; no test in this"
                   " package does yet."),
            String(""),
        )
    )
    rows.append(
        PlanValidationRoute(
            String("(test harness)"),
            String(PV_ENTRY_TEST_HARNESS),
            PV_ROUTE_TEST_HARNESS,
            String("The token tests pass when driving the gate body directly,"
                   " without going through an EngineContext route."),
            String(""),
        )
    )
    return rows^


def route_index_for_entry(entry: String) -> Int:
    """The ledger row whose `entry` token is `entry`, or -1. Empty tokens never
    match (an UNCOVERED row has no wiring, so nothing can present its token)."""
    if entry.byte_length() == 0:
        return -1
    var rows = plan_validation_routes()
    for i in range(len(rows)):
        if rows[i].entry == entry:
            return i
    return -1


def ledger_self_check() raises:
    """Raise if the shipped ledger contradicts itself (see
    `ledger_self_check_rows`)."""
    ledger_self_check_rows(plan_validation_routes())


def ledger_self_check_rows(rows: List[PlanValidationRoute]) raises:
    """Raise if `rows`, a ledger, contradicts itself.

    This is the part that makes the ledger a gate rather than a comment:

      * non-empty, and every status is one of the four declared ones;
      * a COVERED / WIRED_UNPROVEN / TEST_HARNESS row has a non-empty, UNIQUE
        entry token (that is what the gate looks up);
      * an UNCOVERED row has an EMPTY entry token -- an unwired route must not
        be able to present a token and be treated as wired;
      * a COVERED row NAMES the test that proves it;
      * an UNCOVERED row says what closes it ("Closes when: ...");
      * every row explains itself (`note` non-empty).
    """
    if len(rows) == 0:
        raise Error("plan-validation route ledger: empty")

    for i in range(len(rows)):
        ref r = rows[i]
        var where = String(" [row " + String(i) + ": " + r.route + "]")

        if (
            r.status != PV_ROUTE_COVERED
            and r.status != PV_ROUTE_WIRED_UNPROVEN
            and r.status != PV_ROUTE_UNCOVERED
            and r.status != PV_ROUTE_TEST_HARNESS
        ):
            raise Error(
                "plan-validation route ledger: unknown status "
                + String(Int(r.status))
                + where
            )

        if r.note.byte_length() == 0:
            raise Error(
                "plan-validation route ledger: every row must say WHY it has"
                " the status it has" + where
            )

        if r.status == PV_ROUTE_UNCOVERED:
            if r.entry.byte_length() != 0:
                raise Error(
                    "plan-validation route ledger: an UNCOVERED route must not"
                    " carry an entry token -- a token means the gate is wired"
                    + where
                )
            if r.note.find(String("Closes when:")) < 0:
                raise Error(
                    "plan-validation route ledger: an UNCOVERED route must say"
                    " what will close it (\"Closes when: ...\")" + where
                )
        else:
            if r.entry.byte_length() == 0:
                raise Error(
                    "plan-validation route ledger: a wired route must carry the"
                    " entry token its wiring passes to the gate" + where
                )
            for j in range(i):
                if rows[j].entry == r.entry:
                    raise Error(
                        "plan-validation route ledger: duplicate entry token '"
                        + r.entry
                        + "'" + where
                    )

        if r.status == PV_ROUTE_COVERED:
            if r.guard.byte_length() == 0:
                raise Error(
                    "plan-validation route ledger: a COVERED route must name"
                    " the test that DRIVES it and shows the gate firing."
                    " Downgrade it to WIRED_UNPROVEN if no such test exists"
                    + where
                )
