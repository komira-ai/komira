# README API coverage

A package's `README.md` `mojo` examples are its smoke tests: they run as the
welded `[tests][readme]` test of its library
([README examples](../tools/build/mojo/README.md#readme-examples)), and again
against the installed package. So every public API should be used by an
example in its package's README. **README API coverage** measures how much
is: per package, the public symbols its README's examples use. It is not line
or branch coverage, which is a separate metric.

The lint is [`readme_api_coverage`](../tools/build/lint/readme_api_coverage.bzl)
(its action, [`readme_api_coverage.sh`](../tools/build/lint/readme_api_coverage.sh),
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
it, so one README documents it, not two. Two packages re-export this way
today: `kci_validator_report` (eight names of `kci_validator_rows`) and
`kci_artifact` (`require_full_commit_id`, from `kci_api`). Also not public: lines
in comments and in triple-quoted strings (an indented `from .x import` in a
docstring is an example, not an export); a trait's methods. A
`from .x import *` cannot be listed: the report names it and counts nothing
for it (no package has one today). A package whose `__init__.mojo` exports
nothing, because its users import its submodules (`from komira_async.channel
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
  README with no `mojo` example (`komira_secret_env`),
  and **57 have no README** (0%; 5387 of the 6574 undocumented symbols).
- 56 packages have an `__init__.mojo` that exports nothing (their API is
  their submodules, which v1 does not count): `komira_agg` (no-example), `komira_agg_api` (no-example), `komira_arrow` (no-example), `komira_arrow_ipc` (no-example), `komira_async`, `komira_async_api` (no-example), `komira_buffer` (no-example), `komira_collections` (examples:4), `komira_column_format`, `komira_column_kernels` (no-example), `komira_compression` (no-example), `komira_counters` (examples:2), `komira_dispatch_agg_exec` (no-example), `komira_dispatch_agg_folds` (no-example), `komira_dispatch_join_kernels` (no-example), `komira_dispatch_scan` (no-example), `komira_dynamic_filter` (no-example), `komira_eval` (no-example), `komira_exec_types` (no-example), `komira_expr` (no-example), `komira_fs`, `komira_gcp_firestore`, `komira_host` (examples:3), `komira_http_core`, `komira_http_server`, `komira_join_assembly` (no-example), `komira_json_index` (no-example), `komira_kafka_server` (examples:4), `komira_kernels`, `komira_libc` (no-example), `komira_lz4`, `komira_metrics`, `komira_morsel`, `komira_net`, `komira_op_agg_row_api`, `komira_op_agg_state`, `komira_optimizer` (no-example), `komira_plan_expr` (no-example), `komira_plan_ir` (no-example), `komira_plan_stats` (no-example), `komira_row_format`, `komira_scalar_arithmetic` (examples:4), `komira_scan_planning`, `komira_scan_resolver`, `komira_scan_source` (no-example), `komira_sdk` (examples:3), `komira_shuffle`, `komira_shuffle_streaming` (no-example), `komira_simd` (examples:4), `komira_snapshotter`, `komira_spsc_ring`, `komira_sql` (examples:5), `komira_table_store` (no-example), `komira_trace`, `komira_udf` (no-example), `komira_validation_run` (examples:3).
- 36 packages have no `__init__.mojo` (generated clients and protobuf
  packages): `kci_artifact_proto`, `kci_deploy_model_proto`, `kci_manifest_proto`, `kci_resource_proto` (examples:3), `komira_aws_apigatewayv2`, `komira_aws_dynamodb`, `komira_aws_dynamodbstreams`, `komira_aws_ec2`, `komira_aws_ecr`, `komira_aws_ecs`, `komira_aws_iam`, `komira_aws_lambda`, `komira_aws_logs`, `komira_aws_route53`, `komira_aws_s3`, `komira_aws_scheduler`, `komira_aws_secretsmanager`, `komira_aws_sesv2`, `komira_aws_sns`, `komira_aws_sqs`, `komira_broker_proto` (examples:2), `komira_gcp_apigateway`, `komira_gcp_artifactregistry`, `komira_gcp_cloudresourcemanager`, `komira_gcp_cloudscheduler`, `komira_gcp_compute`, `komira_gcp_iam`, `komira_gcp_logging`, `komira_gcp_monitoring_client`, `komira_gcp_run`, `komira_gcp_secretmanager`, `komira_gcp_serviceusage`, `komira_gcp_storage`, `komira_job_report_proto` (examples:3), `komira_plan_proto` (examples:1), `komira_supervisor_proto` (examples:2).

**Most undocumented**:

1. `komira_http_client`: 493 undocumented of 493 (no README)
2. `komira_broker`: 407 undocumented of 407 (no README)
3. `komira_aws_core`: 366 undocumented of 366 (no README)
4. `komira_objectstore`: 278 undocumented of 278 (no README)
5. `komira_orc`: 214 undocumented of 214 (no README)
6. `komira_search`: 206 undocumented of 206 (no README)
7. `komira_gcp_core`: 203 undocumented of 203 (no README)
8. `komira_db`: 200 undocumented of 200 (no README)
9. `kci_cloud`: 197 undocumented of 197 (no README)
10. `kci_reconciler`: 185 undocumented of 185 (no README)

**Every package that exports something**, by percentage, then by
undocumented count:

| Package | README | Exported | Used | % | Names used | Methods used | Undocumented |
|---|---|---:|---:|---:|---:|---:|---:|
| `komira_clock` | examples:3 | 4 | 4 | 100.0% | 4/4 | 0/0 | 0 |
| `komira_fork_join` | examples:2 | 2 | 2 | 100.0% | 2/2 | 0/0 | 0 |
| `komira_resources` | examples:2 | 2 | 2 | 100.0% | 2/2 | 0/0 | 0 |
| `komira_source_url` | examples:2 | 3 | 3 | 100.0% | 3/3 | 0/0 | 0 |
| `komira_name_registry` | examples:2 | 10 | 7 | 70.0% | 3/6 | 4/4 | 3 |
| `komira_encoding` | examples:4 | 26 | 18 | 69.2% | 18/26 | 0/0 | 8 |
| `kci_artifact_manifest` | examples:3 | 6 | 4 | 66.7% | 3/5 | 1/1 | 2 |
| `komira_atomic_alias` | examples:2 | 6 | 4 | 66.7% | 4/6 | 0/0 | 2 |
| `kci_validator_rows` | examples:4 | 12 | 7 | 58.3% | 7/12 | 0/0 | 5 |
| `komira_test_verdict` | examples:3 | 21 | 12 | 57.1% | 6/13 | 6/8 | 9 |
| `komira_test_run_id` | examples:4 | 14 | 7 | 50.0% | 6/9 | 1/5 | 7 |
| `komira_hash` | examples:2 | 6 | 3 | 50.0% | 3/6 | 0/0 | 3 |
| `kci_params` | examples:4 | 37 | 18 | 48.6% | 16/32 | 2/5 | 19 |
| `komira_datetime` | examples:4 | 23 | 11 | 47.8% | 11/23 | 0/0 | 12 |
| `komira_textproto` | examples:3 | 16 | 7 | 43.8% | 6/10 | 1/6 | 9 |
| `komira_retry` | examples:3 | 54 | 23 | 42.6% | 11/21 | 12/33 | 31 |
| `komira_xml` | examples:4 | 47 | 19 | 40.4% | 7/18 | 12/29 | 28 |
| `komira_wkt` | examples:5 | 157 | 60 | 38.2% | 6/26 | 54/131 | 97 |
| `komira_json` | examples:4 | 53 | 19 | 35.8% | 2/19 | 17/34 | 34 |
| `kci_release_channel` | examples:4 | 28 | 9 | 32.1% | 5/23 | 4/5 | 19 |
| `komira_parquet_api` | examples:2 | 36 | 10 | 27.8% | 9/35 | 1/1 | 26 |
| `komira_protobuf` | examples:4 | 67 | 16 | 23.9% | 7/49 | 9/18 | 51 |
| `kci_workflow_check` | examples:4 | 47 | 11 | 23.4% | 5/37 | 6/10 | 36 |
| `komira_parquet` | examples:8 | 66 | 14 | 21.2% | 8/38 | 6/28 | 52 |
| `kci_validator_report` | examples:4 | 100 | 20 | 20.0% | 16/72 | 4/28 | 80 |
| `komira_anomaly` | examples:4 | 108 | 21 | 19.4% | 12/61 | 9/47 | 87 |
| `komira_parquet_codec` | examples:1 | 18 | 3 | 16.7% | 3/18 | 0/0 | 15 |
| `kci_release_machine` | examples:3 | 31 | 5 | 16.1% | 2/20 | 3/11 | 26 |
| `kci_logs` | examples:4 | 86 | 13 | 15.1% | 10/69 | 3/17 | 73 |
| `kci_api` | examples:4 | 203 | 24 | 11.8% | 21/190 | 3/13 | 179 |
| `komira_proto_codec` | examples:3 | 197 | 20 | 10.2% | 8/25 | 12/172 | 177 |
| `komira_objectstore_gcs` | examples:2 | 88 | 5 | 5.7% | 4/37 | 1/51 | 83 |
| `komira_http_client` | none | 493 | 0 | 0.0% | 0/157 | 0/336 | 493 |
| `komira_broker` | none | 407 | 0 | 0.0% | 0/172 | 0/235 | 407 |
| `komira_aws_core` | none | 366 | 0 | 0.0% | 0/260 | 0/106 | 366 |
| `komira_objectstore` | none | 278 | 0 | 0.0% | 0/90 | 0/188 | 278 |
| `komira_orc` | none | 214 | 0 | 0.0% | 0/162 | 0/52 | 214 |
| `komira_search` | none | 206 | 0 | 0.0% | 0/78 | 0/128 | 206 |
| `komira_gcp_core` | none | 203 | 0 | 0.0% | 0/145 | 0/58 | 203 |
| `komira_db` | none | 200 | 0 | 0.0% | 0/82 | 0/118 | 200 |
| `kci_cloud` | none | 197 | 0 | 0.0% | 0/172 | 0/25 | 197 |
| `kci_reconciler` | none | 185 | 0 | 0.0% | 0/99 | 0/86 | 185 |
| `komira_avro` | none | 176 | 0 | 0.0% | 0/127 | 0/49 | 176 |
| `komira_log` | none | 173 | 0 | 0.0% | 0/46 | 0/127 | 173 |
| `kci_cloud_fake` | none | 134 | 0 | 0.0% | 0/38 | 0/96 | 134 |
| `komira_grpc` | none | 132 | 0 | 0.0% | 0/56 | 0/76 | 132 |
| `komira_azure_blob` | none | 131 | 0 | 0.0% | 0/64 | 0/67 | 131 |
| `komira_objectstore_s3` | none | 128 | 0 | 0.0% | 0/45 | 0/83 | 128 |
| `kci_pkg_upload` | none | 123 | 0 | 0.0% | 0/64 | 0/59 | 123 |
| `kci_publish` | none | 123 | 0 | 0.0% | 0/65 | 0/58 | 123 |
| `komira_oci` | none | 106 | 0 | 0.0% | 0/47 | 0/59 | 106 |
| `komira_connect` | none | 98 | 0 | 0.0% | 0/85 | 0/13 | 98 |
| `komira_crypto` | none | 86 | 0 | 0.0% | 0/53 | 0/33 | 86 |
| `komira_csv` | none | 81 | 0 | 0.0% | 0/58 | 0/23 | 81 |
| `komira_job_supervisor` | none | 73 | 0 | 0.0% | 0/34 | 0/39 | 73 |
| `kci_cli` | none | 63 | 0 | 0.0% | 0/46 | 0/17 | 63 |
| `komira_metrics_reader` | none | 62 | 0 | 0.0% | 0/31 | 0/31 | 62 |
| `komira_viewport` | none | 59 | 0 | 0.0% | 0/33 | 0/26 | 59 |
| `komira_plan_wire` | none | 57 | 0 | 0.0% | 0/52 | 0/5 | 57 |
| `kci_artifact` | none | 56 | 0 | 0.0% | 0/54 | 0/2 | 56 |
| `kci_validate` | none | 56 | 0 | 0.0% | 0/51 | 0/5 | 56 |
| `komira_gcp_firestore_db` | none | 50 | 0 | 0.0% | 0/13 | 0/37 | 50 |
| `komira_broker_coordinator` | none | 48 | 0 | 0.0% | 0/16 | 0/32 | 48 |
| `kci_build` | none | 44 | 0 | 0.0% | 0/29 | 0/15 | 44 |
| `komira_db_postgres` | none | 43 | 0 | 0.0% | 0/4 | 0/39 | 43 |
| `komira_supervisor` | none | 40 | 0 | 0.0% | 0/15 | 0/25 | 40 |
| `komira_search_scan` | none | 39 | 0 | 0.0% | 0/15 | 0/24 | 39 |
| `komira_gcp_wif` | none | 36 | 0 | 0.0% | 0/27 | 0/9 | 36 |
| `kci_release_set` | none | 35 | 0 | 0.0% | 0/30 | 0/5 | 35 |
| `komira_aws_lambda_http` | none | 35 | 0 | 0.0% | 0/29 | 0/6 | 35 |
| `komira_azure_core` | none | 35 | 0 | 0.0% | 0/9 | 0/26 | 35 |
| `komira_search_catalog` | none | 34 | 0 | 0.0% | 0/20 | 0/14 | 34 |
| `komira_iceberg_catalog` | none | 32 | 0 | 0.0% | 0/13 | 0/19 | 32 |
| `komira_gcp_monitoring` | none | 27 | 0 | 0.0% | 0/22 | 0/5 | 27 |
| `komira_pplan_wire` | none | 24 | 0 | 0.0% | 0/24 | 0/0 | 24 |
| `komira_db_sqlite` | none | 23 | 0 | 0.0% | 0/1 | 0/22 | 23 |
| `komira_log_query` | none | 23 | 0 | 0.0% | 0/18 | 0/5 | 23 |
| `komira_aws_metrics` | none | 21 | 0 | 0.0% | 0/18 | 0/3 | 21 |
| `komira_rowcell` | none | 21 | 0 | 0.0% | 0/15 | 0/6 | 21 |
| `komira_secret_registry` | none | 18 | 0 | 0.0% | 0/4 | 0/14 | 18 |
| `komira_authz_api` | none | 17 | 0 | 0.0% | 0/5 | 0/12 | 17 |
| `kci_secret_writer` | none | 15 | 0 | 0.0% | 0/2 | 0/13 | 15 |
| `komira_secret_env` | no-example | 14 | 0 | 0.0% | 0/7 | 0/7 | 14 |
| `komira_secret_store` | none | 14 | 0 | 0.0% | 0/5 | 0/9 | 14 |
| `komira_jsonl` | none | 12 | 0 | 0.0% | 0/12 | 0/0 | 12 |
| `komira_zlib` | none | 12 | 0 | 0.0% | 0/12 | 0/0 | 12 |
| `komira_uuid` | none | 10 | 0 | 0.0% | 0/3 | 0/7 | 10 |
| `kci_publish_oci` | none | 6 | 0 | 0.0% | 0/4 | 0/2 | 6 |
| `komira_sync` | none | 4 | 0 | 0.0% | 0/1 | 0/3 | 4 |
| `komira_jwks` | none | 3 | 0 | 0.0% | 0/3 | 0/0 | 3 |

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
  submodules (`komira_async`, `komira_arrow`) counts nothing until submodule
  exports are counted.
- A use is an identifier match, not name resolution: a method name or a
  short name shared with another API can count as used when it is not.
- A struct's methods are found by its name; two structs of the exported name
  in the module the import names are merged. When the named module has no
  struct of that name (it re-exports it from a sibling), every non-`tests/`
  file of the package is searched, so a same-named struct in a `bench/` or
  `examples/` directory would be merged too.
