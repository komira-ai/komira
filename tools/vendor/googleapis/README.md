# googleapis protos, referenced at a pinned commit

The `.proto` files komira generates Google Cloud clients from come from
[googleapis](https://github.com/googleapis/googleapis) (Apache-2.0) and are
**not committed here**. [BUCK](BUCK) fetches googleapis's GitHub archive at
one pinned commit (`_COMMIT`), checked against its sha256 (`_SHA256`), and
extracts at build time exactly the files a client needs. No generated code is
checked in either. The well-known types (`google/protobuf/*`) are not taken
from googleapis: protoc provides them.

googleapis's license is the archive's own `LICENSE`, extracted unmodified as
`//tools/vendor/googleapis:googleapis[LICENSE]`; googleapis ships no NOTICE
file at the pinned commit.

| target | what it is |
|---|---|
| `:googleapis.tar.gz` | the archive at the pin (`pinned_file`) |
| `:googleapis` | the files extracted from it, each a sub-target named by its path (`:googleapis[google/rpc/status.proto]`, `:googleapis[LICENSE]`) |
| `:logging_v2` | the Cloud Logging v2 protos (roots `google/logging/v2/{logging,log_entry}.proto`, for `ListLogEntries`), checked to be exactly their import closure |
| `:storage_v2` | the Cloud Storage v2 protos (root `google/storage/v2/storage.proto`, the gRPC storage API), checked the same way |
| `:firestore_v1` | the Cloud Firestore v1 protos (root `google/firestore/v1/firestore.proto`: the document methods and `Listen`), checked the same way |
| `:iam_admin_v1` | the IAM protos (roots `google/iam/admin/v1/iam.proto`: service accounts, roles, service-account IAM policies; and `google/iam/v1beta/workload_identity_pool.proto`: workload identity pool providers, which the pin has at v1beta only), checked the same way |
| `:resourcemanager_v3` | the Resource Manager v3 Projects protos (root `google/cloud/resourcemanager/v3/projects.proto`), checked the same way |
| `:serviceusage_v1` | the Service Usage v1 protos (root `google/api/serviceusage/v1/serviceusage.proto`), checked the same way |
| `:compute_v1` | the Compute Engine v1 protos (root `google/cloud/compute/v1/compute.proto`, the REST compute API), checked the same way |
| `:artifactregistry_v1` | the Artifact Registry v1 protos (root `google/devtools/artifactregistry/v1/service.proto`), checked the same way |
| `:apigateway_v1` | the API Gateway v1 protos (root `google/cloud/apigateway/v1/apigateway_service.proto`), checked the same way |
| `:run_v2` | the Cloud Run Admin v2 protos (roots `google/cloud/run/v2/{execution,job,revision,service,worker_pool}.proto`), checked the same way |
| `:cloudscheduler_v1` | the Cloud Scheduler v1 protos (root `google/cloud/scheduler/v1/cloudscheduler.proto`), checked the same way |
| `:secretmanager_v1` | the Secret Manager v1 protos (root `google/cloud/secretmanager/v1/service.proto`), checked the same way |
| `:monitoring_v3` | the Cloud Monitoring v3 protos (root `google/monitoring/v3/metric_service.proto`, for `ListTimeSeries`), checked the same way |
| `:api_client` | the `(google.api.http)` and `(google.api.default_host)` option protos (roots `google/api/{annotations,client}.proto`), checked the same way: the import root of the proto codegen goldens (`tests//functional/proto_codegen`) |
| `:googleapis[google/cloud/run/v2/run_v2.yaml]` | the Cloud Run Admin v2 service configuration, whose `http.rules` bind the long-running operations mixin to Run's paths (no `.proto` states them) |

## Using the protos

Depend on the closure target for your API (`:logging_v2`, `:storage_v2`,
`:firestore_v1`, `:iam_admin_v1`, `:resourcemanager_v3`, `:serviceusage_v1`,
`:compute_v1`, `:artifactregistry_v1`, `:apigateway_v1`, `:run_v2`,
`:cloudscheduler_v1`, `:secretmanager_v1`, `:monitoring_v3`). Its `ProtoSrcsInfo` is the checked
tree, so a `mojo_proto_library` names it in
`proto_deps`; `:<target>[tree]` is that tree as a directory (the files at
their import paths), and the default output is protoc's descriptor set for the
roots (`--include_imports`).

Each closure target is a `proto_check` ([proto_check.bzl](proto_check.bzl),
[proto_check.sh](proto_check.sh)): protoc must parse the roots from the
extracted files alone, into a descriptor set naming every one of them. A file
the closure needs and the list lacks fails the build, and so does a listed
file nothing imports. Its fixtures in `testdata/` hold the check to refusing
both; every `proto_check` target depends on them.

## Bumping the pin

The pin changes only by an edit here: an upstream change never reaches a
build on its own.

1. `tools/vendor/googleapis/upstream_version.sh` prints the pin, the head of
   googleapis's default branch, and which extracted files differ between the
   two. It is a report; nothing runs it in the build. If no file differs,
   there is nothing to bump for.
2. Set `_COMMIT` in BUCK to the new full commit sha, and `_SHA256` and
   `_SIZE` to the sha256 and the length in bytes of
   `https://github.com/googleapis/googleapis/archive/<commit>.tar.gz`.
3. Build `//tools/vendor/googleapis:` (every checked closure). If the new
   commit changed an import closure, its check names the file to add to (or
   drop from) that closure's list (`_LOGGING_V2_CLOSURE`,
   `_STORAGE_V2_CLOSURE`, `_FIRESTORE_V1_CLOSURE`, `_IAM_ADMIN_V1_CLOSURE`,
   `_RESOURCEMANAGER_V3_CLOSURE`, `_SERVICEUSAGE_V1_CLOSURE`, `_COMPUTE_V1_CLOSURE`,
   `_ARTIFACTREGISTRY_V1_CLOSURE`, `_APIGATEWAY_V1_CLOSURE`, `_RUN_V2_CLOSURE`,
   `_CLOUDSCHEDULER_V1_CLOSURE`, `_SECRETMANAGER_V1_CLOSURE`). Then build the
   generated clients (`//src/komira_gcp_*:`): komira_gcp_run generates its
   operations client from run_v2.yaml's `http.rules`, and its
   test_run_operations_rules fails until its golden follows a moved path.

## Adding a client

Add its roots and their closure as a list in BUCK, append the closure to
`_ALL_CLOSURES` (`:googleapis` extracts the union, so a file two closures
need is extracted once), and declare a `proto_check` over them as
`:logging_v2` and `:storage_v2` are declared.
