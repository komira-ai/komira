# =============================================================================
# komira_test_s3_adapter/tests/test_spawned_process_runner.mojo
#   The runner's pure pieces as values, its health probe over a recording
#   transport, its handle and argv refusals, and (ARM 6) the runner itself
#   over short /bin/sh children, as komira_supervisor's welded scenarios
#   start them. No server is started; the only socket is a dial to
#   127.0.0.1 port 1, which nothing serves, made by `wait_port`'s probe.
# =============================================================================
#
# What each arm would catch:
#   * ARM 1 (argv): `shell_argv_for` dropping setpriv (the server would
#     outlive a killed test), the working directory, or an argument.
#   * ARM 2 (environment): `child_env_for` passing an empty list (which
#     makes spawn_detached inherit the test's environment), or losing an
#     entry.
#   * ARM 3 (exit status): a mapping that reports 0 for a failed server, or
#     a signal kill as an exit code, or treats an unconfirmed end as clean;
#     `wait_port`'s early-exit code disagreeing with `stop`'s.
#   * ARM 4 (health): a probe on the wrong path, without its Host header, or
#     that calls a non-200 answer or a transport failure "ready".
#   * ARM 5 (refusals): an unknown handle stopped or waited on as if it were
#     a child; an empty argv reaching spawn.
#   * ARM 6 (real children): `start` not using `child_env_for` (the child
#     sees the test's TEST_TMPDIR) or not applying the cwd; `wait_port`
#     calling an exited child ready or losing its exit code; `stop` losing
#     the exit code, not sending SIGTERM, not escalating to SIGKILL, or
#     failing on a child `wait_port` already reaped.
#
# EVERY ARM HAS A CONTROL.
# =============================================================================

from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import AwsHttpTransport, HttpResult
from komira_aws_core.credential_transport import CredentialHttpRequest
from komira_libc.posix import _read_env
from komira_supervisor.supervisor import DetachedExit
from komira_test_minio import EnvEntry, ProcessSpec, READINESS_EXITED, READINESS_TIMEOUT

from komira_test_s3_adapter import (
    EMPTY_ENV_MARKER,
    MINIO_HEALTH_PATH,
    SETPRIV,
    SpawnedProcessRunner,
    child_env_for,
    exit_status_of,
    readiness_exit_code,
    minio_health_live,
    minio_health_request,
    shell_argv_for,
)


def _spec(var cwd: String, die: Bool, var env: List[EnvEntry]) -> ProcessSpec:
    var argv: List[String] = ["/opt/minio", "server", "--address", "127.0.0.1:9000"]
    return ProcessSpec(argv^, env^, cwd^, die)


def _raises_with(msg: String, e: Error) -> Bool:
    return String(e).find(msg) >= 0


# =============================================================================
# ARM 1: the shell argv.
# =============================================================================
def test_argv_runs_through_setpriv_in_the_cwd() raises:
    var a = shell_argv_for(_spec(String("/data/run"), True, List[EnvEntry]()))
    assert_equal(len(a), 7)
    assert_equal(a[0], String("-c"))
    assert_equal(a[1], String('cd "$0" && exec ') + SETPRIV + ' --pdeathsig KILL -- "$@"')
    assert_equal(a[2], String("/data/run"))
    assert_equal(a[3], String("/opt/minio"))
    assert_equal(a[6], String("127.0.0.1:9000"))

    # CONTROL: no die_with_parent and no cwd is a bare exec, "$0" a filler.
    var b = shell_argv_for(_spec(String(""), False, List[EnvEntry]()))
    assert_equal(len(b), 7)
    assert_equal(b[1], String('exec "$@"'))
    assert_equal(b[2], String("sh"))
    assert_equal(b[3], String("/opt/minio"))
    assert_false(b[1].find(SETPRIV) >= 0, "setpriv without die_with_parent")

    # die_with_parent without a cwd: setpriv, no cd.
    var c = shell_argv_for(_spec(String(""), True, List[EnvEntry]()))
    assert_equal(c[1], String("exec ") + SETPRIV + ' --pdeathsig KILL -- "$@"')
    assert_equal(c[2], String("sh"))
    print("  test_argv_runs_through_setpriv_in_the_cwd: PASS")


# =============================================================================
# ARM 2: the child's whole environment.
# =============================================================================
def test_env_is_exactly_the_spec() raises:
    var env = List[EnvEntry]()
    env.append(EnvEntry(String("MINIO_ROOT_USER"), String("u")))
    env.append(EnvEntry(String("HOME"), String("/data/run")))
    var e = child_env_for(_spec(String(""), True, env^))
    assert_equal(len(e), 2)
    assert_equal(e[0], String("MINIO_ROOT_USER=u"))
    assert_equal(e[1], String("HOME=/data/run"))

    # CONTROL: an empty spec env is one marker entry, never an empty list
    # (which spawn_detached reads as "inherit the test's environment").
    var none = child_env_for(_spec(String(""), True, List[EnvEntry]()))
    assert_equal(len(none), 1)
    assert_equal(none[0], EMPTY_ENV_MARKER)
    print("  test_env_is_exactly_the_spec: PASS")


# =============================================================================
# ARM 3: the exit status.
# =============================================================================
def _exited(code: Int) -> DetachedExit:
    return DetachedExit(
        running=False, exited=True, exit_code=Int32(code),
        signaled=False, signal=Int32(-1), error=False,
    )


def test_exit_status_keeps_the_code_and_the_signal() raises:
    assert_equal(exit_status_of(_exited(0)), 0)
    assert_equal(exit_status_of(_exited(3)), 3)
    assert_equal(exit_status_of(_exited(255)), 255)
    var killed = DetachedExit(
        running=False, exited=False, exit_code=Int32(-1),
        signaled=True, signal=Int32(9), error=False,
    )
    assert_equal(exit_status_of(killed), 137)
    var termed = DetachedExit(
        running=False, exited=False, exit_code=Int32(-1),
        signaled=True, signal=Int32(15), error=False,
    )
    assert_equal(exit_status_of(termed), 143)

    # CONTROL: an unconfirmed end (waitpid failed) and a running child raise.
    var unknown = DetachedExit(
        running=False, exited=False, exit_code=Int32(-1),
        signaled=False, signal=Int32(-1), error=True,
    )
    var raised = False
    try:
        _ = exit_status_of(unknown)
    except e:
        raised = _raises_with(String("not confirmed"), e)
    assert_true(raised, "a waitpid failure must raise, naming it")
    var running = DetachedExit(
        running=True, exited=False, exit_code=Int32(-1),
        signaled=False, signal=Int32(-1), error=False,
    )
    raised = False
    try:
        _ = exit_status_of(running)
    except e:
        raised = _raises_with(String("still running"), e)
    assert_true(raised, "a running child has no exit status")

    # wait_port's early-exit code is stop's status; -1 only when unconfirmed.
    assert_equal(readiness_exit_code(_exited(5)), 5)
    assert_equal(readiness_exit_code(killed), 137)
    assert_equal(readiness_exit_code(unknown), -1)
    print("  test_exit_status_keeps_the_code_and_the_signal: PASS")


# =============================================================================
# ARM 4: the health probe.
# =============================================================================
struct RecordingTransport(AwsHttpTransport):
    """Records each request; answers `status`, or raises when `fail`."""

    var status: Int
    var fail: Bool
    var requests: List[CredentialHttpRequest]

    def __init__(out self, status: Int, fail: Bool = False):
        self.status = status
        self.fail = fail
        self.requests = List[CredentialHttpRequest]()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.requests.append(req.copy())
        if self.fail:
            raise Error("HttpError[connect]: refused (injected)")
        return HttpResult(self.status, List[UInt8]())


def _host_header(req: CredentialHttpRequest) -> String:
    for i in range(len(req.headers)):
        if req.headers[i].name.lower() == "host":
            return req.headers[i].value
    return String("")


def test_health_probe() raises:
    var req = minio_health_request(String("127.0.0.1"), 9000)
    assert_equal(req.method, String("GET"))
    assert_equal(req.scheme, String("http"))
    assert_equal(req.host, String("127.0.0.1"))
    assert_equal(req.port, 9000)
    assert_equal(req.target, MINIO_HEALTH_PATH)
    assert_equal(_host_header(req), String("127.0.0.1:9000"))

    var ok = RecordingTransport(200)
    assert_true(minio_health_live(ok, String("127.0.0.1"), 9000), "200 is live")
    assert_equal(len(ok.requests), 1)
    assert_equal(ok.requests[0].target, MINIO_HEALTH_PATH)
    assert_equal(_host_header(ok.requests[0]), String("127.0.0.1:9000"))

    # CONTROL: a non-200 answer and a transport failure are not ready.
    var starting = RecordingTransport(503)
    assert_false(minio_health_live(starting, String("127.0.0.1"), 9000), "503 is not live")
    var down = RecordingTransport(200, fail=True)
    assert_false(minio_health_live(down, String("127.0.0.1"), 9000), "no answer is not live")
    assert_equal(len(down.requests), 1)
    print("  test_health_probe: PASS")


# =============================================================================
# ARM 5: refusals that need no child.
# =============================================================================
def test_unknown_handles_and_empty_argv_are_refused() raises:
    var runner = SpawnedProcessRunner()
    var raised = False
    try:
        _ = runner.stop(1, 0)
    except e:
        raised = _raises_with(String("no child with handle 1"), e)
    assert_true(raised, "stop of an unknown handle must raise")
    var r = runner.wait_port(0, String("127.0.0.1"), 9000, 0)
    assert_equal(r.kind, READINESS_EXITED)
    assert_equal(r.exit_code, -1)

    # An empty argv is refused before anything is spawned.
    raised = False
    try:
        _ = runner.start(ProcessSpec(List[String](), List[EnvEntry](), String(""), False))
    except e:
        raised = _raises_with(String("empty argv"), e)
    assert_true(raised, "an empty argv must be refused")
    assert_equal(len(runner.children), 0)

    # CONTROL: shell_argv_for refuses the same spec on its own.
    raised = False
    try:
        _ = shell_argv_for(ProcessSpec(List[String](), List[EnvEntry](), String(""), True))
    except:
        raised = True
    assert_true(raised, "shell_argv_for of an empty argv must raise")
    print("  test_unknown_handles_and_empty_argv_are_refused: PASS")


# =============================================================================
# ARM 6: the runner over real /bin/sh children.
# =============================================================================
comptime _NOBODY_PORT = 1
"""Loopback port 1: nothing serves it, so `wait_port`'s probe is refused at
once and only the child's exit can end a wait early."""


def _sh(script: String, var env: List[EnvEntry], var cwd: String = String("")) -> ProcessSpec:
    var argv: List[String] = ["/bin/sh", "-c", script]
    return ProcessSpec(argv^, env^, cwd^, False)


def _path_env() -> List[EnvEntry]:
    return [EnvEntry(String("PATH"), String("/usr/bin:/bin"))]


def _tick(mut r: SpawnedProcessRunner, h: Int) -> Int:
    """One 100 ms wait on a child; its readiness kind."""
    return r.wait_port(h, String("127.0.0.1"), _NOBODY_PORT, 0).kind


def test_real_children() raises:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    var r = SpawnedProcessRunner()

    # An exit code reaches wait_port, and stop returns it after wait_port
    # reaped the child.
    var h1 = r.start(_sh(String("exit 3"), _path_env()))
    var r1 = r.wait_port(h1, String("127.0.0.1"), _NOBODY_PORT, 10)
    assert_equal(r1.kind, READINESS_EXITED)
    assert_equal(r1.exit_code, 3)
    assert_equal(r.stop(h1, 1), 3)

    # The child's environment is exactly the spec's: the empty one is the
    # marker alone, and a given one has no TEST_TMPDIR of ours.
    var empty_env = String(
        'test -z "$TEST_TMPDIR" || exit 9; test "$KOMIRA_EMPTY_ENV" = 1 || exit 8; exit 0'
    )
    var h2 = r.start(_sh(empty_env, List[EnvEntry]()))
    var r2 = r.wait_port(h2, String("127.0.0.1"), _NOBODY_PORT, 10)
    assert_equal(r2.kind, READINESS_EXITED)
    assert_equal(r2.exit_code, 0, "the empty environment leaked (9) or lost the marker (8)")
    var given = List[EnvEntry]()
    given.append(EnvEntry(String("KT_GIVEN"), String("v1")))
    var h3 = r.start(
        _sh(
            String('test -z "$TEST_TMPDIR" || exit 9; test "$KT_GIVEN" = v1 || exit 7; exit 0'),
            given^,
        )
    )
    var r3 = r.wait_port(h3, String("127.0.0.1"), _NOBODY_PORT, 10)
    assert_equal(r3.exit_code, 0, "the environment leaked (9) or lost an entry (7)")

    # The cwd is applied: a relative write lands in it.
    var marker = tmp + "/runner-cwd-marker"
    var h4 = r.start(_sh(String(": > runner-cwd-marker"), List[EnvEntry](), tmp))
    assert_equal(r.wait_port(h4, String("127.0.0.1"), _NOBODY_PORT, 10).exit_code, 0)
    assert_true(exists(marker), "the child did not run in the spec's cwd")

    # stop sends SIGTERM to a live child (143); with setpriv when present.
    var die = exists(SETPRIV)
    var argv: List[String] = ["/bin/sh", "-c", "exec sleep 30"]
    var h5 = r.start(ProcessSpec(argv^, _path_env(), String(""), die))
    assert_equal(_tick(r, h5), READINESS_TIMEOUT)
    assert_equal(r.stop(h5, 5), 143)
    print("    (die_with_parent through setpriv: " + String(die) + ")")

    # A child that ignores SIGTERM is SIGKILLed after the grace (137). The
    # trap is in place before the stop: the child writes a marker after it.
    var ready = tmp + "/runner-trap-marker"
    var h6 = r.start(
        _sh(String("trap '' TERM; : > '") + ready + "'; exec sleep 30", _path_env())
    )
    var ticks = 0
    while not exists(ready) and ticks < 100:
        assert_equal(_tick(r, h6), READINESS_TIMEOUT, "the trapping child ended early")
        ticks += 1
    assert_true(exists(ready), "the trapping child never wrote its marker")
    assert_equal(r.stop(h6, 1), 137)

    # CONTROL: every child is gone; a second stop of each returns the same
    # status without signalling anything.
    assert_equal(r.stop(h5, 0), 143)
    assert_equal(r.stop(h6, 0), 137)
    print("  test_real_children: PASS")


def main() raises:
    print("test_spawned_process_runner:")
    test_argv_runs_through_setpriv_in_the_cwd()
    test_env_is_exactly_the_spec()
    test_exit_status_keeps_the_code_and_the_signal()
    test_health_probe()
    test_unknown_handles_and_empty_argv_are_refused()
    test_real_children()
    print("test_spawned_process_runner: ALL PASS")
