# HTTP: client and server on one reactor

## What is it for, and what is out of scope?

The HTTP layer is three packages. `komira_http_core` (`src/komira_http_core`) holds the codecs, the TLS layer and the stream seam that the server and the client share. `komira_http_client` and `komira_http_server` are the HTTP/1.1 and HTTP/2 client and server; each depends on the core and neither on the other. Neither the server nor the client starts a thread: each is driven by a `Reactor` from `komira_async` on the calling thread. A **reactor** waits on many sockets at once and reports each ready one as a completion.

The design idea is **one event loop per server, and I/O as explicit state**. A handler receives the server's own reactor, so its I/O runs on the loop that serves HTTP. Only the suspendable and erased serve methods let a handler that waits on a database or an outbound call park while the loop serves other connections. In the plain and chained methods, the dispatcher returns its response synchronously.

Terms used below:

- A **dispatcher** is the application's request handler: a type conforming to `RequestDispatcher` or one of its variants.
- A **connector** dials a connection and returns a **stream**, a non-blocking byte stream conforming to `IoStream`.
- A **serve round** handles one reactor event on one connection.

The library depends on `komira_async`, `komira_collections`, `komira_libc`, `komira_obs`, `komira_uuid`, the vendored s2n-tls (`third_party/s2n-tls`) and `komira_runtime_paths`.

Out of scope:

- The reactor, the `Runtime` trait and parking. These belong to `komira_async`.
- `komira_crypto`, which this TLS layer does not use: [crypto and TLS](crypto_and_tls.md).
- Building the vendored s2n-tls and AWS-LC archives: [the C and C++ rules](../../tools/build/mojo/README.md).
- A gRPC client, a Connect-RPC server and the object-store clients. They build on this transport and are described with their own libraries.

## How does it work?

```
server:  listener fd ─► Reactor.poll_completions ─► accept / serve round
            serve round: recv ─► parse_request_head ─► [MiddlewareChain] ─► dispatcher.dispatch[RT](reactor, req)
                         ─► serialize_response[_framed] ─► send, or buffer until writable
client:  HttpClient[C].send_buffered ─► pool probe ─► (miss) resolve + C.connect ─► stream
            stream.negotiated_protocol() == h2 ? h2 driver : h1 OutboundDriver ─► response
```

### How does an HTTP server built on komira_http_server serve a request?

`HttpServer[G]` (`src/komira_http_server/server.mojo`) owns one listener, one `Reactor[NoopSink]` (epoll on Linux, kqueue on macOS), a `Slab[ConnEntry]` of connections and a 4,096-byte read buffer (`REQ_BUF_BYTES`). `HttpServerConfig` sets the port (0 asks the kernel for one), the backlog (4,096), the parser limits and `Expect: 100-continue` handling, and binds to 127.0.0.1 unless built with `with_port_bind_any`. `G` is the gRPC dispatcher and defaults to `NoopGrpcDispatch`.

A caller drives the loop one poll at a time. Each of the five `serve_one_iteration*` methods runs `poll_completions` once, accepts on the listener's event, and runs a serve round for each ready connection:

| Method | Handler | Protocols |
|---|---|---|
| `serve_one_iteration_dispatch[D, RT]` | `D: RequestDispatcher` | plaintext HTTP/1.1 |
| `serve_one_iteration_dispatch_chained[D, M, RT]` | `MiddlewareChain`, then `D: CtxRequestDispatcher` | plaintext HTTP/1.1 |
| `serve_one_iteration_dispatch_suspendable[SD, RT]` | `SD: SuspendableDispatcher`; handlers may park | plaintext HTTP/1.1 |
| `serve_one_iteration_dispatch_erased[ED, RT]` | `ED: ErasedDispatcher` | plaintext HTTP/1.1 |
| `serve_one_iteration` | canned responses, or `G` for gRPC | HTTP/1.1, TLS, HTTP/2 |

The suspendable and erased methods also take a required `driver` argument that the caller supplies: a `SuspendableHandlerDriver[NoopSink, SD.Handler]` or an `ErasedHandlerDriver[NoopSink, ED.Resp]`. Comptime asserts require `SD.Handler.Resp == HttpResponse` and `ED.Resp == HttpResponse`.

The four dispatch methods close any connection that is TLS or HTTP/2. Only `serve_one_iteration` accepts TLS, and it never calls an application handler for plain HTTP: HTTP/1.1 gets a fixed `200 Hello, World!` (through `MiddlewareChain.run_with_canned` if one is installed), and HTTP/2 is described [below](#how-are-http2-and-grpc-served).

The dispatcher is passed to each call, not stored. `RequestDispatcher.dispatch[RT](mut reactor, var req) raises -> HttpResponse` owns routing and error mapping; a raise becomes a 500. `serve_one_iteration_dispatch` requires `RT.Sink == NoopSink` with a `comptime assert`, so the reactor it lends is the one it polls.

`GcpServerlessEntry` (`src/komira_http_server/serving/serverless_entry.mojo`) is the ready-made loop for a platform that routes requests to a listener. It holds one listen port, which defaults to 8080 and which a binary parses from its own flag with `parse_serve_port`: the library reads no environment. `serve` calls `tls_init()`, binds 0.0.0.0, and calls `serve_one_iteration_over` with a 50 ms poll timeout forever; `serve_chained` does the same through the chained round. Its runtime type is `GcpCloudRunRuntime[NoopSink]`, imported from `komira_async` (`komira_async.runtime.gcp_cloud_run_runtime`), which the HTTP packages do not define; it is used only as `RT`.

### How is an HTTP/1.1 request parsed and a response framed?

`parse_request_head` (`src/komira_http_core/codec/h1/parser.mojo`) validates one request head in the read buffer and returns a `HeadersParseOutcome`. Header names are lowercased, and repeated headers are joined with `, `. It refuses request smuggling shapes: two `Content-Length` headers, even equal ones; `Content-Length` together with chunked; and a `Transfer-Encoding` without the `chunked` token.

`ParseLimits` defaults (`src/komira_http_core/codec/h1/limits.mojo`) are 100 headers, 8,192 bytes per header line and per request line, 65,536 bytes of headers, and a 10 MiB body. `_kind_to_status` maps each refusal to a status: 414 for a long request line, 431 for header overflow (and for an oversized chunked trailer), 413 for a large body, 417 for an unsupported expectation, 505 for an unsupported version, and 400 for the rest. The round writes that error response.

After the head, the round drains a `Content-Length` body with `accumulate_body_remainder`, or a chunked body with `accumulate_chunked_body` (`src/komira_http_server/dispatch.mojo`), both into `req.body`. The plain round then parses the next pipelined request in the buffer.

Response framing is decided by the transport. A handler calls `HttpResponse.mark_chunked()` to ask for chunked transfer encoding. `response_may_be_chunked(status, http_version_minor, is_head_request)` (`src/komira_http_core/codec/response_framing.mojo`) refuses it for an HTTP/1.0 client, a HEAD request, a 1xx, 204 or 304. `serialize_response_framed` then writes either 64 KiB chunks (`append_chunked_body`) or a `Content-Length` body.

A write that would block keeps the rest in the connection's entry, and the next writable event sends it (`resume_pending_write`).

### How are HTTP/2 and gRPC served?

HTTP/2 is served only after TLS negotiates `h2` by ALPN, inside `serve_one_iteration`. The connection gets an `H2ConnectionState`, and `serve_read_round_h2` (`src/komira_http_server/serve_h2.mojo`) checks the 24-byte client preface, sends its SETTINGS (at most 50 concurrent streams), decodes frames and validates request headers. There is no cleartext HTTP/2 (h2c) server.

A request whose content type `is_grpc_content_type` accepts goes to the server's `G`. `GrpcDispatch.dispatch_grpc(path, content_type, request_body) -> GrpcResponse` handles unary calls, and `GrpcStreamDispatch.dispatch_grpc_stream` handles streaming ones, whose `GrpcStreamResponse.messages` is a complete `List[List[UInt8]]`. `emit_grpc_response` and `emit_grpc_stream_response` (`src/komira_http_core/transport/grpc_emit.mojo`) write the result.

Any other HTTP/2 request is matched against the server's `Router`: a match answers `200 Hello from HTTP/2!` and a miss answers 404.

### How do middleware and routing work?

`MiddlewareChain` (`src/komira_http_server/middleware/chain.mojo`) holds four optional built-ins, `ErrorMappingMiddleware`, `CorsMiddleware`, `TracingMiddleware` and `LoggingMiddleware`, and runs one user middleware that the caller passes in. `run_before_legs` calls `before` on CORS, tracing, logging, then the user middleware; a `before` that returns a response skips the rest and the handler. `run_after_legs` calls `after` in reverse order on whatever response resulted, and skips the user middleware's `after` when its `before` did not run. A raise is turned into a response by `map_chain_error`. `MetricsMiddleware` and `PairMiddleware` (`middleware/metrics.mojo`) are user-slot middleware: the first reports one `RequestMetric` per request to a `MetricsSink`, and the second runs two middleware in one slot, and nests to compose more.

The library has no identity or authorization model of its own. `RequestContext` carries an optional `Principal` and an `attributes` string map; an embedder's middleware fills them and its dispatcher reads them. A `Principal` (`src/komira_http_server/middleware/middleware.mojo`) holds a `scheme` (`jwt` or `session`; its constructors raise on any other value), an opaque `subject` string, a `Claims` string map, and an optional `PresentedCredential`, the credential the request presented. `PresentedCredential` is not `Writable`: `redacted()` returns a fixed text and `expose()` is the only public way to read the value; the `_value` field is private by convention only, which Mojo does not enforce. `tests/test_no_product_vocabulary.mojo` fails the build if a library source names a banned word or an early year-month (a year 2024 or 2025 with any month, or 2026 with month 01 to 08; see `early_date_at`; earlier years are not matched); the word list (`banned_words()`) and the date rule (`early_date_at`) are in the test-only package `src/tests/helpers/komira_test_vocabulary`.

In `serve_one_iteration_dispatch_chained`, the dispatcher is a `CtxRequestDispatcher`: `dispatch_with_ctx` also receives the `RequestContext` the chain filled in, for example the `Principal` an authentication middleware attached.

Two routers exist. `Router` (`src/komira_http_server/routing/router.mojo`) maps a method and path to an integer handler id; patterns hold static segments, `:name` parameters and a `*` that matches the rest of the path and must be the last segment. `AppRouter[*Routes]` (`src/komira_http_server/routing/route.mojo`) is a `RequestDispatcher` over a compile-time pack of `Route` types, each with a `METHOD`, a `PATTERN` and a `handle[RT]` method. It matches through a `Router`, fills `req.path_params`, and answers 405 for a known path with the wrong method and 404 for an unknown path.

### How does the HTTP client send a request?

`HttpClient[C: Connector]` (`src/komira_http_client/client.mojo`) is generic over its connector. `KernelTcpConnector` (`src/komira_http_core/transport/kernel_tcp.mojo`) dials TCP and returns a `TcpIoStream`. `TlsConnector[U]` (`src/komira_http_client/tls_connector.mojo`) wraps another connector, runs the s2n client handshake with SNI and ALPN, and returns a `TlsClientStream[U.Stream]`.

Each send method is generic over a `Runtime` and takes the caller's reactor. The buffered paths (`send_buffered`, `call` and `call_pooled`) read the stream's `negotiated_protocol()`: `NEGOTIATED_HTTP_2` sends through the HTTP/2 driver, and anything else through the HTTP/1.1 `OutboundDriver`.

The main calls:

- `send_buffered` returns the whole body in a `BufferedResponseBody`; like `call` and `call_pooled`, it picks the HTTP/2 or HTTP/1.1 driver from the stream's ALPN result.
- `send` returns a `RecvRingBody` that the caller pulls with `poll_frame`.
- `get_range` sends a `Range` GET and raises `HTTP_ERROR_RANGE_NOT_HONORED` if the server answers 200 instead of 206.
- `send_buffered_batch` sends K requests to one origin as K streams on one HTTP/2 connection.
- `send_grpc_pooled` multiplexes HTTPS gRPC calls on a pooled HTTP/2 connection, and `send_grpc_pooled_h2c` does the same over cleartext HTTP/2 with prior knowledge.
- `call`, from the `HttpService` trait (`src/komira_http_client/service.mojo`), is the buffered surface that `HttpLayer` wrappers such as `RetryLayer`, `TimeoutLayer` and `RedirectLayer` wrap.

Errors raise `HttpError` (`src/komira_http_client/error.mojo`) with a kind such as `HTTP_ERROR_CONNECT_FAILED`, `HTTP_ERROR_TLS_VERIFY_FAILED`, `HTTP_ERROR_RETRYABLE_TRANSPORT`, `HTTP_ERROR_EOF_MID_RESPONSE`, `HTTP_ERROR_BODY_TOO_LARGE` or `HTTP_ERROR_TIMEOUT`. `HttpTransport` (`src/komira_http_client/http_transport.mojo`) is a smaller seam: one request with a single auth header and a string body. Its production conformer is `TlsHttpTransport`, and `ScriptedTransport` records calls for tests.

### How are client connections pooled and reused?

An `HttpClient` keeps up to four caches, each made on first use: a `PerCorePool` for HTTP/1.1, an `H2ClientPool` for HTTP/2, one cached idle HTTP/1.1 connection, and a pool of idle streaming connections. `PerCorePool` holds buckets keyed by `PoolKey` (scheme, host, port, verify mode and negotiated ALPN) and has no locks or atomics. `PoolSizingKnobs.defaults()` allows 32 connections and 16 idle ones per bucket, and evicts a connection idle for more than 60 s.

A reused HTTP/1.1 connection that fails is re-sent once, on a fresh connection, only when `_h1_pooled_retry_is_safe` allows it. Three terms must hold:

1. The connection came from the pool.
2. The error proves the server sent no response bytes (`is_h2_retryable_transport`).
3. No request byte reached the wire, or the method is GET, HEAD or OPTIONS (`_h1_method_is_replay_safe`), or the request carries a non-empty `Idempotency-Key` or `X-Idempotency-Key` header.

A `408 Request Timeout` read off a reused connection is discarded, and the request is sent once more on a fresh connection when its body can be sent again. A 408 on a connection this request dialed is returned. DNS is resolved only when a dial is about to happen (`_resolve_dial_ip_be`), so a pooled hit never blocks on `getaddrinfo`.

`TlsConnector` keeps a `SessionCache` of TLS session tickets per origin (1,024 entries by default, evicted least recently used), so a later dial can resume a session.

### How are outbound calls bounded in time?

A request budget is the time one outbound call may take. `HttpClientConfig.defaults()` is for a process with no containing request deadline, a job, a pod or a command-line tool, and gives 600 s. A process that serves requests under a platform deadline builds its client with `HttpClientConfig.for_serving_ceiling(ceiling_us)` instead, and `HttpClient.with_defaults` is only for the first kind.

`outbound_budget_us(requested_us, ceiling_us)` (`src/komira_http_client/outbound_budget.mojo`) is the rule. A request inside the ceiling keeps its budget; one over it is clamped to the ceiling minus a 5 s reserve; a request of zero gets that largest permissible budget. `serving_request_ceiling_us` computes the ceiling from the platform's identity values, which the caller passes in as strings because the library reads no environment. A Cloud Run job marker (`CLOUD_RUN_JOB`, `CLOUD_RUN_EXECUTION`) means no ceiling and is checked first. Otherwise `K_SERVICE`, `K_REVISION` or `K_CONFIGURATION` mean a Cloud Run service, whose request ceiling is 300 s, so the budget is 295 s. The AWS Lambda runtime API and every other process answer no ceiling.

The HTTP/2 driver has its own bounds. One park waits at most 250 ms (`_H2_PARK_DEADLINE_US`), and one `drive_h2_streams_to_completion` call defaults to a 120 s wall (`_H2_DRIVE_DEFAULT_WALL_US`). After 15 s with no bytes read while a stream awaits its response, the driver sends a PING, and a PING unanswered for 15 s ends the call with a timeout.

### How does TLS work?

The TLS layer is [s2n-tls](https://github.com/aws/s2n-tls), built by `third_party/s2n-tls` against `third_party/aws-lc` and called through FFI. In `src/komira_http_core/tls/`, `ffi.mojo` declares the C functions and `s2n_shim.mojo` wraps them. `_S2nConfigHandle` and `_S2nConnectionHandle` own the raw pointers and free them on destruction. `TlsConfig` holds its handle in an `ArcPointer`, so `.copy()` shares one `s2n_config_t`.

`TlsConfig` loads a certificate, sets ALPN protocols and cipher preferences, adds or wipes trusted PEM roots, turns verification on or off, and enables session tickets. `TlsConnection` binds an existing socket with `bind_fd`, which calls `s2n_connection_set_fd`, and exposes `handshake`, `send`, `recv`, `shutdown` and the negotiated protocol. `handshake` and `shutdown` return an outcome, and `send` and `recv` return an outcome and a byte count. The outcome is `TLS_OUTCOME_DONE`, `TLS_OUTCOME_BLOCKED_ON_READ`, `TLS_OUTCOME_BLOCKED_ON_WRITE` or `TLS_OUTCOME_ERROR`, which `outcome_to_interest` (`tls/handshake_state.mojo`) turns into reactor interest.

`s2n_init` runs once per process, guarded by a `_Global` slot rather than an environment variable, so a forked child initializes s2n for itself. The same first call ignores `SIGPIPE`, because s2n writes to the socket itself and does not handle that signal.

## Why is it built this way?

### Why write the HTTP codecs in Mojo instead of calling nghttp2 or libcurl?

**Decision.** The HTTP/1.1 and HTTP/2 codecs are Mojo. The client and the server share the HTTP/2 frame, HPACK, flow-control and stream codecs, and the HTTP/1.1 chunked decoder and parse limits. Each side has its own HTTP/1.1 head parser: `parse_request_head` on the server and `parse_response_head` (`client/response_parser.mojo`) on the client.

**Because.** An HTTP/2 frame codec works in both directions, so the server's codec is also the client's. Calling `nghttp2` would add a second HTTP/2 stack, with its own HPACK and flow control to keep conformant.

**Alternatives weighed.**

- FFI to `nghttp2` for HTTP/2: a second codec next to the server's.
- FFI to `libcurl`: it brings its own event-loop integration model that fights the per-thread reactor, its own TLS backend selection, against the s2n-tls choice, and a connection pool that would be opaque and untunable.

**Revisit if.** Keeping the native HTTP/2 codec conformant costs more than a C codec would.

### Why TLS through s2n-tls, with the file descriptor handed over?

**Decision.** TLS is s2n-tls over AWS-LC, built from pinned upstream sources and linked statically, and s2n reads and writes the socket itself (`s2n_connection_set_fd`).

**Because.** A TLS stack is a cryptographic correctness liability to write, s2n-tls has a smaller surface than OpenSSL, and s2n pairs with AWS-LC. Building both from source keeps one `libcrypto` in a binary. s2n's send and receive callbacks would need a Mojo function pointer called from C, which the file descriptor path avoids.

**Alternatives weighed.**

- A TLS stack written in Mojo: months of correctness work.
- OpenSSL: a larger API surface.
- A reverse proxy that ends TLS in front of a plaintext server: the aim is one binary that can serve TLS itself. Application handlers still rely on it today ([limits](#what-are-its-limits-and-open-questions)).

**Revisit if.** A Mojo record layer measures faster than the FFI boundary at acceptable risk, or s2n's callback API is needed.

### Why does the server take the dispatcher per call and lend it its own reactor?

**Decision.** `serve_one_iteration_dispatch` takes the dispatcher as an argument on each call and passes the server's own reactor into `dispatch`.

**Because.** The server stays transport-only while a stateful service keeps its state in the dispatcher. A handler's I/O runs on the reactor that serves HTTP, so one event loop runs both, instead of a second runtime inside the handler. Only the suspendable and erased rounds also free the loop while a handler waits.

**Alternatives weighed.**

- The server owns the dispatcher: the server would carry application state.
- The handler builds its own runtime: a second event loop inside the handler, disjoint from the one that serves HTTP.

**Revisit if.** Servers move to several workers, where the reactor a handler parks on must belong to that worker.

### Why does the transport, not the handler, choose chunked framing?

**Decision.** A handler asks with `mark_chunked()`, and `response_may_be_chunked` decides.

**Because.** RFC 9112 allows `Transfer-Encoding` only toward an HTTP/1.1 client, only on a response that may carry a body, and never for HEAD. A handler sees none of those facts: `HttpRequest` has no version field. The round holds all three. Falling back to `Content-Length` costs nothing, because the body is already a whole `List[UInt8]`. A second motive is Cloud Run, whose documented 32 MiB response limit applies only to responses that are not chunked ([quotas](https://docs.cloud.google.com/run/quotas)).

**Alternatives weighed.**

- The handler sets the header: every handler must know a protocol rule it cannot see.
- A streaming body: the round would have to buffer a producer to downgrade it.

**Revisit if.** Responses become streamed rather than whole buffers.

### Why does a reused connection re-send only safe or keyed requests?

**Decision.** A failed request on a reused HTTP/1.1 connection is re-sent only under the three terms in [pooling](#how-are-client-connections-pooled-and-reused).

**Because.** A request whose bytes reached a pooled connection before it failed may already have run on the server. Re-sending is safe only when no byte was written, when the method is safe under RFC 9110, or when the caller states idempotency with a key. PUT and DELETE are left out on purpose: RFC 9110 defines idempotency as a property of the server's resource, which the client cannot check. The 408 case follows RFC 9110 section 15.5.9, which lets a client repeat a request whose connection timed out.

**Alternatives weighed.**

- The idempotent set GET, HEAD, PUT, DELETE, OPTIONS: can write a resource twice.
- Never re-send: every server-side idle close surfaces as an error.

**Revisit if.** The pool gains a reader on idle connections that notices closes before reuse.

### Why is an outbound budget capped at the serving deadline?

**Decision.** A client built with `for_serving_ceiling` inside a Cloud Run service gets at most 295 s per request, not 600 s.

**Because.** Past the ceiling of the request that made the call, the answer cannot be delivered: the platform has already answered the caller. The single-threaded serve loop is still blocked, so every other route stops too. Capping removes only work whose result cannot be used. A job, a pod or a command-line process has no containing request, so it keeps the 600 s default. The discriminator is a pure function of values the caller passes in, so a binary reads its platform identity once, from its own configuration, and a test supplies the values directly.

**Alternatives weighed.**

- A per-call-site budget: a library that runs in services, jobs and command-line tools cannot know at the call site.
- A lower default everywhere: legitimate long calls in jobs would fail.

**Revisit if.** Another platform with a request ceiling is supported, or the ceiling becomes configurable.

### Why is the gRPC seam a trait over plain types?

**Decision.** `GrpcDispatch` takes a path, a content type and a byte body, and returns a `GrpcResponse`.

**Because.** A gRPC service library depends on `komira_http_server`, so `komira_http_server` cannot import that library's types without a cycle. A trait over strings and bytes lets the serve loop call any gRPC service.

**Alternatives weighed.**

- Put the gRPC service types in `komira_http_server`: the HTTP library would own protobuf-level code.

**Revisit if.** Streaming responses need incremental delivery, which a returned list cannot express.

## What must always hold?

- **Three ambiguous framings are refused.** Two `Content-Length` headers, `Content-Length` with chunked, and a `Transfer-Encoding` without the `chunked` token each answer 400. Enforced by `test_content_length_conflicting_dupes` (two differing values; no test sends equal ones), `test_transfer_encoding_and_content_length_rejected` and `test_transfer_encoding_unsupported_coding` in `test_L2_codec_content_length`. `chunked, gzip` is accepted as chunked ([limits](#what-are-its-limits-and-open-questions)).
- **A response is chunked only when `response_may_be_chunked` allows it.** Enforced by `test_http10_client_never_receives_chunked`, `test_head_request_never_receives_chunked` and `test_bodiless_statuses_never_receive_chunked` in `test_L2_chunked_response_encoding`.
- **A chunked request body reaches the handler whole.** Enforced by `test_chunked_request_body_dispatch`.
- **A reused connection re-sends a request at most once, and only under the three terms.** Enforced by `test_h1_pool_stale_conn_retry_safety`, including `test_stale_reuse_retry_is_at_most_once` and `test_idempotency_key_licenses_a_put_replay`.
- **A default budget never exceeds the serving ceiling minus 5 s.** Enforced by `test_outbound_budget_rule`.
- **A dispatcher's `RT.Sink` is the server's `NoopSink`.** Enforced at compile time by the `comptime assert` in `serve_one_iteration_dispatch`.
- **s2n is initialized once per process, including in a forked child.** Enforced by `test_tls_init_guard_is_process_local_not_env_inherited`.
- **An s2n config outlives every connection bound to it.** s2n reads the config through its raw pointer on the send path, so each `TlsConnection` holds a clone of its `TlsConfig`. Enforced by `test_bug_tls_config_lifetime_uaf_after_connector_drop` in `test_L1_tls_config_lifetime_uaf`, which drops the caller's `TlsConfig` and sends through the live connection.
- **A server, a client and their pools are used from one thread.** They hold no locks or atomics. Not enforced: nothing stops a caller from sharing one across threads through its own synchronization.
- **In the plain and chained rounds, a dispatcher's raise becomes an error response.** The plain round calls `report_fault` with status 500. The chained round calls `map_chain_error`, which answers `ErrorMappingConfig.status` (500 by default) when an `ErrorMappingMiddleware` is installed, and 500 when none is. Enforced for the plain round by `test_socket_fault_carries_code_and_incident` in `test_e2e_fault_attribution_socket`, over a loopback socket.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_http_server/server.mojo` | The server and its serve loops | `HttpServer`, `HttpServerConfig`, `serve_one_iteration_dispatch` |
| `src/komira_http_server/dispatch.mojo` | Dispatch rounds, body accumulation | `RequestDispatcher`, `CtxRequestDispatcher`, `SuspendableDispatcher`, `serve_read_round_dispatch` |
| `src/komira_http_server/accept_loop.mojo` | Accept, TLS handshake and canned rounds | `accept_one_and_register`, `drive_tls_handshake`, `resume_pending_write` |
| `src/komira_http_server/serve_h2.mojo` | HTTP/2 serve round | `serve_read_round_h2`, `build_initial_server_settings` |
| `src/komira_http_core/transport/grpc_emit.mojo` | gRPC seam and emitters | `GrpcDispatch`, `GrpcStreamDispatch`, `NoopGrpcDispatch`, `emit_grpc_response` |
| `src/komira_http_core/transport/io_stream.mojo`, `kernel_tcp.mojo`, `scripted.mojo` | Stream and connector traits and conformers | `IoStream`, `Connector`, `KernelTcpConnector`, `ScriptedConnector` |
| `src/komira_http_core/transport/stream_park.mojo` | The one park primitive for stream drivers | `park_on_pending` |
| `src/komira_http_core/codec/h1/` | HTTP/1.1 parser, limits, chunked codec | `parse_request_head`, `ParseLimits`, `ChunkedDecoder`, `append_chunked_body` |
| `src/komira_http_core/codec/h2/` | HTTP/2 frames, HPACK, flow control, streams | `H2ConnectionState`, `decode_frame` |
| `src/komira_http_core/codec/types.mojo`, `response_framing.mojo` | Request, response, framing decision | `HttpRequest`, `HttpResponse`, `response_may_be_chunked` |
| `src/komira_http_server/middleware/` | Chain and built-in middleware | `MiddlewareChain`, `Middleware`, `RequestContext`, `CorsMiddleware` |
| `src/komira_http_server/routing/` | Routers | `Router`, `AppRouter`, `Route` |
| `src/komira_http_server/serving/serverless_entry.mojo` | Listener-platform serving loop | `ServerlessEntry`, `GcpServerlessEntry`, `parse_serve_port` |
| `src/komira_http_client/client.mojo` | The client | `HttpClient`, `HttpClientConfig` |
| `src/komira_http_client/state_machine.mojo`, `h2_client.mojo` | HTTP/1.1 and HTTP/2 drivers | `OutboundDriver`, `drive_h2_streams_to_completion` |
| `src/komira_http_client/pool.mojo`, `h2_pool.mojo`, `session_cache.mojo` | Pools and TLS session cache | `PerCorePool`, `PoolKey`, `H2ClientPool`, `SessionCache` |
| `src/komira_http_client/outbound_budget.mojo` | Budget rule | `outbound_budget_us`, `serving_request_ceiling_us` |
| `src/komira_http_client/retry.mojo`, `timeout.mojo`, `redirect.mojo`, `redirect_policy.mojo` | Layers and redirect rules | `RetryLayer`, `TimeoutLayer`, `RedirectLayer`, `resolve_redirect_location` |
| `src/komira_http_client/tls_connector.mojo` | TLS client connector | `TlsConnector`, `TlsClientStream` |
| `src/komira_http_client/header_simd.mojo` | SIMD byte helpers for headers | `case_fold_copy_span`, `ci_eq_span` |
| `src/komira_http_core/tls/` | s2n FFI and safe wrappers | `TlsConfig`, `TlsConnection`, `TlsStream`, `tls_init` |

Entry points:

- **Serve HTTP:** build an `HttpServer`, then call `serve_one_iteration_dispatch[D, RT]` in a loop with a `RequestDispatcher`, or call `GcpServerlessEntry(port).serve(dispatcher)`.
- **Serve gRPC:** conform to `GrpcDispatch` and `GrpcStreamDispatch`, build `HttpServer[G]` with a `TlsConfig`, and call `serve_one_iteration`.
- **Call HTTP:** `HttpClient[TlsConnector[KernelTcpConnector]].with_defaults(connector)`, then `send_buffered`.
- **Execution starts at:** `HttpServer.serve_one_iteration_dispatch` in `src/komira_http_server/server.mojo`, and `HttpClient.send_buffered` in `src/komira_http_client/client.mojo`.

## How is it tested?

Each package welds its own tests: `komira_http_core` 36, `komira_http_client` 105 and `komira_http_server` 25, 166 in all. Each runs as a build action, so a library cannot build while one of its tests fails. Run: `./buck2 build //src/komira_http_core:komira_http_core //src/komira_http_client:komira_http_client //src/komira_http_server:komira_http_server`.

- TLS tests link the vendored s2n-tls and AWS-LC archives and read the certificates in `src/komira_http_core/tests/fixtures/`.
- `ScriptedStream` and `ScriptedConnector` feed byte scripts to the client, and `ScriptedTransport` records calls through the `HttpTransport` seam, so most client tests open no socket.
- The HTTP/2 client tests replay the frames in `src/komira_http_client/tests/fuzz_corpus/h2_client/`.

Not tested:

- No test in the library's gate sends a dispatch round a request head split across reads, which those rounds drop ([limits](#what-are-its-limits-and-open-questions)).

## What are its limits and open questions?

- **Limit: application handlers are plaintext HTTP/1.1 only.** The dispatch rounds close TLS and HTTP/2 connections. TLS and HTTP/2 run only under `serve_one_iteration`, which answers plain requests with canned bodies. Nothing in this repository builds an `HttpServer` with a `TlsConfig` or a gRPC service for an application, so TLS must end in front of a service.
- **Limit: a request head must arrive in one 4,096-byte read.** The dispatch rounds parse from `io_buf` alone, and a head that needs more bytes (`is_need_more`) closes the connection with no response. The 8 KiB and 64 KiB header limits cannot be reached on these rounds.
- **Limit: `parse_request_head` checks `Transfer-Encoding` only for the `chunked` token.** It treats any list that holds it as chunked. That admits `chunked, gzip`, which [RFC 9112 section 6.3](https://www.rfc-editor.org/rfc/rfc9112#section-6.3) requires a 400 for; `gzip, chunked`, which reaches the handler still gzipped; and two `chunked` headers, folded to `chunked, chunked`. The client's `parse_response_head` checks the final coding.
- **Limit: a slow request body blocks the loop.** `accumulate_body_remainder` retries up to 100,000 empty reads with `sched_yield`, on the serve thread, before it drops the connection.
- **Limit: server bodies are whole buffers.** On the server, requests, responses and gRPC streaming responses are held in memory in full; chunked framing changes the wire, not the peak memory. The client's `send` streams its body through a `RecvRingBody`. Behind Cloud Run's frontend, a chunked response cut at the request timeout reaches the client as a complete 200 with a well-formed terminating chunk, so a caller sending a large body needs its own completeness check. A chunked body cut off by a closed connection has no terminating chunk, and the client raises `HTTP_ERROR_EOF_MID_RESPONSE`.
- **Limit: a raise from `make_frame` escapes the serve call.** The suspendable and erased rounds call `make_frame` and `make_erased_frame` outside any `try`, so the raise leaves `serve_one_iteration_dispatch_suspendable` or `serve_one_iteration_dispatch_erased`. The comment beside each call says the connection is dropped.
- **Limit: IPv4 only, with blocking DNS.** Dials take a `UInt32` address; `resolve_host_be` in `komira_async` calls `getaddrinfo`, which has no timeout.
- **Limit: routes match in registration order.** A `/users/:id` added before `/users/me` captures `/users/me`, and lookup scans the routes one by one.
- **Limit: AWS Lambda reports no ceiling.** `serving_request_ceiling_us` returns no ceiling for the Lambda runtime API value, so a client there keeps the 600 s default (`test_lambda_reports_no_ceiling_and_that_is_a_known_gap`).
- **Limit: no WebSocket framing.** Outside its tests, the HTTP layer mentions WebSocket only in one comment.
- **Raw pointer across a module:** `TlsConnection._raw_conn_ptr_for_test()` in `tls/s2n_shim.mojo` returns the raw s2n pointer. Five test files in `tests/` reach it: three call it directly, and two through `TlsClientStream._conn_quic_enabled_for_test` in `client/tls_connector.mojo`. See the encapsulation rule in [Mojo safety and idioms](mojo_safety_and_idioms.md).
- **Open question:** should the dispatch rounds serve TLS and HTTP/2? The pieces exist in `serve_one_iteration`; what is missing is a handler path for plain requests there, and a decision on whether TLS ends in the process or in front of it.
