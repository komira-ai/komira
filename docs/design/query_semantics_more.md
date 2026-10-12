# Query semantics: further items

These items belong to [query semantics](query_semantics.md) and keep its numbering: §7.16 and §7.17 extend section 7 (strings) and §11.7 extends section 11 (set operations). The conventions, the oracle settings, and the counts are in the main document; the rulings, the parity gaps and "Code that does not follow" are in [rulings, parity gaps and code status](query_semantics_rulings.md). They live here only to keep each file under 1000 lines.

### 7.16 SUBSTRING

- **Rule.** DuckDB's. `substring(s, start, length)` counts Unicode code points, and `start = 1` is the first character. A NULL `s` gives NULL; `start` and `length` are constants in the plan (`SubstringData`), so they are never NULL. For the remaining cases:
  - a positive `start` past the end gives `''`;
  - a negative `start` counts from the end: `substring('hello', -2, 2)` is `'lo'`;
  - `start = 0` begins one position before the first character, so `substring('hello', 0, 2)` is `'h'`, and `start = 0` with a negative `length` is `''`;
  - a negative `length` takes characters backwards from `start`, excluding the character at `start`: `substring('hello', 3, -2)` is `'he'`;
  - `length = 0` gives `''`.

  The two-argument form `substring(s, start)` runs to the end of the string. A `start` or `length` below -2^32 or above 2^32 - 1 is an error, as DuckDB's OutOfRange (its bounds are asymmetric).
- **DuckDB.** `SubstringStartEnd` (`src/function/scalar/string/substring.cpp:51-82` at v1.5.6) implements the cases above, and `AssertInSupportedRange` raises OutOfRange beyond the bounds set at `:15-16` (±`uint32` maximum). `substring` uses the code-point path (`SubstringUnicode`, `:97`); grapheme clusters are the separate `substring_grapheme`.
- **Current behaviour.** The IR defines the standard-SQL meaning instead (`src/komira_plan_expr/expr.mojo:1821-1838`). A `start <= 0` clamps to the first character but still consumes `length` from `start`, so `substring('hello', -1, 3)` is `'h'`, where DuckDB answers `'o'`. A negative `length` is the sentinel for the two-argument form, so it cannot mean "backwards"; the two-argument form needs its own encoding (a flag, or a missing length on the wire) in its place. No SUBSTRING kernel is in this repository ("Code that does not follow", item 20). Until the IR follows the rule, oracle cases use `start >= 1` and `length >= 0`, where the two meanings agree.
- **Mark.** MATCHES.

### 7.17 JSON and columnar formats: NULL and the empty string

- **Rule.** JSON `null` reads as NULL and the JSON string `""` as `''`; a missing member is §13.8. Parquet, ORC, Arrow IPC and Avro carry NULL in their own validity encoding and never turn an empty string into NULL or the reverse. (CSV, which has no NULL marker of its own, is §7.13.)
- **DuckDB.** `read_json` reads `null` as NULL and `""` as an empty VARCHAR; its columnar readers keep the file's validity.
- **Current behaviour.** The JSON reader tests for the literal `null` before parsing a value and pushes NULL, raising for a NOT NULL field (`src/komira_jsonl/columnar_materializer.mojo:1385-1392`); a quoted value, empty included, goes to the STRING accumulator (`:1235-1262`).
- **Mark.** MATCHES.

### 11.7 Nullability across set-operation inputs

- **Rule.** Inputs of UNION ALL (and of the other set operations) must agree on column names and types (§11.1, §11.4) but may differ in nullability. A column of the output is nullable if it is nullable in any input. Requiring identical nullability instead would refuse plans DuckDB answers, and widening nullability is always sound (see the types preamble).
- **DuckDB.** Combines a nullable and a non-nullable column into a nullable one; DuckDB's types carry no nullability, so this is the only answer it can give (the types preamble in [result types](query_semantics_types.md)).
- **Current behaviour.** The wire refuses a UNION whose branch schema differs from the union's in any of name, type or nullability, with `PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED` (`src/komira_plan_wire/plan_wire_codec.mojo:3540-3556`, comparing `_schema_text`). `LogicalPlan.union` requires every child to advertise the output schema exactly (`src/komira_plan_ir/logical_plan.mojo:1052-1068`). So two branches differing only in nullability are refused ("Code that does not follow", item 14).
- **Mark.** MATCHES.
