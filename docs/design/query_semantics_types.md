# Query semantics: result types

This is section 8 of [query semantics](query_semantics.md): the conventions, the marks, the oracle settings are there, the rulings and parity gaps are in [rulings, parity gaps and code status](query_semantics_rulings.md), and its counts include the items here.

The table is the authority for the type of every result column. A conformance case asserts that the actual schema equals the expected schema, and the expected schema comes from this table, not from the plan's own `output_schema`. When the two disagree, that is a question for review, not a reason to edit the expectation. Unless a row says otherwise, every result is nullable. Only the rows that say so are declared non-nullable: COUNT (§8.6), a non-NULL literal (§8.19), IS [NOT] NULL (§8.21), the ranking functions (§8.22, §8.23), LAG/LEAD and FIRST/LAST_VALUE under the conditions in §8.24 and §8.25, and windowed COUNT (§8.27). Declaring a column nullable that never holds a NULL is sound; the reverse is a defect. Declared nullability is hand-derived from this table and never compared with the oracle: DuckDB's result types carry no nullability. "DuckDB" means v1.5.6; a row resting on DuckDB's source cites the [v1.5.6 tag](https://github.com/duckdb/duckdb/tree/v1.5.6).

| Item | Expression | Result type | DuckDB | Mark |
|---|---|---|---|---|
| §8.1 | `SUM(int8 / int16 / int32 / int64)`, `SUM(boolean)` | INT64; a total outside INT64 is an error | HUGEINT | REPRESENTATION DEPARTURE |
| §8.2 | `SUM(uint8 / uint16 / uint32 / uint64)` | UINT64; overflow is an error | HUGEINT | REPRESENTATION DEPARTURE |
| §8.3 | `SUM(float32 / float64)` | FLOAT64 | DOUBLE | MATCHES |
| §8.4 | `SUM(decimal(p, s))` | DECIMAL(38, s) | DECIMAL(38, s) | MATCHES |
| §8.5 | `AVG` of any integer, float or DECIMAL; `STDDEV_*`, `VAR_*`, `CORR` | FLOAT64 | DOUBLE | MATCHES |
| §8.6 | `COUNT(*)`, `COUNT(col)`, `COUNT(DISTINCT col)` | INT64, never NULL | BIGINT | MATCHES |
| §8.7 | `MIN`, `MAX`, `FIRST`, `LAST`, `ANY_VALUE` (BOOLEAN included, FALSE < TRUE) | the input's type | the input's type | MATCHES |
| §8.8 | comparisons, AND, OR, NOT, IN, LIKE | BOOLEAN, nullable | BOOLEAN | MATCHES |
| §8.9 | integer and mixed arithmetic | see §8.9 | see §8.9 | MATCHES |
| §8.10 | `int / int` (`BIN_DIV`) | the integer type (§5.1) | DOUBLE for `/`, integer for `//` | MATCHES at the SQL surface (§5.1, not counted again) |
| §8.11 | `decimal ± decimal` | with w = max(p1-s1, p2-s2) + max(s1, s2) + 1: DECIMAL(18, max(s1, s2)) when w exceeds 18 and both inputs are at most 18, with a runtime overflow error; otherwise DECIMAL(min(w, 38), max(s1, s2)) | the same | MATCHES |
| §8.12 | `decimal * decimal` | see §8.12 | see §8.12 | MATCHES |
| §8.13 | `decimal / decimal`, `decimal / int64` | FLOAT64 | DOUBLE | MATCHES |
| §8.14 | `CASE`, `COALESCE` | see §8.14 | the combination type | MATCHES |
| §8.15 | `length`, `strlen`, `strpos`, the EXTRACT fields the plan has, `dayofweek` | INT64 | BIGINT | MATCHES |
| §8.16 | `MEDIAN`, `QUANTILE_CONT` of an integer or FLOAT64 | FLOAT64 | DOUBLE | MATCHES |
| §8.17 | `MEDIAN` of FLOAT32, DECIMAL or DATE | FLOAT32, the same DECIMAL, TIMESTAMP | FLOAT, the same DECIMAL, TIMESTAMP | MATCHES |
| §8.18 | `uint64` with any signed integer, in arithmetic or a combination | refused by name | HUGEINT | REPRESENTATION DEPARTURE |
| §8.19 | a literal | its declared plan type, which for a SQL literal is DuckDB's type for its spelling; non-nullable unless it is the NULL literal | by spelling: `1` INTEGER, `2.5` DECIMAL(2,1) | MATCHES |
| §8.20 | `decimal(p, s) ± int64`; `decimal * int64`; `decimal / int64` | DECIMAL(min(max(p-s, 19) + s + 1, 38), s); §8.12 with the INT64 as DECIMAL(19, 0); FLOAT64 | the same | MATCHES |
| §8.21 | `IS NULL`, `IS NOT NULL` | BOOLEAN, never NULL (non-nullable) | BOOLEAN, never NULL | MATCHES |
| §8.22 | `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE(n)` | INT64, never NULL (non-nullable); NTILE's `n` is a positive constant, `n <= 0` is an error | BIGINT | MATCHES |
| §8.23 | `PERCENT_RANK`, `CUME_DIST` | FLOAT64, never NULL (non-nullable) | DOUBLE | MATCHES |
| §8.24 | `LAG`, `LEAD` | the input column's type; non-nullable only when the input is non-nullable **and** a non-NULL default is given, otherwise nullable | the input's type | MATCHES |
| §8.25 | `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE` | the input column's type; FIRST/LAST_VALUE non-nullable only when the input is non-nullable and the frame always contains the current row (true only while the plan has no EXCLUDE clause); NTH_VALUE nullable | the input's type | MATCHES |
| §8.26 | windowed `SUM`, `AVG`, `MIN`, `MAX` | the aggregate's type (§8.1 to §8.5, §8.7); nullable unless the input is non-nullable and the frame always contains the current row (true only while the plan has no EXCLUDE clause) | the aggregate's type | MATCHES |
| §8.27 | windowed `COUNT` | INT64, never NULL (0 over an empty frame) | BIGINT | MATCHES |
| §8.28 | `concat(a, ...)` | STRING, never NULL (declaring it nullable is sound) | VARCHAR, never NULL | MATCHES |
| §8.29 | `concat_ws(sep, a, ...)` | STRING; NULL exactly when `sep` is NULL; `''` when every value argument is NULL | VARCHAR, the same | MATCHES |
| §8.30 | `upper(s)`, `lower(s)`, `trim(s)`, `ltrim(s)`, `rtrim(s)`, `substring(s, start, length)` (start and length are plan constants) | STRING; NULL exactly when `s` is NULL | VARCHAR, the same | MATCHES |
| §8.31 | `replace(s, source, target)` (three column arguments) | STRING; NULL when any of `s`, `source`, `target` is NULL | VARCHAR, the same | MATCHES |

Notes:

- **§8.1, §8.2 (REPRESENTATION DEPARTURE).** Arrow has no 128-bit integer type, and returning DECIMAL(38, 0) would change every integer total's type in every consumer. The engine refuses a total outside INT64 by name rather than wrap (`src/komira_op_agg_state/int_sum_overflow.mojo:31-41`, which also records DuckDB's `typeof(sum(<bigint>))` as HUGEINT). DuckDB's `sum(BOOLEAN)` is HUGEINT too (`extension/core_functions/aggregate/distributive/sum.cpp:163-164` at v1.5.6). An oracle query states the plan's type explicitly (`CAST(sum(x) AS BIGINT)`). The plan's rule is at `src/komira_plan_ir/logical_plan.mojo:2411-2470`.
- **§8.3, §8.4.** `src/komira_plan_ir/logical_plan.mojo:2425-2470`; the DECIMAL(38, s) rule is measured against DuckDB, pyarrow and polars there.
- **§8.5.** AVG of a DECIMAL is DOUBLE: `BindDecimalAvg` sets the return type to DOUBLE (`extension/core_functions/aggregate/algebraic/avg.cpp:268-277` at v1.5.6). The plan: `src/komira_plan_expr/typed_schema.mojo:1173-1180` and `:1185-1210`.
- **§8.8.** `src/komira_plan_expr/expr_walk.mojo:819-835` types every comparison and AND/OR as BOOLEAN, nullable.
- **§8.22 to §8.27, window functions.** DuckDB's ranking functions return BIGINT and `percent_rank`/`cume_dist` DOUBLE; `lag`/`lead` and the value functions return the input's type (DuckDB documentation, "window functions"; the oracle confirms each type). The plan: `src/komira_plan_expr/partition_expr.mojo:404-505`.
  - **LAG/LEAD (§8.24).** At a partition edge the default answers, and it defaults to NULL (§9.4). So with a non-nullable input and a non-NULL default no row can be NULL, and declaring the result non-nullable is sound; with either a nullable input or no default (or a NULL default) it must be nullable. The plan declares exactly this (`out_nullable = in_nullable or not value_fn_has_default(expr)`, `:459`), so its non-nullable declaration is sound. The default is converted to the column's type.
  - **NTILE (§8.22).** The plan carries `n` as a constant (`PartitionExpr`'s offset), so it is never NULL; `n <= 0` is an error, as in DuckDB ("Argument for ntile must be greater than zero"). DuckDB's `ntile(NULL)` answers NULL, which the plan cannot express. Oracle cases use a positive literal.
  - **FIRST/LAST_VALUE (§8.25).** A frame that can be empty (`ROWS BETWEEN 2 FOLLOWING AND 3 FOLLOWING` at the end of a partition) gives NULL, so the input's nullability is enough only for frames that always contain the current row, such as the default frame (§9.1). That holds only while the plan has no EXCLUDE clause: `EXCLUDE CURRENT ROW` can leave a one-row frame empty, and adding EXCLUDE to the plan makes these results nullable.
  - **Windowed aggregates (§8.26).** A frame of only NULLs gives NULL for SUM, AVG, MIN and MAX (§2.2), and so does an empty frame; COUNT gives 0 (§8.27). A frame that always contains the current row is never empty, and over a non-nullable input it holds at least one non-NULL value, so the result cannot be NULL; DuckDB answers the same way, since it returns NULL only for a frame with no non-NULL value. The plan declares windowed SUM and AVG non-nullable even over a nullable input or a frame that can be empty, and mistypes some SUMs ([rulings and code status](query_semantics_rulings.md), "Code that does not follow", item 13).
- **§8.28 to §8.31, string-valued functions.** The NULL rules are §7.2, §7.4 and §7.16; `replace` propagates a NULL in any of its three arguments (`src/komira_plan_expr/expr.mojo:1139-1141`, measured); the plan types every one of them STRING, nullable (`src/komira_plan_expr/expr_walk.mojo:1195-1230`), which is sound for CONCAT too.
- **§8.21.** DuckDB: IS [NOT] NULL is total (DuckDB documentation, "NULL values"); the plan: `src/komira_plan_expr/expr_walk.mojo:1045-1052`. The other predicates that can never answer NULL are not plan operators: `IS [NOT] DISTINCT FROM` (§1.6) would be non-nullable if added as an operator, and its desugared form (§1.6) is declared nullable by the AND/OR rule, which is sound because its values are never NULL. `EXISTS` and `NOT EXISTS` lower to SEMI and ANTI joins when they are filter conjuncts (§3.15) and produce no column there; in any other position they are refused until the plan has a MARK join (§3.16), after which EXISTS as a value is a non-nullable row of this table.
- **§8.11.** `BindDecimalArithmetic` (`src/function/scalar/operator/arithmetic.cpp:193-245` at v1.5.6) adds 1 to the required width and, when that exceeds 18 while both inputs are at most 18, declares DECIMAL(18, s) with a runtime overflow check: DECIMAL(18,2) + DECIMAL(18,2) is DECIMAL(18,2), and a sum that needs 19 digits is an overflow error. komira stores every DECIMAL in 128 bits but follows the 18-digit case all the same: same SQL, same result type, same error. The code does not yet ("Code that does not follow", item 22).
- **§8.11, §8.13, §8.20.** `src/komira_scalar_arithmetic/decimal_arith.mojo:150-156`; `src/komira_plan_expr/expr_walk.mojo:857-955`, where the INT64 operand is treated as DECIMAL(19, 0), DuckDB's shape. A DECIMAL with an integer of another width is refused by the evaluator; a frontend casts that integer to INT64 first. DuckDB: "Addition, subtraction and multiplication of two fixed-point decimals returns another fixed-point decimal with the required WIDTH and SCALE to contain the exact result"; division of decimals uses "approximate floating-point arithmetic" (DuckDB documentation, "numeric types").
- **§8.15.** `src/komira_plan_expr/expr_walk.mojo:1195-1230`; `src/komira_kernels/temporal_extract.mojo:13-29` records DuckDB's BIGINT. DuckDB's `epoch` and `julian` parts are DOUBLE, not BIGINT. The plan has neither unit (`src/komira_plan_expr/expr.mojo:569-575`); a frontend refuses them by name, and adding them means adding DOUBLE rows here.
- **§8.16.** DuckDB maps every signed and unsigned integer and DOUBLE to DOUBLE (`extension/core_functions/aggregate/holistic/quantile.cpp:457-478` at v1.5.6). The plan types MEDIAN as FLOAT64 (`src/komira_plan_expr/typed_schema.mojo:1173-1180`).
- **§8.18 (REPRESENTATION DEPARTURE).** DuckDB widens UBIGINT with a signed integer to HUGEINT, which Arrow cannot carry (§8.1's reason). A frontend casts one operand explicitly or the plan refuses the pair by name.
- **§8.19.** Every plan literal carries a type (`src/komira_plan_expr/scalar_value.mojo`). DuckDB types an unadorned literal by its spelling, and a SQL frontend gives each literal that same type, so the same SQL has the same result types on both engines: an integer literal is INTEGER when it fits 32 bits and BIGINT when it fits 64 (past that DuckDB's HUGEINT, §8.1's departure, refused by name); a literal with a decimal point and no exponent is DECIMAL(digits, digits after the point), so `2.5` is DECIMAL(2,1); a literal with an exponent is DOUBLE. The oracle confirms each spelling, including where DuckDB falls back to DOUBLE for a decimal literal too wide for DECIMAL. The SQL parser does not follow this today: it reads `2.5` as a Float64 (item 28 of "Code that does not follow"). A plan built without SQL has no spelling to follow, so the oracle's SQL for it casts **every** literal to the plan literal's type (`CAST(2.5 AS DOUBLE)` for a DOUBLE literal, never `2.5`); an oracle query with an uncast literal is a defect in the case. A NULL literal is nullable; the plan declares it non-nullable today (item 11 of "Code that does not follow", in [rulings and code status](query_semantics_rulings.md)).

### 8.9 Integer and mixed arithmetic

- **Rule.** DuckDB's: for `+ - * %` and `BIN_DIV`, the result type is the narrowest type both operand types convert to without loss, and the oracle measures each mixed-sign pair:

  | Operands | Result |
  |---|---|
  | two signed integers, or two unsigned | the wider of the two |
  | `uint8` with `int8` | `int16` |
  | `uint8` with `int16`, `int32`, `int64` | the signed type |
  | `uint16` with `int8`, `int16` | `int32` |
  | `uint16` with `int32`, `int64` | the signed type |
  | `uint32` with `int8`, `int16`, `int32`, `int64` | `int64` |
  | `uint64` with any signed integer | refused (§8.18) |
  | any integer with `float32` | `float32` |
  | any integer or `float32` with `float64` | `float64` |

  Overflow of the result type is an error (§5.5). The result is never widened to avoid overflow: INT32 + INT32 is INT32.
- **DuckDB.** Implicit casts are added only where "the cast cannot fail, such as INTEGER to DOUBLE" (DuckDB documentation, "typecasting"). UINTEGER with INTEGER is BIGINT and UBIGINT with a signed integer is HUGEINT; the other mixed-sign rows follow the same "narrowest type holding both" rule and the oracle measures each pair.
- **Current behaviour.** The plan types a non-decimal arithmetic result as the **left** operand's type unless either side is FLOAT64 (`src/komira_plan_expr/expr_walk.mojo:968-975`). So `int8 + int16` is INT8, `int32 + int64` is INT32, and `int64 + float32` is INT64. An INT32 column with an integer literal outside INT32 is widened to INT64 (`:977-1005`). The typed surface mirrors the left-wins rule (`src/komira_plan_expr/typed_schema.mojo:1296-1325`). "Code that does not follow", item 21.
- **Mark.** MATCHES.

### 8.12 Decimal multiplication

- **Rule.** DuckDB's, including its 18-digit case: DECIMAL(p1, s1) * DECIMAL(p2, s2) is DECIMAL(18, s1 + s2) when p1 + p2 > 18, max(p1, p2) <= 18 and s1 + s2 < 18, and otherwise DECIMAL(min(p1 + p2, 38), s1 + s2). A product whose value needs more digits than the declared precision is an overflow error at evaluation, so DECIMAL(10, 2) * DECIMAL(10, 2) at 99999999.99 squared is an error, as in DuckDB. If s1 + s2 exceeds 38 the expression is an error when the plan is built.
- **DuckDB.** `BindDecimalMultiply` (`src/function/scalar/operator/arithmetic.cpp` at v1.5.6) sums the widths and scales, then:
  - if p1 + p2 > 18, max(p1, p2) <= 18 and s1 + s2 < 18, the result is **DECIMAL(18, s1 + s2)** with a runtime overflow check;
  - otherwise DECIMAL(min(p1 + p2, 38), s1 + s2), with a runtime overflow check when p1 + p2 exceeds 38;
  - s1 + s2 > 38 is a bind error ("Needed scale ... out of range of the DECIMAL type").
- **Current behaviour.** DECIMAL(min(p1 + p2 + 1, 38), s1 + s2) (`src/komira_scalar_arithmetic/decimal_arith.mojo:159-183`), with neither the 18-digit case nor DuckDB's width; the precision difference is recorded at `src/komira_plan_expr/expr_walk.mojo:936-944` ("Code that does not follow", item 22).
- **Mark.** MATCHES.

### 8.14 CASE and COALESCE

- **Rule.** DuckDB's: the result type of CASE (and of COALESCE, which is a CASE) is DuckDB's combination type of every THEN branch and the ELSE. For numeric branches that is §8.9's table; a NULL literal branch takes the others' type; the other combinations DuckDB makes (for example BOOLEAN with INTEGER) are measured by the oracle before a case relies on them. Branches DuckDB refuses to combine are refused by name.
- **DuckDB.** Combination casting, used "in UNION, CASE, comparisons", picks a type every branch converts to, and is more lenient than §8.9 (for example BOOLEAN to INTEGER) (DuckDB documentation, "typecasting"). DuckDB types the literal `2.5` as DECIMAL(2,1), so `CASE WHEN c THEN 1 ELSE 2.5 END` is a DECIMAL there; the oracle casts every literal (§8.19) to ask the plan's question.
- **Current behaviour.** The result type is the **first** THEN branch's (`src/komira_plan_expr/expr_walk.mojo:1146-1159`). The dataframe and SQL builders convert integer literals to float when some argument provably floats (`src/komira_plan_expr/col_expr.mojo:420-441`); other mixes are refused by the engine ("Code that does not follow", item 23).
- **Mark.** MATCHES.

### 8.17 MEDIAN of FLOAT32, DECIMAL or DATE

- **Rule.** DuckDB's: MEDIAN keeps FLOAT32 as FLOAT32 and DECIMAL(p, s) as DECIMAL(p, s), and answers TIMESTAMP for a DATE input.
- **DuckDB.** FLOAT gives FLOAT, a DECIMAL gives the same DECIMAL, DATE gives TIMESTAMP (`extension/core_functions/aggregate/holistic/quantile.cpp:470-493` at v1.5.6).
- **Current behaviour.** The plan types every MEDIAN as FLOAT64 (`src/komira_plan_expr/typed_schema.mojo:1173-1180`), and the accumulator works in Float64 (`src/komira_op_agg_state/columnar_acc_agg.mojo:60-80`) ("Code that does not follow", item 24).
- **Mark.** MATCHES.
