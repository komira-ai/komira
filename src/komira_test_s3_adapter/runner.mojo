# =============================================================================
# komira_test_s3_adapter/runner.mojo -- `SpawnedProcessRunner`, a
# komira_test_minio `ProcessRunner` that really starts the embedded MinIO,
# and the pure pieces it is built from.
# =============================================================================
#
# `start` runs komira_supervisor's `spawn_detached` on
#
#     /bin/sh -c 'cd "$0" && exec /usr/bin/setpriv --pdeathsig KILL -- "$@"' DIR ARGV...
#
# (`shell_argv_for`): the shell applies the working directory and setpriv
# sets PR_SET_PDEATHSIG before it execs the server, so the server keeps the
# spawned pid and dies with the test. That is Linux only; on any other
# platform, or when setpriv is missing, `start` raises (a FAIL, never a
# skip). The child's environment is exactly `spec.child_env`
# (`child_env_for`; never ours).
#
# `wait_port` polls the child's exit and MinIO's health endpoint
# (`minio_health_live`: `GET /minio/health/live` answering 200); a child
# that ended first is EXITED with `readiness_exit_code` (its exit status, or
# -1 when waitpid failed). `stop` is SIGTERM, up to `grace_s`, then SIGKILL,
# and returns the child's exit status (`exit_status_of`: the exit code, or
# 128 + the signal); it raises unless the child was reaped. A child reaped
# by `wait_port` keeps its status, so a later `stop` returns it.
#
# A handle is 1 + the index of its child in `children`; any other handle is
# refused (`stop` raises, `wait_port` reports EXITED with -1).
# =============================================================================

from std.os.path import exists
from std.sys.info import CompilationTarget

from komira_aws_core import AwsConnectorTransport, AwsHttpTransport, Header
from komira_aws_core.credential_transport import CredentialHttpRequest
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_supervisor.supervisor import DetachedChild, DetachedExit, spawn_detached
from komira_test_minio import ProcessRunner, ProcessSpec, Readiness

from ._sys import _sleep_ms


comptime SETPRIV: String = "/usr/bin/setpriv"
"""The setpriv a `die_with_parent` start runs through."""

comptime MINIO_HEALTH_PATH: String = "/minio/health/live"
"""MinIO's liveness endpoint: 200 once the server serves requests."""

comptime EMPTY_ENV_MARKER: String = "KOMIRA_EMPTY_ENV=1"
"""The one entry of an otherwise empty child environment: an empty list
would make `spawn_detached` inherit the test's environment."""

comptime _P: String = "spawned process runner: "


def shell_argv_for(spec: ProcessSpec) raises -> List[String]:
    """The `/bin/sh` arguments that start `spec` (module header). Raises on
    an empty argv."""
    if len(spec.argv) == 0:
        raise Error(_P + "an empty argv")
    var argv = List[String]()
    argv.append("-c")
    var script = String('exec "$@"')
    if spec.die_with_parent:
        script = String("exec ") + SETPRIV + ' --pdeathsig KILL -- "$@"'
    if spec.cwd.byte_length() > 0:
        script = String('cd "$0" && ') + script
        argv.append(script)
        argv.append(spec.cwd)
    else:
        argv.append(script)
        argv.append("sh")
    for i in range(len(spec.argv)):
        argv.append(spec.argv[i])
    return argv^


def child_env_for(spec: ProcessSpec) -> List[String]:
    """The child's WHOLE environment as `NAME=value` entries; never empty
    (`EMPTY_ENV_MARKER` stands in for none)."""
    var env = List[String]()
    for i in range(len(spec.child_env)):
        env.append(spec.child_env[i].name + "=" + spec.child_env[i].value)
    if len(env) == 0:
        env.append(EMPTY_ENV_MARKER)
    return env^


def exit_status_of(st: DetachedExit) raises -> Int:
    """A reaped child's exit status: its exit code, or 128 + the signal that
    killed it. Raises when waitpid failed (the end is not confirmed) or the
    child is still running."""
    if st.error:
        raise Error(_P + "waitpid failed; the child's end is not confirmed")
    if st.running:
        raise Error(_P + "the child is still running")
    if st.exited:
        return Int(st.exit_code)
    return 128 + Int(st.signal)


def readiness_exit_code(st: DetachedExit) -> Int:
    """What `wait_port` reports for a child that ended before it was ready:
    `exit_status_of`, or -1 when the end is not confirmed."""
    try:
        return exit_status_of(st)
    except:
        return -1


def minio_health_request(host: String, port: Int) -> CredentialHttpRequest:
    """The unsigned `GET /minio/health/live` to `host:port`, with its Host
    header."""
    var req = CredentialHttpRequest(
        String("GET"), String("http"), host, port, MINIO_HEALTH_PATH
    )
    req.headers.append(Header(String("Host"), host + ":" + String(port)))
    return req^


def minio_health_live[X: AwsHttpTransport](mut transport: X, host: String, port: Int) -> Bool:
    """True when the health endpoint answers 200 over `transport`; any other
    status, or no answer, is False."""
    try:
        var res = transport.send(minio_health_request(host, port))
        return res.status == 200
    except:
        return False


struct SpawnedProcessRunner(ProcessRunner):
    """Starts real children (module header)."""

    var children: List[DetachedChild]
    var _ended: List[Optional[DetachedExit]]
    """`_ended[i]`: the status `children[i]` was reaped with, once it was."""

    def __init__(out self):
        self.children = List[DetachedChild]()
        self._ended = List[Optional[DetachedExit]]()

    def _child(self, h: Int) raises -> DetachedChild:
        if h < 1 or h > len(self.children):
            raise Error(_P + "no child with handle " + String(h))
        return self.children[h - 1]

    def _poll(mut self, h: Int) -> DetachedExit:
        """The child's status; a reap is remembered (waitpid would answer a
        second poll with ECHILD). `h` is valid."""
        if self._ended[h - 1]:
            return self._ended[h - 1].value()
        var st = self.children[h - 1].poll_exit()
        if not st.running and not st.error:
            self._ended[h - 1] = Optional[DetachedExit](st)
        return st

    def start(mut self, spec: ProcessSpec) raises -> Int:
        comptime if not CompilationTarget.is_linux():
            raise Error(
                _P + "die_with_parent needs PR_SET_PDEATHSIG; this runner is Linux only"
            )
        var argv = shell_argv_for(spec)
        if spec.die_with_parent and not exists(SETPRIV):
            raise Error(_P + "die_with_parent needs " + SETPRIV + ", which is missing")
        var pid = spawn_detached(String("/bin/sh"), argv, child_env_for(spec))
        if pid <= Int32(0):
            raise Error(_P + "spawn failed (errno " + String(-Int(pid)) + ")")
        self.children.append(DetachedChild(pid))
        self._ended.append(Optional[DetachedExit]())
        return len(self.children)

    def wait_port(mut self, h: Int, host: String, port: Int, timeout_s: Int) -> Readiness:
        try:
            _ = self._child(h)
        except:
            return Readiness.exited(-1)
        var waited_ms = 0
        while waited_ms <= timeout_s * 1000:
            var st = self._poll(h)
            if not st.running:
                return Readiness.exited(readiness_exit_code(st))
            if _answers_health(host, port):
                return Readiness.ready()
            _sleep_ms(100)
            waited_ms += 100
        return Readiness.timeout()

    def stop(mut self, h: Int, grace_s: Int) raises -> Int:
        var child = self._child(h)
        var st = self._poll(h)
        if not st.running:
            return exit_status_of(st)
        _ = child.term()
        var waited_ms = 0
        while waited_ms < grace_s * 1000:
            _sleep_ms(50)
            waited_ms += 50
            st = self._poll(h)
            if not st.running:
                return exit_status_of(st)
        _ = child.kill()
        for _i in range(100):
            _sleep_ms(50)
            st = self._poll(h)
            if not st.running:
                return exit_status_of(st)
        raise Error(_P + "the child survived SIGKILL for 5 s; it is not confirmed gone")


def _answers_health(host: String, port: Int) -> Bool:
    """`minio_health_live` over a fresh plaintext TCP connection."""
    try:
        var t = AwsConnectorTransport[KernelTcpConnector](KernelTcpConnector.new())
        return minio_health_live(t, host, port)
    except:
        return False
