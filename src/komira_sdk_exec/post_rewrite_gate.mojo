"""THE REWRITE GATE: a REWRITE MAY NOT INTRODUCE A VALUE THE DOOR REFUSES.

THE DEFECT, reproduced in one process through the plan-stream route:

    name > 3            REFUSED BY NAME   (PLAN_WIRE_INCOMPARABLE_LITERAL)
    name > (3 + 0)      ALL SIX ROWS      no error, wrong answer

The optimizer's expression folder folds `3 + 0` to `3` INSIDE execution, after
`plan_wire_check_values` graded the message's tree and before the predicate
evaluator read it. The door was NOT wrong about the bytes it received:
`name > (int 3 + int 0)` really is an arithmetic comparand, and an INT really
does survive INT arithmetic. The door graded one expression and the executor
evaluated a different one.

NO MIRROR CAN CLOSE THIS. There is no reader here to mirror; there is a
REWRITE. Teaching the door to constant-fold would be one more mirror of a
reader (the folder itself) and would drift the moment that function learns an
arm. The known falsifier says so out loud: `name > (3 + 0.5)` is an INT plus a
FLOAT, which the folder has NO arm for, so it does not fold and it WALLS
LOUDLY. The bypass exists exactly where the fold SUCCEEDS. A check keyed on
"there is arithmetic here" is therefore the wrong shape: the check has to be
about what the rewrite PRODUCES.

THE INVARIANT THIS FILE ENFORCES, IN ONE SENTENCE:

    if the plan the optimizer was HANDED carries no incomparable literal,
    the plan the optimizer PRODUCES must not carry one either.

Both halves are the SAME function, `plan_wire_check_values`, called twice on
two plan values. Nothing is restated, so there is no second opinion to drift
from the first, and an optimizer pass written next year is covered without an
edit.

THE TWO QUALIFIERS IN THAT SENTENCE, "was handed" and "incomparable literal",
ARE NOT HEDGES. Each was forced by a measurement that turned a real test red,
and each is written up at its own guard below (`plan_values_are_admissible` and
the token check in `check_values_after_rewrite`). A version of this file without
them refused a SEMI JOIN THAT ANSWERS CORRECTLY.

WHY IT IS A DIFFERENCE AND NOT SIMPLY "RUN THE DOOR AFTER THE OPTIMIZER". A
gate that refuses every door-refusable plan on every route deletes the repo's
only instrument for the question "what does this engine actually DO with a
shape the door refuses": that measurement goes through `materialize_plan`
deliberately, because the plan decoder refuses those shapes and a measurement
through the door could only ever report "refused". Standing down when the INPUT
was already refusable keeps that instrument: `SELECT TRUE AS v` is refusable
before the optimizer touches it, so this gate says nothing about it and the
engine's actual behaviour stays measurable.

IT ALSO NARROWS THE BLAST RADIUS TO THE DEFECT. The difference form can only
refuse a plan that was CLEAN going in and DIRTY coming out, which is the class,
exactly. The unconditional form would apply the wire door's whole refusal
policy to every in-process DataFrame and SQL query, including rules known to be
narrower than the executor (`s IN ('bb', NULL)` is refused although SQL says
[2]). Those rules are calibrated for a foreign producer at an admission
boundary; promoting them to a universal execution precondition is a much larger
change than this gate.

THE LIMIT, STATED: a plan that was ALREADY refusable and then has a DIFFERENT
violation introduced by a rewrite is NOT protected; the gate stands down on the
first fact. For the wire path that case does not exist, because the decoder
already refused; for an in-process caller it means the gate protects plans that
were admissible to begin with. That is the honest scope.

WHY HERE, IN `_prepare_plan`, AND NOT AT `materialize_plan`
------------------------------------------------------------
`_prepare_plan` has TWO FAST-ANSWER arms below the optimizer, the
`PROJECT? -> FILTER* -> SCAN(parquet)` collect leaf and the metadata footer
path, and both RETURN ROWS without ever reaching `materialize_plan`'s
`var opt = prep.take_plan()`. `PROJECT(id) -> FILTER(name > 3 + 0) ->
SCAN(parquet)` is exactly the collect shape, so a gate at `take_plan()` would
miss the reproduction on the route it actually takes. Placing the calls around
the optimizer inside `_prepare_plan` covers both fast answers, both optimizer
doors (FULL and BREAKER) and every route that reaches `_prepare_plan`.

COST: two walks of the plan tree per materialize, each O(references x columns)
on a tree bounded to `PLAN_WIRE_MAX_NODES`: once per materialize, never per row
and never per batch. The same walk the plan decoder already pays per decode.

WHY NOT "MAKE THE REWRITES REFUSE TO PRODUCE SUCH A LITERAL"
-------------------------------------------------------------
That alternative is a check inside each rewrite. This file IS its invariant;
what it rejects is its SITE:

  1. THE SITE IS A LIST OF THE OPTIMIZER'S PASSES (36 distinct passes when this
     was written), and the list was never audited. The door's REWRITE ledger
     names THREE and says that nobody has enumerated the rest. Of the three
     named, two were measured producing silently wrong answers. A per-pass
     check covers the passes someone thought of; this covers all of them and
     the next one.
  2. IT NEEDS THE SAME BUILD EDGE ANYWAY. A rewrite cannot know what "a literal
     the door would have refused" is without consulting the door, so the SDK
     depends on the plan wire package either way, and would pay it once per
     pass instead of once.
  3. IT CANNOT SEE THE COMPOSITION. The constant fold and the aggregate-input
     lift do NOT compose today (`fold_constants_inplace`'s PLAN_AGGREGATE arm
     folds the child plan only). That is a fact about the current pass ORDER,
     not an invariant. A per-pass check grades each pass's output in isolation
     and is blind to a literal that only becomes reachable after a later pass
     moves it. This gate runs after all of them, so composition is not a case
     it has to know about.

Its one genuine advantage is real and is recorded as a follow-up rather than as
a reason: a rewrite that DECLINED instead of raising would keep
`id = 2 OR id = 3.0` ANSWERING [2,3], two comparisons the executor evaluates
correctly, where this gate refuses it. That is a capability question for the
IN-list rewrite, and it does not change what must be refused today.
"""

from komira_plan_ir.logical_plan import LogicalPlan


def plan_values_are_admissible(plan: LogicalPlan) -> Bool:
    """Would the value door admit this plan? Answered, never raised.

    ⚠ THE `except` IS THE PRODUCT HERE, NOT AN ERROR PATH. This is the BEFORE
    half of the difference: a plan that is already refusable is one this gate
    has nothing to say about, and the only way to ask the door a question
    instead of taking its verdict is to catch it."""
    from komira_plan_wire.plan_wire_values import plan_wire_check_values

    try:
        plan_wire_check_values(plan)
        return True
    except:
        return False


def check_values_after_rewrite(plan: LogicalPlan) raises:
    """The AFTER half: refuse a LITERAL the OPTIMIZER made incomparable.

    ⚠ CALL THIS ONLY WHEN `plan_values_are_admissible` SAID TRUE OF THE INPUT.
    The two together are the difference that makes this a statement about the
    optimizer; this half alone is the unconditional form the docstring above
    rejects, with its measured cost.

    ★★ ONLY `PLAN_WIRE_INCOMPARABLE_LITERAL` IS RE-RAISED, AND THAT NARROWING
    IS THE SECOND THING A MEASUREMENT FORCED. The door's refusals fall into
    three classes and only one of them is a statement about a VALUE:

      * INCOMPARABLE_LITERAL — a literal against a column the executor's reader
        cannot compare it with. THE REWRITE CLASS. Re-raised.
      * UNRESOLVED_COLUMN / COLUMN_INDEX_OUT_OF_RANGE / UNSUPPORTED_COL_IDX —
        REFERENCE resolution, and this walk resolves references the way a plan
        AS SENT resolves them. ⛔ THE OPTIMIZER LEGITIMATELY PRODUCES PLANS IT
        IS WRONG ABOUT. MEASURED with a join-side
        scope test: a SEMI join carrying the
        residual `RIGHT.k > 'b'` is admissible as sent, executes CORRECTLY
        (ROWS[3,4]), and `join_predicate_decompose` rewrites the residual to the
        collision-renamed `k_right` — a name that is in NEITHER child schema,
        so this walk calls it unresolvable. Re-raising that would DELETE A
        WORKING QUERY, which is an over-refusal. Teaching the walk about the rename would be a fifth
        mirror, of an optimizer pass, and would drift the day the rename
        changes.
      * INCONSISTENT_COUNT / NEGATIVE_COUNT / EMPTY_SORT_KEYS / OUTPUT_SCHEMA —
        STRUCTURAL invariants of a message. Same argument; not re-raised.

    ⚠ SO THE CLASS THIS CLOSES IS "a rewrite makes a literal incomparable", NOT
    "a rewrite cannot hurt you". A rewrite that produced an out-of-range index
    or an unresolvable name is NOT caught here and would still reach the
    executor. That is the honest scope, and the SEMI/ANTI cell above is the
    reason it is drawn there rather than wider.

    The refusal is the door's own, message unchanged at the FRONT and extended
    at the back.

    ⚠ THE `PLAN_WIRE_*` TOKEN MUST STAY FIRST AND THAT IS NOT COSMETIC.
    `plan_endpoint_code_for_wire_token` dispatches on `msg.startswith(...)`, so
    prefixing this refusal with any prose of our own would cost it its endpoint
    code and a frontend author would be told the ENGINE failed, for a literal
    THEY wrote. The added sentence goes on the end, and it says the one thing
    the door cannot: that the expression named in the message is one the
    OPTIMIZER built, so it may not appear anywhere in the plan that was sent.
    """
    from komira_plan_wire.plan_wire_values import (
        PLAN_WIRE_INCOMPARABLE_LITERAL,
        plan_wire_check_values,
    )

    try:
        plan_wire_check_values(plan)
    except e:
        var msg = String(e)
        if not msg.startswith(PLAN_WIRE_INCOMPARABLE_LITERAL):
            # Not a VALUE refusal — see the class table above. The plan
            # continues to execute exactly as it does at HEAD; this gate simply
            # has no jurisdiction over a reference or a count in a plan the
            # optimizer built.
            return
        raise Error(
            msg
            + " ⚠ THE PLAN YOU SENT PASSED THIS CHECK AND THE OPTIMIZED PLAN"
            " DOES NOT, so the expression named above may not appear in the"
            " plan you sent: a rewrite (constant folding, OR-chain to IN-list,"
            " aggregate-input lift) built it. The literal is still yours — find"
            " the operand it was folded from. This second check exists because"
            " the first one graded the tree the message carried and the"
            " executor evaluated the tree the optimizer produced."
        )
