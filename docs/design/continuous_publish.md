# Continuous publish: every package built, published to gamma, tested there, promoted to prod

Status: design, not built. Everything marked **EXISTS** names the code that does it on `main`;
everything marked **PROPOSED** has no code yet. It builds on
[gamma validation](gamma_validation.md) and its
[decisions](gamma_validation_decisions.md), which say what checks each package family before prod,
and on [ci.md](../ci.md), the authority for the workflows. Related: #371, #779, #835, #929, #1136,
#1138, #1140, #1153.

## What is it for, and what is out of scope?

The goal: every komira library is built, published to the conda channel `gamma`, tested there, and
promoted to `prod`, on every change to `main`, with no human click per release. That includes the
cloud SDK packages, which are tested **without spending money on a cloud**. They are tested against
in-memory fakes (`kci_cloud_fake`), against emulators that run as local processes, and against
recorded responses where no emulator exists.

This document covers:

1. how a release runs today and what is missing (with evidence);
2. the target pipeline: the trigger, what "continuous" means at the CI's throughput, the gate between
   gamma and prod, rollback and yank;
3. what stands between "the declared set" and "every package";
4. the emulator test tier: where it runs, how emulators start and stop, one harness for all generated
   clients, the mapping from package to emulator, and recorded-response tests for the rest;
5. the safety rules: no cloud spend, no credentials, no route to a real endpoint;
6. the rollout as slices that can each be merged on their own;
7. the questions for the project owner.

Out of scope:

- **Real cloud accounts in gamma.** These are decision 4 of
  [gamma validation decisions](gamma_validation_decisions.md#open-decisions-for-the-project-owner).
  This design spends nothing and holds no cloud credential.
- **The native package format.** That is #835. This document depends on it but does not decide it.
- **Other platforms** (linux-aarch64, macOS) and Python wheels.
- **DEPLOY.** See [the DEPLOY step](deploy_step.md).

## How does a release run today? (EXISTS)

**Promotion is already continuous.** A push to `main` that touches more than documentation runs
`.github/workflows/kci.yml` as four jobs:

1. `build` runs on the build farm.
2. `gamma` publishes to the `gamma` channel.
3. `validate` installs what `gamma` published and runs the README examples.
4. `prod` publishes the same release set to `prod`.

`prod` runs automatically when `validate` succeeds. It publishes exactly the set `validate` installed,
using the `validated_set_hash` that `validate` hands it (the `kci.yml` header, "CONTINUOUS
AUTO-PROMOTION"; `release/machine.textproto`). It never publishes a lower build number, or a revision
off `main`'s history (`KCI-E-SUPERSEDED`, [ci.md](../ci.md)). Releases run one at a time, in the
concurrency group `kci-release-main`. A newer push replaces the pending run, so pushes made during a
release coalesce into the next one. To pause promotion, add a required reviewer to the `prod`
environment ([ci.md](../ci.md#pausing-promotion-to-prod)).

| piece | today | evidence |
|---|---|---|
| trigger | a push to `main` (not `docs/**` or `**.md` only), or a manual run with a `reason` | `kci.yml` `on:` |
| gate before prod | two `CONDA_INSTALL_ENV` validations: `install-komira-encoding` and `install-set`. Each runs a fresh pixi install from `gamma`, checks the README sha256 and runs every ` ```mojo ` README block. | `release/machine.textproto`; [gamma validation](gamma_validation.md#what-runs-in-gamma-today-exists) |
| what is released | the libraries in `release/artifacts.textproto` (41 libraries plus `komira_all`: 42 `artifacts {` blocks) | `grep -c '^artifacts {'` |
| what is not released | about 160 of the roughly 200 libraries under `src/` | see [What blocks every package?](#what-blocks-every-package) |
| cloud SDK tests | welded unit tests with `ScriptedConnector`, `AwsEchoConnector`, in-memory fakes and loopback fakes on `komira_http_server`. No emulator anywhere. | [gamma validation](gamma_validation.md#aws), §AWS, §GCP, §Azure |
| a release on the release revision | builds `<lib>_conda[release]` and those libraries' welded tests. It runs no standalone e2e, conformance or service test. | [gamma validation](gamma_validation.md#where-can-a-check-run); decision item 6 |
| a failed validate | prod does not start (no `always()`). The gamma bytes stay in `gamma`. | `kci.yml`, job `prod` |
| rollback | "a revert on `main`, released forward as the next build number". There is no yank path. | [ci.md](../ci.md) |

**Measured run time.** These are the last ten releases that ran to the end, all of them after the
switch to auto-promotion, read from the GitHub jobs API:

| part | range | median |
|---|---|---|
| push to prod done | 13.5 to 85 min | about 31 min |
| waiting behind the previous release | 0 to 29 min | |
| `build` | 4.3 to 54 min | about 8 min |
| `gamma` + `validate` + `prod` | 8 to 12 min on every run | |

The slow `build` runs are the ones in which kci's own code changed. The step "build kci" took 16 to
50 s when it was cached, and 650 to 2509 s when kci's code had changed (#1153). Of the last 200 runs on
`main`, 162 were pending runs that a newer push replaced. So coalescing already does the batching.

**Where the settings and the docs disagree** (live repository settings, read through the GitHub API):

| the docs say | the settings say |
|---|---|
| `gamma` deploys from `main` only (`kci.yml` header, BREAK-GLASS) | `gamma` has **no** deployment-branch policy |
| `gamma-breakglass` has a required reviewer | `gamma-breakglass` **does not exist** |
| `prod` deploys from `main` only | holds: its policy is `main` |

The `kci.yml` header admits it: "until those settings exist, a branch's own workflow can still publish
to gamma". Prod is locked; gamma is not. Slice S0 closes this.

**Stale docs.** `docs/releases.md` still says that the repository "does not yet contain the step that
uploads", and it lists upload and channels as "Held". `gamma_validation.md` says 37 libraries and 16
AWS clients. Main has 41 libraries and 17 `mojo_aws_client` calls (`komira_aws_ses` is missing from
the doc), as tracked in #779. Slice S1 fixes `releases.md`.

## The target pipeline

### Trigger: per merge, coalesced

**PROPOSED: keep the trigger as it is.** Every push to `main` is a release, and pushes made during a
release coalesce into the next one. That *is* the per-batch trigger. The batch is whatever landed while
the previous release ran, so there is no clock to tune and no second trigger to keep in step with the
first. A scheduled batch trigger (nightly, for example) would only add delay: a release that changed
nothing is a NOOP that exits 0 (build numbers count first-parent commits, not runs).

"Continuous" therefore means **every push to `main` that touches code reaches `prod` within one release
duration, or within two if it lands during a release, or it fails loudly**. At today's numbers that is
15 to 70 minutes. Two things keep it there as the released set grows:

- **kci built once per revision of `main`, not once per job** (#1153's first direction). A cold kci
  build can by itself use most of `build`'s 120 minutes.
- **The release `build` step split into batches,** each under `--build-timeout-s`. A change under
  `tools/build/package/` or in a core library re-keys every package. #1153 measured 299 units in one
  batch, which overran the 60-minute batch limit. The step should build the released targets in
  fixed-size batches in dependency order, so that a cold full release takes several batches rather
  than one oversized one. The first such release is slow, and the queue coalesces behind it.

### The gate between gamma and prod: results, not clicks

**EXISTS:** prod publishes only the set that `validate` vouched for. **PROPOSED:** the gate gets two
more inputs. Both of them must pass before `gamma` publishes, so neither one needs a new job, and
neither one changes what `prod` trusts:

1. **The release checks** (slice S10). This is a list of Buck2 test targets,
   `release/checks.textproto`, that the release's `build` step builds on the release revision. A
   failure fails `build`, so nothing reaches `gamma`. It holds the emulator tier, the recorded-response
   tier and the standalone e2e and conformance suites that reach released libraries. It is decision
   item 6 of [gamma validation decisions](gamma_validation_decisions.md#what-kci-must-add-to-run-service-validations-in-gamma),
   cut down to a sized list instead of "every derived check". These tests run on the source build. The
   conda payload is that same gated `.mojoc` (`tools/build/package/conda.bzl`), so they test the bytes
   that are published. The installed-path differences (linking, loading, the README against the
   install) are what `validate` covers.
2. **The installed-bytes cloud smoke** (slice S12, only after #835). This is one emulator round trip
   per cloud family, run against the *installed* package in `validate`. It catches the defect class
   the build cannot catch: a native library in the conda package that fails to load or link from the
   install. It needs decision 1 of the gamma validation decisions (a `service` block).

A human enters only to pause, by adding a reviewer to `prod`, or for break-glass. Neither one is part
of the normal path.

### Rollback and yank

**Rollback stays "forward"** (EXISTS). A revert on `main` is released as the next build number. A
consumer that solves for the latest version gets the revert. A consumer pinned to the bad build keeps
it. The revert passes the same pull-request check and the same release, so the time to roll back is
one PR check plus one release duration. The rule "Fix forward or revert within the hour" ([ci.md](../ci.md))
already covers it.

**Yank** (PROPOSED, slice S11, and **every use needs the project owner's go**). A yank is for a
published build that is unsafe for anyone to keep solving to: a security defect, or corrupt bytes.

- **What a yank does.** It removes the file from `prod` (and from `gamma`), so that no new solve
  selects it. The file name is never reused: kci already never overwrites a name and version.
- **What a yank never does.** It never removes anything from a consumer's lockfile, and it never
  publishes anything.
- **Why yank cannot be automatic.** It deletes from a public channel.
- **What has to be confirmed first.** Whether the channel host supports deleting a single package
  file, or marking it removed in the repodata, is **not verified**. It is the first task of S11.
- **Form.** A `kci yank --channel prod --file <name>` verb with a dry run by default. If the host
  cannot delete a file, a yank is a forward release whose build is higher than the bad one, which is
  rollback.

## What blocks every package?

A library is published only if `release/artifacts.textproto` declares it. The build refuses a conda
package for a library in any of these cases:

- it links native code, directly or through a dependency (`tools/build/mojo/defs.bzl`);
- it has no tests;
- it depends on a library that is refused.

The packer refuses a library that uses `OwnedDLHandle` (`tools/build/package/pack/conda.zig`). Gamma
refuses a library that has no README, or a README with no runnable example
(`src/kci_validate/readme_installed.mojo`).

The table below is from a static parse of every library's `BUCK` file at the time of writing, not
from `cquery`. As a cross-check, all 41 declared libraries came out buildable.

| reason a library is not released | count | unblocked by |
|---|---|---|
| links native code directly (async, crypto, http_core, libc, log, fs and others) | 17 | the native package format, #835 |
| links native code through a dependency (most often through `komira_async` or `komira_libc`) | 122 | #835 |
| opens a library at run time (`komira_lz4`, `komira_zlib`) | 2 | #835 (system codecs by soname) |
| no README (`kci_artifact_proto`, `kci_deploy_model_proto`, `kci_manifest_proto`) | 3 | #1138 |
| buildable, declared by an open PR | 14 | #1136 |
| depends on a library that is not declared yet | 4 | the PRs above, then a declare PR |

**Every cloud SDK package is in the native rows.** They all reach `komira_http_core`, `komira_crypto`
or `komira_async`. So no cloud package can be published to `gamma`, or be tested there as installed
bytes, before #835 is decided and built. What can ship before it:

- **The 21 non-native libraries** in the last three rows: through #1136, #1138 and three small declare
  PRs (slice S2).
- **The emulator and recorded-response tiers, run at build time on the release revision** (S4 to S10).
  They test the same source the package will carry, so on the day #835 lands, the cloud packages
  arrive already gated.

**PROPOSED, slice S1: the release ledger.** "Every package" has to be a number the build checks, not a
count in a document. `release/unreleased.textproto` lists every library that is not declared, with a
reason from a closed set: `NATIVE`, `DLOPEN`, `NO_README`, `UNDECLARED_DEP`, `TEST_SUPPORT`, or
`PENDING_DECLARE` with the PR number. A welded test of `kci_release_set` checks three things:

- every library directory is in exactly one of the two files;
- a reason that the build can compute agrees with the build (each library exposes a `[conda_status]`
  sub-target, derived from the refusals `defs.bzl` already makes);
- the ledger only shrinks for the computed reasons.

A new library that nobody declares or lists turns the build red. The day #835 lands, the `NATIVE`
rows become declare work, and the ledger says how much of it remains.

## The emulator test tier

### Where it runs: on the farm, as pinned processes

| option | for | against | verdict |
|---|---|---|---|
| GitHub-hosted runner, `services:` containers | Docker is there. Contributors can reproduce the run with Docker. | It is not the farm: no cache, and it is a new job. Under rules R2, R3, R4 and R9 of `kci_workflow_check` it blocks prod and needs an amendment (decision item 7). A second test runner would duplicate Buck2's. | only for the installed-bytes smoke (S12) |
| farm, container per test | the image is the upstream artifact | Docker inside a farm action is not a probed capability. Privileged Docker-in-Docker was rejected for the earlier LocalStack-on-farm proposal (a container escape gives node root). | no |
| **farm, pinned process per test** | The pattern **EXISTS** (`komira_test_minio`: a sha256-pinned binary on a random loopback port, under `setpriv --pdeathsig`), and the [farm capability probe](../ci.md#what-a-farm-test-action-can-do) checks every capability it needs. The tests are ordinary Buck2 tests: cached, affected-set aware, runnable by anyone with `./buck2 test`. | Emulators that are Python, Java or Node need a pinned runtime | **yes** |

**PROPOSED:** the emulator tier is made of standalone Buck2 test targets under
`src/tests/emulator/<family>/`. Each one starts its emulator as a pinned process inside the test
action. They run in three places:

- in the pull-request check when they are affected (`release/ci/derive_checks.py` derives them like any
  other standalone check);
- on every release revision, through `release/checks.textproto` (S10);
- on a developer's machine with the same command.

The earlier LocalStack-on-farm proposal needed local, uncached compiles, because its test held a
LocalStack auth token, and the farm's action cache cannot be trusted with a secret. The emulator tier
holds no secret (see [the safety rules](#the-safety-rules)), so it has the same trust as every welded
test, and the cache is fine.

### How a test starts and stops an emulator

**PROPOSED: one harness library, `src/tests/helpers/komira_test_emulator`.** It generalizes
`komira_test_minio`'s process code. Every emulator test does the same five things:

1. **Start.** The harness runs the pinned emulator under `setpriv --pdeathsig KILL` (so the emulator
   dies with the test, which the probe's `pdeathsig` row proves). The emulator binds `127.0.0.1` on a
   port picked by binding port 0, and gets a state directory under `TEST_TMPDIR`. Its command line
   comes from a per-emulator descriptor: the runtime, the entry point, the arguments, the readiness
   probe and the start-up budget.
2. **Ready.** The harness polls the emulator's readiness route until a budget runs out. Running out of
   budget fails the test, and the failure names the emulator and the elapsed time. Each budget is
   measured, written in the descriptor, and kept well under the 600 s test-action timeout.
3. **Hand over.** The test receives an `EmulatorEndpoint`: a loopback IPv4 address and port, a
   `LoopbackOnlyConnector` (see the safety rules), and a static credential. For AWS that is
   `StaticCredsSource` with a fixed dummy key pair. For GCP it is `StaticTokenSource` with the
   emulator bearer. For Azure it is Azurite's published development key.
4. **Run.** The test runs the package's round-trip table.
5. **Stop.** The harness sends SIGTERM, waits, sends SIGKILL, and reaps the process (the probe's
   `child_reap` row). Before the test ends, it asserts that no child process survives.

**Emulators as build inputs, pinned by sha256.** No test downloads anything. Each runtime and each
emulator is an action input:

| emulator | form | runtime |
|---|---|---|
| moto server | pinned wheels through the hermetic Python (`tools/build/python`: `python_dist`, `python_wheel`) | CPython from `third_party/python` |
| storage-testbench | pinned wheels, the same way | the same |
| Firestore emulator | the emulator jar, pinned by sha256 | a pinned JRE 21 archive |
| Azurite | decided by a probe in S8: a pinned Node archive plus Azurite's lockfile-pinned package set, or a container once a farm capability row proves one | Node |

### One harness for every generated client

Every generated client is generic over `Connector` and takes its endpoint and credentials as plain
values (`tools/build/cloud/aws.bzl`, `gcp.bzl`). The generated `_no_env_reads` test forbids reading
the environment. The harness therefore gives every client the same three values, and each package
supplies only a table:

```text
# one row per operation group: the call, the state it needs, what to assert
round_trip("sqs", create = "CreateQueue", act = "SendMessage", read = "ReceiveMessage",
           cleanup = "DeleteQueue", expect = "the body sent is the body received")
```

- **AWS client mode** (15 packages, all with the same four test files): the client is built as
  `<Svc>Client[LoopbackOnlyConnector[KernelTcpConnector], StaticCredsSource]` with
  `<Svc>EndpointConfig.endpoint` set to the emulator.
- **AWS pure mode** (`komira_aws_dynamodb`, `komira_aws_logs`): a small shim that signs with
  `build_sigv4_signed_request` and sends.
- **GCP:** `set_rest_host` for REST, and `komira_grpc`'s `GrpcClient` with the bearer hook for
  Firestore's listen client and for storage v2.

The table is hand-written per package, starting with create, read, list with pagination, delete, and
one error case. Generating it from the service model can come later, when the tables show a shape
worth generating.

### Which emulator covers which package

| package | emulator | notes |
|---|---|---|
| `komira_aws_core` (STS credential chain), and the generated clients for s3, sqs, sns, dynamodb, dynamodbstreams, iam, ec2, ecr, ecs, lambda, logs, route53, scheduler, secretsmanager, ses, sesv2, apigatewayv2; `komira_aws_metrics` (CloudWatch); `komira_objectstore_s3` | **moto** server (Apache-2.0, no token) | moto's Lambda Invoke needs Docker: covered for create, list and delete only. ECS `RunTask` and Scheduler firing are recorded, not executed. Signature checking: only once a corrupted-signature mutant turns a run red with moto's authentication on; otherwise the tier does not claim it. |
| `komira_gcp_firestore`, `komira_gcp_firestore_db` | Google's **Firestore emulator** | the client already speaks the emulator's plaintext endpoint and bearer (`FIRESTORE_EMULATOR_BEARER`) |
| `komira_gcp_storage`, `komira_objectstore_gcs` | **storage-testbench** (Apache-2.0; gRPC `google.storage.v2`, fault injection) | not fake-gcs-server, which serves the v1 gRPC proto ([gamma validation](gamma_validation.md#gcp)) |
| `komira_azure_blob` | **Azurite** (MIT), blob service | `AzureConfig.azurite` exists. Azurite does not support soft delete, versions, blob query or incremental copy. |
| `kci_cloud`, `kci_reconciler` | **`kci_cloud_fake`** (EXISTS, in-memory, with a faulty variant) | no kci library reaches a cloud client yet. When a real adapter lands (#1108 for GCP), its emulator test joins this tier. |
| Pub/Sub, Bigtable, Spanner, Datastore; Azure queue and table; Cosmos DB | none: **komira has no client for them** | each emulator is adopted in the PR that adds its client, with the same harness |

LocalStack is not proposed. Its current images need an auth token to start; the free plan is for
non-commercial use; ECR and ECS need a paid plan. A token is a secret, and that would break both the
"no credentials" rule below and outside reproducibility
([decision 2](gamma_validation_decisions.md#open-decisions-for-the-project-owner)).

### Recorded-response tests for the rest

No emulator exists for:

- the GCP management clients (apigateway, artifactregistry, cloudresourcemanager, cloudscheduler,
  compute, iam, logging, monitoring, monitoring_client, run, secretmanager, serviceusage, wif);
- `komira_gcp_core`'s token and ADC paths;
- `komira_gcp_fcm`;
- `komira_azure_core`'s Entra and IMDS paths;
- `komira_aws_lambda_http`, which is the Lambda runtime side and has no API to emulate.

These packages are tested with recorded responses replayed through `ScriptedConnector`. **No response
is recorded from a live cloud.** Recording from a live cloud needs a credential and an account, which
this design does not have. Every fixture comes from one of three sources:

| source | how | example |
|---|---|---|
| the pinned service model | a generator walks the pinned discovery document or botocore model and writes one maximal response per operation: every field present, every enum value used once, nested messages to depth 2. It is deterministic. | a GCP `operations.get` returning an LRO in every state |
| the provider's documented examples | copied from the provider's public reference page, with the page title and section | AIP-193 error envelopes; the OAuth 2.0 token responses of RFC 6749 and Microsoft's identity platform pages; IMDS token responses; FCM v1 send responses |
| an emulator in this tier | captured once from the emulator, with its name and pinned version | moto error bodies, reused as fixtures for unit tests |

**How the fixtures are kept honest** (PROPOSED, slice S9; each rule is a lint that turns the build red):

- **Provenance.** Every file under a package's `tests/recorded/` has a sidecar `.provenance` line:
  `model <path> sha256 <hex>`, `doc "<title>" "<section>"`, or `emulator <name> <version>`. A fixture
  without one is refused.
- **The schema check.** A fixture whose source is a model is re-checked against that pinned model on
  every build: every field name exists, and every value has the declared type. When the model pin is
  bumped, a fixture that drifted turns red, and the fix is to regenerate it, with a visible diff.
- **No secrets.** The lint refuses an `Authorization` header, a JWT-shaped value, or a key-shaped
  value other than the documented example keys.
- **No dead fixtures.** Every fixture must be read by at least one test.

### What the tier proves, and what it does not

| proves | does not prove |
|---|---|
| that an implementation we did not write parses our requests and answers them, operation by operation | that the real cloud accepts them: IAM, quotas, regional behaviour, real TLS chains |
| state round trips (create, then read, then list, then delete), pagination tokens, conditional writes, error codes as each emulator maps them | that an emulator matches its cloud: each one is a third party's reading of the API, with documented gaps |
| SigV4 as an independent server checks it, only if moto's corrupted-signature mutant goes red (S5) | GCP bearer validity, scopes or expiry: the emulators accept any bearer |
| that response parsers accept every field the pinned model declares (the schema-derived fixtures) | that the live service sends what its model says, or documents what it sends |
| that the library under test is the one the release publishes (the release checks, S10) | installed-package loading of native code: that is S12, after #835 |

## The safety rules

1. **No cloud spend.** No test in the tier has a credential to any account. With no credential,
   nothing can be billed. No real-cloud step exists in this design.
2. **No credentials.** The harness passes only fixed dummy values: a dummy AWS key pair, the emulator
   bearer, and Azurite's published development key. The generated `_no_env_reads` tests already stop
   a client from picking up ambient `AWS_*` or `GOOGLE_*` variables. The emulator test targets carry
   no secret attribute, and the jobs that build them hold no cloud identity (`build` holds only the
   farm connection; `validate` has no `id-token`).
3. **No route to a real endpoint, enforced at three layers:**
   - **The connector** (primary). `LoopbackOnlyConnector[C: Connector]` wraps the real connector and
     refuses any `connect` whose address is outside `127.0.0.0/8`, before a socket is opened. The
     check runs on the address after DNS (the `Connector.connect` argument is the resolved
     `ip_be: UInt32`), so a host name that resolves to a public address is refused as well. The
     harness hands out no other connector. A welded test of the harness points a client at a public
     address and asserts that the client is refused. The planted mutant that proves the check: remove
     the range test, and that test turns red.
   - **The credential.** If a request escaped the connector, it would carry a dummy key, which any
     cloud rejects, and a rejected unauthenticated request is not billed.
   - **The network** (once the farm proves it, slice S4). The test runs in a network namespace that
     has only a loopback interface (`unshare --net`; farm actions run as uid 0). It starts with a
     self-check: a connect to a non-loopback address must fail, or the test refuses to run. A new
     `netns_loopback_only` row in the farm capability probe shows whether the workers allow this.
     Until the row passes, the first two layers hold on their own.
4. **No upload and no cluster write from the tier.** Emulators are build inputs. The tier publishes
   nothing; only the `gamma` and `prod` jobs publish, as they do today.

## Rollout

Each slice can be merged on its own, in this order. The proof of each slice is a check that is red
before the slice and green after it, or a planted mutant that turns the slice's own check red. **Go**
marks a step that needs the project owner's explicit go. Everything else is code that publishes
nothing on its own.

| # | slice | proof | go |
|---|---|---|---|
| S0 | **Lock gamma.** `gamma`'s deployment branches set to `main`. `gamma-breakglass` created with a required reviewer, and administrator bypass unchecked. The gamma channel's second trusted publisher confirmed. These are settings, not code. | `gh api .../environments` shows both policies. A dry-run manual run waits for approval. | **Go** (repository settings) |
| S1 | **The release ledger** (`release/unreleased.textproto`, a `[conda_status]` sub-target, a welded test). Fix `docs/releases.md`'s "Held" list. | A planted library that is in neither file turns the build red. A ledger `NATIVE` row on a library that is not native turns it red. | none |
| S2 | **Declare the 21 non-native libraries:** #1136, #1138, then three declare PRs. | `install-set` runs each new README in `gamma` | **Go per PR:** a merged declare PR publishes permanent names to `gamma` and then `prod` |
| S3 | **Native packaging,** #835 and its stack. Then declare the `NATIVE` and `DLOPEN` rows in ledger-sized PRs. | the ledger shrinks. `install-set` loads each native library from the install. | **Go:** the #835 decision, then per declare PR as in S2 |
| S4 | **`komira_test_emulator`:** process start, readiness, stop, `LoopbackOnlyConnector`; the farm probe row `netns_loopback_only`. | Mutants: drop the address range test (the refusal test turns red); drop pdeathsig (the orphan check turns red); a readiness budget of 1 ms (the timeout test turns red). | none |
| S5 | **moto, pinned wheels,** with the first AWS suite: sts, s3, sqs, secretsmanager, `komira_objectstore_s3` | A planted serialization bug (a required parameter dropped) turns the round trip red. The corrupted-signature mutant with moto's authentication on decides whether the tier claims SigV4. | **Go (one-time ruling):** moto over LocalStack, and third-party emulator packages as build inputs (decisions 3 and 5) |
| S6 | **The remaining AWS packages:** round-trip tables for the other client-mode services, the pure-mode shim, `komira_aws_metrics` | a planted bug per package (for example, a pagination token not echoed) | none |
| S7 | **GCP:** the Firestore emulator (pinned JRE and jar) for firestore and firestore_db; storage-testbench for storage and objectstore_gcs | a planted precondition bug (an ignored `currentDocument.exists`); a planted range bug | **Go:** the Firestore emulator's redistribution terms checked and accepted |
| S8 | **Azure:** a probe to choose Azurite's form, then the blob suite | a planted bug in the `NextMarker` loop turns list pagination red | none (unless the probe picks containers: then decision 5) |
| S9 | **Recorded responses:** the provenance, schema, secret and dead-fixture lints; fixtures for the packages that have no emulator | a planted fixture without provenance; a planted unknown field; a planted bearer token. Each turns the lint red. | none |
| S10 | **Release checks:** a `checks:` field on the BUILD step and `release/checks.textproto` (S4 to S9 targets plus the standalone e2e and conformance suites that reach released libraries), run in batches; kci built once per revision (#1153) | a machine-file fixture whose check target fails: `kci run --stage build` fails and `gamma` never starts | none: it adds a gate to an approved pipeline |
| S11 | **Yank:** verify that the channel host can delete a file or mark it removed; a `kci yank` verb, dry run by default | a dry run against the fake channel lists exactly one file. A real run is refused without `--channel` and `--file`. | **Go per use** |
| S12 | **Installed-bytes cloud smoke** in `validate` (after S3): one emulator round trip per cloud family against the installed package | a planted missing `.so` in a fixture package turns it red | **Go:** decision 1 (a `service` block in gamma) and the workflow-rule amendment (item 7) |

S0 is independent of the rest and should go first. S4 to S10 can start at once, in parallel with S2
and S3, because they test source code at build time. The cloud packages then reach `gamma` already
gated, on the day S3 lands.

## Questions for the project owner

Each has a recommendation. None is decided here.

1. **Lock gamma now (S0)?** *Recommendation:* yes, today. It is two settings, and until they exist any
   branch can publish to `gamma`.
2. **Is merging a declare PR the go for its new names?** A merged declare PR publishes names to
   `gamma` and then to `prod`, permanently and with no further click. *Recommendation:* yes, the merge
   is the go. The `gamma` job summary already lists "NEW NAMES" for `prod`.
3. **Native packaging (#835).** 139 of the roughly 160 unreleased libraries, and every cloud SDK
   package, wait on it. *Recommendation:* decide #835 next. Nothing else in this document moves the
   count as much.
4. **moto, not LocalStack, for AWS.** *Recommendation:* moto. LocalStack needs a token (a secret), its
   free plan is for non-commercial use, and ECR and ECS are behind a paid plan.
5. **Pinned third-party emulators as build inputs** (moto, storage-testbench, the Firestore emulator,
   Azurite, and their runtimes). *Recommendation:* yes, by sha256 only. Accept the Firestore
   emulator's terms before pinning it.
6. **Where the cloud tier gates.** *Recommendation:* at build time on the release revision (S10) now.
   Add the installed-bytes smoke in `validate` (S12) once #835 ships native packages, because that is
   when the build stops being able to see the defect.
7. **Yank.** *Recommendation:* approve the mechanism (S11), with each use still a separate go.
8. **Recording from a live cloud.** *Recommendation:* no. It needs an account and a credential, so the
   recorded tier uses models, documented examples and emulators only. Revisit together with real gamma
   projects (decision 4).
9. **The Pub/Sub, Bigtable, Spanner, Datastore and Cosmos DB emulators.** komira has no client for any
   of them. *Recommendation:* adopt each emulator in the PR that adds its client, with this harness.
