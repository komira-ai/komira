# =============================================================================
# komira_test_bucket/store.mojo -- the object-store seam: the five operations
# a test bucket needs from an S3-compatible client, and an in-memory fake.
# =============================================================================
#
# This package depends on no cloud library. A real client (S3 over SigV4)
# implements `ObjectStoreClient` in an adapter package that depends on both
# that client and this package; neither of the two depends on the other. Its
# `bind` builds its credential chain over the shared-credentials FILE named by
# `StoreTarget.credentials_file` (profile `default`), with no process
# environment read; `list_keys` pages ListObjectsV2 to the last page;
# `delete_keys` batches DeleteObjects and reports each per-key error in
# `failed`.
#
# Contract every conformer keeps:
#   * `bind` is called once, before any other method.
#   * `list_keys` returns ALL keys under the prefix, every page. A raise means
#     "could not enumerate", never "found nothing".
#   * `delete_keys` puts each key it could not delete in `failed`, and raises
#     only when the request as a whole failed.
#   * Messages name the operation and the HTTP status and never the endpoint,
#     the bucket or a credential. (The package also scrubs the configured
#     endpoint from anything it reports, as a second line of defence.)
# =============================================================================

from std.collections import Dict


comptime RUN_PREFIX: String = "runs/"
"""Every run lives under `runs/<run_id>/`, on every store."""


struct StoreTarget(Copyable, Movable):
    """Where a client points: endpoint, region, bucket, and the PATH of an AWS
    shared-credentials file. Never a secret value. Not `Writable`: its fields
    are deployment facts that must not reach a log."""

    var endpoint: String
    var region: String
    var bucket: String
    var credentials_file: String

    def __init__(
        out self,
        var endpoint: String,
        var region: String,
        var bucket: String,
        var credentials_file: String,
    ):
        self.endpoint = endpoint^
        self.region = region^
        self.bucket = bucket^
        self.credentials_file = credentials_file^


struct StoreScope(Copyable, Movable):
    """An external S3-compatible store and a run's lease limits: what
    `open_test_bucket` needs besides a client. Not `Writable`, like
    `StoreTarget`."""

    var target: StoreTarget
    var max_lease_seconds: Int
    var teardown_budget_seconds: Int

    def __init__(
        out self, var target: StoreTarget, max_lease_seconds: Int, teardown_budget_seconds: Int
    ):
        self.target = target^
        self.max_lease_seconds = max_lease_seconds
        self.teardown_budget_seconds = teardown_budget_seconds


trait ObjectStoreClient(Movable, Deinitable):
    """The object-store operations a test bucket needs. See the module header
    for the contract."""

    def bind(mut self, target: StoreTarget) raises:
        """Point the client at `target`. Called once, before anything else."""
        ...

    def create_bucket_if_absent(mut self) raises:
        """Create the bound bucket unless it exists. Called only on the
        embedded MinIO the test started: an external endpoint's bucket must
        already exist, and is never created or deleted there."""
        ...

    def put(mut self, key: String, body: Span[UInt8, _]) raises:
        ...

    def list_keys(mut self, prefix: String, mut out: List[String]) raises:
        """Append every key under `prefix` (all pages) to `out`. Raise when
        the listing cannot be completed."""
        ...

    def delete_keys(mut self, keys: List[String], mut failed: List[String]) raises:
        """Delete `keys`; append each one that could not be deleted to
        `failed`. Raise only when the request as a whole failed."""
        ...


struct FakeObjectStore(ObjectStoreClient):
    """An in-memory object store that records every call.

    Fault injection:
      * `fail_list_calls`: the 0-based indices of `list_keys` calls that raise
        (HTTP 503).
      * `fail_delete_keys`: keys whose delete is reported failed and kept.
      * `sticky_keys`: keys whose delete is reported successful but kept.
      * `fail_delete_request`: every `delete_keys` call raises.
      * `fail_puts`: every `put` raises.
      * `extra_listed_keys`: keys every `list_keys` call returns whatever the
        prefix, as a misbehaving client might (for the out-of-prefix guards).
      * `echo_endpoint_in_errors`: injected errors quote the bound endpoint,
        as a careless client might, so a test can prove the package scrubs it.
    """

    var objects: Dict[String, List[UInt8]]
    var calls: List[String]
    var bound: Bool
    var target_endpoint: String
    var target_region: String
    var target_bucket: String
    var target_credentials_file: String
    var bucket_created: Bool
    var list_calls: Int
    var fail_list_calls: List[Int]
    var fail_delete_keys: List[String]
    var sticky_keys: List[String]
    var fail_delete_request: Bool
    var fail_puts: Bool
    var extra_listed_keys: List[String]
    var echo_endpoint_in_errors: Bool

    def __init__(out self):
        self.objects = Dict[String, List[UInt8]]()
        self.calls = List[String]()
        self.bound = False
        self.target_endpoint = String("")
        self.target_region = String("")
        self.target_bucket = String("")
        self.target_credentials_file = String("")
        self.bucket_created = False
        self.list_calls = 0
        self.fail_list_calls = List[Int]()
        self.fail_delete_keys = List[String]()
        self.sticky_keys = List[String]()
        self.fail_delete_request = False
        self.fail_puts = False
        self.extra_listed_keys = List[String]()
        self.echo_endpoint_in_errors = False

    def seed(mut self, key: String, text: String):
        """Store an object without recording a call (another run's, say)."""
        var body = List[UInt8]()
        for b in text.as_bytes():
            body.append(b)
        self.objects[key] = body^

    def has(self, key: String) -> Bool:
        return key in self.objects

    def body_text(self, key: String) raises -> String:
        var v = self.objects.get(key)
        if not v:
            raise Error("FakeObjectStore: no object " + key)
        var body = v.value().copy()
        return String(unsafe_from_utf8=Span(body))

    def _fail(self, op: String, status: Int) -> Error:
        var msg = op + ": HTTP " + String(status) + " (injected)"
        if self.echo_endpoint_in_errors:
            msg += " from " + self.target_endpoint
        return Error(msg)

    def _require_bound(self, op: String) raises:
        if not self.bound:
            raise Error("FakeObjectStore: " + op + " before bind")

    def bind(mut self, target: StoreTarget) raises:
        if self.bound:
            raise Error("FakeObjectStore: bind called twice")
        self.calls.append(String("bind"))
        self.bound = True
        self.target_endpoint = target.endpoint
        self.target_region = target.region
        self.target_bucket = target.bucket
        self.target_credentials_file = target.credentials_file

    def create_bucket_if_absent(mut self) raises:
        self._require_bound("create_bucket_if_absent")
        self.calls.append(String("create_bucket_if_absent"))
        self.bucket_created = True

    def put(mut self, key: String, body: Span[UInt8, _]) raises:
        self._require_bound("put")
        self.calls.append(String("put ") + key)
        if self.fail_puts:
            raise self._fail("put", 500)
        var copy = List[UInt8]()
        for b in body:
            copy.append(b)
        self.objects[key] = copy^

    def list_keys(mut self, prefix: String, mut out: List[String]) raises:
        self._require_bound("list_keys")
        var index = self.list_calls
        self.list_calls += 1
        self.calls.append(String("list_keys ") + prefix)
        for i in self.fail_list_calls:
            if i == index:
                raise self._fail("list_keys", 503)
        var keys = List[String]()
        for k in self.objects.keys():
            if k.startswith(prefix):
                keys.append(k)
        sort(keys)
        for k in keys:
            out.append(k)
        for k in self.extra_listed_keys:
            out.append(k)

    def delete_keys(mut self, keys: List[String], mut failed: List[String]) raises:
        self._require_bound("delete_keys")
        var joined = String("delete_keys")
        for i in range(len(keys)):
            joined += " " if i == 0 else ","
            joined += keys[i]
        self.calls.append(joined^)
        if self.fail_delete_request:
            raise self._fail("delete_keys", 500)
        for k in keys:
            if _contains(self.fail_delete_keys, k):
                failed.append(k)
                continue
            if _contains(self.sticky_keys, k):
                continue
            if k in self.objects:
                _ = self.objects.pop(k)


def _contains(xs: List[String], x: String) -> Bool:
    for v in xs:
        if v == x:
            return True
    return False
