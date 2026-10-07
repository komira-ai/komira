# Query semantics: what a plan's result must be

Status: **draft for ruling.** Items marked UNDECIDED or DEPARTS take effect only once they are ruled on; the list is in "Rulings needed" below.

## What is it for, and what is out of scope?

This document states what a komira logical plan must return: how NULLs flow through logic, aggregates, joins and sorts; what arithmetic does at its edges; what casts and string functions mean; and the type of every result. It is the authority a hand-written test expectation cites. A conformance case whose expected value is derived by hand names the item it relies on (for example "§5.3"), never engine code: an expectation read off the code that produces the answer would let the engine grade itself.

The reference engine is DuckDB, run with its default settings (`ieee_floating_point_ops = true`, `integer_division = false`, `default_null_order = NULLS_LAST`) and with `TimeZone` set to `UTC`. pyarrow's compute functions are a second oracle for single-kernel cases; where pyarrow disagrees with DuckDB this document says which one the plan follows. Statements about DuckDB cite its documentation. Where the documentation is silent, the statement quotes a measurement recorded in komira's source (taken on DuckDB 1.5.3) and says so; the conformance oracle re-measures every such statement, and a disagreement is a defect in this document.

Each item has four parts:

- **Rule**: what a plan must return.
- **DuckDB** (and **pyarrow** where relevant): what the reference does.
- **Current behaviour**: what komira's code does today, cited as `file:line`. It is evidence, not authority: where it differs from the rule, the code is wrong or the rule is still open.
- **Mark**: one of
  - **MATCHES**: the rule is DuckDB's;
  - **DEPARTS**: the rule differs from DuckDB, for the reason given;
  - **UNDECIDED**: the options and a recommendation.

Scope is the plan: the logical-plan IR (`src/komira_plan_ir`, `src/komira_plan_expr`) and its wire form (`src/komira_plan_wire`). A frontend (SQL, a dataframe API, a spreadsheet) maps its own surface onto these rules; where a frontend's spelling differs from the plan operator of the same name (SQL `/` against the plan's `BIN_DIV`), the item says so. Out of scope: collations other than binary, intervals, nested types (struct, list, map), JSON functions, the temporal field extracts beyond time zones, and UDF null modes. Each of those needs its own section before a hand expectation may depend on it.

Many operators named here have no executor in this repository yet (the engine operators arrive separately). Where that is so, "current behaviour" cites the IR, the wire admission or a kernel, and says that nothing executes the operator end to end.

## Rulings needed

Every DEPARTS and UNDECIDED item, with the recommendation. A ruling either accepts the recommendation or names another option; the item's mark then changes to MATCHES or DEPARTS and the ruling is recorded beside it.

| Item | Topic | Mark | Recommendation |
|---|---|---|---|
| §1.6 | `IS [NOT] DISTINCT FROM` | UNDECIDED | Frontends desugar it to `IS NULL` / `=` combinations now; add plan operators only when a null-safe join key needs one. |
| §2.8 | MEDIAN and quantiles over NaN | UNDECIDED | Match DuckDB: NaN is a value and takes part (it sorts above +inf); an all-NaN group answers NaN, not NULL. |
| §3.7 | ASOF `NEAREST`, ties to the earlier row | DEPARTS | Accept: DuckDB has no NEAREST; keep it as a komira extension with hand-derived expectations citing this item. |
| §4.5 | NaN in comparison predicates | UNDECIDED | Match DuckDB: `NaN = NaN` is TRUE, `NaN > x` is TRUE for every non-NaN `x`; one float model for comparisons, sorting and grouping. |
| §5.1 | `BIN_DIV` on two integers truncates and keeps the integer type | DEPARTS | Accept: the plan has one division operator, and it is DuckDB's `//`; a frontend's true division (`/`) casts an operand to DOUBLE first. |
| §6.6 | String-to-integer parse grammar edge cases | UNDECIDED | Match DuckDB on each edge case, measured by the oracle and listed in this item. |
| §6.7 | String-to-double out of range | UNDECIDED | Match DuckDB (expected: an error); the code saturates to ±inf today. |
| §6.8 | Casts between timestamp units | UNDECIDED | Match DuckDB: widening is exact, narrowing follows DuckDB's measured rounding, out of range is an error. |
| §6.9 | Time zones and the session zone | UNDECIDED | Fix the session time zone to UTC; field extraction over a zoned timestamp happens in UTC until a session-zone setting exists. |
| §6.10 | CAST_TO_VARCHAR rendering | UNDECIDED | Match DuckDB's `CAST(x AS VARCHAR)` per type, written out as a table in this item; pyarrow's float rendering (`1` for 1.0) is not followed. |
| §7.5 | CONCAT takes only string arguments | DEPARTS | Accept: a non-string argument is refused by name; never a different value. |
| §7.7 | No LIKE `ESCAPE`, no ILIKE in the plan | DEPARTS | Accept for now: both are refused by name; add when a frontend needs them. |
| §8.1 | SUM of a signed integer is INT64 and refuses overflow | DEPARTS | Accept: Arrow has no 128-bit integer; a total outside INT64 is an error naming the column, never a wrapped value. |
| §8.2 | SUM of an unsigned integer is UINT64 | DEPARTS | Accept, with the same overflow error as §8.1. |
| §8.9 | Result type of integer and mixed arithmetic | UNDECIDED | Match DuckDB: the result is the wider operand type (and FLOAT/DOUBLE wins over any integer); the plan's "left operand wins" rule is retired. |
| §8.12 | Decimal multiplication precision | UNDECIDED | Match DuckDB: precision `p1 + p2` (capped at 38), scale `s1 + s2`; the plan says `p1 + p2 + 1` today. |
| §8.14 | Result type of CASE and COALESCE over mixed types | UNDECIDED | Match DuckDB: the branches combine to their common supertype; until a frontend inserts the casts, the plan refuses mixed branch types by name. |
| §9.5 | No `IGNORE NULLS` for LAG/LEAD | DEPARTS | Accept for now: refused by name. |
| §9.6 | Window ORDER BY cannot state its NULL placement | DEPARTS | Accept for now: the window key uses §4.1's default; a frontend refuses an explicit `NULLS FIRST` inside `OVER`. |
| §10.1 | Excel error-code space | DEPARTS | Ratify: Microsoft's list without a circular-reference code (DuckDB has no error values). |
| §10.2 | Error propagation through scalar expressions | UNDECIDED | An error dominates NULL; the leftmost error operand wins; AND/OR do not short-circuit past an error. |
| §10.3 | Errors in aggregates and sorts | UNDECIDED | SUM/AVERAGE/MIN/MAX answer the first error in input order; COUNT skips errors; sort places errors after logical values and before blanks, all errors equal. |

## Code that does not follow a MATCHES rule today

These are places where the rule is settled (it matches DuckDB) and some code path answers differently. A conformance case that reaches one of them is expected to fail until the code is fixed; the case still cites the rule, not the code.

1. **Integer division has three implementations with three behaviours (§5.1, §5.3).**
   - `src/komira_column_kernels/arithmetic.mojo:40-98` and `:572-580` follow the rules: truncating division, NULL for a zero divisor, an error for MIN / -1.
   - `src/komira_eval/expression_executor.mojo:2749-2759`, `:3349-3360` and `:5365-5372` raise on a zero divisor and divide with Mojo's `//`. Mojo's `//` on integers rounds toward negative infinity, so `-7 // 2` is -4 where the rule says -3. The comment at `:2756-2757` says the division truncates; it does not.
   - `src/komira_kernels/expr_kernel_templates.mojo:390-411` (template 8) also uses `//`, and does not guard a zero divisor (its docstring says so).
2. **SUM cells in `komira_agg` (§2.2, §8.1).** `src/komira_agg/builtin_agg_fns_sum.mojo:63-76` starts each group at 0 with no record of having seen a value, so a group with no non-NULL input finalizes to 0 rather than NULL, and `+=` wraps on overflow. The grouped and scalar folds that refuse overflow (`src/komira_op_agg_state/int_sum_overflow.mojo:31-41`) and that answer NULL for an empty group (`src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:95-99`) follow the rules.
3. **A truncating float-to-integer cast (§6.3).** `src/komira_kernels/runtime_expr.mojo:226-229` says `EXPR_F64_TO_I64` truncates toward zero and is wired to `CAST(f AS bigint)` in the per-cell walker; the rule is half to even with a range check (`src/komira_column_kernels/cast_null.mojo:134-160` implements it). The same node carries integer aggregates through a Float64 channel (`:592-600`), which is exact only below 2^53.
4. **Integer narrowing casts that wrap (§6.2).** `src/komira_column_kernels/cast_null.mojo:22-58` (`eval_cast`) and template 39 in `src/komira_kernels/expr_kernel_templates.mojo:1050-1060` convert with a bare machine cast, which keeps the low bits of an out-of-range value. Any CAST that reaches them with an out-of-range value answers a wrong number instead of an error.
5. **Regular expressions match bytes, not characters (§7.8).** The matcher's `.` is "any byte" (`src/komira_column_kernels/regexp_nfa.mojo:243`) and a character class is a set of byte values (`:59-60`), so `.` consumes one byte of a multi-byte character and `[é]` is a class of two bytes. RE2, which DuckDB uses, matches UTF-8 characters.
6. **The `running_*` window builders use a ROWS frame (§9.1).** `src/komira_plan_expr/partition_expr.mojo:257-283` builds `running_sum`, `running_count`, `running_avg`, `running_min` and `running_max` with `PartitionFrame.default_ordered()`, which is `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (`src/komira_plan_expr/partition_frame.mojo:89-110`). That is correct for an explicit ROWS frame and wrong as the default of an ordered window, which is RANGE.

## 1. Three-valued logic

### 1.1 AND, OR, NOT

**Rule.** Kleene logic over {TRUE, FALSE, NULL}:

| a | b | a AND b | a OR b |
|---|---|---|---|
| TRUE | TRUE | TRUE | TRUE |
| TRUE | FALSE | FALSE | TRUE |
| TRUE | NULL | NULL | TRUE |
| FALSE | FALSE | FALSE | FALSE |
| FALSE | NULL | FALSE | NULL |
| NULL | NULL | NULL | NULL |

`NOT NULL` is NULL. AND and OR are commutative; the result does not depend on evaluation order.

**DuckDB.** The same table ([logical operators](https://duckdb.org/docs/current/sql/expressions/logical_operators.html)). **pyarrow.** `and_kleene` / `or_kleene` follow this table; `and_` / `or_` propagate NULL instead and are not the oracle for this item ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).

**Current behaviour.** `src/komira_kernels/kleene.mojo:15-22` states the table, and `:131-176` implements it on bitmap bytes.

**Mark.** MATCHES.

### 1.2 Comparisons with NULL, and filters

**Rule.** `=`, `<>`, `<`, `<=`, `>`, `>=` answer NULL when either operand is NULL, including `NULL = NULL`. A FILTER keeps a row only when its predicate is TRUE; FALSE and NULL both drop it.

**DuckDB.** "Whenever either of the input arguments is NULL, the output of the comparison is NULL" ([comparison operators](https://duckdb.org/docs/current/sql/expressions/comparison_operators.html), [NULL values](https://duckdb.org/docs/current/sql/data_types/nulls.html)).

**Current behaviour.** A comparison result is valid only where both operands are valid (`src/komira_kernels/kleene.mojo:192-203`).

**Mark.** MATCHES.

### 1.3 IS NULL, IS NOT NULL

**Rule.** Both are total: never NULL. `x IS NULL` is TRUE exactly when `x` is NULL. A NaN is not NULL (§4.3).

**DuckDB.** As stated ([NULL values](https://duckdb.org/docs/current/sql/data_types/nulls.html)).

**Current behaviour.** `src/komira_expr/runtime_expr_bool.mojo:766-800` returns an always-valid result from the validity bit.

**Mark.** MATCHES.

### 1.4 IN with a NULL in the list, or a NULL on the left

**Rule.** `x IN (v1, ..., vn)` is `x = v1 OR ... OR x = vn` under §1.1 and §1.2:

- TRUE if some non-NULL `vi` equals `x`;
- otherwise NULL if `x` is NULL or some `vi` is NULL;
- otherwise FALSE.

So `2 IN (1, NULL)` is NULL, `1 IN (1, NULL)` is TRUE, and `NULL IN (1, 2)` is NULL. The plan's IN_LIST is this tuple form.

**DuckDB.** The same for a parenthesized list; DuckDB's *list* form `x IN [..]` ignores NULL members and is not what IN_LIST means ([IN operator](https://duckdb.org/docs/current/sql/expressions/in.html)). **pyarrow.** `is_in` with the default `skip_nulls=False` matches a NULL input to a NULL in the value set and never answers NULL, so it is not an oracle for this item ([SetLookupOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.SetLookupOptions.html)).

**Current behaviour.** No IN_LIST evaluator is in this repository. The wire admits NULL members (`src/komira_plan_wire/plan_wire_values.mojo:1899-1906`), and its docstring describes the rule above for the engine's evaluator.

**Mark.** MATCHES.

### 1.5 NOT IN

**Rule.** `x NOT IN (...)` is `NOT (x IN (...))`. So a list containing NULL makes every non-matching row NULL, and a filter on it returns no such row.

**DuckDB.** "`x NOT IN y` is equivalent to `NOT (x IN y)`" ([IN operator](https://duckdb.org/docs/current/sql/expressions/in.html)).

**Current behaviour.** As §1.4: no evaluator here. The subquery form is §3.3.

**Mark.** MATCHES.

### 1.6 IS [NOT] DISTINCT FROM

**Rule (proposed).** `a IS DISTINCT FROM b` is FALSE when both are NULL, TRUE when exactly one is NULL, and `a <> b` otherwise; it is never NULL. `IS NOT DISTINCT FROM` is its negation.

**DuckDB.** As stated ([comparison operators](https://duckdb.org/docs/current/sql/expressions/comparison_operators.html)).

**Current behaviour.** The plan has no operator for it: the binary operators are ADD SUB MUL DIV MOD, EQ NE LT LE GT GE, AND OR (`src/komira_plan_expr/expr.mojo:665-686`). The SQL parser refuses the spelling by name (`src/komira_sql/sql_parser.mojo:1863-1868`).

**Options.**
- (a) Frontends desugar: `a IS NOT DISTINCT FROM b` becomes `(a IS NULL AND b IS NULL) OR (a IS NOT NULL AND b IS NOT NULL AND a = b)`. No wire change. It evaluates each operand more than once.
- (b) Add two binary operators to the IR and the wire. One node, one evaluation; a wire-vocabulary change with its goldens.

**Recommendation.** (a) now; (b) when a null-safe equi-join key needs it, since a join cannot use the desugared form as a hash key.

**Mark.** UNDECIDED.

### 1.7 CASE with a NULL condition

**Rule.** A `WHEN` whose condition is NULL is not taken; evaluation moves to the next `WHEN`, then to `ELSE`, and a missing `ELSE` answers NULL.

**DuckDB.** Standard SQL `CASE`; the oracle confirms.

**Current behaviour.** No CASE evaluator here. COALESCE is built as a CASE over `IS NOT NULL` conditions (`src/komira_plan_expr/scalar_desugar.mojo:84-111`).

**Mark.** MATCHES.

## 2. NULLs in aggregates

### 2.1 NULL inputs are skipped; COUNT(*) is not COUNT(col)

**Rule.** Every aggregate skips NULL inputs, except FIRST and LAST (§2.9). `COUNT(*)` counts rows; `COUNT(col)` counts rows where `col` is not NULL.

**DuckDB.** "All general aggregate functions ignore NULLs, except for list (array_agg), first (arbitrary) and last" ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)). **pyarrow.** `count` defaults to `mode="only_valid"`.

**Current behaviour.** `src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:95-99` and `:1431-1437` skip NULL inputs.

**Mark.** MATCHES.

### 2.2 All-NULL groups and empty groups

**Rule.** SUM, AVG, MIN and MAX over a group with no non-NULL input are NULL (SUM is not 0). COUNT is 0.

**DuckDB.** "All general aggregate functions except count return NULL on empty groups ... sum does not return zero" ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)). **pyarrow.** `sum` with its default `min_count=1` answers null.

**Current behaviour.** The mixed fold emits NULL when the contributing count is 0 (`src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:96-99`, `:262-266`); MIN/MAX cells carry a `seen` flag (`src/komira_agg/builtin_agg_fns_minmax.mojo:39-45`). The SUM cells in `komira_agg` do not: see "Code that does not follow", item 2.

**Mark.** MATCHES.

### 2.3 Empty input

**Rule.** An aggregate with no grouping keys over zero rows returns one row (COUNT 0, every other aggregate NULL). An aggregate with grouping keys over zero rows returns zero rows.

**DuckDB.** Standard SQL; the oracle confirms.

**Current behaviour.** No aggregate operator here exercises this end to end.

**Mark.** MATCHES.

### 2.4 NULL grouping keys, and DISTINCT

**Rule.** For grouping and for DISTINCT, NULL equals NULL: all rows whose key is NULL form one group, and DISTINCT keeps one NULL row. Multi-column keys compare column by column under the same rule.

**DuckDB.** Standard SQL; not stated on the GROUP BY page. The oracle confirms.

**Current behaviour.** The mixed fold declines a key column that holds NULLs rather than form the group differently from its sibling kernel (`src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:87-91`).

**Mark.** MATCHES.

### 2.5 COUNT(DISTINCT col)

**Rule.** Counts the distinct non-NULL values; NULL is not counted.

**DuckDB.** "When the DISTINCT clause is provided, only distinct values are considered", and NULLs are ignored ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)).

**Current behaviour.** `src/komira_agg_api/cd_distinct_key.mojo:234-263` reads the NULL mask beside the distinct keys so NULL rows are not counted.

**Mark.** MATCHES.

### 2.6 Floating-point grouping keys

**Rule.** As grouping and DISTINCT keys, all NaNs are one value and `-0.0` equals `+0.0`. Which bit pattern represents the group (`-0.0` or `+0.0`, which NaN payload) is not part of the result: tests compare floats under this equality, never by sign bit or payload.

**DuckDB.** Measured on 1.5.3 and recorded in `src/komira_udf/float_quotient_order.mojo:29-36`: `GROUP BY v` over `{1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}` gives five groups, `{0.0, -0.0}` one of them and `{NaN, NaN}` another.

**Current behaviour.** `src/komira_udf/float_quotient_order.mojo` is the one model, used by the hash and key-equality functions it lists at `:53-75`.

**Mark.** MATCHES.

### 2.7 MIN and MAX over NaN

**Rule.** NaN is greater than every other float, including +inf: MAX over a set containing NaN is NaN; MIN is NaN only if every input is NaN. The answer does not depend on input order or on how work is split between workers.

**DuckDB.** "NaN compares equal to NaN and greater than any other floating point number" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)).

**Current behaviour.** `src/komira_agg/builtin_agg_fns_minmax.mojo:19-37`: the float cells compare through the float model, and the header records the order-dependent answers the bare comparison used to give.

**Mark.** MATCHES.

### 2.8 MEDIAN and quantiles over NaN

**Rule (proposed).** NaN takes part like any other value and sorts above +inf (§4.3). A group whose only non-NULL values are NaN answers NaN.

**DuckDB.** Includes NaN (the measurement is recorded at `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82`).

**Current behaviour.** `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82` excludes NaN rows and answers NULL for an all-NaN group, and notes that DuckDB does not.

**Options.** (a) Match DuckDB. (b) Keep excluding NaN, as pandas' `median` does with its NaN-as-missing model, and record the departure.

**Recommendation.** (a). The plan distinguishes NaN from NULL everywhere else (§1.3, §2.6); excluding NaN here alone makes MEDIAN the one aggregate that treats NaN as missing. A pandas frontend that wants (b) can filter NaN before aggregating.

**Mark.** UNDECIDED.

### 2.9 FIRST, LAST, ANY_VALUE

**Rule.** FIRST and LAST return the value of the first and last row of the group in input order, NULL included. ANY_VALUE returns the first non-NULL value. Without an order imposed below the aggregate, which row is first is not defined, so a test may assert these only over an input whose order the plan fixes.

**DuckDB.** "first(arg): Returns the first value (null or non-null) from arg" ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)).

**Current behaviour.** No evaluator for these is in this repository; the IR states the distinction between ANY_VALUE (first non-NULL) and FIRST (first row) at `src/komira_plan_expr/typed_schema.mojo:1272-1276`.

**Mark.** MATCHES.

## 3. NULLs in joins

### 3.1 NULL keys never match in an equi-join

**Rule.** In INNER, LEFT, RIGHT, FULL and SEMI joins, a row whose equi-join key has a NULL in any key column matches nothing. In an outer join such a row still appears once, padded (§3.4). HASH and SORT_MERGE give the same result for the same inputs.

**DuckDB.** Follows from §1.2: the join condition is NULL, and NULL does not match ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).

**Current behaviour.** No join operator is in this repository; the join types and algorithms are declared at `src/komira_plan_ir/logical_plan.mojo:469-490`.

**Mark.** MATCHES.

### 3.2 ANTI join is NOT EXISTS

**Rule.** An ANTI join returns each left row that has no matching right row. A left row whose key is NULL matches nothing and is therefore returned; NULL keys on the right side match nothing and have no effect.

**DuckDB.** "Anti joins provide the same logic as the NOT IN operator, except anti joins ignore NULL values from the right table" ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).

**Current behaviour.** A correlated `NOT EXISTS` lowers to `JOIN_ANTI` (`src/komira_plan_expr/corr_subquery_data.mojo:66-69`).

**Mark.** MATCHES.

### 3.3 NOT IN over a subquery

**Rule.** `x NOT IN (SELECT y ...)` follows §1.5, which is not an ANTI join:
- if the subquery returns no rows, every row qualifies, including rows where `x` is NULL;
- otherwise a row qualifies only if `x` is not NULL, no `y` equals `x`, and no `y` is NULL.

So a single NULL in the subquery's result removes every row. A frontend builds this from an ANTI join plus the two NULL conditions; the plan has no separate null-aware anti join.

**DuckDB.** Follows from §1.5 and the ANTI-join note in §3.2.

**Current behaviour.** The SQL AST names the null-aware construction (`src/komira_sql/sql_ast.mojo:116`); the binder that builds it is not in this repository.

**Mark.** MATCHES.

### 3.4 Outer-join padding

**Rule.** An unmatched row of the preserved side appears once, with every column of the other side NULL. A padded NULL is indistinguishable from a NULL that was in the data.

**DuckDB.** "When an unpaired row is returned, the attributes from the other table are set to NULL" ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).

**Current behaviour.** The gather kernels keep a zero fill under a `-1` (unmatched) index (`src/komira_join_assembly/compiler_join_assembly.mojo:1339-1342`); the validity of padded rows is the operator's, which is not here.

**Mark.** MATCHES.

### 3.5 Residual predicates

**Rule.** A residual (non-equi) join predicate that evaluates to NULL for a pair counts as no match, exactly like FALSE.

**DuckDB.** Follows from §1.2.

**Current behaviour.** No join operator here.

**Mark.** MATCHES.

### 3.6 ASOF BACKWARD and FORWARD

**Rule.** BACKWARD matches each left row with the right row of the same equality group whose ordering value is the greatest one `<=` the left row's; FORWARD with the least one `>=`. At most one right row matches. A NULL ordering value matches nothing. An optional tolerance bounds `|left - right|`.

**DuckDB.** ASOF with `>=` (and `<=`) "joins each left side row with at most one right side row" ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).

**Current behaviour.** `src/komira_plan_ir/logical_plan.mojo:497-499` declares the directions.

**Mark.** MATCHES.

### 3.7 ASOF NEAREST

**Rule.** NEAREST matches the right row with the smallest `|left - right|`; on a tie between an earlier and a later row, the earlier (backward) row wins.

**DuckDB.** No NEAREST direction. polars' `join_asof(strategy="nearest")` is the nearest external analogue, but this document does not adopt its tie rule without a measurement.

**Current behaviour.** Declared at `src/komira_plan_ir/logical_plan.mojo:499`.

**Mark.** DEPARTS: a komira extension with no DuckDB counterpart. Expectations are hand-derived from this item.

## 4. Sort order and floating-point order

### 4.1 Default NULL placement

**Rule.** Where a sort key does not state a placement, NULLs sort **last in both directions**. This applies to SORT, TOPN, PARTITION_TOPN and the ORDER BY of a window.

**DuckDB.** "DuckDB keeps NULLS LAST even for DESC ordering, whereas PostgreSQL places NULLs first on DESC" ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)); `default_null_order` defaults to `NULLS_LAST` ([configuration](https://duckdb.org/docs/current/configuration/overview.html)). **pyarrow.** `sort_indices` puts nulls at the end by default ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).

**Current behaviour.** `src/komira_plan_expr/null_order_policy.mojo:41-48` records the measurement against DuckDB 1.5.3 and pyarrow 24.0.0, and `derived_nulls_first` (`:80-93`) returns False for both directions.

**Mark.** MATCHES.

### 4.2 Explicit NULL placement

**Rule.** A sort key that states NULLS FIRST or NULLS LAST is sorted that way, whatever its direction. The plan carries the request per key (`SortData.nulls_first`, `TopNData.nulls_first`).

**DuckDB.** `ORDER BY ... NULLS FIRST | NULLS LAST` ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)).

**Current behaviour.** `src/komira_plan_expr/null_order_policy.mojo:63-69`: the default is consulted only where nobody asked.

**Mark.** MATCHES.

### 4.3 NaN in a sort

**Rule.** NaN is a value, not NULL. Ascending, NaN sorts after +inf; descending, before +inf. All NaNs tie. NULL placement (§4.1, §4.2) is independent of NaN: under NULLS LAST an ascending sort ends `..., +inf, NaN, NULL`.

**DuckDB.** "NaN compares equal to NaN and greater than any other floating point number" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)). **pyarrow.** "NaN values are considered greater than any other non-null value, but smaller than nulls" ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).

**Current behaviour.** The sort and top-N kernels use the float model (`src/komira_udf/float_quotient_order.mojo:68-70`); the sort operators themselves are not here.

**Mark.** MATCHES.

### 4.4 Negative zero

**Rule.** `-0.0` and `+0.0` tie in a sort and are equal as keys (§2.6). Their relative order after a sort is not promised.

**DuckDB.** Not documented. Measured on 1.5.3 (`src/komira_udf/float_quotient_order.mojo:32-35`): `0.0 = -0.0` is TRUE and the two tie in ORDER BY.

**Current behaviour.** As §2.6.

**Mark.** MATCHES.

### 4.5 NaN in comparison predicates

**Rule (proposed).** The comparison operators use the same model as sorting and grouping: `NaN = NaN` is TRUE, `NaN <> NaN` is FALSE, and `NaN > x` is TRUE for every non-NaN `x`, including +inf.

**DuckDB.** As proposed ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)).

**Current behaviour.** The comparison kernels are IEEE: every ordered comparison with a NaN operand is FALSE and `NaN <> x` is TRUE. `src/komira_column_kernels/comparison.mojo:316-325` records this as a known divergence from DuckDB, PostgreSQL and Spark SQL.

**Options.** (a) Match DuckDB. (b) Keep IEEE comparisons and record the departure.

**Recommendation.** (a). With (b), `WHERE v = v` drops NaN rows while `GROUP BY v` keeps them as one group, and a filter `v > 1e308` disagrees with `ORDER BY v` about where NaN is. One model for all four is the property the float model was written to give.

**Mark.** UNDECIDED.

### 4.6 String order

**Rule.** Strings sort by their UTF-8 bytes (binary collation). Binary values sort by bytes. A shorter string that is a prefix of a longer one sorts first.

**DuckDB.** "Text is sorted using the binary comparison collation by default, which means values are sorted on their binary UTF-8 values" ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)).

**Current behaviour.** The string sort kernels are not here.

**Mark.** MATCHES.

### 4.7 Stability

**Rule.** No sort is stable. Rows that tie on every sort key come out in an unspecified order, which may differ between runs, worker counts and batch sizes. TOPN and LIMIT over a sort with ties may return any of the tied rows at the boundary. A test either sorts on a total key or compares tied rows as a set.

**DuckDB.** Does not document a stable sort. **pyarrow.** `sort_indices` is stable ("define a stable sort of the input", [compute functions](https://arrow.apache.org/docs/cpp/compute.html)); an expectation must not rely on that.

**Current behaviour.** The row-format sort is stable (`src/komira_row_format/row_sort_perm.mojo:28-31`), but no plan-level guarantee is built on it.

**Mark.** MATCHES.

## 5. Arithmetic

### 5.1 The plan's division operator on integers

**Rule.** `BIN_DIV` over two integer operands is integer division that truncates toward zero, and its result is an integer (§8.9): `7 / 2` is 3 and `-7 / 2` is -3. This is DuckDB's `//`. A frontend whose `/` means true division (SQL, DuckDB, polars) casts the left operand to DOUBLE before building `BIN_DIV`. A frontend whose `//` floors (polars, pandas, Python: `-7 // 2` is -4) builds that from `BIN_DIV` and a correction, not from `BIN_DIV` alone. Over float operands `BIN_DIV` is IEEE division.

**DuckDB.** `/` is floating-point division (`5 / 2 = 2.5`) and `//` is integer division ([numeric functions](https://duckdb.org/docs/current/sql/functions/numeric.html)). The sign of `//` for negative operands is not documented; measured on 1.5.3, `-7 // 2` is -3 (`src/komira_plan_expr/col_expr_division.mojo:5-17`).

**Current behaviour.** The column kernel divides with Mojo's integer `/`, which truncates (`src/komira_column_kernels/arithmetic.mojo:675`); its header records the result-type divergence from DuckDB's `/` as deliberate (`:83-88`). The Mojo dataframe surface decides `/` against `//` in one place (`src/komira_plan_expr/col_expr_division.mojo:28-35`). Two other implementations floor ("Code that does not follow", item 1).

**Mark.** DEPARTS: the plan has one division operator, and making it DuckDB's `/` would change the result type of every integer expression that divides. The frontends carry the difference.

### 5.2 Modulo sign

**Rule.** `BIN_MOD` is the truncated remainder: its sign is the dividend's. `-7 % 2` is -1 and `7 % -2` is 1. `a = (a / b) * b + (a % b)` holds with §5.1's division.

**DuckDB.** Not documented; measured on 1.5.3, `-7 % 2` is -1 (`src/komira_plan_expr/col_expr.mojo:852-856`). polars and Python floor instead (`-7 % 2` is 1).

**Current behaviour.** No `BIN_MOD` column kernel is in this repository; the IR states the rule (`src/komira_plan_expr/col_expr.mojo:852-856`).

**Mark.** MATCHES.

### 5.3 Integer division or modulo by zero

**Rule.** An integer `BIN_DIV` or `BIN_MOD` whose divisor is zero answers NULL for that row. Other rows keep their values. No error is raised.

**DuckDB.** Measured on 1.5.3 (`src/komira_column_kernels/arithmetic.mojo:74-78`): `qty // 0` and `qty % 0` are NULL. **pyarrow.** `divide` on integers raises on a zero divisor; it is not the oracle for this item.

**Current behaviour.** `src/komira_column_kernels/arithmetic.mojo:572-580` and `:615-676` answer NULL per row. The expression executor raises instead ("Code that does not follow", item 1).

**Mark.** MATCHES.

### 5.4 Signed MIN divided by -1

**Rule.** `MIN / -1` for a signed integer type is an error ("Out of Range"), since the quotient is not representable.

**DuckDB.** Measured on 1.5.3: `(-9223372036854775808) // (-1)` raises an Out of Range Error (`src/komira_column_kernels/arithmetic.mojo:74-80`).

**Current behaviour.** `src/komira_column_kernels/arithmetic.mojo:111-130` raises when both operands of such a pair are valid.

**Mark.** MATCHES.

### 5.5 Integer overflow

**Rule.** Integer `+`, `-`, `*` and unary minus whose exact result does not fit the result type (§8.9) raise an error naming the operation, never wrap and never saturate.

**DuckDB.** "Attempts to store values outside of the allowed range will result in an error" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)); measured on 1.5.3: `Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!` (`src/komira_scalar_arithmetic/int_overflow.mojo:11-17`). **pyarrow.** `add`, `subtract`, `multiply` wrap; only the `_checked` variants raise ([compute API](https://arrow.apache.org/docs/python/api/compute.html)). An oracle case uses the `_checked` variants or DuckDB.

**Current behaviour.** `src/komira_scalar_arithmetic/int_overflow.mojo:1-25` is the one predicate; the column kernels raise (`src/komira_column_kernels/arithmetic.mojo:685-690`).

**Mark.** MATCHES.

### 5.6 Float division by zero

**Rule.** Float division by zero follows IEEE 754: `x / 0.0` is +inf or -inf by the signs of `x` and the zero, and `0.0 / 0.0` is NaN. No NULL and no error.

**DuckDB.** `ieee_floating_point_ops` (default true): "Use IEE754-compliant floating point operations (returning NAN instead of errors/NULL)" ([configuration](https://duckdb.org/docs/current/configuration/overview.html)).

**Current behaviour.** The float path is IEEE and unguarded (`src/komira_column_kernels/arithmetic.mojo:65-70`).

**Mark.** MATCHES.

### 5.7 NaN and infinity propagation

**Rule.** Float arithmetic is IEEE 754: an operation with a NaN operand is NaN, `inf - inf` and `0 * inf` are NaN, and `inf + x` is inf for finite `x`. An arithmetic operation with a NULL operand is NULL whatever the other operand is (NULL dominates NaN).

**DuckDB.** As above, under `ieee_floating_point_ops`.

**Current behaviour.** The float kernels are bare IEEE operations; validity is the AND of the operands' (`src/komira_column_kernels/compiler_helpers.mojo:2860-2880`).

**Mark.** MATCHES.

## 6. Casts

### 6.1 Strict casts and TRY_CAST

**Rule.** A CAST whose input cannot be represented in the target type, or cannot be parsed, raises an error. TRY_CAST answers NULL for that row instead, and is therefore always nullable. A NULL input casts to NULL under both.

**DuckDB.** A failed cast "throws an error by default"; `TRY_CAST` converts failures to NULL ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)).

**Current behaviour.** `CastData.try_cast` selects the mode (`src/komira_plan_expr/expr.mojo:1638-1651`); a TRY_CAST result is typed nullable (`src/komira_plan_expr/expr_walk.mojo:1096-1114`).

**Mark.** MATCHES.

### 6.2 Integer to narrower integer

**Rule.** A value outside the target's range is an error (NULL under TRY_CAST). It is never truncated to its low bits.

**DuckDB.** "Type INT32 with value 999 can't be cast because the value is out of range for the destination type INT8" ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)).

**Current behaviour.** Two casts wrap ("Code that does not follow", item 4).

**Mark.** MATCHES.

### 6.3 Float to integer

**Rule.** A FLOAT or DOUBLE casts to an integer by rounding **half to even** (2.5 to 2, 3.5 to 4, -2.5 to -2). The range check is on the unrounded value: it must satisfy `-2^(N-1) <= v < 2^(N-1)` for an N-bit signed target, otherwise the cast is an error, and NaN and ±inf are errors.

**DuckDB.** Measured on 1.5.3 over a DOUBLE column (`src/komira_column_kernels/cast_null.mojo:138-156`). A bare literal such as `2.5` is a DECIMAL in DuckDB and follows §6.4 instead, which is why the documentation's examples (`CAST(3.5 AS INTEGER)` is 4, `CAST(-1.7 AS INTEGER)` is -2, [typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)) do not decide this item. **pyarrow.** A safe cast refuses a non-integral float; it is not the oracle.

**Current behaviour.** `src/komira_column_kernels/cast_null.mojo:177-260` implements the rule. One path truncates ("Code that does not follow", item 3).

**Mark.** MATCHES.

### 6.4 Decimal to integer, and float to decimal

**Rule.** DECIMAL to integer rounds half away from zero (`-2.5` to -3). FLOAT or DOUBLE to DECIMAL rounds half away from zero at the target scale. Out of range is an error.

**DuckDB.** Measured on 1.5.3 (`src/komira_scalar_arithmetic/decimal_cast.mojo:6-16`).

**Current behaviour.** `src/komira_scalar_arithmetic/decimal_cast.mojo:77-105` and `:126-131`.

**Mark.** MATCHES.

### 6.5 DOUBLE to FLOAT

**Rule.** A finite DOUBLE whose FLOAT rounding is infinite is an error. A value just above the FLOAT maximum that rounds down to it is accepted. ±inf and NaN carry over.

**DuckDB.** Measured on 1.5.3 (`src/komira_column_kernels/cast_null.mojo:60-80`).

**Current behaviour.** `eval_cast_f64_to_f32_checked` (`src/komira_column_kernels/cast_null.mojo:97`).

**Mark.** MATCHES.

### 6.6 String to integer: the grammar

**Rule.** Leading and trailing ASCII whitespace is ignored; an optional `+` or `-` sign; one or more decimal digits; leading zeros allowed. An empty or all-whitespace string, any other character, or a value out of range is an error (NULL under TRY_CAST).

**Open edge cases.** A decimal point (`'1.5'`, `'1.0'`), an exponent (`'1e2'`), underscores between digits, hexadecimal or binary prefixes, and non-ASCII whitespace.

**DuckDB.** Parsing "can raise an error at runtime if DuckDB cannot parse and convert the provided text" ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)); the edge cases are not documented.

**Current behaviour.** `src/komira_kernels/cast_to_varchar_kernels.mojo:40-50` states the grammar above and rejects every edge case listed, including `'1e2'`.

**Options.** (a) Measure each edge case on DuckDB and adopt its answer, listing it here. (b) Keep the strict grammar above and record each difference as a departure.

**Recommendation.** (a): these are the inputs a CSV with sloppy numbers produces, and an answer that differs from DuckDB on them is the kind a user meets first.

**Mark.** UNDECIDED.

### 6.7 String to double out of range

**Rule (proposed).** A string whose value is finite but outside DOUBLE's range (`'1e400'`) is an error, as an integer out of range is. `'inf'`, `'infinity'`, `'nan'` (any case, with an optional sign) parse to those values.

**DuckDB.** Not documented; the oracle measures it. The proposal assumes DuckDB raises.

**Current behaviour.** Saturates to ±inf (`src/komira_kernels/cast_to_varchar_kernels.mojo:48`); accepts the special spellings (`:47`).

**Recommendation.** Match DuckDB, whichever it is, once measured.

**Mark.** UNDECIDED.

### 6.8 Timestamp units

**Rule (proposed).** The plan carries Arrow's four timestamp units (seconds, milliseconds, microseconds, nanoseconds), and DATE32 as days. Casting to a finer unit is exact or an error if out of range. Casting to a coarser unit follows DuckDB's measured rounding (truncation toward zero, or toward negative infinity for instants before 1970: this is the open question).

**DuckDB.** `TIMESTAMP` is microseconds; `TIMESTAMP_S`, `TIMESTAMP_MS` and `TIMESTAMP_NS` are the other units ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)). The direction of rounding before 1970 is not documented.

**Current behaviour.** The field extracts accept all four units (`src/komira_kernels/temporal_extract.mojo:6-8`, `:1152`). No unit-changing timestamp cast kernel is in this repository.

**Recommendation.** Measure DuckDB on a pre-1970 instant with a sub-unit part and adopt its rule.

**Mark.** UNDECIDED.

### 6.9 Time zones

**Rule (proposed).** A timestamp with a time zone is an instant (UTC ticks), and the zone is metadata on the column type. A timestamp without one is a wall-clock reading with no zone. There is one session time zone and it is UTC: field extraction (`year`, `hour`, ...) and `date_trunc` over a zoned timestamp operate on the UTC wall clock. Comparison and join of two zoned timestamps compare instants, whatever their zones. Mixing a zoned and an unzoned timestamp in one comparison is refused by name.

**DuckDB.** `TIMESTAMPTZ` stores "the INT64 number of non-leap microseconds since the Unix epoch"; extraction and rendering use the session `TimeZone` setting, which defaults to the system zone ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html), [configuration](https://duckdb.org/docs/current/configuration/overview.html)). With `TimeZone = 'UTC'`, DuckDB answers as proposed.

**Current behaviour.** The zone travels on the field (`src/komira_kernels/join_key_envelope.mojo:319-330`; aliases keep it, `src/komira_plan_expr/expr_walk.mojo:740-750`). The extract kernels take no zone (`src/komira_kernels/temporal_extract.mojo:1152`), so they already answer in UTC.

**Options.** (a) UTC session zone, as proposed. (b) A session zone setting carried in the plan. (c) Extract in the column's own zone.

**Recommendation.** (a) now. (b) needs a wire field and is a later decision; (c) is not what DuckDB does.

**Mark.** UNDECIDED.

### 6.10 CAST_TO_VARCHAR rendering

`PLAN_CAST_TO_VARCHAR` turns every column of a result into text before a text sink (CSV, JSON Lines) writes it (`src/komira_plan_ir/logical_plan.mojo:138-152`). Its rendering is what those files contain.

**Rule (proposed).** Each type renders as DuckDB's `CAST(x AS VARCHAR)`:

| Type | Rendering |
|---|---|
| integers | decimal digits, `-` for negatives, no `+`, no leading zeros |
| BOOLEAN | `true`, `false` |
| DOUBLE, FLOAT | the shortest text that reads back to the same value; to be measured: `1.0` (not `1`), `1e+20`, `1e-07`, `nan`, `inf`, `-inf`, `-0.0` |
| DECIMAL(p, s) | exactly `s` digits after the point (`212.60`, not `212.6`) |
| DATE | `YYYY-MM-DD` |
| TIMESTAMP (no zone) | `YYYY-MM-DD hh:mm:ss`, then `.` and the fraction with trailing zeros removed if non-zero |
| TIMESTAMP (zoned) | as above, then the UTC offset of the session zone (`+00`) |
| strings | unchanged |
| NULL | NULL (the sink decides how to write it) |

**DuckDB.** "Any type can be cast to VARCHAR" ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)); the ISO 8601 shape of timestamps and the offset rendering of zoned ones are documented ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)). The float and decimal spellings in the table are not documented and must be measured. **pyarrow.** `cast(double, string)` renders 1.0 as `1`; not followed.

**Current behaviour.** Integers, booleans and strings render as in the table (`src/komira_kernels/cast_to_varchar_kernels.mojo:9-50`). Floats render with Mojo's `String(Float64)` (`:316-322`), which has not been compared with DuckDB. No DECIMAL, DATE or TIMESTAMP rendering kernel is in this repository.

**Recommendation.** Adopt the table after the oracle has measured each float and decimal spelling, and test it with one case per row.

**Mark.** UNDECIDED.

## 7. Strings

### 7.1 Length

**Rule.** `length(s)` counts Unicode code points; `strlen(s)` counts bytes; `bit_length(s)` is 8 times `strlen(s)`. All three are INT64, and NULL for a NULL input. Grapheme-cluster counts are not offered.

**DuckDB.** `length`: "Number of characters"; `strlen`: "Number of bytes" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)). DuckDB's `length_grapheme` has no plan counterpart. **pyarrow.** `utf8_length` counts code points and `binary_length` bytes.

**Current behaviour.** `src/komira_plan_expr/expr.mojo:872-889` (`STRFN_LENGTH`) and `:902-910`; the grapheme functions are refused by name (`src/komira_sql/sql_fn_table.mojo:1029-1040`).

**Mark.** MATCHES.

### 7.2 CONCAT

**Rule.** `concat(a, b, ...)` skips NULL arguments and is never NULL: `concat('a', NULL, 'c')` is `'ac'` and `concat(NULL, NULL)` is `''`.

**DuckDB.** "NULL inputs are skipped" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)); `concat(NULL, NULL)` measured as `''` (`src/komira_plan_expr/expr.mojo:1103-1110`).

**Current behaviour.** `STRFNN_CONCAT` (`src/komira_plan_expr/expr.mojo:1103-1121`).

**Mark.** MATCHES.

### 7.3 The `||` operator

**Rule.** `a || b` is NULL if either operand is NULL. The plan has no `||` operator, and a frontend must not lower `||` to CONCAT (§7.2), whose NULL rule is the opposite. It lowers `a || b` to `CASE WHEN a IS NULL OR b IS NULL THEN NULL ELSE concat(a, b) END`.

**DuckDB.** "Any NULL input results in NULL" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)).

**Current behaviour.** No `||` in the plan or the SQL parser (`src/komira_plan_expr/expr.mojo:1110-1114`).

**Mark.** MATCHES.

### 7.4 CONCAT_WS

**Rule.** `concat_ws(sep, a, b, ...)`: a NULL separator makes the result NULL; a NULL argument is skipped together with its separator, so `concat_ws('-', 'a', NULL, 'c')` is `'a-c'` and `concat_ws('-', NULL, 'a')` is `'a'`.

**DuckDB.** "NULL inputs are skipped" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)); the NULL-separator rule is measured on 1.5.3 (`src/komira_plan_expr/expr.mojo:1123-1137`).

**Current behaviour.** `STRFNN_CONCAT_WS` (`src/komira_plan_expr/expr.mojo:1123-1137`).

**Mark.** MATCHES.

### 7.5 CONCAT argument types

**Rule.** Every argument of CONCAT and CONCAT_WS must be a string. Any other type is refused by name; a frontend that wants DuckDB's behaviour casts each argument to VARCHAR (§6.10) first.

**DuckDB.** `concat` accepts any type and renders it (`concat(1, 'a', 2.5)` is `'1a2.5'`, measured, `src/komira_plan_expr/expr.mojo:1116-1121`).

**Current behaviour.** As the rule (`src/komira_plan_expr/expr.mojo:1116-1121`).

**Mark.** DEPARTS: a narrowing. The plan refuses where DuckDB converts, and never returns a different value.

### 7.6 LIKE

**Rule.** `s LIKE p` matches the whole string. `%` matches any run of zero or more characters and `_` exactly one character (one code point). Every other pattern character, backslash included, matches itself. Matching is case-sensitive and byte-exact (no collation). A NULL operand gives NULL.

**DuckDB.** "LIKE pattern matching always covers the entire string"; ILIKE is the case-insensitive form; an escape character exists only through the `ESCAPE` clause ([pattern matching](https://duckdb.org/docs/current/sql/functions/pattern_matching.html)).

**Current behaviour.** `src/komira_column_kernels/string_comparison.mojo:1772-1822` (`_like_match`, `_` advances one code point) and `:1824-1830` ("no escape").

**Mark.** MATCHES.

### 7.7 LIKE ESCAPE and ILIKE

**Rule.** The plan's `STR_LIKE` (`src/komira_plan_expr/expr.mojo:807`) carries no escape character and no case-insensitive flag. A frontend refuses `ESCAPE` by name; ILIKE is refused, or lowered only by a frontend that states how it folds case.

**DuckDB.** Both exist ([pattern matching](https://duckdb.org/docs/current/sql/functions/pattern_matching.html)).

**Current behaviour.** The SQL parser refuses `ESCAPE` by name (`src/komira_sql/sql_parser.mojo:1520`); ILIKE is parsed into the SQL tree, and there is no plan operator for it.

**Mark.** DEPARTS: a narrowing, refused by name.

### 7.8 Regular expressions

**Rule.** The regular-expression functions use RE2's syntax and semantics over UTF-8: `.` and a character class match one character (code point); leftmost-first matching; no backreferences and no lookaround, which are errors at compile time. A malformed pattern is an error. `regexp_matches` (`regexp_like`) succeeds on a match anywhere; `regexp_full_match` needs the whole string. `regexp_replace` replaces the first match unless the `g` flag is given. Flags: `i` (case-insensitive), `s` (`.` matches newline), `m` (multi-line anchors), `x`.

**DuckDB.** Uses RE2; partial vs full match, first-occurrence replace and the `g` flag as stated ([regular expressions](https://duckdb.org/docs/current/sql/functions/regular_expressions.html)).

**Current behaviour.** The syntax is RE2's subset and refuses backreferences and lookaround (`src/komira_column_kernels/regexp_nfa.mojo:14-21`), but matching is over bytes ("Code that does not follow", item 5). On ASCII input the answers agree.

**Mark.** MATCHES.

### 7.9 UPPER and LOWER

**Rule.** Simple (one-to-one) Unicode case mapping per code point: `upper('ß')` is `'ẞ'`, not `'SS'`. Bytes that are not valid UTF-8 are copied through unchanged.

**DuckDB.** Measured on 1.5.3 over every code point: every answer is one code point (`src/komira_column_kernels/unicode_case.mojo:17-25`).

**Current behaviour.** `src/komira_column_kernels/unicode_case.mojo`.

**Mark.** MATCHES.

## 8. Result types

The table is the authority for the type of every result column. A conformance case asserts that the actual schema equals the expected schema, and the expected schema comes from this table, not from the plan's own `output_schema`. When the two disagree, that is a question for review, not a reason to edit the expectation. Unless a row says otherwise, every result is nullable.

| Item | Expression | Result type | DuckDB | Mark |
|---|---|---|---|---|
| §8.1 | `SUM(int8 / int16 / int32 / int64)` | INT64; a total outside INT64 is an error | HUGEINT | DEPARTS |
| §8.2 | `SUM(uint8 / uint16 / uint32 / uint64)` | UINT64; overflow is an error | HUGEINT | DEPARTS |
| §8.3 | `SUM(float32 / float64)` | FLOAT64 | DOUBLE | MATCHES |
| §8.4 | `SUM(decimal(p, s))` | DECIMAL(38, s) | DECIMAL(38, s) | MATCHES |
| §8.5 | `AVG(any numeric)`, `STDDEV_*`, `VAR_*`, `CORR`, `MEDIAN` | FLOAT64 | DOUBLE | MATCHES |
| §8.6 | `COUNT(*)`, `COUNT(col)`, `COUNT(DISTINCT col)` | INT64, never NULL | BIGINT | MATCHES |
| §8.7 | `MIN`, `MAX`, `FIRST`, `LAST`, `ANY_VALUE` | the input's type | the input's type | MATCHES |
| §8.8 | comparisons, AND, OR, NOT, IN, LIKE, IS [NOT] NULL | BOOLEAN | BOOLEAN | MATCHES |
| §8.9 | integer and mixed arithmetic | see §8.9 | the wider type | UNDECIDED |
| §8.10 | `int / int` (`BIN_DIV`) | the integer type (§5.1) | DOUBLE for `/`, integer for `//` | DEPARTS (§5.1) |
| §8.11 | `decimal ± decimal` | DECIMAL(min(max(p1-s1, p2-s2) + max(s1, s2) + 1, 38), max(s1, s2)) | the same | MATCHES |
| §8.12 | `decimal * decimal` | DECIMAL(min(p1 + p2 + 1, 38), s1 + s2); scale above 38 is an error | precision p1 + p2 | UNDECIDED |
| §8.13 | `decimal / decimal`, `decimal / int64` | FLOAT64 | DOUBLE | MATCHES |
| §8.14 | `CASE`, `COALESCE` | see §8.14 | the common supertype | UNDECIDED |
| §8.15 | `length`, `strlen`, `strpos`, every EXTRACT field, `dayofweek` | INT64 | BIGINT | MATCHES |

Notes:

- **§8.1, §8.2 (DEPARTS).** Arrow has no 128-bit integer type, and returning DECIMAL(38, 0) would change every integer total's type in every consumer. The engine refuses a total outside INT64 by name rather than wrap (`src/komira_op_agg_state/int_sum_overflow.mojo:31-41`, which also records DuckDB's `typeof(sum(<bigint>))` as HUGEINT). An oracle query states the plan's type explicitly (`CAST(sum(x) AS BIGINT)`). The plan's rule is at `src/komira_plan_ir/logical_plan.mojo:2411-2424`.
- **§8.3, §8.4.** `src/komira_plan_ir/logical_plan.mojo:2425-2470`; the DECIMAL(38, s) rule is measured against DuckDB, pyarrow and polars there.
- **§8.5, §8.6.** `src/komira_plan_expr/typed_schema.mojo:1173-1180` and `:1185-1210`. DuckDB's AVG of a DECIMAL is to be confirmed by the oracle.
- **§8.8.** `src/komira_plan_expr/expr_walk.mojo:819-835` types every comparison and AND/OR as BOOLEAN, nullable.
- **§8.11, §8.13.** `src/komira_scalar_arithmetic/decimal_arith.mojo:150-156`; `src/komira_plan_expr/expr_walk.mojo:857-890`. DuckDB: "Addition, subtraction and multiplication of two fixed-point decimals returns another fixed-point decimal with the required WIDTH and SCALE to contain the exact result"; division of decimals uses "approximate floating-point arithmetic" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)).
- **§8.15.** `src/komira_plan_expr/expr_walk.mojo:1195-1230`; `src/komira_kernels/temporal_extract.mojo:13-29` records DuckDB's BIGINT.

### 8.9 Integer and mixed arithmetic

**Rule (proposed).** For `+ - * %` and `BIN_DIV`:
- two integer operands give the wider of the two types, with signedness rules as DuckDB's;
- an integer with a FLOAT32 gives FLOAT32; with a FLOAT64, FLOAT64;
- FLOAT32 with FLOAT64 gives FLOAT64;
- overflow of the result type is an error (§5.5). The result is never widened to avoid overflow: INT32 + INT32 is INT32.

**DuckDB.** Implicit casts are added only where "the cast cannot fail, such as INTEGER to DOUBLE" ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)): the narrower operand is cast up to the wider.

**Current behaviour.** The plan types a non-decimal arithmetic result as the **left** operand's type unless either side is FLOAT64 (`src/komira_plan_expr/expr_walk.mojo:968-975`). So `int8 + int16` is INT8, `int32 + int64` is INT32, and `int64 + float32` is INT64. An INT32 column with an integer literal outside INT32 is widened to INT64 (`:977-1005`). The typed surface mirrors the left-wins rule (`src/komira_plan_expr/typed_schema.mojo:1296-1325`).

**Options.** (a) Adopt DuckDB's rule, in the plan's type inference and in the kernels. (b) Keep "left wins" and require every frontend to cast operands to a common type before building the expression; the plan refuses mixed integer widths by name.

**Recommendation.** (a). (b) is acceptable as an interim step, but "left wins" without a refusal gives `a + b` and `b + a` different types, and `int32 + int64` a type that cannot hold most of its inputs.

**Mark.** UNDECIDED.

### 8.12 Decimal multiplication

**Rule (proposed).** DECIMAL(p1, s1) * DECIMAL(p2, s2) is DECIMAL(min(p1 + p2, 38), s1 + s2). If s1 + s2 exceeds 38 the expression is an error. A product whose value needs more digits than the precision is an error at evaluation.

**DuckDB.** Precision p1 + p2 ("the required WIDTH and SCALE to contain the exact result", [numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)); the difference is recorded at `src/komira_plan_expr/expr_walk.mojo:936-944` ("32 where DuckDB says 31").

**Current behaviour.** min(p1 + p2 + 1, 38) (`src/komira_scalar_arithmetic/decimal_arith.mojo:159-183`). The value and scale agree with DuckDB; only the declared precision differs.

**Recommendation.** Match DuckDB. The extra digit buys nothing: p1 + p2 digits already hold every product of the two inputs.

**Mark.** UNDECIDED.

### 8.14 CASE and COALESCE

**Rule (proposed).** The result type of CASE (and of COALESCE, which is a CASE) is the common supertype of every THEN branch and the ELSE, by §8.9's widening rule; a NULL literal branch takes the others' type. Branches with no common supertype (a string and a number) are refused by name.

**DuckDB.** Combination casting, used "in UNION, CASE, comparisons", picks a type every branch converts to, and is more lenient than §8.9 (for example BOOLEAN to INTEGER) ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)).

**Current behaviour.** The result type is the **first** THEN branch's (`src/komira_plan_expr/expr_walk.mojo:1146-1159`). The dataframe and SQL builders convert integer literals to float when some argument provably floats (`src/komira_plan_expr/col_expr.mojo:420-441`); other mixes are refused by the engine.

**Options.** (a) The common supertype, as proposed. (b) DuckDB's full combination-cast table, including BOOLEAN to INTEGER. (c) Keep "first branch" and have frontends cast every branch.

**Recommendation.** (a). (b)'s extra conversions are surprises in a typed plan, and (c) gives `CASE WHEN c THEN 1 ELSE 2.5 END` an integer type.

**Mark.** UNDECIDED.

## 9. Window functions

### 9.1 Frames

**Rule.** In the plan every window function carries its frame explicitly (ROWS or RANGE, with its two bounds); there is no plan-level default. A frontend fills in SQL's default:
- with an ORDER BY in the window, `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, where CURRENT ROW includes all peers of the current row, so rows tying on the order key get the same value;
- with no ORDER BY, the whole partition.

**DuckDB.** As stated ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).

**Current behaviour.** `PartitionFrame.running_range()` is the SQL default, and its docstring says why ROWS is wrong for it (`src/komira_plan_expr/partition_frame.mojo:114-130`). FIRST_VALUE, LAST_VALUE and NTH_VALUE default to it (`src/komira_plan_expr/partition_expr.mojo:226-255`); the `running_*` builders do not ("Code that does not follow", item 6).

**Mark.** MATCHES.

### 9.2 Ranking and ties

**Rule.** ROW_NUMBER numbers the rows of a partition 1 to n. RANK gives peers (rows tying on every order key) the row number of the first peer, leaving gaps. DENSE_RANK numbers peer groups 1, 2, 3 without gaps. Ranking functions ignore the frame.

**DuckDB.** rank is "same as row_number of its first peer"; dense_rank "counts peer groups" ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).

**Current behaviour.** Declared at `src/komira_plan_expr/partition_expr.mojo:44-46`; the window operator is not here.

**Mark.** MATCHES.

### 9.3 ROW_NUMBER among peers

**Rule.** Which peer gets which ROW_NUMBER is not specified (§4.7). A test fixes it with an order key that has no ties, or compares peers as a set.

**DuckDB.** Not specified.

**Current behaviour.** As §9.2.

**Mark.** MATCHES.

### 9.4 LAG and LEAD

**Rule.** The offset defaults to 1. Where the offset row does not exist, the result is the default value, and the default value defaults to NULL. An explicit NULL default is the same as no default. LAG and LEAD ignore the frame.

**DuckDB.** The offset "defaults to 1"; the default "default to NULL" ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).

**Current behaviour.** `src/komira_plan_expr/partition_expr.mojo:199-224` and `:371-384`.

**Mark.** MATCHES.

### 9.5 IGNORE NULLS

**Rule.** LAG and LEAD count every row, NULL or not. `IGNORE NULLS` is not in the plan vocabulary and a frontend refuses it by name.

**DuckDB.** Supports `IGNORE NULLS` for lag and lead ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).

**Current behaviour.** No such field on `PartitionExpr` (`src/komira_plan_expr/partition_expr.mojo:110-150`).

**Mark.** DEPARTS: a narrowing, refused by name.

### 9.6 NULL placement in a window's ORDER BY

**Rule.** The window ORDER BY uses the default placement (§4.1) on every key; the plan cannot express another. A frontend refuses `NULLS FIRST` inside `OVER (...)` by name (and `NULLS LAST` is the default, so it may be accepted).

**DuckDB.** Accepts an explicit placement in `OVER`.

**Current behaviour.** The PARTITION_BY node carries no per-key placement (its wire arm has no such field), so the window key takes `derived_nulls_first` (`src/komira_plan_expr/null_order_policy.mojo:80-93`).

**Mark.** DEPARTS: a narrowing, refused by name.

## 10. Excel error values

DuckDB has no error values, so nothing in this section has a DuckDB oracle. The authority is Microsoft's documented behaviour, and expectations are hand-derived from this section.

### 10.1 The code space

**Rule.** The error values are Microsoft's list: `#DIV/0!`, `#N/A`, `#VALUE!`, `#REF!`, `#NAME?`, `#NUM!`, `#NULL!`, `#SPILL!`, `#CALC!`. There is no circular-reference error value: Excel reports a circular reference as a warning, and Microsoft documents no literal for it. An unrecognized `#...` literal is `#NAME?`. An error is a third state of a value, distinct from both a valid value and NULL (a blank cell).

**Microsoft.** The error values and their meanings ([detect formula errors](https://support.microsoft.com/en-us/excel/detect-formula-errors-in-excel), [ERROR.TYPE](https://support.microsoft.com/en-us/office/error-type-function-10958677-7c8d-44f7-ae77-b9a9ee6eefaa)).

**Current behaviour.** `src/komira_plan_expr/excel_error_code.mojo:28-38` still defines `XL_ERR_CIRCULAR = 10`, and the wire vocabulary has the matching enum member. Open PR #662 removes the code and reserves its wire number. The three-state status lane is declared at `src/komira_plan_expr/excel_error_code.mojo:41-46`; it is not yet carried through columns and batches (`:16-20`).

**Mark.** DEPARTS: there is no DuckDB counterpart; the list itself is already decided and needs only ratification here.

### 10.2 Propagation through scalar expressions

**Rule (proposed).**
1. An arithmetic operator, comparison or function with an error operand answers that error. With several error operands, the leftmost wins.
2. An error dominates NULL: `#N/A + NULL` is `#N/A`.
3. AND and OR do not short-circuit past an error: `FALSE AND #N/A` is `#N/A`, unlike §1.1's `FALSE AND NULL`.
4. A conditional with an error condition answers the error; an error in an untaken branch has no effect.
5. `IFERROR(x, y)` answers `y` for any error in `x`; `IFNA(x, y)` only for `#N/A`; `ISERROR`, `ISERR` and `ISNA` are total.
6. In the spreadsheet surface, division by zero is `#DIV/0!`, not §5.3's NULL. That is the frontend's mapping; the plan's `BIN_DIV` keeps §5.3.

**Microsoft.** Rule 1 is the documented behaviour for SUM and AVERAGE ("If AVERAGE or SUM refer to cells that contain #VALUE! errors, the formulas will result in a #VALUE! error", [correct a #VALUE! error in AVERAGE or SUM](https://support.microsoft.com/en-us/excel/how-to-correct-a-value-error-in-average-or-sum-functions)). The leftmost-wins rule and rule 3 are not documented and must be measured in Excel.

**Current behaviour.** None: the propagation algebra is not implemented (`src/komira_plan_expr/excel_error_code.mojo:16-20`), and the comparison kernels reserve an error-dominant NULL policy that is not implemented (`src/komira_kernels/comparison_kleene.mojo:57-63`).

**Options.** (a) The rules above, measured against Excel before ratification. (b) Treat an error as NULL inside the plan and restore it at the surface, which loses which error occurred.

**Recommendation.** (a).

**Mark.** UNDECIDED.

### 10.3 Errors in aggregates and sorts

**Rule (proposed).**
- SUM, AVERAGE, MIN, MAX and the other numeric aggregates over a range containing an error answer the first error in input order.
- COUNT counts numbers only and skips errors; COUNTA counts non-blank cells, errors included.
- A sort orders numbers, then text, then logical values (FALSE before TRUE), then errors, all errors equal to one another; blanks (NULL) come last in both directions, which agrees with §4.1.

**Microsoft.** The SUM/AVERAGE rule as in §10.2. The sort order: "All error values, such as #NUM! and #REF!, are equal", and "sort always puts blank cells last" in both directions ([sort data](https://support.microsoft.com/en-us/office/sort-data-in-a-workbook-in-the-browser-bf63427c-1b17-4ec5-a909-a5f2d07d924c)).

**Current behaviour.** None.

**Recommendation.** Adopt, with "first error in input order" measured in Excel before ratification.

**Mark.** UNDECIDED.

## Counts

MATCHES 57, DEPARTS 9, UNDECIDED 13: 79 marks. Each numbered item counts once: the 68 subsections that carry a **Mark.** line, plus the 11 rows of the §8 table that have no subsection of their own (§8.9, §8.12 and §8.14 have both and count once; §8.10 repeats §5.1 and is not counted). The 22 rows of "Rulings needed" are the 9 DEPARTS and 13 UNDECIDED items.

## What are its limits and open questions?

- **No end-to-end evidence yet.** Most operators named here have no executor in this repository, so "current behaviour" is often a kernel, an IR declaration or a comment. Only the conformance suite can say what a plan returns.
- **DuckDB statements taken from komira's source.** Where DuckDB's documentation is silent, this document quotes measurements recorded in komira's source. They are claims about DuckDB, not about komira, and the oracle re-measures each; a disagreement corrects this document.
- **Not covered.** Collations, intervals and interval arithmetic, nested types, JSON functions, the temporal field extracts (beyond §6.9), math-function domain errors (`sqrt(-1)`, `ln(0)`), UDF null modes, and the rounding of `round()` (half away from zero, `src/komira_column_kernels/numeric_unary.mojo:35`). Each needs its own items before a hand expectation may rely on it.

## Sources

DuckDB documentation:
- [Logical operators](https://duckdb.org/docs/current/sql/expressions/logical_operators.html)
- [Comparison operators](https://duckdb.org/docs/current/sql/expressions/comparison_operators.html)
- [IN operator](https://duckdb.org/docs/current/sql/expressions/in.html)
- [NULL values](https://duckdb.org/docs/current/sql/data_types/nulls.html)
- [Aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)
- [FROM and JOIN clauses](https://duckdb.org/docs/current/sql/query_syntax/from.html)
- [ORDER BY clause](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)
- [Configuration](https://duckdb.org/docs/current/configuration/overview.html)
- [Numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)
- [Numeric functions](https://duckdb.org/docs/current/sql/functions/numeric.html)
- [Typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)
- [Timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)
- [Text functions](https://duckdb.org/docs/current/sql/functions/text.html)
- [Pattern matching](https://duckdb.org/docs/current/sql/functions/pattern_matching.html)
- [Regular expressions](https://duckdb.org/docs/current/sql/functions/regular_expressions.html)
- [Window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)

Apache Arrow documentation:
- [Compute functions (C++)](https://arrow.apache.org/docs/cpp/compute.html)
- [pyarrow compute API](https://arrow.apache.org/docs/python/api/compute.html)
- [SetLookupOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.SetLookupOptions.html)

Microsoft documentation:
- [Detect formula errors in Excel](https://support.microsoft.com/en-us/excel/detect-formula-errors-in-excel)
- [ERROR.TYPE function](https://support.microsoft.com/en-us/office/error-type-function-10958677-7c8d-44f7-ae77-b9a9ee6eefaa)
- [How to correct a #VALUE! error in AVERAGE or SUM](https://support.microsoft.com/en-us/excel/how-to-correct-a-value-error-in-average-or-sum-functions)
- [Sort data in a workbook](https://support.microsoft.com/en-us/office/sort-data-in-a-workbook-in-the-browser-bf63427c-1b17-4ec5-a909-a5f2d07d924c)
