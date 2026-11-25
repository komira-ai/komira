# Port audit: the 236 package directories by category

Part of the [port audit](../port_audit.md). Each row is one package directory of the earlier tree, with its category and fate.


Scope: the 236 package directories komira_<name>/ in the earlier tree, each read from its directory (file names, header comments, BUILD deps), compared with the dirs under src/ of the current tree. Category and fate are assigned per package, not from the name.

## 1. Counts per category

| category | packages | PRESENT | RENAMED | ABSENT-OUT-OF-SCOPE | ABSENT-NEEDED |
|---|---|---|---|---|---|
| ENGINE | 36 | 19 | 16 | 1 | 0 |
| SDK-SURFACE | 23 | 10 | 1 | 10 | 2 |
| STORAGE-CONNECT | 23 | 14 | 4 | 5 | 0 |
| APP | 54 | 8 | 3 | 43 | 0 |
| PLATFORM | 90 | 20 | 5 | 65 | 0 |
| TEST-PROBE | 6 | 0 | 0 | 6 | 0 |
| OTHER | 4 | 0 | 0 | 4 | 0 |
| TOTAL | 236 | 71 | 29 | 134 | 2 |

### Comparison with the earlier claim (about 65 apps, 108 platform/control-plane/cloud, 63 engine/library)

- The claim was not right. Read per package, the split is APP 54, PLATFORM 90, and the library side 88 (ENGINE 36, SDK-SURFACE 23, STORAGE-CONNECT 23, TEST-PROBE 6), with OTHER 4. Folding by the claim's three buckets (APP; PLATFORM plus OTHER; everything else) gives 54 / 94 / 88 against 65 / 108 / 63. No bucket matches; the claimed engine/library bucket is too small by 25, the claimed platform bucket too large by 14 and the claimed app bucket too large by 11.
- 65 + 108 + 63 = 236, so the three numbers do sum to the package count. That is only because a name regex with a catch-all bucket always sums to the total; it is not evidence that each package landed in the right bucket. The claim had no bucket for four kinds of package that matter to the SDK: SDK-SURFACE (the facade, ABI and plan-wire front doors: sdk, sdk_exec, so, pyffi, plan_endpoint, plan_wire, pplan_wire, ivp, flight, connect, grpc, pgwire_server, mcp_server, the Excel packages), STORAGE-CONNECT (object stores, cloud storage clients, catalogs, table formats), TEST-PROBE (ABI probes and test carriers), and OTHER (generated-client inputs, local model hosting). Those were spread across the other three by the first word of their names.
- The original regex was not kept, so the mis-sorts below are the packages whose name points to one bucket and whose contents belong to another:
  - Cloud-named packages that are storage clients on the SDK path, not cloud platform code: aws_core, aws_s3, aws_dynamodb, azure_core, azure_blob, gcp_core, gcp_gcs, gcp_storage, gcp_firestore, gcp_firestore_db (STORAGE-CONNECT).
  - Cloud-named packages that are generated-client inputs: aws_generated, aws_generated_dynamodb (OTHER).
  - Engine-, sdk- or optimizer-named packages that are probes or carriers with no product code: ec_move_probe, optimizer_so, sdk_static_probe, sdk_e2e_gate, integration (TEST-PROBE).
  - Engine-looking names that are SDK front doors: plan_endpoint, plan_wire, pplan_wire, pplan, pplan_capture, pplan_chain, pplan_emit, ivp, pyffi, so (SDK-SURFACE).
  - App-looking names that are plumbing: chat_sync_auth, managed_app_auth, grant_verifier, handler_kit (PLATFORM); comms_index, group_ratchet, git (APP engines of an app, kept APP); docintel and the kg_* packages (APP, not engine); search_* (ENGINE, not app).
  - Database- or protocol-named packages that are wire front doors or platform: pgwire_server (SDK-SURFACE), kafka and kafka_server (PLATFORM), snapshotter and cdc_ingest (STORAGE-CONNECT).

### Fate summary

- PRESENT 71, RENAMED 29, ABSENT-OUT-OF-SCOPE 134, ABSENT-NEEDED 2 (plan_endpoint and pyffi).
- PRESENT is by directory name only. Three PRESENT dirs hold much less than their earlier namesake and are the main SDK work still to land: sdk (plan-building half only; its README says the carrier, sinks and facade come in later parts), sdk_exec (about 31 of 44 earlier source files have no current counterpart: the node framework, source and sink factories, breaker frames, broker consumer and producer specs, the SQL executor) and so (a nine-export skeleton ABI; its README says no call runs a query yet). The RENAMED engine packages engine_dispatch and engine_operators also have about half of their files without a same-named counterpart; those are split or renamed files, but the python UDF bridge, the UDF registry and the chunked join materializer have no current counterpart at all.

## 2. The 255 entries of the earlier tree's komira source directory

255 = 236 package dirs + 19 other entries (13 files, 6 dirs). The 19 are:

| # | entry | kind | what it is |
|---|---|---|---|
| 1 | BUILD.bazel | file | the package build file: one target per package plus lint and partition targets |
| 2 | bundle_quarantine.bzl | rule file | list of tests quarantined out of the bundle build |
| 3 | bundle_quarantine_e2e.bzl | rule file | end-to-end tests quarantined out of the bundle build |
| 4 | e2e_gate_partition.bzl | rule file | partition of end-to-end gate tests across targets |
| 5 | opshadow_so_tests | test dir | one-file test dir for the native library's operator shadowing |
| 6 | optimizer_convert_measure | measurement dir | 4-file optimizer conversion measurement |
| 7 | sdk_e2e_cycle_free.bzl | rule file | declares the SDK end-to-end tests off the SDK's own build path (cycle removal) |
| 8 | sdk_exec_retiered.bzl | rule file | re-tiered test lists for sdk_exec |
| 9 | sdk_so_measure | measurement dir | 11-file measurement dir for the native library |
| 10 | sdk_so_migrated.bzl | rule file | ledger of SDK native-library tests migrated between targets |
| 11 | sdk_so_tests | test dir | 3-file test dir for the native library |
| 12 | sdk_test_env.bzl | rule file | shared environment for SDK tests |
| 13 | sdk_test_partition.bzl | rule file | partition of the SDK's tests (the split that keeps end-to-end tests off the library build) |
| 14 | shim_exported_symbols.txt | symbol list | exported-symbol list for the C shim |
| 15 | test_L1_tls_config_lifetime_uaf.lint_debt.tsv | lint ledger | lint debt rows for one test |
| 16 | test_komira_auth_concurrency_soak.lint_debt.tsv | lint ledger | lint debt rows for one test |
| 17 | test_komira_sdk_e2e_gate_bundle_039.lint_debt.tsv | lint ledger | lint debt rows for one test bundle |
| 18 | uo740_so_tests | test dir | one-file native-library test dir |
| 19 | uo76_so_tests | test dir | one-file native-library test dir |

Why an earlier list showed 246 lines: 246 = 236 + 10, so that list carried 10 of the 19 non-package entries and dropped 9. The listing itself was not kept, so which 10 cannot be proven. Directory listing of the earlier tree shows 255 entries with nothing hidden, 242 of them directories (236 packages + 6 test or measurement dirs) and 13 plain files. Two filters give exactly 10 and 9: a filter that drops the 8 .bzl rule files and the .txt symbol list leaves BUILD.bazel, the 6 non-package dirs and the 3 lint ledgers (10); the opposite filter that drops dirs and lint ledgers leaves BUILD.bazel, the 8 .bzl files and the .txt file (10). Either way the cause is a file-type or extension filter on a mixed directory, not missing packages: all 236 package dirs were in the list.

## 3. Per-package table

| package | category | fate | current location or reason |
|---|---|---|---|
| agent | PLATFORM | RENAMED | src/job_supervisor; 5 of 9 source files found there |
| anomaly | PLATFORM | PRESENT | src/anomaly |
| api | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane HTTP handlers and token minting; not on the SDK path |
| api_testkit | TEST-PROBE | ABSENT-OUT-OF-SCOPE | fakes for control-plane tests |
| app_params | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| async | ENGINE | RENAMED | src/async_rt, src/async_api, src/fs; runtime in async_rt, API in async_api, file systems in fs |
| attempt_supervisor | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| auth | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| authz | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| authz_adapter | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| avro | ENGINE | PRESENT | src/avro |
| aws_bridge | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| aws_core | STORAGE-CONNECT | PRESENT | src/aws_core |
| aws_dynamodb | STORAGE-CONNECT | PRESENT | src/aws_dynamodb |
| aws_dynamodb_db | STORAGE-CONNECT | ABSENT-OUT-OF-SCOPE | DynamoDB Database conformer for the hosted service (dynamo_data_client, dynamo_json); the SDK path does not need it |
| aws_generated | OTHER | ABSENT-OUT-OF-SCOPE | generated-client inputs; the generated clients exist as aws_* dirs [generated-client overrides spec plus tests (code generation input)] |
| aws_generated_dynamodb | OTHER | ABSENT-OUT-OF-SCOPE | generated-client inputs; the generated clients exist as aws_* dirs [generated DynamoDB client inputs and tests (code generation input)] |
| aws_iac | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| aws_iac_live | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| aws_lambda_http | PLATFORM | PRESENT | src/aws_lambda_http |
| aws_reap | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| aws_relay | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| aws_s3 | STORAGE-CONNECT | PRESENT | src/aws_s3 |
| aws_validate | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| aws_wire | PLATFORM | ABSENT-OUT-OF-SCOPE | AWS wire helper of the hosted service; not on the SDK path |
| azure_blob | STORAGE-CONNECT | PRESENT | src/azure_blob |
| azure_core | STORAGE-CONNECT | PRESENT | src/azure_core |
| blob_cas | STORAGE-CONNECT | ABSENT-OUT-OF-SCOPE | content-addressed blob store for hosted apps; not on the SDK path |
| board | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| board_app | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| board_serve | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| boot_publish | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| broker | PLATFORM | PRESENT | src/broker |
| broker_compaction | PLATFORM | PRESENT | src/broker_compaction |
| broker_coord | PLATFORM | RENAMED | src/broker_coordinator |
| cal_delivery | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| caldav_catalog | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| caldav_db | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| caldav_db_erasure | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| calendar_store_hook | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| cdc_ingest | STORAGE-CONNECT | PRESENT | src/cdc_ingest |
| chat_app | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| chat_db | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| chat_db_serve | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| chat_delivery | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| chat_server | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| chat_sync_auth | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| cloud_identity | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| cloud_logs | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| cloud_metrics | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| codeworks | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| codeworks_provider | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| codeworks_service | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| collections | ENGINE | RENAMED | src/containers, src/libc; slab and containers in containers, owned fd in libc |
| comms_index | APP | PRESENT | src/comms_index |
| comms_serve | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| compiler | ENGINE | RENAMED | src/batch_eval, src/optimizer, src/column_kernels, src/dispatch_agg_exec; split by function; several files (bound_expression, plan_budget, expr_to_runtime) have no current counterpart |
| connect | SDK-SURFACE | PRESENT | src/connect |
| core | ENGINE | RENAMED | src/arrow, src/arrow_ipc, src/simd_ops, src/column_kernels, src/plan_ir, src/plan_expr, src/fs, src/containers; split across many focused dirs |
| core_ffi | ENGINE | RENAMED | src/libc; posix FFI |
| core_id | ENGINE | RENAMED | src/uuid, src/clock; ids, clock and entropy |
| crm | APP | PRESENT | src/crm |
| crm_bridge | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| crypto | ENGINE | PRESENT | src/crypto (rs256_jwks and an asm base64 file not present) |
| csv | ENGINE | PRESENT | src/csv |
| db | STORAGE-CONNECT | PRESENT | src/db |
| deploy_bundle | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| deploy_log_sink | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| deploy_targets | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| device_coordinator | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| device_coordinator_service | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| dns | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| docintel | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| domain | PLATFORM | ABSENT-OUT-OF-SCOPE | thin compatibility facade over identity and board; not on the SDK path |
| ec_move_probe | TEST-PROBE | ABSENT-OUT-OF-SCOPE | measurement or ABI probe with no product code |
| engine_dispatch | ENGINE | RENAMED | src/dispatch_scan, src/dispatch_join_kernels, src/dispatch_agg_folds, src/dispatch_agg_exec, src/dispatch_project, src/dispatch_sources; split by operator family; about half of the files have new names or are not yet present |
| engine_operators | ENGINE | RENAMED | src/op_agg_state, src/op_join_probe, src/op_join_build, src/op_sort, src/op_agg_hash, src/op_window, src/op_asof, src/op_sources; split by operator; about half of the files have new names or are not yet present; the python UDF bridge and the UDF registry file have no current counterpart |
| engine_runtime | ENGINE | PRESENT | src/engine_runtime |
| engine_v2 | ENGINE | RENAMED | src/bump_arena, src/chunk; arena and chunk types; grain.mojo has no counterpart |
| eval | ENGINE | PRESENT | src/eval (part of its files now in agg, kernels, udf) |
| examples | APP | ABSENT-OUT-OF-SCOPE | sample programs and snippets, not a library |
| examples_corpus | APP | ABSENT-OUT-OF-SCOPE | sample programs and snippets, not a library |
| factory | PLATFORM | ABSENT-OUT-OF-SCOPE | software-factory orchestration of the hosted service; not on the SDK path |
| factory_build | PLATFORM | ABSENT-OUT-OF-SCOPE | software-factory orchestration of the hosted service; not on the SDK path |
| flight | SDK-SURFACE | PRESENT | src/flight |
| flight_server | SDK-SURFACE | PRESENT | src/flight_server |
| fs_registry | ENGINE | RENAMED | src/fs; FsHandle is fs/handle.mojo |
| gcp_bridge | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| gcp_core | STORAGE-CONNECT | PRESENT | src/gcp_core |
| gcp_firestore | STORAGE-CONNECT | PRESENT | src/gcp_firestore |
| gcp_firestore_db | STORAGE-CONNECT | PRESENT | src/gcp_firestore_db |
| gcp_gcs | STORAGE-CONNECT | RENAMED | src/objectstore_gcs; GCS file system; the V4 signer has no counterpart |
| gcp_storage | STORAGE-CONNECT | PRESENT | src/gcp_storage |
| gcp_wif | PLATFORM | PRESENT | src/gcp_wif |
| git | APP | PRESENT | src/git |
| git_review | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| grant_verifier | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| group_ratchet | APP | PRESENT | src/group_ratchet |
| grpc | SDK-SURFACE | PRESENT | src/grpc |
| handler_kit | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| http | ENGINE | RENAMED | src/http_client, src/http_core, src/http_server; client, core and server split |
| icalendar | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| iceberg | STORAGE-CONNECT | PRESENT | src/iceberg |
| iceberg_rest | STORAGE-CONNECT | RENAMED | src/iceberg_catalog |
| identity | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| identity_token | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| inference_backend | OTHER | ABSENT-OUT-OF-SCOPE | local model hosting; not on the SDK path [local-inference engine seam (model process spawning)] |
| integration | TEST-PROBE | ABSENT-OUT-OF-SCOPE | integration test helper package (no sources beyond a marker) |
| ivp | SDK-SURFACE | RENAMED | src/viewport; the protocol codec renamed (ivp_ticket -> viewport_ticket, and so on) |
| job_manager | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| job_manager_aws | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| job_store | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| jobs | PLATFORM | ABSENT-OUT-OF-SCOPE | job manager or device coordination service; not on the SDK path |
| json | ENGINE | RENAMED | src/jsonl, src/json_index; JSONL reader and index |
| jwks | PLATFORM | PRESENT | src/jwks |
| k8s | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| kafka | PLATFORM | RENAMED | src/kafka_server, src/kafka_broker |
| kafka_server | PLATFORM | PRESENT | src/kafka_server |
| kg | APP | PRESENT | src/kg |
| kg_enrich | APP | PRESENT | src/kg_enrich |
| kg_mode | APP | PRESENT | src/kg_mode |
| kg_read | APP | RENAMED | src/kg_format; delta and embedding codecs |
| kg_spec | APP | PRESENT | src/kg_spec |
| lightcodec | ENGINE | ABSENT-OUT-OF-SCOPE | bit-packing spike, not used by the native library |
| localmodel | OTHER | ABSENT-OUT-OF-SCOPE | local model hosting; not on the SDK path [local model runtime control (fit resolver, backend state machine)] |
| log | ENGINE | PRESENT | src/log |
| log_index | PLATFORM | PRESENT | src/log_index |
| log_query | PLATFORM | PRESENT | src/log_query |
| log_sink_aws | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| mail | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_addr | APP | RENAMED | src/mail_address |
| mail_app | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_catalog | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_delivery | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_ingest | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_migrate | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_relay_api | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_relay_aws | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_relay_cp | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_relay_service | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_router | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| mail_transport | APP | RENAMED | src/smtp_client, src/smtp_server, src/imap_server, src/mail_tls, src/mail_auth, src/mail_store; protocol halves split by role |
| mailbox | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| managed_app_auth | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| mcp | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| mcp_platform | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| mcp_server | SDK-SURFACE | PRESENT | src/mcp_server |
| morsel | ENGINE | PRESENT | src/morsel |
| notify | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| objectstore | STORAGE-CONNECT | PRESENT | src/objectstore (shuffle files now in shuffle) |
| obs | ENGINE | RENAMED | src/metrics, src/trace; metrics and trace; ring buffers and name registry have no counterpart |
| oci | PLATFORM | PRESENT | src/oci |
| optimizer | ENGINE | PRESENT | src/optimizer (optimizer_abi_version, payload narrow and udf opacity files not present) |
| optimizer_so | TEST-PROBE | ABSENT-OUT-OF-SCOPE | measurement or ABI probe with no product code |
| orc | ENGINE | PRESENT | src/orc |
| output_ref | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| parquet | ENGINE | PRESENT | src/parquet (part of its files now in parquet_api, parquet_codec, parquet_scan, parquet_writer, parquet_footers) |
| peer_reachability | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| peer_registry | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| people | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| pg | STORAGE-CONNECT | RENAMED | src/db_postgres |
| pgsql | STORAGE-CONNECT | ABSENT-OUT-OF-SCOPE | serverless Postgres product face; not the SDK query path |
| pgstore | STORAGE-CONNECT | RENAMED | src/table_store; TableStore |
| pgstore_columnar | STORAGE-CONNECT | ABSENT-OUT-OF-SCOPE | serverless Postgres product face; not the SDK query path |
| pgstore_driver | STORAGE-CONNECT | ABSENT-OUT-OF-SCOPE | serverless Postgres product face; not the SDK query path |
| pgwire_server | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | serverless Postgres product face; not the SDK query path |
| pipeline | PLATFORM | ABSENT-OUT-OF-SCOPE | software-factory orchestration of the hosted service; not on the SDK path |
| pipeline_runtime | PLATFORM | ABSENT-OUT-OF-SCOPE | software-factory orchestration of the hosted service; not on the SDK path |
| plan_endpoint | SDK-SURFACE | ABSENT-NEEDED | the plan wire front door the native library uses to run plan bytes and return an Arrow IPC result (execute_plan_bytes, result_ipc, scan_frame_producer, sql_producer); counterpart built since: src/so/sources.mojo plan_result and src/sdk_exec/engine_plan.mojo run_plan (`komira_plan_stream`, ABI 1.8), an Arrow C stream instead of IPC |
| plan_wire | SDK-SURFACE | PRESENT | src/plan_wire |
| pod_boot | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| pplan | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | typed Mojo comptime surface; the Python SDK sends plan bytes instead |
| pplan_capture | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | typed Mojo comptime surface; the Python SDK sends plan bytes instead |
| pplan_chain | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | typed Mojo comptime surface; the Python SDK sends plan bytes instead |
| pplan_emit | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | typed Mojo comptime surface; the Python SDK sends plan bytes instead |
| pplan_wire | SDK-SURFACE | PRESENT | src/pplan_wire |
| protobuf | ENGINE | PRESENT | src/protobuf |
| push | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| pyffi | SDK-SURFACE | ABSENT-NEEDED | the Python-facing C ABI beyond the skeleton in so: execute a plan, stream results, register UDFs, write sinks (komira_c_api); so says no call runs a query yet; skeleton in src/so |
| region_registry | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| registry | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| relay | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| resource_registry | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| restxml | PLATFORM | ABSENT-OUT-OF-SCOPE | cloud deploy or infrastructure code for the hosted service; not on the SDK path |
| review | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| review_service | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| rowcell | ENGINE | PRESENT | src/rowcell |
| run_logs | PLATFORM | ABSENT-OUT-OF-SCOPE | software-factory orchestration of the hosted service; not on the SDK path |
| sdk | SDK-SURFACE | PRESENT | src/sdk (plan-building half only; the carrier, sinks and facade come in later parts) |
| sdk_e2e_gate | TEST-PROBE | ABSENT-OUT-OF-SCOPE | test carrier library with no product code |
| sdk_exec | SDK-SURFACE | PRESENT | src/sdk_exec (partial: about 31 of 44 earlier source files not yet present) |
| sdk_static_probe | TEST-PROBE | ABSENT-OUT-OF-SCOPE | measurement or ABI probe with no product code |
| search | ENGINE | PRESENT | src/search |
| search_compaction | ENGINE | PRESENT | src/search_compaction |
| search_http | ENGINE | PRESENT | src/search_http |
| search_runtime | ENGINE | RENAMED | src/search_scan |
| search_s3 | ENGINE | RENAMED | src/search_catalog |
| secret_registry | PLATFORM | PRESENT | src/secret_registry |
| secret_store | PLATFORM | PRESENT | src/secret_store |
| secret_writer | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| secrets | PLATFORM | PRESENT | src/secrets |
| secrets_audit | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| secrets_audited | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| secrets_authz | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| secrets_aws | PLATFORM | RENAMED | src/aws_secret_store |
| secrets_azure | PLATFORM | PRESENT | src/secrets_azure |
| secrets_conjur | PLATFORM | PRESENT | src/secrets_conjur |
| secrets_gcp | PLATFORM | RENAMED | src/gcp_secret_store |
| secrets_keychain | PLATFORM | PRESENT | src/secrets_keychain |
| secrets_tokencache | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| secrets_vault | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| serde | ENGINE | RENAMED | src/proto_codec, src/encoding; codecs |
| service_registry | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| service_registry_client | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| session_relay | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| session_relay_server | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| shuffle_streaming | ENGINE | PRESENT | src/shuffle_streaming |
| snapshotter | STORAGE-CONNECT | PRESENT | src/snapshotter |
| so | SDK-SURFACE | PRESENT | src/so (rewritten: skeleton ABI, 9 exports) |
| store_policy | PLATFORM | ABSENT-OUT-OF-SCOPE | control-plane service plumbing (registries, secrets layers, push, tool servers); not on the SDK path |
| supervisor | PLATFORM | PRESENT | src/supervisor |
| svc_client | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| telemetry_read | PLATFORM | PRESENT | src/telemetry_read |
| telemetry_store | PLATFORM | PRESENT | src/telemetry_store |
| threads | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| token | PLATFORM | ABSENT-OUT-OF-SCOPE | identity, session or authorization service of the control plane; not on the SDK path |
| validation_run | PLATFORM | PRESENT | src/validation_run |
| viewd_core | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | viewport server process; the SDK needs only the protocol codec |
| wkt | ENGINE | PRESENT | src/wkt |
| workspace_serve | APP | ABSENT-OUT-OF-SCOPE | product application code, not part of the SDK library |
| xl_endpoint | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | Excel surface bridge over the plan wire; Excel is built over the TypeScript SDK, not the Python SDK |
| xl_plan | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | Excel surface, built over the TypeScript SDK; not the Python SDK path |
| xl_scalar | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | Excel surface, built over the TypeScript SDK; not the Python SDK path |
| xlfn | SDK-SURFACE | ABSENT-OUT-OF-SCOPE | Excel surface, built over the TypeScript SDK; not the Python SDK path |
| xml | ENGINE | PRESENT | src/xml |
| zlib | ENGINE | PRESENT | src/zlib |

