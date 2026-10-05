# =============================================================================
# komira_inference_backend/spawning_backend.mojo
#   The spawning InferenceBackend conformers: a backend that SPAWNS its
#   OpenAI-`/v1` server as a child process (komira_supervisor), probes it live
#   over the HTTP client, and tears it down by stopping the child. Three
#   engines:
#     * SpawningMlxBackend       — macOS chat (mlx_lm.server).
#     * SpawningLlamaCppBackend  — Linux chat (llama-server).
#     * SpawningMlxEmbedBackend  — macOS embeddings (mlx-openai-server).
# =============================================================================
#
# Its dependencies are komira_async, the HTTP client, komira_clock,
# komira_supervisor and its sibling `inference_backend`.
#
# All three implement the `InferenceBackend` trait (inference_backend.mojo).
#
# WHAT DIFFERS from the connect-to-running MlxBackend (inference_backend.mojo):
#   * launch()   — if the endpoint is ALREADY serving (an externally-managed
#                  server, or this backend's own earlier launch) it is REUSED
#                  without spawning. Otherwise any child left by an earlier
#                  launch is stopped, the engine binary is spawned, and launch()
#                  BLOCKS until a live probe says the endpoint is serving, the
#                  child exits (raised at once, with its exit status), or the
#                  launch budget runs out. Returns the OpenAI base URL.
#   * health()   — a REAL liveness probe (`HttpClient[C]` on a per-call
#                  BlockingRuntime, bounded by PROBE_TIMEOUT_MS), not an
#                  optimism flag.
#   * teardown() — STOPS a child this backend spawned (SIGTERM -> grace ->
#                  SIGKILL) and reaps it. A reused server is never stopped.
#
# THE CHILD'S STDIO AND ENVIRONMENT. The engine is spawned with
# komira_supervisor's `spawn_detached`: it inherits the caller's fds 0/1/2 and
# environment. An inference server logs for as long as it runs (model load, a
# line per request), so capture pipes that nobody drains would fill and freeze
# it; inheriting stdio means its logs go where the caller's own go. A caller
# whose stdout carries a protocol should point its stdout elsewhere before
# launching.
#
# The wire is the OpenAI `/v1` one, so the base URL these backends return is
# what any OpenAI-compatible client POSTs to. To target an externally-managed
# server without spawning, use `MlxBackend` from inference_backend.mojo.
#
# THE CONNECTOR SEAM `[C: Connector]`: the backends are parametric over the
# HTTP Connector, so a production caller binds `KernelTcpConnector` (real TCP)
# while a test can bind a different connector. The health probe and the launch
# readiness wait both run over `C`. (The spawn itself is connector-independent:
# it goes through komira_supervisor's posix_spawn FFI.)
#
# The surface is owned Strings and values: no UnsafePointer in any public
# signature and no wildcard origin. The Connector factory is a `thin` fn-pointer
# field (a code pointer, no heap). The child is owned through komira_supervisor's
# value-typed `DetachedChild`, which encapsulates the pid and its signals.
# =============================================================================

from std.ffi import external_call

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_clock import now_ns

from komira_http_client.body import EmptyBody, BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST, HttpMethod
from komira_http_core.transport.io_stream import Connector

from komira_supervisor import ChildSpec, DetachedChild, DetachedExit, spawn_detached

from .inference_backend import InferenceBackend


# -----------------------------------------------------------------------------
# Readiness-wait tuning. After spawning the engine, launch() polls the live
# probe until it succeeds (loading a model can take seconds for a 7B-class
# model). These are the bounded defaults.
#   * HEALTH_POLL_INTERVAL_MS — pause between readiness probes.
#   * DEFAULT_LAUNCH_TIMEOUT_MS — overall readiness budget, measured on the
#     monotonic clock from the spawn (a 7B 4-bit model loads in a few seconds
#     on Apple Silicon; 120s is a safe upper bound that also covers a cold disk
#     read or a larger model). `set_launch_timeout_ms` overrides it.
#   * TEARDOWN_GRACE_MS — SIGTERM grace before SIGKILL on teardown.
#   * PROBE_TIMEOUT_MS — the deadline of one probe request, connect to last
#     body byte. A server that accepts and then stalls is "not serving" after
#     this long, so health() stays short and a launch overshoots its budget by
#     at most one probe.
# -----------------------------------------------------------------------------
comptime HEALTH_POLL_INTERVAL_MS: Int = 500
comptime DEFAULT_LAUNCH_TIMEOUT_MS: Int = 120000
comptime TEARDOWN_GRACE_MS: Int = 5000
comptime PROBE_TIMEOUT_MS: Int = 2000

# -----------------------------------------------------------------------------
# Engine-parallelism default. The number of concurrent requests an engine is
# told to serve against ONE loaded model. A caller that admits N concurrent
# requests passes N down to the child spec, so the engine's own concurrency
# matches what the caller admits. A value of 1 means "no engine-side
# parallelism" (the conservative default): the spec then carries no
# parallelism flag (single-stream behavior).
#
# Which engines honor it:
#   * llama-server (Linux chat)   — YES: `--parallel <N>` + `--cont-batching`
#     give N continuous-batching slots.
#   * mlx_lm.server (macOS chat)   — NO native concurrency flag (ml-explore/
#     mlx-lm#499 and #178: batching is an open feature request). The spec
#     carries no flag; the caller's own admission limit is the only bound.
#   * mlx-openai-server embeddings — NO concurrency flag for `--model-type
#     embeddings` (cubist38/mlx-openai-server: `--decode-concurrency` /
#     `--prompt-concurrency` apply to `lm`/multimodal only, not embeddings).
#   * Ollama (reused, not spawned) — a caller CANNOT reconfigure an already-
#     running Ollama; `OLLAMA_NUM_PARALLEL` must be set in Ollama's own launch
#     environment. Even then Ollama serializes the embeddings endpoint
#     (ollama/ollama#8778): NUM_PARALLEL parallelizes generate/chat decode only.
# -----------------------------------------------------------------------------
comptime DEFAULT_NUM_PARALLEL: Int = 1


# -----------------------------------------------------------------------------
# _base_url_for — assemble `http://<host>:<port>` from a host + port. Local
# OpenAI servers listen on plaintext loopback; use the IPv4 dotted-quad literal
# `127.0.0.1` (NOT "localhost", which the HTTP client does not resolve: it
# expects a dotted quad).
# -----------------------------------------------------------------------------
def _base_url_for(host: String, port: UInt16) -> String:
    var out = String("http://")
    out += host
    out += ":"
    out += String(Int(port))
    return out^


def _sleep_ms(ms: Int):
    """Pause `ms` milliseconds. `usleep`, not the stdlib sleep: the stdlib
    declares `nanosleep` with a signature that conflicts with komira_async's
    own declaration when both are linked into one binary."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


# -----------------------------------------------------------------------------
# probe_v1_models[C: Connector] — the liveness probe. GET /v1/models over a
# fresh `HttpClient[C]` on a per-call `BlockingRuntime[NoopSink]`, bounded by
# PROBE_TIMEOUT_MS. Returns True iff the endpoint answered with a 2xx. ANY
# transport / connect / deadline error is swallowed and reported as False (an
# unreachable, stalled or not-yet-up server is "not healthy", not an exception:
# health() is a non-raising boolean per the trait).
#
# `/v1/models` is the OpenAI model-list endpoint the common local-LLM servers
# (mlx_lm.server, llama-server, Ollama, LM Studio) serve; a 2xx there is the
# signal that the OpenAI surface is up. It says nothing about WHICH model is
# loaded: the body is not read.
# -----------------------------------------------------------------------------
def probe_v1_models[
    C: Connector
](mk_connector: def () thin -> C, host: String, port: UInt16) -> Bool:
    """GET `<host>:<port>/v1/models`; return True iff 2xx. Errors -> False."""
    try:
        var url = Url.http(host, port, String("/v1/models"))
        var headers = HeaderMap()
        headers.append(String("Accept"), String("application/json"))
        var req = build_request_with_body[EmptyBody](
            HttpMethod(code=HTTP_METHOD_GET),
            url^,
            headers^,
            EmptyBody.new(),
        )
        var connector = mk_connector()
        var client = HttpClient[C].with_request_timeout_us(
            connector^, PROBE_TIMEOUT_MS * 1000
        )
        var rt = BlockingRuntime[NoopSink].new(
            NoopSink(_placeholder=UInt8(0))
        )
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        # Drain the body so the response is fully consumed (the connection
        # state machine wants the body read even if we only care about status).
        var _resp = cr.body.take_bytes()
        return status >= 200 and status < 300
    except:
        return False


# -----------------------------------------------------------------------------
# probe_v1_embeddings[C: Connector] — the liveness probe for an EMBEDDINGS
# server. Unlike the chat servers (mlx_lm.server / llama-server), the macOS
# embeddings server `mlx-openai-server --model-type embeddings` does NOT
# reliably serve `GET /v1/models`; its readiness signal is a
# `POST /v1/embeddings` that returns a 2xx. So the embeddings backend probes
# with a tiny one-input embeddings request rather than GET /v1/models.
#
# `served_model` MUST equal the server's `--served-model-name`:
# mlx-openai-server 404s any other `model` value. A 404 model_not_found is NOT
# a healthy-server signal (the model is not loaded under that name), so only a
# 2xx counts as healthy. ANY transport / connect / deadline error is swallowed
# -> False (an unreachable / not-yet-up server is "not healthy", never an
# exception: health() is a non-raising boolean per the trait). Bounded by
# PROBE_TIMEOUT_MS.
# -----------------------------------------------------------------------------
def probe_v1_embeddings[
    C: Connector
](
    mk_connector: def () thin -> C,
    host: String,
    port: UInt16,
    served_model: String,
) -> Bool:
    """POST a 1-token `/v1/embeddings` ping to `<host>:<port>`; return True iff
    2xx. The `served_model` is sent as the `model` field (the embeddings server
    404s any other value). Errors / non-2xx -> False."""
    try:
        var url = Url.http(host, port, String("/v1/embeddings"))
        var headers = HeaderMap()
        headers.append(String("Accept"), String("application/json"))
        headers.append(String("Content-Type"), String("application/json"))
        # A minimal, deterministic embeddings request (a single short input).
        var body_str = String('{"model":"')
        body_str += served_model
        body_str += String('","input":["ping"]}')
        var body_bytes = List[UInt8]()
        var src = body_str.as_bytes()
        for i in range(len(src)):
            body_bytes.append(src[i])
        var req = build_request_with_body[BytesBody](
            HttpMethod(code=HTTP_METHOD_POST),
            url^,
            headers^,
            BytesBody.from_bytes(body_bytes^),
        )
        var connector = mk_connector()
        var client = HttpClient[C].with_request_timeout_us(
            connector^, PROBE_TIMEOUT_MS * 1000
        )
        var rt = BlockingRuntime[NoopSink].new(
            NoopSink(_placeholder=UInt8(0))
        )
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            req^, reactor
        )
        var status = Int(cr.status)
        # Drain the body so the connection state machine fully consumes it.
        var _resp = cr.body.take_bytes()
        return status >= 200 and status < 300
    except:
        return False


def _probe[
    C: Connector
](
    mk_connector: def () thin -> C,
    host: String,
    port: UInt16,
    embeddings: Bool,
    served_model: String,
) -> Bool:
    """The probe a backend is served by: POST /v1/embeddings for the embeddings
    engine, GET /v1/models for the chat engines."""
    if embeddings:
        return probe_v1_embeddings[C](mk_connector, host, port, served_model)
    return probe_v1_models[C](mk_connector, host, port)



# =============================================================================
# ChildSpec assembly — pure factory functions (the unit-test seam).
#
# These build the engine `ChildSpec` (path + argv + env) from a host/port/model
# WITHOUT spawning, so a unit test can assert the exact argv a real spawn would
# use, isolated from the engine itself. launch() calls these, then hands the
# spec to `spawn_detached`.
# =============================================================================


def build_mlx_embed_child_spec(
    binary_path: String,
    model_path: String,
    served_model: String,
    host: String,
    port: UInt16,
) -> ChildSpec:
    """Assemble the `mlx-openai-server` EMBEDDINGS child spec (the macOS
    embeddings engine).

    Runs `<binary_path> launch --model-type embeddings --model-path <model_path>
    --served-model-name <served_model> --host <host> --port <port>
    --no-log-file --log-level INFO`. The flags differ from the chat
    `mlx_lm.server` engine: it is the SEPARATE `mlx-openai-server` package
    (wrapping `mlx-embeddings`), takes a `launch` subcommand + `--model-type
    embeddings` + `--model-path` (not `--model`) + `--served-model-name`, and
    serves the OpenAI `/v1/embeddings` wire. `--served-model-name` is the value
    a client must send in the request `model` field (the server 404s any other).
    argv[0] is defaulted to `binary_path` by the spawn.

    No engine-parallelism flag: `mlx-openai-server`'s `--decode-concurrency` /
    `--prompt-concurrency` apply to `--model-type lm`/multimodal ONLY, not to
    `--model-type embeddings`. The embeddings server exposes no concurrency
    knob, so the caller's admission limit is the only concurrency bound here.
    """
    var spec = ChildSpec(binary_path)
    spec.with_arg(String("launch"))
    spec.with_arg(String("--model-type"))
    spec.with_arg(String("embeddings"))
    spec.with_arg(String("--model-path"))
    spec.with_arg(model_path)
    spec.with_arg(String("--served-model-name"))
    spec.with_arg(served_model)
    spec.with_arg(String("--host"))
    spec.with_arg(host)
    spec.with_arg(String("--port"))
    spec.with_arg(String(Int(port)))
    spec.with_arg(String("--no-log-file"))
    spec.with_arg(String("--log-level"))
    spec.with_arg(String("INFO"))
    return spec^


def build_mlx_child_spec(
    binary_path: String,
    model: String,
    host: String,
    port: UInt16,
    num_parallel: Int = DEFAULT_NUM_PARALLEL,
) -> ChildSpec:
    """Assemble the `mlx_lm.server` child spec (the macOS chat engine).

    Runs `<binary_path> --model <model> --host <host> --port <port>`. The
    `mlx_lm.server` console-script entrypoint takes exactly these flags.
    argv[0] is defaulted to `binary_path` by the spawn.

    `num_parallel` is accepted for symmetry with the other engines, but
    **mlx_lm.server has NO native concurrency / continuous-batching CLI flag**
    (ml-explore/mlx-lm#499 and #178). So this spec emits NO parallelism flag
    regardless of `num_parallel`: a `> 1` value cannot be honored by this
    engine, and inventing a flag would make the engine fail to start. The
    caller's admission limit remains the concurrency bound; this engine
    serializes decode. (For real concurrent chat on macOS, point the binary
    path at an engine that does batch: `mlx-openai-server --model-type lm` with
    `--decode-concurrency`, or llama.cpp's `llama-server --parallel`, below.)
    """
    var spec = ChildSpec(binary_path)
    spec.with_arg(String("--model"))
    spec.with_arg(model)
    spec.with_arg(String("--host"))
    spec.with_arg(host)
    spec.with_arg(String("--port"))
    spec.with_arg(String(Int(port)))
    # NOTE: no parallelism flag — mlx_lm.server does not expose one. `num_parallel`
    # is intentionally unused here (documented above). Keep the reference alive so
    # the signature is honest about what it accepts.
    _ = num_parallel
    return spec^


def build_llamacpp_child_spec(
    binary_path: String,
    model: String,
    host: String,
    port: UInt16,
    num_parallel: Int = DEFAULT_NUM_PARALLEL,
) -> ChildSpec:
    """Assemble the `llama-server` child spec (the Linux chat engine).

    Runs `<binary_path> --model <model> --host <host> --port <port>
    --n-gpu-layers 99 [--parallel <N> --cont-batching]`. llama.cpp's server
    takes `-ngl` / `--n-gpu-layers` to offload layers to the GPU; `99` offloads
    every available layer (llama.cpp clamps it to the model's layer count), so
    the spec uses the GPU when there is one. argv[0] is defaulted to
    `binary_path`.

    ENGINE PARALLELISM: when `num_parallel > 1`, append `--parallel <N>` (N
    continuous-batching slots) + `--cont-batching` (without it, even with N
    slots llama-server answers one request at a time). llama.cpp then serves N
    concurrent decode streams against one loaded model. Pass the same N the
    caller admits, so the engine never runs more requests at once than the
    caller sized memory for. `num_parallel <= 1` emits no parallelism flag
    (single-slot behavior, the conservative default).
    """
    var spec = ChildSpec(binary_path)
    spec.with_arg(String("--model"))
    spec.with_arg(model)
    spec.with_arg(String("--host"))
    spec.with_arg(host)
    spec.with_arg(String("--port"))
    spec.with_arg(String(Int(port)))
    spec.with_arg(String("--n-gpu-layers"))
    spec.with_arg(String("99"))
    # ENGINE PARALLELISM: N continuous-batching slots, matching the number of
    # requests the caller admits.
    if num_parallel > 1:
        spec.with_arg(String("--parallel"))
        spec.with_arg(String(num_parallel))
        spec.with_arg(String("--cont-batching"))
    return spec^


# =============================================================================
# The engine process: spawn, stop, and the shared launch body.
# =============================================================================


def _spawn_engine(spec: ChildSpec, who: String) raises -> DetachedChild:
    """Spawn `spec` with inherited stdio (see the header): an inference server
    logs for its whole life, and a capture pipe nobody drains would freeze it.
    The environment is the spec's when it carries one, else the caller's.
    Raises naming the binary when the spawn itself fails."""
    var env = spec.env.copy() if spec.has_env else List[String]()
    var pid = spawn_detached(spec.path, spec.argv, env)
    if pid <= Int32(0):
        raise Error(
            who
            + ": spawn failed (rc="
            + String(Int(pid))
            + ") for "
            + spec.path
        )
    return DetachedChild(pid)


def _describe_exit(st: DetachedExit) -> String:
    """`exited with code N` / `was killed by signal N` / `could not be waited
    on`, for a child that is no longer running."""
    if st.exited:
        return String("exited with code ") + String(Int(st.exit_code))
    if st.signaled:
        return String("was killed by signal ") + String(Int(st.signal))
    return String("could not be waited on")


def _stop_engine(child: DetachedChild, grace_ms: Int):
    """SIGTERM, wait up to `grace_ms` for the child to exit, then SIGKILL, and
    reap it. A child that has already been reaped is left alone, so its pid
    (which the kernel may have reused) is never signalled."""
    if not child.poll_exit().running:
        return
    _ = child.term()
    var waited = 0
    while waited < grace_ms:
        if not child.poll_exit().running:
            return
        _sleep_ms(10)
        waited += 10
    _ = child.kill()
    # SIGKILL cannot be caught, so the reap follows promptly; the bound only
    # keeps a child stuck in the kernel from hanging teardown.
    for _ in range(500):
        if not child.poll_exit().running:
            return
        _sleep_ms(10)


# =============================================================================
# _launch_impl — the SHARED launch body of all three backends; only the
# ChildSpec and the probe differ. Mutates the backend's `spawned` / `child`
# fields in place (passed by `mut`). The flow:
#   1. If the endpoint is ALREADY serving, REUSE it (no spawn): this backend's
#      own child from an earlier launch, or an externally-managed server. Reuse
#      checks that SOMETHING serves the probe at host:port, not which model it
#      has loaded; mlx_lm.server and llama-server share the default port 8080,
#      so a caller running both must give them different ports.
#   2. Else stop any child an earlier launch left (it is not serving, and it
#      may still hold the port), then spawn the engine. A failed spawn raises.
#   3. Poll until the probe succeeds (return the base URL), the child exits
#      (raise at once with its exit status), or `launch_timeout_ms` has passed
#      on the monotonic clock since the spawn (stop the child, raise).
# =============================================================================
def _launch_impl[
    C: Connector
](
    mk_connector: def () thin -> C,
    spec: ChildSpec,
    host: String,
    port: UInt16,
    embeddings: Bool,
    served_model: String,
    launch_timeout_ms: Int,
    who: String,
    mut spawned: Bool,
    mut child: DetachedChild,
) raises -> String:
    var base = _base_url_for(host, port)

    # (1) Reuse an endpoint that is already serving.
    if _probe[C](mk_connector, host, port, embeddings, served_model):
        return base^

    # (2) A child of ours that is not serving is stopped before a new spawn,
    # so it cannot keep the port or outlive the backend unreferenced.
    if spawned:
        _stop_engine(child, TEARDOWN_GRACE_MS)
        spawned = False
    child = _spawn_engine(spec, who)
    spawned = True

    # (3) Wait for readiness, bounded on the monotonic clock.
    var start = now_ns()
    var budget_ns = UInt64(launch_timeout_ms) * UInt64(1_000_000)
    while True:
        if _probe[C](mk_connector, host, port, embeddings, served_model):
            return base^
        var st = child.poll_exit()
        if not st.running:
            spawned = False
            raise Error(
                who
                + ": engine "
                + spec.path
                + " "
                + _describe_exit(st)
                + " before serving at "
                + base
            )
        if now_ns() - start >= budget_ns:
            break
        _sleep_ms(HEALTH_POLL_INTERVAL_MS)

    # Never came up within the budget: stop the child and fail loudly.
    _stop_engine(child, TEARDOWN_GRACE_MS)
    spawned = False
    raise Error(
        who
        + ": engine did not become healthy at "
        + base
        + " within "
        + String(launch_timeout_ms)
        + "ms (model load failed, wrong binary or flags, or for the"
        " embeddings engine a served-model-name mismatch)"
    )


def _teardown_impl(mut spawned: Bool, child: DetachedChild):
    """Stop and reap a child this backend spawned; a no-op otherwise (a reused
    server is never stopped)."""
    if spawned:
        _stop_engine(child, TEARDOWN_GRACE_MS)
        spawned = False


# =============================================================================
# SpawningMlxBackend[C: Connector] — the macOS chat engine.
# =============================================================================
struct SpawningMlxBackend[C: Connector](InferenceBackend, Movable):
    """Spawning MLX backend (mlx_lm.server) — the macOS chat engine.

    `launch()` spawns `mlx_lm.server --model <path> --host <host> --port <p>`
    (unless an endpoint is already serving at the target, in which case it
    reuses it), then blocks until a live GET /v1/models probe succeeds.
    `health()` is the real probe. `teardown()` stops the child.

    Construction:
      * SpawningMlxBackend[C](mk_connector, binary_path, model) — defaults
        host=127.0.0.1, port=8080 (the mlx_lm.server default).
      * SpawningMlxBackend[C](mk_connector, binary_path, model, host, port).
    Bind `C = KernelTcpConnector` in production.
    """

    # The Connector factory — a `thin` (non-raising, non-capturing) fn pointer.
    # A code pointer, no heap, no wildcard origin.
    var _mk_connector: def () thin -> Self.C
    var _binary_path: String
    var _model: String
    var _host: String
    var _port: UInt16
    var _launch_timeout_ms: Int
    # The engine's max concurrent requests per model, as the caller configured
    # it. mlx_lm.server has no native concurrency flag, so this is carried (for
    # symmetry) but emits nothing in the spec; see build_mlx_child_spec.
    var _num_parallel: Int
    # Whether THIS backend spawned the child (vs reused an external server).
    # Only a backend-spawned child is torn down (we never kill someone else's
    # externally-managed server).
    var _spawned: Bool
    # The spawned child (meaningful only while `_spawned`).
    var _child: DetachedChild

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        binary_path: String,
        model: String,
    ):
        """Defaults: host=127.0.0.1, port=8080 (mlx_lm.server default),
        num_parallel=1 (no engine-side concurrency)."""
        self._mk_connector = mk_connector
        self._binary_path = binary_path
        self._model = model
        self._host = String("127.0.0.1")
        self._port = UInt16(8080)
        self._launch_timeout_ms = DEFAULT_LAUNCH_TIMEOUT_MS
        self._num_parallel = DEFAULT_NUM_PARALLEL
        self._spawned = False
        self._child = DetachedChild(Int32(-1))

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        binary_path: String,
        model: String,
        host: String,
        port: UInt16,
        num_parallel: Int = DEFAULT_NUM_PARALLEL,
    ):
        """Explicit host + port (+ optional engine num_parallel, which
        mlx_lm.server ignores; see build_mlx_child_spec)."""
        self._mk_connector = mk_connector
        self._binary_path = binary_path
        self._model = model
        self._host = host
        self._port = port
        self._launch_timeout_ms = DEFAULT_LAUNCH_TIMEOUT_MS
        self._num_parallel = num_parallel
        self._spawned = False
        self._child = DetachedChild(Int32(-1))

    def set_launch_timeout_ms(mut self, ms: Int):
        """The readiness budget of the next launch() (default
        DEFAULT_LAUNCH_TIMEOUT_MS)."""
        self._launch_timeout_ms = ms

    def child_spec(self) -> ChildSpec:
        """The `ChildSpec` `launch()` would spawn (the unit-test seam)."""
        return build_mlx_child_spec(
            self._binary_path,
            self._model,
            self._host,
            self._port,
            self._num_parallel,
        )

    def launch(mut self) raises -> String:
        """Reuse an endpoint already serving at the target, or spawn
        mlx_lm.server and wait for it; return the base URL."""
        var spec = self.child_spec()
        return _launch_impl[Self.C](
            self._mk_connector,
            spec,
            self._host,
            self._port,
            False,
            String(""),
            self._launch_timeout_ms,
            String("SpawningMlxBackend.launch"),
            self._spawned,
            self._child,
        )

    def health(self) -> Bool:
        """REAL GET /v1/models liveness probe."""
        return probe_v1_models[Self.C](self._mk_connector, self._host, self._port)

    def teardown(mut self):
        """Stop the spawned child (SIGTERM -> grace -> SIGKILL) + reap.
        No-op when this backend did not spawn (external server)."""
        _teardown_impl(self._spawned, self._child)

    def base_url(self) -> String:
        return _base_url_for(self._host, self._port)

    def num_parallel(self) -> Int:
        """The num_parallel this backend was configured with. mlx_lm.server
        IGNORES it: no concurrency flag is passed, the engine serializes
        decode, and the caller's own admission limit is the only bound."""
        return self._num_parallel


# =============================================================================
# SpawningLlamaCppBackend[C: Connector] — the Linux chat engine.
# =============================================================================
struct SpawningLlamaCppBackend[C: Connector](InferenceBackend, Movable):
    """Spawning llama.cpp backend (llama-server) — the Linux chat engine.

    Same shape as SpawningMlxBackend: `launch()` spawns
    `llama-server --model <path> --host <host> --port <p> --n-gpu-layers 99`
    (unless an endpoint is already serving), waits for the GET /v1/models
    probe; `health()` probes; `teardown()` stops the child.

    Construction:
      * SpawningLlamaCppBackend[C](mk_connector, binary_path, model) — defaults
        host=127.0.0.1, port=8080 (the llama-server default).
      * SpawningLlamaCppBackend[C](mk_connector, binary_path, model, host,
        port).
    Bind `C = KernelTcpConnector` in production.
    """

    var _mk_connector: def () thin -> Self.C
    var _binary_path: String
    var _model: String
    var _host: String
    var _port: UInt16
    var _launch_timeout_ms: Int
    # The engine's max concurrent requests per model. For llama-server this is
    # real: it becomes `--parallel <N> --cont-batching` (N continuous-batching
    # slots). See build_llamacpp_child_spec.
    var _num_parallel: Int
    var _spawned: Bool
    var _child: DetachedChild

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        binary_path: String,
        model: String,
    ):
        """Defaults: host=127.0.0.1, port=8080 (llama-server default),
        num_parallel=1 (single slot)."""
        self._mk_connector = mk_connector
        self._binary_path = binary_path
        self._model = model
        self._host = String("127.0.0.1")
        self._port = UInt16(8080)
        self._launch_timeout_ms = DEFAULT_LAUNCH_TIMEOUT_MS
        self._num_parallel = DEFAULT_NUM_PARALLEL
        self._spawned = False
        self._child = DetachedChild(Int32(-1))

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        binary_path: String,
        model: String,
        host: String,
        port: UInt16,
        num_parallel: Int = DEFAULT_NUM_PARALLEL,
    ):
        """Explicit host + port (+ optional engine num_parallel)."""
        self._mk_connector = mk_connector
        self._binary_path = binary_path
        self._model = model
        self._host = host
        self._port = port
        self._launch_timeout_ms = DEFAULT_LAUNCH_TIMEOUT_MS
        self._num_parallel = num_parallel
        self._spawned = False
        self._child = DetachedChild(Int32(-1))

    def set_launch_timeout_ms(mut self, ms: Int):
        """The readiness budget of the next launch() (default
        DEFAULT_LAUNCH_TIMEOUT_MS)."""
        self._launch_timeout_ms = ms

    def child_spec(self) -> ChildSpec:
        """The `ChildSpec` `launch()` would spawn (the unit-test seam)."""
        return build_llamacpp_child_spec(
            self._binary_path,
            self._model,
            self._host,
            self._port,
            self._num_parallel,
        )

    def launch(mut self) raises -> String:
        """Reuse an endpoint already serving at the target, or spawn
        llama-server and wait for it; return the base URL."""
        var spec = self.child_spec()
        return _launch_impl[Self.C](
            self._mk_connector,
            spec,
            self._host,
            self._port,
            False,
            String(""),
            self._launch_timeout_ms,
            String("SpawningLlamaCppBackend.launch"),
            self._spawned,
            self._child,
        )

    def health(self) -> Bool:
        """REAL GET /v1/models liveness probe."""
        return probe_v1_models[Self.C](self._mk_connector, self._host, self._port)

    def teardown(mut self):
        """Stop the spawned child (SIGTERM -> grace -> SIGKILL) + reap.
        No-op when this backend did not spawn (external server)."""
        _teardown_impl(self._spawned, self._child)

    def base_url(self) -> String:
        return _base_url_for(self._host, self._port)

    def num_parallel(self) -> Int:
        """The engine max-concurrent this backend was configured with. For
        llama-server this is real: it became `--parallel <N> --cont-batching`
        (N continuous-batching slots)."""
        return self._num_parallel


# =============================================================================
# SpawningMlxEmbedBackend[C: Connector] — the macOS EMBEDDINGS engine.
#
# Same InferenceBackend shape as the chat backends (launch / health / teardown /
# base_url), but it manages the SEPARATE embeddings server (`mlx-openai-server
# --model-type embeddings`) and probes it with a POST /v1/embeddings (its
# readiness signal), NOT GET /v1/models. The base URL it returns is what an
# embeddings client POSTs to (`<base_url>/v1/embeddings`).
#
# Spawn-or-reuse: if an embeddings server already answers for `served_model`
# at the target (an externally-managed mlx-openai-server, Ollama, which serves
# /v1/embeddings natively, or a prior launch), launch() REUSES it without
# spawning, so it never double-spawns. teardown() only stops a child THIS
# backend spawned (it never kills an external server).
# =============================================================================
struct SpawningMlxEmbedBackend[C: Connector](InferenceBackend, Movable):
    """Spawning MLX embeddings backend (`mlx-openai-server --model-type
    embeddings`) — the macOS embeddings engine.

    `launch()` spawns `mlx-openai-server launch --model-type embeddings
    --model-path <path> --served-model-name <name> --host <host> --port <p>`
    (unless an embeddings endpoint is already serving at the target, in which
    case it reuses it), then blocks until a live POST /v1/embeddings probe
    succeeds. `health()` is the real POST probe. `teardown()` stops the child.

    Construction:
      * SpawningMlxEmbedBackend[C](mk_connector, binary_path, model_path,
        served_model) — defaults host=127.0.0.1, port=8082.
      * SpawningMlxEmbedBackend[C](mk_connector, binary_path, model_path,
        served_model, host, port).
    Bind `C = KernelTcpConnector` in production. `served_model` MUST equal the
    server's `--served-model-name` (the embeddings server 404s any other value).
    """

    var _mk_connector: def () thin -> Self.C
    var _binary_path: String
    var _model_path: String
    var _served_model: String
    var _host: String
    var _port: UInt16
    var _launch_timeout_ms: Int
    # The engine's max concurrent requests per model. Carried for symmetry with
    # the chat backends, but the embeddings server exposes no concurrency flag
    # (see build_mlx_embed_child_spec), so it emits nothing; the caller's
    # admission limit is the bound.
    var _num_parallel: Int
    var _spawned: Bool
    var _child: DetachedChild

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        binary_path: String,
        model_path: String,
        served_model: String,
    ):
        """Defaults: host=127.0.0.1, port=8082, num_parallel=1."""
        self._mk_connector = mk_connector
        self._binary_path = binary_path
        self._model_path = model_path
        self._served_model = served_model
        self._host = String("127.0.0.1")
        self._port = UInt16(8082)
        self._launch_timeout_ms = DEFAULT_LAUNCH_TIMEOUT_MS
        self._num_parallel = DEFAULT_NUM_PARALLEL
        self._spawned = False
        self._child = DetachedChild(Int32(-1))

    def __init__(
        out self,
        mk_connector: def () thin -> Self.C,
        binary_path: String,
        model_path: String,
        served_model: String,
        host: String,
        port: UInt16,
        num_parallel: Int = DEFAULT_NUM_PARALLEL,
    ):
        """Explicit host + port (+ optional engine num_parallel, which the
        embeddings server ignores; see build_mlx_embed_child_spec)."""
        self._mk_connector = mk_connector
        self._binary_path = binary_path
        self._model_path = model_path
        self._served_model = served_model
        self._host = host
        self._port = port
        self._launch_timeout_ms = DEFAULT_LAUNCH_TIMEOUT_MS
        self._num_parallel = num_parallel
        self._spawned = False
        self._child = DetachedChild(Int32(-1))

    def set_launch_timeout_ms(mut self, ms: Int):
        """The readiness budget of the next launch() (default
        DEFAULT_LAUNCH_TIMEOUT_MS)."""
        self._launch_timeout_ms = ms

    def child_spec(self) -> ChildSpec:
        """The `ChildSpec` `launch()` would spawn (the unit-test seam)."""
        return build_mlx_embed_child_spec(
            self._binary_path,
            self._model_path,
            self._served_model,
            self._host,
            self._port,
        )

    def launch(mut self) raises -> String:
        """Reuse an embeddings endpoint already serving `served_model` at the
        target (an external Ollama or any /v1/embeddings server), or spawn
        mlx-openai-server and wait for its POST /v1/embeddings probe; return the
        base URL."""
        var spec = self.child_spec()
        return _launch_impl[Self.C](
            self._mk_connector,
            spec,
            self._host,
            self._port,
            True,
            self._served_model,
            self._launch_timeout_ms,
            String("SpawningMlxEmbedBackend.launch"),
            self._spawned,
            self._child,
        )

    def health(self) -> Bool:
        """REAL POST /v1/embeddings liveness probe (NOT GET /v1/models)."""
        return probe_v1_embeddings[Self.C](
            self._mk_connector, self._host, self._port, self._served_model
        )

    def teardown(mut self):
        """Stop the spawned child (SIGTERM -> grace -> SIGKILL) + reap.
        No-op when this backend did not spawn (external server)."""
        _teardown_impl(self._spawned, self._child)

    def base_url(self) -> String:
        return _base_url_for(self._host, self._port)

    def num_parallel(self) -> Int:
        """The num_parallel this backend was configured with. The embeddings
        server IGNORES it: it has no concurrency flag, so none is passed, and
        the caller's own admission limit is the only bound."""
        return self._num_parallel
