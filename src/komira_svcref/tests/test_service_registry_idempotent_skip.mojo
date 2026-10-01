# =============================================================================
# test_service_registry_idempotent_skip.mojo — the idempotent-skip gate for
#   ServiceRegistry.register_if_changed (the LEVEL-TRIGGERED write guard).
# =============================================================================
#
# `register` ALWAYS does a head + CAS (it is never a no-op). A reconcile loop
# that re-registers on every health-gate advance is LEVEL-TRIGGERED, so an
# unconditional `register` there would emit a steady bucket write stream AND
# can exhaust the retry-once budget racing a deploy CLI that writes the same
# `service/<name>` key. `register_if_changed`
# resolve-and-compares FIRST, skipping the head+CAS entirely when the stored URL
# already equals the observed one.
#
# The gate asserts the skip via a STORE CALL-COUNT: the second
# `register_if_changed` with the SAME url issues ZERO head / conditional_put /
# compare_and_swap — ONLY the `get` of the resolve. A CHANGED url falls through
# to `register` (a head + CAS write). The counting decorator mirrors the
# `_RacingOnceStore` shape in the CAS test (ObjectStore + ConditionalWriteStore delegation, with
# an ArcPointer-shared counter cell so the immutable-`self` verbs can tally).
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_svcref.service_registry import ServiceRegistry

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
# The interior-mutable op counter, shared via ArcPointer so the immutable-`self`
# ObjectStore / ConditionalWriteStore verbs can tally their calls.
# -----------------------------------------------------------------------------
struct _Counts(Movable, Deinitable):
    var head: Int
    var put: Int  # conditional_put (create-if-absent)
    var cas: Int  # compare_and_swap (If-Match update)
    var get: Int  # get (the resolve read)

    def __init__(out self):
        self.head = 0
        self.put = 0
        self.cas = 0
        self.get = 0


struct _CountingStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A `ConditionalWriteStore` decorator that TALLIES the head / conditional_put
    / compare_and_swap / get verbs (the ones `register` / `resolve` drive) into a
    shared `_Counts` cell, delegating every verb to the inner in-memory store
    unchanged. The shared cell lets the test read the tallies AFTER the store has
    been moved into the `ServiceRegistry`."""

    var _inner: SharedInMemoryConditionalStore
    var _c: ArcPointer[_Counts]

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^
        self._c = ArcPointer[_Counts](_Counts())

    def counts(self) -> ArcPointer[_Counts]:
        """A shared handle to the counter cell (refcount-bump) the test snapshots
        before/after each op."""
        return self._c.copy()

    # ---- ObjectStore surface ----
    def head(self, path: Path) raises -> ObjectMeta:
        self._c[].head += 1
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----
    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._c[].put += 1
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._c[].cas += 1
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._c[].get += 1
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _eq_opt(got: Optional[String], want: String, ctx: String) raises:
    if not got:
        raise Error(ctx + ": expected '" + want + "' but got None")
    if got.value() != want:
        raise Error(
            ctx + ": expected '" + want + "' but got '" + got.value() + "'"
        )


# =============================================================================
# (a) UNCHANGED re-register is a PURE READ: no head, no conditional_put, no CAS —
#     only the resolve's `get`. This is the load-bearing idempotent-skip falsifier.
# =============================================================================
def test_register_if_changed_skips_unchanged() raises:
    var counting = _CountingStore(SharedInMemoryConditionalStore())
    var counts = counting.counts()  # shared handle before the store is moved
    var reg = ServiceRegistry(counting^)

    # First registration: an absent object -> head (404) + conditional_put.
    reg.register(String("example-api"), String("http://api:8088"))
    var head0 = counts[].head
    var put0 = counts[].put
    var cas0 = counts[].cas
    var get0 = counts[].get

    # Re-register the SAME url via register_if_changed -> resolve-and-compare
    # SKIPS the write: ONLY a `get` (the resolve), ZERO head/put/cas.
    var wrote = reg.register_if_changed(
        String("example-api"), String("http://api:8088")
    )
    assert_false(
        wrote, "register_if_changed of an UNCHANGED url returns False (skip)"
    )
    assert_equal(
        counts[].head, head0, "NO head on the unchanged-url skip (pure read)"
    )
    assert_equal(
        counts[].put, put0, "NO conditional_put on the unchanged-url skip"
    )
    assert_equal(
        counts[].cas, cas0, "NO compare_and_swap on the unchanged-url skip"
    )
    assert_true(
        counts[].get > get0,
        "the unchanged-url skip DID issue the resolve's get (a pure read)",
    )


# =============================================================================
# (b) CHANGED re-register falls through to register: a head + CAS write, and the
#     stored URL becomes the new one (last-writer-wins).
# =============================================================================
def test_register_if_changed_writes_on_change() raises:
    var counting = _CountingStore(SharedInMemoryConditionalStore())
    var counts = counting.counts()
    var reg = ServiceRegistry(counting^)

    reg.register(String("worker"), String("http://worker-v1:9000"))
    var head0 = counts[].head
    var cas0 = counts[].cas

    # A DIFFERENT url -> register_if_changed writes (head + compare_and_swap).
    var wrote = reg.register_if_changed(
        String("worker"), String("http://worker-v2:9000")
    )
    assert_true(
        wrote, "register_if_changed of a CHANGED url returns True (write issued)"
    )
    assert_true(
        counts[].head > head0 or counts[].cas > cas0,
        "the changed-url path issued a head/CAS write",
    )
    _eq_opt(
        reg.resolve(String("worker")),
        String("http://worker-v2:9000"),
        "the changed url was written (last-writer-wins)",
    )


# =============================================================================
# (c) ABSENT object -> register_if_changed writes (the create path): resolve None
#     is treated as changed, so the first observation of a URL is registered.
# =============================================================================
def test_register_if_changed_writes_when_absent() raises:
    var counting = _CountingStore(SharedInMemoryConditionalStore())
    var counts = counting.counts()
    var reg = ServiceRegistry(counting^)

    var wrote = reg.register_if_changed(
        String("scheduler"), String("http://scheduler:8080")
    )
    assert_true(
        wrote,
        "register_if_changed of an ABSENT service returns True (create write)",
    )
    assert_true(
        counts[].put > 0, "an absent service takes the conditional_put create path"
    )
    _eq_opt(
        reg.resolve(String("scheduler")),
        String("http://scheduler:8080"),
        "the absent service was registered",
    )


def main() raises:
    print("== ServiceRegistry.register_if_changed idempotent-skip gate ==")
    test_register_if_changed_skips_unchanged()
    test_register_if_changed_writes_on_change()
    test_register_if_changed_writes_when_absent()
    print("== idempotent-skip ALL GATES PASSED ==")
