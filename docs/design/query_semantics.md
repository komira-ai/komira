# Query semantics: what a plan's result must be

Status: **ruled.** The governing rule below was ruled by the maintainers on 2026-10-09, and every item is marked under it. The rulings, the parity gaps and the code that does not yet follow a rule are in [rulings, parity gaps and code status](query_semantics_rulings.md).

## The governing rule: same SQL, same result as DuckDB

The benchmarks run the same SQL on DuckDB and on komira, so komira's answer to a query is DuckDB's answer: the same rows, values, column types and column names. komira may differ in exactly three ways, and none is a different answer:

- **REPRESENTATION DEPARTURE.** Arrow has no type for DuckDB's result: no 128-bit integer (DuckDB's HUGEINT), no infinite DATE or TIMESTAMP, nothing to hold `uint64` mixed with a signed integer. komira uses the nearest Arrow type and fails by name where that type cannot hold DuckDB's value; an INT64 total that overflows is an error naming the column, never a wrapped number. This is the only reason a rule may depart from DuckDB; preferring another answer is not one.
- **PARITY GAP.** Something komira does not support yet (an operator, a clause, a function, a conversion) is refused by name until it is built, and once built it answers as DuckDB does. A gap is tracked as an issue, not recorded as a semantic choice.
- **EXTENSION.** A plan feature with no DuckDB SQL equivalent, so no query DuckDB accepts can reach it and there is no DuckDB answer to differ from. A SQL frontend gives it no spelling. There are two: §3.7's ASOF NEAREST and §13.10's declared non-nullable scan columns (a SQL frontend declares every scanned column nullable); §3.8's ASOF tolerance is one more, inside a PARITY GAP item. An extension's expectations are hand-derived from its item, and it is counted apart. A feature DuckDB's SQL can express is never an extension: komira either answers as DuckDB does or refuses it as a parity gap.

Everything else MATCHES: what komira answers is what DuckDB v1.5.6 answers, measured with the pinned oracle where an item says to measure. Where a plan operator or type differs from the SQL spelling (§5.1's division, §3.14's join output names, §11.4's implicit casts, §8.19's literal types), the SQL frontend lowers, aliases or types so that the SQL result is DuckDB's, and the item says how. In particular a SQL frontend types every literal as DuckDB does (§8.19): `2.5` is DECIMAL(2,1), not DOUBLE.

## What is it for, and what is out of scope?

This document states what a komira logical plan must return: how NULLs flow through logic, aggregates, joins and sorts; what arithmetic does at its edges; what casts and string functions mean; and the type of every result. It is the authority a hand-written test expectation cites. A conformance case whose expected value is derived by hand names the item it relies on (for example "§5.3"), never engine code: an expectation read off the code that produces the answer would let the engine grade itself.

The reference engine is **DuckDB v1.5.6** ([release tag](https://github.com/duckdb/duckdb/tree/v1.5.6)), pinned by exact version. The oracle runs it with:
- its defaults for `ieee_floating_point_ops` (true), `integer_division` (false), `default_null_order` (`NULLS_LAST`) and `preserve_insertion_order` (true);
- `threads = 1` and `TimeZone = 'UTC'`;
- every literal cast to the plan literal's type (§8.19).

A different DuckDB version is a pin change, reviewed as one. DuckDB 2.0 adds the setting `error_on_division_by_zero`, default true ([duckdb/duckdb#25332](https://github.com/duckdb/duckdb/pull/25332)); on 2.0 or later the oracle must `SET error_on_division_by_zero = false`, or §5.3 flips from NULL to an error.

DuckDB's documentation is cited by page title, in the form DuckDB documentation, "Text functions"; the pages are its `current` ones, which are the 1.5 documentation, since DuckDB publishes no versioned pages for its current release. The Sources list names every page cited. A statement resting on DuckDB's source cites the file at the v1.5.6 tag. Where both are silent, the statement quotes a measurement recorded in komira's source (taken on DuckDB 1.5.3) or says it is inferred, and the oracle re-measures it on v1.5.6; a disagreement is a defect in this document. pyarrow's compute functions are a second oracle for single-kernel cases; where pyarrow disagrees with DuckDB this document says which one the plan follows.

Each item has four parts:

- **Rule**: what a plan must return.
- **DuckDB** (and **pyarrow** where relevant): what the reference does.
- **Current behaviour**: what komira's code does today, cited as `file:line`. It is evidence, not authority: where it differs from the rule, the code is wrong ("Code that does not follow").
- **Mark**: one of
  - **MATCHES**: the rule is DuckDB's;
  - **REPRESENTATION DEPARTURE**: Arrow cannot hold DuckDB's type; the rule names the error komira raises in place of a different value;
  - **PARITY GAP**: komira refuses it by name today; once built, the rule is DuckDB's. The tracking issue is linked;
  - **EXTENSION**: a plan feature with no DuckDB SQL equivalent (the governing rule above).

Scope is the plan: the logical-plan IR (`src/komira_plan_ir`, `src/komira_plan_expr`) and its wire form (`src/komira_plan_wire`). A frontend (SQL, a dataframe API) maps its own surface onto these rules; where a frontend's spelling differs from the plan operator of the same name (SQL `/` against the plan's `BIN_DIV`), the item says so. Out of scope: collations other than binary, intervals, nested types (struct, list, map), JSON functions, the temporal field extracts beyond time zones and §8.15, and UDF null modes. Each of those needs its own section before a hand expectation may depend on it.

Items §7.16, §7.17 and §11.7 are in [further items](query_semantics_more.md) and section 13 (scans) is in [scans](query_semantics_scans.md), numbered as part of this document. Many operators named here have no executor in this repository yet (the engine operators arrive separately). Where that is so, "current behaviour" cites the IR, the wire admission or a kernel, and says that nothing executes the operator end to end.

## Rulings, parity gaps and code status

The rulings that settled each item once open or departing, the table of parity gaps with their issues and the benchmark queries they block, and the list of code that does not yet follow a settled rule, are in [rulings, parity gaps and code status](query_semantics_rulings.md). A reference to "Code that does not follow", item N, anywhere in this document means item N of that list.

## 1. Three-valued logic

### 1.1 AND, OR, NOT

- **Rule.** Kleene logic over {TRUE, FALSE, NULL}:

| a | b | a AND b | a OR b |
|---|---|---|---|
| TRUE | TRUE | TRUE | TRUE |
| TRUE | FALSE | FALSE | TRUE |
| TRUE | NULL | NULL | TRUE |
| FALSE | FALSE | FALSE | FALSE |
| FALSE | NULL | FALSE | NULL |
| NULL | NULL | NULL | NULL |

`NOT NULL` is NULL. AND and OR are commutative; the result does not depend on evaluation order.

- **DuckDB.** The same table (DuckDB documentation, "logical operators"). **pyarrow.** `and_kleene` / `or_kleene` follow this table; `and_` / `or_` propagate NULL instead and are not the oracle for this item ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).
- **Current behaviour.** `src/komira_kernels/kleene.mojo:15-22` states the table, and `:131-176` implements it on bitmap bytes.
- **Mark.** MATCHES.

### 1.2 Comparisons with NULL, and filters

- **Rule.** `=`, `<>`, `<`, `<=`, `>`, `>=` answer NULL when either operand is NULL, including `NULL = NULL`. A FILTER keeps a row only when its predicate is TRUE; FALSE and NULL both drop it.
- **DuckDB.** "Whenever either of the input arguments is NULL, the output of the comparison is NULL" (DuckDB documentation, "comparison operators", "NULL values").
- **Current behaviour.** A comparison result is valid only where both operands are valid (`src/komira_kernels/kleene.mojo:192-203`).
- **Mark.** MATCHES.

### 1.3 IS NULL, IS NOT NULL

- **Rule.** Both are total: never NULL, so their result type is a non-nullable BOOLEAN (§8.21). `x IS NULL` is TRUE exactly when `x` is NULL. A NaN is not NULL (§4.3).
- **DuckDB.** As stated (DuckDB documentation, "NULL values").
- **Current behaviour.** `src/komira_expr/runtime_expr_bool.mojo:766-800` returns an always-valid result from the validity bit, and the plan declares both non-nullable (`src/komira_plan_expr/expr_walk.mojo:1045-1052`).
- **Mark.** MATCHES.

### 1.4 IN with a NULL in the list, or a NULL on the left

- **Rule.** `x IN (v1, ..., vn)` is `x = v1 OR ... OR x = vn` under §1.1 and §1.2:
  - TRUE if some non-NULL `vi` equals `x`;
  - otherwise NULL if `x` is NULL or some `vi` is NULL;
  - otherwise FALSE.

  So `2 IN (1, NULL)` is NULL, `1 IN (1, NULL)` is TRUE, and `NULL IN (1, 2)` is NULL. The plan's IN_LIST is this tuple form.
- **DuckDB.** The same for a parenthesized list; DuckDB's *list* form `x IN [..]` ignores NULL members and is not what IN_LIST means (DuckDB documentation, "IN operator"). **pyarrow.** `is_in` with the default `skip_nulls=False` matches a NULL input to a NULL in the value set and never answers NULL, so it is not an oracle for this item ([SetLookupOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.SetLookupOptions.html)).
- **Current behaviour.** No IN_LIST evaluator is in this repository. The wire admits NULL members (`src/komira_plan_wire/plan_wire_values.mojo:1899-1906`), and its docstring describes the rule above for the engine's evaluator.
- **Mark.** MATCHES.

### 1.5 NOT IN

- **Rule.** `x NOT IN (...)` is `NOT (x IN (...))`. So a list containing NULL makes every non-matching row NULL, and a filter on it returns no such row.
- **DuckDB.** "`x NOT IN y` is equivalent to `NOT (x IN y)`" (DuckDB documentation, "IN operator").
- **Current behaviour.** As §1.4: no evaluator here. The subquery form is §3.3.
- **Mark.** MATCHES.

### 1.6 IS [NOT] DISTINCT FROM

- **Rule.** `a IS DISTINCT FROM b` is FALSE when both are NULL, TRUE when exactly one is NULL, and `a <> b` otherwise; it is never NULL. `IS NOT DISTINCT FROM` is its negation. The same null-safe equality is what an `IS NOT DISTINCT FROM` join key (§3.17) needs.
- **DuckDB.** As stated (DuckDB documentation, "comparison operators").
- **Current behaviour.** The plan has no operator for it: the binary operators are ADD SUB MUL DIV MOD, EQ NE LT LE GT GE, AND OR (`src/komira_plan_expr/expr.mojo:665-686`). The SQL parser refuses the spelling by name (`src/komira_sql/sql_parser.mojo:1863-1868`). As a value it can be desugared to `(a IS NULL AND b IS NULL) OR (a IS NOT NULL AND b IS NOT NULL AND a = b)`; a null-safe hash-join key cannot use that form and needs a plan operator.
- **Mark.** PARITY GAP ([komira#1218](https://github.com/komira-ai/komira/issues/1218)).

### 1.7 CASE with a NULL condition

- **Rule.** A `WHEN` whose condition is NULL is not taken; evaluation moves to the next `WHEN`, then to `ELSE`, and a missing `ELSE` answers NULL.
- **DuckDB.** Standard SQL `CASE`; the oracle confirms.
- **Current behaviour.** No CASE evaluator here. COALESCE is built as a CASE over `IS NOT NULL` conditions (`src/komira_plan_expr/scalar_desugar.mojo:84-111`).
- **Mark.** MATCHES.

### 1.8 NULLIF

- **Rule.** `NULLIF(a, b)` is `CASE WHEN a = b THEN NULL ELSE a END`: NULL when `a` equals `b`, otherwise `a`. Because a comparison with NULL is NULL (§1.2) and a NULL condition is not taken (§1.7), a NULL `a` gives NULL (that is, `a`) and a NULL `b` gives `a`. The result has `a`'s type and is nullable. The plan has no NULLIF node; a frontend builds this CASE with `BIN_EQ`. Over floats, `a = b` follows §4.5: DuckDB answers `NULLIF(NaN, NaN)` with NULL because its NaN equals NaN, while today's IEEE comparison kernels make the condition FALSE and answer NaN ("Code that does not follow", item 17).
- **DuckDB.** "Return NULL if a = b, else return a. Equivalent to CASE WHEN a = b THEN NULL ELSE a END" (DuckDB documentation, "utility functions").
- **Current behaviour.** The SQL function table records the same desugaring (`src/komira_sql/sql_fn_table.mojo:2948`); the binder that applies it is not in this repository.
- **Mark.** MATCHES.

## 2. NULLs in aggregates

### 2.1 NULL inputs are skipped; COUNT(*) is not COUNT(col)

- **Rule.** Every aggregate skips NULL inputs, except FIRST and LAST (§2.9). `COUNT(*)` counts rows; `COUNT(col)` counts rows where `col` is not NULL.
- **DuckDB.** "All general aggregate functions ignore NULLs, except for list (array_agg), first (arbitrary) and last" (DuckDB documentation, "aggregate functions"). **pyarrow.** `count` defaults to `mode="only_valid"`.
- **Current behaviour.** `src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:95-99` and `:1431-1437` skip NULL inputs.
- **Mark.** MATCHES.

### 2.2 All-NULL groups and empty groups

- **Rule.** Every aggregate except COUNT and COUNT(DISTINCT) is NULL over a group with no non-NULL input, whether the group is all-NULL or empty: SUM (not 0), AVG, MIN, MAX, the statistical aggregates (§2.11), and the holistic aggregates. The holistic aggregate the plan has is MEDIAN (§2.14); a quantile or MODE added later follows the same rule. COUNT is 0.
- **DuckDB.** "All general aggregate functions except count return NULL on empty groups ... sum does not return zero" (DuckDB documentation, "aggregate functions"). **pyarrow.** `sum` with its default `min_count=1` answers null.
- **Current behaviour.** The mixed fold emits NULL when the contributing count is 0 (`src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:96-99`, `:262-266`); MIN/MAX cells carry a `seen` flag (`src/komira_agg/builtin_agg_fns_minmax.mojo:39-45`); the MEDIAN accumulator answers NULL for an all-NULL group (`src/komira_op_agg_state/columnar_acc_agg.mojo:79`). The SUM cells in `komira_agg` do not: see "Code that does not follow", item 2.
- **Mark.** MATCHES.

### 2.3 Empty input

- **Rule.** An aggregate with no grouping keys over zero rows returns one row (COUNT 0, every other aggregate NULL). An aggregate with grouping keys over zero rows returns zero rows.
- **DuckDB.** Standard SQL; the oracle confirms.
- **Current behaviour.** No aggregate operator here exercises this end to end.
- **Mark.** MATCHES.

### 2.4 NULL grouping keys, and DISTINCT

- **Rule.** For grouping and for DISTINCT, NULL equals NULL: all rows whose key is NULL form one group, and DISTINCT keeps one NULL row. Multi-column keys compare column by column under the same rule.
- **DuckDB.** Standard SQL; not stated on the GROUP BY page. The oracle confirms.
- **Current behaviour.** The mixed fold declines a key column that holds NULLs rather than form the group differently from its sibling kernel (`src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:87-91`).
- **Mark.** MATCHES.

### 2.5 COUNT(DISTINCT col)

- **Rule.** Counts the distinct non-NULL values; NULL is not counted.
- **DuckDB.** "When the DISTINCT clause is provided, only distinct values are considered", and NULLs are ignored (DuckDB documentation, "aggregate functions").
- **Current behaviour.** `src/komira_agg_api/cd_distinct_key.mojo:234-263` reads the NULL mask beside the distinct keys so NULL rows are not counted.
- **Mark.** MATCHES.

### 2.6 Floating-point grouping keys

- **Rule.** As grouping and DISTINCT keys, all NaNs are one value and `-0.0` equals `+0.0`. Which bit pattern represents the group (`-0.0` or `+0.0`, which NaN payload) is not part of the result: tests compare floats under this equality, never by sign bit or payload.
- **DuckDB.** Measured on 1.5.3 and recorded in `src/komira_udf/float_quotient_order.mojo:29-36`: `GROUP BY v` over `{1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}` gives five groups, `{0.0, -0.0}` one of them and `{NaN, NaN}` another.
- **Current behaviour.** `src/komira_udf/float_quotient_order.mojo` is the one model, used by the hash and key-equality functions it lists at `:53-75`.
- **Mark.** MATCHES.

### 2.7 MIN and MAX over NaN

- **Rule.** NaN is greater than every other float, including +inf: MAX over a set containing NaN is NaN; MIN is NaN only if every input is NaN. The answer does not depend on input order or on how work is split between workers.
- **DuckDB.** "NaN compares equal to NaN and greater than any other floating point number" (DuckDB documentation, "numeric types").
- **Current behaviour.** `src/komira_agg/builtin_agg_fns_minmax.mojo:19-37`: the float cells compare through the float model, and the header records the order-dependent answers the bare comparison used to give.
- **Mark.** MATCHES.

### 2.8 MEDIAN and quantiles over NaN

- **Rule.** NaN takes part like any other value and sorts above +inf (§4.3). A group whose only non-NULL values are NaN answers NaN, not NULL.
- **DuckDB.** Includes NaN (the measurement is recorded at `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82`).
- **Current behaviour.** `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82` excludes NaN rows and answers NULL for an all-NaN group, and notes that DuckDB does not ("Code that does not follow", item 16).
- **Mark.** MATCHES.

### 2.9 FIRST, LAST, ANY_VALUE

- **Rule.** FIRST and LAST return the value of the first and last row of the group in input order, NULL included. ANY_VALUE returns the first non-NULL value. Without an order imposed below the aggregate, which row is first is not defined, so a test may assert these only over an input whose order the plan fixes.
- **DuckDB.** "first(arg): Returns the first value (null or non-null) from arg" (DuckDB documentation, "aggregate functions").
- **Current behaviour.** No evaluator for these is in this repository; the IR states the distinction between ANY_VALUE (first non-NULL) and FIRST (first row) at `src/komira_plan_expr/typed_schema.mojo:1272-1276`.
- **Mark.** MATCHES.

### 2.10 Floating-point SUM and AVG

- **Rule.** SUM and AVG of FLOAT/DOUBLE add in an unspecified order, so the last bits of the answer may differ between runs, worker counts and batch sizes. A test compares them with a tolerance stated in the case (relative or in units in the last place), never bit for bit. An integer SUM is exact (§8.1).
- **DuckDB.** Also order-dependent: its plain `sum` of DOUBLE is not compensated (`fsum`/`kahan_sum` are the compensated forms), and its parallel aggregation combines partial sums in a non-fixed order.
- **Current behaviour.** The plain float SUM cells are uncompensated (`src/komira_agg/builtin_agg_fns_states.mojo:123-127`).
- **Mark.** MATCHES.

### 2.11 Sample statistics of one row

- **Rule.** `stddev_samp` and `var_samp` (and `stddev`, `variance`) over a group with fewer than two non-NULL values are NULL. `stddev_pop` and `var_pop` over one value are 0; over none, NULL.
- **DuckDB.** The same (`extension/core_functions/include/core_functions/aggregate/algebraic/stddev.hpp:86-117` at v1.5.6).
- **Current behaviour.** The `komira_agg` cells answer NaN for one row ("Code that does not follow", item 7).
- **Mark.** MATCHES.

### 2.12 AVG of integers

- **Rule.** AVG of an integer column sums exactly (as §8.1 does) and divides once, in DOUBLE, at the end. It must not accumulate in DOUBLE: a BIGINT sum above 2^53 would lose digits before the division.
- **DuckDB.** Sums integers into a 128-bit accumulator, then divides (`extension/core_functions/aggregate/algebraic/avg.cpp` at v1.5.6).
- **Current behaviour.** The Float64 channel that carries integer aggregates in multi-aggregate shapes is exact only below 2^53 (`src/komira_kernels/runtime_expr.mojo:592-600`); which AVG routes use it is not established here.
- **Mark.** MATCHES.

### 2.13 BOOLEAN aggregates

- **Rule.** MIN and MAX of BOOLEAN order FALSE before TRUE and return BOOLEAN. SUM of BOOLEAN counts the TRUE values (its type is §8.1's). BOOL_AND and BOOL_OR skip NULLs and are NULL over a group with no non-NULL value.
- **DuckDB.** `sum(BOOLEAN)` exists (`extension/core_functions/aggregate/distributive/sum.cpp:163-164` at v1.5.6); `bool_and`/`bool_or` follow §2.1.
- **Current behaviour.** `sum(<BOOL>)` is typed INT64 and answers the count of non-NULL TRUEs (`src/komira_plan_ir/logical_plan.mojo:2431-2460`); BOOL_AND/BOOL_OR are BOOLEAN (`src/komira_plan_expr/agg_expr.mojo:245-253`).
- **Mark.** MATCHES.

### 2.14 MEDIAN at an even count

- **Rule.** MEDIAN is `quantile_cont(x, 0.5)` over the non-NULL values: with an odd count it is the middle value; with an even count it is the mean of the two middle values, even for an integer input, whose MEDIAN is FLOAT64 (§8.16), so `MEDIAN(1, 2)` is 1.5 and `MEDIAN(1, 2, 3, 4)` is 2.5. NaN takes part per §2.8. Between the two values `lo` and `hi` around the index, at fraction `d`, the answer is DuckDB's interpolation `lo + d * (hi - lo)`, computed in that order, so the extremes are DuckDB's too: a middle pair (+inf, +inf) gives NaN (`inf - inf`), and (-DBL_MAX, DBL_MAX) gives +inf (`hi - lo` overflows). A float answer is compared with §2.10's tolerance.
- **DuckDB.** "For even value counts, quantitative values are averaged and ordinal values return the lower value"; `quantile_cont` interpolates "between the adjacent values if the index is not an integer" (DuckDB documentation, "aggregate functions").
- **Current behaviour.** The IR defines MEDIAN as DuckDB's `quantile_cont(x, 0.5)` (`src/komira_plan_expr/agg_expr.mojo:38-40`); the accumulator interpolates `lower * (1 - frac) + upper * frac` at index `q * (n - 1)` (`src/komira_op_agg_state/columnar_acc_agg.mojo:63-71`, `:255`), not DuckDB's formula, so the extremes above answer inf and 0 ("Code that does not follow", item 26).
- **Mark.** MATCHES.

## 3. NULLs in joins

### 3.1 NULL keys never match in an equi-join

- **Rule.** In INNER, LEFT, RIGHT, FULL and SEMI joins, a row whose equi-join key has a NULL in any key column matches nothing. In an outer join such a row still appears once, padded (§3.4). HASH and SORT_MERGE give the same result for the same inputs.
- **DuckDB.** Follows from §1.2: the join condition is NULL, and NULL does not match (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** No join operator is in this repository; the join types and algorithms are declared at `src/komira_plan_ir/logical_plan.mojo:469-490`.
- **Mark.** MATCHES.

### 3.2 ANTI join is NOT EXISTS

- **Rule.** An ANTI join returns each left row that has no matching right row. A left row whose key is NULL matches nothing and is therefore returned; NULL keys on the right side match nothing and have no effect.
- **DuckDB.** "Anti joins provide the same logic as the NOT IN operator, except anti joins ignore NULL values from the right table" (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** A correlated `NOT EXISTS` lowers to `JOIN_ANTI` (`src/komira_plan_expr/corr_subquery_data.mojo:66-69`).
- **Mark.** MATCHES.

### 3.3 NOT IN over a subquery

- **Rule.** `x NOT IN (SELECT y ...)` follows §1.5, which is not an ANTI join:
  - if the subquery returns no rows, every row qualifies, including rows where `x` is NULL;
  - otherwise a row qualifies only if `x` is not NULL, no `y` equals `x`, and no `y` is NULL.

  So a single NULL in the subquery's result removes every row. A frontend builds this from an ANTI join plus the two NULL conditions; the plan has no separate null-aware anti join.
- **DuckDB.** Follows from §1.5 and the ANTI-join note in §3.2.
- **Current behaviour.** The SQL AST names the null-aware construction (`src/komira_sql/sql_ast.mojo:116`); the binder that builds it is not in this repository.
- **Mark.** MATCHES.

### 3.4 Outer-join padding

- **Rule.** An unmatched row of the preserved side appears once, with every column of the other side NULL. A padded NULL is indistinguishable from a NULL that was in the data.
- **DuckDB.** "When an unpaired row is returned, the attributes from the other table are set to NULL" (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** The gather kernels keep a zero fill under a `-1` (unmatched) index (`src/komira_join_assembly/compiler_join_assembly.mojo:1339-1342`); the validity of padded rows is the operator's, which is not here.
- **Mark.** MATCHES.

### 3.5 Residual predicates

- **Rule.** A residual (non-equi) join predicate that evaluates to NULL for a pair counts as no match, exactly like FALSE.
- **DuckDB.** Follows from §1.2.
- **Current behaviour.** No join operator here.
- **Mark.** MATCHES.

### 3.6 ASOF BACKWARD and FORWARD

- **Rule.** BACKWARD matches each left row with the right row of the same equality group whose ordering value is the greatest one `<=` the left row's; FORWARD with the least one `>=`. At most one right row matches. A NULL ordering value matches nothing. The plan has only these non-strict forms; tolerance and strict inequalities are §3.8.
- **DuckDB.** ASOF with `>=` (and `<=`) "joins each left side row with at most one right side row" (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** `src/komira_plan_ir/logical_plan.mojo:497-499` declares the directions.
- **Mark.** MATCHES.

### 3.7 ASOF NEAREST

- **Rule.** NEAREST matches the right row with the smallest `|left - right|`; on a tie between an earlier and a later row, the earlier (backward) row wins.
- **DuckDB.** No NEAREST direction. polars' `join_asof(strategy="nearest")` is the nearest external analogue, but this document does not adopt its tie rule without a measurement.
- **Current behaviour.** Declared at `src/komira_plan_ir/logical_plan.mojo:499`.
- **Mark.** EXTENSION: DuckDB has no NEAREST direction, so no DuckDB SQL reaches it. Expectations are hand-derived from this item.

### 3.8 ASOF tolerance, and strict inequalities

- **Rule.** An ASOF join may carry a tolerance (an INT64 or FLOAT64 bound on `|left - right|`); the bound is inclusive, so a candidate at exactly the tolerance matches (`src/komira_plan_ir/logical_plan.mojo:520`); a candidate outside it is no match, so in a LEFT ASOF join the right columns are NULL. The tolerance is an EXTENSION: DuckDB has no tolerance clause, so no DuckDB SQL reaches it. The strict forms `<` and `>` answer as DuckDB does; the plan has none yet, so a frontend refuses them by name.
- **DuckDB.** No tolerance clause, and it accepts `>`, `<` as well as `>=`, `<=` (DuckDB documentation, "FROM and JOIN"). A tolerance case is still checkable: the oracle runs a LEFT ASOF join and sets the right columns to NULL where `|left - right|` exceeds the bound.
- **Current behaviour.** `AsofTolerance` with NONE / INT64 / FLOAT64 (`src/komira_plan_ir/logical_plan.mojo:513-520`).
- **Mark.** PARITY GAP ([komira#1219](https://github.com/komira-ai/komira/issues/1219)): the strict forms. The tolerance is an extension (see the governing rule).

### 3.9 Floating-point equi-join keys

- **Rule.** As join keys, floats compare under §2.6's model: NaN equals NaN and `-0.0` equals `+0.0`, so such rows match. A NULL key still matches nothing (§3.1).
- **DuckDB.** Inferred from its float equality (`NaN = NaN` is TRUE, DuckDB documentation, "numeric types") and from the hash join comparing keys with the same equality; the oracle measures it.
- **Current behaviour.** No join operator here; the float model lists the join-key and hash functions that use it (`src/komira_udf/float_quotient_order.mojo:53-75`).
- **Mark.** MATCHES.

### 3.10 Equi-join multiplicity

- **Rule.** INNER, LEFT, RIGHT and FULL joins emit one row per matching pair: `k` left rows and `m` right rows with equal keys give `k · m` rows. An unmatched row of a preserved side adds one padded row (§3.4). Duplicate keys are never collapsed.
- **DuckDB.** The join of a left row with each matching right row (DuckDB documentation, "FROM and JOIN"); standard SQL.
- **Current behaviour.** No join operator here.
- **Mark.** MATCHES.

### 3.11 SEMI join output

- **Rule.** A SEMI join returns each left row **at most once**, however many right rows match it, and outputs the left columns only, in the left order of columns.
- **DuckDB.** "Semi joins return rows from the left table that have at least one match in the right table" (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** `LogicalPlan.join` gives SEMI the left schema only (`src/komira_plan_ir/logical_plan.mojo:1234-1235`, `:1261-1262`).
- **Mark.** MATCHES.

### 3.12 ANTI join output

- **Rule.** An ANTI join returns each left row that has no match, once, and outputs the left columns only. NULL keys follow §3.2.
- **DuckDB.** "Anti joins return rows from the left table that have no matches in the right table" (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** As §3.11 (`src/komira_plan_ir/logical_plan.mojo:1234-1235`).
- **Mark.** MATCHES.

### 3.13 Output columns of INNER, LEFT, RIGHT, FULL and CROSS joins

- **Rule.** The output is every left column in the left input's order, then every right column in the right input's order. Both sides' key columns are kept (there is no `USING` merge of keys in the plan; a frontend that wants one projects it). The columns of a side that is padded (the right side of LEFT, the left side of RIGHT, both of FULL) are nullable whatever their input nullability. A CROSS join has the same columns, left then right, and pads nothing, so each column keeps its input nullability; it emits every pair of rows, so a CROSS join with an empty side has zero rows (§11.6). Name collisions are §3.14.
- **DuckDB.** `SELECT *` over `l JOIN r ON ...` lists `l`'s columns then `r`'s, both key columns included; `USING` and `NATURAL` merge the keys. `CROSS JOIN` returns all pairs of rows, with the same left-then-right columns (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** `LogicalPlan.join` builds left then right for every join type except SEMI and ANTI, CROSS (`JOIN_CROSS`, `:475`) included (`src/komira_plan_ir/logical_plan.mojo:1255-1273`), but keeps each side's input nullability, so a padded column can be declared non-nullable ("Code that does not follow", item 12). The ASOF builder forces the right side nullable (`:1500-1502`).
- **Mark.** MATCHES.

### 3.14 Name collisions in join output

- **Rule.** A SQL query's output names are DuckDB's: `SELECT *` over a join keeps a repeated name as it is (`k`, `k`), which an Arrow schema can hold. A SQL frontend that needs unique names inside the plan aliases the inputs and renames the output back, so the SQL result's names are the ones DuckDB returns. Inside the plan, output names are unique, compared case-sensitively: a right column whose name equals a left column's is renamed `<name>_right`, and left names are never changed. If `<name>_right` is itself taken by any left **or** right column (for example a left `a` with a right side holding both `a` and `a_right`), the plan refuses the join by name; a frontend renames or projects first. `_right` is the convention of the dataframe surfaces (polars uses it), which have no DuckDB SQL to match.
- **DuckDB.** SQL `SELECT *` keeps duplicate names (`k` and `k`). DuckDB renames repeats `<name>_<n>` where it must store or return unique names: `QueryResult::DeduplicateColumns` (`src/main/query_result.cpp:71-93` at v1.5.6) and `ColumnList::AddToNameMap` when `allow_duplicate_names` is set (`src/parser/column_list.cpp:38-51`). Its name comparison is case-insensitive. An oracle query over a plan built without a SQL frontend aliases every output column explicitly, so the names are the plan's.
- **Current behaviour.** `src/komira_plan_ir/logical_plan.mojo:1263-1273` appends `_right` (ASOF: `:1490-1501`), comparing names case-sensitively (`==` on the strings) and only against left names, so a second collision produces duplicate names ("Code that does not follow", item 12).
- **Mark.** MATCHES: at the SQL surface, through the frontend's aliasing; `_right` is internal to the plan and the dataframe surfaces.

### 3.15 EXISTS and NOT EXISTS

- **Rule.** Where a correlated `EXISTS` or `NOT EXISTS` is a top-level AND conjunct of a filter, it is a SEMI join (§3.11) or ANTI join (§3.12). Equality correlation predicates become the join keys; any other correlation predicate becomes the join's residual (§3.5), not a key. A left row with a NULL correlation key has no match, so EXISTS is FALSE and NOT EXISTS TRUE for it. In this position neither produces an output column. Every other position is §3.16.
- **DuckDB.** Anti joins have the logic of NOT EXISTS, not of NOT IN (§3.2, DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** `src/komira_plan_expr/corr_subquery_data.mojo:66-69`.
- **Mark.** MATCHES.

### 3.16 EXISTS outside a filter conjunct

- **Rule.** `EXISTS` and `NOT EXISTS` in any other position (a SELECT-list value, under OR or NOT, inside CASE, compared with a value) answer as DuckDB does: a non-nullable BOOLEAN per row. The plan has no MARK join, the join that yields that BOOLEAN, so until it has one a frontend refuses these positions by name. When a MARK join is added, EXISTS as a value gets a row in §8.
- **DuckDB.** Evaluates these positions with a MARK join, giving a non-nullable BOOLEAN.
- **Current behaviour.** The plan's correlated-subquery kinds lower to SEMI and ANTI joins only (`src/komira_plan_expr/corr_subquery_data.mojo:66-69`).
- **Mark.** PARITY GAP ([komira#1220](https://github.com/komira-ai/komira/issues/1220)).

### 3.17 ASOF equality keys and NULL

- **Rule.** An ASOF join's equality keys are equi-join keys: a left row whose equality key holds a NULL matches nothing (§3.1), and so does a NULL ASOF key (§3.6). In a LEFT ASOF join such a row appears once with the right columns NULL. The plan's ASOF equality keys are `=` only: DuckDB also accepts `IS NOT DISTINCT FROM` keys, which do match NULL to NULL, but the plan has no such key (§1.6), so a frontend refuses one by name.
- **DuckDB.** The conditions other than the inequality "must be equalities (or NOT DISTINCT)"; an equality with NULL is not TRUE (§1.2), so it does not match (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** The IR carries `left_keys` / `right_keys` as equi-keys (`src/komira_plan_ir/logical_plan.mojo:1472-1474`); no ASOF operator is in this repository.
- **Mark.** MATCHES.

### 3.18 ASOF without equality keys

- **Rule.** An ASOF join with no equality keys treats all right rows as one group: each left row is matched against every right row by the ASOF key alone.
- **DuckDB.** An ASOF join whose only condition is the inequality matches across the whole right table (DuckDB documentation, "FROM and JOIN").
- **Current behaviour.** "`by=[]` → single-group semantics" (`src/komira_plan_ir/logical_plan.mojo:499`).
- **Mark.** MATCHES.

### 3.19 Right rows tied on the ASOF key

- **Rule.** When two or more right rows in one group have the same ASOF key and that key is the best match, the row returned is the one DuckDB returns, measured with the oracle. If the measurement shows DuckDB's choice depends on input order, any one of the tied rows is a correct answer and a test compares such rows as either answer; komira's answer must still not depend on its own worker count. Until the oracle has measured it, oracle cases keep ASOF keys unique within each equality group.
- **DuckDB.** "ASOF joins each left side row with at most one right side row"; which of several tied rows is not documented.
- **Current behaviour.** BACKWARD is described as "last right row with right.ts <= left.ts" (`src/komira_plan_ir/logical_plan.mojo:502`), which does not say which of two tied rows is last.
- **Mark.** MATCHES.

## 4. Sort order and floating-point order

### 4.1 Default NULL placement

- **Rule.** Where a sort key does not state a placement, NULLs sort **last in both directions**. This applies to SORT, TOPN, PARTITION_TOPN and the ORDER BY of a window.
- **DuckDB.** "DuckDB keeps NULLS LAST even for DESC ordering, whereas PostgreSQL places NULLs first on DESC" (DuckDB documentation, "ORDER BY"); `default_null_order` defaults to `NULLS_LAST` (DuckDB documentation, "configuration"). **pyarrow.** `sort_indices` puts nulls at the end by default ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).
- **Current behaviour.** `src/komira_plan_expr/null_order_policy.mojo:41-48` records the measurement against DuckDB 1.5.3 and pyarrow 24.0.0, and `derived_nulls_first` (`:80-93`) returns False for both directions.
- **Mark.** MATCHES.

### 4.2 Explicit NULL placement

- **Rule.** A sort key that states NULLS FIRST or NULLS LAST is sorted that way, whatever its direction. The plan carries the request per key (`SortData.nulls_first`, `TopNData.nulls_first`).
- **DuckDB.** `ORDER BY ... NULLS FIRST | NULLS LAST` (DuckDB documentation, "ORDER BY").
- **Current behaviour.** `src/komira_plan_expr/null_order_policy.mojo:63-69`: the default is consulted only where nobody asked.
- **Mark.** MATCHES.

### 4.3 NaN in a sort

- **Rule.** NaN is a value, not NULL. Ascending, NaN sorts after +inf; descending, before +inf. All NaNs tie. NULL placement (§4.1, §4.2) is independent of NaN: under NULLS LAST an ascending sort ends `..., +inf, NaN, NULL`.
- **DuckDB.** "NaN compares equal to NaN and greater than any other floating point number" (DuckDB documentation, "numeric types"). **pyarrow.** "NaN values are considered greater than any other non-null value, but smaller than nulls" ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).
- **Current behaviour.** The sort and top-N kernels use the float model (`src/komira_udf/float_quotient_order.mojo:68-70`); the sort operators themselves are not here.
- **Mark.** MATCHES.

### 4.4 Negative zero

- **Rule.** `-0.0` and `+0.0` tie in a sort and are equal as keys (§2.6). Their relative order after a sort is not promised. What a sort returns for a `-0.0` key value is §4.9.
- **DuckDB.** Not documented. Measured on 1.5.3 (`src/komira_udf/float_quotient_order.mojo:32-35`): `0.0 = -0.0` is TRUE and the two tie in ORDER BY.
- **Current behaviour.** As §2.6.
- **Mark.** MATCHES.

### 4.5 NaN in comparison predicates

- **Rule.** The comparison operators use DuckDB's model, the one sorting and grouping use: `NaN = NaN` is TRUE, `NaN <> NaN` is FALSE, and `NaN > x` is TRUE for every non-NaN `x`, including +inf. So `WHERE v = v` keeps NaN rows, as `GROUP BY v` keeps them in one group, and a filter `v > 1e308` agrees with `ORDER BY v` about where NaN is.
- **DuckDB.** As stated (DuckDB documentation, "numeric types").
- **Current behaviour.** The comparison kernels are IEEE: every ordered comparison with a NaN operand is FALSE and `NaN <> x` is TRUE. `src/komira_column_kernels/comparison.mojo:316-325` records this as a known divergence from DuckDB, PostgreSQL and Spark SQL ("Code that does not follow", item 17).
- **Mark.** MATCHES.

### 4.6 String order

- **Rule.** Strings sort by their UTF-8 bytes (binary collation). Binary values sort by bytes. A shorter string that is a prefix of a longer one sorts first.
- **DuckDB.** "Text is sorted using the binary comparison collation by default, which means values are sorted on their binary UTF-8 values" (DuckDB documentation, "ORDER BY").
- **Current behaviour.** The string sort kernels are not here.
- **Mark.** MATCHES.

### 4.7 Stability

- **Rule.** No sort is stable. Rows that tie on every sort key come out in an unspecified order, which may differ between runs, worker counts and batch sizes. TOPN and LIMIT over a sort with ties may return any of the tied rows at the boundary. A test either sorts on a total key or compares tied rows as a set.
- **DuckDB.** Does not document a stable sort. **pyarrow.** `sort_indices` is stable ("define a stable sort of the input", [compute functions](https://arrow.apache.org/docs/cpp/compute.html)); an expectation must not rely on that.
- **Current behaviour.** The row-format sort is stable (`src/komira_row_format/row_sort_perm.mojo:28-31`), but no plan-level guarantee is built on it.
- **Mark.** MATCHES.

### 4.8 Result order without ORDER BY

- **Rule.** A plan without a SORT (or TOPN) at its root promises no row order. Its result is compared as a multiset of rows. LIMIT without a sort below it returns any `n` rows of its input, and a test asserts only the count and that each row belongs to the input, or sorts first.
- **DuckDB.** Preserves order for some operators (a single-table scan, WHERE, LIMIT, UNION ALL) under `preserve_insertion_order`, and not for GROUP BY, joins, UNION or aggregates (DuckDB documentation, "order preservation"). The oracle's `threads = 1` and `preserve_insertion_order = true` make its own output repeatable; they do not make order part of the plan's contract.
- **Current behaviour.** Nothing in the plan IR claims an order for an unsorted plan.
- **Mark.** MATCHES.

### 4.9 Zeros and NaNs in a sorted column

- **Rule.** SORT, TOPN, PARTITION_TOPN and a window's ORDER BY reorder rows and return the values DuckDB returns. A float column that is itself a sort key comes back with each `-0.0` as `0.0`; a float column carried but not sorted on keeps its `-0.0`. Every other value, a NaN's payload included, comes back unchanged. §4.4's tie rule is unaffected.
- **DuckDB.** In v1.5.6, when a float column is itself an ORDER BY key, a `-0.0` in it comes back as `0.0`; where the same column is carried but not sorted on, `-0.0` survives (measured by the oracle work with the pinned 1.5.6 wheel).
- **Current behaviour.** `canonicalize_f32` / `canonicalize_f64` produce the image used for hashing and equality (`src/komira_udf/float_quotient_order.mojo:121-140`), and the file states that the engine keeps a value's first-seen bit pattern (`:46-49`). The sort operators are not in this repository, so nothing yet returns a sorted `-0.0` either way; a sort operator must write the sorted key column's zeros as `0.0`.
- **Mark.** MATCHES.

## 5. Arithmetic

### 5.0 NULL operands

- **Rule.** Every arithmetic operator (`+`, `-`, `*`, `BIN_DIV`, `BIN_MOD`, unary minus), over integers, DECIMALs or floats, answers NULL when any operand is NULL, whatever the other operand holds (a NaN, a zero divisor, or a value that would overflow). The NULL check comes first: `NULL / 0` is NULL, not §5.3's or §5.6's answer, and `NULL + MAX` raises no overflow (§5.5).
- **DuckDB.** "A function that has an input argument as NULL usually returns NULL"; arithmetic operators are among those that do (DuckDB documentation, "NULL values").
- **Current behaviour.** The column kernels give a result row validity only where both operands are valid (`src/komira_column_kernels/compiler_helpers.mojo:2860-2880`), and the guarded division skips NULL rows before testing the divisor (`src/komira_column_kernels/arithmetic.mojo:660-670`).
- **Mark.** MATCHES.

### 5.1 The plan's division operator on integers

- **Rule.** `BIN_DIV` over two integer operands is integer division that truncates toward zero, and its result is an integer (§8.9): `7 / 2` is 3 and `-7 / 2` is -3. This is DuckDB's `//`. A frontend whose `/` means true division (SQL, DuckDB, polars) casts the left operand to DOUBLE before building `BIN_DIV`. A frontend whose `//` floors (polars, pandas, Python: `-7 // 2` is -4) builds that from `BIN_DIV` and a correction, not from `BIN_DIV` alone. Over float operands `BIN_DIV` is IEEE division.
- **DuckDB.** `/` is floating-point division (`5 / 2 = 2.5`) and `//` is integer division (DuckDB documentation, "numeric functions"). The sign of `//` for negative operands is not documented; measured on 1.5.3, `-7 // 2` is -3 (`src/komira_plan_expr/col_expr_division.mojo:5-17`).
- **Current behaviour.** The column kernel divides with Mojo's integer `/`, which truncates (`src/komira_column_kernels/arithmetic.mojo:675`); its header records the result-type divergence from DuckDB's `/` as deliberate (`:83-88`). The Mojo dataframe surface decides `/` against `//` in one place (`src/komira_plan_expr/col_expr_division.mojo:28-35`). The expression executor (`src/komira_eval/expression_executor.mojo`) also truncates: its integer walkers through `_ee_div_trunc`, and its Float64 walker's `EXPR_DIV_I64` arm by truncating the widened quotient (exact below 2^53). Expression template 8 floors ("Code that does not follow", item 1).
- **Mark.** MATCHES: at the SQL surface. The plan has one division operator, DuckDB's `//`; a SQL frontend lowers `/` to a DOUBLE division and `//` to `BIN_DIV`, so a SQL query's result is DuckDB's for both spellings.

### 5.2 Modulo sign

- **Rule.** `BIN_MOD` is the truncated remainder: its sign is the dividend's. `-7 % 2` is -1 and `7 % -2` is 1. `a = (a / b) * b + (a % b)` holds with §5.1's division.
- **DuckDB.** Not documented; measured on 1.5.3, `-7 % 2` is -1 (`src/komira_plan_expr/col_expr.mojo:852-856`). polars and Python floor instead (`-7 % 2` is 1).
- **Current behaviour.** No `BIN_MOD` column kernel is in this repository; the IR states the rule (`src/komira_plan_expr/col_expr.mojo:852-856`).
- **Mark.** MATCHES.

### 5.3 Integer division or modulo by zero

- **Rule.** An integer `BIN_DIV` or `BIN_MOD` whose divisor is zero answers NULL for that row. Other rows keep their values. No error is raised.
- **DuckDB.** Measured on 1.5.3 (`src/komira_column_kernels/arithmetic.mojo:74-78`): `qty // 0` and `qty % 0` are NULL. This holds through 1.5; on 2.0 the oracle sets `error_on_division_by_zero = false` (see the oracle settings). **pyarrow.** `divide` on integers raises on a zero divisor; it is not the oracle for this item.
- **Current behaviour.** `src/komira_column_kernels/arithmetic.mojo:572-580` and `:615-676` answer NULL per row. The expression executor's integer walkers raise instead, and its Float64 walker answers +-Inf or NaN ("Code that does not follow", item 1).
- **Mark.** MATCHES.

### 5.4 Signed MIN divided by -1

- **Rule.** `MIN / -1` for a signed integer type is an error ("Out of Range"), since the quotient is not representable.
- **DuckDB.** Measured on 1.5.3: `(-9223372036854775808) // (-1)` raises an Out of Range Error (`src/komira_column_kernels/arithmetic.mojo:74-80`).
- **Current behaviour.** `src/komira_column_kernels/arithmetic.mojo:111-130` raises when both operands of such a pair are valid.
- **Mark.** MATCHES.

### 5.5 Integer overflow

- **Rule.** Integer `+`, `-`, `*` and unary minus whose exact result does not fit the result type (§8.9) raise an error naming the operation, never wrap and never saturate.
- **DuckDB.** "Attempts to store values outside of the allowed range will result in an error" (DuckDB documentation, "numeric types"); measured on 1.5.3: `Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!` (`src/komira_scalar_arithmetic/int_overflow.mojo:11-17`). **pyarrow.** `add`, `subtract`, `multiply` wrap; only the `_checked` variants raise ([compute API](https://arrow.apache.org/docs/python/api/compute.html)). An oracle case uses the `_checked` variants or DuckDB.
- **Current behaviour.** `src/komira_scalar_arithmetic/int_overflow.mojo:1-25` is the one predicate; the column kernels raise (`src/komira_column_kernels/arithmetic.mojo:685-690`).
- **Mark.** MATCHES.

### 5.6 Float division by zero

- **Rule.** Float division by zero follows IEEE 754: `x / 0.0` is +inf or -inf by the signs of `x` and the zero, and `0.0 / 0.0` is NaN. No NULL and no error.
- **DuckDB.** `ieee_floating_point_ops` (default true): "Use IEE754-compliant floating point operations (returning NAN instead of errors/NULL)" (DuckDB documentation, "configuration").
- **Current behaviour.** The float path is IEEE and unguarded (`src/komira_column_kernels/arithmetic.mojo:65-70`).
- **Mark.** MATCHES.

### 5.7 NaN and infinity propagation

- **Rule.** Float arithmetic is IEEE 754: an operation with a NaN operand is NaN, `inf - inf` and `0 * inf` are NaN, and `inf + x` is inf for finite `x`. An arithmetic operation with a NULL operand is NULL whatever the other operand is (NULL dominates NaN).
- **DuckDB.** As above, under `ieee_floating_point_ops`.
- **Current behaviour.** The float kernels are bare IEEE operations; validity is the AND of the operands' (`src/komira_column_kernels/compiler_helpers.mojo:2860-2880`).
- **Mark.** MATCHES.

### 5.8 Signed MIN modulo -1

- **Rule.** `MIN % -1` for a signed integer type is 0, not an error (the remainder is representable even though §5.4's quotient is not).
- **DuckDB.** Answers 0 (inferred from its modulo kernel; the oracle measures it).
- **Current behaviour.** No `BIN_MOD` column kernel here; a kernel computing `a - (a / b) * b` must not compute the overflowing quotient first.
- **Mark.** MATCHES.

### 5.9 Float modulo

- **Rule.** `BIN_MOD` over FLOAT/DOUBLE is C's `fmod`: the result has the dividend's sign (`-7.5 % 2` is -1.5), `x % 0.0` is NaN, `x % inf` is `x` for finite `x`, and a NaN or infinite dividend gives NaN.
- **DuckDB.** `ModuloOperator` uses `std::fmod` for FLOAT and DOUBLE (`src/function/scalar/operator/arithmetic.cpp:1135-1145` at v1.5.6).
- **Current behaviour.** No float `BIN_MOD` kernel here.
- **Mark.** MATCHES.

### 5.10 DECIMAL modulo and division by zero

- **Rule.** `BIN_MOD` of DECIMAL(p1, s1) and DECIMAL(p2, s2) is DECIMAL(max(p1 - s1, p2 - s2) + max(s1, s2), max(s1, s2)); if that precision exceeds 38, both operands are cast to DOUBLE and the result is DOUBLE (§5.9). A zero divisor answers NULL for that row, as §5.3 does for integers. DECIMAL `/` is FLOAT64 (§8.13), so its zero divisor follows §5.6.
- **DuckDB.** `BindDecimalModulo` computes that type through `BindDecimalArithmetic` with no `+ 1`, falls back to DOUBLE when it does not fit, and executes through `GetBinaryFunctionIgnoreZero`, which answers NULL for a zero divisor (`src/function/scalar/operator/arithmetic.cpp:193-245` and `:1118-1132` at v1.5.6).
- **Current behaviour.** The plan types DECIMAL `%` with the **left** operand's precision and scale (`src/komira_plan_expr/expr_walk.mojo:896-901`), which cannot hold `5.0 % 0.33` = `0.05` (5.0 − 15 × 0.33) at scale 1; no DECIMAL `%` kernel is here ("Code that does not follow", item 9).
- **Mark.** MATCHES.

## 6. Casts

### 6.1 Strict casts and TRY_CAST

- **Rule.** A CAST whose input cannot be represented in the target type, or cannot be parsed, raises an error. TRY_CAST answers NULL for that row instead, and is therefore always nullable. A NULL input casts to NULL under both.
- **DuckDB.** A failed cast "throws an error by default"; `TRY_CAST` converts failures to NULL (DuckDB documentation, "typecasting").
- **Current behaviour.** `CastData.try_cast` selects the mode (`src/komira_plan_expr/expr.mojo:1638-1651`); a TRY_CAST result is typed nullable (`src/komira_plan_expr/expr_walk.mojo:1096-1114`).
- **Mark.** MATCHES.

### 6.2 Integer to narrower integer

- **Rule.** A value outside the target's range is an error (NULL under TRY_CAST). It is never truncated to its low bits.
- **DuckDB.** "Type INT32 with value 999 can't be cast because the value is out of range for the destination type INT8" (DuckDB documentation, "typecasting").
- **Current behaviour.** Two casts wrap ("Code that does not follow", item 4).
- **Mark.** MATCHES.

### 6.3 Float to integer

- **Rule.** A FLOAT or DOUBLE casts to an integer in two steps. First the **unrounded** value must lie in `[MIN, MAX + 1)` of the target type, otherwise the cast is an error; NaN and ±inf are errors. Then it rounds **half to even** (2.5 to 2, 3.5 to 4, -2.5 to -2). So `CAST(-2147483648.4 AS INTEGER)` is an error although it would round to INT32_MIN, and `CAST(-0.4 AS UTINYINT)` is an error although it would round to 0.
- **DuckDB.** "Casting from FLOAT and DOUBLE to integers of any size: round to the nearest integer, with ties (halfs) rounded to the nearest even number" (DuckDB documentation, "numeric types"). `TryCastWithOverflowCheckFloat` checks `value >= min && value < max` on the unrounded value and then calls `nearbyint` (`src/include/duckdb/common/operator/numeric_cast.hpp:75-85` at v1.5.6). A bare literal such as `2.5` is a DECIMAL in DuckDB and follows §6.4, so oracle SQL casts it to DOUBLE first (§8.19). **pyarrow.** A safe cast refuses a non-integral float; it is not the oracle.
- **Oracle cases exclude one band.** A value in `[MAX + 0.5, MAX + 1)` passes the check and rounds to `MAX + 1`, which DuckDB's `static_cast` leaves undefined (its answer differs by platform). Cases do not use that band. The lower edge is defined: values below MIN are errors in both engines.
- **Current behaviour.** `src/komira_column_kernels/cast_null.mojo:217-290` checks the unrounded value against the same window before rounding, as DuckDB does, for signed targets (its window for an unsigned target is empty; see "Code that does not follow"), and clamps the undefined band to MAX (`:257-270`). One other path truncates ("Code that does not follow", item 3).
- **Mark.** MATCHES.

### 6.4 Decimal to integer, and float to decimal

- **Rule.** DECIMAL to integer rounds half away from zero (`-2.5` to -3). FLOAT or DOUBLE to DECIMAL rounds half away from zero at the target scale. Out of range is an error.
- **DuckDB.** Measured on 1.5.3 (`src/komira_scalar_arithmetic/decimal_cast.mojo:6-16`).
- **Current behaviour.** `src/komira_scalar_arithmetic/decimal_cast.mojo:77-105` and `:126-131`.
- **Mark.** MATCHES.

### 6.5 DOUBLE to FLOAT

- **Rule.** A finite DOUBLE whose FLOAT rounding is infinite is an error. A value just above the FLOAT maximum that rounds down to it is accepted. ±inf and NaN carry over.
- **DuckDB.** Measured on 1.5.3 (`src/komira_column_kernels/cast_null.mojo:60-80`).
- **Current behaviour.** `eval_cast_f64_to_f32_checked` (`src/komira_column_kernels/cast_null.mojo:97`).
- **Mark.** MATCHES.

### 6.6 String to integer: the grammar

- **Rule.** DuckDB's grammar: leading and trailing ASCII whitespace is ignored; an optional `+` or `-` sign; decimal digits, leading zeros allowed; and each of DuckDB's extensions below. An empty or all-whitespace string, any other character, or a value out of range is an error (NULL under TRY_CAST).
- **DuckDB.** `src/include/duckdb/common/operator/integer_cast_operator.hpp` at v1.5.6 also accepts:
  - a fractional part, rounded on its first digit away from zero: `'1.5'` is 2, `'-1.5'` is -2, `'1.4'` is 1;
  - an exponent: `'1e2'` is 100;
  - underscores between digits: `'1_000'` is 1000;
  - hexadecimal and binary prefixes: `'0x1F'` is 31, `'0b101'` is 5.

  The oracle measures each before a case relies on it.
- **Current behaviour.** `src/komira_kernels/cast_to_varchar_kernels.mojo:40-50` accepts only the strict grammar and rejects every DuckDB extension above, including `'1e2'` ("Code that does not follow", item 18).
- **Mark.** MATCHES.

### 6.7 String to double out of range

- **Rule.** A string whose value is finite but outside DOUBLE's range (`'1e400'`) answers what DuckDB answers, measured by the oracle; the expected answer is an error, as for an integer out of range. `'inf'`, `'infinity'`, `'nan'` (any case, with an optional sign) parse to those values.
- **DuckDB.** Not documented. Likely a Conversion Error (inferred, not measured); the oracle measures it.
- **Current behaviour.** Saturates to ±inf (`src/komira_kernels/cast_to_varchar_kernels.mojo:48`); accepts the special spellings (`:47`). "Code that does not follow", item 19, unless the oracle shows DuckDB saturates too.
- **Mark.** MATCHES.

### 6.8 Timestamp units

- **Rule.** The plan carries Arrow's four timestamp units (seconds, milliseconds, microseconds, nanoseconds), and DATE32 as days. Casting to a finer unit is exact or an error if out of range. Casting to a coarser unit rounds as DuckDB does, measured by the oracle on an instant before the Unix epoch with a sub-unit part (truncation toward zero, or toward negative infinity: the measurement decides).
- **DuckDB.** `TIMESTAMP` is microseconds; `TIMESTAMP_S`, `TIMESTAMP_MS` and `TIMESTAMP_NS` are the other units (DuckDB documentation, "timestamp types"). The direction of rounding before the Unix epoch is not documented.
- **Current behaviour.** The field extracts accept all four units (`src/komira_kernels/temporal_extract.mojo:6-8`, `:1152`). No unit-changing timestamp cast kernel is in this repository.
- **Mark.** MATCHES.

### 6.9 Time zones

- **Rule.** DuckDB's, with `TimeZone = 'UTC'`. A timestamp with a time zone is an instant (UTC ticks), and the zone is metadata on the column type. A timestamp without one is a wall-clock reading with no zone. There is one session time zone and it is UTC: field extraction (`year`, `hour`, ...) and `date_trunc` over a zoned timestamp operate on the UTC wall clock. Comparison and join of two zoned timestamps compare instants, whatever their zones. Mixing zoned and unzoned is §6.11.
- **DuckDB.** `TIMESTAMPTZ` stores "the INT64 number of non-leap microseconds since the Unix epoch"; extraction and rendering use the session `TimeZone` setting, which defaults to the system zone (DuckDB documentation, "timestamp types", "configuration"). With `TimeZone = 'UTC'`, DuckDB answers as stated.
- **Current behaviour.** The zone travels on the field (`src/komira_kernels/join_key_envelope.mojo:319-330`; aliases keep it, `src/komira_plan_expr/expr_walk.mojo:740-750`). The extract kernels take no zone (`src/komira_kernels/temporal_extract.mojo:1152`), so they already answer in UTC.
- **Mark.** MATCHES.

### 6.10 CAST_TO_VARCHAR rendering

`PLAN_CAST_TO_VARCHAR` turns every column of a result into text before a text sink (CSV, JSON Lines) writes it (`src/komira_plan_ir/logical_plan.mojo:138-152`). Its rendering is what those files contain.

- **Rule.** Each type renders as DuckDB's `CAST(x AS VARCHAR)`; the oracle measures every float and decimal spelling, and each row is tested with one case:

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

- **DuckDB.** "Any type can be cast to VARCHAR" (DuckDB documentation, "typecasting"); the ISO 8601 shape of timestamps and the offset rendering of zoned ones are documented (DuckDB documentation, "timestamp types"). The float and decimal spellings in the table are not documented and must be measured. **pyarrow.** `cast(double, string)` renders 1.0 as `1`; not followed.
- **Current behaviour.** Integers, booleans and strings render as in the table (`src/komira_kernels/cast_to_varchar_kernels.mojo:9-50`). Floats render with Mojo's `String(Float64)` (`:316-322`), which has not been compared with DuckDB. No DECIMAL, DATE or TIMESTAMP rendering kernel is in this repository.
- **Mark.** MATCHES.

### 6.11 Mixing zoned and unzoned timestamps

- **Rule.** As DuckDB with `TimeZone = 'UTC'`: comparing, joining or combining (CASE, UNION) a zoned timestamp with an unzoned one converts between the two through the session zone. komira does not convert yet, so the mixed forms are refused by name until it does; a frontend may cast one side explicitly.
- **DuckDB.** Converts implicitly between TIMESTAMP and TIMESTAMPTZ through the session `TimeZone` (DuckDB documentation, "timestamp types").
- **Current behaviour.** No such comparison kernel here.
- **Mark.** PARITY GAP ([komira#1221](https://github.com/komira-ai/komira/issues/1221)).

## 7. Strings

### 7.1 Length

- **Rule.** `length(s)` counts Unicode code points; `strlen(s)` counts bytes; `bit_length(s)` is 8 times `strlen(s)`. All three are INT64, and NULL for a NULL input. Grapheme-cluster counts are not offered.
- **DuckDB.** `length`: "Number of characters"; `strlen`: "Number of bytes" (DuckDB documentation, "text functions"). DuckDB's `length_grapheme` has no plan counterpart. **pyarrow.** `utf8_length` counts code points and `binary_length` bytes.
- **Current behaviour.** `src/komira_plan_expr/expr.mojo:872-889` (`STRFN_LENGTH`) and `:902-910`; the grapheme functions are refused by name (`src/komira_sql/sql_fn_table.mojo:1029-1040`).
- **Mark.** MATCHES.

### 7.2 CONCAT

- **Rule.** `concat(a, b, ...)` skips NULL arguments and is never NULL: `concat('a', NULL, 'c')` is `'ac'` and `concat(NULL, NULL)` is `''`.
- **DuckDB.** "NULL inputs are skipped" (DuckDB documentation, "text functions"); `concat(NULL, NULL)` measured as `''` (`src/komira_plan_expr/expr.mojo:1103-1110`).
- **Current behaviour.** `STRFNN_CONCAT` (`src/komira_plan_expr/expr.mojo:1103-1121`).
- **Mark.** MATCHES.

### 7.3 The `||` operator

- **Rule.** `a || b` is NULL if either operand is NULL. The plan has no `||` operator, and a frontend must not lower `||` to CONCAT (§7.2), whose NULL rule is the opposite. It lowers `a || b` to `CASE WHEN a IS NULL OR b IS NULL THEN NULL ELSE concat(a, b) END`.
- **DuckDB.** "Any NULL input results in NULL" (DuckDB documentation, "text functions").
- **Current behaviour.** No `||` in the plan or the SQL parser (`src/komira_plan_expr/expr.mojo:1110-1114`).
- **Mark.** MATCHES.

### 7.4 CONCAT_WS

- **Rule.** `concat_ws(sep, a, b, ...)`: a NULL separator makes the result NULL; a NULL argument is skipped together with its separator, so `concat_ws('-', 'a', NULL, 'c')` is `'a-c'` and `concat_ws('-', NULL, 'a')` is `'a'`. With every value argument NULL and a non-NULL separator, the result is `''`, not NULL.
- **DuckDB.** "NULL inputs are skipped" (DuckDB documentation, "text functions"); the NULL-separator rule is measured on 1.5.3 (`src/komira_plan_expr/expr.mojo:1123-1137`).
- **Current behaviour.** `STRFNN_CONCAT_WS` (`src/komira_plan_expr/expr.mojo:1123-1137`).
- **Mark.** MATCHES.

### 7.5 CONCAT argument types

- **Rule.** As DuckDB: an argument of CONCAT and CONCAT_WS may be of any type and renders as `CAST(x AS VARCHAR)` does (§6.10). The plan accepts only string arguments today, so a non-string argument is refused by name until it accepts others; a frontend may cast each argument to VARCHAR first.
- **DuckDB.** `concat` accepts any type and renders it (`concat(1, 'a', 2.5)` is `'1a2.5'`, measured, `src/komira_plan_expr/expr.mojo:1116-1121`).
- **Current behaviour.** As the rule (`src/komira_plan_expr/expr.mojo:1116-1121`).
- **Mark.** PARITY GAP ([komira#1223](https://github.com/komira-ai/komira/issues/1223)).

### 7.6 LIKE

- **Rule.** `s LIKE p` matches the whole string. `%` matches any run of zero or more characters and `_` exactly one character (one code point). Every other pattern character, backslash included, matches itself. Matching is case-sensitive and byte-exact (no collation). A NULL operand gives NULL.
- **DuckDB.** "LIKE pattern matching always covers the entire string"; ILIKE is the case-insensitive form; an escape character exists only through the `ESCAPE` clause (DuckDB documentation, "pattern matching").
- **Current behaviour.** `src/komira_column_kernels/string_comparison.mojo:1772-1822` (`_like_match`, `_` advances one code point) and `:1824-1830` ("no escape").
- **Mark.** MATCHES.

### 7.7 LIKE ESCAPE and ILIKE

- **Rule.** `LIKE ... ESCAPE c` and ILIKE answer as DuckDB does. The plan's `STR_LIKE` (`src/komira_plan_expr/expr.mojo:807`) carries no escape character and no case-insensitive flag, so until it does a frontend refuses `ESCAPE` and ILIKE by name.
- **DuckDB.** Both exist (DuckDB documentation, "pattern matching").
- **Current behaviour.** The SQL parser refuses `ESCAPE` by name (`src/komira_sql/sql_parser.mojo:1520`); ILIKE is parsed into the SQL tree, and there is no plan operator for it.
- **Mark.** PARITY GAP ([komira#1224](https://github.com/komira-ai/komira/issues/1224)).

### 7.8 Regular expressions

- **Rule.** The regular-expression functions use RE2's syntax and semantics over UTF-8: `.` and a character class match one character (code point); leftmost-first matching; no backreferences and no lookaround, which are errors at compile time. A malformed pattern is an error. `regexp_matches` (`regexp_like`) succeeds on a match anywhere; `regexp_full_match` needs the whole string. `regexp_replace` replaces the first match unless the `g` flag is given. By default `.` does not match a newline. The option flags are §7.10.
- **DuckDB.** Uses RE2; partial vs full match, first-occurrence replace and the `g` flag as stated (DuckDB documentation, "regular expressions").
- **Current behaviour.** The syntax is RE2's subset and refuses backreferences and lookaround (`src/komira_column_kernels/regexp_nfa.mojo:14-21`), but matching is over bytes ("Code that does not follow", item 5). On ASCII input the answers agree.
- **Mark.** MATCHES.

### 7.9 UPPER and LOWER

- **Rule.** Simple (one-to-one) Unicode case mapping per code point: `upper('ß')` is `'ẞ'`, not `'SS'`. Bytes that are not valid UTF-8 are copied through unchanged.
- **DuckDB.** Measured on 1.5.3 over every code point: every answer is one code point (`src/komira_column_kernels/unicode_case.mojo:17-25`).
- **Current behaviour.** `src/komira_column_kernels/unicode_case.mojo`.
- **Mark.** MATCHES.

### 7.10 Regex option flags

- **Rule.** The options string of the regex functions, as DuckDB's `ParseRegexOptions`:

  | Flag | Meaning |
  |---|---|
  | `c` | case-sensitive (the default) |
  | `i` | case-insensitive |
  | `l` | the pattern is a literal string |
  | `m`, `n`, `p` | newline-sensitive: `.` does not match a newline (the default). Not multi-line anchors |
  | `s` | `.` matches a newline |
  | `g` | replace every match; valid only for `regexp_replace`, an error elsewhere |
  | space, tab, newline | ignored |
  | anything else, including `x` | an error |

  Inline flags inside the pattern (`(?i)`, `(?s)`, `(?m)`) are RE2's and are separate from this string.
- **DuckDB.** `ParseRegexOptions` (`src/function/scalar/string/regexp/regexp_util.cpp:22-62` at v1.5.6).
- **Current behaviour.** Differs on `m`, `x`, `c` and `l` ("Code that does not follow", item 8).
- **Mark.** MATCHES.

### 7.11 regexp_extract with no match

- **Rule.** `regexp_extract(s, p, g)` answers `''` (not NULL) when `p` does not match `s`, or when group `g` did not take part in the match. A NULL `s` gives NULL.
- **DuckDB.** As stated (DuckDB documentation, "regular expressions"; the oracle confirms).
- **Current behaviour.** `src/komira_column_kernels/regexp_functions.mojo:434-440` answers `''`.
- **Mark.** MATCHES.

### 7.12 Empty string and NULL

- **Rule.** `''` is a value, distinct from NULL: `'' IS NULL` is FALSE, `length('')` is 0, and `''` and NULL are different grouping keys.
- **DuckDB.** The same.
- **Current behaviour.** A plan literal keeps `''` distinct from NULL (`src/komira_plan_expr/scalar_value.mojo:33-38`). The CSV writer renders NULL as an empty field (`src/komira_csv/csv_sink.mojo:32`), so a written CSV does not distinguish them.
- **Mark.** MATCHES.

### 7.13 Where the CSV reader turns an empty field into NULL

- **Rule.** As DuckDB's `read_csv` with default options, measured by the oracle and stated in the formats doc: an empty unquoted field is NULL; a quoted empty field (`""`) is `''`. The settled JSON and columnar half of this question is §7.17.
- **DuckDB.** The CSV defaults are to be measured by the oracle.
- **Current behaviour.** The CSV format's blank-line policy is in the [text and row formats](text_and_row_formats.md) design doc; the empty-field rule is not stated there.
- **Mark.** MATCHES.

### 7.14 No padding in string comparison

- **Rule.** Strings compare by their bytes with no trailing-space padding: `'a' = 'a '` is FALSE, and `'a' < 'a '`.
- **DuckDB.** Binary comparison of VARCHAR (DuckDB documentation, "ORDER BY"); DuckDB has no padded CHAR semantics.
- **Current behaviour.** The string comparison kernels compare bytes (`src/komira_column_kernels/string_comparison.mojo`).
- **Mark.** MATCHES.

### 7.15 Invalid UTF-8

- **Rule.** As DuckDB, which rejects invalid UTF-8 read into VARCHAR: a string column holds valid UTF-8, and a reader that meets invalid UTF-8 in a string column raises an error naming the file and column; it does not repair or pass the bytes through, so every string kernel may assume valid input. Binary columns are unaffected.
- **DuckDB.** Rejects invalid UTF-8 when reading into VARCHAR (the oracle measures the exact error).
- **Current behaviour.** The case-mapping kernels copy malformed bytes through (`src/komira_column_kernels/unicode_case.mojo:27-30`); whether each reader validates is not established here.
- **Mark.** MATCHES.

## 8. Result types

The type of every result column is in [the result-type table](query_semantics_types.md), items §8.1 to §8.31. It is part of this document: its items are counted below, and its rulings and gaps are in the rulings file.

## 9. Window functions

### 9.1 Frames

- **Rule.** In the plan every window function carries its frame explicitly (ROWS or RANGE, with its two bounds); there is no plan-level default. A frontend fills in SQL's default:
- with an ORDER BY in the window, `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, where CURRENT ROW includes all peers of the current row, so rows tying on the order key get the same value;
- with no ORDER BY, the whole partition.
- **DuckDB.** As stated (DuckDB documentation, "window functions").
- **Current behaviour.** `PartitionFrame.running_range()` is the SQL default, and its docstring says why ROWS is wrong for it (`src/komira_plan_expr/partition_frame.mojo:114-130`). FIRST_VALUE, LAST_VALUE and NTH_VALUE default to it (`src/komira_plan_expr/partition_expr.mojo:226-255`); the `running_*` builders do not ("Code that does not follow", item 6).
- **Mark.** MATCHES.

### 9.2 Ranking and ties

- **Rule.** ROW_NUMBER numbers the rows of a partition 1 to n. Peers are rows whose order keys compare equal on every key, with NULL equal to NULL (§9.7) and floats under §2.6. RANK gives peers the row number of the first peer, leaving gaps. DENSE_RANK numbers peer groups 1, 2, 3 without gaps; PERCENT_RANK and CUME_DIST are computed over the same peer groups. Ranking functions ignore the frame, so this peer definition applies to them whatever the frame says.
- **DuckDB.** rank is "same as row_number of its first peer"; dense_rank "counts peer groups" (DuckDB documentation, "window functions").
- **Current behaviour.** Declared at `src/komira_plan_expr/partition_expr.mojo:44-46`; the window operator is not here.
- **Mark.** MATCHES.

### 9.3 ROW_NUMBER among peers

- **Rule.** Which peer gets which ROW_NUMBER is not specified (§4.7). A test fixes it with an order key that has no ties, or compares peers as a set.
- **DuckDB.** Not specified.
- **Current behaviour.** As §9.2.
- **Mark.** MATCHES.

### 9.4 LAG and LEAD

- **Rule.** The offset defaults to 1. Where the offset row does not exist, the result is the default value, and the default value defaults to NULL. An explicit NULL default is the same as no default. LAG and LEAD ignore the frame.
- **DuckDB.** The offset "defaults to 1"; the default "default to NULL" (DuckDB documentation, "window functions").
- **Current behaviour.** `src/komira_plan_expr/partition_expr.mojo:199-224` and `:371-384`.
- **Mark.** MATCHES.

### 9.5 IGNORE NULLS

- **Rule.** Without `IGNORE NULLS`, LAG, LEAD, FIRST_VALUE, LAST_VALUE and NTH_VALUE count every row, NULL or not (§9.10). With it they answer as DuckDB does; it is not in the plan vocabulary yet, so a frontend refuses it by name.
- **DuckDB.** Its signatures accept `[IGNORE NULLS]` on `first_value`, `last_value`, `nth_value`, `lag` and `lead` (DuckDB documentation, "window functions").
- **Current behaviour.** No such field on `PartitionExpr` (`src/komira_plan_expr/partition_expr.mojo:110-150`).
- **Mark.** PARITY GAP ([komira#1226](https://github.com/komira-ai/komira/issues/1226)).

### 9.6 NULL placement in a window's ORDER BY

- **Rule.** A window ORDER BY key with no stated placement uses §4.1's default; an explicit `NULLS FIRST` or `NULLS LAST` inside `OVER (...)` answers as DuckDB does. The plan cannot express a placement yet, so a frontend refuses `NULLS FIRST` inside `OVER` by name (`NULLS LAST` is the default, so it may be accepted).
- **DuckDB.** Accepts an explicit placement in `OVER`.
- **Current behaviour.** The PARTITION_BY node carries no per-key placement (its wire arm has no such field), so the window key takes `derived_nulls_first` (`src/komira_plan_expr/null_order_policy.mojo:80-93`).
- **Mark.** PARITY GAP ([komira#1227](https://github.com/komira-ai/komira/issues/1227)).

### 9.7 NULL order keys are peers

- **Rule.** Rows whose order key is NULL are peers of one another: they form one peer group, placed by §4.1. This holds for the ranking functions whatever the frame (§9.2), so NULL-keyed rows tie in RANK, DENSE_RANK, PERCENT_RANK and CUME_DIST; and under a RANGE frame they also get the same running value. Under a ROWS frame, frame bounds count physical rows, but ranking still treats them as peers.
- **DuckDB.** The same: NULLs compare equal for peer detection, so NULL-keyed rows tie in the ranking functions and share a RANGE frame (the oracle confirms).
- **Current behaviour.** No window operator here.
- **Mark.** MATCHES.

### 9.8 RANGE frames with offsets

- **Rule.** As DuckDB. `RANGE BETWEEN n PRECEDING AND m FOLLOWING` needs exactly one numeric or temporal order key. The frames of NULL and NaN order keys are DuckDB's, measured by the oracle before a case relies on them; the expected answer is that a NULL-keyed row's frame is the NULL peer group and NaN keys are peers of each other, sorting per §4.3. The plan's offsets are INT64 (`src/komira_plan_expr/partition_frame.mojo:51-58`); a fractional offset over a float key and an interval offset over a temporal key are refused by name until the plan carries them ([komira#1228](https://github.com/komira-ai/komira/issues/1228)).
- **DuckDB.** Accepts fractional offsets over float keys; its frame for a NULL or NaN key is not documented and the oracle measures it.
- **Current behaviour.** No window operator here.
- **Mark.** MATCHES (its non-integer offsets are a parity gap).

### 9.9 NULL partition keys

- **Rule.** For PARTITION BY (windows and PARTITION_TOPN), NULL equals NULL: all rows whose partition key is NULL form one partition, as in grouping (§2.4). Multi-column keys compare column by column under the same rule, and float keys follow §2.6.
- **DuckDB.** PARTITION BY groups rows like GROUP BY, NULLs together (DuckDB documentation, "window functions"; the oracle confirms).
- **Current behaviour.** No window operator here.
- **Mark.** MATCHES.

### 9.10 FIRST_VALUE, LAST_VALUE and NTH_VALUE over NULLs

- **Rule.** These functions respect NULLs: FIRST_VALUE is the value of the frame's first row and LAST_VALUE of its last row, NULL if that row's value is NULL. NTH_VALUE(x, n) is the value of the n-th row of the frame, counting from 1 and counting rows whose value is NULL; it is NULL when the frame has fewer than n rows. All three are NULL over an empty frame. Skipping NULLs (`IGNORE NULLS`) is §9.5.
- **DuckDB.** RESPECT NULLS is the default, with IGNORE NULLS as an option; `nth_value` evaluates "at the nth row (counting from 1) of the window frame" (DuckDB documentation, "window functions").
- **Current behaviour.** `PartitionExpr` carries no IGNORE NULLS field, and the value functions read their frame (`src/komira_plan_expr/partition_expr.mojo:51-54`, `:226-255`); no window operator is in this repository.
- **Mark.** MATCHES.

## 10. Reserved

Excel semantics are not part of the plan; they belong to the Excel surface, which is built on the TypeScript SDK.

## 11. Set operations and empty inputs

### 11.1 UNION ALL

- **Rule.** UNION ALL concatenates its inputs and keeps every row (bag semantics). The order of the output is not promised (§4.8). Every input has the same schema: same column count, names and types by position; the plan does not coerce.
- **DuckDB.** "UNION ALL" keeps all rows (DuckDB documentation, "set operations").
- **Current behaviour.** `LogicalPlan.union` builds UNION ALL and requires the caller to give every child the output schema; "the engine does not coerce" (`src/komira_plan_ir/logical_plan.mojo:1052-1068`).
- **Mark.** MATCHES.

### 11.2 UNION (distinct)

- **Rule.** UNION is UNION ALL followed by DISTINCT over all columns, with NULLs equal (§2.4) and floats under §2.6. A frontend builds it from the two plan nodes.
- **DuckDB.** "The vanilla UNION clause follows set semantics, therefore it performs duplicate elimination" (DuckDB documentation, "set operations").
- **Current behaviour.** UNION ALL and DISTINCT are separate plan nodes (`src/komira_plan_ir/logical_plan.mojo:97`, `:110`).
- **Mark.** MATCHES.

### 11.3 INTERSECT and EXCEPT

- **Rule.** As DuckDB: INTERSECT and EXCEPT compare whole rows with NULLs equal, like DISTINCT, not with `=`. Without ALL they return distinct rows. With ALL they are bag operations: a row appearing `m` times on the left and `n` on the right appears `min(m, n)` times in INTERSECT ALL and `max(m - n, 0)` times in EXCEPT ALL. The plan has no node for them yet, so frontends refuse them by name until it does.
- **DuckDB.** Both forms, set and bag (DuckDB documentation, "set operations"); NULL handling is not documented there and the oracle measures it.
- **Current behaviour.** The plan has no set-operation node for them. A SEMI or ANTI join on `=` is **not** a lowering of them: it drops rows with a NULL in any column (§3.1), where INTERSECT and EXCEPT keep them.
- **Mark.** PARITY GAP ([komira#1229](https://github.com/komira-ai/komira/issues/1229)).

### 11.4 Column types across set-operation inputs

- **Rule.** Inputs of a set operation must already have identical column types. A SQL frontend casts each input to the type DuckDB's implicit cast gives (§8.9, §8.14) before building the node; the plan refuses a mismatch by name. Column names must also be identical in every input (§11.1), so the output's names are every input's; a frontend that follows DuckDB's "names from the first query" renames the later inputs by projection first. Nullability may differ (§11.7).
- **DuckDB.** "Implicit casting to one of the returned types is performed", and the result takes "the column names from the first query" (DuckDB documentation, "set operations").
- **Current behaviour.** As §11.1: no coercion in the plan.
- **Mark.** MATCHES: at the SQL surface. The plan takes no implicit casts; the frontend inserts the casts DuckDB inserts and takes the names from the first query, so a SQL query's result is DuckDB's.

### 11.5 UNION BY NAME

- **Rule.** UNION [ALL] BY NAME matches columns by name; a column missing from an input is NULL there. The plan has no BY NAME form: a frontend lowers it by projecting each input to the full, ordered column list, with NULL literals of the column's type for missing columns, then applies §11.1 or §11.2.
- **DuckDB.** Matches by name and fills missing columns with NULL (DuckDB documentation, "set operations").
- **Current behaviour.** Nothing needed in the plan.
- **Mark.** MATCHES.

### 11.6 Empty inputs

- **Rule.** A CROSS JOIN with an empty side has zero rows. An INNER or SEMI join with an empty side has zero rows; a LEFT join with an empty right side returns every left row padded (§3.4); an ANTI join with an empty right side returns every left row. A UNION ALL of empty inputs is empty with the common schema. A scalar aggregate over empty input still returns one row (§2.3). Every empty result carries its full schema.
- **DuckDB.** Standard SQL; the oracle confirms.
- **Current behaviour.** No join or set-operation operator here.
- **Mark.** MATCHES.

## 12. Dates

### 12.1 DATE plus or minus an integer

- **Rule.** `DATE ± INT` adds or subtracts whole days and is a DATE. A result outside the DATE range is an error.
- **DuckDB.** "addition of days (integers)": `DATE '1992-03-22' + 5` is `1992-03-27` (DuckDB documentation, "date functions"); the out-of-range error is measured by the oracle.
- **Current behaviour.** No DATE arithmetic kernel was found by name in this repository.
- **Mark.** MATCHES.

### 12.2 DATE minus DATE

- **Rule.** `DATE - DATE` is the number of days between them, as INT64.
- **DuckDB.** `DATE '1992-03-27' - DATE '1992-03-22'` is `5` (DuckDB documentation, "date functions"); its type, BIGINT, is confirmed by the oracle.
- **Current behaviour.** As §12.1.
- **Mark.** MATCHES.

### 12.3 Infinite dates and timestamps

- **Rule.** The plan has no infinite DATE or TIMESTAMP. Arrow's `date32` and `timestamp` carry plain integers with no infinity marker, so `infinity` and `-infinity` cannot be represented. A reader or cast that meets the text `infinity` for a DATE or TIMESTAMP column raises by name.
- **DuckDB.** Supports `infinity` and `-infinity`; "adding to or subtracting from infinite values produces the same infinite value" (DuckDB documentation, "date functions", "timestamp types"). Oracle datasets contain no infinite values.
- **Current behaviour.** No infinity handling in the temporal kernels (`src/komira_kernels/temporal_extract.mojo`).
- **Mark.** REPRESENTATION DEPARTURE: Arrow cannot represent the value; a reader or cast that meets it raises by name.

### 12.4 Out-of-range dates and timestamps

- **Rule.** The range of a DATE or TIMESTAMP result is DuckDB's range for that type, not Arrow's. Arithmetic, a function or a cast whose result lies outside DuckDB's range is an error, raised as DuckDB raises it (the oracle measures the error class), never a value and never a wrapped value. DuckDB's DATE range is narrower than Arrow's `date32`, so a day `date32` can hold but DuckDB's DATE cannot is an error too; the same holds for each timestamp unit against DuckDB's TIMESTAMP_S, TIMESTAMP_MS, TIMESTAMP and TIMESTAMP_NS. The oracle measures both boundaries of each type, and cases test a value just inside and just outside each.
- **DuckDB.** Raises an out-of-range error. Its DATE is a 32-bit day count whose extreme values are reserved for `infinity` and `-infinity` (§12.3), which is why its range is narrower than `date32`'s (inferred from DuckDB's source; the oracle measures the boundary).
- **Current behaviour.** No DATE arithmetic kernel and no unit-changing timestamp cast here (§12.1, §6.8). The DATE `date_trunc` kernel converts its result with `Int32(trunc_days)` and no range check (`src/komira_kernels/temporal_extract.mojo:986`), so a truncation below the first representable day wraps where the rule is DuckDB's error ("Code that does not follow", item 27). Whether each reader checks DATE days and timestamp ticks against DuckDB's range is not yet recorded.
- **Mark.** MATCHES.

## Counts

MATCHES 133, REPRESENTATION DEPARTURE 4, PARITY GAP 11, EXTENSION 2: 150 marks, across this file, [the result-type table](query_semantics_types.md), [further items](query_semantics_more.md) and [scans](query_semantics_scans.md). Each numbered item counts once: every subsection that carries a **Mark** line, plus each row of the §8 table that has no subsection of its own (§8.10 repeats §5.1 and is not counted). The 42 rows of "Rulings" ([rulings, parity gaps and code status](query_semantics_rulings.md)) are the items settled under the governing rule: 25 MATCHES, 4 REPRESENTATION DEPARTURE, 11 PARITY GAP and 2 EXTENSION. The parity-gap table there has 15 rows: the 11 PARITY GAP items and 4 refused cases inside items that otherwise MATCH (§7.1, §8.15, §9.8, §13.5).

## What are its limits and open questions?

- **No end-to-end evidence yet.** Most operators named here have no executor in this repository, so "current behaviour" is often a kernel, an IR declaration or a comment. Only the conformance suite can say what a plan returns.
- **DuckDB statements taken from komira's source.** Where DuckDB's documentation is silent, this document quotes measurements recorded in komira's source. They are claims about DuckDB, not about komira, and the oracle re-measures each; a disagreement corrects this document.
- **Not covered.** Collations, intervals and interval arithmetic, nested types, JSON functions, the temporal field extracts (beyond §6.9), math-function domain errors (`sqrt(-1)`, `ln(0)`), UDF null modes, and the rounding of `round()` (half away from zero, `src/komira_column_kernels/numeric_unary.mojo:35`). Each needs its own items before a hand expectation may rely on it.

## Sources

DuckDB documentation, cited by page title (its `current` pages, which are the 1.5 documentation):
- Logical operators
- Comparison operators
- IN operator
- NULL values
- Aggregate functions
- FROM and JOIN clauses
- ORDER BY clause
- Configuration
- Numeric types
- Numeric functions
- Typecasting
- Timestamp types
- Text functions
- Pattern matching
- Regular expressions
- Window functions
- Set operations
- Date functions
- Order preservation
- Utility functions
- Loading JSON
- Avro extension

DuckDB source:
- [DuckDB v1.5.6 source](https://github.com/duckdb/duckdb/tree/v1.5.6) and [duckdb/duckdb#25332](https://github.com/duckdb/duckdb/pull/25332)

Apache Arrow documentation:
- [Compute functions (C++)](https://arrow.apache.org/docs/cpp/compute.html)
- [pyarrow compute API](https://arrow.apache.org/docs/python/api/compute.html)
- [SetLookupOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.SetLookupOptions.html)
