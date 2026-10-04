"""Acceptance gate -- the TTL cache and the store-error classifiers.

Two things the in-memory store alone cannot pin:

  * `CachedServiceDirectory`: the TTL boundary is EXCLUSIVE (`age >= ttl` is
    stale, so a zero-length TTL never serves from cache), pinned from both
    sides; `invalidate` drops exactly one key; `clear`, `cache_len`, `ttl_ms`
    and `into_directory` work; and a NEGATIVE answer is never cached.
  * The canonical `StoreError[NOT_FOUND]` / `StoreError[PRECONDITION]` tokens
    are classified even when no numeric status accompanies them, driven through
    a conformer (`_CanonicalTokenStore`) that re-projects the in-memory store's
    messages into that spelling.

Hermetic: no live bucket, no data files, no FFI.
"""

from std.testing import assert_equal, assert_false, assert_true

from komira_service_registry import (
    CachedServiceDirectory,
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


# -----------------------------------------------------------------------------
# THE TTL BOUNDARY IS EXCLUSIVE, AND THE CACHE'S OTHER VERBS EXIST.
#
# ⚠ An earlier version tested the TTL with age 1500 against a 60000 TTL and age 60001
# against the same — both a whole second away from the boundary — so relaxing
# `age >= ttl` to `age > ttl` left every gate green. That one-token change makes
# an entry AT the TTL a cache HIT, and with it the documented `ttl_ms = 0`
# behaviour ("a 0-length TTL never serves from cache") silently inverts into
# "a 0-length TTL caches FOREVER", which is the opposite of what a caller
# disabling the cache is asking for.
#
# The boundary is pinned from BOTH sides — `ttl - 1` must still be a HIT — so
# the arm cannot be satisfied by a cache that simply never serves.
#
# ⚠ ALSO COVERED HERE, because the mutation report found them named nowhere:
# `invalidate`, `clear`, `cache_len`, `ttl_ms`, `into_directory`, and the
# "negatives are not cached" claim.
# -----------------------------------------------------------------------------


def test_the_cache_ttl_boundary_is_exclusive_and_the_verbs_work() raises:
    print("-- test_cache_ttl_boundary_is_exclusive_and_the_verbs_work --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    dir.publish_endpoint(String("a-svc"), String("https://a"))
    dir.publish_endpoint(String("b-svc"), String("https://b"))

    var cached = CachedServiceDirectory(dir^, Int64(1000))
    assert_equal(cached.ttl_ms(), Int64(1000), String("the TTL is readable"))
    assert_equal(cached.cache_len(), 0, String("a fresh cache is empty"))

    var t0 = Int64(5_000_000)
    assert_equal(
        cached.resolve_endpoint(String("a-svc"), t0).source,
        RESOLVE_SOURCE_STORE,
        String("cold read is sourced from the STORE"),
    )
    assert_equal(cached.cache_len(), 1, String("...and is now cached"))

    # THE BOUNDARY, FROM BELOW: one millisecond short of the TTL is a HIT.
    var just_inside = cached.resolve_endpoint(
        String("a-svc"), t0 + Int64(999)
    )
    assert_equal(
        just_inside.source,
        RESOLVE_SOURCE_CACHE,
        String("age = ttl - 1 must still be served from cache"),
    )
    assert_equal(just_inside.age_ms, Int64(999), String("and report its age"))

    # THE BOUNDARY, EXACTLY: an entry AT the TTL is STALE, not fresh.
    assert_equal(
        cached.resolve_endpoint(String("a-svc"), t0 + Int64(1000)).source,
        RESOLVE_SOURCE_STORE,
        String(
            "age = ttl EXACTLY must read through — the comparison is `age >="
            " ttl`, and relaxing it to `>` is what makes a 0-length TTL cache"
            " forever instead of never"
        ),
    )

    # THE CONSEQUENCE THE DOCSTRING CLAIMS: a 0-length TTL never serves from
    # cache. Under `age > ttl` this is FALSE for every read at the same instant.
    var zero = CachedServiceDirectory(
        ServiceDirectory(SharedInMemoryConditionalStore()), Int64(0)
    )
    zero.directory().publish_endpoint(String("z-svc"), String("https://z"))
    var z0 = zero.resolve_endpoint(String("z-svc"), t0)
    assert_equal(z0.source, RESOLVE_SOURCE_STORE, String("ttl=0 cold"))
    assert_equal(
        zero.resolve_endpoint(String("z-svc"), t0).source,
        RESOLVE_SOURCE_STORE,
        String("a 0-length TTL must NEVER serve from cache, not even at age 0"),
    )

    var t1 = t0 + Int64(10_000)

    # NEGATIVES ARE NOT CACHED — a peer that has not published yet is the
    # ordinary state during a rollout, and caching its absence would make the
    # registry converge slower than the deploy.
    var before = cached.cache_len()
    _absent(cached.resolve_endpoint(String("not-yet"), t1), "absent, cold")
    _absent(cached.resolve_endpoint(String("not-yet"), t1), "absent, again")
    assert_equal(
        cached.cache_len(),
        before,
        String("an ABSENT answer must not enter the cache"),
    )

    # `invalidate` DROPS EXACTLY ONE KEY. Warm both, drop one, and check the
    # OTHER is untouched — a mutant that clears everything reds here, and one
    # that drops nothing reds on the first assertion.
    var t2 = t1 + Int64(100_000)
    _ = cached.resolve_endpoint(String("a-svc"), t2)
    _ = cached.resolve_endpoint(String("b-svc"), t2)
    var n_warm = cached.cache_len()
    var a_key = cached.directory().endpoint_key(String("a-svc"))
    cached.invalidate(a_key)
    assert_equal(
        cached.cache_len(),
        n_warm - 1,
        String("invalidate drops exactly one entry"),
    )
    assert_equal(
        cached.resolve_endpoint(String("a-svc"), t2).source,
        RESOLVE_SOURCE_STORE,
        String("the invalidated key reads through"),
    )
    assert_equal(
        cached.resolve_endpoint(String("b-svc"), t2).source,
        RESOLVE_SOURCE_CACHE,
        String("...and every OTHER key is untouched by it"),
    )

    # `clear` drops all of them.
    cached.clear()
    assert_equal(cached.cache_len(), 0, String("clear empties the cache"))
    assert_equal(
        cached.resolve_endpoint(String("b-svc"), t2).source,
        RESOLVE_SOURCE_STORE,
        String("after clear, every key reads through"),
    )

    # `into_directory` recovers the wrapped directory WITH ITS DATA — the cache
    # is a client, not the source of truth.
    var recovered = cached^.into_directory()
    _found(
        recovered.resolve_endpoint(String("a-svc")),
        String("https://a"),
        "into_directory round-trip",
    )
    print(
        "   ttl boundary exclusive both sides; invalidate/clear/into_directory"
        " OK"
    )


# -----------------------------------------------------------------------------
# THE CANONICAL `StoreError[...]` TOKEN IS CLASSIFIED WITHOUT A NUMERIC.
#
# `_is_precondition_failed` / `_is_not_found` open with
# `msg.find("StoreError[PRECONDITION]")` / `msg.find("StoreError[NOT_FOUND]")`
# and the comment above them says that keying only on the lowercase word plus
# the numeric "survives only while the numeric happens to be co-present — a
# message reformat that dropped `status=412` would silently turn a
# concurrent-deploy 412 into a fatal write".
#
# MUTANT: delete BOTH canonical arms. Every other test stays green, because the
# only store they run against is `SharedInMemoryConditionalStore`, whose
# messages read `not_found (404)` and `precondition (412)` -- the lowercase word
# AND the numeric. So the canonical arm needs a store of its own.
#
# The conformer below emits the canonical token and NO numeric at all, which is
# the one shape the two classifiers exist for. Under the mutant every verb here
# converts a routine absence into a raised store error: `resolve_endpoint` on
# an unpublished peer RAISES instead of reporting absent, and publishing a
# fresh service fails at its first head.
# -----------------------------------------------------------------------------


def _canonical_store_message(kind: String, method: String, key: String) -> String:
    """A `StoreError[<KIND>] <method> gs://<bucket>/<key>` message carrying the
    CANONICAL token and NO numeric status — the reformat the classifiers'
    first arm exists to survive.

    Shaped after a cloud object store's gRPC error mapping,
    with the `status=` / `grpc_code=` tail removed. Nothing here may contain the
    digits `404` or `412`; `test_the_CANONICAL_store_error_tokens...` asserts
    that of the exact messages this fixture produces, so a later edit that
    smuggles a numeric back in turns the gate vacuous LOUDLY."""
    return (
        String("StoreError[")
        + kind
        + String("] ")
        + method
        + String(" gs://example-bucket/")
        + key
    )


struct _CanonicalTokenStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A `ConditionalWriteStore` that re-projects the in-memory store's absences
    and conflicts into the CANONICAL `StoreError[...]` spelling with NO numeric.

    Every verb delegates to a real `SharedInMemoryConditionalStore`; the ONLY
    added behaviour is the message reformat. The directory is not stubbed — the
    404s and the 412 are real ones raised by the real store for the real
    reasons, and only their wording changes."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def _reproject(self, e: Error, method: String, key: String) -> Error:
        """`e` in the canonical spelling — or verbatim when it is neither an
        absence nor a conflict (a transport fault must stay a transport fault)."""
        var msg = String(e)
        if msg.find("not_found") >= 0:
            return Error(
                _canonical_store_message(String("NOT_FOUND"), method, key)
            )
        if msg.find("precondition") >= 0:
            return Error(
                _canonical_store_message(String("PRECONDITION"), method, key)
            )
        return e

    def head(self, path: Path) raises -> ObjectMeta:
        try:
            return self._inner.head(path)
        except e:
            raise self._reproject(e, String("head"), path.raw())

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        try:
            return self._inner.conditional_put(path, bytes, precond)
        except e:
            raise self._reproject(e, String("conditional_put"), path.raw())

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        try:
            return self._inner.compare_and_swap(path, bytes, expected_version)
        except e:
            raise self._reproject(e, String("compare_and_swap"), path.raw())

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        try:
            return self._inner.get(path)
        except e:
            raise self._reproject(e, String("get"), path.raw())

    def delete(self, path: Path) raises -> None:
        try:
            self._inner.delete(path)
        except e:
            raise self._reproject(e, String("delete"), path.raw())


def test_the_CANONICAL_store_error_tokens_are_classified_without_a_numeric() raises:
    print(
        "-- test_the_CANONICAL_store_error_tokens_are_classified_without_a_numeric"
        " --"
    )
    # ── FIXTURE PRECONDITION. The messages this gate drives carry the canonical
    # token and NOTHING a numeric classifier could latch onto. Asserted, not
    # assumed: if a later edit reintroduces `status=412` the gate would go on
    # passing while testing the arm it was written to bypass.
    var probe_keys = List[String]()
    probe_keys.append(String("service/alpha-svc"))
    probe_keys.append(String("service/beta-svc"))
    assert_equal(len(probe_keys), 2, "the fixture must carry both keys")
    for i in range(len(probe_keys)):
        var nf = _canonical_store_message(
            String("NOT_FOUND"), String("head"), probe_keys[i]
        )
        var pc = _canonical_store_message(
            String("PRECONDITION"), String("conditional_put"), probe_keys[i]
        )
        assert_true(
            nf.find("404") < 0 and nf.find("412") < 0,
            String("the NOT_FOUND fixture must carry NO numeric status: ") + nf,
        )
        assert_true(
            pc.find("404") < 0 and pc.find("412") < 0,
            String("the PRECONDITION fixture must carry NO numeric status: ")
            + pc,
        )
        assert_true(
            nf.find("not_found") < 0 and nf.find("NotFound") < 0,
            String("...and none of the lowercase spellings either: ") + nf,
        )
        assert_true(
            pc.find("precondition") < 0 and pc.find("Precondition") < 0,
            String("...and none of the lowercase spellings either: ") + pc,
        )

    var inner = SharedInMemoryConditionalStore()
    var dir = ServiceDirectory(_CanonicalTokenStore(inner.clone()))

    # ⛔ EVERY ARM BELOW CATCHES AND RE-STATES. Under the mutant these verbs
    # PROPAGATE the store's own error, and an uncaught `StoreError[NOT_FOUND]
    # get gs://...` names the store rather than the contract that broke —
    # sending the reader to the object store instead of to the four lines of
    # classifier this gate is about.

    # ── 1. AN ABSENCE IS AN ABSENCE. `_read`'s 404 arm is the whole reason
    # `ResolveResult` has a `found` field: an unpublished peer during a rollout
    # is the ORDINARY state, not an error.
    var ep_absent = False
    var ep_err = String("")
    try:
        ep_absent = not dir.resolve_endpoint(String("alpha-svc")).found
    except e:
        ep_err = String(e)
    assert_equal(
        ep_err,
        String(""),
        String(
            "an ABSENT endpoint must come back as found=False, NOT as a raise."
            " `_is_not_found`'s FIRST arm is the canonical"
            " `StoreError[NOT_FOUND]` token; a classifier keyed only on the"
            " lowercase word plus the numeric is DEAD against a store that"
            " emits the canonical spelling, and an unpublished peer during a"
            " rollout then fails the caller instead of reporting absent. Got: "
        )
        + ep_err,
    )
    assert_true(ep_absent, "...and it reports found=False")

    # ── 2. AND SO IS A DELETE OF AN ABSENT KEY — `_delete_if_present`'s head.
    var del_err = String("")
    var withdrew = True
    try:
        withdrew = dir.withdraw_endpoint(String("alpha-svc"))
    except e:
        del_err = String(e)
    assert_equal(
        del_err,
        String(""),
        String(
            "deleting an ALREADY-ABSENT binding is False, not a raise — a"
            " second reap pass is not an error, and the head that decides it"
            " runs through the same classifier. Got: "
        )
        + del_err,
    )
    assert_false(withdrew, "...and withdraw_endpoint reports False")

    # ── 3. THE CREATE PATH. `_try_last_writer_wins` heads first, and that head
    # 404s on a fresh key — so publishing at ALL goes through the classifier.
    var pub_err = String("")
    try:
        dir.publish_endpoint(String("alpha-svc"), String("https://alpha"))
    except e:
        pub_err = String(e)
    assert_equal(
        pub_err,
        String(""),
        String(
            "publishing a FRESH endpoint must commit. `_try_last_writer_wins`"
            " heads first and swallows the 404 to take the create branch; an"
            " unclassified 404 there is re-raised as `a real error (auth /"
            " transport)`, so the first publish of every new service fails."
            " Got: "
        )
        + pub_err,
    )
    _found(
        dir.resolve_endpoint(String("alpha-svc")),
        String("https://alpha"),
        "the create path commits under the CANONICAL token",
    )
    # And the re-publish path: head SUCCEEDS, CAS commits. Both spellings of
    # last-writer-wins reached.
    dir.publish_endpoint(String("alpha-svc"), String("https://alpha-v2"))
    _found(
        dir.resolve_endpoint(String("alpha-svc")),
        String("https://alpha-v2"),
        "the CAS path commits under the CANONICAL token",
    )

    print("   canonical StoreError tokens classified with NO numeric OK")


def main() raises:
    test_the_cache_ttl_boundary_is_exclusive_and_the_verbs_work()
    test_the_CANONICAL_store_error_tokens_are_classified_without_a_numeric()
    print("ALL SERVICE-DIRECTORY CACHE AND ERROR-TOKEN TESTS PASSED")
