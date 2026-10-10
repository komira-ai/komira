# Query semantics: rulings, parity gaps and code status

This file belongs to [query semantics](query_semantics.md), whose governing rule, conventions, oracle settings and counts apply. It records how each item that was open or departed before the rule is settled, lists the parity gaps with their issues, and lists the code that does not yet follow a settled rule. The items themselves are in the main document, [result types](query_semantics_types.md), [further items](query_semantics_more.md) and [scans](query_semantics_scans.md).

## Rulings

The governing rule, same SQL, same result as DuckDB, was ruled by the maintainers on 2026-10-09. It settles every item below: an open question resolves to DuckDB's answer, a departure stays only where Arrow cannot hold DuckDB's type, something komira does not support yet is a parity gap, and a plan feature with no DuckDB SQL equivalent is an extension. Items already marked MATCHES kept their mark; three of them (§2.14, §8.19, §12.4) had their rule brought to DuckDB's answer and are listed below. The oracle stays pinned at DuckDB v1.5.6, with the division-by-zero setting the main document states for 2.0 and later.

| Item | Topic | Mark | Ruling |
|---|---|---|---|
| §1.6 | `IS [NOT] DISTINCT FROM` | PARITY GAP | DuckDB's null-safe equality, as a value and as a join key; refused by name until the plan has it ([komira#1218](https://github.com/komira-ai/komira/issues/1218)). |
| §2.8 | MEDIAN and quantiles over NaN | MATCHES | NaN takes part (it sorts above +inf); an all-NaN group answers NaN. |
| §2.14 | MEDIAN interpolation | MATCHES | DuckDB's formula `lo + d * (hi - lo)`, including its answers at infinite and near-overflow pairs. |
| §3.7 | ASOF `NEAREST` | EXTENSION | No DuckDB SQL reaches it; expectations are hand-derived from the item. |
| §3.8 | ASOF tolerance; strict `<` / `>` ASOF | PARITY GAP | The strict forms answer as DuckDB's and are refused by name until built ([komira#1219](https://github.com/komira-ai/komira/issues/1219)); the tolerance is an extension. |
| §3.14 | Join output name collisions | MATCHES | The SQL frontend aliases so a query's names are DuckDB's; `_right` stays inside the plan and the dataframe surfaces. |
| §3.16 | EXISTS outside a filter conjunct | PARITY GAP | A non-nullable BOOLEAN, as DuckDB's MARK join gives; refused by name until the plan has one ([komira#1220](https://github.com/komira-ai/komira/issues/1220)). |
| §3.19 | Two right rows tied on the ASOF key in one group | MATCHES | The row DuckDB returns, measured; any tied row if DuckDB's choice depends on input order. |
| §4.5 | NaN in comparison predicates | MATCHES | `NaN = NaN` is TRUE and `NaN > x` is TRUE for every non-NaN `x`: one float model for comparisons, sorting and grouping. |
| §4.9 | Zeros and NaNs in a sorted column | MATCHES | A float sort key comes back with `-0.0` as `0.0`, as DuckDB returns it; other values unchanged. |
| §5.1 | `BIN_DIV` on two integers | MATCHES | At the SQL surface: the plan's operator is DuckDB's `//`, and the frontend lowers `/` to a DOUBLE division. |
| §6.6 | String-to-integer grammar | MATCHES | DuckDB's grammar with all its extensions, each measured. |
| §6.7 | String-to-double out of range | MATCHES | DuckDB's answer, measured (expected: an error). |
| §6.8 | Casts between timestamp units | MATCHES | DuckDB's rounding, measured before the Unix epoch; out of range is an error. |
| §6.9 | Time zones and the session zone | MATCHES | DuckDB with `TimeZone = 'UTC'`, the oracle's setting. |
| §6.10 | CAST_TO_VARCHAR rendering | MATCHES | DuckDB's `CAST(x AS VARCHAR)` per type, measured row by row. |
| §6.11 | Zoned with unzoned timestamps | PARITY GAP | DuckDB's implicit conversion through the session zone; refused by name until built ([komira#1221](https://github.com/komira-ai/komira/issues/1221)). |
| §7.5 | CONCAT with non-string arguments | PARITY GAP | DuckDB's rendering of each argument; refused by name until built ([komira#1223](https://github.com/komira-ai/komira/issues/1223)). |
| §7.7 | LIKE `ESCAPE` and ILIKE | PARITY GAP | DuckDB's meaning; refused by name until the plan carries them ([komira#1224](https://github.com/komira-ai/komira/issues/1224)). |
| §7.13 | Readers: empty field vs NULL | MATCHES | DuckDB's `read_csv` defaults, measured. |
| §7.15 | Invalid UTF-8 in a string column | MATCHES | The reader raises by name, as DuckDB does, measured per reader. |
| §7.16 | SUBSTRING with a negative start or length | MATCHES | DuckDB's meaning; the two-argument form gets its own encoding. |
| §8.1 | SUM of a signed integer or BOOLEAN | REPRESENTATION DEPARTURE | INT64 in place of HUGEINT; a total outside INT64 is an error naming the column. |
| §8.2 | SUM of an unsigned integer | REPRESENTATION DEPARTURE | UINT64 in place of HUGEINT, with §8.1's overflow error. |
| §8.9 | Result type of integer and mixed arithmetic | MATCHES | DuckDB's narrowest common type; "left operand wins" is retired. |
| §8.11 | Decimal addition and subtraction | MATCHES | DuckDB's precision and scale, including its 18-digit case and its overflow error. |
| §8.12 | Decimal multiplication | MATCHES | DuckDB's precision and scale, including its 18-digit case; the code's `+ 1` goes. |
| §8.14 | Result type of CASE and COALESCE | MATCHES | DuckDB's combination type; mixes DuckDB refuses are refused by name. |
| §8.17 | MEDIAN of FLOAT32, DECIMAL, DATE | MATCHES | FLOAT32, the same DECIMAL, TIMESTAMP, as DuckDB. |
| §8.18 | `uint64` with a signed integer | REPRESENTATION DEPARTURE | Refused by name: DuckDB's HUGEINT has no Arrow type. |
| §8.19 | Type of a SQL literal | MATCHES | DuckDB's type for the literal's spelling: `2.5` is DECIMAL(2,1). |
| §9.5 | `IGNORE NULLS` | PARITY GAP | DuckDB's meaning; refused by name until the plan carries it ([komira#1226](https://github.com/komira-ai/komira/issues/1226)). |
| §9.6 | Explicit NULL placement in a window's ORDER BY | PARITY GAP | DuckDB's meaning; `NULLS FIRST` in `OVER` refused by name until built ([komira#1227](https://github.com/komira-ai/komira/issues/1227)). |
| §9.8 | RANGE frames with offsets | MATCHES | DuckDB's frames, NULL and NaN keys measured; non-integer offsets refused by name until built ([komira#1228](https://github.com/komira-ai/komira/issues/1228)). |
| §11.3 | INTERSECT and EXCEPT | PARITY GAP | DuckDB's set and bag forms, NULLs equal; refused by name until the plan has them ([komira#1229](https://github.com/komira-ai/komira/issues/1229)). |
| §11.4 | Set-operation inputs: types and names | MATCHES | At the SQL surface: the frontend inserts DuckDB's implicit casts and takes the first query's names. |
| §12.3 | Infinite dates and timestamps | REPRESENTATION DEPARTURE | Arrow cannot represent them; refused by name. |
| §12.4 | Out-of-range dates and timestamps | MATCHES | DuckDB's range for each type and DuckDB's error outside it, not Arrow's wider range. |
| §13.5 | Avro logical and complex types | MATCHES | DuckDB's default mapping; the types komira cannot read yet are refused by name ([komira#1230](https://github.com/komira-ai/komira/issues/1230)). |
| §13.7 | JSON value of another type than its column | PARITY GAP | DuckDB's `read_json` conversions, measured; refused by name until built ([komira#1231](https://github.com/komira-ai/komira/issues/1231)). |
| §13.9 | A repeated JSON key the schema reads | PARITY GAP | `read_json`'s default, measured; komira refuses today ([komira#1232](https://github.com/komira-ai/komira/issues/1232)). |
| §13.10 | Non-nullable declared column over a file holding NULL | EXTENSION | The reader raises naming the column and row; no DuckDB SQL reaches it. |

## Parity gaps

Each gap is refused by name today and must answer as DuckDB does once built; its issue tracks the work, and the item's mark becomes MATCHES when it lands. Rows for §7.1, §8.15, §9.8 and §13.5 are refused cases inside items whose rule otherwise holds. "Blocks" names the TPC-H, TPC-DS and ClickBench queries known to use the feature, from their published texts; "none known" is the absence of a known use, not a survey of every query.

| Item | Gap | Issue | Blocks |
|---|---|---|---|
| §1.6, §3.17 | `IS [NOT] DISTINCT FROM`, and null-safe equi-join and ASOF keys | [komira#1218](https://github.com/komira-ai/komira/issues/1218) | none known |
| §3.8 | Strict ASOF inequalities `<` and `>` | [komira#1219](https://github.com/komira-ai/komira/issues/1219) | none known |
| §3.16 | EXISTS and NOT EXISTS as values (MARK join) | [komira#1220](https://github.com/komira-ai/komira/issues/1220) | TPC-DS q10, q35 (EXISTS under OR) |
| §6.11 | Comparing and combining TIMESTAMP with TIMESTAMPTZ | [komira#1221](https://github.com/komira-ai/komira/issues/1221) | none known |
| §7.1 | Grapheme-cluster functions: `length_grapheme`, `left_grapheme`, `right_grapheme`, `substring_grapheme` | [komira#1222](https://github.com/komira-ai/komira/issues/1222) | none known |
| §7.5 | CONCAT and CONCAT_WS over non-string arguments | [komira#1223](https://github.com/komira-ai/komira/issues/1223) | none known |
| §7.7 | ILIKE and `LIKE ... ESCAPE` | [komira#1224](https://github.com/komira-ai/komira/issues/1224) | none known |
| §8.15 | EXTRACT and `date_part` of `epoch` and `julian` (DOUBLE) | [komira#1225](https://github.com/komira-ai/komira/issues/1225) | none known |
| §9.5 | `IGNORE NULLS` for LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE | [komira#1226](https://github.com/komira-ai/komira/issues/1226) | none known |
| §9.6 | `NULLS FIRST` / `NULLS LAST` inside a window's ORDER BY | [komira#1227](https://github.com/komira-ai/komira/issues/1227) | none known |
| §9.8 | RANGE frames with fractional and interval offsets | [komira#1228](https://github.com/komira-ai/komira/issues/1228) | none known |
| §11.3 | INTERSECT and EXCEPT, with and without ALL | [komira#1229](https://github.com/komira-ai/komira/issues/1229) | TPC-DS q8, q14, q38 (INTERSECT); q87 (EXCEPT) |
| §13.5 | Avro `enum`, `uuid`, `duration`, `timestamp-nanos`, unions, records, arrays, maps | [komira#1230](https://github.com/komira-ai/komira/issues/1230) | none known |
| §13.7 | JSON values of another type than the column, converted as `read_json` does | [komira#1231](https://github.com/komira-ai/komira/issues/1231) | none known |
| §13.9 | A repeated JSON key, read as `read_json`'s default | [komira#1232](https://github.com/komira-ai/komira/issues/1232) | none known |

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
13. **Window function nullability and SUM types (§8.25 to §8.27).** `partition_expr_output_field` (`src/komira_plan_expr/partition_expr.mojo:404-505`) declares windowed SUM and AVG non-nullable (`:471-488`) whatever the input's nullability and the frame, though a frame holding only NULLs, or no rows, gives NULL (§8.26 allows non-nullable only for a non-nullable input over a frame that always contains the current row); types a windowed SUM of DECIMAL or of an unsigned integer as FLOAT64 (`:471-480`), where §8.2 and §8.4 give UINT64 and DECIMAL(38, s); and gives windowed MIN/MAX and FIRST_VALUE/LAST_VALUE the input's nullability (`:463`, `:489-496`), which is sound only for frames that always contain the current row (§8.25, §8.26); over a frame that can be empty the result must be nullable.
14. **UNION refuses branches that differ only in nullability (§11.7).** The wire's check compares name, type and nullability (`src/komira_plan_wire/plan_wire_codec.mojo:3540-3556`), and `LogicalPlan.union` requires every child to advertise the output schema exactly.
15. **A scan drops a projected name its schema lacks (§13.2).** `LogicalPlan.scan_from_source` and the positional `scan` factory skip it silently (`src/komira_plan_ir/logical_plan.mojo:925-930`, `:775-780`); only the wire's value gate refuses it.
16. **MEDIAN excludes NaN (§2.8).** `src/komira_op_agg_state/columnar_acc_agg.mojo:79-82` drops NaN rows and answers NULL for an all-NaN group; the rule keeps NaN and answers NaN.
17. **IEEE comparisons over NaN (§4.5).** The comparison kernels answer FALSE for every ordered comparison with a NaN and TRUE for `NaN <> x` (`src/komira_column_kernels/comparison.mojo:316-325`); the rule is DuckDB's, where `NaN = NaN` is TRUE.
18. **The strict string-to-integer grammar (§6.6).** `src/komira_kernels/cast_to_varchar_kernels.mojo:40-50` rejects DuckDB's fractional, exponent, underscore, hexadecimal and binary forms.
19. **String-to-double saturates (§6.7).** `src/komira_kernels/cast_to_varchar_kernels.mojo:48` gives ±inf for an out-of-range value, unless the oracle shows DuckDB does the same.
20. **SUBSTRING with a negative start or length (§7.16).** The IR defines the standard-SQL meaning (`src/komira_plan_expr/expr.mojo:1821-1838`), so `substring('hello', -1, 3)` is `'h'` where the rule gives `'o'`, and a negative `length` is the two-argument sentinel.
21. **"Left operand wins" in arithmetic result types (§8.9).** `src/komira_plan_expr/expr_walk.mojo:968-975` and `src/komira_plan_expr/typed_schema.mojo:1296-1325`.
22. **Decimal addition, subtraction and multiplication types (§8.11, §8.12).** `src/komira_scalar_arithmetic/decimal_arith.mojo:150-183` has no 18-digit case, and multiplication adds 1 to the precision.
23. **CASE and COALESCE take the first branch's type (§8.14).** `src/komira_plan_expr/expr_walk.mojo:1146-1159`.
24. **MEDIAN is typed FLOAT64 for every input (§8.17).** `src/komira_plan_expr/typed_schema.mojo:1173-1180`, with a Float64 accumulator (`src/komira_op_agg_state/columnar_acc_agg.mojo:60-80`).
25. **Avro timestamps with the adjust-to-UTC flag read unzoned (§13.5).** `src/komira_avro/avro_schema.mojo:1009-1020`; DuckDB reads them zoned, once the oracle confirms it.
26. **MEDIAN interpolates with another formula (§2.14).** `src/komira_op_agg_state/columnar_acc_agg.mojo:255` returns `lower * (1 - frac) + upper * frac`; the rule is DuckDB's `lo + d * (hi - lo)`. They differ at the extremes: a middle pair (+inf, +inf) answers inf where the rule gives NaN, and (-DBL_MAX, DBL_MAX) answers 0 where the rule gives +inf.
27. **A DATE result outside DuckDB's range is not an error (§12.4).** The DATE `date_trunc` kernel converts with `Int32(trunc_days)` and no range check (`src/komira_kernels/temporal_extract.mojo:986`), so a truncation below the first `date32` day wraps; nothing checks a result against DuckDB's narrower DATE range. The rule is DuckDB's range and DuckDB's error.
28. **The SQL parser reads a decimal literal as a Float64 (§8.19).** `src/komira_sql/sql_parser.mojo:2322-2325` builds `SqlExpr.float_lit` from the token's `float_val`, so `2.5` loses its digits before binding; the rule types it as DuckDB does, DECIMAL(2,1).
29. **Avro `uuid`, `timestamp-nanos` and reader-schema `enum` read as values instead of being refused (§13.5).** `uuid` reads as STRING or BINARY (`src/komira_avro/avro_schema.mojo:1024-1033`, `src/komira_avro/action_table.mojo:400-408`); `timestamp-nanos` falls through to INT64 (`src/komira_avro/avro_schema.mojo:1034`); an `enum` read through a reader schema returns a STRING column (`src/komira_avro/action_table.mojo:2320-2340`). DuckDB reads them as UUID, TIMESTAMP_NS and ENUM; until komira does, the rule refuses each by name ([komira#1230](https://github.com/komira-ai/komira/issues/1230)).
