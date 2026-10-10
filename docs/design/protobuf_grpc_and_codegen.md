# Protobuf, gRPC and code generation: from a .proto file to Mojo on the wire

## What is it for, and what is out of scope?

These libraries let Mojo code exchange typed messages with other programs. A message is declared once in a `.proto` file. A code generator turns it into a Mojo struct, and a runtime writes that struct as protobuf binary or as proto3 JSON. An RPC layer carries it over gRPC or Connect.

The design rests on one idea: **a generated message is written once against two traits, and the wire format is a compile-time type parameter.** The generated `encode` and `decode` bodies call field primitives on an encoder or decoder type; the protobuf and JSON backends are two implementations of those traits.

| Library | Role |
|---|---|
| `tools/build/proto-codegen` | A Rust crate (`komira_proto_codegen`, 39 `.rs` files) holding the protoc plugins that write Mojo, and the `(komira.db.*)` options proto |
| `komira_protobuf` | Wire primitives: varints, zigzag, fixed and length-delimited fields, `PbFieldCursor` |
| `komira_proto_codec` | The `Serializable`, `WireEncoder` and `WireDecoder` traits and their protobuf and proto3-JSON backends |
| `komira_wkt` | The `google.protobuf` well-known types |
| `komira_grpc` | An RPC client for classic gRPC and Connect |
| `komira_connect` | A Connect-RPC server, and the envelope, status and codec code the client also uses |

Out of scope:

- The Buck2 rules that run the generators (`mojo_proto_library`, `mojo_db_proto_library`): see [the Mojo rules](../../tools/build/mojo/README.md). This doc describes what those rules produce.
- The HTTP/2 transport, TLS, and the `GrpcDispatch` seam in `komira_http_core/transport/grpc_emit.mojo`. This doc takes the HTTP packages (`komira_http_core`, `komira_http_client`, `komira_http_server`) as given.
- The generated AWS clients, which `aws-client-gen` writes from botocore models.
- The database layer that the `DbStorable` output compiles against.

## How does it work?

```
.proto --protoc--> CodeGeneratorRequest --> protoc-gen-mojo (Rust)
                                             lower.rs -> IR (ir.rs) -> emit.rs / emit_rest.rs
                                             --> one <stem>.mojo per .proto
generated struct: Serializable.encode[E] / decode[D]
  E, D = PbEncoder, PbDecoder (komira_proto_codec -> komira_protobuf)  or  JsonEncoder, JsonDecoder
generated <Svc>Client[C, P] --> GrpcClient[C] (komira_grpc) --> komira_http_client HttpClient
server side: ConnectService (komira_connect) conforms to komira_http_core's GrpcDispatch
```

### How does a .proto file become Mojo code?

`protoc` runs `protoc-gen-mojo` (`tools/build/proto-codegen/src/main.rs`), a standard plugin. It reads a `CodeGeneratorRequest` on stdin and writes a `CodeGeneratorResponse` on stdout. A request that fails to decode is reported in the response's `error` field, and so is one that fails to lower or emit; only an I/O failure makes the process exit non-zero.

`respond_with_bytes` in `tools/build/proto-codegen/src/lib.rs` parses the plugin parameter string into `PluginParameters` (`default_wire`, `default_protocol`, `package_prefix`, `roots`, `methods`, `messages_only` and `layout_probe`; an unknown key is an error naming all seven). `ProtocolMode::parse` refuses an unknown `default_protocol` with an error naming `grpc, connect, rest`; the default is `connect`, because `PluginParameters` defaults the string to `connect`. `ProtocolMode`'s own `Default` is `Grpc`, and its doc comment calls that the default, but the plugin never uses it. All three modes lower through `lower::lower_scoped` and `generate_scoped`. A `rest` target recovers `(google.api.http)` from the request bytes and emits through `emit_rest.rs`; `grpc` and `connect` go through `generate_with_routing`, which also recovers `(google.api.routing)`.

The request is decoded with `prost`, which drops extension options on a typed decode. `http_options.rs`, `routing_options.rs` and `db_options.rs` therefore recover `(google.api.http)`, `(google.api.routing)` and `(komira.db.*)` from the raw request bytes.

`lower.rs` builds the protocol-neutral IR in `ir.rs` (`IrModel`, `IrFile`, `IrMessage`, `IrField`, `IrEnum`, `IrOneof`, `IrService`, `IrMethod`). `emit.rs` writes it with one `Emitter`. `proto_to_mojo_path` maps each input file to one flat `<stem>.mojo`. The emitter iterates in declaration order, and the recursion analysis keeps its edges in a `BTreeSet`, so the output does not depend on hash order.

A reference to one of the 18 types in `wkt_symbol` (`lower.rs`), such as `google.protobuf.Timestamp`, becomes an import from `komira_wkt`. Any other imported type must be generated into the same package. `komira_wkt` defines all 18, including an opaque `Any`.

`mojo_proto_library` runs this plugin in the build: it runs protoc over its `srcs` and precompiles the generated directory. Generated modules import each other through their package name, so a `.proto` that imports another is compiled only with the imported file generated into the same package (`bundle_proto_deps`); `tools/build/tests/functional/proto` holds worked examples.

### What does a generated message look like?

A struct that conforms to `Serializable` (so `Copyable` and `Movable`, not `ImplicitlyCopyable`). `field_storage_type` in `emit.rs` maps a singular field to `T`, a proto3 `optional` field to `Optional[T]`, a `repeated` field to `List[T]` and a `map` to `Dict[K, V]`. A `oneof` arm is `Optional[T]`, and an `Int` member `_oneofN_case` records which arm is set. A singular message edge that closes a reference cycle, found by `recursion_breaking_edges`, is stored as a `List[T]` of zero or one element. Every generated message has an explicit `__deinit__`.

A proto enum becomes a struct holding `value: Int` that conforms to `ProtoEnum`: `number()` for the binary wire, `json_name()` for JSON, and `from_number`, `from_json_name` for decoding.

`encode` is a flat sequence of `enc.write_*_field(field_no, json_name, value)` calls. `decode` is one loop over `dec.next_field()` that matches the field number or JSON name and calls `dec.skip()` on anything else.

### How is a message encoded as protobuf or JSON?

Through `komira_proto_codec`. `Serializable` declares `encode[E: WireEncoder](self, mut enc: E)` and `decode[D: WireDecoder](mut dec: D) -> Self`, both `raises` (`wire_format.mojo`). Each field primitive takes both the field number and the JSON name, and each backend uses one of them. `codec.mojo` wraps the two backends: `encode_proto`, `decode_proto`, `encode_json`, `decode_json` and `decode_json_lenient`.

The protobuf backend is `proto_binary.mojo`:

- `PbEncoder` appends to a `List[UInt8]`. A nested message must be encoded before its length prefix can be written, so it is encoded into a buffer borrowed from `_scratch_pool` and the buffer is returned for reuse.
- A repeated scalar is written unpacked, one tag per element. `PbDecoder` accepts both the unpacked and the packed form.
- `PbDecoder.read_message` copies the sub-message bytes into an owned buffer and makes the child decoder through `_sub_decoder`. That refuses nesting beyond `PB_MAX_DECODE_DEPTH` (64) with an error starting `PB_DECODE_TOO_DEEP` (`ProtobufError.TOO_DEEP`).
- `skip` advances past an unknown field with `pb_skip_field`, and `expect_fields` is a no-op, because the binary wire keys on numbers and an unknown number must be skipped.

The JSON backend is `proto3_json.mojo`:

- `JsonEncoder` writes 64-bit integers as JSON strings, `bytes` as base64 (`base64_encode` and `base64_decode` from `komira_encoding`) and field names as the proto3 `jsonName`.
- `JsonDecoder` parses the document into a `JsonValue` tree (`komira_json`). It treats a `null` member as absent and accepts both the `jsonName` and the `.proto` field name.
- `decode_json` is strict. It raises `JsonError: unknown field`, `JsonError: unknown enum value` or, when one document spells a field both ways, `JsonError: duplicate field`.
- `decode_json_lenient` drops unknown keys and folds an unknown enum name to the zero value.

### What do the wire primitives check?

`komira_protobuf` has three modules, and its source imports only the standard library. `wire_types.mojo` holds the four wire types (`PB_WIRE_VARINT`, `PB_WIRE_FIXED64`, `PB_WIRE_LEN`, `PB_WIRE_FIXED32`) and the zigzag transforms. `writer.mojo` holds the `pb_write_*` encoders. `reader.mojo` holds the decoders, which raise errors starting `ProtobufError.MALFORMED`:

- `pb_read_varint` refuses a varint longer than 10 bytes or one that runs past the buffer.
- `pb_read_tag` refuses field number 0.
- `pb_read_len_field` refuses a payload that ends past the buffer.
- `pb_read_string` and `pb_read_bytes` check their span once, in `_pb_check_span`, before copying.

`PbFieldCursor[origin]` walks one message over a `Span` window. Its constructor refuses a window outside the buffer. After each tag, varint, fixed-width, length-delimited or skipped field, `_bound` refuses a value that ends past the cursor's own window, so a sub-message cannot read its parent's bytes. The packed readers are the exception: see the limits. An accessor called for the wrong wire type raises `ProtobufError.WIRE_MISMATCH`.

### How are well-known types encoded?

`komira_wkt` holds `Any`, `Timestamp`, `Duration`, `Empty`, `FieldMask`, `Struct`, `Value`, `ListValue`, `NullValue` and the nine scalar wrappers (`DoubleValue`, `FloatValue`, `Int64Value`, `UInt64Value`, `Int32Value`, `UInt32Value`, `BoolValue`, `StringValue`, `BytesValue`). Each message type conforms to `Proto3JsonWkt`, a refinement of `Serializable`. Its `encode` and `decode` give the ordinary field form: `Timestamp.encode` writes `seconds` and `nanos`. Its `write_proto3_json` and `read_proto3_json` give the special JSON form, which the JSON backend and `encode_json` and `decode_json` select at compile time for a well-known type; most types also have the string forms `to_proto3_json()` and `from_proto3_json()`. The special forms are: an RFC 3339 string for `Timestamp`, `"<seconds>[.<nanos>]s"` for `Duration`, the bare scalar for a wrapper, a comma-joined path string for `FieldMask`. `Any` is opaque: it has no type registry, keeps whichever form it was given, and refuses a transcode between the two. `NullValue` is a plain enum-like struct without `Serializable`. The library depends on `komira_proto_codec`, `komira_json`, `komira_encoding` and `komira_datetime`.

### How does a generated client make a gRPC call?

`emit_service` writes `struct <Svc>Client[C: Connector, P: Protocol]` holding one `GrpcClient[C]`. A unary method encodes the request with `PbEncoder` and calls `GrpcClient.unary_call_retrying` with the path `/<package>.<Service>/<Method>`, the per-call `reactor`, `token` and `now_us`, and the method's `RetryPolicy`. It then decodes the reply with `PbDecoder`. `GrpcClient` (`komira_grpc/client.mojo`) holds its `HttpClient[C]` in an `OwnedPointer` and has five call methods: `unary_call`, `unary_call_retrying`, `server_stream`, `client_stream` and `bidi_stream`. It moves opaque message bytes; its source imports neither `komira_proto_codec` nor `komira_protobuf`.

`P` is one of three `Protocol` conformers (`protocol.mojo`), which differ as follows:

| Conformer | Unary content type | Unary body | Stream end |
|---|---|---|---|
| `ProtocolGrpcProto` | `application/grpc` | 5-byte envelope | HTTP/2 trailers |
| `ProtocolConnectProto` | `application/proto` | bare | end-stream envelope |
| `ProtocolConnectJson` | `application/json` | bare | end-stream envelope |

The 5-byte envelope is one flags byte and a big-endian length (`komira_connect/envelope.mojo`). `ClientFramer` (`framing.mojo`) reassembles streamed envelopes from response frames and refuses one declaring more than `MAX_RECV_MESSAGE_SIZE` (4 MiB), naming `RESOURCE_EXHAUSTED`. The client sends `Grpc-Accept-Encoding: identity` and supports no compression: a compressed envelope is refused with `UNIMPLEMENTED` in a unary body (`grpc_decode_unary`) and ends a stream with `UNKNOWN`.

A failure is raised as an `Error` whose text starts `[grpc:<code>]` (`format_grpc_error_message`). The status comes from trailers, from a trailers-only header block, from a Connect error envelope, or from the HTTP status (`grpc_error_from_http_non_200`).

`CallOptions` carries an absolute `deadline_micros`; the header builders turn it into a relative `grpc-timeout` for every protocol. It also carries `metadata`, sent verbatim over gRPC and with a `grpc-metadata-` prefix over Connect, and `raw_metadata`, sent as bare headers such as `authorization`. For a method with a `(google.api.routing)` annotation, the generated code calls `match_path_template` and `build_routing_params` (`routing.mojo`) and sets `x-goog-request-params`.

### When does a gRPC call retry?

Two mechanisms, each bounded:

- **A connection-level fault.** The unary, server-streaming and client-streaming paths of `GrpcClient` re-issue a request when their shared gate, `_not_processed_retry_or_raise` (`komira_grpc/client.mojo`), accepts one of two errors:
  - a GOAWAY for a stream above the peer's last-processed stream id (`is_h2_goaway_unprocessed`), which proves the peer did not process the request;
  - any error whose message contains `HttpError[RETRYABLE_TRANSPORT]` (`is_h2_retryable_transport`, a substring test).

  The HTTP/2 driver raises `HttpError[RETRYABLE_TRANSPORT]` for an attempt that failed before any response byte arrived, such as a failed socket write or read, for an HTTP/2 REFUSED_STREAM reset, and for a connection that has spent its stream-id space (`komira_http_client/h2_client.mojo`); the HTTP/1.1 state machine raises it for the same zero-byte cases. REFUSED_STREAM and an exhausted stream-id space prove the peer did not process the request; zero response bytes alone does not (see limits). The gate ignores the method and its retry policy, and every `GrpcClient` request is a POST.

  Both kinds share one bound: at most 4 attempts (`_GOAWAY_RETRY_MAX_ATTEMPTS`) within a 90-second wall budget. A caller may state another budget with `GrpcClient.with_retry_budget_ms`; a value that is empty, not a number, zero or above 24 hours falls back to the default, so the budget can be stated but never removed. The module reads no environment. Any other error, including a GOAWAY at or below that id, is raised unchanged.
- **A status code, per method.** For a generated client, `derive_retry_class` (`tools/build/proto-codegen/src/retry_policy.rs`) decides at generation time. A streaming method is classed `None`, and the generated streaming path takes no status-code policy: only the unary arm of `emit_service` passes a `RetryPolicy` to `unary_call_retrying`. A unary method with `idempotency_level = IDEMPOTENT`, or with a `(google.api.http)` verb of `get`, `head`, `put` or `delete`, gets `RetryPolicy.idempotent()`, and every other unary method gets `none()`. `idempotent()` means 5 attempts, backoff from 1 s to 10 s at a factor of 1.3, on `UNAVAILABLE` only (`RETRY_CODES_AIP194`). A hand-written caller of `GrpcClient.unary_call_retrying` passes its own policy; `RetryPolicy.internal_on_alreadyexists_guarded()` is the opt-in policy that also retries `INTERNAL`, for a create whose caller tolerates `ALREADY_EXISTS`, and the generator never selects it.

`backoff_draw_ms` draws each wait uniformly from zero to the cap (full jitter). The `RetryPolicy` constructor clamps attempts to between 1 and 16, raises a multiplier below 100 percent to 100, and caps the maximum backoff at 120 s unless the initial backoff is larger, which it does not cap.

### How does the Connect server dispatch a call?

`ConnectService` (`komira_connect/service.mojo`) holds a list of unary methods, keyed by full path, and a list of streaming methods (server-streaming and client-streaming). The server has no bidirectional registration: `register_method`, `register_server_stream` and `register_client_stream` are the only three. A handler is a `ConnectHandlerFn`: a function from `(codec_id, request bytes)` to response bytes. `handle_request` picks the codec with `codec_id_for_content_type`, and `dispatch` (`dispatch.mojo`) runs one call:

1. Unwrap the request: a gRPC envelope, a gRPC-Web body, or the Connect body as is.
2. Call the handler, and map a raised error to a status with `parse_connect_error`.
3. Wrap the response in the same codec.

An unregistered path gets `NOT_FOUND`, and an unknown content type `UNIMPLEMENTED`.

The server speaks three codecs. `application/grpc` and `application/grpc+proto` select gRPC. `application/grpc-web` and `application/grpc-web+proto` select gRPC-Web. `application/json`, `application/connect+json`, `application/proto` and `application/connect+proto` all select `CODEC_ID_CONNECT_JSON`, because their framing and error envelope are the same.

`ConnectService` mounts on `komira_http_server` in two ways. It conforms to `GrpcDispatch` and `GrpcStreamDispatch`, so `HttpServer[ConnectService]` serves it on the HTTP/2 path, and `register_connect_wildcard` plus `dispatch_connect_request` route a `POST /*` through a `Router`.

Within komira only tests construct `ConnectService`. `komira_grpc` takes the envelope, status, deadline-encoding and error-envelope code from `komira_connect`.

### What do the other generators produce?

The crate carries more emitters than the build exposes. `tools/build/proto-codegen/BUCK` builds these generator binaries:

| Binary | Reads | Writes |
|---|---|---|
| `protoc-gen-mojo` | a `CodeGeneratorRequest` | messages and clients (above) |
| `protoc-gen-mojo-db` | a `CodeGeneratorRequest` | `<stem>_db.mojo` for each file with a `(komira.db.table)` message (`emit_dbstorable.rs`) |
| `aws-client-gen` | a validated botocore model and an operation list | one Mojo module (`emit_aws/`) |

The sources of three further binaries sit beside them (`main_openapi.rs`, `main_openapi_in.rs` and `main_index.rs`), and the library holds their emitters, but no Buck2 target builds them. Three more binaries serve the AWS generator's checks and are built: `aws-model-check`, `aws-conformance-gen` and `xml-equiv-verdicts`.

The `DbStorable` output is a struct per `(komira.db.table)` message with `column_names`, `column_types`, `to_row`, `from_row`, `insert_sql[D: SqlDatabase]` and `create_table_ddl` (with `_pg` and `_sqlite` variants). `aws-client-gen` refuses an empty `--operations` list and emits only the named operations. `emit_aws/` covers the `awsJson1_0`, `awsJson1_1`, `restJson1`, `restXml`, `awsQuery` and `ec2Query` protocols and refuses the others by name.

A `default_protocol = "rest"` target gets a different client from `emit_rest.rs`: `<Svc>Client[C: Connector]` over `HttpClient[C]`, with no `Protocol` parameter. A unary method with a `(google.api.http)` rule fills the path template from request fields and sends the body as proto3 JSON. A server-streaming method returns a `List` of its responses: over REST the whole stream is one HTTP response, a JSON array, which `komira_gcp_core.gcp_rest_stream_items` splits (raising an `{"error": ...}` element as a failed status). A client-streaming or bidirectional method has no REST mapping, and a rest target that names one is refused by name (generate it with `protocol = "grpc"`). It decodes each reply with `decode_json_lenient`, which skips a field the server added after the protos were pinned.

## Why is it built this way?

### Why is the generator a Rust protoc plugin?

**Decision.** The generators are Rust binaries, and the ones that read `.proto` files are standard `protoc` plugins.

**Because.** A plugin's input is itself a protobuf message, a `CodeGeneratorRequest` with nested descriptors. Rust has `prost` and `prost-types` to decode it into typed structs, while a Mojo plugin would first have to hand-decode that request. The plugin's job is text emission, so the target language does not matter.

**Alternatives weighed.**

- A plugin written in Mojo: it needs a descriptor decoder before any generation logic exists.
- A checked-in binary written in another language: it is platform-specific, where a Rust binary built from source by the Buck2 Rust rules is a hermetic tool on every platform the build supports.

**Revisit if.** Mojo gains a maintained descriptor library, or the plugin needs to run where no Rust toolchain can be built.

### Why is the wire format a compile-time parameter?

**Decision.** `Serializable.encode` and `decode` take the encoder or decoder type as a trait-bound parameter, so each format is a separate monomorphized body.

**Because.** The `wire_format.mojo` header requires the codec path to have no runtime branch on the format and no trampoline, function pointer or vtable. An associated encoder type (`W.Sink`) is not materialized at the nested-message call site, `write_message_field[M]` calling `v.encode[W]`. Passing the encoder itself as the parameter needs no associated type.

**Alternatives weighed.**

- One `WireFormat` trait with associated `Sink` and `Source` types: rejected by the compiler at the recursive call.
- A runtime format flag: a branch on every field, and the body is no longer one shape.

**Revisit if.** Associated types materialize at cross-trait call sites, or a format needs a field shape the shared primitives cannot express.

### Why is a recursive field a List and not an OwnedPointer?

**Decision.** A field on a reference cycle is stored as `List[T]` holding zero or one element.

**Because.** A struct cannot contain itself inline, so the edge needs heap indirection. `Serializable` requires `Copyable`, and `OwnedPointer` is single-owner and not `Copyable`. A `List` is a finitely sized, copyable heap reference, so the struct stays `Serializable` with no hand-written copy constructor.

**Alternatives weighed.**

- `OwnedPointer[T]`: the struct stops being `Copyable` and so cannot be `Serializable`.

**Revisit if.** `Serializable` drops `Copyable`, or Mojo gains a copyable owning box.

### Why does the JSON decoder refuse unknown fields by default?

**Decision.** `decode_json` refuses an unknown key, an unknown enum name and a field spelled twice; `decode_json_lenient` is a separate entry point.

**Because.** Refusing unknown fields is the proto3-JSON spec's stated parser default. A typo in a hand- or model-written document would otherwise decode to a message with defaults and no error (the `decode_json` docstring). `expect_fields` exists because `skip()` never sees a key whose value is `null`, and cannot tell that two keys name one field.

**Alternatives weighed.**

- Lenient by default, like the protobuf binary wire: hides typos in authored documents.
- A strictness flag with a default: `decode_json_lenient` is named so the silent mode is chosen explicitly.

**Revisit if.** JSON becomes a forward-compatible exchange format between builds with different schemas, where lenient decoding is the safe direction.

### Why is the retry policy derived from the HTTP verb?

**Decision.** The generator derives each method's `RetryPolicy` from a declared idempotency level or the `(google.api.http)` verb, and retries only `UNAVAILABLE` by default.

**Because.** Replaying a call that may already have run can create a second resource, so the question is whether replaying the verb is safe (the `komira_grpc/retry.mojo` header). RFC 9110 defines GET, HEAD, PUT and DELETE as idempotent and POST and PATCH as not. AIP-194 names `UNAVAILABLE` as the one retryable code, and `INTERNAL` gives no guarantee that the call did not happen.

**Alternatives weighed.**

- One retry policy for every method: replays creates.
- Hand-written retries at call sites: each fixes one verb.
- `idempotency_level` alone: `retry.mojo`'s header says the field is rarely set in published Google APIs.

**Revisit if.** Services you generate for routinely declare `idempotency_level`, or a service documents that `INTERNAL` means the call was not processed.

### Why do the client and the server share komira_connect?

**Decision.** The envelope, status codes, deadline encoding and Connect error envelope live in `komira_connect`, and `komira_grpc` imports them.

**Because.** The client and server use the same framing and status model, and one definition cannot drift from a copy. The dependency runs from `komira_grpc` to `komira_connect`, so the `[grpc:N]` error format is defined once, in `komira_connect.status.format_grpc_status_error`.

**Alternatives weighed.**

- A copy in each library: two definitions of a prefix that parsers scan for.

**Revisit if.** The server surface is retired, or the two sides need framing rules that differ.

## What must always hold?

- **A field read through `PbFieldCursor` stays inside its message window, and a malformed field raises.** The primitives check spans against the buffer and `_bound` checks each field against the window. The packed readers do not (see limits). `test_protobuf_roundtrip.mojo` checks the wire guards; no test is dedicated to the window bound.
- **The protobuf codec reads what an independent implementation writes.** Enforced by `test_protobuf_prost_crosscheck.mojo`, which decodes bytes encoded by `prost` 0.13.
- **Protobuf decoding refuses nesting beyond 64.** Nothing in komira tests it yet.
- **Strict JSON decoding refuses unknown keys, unknown enum names and a field spelled twice.** Enforced by `test_proto_codec_proto3_json_strictness.mojo`.
- **Generated code compiles and a generated struct follows its `.proto`.** Enforced by the proto functional test of the build tooling (`tools/build/tests`, test 23): the generated `Person` follows a renamed field, and a package missing a bundled dependency fails to compile.
- **A generated client never retries a streaming method, or a unary method whose verb is not proven idempotent, on a status.** Written as unit tests in `retry_policy.rs`, which run as `//tools/build/proto-codegen:komira_proto_codegen_unit`, the target the codegen library and its binaries are published behind. A hand-written caller sets its own `RetryPolicy`, and nothing checks that choice.
- **A connection-level re-issue happens only after a GOAWAY above the peer's last-processed stream id or a `RETRYABLE_TRANSPORT` fault, and is bounded.** Enforced by `test_goaway_unprocessed_retry.mojo` (the GOAWAY arm), `test_retryable_transport_reissue.mojo` (the transport arm) and `test_client_stream_goaway_reissue.mojo`. The transport arm does not prove the peer left the request unprocessed (see limits).
- **A client refuses a streamed message over 4 MiB.** Enforced by `test_grpc_truncation_and_terminal.mojo`.
- **Ownership.** `GrpcClient` takes the reactor, cancellation token and clock reading per call, and holds no borrowed pointer. Not enforced by a test.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `tools/build/proto-codegen/src/main.rs`, `lib.rs`, `plugin.rs` | The plugin shim, parameters and routing | `respond_with_bytes`, `PluginParameters`, `ProtocolMode`, `CodeGeneratorRequest` |
| `tools/build/proto-codegen/src/lower.rs`, `ir.rs` | Descriptors to IR; the IR | `lower`, `recursion_breaking_edges`, `wkt_symbol`, `IrModel` |
| `tools/build/proto-codegen/src/emit.rs`, `emit_rest.rs` | Mojo messages and clients | `Emitter`, `emit_service`, `field_storage_type`, `proto_to_mojo_path` |
| `tools/build/proto-codegen/src/retry_policy.rs` | Per-method retry class | `derive_retry_class`, `RetryClass` |
| `tools/build/proto-codegen/src/emit_dbstorable.rs`, `emit_index.rs`, `openapi_emit.rs`, `openapi_in.rs`, `emit_aws/` | The other emitters and front-ends | |
| `tools/build/proto-codegen/BUCK`, `db/options.proto` | The built binaries; the `(komira.db.*)` options | `protoc-gen-mojo`, `protoc-gen-mojo-db`, `aws-client-gen`, `db_options` |
| `src/komira_protobuf/reader.mojo`, `writer.mojo`, `wire_types.mojo` | Wire primitives | `pb_read_varint`, `pb_skip_field`, `PbFieldCursor`, `pb_write_message_field` |
| `src/komira_proto_codec/wire_format.mojo` | The traits | `Serializable`, `WireEncoder`, `WireDecoder`, `ProtoEnum`, `FieldKey` |
| `src/komira_proto_codec/proto_binary.mojo`, `proto3_json.mojo`, `codec.mojo` | The backends and entry points | `PbEncoder`, `PbDecoder`, `JsonEncoder`, `JsonDecoder`, `encode_proto`, `decode_json` |
| `src/komira_wkt/*.mojo` | Well-known types | `Timestamp`, `Duration`, `Struct`, `FieldMask` |
| `src/komira_grpc/client.mojo`, `protocol.mojo`, `framing.mojo`, `retry.mojo` | The client | `GrpcClient`, `Protocol`, `ClientFramer`, `RetryPolicy` |
| `src/komira_grpc/error.mojo`, `metadata.mojo`, `call_options.mojo`, `routing.mojo` | Status, metadata, options, routing header | `GrpcError`, `RpcMetadata`, `CallOptions`, `match_path_template` |
| `src/komira_connect/service.mojo`, `dispatch.mojo`, `server_integration.mojo` | The server | `ConnectService`, `dispatch`, `codec_id_for_content_type` |
| `src/komira_connect/envelope.mojo`, `status.mojo`, `codec_*.mojo`, `deadline.mojo` | Shared framing and status | `split_envelopes`, `grpc_encode_unary`, `parse_grpc_timeout` |

Entry points:

- **Public API:** `encode_proto`, `decode_proto`, `encode_json`, `decode_json` in `src/komira_proto_codec/codec.mojo`: serialize a generated or hand-written `Serializable`.
- **Public API:** a generated `<Svc>Client[C, P]` over `GrpcClient` in `src/komira_grpc/client.mojo`: call a service.
- **Execution starts at:** `main` in `tools/build/proto-codegen/src/main.rs` for generation; `GrpcClient.unary_call` for a call; `dispatch` in `src/komira_connect/dispatch.mojo` for a served call.

## How is it tested?

Each library lists its tests in `test_srcs` (files in `src/<library>/tests/`), and they run when the library is built (see [the Mojo rules](../../tools/build/mojo/README.md)):

```sh
./buck2 build //src/komira_protobuf:komira_protobuf //src/komira_proto_codec:komira_proto_codec \
  //src/komira_wkt:komira_wkt //src/komira_grpc:komira_grpc //src/komira_connect:komira_connect
```

The tests include:

| Test | Covers |
|---|---|
| `test_protobuf_roundtrip.mojo`, `test_protobuf_prost_crosscheck.mojo` | Primitives; decoding `prost` output |
| `test_proto_codec_roundtrip.mojo`, `test_proto_codec_proto3_json_conformance.mojo`, `test_proto_codec_proto3_json_strictness.mojo`, `test_proto_codec_json_nonascii_roundtrip.mojo`, `test_copy_hazard.mojo` | Both backends; the JSON mapping and its refusals; a generated message copied as a list element |
| `test_wkt_runtime.mojo`, `test_wkt_json_codec_path.mojo`, `test_wkt_plain_arms.mojo`, `test_wkt_list_copy.mojo`, `test_wkt_timestamp_text.mojo` | Well-known types in both forms, and through the codec's message arms |
| `komira_grpc`'s `test_L5_*.mojo`, `test_unary_status_retry.mojo`, `test_goaway_unprocessed_retry.mojo`, `test_retryable_transport_reissue.mojo`, `test_client_stream_goaway_reissue.mojo`, `test_e2e_*.mojo` | Client framing, headers, metadata, routing, streams, retries, a full loop against `ConnectService` |
| `komira_connect`'s `test_L5_*.mojo`, `test_e2e_*.mojo`, `test_server_integration.mojo`, `test_grpc_timeout_conformance.mojo`, `test_grpc_timeout_enforced.mojo` | The three server codecs, unary, server-streaming and client-streaming calls, the router mount, `grpc-timeout` enforcement on the HTTP/2 serve loop. Bidirectional streaming is covered at the framing level only (`test_e2e_bidi.mojo` simulates framing and never touches `ConnectService`) |

The code generator is exercised by the build tooling's end-to-end tests (`tools/build/tests/run_tests.sh`, test 23, from `proto_tests.sh`): generated packages compile and pass `test_person`, `test_team` and `test_tasks_db`, the generated struct follows the `.proto`, `bundle_only` selects only the named files, and two uncached builds produce the same bytes. The AWS generator has its own golden checks in `tools/build/tests/functional/aws_codegen`. The unit tests inside the Rust sources (for example in `retry_policy.rs`) run as `komira_proto_codegen_unit`, and the codegen library and the generator binaries cannot build unless they pass.

Not tested: no test sends a generated client's call with `ProtocolConnectJson`, no test feeds `JsonDecoder` deeply nested input, no test checks protobuf decoding's depth bound, and no test runs a third-party gRPC client against `ConnectService`.

## What are its limits and open questions?

- **Limit:** a generated client encodes with `PbEncoder` whatever `P` is. Instantiated with `ProtocolConnectJson`, it would send protobuf bytes labelled `application/json`.
- **Limit:** the `default_wire` plugin parameter is parsed but no emitter reads it. The wire follows the protocol mode: protobuf for `grpc` and `connect`, JSON for `rest`.
- **Limit:** `komira_wkt.Any` is opaque. With no type registry it cannot transcode its payload between the protobuf and JSON forms, and refuses to, naming the type.
- **Limit:** JSON decoding's nesting bound is the parser's, not the decoder's. `komira_json.parse_json_value` refuses nesting beyond `JSON_DEFAULT_MAX_DEPTH` (128) with a non-recursive parser, and `JsonDecoder.read_message` makes a sub-decoder with no counter of its own. No test feeds `JsonDecoder` deeply nested input.
- **Limit:** a generated message has no member for unknown fields. Decoding skips them, so decoding and re-encoding drops them.
- **Limit:** a `Proto3JsonWkt` type reaches its special JSON form only through the codec's message arms and the top-level `encode_json` and `decode_json`; a hand-written `encode[JsonEncoder]` body that bypasses them writes the ordinary field form.
- **Limit:** `GrpcClient`'s re-issue on `HttpError[RETRYABLE_TRANSPORT]` can run a non-idempotent call twice. The HTTP/2 read branch raises it when a read fails before any response byte, even after the whole request was written, and the POST goes out again. `komira_http_client`'s HTTP/1.1 replay rule, `_h1_pooled_retry_is_safe` (`komira_http_client/client.mojo`), would refuse it: after a retryable-transport check, it requires that nothing was written, OR a safe verb, OR an idempotency key.
- **Limit:** compressed gRPC messages are refused; only `identity` encoding is supported.
- **Limit:** `MAX_RECV_MESSAGE_SIZE` guards streamed envelopes only: `ClientFramer` is the only code that applies it, and `komira_connect` declares no size limit of its own.
- **Limit:** the server enforces `grpc-timeout` only for `application/grpc` and `application/grpc+*` calls on the HTTP/2 serve loop (`komira_http_core/transport/grpc_timeout.mojo`). The deadline is fixed when the request's HEADERS block arrives. A malformed value is answered `:status 400`, `grpc-status 13`, `malformed grpc-timeout: <reason>`, and a deadline already past when the HEADERS block completes (a zero value) `:status 200`, `grpc-status 4`, `context deadline exceeded`, both without running the handler (grpc-go's server behaviour; its early abort for the second). A deadline that runs out while the body arrives, or while the handler runs, gets the same `grpc-status 4` answer; that is komira's choice, since grpc-go's timer resets the stream with `RST_STREAM(CANCEL)`. The handler runs synchronously and cannot be interrupted: if the deadline passes while it runs, its response is dropped for `DEADLINE_EXCEEDED`, but its side effects stand, and the handler never sees its deadline. The loop has no per-stream timer, so a request whose body is still arriving is answered only when the body ends. gRPC-Web calls are not enforced, and `Connect-Timeout-Ms` is parsed (`parse_connect_timeout_ms`) but not enforced. The client sends `grpc-timeout` on Connect calls too, where the Connect protocol names `Connect-Timeout-Ms`.
- **Limit:** a Connect handler receives `CODEC_ID_CONNECT_JSON` for both `application/json` and `application/proto` bodies, so the codec id does not tell it the payload format.
- **Limit:** the `WireEncoder` and `WireDecoder` traits cannot express REST-XML, which needs attributes, a name for each repeated item and more than one name per field, so an XML binding has to be a separate model-driven one (`emit_aws/xml_codec.rs` is that binding for the AWS generator).
- **Limit:** the `DbStorable` output imports `komira_db`. No library in this tree provides it, so the `mojo_db_proto_library` example in the build tests is the only place it is compiled.
- **Limit:** the packed readers do not check their elements against the block. `PbFieldCursor.read_packed_varints` and `read_packed_sint64` bound the block, then call `pb_read_packed_varints` and `pb_read_packed_sint64`, which loop `pb_read_varint` while the position is below the block end; `pb_read_varint` is bounded only by the whole buffer, so a last varint that straddles the block end reads the bytes after it and does not raise. `pb_read_packed_fixed32` and `pb_read_packed_fixed64` drop a trailing partial element instead of raising. All four are public exports, and only tests call them. `komira_proto_codec`'s `PbDecoder` bounds its own packed reads (`_packed_bound`).
- **Limit:** several module headers disagree with the code. `komira_proto_codec`'s names a backend `ProtoBinaryWire` and a test header names `Proto3JsonWire`, neither of which exists; `komira_grpc`'s protocol header and `komira_connect`'s JSON codec header name `Proto3JsonWire` too. `komira_grpc`'s and `komira_connect`'s sources import nothing from `komira_proto_codec`.
- **Open question:** whether to keep the Connect server surface (`ConnectService`, the gRPC-Web codec), which only tests use, or replace it with direct `GrpcDispatch` implementations. A production service built on it would decide.
