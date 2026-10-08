# Query semantics: further items

These items belong to [query semantics](query_semantics.md) and keep its numbering: §7.16 extends section 7 (strings) and §11.7 extends section 11 (set operations). The conventions, the oracle settings, "Rulings needed" and the counts are in the main document. They live here only to keep each file under 1000 lines.

### 7.16 SUBSTRING

- **Rule (proposed).** `substring(s, start, length)` counts Unicode code points, and `start = 1` is the first character. A NULL `s` gives NULL; `start` and `length` are constants in the plan (`SubstringData`), so they are never NULL. For the remaining cases the proposal is DuckDB's:
  - a positive `start` past the end gives `''`;
  - a negative `start` counts from the end: `substring('hello', -2, 2)` is `'lo'`;
  - `start = 0` begins one position before the first character, so `substring('hello', 0, 2)` is `'h'`;
  - a negative `length` takes characters backwards from `start`;
  - `length = 0` gives `''`.

  The two-argument form `substring(s, start)` runs to the end of the string.
- **DuckDB.** `SubstringStartEnd` (`src/function/scalar/string/substring.cpp:51-80` at v1.5.6) implements the cases above. `substring` uses the code-point path (`SubstringUnicode`, `:97`); grapheme clusters are the separate `substring_grapheme`.
- **Current behaviour.** The IR defines the standard-SQL meaning instead (`src/komira_plan_expr/expr.mojo:1821-1838`). A `start <= 0` clamps to the first character but still consumes `length` from `start`, so `substring('hello', -1, 3)` is `'h'`, where DuckDB answers `'o'`. A negative `length` is the sentinel for the two-argument form, so it cannot mean "backwards". No SUBSTRING kernel is in this repository.
- **Options.** (a) DuckDB's meaning, as proposed. The two-argument form then needs its own encoding (a flag, or a missing length on the wire) instead of the `length < 0` sentinel. (b) Keep the standard-SQL meaning and record a departure for negative `start` and negative `length`.
- **Recommendation.** (a): a SQL frontend that answers like DuckDB needs it, and the sentinel is the only obstacle. Until it is ruled, oracle cases use `start >= 1` and `length >= 0`, where the two meanings agree.
- **Mark.** UNDECIDED.

### 11.7 Nullability across set-operation inputs

- **Rule.** Inputs of UNION ALL (and of the other set operations) must agree on column names and types (§11.1, §11.4) but may differ in nullability. A column of the output is nullable if it is nullable in any input. Requiring identical nullability instead would refuse plans DuckDB answers, and widening nullability is always sound (see the types preamble).
- **DuckDB.** Combines a nullable and a non-nullable column into a nullable one; DuckDB's types carry no nullability, so this is the only answer it can give (the types preamble in [result types](query_semantics_types.md)).
- **Current behaviour.** The wire refuses a UNION whose branch schema differs from the union's in any of name, type or nullability, with `PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED` (`src/komira_plan_wire/plan_wire_codec.mojo:3540-3556`, comparing `_schema_text`). `LogicalPlan.union` requires every child to advertise the output schema exactly (`src/komira_plan_ir/logical_plan.mojo:1052-1068`). So two branches differing only in nullability are refused ("Code that does not follow", item 14).
- **Mark.** MATCHES.
