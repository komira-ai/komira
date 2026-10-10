# Coverage census

Generated: `tools/build/coverage/census.sh render` writes this file from
[census.tsv](../tools/build/coverage/census.tsv), the numbers of one coverage
build of every library under `src/`, and from the floors of
[ratchet.tsv](../tools/build/coverage/ratchet.tsv), which it raises to them.
The build holds this file, census.tsv and ratchet.tsv to each other
(`//:coverage_census`), so edit none of them by hand except to lower a floor;
[The census](../tools/build/coverage/census.md) says how to refresh
them and what a floor does: a library measured under its package's floor
fails its coverage gate in every mode, so its conda package is not built.

Census of 2026-10-10, built with
`-c komira.coverage=true`: line coverage from kcov over every test of the
library, branch coverage from the branch records of the libraries in
`COVERAGE_BRANCH_GATE` (tools/build/coverage/policy.bzl); the others show
*not gated*. The libraries under `src/tests/` are test code, outside the
target: they are listed for information at the end, with no floor.

## Summary

| | |
|---|---:|
| Libraries (under `src/`, not `src/tests/`) | 208 |
| Measured | 205 |
| Not measured (a run or the gate failed; floor 0) | 3 |
| Line coverage, all measured libraries | 89.86% (179409/199652) |
| Median line coverage (lower middle) | 96.19% |
| At 100% / 90% to 100% / 50% to 90% / under 50% / no line | 44 / 63 / 49 / 3 / 46 |
| Branch coverage of the libraries with branch records (39) | 89.78% (6847/7626) |
| Libraries with files no test compiles | 28 (100 files) |
| Published: in the release / a conda package only / neither | 54 / 153 / 1 |
| Measured under their floor | 0 |

## Ranked by line coverage

Lowest first. *Uncovered* counts executable lines no test ran, the lines of
files no test compiles included; *Floor* is the package's (ratchet.tsv), line /
branch, `-` for none, *pinned* when set by hand ([Pinned floors](#pinned-floors));
**under floor** marks a library measured under it.

| # | Library | Line | Uncovered | Branch | Files no test compiles | Published | Floor |
|---:|---|---:|---:|---|---:|---|---|
| 1 | `src/komira_udf:komira_udf` | 17.50% (118/674) | 556 | 100.00% (36/36) | 11 | conda | 17.50% / 100.00% |
| 2 | `src/komira_agg_api:komira_agg_api` | 28.73% (154/536) | 382 | not gated | 2 | conda | 28.73% / - |
| 3 | `src/komira_exec_types:komira_exec_types` | 47.29% (105/222) | 117 | 62.06% (36/58) | 4 | conda | 47.29% / 62.06% |
| 4 | `src/komira_kernels:komira_kernels` | 52.70% (1366/2592) | 1226 | not gated | 6 | conda | 52.70% / - |
| 5 | `src/komira_plan_expr:komira_plan_expr` | 54.40% (1983/3645) | 1662 | not gated | 13 | conda | 54.40% / - |
| 6 | `src/komira_plan_stats:komira_plan_stats` | 57.59% (163/283) | 120 | 78.44% (91/116) | 3 | conda | 57.59% / 78.44% |
| 7 | `src/komira_host:komira_host` | 60.41% (464/768) | 304 | not gated | 1 | release | 60.41% / - |
| 8 | `src/komira_scan_source:komira_scan_source` | 63.18% (1462/2314) | 852 | not gated | 10 | conda | 63.18% / - |
| 9 | `src/komira_join_assembly:komira_join_assembly` | 64.74% (540/834) | 294 | not gated | 0 | conda | 64.74% / - |
| 10 | `src/komira_column_kernels:komira_column_kernels` | 66.95% (4728/7061) | 2333 | not gated | 7 | conda | 66.95% / - |
| 11 | `src/komira_arrow:komira_arrow` | 67.76% (4772/7042) | 2270 | not gated | 13 | conda | 67.76% / - |
| 12 | `src/komira_op_agg_row_api:komira_op_agg_row_api` | 74.54% (41/55) | 14 | not gated | 1 | conda | 74.54% / - |
| 13 | `src/komira_zlib:komira_zlib` | 75.00% (180/240) | 60 | 69.73% (53/76) | 0 | conda | 75.00% / 69.73% |
| 14 | `src/komira_scan_planning:komira_scan_planning` | 75.21% (173/230) | 57 | not gated | 0 | conda | 75.21% / - |
| 15 | `src/komira_gcp_firestore_db:komira_gcp_firestore_db` | 76.50% (801/1047) | 246 | not gated | 0 | conda | 76.50% / - |
| 16 | `src/komira_column_format:komira_column_format` | 77.58% (218/281) | 63 | 51.17% (87/170) | 0 | conda | 77.58% / 51.17% |
| 17 | `src/komira_trace:komira_trace` | 77.80% (291/374) | 83 | 87.25% (89/102) | 1 | conda | 77.80% / 87.25% |
| 18 | `src/komira_supervisor:komira_supervisor` | 78.78% (312/396) | 84 | not gated | 2 | conda | 78.78% / - |
| 19 | `src/komira_libc:komira_libc` | 79.92% (227/284) | 57 | 79.16% (76/96) | 0 | conda | 79.92% / 79.16% |
| 20 | `src/komira_lz4:komira_lz4` | 80.26% (183/228) | 45 | 76.31% (58/76) | 0 | conda | 80.26% / 76.31% |
| 21 | `src/komira_db:komira_db` | 82.41% (970/1177) | 207 | not gated | 2 | conda | 82.41% / - |
| 22 | `src/komira_orc:komira_orc` | 83.37% (3943/4729) | 786 | not gated | 0 | conda | 83.37% / - |
| 23 | `src/komira_simd:komira_simd` | 83.37% (632/758) | 126 | not gated | 3 | release | 83.37% / - |
| 24 | `src/komira_counters:komira_counters` | 83.38% (266/319) | 53 | 97.50% (78/80) | 1 | release | 83.38% / 97.50% |
| 25 | `src/komira_crypto:komira_crypto` | 83.56% (2374/2841) | 467 | not gated | 2 | conda | 83.56% / - |
| 26 | `src/komira_search_catalog:komira_search_catalog` | 83.59% (591/707) | 116 | not gated | 0 | conda | 83.59% / - |
| 27 | `src/komira_objectstore:komira_objectstore` | 83.64% (2819/3370) | 551 | not gated | 4 | conda | 83.64% / - |
| 28 | `src/kci_logs:kci_logs` | 83.95% (905/1078) | 173 | not gated | 0 | release | 83.95% / - |
| 29 | `src/komira_broker_coordinator:komira_broker_coordinator` | 83.96% (440/524) | 84 | not gated | 0 | conda | 83.96% / - |
| 30 | `src/komira_name_registry:komira_name_registry` | 84.12% (53/63) | 10 | 75.00% (24/32) | 0 | release | 84.12% / 75.00% |
| 31 | `src/komira_async_api:komira_async_api` | 84.31% (86/102) | 16 | 50.00% (1/2) | 1 | conda | 84.31% / 50.00% |
| 32 | `src/komira_json_index:komira_json_index` | 84.77% (462/545) | 83 | not gated | 0 | conda | 84.77% / - |
| 33 | `src/komira_http_server:komira_http_server` | 84.94% (2183/2570) | 387 | not gated | 1 | conda | 84.94% / - |
| 34 | `src/komira_net:komira_net` | 85.21% (98/115) | 17 | not gated | 0 | conda | 85.21% / - |
| 35 | `src/komira_table_store:komira_table_store` | 85.24% (884/1037) | 153 | not gated | 0 | conda | 85.24% / - |
| 36 | `src/kci_cloud:kci_cloud` | 85.38% (2758/3230) | 472 | not gated | 1 | conda | 85.38% / - |
| 37 | `src/komira_shuffle:komira_shuffle` | 85.76% (464/541) | 77 | not gated | 0 | conda | 85.76% / - |
| 38 | `src/komira_arrow_ipc:komira_arrow_ipc` | 86.09% (5878/6827) | 949 | not gated | 0 | conda | 86.09% / - |
| 39 | `src/komira_spsc_ring:komira_spsc_ring` | 86.23% (119/138) | 19 | 78.00% (39/50) | 0 | release | 86.23% / 78.00% |
| 40 | `src/komira_async:komira_async` | 86.24% (4195/4864) | 669 | not gated | 5 | conda | 86.18% / - pinned |
| 41 | `src/komira_compression:komira_compression` | 86.32% (341/395) | 54 | 70.00% (70/100) | 0 | conda | 86.32% / 70.00% |
| 42 | `src/komira_job_supervisor:komira_job_supervisor` | 86.87% (1105/1272) | 167 | not gated | 0 | conda | 86.87% / - |
| 43 | `src/komira_iceberg_catalog:komira_iceberg_catalog` | 87.17% (204/234) | 30 | not gated | 0 | conda | 87.17% / - |
| 44 | `src/komira_search_scan:komira_search_scan` | 87.28% (501/574) | 73 | not gated | 0 | conda | 87.28% / - |
| 45 | `src/komira_pplan_wire:komira_pplan_wire` | 87.41% (486/556) | 70 | not gated | 0 | conda | 87.41% / - |
| 46 | `src/komira_connect:komira_connect` | 87.95% (752/855) | 103 | not gated | 0 | conda | 87.95% / - |
| 47 | `src/kci_reconciler:kci_reconciler` | 87.98% (1238/1407) | 169 | not gated | 0 | conda | 87.98% / - |
| 48 | `src/komira_snapshotter:komira_snapshotter` | 88.23% (60/68) | 8 | 78.57% (22/28) | 0 | release | 88.23% / 78.57% |
| 49 | `src/komira_viewport:komira_viewport` | 88.31% (461/522) | 61 | not gated | 0 | conda | 88.31% / - |
| 50 | `src/kci_pkg_upload:kci_pkg_upload` | 89.05% (1953/2193) | 240 | not gated | 0 | conda | 89.05% / - |
| 51 | `src/komira_plan_ir:komira_plan_ir` | 89.50% (2149/2401) | 252 | 81.46% (1354/1662) | 0 | conda | 89.50% / 81.46% |
| 52 | `src/kci_cli:kci_cli` | 89.88% (1360/1513) | 153 | not gated | 0 | conda | 89.88% / - |
| 53 | `src/komira_log:komira_log` | 90.89% (1957/2153) | 196 | not gated | 1 | conda | 90.89% / - |
| 54 | `src/kci_validate:kci_validate` | 91.23% (1229/1347) | 118 | not gated | 0 | conda | 91.23% / - |
| 55 | `src/komira_http_core:komira_http_core` | 91.88% (3070/3341) | 271 | not gated | 0 | conda | 91.88% / - |
| 56 | `src/kci_publish:kci_publish_lib` | 92.15% (2102/2281) | 179 | not gated | 1 | conda | 92.15% / - |
| 57 | `src/komira_grpc:komira_grpc` | 92.17% (1049/1138) | 89 | not gated | 0 | conda | 92.17% / - |
| 58 | `src/komira_agg:komira_agg` | 92.36% (1185/1283) | 98 | 98.26% (566/576) | 1 | conda | 92.36% / 98.26% |
| 59 | `src/komira_gcp_wif:komira_gcp_wif` | 92.39% (510/552) | 42 | not gated | 0 | conda | 92.39% / - |
| 60 | `src/komira_aws_core:komira_aws_core` | 93.24% (4939/5297) | 358 | not gated | 1 | conda | 93.24% / - |
| 61 | `src/komira_gcp_firestore:komira_gcp_firestore` | 93.79% (1829/1950) | 121 | not gated | 0 | conda | 93.79% / - |
| 62 | `src/kci_secret_writer:kci_secret_writer` | 93.84% (61/65) | 4 | 81.25% (13/16) | 0 | conda | 93.84% / 81.25% |
| 63 | `src/kci_build:kci_build_lib` | 93.85% (1115/1188) | 73 | not gated | 0 | conda | 93.85% / - |
| 64 | `src/komira_gcp_fcm:komira_gcp_fcm` | 93.85% (214/228) | 14 | not gated | 0 | conda | 93.85% / - |
| 65 | `src/komira_aws_lambda_http:komira_aws_lambda_http` | 94.00% (565/601) | 36 | not gated | 0 | conda | 94.00% / - |
| 66 | `src/komira_db_sqlite:komira_db_sqlite` | 94.02% (315/335) | 20 | not gated | 0 | conda | 94.02% / - |
| 67 | `src/komira_objectstore_gcs:komira_objectstore_gcs` | 94.05% (901/958) | 57 | not gated | 1 | conda | 94.05% / - |
| 68 | `src/komira_dynamic_filter:komira_dynamic_filter` | 94.06% (206/219) | 13 | 80.76% (42/52) | 0 | conda | 94.06% / 80.76% |
| 69 | `src/komira_vcard:komira_vcard` | 95.00% (609/641) | 32 | not gated | 0 | release | 95.00% / - |
| 70 | `src/komira_proto_codec:komira_proto_codec` | 95.28% (1050/1102) | 52 | not gated | 0 | release | 95.28% / - |
| 71 | `src/komira_objectstore_s3:komira_objectstore_s3` | 95.30% (1138/1194) | 56 | not gated | 0 | conda | 95.30% / - |
| 72 | `src/komira_log_query:komira_log_query` | 95.31% (468/491) | 23 | not gated | 0 | conda | 95.31% / - |
| 73 | `src/komira_uuid:komira_uuid` | 95.34% (123/129) | 6 | 89.28% (75/84) | 0 | conda | 95.34% / 89.28% |
| 74 | `src/komira_buffer:komira_buffer` | 95.60% (478/500) | 22 | 86.36% (133/154) | 0 | conda | 95.60% / 86.36% |
| 75 | `src/komira_http_auth:komira_http_auth` | 95.71% (983/1027) | 44 | not gated | 0 | conda | 95.71% / - |
| 76 | `src/komira_xml:komira_xml` | 95.75% (858/896) | 38 | not gated | 0 | release | 95.75% / - |
| 77 | `src/komira_scan_resolver:komira_scan_resolver` | 95.96% (499/520) | 21 | not gated | 0 | conda | 95.96% / - |
| 78 | `src/komira_parquet_codec:komira_parquet_codec` | 96.03% (557/580) | 23 | 92.78% (386/416) | 0 | conda | 96.03% / 92.78% |
| 79 | `src/komira_gcp_core:komira_gcp_core` | 96.04% (1580/1645) | 65 | not gated | 0 | conda | 96.04% / - |
| 80 | `src/komira_morsel:komira_morsel` | 96.19% (1515/1575) | 60 | not gated | 0 | conda | 96.19% / - |
| 81 | `src/komira_mcp_server:komira_mcp_server` | 96.26% (438/455) | 17 | not gated | 0 | release | 96.26% / - |
| 82 | `src/komira_row_format:komira_row_format` | 96.27% (1602/1664) | 62 | 96.24% (820/852) | 0 | conda | 96.27% / 96.24% |
| 83 | `src/komira_aws_metrics:komira_aws_metrics` | 96.51% (305/316) | 11 | not gated | 0 | conda | 96.51% / - |
| 84 | `src/komira_mail_address:komira_mail_address` | 96.55% (533/552) | 19 | not gated | 0 | release | 96.55% / - |
| 85 | `src/kci_cloud_fake:kci_cloud_fake` | 97.10% (1979/2038) | 59 | 91.01% (699/768) | 0 | conda | 97.10% / 91.01% |
| 86 | `src/komira_metrics:komira_metrics` | 97.18% (896/922) | 26 | not gated | 0 | conda | 97.18% / - |
| 87 | `src/komira_secret_env:komira_secret_env` | 97.22% (105/108) | 3 | not gated | 0 | conda | 97.22% / - |
| 88 | `src/kci_artifact:kci_artifact` | 97.27% (893/918) | 25 | not gated | 0 | conda | 97.27% / - |
| 89 | `src/komira_metrics_reader:komira_metrics_reader` | 97.27% (572/588) | 16 | not gated | 0 | conda | 97.27% / - |
| 90 | `src/kci_publish_oci:kci_publish_oci` | 97.75% (87/89) | 2 | not gated | 0 | conda | 97.75% / - |
| 91 | `src/komira_collections:komira_collections` | 97.83% (316/323) | 7 | not gated | 0 | release | 97.83% / - |
| 92 | `src/komira_source_url:komira_source_url` | 98.07% (102/104) | 2 | not gated | 0 | conda | 98.07% / - |
| 93 | `src/komira_gcp_monitoring:komira_gcp_monitoring` | 98.37% (364/370) | 6 | not gated | 0 | conda | 98.37% / - |
| 94 | `src/komira_secret_registry:komira_secret_registry` | 98.46% (64/65) | 1 | 81.25% (13/16) | 0 | conda | 98.46% / 81.25% |
| 95 | `src/komira_content_line:komira_content_line` | 98.59% (350/355) | 5 | not gated | 0 | release | 98.59% / - |
| 96 | `src/komira_fs:komira_fs` | 98.77% (1213/1228) | 15 | not gated | 1 | conda | 98.77% / - |
| 97 | `src/komira_azure_core:komira_azure_core` | 98.78% (325/329) | 4 | not gated | 0 | conda | 98.78% / - |
| 98 | `src/komira_broker:komira_broker` | 98.90% (5759/5823) | 64 | not gated | 0 | conda | 98.90% / - |
| 99 | `src/kci_release_set:kci_release_set` | 98.92% (738/746) | 8 | not gated | 0 | conda | 98.92% / - |
| 100 | `src/komira_dispatch_agg_exec:komira_dispatch_agg_exec` | 99.02% (407/411) | 4 | not gated | 0 | conda | 99.02% / - |
| 101 | `src/komira_sdk:komira_sdk` | 99.04% (1347/1360) | 13 | not gated | 0 | conda | 99.04% / - |
| 102 | `src/komira_eval:komira_eval` | 99.15% (2816/2840) | 24 | not gated | 0 | conda | 99.15% / - |
| 103 | `src/komira_jwks:komira_jwks` | 99.17% (362/365) | 3 | 91.84% (169/184) | 0 | conda | 99.17% / 91.84% |
| 104 | `src/komira_avro:komira_avro` | 99.29% (3379/3403) | 24 | not gated | 0 | conda | 99.29% / - |
| 105 | `src/komira_db_postgres:komira_db_postgres` | 99.29% (1128/1136) | 8 | not gated | 0 | conda | 99.29% / - |
| 106 | `src/komira_jsonl:komira_jsonl` | 99.59% (3706/3721) | 15 | not gated | 0 | conda | 99.59% / - |
| 107 | `src/komira_git:komira_git` | 99.60% (3252/3265) | 13 | not gated | 0 | conda | 99.60% / - |
| 108 | `src/komira_plan_wire:komira_plan_wire` | 99.71% (5184/5199) | 15 | not gated | 0 | conda | 99.71% / - |
| 109 | `src/komira_scalar_arithmetic:komira_scalar_arithmetic` | 99.72% (357/358) | 1 | 99.65% (285/286) | 0 | release | 99.72% / 99.65% |
| 110 | `src/kci_release_machine:kci_release_machine` | 99.79% (988/990) | 2 | not gated | 0 | release | 99.79% / - |
| 111 | `src/komira_parquet:komira_parquet` | 99.86% (5158/5165) | 7 | not gated | 0 | conda | 99.86% / - |
| 112 | `src/komira_sql:komira_sql` | 99.87% (3192/3196) | 4 | not gated | 0 | conda | 99.87% / - |
| 113 | `src/komira_wkt:komira_wkt` | 99.87% (809/810) | 1 | 99.10% (551/556) | 0 | release | 99.87% / 99.10% |
| 114 | `src/komira_op_agg_state:komira_op_agg_state` | 99.94% (3439/3441) | 2 | not gated | 0 | conda | 99.94% / - |
| 115 | `src/komira_optimizer:komira_optimizer` | 99.95% (9302/9306) | 4 | not gated | 0 | conda | 99.95% / - |
| 116 | `src/kci_api:kci_api` | 100.00% (1560/1560) | 0 | not gated | 0 | release | 100.00% / - |
| 117 | `src/kci_artifact_manifest:kci_artifact_manifest` | 100.00% (170/170) | 0 | not gated | 0 | release | 100.00% / - |
| 118 | `src/kci_cell:kci_cell` | 100.00% (246/246) | 0 | not gated | 0 | release | 100.00% / - |
| 119 | `src/kci_params:kci_params` | 100.00% (407/407) | 0 | not gated | 0 | release | 100.00% / - |
| 120 | `src/kci_release_channel:kci_release_channel` | 100.00% (460/460) | 0 | not gated | 0 | release | 100.00% / - |
| 121 | `src/kci_validator_report:kci_validator_report` | 100.00% (746/746) | 0 | not gated | 0 | release | 100.00% / - |
| 122 | `src/kci_validator_rows:kci_validator_rows` | 100.00% (117/117) | 0 | 100.00% (40/40) | 0 | release | 100.00% / 100.00% |
| 123 | `src/kci_workflow_check:kci_workflow_check` | 100.00% (1845/1845) | 0 | not gated | 0 | release | 100.00% / - |
| 124 | `src/komira_anomaly:komira_anomaly` | 100.00% (869/869) | 0 | not gated | 0 | release | 100.00% / - |
| 125 | `src/komira_authz_api:komira_authz_api` | 100.00% (27/27) | 0 | not gated | 0 | conda | 100.00% / - |
| 126 | `src/komira_calendar:komira_calendar` | 100.00% (630/630) | 0 | not gated | 0 | conda | 100.00% / - |
| 127 | `src/komira_calendar_ics:komira_calendar_ics` | 100.00% (1360/1360) | 0 | not gated | 0 | conda | 100.00% / - |
| 128 | `src/komira_calendar_store:komira_calendar_store` | 100.00% (665/665) | 0 | not gated | 0 | conda | 100.00% / - |
| 129 | `src/komira_chat_store:komira_chat_store` | 100.00% (1156/1156) | 0 | not gated | 0 | conda | 100.00% / - |
| 130 | `src/komira_clock:komira_clock` | 100.00% (13/13) | 0 | 100.00% (2/2) | 0 | release | 100.00% / 100.00% |
| 131 | `src/komira_contacts:komira_contacts` | 100.00% (419/419) | 0 | not gated | 0 | conda | 100.00% / - |
| 132 | `src/komira_datetime:komira_datetime` | 100.00% (853/853) | 0 | not gated | 0 | release | 100.00% / - |
| 133 | `src/komira_dispatch_agg_folds:komira_dispatch_agg_folds` | 100.00% (1616/1616) | 0 | not gated | 0 | conda | 100.00% / - |
| 134 | `src/komira_dispatch_join_kernels:komira_dispatch_join_kernels` | 100.00% (709/709) | 0 | not gated | 0 | conda | 100.00% / - |
| 135 | `src/komira_dispatch_scan:komira_dispatch_scan` | 100.00% (1002/1002) | 0 | not gated | 0 | conda | 100.00% / - |
| 136 | `src/komira_encoding:komira_encoding` | 100.00% (321/321) | 0 | not gated | 0 | release | 100.00% / - |
| 137 | `src/komira_expr:komira_expr` | 100.00% (605/605) | 0 | not gated | 0 | conda | 100.00% / - |
| 138 | `src/komira_fork_join:komira_fork_join` | 100.00% (59/59) | 0 | 100.00% (26/26) | 0 | release | 100.00% / 100.00% |
| 139 | `src/komira_hash:komira_hash` | 100.00% (8/8) | 0 | 100.00% (4/4) | 0 | release | 100.00% / 100.00% |
| 140 | `src/komira_json:komira_json` | 100.00% (656/656) | 0 | 100.00% (580/580) | 0 | release | 100.00% / 100.00% |
| 141 | `src/komira_kafka_server:komira_kafka_server` | 100.00% (1588/1588) | 0 | not gated | 0 | release | 100.00% / - |
| 142 | `src/komira_kg_code/tests/fixtures/repo:kgfix` | 100.00% (5/5) | 0 | not gated | 0 | no | 100.00% / - |
| 143 | `src/komira_kg_code:komira_kg_code` | 100.00% (684/684) | 0 | not gated | 0 | conda | 100.00% / - |
| 144 | `src/komira_mail_message:komira_mail_message` | 100.00% (1453/1453) | 0 | not gated | 0 | release | 100.00% / - |
| 145 | `src/komira_oci:komira_oci` | 100.00% (1678/1678) | 0 | not gated | 0 | conda | 100.00% / - |
| 146 | `src/komira_parquet_api:komira_parquet_api` | 100.00% (265/265) | 0 | 100.00% (124/124) | 0 | release | 100.00% / 100.00% |
| 147 | `src/komira_protobuf:komira_protobuf` | 100.00% (308/308) | 0 | 100.00% (106/106) | 0 | release | 100.00% / 100.00% |
| 148 | `src/komira_resources:komira_resources` | 100.00% (17/17) | 0 | 100.00% (2/2) | 0 | release | 100.00% / 100.00% |
| 149 | `src/komira_retry:komira_retry` | 100.00% (208/208) | 0 | 100.00% (76/76) | 0 | release | 100.00% / 100.00% |
| 150 | `src/komira_rowcell:komira_rowcell` | 100.00% (46/46) | 0 | not gated | 0 | release | 100.00% / - |
| 151 | `src/komira_search:komira_search` | 100.00% (4158/4158) | 0 | not gated | 0 | conda | 100.00% / - |
| 152 | `src/komira_secret_store:komira_secret_store` | 100.00% (49/49) | 0 | 90.00% (9/10) | 0 | conda | 100.00% / 90.00% |
| 153 | `src/komira_shuffle_streaming:komira_shuffle_streaming` | 100.00% (159/159) | 0 | not gated | 0 | conda | 100.00% / - |
| 154 | `src/komira_sync:komira_sync` | 100.00% (16/16) | 0 | 100.00% (4/4) | 0 | release | 100.00% / 100.00% |
| 155 | `src/komira_test_run_id:komira_test_run_id` | 100.00% (46/46) | 0 | 100.00% (8/8) | 0 | release | 100.00% / 100.00% |
| 156 | `src/komira_test_verdict:komira_test_verdict` | 100.00% (65/65) | 0 | not gated | 0 | release | 100.00% / - |
| 157 | `src/komira_textproto:komira_textproto` | 100.00% (174/174) | 0 | not gated | 0 | release | 100.00% / - |
| 158 | `src/komira_validation_run:komira_validation_run` | 100.00% (67/67) | 0 | not gated | 0 | release | 100.00% / - |
| 159 | `src/komira_webpush:komira_webpush` | 100.00% (321/321) | 0 | not gated | 0 | conda | 100.00% / - |
| 160 | `src/kci_artifact_proto:kci_artifact_proto` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 161 | `src/kci_deploy_model_proto:kci_deploy_model_proto` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 162 | `src/kci_manifest_proto:kci_manifest_proto` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 163 | `src/kci_resource_proto:kci_resource_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 164 | `src/komira_atomic_alias:komira_atomic_alias` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 165 | `src/komira_aws_apigatewayv2:komira_aws_apigatewayv2` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 166 | `src/komira_aws_dynamodb:komira_aws_dynamodb` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 167 | `src/komira_aws_dynamodbstreams:komira_aws_dynamodbstreams` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 168 | `src/komira_aws_ec2:komira_aws_ec2` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 169 | `src/komira_aws_ecr:komira_aws_ecr` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 170 | `src/komira_aws_ecs:komira_aws_ecs` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 171 | `src/komira_aws_iam:komira_aws_iam` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 172 | `src/komira_aws_lambda:komira_aws_lambda` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 173 | `src/komira_aws_logs:komira_aws_logs` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 174 | `src/komira_aws_route53:komira_aws_route53` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 175 | `src/komira_aws_s3:komira_aws_s3` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 176 | `src/komira_aws_scheduler:komira_aws_scheduler` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 177 | `src/komira_aws_secretsmanager:komira_aws_secretsmanager` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 178 | `src/komira_aws_ses:komira_aws_ses` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 179 | `src/komira_aws_sesv2:komira_aws_sesv2` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 180 | `src/komira_aws_sns:komira_aws_sns` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 181 | `src/komira_aws_sqs:komira_aws_sqs` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 182 | `src/komira_broker_proto:komira_broker_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 183 | `src/komira_calendar_proto:komira_calendar_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 184 | `src/komira_chat_proto:komira_chat_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 185 | `src/komira_contacts_proto:komira_contacts_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 186 | `src/komira_gcp_apigateway:komira_gcp_apigateway` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 187 | `src/komira_gcp_artifactregistry:komira_gcp_artifactregistry` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 188 | `src/komira_gcp_cloudresourcemanager:komira_gcp_cloudresourcemanager` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 189 | `src/komira_gcp_cloudscheduler:komira_gcp_cloudscheduler` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 190 | `src/komira_gcp_compute:komira_gcp_compute` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 191 | `src/komira_gcp_firestore:komira_gcp_firestore_listen` | n/a | 0 | not gated | 0 | conda | 93.79% / - |
| 192 | `src/komira_gcp_firestore:komira_gcp_firestore_v1` | n/a | 0 | not gated | 0 | conda | 93.79% / - |
| 193 | `src/komira_gcp_iam:komira_gcp_iam` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 194 | `src/komira_gcp_logging:komira_gcp_logging` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 195 | `src/komira_gcp_monitoring_client:komira_gcp_monitoring_client` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 196 | `src/komira_gcp_run:komira_gcp_run` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 197 | `src/komira_gcp_secretmanager:komira_gcp_secretmanager` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 198 | `src/komira_gcp_serviceusage:komira_gcp_serviceusage` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 199 | `src/komira_gcp_storage:komira_gcp_storage` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 200 | `src/komira_job_report_proto:komira_job_report_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 201 | `src/komira_managed_mail_proto:komira_managed_mail_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 202 | `src/komira_plan_proto:komira_plan_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 203 | `src/komira_proto_codec:implicit_presence_proto` | n/a | 0 | not gated | 0 | conda | 95.28% / - |
| 204 | `src/komira_supervisor_proto:komira_supervisor_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 205 | `src/komira_wkt:value_null_proto` | n/a | 0 | not gated | 0 | conda | 99.87% / 99.10% |

## Not measured

| Library | Status | Why | Published | Floor |
|---|---|---|---|---|
| `src/komira_azure_blob:komira_azure_blob` | RUN_FAILED | not built in this census: test_azure_store_fs takes longer than the 450 s run limit under kcov (sharding it is pending) | conda | 0.00% / - |
| `src/komira_csv:komira_csv` | RUN_FAILED | not built in this census: test_csv_parallel_reader and test_csv_phase_4_column_parallel_concat take about 450 s under kcov, the run limit (sharding them is pending) | conda | 0.00% / - |
| `src/komira_http_client:komira_http_client` | RUN_FAILED | not built in this census: test_body_drain_deadline fails intermittently under kcov, a 150 ms wall-clock budget (komira-ai/komira#1246) | conda | 81.40% / - |

## Pinned floors

A pinned row of ratchet.tsv holds a floor set by hand, with its reason;
render keeps it as written, whatever the census measured (*measured* is
the package floor the census would give it).

| Package | Floor | Measured | Why |
|---|---|---|---|
| `src/komira_async` | 86.18% / - | 86.24% / - | async_mutex.mojo:197-198 and semaphore.mojo:213-218 (the contended slow paths) run only when the unsynchronised two-thread smoke tests contend; 8618 is 86.18% without those 6 lines |

## Files no test compiles

Sources of a library that no test binary of it includes: each counts all its
executable lines uncovered (covcheck's UnmeasuredFile).

- `src/komira_udf:komira_udf`: `src/komira_udf/float_quotient_order.mojo`, `src/komira_udf/frame_view.mojo`, `src/komira_udf/partition_row_view.mojo`, `src/komira_udf/predicate.mojo`, `src/komira_udf/purity.mojo`, `src/komira_udf/row_transform.mojo`, `src/komira_udf/row_udf.mojo`, `src/komira_udf/stateful_contract.mojo`, `src/komira_udf/udf_descriptor.mojo`, `src/komira_udf/window_fn.mojo`, `src/komira_udf/window_frame_spec.mojo`
- `src/komira_agg_api:komira_agg_api`: `src/komira_agg_api/agg_column_ptrs.mojo`, `src/komira_agg_api/cd_distinct_key.mojo`
- `src/komira_exec_types:komira_exec_types`: `src/komira_exec_types/byte_size.mojo`, `src/komira_exec_types/exec_result.mojo`, `src/komira_exec_types/process_result.mojo`, `src/komira_exec_types/query_context.mojo`
- `src/komira_kernels:komira_kernels`: `src/komira_kernels/builtin_binary_fns.mojo`, `src/komira_kernels/builtin_hash_fns.mojo`, `src/komira_kernels/builtin_string_hash_fns.mojo`, `src/komira_kernels/eval_chunks.mojo`, `src/komira_kernels/join_key_envelope.mojo`, `src/komira_kernels/runtime_expr.mojo`
- `src/komira_plan_expr:komira_plan_expr`: `src/komira_plan_expr/col_expr_bind.mojo`, `src/komira_plan_expr/col_expr_name.mojo`, `src/komira_plan_expr/expr_id.mojo`, `src/komira_plan_expr/expr_pool.mojo`, `src/komira_plan_expr/fs_bindings.mojo`, `src/komira_plan_expr/fs_descriptor_pod.mojo`, `src/komira_plan_expr/fs_resolver.mojo`, `src/komira_plan_expr/null_order_policy.mojo`, `src/komira_plan_expr/partition_expr.mojo`, `src/komira_plan_expr/partition_pred_pod.mojo`, `src/komira_plan_expr/payload_narrow.mojo`, `src/komira_plan_expr/scalar_desugar.mojo`, `src/komira_plan_expr/udf_data.mojo`
- `src/komira_plan_stats:komira_plan_stats`: `src/komira_plan_stats/physical_type.mojo`, `src/komira_plan_stats/precision_scalar.mojo`, `src/komira_plan_stats/source_statistics.mojo`
- `src/komira_host:komira_host`: `src/komira_host/proc_probe.mojo`
- `src/komira_scan_source:komira_scan_source`: `src/komira_scan_source/arrow_source.mojo`, `src/komira_scan_source/avro_source.mojo`, `src/komira_scan_source/compiler_registry.mojo`, `src/komira_scan_source/json_source.mojo`, `src/komira_scan_source/orc_source.mojo`, `src/komira_scan_source/scan_registry.mojo`, `src/komira_scan_source/scan_resolver.mojo`, `src/komira_scan_source/sink.mojo`, `src/komira_scan_source/source_capabilities.mojo`, `src/komira_scan_source/source_like.mojo`
- `src/komira_column_kernels:komira_column_kernels`: `src/komira_column_kernels/dict_filter.mojo`, `src/komira_column_kernels/digest_functions.mojo`, `src/komira_column_kernels/fused_predicate.mojo`, `src/komira_column_kernels/gather_recordbatch.mojo`, `src/komira_column_kernels/numeric_unary.mojo`, `src/komira_column_kernels/selective_decode.mojo`, `src/komira_column_kernels/unicode_case.mojo`
- `src/komira_arrow:komira_arrow`: `src/komira_arrow/band_view.mojo`, `src/komira_arrow/chunk_typed.mojo`, `src/komira_arrow/copy_column_ref.mojo`, `src/komira_arrow/decimal256_array.mojo`, `src/komira_arrow/interval_mdn_array.mojo`, `src/komira_arrow/parallel_work.mojo`, `src/komira_arrow/quote_styles.mojo`, `src/komira_arrow/schema_identity.mojo`, `src/komira_arrow/selection_column.mojo`, `src/komira_arrow/selection_vector.mojo`, `src/komira_arrow/selection_vector_row.mojo`, `src/komira_arrow/serde_format.mojo`, `src/komira_arrow/write_target.mojo`
- `src/komira_op_agg_row_api:komira_op_agg_row_api`: `src/komira_op_agg_row_api/agg_chunk_rows.mojo`
- `src/komira_trace:komira_trace`: `src/komira_trace/tracer_handle.mojo`
- `src/komira_supervisor:komira_supervisor`: `src/komira_supervisor/exit_monitor.mojo`, `src/komira_supervisor/pid1.mojo`
- `src/komira_db:komira_db`: `src/komira_db/blocking.mojo`, `src/komira_db/db_storable.mojo`
- `src/komira_simd:komira_simd`: `src/komira_simd/byte_class/broadcast_iota.mojo`, `src/komira_simd/byte_class/prefix_xor.mojo`, `src/komira_simd/width_policy.mojo`
- `src/komira_counters:komira_counters`: `src/komira_counters/runtime_introspection.mojo`
- `src/komira_crypto:komira_crypto`: `src/komira_crypto/aead.mojo`, `src/komira_crypto/internal/asm/sha256_compress.mojo`
- `src/komira_objectstore:komira_objectstore`: `src/komira_objectstore/presign.mojo`, `src/komira_objectstore/request_core.mojo`, `src/komira_objectstore/shared_in_memory_latency_store.mojo`, `src/komira_objectstore/store_readiness.mojo`
- `src/komira_async_api:komira_async_api`: `src/komira_async_api/worker_pool_traits.mojo`
- `src/komira_http_server:komira_http_server`: `src/komira_http_server/middleware/passthrough.mojo`
- `src/kci_cloud:kci_cloud`: `src/kci_cloud/conformance.mojo`
- `src/komira_async:komira_async`: `src/komira_async/channel/message.mojo`, `src/komira_async/errors/io_error.mojo`, `src/komira_async/reactor/graceful_shutdown.mojo`, `src/komira_async/runtime/aws_lambda_runtime.mojo`, `src/komira_async/sources/prefetch_source.mojo`
- `src/komira_log:komira_log`: `src/komira_log/engine/metric_sink.mojo`
- `src/kci_publish:kci_publish_lib`: `src/kci_publish/workers.mojo`
- `src/komira_agg:komira_agg`: `src/komira_agg/builtin_agg_fns_states.mojo`
- `src/komira_aws_core:komira_aws_core`: `src/komira_aws_core/process_creds.mojo`
- `src/komira_objectstore_gcs:komira_objectstore_gcs`: `src/komira_objectstore_gcs/backend.mojo`
- `src/komira_fs:komira_fs`: `src/komira_fs/file_format_capabilities.mojo`

## Test packages (information)

Libraries under `src/tests/`: conformance suites, end-to-end tests and test
helpers. They are not held to the target and have no floor.

| Library | Line | Uncovered | Branch | Files no test compiles | Status |
|---|---:|---:|---|---:|---|
| `src/tests/conformance/komira_calendar_ics_conformance:komira_calendar_ics_conformance` | 100.00% (26/26) | 0 | not gated | 0 | OK |
| `src/tests/conformance/komira_calendar_store_conformance:komira_calendar_store_conformance` | 92.24% (214/232) | 18 | not gated | 0 | OK |
| `src/tests/conformance/komira_chat_store_conformance:komira_chat_store_conformance` | 94.11% (784/833) | 49 | not gated | 0 | OK |
| `src/tests/conformance/komira_connect_conformance:komira_connect_conformance` | 95.45% (126/132) | 6 | not gated | 0 | OK |
| `src/tests/conformance/komira_contacts_store_conformance:komira_contacts_store_conformance` | 94.11% (400/425) | 25 | not gated | 0 | OK |
| `src/tests/conformance/komira_datetime_conformance:komira_datetime_conformance` | 94.20% (65/69) | 4 | not gated | 0 | OK |
| `src/tests/conformance/komira_db_conformance:komira_db_conformance` | 94.27% (1136/1205) | 69 | not gated | 0 | OK |
| `src/tests/conformance/komira_git_conformance:komira_git_conformance` | 100.00% (39/39) | 0 | not gated | 0 | OK |
| `src/tests/conformance/komira_git_pack_conformance:komira_git_pack_conformance` | 100.00% (164/164) | 0 | not gated | 0 | OK |
| `src/tests/conformance/komira_git_protocol_conformance:komira_git_protocol_conformance` | 100.00% (199/199) | 0 | not gated | 0 | OK |
| `src/tests/conformance/komira_http_conformance:komira_http_conformance` | 90.69% (273/301) | 28 | not gated | 0 | OK |
| `src/tests/conformance/komira_json_conformance:komira_json_conformance` | 95.38% (475/498) | 23 | not gated | 0 | OK |
| `src/tests/conformance/komira_plan_conformance:komira_plan_conformance` | 91.47% (601/657) | 56 | not gated | 0 | OK |
| `src/tests/conformance/komira_vcard_conformance:komira_vcard_conformance` | 100.00% (10/10) | 0 | not gated | 0 | OK |
| `src/tests/conformance/komira_xml_conformance:komira_xml_conformance` | n/a | 0 | not gated | 0 | OK |
| `src/tests/e2e/komira_azure_blob_e2e:komira_azure_blob_e2e` | 91.31% (389/426) | 37 | not gated | 0 | OK |
| `src/tests/e2e/komira_formats_e2e:komira_formats_e2e` | 89.34% (394/441) | 47 | not gated | 0 | OK |
| `src/tests/e2e/komira_http_tls_e2e:komira_http_tls_e2e` | 93.65% (59/63) | 4 | not gated | 0 | OK |
| `src/tests/e2e/komira_job_supervisor_loopback:komira_job_supervisor_loopback` | 81.13% (228/281) | 53 | not gated | 0 | OK |
| `src/tests/e2e/komira_pandas_door_e2e:komira_pandas_door_e2e` | 93.49% (417/446) | 29 | not gated | 0 | OK |
| `src/tests/e2e/komira_search_e2e:komira_search_e2e` | 84.01% (247/294) | 47 | not gated | 0 | OK |
| `src/tests/e2e/komira_secrets_e2e:komira_secrets_e2e` | 87.68% (1054/1202) | 148 | not gated | 0 | OK |
| `src/tests/e2e/komira_shuffle_e2e:komira_shuffle_e2e` | 12.34% (49/397) | 348 | not gated | 2 | OK |
| `src/tests/e2e/komira_tls_interop_e2e:komira_tls_interop_e2e` | 13.80% (58/420) | 362 | not gated | 3 | OK |
| `src/tests/e2e/komira_udf_e2e:komira_udf_e2e` | 92.10% (35/38) | 3 | 93.75% (15/16) | 0 | OK |
| `src/tests/helpers/komira_plan_harness:komira_plan_harness` | 91.80% (2576/2806) | 230 | not gated | 0 | OK |
| `src/tests/helpers/komira_test_bucket:komira_test_bucket` | 96.59% (595/616) | 21 | not gated | 0 | OK |
| `src/tests/helpers/komira_test_fake_s3:komira_test_fake_s3` | 100.00% (28/28) | 0 | not gated | 0 | OK |
| `src/tests/helpers/komira_test_minio:komira_test_minio` | 90.20% (221/245) | 24 | 62.72% (69/110) | 0 | OK |
| `src/tests/helpers/komira_test_python:komira_test_python` | n/a | 0 | not gated | 0 | OK |
| `src/tests/helpers/komira_test_s3_adapter:komira_test_s3_adapter` | 83.67% (205/245) | 40 | not gated | 1 | OK |
| `src/tests/helpers/komira_test_vocabulary:komira_test_vocabulary` | 100.00% (59/59) | 0 | not gated | 0 | OK |
