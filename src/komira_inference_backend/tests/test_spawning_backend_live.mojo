# The spawning backends against a running engine: stub_openai_server, a test
# binary staged as this test's data, stands in for llama-server,
# mlx_lm.server and mlx-openai-server (it takes their argv and serves the two
# probe endpoints on 127.0.0.1). Each case takes a free loopback port of its
# own.
#
#   * Both probes see a serving engine; the embeddings probe refuses a model
#     the server does not serve; a 5xx is not serving; a server that accepts
#     and never answers is not serving, and the probe returns within its
#     deadline.
#   * launch -> health -> teardown for all three backends, then a second
#     launch and teardown of the same backend, which must stop the second
#     child too.
#   * An engine that writes far more log output than a pipe holds before it
#     listens still comes up.
#   * An engine that exits at once fails launch() at once, with its exit code.
#   * An engine that never becomes healthy fails launch() after the budget,
#     and its child is stopped.
#   * A server already answering at the target is reused (launch() spawns
#     nothing, so a missing binary does not matter) and teardown() leaves it
#     running.
from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_clock import now_ns
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_inference_backend import (
    SpawningMlxBackend,
    SpawningLlamaCppBackend,
    SpawningMlxEmbedBackend,
    probe_v1_models,
    probe_v1_embeddings,
    PROBE_TIMEOUT_MS,
)
from komira_supervisor import DetachedChild, spawn_detached

comptime _C = KernelTcpConnector
# Staged by the BUCK file's test_data; the test runs with share/ as its
# current directory.
comptime _STUB = "stub/stub_openai_server"
comptime _MISSING_BINARY = "/nonexistent/komira-inference-backend/engine"
comptime _HOST = "127.0.0.1"
comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def _elapsed_ms(start: UInt64) -> Int:
    return Int((now_ns() - start) // UInt64(1_000_000))


def _sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    return addr^


def _free_port() raises -> UInt16:
    """A loopback port the kernel just handed out and nothing holds."""
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < Int32(0):
        raise Error("test: socket() failed")
    var addr = _sockaddr_in_loopback(UInt16(0))
    # SAFETY: stack locals; bind(2) / getsockname(2) read or write them
    # synchronously and keep no pointer.
    if (
        external_call["bind", Int32](
            fd, UnsafePointer(to=addr).bitcast[UInt8](), UInt32(16)
        )
        < Int32(0)
    ):
        _ = external_call["close", Int32](fd)
        raise Error("test: bind() failed")
    var sa = Array[UInt8, 16](fill=UInt8(0))
    var sa_len = Array[UInt32, 1](fill=UInt32(16))
    var rc = external_call["getsockname", Int32](
        fd, sa.unsafe_ptr(), sa_len.unsafe_ptr()
    )
    _ = external_call["close", Int32](fd)
    if rc < Int32(0):
        raise Error("test: getsockname() failed")
    return UInt16(Int(sa[2]) << 8 | Int(sa[3]))


def _accepts(port: UInt16) -> Bool:
    """Whether a TCP connect to 127.0.0.1:port succeeds."""
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < Int32(0):
        return False
    var addr = _sockaddr_in_loopback(port)
    # SAFETY: `addr` is a stack local; connect(2) reads it synchronously.
    var rc = external_call["connect", Int32](
        fd, UnsafePointer(to=addr).bitcast[UInt8](), UInt32(16)
    )
    _ = external_call["close", Int32](fd)
    return rc == Int32(0)


def _start_stub(var argv: List[String]) raises -> DetachedChild:
    var pid = spawn_detached(String(_STUB), argv, List[String]())
    if pid <= Int32(0):
        raise Error("test: cannot spawn " + String(_STUB) + " rc=" + String(Int(pid)))
    return DetachedChild(pid)


def _chat_argv(model: String, port: UInt16) -> List[String]:
    return [
        "--model", model, "--host", _HOST, "--port", String(Int(port))
    ]


def _embed_argv(model_path: String, served: String, port: UInt16) -> List[String]:
    return [
        "launch",
        "--model-type",
        "embeddings",
        "--model-path",
        model_path,
        "--served-model-name",
        served,
        "--host",
        _HOST,
        "--port",
        String(Int(port)),
    ]


def _wait_accepting(port: UInt16) raises:
    var start = now_ns()
    while not _accepts(port):
        if _elapsed_ms(start) > 30000:
            raise Error("test: stub never listened on port " + String(Int(port)))
        _sleep_ms(20)


def _stop(child: DetachedChild):
    _ = child.kill()
    for _ in range(500):
        if not child.poll_exit().running:
            return
        _sleep_ms(10)


def test_probes_see_a_serving_engine() raises:
    var port = _free_port()
    var chat = _start_stub(_chat_argv(String("m"), port))
    _wait_accepting(port)
    assert_true(
        probe_v1_models[_C](KernelTcpConnector.new, String(_HOST), port),
        "GET /v1/models answers 200",
    )
    _stop(chat)

    var eport = _free_port()
    var emb = _start_stub(_embed_argv(String("/models/e"), String("m"), eport))
    _wait_accepting(eport)
    assert_true(
        probe_v1_embeddings[_C](
            KernelTcpConnector.new, String(_HOST), eport, String("m")
        ),
        "POST /v1/embeddings for the served model answers 200",
    )
    assert_false(
        probe_v1_embeddings[_C](
            KernelTcpConnector.new, String(_HOST), eport, String("other")
        ),
        "a model the server does not serve is a 404, not serving",
    )
    _stop(emb)

    # Embeddings answer 200, so the server is up; /v1/models answers 503.
    var sport = _free_port()
    var five = _start_stub(_embed_argv(String("status=503"), String("m"), sport))
    _wait_accepting(sport)
    assert_true(
        probe_v1_embeddings[_C](
            KernelTcpConnector.new, String(_HOST), sport, String("m")
        )
    )
    assert_false(
        probe_v1_models[_C](KernelTcpConnector.new, String(_HOST), sport),
        "a 5xx is not serving",
    )
    _stop(five)


def test_a_stalled_server_is_not_serving_within_the_probe_deadline() raises:
    var port = _free_port()
    var stalled = _start_stub(_chat_argv(String("stall"), port))
    _wait_accepting(port)
    var start = now_ns()
    var up = probe_v1_models[_C](KernelTcpConnector.new, String(_HOST), port)
    var took = _elapsed_ms(start)
    _stop(stalled)
    assert_false(up, "a server that never answers is not serving")
    assert_true(
        took >= PROBE_TIMEOUT_MS - 100,
        "the probe waited for its deadline: " + String(took) + "ms",
    )
    assert_true(
        took < PROBE_TIMEOUT_MS + 3000,
        "the probe returned at its deadline: " + String(took) + "ms",
    )


def test_launch_health_teardown_and_relaunch() raises:
    var port = _free_port()
    var base = String("http://127.0.0.1:") + String(Int(port))
    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new, String(_STUB), String("m"), String(_HOST), port
    )
    be.set_launch_timeout_ms(60000)
    assert_false(be.health(), "nothing serves before launch()")
    assert_equal(be.launch(), base)
    assert_true(be.health(), "the spawned engine serves")
    assert_equal(be.launch(), base, "a second launch() reuses the running engine")
    be.teardown()
    assert_false(be.health(), "teardown() stopped the engine")
    assert_false(_accepts(port), "and its port is closed")

    # The same backend again: the second child must be stopped as well.
    assert_equal(be.launch(), base)
    assert_true(be.health())
    be.teardown()
    assert_false(be.health(), "teardown() stopped the relaunched engine")
    assert_false(_accepts(port))

    var mport = _free_port()
    var mlx = SpawningMlxBackend[_C](
        KernelTcpConnector.new, String(_STUB), String("m"), String(_HOST), mport
    )
    mlx.set_launch_timeout_ms(60000)
    _ = mlx.launch()
    assert_true(mlx.health())
    mlx.teardown()
    assert_false(mlx.health())

    var eport = _free_port()
    var emb = SpawningMlxEmbedBackend[_C](
        KernelTcpConnector.new,
        String(_STUB),
        String("/models/e"),
        String("e"),
        String(_HOST),
        eport,
    )
    emb.set_launch_timeout_ms(60000)
    assert_equal(emb.launch(), String("http://127.0.0.1:") + String(Int(eport)))
    assert_true(emb.health())
    emb.teardown()
    assert_false(emb.health())
    assert_false(_accepts(eport))


def test_a_chatty_engine_still_comes_up() raises:
    # 128 KiB to each of stdout and stderr before listening: twice what a
    # default Linux pipe holds, so an undrained capture pipe would block the
    # engine before it ever served.
    var port = _free_port()
    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String(_STUB),
        String("flood=131072"),
        String(_HOST),
        port,
    )
    be.set_launch_timeout_ms(30000)
    _ = be.launch()
    # Every request adds a log line on both streams.
    for _ in range(50):
        assert_true(be.health())
    be.teardown()
    assert_false(be.health())


def test_an_engine_that_exits_fails_the_launch_at_once() raises:
    var port = _free_port()
    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String(_STUB),
        String("exit=3"),
        String(_HOST),
        port,
    )
    be.set_launch_timeout_ms(60000)
    var start = now_ns()
    var msg = String("")
    try:
        _ = be.launch()
    except e:
        msg = String(e)
    var took = _elapsed_ms(start)
    assert_true(msg.find("exited with code 3") >= 0, msg)
    assert_true(msg.find(_STUB) >= 0, msg)
    assert_true(took < 20000, "raised without waiting out the budget: " + String(took) + "ms")
    be.teardown()  # the child is already reaped: a no-op


def test_an_engine_that_never_serves_times_out_and_is_stopped() raises:
    var port = _free_port()
    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String(_STUB),
        String("stall"),
        String(_HOST),
        port,
    )
    be.set_launch_timeout_ms(3000)
    var start = now_ns()
    var msg = String("")
    try:
        _ = be.launch()
    except e:
        msg = String(e)
    var took = _elapsed_ms(start)
    assert_true(msg.find("did not become healthy") >= 0, msg)
    assert_true(took >= 3000, "the budget was spent: " + String(took) + "ms")
    # Budget, plus at most one probe and one poll interval, plus the stop.
    assert_true(
        took < 3000 + PROBE_TIMEOUT_MS + 500 + 5000,
        "the budget is wall time, not sleep time: " + String(took) + "ms",
    )
    assert_false(_accepts(port), "the stalled engine was stopped")


def test_a_reused_server_is_never_stopped() raises:
    var port = _free_port()
    var external = _start_stub(_chat_argv(String("m"), port))
    _wait_accepting(port)
    var be = SpawningLlamaCppBackend[_C](
        KernelTcpConnector.new,
        String(_MISSING_BINARY),
        String("m"),
        String(_HOST),
        port,
    )
    # Spawning would fail on the missing binary, so a URL back means reuse.
    assert_equal(be.launch(), String("http://127.0.0.1:") + String(Int(port)))
    be.teardown()
    assert_true(be.health(), "teardown() left the external server running")
    _stop(external)

    var eport = _free_port()
    var ext_emb = _start_stub(_embed_argv(String("/models/e"), String("e"), eport))
    _wait_accepting(eport)
    var emb = SpawningMlxEmbedBackend[_C](
        KernelTcpConnector.new,
        String(_MISSING_BINARY),
        String("/models/e"),
        String("e"),
        String(_HOST),
        eport,
    )
    assert_equal(emb.launch(), String("http://127.0.0.1:") + String(Int(eport)))
    emb.teardown()
    assert_true(emb.health(), "teardown() left the external server running")
    _stop(ext_emb)


def main() raises:
    test_probes_see_a_serving_engine()
    test_a_stalled_server_is_not_serving_within_the_probe_deadline()
    test_launch_health_teardown_and_relaunch()
    test_a_chatty_engine_still_comes_up()
    test_an_engine_that_exits_fails_the_launch_at_once()
    test_an_engine_that_never_serves_times_out_and_is_stopped()
    test_a_reused_server_is_never_stopped()
    print("PASS test_spawning_backend_live")
