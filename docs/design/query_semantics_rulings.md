# Query semantics: rulings and code status

This file belongs to [query semantics](query_semantics.md), whose conventions, oracle settings and counts apply. It holds the table of items that need a ruling and the list of code that does not yet follow a settled rule. The items themselves are in the main document, [result types](query_semantics_types.md), [further items](query_semantics_more.md) and [scans](query_semantics_scans.md).

## Rulings needed

Every DEPARTS and UNDECIDED item, with the recommendation. A ruling either accepts the recommendation or names another option; the item's mark then changes to MATCHES or DEPARTS and the ruling is recorded beside it.

| Item | Topic | Mark | Recommendation |
|---|---|---|---|
| §1.6 | `IS [NOT] DISTINCT FROM` | UNDECIDED | Frontends desugar it to `IS NULL` / `=` combinations now; add plan operators only when a null-safe join key needs one. |
| §2.8 | MEDIAN and quantiles over NaN | UNDECIDED | Match DuckDB: NaN is a value and takes part (it sorts above +inf); an all-NaN group answers NaN, not NULL. |
| §3.7 | ASOF `NEAREST`, ties to the earlier row | DEPARTS | Accept: DuckDB has no NEAREST; keep it as a komira extension with hand-derived expectations citing this item. |
| §3.8 | ASOF tolerance; no strict `<` / `>` ASOF | DEPARTS | Accept: the tolerance is a komira extension (the oracle checks it with a LEFT ASOF join and NULLing); strict forms are refused by name. |
| §3.14 | Join output name collisions | DEPARTS | Accept: a right column colliding with a left one becomes `<name>_right`; a second collision is refused by name; oracle queries alias every column. |
| §3.16 | EXISTS outside a filter conjunct | DEPARTS | Accept for now: frontends refuse it by name until the plan has a MARK join; then EXISTS as a value is a non-nullable BOOLEAN. |
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
| §7.16 | SUBSTRING with a negative start or length | UNDECIDED | (a) DuckDB's meaning (negative start counts from the end, negative length goes backwards), with the two-argument form encoded without the `length < 0` sentinel. |
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
| §11.4 | Set-operation inputs must have identical types and names | DEPARTS | Accept: the frontend inserts the casts DuckDB inserts implicitly. |
| §12.3 | No infinite dates or timestamps | DEPARTS | Accept: Arrow cannot represent them; refused by name. |
| §13.5 | Avro logical and complex types | UNDECIDED | DuckDB's default: `timestamp-*` and `local-timestamp-*` unzoned, `enum` as STRING; refuse `uuid`, `duration`, `timestamp-nanos`, multi-type unions and nested types by name. Reading `timestamp-*` as zoned would depart from DuckDB. |
| §13.7 | JSON value of another type than its column | UNDECIDED | Cast a numeric string through §6.6's string cast, as DuckDB does; refuse the other mismatches by name unless the oracle shows DuckDB converts them. |
| §13.9 | A repeated JSON key the schema reads | UNDECIDED | Match `read_json`'s default once measured: first occurrence wins if `error_duplicate_key` is off, an error if it is on. |
| §13.10 | Non-nullable declared column over a file holding NULL | DEPARTS | Accept: the reader raises naming the column and row; DuckDB has no declared nullability. |

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
12. **Join output schema (§3.13, §3.14).** `LogicalPlan.join` (`src/komira_plan_ir/logical_plan.mojo:1255-1273`) keeps each side's input nullability for the padded side of LEFT, RIGHT and FULL joins, so a padded NULL lands in a column declared non-nullable; and it checks a right column's name only against left names before appending `_right`, so `a`, `a_right` on the left with `a` on the right, or `a` on the left with `a`, `a_right` on the right, yields two columns named `a_right`. The comparison is case-sensitive, so `A` and `a` do not collide.
13. **Window function nullability and SUM types (§8.25 to §8.27).** `partition_expr_output_field` (`src/komira_plan_expr/partition_expr.mojo:404-505`) declares windowed SUM and AVG non-nullable (`:471-488`), though a frame holding only NULLs, or no rows, gives NULL; types a windowed SUM of DECIMAL or of an unsigned integer as FLOAT64 (`:471-480`), where §8.2 and §8.4 give UINT64 and DECIMAL(38, s); and gives windowed MIN/MAX and FIRST_VALUE/LAST_VALUE the input's nullability (`:463`, `:489-496`), which is sound only for frames that always contain the current row.
14. **UNION refuses branches that differ only in nullability (§11.7).** The wire's check compares name, type and nullability (`src/komira_plan_wire/plan_wire_codec.mojo:3540-3556`), and `LogicalPlan.union` requires every child to advertise the output schema exactly.
15. **A scan drops a projected name its schema lacks (§13.2).** `LogicalPlan.scan_from_source` and the positional `scan` factory skip it silently (`src/komira_plan_ir/logical_plan.mojo:925-930`, `:775-780`); only the wire's value gate refuses it.
