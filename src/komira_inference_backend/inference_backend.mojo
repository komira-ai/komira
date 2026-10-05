# =============================================================================
# komira_inference_backend/inference_backend.mojo
#   The InferenceBackend seam: the inference engine is a swappable detail.
#   `launch()` / `health()` / `teardown()` over an OpenAI-`/v1` endpoint.
#   MlxBackend is the macOS default conformer.
# =============================================================================
#
# This file holds three OpenAI-`/v1` port defaults, a comptime-OS switch between
# them, a four-method trait (launch / health / teardown / base_url), and a
# connect-to-running conformer that returns a configured URL. Its only import
# is `std.sys.info.CompilationTarget`.
#
# THE SEAM. Three lifecycle verbs, which are what a caller needs to point an
# OpenAI-compatible client at a live server:
#   * launch()   — bring the backend up (or connect to an already-running one)
#                  and return the base URL the client should POST to.
#   * health()   — is the endpoint serving? (a liveness probe).
#   * teardown() — release the backend (a no-op for connect-to-running).
# Model download, quantization and idle eviction are not part of this seam;
# they belong to whatever manages the models on the machine.
#
# WHY IT IS THIN. Every candidate engine (Ollama, MLX-LM, llama.cpp, vLLM)
# exposes OpenAI `/v1`, so the caller only ever talks OpenAI-compatible HTTP and
# the engine underneath can be replaced. `comptime if
# CompilationTarget.is_macos()` makes MLX the default backend on Apple Silicon;
# other engines are further conformers of THIS trait, plugged in with no change
# to the client. `default_backend_base_url()` is the comptime-OS-selected
# default, which a caller's configuration can override at run time.
#
# MlxBackend connects to an already-running `mlx_lm.server` at a configured
# base URL: its `launch()` does NOT spawn a process. The spawning conformers
# are in spawning_backend.mojo, behind the same trait.
#
# The surface is owned Strings and values: no UnsafePointer in any signature
# and no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Default OpenAI-server ports of the common local-LLM servers. These are the
# conventional defaults; a caller's configuration overrides them.
#   * MLX (mlx_lm.server)    — 8080 (the mlx_lm.server default).
#   * llama.cpp server       — 8080.
#   * Ollama                 — 11434.
# The local base URL uses the loopback IPv4 literal (NOT "localhost"), because
# the HTTP client resolves the host as a dotted quad.
# -----------------------------------------------------------------------------
comptime MLX_DEFAULT_BASE_URL: String = "http://127.0.0.1:8080"
comptime LLAMACPP_DEFAULT_BASE_URL: String = "http://127.0.0.1:8080"
comptime OLLAMA_DEFAULT_BASE_URL: String = "http://127.0.0.1:11434"


def default_backend_base_url() -> String:
    """The comptime-OS-selected default backend base URL.

    macOS -> MLX (the Apple-Silicon default). Other OSes -> the
    llama.cpp/Ollama-compatible default (same OpenAI `/v1` wire). A caller's
    configuration can override this at run time."""

    comptime if CompilationTarget.is_macos():
        return MLX_DEFAULT_BASE_URL
    return LLAMACPP_DEFAULT_BASE_URL


# -----------------------------------------------------------------------------
# The InferenceBackend trait. Three lifecycle verbs over an OpenAI-`/v1`
# endpoint. Every conformer serves the SAME OpenAI wire, so the client that
# talks to it is backend-agnostic.
# -----------------------------------------------------------------------------
trait InferenceBackend(Movable):
    """The swappable local-inference engine seam (OpenAI-`/v1` endpoint).

    Conformers bring up / probe / release an engine; a client POSTs to the
    `launch()`-returned base URL. The caller only ever talks OpenAI-compatible
    HTTP, so the engine underneath is a swappable detail.
    """

    def launch(mut self) raises -> String:
        """Bring the backend up (or connect to an already-running one) and
        return the OpenAI base URL to POST to (e.g. http://127.0.0.1:8080).

        Returns:
            The base URL a client should target.
        """
        ...

    def health(self) -> Bool:
        """Liveness probe: is the endpoint serving? A connect-to-running
        backend reports the configured-reachable assumption; a spawning
        backend reports the actual process/endpoint state.

        Returns:
            True if the backend is (believed) serving.
        """
        ...

    def teardown(mut self):
        """Release the backend. A no-op for connect-to-running (the server is
        externally managed); a spawning backend stops its process here."""
        ...

    def base_url(self) -> String:
        """The base URL this backend serves / will serve (without launching).
        Lets a caller read the target before / without `launch()`."""
        ...


# -----------------------------------------------------------------------------
# MlxBackend — the macOS-default conformer, CONNECT-TO-RUNNING: it points at an
# already-running `mlx_lm.server` at a configured base URL, brought up by the
# user or by another process.
#
# Construction:
#   * MlxBackend() — default base_url (MLX_DEFAULT_BASE_URL).
#   * MlxBackend(base_url) — explicit (a configuration override).
# -----------------------------------------------------------------------------
struct MlxBackend(InferenceBackend, Movable):
    """Connect-to-running MLX backend (mlx_lm.server) at a configured base URL.

    `launch()` returns the configured base URL (no process spawn — the server
    is externally managed). The spawning variants are in spawning_backend.mojo,
    behind the same trait.
    """

    var _base_url: String
    # Whether the externally-managed server is assumed reachable. Set True on
    # construction (connect-to-running optimism); health() reports this flag,
    # not a live probe. The spawning backends probe GET /v1/models instead.
    var _assumed_up: Bool

    def __init__(out self):
        """Default MLX base URL (MLX_DEFAULT_BASE_URL)."""
        self._base_url = MLX_DEFAULT_BASE_URL
        self._assumed_up = True

    def __init__(out self, base_url: String):
        """Explicit base URL (a configuration override)."""
        self._base_url = base_url
        self._assumed_up = True

    def launch(mut self) raises -> String:
        """Connect-to-running: return the configured base URL (no spawn)."""
        self._assumed_up = True
        return self._base_url

    def health(self) -> Bool:
        """Report the connect-to-running reachability assumption."""
        return self._assumed_up

    def teardown(mut self):
        """No-op: the mlx_lm.server is externally managed (connect-to-running).
        A spawning variant stops its child process here."""
        self._assumed_up = False

    def base_url(self) -> String:
        return self._base_url


# -----------------------------------------------------------------------------
# default_local_backend — the comptime-OS-selected default backend instance.
# macOS -> MlxBackend at the MLX default. Other OSes also get an MlxBackend,
# pointed at the llama.cpp/Ollama-compatible default base URL (the OpenAI wire
# is identical). A caller can override the base URL either way.
# -----------------------------------------------------------------------------
def default_local_backend() -> MlxBackend:
    """The comptime-OS-selected default local backend (connect-to-running).

    macOS returns an MlxBackend at the MLX default; other OSes return an
    MlxBackend at the llama.cpp/Ollama-compatible default (same wire).
    Override the base_url via `MlxBackend(base_url)` for a non-default
    endpoint."""

    comptime if CompilationTarget.is_macos():
        return MlxBackend(MLX_DEFAULT_BASE_URL)
    return MlxBackend(LLAMACPP_DEFAULT_BASE_URL)
