# komira_plan_conformance

The logical-plan conformance corpus. A case is a logical plan plus the answer
it must give. Nothing in this repository executes a plan yet. Until something
does, the welded test `test_corpus` checks every case through the plan wire
and against its expectation's schema. Each shard becomes one executing test
once a plan can run.

## Layout

```text
plan_case.mojo            Case, Dataset, the expectation kinds, the .err format
datasets.mojo             the datasets and their schemas
cases_<shard>.mojo        one shard's plans, built with komira_plan_ir factories
registry.mojo             the shards, and the cases each one registers
corpus.mojo               the checks test_corpus runs
oracle_checks.mojo        rows tied to an oracle file; the Avro header schema
datasets/<name>.jsonl     inputs, one JSON object per line (hand-written;
                          weather.jsonl is Apache Avro's weather.json, staged)
inputs/avro/              Apache Avro's four weather .avro files, staged
                          from third_party/apache-avro by BUCK
expect/<shard>/<id>.tsv   expected result, canonical text (komira_plan_harness)
expect/<shard>/<id>.err   expected refusal
```

## Shards

| shard | what it pins | items |
|---|---|---|
| `filter_3vl` | the AND/OR/NOT truth table over two nullable BOOLEAN columns, as values and as filters; comparisons with a NULL literal and a NULL value | query semantics §1.1, §1.2, §8.8 |
| `agg_grouping` | NULL grouping keys form one group; COUNT(*) against COUNT(col); SUM, MIN and MAX of an all-NULL group are NULL; empty input with and without keys | §2.1 to §2.4, §8.1, §8.6, §8.7 |
| `join_residual_nullkeys` | NULL keys match nothing in INNER, LEFT, RIGHT, FULL and SEMI joins, on the AUTO and SORT_MERGE kernels; outer joins pad with NULL; ANTI returns NULL-key rows and ignores right NULLs; duplicate keys multiply; a NULL residual is no match; -0.0 and 0.0 match as float keys; a CROSS, LEFT and ANTI join with an empty right side | §1.2, §3.1, §3.2, §3.4, §3.5, §3.9 to §3.13, §11.6 |
| `sort_topn_limit` | explicit NULLS FIRST and NULLS LAST in both directions; the default (NULLS LAST in both); two keys of mixed direction and placement; -0.0 tying with 0.0; TOPN; LIMIT 0, above the row count, and over a sort. No NaN or infinity: JSON cannot spell them | §4.1, §4.2, §4.4, §4.7, §4.8 |
| `window_rank` | LAG and LEAD within partitions: the partition edge, a NULL value at an existing offset row (not the default), an explicit default, an explicit NULL default, an offset of 2, a descending order key, and the nullability of LAG over a non-nullable input; RANK and DENSE_RANK with ties and NULL order keys as peers, ascending and descending; ROW_NUMBER among peers, compared as a set; a NULL partition key forming one partition. No windowed SUM under its RANGE frame: the plan declares it non-nullable against §8.26 (komira#771, item 13) | §4.1, §4.8, §8.22, §8.24, §9.2 to §9.5, §9.7, §9.9 |
| `conditional` | CASE with a NULL condition and with no ELSE; COALESCE over NULLs; NULLIF (as the CASE §1.8 defines); IN and NOT IN with a NULL member, as values and filters. Every CASE branch has one type: mixed types are §8.14, undecided | §1.1 to §1.5, §1.7, §1.8, §8.8, §8.19 |
| `agg_stats` | AVG of integers summed exactly (2^53 + 1 included) and of floats, over all-NULL groups and empty input; VAR_SAMP, VAR_POP, STDDEV_SAMP and STDDEV_POP over three, one and no values; MEDIAN of INT64 and FLOAT64 at odd and even counts and over an all-NULL group; COUNT(DISTINCT) with NULLs and duplicates; MIN and MAX of strings by bytes. The float AVG and MEDIAN columns carry a tolerance (§2.10, §2.14). No MEDIAN of FLOAT32 or DECIMAL (§8.17, undecided) | §1.2, §2.1 to §2.3, §2.5, §2.10 to §2.12, §2.14, §4.6, §4.8, §8.5 to §8.7, §8.16 |
| `project_arith` | integer `+ - *` with NULL operands, none near overflow; BIN_DIV truncating and BIN_MOD taking the dividend's sign, for every sign pair; the identity a = (a / b) * b + a % b; a zero divisor, in a column and as a literal, answering NULL, and a NULL operand answering NULL before the divisor is checked; float division by zero giving inf, -inf and NaN, and NaN and inf carried through `+ - *`, with NULL dominating NaN. Both operands always have one type: mixed arithmetic is §8.9, undecided | §4.8, §5.0 to §5.3, §5.5 to §5.7, §8.9, §8.10, §8.19 |
| `distinct_union` | DISTINCT with NULLs equal and strings equal only byte for byte; DISTINCT over -0.0 and 0.0 (counted: §2.6 leaves the representative open) and over NaN, inf and NULL; UNION ALL keeping duplicates; UNION as DISTINCT over UNION ALL; UNION ALL and UNION with an empty input, and of two empty inputs. Every UNION's inputs have identical names and types (§11.4); no INTERSECT or EXCEPT (§11.3, undecided) | §1.2, §2.1, §2.3, §2.4, §2.6, §4.6, §4.8, §5.0, §5.6, §7.14, §8.6, §11.1, §11.2, §11.4, §11.6 |
| `string` | length in code points against strlen and bit_length in bytes over 1- to 4-byte characters; CONCAT skipping NULLs; CONCAT_WS with a NULL argument, a NULL separator and ''; LIKE's `%` and `_` (one code point), case-sensitive, with a NULL subject, as a value and a filter; UPPER and LOWER by simple Unicode mapping; comparison by bytes with no padding; '' against NULL as a value and a grouping key. No SUBSTRING (no item), no regular expressions | §1.2, §2.4, §4.6, §4.8, §7.1, §7.2, §7.4, §7.6, §7.9, §7.12, §7.14, §8.6, §8.8, §8.15, §8.21 |
| `scan_avro` | the scan node over Apache Avro's four upstream weather files: the output schema (string, int64, int32, none nullable, by §13.4 from the writer schema); a full scan; the same rows from each block codec; a projection to a reordered subset; a filter above the scan; a filter carried by the scan onto a column the projection drops. Expected rows are upstream's weather.json, not komira's output, and test_corpus holds every case's rows to it. Not the encoding (komira_formats_e2e reads these files by value); no NULL (test.Weather has no union); no logical or complex types (§13.5, undecided) | §1.2, §4.8, §13.1, §13.3, §13.4 |
| `scan_jsonl` | the scan node itself, built in each case (not `datasets.scan`), over hand-written JSON Lines: explicit null and "" in integer and string columns; members bound by name in any order; a missing member as NULL and an undeclared one ignored; a JSON integer read into FLOAT64; a projection reordering columns; filters carried by the scan, one on a dropped column and one on ''; a declared schema more nullable than the file. No nested NULLs (nested types out of scope), mistyped values (§13.7) or repeated keys (§13.9), both undecided; no reader-error cases until an error code is fixed | §1.2, §4.8, §7.12, §7.17, §13.1, §13.3, §13.6, §13.8, §13.10 |
| `window_frames` | windowed COUNT(*) and COUNT(col), MIN and MAX, FIRST_VALUE and LAST_VALUE over explicit ROWS frames ordered by a key with no ties: running, sliding (1 PRECEDING to 1 FOLLOWING), the whole partition, and frames wholly ahead of or behind the current row that are empty at a partition's edge (COUNT 0, the others NULL); an all-NULL partition; FIRST_VALUE and LAST_VALUE respecting a NULL first or last row; NTH_VALUE counting from 1 over NULL rows, NULL past a short frame; SUM, AVG, MIN and MAX of a non-nullable column under a frame holding the current row, declared non-nullable. A frame staying within its partition is standard SQL, not yet an item. No windowed SUM or AVG of a nullable column or under a frame that can be empty, and no FIRST/LAST_VALUE, MIN or MAX of a non-nullable column under a frame that can be empty: the plan declares each non-nullable against §8.25 and §8.26 (item 13). No RANGE offsets (§9.8, undecided) | §2.1, §2.2, §4.8, §8.1, §8.5, §8.7, §8.25 to §8.27, §9.1, §9.7, §9.10 |
| `join_asof` | the plan's ASOF join, a LEFT ASOF join: BACKWARD and FORWARD matching at an equal ordering value and choosing the closest candidate; a NULL equality key, a NULL ordering value on either side and a missing group matching nothing, the left row kept with NULL right columns; an inclusive tolerance, a candidate at exactly the bound kept (§3.8, DEPARTS); NEAREST with a tie going to the earlier row (§3.7, DEPARTS); no equality keys as one group. Left columns keep their nullability, right ones are nullable. No two right rows of a group share an ordering value (§3.19, undecided) | §1.2, §3.1, §3.4, §3.6 to §3.8, §3.13, §3.17, §3.18, §4.8 |

## Adding a case

1. Write the plan in `cases_<shard>.mojo` as a `def () raises -> LogicalPlan`
   built with `komira_plan_ir` factories, not the SDK's verbs. Register it in
   the shard's `cases()` list with its comparison policy. Rows without an
   ORDER BY compare as a multiset (`CanonPolicy.unordered()`).
2. Write the expectation by hand, from the dataset and the query-semantics
   document (`docs/design/query_semantics.md`, under review as komira#770):

   ```text
   #! komira-plan-conformance v1
   #  order: none
   #  float: ulps=0
   # derivation: §2.2: SUM over a group with no non-NULL input is NULL ...
   k:int64?	s:int64?
   1	10
   \N	12
   ```

   The derivation is the `# derivation:` line and the comment lines after it.
   It cites the items the rows rest on (`§2.2`), never engine code. The
   schema line's types come from the document's result-type table (§8). A
   scanned column keeps its dataset's nullability. A computed column is
   nullable unless the table says otherwise (COUNT, §8.6; IS [NOT] NULL,
   §8.21). Every cell must be a value of its column's type: `\N` only in a
   `?` column, `true`/`false` in a bool column, plain integers in an integer
   column. An ORACLE file's first comment line is `# GENERATED by ...`. A
   HAND file never carries that line.
3. A refusal is an `.err` file. It holds `prefix: PLAN_ENDPOINT_<NAME>(<code>)`
   and `kind: <error kind>`, plus `text: <message>` only where the wording is
   itself the contract.

If `test_corpus` reports that the expectation and the plan disagree on a type,
that is a review question: decide which side is wrong against the document.
Never copy the plan's schema into the expectation.

## What test_corpus checks, and what each check catches

- **Partition.** Every case is registered through exactly one shard's list,
  and that shard is the one the case names. This catches a case copied into
  a second shard, which would otherwise run twice.
- **Files.** Every case has exactly one expectation file, and every file
  under `expect/` belongs to a case. This catches a renamed case that leaves
  a stale file behind, and a case that has none.
- **Wire.** The plan builds. `plan_to_bytes` encodes it, `plan_wire_admit`
  accepts the bytes, `plan_wire_check_values` accepts the plan, and
  `plan_from_bytes` decodes it. The decoded plan must have the same
  structural hash and root output schema. This catches a plan that the
  plan door would refuse before it ever runs.
- **Expectation.** The file parses, and a HAND file has a derivation that
  cites an item. An ORACLE file starts its comments with `# GENERATED by`.
  Its order/float header must equal the case's policy, every cell must be a
  value of its column's type, and its schema must equal the plan's root
  output schema. This catches an expectation whose types
  drift from the plan, in either direction.
- **Datasets.** Each line's members are the declared columns, in order (or,
  for a dataset declared with any member order, each column exactly once;
  a sparse dataset may omit a nullable column and carry the undeclared
  members it names). Each value has the column's JSON kind (an int32 value
  within range), and `null` appears only where the column is nullable.
  Every file under `datasets/` is a registered dataset. This catches a hand
  edit that changes one side only, and a narrowing drift of the scan_avro
  schema against upstream's weather.json (time declared int32); a widening
  one (temp declared int64) is caught by the Avro header check below.
- **Oracle.** A case registered `with_rows_from` must expect exactly its
  oracle file's rows, filtered and projected as the case restates, as a
  multiset: every scan_avro case against upstream's weather.json. This
  catches a hand edit to one expected row (22 written 23). Each staged Avro
  file's header schema (`avro.schema`) must give the declared columns'
  names, types and nullability by §13.4. This catches a declared schema
  that drifts from the files in either direction.
- **Inputs.** Every file a case may name under `inputs/` (`all_inputs`) is
  staged, and every file staged there is registered. This catches a BUCK
  edit that drops a staged Avro file, or stages one no case names.

Every problem is reported in one failure, not only the first.
`test_corpus_checks` plants defects for the partition, file, expectation,
cell, `.err`, dataset, input and oracle checks. On the wire it plants a build that raises
and a plan the admission gate refuses. Three wire legs are not planted,
because each needs a broken codec rather than a broken case:
`plan_to_bytes` refusing a plan, `plan_wire_check_values` refusing one, and
a round trip that changes the hash or the schema. `komira_plan_wire`'s own
tests prove those raise.
