"""Acceptance gate -- the DISCOVERY half of the service registry.

`ServiceDirectory` binds a service NAME to the URL peers should dial, over one
`ConditionalWriteStore`. These tests are the falsifier for that contract:

  * LAST-WRITER-WINS: a URL changes on every redeploy, so the newest publish
    wins (`publish_endpoint`: read the etag, compare-and-swap, retry once on a
    412).
  * `publish_endpoint_if_changed` writes if and only if the URL changed, and an
    unchanged republish is a pure read.
  * PROVENANCE: a `ResolveResult` distinguishes a fresh store read from a cache
    hit, and an absent key still reports that the store was consulted.
  * DELETE: `withdraw_endpoint` removes the binding; withdrawing an absent one
    returns False rather than raising.
  * THE KEY COMPOSITION: the object is `service/<name>` holding the bare URL
    bytes, byte for byte what `komira_svcref.ServiceRegistry` writes, so
    switching a caller between the two is a code change with no data migration.
  * LISTING: `list_endpoints` returns every published name.
  * CONTENTION: one 412 is retried once and the write lands; a persistent 412
    raises an error that names the used-up retry and the service, and writes
    nothing.

Hermetic: `SharedInMemoryConditionalStore` plus one in-file conformer
(`_EndpointCasConflictStore`) that injects the 412 -- no live bucket, no data
files, no FFI.
"""

from std.testing import assert_equal, assert_false, assert_true

from komira_service_registry import (
    CachedServiceDirectory,
    ENDPOINT_PREFIX,
    RESOLVE_SOURCE_CACHE,
    RESOLVE_SOURCE_STORE,
    ResolveResult,
    ServiceDirectory,
)

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _found(r: ResolveResult, want: String, ctx: String) raises:
    if not r.found:
        raise Error(ctx + ": expected '" + want + "' but the key was ABSENT")
    if r.value != want:
        raise Error(ctx + ": expected '" + want + "' but got '" + r.value + "'")


def _absent(r: ResolveResult, ctx: String) raises:
    if r.found:
        raise Error(ctx + ": expected ABSENT but got '" + r.value + "'")


def _bytes(s: String) -> List[UInt8]:
    """String -> the bare object bytes, for writing a key STRAIGHT to the store
    (i.e. without going through the directory that is under test)."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _has(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


# -----------------------------------------------------------------------------
# last-writer-wins on the endpoint (the OPPOSITE policy).
# -----------------------------------------------------------------------------


def test_the_endpoint_is_last_writer_wins() raises:
    print("-- test_the_endpoint_is_last_writer_wins --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    dir.publish_endpoint(String("scheduler"), String("https://jm-v1"))
    _found(
        dir.resolve_endpoint(String("scheduler")),
        String("https://jm-v1"),
        "v1",
    )
    dir.publish_endpoint(String("scheduler"), String("https://jm-v2"))
    _found(
        dir.resolve_endpoint(String("scheduler")),
        String("https://jm-v2"),
        "v2",
    )
    print("   redeploy overwrites the endpoint OK")


# -----------------------------------------------------------------------------
# PROVENANCE.
# -----------------------------------------------------------------------------


def test_resolve_result_carries_provenance() raises:
    print("-- test_resolve_result_carries_provenance --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    dir.publish_endpoint(String("orders-api"), String("https://api.example"))

    var fresh = dir.resolve_endpoint(String("orders-api"))
    assert_equal(
        fresh.source,
        RESOLVE_SOURCE_STORE,
        String("a direct directory read is sourced from the STORE"),
    )
    assert_equal(fresh.age_ms, Int64(0), String("a fresh store read has age 0"))
    assert_equal(fresh.key, String(ENDPOINT_PREFIX) + String("/orders-api"))

    # An ABSENT key still reports that the store WAS consulted — "we looked and
    # it is not there" is a different diagnosis from "we never looked".
    var miss = dir.resolve_endpoint(String("no-such-service"))
    _absent(miss, "absent")
    assert_equal(
        miss.source,
        RESOLVE_SOURCE_STORE,
        String("an absent read still records that the store was consulted"),
    )

    # A CACHE hit reports source CACHE and a REAL age.
    var cached = CachedServiceDirectory(dir^, Int64(60000))
    var t0 = Int64(1000000)
    var first = cached.resolve_endpoint(String("orders-api"), t0)
    assert_equal(first.source, RESOLVE_SOURCE_STORE, String("cold = store"))
    var second = cached.resolve_endpoint(
        String("orders-api"), t0 + Int64(1500)
    )
    assert_equal(
        second.source, RESOLVE_SOURCE_CACHE, String("warm within TTL = cache")
    )
    assert_equal(
        second.age_ms,
        Int64(1500),
        String("a cache hit reports how stale the entry is"),
    )
    _found(second, String("https://api.example"), "cache hit value")
    # Past the TTL it reads through again.
    var third = cached.resolve_endpoint(
        String("orders-api"), t0 + Int64(60001)
    )
    assert_equal(third.source, RESOLVE_SOURCE_STORE, String("expired = store"))
    # The log line a runtime lookup emits must carry all four facts.
    var line = second.describe()
    assert_true(line.find("source=cache") >= 0, String("log line: ") + line)
    assert_true(line.find("age_ms=1500") >= 0, String("log line: ") + line)
    assert_true(line.find("key=") >= 0, String("log line: ") + line)
    print("   store / cache / absent provenance + the log line OK")


# -----------------------------------------------------------------------------
# DELETE.
# -----------------------------------------------------------------------------


def test_delete_verbs() raises:
    print("-- test_delete_verbs --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    dir.publish_endpoint(String("orphan"), String("https://orphan"))

    assert_true(
        dir.withdraw_endpoint(String("orphan")),
        String("withdrawing a present endpoint returns True"),
    )
    _absent(dir.resolve_endpoint(String("orphan")), "after withdraw")
    assert_false(
        dir.withdraw_endpoint(String("orphan")),
        String("withdrawing an ABSENT endpoint is False, not a raise"),
    )

    # A withdrawn name can be published again, and it is a plain create.
    dir.publish_endpoint(String("orphan"), String("https://orphan-v2"))
    _found(
        dir.resolve_endpoint(String("orphan")),
        String("https://orphan-v2"),
        "re-publish after withdraw",
    )
    print("   withdraw, idempotent-absent, re-publish-after-withdraw OK")


# -----------------------------------------------------------------------------
# the key composition and the stored bytes are UNCHANGED.
# -----------------------------------------------------------------------------


def test_the_endpoint_object_is_wire_identical_to_the_shipped_writer() raises:
    print("-- test_endpoint_object_is_wire_identical_to_shipped_writer --")
    var store = SharedInMemoryConditionalStore()
    var dir = ServiceDirectory(store.clone())
    dir.publish_endpoint(
        String("orders-api"), String("https://api.example:8088")
    )

    # THE KEY: `service/<name>`, and there is no second composition.
    assert_equal(String(ENDPOINT_PREFIX), String("service"))
    assert_equal(
        dir.endpoint_key(String("orders-api")), String("service/orders-api")
    )
    # THE BYTES: the bare URL, no framing, no trailing newline — read straight
    # off the store, not through our own decoder.
    var raw = store.get(Path.parse(String("service/orders-api")))
    var want = String("https://api.example:8088").as_bytes()
    assert_equal(len(raw), len(want), String("stored bytes are the bare URL"))
    for i in range(len(want)):
        assert_equal(Int(raw[i]), Int(want[i]), String("byte ") + String(i))
    print("   service/<name> -> bare URL bytes, unchanged OK")


def test_list_verbs() raises:
    print("-- test_list_verbs --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    assert_equal(len(dir.list_endpoints()), 0, String("an empty registry"))
    dir.publish_endpoint(String("a-svc"), String("https://a"))
    dir.publish_endpoint(String("b-svc"), String("https://b"))

    var eps = dir.list_endpoints()
    assert_equal(len(eps), 2, String("two endpoints"))
    assert_true(_has(eps, String("a-svc")), String("a-svc listed"))
    assert_true(_has(eps, String("b-svc")), String("b-svc listed"))
    print("   list_endpoints OK")


# -----------------------------------------------------------------------------
# `publish_endpoint_if_changed` IS A REAL PUBLISHER, NOT A NO-OP.
#
# ⚠ THE ORIGINAL ELEVEN GATES NAMED THIS METHOD ZERO TIMES. Invert it so it
# never republishes and all eleven stay green — while a redeploy silently keeps
# the STALE URL, which is the exact failure last-writer-wins exists to prevent
# and the one a level-triggered reconcile loop would hit on every advance.
#
# The two halves are asserted with DIFFERENT instruments on purpose:
#   * the CHANGED case is asserted on the STORE's bytes, so "returned True" is
#     not accepted as evidence that anything was written;
#   * the UNCHANGED case is asserted on the store's OP COUNTERS, because "no
#     write was issued" is the whole claim and a return value cannot carry it.
#     `n_head` and `n_put` are both pinned — the docstring says a steady-state
#     redeploy to the same URL is a PURE READ, i.e. no head AND no CAS.
# Together they also catch the opposite mutant (always republish).
# -----------------------------------------------------------------------------


def _stored_url(
    store: SharedInMemoryConditionalStore, name: String
) raises -> String:
    """The endpoint bytes read STRAIGHT off the store — not through our own
    decoder, and not through the directory that wrote them."""
    var raw = store.get(Path.parse(String("service/") + name))
    var out = String("")
    for i in range(len(raw)):
        out += chr(Int(raw[i]))
    return out^


def test_publish_endpoint_if_changed_writes_iff_the_url_changed() raises:
    print("-- test_publish_endpoint_if_changed_writes_iff_url_changed --")
    var store = SharedInMemoryConditionalStore()
    var dir = ServiceDirectory(store.clone())

    # (a) ABSENT key -> it must WRITE. A reconcile loop's first pass is this
    #     case, and a no-op here means the service is never discoverable.
    assert_true(
        dir.publish_endpoint_if_changed(
            String("scheduler"), String("https://jm-v1")
        ),
        String("publishing to an ABSENT key must report a write"),
    )
    assert_equal(
        _stored_url(store, String("scheduler")),
        String("https://jm-v1"),
        String("...and must actually have written it"),
    )

    # (b) UNCHANGED -> no write, and no write ISSUED: pure read.
    var puts_before = store.n_put()
    var heads_before = store.n_head()
    assert_false(
        dir.publish_endpoint_if_changed(
            String("scheduler"), String("https://jm-v1")
        ),
        String("republishing the SAME url must report no write"),
    )
    assert_equal(
        store.n_put(),
        puts_before,
        String(
            "an unchanged republish must issue NO conditional_put — a"
            " level-triggered caller would otherwise emit a steady write"
            " stream and burn publish_endpoint's retry-once budget"
        ),
    )
    assert_equal(
        store.n_head(),
        heads_before,
        String("an unchanged republish must not even HEAD — it is a pure read"),
    )
    assert_equal(
        _stored_url(store, String("scheduler")),
        String("https://jm-v1"),
        String("the unchanged url is still there"),
    )

    # (c) CHANGED -> it must WRITE, and the STORE must carry the new bytes.
    #     This is the redeploy, and a stale url here is the failure.
    assert_true(
        dir.publish_endpoint_if_changed(
            String("scheduler"), String("https://jm-v2")
        ),
        String("a CHANGED url must report a write"),
    )
    assert_equal(
        _stored_url(store, String("scheduler")),
        String("https://jm-v2"),
        String(
            "the redeploy's url must be what the store holds — keeping the"
            " stale one is the failure last-writer-wins exists to prevent"
        ),
    )
    _found(
        dir.resolve_endpoint(String("scheduler")),
        String("https://jm-v2"),
        "read back through the directory",
    )

    # (d) and it is the SAME writer: bare bytes, no framing, no trailing
    #     newline — the wire-identity claim must hold on this path too.
    var raw = store.get(Path.parse(String("service/scheduler")))
    assert_equal(
        len(raw),
        len(String("https://jm-v2").as_bytes()),
        String("the if-changed path writes the BARE url, same as publish"),
    )
    print("   writes iff changed; unchanged is a pure read; bytes are bare OK")


# -----------------------------------------------------------------------------
# ⛔ THE RETRY-ONCE ON THE ENDPOINT CAS, AND THE RAISE BEHIND IT.
#
# `publish_endpoint` calls `_try_last_writer_wins` TWICE and then raises "(412
# twice)". Nothing above reaches either the second call or the raise: every
# publish in this file runs against an uncontended store, so `_try_last_writer_wins`
# returns True on the first attempt every time.
#
# TWO MUTANTS, BOTH GREEN:
#   * delete the second `_try_last_writer_wins` — a SINGLE concurrent
#     registrant then fails a deploy that the retry exists to carry through.
#   * replace the trailing `raise` with `return` — the WORSE one:
#     `publish_endpoint` reports success having written NOTHING, and the peers
#     that resolve that name get the previous deploy's URL forever.
#
# The interleaving is injected by substituting the `Store` type-param: nothing
# about the directory is stubbed and the 412 is the real classifier's answer to
# a real conflict message.
# -----------------------------------------------------------------------------

comptime _CAS_FAULT_SENTINEL: String = "fault/endpoint-cas-armed"


struct _EndpointCasConflictStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A store that answers a write to the DISCOVERY keyspace with a 412 —
    ALWAYS when `_forever`, otherwise exactly ONCE.

    ⚠ THE ONE-SHOT BUDGET LIVES IN THE STORE, NOT IN A FIELD. The
    `ConditionalWriteStore` write verbs take `self`, not `mut self`, so a
    counter field cannot be decremented from inside one. The armed state is
    therefore an OBJECT (`fault/endpoint-cas-armed`) that the first conflict
    consumes — which also makes it observable from the test, so the arm can
    prove the fault actually fired instead of assuming it.

    ⚠ ONLY `service/` IS FAULTED, so the double stays on the discovery write
    path this test is about."""

    var _inner: SharedInMemoryConditionalStore
    var _forever: Bool

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, forever: Bool
    ) raises:
        if not forever:
            _ = inner.put(
                Path.parse(String(_CAS_FAULT_SENTINEL)),
                _bytes(String("armed")),
            )
        self._inner = inner^
        self._forever = forever

    def _should_fault(self, path: Path) raises -> Bool:
        if path.raw().find(String(ENDPOINT_PREFIX) + String("/")) != 0:
            return False
        if self._forever:
            return True
        var armed = True
        try:
            _ = self._inner.head(Path.parse(String(_CAS_FAULT_SENTINEL)))
        except:
            armed = False
        if armed:
            self._inner.delete(Path.parse(String(_CAS_FAULT_SENTINEL)))
        return armed

    def _conflict(self, path: Path) -> Error:
        """The 412 a real concurrent registrant produces — the canonical GCS
        spelling, numeric included, so this test is independent of the canonical-token one."""
        return Error(
            String("StoreError[PRECONDITION] conditional_put gs://")
            + String("example-bucket/")
            + path.raw()
            + String(" status=412 grpc_code=10 grpc_detail=[grpc:10] SERVER:")
            + String(" generation precondition failed")
        )

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if self._should_fault(path):
            raise self._conflict(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        if self._should_fault(path):
            raise self._conflict(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _sentinel_consumed(store: SharedInMemoryConditionalStore) raises -> Bool:
    try:
        _ = store.head(Path.parse(String(_CAS_FAULT_SENTINEL)))
    except:
        return True
    return False


def test_a_contended_endpoint_publish_retries_ONCE_and_then_RAISES() raises:
    print("-- test_a_contended_endpoint_publish_retries_ONCE_and_then_RAISES --")

    # ── TRANSIENT CONTENTION: exactly one 412, then the write must LAND. ────
    var inner = SharedInMemoryConditionalStore()
    var dir = ServiceDirectory(_EndpointCasConflictStore(inner.clone(), False))
    assert_false(
        _sentinel_consumed(inner.clone()),
        "fixture drift: the one-shot fault must be ARMED before the publish",
    )
    # Caught and re-stated: under the retry-deleted mutant the production's own
    # "(412 twice)" raise propagates, and reading that uncaught says the retry
    # was EXHAUSTED — the opposite of what happened, which was that it was never
    # attempted.
    var transient_err = String("")
    try:
        dir.publish_endpoint(String("alpha-svc"), String("https://alpha"))
    except e:
        transient_err = String(e)
    assert_equal(
        transient_err,
        String(""),
        String(
            "ONE 412 must be RETRIED, not raised. `publish_endpoint` calls"
            " `_try_last_writer_wins` TWICE before it gives up, because"
            " publishing is a deploy-time event and a single concurrent"
            " registrant must not fail the deploy. A raise here is the retry"
            " having been REMOVED, not the retry having been exhausted. Got: "
        )
        + transient_err,
    )
    # ⛔ VACUITY GUARD. Without this the arm passes on a production with NO
    # retry at all, as long as the double never happened to fire.
    assert_true(
        _sentinel_consumed(inner.clone()),
        "fixture drift: the one-shot 412 never fired, so this gate proved"
        " nothing about the retry",
    )
    # Read back through a CLEAN handle — the fact asserted is the STORE's, not
    # the return value of the verb under test.
    _found(
        ServiceDirectory(inner.clone()).resolve_endpoint(String("alpha-svc")),
        String("https://alpha"),
        "ONE concurrent registrant must not fail the deploy — the retry exists"
        " because publishing is a deploy-time event and two publishers racing"
        " one name is already unlikely",
    )

    # The retry budget is per CALL, not per directory: a second publish through
    # the same directory re-arms nothing and simply commits.
    dir.publish_endpoint(String("alpha-svc"), String("https://alpha-v2"))
    _found(
        ServiceDirectory(inner.clone()).resolve_endpoint(String("alpha-svc")),
        String("https://alpha-v2"),
        "an uncontended re-publish still commits",
    )

    # ── PERMANENT CONTENTION: it RAISES, and says which failure it is. ──────
    var inner2 = SharedInMemoryConditionalStore()
    var dir2 = ServiceDirectory(_EndpointCasConflictStore(inner2.clone(), True))
    var raised = String("")
    try:
        dir2.publish_endpoint(String("beta-svc"), String("https://beta"))
    except e:
        raised = String(e)
    assert_true(
        raised.byte_length() > 0,
        "PERSISTENT CAS contention must RAISE. A `publish_endpoint` that"
        " returns having written nothing reports a successful deploy whose"
        " peers keep resolving the PREVIOUS deploy's URL forever",
    )
    assert_true(
        raised.find("412 twice") >= 0,
        String(
            "...and the raise must name the exhausted retry, not merely"
            " propagate the store's 412 — 'we tried twice' is what tells the"
            " operator to re-run the deploy rather than to go looking for a"
            " permissions problem. Got: "
        )
        + raised,
    )
    assert_true(
        raised.find("beta-svc") >= 0,
        String("...and it names the service. Got: ") + raised,
    )
    _absent(
        ServiceDirectory(inner2.clone()).resolve_endpoint(String("beta-svc")),
        "a refused publish writes nothing",
    )

    print("   one 412 retried, a permanent 412 raised naming '412 twice' OK")


def main() raises:
    test_the_endpoint_is_last_writer_wins()
    test_publish_endpoint_if_changed_writes_iff_the_url_changed()
    test_resolve_result_carries_provenance()
    test_delete_verbs()
    test_the_endpoint_object_is_wire_identical_to_the_shipped_writer()
    test_list_verbs()
    test_a_contended_endpoint_publish_retries_ONCE_and_then_RAISES()
    print("ALL SERVICE-DISCOVERY CONTRACT TESTS PASSED")
