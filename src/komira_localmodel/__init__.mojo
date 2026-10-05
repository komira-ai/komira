"""komira_localmodel: lifecycle supervision for local model servers.

A local inference engine (an MLX or llama.cpp server, anything that serves an
OpenAI-compatible `/v1` API) is a child process that takes memory, takes time
to load, and should be unloaded when idle. This package decides whether a
model fits on the host, starts and stops engine children, keeps a bounded
number of them resident, bounds the requests in flight against each one, and
serves a loopback HTTP control API in front of them.

Pieces:
  * HostMemoryProfile: the memory facts a fit decision needs (total RAM,
    discrete-GPU VRAM, whether the memory is unified, the platform), probed
    once with sysctl on macOS and /proc/meminfo + nvidia-smi on Linux.
  * fit / auto_pick_highest_green_quant: a pure fit rating (green / yellow /
    red) for a model variant on a host, from a conservative resident-size
    estimate (padded weights + KV cache for N concurrent streams + an OS
    margin), and a picker that chooses the highest-quality quantization that
    fits.
  * SupervisorRegistry / find_free_port: N supervised children addressed by
    id, and a bind(0) helper that finds a free loopback port for each.
  * BackendSupervisor: the per-model state machine REGISTERED -> LOADING ->
    SERVING -> UNLOADING -> REGISTERED, with load on first request, idle
    unload after a keep-alive TTL, least-recently-used eviction to a resident
    byte and count budget, per-model admission control (a concurrency cap and
    a bounded queue) and FAILED states that name their reason. It is generic
    over a `LocalBackend` (the engine) and a `MonotonicClock` (so tests drive
    virtual time).
  * ControlApiDispatcher: a `RequestDispatcher` for komira_http_server that
    serves list / status / select / stop and forwards `/v1/...` requests to
    the selected model through an `OpenAiForwarder`, loading it first.

Downloading models is out of scope: the state machine assumes a registered
model is already on disk.

No public signature carries a pointer. The sysctl, /proc and nvidia-smi
probes are private helpers; the port helper uses komira_async's
`TcpListener.bind_loopback(0)`.
"""

from .host_profile import (
    HostMemoryProfile,
    PLATFORM_MACOS,
    PLATFORM_LINUX,
    PLATFORM_UNKNOWN,
    platform_name,
)
from .fit_resolver import (
    FitResult,
    ModelVariant,
    CatalogEntry,
    FitRating,
    FIT_GREEN,
    FIT_YELLOW,
    FIT_RED,
    fit,
    fit_concurrent,
    auto_pick_highest_green_quant,
    estimate_resident_bytes,
    estimate_resident_bytes_concurrent,
    model_footprint_bytes,
    model_footprint_bytes_concurrent,
    kv_cache_bytes,
    kv_cache_bytes_concurrent,
    DEFAULT_CONTEXT_TOKENS,
    DEFAULT_MAX_CONCURRENT,
    OS_HEADROOM_BYTES,
    fit_rating_name,
)
from .supervisor_registry import (
    SupervisorRegistry,
    ChildHandle,
    ChildState,
    CHILD_SPAWNED,
    CHILD_GONE,
    CHILD_NOT_FOUND,
    find_free_port,
)
from .backend_state_machine import (
    BackendSupervisor,
    LocalBackend,
    MonotonicClock,
    SystemClock,
    ModelStatus,
    default_monotonic_now_ms,
    model_state_name,
    failure_reason_text,
    admission_decision_name,
    derive_concurrency_cap,
    LM_REGISTERED,
    LM_LOADING,
    LM_SERVING,
    LM_UNLOADING,
    LM_FAILED,
    FAIL_NONE,
    FAIL_LAUNCH,
    FAIL_WONT_FIT,
    ADMIT_ADMITTED,
    ADMIT_QUEUED,
    ADMIT_REJECTED,
    DEFAULT_KEEP_ALIVE_MS,
    DEFAULT_MAX_RESIDENT,
    DEFAULT_MAX_CONCURRENT_PER_MODEL,
    QUEUE_DEPTH_MULTIPLE,
)
from .control_api import (
    ControlApiDispatcher,
    OpenAiForwarder,
    ForwardedResponse,
    ROUTE_V1_MODELS,
    ROUTE_MODELS,
    ROUTE_STATUS,
    ROUTE_SELECT,
    ROUTE_STOP,
)
