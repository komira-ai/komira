# =============================================================================
# tests/test_inference_backend_port.mojo — the InferenceBackend seam, the
#   child-spec factories and the comptime-OS default.
# =============================================================================
#
# What this file checks:
#
#   1. A CALLER CAN BRING ITS OWN ENGINE. A struct declared HERE, outside the
#      package, CONFORMS to `InferenceBackend` and is accepted by a
#      `[B: InferenceBackend]` generic. That is the trait's whole premise ("the
#      engine underneath is a swappable detail"), checked at compile time: had
#      the trait been redeclared rather than imported (Mojo traits are nominal),
#      `_launch_through[LocalTestBackend]` would not compile.
#
#   2. THE CHILD-SPEC FACTORIES. `build_mlx_child_spec` /
#      `build_llamacpp_child_spec` / `build_mlx_embed_child_spec` assemble the
#      exact argv a real spawn depends on. They are free functions precisely
#      BECAUSE a test cannot spawn a multi-GB inference engine; they are the
#      unit-test seam. A silent argv change here is an engine that fails to
#      start on a developer's machine, with nothing pointing back at the change.
#
#   3. THE COMPTIME-OS DEFAULT RESOLVES. `default_backend_base_url()` /
#      `default_local_backend()` switch on `CompilationTarget.is_macos()`.
#
# The spawning backends' probes and launch failure are in
# test_spawning_backend.mojo.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_inference_backend.inference_backend import (
    InferenceBackend,
    MlxBackend,
    default_backend_base_url,
    default_local_backend,
    MLX_DEFAULT_BASE_URL,
    LLAMACPP_DEFAULT_BASE_URL,
    OLLAMA_DEFAULT_BASE_URL,
)
from komira_inference_backend.spawning_backend import (
    build_mlx_child_spec,
    build_llamacpp_child_spec,
    build_mlx_embed_child_spec,
)


# =============================================================================
# §1 — A conformer declared outside the package.
# =============================================================================
struct LocalTestBackend(InferenceBackend, Movable):
    """An `InferenceBackend` conformer written HERE: a caller binding its own
    engine.

    Deliberately trivial — it reports a fixed URL and tracks its own liveness.
    The point is not what it does; it is that it COMPILES and satisfies the
    trait's full four-method contract."""

    var _url: String
    var _up: Bool

    def __init__(out self, url: String):
        self._url = url
        self._up = False

    def launch(mut self) raises -> String:
        self._up = True
        return self._url

    def health(self) -> Bool:
        return self._up

    def teardown(mut self):
        self._up = False

    def base_url(self) -> String:
        return self._url


def _launch_through[B: InferenceBackend](mut backend: B) raises -> String:
    """A `[B: InferenceBackend]` generic — the shape every caller uses."""
    return backend.launch()


def test_a_caller_can_declare_its_own_engine() raises:
    """The trait's stated premise: 'the engine underneath is a swappable
    detail'. A conformer declared outside the package satisfies the generic."""
    var be = LocalTestBackend(String("http://127.0.0.1:9999"))
    assert_false(be.health(), "a backend is not up before launch()")
    var url = _launch_through[LocalTestBackend](be)
    assert_equal(url, String("http://127.0.0.1:9999"), "launch returns the URL")
    assert_true(be.health(), "up after launch()")
    be.teardown()
    assert_false(be.health(), "down after teardown()")


def test_shipped_conformer_satisfies_the_same_generic() raises:
    """`MlxBackend` (the connect-to-running conformer) satisfies the SAME
    generic as the locally-declared one."""
    var be = MlxBackend(String("http://127.0.0.1:8080"))
    var url = _launch_through[MlxBackend](be)
    assert_equal(url, String("http://127.0.0.1:8080"))
    assert_true(be.health(), "connect-to-running reports its reachability")
    be.teardown()
    assert_false(be.health(), "teardown drops the assumption")


# =============================================================================
# §2 — The child-spec factories.
#      A silent argv change here is an engine that fails to start, with nothing
#      pointing back at the change.
# =============================================================================
def test_mlx_child_spec_argv_is_unchanged() raises:
    var spec = build_mlx_child_spec(
        String("/abs/mlx_lm.server"),
        String("/models/Qwen2.5-7B-Instruct-4bit"),
        String("127.0.0.1"),
        UInt16(8080),
    )
    assert_equal(spec.path, String("/abs/mlx_lm.server"))
    # argv[0] is defaulted to `path` by Supervisor.spawn, so argv holds the flags.
    assert_equal(len(spec.argv), 6, "mlx_lm.server takes exactly these 6 tokens")
    assert_equal(spec.argv[0], String("--model"))
    assert_equal(spec.argv[1], String("/models/Qwen2.5-7B-Instruct-4bit"))
    assert_equal(spec.argv[2], String("--host"))
    assert_equal(spec.argv[3], String("127.0.0.1"))
    assert_equal(spec.argv[4], String("--port"))
    assert_equal(spec.argv[5], String("8080"))


def test_llamacpp_child_spec_keeps_its_gpu_offload_flag() raises:
    """The llama.cpp spec's distinguishing addition over MLX is
    `--n-gpu-layers`, which offloads the model to the GPU when there is one."""
    var spec = build_llamacpp_child_spec(
        String("/abs/llama-server"),
        String("/models/model.gguf"),
        String("127.0.0.1"),
        UInt16(8080),
    )
    assert_equal(spec.path, String("/abs/llama-server"))
    var saw_ngl = False
    for i in range(len(spec.argv)):
        if spec.argv[i] == String("--n-gpu-layers"):
            saw_ngl = True
    assert_true(saw_ngl, "the spec carries the GPU-offload flag")
    assert_equal(spec.argv[0], String("--model"))
    assert_equal(spec.argv[1], String("/models/model.gguf"))


def test_mlx_embed_child_spec_is_the_separate_embeddings_engine() raises:
    """The EMBEDDINGS engine is a DIFFERENT package (`mlx-openai-server`) with a
    `launch` subcommand and `--model-path`, not `mlx_lm.server`'s `--model`.
    Conflating the two is the mistake this assertion exists to catch."""
    var spec = build_mlx_embed_child_spec(
        String("/abs/mlx-openai-server"),
        String("/models/bge-small"),
        String("bge-small"),
        String("127.0.0.1"),
        UInt16(8081),
    )
    assert_equal(spec.path, String("/abs/mlx-openai-server"))
    var saw_launch = False
    var saw_model_path = False
    var saw_served = False
    for i in range(len(spec.argv)):
        if spec.argv[i] == String("launch"):
            saw_launch = True
        if spec.argv[i] == String("--model-path"):
            saw_model_path = True
        if spec.argv[i] == String("--served-model-name"):
            saw_served = True
    assert_true(saw_launch, "the spec carries the `launch` subcommand")
    assert_true(saw_model_path, "the spec carries --model-path (NOT --model)")
    assert_true(
        saw_served,
        "the spec carries --served-model-name: the server 404s any other model value",
    )


# =============================================================================
# §3 — The comptime-OS default resolves.
# =============================================================================
def test_comptime_os_default_resolves_to_a_real_url() raises:
    """`comptime if CompilationTarget.is_macos()` picks the default. Assert the
    SELECTION, not one platform's answer."""
    var url = default_backend_base_url()
    assert_true(
        url == MLX_DEFAULT_BASE_URL or url == LLAMACPP_DEFAULT_BASE_URL,
        "the OS switch picks one of the two declared defaults",
    )
    var be = default_local_backend()
    assert_equal(
        be.base_url(), url, "the default backend targets the default URL"
    )


def test_the_three_port_defaults_are_distinguishable() raises:
    """Ollama's default port differs from MLX's and llama.cpp's; MLX and
    llama.cpp share 8080 by convention. Pinning this keeps a future edit from
    collapsing them into one constant."""
    assert_equal(MLX_DEFAULT_BASE_URL, LLAMACPP_DEFAULT_BASE_URL)
    assert_true(
        OLLAMA_DEFAULT_BASE_URL != MLX_DEFAULT_BASE_URL,
        "Ollama listens on its own port (11434)",
    )


def main() raises:
    test_a_caller_can_declare_its_own_engine()
    test_shipped_conformer_satisfies_the_same_generic()
    test_mlx_child_spec_argv_is_unchanged()
    test_llamacpp_child_spec_keeps_its_gpu_offload_flag()
    test_mlx_embed_child_spec_is_the_separate_embeddings_engine()
    test_comptime_os_default_resolves_to_a_real_url()
    test_the_three_port_defaults_are_distinguishable()
    print("PASS test_inference_backend_port")
