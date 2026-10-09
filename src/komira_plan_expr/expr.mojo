# =============================================================================
# Expr — the expression tree for the Komira compiler pipeline
# =============================================================================
#
# Mojo does not have recursive enums. We use a tagged struct with Optional
# variant data and OwnedPointer[Expr] for heap-allocated child references
# (like Rust's Box<Expr>). Each Expr node is owned by its parent -- no
# manual memory management, no reference counting needed.
#
# Memory layout:
#     tag: UInt8                           -- discriminant
#     _col_ref: Optional[ColRefData]       -- populated when tag == EXPR_COL_REF
#     _literal: Optional[LiteralData]      -- populated when tag == EXPR_LITERAL
#     _binary: Optional[BinaryOpData]      -- populated when tag == EXPR_BINARY_OP
#     _unary: Optional[UnaryOpData]        -- populated when tag == EXPR_UNARY_OP
#     _cast: Optional[CastData]            -- populated when tag == EXPR_CAST
#     _alias: Optional[AliasData]          -- populated when tag == EXPR_ALIAS
#     _when: Optional[WhenData]            -- populated when tag == EXPR_WHEN
#
# Only one Optional is populated at a time. The others are None.
# =============================================================================

from std.memory import OwnedPointer, ArcPointer
from komira_collections.slab import Slab
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.render_text import write_escaped, write_quoted
# `PartitionFrame` comes from the ZERO-IMPORT leaf `partition_frame.mojo`, NOT
# from `partition_expr.mojo`. Same type (that file re-exports this one); the
# difference is the CLOSURE — `partition_expr` also declares
# `partition_expr_output_field`, which imports `arrow.schema`, whose closure is
# ~50 modules `Expr` never names. ⛔ Do not "tidy" this back to
# `from .partition_expr import PartitionFrame`: it compiles, and it silently
# re-attaches every one of those modules to this translation unit.
from komira_plan_expr.partition_frame import PartitionFrame
# Pretty-printers live in `expr_helpers.mojo` to keep this file smaller.
from komira_plan_expr.expr_helpers import _write_binop, _write_unop, _write_strop
# ⛔⛔ THIS FILE MUST NOT NAME `LogicalPlan`. THAT IS THE INVARIANT.
#
# An import of `LogicalPlan` (with `CorrelatedSubqueryData` / `CORR_KIND_*`)
# from `logical_plan` would be the ONLY reason `Expr` is not a leaf type.
# `Expr` tag 14 carries a correlated subquery, whose payload owns a whole
# `LogicalPlan`, which is built out of `Expr` — a real mutual dependency that
# is SQL semantics (`WHERE x > (SELECT ...)`), not bad wiring. That import
# would put this file inside a large strongly-connected component spanning
# `plan/` and `source/`.
#
#     MEASURED (the core packages-restricted, seed included):
#       closure(plan/expr.mojo) with that import ............. 90
#       ... without it ....................................... 59
#       ... plus the `partition_expr` -> `partition_frame` cut .. 7
#
# The payload lives in `corr_subquery_data.mojo` and holds the plan in an
# `ErasedBox` — owned, deep-copied, but UNNAMED here. Read that module's header
# before touching any of this; in particular, it records why a registry handle
# is the WRONG shape (`bind_plan_inmem_payloads` mutates a subquery's inner plan
# in place, so shared ownership is a silent cross-expression mutation).
#
# ⚠ THE ONE-LINE REGRESSION TO WATCH FOR: adding `LogicalPlan` back to any
# signature in this file compiles fine and silently re-attaches that closure.
# `git grep -n LogicalPlan src/komira_plan_expr/expr.mojo` must return
# nothing but comments.
from komira_plan_expr.corr_subquery_data import (
    CorrelatedSubqueryData,
    BoxablePlan,
    make_correlated_subquery_data,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    CORR_KIND_IN_CORRELATED,
)
from komira_arrow.dtype_sentinel import DTYPE_NONE


# =============================================================================
# Tag constants (UInt8-backed for compact storage)
# =============================================================================

comptime EXPR_COL_REF: UInt8 = 0
comptime EXPR_COL_IDX: UInt8 = 1
comptime EXPR_LITERAL: UInt8 = 2
comptime EXPR_BINARY_OP: UInt8 = 3
comptime EXPR_UNARY_OP: UInt8 = 4
comptime EXPR_CAST: UInt8 = 5
comptime EXPR_ALIAS: UInt8 = 6
comptime EXPR_STRING_OP: UInt8 = 7
comptime EXPR_WHEN: UInt8 = 8
comptime EXPR_IN_LIST: UInt8 = 9
comptime EXPR_BETWEEN: UInt8 = 10
comptime EXPR_SORT_KEY: UInt8 = 11
# Aggregate-as-expression for the
# scalar-broadcast rewrite. Carries an `op: UInt8` (one of AGG_*) and a
# `child: Expr` (the column reference). An optimizer rule is expected to
# consume the variant before eval sees it; `interpret_expr`
# (komira_kernels) returns NULL for this tag.
comptime EXPR_AGG_FN: UInt8 = 12

# Window-function-as-expression for the
# `df.with_column(col("x").rank().over("g"))` Polars-shape API. Lowered
# by the SDK's window lowering (not in this tree) to PARTITION_BY directly
# (fast-path). Multi-window co-location is not done.
comptime EXPR_WINDOW_FN: UInt8 = 13

# Correlated subquery.
#
# `CorrelatedSubqueryData` lives in the LEAF `corr_subquery_data.mojo` and
# holds the inner plan in an `ErasedBox` — still owned, still deep-cloned, just
# not NAMED, so this file names no plan type and `Expr` is a leaf. Reach the
# plan with `corr_subquery.corr_subq_inner_plan_ref(expr)`.
#
# `Expr` stores `Optional[OwnedPointer[CorrelatedSubqueryData]]` and
# is not in any cycle. The optimizer pass `flatten_dependent_joins`
# (komira_optimizer) consumes this variant before the plan compiler sees it
# (lowered to SEMI / ANTI / LEFT+agg joins). `interpret_expr` (komira_kernels)
# returns NULL for this tag; a node that reaches eval was missed by the pass.
comptime EXPR_CORRELATED_SUBQUERY: UInt8 = 14

# `regexp_*`
# functions backed by the pure-Mojo Thompson NFA
# (`komira_column_kernels/regexp_nfa.mojo`).  One variant carrying
# `RegexpData{op, child, pattern, replacement, flags, group}` where `op` is one
# of the `REGEXP_*` ops below. The pattern is a plan-literal String (compiled
# once per batch by the dispatch arm; compiling once per plan is a possible
# optimization — see regexp_functions.mojo).
comptime EXPR_REGEXP: UInt8 = 15

# STRUCT field projection.
#
# Two variants ship as a pair:
#
# `EXPR_STRUCT_FIELD` (tag 16) — by-NAME projection used by the UNTYPED
# DataFrame surface (`col("addr").field("city")`). Payload carries
# `(parent: Expr, field_name: String)`. At eval time the parent is
# evaluated to a STRUCT Column; the child column whose
# `_field_names[i] == field_name` is extracted by linear scan.
# Composable, no planner changes, works for any DataFrame.
#
# `EXPR_STRUCT_FIELD_IDX` (tag 17) — by-INDEX projection emitted by the
# TYPED DataFrame surface (`df.field["addr", "city"]()`). Payload carries
# `(parent: Expr, field_idx: Int)`. The TypedDataFrame resolves the field
# index at COMPTIME via `comptime_struct_field_index[S, parent, name]()`;
# at eval time the arm directly indexes `_children[field_idx]` — zero
# scan. Mirrors the EXPR_COL_REF / EXPR_COL_IDX bound-twin pattern.
#
# Both ride on `Column._children` + `_field_names` slots.
comptime EXPR_STRUCT_FIELD: UInt8 = 16
comptime EXPR_STRUCT_FIELD_IDX: UInt8 = 17

# MAP[key] projection.
#
# `EXPR_MAP_GET` (tag 18) — per-row dynamic key lookup against a MAP-typed
# parent column.  Payload `MapGetData{parent: Expr, key: Expr}` — BOTH are
# Expr (key is a full Expr, not just a String, because the key is a runtime
# value — that's the whole point of Map vs Struct).  No comptime-idx twin:
# Map keys are inherently runtime values; the typed-DF surface adds value
# at the TYPE-CHECK level (comptime-validates KeyType matches the Map's
# declared key type), but not at runtime resolution.
#
# Arrow Map encoding: MAP is physically `list<entries: struct<key, value>>`
# (per Arrow spec).  Each row is a list of entries.  `map[k]` per row scans
# the row's entries list for `entry.key == k`, returning `entry.value` (or
# NULL on miss).  `_keys_sorted=True` -> can binary-search; otherwise
# linear scan.  Both currently use a linear scan.
comptime EXPR_MAP_GET: UInt8 = 18

# `json_extract` + SQL `->` / `->>` operators.
#
# `EXPR_JSON_EXTRACT` (tag 19) — extract a path from a JSON-bytes column.
# Payload `JsonExtractData{parent: Expr, path_segments: List[String],
# output_type: ArrowType, preserve_extension_metadata: Bool}`. `parent`
# must evaluate to an Arrow STRING column whose values are JSON text.
# `path_segments` is the parsed JSONPath (e.g. `["user", "id"]` for
# `$.user.id`). `output_type` is the target Arrow type (STRING only; a
# typed `json_extract[Int64]` is not served). `preserve_extension_metadata`
# discriminates `->` (True — attach `ARROW:extension:name = "komira.ext.json"`)
# vs `->>` (False — plain STRING).
#
# Eval-arm lives in the plan compiler's column evaluator (not in this tree)
# (like EXPR_STRUCT_FIELD / EXPR_MAP_GET).
# The kernel `extract_column` is in `komira_json_index/json_extract_kernel.mojo`
# and uses the structural index per-row (path-aware fast-path).
comptime EXPR_JSON_EXTRACT: UInt8 = 19

# Temporal field extract.
#
# `EXPR_EXTRACT` (tag 20) — extract a calendar / clock field from a DATE32
# or TIMESTAMP_* column.  Payload `ExtractData{child: Expr, unit: UInt8}`.
# `child` must evaluate to a DATE32 (Int32 days) or TIMESTAMP_* (Int64
# ticks) Column.  `unit` is one of the `EXTRACT_*` constants below.
#
# Eval-arm lives in the plan compiler's column evaluator (not in this tree)
# (like EXPR_JSON_EXTRACT).  The kernel
# entry points are in `komira_kernels/temporal_extract.mojo`.
#
# Unit semantics:
#   - EXTRACT_YEAR / MONTH / DAY / HOUR / MINUTE / SECOND / QUARTER
#     -> Int32 column.  HOUR / MINUTE / SECOND raise on DATE32 (no
#     sub-day field).
#   - EXTRACT_TRUNC_* -> same type as input (DATE32 / TIMESTAMP_*),
#     value rounded down to the period start.
#
# Output type:
#   * Field extracts (year/month/day/hour/...) -> INT32 Column.
#   * date_trunc(DATE32, *) -> DATE32 Column.
#   * date_trunc(TIMESTAMP_*, *) -> same TIMESTAMP_* unit.
comptime EXPR_EXTRACT: UInt8 = 20

# Scalar floating-point math
# functions needed by the `haversine` example (great-circle distance over
# lat/lon).  Two variants ship as a pair, mirroring the unary/binary split
# the rest of the Expr surface uses:
#
# `EXPR_MATH_FN` (tag 21) — UNARY math: sin / cos / sqrt / asin / radians.
# Payload `MathFnData{op, child}` where `op` is one of the MATH_* unary
# constants below.  `child` must evaluate to a numeric Column at eval time;
# the kernel casts to FLOAT64 and emits a FLOAT64 Column.  Null in -> null
# out (validity is carried verbatim).
#
# `EXPR_MATH_FN2` (tag 22) — BINARY math: atan2(y, x).  Payload
# `MathFn2Data{op, left, right}`.  Both children evaluate to numeric
# Columns; the kernel casts both to FLOAT64 element-wise and emits FLOAT64.
# A separate variant (rather than overloading EXPR_BINARY_OP) keeps the
# arithmetic BinOp dispatch — which is type-preserving — distinct from the
# always-FLOAT64 math-fn dispatch.
#
# Eval-arms live in the plan compiler's column evaluator (not in this tree)
# (like EXPR_EXTRACT).  The kernels are in
# `komira_column_kernels/scalar_math.mojo`.
comptime EXPR_MATH_FN: UInt8 = 21
comptime EXPR_MATH_FN2: UInt8 = 22
# Substring: `substring(s, start, length)` scalar over a
# string column -> a string column. 1-based `start`, `length` chars.
# ⚠ A NEGATIVE `length` IS A SENTINEL **FAMILY**, NOT A SINGLE VALUE: `-1` is
# "to end of string" (the
# two-argument `substring(s, start)` form) and `-k` for k >= 2 is "to end,
# dropping k-1 trailing CHARACTERS", which is what `left(s, NEGATIVE)` desugars
# to — `left('abc',-1)` = `'ab'` needs the string's RUNTIME length, and the
# SHORTFALL is the part a plan-time field can carry. ⛔ It is NOT DuckDB's
# negative-length semantics (a window extending BACKWARD from `start`), and the
# SQL binder must keep REFUSING a negative `length` literal for that reason.
# The arithmetic lives at ONE site, in the plan compiler's column evaluator (not
# in this tree). String-producing, so it routes through
# the column evaluator's project OVERLAY (the EXPR_REGEXP precedent),
# NOT the numeric runtime-expr opcode path.
comptime EXPR_SUBSTRING: UInt8 = 23

# The UNARY scalar string functions. `upper`,
# `lower`, `trim`, `ltrim`, `rtrim`, `reverse` (Utf8 -> Utf8) and `length`
# (Utf8 -> Int64) share ONE payload shape — `{op: UInt8, child: Expr}` — which
# is byte-for-byte the `MathFnData` shape, so this variant is the string-side
# twin of `EXPR_MATH_FN`.
#
# ⚠ THE OUTPUT TYPE IS PER-OP, NOT PER-TAG, and that is the one way this
# differs from `EXPR_MATH_FN` (which is always FLOAT64). `STRFN_LENGTH` emits
# INT64 and every other member emits Utf8, so every site that infers a field
# type from this tag MUST switch on the op — `string_fn_returns_int()` below is
# the single place that answers it, so a new op cannot be added without a
# decision being recorded there.
#
# WHY A NEW TAG RATHER THAN NEW `EXPR_STRING_OP` OPS: `EXPR_STRING_OP` is the
# four fixed-pattern PREDICATES (contains / starts_with / ends_with / like).
# Every one is Bool-out and carries a `pattern` String the wire requires; a
# Utf8-out member with no pattern riding that tag would make both the
# output-type inference and the wire payload conditional on the op in a family
# whose whole shape is that they are not.
#
# String-producing, so eval routes through the column evaluator's project
# OVERLAY (the EXPR_SUBSTRING / EXPR_REGEXP precedent), NOT the
# numeric runtime-expr opcode path.
comptime EXPR_STRING_FN: UInt8 = 24

# A REGISTERED SCALAR UDF, AS AN EXPRESSION. The 25th
# tag.
#
# ★ WHY A TAG AND NOT A PLAN NODE. A UDF carried
# on a plan node (`ProjectData.udf: Optional[UdfData]`) cannot compose: it is
# the WHOLE projection, so it cannot be nested inside another expression, it
# cannot appear in a predicate, and two of them cannot appear in one query. It
# also needs a separate verb to name its output, because a node has nowhere
# for an ordinary `.alias()` to attach. As an `Expr` all four fall out for free —
# `with_columns(affine(col("x")).alias("y"))`, `upper(affine(col("x")))`,
# `filter(affine(col("x")) > lit(10))`, and the same UDF twice.
#
# ⚠ AND IT SURVIVES THE OPTIMIZER, WHICH THE NODE FORM DOES NOT. A `UdfData`
# on a plan node is dropped by every rebuild site that uses the non-UDF plan
# factories (measured: after the full optimizer pipeline, `has_udf()` is
# already False).
# An `Expr` payload has
# ONE copy site — `Expr.copy()`, one arm below — so a rebuilt plan carries the
# UDF by construction rather than by every rebuilder remembering.
#
# ⛔ THE `handle` IS PROCESS-LOCAL AND IS STRIPPED AT THE WIRE, exactly as
# `UdfData.registered_handle_id` is. The peer re-mints its own by resolving
# `name` against ITS registry. `name` is therefore the RESOLUTION KEY, not a
# label — which is why `register_scalar` has exactly one name parameter in its
# whole surface and there is no second name to disagree with.
#
# ⚠ BOTH DTYPES ARE ON THE PAYLOAD BECAUSE THE PLAN IS RUNTIME DATA, and that
# is NOT a restatement of the `comptime IN_TAG`/`OUT_TAG` on `ScalarUdf`. Those
# comptime members are the ONE derivation; these fields are the single runtime
# copy the derivation writes, and `ScalarUdf.__call__` is the only writer.
# `out_type` is what `_infer_expr_field` reads, so a UDF's output type comes
# from the customer's own signature and from nowhere else.
comptime EXPR_UDF_CALL: UInt8 = 25

# The VARIADIC / MULTI-ARGUMENT scalar string
# functions. `concat`, `concat_ws`, `replace`, `lpad`, `rpad`, `repeat` and
# `strpos` share ONE payload shape — `{op: UInt8, args: List[Expr]}` — because
# the thing they have in common is not their arity, it is that EVERY ARGUMENT
# IS AN ORDINARY EXPRESSION. A fixed-arity twin of `EXPR_MATH_FN2` would have
# bought `replace`/`lpad`/`rpad` nothing and `concat` nothing at all.
#
# ⛔ AND THIS IS WHY `concat` IS NOT A `BIN_CONCAT` ON `EXPR_BINARY_OP`,
# WHICH IS THE OBVIOUS-LOOKING FREE ROUTE AND IS WRONG. That tag is already
# `{op, left, right}` and an n-ary fold over it is linear, so it reads as a
# one-line addition. MEASURED: **many non-test modules switch on the
# `BIN_*` op space** — `komira_kernels/expr_interpreter`,
# `expr_kernel_templates` and `viewport_expr_codec` among them, and the engine's
# numeric opcode compiler and the optimizer's expression rules outside this
# tree — and a
# STRING-PRODUCING member arriving at any of those AS A BINARY OP is a silent
# mishandling, not a refusal. Nothing measures that space the way the
# walker-arms lint measures this one. The `EXPR_*`
# space is the one with a gate; put the new behaviour where the gate is.
#
# ⚠ THE OUTPUT TYPE IS PER-OP, exactly as for `EXPR_STRING_FN`: `strpos` emits
# INT64 and every other member emits Utf8. `string_fn_n_returns_int()` below is
# the single place that answers it.
#
# ⚠ AND THE ARITY IS PER-OP TOO, WHICH IS NEW. `string_fn_n_arity()` states the
# REQUIRED argument count for each member (or `-1` for genuinely variadic), so
# the binder, the wire decoder and the evaluator all refuse a malformed node
# against ONE table instead of three opinions.
#
# String-producing (except `strpos`), so eval routes through the column
# evaluator's project OVERLAY — the `EXPR_STRING_FN`
# precedent — never the numeric runtime-expr opcode path.
comptime EXPR_STRING_FN_N: UInt8 = 26



# =============================================================================
# The tag SPACE, counted and named — the `PLAN_TAG_COUNT` / `plan_tag_name`
# shape (`logical_plan.mojo`), applied to the expression side.
# =============================================================================
#
# WHY THIS EXISTS HERE. Several walkers enumerate this tag space and each one is
# only as complete as the last person to extend it:
# `plan_helpers._collect_expr_columns` (a missed arm silently prunes scan
# projections), `plan_validator._validate_expr_columns` (a
# missed arm reports a bad column reference as VALID), and
# `plan/scan_binding_gate.check_expr_scan_bindings` (a missed arm hides a whole
# `LogicalPlan`, because tag 14 carries one). A COUNT and a LABEL TABLE at the
# DEFINITION site give every one of those a way to notice the space grew that
# does not depend on the walker's author noticing.
#
# Adding an `EXPR_*` constant above means bumping the count and adding one arm
# below.

comptime EXPR_TAG_COUNT: Int = 27
"""One past the highest `EXPR_*` tag id.

Every `EXPR_*` constant is declared in this file, so this covers the whole
space by construction."""


def _write_expr_tag_name[W: Writer](mut writer: W, tag: UInt8):
    """WRITE what `expr_tag_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a
    shared library can bind such a pair CROSSED and crash the host
    interpreter."""
    if tag == EXPR_COL_REF:
        writer.write(String("EXPR_COL_REF"))
        return
    if tag == EXPR_COL_IDX:
        writer.write(String("EXPR_COL_IDX"))
        return
    if tag == EXPR_LITERAL:
        writer.write(String("EXPR_LITERAL"))
        return
    if tag == EXPR_BINARY_OP:
        writer.write(String("EXPR_BINARY_OP"))
        return
    if tag == EXPR_UNARY_OP:
        writer.write(String("EXPR_UNARY_OP"))
        return
    if tag == EXPR_CAST:
        writer.write(String("EXPR_CAST"))
        return
    if tag == EXPR_ALIAS:
        writer.write(String("EXPR_ALIAS"))
        return
    if tag == EXPR_STRING_OP:
        writer.write(String("EXPR_STRING_OP"))
        return
    if tag == EXPR_WHEN:
        writer.write(String("EXPR_WHEN"))
        return
    if tag == EXPR_IN_LIST:
        writer.write(String("EXPR_IN_LIST"))
        return
    if tag == EXPR_BETWEEN:
        writer.write(String("EXPR_BETWEEN"))
        return
    if tag == EXPR_SORT_KEY:
        writer.write(String("EXPR_SORT_KEY"))
        return
    if tag == EXPR_AGG_FN:
        writer.write(String("EXPR_AGG_FN"))
        return
    if tag == EXPR_WINDOW_FN:
        writer.write(String("EXPR_WINDOW_FN"))
        return
    if tag == EXPR_CORRELATED_SUBQUERY:
        writer.write(String("EXPR_CORRELATED_SUBQUERY"))
        return
    if tag == EXPR_REGEXP:
        writer.write(String("EXPR_REGEXP"))
        return
    if tag == EXPR_STRUCT_FIELD:
        writer.write(String("EXPR_STRUCT_FIELD"))
        return
    if tag == EXPR_STRUCT_FIELD_IDX:
        writer.write(String("EXPR_STRUCT_FIELD_IDX"))
        return
    if tag == EXPR_MAP_GET:
        writer.write(String("EXPR_MAP_GET"))
        return
    if tag == EXPR_JSON_EXTRACT:
        writer.write(String("EXPR_JSON_EXTRACT"))
        return
    if tag == EXPR_EXTRACT:
        writer.write(String("EXPR_EXTRACT"))
        return
    if tag == EXPR_MATH_FN:
        writer.write(String("EXPR_MATH_FN"))
        return
    if tag == EXPR_MATH_FN2:
        writer.write(String("EXPR_MATH_FN2"))
        return
    if tag == EXPR_SUBSTRING:
        writer.write(String("EXPR_SUBSTRING"))
        return
    if tag == EXPR_STRING_FN:
        writer.write(String("EXPR_STRING_FN"))
        return
    if tag == EXPR_UDF_CALL:
        writer.write(String("EXPR_UDF_CALL"))
        return
    if tag == EXPR_STRING_FN_N:
        writer.write(String("EXPR_STRING_FN_N"))
        return
    writer.write(String("tag#") + String(Int(tag)))
    return


def expr_tag_name(tag: UInt8) -> String:
    """Human name for an `EXPR_*` tag id.

    An id with no arm renders as `tag#<n>` rather than being dropped or silently
    aliased onto a neighbour, so a tag added without being named here is VISIBLE
    wherever it is printed.
    """
    var out = String()
    _write_expr_tag_name(out, tag)
    return out^


# Unary math-fn op codes (EXPR_MATH_FN).
#
# ★ EVERY MEMBER OF THIS FAMILY EMITS FLOAT64, WHATEVER ITS INPUT — that is the
# tag's contract, and it is what makes the block below FREE. MEASURED against
# DuckDB v1.5.3 (`typeof(ceil(BIGINT))`, one statement per name): all 20 return
# DOUBLE, over BIGINT input as well as over DOUBLE. So a name added here matches
# DuckDB cell for cell at zero structural cost.
#
# ⛔ `abs` / `round` / `sign` MAY NEVER JOIN THIS TAG. MEASURED on the same
# v1.5.3: `abs(BIGINT)` -> BIGINT, `round(BIGINT)` -> BIGINT, `sign(*)` ->
# TINYINT. They PRESERVE (or narrow) the input type, and routing them through
# an always-FLOAT64 variant would be a SILENT type divergence — a column that
# answers the right number under the wrong type, which the value half of a
# parity sweep cannot see. They need type-aware output, i.e. a different tag.
comptime MATH_SIN: UInt8 = 0
comptime MATH_COS: UInt8 = 1
comptime MATH_SQRT: UInt8 = 2
comptime MATH_ASIN: UInt8 = 3
comptime MATH_RADIANS: UInt8 = 4
# The DOUBLE-returning free riders. Each is one
# libm call in `scalar_math.eval_math_unary`; none needs a new payload, a new
# wire arm or a new walker arm, because they ride the tag that already has them.
comptime MATH_CEIL: UInt8 = 5
comptime MATH_FLOOR: UInt8 = 6
comptime MATH_LN: UInt8 = 7
comptime MATH_EXP: UInt8 = 8
comptime MATH_LOG10: UInt8 = 9
comptime MATH_LOG2: UInt8 = 10
comptime MATH_TAN: UInt8 = 11
comptime MATH_ATAN: UInt8 = 12
comptime MATH_ACOS: UInt8 = 13
comptime MATH_COT: UInt8 = 14
comptime MATH_DEGREES: UInt8 = 15
comptime MATH_CBRT: UInt8 = 16
comptime MATH_SINH: UInt8 = 17
comptime MATH_COSH: UInt8 = 18
comptime MATH_TANH: UInt8 = 19
# The INVERSE HYPERBOLICS and the GAMMA
# function. Same free-rider shape as the fifteen above: one libm call each in
# `scalar_math._apply_unary`, no new payload, no new walker arm.
#
# ⚠ EVERY ONE OF THESE HAS EXACTLY ONE OVERLOAD IN DuckDB v1.5.3 —
# `DOUBLE(DOUBLE)` — so the always-FLOAT64 contract of this tag is an EXACT
# match and there is no output-type divergence to state. That is NOT true of
# `ceil`/`floor` (DECIMAL and FLOAT preserving there) and it is why those two
# carry a stated exception and these four do not.
#
# ⛔ `lgamma` IS DELIBERATELY NOT HERE, AND THE BLOCKER IS THE ORACLE — THE
# KERNEL WOULD BE CORRECT. MEASURED, three values for one input:
#     DuckDB v1.5.3   lgamma(5.0) = 3.1780538303479453
#     libm (dlsym)    lgamma(5.0) = 3.1780538303479453   <- identical
#     CPython 3.12    math.lgamma(5.0) = 3.1780538303479444
#     log(gamma(5.0))                  = 3.1780538303479458
# DuckDB calls libm, so an `external_call["lgamma"]` kernel here would match it
# EXACTLY. CPython is the outlier: it implements lgamma itself (a Lanczos
# series in `mathmodule.c`) rather than calling libm. Every other name in this
# space was validated digit-for-digit against CPython, and the plan-matrix
# cells take their expected values from Python — so landing `lgamma` on that
# instrument puts a 2-ulp red into a value-compared cell that is NOT a bug in
# the kernel and cannot be closed by fixing one. It needs a DuckDB-derived
# oracle first, which is a decision about the instrument, not about this op.
# `gamma` has no such problem: `gamma(5.0)` = 24.0 in DuckDB, libm and CPython
# alike, exactly.
comptime MATH_ACOSH: UInt8 = 20
comptime MATH_ASINH: UInt8 = 21
comptime MATH_ATANH: UInt8 = 22
comptime MATH_GAMMA: UInt8 = 23

# Binary math-fn op codes (EXPR_MATH_FN2).
comptime MATH2_ATAN2: UInt8 = 0
# `pow(base, exponent)` / `power(base, exponent)`.
# Backs e.g. `pow(corr(v1, v2), 2)`. Both children eval to numeric
# Columns (the eval arm casts to FLOAT64); output is FLOAT64. Implemented via
# libm `pow` (handles a negative base with an integer-valued exponent, e.g.
# `pow(corr, 2)` for a negative correlation) in `scalar_math.eval_math_binary`.
comptime MATH2_POW: UInt8 = 1

# Field-extract units.
comptime EXTRACT_YEAR: UInt8 = 0
comptime EXTRACT_QUARTER: UInt8 = 1
comptime EXTRACT_MONTH: UInt8 = 2
comptime EXTRACT_DAY: UInt8 = 3
comptime EXTRACT_HOUR: UInt8 = 4
comptime EXTRACT_MINUTE: UInt8 = 5
comptime EXTRACT_SECOND: UInt8 = 6

# -- the DAY-INDEX family ------------
#
# ⚠ THESE MUST STAY BELOW 16 AND THE REASON IS `_is_trunc_unit`, NOT TIDINESS.
# The whole engine discriminates "field extract" from "date_trunc" with the
# single predicate `unit >= EXTRACT_TRUNC_YEAR` below — one function, delegated
# by `expr_walk` (and by the column evaluator and the row-mode walkers, which
# are not in this tree) rather than restated (see `expr_walk.mojo`'s EXTRACT
# arm, which says so). A new FIELD unit numbered above 25 would be typed as a
# date_trunc by every one of them: DECLARED as the child's temporal type over an
# INT64 buffer. The 7..15 run was left free for exactly this, and 15 is
# deliberately still free — `test_an_extract_unit_in_the_sparse_hole_is_refused`
# needs a value BETWEEN the two declared runs, because a codec that
# RANGE-CHECKED instead of consulting the vocabulary would accept it.
#
# ⚠ THE FIELD RUN IS 0..14 AND **15 IS THE ONLY HOLE LEFT**.
# The next temporal field unit (`era` / `decade` / `century` / `millennium`
# / `epoch` / `julian` / `nanosecond` / `timezone_hour` / `timezone_minute`
# are all real DuckDB parts with no unit here) cannot simply take 16+:
# that is the truncation run and `_is_trunc_unit` is an OPEN-ENDED `>= 16`.
# Extending the field family past 15 means turning that predicate into a
# BOUNDED range (`16..25`) first — one edit, in one place, because every
# consumer delegates to it — and then the hole test has to move above the
# whole space, where it stops discriminating a range check from a
# vocabulary lookup. That is a decision, not a mechanical step.
#
# ⚠ EVERY MEMBER RETURNS BIGINT AND NONE OF THEM IS A "SMALL" INT. Measured on
# DuckDB v1.5.3: `typeof(dayofweek(DATE '2026-09-13'))` = BIGINT. `walk_expr_field`
# types the whole non-trunc family INT64 in one line, so a new field unit needs
# no type arm — which is only true while every member IS an INT64.
#
# ⛔ `dayofweek` AND `isodow` ARE TWO UNITS, NOT ONE WITH AN OFFSET, AND SUNDAY
# IS THE ONLY WITNESS. MEASURED v1.5.3: `dayofweek` is Sunday=**0**, Monday=1 …
# Saturday=6; `isodow` is Monday=1 … Sunday=**7**. On Monday..Saturday the two
# answer the IDENTICAL number, so a fixture with no Sunday row scores green
# under either mapping and under "isodow = dayofweek" as well.
comptime EXTRACT_DAYOFWEEK: UInt8 = 7
comptime EXTRACT_ISODOW: UInt8 = 8
comptime EXTRACT_DAYOFYEAR: UInt8 = 9

# -- the ISO WEEK-DATE family --------
#
# ⛔ `EXTRACT_ISOYEAR` IS NOT `EXTRACT_YEAR` AND THE TWO DISAGREE ON UP TO
# THREE DAYS AT EACH END OF EVERY YEAR: `year(DATE '2027-01-01')` = 2027
# while `isoyear(DATE '2027-01-01')` = **2026** (that Friday belongs to ISO
# week 53 of 2026), and `year(DATE '2029-12-31')` = 2029 while `isoyear` =
# **2030**. 99% of days agree, which is what makes an alias survive every
# fixture that is not authored to break it.
#
# ⛔ AND `EXTRACT_WEEK` IS THE **ISO** WEEK, NOT `dayofyear / 7`. `week(DATE
# '2027-01-01')` = 53, not 1 — the week number belongs to the ISO year, so it
# can exceed anything a day-of-year division produces and can be 52 or 53 on a
# January date.
comptime EXTRACT_WEEK: UInt8 = 10
comptime EXTRACT_ISOYEAR: UInt8 = 11
comptime EXTRACT_YEARWEEK: UInt8 = 12

# -- the SUB-SECOND family ----------
#
# ⛔⛔ THESE ARE NOT "THE FRACTIONAL PART". THE SECONDS ARE FOLDED IN.
# MEASURED v1.5.3 on `TIMESTAMP '2026-09-13 13:45:30.123456'`:
#     second(ts)      = 30
#     millisecond(ts) = 30123        <- 30 * 1000     + 123
#     microsecond(ts) = 30123456     <- 30 * 1000000  + 123456
# Mapping either onto the fraction alone gives 123 / 123456 — wrong by three
# and six orders of magnitude respectively, with the right type and a
# plausible-looking value — and that mapping is the obvious one.
#
# ⇒ The whole computation is `floor_mod(ticks, 60 * ticks_per_second)` scaled
# to microseconds: the residue of the tick count modulo ONE MINUTE already IS
# "seconds and fraction", so there is no second-plus-fraction recomposition to
# get wrong.
comptime EXTRACT_MILLISECOND: UInt8 = 13
comptime EXTRACT_MICROSECOND: UInt8 = 14

# date_trunc units.  Encoded in a separate sub-range so the eval-arm
# can branch on (unit >= EXTRACT_TRUNC_YEAR) for the trunc family.
comptime EXTRACT_TRUNC_YEAR: UInt8 = 16
comptime EXTRACT_TRUNC_QUARTER: UInt8 = 17
comptime EXTRACT_TRUNC_MONTH: UInt8 = 18
comptime EXTRACT_TRUNC_WEEK: UInt8 = 19
comptime EXTRACT_TRUNC_DAY: UInt8 = 20
comptime EXTRACT_TRUNC_HOUR: UInt8 = 21
comptime EXTRACT_TRUNC_MINUTE: UInt8 = 22
comptime EXTRACT_TRUNC_SECOND: UInt8 = 23
comptime EXTRACT_TRUNC_MILLISECOND: UInt8 = 24
comptime EXTRACT_TRUNC_MICROSECOND: UInt8 = 25

@always_inline
def _is_trunc_unit(unit: UInt8) -> Bool:
    """True if `unit` is an EXTRACT_TRUNC_* (date_trunc family)."""
    return unit >= EXTRACT_TRUNC_YEAR


comptime REGEXP_LIKE: UInt8 = 0           # Bool — `regexp_like` / `regexp_matches` / `~`
comptime REGEXP_MATCH: UInt8 = 1          # List<Utf8> — `regexp_match`
comptime REGEXP_REPLACE: UInt8 = 2        # Utf8 — `regexp_replace`
comptime REGEXP_EXTRACT: UInt8 = 3        # Utf8 — `regexp_extract`
comptime REGEXP_SPLIT_TO_ARRAY: UInt8 = 4 # List<Utf8> — `regexp_split_to_array`
comptime REGEXP_EXTRACT_ALL: UInt8 = 5    # List<Utf8> — `regexp_extract_all`
comptime REGEXP_COUNT: UInt8 = 6          # Int64 — `regexp_count` (PG semantics)
comptime REGEXP_INSTR: UInt8 = 7          # Int64 — `regexp_instr` (PG semantics; 1-based byte pos, 0 = none)
comptime REGEXP_SUBSTR: UInt8 = 8         # Utf8 — `regexp_substr` (PG/Oracle; NULL on no match)
comptime REGEXP_FULL_MATCH: UInt8 = 9     # Bool — `regexp_full_match` (anchored \A(?:...)\z — DuckDB)


# =============================================================================
# BinOp constants
# =============================================================================

# Arithmetic
comptime BIN_ADD: UInt8 = 0
comptime BIN_SUB: UInt8 = 1
comptime BIN_MUL: UInt8 = 2
comptime BIN_DIV: UInt8 = 3
comptime BIN_MOD: UInt8 = 4

# Comparison
comptime BIN_EQ: UInt8 = 10
comptime BIN_NE: UInt8 = 11
comptime BIN_LT: UInt8 = 12
comptime BIN_LE: UInt8 = 13
comptime BIN_GT: UInt8 = 14
comptime BIN_GE: UInt8 = 15

# Logical
comptime BIN_AND: UInt8 = 20
comptime BIN_OR: UInt8 = 21


# =============================================================================
# UnOp constants
# =============================================================================

comptime UN_NOT: UInt8 = 0
comptime UN_NEGATE: UInt8 = 1
comptime UN_IS_NULL: UInt8 = 2
comptime UN_IS_NOT_NULL: UInt8 = 3

# -----------------------------------------------------------------------------
# ★ THE TYPE-PRESERVING NUMERIC MEMBERS.
# -----------------------------------------------------------------------------
#
# ⭐ WHY THEY LIVE HERE AND NOT ON `EXPR_MATH_FN`, WHICH IS THE OBVIOUS HOME.
#
# `EXPR_MATH_FN` is **ALWAYS FLOAT64** — that is the tag's contract, stated on
# the tag and relied on by name: the engine's row-streaming classifier (not in
# this tree) returns `True` for the tag UNCONDITIONALLY, with the comment "the
# math fns ALWAYS produce FLOAT64, regardless of the child's family — so the
# project root picks the f64 walker family". A type-PRESERVING member on that
# tag is a silent type divergence waiting for the first person to give it a
# row-walker opcode.
#
# `EXPR_UNARY_OP`, by contrast, ALREADY carries the type-preserving unary
# numeric rule: `walk_expr_field`'s arm for this tag is PER-OP, and its
# `UN_NEGATE` leg recurses into the child's `Field` and returns the CHILD's
# `arrow_type`. `abs` / `trunc` / `round` need exactly that rule and nothing
# else; `sign` needs one more per-op leg in a ladder that is already per-op
# (UN_NOT / UN_IS_NULL are BOOL there while UN_NEGATE is the child's type).
#
# ⛔ AND THE ROUTE THAT LOOKS FREE AND IS NOT: `abs(x)` desugared to
# `CASE WHEN x < 0 THEN -x ELSE x END` in the binder. The TYPE reasoning is
# correct (EXPR_WHEN takes its dtype from the ELSE arm; UN_NEGATE preserves),
# and it has TWO silent wrong answers, both measured against DuckDB v1.5.3:
#   * `abs(-0.0)` -> the desugar answers `-0.0` (because `-0.0 < 0` is FALSE),
#     DuckDB answers `+0.0`. Invisible to `=`, since `-0.0 == 0.0`; visible as
#     `1/abs(-0.0)` = `-inf` vs DuckDB's `inf`.
#   * `abs(INT64_MIN)` -> the desugar computes `-INT64_MIN`, which WRAPS to a
#     NEGATIVE absolute value. DuckDB RAISES `Out of Range Error: Overflow on
#     abs(-9223372036854775808)`.
# Both are why these are real kernels with a real overflow guard.
#
# ⚠ THE UN_* SPACE FAILS SAFE ON AN UNKNOWN MEMBER, and that was MEASURED
# rather than assumed, over a tree that also held the engine, the plan compiler
# and the optimizer's expression rules — every non-test module there that read
# a `UN_*` was an ALLOWLIST. Of those, `viewport_expr_codec._is_allowed_unop`
# and both display ladders are in this tree; the row-capability and
# row-streaming walkers, the engine's unary translation, the optimizer's
# template matcher and selectivity estimate, and the SDK's leaf and lowering
# checks are not. An unknown member is an honest
# column demote or a named raise, never a wrong answer. That is the property
# `BIN_CONCAT` could NOT have had on the `BIN_*` space, and it is why the same
# reasoning does not generalise to that space.

comptime UN_ABS: UInt8 = 4
"""`abs(x)` — TYPE-PRESERVING absolute value. INT32 -> INT32, INT64 -> INT64,
FLOAT64 -> FLOAT64 (the three widths the projection arithmetic ladder carries,
the same set `UN_NEGATE` serves). NULL in -> NULL out.

DuckDB v1.5.3, measured: `abs(-0.0)` is `+0.0` (`1/abs(-0.0)` =
`inf`), `abs(-inf)` is `inf`, `abs(nan)` is `nan`, and `abs(INT64_MIN)` RAISES
`Out of Range Error`. The kernel reproduces all four."""

comptime UN_SIGN: UInt8 = 5
"""`sign(x)` — the ONE member of this family whose output type is FIXED rather
than preserved: **INT8 (DuckDB TINYINT) for every numeric input**, measured
from `duckdb_functions()` on v1.5.3 (all twelve overloads return TINYINT).

`sign(-0.0)` is `0` and `sign(nan)` is `0`, both measured — so the kernel
cannot be `copysign`-shaped and cannot be a bare `x < 0 ? -1 : 1`."""

comptime UN_TRUNC: UInt8 = 6
"""`trunc(x)` — round toward ZERO, TYPE-PRESERVING. An INTEGER input is
returned unchanged (DuckDB: `trunc(BIGINT) -> BIGINT`), a FLOAT64 goes through
C `trunc`. `trunc(-0.5)` is `-0` in DuckDB v1.5.3 (measured) — negative zero is
PRESERVED, which `Float64(Int(x))` would destroy."""

comptime UN_ROUND: UInt8 = 7
"""`round(x)` — round HALF AWAY FROM ZERO, TYPE-PRESERVING. Measured on
v1.5.3: `round(0.5)`=1, `round(1.5)`=2, `round(2.5)`=3, `round(-2.5)`=-3 — so
it is C `round`, NOT banker's rounding and NOT `nearbyint`. An INTEGER input is
returned unchanged (`round(BIGINT) -> BIGINT`).

⚠ ONE-ARGUMENT ONLY. DuckDB also has `round(x, digits)`; this node is unary and
cannot carry the second operand, so the SQL table refuses the 2-arg form BY
NAME rather than silently rounding to zero digits."""

comptime UN_BIT_COUNT: UInt8 = 8
"""`bit_count(x)` — POPCOUNT over a SIGNED INTEGER operand. **INT8 (DuckDB
TINYINT) out, whatever the operand's width** — the second member of this
space whose output type is FIXED rather than preserved, and it takes that
rule from `UN_SIGN` rather than inventing one.

MEASURED on DuckDB v1.5.3, off `duckdb_functions()` and the CLI:
five integer overloads (TINYINT / SMALLINT / INTEGER / BIGINT / HUGEINT) plus
one over BIT, and EVERY integer overload returns TINYINT.

⛔ THE ANSWER DEPENDS ON THE OPERAND'S DECLARED WIDTH, WHICH IS WHY THIS IS
NOT A WIDTH-AGNOSTIC KERNEL: `bit_count((-1)::TINYINT)` = 8,
`bit_count((-1)::SMALLINT)` = 16, `bit_count((-1)::INTEGER)` = 32 and
`bit_count((-1)::BIGINT)` = 64. A kernel that widened to INT64 first would
answer 64 for all four — a plausible wrong answer on every negative value,
invisible on every non-negative one.

⛔ AND THERE IS **NO FLOATING OVERLOAD**. `SELECT bit_count(1.5)` is a BINDER
ERROR on v1.5.3 (measured), so a FLOAT32 / FLOAT64 operand here RAISES in the
eval arm rather than being cast to an integer first. Casting would answer a
number for an expression DuckDB refuses to run at all.

⚠ NOT SERVED OVER BIT: this engine has no BIT type, and the BIT overload is
the ONE whose return type is BIGINT rather than TINYINT — so the day a BIT
array lands, this node's fixed INT8 output rule does NOT extend to it."""


# =============================================================================
# StringOp constants
# =============================================================================

comptime STR_CONTAINS: UInt8 = 0
comptime STR_STARTS_WITH: UInt8 = 1
comptime STR_ENDS_WITH: UInt8 = 2
comptime STR_LIKE: UInt8 = 3


# =============================================================================
# StringFn constants (EXPR_STRING_FN)
# =============================================================================
#
# The UNARY scalar string functions. One op per DuckDB name; the DuckDB
# semantics each one is pinned to is stated on its line, because "upper" is not
# one behaviour — `upper` over non-ASCII is a Unicode case mapping and over
# ASCII it is a byte flip. That is why each line below states its semantics
# instead of trusting the name.

comptime STRFN_UPPER: UInt8 = 0
"""`upper(s)` — Unicode simple case mapping, Utf8 -> Utf8. NULL in -> NULL out.

⭐ EXACT AGAINST DuckDB v1.5.3 ON EVERY CODEPOINT. The table
in `komira_column_kernels/unicode_case_table.mojo` is generated by asking DuckDB
itself for `upper(chr(cp))` over all 1,112,064 legal codepoints, so this is
parity by construction rather than by a spot check.

⚠ SIMPLE (1:1) MAPPING, NOT FULL CASE FOLDING — measured, not assumed, and the
distinction is visible: `upper('straße')` is `'STRAẞE'` (U+1E9E), NOT
`'STRASSE'`. Python's `str.upper()` gives the latter and is the wrong oracle.

⚠ AN ASCII-ONLY KERNEL FAILS SILENTLY: `upper` of `'Ünïcodé'` would return
`'ÜNïCODé'` — right length, valid UTF-8, no error, and correct on every
all-ASCII fixture. A test suite with no non-ASCII string cannot see it.
"""

comptime STRFN_LOWER: UInt8 = 1
"""`lower(s)` — Unicode simple case mapping, Utf8 -> Utf8. NULL in -> NULL out.

⭐ EXACT AGAINST DuckDB v1.5.3 ON EVERY CODEPOINT, from the same generated
table as `STRFN_UPPER`.

⛔ NEITHER DIRECTION IS THE OTHER'S INVERSE, AND CALLERS GET THIS WRONG.
MEASURED: `lower('İ')` is `'i'` (U+0130 -> U+0069) and `upper('ı')` is `'I'`
(U+0131 -> U+0049), so `upper(lower('İ'))` is `'I'` and not `'İ'`. Do not build
a case-insensitive comparison that assumes a round trip; fold ONE side.

⚠ AND THE OUTPUT IS NOT THE INPUT'S LENGTH IN EITHER DIRECTION: `upper('ß')`
grows 2 bytes to 3, `upper('ı')` shrinks 2 bytes to 1.
"""

comptime STRFN_TRIM: UInt8 = 2
"""`trim(s)` — strip leading AND trailing SPACE (0x20). Utf8 -> Utf8.

⛔ SPACE ONLY — NOT "whitespace". MEASURED against DuckDB v1.5.3, which is
where the trap is: `trim(e'\t  hi  \t')` comes back with BOTH TABS STILL
ON IT, and `trim(e'\n hi \n')` keeps its newlines. DuckDB's one-argument
`trim` removes the space character and nothing else; a kernel written against
an `isspace()` intuition would strip tabs and newlines too and disagree with
DuckDB on every value that has one. `trim(s, chars)` — the two-argument form
with an explicit strip set — is a DIFFERENT function and is not this op.
"""

comptime STRFN_LTRIM: UInt8 = 3
"""`ltrim(s)` — strip LEADING spaces only. Same space-not-whitespace rule as
`STRFN_TRIM`; MEASURED `ltrim('  hi  ')` = `'hi  '`."""

comptime STRFN_RTRIM: UInt8 = 4
"""`rtrim(s)` — strip TRAILING spaces only. MEASURED `rtrim('  hi  ')` =
`'  hi'`."""

comptime STRFN_LENGTH: UInt8 = 5
"""`length(s)` — the CHARACTER count, Utf8 -> INT64. NULL in -> NULL out.

⛔ CHARACTERS, NOT BYTES, AND DuckDB HAS BOTH FUNCTIONS. MEASURED on v1.5.3:
`length('héllo')` = 5 while `strlen('héllo')` = 6, and `length('straße')` = 6.
`strlen` is the byte count and is a SEPARATE name this op is not. Counting
bytes here would be right for every ASCII test and wrong for the first
non-ASCII row — the exact shape of defect an ASCII-only corpus cannot see.

This one is EXACT against DuckDB, not a divergence: counting UTF-8 codepoints
needs no case table, only the continuation-byte rule (a codepoint's first byte
is any byte outside 0x80..0xBF).

⚠ THE ONLY INT64-RETURNING MEMBER OF THIS FAMILY today, which is what
`string_fn_returns_int` exists to answer. Every site that infers this tag's
output type must switch on the op, never on the tag.
"""

comptime STRFN_REVERSE: UInt8 = 6
"""`reverse(s)` — reverse the CHARACTER order, Utf8 -> Utf8.

⛔ CODEPOINTS, NOT BYTES. MEASURED on v1.5.3: `reverse('héllo')` = `olléh` —
the two bytes of `é` come back in their ORIGINAL order, in a new position.
A byte-wise reverse would emit the continuation byte first and produce
INVALID UTF-8 out of a valid input, which is worse than a wrong answer
because a downstream consumer cannot even decode it.

EXACT against DuckDB for the same reason as `STRFN_LENGTH`: no case table is
involved, only codepoint boundaries.
"""

# The STRING -> INT bucket. Four members that
# are INT64-returning, joining `STRFN_LENGTH` and TRIPLING the size of the
# minority arm `string_fn_returns_int` exists to serve.
#
# ⛔⛔ THE THREE LENGTH-SHAPED NAMES ARE THREE DIFFERENT FUNCTIONS AND DuckDB
# SHIPS ALL THREE. MEASURED on v1.5.3 over `'héllo'` (5 characters, 6 bytes):
#     length('héllo')     = 5    CHARACTERS   -> STRFN_LENGTH
#     strlen('héllo')     = 6    BYTES        -> STRFN_STRLEN
#     bit_length('héllo') = 48   BYTES * 8    -> STRFN_BIT_LENGTH
# All three are right on every ASCII input and only diverge on the first
# non-ASCII row, which is exactly the defect shape an ASCII corpus cannot see.

comptime STRFN_ASCII: UInt8 = 7
"""`ascii(s)` — the CODEPOINT of the first character, Utf8 -> INT64.

⛔ IT IS A CODEPOINT, NOT A BYTE, DESPITE THE NAME. MEASURED on v1.5.3:
`ascii('é')` = 233 and `ascii('😀')` = 128512 — the whole scalar value, decoded
from however many UTF-8 bytes it occupies. Returning the first BYTE would give
195 and 240 respectively: plausible small integers, right for all of ASCII.

⚠ `ascii('')` IS 0, AND THAT IS THE ONLY THING SEPARATING IT FROM
`STRFN_UNICODE`. MEASURED: `ascii('')` = 0 while `unicode('')` = -1. On every
NON-empty input the two are the same number, which is why they are two ops and
not one op with two names — an alias would be correct on every test that does
not contain an empty string.
"""

comptime STRFN_UNICODE: UInt8 = 8
"""`unicode(s)` / `ord(s)` — the CODEPOINT of the first character, Utf8 ->
INT64, with **-1** for the empty string.

MEASURED on v1.5.3: `unicode('')` = `ord('')` = -1, and `unicode('é')` =
`ord('é')` = 233. `ord` IS a true alias of this one (both -1 on empty);
`ascii` is NOT (0 on empty) — see `STRFN_ASCII`.
"""

comptime STRFN_STRLEN: UInt8 = 9
"""`strlen(s)` — the BYTE count of the UTF-8 encoding, Utf8 -> INT64.

⛔ NOT AN ALIAS OF `length`. MEASURED: `strlen('héllo')` = 6, `length('héllo')`
= 5, `strlen('😀')` = 4, `length('😀')` = 1. Binding `strlen` to the
character count would be a silent wrong answer on non-ASCII input.
"""

comptime STRFN_BIT_LENGTH: UInt8 = 10
"""`bit_length(s)` — the byte count times eight, Utf8 -> INT64.

MEASURED on v1.5.3: `bit_length('héllo')` = 48, `bit_length('😀')` = 32,
`bit_length('')` = 0. It is exactly `8 * strlen(s)` for a VARCHAR.

⚠ `octet_length` IS NOT ITS COMPANION AND IS NOT BINDABLE HERE. It has NO
VARCHAR overload in v1.5.3 (only BIT and BLOB), so `octet_length('héllo')` is a
Binder Error THERE — `strlen` is the byte count for a string. ⛔ NOT an absent
function: the name resolves in DuckDB and `octet_length('abc'::BLOB)` = 3
(measured). A missing OVERLOAD, not a missing name.
"""


# -- the BYTE-TRANSFORM members ---------------
#
# ⭐ WHY THESE FIVE AND NOT THE REST OF THE STRING BUCKET. Every member above
# that touches CASE or character boundaries (`upper`, `lower`, `reverse`)
# carries a STATED Unicode divergence, because DuckDB runs utf8proc and this
# engine does not. These five are defined ON THE UTF-8 BYTES in DuckDB TOO, so
# they are EXACT rather than ASCII-faithful — there is no mapping to be
# missing. MEASURED v1.5.3: hex('é')='C3A9', bin('é')='1100001110101001',
# url_encode('é')='%C3%A9', regexp_escape('é.b')='é\.b'.

comptime STRFN_HEX: UInt8 = 11
"""`hex(s)` / `to_hex(s)` — two UPPERCASE hex digits per UTF-8 byte.

MEASURED v1.5.3: `hex('abc')` = '616263', `hex('')` = '', `hex('é')` = 'C3A9',
`hex('😀')` = 'F09F9880'. `to_hex` over a VARCHAR is byte-identical, which is
why the two names share this op.

⛔ THE INTEGER OVERLOADS ARE DIFFERENT FUNCTIONS AND ARE NOT THIS OP.
`to_hex(255)` = 'FF' in v1.5.3 while `hex('255')` = '323535'. This op reads a
STRING column; an integer argument is refused BY NAME at the eval arm.

⚠ UPPERCASE, and that is not a shared convention: `md5`/`sha256` emit LOWERCASE
hex in the same engine.
"""

comptime STRFN_BIN: UInt8 = 12
"""`bin(s)` — EIGHT binary digits per UTF-8 byte, no separator.

MEASURED v1.5.3: `bin('abc')` = '011000010110001001100011' — 24 digits for 3
bytes, so the leading zero of `a` (0x61) is KEPT. `bin('')` = ''.

⛔ `bin` OVER AN INTEGER **DOES** STRIP LEADING ZEROS (`bin(5)` = '101') and is
a different overload this engine does not bind. A kernel that stripped would be
right for the integer form and wrong for every string.
"""

comptime STRFN_URL_ENCODE: UInt8 = 13
"""`url_encode(s)` — RFC 3986 percent-encoding with UPPERCASE hex digits.

MEASURED v1.5.3: `url_encode('a b/c?d=é')` = 'a%20b%2Fc%3Fd%3D%C3%A9'. The
unreserved set was derived by running every printable ASCII byte through it and
keeping what came back unchanged: EXACTLY `-.0-9A-Z_a-z~`.

⛔ A SPACE IS `%20`, NEVER `+`, AND `+` IS ITSELF ENCODED (`url_encode('a+b')` =
'a%2Bb'). This is URI encoding, not form encoding.
"""

comptime STRFN_URL_DECODE: UInt8 = 14
"""`url_decode(s)` — decode `%XX`, leave everything else verbatim.

⛔ THREE MEASURED FACTS, EACH THE OPPOSITE OF THE OBVIOUS GUESS (v1.5.3):
  * `url_decode('a+b')` = 'a+b'. `+` IS NOT A SPACE here.
  * A MALFORMED ESCAPE IS LEFT ALONE, not an error: `url_decode('a%zz')` =
    'a%zz', `url_decode('a%2')` = 'a%2', `url_decode('100%')` = '100%'.
  * AN ESCAPE THAT DECODES TO INVALID UTF-8 **RAISES**: `url_decode('%FF')` is
    an `Invalid Input Error` there, and it raises here too. Emitting the bytes
    would put an invalid-UTF-8 value in a STRING column, which the Arrow C-ABI
    export is entitled to reject — a corruption, not a divergence.
Lowercase escapes ARE accepted: `url_decode('%c3%a9')` = 'é'.
"""

comptime STRFN_REGEXP_ESCAPE: UInt8 = 15
"""`regexp_escape(s)` — RE2's `QuoteMeta`.

⚠ THE RULE IS "ESCAPE EVERYTHING THAT IS NOT `[A-Za-z0-9_]`", NOT "escape the
metacharacters", and it was MEASURED: running bytes 1..127 through v1.5.3's
`regexp_escape` puts a backslash in front of ALL of them except the
alphanumerics and `_` — including space, `/`, `:`, `@`, `-` and the C0
controls, none of which is a regex metacharacter. A hand-written metacharacter
list is a strict subset and leaves, e.g., `-` unescaped inside a character
class the caller then builds.

⚠ BYTES >= 0x80 ARE LEFT VERBATIM: `regexp_escape('é.b')` = 'é\\.b'
(one backslash, doubled here because this is a docstring).

⛔ IT IS A `STRFN_*`, NOT A `REGEXP_*`. It compiles no pattern and reads no
`RegexpData`; it is an ordinary unary string transform that happens to be named
after the family its output is meant for.
"""



comptime STRFN_MD5: UInt8 = 16
"""`md5(s)` — RFC 1321, LOWERCASE hex of the digest of the UTF-8 BYTES.

MEASURED v1.5.3 over a COLUMN: `md5('abc')` =
'900150983cd24fb0d6963f7d28e17f72' (RFC 1321 §A.5), `md5('')` =
'd41d8cd98f00b204e9800998ecf8427e', `md5('é')` =
'66ddcd97cfdeabb2f6fb8a999b4bc76f'.

⛔ THE DIGEST IS OVER BYTES, NOT CODEPOINTS, AND `é` IS THE WITNESS: the value
above is the digest of the two bytes C3 A9. A codepoint-wise kernel agrees on
every ASCII fixture and diverges on the first accented character.

⛔ LOWERCASE — unlike `STRFN_HEX` on this same tag, which is UPPERCASE.

⛔ `md5_number`, `md5_number_lower` and `md5_number_upper` are DIFFERENT DuckDB
functions returning HUGEINT/UBIGINT, not this one. They are refused rows: this
engine has no int128 column."""

comptime STRFN_SHA1: UInt8 = 17
"""`sha1(s)` — RFC 3174, LOWERCASE hex, 40 characters.

MEASURED v1.5.3 over a COLUMN: `sha1('abc')` =
'a9993e364706816aba3e25717850c26c9cd0d89d' (RFC 3174), `sha1('')` =
'da39a3ee5e6b4b0d3255bfef95601890afd80709'.

⚠ 40 CHARACTERS, where `md5` is 32 and `sha256` is 64. The three widths differ
on purpose in the tests: a width assertion is the cheapest witness that the
eval ladder dispatched to the op it was handed."""

comptime STRFN_SHA256: UInt8 = 18
"""`sha256(s)` — FIPS 180-2, LOWERCASE hex, 64 characters.

MEASURED v1.5.3 over a COLUMN: `sha256('abc')` =
'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' (FIPS 180-2
§B.1), `sha256('')` =
'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'.

⭐ ITS KERNEL IS A SECOND SHA-256 IN THIS REPO AND THAT IS DELIBERATE.
`komira_crypto.sha256` is an AWS-LC FFI wrapper, and its package declares the
CAVP suites and bettertls as gating tests that the plan compiler (not in this
tree) would inherit transitively — on every engine build, for one scalar
function. The
reasoning is recorded in `komira_column_kernels/digest_functions.mojo`; do not
"fix" the duplication by adding the dependency edge.

⛔ DuckDB HAS NO `sha512` OR `sha384` (measured: the digest family on v1.5.3 is
exactly `md5 md5_number md5_number_lower md5_number_upper sha1 sha256 hash`),
so there is no third width to add and no refusal row to write for one."""

# =============================================================================
# StringFnN constants (EXPR_STRING_FN_N)
# =============================================================================
#
# The MULTI-ARGUMENT scalar string functions. One op per DuckDB behaviour; the
# semantics each is pinned to were MEASURED against the DuckDB v1.5.3 CLI, not
# read off the docs page (which can disagree with itself).
#
# ⛔ READ THE NULL RULE ON EVERY LINE. It is NOT uniform across this family,
# and that is the single most expensive thing to guess: `concat` IGNORES nulls
# where every other member propagates them, and `concat_ws` propagates a null
# SEPARATOR while ignoring null ARGUMENTS. Three different rules, one tag.

comptime STRFNN_CONCAT: UInt8 = 0
"""`concat(a, b, ...)` — VARIADIC, Utf8 -> Utf8. n >= 1.

⛔ NULL ARGUMENTS ARE SKIPPED, NOT PROPAGATED, AND THE RESULT IS NEVER NULL.
MEASURED: `concat('a',NULL,'c')` = `'ac'` and `concat(NULL,NULL)` = `''` — the
EMPTY STRING, not NULL. This is the opposite of what a reader who knows SQL's
`||` expects, and DuckDB itself differs on that very pair (`'a'||NULL` IS
NULL there). ⚠ THIS ENGINE HAS NO `||` AT ALL — no token, no binary op, no
function — so there is nothing here for the two behaviours to be confused
between; if `||` is ever added it is a PARSER change and it does NOT get to
reuse this op.

⚠ DuckDB's `concat` takes ANY and stringifies (`concat(1,'a',2.5)` =
`'1a2.5'`). This op requires every argument to evaluate to a STRING /
DICTIONARY column and refuses anything else BY NAME; the binder inserts no
implicit cast. That is a STATED NARROWING — a wrong-type argument raises where
DuckDB would coerce, which is a refusal and never a wrong value.
"""

comptime STRFNN_CONCAT_WS: UInt8 = 1
"""`concat_ws(sep, a, b, ...)` — VARIADIC, args[0] is the SEPARATOR. n >= 2.

⚠ TWO DIFFERENT NULL RULES IN ONE FUNCTION, and both are MEASURED:
  * a NULL SEPARATOR makes the whole result NULL — `concat_ws(NULL,'a','b')`
    is NULL;
  * a NULL VALUE is SKIPPED, separator and all — `concat_ws('-','a',NULL,'c')`
    = `'a-c'` (ONE dash, not two), and `concat_ws('-',NULL,'a')` = `'a'` with
    no leading dash.

The separator is emitted BETWEEN surviving values only, so the count of
separators is `max(0, surviving - 1)` and is not derivable from the argument
count.
"""

comptime STRFNN_REPLACE: UInt8 = 2
"""`replace(s, source, target)` — EXACTLY 3 args, Utf8 -> Utf8.

NULL in ANY position -> NULL out (measured, all three).

⚠ NON-OVERLAPPING LEFT-TO-RIGHT SCAN, which is observable:
`replace('aaa','aa','b')` = `'ba'`, not `'b'` and not `'bb'` — the match
consumes its own bytes and the scan resumes AFTER them.

⚠ AN EMPTY `source` MATCHES NOTHING: `replace('abc','','X')` = `'abc'`. A
naive "insert at every position" reading of the empty needle produces
`'XaXbXcX'` and is what an unguarded loop writes.

BYTE-WISE, and that is CORRECT here rather than a divergence: UTF-8 is
self-synchronising, so a byte-substring search can only match at a codepoint
boundary when the needle is itself valid UTF-8. MEASURED: `replace('Straße',
'ß','ss')` = `'Strasse'`.
"""

comptime STRFNN_LPAD: UInt8 = 3
"""`lpad(s, n, pad)` — EXACTLY 3 args, Utf8 -> Utf8. NULL in any -> NULL out.

⛔ CHARACTERS, NOT BYTES, IN EVERY DIRECTION. MEASURED: `lpad('é',4,'ß')` =
`'ßßßé'` — four CHARACTERS out of a two-byte input and a two-byte pad. A
byte-wise implementation returns a different string AND can split a codepoint,
producing invalid UTF-8 out of valid input.

⚠ IT ALSO TRUNCATES. `n` shorter than the input is not a no-op:
`lpad('abc',2,'x')` = `'ab'` — the FIRST n characters, i.e. `left(s, n)`. And
`n <= 0` gives `''` (measured at `n = 0` and `n = -1`).

⛔⛔ AN EMPTY `pad` RAISES — `Invalid Input Error: Insufficient padding in
LPAD.` — IT DOES NOT PASS THE STRING THROUGH. ⚠ AND THE RAISE IS CONDITIONAL,
which is the part that is easy to get wrong in both directions: it fires only
when padding is actually NEEDED. MEASURED, all four corners:
  lpad('abc',4,'')  RAISES        (needs 1 char, has no source for it)
  lpad('abc',3,'')  = 'abc'       (needs none)
  lpad('abc',2,'')  = 'ab'        (truncating, needs none)
  lpad('',0,'')     = ''          (needs none)
So the guard is `target > char_len(s) and len(pad) == 0`, never `len(pad) == 0`
alone.
"""

comptime STRFNN_RPAD: UInt8 = 4
"""`rpad(s, n, pad)` — the right-hand twin of `STRFNN_LPAD`, EXACTLY 3 args.

Same character semantics, same truncation-to-first-n rule (`rpad('abc',2,'x')`
= `'ab'` — the FIRST two, NOT the last two), same conditional raise with
`RPAD` in the message instead of `LPAD`. MEASURED: `rpad('Straße',8,'ß')` =
`'Straßeßß'`.
"""

comptime STRFNN_REPEAT: UInt8 = 5
"""`repeat(s, n)` — EXACTLY 2 args, Utf8 -> Utf8. NULL in either -> NULL out.

`n <= 0` gives `''` (measured at 0 and -1); `repeat('',5)` = `''`.

⚠ THE ONE MEMBER THAT CAN ALLOCATE UNBOUNDEDLY FROM A SMALL PLAN. `n` is a
BIGINT in DuckDB and `repeat('ab', 2147483647)` really does try to build a 4 GB
value. The kernel here refuses a result longer than `STRFNN_REPEAT_MAX_BYTES`
BY NAME rather than attempting the allocation, because an OOM in a morsel
worker takes the process and a refusal takes one query.
"""

comptime STRFNN_STRPOS: UInt8 = 6
"""`strpos(haystack, needle)` — EXACTLY 2 args, Utf8 -> INT64. Aliases `instr`,
`position`.

⛔ THE ONLY INT64-RETURNING MEMBER OF THIS FAMILY — `string_fn_n_returns_int`
is what answers that, and every site inferring this tag's output type must
switch on the OP and never on the tag.

⛔ 1-BASED, AND `0` MEANS NOT FOUND — it is not an index, it is a POSITION.
MEASURED: `strpos('abcabc','c')` = 3 (the FIRST match), `strpos('abc','z')` =
0, `strpos('','a')` = 0.

⛔ CHARACTERS, NOT BYTES. MEASURED: `strpos('Straße','e')` = **6**, where a
byte offset would say 7, and `strpos('Straße','ße')` = 5. The search itself is
byte-wise (safe — see `STRFNN_REPLACE`); it is the RESULT that must be
converted to a character position.

⚠ AN EMPTY NEEDLE IS FOUND AT 1, INCLUDING IN AN EMPTY HAYSTACK:
`strpos('abc','')` = 1 and `strpos('','')` = 1. NULL in either -> NULL out.
"""

# The EDIT-DISTANCE family. Three ops, five
# SQL names, all Utf8 x Utf8 -> INT64.
#
# ⛔⛔ ALL THREE OPERATE ON **BYTES**, NOT CHARACTERS, AND THAT IS MEASURED
# AGAINST DuckDB v1.5.3 RATHER THAN CHOSEN FOR CONVENIENCE. It is the single
# most surprising fact about this family and every textbook writes it the
# other way:
#     levenshtein('é', '')   = 2   ('é' is 1 CHARACTER and 2 BYTES)
#     levenshtein('😀', '')  = 4   (1 character, 4 bytes)
#     levenshtein('😀', 'x') = 4   (a character version answers 1)
#     hamming('é', 'e')          RAISES "must be of equal length" — which is
#                                only true if the unit is the BYTE; both are
#                                one CHARACTER
# A character-based kernel is right on every ASCII input and wrong on the
# first row that is not, which is this repo's standing defect shape.

comptime STRFNN_TRANSLATE: UInt8 = 10
"""`translate(s, from, to)` — replace each CHARACTER of `s` found in `from`
with the character at the SAME POSITION in `to`. Exactly 3 arguments.

⛔⛔ IT IS CHARACTER-BASED, AND IT IS THE ONLY MEMBER OF THIS TAG THAT IS.
`levenshtein`, `damerau_levenshtein` and `hamming` are BYTE-based here (their
own docstrings say so and it is measured); `translate` is not. MEASURED on
DuckDB v1.5.3: `translate('héllo','é','e')` = 'hello' — the `é` is TWO UTF-8
bytes and is matched and replaced AS ONE UNIT. A byte-wise kernel would match
the lead byte C3 alone, emit `e` for it, and leave the trailing A9 stranded —
producing INVALID UTF-8, not merely a wrong answer.

⛔ A SHORTER `to` DELETES, IT DOES NOT PAD. MEASURED:
`translate('abcd','abc','xy')` = 'xyd' — the `c` has no partner at index 2 and
is DROPPED. `translate('abc','abc','')` = '' for the same reason.

⛔ A DUPLICATE IN `from` TAKES THE FIRST MAPPING. MEASURED:
`translate('abc','aa','xy')` = 'xbc', not 'ybc'.

⚠ A LONGER `to` IGNORES THE EXTRA (`translate('abc','a','xyz')` = 'xbc'), and
the pairing is per CODEPOINT on BOTH sides — `translate('Straße','ß','ss')` =
'Strase', where only the FIRST `s` of the two-character `to` is used.

NULL in any of the three arguments yields NULL (measured), which is the
"any null in, null out" rule this family's `replace` already has."""


comptime STRFNN_LEVENSHTEIN: UInt8 = 7
"""`levenshtein(a, b)` / `editdist3(a, b)` — EXACTLY 2 args, Utf8 -> INT64.

The classic insert/delete/substitute edit distance, over BYTES (see the block
above). MEASURED on v1.5.3: `levenshtein('kitten','sitting')` = 3,
`levenshtein('ca','abc')` = 3, `levenshtein('ab','ba')` = 2 (NO transposition
— that is what separates it from `STRFNN_DAMERAU_LEVENSHTEIN`),
`levenshtein('Straße','Strasse')` = 2.

⚠ EMPTY STRINGS ARE FINE AND ANSWER THE OTHER OPERAND'S LENGTH:
`levenshtein('','abc')` = 3, `levenshtein('abc','')` = 3, `levenshtein('','')`
= 0. `STRFNN_HAMMING` RAISES on the same input, which is why they are not one
kernel with a flag.

`editdist3` IS a true alias — measured identical on v1.5.3. NULL in either
-> NULL out.
"""

comptime STRFNN_DAMERAU_LEVENSHTEIN: UInt8 = 8
"""`damerau_levenshtein(a, b)` — EXACTLY 2 args, Utf8 -> INT64.

Edit distance WITH transposition of two adjacent symbols as a single edit.

⛔⛔ THE **UNRESTRICTED** DAMERAU-LEVENSHTEIN, NOT THE OPTIMAL STRING
ALIGNMENT (OSA) DISTANCE, AND THE TWO ARE DIFFERENT FUNCTIONS. Nearly every
"Damerau-Levenshtein" implementation on the internet is OSA — it is the one
that fits in a 2-row DP, and it forbids editing a substring that has already
been transposed. MEASURED on DuckDB v1.5.3, which settles it:

    damerau_levenshtein('ca','abc') = 2
    OSA('ca','abc')                 = 3      <- what the easy version answers
    unrestricted('ca','abc')        = 2

⇒ THE ALPHABET LAST-OCCURRENCE TABLE IS NOT OPTIONAL. An OSA kernel agrees
with DuckDB on `('ab','ba')` = 1, on `('kitten','sitting')` = 3 and on every
input with no repeated-and-re-edited transposition; `('ca','abc')` is the
smallest witness and it must be in the fixture.

⚠ THE TABLE IS 256 ENTRIES, NOT A HASH MAP, precisely BECAUSE the unit is the
BYTE — the "alphabet" is 0..255 and is closed. A character-based version would
need a real map, which is one more reason the byte reading is the cheap one as
well as the correct one.
"""

comptime STRFNN_HAMMING: UInt8 = 9
"""`hamming(a, b)` / `mismatches(a, b)` — EXACTLY 2 args, Utf8 -> INT64.

The count of positions at which the two BYTE sequences differ.

⛔⛔ IT RAISES ON TWO INPUTS THAT EVERY OTHER MEMBER OF THIS FAMILY ACCEPTS,
AND BOTH MESSAGES ARE MEASURED VERBATIM FROM v1.5.3:
    hamming('abc','abcd')  -> Invalid Input Error: Mismatch Function: Strings
                              must be of equal length!
    hamming('','')         -> Invalid Input Error: Mismatch Function: Strings
                              must be of length > 0!
The EMPTY-STRING refusal is the surprising one: `levenshtein('','')` is 0 and
a natural reading of "count the differing positions" is also 0, so a kernel
that answered 0 would look right and would accept a call DuckDB rejects.

⚠ AND THE EQUAL-LENGTH TEST IS ON BYTES: `hamming('é','e')` RAISES on v1.5.3
even though both are exactly one CHARACTER.

`mismatches` IS a true alias — measured identical. NULL in either -> NULL out,
and a NULL row is NOT length-checked (there is nothing to compare).
"""

comptime STRING_FN_N_REPEAT_MAX_BYTES: Int = 64 * 1024 * 1024
"""The `repeat` output ceiling, in BYTES, per ROW.

⚠ A LIMIT AND NOT A CLAMP: exceeding it RAISES by name. A clamp would return a
truncated string that differs from DuckDB with nothing saying so, which is the
worse failure — and `repeat` is the one member whose output size is controlled
by a DATA value rather than by the plan.

⛔ IT IS **NOT** SPELLED `STRFNN_*`, AND THAT IS LOAD-BEARING RATHER THAN
STYLISTIC. The plan-wire vocabulary generator derives the `StringFnN` wire
enum from EVERY `comptime STRFNN_<NAME>: UInt8` in this file, and a
repository lint REFUSES a `STRFNN_`-prefixed constant of any OTHER type —
because a member the scan cannot see is a member absent from the wire
vocabulary with nothing saying so. A ceiling is not an op; giving it the op
prefix would make the gate red for a real reason it could not explain. (There
is deliberately no `STRFNN_OP_COUNT` either — `string_fn_n_arity` answering 0
for an undeclared op is what forces a per-member decision, and a second size
constant is one more thing to leave stale.)
"""


# =============================================================================
# Column-reference side qualifier
# =============================================================================
#
# Non-equi / range join support: the `predicate=` join API lets a user
# qualify a column reference as belonging to the LEFT or RIGHT join input,
# e.g. `Expr.left("l_orderkey") == Expr.right("l_orderkey")`. The side bit
# rides on the existing `EXPR_COL_REF` variant (`ColRefData.side`) rather
# than introducing a new variant tag — it only matters inside a join
# predicate, and `COL_SIDE_NONE` is the universal default everywhere else.
#
# OUTSIDE join contexts (filter, project, agg) a `COL_SIDE_LEFT` /
# `COL_SIDE_RIGHT` qualifier is an ERROR — the optimizer / compiler
# raises clearly if a side-qualified col-ref reaches a non-join node.
# The `join_predicate_decompose` pass strips the qualifier (rewriting to
# `COL_SIDE_NONE` col-refs over the joined-row schema) before any other
# rule sees the join's residual Expr.
comptime COL_SIDE_NONE: UInt8 = 0
comptime COL_SIDE_LEFT: UInt8 = 1
comptime COL_SIDE_RIGHT: UInt8 = 2


# =============================================================================
# JSONPath parse helper.
# =============================================================================

def parse_json_path(path: String) raises -> List[String]:
    """Parse a JSONPath string into a list of path segments.

    Supported syntax (subset of JSONPath spec):
      - `$` -> [] (whole document; trivial extract)
      - `$.foo` -> ["foo"]
      - `$.foo.bar` -> ["foo", "bar"]
      - `$.foo.bar.baz` -> ["foo", "bar", "baz"]
      - `$."foo.bar"` -> ["foo.bar"]   ONE key — a QUOTED segment keeps its
        dots, its spaces, and any `[`, `]` or `*` inside it.
      - `$.a."b.c"` -> ["a", "b.c"]    the two forms mix freely.

    NOT supported (raise clearly):
      - Bracket-notation `$["foo"]`, `$.items[0]` (LIST indexing).
      - Wildcards `$.*`, `$..foo`.
      - Filters `$.foo[?(@.x > 1)]`.
      - An EMPTY (`$.""`) or UNTERMINATED (`$."a`) quoted segment, and
        trailing bytes after a closing quote (`$."a"x`) — each a Binder
        Error on DuckDB v1.5.3, so each raises here.

    ⛔ THE QUOTED SEGMENT IS NOT A CONVENIENCE — ITS ABSENCE IS A WRONG
    ANSWER. Splitting every segment on `.` with no quote handling parses
    `$."a.b"` to `["\"a", "b\""]`, which matches nothing, and `json_extract`
    returns a plausible SQL NULL with no raise and no diagnostic.

    Empty path `""` is treated as `"$"` (whole document).

    Raises on malformed input — caller (`Expr.json_extract_json` /
    `_string` factories) surfaces at plan time, not eval time.
    """
    var segs = List[String]()
    var bytes = path.as_bytes()
    var n = len(bytes)
    if n == 0:
        # Empty path -> whole document. No segments.
        return segs^
    # Path must start with '$'.
    if bytes[0] != UInt8(0x24):  # '$'
        raise Error("parse_json_path: path must start with '$', got '" + path + "'")
    var i = 1
    while i < n:
        if bytes[i] != UInt8(0x2E):  # '.'
            raise Error("parse_json_path: expected '.' separator at byte "
                        + String(i) + " in path '" + path + "' (supported: '$.foo.bar' and the quoted form '$.\"foo.bar\"'; brackets/wildcards/filters NOT supported)")
        i += 1
        if i < n and bytes[i] == UInt8(0x22):  # '"' — a QUOTED segment.
            # ⭐ THE QUOTED FORM IS ONE KEY, DOTS INCLUDED. Without this arm
            #   `$."a.b"` would fall into the unquoted loop below, split on
            #   the dot, and produce the two segments `"a` and `b"` — keys of
            #   no document — so `json_extract` would BIND, EXECUTE and
            #   return SQL NULL where DuckDB v1.5.3 answers the value.
            #
            #   MEASURED v1.5.3, transcribed not reasoned about:
            #     json_extract('{"a.b":5}',       '$."a.b"')    = 5
            #     json_extract('{"a":1}',         '$."a"')      = 1
            #     json_extract('{"a":{"b.c":2}}', '$.a."b.c"')  = 2
            #     json_extract('{"a b":3}',       '$."a b"')    = 3
            #     json_extract('{"a[0]":7}',      '$."a[0]"')   = 7
            #     json_extract('{"a*":8}',        '$."a*"')     = 8
            #   ⇒ `[` `]` `*` are LITERAL inside quotes, which is why the
            #   unquoted loop's rejection of them is NOT reused here.
            i += 1
            var qbuf = List[UInt8]()
            var closed = False
            while i < n:
                var qb = bytes[i]
                if qb == UInt8(0x5C):  # a backslash
                    # ⚠ THE ONLY TWO ESCAPES ARE `\\` AND `\"`. Every other
                    #   `\X` stays as BOTH bytes, and that is a POSITIVE
                    #   measured claim, not an omission. v1.5.3 over a
                    #   document whose key is a backslash-t-b:
                    #     $."a\\tb"   finds it    (`\\` collapses to one)
                    #     $."a\tb"    ALSO finds it (`\t` is two bytes)
                    #   A JSON-style unescaper would read the second as a TAB
                    #   and miss; a drop-the-backslash rule would read it as
                    #   `atb` and miss. Both answer NULL where DuckDB answers
                    #   the value.
                    if i + 1 < n and (
                        bytes[i + 1] == UInt8(0x22)
                        or bytes[i + 1] == UInt8(0x5C)
                    ):
                        qbuf.append(bytes[i + 1])
                        i += 2
                        continue
                    qbuf.append(qb)
                    i += 1
                    continue
                if qb == UInt8(0x22):  # the closing '"'
                    closed = True
                    i += 1
                    break
                qbuf.append(qb)
                i += 1
            if not closed:
                raise Error("parse_json_path: unterminated quoted segment in"
                            " path '" + path + "' (DuckDB v1.5.3 answers a"
                            " Binder Error here; this raises rather than"
                            " guessing where the key ends)")
            if len(qbuf) == 0:
                raise Error("parse_json_path: empty quoted segment in path '"
                            + path + "' (DuckDB v1.5.3 answers a Binder Error"
                            " on `$.\"\"`)")
            if i < n and bytes[i] != UInt8(0x2E):
                raise Error("parse_json_path: trailing bytes after the closing"
                            " quote in path '" + path + "' — a quoted segment"
                            " must be followed by '.' or the end of the path"
                            " (DuckDB v1.5.3: Binder Error on `$.\"a\"x`)")
            qbuf.append(UInt8(0))
            # SAFETY: qbuf is alive through the ctor call; the ptr it passes
            # is a NUL-terminated buffer String copies out immediately. Same
            # pattern as the unquoted arm below.
            var qseg = String(unsafe_from_utf8_ptr=qbuf.unsafe_ptr())
            segs.append(qseg^)
            continue
        # Read segment bytes until next '.' or EOI.
        # ⚠ AN UNQUOTED SEGMENT DOES NO UNESCAPING AND KEEPS ANY `"` THAT IS
        #   NOT ITS FIRST BYTE. v1.5.3: `json_extract('{"a\"b":4}', '$.a"b')`
        #   = 4, so quoted mode keys off the FIRST byte only; and
        #   `json_extract('{"a\\tb":1}', '$.a\\tb')` = NULL, where the quoted
        #   spelling of the same path finds the key.
        var start = i
        while i < n and bytes[i] != UInt8(0x2E):
            # Reject bracket/wildcard chars early with clear errors.
            var b = bytes[i]
            if b == UInt8(0x5B) or b == UInt8(0x5D):  # '[' / ']'
                raise Error("parse_json_path: bracket notation not supported (path '" + path + "')")
            if b == UInt8(0x2A):  # '*'
                raise Error("parse_json_path: wildcards not supported (path '" + path + "')")
            i += 1
        if i == start:
            raise Error("parse_json_path: empty segment after '.' in path '" + path + "'")
        # Build segment String from bytes[start..i] via NUL-term ctor
        # (mirrors parse_string._string_from_bytes pattern).
        var seg_buf = List[UInt8](capacity=(i - start) + 1)
        for j in range(start, i):
            seg_buf.append(bytes[j])
        seg_buf.append(UInt8(0))
        # SAFETY: seg_buf is alive through the ctor call; the ptr it
        # passes is a NUL-terminated buffer that String copies out
        # immediately. Same pattern as `parse_string`.
        var seg = String(unsafe_from_utf8_ptr=seg_buf.unsafe_ptr())
        segs.append(seg^)
    return segs^


# =============================================================================
# Typed data structs — variant payloads
# =============================================================================

struct ColRefData(Movable, Copyable):
    """Column reference by name.

    `side` is `COL_SIDE_NONE` for ordinary references; `COL_SIDE_LEFT` /
    `COL_SIDE_RIGHT` only appear inside a join `predicate=` Expr to pin
    the reference to one of the two join inputs. Carried
    through `copy()` / `write_to()` / `structural_hash`.
    """
    var name: String
    var side: UInt8

    def __init__(out self, name: String, side: UInt8 = COL_SIDE_NONE):
        self.name = name
        self.side = side

    def copy(self) -> Self:
        return Self(self.name.copy(), self.side)


struct ColIdxData(Movable, Copyable):
    """Column reference by index (post-compilation only)."""
    var index: Int

    def __init__(out self, index: Int):
        self.index = index

    def copy(self) -> Self:
        return Self(self.index)


struct LiteralData(Movable, Copyable):
    """Constant value."""
    var value: ScalarValue

    def __init__(out self, var value: ScalarValue):
        self.value = value^

    def copy(self) -> Self:
        return Self(self.value.copy())


struct BinaryOpData(Movable):
    """Binary operation with two child expressions.

    Uses OwnedPointer[Expr] for heap-allocated children -- this is how we
    handle recursive types in Mojo. OwnedPointer gives us automatic
    cleanup, clear ownership, and no manual free(). Like Rust's Box<Expr>.
    """
    var op: UInt8
    var left: OwnedPointer[Expr]
    var right: OwnedPointer[Expr]
    # WHO DECIDED what this `BIN_DIV` means, when that decision was made
    # without the operands' types (`col_expr_division`'s `DIVISION_*`; 0 for
    # every node any other builder makes). ⚠ ADVISORY, NEVER SEMANTIC: the
    # node is already a complete, executable division; a consumer that
    # ignores this field (every evaluator, the wire encoder, the optimizer)
    # gets exactly that division. Only `col_expr_bind` reads it, to re-decide
    # the division once a schema is in hand.
    var division_intent: UInt8

    def __init__(
        out self, op: UInt8, var left: Expr, var right: Expr,
        division_intent: UInt8 = 0,
    ):
        self.op = op
        self.left = OwnedPointer(left^)
        self.right = OwnedPointer(right^)
        self.division_intent = division_intent

    def copy(self) -> Self:
        return Self(
            self.op, self.left[].copy(), self.right[].copy(),
            self.division_intent,
        )

struct UnaryOpData(Movable):
    """Unary operation with one child expression."""
    var op: UInt8
    var child: OwnedPointer[Expr]

    def __init__(out self, op: UInt8, var child: Expr):
        self.op = op
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        return Self(self.op, self.child[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct CastData(Movable):
    """Type cast.

    `target` is the Mojo DType for numeric targets (kept for backward
    compatibility — callers checking `cast_target()` are unaffected).
    `target_arrow` carries the Arrow
    logical type (needed because DType cannot represent DECIMAL128(p,s)) and
    `decimal_precision` / `decimal_scale` carry the target precision/scale
    for `cast(x AS DECIMAL(p, s))`.  For an ordinary numeric cast,
    `target_arrow == ArrowType.from_dtype(target)` and the decimal fields
    are 0.
    """
    var child: OwnedPointer[Expr]
    var target: DType
    var target_arrow: ArrowType
    var decimal_precision: Int
    var decimal_scale: Int
    # TRY_CAST TWIN: null-on-failure mode.
    # False (default) = strict CAST — a bad input RAISES. True = TRY_CAST — a
    # bad input yields NULL instead of raising (SQL `TRY_CAST`, DuckDB
    # semantics). A flag (not a sibling node) keeps every strict CastData
    # construction unchanged.
    var try_cast: Bool

    def __init__(out self, var child: Expr, target: DType, try_cast: Bool = False):
        self.child = OwnedPointer(child^)
        self.target = target
        self.target_arrow = ArrowType.from_dtype(target)
        self.decimal_precision = 0
        self.decimal_scale = 0
        self.try_cast = try_cast

    def __init__(out self, var child: Expr, target: DType, target_arrow: ArrowType, decimal_precision: Int, decimal_scale: Int, try_cast: Bool = False):
        self.child = OwnedPointer(child^)
        self.target = target
        self.target_arrow = target_arrow
        self.decimal_precision = decimal_precision
        self.decimal_scale = decimal_scale
        self.try_cast = try_cast

    def copy(self) -> Self:
        return Self(self.child[].copy(), self.target, self.target_arrow, self.decimal_precision, self.decimal_scale, self.try_cast)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


@always_inline
def _arrow_to_physical_dtype(at: ArrowType) -> DType:
    """Map an ArrowType to the physical DType used as `CastData.target`.

    Only used by
    `Expr.cast_to_arrow(child, target_arrow)` to populate the
    back-compat `target: DType` field. The Arrow logical type
    (including unit information for temporal types) lives in
    `target_arrow`. For nested / variable-length / decimal Arrow
    types that have no DType peer, returns `DTYPE_NONE`.
    """
    if at == ArrowType.DATE32:
        return DType.int32
    elif at == ArrowType.DATE64:
        return DType.int64
    elif (
        at == ArrowType.TIMESTAMP
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        return DType.int64
    elif (
        at == ArrowType.TIME32_S
        or at == ArrowType.TIME32_MS
    ):
        return DType.int32
    elif (
        at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
    ):
        return DType.int64
    elif (
        at == ArrowType.DURATION_S
        or at == ArrowType.DURATION_MS
        or at == ArrowType.DURATION_US
        or at == ArrowType.DURATION_NS
    ):
        return DType.int64
    elif at == ArrowType.BOOL:
        return DType.bool
    elif at == ArrowType.INT8:
        return DType.int8
    elif at == ArrowType.INT16:
        return DType.int16
    elif at == ArrowType.INT32:
        return DType.int32
    elif at == ArrowType.INT64:
        return DType.int64
    elif at == ArrowType.UINT8:
        return DType.uint8
    elif at == ArrowType.UINT16:
        return DType.uint16
    elif at == ArrowType.UINT32:
        return DType.uint32
    elif at == ArrowType.UINT64:
        return DType.uint64
    elif at == ArrowType.FLOAT16:
        return DType.float16
    elif at == ArrowType.FLOAT32:
        return DType.float32
    elif at == ArrowType.FLOAT64:
        return DType.float64
    else:
        # STRING, BINARY, DECIMAL128, LIST, STRUCT, MAP, etc. — no DType peer.
        return DTYPE_NONE


struct AliasData(Movable):
    """Rename output column."""
    var child: OwnedPointer[Expr]
    var name: String

    def __init__(out self, var child: Expr, name: String):
        self.child = OwnedPointer(child^)
        self.name = name

    def copy(self) -> Self:
        return Self(self.child[].copy(), self.name.copy())

struct StringOpData(Movable):
    """String operation with a column child and a pattern argument.

    Represents operations like CONTAINS, STARTS_WITH, ENDS_WITH, LIKE.
    The child expression identifies the string column, and the pattern
    is the literal string to match against.
    """
    var op: UInt8
    var child: OwnedPointer[Expr]
    var pattern: String

    def __init__(out self, op: UInt8, var child: Expr, pattern: String):
        self.op = op
        self.child = OwnedPointer(child^)
        self.pattern = pattern

    def copy(self) -> Self:
        return Self(self.op, self.child[].copy(), self.pattern.copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

struct RegexpData(Movable):
    """Payload for `EXPR_REGEXP`.

    `op`          — one of REGEXP_LIKE / REGEXP_MATCH / REGEXP_REPLACE / REGEXP_EXTRACT.
    `child`       — the string-column expr.
    `pattern`     — the regex pattern literal (always a plan-literal in practice).
    `replacement` — "" unless op == REGEXP_REPLACE.
    `flags`       — "" / "i" / "g" / "gi" / "m" / "s" / "x" / ...
    `group`       — 0 unless op == REGEXP_EXTRACT (capture-group index; 0 = whole match).
    `group_name`  — "" unless op == REGEXP_EXTRACT and the user referenced a
                    named capture group `(?P<name>...)` by name; when non-empty
                    the executor resolves it to the group index via
                    `RegexProgram.group_index_for_name` (the pattern is only
                    compiled at execution time, so the name→index resolution
                    cannot happen at plan-build time). `group` is ignored when
                    `group_name` is non-empty.
    """
    var op: UInt8
    var child: OwnedPointer[Expr]
    var pattern: String
    var replacement: String
    var flags: String
    var group: Int
    var group_name: String

    def __init__(out self, op: UInt8, var child: Expr, pattern: String, replacement: String, flags: String, group: Int, group_name: String = ""):
        self.op = op
        self.child = OwnedPointer(child^)
        self.pattern = pattern
        self.replacement = replacement
        self.flags = flags
        self.group = group
        self.group_name = group_name

    def copy(self) -> Self:
        return Self(self.op, self.child[].copy(), self.pattern.copy(), self.replacement.copy(), self.flags.copy(), self.group, self.group_name.copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct SubstringData(Movable):
    """Payload for `EXPR_SUBSTRING`: a SQL
    `substring(s, start, length)` scalar over a string-column child.

    `child`  — the string-column expr.
    `start`  — 1-based start position (SQL semantics; `substring(s,1,2)` takes the
               first two characters). A `start <= 0` clamps the take to begin at
               the string's first character but STILL consumes `length` counting
               from `start` (standard SQL `substring` — the pre-string positions
               count against `length`).
    `length` — number of characters to take; `length < 0` means "to end of string"
               (the two-arg `substring(s, start)` form).

    Heap-indirect child via `OwnedPointer[Expr]`, breaking the `Expr -> Data ->
    Expr` recursion exactly like `RegexpData`."""
    var child: OwnedPointer[Expr]
    var start: Int
    var length: Int

    def __init__(out self, var child: Expr, start: Int, length: Int):
        self.child = OwnedPointer(child^)
        self.start = start
        self.length = length

    def copy(self) -> Self:
        return Self(self.child[].copy(), self.start, self.length)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct WhenCaseData(Movable, Copyable):
    """A single WHEN condition/result pair.

    Uses ArcPointer[Expr] (not OwnedPointer) so this struct can conform
    to Copyable and be stored in List. ArcPointer is reference-counted
    and copyable. This is a pragmatic workaround for Mojo's requirement
    that all fields be copyable for Copyable conformance.
    """
    var condition: ArcPointer[Expr]
    var result: ArcPointer[Expr]

    def __init__(out self, var condition: Expr, var result: Expr):
        self.condition = ArcPointer(condition^)
        self.result = ArcPointer(result^)

    def copy(self) -> Self:
        """True deep copy of the expression trees.

        WhenCaseData fields are ArcPointer[Expr] (refcount-bumped on the
        struct's auto-Copyable path). This `copy()` walks the inner Exprs
        for a true byte-disjoint clone; the cascade in `Expr.copy()`
        chooses this method so the cloned tree shares no storage with
        the original.
        """
        return Self(self.condition[].copy(), self.result[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct AggFnData(Movable):
    """Aggregate-as-expression payload for `EXPR_AGG_FN`.

    The `op` field mirrors the `AGG_*` constants from
    `komira_plan_expr/agg_expr.mojo` (AGG_SUM=0, AGG_COUNT=1, AGG_MIN=2,
    AGG_MAX=3, AGG_MEAN=4). The `child` is the column reference (or
    other scalar Expr) being aggregated.

    Construction: prefer the ColExpr `.max()` / `.min()` / `.sum()` /
    `.avg()` / `.count()` factories which produce an `Expr` of tag
    `EXPR_AGG_FN`. The variant is expected to be consumed by an optimizer
    rule (not in this tree) before eval; `interpret_expr` (komira_kernels)
    returns NULL for it.
    """
    var op: UInt8
    var child: OwnedPointer[Expr]

    def __init__(out self, op: UInt8, var child: Expr):
        self.op = op
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        return Self(self.op, self.child[].copy())


struct WindowFnData(Movable):
    """Window-function-as-expression payload for `EXPR_WINDOW_FN`.

    `func` mirrors `PF_*` from `partition_expr.mojo`. `arg_col` is the
    input column (empty for ranking factories). `arg_offset` is the
    LAG/LEAD offset / NTH n / NTILE buckets / rolling-N. `frame` is
    the frame spec. The `partition_by`/`order_by`/`descending` triple
    is set by chaining `.over(...)` on the constructed Expr.

    User-facing entry: ColExpr `.rank()` / `.lag(n)` / `.cum_sum()` /
    `.rolling_mean(n)` factories. Lowered by the SDK's window lowering
    (not in this tree) to a `PARTITION_BY` plan node directly (no Project
    wrap). `interpret_expr` (komira_kernels) returns NULL for it.
    """
    var func: UInt8
    var arg_col: String
    var arg_offset: Int
    var frame: PartitionFrame
    var partition_by: List[String]
    var order_by: List[String]
    var descending: List[Bool]

    def __init__(
        out self,
        func: UInt8,
        var arg_col: String,
        arg_offset: Int,
        var frame: PartitionFrame,
        var partition_by: List[String],
        var order_by: List[String],
        var descending: List[Bool],
    ):
        self.func = func
        self.arg_col = arg_col^
        self.arg_offset = arg_offset
        self.frame = frame^
        self.partition_by = partition_by^
        self.order_by = order_by^
        self.descending = descending^

    def copy(self) -> Self:
        """Deep-copy the WindowFnData (all fields are value or owned)."""
        return Self(
            self.func,
            self.arg_col.copy(),
            self.arg_offset,
            self.frame.copy(),
            self.partition_by.copy(),
            self.order_by.copy(),
            self.descending.copy(),
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct WhenData(Movable):
    """CASE WHEN ... THEN ... ELSE ... expression."""
    var cases: List[WhenCaseData]
    var default: OwnedPointer[Expr]

    def __init__(out self, var cases: List[WhenCaseData], var default: Expr):
        self.cases = cases^
        self.default = OwnedPointer(default^)

    def copy(self) -> Self:
        var new_cases = List[WhenCaseData]()
        for c in self.cases:
            new_cases.append(c.copy())
        return Self(new_cases^, self.default[].copy())


struct StructFieldData(Movable):
    """Payload for `EXPR_STRUCT_FIELD`.

    BY-NAME variant. `parent` evaluates to a STRUCT Column at runtime;
    `field_name` identifies which child (by `_field_names[i]`) to extract
    via a linear scan. Constructed via `Expr.struct_field(parent, field_name)`.
    User-facing surface: untyped `col("addr").field("city")`. Composable,
    schema-agnostic.

    The bound-idx twin (`EXPR_STRUCT_FIELD_IDX` / `StructFieldIdxData`)
    skips the scan when the planner / typed DF has resolved the index at
    comptime — same eval shape on the parent side but zero scan on the
    child side.
    """
    var parent: OwnedPointer[Expr]
    var field_name: String

    def __init__(out self, var parent: Expr, field_name: String):
        self.parent = OwnedPointer(parent^)
        self.field_name = field_name

    def copy(self) -> Self:
        return Self(self.parent[].copy(), self.field_name.copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct StructFieldIdxData(Movable):
    """Payload for
    `EXPR_STRUCT_FIELD_IDX`.

    BY-INDEX variant. `parent` evaluates to a STRUCT Column at runtime;
    `field_idx` directly addresses `_children[field_idx]`. Constructed
    via `Expr.struct_field_idx(parent, field_idx)`. The typed DataFrame
    chain method `df.field["addr","city"]()` resolves `field_idx` at
    COMPTIME via `comptime_struct_field_index[S, parent, name]()` and
    emits this variant. Eval raises if `field_idx >= num_children` (the
    runtime safety net behind the comptime guard).

    Mirrors the `EXPR_COL_REF` / `EXPR_COL_IDX` bound-twin shape (the
    convention used elsewhere — see `ColIdxData`).
    """
    var parent: OwnedPointer[Expr]
    var field_idx: Int

    def __init__(out self, var parent: Expr, field_idx: Int):
        self.parent = OwnedPointer(parent^)
        self.field_idx = field_idx

    def copy(self) -> Self:
        return Self(self.parent[].copy(), self.field_idx)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct MapGetData(Movable):
    """Payload for `EXPR_MAP_GET`.

    Per-row MAP[key] projection.  `parent` evaluates to a MAP-typed Column
    at runtime; `key` evaluates to either a literal scalar (broadcast) or
    a per-row key column.  At eval time, for each row of the parent map:
      1. Pull the entries list for that row (offsets[i]..offsets[i+1]).
      2. Scan entries for the entry whose key equals the row's key value.
      3. Return that entry's value, or NULL if no match.

    Constructed via `Expr.map_get(parent, key)`.

    User-facing surface:
      - Untyped DF: `col("metadata").get(lit("city"))` or
                    `col("metadata").get(col("which_key"))`.
      - Typed DF:   `df.col[S, "metadata"].get[String]("city")` —
                    `KeyType` is comptime-validated against the Map's
                    declared key type via `comptime_map_key_type[S, parent]()`.

    NO COMPTIME-IDX TWIN: Map keys are inherently runtime values; the
    typed-DF surface only adds the type-check at the wrapping layer, not
    a different EXPR variant.
    """
    var parent: OwnedPointer[Expr]
    var key: OwnedPointer[Expr]

    def __init__(out self, var parent: Expr, var key: Expr):
        self.parent = OwnedPointer(parent^)
        self.key = OwnedPointer(key^)

    def copy(self) -> Self:
        return Self(self.parent[].copy(), self.key[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct JsonExtractData(Movable):
    """Payload for `EXPR_JSON_EXTRACT` (tag 19).

    Extract a path from a JSON-bytes column. `parent` evaluates to an
    Arrow STRING column whose values are JSON text. `path_segments` is
    the parsed JSONPath (e.g. `["user", "id"]` for `$.user.id`).
    `output_type` is the target Arrow type for the extracted column
    (STRING only; a typed `json_extract[Int64]` is not served).
    `preserve_extension_metadata` discriminates `->` (True, attaches
    `ARROW:extension:name = "komira.ext.json"`) vs `->>`
    (False, plain STRING).

    Constructed via `Expr.json_extract_json(parent, path)` (operator
    `->`) or `Expr.json_extract_string(parent, path)` (operator `->>`).
    Both operators take a String JSONPath and parse it into
    `path_segments` at factory time; malformed paths raise at plan
    time, not at eval time.

    Engine tests construct directly via the static factories below.

    NO COMPTIME-IDX TWIN: JSONPath is inherently runtime (the path is
    a string parsed at plan time, not a structural offset).
    """
    var parent: OwnedPointer[Expr]
    var path_segments: List[String]
    var output_type: ArrowType
    var preserve_extension_metadata: Bool

    def __init__(out self, var parent: Expr, var path_segments: List[String],
                 output_type: ArrowType, preserve_extension_metadata: Bool):
        self.parent = OwnedPointer(parent^)
        self.path_segments = path_segments^
        self.output_type = output_type
        self.preserve_extension_metadata = preserve_extension_metadata

    def copy(self) -> Self:
        var segs = List[String]()
        for i in range(len(self.path_segments)):
            segs.append(self.path_segments[i].copy())
        return Self(self.parent[].copy(), segs^, self.output_type,
                    self.preserve_extension_metadata)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct ExtractData(Movable):
    """Payload for `EXPR_EXTRACT` (tag 20).

    Carries a single child Expr that must evaluate to a DATE32 or
    TIMESTAMP_* Column, plus the unit selector (`EXTRACT_YEAR` /
    `EXTRACT_MONTH` / ... / `EXTRACT_TRUNC_YEAR` / ...).

    Constructed via `Expr.extract(unit, child)` or any of the per-unit
    factories `Expr.year(child)` / `Expr.month(child)` / ...
    """
    var child: OwnedPointer[Expr]
    var unit: UInt8

    def __init__(out self, var child: Expr, unit: UInt8):
        self.child = OwnedPointer(child^)
        self.unit = unit

    def copy(self) -> Self:
        return Self(self.child[].copy(), self.unit)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct StringFnData(Movable):
    """Payload for `EXPR_STRING_FN` (tag 24).

    UNARY scalar string function. `child` evaluates to a STRING (or
    DICTIONARY) Column; `op` is one of the `STRFN_*` constants. The output
    type is PER-OP — see `string_fn_returns_int`.

    Byte-for-byte the `MathFnData` shape, deliberately: the two are the unary
    scalar-function variants of the expression IR and a reader who knows one
    knows the other.
    """
    var op: UInt8
    var child: OwnedPointer[Expr]

    def __init__(out self, op: UInt8, var child: Expr):
        self.op = op
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        return Self(self.op, self.child[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


def string_fn_returns_int(op: UInt8) -> Bool:
    """Does `STRFN_<op>` produce an INT64 column rather than a Utf8 one?

    ⚠ THE SINGLE PLACE THIS QUESTION IS ANSWERED. Output-type inference,
    the projection overlay's string-producing test and the eval arm all
    read it, so adding a `STRFN_*` member forces a decision here instead of
    letting one site's default stand in for a judgement. Total, never
    raising: an unknown op answers False (Utf8), which is the family default
    and is refused later by the eval arm BY NAME rather than here.
    """
    # ⚠ FIVE MEMBERS, NOT ONE: `STRFN_LENGTH` plus the string->INT bucket.
    # A reader who remembers "only length" will mis-predict output types for
    # four more ops. The Utf8 members remain the majority and the default.
    return (
        op == STRFN_LENGTH
        or op == STRFN_ASCII
        or op == STRFN_UNICODE
        or op == STRFN_STRLEN
        or op == STRFN_BIT_LENGTH
    )


struct StringFnNData(Movable):
    """Payload for `EXPR_STRING_FN_N` (tag 26).

    MULTI-ARGUMENT scalar string function. `op` is one of the `STRFNN_*`
    constants; `args` holds EVERY operand as an ordinary `Expr`, in SOURCE
    ORDER, with no operand promoted to a named field.

    ⭐ WHY ONE `List[Expr]` AND NOT NAMED SLOTS. `replace(s, from, to)` and
    `lpad(s, n, pad)` both have three operands and NOTHING in common between
    slot 2 of one and slot 2 of the other; naming them (`source`/`target` vs
    `count`/`pad`) would either need one struct per function — which is a
    fixed-arity tag per function, i.e. the design this replaces — or names
    that lie about one of them. `concat` settles it: its arity is not fixed at
    all, so there is no slot count that could be named.

    ⚠ THE INDEX IS THE CONTRACT, AND `string_fn_n_arity()` IS WHERE IT IS
    WRITTEN DOWN. args[0] is the subject string for every member EXCEPT
    `STRFNN_CONCAT_WS`, where args[0] is the separator — that one exception is
    stated on the op's own docstring and is why no accessor here is called
    `subject`.

    ⛔ THE ARITY IS NOT VALIDATED BY THIS CONSTRUCTOR. A payload struct that
    raises cannot be built from a non-raising factory, and every producer
    (binder, wire decoder, SDK surface) already has a raising context in which
    to check `string_fn_n_arity`. The EVALUATOR checks it again and refuses by
    name, which is what makes a mis-built node loud rather than wrong.
    """
    var op: UInt8
    var args: List[Expr]

    def __init__(out self, op: UInt8, var args: List[Expr]):
        self.op = op
        self.args = args^

    def copy(self) -> Self:
        var new_args = List[Expr](capacity=len(self.args))
        for i in range(len(self.args)):
            new_args.append(self.args[i].copy())
        return Self(self.op, new_args^)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass



# THE STRING-SIMILARITY family. Three ops, three SQL
# names, all Utf8 x Utf8 -> **FLOAT64**.
#
# ⭐⭐ THIS FAMILY IS WHY `string_fn_n_returns_float` EXISTS. The KERNELS are
# the cheap half — the three below walk two byte strings exactly like the
# edit-distance family one screen up. What they need is a third answer to
# "what type does this node produce": with only a TWO-WAY choice a float
# output on `EXPR_STRING_FN_N` is inexpressible.
#
# ⛔⛔ ALL THREE OPERATE ON **BYTES**, NOT CHARACTERS — the same reading as the
# edit-distance family and, again, MEASURED rather than inherited:
#     jaro_similarity('Ünïcodé','Unicode') = 0.65714285714285714
# A CHARACTER kernel answers 0.71428571428571430 there (4 matches over 7 and 7);
# the byte kernel answers 4 matches over 10 and 7, which is what DuckDB prints.
#     jaccard('Ünïcodé','Unicode')         = 0.36363636363636365 = 4/11
# which is the BYTE-set intersection (4) over the BYTE-set union (11); the
# CHARACTER sets intersect in 4 over a union of 10 and answer 0.4.
# Both agree on every ASCII input, which is this repo's standing defect shape.

comptime STRFNN_JARO: UInt8 = 11
"""`jaro_similarity(a, b)` — EXACTLY 2 args, Utf8 -> FLOAT64. The Jaro
similarity over BYTES, in [0, 1].

⚠ EMPTY OPERANDS ANSWER 0 AND DO NOT RAISE, which is the opposite of
`STRFNN_HAMMING` and worth stating because the two families look alike.
MEASURED v1.5.3: `jaro_similarity('','')` = 0, `jaro_similarity('abc','')` = 0.
A "two empty strings are identical, so 1" reading is the plausible wrong one.

⛔ DuckDB'S THIRD ARGUMENT — A SCORE CUTOFF — IS **NOT SERVED**, AND THAT IS A
STATED NARROWING recorded in `string_fn_n_arity`. MEASURED:
`jaro_similarity('dixon','dicksonx')` = 0.76666666666666661 while
`jaro_similarity('dixon','dicksonx', 0.9)` = **0** and the same call at 0.5 is
0.76666666666666661 again — the score is computed and then ZEROED below the
cutoff. Serving it needs a NUMERIC operand on this tag; see the arity table.

NULL in either operand -> NULL out (measured)."""

comptime STRFNN_JARO_WINKLER: UInt8 = 12
"""`jaro_winkler_similarity(a, b)` — EXACTLY 2 args, Utf8 -> FLOAT64.

Jaro, plus Winkler's common-prefix boost: `j + p * L * (1 - j)` with
`p = 0.1` and `L` the common prefix length.

⛔⛔ TWO CONSTANTS IN THAT FORMULA ARE MEASURED, AND A KERNEL THAT GETS EITHER
WRONG IS RIGHT ON THE TEXTBOOK EXAMPLES:
  * **L IS CAPPED AT 4.** `jaro_similarity('abcdefgh','abcdeXXX')` = 0.75 and
    `jaro_winkler_similarity` of the same pair = 0.84999999999999998. The
    common prefix is FIVE bytes; 0.75 + 4*0.1*0.25 = 0.85 and an uncapped
    L = 5 answers 0.875.
  * **THE BOOST IS GATED ON j > 0.7.** `jaro_similarity('abcde','abzzzzzzz')` =
    0.54074074074074074 and `jaro_winkler_similarity` of that pair is
    0.54074074074074074 TOO — no boost at all, despite a two-byte common
    prefix. Ungated, it would answer 0.6326.... The neighbouring pair
    `('abcde','abcxx')` HAS the boost (0.73333333333333339 -> 
    0.81333333333333335, a delta of exactly 3*0.1*(1-j)), so the two rows
    together pin the gate from both sides.

⚠ THE PREFIX IS COUNTED IN BYTES, like the matching."""

comptime STRFNN_JACCARD: UInt8 = 13
"""`jaccard(a, b)` — EXACTLY 2 args, Utf8 -> FLOAT64. The Jaccard index of the
two operands' BYTE SETS: `|A ∩ B| / |A ∪ B|`.

⛔⛔ IT IS A SET OF SINGLE BYTES, NOT A SET OF BIGRAMS, AND THAT IS THE ONE
THING A "jaccard on strings" IMPLEMENTATION USUALLY GETS OTHERWISE. MEASURED
v1.5.3: `jaccard('martha','marhta')` = **1** — the two share every character
and differ only in ORDER, and a bigram implementation answers 0.2 there;
`jaccard('abc','cba')` = **1** for the same reason, where bigrams answer 0.
`jaccard('aab','ab')` = 1 (a SET ignores multiplicity) and
`jaccard('abcd','ab')` = 0.5 = |{a,b}| / |{a,b,c,d}|.

⛔ IT RAISES ON AN EMPTY OPERAND, WHERE `STRFNN_JARO` ANSWERS 0. MEASURED, and
the message is verbatim: `jaccard('abc','')` ->
`Invalid Input Error: Jaccard Function: An argument too short!`. Both operands
empty raises the same. A kernel answering 0 (or 1, on "two empty sets are
equal") accepts a call the parity target rejects.

⚠ CASE-SENSITIVE: `jaccard('ABC','abc')` = 0."""


def string_fn_n_returns_int(op: UInt8) -> Bool:
    """Does `STRFNN_<op>` produce an INT64 column rather than a Utf8 one?

    ⚠ THE SINGLE PLACE THIS QUESTION IS ANSWERED for the variadic family, the
    exact twin of `string_fn_returns_int` one screen up. Output-type
    inference, the projection overlay's string-producing test and the eval arm
    all read it, so adding a `STRFNN_*` member forces a decision here instead
    of letting one site's default stand in for a judgement. Total, never
    raising: an unknown op answers False (Utf8), the family default, and is
    refused later by the eval arm BY NAME rather than here.
    """
    # ⚠ FOUR MEMBERS, NOT ONE. The edit-distance family
    # is INT64-returning like `strpos`, so this arm is nearly half of the
    # family, and a reader who remembers "only strpos" will mis-predict four
    # output types.
    return (
        op == STRFNN_STRPOS
        or op == STRFNN_LEVENSHTEIN
        or op == STRFNN_DAMERAU_LEVENSHTEIN
        or op == STRFNN_HAMMING
    )


def string_fn_n_returns_float(op: UInt8) -> Bool:
    """Does `STRFNN_<op>` produce a FLOAT64 column?

    ⚠ THE SINGLE PLACE THIS QUESTION IS ANSWERED, the exact twin of
    `string_fn_n_returns_int` directly above. The family's output type is now a
    THREE-WAY choice — INT64, FLOAT64, Utf8 — and every site that infers it
    must ask both predicates in that order, because a member declared BOTH is a
    contradiction this pair cannot express and `string_fn_n_type_is_coherent`
    below is what refuses one.

    ⛔ A NEW MEMBER DEFAULTS TO Utf8 BY OMISSION, which is the fail-visible
    direction: the eval arm refuses an op it has no kernel for BY NAME, where a
    wrong TYPE would hand the caller a column whose schema disagrees with its
    bytes. Total, never raising.
    """
    return (
        op == STRFNN_JARO
        or op == STRFNN_JARO_WINKLER
        or op == STRFNN_JACCARD
    )


def string_fn_n_type_is_coherent(op: UInt8) -> Bool:
    """Is `STRFNN_<op>`'s declared output type a single answer?

    ⭐ THE CONTRADICTION GUARD THE TWO-WAY VERSION OF THIS FAMILY DID NOT NEED.
    With one predicate the type was total by construction: `returns_int` or
    not. With two, an op named by BOTH declares itself INT64 *and* FLOAT64, and
    every consumer would resolve that by ARM ORDER — silently, differently per
    consumer, and correctly nowhere. This says so once so a test can assert it
    over the whole declared range rather than per member.

    Total, never raising.
    """
    return not (string_fn_n_returns_int(op) and string_fn_n_returns_float(op))


def string_fn_n_arity(op: UInt8) -> Int:
    """How many arguments `STRFNN_<op>` REQUIRES, or a negative variadic floor.

    ⭐ THE ONE ARITY TABLE, READ BY FOUR PRODUCERS AND ONE CONSUMER. The SQL
    binder, the DataFrame surface, the wire decoder and the optimizer all build
    or rebuild one of these nodes, and the evaluator has to run whatever they
    built. Four independent opinions about "how many arguments does `lpad`
    take" is four chances to disagree; this is the answer all of them read.

    Returns:
        `n > 0`  — EXACTLY n arguments.
        `n < 0`  — VARIADIC with a floor of `-n` arguments (so `-1` means
                   "one or more", `-2` means "two or more").
        `0`      — unknown op. A caller MUST treat this as a refusal and never
                   as "no constraint"; that is the whole reason `0` is not
                   spelled as a legal arity for any member.

    ⚠ `concat_ws`'s floor is 2, NOT 1: DuckDB's own signature is
    `(separator, string, [ANY...])` and `concat_ws('-')` alone does not bind
    there either. The floor counts the separator.
    """
    if op == STRFNN_CONCAT:
        return -1
    if op == STRFNN_CONCAT_WS:
        return -2
    if op == STRFNN_REPLACE:
        return 3
    if op == STRFNN_LPAD:
        return 3
    if op == STRFNN_RPAD:
        return 3
    if op == STRFNN_REPEAT:
        return 2
    if op == STRFNN_STRPOS:
        return 2
    # The edit-distance family. All three
    # are exactly two arguments; none is variadic in DuckDB v1.5.3 either.
    if op == STRFNN_LEVENSHTEIN:
        return 2
    if op == STRFNN_DAMERAU_LEVENSHTEIN:
        return 2
    if op == STRFNN_HAMMING:
        return 2
    # Exactly three, like `replace`, and NOT
    # variadic in DuckDB v1.5.3 either.
    if op == STRFNN_TRANSLATE:
        return 3
    # EXACTLY TWO, ALL THREE.
    #
    # ⛔⛔ AND FOR THE FIRST TWO THAT IS A **STATED NARROWING**, NOT THE WHOLE
    # DuckDB SIGNATURE. v1.5.3 gives `jaro_similarity` and
    # `jaro_winkler_similarity` a THREE-argument overload whose third operand
    # is a SCORE CUTOFF: measured, `jaro_similarity('dixon','dicksonx')` =
    # 0.76666666666666661 and the same call with a third argument of 0.9
    # answers **0**, while 0.5 answers 0.76666666666666661 again. So it zeroes
    # a result below the cutoff rather than changing the matching.
    #
    # ⚠ IT IS SPELLED `2`, NOT `-2`, AND THE VARIADIC FLOOR WOULD HAVE BEEN
    # WRONG IN THE DANGEROUS DIRECTION. This table can say "exactly n" or "at
    # least n" and nothing else, so a floor of 2 would ACCEPT
    # `jaro_similarity(a, b, c, d)` — measured a Binder Error on v1.5.3 — i.e.
    # a query that runs here and fails on the parity target, the divergence
    # that looks like extra capability. Refusing the 3-argument form is a
    # narrowing the caller is TOLD about; accepting a 4-argument one is a
    # promise nothing can keep. The cutoff overload needs a NUMERIC operand on
    # this tag, which the column evaluator's string-argument binder (not in
    # this tree) cannot bind — the same wall
    # `STRFNN_LPAD` needed its own eval path to get past.
    #
    # `jaccard` has no 3-argument overload there at all (measured:
    # `jaccard('a','b',0.5)` is a Binder Error), so for it 2 is the full
    # signature and not a narrowing.
    if op == STRFNN_JARO:
        return 2
    if op == STRFNN_JARO_WINKLER:
        return 2
    if op == STRFNN_JACCARD:
        return 2
    return 0


def string_fn_n_arity_ok(op: UInt8, n: Int) -> Bool:
    """Is `n` a legal argument count for `STRFNN_<op>`?

    False for an unknown op, by construction — `string_fn_n_arity` answers 0
    there and 0 satisfies neither branch. That is deliberate: an op nobody has
    declared an arity for has no legal call.
    """
    var want = string_fn_n_arity(op)
    if want > 0:
        return n == want
    if want < 0:
        return n >= -want
    return False


def string_fn_n_name(op: UInt8) -> String:
    """The SQL name of `STRFNN_<op>`, for refusal messages ONLY.

    ⚠ NOT A DISPATCH KEY AND NOT A RENDER. `Expr.write_to` prints the numeric
    op (see its arm), because the plan-wire round trip's TEXT leg has to see a
    dropped field and a NAME table is one more thing that can drift out of
    step with the numbering. This exists so a refusal can say `lpad` instead of
    `op 3`, and an unknown op renders as its number rather than being aliased
    onto a neighbour.
    """
    if op == STRFNN_CONCAT:
        return String("concat")
    if op == STRFNN_CONCAT_WS:
        return String("concat_ws")
    if op == STRFNN_REPLACE:
        return String("replace")
    if op == STRFNN_LPAD:
        return String("lpad")
    if op == STRFNN_RPAD:
        return String("rpad")
    if op == STRFNN_REPEAT:
        return String("repeat")
    if op == STRFNN_STRPOS:
        return String("strpos")
    if op == STRFNN_LEVENSHTEIN:
        return String("levenshtein")
    if op == STRFNN_DAMERAU_LEVENSHTEIN:
        return String("damerau_levenshtein")
    if op == STRFNN_HAMMING:
        return String("hamming")
    if op == STRFNN_TRANSLATE:
        return String("translate")
    if op == STRFNN_JARO:
        return String("jaro_similarity")
    if op == STRFNN_JARO_WINKLER:
        return String("jaro_winkler_similarity")
    if op == STRFNN_JACCARD:
        return String("jaccard")
    return String("strfnn#") + String(Int(op))


struct UdfCallData(Movable):
    """Payload for `EXPR_UDF_CALL` (tag 25).

    A REGISTERED SCALAR UDF applied to one expression. `child` evaluates to a
    column of `in_tag`'s dtype; the call produces a column of `out_tag`'s.

    ── THE FIVE FIELDS, AND WHO IS ALLOWED TO WRITE EACH ───────────────────

    * `name`   — the REGISTRY RESOLUTION KEY, written by `register_scalar`'s
      single `name` parameter and by nothing else. ⛔ Not a display label:
      it is the string a PEER resolves against ITS registry to re-mint a
      handle after this node crosses the wire, which is why the surface that
      builds this node has exactly one name in it.
    * `handle` — PROCESS-LOCAL, generation-carrying. `None` on a node that
      crossed the wire (the codec strips it, `UdfData.registered_handle_id`'s
      precedent); execution then REFUSES by name rather than guessing.
    * `in_type` / `out_type` — the argument's and the result's `ArrowType`.
      ⚠ `ArrowType` AND NOT THE ENGINE'S `DT_*` TAG, DELIBERATELY. `DT_*` is a
      `komira_eval` vocabulary this package cannot import (eval depends on
      core), and it is spelled THREE INCOMPATIBLE WAYS in this tree —
      `schema_descriptor.DT_I64` is 3 while `row_block.DT_I64` and
      `column_format_storage.DT_I64` are both 1 — so a bare `UInt8` here would
      be a number whose meaning the reader cannot recover. `ArrowType` is the
      plan IR's own dtype vocabulary; `_infer_expr_field` reads `out_type`
      with no conversion at all, and the ONE consumer that needs a `DT_*` tag
      (the SDK's execution ladder) converts at that single site.

      Both are the single runtime copy of `ScalarUdf`'s `comptime
      IN_TAG`/`OUT_TAG`, which are derived from the customer function's own
      signature — ONE derivation chain, `T -> IN_TAG -> in_type`, so a UDF's
      declared output type and the type its kernel actually writes cannot
      disagree.
    * `child` — the argument. Any expression, including another
      `EXPR_UDF_CALL`; nesting is the whole reason this is a tag.

    ⚠ THE THUNK IS NOT A FIELD, AND IT MUST NOT BECOME ONE. `UdfRunBatchThunk`
    is a function type over `UnsafePointer[..., MutExternalOrigin]`, so putting
    it here would (a) put a wildcard-origin pointer in a plan-IR field, (b)
    make the plan packages depend on the engine's operators (not in this tree)
    — a package CYCLE, since those depend on the plan compiler, which depends
    on the plan packages — and (c) put an unserializable value in a type the
    wire encodes. The handle is the indirection that avoids all three.
    """

    var name: String
    var handle: Optional[Int]
    var in_type: ArrowType
    var out_type: ArrowType
    var child: OwnedPointer[Expr]

    def __init__(
        out self,
        var name: String,
        var handle: Optional[Int],
        in_type: ArrowType,
        out_type: ArrowType,
        var child: Expr,
    ):
        self.name = name^
        self.handle = handle^
        self.in_type = in_type
        self.out_type = out_type
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        """★ THE SINGLE COPY SITE FOR A UDF IN A PLAN, and the reason the
        expression form survives the optimizer where the node form does not.
        Every optimizer rebuild that copies an `Expr` copies the UDF; there is
        no non-UDF factory to forget it."""
        return Self(
            self.name.copy(),
            self.handle.copy(),
            self.in_type,
            self.out_type,
            self.child[].copy(),
        )

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct MathFnData(Movable):
    """Payload for `EXPR_MATH_FN` (tag 21).

    UNARY scalar math.  `child` evaluates to a numeric Column; `op` is one of
    the `MATH_*` constants (see their declaration block for the DuckDB type
    measurement that makes them free, and for the three names that may NOT be
    added here).

    ⚠ OUTPUT IS ALWAYS A FLOAT64 COLUMN (null in -> null out), FOR EVERY OP.
    That is the tag's contract and the reason a name can join it at no
    structural cost; it is also why `abs` / `round` / `sign`, which PRESERVE
    their input type in DuckDB, cannot.

    Constructed via `Expr.math_fn(op, child)` or the per-fn factories
    (`Expr.sin` / `Expr.sqrt` / ... / `Expr.tanh`).
    """
    var op: UInt8
    var child: OwnedPointer[Expr]

    def __init__(out self, op: UInt8, var child: Expr):
        self.op = op
        self.child = OwnedPointer(child^)

    def copy(self) -> Self:
        return Self(self.op, self.child[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct MathFn2Data(Movable):
    """Payload for `EXPR_MATH_FN2` (tag 22).

    BINARY scalar math.  Both `left` / `right` evaluate to numeric Columns;
    `op` is MATH2_ATAN2 (for the haversine great-circle formula) or
    MATH2_POW.  Output is always a FLOAT64 Column.

    Constructed via `Expr.math_fn2(op, left, right)` or `Expr.atan2(y, x)`.
    """
    var op: UInt8
    var left: OwnedPointer[Expr]
    var right: OwnedPointer[Expr]

    def __init__(out self, op: UInt8, var left: Expr, var right: Expr):
        self.op = op
        self.left = OwnedPointer(left^)
        self.right = OwnedPointer(right^)

    def copy(self) -> Self:
        return Self(self.op, self.left[].copy(), self.right[].copy())

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct InListData(Movable):
    """Payload for `EXPR_IN_LIST` (tag 9).

    Represents `child IN (v0, ..., v{n-1})` as a canonical IR node so
    the engine probes a value table once per batch instead of walking
    an N-deep OR-of-eq tree. Constructed via `Expr.in_list_node(...)`.
    """
    var child: OwnedPointer[Expr]
    var values: List[ScalarValue]

    def __init__(out self, var child: Expr, var values: List[ScalarValue]):
        self.child = OwnedPointer(child^)
        self.values = values^

    def copy(self) -> Self:
        var new_values = List[ScalarValue]()
        for i in range(len(self.values)):
            new_values.append(self.values[i].copy())
        return Self(self.child[].copy(), new_values^)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

# =============================================================================
# Expr — the main expression tree node
# =============================================================================

struct Expr(Movable, Writable):
    """Expression tree node.

    Tagged struct with typed variant data. Uses OwnedPointer[Expr] for
    recursive child references (heap indirection with automatic cleanup).

    Why not Variant? Variant[ColRefData, LiteralData, BinaryOpData, ...]
    would work but makes pattern matching verbose. The tagged struct
    approach with factory methods gives a cleaner API.
    """

    var tag: UInt8
    var _col_ref: Optional[ColRefData]
    var _col_idx: Optional[ColIdxData]
    var _literal: Optional[LiteralData]
    var _binary: Optional[BinaryOpData]
    var _unary: Optional[UnaryOpData]
    var _cast: Optional[CastData]
    var _alias: Optional[AliasData]
    var _string_op: Optional[StringOpData]
    var _when: Optional[WhenData]
    # Aggregate-as-expression for the
    # scalar-broadcast rewrite. Populated when tag == EXPR_AGG_FN.
    var _agg_fn: Optional[AggFnData]
    # Window-function-as-expression for
    # the `df.with_column(col("x").rank().over("g"))` Polars-shape API.
    # Populated when tag == EXPR_WINDOW_FN.
    var _window_fn: Optional[WindowFnData]
    # Set-membership predicate `child IN (...)`.
    # Populated when tag == EXPR_IN_LIST.
    var _in_list: Optional[InListData]
    # Correlated subquery
    # payload. Populated when tag == EXPR_CORRELATED_SUBQUERY.
    #
    # ⚠ THE `OwnedPointer` INDIRECTION IS A SIZE CHOICE. The payload holds an
    # `ErasedBox` — a fixed 4-word struct with no recursion visible to the type
    # system — so the indirection is not needed for recursion: `Expr` has ~20
    # Optional variant slots and is copied constantly, and inlining a payload
    # with three `String`/`List` fields into every one of them is not free.
    # ⛔ Do not remove it without measuring `sizeof[Expr]()`.
    var _corr_subq: Optional[OwnedPointer[CorrelatedSubqueryData]]
    # `regexp_*` payload. Populated when
    # tag == EXPR_REGEXP.
    var _regexp: Optional[RegexpData]
    # STRUCT field projection.
    # Populated when tag == EXPR_STRUCT_FIELD (by-name) /
    # EXPR_STRUCT_FIELD_IDX (by-idx, typed-DF emit). The dual-variant
    # design mirrors EXPR_COL_REF / EXPR_COL_IDX.
    var _struct_field: Optional[StructFieldData]
    var _struct_field_idx: Optional[StructFieldIdxData]
    # MAP[key] projection.
    # Populated when tag == EXPR_MAP_GET.  No comptime-idx twin (Map keys
    # are inherently runtime values — see header note).
    var _map_get: Optional[MapGetData]
    # Json_extract + SQL `->` / `->>` operators.
    # Populated when tag == EXPR_JSON_EXTRACT.
    var _json_extract: Optional[JsonExtractData]
    # Temporal field extract.
    # Populated when tag == EXPR_EXTRACT.
    var _extract: Optional[ExtractData]
    # Scalar floating-point math.
    # `_math_fn` populated when tag == EXPR_MATH_FN (unary sin/cos/sqrt/
    # asin/radians); `_math_fn2` populated when tag == EXPR_MATH_FN2
    # (binary atan2).
    var _math_fn: Optional[MathFnData]
    var _math_fn2: Optional[MathFn2Data]
    # Substring: `substring(s, start, length)`. Populated
    # when tag == EXPR_SUBSTRING.
    var _substring: Optional[SubstringData]
    # The unary scalar string functions. Populated
    # when tag == EXPR_STRING_FN.
    var _string_fn: Optional[StringFnData]
    # A registered scalar UDF applied to one expression.
    # Populated when tag == EXPR_UDF_CALL.
    var _udf_call: Optional[UdfCallData]
    # The multi-argument / variadic scalar string
    # functions. Populated when tag == EXPR_STRING_FN_N.
    var _string_fn_n: Optional[StringFnNData]

    # --- Private constructor (all fields) ---

    def __init__(out self, tag: UInt8):
        """Create an Expr with the given tag. All variant data is None."""
        self.tag = tag
        self._col_ref = None
        self._col_idx = None
        self._literal = None
        self._binary = None
        self._unary = None
        self._cast = None
        self._alias = None
        self._string_op = None
        self._when = None
        self._agg_fn = None
        self._window_fn = None
        self._in_list = None
        self._corr_subq = None
        self._regexp = None
        self._struct_field = None
        self._struct_field_idx = None
        self._map_get = None
        self._json_extract = None
        self._extract = None
        self._math_fn = None
        self._math_fn2 = None
        self._substring = None
        self._string_fn = None
        self._udf_call = None
        self._string_fn_n = None

    def copy(self) -> Self:
        """Deep copy of the expression tree.

        Tag-dispatches to the per-variant `*Data.copy()` method. Each
        variant's `copy()` recursively walks its OwnedPointer[Expr]
        children, so the resulting clone is fully byte-disjoint from
        the original.
        """
        var e = Expr(self.tag)
        if self.tag == EXPR_COL_REF:
            e._col_ref = self._col_ref.value().copy()
        elif self.tag == EXPR_COL_IDX:
            e._col_idx = self._col_idx.value().copy()
        elif self.tag == EXPR_LITERAL:
            e._literal = self._literal.value().copy()
        elif self.tag == EXPR_BINARY_OP:
            e._binary = self._binary.value().copy()
        elif self.tag == EXPR_UNARY_OP:
            e._unary = self._unary.value().copy()
        elif self.tag == EXPR_CAST:
            e._cast = self._cast.value().copy()
        elif self.tag == EXPR_ALIAS:
            e._alias = self._alias.value().copy()
        elif self.tag == EXPR_STRING_OP:
            e._string_op = self._string_op.value().copy()
        elif self.tag == EXPR_WHEN:
            e._when = self._when.value().copy()
        elif self.tag == EXPR_AGG_FN:
            e._agg_fn = self._agg_fn.value().copy()
        elif self.tag == EXPR_WINDOW_FN:
            e._window_fn = self._window_fn.value().copy()
        elif self.tag == EXPR_IN_LIST:
            e._in_list = self._in_list.value().copy()
        elif self.tag == EXPR_CORRELATED_SUBQUERY:
            # Correlated subquery: OwnedPointer deep-copy of the inner
            # plan tree. The cloned tree shares NO storage with the
            # original — same byte-disjoint discipline as the other
            # Optional[OwnedPointer[*Data]] variants on LogicalPlan.
            e._corr_subq = OwnedPointer(self._corr_subq.value()[].copy())
        elif self.tag == EXPR_REGEXP:
            e._regexp = self._regexp.value().copy()
        elif self.tag == EXPR_STRUCT_FIELD:
            e._struct_field = self._struct_field.value().copy()
        elif self.tag == EXPR_STRUCT_FIELD_IDX:
            e._struct_field_idx = self._struct_field_idx.value().copy()
        elif self.tag == EXPR_MAP_GET:
            e._map_get = self._map_get.value().copy()
        elif self.tag == EXPR_JSON_EXTRACT:
            e._json_extract = self._json_extract.value().copy()
        elif self.tag == EXPR_EXTRACT:
            e._extract = self._extract.value().copy()
        elif self.tag == EXPR_MATH_FN:
            e._math_fn = self._math_fn.value().copy()
        elif self.tag == EXPR_MATH_FN2:
            e._math_fn2 = self._math_fn2.value().copy()
        elif self.tag == EXPR_SUBSTRING:
            e._substring = self._substring.value().copy()
        elif self.tag == EXPR_STRING_FN:
            e._string_fn = self._string_fn.value().copy()
        elif self.tag == EXPR_UDF_CALL:
            e._udf_call = self._udf_call.value().copy()
        elif self.tag == EXPR_STRING_FN_N:
            e._string_fn_n = self._string_fn_n.value().copy()
        # else: unknown tag — return placeholder Expr(tag) as-is.
        return e^

    # --- Factory methods ---

    @staticmethod
    @always_inline
    def col_ref(name: String) -> Expr:
        """Create a column reference expression (by name)."""
        var e = Expr(EXPR_COL_REF)
        e._col_ref = ColRefData(name)
        return e^

    @staticmethod
    @always_inline
    def left(name: String) -> Expr:
        """A LEFT-input-qualified column reference.

        Only meaningful inside a join `predicate=` Expr (e.g.
        `Expr.left("l_orderkey") == Expr.right("l_orderkey")`). Reaching
        a non-join plan node with a side-qualified col-ref is an error
        surfaced by the optimizer / compiler.
        """
        var e = Expr(EXPR_COL_REF)
        e._col_ref = ColRefData(name, COL_SIDE_LEFT)
        return e^

    @staticmethod
    @always_inline
    def right(name: String) -> Expr:
        """A RIGHT-input-qualified column reference.

        See `Expr.left` for the contract; this is the right-hand-side
        twin used in join `predicate=` expressions.
        """
        var e = Expr(EXPR_COL_REF)
        e._col_ref = ColRefData(name, COL_SIDE_RIGHT)
        return e^

    @staticmethod
    @always_inline
    def col_idx(index: Int) -> Expr:
        """Create a column reference expression (by index, post-compilation only)."""
        var e = Expr(EXPR_COL_IDX)
        e._col_idx = ColIdxData(index)
        return e^

    @staticmethod
    @always_inline
    def literal(var value: ScalarValue) -> Expr:
        """Create a literal value expression."""
        var e = Expr(EXPR_LITERAL)
        e._literal = LiteralData(value^)
        return e^

    @staticmethod
    @always_inline
    def binary(op: UInt8, var left: Expr, var right: Expr) -> Expr:
        """Create a binary operation. Children are heap-allocated via OwnedPointer."""
        var e = Expr(EXPR_BINARY_OP)
        e._binary = BinaryOpData(op, left^, right^)
        return e^

    @staticmethod
    def binary_with_division_intent(
        op: UInt8, var left: Expr, var right: Expr, division_intent: UInt8
    ) -> Expr:
        """`Expr.binary` recording WHO decided an unbound division (see
        `BinaryOpData.division_intent`; the codes are `col_expr_division`'s)."""
        var e = Expr(EXPR_BINARY_OP)
        e._binary = BinaryOpData(op, left^, right^, division_intent)
        return e^

    @staticmethod
    @always_inline
    def unary(op: UInt8, var child: Expr) -> Expr:
        """Create a unary operation."""
        var e = Expr(EXPR_UNARY_OP)
        e._unary = UnaryOpData(op, child^)
        return e^

    @staticmethod
    @always_inline
    def cast(var child: Expr, target: DType) -> Expr:
        """Create a strict type cast expression (bad input RAISES)."""
        var e = Expr(EXPR_CAST)
        e._cast = CastData(child^, target)
        return e^

    @staticmethod
    @always_inline
    def try_cast(var child: Expr, target: DType) -> Expr:
        """Create a TRY_CAST expression — bad input yields NULL instead of
        raising. The TRY twin of `Expr.cast`."""
        var e = Expr(EXPR_CAST)
        e._cast = CastData(child^, target, True)
        return e^

    @staticmethod
    def cast_to_decimal(var child: Expr, precision: Int, scale: Int) raises -> Expr:
        """Create a `CAST(child AS DECIMAL(precision, scale))` expression.

        Enforces 0 <= scale <= precision <= 38 (negative scale out of scope).
        """
        if precision < 1 or precision > 38:
            raise Error("cast_to_decimal: precision must be in [1, 38], got " + String(precision))
        if scale < 0 or scale > precision:
            raise Error("cast_to_decimal: scale must be in [0, precision], got " + String(scale))
        var e = Expr(EXPR_CAST)
        e._cast = CastData(child^, DTYPE_NONE, ArrowType.DECIMAL128, precision, scale)
        return e^

    @staticmethod
    def cast_to_arrow(var child: Expr, target_arrow: ArrowType) -> Expr:
        """Create a cast expression that targets a specific Arrow logical type.

        Used when DType
        alone cannot express the target unit — e.g. `cast(int AS date32)`,
        `cast(int AS timestamp[us])`, `cast(ts[ms] AS ts[us])`. For ordinary
        numeric targets, prefer `Expr.cast()` — consumers that read
        `cast_target()` (a bare DType) rely on it.

        The physical `DType` is derived from `target_arrow` via
        `_arrow_to_physical_dtype` so that `cast_target()` returns a
        meaningful value (e.g. `int32` for DATE32; `int64` for TIMESTAMP_*).
        """
        var e = Expr(EXPR_CAST)
        var phys_dtype = _arrow_to_physical_dtype(target_arrow)
        e._cast = CastData(child^, phys_dtype, target_arrow, 0, 0)
        return e^

    @staticmethod
    def cast_preserving_arrow(var child: Expr, src_expr: Expr) -> Expr:
        """Rebuild an EXPR_CAST node from a source cast, preserving both the
        DType target AND the ArrowType target (and decimal precision/scale).

        Optimizer / compiler rewrite sites use this rather than
        `Expr.cast(child^, src.cast_target())`, which silently drops
        `target_arrow` AND `decimal_precision/scale`. For ordinary numeric
        casts that round-trip is byte-identical to the original (because
        `target_arrow` is auto-derived from DType in
        `CastData.__init__(child, target)`), but for temporal targets
        (DATE32 / TIMESTAMP_*) or DECIMAL128 it is a latent bug.
        """
        var e = Expr(EXPR_CAST)
        e._cast = CastData(
            child^,
            src_expr.cast_target(),
            src_expr.cast_target_arrow(),
            src_expr.cast_decimal_precision(),
            src_expr.cast_decimal_scale(),
            src_expr.cast_is_try(),
        )
        return e^

    @staticmethod
    def cast_from_parts(
        var child: Expr,
        target: DType,
        target_arrow: ArrowType,
        decimal_precision: Int,
        decimal_scale: Int,
        try_cast: Bool,
    ) -> Expr:
        """Rebuild an EXPR_CAST from all SIX of `CastData`'s parts — the exact
        inverse of the five `cast_*` accessors above.

        ⚠ WHY THIS EXISTS WHEN FIVE CAST FACTORIES ALREADY DO. Every other
        factory DERIVES some of the six from the others: `cast`/`try_cast`
        derive `target_arrow` from `target` and pin the decimal pair to 0,
        `cast_to_decimal` pins `target` to `invalid`, `cast_to_arrow` derives
        `target` from `target_arrow`, and `cast_preserving_arrow` needs a cast
        Expr it does not have. A DECODER does not get to choose its input: it
        is handed six values and must produce the node they name, and a
        case-analysis over five partial factories is not total — it fails on
        the first combination none of them can express (a TRY_CAST to
        DECIMAL(p,s), for one).

        The five factories stay the surface a QUERY is written against; this
        one is the surface a PLAN is rebuilt through. Its first caller is
        `komira_plan_wire`'s `_expr_from_wire`, which is why it takes the
        parts positionally in `CastData`'s own declaration order.
        """
        var e = Expr(EXPR_CAST)
        e._cast = CastData(
            child^, target, target_arrow, decimal_precision, decimal_scale,
            try_cast,
        )
        return e^

    @always_inline
    def cast_target_arrow(self) -> ArrowType:
        """Get the target ArrowType. Requires tag == EXPR_CAST."""
        return self._cast.value().target_arrow

    @always_inline
    def cast_is_try(self) -> Bool:
        """True if this is a TRY_CAST (null-on-failure). Requires
        tag == EXPR_CAST."""
        return self._cast.value().try_cast

    @always_inline
    def cast_decimal_precision(self) -> Int:
        """Target decimal precision (0 unless casting to DECIMAL128)."""
        return self._cast.value().decimal_precision

    @always_inline
    def cast_decimal_scale(self) -> Int:
        """Target decimal scale (0 unless casting to DECIMAL128)."""
        return self._cast.value().decimal_scale

    @staticmethod
    @always_inline
    def alias(var child: Expr, name: String) -> Expr:
        """Create an alias (rename) expression."""
        var e = Expr(EXPR_ALIAS)
        e._alias = AliasData(child^, name)
        return e^

    @staticmethod
    @always_inline
    def string_op(op: UInt8, var child: Expr, pattern: String) -> Expr:
        """Create a string operation expression (CONTAINS, STARTS_WITH, etc.)."""
        var e = Expr(EXPR_STRING_OP)
        e._string_op = StringOpData(op, child^, pattern)
        return e^

    @staticmethod
    @always_inline
    def substring(var child: Expr, start: Int, length: Int = -1) -> Expr:
        """Create an `EXPR_SUBSTRING` node — SQL `substring(child, start, length)`
        over a string-column child (1-based `start`).

        ⚠ A NEGATIVE `length` IS A SENTINEL FAMILY, not one value: `-1` is "to
        end of string" (the default, i.e. the two-argument form) and `-k` for
        k >= 2 is "to end, dropping k-1 trailing CHARACTERS" — the encoding
        `left(s, NEGATIVE)` desugars to. ⛔ It is NOT DuckDB's negative-length
        semantics (a BACKWARD window from `start`), so a SQL binder must keep
        refusing a negative `length` LITERAL. The arithmetic is at one site,
        in the plan compiler's column evaluator (not in this tree)."""
        var e = Expr(EXPR_SUBSTRING)
        e._substring = SubstringData(child^, start, length)
        return e^

    # --- `regexp_*` factories ---

    @staticmethod
    @always_inline
    def regexp(op: UInt8, var child: Expr, pattern: String, replacement: String = "", flags: String = "", group: Int = 0, group_name: String = "") -> Expr:
        """Create an `EXPR_REGEXP` node. `op` is one of REGEXP_LIKE / REGEXP_MATCH /
        REGEXP_REPLACE / REGEXP_EXTRACT / ... `group_name` (only meaningful for
        REGEXP_EXTRACT) names a `(?P<name>...)` capture group; the executor
        resolves it to the group index at execution time."""
        var e = Expr(EXPR_REGEXP)
        e._regexp = RegexpData(op, child^, pattern, replacement, flags, group, group_name)
        return e^

    @staticmethod
    @always_inline
    def regexp_like(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_like(child, pattern[, flags])` -> Bool (unanchored). Also the
        lowering target for `regexp_matches` / `~`."""
        return Expr.regexp(REGEXP_LIKE, child^, pattern, "", flags, 0)

    @staticmethod
    @always_inline
    def regexp_extract(var child: Expr, pattern: String, group: Int = 0, flags: String = "") -> Expr:
        """`regexp_extract(child, pattern[, group])` -> Utf8. `group` defaults to 0
        (= the whole match); no match / non-participating group -> ''."""
        return Expr.regexp(REGEXP_EXTRACT, child^, pattern, "", flags, group)

    @staticmethod
    @always_inline
    def regexp_extract_named(var child: Expr, pattern: String, group_name: String, flags: String = "") -> Expr:
        """`regexp_extract(child, pattern, group="name")` -> Utf8. Extracts the
        substring matched by the `(?P<name>...)` capture group. The name is
        resolved to the group index at execution time (the pattern is only
        compiled then); referencing a name that does not exist in `pattern`
        raises at execution time. No match / non-participating group -> ''."""
        return Expr.regexp(REGEXP_EXTRACT, child^, pattern, "", flags, 0, group_name)

    @staticmethod
    @always_inline
    def regexp_replace(var child: Expr, pattern: String, replacement: String, flags: String = "") -> Expr:
        """`regexp_replace(child, pattern, replacement[, flags])` -> Utf8. Replaces
        the FIRST match by default, ALL non-overlapping matches when `flags`
        contains `g`. Replacement template uses RE2/PostgreSQL `\\N` backref
        syntax (`\\0` = whole match, `\\1`..`\\9` = capture groups, `\\\\` =
        literal backslash) — NOT DataFusion's `$N`. An invalid template -> the
        input is returned unchanged (matches DuckDB)."""
        return Expr.regexp(REGEXP_REPLACE, child^, pattern, replacement, flags, 0)

    @staticmethod
    @always_inline
    def regexp_match(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_match(child, pattern[, flags])` -> List<Utf8>. Captured-group
        substrings of the first match ([whole_match] if the pattern has no
        groups); NULL list on no match."""
        return Expr.regexp(REGEXP_MATCH, child^, pattern, "", flags, 0)

    @staticmethod
    @always_inline
    def regexp_split_to_array(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_split_to_array(child, pattern[, flags])` -> List<Utf8>. The
        between-match substrings of the (non-overlapping) matches."""
        return Expr.regexp(REGEXP_SPLIT_TO_ARRAY, child^, pattern, "", flags, 0)

    @staticmethod
    @always_inline
    def regexp_extract_all(var child: Expr, pattern: String, group: Int = 0, flags: String = "") -> Expr:
        """`regexp_extract_all(child, pattern[, group])` -> List<Utf8>. The
        captured-group substring of every (non-overlapping) match; `group`
        defaults to 0 (= whole match)."""
        return Expr.regexp(REGEXP_EXTRACT_ALL, child^, pattern, "", flags, group)

    @staticmethod
    @always_inline
    def regexp_count(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_count(child, pattern[, flags])` -> Int64. Number of
        non-overlapping matches (PostgreSQL semantics; no match -> 0). NULL
        input row -> NULL."""
        return Expr.regexp(REGEXP_COUNT, child^, pattern, "", flags, 0)

    @staticmethod
    @always_inline
    def regexp_instr(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_instr(child, pattern[, flags])` -> Int64. 1-based byte
        position of the first match (0 if no match; PostgreSQL semantics).
        NULL input row -> NULL."""
        return Expr.regexp(REGEXP_INSTR, child^, pattern, "", flags, 0)

    @staticmethod
    @always_inline
    def regexp_substr(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_substr(child, pattern[, flags])` -> Utf8. The first matched
        substring (NULL if no match — PostgreSQL/Oracle semantics; note this
        differs from `regexp_extract` which returns ''). NULL input row -> NULL.
        """
        return Expr.regexp(REGEXP_SUBSTR, child^, pattern, "", flags, 0)

    @staticmethod
    @always_inline
    def regexp_full_match(var child: Expr, pattern: String, flags: String = "") -> Expr:
        """`regexp_full_match(child, pattern[, flags])` -> Bool. True iff the
        ENTIRE string matches `pattern` (anchored both ends — implemented by
        wrapping the pattern in `\\A(?:...)\\z`; DuckDB semantics). NULL input
        row -> NULL."""
        return Expr.regexp(REGEXP_FULL_MATCH, child^, pattern, "", flags, 0)

    @always_inline
    def is_regexp(self) -> Bool:
        """True if tag == EXPR_REGEXP."""
        return self.tag == EXPR_REGEXP

    # --- STRUCT field projection ---
    # Dual variant: by-name (`EXPR_STRUCT_FIELD`, untyped DF surface) +
    # by-idx (`EXPR_STRUCT_FIELD_IDX`, typed DF comptime-resolved emit).

    @staticmethod
    @always_inline
    def struct_field(var parent: Expr, field_name: String) -> Expr:
        """Create an `EXPR_STRUCT_FIELD` node (by-name) that extracts
        `field_name` out of the STRUCT-typed result of `parent`.

        User-facing entry point is `col(...).field(name)` in col_expr.mojo.
        Field resolution is by linear-scan of `_field_names` at eval time
        — composable, schema-agnostic.
        """
        var e = Expr(EXPR_STRUCT_FIELD)
        e._struct_field = StructFieldData(parent^, field_name)
        return e^

    @staticmethod
    @always_inline
    def struct_field_idx(var parent: Expr, field_idx: Int) -> Expr:
        """Create an `EXPR_STRUCT_FIELD_IDX` node (by-index) that extracts
        `_children[field_idx]` out of the STRUCT-typed result of `parent`.

        User-facing entry point is `TypedDataFrame.field[parent, name]()`,
        which comptime-resolves `field_idx` from the typed schema via
        `comptime_struct_field_index[S, parent, name]()`. The runtime arm
        skips the `_field_names` scan and indexes `_children` directly.
        """
        var e = Expr(EXPR_STRUCT_FIELD_IDX)
        e._struct_field_idx = StructFieldIdxData(parent^, field_idx)
        return e^

    @always_inline
    def is_struct_field(self) -> Bool:
        """True if tag == EXPR_STRUCT_FIELD (by-name variant)."""
        return self.tag == EXPR_STRUCT_FIELD

    @always_inline
    def is_struct_field_idx(self) -> Bool:
        """True if tag == EXPR_STRUCT_FIELD_IDX (by-idx variant)."""
        return self.tag == EXPR_STRUCT_FIELD_IDX

    @always_inline
    def struct_field_parent_ref(self) -> ref [origin_of(self._struct_field.value().parent[])] Expr:
        """Reference to the parent expression (must evaluate to STRUCT).
        Requires tag == EXPR_STRUCT_FIELD."""
        return self._struct_field.value().parent[]

    @always_inline
    def struct_field_name(self) -> String:
        """Field name to extract. Requires tag == EXPR_STRUCT_FIELD."""
        return self._struct_field.value().field_name.copy()

    @always_inline
    def struct_field_idx_parent_ref(self) -> ref [origin_of(self._struct_field_idx.value().parent[])] Expr:
        """Reference to the parent expression (must evaluate to STRUCT).
        Requires tag == EXPR_STRUCT_FIELD_IDX."""
        return self._struct_field_idx.value().parent[]

    @always_inline
    def struct_field_index(self) -> Int:
        """Field index to extract. Requires tag == EXPR_STRUCT_FIELD_IDX."""
        return self._struct_field_idx.value().field_idx

    # --- MAP[key] projection ---

    @staticmethod
    @always_inline
    def map_get(var parent: Expr, var key: Expr) -> Expr:
        """Create an `EXPR_MAP_GET` node — per-row dynamic key lookup against
        a MAP-typed parent.

        `key` is itself an Expr: it may be a `lit("foo")` for a constant
        key, or a `col("which_key")` for a per-row key, or any other Expr
        that evaluates to a scalar-or-column of the Map's key type.

        User-facing entry point:
          - `col("metadata").get(lit("city"))` (in col_expr.mojo).
        """
        var e = Expr(EXPR_MAP_GET)
        e._map_get = MapGetData(parent^, key^)
        return e^

    @always_inline
    def is_map_get(self) -> Bool:
        """True if tag == EXPR_MAP_GET."""
        return self.tag == EXPR_MAP_GET

    @always_inline
    def map_get_parent_ref(self) -> ref [origin_of(self._map_get.value().parent[])] Expr:
        """Reference to the parent expression (must evaluate to MAP).
        Requires tag == EXPR_MAP_GET."""
        return self._map_get.value().parent[]

    @always_inline
    def map_get_key_ref(self) -> ref [origin_of(self._map_get.value().key[])] Expr:
        """Reference to the key expression.  Requires tag == EXPR_MAP_GET."""
        return self._map_get.value().key[]

    # --- json_extract + `->` / `->>` ---

    @staticmethod
    def json_extract_json(var parent: Expr, path: String) raises -> Expr:
        """Create an `EXPR_JSON_EXTRACT` node with `preserve_extension_metadata=True`.

        Lowers SQL `parent -> path` (or Mojo `parent >> key` operator).
        Output is Arrow STRING with `ARROW:extension:name = "komira.ext.json"`
        extension metadata.

        ⚠ THE `ext.` SEGMENT IS LOAD-BEARING AND THE TWO-SEGMENT FORM COLLIDES.
        Written as `komira.json` it is ALREADY TAKEN, by
        `SCAN_KIND_NAME_JSON` (`komira_scan_source/scan_binding.mojo`) -- a wire
        constant whose FNV id names a scan kind. One literal would then mean two
        things: "this column holds JSON text" and "this table is read by the JSON
        scan kind". Scan kinds occupy `komira.<format>`; every Arrow extension
        type this repo defines goes under `komira.ext.<name>`, so the two
        namespaces cannot collide again as formats are added. ⛔ Do not
        "simplify" it back to a two-segment name.

        `path` is parsed into segments at factory time (e.g. `$.user.id`
        -> `["user", "id"]`). Malformed paths raise here, NOT at eval.
        """
        var segs = parse_json_path(path)
        var e = Expr(EXPR_JSON_EXTRACT)
        e._json_extract = JsonExtractData(parent^, segs^, ArrowType.STRING, True)
        return e^

    @staticmethod
    def json_extract_string(var parent: Expr, path: String) raises -> Expr:
        """Create an `EXPR_JSON_EXTRACT` node with `preserve_extension_metadata=False`.

        Lowers SQL `parent ->> path` (or Mojo `parent.extract_text(key)`
        method). Output is plain Arrow STRING with NO extension metadata
        Byte content is identical to `json_extract_json`
        for non-string scalars; the diff is purely in extension metadata.
        """
        var segs = parse_json_path(path)
        var e = Expr(EXPR_JSON_EXTRACT)
        e._json_extract = JsonExtractData(parent^, segs^, ArrowType.STRING, False)
        return e^

    @staticmethod
    def json_extract_from_parts(
        var parent: Expr,
        var path_segments: List[String],
        output_type: ArrowType,
        preserve_extension_metadata: Bool,
    ) -> Expr:
        """Rebuild an EXPR_JSON_EXTRACT from all FOUR of `JsonExtractData`'s
        parts — the exact inverse of the four `json_extract_*` accessors above.

        ⚠ WHY THIS EXISTS WHEN TWO JSON FACTORIES ALREADY DO. Both of them
        DERIVE two of the four: `output_type` is pinned to `ArrowType.STRING`
        and `path_segments` is re-parsed out of a `$.a.b` string by
        `parse_json_path`. A DECODER does not get to choose its input — it is
        handed four values and must produce the node they name — and neither
        derivation is safe for it:

          * `output_type` is invisible to EVERY other check. `Expr.write_to`
            does not print it, and `_infer_expr_field` has no
            EXPR_JSON_EXTRACT arm at all, so the node types as
            `ArrowType.NULL` regardless. A decoder that re-derived STRING
            would therefore agree with a correct one on every plan that
            exists and silently truncate a typed `json_extract[Int64]` the
            day one is served. This is the bug
            `Expr.cast_preserving_arrow` exists to fix, one node over.

          * `path_segments` is STRICTLY MORE PRECISE than the joined path.
            `parse_json_path` cannot produce a segment containing a `.`
            (it is the separator), so `["a.b"]` is a segment list no string
            round-trips back to — re-parsing would silently split it in two.

        The two `json_extract_*` factories stay the surface a QUERY is written
        against; this one is the surface a PLAN is rebuilt through. Its first
        caller is `komira_plan_wire`'s `_expr_from_wire`, which is why it
        takes the parts positionally in `JsonExtractData`'s own declaration
        order. Same shape, and same reason, as `Expr.cast_from_parts`.
        """
        var e = Expr(EXPR_JSON_EXTRACT)
        e._json_extract = JsonExtractData(
            parent^, path_segments^, output_type, preserve_extension_metadata
        )
        return e^

    @always_inline
    def is_json_extract(self) -> Bool:
        """True if tag == EXPR_JSON_EXTRACT."""
        return self.tag == EXPR_JSON_EXTRACT

    @always_inline
    def json_extract_parent_ref(self) -> ref [origin_of(self._json_extract.value().parent[])] Expr:
        """Reference to the parent expression (must evaluate to STRING).
        Requires tag == EXPR_JSON_EXTRACT."""
        return self._json_extract.value().parent[]

    def json_extract_path_segments(self) -> List[String]:
        """Copy of the parsed JSONPath segments. Requires tag == EXPR_JSON_EXTRACT."""
        var segs = List[String]()
        ref payload = self._json_extract.value()
        for i in range(len(payload.path_segments)):
            segs.append(payload.path_segments[i].copy())
        return segs^

    @always_inline
    def json_extract_output_type(self) -> ArrowType:
        """Target Arrow type for the extracted column. Requires tag == EXPR_JSON_EXTRACT."""
        return self._json_extract.value().output_type

    @always_inline
    def json_extract_preserve_extension_metadata(self) -> Bool:
        """True if `->` semantics (preserve `komira.ext.json` ext metadata); False if `->>`.
        Requires tag == EXPR_JSON_EXTRACT."""
        return self._json_extract.value().preserve_extension_metadata

    # --- temporal extract ---

    @staticmethod
    @always_inline
    def extract(unit: UInt8, var child: Expr) -> Expr:
        """Create an `EXPR_EXTRACT` node carrying a temporal field selector.

        `unit` is one of the `EXTRACT_*` (field) or `EXTRACT_TRUNC_*`
        (date_trunc family) constants.  `child` must evaluate to a
        DATE32 or TIMESTAMP_* Column at eval time.
        """
        var e = Expr(EXPR_EXTRACT)
        e._extract = ExtractData(child^, unit)
        return e^

    @staticmethod
    @always_inline
    def year(var child: Expr) -> Expr:
        """`year(child)` — extract calendar year from a DATE32 / TIMESTAMP_*."""
        return Expr.extract(EXTRACT_YEAR, child^)

    @staticmethod
    @always_inline
    def month(var child: Expr) -> Expr:
        """`month(child)` — extract calendar month [1..12]."""
        return Expr.extract(EXTRACT_MONTH, child^)

    @staticmethod
    @always_inline
    def day(var child: Expr) -> Expr:
        """`day(child)` — extract calendar day [1..31]."""
        return Expr.extract(EXTRACT_DAY, child^)

    @staticmethod
    @always_inline
    def hour(var child: Expr) -> Expr:
        """`hour(child)` — extract clock hour [0..23] from a TIMESTAMP_*.
        Raises at eval time when child is DATE32 (no sub-day field)."""
        return Expr.extract(EXTRACT_HOUR, child^)

    @staticmethod
    @always_inline
    def minute(var child: Expr) -> Expr:
        """`minute(child)` — extract clock minute [0..59] from a TIMESTAMP_*."""
        return Expr.extract(EXTRACT_MINUTE, child^)

    @staticmethod
    @always_inline
    def second(var child: Expr) -> Expr:
        """`second(child)` — extract clock second [0..59] from a TIMESTAMP_*."""
        return Expr.extract(EXTRACT_SECOND, child^)

    @staticmethod
    @always_inline
    def quarter(var child: Expr) -> Expr:
        """`quarter(child)` — extract calendar quarter [1..4]."""
        return Expr.extract(EXTRACT_QUARTER, child^)

    @staticmethod
    @always_inline
    def date_trunc(unit: UInt8, var child: Expr) -> Expr:
        """`date_trunc(unit, child)` — round down to period start.

        `unit` is one of the EXTRACT_TRUNC_* constants.  Returns a
        Column of the same logical type as `child` (DATE32 for DATE32
        input; same TIMESTAMP_* unit for TIMESTAMP_* input)."""
        return Expr.extract(unit, child^)

    @always_inline
    def is_extract(self) -> Bool:
        """True if tag == EXPR_EXTRACT."""
        return self.tag == EXPR_EXTRACT

    @always_inline
    def extract_child_ref(self) -> ref [origin_of(self._extract.value().child[])] Expr:
        """Reference to the child expression (must evaluate to DATE32 or
        TIMESTAMP_*).  Requires tag == EXPR_EXTRACT."""
        return self._extract.value().child[]

    @always_inline
    def extract_unit(self) -> UInt8:
        """Unit selector (EXTRACT_YEAR / ... / EXTRACT_TRUNC_*).
        Requires tag == EXPR_EXTRACT."""
        return self._extract.value().unit

    # --- Scalar math factories + accessors ---

    @staticmethod
    @always_inline
    def math_fn(op: UInt8, var child: Expr) -> Expr:
        """Create an `EXPR_MATH_FN` node (unary scalar math).

        `op` is one of the `MATH_*` constants. `child` evaluates to a numeric
        Column; the result is a FLOAT64 Column (null in -> null out) for EVERY
        member — this family's output type is per-TAG, unlike `EXPR_STRING_FN`
        where it is per-op.
        """
        var e = Expr(EXPR_MATH_FN)
        e._math_fn = MathFnData(op, child^)
        return e^

    @staticmethod
    @always_inline
    def sin(var child: Expr) -> Expr:
        """`sin(child)` — sine of a numeric column (radians) -> FLOAT64."""
        return Expr.math_fn(MATH_SIN, child^)

    @staticmethod
    @always_inline
    def cos(var child: Expr) -> Expr:
        """`cos(child)` — cosine of a numeric column (radians) -> FLOAT64."""
        return Expr.math_fn(MATH_COS, child^)

    @staticmethod
    @always_inline
    def sqrt(var child: Expr) -> Expr:
        """`sqrt(child)` — square root of a numeric column -> FLOAT64."""
        return Expr.math_fn(MATH_SQRT, child^)

    @staticmethod
    @always_inline
    def asin(var child: Expr) -> Expr:
        """`asin(child)` — arcsine of a numeric column -> FLOAT64 (radians)."""
        return Expr.math_fn(MATH_ASIN, child^)

    @staticmethod
    @always_inline
    def radians(var child: Expr) -> Expr:
        """`radians(child)` — convert degrees to radians -> FLOAT64."""
        return Expr.math_fn(MATH_RADIANS, child^)

    # The DOUBLE-returning free riders. Every
    # one is FLOAT64-out in DuckDB v1.5.3 over integer input too (measured), so
    # the always-FLOAT64 tag is exact rather than approximate.
    @staticmethod
    @always_inline
    def ceil(var child: Expr) -> Expr:
        """`ceil(child)` -> FLOAT64 (DOUBLE in DuckDB, over INT input too)."""
        return Expr.math_fn(MATH_CEIL, child^)

    @staticmethod
    @always_inline
    def floor(var child: Expr) -> Expr:
        """`floor(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_FLOOR, child^)

    @staticmethod
    @always_inline
    def ln(var child: Expr) -> Expr:
        """`ln(child)` — natural log -> FLOAT64."""
        return Expr.math_fn(MATH_LN, child^)

    @staticmethod
    @always_inline
    def exp(var child: Expr) -> Expr:
        """`exp(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_EXP, child^)

    @staticmethod
    @always_inline
    def log10(var child: Expr) -> Expr:
        """`log10(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_LOG10, child^)

    @staticmethod
    @always_inline
    def log2(var child: Expr) -> Expr:
        """`log2(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_LOG2, child^)

    @staticmethod
    @always_inline
    def tan(var child: Expr) -> Expr:
        """`tan(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_TAN, child^)

    @staticmethod
    @always_inline
    def atan(var child: Expr) -> Expr:
        """`atan(child)` -> FLOAT64 (radians)."""
        return Expr.math_fn(MATH_ATAN, child^)

    @staticmethod
    @always_inline
    def acos(var child: Expr) -> Expr:
        """`acos(child)` -> FLOAT64 (radians)."""
        return Expr.math_fn(MATH_ACOS, child^)

    @staticmethod
    @always_inline
    def cot(var child: Expr) -> Expr:
        """`cot(child)` — cotangent, `1/tan` -> FLOAT64."""
        return Expr.math_fn(MATH_COT, child^)

    @staticmethod
    @always_inline
    def degrees(var child: Expr) -> Expr:
        """`degrees(child)` — radians to degrees -> FLOAT64."""
        return Expr.math_fn(MATH_DEGREES, child^)

    @staticmethod
    @always_inline
    def cbrt(var child: Expr) -> Expr:
        """`cbrt(child)` — cube root -> FLOAT64."""
        return Expr.math_fn(MATH_CBRT, child^)

    @staticmethod
    @always_inline
    def sinh(var child: Expr) -> Expr:
        """`sinh(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_SINH, child^)

    @staticmethod
    @always_inline
    def cosh(var child: Expr) -> Expr:
        """`cosh(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_COSH, child^)

    @staticmethod
    @always_inline
    def tanh(var child: Expr) -> Expr:
        """`tanh(child)` -> FLOAT64."""
        return Expr.math_fn(MATH_TANH, child^)

    @staticmethod
    @always_inline
    def acosh(var child: Expr) -> Expr:
        """`acosh(child)` -> FLOAT64. Inverse hyperbolic cosine.

        ⚠ `acosh(x)` for `x < 1` is NaN here and NaN in libm; DuckDB v1.5.3
        also answers NaN (measured: `acosh(0.5)` = nan, NOT an error) — unlike
        `acos`, which RAISES outside [-1,1] there. The two are not symmetric
        and this one happens to agree.
        """
        return Expr.math_fn(MATH_ACOSH, child^)

    @staticmethod
    @always_inline
    def asinh(var child: Expr) -> Expr:
        """`asinh(child)` -> FLOAT64. Inverse hyperbolic sine, total on R."""
        return Expr.math_fn(MATH_ASINH, child^)

    @staticmethod
    @always_inline
    def atanh(var child: Expr) -> Expr:
        """`atanh(child)` -> FLOAT64. Inverse hyperbolic tangent.

        ⚠ STATED DIVERGENCE, MEASURED: DuckDB v1.5.3 RAISES `Invalid Input
        Error: ATANH is undefined outside [-1,1]` for `|x| > 1` and answers
        `inf` at exactly `|x| = 1`; libm returns NaN and inf respectively with
        no error. This engine follows libm, which is the SAME convention it
        already follows for `sqrt(-1)`, `ln(0)`, `acos(2)` and `asin(2)` — all
        four of which raise in DuckDB and return NaN/-inf here. This is an
        engine-wide pre-existing class, not a new one introduced by this op.
        """
        return Expr.math_fn(MATH_ATANH, child^)

    @staticmethod
    @always_inline
    def gamma(var child: Expr) -> Expr:
        """`gamma(child)` -> FLOAT64. The gamma function, libm `tgamma`.

        ⚠ NOT `lgamma`, and NOT a factorial: `gamma(5.0)` = 24.0 = 4!, i.e.
        `gamma(n) = (n-1)!`. Measured identical in DuckDB v1.5.3 and CPython.
        `gamma(0.0)` raises in DuckDB and is `inf` here — the same libm-vs-raise
        class as `atanh` above.
        """
        return Expr.math_fn(MATH_GAMMA, child^)

    @staticmethod
    @always_inline
    def string_fn(op: UInt8, var child: Expr) -> Expr:
        """Create an `EXPR_STRING_FN` node (unary scalar string function).

        `op` is one of the `STRFN_*` constants. `child` evaluates to a STRING
        or DICTIONARY Column; the output type is per-op
        (`string_fn_returns_int`).
        """
        var e = Expr(EXPR_STRING_FN)
        e._string_fn = StringFnData(op, child^)
        return e^

    @staticmethod
    @always_inline
    def upper(var child: Expr) -> Expr:
        """`upper(child)` — ASCII upper-case of a string column -> Utf8."""
        return Expr.string_fn(STRFN_UPPER, child^)

    @staticmethod
    @always_inline
    def lower(var child: Expr) -> Expr:
        """`lower(child)` — ASCII lower-case of a string column -> Utf8."""
        return Expr.string_fn(STRFN_LOWER, child^)

    @staticmethod
    @always_inline
    def trim(var child: Expr) -> Expr:
        """`trim(child)` — strip leading+trailing SPACES (0x20 only) -> Utf8."""
        return Expr.string_fn(STRFN_TRIM, child^)

    @staticmethod
    @always_inline
    def ltrim(var child: Expr) -> Expr:
        """`ltrim(child)` — strip leading SPACES -> Utf8."""
        return Expr.string_fn(STRFN_LTRIM, child^)

    @staticmethod
    @always_inline
    def rtrim(var child: Expr) -> Expr:
        """`rtrim(child)` — strip trailing SPACES -> Utf8."""
        return Expr.string_fn(STRFN_RTRIM, child^)

    @staticmethod
    @always_inline
    def length(var child: Expr) -> Expr:
        """`length(child)` — UTF-8 CHARACTER count -> INT64 (not bytes)."""
        return Expr.string_fn(STRFN_LENGTH, child^)

    @staticmethod
    @always_inline
    def reverse(var child: Expr) -> Expr:
        """`reverse(child)` — reverse CODEPOINT order -> Utf8."""
        return Expr.string_fn(STRFN_REVERSE, child^)

    @staticmethod
    @always_inline
    def ascii(var child: Expr) -> Expr:
        """`ascii(child)` — CODEPOINT of the first character -> INT64, 0 on ''."""
        return Expr.string_fn(STRFN_ASCII, child^)

    @staticmethod
    @always_inline
    def unicode(var child: Expr) -> Expr:
        """`unicode(child)` / `ord(child)` — first CODEPOINT -> INT64, -1 on ''."""
        return Expr.string_fn(STRFN_UNICODE, child^)

    @staticmethod
    @always_inline
    def strlen(var child: Expr) -> Expr:
        """`strlen(child)` — UTF-8 BYTE count -> INT64. NOT `length`."""
        return Expr.string_fn(STRFN_STRLEN, child^)

    @staticmethod
    @always_inline
    def bit_length(var child: Expr) -> Expr:
        """`bit_length(child)` — UTF-8 byte count * 8 -> INT64."""
        return Expr.string_fn(STRFN_BIT_LENGTH, child^)

    @always_inline
    def is_string_fn(self) -> Bool:
        """True if tag == EXPR_STRING_FN."""
        return self.tag == EXPR_STRING_FN

    @always_inline
    def string_fn_op(self) -> UInt8:
        """Unary string op (STRFN_*). Requires tag == EXPR_STRING_FN."""
        return self._string_fn.value().op

    @always_inline
    def string_fn_child_ref(self) -> ref [origin_of(self._string_fn.value().child[])] Expr:
        """Ref to the unary string-fn child. Requires tag == EXPR_STRING_FN."""
        return self._string_fn.value().child[]

    # -- the variadic string family ------------

    @staticmethod
    @always_inline
    def string_fn_n(op: UInt8, var args: List[Expr]) -> Expr:
        """Create an `EXPR_STRING_FN_N` node (multi-argument string function).

        `op` is one of the `STRFNN_*` constants; `args` is every operand in
        SOURCE ORDER. The output type is per-op (`string_fn_n_returns_int`).

        ⛔ NON-RAISING, SO IT DOES NOT CHECK THE ARITY. Every `Expr` factory in
        this file is non-raising and this one may not be the exception —
        `LogicalPlan.project` synthesizes a schema through a non-raising walk,
        so a raising factory would have nowhere to be called from. Producers
        check `string_fn_n_arity_ok` in their own raising context; the
        evaluator checks it again and refuses BY NAME.
        """
        var e = Expr(EXPR_STRING_FN_N)
        e._string_fn_n = StringFnNData(op, args^)
        return e^

    @staticmethod
    def concat(var args: List[Expr]) -> Expr:
        """`concat(a, b, ...)` — NULL arguments are SKIPPED, not propagated."""
        return Expr.string_fn_n(STRFNN_CONCAT, args^)

    @staticmethod
    def concat_ws(var args: List[Expr]) -> Expr:
        """`concat_ws(sep, a, ...)` — `args[0]` IS THE SEPARATOR.

        A NULL separator makes the row NULL; a NULL value is skipped along
        with its separator. See `STRFNN_CONCAT_WS`."""
        return Expr.string_fn_n(STRFNN_CONCAT_WS, args^)

    @staticmethod
    def replace_str(var s: Expr, var source: Expr, var target: Expr) -> Expr:
        """`replace(s, source, target)` — non-overlapping, left to right.

        ⚠ NAMED `replace_str` AND NOT `replace`: `regexp_replace` is a
        DIFFERENT function on `EXPR_REGEXP`, and a bare `replace` on this type
        would read as either. The SQL name is `replace`; only the Mojo
        factory carries the suffix."""
        var args = List[Expr]()
        args.append(s^)
        args.append(source^)
        args.append(target^)
        return Expr.string_fn_n(STRFNN_REPLACE, args^)

    @staticmethod
    def lpad(var s: Expr, var count: Expr, var pad: Expr) -> Expr:
        """`lpad(s, count, pad)` — CHARACTER-based; truncates when
        `count < length(s)`; RAISES at eval on an empty `pad` that is
        actually needed."""
        var args = List[Expr]()
        args.append(s^)
        args.append(count^)
        args.append(pad^)
        return Expr.string_fn_n(STRFNN_LPAD, args^)

    @staticmethod
    def rpad(var s: Expr, var count: Expr, var pad: Expr) -> Expr:
        """`rpad(s, count, pad)` — the right-hand twin of `lpad`."""
        var args = List[Expr]()
        args.append(s^)
        args.append(count^)
        args.append(pad^)
        return Expr.string_fn_n(STRFNN_RPAD, args^)

    @staticmethod
    def repeat(var s: Expr, var count: Expr) -> Expr:
        """`repeat(s, count)` — `count <= 0` gives the empty string."""
        var args = List[Expr]()
        args.append(s^)
        args.append(count^)
        return Expr.string_fn_n(STRFNN_REPEAT, args^)

    @staticmethod
    def strpos(var haystack: Expr, var needle: Expr) -> Expr:
        """`strpos(haystack, needle)` — 1-based CHARACTER position, 0 if
        absent. INT64-returning, the only member of this family that is."""
        var args = List[Expr]()
        args.append(haystack^)
        args.append(needle^)
        return Expr.string_fn_n(STRFNN_STRPOS, args^)

    @staticmethod
    def levenshtein(var a: Expr, var b: Expr) -> Expr:
        """`levenshtein(a, b)` — BYTE edit distance -> INT64. Aliases
        `editdist3`. ⛔ NO transposition: `levenshtein('ab','ba')` = 2."""
        var args = List[Expr]()
        args.append(a^)
        args.append(b^)
        return Expr.string_fn_n(STRFNN_LEVENSHTEIN, args^)

    @staticmethod
    def damerau_levenshtein(var a: Expr, var b: Expr) -> Expr:
        """`damerau_levenshtein(a, b)` — UNRESTRICTED Damerau-Levenshtein over
        BYTES -> INT64. ⛔ NOT the OSA distance: `('ca','abc')` = 2, not 3."""
        var args = List[Expr]()
        args.append(a^)
        args.append(b^)
        return Expr.string_fn_n(STRFNN_DAMERAU_LEVENSHTEIN, args^)

    @staticmethod
    def hamming(var a: Expr, var b: Expr) -> Expr:
        """`hamming(a, b)` — differing BYTE positions -> INT64. Aliases
        `mismatches`. ⛔ RAISES on unequal lengths AND on two empty strings."""
        var args = List[Expr]()
        args.append(a^)
        args.append(b^)
        return Expr.string_fn_n(STRFNN_HAMMING, args^)

    @always_inline
    def is_string_fn_n(self) -> Bool:
        """True if tag == EXPR_STRING_FN_N."""
        return self.tag == EXPR_STRING_FN_N

    @always_inline
    def string_fn_n_op(self) -> UInt8:
        """Multi-arg string op (STRFNN_*). Requires tag == EXPR_STRING_FN_N."""
        return self._string_fn_n.value().op

    @always_inline
    def string_fn_n_num_args(self) -> Int:
        """How many arguments this node ACTUALLY carries.

        ⚠ NOT `string_fn_n_arity(op)`, which is how many it SHOULD carry. The
        two disagreeing is precisely the malformed-node case every consumer
        has to refuse, so they are two different questions with two different
        spellings and neither is derived from the other."""
        return len(self._string_fn_n.value().args)

    @always_inline
    def string_fn_n_arg_ref(self, i: Int) -> ref [self._string_fn_n.value().args[i]] Expr:
        """Ref to argument `i`. Requires tag == EXPR_STRING_FN_N."""
        return self._string_fn_n.value().args[i]

    @staticmethod
    @always_inline
    def udf_call(
        var name: String,
        var handle: Optional[Int],
        in_type: ArrowType,
        out_type: ArrowType,
        var child: Expr,
    ) -> Expr:
        """Create an `EXPR_UDF_CALL` node — a registered scalar UDF applied to
        `child`.

        ⚠ THIS IS NOT THE CUSTOMER SURFACE AND MUST NOT BECOME ONE. Every
        argument here is a fact `ScalarUdf` already derives: the name from
        `register_scalar`'s one name parameter, the handle from the registry,
        both dtype tags from the customer function's signature. The customer
        spelling is `affine(col("x"))` — `ScalarUdf.__call__`, which is the
        ONLY caller that should exist in customer-reachable code. A second
        caller passing hand-written arguments re-opens exactly the two defects
        (two names, a restated dtype) that `scalar_udf.mojo` exists to make
        unrepresentable; this factory is here because the core packages cannot
        depend on the SDK, not because the arguments are meant to be typed.
        """
        var e = Expr(EXPR_UDF_CALL)
        e._udf_call = UdfCallData(name^, handle^, in_type, out_type, child^)
        return e^

    @always_inline
    def is_udf_call(self) -> Bool:
        """True if tag == EXPR_UDF_CALL."""
        return self.tag == EXPR_UDF_CALL

    @always_inline
    def udf_call_name(self) -> String:
        """The registry resolution key. Requires tag == EXPR_UDF_CALL."""
        return self._udf_call.value().name.copy()

    @always_inline
    def udf_call_handle(self) -> Optional[Int]:
        """The process-local registry handle, or `None` after the wire."""
        return self._udf_call.value().handle.copy()

    @always_inline
    def udf_call_in_type(self) -> ArrowType:
        """`ArrowType` of the argument column. Requires tag == EXPR_UDF_CALL."""
        return self._udf_call.value().in_type

    @always_inline
    def udf_call_out_type(self) -> ArrowType:
        """`ArrowType` of the produced column. Requires tag == EXPR_UDF_CALL.

        ★ THIS IS WHAT `_infer_expr_field` RETURNS, so a UDF's plan-declared
        output type comes from the customer's own function signature and from
        nowhere else."""
        return self._udf_call.value().out_type

    @always_inline
    def udf_call_child_ref(self) -> ref [origin_of(self._udf_call.value().child[])] Expr:
        """Ref to the UDF's argument. Requires tag == EXPR_UDF_CALL."""
        return self._udf_call.value().child[]

    @staticmethod
    @always_inline
    def math_fn2(op: UInt8, var left: Expr, var right: Expr) -> Expr:
        """Create an `EXPR_MATH_FN2` node (binary scalar math).

        `op` is MATH2_ATAN2.  Both children evaluate to numeric Columns;
        the result is a FLOAT64 Column.
        """
        var e = Expr(EXPR_MATH_FN2)
        e._math_fn2 = MathFn2Data(op, left^, right^)
        return e^

    @staticmethod
    @always_inline
    def atan2(var y: Expr, var x: Expr) -> Expr:
        """`atan2(y, x)` — two-argument arctangent -> FLOAT64 (radians)."""
        return Expr.math_fn2(MATH2_ATAN2, y^, x^)

    @always_inline
    def is_math_fn(self) -> Bool:
        """True if tag == EXPR_MATH_FN."""
        return self.tag == EXPR_MATH_FN

    @always_inline
    def math_fn_op(self) -> UInt8:
        """Unary math op (MATH_*). Requires tag == EXPR_MATH_FN."""
        return self._math_fn.value().op

    @always_inline
    def math_fn_child_ref(self) -> ref [origin_of(self._math_fn.value().child[])] Expr:
        """Ref to the unary math child. Requires tag == EXPR_MATH_FN."""
        return self._math_fn.value().child[]

    @always_inline
    def is_math_fn2(self) -> Bool:
        """True if tag == EXPR_MATH_FN2."""
        return self.tag == EXPR_MATH_FN2

    @always_inline
    def math_fn2_op(self) -> UInt8:
        """Binary math op (MATH2_*). Requires tag == EXPR_MATH_FN2."""
        return self._math_fn2.value().op

    @always_inline
    def math_fn2_left_ref(self) -> ref [origin_of(self._math_fn2.value().left[])] Expr:
        """Ref to the binary math left child. Requires tag == EXPR_MATH_FN2."""
        return self._math_fn2.value().left[]

    @always_inline
    def math_fn2_right_ref(self) -> ref [origin_of(self._math_fn2.value().right[])] Expr:
        """Ref to the binary math right child. Requires tag == EXPR_MATH_FN2."""
        return self._math_fn2.value().right[]

    @always_inline
    def is_substring(self) -> Bool:
        """True if tag == EXPR_SUBSTRING."""
        return self.tag == EXPR_SUBSTRING

    @always_inline
    def substring_child_ref(self) -> ref [origin_of(self._substring.value().child[])] Expr:
        """Ref to the string-column child. Requires tag == EXPR_SUBSTRING."""
        return self._substring.value().child[]

    @always_inline
    def substring_start(self) -> Int:
        """1-based start position. Requires tag == EXPR_SUBSTRING."""
        return self._substring.value().start

    @always_inline
    def substring_length(self) -> Int:
        """Number of characters (`< 0` = to end). Requires tag == EXPR_SUBSTRING."""
        return self._substring.value().length

    @always_inline
    def regexp_op(self) -> UInt8:
        """Get the regexp op (REGEXP_LIKE/MATCH/REPLACE/EXTRACT). Requires tag == EXPR_REGEXP."""
        return self._regexp.value().op

    @always_inline
    def regexp_child_ref(self) -> ref [origin_of(self._regexp.value().child[])] Expr:
        """Ref to the string-column child. Requires tag == EXPR_REGEXP."""
        return self._regexp.value().child[]

    @always_inline
    def regexp_pattern(self) -> String:
        """The regex pattern literal. Requires tag == EXPR_REGEXP."""
        return self._regexp.value().pattern.copy()

    @always_inline
    def regexp_replacement(self) -> String:
        """The replacement template ("" unless op == REGEXP_REPLACE). Requires tag == EXPR_REGEXP."""
        return self._regexp.value().replacement.copy()

    @always_inline
    def regexp_flags(self) -> String:
        """The flags string. Requires tag == EXPR_REGEXP."""
        return self._regexp.value().flags.copy()

    @always_inline
    def regexp_group(self) -> Int:
        """The capture-group index (0 unless op == REGEXP_EXTRACT). Requires tag == EXPR_REGEXP."""
        return self._regexp.value().group

    @always_inline
    def regexp_group_name(self) -> String:
        """The named capture group ("" unless the user referenced a `(?P<name>...)`
        group by name in regexp_extract). Requires tag == EXPR_REGEXP."""
        return self._regexp.value().group_name.copy()

    @staticmethod
    @always_inline
    def when(var cases: List[WhenCaseData], var default: Expr) -> Expr:
        """Create a CASE WHEN ... THEN ... ELSE ... expression."""
        var e = Expr(EXPR_WHEN)
        e._when = WhenData(cases^, default^)
        return e^

    @staticmethod
    @always_inline
    def agg_fn(op: UInt8, var child: Expr) -> Expr:
        """Aggregate-as-expression factory.

        Constructs an `EXPR_AGG_FN` node carrying `op` (one of
        `AGG_SUM` / `AGG_COUNT` / `AGG_MIN` / `AGG_MAX` / `AGG_MEAN`
        from `agg_expr.mojo`) and the column-reference child.

        User-facing entry point is the ColExpr `.max()` / `.min()` /
        `.sum()` / `.avg()` / `.count()` methods (col_expr.mojo). This
        free factory exists so the optimizer rule can construct the
        node directly when needed (e.g. during pattern recognition or
        substitution traversal).

        Eval-side semantics: an optimizer rule (the scalar-broadcast
        rewrite, not in this tree) is expected to consume the variant
        before eval ever sees one. `interpret_expr` (komira_kernels)
        returns NULL for an `EXPR_AGG_FN` that reaches it.
        """
        var e = Expr(EXPR_AGG_FN)
        e._agg_fn = AggFnData(op, child^)
        return e^

    @staticmethod
    @always_inline
    def window_fn(
        func: UInt8,
        var arg_col: String,
        arg_offset: Int,
        var frame: PartitionFrame,
    ) -> Expr:
        """EXPR_WINDOW_FN factory.

        `partition_by`/`order_by`/`descending` default to empty; set
        them by chaining `.over(...)` on the returned Expr.
        """
        var e = Expr(EXPR_WINDOW_FN)
        e._window_fn = WindowFnData(
            func, arg_col^, arg_offset, frame^,
            List[String](), List[String](), List[Bool](),
        )
        return e^

    @staticmethod
    @always_inline
    def in_list_node(var child: Expr, var values: List[ScalarValue]) -> Expr:
        """Canonical EXPR_IN_LIST factory.

        Builds the IR-level IN-list node directly. `Expr.in_list(...)`
        folds to OR-of-eq; an optimizer rule (not in this tree)
        canonicalizes that shape to `EXPR_IN_LIST` during plan optimization.
        """
        var e = Expr(EXPR_IN_LIST)
        e._in_list = InListData(child^, values^)
        return e^

    @staticmethod
    def correlated_subquery[
        P: BoxablePlan
    ](
        var inner_plan: P,
        var outer_refs: List[String],
        kind: UInt8,
    ) -> Expr:
        """Correlated subquery factory.

        ⚠ PARAMETRIC OVER `P: BoxablePlan`, AND `P` IS INFERRED — a call site
        reads `Expr.correlated_subquery(inner_plan^, refs^, kind)`.
        `LogicalPlan` is the only conformer; the
        parameter exists so this file need not NAME it. See the import block at
        the top of this file for what that buys and what breaks it.

        Builds an `EXPR_CORRELATED_SUBQUERY` Expr carrying:
          - `inner_plan`: the subquery's full LogicalPlan tree (consumed).
          - `outer_refs`: column names from the OUTER scope this subquery
            correlates against. `flatten_dependent_joins` validates them
            against the outer parent's `output_schema` and raises
            `UnresolvedOuterRef` on mismatch.
          - `kind`: one of `CORR_KIND_EXISTS` (Q4), `CORR_KIND_NOT_EXISTS`
            (Q21), `CORR_KIND_SCALAR` (Q17). Selects the lowering shape
            (SEMI / ANTI / LEFT+agg).

        This factory is the user-facing entry point on the Expr surface;
        the SDK's DataFrame-taking alias is not in this tree.

        Eval-side: this variant must be consumed by
        `flatten_dependent_joins` (komira_optimizer, a pass-1 INDEP rule)
        BEFORE the plan compiler dispatches the plan. `interpret_expr`
        (komira_kernels) returns NULL for it; reaching eval means the pass
        missed a node.
        """
        var e = Expr(EXPR_CORRELATED_SUBQUERY)
        var data = make_correlated_subquery_data[P](inner_plan^, outer_refs^, kind)
        e._corr_subq = OwnedPointer(data^)
        return e^

    @staticmethod
    def in_correlated_subquery[
        P: BoxablePlan
    ](
        var inner_plan: P,
        var outer_refs: List[String],
        var in_lhs_col: String,
        var in_rhs_col: String,
    ) -> Expr:
        """`IN (subquery)` factory.

        ⚠ PARAMETRIC OVER `P: BoxablePlan`, INFERRED — see
        `Expr.correlated_subquery` above.

        Builds an `EXPR_CORRELATED_SUBQUERY` Expr of kind
        `CORR_KIND_IN_CORRELATED`, representing the boolean predicate
        `<in_lhs_col> IN (SELECT <in_rhs_col> FROM <inner_plan> [WHERE <corr>])`.

        Mirrors `Expr.correlated_subquery(...)` but carries the two extra
        column names that pin the `IN`-list equi-predicate:
          - `inner_plan`: the subquery's full LogicalPlan tree (consumed).
            The single column it projects (or that survives correlation-key
            hoisting) is `in_rhs_col`.
          - `outer_refs`: column names from the OUTER scope this subquery
            correlates against (may be empty — an *uncorrelated* `IN`
            whose RHS is a subquery; lowers to a single-equi-key semi-join).
          - `in_lhs_col`: the OUTER column on the LHS of `IN` (e.g.
            `s_suppkey`). Validated against the outer parent's
            `output_schema` by `flatten_dependent_joins`.
          - `in_rhs_col`: the INNER column the subquery projects that the
            `IN` matches against (e.g. `ps_suppkey`).

        Lowering (`flatten_dependent_joins`, komira_optimizer, pass-1 INDEP):
          `Filter(outer, <this>)` → `outer ⋈SEMI inner_after_hoist
          ON (hoisted_corr_keys..., in_lhs_col) = (..., in_rhs_col)`.

        DuckDB reference: `IN (subquery)` lowers to a correlated MARK join
        with "one extra join condition" (the original `IN` comparison) —
        see DuckDB's `plan_subquery.cpp`. This engine has no MARK join; the
        positive-`IN` form is exactly a
        SEMI join with that extra equi-key.
        """
        var e = Expr(EXPR_CORRELATED_SUBQUERY)
        var data = make_correlated_subquery_data[P](
            inner_plan^, outer_refs^, CORR_KIND_IN_CORRELATED,
            in_lhs_col^, in_rhs_col^,
        )
        e._corr_subq = OwnedPointer(data^)
        return e^

    # --- Python comparison / boolean dunders -------------------
    #
    # These return an Expr (the comparison / conjunction expression), NOT a
    # Bool — same shape Polars uses. This codebase never compares two
    # `Expr` values with `==` for equality nor uses `Expr` as a Dict key, so
    # overriding `__eq__` to produce a comparison Expr is safe. (`ColExpr`
    # already does the same for `col("a") == 5`; this surface mirrors it on
    # the bare `Expr` so the join `predicate=` API reads naturally:
    # `Expr.left("a") == Expr.right("b")`.)

    @always_inline
    def __eq__(self, other: Expr) -> Expr:
        """`lhs == rhs` -> Expr(BIN_EQ, lhs, rhs)."""
        return Expr.binary(BIN_EQ, self.copy(), other.copy())

    @always_inline
    def __ne__(self, other: Expr) -> Expr:
        """`lhs != rhs` -> Expr(BIN_NE, lhs, rhs)."""
        return Expr.binary(BIN_NE, self.copy(), other.copy())

    @always_inline
    def __lt__(self, other: Expr) -> Expr:
        """`lhs < rhs` -> Expr(BIN_LT, lhs, rhs)."""
        return Expr.binary(BIN_LT, self.copy(), other.copy())

    @always_inline
    def __le__(self, other: Expr) -> Expr:
        """`lhs <= rhs` -> Expr(BIN_LE, lhs, rhs)."""
        return Expr.binary(BIN_LE, self.copy(), other.copy())

    @always_inline
    def __gt__(self, other: Expr) -> Expr:
        """`lhs > rhs` -> Expr(BIN_GT, lhs, rhs)."""
        return Expr.binary(BIN_GT, self.copy(), other.copy())

    @always_inline
    def __ge__(self, other: Expr) -> Expr:
        """`lhs >= rhs` -> Expr(BIN_GE, lhs, rhs)."""
        return Expr.binary(BIN_GE, self.copy(), other.copy())

    @always_inline
    def __and__(self, other: Expr) -> Expr:
        """`lhs & rhs` -> Expr(BIN_AND, lhs, rhs) (boolean conjunction)."""
        return Expr.binary(BIN_AND, self.copy(), other.copy())

    @always_inline
    def __or__(self, other: Expr) -> Expr:
        """`lhs | rhs` -> Expr(BIN_OR, lhs, rhs) (boolean disjunction)."""
        return Expr.binary(BIN_OR, self.copy(), other.copy())

    @always_inline
    def __invert__(self) -> Expr:
        """`~pred` -> Expr(UN_NOT, pred) (boolean negation).

        Closes the boolean-composition trio on Expr: `__and__` / `__or__` /
        `__invert__`. Mirrors typed `Column.__invert__` on the Expr return of
        `__eq__`/`__lt__`/..., so `~(col("x") == 5)` parses.
        """
        return Expr.unary(UN_NOT, self.copy())

    @always_inline
    def with_window_spec(
        var self,
        var partition_by: List[String],
        var order_by: List[String],
        var descending: List[Bool],
    ) -> Expr:
        """Replace the window spec on EXPR_WINDOW_FN.

        Partial-moving fields out of a struct is banned; we deep-copy
        func/arg_col/arg_offset/frame and
        rebuild the WindowFnData. Old _window_fn drops on assignment.

        ★ AN AGGREGATE OPERAND: polars'
        GROUP BROADCAST `col("v").mean().over("g")` — `.sum()` / `.mean()` /
        `.avg()` / `.count()` / `.min()` / `.max()` of a PLAIN column. The
        `EXPR_AGG_FN` becomes the `EXPR_WINDOW_FN` of the same function over
        the WHOLE partition (`PartitionFrame.default_unordered()`), SQL's
        `avg(v) OVER (PARTITION BY g)`. ⚠ The frame stays WHOLE when
        `order_by` is given, as polars answers (an aggregate ignores the
        order); SQL's `sum(v) OVER (PARTITION BY g ORDER BY k)` is a RUNNING
        sum — spell that `cum_sum().over(...)`. ⛔ Without this arm the
        receiver would be read as a window payload it does not have
        (`_window_fn` is empty on an `EXPR_AGG_FN`): undefined behaviour, not
        an error.

        ⛔ ANY OTHER RECEIVER IS REFUSED BY NAME — an aggregate of a COMPUTED
        expression (`(col("v") * 2).sum().over("g")`, which polars and DuckDB
        answer: `WindowFnData` carries a column NAME, not an expression), an
        aggregate outside the five, or a non-window expression. This method
        cannot raise (the four `.over` overloads are non-raising and widely
        called), so the refusal is CARRIED: a window whose argument-column
        slot holds `OVER_REFUSED_PREFIX` + the reason (`_refused_over`).
        `PlanCarrier` finds it anywhere in a verb's expression
        (`col_expr_bind.over_refusal`): `with_columns` raises it at the verb,
        and `select` and `filter` answer a PROJECT of one column NAMED the
        refusal, which every later verb keeps as the plan's ROOT
        (`filter_refusal.keep_refusal_at_root`), so the run fails (by name
        over a parquet source; over an in-memory one with that leaf's
        envelope text). Never a FILTER over the refusal: the engine drops a
        filter whose predicate names a column the input lacks, so it would
        answer every row; and the refusal must stay the ROOT, or a verb AFTER
        it lets the optimizer prune it (MEASURED: `filter(col("nope") > 3)
        .select(col("k"))` answered all 6 rows). ⛔ ABORTING instead would
        be a refusal that kills the caller.
        """
        if self.tag == EXPR_AGG_FN:
            return _agg_fn_over(self^, partition_by^, order_by^, descending^)
        if self.tag != EXPR_WINDOW_FN:
            return _refused_over(
                String(
                    "the receiver must be a window function (col(x).rank() /"
                    " .lag() / .cum_sum() / .rolling_mean(n) ...) or an"
                    " aggregate of a plain column (col(x).sum() / .mean() /"
                    " .count() / .min() / .max()); got expression tag "
                )
                + String(Int(self.tag)),
                partition_by^, order_by^, descending^,
            )
        var src = self._window_fn.value().copy()
        self._window_fn = WindowFnData(
            src.func, src.arg_col.copy(), src.arg_offset, src.frame.copy(),
            partition_by^, order_by^, descending^,
        )
        return self^

    @staticmethod
    def in_list(var col_expr: Expr, var values: List[ScalarValue]) raises -> Expr:
        """IN-list predicate: `col_expr IN (v0, v1, ...)`.

        Folds at the factory site (no separate EXPR_IN_LIST variant):
          - Empty list (N == 0):   returns `Expr.literal(False)`
            (matches SQL `IN (empty)` → FALSE).
          - Small list (1 <= N <= 64): folds to a left-leaning OR chain
            of `col_expr == v0 OR col_expr == v1 OR ...`. Composes
            cleanly with all existing optimizer rules (predicate
            pushdown, column-range pruning, etc.) because the result
            is a tree of `EXPR_BINARY_OP` nodes the optimizer already
            understands.
          - Large list (N > 64): out of scope here; callers must
            decompose, use a SEMI-join shape, or build the EXPR_IN_LIST
            node (`in_list_node`). Raises with a clear error message.

        Args:
            col_expr: The column-reference (or other scalar-typed) Expr
                      being tested against the values.
            values:   The membership set, drawn from a Pattern A
                      `scalar_list(inner_batch)` call or constructed
                      manually from `ScalarValue.from_*`.

        Returns:
            An Expr representing the IN-list predicate. Tag is
            EXPR_LITERAL (False) when empty, otherwise EXPR_BINARY_OP
            (BIN_OR) for N >= 2, or EXPR_BINARY_OP (BIN_EQ) for N == 1.
        """
        var n = len(values)
        if n == 0:
            # SQL IN (empty) → FALSE.
            return Expr.literal(ScalarValue.from_bool(False))
        if n > 64:
            # Out-of-scope path — raising at construction is the safest
            # signal; callers decompose or build the EXPR_IN_LIST node.
            raise Error(
                "Expr.in_list: list length " + String(n)
                + " exceeds the small-IN factory limit of 64"
                + " (large IN-lists require the EXPR_IN_LIST tag-9 path,"
                + " not yet implemented; decompose into smaller lists or"
                + " use a SEMI-join shape)"
            )
        # Build a left-leaning OR chain: ((col == v0) OR (col == v1)) OR ...
        # Each leaf takes a fresh copy of `col_expr` so the original
        # remains owned by the function and is dropped at exit. The
        # `values` list is consumed by indexing-and-copying each entry;
        # the list itself is dropped at function exit.
        var v0 = values[0].copy()
        var acc = Expr.binary(BIN_EQ, col_expr.copy(), Expr.literal(v0^))
        for i in range(1, n):
            var vi = values[i].copy()
            var eq = Expr.binary(BIN_EQ, col_expr.copy(), Expr.literal(vi^))
            acc = Expr.binary(BIN_OR, acc^, eq^)
        return acc^

    # --- Type checks ---

    @always_inline
    def is_col_ref(self) -> Bool:
        """True if this is a column reference by name."""
        return self.tag == EXPR_COL_REF

    @always_inline
    def is_col_idx(self) -> Bool:
        """True if this is a column reference by index."""
        return self.tag == EXPR_COL_IDX

    @always_inline
    def is_literal(self) -> Bool:
        """True if this is a literal value."""
        return self.tag == EXPR_LITERAL

    @always_inline
    def is_binary(self) -> Bool:
        """True if this is a binary operation."""
        return self.tag == EXPR_BINARY_OP

    @always_inline
    def is_unary(self) -> Bool:
        """True if this is a unary operation."""
        return self.tag == EXPR_UNARY_OP

    @always_inline
    def is_cast(self) -> Bool:
        """True if this is a type cast."""
        return self.tag == EXPR_CAST

    @always_inline
    def is_alias(self) -> Bool:
        """True if this is an alias (rename)."""
        return self.tag == EXPR_ALIAS

    @always_inline
    def is_string_op(self) -> Bool:
        """True if this is a string operation (CONTAINS, LIKE, etc.)."""
        return self.tag == EXPR_STRING_OP

    @always_inline
    def is_when(self) -> Bool:
        """True if this is a WHEN (CASE) expression."""
        return self.tag == EXPR_WHEN

    @always_inline
    def when_num_cases(self) -> Int:
        """Number of WHEN/THEN case pairs. Requires tag == EXPR_WHEN."""
        return len(self._when.value().cases)

    @always_inline
    def when_case_condition_ref(self, i: Int) -> ref [self._when.value().cases[i].condition] Expr:
        """Reference to the i-th WHEN condition Expr. Requires tag == EXPR_WHEN."""
        return self._when.value().cases[i].condition[]

    @always_inline
    def when_case_result_ref(self, i: Int) -> ref [self._when.value().cases[i].result] Expr:
        """Reference to the i-th THEN result Expr. Requires tag == EXPR_WHEN."""
        return self._when.value().cases[i].result[]

    @always_inline
    def when_default_ref(self) -> ref [origin_of(self._when.value().default[])] Expr:
        """Reference to the ELSE (default) Expr. Requires tag == EXPR_WHEN."""
        return self._when.value().default[]

    @always_inline
    def is_agg_fn(self) -> Bool:
        """True if this is an aggregate-as-expression."""
        return self.tag == EXPR_AGG_FN

    @always_inline
    def agg_fn_op(self) -> UInt8:
        """Get the agg-fn op (AGG_SUM/COUNT/MIN/MAX/MEAN). Requires tag == EXPR_AGG_FN."""
        return self._agg_fn.value().op

    @always_inline
    def agg_fn_child_ref(self) -> ref [origin_of(self._agg_fn.value().child[])] Expr:
        """Get a reference to the aggregated child expr. Requires tag == EXPR_AGG_FN."""
        return self._agg_fn.value().child[]

    @always_inline
    def agg_fn_child(self) -> Expr:
        """Get a copy of the aggregated child expr. Requires tag == EXPR_AGG_FN."""
        return self._agg_fn.value().child[].copy()

    # --- EXPR_CORRELATED_SUBQUERY (tag 14) accessors ---
    #
    # ⛔ THE INNER-PLAN ACCESSOR IS NOT HERE AND CANNOT BE. Its return type is
    # `LogicalPlan`, which is the edge this file exists not to have. It is the
    # FREE FUNCTION `corr_subq_inner_plan_ref(e)` in `plan/corr_subquery.mojo`.
    #
    # ⚠ ITS NAME IS WHAT MAKES IT GREPPABLE: `git grep corr_subq_inner_plan_ref`
    # enumerates every walk that crosses from the expression tree into the plan
    # tree, which is the one edge a plan-node-only walk cannot see — a walk
    # blind to it silently skips every plan hanging off a subquery while its
    # caller sees success. The free function RAISES on an `ErasedBox` type-tag
    # mismatch, so there is no way to reach a subquery's plan that is not both
    # greppable and checked.
    #
    # The FOUR fields below stay HERE because they are leaf-typed
    # (`List[String]`, `UInt8`, `String`, `String`); accessors mean nobody
    # reaches through `expr._corr_subq.value()[]` by hand. Requires
    # tag == EXPR_CORRELATED_SUBQUERY on all four.

    @always_inline
    def corr_subq_outer_refs(self) -> List[String]:
        """The OUTER-scope column names this subquery correlates with.

        ⚠ THE PLAN RENDER PRINTS ONLY THEIR COUNT (`outer_refs=#2`), so any
        consumer that needs the NAMES has to come here — `structural_hash`
        cannot tell two subqueries with differently-named refs apart."""
        return self._corr_subq.value()[].outer_refs.copy()

    @always_inline
    def corr_subq_kind(self) -> UInt8:
        """CORR_KIND_EXISTS / _NOT_EXISTS / _SCALAR / _IN_CORRELATED — the
        flavour that selects the lowering shape in
        `flatten_dependent_joins`."""
        return self._corr_subq.value()[].kind

    @always_inline
    def corr_subq_in_lhs_col(self) -> String:
        """The OUTER column on the LHS of `IN`. Empty unless
        kind == CORR_KIND_IN_CORRELATED."""
        return self._corr_subq.value()[].in_lhs_col.copy()

    @always_inline
    def corr_subq_in_rhs_col(self) -> String:
        """The INNER column the subquery projects that the `IN` matches
        against. Empty unless kind == CORR_KIND_IN_CORRELATED."""
        return self._corr_subq.value()[].in_rhs_col.copy()

    # --- EXPR_WINDOW_FN accessors ---

    @always_inline
    def is_window_fn(self) -> Bool:
        """True if this is a window-function-as-expression."""
        return self.tag == EXPR_WINDOW_FN

    @always_inline
    def window_fn_data_ref(self) -> ref [self._window_fn.value()] WindowFnData:
        """Get a reference to the WindowFnData payload.
        Requires tag == EXPR_WINDOW_FN. Single-call accessor (no per-field
        accessors)."""
        return self._window_fn.value()

    @always_inline
    def alias(self, name: String) -> Expr:
        """`expr.alias("name")` instance form
        (mirrors the staticmethod `Expr.alias(child, name)`).

        Used for `col("x").rank().over("g").alias("rk")`-style chains
        where the receiver is an Expr (not a ColExpr).
        """
        return Expr.alias(self.copy(), name)

    @always_inline
    def over(
        var self,
        var partition_by: List[String],
        var order_by: List[String],
        var descending: List[Bool],
    ) -> Expr:
        """Chainable `.over(partition_by, order_by, descending)`.

        Binds a window function (from `col(...).rank()` / `.lag()` /
        `.rolling_mean(n)` / ...) to a partition + explicit sort direction. The
        untyped fluent `.over()` surface is plan-shape verified; value oracles
        live in the typed-row window tests.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var ok: List[String] = ["ts"]
            var desc: List[Bool] = [True]     # descending order_by
            var out = ctx.materialize(
                df^.with_column(col("v").lag().over(pk^, ok^, desc^).alias("prev"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return self^.with_window_spec(partition_by^, order_by^, descending^)

    @always_inline
    def over(var self, var partition_by: List[String]) -> Expr:
        """`.over(partition_by)` -- no ordering.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["g"]
            var out = ctx.materialize(
                df^.with_column(col("v").rank().over(pk^).alias("rk"))^
            )
            ```
        (example not yet doctest-verified)
        """
        return self^.with_window_spec(
            partition_by^, List[String](), List[Bool](),
        )

    @always_inline
    def over(var self, partition_by: String) -> Expr:
        """`.over("g")` -- single partition key, no ordering.

        Examples:
            ```mojo
            from komira_sdk import col
            var out = ctx.materialize(
                df^.with_column(col("v").rank().over("g").alias("rk"))^
            )
            ```
        """
        var pkeys: List[String] = [partition_by]
        return self^.with_window_spec(pkeys^, List[String](), List[Bool]())

    @always_inline
    def over(
        var self,
        var partition_by: List[String],
        var order_by: List[String],
    ) -> Expr:
        """`.over(["g"], ["ts"])` -- partition + order, all ascending.

        Examples:
            ```mojo
            from komira_sdk import col
            var pk: List[String] = ["user_id"]
            var ok: List[String] = ["ts"]
            var out = ctx.materialize(
                df^.with_column(
                    col("value").rolling_mean(7).over(pk^, ok^).alias("roll7")
                )^
            )
            ```
        """
        var n = len(order_by)
        var desc = List[Bool]()
        for _i in range(n):
            desc.append(False)
        return self^.with_window_spec(partition_by^, order_by^, desc^)

    # --- Accessor methods ---

    @always_inline
    def col_ref_name(self) -> String:
        """Get the column name. Requires tag == EXPR_COL_REF."""
        return self._col_ref.value().name.copy()

    @always_inline
    def col_ref_side(self) -> UInt8:
        """Get the join-side qualifier.

        One of `COL_SIDE_NONE` / `COL_SIDE_LEFT` / `COL_SIDE_RIGHT`.
        Requires tag == EXPR_COL_REF.
        """
        return self._col_ref.value().side

    @always_inline
    def col_idx_index(self) -> Int:
        """Get the column index. Requires tag == EXPR_COL_IDX."""
        return self._col_idx.value().index

    @always_inline
    def literal_value(self) -> ScalarValue:
        """Get the literal value. Requires tag == EXPR_LITERAL."""
        return self._literal.value().value.copy()

    @always_inline
    def binary_op(self) -> UInt8:
        """Get the binary operator. Requires tag == EXPR_BINARY_OP."""
        return self._binary.value().op

    @always_inline
    def binary_division_intent(self) -> UInt8:
        """`BinaryOpData.division_intent` (0 unless an unbound builder made
        this division). Requires tag == EXPR_BINARY_OP."""
        return self._binary.value().division_intent

    @always_inline
    def binary_left_ref(self) -> ref [origin_of(self._binary.value().left[])] Expr:
        """Get a reference to the left child. Requires tag == EXPR_BINARY_OP."""
        return self._binary.value().left[]

    @always_inline
    def binary_right_ref(self) -> ref [origin_of(self._binary.value().right[])] Expr:
        """Get a reference to the right child. Requires tag == EXPR_BINARY_OP."""
        return self._binary.value().right[]

    @always_inline
    def binary_left(self) -> Expr:
        """Get a copy of the left child. Requires tag == EXPR_BINARY_OP."""
        return self._binary.value().left[].copy()

    @always_inline
    def binary_right(self) -> Expr:
        """Get a copy of the right child. Requires tag == EXPR_BINARY_OP."""
        return self._binary.value().right[].copy()

    @always_inline
    def unary_op(self) -> UInt8:
        """Get the unary operator. Requires tag == EXPR_UNARY_OP."""
        return self._unary.value().op

    @always_inline
    def unary_child_ref(self) -> ref [origin_of(self._unary.value().child[])] Expr:
        """Get a reference to the child. Requires tag == EXPR_UNARY_OP."""
        return self._unary.value().child[]

    @always_inline
    def unary_child(self) -> Expr:
        """Get a copy of the child. Requires tag == EXPR_UNARY_OP."""
        return self._unary.value().child[].copy()

    @always_inline
    def cast_target(self) -> DType:
        """Get the target DType. Requires tag == EXPR_CAST."""
        return self._cast.value().target

    @always_inline
    def cast_child_ref(self) -> ref [origin_of(self._cast.value().child[])] Expr:
        """Get a reference to the child. Requires tag == EXPR_CAST."""
        return self._cast.value().child[]

    @always_inline
    def cast_child(self) -> Expr:
        """Get a copy of the child. Requires tag == EXPR_CAST."""
        return self._cast.value().child[].copy()

    @always_inline
    def alias_name(self) -> String:
        """Get the alias name. Requires tag == EXPR_ALIAS."""
        return self._alias.value().name.copy()

    @always_inline
    def alias_child_ref(self) -> ref [origin_of(self._alias.value().child[])] Expr:
        """Get a reference to the child. Requires tag == EXPR_ALIAS."""
        return self._alias.value().child[]

    @always_inline
    def alias_child(self) -> Expr:
        """Get a copy of the child. Requires tag == EXPR_ALIAS."""
        return self._alias.value().child[].copy()

    @always_inline
    def string_op_type(self) -> UInt8:
        """Get the string operation type. Requires tag == EXPR_STRING_OP."""
        return self._string_op.value().op

    @always_inline
    def string_op_child_ref(self) -> ref [origin_of(self._string_op.value().child[])] Expr:
        """Get a reference to the child. Requires tag == EXPR_STRING_OP."""
        return self._string_op.value().child[]

    @always_inline
    def string_op_pattern(self) -> String:
        """Get the pattern string. Requires tag == EXPR_STRING_OP."""
        return self._string_op.value().pattern.copy()

    # --- EXPR_IN_LIST accessors ---

    @always_inline
    def is_in_list(self) -> Bool:
        """True if tag == EXPR_IN_LIST."""
        return self.tag == EXPR_IN_LIST

    @always_inline
    def in_list_child_ref(self) -> ref [origin_of(self._in_list.value().child[])] Expr:
        """Ref to the child Expr being tested. Requires tag == EXPR_IN_LIST."""
        return self._in_list.value().child[]

    @always_inline
    def in_list_child(self) -> Expr:
        """Copy of the child Expr being tested. Requires tag == EXPR_IN_LIST."""
        return self._in_list.value().child[].copy()

    @always_inline
    def in_list_values_ref(self) -> ref [self._in_list.value().values] List[ScalarValue]:
        """Ref to the value list. Requires tag == EXPR_IN_LIST."""
        return self._in_list.value().values

    @always_inline
    def in_list_len(self) -> Int:
        """Count of literal values. Requires tag == EXPR_IN_LIST."""
        return len(self._in_list.value().values)

    # --- Writable ---

    def write_to[W: Writer](self, mut writer: W):
        """Human-readable representation of the expression tree."""
        if self.tag == EXPR_COL_REF:
            ref cr = self._col_ref.value()
            if cr.side == COL_SIDE_LEFT:
                writer.write("ColRef(left.", cr.name, ")")
            elif cr.side == COL_SIDE_RIGHT:
                writer.write("ColRef(right.", cr.name, ")")
            else:
                writer.write("ColRef(", cr.name, ")")
        elif self.tag == EXPR_COL_IDX:
            writer.write("ColIdx(", self._col_idx.value().index, ")")
        elif self.tag == EXPR_LITERAL:
            writer.write("Literal(")
            self._literal.value().value.write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_BINARY_OP:
            # Access through Optional reference -- BinaryOpData is not ImplicitlyCopyable
            writer.write("BinaryOp(")
            _write_binop(writer, self._binary.value().op)
            writer.write(", ")
            self._binary.value().left[].write_to(writer)
            writer.write(", ")
            self._binary.value().right[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_UNARY_OP:
            writer.write("UnaryOp(")
            _write_unop(writer, self._unary.value().op)
            writer.write(", ")
            self._unary.value().child[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_CAST:
            # ⛔ PLAN IDENTITY (the render feeds
            # `LogicalPlan.structural_hash`, the plan-compile cache key). The
            # DType alone would render `CAST(x AS DECIMAL(10, 2))` and
            # `DECIMAL(12, 4)`, and `TRY_CAST` beside `CAST`, EQUAL.
            # The Arrow target, the decimal (p, s) and the try flag are
            # printed when they DEVIATE from the plain DType cast, so an
            # ordinary cast's render is unchanged.
            ref cd = self._cast.value()
            writer.write("Cast(")
            cd.child[].write_to(writer)
            writer.write(", ", cd.target)
            if cd.target_arrow != ArrowType.from_dtype(cd.target):
                writer.write(", arrow=", cd.target_arrow)
            if cd.decimal_precision != 0 or cd.decimal_scale != 0:
                writer.write(
                    ", p=", cd.decimal_precision, ", s=", cd.decimal_scale
                )
            if cd.try_cast:
                writer.write(", try")
            writer.write(")")
        elif self.tag == EXPR_ALIAS:
            writer.write("Alias(")
            self._alias.value().child[].write_to(writer)
            writer.write(", ")
            write_quoted(writer, self._alias.value().name)
            writer.write(")")
        elif self.tag == EXPR_STRING_OP:
            writer.write("StringOp(")
            _write_strop(writer, self._string_op.value().op)
            writer.write(", ")
            self._string_op.value().child[].write_to(writer)
            writer.write(", ")
            write_quoted(writer, self._string_op.value().pattern)
            writer.write(")")
        elif self.tag == EXPR_REGEXP:
            ref rd = self._regexp.value()
            writer.write("Regexp(op=", Int(rd.op), ", ")
            rd.child[].write_to(writer)
            writer.write(", pattern=")
            write_quoted(writer, rd.pattern)
            if rd.flags.byte_length() > 0:
                writer.write(", flags=")
                write_quoted(writer, rd.flags)
            if rd.op == REGEXP_EXTRACT or rd.op == REGEXP_EXTRACT_ALL:
                writer.write(", group=", rd.group)
            if rd.group_name.byte_length() > 0:
                writer.write(", group_name=")
                write_quoted(writer, rd.group_name)
            if rd.op == REGEXP_REPLACE:
                writer.write(", replacement=")
                write_quoted(writer, rd.replacement)
            writer.write(")")
        elif self.tag == EXPR_SUBSTRING:
            ref sd = self._substring.value()
            writer.write("Substring(")
            sd.child[].write_to(writer)
            writer.write(", start=", sd.start, ", length=", sd.length, ")")
        elif self.tag == EXPR_WHEN:
            # ⛔ PLAN IDENTITY, NOT DECORATION. This render feeds
            # `LogicalPlan.structural_hash`, the plan-compile cache key. A
            # constant `When(...)` would let two plans differing only
            # INSIDE a CASE share a compiled plan: in ONE engine session
            # `select([k, when(v > 5, 1, 0)])` after `when(v > 8, 1, 0)`
            # would answer the FIRST query's column (MEASURED).
            ref wd = self._when.value()
            writer.write("When(")
            for i in range(len(wd.cases)):
                if i > 0:
                    writer.write(", ")
                writer.write("WHEN ")
                wd.cases[i].condition[].write_to(writer)
                writer.write(" THEN ")
                wd.cases[i].result[].write_to(writer)
            writer.write(", ELSE ")
            wd.default[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_AGG_FN:
            # Surface the agg-fn variant for EXPLAIN /
            # debug. Op is one of AGG_SUM/COUNT/MIN/MAX/MEAN.
            writer.write("AggFn(", Int(self._agg_fn.value().op), ", ")
            self._agg_fn.value().child[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_WINDOW_FN:
            # Surface for EXPLAIN. Func is one of PF_*.
            # ⛔ PLAN IDENTITY (the EXPRESSION-level twin of the
            # PLAN_PARTITION_BY render). Printing `partition_by=#N,
            # order_by=#N` — two COUNTS, no names, no directions, no frame —
            # would let, in ONE engine session, `sum(v).over("k")` after
            # `sum(v).over("g")`, and a row_number ordered DESC after the same
            # one ASC, answer the FIRST query (MEASURED). Every field is
            # emitted; the three lists are NOT parallel, so each prints in full.
            ref w = self._window_fn.value()
            writer.write("WindowFn(func=", Int(w.func), ", col=")
            write_quoted(writer, w.arg_col)
            writer.write(", offset=", w.arg_offset, ", partition_by=[")
            for i in range(len(w.partition_by)):
                if i > 0:
                    writer.write(", ")
                writer.write(w.partition_by[i])
            writer.write("], order_by=[")
            for i in range(len(w.order_by)):
                if i > 0:
                    writer.write(", ")
                writer.write(w.order_by[i])
            writer.write("], descending=[")
            for i in range(len(w.descending)):
                if i > 0:
                    writer.write(", ")
                writer.write("T" if w.descending[i] else "F")
            writer.write("], frame=", w.frame, ")")
        elif self.tag == EXPR_IN_LIST:
            # Surface for EXPLAIN.
            ref il = self._in_list.value()
            # ⛔ PLAN IDENTITY: the VALUES, not their count (two IN lists of
            # one length must not share a compiled plan).
            writer.write("InList(")
            il.child[].write_to(writer)
            writer.write(", [")
            for i in range(len(il.values)):
                if i > 0:
                    writer.write(", ")
                il.values[i].write_to(writer)
            writer.write("])")
        elif self.tag == EXPR_STRUCT_FIELD:
            # Surface for EXPLAIN (by-name).
            ref sf = self._struct_field.value()
            writer.write("StructField(")
            sf.parent[].write_to(writer)
            writer.write(", ")
            write_quoted(writer, sf.field_name)
            writer.write(")")
        elif self.tag == EXPR_STRUCT_FIELD_IDX:
            # Surface for EXPLAIN (by-idx).
            ref sfi = self._struct_field_idx.value()
            writer.write("StructFieldIdx(")
            sfi.parent[].write_to(writer)
            writer.write(", #", sfi.field_idx, ")")
        elif self.tag == EXPR_MAP_GET:
            # Surface for EXPLAIN.
            ref mg = self._map_get.value()
            writer.write("MapGet(")
            mg.parent[].write_to(writer)
            writer.write(", ")
            mg.key[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_EXTRACT:
            # Surface
            # for EXPLAIN.
            ref ed = self._extract.value()
            writer.write("Extract(unit=", Int(ed.unit), ", ")
            ed.child[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_MATH_FN:
            # Surface for EXPLAIN.
            ref mf = self._math_fn.value()
            writer.write("MathFn(op=", Int(mf.op), ", ")
            mf.child[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_STRING_FN:
            # Surface for EXPLAIN. Every carried
            # scalar is printed (there is exactly one, `op`), which is what
            # keeps the plan-wire round trip's TEXT leg able to see a dropped
            # field — see plan.proto's note on the flat scalar payloads.
            ref sf = self._string_fn.value()
            writer.write("StringFn(op=", Int(sf.op), ", ")
            sf.child[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_UDF_CALL:
            # ⛔ THIS RENDER IS NOT DISPLAY-ONLY.
            # It is read by the plan CACHE KEY, and — measured — it is a
            # SECOND, REDUNDANT carrier of the UDF's identity for
            # `_expr_fingerprint`, whose `else` arm salts an un-armed tag with
            # `String(expr)`. Deleting `_expr_fingerprint`'s UDF arm alone
            # leaves the suite green because THIS arm covers it;
            # deleting both is two wrong-value failures. Do not "simplify"
            # this render.
            #
            # The HANDLE is rendered and not just the name because:
            #
            # ★ THE HANDLE IS WHAT MAKES THIS RENDER AN IDENTITY. The L1/L2
            # plan cache keys on the rendered node, so two UDFs that render
            # alike share a compiled plan. Two registrations under one name are
            # legal (re-registering after an eviction is the ordinary case) and
            # they carry DIFFERENT generation-carrying handles — so rendering
            # the name alone would let a cached plan run the WRONG function's
            # thunk. `UdfData` solves this with a monotonic `call_site_salt`,
            # which also defeats the cache for every genuinely repeated query;
            # the handle is both narrower and truthful. A wire-stripped node
            # renders `h=-` and cannot collide with any local handle.
            ref uc = self._udf_call.value()
            writer.write("UdfCall(name=", uc.name, ", h=")
            if uc.handle:
                writer.write(uc.handle.value())
            else:
                writer.write("-")
            writer.write(
                ", in=", Int(uc.in_type.type_id),
                ", out=", Int(uc.out_type.type_id), ", ",
            )
            uc.child[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_STRING_FN_N:
            # Surface for EXPLAIN, and a leg of
            # the plan-wire round trip's TEXT comparison.
            #
            # ⚠ THE ARGUMENT COUNT IS RENDERED, NOT JUST THE ARGUMENTS. For
            # every OTHER arm the arity is fixed by the tag, so a dropped
            # child shows up as a missing sub-render; here `concat('a','b')`
            # and `concat('a','b','')` differ by an argument whose own render
            # is EMPTY, and only the count distinguishes them. `structural_
            # hash` reads this render, so without `n=` the wire could lose a
            # trailing empty-literal argument and the text leg would agree.
            ref sfnn = self._string_fn_n.value()
            writer.write(
                "StringFnN(op=", Int(sfnn.op),
                ", n=", len(sfnn.args),
            )
            for i in range(len(sfnn.args)):
                writer.write(", ")
                sfnn.args[i].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_MATH_FN2:
            ref mf2 = self._math_fn2.value()
            writer.write("MathFn2(op=", Int(mf2.op), ", ")
            mf2.left[].write_to(writer)
            writer.write(", ")
            mf2.right[].write_to(writer)
            writer.write(")")
        elif self.tag == EXPR_JSON_EXTRACT:
            # Surface for EXPLAIN. The path
            # is shown in canonical "$.a.b.c" form (rebuilt from segments)
            # so a CSE path-equality byte-compare sees a stable
            # canonical form across instances. The preserve_extension_metadata
            # bit is part of the printed surface so EXPLAIN distinguishes
            # `->` (json) vs `->>` (string) calls.
            ref je = self._json_extract.value()
            writer.write("JsonExtract(")
            je.parent[].write_to(writer)
            writer.write(", path=\"$")
            # Each segment escaped, `.` included: the ONE key `a.b`
            # (`$."a.b"`) must not render like the TWO keys `a`, `b`
            # (`$.a.b`) -- this render is plan identity (komira#960).
            for i in range(len(je.path_segments)):
                writer.write(".")
                write_escaped(writer, je.path_segments[i], escape_dot=True)
            writer.write("\"")
            if je.preserve_extension_metadata:
                writer.write(", mode=->")
            else:
                writer.write(", mode=->>")
            # ⛔ PLAN IDENTITY: the target type, when it is not
            # the STRING both query factories pin (a decoded typed extract).
            if je.output_type != ArrowType.STRING:
                writer.write(", type=", je.output_type)
            writer.write(")")
        elif self.tag == EXPR_CORRELATED_SUBQUERY:
            # Surface for EXPLAIN.
            # We don't recurse into the inner plan tree here (that would
            # require LogicalPlan.write_to; cheap structural summary is
            # enough for plan inspection).
            #
            # ⚠⚠ THIS RENDER IS `structural_hash`'s ONLY INPUT — "THE RENDER IS
            # THE HASH, THERE IS NO SECOND SOURCE OF IDENTITY" — and it is
            # ALREADY under-discriminating: two subqueries agreeing on `kind`,
            # `len(outer_refs)` and `inner_tag` hash IDENTICALLY however
            # different their inner plans are, so plan CSE can share them.
            # ⇒ A KNOWN DEFECT of the render, independent of the type
            # erasure. `cs.inner_tag` is a snapshot taken at construction from
            # the plan that was boxed.
            # ⛔ DO NOT "FIX" IT BY DELETING THE FIELD — the fix is to render
            # MORE (the inner plan's own structural hash), and the only module
            # that can see the plan to do that is `plan/corr_subquery.mojo`.
            ref cs = self._corr_subq.value()[]
            if cs.kind == CORR_KIND_IN_CORRELATED:
                writer.write(
                    "CorrelatedSubquery(kind=IN, ",
                    cs.in_lhs_col, " IN (#", len(cs.outer_refs),
                    " corr refs) -> ", cs.in_rhs_col,
                    ", inner_tag=", Int(cs.inner_tag), ")",
                )
            else:
                writer.write(
                    "CorrelatedSubquery(kind=", Int(cs.kind),
                    ", outer_refs=#", len(cs.outer_refs),
                    ", inner_tag=", Int(cs.inner_tag), ")",
                )
        else:
            writer.write("Expr(tag=", Int(self.tag), ")")

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


# `_write_binop`, `_write_unop`, `_write_strop`
# live in `expr_helpers.mojo` (alongside `binop_name` /
# `unop_name` / `flatten_and_conjuncts`) to keep `expr.mojo` smaller.
# `Expr.write_to` imports them directly via the
# `from .expr_helpers import _write_binop, ...` line at the top of this
# file.


# =============================================================================
# `.over()` on an AGGREGATE operand — see `Expr.with_window_spec`
# =============================================================================
#
# AGG_* -> PF_* by NUMBER, not by name: `agg_expr.mojo` and `partition_expr.mojo`
# both import this module, so importing either here is a cycle. The same
# mirror `col_expr.mojo`'s aggregate-as-expression factories keep, and the
# same mapping the SDK's window lowering (not in this tree) states; pinned
# against the real constants by `test_col_expr_desugar_verbs`.
def _agg_op_as_partition_func(op: UInt8) -> UInt8:
    """AGG_SUM 0 -> PF_SUM 20, AGG_COUNT 1 -> PF_COUNT 22, AGG_MIN 2 ->
    PF_MIN 23, AGG_MAX 3 -> PF_MAX 24, AGG_MEAN 4 -> PF_AVG 21; anything
    else -> 255 (no window form)."""
    if op == 0:
        return UInt8(20)
    if op == 1:
        return UInt8(22)
    if op == 2:
        return UInt8(23)
    if op == 3:
        return UInt8(24)
    if op == 4:
        return UInt8(21)
    return UInt8(255)


# ★ A REFUSED `.over()`. The four `.over`
# overloads cannot raise, and an `abort` kills the caller's process, so the
# refusal RIDES THE WINDOW: its argument-column slot holds this prefix + why.
# Every PlanCarrier verb looks for it with `col_expr_bind.over_refusal` — the
# ONE column-reference walk, so a refusal under a MathFn / When / InList is
# seen too — before it builds a node: `with_columns` raises it, and
# `select` / `filter` carry it into a PROJECT whose one column is NAMED the
# refusal, kept as the plan's ROOT under every later verb
# (`filter_refusal.keep_refusal_at_root`; otherwise a verb after it lets the
# optimizer prune it), so the run fails -- by name over a parquet
# source, with the in-memory leaf's envelope text over an in-memory one. (A
# FILTER over the refusal would be dropped by the engine -- a filter over an
# unknown column answers EVERY row.)
# ⛔ MEASURED: a walk that looks through alias / cast / unary / binary only
# lets `filter(sqrt(<refused over>) > 1)` answer all 6 of 6 rows (DuckDB: 4)
# and `select([sqrt(<refused over>)])` die unnamed ("unsupported projection
# expression tag: 13").
comptime OVER_REFUSED_PREFIX = "Expr.over(...) is refused: "


def _refused_over(
    reason: String,
    var partition_by: List[String],
    var order_by: List[String],
    var descending: List[Bool],
) -> Expr:
    """A window carrying its own refusal. `func` 24 is PF_MAX by number (see
    `_agg_op_as_partition_func`): any aggregate that reads its column."""
    var w = Expr.window_fn(
        UInt8(24),
        String(OVER_REFUSED_PREFIX) + reason,
        0,
        PartitionFrame.default_unordered(),
    )
    return w^.with_window_spec(partition_by^, order_by^, descending^)


def _agg_fn_over(
    var agg: Expr,
    var partition_by: List[String],
    var order_by: List[String],
    var descending: List[Bool],
) -> Expr:
    """`EXPR_AGG_FN(op, col(c)).over(...)` -> the whole-partition
    `EXPR_WINDOW_FN(PF_op, c)` with that spec. A computed operand or an
    aggregate with no window form is REFUSED BY NAME (`_refused_over`)."""
    var pf = _agg_op_as_partition_func(agg.agg_fn_op())
    if pf == UInt8(255):
        return _refused_over(
            String("aggregate op ")
            + String(Int(agg.agg_fn_op()))
            + String(
                " has no window form; `.over()` takes sum / mean / avg /"
                " count / min / max of a column"
            ),
            partition_by^, order_by^, descending^,
        )
    ref child = agg.agg_fn_child_ref()
    if not child.is_col_ref():
        return _refused_over(
            String(
                "an aggregate BROADCAST takes a plain column"
                " (`col(\"v\").sum().over(\"g\")`); an aggregate of a"
                " COMPUTED expression is not served (the window vocabulary"
                " names one input column, and a window over a column an"
                " earlier `with_columns` computed is outside the window"
                " executor's envelope)"
            ),
            partition_by^, order_by^, descending^,
        )
    var w = Expr.window_fn(
        pf, child.col_ref_name(), 0, PartitionFrame.default_unordered()
    )
    return w^.with_window_spec(partition_by^, order_by^, descending^)
