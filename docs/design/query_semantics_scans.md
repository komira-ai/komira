# Query semantics: scans

This is section 13 of [query semantics](query_semantics.md): what a SCAN node returns from a file. The conventions, the oracle settings, "Rulings needed" and the counts are in the main document. The DuckDB references are its readers: `read_parquet`, `read_json` (with an explicit `columns` list), `read_avro` and, where relevant, `read_csv`. How each reader decodes its format is in the [text and row formats](text_and_row_formats.md) design doc; this section states only what a plan's result must be.

## 13. Scans

### 13.1 Projection order

- **Rule.** A scan with a projection outputs exactly the projected columns, in the projection's order, whatever their order in the file or in the declared schema. Without a projection it outputs the declared schema's columns in order.
- **DuckDB.** A `SELECT` list over `read_parquet` / `read_json` / `read_avro` returns its columns in the list's order.
- **Current behaviour.** `LogicalPlan.scan_from_source` builds the output schema by walking the projection list (`src/komira_plan_ir/logical_plan.mojo:925-930`).
- **Mark.** MATCHES.

### 13.2 A projected name the schema does not have

- **Rule.** A projected name absent from the scan's declared schema is refused by name when the plan is built or decoded. It is never dropped.
- **DuckDB.** Referencing a column the file does not have is a binder error.
- **Current behaviour.** The wire's value gate refuses it (`src/komira_plan_wire/plan_wire_values.mojo:2671-2678`). `LogicalPlan.scan_from_source` and the positional `scan` factory skip it silently (`src/komira_plan_ir/logical_plan.mojo:925-930` and `:775-780`), so a plan built in-process outputs fewer columns than it projected ("Code that does not follow", item 15).
- **Mark.** MATCHES.

### 13.3 A filter inside a scan

- **Rule.** A filter carried by a SCAN node has exactly the semantics of a FILTER node above an unfiltered scan (§1.2): a row is kept only when the predicate is TRUE, and a NULL predicate drops the row. The filter is evaluated against the source schema, before the projection prunes columns. Pushing a predicate into a reader (row-group or stripe skipping, late materialization) is an optimization: it may skip work, never change the rows. A reader that declines pushdown leaves the predicate to be applied after the read, with the same result.
- **DuckDB.** `WHERE` over a `read_*` call has the same answer whether or not the reader pushes the filter down; `read_avro` does no pushdown at all ([Avro extension](https://duckdb.org/docs/current/core_extensions/avro.html)).
- **Current behaviour.** The wire resolves a scan's filter against the source schema (`src/komira_plan_wire/plan_wire_values.mojo:2641-2683`). `komira.avro`'s `supports_filter_pushdown` returns false for every predicate (`src/komira_scan_source/avro_source.mojo:147-153`) while the IR accepts a filter on an Avro scan. So the executor must apply a scan-carried filter that its source declined; no executor is in this repository to show that it does, and a conformance case over an Avro scan with a filter is what proves it.
- **Mark.** MATCHES.

### 13.4 Avro primitive types

- **Rule.** Avro types map to plan types as:

  | Avro | Plan |
  |---|---|
  | `boolean` | BOOL |
  | `int` | INT32 |
  | `long` | INT64 |
  | `float` | FLOAT32 |
  | `double` | FLOAT64 |
  | `bytes`, `fixed` | BINARY |
  | `string` | STRING |
  | `int` + `date` | DATE32 |
  | `bytes`/`fixed` + `decimal(p, s)`, p <= 38 | DECIMAL(p, s) |
  | `["null", T]` or `[T, "null"]` | T, nullable |
  | T outside a union | T, non-nullable |

- **DuckDB.** "An Avro union of any type and the special null type is simplified to just the non-null type", nullable ([Avro extension](https://duckdb.org/docs/current/core_extensions/avro.html)). The primitive rows are DuckDB's straightforward mapping (BOOLEAN, INTEGER, BIGINT, FLOAT, DOUBLE, BLOB, VARCHAR, DATE, DECIMAL), which its documentation does not tabulate; the oracle confirms each.
- **Current behaviour.** `avro_node_to_arrow` (`src/komira_avro/avro_schema.mojo:952-1075`), with the union collapse at `:1063`.
- **Mark.** MATCHES.

### 13.5 Avro logical and complex types

- **Rule (proposed).**
  - `timestamp-millis` and `timestamp-micros` are instants: a zoned timestamp in UTC (§6.9).
  - `local-timestamp-*` are unzoned.
  - `time-*` map to the matching time type.
  - `enum` reads as STRING.
  - `uuid` and `duration` are refused by name until the plan has types for them.
  - A union of two or more non-null types, records, arrays and maps are refused by name.
- **DuckDB.** Not tabulated in its documentation; the oracle measures each type.
- **Current behaviour.**
  - Both `timestamp-*` and `local-timestamp-*` map to an unzoned timestamp (`src/komira_avro/avro_schema.mojo:1009-1020`), losing the instant/local distinction the Avro specification draws.
  - `enum` maps to DICTIONARY (`:1054`) and `uuid` to BINARY (`:1024-1028`).
  - The decoder raises on other unions, records, arrays, maps and enums (the [formats doc](text_and_row_formats.md), "Decoding takes one of two paths").
- **Options.** (a) As proposed. (b) Keep the current mapping and record each difference.
- **Recommendation.** (a), after the oracle has measured DuckDB on each logical type.
- **Mark.** UNDECIDED.

### 13.6 JSON values into a column of the matching type

- **Rule.** Against a declared schema:
  - a JSON integer reads into INT64 and any JSON number into FLOAT64;
  - `true` / `false` read into BOOL;
  - a JSON string reads into STRING;
  - JSON `null` is NULL (§7.17).
- **DuckDB.** `read_json` with `columns` reads each value as the declared type ([loading JSON](https://duckdb.org/docs/current/data/json/loading_json.html)).
- **Current behaviour.** `materialize_jsonl_to_batch` parses each value with its column's parser (`src/komira_jsonl/columnar_materializer.mojo:1000-1024`).
- **Mark.** MATCHES.

### 13.7 JSON values of another type than the column's

- **Rule (proposed).** A value whose JSON type does not fit the column is an error naming the column and the line: a JSON string into a numeric or BOOL column, a fractional number into INT64, an integer out of INT64's range, a number or object into a STRING column. DATE and DECIMAL columns accept their string form.
- **DuckDB.** Not documented for `read_json` with `columns`; `ignore_errors` exists, and COPY has `convert_strings_to_integers` ([loading JSON](https://duckdb.org/docs/current/data/json/loading_json.html)). The oracle measures each case.
- **Current behaviour.** A JSON string into a non-string column is refused (`src/komira_jsonl/columnar_materializer.mojo:1280-1285`); the other cases are not established here.
- **Options.** (a) Refuse, as proposed. (b) Match DuckDB's conversions once measured.
- **Recommendation.** (b) where DuckDB converts without loss (a numeric string into a number), (a) otherwise.
- **Mark.** UNDECIDED.

### 13.8 JSON members: missing, extra, order

- **Rule.** Members bind to columns by name, whatever their order in the object.
  - A member missing from an object is NULL in a nullable column and an error in a non-nullable one (§13.10).
  - A member the schema does not declare is ignored.
- **DuckDB.** With `columns`, "missing keys become NULL" and keys not listed are excluded ([loading JSON](https://duckdb.org/docs/current/data/json/loading_json.html)).
- **Current behaviour.** Keys not in the schema are skipped and binding is by key lookup (`src/komira_jsonl/columnar_materializer.mojo:1010-1016`); a missing key reads as NULL, or raises for a NOT NULL field (`:1021-1022`).
- **Mark.** MATCHES.

### 13.9 A repeated JSON key

- **Rule (proposed).** An object that repeats a key the schema reads is an error naming the key. A repeated key the schema does not read is ignored with the rest of the undeclared members.
- **DuckDB.** Not documented; the oracle measures it.
- **Current behaviour.** Refused (`src/komira_jsonl/columnar_materializer.mojo:1211-1222`): "neither value is the record's".
- **Options.** (a) Refuse, as proposed. (b) Last value wins. (c) First value wins.
- **Recommendation.** (a) unless DuckDB answers (b) or (c) without an error, in which case match it.
- **Mark.** UNDECIDED.

### 13.10 Declared nullability against the file

- **Rule.**
  - A column declared nullable over a file with no NULLs is sound and reads normally.
  - A column declared non-nullable over a file that holds a NULL in it is an error raised by the reader, naming the column and the row or line; the NULL is never read as a value or a zero.
  - For Avro, a non-union field cannot hold NULL, and a declared non-nullable column over a `["null", T]` field is refused only if a NULL actually occurs.
- **DuckDB.** Its reader types carry no nullability (the [result types](query_semantics_types.md) preamble), so it has no such check.
- **Current behaviour.** The JSON reader raises for "a JSON `null`, or an object without the key, for a NOT NULL field" (`src/komira_jsonl/columnar_materializer.mojo:1021-1022`); whether the Parquet, ORC, Avro and CSV readers refuse is not established here.
- **Mark.** DEPARTS: declared nullability is komira's contract, with no DuckDB counterpart.
