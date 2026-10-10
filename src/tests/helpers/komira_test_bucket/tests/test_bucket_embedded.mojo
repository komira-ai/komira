# A TestBucket on an embedded MinIO (komira_test_minio, over a scripted
# process runner and a pinned fixture file; nothing is executed): the bucket
# is bound to the server's endpoint, created, and the lease written, in that
# order; `close()` deletes and re-lists while the server is still there and
# only THEN stops it and removes its directory; an unconfirmed stop is
# CANNOT_TELL; and a failed open stops the server before it raises.

from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_test_bucket import (
    BACKEND_EMBEDDED_MINIO,
    EMBEDDED_BUCKET,
    FakeObjectStore,
    ObjectStoreClient,
    StoreTarget,
    open_embedded_minio_bucket,
)
from komira_test_minio import (
    MINIO_REGION,
    EmbeddedMinio,
    MinioPin,
    binary_sha256,
    Readiness,
    ScriptedProcessRunner,
    current_minio_platform,
    start_embedded_minio_with_pins,
)
from komira_test_run_id import FixedWallClock, RunId, ScriptedEntropy
from komira_test_verdict import VERDICT_CANNOT_TELL, VERDICT_CLEAN


struct _DirWatchingStore(ObjectStoreClient):
    """The in-memory store, plus a record of whether `watched` existed at
    each `list_keys` call. The server's directory is removed by its stop, so
    every list having seen it proves the stop came after the last list."""

    var inner: FakeObjectStore
    var watched: String
    var dir_seen_at_list: List[Bool]

    def __init__(out self, var watched: String):
        self.inner = FakeObjectStore()
        self.watched = watched^
        self.dir_seen_at_list = List[Bool]()

    def bind(mut self, target: StoreTarget) raises:
        self.inner.bind(target)

    def create_bucket_if_absent(mut self) raises:
        self.inner.create_bucket_if_absent()

    def put(mut self, key: String, body: Span[UInt8, _]) raises:
        self.inner.put(key, body)

    def list_keys(mut self, prefix: String, mut out: List[String]) raises:
        self.dir_seen_at_list.append(exists(self.watched))
        self.inner.list_keys(prefix, out)

    def delete_keys(mut self, keys: List[String], mut failed: List[String]) raises:
        self.inner.delete_keys(keys, failed)


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


def _start(
    id: String, var runner: ScriptedProcessRunner
) raises -> EmbeddedMinio[ScriptedProcessRunner]:
    var tmp = _tmp()
    var binary = _fixture_binary(tmp)
    var pins = List[MinioPin]()
    pins.append(MinioPin(current_minio_platform(), binary_sha256(binary)))
    var entropy = ScriptedEntropy(
        [UInt64(0x11), UInt64(0x22), UInt64(0x33), UInt64(100), UInt64(200)]
    )
    return start_embedded_minio_with_pins(
        RunId(id, 1790000000), binary, tmp, runner^, entropy, pins
    )


def test_open_binds_creates_and_leases_then_close_stops_last() raises:
    var id = String("1790000000-00000000000000e1")
    var server = _start(id, ScriptedProcessRunner([Readiness.ready()]))
    var dir = server.tmpdir()
    var endpoint = server.endpoint()
    var clock = FixedWallClock(1790000000)
    var b = open_embedded_minio_bucket(
        RunId(id, 1790000000), server^, "//p:embedded", 600, 60, _DirWatchingStore(dir), clock
    )
    assert_true(b.has_server())
    assert_equal(b.endpoint(), endpoint)
    assert_equal(b.region(), MINIO_REGION)
    assert_equal(b.bucket(), EMBEDDED_BUCKET)
    assert_equal(b.credentials_file(), dir + "/credentials")
    assert_equal(b.backend(), BACKEND_EMBEDDED_MINIO)
    assert_equal(b.prefix(), "runs/" + id + "/")
    ref c = b.client().inner
    assert_equal(c.calls[0], "bind")
    assert_equal(c.calls[1], "create_bucket_if_absent")
    assert_equal(c.calls[2], "put runs/" + id + "/_lease.textproto")
    assert_true(
        "backend: \"embedded-minio\"" in c.body_text("runs/" + id + "/_lease.textproto")
    )
    var body = String("x")
    b.client().put(b.key("a.bin"), body.as_bytes())

    var v = b.close()
    assert_equal(v.kind, VERDICT_CLEAN, String(v))
    # Three lists (before delete, before the lease delete, the final
    # re-list), every one while the server's directory was still there.
    ref seen = b.client().dir_seen_at_list
    assert_equal(len(seen), 3)
    for s in seen:
        assert_true(s, "a list ran after the server was stopped")
    # Then the server was stopped (5 s grace) and its directory removed.
    ref server_after = b.server().value()
    assert_true(server_after.is_stopped())
    assert_equal(len(server_after.runner().stops), 1)
    assert_equal(server_after.runner().stop_graces[0], 5)
    assert_false(exists(dir), "the temporary directory remained")
    # Idempotent: no second stop.
    assert_equal(b.close().kind, VERDICT_CLEAN)
    assert_equal(len(b.server().value().runner().stops), 1)


def test_unconfirmed_stop_is_cannot_tell() raises:
    var id = String("1790000000-00000000000000e2")
    var runner = ScriptedProcessRunner([Readiness.ready()])
    runner.stop_raises = True
    var server = _start(id, runner^)
    var dir = server.tmpdir()
    var clock = FixedWallClock(1790000000)
    var b = open_embedded_minio_bucket(
        RunId(id, 1790000000), server^, "//p:embedded", 600, 60, FakeObjectStore(), clock
    )
    var v = b.close()
    assert_equal(v.kind, VERDICT_CANNOT_TELL, String(v))
    assert_true("embedded MinIO stop not confirmed" in String(v), String(v))
    # The directory is still removed.
    assert_false(exists(dir))


def test_failed_open_stops_the_server() raises:
    var id = String("1790000000-00000000000000e3")
    var server = _start(id, ScriptedProcessRunner([Readiness.ready()]))
    var dir = server.tmpdir()
    var store = FakeObjectStore()
    store.fail_puts = True
    var clock = FixedWallClock(1790000000)
    var raised = False
    try:
        var b = open_embedded_minio_bucket(
            RunId(id, 1790000000), server^, "//p:embedded", 600, 60, store^, clock
        )
        _ = b.close()
    except e:
        raised = True
        var msg = String(e)
        assert_true("komira_test_bucket: open: put _lease.textproto" in msg, msg)
        assert_true("teardown verdict CLEAN" in msg, msg)
    assert_true(raised, "opened although the lease put failed")
    assert_false(exists(dir), "a failed open left the server's directory")


def main() raises:
    test_open_binds_creates_and_leases_then_close_stops_last()
    test_unconfirmed_stop_is_cannot_tell()
    test_failed_open_stops_the_server()
    print("test_bucket_embedded: OK")
