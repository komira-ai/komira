# Coverage census

Generated: `tools/build/coverage/census.sh render` writes this file from
[census.tsv](../tools/build/coverage/census.tsv), the numbers of one coverage
build of every library under `src/`, and from the floors of
[ratchet.tsv](../tools/build/coverage/ratchet.tsv), which it raises to them.
The build holds this file, census.tsv and ratchet.tsv to each other
(`//:coverage_census`), so edit none of them by hand except to lower a floor;
[The census](../tools/build/coverage/README.md#the-census) says how to refresh
them and what a floor does: a library measured under its package's floor
fails its coverage gate in every mode, so its conda package is not built.

Census of 2026-10-08 (main after #787, with #860 applied: main itself does not link komira_crypto's and komira_http_core's tests), built with
`-c komira.coverage=true`: line coverage from kcov over every test of the
library, branch coverage from the branch records of the libraries in
`COVERAGE_BRANCH_GATE` (tools/build/coverage/policy.bzl); the others show
*not gated*. The libraries under `src/tests/` are test code, outside the
target: they are listed for information at the end, with no floor.

## Summary

| | |
|---|---:|
| Libraries (under `src/`, not `src/tests/`) | 192 |
| Measured | 172 |
| Not measured (a run or the gate failed; floor 0) | 20 |
| Line coverage, all measured libraries | 74.92% (135205/180458) |
| Median line coverage (lower middle) | 89.05% |
| At 100% / 90% to 100% / 50% to 90% / under 50% / no line | 13 / 59 / 55 / 19 / 26 |
| Branch coverage of the libraries with branch records (37) | 74.79% (3946/5276) |
| Libraries with files no test compiles | 48 (223 files) |
| Published: in the release / a conda package only / neither | 40 / 152 / 0 |
| Measured under their floor | 0 |

## Ranked by line coverage

Lowest first. *Uncovered* counts executable lines no test ran, the lines of
files no test compiles included; *Floor* is the package's (ratchet.tsv), line /
branch, `-` for none; **under floor** marks a library measured under it.

| # | Library | Line | Uncovered | Branch | Files no test compiles | Published | Floor |
|---:|---|---:|---:|---|---:|---|---|
| 1 | `src/komira_atomic_alias:komira_atomic_alias` | 0.00% (0/6) | 6 | not gated | 1 | release | 0.00% / - |
| 2 | `src/komira_db_sqlite:komira_db_sqlite` | 0.00% (0/718) | 718 | not gated | 2 | conda | 0.00% / - |
| 3 | `src/komira_db:komira_db` | 3.02% (66/2183) | 2117 | not gated | 12 | conda | 3.02% / - |
| 4 | `src/komira_async_api:komira_async_api` | 6.38% (20/313) | 293 | 50.00% (1/2) | 7 | conda | 6.38% / 50.00% |
| 5 | `src/komira_kernels:komira_kernels` | 11.40% (474/4156) | 3682 | not gated | 12 | conda | 11.40% / - |
| 6 | `src/komira_scalar_arithmetic:komira_scalar_arithmetic` | 11.80% (62/525) | 463 | 79.16% (19/24) | 4 | release | 11.80% / 79.16% |
| 7 | `src/komira_expr:komira_expr` | 13.43% (151/1124) | 973 | not gated | 4 | conda | 13.43% / - |
| 8 | `src/komira_udf:komira_udf` | 15.32% (118/770) | 652 | 100.00% (36/36) | 18 | conda | 15.32% / 100.00% |
| 9 | `src/komira_plan_expr:komira_plan_expr` | 23.61% (903/3824) | 2921 | not gated | 17 | conda | 23.61% / - |
| 10 | `src/komira_agg_api:komira_agg_api` | 28.10% (154/548) | 394 | not gated | 3 | conda | 28.10% / - |
| 11 | `src/komira_scan_source:komira_scan_source` | 28.22% (644/2282) | 1638 | not gated | 12 | conda | 28.22% / - |
| 12 | `src/komira_agg:komira_agg` | 35.94% (339/943) | 604 | 85.08% (194/228) | 8 | conda | 35.94% / 85.08% |
| 13 | `src/komira_scan_planning:komira_scan_planning` | 38.91% (158/406) | 248 | not gated | 2 | conda | 38.91% / - |
| 14 | `src/komira_host:komira_host` | 41.24% (403/977) | 574 | not gated | 2 | release | 41.24% / - |
| 15 | `src/komira_plan_ir:komira_plan_ir` | 44.02% (1025/2328) | 1303 | 53.10% (598/1126) | 3 | conda | 44.02% / 53.10% |
| 16 | `src/komira_column_kernels:komira_column_kernels` | 46.84% (3501/7473) | 3972 | not gated | 8 | conda | 46.84% / - |
| 17 | `src/komira_exec_types:komira_exec_types` | 47.08% (105/223) | 118 | 62.06% (36/58) | 5 | conda | 47.08% / 62.06% |
| 18 | `src/komira_http_server:komira_http_server` | 48.84% (1168/2391) | 1223 | not gated | 1 | conda | 48.84% / - |
| 19 | `src/komira_buffer:komira_buffer` | 48.92% (408/834) | 426 | 86.36% (133/154) | 5 | conda | 48.92% / 86.36% |
| 20 | `src/komira_plan_stats:komira_plan_stats` | 52.92% (163/308) | 145 | 78.44% (91/116) | 4 | conda | 52.92% / 78.44% |
| 21 | `src/komira_op_agg_row_api:komira_op_agg_row_api` | 55.07% (38/69) | 31 | not gated | 2 | conda | 55.07% / - |
| 22 | `src/komira_eval:komira_eval` | 56.20% (1345/2393) | 1048 | not gated | 0 | conda | 56.20% / - |
| 23 | `src/komira_db_postgres:komira_db_postgres` | 59.29% (762/1285) | 523 | not gated | 2 | conda | 59.29% / - |
| 24 | `src/komira_row_format:komira_row_format` | 60.58% (1065/1758) | 693 | 66.71% (455/682) | 5 | conda | 60.58% / 66.71% |
| 25 | `src/komira_arrow:komira_arrow` | 62.98% (4572/7259) | 2687 | not gated | 18 | conda | 62.98% / - |
| 26 | `src/komira_morsel:komira_morsel` | 64.72% (1191/1840) | 649 | not gated | 9 | conda | 64.72% / - |
| 27 | `src/komira_join_assembly:komira_join_assembly` | 64.74% (540/834) | 294 | not gated | 0 | conda | 64.74% / - |
| 28 | `src/komira_http_core:komira_http_core` | 66.12% (2352/3557) | 1205 | not gated | 3 | conda | 66.12% / - |
| 29 | `src/komira_fs:komira_fs` | 67.77% (839/1238) | 399 | not gated | 8 | conda | 67.77% / - |
| 30 | `src/komira_plan_wire:komira_plan_wire` | 69.69% (3521/5052) | 1531 | not gated | 0 | conda | 69.69% / - |
| 31 | `src/komira_zlib:komira_zlib` | 75.00% (180/240) | 60 | 70.27% (52/74) | 0 | conda | 75.00% / 70.27% |
| 32 | `src/komira_compression:komira_compression` | 75.94% (341/449) | 108 | 75.00% (48/64) | 2 | conda | 75.94% / 75.00% |
| 33 | `src/komira_orc:komira_orc` | 76.36% (3580/4688) | 1108 | not gated | 0 | conda | 76.36% / - |
| 34 | `src/komira_libc:komira_libc` | 76.37% (181/237) | 56 | 78.72% (74/94) | 0 | conda | 76.37% / 78.72% |
| 35 | `src/komira_gcp_firestore_db:komira_gcp_firestore_db` | 76.50% (801/1047) | 246 | not gated | 0 | conda | 76.50% / - |
| 36 | `src/komira_jsonl:komira_jsonl` | 76.79% (2780/3620) | 840 | not gated | 2 | conda | 76.79% / - |
| 37 | `src/komira_arrow_ipc:komira_arrow_ipc` | 77.33% (5258/6799) | 1541 | not gated | 0 | conda | 77.33% / - |
| 38 | `src/komira_trace:komira_trace` | 77.60% (291/375) | 84 | 87.25% (89/102) | 2 | conda | 77.60% / 87.25% |
| 39 | `src/komira_column_format:komira_column_format` | 77.90% (201/258) | 57 | 51.17% (87/170) | 0 | conda | 77.90% / 51.17% |
| 40 | `src/komira_broker:komira_broker` | 78.07% (4448/5697) | 1249 | not gated | 4 | conda | 78.07% / - |
| 41 | `src/komira_op_agg_state:komira_op_agg_state` | 78.27% (2202/2813) | 611 | not gated | 5 | conda | 78.27% / - |
| 42 | `src/kci_params:kci_params` | 79.44% (259/326) | 67 | not gated | 0 | release | 79.44% / - |
| 43 | `src/komira_crypto:komira_crypto` | 80.18% (2351/2932) | 581 | not gated | 4 | conda | 80.18% / - |
| 44 | `src/komira_lz4:komira_lz4` | 80.26% (183/228) | 45 | 76.66% (46/60) | 0 | conda | 80.26% / 76.66% |
| 45 | `src/komira_async:komira_async` | 81.69% (4025/4927) | 902 | not gated | 11 | conda | 81.69% / - |
| 46 | `src/komira_job_supervisor:komira_job_supervisor` | 82.25% (765/930) | 165 | not gated | 0 | conda | 82.25% / - |
| 47 | `src/komira_oci:komira_oci` | 82.72% (1394/1685) | 291 | not gated | 0 | conda | 82.72% / - |
| 48 | `src/komira_search:komira_search` | 82.74% (3420/4133) | 713 | not gated | 0 | conda | 82.74% / - |
| 49 | `src/komira_simd:komira_simd` | 83.24% (631/758) | 127 | not gated | 3 | release | 83.24% / - |
| 50 | `src/komira_name_registry:komira_name_registry` | 83.33% (50/60) | 10 | 75.00% (24/32) | 0 | release | 83.33% / 75.00% |
| 51 | `src/komira_counters:komira_counters` | 83.38% (266/319) | 53 | 97.43% (76/78) | 1 | release | 83.38% / 97.43% |
| 52 | `src/komira_supervisor:komira_supervisor` | 83.38% (286/343) | 57 | not gated | 1 | conda | 83.38% / - |
| 53 | `src/komira_search_catalog:komira_search_catalog` | 83.62% (572/684) | 112 | not gated | 0 | conda | 83.62% / - |
| 54 | `src/komira_broker_coordinator:komira_broker_coordinator` | 83.77% (439/524) | 85 | not gated | 0 | conda | 83.77% / - |
| 55 | `src/kci_logs:kci_logs` | 83.95% (905/1078) | 173 | not gated | 0 | release | 83.95% / - |
| 56 | `src/komira_json_index:komira_json_index` | 84.77% (462/545) | 83 | not gated | 0 | conda | 84.77% / - |
| 57 | `src/kci_cloud:kci_cloud` | 84.88% (2493/2937) | 444 | not gated | 1 | conda | 84.88% / - |
| 58 | `src/komira_dynamic_filter:komira_dynamic_filter` | 84.93% (186/219) | 33 | 80.76% (42/52) | 1 | conda | 84.93% / 80.76% |
| 59 | `src/komira_net:komira_net` | 85.21% (98/115) | 17 | not gated | 0 | conda | 85.21% / - |
| 60 | `src/komira_table_store:komira_table_store` | 85.24% (884/1037) | 153 | not gated | 0 | conda | 85.24% / - |
| 61 | `src/komira_protobuf:komira_protobuf` | 85.71% (252/294) | 42 | 75.47% (80/106) | 0 | release | 85.71% / 75.47% |
| 62 | `src/komira_shuffle:komira_shuffle` | 85.76% (464/541) | 77 | not gated | 0 | conda | 85.76% / - |
| 63 | `src/komira_avro:komira_avro` | 85.88% (2896/3372) | 476 | not gated | 0 | conda | 85.88% / - |
| 64 | `src/komira_spsc_ring:komira_spsc_ring` | 86.23% (119/138) | 19 | 79.16% (38/48) | 0 | conda | 86.23% / 79.16% |
| 65 | `src/komira_fork_join:komira_fork_join` | 86.44% (51/59) | 8 | 91.66% (22/24) | 0 | release | 86.44% / 91.66% |
| 66 | `src/komira_search_scan:komira_search_scan` | 86.77% (479/552) | 73 | not gated | 0 | conda | 86.77% / - |
| 67 | `src/komira_iceberg_catalog:komira_iceberg_catalog` | 87.17% (204/234) | 30 | not gated | 0 | conda | 87.17% / - |
| 68 | `src/komira_pplan_wire:komira_pplan_wire` | 87.23% (485/556) | 71 | not gated | 0 | conda | 87.23% / - |
| 69 | `src/komira_viewport:komira_viewport` | 87.54% (457/522) | 65 | not gated | 0 | conda | 87.54% / - |
| 70 | `src/komira_connect:komira_connect` | 87.83% (751/855) | 104 | not gated | 0 | conda | 87.83% / - |
| 71 | `src/kci_reconciler:kci_reconciler` | 87.98% (1237/1406) | 169 | not gated | 0 | conda | 87.98% / - |
| 72 | `src/komira_snapshotter:komira_snapshotter` | 88.05% (59/67) | 8 | 78.57% (22/28) | 0 | conda | 88.05% / 78.57% |
| 73 | `src/kci_pkg_upload:kci_pkg_upload` | 89.05% (1953/2193) | 240 | not gated | 0 | conda | 89.05% / - |
| 74 | `src/kci_cli:kci_cli` | 89.94% (1190/1323) | 133 | not gated | 0 | conda | 89.94% / - |
| 75 | `src/komira_secret_registry:komira_secret_registry` | 90.62% (58/64) | 6 | 81.25% (13/16) | 1 | conda | 90.62% / 81.25% |
| 76 | `src/kci_validator_rows:kci_validator_rows` | 90.75% (108/119) | 11 | 100.00% (40/40) | 1 | release | 90.75% / 100.00% |
| 77 | `src/komira_objectstore_gcs:komira_objectstore_gcs` | 90.91% (901/991) | 90 | not gated | 1 | conda | 90.91% / - |
| 78 | `src/komira_log:komira_log` | 90.96% (1812/1992) | 180 | not gated | 1 | conda | 90.96% / - |
| 79 | `src/kci_validate:kci_validate` | 91.09% (1227/1347) | 120 | not gated | 0 | conda | 91.09% / - |
| 80 | `src/kci_publish:kci_publish_lib` | 91.69% (1954/2131) | 177 | not gated | 1 | conda | 91.69% / - |
| 81 | `src/kci_validator_report:kci_validator_report` | 91.72% (521/568) | 47 | not gated | 0 | release | 91.72% / - |
| 82 | `src/komira_grpc:komira_grpc` | 92.17% (1049/1138) | 89 | not gated | 0 | conda | 92.17% / - |
| 83 | `src/komira_clock:komira_clock` | 92.30% (12/13) | 1 | 50.00% (1/2) | 0 | release | 92.30% / 50.00% |
| 84 | `src/komira_collections:komira_collections` | 93.15% (313/336) | 23 | not gated | 1 | release | 93.15% / - |
| 85 | `src/komira_aws_core:komira_aws_core` | 93.24% (4939/5297) | 358 | not gated | 1 | conda | 93.24% / - |
| 86 | `src/kci_secret_writer:kci_secret_writer` | 93.33% (42/45) | 3 | 81.25% (13/16) | 0 | conda | 93.33% / 81.25% |
| 87 | `src/kci_build:kci_build_lib` | 93.53% (1057/1130) | 73 | not gated | 0 | conda | 93.53% / - |
| 88 | `src/komira_gcp_firestore:komira_gcp_firestore` | 93.79% (1829/1950) | 121 | not gated | 0 | conda | 0.00% / - |
| 89 | `src/komira_gcp_fcm:komira_gcp_fcm` | 93.85% (214/228) | 14 | not gated | 0 | conda | 93.85% / - |
| 90 | `src/komira_test_run_id:komira_test_run_id` | 93.87% (46/49) | 3 | 83.33% (10/12) | 0 | release | 93.87% / 83.33% |
| 91 | `src/komira_aws_lambda_http:komira_aws_lambda_http` | 94.00% (565/601) | 36 | not gated | 0 | conda | 94.00% / - |
| 92 | `src/komira_wkt:komira_wkt` | 94.07% (730/776) | 46 | 74.45% (408/548) | 0 | release | 0.00% / 74.45% |
| 93 | `src/komira_proto_codec:komira_proto_codec` | 94.46% (1041/1102) | 61 | not gated | 0 | release | 0.00% / - |
| 94 | `src/komira_vcard:komira_vcard` | 95.00% (609/641) | 32 | not gated | 0 | conda | 95.00% / - |
| 95 | `src/komira_parquet_codec:komira_parquet_codec` | 95.05% (557/586) | 29 | 93.28% (375/402) | 1 | conda | 95.05% / 93.28% |
| 96 | `src/komira_uuid:komira_uuid` | 95.27% (121/127) | 6 | 89.28% (75/84) | 0 | conda | 95.27% / 89.28% |
| 97 | `src/komira_anomaly:komira_anomaly` | 95.28% (828/869) | 41 | not gated | 0 | release | 95.28% / - |
| 98 | `src/komira_log_query:komira_log_query` | 95.31% (468/491) | 23 | not gated | 0 | conda | 95.31% / - |
| 99 | `src/komira_xml:komira_xml` | 95.75% (858/896) | 38 | not gated | 0 | release | 95.75% / - |
| 100 | `src/komira_scan_resolver:komira_scan_resolver` | 95.96% (499/520) | 21 | not gated | 0 | conda | 95.96% / - |
| 101 | `src/komira_gcp_core:komira_gcp_core` | 96.04% (1580/1645) | 65 | not gated | 0 | conda | 96.04% / - |
| 102 | `src/komira_gcp_wif:komira_gcp_wif` | 96.12% (248/258) | 10 | not gated | 0 | conda | 96.12% / - |
| 103 | `src/komira_mcp_server:komira_mcp_server` | 96.26% (438/455) | 17 | not gated | 0 | conda | 96.26% / - |
| 104 | `src/kci_workflow_check:kci_workflow_check` | 96.48% (1784/1849) | 65 | not gated | 0 | release | 96.48% / - |
| 105 | `src/komira_aws_metrics:komira_aws_metrics` | 96.51% (305/316) | 11 | not gated | 0 | conda | 96.51% / - |
| 106 | `src/komira_mail_address:komira_mail_address` | 96.55% (533/552) | 19 | not gated | 0 | conda | 96.55% / - |
| 107 | `src/komira_textproto:komira_textproto` | 96.55% (168/174) | 6 | not gated | 0 | release | 96.55% / - |
| 108 | `src/komira_json:komira_json` | 96.94% (635/655) | 20 | 92.75% (538/580) | 0 | release | 96.94% / 92.75% |
| 109 | `src/komira_metrics:komira_metrics` | 97.18% (896/922) | 26 | not gated | 0 | conda | 97.18% / - |
| 110 | `src/komira_secret_env:komira_secret_env` | 97.22% (105/108) | 3 | not gated | 0 | conda | 97.22% / - |
| 111 | `src/kci_artifact:kci_artifact` | 97.27% (893/918) | 25 | not gated | 0 | conda | 97.27% / - |
| 112 | `src/komira_metrics_reader:komira_metrics_reader` | 97.27% (572/588) | 16 | not gated | 0 | conda | 97.27% / - |
| 113 | `src/komira_kafka_server:komira_kafka_server` | 97.34% (1174/1206) | 32 | not gated | 0 | release | 97.34% / - |
| 114 | `src/komira_calendar:komira_calendar` | 97.41% (452/464) | 12 | not gated | 1 | conda | 97.41% / - |
| 115 | `src/komira_parquet_api:komira_parquet_api` | 97.51% (235/241) | 6 | 95.16% (118/124) | 0 | release | 97.51% / 95.16% |
| 116 | `src/kci_api:kci_api` | 97.70% (1361/1393) | 32 | not gated | 0 | release | 97.70% / - |
| 117 | `src/kci_publish_oci:kci_publish_oci` | 97.75% (87/89) | 2 | not gated | 0 | conda | 97.75% / - |
| 118 | `src/komira_source_url:komira_source_url` | 98.07% (102/104) | 2 | not gated | 0 | conda | 98.07% / - |
| 119 | `src/kci_artifact_manifest:kci_artifact_manifest` | 98.14% (159/162) | 3 | not gated | 0 | release | 98.14% / - |
| 120 | `src/kci_release_channel:kci_release_channel` | 98.26% (452/460) | 8 | not gated | 0 | release | 98.26% / - |
| 121 | `src/komira_gcp_monitoring:komira_gcp_monitoring` | 98.37% (364/370) | 6 | not gated | 0 | conda | 98.37% / - |
| 122 | `src/komira_git:komira_git` | 98.55% (885/898) | 13 | not gated | 0 | conda | 98.55% / - |
| 123 | `src/komira_content_line:komira_content_line` | 98.59% (350/355) | 5 | not gated | 0 | conda | 98.59% / - |
| 124 | `src/kci_release_machine:kci_release_machine` | 98.77% (643/651) | 8 | not gated | 0 | release | 98.77% / - |
| 125 | `src/komira_azure_core:komira_azure_core` | 98.78% (325/329) | 4 | not gated | 0 | conda | 98.78% / - |
| 126 | `src/kci_release_set:kci_release_set` | 98.92% (738/746) | 8 | not gated | 0 | conda | 98.92% / - |
| 127 | `src/komira_dispatch_agg_exec:komira_dispatch_agg_exec` | 99.02% (407/411) | 4 | not gated | 0 | conda | 99.02% / - |
| 128 | `src/komira_sdk:komira_sdk` | 99.04% (1347/1360) | 13 | not gated | 0 | conda | 99.04% / - |
| 129 | `src/komira_encoding:komira_encoding` | 99.37% (319/321) | 2 | not gated | 0 | release | 99.37% / - |
| 130 | `src/komira_optimizer:komira_optimizer` | 99.44% (6399/6435) | 36 | not gated | 0 | conda | 99.44% / - |
| 131 | `src/komira_retry:komira_retry` | 99.50% (201/202) | 1 | 98.64% (73/74) | 0 | release | 99.50% / 98.64% |
| 132 | `src/komira_sql:komira_sql` | 99.87% (3192/3196) | 4 | not gated | 0 | conda | 99.87% / - |
| 133 | `src/komira_parquet:komira_parquet` | 99.91% (4797/4801) | 4 | not gated | 0 | conda | 99.91% / - |
| 134 | `src/komira_authz_api:komira_authz_api` | 100.00% (32/32) | 0 | not gated | 0 | conda | 100.00% / - |
| 135 | `src/komira_datetime:komira_datetime` | 100.00% (313/313) | 0 | not gated | 0 | release | 100.00% / - |
| 136 | `src/komira_dispatch_agg_folds:komira_dispatch_agg_folds` | 100.00% (1616/1616) | 0 | not gated | 0 | conda | 100.00% / - |
| 137 | `src/komira_dispatch_join_kernels:komira_dispatch_join_kernels` | 100.00% (709/709) | 0 | not gated | 0 | conda | 100.00% / - |
| 138 | `src/komira_dispatch_scan:komira_dispatch_scan` | 100.00% (1002/1002) | 0 | not gated | 0 | conda | 100.00% / - |
| 139 | `src/komira_hash:komira_hash` | 100.00% (8/8) | 0 | 100.00% (4/4) | 0 | release | 100.00% / 100.00% |
| 140 | `src/komira_resources:komira_resources` | 100.00% (17/17) | 0 | 100.00% (2/2) | 0 | release | 100.00% / 100.00% |
| 141 | `src/komira_rowcell:komira_rowcell` | 100.00% (46/46) | 0 | not gated | 0 | conda | 100.00% / - |
| 142 | `src/komira_secret_store:komira_secret_store` | 100.00% (49/49) | 0 | 90.00% (9/10) | 0 | conda | 100.00% / 90.00% |
| 143 | `src/komira_shuffle_streaming:komira_shuffle_streaming` | 100.00% (159/159) | 0 | not gated | 0 | conda | 100.00% / - |
| 144 | `src/komira_sync:komira_sync` | 100.00% (16/16) | 0 | 100.00% (4/4) | 0 | conda | 100.00% / 100.00% |
| 145 | `src/komira_test_verdict:komira_test_verdict` | 100.00% (65/65) | 0 | not gated | 0 | release | 100.00% / - |
| 146 | `src/komira_validation_run:komira_validation_run` | 100.00% (53/53) | 0 | not gated | 0 | release | 100.00% / - |
| 147 | `src/kci_resource_proto:kci_resource_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 148 | `src/komira_aws_apigatewayv2:komira_aws_apigatewayv2` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 149 | `src/komira_aws_dynamodb:komira_aws_dynamodb` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 150 | `src/komira_aws_dynamodbstreams:komira_aws_dynamodbstreams` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 151 | `src/komira_aws_ec2:komira_aws_ec2` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 152 | `src/komira_aws_ecr:komira_aws_ecr` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 153 | `src/komira_aws_ecs:komira_aws_ecs` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 154 | `src/komira_aws_iam:komira_aws_iam` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 155 | `src/komira_aws_lambda:komira_aws_lambda` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 156 | `src/komira_aws_logs:komira_aws_logs` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 157 | `src/komira_aws_route53:komira_aws_route53` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 158 | `src/komira_aws_s3:komira_aws_s3` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 159 | `src/komira_aws_scheduler:komira_aws_scheduler` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 160 | `src/komira_aws_secretsmanager:komira_aws_secretsmanager` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 161 | `src/komira_aws_ses:komira_aws_ses` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 162 | `src/komira_aws_sesv2:komira_aws_sesv2` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 163 | `src/komira_aws_sns:komira_aws_sns` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 164 | `src/komira_aws_sqs:komira_aws_sqs` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 165 | `src/komira_broker_proto:komira_broker_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 166 | `src/komira_calendar_proto:komira_calendar_proto` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 167 | `src/komira_gcp_compute:komira_gcp_compute` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 168 | `src/komira_job_report_proto:komira_job_report_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 169 | `src/komira_plan_proto:komira_plan_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 170 | `src/komira_proto_codec:implicit_presence_proto` | n/a | 0 | not gated | 0 | conda | 0.00% / - |
| 171 | `src/komira_supervisor_proto:komira_supervisor_proto` | n/a | 0 | not gated | 0 | release | 0.00% / - |
| 172 | `src/komira_wkt:value_null_proto` | n/a | 0 | not gated | 0 | conda | 0.00% / 74.45% |

## Not measured

| Library | Status | Why | Published | Floor |
|---|---|---|---|---|
| `src/kci_cloud_fake:kci_cloud_fake` | RUN_FAILED | mojo_gated_test readme: 1 of 3 README examples failed | conda | 0.00% / - |
| `src/komira_azure_blob:komira_azure_blob` | RUN_FAILED | not built in this census: test_azure_store_fs takes longer than the 450 s run limit under kcov (sharding it is pending) | conda | 0.00% / - |
| `src/komira_csv:komira_csv` | RUN_FAILED | not built in this census: test_csv_parallel_reader and test_csv_phase_4_column_parallel_concat take about 450 s under kcov, the run limit (sharding them is pending) | conda | 0.00% / - |
| `src/komira_gcp_apigateway:komira_gcp_apigateway` | RUN_FAILED | mojo_cov_run test_apigateway_default_host: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_artifactregistry:komira_gcp_artifactregistry` | RUN_FAILED | mojo_cov_run test_artifactregistry_default_host: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_cloudresourcemanager:komira_gcp_cloudresourcemanager` | RUN_FAILED | mojo_cov_run test_crm_default_host: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_cloudscheduler:komira_gcp_cloudscheduler` | RUN_FAILED | mojo_cov_run test_cloudscheduler_endpoint: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_firestore:komira_gcp_firestore_listen` | RUN_FAILED | mojo_cov_run test_firestore_listen_client: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_firestore:komira_gcp_firestore_v1` | RUN_FAILED | mojo_cov_run test_firestore_v1_errors: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_iam:komira_gcp_iam` | RUN_FAILED | mojo_cov_run test_iam_default_host: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_logging:komira_gcp_logging` | RUN_FAILED | mojo_cov_run test_logging_default_host: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_monitoring_client:komira_gcp_monitoring_client` | RUN_FAILED | mojo_cov_run test_list_time_series_query: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_run:komira_gcp_run` | RUN_FAILED | mojo_cov_run test_no_env_reads: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_secretmanager:komira_gcp_secretmanager` | RUN_FAILED | mojo_cov_run test_no_env_reads: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_serviceusage:komira_gcp_serviceusage` | RUN_FAILED | mojo_cov_run test_no_env_reads: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_gcp_storage:komira_gcp_storage` | RUN_FAILED | mojo_cov_run test_no_env_reads: kcov: error: Too long string! | conda | 0.00% / - |
| `src/komira_http_client:komira_http_client` | RUN_FAILED | mojo_cov_run test_recv_ring_body: HttpError[TIMEOUT]: response body deadline exceeded after 298858 body bytes -- no deadline was stamped on this body, so the drain fell back to its unstamped backstop of 400000 us (collect_body). A ... | conda | 0.00% / - |
| `src/komira_jwks:komira_jwks` | RUN_FAILED | mojo_cov_branch_classify test_jwk_rfc_vectors | conda | 0.00% / - |
| `src/komira_objectstore:komira_objectstore` | RUN_FAILED | mojo_cov_run test_cas_manifest_concurrent_offline: At tests/test_cas_manifest_concurrent_offline.mojo:292:17: AssertionError: `left == right` comparison failed: | conda | 0.00% / - |
| `src/komira_objectstore_s3:komira_objectstore_s3` | RUN_FAILED | mojo_cov_run test_s3_fs_inflight: At tests/test_s3_fs_inflight.mojo:470:16: AssertionError: 6 parts under a bound of 3 took 9493 ms: they were not sent 3 at a time | conda | 0.00% / - |

## Files no test compiles

Sources of a library that no test binary of it includes: each counts all its
executable lines uncovered (covcheck's UnmeasuredFile).

- `src/komira_atomic_alias:komira_atomic_alias`: `src/komira_atomic_alias/atypes.mojo`
- `src/komira_db_sqlite:komira_db_sqlite`: `src/komira_db_sqlite/ffi.mojo`, `src/komira_db_sqlite/sqlite_driver.mojo`
- `src/komira_db:komira_db`: `src/komira_db/blocking.mojo`, `src/komira_db/database.mojo`, `src/komira_db/db_row.mojo`, `src/komira_db/db_schema.mojo`, `src/komira_db/db_storable.mojo`, `src/komira_db/db_uuid.mojo`, `src/komira_db/db_value.mojo`, `src/komira_db/migration.mojo`, `src/komira_db/neutral_ops.mojo`, `src/komira_db/proto_json.mojo`, `src/komira_db/sql_neutral_ops.mojo`, `src/komira_db/timestamptz.mojo`
- `src/komira_async_api:komira_async_api`: `src/komira_async_api/fork_join_shared.mojo`, `src/komira_async_api/parallel_dispatch.mojo`, `src/komira_async_api/scale_signal.mojo`, `src/komira_async_api/sched_sites.mojo`, `src/komira_async_api/shared_chunk_work.mojo`, `src/komira_async_api/token.mojo`, `src/komira_async_api/worker_pool_traits.mojo`
- `src/komira_kernels:komira_kernels`: `src/komira_kernels/binary_fn.mojo`, `src/komira_kernels/builtin_binary_fns.mojo`, `src/komira_kernels/builtin_hash_fns.mojo`, `src/komira_kernels/builtin_match_fns.mojo`, `src/komira_kernels/builtin_string_hash_fns.mojo`, `src/komira_kernels/eval_chunks.mojo`, `src/komira_kernels/expr_kernel_templates.mojo`, `src/komira_kernels/hash_fn.mojo`, `src/komira_kernels/join_key_envelope.mojo`, `src/komira_kernels/match_fn.mojo`, `src/komira_kernels/runtime_expr.mojo`, `src/komira_kernels/temporal_extract.mojo`
- `src/komira_scalar_arithmetic:komira_scalar_arithmetic`: `src/komira_scalar_arithmetic/decimal_arith.mojo`, `src/komira_scalar_arithmetic/decimal_cast.mojo`, `src/komira_scalar_arithmetic/decimal_compare.mojo`, `src/komira_scalar_arithmetic/int_overflow.mojo`
- `src/komira_expr:komira_expr`: `src/komira_expr/composite_key.mojo`, `src/komira_expr/expr_sortable_key.mojo`, `src/komira_expr/stage_program.mojo`, `src/komira_expr/typed_projects.mojo`
- `src/komira_udf:komira_udf`: `src/komira_udf/agg_fn.mojo`, `src/komira_udf/auto_komira_schema.mojo`, `src/komira_udf/expr_scalar_fn.mojo`, `src/komira_udf/filter_fn.mojo`, `src/komira_udf/float_quotient_order.mojo`, `src/komira_udf/frame_view.mojo`, `src/komira_udf/map_fn.mojo`, `src/komira_udf/partition_local_map_fn.mojo`, `src/komira_udf/partition_row_view.mojo`, `src/komira_udf/predicate.mojo`, `src/komira_udf/purity.mojo`, `src/komira_udf/row_transform.mojo`, `src/komira_udf/row_udf.mojo`, `src/komira_udf/scalar_udf.mojo`, `src/komira_udf/stateful_contract.mojo`, `src/komira_udf/udf_descriptor.mojo`, `src/komira_udf/window_fn.mojo`, `src/komira_udf/window_frame_spec.mojo`
- `src/komira_plan_expr:komira_plan_expr`: `src/komira_plan_expr/col_expr_bind.mojo`, `src/komira_plan_expr/col_expr_name.mojo`, `src/komira_plan_expr/declared_scalar_udf.mojo`, `src/komira_plan_expr/expr_id.mojo`, `src/komira_plan_expr/expr_pool.mojo`, `src/komira_plan_expr/expr_walk.mojo`, `src/komira_plan_expr/fs_bindings.mojo`, `src/komira_plan_expr/fs_descriptor_pod.mojo`, `src/komira_plan_expr/fs_resolver.mojo`, `src/komira_plan_expr/literal_domain.mojo`, `src/komira_plan_expr/null_order_policy.mojo`, `src/komira_plan_expr/partition_expr.mojo`, `src/komira_plan_expr/partition_pred_pod.mojo`, `src/komira_plan_expr/payload_narrow.mojo`, `src/komira_plan_expr/scalar_desugar.mojo`, `src/komira_plan_expr/typed_schema.mojo`, `src/komira_plan_expr/udf_data.mojo`
- `src/komira_agg_api:komira_agg_api`: `src/komira_agg_api/accumulator_trait.mojo`, `src/komira_agg_api/agg_column_ptrs.mojo`, `src/komira_agg_api/cd_distinct_key.mojo`
- `src/komira_scan_source:komira_scan_source`: `src/komira_scan_source/arrow_source.mojo`, `src/komira_scan_source/avro_source.mojo`, `src/komira_scan_source/compiler_registry.mojo`, `src/komira_scan_source/json_source.mojo`, `src/komira_scan_source/orc_source.mojo`, `src/komira_scan_source/scan_identity_audit.mojo`, `src/komira_scan_source/scan_kind_registry.mojo`, `src/komira_scan_source/scan_registry.mojo`, `src/komira_scan_source/scan_resolver.mojo`, `src/komira_scan_source/sink.mojo`, `src/komira_scan_source/source_capabilities.mojo`, `src/komira_scan_source/source_like.mojo`
- `src/komira_agg:komira_agg`: `src/komira_agg/agg_op_traits.mojo`, `src/komira_agg/builtin_agg_fns_bool.mojo`, `src/komira_agg/builtin_agg_fns_states.mojo`, `src/komira_agg/builtin_agg_fns_string.mojo`, `src/komira_agg/builtin_agg_fns_sum_product.mojo`, `src/komira_agg/builtin_agg_fns_vec.mojo`, `src/komira_agg/hash_agg_op_aggregator.mojo`, `src/komira_agg/pod_state_gate.mojo`
- `src/komira_scan_planning:komira_scan_planning`: `src/komira_scan_planning/reader_factory.mojo`, `src/komira_scan_planning/source_capability_config.mojo`
- `src/komira_host:komira_host`: `src/komira_host/proc_probe.mojo`, `src/komira_host/thp_policy.mojo`
- `src/komira_plan_ir:komira_plan_ir`: `src/komira_plan_ir/scan_binding_bind_pass.mojo`, `src/komira_plan_ir/scan_binding_gate.mojo`, `src/komira_plan_ir/schema_propagation.mojo`
- `src/komira_column_kernels:komira_column_kernels`: `src/komira_column_kernels/dict_filter.mojo`, `src/komira_column_kernels/digest_functions.mojo`, `src/komira_column_kernels/fused_predicate.mojo`, `src/komira_column_kernels/gather_recordbatch.mojo`, `src/komira_column_kernels/numeric_unary.mojo`, `src/komira_column_kernels/selective_decode.mojo`, `src/komira_column_kernels/unicode_case.mojo`, `src/komira_column_kernels/unicode_case_table.mojo`
- `src/komira_exec_types:komira_exec_types`: `src/komira_exec_types/byte_size.mojo`, `src/komira_exec_types/exec_result.mojo`, `src/komira_exec_types/partition_by_output_contract.mojo`, `src/komira_exec_types/process_result.mojo`, `src/komira_exec_types/query_context.mojo`
- `src/komira_http_server:komira_http_server`: `src/komira_http_server/middleware/passthrough.mojo`
- `src/komira_buffer:komira_buffer`: `src/komira_buffer/aligned_buffer_trait.mojo`, `src/komira_buffer/byte_buffer.mojo`, `src/komira_buffer/constants.mojo`, `src/komira_buffer/file_identity.mojo`, `src/komira_buffer/memory_region.mojo`
- `src/komira_plan_stats:komira_plan_stats`: `src/komira_plan_stats/physical_type.mojo`, `src/komira_plan_stats/precision_scalar.mojo`, `src/komira_plan_stats/source_statistics.mojo`, `src/komira_plan_stats/stats_provider.mojo`
- `src/komira_op_agg_row_api:komira_op_agg_row_api`: `src/komira_op_agg_row_api/agg_chunk_rows.mojo`, `src/komira_op_agg_row_api/combine_agg_plan.mojo`
- `src/komira_db_postgres:komira_db_postgres`: `src/komira_db_postgres/pg_driver.mojo`, `src/komira_db_postgres/pg_pool.mojo`
- `src/komira_row_format:komira_row_format`: `src/komira_row_format/cell_source.mojo`, `src/komira_row_format/row_directory.mojo`, `src/komira_row_format/row_evaluator.mojo`, `src/komira_row_format/row_output.mojo`, `src/komira_row_format/row_sink.mojo`
- `src/komira_arrow:komira_arrow`: `src/komira_arrow/band_view.mojo`, `src/komira_arrow/batch_format.mojo`, `src/komira_arrow/chunk_typed.mojo`, `src/komira_arrow/column_native.mojo`, `src/komira_arrow/column_native_nested.mojo`, `src/komira_arrow/copy_column_ref.mojo`, `src/komira_arrow/decimal256_array.mojo`, `src/komira_arrow/dtype_sentinel.mojo`, `src/komira_arrow/interval_mdn_array.mojo`, `src/komira_arrow/morsel_view.mojo`, `src/komira_arrow/parallel_work.mojo`, `src/komira_arrow/quote_styles.mojo`, `src/komira_arrow/schema_identity.mojo`, `src/komira_arrow/selection_column.mojo`, `src/komira_arrow/selection_vector.mojo`, `src/komira_arrow/selection_vector_row.mojo`, `src/komira_arrow/serde_format.mojo`, `src/komira_arrow/write_target.mojo`
- `src/komira_morsel:komira_morsel`: `src/komira_morsel/bypass_ref.mojo`, `src/komira_morsel/hash_agg_decoded.mojo`, `src/komira_morsel/morsel_operator.mojo`, `src/komira_morsel/morsel_sink.mojo`, `src/komira_morsel/morsel_source.mojo`, `src/komira_morsel/pipeline_execution.mojo`, `src/komira_morsel/source_hooks.mojo`, `src/komira_morsel/streaming_sink.mojo`, `src/komira_morsel/streaming_source.mojo`
- `src/komira_http_core:komira_http_core`: `src/komira_http_core/codec/h2/connection_state.mojo`, `src/komira_http_core/codec/h2/response_validation.mojo`, `src/komira_http_core/transport/stream_park.mojo`
- `src/komira_fs:komira_fs`: `src/komira_fs/byte_range.mojo`, `src/komira_fs/column_set.mojo`, `src/komira_fs/file_format.mojo`, `src/komira_fs/file_format_capabilities.mojo`, `src/komira_fs/footer_region.mojo`, `src/komira_fs/footer_window_hints.mojo`, `src/komira_fs/handle.mojo`, `src/komira_fs/metadata_cache.mojo`
- `src/komira_compression:komira_compression`: `src/komira_compression/compression.mojo`, `src/komira_compression/zlib.mojo`
- `src/komira_jsonl:komira_jsonl`: `src/komira_jsonl/decode.mojo`, `src/komira_jsonl/json_compatible.mojo`
- `src/komira_trace:komira_trace`: `src/komira_trace/span_ring.mojo`, `src/komira_trace/tracer_handle.mojo`
- `src/komira_broker:komira_broker`: `src/komira_broker/broker_node_state.mojo`, `src/komira_broker/producer_dedupe.mojo`, `src/komira_broker/producer_registry.mojo`, `src/komira_broker/sublineage_rollout_metrics.mojo`
- `src/komira_op_agg_state:komira_op_agg_state`: `src/komira_op_agg_state/accumulator_trait.mojo`, `src/komira_op_agg_state/agg_fn_fused_kernel.mojo`, `src/komira_op_agg_state/aggregator_with_struct_trait.mojo`, `src/komira_op_agg_state/int_sum_overflow.mojo`, `src/komira_op_agg_state/row_map_projects.mojo`
- `src/komira_crypto:komira_crypto`: `src/komira_crypto/aead.mojo`, `src/komira_crypto/internal/asm/sha256_compress.mojo`, `src/komira_crypto/pbkdf2.mojo`, `src/komira_crypto/traits.mojo`
- `src/komira_async:komira_async`: `src/komira_async/channel/message.mojo`, `src/komira_async/errors/io_error.mojo`, `src/komira_async/primitives/never_origin.mojo`, `src/komira_async/reactor/graceful_shutdown.mojo`, `src/komira_async/runtime/aws_lambda_runtime.mojo`, `src/komira_async/runtime/chunk_work.mojo`, `src/komira_async/runtime/idle_hook.mojo`, `src/komira_async/runtime/multiphase_work.mojo`, `src/komira_async/runtime/runtime_trait.mojo`, `src/komira_async/runtime/steal_work.mojo`, `src/komira_async/sources/prefetch_source.mojo`
- `src/komira_simd:komira_simd`: `src/komira_simd/byte_class/broadcast_iota.mojo`, `src/komira_simd/byte_class/prefix_xor.mojo`, `src/komira_simd/width_policy.mojo`
- `src/komira_counters:komira_counters`: `src/komira_counters/runtime_introspection.mojo`
- `src/komira_supervisor:komira_supervisor`: `src/komira_supervisor/exit_monitor.mojo`
- `src/kci_cloud:kci_cloud`: `src/kci_cloud/conformance.mojo`
- `src/komira_dynamic_filter:komira_dynamic_filter`: `src/komira_dynamic_filter/constant_filter.mojo`
- `src/komira_secret_registry:komira_secret_registry`: `src/komira_secret_registry/credential_consumer.mojo`
- `src/kci_validator_rows:kci_validator_rows`: `src/kci_validator_rows/live.mojo`
- `src/komira_objectstore_gcs:komira_objectstore_gcs`: `src/komira_objectstore_gcs/backend.mojo`
- `src/komira_log:komira_log`: `src/komira_log/engine/metric_sink.mojo`
- `src/kci_publish:kci_publish_lib`: `src/kci_publish/workers.mojo`
- `src/komira_collections:komira_collections`: `src/komira_collections/variadic_pack.mojo`
- `src/komira_aws_core:komira_aws_core`: `src/komira_aws_core/process_creds.mojo`
- `src/komira_parquet_codec:komira_parquet_codec`: `src/komira_parquet_codec/snappy/format.mojo`
- `src/komira_calendar:komira_calendar`: `src/komira_calendar/limits.mojo`

## Test packages (information)

Libraries under `src/tests/`: conformance suites, end-to-end tests and test
helpers. They are not held to the target and have no floor.

| Library | Line | Uncovered | Branch | Files no test compiles | Status |
|---|---:|---:|---|---:|---|
| `src/tests/conformance/komira_connect_conformance:komira_connect_conformance` | 95.45% (126/132) | 6 | not gated | 0 | OK |
| `src/tests/conformance/komira_db_conformance:komira_db_conformance` | 92.50% (1136/1228) | 92 | not gated | 1 | OK |
| `src/tests/conformance/komira_http_conformance:komira_http_conformance` | 90.69% (273/301) | 28 | not gated | 0 | OK |
| `src/tests/conformance/komira_json_conformance:komira_json_conformance` | 95.38% (475/498) | 23 | not gated | 0 | OK |
| `src/tests/conformance/komira_vcard_conformance:komira_vcard_conformance` | 100.00% (10/10) | 0 | not gated | 0 | OK |
| `src/tests/e2e/komira_azure_blob_e2e:komira_azure_blob_e2e` | 91.31% (389/426) | 37 | not gated | 0 | OK |
| `src/tests/e2e/komira_formats_e2e:komira_formats_e2e` | 89.34% (394/441) | 47 | not gated | 0 | OK |
| `src/tests/e2e/komira_http_tls_e2e:komira_http_tls_e2e` | 93.65% (59/63) | 4 | not gated | 0 | OK |
| `src/tests/e2e/komira_job_supervisor_loopback:komira_job_supervisor_loopback` | 81.13% (228/281) | 53 | not gated | 0 | OK |
| `src/tests/e2e/komira_pandas_door_e2e:komira_pandas_door_e2e` | 89.81% (238/265) | 27 | not gated | 0 | OK |
| `src/tests/e2e/komira_search_e2e:komira_search_e2e` | 84.01% (247/294) | 47 | not gated | 0 | OK |
| `src/tests/e2e/komira_secrets_e2e:komira_secrets_e2e` | 87.68% (1054/1202) | 148 | not gated | 0 | OK |
| `src/tests/e2e/komira_shuffle_e2e:komira_shuffle_e2e` | 12.34% (49/397) | 348 | not gated | 2 | OK |
| `src/tests/e2e/komira_tls_interop_e2e:komira_tls_interop_e2e` | 9.92% (39/393) | 354 | not gated | 3 | OK |
| `src/tests/e2e/komira_udf_e2e:komira_udf_e2e` | 92.10% (35/38) | 3 | 93.75% (15/16) | 0 | OK |
| `src/tests/helpers/komira_plan_harness:komira_plan_harness` | - | - | - | - | RUN_FAILED: mojo_precompile : buck-out/v2/art/komira/src/tests/helpers/komira_plan_harness/__komira_plan_harness__/47365a912b650570/src/komira_plan_harness/type_text.mojo:145:22: error: 'ArrowType' value has no attribute 'ERROR' |
| `src/tests/helpers/komira_test_bucket:komira_test_bucket` | 96.59% (595/616) | 21 | not gated | 0 | OK |
| `src/tests/helpers/komira_test_fake_s3:komira_test_fake_s3` | 100.00% (28/28) | 0 | not gated | 0 | OK |
| `src/tests/helpers/komira_test_minio:komira_test_minio` | 90.20% (221/245) | 24 | 69.11% (47/68) | 0 | OK |
| `src/tests/helpers/komira_test_s3_adapter:komira_test_s3_adapter` | 83.67% (205/245) | 40 | not gated | 1 | OK |
