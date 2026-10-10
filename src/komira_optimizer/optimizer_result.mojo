# =============================================================================
# optimizer_result -- the NON-RAISING return channel for the optimizer boundary
# =============================================================================
#
# THE RULE THIS REALISES. The optimizer-executor contract (a design
# document, not in this tree), "THE THREE ABI RESTRICTIONS":
#
#     "No `raises`. `abi("C")` rejects it outright ... Result struct + status
#      code."
#
# On Mojo 1.0.0, `@export def f(...) abi("C") raises -> T` does not compile:
#
#     error: 'abi("C")' function may not be marked 'raises';
#            remove 'raises' or use 'abi("Mojo")'
#
# — a PARSE refusal on this compiler. So a C-ABI optimizer entry point returns
# a result struct and a status code instead of raising.
#
# =============================================================================
# WHAT THIS IS, AND WHY IT IS NOT A SECOND API
# =============================================================================
#
# `OptimizeResult` is the value a NON-RAISING optimizer entry point returns: a
# `LogicalPlan`, or a status code and the raiser's message. komira_optimizer
# has no driver that orders its passes, and no function in this tree returns
# an `OptimizeResult`; this module is the contract such an entry point is
# designed to use (the type, its status codes and `_classify`).
#
# The design: each non-raising entry point is a `try` / `except` around the
# raising function it wraps, with NO `raises` of its own. The raising function
# stays, for in-process callers; `unwrap_or_raise` adapts back to it.
#
# The optimizer's output is an optimized `LogicalPlan`, and that is what an
# `OptimizeResult` carries. komira_optimizer imports no physical-plan IR
# (komira_physical_plan is not in the closure of its deps, so such an import
# does not resolve): lowering to a physical plan,
# and the doors that check one, belong to the packages that build it, so no
# refusal of theirs is classified here.
#
# ⛔ THIS IS NOT AN ADDITIVE `_v2` API, and the distinction is load-bearing.
# A `_v2` is a second implementation that can drift from the first. These
# wrappers are designed to have NO BODY OF THEIR OWN — each one's entire
# content is a `try: return ok(<the existing call>) except e: return err(...)`.
# There is one implementation, and a divergence between the two spellings is
# not expressible.
#
# ★ THE PRECEDENT, COPIED NOT INVENTED: a C-API module
# (`komira_pyffi/komira_c_api.mojo`, not in this tree) whose `abi("C")` exports
# are each a `try` / `except e:` that lowers the `Error` text out of band and
# returns a NEGATIVE `Int32`. Three of its rules are carried here verbatim:
#
#   1. 0 is OK; every failure is NEGATIVE and DISTINGUISHABLE.
#   2. An error NEVER returns an empty success. `komira_c_api` says it as
#      "NEVER partially fills `out`, and NEVER returns an empty result to mean
#      error"; here that is `_plan` being `None` on every non-OK status, and
#      `take_plan()` returning `None` rather than aborting.
#   3. The raiser's own message survives verbatim. A status code that discards
#      the text turns a diagnosable refusal into a number.
#
# =============================================================================
# WHY THE STATUS SET IS FOUR AND NOT TWO
# =============================================================================
#
# A boolean ok/fail would be honest but useless to the caller across an ABI: an
# `.so` consumer cannot re-read our source to decide what to do. The three
# failure codes are the three classes a caller can act on DIFFERENTLY:
#
#   SCAN_BINDING     the caller handed us a plan carrying a scan handle this
#                    optimizer's registry cannot resolve. The caller's bug, and
#                    fixable by the caller -- rebind and resubmit.
#   UNRESOLVED_DEPS  the plan's scalar dependencies did not reach a fixpoint.
#                    Not the caller's bug and not fixable by resubmitting the
#                    same plan.
#   PASS_REFUSED     a pass refused. The catch-all.
#
# ⚠ CLASSIFICATION IS BY IMPORTED TOKEN, NEVER BY A STRING SPELLED HERE.
# `SCAN_BINDING_EPOCH_MISMATCH` / `SCAN_BINDING_HANDLE_NOT_BOUND` are imported
# from the module that RAISES them (`komira_scan_source.scan_resolver`), so a
# rename moves both sides at once. Re-spelling either literal in this file would
# create a second source of truth for the same token.
#
# ⚠ AND CLASSIFICATION CANNOT MANUFACTURE AN OK. `_classify` is only ever
# reached from an `except` arm, and its most general answer is a FAILURE code,
# not `OPTIMIZE_OK`. An unrecognised message degrades to `PASS_REFUSED` -- the
# safe direction. The inverse (an unrecognised message degrading to OK) is the
# defect this note exists to make unwritable.
# =============================================================================

from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.scan_resolver import (
    SCAN_BINDING_EPOCH_MISMATCH,
    SCAN_BINDING_HANDLE_NOT_BOUND,
)


# -----------------------------------------------------------------------------
# STATUS CODES. 0 = OK; every failure is negative and distinguishable.
# -----------------------------------------------------------------------------

comptime OPTIMIZE_OK: Int32 = 0
"""The optimizer produced a plan. `take_plan()` yields it exactly once."""

comptime OPTIMIZE_ERR_SCAN_BINDING: Int32 = -1
"""The submitted plan carries a scan handle this optimizer cannot resolve.

Classified from the `SCAN_BINDING_EPOCH_MISMATCH` /
`SCAN_BINDING_HANDLE_NOT_BOUND` tokens of `komira_scan_source.scan_resolver`.
The check behind them is a MEMORY-SAFETY check, not a diagnostic: a handle
minted by a dead or foreign `ScanRegistry` must be refused rather than
laundered. Caller-actionable."""

comptime OPTIMIZE_ERR_UNRESOLVED_DEPS: Int32 = -2
"""The plan's scalar dependencies did not reach a fixpoint.

The protocol in `optimizer_scalar_deps.mojo` runs the passes, resolves the
requests they emitted, and re-plans with them bound, under a round cap
(komira_optimizer has no driver that runs it). Exceeding the cap means a pass
is emitting a request nobody consumes, or the query nests deeper than the cap.
Returning a plan anyway would ship an unfolded subquery site that fails much
later, at eval, far from this cause."""

comptime OPTIMIZE_ERR_PASS_REFUSED: Int32 = -3
"""A pass refused, and the class is not one of the above. The catch-all.

Its message is the pass's own `Error` text, unmodified."""


comptime OPTIMIZE_REFUSAL_UNRESOLVED_DEPS: StaticString = (
    "OPTIMIZER_UNRESOLVED_SCALAR_DEPS"
)
"""The named token for the round-cap refusal of the dependency protocol.

⚠ THE RAISE SITE (the round-capped loop, not in this tree) MUST IMPORT THIS,
NOT RE-SPELL IT. It is the only reason
`_classify` can tell that refusal apart from any other pass refusal, and a
second spelling makes the two silently stop matching. Same idiom, and the same
reason, as `SCAN_BINDING_EPOCH_MISMATCH` and the `PLAN_WIRE_*` tokens."""


def _classify(message: String) -> Int32:
    """Map a caught `Error`'s text to a status code.

    ⚠ ONLY EVER CALLED FROM AN `except` ARM. Every arm returns a FAILURE code;
    there is deliberately no path from here to `OPTIMIZE_OK`, so a message this
    function does not recognise degrades to `PASS_REFUSED` (still an error) and
    never to success.
    """
    if message.find(String(SCAN_BINDING_EPOCH_MISMATCH)) >= 0:
        return OPTIMIZE_ERR_SCAN_BINDING
    if message.find(String(SCAN_BINDING_HANDLE_NOT_BOUND)) >= 0:
        return OPTIMIZE_ERR_SCAN_BINDING
    if message.find(String(OPTIMIZE_REFUSAL_UNRESOLVED_DEPS)) >= 0:
        return OPTIMIZE_ERR_UNRESOLVED_DEPS
    return OPTIMIZE_ERR_PASS_REFUSED


# -----------------------------------------------------------------------------
# OptimizeResult -- the boundary value
# -----------------------------------------------------------------------------


struct OptimizeResult(Movable):
    """What the optimizer's non-raising boundary functions return.

    THE INVARIANT, and it is the one the C-API precedent states as "NEVER
    returns an empty result to mean error": `_plan` is populated IF AND ONLY IF
    `_status == OPTIMIZE_OK`. `ok()` is the only constructor that populates it
    and it is the only one that sets `OPTIMIZE_OK`; `err()` refuses to build an
    OK-statused failure (see its body). So `is_ok()` and `has_plan()` cannot
    disagree, and a caller may branch on either.

    Movable, not Copyable, ON PURPOSE: it owns a `LogicalPlan`, which is a deep
    tree. A copy would be a silent deep clone at a boundary whose whole point is
    that the plan crosses as a native value.
    """

    var _status: Int32
    var _message: String
    var _plan: Optional[LogicalPlan]

    def __init__(
        out self, status: Int32, var message: String, var plan: Optional[LogicalPlan]
    ):
        """Private-by-convention. Use `ok()` / `err()`, which cannot build an
        inconsistent value."""
        self._status = status
        self._message = message^
        self._plan = plan^

    @staticmethod
    def ok(var plan: LogicalPlan) -> OptimizeResult:
        """Success. The plan moves in; `take_plan()` moves it out once."""
        return OptimizeResult(OPTIMIZE_OK, String(""), Optional(plan^))

    @staticmethod
    def err(status: Int32, var message: String) -> OptimizeResult:
        """Failure, carrying the raiser's own text and NO plan.

        ⚠ `status` IS FORCED NEGATIVE RATHER THAN TRUSTED. A caller that passed
        `OPTIMIZE_OK` here -- by threading a variable that was not classified,
        say -- would mint a result reporting success while carrying no plan,
        which is precisely the state the struct's invariant forbids and the one
        no downstream check would catch. `PASS_REFUSED` is the safe answer: an
        error whose class we are unsure of is still an error.
        """
        var safe_status = status
        if safe_status >= OPTIMIZE_OK:
            safe_status = OPTIMIZE_ERR_PASS_REFUSED
        return OptimizeResult(safe_status, message^, None)

    @staticmethod
    def from_error(var message: String) -> OptimizeResult:
        """Failure, with the class DERIVED from the raiser's text.

        The shape every `except e:` arm wants: `return OptimizeResult
        .from_error(String(e))`. Classification lives in one place so no two
        entry points can disagree about what a scan-binding refusal is.
        """
        var status = _classify(message)
        return OptimizeResult.err(status, message^)

    def is_ok(self) -> Bool:
        """True iff a plan is present. Never raises."""
        return self._status == OPTIMIZE_OK

    def status(self) -> Int32:
        """The status code. `OPTIMIZE_OK` (0) or one of the negatives."""
        return self._status

    def message(self) -> String:
        """The raiser's own text, or `""` on success. A copy; never raises."""
        return String(self._message)

    def has_plan(self) -> Bool:
        """Whether the plan is still here.

        Distinct from `is_ok()` AFTER `take_plan()` has run: the status is a
        record of what happened and does not change, while the plan is moved out
        exactly once. A second `take_plan()` returns `None` rather than aborting.
        """
        return Bool(self._plan)

    def take_plan(mut self) -> Optional[LogicalPlan]:
        """Move the plan out. Returns `None` on failure OR on a second call.

        ⛔ THE GUARD IS NOT DEFENSIVE PROGRAMMING. `Optional.take()` ABORTS THE
        PROCESS on an empty `Optional`:

            ABORT: .../std/collections/optional.mojo:664:18: `Optional.take()`
                   called on empty `Optional`.

        An unguarded `take()` here would turn the error path of a function whose
        entire purpose is "do not raise across the boundary" into a process
        abort, which is strictly worse than the raise it replaced. The `if`
        below is the whole difference.
        """
        if self._plan:
            return self._plan.take()
        return None

    def unwrap_or_raise(mut self) raises -> LogicalPlan:
        """Adapter back to the raising world, for in-process callers.

        This lets an in-process caller keep calling a raising function while a
        non-raising twin is the one a boundary exports. It raises the ORIGINAL
        message so a caller that never learns about status codes sees exactly
        the error the raising function raised.
        """
        var maybe = self.take_plan()
        if maybe:
            return maybe.take()
        raise Error(self._message)
