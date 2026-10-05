# komira_inference_backend

Bring up a local OpenAI-`/v1` inference server, ask whether it is serving, and
tear it down.

Every common local engine (MLX-LM, llama.cpp, Ollama, vLLM) serves the OpenAI
`/v1` wire, so a caller only needs a base URL to POST to; which engine answers
is a detail behind one trait.

- `InferenceBackend`: `launch()` returns the base URL, `health()` is a
  liveness probe, `teardown()` releases the engine, `base_url()` reads the
  target without launching.
- `MlxBackend`: connect-to-running. It returns a configured URL and spawns
  nothing. `default_local_backend()` picks the MLX default URL on macOS and
  the llama.cpp-compatible one elsewhere.
- `SpawningMlxBackend[C]`, `SpawningLlamaCppBackend[C]`,
  `SpawningMlxEmbedBackend[C]`: spawn `mlx_lm.server`, `llama-server` or
  `mlx-openai-server --model-type embeddings` as a supervised child
  (`komira_supervisor`), poll until it answers (`GET /v1/models`, or a
  one-input `POST /v1/embeddings` for the embeddings server), and stop it
  with SIGTERM, a grace period and SIGKILL on teardown. A server already
  answering at the target is reused and never stopped. `C` is the
  `komira_http_core` connector the probes dial with.
- `build_mlx_child_spec`, `build_llamacpp_child_spec`,
  `build_mlx_embed_child_spec`: the argv each spawn uses, built without
  spawning. `llama-server` gets `--n-gpu-layers 99`, and `--parallel <N>
  --cont-batching` when asked for N concurrent requests; the MLX servers have
  no such flag and get none.

```mojo
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_inference_backend import SpawningLlamaCppBackend

var be = SpawningLlamaCppBackend[KernelTcpConnector](
    KernelTcpConnector.new, "/usr/local/bin/llama-server", "/models/model.gguf"
)
print(be.base_url())  # http://127.0.0.1:8080
var spec = be.child_spec()  # what launch() spawns
print(spec.argv[6], spec.argv[7])  # --n-gpu-layers 99
```

`be.launch()` spawns that child (or reuses a server already answering at
`127.0.0.1:8080`) and returns the base URL once `GET /v1/models` answers 2xx;
`be.teardown()` stops a child it spawned.

The package reads no environment: binary paths, models, hosts and ports are
the caller's arguments. The welded test spawns nothing: it pins the argv of
each factory, the comptime-OS default, and that a conformer declared outside
the package satisfies the trait.
