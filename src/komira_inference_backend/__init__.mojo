"""`komira_inference_backend`: bring up an OpenAI-`/v1` inference server, ask
whether it is serving, and tear it down.

Every common local engine (MLX-LM, llama.cpp, Ollama, vLLM) speaks the OpenAI
`/v1` wire, so a caller talks OpenAI-compatible HTTP to whatever base URL a
backend returns, and the engine underneath is a swappable detail.

PUBLIC SURFACE:
  InferenceBackend — the trait: `launch()` returns the base URL to POST to,
    `health()` is a liveness probe, `teardown()` releases the engine, and
    `base_url()` reads the target without launching.
  MlxBackend — connect-to-running: returns a configured URL and spawns
    nothing. `default_local_backend()` / `default_backend_base_url()` pick the
    MLX default on macOS and the llama.cpp-compatible default elsewhere;
    MLX_DEFAULT_BASE_URL, LLAMACPP_DEFAULT_BASE_URL, OLLAMA_DEFAULT_BASE_URL.
  SpawningMlxBackend[C] / SpawningLlamaCppBackend[C] / SpawningMlxEmbedBackend[C]
    — spawn `mlx_lm.server` / `llama-server` / `mlx-openai-server
    --model-type embeddings` as a child process (komira_supervisor, with
    inherited stdio), wait until it answers, and stop it on teardown. An
    endpoint already serving at the target is reused, never killed; reuse
    does not check which model it has loaded. A child that exits during the
    wait fails the launch at once, with its exit status. `C` is the
    komira_http_core Connector the probes dial with.
  build_mlx_child_spec / build_llamacpp_child_spec / build_mlx_embed_child_spec
    — the argv each spawn uses, built without spawning.
  probe_v1_models / probe_v1_embeddings — the liveness probes:
    `GET /v1/models`, and for the embeddings server `POST /v1/embeddings`;
    True iff 2xx; False on any transport error or after PROBE_TIMEOUT_MS.
  HEALTH_POLL_INTERVAL_MS, DEFAULT_LAUNCH_TIMEOUT_MS, TEARDOWN_GRACE_MS,
    PROBE_TIMEOUT_MS, DEFAULT_NUM_PARALLEL.

The package reads no environment: binary paths, models, hosts and ports are
the caller's arguments. A spawned engine inherits the caller's environment
(ChildSpec's default) and its stdout and stderr.
"""

from .inference_backend import (
    InferenceBackend,
    MlxBackend,
    default_backend_base_url,
    default_local_backend,
    MLX_DEFAULT_BASE_URL,
    LLAMACPP_DEFAULT_BASE_URL,
    OLLAMA_DEFAULT_BASE_URL,
)
from .spawning_backend import (
    SpawningMlxBackend,
    SpawningLlamaCppBackend,
    SpawningMlxEmbedBackend,
    probe_v1_models,
    probe_v1_embeddings,
    build_mlx_child_spec,
    build_llamacpp_child_spec,
    build_mlx_embed_child_spec,
    HEALTH_POLL_INTERVAL_MS,
    DEFAULT_LAUNCH_TIMEOUT_MS,
    TEARDOWN_GRACE_MS,
    PROBE_TIMEOUT_MS,
    DEFAULT_NUM_PARALLEL,
)
