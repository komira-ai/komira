# =============================================================================
# komira_kg_enrich/drain_lease.mojo -- the per-partition drain lease.
# =============================================================================
#
# A mutex with a time limit, held in one object per partition on a
# `CloneableConditionalWriteStore`. Two workers draining one partition at once
# would deliver its items out of order and twice, so a worker takes the lease
# first and skips the pass when another worker holds it.
#
#   * Absent: `try_acquire` creates the object (If-None-Match), epoch 1.
#   * Held and not expired by another holder: `try_acquire` returns None.
#   * Expired, or held by the same holder token: `try_acquire` replaces the
#     object with a compare-and-swap on the etag it read, epoch + 1. A racer that
#     wins the swap makes this call return None.
#   * `release` swaps the object for an expired record with the same epoch. It is
#     a compare-and-swap on the grant's etag, so a worker whose lease has already
#     been taken over (or renewed) releases nothing, and the epoch never goes
#     back: the next holder's epoch is higher than every earlier one's.
#
# The epoch on a grant is a fencing token: a caller that passes it with its
# writes lets the receiver refuse the writes of a holder whose epoch is lower.
# The time is an argument (`now_micros`), never read from a clock; a holder token
# names one worker, and two workers must not share one.
#
# There is no heartbeat. A holder that needs longer than its ttl takes the lease
# again with the same token before it expires, which bumps the epoch.
#
# Reads: the etag is read before the body, so the etag is never newer than the
# body the decision was made on. If the lease changes in between, the swap on the
# older etag fails and the caller gets None, instead of replacing a lease it did
# not see.
# =============================================================================

from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from .framing import check_identifier, check_prefix, parse_nonneg_i64, to_bytes


@fieldwise_init
struct LeaseGrant(Copyable, Movable):
    """A held lease. `epoch` is the fencing token, `expires_at_micros` the time
    after which another holder may take over, `etag` the store version that
    `release` swaps against, `key` the lease object's key."""

    var partition_id: String
    var holder_token: String
    var epoch: Int64
    var expires_at_micros: Int64
    var etag: String
    var key: String


@fieldwise_init
struct _HeldLease(Copyable, Movable):
    var holder_token: String
    var epoch: Int64
    var expires_at_micros: Int64
    var etag: String


struct DrainLease[S: CloneableConditionalWriteStore](Movable):
    """A per-partition lease over a `CloneableConditionalWriteStore`, under
    `prefix` (use a prefix of its own, not the queue's)."""

    var _store: Self.S
    var _prefix: String

    def __init__(out self, var store: Self.S, var prefix: String) raises:
        check_prefix("lease prefix", prefix)
        self._store = store^
        self._prefix = prefix^

    def _lock_key(self, partition_id: String) -> String:
        return self._prefix + String("/") + partition_id + String(".lease")

    def try_acquire(
        mut self,
        partition_id: String,
        holder_token: String,
        now_micros: Int64,
        ttl_micros: Int64,
    ) raises -> Optional[LeaseGrant]:
        """Try to take the lease of `partition_id` for `holder_token` until
        `now_micros + ttl_micros`. Returns the grant, or None when another holder
        has it unexpired or another worker won the race to take it. A store fault
        that is not a lost race is raised."""
        check_identifier("partition_id", partition_id)
        check_identifier("holder_token", holder_token)
        if now_micros < Int64(0):
            raise Error("now_micros must not be negative")
        if ttl_micros <= Int64(0):
            raise Error("ttl_micros must be positive")
        var key = self._lock_key(partition_id)
        var expires = now_micros + ttl_micros
        var cur = self._read(key)

        if not cur:
            try:
                var meta = self._store.conditional_put(
                    Path.parse(key.copy()),
                    to_bytes(_encode_lease(holder_token, Int64(1), expires)),
                    WritePrecondition.if_none_match_star(),
                )
                return Optional[LeaseGrant](
                    LeaseGrant(
                        partition_id.copy(),
                        holder_token.copy(),
                        Int64(1),
                        expires,
                        meta.etag.copy(),
                        key^,
                    )
                )
            except e:
                if is_precondition(String(e)):
                    return Optional[LeaseGrant]()
                raise e^

        var held = cur.value().copy()
        if now_micros < held.expires_at_micros and (
            held.holder_token != holder_token
        ):
            return Optional[LeaseGrant]()

        var next_epoch = held.epoch + Int64(1)
        try:
            var meta = self._store.compare_and_swap(
                Path.parse(key.copy()),
                to_bytes(_encode_lease(holder_token, next_epoch, expires)),
                held.etag.copy(),
            )
            return Optional[LeaseGrant](
                LeaseGrant(
                    partition_id.copy(),
                    holder_token.copy(),
                    next_epoch,
                    expires,
                    meta.etag.copy(),
                    key^,
                )
            )
        except e:
            var msg = String(e)
            if is_precondition(msg) or is_not_found(msg):
                return Optional[LeaseGrant]()
            raise e^

    def release(mut self, grant: LeaseGrant) raises:
        """Give the lease up: swap it for an expired record of the same epoch,
        if it is still the grant's version. A lease that was taken over or
        renewed since is left alone."""
        try:
            _ = self._store.compare_and_swap(
                Path.parse(grant.key.copy()),
                to_bytes(
                    _encode_lease(grant.holder_token, grant.epoch, Int64(0))
                ),
                grant.etag.copy(),
            )
        except e:
            var msg = String(e)
            if is_precondition(msg) or is_not_found(msg):
                return
            raise e^

    def _read(self, key: String) raises -> Optional[_HeldLease]:
        """The current lease and its etag, or None when the object is absent.
        The etag is read first (see the header)."""
        var etag = String("")
        try:
            var meta = self._store.head(Path.parse(key.copy()))
            etag = meta.etag.copy()
        except e:
            if is_not_found(String(e)):
                return Optional[_HeldLease]()
            raise e^
        var bytes: List[UInt8]
        try:
            bytes = self._store.get(Path.parse(key.copy()))
        except e:
            if is_not_found(String(e)):
                return Optional[_HeldLease]()
            raise e^
        var raw = String(StringSlice(from_utf8=Span(bytes)))
        return Optional[_HeldLease](_decode_lease(raw, etag^, key))


def _encode_lease(holder_token: String, epoch: Int64, expires: Int64) -> String:
    """`<holder token>\\n<epoch>\\n<expires at micros>`."""
    return (
        holder_token
        + String("\n")
        + String(epoch)
        + String("\n")
        + String(expires)
    )


def _decode_lease(
    raw: String, var etag: String, key: String
) raises -> _HeldLease:
    var parts = raw.split(String("\n"))
    if len(parts) != 3:
        raise Error("malformed lease object: " + key)
    var epoch = parse_nonneg_i64("lease epoch of " + key, String(parts[1]))
    var expires = parse_nonneg_i64("lease expiry of " + key, String(parts[2]))
    return _HeldLease(String(parts[0]), epoch, expires, etag^)
