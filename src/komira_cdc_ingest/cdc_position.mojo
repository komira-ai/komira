# =============================================================================
# cdc_position.mojo — per-shard stream position tracking.
# =============================================================================
#
# The last-applied stream position (the sequence number, per shard) is stamped
# INTO the Iceberg snapshot `summary` map on each commit. On startup, the resume
# point is derived by reading the latest committed snapshot's summary; there is
# no separate checkpoint store. The position write and the data write are ONE
# atomic commit:
#
#   * A crash after the Iceberg commit is a no-op on restart: the position is
#     already in the committed table, so the batch is skipped.
#   * A crash before the commit re-reads from the last committed position and
#     re-applies the batch, which is safe because apply is idempotent (an
#     equality delete by key is a no-op on an absent key; the append is guarded
#     by the sequence-number skip).
#
# The summary-key convention is one entry per shard:
#   key   = "cdc.shard.<ShardId>"
#   value = the last-applied sequence number for that shard (a decimal string).
# The whole per-shard map is re-stamped on EVERY commit, so the latest
# snapshot's summary is the complete resume map and a reader recovers every
# shard's position from the single current snapshot.
#
# Sequence comparison. Sequence numbers are bare decimal strings (digits only, no
# sign, radix or exponent) that can exceed Int64 (about 28 digits) and are not
# zero-padded to a fixed width. A byte compare is therefore wrong across different
# digit widths ("9" > "100" lexicographically but 9 < 100 numerically). `seq_gt`
# compares by numeric magnitude: strip leading zeros, then the value with more
# significant digits is larger; equal widths compare lexicographically. No bignum
# parse is needed.
#
# `ShardPositions` holds two owned `List[String]` (parallel key and value arrays,
# one entry per shard). No pointer type is used.
# =============================================================================

from komira_objectstore.store import ConditionalWriteStore

from komira_iceberg import (
    SummaryKV,
    read_current_snapshot_summary,
)


comptime CDC_SUMMARY_KEY_PREFIX: String = "cdc.shard."


# =============================================================================
# ShardPositions — the per-shard last-applied SequenceNumber map.
# =============================================================================


struct ShardPositions(Copyable, Movable, Deinitable):
    """A small per-shard map: ShardId -> last-applied SequenceNumber.

    Stored as two parallel owned `List[String]` (keys + values) — O(#shards) is
    tiny (a stream has a handful of open shards), so a linear scan is
    fine and avoids a Dict-of-String dependency. The map is the in-memory mirror
    of the positions stamped into the current snapshot's summary.

    A plain owned-field struct (two `List[String]`) with no pointer field."""

    var _shard_ids: List[String]
    var _positions: List[String]

    def __init__(out self):
        self._shard_ids = List[String]()
        self._positions = List[String]()

    def copy(self) -> Self:
        var out = Self()
        for i in range(len(self._shard_ids)):
            out._shard_ids.append(String(self._shard_ids[i]))
            out._positions.append(String(self._positions[i]))
        return out^

    @always_inline
    def num_shards(self) -> Int:
        return len(self._shard_ids)

    def get(self, shard_id: String) -> String:
        """The last-applied SequenceNumber for `shard_id`, or "" if this shard
        has no committed position yet (cold start -> resume from TRIM_HORIZON)."""
        for i in range(len(self._shard_ids)):
            if _str_eq(self._shard_ids[i], shard_id):
                return String(self._positions[i])
        return String("")

    def set(mut self, shard_id: String, var position: String):
        """Set `shard_id`'s last-applied position (insert or update). The caller
        advances this to the batch's max applied sequence before stamping the
        full map into the commit summary."""
        for i in range(len(self._shard_ids)):
            if _str_eq(self._shard_ids[i], shard_id):
                self._positions[i] = position^
                return
        self._shard_ids.append(String(shard_id))
        self._positions.append(position^)

    def has(self, shard_id: String) -> Bool:
        """True iff `shard_id` has a committed position."""
        for i in range(len(self._shard_ids)):
            if _str_eq(self._shard_ids[i], shard_id):
                return True
        return False

    def shard_id_at(self, i: Int) -> String:
        return String(self._shard_ids[i])

    def to_summary_kvs(self) -> List[SummaryKV]:
        """Serialize the WHOLE map to `cdc.shard.<id>` summary KVs (the complete
        resume map stamped into every commit's snapshot summary)."""
        var out = List[SummaryKV]()
        for i in range(len(self._shard_ids)):
            out.append(
                SummaryKV(
                    CDC_SUMMARY_KEY_PREFIX + self._shard_ids[i],
                    String(self._positions[i]),
                )
            )
        return out^

    @staticmethod
    def from_summary_kvs(summary: List[SummaryKV]) -> ShardPositions:
        """Recover the per-shard map from a snapshot summary — every
        `cdc.shard.<id>` entry becomes a (ShardId -> position) mapping. Non-cdc
        summary keys (operation / count metrics) are ignored."""
        var out = ShardPositions()
        for i in range(len(summary)):
            var k = summary[i].key
            if _starts_with(k, CDC_SUMMARY_KEY_PREFIX):
                var shard_id = _strip_prefix(k, CDC_SUMMARY_KEY_PREFIX)
                out.set(shard_id, String(summary[i].value))
        return out^


# =============================================================================
# Derive the resume point from the committed Iceberg table (the startup read).
# =============================================================================


def derive_positions_from_table[
    Store: ConditionalWriteStore, o: Origin[mut=True]
](ref [o] store: Store, location: String) raises -> ShardPositions:
    """DERIVE the per-shard resume map by reading the LATEST committed snapshot's
    summary through `store` — the exactly-once resume point.

    There is NO separate checkpoint store: the position is IN the committed
    table's snapshot summary. A never-committed table (no version-hint) yields an
    empty map -> every shard cold-starts from the stream's oldest record."""
    var summary = read_current_snapshot_summary(store, location)
    return ShardPositions.from_summary_kvs(summary)


# =============================================================================
# Sequence-number comparison (decimal strings of any width).
# =============================================================================


def seq_gt(a: String, b: String) -> Bool:
    """True iff sequence number `a` is STRICTLY GREATER than `b`.

    Sequence numbers are decimal strings that can exceed Int64 (~28
    digits). Compare by numeric magnitude: the number with more significant
    digits (after stripping leading zeros) is larger; equal digit counts compare
    lexicographically. An empty `b` (no committed position) means EVERY real
    sequence is greater (a is applied)."""
    if b.byte_length() == 0:
        return a.byte_length() > 0
    if a.byte_length() == 0:
        return False
    var sa = _strip_leading_zeros(a)
    var sb = _strip_leading_zeros(b)
    if sa.byte_length() != sb.byte_length():
        return sa.byte_length() > sb.byte_length()
    # Equal significant-digit width -> lexicographic (== numeric for decimals).
    var ab = sa.as_bytes()
    var bb = sb.as_bytes()
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return ab[i] > bb[i]
    return False  # equal


def _strip_leading_zeros(s: String) -> String:
    var bs = s.as_bytes()
    var n = len(bs)
    var i = 0
    while i < n - 1 and bs[i] == UInt8(ord("0")):
        i += 1
    var out = String("")
    while i < n:
        out += chr(Int(bs[i]))
        i += 1
    return out^


# =============================================================================
# Small string helpers.
# =============================================================================


@always_inline
def _str_eq(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return False
    return True


def _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _strip_prefix(s: String, prefix: String) -> String:
    var sb = s.as_bytes()
    var out = String("")
    for i in range(prefix.byte_length(), len(sb)):
        out += chr(Int(sb[i]))
    return out^
