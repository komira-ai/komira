# =============================================================================
# kci_revision/tests/test_kci_revision_store.mojo — THE REVISION SUBSTRATE
#   GATE: minting is an ALLOCATOR, not a "read the counter and write".
# =============================================================================
#
# Rule applied throughout: A TEST I CANNOT SEE FAIL IS WORTHLESS. Every test
# below names, in its docstring, the concrete MUTANT implementation it goes RED
# against — and the three that matter most were each run against that mutant and
# observed RED before the implementation was accepted.
#
# THE THREE FALSIFIERS THAT DEFINE THIS FILE
#
#   (1) test_concurrent_mint_does_not_clobber_the_winner
#       Two machines mint at once. The loser MUST NOT overwrite the winner's
#       record. RED against the naive allocator (`read HEAD, +1, put`), which
#       silently replaces r14's bytes with the second machine's build — the
#       exact "two builds, one revision id, one of them lost" failure.
#
#   (2) test_resolve_unknown_revision_is_an_honest_error
#       `--revision shop-r99` on an app that has r1..r3 MUST raise, naming what
#       IS there. RED against any implementation that returns an empty record /
#       `None`-degrades to latest — a typo must not silently ship a different
#       build than the operator named.
#
#   (3) test_revision_round_trips_its_full_artifact_set
#       A revision minted from a service image + TWO probe images resolves back
#       with all three. RED against a record that stores only the service digest
#       — which reproduces the probe FALSE-GREEN (a probe image that asserts the
#       OLD contract and exits 0) one level up, in the release ledger.
#
# Plus the allocator's own invariants: probe-forward (never re-read HEAD after a
# 412 — the spin bug), monotone-max HEAD, crash-between-record-and-HEAD
# self-heal, the HEAD-only reuse boundary, and the hyphenated-app-id ordinal
# parse (`orders-coordinator-r7`, the input every `rfind("-r")` heuristic
# gets wrong).
#
# HERMETIC: `InMemoryConditionalStore` (single-handle) and
# `SharedInMemoryConditionalStore` (Arc-shared — two handles = two machines,
# with the interleaving driven explicitly by the test). No bucket, no network,
# no hosted account — which is also the point: the substrate must work with
# none of them. Mojo 1.0 (def-only).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
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

from kci_revision import (
    RevisionArtifact,
    RevisionRecord,
    RevisionStore,
    MintOutcome,
    REVISION_SCHEMA,
    MAX_REPRODUCED_COMMITS,
    REVISION_ROLE_SERVICE,
    REVISION_ROLE_PROBE,
    REVISION_ROLE_WEB_CONTENT,
    format_revision_id,
    ordinal_of,
    encode_revision,
    decode_revision,
    revision_json,
    artifacts_equal,
    sort_artifacts,
    merge_artifacts,
)


# -----------------------------------------------------------------------------
# Fixtures — three DISTINCT artifact sets (A / B / C) + the shapes they model.
# -----------------------------------------------------------------------------

comptime _APP: String = "shop"
comptime _SVC_A: String = "sha256:9f3c000000000000000000000000000000000000000000000000000000000000"
comptime _SVC_B: String = "sha256:11ab000000000000000000000000000000000000000000000000000000000000"
comptime _SVC_C: String = "sha256:22cd000000000000000000000000000000000000000000000000000000000000"
comptime _PROBE_1: String = "sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
comptime _PROBE_2: String = "sha256:bbbb000000000000000000000000000000000000000000000000000000000000"


def _service_only(digest: String) -> List[RevisionArtifact]:
    """The minimal set: one ServerlessCompute image."""
    var out = List[RevisionArtifact]()
    out.append(
        RevisionArtifact(
            String("shop-svc"),
            String(REVISION_ROLE_SERVICE),
            digest.copy(),
            String("registry.example.com/example-project/apps/shop@")
            + digest,
        )
    )
    return out^


def _service_and_probes(digest: String) -> List[RevisionArtifact]:
    """The REAL shape of a managed-app build: the service image PLUS every
    validator/probe image the bundle's validate steps name. This is the set the
    release record must carry — see falsifier (3)."""
    var out = _service_only(digest)
    out.append(
        RevisionArtifact(
            String("smoke_validator"),
            String(REVISION_ROLE_PROBE),
            String(_PROBE_1),
            String(
                "registry.example.com/example-project/probes/smoke-validator@"
            )
            + String(_PROBE_1),
        )
    )
    out.append(
        RevisionArtifact(
            String("contract_validator"),
            String(REVISION_ROLE_PROBE),
            String(_PROBE_2),
            String(
                "registry.example.com/example-project/probes/contract-validator@"
            )
            + String(_PROBE_2),
        )
    )
    return out^


def _new_store() -> RevisionStore[InMemoryConditionalStore]:
    return RevisionStore[InMemoryConditionalStore](InMemoryConditionalStore())


def _service_digest_n(i: Int) -> String:
    """A distinct, well-formed `sha256:` digest per `i` — so a 70-revision
    history is 70 GENUINELY different builds (identical artifacts would hit the
    reuse fast path and mint nothing)."""
    var s = String(i)
    var pad = String("")
    for _ in range(64 - s.byte_length()):
        pad += String("0")
    return String("sha256:") + pad + s


# =============================================================================
# THE TORN-CREATE STORE DOUBLE — a state no other store double produces.
# =============================================================================
#
# The in-memory store doubles commit the KEY and the BODY in one indivisible
# step, so no test could reach the allocator's "I 412'd; who owns this
# ordinal?" branch with a slot whose body is not there yet. That is not a
# hypothetical state: `LocalFsConditionalStore` — the conformer the "works with
# no hosted account and no database" claim rests on — is explicitly NON-ATOMIC
# on create:
#
#     Step 1 — the exclusive create-open is the linearization point. …
#       w = RawWriteFd.open_create_exclusive(path)      # O_CREAT|O_EXCL
#     Step 2 — the create succeeded; WE own the slot. …
#       w.write_bytes(...); w.fsync(); w.close()
#
# and its own documentation concedes the window: "(A torn-create chunk — present
# but zero/partial — is re-derived by the protocol's LIST recovery.)"
#
# So: two `kci shop build` processes over one revisions directory. A wins
# the O_EXCL create of `revisions/shop/shop-r2` and has not yet reached step
# 2. B's `conditional_put` 412s, B `get`s the key, and B receives ZERO BYTES.
# `TornCreateStore` reproduces exactly that observable state, and nothing else.


struct TornCreateStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A `ConditionalWriteStore` whose create-if-absent is NON-ATOMIC for ONE
    designated key: the key becomes visible, the body does NOT.

    Models `LocalFsConditionalStore`'s exclusive create (step 1) having
    linearized while step 2 has not run — i.e. the winner is still in flight.
    Delegates every other verb, including creates of every other key, to a
    shared in-memory store, so a `RevisionStore[TornCreateStore]` behaves
    normally everywhere else and the test isolates ONE variable.

    `tear_key` is fixed at construction (no interior mutability, no Arc): the
    test names the exact key it wants torn, which is also what makes the fixture
    readable at the call site."""

    var _inner: SharedInMemoryConditionalStore
    var _tear_key: String

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, var tear_key: String
    ):
        self._inner = inner^
        self._tear_key = tear_key^

    # ---- ObjectStore base surface (pure delegation) ----
    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----
    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if precond.is_create() and path.raw() == self._tear_key:
            # THE TEAR. The exclusive create linearizes — the caller legitimately
            # owns the slot and would go on to write — but the BODY has not
            # landed. A concurrent reader sees the key with zero bytes.
            return self._inner.conditional_put(path, List[UInt8](), precond)
        return self._inner.conditional_put(path, bytes, precond)

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


# =============================================================================
# DEFECT 1 — a losing minter must survive a winner whose KEY exists but whose
#            BODY is not yet visible.
# =============================================================================
def test_mint_probes_past_a_winner_whose_body_is_not_yet_visible() raises:
    """★ Two `kci shop build` processes over ONE revisions directory.
    Machine A wins the `O_EXCL` create of `shop-r2`; before A writes its body,
    machine B collides on the same ordinal. B must take `shop-r3`.

    RED against an allocator that reads the winner through the fail-loud
    `try_resolve`:

        PROBE-1 minted=[] raised=[JsonError: unexpected end of input]

    `decode_revision("")` raises a `JsonError`, which matches neither
    `_is_not_found` nor any other caught arm, so it propagates straight out of
    `mint` and KILLS B's build — while `shop-r3` is free the whole time and
    probing forward is the only correct move.

    Three things are asserted, and the second is the one that keeps the fix
    honest: B must not merely survive, it must not CLOBBER A's slot either. A
    "fix" that treated an unreadable body as an absent record and re-created it
    would pass a survival-only test and silently destroy the winner's build."""
    var shared = SharedInMemoryConditionalStore()
    var seeder = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var base = seeder.mint(
        String(_APP), _service_only(String(_SVC_C)), String("c"), String(_APP),
        Int64(1),
    )
    assert_equal(base.record.revision_id, String("shop-r1"))

    # MACHINE A: wins the exclusive create of shop-r2 and has NOT yet written.
    # Driven through the double directly — A is mid-call, so it has not returned
    # to `mint` and has therefore not advanced HEAD either.
    var r2_key = String("revisions/shop/shop-r2")
    var torn = TornCreateStore(shared.clone(), r2_key.copy())
    _ = torn.conditional_put(
        Path.parse(r2_key),
        _bytes(String('{"schema":"kci.revision.v1","appId":"shop"}')),
        WritePrecondition.if_none_match_star(),
    )
    var torn_meta = shared.head(Path.parse(r2_key))
    assert_equal(
        torn_meta.size, Int64(0), "the fixture must produce a TORN create"
    )

    # MACHINE B: reads HEAD=shop-r1, computes ordinal 2, collides with A.
    # Its own store is the torn double too (same tear key) — the fix must hold
    # for a RevisionStore parameterised over a non-atomically-creating store.
    var machine_b = RevisionStore[TornCreateStore](
        TornCreateStore(shared.clone(), r2_key.copy())
    )
    var b = machine_b.mint(
        String(_APP), _service_only(String(_SVC_B)), String("bbbbbbbb22"),
        String(_APP), Int64(3),
    )
    assert_equal(
        b.record.revision_id,
        String("shop-r3"),
        "B must probe PAST the in-flight winner, not die on its empty body",
    )
    assert_true(b.minted, "B minted a new revision")

    # ★ A's slot is UNTOUCHED — still the winner's, still zero bytes.
    var after = shared.head(Path.parse(r2_key))
    assert_equal(
        after.size,
        Int64(0),
        "the loser must not have re-created / clobbered the winner's slot",
    )

    # And when A finally writes, the ledger is coherent: r2 is A's, r3 is B's.
    _ = shared.put(
        Path.parse(r2_key),
        encode_revision(
            RevisionRecord(
                String(REVISION_SCHEMA), String(_APP), String("shop-r2"),
                Int64(2), String("aaaaaaaa11"), Int64(2), String(_APP),
                _service_only(String(_SVC_A)),
            )
        ),
    )
    var reader = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    assert_equal(
        reader.resolve(String(_APP), String("shop-r2")).service_digest(),
        String(_SVC_A),
    )
    assert_equal(
        reader.resolve(String(_APP), String("shop-r3")).service_digest(),
        String(_SVC_B),
    )
    print("  test_mint_probes_past_a_winner_whose_body_is_not_yet_visible: PASS")


def test_mint_probes_past_a_winner_whose_body_is_half_written() raises:
    """The same defect with a PARTIAL body rather than a zero-length one — the
    other half of the local-filesystem conformer's "present but
    zero/partial". `parse_json_value` raises a different `JsonError` here, so a
    fix that special-cased "empty bytes" would go RED on this one and green on
    the test above."""
    var shared = SharedInMemoryConditionalStore()
    var seeder = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = seeder.mint(
        String(_APP), _service_only(String(_SVC_C)), String("c"), String(_APP),
        Int64(1),
    )
    # A's write landed HALF a record (fsync never ran).
    _ = shared.conditional_put(
        Path.parse(String("revisions/shop/shop-r2")),
        _bytes(String('{"schema":"kci.revision.v1","appId":"sho')),
        WritePrecondition.if_none_match_star(),
    )
    var machine_b = RevisionStore[SharedInMemoryConditionalStore](
        shared.clone()
    )
    var b = machine_b.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP),
        Int64(3),
    )
    assert_equal(b.record.revision_id, String("shop-r3"))
    print("  test_mint_probes_past_a_winner_whose_body_is_half_written: PASS")


def test_resolve_of_an_unreadable_record_still_raises() raises:
    """★ THE ANTI-DEGRADE GUARD for the fix above. Tolerating an unreadable body
    is the ALLOCATOR's rule and must not leak into the OPERATOR's read.

    This is the wrong-fix detector: making `decode_revision` (or `try_resolve`)
    lenient would turn both defect-1 tests green while making
    `--revision shop-r2` answer "no such revision" — or worse, hand back an
    empty record — for a revision that demonstrably EXISTS. That is the same
    fail-quiet shape falsifier (2) exists to prevent, one layer down."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP),
        Int64(1),
    )
    _ = shared.put(
        Path.parse(String("revisions/shop/shop-r1")),
        _bytes(String('{"schema":"kci.revision.v1","appI')),
    )
    with assert_raises():
        var _r = store.resolve(String(_APP), String("shop-r1"))
    with assert_raises():
        var _t = store.try_resolve(String(_APP), String("shop-r1"))
    print("  test_resolve_of_an_unreadable_record_still_raises: PASS")


def test_mint_survives_a_head_pointing_at_an_unreadable_record() raises:
    """The same defect one call earlier: `head()` resolves HEAD's record, so a
    HEAD that points at a TORN (not merely absent) record killed `mint` before
    the allocator ever ran.

    RED against a `head` that reads through `try_resolve`: `JsonError: unexpected
    end of input` out of `mint`. `test_torn_head_pointing_at_nothing_is_survivable`
    cannot catch it — it only ever points HEAD at a key that 404s."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP),
        Int64(1),
    )
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP),
        Int64(2),
    )
    # HEAD still says shop-r2, but r2's body is now unreadable.
    _ = shared.put(
        Path.parse(String("revisions/shop/shop-r2")), List[UInt8]()
    )
    var out = store.mint(
        String(_APP), _service_only(String(_SVC_C)), String("c"), String(_APP),
        Int64(3),
    )
    assert_equal(
        out.record.revision_id,
        String("shop-r3"),
        "a torn HEAD TARGET is 'nothing known', not a build-killing fault",
    )
    var still = shared.head(Path.parse(String("revisions/shop/shop-r2")))
    assert_equal(still.size, Int64(0), "r2 was not silently rewritten")
    print("  test_mint_survives_a_head_pointing_at_an_unreadable_record: PASS")


# =============================================================================
# DEFECT 2 — losing HEAD must be RECOVERABLE, at any history length.
# =============================================================================
def test_mint_recovers_when_head_is_lost_past_the_probe_ceiling() raises:
    """★ HEAD is a DERIVED CACHE ("a lost HEAD CAS is not an error"), so losing
    it cannot be terminal. A lost HEAD that restarted probing at ordinal 1 with
    a `MINT_MAX_PROBES = 64` ceiling would mean an app that had passed 64
    revisions COULD NEVER MINT AGAIN — every probe 412s against an existing
    record and the loop gives up.

    70 revisions, delete HEAD, mint. RED against an allocator without the
    store-derived floor:

        Unhandled exception caught during execution: kci revision: could
        not allocate an ordinal for app 'shop' after 64 probes starting at 1
        — the revision keyspace looks corrupted

    The 70 is not arbitrary: 64 is the constant, and any app shipping weekly
    passes it in sixteen months."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    for i in range(1, 71):
        var out = store.mint(
            String(_APP), _service_only(_service_digest_n(i)), String("c") + String(i),
            String(_APP), Int64(i),
        )
        assert_equal(out.record.revision_id, format_revision_id(String(_APP), Int64(i)))
    assert_equal(store.head_id(String(_APP)).value(), String("shop-r70"))

    # The cache is gone (a lifecycle rule, a mistaken delete, a bucket restore
    # that missed one object).
    shared.delete(Path.parse(String("revisions/shop/HEAD")))
    var gone = store.head_id(String(_APP))
    assert_true(not gone, "HEAD is gone")

    var out = store.mint(
        String(_APP), _service_only(_service_digest_n(71)), String("c71"),
        String(_APP), Int64(71),
    )
    assert_equal(
        out.record.revision_id,
        String("shop-r71"),
        "a lost HEAD must be recovered from the store, not bricked",
    )
    assert_true(out.minted)
    assert_equal(
        store.head_id(String(_APP)).value(),
        String("shop-r71"),
        "and HEAD is rebuilt",
    )
    print("  test_mint_recovers_when_head_is_lost_past_the_probe_ceiling: PASS")


def test_reuse_still_works_through_a_reconstructed_head() raises:
    """★ THE REGRESSION GUARD for a floor-only recovery. When HEAD is lost,
    recovering only the FLOOR silently drops the reuse contract: the allocator
    jumps to max+1 and mints a fresh ordinal for bytes that already have a
    durable record — and the concurrent-twin convergence mints two records for
    ONE release.

    So the recovery must reconstruct the whole of what HEAD carried: the floor
    AND the record to compare artifacts against. 70 revisions, HEAD deleted, a
    rebuild identical to r70 -> `shop-r70` REUSED (nothing minted), and the
    lost cache repaired on the way out.

    (A floor-only recovery also reddens
    `test_concurrent_identical_artifacts_converge_on_one_record`:
    `left: shop-r2  right: shop-r1`.)"""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    for i in range(1, 71):
        _ = store.mint(
            String(_APP), _service_only(_service_digest_n(i)), String("c") + String(i),
            String(_APP), Int64(i),
        )
    shared.delete(Path.parse(String("revisions/shop/HEAD")))

    var out = store.mint(
        String(_APP), _service_only(_service_digest_n(70)), String("rebuild"),
        String(_APP), Int64(99),
    )
    assert_equal(out.record.revision_id, String("shop-r70"))
    assert_false(out.minted, "identical bytes must NOT burn a fresh ordinal")
    assert_equal(
        out.record.git_commit,
        String("c70"),
        "the record is immutable — the ORIGINAL commit is preserved",
    )
    assert_equal(len(store.list_ids(String(_APP))), 70, "no new record")
    assert_equal(
        store.head_id(String(_APP)).value(),
        String("shop-r70"),
        "the lost HEAD is repaired on the way out",
    )
    print("  test_reuse_still_works_through_a_reconstructed_head: PASS")


def test_recovered_floor_is_the_max_ordinal_not_the_record_count() raises:
    """★ THE CHEAT DETECTOR for the recovery above. The floor must be the
    MAXIMUM ordinal present, never a COUNT of the objects present.

    70 revisions minted, HEAD deleted, and r1..r40 pruned (a retention sweep —
    the realistic way a prefix loses objects). 30 records remain; the max is
    still 70. A count-based floor computes 30 -> tries `shop-r31`, which is
    FREE because it was pruned, so it SUCCEEDS and re-issues an ordinal that
    already named a different build. The ledger then has two distinct records
    that were both `shop-r31`, and every consumer that treats ordinals as
    monotone with release time is reading a lie.

    A survival-only test cannot see this: the count-based floor SURVIVES."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    for i in range(1, 71):
        _ = store.mint(
            String(_APP), _service_only(_service_digest_n(i)), String("c") + String(i),
            String(_APP), Int64(i),
        )
    shared.delete(Path.parse(String("revisions/shop/HEAD")))
    for i in range(1, 41):
        shared.delete(
            Path.parse(
                String("revisions/shop/")
                + format_revision_id(String(_APP), Int64(i))
            )
        )
    assert_equal(len(store.list_ids(String(_APP))), 30, "30 records remain")

    var out = store.mint(
        String(_APP), _service_only(_service_digest_n(71)), String("c71"),
        String(_APP), Int64(71),
    )
    assert_equal(
        out.record.revision_id,
        String("shop-r71"),
        "the floor is the MAX ordinal (70), not the record COUNT (30)",
    )
    print("  test_recovered_floor_is_the_max_ordinal_not_the_record_count: PASS")


def test_mint_recovers_when_head_was_restored_far_behind() raises:
    """The other way a floor goes wrong: HEAD is PRESENT and resolvable but
    stale by more than the whole probe budget (a bucket restored from an old
    snapshot). `n0` is then a hint that is 69 ordinals short, the budget is
    burned entirely.

    RED against an allocator without the recovery pass:

        Unhandled exception caught during execution: kci revision: could
        not allocate an ordinal for app 'shop' after 64 probes starting at 2
        — the revision keyspace looks corrupted

    Exercises `mint`'s recovery pass (C), which the HEAD-deleted test above does
    NOT reach (that one recovers the floor before probing at all)."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    for i in range(1, 71):
        _ = store.mint(
            String(_APP), _service_only(_service_digest_n(i)), String("c") + String(i),
            String(_APP), Int64(i),
        )
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")), _bytes(String("shop-r1\n"))
    )
    var out = store.mint(
        String(_APP), _service_only(_service_digest_n(71)), String("c71"),
        String(_APP), Int64(71),
    )
    assert_equal(out.record.revision_id, String("shop-r71"))
    assert_equal(store.head_id(String(_APP)).value(), String("shop-r71"))
    print("  test_mint_recovers_when_head_was_restored_far_behind: PASS")


def test_a_healthy_head_mint_issues_no_listing() raises:
    """The recovery LIST is a FALLBACK, not a tax. With a resolvable HEAD the
    mint must issue ZERO `list_with_delimiter` calls.

    RED against the lazy fix — "just LIST the prefix every mint to get the
    floor" — which is correct but makes every build on a 5,000-revision app pay
    a full-prefix listing, and on GCS/S3 a paginated one."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP),
        Int64(1),
    )
    shared.reset_op_counts()
    var out = store.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP),
        Int64(2),
    )
    assert_equal(out.record.revision_id, String("shop-r2"))
    assert_equal(
        shared.n_list(),
        Int64(0),
        "a healthy HEAD must not trigger the recovery listing",
    )
    print("  test_a_healthy_head_mint_issues_no_listing: PASS")


# =============================================================================
# (1) THE CONCURRENCY FALSIFIER — the loser must not clobber the winner.
# =============================================================================
def test_concurrent_mint_does_not_clobber_the_winner() raises:
    """★ FALSIFIER (1). Two machines mint at the same moment against the SAME
    bucket. Machine A wins the create of `shop-r14`; machine B — which read the
    same HEAD=`shop-r13` and therefore also computed 14 — MUST take the 412,
    discover A's record is a DIFFERENT build, and probe forward to `shop-r15`.
    A's record must be byte-for-byte untouched.

    RED against the naive allocator (`read HEAD, +1, put`): a plain `put` has no
    precondition, so B silently overwrites A's r14 with B's artifacts and A's
    build vanishes from the ledger while both operators are told "r14".
    (Against that mutant, `assert_equal(a_after.service_digest(), _SVC_A)`
    reports B's digest.)

    The interleaving is driven explicitly rather than by threads: A's record is
    committed while HEAD still says r13 — which is EXACTLY the window a
    concurrent minter observes, and also exactly the crash window between the
    record and HEAD."""
    var shared = SharedInMemoryConditionalStore()
    var seeder = RevisionStore[SharedInMemoryConditionalStore](shared.clone())

    # Ground truth both racers start from: r1 exists and HEAD points at it.
    var base = seeder.mint(
        String(_APP),
        _service_only(String(_SVC_C)),
        String("c0ffee0001"),
        String(_APP),
        Int64(1),
    )
    assert_equal(base.record.revision_id, String("shop-r1"))

    # Machine A commits its record. (The store is shared, so this IS the
    # winner's committed state as machine B would observe it.)
    var machine_a = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var a = machine_a.mint(
        String(_APP),
        _service_only(String(_SVC_A)),
        String("aaaaaaaa11"),
        String(_APP),
        Int64(2),
    )
    assert_equal(a.record.revision_id, String("shop-r2"))
    assert_true(a.minted, "machine A minted a NEW revision")

    # Machine B raced A: it read HEAD=shop-r1 BEFORE A advanced it, so it will
    # compute ordinal 2 and collide. Simulate by rolling HEAD back to r1 — the
    # observable state of "A created its record but has not advanced HEAD yet".
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")),
        _bytes(String("shop-r1\n")),
    )
    var machine_b = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var b = machine_b.mint(
        String(_APP),
        _service_only(String(_SVC_B)),
        String("bbbbbbbb22"),
        String(_APP),
        Int64(3),
    )

    # ★ THE CLOBBER CHECK FIRST — it is the headline property. A's record must
    #   still hold A's build, byte for byte.
    var reader = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var a_after = reader.resolve(String(_APP), String("shop-r2"))
    assert_equal(
        a_after.service_digest(),
        String(_SVC_A),
        "machine A's revision must be untouched by the concurrent minter",
    )
    assert_equal(a_after.git_commit, String("aaaaaaaa11"))

    # B PROBED FORWARD — it did not take r2, and it did not fail.
    assert_equal(
        b.record.revision_id,
        String("shop-r3"),
        "the losing minter must probe forward to the next free ordinal",
    )
    assert_true(b.minted, "machine B minted a NEW revision (different bytes)")
    var b_after = reader.resolve(String(_APP), String("shop-r3"))
    assert_equal(b_after.service_digest(), String(_SVC_B))

    # BOTH are durable, ordinals are distinct, HEAD is the max.
    assert_equal(reader.head_id(String(_APP)).value(), String("shop-r3"))
    print("  test_concurrent_mint_does_not_clobber_the_winner: PASS")


# =============================================================================
# (2) THE FAIL-LOUD FALSIFIER — an unknown revision is an ERROR, never a shrug.
# =============================================================================
def test_resolve_unknown_revision_is_an_honest_error() raises:
    """★ FALSIFIER (2). `resolve` on an id that was never minted RAISES, and the
    message names the app, the key, AND the ids that DO exist — so an operator
    who typed `shop-r41` for `shop-r14` is told so.

    RED against any implementation that returns an empty/default record or
    degrades to "latest": that is precisely how a deploy ships a build nobody
    asked for while exiting 0. (Against a `resolve` returning an empty
    `RevisionRecord`, `assert_raises` reports "AssertionError: no error
    raised".)

    Also pinned here: `head` on an app with NO revisions is `None`, not a raise
    — nothing built yet is a STATE (the service registry's contract), while a
    NAMED-but-absent revision is an ERROR. The two are different questions and
    must not share an answer."""
    var store = _new_store()
    _ = store.mint(
        String(_APP),
        _service_only(String(_SVC_A)),
        String("aaaa"),
        String(_APP),
        Int64(1),
    )
    _ = store.mint(
        String(_APP),
        _service_only(String(_SVC_B)),
        String("bbbb"),
        String(_APP),
        Int64(2),
    )

    with assert_raises(contains="no revision 'shop-r99'"):
        var _r = store.resolve(String(_APP), String("shop-r99"))

    # The message must name what IS there (an operator needs the next move).
    var told_what_exists = False
    try:
        var _r2 = store.resolve(String(_APP), String("shop-r99"))
    except e:
        var msg = String(e)
        told_what_exists = msg.find("shop-r1") >= 0 and msg.find("shop-r2") >= 0
    assert_true(
        told_what_exists,
        "the not-found message must list the revisions that DO exist",
    )

    # A CROSS-APP id is refused before any round trip.
    with assert_raises(contains="is not a revision of app 'shop'"):
        var _r3 = store.resolve(String(_APP), String("cart-r3"))

    # Nothing-built-yet is None, NOT an error.
    var no_head = store.head(String("cart"))
    assert_true(
        not no_head,
        "an app with no revisions has no HEAD — a state, not an error",
    )
    var no_head_id = store.head_id(String("cart"))
    assert_true(not no_head_id, "head_id is None for an unbuilt app")
    print("  test_resolve_unknown_revision_is_an_honest_error: PASS")


# =============================================================================
# (3) THE ARTIFACT-SET FALSIFIER — the FULL set round-trips, not just service.
# =============================================================================
def test_revision_round_trips_its_full_artifact_set() raises:
    """★ FALSIFIER (3). A revision minted from a service image + TWO probe images
    resolves back carrying all three, with role + digest + full pullable ref
    intact — through the real object bytes, not an in-memory handoff.

    RED against a record that keeps only the service digest. That omission is the
    probe FALSE-GREEN one level up: the release record would name the code but
    not the gate that blessed it, so a deploy pinned to this revision would still
    pull whatever `:latest` the probe repo happens to hold — a probe that asserts
    the OLD contract and exits 0. (Against a `revision_json` that skips
    non-`service` roles, `assert_equal(len(got.artifacts), 3)` reports 1.)"""
    var store = _new_store()
    var out = store.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),
        String("5e7d1c0a92"),
        String(_APP),
        Int64(1785000000000000),
    )
    assert_true(out.minted)

    # Resolve through the STORE (a real decode of the real stored bytes).
    var got = store.resolve(String(_APP), out.record.revision_id)
    assert_equal(len(got.artifacts), 3, "service + 2 probes must all be stored")

    # The service image.
    assert_equal(got.service_digest(), String(_SVC_A))
    assert_equal(got.artifact_digest(String("shop-svc")), String(_SVC_A))

    # BOTH probes, by their `from_build` names, with role + ref preserved.
    assert_equal(
        got.artifact_digest(String("smoke_validator")), String(_PROBE_1)
    )
    assert_equal(
        got.artifact_digest(String("contract_validator")), String(_PROBE_2)
    )
    var probe_roles = 0
    var refs_ok = 0
    for i in range(len(got.artifacts)):
        if got.artifacts[i].role == REVISION_ROLE_PROBE:
            probe_roles += 1
            if got.artifacts[i].image_ref.find("probes/") >= 0:
                refs_ok += 1
    assert_equal(probe_roles, 2, "both probes keep the `probe` role")
    assert_equal(refs_ok, 2, "both probes keep their FULL pullable ref")

    # Provenance survives the round trip too.
    assert_equal(got.git_commit, String("5e7d1c0a92"))
    assert_equal(got.built_at_us, Int64(1785000000000000))
    assert_equal(got.schema, String(REVISION_SCHEMA))
    assert_equal(got.app_id, String(_APP))
    assert_equal(got.ordinal, Int64(1))

    # A revision with NO service artifact refuses to be published FROM, loudly.
    var probes_only = List[RevisionArtifact]()
    probes_only.append(
        RevisionArtifact(
            String("smoke_validator"),
            String(REVISION_ROLE_PROBE),
            String(_PROBE_1),
            String(""),
        )
    )
    var po = store.mint(
        String("probeonly"),
        probes_only^,
        String("dead"),
        String("probeonly"),
        Int64(1),
    )
    with assert_raises(contains="carries no `service`-role artifact"):
        var _d = po.record.service_digest()
    print("  test_revision_round_trips_its_full_artifact_set: PASS")


# =============================================================================
# The allocator's own invariants.
# =============================================================================
def test_mint_first_is_r1_and_sets_head() raises:
    """A mint on an EMPTY store yields `<app>-r1` and writes HEAD. RED if the
    allocator seeds from 0, or mints without publishing the pointer (which would
    make every subsequent build start over at r1 and 412-storm)."""
    var store = _new_store()
    var out = store.mint(
        String(_APP),
        _service_only(String(_SVC_A)),
        String("aaaa"),
        String(_APP),
        Int64(7),
    )
    assert_equal(out.record.revision_id, String("shop-r1"))
    assert_equal(out.record.ordinal, Int64(1))
    assert_true(out.minted)
    assert_equal(store.head_id(String(_APP)).value(), String("shop-r1"))
    assert_equal(store.head(String(_APP)).value().revision_id, String("shop-r1"))
    print("  test_mint_first_is_r1_and_sets_head: PASS")


def test_mint_is_monotone_r1_r2_r3() raises:
    """Three mints with DIFFERENT artifacts -> r1, r2, r3, all durable, HEAD=r3.
    RED on any off-by-one or ordinal reuse."""
    var store = _new_store()
    var o1 = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP), Int64(1)
    )
    var o2 = store.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP), Int64(2)
    )
    var o3 = store.mint(
        String(_APP), _service_only(String(_SVC_C)), String("c"), String(_APP), Int64(3)
    )
    assert_equal(o1.record.revision_id, String("shop-r1"))
    assert_equal(o2.record.revision_id, String("shop-r2"))
    assert_equal(o3.record.revision_id, String("shop-r3"))
    assert_equal(store.head_id(String(_APP)).value(), String("shop-r3"))
    assert_equal(len(store.list_ids(String(_APP))), 3, "HEAD is not a revision")
    # Every record is still independently resolvable.
    assert_equal(
        store.resolve(String(_APP), String("shop-r1")).service_digest(),
        String(_SVC_A),
    )
    assert_equal(
        store.resolve(String(_APP), String("shop-r2")).service_digest(),
        String(_SVC_B),
    )
    print("  test_mint_is_monotone_r1_r2_r3: PASS")


def test_identical_artifacts_reuse_head_and_record_the_reproduction() raises:
    """A rebuild whose artifact set EQUALS HEAD's reuses the revision: same id,
    `minted=False`, no ordinal burned — and the rebuild's commit is APPENDED to
    `reproduced_at` while every other field is left exactly as it was.

    ⚠ THE RECORD IS IMMUTABLE EXCEPT FOR ONE APPEND-ONLY FIELD. Strict
    immutability is not free: under a gate that compares the record's commit with
    the deploying commit, a reproducible build reproduces the same bytes, reuses
    the same revision and reads back the same commit — forever — so a remedy of
    "build the artifact at this commit" can never be satisfied.

    This row pins the boundary in both directions: `reproduced_at` grew by
    exactly one entry, and `git_commit`, `built_at_us`, `ordinal` and `artifacts`
    did not move. Re-stamping `git_commit` in place would be wrong — it would
    destroy the answer to "when was this release first cut" — and this row goes
    RED against that shortcut too."""
    var store = _new_store()
    var first = store.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),
        String("5e7d1c0a92"),
        String(_APP),
        Int64(100),
    )
    var before = store.resolve(String(_APP), String("shop-r1"))
    assert_equal(
        len(before.reproduced_at),
        0,
        "a freshly minted record has reproduced nothing",
    )

    var again = store.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),  # identical bytes
        String("4f1a9c2b01"),  # ... from a LATER commit
        String(_APP),
        Int64(200),  # ... at a later time
        )
    assert_equal(again.record.revision_id, String("shop-r1"), "reuse, not r2")
    assert_false(again.minted, "an identical rebuild mints nothing")
    assert_equal(len(store.list_ids(String(_APP))), 1, "no ordinal burned")

    var after = store.resolve(String(_APP), String("shop-r1"))
    assert_equal(
        after.git_commit,
        String("5e7d1c0a92"),
        "the FIRST commit that produced these bytes is NOT re-stamped — that"
        " would destroy when the release was cut",
    )
    assert_equal(
        after.built_at_us, Int64(100), "nor is the original build time moved"
    )
    assert_equal(after.ordinal, Int64(1), "nor the ordinal")
    assert_true(
        artifacts_equal(after.artifacts, before.artifacts),
        "nor the artifact set — the ONE field that moves is the append-only one",
    )
    assert_equal(
        len(after.reproduced_at), 1, "exactly one reproduction was recorded"
    )
    assert_equal(
        String(after.reproduced_at[0]),
        String("4f1a9c2b01"),
        "and it is the commit the REBUILD ran at",
    )
    assert_true(
        after.was_built_at(String("4f1a9c2b01")),
        "so the record now answers for the rebuild's commit...",
    )
    assert_true(
        after.was_built_at(String("5e7d1c0a92")),
        "...without ceasing to answer for the original",
    )
    assert_false(
        after.was_built_at(String("cafebabe99")), "and for nothing else"
    )
    # The value handed back to `build` is the UPDATED one, not the pre-append
    # read — a caller that printed the stale record would tell the operator this
    # commit is absent from the revision's provenance when it is present.
    assert_equal(
        len(again.record.reproduced_at),
        1,
        "mint returns the record AS UPDATED",
    )
    print(
        "  test_identical_artifacts_reuse_head_and_record_the_reproduction: PASS"
    )


def test_rebuilding_at_the_same_commit_rewrites_nothing() raises:
    """The steady state: a rebuild at the SAME commit the record already names
    records nothing and leaves the stored bytes byte-identical.

    `build` runs repeatedly at one commit — the CI loop, a retried deploy, an
    operator re-running after a transient. Appending on every one of those would
    grow the record without bound and burn a store write per no-op. RED against a
    fix that appends unconditionally.

    This is also the row that keeps the ORIGINAL "the record is not rewritten"
    assertion alive for the case where it is still exactly right."""
    var store = _new_store()
    _ = store.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),
        String("5e7d1c0a92"),
        String(_APP),
        Int64(100),
    )
    var before = revision_json(store.resolve(String(_APP), String("shop-r1")))
    _ = store.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),
        String("5e7d1c0a92"),  # the SAME commit
        String(_APP),
        Int64(200),
    )
    var after = revision_json(store.resolve(String(_APP), String("shop-r1")))
    assert_equal(
        before, after, "a rebuild at the recorded commit rewrites nothing"
    )
    assert_true(
        after.find(String("reproducedAt")) < 0,
        "and the field is not even emitted — an untouched record stays"
        " byte-identical to what the pre-`reproducedAt` encoder wrote",
    )
    print("  test_rebuilding_at_the_same_commit_rewrites_nothing: PASS")


def test_an_abbreviated_rebuild_commit_is_not_recorded_twice() raises:
    """`_commits_name_the_same` treats an abbreviation as the same commit, and the
    APPEND path must use that same comparison — not `==`.

    A build that resolves `4f1a9c2b01` and a later one that resolves
    `4f1a9c2b0139ee...` are the same commit. RED against a fix that dedups with
    `==`, which would record both and, on a long-lived stable artifact, fill the
    bound with aliases of one commit."""
    var store = _new_store()
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("5e7d1c0a92"),
        String(_APP), Int64(100),
    )
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("4f1a9c2b01"),
        String(_APP), Int64(200),
    )
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)),
        String("4f1a9c2b0139ee77aa"),  # the SAME commit, spelled longer
        String(_APP), Int64(300),
    )
    var rec = store.resolve(String(_APP), String("shop-r1"))
    assert_equal(
        len(rec.reproduced_at),
        1,
        "an abbreviation of a recorded commit is not a second reproduction",
    )
    # ...and the same for an abbreviation of the ORIGINAL git_commit.
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("5e7d1c"),
        String(_APP), Int64(400),
    )
    assert_equal(
        len(store.resolve(String(_APP), String("shop-r1")).reproduced_at),
        1,
        "nor is an abbreviation of `git_commit` itself",
    )
    print("  test_an_abbreviated_rebuild_commit_is_not_recorded_twice: PASS")


def test_a_changed_artifact_set_records_nothing_and_mints_a_new_revision() raises:
    """THE HOLE STAYS SHUT, asserted at the STORE rather than at the gate.

    When a rebuild's digests DIFFER, nothing is appended anywhere: a new revision
    is minted and the old record still answers only for its own commit. This is
    the shape of a binary whose source changed: a rebuild produces different
    bytes, and that is what makes `reproduced_at` unable to launder an artifact
    nobody can trace to the tree.

    RED against a fix that appended the rebuild commit before comparing artifact
    sets, which is the natural shape if the append is written at the top of `mint`
    rather than inside the reuse branch."""
    var store = _new_store()
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("5e7d1c0a92"),
        String(_APP), Int64(100),
    )
    var second = store.mint(
        String(_APP),
        _service_only(String(_SVC_B)),  # DIFFERENT bytes
        String("4f1a9c2b01"),
        String(_APP),
        Int64(200),
    )
    assert_true(second.minted, "different bytes are a new release")
    assert_equal(second.record.revision_id, String("shop-r2"))

    var r1 = store.resolve(String(_APP), String("shop-r1"))
    assert_equal(
        len(r1.reproduced_at),
        0,
        "the OLD record learned nothing from a build that did not reproduce it",
    )
    assert_false(
        r1.was_built_at(String("4f1a9c2b01")),
        "and still refuses to answer for that commit — a record's provenance"
        " names only commits at which ITS OWN bytes were observed to build",
    )
    assert_equal(
        len(second.record.reproduced_at),
        0,
        "a NEWLY minted record records no reproduction either — its own"
        " `git_commit` already names the commit that built it",
    )
    print(
        "  test_a_changed_artifact_set_records_nothing_and_mints_a_new_revision:"
        " PASS"
    )


def test_reproduction_set_is_bounded() raises:
    """The append-only field cannot grow without limit.

    A stable component reproduces on every rebuild while the trunk moves dozens
    of commits a day, so an unbounded field on a record an operator reads would
    become a git log. At the bound the store WARNS and records nothing — the
    provenance notice simply lists fewer commits."""
    var store = _new_store()
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("c000000000"),
        String(_APP), Int64(1),
    )
    for i in range(MAX_REPRODUCED_COMMITS + 10):
        _ = store.mint(
            String(_APP),
            _service_only(String(_SVC_A)),
            String("d") + String(1000000 + i),
            String(_APP),
            Int64(2 + i),
        )
    var rec = store.resolve(String(_APP), String("shop-r1"))
    assert_equal(
        len(rec.reproduced_at),
        MAX_REPRODUCED_COMMITS,
        "the set stops at the bound rather than growing forever",
    )
    assert_equal(len(store.list_ids(String(_APP))), 1, "and no ordinal burned")
    print("  test_reproduction_set_is_bounded: PASS")


def test_a_record_written_before_reproduced_at_reads_as_an_empty_set() raises:
    """BACKWARD COMPATIBILITY, in the STRICT direction.

    Every record written before the field existed has no `reproducedAt` key.
    Reading one must yield an EMPTY set — which admits no
    extra commit — so an old record cannot be read into a weaker gate than the one
    it was written under. RED against a decoder that raised on the missing key
    (which would brick every existing revision) or defaulted it to anything
    else."""
    var legacy = String('{"schema":"') + REVISION_SCHEMA + String(
        '","appId":"shop","revisionId":"shop-r7","ordinal":7,'
        '"gitCommit":"5e7d1c0a92","builtAtUs":123,"bundleName":"shop",'
        '"artifacts":[{"logicalId":"svc","role":"service","digest":"sha256:'
    ) + "aa" * 32 + String('","ref":""}]}')
    var raw = List[UInt8]()
    var b = legacy.as_bytes()
    for i in range(len(b)):
        raw.append(b[i])
    var rec = decode_revision(raw, String("shop"))
    assert_equal(
        len(rec.reproduced_at), 0, "an absent `reproducedAt` reads as EMPTY"
    )
    assert_true(
        rec.was_built_at(String("5e7d1c0a92")), "its own commit still answers"
    )
    assert_false(
        rec.was_built_at(String("9f21c0aa4b")),
        "and nothing else does — an old record admits exactly what it always"
        " did",
    )
    print(
        "  test_a_record_written_before_reproduced_at_reads_as_an_empty_set:"
        " PASS"
    )


def test_reproduced_at_survives_a_codec_round_trip() raises:
    """The field is durable, in order, and does not disturb the rest of the record.

    A field that lived only in memory would make the whole design a no-op across
    the process boundary that separates `build` from `deploy` — the ONLY boundary
    it exists to cross."""
    var arts = List[RevisionArtifact]()
    arts.append(
        RevisionArtifact(
            String("svc"),
            String(REVISION_ROLE_SERVICE),
            String("sha256:") + "ab" * 32,
            String(""),
        )
    )
    var reproduced = List[String]()
    reproduced.append(String("4f1a9c2b01"))
    reproduced.append(String("9f21c0aa4b"))
    var rec = RevisionRecord(
        String(REVISION_SCHEMA), String("shop"), String("shop-r3"),
        Int64(3), String("5e7d1c0a92"), Int64(99), String("shop"),
        arts^, reproduced^,
    )
    var back = decode_revision(encode_revision(rec), String("shop"))
    assert_equal(len(back.reproduced_at), 2, "both entries survive")
    assert_equal(String(back.reproduced_at[0]), String("4f1a9c2b01"))
    assert_equal(String(back.reproduced_at[1]), String("9f21c0aa4b"))
    assert_equal(
        back.git_commit, String("5e7d1c0a92"), "and git_commit is untouched"
    )
    assert_equal(
        revision_json(back),
        revision_json(rec),
        "the encode stays byte-deterministic with the field present",
    )
    print("  test_reproduced_at_survives_a_codec_round_trip: PASS")


def test_rebuild_of_older_artifacts_mints_a_new_ordinal() raises:
    """THE REUSE BOUNDARY, pinned so nobody "improves" it later. A -> r1,
    B -> r2, then A again -> **r3**, NOT a resurrected r1.

    RED if reuse is widened into a history search. Ordinals must be monotone
    with RELEASE time because consumers treat them that way, and re-releasing
    older bytes AFTER a newer release is a genuinely distinct release event."""
    var store = _new_store()
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP), Int64(1)
    )
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP), Int64(2)
    )
    var again_a = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a2"), String(_APP), Int64(3)
    )
    assert_equal(
        again_a.record.revision_id,
        String("shop-r3"),
        "re-releasing older bytes after a newer release is a NEW release",
    )
    assert_true(again_a.minted)
    print("  test_rebuild_of_older_artifacts_mints_a_new_ordinal: PASS")


def test_create_412_probes_forward_without_respinning_on_head() raises:
    """THE SPIN-BUG FALSIFIER. After a create-412 the allocator must PROBE
    FORWARD (n+1), never re-derive n from HEAD — because the winner may not have
    advanced HEAD yet, so a re-read yields the SAME ordinal and the loser spins.

    Asserted by OP COUNT (the only way an offline test can see the difference):
    the losing mint issues a bounded handful of PUTs and GETs. Under the spin
    bug the loser burns MINT_MAX_PROBES=64 create attempts and then raises —
    so a tight bound is a real falsifier, not a decoration.

    Setup is the concurrent window: r1 and r2 exist; HEAD is rolled back to r1."""
    var shared = SharedInMemoryConditionalStore()
    var seeder = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = seeder.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP), Int64(1)
    )
    _ = seeder.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP), Int64(2)
    )
    # Roll HEAD back: the loser observes a stale pointer.
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")), _bytes(String("shop-r1\n"))
    )

    shared.reset_op_counts()
    var loser = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var out = loser.mint(
        String(_APP), _service_only(String(_SVC_C)), String("c"), String(_APP), Int64(3)
    )
    var puts = shared.n_put()
    var gets = shared.n_get()

    assert_equal(out.record.revision_id, String("shop-r3"))
    assert_true(
        puts <= Int64(8),
        String("bounded create attempts; got ") + String(puts),
    )
    assert_true(
        gets <= Int64(8),
        String("no HEAD re-read spin; got ") + String(gets) + String(" gets"),
    )
    print(
        "  test_create_412_probes_forward_without_respinning_on_head: PASS"
        " (puts="
        + String(puts)
        + " gets="
        + String(gets)
        + ")"
    )


def test_concurrent_identical_artifacts_converge_on_one_record() raises:
    """Two builders fire `kci shop build` on the SAME tree. The
    loser 412s, reads the winner's record, sees IDENTICAL artifacts, and returns
    the winner's id having written nothing. Both operators are told `shop-r1`
    and exactly ONE record exists.

    RED if the loser mints a duplicate ordinal for identical bytes — two release
    records for one release."""
    var shared = SharedInMemoryConditionalStore()
    var a = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var out_a = a.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),
        String("5e7d1c0a92"),
        String(_APP),
        Int64(1),
    )
    # Roll HEAD back so B genuinely races on ordinal 1.
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")), _bytes(String("\n"))
    )
    var b = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var out_b = b.mint(
        String(_APP),
        _service_and_probes(String(_SVC_A)),
        String("5e7d1c0a92"),
        String(_APP),
        Int64(2),
    )
    assert_equal(out_a.record.revision_id, String("shop-r1"))
    assert_equal(out_b.record.revision_id, String("shop-r1"))
    assert_false(out_b.minted, "the loser adopted the concurrent twin")
    assert_equal(len(b.list_ids(String(_APP))), 1, "exactly ONE record")
    assert_equal(b.head_id(String(_APP)).value(), String("shop-r1"))
    print("  test_concurrent_identical_artifacts_converge_on_one_record: PASS")


def test_crash_between_record_and_head_self_heals() raises:
    """The crash window — an accepted and pinned residual. A machine created r1's record
    and DIED before advancing HEAD. The next mint of the SAME artifacts adopts
    r1 AND repairs HEAD.

    RED if the orphan is never adopted (which would mint r2 for bytes that
    already have a durable record, and leave HEAD permanently unset)."""
    var shared = SharedInMemoryConditionalStore()
    var seeder = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    var rec = RevisionRecord(
        String(REVISION_SCHEMA),
        String(_APP),
        String("shop-r1"),
        Int64(1),
        String("crash01"),
        Int64(1),
        String(_APP),
        _service_only(String(_SVC_A)),
    )
    # The record lands; HEAD never does (the crash window).
    _ = shared.conditional_put(
        Path.parse(String("revisions/shop/shop-r1")),
        encode_revision(rec),
        WritePrecondition.if_none_match_star(),
    )
    assert_false(Bool(seeder.head_id(String(_APP))), "HEAD is unset — the crash")

    var healed = seeder.mint(
        String(_APP),
        _service_only(String(_SVC_A)),
        String("later99"),
        String(_APP),
        Int64(2),
    )
    assert_equal(healed.record.revision_id, String("shop-r1"))
    assert_false(healed.minted, "the orphan was ADOPTED, not duplicated")
    assert_equal(
        seeder.head_id(String(_APP)).value(),
        String("shop-r1"),
        "HEAD self-healed",
    )
    print("  test_crash_between_record_and_head_self_heals: PASS")


def test_head_advance_declines_to_move_backwards() raises:
    """HEAD only ever moves FORWARD (monotone-max). Setup: r1 exists, but HEAD
    claims `shop-r5` (a faster machine's write). A mint that ADOPTS r1 must
    leave HEAD at r5 — it must not pull the pointer back to r1.

    RED if HEAD is a blind last-writer-wins put: a slower machine would walk the
    pointer backwards, and the next mint would then start below the true max and
    412-storm its way back up to it."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP), Int64(1)
    )
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")), _bytes(String("shop-r5\n"))
    )
    # The SAME artifacts again: the allocator collides on r1, adopts it, and
    # asks HEAD to advance to ordinal 1 — which is BEHIND the stored r5.
    var adopt = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a2"), String(_APP), Int64(2)
    )
    assert_equal(adopt.record.revision_id, String("shop-r1"), "adopted r1")
    assert_false(adopt.minted, "no new record for identical bytes")
    assert_equal(
        store.head_id(String(_APP)).value(),
        String("shop-r5"),
        "HEAD must NOT walk backwards from r5 to r1",
    )
    # And the mint SUCCEEDED anyway — a HEAD that could not be advanced is never
    # allowed to fail a build (HEAD is a cache; the record is the truth).
    assert_equal(adopt.record.service_digest(), String(_SVC_A))
    print("  test_head_advance_declines_to_move_backwards: PASS")


def test_torn_head_pointing_at_nothing_is_survivable() raises:
    """A HEAD that points at a record that 404s (or at garbage) must
    NOT brick the app. It is a CACHE: treat it as unknown, probe from 1, walk
    forward to the true max.

    RED if a torn HEAD raises: every subsequent build of that app would fail
    with no operator-visible repair path."""
    var shared = SharedInMemoryConditionalStore()
    var store = RevisionStore[SharedInMemoryConditionalStore](shared.clone())
    _ = store.mint(
        String(_APP), _service_only(String(_SVC_A)), String("a"), String(_APP), Int64(1)
    )
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")),
        _bytes(String("shop-r77\n")),  # points at a record that does not exist
    )
    var out = store.mint(
        String(_APP), _service_only(String(_SVC_B)), String("b"), String(_APP), Int64(2)
    )
    assert_equal(out.record.revision_id, String("shop-r2"), "walked to the max")
    # Outright garbage (not even this app's id shape) is equally survivable —
    # AND, unlike the r77 case, it is safe to overwrite (it parses as no
    # ordinal at all, so monotone-max cannot be violated by replacing it).
    _ = shared.put(
        Path.parse(String("revisions/shop/HEAD")),
        _bytes(String("garbage-not-an-id\n")),
    )
    var out2 = store.mint(
        String(_APP), _service_only(String(_SVC_C)), String("c"), String(_APP), Int64(3)
    )
    assert_equal(out2.record.revision_id, String("shop-r3"))
    assert_equal(
        store.head_id(String(_APP)).value(),
        String("shop-r3"),
        "a garbage HEAD is repaired, not preserved",
    )
    print("  test_torn_head_pointing_at_nothing_is_survivable: PASS")


# =============================================================================
# The pure core: id format, codec, set equality.
# =============================================================================
def test_ordinal_of_requires_the_app_id() raises:
    """`ordinal_of` takes the app id because the READER ALWAYS KNOWS IT (it is a
    path segment of the key). RED against any `rfind("-r")` heuristic: the
    hyphenated app id is the killer input."""
    assert_equal(ordinal_of(String("shop"), String("shop-r14")), Int64(14))
    assert_equal(
        ordinal_of(
            String("orders-coordinator"), String("orders-coordinator-r7")
        ),
        Int64(7),
        "a HYPHENATED app id parses exactly — no rfind heuristic",
    )
    # A foreign app's id is refused, not silently reinterpreted.
    with assert_raises(contains="is not a revision of app 'shop'"):
        var _a = ordinal_of(String("shop"), String("cart-r3"))
    # `rfind("-r")` would happily read this as ordinal 7; we refuse it.
    with assert_raises(contains="is not a revision of app"):
        var _b = ordinal_of(String("orders"), String("orders-coordinator-r7"))
    with assert_raises(contains="non-numeric ordinal"):
        var _c = ordinal_of(String("shop"), String("shop-rXY"))
    with assert_raises(contains="no ordinal after"):
        var _d = ordinal_of(String("shop"), String("shop-r"))
    assert_equal(format_revision_id(String("shop"), Int64(14)), String("shop-r14"))
    print("  test_ordinal_of_requires_the_app_id: PASS")


def test_codec_roundtrip_rejects_an_ordinal_that_disagrees_with_its_id() raises:
    """`ordinal` is STORED, and VALIDATED against `revision_id` on decode. RED if
    a reader silently re-derives one from the other — that is a hand-maintained
    parallel map, and here it would make the release ORDER a guess."""
    var rec = RevisionRecord(
        String(REVISION_SCHEMA),
        String(_APP),
        String("shop-r14"),
        Int64(14),
        String("5e7d1c0a92"),
        Int64(1785000000000000),
        String(_APP),
        _service_and_probes(String(_SVC_A)),
    )
    var back = decode_revision(encode_revision(rec), String(_APP))
    assert_equal(back.revision_id, String("shop-r14"))
    assert_equal(back.ordinal, Int64(14))
    assert_equal(len(back.artifacts), 3)
    assert_equal(back.artifacts[0].logical_id, rec.artifacts[0].logical_id)

    # A record whose stored ordinal disagrees with its id FAILS decode.
    var bad = RevisionRecord(
        String(REVISION_SCHEMA),
        String(_APP),
        String("shop-r14"),
        Int64(9),
        String("x"),
        Int64(1),
        String(_APP),
        _service_only(String(_SVC_A)),
    )
    with assert_raises(contains="refusing to guess which is the release order"):
        var _r = decode_revision(encode_revision(bad), String(_APP))

    # A foreign/unknown schema is refused rather than half-read.
    var future = RevisionRecord(
        String("kci.revision.v9"),
        String(_APP),
        String("shop-r14"),
        Int64(14),
        String("x"),
        Int64(1),
        String(_APP),
        _service_only(String(_SVC_A)),
    )
    with assert_raises(contains="unknown record schema"):
        var _r2 = decode_revision(encode_revision(future), String(_APP))

    # A record filed under the wrong app is a corrupted ledger, not a rename.
    with assert_raises(contains="the revision ledger is corrupted"):
        var _r3 = decode_revision(encode_revision(rec), String("cart"))
    print(
        "  test_codec_roundtrip_rejects_an_ordinal_that_disagrees_with_its_id:"
        " PASS"
    )


def test_codec_is_byte_deterministic() raises:
    """Two encodes of an EQUAL record are byte-identical, and artifact ORDER at
    the input does not change the bytes. RED if an unordered container sneaks
    in — determinism is what lets the reuse test assert "the stored bytes were
    not rewritten"."""
    var a = _service_and_probes(String(_SVC_A))
    var b = _service_and_probes(String(_SVC_A))
    # Shuffle b's order.
    b.swap_elements(0, 2)
    sort_artifacts(a)
    sort_artifacts(b)
    var ra = RevisionRecord(
        String(REVISION_SCHEMA), String(_APP), String("shop-r1"), Int64(1),
        String("c"), Int64(5), String(_APP), a^,
    )
    var rb = RevisionRecord(
        String(REVISION_SCHEMA), String(_APP), String("shop-r1"), Int64(1),
        String("c"), Int64(5), String(_APP), b^,
    )
    assert_equal(revision_json(ra), revision_json(rb))
    assert_equal(revision_json(ra), revision_json(ra))
    print("  test_codec_is_byte_deterministic: PASS")


def test_artifact_set_equality_ignores_ref_and_order() raises:
    """Set equality is `(logical_id, role, digest)` after sorting. `image_ref` is
    EXCLUDED — it is a rendering of digest + repo, and a registry move must not
    mint a phantom revision. A DIGEST change is of course unequal."""
    var a = _service_and_probes(String(_SVC_A))
    var b = _service_and_probes(String(_SVC_A))
    b.swap_elements(0, 1)
    assert_true(artifacts_equal(a, b), "order does not matter")
    # A pure REF change (registry move) is still the same release.
    var moved = List[RevisionArtifact]()
    for i in range(len(b)):
        moved.append(
            RevisionArtifact(
                b[i].logical_id.copy(),
                b[i].role.copy(),
                b[i].digest.copy(),
                String("some-other-registry.example/x@") + b[i].digest,
            )
        )
    assert_true(artifacts_equal(a, moved), "a repo rename is not a new revision")
    # A DIGEST change is a different release.
    var retagged = List[RevisionArtifact]()
    for i in range(len(b)):
        var d = String(_SVC_B) if i == 0 else b[i].digest.copy()
        retagged.append(
            RevisionArtifact(
                b[i].logical_id.copy(), b[i].role.copy(), d^, b[i].image_ref.copy()
            )
        )
    assert_false(artifacts_equal(a, retagged))
    # A missing artifact is a different release (the probe-dropped case).
    var short = _service_only(String(_SVC_A))
    assert_false(
        artifacts_equal(a, short),
        "dropping a probe from the set is a DIFFERENT revision",
    )
    print("  test_artifact_set_equality_ignores_ref_and_order: PASS")


def test_merge_artifacts_dedups_by_logical_id_and_role() raises:
    """The two feeders (pinned manifest nodes, bundle validate probes) merge
    without duplicating a `(logical_id, role)` — a duplicate would make an
    otherwise identical rebuild compare UNEQUAL and burn an ordinal every
    build."""
    var svc = _service_only(String(_SVC_A))
    var probes = List[RevisionArtifact]()
    probes.append(
        RevisionArtifact(
            String("smoke_validator"), String(REVISION_ROLE_PROBE),
            String(_PROBE_1), String(""),
        )
    )
    probes.append(
        RevisionArtifact(  # a duplicate of the service entry
            String("shop-svc"), String(REVISION_ROLE_SERVICE),
            String(_SVC_A), String(""),
        )
    )
    var merged = merge_artifacts(svc^, probes)
    assert_equal(len(merged), 2, "the duplicate service entry was dropped")
    # A web_content artifact with the SAME logical id but a different role is
    # NOT a duplicate.
    var web = List[RevisionArtifact]()
    web.append(
        RevisionArtifact(
            String("shop-svc"), String(REVISION_ROLE_WEB_CONTENT),
            String("content-sha256:abc"), String(""),
        )
    )
    var merged2 = merge_artifacts(merged^, web)
    assert_equal(len(merged2), 3, "role is part of the identity")
    print("  test_merge_artifacts_dedups_by_logical_id_and_role: PASS")


def test_per_app_keyspaces_do_not_collide() raises:
    """Two apps mint independently in one bucket: each gets its OWN r1, and
    neither app's HEAD or listing sees the other's records. RED if the key
    layout drops the `<app_id>/` segment."""
    var store = _new_store()
    var e = store.mint(
        String("shop"), _service_only(String(_SVC_A)), String("a"), String("shop"), Int64(1)
    )
    var b = store.mint(
        String("cart"), _service_only(String(_SVC_B)), String("b"), String("cart"), Int64(2)
    )
    assert_equal(e.record.revision_id, String("shop-r1"))
    assert_equal(b.record.revision_id, String("cart-r1"))
    assert_equal(len(store.list_ids(String("shop"))), 1)
    assert_equal(len(store.list_ids(String("cart"))), 1)
    assert_equal(store.head_id(String("shop")).value(), String("shop-r1"))
    assert_equal(store.head_id(String("cart")).value(), String("cart-r1"))
    print("  test_per_app_keyspaces_do_not_collide: PASS")


# -----------------------------------------------------------------------------
def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def main() raises:
    # The three falsifiers first — they are the reason this file exists.
    test_concurrent_mint_does_not_clobber_the_winner()
    test_resolve_unknown_revision_is_an_honest_error()
    test_revision_round_trips_its_full_artifact_set()
    # The allocator's invariants.
    test_mint_first_is_r1_and_sets_head()
    test_mint_is_monotone_r1_r2_r3()
    test_identical_artifacts_reuse_head_and_record_the_reproduction()
    # the reproducible-build rows: reuse now RECORDS the rebuild's
    # commit, which is what makes the deploy provenance gate satisfiable.
    test_rebuilding_at_the_same_commit_rewrites_nothing()
    test_an_abbreviated_rebuild_commit_is_not_recorded_twice()
    test_a_changed_artifact_set_records_nothing_and_mints_a_new_revision()
    test_reproduction_set_is_bounded()
    test_a_record_written_before_reproduced_at_reads_as_an_empty_set()
    test_reproduced_at_survives_a_codec_round_trip()
    test_rebuild_of_older_artifacts_mints_a_new_ordinal()
    test_create_412_probes_forward_without_respinning_on_head()
    test_concurrent_identical_artifacts_converge_on_one_record()
    test_crash_between_record_and_head_self_heals()
    test_head_advance_declines_to_move_backwards()
    test_torn_head_pointing_at_nothing_is_survivable()
    # The two robustness defects: a winner whose body is not yet
    # visible, and a lost HEAD past the probe ceiling.
    test_mint_probes_past_a_winner_whose_body_is_not_yet_visible()
    test_mint_probes_past_a_winner_whose_body_is_half_written()
    test_resolve_of_an_unreadable_record_still_raises()
    test_mint_survives_a_head_pointing_at_an_unreadable_record()
    test_mint_recovers_when_head_is_lost_past_the_probe_ceiling()
    test_reuse_still_works_through_a_reconstructed_head()
    test_recovered_floor_is_the_max_ordinal_not_the_record_count()
    test_mint_recovers_when_head_was_restored_far_behind()
    test_a_healthy_head_mint_issues_no_listing()
    # The pure core.
    test_ordinal_of_requires_the_app_id()
    test_codec_roundtrip_rejects_an_ordinal_that_disagrees_with_its_id()
    test_codec_is_byte_deterministic()
    test_artifact_set_equality_ignores_ref_and_order()
    test_merge_artifacts_dedups_by_logical_id_and_role()
    test_per_app_keyspaces_do_not_collide()
    print("test_kci_revision_store: ALL PASS")
