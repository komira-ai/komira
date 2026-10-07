# Query semantics: what a plan's result must be

Status: **draft for ruling.** Items marked UNDECIDED or DEPARTS take effect only once they are ruled on; the list is in "Rulings needed" below.

## What is it for, and what is out of scope?

This document states what a komira logical plan must return: how NULLs flow through logic, aggregates, joins and sorts; what arithmetic does at its edges; what casts and string functions mean; and the type of every result. It is the authority a hand-written test expectation cites. A conformance case whose expected value is derived by hand names the item it relies on (for example "§5.3"), never engine code: an expectation read off the code that produces the answer would let the engine grade itself.

The reference engine is **DuckDB v1.5.6** ([release tag](https://github.com/duckdb/duckdb/tree/v1.5.6)), pinned by exact version. The oracle runs it with:
- its defaults for `ieee_floating_point_ops` (true), `integer_division` (false), `default_null_order` (`NULLS_LAST`) and `preserve_insertion_order` (true);
- `threads = 1` and `TimeZone = 'UTC'`;
- every literal cast to the plan literal's type (§8.19).

A different DuckDB version is a pin change, reviewed as one. DuckDB 2.0 adds the setting `error_on_division_by_zero`, default true ([duckdb/duckdb#25332](https://github.com/duckdb/duckdb/pull/25332)); on 2.0 or later the oracle must `SET error_on_division_by_zero = false`, or §5.3 flips from NULL to an error.

DuckDB's documentation links below are its `current` pages, which are the 1.5 documentation; DuckDB publishes no versioned URL for its current release. A statement resting on DuckDB's source cites the file at the v1.5.6 tag. Where both are silent, the statement quotes a measurement recorded in komira's source (taken on DuckDB 1.5.3) or says it is inferred, and the oracle re-measures it on v1.5.6; a disagreement is a defect in this document. pyarrow's compute functions are a second oracle for single-kernel cases; where pyarrow disagrees with DuckDB this document says which one the plan follows.

Each item has four parts:

- **Rule**: what a plan must return.
- **DuckDB** (and **pyarrow** where relevant): what the reference does.
- **Current behaviour**: what komira's code does today, cited as `file:line`. It is evidence, not authority: where it differs from the rule, the code is wrong or the rule is still open.
- **Mark**: one of
  - **MATCHES**: the rule is DuckDB's;
  - **DEPARTS**: the rule differs from DuckDB, for the reason given;
  - **UNDECIDED**: the options and a recommendation.

Scope is the plan: the logical-plan IR (`src/komira_plan_ir`, `src/komira_plan_expr`) and its wire form (`src/komira_plan_wire`). A frontend (SQL, a dataframe API, a spreadsheet) maps its own surface onto these rules; where a frontend's spelling differs from the plan operator of the same name (SQL `/` against the plan's `BIN_DIV`), the item says so. Out of scope: collations other than binary, intervals, nested types (struct, list, map), JSON functions, the temporal field extracts beyond time zones and §8.15, and UDF null modes. Each of those needs its own section before a hand expectation may depend on it.

Many operators named here have no executor in this repository yet (the engine operators arrive separately). Where that is so, "current behaviour" cites the IR, the wire admission or a kernel, and says that nothing executes the operator end to end.

## Rulings needed

Every DEPARTS and UNDECIDED item, with the recommendation. A ruling either accepts the recommendation or names another option; the item's mark then changes to MATCHES or DEPARTS and the ruling is recorded beside it.

| Item | Topic | Mark | Recommendation |
|---|---|---|---|
| §1.6 | `IS [NOT] DISTINCT FROM` | UNDECIDED | Frontends desugar it to `IS NULL` / `=` combinations now; add plan operators only when a null-safe join key needs one. |
| §2.8 | MEDIAN and quantiles over NaN | UNDECIDED | Match DuckDB: NaN is a value and takes part (it sorts above +inf); an all-NaN group answers NaN, not NULL. |
| §3.7 | ASOF `NEAREST`, ties to the earlier row | DEPARTS | Accept: DuckDB has no NEAREST; keep it as a komira extension with hand-derived expectations citing this item. |
| §3.8 | ASOF tolerance; no strict `<` / `>` ASOF | DEPARTS | Accept: the tolerance is a komira extension (the oracle checks it with a LEFT ASOF join and NULLing); strict forms are refused by name. |
| §4.5 | NaN in comparison predicates | UNDECIDED | Match DuckDB: `NaN = NaN` is TRUE, `NaN > x` is TRUE for every non-NaN `x`; one float model for comparisons, sorting and grouping. |
| §5.1 | `BIN_DIV` on two integers truncates and keeps the integer type | DEPARTS | Accept: the plan has one division operator, and it is DuckDB's `//`; a frontend's true division (`/`) casts an operand to DOUBLE first. |
| §6.6 | String-to-integer grammar | UNDECIDED | (a): accept all of DuckDB's extensions (`'1.5'` is 2, `'1e2'` is 100, `'1_000'` is 1000, `'0x1F'`, `'0b101'`), each measured by the oracle. |
| §6.7 | String-to-double out of range | UNDECIDED | Match DuckDB (likely a Conversion Error, to be measured); the code saturates to ±inf today. |
| §6.8 | Casts between timestamp units | UNDECIDED | Match DuckDB: widening is exact, narrowing follows DuckDB's measured rounding before the Unix epoch, out of range is an error. |
| §6.9 | Time zones and the session zone | UNDECIDED | Fix the session time zone to UTC; field extraction over a zoned timestamp happens in UTC until a session-zone setting exists. |
| §6.10 | CAST_TO_VARCHAR rendering | UNDECIDED | Match DuckDB's `CAST(x AS VARCHAR)` per type, written out as a table in this item; pyarrow's float rendering (`1` for 1.0) is not followed. |
| §6.11 | Zoned with unzoned timestamps | DEPARTS | Accept: refused by name; a frontend casts one side. |
| §7.5 | CONCAT takes only string arguments | DEPARTS | Accept: a non-string argument is refused by name; never a different value. |
| §7.7 | No LIKE `ESCAPE`, no ILIKE in the plan | DEPARTS | Accept for now: both are refused by name; add when a frontend needs them. |
| §7.13 | Readers: empty field vs NULL | UNDECIDED | Match DuckDB's `read_csv` defaults (empty unquoted field NULL, `""` is `''`), measured, and state it in the formats doc. |
| §7.15 | Invalid UTF-8 in a string column | UNDECIDED | The reader raises by name; string kernels may then assume valid UTF-8. |
| §8.1 | SUM of a signed integer or BOOLEAN is INT64 and refuses overflow | DEPARTS | Accept: Arrow has no 128-bit integer; a total outside INT64 is an error naming the column, never a wrapped value. |
| §8.2 | SUM of an unsigned integer is UINT64 | DEPARTS | Accept, with the same overflow error as §8.1. |
| §8.9 | Result type of integer and mixed arithmetic | UNDECIDED | Adopt the narrowest-common-type table in §8.9 (DuckDB's rule); retire "left operand wins". |
| §8.11 | Decimal addition and subtraction | DEPARTS | Accept: DECIMAL(min(max(p1 - s1, p2 - s2) + max(s1, s2) + 1, 38), max(s1, s2)) without DuckDB's 18-digit case, for §8.12's reason. |
| §8.12 | Decimal multiplication | DEPARTS | Accept: DECIMAL(min(p1 + p2, 38), s1 + s2) without DuckDB's 18-digit case; the code drops its `+ 1`. |
| §8.14 | Result type of CASE and COALESCE over mixed types | UNDECIDED | The common type by §8.9's table; mixes with none are refused by name. |
| §8.17 | MEDIAN of FLOAT32, DECIMAL, DATE | UNDECIDED | Match DuckDB for FLOAT32 (FLOAT) and DECIMAL (same DECIMAL); refuse DATE by name. |
| §8.18 | `uint64` with a signed integer | DEPARTS | Accept: refused by name (DuckDB's HUGEINT has no Arrow type). |
| §9.5 | No `IGNORE NULLS` for LAG/LEAD | DEPARTS | Accept for now: refused by name. |
| §9.6 | Window ORDER BY cannot state its NULL placement | DEPARTS | Accept for now: the window key uses §4.1's default; a frontend refuses an explicit `NULLS FIRST` inside `OVER`. |
| §9.8 | RANGE frames with offsets | UNDECIDED | INT64 offsets only (fractional offsets refused); measure DuckDB's NULL and NaN frames first. |
| §10.1 | Excel error-code space | DEPARTS | Ratify: Microsoft's list without a circular-reference code (DuckDB has no error values). |
| §10.2 | Error propagation through scalar expressions | UNDECIDED | An error dominates NULL; the leftmost error operand wins; AND/OR do not short-circuit past an error. |
| §10.3 | Errors in aggregates and sorts | UNDECIDED | SUM/AVERAGE/MIN/MAX answer the first error in input order; COUNT skips errors; sort places errors after logical values and before blanks, all errors equal. |
| §11.3 | INTERSECT and EXCEPT | UNDECIDED | Frontends refuse them by name until a null-safe join key exists; a SEMI/ANTI join on `=` is not a lowering. |
| §11.4 | Set-operation inputs must have identical types | DEPARTS | Accept: the frontend inserts the casts DuckDB inserts implicitly. |
| §12.3 | No infinite dates or timestamps | DEPARTS | Accept: Arrow cannot represent them; refused by name. |

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
7. **Sample statistics of one row answer NaN (§2.11).** `src/komira_agg/builtin_agg_fns_stddev.mojo:15-18` and `:67-79` answer NaN for `stddev_samp` and `var_samp` over one row and call it DuckDB's NULL convention; DuckDB answers NULL.
8. **Regex flags (§7.10).** `parse_flags_string` (`src/komira_column_kernels/regexp_nfa.mojo:217-234`) reads `m` as multi-line anchors and accepts `x`; DuckDB reads `m` as "`.` does not match a newline" and refuses `x`. It refuses `c` and `l`, which DuckDB accepts.
9. **DECIMAL modulo is typed with the left operand's precision and scale (§5.10).** `src/komira_plan_expr/expr_walk.mojo:896-901`; the rule is DuckDB's DECIMAL(max(p1 - s1, p2 - s2) + max(s1, s2), max(s1, s2)), DOUBLE above 38.
10. **The float-to-integer window for an unsigned target is empty (§6.3).** `eval_cast_float_to_int` (`src/komira_column_kernels/cast_null.mojo`, around line 277) builds its window as `[MIN, -MIN)`, which is `[0, 0)` for an unsigned target and would refuse every value; the rule's window is `[0, MAX + 1)`. Latent today: every caller instantiates a signed target.
11. **A NULL literal is declared non-nullable (§8.19).** `walk_expr_field` returns `Field("literal", <type>, False)` for every literal, the NULL literal included (`src/komira_plan_expr/expr_walk.mojo:814-817`), so a projected `NULL` is a column declared non-nullable whose every row is NULL.

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

- **DuckDB.** The same table ([logical operators](https://duckdb.org/docs/current/sql/expressions/logical_operators.html)). **pyarrow.** `and_kleene` / `or_kleene` follow this table; `and_` / `or_` propagate NULL instead and are not the oracle for this item ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).
- **Current behaviour.** `src/komira_kernels/kleene.mojo:15-22` states the table, and `:131-176` implements it on bitmap bytes.
- **Mark.** MATCHES.

### 1.2 Comparisons with NULL, and filters

- **Rule.** `=`, `<>`, `<`, `<=`, `>`, `>=` answer NULL when either operand is NULL, including `NULL = NULL`. A FILTER keeps a row only when its predicate is TRUE; FALSE and NULL both drop it.
- **DuckDB.** "Whenever either of the input arguments is NULL, the output of the comparison is NULL" ([comparison operators](https://duckdb.org/docs/current/sql/expressions/comparison_operators.html), [NULL values](https://duckdb.org/docs/current/sql/data_types/nulls.html)).
- **Current behaviour.** A comparison result is valid only where both operands are valid (`src/komira_kernels/kleene.mojo:192-203`).
- **Mark.** MATCHES.

### 1.3 IS NULL, IS NOT NULL

- **Rule.** Both are total: never NULL, so their result type is a non-nullable BOOLEAN (§8.21). `x IS NULL` is TRUE exactly when `x` is NULL. A NaN is not NULL (§4.3).
- **DuckDB.** As stated ([NULL values](https://duckdb.org/docs/current/sql/data_types/nulls.html)).
- **Current behaviour.** `src/komira_expr/runtime_expr_bool.mojo:766-800` returns an always-valid result from the validity bit, and the plan declares both non-nullable (`src/komira_plan_expr/expr_walk.mojo:1045-1052`).
- **Mark.** MATCHES.

### 1.4 IN with a NULL in the list, or a NULL on the left

- **Rule.** `x IN (v1, ..., vn)` is `x = v1 OR ... OR x = vn` under §1.1 and §1.2:
  - TRUE if some non-NULL `vi` equals `x`;
  - otherwise NULL if `x` is NULL or some `vi` is NULL;
  - otherwise FALSE.

  So `2 IN (1, NULL)` is NULL, `1 IN (1, NULL)` is TRUE, and `NULL IN (1, 2)` is NULL. The plan's IN_LIST is this tuple form.
- **DuckDB.** The same for a parenthesized list; DuckDB's *list* form `x IN [..]` ignores NULL members and is not what IN_LIST means ([IN operator](https://duckdb.org/docs/current/sql/expressions/in.html)). **pyarrow.** `is_in` with the default `skip_nulls=False` matches a NULL input to a NULL in the value set and never answers NULL, so it is not an oracle for this item ([SetLookupOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.SetLookupOptions.html)).
- **Current behaviour.** No IN_LIST evaluator is in this repository. The wire admits NULL members (`src/komira_plan_wire/plan_wire_values.mojo:1899-1906`), and its docstring describes the rule above for the engine's evaluator.
- **Mark.** MATCHES.

### 1.5 NOT IN

- **Rule.** `x NOT IN (...)` is `NOT (x IN (...))`. So a list containing NULL makes every non-matching row NULL, and a filter on it returns no such row.
- **DuckDB.** "`x NOT IN y` is equivalent to `NOT (x IN y)`" ([IN operator](https://duckdb.org/docs/current/sql/expressions/in.html)).
- **Current behaviour.** As §1.4: no evaluator here. The subquery form is §3.3.
- **Mark.** MATCHES.

### 1.6 IS [NOT] DISTINCT FROM

- **Rule (proposed).** `a IS DISTINCT FROM b` is FALSE when both are NULL, TRUE when exactly one is NULL, and `a <> b` otherwise; it is never NULL. `IS NOT DISTINCT FROM` is its negation.
- **DuckDB.** As stated ([comparison operators](https://duckdb.org/docs/current/sql/expressions/comparison_operators.html)).
- **Current behaviour.** The plan has no operator for it: the binary operators are ADD SUB MUL DIV MOD, EQ NE LT LE GT GE, AND OR (`src/komira_plan_expr/expr.mojo:665-686`). The SQL parser refuses the spelling by name (`src/komira_sql/sql_parser.mojo:1863-1868`).
- **Options.**
- (a) Frontends desugar: `a IS NOT DISTINCT FROM b` becomes `(a IS NULL AND b IS NULL) OR (a IS NOT NULL AND b IS NOT NULL AND a = b)`. No wire change. It evaluates each operand more than once.
- (b) Add two binary operators to the IR and the wire. One node, one evaluation; a wire-vocabulary change with its goldens.
- **Recommendation.** (a) now; (b) when a null-safe equi-join key needs it, since a join cannot use the desugared form as a hash key.
- **Mark.** UNDECIDED.

### 1.7 CASE with a NULL condition

- **Rule.** A `WHEN` whose condition is NULL is not taken; evaluation moves to the next `WHEN`, then to `ELSE`, and a missing `ELSE` answers NULL.
- **DuckDB.** Standard SQL `CASE`; the oracle confirms.
- **Current behaviour.** No CASE evaluator here. COALESCE is built as a CASE over `IS NOT NULL` conditions (`src/komira_plan_expr/scalar_desugar.mojo:84-111`).
- **Mark.** MATCHES.

## 2. NULLs in aggregates

### 2.1 NULL inputs are skipped; COUNT(*) is not COUNT(col)

- **Rule.** Every aggregate skips NULL inputs, except FIRST and LAST (§2.9). `COUNT(*)` counts rows; `COUNT(col)` counts rows where `col` is not NULL.
- **DuckDB.** "All general aggregate functions ignore NULLs, except for list (array_agg), first (arbitrary) and last" ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)). **pyarrow.** `count` defaults to `mode="only_valid"`.
- **Current behaviour.** `src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:95-99` and `:1431-1437` skip NULL inputs.
- **Mark.** MATCHES.

### 2.2 All-NULL groups and empty groups

- **Rule.** SUM, AVG, MIN and MAX over a group with no non-NULL input are NULL (SUM is not 0). COUNT is 0.
- **DuckDB.** "All general aggregate functions except count return NULL on empty groups ... sum does not return zero" ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)). **pyarrow.** `sum` with its default `min_count=1` answers null.
- **Current behaviour.** The mixed fold emits NULL when the contributing count is 0 (`src/komira_dispatch_agg_folds/agg_mixed_cd_fold.mojo:96-99`, `:262-266`); MIN/MAX cells carry a `seen` flag (`src/komira_agg/builtin_agg_fns_minmax.mojo:39-45`). The SUM cells in `komira_agg` do not: see "Code that does not follow", item 2.
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
- **DuckDB.** "When the DISTINCT clause is provided, only distinct values are considered", and NULLs are ignored ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)).
- **Current behaviour.** `src/komira_agg_api/cd_distinct_key.mojo:234-263` reads the NULL mask beside the distinct keys so NULL rows are not counted.
- **Mark.** MATCHES.

### 2.6 Floating-point grouping keys

- **Rule.** As grouping and DISTINCT keys, all NaNs are one value and `-0.0` equals `+0.0`. Which bit pattern represents the group (`-0.0` or `+0.0`, which NaN payload) is not part of the result: tests compare floats under this equality, never by sign bit or payload.
- **DuckDB.** Measured on 1.5.3 and recorded in `src/komira_udf/float_quotient_order.mojo:29-36`: `GROUP BY v` over `{1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}` gives five groups, `{0.0, -0.0}` one of them and `{NaN, NaN}` another.
- **Current behaviour.** `src/komira_udf/float_quotient_order.mojo` is the one model, used by the hash and key-equality functions it lists at `:53-75`.
- **Mark.** MATCHES.

### 2.7 MIN and MAX over NaN

- **Rule.** NaN is greater than every other float, including +inf: MAX over a set containing NaN is NaN; MIN is NaN only if every input is NaN. The answer does not depend on input order or on how work is split between workers.
- **DuckDB.** "NaN compares equal to NaN and greater than any other floating point number" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)).
- **Current behaviour.** `src/komira_agg/builtin_agg_fns_minmax.mojo:19-37`: the float cells compare through the float model, and the header records the order-dependent answers the bare comparison used to give.
- **Mark.** MATCHES.

### 2.8 MEDIAN and quantiles over NaN

- **Rule (proposed).** NaN takes part like any other value and sorts above +inf (§4.3). A group whose only non-NULL values are NaN answers NaN.
- **DuckDB.** Includes NaN (the measurement is recorded at `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82`).
- **Current behaviour.** `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82` excludes NaN rows and answers NULL for an all-NaN group, and notes that DuckDB does not.
- **Options.** (a) Match DuckDB. (b) Keep excluding NaN, as pandas' `median` does with its NaN-as-missing model, and record the departure.
- **Recommendation.** (a). The plan distinguishes NaN from NULL everywhere else (§1.3, §2.6); excluding NaN here alone makes MEDIAN the one aggregate that treats NaN as missing. A pandas frontend that wants (b) can filter NaN before aggregating.
- **Mark.** UNDECIDED.

### 2.9 FIRST, LAST, ANY_VALUE

- **Rule.** FIRST and LAST return the value of the first and last row of the group in input order, NULL included. ANY_VALUE returns the first non-NULL value. Without an order imposed below the aggregate, which row is first is not defined, so a test may assert these only over an input whose order the plan fixes.
- **DuckDB.** "first(arg): Returns the first value (null or non-null) from arg" ([aggregate functions](https://duckdb.org/docs/current/sql/functions/aggregates.html)).
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

## 3. NULLs in joins

### 3.1 NULL keys never match in an equi-join

- **Rule.** In INNER, LEFT, RIGHT, FULL and SEMI joins, a row whose equi-join key has a NULL in any key column matches nothing. In an outer join such a row still appears once, padded (§3.4). HASH and SORT_MERGE give the same result for the same inputs.
- **DuckDB.** Follows from §1.2: the join condition is NULL, and NULL does not match ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).
- **Current behaviour.** No join operator is in this repository; the join types and algorithms are declared at `src/komira_plan_ir/logical_plan.mojo:469-490`.
- **Mark.** MATCHES.

### 3.2 ANTI join is NOT EXISTS

- **Rule.** An ANTI join returns each left row that has no matching right row. A left row whose key is NULL matches nothing and is therefore returned; NULL keys on the right side match nothing and have no effect.
- **DuckDB.** "Anti joins provide the same logic as the NOT IN operator, except anti joins ignore NULL values from the right table" ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).
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
- **DuckDB.** "When an unpaired row is returned, the attributes from the other table are set to NULL" ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).
- **Current behaviour.** The gather kernels keep a zero fill under a `-1` (unmatched) index (`src/komira_join_assembly/compiler_join_assembly.mojo:1339-1342`); the validity of padded rows is the operator's, which is not here.
- **Mark.** MATCHES.

### 3.5 Residual predicates

- **Rule.** A residual (non-equi) join predicate that evaluates to NULL for a pair counts as no match, exactly like FALSE.
- **DuckDB.** Follows from §1.2.
- **Current behaviour.** No join operator here.
- **Mark.** MATCHES.

### 3.6 ASOF BACKWARD and FORWARD

- **Rule.** BACKWARD matches each left row with the right row of the same equality group whose ordering value is the greatest one `<=` the left row's; FORWARD with the least one `>=`. At most one right row matches. A NULL ordering value matches nothing. The plan has only these non-strict forms; tolerance and strict inequalities are §3.8.
- **DuckDB.** ASOF with `>=` (and `<=`) "joins each left side row with at most one right side row" ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)).
- **Current behaviour.** `src/komira_plan_ir/logical_plan.mojo:497-499` declares the directions.
- **Mark.** MATCHES.

### 3.7 ASOF NEAREST

- **Rule.** NEAREST matches the right row with the smallest `|left - right|`; on a tie between an earlier and a later row, the earlier (backward) row wins.
- **DuckDB.** No NEAREST direction. polars' `join_asof(strategy="nearest")` is the nearest external analogue, but this document does not adopt its tie rule without a measurement.
- **Current behaviour.** Declared at `src/komira_plan_ir/logical_plan.mojo:499`.
- **Mark.** DEPARTS: a komira extension with no DuckDB counterpart. Expectations are hand-derived from this item.

### 3.8 ASOF tolerance, and strict inequalities

- **Rule.** An ASOF join may carry a tolerance (an INT64 or FLOAT64 bound on `|left - right|`); a candidate outside it is no match, so in a LEFT ASOF join the right columns are NULL. The plan has no strict form (`<`, `>`): a frontend refuses one by name.
- **DuckDB.** No tolerance clause, and it accepts `>`, `<` as well as `>=`, `<=` ([FROM and JOIN](https://duckdb.org/docs/current/sql/query_syntax/from.html)). A tolerance case is still checkable: the oracle runs a LEFT ASOF join and sets the right columns to NULL where `|left - right|` exceeds the bound.
- **Current behaviour.** `AsofTolerance` with NONE / INT64 / FLOAT64 (`src/komira_plan_ir/logical_plan.mojo:513-520`).
- **Mark.** DEPARTS: the tolerance is a komira extension, and the missing strict forms are a narrowing refused by name.

### 3.9 Floating-point equi-join keys

- **Rule.** As join keys, floats compare under §2.6's model: NaN equals NaN and `-0.0` equals `+0.0`, so such rows match. A NULL key still matches nothing (§3.1).
- **DuckDB.** Inferred from its float equality (`NaN = NaN` is TRUE, [numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)) and from the hash join comparing keys with the same equality; the oracle measures it.
- **Current behaviour.** No join operator here; the float model lists the join-key and hash functions that use it (`src/komira_udf/float_quotient_order.mojo:53-75`).
- **Mark.** MATCHES.

## 4. Sort order and floating-point order

### 4.1 Default NULL placement

- **Rule.** Where a sort key does not state a placement, NULLs sort **last in both directions**. This applies to SORT, TOPN, PARTITION_TOPN and the ORDER BY of a window.
- **DuckDB.** "DuckDB keeps NULLS LAST even for DESC ordering, whereas PostgreSQL places NULLs first on DESC" ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)); `default_null_order` defaults to `NULLS_LAST` ([configuration](https://duckdb.org/docs/current/configuration/overview.html)). **pyarrow.** `sort_indices` puts nulls at the end by default ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).
- **Current behaviour.** `src/komira_plan_expr/null_order_policy.mojo:41-48` records the measurement against DuckDB 1.5.3 and pyarrow 24.0.0, and `derived_nulls_first` (`:80-93`) returns False for both directions.
- **Mark.** MATCHES.

### 4.2 Explicit NULL placement

- **Rule.** A sort key that states NULLS FIRST or NULLS LAST is sorted that way, whatever its direction. The plan carries the request per key (`SortData.nulls_first`, `TopNData.nulls_first`).
- **DuckDB.** `ORDER BY ... NULLS FIRST | NULLS LAST` ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)).
- **Current behaviour.** `src/komira_plan_expr/null_order_policy.mojo:63-69`: the default is consulted only where nobody asked.
- **Mark.** MATCHES.

### 4.3 NaN in a sort

- **Rule.** NaN is a value, not NULL. Ascending, NaN sorts after +inf; descending, before +inf. All NaNs tie. NULL placement (§4.1, §4.2) is independent of NaN: under NULLS LAST an ascending sort ends `..., +inf, NaN, NULL`.
- **DuckDB.** "NaN compares equal to NaN and greater than any other floating point number" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)). **pyarrow.** "NaN values are considered greater than any other non-null value, but smaller than nulls" ([compute functions](https://arrow.apache.org/docs/cpp/compute.html)).
- **Current behaviour.** The sort and top-N kernels use the float model (`src/komira_udf/float_quotient_order.mojo:68-70`); the sort operators themselves are not here.
- **Mark.** MATCHES.

### 4.4 Negative zero

- **Rule.** `-0.0` and `+0.0` tie in a sort and are equal as keys (§2.6). Their relative order after a sort is not promised.
- **DuckDB.** Not documented. Measured on 1.5.3 (`src/komira_udf/float_quotient_order.mojo:32-35`): `0.0 = -0.0` is TRUE and the two tie in ORDER BY.
- **Current behaviour.** As §2.6.
- **Mark.** MATCHES.

### 4.5 NaN in comparison predicates

- **Rule (proposed).** The comparison operators use the same model as sorting and grouping: `NaN = NaN` is TRUE, `NaN <> NaN` is FALSE, and `NaN > x` is TRUE for every non-NaN `x`, including +inf.
- **DuckDB.** As proposed ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)).
- **Current behaviour.** The comparison kernels are IEEE: every ordered comparison with a NaN operand is FALSE and `NaN <> x` is TRUE. `src/komira_column_kernels/comparison.mojo:316-325` records this as a known divergence from DuckDB, PostgreSQL and Spark SQL.
- **Options.** (a) Match DuckDB. (b) Keep IEEE comparisons and record the departure.
- **Recommendation.** (a). With (b), `WHERE v = v` drops NaN rows while `GROUP BY v` keeps them as one group, and a filter `v > 1e308` disagrees with `ORDER BY v` about where NaN is. One model for all four is the property the float model was written to give.
- **Mark.** UNDECIDED.

### 4.6 String order

- **Rule.** Strings sort by their UTF-8 bytes (binary collation). Binary values sort by bytes. A shorter string that is a prefix of a longer one sorts first.
- **DuckDB.** "Text is sorted using the binary comparison collation by default, which means values are sorted on their binary UTF-8 values" ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)).
- **Current behaviour.** The string sort kernels are not here.
- **Mark.** MATCHES.

### 4.7 Stability

- **Rule.** No sort is stable. Rows that tie on every sort key come out in an unspecified order, which may differ between runs, worker counts and batch sizes. TOPN and LIMIT over a sort with ties may return any of the tied rows at the boundary. A test either sorts on a total key or compares tied rows as a set.
- **DuckDB.** Does not document a stable sort. **pyarrow.** `sort_indices` is stable ("define a stable sort of the input", [compute functions](https://arrow.apache.org/docs/cpp/compute.html)); an expectation must not rely on that.
- **Current behaviour.** The row-format sort is stable (`src/komira_row_format/row_sort_perm.mojo:28-31`), but no plan-level guarantee is built on it.
- **Mark.** MATCHES.

### 4.8 Result order without ORDER BY

- **Rule.** A plan without a SORT (or TOPN) at its root promises no row order. Its result is compared as a multiset of rows. LIMIT without a sort below it returns any `n` rows of its input, and a test asserts only the count and that each row belongs to the input, or sorts first.
- **DuckDB.** Preserves order for some operators (a single-table scan, WHERE, LIMIT, UNION ALL) under `preserve_insertion_order`, and not for GROUP BY, joins, UNION or aggregates ([order preservation](https://duckdb.org/docs/current/sql/dialect/order_preservation.html)). The oracle's `threads = 1` and `preserve_insertion_order = true` make its own output repeatable; they do not make order part of the plan's contract.
- **Current behaviour.** Nothing in the plan IR claims an order for an unsorted plan.
- **Mark.** MATCHES.

## 5. Arithmetic

### 5.1 The plan's division operator on integers

- **Rule.** `BIN_DIV` over two integer operands is integer division that truncates toward zero, and its result is an integer (§8.9): `7 / 2` is 3 and `-7 / 2` is -3. This is DuckDB's `//`. A frontend whose `/` means true division (SQL, DuckDB, polars) casts the left operand to DOUBLE before building `BIN_DIV`. A frontend whose `//` floors (polars, pandas, Python: `-7 // 2` is -4) builds that from `BIN_DIV` and a correction, not from `BIN_DIV` alone. Over float operands `BIN_DIV` is IEEE division.
- **DuckDB.** `/` is floating-point division (`5 / 2 = 2.5`) and `//` is integer division ([numeric functions](https://duckdb.org/docs/current/sql/functions/numeric.html)). The sign of `//` for negative operands is not documented; measured on 1.5.3, `-7 // 2` is -3 (`src/komira_plan_expr/col_expr_division.mojo:5-17`).
- **Current behaviour.** The column kernel divides with Mojo's integer `/`, which truncates (`src/komira_column_kernels/arithmetic.mojo:675`); its header records the result-type divergence from DuckDB's `/` as deliberate (`:83-88`). The Mojo dataframe surface decides `/` against `//` in one place (`src/komira_plan_expr/col_expr_division.mojo:28-35`). Two other implementations floor ("Code that does not follow", item 1).
- **Mark.** DEPARTS: the plan has one division operator, and making it DuckDB's `/` would change the result type of every integer expression that divides. The frontends carry the difference.

### 5.2 Modulo sign

- **Rule.** `BIN_MOD` is the truncated remainder: its sign is the dividend's. `-7 % 2` is -1 and `7 % -2` is 1. `a = (a / b) * b + (a % b)` holds with §5.1's division.
- **DuckDB.** Not documented; measured on 1.5.3, `-7 % 2` is -1 (`src/komira_plan_expr/col_expr.mojo:852-856`). polars and Python floor instead (`-7 % 2` is 1).
- **Current behaviour.** No `BIN_MOD` column kernel is in this repository; the IR states the rule (`src/komira_plan_expr/col_expr.mojo:852-856`).
- **Mark.** MATCHES.

### 5.3 Integer division or modulo by zero

- **Rule.** An integer `BIN_DIV` or `BIN_MOD` whose divisor is zero answers NULL for that row. Other rows keep their values. No error is raised.
- **DuckDB.** Measured on 1.5.3 (`src/komira_column_kernels/arithmetic.mojo:74-78`): `qty // 0` and `qty % 0` are NULL. This holds through 1.5; on 2.0 the oracle sets `error_on_division_by_zero = false` (see the oracle settings). **pyarrow.** `divide` on integers raises on a zero divisor; it is not the oracle for this item.
- **Current behaviour.** `src/komira_column_kernels/arithmetic.mojo:572-580` and `:615-676` answer NULL per row. The expression executor raises instead ("Code that does not follow", item 1).
- **Mark.** MATCHES.

### 5.4 Signed MIN divided by -1

- **Rule.** `MIN / -1` for a signed integer type is an error ("Out of Range"), since the quotient is not representable.
- **DuckDB.** Measured on 1.5.3: `(-9223372036854775808) // (-1)` raises an Out of Range Error (`src/komira_column_kernels/arithmetic.mojo:74-80`).
- **Current behaviour.** `src/komira_column_kernels/arithmetic.mojo:111-130` raises when both operands of such a pair are valid.
- **Mark.** MATCHES.

### 5.5 Integer overflow

- **Rule.** Integer `+`, `-`, `*` and unary minus whose exact result does not fit the result type (§8.9) raise an error naming the operation, never wrap and never saturate.
- **DuckDB.** "Attempts to store values outside of the allowed range will result in an error" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)); measured on 1.5.3: `Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!` (`src/komira_scalar_arithmetic/int_overflow.mojo:11-17`). **pyarrow.** `add`, `subtract`, `multiply` wrap; only the `_checked` variants raise ([compute API](https://arrow.apache.org/docs/python/api/compute.html)). An oracle case uses the `_checked` variants or DuckDB.
- **Current behaviour.** `src/komira_scalar_arithmetic/int_overflow.mojo:1-25` is the one predicate; the column kernels raise (`src/komira_column_kernels/arithmetic.mojo:685-690`).
- **Mark.** MATCHES.

### 5.6 Float division by zero

- **Rule.** Float division by zero follows IEEE 754: `x / 0.0` is +inf or -inf by the signs of `x` and the zero, and `0.0 / 0.0` is NaN. No NULL and no error.
- **DuckDB.** `ieee_floating_point_ops` (default true): "Use IEE754-compliant floating point operations (returning NAN instead of errors/NULL)" ([configuration](https://duckdb.org/docs/current/configuration/overview.html)).
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
- **DuckDB.** A failed cast "throws an error by default"; `TRY_CAST` converts failures to NULL ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)).
- **Current behaviour.** `CastData.try_cast` selects the mode (`src/komira_plan_expr/expr.mojo:1638-1651`); a TRY_CAST result is typed nullable (`src/komira_plan_expr/expr_walk.mojo:1096-1114`).
- **Mark.** MATCHES.

### 6.2 Integer to narrower integer

- **Rule.** A value outside the target's range is an error (NULL under TRY_CAST). It is never truncated to its low bits.
- **DuckDB.** "Type INT32 with value 999 can't be cast because the value is out of range for the destination type INT8" ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)).
- **Current behaviour.** Two casts wrap ("Code that does not follow", item 4).
- **Mark.** MATCHES.

### 6.3 Float to integer

- **Rule.** A FLOAT or DOUBLE casts to an integer in two steps. First the **unrounded** value must lie in `[MIN, MAX + 1)` of the target type, otherwise the cast is an error; NaN and ±inf are errors. Then it rounds **half to even** (2.5 to 2, 3.5 to 4, -2.5 to -2). So `CAST(-2147483648.4 AS INTEGER)` is an error although it would round to INT32_MIN, and `CAST(-0.4 AS UTINYINT)` is an error although it would round to 0.
- **DuckDB.** "Casting from FLOAT and DOUBLE to integers of any size: round to the nearest integer, with ties (halfs) rounded to the nearest even number" ([numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html)). `TryCastWithOverflowCheckFloat` checks `value >= min && value < max` on the unrounded value and then calls `nearbyint` (`src/include/duckdb/common/operator/numeric_cast.hpp:75-85` at v1.5.6). A bare literal such as `2.5` is a DECIMAL in DuckDB and follows §6.4, so oracle SQL casts it to DOUBLE first (§8.19). **pyarrow.** A safe cast refuses a non-integral float; it is not the oracle.
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

- **Rule (proposed).** Leading and trailing ASCII whitespace is ignored; an optional `+` or `-` sign; decimal digits, leading zeros allowed. An empty or all-whitespace string, any other character, or a value out of range is an error (NULL under TRY_CAST). Beyond that, the grammar is DuckDB's (below) or the strict one, by ruling.
- **DuckDB.** `src/include/duckdb/common/operator/integer_cast_operator.hpp` at v1.5.6 also accepts:
  - a fractional part, rounded on its first digit away from zero: `'1.5'` is 2, `'-1.5'` is -2, `'1.4'` is 1;
  - an exponent: `'1e2'` is 100;
  - underscores between digits: `'1_000'` is 1000;
  - hexadecimal and binary prefixes: `'0x1F'` is 31, `'0b101'` is 5.

  The oracle measures each before a case relies on it.
- **Current behaviour.** `src/komira_kernels/cast_to_varchar_kernels.mojo:40-50` accepts only the strict grammar and rejects every DuckDB extension above, including `'1e2'`.
- **Options.** (a) DuckDB's grammar: accept all four extensions above. (b) Keep the strict grammar and record each difference as a departure.
- **Recommendation.** (a): these are the inputs a CSV with sloppy numbers produces, and an answer that differs from DuckDB on them is the kind a user meets first.
- **Mark.** UNDECIDED.

### 6.7 String to double out of range

- **Rule (proposed).** A string whose value is finite but outside DOUBLE's range (`'1e400'`) is an error, as an integer out of range is. `'inf'`, `'infinity'`, `'nan'` (any case, with an optional sign) parse to those values.
- **DuckDB.** Not documented. Likely a Conversion Error (inferred, not measured); the oracle measures it.
- **Current behaviour.** Saturates to ±inf (`src/komira_kernels/cast_to_varchar_kernels.mojo:48`); accepts the special spellings (`:47`).
- **Recommendation.** Match DuckDB, whichever it is, once measured.
- **Mark.** UNDECIDED.

### 6.8 Timestamp units

- **Rule (proposed).** The plan carries Arrow's four timestamp units (seconds, milliseconds, microseconds, nanoseconds), and DATE32 as days. Casting to a finer unit is exact or an error if out of range. Casting to a coarser unit follows DuckDB's measured rounding (truncation toward zero, or toward negative infinity for instants before the Unix epoch: this is the open question).
- **DuckDB.** `TIMESTAMP` is microseconds; `TIMESTAMP_S`, `TIMESTAMP_MS` and `TIMESTAMP_NS` are the other units ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)). The direction of rounding before the Unix epoch is not documented.
- **Current behaviour.** The field extracts accept all four units (`src/komira_kernels/temporal_extract.mojo:6-8`, `:1152`). No unit-changing timestamp cast kernel is in this repository.
- **Recommendation.** Measure DuckDB on an instant before the Unix epoch with a sub-unit part and adopt its rule.
- **Mark.** UNDECIDED.

### 6.9 Time zones

- **Rule (proposed).** A timestamp with a time zone is an instant (UTC ticks), and the zone is metadata on the column type. A timestamp without one is a wall-clock reading with no zone. There is one session time zone and it is UTC: field extraction (`year`, `hour`, ...) and `date_trunc` over a zoned timestamp operate on the UTC wall clock. Comparison and join of two zoned timestamps compare instants, whatever their zones. Mixing zoned and unzoned is §6.11.
- **DuckDB.** `TIMESTAMPTZ` stores "the INT64 number of non-leap microseconds since the Unix epoch"; extraction and rendering use the session `TimeZone` setting, which defaults to the system zone ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html), [configuration](https://duckdb.org/docs/current/configuration/overview.html)). With `TimeZone = 'UTC'`, DuckDB answers as proposed.
- **Current behaviour.** The zone travels on the field (`src/komira_kernels/join_key_envelope.mojo:319-330`; aliases keep it, `src/komira_plan_expr/expr_walk.mojo:740-750`). The extract kernels take no zone (`src/komira_kernels/temporal_extract.mojo:1152`), so they already answer in UTC.
- **Options.** (a) UTC session zone, as proposed. (b) A session zone setting carried in the plan. (c) Extract in the column's own zone.
- **Recommendation.** (a) now. (b) needs a wire field and is a later decision; (c) is not what DuckDB does.
- **Mark.** UNDECIDED.

### 6.10 CAST_TO_VARCHAR rendering

`PLAN_CAST_TO_VARCHAR` turns every column of a result into text before a text sink (CSV, JSON Lines) writes it (`src/komira_plan_ir/logical_plan.mojo:138-152`). Its rendering is what those files contain.

- **Rule (proposed).** Each type renders as DuckDB's `CAST(x AS VARCHAR)`:

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

- **DuckDB.** "Any type can be cast to VARCHAR" ([typecasting](https://duckdb.org/docs/current/sql/data_types/typecasting.html)); the ISO 8601 shape of timestamps and the offset rendering of zoned ones are documented ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)). The float and decimal spellings in the table are not documented and must be measured. **pyarrow.** `cast(double, string)` renders 1.0 as `1`; not followed.
- **Current behaviour.** Integers, booleans and strings render as in the table (`src/komira_kernels/cast_to_varchar_kernels.mojo:9-50`). Floats render with Mojo's `String(Float64)` (`:316-322`), which has not been compared with DuckDB. No DECIMAL, DATE or TIMESTAMP rendering kernel is in this repository.
- **Recommendation.** Adopt the table after the oracle has measured each float and decimal spelling, and test it with one case per row.
- **Mark.** UNDECIDED.

### 6.11 Mixing zoned and unzoned timestamps

- **Rule.** Comparing, joining or combining (CASE, UNION) a zoned timestamp with an unzoned one is refused by name; a frontend casts one side explicitly.
- **DuckDB.** Converts implicitly between TIMESTAMP and TIMESTAMPTZ through the session `TimeZone` ([timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)).
- **Current behaviour.** No such comparison kernel here.
- **Mark.** DEPARTS: a narrowing, refused by name; never a different value.

## 7. Strings

### 7.1 Length

- **Rule.** `length(s)` counts Unicode code points; `strlen(s)` counts bytes; `bit_length(s)` is 8 times `strlen(s)`. All three are INT64, and NULL for a NULL input. Grapheme-cluster counts are not offered.
- **DuckDB.** `length`: "Number of characters"; `strlen`: "Number of bytes" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)). DuckDB's `length_grapheme` has no plan counterpart. **pyarrow.** `utf8_length` counts code points and `binary_length` bytes.
- **Current behaviour.** `src/komira_plan_expr/expr.mojo:872-889` (`STRFN_LENGTH`) and `:902-910`; the grapheme functions are refused by name (`src/komira_sql/sql_fn_table.mojo:1029-1040`).
- **Mark.** MATCHES.

### 7.2 CONCAT

- **Rule.** `concat(a, b, ...)` skips NULL arguments and is never NULL: `concat('a', NULL, 'c')` is `'ac'` and `concat(NULL, NULL)` is `''`.
- **DuckDB.** "NULL inputs are skipped" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)); `concat(NULL, NULL)` measured as `''` (`src/komira_plan_expr/expr.mojo:1103-1110`).
- **Current behaviour.** `STRFNN_CONCAT` (`src/komira_plan_expr/expr.mojo:1103-1121`).
- **Mark.** MATCHES.

### 7.3 The `||` operator

- **Rule.** `a || b` is NULL if either operand is NULL. The plan has no `||` operator, and a frontend must not lower `||` to CONCAT (§7.2), whose NULL rule is the opposite. It lowers `a || b` to `CASE WHEN a IS NULL OR b IS NULL THEN NULL ELSE concat(a, b) END`.
- **DuckDB.** "Any NULL input results in NULL" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)).
- **Current behaviour.** No `||` in the plan or the SQL parser (`src/komira_plan_expr/expr.mojo:1110-1114`).
- **Mark.** MATCHES.

### 7.4 CONCAT_WS

- **Rule.** `concat_ws(sep, a, b, ...)`: a NULL separator makes the result NULL; a NULL argument is skipped together with its separator, so `concat_ws('-', 'a', NULL, 'c')` is `'a-c'` and `concat_ws('-', NULL, 'a')` is `'a'`.
- **DuckDB.** "NULL inputs are skipped" ([text functions](https://duckdb.org/docs/current/sql/functions/text.html)); the NULL-separator rule is measured on 1.5.3 (`src/komira_plan_expr/expr.mojo:1123-1137`).
- **Current behaviour.** `STRFNN_CONCAT_WS` (`src/komira_plan_expr/expr.mojo:1123-1137`).
- **Mark.** MATCHES.

### 7.5 CONCAT argument types

- **Rule.** Every argument of CONCAT and CONCAT_WS must be a string. Any other type is refused by name; a frontend that wants DuckDB's behaviour casts each argument to VARCHAR (§6.10) first.
- **DuckDB.** `concat` accepts any type and renders it (`concat(1, 'a', 2.5)` is `'1a2.5'`, measured, `src/komira_plan_expr/expr.mojo:1116-1121`).
- **Current behaviour.** As the rule (`src/komira_plan_expr/expr.mojo:1116-1121`).
- **Mark.** DEPARTS: a narrowing. The plan refuses where DuckDB converts, and never returns a different value.

### 7.6 LIKE

- **Rule.** `s LIKE p` matches the whole string. `%` matches any run of zero or more characters and `_` exactly one character (one code point). Every other pattern character, backslash included, matches itself. Matching is case-sensitive and byte-exact (no collation). A NULL operand gives NULL.
- **DuckDB.** "LIKE pattern matching always covers the entire string"; ILIKE is the case-insensitive form; an escape character exists only through the `ESCAPE` clause ([pattern matching](https://duckdb.org/docs/current/sql/functions/pattern_matching.html)).
- **Current behaviour.** `src/komira_column_kernels/string_comparison.mojo:1772-1822` (`_like_match`, `_` advances one code point) and `:1824-1830` ("no escape").
- **Mark.** MATCHES.

### 7.7 LIKE ESCAPE and ILIKE

- **Rule.** The plan's `STR_LIKE` (`src/komira_plan_expr/expr.mojo:807`) carries no escape character and no case-insensitive flag. A frontend refuses `ESCAPE` by name; ILIKE is refused, or lowered only by a frontend that states how it folds case.
- **DuckDB.** Both exist ([pattern matching](https://duckdb.org/docs/current/sql/functions/pattern_matching.html)).
- **Current behaviour.** The SQL parser refuses `ESCAPE` by name (`src/komira_sql/sql_parser.mojo:1520`); ILIKE is parsed into the SQL tree, and there is no plan operator for it.
- **Mark.** DEPARTS: a narrowing, refused by name.

### 7.8 Regular expressions

- **Rule.** The regular-expression functions use RE2's syntax and semantics over UTF-8: `.` and a character class match one character (code point); leftmost-first matching; no backreferences and no lookaround, which are errors at compile time. A malformed pattern is an error. `regexp_matches` (`regexp_like`) succeeds on a match anywhere; `regexp_full_match` needs the whole string. `regexp_replace` replaces the first match unless the `g` flag is given. By default `.` does not match a newline. The option flags are §7.10.
- **DuckDB.** Uses RE2; partial vs full match, first-occurrence replace and the `g` flag as stated ([regular expressions](https://duckdb.org/docs/current/sql/functions/regular_expressions.html)).
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
- **DuckDB.** As stated ([regular expressions](https://duckdb.org/docs/current/sql/functions/regular_expressions.html); the oracle confirms).
- **Current behaviour.** `src/komira_column_kernels/regexp_functions.mojo:434-440` answers `''`.
- **Mark.** MATCHES.

### 7.12 Empty string and NULL

- **Rule.** `''` is a value, distinct from NULL: `'' IS NULL` is FALSE, `length('')` is 0, and `''` and NULL are different grouping keys.
- **DuckDB.** The same.
- **Current behaviour.** A plan literal keeps `''` distinct from NULL (`src/komira_plan_expr/scalar_value.mojo:33-38`). The CSV writer renders NULL as an empty field (`src/komira_csv/csv_sink.mojo:32`), so a written CSV does not distinguish them.
- **Mark.** MATCHES.

### 7.13 Where readers turn an empty field into NULL

- **Rule (proposed).** As DuckDB's `read_csv` with default options: an empty unquoted field is NULL; a quoted empty field (`""`) is `''`. JSON `""` is `''` and JSON `null` is NULL. Columnar formats (Parquet, ORC, Arrow IPC, Avro) carry NULL explicitly and never convert.
- **DuckDB.** The CSV defaults are to be measured by the oracle.
- **Current behaviour.** The CSV format's blank-line policy is in the [text and row formats](text_and_row_formats.md) design doc; the empty-field rule is not stated there.
- **Recommendation.** Match DuckDB, measured, and state the rule in the formats doc.
- **Mark.** UNDECIDED.

### 7.14 No padding in string comparison

- **Rule.** Strings compare by their bytes with no trailing-space padding: `'a' = 'a '` is FALSE, and `'a' < 'a '`.
- **DuckDB.** Binary comparison of VARCHAR ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)); DuckDB has no padded CHAR semantics.
- **Current behaviour.** The string comparison kernels compare bytes (`src/komira_column_kernels/string_comparison.mojo`).
- **Mark.** MATCHES.

### 7.15 Invalid UTF-8

- **Rule (proposed).** A string column holds valid UTF-8. A reader that meets invalid UTF-8 in a string column raises an error naming the file and column; it does not repair or pass the bytes through. Binary columns are unaffected.
- **DuckDB.** Rejects invalid UTF-8 when reading into VARCHAR (the oracle measures the exact error).
- **Current behaviour.** The case-mapping kernels copy malformed bytes through (`src/komira_column_kernels/unicode_case.mojo:27-30`); whether each reader validates is not established here.
- **Recommendation.** Validate at the reader, as proposed, so that every string kernel may assume valid input.
- **Mark.** UNDECIDED.

## 8. Result types

The type of every result column is in [the result-type table](query_semantics_types.md), items §8.1 to §8.21. It is part of this document: its items are counted below and its open items are in "Rulings needed".

## 9. Window functions

### 9.1 Frames

- **Rule.** In the plan every window function carries its frame explicitly (ROWS or RANGE, with its two bounds); there is no plan-level default. A frontend fills in SQL's default:
- with an ORDER BY in the window, `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, where CURRENT ROW includes all peers of the current row, so rows tying on the order key get the same value;
- with no ORDER BY, the whole partition.
- **DuckDB.** As stated ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).
- **Current behaviour.** `PartitionFrame.running_range()` is the SQL default, and its docstring says why ROWS is wrong for it (`src/komira_plan_expr/partition_frame.mojo:114-130`). FIRST_VALUE, LAST_VALUE and NTH_VALUE default to it (`src/komira_plan_expr/partition_expr.mojo:226-255`); the `running_*` builders do not ("Code that does not follow", item 6).
- **Mark.** MATCHES.

### 9.2 Ranking and ties

- **Rule.** ROW_NUMBER numbers the rows of a partition 1 to n. RANK gives peers (rows tying on every order key) the row number of the first peer, leaving gaps. DENSE_RANK numbers peer groups 1, 2, 3 without gaps. Ranking functions ignore the frame.
- **DuckDB.** rank is "same as row_number of its first peer"; dense_rank "counts peer groups" ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).
- **Current behaviour.** Declared at `src/komira_plan_expr/partition_expr.mojo:44-46`; the window operator is not here.
- **Mark.** MATCHES.

### 9.3 ROW_NUMBER among peers

- **Rule.** Which peer gets which ROW_NUMBER is not specified (§4.7). A test fixes it with an order key that has no ties, or compares peers as a set.
- **DuckDB.** Not specified.
- **Current behaviour.** As §9.2.
- **Mark.** MATCHES.

### 9.4 LAG and LEAD

- **Rule.** The offset defaults to 1. Where the offset row does not exist, the result is the default value, and the default value defaults to NULL. An explicit NULL default is the same as no default. LAG and LEAD ignore the frame.
- **DuckDB.** The offset "defaults to 1"; the default "default to NULL" ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).
- **Current behaviour.** `src/komira_plan_expr/partition_expr.mojo:199-224` and `:371-384`.
- **Mark.** MATCHES.

### 9.5 IGNORE NULLS

- **Rule.** LAG and LEAD count every row, NULL or not. `IGNORE NULLS` is not in the plan vocabulary and a frontend refuses it by name.
- **DuckDB.** Supports `IGNORE NULLS` for lag and lead ([window functions](https://duckdb.org/docs/current/sql/functions/window_functions.html)).
- **Current behaviour.** No such field on `PartitionExpr` (`src/komira_plan_expr/partition_expr.mojo:110-150`).
- **Mark.** DEPARTS: a narrowing, refused by name.

### 9.6 NULL placement in a window's ORDER BY

- **Rule.** The window ORDER BY uses the default placement (§4.1) on every key; the plan cannot express another. A frontend refuses `NULLS FIRST` inside `OVER (...)` by name (and `NULLS LAST` is the default, so it may be accepted).
- **DuckDB.** Accepts an explicit placement in `OVER`.
- **Current behaviour.** The PARTITION_BY node carries no per-key placement (its wire arm has no such field), so the window key takes `derived_nulls_first` (`src/komira_plan_expr/null_order_policy.mojo:80-93`).
- **Mark.** DEPARTS: a narrowing, refused by name.

### 9.7 NULL order keys are peers

- **Rule.** Under a RANGE frame, rows whose order key is NULL are peers of one another: they form one peer group, placed by §4.1, and get the same running value.
- **DuckDB.** The same (NULLs compare equal for peer detection; the oracle confirms).
- **Current behaviour.** No window operator here.
- **Mark.** MATCHES.

### 9.8 RANGE frames with offsets

- **Rule (proposed).** `RANGE BETWEEN n PRECEDING AND m FOLLOWING` needs exactly one numeric or temporal order key. A row whose order key is NULL has as its frame the NULL peer group. The plan's offsets are INT64 (`src/komira_plan_expr/partition_frame.mojo:51-58`), so a fractional offset over a FLOAT key is refused by name, and NaN keys are peers of each other and sort per §4.3.
- **DuckDB.** Accepts fractional offsets over float keys; its frame for a NULL or NaN key is not documented and the oracle measures it.
- **Current behaviour.** No window operator here.
- **Options.** (a) As proposed, with fractional offsets refused. (b) Add FLOAT64 offsets to the plan and the wire.
- **Recommendation.** (a), and measure DuckDB's NULL and NaN frames before a case relies on them.
- **Mark.** UNDECIDED.

## 10. Excel error values

DuckDB has no error values, so nothing in this section has a DuckDB oracle. The authority is Microsoft's documented behaviour, and expectations are hand-derived from this section.

### 10.1 The code space

- **Rule.** The error values are Microsoft's list: `#DIV/0!`, `#N/A`, `#VALUE!`, `#REF!`, `#NAME?`, `#NUM!`, `#NULL!`, `#SPILL!`, `#CALC!`. There is no circular-reference error value: Excel reports a circular reference as a warning, and Microsoft documents no literal for it. An unrecognized `#...` literal is `#NAME?`. An error is a third state of a value, distinct from both a valid value and NULL (a blank cell).
- **Microsoft.** The error values and their meanings ([detect formula errors](https://support.microsoft.com/en-us/excel/detect-formula-errors-in-excel), [ERROR.TYPE](https://support.microsoft.com/en-us/office/error-type-function-10958677-7c8d-44f7-ae77-b9a9ee6eefaa)).
- **Current behaviour.** `src/komira_plan_expr/excel_error_code.mojo:28-38` still defines `XL_ERR_CIRCULAR = 10`, and the wire vocabulary has the matching enum member. `komira-ai/komira#662` removes the code and reserves its wire number. The three-state status lane is declared at `src/komira_plan_expr/excel_error_code.mojo:41-46`; it is not yet carried through columns and batches (`:16-20`).
- **Mark.** DEPARTS: there is no DuckDB counterpart; the list itself is already decided and needs only ratification here.

### 10.2 Propagation through scalar expressions

- **Rule (proposed).**
  1. An arithmetic operator, comparison or function with an error operand answers that error. With several error operands, the leftmost wins.
  2. An error dominates NULL: `#N/A + NULL` is `#N/A`.
  3. AND and OR do not short-circuit past an error: `FALSE AND #N/A` is `#N/A`, unlike §1.1's `FALSE AND NULL`.
  4. A conditional with an error condition answers the error; an error in an untaken branch has no effect.
  5. `IFERROR(x, y)` answers `y` for any error in `x`; `IFNA(x, y)` only for `#N/A`; `ISERROR`, `ISERR` and `ISNA` are total.
  6. In the spreadsheet surface, division by zero is `#DIV/0!`, not §5.3's NULL. That is the frontend's mapping; the plan's `BIN_DIV` keeps §5.3.
- **Microsoft.** Rule 1 is the documented behaviour for SUM and AVERAGE ("If AVERAGE or SUM refer to cells that contain #VALUE! errors, the formulas will result in a #VALUE! error", [correct a #VALUE! error in AVERAGE or SUM](https://support.microsoft.com/en-us/excel/how-to-correct-a-value-error-in-average-or-sum-functions)). The leftmost-wins rule and rule 3 are not documented and must be measured in Excel.
- **Current behaviour.** None: the propagation algebra is not implemented (`src/komira_plan_expr/excel_error_code.mojo:16-20`), and the comparison kernels reserve an error-dominant NULL policy that is not implemented (`src/komira_kernels/comparison_kleene.mojo:57-63`).
- **Options.** (a) The rules above, measured against Excel before ratification. (b) Treat an error as NULL inside the plan and restore it at the surface, which loses which error occurred.
- **Recommendation.** (a).
- **Mark.** UNDECIDED.

### 10.3 Errors in aggregates and sorts

- **Rule (proposed).**
- SUM, AVERAGE, MIN, MAX and the other numeric aggregates over a range containing an error answer the first error in input order.
- COUNT counts numbers only and skips errors; COUNTA counts non-blank cells, errors included.
- A sort orders numbers, then text, then logical values (FALSE before TRUE), then errors, all errors equal to one another; blanks (NULL) come last in both directions, which agrees with §4.1.
- **Microsoft.** The SUM/AVERAGE rule as in §10.2. The sort order: "All error values, such as #NUM! and #REF!, are equal", and "sort always puts blank cells last" in both directions ([sort data](https://support.microsoft.com/en-us/office/sort-data-in-a-workbook-in-the-browser-bf63427c-1b17-4ec5-a909-a5f2d07d924c)).
- **Current behaviour.** None.
- **Recommendation.** Adopt, with "first error in input order" measured in Excel before ratification.
- **Mark.** UNDECIDED.

## 11. Set operations and empty inputs

### 11.1 UNION ALL

- **Rule.** UNION ALL concatenates its inputs and keeps every row (bag semantics). The order of the output is not promised (§4.8). Every input has the same schema: same column count, names and types by position; the plan does not coerce.
- **DuckDB.** "UNION ALL" keeps all rows ([set operations](https://duckdb.org/docs/current/sql/query_syntax/setops.html)).
- **Current behaviour.** `LogicalPlan.union` builds UNION ALL and requires the caller to give every child the output schema; "the engine does not coerce" (`src/komira_plan_ir/logical_plan.mojo:1052-1068`).
- **Mark.** MATCHES.

### 11.2 UNION (distinct)

- **Rule.** UNION is UNION ALL followed by DISTINCT over all columns, with NULLs equal (§2.4) and floats under §2.6. A frontend builds it from the two plan nodes.
- **DuckDB.** "The vanilla UNION clause follows set semantics, therefore it performs duplicate elimination" ([set operations](https://duckdb.org/docs/current/sql/query_syntax/setops.html)).
- **Current behaviour.** UNION ALL and DISTINCT are separate plan nodes (`src/komira_plan_ir/logical_plan.mojo:97`, `:110`).
- **Mark.** MATCHES.

### 11.3 INTERSECT and EXCEPT

- **Rule (proposed).** INTERSECT and EXCEPT compare whole rows with NULLs equal, like DISTINCT, not with `=`. Without ALL they return distinct rows. With ALL they are bag operations: a row appearing `m` times on the left and `n` on the right appears `min(m, n)` times in INTERSECT ALL and `max(m - n, 0)` times in EXCEPT ALL.
- **DuckDB.** Both forms, set and bag ([set operations](https://duckdb.org/docs/current/sql/query_syntax/setops.html)); NULL handling is not documented there and the oracle measures it.
- **Current behaviour.** The plan has no set-operation node for them. A SEMI or ANTI join on `=` is **not** a lowering of them: it drops rows with a NULL in any column (§3.1), where INTERSECT and EXCEPT keep them.
- **Options.** (a) Frontends refuse INTERSECT and EXCEPT by name until a null-safe join key exists (§1.6 option b). (b) Add INTERSECT / EXCEPT [ALL] nodes to the plan and the wire.
- **Recommendation.** (a) now; (b) only if a surface needs them.
- **Mark.** UNDECIDED.

### 11.4 Column types across set-operation inputs

- **Rule.** Inputs of a set operation must already have identical column types. A frontend casts each input to the common type of §8.9 / §8.14 before building the node; the plan refuses a mismatch by name. Output column names are the first input's.
- **DuckDB.** "Implicit casting to one of the returned types is performed", and the result takes "the column names from the first query" ([set operations](https://duckdb.org/docs/current/sql/query_syntax/setops.html)).
- **Current behaviour.** As §11.1: no coercion in the plan.
- **Mark.** DEPARTS: a narrowing; the frontend inserts the casts DuckDB inserts implicitly.

### 11.5 UNION BY NAME

- **Rule.** UNION [ALL] BY NAME matches columns by name; a column missing from an input is NULL there. The plan has no BY NAME form: a frontend lowers it by projecting each input to the full, ordered column list, with NULL literals of the column's type for missing columns, then applies §11.1 or §11.2.
- **DuckDB.** Matches by name and fills missing columns with NULL ([set operations](https://duckdb.org/docs/current/sql/query_syntax/setops.html)).
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
- **DuckDB.** "addition of days (integers)": `DATE '1992-03-22' + 5` is `1992-03-27` ([date functions](https://duckdb.org/docs/current/sql/functions/date.html)); the out-of-range error is measured by the oracle.
- **Current behaviour.** No DATE arithmetic kernel was found by name in this repository.
- **Mark.** MATCHES.

### 12.2 DATE minus DATE

- **Rule.** `DATE - DATE` is the number of days between them, as INT64.
- **DuckDB.** `DATE '1992-03-27' - DATE '1992-03-22'` is `5` ([date functions](https://duckdb.org/docs/current/sql/functions/date.html)); its type, BIGINT, is confirmed by the oracle.
- **Current behaviour.** As §12.1.
- **Mark.** MATCHES.

### 12.3 Infinite dates and timestamps

- **Rule.** The plan has no infinite DATE or TIMESTAMP. Arrow's `date32` and `timestamp` carry plain integers with no infinity marker, so `infinity` and `-infinity` cannot be represented. A reader or cast that meets the text `infinity` for a DATE or TIMESTAMP column raises by name.
- **DuckDB.** Supports `infinity` and `-infinity`; "adding to or subtracting from infinite values produces the same infinite value" ([date functions](https://duckdb.org/docs/current/sql/functions/date.html), [timestamp types](https://duckdb.org/docs/current/sql/data_types/timestamp.html)). Oracle datasets contain no infinite values.
- **Current behaviour.** No infinity handling in the temporal kernels (`src/komira_kernels/temporal_extract.mojo`).
- **Mark.** DEPARTS: Arrow cannot represent the value; refused by name.

### 12.4 Out-of-range dates and timestamps

- **Rule.** Arithmetic or a cast whose result lies outside the target type's range (DATE32 days, or the timestamp unit's INT64 ticks) is an error, never a wrapped value.
- **DuckDB.** Raises an out-of-range error (the oracle measures the exact boundary, which for DuckDB's DATE is narrower than Arrow's `date32`).
- **Current behaviour.** No DATE arithmetic kernel here; the oracle cases stay inside DuckDB's range.
- **Mark.** MATCHES.

## Counts

MATCHES 81, DEPARTS 16, UNDECIDED 17: 114 marks, across this file and [the result-type table](query_semantics_types.md). Each numbered item counts once: every subsection that carries a **Mark** line, plus each row of the §8 table that has no subsection of its own (§8.10 repeats §5.1 and is not counted). The 33 rows of "Rulings needed" are the 16 DEPARTS and 17 UNDECIDED items.

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
- [Set operations](https://duckdb.org/docs/current/sql/query_syntax/setops.html)
- [Date functions](https://duckdb.org/docs/current/sql/functions/date.html)
- [Order preservation](https://duckdb.org/docs/current/sql/dialect/order_preservation.html)
- [DuckDB v1.5.6 source](https://github.com/duckdb/duckdb/tree/v1.5.6) and [duckdb/duckdb#25332](https://github.com/duckdb/duckdb/pull/25332)

Apache Arrow documentation:
- [Compute functions (C++)](https://arrow.apache.org/docs/cpp/compute.html)
- [pyarrow compute API](https://arrow.apache.org/docs/python/api/compute.html)
- [SetLookupOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.SetLookupOptions.html)

Microsoft documentation:
- [Detect formula errors in Excel](https://support.microsoft.com/en-us/excel/detect-formula-errors-in-excel)
- [ERROR.TYPE function](https://support.microsoft.com/en-us/office/error-type-function-10958677-7c8d-44f7-ae77-b9a9ee6eefaa)
- [How to correct a #VALUE! error in AVERAGE or SUM](https://support.microsoft.com/en-us/excel/how-to-correct-a-value-error-in-average-or-sum-functions)
- [Sort data in a workbook](https://support.microsoft.com/en-us/office/sort-data-in-a-workbook-in-the-browser-bf63427c-1b17-4ec5-a909-a5f2d07d924c)
