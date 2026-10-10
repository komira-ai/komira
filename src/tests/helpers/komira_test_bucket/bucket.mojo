# =============================================================================
# komira_test_bucket/bucket.mojo -- `TestBucket`: one run's private prefix in
# an object store, which deletes what is under it and proves it did.
# =============================================================================
#
# Every object of a run lives under `runs/<run_id>/`. Opening a bucket
# writes `<prefix>_lease.textproto` (run id, target label, creation time,
# deadline, backend) BEFORE any other object, so anything a run leaves behind
# is attributable from its first byte, even when the test is killed a moment
# later.
#
# The test under test is usually another process (or a client built from the
# test's own flags). `as_flags()` hands it what it needs: the endpoint,
# region, bucket and prefix, and the PATH of an AWS shared-credentials file.
# Secrets travel by path only.
#
# ── TEARDOWN IS EXPLICIT ─────────────────────────────────────────────────────
# `close()` is mandatory. It lists the prefix and deletes everything but
# `_lease`, then lists AGAIN and deletes `_lease` only when that listing shows
# nothing else is left (a delete reported successful does not prove the key
# is gone, and a program still running can write during the close), so
# residue stays attributable. It then lists a last time to prove the prefix
# is empty, and only THEN, for a bucket on an embedded MinIO, stops the
# server and removes its temporary directory (`EmbeddedMinio.stop`). Only
# keys inside the prefix are ever deleted (`_key_in_run`). It returns a
# `Verdict` and keeps every failure it met; calling it again returns the same
# verdict and does nothing.
#
# A destructor cannot fail a test: it cannot raise, and Mojo runs it at the
# handle's LAST USE, not at the end of the scope. So a test calls `close()`
# itself, at the end, and checks the verdict:
#
#     var bucket = open_test_bucket(run_id, scope, flags.target, client^, clock)
#     ...                                  # the test body
#     bucket.close().require_clean()       # the last use of `bucket`
#
# A handle destroyed while still open is a bug in the test: its destructor
# tears down, then ends the process with Mojo's `abort()` and the message
# `komira_test_bucket: UNCLOSED HANDLE (LEAK-RISK) <verdict>`. On Mojo 1.0
# `abort()` is a trap: the process dies of SIGILL (exit 132, measured), not
# of SIGKILL (137), so a runner that retries killed tests cannot turn it into
# a pass.
#
# That includes a test that RAISES while a handle is open: the error unwinds,
# the handle is destroyed unclosed, and the abort message is what the log
# shows, not the error. A test whose body can raise closes in a `finally`:
#
#     var bucket = open_test_bucket(...)
#     var verdict = Verdict()
#     try:
#         ...                              # the test body
#     finally:
#         verdict = bucket.close()         # runs whether or not the body raised
#     verdict.require_clean()
#
# The deadline: `deadline_unix() = created + max_lease_seconds`.
# `check_deadline(clock)` raises once `deadline - teardown_budget_seconds` has
# passed, so a long test stops creating while there is still time to clean
# up. This package does not end the process at the deadline; whatever grants
# the lease enforces it.
#
# Two ways to open one, and the external store's bucket is never created or
# deleted:
#   * `open_test_bucket`: an external S3-compatible store (`StoreScope`);
#   * `open_embedded_minio_bucket`: a MinIO the test started
#     (komira_test_minio), on which this package creates its bucket and which
#     the handle then owns and stops in `close()`.
# `open_test_bucket_from_flags` (flags.mojo) picks one from the test's flags.
# =============================================================================

from std.os import abort

from komira_test_minio import EmbeddedMinio, NoProcess, ProcessRunner
from komira_test_run_id import RunId, WallClock
from komira_test_verdict import Verdict
from komira_validation_run.validation_run_tag import is_valid_validation_run_id

from ._redact import _Redactor
from .leak_check import _key_in_run, _leak_check_prefix, _run_prefix_for
from .store import ObjectStoreClient, StoreScope, StoreTarget

comptime LEASE_OBJECT: String = "_lease.textproto"
"""The lease object's name under a run's prefix."""

comptime BACKEND_EXTERNAL_S3: String = "external-s3"
comptime BACKEND_EMBEDDED_MINIO: String = "embedded-minio"

comptime EMBEDDED_BUCKET: String = "komira-test-embedded"
"""The bucket this package creates on an embedded MinIO. It names a private
server the test starts and destroys, nothing that outlives a test."""

comptime UNCLOSED_HANDLE_MARKER: String = "komira_test_bucket: UNCLOSED HANDLE (LEAK-RISK)"


def _quote(s: String) -> String:
    """A textproto string literal for `s`."""
    var out = String("\"")
    out += s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
    out += "\""
    return out^


def lease_text(
    run_id: String, target: String, created_unix: Int, deadline_unix: Int, backend: String
) -> String:
    """The `_lease.textproto` body."""
    var out = String("run_id: ") + _quote(run_id) + "\n"
    out += String("target: ") + _quote(target) + "\n"
    out += String("created_unix: ") + String(created_unix) + "\n"
    out += String("deadline_unix: ") + String(deadline_unix) + "\n"
    out += String("backend: ") + _quote(backend) + "\n"
    return out^


def _check_relative_key(rel: String) raises:
    if rel.byte_length() == 0:
        raise Error("key: refused an empty key")
    if rel.startswith("/"):
        raise Error("key: refused a key starting with '/'")
    for seg in rel.split("/"):
        if seg == "..":
            raise Error("key: refused a key with a '..' segment")
    if rel == LEASE_OBJECT:
        raise Error("key: refused the lease object's name")


def _unclosed_message(v: Verdict) -> String:
    return String(UNCLOSED_HANDLE_MARKER) + " " + String(v)


def _scrubbed(v: Verdict, redactor: _Redactor) -> Verdict:
    """`v` with every reason passed through the redactor."""
    var out = Verdict()
    out.kind = v.kind
    for k in v.residue:
        out.residue.append(k)
    for r in v.reasons:
        out.reasons.append(redactor.scrub(r))
    return out^


struct _BucketState[S: ObjectStoreClient, P: ProcessRunner](Movable):
    """Everything a handle owns. Kept apart from `TestBucket` so the
    destructor can run the same `close` a test calls."""

    var client: Self.S
    var server: Optional[EmbeddedMinio[Self.P]]
    var bound: Bool
    var run_id: RunId
    var prefix: String
    var target: StoreTarget
    var redactor: _Redactor
    var created: Int
    var deadline: Int
    var teardown_budget: Int
    var backend: String
    var closed: Bool
    var verdict: Verdict

    def __init__(
        out self,
        var client: Self.S,
        var server: Optional[EmbeddedMinio[Self.P]],
        var run_id: RunId,
        var prefix: String,
        var target: StoreTarget,
        created: Int,
        deadline: Int,
        teardown_budget: Int,
        var backend: String,
    ):
        self.client = client^
        self.server = server^
        self.bound = False
        self.run_id = run_id^
        self.prefix = prefix^
        self.redactor = _Redactor(target.endpoint, target.bucket, target.credentials_file)
        self.target = target^
        self.created = created
        self.deadline = deadline
        self.teardown_budget = teardown_budget
        self.backend = backend^
        self.closed = False
        self.verdict = Verdict()

    def rel(self, key: String) -> String:
        var n = self.prefix.byte_length()
        if key.startswith(self.prefix) and key.byte_length() > n:
            return String(key[byte=n:])
        return key

    def close(mut self) -> Verdict:
        if self.closed:
            return self.verdict.copy()
        var v = Verdict()
        if self.bound:
            self._delete_prefix(v)
            v.merge(_leak_check_prefix(self.prefix, self.client, self.redactor))
        # The server goes only after the final re-list: stopping it first
        # would turn "is the prefix empty?" into a list that cannot answer.
        if self.server:
            v.merge(_scrubbed(self.server.value().stop(), self.redactor))
        self.closed = True
        self.verdict = v.copy()
        return v^

    def _delete_prefix(mut self, mut v: Verdict):
        var keys = List[String]()
        try:
            self.client.list_keys(self.prefix, keys)
        except e:
            v.add_cannot_tell("list_keys (before delete): " + self.redactor.scrub(String(e)))
            return
        var lease_key = self.prefix + LEASE_OBJECT
        var others = List[String]()
        var has_lease = False
        for k in keys:
            if not _key_in_run(k, self.prefix):
                continue
            if k == lease_key:
                has_lease = True
            else:
                others.append(k)
        var failed = List[String]()
        var request_ok = True
        if len(others) > 0:
            try:
                self.client.delete_keys(others, failed)
            except e:
                request_ok = False
                v.add_leak("delete_keys: " + self.redactor.scrub(String(e)))
        for f in failed:
            v.add_leak("delete failed: " + self.rel(f))
        if not has_lease:
            return
        if not request_ok or len(failed) > 0:
            v.add_leak(String("kept ") + LEASE_OBJECT + " so the residue stays attributable")
            return
        # A delete reported successful is not proof the key is gone, and a
        # program still running can write during the close: list again and
        # delete the lease only when it is the last key left. What remains is
        # charged by the final re-list in `close`, not here.
        var left = List[String]()
        try:
            self.client.list_keys(self.prefix, left)
        except e:
            v.add_cannot_tell(
                "list_keys (before lease delete): " + self.redactor.scrub(String(e))
            )
            v.add_leak(String("kept ") + LEASE_OBJECT + " so the residue stays attributable")
            return
        var lease_left = False
        for k in left:
            if not _key_in_run(k, self.prefix):
                continue
            if k == lease_key:
                lease_left = True
            else:
                v.add_leak(
                    String("kept ") + LEASE_OBJECT + " so the residue stays attributable"
                )
                return
        if not lease_left:
            return
        var lease_failed = List[String]()
        var lease_keys = List[String]()
        lease_keys.append(lease_key)
        try:
            self.client.delete_keys(lease_keys, lease_failed)
        except e:
            v.add_leak("delete_keys (lease): " + self.redactor.scrub(String(e)))
        for f in lease_failed:
            v.add_leak("delete failed: " + self.rel(f))


struct TestBucket[S: ObjectStoreClient, P: ProcessRunner = NoProcess](Movable):
    """One run's prefix in an object store. See the module header: call
    `close()` at the end of the test and check its verdict. `P` is the
    process runner of an embedded MinIO the handle owns; on an external
    store it is `NoProcess` and there is no server."""

    var _state: _BucketState[Self.S, Self.P]

    def __init__(out self, var state: _BucketState[Self.S, Self.P]):
        self._state = state^

    def __deinit__(deinit self):
        if not self._state.closed:
            abort(_unclosed_message(self._state.close()))

    def _teardown_unclosed(mut self) -> String:
        """What the destructor of an unclosed handle does, minus the abort:
        tear down and build the abort message. For the package's own test."""
        return _unclosed_message(self._state.close())

    def close(mut self) -> Verdict:
        """Delete everything under the prefix, re-list, then stop an embedded
        MinIO server and remove its temporary directory. Idempotent."""
        return self._state.close()

    def is_closed(self) -> Bool:
        return self._state.closed

    def client(ref self) -> ref [self._state.client] Self.S:
        """The bound client, for a test that drives the store in-process."""
        return self._state.client

    def has_server(self) -> Bool:
        """True when the handle owns an embedded MinIO."""
        return Bool(self._state.server)

    def server(ref self) -> ref [self._state.server] Optional[EmbeddedMinio[Self.P]]:
        """The embedded MinIO the handle owns, if any. `close()` stops it."""
        return self._state.server

    def run_id(self) -> RunId:
        return self._state.run_id.copy()

    def prefix(self) -> String:
        """`runs/<run_id>/`."""
        return self._state.prefix

    def key(self, rel: String) raises -> String:
        """The full key for `rel` under the prefix. Refuses an empty key, a
        leading `/`, a `..` segment and the lease object's name."""
        _check_relative_key(rel)
        return self._state.prefix + rel

    def endpoint(self) -> String:
        return self._state.target.endpoint

    def bucket(self) -> String:
        return self._state.target.bucket

    def region(self) -> String:
        return self._state.target.region

    def credentials_file(self) -> String:
        return self._state.target.credentials_file

    def created_unix(self) -> Int:
        return self._state.created

    def deadline_unix(self) -> Int:
        return self._state.deadline

    def backend(self) -> String:
        return self._state.backend

    def as_flags(self) -> List[String]:
        """The flags for the program under test: where the store is and the
        PATH of the credentials file. No secret value."""
        var out = List[String]()
        out.append("--s3-endpoint=" + self._state.target.endpoint)
        out.append("--s3-region=" + self._state.target.region)
        out.append("--s3-bucket=" + self._state.target.bucket)
        out.append("--s3-prefix=" + self._state.prefix)
        out.append("--aws-shared-credentials-file=" + self._state.target.credentials_file)
        return out^

    def check_deadline[C: WallClock](self, mut clock: C) raises:
        """Raise once `deadline - teardown_budget` has passed: the test must
        stop creating and tear down."""
        var now = clock.now_unix()
        var stop_at = self._state.deadline - self._state.teardown_budget
        if now >= stop_at:
            raise Error(
                "komira_test_bucket: lease deadline: "
                + String(now - stop_at)
                + "s past the point where teardown must start"
            )


def _open_bucket[S: ObjectStoreClient, P: ProcessRunner, C: WallClock](
    run_id: RunId,
    var target: StoreTarget,
    max_lease_seconds: Int,
    teardown_budget_seconds: Int,
    target_label: String,
    backend: String,
    var client: S,
    var server: Optional[EmbeddedMinio[P]],
    create_bucket: Bool,
    mut clock: C,
) raises -> TestBucket[S, P]:
    """Build the handle (which then owns the server, if any), then bind,
    (create the bucket,) and write the lease. A failure after the handle
    exists tears it down and raises with the teardown verdict, so a failed
    open leaves nothing open and no server running."""
    var created = clock.now_unix()
    var state = _BucketState[S, P](
        client^,
        server^,
        run_id.copy(),
        _run_prefix_for(run_id.value),
        target^,
        created,
        created + max_lease_seconds,
        teardown_budget_seconds,
        backend,
    )
    var bucket = TestBucket[S, P](state^)
    var step = String("bind")
    try:
        if run_id.value.byte_length() == 0 or not is_valid_validation_run_id(run_id.value):
            step = String("run id")
            raise Error("refused an empty or invalid run id")
        if target_label.byte_length() == 0:
            step = String("target label")
            raise Error("refused an empty target label (pass --test-target)")
        if max_lease_seconds <= 0 or teardown_budget_seconds <= 0 or (
            teardown_budget_seconds >= max_lease_seconds
        ):
            step = String("lease")
            raise Error(
                "refused a lease whose teardown budget is not positive and below its"
                " maximum length"
            )
        if created <= 0:
            step = String("clock")
            raise Error("the wall clock read " + String(created))
        bucket._state.client.bind(bucket._state.target)
        bucket._state.bound = True
        if create_bucket:
            step = String("create_bucket_if_absent")
            bucket._state.client.create_bucket_if_absent()
        step = String("put ") + LEASE_OBJECT
        var body = lease_text(
            run_id.value, target_label, created, created + max_lease_seconds, backend
        )
        bucket._state.client.put(bucket._state.prefix + LEASE_OBJECT, body.as_bytes())
    except e:
        var msg = bucket._state.redactor.scrub(String(e))
        var v = bucket.close()
        raise Error(
            "komira_test_bucket: open: "
            + step
            + ": "
            + msg
            + "; teardown verdict "
            + String(v)
        )
    return bucket^


def _open_external[S: ObjectStoreClient, P: ProcessRunner, C: WallClock](
    run_id: RunId,
    scope: StoreScope,
    target_label: String,
    var client: S,
    mut clock: C,
) raises -> TestBucket[S, P]:
    return _open_bucket[S, P, C](
        run_id,
        scope.target.copy(),
        scope.max_lease_seconds,
        scope.teardown_budget_seconds,
        target_label,
        String(BACKEND_EXTERNAL_S3),
        client^,
        Optional[EmbeddedMinio[P]](),
        False,
        clock,
    )


def open_test_bucket[S: ObjectStoreClient, C: WallClock](
    run_id: RunId,
    scope: StoreScope,
    target_label: String,
    var client: S,
    mut clock: C,
) raises -> TestBucket[S, NoProcess]:
    """Open this run's prefix in the external S3-compatible store `scope`
    describes. Its bucket must already exist; it is never created or
    deleted. `client` is unbound; this call binds it. `target_label` is the
    test target, as the runner passed it in `--test-target`."""
    return _open_external[S, NoProcess, C](run_id, scope, target_label, client^, clock)


def open_embedded_minio_bucket[S: ObjectStoreClient, P: ProcessRunner, C: WallClock](
    run_id: RunId,
    var server: EmbeddedMinio[P],
    target_label: String,
    max_lease_seconds: Int,
    teardown_budget_seconds: Int,
    var client: S,
    mut clock: C,
) raises -> TestBucket[S, P]:
    """Open this run's prefix on an embedded MinIO the test started
    (`komira_test_minio.start_embedded_minio`): bind to its endpoint, create
    the bucket `EMBEDDED_BUCKET`, write the lease. The handle owns the
    server from here on: `close()` stops it after the final re-list, and a
    failed open stops it before raising."""
    var target = StoreTarget(
        server.endpoint(), server.region(), String(EMBEDDED_BUCKET), server.credentials_file()
    )
    return _open_bucket[S, P, C](
        run_id,
        target^,
        max_lease_seconds,
        teardown_budget_seconds,
        target_label,
        String(BACKEND_EMBEDDED_MINIO),
        client^,
        Optional[EmbeddedMinio[P]](server^),
        True,
        clock,
    )
