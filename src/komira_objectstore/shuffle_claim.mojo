# =============================================================================
# komira_objectstore/shuffle_claim.mojo
#   The PULL-VIA-CLAIM primitive — the elastic half of disaggregated shuffle
#   execution.
# =============================================================================
#
# WHAT THIS IS. A VARIABLE number of reducer workers may run over the SAME
# durable, sealed map output. To process each of the R partitions EXACTLY ONCE
# regardless of how many reducers run (elasticity), the reducers PULL work by
# CLAIMING a partition: each worker loops 0..R and tries to `claim_partition`;
# the worker that WINS the claim owns + processes that partition; losers move on
# to the next partition-id. With N workers the R partitions are partitioned among
# them by who-claims-first — none missed, none double-processed.
#
# -----------------------------------------------------------------------------
# THE LOAD-BEARING SAFETY PROPERTY — CREATE-CAS ONLY
# -----------------------------------------------------------------------------
# The claim is a CREATE-CAS write: `conditional_put(..., if_none_match_star())`
# creates a brand-new `_claims/{partition_id}` object only if it is ABSENT. On
# `LocalFsConditionalStore` this maps to `open(O_CREAT|O_EXCL)` — the kernel
# guarantees EXACTLY ONE creator wins ATOMICALLY across SEPARATE processes
# (see `local_fs_conditional_store.mojo`). This is the SAME create-CAS
# single-winner the seal protocol relies on, so a claim inherits the identical
# cross-process correctness the seal has.
#
# It is CREATE-CAS ONLY. It NEVER uses `If-Match` / read-modify-write /
# mutate-in-place: the LocalFs If-Match advance has a read-compare-rename window
# that is NOT strictly cross-process linearizable (see its module header). A claim
# is a fresh object create — never an update of an existing one — so it sidesteps
# that caveat entirely. Each partition's claim is its OWN distinct key; a claim
# is won once and is then permanently present (the loser sees the 412/EEXIST).
#
# LEASE / REAPING IS OUT OF SCOPE here. This primitive is the basic
# single-winner claim: it does NOT handle a reducer that dies WHILE holding a
# claim (its partition would stay claimed-but-unprocessed). The elastic
# no-fault case needs only the single-winner claim; re-claiming from a dead
# reducer needs lease-via-heartbeat-staleness reaping, which is not built.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — `store` is passed by `ref` (the
#     concrete conformer's value), the claim body flows as an owned `List[UInt8]`,
#     and the result is a plain `Bool`.
#   * ZERO wildcard origins. ZERO `unsafe_from_address=Int`. ZERO `take_pointee`.
# * heap-reuse N/A: no struct fields (free functions only); transient values.
# =============================================================================

from komira_objectstore.cas_manifest import _is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition


# -----------------------------------------------------------------------------
# Prefix derivation — the claim family roots at `{shuffle_id}/{step_id}/_claims`,
# a sibling of the `_entries` / `_seal` manifest prefixes. Each
# partition's claim is its own distinct object `_claims/{partition_id}`.
# -----------------------------------------------------------------------------


def claims_prefix(shuffle_id: Int64, step_id: Int64) -> String:
    """The `{shuffle_id}/{step_id}/_claims` prefix (sibling of `_entries` /
    `_seal`). One claim object per partition lives directly under it."""
    return String(shuffle_id) + "/" + String(step_id) + "/_claims"


def claim_key(shuffle_id: Int64, step_id: Int64, partition_id: Int64) -> String:
    """The `{shuffle_id}/{step_id}/_claims/{partition_id}` claim object key.
    Distinct per partition — a claim never mutates an existing key, it creates a
    brand-new one (create-CAS only)."""
    return (
        claims_prefix(shuffle_id, step_id) + "/" + String(partition_id)
    )


# -----------------------------------------------------------------------------
# claim_partition — the CREATE-CAS single-winner partition claim.
# -----------------------------------------------------------------------------


def claim_partition[
    S: ConditionalWriteStore
](
    store: S,
    shuffle_id: Int64,
    step_id: Int64,
    partition_id: Int64,
) raises -> Bool:
    """Attempt to CLAIM `partition_id` for this caller. Returns True iff THIS
    caller WON the claim (created the `_claims/{partition_id}` object); False if
    the partition was ALREADY claimed by another caller (a 412 / EEXIST loser).

    The claim is a CREATE-CAS write — `conditional_put` with
    `WritePrecondition.if_none_match_star()` (create-if-absent). On
    `LocalFsConditionalStore` this is `open(O_CREAT|O_EXCL)`: the kernel admits
    EXACTLY ONE creator atomically across SEPARATE processes, so concurrent
    reducer processes racing the same partition resolve to a single winner. The
    loser's `conditional_put` raises the precondition (412) Error, which this
    function catches and reports as `False` (not won — move to the next
    partition).

    CREATE-CAS ONLY: this NEVER uses `If-Match` / read-modify-write — the claim
    is a fresh object create, never an update, so it inherits the seal's
    cross-process single-winner correctness and avoids the LocalFs If-Match
    non-linearizable window.

    The claim body is a tiny non-empty marker (so the object is present + has a
    stable content etag); the body content is NOT load-bearing — only the
    PRESENCE of the object matters (a claimed partition is a present key).
    """
    var key = Path.parse(claim_key(shuffle_id, step_id, partition_id))
    var body = _claim_marker(partition_id)
    try:
        # Create-if-absent: the linearization point is the O_CREAT|O_EXCL create.
        # The winner's create succeeds; every later/racing creator sees a 412.
        var _meta = store.conditional_put(
            key, body^, WritePrecondition.if_none_match_star()
        )
        _ = _meta^
        return True
    except e:
        # A precondition (412) / exclusive-create-lost is the EXPECTED loser
        # outcome (someone else already claimed this partition). Any OTHER error
        # (transport / permission / out-of-space / a torn create) is NOT a claim
        # loss — re-raise so the caller does NOT silently skip a partition it
        # could have owned. FAIL CLOSED: classify a precondition POSITIVELY (the
        # canonical `_is_precondition`, which also matches the 'Precondition' /
        # 'PreconditionFailed' casings the prior hand-rolled two-substring check
        # missed, and is correct across the S3 / GCS / Azure conformers too — not
        # just LocalFs); RE-RAISE everything else. Without this a real IO failure
        # would fake-412 -> return False -> the worker skips a partition that NO
        # worker claimed -> silent data loss.
        # `String(e)` consumes `e` (Error is not ImplicitlyCopyable), so re-raise
        # a FRESH Error carrying its already-extracted text.
        var msg = String(e)
        if _is_precondition(msg):
            return False
        raise Error(msg)


def is_partition_claimed[
    S: ConditionalWriteStore
](
    store: S,
    shuffle_id: Int64,
    step_id: Int64,
    partition_id: Int64,
) raises -> Bool:
    """True iff `partition_id` already has a claim object present. A read-only
    probe (HEAD) — does NOT claim. Useful for an observer / GC to enumerate which
    partitions are claimed without taking them.

    NOTE — this bare-except CONFLATES 'claim absent' (a real 404 — not claimed)
    with 'transient HEAD failure' (transport / permission), both reported as
    False. That is acceptable for the read-only probe TODAY because this function
    has NO callers yet. The FUTURE GC / reaper caller (the lease-via-heartbeat-
    staleness reaping) MUST distinguish the two: a
    transient HEAD failure must NOT be treated as 'unclaimed' (that would let the
    reaper re-assign a partition a live worker still holds). When that caller is
    written, classify the error here (404 vs transient) and surface the transient
    case to the caller instead of swallowing it. Do NOT wire this until then.
    """
    var key = Path.parse(claim_key(shuffle_id, step_id, partition_id))
    try:
        var _meta = store.head(key)
        _ = _meta^
        return True
    except:
        return False


# -----------------------------------------------------------------------------
# The claim marker body — a tiny deterministic non-empty payload. Only the
# PRESENCE of the claim object is load-bearing; the bytes are a human-legible
# marker so a `find`/`cat` over the shared dir shows which partition each claim
# object is for. Kept private (the body is an implementation detail).
# -----------------------------------------------------------------------------


def _claim_marker(partition_id: Int64) -> List[UInt8]:
    var s = String("claim:") + String(partition_id)
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^
