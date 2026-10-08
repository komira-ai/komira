# =============================================================================
# plan_wire_values.mojo — ★ THE DOOR BOUNDS VALUES, NOT ONLY FRAMING.
# =============================================================================
#
# WHY THIS FILE EXISTS. Bytes that are FOREIGN, STRUCTURALLY PERFECT and
# INSIDE EVERY PUBLISHED BUDGET — the kind protoc produces from hand-edited
# text — can still carry values that contradict the plan's own schema:
#
#   ★ A SIGSEGV AT 261 BYTES.  `col_idx: 999999999` in a filter predicate over a
#     three-column schema. `_expr_from_wire` builds `Expr.col_idx(999999999)`
#     without looking at a schema; `compiler_helpers.resolve_col_index` — which
#     UNLIKE ITS `COL_REF` SIBLING consults no schema — hands the integer
#     straight to `RecordBatch.column_at`, whose body is `self._columns[index]`.
#
#   ★ A SILENT WRONG ANSWER AT 273 BYTES.  A column NAME the schema does not
#     have makes the filter be DROPPED: six rows out of a six-row fixture where
#     four are correct. No error, no warning, wrong data.
#
# ⚠ THE SECOND IS THE WORSE ONE AND IT IS NOT CLOSE. A crash is loud, local,
# and impossible to mistake for an answer. Wrong rows with no error cannot be
# detected by the frontend that asked — it has no oracle; asking was the whole
# reason it called. Every refusal in this file is therefore an `Error` with a
# token, and none of them is a fallback, a clamp, or a best effort.
#
# ======================= WHY THE OTHER PASSES DO NOT COVER IT ===============
#
# `plan_wire_admit.mojo` bounds SIZE, DEPTH, NODE COUNT and VERSION, and the
# per-field ledger in `plan_wire_codec.mojo` refuses unmodelled SHAPES. Both
# are correct. Neither is about values.
#
# ★ THE LEDGER DOES NOT DO THIS JOB, AND NEVER CLAIMED TO. Its refusals are
# about shapes the FORMAT cannot carry — a UDF pointer, an unmodelled tag, a
# schemaless scan. `col_idx: 999999999` is a shape the format carries perfectly;
# it is a `WireColIdx` with an `int64` in it. A mechanism that is true about a
# DIFFERENT PROPERTY does not cover this one, and the gap between the two
# properties is the entire attack surface.
#
# ★ THE SAME RULE HOLDS AT THE OTHER UNTRUSTED-INPUT BOUNDARY.
# `komira_viewport` is FAIL-CLOSED with a six-tag Expr allow-list that
# DELIBERATELY OMITS `EXPR_COL_IDX`, for exactly this reason. The plan wire is
# the broader door, so it checks every value instead.
#
# ========================= WHAT THIS FILE CHECKS ==============================
#
#   INDEX    every positional column reference, against the schema in scope.
#            `0 <= i < num_columns`. No clamp, no modulo, no default.
#   ORDINAL  ★ AND THEN THE REFERENCE ITSELF, IN RANGE OR NOT. `col_idx: 1`
#            against a three-column schema — SEMANTICALLY CORRECT, 257 bytes,
#            inside every budget, past the index check — still ENDS THE
#            PROCESS. The bound is necessary and not sufficient. See
#            `PLAN_WIRE_UNSUPPORTED_COL_IDX`.
#   NAME     every column name — in an expression, in a sort key, in a join
#            key, in a DISTINCT list, in a scan projection, in a window
#            partition/order list — resolved against the schema in scope, or
#            REFUSED BY NAME with the available columns listed.
#   COUNT    a count that disagrees with what it describes (a sort with one key
#            and three `descending` flags; a PartitionTopN with one sort key
#            and none; a join with two left keys and one right key), and a
#            count that is negative (`LIMIT -1`, `TOP -5`, `row_count: -1`,
#            `k: -1`).
#   EMPTY    ★★ AND THE STATE WHERE TWO PARALLEL LISTS AGREE AND ARE BOTH ZERO.
#            It is the one class every rule above passes BY CONSTRUCTION:
#            `_check_parallel` compares 0 with 0 and agrees, `_check_keys`
#            iterates an empty list and resolves nothing. A SORT or a TOP-N
#            with no keys at all would therefore walk the entire gate
#            untouched and END THE PROCESS in the kernel. See
#            `PLAN_WIRE_EMPTY_SORT_KEYS`.
#
# ⚠ ENUMS ARE ALREADY CLOSED AND THIS FILE DOES NOT RE-CHECK THEM.
# `plan_wire_vocabulary.binary_op_from_wire` and its fifteen siblings test
# MEMBERSHIP and raise on an undeclared number — `op: 9999` is refused before
# this file runs. It reaches a caller as `PLAN_ENDPOINT_MALFORMED` rather than
# under its own code, because those messages carry no `PLAN_WIRE_` token; that
# is a naming gap, not a hole, and the `filter_binary_op_undeclared_enum`
# hostile fixture is what keeps it from becoming one.
#
# =================== ⚠ WHAT "THE SCHEMA IN SCOPE" MEANS ======================
#
# A column reference is resolved against the schema of the ROWS IT WILL SEE,
# which is the CHILD's output schema for every unary node — never the node's
# own. Getting that backwards would be a gate that passes a filter referencing
# a column its own projection creates and refuses one referencing a column its
# child provides, i.e. exactly wrong in both directions.
#
#   Filter        predicate            -> child's output schema
#   Project       each expr            -> child's output schema
#   Aggregate     group_by + all FOUR  -> child's output schema
#                 AggExpr arg slots
#   Sort / TopN   keys                 -> child's output schema
#   Distinct      columns              -> child's output schema
#   PartitionBy   partition + order    -> child's output schema
#                 keys + expr columns
#   PartitionTopN partition + sort keys-> child's output schema
#   Join          left_on              -> LEFT child's output schema
#                 right_on             -> RIGHT child's output schema
#                 residual             -> per COL_SIDE; see `_check_expr`
#   AsofJoin      left/right keys+asof -> the corresponding side
#   Scan          projection + filter  -> ★ the SOURCE schema
#                                         (`ScanData.schema`), NOT the node's
#                                         output schema. The output schema is
#                                         post-projection; the pushdown filter
#                                         runs BEFORE the projection prunes, so
#                                         `projection=[b], filter=a > 11` is
#                                         the shape the optimizer wants and the
#                                         one an output-schema scope refuses
#
# The node's own `output_schema` is not taken on trust either: `_plan_from_wire`
# runs `_check_output_schema` on every arm, which compares the wire's stated
# schema against the one the factory DERIVED. So by the time this walk runs,
# every schema it reads has already been reconciled with the plan's structure.
#
# ==================== ⚠ THE FOUR LIMITS, STATED ==============================
#
# Named rather than implied, because a guarantee stated without being held is
# worse than none: `plan_wire_admit.mojo`'s header shows one beaten by a
# single appended byte.
#
#   1. LEAF REFERENCES ARE NOT RESOLVED. `PLAN_VIEW_REF` and `PLAN_CSE_REF` are
#      opaque leaves whose subtree is spliced in later by
#      `view_resolution_pass`, in a process that owns the registry. Their
#      CARRIED output schema is checked against the plan (by
#      `_check_output_schema`) and everything ABOVE them resolves against it —
#      but nothing inside them is checked here, because nothing inside them
#      exists yet.
#
#   2. A CORRELATED SUBQUERY'S **OUTER** REFERENCES ARE NOT RESOLVED. The inner
#      plan IS walked in full — every node, every scan, every index, against its
#      own schemas — which is more than the engine's development-time plan
#      validator does (it declines the whole operand). What is not resolved is
#      `outer_refs` / `in_lhs_col`: those name columns in the ENCLOSING
#      query's scope, which this walk does not carry, and `decorrelate` is the
#      pass that builds that context. ★ REFUSING THE WHOLE EXPRESSION INSTEAD
#      WOULD REJECT A QUERY A USER CAN WRITE — a correlated subquery is an
#      ordinary SQL shape — for a property of this walk rather than of the
#      plan.
#
#   3. A SIDE-QUALIFIED REFERENCE IS RESOLVED ONLY AT A JOIN. `Expr.left("x")`
#      names the LEFT INPUT's `x`, so its scope is a join's two children —
#      which this walk has only at a `PLAN_JOIN`. `Expr` documents such a
#      qualifier outside a join as an ERROR that the optimizer rewrites, but
#      the SQL frontend emits the PRE-rewrite form and this walk runs on a plan
#      at any stage. Resolving one against the enclosing node's schema refuses
#      a real SQL query — for example `SELECT l_orderkey FROM lineitem WHERE
#      l_suppkey IN (SELECT o_custkey FROM orders)` — because the reference
#      is right and the SCOPE is wrong. The name is therefore unchecked
#      outside a join.
#      ★★ SO LIMIT 3 IS LIMIT 2 IN A SECOND SPELLING, AND THAT IS THE REASON
#      THE SKIP IS LOAD-BEARING: `COL_SIDE_LEFT` HAS A SECOND MEANING. The SQL
#      binder uses `Expr.left(...)` to mark a CORRELATED OUTER reference
#      inside a subquery's INNER plan (a correlated scalar subquery, and the
#      IN-subquery membership equi) — a name that by construction is NOT in
#      the scope this walk carries there, and that is never resolved against
#      the inner scan. "Sided ⇒ join" is therefore FALSE, and a walk that
#      resolves sided names wherever there is no join refuses every IN /
#      EXISTS subquery the frontend emits — queries that execute and answer
#      correctly, so the refusal would delete a working query rather than
#      catch a broken one.
#
#   4. TYPES ARE NOT CHECKED. That a join key resolves on both sides does not
#      mean the two columns have compatible types, and this file does not look.
#      A type mismatch is an EXECUTION failure with a name (the engine raises),
#      not a crash and not wrong rows — the two things this file exists to stop
#      — so it is out of scope rather than forgotten. No fixture in the hostile
#      corpus produces either symptom from a type disagreement.
#
# ================= WHY THIS RUNS INSIDE `plan_from_bytes` =====================
#
# Not in the endpoint. `plan_from_bytes` is what turns FOREIGN BYTES into a
# plan, and it is reachable from any caller that does not come through
# `komira_plan_endpoint`. A safety property that depends on which function the
# caller picked is not a safety property — the same argument the plan
# endpoint already makes for running `plan_wire_admit` twice.
#
# ⚠ AND IT DOES NOT MAKE THE ENGINE'S PLAN VALIDATOR REDUNDANT, NOR THE OTHER
# WAY ROUND. That validator is a DEV DIAGNOSTIC over plans built IN THIS
# PROCESS, is OFF by default, and reports "NOT VALIDATED" for five plan tags
# rather than refusing. Forcing it ON for foreign bytes is the wrong fix: it
# would make the door's safety depend on a switch, on a validator that declines
# to check `EXPR_COL_IDX` at all ("positional-index validation belongs on the
# node, not the expr" — and that is correct for its job), and on a module the
# codec cannot depend on without putting the whole engine graph upstream of the
# format. The check the door needs is unconditional, at the boundary, in the
# layer that owns the bytes. That is this file.
#
# Encapsulation: no UnsafePointer anywhere; borrowed `LogicalPlan` / `Schema` /
# `Expr` throughout, no allocation except the error text on the refusal path.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_GE,
    # ★ THE ARITHMETIC RUN IS `BIN_ADD`(0) .. `BIN_MOD`(4), CONTIGUOUS AND
    # LOWEST. `_eval_column_expr`'s scalar fast path fires on exactly those, so
    # `op <= BIN_MOD` is the whole test and the constant is imported rather than
    # spelled 4 — a renumbering of the vocabulary must move this with it.
    BIN_MOD,
    # ★ THE LOGICAL RUN IS `BIN_AND`(20) / `BIN_OR`(21), CONTIGUOUS WITH
    # NEITHER other run — which is why they are NAMED here rather than derived
    # from a range. Their operands go to `_eval_predicate`
    # (`_eval_short_circuit_and` / `_eval_short_circuit_or`), so the
    # context they hand a child is a TRUTH-VALUE one.
    BIN_AND,
    BIN_OR,
    # `UN_NOT`(0) is the ONLY unary operator whose child is a PREDICATE
    # (`compiler_eval_predicate`'s UN_NOT arm); `UN_NEGATE` / `UN_IS_NULL` /
    # `UN_IS_NOT_NULL` all take a value.
    UN_NOT,
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_EXTRACT,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
)
from komira_plan_expr.agg_expr import (
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
    AGG_COUNT_DISTINCT,
    AGG_FIRST,
    AGG_LAST,
    AGG_STDDEV_SAMP,
    AGG_CORR,
    AGG_MEDIAN,
    AGG_LARGEST_K,
    AGG_VAR_SAMP,
    AGG_VAR_POP,
    AGG_STDDEV_POP,
    AGG_SEM,
    AGG_COUNT_IF,
    AGG_BOOL_AND,
    AGG_BOOL_OR,
    AGG_PRODUCT,
    AGG_ANY_VALUE,
    AGG_KAHAN_SUM,
    AGG_KAHAN_AVG,
    AGG_SKEWNESS,
    AGG_KURTOSIS,
    AGG_KURTOSIS_POP,
    agg_is_bivariate,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    agg_func_base_name,
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
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref


# =============================================================================
# THE REFUSAL VOCABULARY
# =============================================================================
#
# ⚠ SEVERAL TOKENS, NOT ONE, AND FOR THE SAME REASON THE ENDPOINT'S CODE SPACE
# IS NUMBERED RATHER THAN "REJECTED". They are different ACTIONS for the
# frontend author who receives them: an out-of-range index means their column
# resolution is off by a schema; an unresolved name means they are querying a
# table they think they have; an inconsistent count means their serializer
# dropped an element; an EMPTY key list means their serializer dropped the whole
# field. The endpoint must be able to name every one of them with its own code.
#
# ⚠ THE COUNT IS DELIBERATELY NOT WRITTEN HERE. A number in a comment is not a
# measurement, and a count of tokens goes stale the first time one is added.

comptime PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE: String = (
    "PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE"
)
"""A positional column reference outside the schema in scope.

★ THE 261-BYTE SIGSEGV. This token turns it into an `Error` a caller can catch
instead of a signal that ends the process while `plan_from_bytes` is inside a
`try`."""

comptime PLAN_WIRE_UNRESOLVED_COLUMN: String = "PLAN_WIRE_UNRESOLVED_COLUMN"
"""A column NAME the schema in scope does not have.

★ THE 273-BYTE SILENT WRONG ANSWER. ⚠ THE ERROR TEXT LISTS THE AVAILABLE
COLUMNS, deliberately and at some cost: the whole class of producer this format
exists for is a frontend in another language whose column list came from
somewhere else, and "not found" without "here is what there is" sends its author
to guess."""

comptime PLAN_WIRE_INCONSISTENT_COUNT: String = "PLAN_WIRE_INCONSISTENT_COUNT"
"""Two repeated fields that must describe each other element-for-element do not.

⚠ ONLY WHERE THE ENGINE ITSELF STATES THE INVARIANT — and the source of truth
for that is the ENGINE, not `plan.proto`'s prose. The comment on
`WirePartitionByNode.descending` calls the lists three facts, but the engine's
plan validator states both pairings:

    PartitionBy     len(order_keys) == len(descending)
    PartitionTopN   len(sort_keys)  == len(descending)

So both are checked here, exactly as a Sort's are. Without the check,
`partition_topn_descending_short` — one sort key and ZERO `descending` flags —
reaches the PartitionTopN kernel, which reads `spec.descending[0]` guarded only
by `len(spec.sort_keys) == 1` and `descending[i]` for
`i in range(len(sort_keys))`: a STACK DUMP and no catchable error.

⚠ A VALIDATOR THAT KNOWS AN INVARIANT WHILE THE UNTRUSTED DOOR DOES NOT is a
class rather than a bug: the validator runs on plans built IN THIS PROCESS,
where the invariant holds by construction, so its check never fires and nobody
notices the door is missing it."""

comptime PLAN_WIRE_NEGATIVE_COUNT: String = "PLAN_WIRE_NEGATIVE_COUNT"
"""A row count, limit, offset or k that is negative.

`LimitData.n` is documented "Always >= 0" — a stated invariant with nothing
enforcing it, on a field an adversary sets directly. That is the shape of every
defect in this file."""

comptime PLAN_WIRE_EMPTY_SORT_KEYS: String = "PLAN_WIRE_EMPTY_SORT_KEYS"
"""★★ A SORT OR A TOP-N THAT CARRIES NO KEYS AT ALL.

⚠ EVERY OTHER CHECK IN THIS FILE PASSES IT BY CONSTRUCTION, WHICH IS THE WHOLE
REASON IT NEEDED A TOKEN OF ITS OWN. `PLAN_WIRE_INCONSISTENT_COUNT` fires when
two parallel lists DISAGREE; here they agree perfectly and are both ZERO.
`_check_parallel` compares 0 with 0; `_check_keys` iterates an empty list and
resolves nothing. So a gate assembled entirely out of "these two must agree" and
"these names must resolve" is GREEN on this input no matter how carefully it is
written — this class cannot be derived from the `partition_topn_descending_short`
check; it has to be named on its own.

★ WITHOUT IT, `sort_zero_keys` (231 B) and `topn_zero_keys` (229 B) through
`execute_plan_bytes` end with

    Assert Error: index 0 is out of bounds, valid range is 0 to -1

— an ABORT, not a raise. A sort kernel that guards its single-key arm with
`if len(sort_keys) > 1:` — a test for MORE than one key standing in for a test
that a key exists at all — lets ZERO fall through to `sort_keys[0]`. The
process ends; `execute_plan_bytes` is `raises` and no `except` sees it; the
test harness report is eaten with it.

⚠ IT COSTS A FOREIGN PRODUCER NOTHING TO SEND, AND NEEDS NO ADVERSARY. proto3
OMITS AN EMPTY REPEATED FIELD ENTIRELY, so a client that merely forgot to
populate `keys` emits exactly these bytes. No Mojo caller builds
`LogicalPlan.sort` with no keys — so the first producer to reach this state is
one that is not this process.

★★ REFUSED RATHER THAN NO-OPPED, AND THE `k <= 0` GUARD ONE FUNCTION OVER IS WHY
THAT NEEDED DECIDING. `_execute_topn_sink` answers `k == 0` with a
schema-preserving EMPTY batch instead of a refusal, which looks like the opposite
policy on a neighbouring field. It is not, and the line between them is:

    A VALUE WITH A DEFINED ANSWER GETS THE ANSWER.
    A VALUE WITH NO DEFINED ANSWER GETS A NAMED REFUSAL.

  * `k == 0` is `LIMIT 0` / `TOP 0` — a query a user can write, that this format
    has exactly ONE spelling for, and whose answer is DEFINED: the empty relation
    with the input's schema. Returning it is THE ANSWER, not a fallback. (A
    NEGATIVE k is not expressible either, and it is already refused at this same
    gate under `PLAN_WIRE_NEGATIVE_COUNT`; it never reaches that kernel line.)
  * A zero KEY LIST has no answer to fall back to, and — decisively — this format
    ALREADY SPELLS BOTH READINGS OF IT UNAMBIGUOUSLY. "No ordering" is the child
    with no `sort` node wrapped round it. "Any N rows" is a `limit` node. So a
    kernel no-op would install a SECOND, ambiguous spelling of something already
    sayable, and would have to pick which of the two the producer meant. Given
    that proto3 omission is the cheapest way in the world to lose this field, the
    likeliest truth is neither reading — it is that the keys were DROPPED. Every
    other refusal in this file exists because guessing a foreign producer's
    intent is the silent-wrong-answer failure this door was built to stop.

The refusal names the node to send instead, because the fix is one edit on the
producer either way."""

comptime PLAN_WIRE_UNSUPPORTED_COL_IDX: String = (
    "PLAN_WIRE_UNSUPPORTED_COL_IDX"
)
"""★★ A POSITIONAL COLUMN REFERENCE THIS ENGINE WILL NOT EXECUTE — AT ANY INDEX.

⚠ THE BOUND IS NECESSARY AND IT IS NOT SUFFICIENT. `PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE`
closes `col_idx: 999999999` at 261 bytes. But `filter_colidx_in_range` — 257
bytes, `col_idx: 1` against a three-column schema `[id, qty, name]`, i.e. a
SEMANTICALLY CORRECT plan meaning exactly `qty > 25` — through
`execute_plan_bytes` without this token is a STACK DUMP and no catchable error.
The format bounds the integer correctly and the engine still cannot run it.

⚠ WHY THIS IS NOT A CORNER CASE. Addressing columns by ORDINAL is what a
GENERATED client does when it has a schema and no name-resolution layer, which
is the normal shape of a TypeScript or a Python frontend. Every Mojo producer
emits `col_ref`, so no Mojo caller reaches it — THE FIRST NON-MOJO PRODUCER
IS EXACTLY WHO DOES. A defect invisible to every test that shares the
producer is the reason this door checks values at all.

★ REFUSED RATHER THAN IMPLEMENTED, because the engine says so in three places:
  * the untyped-expression lowering raises `UnsupportedByLowerUntypedExpr` on
    `EXPR_COL_IDX` in as many words.
  * `compiler_helpers.collect_expr_cols` yields NO name for it (its own comment:
    "EXPR_COL_IDX, EXPR_LITERAL: no column refs to collect"), and the optimizer's
    projection pushdown, late materialization and scan binding are all keyed on
    NAMES. An ordinal's frame of reference is a schema no pass promises to
    preserve.
  * the engine's plan validator declines it outright —
    "positional-index validation belongs on the node, not the expr".
  ⚠ AND THE SAME RULE HOLDS AT THE OTHER UNTRUSTED BOUNDARY:
  `komira_viewport`'s six-tag Expr allow-list DELIBERATELY OMITS `EXPR_COL_IDX`.

★ AND THE FIX IS ONE LINE ON THE PRODUCER, WHICH IS WHY REFUSING IS NOT A TAX.
A message carrying `col_idx: i` has ALREADY serialized the schema it indexes —
`WireSchema.fields[i].name` is in the same bytes. The refusal says so.

⚠ THE ORDER OF THE TWO REFUSALS IS LOAD-BEARING. `_resolve_index` runs FIRST, so
an out-of-range ordinal keeps `PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE` and its own
endpoint code. The two are different FIXES for the frontend author — "your
column resolution is off by a schema" versus "this engine does not execute
ordinals; send the name" — which is the entire reason this door numbers its
refusals instead of only describing them.

⚠ THE FORMAT STILL CARRIES THE TAG. `WireColIdx` keeps its message and its
field number, `_expr_to_wire` / `_expr_from_wire` keep their arms, and the
vocabulary still publishes `EXPR_COL_IDX` — so bytes written by any producer
remain readable and a future engine that grows positional execution needs no
format change. This is a statement about what THIS BUILD will run, which is why
it lives in the value gate and not in the codec's shape ledger."""

comptime PLAN_WIRE_UNCHECKED_VALUE_SITE: String = (
    "PLAN_WIRE_UNCHECKED_VALUE_SITE"
)
"""★ THE FAIL-CLOSED ARM. This walk reached a site it cannot resolve, and
REFUSED rather than passing it.

⚠ THIS IS THE DIFFERENCE BETWEEN THIS FILE AND THE DEV VALIDATOR, AND IT IS THE
WHOLE DESIGN. The engine's plan validator records a NOT-VALIDATED note and
returns — correct for a diagnostic a developer opted into, because a gate that
cries wolf gets turned off. At an untrusted boundary the same behaviour is a
hole: "I did not check this" and "this is fine" become the same outcome for the
caller, which is precisely how a crash and a wrong answer get through.

⚠ NO HOSTILE FIXTURE EXERCISES THIS TOKEN, and that is stated rather than left
to be discovered. Every state that reaches it is one the CODEC ITSELF already
refuses on the way in — a fourth `COL_SIDE` value, an `Expr` tag with no decode
arm — so it cannot be reached from bytes at all. It exists for the case where
the codec grows an arm and this walk does not follow, which is a future edit,
not an input. A token with no fixture is a refusal nothing holds; this one is
held by the terminal `else` being the only alternative to a silent pass.

Two situations produce it, and the message says which:
  * `EXPR_CORRELATED_SUBQUERY`, whose outer references need a correlation
    context that does not exist at decode time (see limit 2 in the header).
  * an `Expr` tag with no arm in `_check_expr`. That means the codec grew a
    decode arm and this walk did not follow — a bug in this package, reported
    to the caller as one. EVERY tag in `[0, EXPR_TAG_COUNT)` is named
    below, so this cannot happen without an edit that ignores this comment.
    ⚠ NO COUNT IS WRITTEN HERE ON PURPOSE: a written count of the tag space
    goes stale at the next tag-add."""

comptime PLAN_WIRE_AGG_ARG_DROPPED: String = "PLAN_WIRE_AGG_ARG_DROPPED"
"""★★ AN AGGREGATE ARGUMENT SLOT THIS BUILD'S AGGREGATE DOES NOT READ — the
argument is DISCARDED and the query answered is a DIFFERENT one.

`sum(id)` with `WireAggExpr.child1` set to a BOOL literal, and the same with a
STRING literal, would EXECUTE and return the answer to `sum(id)`. `sum` is
unary; slot 1 is read by nothing, so the second argument is not evaluated, not
refused and not reported. A frontend cannot detect that.

⚠ IT IS NOT `PLAN_WIRE_INCOMPARABLE_LITERAL`. That token is about a literal
whose VALUE a reader destroys; here the whole EXPRESSION is dropped before any
reader sees it, and the slot is dropped just as silently when it holds a
COLUMN REFERENCE — `sum(id)` with `child1 = col('name')` is the same wrong
answer with no literal in it at all, so a rule keyed on the literal would close
half the class. It is the class `PLAN_WIRE_UNRESOLVED_COLUMN` names one node
over: a DROPPED expression returns wrong rows with no error — the failure mode
a frontend cannot detect, which is why it gets its own code.

★ THE ARITY IS THE PRODUCER'S OWN RULE, MIRRORED — NOT A NEW POLICY. The Python
producer's aggregate-arity table enforces it in BOTH directions ("a `corr` with
one input and a `sum` with two are equally unrepresentable"), so that producer
cannot emit this shape and a stranger's bytes can. That is the "a validator
knows an invariant the untrusted door does not" split again.

⚠ WHAT IT DOES NOT CHECK: TOO FEW. `sum()` with no argument at all is a
different defect and is left to whatever stops it at execution; this rule
refuses only a POPULATED slot BEYOND the function's arity."""

comptime PLAN_WIRE_INCOMPARABLE_LITERAL: String = (
    "PLAN_WIRE_INCOMPARABLE_LITERAL"
)
"""★★ A LITERAL COMPARED AGAINST A COLUMN WHOSE TYPE HAS NO ARM FOR IT — the
silent wrong answer.

★ THE MECHANISM, WHICH IS A UNION AND NOT A CAST. `ScalarValue` is a tagged
union with one field per storage class (`int_val`, `float_val`, `string_val`,
`bool_val`, …), and `compiler_eval_predicate` dispatches on the COLUMN'S Arrow
type ALONE. The INT64 arm reads `lit_val.int_val`; the STRING arm reads
`lit_val.string_val`. A literal that carries its value in a DIFFERENT field
leaves the one being read at its ZERO — so `id > TRUE` would execute as
`id > 0` and `name > TRUE` as `name > ""`. Nothing raises, the output schema
is right, and the rows are wrong. Over a six-row fixture (ids 1..6) that means:

    id   >  True              -> [1,2,3,4,5,6]      (`id > 0`)
    id   >  False             -> [1,2,3,4,5,6]      IDENTICAL to `> True`
    id   == True              -> []                 (`id == 0`)
    name >  True              -> [1,2,3,4,5,6]      (`name > ""`)
    id   >  Decimal("30.75")  -> [1,..,6]           (`id > 0`)
    d    >  3                 -> [1,2,3,4,5,6]      (a DATE against a day count)

⚠ IT IS A CLASS OF PAIRS, NOT ONE CELL. The same read-the-wrong-union-member
mechanism covers STRING/INT, STRING/FLOAT, STRING/DECIMAL, INT64/STRING,
INT64/DECIMAL, INT64/DATE and DATE32/INT as well as the BOOL literal. So the
refusal is written against the MECHANISM (does the executor have an arm for
this pair?) rather than against any one cell.

★ REFUSED, NOT IMPLEMENTED, AND THE ALTERNATIVE IS REAL. DuckDB DEFINES
`1 > true` (implicit BOOL->INT32: `1 > true` = false, `1 = true` = true,
`1 > false` = true), and pandas would define it the same way through numpy.
PostgreSQL does not — `operator does not exist: integer > boolean`. Two things
decide it for this engine:
  1. THERE IS NO CAST LAYER TO COERCE INTO. The executor's only implicit
     promotions are numeric (INT<->FLOAT, and INT/FLOAT->DECIMAL through the
     decimal helper) and temporal-to-temporal. Everything else reads a union
     member nobody wrote.
  2. THE ONE SHAPE WHERE A BOOL LITERAL IS MEANINGFUL IS ALREADY REFUSED.
     `flag = TRUE` over a genuine BOOL column raises `PipelineCompiler:
     unsupported column type for predicate: bool` — so implementing the
     coercion would mean inventing a semantics ahead of the engine's own
     ability to evaluate it.
⇒ the rule applies unchanged: a value with a defined answer gets the answer; a
value with no defined answer gets a NAMED REFUSAL. When a CAST layer lands,
this is the site that relaxes.

⛔ `EXPR_CAST` IS NOT THE ESCAPE HATCH IT LOOKS LIKE, and that is stated because
it is the plausible reading. A producer that sends `id > CAST(TRUE AS INT64)`
does NOT get `id > 1` wherever the cast is applied AFTER
`compiler_helpers.broadcast_scalar` has turned the literal into an INT64 zero:
the format carries the NODE; the engine has no execution of it for those
literals. So the refusal message does not recommend it, and that spelling is
refused in its own right — see `_literal_is_materializable`. Where
`broadcast_scalar` HAS an arm for the literal (BOOL, DATE32, TIMESTAMP), the
cast spelling is refused one layer down instead, by `compiler_eval_column`'s
EXPR_CAST ladder, which has no BOOL source arm and no DATE32 -> INT64 arm (its
DATE32 arm targets INT32 — a pure relabel — so `CAST(<date> AS BIGINT)` falls
off the end of that ladder and raises). Still fail-closed, still not `id > 1`,
but by a different guard. The DECIMAL / TIME / DURATION / INTERVAL / BINARY
spellings of the same shape are refused here.

⚠ WHAT THIS TOKEN DOES NOT COVER, stated so a green is not over-read:
  * `EXPR_IN_LIST` values. `col IN (TRUE, 'x')` goes through
    `compiler_eval_in_list`, which is the same union-read shape and is NOT
    checked here. It is UNMEASURED rather than known good.
  * a DICTIONARY column. Its VALUE type is not visible from `Field.arrow_type`
    (the executor discriminates at run time with `is_numeric_dict()`), so the
    pair cannot be judged here and is passed. Refusing on the encoded type
    would reject the working string-dict filter path.
  * column-vs-column comparisons, which promote through
    `_eval_col_vs_col_promoted` and are a different mechanism.
  * ⛔ THE ROOT OF THE MATERIALIZING HALF — `compiler_helpers.broadcast_scalar`
    ITSELF, which this token guards at the plan-wire boundary and NOWHERE
    ELSE. Its `else: # Default: create a zero int64 column` tail is reachable
    by the SQL route (no door in front of it), by a literal PROJECTION, and by
    a CASE arm. Fixing it there is a change to the core packages, not to this
    package.
  * BINARY / LARGE_BINARY columns and binary literals, deliberately passed:
    the executor's own binary-vs-string behaviour is a separate question, and
    a refusal written on a guess would be the over-broad kind.
  * ⛔ THE OTHER UNTRUSTED BOUNDARY — `komira_viewport`. This token guards
    the PLAN wire and nothing else. A `GridTicket` carries its own `Expr`
    filter, and the ticket validator checks ticket SIZE, tree DEPTH, total
    node COUNT and blank names and NEVER the (column, literal) pair, before
    the filter reaches the same `compiler_eval_predicate`. The viewport scalar
    codec carries BOOL / INT32 / INT64 / FLOAT32 / FLOAT64 / STRING and its
    Expr allow-list includes `EXPR_ALIAS`, so every pair enumerated above is
    spellable in a ticket. ⚠ THE FIX IS NOT A COPY-PASTE: the ticket
    validator runs before the source is opened, so it has no schema to judge
    against — the check belongs after the plan is built, where
    `plan_wire_check_values` is already callable on a `LogicalPlan` for
    exactly this reason."""


def _schema_columns(schema: Schema) raises -> String:
    var out = String("[")
    for i in range(schema.num_columns()):
        if i > 0:
            out += ", "
        out += schema.field_name(i)
    out += "]"
    return out^


def _resolve_name(name: String, schema: Schema, where: String) raises:
    """THE ONE PLACE A COLUMN NAME IS RESOLVED. Every site funnels here so the
    refusal text is identical wherever it comes from — the same discipline the
    engine's plan validator follows, with a token in front so the endpoint can
    give it a code."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return
    raise Error(
        PLAN_WIRE_UNRESOLVED_COLUMN
        + ": "
        + where
        + " names column '"
        + name
        + "', which the schema in scope does not have. Available: "
        + _schema_columns(schema)
        + ". ⚠ Refused rather than dropped — an unresolved reference that is"
        " silently discarded returns WRONG ROWS with no error, which the"
        " caller has no way to detect."
    )


def _resolve_index(index: Int, schema: Schema, where: String) raises:
    """THE ONE PLACE A POSITIONAL COLUMN REFERENCE IS BOUNDED.

    ⚠ BOTH ENDS. A negative index is not a smaller problem than a large one:
    `RecordBatch.column_at` is `self._columns[index]` either way, and a negative
    subscript reads BEFORE the allocation, which is the harder crash to
    diagnose and the easier one to turn into a read of unrelated memory."""
    if index < 0 or index >= schema.num_columns():
        raise Error(
            PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE
            + ": "
            + where
            + " refers to column index "
            + String(index)
            + ", and the schema in scope has "
            + String(schema.num_columns())
            + " columns "
            + _schema_columns(schema)
            + ". ⚠ Refused rather than executed — this index reaches"
            " `RecordBatch.column_at`, whose body is an unchecked"
            " `self._columns[index]`, so executing it is a SIGSEGV and not a"
            " catchable error."
        )


def _refuse_unchecked(where: String, why: String) -> Error:
    return Error(
        PLAN_WIRE_UNCHECKED_VALUE_SITE
        + ": "
        + where
        + " could not be checked — "
        + why
        + ". ⚠ REFUSED RATHER THAN ADMITTED. At this boundary 'I did not check'"
        " and 'this is fine' must not be the same answer; see"
        " plan_wire_values.mojo."
    )


# =============================================================================
# COMPARISON OPERAND TYPES — see `PLAN_WIRE_INCOMPARABLE_LITERAL`
# =============================================================================
#
# ⚠ THESE TWO FUNCTIONS ARE A MIRROR OF `compiler_eval_predicate`'s ARM SET, and
# the mirror is stated here rather than left implicit because a drift makes this
# gate WRONG IN ONE OF TWO DIRECTIONS: too narrow and it admits the silent wrong
# answer back; too wide and it refuses a shape that works today. Both directions
# can only be held by an EXECUTING instrument: a sweep of column types x
# literal types x operators through the real engine that asserts ROWS on every
# pair this table calls evaluable and the NAMED CODE on every pair it does not.
# Too narrow and the row assertions go red; too wide and the "REFUSED a valid
# pair" arm does. ⚠ A second, non-executing copy of this table in a unit test
# would prove nothing: a mirror of a mirror agrees with a drift.
#
# The domains are named for what the EXECUTOR does, not for Arrow's taxonomy:
#   number   INT8..UINT64 / FLOAT16..FLOAT64 — the arms that read `int_val` or
#            `float_val`, plus the INT<->FLOAT promotion between them.
#   decimal  DECIMAL128 / DECIMAL256 — `_eval_decimal_col_vs_literal`, which
#            scale-aligns an INT or FLOAT literal as well as a DECIMAL one. So
#            a decimal COLUMN accepts a number and a number COLUMN does NOT
#            accept a decimal: the asymmetry is the executor's
#            (`amt > 3` is right; `id > Decimal("30.75")` would be `id > 0`).
#   text     STRING / LARGE_STRING — the arms that read `string_val`.
#   temporal DATE32/DATE64/TIMESTAMP*/TIME*/DURATION* — routed to
#            `_eval_temporal_col_vs_literal` BEFORE the numeric arms.
#            ⚠⚠ AND IT ALSO TAKES AN INTEGER LITERAL, WHICH THE DOMAINS BELOW
#            CANNOT SAY. That arm is selected by the COLUMN ALONE and its
#            threshold read has an explicit `lit.is_int()` branch, because a
#            DATE32 column IS int32 days-since-epoch. The pair is carried by
#            `_temporal_column_reads_int_literal`, consulted with the LITERAL in
#            hand — a domain that lumps INT and FLOAT together cannot express
#            it, and the two are not the same here: the INT is answered and the
#            FLOAT raises.
#   bool     BOOL. Admitted with a bool literal so that the engine's own
#            "unsupported column type for predicate: bool" stays the refusal a
#            caller sees — that is an ENVELOPE limit, not a type error, and
#            replacing it here would mislabel it.
#   ""       everything else: unknown to this check, and PASSED. An empty
#            domain on either side means "this walk cannot judge the pair", and
#            it must not become "this pair is bad".


comptime _CMP_UNKNOWN: String = ""


def _write_comparison_domain_of_column[W: Writer](mut writer: W, t: ArrowType):
    """WRITE what `_comparison_domain_of_column` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library
    that binds such a pair CROSSED reads the wrong bytes and can crash
    the host process that loaded it."""
    if t == ArrowType.BOOL:
        writer.write(String("bool"))
        return
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        writer.write(String("decimal"))
        return
    if t.is_numeric():
        writer.write(String("number"))
        return
    if t == ArrowType.STRING or t == ArrowType.LARGE_STRING:
        writer.write(String("text"))
        return
    if t.is_temporal():
        writer.write(String("temporal"))
        return
    writer.write(String(_CMP_UNKNOWN))
    return


def _comparison_domain_of_column(t: ArrowType) -> String:
    """The executor's comparison domain for a column type, or `""`."""
    var out = String()
    _write_comparison_domain_of_column(out, t)
    return out^


def _write_comparison_domain_of_literal[W: Writer](mut writer: W, v: ScalarValue):
    """WRITE what `_comparison_domain_of_literal` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library
    that binds such a pair CROSSED reads the wrong bytes and can crash
    the host process that loaded it."""
    if v.is_null():
        writer.write(String(_CMP_UNKNOWN))
        return
    if v.is_bool():
        writer.write(String("bool"))
        return
    if v.is_decimal128() or v.is_decimal256():
        writer.write(String("decimal"))
        return
    if v.is_any_integer() or v.is_float():
        writer.write(String("number"))
        return
    if v.is_string():
        writer.write(String("text"))
        return
    if (
        v.is_date32()
        or v.is_timestamp()
        or v.is_time()
        or v.is_duration()
        or v.is_interval()
    ):
        writer.write(String("temporal"))
        return
    writer.write(String(_CMP_UNKNOWN))
    return


def _comparison_domain_of_literal(v: ScalarValue) -> String:
    """The executor's comparison domain for a literal, or `""`.

    ⚠ A NULL LITERAL IS `""` ON PURPOSE. `col OP NULL` is NULL for every row
    under 3VL and the executor has an explicit arm that drops all rows (a
    NULL literal may still carry a dtype). Judging it by type would refuse a
    shape that is both expressible and correct."""
    var out = String()
    _write_comparison_domain_of_literal(out, v)
    return out^


def _comparison_pair_is_evaluable(col_domain: String, lit_domain: String) -> Bool:
    """Does `compiler_eval_predicate` have an arm for this pair?

    ⚠ ONE ADMITTED PAIR IS NOT EXPRESSIBLE HERE — a TEMPORAL column against an
    INTEGER literal. See `_temporal_column_reads_int_literal`, which
    `_refuse_if_incomparable` consults with the literal in hand, because the
    domains cannot tell an INT from a FLOAT and the executor's temporal arm
    treats them differently."""
    if col_domain == _CMP_UNKNOWN or lit_domain == _CMP_UNKNOWN:
        return True  # not judged here; see the domain table above
    if col_domain == "decimal":
        # The decimal helper promotes an INT or FLOAT literal too.
        return lit_domain == "decimal" or lit_domain == "number"
    return col_domain == lit_domain


def _temporal_column_reads_int_literal(col_t: ArrowType, lit: ScalarValue) -> Bool:
    """MIRROR of the TEMPORAL arm's SELECTOR and of its THRESHOLD READ.

    ⛔ THE PAIR THIS EXISTS FOR IS ONE THE ENGINE ANSWERS, SO THE DOOR MUST NOT
    REFUSE IT. Over a DATE32 column `d` holding six consecutive days,
    `d IN (20456, 20458)` — the day counts of the third and fifth of them —
    returns `[3, 5]`. A door that judged by domain alone would refuse it with
    `PLAN_ENDPOINT_INCOMPARABLE_LITERAL(37)`, a refusal of a shape that is right.

    ★ TWO HALVES, BOTH FROM THE EXECUTOR, AND BOTH LINE-FOR-LINE:

      the SELECTOR   `compiler_eval_predicate`'s `col_is_temporal_intlike` —
                     DATE32 / DATE64 / TIMESTAMP* / TIME* / DURATION*. It fires
                     on the COLUMN ALONE, i.e. a temporal column routes to
                     `_eval_temporal_col_vs_literal` no matter what the literal
                     is. ⚠ NOT `ArrowType.is_temporal()`, which also answers
                     True for INTERVAL — an interval column is NOT in the
                     executor's selector and falls through to the numeric arms,
                     so mirroring the wider predicate would admit a pair the
                     executor does not have.
      the THRESHOLD  `temporal_literal_value._temporal_literal_i64`, whose
                     ladder is date32 -> `date32_val`, timestamp -> `ts_micros`,
                     and `lit.is_int() or lit.is_time() or lit.is_duration()`
                     -> `int_val`. A DATE32 column is physically int32
                     DAYS-SINCE-EPOCH, so an INT64/INT32 literal IS a
                     well-formed threshold and its value is in the field the
                     arm reads.

    ⚠ `is_int()` AND NOT `is_any_integer()`, DELIBERATELY. `is_int()` is
    int64/int32 only; an int8/int16/uint literal reaches
    `_temporal_literal_i64`'s `else` and RAISES BY NAME. That is loud, so it is
    the ENGINE's refusal to give — but this door must not CLAIM the pair is
    evaluable when the arm raises, or the next reader will mirror the claim
    instead of the code.

    ⚠ AND THIS IS WHY A FLOAT IS STILL REFUSED HERE. `d > 3.5` enters the same
    arm and raises `temporal literal: unsupported literal type` — a message
    about a helper the plan's author never named. The door's own refusal says
    which literal, in which position, and what to send instead, so admitting the
    whole `number` domain (the one-line version of this rule) would trade a
    correct refusal for a worse-worded one."""
    var col_is_temporal_intlike = (
        col_t == ArrowType.DATE32
        or col_t == ArrowType.DATE64
        or col_t.is_timestamp()
        or col_t.is_time()
        or col_t.is_duration()
    )
    return col_is_temporal_intlike and lit.is_int()


# =============================================================================
# ★★ WHAT COUNTS AS "A COLUMN REFERENCE" — AND IT IS THE EXECUTOR'S ANSWER
# =============================================================================
#
# ⛔ THE HAZARD THIS SECTION EXISTS FOR IS NOT THE ALIAS. It is that an
# ADMISSION CHECK and the CODE IT ADMITS FOR can hold two different opinions of
# the same predicate. A check that asked `tag == EXPR_COL_REF` would disagree
# with the executor, which asks `compiler_helpers.expr_resolves_to_column` and
# also says yes to `EXPR_COL_IDX` and to an `EXPR_ALIAS` (transitively)
# wrapping either. One `WireAlias` node — a rename that changes no value, not
# even a name if you leave it empty — would put the ENTIRE refused class back
# on the table: `ALIAS(id) > True -> [1,2,3,4,5,6]`, `ALIAS(id) = True -> []`,
# `ALIAS(name) > 3 -> [1,2,3,4,5,6]`, and wrapping TWICE the same.
#
# ⇒ THE RULE IS NOT "ALSO UNWRAP ALIASES". It is that this file must ask the
# EXECUTOR'S question, so the two cannot drift apart on some third spelling
# nobody has thought of. `_resolves_to_column` below is a line-for-line mirror
# of `expr_resolves_to_column`, and `_column_arrow_type` mirrors
# `resolve_col_index`'s three arms.
#
# ⚠ WHY THIS FILE DOES NOT IMPORT THE EXECUTOR'S FUNCTION INSTEAD, which is the
# obvious way to make a divergence impossible. `expr_resolves_to_column` answers
# "does this resolve to a column"; this walk needs "and to a column of WHICH
# ARROW TYPE, in WHICH of three schemas, honouring COL_SIDE" — which the
# executor's version cannot answer because it has no schema and no sides. So the
# structural recursion is duplicated and the duplication is NAMED, here, with
# the source it mirrors. If `compiler_helpers` grows a fourth arm, this comment
# is what says the second copy exists.
#
# ⚠ WIDTH IS NOT THE SEVERITY AXIS — THE NO-MATCH BRANCH IS. The engine holds
# several opinions of "does this expression resolve to a column", of different
# widths. A copy whose no-match branch DECLINES to a general path is SAFE when
# it is too narrow: it merely stops optimizing. A copy whose no-match branch
# ADMITS is UNSAFE when it is too narrow, because "I did not recognise this"
# becomes "this is fine" — and this file's is ADMIT-shaped. That is why the
# same narrowness that costs an optimizer a skipped stride would cost this door
# wrong row sets. And the inverse holds too: a copy that is too WIDE and then
# calls the resolver turns a decline into a RAISE.
#
# ⚠ THE `EXPR_COL_IDX` ARMS BELOW ARE SHADOWED AND ARE STILL WRITTEN.
# `_check_expr` refuses EVERY ordinal reference (`PLAN_WIRE_UNSUPPORTED_COL_IDX`)
# on the way down, and it runs BEFORE `_check_comparison_operands`, so no plan
# reaches these arms through this walk — every `col_idx` / `alias(col_idx)`
# comparison is refused under that other token. They are here because they are
# half of what `resolve_col_index` accepts, the ordinal refusal is explicitly
# about "what THIS build will run" rather than about the format, and the day it
# is lifted this check must ALREADY be right — rebuilding the narrower opinion
# is the defect, not a spelling of it. ⚠ AND THEREFORE THEY ARE NOT COVERED BY A
# TEST THAT CAN GO RED. That is stated, not hidden: nothing can currently
# distinguish these arms from `return ArrowType.NULL`.


def _resolves_to_column(e: Expr) -> Bool:
    """MIRROR of `compiler_helpers.expr_resolves_to_column`. Keep them equal.

    True iff `resolve_col_index` would resolve `e` to a single column index
    without raising: a bare ColRef / ColIdx, or an Alias that transitively wraps
    one. A CAST, a UnaryOp or any arithmetic does NOT resolve to a column — the
    executor materializes those and compares by promotion instead, which is a
    different mechanism the domain table does not describe.

    ⚠ `EXPR_CAST` IS NOT a remedy the refusal message recommends — see
    `_literal_is_materializable` below and the message's own text for why."""
    if e.tag == EXPR_COL_REF or e.tag == EXPR_COL_IDX:
        return True
    elif e.tag == EXPR_ALIAS:
        return _resolves_to_column(e.alias_child_ref())
    return False


def _is_literal_under_aliases(e: Expr) -> Bool:
    """True iff `e` is a literal, possibly under `EXPR_ALIAS` wrappers.

    ⚠ THE ALIAS IS UNWRAPPED ON THIS SIDE TOO, and the reason is not symmetry:
    without it `A(True) > id` and `True > A(id)` both return `[]` with NO
    ERROR, where the bare `True > id` is refused by name. An alias over a literal renames a constant;
    it changes neither the value nor its type, so it cannot change the pair's
    domains, and a check that let it change the VERDICT was judging the
    spelling instead of the pair."""
    if e.is_literal():
        return True
    elif e.tag == EXPR_ALIAS:
        return _is_literal_under_aliases(e.alias_child_ref())
    return False


def _literal_under_aliases(e: Expr) -> ScalarValue:
    """The literal `_is_literal_under_aliases` found. Call only after it."""
    if e.tag == EXPR_ALIAS:
        return _literal_under_aliases(e.alias_child_ref())
    return e.literal_value()


# =============================================================================
# ★★ THE SECOND EVALUATOR — AND THE SECOND PLACE A LITERAL BECOMES A ZERO
# =============================================================================
#
# ⛔ THE HAZARD THIS SECTION EXISTS FOR: THE OBVIOUS REMEDY FOR THE REFUSAL
# ABOVE MANUFACTURES THE EXACT WRONG ANSWER THE REFUSAL STOPS. "State the
# conversion you mean with an `EXPR_CAST` node" sounds right, and over a six-row
# fixture it produces:
#
#   id > CAST(30.75 AS INT64)  -> [1,2,3,4,5,6]   (`id > 0`)   the bare
#                                                              spelling is
#                                                              REFUSED
#
# and the same for every literal `broadcast_scalar` has no arm for, in EVERY
# spelling that puts a cast anywhere: over the literal, over the COLUMN with a
# bare literal opposite it, over both, and under or over an `EXPR_ALIAS`. Where
# the literal IS materializable, the cast is right — `id > CAST(3 AS INT64)`
# really is `id > 3` — which is why the rule below is not "refuse casts".
#
# ★★ THE MECHANISM IS NOT THE CAST. `compiler_eval_predicate` has TWO ways to
# read a literal, and a door that mirrors only one is bypassed by the other:
#
#   THE UNION-MEMBER PATH — `<expr that resolves to a column> OP <bare
#   literal>`. Dispatches on the COLUMN's Arrow type and reads the
#   `ScalarValue` member that type stores its values in. Its arm set is
#   mirrored above by `_comparison_domain_of_*`.
#
#   THE MATERIALIZING PATH — EVERY other spelling. Both operands are turned
#   into Columns and compared by `_eval_col_vs_col_promoted`, and a literal
#   becomes a Column through `compiler_helpers.broadcast_scalar`, whose tail is
#
#       else:
#           # Default: create a zero int64 column
#
# ⇒ every literal `broadcast_scalar` has no arm for becomes SIX INT64 ZEROS,
# and the cast is then applied to a zero. ⛔ DO NOT QUOTE AN ARM LIST FROM A
# COMMENT: read the ladder (and `_literal_is_materializable`, which copies it).
# It is the SAME defect as the one the domain table already closes, on the
# other evaluator: both turn "I have no arm for this member" into "0".
#
# ⇒ THE RULE IS A THIRD MIRROR, NOT A RULE ABOUT CASTS. `_literal_is_materializable`
# is a line-for-line mirror of `broadcast_scalar`'s ladder, and
# `_check_comparison_operands` refuses a comparison whose literal operand will
# go down the materializing path and be destroyed there. A rule that said
# "casts are special" would be an OPINION of this file's, and an opinion is
# exactly what a bypass is made of.
#
# ⚠ WHAT THIS REFUSES COSTS NOTHING: every one of those spellings zeroes the
# literal, so there is no correct answer among them to lose. Every spelling
# that answers correctly carries a literal `broadcast_scalar` CAN materialize,
# and this check passes it untouched — that is the load-bearing control.
#
# ⚠ AND IT IS NARROWER THAN THE MECHANISM, STATED RATHER THAN HIDDEN. The root
# is `broadcast_scalar` itself, which is reached by the SQL route and by literal
# PROJECTIONS with no door in front of them at all. This check governs the
# PLAN-WIRE route only. Fixing the root is a change to the core packages, not to
# this package.


def _literal_is_materializable(v: ScalarValue) -> Bool:
    """MIRROR of `compiler_helpers.broadcast_scalar`'s arm ladder. Keep equal.

    True iff `broadcast_scalar` has an arm that carries `v`'s VALUE into the
    Column it builds. False means the tail arm fires and the value becomes an
    INT64 zero — so any comparison against it is a comparison against 0.

    ⚠ THE LADDER IS COPIED IN ORDER AND ON PURPOSE, ARM FOR ARM — INCLUDING
    WHICH ARMS TEST `dtype` AND WHICH TEST `_kind`. `broadcast_scalar`'s
    numeric/bool arms branch on `sv.dtype` alone, and `ScalarValue`'s DECIMAL /
    TIME / DURATION / INTERVAL / BINARY values are `_kind`-tagged with `dtype`
    left at its default — which is exactly why they reach the tail unless the
    ladder has a `_kind` arm for them. DATE32, TIMESTAMP and DECIMAL128 have
    `_kind` arms over there, so they have `_kind` arms here, in the same
    position. A mirror written from the `is_*` predicates wholesale would be a
    paraphrase, and a paraphrase is how a checker and an executor come apart."""
    if v.is_null():
        return True
    if v.is_date32():
        # ★ THE MIRROR DOING ITS JOB. `broadcast_scalar` has its
        # `is_date32()` / `is_timestamp()` arms in THIS position (immediately
        # after the null arm and ahead of every `dtype` test), so these two
        # lines copy the ladder rather than paraphrase it. They are NOT an
        # opinion about dates.
        return True
    if v.is_timestamp():
        return True
    if v.is_decimal128():
        # `broadcast_scalar` has a DECIMAL128 arm in this position, so a
        # decimal literal carries its value.
        return True
    if v.dtype == DType.int64:
        return True
    elif v.dtype == DType.float64:
        return True
    elif v.dtype == DType.int32:
        return True
    elif v.dtype == DType.float32:
        return True
    elif v.dtype == DType.bool:
        # `broadcast_scalar` has a bit-packed `BooleanArray` arm, so a bool
        # literal carries its VALUE into the Column instead of becoming an
        # INT64 zero. This line is not an opinion about bools — it is the
        # ladder being copied, which is the only rule this predicate has.
        return True
    elif v.is_string():
        return True
    return False


def _literal_survives_scalar_arith(v: ScalarValue) -> Bool:
    """MIRROR of `compiler_eval_column._eval_binary_col_scalar`'s scalar read.

    ★★ THE SECOND LADDER, AND IT IS NARROWER THAN `broadcast_scalar`'S.
    `_eval_column_expr`'s `EXPR_BINARY_OP` arm has a SCALAR FAST PATH: when one
    operand is a bare `EXPR_LITERAL` it does NOT broadcast it into a Column at
    all — it hands the `ScalarValue` to `_eval_binary_col_scalar`, which reads
    ONE union member chosen by the COLUMN's Arrow type:

        FLOAT64 col:  `sv.is_int()` -> `int_val`, else `float_val`
        INT64/32 col: `sv.is_float()` -> `float_val`, else `int_val`
        anything else: raises

    So it carries a value iff the literal is an INT or a FLOAT. Everything else
    — BOOL, DECIMAL, the temporal family, a STRING, and a NULL — leaves the
    member it reads at that member's ZERO. It is the SAME defect as the two
    ladders already mirrored in this file, in a THIRD reader.

    ⚠ THE STRING IS THE ONE THAT MATTERS, BECAUSE `broadcast_scalar` CARRIES IT
    AND THIS DOES NOT. `id > (0 + 'c')` over a six-row fixture returns
    [1,2,3,4,5,6] — the whole fixture, i.e. `id > 0` — because the string's
    `int_val` is 0. The materializer mirror alone admits that cell, which is
    why this second predicate exists rather than a widening of the first.

    ⚠ AND `NULL` IS REFUSED HERE THOUGH `broadcast_scalar` CARRIES IT. This
    reader has no null path at all, so `col + NULL` is `col + 0` where SQL 3VL
    says the whole predicate is NULL and no row qualifies. Read from the arm
    list rather than executed — a producer that refuses a `None` literal
    outright never reaches it; a stranger's bytes can."""
    return v.is_int() or v.is_float()


def _literal_is_a_predicate(v: ScalarValue) -> Bool:
    """MIRROR of `compiler_eval_predicate`'s `EXPR_LITERAL` arm.

    ★★★ THE THIRD READER, AND IT IS THE PUREST INSTANCE OF THE CLASS. The arm is

        var lit_val = expr.literal_value()
        ...
        if lit_val.bool_val:            # else: all bits already clear (False)

    — ONE `ScalarValue` member, chosen by NOTHING AT ALL. Not by the literal's
    own kind (as a sane reader would) and not even by a column's Arrow type (as
    the comparison dispatch at least does). So a BOOL is the only literal that
    carries a value into a predicate slot; an INT, a FLOAT, a STRING, a DECIMAL,
    the whole temporal family and a NULL all read `bool_val` at its ZERO, and the
    predicate EXECUTED is `FALSE`.

    ⚠⚠ IT IS THE INVERSE OF `_literal_is_materializable`, NOT A WIDENING OF IT,
    AND THAT IS WHY IT IS A THIRD PREDICATE RATHER THAN A THIRD CALL SITE.
    `broadcast_scalar` carries int64 / float64 / int32 / float32 / string /
    NULL; this reader carries a bool and NOTHING else. Calling the materializer
    mirror at a predicate slot would refuse `WHERE TRUE`, `(id>3) AND TRUE`,
    `NOT(FALSE)` and `CASE WHEN TRUE` — shapes that answer CORRECTLY —
    while still ADMITTING `WHERE 3`, which is executed as `WHERE FALSE`. Wrong
    in both directions at once.

    ⚠ A NULL IS REFUSED, AND THE COINCIDENCE IS WHY IT HAS TO BE. `WHERE NULL`
    returns no rows, which is what SQL 3VL says — but only because
    `bool_val`'s zero is FALSE and SQL's answer happens to be the same. The same
    coincidence makes `NOT(NULL)` return EVERY row where SQL says none. One rule
    cannot admit the accident and refuse the error, so both are refused."""
    return v.is_bool()


def _refuse_non_predicate_literal(v: ScalarValue, where: String) raises:
    """The refusal for a literal used as a TRUTH VALUE. One message, one token."""
    if _literal_is_a_predicate(v):
        return
    raise Error(
        PLAN_WIRE_INCOMPARABLE_LITERAL
        + ": "
        + where
        + " uses the literal "
        + String(v)
        + " AS A TRUTH VALUE — as the whole predicate, as an operand of"
        " `AND`/`OR`, under `NOT`, or as a `CASE WHEN` condition. This"
        " engine's predicate evaluator reads ONE `ScalarValue` member there"
        " and it reads it unconditionally: `if lit_val.bool_val`. It does not"
        " look at the literal's own kind, so anything that is not a BOOL"
        " leaves that member at its ZERO and THE PREDICATE EXECUTED IS"
        " `FALSE`. ⚠ Refused rather than executed, and the reason is that"
        " executing it returns WRONG ROWS WITH NO ERROR — `WHERE 3` returns"
        " NO ROWS of a six-row fixture and `(id > 3) AND 3` returns none"
        " where `id > 3` returns three."
        " ★ SEND A BOOLEAN LITERAL, OR A COMPARISON. `TRUE` and `FALSE` are"
        " admitted here and DO work — they are the one literal kind this"
        " position carries. ⚠ A NULL literal is refused too: `WHERE NULL`"
        " agreeing with SQL is a coincidence of the same zero, and the"
        " same coincidence makes `NOT(NULL)` return every row where SQL says"
        " none."
    )


def _refuse_destroyed_literal(v: ScalarValue, where: String, in_arith: Bool) raises:
    """The refusal itself, so every site raises one message under one token."""
    if in_arith:
        if _literal_survives_scalar_arith(v):
            return
    elif _literal_is_materializable(v):
        return
    var why: String
    if in_arith:
        why = String(
            " as a BARE operand of ARITHMETIC (the position named above —"
            " NOT necessarily a comparison; this rule reaches every value"
            " position). This engine's scalar-arithmetic"
            " kernel reads one"
            " `ScalarValue` member chosen by the COLUMN's type and carries"
            " only an INT or a FLOAT there — every other literal, a STRING"
            " and a NULL included, leaves that member at its ZERO, so the"
            " arithmetic executed is `<the other side> OP 0`. ⚠ This rule is"
            " NARROWER than the materializer's, and deliberately:"
            " `broadcast_scalar` CAN carry a string and this kernel cannot."
            " `id > (0 + 'c')` returns all six rows of a six-row fixture —"
            " `id > 0` — with no error. ★ SEND ARITHMETIC"
            " OVER INT OR FLOAT LITERALS ONLY, or fold the constant"
            " producer-side and send the result as a literal of the column's"
            " own type."
        )
    else:
        why = String(
            " in a spelling that MATERIALIZES it, and this engine's"
            " materializer has no arm for that literal — it would become an"
            " INT64 ZERO before any comparison happened, so the predicate"
            " executed would be `<the other side> OP 0`. ⚠ Refused rather than"
            " executed, and this is a DIFFERENT mechanism from the column-type"
            " dispatch: a comparison takes the materializing path whenever it"
            " is NOT `<a column reference> OP <a bare literal>` — so an"
            " `EXPR_CAST` on EITHER side, an `EXPR_ALIAS` over the literal, an"
            " arithmetic operand, a `CASE` arm, a `SQRT`/`POW` argument, or the"
            " literal being on the LEFT all reach it. ★ THE FIX IS TO SEND THE"
            " COMPARISON AS `<column> OP <literal of that column's own type>`,"
            " which is the one spelling that reads the literal's own value."
            " ⛔ WRAPPING IT IN AN `EXPR_CAST` IS NOT THE FIX: the cast is"
            " applied to the zero the materializer already produced, so it"
            " returns the SAME wrong rows as the bare comparison. Casts over a"
            " literal this engine CAN materialize are admitted here and DO"
            " work — `id > CAST(3 AS INT64)` returns exactly the rows"
            " `id > 3` returns."
        )
    raise Error(
        PLAN_WIRE_INCOMPARABLE_LITERAL
        + ": "
        + where
        + " compares against the literal "
        + String(v)
        + why
    )


# =============================================================================
# ★★★ THE CONTEXT — AND IT IS THE ONE THING IN THIS SECTION THAT IS NOT A MIRROR
# =============================================================================
#
# ⛔ THE HAZARD THIS BLOCK EXISTS FOR: A DOOR THAT ENUMERATES A SET OF
# EXPRESSION TAGS WHILE THE EXECUTOR WALKS THEM IS BYPASSED BY THE FIRST TAG IT
# DID NOT LIST. Refusing `col OP literal` alone is bypassed by an `EXPR_ALIAS`;
# mirroring `expr_resolves_to_column` alone is bypassed by an `EXPR_CAST`; a
# walk down to the literal through a fixed handful of tags with a silent
# `return False` tail is bypassed by any of the other child-bearing tags
# `_eval_column_expr` descends into. The only design that cannot drift is a
# walk over the `Expr` GRAMMAR — every declared child slot, an arm for every
# tag, terminal `else` REFUSES — so no arm ladder is restated and no new tag
# can outrun it.
#
# ★★★ AND THE WALK MUST GRADE EVERY POSITION, NOT ONLY COMPARISONS. A
# grammar-complete walk that is reachable only behind a test for a comparison
# operator leaves every other expression position in a plan ungraded, and over
# a six-row fixture those positions produce:
#
#   WHERE 3                            -> []            (`WHERE FALSE`)
#   (id > 3) AND 3                     -> []            where `id > 3` is [4,5,6]
#   (id > 5) OR 3                      -> [6]           (`OR FALSE`)
#   NOT('c')                           -> [1,...,6]     (`NOT FALSE`)
#   id > CASE WHEN 3 THEN 0 ELSE 9 END -> []            (`WHEN FALSE`)
#   SELECT CAST(id + 'c' AS INT64)     -> [1,...,6]     (`id + 0`)
#
# ⇒ SO THE LITERAL CHECK LIVES IN `_check_expr`, WHICH ALREADY VISITS EVERY
# EXPRESSION IN THE PLAN. Two walks over one grammar would be the copying
# defect at a smaller scale. There is one walk, and it carries a CONTEXT.
#
# ================= ⚠ THE CONTEXT IS A PROPERTY OF THE EDGE ===================
#
# ⛔ AND NOT OF THE POSITION, WHICH IS THE MISTAKE A POSITION-KEYED DESIGN MAKES
# ONE EDGE DOWN. `compiler_eval_case` sends a CASE's CONDITION to
# `_eval_predicate` and its RESULTS and DEFAULT to `_eval_column_expr` — from
# THE SAME NODE, in the same plan. So "which plan
# slot am I in" cannot answer "which reader gets this literal"; only "which edge
# did I arrive on" can. ★ THE SHAPE THAT PROVES IT AND THAT A POSITION-KEYED
# RULE DELETES: `Filter(id > CASE WHEN TRUE THEN 0 ELSE 9 END)` — one FILTER
# predicate carrying a literal that MUST be a bool (the condition) and two that
# must NOT be (the arms).
#
# THREE CONTEXTS, ONE-TO-ONE WITH THE THREE PLACES THE EXECUTOR READS A LITERAL:
#
#   CTX_PREDICATE  -> `compiler_eval_predicate`'s EXPR_LITERAL arm of
#                     `_eval_predicate`: `if lit_val.bool_val:`.
#                     RULE: `_literal_is_a_predicate` — a BOOL and nothing else.
#   CTX_VALUE      -> `compiler_helpers.broadcast_scalar` (in_arith False) or
#                     `compiler_eval_column._eval_binary_col_scalar` (in_arith
#                     True). RULE: `_refuse_destroyed_literal`, the two EXISTING
#                     mirrors, byte-identical to what they were — reached from
#                     more places.
#   CTX_COMPARAND  -> `compiler_eval_predicate`'s union-member dispatch. RULE:
#                     none HERE; the pair is graded at the PARENT by arms 1/2 of
#                     `_check_comparison_operands`, which need both operands.
#
# ⚠ THE PARAMETER IS REQUIRED, AND THAT IS THE WHOLE OF THE ANTI-DRIFT ARGUMENT.
# A new plan position, a new tag arm or a new call site cannot COMPILE without
# stating a context. There is no list to forget to extend, and no default that
# means "unchecked".
#
# ============ THE PROPAGATION TABLE, WITH THE DISPATCH IT MIRRORS ============
#
# Every edge that differs from "inherit the parent's context". Each line names
# the executor site it mirrors, so a drift has somewhere to be checked against.
#
#   BINARY_OP, op <= BIN_MOD (arithmetic)
#       both children CTX_VALUE; `in_arith` is TRUE for a child whose OWN tag
#       is `EXPR_LITERAL` and FALSE for every other child, INCLUDING an
#       `EXPR_CAST` / `EXPR_ALIAS` over a literal.
#       MIRROR: `compiler_eval_column`'s scalar fast path, and specifically
#       its selector (`binary_{right,left}_ref().tag == EXPR_LITERAL`). ⚠ A
#       WRAPPER TAKES THE EXECUTOR OFF THAT PATH: the column-column branch
#       below it evaluates the operand through `broadcast_scalar`, which
#       carries a string and a NULL that `_eval_binary_col_scalar` does not.
#       `SELECT CAST(id + CAST('3' AS INT64) AS INT64)` answers [4,5,6,7,8,9];
#       a flag propagated through the cast would refuse it.
#   BINARY_OP, BIN_AND / BIN_OR
#       both children CTX_PREDICATE.
#       MIRROR: `_eval_short_circuit_and` and `_eval_short_circuit_or` in
#       `compiler_eval_predicate`, which call `_eval_predicate` on every operand.
#   BINARY_OP, BIN_EQ..BIN_GE
#       lhs CTX_VALUE in_arith=False; rhs CTX_COMPARAND iff the executor takes
#       the union-member path, else CTX_VALUE in_arith=False.
#       MIRROR: `_eval_predicate`'s dispatch, i.e. `expr_resolves_to_column(LHS)
#       and RHS.is_literal()` — a BARE literal, no wrapper, on the RIGHT.
#       ⚠ THE EXEMPTION IS KEYED ON THE SHAPE AND NOT ON THE PARENT CONTEXT,
#       DELIBERATELY AND CONSERVATIVELY. At CTX_VALUE a comparison is
#       materialized by `_eval_column_expr` rather than by `_eval_predicate`, so
#       an argument exists for dropping the exemption there — and it is
#       UNMEASURED. Dropping it would newly refuse `flag = TRUE` inside a
#       PROJECTION, a domain-matching pair the door admits. Keeping the shape
#       rule preserves every such admission; the widening is a stated
#       residual, not a decision taken silently.
#   UNARY_OP, UN_NOT
#       child CTX_PREDICATE. MIRROR: `compiler_eval_predicate`'s UN_NOT arm.
#   UNARY_OP, anything else
#       child CTX_VALUE, in_arith=False.
#   WHEN
#       conditions CTX_PREDICATE; results and default CTX_VALUE,
#       in_arith=False (MIRROR: `compiler_eval_case`).
#   ALIAS / CAST
#       child inherits the parent's `ExprPos` unchanged — which, after the
#       arithmetic rule above, means `in_arith` is already FALSE on any
#       wrapper node under arithmetic, so a literal beneath the wrapper is
#       graded by the MATERIALIZER's ladder. ⚠ THE CAST STILL DOES NOT RESCUE
#       THE LITERAL: `_eval_column_expr` evaluates the child FIRST and applies
#       the cast to what comes back, so a cast over a destroyed literal is a
#       cast over a zero.
#   CORRELATED_SUBQUERY
#       `_check_plan` on the inner plan; contexts restart from ITS positions.
#   every other tag
#       child(ren) CTX_VALUE, in_arith=False.
#
# ⚠ THREE OPTIONS, AND WHY ONE OF THEM IS REFUTED (the reasoning is about the
# grammar and not about where it is called from):
#
#   (1) CALL THE EXECUTOR'S OWN CLASSIFIER. Refuted, and not on taste: the
#       descent is FUSED into `_eval_column_expr`'s evaluation (every arm both
#       decides and computes, and the function's signature takes a
#       `RecordBatch`), and it lives in `komira_compiler`, which is NOT a dep
#       of `komira_plan_wire` (this package sits BELOW the engine on purpose;
#       the door decodes, the endpoint executes).
#       There is no separable predicate to import.
#
#   (2) INVERT THE DEFAULT — refuse an unrecognised tag. ADOPTED, and it is
#       `_check_expr`'s terminal `else`. It costs nothing while every
#       tag has an arm; what it buys is that the NEXT tag is a refusal instead
#       of a silent wrong answer.
#
#   (3) ONE DECLARATION BOTH SIDES READ. Best held as a CHECK rather than as
#       data: derive the POSITION list from the plan variants' own type
#       declarations, refuse a position that reaches no check, and refuse if
#       `_eval_column_expr` knows a tag `_check_expr` does not. A zero-parse
#       must also be a refusal — an empty result is indistinguishable from
#       compliance.
#
# ⚠ WHY A CASE'S WHEN CONDITION IS DESCENDED, AND NOT WITH THE VALUE RULE.
# Descending the conditions with the VALUE rule would refuse a COMPARISON the
# domain table admits, because conditions go to `_eval_predicate`. Not
# descending them at all would leave a BARE LITERAL condition unchecked. The
# answer is neither: the condition edge has a DIFFERENT reader, which is what
# CTX_PREDICATE says.


comptime CTX_PREDICATE: UInt8 = 0
"""The expression is used as a TRUTH VALUE — `_eval_predicate` reads it."""

comptime CTX_VALUE: UInt8 = 1
"""The expression is MATERIALIZED into a Column — `_eval_column_expr` reads it."""

comptime CTX_COMPARAND: UInt8 = 2
"""The bare RIGHT operand of `<column> OP <literal>` — the union-member
dispatch reads it, and the PAIR is graded at the parent by arms 1/2."""


@fieldwise_init
struct ExprPos(Copyable, Movable, ImplicitlyCopyable):
    """Which reader will get this expression, carried down the walk.

    ⚠ `in_arith` IS ONLY MEANINGFUL UNDER `CTX_VALUE`, and it is not folded into
    `ctx` as a fourth constant on purpose: it is a property of the parent
    OPERATOR (`+ - * / %`), while `ctx` is a property of the parent EDGE, and
    the two compose independently — `CASE WHEN <cond> THEN (id + <lit>)` has
    both."""

    var ctx: UInt8
    var in_arith: Bool


def _child_pos(parent: ExprPos, e: Expr, is_right: Bool) -> ExprPos:
    """The context of `e`'s child on the given side. See the table above.

    `is_right` selects the RIGHT operand of a two-child node; it is ignored for
    every tag whose children share one context."""
    if e.tag == EXPR_ALIAS or e.tag == EXPR_CAST:
        return parent
    if e.tag == EXPR_BINARY_OP:
        var op = e.binary_op()
        if op <= BIN_MOD:
            # ★★ `in_arith` IS TRUE FOR A **BARE** LITERAL OPERAND AND FOR
            # NOTHING ELSE, AND THAT IS A MIRROR, NOT A NARROWING.
            # `_eval_column_expr`'s scalar fast path is selected by
            # `expr.binary_{right,left}_ref().tag == EXPR_LITERAL`
            # — the operand's OWN tag.
            # Put an `EXPR_CAST` or an `EXPR_ALIAS` over the literal and that
            # test fails, so the executor takes the COLUMN-COLUMN path, which
            # evaluates the wrapped operand through `broadcast_scalar` — a
            # reader that CARRIES a string and a NULL where
            # `_eval_binary_col_scalar` does not.
            #
            # ⛔ RETURNING `True` UNCONDITIONALLY AND PROPAGATING IT THROUGH THE
            # WRAPPER WOULD GRADE A MATERIALIZED LITERAL BY THE SCALAR KERNEL'S
            # NARROWER LADDER: `SELECT CAST(id + CAST('3' AS INT64) AS INT64)`
            # answers [4,5,6,7,8,9] and `CAST('3' AS INT64) + CAST('4' AS
            # INT64)` answers [7]x6, and both would be refused
            # `PLAN_WIRE_INCOMPARABLE_LITERAL` — a WRONG-MIRROR refusal, not a
            # wrong-answer one.
            #
            # ⚠ THIS IS NOT "STOP LOOKING UNDER CASTS". Clearing the flag hands
            # the wrapped literal to `_literal_is_materializable`, which still
            # refuses every literal `broadcast_scalar` would turn into a zero;
            # and a cast whose literal IS materialized but whose source type
            # the EXPR_CAST ladder cannot convert (a BOOL to INT64) raises by
            # name one layer down, in `compiler_eval_column`. What this
            # position decides is only WHICH of the two mirrors grades a
            # wrapped literal, which is exactly what the executor's own
            # dispatch decides.
            if is_right:
                return ExprPos(CTX_VALUE, e.binary_right_ref().is_literal())
            return ExprPos(CTX_VALUE, e.binary_left_ref().is_literal())
        if op == BIN_AND or op == BIN_OR:
            return ExprPos(CTX_PREDICATE, False)
        if op >= BIN_EQ and op <= BIN_GE:
            # ★ THE ONE EXEMPTION, SPELLED OUT RATHER THAN INFERRED, because it
            # is a mirror of `_eval_predicate`'s dispatch and not a judgement:
            # the executor takes the union-member path iff the LHS resolves to a
            # column AND the RHS is a BARE literal. Reverse the operands, wrap
            # either one, or make the left side arithmetic, and the literal is
            # MATERIALIZED instead.
            if is_right and _resolves_to_column(e.binary_left_ref()):
                if e.binary_right_ref().is_literal():
                    return ExprPos(CTX_COMPARAND, False)
        return ExprPos(CTX_VALUE, False)
    if e.tag == EXPR_UNARY_OP:
        if e.unary_op() == UN_NOT:
            return ExprPos(CTX_PREDICATE, False)
        return ExprPos(CTX_VALUE, False)
    return ExprPos(CTX_VALUE, False)



def _column_arrow_type(
    e: Expr,
    schema: Schema,
    left: Schema,
    right: Schema,
    sided_scope: Bool,
) raises -> ArrowType:
    """`e`'s column type if it is a resolvable column reference, else NULL.

    MIRROR of `compiler_helpers.resolve_col_index`'s three arms, plus the type
    lookup that function's callers perform. See the section header above for why
    the mirror is duplicated rather than imported.

    `ArrowType.NULL` is the "not a plain column reference" sentinel, and a
    genuinely NULL-typed column is indistinguishable from it — which costs
    nothing, because NULL's comparison domain is `""` and an unknown domain is
    passed anyway."""
    if e.tag == EXPR_ALIAS:
        return _column_arrow_type(
            e.alias_child_ref(), schema, left, right, sided_scope
        )
    if e.tag == EXPR_COL_IDX:
        # SHADOWED by `PLAN_WIRE_UNSUPPORTED_COL_IDX` today — see the header.
        # An ordinal has no sided form (`resolve_col_index` ignores side for
        # it), so it resolves against the schema in scope and nothing else.
        var i = e.col_idx_index()
        if i < 0 or i >= schema.num_columns():
            return ArrowType.NULL
        return schema.field_at(i).arrow_type
    if e.tag != EXPR_COL_REF:
        return ArrowType.NULL
    var side = e.col_ref_side()
    if side == COL_SIDE_NONE:
        return _lookup_arrow_type(e.col_ref_name(), schema)
    if not sided_scope:
        # ★★ OUTSIDE A JOIN, THE EXECUTOR IGNORES THE SIDE, SO THIS MIRROR MUST
        # TOO. Answering `NULL` here would be a bypass of this door.
        #
        # `resolve_col_index` reads `schema.column_index(name)` and has NO side
        # arm at all. That is not only a join question: a `COL_SIDE_LEFT`
        # reference in a plain FILTER over a SCAN never meets
        # `join_predicate_decompose`, because there is no join to decompose.
        # Setting `side = COL_SIDE_LEFT` / `COL_SIDE_RIGHT` on an otherwise
        # refused comparison changes admission and nothing else — the executor
        # returns the unsided verdict — so a mirror that answered `NULL` would
        # let `id > TRUE` -> [1,2,3,4,5,6], `name > 3` -> [1..6] and
        # `id > DECIMAL '30.75'` -> [1..6] through with one enum field. The
        # IN-list half is worse, because `_check_in_list_values` is HANDED this
        # function's answer: sided, `id IN (DATE '1970-01-03')` would return
        # [2], the row whose id equals the date's day count.
        #
        # ⚠ THE FALLBACK IS A LOOKUP, NOT A REFUSAL. `_check_expr` still
        # declines to RESOLVE a sided NAME outside a join — that refusal would
        # reject a correct SQL shape (a correlated IN-subquery, whose sided ref
        # is a CORRELATED OUTER one; see limit 3 in the header). This asks only
        # "if the executor resolves this name HERE, what type will it get?": a
        # name the enclosing scope does not carry still answers `NULL` and is
        # still declined.
        #
        # ⚠⚠ AND ABOVE A JOIN THAT ANSWER IS THE *WRONG COLUMN*, FAITHFULLY.
        # `_lookup_arrow_type` takes the FIRST `name` in `schema`, which is what
        # `resolve_col_index` will do — so at a FILTER over a join whose two
        # inputs share a column name, `RIGHT.k` is typed from the LEFT `k` by
        # BOTH readers. Nothing rewrites a sided ref at that position
        # (`join_predicate_decompose` rewrites a join's RESIDUAL and nothing
        # else); that is an engine question, not this mirror's.
        return _lookup_arrow_type(e.col_ref_name(), schema)
    # ★★ AT A RESIDUAL, BY SIDE — AND DO NOT "FIX" THIS TO MATCH
    # `resolve_col_index`'s FIRST-MATCH. These two lines are correct across
    # join types, algorithm hints, keyed and residual-only forms:
    # `join_predicate_decompose` rewrites the residual into the joined-row name
    # — applying the SAME collision rename `LogicalPlan.join`'s schema builder
    # applies — before the executor resolves anything, so typing `RIGHT.k` from
    # the right child is what the executor will read. Making these lines take
    # the first match instead would type a right-side ref from a left-side
    # column and refuse (or admit) exactly the wrong pairs.
    if side == COL_SIDE_LEFT:
        return _lookup_arrow_type(e.col_ref_name(), left)
    if side == COL_SIDE_RIGHT:
        return _lookup_arrow_type(e.col_ref_name(), right)
    return ArrowType.NULL


def _lookup_arrow_type(name: String, scope: Schema) raises -> ArrowType:
    """`name`'s type in `scope`, or NULL if it is not there.

    Not-there is `NULL` rather than a refusal because `_resolve_name` owns that
    refusal and has already run on this same expression; a second one here
    would report the wrong problem if the two ever ran out of order."""
    for i in range(scope.num_columns()):
        if scope.field_name(i) == name:
            return scope.field_at(i).arrow_type
    return ArrowType.NULL


def _check_comparison_operands(
    expr: Expr,
    schema: Schema,
    left: Schema,
    right: Schema,
    sided_scope: Bool,
    where: String,
) raises:
    """Refuse `column OP literal` where the executor has no arm for the pair.

    Only COMPARISONS (`= <> < <= > >=`). `BIN_AND` / `BIN_OR` / the arithmetic
    ops are excluded because their operands are not a column-against-a-constant
    of the same domain, and a check written for one shape must not silently
    grade another.

    ⚠⚠ THAT EXCLUSION MUST NOT GATE THE LITERAL WALK. If the grammar walk that
    finds a destroyed literal anywhere under an operand ran only when the
    operator was a comparison, a literal in `WHERE`, in `AND`/`OR`, under
    `NOT`, in a `CASE WHEN` condition, in a projection or in an aggregate
    argument would be graded by NOTHING. That walk lives in `_check_expr`'s
    `EXPR_LITERAL` arm, which visits every expression in the plan, graded by
    the CONTEXT the edge carries. This function is the union-member dispatch
    (arms 1 and 2) and nothing else."""
    var op = expr.binary_op()
    if op < BIN_EQ or op > BIN_GE:
        return

    ref lhs = expr.binary_left_ref()
    ref rhs = expr.binary_right_ref()

    # ★ THE PREDICATE IS THE EXECUTOR'S, NOT A NARROWER ONE OF THIS FILE'S. A
    # `tag == EXPR_COL_REF` test would let one `EXPR_ALIAS` walk the whole
    # refused class straight past it — see the section header above
    # `_resolves_to_column` for why the divergence, not the alias, is the
    # defect.
    #
    # BOTH ORDERS. A producer is free to write `TRUE < id`, and a check that
    # only looked at `left=column, right=literal` would grade half the plane.
    if _resolves_to_column(lhs) and _is_literal_under_aliases(rhs):
        _refuse_if_incomparable(
            _column_arrow_type(lhs, schema, left, right, sided_scope),
            _literal_under_aliases(rhs),
            where,
        )
    elif _resolves_to_column(rhs) and _is_literal_under_aliases(lhs):
        _refuse_if_incomparable(
            _column_arrow_type(rhs, schema, left, right, sided_scope),
            _literal_under_aliases(lhs),
            where,
        )

    # ⚠ THERE IS NO THIRD ARM HERE, DELIBERATELY. The exemption a third arm
    # would carry (`_resolves_to_column(lhs) and rhs.is_literal()`) lives in
    # `_child_pos`, where it decides whether the RIGHT operand's edge is
    # `CTX_COMPARAND` — the same mirror of `_eval_predicate`'s dispatch,
    # applied where every OTHER edge is also decided instead of at the one
    # node that happens to be a comparison.

# =============================================================================
# ★★ THE ADMISSION PATH — WHAT IS A MIRROR, WHAT IS NOT
# =============================================================================
#
# ── READERS THIS FILE MIRRORS. Each is a UNION-MEMBER LADDER in the executor:
#    it picks one `ScalarValue` field by something OTHER than the literal's own
#    kind, and its tail turns "no arm for this" into a ZERO. That single shape
#    is the whole class this file guards.
#
#      `_resolves_to_column`         <- `compiler_helpers.expr_resolves_to_column`
#      `_column_arrow_type`          <- `resolve_col_index`'s three arms
#      `_comparison_domain_of_*`     <- `compiler_eval_predicate`'s arm set
#      `_literal_is_materializable`  <- `compiler_helpers.broadcast_scalar`
#      `_literal_survives_scalar_arith`
#                                    <- `compiler_eval_column
#                                        ._eval_binary_col_scalar`
#      `_literal_is_a_predicate`     <- `compiler_eval_predicate`'s EXPR_LITERAL
#                                       arm
#
#    ⚠ THE EXECUTOR HAS SEVERAL WAYS TO READ A LITERAL, AND THEIR ADMISSIBLE
#    SETS DO NOT CONTAIN ONE ANOTHER:
#      * `_eval_binary_col_scalar` admits a STRICTLY SMALLER set than
#        `broadcast_scalar`, so a check written from the materializer alone
#        passes `id > (0 + 'c')`, which returns [1,2,3,4,5,6];
#      * `_eval_predicate`'s EXPR_LITERAL arm admits a set DISJOINT from
#        `broadcast_scalar`'s — a BOOL and only a BOOL — so the materializer
#        mirror is EXACTLY BACKWARDS at a predicate slot: it would refuse
#        `WHERE TRUE` (which works) and admit `WHERE 3` (which is executed as
#        `WHERE FALSE`).
#      * the IN-list kernels' `_comparable_literal_i64` is a further reader;
#        see the IN-list section below.
#
# ── ⛔ NOT A MIRROR, AND THAT IS THE STRUCTURAL POINT: `_check_expr` walks the
#      `Expr` GRAMMAR — every declared child slot, an arm for every tag,
#      terminal `else` REFUSES — and carries an `ExprPos` naming which reader
#      the EDGE it arrived on leads to. It restates no arm ladder, so
#      `_eval_column_expr` growing a new descending tag cannot silently
#      outrun it; and the context parameter is REQUIRED, so a new plan position
#      cannot be added without stating a reader.
#
# ── REWRITES — THE CLASS NO MIRROR CAN CLOSE. The door grades the tree the
#    message CARRIES; the optimizer runs INSIDE execution, after this walk, and
#    can move an expression to a DIFFERENT reader. This walk is not wrong about
#    the bytes it received — which is exactly why a more faithful mirror cannot
#    help, and why the guard is not here. The engine calls
#    `plan_wire_check_values` TWICE when it prepares a plan — once on the plan
#    the optimizer is HANDED and once on the plan it PRODUCES — and refuses the
#    DIFFERENCE. The invariant is about the OPTIMIZER, not about the producer:
#
#          if the input carries no incomparable literal,
#          the output must not carry one either.
#
#    Both halves are THIS function, so there is no copy of any rule to drift
#    from, and a new optimizer pass is covered without an edit.
#
#    ⚠⚠ BOTH QUALIFIERS IN THAT INVARIANT ARE LOAD-BEARING:
#
#    (i) "IF THE INPUT CARRIES NO..." — the gate STANDS DOWN when the input
#        was already refusable, so an instrument that executes refused shapes
#        on purpose can still measure them. The cost: a plan that was ALREADY
#        refusable and then has a DIFFERENT violation introduced by a rewrite
#        is NOT protected. For the wire that case does not exist
#        (`plan_from_bytes` already refused).
#
#    (ii) "...INCOMPARABLE LITERAL" — ONLY that token is re-raised. ⛔ THE
#        OPTIMIZER LEGITIMATELY PRODUCES PLANS THIS WALK'S REFERENCE
#        RESOLUTION IS WRONG ABOUT: a SEMI join carrying the residual
#        `RIGHT.k > 'b'` is admissible as sent and answers correctly, and
#        `join_predicate_decompose` rewrites the residual to the
#        collision-renamed `k_right`, which is in NEITHER child schema, so
#        `_resolve_name` would call it unresolvable. Re-raising THAT would
#        delete a working query, and teaching this walk the rename would be a
#        mirror of an OPTIMIZER PASS that drifts the day the rename changes.
#        So `PLAN_WIRE_UNRESOLVED_COLUMN`, `..._COLUMN_INDEX_OUT_OF_RANGE`, the
#        count checks and the schema check are NOT enforced on a post-rewrite
#        plan.
#
#    The rewrites this covers include an IN-list fold (`col IN (a)` into
#    `col = a`, and an OR-of-eq chain into `EXPR_IN_LIST`), constant folding
#    (`lit OP lit` into `lit`, which can MANUFACTURE a BOOL from two INT
#    operands: `name > (3 = 3)`), and lifting a non-column aggregate child
#    into a synthesized projection. What a new pass CAN still do is produce a
#    shape this file has no opinion about — an empty `_comparison_domain_of_*`
#    on either side is PASSED, by design — so the class that is closed is "a
#    rewrite lands a literal this door refuses", not "a rewrite cannot hurt
#    you".
#
# ── SUBSTITUTES for a check the executor does not make AT ALL — `_resolve_index`
#    (for the unchecked `RecordBatch.column_at`), `_check_non_negative`,
#    `_check_sort_keys_present`, `_check_parallel`. These cannot DIVERGE from an
#    executor opinion because there is none; they can only be INCOMPLETE.


def _refuse_if_incomparable(
    col_t: ArrowType, lit: ScalarValue, where: String
) raises:
    """The refusal itself, so both operand orders raise the same message."""
    if _comparison_pair_is_evaluable(
        _comparison_domain_of_column(col_t),
        _comparison_domain_of_literal(lit),
    ):
        return
    # ★ THE PAIR THE DOMAINS CANNOT EXPRESS. A temporal column against an
    # INTEGER literal is evaluable — `_eval_temporal_col_vs_literal` selects on
    # the COLUMN and reads `int_val`. See `_temporal_column_reads_int_literal`
    # for the two halves it mirrors and for why `is_int()` and not the whole
    # `number` domain.
    if _temporal_column_reads_int_literal(col_t, lit):
        return
    raise Error(
        PLAN_WIRE_INCOMPARABLE_LITERAL
        + ": "
        + where
        + " compares a column of type "
        + String(col_t)
        + " against the literal "
        + String(lit)
        + ", and this engine has no comparison for that pair. ⚠ Refused"
        " rather than executed, and the reason is that executing it returns"
        " WRONG ROWS WITH NO ERROR: the predicate dispatches on the COLUMN's"
        " type and reads the `ScalarValue` field that type stores its values"
        " in, so a literal carrying its value in a different field is read as"
        " that field's ZERO — `id > TRUE` becomes `id > 0` and `name > TRUE`"
        " becomes `name > \"\"`. ★ SEND A LITERAL OF THE COLUMN'S OWN TYPE."
        " ⛔ WRAPPING THE LITERAL IN AN `EXPR_CAST` IS NOT A FIX: a cast takes"
        " the comparison off this dispatch and onto"
        " the materializing one, whose `broadcast_scalar` turns a"
        " literal it has no arm for into an INT64 ZERO"
        " BEFORE the cast is applied, so the conversion has nothing left to"
        " convert. That spelling is refused too, by name, with its own"
        " message. ⚠ Some frontends DEFINE this comparison (DuckDB reads TRUE"
        " as 1; so would pandas) — this engine does not have that cast, which"
        " is why it says so instead of guessing."
    )


# =============================================================================
# ★★ `EXPR_IN_LIST`'s VALUES — THE POSITION NO EXPRESSION WALK CAN REACH
# =============================================================================
#
# ⛔ THEY ARE `List[ScalarValue]` ON `InListData`, NOT `Expr`s, so no
# expression walk reaches them and they need their own check. Unchecked, over a
# six-row fixture:
#
#   id IN (DATE '1970-01-03')    -> [2]    ★ THE ROW WHOSE `id` EQUALS THE
#                                          DATE'S DAY COUNT — a row MANUFACTURED
#                                          out of a six-row fixture, with no
#                                          error, while the identical
#                                          `id = DATE '1970-01-03'` is refused
#                                          BY NAME.
#   id IN (TRUE) / ('c') / (DEC) -> []     no error
#   id IN (2, 3.0)               -> [2]    answer [2,3] — an ALL-NUMERIC,
#                                          domain-legal list that SILENTLY LOSES
#                                          A ROW.
#
# ★★ TWO READERS, AND THE DISCRIMINATOR IS THE LIST LENGTH — WHICH IS WHY THIS
# IS TWO RULES AND NOT ONE:
#
#   n <= 1   NOT A READER AT ALL, A REWRITE. The optimizer's IN-list rewrite
#            folds `col IN (a)` into `Expr.binary(BIN_EQ, child, literal(a))`,
#            and it runs inside EXECUTION, i.e. AFTER this door. So the value
#            LITERALLY BECOMES a comparison operand and is read by the
#            union-member dispatch. ⇒ RULE 1 is this file's OWN comparison rule,
#            `_refuse_if_incomparable`, applied per value against the CHILD's
#            column type. It is sound at EVERY n, because `IN` is a disjunction
#            of equalities at every n.
#            ⚠ "SOUND AT EVERY n" IS A CLAIM ABOUT THE DISJUNCTION, NOT ABOUT
#            RULE 1's CONTENT. If RULE 1 refused a TEMPORAL column against an
#            INTEGER literal — which BOTH readers carry — it would shadow
#            RULE 2's temporal arm entirely and refuse `d IN (20456, 20458)`,
#            the day counts of two real rows. Reordering the two rules would
#            not fix that: it would make the n>=2 cell pass and leave
#            `d IN (20456)` and the bare `d = 20456` refused, moving the
#            contradiction to a different list length instead of removing it.
#            The rule itself has to be right (see
#            `_temporal_column_reads_int_literal`), which covers both lengths
#            and the plain comparison with them.
#   n >= 2   `compiler_eval_in_list._eval_in_list_int64/_int32` build a value
#            table through `temporal_literal_value._comparable_literal_i64`,
#            which routes date32 / timestamp / time / duration to
#            `_temporal_literal_i64` and returns `lit.int_val` FOR EVERYTHING
#            ELSE — a float, a bool, a string and a decimal alike.
#            ⇒ RULE 2, a separate MIRROR, and it is what catches
#            `id IN (2, 3.0)`, which RULE 1 admits (number against number) and
#            the kernel loses.
#
# ⚠ A MIRROR OF A READER COULD NEVER CLOSE THE n<=1 HALF: the offending
# expression DOES NOT EXIST when the door runs. The optimizer builds it
# afterwards — which is why the post-rewrite check described above exists.
#
# ⚠ THE THRESHOLD IS 2, DELIBERATELY, AND NOT "whatever the rewrite uses". If
# the optimizer ever raises its fold threshold this door OVER-refuses (loud)
# rather than under-refuses (silent). That direction is chosen, not incidental.
#
# ★★ RULE 2 MIRRORS THE FLOAT64, STRING AND DICTIONARY VALUE-TABLE BUILDS AS
# WELL AS THE INTEGER ONES. Each has a zeroing tail: the string kernels read
# `string_val` (`""` for a non-string literal, length 0, which memcmp-matches
# any ZERO-LENGTH cell — an empty string OR A NULL), and
# `_eval_in_list_float64` takes `else: vt.append(0.0)`, which MATCHES A GENUINE
# 0.0 CELL. The price is stated: this is a capability loss chosen over a wrong
# answer — the same trade `_refuse_if_incomparable` already makes.
#
# ⛔ THE BOOL ARM IS DELIBERATELY NOT MIRRORED, AND MIRRORING IT WOULD BREAK A
# RIGHT ANSWER. `_eval_in_list_bool` gates both `has_true` and `has_false` behind
# `values[i].is_bool()`, so it IGNORES a non-bool member, and
# `flag IN (TRUE, NULL)` answers correctly. A `v.is_bool()` mirror would turn
# that into a refusal. RULE 1 already refuses every non-bool non-NULL literal
# over a bool column, so this arm needs no rule.
#
# ⚠ AND ONE DEFECT IN THIS AREA IS NOT THIS DOOR'S: `s IN ('bb', '')` over a
# string column holding a NULL cell matches the NULL row as well as the empty
# string, on a list of TWO GENUINE STRING LITERALS. `_eval_in_list_string`
# sweeps `offsets[i+1] - offsets[i]` and does not consult the validity bitmap,
# so a NULL cell is length 0 and the zero-length probe matches it. There is
# nothing for an admission check to refuse — every member is readable. It
# needs an ENGINE fix.


def _in_list_value_survives_kernel(v: ScalarValue, col_t: ArrowType) -> Bool:
    """MIRROR of the VALUE-TABLE BUILD in each `compiler_eval_in_list` kernel,
    selected the way `_eval_in_list` selects them — by column type.

    True iff the KERNEL that builds the IN-list value table carries `v`'s value.
    False means it reads a member `v` never wrote, so the probe runs against a
    ZERO and a row either vanishes or is manufactured.

    THE FOUR MIRRORED ARMS, each against the lines it mirrors:
      INT64 / INT32   `temporal_literal_value._comparable_literal_i64`:
                      temporal literals routed by field, `int_val` for EVERYTHING
                      else — so every integer WIDTH is carried and a float, a
                      bool, a string, a decimal and a NULL are not.
      temporal        the same function, reached from `_eval_in_list_int32` /
                      `_int64` because a temporal column is physically an int.
      FLOAT64         `_eval_in_list_float64` — `is_float()` ->
                      `float_val`, `is_int()` -> `Float64(int_val)`, and
                      `else: vt.append(0.0)`. ⚠ `is_int()` is int64/int32 ONLY,
                      so an int8/int16/uint literal takes the `else` and is a
                      ZERO. The mirror says `is_int()`, not `is_any_integer()`.
      STRING / DICT   `_eval_in_list_string` and
                      `_eval_in_list_dictionary` — both build
                      `val_lens[i] = values[i].string_val.byte_length()` for
                      EVERY kind, and a non-string `ScalarValue`'s `string_val`
                      is `""`. Length 0 memcmp-matches any ZERO-LENGTH cell,
                      which in real data is an empty string OR A NULL.
                      ⚠ The DICTIONARY arm is DERIVED rather than exercised
                      through this door: a parquet footer reader may report a
                      dictionary-encoded column as STRING, in which case this
                      function never sees `ArrowType.DICTIONARY`. It mirrors a
                      kernel through a column type that may not reach it.

    ⛔ BOOL IS ABSENT ON PURPOSE — see the section header. `_eval_in_list_bool`
    ignores a member it cannot read, which is 3VL-correct for a NULL, and
    `flag IN (TRUE, NULL)` is a right answer a mirror here would refuse.

    ⚠ `True` FOR EVERY OTHER COLUMN TYPE IS A DECLINE, NOT AN APPROVAL. DECIMAL
    and LARGE_STRING reach no kernel at all (`_eval_in_list` else-RAISES), so the
    engine's own loud wall is the right refusal for them and this walk must not
    pre-empt it with a message about a value table that never runs. An unknown
    arm must not become "this is fine"; it is
    "this walk cannot judge it" — the same policy `_comparison_domain_of_*`
    applies to an unknown domain.

    ⚠⚠ THE TEMPORAL ARM IS WIDER THAN RULE 1. RULE 1 runs first and admits an
    `is_int()` literal (int64/int32) against a temporal column, which is what
    makes `d IN (20456, 20458)` execute — and that is STRICTLY NARROWER than
    this line. An int8/int16/uint literal is carried correctly by
    `_comparable_literal_i64` (it reads `int_val`, which is where every
    integer width keeps its value) and is still refused by RULE 1, whose
    mirror — `_temporal_literal_i64` — RAISES on those widths.
    ⇒ RESIDUAL, STATED RATHER THAN CLOSED: at n>=2 that is an OVER-refusal. It
    is expressible on the wire (the codec has codes for all eight integer
    widths) though not by a producer that always emits `_DT_INT64`. Running
    RULE 2 first for the column types it mirrors and falling back to RULE 1
    only where it declines would lift it, and its falsifier must exist before
    the widening does: a widening with nothing executed behind it is the same
    mistake as a refusal with nothing executed behind it, pointed the other
    way.

    ★ A NULL MEMBER SURVIVES, AND NO VALUE-TABLE BUILD EVER READS IT.
    `_eval_in_list` removes NULL members BEFORE it selects a kernel and answers
    them itself — a NULL member never matches, and a row that matched nothing
    answers NULL (`x IN (1, NULL)` is `x = 1 OR x = NULL`). So SQL's
    `k IN (2, NULL)` — whose `OR` the optimizer folds into exactly this node —
    gets the 3VL answer instead of a refusal. `komira_compiler`'s IN-list NULL
    contract test is the falsifier."""
    if v.is_null():
        return True
    if col_t == ArrowType.INT64 or col_t == ArrowType.INT32:
        return v.is_any_integer()
    if col_t.is_temporal():
        return (
            v.is_any_integer()
            or v.is_date32()
            or v.is_timestamp()
            or v.is_time()
            or v.is_duration()
        )
    if col_t == ArrowType.FLOAT64:
        return v.is_float() or v.is_int()
    if col_t == ArrowType.STRING or col_t == ArrowType.DICTIONARY:
        return v.is_string()
    return True


def _in_list_kernel_note(col_t: ArrowType) -> StaticString:
    """WHICH value-table build refused this member, in the refusal itself.

    ⚠ ONE SENTENCE PER MIRRORED ARM, BECAUSE ONE SENTENCE FOR ALL OF THEM IS
    WRONG FOR THREE OF THEM. `_comparable_literal_i64` is true of the integer
    and temporal arms and of nothing else. A producer told that its STRING list
    is misread by an integer helper it never invoked has been handed a false
    lead."""
    if (
        col_t == ArrowType.INT64
        or col_t == ArrowType.INT32
        or col_t.is_temporal()
    ):
        return (
            "The kernel builds its value table with `_comparable_literal_i64`,"
            " which carries a TEMPORAL literal and an INTEGER of any width and"
            " reads `int_val` for EVERYTHING else — so a FLOAT, a BOOL, a"
            " STRING and a DECIMAL all probe against a ZERO."
        )
    if col_t == ArrowType.FLOAT64:
        return (
            "`_eval_in_list_float64` builds its value table from `float_val`"
            " for a FLOAT literal and from `int_val` for an INT64/INT32 one,"
            " and its `else` arm appends 0.0 — so a BOOL, a STRING, a DECIMAL,"
            " a temporal literal and a NARROW/UNSIGNED integer all probe"
            " against 0.0, which MATCHES A GENUINE 0.0 CELL."
        )
    return (
        "`_eval_in_list_string` / `_eval_in_list_dictionary` build their value"
        " table from `values[i].string_val.byte_length()` for EVERY kind, and a"
        " non-string `ScalarValue`'s `string_val` is the EMPTY STRING — so the"
        " probe is a zero-length memcmp, which matches any zero-length cell."
        " ⚠ In real data a zero-length cell is an empty string OR A NULL, so"
        " a non-string member can manufacture both the empty-string row and"
        " the NULL row."
    )


def _check_in_list_values(
    expr: Expr, col_t: ArrowType, where: String
) raises:
    """Grade every `IN`-list value against BOTH readers. See the header above.

    ⚠ IT IS A PER-VALUE LOOP AND NOT A WALK, AND IT CANNOT BE A WALK. The values
    are `List[ScalarValue]` on `InListData`, so no expression descent can reach
    them."""
    ref values = expr.in_list_values_ref()
    var n = len(values)
    for i in range(n):
        var w = where + " IN-list value " + String(i)
        # RULE 1 — EVERY n.
        _refuse_if_incomparable(col_t, values[i], w)
        # RULE 2 — n >= 2 only, where the membership KERNEL runs instead of a
        # rewritten comparison.
        if n < 2:
            continue
        if _in_list_value_survives_kernel(values[i], col_t):
            continue
        raise Error(
            PLAN_WIRE_INCOMPARABLE_LITERAL
            + ": "
            + w
            + " carries the literal "
            + String(values[i])
            + ", which this engine's IN-list MEMBERSHIP KERNEL cannot read"
            " against a column of type "
            + String(col_t)
            + ". "
            + _in_list_kernel_note(col_t)
            + " ⚠ Refused rather than executed, and the reason is that"
            " executing it returns WRONG ROWS WITH NO ERROR — `id IN (3.0, 5.0)`"
            " returns NO ROWS where the answer is [3,5], and `id IN (2, 4.0)`"
            " returns ONE row where the answer is two. ⚠⚠ AND THE SAME LITERAL"
            " IN A ONE-ELEMENT LIST WORKS:"
            " `id IN (3.0)` returns [3], because at n<=1 the optimizer folds the"
            " node into `id = 3.0` and the comparison path reads `float_val`."
            " Adding a second element changes the READER, which is why this"
            " refusal starts at two. ★ SEND INTEGER LITERALS, or write the"
            " disjunction as ORed equalities."
        )


# =============================================================================
# EXPRESSIONS
# =============================================================================


def _check_expr(
    expr: Expr,
    schema: Schema,
    left: Schema,
    right: Schema,
    sided_scope: Bool,
    where: String,
    pos: ExprPos,
) raises:
    """Resolve every column reference in `expr` against the schema in scope.

    ⚠ THREE SCHEMAS, AND ONLY A JOIN RESIDUAL USES MORE THAN ONE.
    `Expr.left("x")` / `Expr.right("x")` carry `COL_SIDE_LEFT` /
    `COL_SIDE_RIGHT` and appear in a join predicate residual until
    `join_predicate_decompose` rewrites them into unsided refs over the joined
    row. The dev validator declines to check a residual at all for exactly this
    reason. This walk does not have to decline AT A JOIN: there it HAS both
    children, so it passes their schemas down and a sided reference is resolved
    against ITS OWN SIDE.

    `sided_scope` is TRUE at exactly one call site — the join residual — and
    FALSE everywhere else, where `left`/`right`/`schema` are the same value and
    a sided ref names a scope this walk does not carry. ⚠ THE FLAG IS NOT
    BOOKKEEPING: without it, `left` and `right` silently become "whatever the
    enclosing node's schema is", and a correct query gets refused for naming a
    column of the join's other input.

    ⚠ EVERY `EXPR_*` TAG HAS AN ARM AND THE TERMINAL `else`
    REFUSES. See `PLAN_WIRE_UNCHECKED_VALUE_SITE`."""

    # ---- the two leaves this file exists for --------------------------------
    if expr.tag == EXPR_COL_REF:
        var side = expr.col_ref_side()
        if side == COL_SIDE_LEFT or side == COL_SIDE_RIGHT:
            # ★★ RESOLVED ONLY WHERE THE TWO SIDES EXIST. A side-qualified ref
            # means "the LEFT input's `x`" and its scope is a JOIN. `Expr`
            # documents such a qualifier outside a join as an ERROR that the
            # optimizer rewrites before any other pass — but the SQL frontend
            # EMITS the pre-rewrite form, and this walk runs on a decoded plan
            # that may be at any stage.
            #
            # ⚠ RESOLVED AGAINST THE ENCLOSING NODE'S SCHEMA, A CORRECT SQL
            # SHAPE WOULD BE REFUSED: `Filter predicate (LEFT side) names
            # column 'l_suppkey', available [o_orderkey, o_custkey,
            # o_totalprice]`. The ref is correct; the SCOPE this walk has is
            # the wrong one. `Expr.left()` is ALSO how the SQL binder marks a
            # CORRELATED OUTER reference inside a subquery's inner plan, so
            # this arm's skip is what keeps every `IN (SELECT …)` / `EXISTS`
            # query admissible. A sided ref is resolved AT A JOIN, where both
            # schemas are in hand, and is a stated residual anywhere else (see
            # limit 3 in the file header).
            if sided_scope:
                if side == COL_SIDE_LEFT:
                    _resolve_name(
                        expr.col_ref_name(), left, where + " (LEFT side)"
                    )
                else:
                    _resolve_name(
                        expr.col_ref_name(), right, where + " (RIGHT side)"
                    )
        elif side == COL_SIDE_NONE:
            _resolve_name(expr.col_ref_name(), schema, where)
        else:
            # Unreachable through the codec — `_col_ref_of_side` refuses any
            # other side on the way in. Kept because this function is reachable
            # from a plan built in-process, and a fourth side value must not
            # become an unchecked name.
            raise _refuse_unchecked(
                where,
                String(
                    "the column reference carries COL_SIDE "
                    + String(Int(side))
                    + ", which is not NONE, LEFT or RIGHT"
                ),
            )

    elif expr.tag == EXPR_COL_IDX:
        # ★ THE 261-BYTE SIGSEGV. A positional reference resolves against the
        # schema in scope regardless of side — there is no sided form of it.
        #
        # ⚠ THIS RUNS FIRST AND IT STILL MATTERS. An out-of-range ordinal is a
        # defect in the PRODUCER'S column resolution and keeps its own token, so
        # a deployed frontend branching on
        # `PLAN_ENDPOINT_COLUMN_INDEX_OUT_OF_RANGE` goes on seeing it.
        _resolve_index(expr.col_idx_index(), schema, where)
        # ★★ AND THEN THE 257-BYTE ONE. An IN-RANGE ordinal is refused too —
        # see `PLAN_WIRE_UNSUPPORTED_COL_IDX` for the crash and for why
        # this is a refusal rather than a feature. The index is named in the
        # message together with the column it MEANT, because the producer has
        # that name in the same bytes and the whole fix is to send it instead.
        raise Error(
            PLAN_WIRE_UNSUPPORTED_COL_IDX
            + ": "
            + where
            + " addresses a column by ORDINAL (index "
            + String(expr.col_idx_index())
            + "), and this engine does not execute positional column"
            " references — at any index. The index is IN RANGE: the schema in"
            " scope has "
            + String(schema.num_columns())
            + " columns "
            + _schema_columns(schema)
            + ", so this plan is SEMANTICALLY CORRECT and executing it ends the"
            " process (measured: a stack dump, not a catchable error, at 257"
            " bytes). ★ SEND `col_ref` WITH THE NAME INSTEAD — emit '"
            + schema.field_name(expr.col_idx_index())
            + "'. Your message already carries that name; it is"
            " `WireSchema.fields["
            + String(expr.col_idx_index())
            + "].name` in the same bytes. ⚠ The FORMAT still carries"
            " `WireColIdx`, so these bytes stay readable and a future build"
            " that executes ordinals needs no format change; this refusal is"
            " about what THIS build will run."
        )

    # ---- ★★★ THE LEAF, AND IT IS WHERE THE LITERAL CHECK LIVES --------------
    elif expr.tag == EXPR_LITERAL:
        # ⛔ THIS ARM MUST NOT BE `pass`. `_check_expr` visits every literal in
        # every plan, so this is the one place a literal can be graded without
        # a second, parallel grammar walk. Three contexts, three readers, one
        # arm, one walk.
        if pos.ctx == CTX_PREDICATE:
            _refuse_non_predicate_literal(expr.literal_value(), where)
        elif pos.ctx == CTX_VALUE:
            _refuse_destroyed_literal(
                expr.literal_value(), where, pos.in_arith
            )
        # CTX_COMPARAND: graded at the PARENT by arms 1/2 of
        # `_check_comparison_operands`, which need the COLUMN's type as well as
        # the literal and therefore cannot be answered from the leaf alone.

    # ---- one child -----------------------------------------------------------
    elif expr.tag == EXPR_UNARY_OP:
        _check_expr(
            expr.unary_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_CAST:
        _check_expr(
            expr.cast_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_ALIAS:
        _check_expr(
            expr.alias_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_STRING_OP:
        _check_expr(
            expr.string_op_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_REGEXP:
        _check_expr(
            expr.regexp_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_SUBSTRING:
        _check_expr(
            expr.substring_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_STRING_FN:
        _check_expr(
            expr.string_fn_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_STRING_FN_N:
        # Every argument, same context. There is
        # no `is_right` distinction to make — this family has no operand whose
        # admission context differs from its siblings' (`_child_pos` returns
        # the same `ExprPos` for both flags on any tag it does not name).
        for i in range(expr.string_fn_n_num_args()):
            _check_expr(
                expr.string_fn_n_arg_ref(i), schema, left, right, sided_scope,
                where, _child_pos(pos, expr, False),
            )
    elif expr.tag == EXPR_UDF_CALL:
        _check_expr(
            expr.udf_call_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_EXTRACT:
        _check_expr(
            expr.extract_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_MATH_FN:
        _check_expr(
            expr.math_fn_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_AGG_FN:
        _check_expr(
            expr.agg_fn_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_IN_LIST:
        # The VALUES are `ScalarValue` literals; no column names in them.
        _check_expr(
            expr.in_list_child_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
        # ★★ AND THEN THE VALUES, WHICH NO EXPRESSION WALK CAN REACH. They are
        # `List[ScalarValue]`, so this is a per-value loop with the CHILD's
        # column type in hand. `_column_arrow_type` answers `NULL` when the child
        # is not a plain column reference, and both rules DECLINE on an unknown
        # type rather than guessing. See the section above `_check_in_list_values`.
        _check_in_list_values(
            expr,
            _column_arrow_type(
                expr.in_list_child_ref(), schema, left, right, sided_scope
            ),
            where,
        )
    elif expr.tag == EXPR_STRUCT_FIELD:
        # The FIELD name resolves against the parent's STRUCT type, not against
        # `schema`. The parent expression is what this walk owns.
        _check_expr(
            expr.struct_field_parent_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        # ⚠ `field_idx` IS NOT BOUNDED HERE, AND THE REASON IS THAT ITS FRAME OF
        # REFERENCE IS A TYPE, NOT A SCHEMA. It indexes the PARENT's struct
        # children, which are known only after the parent's type is inferred —
        # a step this walk deliberately does not perform (see limit 3). It is
        # bounded where the type exists: `LogicalPlan`'s type inference refuses
        # `fidx < 0 or fidx >= parent_field.num_children()`. Named here so the
        # omission reads as a decision rather than as the `col_idx` defect
        # repeated one field over.
        _check_expr(
            expr.struct_field_idx_parent_ref(), schema, left, right,
            sided_scope, where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_JSON_EXTRACT:
        _check_expr(
            expr.json_extract_parent_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )

    # ---- two children --------------------------------------------------------
    elif expr.tag == EXPR_BINARY_OP:
        # ★ THE TWO OPERANDS DO NOT ALWAYS SHARE A CONTEXT, WHICH IS THE ONLY
        # REASON `_child_pos` TAKES A SIDE. Under a comparison the executor
        # reads a BARE RIGHT literal through the union-member dispatch and
        # MATERIALIZES everything else, so the right operand alone can be a
        # `CTX_COMPARAND`.
        _check_expr(
            expr.binary_left_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
        _check_expr(
            expr.binary_right_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, True),
        )
        # ★ AND THEN THE PAIR, which neither operand can be wrong about alone.
        # Runs AFTER both children so that an unresolvable column name keeps
        # `PLAN_WIRE_UNRESOLVED_COLUMN` — "your column resolution is off" and
        # "this pair has no comparison" are two different edits on the producer.
        _check_comparison_operands(
            expr, schema, left, right, sided_scope, where
        )
    elif expr.tag == EXPR_MATH_FN2:
        _check_expr(
            expr.math_fn2_left_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
        _check_expr(
            expr.math_fn2_right_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
    elif expr.tag == EXPR_MAP_GET:
        # BOTH sides: the key is itself an `Expr` and may be `col("which_key")`.
        _check_expr(
            expr.map_get_parent_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )
        _check_expr(
            expr.map_get_key_ref(), schema, left, right, sided_scope,
            where, _child_pos(pos, expr, False),
        )

    # ---- n children ----------------------------------------------------------
    elif expr.tag == EXPR_WHEN:
        # ★★ THE EDGE THAT IS THE WHOLE ARGUMENT FOR CONTEXTS. `compiler_eval_
        # case` sends the CONDITION to `_eval_predicate` and the RESULTS and the
        # DEFAULT to `_eval_column_expr` — from the SAME node. The two readers admit
        # DISJOINT literal sets (a bool here, six non-bool kinds there), so one
        # rule for "a literal inside a CASE" is wrong for one of the two slots
        # whichever rule it is. `Filter(id > CASE WHEN TRUE THEN 0 ELSE 9 END)`
        # is the shape that needs both at once.
        for i in range(expr.when_num_cases()):
            _check_expr(
                expr.when_case_condition_ref(i), schema, left, right,
                sided_scope, where, ExprPos(CTX_PREDICATE, False),
            )
            _check_expr(
                expr.when_case_result_ref(i), schema, left, right,
                sided_scope, where, ExprPos(CTX_VALUE, False),
            )
        _check_expr(
            expr.when_default_ref(), schema, left, right, sided_scope,
            where, ExprPos(CTX_VALUE, False),
        )

    # ---- names carried on the payload rather than in a child expr -----------
    elif expr.tag == EXPR_WINDOW_FN:
        ref wf = expr.window_fn_data_ref()
        if wf.arg_col.byte_length() > 0:
            _resolve_name(wf.arg_col, schema, where + " (window arg)")
        for i in range(len(wf.partition_by)):
            _resolve_name(
                wf.partition_by[i], schema, where + " (window PARTITION BY)"
            )
        for i in range(len(wf.order_by)):
            _resolve_name(
                wf.order_by[i], schema, where + " (window ORDER BY)"
            )

    # ---- ★ THE CROSS-EDGE BACK INTO THE PLAN TREE ---------------------------
    elif expr.tag == EXPR_CORRELATED_SUBQUERY:
        # ★★ IT DESCENDS. `CorrelatedSubqueryData.inner_plan` is the ONLY
        # `LogicalPlan`-typed field outside a plan node's own child slot — the
        # one way a whole plan, scan leaves included, hides where a
        # plan-node-only walk never looks. A plan-node-only walk has exactly
        # that hole, and the dev validator declines here, recording a
        # NOT-VALIDATED note. Declining is right for a diagnostic
        # and wrong at an untrusted boundary: it would leave every node, every
        # scan and every column index inside the subquery unchecked, behind one
        # expression.
        #
        # ⚠ REFUSING HERE WOULD BE WRONG TOO: a correlated subquery is an
        # ordinary SQL shape a user can write, and refusing it would reject it
        # for a property of THIS WALK rather than of the plan. That is the
        # "gate that cries wolf" failure, and the answer is not to relax the
        # standard but to do the work: the inner plan is fully checkable
        # against its OWN schemas, which is where its own defects live.
        _check_plan(corr_subq_inner_plan_ref(expr))
        # ⚠ `outer_refs` IS DELIBERATELY NOT RESOLVED, AND THIS IS A REAL
        # RESIDUAL, NOT A TECHNICALITY. Those names refer to the ENCLOSING
        # query's scope, which this walk does not carry — resolving them
        # against the inner plan's schema would refuse every correct correlated
        # subquery, and against the outer node's would be a guess about which
        # ancestor. They are resolved for real by `decorrelate`, which is the
        # pass that builds the correlation context. Named here so the omission
        # is a decision on the record rather than a walk that quietly stops.
        # Same for `in_lhs_col` / `in_rhs_col`: `in_rhs_col` belongs to the
        # inner plan's output and `in_lhs_col` to the outer scope, and the
        # asymmetry is exactly what makes a single-schema resolver wrong here.

    elif expr.tag == EXPR_BETWEEN or expr.tag == EXPR_SORT_KEY:
        # Tags 10 / 11 are declared on `Expr` with NO payload field and no
        # factory — nothing builds one, and `_expr_from_wire` has no
        # arm that produces one either. If one ever arrives its operands are
        # unreachable from here, so it is refused rather than passed.
        raise _refuse_unchecked(
            where,
            String(
                "expression tag "
                + String(Int(expr.tag))
                + " has no payload field on `Expr`, so its operands cannot be"
                " reached"
            ),
        )

    else:
        raise _refuse_unchecked(
            where,
            String(
                "expression tag "
                + String(Int(expr.tag))
                + " has no arm in `_check_expr`. The codec grew a decode arm"
                " and this walk did not follow — that is a bug in this build,"
                " not in the message"
            ),
        )


def _agg_arg_slots(func: UInt8) raises -> Int:
    """How many argument slots THIS BUILD's aggregate `func` READS.

    ⚠ TOTAL OVER THE VOCABULARY, WITH A REFUSING TAIL. `agg_fn_from_wire`
    admits engine tags 0..23 and nothing else, so every arm below is reachable
    and the `raise` is not — until a twenty-fifth aggregate is declared without
    extending this table, at which point the door SAYS SO instead of guessing.
    Neither guess is safe: 1 would refuse a legitimate new bivariate, and 4
    would silently re-open the defect `PLAN_WIRE_AGG_ARG_DROPPED` names.

    ★ IT IS A CEILING, NOT A COUNT. `COUNT(*)` populates ZERO slots and
    `COUNT(col)` one; both are correct and this function answers 1 for both.
    Only a slot ABOVE the ceiling is refused — see the token.
    """
    if agg_is_bivariate(func):
        # ⭐ THE BIVARIATE FAMILY — `AGG_CORR` plus the eleven `regr_*` /
        # `covar_*` tags. All twelve populate slot 0
        # and slot 1: `agg_expr.corr(x, y)` is `AggExpr(AGG_CORR, x, y, None)`,
        # i.e. child then child1, and the family is bound the same way.
        #
        # ⛔ THE PREDICATE, NOT A TWELVE-ARM LADDER. A ladder of
        # `func == AGG_CORR`-style tests would let a new bivariate added
        # without editing it fall through to the 1-slot arm below, and
        # `_check_agg_arity` would then REFUSE the encode of a legitimate plan — the
        # `PLAN_WIRE_AGG_ARG_DROPPED` defect wearing a refusal instead of a
        # silent drop. `agg_is_bivariate` is declared beside the tags.
        return 2
    if (
        func == AGG_SUM
        or func == AGG_COUNT
        or func == AGG_MIN
        or func == AGG_MAX
        or func == AGG_MEAN
        or func == AGG_COUNT_DISTINCT
        or func == AGG_FIRST
        or func == AGG_LAST
        or func == AGG_STDDEV_SAMP
        or func == AGG_MEDIAN
        or func == AGG_LARGEST_K
        or func == AGG_VAR_SAMP
        # The POPULATION-FINALIZE family is
        # UNIVARIATE, like the sample pair it shares a Welford state with.
        or func == AGG_VAR_POP
        or func == AGG_STDDEV_POP
        or func == AGG_SEM
        # The MONOID-FOLD family is UNIVARIATE:
        # one column reduced over one monoid.
        or func == AGG_COUNT_IF
        or func == AGG_BOOL_AND
        or func == AGG_BOOL_OR
        or func == AGG_PRODUCT
        # The ARRIVAL-ORDER PICK family is UNIVARIATE: one column, one picked
        # row. `AGG_FIRST` / `AGG_LAST` are listed above; `AGG_ANY_VALUE` is
        # the third member.
        or func == AGG_ANY_VALUE
        # The COMPENSATED sums and the
        # HIGHER-MOMENT trio are all UNIVARIATE: one column in, one number out.
        # ⛔ A tag absent from this ladder RAISES at plan-wire encode rather
        # than defaulting to 1, so a served aggregate that never round-trips
        # the wire looks fine until the first distributed plan.
        or func == AGG_KAHAN_SUM
        or func == AGG_KAHAN_AVG
        or func == AGG_SKEWNESS
        or func == AGG_KURTOSIS
        or func == AGG_KURTOSIS_POP
    ):
        return 1
    raise Error(
        PLAN_WIRE_AGG_ARG_DROPPED
        + ": aggregate function tag "
        + String(Int(func))
        + " has no ARITY in this build, so this door cannot say whether its"
        " argument slots are read or discarded. The decoder admitted the tag"
        " (`agg_fn_from_wire` knows it) and `_agg_arg_slots` does not — which"
        " means an aggregate was added to the vocabulary without extending"
        " that table. ⚠ REFUSED RATHER THAN GUESSED: guessing 1 would refuse"
        " a legitimate multi-argument aggregate and guessing 4 would restore"
        " the silent dropped-argument answer this token exists to stop. The"
        " fix is one arm in `_agg_arg_slots`."
    )


def _check_agg_arity(
    func: UInt8, has1: Bool, has2: Bool, has3: Bool, where: String
) raises:
    """Refuse a POPULATED argument slot this aggregate does not read.

    ⚠ THE SLOTS ARE SPARSE AND ARE READ BY FIELD, NEVER BY
    `num_children()` — that accessor STOPS at the first empty slot, so an
    `AggExpr` holding (child, None, child2, None) reports ONE child and would
    walk past exactly the payload this function exists to see.
    """
    var ceiling = _agg_arg_slots(func)
    var extra = -1
    if has1 and ceiling <= 1:
        extra = 1
    elif has2 and ceiling <= 2:
        extra = 2
    elif has3 and ceiling <= 3:
        extra = 3
    if extra < 0:
        return
    raise Error(
        PLAN_WIRE_AGG_ARG_DROPPED
        + ": "
        + where
        + " is `"
        + String(agg_func_base_name(func))
        + "`, which this engine evaluates with at most "
        + String(ceiling)
        + " argument(s), and this plan POPULATES argument slot "
        + String(extra)
        + ". ⚠ NOTHING READS THAT SLOT. The expression in it is not"
        " evaluated, not refused and not reported — the engine answers the"
        " query WITHOUT it, so a `sum(id, <anything>)` returns `sum(id)` and"
        " no error: `sum(id)` with `child1` set to TRUE or to 'c' returns the"
        " answer to `sum(id)`. ★ SEND THE AGGREGATE THE NUMBER OF ARGUMENTS IT"
        " TAKES. The bivariate aggregates (`corr`, `regr_*`, `covar_*`) read"
        " slot 1; every other member reads slot 0 alone, and `count(*)` reads"
        " none."
        " Slots 2 and 3 exist in the format for a multi-argument aggregate"
        " this build does not have — they are carried, never read."
    )


def _check_expr_1(
    expr: Expr, schema: Schema, where: String, ctx: UInt8
) raises:
    """The unary-node spelling: ONE schema in scope, and `sided_scope=False`.

    ⚠ THE FLAG IS THE POINT, NOT THE REPEATED ARGUMENT. Passing `schema` three
    times would make a `COL_SIDE_LEFT` ref resolve against a schema that is not
    a join side, which refuses a correct SQL query — an IN-subquery, whose
    `Expr.left(...)` is a CORRELATED OUTER reference and not a join side at
    all. `False` says "there are no sides here", and the sided arm declines
    rather than guessing.

    ⚠⚠ `ctx` IS REQUIRED AND HAS NO DEFAULT, AND THAT IS THE ANTI-DRIFT
    ARGUMENT IN ONE PARAMETER. A new plan position cannot be added without
    STATING which reader its expressions reach; there is no list to forget to
    extend and no default that means "unchecked". `in_arith` is False at every
    plan-node entry because no plan node is itself an arithmetic operator — it
    is set only by `_child_pos`, from the parent OPERATOR."""
    _check_expr(
        expr, schema, schema, schema, False, where, ExprPos(ctx, False)
    )


# =============================================================================
# COUNTS
# =============================================================================


def _check_non_negative(v: Int, what: String, where: String) raises:
    if v < 0:
        raise Error(
            PLAN_WIRE_NEGATIVE_COUNT
            + ": "
            + where
            + " declares "
            + what
            + " = "
            + String(v)
            + ". A count of rows cannot be negative, and the engine type that"
            " holds it documents the invariant without enforcing it — which is"
            " safe for a plan built in this process and is not safe for one"
            " that arrived as bytes."
        )


def _check_sort_keys_present(
    n_keys: Int, where: String, instead: String
) raises:
    """★ THE CHECK `_check_parallel` CANNOT MAKE. It compares two lengths; this
    one asks whether there is anything to compare. Both callers pass the KEY
    list, which is the list every other field on the node is parallel to — so
    zero keys means the node has no subject, not merely a short flag list.

    `instead` names the node that says, unambiguously, whatever the producer
    might have meant by sending none. That is not politeness: it is the
    argument for refusing rather than no-opping, made where the producer reads
    it."""
    if n_keys != 0:
        return
    raise Error(
        PLAN_WIRE_EMPTY_SORT_KEYS
        + ": "
        + where
        + " carries ZERO sort keys. An ordering with nothing to order by is not"
        " a query this format can mean, and there is no answer to fall back to:"
        " returning the rows untouched would be a GUESS that you meant 'no"
        " ordering', when the likelier cause by far is that the keys were"
        " DROPPED — proto3 OMITS AN EMPTY REPEATED FIELD ENTIRELY, so a producer"
        " that simply forgot to populate `keys` sends exactly these bytes and"
        " pays nothing for it. ★ "
        + instead
        + " Otherwise populate `keys`, with one `descending` and one"
        " `nulls_first` flag for each. ⚠ Refused rather than executed: this"
        " state reaches the sort kernel's single-key arms, which are"
        " guarded by `len(sort_keys) > 1` — a test for MORE than one key, which"
        " zero also fails — and the `sort_keys[0]` beyond it ABORTS the process"
        " (`index 0 is out of bounds, valid range is 0 to -1`), which is not an"
        " error any caller can catch."
    )


def _check_parallel(
    a: Int, a_name: String, b: Int, b_name: String, where: String
) raises:
    if a != b:
        raise Error(
            PLAN_WIRE_INCONSISTENT_COUNT
            + ": "
            + where
            + " carries "
            + String(a)
            + " "
            + a_name
            + " and "
            + String(b)
            + " "
            + b_name
            + ". These describe each other element for element, so the message"
            " states two different things at once and there is no reading of it"
            " that is not a guess."
        )


# =============================================================================
# THE PLAN WALK
# =============================================================================


def _check_keys(
    keys: List[String], schema: Schema, where: String
) raises:
    for i in range(len(keys)):
        _resolve_name(keys[i], schema, where + " key " + String(i))


def _check_plan(plan: LogicalPlan) raises:
    """Recursive, bottom-up: a child is checked before the node that reads its
    output schema, so the first refusal names the DEEPEST site that is wrong
    rather than the outermost one that inherited it."""

    if plan.tag == PLAN_SCAN:
        ref d = plan.scan_data_ref()
        # ★★ THE SOURCE SCHEMA, NOT `plan.output_schema`, AND THE DIFFERENCE IS
        # A REAL BUG, NOT A NICETY.
        #
        # A scan's OUTPUT schema is post-PROJECTION. Its pushdown FILTER runs on
        # the SOURCE rows, BEFORE the projection prunes them — which is the
        # whole point of predicate pushdown with projection pruning. So
        # `scan(source=[a,b,s], projection=[b], filter=a > 11)` is not merely
        # legal, it is the shape the optimizer WANTS. Resolving that filter
        # against the output schema `[b]` refuses it.
        #
        # ⚠ `tests/test_plan_wire_round_trip_ir.mojo`'s `obs[1]:scan(optionals)`
        # — a fixture built for a completely different purpose — holds exactly
        # this shape, and a walk that resolved against the output schema
        # reports "Scan pushdown filter names column 'a', available [b]" on it.
        # A corpus that exists to freeze BYTES catches a semantic error here,
        # which is the argument for keeping adversarial fixtures around after
        # the thing they were written for is settled.
        #
        # `_plan_from_wire` refuses a schemaless scan outright, so a decoded
        # scan always has `Some` here. The `plan.output_schema` fallback is for
        # a plan built in-process through the legacy `LogicalPlan.scan` factory,
        # which can leave it `None`.
        #
        # ⚠ ONE `Schema` COPY PER SCAN NODE, and it is a readability trade
        # rather than an oversight: a `ref` binding cannot be produced by a
        # conditional expression here. The cost is bounded the way everything
        # else on this path is — `PLAN_WIRE_MAX_BYTES` caps the message, so the
        # schema bytes an adversary can make this copy are a constant factor of
        # what they already sent.
        var src_schema = (
            d.schema.value().copy() if d.schema
            else plan.output_schema.copy()
        )
        if d.projection:
            ref proj = d.projection.value()
            for i in range(len(proj)):
                _resolve_name(
                    proj[i], src_schema,
                    "Scan projection entry " + String(i),
                )
        if d.filter:
            # ⚠ CTX_PREDICATE, AND IT IS DERIVED FROM THE SOURCE RATHER THAN
            # EXERCISED. The reader is the SAME `_eval_predicate` a
            # `PLAN_FILTER` predicate reaches (the parquet scan and the
            # streaming late-materialization path both evaluate the pushdown
            # filter that way), and a pushdown filter is the same shape a
            # producer writes.
            _check_expr_1(
                d.filter.value(), src_schema, "Scan pushdown filter",
                CTX_PREDICATE,
            )
        if d.row_count:
            _check_non_negative(
                d.row_count.value(), String("row_count"), String("Scan")
            )

    elif plan.tag == PLAN_FILTER:
        ref d = plan.filter_data_ref()
        _check_plan(d.child[])
        # ★ CTX_PREDICATE. `WHERE 3`, `(id>3) AND 3`, `NOT('c')` and
        # `CASE WHEN 3` all reach here and would return a manufactured row
        # set; `WHERE TRUE` / `WHERE FALSE` are the controls that must survive.
        _check_expr_1(
            d.predicate, d.child[].output_schema, "Filter predicate",
            CTX_PREDICATE,
        )

    elif plan.tag == PLAN_PROJECT:
        ref d = plan.project_data_ref()
        _check_plan(d.child[])
        for i in range(len(d.exprs)):
            # ★ CTX_VALUE. A literal the materializer has no arm for becomes a
            # column of ZEROS here; `SELECT CAST(id + 'c' AS INT64)` would
            # return `id` unchanged.
            _check_expr_1(
                d.exprs[i], d.child[].output_schema,
                "Project expression " + String(i), CTX_VALUE,
            )

    elif plan.tag == PLAN_AGGREGATE:
        ref d = plan.aggregate_data_ref()
        _check_plan(d.child[])
        for i in range(len(d.group_by)):
            # ⚠ CTX_VALUE, DERIVED FROM THE SHAPE OF THE NODE (a key is
            # materialized, not tested for truth) rather than exercised. If the
            # grouper turns out to have a union-member ladder of its own, that
            # is another reader and this line is where it lands.
            _check_expr_1(
                d.group_by[i], d.child[].output_schema,
                "Aggregate group_by " + String(i), CTX_VALUE,
            )
        # ⚠ ALL FOUR ARG SLOTS, ENUMERATED BY FIELD. `AggExpr` carries `child`
        # .. `child3` for the multi-argument aggregates (CORR, COVAR, UDAFs),
        # and `num_children()` STOPS AT THE FIRST EMPTY SLOT, so it cannot
        # enumerate a sparse payload. A walk that read slot 0 only would leave a
        # bad reference in the second argument of a bivariate aggregate
        # unchecked.
        for i in range(len(d.agg_exprs)):
            ref ae = d.agg_exprs[i]
            var w = String("Aggregate agg_expr ") + String(i)
            # ★ CTX_VALUE — for slot 0 `avg(id + 'c')` would be `avg(id + 0)`;
            # slots 1..3 get the same context by derivation.
            #
            # ⚠ THE READER IS A PROJECT NODE THE PRODUCER NEVER WROTE, and that
            # is worth knowing before someone re-derives it:
            # the optimizer's aggregate-input materialization LIFTS a non-col-ref agg
            # child into a synthesized `alias(<child>, '__agg_in_0')` PROJECT,
            # after this door has run. CTX_VALUE is nonetheless the correct
            # context — the lifted node is materialized by exactly the two
            # readers CTX_VALUE names — but the position where the value is lost
            # is one the optimizer CREATES. See the rewrite section above.
            if ae.child:
                _check_expr_1(
                    ae.child.value(), d.child[].output_schema, w, CTX_VALUE
                )
            if ae.child1:
                _check_expr_1(
                    ae.child1.value(), d.child[].output_schema, w + " arg 1",
                    CTX_VALUE,
                )
            if ae.child2:
                _check_expr_1(
                    ae.child2.value(), d.child[].output_schema, w + " arg 2",
                    CTX_VALUE,
                )
            if ae.child3:
                _check_expr_1(
                    ae.child3.value(), d.child[].output_schema, w + " arg 3",
                    CTX_VALUE,
                )
            # ★★ AND THEN THE SLOT ITSELF, WHICH IS A DIFFERENT QUESTION FROM
            # ITS CONTENTS. The four calls above grade what is IN each slot;
            # this one asks whether the slot is READ. `sum(id)` with `child1`
            # populated executes as `sum(id)` and returns rows — see
            # `PLAN_WIRE_AGG_ARG_DROPPED`.
            #
            # ⚠ AFTER THE FOUR, NOT BEFORE, AND THAT ORDER IS LOAD-BEARING.
            # `sum(id)` with `child1 = id + 'c'` is refused by
            # `PLAN_WIRE_INCOMPARABLE_LITERAL`, and a deployed frontend
            # branching on `PLAN_ENDPOINT_INCOMPARABLE_LITERAL(37)` goes on
            # seeing it. Same rule as `_resolve_index` running ahead of
            # `PLAN_WIRE_UNSUPPORTED_COL_IDX` a few hundred lines up: an
            # existing named refusal is not re-pointed by a new one that also
            # applies.
            _check_agg_arity(
                ae.func, Bool(ae.child1), Bool(ae.child2), Bool(ae.child3), w
            )

    elif plan.tag == PLAN_JOIN:
        ref d = plan.join_data_ref()
        _check_plan(d.left[])
        _check_plan(d.right[])
        _check_parallel(
            len(d.left_on), String("left keys"),
            len(d.right_on), String("right keys"),
            String("Join"),
        )
        _check_keys(d.left_on, d.left[].output_schema, String("Join left_on"))
        _check_keys(
            d.right_on, d.right[].output_schema, String("Join right_on")
        )
        if d.residual:
            # ★ THE RESIDUAL IS CHECKED, NOT NOTED. Its refs are side-qualified
            # until `join_predicate_decompose` rewrites them, and this node has
            # both sides — so `_check_expr` resolves each against its own. The
            # node's own output schema is the scope for an UNSIDED ref, which is
            # what a residual carries after the rewrite.
            # ⚠ CTX_PREDICATE, DERIVED FROM THE SOURCE — a residual is a
            # predicate over the joined row, so its literals are read as truth
            # values.
            _check_expr(
                d.residual.value()[],
                plan.output_schema,
                d.left[].output_schema,
                d.right[].output_schema,
                True,  # ★ the one place both sides exist
                String("Join residual"),
                ExprPos(CTX_PREDICATE, False),
            )

    elif plan.tag == PLAN_SORT:
        ref d = plan.sort_data_ref()
        _check_plan(d.child[])
        # ★★ BEFORE THE COUNT CHECKS, AND THE ORDER IS THE POINT. With zero keys
        # the two `_check_parallel` calls below compare 0 with 0 and AGREE, so a
        # gate that ran them first would report nothing at all. Asking whether
        # there is a subject has to precede asking whether its flags line up.
        _check_sort_keys_present(
            len(d.keys),
            String("Sort"),
            String(
                "IF YOU MEANT NO ORDERING, SEND NO `sort` NODE AT ALL — the"
                " child on its own already says exactly that, and says it"
                " unambiguously."
            ),
        )
        _check_parallel(
            len(d.keys), String("sort keys"),
            len(d.descending), String("`descending` flags"),
            String("Sort"),
        )
        _check_parallel(
            len(d.keys), String("sort keys"),
            len(d.nulls_first), String("`nulls_first` flags"),
            String("Sort"),
        )
        _check_keys(d.keys, d.child[].output_schema, String("Sort"))

    elif plan.tag == PLAN_LIMIT:
        ref d = plan.limit_data_ref()
        _check_plan(d.child[])
        _check_non_negative(d.n, String("n"), String("Limit"))
        _check_non_negative(d.offset, String("offset"), String("Limit"))

    elif plan.tag == PLAN_DISTINCT:
        ref d = plan.distinct_data_ref()
        _check_plan(d.child[])
        if d.columns:
            _check_keys(
                d.columns.value(), d.child[].output_schema, String("Distinct")
            )

    elif plan.tag == PLAN_TOPN:
        ref d = plan.topn_data_ref()
        _check_plan(d.child[])
        _check_non_negative(d.n, String("n"), String("TopN"))
        # ★★ THE SAME STATE ON THE SAME KERNEL FILE, ONE ARM OVER. Both crash
        # sites are `_sort_batch_single_key(batch^, sort_keys[0], descending[0])`
        # behind a `len(...) > 1` guard; `_execute_topn_sink` has TWO of them
        # (the `k >= num_rows` full-sort arm and the full-sort+slice fallback),
        # which is why fixing one node and not the other would have left the
        # identical 229-byte message live.
        _check_sort_keys_present(
            len(d.keys),
            String("TopN"),
            String(
                "IF YOU MEANT 'ANY N ROWS, IN NO PARTICULAR ORDER', SEND A"
                " `limit` NODE — that is precisely what it means and this"
                " format already carries it."
            ),
        )
        _check_parallel(
            len(d.keys), String("sort keys"),
            len(d.descending), String("`descending` flags"),
            String("TopN"),
        )
        _check_parallel(
            len(d.keys), String("sort keys"),
            len(d.nulls_first), String("`nulls_first` flags"),
            String("TopN"),
        )
        _check_keys(d.keys, d.child[].output_schema, String("TopN"))

    elif plan.tag == PLAN_PARTITION_BY:
        ref d = plan.partition_by_data_ref()
        _check_plan(d.child[])
        ref cs = d.child[].output_schema
        # ★ `descending` IS PARALLEL TO `order_keys`, whatever `plan.proto`'s
        # "three independent facts" note suggests. THE ENGINE STATES THE
        # INVARIANT: its plan validator reports `len(order_keys) !=
        # len(descending)` as a validation failure, and the partition-scan
        # kernel reads `sink_data.descending[i]` across the ORDER KEYS with
        # nothing checking the length. ⚠ It is NOT parallel to `partition_keys` — that pairing
        # genuinely is three facts, and the proto note was right about it.
        _check_parallel(
            len(d.order_keys), String("order keys"),
            len(d.descending), String("`descending` flags"),
            String("PartitionBy"),
        )
        _check_keys(d.partition_keys, cs, String("PartitionBy partition"))
        _check_keys(d.order_keys, cs, String("PartitionBy order"))
        for i in range(len(d.partition_exprs)):
            ref col = d.partition_exprs[i].column
            if col.byte_length() > 0:
                _resolve_name(
                    col, cs,
                    "PartitionBy expression " + String(i) + " column",
                )

    elif plan.tag == PLAN_PARTITION_TOPN:
        ref d = plan.partition_topn_data_ref()
        _check_plan(d.child[])
        _check_non_negative(d.k, String("k"), String("PartitionTopN"))
        _check_non_negative(
            d.over_fetch_k, String("over_fetch_k"), String("PartitionTopN")
        )
        # ★★ 246 BYTES, A STACK DUMP, AND NO CATCHABLE ERROR. One sort key and
        # ZERO `descending` flags. The PartitionTopN kernel reads
        # `spec.descending[0]` guarded only by `len(spec.sort_keys) == 1`, and
        # reads `descending[i]` across the sort keys — neither subscript is
        # bounded. The engine's plan validator states this invariant and never
        # fires, because it only ever runs on plans built in this process,
        # where the two lists are built together.
        _check_parallel(
            len(d.sort_keys), String("sort keys"),
            len(d.descending), String("`descending` flags"),
            String("PartitionTopN"),
        )
        ref cs = d.child[].output_schema
        _check_keys(d.partition_keys, cs, String("PartitionTopN partition"))
        _check_keys(d.sort_keys, cs, String("PartitionTopN sort"))

    elif plan.tag == PLAN_ASOF_JOIN:
        ref d = plan.asof_join_data_ref()
        _check_plan(d.left[])
        _check_plan(d.right[])
        ref ls = d.left[].output_schema
        ref rs = d.right[].output_schema
        _check_parallel(
            len(d.left_keys), String("left keys"),
            len(d.right_keys), String("right keys"),
            String("AsofJoin"),
        )
        _check_keys(d.left_keys, ls, String("AsofJoin left"))
        _check_keys(d.right_keys, rs, String("AsofJoin right"))
        _resolve_name(d.left_asof, ls, String("AsofJoin left_asof"))
        _resolve_name(d.right_asof, rs, String("AsofJoin right_asof"))
        # The four pre-sort hint lists name columns on their own side. A hint
        # naming a column that is not there is the shape that makes the
        # compiler skip a sort it needed — wrong rows, not a crash.
        _check_keys(d.left_sort_keys, ls, String("AsofJoin left pre-sort"))
        _check_keys(d.right_sort_keys, rs, String("AsofJoin right pre-sort"))

    elif plan.tag == PLAN_UNION:
        ref d = plan.union_data_ref()
        for i in range(len(d.children)):
            _check_plan(d.children[i][])

    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        _check_plan(plan.cast_to_varchar_data_ref().child[])

    elif plan.tag == PLAN_VIEW_REF or plan.tag == PLAN_CSE_REF:
        # OPAQUE LEAVES — see limit 1 in the header. There is no subtree yet, so
        # there is nothing here to resolve. Their carried output schema has
        # already been reconciled by `_check_output_schema`, and every reference
        # ABOVE them is resolved against it by the arms above.
        pass

    else:
        raise _refuse_unchecked(
            String("plan tag ") + String(Int(plan.tag)),
            String(
                "it has no arm in `_check_plan`. Every tag `_plan_from_wire`"
                " can produce is named above, so this is a decode arm that grew"
                " without this walk following it"
            ),
        )


def plan_wire_check_values(plan: LogicalPlan) raises:
    """★ THE VALUE GATE. Refuse a decoded plan whose VALUES its own schema
    contradicts.

    Runs inside `plan_from_bytes`, after `_plan_from_wire` and therefore after
    `_check_output_schema` has reconciled every node's carried schema with the
    one its factory derives. Both of those are preconditions: this walk resolves
    references against schemas, and a walk that did so before the schemas were
    reconciled would be checking references against numbers the message chose.

    ⚠ COST. One pass over the plan tree, resolving each name by linear scan of
    the schema in scope — O(references x columns), on a tree already bounded to
    `PLAN_WIRE_MAX_NODES` records and 16 MiB by `plan_wire_admit`. Paid once per
    decode, never per row. The alternative to paying it is the 261-byte
    SIGSEGV."""
    _check_plan(plan)
