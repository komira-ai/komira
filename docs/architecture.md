# Architecture

komira is a data platform written in [Mojo](https://www.modular.com/mojo): a
columnar, Arrow-native core, the codecs and cryptography its connectors and
storage formats are built on, and the libraries `kci`, its build-and-deploy
command line, uses to validate what it ships. Everything is built with
[Buck2](https://buck2.build) and a hermetic toolchain, and every library's
tests are part of its build.

This page is the map: what is in [`src/`](../src/) today, how the build holds
it together, and which layers are still to come. Setup is in
[DEVELOPMENT.md](../DEVELOPMENT.md); a first build is in
[getting-started.md](getting-started.md).

## The module map

Every Mojo module is one directory directly under `src/`. The directory name
is the import name (`from komira_crypto import ...`) and the name of the
module's `mojo_library`; a module's tests are in its own `tests/`
([DEVELOPMENT.md](../DEVELOPMENT.md#repository-layout)). Each line below is
the module's own description, from the header of its `__init__.mojo` (or, where
that header only re-exports, its BUCK file).

### Core

| module | what it is |
|---|---|
| [`komira_core`](../src/komira_core/) | the Arrow-native core types the rest is built on: the columnar primitives (Column, Buffer, RecordBatch and the Arrow value types), the SIMD helpers operators vectorize over, and the shared plan IR (LogicalPlan, Expr, ScalarValue, AggExpr). Its [README](../src/komira_core/README.md) lists what lives in each subpackage. |
| [`komira_core_ffi`](../src/komira_core_ffi/) | the canonical libc / POSIX FFI declarations: one declaration per C symbol, so two packages in one link unit never declare the same symbol with conflicting signatures. |
| [`komira_atomic_alias`](../src/komira_atomic_alias/) | the one place the repository spells `Atomic[...]`; it imports only `std.atomic`, so any package may depend on it. |
| [`komira_rowcell`](../src/komira_rowcell/) | the typed table-cell value model: one `RowCell` struct, its six scalar type tags, typed constructors and value equality. A leaf that imports only the Mojo standard library. |

### Codecs and wire formats

| module | what it is |
|---|---|
| [`komira_lz4`](../src/komira_lz4/) | the shared LZ4 raw-block codec over liblz4, loaded at run time, with no first-party deps. |
| [`komira_zlib`](../src/komira_zlib/) | a zero-dependency FFI facade over libz, so a consumer that needs only zlib framing does not depend on a file-format reader. |
| [`komira_protobuf`](../src/komira_protobuf/) | a general-purpose Protocol Buffers wire codec (reader, writer, wire types), not tied to any one message set. |
| [`komira_xml`](../src/komira_xml/) | a general XML codec: reader, tree, writer and escaping. |

### Security and identity

| module | what it is |
|---|---|
| [`komira_crypto`](../src/komira_crypto/) | cryptographic primitives: hashes, MACs, KDFs, AEADs, key agreement, signatures, an entropy source and DRBG, hex / base64 / base32 codecs, and X.509 chain validation. The heavy primitives call AWS-LC's `libcrypto`; the traits, codecs and DER / X.509 layer are Mojo. Design: [crypto and TLS](design/crypto_and_tls.md). |
| [`komira_uuid`](../src/komira_uuid/) | UUIDv7 (RFC 9562): the `Uuid` value type, a stateless generator and a monotonic one. |

### Runtime support and change data capture

| module | what it is |
|---|---|
| [`komira_resources`](../src/komira_resources/) | the files a program reads at run time: `read_resource` and `resource_path`. |
| [`komira_snapshotter`](../src/komira_snapshotter/) | the provider-agnostic change-stream seam: one trait every change-stream provider conforms to, so a snapshotter's apply, write, commit and checkpoint half is written once. It holds no provider client code. |

### CI and deploy (`kci`)

A library `kci` owns is named `kci_<x>`.

| module | what it is |
|---|---|
| [`kci_logs`](../src/kci_logs/) | reads the logs behind a failed step: a pipeline run's stage logs, and a terminated cloud unit's container output. |
| [`kci_params`](../src/kci_params/) | the generic managed-app parameter mechanism: one declaration that the deploy renderer turns into argv, the app parses at startup, and the control plane stores opaquely. |
| [`kci_validator_report`](../src/kci_validator_report/) | the one report library every validator shares. It produces evidence, not authorization: the gate stays the exit code and the build graph. |
| [`kci_validator_rows`](../src/kci_validator_rows/) | the positional row-accounting model every managed-app validator shares, so a run that emitted only a prefix of its rows cannot report PASS. |
| [`komira_validation_run`](../src/komira_validation_run/) | the validation-run correlator: the tag key under which a validation run stamps its identity on every billable cloud resource it creates, so cleanup acts only on what it can prove that run made. |

### Third-party code

C and C++ libraries are built from pinned source archives under
[`third_party/`](../third_party/): aws-lc, s2n-tls and snappy, plus the
crates.io crates the Rust rules use. Mojo code calls them through `deps` on
their targets ([C and C++](../tools/build/mojo/README.md#c-and-c)).

## How the build holds it together

The build tooling is in [`tools/build/`](../tools/build/README.md): the Mojo
rules, the hermetic toolchain, the execution platforms, the packaging rules
and the end-to-end tests. Two properties shape how you work in this
repository.

**Tests are welded to the library they cover.** A `mojo_library` names its
tests in `test_srcs`. Each test is compiled against the package and run as a
build action, and the PASS marker of every test is an input to the action
that publishes the package, so the package cannot exist unless its tests
passed, and neither can anything depending on it. Building a library runs
its tests; there is no separate step to forget. A red test that must not
block the library is held by a `tests_known_failing` row, which inverts
rather than mutes: the held test must keep failing, and the build goes red
when it starts passing. The full contract is in
[the Mojo rules](../tools/build/mojo/README.md#libraries-and-the-test_srcs-gate).

**Lints are validations of the targets they guard.** Shellcheck,
actionlint, the repository checks and the Markdown link check (`//:docs`:
every relative link and `#anchor` resolves) return their verdict as Buck2
validations ([tools/build/lint/defs.bzl](../tools/build/lint/defs.bzl)), so
`./buck2 build //...` fails on a finding. The Mojo and Rust rules depend on
the lint of the scripts their actions run, so no Mojo target builds while one
of those scripts has a finding.

Other properties of the build:

- **One closure, through `deps`.** A package reaches the compiler only through
  `deps`, which carries the full transitive closure, one package per `-I`
  directory; a missing edge fails to compile rather than resolving from a
  stray source directory.
- **Hermetic toolchain.** The Mojo compiler, zig and the file utilities every
  action uses are sha256-pinned downloads
  ([toolchains](../tools/build/toolchains/README.md)).
- **Local or remote, same commands.** A fresh clone builds on the local
  machine; a `.buckconfig.local` naming a remote-execution service moves every
  action there ([DEVELOPMENT.md](../DEVELOPMENT.md)).
- **Execution classes.** Each action runs on a class of worker: light
  work (unpacking toolchain files), Mojo compiles and tests on one NUMA node,
  or multi-NUMA runs ([platforms](../tools/build/platforms/README.md)).
- **Packaging.** `mojo_bundle`, `bundle_tarball` and `oci_image` turn a
  binary into a relocatable bundle or an image
  ([packaging](../tools/build/package/README.md)).
- **Usable from another repository.** komira is one Buck2 cell that another
  repository mounts as a git external cell or a submodule
  ([using komira from another repository](../tools/build/README.md#using-komira-from-another-repository)).

What each end-to-end test proves is in
[tools/build/tests/README.md](../tools/build/tests/README.md).

## Layers still to come

The libraries below are not in `src/` yet. Each family's design doc arrives
with its libraries ([docs/index.md](index.md#design-docs)).

| layer | coming with |
|---|---|
| HTTP, databases, object stores, file-system discovery, gRPC | komira_http, komira_db, komira_objectstore, komira_grpc |
| storage formats: Parquet, text and row formats, Iceberg and CDC, serverless Postgres | komira_parquet, komira_csv, komira_iceberg, komira_pgstore |
| execution and operators: pipelines and morsel dispatch, aggregation, joins, sort, top-N, window | the engine libraries |
| plan and optimizer: logical and physical planning, the plan wire format, the query optimizer | komira_compiler, komira_optimizer |
| SDK and SQL: the plan-carrier surface, UDFs, the Python package, the SQL front ends | komira_sdk |
| runtime: the async runtime, the job agent and supervisor | komira_async, komira_agent |
| observability: logging and telemetry | komira_log |
| agents: MCP and local models | komira_mcp_server, komira_localmodel |
| cloud: AWS clients, cloud credentials, infrastructure providers, secrets and service registry | the cloud SDK libraries |
| CI and deploy: the bundle model, apply, validate and rollout, the command line | kci |
| packaging: the shared-library ABI, the release train | komira_so and the packaging rules |

## Conventions

These are the rules for new code. Existing code has exceptions, chiefly FFI
handles, and the build checks none of the pointer rules; review holds them.

- **Pointers.** `UnsafePointer` does not cross a module boundary: it is
  allowed inside a struct for performance or FFI, and the public API exposes
  safe types. Allocate with `OwnedPointer[T]` (or `ArcPointer[T]` for shared
  ownership); do not give an owning struct field a wildcard origin; do not
  rebuild a pointer from an integer address; and give an internal
  `UnsafePointer` a `# SAFETY:` comment saying why it is sound. Some existing
  code does not follow these yet: for example, an owning codec handle keeps an
  FFI pointer in a `MutExternalOrigin` field, and some tests rebuild pointers
  with `unsafe_from_address=`. Why, and where the tree stands:
  [Mojo safety and idioms](design/mojo_safety_and_idioms.md).
- **A bug fix comes with a failing test.** Write a test that fails before the
  fix, apply the fix, watch it pass, and commit both together. Name the test
  in the library's `test_srcs`, or it never runs.
- **Configuration is flags, not environment variables.** A flag is parsed at
  startup and can be required, so a missing value is refused by name before
  anything changes; to an environment variable, absent and empty are the same
  bytes. Environment variables remain for platform-set mode discriminators and
  for secret material, which must not appear in argv.
- **Describe only what the code does.** A header or design doc whose prose
  contradicts its code costs the next reader real time. If you cannot point at
  the code, do not write the claim.
