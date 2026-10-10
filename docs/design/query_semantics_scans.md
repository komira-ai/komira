# Query semantics: scans

This is section 13 of [query semantics](query_semantics.md): what a SCAN node returns from a file. The conventions, the oracle settings and the counts are in the main document; the rulings, the parity gaps and "Code that does not follow" are in [rulings, parity gaps and code status](query_semantics_rulings.md). The DuckDB references are its readers: `read_parquet`, `read_json` (with an explicit `columns` list), `read_avro` and, where relevant, `read_csv`. How each reader decodes its format is in the [text and row formats](text_and_row_formats.md) design doc; this section states only what a plan's result must be.

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
- **DuckDB.** `WHERE` over a `read_*` call has the same answer whether or not the reader pushes the filter down; `read_avro` does no pushdown at all (DuckDB documentation, "Avro extension").
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

- **DuckDB.** "An Avro union of any type and the special null type is simplified to just the non-null type", nullable (DuckDB documentation, "Avro extension"). The primitive rows are DuckDB's straightforward mapping (BOOLEAN, INTEGER, BIGINT, FLOAT, DOUBLE, BLOB, VARCHAR, DATE, DECIMAL), which its documentation does not tabulate; the oracle confirms each.
- **Current behaviour.** `avro_node_to_arrow` (`src/komira_avro/avro_schema.mojo:952-1075`), with the union collapse at `:1063`.
- **Mark.** MATCHES.

### 13.5 Avro logical and complex types

- **Rule.** Each Avro type reads as DuckDB's Avro extension reads it by default:
  - `timestamp-millis`, `timestamp-micros` and `local-timestamp-*` read as an unzoned timestamp, and `timestamp-*` with the adjust-to-UTC flag as a zoned one; the ticks are UTC either way, so no value changes. The oracle measures the flag before a case relies on it.
  - `time-*` read as the matching time type.
  - `enum`, `uuid`, `duration`, `timestamp-nanos`, multi-type unions, records, arrays and maps read as DuckDB reads them once the plan and the decoder carry them; until then they are refused by name ([komira#1230](https://github.com/komira-ai/komira/issues/1230)).
- **DuckDB.** The duckdb-avro extension maps `timestamp-millis` / `timestamp-micros` to TIMESTAMP, and to TIMESTAMP_TZ only when the adjust-to-UTC flag is set; `local-timestamp-*` to TIMESTAMP; `timestamp-nanos` to TIMESTAMP_NS; `time-*` to TIME; `enum` to ENUM; `uuid` to UUID; a multi-type union to UNION; record to STRUCT, array to LIST, map to MAP (read from the extension's source by the reviewer; the oracle confirms).
- **Current behaviour.**
  - Both `timestamp-*` and `local-timestamp-*` map to an unzoned timestamp (`src/komira_avro/avro_schema.mojo:1009-1020`), which agrees with DuckDB's default; with the adjust-to-UTC flag set DuckDB reads a zoned one ("Code that does not follow", item 25, once the oracle confirms).
  - `uuid` is not refused: the schema maps it to BINARY (`src/komira_avro/avro_schema.mojo:1024-1033`), and the decoder reads a `string` uuid as a STRING column (`src/komira_avro/action_table.mojo:400-408`) and a `fixed(16)` uuid as BINARY. Either way it returns a value where the rule refuses by name ("Code that does not follow", item 29).
  - `enum` maps to DICTIONARY in the schema (`src/komira_avro/avro_schema.mojo:1054`), but the decoder reads it as a STRING column (`src/komira_avro/action_table.mojo:409-415`). A read with no separate reader schema raises `AvroDecodeError.UNSUPPORTED_FIELD_KIND` when a block decodes, which is the rule's named refusal; a read with a reader schema remaps each symbol and returns the STRING column (`:2320-2340`), which is not refused (item 29).
  - `timestamp-nanos` is not a logical type the mapper knows, so it falls through to its physical `long` and reads as INT64 (`src/komira_avro/avro_schema.mojo:1034`), not refused (item 29).
  - `duration` maps to INTERVAL_MONTH_DAY_NANO (`src/komira_avro/avro_schema.mojo:1021-1023`), which has no accumulator, so the decoder raises `AvroDecodeError.UNSUPPORTED_COLUMN_TYPE`: refused by name.
  - The decoder raises on other unions, records, arrays and maps (the [formats doc](text_and_row_formats.md), "Decoding takes one of two paths").
- **Mark.** MATCHES (its refused types are a parity gap).

### 13.6 JSON values into a column of the matching type

- **Rule.** Against a declared schema:
  - a JSON integer reads into INT64 and any JSON number into FLOAT64;
  - `true` / `false` read into BOOL;
  - a JSON string reads into STRING;
  - JSON `null` is NULL (§7.17).
- **DuckDB.** `read_json` with `columns` reads each value as the declared type (DuckDB documentation, "loading JSON").
- **Current behaviour.** `materialize_jsonl_to_batch` parses each value with its column's parser (`src/komira_jsonl/columnar_materializer.mojo:1000-1024`).
- **Mark.** MATCHES.

### 13.7 JSON values of another type than the column's

- **Rule.** As `read_json` with `columns`: a JSON value whose type differs from its column's converts where DuckDB converts it (a JSON string into a numeric column goes through §6.6's string cast, so `"12"` reads as 12) and is an error naming the column and the line where DuckDB raises. DATE and DECIMAL columns accept their string form. Which other mismatches DuckDB converts (a fractional number into INT64, a number or object into a STRING column) the oracle measures before a case relies on it. komira does not convert yet, so a mismatch is refused by name until it does.
- **DuckDB.** `read_json` casts a JSON string into a numeric column through the normal string cast (§6.6), so `"12"` reads as 12; a failed cast is an error or NULL depending on `strict_cast` (`extension/json/json_functions/json_transform.cpp` at v1.5.6). The other mismatches are measured by the oracle.
- **Current behaviour.** A JSON string into a non-string column is refused (`src/komira_jsonl/columnar_materializer.mojo:1280-1285`); the other cases are not established here.
- **Mark.** PARITY GAP ([komira#1231](https://github.com/komira-ai/komira/issues/1231)).

### 13.8 JSON members: missing, extra, order

- **Rule.** Members bind to columns by name, whatever their order in the object. Names match case-sensitively, byte for byte: `"ID"` does not bind to a column `id`.
  - A member missing from an object is NULL in a nullable column and an error in a non-nullable one (§13.10).
  - A member the schema does not declare is ignored.
- **DuckDB.** With `columns`, "missing keys become NULL" and keys not listed are excluded (DuckDB documentation, "loading JSON"); keys are matched case-sensitively (`key_map.find`, `extension/json/json_functions/json_transform.cpp:440` at v1.5.6).
- **Current behaviour.** Keys not in the schema are skipped and binding is by key lookup, with "no case-folding" (`src/komira_jsonl/key_dispatch.mojo:187-188`; `src/komira_jsonl/columnar_materializer.mojo:1010-1016`); a missing key reads as NULL, or raises for a NOT NULL field (`:1021-1022`).
- **Mark.** MATCHES.

### 13.9 A repeated JSON key

- **Rule.** An object that repeats a key the schema reads answers as `read_json`'s default does, measured by the oracle: the first occurrence wins if `error_duplicate_key` is off by default, and it is an error naming the key if the option is on. A repeated key the schema does not read is ignored with the rest of the undeclared members. komira refuses a repeated read key today; if the oracle shows the default is the error, the refusal already matches and the gap closes.
- **DuckDB.** In `json_transform.cpp` (`:436-455` at v1.5.6) the FIRST occurrence wins when `error_duplicate_key` is off; when it is on, the read fails with "Object %s has duplicate key". The default of that option for `read_json` is what the oracle measures.
- **Current behaviour.** Refused (`src/komira_jsonl/columnar_materializer.mojo:1211-1222`): "neither value is the record's".
- **Mark.** PARITY GAP ([komira#1232](https://github.com/komira-ai/komira/issues/1232)).

### 13.10 Declared nullability against the file

- **Rule.**
  - A column declared nullable over a file with no NULLs is sound and reads normally.
  - A column declared non-nullable over a file that holds a NULL in it is an error raised by the reader, naming the column and the row or line; the NULL is never read as a value or a zero.
  - For Avro, a non-union field cannot hold NULL, and a declared non-nullable column over a `["null", T]` field is refused only if a NULL actually occurs.
- **DuckDB.** Its reader types carry no nullability (the [result types](query_semantics_types.md) preamble), so it has no such check.
- **Current behaviour.** The JSON reader raises for "a JSON `null`, or an object without the key, for a NOT NULL field" (`src/komira_jsonl/columnar_materializer.mojo:1021-1022`); whether the Parquet, ORC, Avro and CSV readers refuse is not established here.
- **Mark.** EXTENSION: declared nullability is komira's contract with no DuckDB SQL; a SQL frontend declares every scanned column nullable, so no SQL query reaches the check.
