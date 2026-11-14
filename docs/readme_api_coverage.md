# README API coverage

A package's `README.md` `mojo` examples are its smoke tests: they run as the
welded `[tests][readme]` test of its library
([README examples](../tools/build/mojo/README.md#readme-examples)), and again
against the installed package. So every public API should be used by an
example in its package's README. **README API coverage** measures how much
is: per package, the public symbols its README's examples use. It is not line
or branch coverage, which is a separate metric.

The lint is [`readme_api_coverage`](../tools/build/lint/readme_api_coverage.bzl)
(its action, [`readme_api_coverage.zig`](../tools/build/lint/readme_api_coverage.zig),
states the same rules), declared once in the root [`BUCK`](../BUCK) as
`//:readme_api_coverage` over every file of the cell. It is a validation
that runs on the farm like the other lints; its tests are
[test 40](../tools/build/tests/lint_tests.md#40-readme-api-coverage).

```sh
./buck2 build //:readme_api_coverage                                     # the census; fails only on the ledger
./buck2 build '//:readme_api_coverage[report]' --show-full-output         # the human summary
./buck2 build '//:readme_api_coverage[symbols]' --show-full-output        # one row per public symbol
```

## The rules

**Public API.** A package is a directory directly under `src/`, other than
`src/tests/`, which holds the test-only packages: they publish no API, so the
census skips them. Its public
API is read from `src/<package>/__init__.mojo` only:

- every name bound at column 0 by an import of the package's own modules:
  relative (`from .x import A, B`) or by the package's own name
  (`from <package>.x import A`), on one line, parenthesised over several, or
  continued with a backslash. `from .x import A as B` exports `B`;
  `from . import x` exports the module `x`. A repeated name counts once.
- every column-0 `def`, `fn`, `struct`, `trait`, `comptime` or `alias` the
  `__init__.mojo` declares itself.
- **Methods are included (v1).** For each exported struct, each public
  method is a symbol named `<Exported>.<method>` (the exported name, so an
  alias names its methods): a `def` or `fn` at four spaces in the struct's
  body (a header may span lines: `struct X[\n    T: AnyType,\n](Traits):`),
  found in the module the import names (`.x` is `x.mojo` or a file under
  `x/`), else in any file of the package outside `tests/`. Overloads are one
  symbol, placed at the first one's line. Struct-level `comptime` members
  are not counted in v1.

Not public: a name with a leading underscore (so `__init__`, `__eq__` and the
other dunder methods are not counted: syntax reaches them, not their names);
`write_to` and `write_repr_to`, for the same reason (`print`, `String` and
`repr` call them; a README prints the value). Other trait-conformance
methods are counted: `copy`, for one, is a name a user writes (`x.copy()`).
An import from another package is not an export of this one, even a
deliberate re-export: the name is counted once, in the package that defines
it, so one README documents it, not two. Also not public: lines
in comments and in triple-quoted strings (an indented `from .x import` in a
docstring is an example, not an export); a trait's methods. A
`from .x import *` cannot be listed: the report names it and counts nothing
for it (no package has one today). A package whose `__init__.mojo` exports
nothing, because its users import its submodules (`from async_rt.channel
import ...`), exports nothing here; the report lists those packages.

**Used.** The README is read through the tool the gate runs
(`//tools/build/readme_examples:tool generate`), so exactly the code the
`[tests][readme]` test compiles is read: every `mojo` and `mojo module`
fence, hidden lines (`<!-- mojo-hidden ... -->`) included, and no prose,
`text` fence or other fence. Each example's program is read; the generated
lines (the header comment and a `mojo` example's `def main() raises:`) are
dropped, the runner is not read, and comments and string literals are
blanked.
One difference from the gate: the lint passes `--links allow`, where the gate
of a shipped library passes `refuse`, so a shipped README with a relative
link is counted here while its gate refuses it; the tokens read are the
same.

Not uses: `from`/`import` lines (a name an example only imports is not
exercised by it, so an import alone does not count), and the name
a `def`, `fn`, `struct`, `trait`, `comptime`, `alias` or `var` in the
README declares (a README that implements a trait with its own
`def encode` has not called anyone's `encode`). A name is used when its
identifier appears in what remains as a whole token (`squared_area` is not
a use of `area`); a method is used when `.<method>` appears (`x.read()`,
`Reader.make()`), so a local variable named like a method is not a use.
This is conservative on purpose: a use of a method name counts for every
overload, and for every exported struct's method of that name. A name the
README only mentions in prose is not used.

**Per package:** exported N (names and methods), used U, U/N as a
percentage with one decimal (`-` when N is 0), the ledger rows that apply,
and the undocumented list. A package with an `__init__.mojo` and no README
scores 0% and says `none`; a README with no `mojo` example says
`no-example`; a README the tool refuses (its library's gate would refuse it
too) says `refused` and scores 0%. A package with no `__init__.mojo` (the
generated clients and protobuf packages) exports nothing.

## The outputs

| Sub-target | Contents |
|---|---|
| `[packages]` | TSV with a header: `package init readme exported used percent names names_used methods methods_used excepted undocumented`, one row per package |
| `[symbols]` | TSV with a header: `package symbol kind status where`; `kind` is `name` or `method`, `status` is `used`, `excepted` or `undocumented`, `where` is `<path>:<line>` of the export (the `__init__.mojo` line) or of the method's first `def` |
| `[report]` | the human summary: totals, the packages with no `__init__.mojo`, those exporting nothing, those with no README, a line per package, notes, and every undocumented symbol |

`[symbols]` is what a pull-request check can read to annotate a newly
exported symbol that no README example uses: the row's `where` is the line
to annotate.

## The ledger, and turning enforcement on

[`tests/readme_api_exceptions.tsv`](../tests/readme_api_exceptions.tsv) lists
the symbols allowed to go undocumented: `<package><TAB><symbol><TAB><reason>`,
a method as `<Struct>.<method>`; blank lines and `#` lines are comments. It
only shrinks. The build fails, even today, on a row that is malformed (not
three fields, a symbol that is no identifier, no reason), repeats a row, names
a symbol that is not exported, or names a symbol a README example now uses
(the change that documents it deletes the row).

**v1 is report-only.** An undocumented symbol is counted and listed, never a
finding. The switch is one line, `enforce = False` in `//:readme_api_coverage`
in the root [`BUCK`](../BUCK): with `enforce = True`, every undocumented
symbol without a ledger row fails the build, naming its `where`.
`tests//negative/readme_api_coverage:enforce` proves that path. Before
flipping it, document the symbols or seed the ledger from `[symbols]` (its
`undocumented` rows, each given a reason).

## Census

The census of 2026-10-07: `./buck2 build //:readme_api_coverage` on the
farm over the tree of that day (test-only packages under `src/tests/` are not
counted). A dated snapshot: rebuild `[report]` for today's numbers.

**Totals.** 182 packages; 6975 public symbols exported (3759 names, 3216
methods); 401 used by a README example, **5.7%** (names 230, 6.1%; methods
171, 5.3%); 0 excepted; 6574 undocumented.

- 90 packages export something. 32 of them have README examples, 1 have a
  README with no `mojo` example (`secret_env`),
  and **57 have no README** (0%; 5387 of the 6574 undocumented symbols).
- 56 packages have an `__init__.mojo` that exports nothing (their API is
  their submodules, which v1 does not count): `agg` (no-example), `agg_api` (no-example), `arrow` (no-example), `arrow_ipc` (no-example), `async_rt`, `async_api` (no-example), `byte_buffer` (no-example), `containers` (examples:4), `column_format`, `column_kernels` (no-example), `compression` (no-example), `counters` (examples:2), `dispatch_agg_exec` (no-example), `dispatch_agg_folds` (no-example), `dispatch_join_kernels` (no-example), `dispatch_scan` (no-example), `dynamic_filter` (no-example), `eval` (no-example), `exec_types` (no-example), `expr` (no-example), `fs`, `gcp_firestore`, `host_probe` (examples:3), `http_core`, `http_server`, `join_assembly` (no-example), `json_index` (no-example), `kafka_server` (examples:4), `kernels`, `libc` (no-example), `lz4`, `metrics`, `morsel`, `net`, `op_agg_row_api`, `op_agg_state`, `optimizer` (no-example), `plan_expr` (no-example), `plan_ir` (no-example), `plan_stats` (no-example), `row_format`, `scalar_arithmetic` (examples:4), `scan_planning`, `scan_resolver`, `scan_source` (no-example), `sdk` (examples:3), `shuffle`, `shuffle_streaming` (no-example), `simd_ops` (examples:4), `snapshotter`, `spsc_ring`, `sql` (examples:5), `table_store` (no-example), `trace`, `udf` (no-example), `validation_run` (examples:3).
- 36 packages have no `__init__.mojo` (generated clients and protobuf
  packages): `aws_apigatewayv2`, `aws_dynamodb`, `aws_dynamodbstreams`, `aws_ec2`, `aws_ecr`, `aws_ecs`, `aws_iam`, `aws_lambda`, `aws_logs`, `aws_route53`, `aws_s3`, `aws_scheduler`, `aws_secretsmanager`, `aws_sesv2`, `aws_sns`, `aws_sqs`, `broker_proto` (examples:2), `gcp_apigateway`, `gcp_artifactregistry`, `gcp_cloudresourcemanager`, `gcp_cloudscheduler`, `gcp_compute`, `gcp_iam`, `gcp_logging`, `gcp_monitoring_client`, `gcp_run`, `gcp_secretmanager`, `gcp_serviceusage`, `gcp_storage`, `job_report_proto` (examples:3), `plan_proto` (examples:1), `supervisor_proto` (examples:2).

**Most undocumented**:

1. `http_client`: 493 undocumented of 493 (no README)
2. `broker`: 407 undocumented of 407 (no README)
3. `aws_core`: 366 undocumented of 366 (no README)
4. `objectstore`: 278 undocumented of 278 (no README)
5. `orc`: 214 undocumented of 214 (no README)
6. `search`: 206 undocumented of 206 (no README)
7. `gcp_core`: 203 undocumented of 203 (no README)
8. `db`: 200 undocumented of 200 (no README)

**Every package that exports something**, by percentage, then by
undocumented count:

| Package | README | Exported | Used | % | Names used | Methods used | Undocumented |
|---|---|---:|---:|---:|---:|---:|---:|
| `clock` | examples:3 | 4 | 4 | 100.0% | 4/4 | 0/0 | 0 |
| `fork_join` | examples:2 | 2 | 2 | 100.0% | 2/2 | 0/0 | 0 |
| `resources` | examples:2 | 2 | 2 | 100.0% | 2/2 | 0/0 | 0 |
| `source_url` | examples:2 | 3 | 3 | 100.0% | 3/3 | 0/0 | 0 |
| `name_registry` | examples:2 | 10 | 7 | 70.0% | 3/6 | 4/4 | 3 |
| `encoding` | examples:4 | 26 | 18 | 69.2% | 18/26 | 0/0 | 8 |
| `atomic_alias` | examples:2 | 6 | 4 | 66.7% | 4/6 | 0/0 | 2 |
| `test_verdict` | examples:3 | 21 | 12 | 57.1% | 6/13 | 6/8 | 9 |
| `test_run_id` | examples:4 | 14 | 7 | 50.0% | 6/9 | 1/5 | 7 |
| `hashing` | examples:2 | 6 | 3 | 50.0% | 3/6 | 0/0 | 3 |
| `datetime` | examples:4 | 23 | 11 | 47.8% | 11/23 | 0/0 | 12 |
| `textproto` | examples:3 | 16 | 7 | 43.8% | 6/10 | 1/6 | 9 |
| `retry` | examples:3 | 54 | 23 | 42.6% | 11/21 | 12/33 | 31 |
| `xml` | examples:4 | 47 | 19 | 40.4% | 7/18 | 12/29 | 28 |
| `wkt` | examples:5 | 157 | 60 | 38.2% | 6/26 | 54/131 | 97 |
| `json` | examples:4 | 53 | 19 | 35.8% | 2/19 | 17/34 | 34 |
| `parquet_api` | examples:2 | 36 | 10 | 27.8% | 9/35 | 1/1 | 26 |
| `protobuf` | examples:4 | 67 | 16 | 23.9% | 7/49 | 9/18 | 51 |
| `parquet` | examples:8 | 66 | 14 | 21.2% | 8/38 | 6/28 | 52 |
| `anomaly` | examples:4 | 108 | 21 | 19.4% | 12/61 | 9/47 | 87 |
| `parquet_codec` | examples:1 | 18 | 3 | 16.7% | 3/18 | 0/0 | 15 |
| `proto_codec` | examples:3 | 197 | 20 | 10.2% | 8/25 | 12/172 | 177 |
| `objectstore_gcs` | examples:2 | 88 | 5 | 5.7% | 4/37 | 1/51 | 83 |
| `http_client` | none | 493 | 0 | 0.0% | 0/157 | 0/336 | 493 |
| `broker` | none | 407 | 0 | 0.0% | 0/172 | 0/235 | 407 |
| `aws_core` | none | 366 | 0 | 0.0% | 0/260 | 0/106 | 366 |
| `objectstore` | none | 278 | 0 | 0.0% | 0/90 | 0/188 | 278 |
| `orc` | none | 214 | 0 | 0.0% | 0/162 | 0/52 | 214 |
| `search` | none | 206 | 0 | 0.0% | 0/78 | 0/128 | 206 |
| `gcp_core` | none | 203 | 0 | 0.0% | 0/145 | 0/58 | 203 |
| `db` | none | 200 | 0 | 0.0% | 0/82 | 0/118 | 200 |
| `avro` | none | 176 | 0 | 0.0% | 0/127 | 0/49 | 176 |
| `log` | none | 173 | 0 | 0.0% | 0/46 | 0/127 | 173 |
| `grpc` | none | 132 | 0 | 0.0% | 0/56 | 0/76 | 132 |
| `azure_blob` | none | 131 | 0 | 0.0% | 0/64 | 0/67 | 131 |
| `objectstore_s3` | none | 128 | 0 | 0.0% | 0/45 | 0/83 | 128 |
| `oci` | none | 106 | 0 | 0.0% | 0/47 | 0/59 | 106 |
| `connect` | none | 98 | 0 | 0.0% | 0/85 | 0/13 | 98 |
| `crypto` | none | 86 | 0 | 0.0% | 0/53 | 0/33 | 86 |
| `csv` | none | 81 | 0 | 0.0% | 0/58 | 0/23 | 81 |
| `job_supervisor` | none | 73 | 0 | 0.0% | 0/34 | 0/39 | 73 |
| `metrics_reader` | none | 62 | 0 | 0.0% | 0/31 | 0/31 | 62 |
| `viewport` | none | 59 | 0 | 0.0% | 0/33 | 0/26 | 59 |
| `plan_wire` | none | 57 | 0 | 0.0% | 0/52 | 0/5 | 57 |
| `gcp_firestore_db` | none | 50 | 0 | 0.0% | 0/13 | 0/37 | 50 |
| `broker_coordinator` | none | 48 | 0 | 0.0% | 0/16 | 0/32 | 48 |
| `db_postgres` | none | 43 | 0 | 0.0% | 0/4 | 0/39 | 43 |
| `supervisor` | none | 40 | 0 | 0.0% | 0/15 | 0/25 | 40 |
| `search_scan` | none | 39 | 0 | 0.0% | 0/15 | 0/24 | 39 |
| `gcp_wif` | none | 36 | 0 | 0.0% | 0/27 | 0/9 | 36 |
| `aws_lambda_http` | none | 35 | 0 | 0.0% | 0/29 | 0/6 | 35 |
| `azure_core` | none | 35 | 0 | 0.0% | 0/9 | 0/26 | 35 |
| `search_catalog` | none | 34 | 0 | 0.0% | 0/20 | 0/14 | 34 |
| `iceberg_catalog` | none | 32 | 0 | 0.0% | 0/13 | 0/19 | 32 |
| `gcp_monitoring` | none | 27 | 0 | 0.0% | 0/22 | 0/5 | 27 |
| `pplan_wire` | none | 24 | 0 | 0.0% | 0/24 | 0/0 | 24 |
| `db_sqlite` | none | 23 | 0 | 0.0% | 0/1 | 0/22 | 23 |
| `log_query` | none | 23 | 0 | 0.0% | 0/18 | 0/5 | 23 |
| `aws_metrics` | none | 21 | 0 | 0.0% | 0/18 | 0/3 | 21 |
| `rowcell` | none | 21 | 0 | 0.0% | 0/15 | 0/6 | 21 |
| `secret_registry` | none | 18 | 0 | 0.0% | 0/4 | 0/14 | 18 |
| `authz_api` | none | 17 | 0 | 0.0% | 0/5 | 0/12 | 17 |
| `secret_env` | no-example | 14 | 0 | 0.0% | 0/7 | 0/7 | 14 |
| `secret_store` | none | 14 | 0 | 0.0% | 0/5 | 0/9 | 14 |
| `jsonl` | none | 12 | 0 | 0.0% | 0/12 | 0/0 | 12 |
| `zlib` | none | 12 | 0 | 0.0% | 0/12 | 0/0 | 12 |
| `uuid` | none | 10 | 0 | 0.0% | 0/3 | 0/7 | 10 |
| `sync` | none | 4 | 0 | 0.0% | 0/1 | 0/3 | 4 |
| `jwks` | none | 3 | 0 | 0.0% | 0/3 | 0/0 | 3 |

## Tests

[Test 40](../tools/build/tests/lint_tests.md#40-readme-api-coverage):
`tests//functional/readme_api_coverage:ok` builds a planted tree whose census
must equal its expected `[packages]`, `[symbols]` and `[report]` byte for byte, and each
target of `tests//negative/readme_api_coverage` must fail naming its planted
finding: a malformed row, a repeated row, a row for a symbol that is not
exported, a row for a symbol the README uses (one only in hidden lines), an
undocumented symbol under `enforce = True`, and a root with no package.
The planted tree has a struct header over three lines, a backslash-continued
import, a same-named struct outside the imported module, a `write_to`, an
import-only name, a README-declared method, a loop variable named like a
method, a `from .x import *` and a README the tool refuses. Each of these
mutants of the lint turns `ok` red: ignoring `as` aliases, reading comments
as code, ending a struct at its header's column-0 closing line, counting a
README's declarations, counting import lines, matching a method without its
`.`, ignoring the imported module, ignoring backslash continuation, and
counting `write_to`.

## Limits

- Only the top-level `__init__.mojo` is read; a package exposing its API as
  submodules (`async_rt`, `arrow`) counts nothing until submodule
  exports are counted.
- A use is an identifier match, not name resolution: a method name or a
  short name shared with another API can count as used when it is not.
- A struct's methods are found by its name; two structs of the exported name
  in the module the import names are merged. When the named module has no
  struct of that name (it re-exports it from a sibling), every non-`tests/`
  file of the package is searched, so a same-named struct in a `bench/` or
  `examples/` directory would be merged too.
