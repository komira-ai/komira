# The embedded MinIO over a scripted process runner: both addresses bind
# 127.0.0.1; the child environment is exactly the two *_FILE paths,
# MINIO_BROWSER=off and HOME; the credential files have the right shape and modes; a
# binary that is not the pin raises; an early exit is retried on fresh ports;
# `stop()` stops with a 5 s grace and removes the directory, and a stop that
# cannot be confirmed is CANNOT_TELL; an unstopped server stops before its
# abort; and a bad run id or temporary root is refused before anything
# touches the disk.
#
# The "MinIO binary" here is a small fixture file whose digest the test pins
# (through `start_embedded_minio_with_pins`). Nothing is executed.

from std.os import listdir, mkdir, stat
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_test_minio import (
    MINIO_REGION,
    UNSTOPPED_SERVER_MARKER,
    MinioPin,
    binary_sha256,
    Readiness,
    ScriptedProcessRunner,
    current_minio_platform,
    start_embedded_minio,
    start_embedded_minio_with_pins,
)
from komira_test_run_id import RunId, ScriptedEntropy
from komira_test_verdict import VERDICT_CANNOT_TELL, VERDICT_CLEAN


def _tmp() raises -> String:
    var t = _read_env("TEST_TMPDIR")
    if t.byte_length() == 0:
        raise Error("TEST_TMPDIR is unset; run under the test runner")
    return t


def _fixture_binary(tmp: String) raises -> String:
    var path = tmp + "/fake-minio"
    if not exists(path):
        with open(path, "w") as f:
            f.write("not a server; only its digest matters here\n")
    return path


def _pins(binary: String) raises -> List[MinioPin]:
    var pins = List[MinioPin]()
    pins.append(MinioPin(current_minio_platform(), binary_sha256(binary)))
    return pins^


def _mode(path: String) raises -> Int:
    return Int(stat(path).st_mode) & 0o777


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _entropy() -> ScriptedEntropy:
    # user, password (2), then (port, console port) per start attempt.
    return ScriptedEntropy(
        [
            UInt64(0x11),
            UInt64(0x22),
            UInt64(0x33),
            UInt64(100),
            UInt64(200),
            UInt64(300),
            UInt64(400),
        ]
    )


def test_start_retry_files_env_and_stop() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c1")
    var runner = ScriptedProcessRunner([Readiness.exited(1), Readiness.ready()])
    var entropy = _entropy()
    var s = start_embedded_minio_with_pins(
        RunId(id, 1790000000), binary, tmp, runner^, entropy, _pins(binary)
    )
    var dir = tmp + "/kti-" + id

    # Bind retry: two starts, the second on fresh ports.
    ref r = s.runner()
    assert_equal(len(r.specs), 2)
    assert_equal(r.waits[0], 20100)
    assert_equal(r.waits[1], 20300)

    # argv: loopback only, both addresses.
    var argv = r.specs[1].argv.copy()
    var want: List[String] = [
        binary,
        "server",
        dir + "/data",
        "--address",
        "127.0.0.1:20300",
        "--console-address",
        "127.0.0.1:20400",
        "--certs-dir",
        dir + "/certs",
    ]
    assert_equal(len(argv), len(want))
    for i in range(len(want)):
        assert_equal(argv[i], want[i])
    assert_true(r.specs[1].die_with_parent)
    assert_equal(r.specs[1].cwd, dir)

    # Environment: exactly the two *_FILE paths, MINIO_BROWSER=off and HOME,
    # the run's own directory. A real server exits 1 at start without a HOME
    # ("Unable to get mcConfigDir") when it cannot look the user up either.
    ref env = r.specs[1].child_env
    assert_equal(len(env), 4)
    assert_equal(env[0].name, "MINIO_ROOT_USER_FILE")
    assert_equal(env[0].value, dir + "/root_user")
    assert_equal(env[1].name, "MINIO_ROOT_PASSWORD_FILE")
    assert_equal(env[1].value, dir + "/root_password")
    assert_equal(env[2].name, "MINIO_BROWSER")
    assert_equal(env[2].value, "off")
    assert_equal(env[3].name, "HOME")
    assert_equal(env[3].value, dir)

    # Files: shapes and modes. The credential is in files only.
    assert_equal(_mode(dir), 0o700)
    var user = _read(dir + "/root_user")
    var password = _read(dir + "/root_password")
    assert_equal(user, "kti0000000000000011")
    assert_equal(password, "00000000000000220000000000000033")
    for name in ["root_user", "root_password", "credentials"]:
        assert_equal(_mode(dir + "/" + name), 0o600, name)
    assert_equal(
        _read(dir + "/credentials"),
        "[default]\naws_access_key_id = "
        + user
        + "\naws_secret_access_key = "
        + password
        + "\n",
    )
    for a in argv:
        assert_false(user in a or password in a, "credential in argv")
    for e in env:
        assert_false(user in e.value or password in e.value, "credential in env")

    # What the server hands back.
    assert_equal(s.endpoint(), "http://127.0.0.1:20300")
    assert_equal(s.region(), MINIO_REGION)
    assert_equal(s.credentials_file(), dir + "/credentials")
    assert_equal(s.tmpdir(), dir)
    assert_false(s.is_stopped())

    var v = s.stop()
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    assert_true(s.is_stopped())
    assert_equal(len(s.runner().stops), 1)
    assert_equal(s.runner().stops[0], 2)
    assert_equal(s.runner().stop_graces[0], 5)
    assert_false(exists(dir), "the temporary directory remained")
    # Idempotent: the same verdict, and no second stop.
    assert_equal(s.stop().kind, VERDICT_CLEAN)
    assert_equal(len(s.runner().stops), 1)


def test_sha_mismatch_raises_before_anything() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c2")
    var runner = ScriptedProcessRunner([Readiness.ready()])
    var entropy = _entropy()
    var raised = False
    try:
        # The real pins: the fixture is not a pinned MinIO.
        var s = start_embedded_minio(RunId(id, 1790000000), binary, tmp, runner^, entropy)
        _ = s.stop()
    except e:
        raised = True
        assert_true("sha256" in String(e), String(e))
    assert_true(raised, "an unpinned binary was accepted")
    assert_false(exists(tmp + "/kti-" + id), "a directory was made before the pin check")


def test_every_attempt_exiting_is_cannot_tell() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c3")
    var runner = ScriptedProcessRunner(
        [Readiness.exited(1), Readiness.exited(1), Readiness.exited(1), Readiness.exited(2)]
    )
    var entropy = ScriptedEntropy(
        [UInt64(1), UInt64(2), UInt64(3), UInt64(10), UInt64(11), UInt64(12), UInt64(13),
         UInt64(14), UInt64(15), UInt64(16), UInt64(17)]
    )
    var raised = False
    try:
        var s = start_embedded_minio_with_pins(
            RunId(id, 1790000000), binary, tmp, runner^, entropy, _pins(binary)
        )
        _ = s.stop()
    except e:
        raised = True
        var msg = String(e)
        assert_true("CANNOT_TELL" in msg, msg)
        assert_true("4 attempts" in msg, msg)
        assert_true("last exit code 2" in msg, msg)
    assert_true(raised, "started although every start exited")
    assert_false(exists(tmp + "/kti-" + id), "the temporary directory remained")


def test_unconfirmed_stop_is_cannot_tell() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c4")
    var runner = ScriptedProcessRunner([Readiness.ready()])
    runner.stop_raises = True
    var entropy = _entropy()
    var s = start_embedded_minio_with_pins(
        RunId(id, 1790000000), binary, tmp, runner^, entropy, _pins(binary)
    )
    var v = s.stop()
    assert_equal(v.kind, VERDICT_CANNOT_TELL, String(v))
    assert_true("embedded MinIO stop not confirmed" in String(v), String(v))
    # The directory is still removed.
    assert_false(isdir(tmp + "/kti-" + id))


def test_unstopped_server_stops_and_builds_the_message() raises:
    # The abort itself would end this test, so the test drives the same path
    # the destructor runs and checks that the stop ran first.
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c7")
    var runner = ScriptedProcessRunner([Readiness.ready()])
    var entropy = _entropy()
    var s = start_embedded_minio_with_pins(
        RunId(id, 1790000000), binary, tmp, runner^, entropy, _pins(binary)
    )
    var msg = s._stop_unstopped()
    assert_true(msg.startswith(String(UNSTOPPED_SERVER_MARKER) + " CLEAN"), msg)
    assert_true(s.is_stopped())
    assert_equal(len(s.runner().stops), 1)
    assert_false(exists(tmp + "/kti-" + id), "the temporary directory remained")


def _start_refused(
    id: String, tmp_root: String, binary: String
) raises -> String:
    """Start with a valid pin; return the error. The runner's script is
    empty, so a server started anyway would time out with its own, different
    error: the refusal has to come before the start."""
    var runner = ScriptedProcessRunner(List[Readiness]())
    var entropy = _entropy()
    try:
        var s = start_embedded_minio_with_pins(
            RunId(id, 1790000000), binary, tmp_root, runner^, entropy, _pins(binary)
        )
        _ = s.stop()
    except e:
        return String(e)
    return String("")


comptime _REFUSED: String = "komira_test_minio: refused"


def test_bad_run_id_or_root_refused_before_the_disk() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    # `<root>/inner/kti-x` exists, so `<root>/inner/kti-x/../../escaped` would
    # resolve to `<root>/escaped`: outside the temporary root.
    var root = tmp + "/escape-check"
    mkdir(root)
    mkdir(root + "/inner")
    mkdir(root + "/inner/kti-x")
    var inner = root + "/inner"

    var msg = _start_refused("x/../../escaped", inner, binary)
    assert_true(msg.startswith(String(_REFUSED) + " an empty or invalid run id"), msg)
    assert_false(exists(root + "/escaped"), "a directory was made outside the temporary root")
    assert_equal(len(listdir(root)), 1)
    assert_equal(len(listdir(inner)), 1)
    assert_equal(len(listdir(inner + "/kti-x")), 0)

    msg = _start_refused("", inner, binary)
    assert_true(msg.startswith(String(_REFUSED) + " an empty or invalid run id"), msg)
    assert_false(exists(inner + "/kti-"), "an empty run id made a directory")

    msg = _start_refused("1790000000-00000000000000c5", "relative/root", binary)
    assert_true(msg.startswith("komira_test_minio: the temporary root must be"), msg)
    assert_false(exists("relative"), "a relative temporary root was used")

    msg = _start_refused("1790000000-00000000000000c6", "", binary)
    assert_true(msg.startswith(String(_REFUSED) + " an empty temporary root"), msg)
    assert_equal(len(listdir(inner)), 1)


def test_file_refusals_carry_no_path() raises:
    # Every path here is built from a caller's value (the binary, the
    # temporary root, the run id); a refusal names the file's role only.
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var runner = ScriptedProcessRunner(List[Readiness]())
    var entropy = _entropy()
    var msg = String("")
    try:
        var s = start_embedded_minio_with_pins(
            RunId(String("1790000000-00000000000000c7"), 1790000000),
            tmp + "/sentinel-missing-binary",
            tmp,
            runner^,
            entropy,
            _pins(binary),
        )
        _ = s.stop()
    except e:
        msg = String(e)
    assert_equal(msg, "komira_test_minio: cannot read the MinIO binary")

    # An existing run directory: refused, not reused, and not removed.
    var id = String("1790000000-00000000000000c8")
    mkdir(tmp + "/kti-" + id)
    msg = _start_refused(id, tmp, binary)
    assert_equal(
        msg, "komira_test_minio: refusing to reuse an existing temporary directory for this run"
    )
    assert_false(tmp in msg, msg)
    assert_true(exists(tmp + "/kti-" + id), "a directory this call did not make was removed")


def main() raises:
    test_start_retry_files_env_and_stop()
    test_sha_mismatch_raises_before_anything()
    test_every_attempt_exiting_is_cannot_tell()
    test_unconfirmed_stop_is_cannot_tell()
    test_unstopped_server_stops_and_builds_the_message()
    test_bad_run_id_or_root_refused_before_the_disk()
    test_file_refusals_carry_no_path()
    print("test_embedded_minio: OK")
