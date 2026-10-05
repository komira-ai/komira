# `komira_localmodel`

## Responsibility

Running local inference engines as supervised children. An engine here is a
server process with an OpenAI-compatible `/v1` API (an MLX server, a
llama.cpp server). It takes memory, takes seconds to load, and should be
unloaded when nobody uses it. This package decides whether a model fits on the
host, starts and stops engine children, keeps a bounded number of them
resident, bounds the requests in flight against each, and serves a loopback
HTTP control API in front of them.

It does not know how to start any particular engine. A caller implements
`LocalBackend` (launch, health, teardown, base URL) for its engine and
`OpenAiForwarder` (send a `/v1` request body to a base URL) with its HTTP
client. It does not download models: a registered model is assumed to be on
disk.

## API

| name | file | what it is |
|---|---|---|
| `HostMemoryProfile`, `PLATFORM_*` | [host_profile.mojo](host_profile.mojo) | total RAM, discrete-GPU VRAM, unified-memory flag, platform; `detect()` probes sysctl on macOS, /proc/meminfo and nvidia-smi on Linux |
| `ModelVariant`, `CatalogEntry`, `FitResult`, `FIT_GREEN` / `FIT_YELLOW` / `FIT_RED` | [fit_resolver.mojo](fit_resolver.mojo) | one quantization of a model, a model with its quantizations, a fit answer |
| `fit`, `fit_concurrent`, `auto_pick_highest_green_quant` | [fit_resolver.mojo](fit_resolver.mojo) | the pure fit rating, and the highest-quality quantization that fits |
| `estimate_resident_bytes*`, `model_footprint_bytes*`, `kv_cache_bytes*` | [fit_resolver.mojo](fit_resolver.mojo) | the terms of the estimate |
| `SupervisorRegistry`, `ChildHandle`, `ChildState`, `find_free_port` | [supervisor_registry.mojo](supervisor_registry.mojo) | N supervised children keyed by id; a free loopback port |
| `BackendSupervisor`, `LocalBackend`, `MonotonicClock`, `SystemClock`, `ModelStatus` | [backend_state_machine.mojo](backend_state_machine.mojo) | the per-model state machine and its two seams |
| `ControlApiDispatcher`, `OpenAiForwarder`, `ForwardedResponse`, `ROUTE_*` | [control_api.mojo](control_api.mojo) | a `komira_http_server` `RequestDispatcher` for the control API |

## Semantics

- **Fit.** The resident estimate is padded weights (a per-family fudge factor,
  rounded up) plus the KV cache for N concurrent streams (4 by default) plus a
  2 GiB OS margin. The KV cost per token is the fp16 size from the family's
  architecture (2 × layers × KV heads × head dimension × 2 bytes), rounded up;
  an unknown family is charged as much as Llama-2-13B. The budget is total RAM
  on unified memory and on CPU-only hosts, VRAM on a discrete GPU. GREEN means
  the estimate is at most 85% of the budget, YELLOW at most 100%, RED more.
  The weight fudge factors are uncalibrated; the calibration note at the end
  of `fit_resolver.mojo` says how to tune them.
- **Lifecycle.** A registered model is REGISTERED until the first
  `request_load`, which launches it (LOADING) and, once the backend's
  `launch()` returns, marks it SERVING. `tick_idle_unload` unloads a SERVING
  model whose last request is older than its keep-alive TTL (per model, or the
  state machine's default). Before a launch, idle resident models are
  unloaded, least recently used first, until the new one fits the byte budget
  and the resident-count cap.
- **Busy models stay loaded.** A model with an admitted or queued request is
  never idle-unloaded, never evicted and refused by `stop`. If the idle
  models are not enough to make room, nothing is unloaded and `request_load`
  returns False with the model still REGISTERED; a retry may succeed once the
  others finish. Only `shutdown_all` unloads busy models.
- **Failure.** A launch that raises leaves the model FAILED with
  `FAIL_LAUNCH`, and the backend's error message in
  `ModelStatus.failure_detail`; a model larger than the whole budget is FAILED
  with `FAIL_WONT_FIT` before anything is unloaded or launched. A FAILED model
  stays FAILED until `clear_failure`.
- **Admission.** Each model has an in-flight cap (by default 4, or one
  derived from its fit by `derive_concurrency_cap`) and a queue of
  `cap * QUEUE_DEPTH_MULTIPLE`. `admit` answers ADMITTED, QUEUED or REJECTED;
  a queued caller claims a freed slot with `try_promote_if_under_cap`, so
  in-flight never exceeds the cap.
- **Threads.** Every public state-machine method takes one process-global
  mutex (`komira_localmodel_sm_lock`, in komira_async's C shim), so N worker
  threads may share one state machine. The forward to the engine happens
  outside the lock. `request_load` holds the lock through the backend's
  `launch()` and through the teardown of any model it evicts, so a cold start
  stalls every other call into the state machine for its duration.
  `SupervisorRegistry` is not thread-safe; its owner must also call `poll` (or
  `drain_output`) regularly, because an engine that logs blocks once its
  output pipe fills.
- **Control API.** `GET /v1/models`, `GET /models`, `GET /status?id=`,
  `POST /select`, `POST /stop`, and `POST /v1/...` naming a top-level
  `"model"`. The passthrough takes an admission slot, loads the model, and
  forwards the body to the same path on its endpoint; the engine's status,
  content type and body come back unchanged, buffered (a streaming response
  arrives in one piece). Errors are JSON `{"error": ...}` with 400 (including
  a body that is not UTF-8), 404, 500, 502 or 503. There is no
  authentication: host it on a loopback-bound server.

## Use

A model variant against a host profile (here a 16 GiB unified-memory host;
`HostMemoryProfile.detect()` reads the real one):

```mojo
from komira_localmodel import FIT_GREEN, FIT_RED, HostMemoryProfile, ModelVariant, PLATFORM_MACOS, fit
from std.testing import assert_equal

var gib = 1024 * 1024 * 1024
var host = HostMemoryProfile(16 * gib, 0, True, PLATFORM_MACOS)
var small = ModelVariant(String("Qwen-7B-4bit"), String("qwen-7b"), 4 * gib, String("4bit"))
var large = ModelVariant(String("Llama-3.3-70B-Q6"), String("llama-3.3-70b"), 50 * gib, String("Q6"))
assert_equal(fit(small, host).rating, FIT_GREEN)
assert_equal(fit(large, host).rating, FIT_RED)
```

## Tests

Every file in [tests/](tests/) is welded to the package (`test_srcs`). None
needs an engine, a model, a GPU or a network beyond 127.0.0.1:

- `test_localmodel_fit` covers the fit matrix, the KV cost against sizes
  computed by hand from each architecture, the rating drop as concurrency
  grows,
  the quantization picker and the parse helpers.
- `test_localmodel_state_machine` covers load on first request, idle unload,
  LRU eviction and the FAILED states, with a stub backend and a virtual clock.
- `test_localmodel_admission` covers the cap, the queue bound, pull promotion,
  and that a busy model is not unloaded, evicted or stopped.
- `test_localmodel_sm_concurrency` drives one state machine from real
  pthreads: no lost counter updates, the cap holds, a concurrent load
  launches once.
- `test_localmodel_registry` spawns and stops real `sh` children through
  the registry, checks each stopped process is gone, that `poll` drains a
  child's output, and `find_free_port`.
- `test_localmodel_control_api`, `test_localmodel_server_daemon` and
  `test_localmodel_chat` run the control API on a loopback `HttpServer` with
  stub backends and a stub forwarder.
