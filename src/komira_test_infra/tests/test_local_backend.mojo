# The local backend over a scripted process runner and the in-memory store:
# both addresses bind 127.0.0.1; the child environment is exactly the two
# *_FILE paths and MINIO_BROWSER=off; the credential files have the right
# shape and modes; a binary that is not the pin raises; an early exit is
# retried on fresh ports; and a stop that cannot be confirmed is CANNOT_TELL.
#
# The "MinIO binary" here is a small fixture file whose digest the test pins
# (through the library's internal pin-list entry point). Nothing is executed.

from std.os import stat
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_false, assert_true

from komira_core_ffi.posix import _read_env
from komira_test_infra import (
    LOCAL_BUCKET,
    LOCAL_REGION,
    FakeObjectStore,
    FixedWallClock,
    MinioPin,
    Readiness,
    RunId,
    ScriptedEntropy,
    ScriptedProcessRunner,
    VERDICT_CANNOT_TELL,
    VERDICT_CLEAN,
    current_minio_platform,
    open_local_test_bucket,
)
from komira_test_infra.local_backend import _open_local_with_pins
from komira_test_infra.private_files import _sha256_file_hex


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
    pins.append(MinioPin(current_minio_platform(), _sha256_file_hex(binary)))
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


def test_open_retry_files_env_and_close() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c1")
    var runner = ScriptedProcessRunner([Readiness.exited(1), Readiness.ready()])
    var entropy = _entropy()
    var clock = FixedWallClock(1790000000)
    var b = _open_local_with_pins(
        RunId(id, 1790000000), binary, tmp, "//p:local", FakeObjectStore(), runner^, entropy, clock, _pins(binary)
    )
    var dir = tmp + "/kti-" + id

    # Bind retry: two starts, the second on fresh ports.
    ref r = b.runner()
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

    # Environment: exactly the two *_FILE paths and MINIO_BROWSER=off.
    ref env = r.specs[1].child_env
    assert_equal(len(env), 3)
    assert_equal(env[0].name, "MINIO_ROOT_USER_FILE")
    assert_equal(env[0].value, dir + "/root_user")
    assert_equal(env[1].name, "MINIO_ROOT_PASSWORD_FILE")
    assert_equal(env[1].value, dir + "/root_password")
    assert_equal(env[2].name, "MINIO_BROWSER")
    assert_equal(env[2].value, "off")

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

    # The handle points at the local server.
    assert_equal(b.endpoint(), "http://127.0.0.1:20300")
    assert_equal(b.region(), LOCAL_REGION)
    assert_equal(b.bucket(), LOCAL_BUCKET)
    assert_equal(b.credentials_file(), dir + "/credentials")
    assert_equal(b.backend(), "local")
    assert_equal(b.prefix(), "runs/" + id + "/")
    ref c = b.client()
    assert_equal(c.calls[0], "bind")
    assert_equal(c.calls[1], "create_bucket_if_absent")
    assert_equal(c.calls[2], "put runs/" + id + "/_lease.textproto")
    assert_true("backend: \"local\"" in c.body_text("runs/" + id + "/_lease.textproto"))

    var v = b.close()
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    assert_equal(len(b.runner().stops), 1)
    assert_equal(b.runner().stops[0], 2)
    assert_equal(b.runner().stop_graces[0], 5)
    assert_false(exists(dir), "the temporary directory remained")


def test_sha_mismatch_raises_before_anything() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c2")
    var runner = ScriptedProcessRunner([Readiness.ready()])
    var entropy = _entropy()
    var clock = FixedWallClock(1790000000)
    var raised = False
    try:
        # The real pins: the fixture is not a pinned MinIO.
        var b = open_local_test_bucket(
            RunId(id, 1790000000), binary, tmp, "//p:local", FakeObjectStore(), runner^, entropy, clock
        )
        _ = b.close()
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
    var clock = FixedWallClock(1790000000)
    var raised = False
    try:
        var b = _open_local_with_pins(
            RunId(id, 1790000000), binary, tmp, "//p:local", FakeObjectStore(), runner^, entropy, clock, _pins(binary)
        )
        _ = b.close()
    except e:
        raised = True
        var msg = String(e)
        assert_true("CANNOT_TELL" in msg, msg)
        assert_true("4 attempts" in msg, msg)
        assert_true("last exit code 2" in msg, msg)
    assert_true(raised, "opened although every start exited")
    assert_false(exists(tmp + "/kti-" + id), "the temporary directory remained")


def test_unconfirmed_stop_is_cannot_tell() raises:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var id = String("1790000000-00000000000000c4")
    var runner = ScriptedProcessRunner([Readiness.ready()])
    runner.stop_raises = True
    var entropy = _entropy()
    var clock = FixedWallClock(1790000000)
    var b = _open_local_with_pins(
        RunId(id, 1790000000), binary, tmp, "//p:local", FakeObjectStore(), runner^, entropy, clock, _pins(binary)
    )
    var v = b.close()
    assert_equal(v.kind, VERDICT_CANNOT_TELL, String(v))
    assert_true("local server stop not confirmed" in String(v), String(v))
    # The directory is still removed.
    assert_false(isdir(tmp + "/kti-" + id))


def main() raises:
    test_open_retry_files_env_and_close()
    test_sha_mismatch_raises_before_anything()
    test_every_attempt_exiting_is_cannot_tell()
    test_unconfirmed_stop_is_cannot_tell()
    print("test_local_backend: OK")
