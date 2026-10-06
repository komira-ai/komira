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
that header only re-exports, its BUCK file). The current list is `ls src/`.

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
| [`komira_parquet_api`](../src/komira_parquet_api/) | the Parquet format's types and footer metadata: the Thrift enums (physical type, encoding, compression codec, page type) and the `FileMetaData` tree a footer decodes into, as plain values with no dependencies. |
| [`komira_protobuf`](../src/komira_protobuf/) | a general-purpose Protocol Buffers wire codec (reader, writer, wire types), not tied to any one message set. |
| [`komira_xml`](../src/komira_xml/) | a general XML codec: reader, tree, writer and escaping. |
| [`komira_encoding`](../src/komira_encoding/) | binary-to-text encodings, base64, base64url, base32 and hex, and RFC 7468 PEM armor, in pure Mojo with no dependencies; decoding is strict and names the byte position of what it rejects. |
| [`komira_json`](../src/komira_json/) | a small dependency-free JSON library (RFC 8259): a tagged `JsonValue`, a strict non-recursive parser with a nesting-depth limit, and direct-byte writers. |
| [`komira_textproto`](../src/komira_textproto/) | a zero-dependency textproto lexer: typed tokens (so a quoted brace never equals a brace) and a cursor for hand-written parsers. |
| [`komira_kafka_server`](../src/komira_kafka_server/) | a Kafka-protocol server for the komira broker. Today it holds only its wire codec (`komira_kafka_server.wire`: framing, primitive types, the v2 RecordBatch with CRC-32C, request and response schemas); connection handling and dispatch arrive in the same package. |

### Security and identity

| module | what it is |
|---|---|
| [`komira_crypto`](../src/komira_crypto/) | cryptographic primitives: hashes, MACs, KDFs, AEADs, key agreement, signatures, an entropy source and DRBG, hex / base64 / base32 codecs, and X.509 chain validation. The heavy primitives call AWS-LC's `libcrypto`; the traits, codecs and DER / X.509 layer are Mojo. Design: [crypto and TLS](design/crypto_and_tls.md). |
| [`komira_uuid`](../src/komira_uuid/) | UUIDv7 (RFC 9562): the `Uuid` value type, a stateless generator and a monotonic one. |
| [`komira_jwks`](../src/komira_jwks/) | the public half of an offline-verify token stack: the deterministic `kid`, the JWK Set renderer (RFC 7517 / RFC 8037, public members only) and the publish-only seed-to-JWKS derivation. The minter's own authorization vocabulary stays out of it. |
| [`komira_secret_store`](../src/komira_secret_store/) | the secret-store seam: a one-method `SecretStore` trait (handle in, `SecretValue` out) and a scripted, network-free double, so a consumer can bind a store without depending on any implementation. |
| [`komira_secret_registry`](../src/komira_secret_registry/) | the per-execution secret registry: a side table binding a query's secret-bearing plan nodes to opaque handles, and the connector reveal seam that resolves a handle only at the moment a connector needs the bytes. |

### Runtime support and change data capture

| module | what it is |
|---|---|
| [`komira_resources`](../src/komira_resources/) | the files a program reads at run time: `read_resource` and `resource_path`. |
| [`komira_snapshotter`](../src/komira_snapshotter/) | the provider-agnostic change-stream seam: one trait every change-stream provider conforms to, so a snapshotter's apply, write, commit and checkpoint half is written once. It holds no provider client code. |
| [`komira_retry`](../src/komira_retry/) | generic retry: when to retry and how long to wait, never which failures. A pure `RetryPolicy`, a `RetryLoop` over injected clock, sleeper and random-source seams, and an optional retry budget; classifying a failure belongs to the client library that knows the protocol. |

### Cloud

| module | what it is |
|---|---|
| [`komira_aws_core`](../src/komira_aws_core/) | the one hand-written AWS core under the generated AWS clients: the credential value, SigV4 signing (headers and presigned URLs), the SDK default credential chain and region resolution, the shared config file parser, and the network-backed credential providers as request builders and response parsers. |
| [`komira_aws_s3`](../src/komira_aws_s3/) | the Amazon S3 client, generated at build time from botocore's pinned S3 model (no source is committed): each operation's request builder and response parser, and its endpoint resolved through S3's published endpoint ruleset, and `S3Client`, which signs and sends each call through `komira_aws_core` over the connector it is given. It reads no environment. |
| [`komira_aws_dynamodb`](../src/komira_aws_dynamodb/) | the Amazon DynamoDB client, generated at build time from botocore's pinned DynamoDB model (no source is committed): the item, query, scan and table operations' request builders and response parsers, and their endpoints resolved through DynamoDB's published endpoint ruleset. Pure: it opens no connection and reads no environment; a caller signs a built request with `komira_aws_core`. |
| [`komira_aws_dynamodbstreams`](../src/komira_aws_dynamodbstreams/) | the Amazon DynamoDB Streams client, generated at build time from botocore's pinned DynamoDB Streams model (no source is committed): DescribeStream, GetShardIterator and GetRecords, their endpoints resolved through the service's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a connector it is given. It reads no environment. |
| [`komira_aws_logs`](../src/komira_aws_logs/) | the Amazon CloudWatch Logs client, generated at build time from botocore's pinned logs model (no source is committed): GetLogEvents' request builder and response parser, and its endpoint resolved through the service's published endpoint ruleset. Pure: it opens no connection and reads no environment; a caller signs a built request with `komira_aws_core`. |
| [`komira_aws_metrics`](../src/komira_aws_metrics/) | CloudWatch metrics through the `komira_metrics_reader` seam: GetMetricData's request body, response parse and error, and `CloudWatchMetricsReader`, a `MetricsReader` for one namespace and a fixed set of dimensions (an ECS service's, from its ARN) that signs and sends each call through `komira_aws_core` over the transport it is given. Hand-written: the pinned CloudWatch model declares a protocol the AWS generator refuses; its constants are checked against that model by a welded test. Its endpoint comes from `komira_aws_core`'s generic `aws_service_endpoint`, not from the service's ruleset, checked against botocore's CloudWatch endpoint tests except FIPS, which it does not offer (the generic FIPS host is wrong in GovCloud). It reads no environment. |
| [`komira_aws_route53`](../src/komira_aws_route53/) | the Amazon Route 53 client, generated at build time from botocore's pinned Route 53 model (no source is committed): the record-set operations (ListHostedZonesByName, ListResourceRecordSets, ChangeResourceRecordSets), their request builders and response parsers, and `Route53Client`, which sends each to the global endpoint Route 53's published endpoint ruleset chooses for the partition, signed in the region that endpoint names, through `komira_aws_core` over the connector it is given. A zone or change Id is sent bare, as botocore sends it, so an Id Route 53 answered with can be passed back as it came. It reads no environment. |
| [`komira_aws_sqs`](../src/komira_aws_sqs/) | the Amazon SQS client, generated at build time from botocore's pinned SQS model (no source is committed): the queue and message operations' request builders and response parsers, and their endpoints resolved through SQS's published endpoint ruleset, and `SQSClient`, which signs and sends each call through `komira_aws_core` over the connector it is given. It reads no environment. |
| [`komira_aws_ecr`](../src/komira_aws_ecr/) | the Amazon ECR client, generated at build time from botocore's pinned ECR model (no source is committed): the repository create, describe and tag-mutability operations and GetAuthorizationToken, their endpoints resolved through ECR's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a connector it is given. It reads no environment. |
| [`komira_aws_ecs`](../src/komira_aws_ecs/) | the Amazon ECS client, generated at build time from botocore's pinned ECS model (no source is committed): the cluster, task definition and task operations, their endpoints resolved through ECS's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a connector it is given. It reads no environment. |
| [`komira_aws_lambda_http`](../src/komira_aws_lambda_http/) | a `komira_http_server` `RequestDispatcher` run on AWS Lambda behind API Gateway, the dispatcher unchanged: the payload-format-2.0 proxy event to `HttpRequest` and the response back (base64 bodies both ways, the authorizer context injected as headers under a caller-chosen prefix, client-forged headers under it dropped), the REQUEST-authorizer event and its simple response, the EventBridge Scheduler tick, and the invoke loops over a Runtime API transport and a post-response drain the binary supplies. It reads no environment. |
| [`komira_aws_secretsmanager`](../src/komira_aws_secretsmanager/) | the AWS Secrets Manager client, generated at build time from botocore's pinned Secrets Manager model (no generated source is committed): a secret's create, put, get, describe, delete and restore operations, their endpoints resolved through the service's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a connector it is given, filling an unset ClientRequestToken. DeleteSecret's verb is hand-written: it refuses a recovery window with a forced delete, or outside 7..30 days, before sending. Its errors never carry a response body. It reads no environment. |
| [`komira_aws_lambda`](../src/komira_aws_lambda/) | the AWS Lambda client, generated at build time from botocore's pinned Lambda model (no source is committed): the function create, read, update, permission, concurrency, function URL, invoke and delete operations' request builders and response parsers, their endpoints resolved through Lambda's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a `komira_http_core` connector it is given. It reads no environment. |
| [`komira_aws_apigatewayv2`](../src/komira_aws_apigatewayv2/) | the Amazon API Gateway v2 client, generated at build time from botocore's pinned apigatewayv2 model (no source is committed): the HTTP API, stage, integration, route and authorizer operations' request builders and response parsers, their endpoints resolved through the service's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a `komira_http_core` connector it is given. It reads no environment. |
| [`komira_aws_sesv2`](../src/komira_aws_sesv2/) | the Amazon SES API v2 client, generated at build time from botocore's pinned sesv2 model (no source is committed): the email identity, configuration set and SendEmail operations' request builders and response parsers, their endpoints resolved through the service's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a `komira_http_core` connector it is given. It reads no environment. |
| [`komira_aws_scheduler`](../src/komira_aws_scheduler/) | the Amazon EventBridge Scheduler client, generated at build time from botocore's pinned scheduler model (no source is committed): the schedule create, read, update and delete operations' request builders and response parsers, their endpoints resolved through the service's published endpoint ruleset, and a client that signs and sends each call through `komira_aws_core` over a `komira_http_core` connector it is given. It reads no environment. |
| [`komira_aws_iam`](../src/komira_aws_iam/) | the AWS IAM client, generated at build time from botocore's pinned IAM model (no source is committed): the user, access key, role, inline policy and OIDC provider operations, as awsQuery form requests and result parsers, their endpoint resolved through IAM's published endpoint ruleset (the global endpoint, signed for us-east-1), and `IAMClient`, which signs and sends each call through `komira_aws_core` over the connector it is given. It reads no environment. |
| [`komira_aws_sns`](../src/komira_aws_sns/) | the Amazon SNS client, generated at build time from botocore's pinned SNS model (no source is committed): the topic and subscription operations, as awsQuery form requests and result parsers, their endpoint resolved through SNS's published endpoint ruleset, and `SNSClient`, which signs and sends each call through `komira_aws_core` over the connector it is given. It reads no environment. |
| [`komira_aws_ec2`](../src/komira_aws_ec2/) | the Amazon EC2 client, generated at build time from botocore's pinned EC2 model (no source is committed): the twelve instance, spot request, VPC, subnet and security group operations, as ec2Query form requests and response parsers, their endpoint resolved through EC2's published endpoint ruleset, and `EC2Client`, which signs and sends each call through `komira_aws_core` over the connector it is given. It reads no environment. |
| [`komira_gcp_core`](../src/komira_gcp_core/) | the one hand-written core of the Google Cloud SDK: the token-source seam, status-to-error mapping, a retry classifier and page-token helpers the generated `komira_gcp_<service>` clients compose; and the production token sources (the metadata server, a service-account key's JWT grant or self-signed JWT, an `authorized_user` refresh) with Application Default Credentials, which picks one in Google's order. Those send their own token requests through `komira_http_client` (`token_http`): the OAuth 2.0 token endpoint and the metadata server have no googleapis proto, so there is nothing to generate them from. It reads the environment only in `sources.mojo`, and only the variables Google's auth libraries read. |
| [`komira_gcp_apigateway`](../src/komira_gcp_apigateway/) | the API Gateway v1 client, generated at build time from the pinned googleapis apigateway protos (no source is committed): Create, Get and Delete of an API, an API config and a gateway, as REST/JSON through `komira_http_client` with a bearer token from a `komira_gcp_core` token source, a non-2xx answer mapped through `komira_gcp_core`. It reads no environment. |
| [`komira_gcp_artifactregistry`](../src/komira_gcp_artifactregistry/) | the Artifact Registry v1 client, generated at build time from the pinned googleapis artifactregistry protos (no source is committed): repository create, get, delete and list, and a file's get, as REST/JSON in the same shape. It reads no environment. |
| [`komira_gcp_cloudresourcemanager`](../src/komira_gcp_cloudresourcemanager/) | the Resource Manager v3 Projects client, generated at build time from the pinned googleapis protos (no source is committed): GetProject, and a project's GetIamPolicy, SetIamPolicy (the etag read sent back with the write) and TestIamPermissions, as `ProjectsClient` over REST/JSON with a bearer token from a `komira_gcp_core` token source. It reads no environment. |
| [`komira_gcp_compute`](../src/komira_gcp_compute/) | the Compute Engine v1 client, generated at build time from the pinned googleapis compute proto (no source is committed) and scoped to the methods its callers make: VM instances, region quotas, VPC networks, subnetworks and firewalls, the HTTPS load-balancer resources, and the waits on Compute's own operations, as REST/JSON in the same shape. It reads no environment. |
| [`komira_gcp_iam`](../src/komira_gcp_iam/) | the IAM v1 client, generated at build time from the pinned googleapis protos (no source is committed): service accounts (list, get, create, delete), custom roles (get, create, update, delete, each at its project or organization path; get also reads a predefined role) and a service account's IAM policy, as `IAMClient` over REST/JSON with a bearer token from a `komira_gcp_core` token source. No key, signing or undelete method is generated. It reads no environment. |
| [`komira_gcp_logging`](../src/komira_gcp_logging/) | the Cloud Logging v2 client, generated at build time from the pinned googleapis logging protos (no source is committed): ListLogEntries' request and response messages and `LoggingServiceV2Client`, which sends it as REST/JSON through `komira_http_client` with a bearer token from a `komira_gcp_core` token source and maps a non-2xx answer through `komira_gcp_core`. It reads no environment. |
| [`komira_gcp_monitoring`](../src/komira_gcp_monitoring/) | Cloud Monitoring metrics through the `komira_metrics_reader` seam: `CloudMonitoringMetricsReader`, a `MetricsReader` for one project over the generated `komira_gcp_monitoring_client`, and its adapter: the `ListTimeSeriesRequest` it builds and refuses, the filter (values quoted, label keys refused unless plain identifiers) and the page it reads from the generated response. Pages are merged on a series' whole identity (metric type, every label, resource type). It reads no environment. |
| [`komira_gcp_monitoring_client`](../src/komira_gcp_monitoring_client/) | the Cloud Monitoring v3 client, generated at build time from the pinned googleapis monitoring protos (no source is committed): ListTimeSeries' request and response messages and `MetricServiceClient`, which sends it as a REST GET (its interval and aggregation in the query: Timestamps in RFC 3339, the alignment period as a Duration string) through `komira_http_client` with a bearer token from a `komira_gcp_core` token source and maps a non-2xx answer through `komira_gcp_core`. It reads no environment. |
| [`komira_gcp_serviceusage`](../src/komira_gcp_serviceusage/) | the Service Usage v1 client, generated at build time from the pinned googleapis protos (no source is committed): EnableService and DisableService, answered with a long-running `Operation`, and GetService, whose `state` a caller polls until the service is enabled, as `ServiceUsageClient` over REST/JSON with a bearer token from a `komira_gcp_core` token source. It reads no environment. |
| [`komira_gcp_storage`](../src/komira_gcp_storage/) | the Cloud Storage gRPC client, generated at build time from googleapis's pinned storage v2 protos (no source is committed): the object reads, writes (streamed and resumable), listings and deletes, and bucket create, get, delete and IAM policy, over `komira_grpc` with each call's token from a `komira_gcp_core` token source and its `x-goog-request-params` from the method's routing annotation. It reads no environment. |
| [`komira_gcp_wif`](../src/komira_gcp_wif/) | workload identity federation from AWS: a SigV4-signed `GetCallerIdentity` (the `aws1` subject token, signed by `komira_aws_core`) exchanged at Google STS for an access token, as a `komira_gcp_core` token fetcher behind its `GcpTokenSource` seam, and that token used to mint a JWT self-signed by a service account through IAM Credentials `signJwt`. Both calls go through `komira_http_client`; a refusal never echoes a body. It reads no environment. |

### CI and deploy (`kci`)

A library `kci` owns is named `kci_<x>`.

| module | what it is |
|---|---|
| [`kci_artifact`](../src/kci_artifact/) | the artifacts: the one reviewed list of what kci builds and publishes. kci names no build tool: a file declares build systems (a program and the args it always gets) and artifacts (a name, the build system, the args appended for it). The contract: for each artifact kci creates an EMPTY directory, runs `<executable> <build system args> <artifact args>` with every `{out_dir}` replaced by its absolute path, and ships exactly what the ONE kci artifact manifest it left at the top, `manifest.json`, describes: one artifact per entry (the layout of a `conda_package`'s `[release]`: the `.conda`, `manifest.json`, `metadata.json`). Refused: a non-zero exit, no `manifest.json` at the top (or a listing naming it twice), and a manifest whose `name` is not the artifact's, compared exactly. Which remote-execution farm a build uses is machine configuration, never an artifact's args: buck2 reads `[buck2_re_client]` only from config files at daemon start (`/etc/buckconfig.d/`, `~/.buckconfig.d/`), so `--config-file` and `-c` cannot supply it, and a buck2 build system's args are just `["build"]`. Reads and validates an artifacts file (names, executables, args, the one placeholder `{out_dir}` present for every artifact) and renders one artifact's argv (pure; the BUILD step runs it). Type, platform, file, sha256 and metadata come from the built manifest, and the set-level checks (every artifact built, lockstep versions, metapackage last, requirement closure) are made over those manifests: the BUILD step refuses, before `release.json`, a library requirement whose name is not the conda name of another library of the set (the platform guard and the compiler pin aside), and the PUBLISH step checks all of them, the closure with its exact pins. |
| [`kci_artifact_proto`](../src/kci_artifact_proto/) | the artifacts schema (`kci.release.v1`): `Artifacts` holds `BuildSystem`s (name, executable, args) and `Artifact`s (name, build system, args). No enum and no kind of artifact; the build rules (one artifact per entry: exactly one `manifest.json` at the top of `{out_dir}`, its `name` the artifact's) is stated in the `.proto`. |
| [`kci_cloud`](../src/kci_cloud/) | the clouds of the deploy side. A cloud is a cell's deploy target (`gcp`, `aws`, `fake`), the id of a cloud adapter built into kci; it is not a platform (an OS and a CPU). Holds the closed list of built-in clouds (an unknown id is refused, naming the closest), the validate phase that refuses a whole graph before anything is lowered or created (graph, coverage and limit findings in one pass), plan / apply / destroy in a cell over the reconciler's owned scope (an apply reports what landed and what is pending when it stops part-way, and a refusal before any change), the cloud adapter interface (cell settings, the public mechanism chosen at validate time, the artifact a resource needs, lowering to data, bootstrap resources, the label rule, the owned-object list, who-am-I and the cloud side of trust), and the conformance kit every cloud runs. |
| [`kci_cloud_fake`](../src/kci_cloud_fake/) | the fake clouds `fake` (complete) and `fake-limited` (deliberately partial: no `job`, no public ingress). Fakes, not mocks: working, lightweight clouds held in memory that really deploy. They are the executable specification of a cloud, the offline test double, and the offline proof that a graph a cloud cannot host is refused before anything is created. They honour the ownership labels (every object born stamped, read back exactly, listed per cell), and a faulty variant (one chosen call refused, reads that lag, an object made outside kci, a create raced by a second apply) is tested with no cloud. |
| [`kci_logs`](../src/kci_logs/) | reads the logs behind a failed step: a pipeline run's stage logs, and a terminated cloud unit's container output. |
| [`kci_params`](../src/kci_params/) | the generic managed-app parameter mechanism: one declaration that the deploy renderer turns into argv, the app parses at startup, and the control plane stores opaquely. |
| [`kci_reconciler`](../src/kci_reconciler/) | the deploy engine core: reconciles a graph of desired resources against the live cloud (plan, apply, rollback, destroy) over a write-ahead intent store, with typed outputs flowing from one node into the next. It names no cloud: a cloud adapter supplies the nodes. Only a resource this apply created is unwound on rollback, and a failed resource is updated, not refused. In a cell (machine + cell), the store is keyed (machine, cell, resource), every object is created carrying its ownership stamp, and an object kci does not own is refused before any change. |
| [`kci_validator_report`](../src/kci_validator_report/) | the one report library every validator shares. It produces evidence, not authorization: the gate stays the exit code and the build graph. |
| [`kci_validator_rows`](../src/kci_validator_rows/) | the positional row-accounting model every managed-app validator shares, so a run that emitted only a prefix of its rows cannot report PASS. |
| [`kci_release_channel`](../src/kci_release_channel/) | release channels: a publish destination (a name, a visibility and one repository per artifact type), its lookups and validation, and the channels-file parser. |
| [`kci_secret_writer`](../src/kci_secret_writer/) | the write-only secret seam: the verb a deployer uses to write an app secret it is the source of, a capability distinct from `SecretStore` so the runtime resolve path cannot write. |
| [`komira_validation_run`](../src/komira_validation_run/) | the validation-run correlator: the tag key under which a validation run stamps its identity on every billable cloud resource it creates, so cleanup acts only on what it can prove that run made. |

### Test infrastructure

Libraries a test uses to run against real infrastructure and prove it
cleaned up. Each is configured by the test's own flags, and with no flags a
test that needs one SKIPS with a reason (exit 77) instead of passing. The
dependency order is the order of the rows.

| module | what it is |
|---|---|
| [`komira_test_verdict`](../src/komira_test_verdict/) | the exit-code vocabulary of a test that can do more than pass or fail: `Verdict` (CLEAN 0, CANNOT_TELL 3, LEAK 6; the worst wins and every reason is kept) and SKIP (77) / CANNOT_TELL (3) with a reason, which end the process and are never exit 0. Standard library only. |
| [`komira_test_run_id`](../src/komira_test_run_id/) | a per-run id minted inside the test process from the wall clock and 64 random bits, never derived from inputs, so a retry and its twin get disjoint resources; with the clock and random-source seams and their fakes. |
| [`komira_test_minio`](../src/komira_test_minio/) | an embedded MinIO the test starts itself: pinned by sha256, a private temporary directory, a random root credential in 0600 files, random loopback-only ports, dies with the test. It hands back the endpoint, region and credentials-file path, and `stop()` returns a verdict. |
| [`komira_test_bucket`](../src/komira_test_bucket/) | a run-scoped prefix in any S3-compatible store: the lease is written first, `close()` deletes everything and re-lists to prove it, and a leak check asks the same from outside the run. It reads the test's `--test-s3-*` / `--test-minio-binary` flags, and on an embedded MinIO it creates the bucket and owns and stops the server. |
| [`komira_test_s3_adapter`](../src/komira_test_s3_adapter/) | the real adapters behind those seams, for a test that runs on an embedded MinIO: `SpawnedProcessRunner` (starts the server through `spawn_detached` and setpriv so it dies with the test, Linux only; readiness from MinIO's health endpoint) and `MinioObjectStore` (an `S3Store`, path-style plaintext, the credential from the shared-credentials file), and `open_embedded_minio_test_bucket`, which opens a run's bucket from the test's flags with both. The only one of these libraries with an HTTP stack and a process supervisor. |

### End-to-end test packages

Packages that exist for their welded tests: each runs several libraries
together inside the build action (over loopback, or over the real local
filesystem); nothing depends on them.

| module | what it is |
|---|---|
| [`komira_http_tls_e2e`](../src/komira_http_tls_e2e/) | a real `komira_http_server` `HttpServer` against a real `komira_http_client` `HttpClient` in one process: an HTTP/1.1 GET over TLS checked byte for byte, the ALPN pivot to h2 on both sides, a 4 MiB plaintext response flushed through the server's buffered-write path (the server has no buffered-write path over TLS today), and the client refusing an untrusted root and a wrong server name while the server goes on serving. The library holds the shared TLS fixtures and the runner that steps the server on one thread while the client runs on another. |
| [`komira_formats_e2e`](../src/komira_formats_e2e/) | one nullable dataset written through the ORC, Avro OCF, JSONL and CSV (`CsvSink`) writers into a Hive tree with a non-ASCII partition value (`city=Zürich`), discovered over the real `LocalFs` with `EagerGlobDiscovery` and `PrunedHiveDiscovery`, and read back with projections, values, NULLs and partition values compared with the source; the CSV and JSONL bytes, the Avro OCF framing and the ORC stripe statistics are also checked against literals spelled from the format specs, since a writer/reader round-trip alone cannot see a shared misencoding. |

### Third-party code

C and C++ libraries are built from pinned source archives under
[`third_party/`](../third_party/), among them aws-lc, s2n-tls, snappy and sqlite, plus the
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
| HTTP, databases, object stores, file-system discovery, gRPC | komira_http_core, komira_http_client, komira_http_server, komira_db, komira_db_postgres, komira_db_sqlite, komira_objectstore, komira_grpc |
| storage formats: Parquet, text and row formats, Iceberg and CDC, an MVCC table store | komira_parquet, komira_csv, komira_iceberg, komira_table_store |
| execution and operators: pipelines and morsel dispatch, aggregation, joins, sort, top-N, window | the engine libraries |
| plan and optimizer: logical and physical planning, the plan wire format, the query optimizer | komira_compiler, komira_optimizer |
| SDK and SQL: the plan-carrier surface, UDFs, the Python package, the SQL front ends | komira_sdk |
| runtime: the async runtime, the job supervisor and its job report wire | komira_async, komira_job_supervisor, komira_job_report_proto |
| observability: logging and telemetry | komira_log |
| agents: MCP and local models | komira_mcp_server, komira_localmodel |
| cloud: the generated AWS and Google Cloud service clients, infrastructure providers, the service registry | the cloud SDK libraries (their cores, `komira_aws_core` and `komira_gcp_core`, and the generated `komira_aws_s3`, `komira_aws_apigatewayv2`, `komira_aws_dynamodb`, `komira_aws_dynamodbstreams`, `komira_aws_ec2`, `komira_aws_ecr`, `komira_aws_ecs`, `komira_aws_iam`, `komira_aws_lambda`, `komira_aws_logs`, `komira_aws_route53`, `komira_aws_scheduler`, `komira_aws_secretsmanager`, `komira_aws_sesv2`, `komira_aws_sns`, `komira_aws_sqs`, `komira_gcp_apigateway`, `komira_gcp_artifactregistry`, `komira_gcp_cloudresourcemanager`, `komira_gcp_compute`, `komira_gcp_iam`, `komira_gcp_logging`, `komira_gcp_monitoring_client`, `komira_gcp_serviceusage` and `komira_gcp_storage`, are in `src/`) |
| CI and deploy: the bundle model, apply, validate and rollout, the command line itself | kci (its `kci_*` libraries above are in `src/`) |
| message broker: connection handling and request dispatch | komira_kafka_server (its wire codec is in `src/`) |
| packaging: the shared-library ABI, the release machine | komira_so and the packaging rules |

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
