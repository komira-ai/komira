"""Acceptance gate — the SERVICE REGISTRY record + store contract.

The registry has TWO GENERIC JOBS and this file is the falsifier for both of
them being served by ONE store with the RIGHT write policy on each:

  * DISCOVERY  — `name -> endpoint`.  A URL changes on every redeploy, so
                 LAST-WRITER-WINS is correct: the newest deploy's URL is the
                 one peers should reach.
  * ENROLLMENT — `platform identity -> service`.  Last-writer-wins here means
                 the most recent writer decides who a service IS.  So this is
                 CREATE-OR-CONFLICT: a 412 from a DIFFERENT claimant is a
                 REFUSAL, never a retry.

Gates:

  1. TWO JOBS, ONE STORE:  enroll an identity and publish an endpoint through
     one `ServiceDirectory` over one store; resolve identity -> service AND
     name -> endpoint back out of it.
  2. THE REFUSAL:  a SECOND writer claiming an ALREADY-ENROLLED identity for a
     DIFFERENT service RAISES, names both services, and leaves the binding
     UNCHANGED.  (Last-writer-wins would have silently rebound it.)
  3. IDEMPOTENT RE-ENROLL:  the SAME service re-claiming its OWN identity is
     accepted and is a no-op — a redeploy re-running enrollment must not fail.
  4. CARDINALITY IS NOT 1:1:  one logical service holds a GCP identity AND an
     AWS one; both resolve to it.  And an identity maps to exactly ONE service
     STRUCTURALLY — the enrollment object is KEYED BY THE IDENTITY, so two
     services claiming one identity COLLIDE on one key rather than coexisting
     at two.
  5. LAST-WRITER-WINS ON THE ENDPOINT:  a redeploy overwrites the URL.
  6. PROVENANCE:  `ResolveResult` distinguishes a fresh store read (source
     STORE, age 0) from a cache hit (source CACHE, real age), and an absent key
     still reports that the STORE was consulted.  The registry trades
     deploy-time validation for runtime lookup, so this distinction is the
     diagnosis story.
  7. DELETE:  `withdraw_endpoint` / `revoke_identity` remove the binding;
     deleting an absent one returns False rather than raising; and revoking is
     the ONLY way to re-bind an identity (the deliberate consequence of (2)).
  8. THE KEY COMPOSITION IS UNCHANGED:  the endpoint object is `service/<name>`
     holding the BARE URL BYTES — byte-for-byte what
     `komira_svcref.ServiceRegistry` writes — so this contract is a
     drop-in for it and switching is a code swap, not a data migration.
  9. FINGERPRINT INJECTIVITY:  the identity -> key-segment escape round-trips
     and never collides, over principals carrying `/`, `:`, `@` and `_`.

⛔ GATES 1-9 ALL SURVIVED FIVE ONE-TOKEN MUTANTS. Each of the six gates below
was added by APPLYING a specific mutant, watching gates 1-9 stay GREEN, and
keeping only an assertion that then went RED. They are not extra coverage — they
are the arms that make the file discriminate, and each names the mutant it kills
so nobody re-relaxes the line it guards:

  2b. IDENTITY OWNERSHIP IS EQUALITY, NOT CONTAINMENT.  `incumbent.value ==
      service_name` relaxed to `.find(...) >= 0` (either direction) passed all
      of 1-9, because none of them picks two service names with a substring
      relation — while regional names are commonly BUILT from one
      (`<service>-<cloud>-<region>`), so `scheduler` would be silently
      ACCEPTED onto `scheduler-gcp-us-central1`'s identity.
  2c. THE CONCURRENTLY-REVOKED ARM IS REACHABLE AND IS A REFUSAL.  Reached by
      substituting the `Store` type-param for a conformer that revokes inside
      the 412 window; the falsifying assertion is that NOTHING WAS WRITTEN.
  5b. `publish_endpoint_if_changed` WRITES IFF THE URL CHANGED.  Named ZERO
      times by gates 1-9; inverted to never republish, all of them stayed green
      while a redeploy kept the STALE url.  Asserted on the STORE's bytes and
      on its OP COUNTERS, not on the return value.
  6b. THE TTL BOUNDARY IS EXCLUSIVE (`age >= ttl`), pinned from BOTH sides —
      plus `invalidate` / `clear` / `cache_len` / `ttl_ms` / `into_directory`,
      the cache's IDENTITY arm, and "negatives are not cached", none of which
      gates 1-9 named.
  9b. THE PLATFORM CHARSET IS WHAT MAKES THE SPLIT UNAMBIGUOUS.  Relaxing
      `validate_platform` to admit `.` and A-Z passed all of 1-9; under it
      `gcp.v2 / x` round-trips as platform `gcp`, principal `v2.x` — a
      FABRICATED identity, and `list_identities` is what the reap tooling reads.
  9c. A CORRUPT KEY IS A REFUSAL, NOT A PRINCIPAL.  `_nibble_value`'s raise
      turned into `return 0` passed all of 1-9, decoding `identity/gcp.a_ZZ`
      into a fabricated principal.  Plus the escape's two halves directly, the
      explicit collision pair (`a:` vs `a_3A`), and `into_store`.

⛔ AND GATES 2d / 2e / 5c WERE ADDED THE SAME WAY, against a
re-mutation of the file above.  Every one of 1-9 plus 2b/2c/5b/6b/9b/9c stayed
GREEN under each mutant below; each gate names its own and asserts on the STORE
or on the REFUSAL TEXT, never on the fact that something raised.

  2d. THE CANONICAL `StoreError[...]` TOKEN IS CLASSIFIED WITHOUT A NUMERIC.
      `_is_precondition_failed` / `_is_not_found` open with the canonical
      uppercase token and the comment above them calls that arm
      load-bearing.  DELETE BOTH CANONICAL ARMS and every
      gate stayed green — because the ONLY store any of them runs against emits
      `not_found (404)` / `precondition (412)`, the lowercase word AND the
      numeric, so the canonical arm was exercised by nothing.  The file's most
      emphatic warning was guarded by nothing.  Closed with a conformer
      (`_CanonicalTokenStore`) that emits the canonical token and NO numeric.
  2e. `describe()` OWNERSHIP IS EQUALITY, NOT CONTAINMENT — byte-for-byte the
      2b defect, one method away, on a line 2b never reached.  Closed with two
      registered names in a REALISTIC substring relation (`scheduler` /
      `scheduler-gcp-us-central1`), asserting each record's identity COUNT.
  5c. THE RETRY-ONCE ON THE ENDPOINT CAS, AND THE RAISE BEHIND IT.  Deleting
      the second `_try_last_writer_wins`, and replacing the trailing raise with
      a bare `return`, BOTH passed everything — nothing above ever contends the
      discovery keyspace.  The second is the worse one: `publish_endpoint`
      reports success having written nothing.

⚠ AND ONE THAT WAS *NOT* A SURVIVING MUTANT, recorded because the distinction
is worth more than the fix: adding `_` to `identity._is_literal`'s pass-through
set was CAUGHT — but at the first round-trip probe loop, on an uncaught
`truncated escape` raised out of the DECODER, for a defect in the ENCODER.  The
collision pair moved to `_assert_the_escape_marker_is_ITSELF_escaped`, called
BEFORE that loop.  A diagnosis fix, not a closed hole.

Hermetic: `SharedInMemoryConditionalStore` plus THREE in-file conformers
(`_RevokeOnConflictStore` gate 2c, `_CanonicalTokenStore` gate 2d,
`_EndpointCasConflictStore` gate 5c) — no live bucket, no data files, no FFI.
"""

from std.testing import assert_equal, assert_false, assert_true

from komira_service_registry import (
    CachedServiceDirectory,
    ENDPOINT_PREFIX,
    IDENTITY_PREFIX,
    PlatformIdentity,
    RESOLVE_SOURCE_CACHE,
    RESOLVE_SOURCE_STORE,
    ResolveResult,
    ServiceDirectory,
    ServiceRecord,
    escape_principal,
    identity_fingerprint,
    identity_from_fingerprint,
    unescape_principal,
    validate_platform,
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


def _gcp(principal: String) -> PlatformIdentity:
    return PlatformIdentity(String("gcp"), principal)


def _aws(principal: String) -> PlatformIdentity:
    return PlatformIdentity(String("aws"), principal)


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


def _render_names(names: List[String]) -> String:
    """`[a, b]` — so a count assertion's failure text says WHAT it got, not only
    how many. A count that reds without naming its members sends the reader back
    to the fixture to guess which one leaked in."""
    var out = String("[")
    for i in range(len(names)):
        if i > 0:
            out += String(", ")
        out += names[i]
    out += String("]")
    return out^


# -----------------------------------------------------------------------------
# Gate 1 — the two jobs, from ONE store.
# -----------------------------------------------------------------------------


def test_one_store_serves_both_jobs() raises:
    print("-- test_one_store_serves_both_jobs --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())

    # Job A: discovery.
    dir.publish_endpoint(
        String("orders-api"), String("https://api.example:8088")
    )
    # Job B: enrollment — the checkable claim.
    var id = _gcp(String("orders-api@proj.iam.gserviceaccount.com"))
    dir.enroll_identity(id, String("orders-api"))

    _found(
        dir.resolve_endpoint(String("orders-api")),
        String("https://api.example:8088"),
        "name -> endpoint",
    )
    _found(
        dir.resolve_identity(id), String("orders-api"), "identity -> service"
    )
    print("   identity -> service AND name -> endpoint from ONE store OK")


# -----------------------------------------------------------------------------
# Gate 2 — THE REFUSAL. This is the crux of the registry.
# -----------------------------------------------------------------------------


def test_a_second_claimant_of_an_enrolled_identity_is_refused() raises:
    print("-- test_a_second_claimant_of_an_enrolled_identity_is_refused --")
    var store = SharedInMemoryConditionalStore()
    var honest = ServiceDirectory(store.clone())
    var attacker = ServiceDirectory(store.clone())

    var id = _gcp(String("jm@proj.iam.gserviceaccount.com"))
    honest.enroll_identity(id, String("scheduler-gcp-us-central1"))

    var refused = False
    var msg = String("")
    try:
        attacker.enroll_identity(id, String("report-builder"))
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        String(
            "a SECOND service claiming an enrolled identity must be REFUSED;"
            " last-writer-wins here lets the most recent writer decide who a"
            " service IS"
        ),
    )
    # The refusal must name BOTH services — the operator has to be able to tell
    # which claim was rejected and which one holds the binding.
    assert_true(
        msg.find("scheduler-gcp-us-central1") >= 0,
        String("refusal must name the INCUMBENT service, got: ") + msg,
    )
    assert_true(
        msg.find("report-builder") >= 0,
        String("refusal must name the REJECTED claimant, got: ") + msg,
    )
    # And the binding is UNCHANGED.
    _found(
        honest.resolve_identity(id),
        String("scheduler-gcp-us-central1"),
        "binding after a refused second claim",
    )
    print(
        "   second claimant REFUSED, binding unchanged, both names named OK"
    )


# -----------------------------------------------------------------------------
# Gate 3 — idempotent re-enroll by the SAME service.
# -----------------------------------------------------------------------------


def test_reenrolling_the_same_service_is_a_noop() raises:
    print("-- test_reenrolling_the_same_service_is_a_noop --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    var id = _aws(
        String("arn:aws:iam::111122223333:role/scheduler-aws-us-east-1")
    )
    dir.enroll_identity(id, String("scheduler-aws-us-east-1"))
    # A redeploy re-runs enrollment with the identical claim. Must NOT raise.
    dir.enroll_identity(id, String("scheduler-aws-us-east-1"))
    _found(
        dir.resolve_identity(id),
        String("scheduler-aws-us-east-1"),
        "idempotent re-enroll",
    )
    print("   same-service re-enroll accepted as a no-op OK")


# -----------------------------------------------------------------------------
# Gate 4 — cardinality: many identities -> one service; one identity -> one
# service STRUCTURALLY (they collide on one key).
# -----------------------------------------------------------------------------


def test_one_service_may_hold_identities_on_two_clouds() raises:
    print("-- test_one_service_may_hold_identities_on_two_clouds --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    var g = _gcp(String("relay@proj.iam.gserviceaccount.com"))
    var a = _aws(String("arn:aws:iam::111122223333:role/relay"))
    dir.enroll_identity(g, String("edge-session-relay"))
    dir.enroll_identity(a, String("edge-session-relay"))
    _found(dir.resolve_identity(g), String("edge-session-relay"), "gcp arm")
    _found(dir.resolve_identity(a), String("edge-session-relay"), "aws arm")

    dir.publish_endpoint(
        String("edge-session-relay"), String("https://relay.example")
    )
    var rec = dir.describe(String("edge-session-relay"))
    assert_equal(rec.name, String("edge-session-relay"))
    assert_true(rec.endpoint.__bool__(), String("describe carries the endpoint"))
    assert_equal(
        len(rec.identities),
        2,
        String("describe must carry BOTH identity bindings"),
    )
    print("   one service, two platform identities, joined by describe() OK")


def test_two_services_claiming_one_identity_collide_on_one_key() raises:
    print("-- test_two_services_claiming_one_identity_collide_on_one_key --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    var id = _gcp(String("shared@proj.iam.gserviceaccount.com"))
    # THE STRUCTURAL PROPERTY: the enrollment object is keyed by the IDENTITY,
    # not by the service, so two services' claims target the SAME object. Were
    # it keyed by service, the two claims would land at two keys and coexist —
    # and detecting the double-claim would need a scan, which is a race.
    var k1 = dir.identity_key(id)
    dir.enroll_identity(id, String("service-a"))
    var k2 = dir.identity_key(id)
    assert_equal(
        k1, k2, String("the identity key must be a function of the identity")
    )
    assert_true(
        k1.find(String(IDENTITY_PREFIX)) == 0,
        String("enrollment lives under the identity prefix, got: ") + k1,
    )
    var raised = False
    try:
        dir.enroll_identity(id, String("service-b"))
    except:
        raised = True
    assert_true(raised, String("the collision must be a refusal"))
    print("   two claimants collide on ONE key OK")


# -----------------------------------------------------------------------------
# Gate 5 — last-writer-wins on the endpoint (the OPPOSITE policy).
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
# Gate 6 — PROVENANCE.
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
# Gate 7 — DELETE.
# -----------------------------------------------------------------------------


def test_delete_verbs() raises:
    print("-- test_delete_verbs --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    var id = _gcp(String("reapme@proj.iam.gserviceaccount.com"))
    dir.publish_endpoint(String("orphan"), String("https://orphan"))
    dir.enroll_identity(id, String("orphan"))

    assert_true(
        dir.withdraw_endpoint(String("orphan")),
        String("withdrawing a present endpoint returns True"),
    )
    _absent(dir.resolve_endpoint(String("orphan")), "after withdraw")
    assert_false(
        dir.withdraw_endpoint(String("orphan")),
        String("withdrawing an ABSENT endpoint is False, not a raise"),
    )

    assert_true(
        dir.revoke_identity(id), String("revoking a present binding is True")
    )
    _absent(dir.resolve_identity(id), "after revoke")
    assert_false(
        dir.revoke_identity(id),
        String("revoking an ABSENT binding is False, not a raise"),
    )

    # Revocation is the ONLY way to re-bind an identity — the deliberate
    # consequence of create-or-conflict, and what the reap tooling binds to.
    dir.enroll_identity(id, String("the-new-owner"))
    _found(
        dir.resolve_identity(id),
        String("the-new-owner"),
        "re-bind after revoke",
    )
    print("   withdraw / revoke, idempotent-absent, re-bind-after-revoke OK")


# -----------------------------------------------------------------------------
# Gate 8 — the key composition and the stored bytes are UNCHANGED.
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
    dir.publish_endpoint(String("a-svc"), String("https://a"))
    dir.publish_endpoint(String("b-svc"), String("https://b"))
    dir.enroll_identity(
        _gcp(String("a@p.iam.gserviceaccount.com")), String("a-svc")
    )
    dir.enroll_identity(_aws(String("arn:aws:iam::1:role/b")), String("b-svc"))

    var eps = dir.list_endpoints()
    assert_equal(len(eps), 2, String("two endpoints"))
    assert_true(_has(eps, String("a-svc")), String("a-svc listed"))
    assert_true(_has(eps, String("b-svc")), String("b-svc listed"))

    var ids = dir.list_identities()
    assert_equal(len(ids), 2, String("two identities"))
    # Listing identities must recover the PRINCIPAL verbatim off the key — that
    # is what lets the reap tooling report an orphan by the name an operator typed.
    var saw_arn = False
    for i in range(len(ids)):
        if ids[i].principal == String("arn:aws:iam::1:role/b"):
            saw_arn = True
            assert_equal(ids[i].platform, String("aws"))
    assert_true(saw_arn, String("the ARN must round-trip out of the key"))
    print("   list_endpoints / list_identities OK")


# -----------------------------------------------------------------------------
# Gate 9 — fingerprint injectivity.
# -----------------------------------------------------------------------------


def _assert_the_escape_marker_is_ITSELF_escaped() raises:
    """THE COLLISION PAIR — asserted BEFORE any round-trip loop runs.

    `_` is the escape marker, so a principal that already LOOKS like an escape
    must itself be escaped; otherwise `a:` and a literal `a_3A` land on ONE
    identity key. That is the one collision the enrollment refusal cannot
    detect, because there is nothing left to conflict with.

    ⛔ THE ORDER IS THE POINT, AND IT IS MEASURED. Apply the one-token mutant
    (add `_` to `identity._is_literal`'s pass-through set) and the suite goes
    RED — but at the FIRST round-trip probe loop, on an UNCAUGHT
    `malformed identity fingerprint — truncated escape at the end of 'a_b'`
    raised out of `unescape_principal`. That message names the DECODER, and the
    defect is in the ENCODER's literal set: the reader is sent to the half that
    behaved correctly. Both loops (this test's and
    `test_a_corrupt_fingerprint_is_refused_not_decoded`'s) carry an `a_b` probe,
    so BOTH die that way, and this test runs first.

    ⚠ SO THIS IS A DIAGNOSIS FIX, NOT A CLOSED HOLE — stated plainly because
    the two are worth different amounts. The mutant did NOT survive; it was
    caught, badly. Running it now reds HERE, on a message that names the
    merge."""
    assert_true(
        escape_principal(String("a:")) != escape_principal(String("a_3A")),
        String(
            "'a:' escapes to 'a_3A', so a literal 'a_3A' must escape to"
            " something else — letting '_' through unescaped merges two"
            " distinct principals onto one identity key"
        ),
    )
    assert_true(
        identity_fingerprint(_gcp(String("a:")))
        != identity_fingerprint(_gcp(String("a_3A"))),
        String("...and the same must hold of the fingerprints they key"),
    )


def test_identity_fingerprint_is_injective() raises:
    print("-- test_identity_fingerprint_is_injective --")
    # ⛔ FIRST, BEFORE THE PROBE LOOP. The loop's `a_b` probe raises out of
    # `unescape_principal` under the escape-marker mutant, and an uncaught
    # decoder error is a worse report than the collision it is a symptom of.
    _assert_the_escape_marker_is_ITSELF_escaped()
    var principals = List[String]()
    principals.append(String("jm@proj.iam.gserviceaccount.com"))
    principals.append(String("arn:aws:iam::111122223333:role/scheduler"))
    principals.append(String("a/b"))
    principals.append(String("a_b"))
    principals.append(String("a.b"))
    principals.append(String("A"))
    principals.append(String("a"))

    var seen = List[String]()
    for i in range(len(principals)):
        var id = PlatformIdentity(String("gcp"), principals[i])
        var fp = identity_fingerprint(id)
        # No `/` may survive the escape — it would split the object key.
        assert_true(
            fp.find("/") < 0,
            String("a fingerprint may not contain '/': ") + fp,
        )
        # Round-trip: the key is the identity, so it must be recoverable.
        var back = identity_from_fingerprint(fp)
        assert_equal(
            back.platform, String("gcp"), String("platform round-trip")
        )
        assert_equal(
            back.principal,
            principals[i],
            String("principal round-trip: ") + fp,
        )
        for j in range(len(seen)):
            assert_true(
                seen[j] != fp,
                String("fingerprint COLLISION on '")
                + principals[i]
                + String("'"),
            )
        seen.append(fp.copy())

    # The platform is part of the fingerprint: the same principal string on two
    # platforms is two identities, not one.
    assert_true(
        identity_fingerprint(_gcp(String("x")))
        != identity_fingerprint(_aws(String("x"))),
        String("the platform must be part of the identity"),
    )
    # An EMPTY principal is not an identity — it is a caller that has not
    # resolved its binding, and it must be refused rather than keyed.
    var empty_refused = False
    try:
        _ = identity_fingerprint(PlatformIdentity(String("gcp"), String("")))
    except:
        empty_refused = True
    assert_true(
        empty_refused, String("an empty principal must be REFUSED, not keyed")
    )
    print("   escape is injective, round-trips, and never emits '/' OK")



# -----------------------------------------------------------------------------
# Gate 2b — THE IDENTITY-OWNERSHIP COMPARISON IS EQUALITY, NOT CONTAINMENT.
#
# ⚠ THIS IS THE MUTANT THE ORIGINAL ELEVEN GATES ALL SURVIVED. `enroll_identity`
# decides ACCEPTED-AS-IDEMPOTENT vs REFUSED on ONE line — `incumbent.value ==
# service_name`. Relax it to `incumbent.value.find(service_name) >= 0` (or the
# other direction) and every one of gates 1-9 still passes, because each of them
# happens to pick two service names with NO substring relation.
#
# ⭐ REGIONAL SERVICE NAMES ARE BUILT FROM THAT PREFIX RELATION — a common
# regional form is `<service>-<cloud>-<region>`, so `scheduler` IS a prefix of
# `scheduler-gcp-us-central1` under that naming scheme. A containment test
# therefore hands `scheduler` a SILENT SUCCESS on an identity bound to
# `scheduler-gcp-us-central1`, and it then believes it is enrolled AS ITSELF —
# the exact "the most recent writer decides who a service IS" failure the
# create-or-conflict policy exists to deny, arriving with no error at all.
#
# Both directions are asserted, because the two one-token relaxations differ:
# `incumbent.find(claimant)` is caught only by the SHORTER claimant and
# `claimant.find(incumbent)` only by the LONGER one.
# -----------------------------------------------------------------------------


def _claim_must_be_refused(
    mut dir: ServiceDirectory[SharedInMemoryConditionalStore],
    id: PlatformIdentity,
    claimant: String,
    incumbent: String,
) raises:
    """Assert `claimant` is REFUSED against an identity already bound to
    `incumbent`, that the refusal names both, and that the binding survives."""
    var refused = False
    var msg = String("")
    try:
        dir.enroll_identity(id, claimant)
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        String("'")
        + claimant
        + String("' must be REFUSED against the binding held by '")
        + incumbent
        + String(
            "' — these are DIFFERENT services, and a substring relation"
            " between two service names is not identity"
        ),
    )
    assert_true(
        msg.find(incumbent) >= 0,
        String("refusal must name the INCUMBENT, got: ") + msg,
    )
    assert_true(
        msg.find(claimant) >= 0,
        String("refusal must name the REJECTED claimant, got: ") + msg,
    )
    _found(
        dir.resolve_identity(id),
        incumbent,
        String("binding after refusing '") + claimant + String("'"),
    )


def test_a_substring_related_service_name_is_still_a_different_service() raises:
    print("-- test_a_substring_related_service_name_is_a_different_service --")

    # (a) the CLAIMANT is a PREFIX of the incumbent — the realistic case, since
    #     the regional name is composed as `<service>-<cloud>-<region>`.
    var d1 = ServiceDirectory(SharedInMemoryConditionalStore())
    var id1 = _gcp(String("jm@proj.iam.gserviceaccount.com"))
    d1.enroll_identity(id1, String("scheduler-gcp-us-central1"))
    _claim_must_be_refused(
        d1,
        id1,
        String("scheduler"),
        String("scheduler-gcp-us-central1"),
    )

    # (b) the INCUMBENT is a prefix of the claimant — the same relaxation
    #     written the other way round.
    var d2 = ServiceDirectory(SharedInMemoryConditionalStore())
    var id2 = _gcp(String("jm2@proj.iam.gserviceaccount.com"))
    d2.enroll_identity(id2, String("scheduler"))
    _claim_must_be_refused(
        d2,
        id2,
        String("scheduler-gcp-us-central1"),
        String("scheduler"),
    )

    # (c) containment in the MIDDLE, not at either end — so the arm does not
    #     merely pin "prefix", it pins EQUALITY.
    var d3 = ServiceDirectory(SharedInMemoryConditionalStore())
    var id3 = _aws(String("arn:aws:iam::1:role/relay"))
    d3.enroll_identity(id3, String("edge-session-relay-aws-us-east-1"))
    _claim_must_be_refused(
        d3,
        id3,
        String("session-relay"),
        String("edge-session-relay-aws-us-east-1"),
    )

    # And the accepting arm still accepts: EXACT equality is idempotent.
    d3.enroll_identity(id3, String("edge-session-relay-aws-us-east-1"))
    _found(
        d3.resolve_identity(id3),
        String("edge-session-relay-aws-us-east-1"),
        "exact re-claim is still accepted",
    )
    print(
        "   prefix / suffix / infix claimants REFUSED; only EQUALITY is"
        " idempotent OK"
    )



# -----------------------------------------------------------------------------
# Gate 9b — THE PLATFORM TOKEN'S CHARACTER SET IS LOAD-BEARING, AND WHAT IT
# PROTECTS IS THE FINGERPRINT SPLIT.
#
# ⚠ NOTHING TESTED THIS. `identity.mojo`'s header calls the `.` exclusion the
# reason `identity_from_fingerprint`'s split at the FIRST `.` is unambiguous,
# and calls the lowercase restriction the reason `GCP` and `gcp` are not two
# platforms — and the eleven original gates only ever passed `gcp` / `aws`, so
# `validate_platform` could be relaxed to accept `.` and A-Z with every one of
# them still green.
#
# WHAT THE RELAXATION COSTS IS A FABRICATED IDENTITY, not a cosmetic laxity.
# `gcp.v2 / x` fingerprints to `gcp.v2.x`; the split at the first `.` then reads
# that back as platform `gcp`, principal `v2.x` — a DIFFERENT identity from the
# one enrolled, recovered from the key with no error anywhere. `list_identities`
# is what the reap tooling binds to, so the fabrication is what an operator would
# be shown and what a reaper would act on.
#
# So the arm is written as a PROPERTY over both directions rather than as a
# character list: for every token, EITHER the fingerprint is refused OR it
# round-trips EXACTLY in both fields. A relaxation cannot satisfy both.
# -----------------------------------------------------------------------------


def _refused_platform(platform: String, why: String) raises:
    """`platform` must be REFUSED by BOTH the direct validator and the
    fingerprint that depends on it. Checking only one leaves the other free to
    drift — and it is `identity_fingerprint` the store path calls."""
    var v_refused = False
    try:
        validate_platform(platform)
    except:
        v_refused = True
    assert_true(
        v_refused,
        String("validate_platform must REFUSE '") + platform + String("' — ") + why,
    )
    var f_refused = False
    try:
        _ = identity_fingerprint(PlatformIdentity(platform, String("x")))
    except:
        f_refused = True
    assert_true(
        f_refused,
        String("identity_fingerprint must REFUSE platform '")
        + platform
        + String("' — ")
        + why,
    )


def _accepted_platform_round_trips(platform: String) raises:
    """An ACCEPTED platform must round-trip EXACTLY — both fields. This is the
    half that makes the refusals above load-bearing rather than decorative."""
    validate_platform(platform)
    var fp = identity_fingerprint(
        PlatformIdentity(platform, String("arn:aws:iam::1:role/x"))
    )
    var back = identity_from_fingerprint(fp)
    assert_equal(
        back.platform,
        platform,
        String("platform must round-trip VERBATIM out of ") + fp,
    )
    assert_equal(
        back.principal,
        String("arn:aws:iam::1:role/x"),
        String("principal must round-trip VERBATIM out of ") + fp,
    )


def test_the_platform_token_charset_is_what_makes_the_split_unambiguous() raises:
    print("-- test_platform_token_charset_makes_the_split_unambiguous --")

    # THE `.` — the separator itself. Admitting it is what fabricates an
    # identity: `gcp.v2` + `x` would read back as `gcp` + `v2.x`.
    _refused_platform(
        String("gcp.v2"),
        String(
            "'.' separates the platform from the principal, so a platform"
            " carrying one makes the split at the FIRST '.' recover a"
            " DIFFERENT identity than the one enrolled"
        ),
    )
    # UPPERCASE — `GCP` and `gcp` would otherwise be two platforms, i.e. two
    # keys, i.e. one principal enrolled twice with neither claim colliding.
    _refused_platform(
        String("GCP"),
        String("'GCP' and 'gcp' must not be two platforms"),
    )
    _refused_platform(
        String("Gcp"),
        String("case is not folded, so a mixed-case token must be refused"),
    )
    # The rest of what is not `[a-z0-9-]`.
    _refused_platform(String(""), String("an empty token is not a platform"))
    _refused_platform(
        String("gcp_v2"), String("'_' is the escape marker in the other half")
    )
    _refused_platform(
        String("gcp/v2"), String("'/' would split the object key")
    )
    _refused_platform(String("gcp v2"), String("a space is not key-safe"))

    # THE FABRICATION, stated end to end at the ONE surface that matters: no
    # fabricated binding may reach the store, because `list_identities` is what
    # the reap tooling reads and it recovers the identity FROM THE KEY.
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    var raised = False
    try:
        dir.enroll_identity(
            PlatformIdentity(String("gcp.v2"), String("x")), String("svc")
        )
    except:
        raised = True
    assert_true(
        raised,
        String(
            "enrolling under a '.'-carrying platform must be REFUSED at the"
            " key composition — otherwise list_identities reports an identity"
            " that was never enrolled"
        ),
    )
    assert_equal(
        len(dir.list_identities()),
        0,
        String("a refused enrollment must leave NO binding behind"),
    )

    # And every token that IS accepted round-trips exactly — including one that
    # is only digits and one carrying the permitted '-'.
    _accepted_platform_round_trips(String("gcp"))
    _accepted_platform_round_trips(String("aws"))
    _accepted_platform_round_trips(String("kubernetes"))
    _accepted_platform_round_trips(String("k8s-dev-2"))
    _accepted_platform_round_trips(String("0"))
    print("   '.'/uppercase REFUSED, accepted tokens round-trip exactly OK")



# -----------------------------------------------------------------------------
# Gate 5b — `publish_endpoint_if_changed` IS A REAL PUBLISHER, NOT A NO-OP.
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
# Gate 6b — THE TTL BOUNDARY IS EXCLUSIVE, AND THE CACHE'S OTHER VERBS EXIST.
#
# ⚠ Gate 6 tested the TTL with age 1500 against a 60000 TTL and age 60001
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
# `invalidate`, `clear`, `cache_len`, `ttl_ms`, `into_directory`, the IDENTITY
# arm of the cache, and the "negatives are not cached" claim.
# -----------------------------------------------------------------------------


def test_the_cache_ttl_boundary_is_exclusive_and_the_verbs_work() raises:
    print("-- test_cache_ttl_boundary_is_exclusive_and_the_verbs_work --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())
    dir.publish_endpoint(String("a-svc"), String("https://a"))
    dir.publish_endpoint(String("b-svc"), String("https://b"))
    var id = _gcp(String("a@proj.iam.gserviceaccount.com"))
    dir.enroll_identity(id, String("a-svc"))

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

    # THE IDENTITY ARM OF THE CACHE — untested until now, and a different key
    # composition from the endpoint arm.
    var t1 = t0 + Int64(10_000)
    assert_equal(
        cached.resolve_identity(id, t1).source,
        RESOLVE_SOURCE_STORE,
        String("cold identity read is from the STORE"),
    )
    var id_hit = cached.resolve_identity(id, t1 + Int64(500))
    assert_equal(
        id_hit.source,
        RESOLVE_SOURCE_CACHE,
        String("a warm identity read is served from cache"),
    )
    _found(id_hit, String("a-svc"), "cached identity -> service")
    assert_equal(
        cached.resolve_identity(id, t1 + Int64(1000)).source,
        RESOLVE_SOURCE_STORE,
        String("the identity arm honours the SAME exclusive boundary"),
    )

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
    _found(
        recovered.resolve_identity(id),
        String("a-svc"),
        "into_directory keeps the enrollment too",
    )
    print(
        "   ttl boundary exclusive both sides; invalidate/clear/into_directory"
        " OK"
    )



# -----------------------------------------------------------------------------
# Gate 2c — THE CONCURRENTLY-REVOKED ARM. It is REACHABLE, and it is a REFUSAL.
#
# `enroll_identity` has a third outcome the other gates cannot produce: the
# conditional create 412s, and by the time the incumbent is read back it is
# GONE — a reaper revoked it in the window. The hermetic store cannot generate
# that interleaving single-threaded, so the branch was covered by nothing and a
# mutant turning it into a RETRY of the create passed every gate.
#
# ⚠ IT IS NOT UNREACHABLE — it is unreachable *from one concrete store*.
# `ServiceDirectory` is generic over `ConditionalWriteStore` precisely so the
# store can be substituted, so the interleaving is injected by a conformer that
# performs the revocation inside the 412 window. That is the branch's own
# premise (a concurrent writer) expressed as a test double, not a contrived
# input: nothing about the directory is stubbed, and the 412 it sees is a real
# one raised by the real in-memory store.
#
# WHAT THE MUTANT COSTS: retrying the create there succeeds, so the LATE
# claimant silently becomes the owner of an identity it never won — which is
# last-writer-wins wearing a retry's clothes, on the one keyspace whose whole
# purpose is to deny that. The falsifying assertion is therefore not "it
# raised" but "NOTHING WAS WRITTEN".
# -----------------------------------------------------------------------------


struct _RevokeOnConflictStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """A `ConditionalWriteStore` that DELETES the conflicting key immediately
    after a precondition failure, before returning control to the caller.

    Every verb delegates to a real `SharedInMemoryConditionalStore`; the ONLY
    added behaviour is the revocation inside the 412 window, which is the one
    interleaving a single-threaded test cannot otherwise produce."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

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
            # Only a 412 opens the window this double exists to model; any
            # other error is passed through untouched.
            if String(e).find("412") >= 0:
                self._inner.delete(path)
            raise e^

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
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


def test_a_concurrently_revoked_binding_is_refused_not_recreated() raises:
    print("-- test_a_concurrently_revoked_binding_is_refused_not_recreated --")
    var inner = SharedInMemoryConditionalStore()

    # Seed a real binding through an ordinary directory, so the 412 the racing
    # claimant sees is raised by the real store for the real reason.
    var seed = ServiceDirectory(inner.clone())
    var id = _gcp(String("racer@proj.iam.gserviceaccount.com"))
    seed.enroll_identity(id, String("incumbent-service"))

    var racy = ServiceDirectory(_RevokeOnConflictStore(inner.clone()))
    var refused = False
    var msg = String("")
    try:
        racy.enroll_identity(id, String("late-claimant"))
    except e:
        refused = True
        msg = String(e)

    assert_true(
        refused,
        String(
            "a create that 412s and then finds the binding REVOKED must be"
            " REFUSED — re-attempting the create under a concurrent revocation"
            " is last-writer-wins wearing a retry's clothes"
        ),
    )
    assert_true(
        msg.find("REVOKED") >= 0,
        String("the refusal must say the binding was revoked, got: ") + msg,
    )
    assert_true(
        msg.find("late-claimant") >= 0,
        String("the refusal must name the claimant it rejected, got: ") + msg,
    )

    # THE FALSIFYING ASSERTION: nothing was written. "It raised" is not enough —
    # a retry that succeeded and THEN raised would still have handed the
    # identity to a service that never won it.
    _absent(
        seed.resolve_identity(id),
        "the identity after a racing claim met a revocation",
    )
    assert_equal(
        len(seed.list_identities()),
        0,
        String("no enrollment object may survive a refused racing claim"),
    )

    # And the caller's correct response — re-run enrollment deliberately —
    # works, through an ordinary store.
    seed.enroll_identity(id, String("late-claimant"))
    _found(
        seed.resolve_identity(id),
        String("late-claimant"),
        "deliberate re-enrollment after the revocation",
    )
    print("   revoked-in-the-window claim REFUSED, nothing written OK")



# -----------------------------------------------------------------------------
# Gate 9c — A CORRUPT KEY IS A REFUSAL, NOT A PRINCIPAL. And the escape's two
# halves are asserted directly, not only through the fingerprint.
#
# ⚠ `escape_principal` / `unescape_principal` were named nowhere by the original
# file — reached only through `identity_fingerprint`, and only over well-formed
# input. So `_nibble_value`'s raise on a non-hex digit was covered by nothing:
# turn it into `return 0` and every gate stays green, while a corrupt key
# `identity/gcp.a_ZZ` decodes to the FABRICATED principal `a\0`.
#
# That is the same failure class as the relaxed platform token, at the other
# end of the same key, and it lands in the same place: `list_identities` is what
# the reap tooling reads, so a fabricated principal is what an operator is shown
# and what a reaper acts on. "We cannot read this key" and "this key says X" are
# different answers and only one of them is safe to act on.
#
# The COLLISION pair is also written out explicitly. Gate 9's injectivity check
# only compares principals against the others in its own list, and that list
# holds no pair that a relaxation would actually merge. `a:` escapes to `a_3A`,
# so a literal `a_3A` is the principal that collides with it the moment `_`
# stops being escaped — the reason `_is_literal` excludes `_` at all.
# -----------------------------------------------------------------------------


def _must_refuse_unescape(bad: String, why: String) raises:
    var refused = False
    try:
        _ = unescape_principal(bad)
    except:
        refused = True
    assert_true(
        refused,
        String("unescape_principal must REFUSE '") + bad + String("' — ") + why,
    )


def test_a_corrupt_fingerprint_is_refused_not_decoded() raises:
    print("-- test_a_corrupt_fingerprint_is_refused_not_decoded --")

    # The two halves are inverses, asserted DIRECTLY over the awkward bytes.
    var probes = List[String]()
    probes.append(String("jm@proj.iam.gserviceaccount.com"))
    probes.append(String("arn:aws:iam::1:role/scheduler"))
    probes.append(String("a_b"))
    probes.append(String("a:b"))
    probes.append(String("a/b"))
    probes.append(String("%_%"))
    probes.append(String("-"))
    for i in range(len(probes)):
        var enc = escape_principal(probes[i])
        assert_true(
            enc.find("/") < 0,
            String("an escaped principal may never contain '/': ") + enc,
        )
        assert_equal(
            unescape_principal(enc),
            probes[i],
            String("escape/unescape must be exact inverses for: ") + probes[i],
        )

    # ⛔ THE COLLISION PAIR (`a:` vs `a_3A`) is asserted at the TOP of
    # `test_identity_fingerprint_is_injective` — see
    # `_assert_the_escape_marker_is_ITSELF_escaped`; the reason for that ORDER
    # is in that helper's docstring. Do not copy it here: two copies of one
    # assertion is how the earlier of the two comes to be the one nobody
    # maintains.

    # A MALFORMED ESCAPE IS A REFUSAL. Each of these decodes to a plausible
    # string the moment the validation is relaxed.
    _must_refuse_unescape(
        String("a_ZZ"), String("'Z' is not a hex digit")
    )
    _must_refuse_unescape(
        String("a_3"), String("a truncated escape at the end of the key")
    )
    _must_refuse_unescape(
        String("a_"), String("an escape marker with no digits at all")
    )
    _must_refuse_unescape(
        String("a_G0"), String("'G' is one past 'F'")
    )

    # AND AT THE SURFACE THAT MATTERS: a corrupt key must make the reap tooling's
    # own verb REFUSE, rather than hand it an identity nobody enrolled.
    var store = SharedInMemoryConditionalStore()
    var dir = ServiceDirectory(store.clone())
    var real = _gcp(String("good@proj.iam.gserviceaccount.com"))
    dir.enroll_identity(real, String("a-svc"))
    assert_equal(
        len(dir.list_identities()),
        1,
        String("the well-formed binding lists"),
    )
    _ = store.put(
        Path.parse(String("identity/gcp.a_ZZ")), _bytes(String("ghost-svc"))
    )
    var listed = False
    try:
        _ = dir.list_identities()
        listed = True
    except:
        listed = False
    assert_false(
        listed,
        String(
            "list_identities must REFUSE a corrupt key rather than report a"
            " decoded-from-garbage principal — the reap tooling acts on what this"
            " returns"
        ),
    )
    # The direct recovery verb refuses it too, and names the key.
    var fp_refused = False
    try:
        _ = identity_from_fingerprint(String("gcp.a_ZZ"))
    except:
        fp_refused = True
    assert_true(
        fp_refused, String("identity_from_fingerprint must refuse 'gcp.a_ZZ'")
    )

    # `into_store` recovers the backing handle, data intact — the directory is
    # a contract over the store, not an owner of a second copy of the facts.
    var recovered = dir^.into_store()
    var raw = recovered.get(Path.parse(String("identity/gcp.good_40proj.iam.gserviceaccount.com")))
    assert_equal(
        len(raw),
        len(String("a-svc").as_bytes()),
        String("into_store hands back the same objects"),
    )
    print("   corrupt keys REFUSED; escape/unescape exact; into_store OK")


# -----------------------------------------------------------------------------
# Gate 2d — ⛔ THE CANONICAL `StoreError[...]` TOKEN IS CLASSIFIED WITHOUT A
# NUMERIC. The file's own most emphatic warning, guarded by nothing.
#
# `_is_precondition_failed` / `_is_not_found` open with
# `msg.find("StoreError[PRECONDITION]")` / `msg.find("StoreError[NOT_FOUND]")`
# and the comment above them says, in as many words, that keying only on the
# lowercase word plus the numeric "survives only while the numeric happens to be
# co-present — a message reformat that dropped `status=412` would silently turn
# a concurrent-deploy 412 into a fatal write".
#
# ⛔ MUTANT, AND IT WAS GREEN: delete BOTH canonical arms.
# Every gate above stayed green, because the ONLY store any of them runs against
# is `SharedInMemoryConditionalStore`, whose messages read `not_found (404)` and
# `precondition (412)` — the lowercase word AND the numeric, both. So the
# canonical arm was exercised by nothing and the warning guarded nothing.
#
# The conformer below emits the canonical token and NO numeric at all, which is
# the one shape the two classifiers exist for. Under the mutant every verb here
# converts a routine absence or a routine conflict into a raised store error:
# `resolve_endpoint` on an unpublished peer RAISES instead of reporting absent,
# and a redeploy re-running its own enrollment RAISES instead of being the
# no-op the policy promises.
# -----------------------------------------------------------------------------


def _canonical_store_message(kind: String, method: String, key: String) -> String:
    """A `StoreError[<KIND>] <method> gs://<bucket>/<key>` message carrying the
    CANONICAL token and NO numeric status — the reformat the classifiers'
    first arm exists to survive.

    Shaped after `komira_gcp_storage`'s `map_grpc_error_to_store_error`
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
    probe_keys.append(String("identity/gcp.jm_40proj.iam.gserviceaccount.com"))
    assert_equal(len(probe_keys), 3, "the fixture must carry all three keys")
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

    var id = _gcp(String("jm@proj.iam.gserviceaccount.com"))

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

    var id_absent = False
    var id_err = String("")
    try:
        id_absent = not dir.resolve_identity(id).found
    except e:
        id_err = String(e)
    assert_equal(
        id_err,
        String(""),
        String(
            "an UNENROLLED identity must come back as found=False, not as a"
            " raise — same classifier, the other keyspace. Got: "
        )
        + id_err,
    )
    assert_true(id_absent, "...and it reports found=False")

    # ── 2. AND SO IS A DELETE OF AN ABSENT KEY — `_delete_if_present`'s head.
    var del_err = String("")
    var withdrew = True
    var revoked = True
    try:
        withdrew = dir.withdraw_endpoint(String("alpha-svc"))
        revoked = dir.revoke_identity(id)
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
    assert_false(revoked, "...and revoke_identity reports False")

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

    # ── 4. THE 412 ARM — the one the classifier's warning is about. A redeploy
    # re-running its OWN enrollment is a NO-OP, and reaching that answer
    # requires classifying the conflict, reading the incumbent back and finding
    # it identical.
    dir.enroll_identity(id, String("alpha-svc"))
    var reenroll_err = String("")
    try:
        dir.enroll_identity(id, String("alpha-svc"))
    except e:
        reenroll_err = String(e)
    assert_equal(
        reenroll_err,
        String(""),
        String(
            "a redeploy re-running its OWN enrollment must be a NO-OP. The 412"
            " it gets back is classified by `_is_precondition_failed`, whose"
            " FIRST arm is the canonical `StoreError[PRECONDITION]` token —"
            " unclassified, the conflict is re-raised and every redeploy of"
            " every service fails at enrollment. Got: "
        )
        + reenroll_err,
    )
    _found(
        dir.resolve_identity(id),
        String("alpha-svc"),
        "the idempotent re-enroll left the binding intact",
    )

    # ── 5. AND A DIFFERENT CLAIMANT IS A **REFUSAL**, NOT A FATAL WRITE ERROR.
    # ⛔ THIS IS THE ASSERTION THAT DISCRIMINATES. Under the mutant the conflict
    # is unclassified, so `enroll_identity` re-raises the STORE's error — which
    # also "raises", and a bare "it raised" arm would pass. What must come back
    # is the REGISTRY's own refusal, naming BOTH services.
    var refused = String("")
    try:
        dir.enroll_identity(id, String("beta-svc"))
    except e:
        refused = String(e)
    assert_true(
        refused.byte_length() > 0,
        "a SECOND claimant must not be accepted",
    )
    assert_true(
        refused.find("REFUSED enrollment") >= 0,
        String(
            "the conflict must come back as the REGISTRY's refusal, not as the"
            " store's raw error — an unclassified 412 is re-raised verbatim and"
            " the incumbent is never read at all. Got: "
        )
        + refused,
    )
    assert_true(
        refused.find("alpha-svc") >= 0 and refused.find("beta-svc") >= 0,
        String("...and it names BOTH services. Got: ") + refused,
    )
    _found(
        dir.resolve_identity(id),
        String("alpha-svc"),
        "the incumbent binding is unchanged by the refusal",
    )
    print("   canonical StoreError tokens classified with NO numeric OK")


# -----------------------------------------------------------------------------
# Gate 2e — ⛔ `describe()` OWNERSHIP IS EQUALITY, NOT CONTAINMENT. The SAME
# defect gate 2b closes in `enroll_identity`, one method away, on a line nothing
# reached.
#
# MUTANT, AND IT WAS GREEN: `bound.value == name` relaxed to
# `bound.value.find(name) >= 0`. Every gate above stayed green because no gate
# calls `describe` with two registered service names in a substring relation —
# while `<service>-<cloud>-<region>` MAKES that relation on every regional name.
#
# WHAT IT COSTS. `describe` is the reap tooling's join view: it is what an operator
# reads to decide which identities belong to a service before revoking them.
# Under containment, `describe("scheduler")` reports the identity enrolled as
# `scheduler-gcp-us-central1` as its own — and the reap that follows revokes a
# LIVE service's identity while reporting it was cleaning up a different one.
# -----------------------------------------------------------------------------


def _identity_principals(record: ServiceRecord) -> List[String]:
    var out = List[String]()
    for i in range(len(record.identities)):
        out.append(String(record.identities[i].principal))
    return out^


def test_describe_names_only_the_identities_bound_to_THAT_service() raises:
    print("-- test_describe_names_only_the_identities_bound_to_THAT_service --")
    var dir = ServiceDirectory(SharedInMemoryConditionalStore())

    # ⭐ A REAL NAMING SCHEME, not a contrived pair: `scheduler` IS a prefix
    # of `scheduler-gcp-us-central1`, which is how a regional name is commonly
    # built.
    var short_name = String("scheduler")
    var long_name = String("scheduler-gcp-us-central1")
    assert_true(
        long_name.find(short_name) >= 0 and short_name != long_name,
        "fixture drift: this gate needs one name to CONTAIN the other",
    )

    var short_id = _gcp(String("jm-bare@proj.iam.gserviceaccount.com"))
    var long_id = _gcp(String("jm-regional@proj.iam.gserviceaccount.com"))
    dir.enroll_identity(short_id, short_name)
    dir.enroll_identity(long_id, long_name)
    dir.publish_endpoint(short_name, String("https://jm-bare"))
    dir.publish_endpoint(long_name, String("https://jm-regional"))

    var short_rec = dir.describe(short_name)
    var long_rec = dir.describe(long_name)

    # ⛔ THE COUNTS COME FIRST. A containment test in EITHER direction inflates
    # exactly one of these to 2, and a membership-only assertion would not see
    # it (each record does contain its own identity under both mutants).
    assert_equal(
        len(short_rec.identities),
        1,
        String(
            "describe('scheduler') must name ONE identity — its own."
            " `bound.value.find(name) >= 0` also matches the identity enrolled"
            " as 'scheduler-gcp-us-central1', and the reap tooling reads this to"
            " decide what to revoke. Got: "
        )
        + _render_names(_identity_principals(short_rec)),
    )
    assert_equal(
        len(long_rec.identities),
        1,
        String(
            "describe('scheduler-gcp-us-central1') must name ONE identity —"
            " its own. `name.find(bound.value) >= 0` is the OTHER one-token"
            " relaxation and it is caught only by the LONGER claimant. Got: "
        )
        + _render_names(_identity_principals(long_rec)),
    )
    assert_equal(
        short_rec.identities[0].principal,
        short_id.principal,
        "...and it is the one enrolled as 'scheduler'",
    )
    assert_equal(
        long_rec.identities[0].principal,
        long_id.principal,
        "...and it is the one enrolled as 'scheduler-gcp-us-central1'",
    )

    # The endpoint half of the record is per-name too — the SAME containment
    # question one field over, answered by the key rather than by a comparison.
    assert_true(short_rec.has_endpoint(), "the short name has an endpoint")
    assert_true(long_rec.has_endpoint(), "the long name has an endpoint")
    assert_equal(
        short_rec.endpoint.value(),
        String("https://jm-bare"),
        "describe reports the service's OWN endpoint",
    )
    assert_equal(
        long_rec.endpoint.value(),
        String("https://jm-regional"),
        "...and not its substring-relative's",
    )
    assert_equal(
        short_rec.name, short_name, "the record names the service asked for"
    )

    # A service with NO endpoint still describes: the join is over identities,
    # and an unpublished service is the ordinary state during a rollout.
    var third_id = _aws(String("arn:aws:iam::role/scheduler-shadow"))
    dir.enroll_identity(third_id, String("scheduler-aws-us-east"))
    var unpublished = dir.describe(String("scheduler-aws-us-east"))
    assert_false(
        unpublished.has_endpoint(),
        "an unpublished service describes with NO endpoint, not a raise",
    )
    assert_equal(
        len(unpublished.identities), 1, "and still names its own identity"
    )
    # ...and adding it did not leak into either of the first two records.
    assert_equal(
        len(dir.describe(short_name).identities),
        1,
        "a THIRD substring-related name does not join the first record",
    )
    print("   describe joins on equality, never containment OK")


# -----------------------------------------------------------------------------
# Gate 5c — ⛔ THE RETRY-ONCE ON THE ENDPOINT CAS, AND THE RAISE BEHIND IT.
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
# The interleaving is injected by substituting the `Store` type-param, the same
# technique gate 2c uses: nothing about the directory is stubbed and the 412 is
# the real classifier's answer to a real conflict message.
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

    ⚠ ONLY `service/` IS FAULTED. The enrollment keyspace has the OPPOSITE write
    policy (a 412 there is a refusal, never a retry) and injecting a conflict
    into it would be testing gate 2's contract with gate 5's double."""

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
        spelling, numeric included, so this gate is independent of gate 2d."""
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

    # ⛔ AND THE ENROLLMENT KEYSPACE IS UNTOUCHED BY THE SAME DOUBLE — its 412
    # is a REFUSAL, never a retry, and the two policies must not be able to
    # borrow each other's handling through one store.
    var id = _gcp(String("jm@proj.iam.gserviceaccount.com"))
    dir2.enroll_identity(id, String("beta-svc"))
    _found(
        ServiceDirectory(inner2.clone()).resolve_identity(id),
        String("beta-svc"),
        "the identity keyspace is not faulted by the endpoint double",
    )
    print("   one 412 retried, a permanent 412 raised naming '412 twice' OK")


def main() raises:
    test_one_store_serves_both_jobs()
    test_a_second_claimant_of_an_enrolled_identity_is_refused()
    test_a_substring_related_service_name_is_still_a_different_service()
    test_a_concurrently_revoked_binding_is_refused_not_recreated()
    test_reenrolling_the_same_service_is_a_noop()
    test_one_service_may_hold_identities_on_two_clouds()
    test_two_services_claiming_one_identity_collide_on_one_key()
    test_the_endpoint_is_last_writer_wins()
    test_publish_endpoint_if_changed_writes_iff_the_url_changed()
    test_resolve_result_carries_provenance()
    test_the_cache_ttl_boundary_is_exclusive_and_the_verbs_work()
    test_delete_verbs()
    test_the_endpoint_object_is_wire_identical_to_the_shipped_writer()
    test_list_verbs()
    test_identity_fingerprint_is_injective()
    test_the_platform_token_charset_is_what_makes_the_split_unambiguous()
    test_a_corrupt_fingerprint_is_refused_not_decoded()
    test_the_CANONICAL_store_error_tokens_are_classified_without_a_numeric()
    test_describe_names_only_the_identities_bound_to_THAT_service()
    test_a_contended_endpoint_publish_retries_ONCE_and_then_RAISES()
    print("ALL SERVICE-REGISTRY CONTRACT GATES PASSED")
