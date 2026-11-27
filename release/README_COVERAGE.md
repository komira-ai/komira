# Which READMEs the release runs

Every `src/<name>/README.md` of the repository, and who runs its `mojo` examples. The graph check
`//release:readme_coverage` ([readme_coverage.zig](../tools/build/selftest/graph/readme_coverage.zig))
writes this text from the build graph and the READMEs, and the pull request check fails when this
file is not that text byte for byte, printing each line that differs with the line it must be. So a
package that gains or loses a `mopm.toml`, a README e2e target, a README gate or its last example
changes its row in the same change. Do not edit it by hand: copy the lines the check prints.

| Column | What it says | Read from |
|---|---|---|
| `mopm.toml` | the package has a `src/<name>/mopm.toml`: the release publishes it on mopm | the files of the checkout (the root `doc_tree`) |
| e2e | `//release/readme_e2e/verify:<name>` exists: the release installs the staged package into a fresh project and runs the README's examples against the installed copy ([readme_e2e](../tools/build/readme_e2e/README.md)) | the `readme_e2e` targets of that package, each installing `<namespace>/<its name>` |
| gate | the README gate that runs the examples inside the build, against the library as the build holds it: `mojo_adopted_library` or `mojo_library` (a target of `//src/<name>` of that rule whose `readme` is this README), or `none` | the rule and the `readme` of every target under `//src/` |
| example | `yes` when the README holds at least one example (a `mojo` or `mojo module` fenced block, as the README examples tool reads it), `no` when it holds none, `refused` when that tool refuses the README | the README |
| run by | who runs the examples: `release e2e` (e2e and example are yes), `build gate` (a gate, and example is yes), both, or `nobody` | the columns before it |

## Counts

| READMEs | Count |
|---|---|
| every `src/<name>/README.md` | 265 |
| with a `mopm.toml` | 66 |
| with a README e2e target | 66 |
| with a `mojo_adopted_library` gate | 66 |
| with a `mojo_library` gate | 197 |
| with no gate | 2 |
| with at least one example | 249 |
| refused by the README examples tool | 0 |
| run by the release e2e | 66 |
| run by a build gate | 249 |
| run by nobody | 16 |

## Left out

Run by a build gate and not by the release e2e: 183 READMEs. Their packages have no `mopm.toml`, so the release does not publish them; [UNPUBLISHED.md](UNPUBLISHED.md) says why for each library.

Run by nobody (16): [`dispatch_sources`](../src/dispatch_sources/README.md), [`engine_runtime`](../src/engine_runtime/README.md), [`eval`](../src/eval/README.md), [`exec_types`](../src/exec_types/README.md), [`expr`](../src/expr/README.md), [`group_ratchet`](../src/group_ratchet/README.md), [`iceberg`](../src/iceberg/README.md), [`json_index`](../src/json_index/README.md), [`log_index`](../src/log_index/README.md), [`lowering`](../src/lowering/README.md), [`mail_tls`](../src/mail_tls/README.md), [`op_agg_distinct`](../src/op_agg_distinct/README.md), [`op_agg_hash`](../src/op_agg_hash/README.md), [`op_agg_slab`](../src/op_agg_slab/README.md), [`udf_abi`](../src/udf_abi/README.md), [`udf_python`](../src/udf_python/README.md).

## The READMEs

| Package | `mopm.toml` | e2e | gate | example | run by |
|---|---|---|---|---|---|
| [`agg`](../src/agg/README.md) | no | no | mojo_library | yes | build gate |
| [`agg_api`](../src/agg_api/README.md) | no | no | mojo_library | yes | build gate |
| [`anomaly`](../src/anomaly/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`arrow`](../src/arrow/README.md) | no | no | mojo_library | yes | build gate |
| [`arrow_ipc`](../src/arrow_ipc/README.md) | no | no | mojo_library | yes | build gate |
| [`async_api`](../src/async_api/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`async_rt`](../src/async_rt/README.md) | no | no | mojo_library | yes | build gate |
| [`atomic_alias`](../src/atomic_alias/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`authz_api`](../src/authz_api/README.md) | no | no | mojo_library | yes | build gate |
| [`avro`](../src/avro/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_apigatewayv2`](../src/aws_apigatewayv2/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_core`](../src/aws_core/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_dynamodb`](../src/aws_dynamodb/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_dynamodbstreams`](../src/aws_dynamodbstreams/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_ec2`](../src/aws_ec2/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_ecr`](../src/aws_ecr/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_ecs`](../src/aws_ecs/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_iam`](../src/aws_iam/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_lambda`](../src/aws_lambda/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_lambda_http`](../src/aws_lambda_http/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_logs`](../src/aws_logs/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_metrics`](../src/aws_metrics/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_route53`](../src/aws_route53/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_s3`](../src/aws_s3/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_scheduler`](../src/aws_scheduler/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_secret_store`](../src/aws_secret_store/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_secretsmanager`](../src/aws_secretsmanager/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_ses`](../src/aws_ses/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_sesv2`](../src/aws_sesv2/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_sns`](../src/aws_sns/README.md) | no | no | mojo_library | yes | build gate |
| [`aws_sqs`](../src/aws_sqs/README.md) | no | no | mojo_library | yes | build gate |
| [`awslc`](../src/awslc/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`azure_blob`](../src/azure_blob/README.md) | no | no | mojo_library | yes | build gate |
| [`azure_core`](../src/azure_core/README.md) | no | no | mojo_library | yes | build gate |
| [`batch_eval`](../src/batch_eval/README.md) | no | no | mojo_library | yes | build gate |
| [`bench`](../src/bench/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`bench_corpus`](../src/bench_corpus/README.md) | no | no | mojo_library | yes | build gate |
| [`bench_data`](../src/bench_data/README.md) | no | no | mojo_library | yes | build gate |
| [`bench_duckdb`](../src/bench_duckdb/README.md) | no | no | mojo_library | yes | build gate |
| [`bench_q6_phases`](../src/bench_q6_phases/README.md) | no | no | mojo_library | yes | build gate |
| [`bench_report`](../src/bench_report/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`bench_runner`](../src/bench_runner/README.md) | no | no | mojo_library | yes | build gate |
| [`broker`](../src/broker/README.md) | no | no | mojo_library | yes | build gate |
| [`broker_compaction`](../src/broker_compaction/README.md) | no | no | mojo_library | yes | build gate |
| [`broker_coordinator`](../src/broker_coordinator/README.md) | no | no | mojo_library | yes | build gate |
| [`broker_proto`](../src/broker_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`bump_arena`](../src/bump_arena/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`byte_buffer`](../src/byte_buffer/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`calendar`](../src/calendar/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`calendar_ics`](../src/calendar_ics/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`calendar_proto`](../src/calendar_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`calendar_store`](../src/calendar_store/README.md) | no | no | mojo_library | yes | build gate |
| [`cdc_ingest`](../src/cdc_ingest/README.md) | no | no | mojo_library | yes | build gate |
| [`chat_proto`](../src/chat_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`chat_store`](../src/chat_store/README.md) | no | no | mojo_library | yes | build gate |
| [`chunk`](../src/chunk/README.md) | no | no | mojo_library | yes | build gate |
| [`clock`](../src/clock/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`codeworks_api`](../src/codeworks_api/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`column_format`](../src/column_format/README.md) | no | no | mojo_library | yes | build gate |
| [`column_kernels`](../src/column_kernels/README.md) | no | no | mojo_library | yes | build gate |
| [`comms_index`](../src/comms_index/README.md) | no | no | mojo_library | yes | build gate |
| [`compression`](../src/compression/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`connect`](../src/connect/README.md) | no | no | mojo_library | yes | build gate |
| [`contacts`](../src/contacts/README.md) | no | no | mojo_library | yes | build gate |
| [`contacts_proto`](../src/contacts_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`containers`](../src/containers/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`content_line`](../src/content_line/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`counters`](../src/counters/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`crm`](../src/crm/README.md) | no | no | mojo_library | yes | build gate |
| [`crm_proto`](../src/crm_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`crypto`](../src/crypto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`csv`](../src/csv/README.md) | no | no | mojo_library | yes | build gate |
| [`datetime`](../src/datetime/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`db`](../src/db/README.md) | no | no | mojo_library | yes | build gate |
| [`db_postgres`](../src/db_postgres/README.md) | no | no | mojo_library | yes | build gate |
| [`db_sqlite`](../src/db_sqlite/README.md) | no | no | mojo_library | yes | build gate |
| [`decimal_literal`](../src/decimal_literal/README.md) | no | no | mojo_library | yes | build gate |
| [`dispatch_agg_exec`](../src/dispatch_agg_exec/README.md) | no | no | mojo_library | yes | build gate |
| [`dispatch_agg_folds`](../src/dispatch_agg_folds/README.md) | no | no | mojo_library | yes | build gate |
| [`dispatch_join_kernels`](../src/dispatch_join_kernels/README.md) | no | no | mojo_library | yes | build gate |
| [`dispatch_project`](../src/dispatch_project/README.md) | no | no | mojo_library | yes | build gate |
| [`dispatch_scan`](../src/dispatch_scan/README.md) | no | no | mojo_library | yes | build gate |
| [`dispatch_sources`](../src/dispatch_sources/README.md) | no | no | mojo_library | no | nobody |
| [`dynamic_filter`](../src/dynamic_filter/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`encoding`](../src/encoding/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`engine_runtime`](../src/engine_runtime/README.md) | no | no | mojo_library | no | nobody |
| [`eval`](../src/eval/README.md) | no | no | mojo_library | no | nobody |
| [`exec_types`](../src/exec_types/README.md) | no | no | mojo_library | no | nobody |
| [`expr`](../src/expr/README.md) | no | no | mojo_library | no | nobody |
| [`flight`](../src/flight/README.md) | no | no | mojo_library | yes | build gate |
| [`flight_server`](../src/flight_server/README.md) | no | no | mojo_library | yes | build gate |
| [`fork_join`](../src/fork_join/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`fs`](../src/fs/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_apigateway`](../src/gcp_apigateway/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_artifactregistry`](../src/gcp_artifactregistry/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_cloudresourcemanager`](../src/gcp_cloudresourcemanager/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_cloudscheduler`](../src/gcp_cloudscheduler/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_compute`](../src/gcp_compute/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_core`](../src/gcp_core/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_fcm`](../src/gcp_fcm/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_firestore`](../src/gcp_firestore/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_firestore_db`](../src/gcp_firestore_db/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_iam`](../src/gcp_iam/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_logging`](../src/gcp_logging/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_monitoring`](../src/gcp_monitoring/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_monitoring_client`](../src/gcp_monitoring_client/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_run`](../src/gcp_run/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_secret_store`](../src/gcp_secret_store/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_secretmanager`](../src/gcp_secretmanager/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_serviceusage`](../src/gcp_serviceusage/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_storage`](../src/gcp_storage/README.md) | no | no | mojo_library | yes | build gate |
| [`gcp_wif`](../src/gcp_wif/README.md) | no | no | mojo_library | yes | build gate |
| [`git`](../src/git/README.md) | no | no | mojo_library | yes | build gate |
| [`group_ratchet`](../src/group_ratchet/README.md) | no | no | mojo_library | no | nobody |
| [`grpc`](../src/grpc/README.md) | no | no | mojo_library | yes | build gate |
| [`hashing`](../src/hashing/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`host_probe`](../src/host_probe/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`host_profile`](../src/host_profile/README.md) | no | no | mojo_library | yes | build gate |
| [`http_auth`](../src/http_auth/README.md) | no | no | mojo_library | yes | build gate |
| [`http_client`](../src/http_client/README.md) | no | no | mojo_library | yes | build gate |
| [`http_core`](../src/http_core/README.md) | no | no | mojo_library | yes | build gate |
| [`http_server`](../src/http_server/README.md) | no | no | mojo_library | yes | build gate |
| [`iceberg`](../src/iceberg/README.md) | no | no | mojo_library | no | nobody |
| [`iceberg_catalog`](../src/iceberg_catalog/README.md) | no | no | mojo_library | yes | build gate |
| [`iceberg_scan`](../src/iceberg_scan/README.md) | no | no | mojo_library | yes | build gate |
| [`imap_server`](../src/imap_server/README.md) | no | no | mojo_library | yes | build gate |
| [`job_report_proto`](../src/job_report_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`job_supervisor`](../src/job_supervisor/README.md) | no | no | mojo_library | yes | build gate |
| [`join_assembly`](../src/join_assembly/README.md) | no | no | mojo_library | yes | build gate |
| [`jose`](../src/jose/README.md) | no | no | mojo_library | yes | build gate |
| [`json`](../src/json/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`json_index`](../src/json_index/README.md) | no | no | mojo_library | no | nobody |
| [`jsonl`](../src/jsonl/README.md) | no | no | mojo_library | yes | build gate |
| [`jwks`](../src/jwks/README.md) | no | no | mojo_library | yes | build gate |
| [`kafka_broker`](../src/kafka_broker/README.md) | no | no | mojo_library | yes | build gate |
| [`kafka_server`](../src/kafka_server/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`kernels`](../src/kernels/README.md) | no | no | mojo_library | yes | build gate |
| [`kg`](../src/kg/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_capture`](../src/kg_capture/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_code`](../src/kg_code/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_enrich`](../src/kg_enrich/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_format`](../src/kg_format/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_llm`](../src/kg_llm/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_mode`](../src/kg_mode/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`kg_sources`](../src/kg_sources/README.md) | no | no | mojo_library | yes | build gate |
| [`kg_spec`](../src/kg_spec/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`libc`](../src/libc/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`log`](../src/log/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`log_index`](../src/log_index/README.md) | no | no | mojo_library | no | nobody |
| [`log_query`](../src/log_query/README.md) | no | no | mojo_library | yes | build gate |
| [`lowering`](../src/lowering/README.md) | no | no | mojo_library | no | nobody |
| [`lowering_rules`](../src/lowering_rules/README.md) | no | no | mojo_library | yes | build gate |
| [`lz4`](../src/lz4/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`mail_address`](../src/mail_address/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`mail_auth`](../src/mail_auth/README.md) | no | no | mojo_library | yes | build gate |
| [`mail_message`](../src/mail_message/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`mail_store`](../src/mail_store/README.md) | no | no | mojo_library | yes | build gate |
| [`mail_tls`](../src/mail_tls/README.md) | no | no | mojo_library | no | nobody |
| [`managed_mail_proto`](../src/managed_mail_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`mcp_server`](../src/mcp_server/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`metrics`](../src/metrics/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`metrics_reader`](../src/metrics_reader/README.md) | no | no | mojo_library | yes | build gate |
| [`morsel`](../src/morsel/README.md) | no | no | mojo_library | yes | build gate |
| [`name_registry`](../src/name_registry/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`net`](../src/net/README.md) | no | no | mojo_library | yes | build gate |
| [`oauth`](../src/oauth/README.md) | no | no | mojo_library | yes | build gate |
| [`objectstore`](../src/objectstore/README.md) | no | no | mojo_library | yes | build gate |
| [`objectstore_gcs`](../src/objectstore_gcs/README.md) | no | no | mojo_library | yes | build gate |
| [`objectstore_s3`](../src/objectstore_s3/README.md) | no | no | mojo_library | yes | build gate |
| [`oci`](../src/oci/README.md) | no | no | mojo_library | yes | build gate |
| [`op_agg_distinct`](../src/op_agg_distinct/README.md) | no | no | mojo_library | no | nobody |
| [`op_agg_hash`](../src/op_agg_hash/README.md) | no | no | mojo_library | no | nobody |
| [`op_agg_row_api`](../src/op_agg_row_api/README.md) | no | no | mojo_library | yes | build gate |
| [`op_agg_slab`](../src/op_agg_slab/README.md) | no | no | mojo_library | no | nobody |
| [`op_agg_stage`](../src/op_agg_stage/README.md) | no | no | mojo_library | yes | build gate |
| [`op_agg_state`](../src/op_agg_state/README.md) | no | no | mojo_library | yes | build gate |
| [`op_asof`](../src/op_asof/README.md) | no | no | mojo_library | yes | build gate |
| [`op_fused_kernels`](../src/op_fused_kernels/README.md) | no | no | mojo_library | yes | build gate |
| [`op_join_build`](../src/op_join_build/README.md) | no | no | mojo_library | yes | build gate |
| [`op_join_probe`](../src/op_join_probe/README.md) | no | no | mojo_library | yes | build gate |
| [`op_join_sinks`](../src/op_join_sinks/README.md) | no | no | mojo_library | yes | build gate |
| [`op_join_stage`](../src/op_join_stage/README.md) | no | no | mojo_library | yes | build gate |
| [`op_sort`](../src/op_sort/README.md) | no | no | mojo_library | yes | build gate |
| [`op_sources`](../src/op_sources/README.md) | no | no | mojo_library | yes | build gate |
| [`op_spill_rows`](../src/op_spill_rows/README.md) | no | no | mojo_library | yes | build gate |
| [`op_typed_source_api`](../src/op_typed_source_api/README.md) | no | no | mojo_library | yes | build gate |
| [`op_window`](../src/op_window/README.md) | no | no | mojo_library | yes | build gate |
| [`operator_api`](../src/operator_api/README.md) | no | no | mojo_library | yes | build gate |
| [`optimized_plan`](../src/optimized_plan/README.md) | no | no | mojo_library | yes | build gate |
| [`optimized_plan_header`](../src/optimized_plan_header/README.md) | no | no | mojo_library | yes | build gate |
| [`optimizer`](../src/optimizer/README.md) | no | no | mojo_library | yes | build gate |
| [`orc`](../src/orc/README.md) | no | no | mojo_library | yes | build gate |
| [`parquet`](../src/parquet/README.md) | no | no | mojo_library | yes | build gate |
| [`parquet_api`](../src/parquet_api/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`parquet_codec`](../src/parquet_codec/README.md) | no | no | mojo_library | yes | build gate |
| [`parquet_footers`](../src/parquet_footers/README.md) | no | no | mojo_library | yes | build gate |
| [`parquet_scan`](../src/parquet_scan/README.md) | no | no | mojo_library | yes | build gate |
| [`parquet_writer`](../src/parquet_writer/README.md) | no | no | mojo_library | yes | build gate |
| [`phase_timers`](../src/phase_timers/README.md) | no | no | mojo_library | yes | build gate |
| [`physical_plan`](../src/physical_plan/README.md) | no | no | mojo_library | yes | build gate |
| [`pipeline_exec`](../src/pipeline_exec/README.md) | no | no | mojo_library | yes | build gate |
| [`plan_expr`](../src/plan_expr/README.md) | no | no | mojo_library | yes | build gate |
| [`plan_ir`](../src/plan_ir/README.md) | no | no | mojo_library | yes | build gate |
| [`plan_proto`](../src/plan_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`plan_stats`](../src/plan_stats/README.md) | no | no | mojo_library | yes | build gate |
| [`plan_wire`](../src/plan_wire/README.md) | no | no | mojo_library | yes | build gate |
| [`pplan_wire`](../src/pplan_wire/README.md) | no | no | mojo_library | yes | build gate |
| [`proto_codec`](../src/proto_codec/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`protobuf`](../src/protobuf/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`resource_gate`](../src/resource_gate/README.md) | no | no | mojo_library | yes | build gate |
| [`resources`](../src/resources/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`retry`](../src/retry/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`row_format`](../src/row_format/README.md) | no | no | mojo_library | yes | build gate |
| [`rowcell`](../src/rowcell/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`runtime_paths`](../src/runtime_paths/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`scalar_arithmetic`](../src/scalar_arithmetic/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`scan_planning`](../src/scan_planning/README.md) | no | no | mojo_library | yes | build gate |
| [`scan_resolver`](../src/scan_resolver/README.md) | no | no | mojo_library | yes | build gate |
| [`scan_source`](../src/scan_source/README.md) | no | no | mojo_library | yes | build gate |
| [`sdk`](../src/sdk/README.md) | no | no | mojo_library | yes | build gate |
| [`sdk_exec`](../src/sdk_exec/README.md) | no | no | mojo_library | yes | build gate |
| [`search`](../src/search/README.md) | no | no | mojo_library | yes | build gate |
| [`search_catalog`](../src/search_catalog/README.md) | no | no | mojo_library | yes | build gate |
| [`search_compaction`](../src/search_compaction/README.md) | no | no | mojo_library | yes | build gate |
| [`search_http`](../src/search_http/README.md) | no | no | mojo_library | yes | build gate |
| [`search_scan`](../src/search_scan/README.md) | no | no | mojo_library | yes | build gate |
| [`secret_env`](../src/secret_env/README.md) | no | no | mojo_library | yes | build gate |
| [`secret_registry`](../src/secret_registry/README.md) | no | no | mojo_library | yes | build gate |
| [`secret_store`](../src/secret_store/README.md) | no | no | mojo_library | yes | build gate |
| [`secrets`](../src/secrets/README.md) | no | no | mojo_library | yes | build gate |
| [`secrets_azure`](../src/secrets_azure/README.md) | no | no | mojo_library | yes | build gate |
| [`secrets_conjur`](../src/secrets_conjur/README.md) | no | no | mojo_library | yes | build gate |
| [`secrets_keychain`](../src/secrets_keychain/README.md) | no | no | mojo_library | yes | build gate |
| [`shuffle`](../src/shuffle/README.md) | no | no | mojo_library | yes | build gate |
| [`shuffle_streaming`](../src/shuffle_streaming/README.md) | no | no | mojo_library | yes | build gate |
| [`simd_ops`](../src/simd_ops/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`smtp_client`](../src/smtp_client/README.md) | no | no | mojo_library | yes | build gate |
| [`smtp_server`](../src/smtp_server/README.md) | no | no | mojo_library | yes | build gate |
| [`snapshotter`](../src/snapshotter/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`so`](../src/so/README.md) | no | no | mojo_library | yes | build gate |
| [`source_url`](../src/source_url/README.md) | no | no | mojo_library | yes | build gate |
| [`spsc_ring`](../src/spsc_ring/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`sql`](../src/sql/README.md) | no | no | mojo_library | yes | build gate |
| [`supervisor`](../src/supervisor/README.md) | no | no | mojo_library | yes | build gate |
| [`supervisor_proto`](../src/supervisor_proto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`sync`](../src/sync/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`table_store`](../src/table_store/README.md) | no | no | mojo_library | yes | build gate |
| [`telemetry_read`](../src/telemetry_read/README.md) | no | no | mojo_library | yes | build gate |
| [`telemetry_store`](../src/telemetry_store/README.md) | no | no | mojo_library | yes | build gate |
| [`test_run_id`](../src/test_run_id/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`test_verdict`](../src/test_verdict/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`textproto`](../src/textproto/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`tpch_answers`](../src/tpch_answers/README.md) | no | no | mojo_library | yes | build gate |
| [`trace`](../src/trace/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`udf`](../src/udf/README.md) | no | no | mojo_library | yes | build gate |
| [`udf_abi`](../src/udf_abi/README.md) | no | no | none | no | nobody |
| [`udf_python`](../src/udf_python/README.md) | no | no | none | no | nobody |
| [`uuid`](../src/uuid/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`validation_run`](../src/validation_run/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`vcard`](../src/vcard/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`viewport`](../src/viewport/README.md) | no | no | mojo_library | yes | build gate |
| [`webpush`](../src/webpush/README.md) | no | no | mojo_library | yes | build gate |
| [`wkt`](../src/wkt/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`xml`](../src/xml/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
| [`zlib`](../src/zlib/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |
