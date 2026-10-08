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
datasets/<name>.jsonl     hand-written inputs, one JSON object per line
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
- **Datasets.** Each line's members are the declared columns, in order. Each
  value has the column's JSON kind, and `null` appears only where the column
  is nullable. Every file under `datasets/` is a registered dataset. This
  catches a hand edit that changes one side only.

Every problem is reported in one failure, not only the first.
`test_corpus_checks` plants defects for the partition, file, expectation,
cell, `.err` and dataset checks. On the wire it plants a build that raises
and a plan the admission gate refuses. Three wire legs are not planted,
because each needs a broken codec rather than a broken case:
`plan_to_bytes` refusing a plan, `plan_wire_check_values` refusing one, and
a round trip that changes the hash or the schema. `komira_plan_wire`'s own
tests prove those raise.
