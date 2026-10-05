# =============================================================================
# komira_test_minio/server.mojo -- `EmbeddedMinio`: a private MinIO server
# started inside the test, bound to 127.0.0.1, with its data and a throwaway
# root credential in the test's own temporary directory.
# =============================================================================
#
# `start_embedded_minio` does, in order:
#   1. Hash the given MinIO binary and compare it with this platform's pin
#      (minio_pins.mojo). A mismatch RAISES: a FAIL, never a SKIP.
#   2. Make `<tmp_root>/kti-<run_id>/` (0700) holding `root_user` and
#      `root_password` (0600, random) and empty `data/` and `certs/`.
#   3. Start the server with
#        server <tmp>/data --address 127.0.0.1:<p> --console-address 127.0.0.1:<q>
#               --certs-dir <tmp>/certs
#      and a child environment of exactly MINIO_ROOT_USER_FILE,
#      MINIO_ROOT_PASSWORD_FILE (both PATHS), MINIO_BROWSER=off and HOME. The
#      credential is never in an environment block or argv. Both addresses
#      are loopback: MinIO's defaults listen on every interface, which on a
#      developer machine is the LAN. HOME is `<tmp>` and `--certs-dir` is
#      `<tmp>/certs`, so the server stays out of the developer's home
#      directory. HOME is required: a server with none, that cannot look up
#      its user either, exits 1 at start ("Unable to get mcConfigDir"). Ports are drawn
#      from the entropy source in [20000, 60000); an early exit (a port
#      already taken, typically) is retried with fresh ports up to 3 times.
#      The child is started with `die_with_parent`, so a killed test does not
#      leave a server running.
#   4. Once the port answers, write `<tmp>/credentials` (0600) in the AWS
#      shared-credentials shape and hand back the running server: its
#      endpoint (http://127.0.0.1:<p>), its region and the PATH of that
#      credentials file. This package creates no bucket and knows no object
#      store client; komira_test_bucket does that on top of it.
#
# `stop()` stops the server (5 s grace), then removes the temporary
# directory, and returns a `Verdict`: a stop it cannot confirm is
# CANNOT_TELL, a directory that stays is LEAK. It is idempotent. A server
# dropped without `stop()` is a bug in the caller: its destructor stops it
# and then ends the process with `abort()` and the message
# `komira_test_minio: UNSTOPPED SERVER (LEAK-RISK) <verdict>` (SIGILL, exit
# 132 on Mojo 1.0; not a SIGKILL a retrying runner could turn into a pass).
#
# The credentials file has no session token: the root keys of a server that
# lives as long as the test need none. The file is written once and its
# contents are never part of a message.
#
# The fixed names below (host, region) describe a private server this package
# starts and destroys; they name nothing that outlives a test.
# =============================================================================

from std.os import abort

from komira_test_run_id import Entropy, RunId, hex16_lower
from komira_test_verdict import Verdict
from komira_validation_run.validation_run_tag import is_valid_validation_run_id

from ._private_files import (
    _make_private_dir,
    _remove_tree,
    _sha256_file_hex,
    _write_private_file,
)
from .minio_pins import (
    MinioPin,
    current_minio_platform,
    minio_server_pins,
    pinned_sha256_for,
)
from .process import (
    READINESS_EXITED,
    READINESS_READY,
    EnvEntry,
    ProcessRunner,
    ProcessSpec,
)

comptime MINIO_HOST: String = "127.0.0.1"
comptime MINIO_REGION: String = "us-east-1"
comptime MINIO_PORT_LOW: Int = 20000
comptime MINIO_PORT_HIGH: Int = 60000
comptime MINIO_START_RETRIES: Int = 3
comptime MINIO_READY_TIMEOUT_S: Int = 30
comptime MINIO_STOP_GRACE_S: Int = 5

comptime UNSTOPPED_SERVER_MARKER: String = "komira_test_minio: UNSTOPPED SERVER (LEAK-RISK)"


def credentials_file_text(
    access_key_id: String, secret_access_key: String, session_token: String
) -> String:
    """An AWS shared-credentials file with one profile, `[default]`. The
    `aws_session_token` line is written only when a token is given."""
    var out = String("[default]\n")
    out += "aws_access_key_id = " + access_key_id + "\n"
    out += "aws_secret_access_key = " + secret_access_key + "\n"
    if session_token.byte_length() > 0:
        out += "aws_session_token = " + session_token + "\n"
    return out^


def _draw_port[E: Entropy](mut entropy: E) raises -> Int:
    var span = UInt64(MINIO_PORT_HIGH - MINIO_PORT_LOW)
    return MINIO_PORT_LOW + Int(entropy.next_u64() % span)


def _minio_spec(minio_path: String, tmp: String, port: Int, console_port: Int) -> ProcessSpec:
    var argv = List[String]()
    argv.append(minio_path)
    argv.append("server")
    argv.append(tmp + "/data")
    argv.append("--address")
    argv.append(String(MINIO_HOST) + ":" + String(port))
    argv.append("--console-address")
    argv.append(String(MINIO_HOST) + ":" + String(console_port))
    argv.append("--certs-dir")
    argv.append(tmp + "/certs")
    var env = List[EnvEntry]()
    env.append(EnvEntry("MINIO_ROOT_USER_FILE", tmp + "/root_user"))
    env.append(EnvEntry("MINIO_ROOT_PASSWORD_FILE", tmp + "/root_password"))
    env.append(EnvEntry("MINIO_BROWSER", "off"))
    env.append(EnvEntry("HOME", tmp))
    return ProcessSpec(argv^, env^, tmp, True)


def _verify_pinned_minio(minio_path: String, pins: List[MinioPin]) raises:
    var platform = current_minio_platform()
    var want = pinned_sha256_for(pins, platform)
    if want.byte_length() == 0:
        raise Error("komira_test_minio: no pinned binary for platform " + platform)
    # Outside the start's `try`, so nothing scrubs this message after it:
    # it must carry no path (the path is a caller's value).
    var got: String
    try:
        got = _sha256_file_hex(minio_path, "the MinIO binary")
    except e:
        raise Error("komira_test_minio: " + String(e))
    if got != want:
        raise Error(
            "komira_test_minio: the binary's sha256 "
            + got
            + " is not the pin for "
            + platform
            + " ("
            + want
            + ")"
        )


struct _ServerState[P: ProcessRunner](Movable):
    """Everything a running server owns. Kept apart from `EmbeddedMinio` so
    the destructor can run the same `stop` a caller does."""

    var runner: Self.P
    var handle: Int
    var tmpdir: String
    var port: Int
    var stopped: Bool
    var verdict: Verdict

    def __init__(out self, var runner: Self.P, handle: Int, var tmpdir: String, port: Int):
        self.runner = runner^
        self.handle = handle
        self.tmpdir = tmpdir^
        self.port = port
        self.stopped = False
        self.verdict = Verdict()

    def stop(mut self) -> Verdict:
        if self.stopped:
            return self.verdict.copy()
        var v = Verdict()
        try:
            _ = self.runner.stop(self.handle, MINIO_STOP_GRACE_S)
        except e:
            v.add_cannot_tell("embedded MinIO stop not confirmed: " + String(e))
        if not _remove_tree(self.tmpdir):
            v.add_leak(String("embedded MinIO temporary directory remained"))
        self.stopped = True
        self.verdict = v.copy()
        return v^


struct EmbeddedMinio[P: ProcessRunner](Movable):
    """A running embedded MinIO. See the module header: call `stop()` and
    check its verdict."""

    var _state: _ServerState[Self.P]

    def __init__(out self, var state: _ServerState[Self.P]):
        self._state = state^

    def __deinit__(deinit self):
        if not self._state.stopped:
            abort(String(UNSTOPPED_SERVER_MARKER) + " " + String(self._state.stop()))

    def _stop_unstopped(mut self) -> String:
        """What the destructor of an unstopped server does, minus the abort:
        stop and build the abort message. For the package's own test."""
        return String(UNSTOPPED_SERVER_MARKER) + " " + String(self._state.stop())

    def stop(mut self) -> Verdict:
        """Stop the server (5 s grace), then remove its temporary directory.
        Idempotent: a second call returns the same verdict and does nothing."""
        return self._state.stop()

    def is_stopped(self) -> Bool:
        return self._state.stopped

    def endpoint(self) -> String:
        """`http://127.0.0.1:<port>`."""
        return "http://" + String(MINIO_HOST) + ":" + String(self._state.port)

    def region(self) -> String:
        return String(MINIO_REGION)

    def credentials_file(self) -> String:
        """The PATH of the AWS shared-credentials file holding the server's
        root keys (0600, inside the private temporary directory)."""
        return self._state.tmpdir + "/credentials"

    def tmpdir(self) -> String:
        return self._state.tmpdir

    def runner(ref self) -> ref [self._state.runner] Self.P:
        return self._state.runner


def start_embedded_minio_with_pins[P: ProcessRunner, E: Entropy](
    run_id: RunId,
    minio_path: String,
    tmp_root: String,
    var runner: P,
    mut entropy: E,
    pins: List[MinioPin],
) raises -> EmbeddedMinio[P]:
    """`start_embedded_minio` over an explicit pin list, for a test that pins
    a fixture file. `start_embedded_minio` itself always uses
    `minio_server_pins()`."""
    # The run id becomes a directory name below: refuse a bad one (and a bad
    # temporary root) before ANY filesystem call or process start. `RunId` is
    # publicly constructible, so `RunId("x/../../elsewhere", t)` would
    # otherwise place the root credential outside `tmp_root`, start a server
    # on it, and hand that path to the teardown's tree removal.
    if run_id.value.byte_length() == 0 or not is_valid_validation_run_id(run_id.value):
        raise Error("komira_test_minio: refused an empty or invalid run id")
    if tmp_root.byte_length() == 0:
        raise Error("komira_test_minio: refused an empty temporary root")
    if not tmp_root.startswith("/"):
        raise Error("komira_test_minio: the temporary root must be an absolute path")
    _verify_pinned_minio(minio_path, pins)
    var user = "kti" + hex16_lower(entropy.next_u64())
    var password = hex16_lower(entropy.next_u64()) + hex16_lower(entropy.next_u64())
    var tmp = tmp_root + "/kti-" + run_id.value
    # Outside the `try` below: a directory this call did not make is never
    # removed by its cleanup.
    try:
        _make_private_dir(tmp, "temporary directory for this run")
    except e:
        raise Error("komira_test_minio: " + String(e))
    var h = -1
    var port = 0
    try:
        _write_private_file(tmp + "/root_user", user, "root user file")
        _write_private_file(tmp + "/root_password", password, "root password file")
        _make_private_dir(tmp + "/data", "data directory")
        _make_private_dir(tmp + "/certs", "certs directory")
        var last_exit = 0
        for _attempt in range(1 + MINIO_START_RETRIES):
            port = _draw_port(entropy)
            var console_port = _draw_port(entropy)
            if console_port == port:
                console_port = port + 1 if port + 1 < MINIO_PORT_HIGH else MINIO_PORT_LOW
            var started = runner.start(_minio_spec(minio_path, tmp, port, console_port))
            var r = runner.wait_port(started, String(MINIO_HOST), port, MINIO_READY_TIMEOUT_S)
            if r.kind == READINESS_READY:
                h = started
                break
            if r.kind == READINESS_EXITED:
                last_exit = r.exit_code
                continue
            # TIMEOUT: the child may still be running; stop it before giving up.
            try:
                _ = runner.stop(started, MINIO_STOP_GRACE_S)
            except:
                raise Error(
                    "CANNOT_TELL: embedded MinIO did not answer on its port, and its stop was"
                    " not confirmed"
                )
            raise Error("CANNOT_TELL: embedded MinIO did not answer on its port in time")
        if h < 0:
            raise Error(
                "CANNOT_TELL: embedded MinIO exited early on "
                + String(1 + MINIO_START_RETRIES)
                + " attempts (last exit code "
                + String(last_exit)
                + ")"
            )
        _write_private_file(
            tmp + "/credentials", credentials_file_text(user, password, ""), "credentials file"
        )
    except e:
        var msg = String(e)
        if h >= 0:
            try:
                _ = runner.stop(h, MINIO_STOP_GRACE_S)
            except:
                msg += "; the server's stop was not confirmed"
        if not _remove_tree(tmp):
            msg += "; the temporary directory remained"
        raise Error("komira_test_minio: " + msg)
    return EmbeddedMinio[P](_ServerState[P](runner^, h, tmp, port))


def start_embedded_minio[P: ProcessRunner, E: Entropy](
    run_id: RunId,
    minio_path: String,
    tmp_root: String,
    var runner: P,
    mut entropy: E,
) raises -> EmbeddedMinio[P]:
    """Start a pinned MinIO on loopback inside the test. See the module
    header for the steps; `stop()` it when done."""
    return start_embedded_minio_with_pins(
        run_id, minio_path, tmp_root, runner^, entropy, minio_server_pins()
    )
