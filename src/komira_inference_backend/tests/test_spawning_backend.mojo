# The spawning backends without an engine: the child spec each backend would
# spawn (defaults, explicit host and port, the llama-server parallelism flags,
# the MLX specs' indifference to num_parallel), both probes and health()
# against a port nothing listens on, and launch() against a binary that does
# not exist, which must raise naming the spawn failure and leave nothing to
# tear down. Port 1 on loopback is the dead port: it is privileged and no
# test worker serves on it, so a connect there is refused at once.
from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_inference_backend import (
    SpawningMlxBackend,
    SpawningLlamaCppBackend,
    SpawningMlxEmbedBackend,
    probe_v1_models,
    probe_v1_embeddings,
    build_mlx_child_spec,
    build_llamacpp_child_spec,
    build_mlx_embed_child_spec,
)

comptime _C = KernelTcpConnector
comptime _DEAD_PORT: UInt16 = UInt16(1)
comptime _MISSING_BINARY = "/nonexistent/komira-inference-backend/engine"


def test_mlx_backend_defaults_and_explicit_host_port() raises:
    var be = SpawningMlxBackend[_C](
        KernelTcpConnector.new,
        String("/abs/mlx_lm.server"),
        String("/models/Qwen2.5-7B-Instruct-4bit"),
    )
    var spec = be.child_spec()
    assert_equal(spec.path, String("/abs/mlx_lm.server"))
    assert_equal(len(spec.argv), 6)
    assert_equal(spec.argv[3], String("127.0.0.1"))
    assert_equal(spec.argv[5], String("8080"))
    assert_equal(be.base_url(), String("http://127.0.0.1:8080"))
    assert_equal(be.num_parallel(), 1)

    var be2 = SpawningMlxBackend[_C](
        KernelTcpConnector.new,
        String("/abs/mlx_lm.server"),
        String("the-model"),
        String("0.0.0.0"),
        UInt16(9001),
    )
    var spec2 = be2.child_spec()
    assert_equal(spec2.argv[3], String("0.0.0.0"))
    assert_equal(spec2.argv[5], String("9001"))
    assert_equal(be2.base_url(), String("http://0.0.0.0:9001"))


def test_llamacpp_argv_in_full() raises:
    var spec = build_llamacpp_child_spec(
        String("/usr/local/bin/llama-server"),
        String("/models/qwen.gguf"),
        String("127.0.0.1"),
        UInt16(8080),
    )
    var want: List[String] = [
        "--model",
        "/models/qwen.gguf",
        "--host",
        "127.0.0.1",
        "--port",
        "8080",
        "--n-gpu-layers",
        "99",
    ]
    assert_equal(len(spec.argv), len(want), "no parallelism flag at num_parallel=1")
    for i in range(len(want)):
        assert_equal(spec.argv[i], want[i])

    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String("/usr/local/bin/llama-server"),
        String("/models/qwen.gguf"),
    )
    assert_equal(len(be.child_spec().argv), len(want))
    assert_equal(be.base_url(), String("http://127.0.0.1:8080"))
    assert_equal(be.num_parallel(), 1)


def test_llamacpp_parallel_flags_follow_num_parallel() raises:
    var spec = build_llamacpp_child_spec(
        String("/usr/local/bin/llama-server"),
        String("/models/qwen.gguf"),
        String("127.0.0.1"),
        UInt16(8080),
        4,
    )
    assert_equal(len(spec.argv), 11)
    assert_equal(spec.argv[8], String("--parallel"))
    assert_equal(spec.argv[9], String("4"))
    assert_equal(spec.argv[10], String("--cont-batching"))

    # The backend passes its num_parallel to the spec it spawns.
    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String("/usr/local/bin/llama-server"),
        String("/models/qwen.gguf"),
        String("127.0.0.1"),
        UInt16(8080),
        4,
    )
    assert_equal(be.num_parallel(), 4)
    var s2 = be.child_spec()
    assert_equal(len(s2.argv), 11)
    assert_equal(s2.argv[9], String("4"))

    # num_parallel = 1 adds nothing.
    var one = build_llamacpp_child_spec(
        String("/usr/local/bin/llama-server"),
        String("/models/qwen.gguf"),
        String("127.0.0.1"),
        UInt16(8080),
        1,
    )
    assert_equal(len(one.argv), 8)


def test_mlx_specs_ignore_num_parallel() raises:
    # mlx_lm.server has no concurrency flag: the argv is the same at 1 and 4.
    var s1 = build_mlx_child_spec(
        String("/abs/mlx_lm.server"), String("m"), String("127.0.0.1"), UInt16(8080), 1
    )
    var s4 = build_mlx_child_spec(
        String("/abs/mlx_lm.server"), String("m"), String("127.0.0.1"), UInt16(8080), 4
    )
    assert_equal(len(s1.argv), 6)
    assert_equal(len(s4.argv), 6)
    for i in range(6):
        assert_equal(s1.argv[i], s4.argv[i])
    var be = SpawningMlxBackend[_C](
        KernelTcpConnector.new,
        String("/abs/mlx_lm.server"),
        String("m"),
        String("127.0.0.1"),
        UInt16(8080),
        4,
    )
    assert_equal(be.num_parallel(), 4)
    assert_equal(len(be.child_spec().argv), 6)

    # The embeddings spec takes no num_parallel at all; the backend records it.
    var emb = SpawningMlxEmbedBackend[_C](
        KernelTcpConnector.new,
        String("/abs/mlx-openai-server"),
        String("/models/bge-small"),
        String("bge-small"),
        String("127.0.0.1"),
        UInt16(8082),
        4,
    )
    assert_equal(emb.num_parallel(), 4)
    assert_equal(len(emb.child_spec().argv), 14)


def test_mlx_embed_argv_in_full() raises:
    var spec = build_mlx_embed_child_spec(
        String("/abs/mlx-openai-server"),
        String("/models/bge-small"),
        String("bge-small"),
        String("127.0.0.1"),
        UInt16(8082),
    )
    var want: List[String] = [
        "launch",
        "--model-type",
        "embeddings",
        "--model-path",
        "/models/bge-small",
        "--served-model-name",
        "bge-small",
        "--host",
        "127.0.0.1",
        "--port",
        "8082",
        "--no-log-file",
        "--log-level",
        "INFO",
    ]
    assert_equal(len(spec.argv), len(want))
    for i in range(len(want)):
        assert_equal(spec.argv[i], want[i])

    var be = SpawningMlxEmbedBackend[_C](
        KernelTcpConnector.new,
        String("/abs/mlx-openai-server"),
        String("/models/bge-small"),
        String("bge-small"),
    )
    assert_equal(be.base_url(), String("http://127.0.0.1:8082"))


def test_probes_report_a_dead_port_as_unhealthy() raises:
    # A refused connect is "not serving", never an exception.
    assert_false(
        probe_v1_models[_C](KernelTcpConnector.new, String("127.0.0.1"), _DEAD_PORT)
    )
    assert_false(
        probe_v1_embeddings[_C](
            KernelTcpConnector.new, String("127.0.0.1"), _DEAD_PORT, String("m")
        )
    )
    var chat = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String("/usr/local/bin/llama-server"),
        String("m"),
        String("127.0.0.1"),
        _DEAD_PORT,
    )
    assert_false(chat.health())
    var emb = SpawningMlxEmbedBackend[_C](
        KernelTcpConnector.new,
        String("/abs/mlx-openai-server"),
        String("/models/m"),
        String("m"),
        String("127.0.0.1"),
        _DEAD_PORT,
    )
    assert_false(emb.health())


def test_launch_raises_when_the_engine_cannot_be_spawned() raises:
    # Nothing answers on the dead port, so launch() spawns; the binary does not
    # exist, so the spawn fails and launch() raises naming it.
    var chat = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String(_MISSING_BINARY),
        String("m"),
        String("127.0.0.1"),
        _DEAD_PORT,
    )
    var chat_msg = String("")
    try:
        _ = chat.launch()
    except e:
        chat_msg = String(e)
    assert_true(chat_msg.find("spawn failed") >= 0, chat_msg)
    assert_true(chat_msg.find(_MISSING_BINARY) >= 0, chat_msg)
    chat.teardown()  # nothing was spawned: a no-op
    assert_false(chat.health())

    var mlx = SpawningMlxBackend[_C](
        KernelTcpConnector.new,
        String(_MISSING_BINARY),
        String("m"),
        String("127.0.0.1"),
        _DEAD_PORT,
    )
    var mlx_msg = String("")
    try:
        _ = mlx.launch()
    except e:
        mlx_msg = String(e)
    assert_true(mlx_msg.find("spawn failed") >= 0, mlx_msg)
    mlx.teardown()

    var emb = SpawningMlxEmbedBackend[_C](
        KernelTcpConnector.new,
        String(_MISSING_BINARY),
        String("/models/m"),
        String("m"),
        String("127.0.0.1"),
        _DEAD_PORT,
    )
    var emb_msg = String("")
    try:
        _ = emb.launch()
    except e:
        emb_msg = String(e)
    assert_true(emb_msg.find("spawn failed") >= 0, emb_msg)
    assert_true(emb_msg.find(_MISSING_BINARY) >= 0, emb_msg)
    emb.teardown()


def main() raises:
    test_mlx_backend_defaults_and_explicit_host_port()
    test_llamacpp_argv_in_full()
    test_llamacpp_parallel_flags_follow_num_parallel()
    test_mlx_specs_ignore_num_parallel()
    test_mlx_embed_argv_in_full()
    test_probes_report_a_dead_port_as_unhealthy()
    test_launch_raises_when_the_engine_cannot_be_spawned()
    print("PASS test_spawning_backend")
