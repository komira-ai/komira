# The Mojo libraries not published on mopm

A Mojo library is a directory `src/<name>` with a `BUCK` file and a `.mojo` file outside its `tests/`.
The release publishes a library when it is a member of `PACKAGES` in
[readme_e2e/packages.bzl](readme_e2e/packages.bzl) (a package with a `mopm.toml`, whose README examples
the release's README e2e runs against the installed copy). Every other library has a row here, with
the reason it is not published. `//release:unpublished_cases` ([unpublished_test.zig](unpublished_test.zig))
fails the build when a library is neither a member nor in this table, when a row names a member or a
directory that is no library, when a row does not parse, or when the counts below are not the table's.
A row whose reason is "depends on an unpublished library" names those libraries in backticks, and each
must have a row here: when one of them is published, the check refuses the row until it says the
reason that is left.

So publishing a library deletes its row in the same change, and a new library adds one.

## The reasons

| Reason | What it means |
|---|---|
| no README example | its `README.md` holds no `mojo` example, and the release refuses a package whose README has none |
| test-only | it exists only to test or benchmark komira itself; nobody would depend on it |
| internal | it belongs to a hosted service and is not meant to be a public package |
| native dependency pending | it owns C, or links a vendored library, through a native shared library; a mopm package declares its native code as a static archive, and that move is not made yet |
| renamed or superseded | another library replaces it |
| depends on an unpublished library | its own sources and README are ready, and it imports a library that is not published (named in the detail) |
| none | nothing holds it back: every library it imports is published and its README has examples |

A library is given the first reason of this order that applies to it: test-only, native dependency
pending, no README example, depends on an unpublished library, none. The imports counted are those of
the library's own sources, not of its tests, docstrings or comments. "internal" and "renamed or
superseded" are read from the code by hand, and no library has either today. In the detail of a
"depends on an unpublished library" row, only library names are in backticks.

## Counts

| Reason | Libraries |
|---|---|
| no README example | 41 |
| test-only | 5 |
| internal | 0 |
| native dependency pending | 8 |
| renamed or superseded | 0 |
| depends on an unpublished library | 137 |
| none | 7 |

## The libraries

| Library | Reason | Detail |
|---|---|---|
| [`agg`](../src/agg/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`agg_api`](../src/agg_api/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`arrow`](../src/arrow/) | none | every library it imports is published, and its README.md holds 2 examples |
| [`arrow_ipc`](../src/arrow_ipc/) | depends on an unpublished library | imports `arrow` |
| [`async_rt`](../src/async_rt/) | native dependency pending | owns C (reactor/_posix_shim.c) linked through a native shared library; it is not yet the static archive a mopm package declares |
| [`authz_api`](../src/authz_api/) | depends on an unpublished library | imports `async_rt`, `http_server` |
| [`avro`](../src/avro/) | depends on an unpublished library | imports `arrow`, `async_rt`, `fs`, `row_format` |
| [`aws_apigatewayv2`](../src/aws_apigatewayv2/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_core`](../src/aws_core/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core` |
| [`aws_dynamodb`](../src/aws_dynamodb/) | depends on an unpublished library | imports `aws_core`; its client is generated at build time by the AWS client generator |
| [`aws_dynamodbstreams`](../src/aws_dynamodbstreams/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_ec2`](../src/aws_ec2/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_ecr`](../src/aws_ecr/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_ecs`](../src/aws_ecs/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_iam`](../src/aws_iam/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_lambda`](../src/aws_lambda/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_lambda_http`](../src/aws_lambda_http/) | depends on an unpublished library | imports `async_rt`, `http_core`, `http_server` |
| [`aws_logs`](../src/aws_logs/) | depends on an unpublished library | imports `aws_core`; its client is generated at build time by the AWS client generator |
| [`aws_metrics`](../src/aws_metrics/) | depends on an unpublished library | imports `aws_core`, `metrics_reader` |
| [`aws_route53`](../src/aws_route53/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_s3`](../src/aws_s3/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_scheduler`](../src/aws_scheduler/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_secret_store`](../src/aws_secret_store/) | depends on an unpublished library | imports `aws_core`, `aws_secretsmanager`, `http_core`, `secret_store` |
| [`aws_secretsmanager`](../src/aws_secretsmanager/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_ses`](../src/aws_ses/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_sesv2`](../src/aws_sesv2/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_sns`](../src/aws_sns/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`aws_sqs`](../src/aws_sqs/) | depends on an unpublished library | imports `aws_core`, `http_client`, `http_core`; its client is generated at build time by the AWS client generator |
| [`azure_blob`](../src/azure_blob/) | depends on an unpublished library | imports `async_rt`, `azure_core`, `fs`, `http_client`, `http_core`, `objectstore`, `plan_expr` |
| [`azure_core`](../src/azure_core/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core` |
| [`batch_eval`](../src/batch_eval/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`bench_corpus`](../src/bench_corpus/) | none | every library it imports is published, and its README.md holds 1 example |
| [`bench_data`](../src/bench_data/) | test-only | the datasets of komira's own benchmarks: their manifests, a verifier and a table generator |
| [`bench_duckdb`](../src/bench_duckdb/) | test-only | the DuckDB comparison arm of komira's own benchmarks |
| [`bench_q6_phases`](../src/bench_q6_phases/) | test-only | a profiling probe of the engine's phases on one benchmark query, built only for benchmark runs |
| [`bench_runner`](../src/bench_runner/) | test-only | runs komira's own benchmarks against DuckDB and writes their result file |
| [`broker`](../src/broker/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `async_rt`, `column_kernels`, `objectstore`, `plan_expr`, `scan_resolver`, `scan_source` |
| [`broker_compaction`](../src/broker_compaction/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`broker_coordinator`](../src/broker_coordinator/) | depends on an unpublished library | imports `async_rt`, `broker`, `http_core`, `http_server`, `objectstore` |
| [`calendar_store`](../src/calendar_store/) | depends on an unpublished library | imports `async_rt`, `db` |
| [`cdc_ingest`](../src/cdc_ingest/) | depends on an unpublished library | imports `iceberg`, `objectstore` |
| [`chat_store`](../src/chat_store/) | depends on an unpublished library | imports `async_rt`, `db` |
| [`chunk`](../src/chunk/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`column_format`](../src/column_format/) | depends on an unpublished library | imports `arrow` |
| [`column_kernels`](../src/column_kernels/) | depends on an unpublished library | imports `arrow`, `plan_expr` |
| [`comms_index`](../src/comms_index/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`connect`](../src/connect/) | depends on an unpublished library | imports `http_core`, `http_server` |
| [`contacts`](../src/contacts/) | depends on an unpublished library | imports `async_rt`, `db` |
| [`crm`](../src/crm/) | depends on an unpublished library | imports `async_rt`, `db` |
| [`csv`](../src/csv/) | depends on an unpublished library | imports `arrow`, `async_rt`, `fs`, `row_format`, `scan_source` |
| [`db`](../src/db/) | depends on an unpublished library | imports `async_rt` |
| [`db_postgres`](../src/db_postgres/) | depends on an unpublished library | imports `async_rt`, `db`, `http_core`, `net` |
| [`db_sqlite`](../src/db_sqlite/) | native dependency pending | links SQLite, built from third_party/sqlite, through a native shared library; it is not yet the static archive a mopm package declares |
| [`decimal_literal`](../src/decimal_literal/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`dispatch_agg_exec`](../src/dispatch_agg_exec/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`dispatch_agg_folds`](../src/dispatch_agg_folds/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`dispatch_join_kernels`](../src/dispatch_join_kernels/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`dispatch_project`](../src/dispatch_project/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`dispatch_scan`](../src/dispatch_scan/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`dispatch_sources`](../src/dispatch_sources/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`engine_runtime`](../src/engine_runtime/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`eval`](../src/eval/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`exec_types`](../src/exec_types/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`expr`](../src/expr/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`flight`](../src/flight/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `op_sources` |
| [`flight_server`](../src/flight_server/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `broker`, `connect`, `flight`, `http_core`, `objectstore`, `op_sources` |
| [`fs`](../src/fs/) | native dependency pending | owns C (_fs_shim.c) linked through a native shared library; it is not yet the static archive a mopm package declares |
| [`gcp_apigateway`](../src/gcp_apigateway/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_artifactregistry`](../src/gcp_artifactregistry/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_cloudresourcemanager`](../src/gcp_cloudresourcemanager/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_cloudscheduler`](../src/gcp_cloudscheduler/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_compute`](../src/gcp_compute/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_core`](../src/gcp_core/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core` |
| [`gcp_fcm`](../src/gcp_fcm/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core` |
| [`gcp_firestore`](../src/gcp_firestore/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `grpc`, `http_client`, `http_core`, `objectstore`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_firestore_db`](../src/gcp_firestore_db/) | depends on an unpublished library | imports `async_rt`, `db`, `gcp_core`, `gcp_firestore`, `http_core` |
| [`gcp_iam`](../src/gcp_iam/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_logging`](../src/gcp_logging/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_monitoring`](../src/gcp_monitoring/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `gcp_monitoring_client`, `http_client`, `http_core`, `metrics_reader` |
| [`gcp_monitoring_client`](../src/gcp_monitoring_client/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_run`](../src/gcp_run/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_secret_store`](../src/gcp_secret_store/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `gcp_secretmanager`, `http_core`, `secret_store` |
| [`gcp_secretmanager`](../src/gcp_secretmanager/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core` |
| [`gcp_serviceusage`](../src/gcp_serviceusage/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `http_client`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_storage`](../src/gcp_storage/) | depends on an unpublished library | imports `async_rt`, `gcp_core`, `grpc`, `http_core`; its client is generated at build time by the Google Cloud client generator |
| [`gcp_wif`](../src/gcp_wif/) | depends on an unpublished library | imports `async_rt`, `aws_core`, `gcp_core`, `http_client`, `http_core` |
| [`git`](../src/git/) | none | every library it imports is published, and its README.md holds 9 examples |
| [`group_ratchet`](../src/group_ratchet/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`grpc`](../src/grpc/) | depends on an unpublished library | imports `async_rt`, `connect`, `http_client`, `http_core` |
| [`host_profile`](../src/host_profile/) | depends on an unpublished library | imports `arrow`, `physical_plan` |
| [`http_auth`](../src/http_auth/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core`, `http_server`, `jose`, `jwks` |
| [`http_client`](../src/http_client/) | depends on an unpublished library | imports `async_rt`, `http_core`, `net` |
| [`http_core`](../src/http_core/) | native dependency pending | links s2n-tls, built from third_party/s2n-tls, through a native shared library; it is not yet the static archive a mopm package declares |
| [`http_server`](../src/http_server/) | depends on an unpublished library | imports `async_rt`, `http_core` |
| [`iceberg`](../src/iceberg/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`iceberg_catalog`](../src/iceberg_catalog/) | depends on an unpublished library | imports `arrow`, `async_rt`, `fs`, `http_client`, `http_core`, `iceberg`, `objectstore` |
| [`iceberg_scan`](../src/iceberg_scan/) | depends on an unpublished library | imports `arrow`, `async_rt`, `avro`, `column_kernels`, `fs`, `parquet`, `physical_plan`, `plan_expr`, `scan_source` |
| [`imap_server`](../src/imap_server/) | depends on an unpublished library | imports `async_rt`, `comms_index`, `mail_auth`, `mail_store`, `mail_tls`, `objectstore`, `smtp_server` |
| [`job_supervisor`](../src/job_supervisor/) | depends on an unpublished library | imports `async_rt`, `aws_core`, `gcp_core`, `http_client`, `http_core`, `objectstore`, `objectstore_gcs`, `objectstore_s3`, `secret_env`, `secret_store`, `supervisor` |
| [`join_assembly`](../src/join_assembly/) | depends on an unpublished library | imports `arrow`, `column_kernels`, `plan_ir` |
| [`jose`](../src/jose/) | depends on an unpublished library | imports `jwks`, `secret_store` |
| [`json_index`](../src/json_index/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`jsonl`](../src/jsonl/) | depends on an unpublished library | imports `arrow`, `async_rt`, `json_index`, `row_format` |
| [`jwks`](../src/jwks/) | depends on an unpublished library | imports `secret_store` |
| [`kafka_broker`](../src/kafka_broker/) | depends on an unpublished library | imports `arrow`, `objectstore` |
| [`kernels`](../src/kernels/) | depends on an unpublished library | imports `arrow`, `column_kernels`, `plan_expr`, `udf` |
| [`kg`](../src/kg/) | depends on an unpublished library | imports `arrow`, `kg_format`, `objectstore`, `parquet` |
| [`kg_capture`](../src/kg_capture/) | depends on an unpublished library | imports `async_rt`, `http_core`, `http_server`, `kg`, `kg_format`, `kg_sources`, `objectstore` |
| [`kg_code`](../src/kg_code/) | depends on an unpublished library | imports `arrow` |
| [`kg_enrich`](../src/kg_enrich/) | depends on an unpublished library | imports `objectstore` |
| [`kg_format`](../src/kg_format/) | depends on an unpublished library | imports `arrow`, `objectstore`, `parquet`, `parquet_writer` |
| [`kg_llm`](../src/kg_llm/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core`, `kg`, `kg_format` |
| [`kg_sources`](../src/kg_sources/) | depends on an unpublished library | imports `kg`, `kg_format`, `objectstore` |
| [`log_index`](../src/log_index/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`log_query`](../src/log_query/) | depends on an unpublished library | imports `http_core` |
| [`lowering`](../src/lowering/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`lowering_rules`](../src/lowering_rules/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `plan_ir`, `plan_stats` |
| [`mail_auth`](../src/mail_auth/) | none | every library it imports is published, and its README.md holds 3 examples |
| [`mail_store`](../src/mail_store/) | depends on an unpublished library | imports `objectstore` |
| [`mail_tls`](../src/mail_tls/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`metrics_reader`](../src/metrics_reader/) | depends on an unpublished library | imports `http_core` |
| [`morsel`](../src/morsel/) | depends on an unpublished library | imports `arrow`, `column_kernels`, `exec_types`, `physical_plan`, `plan_expr`, `plan_ir`, `plan_stats`, `scan_source` |
| [`net`](../src/net/) | depends on an unpublished library | imports `async_rt` |
| [`oauth`](../src/oauth/) | depends on an unpublished library | imports `jose`, `jwks` |
| [`objectstore`](../src/objectstore/) | native dependency pending | owns C (_objectstore_shim.c) linked through a native shared library; it is not yet the static archive a mopm package declares |
| [`objectstore_gcs`](../src/objectstore_gcs/) | depends on an unpublished library | imports `async_rt`, `fs`, `gcp_core`, `gcp_storage`, `grpc`, `http_client`, `http_core`, `objectstore`, `plan_expr` |
| [`objectstore_s3`](../src/objectstore_s3/) | depends on an unpublished library | imports `aws_core`, `aws_s3`, `fs`, `http_client`, `http_core`, `objectstore`, `plan_expr` |
| [`oci`](../src/oci/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core` |
| [`op_agg_distinct`](../src/op_agg_distinct/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`op_agg_hash`](../src/op_agg_hash/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`op_agg_row_api`](../src/op_agg_row_api/) | depends on an unpublished library | imports `column_format` |
| [`op_agg_slab`](../src/op_agg_slab/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`op_agg_stage`](../src/op_agg_stage/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`op_agg_state`](../src/op_agg_state/) | depends on an unpublished library | imports `agg`, `agg_api`, `arrow`, `expr`, `kernels`, `plan_expr`, `udf` |
| [`op_asof`](../src/op_asof/) | depends on an unpublished library | imports `arrow`, `engine_runtime`, `expr`, `join_assembly`, `op_sort`, `operator_api`, `physical_plan`, `plan_ir` |
| [`op_fused_kernels`](../src/op_fused_kernels/) | depends on an unpublished library | imports `arrow`, `async_rt`, `column_kernels`, `engine_runtime`, `join_assembly`, `op_agg_hash`, `op_join_build`, `plan_expr`, `plan_ir` |
| [`op_join_build`](../src/op_join_build/) | depends on an unpublished library | imports `arrow`, `async_rt`, `column_format`, `engine_runtime`, `join_assembly`, `udf` |
| [`op_join_probe`](../src/op_join_probe/) | depends on an unpublished library | imports `arrow`, `async_rt`, `batch_eval`, `column_kernels`, `engine_runtime`, `exec_types`, `join_assembly`, `morsel`, `op_fused_kernels`, `op_join_build`, `op_sort`, `operator_api`, `physical_plan`, `plan_expr`, `plan_ir`, `udf` |
| [`op_join_sinks`](../src/op_join_sinks/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`op_join_stage`](../src/op_join_stage/) | depends on an unpublished library | imports `arrow`, `engine_runtime`, `expr`, `operator_api`, `udf` |
| [`op_sort`](../src/op_sort/) | depends on an unpublished library | imports `arrow`, `async_rt`, `column_format`, `column_kernels`, `engine_runtime`, `exec_types`, `expr`, `operator_api`, `physical_plan`, `udf` |
| [`op_sources`](../src/op_sources/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`op_spill_rows`](../src/op_spill_rows/) | depends on an unpublished library | imports `arrow`, `async_rt`, `engine_runtime`, `op_sort`, `row_format` |
| [`op_typed_source_api`](../src/op_typed_source_api/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `async_rt`, `avro`, `column_format`, `csv`, `fs`, `host_profile`, `jsonl`, `morsel`, `op_agg_row_api`, `parquet`, `parquet_codec`, `physical_plan`, `plan_expr`, `plan_ir`, `scan_source` |
| [`op_window`](../src/op_window/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`operator_api`](../src/operator_api/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`optimized_plan`](../src/optimized_plan/) | depends on an unpublished library | imports `optimized_plan_header`, `plan_ir`, `plan_wire` |
| [`optimized_plan_header`](../src/optimized_plan_header/) | none | every library it imports is published, and its README.md holds 1 example |
| [`optimizer`](../src/optimizer/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`orc`](../src/orc/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `async_rt`, `column_kernels`, `fs`, `plan_expr` |
| [`parquet`](../src/parquet/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `async_rt`, `fs`, `parquet_codec`, `plan_expr`, `plan_stats` |
| [`parquet_codec`](../src/parquet_codec/) | native dependency pending | links the Brotli decoder and other codecs from third_party through a native shared library; it is not yet the static archive a mopm package declares |
| [`parquet_footers`](../src/parquet_footers/) | depends on an unpublished library | imports `arrow`, `async_rt`, `fs`, `iceberg_scan`, `lowering`, `parquet`, `plan_expr`, `plan_stats`, `scan_source`, `sql` |
| [`parquet_scan`](../src/parquet_scan/) | depends on an unpublished library | imports `arrow`, `async_rt`, `batch_eval`, `column_kernels`, `engine_runtime`, `exec_types`, `fs`, `host_profile`, `morsel`, `parquet`, `phase_timers`, `plan_expr`, `plan_stats`, `scan_planning`, `scan_source` |
| [`parquet_writer`](../src/parquet_writer/) | depends on an unpublished library | imports `arrow`, `column_kernels`, `parquet_codec` |
| [`phase_timers`](../src/phase_timers/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`physical_plan`](../src/physical_plan/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `plan_ir` |
| [`pipeline_exec`](../src/pipeline_exec/) | depends on an unpublished library | imports `arrow`, `async_rt`, `batch_eval`, `column_kernels`, `csv`, `engine_runtime`, `exec_types`, `fs`, `iceberg_scan`, `join_assembly`, `jsonl`, `morsel`, `op_join_probe`, `op_sort`, `op_sources`, `op_spill_rows`, `op_window`, `operator_api`, `parquet`, `parquet_codec`, `parquet_scan`, `phase_timers`, `physical_plan`, `plan_expr`, `plan_ir`, `plan_stats`, `scan_planning` |
| [`plan_expr`](../src/plan_expr/) | depends on an unpublished library | imports `arrow` |
| [`plan_ir`](../src/plan_ir/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `plan_stats`, `scan_source` |
| [`plan_stats`](../src/plan_stats/) | depends on an unpublished library | imports `arrow`, `plan_expr` |
| [`plan_wire`](../src/plan_wire/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `plan_ir`, `scan_source` |
| [`pplan_wire`](../src/pplan_wire/) | depends on an unpublished library | imports `arrow`, `physical_plan`, `plan_expr`, `plan_ir` |
| [`resource_gate`](../src/resource_gate/) | depends on an unpublished library | imports `async_rt`, `authz_api`, `http_core`, `http_server` |
| [`row_format`](../src/row_format/) | depends on an unpublished library | imports `arrow`, `scan_source`, `udf` |
| [`scan_planning`](../src/scan_planning/) | depends on an unpublished library | imports `arrow`, `fs`, `plan_expr` |
| [`scan_resolver`](../src/scan_resolver/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `scan_source` |
| [`scan_source`](../src/scan_source/) | native dependency pending | owns C (native/komira_scan_source_inmem_id.c) linked through a native shared library; it is not yet the static archive a mopm package declares |
| [`sdk`](../src/sdk/) | depends on an unpublished library | imports `arrow`, `async_rt`, `fs`, `parquet`, `plan_expr`, `plan_ir`, `scan_source`, `udf` |
| [`sdk_exec`](../src/sdk_exec/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `async_rt`, `column_kernels`, `engine_runtime`, `fs`, `host_profile`, `iceberg_catalog`, `iceberg_scan`, `lowering`, `optimizer`, `parquet`, `parquet_footers`, `parquet_writer`, `phase_timers`, `physical_plan`, `pipeline_exec`, `plan_expr`, `plan_ir`, `plan_wire`, `scan_source`, `sdk`, `secret_registry`, `secret_store`, `sql` |
| [`search`](../src/search/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `scan_source` |
| [`search_catalog`](../src/search_catalog/) | depends on an unpublished library | imports `objectstore` |
| [`search_compaction`](../src/search_compaction/) | depends on an unpublished library | imports `arrow`, `objectstore`, `search`, `search_catalog` |
| [`search_http`](../src/search_http/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`search_scan`](../src/search_scan/) | depends on an unpublished library | imports `arrow`, `plan_expr`, `scan_resolver`, `scan_source`, `search` |
| [`secret_env`](../src/secret_env/) | depends on an unpublished library | imports `secret_store` |
| [`secret_registry`](../src/secret_registry/) | depends on an unpublished library | imports `secret_store` |
| [`secret_store`](../src/secret_store/) | none | every library it imports is published, and its README.md holds 2 examples |
| [`secrets`](../src/secrets/) | depends on an unpublished library | imports `async_rt`, `db`, `secret_store` |
| [`secrets_azure`](../src/secrets_azure/) | depends on an unpublished library | imports `async_rt`, `azure_core`, `http_client`, `http_core`, `secret_store` |
| [`secrets_conjur`](../src/secrets_conjur/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core`, `secret_store` |
| [`secrets_keychain`](../src/secrets_keychain/) | depends on an unpublished library | imports `secret_store`, `supervisor` |
| [`shuffle`](../src/shuffle/) | depends on an unpublished library | imports `objectstore` |
| [`shuffle_streaming`](../src/shuffle_streaming/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`smtp_client`](../src/smtp_client/) | depends on an unpublished library | imports `async_rt`, `http_client`, `http_core`, `net` |
| [`smtp_server`](../src/smtp_server/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`so`](../src/so/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `csv`, `plan_ir`, `plan_wire`, `scan_source`, `sdk`, `sdk_exec`, `secret_registry`, `secret_store`, `sql` |
| [`source_url`](../src/source_url/) | depends on an unpublished library | imports `plan_expr` |
| [`sql`](../src/sql/) | depends on an unpublished library | imports `arrow`, `arrow_ipc`, `avro`, `column_kernels`, `csv`, `decimal_literal`, `jsonl`, `parquet_codec`, `plan_expr`, `plan_ir`, `scan_source` |
| [`supervisor`](../src/supervisor/) | native dependency pending | owns C (_proc_shim.c, _proc_io_shim.c) linked through a native shared library; it is not yet the static archive a mopm package declares |
| [`table_store`](../src/table_store/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`telemetry_read`](../src/telemetry_read/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`telemetry_store`](../src/telemetry_store/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`tpch_answers`](../src/tpch_answers/) | test-only | the reference answers komira's benchmark queries are checked against |
| [`udf`](../src/udf/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`udf_host`](../src/udf_host/) | no README example | its README.md holds no mojo example, which the release README gate refuses |
| [`viewport`](../src/viewport/) | depends on an unpublished library | imports `plan_expr` |
| [`webpush`](../src/webpush/) | none | every library it imports is published, and its README.md holds 4 examples |
