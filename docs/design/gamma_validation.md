# Gamma validation: what checks a release before prod, per package family

## What is this document for?

`gamma` is the stage of komira's release machine that publishes a release to
the conda channel `gamma` and then validates what it published, before the
`prod` stage may publish the same set. This document says, for each family of
packages komira publishes or will publish, what checks the release before
prod, where each check runs, what it can catch and what it cannot. It keeps
three things apart that are easy to blur:

- what the code does today (marked **EXISTS**, with the path that does it);
- what this document proposes (marked **PROPOSED**); nothing proposed here
  has code behind it yet;
- what is left for the project owner to decide (the last section).

[release machines](release_machine.md) is the authority for the machine's
grammar and the two validation kinds; [ci.md](../ci.md) for the workflows and
the build farm. This document cites them and does not repeat them.

## What constrains gamma?

- **No production cloud.** No gamma check may create, read or depend on a
  production account, project, subscription or service.
- **Open-source CI.** Anyone with a fork must be able to understand what ran,
  and ideally to run it. A pull request from a fork gets no secrets
  ([ci.md](../ci.md#pull-requests-from-forks)), so a check that needs one is
  invisible to an outside contributor.
- **No stored secret.** Publishing uses trusted publishing (an OIDC identity
  token, no stored credential), and gamma and prod run kci with
  `--secret-store none` (`.github/workflows/kci.yml`). kci reads secrets only
  through `--secret-store none|env` (`src/kci_cli/args.mojo`).
- **The validate job holds nothing.** gamma runs as two jobs of `kci.yml`:
  `gamma` publishes (`--only step:publish`, in the GitHub environment
  `gamma`), and `validate` runs the validations (`--only validation:<name>`).
  `validate` runs on a GitHub-hosted `ubuntu-24.04` runner with no farm, no
  container, no GitHub environment, `contents: read` and no `id-token`, and a
  60-minute timeout (`.github/workflows/kci.yml`, job `validate`; the header
  of `release/machine.textproto`). It is the job a validation runs in today.
- **`validate` is a job, not a stage.** The stages are `build`, `gamma`,
  `prod` and `pr` (`release/machine.textproto`). This document says "gamma's
  validations" for what the `validate` job runs.

## What runs in gamma today? (EXISTS)

`release/machine.textproto` gives gamma's PUBLISH step two validations, both
of kind `CONDA_INSTALL_ENV` with `smoke: README`:

| validation | installs | runs |
|---|---|---|
| `install-komira-encoding` | `komira_encoding` alone | its README examples |
| `install-set` | `komira_all` alone; kci reads the members from the built metapackage's requirements | every member's README examples |

Each one installs from the `gamma` channel with the pinned pixi, in a fresh
scratch directory outside the checkout and an environment built from nothing
(`src/kci_validate/env.mojo`), checks each installed README's sha256 against
the release's record, and runs every ` ```mojo ` block of every installed
README against the install (`src/kci_validate/readme_installed.mojo`).
`release/validations/BUCK` makes each one a target a developer can run, also
against a local channel before publishing
([release machines](release_machine.md#what-does-this-repositorys-release-machine-say)).

Three properties of this check shape everything below:

1. **A README example cannot reach a service.** Every ` ```mojo ` block runs;
   there is no skip word, and a sketch that cannot run must be fenced
   ` ```text ` (`tools/build/readme_examples/readme_examples/examples.mojo`).
   The same examples are also a welded test of the library in source mode
   (`tools/build/mojo/defs.bzl`, the README gate), so they run inside a build
   action too. An example that needed a live service could not pass the
   build.
2. **The network is the channels.** The validation asks each declared
   channel host once; no host answering is `INDETERMINATE` (exit 5), never a
   pass (`src/kci_validate/network.mojo`). There is no field to declare any
   other host.
3. **It covers released libraries only.** `release/artifacts.textproto`
   lists 37 libraries and `komira_all`. Of the families below, only
   `komira_kafka_server` and the hermetic utilities and kci libraries are in
   it. No AWS, GCP, Azure, HTTP, gRPC, TLS, database or object-store library
   is released; most wait on the native package (`komira_native`) and the
   release of their closure (open pull requests #672, #704, #761, #763).

The second validation kind, `CONDA_INSTALL_SMOKE`, installs into a
digest-pinned container and runs one `program` under `release/`
(`src/kci_release_machine/graph.mojo`). Its `docker run` uses
`--network=bridge`, a read-only root, no capabilities and four `-e`
variables, and copies in only the program (`src/kci_validate/container.mojo`).
No machine file uses it today, and it has no field for a second container.

## Where can a check run?

The family tables use these places. The first three exist; the last three are
proposed.

| place | what it is | status |
|---|---|---|
| in-process | a fake or conformer in the test's own process, no socket (a scripted connector, an in-memory store) | EXISTS |
| loopback in one action | a server (komira's own `komira_http_server`, or a fake on it) and a client on two threads on 127.0.0.1 in one build action | EXISTS (`src/tests/e2e/*`) |
| per-test service process | a pinned third-party server binary the test starts on a random loopback port and that dies with the test (`komira_test_minio`: sha256-pinned binary, `setpriv --pdeathsig`) | EXISTS as a pattern; [ci.md](../ci.md#what-a-farm-test-action-can-do) lists the farm capabilities it needs |
| per-test service container on the build farm | the same, from a digest-pinned image | PROPOSED; Docker inside a farm action is not a probed capability today |
| sidecar container in gamma | a digest-pinned service container next to a `CONDA_INSTALL_SMOKE` validation | PROPOSED; no field exists |
| real gamma cloud project | a cost-bounded account, project or subscription the project owns, reached through OIDC federation | PROPOSED; kci has no way to express it (see "What kci must add") |

The first four run at build time on the build farm, as welded `test_srcs` or
as standalone tests under `src/tests/e2e` and `src/tests/conformance`; the
pull request's check builds and tests every affected target
(`release/ci/build_targets.sh`, `release/ci/derive_checks.py`), and gamma's
`build` stage builds them again. They test the source build, not the
installed package. Gamma tests the installed package. That split is the
main decision of this document:

> **Protocol and service behaviour is proven at build time on the farm.
> Gamma proves that what a consumer installs from the channel links, loads
> and runs its README.** A service in gamma is added only where installed
> bytes against a service would catch a defect the build cannot, and only
> as an explicit decision (see "Open decisions").

## AWS

Packages: `komira_aws_core` (hand-written SigV4, credential chain, endpoint
rules, retry), 18 clients generated at build time from pinned botocore
models (`tools/build/cloud/aws.bzl`; s3, sqs, sns, dynamodb, dynamodbstreams,
lambda, iam, ec2, ecr, ecs, logs, metrics, route53, scheduler,
secretsmanager, sesv2, apigatewayv2, plus `komira_aws_lambda_http`), and
`komira_objectstore_s3`. None is released.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_aws_core`, every client | EXISTS: the official AWS SigV4 test suite from the pinned aws-c-auth archive, header and query modes (`src/komira_aws_core/tests/test_sigv4_test_suite.mojo`); botocore's S3 endpoint-rule tests, rest-xml protocol corpus and standard retry mode (`src/komira_aws_core/BUCK`); each client's `test_<svc>_endpoints` signing against AWS, FIPS, dual-stack and a custom endpoint (e.g. `src/komira_aws_dynamodb/tests/`); `AwsEchoConnector` and scripted connectors | in-process, build time | a wrong canonical request, signature, endpoint, serialization or retry decision, byte for byte against AWS's own vectors | whether any server accepts the bytes; server-side semantics |
| `komira_aws_secretsmanager` | EXISTS: `komira_secrets_e2e`, a stateful Secrets Manager fake on `komira_http_server` that recomputes SigV4 with `komira_crypto` (not `komira_aws_core`), keeps versions and staging labels, and checks `ClientRequestToken` idempotency | loopback in one action | the real transport path, the signature as an independent server computes it, idempotency | divergence between the fake and AWS: the fake is our reading of the API |
| `komira_objectstore_s3`, `komira_aws_s3` | EXISTS: `komira_test_fake_s3`, an in-memory S3 connector with fault injection, in `test_deps` | in-process | conditional-write and retry logic against scripted 409/412/5xx | a real S3 server; no socket |
| `komira_objectstore_s3`, `komira_job_supervisor` | EXISTS, opt-in: MinIO from a sha256-pinned binary (`komira_test_minio`); the two `komira_job_supervisor` MinIO tests are binaries that SKIP (exit 77) without `--test-minio-binary`, so no gate runs them (`src/komira_job_supervisor/BUCK`) | per-test service process, run by hand | SigV4 checked by an independent server, multipart, ranges, conditional PUT, pagination | AWS-only behaviour; MinIO's upstream has stopped publishing binaries and archived its repository, so the pin is frozen with no security fixes |
| every released AWS library | PROPOSED (mechanism EXISTS): `install-set` runs their README examples once they are released; the READMEs are already offline (e.g. `src/komira_aws_core/README.md` signs at a fixed clock with the AWS documentation key and asserts the exact signature) | gamma, installed package | packaging and link defects; SigV4 producing the documented signature on the consumer's install | any network behaviour |
| S3, SQS, SNS, DynamoDB, Logs | PROPOSED: verifying fakes on loopback in the `komira_secrets_e2e` pattern, S3 first (a socket front for `komira_test_fake_s3` that recomputes SigV4) | loopback in one action | as `komira_secrets_e2e`, per service | fake-vs-AWS divergence; one fake per service to maintain |
| the generated clients broadly | PROPOSED: moto server (Apache-2.0, no account, no token), one process for every service in scope, from a pinned image or a pinned Python package | per-test service container or process on the build farm | each client's requests parsed and answered by an independent, botocore-derived implementation; error codes, pagination tokens, stateful round-trips | signature verification (off by default, and described by moto as basic when on: a corrupted-signature mutant must turn the run red before we rely on it); Lambda Invoke, ECS tasks and Scheduler firing (they need a Docker socket, which we do not grant) |
| S3, SQS, STS, Secrets Manager | PROPOSED, decision: a real gamma AWS account, OIDC role, run-scoped resources | real gamma cloud project | AWS itself rejecting what every emulator accepted; virtual-host, dual-stack and FIPS endpoints; real IAM | reproducibility for outsiders; real-network flakes |

`komira_objectstore_s3` has no README, so the README check would refuse it
(`src/kci_validate/readme_installed.mojo`); it needs one before it can be
released. LocalStack is discussed under "Open decisions": it is not proposed
here.

## GCP

Packages: `komira_gcp_core` (tokens, ADC, retry, pagination),
`komira_gcp_storage` (gRPC `google.storage.v2`, `protocol = "grpc"` in its
BUCK), `komira_objectstore_gcs`, `komira_gcp_firestore` (REST v1 and a gRPC
listen client), `komira_gcp_firestore_db`, `komira_gcp_logging`,
`komira_gcp_monitoring_client`, `komira_gcp_monitoring`, the generated REST
clients (iam, run, secretmanager, compute, artifactregistry, apigateway,
cloudscheduler, cloudresourcemanager, serviceusage) and `komira_gcp_wif`.
None is released. **There is no Pub/Sub, Bigtable, Spanner or Datastore
client** in `src/`.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_objectstore_gcs` | EXISTS: `FakeGcsStorageBackend` (`src/komira_objectstore_gcs/fake_backend.mojo`); a `GetObject` stub over TLS and h2 (`test_gcs_grpc_trust`) | in-process; loopback in one action | the backend seam's precondition logic; the TLS trust path | real v2 message semantics |
| `komira_gcp_firestore`, `komira_gcp_firestore_db` | EXISTS: `ScriptedFirestore` and `ExchangeConnector` (`src/komira_gcp_firestore/firestore_scripted.mojo`, `firestore_fake.mojo`); every `komira_gcp_firestore_db` test runs on `MockFirestore` | in-process | request and response encoding; `komira_db` conformance against the mock (open PR #679) | Firestore's real precondition, query and transaction behaviour |
| `komira_gcp_secretmanager` | EXISTS: a Secret Manager fake behind a TLS front in `komira_secrets_e2e` | loopback in one action | transport, TLS, request shape | fake-vs-service divergence |
| `komira_gcp_storage`, `komira_objectstore_gcs` | PROPOSED: Google's storage-testbench (Apache-2.0), which serves the gRPC v2 API Google's own client libraries test against, including per-request fault injection | per-test service process (needs a pinned Python with grpcio, open PR #767) or container | v2 preconditions, resumable and bidi write framing, ranges, error details, the retry classifier against Google's fault scripts | real auth (any bearer is accepted), IAM, TLS to the real service |
| `komira_gcp_firestore`, `komira_gcp_firestore_db` | PROPOSED: Google's Firestore emulator; the client already supports a plaintext endpoint and the emulator bearer (`FIRESTORE_EMULATOR_BEARER` in `src/komira_gcp_firestore/firestore_client.mojo`); PR #679's suite as a third target | per-test service container (Java, from Google's CLI image) | real preconditions, queries, commit and listen framing against Google's implementation | IAM, security rules, index requirements, quotas |
| every released GCP library | PROPOSED (mechanism EXISTS): README examples, which use scripted connectors and open no socket | gamma, installed package | packaging and link defects; README-vs-API drift | any service behaviour |
| iam, run, compute, artifactregistry, apigateway, cloudscheduler, cloudresourcemanager, serviceusage, secretmanager, logging, monitoring, wif | PROPOSED, decision: a small real gamma GCP project; read-mostly and free-tier calls, one create/delete where needed, no Compute instance by default | real gamma cloud project | real auth (scopes, STS exchange, expiry), real error envelopes, LRO polling, pagination, quota classification | determinism (needs an INDETERMINATE outcome for a provider outage); outsiders cannot run it |

Not proposed: **fake-gcs-server**. It serves the JSON and XML REST API;
komira's GCS path is gRPC v2 only, so a run against it would test a path no
komira code takes. **The Pub/Sub, Bigtable, Spanner and Datastore
emulators**: there is no client for them to test. Each is adopted in the
pull request that adds its client, or not at all.

No emulator exists for the generated control-plane clients (IAM, Run,
Compute, Artifact Registry, API Gateway, Cloud Scheduler, Resource Manager,
Service Usage, Logging, Monitoring, WIF). Until a real project exists their
checks are the welded tests and scripted-byte README examples.

## Azure

Packages: `komira_azure_core` (account key, SAS, IMDS managed identity, a
service principal with a client secret; no federated credential) and
`komira_azure_blob` (Shared Key, SAS, `AzureStore`, `AzureFs`). Neither is
released; `komira_azure_blob` also waits on `komira_plan_expr` and so on
`komira_arrow`.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_azure_blob` | EXISTS: `komira_azure_blob_e2e`, a fake Blob service on `komira_http_server` that recomputes Shared Key with its own canonicalizer under the published Azurite development key and refuses a mismatch with 403 | loopback in one action | the real socket path; Shared Key as an independent canonicalizer computes it | real list XML, error codes and range semantics as Microsoft implements them |
| `komira_azure_blob` | PROPOSED: Azurite (MIT); the client already has first-class Azurite addressing (`AzureConfig.azurite` in `src/komira_azure_blob/azure.mojo`, with a README example) | per-test service container (Azurite is Node.js, not one static binary) | list pagination (`NextMarker`, delimiters), 404/412/416 codes, conditional Put Blob, Shared Key as Microsoft's code checks it | Entra and IMDS auth, virtual-hosted addressing, TLS to the real service, Azurite's documented feature gaps |
| both, once released | PROPOSED (mechanism EXISTS): README examples | gamma, installed package | packaging and link defects | service behaviour |
| `komira_azure_core` Entra paths | PROPOSED, later, decision: a real subscription through a GitHub OIDC federated credential | real gamma cloud project | Entra tokens, virtual-hosted addressing, real TLS | IMDS (needs an Azure VM); blocked: `komira_azure_core` has no federated credential, and a client secret is a standing secret |

## Network: HTTP, TLS, gRPC, Connect, DNS, JWKS, OCI, crypto, Kafka codec

Packages: `komira_http_core` (including TLS over s2n-tls in
`komira_http_core/tls`), `komira_http_client`, `komira_http_server`,
`komira_grpc` (the client), `komira_connect` (the gRPC and Connect server),
`komira_net`, `komira_jwks`, `komira_oci`, `komira_crypto` (AWS-LC primitives
and its own RFC 5280 chain validation) and `komira_kafka_server` (a wire
codec; it opens no socket, `src/komira_kafka_server/README.md`). Only
`komira_kafka_server` is released.

This family needs no cloud, no emulator and no secret: everything runs on
127.0.0.1.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_http_server` | EXISTS: h2spec v2.6.0 (summerwind/h2spec, MIT, pinned by sha256 in `third_party/h2spec`), the strict suite against a real server over TLS and ALPN h2; exactly 147 cases required, a shrink-only allowlist that is empty (`src/tests/conformance/komira_http_conformance`) | per-test service process, build time | any h2 framing, HPACK, stream-state or flow-control regression h2spec has a case for; incidentally a Go `crypto/tls` handshake against komira's s2n server | the client's h2; HTTP/1.1; linux x86_64 only |
| `komira_connect` | EXISTS: Connect conformance v1.0.5 (connectrpc/conformance, Apache-2.0) in server mode: 236 cases selected, at least 16 must pass, a known-failing list that only shrinks (`src/tests/conformance/komira_connect_conformance`) | per-test service process, build time | regressions in the passing cases; a listed case starting to pass | most of the suite. These numbers mean "runs the suite", not "conformant" |
| `komira_http_*`, `komira_grpc` | EXISTS: loopback tests (`src/komira_grpc/tests/test_e2e_live_socket.mojo`, a real server over TLS and h2 against a real `GrpcClient`); `komira_http_tls_e2e` (HTTP/1.1 over TLS byte for byte, the ALPN switch to h2, an untrusted root and a wrong name refused); `komira_http_core`'s TLS tests on fixture certificates | loopback in one action | the socket, reactor, TLS handshake and ALPN path; trust refusals | an independent TLS peer (both ends are s2n) |
| `komira_http_core` TLS | PROPOSED, in flight: `komira_tls_interop_e2e` against `bssl` built from the pinned aws-lc (open PR #764) | per-test service process | version, cipher, ALPN, SNI and refusal behaviour against a non-s2n peer | `bssl` shares BoringSSL lineage with aws-lc, so it is less independent than OpenSSL or Go |
| `komira_grpc` | PROPOSED: the same Connect conformance pin in client mode, with a client-under-test binary | per-test service process | client framing, trailers-only responses, status and metadata decoding, deadlines, streaming against the suite's reference servers | the same feature gaps as server mode |
| `komira_crypto` | EXISTS: NIST CAVP SHA-2 and Wycheproof HKDF vectors; a synthetic 19-case BetterTLS-style corpus for chain validation. PROPOSED: C2SP x509-limbo and the remaining Wycheproof sets (AES-GCM, ChaCha20-Poly1305, ECDSA, Ed25519, X25519, RSA) | in-process | path-validation bugs in komira's own validator against an independent corpus; FFI misuse | primitive bugs inside AWS-LC (tested upstream) |
| `komira_oci` | EXISTS: an in-process registry fake. PROPOSED: a pinned real registry (zot or the CNCF distribution registry, Apache-2.0) | per-test service process | upload sessions, cross-repo mounts, redirects, digest headers as a real registry answers them | hosted-registry auth flows |
| `komira_kafka_server` | EXISTS: goldens hand-written from Kafka 3.9.0 schemas, none captured from a client (`src/komira_kafka_server/tests/GOLDENS.md`); README examples in `install-set` today. PROPOSED: goldens captured once from a real client | in-process; gamma for the README | a misreading shared by the golden and the codec, once captured goldens exist | nothing end to end until a server exists |
| the HTTP and gRPC libraries, once released | PROPOSED: one loopback example in each README (a server on 127.0.0.1 port 0 and one request; one unary RPC for gRPC and Connect), so gamma executes the installed reactor and, with TLS, the installed s2n and aws-lc | gamma, installed package; the same bytes are the welded README test | the installed runtime path: symbol-prefix or link-order breakage, a missing native symbol, a trust-store or path defect on a clean machine | protocol breadth (that stays at build time). TLS needs a certificate in the README: a decision |

Not proposed: grpc/grpc interop binaries (upstream ships none prebuilt, the
repository has no Go toolchain, and Connect conformance in both modes covers
most of the same cases); tlsfuzzer and BoGo (they mostly test s2n-tls itself,
which upstream already does).

## Data services: object stores, broker, search, databases, secrets, supervisors

Packages: `komira_objectstore`, `komira_objectstore_s3`,
`komira_objectstore_gcs`, `komira_fs_registry`, `komira_broker`,
`komira_broker_coordinator`, `komira_search`, `komira_search_catalog`,
`komira_search_scan`, `komira_db`, `komira_db_sqlite`, `komira_db_postgres`,
`komira_iceberg_catalog`, `komira_snapshotter`, `komira_log_query`,
`komira_secret_store`, `komira_secret_registry`, `komira_secret_env`,
`komira_job_supervisor`, `komira_supervisor`. None is released.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_broker`, `komira_broker_coordinator`, `komira_search*` | EXISTS: `broker_e2e` (a coordinator and three nodes, replay from disk, reassignment, retention, compaction) and `komira_search_e2e` (publish, cold read, publish races) over `LocalFsConditionalStore` | in-process, build time | contract and logic defects: CAS preconditions, manifest races, lease fencing, replay | a real store's wire, latency and listing behaviour |
| `komira_objectstore` and its conformers | EXISTS: in-memory, shared in-memory (latency, slow CAS) and local-fs conditional stores. PROPOSED: one `ConditionalWriteStore` contract suite under `src/tests/conformance`, run against every conformer (in-memory, local fs, `komira_test_fake_s3`, `FakeGcsStorageBackend`, and each service tier below) | in-process; the service rows as they land | a conformer that disagrees with the contract the broker and search rely on | nothing beyond the conformers it is given |
| `komira_db`, `komira_db_sqlite` | EXISTS: SQLite statically linked and in-process; PR #679 adds the shared `komira_db` suite | in-process | backend-neutral contract defects | nothing service-shaped: SQLite runs in the process |
| `komira_db_postgres` | EXISTS: SCRAM and codec vectors and a socketpair-driven frame; **no test talks to a real PostgreSQL**. PROPOSED: a pinned PostgreSQL started in-action (the `komira_test_minio` pattern; initdb as `nobody`, which the farm's `uid` capability row supports; TLS with a fixture certificate; SCRAM), as a third PR #679 target | per-test service process | SSLRequest and TLS negotiation, SCRAM details, binary decoding of real rows, error-field mapping, transaction-state errors, pool reuse after an error | managed-Postgres auth, proxies, failover; version skew unless two majors are pinned |
| `komira_iceberg_catalog` | EXISTS: a REST catalog fake on loopback (`test_iceberg_rest_loopback`). PROPOSED, optional: the Apache Iceberg REST fixture image | loopback; per-test service container | divergence from the reference server's JSON and error model | vendor catalogs |
| `komira_secret_*` | EXISTS: the cloud secret-manager fakes of `komira_secrets_e2e` | loopback in one action | as in the AWS and GCP tables | as there |
| `komira_job_supervisor`, `komira_supervisor` | EXISTS: `komira_job_supervisor_loopback` (a heartbeat receiver on a real server, real `/bin/sh` children); the opt-in MinIO binaries (AWS table) | loopback in one action | the run loop, process supervision, heartbeat HTTP | S3 behaviour, until the MinIO tests are gated |
| the family, once released | PROPOSED (mechanism EXISTS): README examples, which are already offline (in-memory stores, rendered SQL, local fs) | gamma, installed package | packaging and closure defects | every service behaviour |

README gaps that block release: `komira_objectstore`, `komira_objectstore_s3`,
`komira_job_supervisor` and `komira_supervisor` have no README;
`komira_secret_env`'s README has no ` ```mojo ` block.

A side finding for review: `PgConfig` defaults `require_tls = True` and
`verify_cert = False` (`src/komira_db_postgres/wire/connection.mojo`), so by
default the connection is encrypted but the server is not authenticated. A
real-server test should pin both settings.

## Formats, engine, runtime and core utilities

Packages: the formats (`komira_parquet*`, `komira_arrow`,
`komira_arrow_ipc`, `komira_avro`, `komira_orc`, `komira_csv`, `komira_json*`,
`komira_jsonl`, `komira_compression`, `komira_lz4`, `komira_zlib`), the
engine (`komira_plan_*`, `komira_sql`, `komira_optimizer`, `komira_eval`,
`komira_agg*`, `komira_kernels`, `komira_shuffle*`, `komira_dispatch_*`,
`komira_join_assembly`), the runtime (`komira_async*`, `komira_fs`,
`komira_log`, `komira_metrics*`, `komira_trace`, `komira_sync`,
`komira_spsc_ring`) and the core utilities (`komira_hash`, `komira_simd`,
`komira_clock`, `komira_host`, `komira_encoding`, ...). Of these,
`komira_encoding`, `komira_json`, `komira_hash`, `komira_atomic_alias`,
`komira_clock`, `komira_simd`, `komira_host` and `komira_parquet_api` are
released.

This family needs no service, no secret and no cloud. The questions here are
about the installed package itself.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| the formats and codecs | EXISTS: pinned upstream corpora (`third_party/arrow-testing`, `apache-avro`, `parquet-format`, `jsontestsuite`, `snappy`, `pierrec-lz4`, `zlib`, `brotli`); pyarrow-written Parquet and Arrow IPC fixtures with their generator scripts; foreign ORC and Avro files in `komira_formats_e2e`; `komira_json_conformance`; the Arrow C Data Interface probe (`src/komira_arrow_ipc/BUCK`, `arrow_c_abi_probe`) | in-process, build time | codec and format correctness and regressions, reading what other implementations wrote | the write direction: every cross-implementation fixture is foreign-writer, komira-reader |
| every released library | EXISTS: `install-set` README examples | gamma, installed package | layout and metadata errors, closure errors, README drift, a metapackage whose members drift from the release set | anything a README does not touch |
| libraries requiring `komira_native` | PROPOSED, in flight: the README run gains `-Xlinker -L<env>/lib -Xlinker -lkomira_native`, with link names taken from the native package's `lib/lib<x>.so` rows (open PR #763) | gamma, installed package | a library that stopped requiring `komira_native`; a malformed link name; the glibc floor | per-library static archives (next row) |
| `komira_log` and every library above it | PROPOSED: a build-mode README check: `mojo build` with run path `$ORIGIN/../lib` and `-l` for each per-library `.a` row of each installed package, then run the binary. On the PR #763 branch, `komira_log`'s package ships `lib/libkomira_log_holder.a`, and its native README states that `mojo run` does not link a static archive | gamma, installed package | a per-library archive missing from its package or misnamed; a run-path or NEEDED mistake only a built binary shows | interop; it costs a full compile per README |
| `komira_compression`, `komira_lz4`, `komira_zlib` and the formats above them | PROPOSED: a codec load-origin check: compress and decompress one frame per codec, then fail unless each loaded codec library lies under the installed environment's `lib/` | gamma, installed package | a wrong or missing conda-forge requirement: the codecs are opened by bare soname at first use (`src/komira_compression/codec_libraries.mojo`), and the runner image ships its own copies, so today such a requirement would pass gamma | codec correctness (build time) |
| `komira_parquet`, `komira_arrow_ipc`, `komira_orc`, `komira_avro`, `komira_csv`, `komira_jsonl` | PROPOSED: an interop leg: pyarrow (Apache-2.0) and fastavro (MIT) pinned exactly from conda-forge in the same environment read what the installed komira wrote, and komira reads what they wrote | gamma, installed package; or build time with pinned downloads | the write direction; C Data Interface export into a real pyarrow process; komira's native library coexisting with pyarrow's in one process | breadth (one dataset per format); other platforms |

The interop leg needs a grammar change: `install` must name release members
and `smoke` has one word (`src/kci_release_machine/graph.mojo`), so a
third-party oracle cannot be requested today.

Runtime packages without a README (`komira_log`, `komira_async`, `komira_fs`,
`komira_metrics`, `komira_metrics_reader`, `komira_trace`, `komira_sync`,
`komira_spsc_ring`) cannot be released until they have one.

## kci libraries

The released kci libraries (`kci_api`, `kci_release_channel`,
`kci_artifact_manifest`, `kci_logs`, `kci_params`, `kci_release_machine`,
`kci_resource_proto`, `kci_validator_rows`, `kci_validator_report`,
`kci_workflow_check`) are checked by their README examples in `install-set`
(EXISTS). The deploy side is checked at build time against `kci_cloud_fake`,
the in-memory clouds that model kci's resource model (EXISTS). Neither
`kci_cloud_fake` nor any other kci library is an emulator of a cloud SDK API;
it cannot validate the AWS, GCP or Azure clients.

No kci binary is released, so gamma never tests an installed kci: kci built
from source runs the validations. If a kci package is released, a dry run of
`kci run --stage pr` over `release/` from the installed binary is the natural
check (PROPOSED).

## Cross-cutting

### Identity and secrets

- **Emulators need none.** moto, Azurite, the Firestore emulator,
  storage-testbench, PostgreSQL, h2spec and Connect conformance run with no
  account and no token. They are the default for every proposal above.
- **A tokened emulator breaks two deliberate properties.** The `validate`
  job has no environment and no secret (`kci.yml`), and a
  `CONDA_INSTALL_SMOKE` container receives four fixed `-e` variables and
  nothing else (`src/kci_validate/container.mojo`). A licence token would
  have to live in a GitHub environment on a new job, and fork pull requests
  would never see it.
- **A real cloud project is reached by OIDC federation only.** No stored
  key: kci never holds standing access. That needs, first:
  `external_account` credentials in `komira_gcp_core` (refused by name
  today, `src/komira_gcp_core/adc.mojo`) and a federated credential in
  `komira_azure_core` (none exists). On AWS, a role assumed with the
  workflow's identity token.
- **No deployment fact is committed.** Account, project, pool, role and
  tenant identifiers live in the GitHub environment's variables, never in
  this repository.

### Cost bounds and cleanup

- A cloud budget **alerts**; it does not cap. A hard stop on GCP needs a
  budget notification that detaches billing (which stops the project), plus
  per-API quota overrides; Azure pay-as-you-go has no hard spending limit at
  all. Any real project needs that automation designed and owned before it
  runs.
- Cleanup follows `komira_test_bucket`: everything under a run-scoped
  prefix, deleted, listed again, and a verdict that is not CLEAN fails the
  run (EXISTS for S3 in the opt-in MinIO tests; `src/komira_job_supervisor/BUCK`
  describes it). For a real project, a scheduled sweeper that
  deletes only resources carrying an old validation run id (PROPOSED).

### Validation run id stamping

`komira_validation_run` defines the label `kci-run-id`, legal as both an AWS
tag and a GCP label, and `kci_cloud` writes it on resources created in a
scope that carries a validation run id (EXISTS:
`src/komira_validation_run/validation_run_tag.mojo`,
`src/kci_cloud/adapter.mojo`). **No kci verb sets a scope's validation run id
yet**, so nothing real is stamped. Some resources take no labels (IAM service
accounts), so the id must also be encodable in a resource's name or
description, and the sweeper must know which form each type uses. The
validation run id is not `komira_test_run_id`, which names one test process.

### Time budget

- `validate` job: 60 minutes for both validations together, each of which
  may wait up to `wait_for_index_seconds` (1800 by default, 3600 at most,
  `src/kci_release_machine/graph.mojo`) for the channel index.
- `CONDA_INSTALL_SMOKE`: 900 s to pull, 2700 s to run
  (`src/kci_validate/container.mojo`).
- Build-time tests run under the remote action limit (the Connect
  conformance run budgets 420 s of it).
- A service validation in gamma therefore needs its own job and timeout; it
  must not share the `validate` job's hour.

### What kci must add to run service validations in gamma

None of this exists. Each item is a change to `kci_api`,
`kci_release_machine`, `kci_validate` and `kci.yml`, with a golden test of
the `docker` argv, and gets a design note of its own first.

1. A `service` block on `CONDA_INSTALL_SMOKE`: a digest-pinned image, a
   port, readiness; kci starts it with the same hardening as the program's
   container, on a per-validation internal docker network, writes the
   endpoints to a file in `/work` (configuration is a file or a flag, not an
   environment variable), runs the program, and tears the service down.
2. The network check must learn service hosts, so a service that never
   answers is a FAIL or INDETERMINATE, never a pass.
3. For an interop leg: a closed-vocabulary way to install a pinned
   third-party package from `extra_channel` and a second `smoke` word.
4. For a build-mode README run: a `smoke` word or an automatic switch when
   the install holds a per-library archive.
5. For a real cloud project: a DEPLOY body, a cell field (both reserved:
   `src/kci_api/verbs.mojo`, `src/kci_release_machine/graph.mojo`), a verb
   that sets the validation run id, a bootstrap for the federated identity,
   and an INDETERMINATE outcome for a provider outage.

## Gaps

- No AWS, GCP, Azure, HTTP, gRPC, TLS, database or object-store library is
  released, so gamma validates none of them today. Every row for them above
  that says "gamma" is PROPOSED.
- Libraries without a README cannot be released: `komira_objectstore`,
  `komira_objectstore_s3`, `komira_job_supervisor`, `komira_supervisor`,
  the eight runtime packages, most GCP clients (open PR #757 adds eight), and
  most kci libraries; `komira_secret_env` has a README with no example.
- No validation kind can start a service, and the network check declares only
  channel hosts.
- Service tests never run against installed bytes: a defect that appears only
  in the conda layout is caught only if a README example touches it.
- Only Secrets Manager (AWS and GCP) and Azure Blob have an over-the-socket
  test against an independent verifier. The other AWS clients are checked
  only against recorded bytes and canned responses.
- `komira_db_postgres` has never run against a real PostgreSQL.
- There is no shared contract suite for `ConditionalWriteStore`.
- The MinIO tests are opt-in and run by no gate; the MinIO pin is frozen
  upstream.
- Connect conformance requires 16 of 236 cases; the `komira_grpc` client is
  never run against an independent server.
- Write-direction format interop is untested anywhere.
- Codec origin is untested: a wrong conda-forge codec requirement passes on
  the runner's own system libraries.
- The per-library archive of `komira_log` cannot be linked by `mojo run`, so
  its README cannot pass gamma's current check, although the welded README
  test passes (it links archives through the build).
- Lambda Invoke, ECS run-task and Scheduler firing cannot be validated end to
  end by any emulator without a Docker socket.
- Only linux x86_64 is validated; the h2spec and Connect conformance pins are
  linux x86_64 only.
- [release machines](release_machine.md) lists the fields of
  `CONDA_INSTALL_SMOKE` in its table and describes `CONDA_INSTALL_ENV` only in
  prose, although gamma uses only the latter.

## Open decisions (for the project owner)

Each is a question with a recommendation; none is decided by this document.

1. **Service validations in gamma, or at build time only?** Add a `service`
   sidecar to `CONDA_INSTALL_SMOKE`, or keep gamma install-only and put
   service tests on the farm at build time? *Recommendation:* build time
   first. Gamma's job is "what was published installs and works", which the
   README check proves; revisit when a service test against installed bytes
   would catch a defect class the build cannot.
2. **LocalStack.** Current LocalStack images require an auth token for all
   use, including the services the former community image covered (the last
   image without one, 4.4.0, is frozen). The free tier is for non-commercial
   use; ECR, ECS and API Gateway v2 need a paid plan; an open-source licence
   is by application. A token is a secret: it cannot reach the `validate`
   job or a fork's pull request without weakening the isolation above, and a
   contributor without an account cannot reproduce a run. *Recommendation:*
   do not adopt it for the public CI. Use moto server (Apache-2.0, no token)
   for broad AWS coverage, verifying fakes for the services where a
   signature check matters, and, if fidelity beyond moto is ever needed,
   apply for the open-source licence and run it only at build time on the
   farm.
3. **moto as the AWS emulator.** *Recommendation:* yes, pinned by digest or
   by package hash, after a probe shows that a corrupted signature turns a
   run red with authentication enabled; until then it proves the protocol,
   not the signature.
4. **Real gamma cloud projects (AWS, GCP, Azure).** Approve the spend and the
   one-time bootstrap? *Recommendation:* not yet. First land keyless identity
   (`external_account` in `komira_gcp_core`, a federated credential in
   `komira_azure_core`), the verb that sets the validation run id, and the
   billing-stop automation. Then start with GCP (most clients without an
   emulator), read-mostly, in its own job and environment, and advisory
   rather than blocking prod until it has a month of history.
5. **Emulator images and jars at build time.** May the pull request's check
   pull Google's emulator images and other service images? *Recommendation:*
   yes, by digest only, after a farm capability row proves Docker (or the
   chosen process form) works in a test action. Check the Firestore
   emulator's redistribution terms before pinning a copy anywhere komira
   publishes; pulling Google's image at test time is the lower-risk path.
6. **MinIO.** *Recommendation:* keep it for the existing opt-in S3 tests and
   plan its retirement; choose a maintained permissive S3-compatible server
   (moto, or SeaweedFS after a probe of `If-None-Match`/`If-Match`) for the
   `ConditionalWriteStore` suite.
7. **TLS in a README example.** A loopback TLS example needs a certificate,
   and a shipped README can neither link a fixture file nor carry one into a
   container. Options: an inline throwaway key in a public README, an
   in-process self-signed certificate helper in `komira_crypto` (none
   exists), or plaintext-only loopback examples. *Recommendation:* plaintext
   loopback in the README now; the certificate helper as follow-up work.
8. **The per-library archive.** *Recommendation:* add the build-mode README
   check before `komira_log`, or any library above it, is declared for
   release; otherwise `install-set` fails on the first such release.
9. **Codec origin and native link flags.** *Recommendation:* land open PR
   #763's native link flags, and add the codec load-origin check in the same
   release that first ships `komira_compression`.
10. **Format interop in gamma.** *Recommendation:* both: breadth at build
    time with pinned pyarrow, one round trip per format in gamma.
