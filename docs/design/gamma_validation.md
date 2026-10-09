# Gamma validation: what checks a release before prod, per package family

**Superseded in part by [native_packaging.md](native_packaging.md).** Every
row and note here about the shared-library package `komira_native` (the
release state list, "Declared by open pull requests", its row in the library
table, and the gap list) describes a plan that is replaced: each library that
owns C ships its own shared library in its own package, and every check of an
installed native package runs in beta's install job, not in gamma. That plan's
slice 13 rewrites these rows; until then, read them as history.

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

Where it names an open pull request, it describes that pull request's head
at the time of writing, not `main`. Those sentences go stale as the pull
requests merge; issue #779 tracks updating them.

## What constrains gamma?

- **No production cloud.** No gamma check may create, read or depend on a
  production account, project, subscription or service.
- **Open-source CI.** Anyone with a fork must be able to understand what ran,
  and ideally to run it on their own machine. A fork's pull request gets no
  check at all: `pr.yml`'s `check` job is skipped for it and no other
  workflow runs ([ci.md](../ci.md#pull-requests-from-forks)). So no choice of
  emulator makes a check visible on a fork's pull request; what separates
  them is whether an outside contributor can reproduce the run locally
  without an account, a token or a licence.
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
   lists 37 libraries and `komira_all`: ten kci libraries,
   `komira_kafka_server`, the protobuf, textproto and XML codecs
   (`komira_protobuf`, `komira_textproto`, `komira_wkt`, `komira_proto_codec`,
   `komira_xml`), core utilities, and the test-support libraries
   (`komira_validation_run`, `komira_test_run_id`, `komira_test_verdict`);
   the full list is under "Formats, engine, runtime and core utilities". No
   AWS, GCP, Azure, HTTP, gRPC, TLS, database or object-store library is
   released; most wait on the native package (`komira_native`) and the
   release of their closure (the native stack of open pull requests, #672
   at its base up to #763 at its top).
   Two open pull requests declare more: #755 adds `komira_collections`,
   `komira_broker_proto`, `komira_supervisor_proto` and `komira_plan_proto`;
   #761 adds those four and `komira_native`, `komira_libc`, `komira_buffer`,
   `komira_async_api` and `komira_dynamic_filter` (see "Declared by open
   pull requests" below).

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
| per-test service process | a pinned third-party server binary the test starts on a random loopback port and that dies with the test (`komira_test_minio`'s sha256-pinned binary, started by `komira_test_s3_adapter`'s `SpawnedProcessRunner` under `setpriv --pdeathsig`) | EXISTS as a pattern; [ci.md](../ci.md#what-a-farm-test-action-can-do) lists the farm capabilities it needs |
| per-test service container on the build farm | the same, from a digest-pinned image | PROPOSED; Docker inside a farm action is not a probed capability today |
| sidecar container in gamma | a digest-pinned service container next to a `CONDA_INSTALL_SMOKE` validation | PROPOSED; no field exists |
| real gamma cloud project | a cost-bounded account, project or subscription the project owns, reached through OIDC federation | PROPOSED; kci has no way to express it (see [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)) |

The first three run (and the fourth would run) at build time on the build
farm, as welded `test_srcs` or as standalone tests under `src/tests/e2e` and
`src/tests/conformance`. Which of them a run builds depends on the stage:

- The pull request's check (`kci run --stage pr --affected-by <base>`,
  `src/kci_build/affected.mojo`) builds the units the change reaches,
  including the standalone and per-package checks `release/ci/derive_checks.py`
  derives.
- The release's `build` stage is one BUILD step over
  `release/artifacts.textproto` (`release/machine.textproto`). It builds the
  released `<lib>_conda[release]` targets and, through them, those libraries'
  welded `test_srcs` (a conda package's payload is the library's gated
  `.mojoc`, `tools/build/package/conda.bzl`), and nothing else. It does not
  run `src/tests/e2e`, `src/tests/conformance` (h2spec, Connect),
  `komira_secrets_e2e`, `komira_azure_blob_e2e`, `broker_e2e` or the
  standalone tests of unreleased packages. Those ran, if at all, on the
  pull requests whose changes reached them (see "Gaps").

These checks test the source build, not the installed package. Gamma tests
the installed package. That split is the main decision of this document:

> **Protocol and service behaviour is proven at build time on the farm**
> (today on the pull requests that reach it; on the release revision only
> once kci runs every derived check there, item 6 of
> [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)).
> **Gamma proves that what a consumer installs from the channel links, loads
> and runs its README.** A service in gamma is added only where installed
> bytes against a service would catch a defect the build cannot, and only
> as an explicit decision (see
> [Open decisions](gamma_validation_decisions.md#open-decisions-for-the-project-owner)).

## AWS

Packages: `komira_aws_core` (hand-written SigV4, credential chain, endpoint
rules, retry); 16 clients `komira_aws_<service>` generated at build time
from pinned botocore models (`mojo_aws_client` in
`tools/build/cloud/aws.bzl`), for s3, sqs, sns, dynamodb, dynamodbstreams,
lambda, iam, ec2, ecr, ecs, logs, route53, scheduler, secretsmanager, sesv2
and apigatewayv2; the hand-written CloudWatch
client `komira_aws_metrics` (its BUCK: "Hand-written, not generated", and
not FIPS); the hand-written API Gateway/Lambda adapter
`komira_aws_lambda_http`; and `komira_objectstore_s3`, which also mints
presigned S3 URLs (`S3PresignSigner`, `src/komira_objectstore_s3/presign.mojo`,
behind `komira_objectstore`'s `ObjectUrlSigner`). None is released.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_aws_core`, every generated client | EXISTS: the official AWS SigV4 test suite from the pinned aws-c-auth archive, header and query modes (`src/komira_aws_core/tests/test_sigv4_test_suite.mojo`); botocore's S3 endpoint-rule tests, rest-xml protocol corpus and standard retry mode (`src/komira_aws_core/BUCK`); each generated client's `test_<svc>_endpoints` signing against AWS, FIPS, dual-stack and a custom endpoint (e.g. `src/komira_aws_dynamodb/tests/`; `komira_aws_metrics` is not FIPS); `AwsEchoConnector` and scripted connectors | in-process, build time | a wrong canonical request, signature, endpoint, serialization or retry decision, byte for byte against AWS's own vectors | whether any server accepts the bytes; server-side semantics |
| `komira_aws_secretsmanager` | EXISTS: `komira_secrets_e2e`, a stateful Secrets Manager fake on `komira_http_server` that recomputes SigV4 with `komira_crypto` (not `komira_aws_core`), keeps versions and staging labels, and checks `ClientRequestToken` idempotency | loopback in one action | the real transport path, the signature as an independent server computes it, idempotency | divergence between the fake and AWS: the fake is our reading of the API |
| `komira_objectstore_s3` presigned URLs | EXISTS: `test_s3_presign` compares each URL byte for byte with one signed by an independent SigV4 query-signing implementation written from AWS's query-parameter authentication page (virtual-hosted GET, path-style PUT with a session token), and the TTL and empty-key refusals | in-process, build time | a wrong canonical query, signature, encoding or expiry | whether a server accepts the URL: no test transfers against one. PROPOSED: one presigned PUT and GET round trip against a verifying server (MinIO or moto with authentication on, once a corrupted-signature mutant turns it red) |
| `komira_objectstore_s3`, `komira_aws_s3` | EXISTS: `komira_test_fake_s3`, an in-memory S3 connector with fault injection, in `test_deps` | in-process | conditional-write and retry logic against scripted 409/412/5xx | a real S3 server; no socket |
| `komira_objectstore_s3`, `komira_job_supervisor` | EXISTS, opt-in: MinIO from a sha256-pinned binary (`komira_test_minio`); the two `komira_job_supervisor` MinIO tests are binaries that SKIP (exit 77) without `--test-minio-binary`, so no gate runs them (`src/komira_job_supervisor/BUCK`) | per-test service process, run by hand | SigV4 checked by an independent server, multipart, ranges, conditional PUT, pagination | AWS-only behaviour; MinIO's upstream has stopped publishing binaries and archived its repository, so the pin is frozen with no security fixes |
| every released AWS library | PROPOSED (mechanism EXISTS): `install-set` runs their README examples once they are released; the READMEs are already offline (e.g. `src/komira_aws_core/README.md` signs at a fixed clock with the AWS documentation key and asserts the exact signature) | gamma, installed package | packaging and link defects; SigV4 producing the documented signature on the consumer's install | any network behaviour |
| S3, SQS, SNS, DynamoDB, Logs | PROPOSED: verifying fakes on loopback in the `komira_secrets_e2e` pattern, S3 first (a socket front for `komira_test_fake_s3` that recomputes SigV4) | loopback in one action | as `komira_secrets_e2e`, per service | fake-vs-AWS divergence; one fake per service to maintain |
| the generated clients broadly | PROPOSED: moto server (Apache-2.0, no account, no token), one process for every service in scope, from a pinned image or a pinned Python package | per-test service container or process on the build farm | each client's requests parsed and answered by an independent, botocore-derived implementation; error codes, pagination tokens, stateful round-trips | signature verification (off by default, and described by moto as basic when on: a corrupted-signature mutant must turn the run red before we rely on it); Lambda Invoke (moto runs it in a container, which needs a Docker socket we do not grant); ECS tasks and Scheduler firing (moto records `RunTask` and schedules but starts no container and fires no target, with or without Docker) |
| S3, SQS, STS, Secrets Manager | PROPOSED, decision: a real gamma AWS account, OIDC role, run-scoped resources | real gamma cloud project | AWS itself rejecting what every emulator accepted; virtual-host, dual-stack and FIPS endpoints; real IAM | reproducibility for outsiders; real-network flakes |

`komira_objectstore_s3` has no README, so the README check would refuse it
(`src/kci_validate/readme_installed.mojo`); it needs one before it can be
released. LocalStack is discussed under
[Open decisions](gamma_validation_decisions.md#open-decisions-for-the-project-owner):
it is not proposed here.

## GCP

Packages: `komira_gcp_core` (tokens, ADC, retry, pagination),
`komira_gcp_storage` (gRPC `google.storage.v2`, `protocol = "grpc"` in its
BUCK), `komira_objectstore_gcs` (which reaches GCS two ways: the gRPC v2
backend, and V4 signed URLs, GOOG4-RSA-SHA256, minted by `GcsV4Signer` in
`src/komira_objectstore_gcs/signer.mojo` on
`src/komira_gcp_core/v4_sign.mojo`; a signed URL is a plain HTTPS URL to
`storage.googleapis.com`, the XML API), `komira_gcp_firestore` (REST v1 and
a gRPC listen client), `komira_gcp_firestore_db`, `komira_gcp_logging`,
`komira_gcp_monitoring_client`, `komira_gcp_monitoring`, the generated REST
clients `komira_gcp_<name>` for iam, run, secretmanager, compute,
artifactregistry, apigateway, cloudscheduler, cloudresourcemanager and
serviceusage, and `komira_gcp_wif`.
None is released. **There is no Pub/Sub, Bigtable, Spanner or Datastore
client** in `src/`.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| `komira_objectstore_gcs` | EXISTS: `FakeGcsStorageBackend` (`src/komira_objectstore_gcs/fake_backend.mojo`); a `GetObject` stub over TLS and h2 (`test_gcs_grpc_trust`) | in-process; loopback in one action | the backend seam's precondition logic; the TLS trust path | real v2 message semantics |
| `komira_objectstore_gcs` signed URLs | EXISTS: Google's published V4 signing conformance vectors (`test_v4_sign_conformance` in `komira_gcp_core`, from the sha256-pinned `third_party/googleapis_conformance_tests`); `test_gcs_presign_portability` | in-process, build time | a wrong canonical request, string to sign, encoding or expiry, against Google's own vectors | whether a server accepts the URL: no test transfers against one. PROPOSED: one presigned PUT and GET round trip against storage-testbench's XML endpoint or fake-gcs-server (whether either verifies the signature needs a probe with a corrupted-signature mutant) |
| `komira_gcp_firestore`, `komira_gcp_firestore_db` | EXISTS: `ScriptedFirestore` and `ExchangeConnector` (`src/komira_gcp_firestore/firestore_scripted.mojo`, `firestore_fake.mojo`); every `komira_gcp_firestore_db` test runs on `MockFirestore` | in-process | request and response encoding; `komira_db` conformance against the mock (open PR #679) | Firestore's real precondition, query and transaction behaviour |
| `komira_gcp_secretmanager` | EXISTS: a stateful Secret Manager fake behind a TLS front in `komira_secrets_e2e` (`src/tests/e2e/komira_secrets_e2e/gcp_fake.mojo`): on every request it checks the bearer token's value (401 `UNAUTHENTICATED` for a missing or empty token and for any token other than the fake's), then the path, the global or regional host, and each method's preconditions (409 on a taken id, 400 on a bad CRC32C); `test_gcp_refusals` asserts both 401s and the exact request log, bearer tokens included | loopback in one action | transport and TLS; a missing, empty or wrong bearer token; request shape and endpoint choice; CRC32C | fake-vs-service divergence; token validity as Google judges it (scopes, expiry): a bearer token has no signature for the fake to recompute, so this is a value comparison, not an independent signature check like the AWS and Azure fakes' |
| `komira_gcp_storage`, `komira_objectstore_gcs` | PROPOSED: Google's storage-testbench (Apache-2.0), which serves the gRPC v2 API Google's own client libraries test against, including per-request fault injection | per-test service process (needs a pinned Python with grpcio, open PR #767) or container | v2 preconditions, resumable and bidi write framing, ranges, error details, the retry classifier against Google's fault scripts | real auth (any bearer is accepted), IAM, TLS to the real service |
| `komira_gcp_firestore`, `komira_gcp_firestore_db` | PROPOSED: Google's Firestore emulator; the client already supports a plaintext endpoint and the emulator bearer (`FIRESTORE_EMULATOR_BEARER` in `src/komira_gcp_firestore/firestore_client.mojo`); PR #679's suite as a third target | per-test service container (Java, from Google's CLI image) | real preconditions, queries, commit and listen framing against Google's implementation | IAM, security rules, index requirements, quotas |
| every released GCP library | PROPOSED (mechanism EXISTS): README examples, which use scripted connectors and open no socket | gamma, installed package | packaging and link defects; README-vs-API drift | any service behaviour |
| iam, run, compute, artifactregistry, apigateway, cloudscheduler, cloudresourcemanager, serviceusage, secretmanager, logging, monitoring, wif | PROPOSED, decision: a small real gamma GCP project; read-mostly and free-tier calls, one create/delete where needed, no Compute instance by default | real gamma cloud project | real auth (scopes, STS exchange, expiry), real error envelopes, LRO polling, pagination, quota classification | determinism (needs an INDETERMINATE outcome for a provider outage); outsiders cannot run it |

Not proposed for the gRPC path: **fake-gcs-server**. It serves the JSON and
XML REST APIs and a gRPC interface of the older v1 proto, not
`google.storage.v2`, so it cannot test `komira_gcp_storage`. Its XML path
could carry the signed-URL round trip above, but it does not verify
signatures, so that run would prove transfer framing, not the signature.
**The Pub/Sub, Bigtable, Spanner and Datastore emulators**: there is no
client for them to test. Each is adopted in the
pull request that adds its client, or not at all.

No emulator exists for the generated management-API clients (IAM, Run,
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
| `komira_db_postgres` | EXISTS: SCRAM and codec vectors and a socketpair-driven frame; **no test talks to a real PostgreSQL**. PROPOSED: a pinned PostgreSQL started in-action (the `komira_test_minio` pattern; initdb as `nobody`, which the farm's `uid` capability row supports, given a data directory `nobody` can write: the same row records that `nobody` cannot create a file in `TEST_TMPDIR`, so the test must create and hand over its own directory first; TLS with a fixture certificate; SCRAM), as a third PR #679 target | per-test service process | SSLRequest and TLS negotiation, SCRAM details, binary decoding of real rows, error-field mapping, transaction-state errors, pool reuse after an error | managed-Postgres auth, proxies, failover; version skew unless two majors are pinned |
| `komira_iceberg_catalog` | EXISTS: a REST catalog fake on loopback (`test_iceberg_rest_loopback`). PROPOSED, optional: the Apache Iceberg REST fixture image | loopback; per-test service container | divergence from the reference server's JSON and error model | vendor catalogs |
| `komira_secret_*` | EXISTS: the cloud secret-manager fakes of `komira_secrets_e2e` | loopback in one action | as in the AWS and GCP tables | as there |
| `komira_job_supervisor`, `komira_supervisor` | EXISTS: `komira_job_supervisor_loopback` (a heartbeat receiver on a real server, real `/bin/sh` children); the opt-in MinIO binaries (AWS table) | loopback in one action | the run loop, process supervision, heartbeat HTTP | S3 behaviour, until the MinIO tests are gated |
| the family, once released | PROPOSED (mechanism EXISTS): README examples, which are already offline (in-memory stores, rendered SQL, local fs) | gamma, installed package | packaging and closure defects | every service behaviour |

README gaps that block release: `komira_objectstore`, `komira_objectstore_s3`,
`komira_job_supervisor` and `komira_supervisor` have no README;
`komira_secret_env`'s README has no ` ```mojo ` block (nor has
`komira_compression`'s, in the formats family).

A side finding for review: `PgConfig` defaults `require_tls = True` and
`verify_cert = False` (`src/komira_db_postgres/wire/connection.mojo`), so by
default the connection is encrypted but the server is not authenticated. A
real-server test should pin both settings.

## Formats, engine, runtime and core utilities

Packages:

- the formats: `komira_parquet`, `komira_parquet_api`,
  `komira_parquet_codec`, `komira_arrow`, `komira_arrow_ipc`, `komira_avro`,
  `komira_orc`, `komira_csv`, `komira_json_index`, `komira_jsonl`,
  `komira_compression`, `komira_lz4`, `komira_zlib` (`komira_json`, a JSON
  reader and writer, is released and listed with the core utilities below);
- the engine: `komira_plan_expr`, `komira_plan_ir`, `komira_plan_proto`,
  `komira_plan_stats`, `komira_plan_wire`, `komira_pplan_wire`, `komira_sql`,
  `komira_optimizer`, `komira_eval`, `komira_expr`, `komira_agg`,
  `komira_agg_api`, `komira_op_agg_row_api`, `komira_op_agg_state`,
  `komira_kernels`, `komira_column_kernels`, `komira_column_format`,
  `komira_row_format`, `komira_rowcell`, `komira_morsel`,
  `komira_exec_types`, `komira_scan_planning`, `komira_scan_resolver`,
  `komira_scan_source`, `komira_shuffle`, `komira_shuffle_streaming`,
  `komira_dispatch_agg_exec`, `komira_dispatch_agg_folds`,
  `komira_dispatch_join_kernels`, `komira_dispatch_scan`,
  `komira_join_assembly`, `komira_dynamic_filter`;
- the runtime: `komira_async`, `komira_async_api`, `komira_fs`,
  `komira_log`, `komira_metrics`, `komira_metrics_reader`, `komira_trace`,
  `komira_sync`, `komira_spsc_ring`;
- the core utilities: the released ones listed below, and the unreleased
  `komira_collections`, `komira_buffer` and `komira_libc` (next paragraph);
- the protobuf, textproto and XML codecs (`komira_protobuf`,
  `komira_textproto`, `komira_wkt`, `komira_proto_codec`, `komira_xml`);
- the test-support libraries (`komira_validation_run`, `komira_test_run_id`,
  `komira_test_verdict`).

Released (`release/artifacts.textproto`), apart from the ten kci libraries
and `komira_kafka_server`: the codecs `komira_protobuf`, `komira_textproto`,
`komira_wkt`, `komira_proto_codec` and `komira_xml`; the core utilities
`komira_encoding`, `komira_json`, `komira_retry`, `komira_datetime`,
`komira_hash`, `komira_atomic_alias`, `komira_anomaly`, `komira_clock`,
`komira_counters`, `komira_fork_join`, `komira_host`,
`komira_job_report_proto`, `komira_name_registry`, `komira_parquet_api`,
`komira_runtime_paths`, `komira_resources`, `komira_scalar_arithmetic` and
`komira_simd`; and the three test-support libraries. Two of these read and
write a format: `komira_json` (JSON) and `komira_parquet_api`. No other
format reader or writer, no engine package and no runtime package is
released.

**Declared by open pull requests.** At the time of writing, #755 and #761
would add `komira_collections`, `komira_buffer`, `komira_libc` (FFI to
libc), the proto packages `komira_broker_proto`, `komira_supervisor_proto`
and `komira_plan_proto`, the runtime interface `komira_async_api`, the
engine package `komira_dynamic_filter`, and `komira_native`, a new package
kind (one shared library, not a Mojo library). Every one of these except
`komira_native` is checked only by the "every released library" row below
(README examples in `install-set`); no family-specific row is proposed for
them. The same holds for the packages in no family list of this document
(`komira_sdk`, `komira_udf`, `komira_table_store`, `komira_viewport`,
`komira_authz_api`, `komira_uuid`) if they are released. `komira_native`
has its own row.

This family needs no service, no secret and no cloud. The questions here are
about the installed package itself.

| packages | what runs | where it runs | what it catches | what it misses |
|---|---|---|---|---|
| the formats and codecs | EXISTS: pinned upstream corpora (`third_party/arrow-testing`, `apache-avro`, `parquet-format`, `jsontestsuite`, `snappy`, `pierrec-lz4`, `zlib`, `brotli`); pyarrow-written Parquet and Arrow IPC fixtures with their generator scripts; foreign ORC and Avro files in `komira_formats_e2e`; `komira_json_conformance`; the Arrow C Data Interface probe (`src/komira_arrow_ipc/BUCK`, `arrow_c_abi_probe`) | in-process, build time | codec and format correctness and regressions, reading what other implementations wrote | the write direction: every cross-implementation fixture is foreign-writer, komira-reader |
| `komira_protobuf`, `komira_textproto`, `komira_wkt`, `komira_proto_codec`, `komira_xml` (released) | EXISTS: `komira_protobuf` decodes wire goldens generated once by prost 0.13 (`test_protobuf_prost_crosscheck`); `komira_proto_codec` byte-diffs its proto3-JSON output against hand-checked reference strings, one per mapping rule (`test_proto_codec_proto3_json_conformance`); `komira_xml` checks rows that each cite an XML 1.0 or Namespaces rule (`test_xml_strict`); round trips; README examples in `install-set` | in-process, build time; gamma for the README | wire-level decode compatibility with one independent encoder; mapping-rule regressions; well-formedness refusals | no upstream conformance corpus is pinned for any of them (not protobuf's conformance suite, not the W3C XML test suite), so each oracle is prost's output once or our reading of the spec; the encode direction against an independent decoder. PROPOSED: pin the protobuf conformance runner's test list and run the binary and proto3-JSON cases at build time |
| `komira_validation_run`, `komira_test_run_id`, `komira_test_verdict` (released test support) | EXISTS: welded tests; README examples in `install-set` | in-process, build time; gamma for the README | label legality, id format, verdict parsing as their tests state them | nothing beyond the strings: they are used by tests and kci, not against a service |
| every released library | EXISTS: `install-set` README examples | gamma, installed package | layout and metadata errors, closure errors, README drift, a metapackage whose members drift from the release set | anything a README does not touch |
| `komira_native` (declared by open PR #761) | EXISTS at build time on the native stack's branches (from #681 up; #763 carries it): `tools/build/native/native_check.sh` fails the build unless every exported symbol of the built `libkomira_native.so.1` starts with `komira_` and the exports are exactly the generated list, NEEDED is only glibc's libraries, there is no run path, and it was linked `-Bsymbolic`. PROPOSED, with no mechanism today: (a) the same checks, plus its highest `GLIBC_` symbol version against the declared `__glibc` floor, run on the `.so` installed from the channel; (b) loading it with `dlopen` together with a second libcrypto (OpenSSL) and one call through each side. Neither runs today: `CONDA_INSTALL_ENV`'s only `smoke` word runs README examples, which cannot read a symbol table; a `CONDA_INSTALL_SMOKE` program could, but needs `komira_native` installable as a release member (`kci_validate` carries the native kind only from #704 up), an ELF dynamic-symbol reader in Mojo (none in `src/`), a digest-pinned image with pixi, and an entry in the `validate` job's `--only` list. (a) is item 8 of [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma); (b) also needs item 3, because OpenSSL is not a release member and `install` names members only | build time (EXISTS on the branches); gamma, installed package (PROPOSED) | an unprefixed aws-lc, s2n or snappy symbol that would clash with another libcrypto in the same process (the reason for #672); a packaging step that ships a different `.so` from the checked one; a glibc requirement above the floor | symbol interposition by a library loaded later in a real application; other platforms |
| libraries requiring `komira_native` | PROPOSED, in flight: the README run gains `-Xlinker -L<env>/lib -Xlinker -lkomira_native`, with link names taken from the native package's `lib/lib<x>.so` rows (`src/kci_validate` on #763, the top of the native stack; on `main` and on #761 the README run passes no link flag) | gamma, installed package | a library that stopped requiring `komira_native`; a malformed link name; the glibc floor | per-library static archives (next row) |
| `komira_log` and every library above it | PROPOSED: a build-mode README check (item 4 of [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)): `mojo build` with run path `$ORIGIN/../lib` and `-l` for each per-library `.a` row of each installed package, then run the binary. On the native stack's branches (from #685 up), `komira_log`'s package ships `lib/libkomira_log_holder.a`, and `tools/build/native/README.md` (from #685 up) states that `mojo run` does not link a static archive | gamma, installed package | a per-library archive missing from its package or misnamed; a run-path or NEEDED mistake only a built binary shows | interop; it costs a full compile per README |
| `komira_compression`, `komira_lz4`, `komira_zlib` and the formats above them | PROPOSED, on an existing kind: a `CONDA_INSTALL_SMOKE` validation on gamma's PUBLISH step installing `komira_compression`, whose `program` (a `.mojo` file under `release/`) compresses and decompresses one frame per codec, then reads `/proc/self/maps` and fails unless each loaded codec library lies under the installed environment's `lib/` (`.pixi/envs/default` under `/work`, `src/kci_validate/container.mojo`). Whether a bare-soname `dlopen` (`OwnedDLHandle(soname)` in `src/komira_compression/codec_libraries.mojo`) under `mojo run` finds the environment's `lib/` at all depends on the calling object's run path or the loader's search path reaching it, which nothing has measured: a probe must show it first, or the check fails on every run (or, with the image's copies, proves nothing). It cannot run today: `komira_compression` is not released (its README has no ` ```mojo ` block, which `install-set` would refuse); no image is pinned for the kind; and the `validate` job's `--only` list must name it (rule R9, item 7 of [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)), with its 900 s pull and 2700 s run inside that job's hour or in a part job of its own | gamma, installed package | a wrong or missing conda-forge requirement: the codecs are opened by bare soname at first use (`src/komira_compression/codec_libraries.mojo`), and the runner image ships its own copies, so today such a requirement would pass gamma | codec correctness (build time) |
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
(EXISTS). The other kci packages (`kci_artifact`, `kci_artifact_proto`,
`kci_build`, `kci_cli`, `kci_cloud`, `kci_cloud_fake`,
`kci_deploy_model_proto`, `kci_manifest_proto`, `kci_pkg_upload`,
`kci_publish`, `kci_publish_oci`, `kci_reconciler`, `kci_release_set`,
`kci_secret_writer`, `kci_validate`) are not released and are checked at
build time only. The deploy side is checked at build time against
`kci_cloud_fake`, the in-memory clouds that model kci's resource model
(EXISTS). Neither
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
  have to live in a GitHub environment on a new job. And an outside
  contributor could not reproduce the run without an account of their own.
  (A fork's pull request sees neither kind: it gets no check at all,
  [ci.md](../ci.md#pull-requests-from-forks).)
- **A real cloud project is reached by OIDC federation only.** No stored
  key: kci never holds standing access. That needs, first:
  `external_account` credentials in `komira_gcp_core` (refused by name
  today, `src/komira_gcp_core/adc.mojo`) and a federated credential in
  `komira_azure_core` (none exists). On AWS, a role assumed with the
  workflow's identity token.
- **No path exists today for a credential or a run id to reach the program
  under test.** A `CONDA_INSTALL_SMOKE` container gets four fixed `-e`
  variables and a CI job's token-request variables and secrets never reach
  it (`src/kci_validate/container.mojo`, lines 40 to 44); a
  `CONDA_INSTALL_ENV` program runs in an environment built from nothing
  (`src/kci_validate/env.mojo`, lines 28 to 37). A real-cloud validation
  must relax one of these on purpose: kci, in the job that holds the
  identity token, exchanges it for a short-lived credential scoped to the
  gamma project and writes it, with the validation run id, to files under
  `/work` (configuration is a file, not an environment variable). The
  program then holds a live cloud credential, which is exactly what those
  lines rule out today; item 5 of
  [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)
  carries this, and whether each client's credential chain can read such a
  file without an environment variable is part of that item.
- **The trust is created by a bootstrap, per cloud** (PROPOSED; no such verb
  exists). A human admin runs it once with their own credentials, and it
  creates exactly one trust whose subject is GitHub's environment-restricted
  `sub` claim (`repo:<owner>/<repo>:environment:<env>`), so only a job in
  that GitHub environment can use it:
  - AWS: an IAM OIDC provider for GitHub's issuer and one role whose trust
    policy requires that `sub` and `aud`, with a permissions policy limited
    to the gamma account's run-scoped resources.
  - GCP: a Workload Identity Federation pool and provider with an attribute
    condition on that `sub`, and one service account the pool's principal may
    impersonate, with roles on the gamma project only.
  - Azure: a federated identity credential on one app registration, issuer
    GitHub, subject that `sub`, with a role assignment scoped to the gamma
    resource group.
  Teardown is the same verb's delete: it removes the trust (role, pool and
  provider, federated credential) and nothing else, after the sweeper has
  emptied the run-scoped resources.
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
  run (EXISTS for S3 in the opt-in MinIO tests;
  `src/komira_job_supervisor/BUCK` describes it). For a real project, a
  scheduled sweeper that deletes only resources carrying an old validation
  run id, as a `kci-run-id` label or as a run-scoped name prefix
  (PROPOSED). The sweeper finds only what is marked: a resource the program
  under test creates through `komira_aws_*`, `komira_gcp_*` or
  `komira_azure_*` is not stamped by kci (next section), so the program
  must stamp it itself, or the resource leaks and keeps billing.

### Validation run id stamping

`komira_validation_run` defines the label `kci-run-id`, legal as both an AWS
tag and a GCP label, and `kci_cloud` writes it on resources created in a
scope that carries a validation run id (EXISTS:
`src/komira_validation_run/validation_run_tag.mojo`,
`src/kci_cloud/adapter.mojo`). **No kci verb sets a scope's validation run id
yet**, so nothing real is stamped. And `kci_cloud` stamps only the objects
`kci_cloud` itself creates: a resource that a validation program creates
through a cloud client library carries no `kci-run-id` unless the program
reads the run id (from the `/work` file item 5 proposes) and writes the
label, or names the resource under a run-scoped prefix. Some resources take
no labels (IAM service accounts), so the id must also be encodable in a
resource's name or description, and the sweeper must know which form each
type uses. The
validation run id is not `komira_test_run_id`, which names one test process.

### Time budget

- `validate` job: 60 minutes for both validations together, each of which
  may wait up to `wait_for_index_seconds` (1800 by default, 3600 at most,
  `src/kci_release_machine/graph.mojo`) for the channel index. Measured: in
  five consecutive successful `kci.yml` runs on `main` on 2026-10-07 (run
  37688200088 the latest), the whole `validate` job took 151 to 208 s
  (GitHub's `startedAt` to `completedAt` for the job: checkout, the release
  artifact's download, pixi, both validations with their index waits,
  installs and README runs over the 37 libraries, and the hand-off steps).
  In run 37688200088 the one `kci run --stage gamma --only ...` step took
  181 s of the job's 192 s; the waits, installs and README runs are all
  inside that one step, so they are not timed apart.
- `CONDA_INSTALL_SMOKE`: 900 s to pull, 2700 s to run
  (`src/kci_validate/container.mojo`).
- Build-time tests run under the remote action limit (the Connect
  conformance run budgets 420 s of it).
- The wait ends as soon as the index lists every pinned file
  (`src/kci_validate/channel_index.mojo`), so in a normal run the second
  validation's wait is near zero. In the worst case it is not: if the index
  lists the first validation's files just inside its 1800 s, or lists
  `komira_encoding`'s files but not the rest of the set, the second
  validation can wait up to another 1800 s. The two waits alone then fill
  the job's 60 minutes, and GitHub cancels the job before kci reports a
  verdict. This is a gap;
  [Open decision 11](gamma_validation_decisions.md#open-decisions-for-the-project-owner)
  proposes a fix.
- A build-time service (the Java Firestore emulator, moto, PostgreSQL's
  initdb) must start, run its cases and stop inside one remote action. Each
  proposal above needs a measured start-up time and a per-action budget, as
  the Connect conformance run has, before it is welded.
- A service validation in gamma therefore needs its own job and timeout; it
  must not share the `validate` job's hour. Inside `kci.yml` that job is a
  part job of gamma under rule R9 of `src/kci_workflow_check/rules.mojo`: no
  environment, no identity token, and prod needs it (R2, R4, R3). A job
  that needs an environment or a token, or must not block prod, collides
  with those rules; item 7 of
  [What kci must add](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma)
  lists the amendments.

## Gaps

- No AWS, GCP, Azure, HTTP, gRPC, TLS, database or object-store library is
  released, so gamma validates none of them today. Every row for them above
  that says "gamma" is PROPOSED.
- Libraries without a README cannot be released: `komira_objectstore`,
  `komira_objectstore_s3`, `komira_job_supervisor`, `komira_supervisor`,
  the eight runtime packages, most GCP clients (open PR #757 adds eight),
  and most kci libraries; `komira_secret_env` and `komira_compression` have
  a README with no ` ```mojo ` block, which
  `src/kci_validate/readme_installed.mojo` refuses in the same way.
- No validation kind can start a service, and the network check declares only
  channel hosts.
- Service tests never run against installed bytes: a defect that appears only
  in the conda layout is caught only if a README example touches it.
- Only AWS Secrets Manager and Azure Blob have an over-the-socket test
  against a fake that recomputes the request's signature. GCP Secret
  Manager's TLS fake compares the bearer token with its own and answers 401
  to a missing, empty or other token, but a bearer token carries no
  signature to recompute, so nothing checks a token as Google would. The
  other AWS clients are checked only against recorded bytes and canned
  responses.
- `komira_db_postgres` has never run against a real PostgreSQL.
- There is no shared contract suite for `ConditionalWriteStore`.
- The MinIO tests are opt-in and run by no gate; the MinIO pin is frozen
  upstream.
- Connect conformance requires 16 of 236 cases; the `komira_grpc` client is
  never run against an independent server.
- Write-direction format interop is untested anywhere.
- Codec origin is untested: a wrong conda-forge codec requirement passes on
  the runner's own system libraries.
- A README example of any library that links `komira_log` (none is released
  or has a README yet) could not pass gamma's current `mojo run` check, while
  the same example as a welded test would pass, because the build links the
  per-library archive. This is a fact of the native stack's branches, not
  of `main`: `lib/libkomira_log_holder.a` (from #685 up) and the line of
  `tools/build/native/README.md` stating that `mojo run` does not link a
  static archive (also from #685 up) exist only there.
- Nothing checks the installed `komira_native` library: its export check
  runs on the built `.so` at build time (on the native stack's branches),
  not on what the channel serves, and nothing loads it beside a second
  libcrypto. No validation kind can do either today (item 8 of the kci
  work).
- Lambda Invoke cannot be validated end to end by moto without a Docker
  socket; ECS run-task and Scheduler firing cannot be validated end to end by
  moto at all (it starts no task container and fires no target).
- Release builds do not re-run standalone checks: the `build` stage builds
  only the released libraries and their welded tests, so `src/tests/e2e`,
  `src/tests/conformance`, `komira_secrets_e2e`, `komira_azure_blob_e2e`,
  `broker_e2e` and unreleased packages' tests run only on the pull requests
  whose changes reach them, never on the release revision as a whole.
- Presigned URLs (S3 and GCS) are checked only against signing vectors; no
  test transfers bytes through one.
- The protobuf, textproto and XML codecs are released with no pinned
  upstream conformance corpus.
- Only linux x86_64 is validated; the h2spec and Connect conformance pins are
  linux x86_64 only.
- [release machines](release_machine.md) lists the fields of
  `CONDA_INSTALL_SMOKE` in its table and describes `CONDA_INSTALL_ENV` only in
  prose, although gamma uses only the latter.

## What is decided elsewhere?

What kci must add to run service validations in gamma, and the open
decisions for the project owner, are in
[gamma validation: kci work and open decisions](gamma_validation_decisions.md).
