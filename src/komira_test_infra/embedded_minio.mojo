# =============================================================================
# komira_test_infra/embedded_minio.mojo -- the embedded-MinIO backend: a
# private MinIO server started inside the test, bound to 127.0.0.1, with data
# and a throwaway root credential in the test's own temporary directory.
# =============================================================================
#
# Steps, in order:
#   1. Hash the given MinIO binary and compare it with this platform's pin
#      (minio_pins.mojo). A mismatch RAISES: a FAIL, never a SKIP.
#   2. Make `<tmp_root>/kti-<run_id>/` (0700) holding `root_user` and
#      `root_password` (0600, random) and empty `data/` and `certs/`.
#   3. Start the server with
#        server <tmp>/data --address 127.0.0.1:<p> --console-address 127.0.0.1:<q>
#               --certs-dir <tmp>/certs
#      and a child environment of exactly MINIO_ROOT_USER_FILE,
#      MINIO_ROOT_PASSWORD_FILE (both PATHS) and MINIO_BROWSER=off. The
#      credential is never in an environment block or argv. Both addresses
#      are loopback: MinIO's defaults listen on every interface, which on a
#      developer machine is the LAN. `--certs-dir` keeps the server out of
#      the developer's home directory (the child has no HOME). Ports are drawn
#      from the entropy source in [20000, 60000); an early exit (a port
#      already taken, typically) is retried with fresh ports up to 3 times.
#      The child is started with `die_with_parent`, so a killed test does not
#      leave a server running.
#   4. Once the port answers, write `<tmp>/credentials` (0600) in the AWS
#      shared-credentials shape, bind the client to http://127.0.0.1:<p>,
#      region us-east-1, bucket komira-test-embedded, create the bucket, and
#      continue as `open_test_bucket` does (the lease first).
#
# `close()` also stops the server (5 s grace) and removes the temporary
# directory; a stop it cannot confirm is CANNOT_TELL, a directory that stays
# is LEAK.
#
# This credentials file has no session token: the root keys of a server
# that lives as long as the test need none. The file is written once and its
# contents are never part of a message.
#
# The fixed names below (region, bucket, `runs/` prefix) describe a private
# server this library starts and destroys; they name nothing that outlives a
# test.
# =============================================================================

from komira_validation_run.validation_run_tag import is_valid_validation_run_id

from .bucket import BACKEND_EMBEDDED_MINIO, TestBucket, _open_bucket
from .minio_pins import (
    MinioPin,
    current_minio_platform,
    minio_server_pins,
    pinned_sha256_for,
)
from .private_files import (
    _make_private_dir,
    _remove_tree,
    _sha256_file_hex,
    _write_private_file,
)
from .process import (
    READINESS_EXITED,
    READINESS_READY,
    EnvEntry,
    ProcessRunner,
    ProcessSpec,
)
from .run_id import RunId, _hex16
from .seams import Entropy, WallClock
from .store import ObjectStoreClient, StoreTarget

comptime MINIO_HOST: String = "127.0.0.1"
comptime MINIO_REGION: String = "us-east-1"
comptime MINIO_BUCKET: String = "komira-test-embedded"
comptime MINIO_RUN_PREFIX: String = "runs/"
comptime MINIO_PORT_LOW: Int = 20000
comptime MINIO_PORT_HIGH: Int = 60000
comptime MINIO_START_RETRIES: Int = 3
comptime MINIO_READY_TIMEOUT_S: Int = 30
comptime MINIO_STOP_GRACE_S: Int = 5
comptime MINIO_MAX_LEASE_SECONDS: Int = 5400
comptime MINIO_TEARDOWN_BUDGET_SECONDS: Int = 120


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
    return ProcessSpec(argv^, env^, tmp, True)


def _verify_pinned_minio(minio_path: String, pins: List[MinioPin]) raises:
    var platform = current_minio_platform()
    var want = pinned_sha256_for(pins, platform)
    if want.byte_length() == 0:
        raise Error(
            "komira_test_infra: embedded MinIO: no pinned binary for platform " + platform
        )
    var got = _sha256_file_hex(minio_path)
    if got != want:
        raise Error(
            "komira_test_infra: embedded MinIO: the binary's sha256 "
            + got
            + " is not the pin for "
            + platform
            + " ("
            + want
            + ")"
        )


def _open_embedded_minio_with_pins[
    S: ObjectStoreClient, P: ProcessRunner, E: Entropy, C: WallClock
](
    run_id: RunId,
    minio_path: String,
    tmp_root: String,
    target_label: String,
    var client: S,
    var runner: P,
    mut entropy: E,
    mut clock: C,
    pins: List[MinioPin],
) raises -> TestBucket[S, P]:
    """`open_embedded_minio_test_bucket` over an explicit pin list (the library's own
    test pins a fixture binary)."""
    # The run id becomes a directory name below: refuse a bad one (and a bad
    # temporary root) before ANY filesystem call or process start. `RunId` is
    # publicly constructible, so `RunId("x/../../elsewhere", t)` would
    # otherwise place the root credential outside `tmp_root`, start a server
    # on it, and hand that path to the teardown's tree removal.
    if run_id.value.byte_length() == 0 or not is_valid_validation_run_id(run_id.value):
        raise Error("komira_test_infra: embedded MinIO: refused an empty or invalid run id")
    if tmp_root.byte_length() == 0:
        raise Error("komira_test_infra: embedded MinIO: refused an empty temporary root")
    if not tmp_root.startswith("/"):
        raise Error("komira_test_infra: embedded MinIO: the temporary root must be an absolute path")
    _verify_pinned_minio(minio_path, pins)
    var user = "kti" + _hex16(entropy.next_u64())
    var password = _hex16(entropy.next_u64()) + _hex16(entropy.next_u64())
    var tmp = tmp_root + "/kti-" + run_id.value
    _make_private_dir(tmp)
    var h = -1
    var port = 0
    try:
        _write_private_file(tmp + "/root_user", user)
        _write_private_file(tmp + "/root_password", password)
        _make_private_dir(tmp + "/data")
        _make_private_dir(tmp + "/certs")
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
        _write_private_file(tmp + "/credentials", credentials_file_text(user, password, ""))
    except e:
        var msg = String(e)
        if h >= 0:
            try:
                _ = runner.stop(h, MINIO_STOP_GRACE_S)
            except:
                msg += "; the server's stop was not confirmed"
        if not _remove_tree(tmp):
            msg += "; the temporary directory remained"
        raise Error("komira_test_infra: embedded MinIO: " + msg)
    return _open_bucket[S, P, C](
        run_id,
        StoreTarget(
            "http://" + String(MINIO_HOST) + ":" + String(port),
            String(MINIO_REGION),
            String(MINIO_BUCKET),
            tmp + "/credentials",
        ),
        String(MINIO_RUN_PREFIX),
        MINIO_MAX_LEASE_SECONDS,
        MINIO_TEARDOWN_BUDGET_SECONDS,
        target_label,
        String(BACKEND_EMBEDDED_MINIO),
        client^,
        runner^,
        h,
        tmp,
        True,
        clock,
    )


def open_embedded_minio_test_bucket[
    S: ObjectStoreClient, P: ProcessRunner, E: Entropy, C: WallClock
](
    run_id: RunId,
    minio_path: String,
    tmp_root: String,
    target_label: String,
    var client: S,
    var runner: P,
    mut entropy: E,
    mut clock: C,
) raises -> TestBucket[S, P]:
    """Start a pinned MinIO on loopback inside the test and open this run's
    prefix in it. See the module header for the steps."""
    return _open_embedded_minio_with_pins(
        run_id,
        minio_path,
        tmp_root,
        target_label,
        client^,
        runner^,
        entropy,
        clock,
        minio_server_pins(),
    )
