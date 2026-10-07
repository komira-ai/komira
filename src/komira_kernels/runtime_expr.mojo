# =============================================================================
# komira_kernels.runtime_expr — Runtime LogicalPlan walker AST surface
# =============================================================================
#
# This module owns the RUNTIME side of the AST surface:
#   - `RuntimeExpr` POD tagged union (the runtime LogicalPlan walker's
#     entry struct, stored as `List[RuntimeExpr]` AoS-as-index-arena).
#   - 60+ `EXPR_*` Int tag constants (the runtime tag discriminator space
#     dispatched on by the per-DType filter / project walker arms).
#   - 50+ `make_*` factory helpers (the public surface that SDK
#     lowering + compiler translators call to construct runtime AST
#     nodes from a LogicalPlan Expr tree).
#
# The runtime walker AST is structurally distinct from the comptime typed
# `ExprBool` family:
#   - Runtime: flat AoS-of-tags-and-indices dispatched at evaluation time
#     by `ExpressionExecutor` and the per-Stage walker arms. Plan shape
#     is unknown at compile time.
#   - Comptime: nested parametric structs monomorphized at compile time
#     via `PredicateFilter[E.X[S]]`. Plan shape known at compile time.
#
# The two are parallel hierarchies and must not be unified: they share NAMES
# only, never a trait. Keeping them in separate files makes the physical
# separation match the logical one.
#
# Main consumers: the SDK's untyped-expression lowering, the compiler's
# LogicalPlan Expr -> RuntimeExpr translator, `komira_eval.expression_executor`
# (the runtime walker over the tag space), and the engine operators' runtime
# stage programs.
#
# =============================================================================
# Runtime surface — RuntimeExpr POD tagged-union + factory helpers
# =============================================================================
#
# Mojo has no true `enum`; the runtime variant is modeled as:
#   - `EXPR_*` Int constants (the tag space).
#   - A single `@fieldwise_init` POD struct with `kind` + payload union.
#
# The same `RuntimeExpr` type carries Lit/Col leaves and binop/And/Or
# internals, which is what ExpressionExecutor needs.
#
# Children of binop / And / Or nodes are referenced by `left` / `right`
# slot indices into a parent `List[RuntimeExpr]` pool (AoS-as-index-arena).
# This is the runtime analogue of the comptime-parametric struct nesting.


# -----------------------------------------------------------------------------
# Tag space
# -----------------------------------------------------------------------------
# Integer kind constants (comptime Int) to avoid any parameter-trait
# dependency. New tags are appended after the existing tag space; tags are
# never renumbered.

comptime EXPR_LIT_I64: Int = 1
comptime EXPR_LIT_F64: Int = 2
comptime EXPR_LIT_BOOL: Int = 3
comptime EXPR_COL: Int = 4
comptime EXPR_GT_I64: Int = 5
comptime EXPR_LT_I64: Int = 6
comptime EXPR_GT_F64: Int = 7
comptime EXPR_LT_F64: Int = 8
comptime EXPR_EQ_I64: Int = 9
comptime EXPR_AND: Int = 10
comptime EXPR_OR: Int = 11
# GE/LE comparison tags (TPC-H Q6's 4-conjunction filter needs GE_I64 +
# GE_F64 + LE_F64 in addition to LT_I64 / LT_F64).
comptime EXPR_GE_I64: Int = 12
comptime EXPR_GE_F64: Int = 13
comptime EXPR_LE_F64: Int = 14
# Arithmetic + I32 literal tags for the per-DType project walker.
#
# Semantics (mirrors DuckDB / Polars conventions):
#   - Int64 ADD/SUB/MUL: native Int64 ops, two's-complement wrap on overflow.
#     No overflow detection.
#   - Int64 DIV: truncated integer division (Mojo `a // b` on Int64 truncates
#     toward zero). DIV-BY-ZERO RAISES Error in the walker.
#   - Float64 ADD/SUB/MUL/DIV: IEEE-754 default. NaN/Inf propagate; div-by-zero
#     produces +Inf / -Inf / NaN (NO raise).
#   - I32 LIT: i64 field reused as carrier; walker casts at append time
#     (RuntimeExpr layout unchanged to avoid a POD-widening cost).
#
# Modulo (EXPR_MOD_I64) is not in this tag group.
comptime EXPR_ADD_I64: Int = 15
comptime EXPR_SUB_I64: Int = 16
comptime EXPR_MUL_I64: Int = 17
comptime EXPR_DIV_I64: Int = 18
comptime EXPR_ADD_F64: Int = 19
comptime EXPR_SUB_F64: Int = 20
comptime EXPR_MUL_F64: Int = 21
comptime EXPR_DIV_F64: Int = 22
comptime EXPR_LIT_I32: Int = 23
# 4 NEW arithmetic
# opcodes mirroring EXPR_{ADD,SUB,MUL,DIV}_I64. Semantics match I64:
# native Int32 ops, two's-complement wrap on ADD/SUB/MUL overflow; DIV
# truncated, div-by-zero raises. Walker eval_to_list_i32_from_view +
# _eval_scalar_i32_from_view (NEW) handle the recursive evaluation.
comptime EXPR_ADD_I32: Int = 24
comptime EXPR_SUB_I32: Int = 25
comptime EXPR_MUL_I32: Int = 26
comptime EXPR_DIV_I32: Int = 27
# Unary
# Float64 opcode. First arity-1 tag in the runtime expr catalog (prior
# tags are all arity 0 / 2). Required precursor for AGG_CORR Option A
# (Pearson closed-form `r = num / sqrt(denom_x * denom_y)`). Semantics:
# IEEE-754 default — sqrt(<0)=NaN, sqrt(NaN)=NaN, sqrt(+Inf)=+Inf,
# sqrt(-0.0)=-0.0. No raise on any input. NULL-mask semantics out of
# scope at this evaluator layer (matches existing MUL/DIV pattern;
# explicit NULL handling deferred to a higher layer if needed).
comptime EXPR_SQRT_F64: Int = 28

# Additional Float64 scalar math
# opcodes for the `haversine` example (great-circle distance over lat/lon).
# Follow the EXPR_SQRT_F64 arity-1 single-`left`-slot convention for the
# unary ops; EXPR_ATAN2_F64 is arity-2 (uses `left` + `right` like the
# arithmetic binops). All emit Float64; IEEE-754 default on edge inputs
# (no raise). NULL-mask semantics match the existing arithmetic ops at this
# evaluator layer.
comptime EXPR_SIN_F64: Int = 63
comptime EXPR_COS_F64: Int = 64
comptime EXPR_ASIN_F64: Int = 65
comptime EXPR_RADIANS_F64: Int = 66
comptime EXPR_ATAN2_F64: Int = 67

# `pow(base, exponent)` binary Float64 op (mirrors
# EXPR_ATAN2_F64: arity-2, `left`=base, `right`=exponent). Emits Float64 via
# libm `pow` (handles a negative base with an integer-valued exponent, e.g.
# `pow(corr, 2)`). NULL-mask + IEEE-754 edge semantics match the other math ops.
comptime EXPR_POW_F64: Int = 87

# THE GENERIC UNARY-MATH NODE.
#
# ⭐ WHY A GENERIC NODE RATHER THAN ONE TAG PER OP. `MATH_*` in
# `komira_plan_expr.expr` holds many unary ops. With a per-op tag, an op with
# no tag makes `lower_untyped_expr._translate_node`'s EXPR_MATH_FN arm raise
# `UnsupportedByLowerUntypedExpr`, which `compute_project` turns into a
# DECLINE and `materialize_subplan` into a hard REFUSAL for a computed PROJECT
# over a breaker (so `sqrt(avg(v))` would answer while `exp(avg(v))` refused).
#
# ⛔ THE POINT OF THE GENERIC FORM IS THAT THE **NEXT** OP CANNOT MISS IT. A
# per-op tag makes adding `MATH_<new>` a four-file edit (alias + factory +
# three walker arms) that nothing forces. This node carries the `KMATH_*` op
# code in `col_idx` and dispatches through the ONE ladder that already covers
# the whole space, `scalar_math._apply_unary` — so a new op needs a line THERE
# and nowhere else, and `_apply_unary`'s own space must stay equal to `MATH_*`.
#
# `col_idx` is the payload field (unused by every other arity-1 node); `left`
# is the child pool slot, `right` is 0, per the EXPR_SQRT_F64 convention.
#
# ⚠ THE FIVE TAGS ABOVE ARE NOT RETIRED. They are still emitted for their five
# ops so that every existing kernel-direct test, plan assertion and bench keeps
# observing the node kind it was written against; this tag serves the other
# nineteen. Both routes reach the same libm call.
comptime EXPR_MATH_UNARY_F64: Int = 88

# UNSIGNED INT64 comparison
# family. A U64 column comparison CANNOT route through EXPR_*_I64: a U64 value
# above Int64.MAX read as Int64 wraps negative, so a signed compare silently
# mis-orders (the same class as the SW bugs). These tags read both sides via
# the per-cell walker's `read_u64` accessor and compare as native UInt64
# (unsigned ordering). EQ/NEQ are bit-equality (sign-agnostic) but are kept in
# this family for consistency. NOTE: narrow unsigned (U8/U16/U32) do NOT need
# these — their max fits positively in Int64, so the existing EXPR_*_I64 arm is
# correct once `read_i64` reads them at their unsigned width. Only U64 needs the
# unsigned compare. The planner does not emit these tags;
# the per-cell walker arm + RuntimeExpr factories below make the substrate
# correct and kernel-direct-testable today.
comptime EXPR_GT_U64: Int = 68
comptime EXPR_GE_U64: Int = 69
comptime EXPR_LT_U64: Int = 70
comptime EXPR_LE_U64: Int = 71
comptime EXPR_EQ_U64: Int = 72

# F2 NUMERIC-NE — numeric `!=`
# (NE) comparison family. STRING `!=` already self-serves via EXPR_NEQ_STRING;
# the numeric per-cell walker had EQ/GT/GE/LT/LE arms but NO inequality, so a
# numeric `col != lit` predicate demoted off the row path. These three tags are
# the exact negation of the corresponding EQ arms (I64 / F64 / U64) and reuse
# the same `_eval_i64/f64/u64_from_source` leaf readers. Like the other compare
# arms, NE compares the raw cell value (no 3VL null-skip) — byte-identical to
# the column sel-kernel `BIN_OP_NE` path, which also compares raw values.
comptime EXPR_NE_I64: Int = 73
comptime EXPR_NE_F64: Int = 74
comptime EXPR_NE_U64: Int = 75

# F10 IS NULL / IS NOT NULL — GENERIC
# per-cell validity test (any dtype), distinct from the STRING-only
# EXPR_IS_NULL_STRING (47) / EXPR_IS_NOT_NULL_STRING (48) which read a
# StringArray's validity on the column path. These read the FORM-ii row
# validity bitmap via the orientation-poly `CellSource.is_null(row, col_idx)`
# accessor. `col_idx` carries the LOGICAL column index of the operand (the
# arity-1 leaf-pattern shape, mirroring make_col / make_col_bool). On the row
# path the RowCellSource resolves it against the block's validity_offset; bit=1
# means NULL. IS NULL emits True on null rows; IS NOT NULL emits True on
# present rows (3VL-correct for the unary null tests).
comptime EXPR_IS_NULL_CELL: Int = 76
comptime EXPR_IS_NOT_NULL_CELL: Int = 77

# CASE/WHEN + CAST — scalar
# projection-expression nodes for the row PROJECT walker.
#
# EXPR_CASE_I64 / EXPR_CASE_F64 (arity-N via side-pool): a CASE WHEN ... THEN ...
# ELSE ... END producing an Int64 / Float64 value. The variable-arity branch
# structure (N condition/then pairs + 1 else) cannot live in the fixed RuntimeExpr
# POD, so `col_idx` is REPURPOSED as an index into a NEW side-pool
# `ExpressionExecutor.when_pool: List[List[Int]]` (parallel to in_list_pool /
# string_pool). The flattened slot list is `[cond0, then0, cond1, then1, ...,
# condK-1, thenK-1, elseSlot]` — odd length, the last slot is the ELSE value, the
# preceding pairs are (condition-bool-subtree, then-value-subtree). The walker
# arm walks pairs in order, evaluating each condition via `_eval_bool_from_source`
# and returning the first matching THEN value (via `_eval_{i64,f64}_from_source`);
# if none match it returns the ELSE value. The I64 vs F64 family is chosen once
# at the CASE root (by whether any THEN/ELSE branch is float), mirroring the
# arithmetic walker's `as_float` discipline.
#
# EXPR_NULL (arity-0): a NULL-marker value leaf, used as a THEN/ELSE branch in a
# CASE whose corresponding SQL branch is a NULL literal. As a VALUE it evaluates
# to 0 (the dtype-zero sentinel); its nullity is queried separately by the
# project walker's `_cell_is_null_from_source` driver (which sets the output
# validity bit when a CASE selects an EXPR_NULL branch). A computed column that
# can never select a NULL branch carries no validity bit (matches the existing
# "computed numeric column is always non-null" rule).
comptime EXPR_CASE_I64: Int = 78
comptime EXPR_CASE_F64: Int = 79
comptime EXPR_NULL: Int = 80

# CAST — numeric cast value node. EXPR_F64_TO_I64 (tag 54) is
# the existing Float64 -> Int64 truncating cast (added for agg-result narrowing;
# now also wired into the per-cell `_eval_i64_from_source` walker for CAST(f AS
# bigint)). EXPR_I64_TO_F64 is the inverse widening cast: evaluate the child as
# Int64 and widen to Float64 (CAST(i AS double) over a computed Int64 sub-expr).
# Both are arity-1: child slot in `left`. In-FAMILY numeric casts (i32->i64,
# i64->i64, f32->f64) need NO node — the source read auto-widens and the output
# evaluator family is chosen by the cast target dtype.
comptime EXPR_I64_TO_F64: Int = 81

# EXTRACT / date-part — temporal field extraction value node.
# EXPR_EXTRACT_I64 (arity-1): read the child epoch as Int64 (Date32 = i32 days;
# Date64 / Timestamp = i64 ticks), convert to a civil (y,m,d[,h,mi,s]) and emit
# the requested calendar/clock field as Int64.
#   * `left`    — child pool slot (the temporal column, read via the i64 walker;
#                 Date32 i32-backing / Date64+Timestamp i64-backing both widen
#                 to Int64 through `CS.read_i64`).
#   * `col_idx` — the EXTRACT unit selector (EXTRACT_YEAR / MONTH / DAY / QUARTER
#                 / HOUR / MINUTE / SECOND — the field family ONLY; date_trunc
#                 returns a temporal value not an Int and is out of this node).
#   * `i64`     — ticks-per-day for the child's temporal unit: 1 for Date32
#                 (raw day count), 86_400 for Timestamp(s), 86_400_000 for
#                 Date64 / Timestamp(ms), 86_400_000_000 for Timestamp(us),
#                 86_400_000_000_000 for Timestamp(ns). The walker floor-divides
#                 the epoch by this to recover days-since-1970, then takes the
#                 within-day remainder (× the per-day tick rate) for clock fields.
# Output is always Int64 (a date part is an integer); when the project root's
# numeric family is float the lowering wraps this node in EXPR_I64_TO_F64.
comptime EXPR_EXTRACT_I64: Int = 82

# Mirror of komira_plan_expr.expr EXTRACT_* unit constants — kept here so the
# runtime walker arm + the row lowering don't have to reach across to the SDK
# IR module for the field selector. These MUST equal the EXPR_* values in
# komira_plan_expr.expr (EXTRACT_YEAR=0 ... EXTRACT_SECOND=6).
comptime RT_EXTRACT_YEAR: Int = 0
comptime RT_EXTRACT_QUARTER: Int = 1
comptime RT_EXTRACT_MONTH: Int = 2
comptime RT_EXTRACT_DAY: Int = 3
comptime RT_EXTRACT_HOUR: Int = 4
comptime RT_EXTRACT_MINUTE: Int = 5
comptime RT_EXTRACT_SECOND: Int = 6

# The DAY-INDEX units. Same mirror
# rule as above: these MUST equal `komira_plan_expr.expr.EXTRACT_DAYOFWEEK` =
# 7 / `EXTRACT_ISODOW` = 8 / `EXTRACT_DAYOFYEAR` = 9.
#
# ⛔ `RT_EXTRACT_DAYOFWEEK` AND `RT_EXTRACT_ISODOW` ARE TWO SELECTORS AND NOT
# ONE WITH AN OFFSET. MEASURED on DuckDB v1.5.3: `dayofweek` is Sunday=0 and
# `isodow` is Sunday=7; on the other six days they are the same number, so a
# collapse here is invisible to any row that is not a Sunday.
comptime RT_EXTRACT_DAYOFWEEK: Int = 7
comptime RT_EXTRACT_ISODOW: Int = 8
comptime RT_EXTRACT_DAYOFYEAR: Int = 9

# The ISO WEEK-DATE units. Mirrors
# `EXTRACT_WEEK` = 10 / `EXTRACT_ISOYEAR` = 11 / `EXTRACT_YEARWEEK` = 12.
#
# ⛔ `RT_EXTRACT_ISOYEAR` MUST NOT BE SERVED BY THE `RT_EXTRACT_YEAR` ARM.
# They differ on up to three days at each end of every year
# (`isoyear(DATE '1999-01-01')` = 1998, `year` = 1999).
comptime RT_EXTRACT_WEEK: Int = 10
comptime RT_EXTRACT_ISOYEAR: Int = 11
comptime RT_EXTRACT_YEARWEEK: Int = 12

# The SUB-SECOND units. `EXTRACT_MILLISECOND` = 13,
# `EXTRACT_MICROSECOND` = 14.
#
# ⚠ THESE TWO DECLINE OVER A DATE32 AND THAT IS NOT AN OVERSIGHT. `i64` here
# carries ticks-per-DAY, and for a Date32 that is 1 — so ticks-per-second
# would be `1 // 86400` = 0 and the kernel would divide by zero. The capability
# gate demotes the Date32 case to the column path, which answers the measured
# constant 0, exactly as it already does for HOUR/MINUTE/SECOND.
comptime RT_EXTRACT_MILLISECOND: Int = 13
comptime RT_EXTRACT_MICROSECOND: Int = 14

# date_trunc — temporal-OUTPUT value node. EXPR_DATE_TRUNC_I64
# (arity-1): read the child epoch as Int64, round it DOWN to the start of the
# requested period, and emit the truncated epoch (still as Int64 — the cell
# write happens at the input temporal dtype's width by the project walker).
# Unlike EXPR_EXTRACT_I64 (which emits an Int FIELD), this node's output dtype
# is the INPUT temporal dtype (Date32->Date32, Date64/Timestamp->same unit), so
# the lowering threads the temporal out-dtype back to the resolver and the
# walker writes a 4-byte (Date32) or 8-byte (Date64/Timestamp) temporal cell.
#   * `left`    — child pool slot (the temporal column, read via the i64 walker).
#   * `col_idx` — the RT_TRUNC_* unit selector.
#   * `i64`     — ticks-per-day for the child's temporal unit (1 for Date32-days,
#                 86_400_000 for Date64/Timestamp(ms), etc.). The walker derives
#                 ticks-per-second (= tpd/86400) for sub-day truncs (HOUR/MINUTE/
#                 SECOND/MILLISECOND/MICROSECOND). Date32 (tpd=1) makes every
#                 sub-day trunc a no-op (no sub-day field) — matches the column
#                 kernel `_date_trunc_date32_range`.
comptime EXPR_DATE_TRUNC_I64: Int = 83

# Var-length byte/dictionary column leaves.
# These unblock the BINARY + DICTIONARY half of the typed-join payload
# passthrough (the FEED stage reads a build-payload column through these
# leaves; the downstream join drain re-emits it byte-exact / encoding-
# preserving). Both are EXTRACTION-ONLY leaves (arity 0) mirroring
# EXPR_COL_STRING; there is intentionally no combinator family here.
#
#   - EXPR_COL_BINARY (arity 0): BINARY column reference. Payload:
#     `col_idx` (frame-local column index, same semantic as EXPR_COL).
#     The walker reads each element's bytes via
#     `batch.column_as_binary(runtime_idx).get(row)` — BINARY is exactly
#     STRING WITHOUT UTF-8 validation, so the walker mirrors the STRING
#     leaf and emits `List[List[UInt8]]` (one byte-list per selected row).
#
#   - EXPR_COL_DICTIONARY (arity 0): DICTIONARY column reference. Payload:
#     `col_idx`. The walker reads the column via
#     `batch.column_as_dictionary(runtime_idx)` and PRESERVES the
#     dictionary encoding (int32 indices + shared dict StringArray buffer +
#     dict_size) rather than decoding to flat strings — the downstream
#     drain requires the output to stay ArrowType.DICTIONARY.
comptime EXPR_COL_BINARY: Int = 84
comptime EXPR_COL_DICTIONARY: Int = 85

# `REGEXP_LIKE` / `EXPR_REGEXP` per-cell filter predicate node. A row-source
# `regexp_like(col, 'pat')` filter previously DEMOTED to the column path because
# the per-cell row FILTER walker had no regex arm; this node closes that gap.
#
# Shape (arity 1 over the value column + a side-pool program):
#   - `left`    — pool slot of the value column child (EXPR_COL_STRING, read via
#                 CS.read_string at evaluation time).
#   - `col_idx` — REPURPOSED as the index into the NEW side-table
#                 `ExpressionExecutor.regex_pool: List[RegexProgram]`. The regex
#                 is COMPILED ONCE at segment/executor setup (the column oracle's
#                 same "build the RegexProgram once per call" discipline — see the
#                 PERF breadcrumb in `regexp_functions.mojo`) and reused per cell.
#                 tag-disambiguated from EXPR_COL (which uses col_idx as a column
#                 index) and from the other side-pool nodes (string/decimal/in-list/
#                 case) by the `kind` value.
#
# The walker reads the value cell as a String, then runs the compiled NFA's
# per-string `is_match` (unanchored — matches DuckDB `regexp_like` / `~`). This
# is a PORT of the column oracle `eval_regexp_like` / `regexp_like_scalar`, NOT a
# reimplementation: the same `RegexProgram` (Thompson NFA / Pike VM) is the leaf.
#
# Like the LIKE / string-comparison arms, the per-cell walker treats a row's
# cells as present (no 3VL null-skip here); the filter-context wrapper applies
# the standard null-collapse so NULL value rows never survive the WHERE.
#
# Carrying the COMPILED program (not just the pattern) in the side-pool keeps the
# arm self-contained: the only field threaded through the executor / payload is
# the `regex_pool`, and the compile (which RAISES on an invalid pattern) happens
# once at the `raises` segment-setup site, never in the per-cell hot loop.
comptime EXPR_REGEXP: Int = 86

# Mirror of komira_kernels.temporal_extract TRUNC_* unit constants — kept here so
# the runtime walker arm doesn't reach across to the column-kernel module. These
# MUST equal the TRUNC_* values in temporal_extract.mojo (TRUNC_YEAR=0 ...
# TRUNC_MICROSECOND=9). The SDK IR uses a DIFFERENT encoding (EXTRACT_TRUNC_*
# 16..25); the row lowering maps IR -> RT_TRUNC_* exactly as the column oracle
# maps IR -> kernel TRUNC_*.
comptime RT_TRUNC_YEAR: Int = 0
comptime RT_TRUNC_QUARTER: Int = 1
comptime RT_TRUNC_MONTH: Int = 2
comptime RT_TRUNC_WEEK: Int = 3
comptime RT_TRUNC_DAY: Int = 4
comptime RT_TRUNC_HOUR: Int = 5
comptime RT_TRUNC_MINUTE: Int = 6
comptime RT_TRUNC_SECOND: Int = 7
comptime RT_TRUNC_MILLISECOND: Int = 8
comptime RT_TRUNC_MICROSECOND: Int = 9

# Bool column primitives. Pre-existing tags EXPR_LIT_BOOL=3 (Bool
# literal, payload in `b`) + EXPR_AND=10 + EXPR_OR=11 (Bool combinators
# whose children produce Bool via comparison kernels) cover the
# "expression result is Bool" case. The TWO new tags below cover the
# "input column IS Bool" case:
#
#   - EXPR_COL_BOOL (arity 0): leaf that gathers a Bool column from
#     the source batch via `column_as_boolean` (BooleanArray, 1-bit
#     packed). Filter walker arm reads each bit + emits sel-mask;
#     Project walker arm reads each bit + appends to a Bool output
#     list. Payload: `col_idx`.
#
#   - EXPR_NOT_BOOL (arity 1): logical NOT over a Bool sub-expression.
#     Filter walker arm recurses on `left`, then takes the
#     set-complement within `input_sel`. Project walker arm recurses
#     on `left`, then negates each element. Payload: `left` carries
#     the child pool index.
#
# Composition with EXPR_AND / EXPR_OR works for free: the filter
# walker's recursive descent through AND children now sees
# EXPR_COL_BOOL / EXPR_NOT_BOOL as valid Bool-mask producers (alongside
# the existing comparison kernels).
#
# DEFERRED: EXPR_EQ_BOOL ("col_b == True") is unneeded because the
# optimizer rewrites `col_b == True` to `col_b` and `col_b == False`
# to `NOT col_b`. EXPR_OR_BOOL is unneeded for the same reason
# EXPR_AND_BOOL is unneeded: the existing EXPR_AND/EXPR_OR combinators
# compose over any Bool-producing children, including these new tags.
comptime EXPR_COL_BOOL: Int = 29
comptime EXPR_NOT_BOOL: Int = 30

# String column primitive tags. String storage is variable-length so it
# cannot live directly inside the fixed-size RuntimeExpr POD without
# slab-unsafe (heap-owning fields on byte-slab structs are banned).
# The substrate design uses a side-table on ExpressionExecutor:
# `string_pool: List[String]` carries the interned literal text; the
# RuntimeExpr.col_idx field is REPURPOSED to carry the string-pool
# index for EXPR_LIT_STRING (tag-disambiguated — different `kind` value
# vs EXPR_COL which uses col_idx as column index).
#
#   - EXPR_LIT_STRING (arity 0): literal String value. Payload: `col_idx`
#     repurposed as `string_pool_idx` (index into ExpressionExecutor.
#     string_pool: List[String]).
#
#   - EXPR_COL_STRING (arity 0): String column reference. Payload:
#     `col_idx` (frame-local column index, same semantic as EXPR_COL).
#
#   - EXPR_EQ_STRING (arity 2): element-wise String equality.
#     Children in `left`/`right` pool indices; both should resolve to
#     EXPR_COL_STRING or EXPR_LIT_STRING. Filter walker uses
#     `StringArray.get(row) == literal_or_col_string` per row.
#
#   - EXPR_NEQ_STRING (arity 2): element-wise String inequality.
#     Mirror of EXPR_EQ_STRING with `!=`.
#
# Not in this group:
#   - LIKE / regex (`EXPR_LIKE_STRING`, below).
#   - String-keyed hash/sort/distinct/join primitives (variable-length
#     payload in HeapSlot non-trivial; recommended pivot: dict-id
#     intern).
#   - GT/GE/LT/LE lexicographic comparisons (see the lexicographic tags).
#
# Composition with EXPR_AND / EXPR_OR works for free: the existing
# AND-chain walker recurses into Bool-producing children, including
# EXPR_EQ_STRING / EXPR_NEQ_STRING.
comptime EXPR_LIT_STRING: Int = 31
comptime EXPR_COL_STRING: Int = 32
comptime EXPR_EQ_STRING: Int = 33
comptime EXPR_NEQ_STRING: Int = 34

# Decimal128 column primitive tags. Decimal storage is 128-bit (16 bytes)
# unscaled + precision + scale metadata. The fixed-size RuntimeExpr POD
# cannot hold a 128-bit value without 2-field splitting AND would still
# lack precision/scale slots. The substrate design uses a side-table on
# ExpressionExecutor: `decimal_pool: List[DecimalSpec]` carries the
# (value, precision, scale) triple for literals; the RuntimeExpr.col_idx
# field is REPURPOSED to carry the decimal-pool index for EXPR_LIT_DECIMAL128
# (tag-disambiguated — different `kind` value vs EXPR_COL).
#
#   - EXPR_LIT_DECIMAL128 (arity 0): literal Decimal128 value. Payload:
#     `col_idx` repurposed as `decimal_pool_idx` (index into
#     ExpressionExecutor.decimal_pool: List[DecimalSpec]).
#
#   - EXPR_COL_DECIMAL128 (arity 0): Decimal128 column reference. Payload:
#     `col_idx` (frame-local column index, same semantic as EXPR_COL).
#     The walker reads precision/scale directly from the
#     `Decimal128Array.{precision,scale}` fields at gather time.
#
#   - EXPR_ADD_DECIMAL128 / EXPR_SUB_DECIMAL128 / EXPR_MUL_DECIMAL128 /
#     EXPR_DIV_DECIMAL128 (arity 2): per-row decimal arithmetic. Walker
#     calls `decimal_add_i128` / `decimal_sub_i128` / `decimal_mul_i128`
#     / `decimal_div_i128` from `komira_scalar_arithmetic.decimal_arith`
#     (overflow-checked, native SIMD[DType.int128, 1] arithmetic).
#     Result (precision, scale) computed via `decimal_{add,mul,div}_result_ps`.
#
#   - EXPR_EQ_DECIMAL128 / EXPR_NEQ_DECIMAL128 / EXPR_GT_DECIMAL128 /
#     EXPR_LT_DECIMAL128 / EXPR_GE_DECIMAL128 / EXPR_LE_DECIMAL128
#     (arity 2): per-row decimal comparison. Same-scale fast-path
#     (direct i128 compare); cross-scale rescales smaller-scale operand
#     UP via `rescale_i256_half_up` (no precision loss when scaling up).
#
# Not covered:
#   - Decimal256 (uncommon; covers DECIMAL(p,s) for p > 38).
#   - Null-mask propagation (matches STRING/BOOL v1 simplification).
#   - Decimal-keyed hash/sort/distinct/join primitives (variable-precision
#     payload in HeapSlot non-trivial).
#
# Composition with EXPR_AND / EXPR_OR works for free: the existing
# AND-chain walker recurses into Bool-producing children, including
# the 6 Decimal comparison primitives above.
comptime EXPR_LIT_DECIMAL128: Int = 35
comptime EXPR_COL_DECIMAL128: Int = 36
comptime EXPR_ADD_DECIMAL128: Int = 37
comptime EXPR_SUB_DECIMAL128: Int = 38
comptime EXPR_MUL_DECIMAL128: Int = 39
comptime EXPR_DIV_DECIMAL128: Int = 40
comptime EXPR_EQ_DECIMAL128: Int = 41
comptime EXPR_NEQ_DECIMAL128: Int = 42
comptime EXPR_GT_DECIMAL128: Int = 43
comptime EXPR_LT_DECIMAL128: Int = 44
comptime EXPR_GE_DECIMAL128: Int = 45
comptime EXPR_LE_DECIMAL128: Int = 46


# -----------------------------------------------------------------------------
# Null-aware
# String primitives.
#
# EXPR_IS_NULL_STRING + EXPR_IS_NOT_NULL_STRING (arity 1): emit Bool per
# row by reading `StringArray.is_null(row)` (or its negation) on a child
# that must resolve to EXPR_COL_STRING. Child slot is stored in the
# `col_idx` field for simplicity (avoids using `left` which is `Int` —
# both work but col_idx aligns with the LEAF-pattern: walker reads child
# col-name from `column_names[child_node.col_idx]`).
#
# Three-valued-logic note: with EXPR_IS_NULL_STRING + the null-skip
# behavior added to EXPR_EQ_STRING / EXPR_NEQ_STRING walker arms, the
# composable filter pipeline correctly implements SQL WHERE 3VL — every
# null produces "unknown" which AND-composes to filter-fail. Out of
# scope for this slot: EXPR_OR over Bool combinators with NULL (would
# need EXPR_OR_BOOL_3VL; EXPR_OR is not in the filter walker catalog
# today).
comptime EXPR_IS_NULL_STRING: Int = 47
comptime EXPR_IS_NOT_NULL_STRING: Int = 48

# -----------------------------------------------------------------------------
# Byte-wise lexicographic GT / LT / GE / LE comparisons over String
# operands.
#
# Shape mirrors EXPR_EQ_STRING / EXPR_NEQ_STRING exactly:
#   - arity 2 (left + right pool indices)
#   - each child must resolve to EXPR_COL_STRING or EXPR_LIT_STRING
#   - filter walker arm reads operands via StringArray.get(row) / the
#     string_pool side-table, compares byte-wise lexicographic
#   - NULL handling: SQL WHERE 3VL — per-row is_null(row) short-circuit
#     at the top of each col-bearing sub-case excludes rows where
#     either operand is NULL (NULL > x produces "unknown", excluded).
#
# Byte-wise lexicographic equals UTF-8 codepoint lexicographic for
# valid UTF-8 byte sequences (canonical DuckDB / Postgres ORDER BY
# semantics for non-collated String columns). Uses a free helper
# `_str_compare(a: String, b: String) -> Int` (memcmp-style return:
# <0 / 0 / >0) defined in expression_executor.mojo above the walker
# arm body; mirrors `sort_lex.mojo:_str_lt`.
comptime EXPR_GT_STRING: Int = 49
comptime EXPR_LT_STRING: Int = 50
comptime EXPR_GE_STRING: Int = 51
comptime EXPR_LE_STRING: Int = 52

# -----------------------------------------------------------------------------
# SQL LIKE pattern
# matching on String columns.
#
# Pattern semantics (PostgreSQL/MySQL/DuckDB compatible):
#   - `%`  matches zero or more CHARACTERS.
#   - `_`  matches exactly one UTF-8 CHARACTER (1-4 bytes).
#   - Other bytes match themselves (literal).
#
# Case-sensitive. The walker's arm calls the ONE shared matcher,
# `komira_column_kernels.string_comparison.like_match_string`, so `_` is one
# character here exactly as in the columnar kernel (`'é' LIKE '_'` is
# true). ESCAPE clause + ILIKE (case-insensitive) are out of scope.
#
# Shape (arity 2):
#   - `left`  -> pool slot of EXPR_COL_STRING (the value column).
#   - `right` -> pool slot of EXPR_LIT_STRING (the pattern string,
#                interned into string_pool side-table on ExpressionExecutor;
#                col_idx of the lit node carries the pool index).
#
# The walker arm validates both operand shapes and raises on the
# col-vs-col or lit-vs-col cases (SDK lowering never emits those — LIKE
# with a column-valued pattern is a degenerate SQL shape).
#
# Filter walker reads col via batch.column_as_string(...), reads pattern
# once from string_pool, and per-row calls `_string_like_match(text,
# pattern) -> Bool`. SQL WHERE 3VL: NULL value -> row excluded (mirror
# EXPR_EQ_STRING precedent).
comptime EXPR_LIKE_STRING: Int = 53


# -----------------------------------------------------------------------------
# Unary
# Float64 -> Int64 narrowing cast. Arity-1 (single `left` child slot, same
# convention as EXPR_SQRT_F64). The multi-agg HashAgg substrate stores every
# accumulator in the Float64 channel, so an integer-result agg (COUNT, or
# Int64-input SUM/MIN/MAX) that lands in a multi-agg / AVG-decomp shape emits
# its result column as Float64. The Step 10b / 11b post-stage Project wraps
# such a column in EXPR_F64_TO_I64 + VAL_DT_I64 so the materialized column
# carries the planner-declared INT64 dtype. Truncation-toward-zero (Mojo
# `Int64(f)` semantics) is exact for these values — an integer aggregate
# accumulated in the F64 channel is a whole number for any input < 2^53.
comptime EXPR_F64_TO_I64: Int = 54


# -----------------------------------------------------------------------------
# Int64
# less-than-or-equal. Sibling to existing EXPR_LT_I64 / EXPR_GE_I64 / EXPR_LE_F64
# tags. Arity 2 (left + right pool slot indices). Walker dispatches to the
# existing `_dispatch_comparison[DType.int64, BIN_OP_LE]` helper (sel_kernels
# substrate already covers BIN_OP_LE for every primitive DType — only the
# expr-catalog leaf was missing). Unblocks TPC-H Q1 date-filter shape
# `WHERE shipdate <= DATE '1998-09-02'` which the SDK lowered to BIN_LE on
# Int32-mapped-to-RUNTIME_DTYPE_I64. No payload field changes — reuses the
# binary 7-arg ctor exactly as EXPR_LT_I64 does.
comptime EXPR_LE_I64: Int = 56


# -----------------------------------------------------------------------------
# Float64
# equality. Sibling to existing EXPR_EQ_I64 / EXPR_EQ_STRING / EXPR_EQ_DECIMAL128
# tags. Arity 2 (left + right pool slot indices). Walker dispatches to the
# existing `_dispatch_comparison[DType.float64, BIN_OP_EQ]` helper (sel_kernels
# substrate already covers BIN_OP_EQ for every primitive DType — only the
# expr-catalog leaf was missing). Unblocks TPC-H Q15 supplier-revenue shape
# `WHERE total_revenue = max_revenue` where the sub-query feeds Float64
# revenue values. No payload field changes — reuses the binary 7-arg ctor
# exactly as EXPR_LT_F64 / EXPR_LE_F64 do.
comptime EXPR_EQ_F64: Int = 57


# -----------------------------------------------------------------------------
# Float64-vs-Int64 mixed-family comparison
# tags. The existing EXPR_*_F64 family uses
# `_dispatch_comparison_from_view[F64]` which calls
# `column_as_primitive_float64` directly — that raises if the source
# column is INT64-backed. SQL semantics (and DuckDB / Polars) require
# implicit widening when comparing a F64 operand against an I64 operand.
#
# These 5 NEW tags route through `_eval_cmp_f64_mixed_from_view` which
# evaluates both children via `eval_to_list_f64_from_view` (the
# already-tested F64 walker that auto-widens i64 columns / literals to
# Float64 via `Scalar[DType.float64](int_val)`) and runs a per-row scalar
# compare. Closes TPC-H Q11 `part_value > __scalar_subq_0` shape
# (F64 column vs I64-dtype-tagged subquery output) and similar
# F64-vs-I64 mismatches that the optimizer can't normalize because
# there is no EXPR_CAST in the runtime catalog.
#
# Arity 2 (left + right pool slot indices). The arm dispatches the
# concrete operator (LT/LE/GT/GE/EQ) by tag identity inside the walker
# — no payload-field repurposing needed.
comptime EXPR_LT_F64_MIXED: Int = 58
comptime EXPR_LE_F64_MIXED: Int = 59
comptime EXPR_GT_F64_MIXED: Int = 60
comptime EXPR_GE_F64_MIXED: Int = 61
comptime EXPR_EQ_F64_MIXED: Int = 62


# -----------------------------------------------------------------------------
# Bool
# IN-list membership test on a single child column. The child operand
# lives in `node.left` (pool slot index), and the IN-list value table
# lives at `ExpressionExecutor.in_list_pool[node.col_idx]` (a side-table
# parallel to string_pool / decimal_pool — the `col_idx` field is
# REPURPOSED as the side-pool index for IN-list nodes; tag-disambiguated
# from EXPR_COL which uses `col_idx` as a column index).
#
# Why a side-pool (and not nested pool slots): the value list is a
# `List[ScalarValue]` of variable size, and ScalarValue carries a
# `String` field that cannot live inside the fixed-size RuntimeExpr POD
# without a heap-owning child. The string_pool / decimal_pool precedent
# (string and decimal literals) already handles variable
# / heap-owning payloads via the same side-table pattern.
#
# Composition with EXPR_AND is supported for free (EXPR_IN_LIST returns
# Bool; conjunctions over it walk the standard recursive AND arm). Per-
# DType dispatch happens INSIDE the walker arm at evaluation time based
# on the runtime column's ArrowType — int64 / int32 / float64 / string /
# bool / dictionary, mirroring `compiler_eval_in_list._eval_in_list`.
# K=0 short-circuits to all-false (matches the SDK `Expr.in_list(...)`
# empty-fold and defends against any IR construction route that bypasses
# `_rewrite_in_expr`'s 5a fold).
#
# NULL semantics (SQL-Kleene 3VL): the walker arm treats NULL column
# values as non-matches (returns False on null rows). The downstream
# filter-context wrapper (StageRuntimeProgram's filter root_idx path)
# applies the standard `_collapse_nulls_to_false` semantics — null rows
# never survive the filter, matching SQL Kleene WHERE-clause behavior.
# This mirrors `compiler_eval_in_list._eval_in_list`'s
# non-null-aware-then-collapse design.
comptime EXPR_IN_LIST: Int = 55


# -----------------------------------------------------------------------------
# RuntimeExpr POD tagged-union
# -----------------------------------------------------------------------------
# Payload union — only the field(s) matching `kind` are meaningful:
#   kind == EXPR_LIT_I64  -> i64
#   kind == EXPR_LIT_F64  -> f64
#   kind == EXPR_LIT_BOOL -> b
#   kind == EXPR_COL      -> col_idx (frame-local column index)
#   kind in {EXPR_GT_*, EXPR_LT_*, EXPR_EQ_*, EXPR_AND, EXPR_OR}
#                         -> left, right (pool slot indices)
#
# (Copyable, Movable, ImplicitlyCopyable) is the canonical POD super-trait
# trio under Mojo 1.0.0b1; matches the comptime typed expression trait
# family. POD layout (no heap-owning fields) means no
# stale-slab hazard when stored in `List[RuntimeExpr]`.

@fieldwise_init
struct RuntimeExpr(Copyable, Movable, ImplicitlyCopyable):
    var kind: Int
    var i64: Int64
    var f64: Float64
    var b: Bool
    var col_idx: Int
    var left: Int     # slot id in pool (NOT a pointer)
    var right: Int    # slot id in pool


# -----------------------------------------------------------------------------
# Factory helpers
# -----------------------------------------------------------------------------
# Encapsulate the tag/field setup so callers never touch RuntimeExpr's raw
# 7-arg constructor.

def make_lit_i64(v: Int64) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LIT_I64, v, 0.0, False, 0, 0, 0)


def make_lit_bool(v: Bool) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LIT_BOOL, 0, 0.0, v, 0, 0, 0)


def make_gt_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_GT_I64, 0, 0.0, False, 0, left, right)


def make_eq_i64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Int64 equality. Public sibling of make_gt_i64 / make_ne_i64
    (the row-segment had a private `_make_eq_i64` for the same RuntimeExpr; this
    exports it for the kernel-direct test seam)."""
    return RuntimeExpr(EXPR_EQ_I64, 0, 0.0, False, 0, left, right)


def make_and(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_AND, 0, 0.0, False, 0, left, right)


# disjunction combinator. Arity-2; both `left` / `right` are pool slot
# indices into a Bool sub-expr (typically a comparison or a nested
# AND/OR). The walker arm computes the union of each child's true-sel
# within `input_sel` via a two-pointer merge. Closes TPC-H Q7's
# nation-pair filter shape `(n1='FRANCE' AND n2='GERMANY') OR
# (n1='GERMANY' AND n2='FRANCE')`.
def make_or(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_OR, 0, 0.0, False, 0, left, right)


# Mixed-family compare factories. Used by
# `lower_untyped_expr._translate_binary` when one binary operand
# resolves to RUNTIME_DTYPE_I64 and the other to RUNTIME_DTYPE_F64.
# The walker arm pre-evaluates both children via the
# `eval_to_list_f64_from_view` widener and runs scalar compare per row.
def make_lt_f64_mixed(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LT_F64_MIXED, 0, 0.0, False, 0, left, right)


def make_le_f64_mixed(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LE_F64_MIXED, 0, 0.0, False, 0, left, right)


def make_gt_f64_mixed(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_GT_F64_MIXED, 0, 0.0, False, 0, left, right)


def make_ge_f64_mixed(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_GE_F64_MIXED, 0, 0.0, False, 0, left, right)


def make_eq_f64_mixed(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_EQ_F64_MIXED, 0, 0.0, False, 0, left, right)


# -----------------------------------------------------------------------------
# GE/LE factories (TPC-H Q6 untyped filter).
# -----------------------------------------------------------------------------
# Adds the seven additional factories needed to express Q6's filter shape:
#   l_shipdate >= 1994-01-01   (GE_I64)
#   AND l_shipdate < 1995-01-01 (LT_I64)
#   AND l_discount >= 0.05     (GE_F64)
#   AND l_discount <= 0.07     (LE_F64)
#   AND l_quantity < 24.0      (LT_F64)
#
# All additive — no existing factory or tag is renumbered. The wider per-DType
# set (GtI32, LtI32, EqF64, NeF64, etc.) is served by the ExpressionExecutor;
# these factories cover the Q6-shape minimum.

def make_lit_f64(v: Float64) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LIT_F64, 0, v, False, 0, 0, 0)


def make_col(idx: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_COL, 0, 0.0, False, idx, 0, 0)


def make_lt_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LT_I64, 0, 0.0, False, 0, left, right)


def make_ge_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_GE_I64, 0, 0.0, False, 0, left, right)


def make_lt_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LT_F64, 0, 0.0, False, 0, left, right)


def make_ge_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_GE_F64, 0, 0.0, False, 0, left, right)


def make_le_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LE_F64, 0, 0.0, False, 0, left, right)


# Int64 LE
# factory, mirror of `make_lt_i64` / `make_le_f64`. Closes the asymmetric gap
# where BIN_LE was supported on F64/Decimal128/String but RAISED for Int64.
def make_le_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_LE_I64, 0, 0.0, False, 0, left, right)


# Float64 EQ
# factory, mirror of `make_le_f64` / `_make_eq_i64_node`. Closes the
# asymmetric gap where BIN_EQ was supported on I64/String/Decimal128 but
# RAISED for Float64. Unblocks TPC-H Q15 `WHERE total_revenue = max_revenue`.
def make_eq_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_EQ_F64, 0, 0.0, False, 0, left, right)


# -----------------------------------------------------------------------------
# arithmetic + I32 lit.
# -----------------------------------------------------------------------------
# Mirror of the existing factory shape: binary arithmetic nodes carry only
# left/right pool slot indices (operand payloads live in those slots); the
# I32 literal carries its value in the i64 field (walker casts at append).

def make_add_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_ADD_I64, 0, 0.0, False, 0, left, right)


def make_sub_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_SUB_I64, 0, 0.0, False, 0, left, right)


def make_mul_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_MUL_I64, 0, 0.0, False, 0, left, right)


def make_div_i64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_DIV_I64, 0, 0.0, False, 0, left, right)


def make_add_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_ADD_F64, 0, 0.0, False, 0, left, right)


def make_sub_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_SUB_F64, 0, 0.0, False, 0, left, right)


def make_mul_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_MUL_F64, 0, 0.0, False, 0, left, right)


def make_div_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_DIV_F64, 0, 0.0, False, 0, left, right)


def make_lit_i32(v: Int32) -> RuntimeExpr:
    # The Int32 value is carried in the i64 field (truncated cast at the
    # walker's append point). RuntimeExpr layout unchanged — avoids stale-slab /
    # POD-widening cost from adding a new i32 field.
    return RuntimeExpr(EXPR_LIT_I32, Int64(v), 0.0, False, 0, 0, 0)


# -----------------------------------------------------------------------------
# Int32 arithmetic
# factories. Mirror of EXPR_{ADD,SUB,MUL,DIV}_I64 factories; operands live
# in pool slots (`left` / `right`), value-less node payload.
# -----------------------------------------------------------------------------

def make_add_i32(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_ADD_I32, 0, 0.0, False, 0, left, right)


def make_sub_i32(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_SUB_I32, 0, 0.0, False, 0, left, right)


def make_mul_i32(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_MUL_I32, 0, 0.0, False, 0, left, right)


def make_div_i32(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_DIV_I32, 0, 0.0, False, 0, left, right)


# -----------------------------------------------------------------------------
# Unary
# Float64 sqrt factory. Mirror of the binary F64 factories above, but
# uses ONLY `left` to carry the single child pool index (RuntimeExpr
# `right` field is zero / unused for arity-1 nodes). Parameter named
# `child` (not `left`) so call sites surface the unary intent.
#
# Required precursor for AGG_CORR Option A — Pearson's
# `r = num / sqrt(denom_x * denom_y)` cannot be expressed in the
# pre-existing expr substrate (no transcendental / unary-numeric
# arms). Future arity-1 ops (NOT, IS_NULL, NEG, ABS, CAST) follow
# the same single-`left`-slot convention.
# -----------------------------------------------------------------------------

def make_sqrt_f64(child: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_SQRT_F64, 0, 0.0, False, 0, child, 0)


# -----------------------------------------------------------------------------
# Float64 scalar math factories.
# Unary ops mirror `make_sqrt_f64` (single `left`-slot child, `right`=0);
# `make_atan2_f64` is binary (mirrors `make_add_f64`).
# -----------------------------------------------------------------------------

def make_sin_f64(child: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_SIN_F64, 0, 0.0, False, 0, child, 0)


def make_cos_f64(child: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_COS_F64, 0, 0.0, False, 0, child, 0)


def make_asin_f64(child: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_ASIN_F64, 0, 0.0, False, 0, child, 0)


def make_radians_f64(child: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_RADIANS_F64, 0, 0.0, False, 0, child, 0)


def make_atan2_f64(left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_ATAN2_F64, 0, 0.0, False, 0, left, right)


def make_pow_f64(left: Int, right: Int) -> RuntimeExpr:
    """`pow(base, exponent)`. `left`=base,
    `right`=exponent; binary, mirrors `make_atan2_f64`."""
    return RuntimeExpr(EXPR_POW_F64, 0, 0.0, False, 0, left, right)


def make_math_unary_f64(op: Int, child: Int) -> RuntimeExpr:
    """The GENERIC unary-math node.

    `op` is a `KMATH_*` code (numerically identical to the `MATH_*` code on the
    IR side; the two spaces must stay
    equal). It rides in `col_idx`; `child` is the single operand's pool slot.

    ⛔ The walker arms for this tag dispatch through
    `scalar_math._apply_unary`, whose `else` branch is `KMATH_RADIANS` and NOT
    a default — so an op code outside the pinned space would be silently
    computed as `x * pi/180`. `lower_untyped_expr` range-checks the code before
    it can reach here.
    """
    return RuntimeExpr(EXPR_MATH_UNARY_F64, 0, 0.0, False, op, child, 0)


# -----------------------------------------------------------------------------
# Unary
# Float64 -> Int64 narrowing cast factory. Mirror of `make_sqrt_f64` (single
# `left`-slot child; `right` unused). Evaluated only by the Int64 project
# walker (`eval_to_list_i64_from_view`), which recurses on the child through
# the Float64 walker then truncates toward zero. Used by the agg post-stage
# Project to narrow an F64-channel integer-result agg column back to INT64.
# -----------------------------------------------------------------------------

def make_f64_to_i64(child: Int) -> RuntimeExpr:
    return RuntimeExpr(EXPR_F64_TO_I64, 0, 0.0, False, 0, child, 0)


# -----------------------------------------------------------------------------
# EXPR_IN_LIST factory. Arity-1: child operand lives in `left`, IN-list
# side-pool index in `col_idx`. The side pool is
# `ExpressionExecutor.in_list_pool: List[List[ScalarValue]]` (parallel
# to string_pool / decimal_pool). Per-DType dispatch in the walker arm
# is on the runtime column's ArrowType.
# -----------------------------------------------------------------------------

def make_in_list(child: Int, in_list_pool_idx: Int) -> RuntimeExpr:
    """EXPR_IN_LIST node. `child` is the pool slot of the child column
    operand (typically an EXPR_COL / EXPR_COL_STRING / EXPR_COL_BOOL).
    `in_list_pool_idx` indexes into the executor's `in_list_pool` side
    table holding the variable-sized List[ScalarValue] value tables.
    """
    return RuntimeExpr(EXPR_IN_LIST, 0, 0.0, False, in_list_pool_idx, child, 0)


# -----------------------------------------------------------------------------
# Bool
# column primitive factories. EXPR_COL_BOOL carries the Bool column's
# frame-local index in `col_idx` (mirrors EXPR_COL for I64/F64 cols).
# EXPR_NOT_BOOL carries the child pool index in `left` (arity-1
# convention, same as EXPR_SQRT_F64).
# -----------------------------------------------------------------------------

def make_col_bool(idx: Int) -> RuntimeExpr:
    """Bool column reference. `idx` is the frame-local column index
    (resolved at walker time via `batch.column_by_name(col_names[idx])`).
    """
    return RuntimeExpr(EXPR_COL_BOOL, 0, 0.0, False, idx, 0, 0)


def make_not_bool(child: Int) -> RuntimeExpr:
    """Logical NOT over a Bool sub-expression. `child` is the child
    pool index; the walker recurses on `node.left` and computes the
    set-complement within `input_sel`.
    """
    return RuntimeExpr(EXPR_NOT_BOOL, 0, 0.0, False, 0, child, 0)


# -----------------------------------------------------------------------------
# String
# column primitive factories. The translator interns String literals
# into a side-table (`ExpressionExecutor.string_pool: List[String]`) and
# emits `make_lit_string(pool_idx)` carrying the ALREADY-INTERNED index
# in the `col_idx` field. This keeps `runtime_expr.mojo` pure POD + factory
# (no String storage in the RuntimeExpr POD; no stale-slab hazard).
# -----------------------------------------------------------------------------

def make_lit_string(string_pool_idx: Int) -> RuntimeExpr:
    """String literal. `string_pool_idx` is the index into
    ExpressionExecutor.string_pool (caller-side interned). The walker
    resolves the literal at evaluation time via
    `self.string_pool[node.col_idx]`. col_idx is REPURPOSED here as
    the string-pool index (tag-disambiguated — different `kind` value
    from EXPR_COL which uses col_idx as column index).
    """
    return RuntimeExpr(EXPR_LIT_STRING, 0, 0.0, False, string_pool_idx, 0, 0)


def make_col_string(idx: Int) -> RuntimeExpr:
    """String column reference. `idx` is the frame-local column index
    (resolved at walker time via `batch.column_by_name(col_names[idx])`,
    then `batch.column_as_string(runtime_idx)`).
    """
    return RuntimeExpr(EXPR_COL_STRING, 0, 0.0, False, idx, 0, 0)


def make_col_binary(idx: Int) -> RuntimeExpr:
    """BINARY column reference.
    `idx` is the frame-local column index (resolved at
    walker time via `batch.column_by_name(col_names[idx])`, then
    `batch.column_as_binary(runtime_idx)`). Mirrors `make_col_string`:
    BINARY is STRING without UTF-8 validation, so the extraction leaf is
    identical except the walker emits `List[List[UInt8]]` (byte-exact).
    """
    return RuntimeExpr(EXPR_COL_BINARY, 0, 0.0, False, idx, 0, 0)


def make_col_dictionary(idx: Int) -> RuntimeExpr:
    """DICTIONARY column reference.
    `idx` is the frame-local column index (resolved at
    walker time via `batch.column_by_name(col_names[idx])`, then
    `batch.column_as_dictionary(runtime_idx)`). The walker PRESERVES the
    dictionary encoding (int32 indices + shared dict buffer + dict_size)
    rather than decoding to flat strings.
    """
    return RuntimeExpr(EXPR_COL_DICTIONARY, 0, 0.0, False, idx, 0, 0)


def make_eq_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise String equality. Children at `left`/`right` pool
    indices should resolve to EXPR_COL_STRING or EXPR_LIT_STRING. The
    filter walker calls `StringArray.get(row)` (or pool lookup for
    literals) on both sides and compares via `String.__eq__`.
    """
    return RuntimeExpr(EXPR_EQ_STRING, 0, 0.0, False, 0, left, right)


def make_neq_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise String inequality. Mirror of make_eq_string with
    `String.__ne__`.
    """
    return RuntimeExpr(EXPR_NEQ_STRING, 0, 0.0, False, 0, left, right)


def make_is_null_string(child_pool_idx: Int) -> RuntimeExpr:
    """Per-row
    IS NULL test on a String column. `child_pool_idx` must resolve to a
    EXPR_COL_STRING (literal IS_NULL is degenerate; constant-folded at
    lower-time). Stored in the `col_idx` field for the leaf-pattern
    walker shape (walker reads `string_pool[node.col_idx]` to get the
    child slot, then resolves the child's col-name through
    `column_names`).
    """
    return RuntimeExpr(EXPR_IS_NULL_STRING, 0, 0.0, False, child_pool_idx, 0, 0)


def make_is_not_null_string(child_pool_idx: Int) -> RuntimeExpr:
    """Mirror
    of make_is_null_string but emits True on non-null rows.
    """
    return RuntimeExpr(EXPR_IS_NOT_NULL_STRING, 0, 0.0, False, child_pool_idx, 0, 0)


def make_gt_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise lexicographic `left > right` over String
    operands. Children at `left`/`right` pool indices should resolve to
    EXPR_COL_STRING or EXPR_LIT_STRING. The filter walker calls
    `StringArray.get(row)` (or pool lookup for literals) on both sides
    and compares via the byte-wise `_str_compare` helper. SQL 3VL: any
    row with a NULL operand is excluded from output_sel.
    """
    return RuntimeExpr(EXPR_GT_STRING, 0, 0.0, False, 0, left, right)


def make_lt_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise lexicographic `left < right` over String operands.
    Mirror of make_gt_string.
    """
    return RuntimeExpr(EXPR_LT_STRING, 0, 0.0, False, 0, left, right)


def make_ge_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise lexicographic `left >= right` over String operands.
    Mirror of make_gt_string.
    """
    return RuntimeExpr(EXPR_GE_STRING, 0, 0.0, False, 0, left, right)


def make_le_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise lexicographic `left <= right` over String operands.
    Mirror of make_gt_string.
    """
    return RuntimeExpr(EXPR_LE_STRING, 0, 0.0, False, 0, left, right)


def make_like_string(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise
    SQL LIKE pattern match. `left` is the pool slot of an EXPR_COL_STRING
    (the value column); `right` is the pool slot of an EXPR_LIT_STRING
    (the pattern literal, with the pool index carried in its col_idx).
    The filter walker validates both operand shapes (raises on col-vs-col
    or lit-vs-col); calls `StringArray.get(row)` per row and
    `_string_like_match(text, pattern)` for the per-row Bool. SQL WHERE
    3VL: NULL value rows are excluded from output_sel.
    """
    return RuntimeExpr(EXPR_LIKE_STRING, 0, 0.0, False, 0, left, right)


def make_regexp(value_child: Int, regex_pool_idx: Int) -> RuntimeExpr:
    """Regex predicate node.
    `regexp_like(col, 'pat')` per-cell predicate. `value_child` is the pool slot
    of an EXPR_COL_STRING (the value column read via CS.read_string per row);
    `regex_pool_idx` is the index into `ExpressionExecutor.regex_pool:
    List[RegexProgram]` (caller-side compiled ONCE at segment setup — the
    RegexProgram is the same Thompson-NFA/Pike-VM leaf the column oracle uses).
    `col_idx` is REPURPOSED here as the regex-pool index (tag-disambiguated by the
    EXPR_REGEXP `kind` from EXPR_COL which uses col_idx as a column index). The
    walker reads the value cell, then runs the compiled NFA's per-string
    `is_match` (unanchored — DuckDB `regexp_like` / `~` semantics).
    """
    return RuntimeExpr(EXPR_REGEXP, 0, 0.0, False, regex_pool_idx, value_child, 0)


# -----------------------------------------------------------------------------
# Decimal128
# column primitive factories. The translator interns Decimal literals
# into a side-table (`ExpressionExecutor.decimal_pool: List[DecimalSpec]`)
# and emits `make_lit_decimal128(pool_idx)` carrying the ALREADY-INTERNED
# index in the `col_idx` field. Keeps `runtime_expr.mojo` pure POD + factory
# (no i128/precision/scale storage in the RuntimeExpr POD).
# -----------------------------------------------------------------------------

def make_lit_decimal128(decimal_pool_idx: Int) -> RuntimeExpr:
    """Decimal128 literal. `decimal_pool_idx` is the index into
    ExpressionExecutor.decimal_pool: List[DecimalSpec] (caller-side
    interned). The walker resolves the literal at evaluation time via
    `self.decimal_pool[node.col_idx]`. col_idx is REPURPOSED here as
    the decimal-pool index (tag-disambiguated — different `kind` value
    from EXPR_COL which uses col_idx as column index).
    """
    return RuntimeExpr(EXPR_LIT_DECIMAL128, 0, 0.0, False, decimal_pool_idx, 0, 0)


def make_col_decimal128(idx: Int) -> RuntimeExpr:
    """Decimal128 column reference. `idx` is the frame-local column
    index (resolved at walker time via
    `batch.column_by_name(col_names[idx])`, then
    `batch.column_as_decimal128(runtime_idx)`). The walker reads
    (precision, scale) directly from the Decimal128Array fields.
    """
    return RuntimeExpr(EXPR_COL_DECIMAL128, 0, 0.0, False, idx, 0, 0)


def make_add_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 add. Children at `left`/`right` pool
    indices. Walker calls `decimal_add_i128(a, s1, b, s2, out_scale)`
    per row from `komira_scalar_arithmetic.decimal_arith`. Result
    (precision, scale) via `decimal_add_result_ps(p1, s1, p2, s2)`.
    """
    return RuntimeExpr(EXPR_ADD_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_sub_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 subtract. Mirror of make_add_decimal128
    with `decimal_sub_i128`. Result (p, s) shares `decimal_add_result_ps`
    rule (add/sub have identical p,s rules)."""
    return RuntimeExpr(EXPR_SUB_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_mul_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 multiply. Walker calls
    `decimal_mul_i128(a, b)` per row + rescales result to
    `decimal_mul_result_ps(p1, s1, p2, s2)` output scale.
    """
    return RuntimeExpr(EXPR_MUL_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_div_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 divide. Walker calls
    `decimal_div_i128(a, s1, b, s2, out_scale)` per row. Result (p, s)
    via `decimal_div_result_ps`. Hive-convention scale rule
    `min(s1 + 4, 38)`; result rounded HALF_UP per
    DuckDB/PostgreSQL semantics (deliberate divergence from
    arrow-rs TRUNCATE).
    """
    return RuntimeExpr(EXPR_DIV_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_eq_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 equality. Same-scale fast-path
    (direct i128 == compare); cross-scale rescales smaller-scale
    operand UP to match (lossless), then compares.
    """
    return RuntimeExpr(EXPR_EQ_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_neq_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 inequality. Mirror of make_eq_decimal128
    with `!=`.
    """
    return RuntimeExpr(EXPR_NEQ_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_gt_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 greater-than. Same-scale fast-path;
    cross-scale rescales smaller-scale operand UP."""
    return RuntimeExpr(EXPR_GT_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_lt_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 less-than. Mirror of make_gt_decimal128."""
    return RuntimeExpr(EXPR_LT_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_ge_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 greater-or-equal."""
    return RuntimeExpr(EXPR_GE_DECIMAL128, 0, 0.0, False, 0, left, right)


def make_le_decimal128(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Decimal128 less-or-equal."""
    return RuntimeExpr(EXPR_LE_DECIMAL128, 0, 0.0, False, 0, left, right)


# UNSIGNED INT64 comparison
# factories. Both `left` / `right` are pool-slot indices; each side resolves to
# an EXPR_COL (read via the per-cell walker's `read_u64`) or EXPR_LIT_I64 (the
# i64 carrier reinterpreted as the unsigned literal). The walker compares as
# native UInt64 so a U64 value above Int64.MAX orders correctly (a signed
# compare would mis-order it). Only U64 needs these; narrow
# unsigned (U8/U16/U32) ride the EXPR_*_I64 arm (their max fits in Int64).
def make_gt_u64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise UInt64 greater-than (unsigned ordering)."""
    return RuntimeExpr(EXPR_GT_U64, 0, 0.0, False, 0, left, right)


def make_ge_u64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise UInt64 greater-or-equal (unsigned ordering)."""
    return RuntimeExpr(EXPR_GE_U64, 0, 0.0, False, 0, left, right)


def make_lt_u64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise UInt64 less-than (unsigned ordering)."""
    return RuntimeExpr(EXPR_LT_U64, 0, 0.0, False, 0, left, right)


def make_le_u64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise UInt64 less-or-equal (unsigned ordering)."""
    return RuntimeExpr(EXPR_LE_U64, 0, 0.0, False, 0, left, right)


def make_eq_u64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise UInt64 equality (bit-equality; sign-agnostic)."""
    return RuntimeExpr(EXPR_EQ_U64, 0, 0.0, False, 0, left, right)


# F2 NUMERIC-NE — numeric `!=` factories. Children at
# `left`/`right` resolve to the same numeric leaves the EQ arms consume
# (EXPR_COL + EXPR_LIT_I64/F64). The walker arm returns the negation of the
# EQ comparison on the per-cell-read values.
def make_ne_i64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Int64 inequality (negation of EXPR_EQ_I64)."""
    return RuntimeExpr(EXPR_NE_I64, 0, 0.0, False, 0, left, right)


def make_ne_f64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise Float64 inequality (negation of EXPR_EQ_F64)."""
    return RuntimeExpr(EXPR_NE_F64, 0, 0.0, False, 0, left, right)


def make_ne_u64(left: Int, right: Int) -> RuntimeExpr:
    """Element-wise UInt64 inequality (negation of EXPR_EQ_U64)."""
    return RuntimeExpr(EXPR_NE_U64, 0, 0.0, False, 0, left, right)


# F10 IS NULL / IS NOT NULL — GENERIC per-cell validity-test
# factories. Arity-1 leaf-pattern: `col_idx` carries the LOGICAL column index
# of the operand (mirrors make_col), resolved by the walker against the
# source's validity bitmap via `CellSource.is_null`. No string-pool / value-
# pool side table is needed (unlike EXPR_IS_NULL_STRING).
def make_is_null_cell(col_idx: Int) -> RuntimeExpr:
    """Per-row IS NULL test on the column at logical index `col_idx`. Emits
    True when the cell is NULL (validity bit set)."""
    return RuntimeExpr(EXPR_IS_NULL_CELL, 0, 0.0, False, col_idx, 0, 0)


def make_is_not_null_cell(col_idx: Int) -> RuntimeExpr:
    """Per-row IS NOT NULL test on the column at logical index `col_idx`.
    Emits True when the cell is present (validity bit clear)."""
    return RuntimeExpr(EXPR_IS_NOT_NULL_CELL, 0, 0.0, False, col_idx, 0, 0)


# CASE/WHEN + CAST — projection-expression node factories.
def make_case_i64(when_pool_idx: Int) -> RuntimeExpr:
    """Int64 CASE node. `when_pool_idx` indexes into the executor's `when_pool`
    side table; the entry is the flattened slot list
    `[cond0, then0, ..., condK-1, thenK-1, elseSlot]`. The THEN/ELSE branches
    are Int64 value sub-trees; the conditions are Bool sub-trees."""
    return RuntimeExpr(EXPR_CASE_I64, 0, 0.0, False, when_pool_idx, 0, 0)


def make_case_f64(when_pool_idx: Int) -> RuntimeExpr:
    """Float64 CASE node (mirror of make_case_i64; THEN/ELSE branches are
    Float64 value sub-trees)."""
    return RuntimeExpr(EXPR_CASE_F64, 0, 0.0, False, when_pool_idx, 0, 0)


def make_null() -> RuntimeExpr:
    """NULL-marker value leaf. As a VALUE it evaluates to 0; its nullity is
    queried by the project walker's `_cell_is_null_from_source` driver (used as a
    CASE THEN/ELSE branch corresponding to a SQL NULL literal)."""
    return RuntimeExpr(EXPR_NULL, 0, 0.0, False, 0, 0, 0)


def make_i64_to_f64(child: Int) -> RuntimeExpr:
    """Int64 -> Float64 widening cast. `child` is the pool slot of the Int64
    value sub-tree; the walker's f64 arm widens its result to Float64."""
    return RuntimeExpr(EXPR_I64_TO_F64, 0, 0.0, False, 0, child, 0)


def make_extract_i64(child: Int, unit: Int, ticks_per_day: Int64) -> RuntimeExpr:
    """EXTRACT — temporal field extraction. `child` is the pool slot of the
    temporal column (read as Int64 epoch); `unit` is an RT_EXTRACT_* field
    selector; `ticks_per_day` is the temporal unit's per-day tick count (1 for
    Date32-days, 86_400_000 for Date64-ms, etc.). The walker's i64 arm recovers
    the civil date from the epoch and emits the requested field as Int64."""
    return RuntimeExpr(EXPR_EXTRACT_I64, ticks_per_day, 0.0, False, unit, child, 0)


def make_date_trunc_i64(child: Int, unit: Int, ticks_per_day: Int64) -> RuntimeExpr:
    """`date_trunc` — temporal-OUTPUT value node. `child` is the pool slot of the
    temporal column (read as Int64 epoch); `unit` is an RT_TRUNC_* selector;
    `ticks_per_day` is the temporal unit's per-day tick count. The walker's i64
    arm rounds the epoch DOWN to the period start and returns the truncated
    epoch as Int64 (the project walker writes it at the input temporal width)."""
    return RuntimeExpr(EXPR_DATE_TRUNC_I64, ticks_per_day, 0.0, False, unit, child, 0)
