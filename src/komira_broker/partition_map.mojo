# =============================================================================
# komira_broker/partition_map.mojo
#   The partition-map abstraction (dynamic partition scaling)
# =============================================================================
#
# The versioned `partition_map.json` object that mediates routing +
# partition-set enumeration, sitting BETWEEN the topic config (`config.json`)
# and the per-partition manifests.
#
# -----------------------------------------------------------------------------
# WHAT THE MAP CARRIES
# -----------------------------------------------------------------------------
#   * the PartitionMap struct (versioned, mode-flagged, ordered hash-ranges),
#     the `fixed(N)` static equal-width map, high-bits-range ROUTING
#     (`range_containing_pid`), JSON encode/decode, and object-store
#     persistence (create-if-absent on first topic write; read on consume).
#   * split/merge lineage (parent->child edges and retired-range tombstones)
#     for `auto`-mode topics. A `fixed` map is written ONCE at topic creation
#     and never mutated; an `auto` map changes only through the versioned
#     `If-Match` UPDATE (`persist_update`).
#
# -----------------------------------------------------------------------------
# THE ROUTING — high-bits range, NOT `% N`
# -----------------------------------------------------------------------------
# A key's pid is the range its FULL 64-bit fnv1a hash falls into,
# `partition_id = map.range_containing_pid(fnv1a(key))`, not
# `fnv1a(key) % num_partitions` (the low bits). For a fixed equal-width map of
# N ranges this is `floor(hash / (2^64 / N))` clamped to N-1 — i.e. the high
# bits of `hash`. This is the CANONICAL reduction so a broker range map and the
# engine's `% P` shuffle index the SAME hash space with the SAME canonical
# hash.
#
# -----------------------------------------------------------------------------
# THE u64 HASH-SPACE REPRESENTATION SUBTLETY (the one real gotcha)
# -----------------------------------------------------------------------------
# The map covers the FULL `[0, 2^64)` hash space, but `2^64` is NOT
# representable in a UInt64 (it overflows). So a half-open `[lo, hi)` cannot
# carry an exclusive upper bound of `2^64` directly. The representation:
#   * each range stores `hash_lo: UInt64` (inclusive) + `hash_hi: UInt64`.
#   * for every NON-LAST range, `hash_hi` is the genuine exclusive upper bound
#     (the next range's `hash_lo`).
#   * for the LAST range, `hash_hi` is stored as `UInt64.MAX` and is treated as
#     INCLUSIVE (semantically `2^64` exclusive). The last range therefore
#     absorbs the `2^64 % N` remainder quantum — it is the widest range when N
#     does not evenly divide 2^64.
# `range_containing_pid` honors this: a hash matches range i iff
#   `hash >= lo_i AND (i is last OR hash < hi_i)`.
# This keeps the space gap-free + total (every u64 maps to exactly one pid) with
# no overflow.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — PartitionMap is a plain Movable +
#     Copyable value (an Int version/epoch + a mode flag + a List[HashRange] of
#     small POD range structs). No pointers needed anywhere.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * PartitionMap is a stack value, NOT a byte-slab element. Its
#     only heap-owning field is a `List[HashRange]` of POD (3 scalars) — never
#     stored in an OwnedSlab/AtomicSlab/MutableArray with a wildcard cast.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition


# =============================================================================
# Mode flag — the `auto` vs `fixed` axis.
# =============================================================================
#
# Recorded on every map so the scaler + the native/Kafka distinction have the
# field to read. `auto` topics start as a 1-range full-space map that
# splits/merges; `fixed` (Kafka CreateTopics) is N immutable equal-width
# ranges that never scale.

comptime PARTITION_MODE_FIXED: UInt8 = 0
comptime PARTITION_MODE_AUTO: UInt8 = 1

# The canonical hash id pinned into the map — fnv1a-64. Recorded
# so a reader can verify the ranges index the hash it computes.
comptime PARTITION_MAP_HASH_ID: String = "fnv1a64"

# The stable S3 key suffix the partition map lives at, sibling of config.json.
# `<cluster>/_meta/topics/<topic>/partition_map.json`.


def partition_map_key(cluster: String, topic: String) -> String:
    """The stable S3 key the topic's partition map lives at:
    `<cluster>/_meta/topics/<topic>/partition_map.json`. Sibling of the topic
    config (`config.json`) and the per-partition manifest prefixes."""
    return cluster + "/_meta/topics/" + topic + "/partition_map.json"


def prefix_gen_manifest_prefix(
    cluster: String, topic: String, child_pid: Int, prefix_gen_seq: Int64
) -> String:
    """The object-store manifest prefix a compacted child's PREFIX-GENERATION
    manifest lives at: `<cluster>/_meta/topics/<topic>/<child_pid>.g<gen>`
    (gen-model compaction). A SIBLING of the
    child's LIVE manifest prefix `<cluster>/_meta/topics/<topic>/<child_pid>` —
    the `.g<gen>` suffix puts it under a DIFFERENT `CasManifestStore` prefix with
    its OWN `manifest/`, `_HEAD`, `tombstones/`, `_LOG_START`. So the prefix
    generation has its own FROM-0 offset space that cannot collide with the live
    generation's `[0, hwm)` (different key prefix → no shared offset axis). The
    prefix generation is read STRICTLY BEFORE the live generation; its offsets
    are READ-ORDER coordinates, NEVER committed offsets (the live generation's
    offsets are the only committed ones)."""
    return (
        cluster
        + "/_meta/topics/"
        + topic
        + "/"
        + String(child_pid)
        + ".g"
        + String(prefix_gen_seq)
    )


@always_inline
def mode_name(mode: UInt8) -> String:
    """Human/JSON name for a partition mode flag."""
    if mode == PARTITION_MODE_AUTO:
        return String("auto")
    return String("fixed")


@always_inline
def mode_from_name(name: String) -> UInt8:
    """Parse a partition mode flag from its JSON name (default fixed)."""
    if name == "auto":
        return PARTITION_MODE_AUTO
    return PARTITION_MODE_FIXED


# =============================================================================
# HashRange — one ordered `[lo, hi)` range -> pid (POD).
# =============================================================================


comptime NO_PARENT_PID: Int = -1
comptime NO_PARENT_BASE: Int64 = -1


@fieldwise_init
struct HashRange(Copyable, Movable, Deinitable):
    """One contiguous hash-space range owned by a partition. POD (7 scalars).

    Field layout:
      var hash_lo: UInt64    — inclusive lower bound (this range owns `hash_lo`).
      var hash_hi: UInt64    — exclusive upper bound for non-last ranges; for the
                               LAST range it is `UInt64.MAX` treated INCLUSIVE
                               (semantically `2^64`). See the module header's
                               "u64 hash-space representation subtlety".
      var pid: Int           — the stable partition id this range routes to.
      var parent_pid: Int    — SPLIT LINEAGE: the pid this range was
                               SPLIT OUT OF, or `NO_PARENT_PID` (-1) for an
                               original (never-split-from) range OR a merged child
                               (which has TWO predecessors in `merge_pred_a_pid` /
                               `merge_pred_b_pid` instead). Lets a consumer of a
                               split child reconstruct read order: read the parent
                               prefix up to `parent_split_offset`, then this child
                               from its base.
      var parent_split_offset: Int64 — SPLIT LINEAGE (the freeze offset X):
                               the split parent's committed offset count at
                               the moment of the split. `NO_PARENT_BASE` (-1) for
                               an original range OR a merged child. A LOWER BOUND
                               on the parent tail: the consumer
                               reads the parent manifest to its ACTUAL tail.
      var merge_pred_a_pid: Int — MERGE LINEAGE: for a MERGED child
                               C = merge(A, B), the LOWER-subrange predecessor pid
                               A. `NO_PARENT_PID` (-1) for a non-merged range. A
                               merged child has BOTH `merge_pred_a_pid` and
                               `merge_pred_b_pid` set; the consumer reads
                               A[0..tail] then B[0..tail] then C[0..]. The two
                               predecessors are already RANGE-PURE (disjoint
                               subranges), so NO per-row filter is needed (unlike
                               a split parent, which holds both children's rows).
      var merge_pred_b_pid: Int — MERGE LINEAGE: the UPPER-subrange
                               predecessor pid B for a merged child C. (-1) if
                               not a merged child.
      var prefix_gen_seq: Int64 — PREFIX-GENERATION (gen-model compaction): the
                               generation
                               token `<gen>` of this LIVE child's compacted PREFIX
                               GENERATION manifest, read STRICTLY BEFORE this
                               child's live generation. `NO_PARENT_BASE` (-1) ==
                               no prefix generation (the common case). When set,
                               the prefix-generation manifest lives at the SIBLING
                               key prefix derived from `(pid, prefix_gen_seq)` via
                               `prefix_gen_manifest_prefix` — a SEPARATE from-0
                               manifest (its offsets are READ-ORDER coordinates,
                               NEVER committed offsets; the live generation's
                               `[0, hwm)` offsets are physically untouched, so a
                               consumer's committed offset is stable). Additive +
                               forward-compat (a pre-gen-model map decodes it as
                               -1 == no prefix gen).
    """

    var hash_lo: UInt64
    var hash_hi: UInt64
    var pid: Int
    var parent_pid: Int
    var parent_split_offset: Int64
    var merge_pred_a_pid: Int
    var merge_pred_b_pid: Int
    var prefix_gen_seq: Int64

    @staticmethod
    def original(hash_lo: UInt64, hash_hi: UInt64, pid: Int) -> HashRange:
        """An ORIGINAL (never-split-from, never-merged) range — no lineage. The
        compat shape the `fixed(N)` map + a hand-built 1-range auto seed use
        (matches the prior 3-field `HashRange(hash_lo=, hash_hi=, pid=)` call
        sites)."""
        return HashRange(
            hash_lo=hash_lo,
            hash_hi=hash_hi,
            pid=pid,
            parent_pid=NO_PARENT_PID,
            parent_split_offset=NO_PARENT_BASE,
            merge_pred_a_pid=NO_PARENT_PID,
            merge_pred_b_pid=NO_PARENT_PID,
            prefix_gen_seq=NO_PARENT_BASE,
        )

    @staticmethod
    def split_child(
        hash_lo: UInt64,
        hash_hi: UInt64,
        pid: Int,
        parent_pid: Int,
        parent_split_offset: Int64,
    ) -> HashRange:
        """A SPLIT child range (one of two children of a split parent). Carries
        the split lineage (`parent_pid` + freeze offset X), no merge lineage."""
        return HashRange(
            hash_lo=hash_lo,
            hash_hi=hash_hi,
            pid=pid,
            parent_pid=parent_pid,
            parent_split_offset=parent_split_offset,
            merge_pred_a_pid=NO_PARENT_PID,
            merge_pred_b_pid=NO_PARENT_PID,
            prefix_gen_seq=NO_PARENT_BASE,
        )

    @staticmethod
    def merged_child(
        hash_lo: UInt64,
        hash_hi: UInt64,
        pid: Int,
        merge_pred_a_pid: Int,
        merge_pred_b_pid: Int,
    ) -> HashRange:
        """A MERGED child range (the single child of a 2->1 merge).
        Carries the merge lineage (BOTH predecessor pids), no split lineage. The
        predecessors are range-pure (disjoint subranges) so the consumer reads
        each fully with NO per-row filter."""
        return HashRange(
            hash_lo=hash_lo,
            hash_hi=hash_hi,
            pid=pid,
            parent_pid=NO_PARENT_PID,
            parent_split_offset=NO_PARENT_BASE,
            merge_pred_a_pid=merge_pred_a_pid,
            merge_pred_b_pid=merge_pred_b_pid,
            prefix_gen_seq=NO_PARENT_BASE,
        )

    @always_inline
    def has_prefix_gen(self) -> Bool:
        """True iff this live child carries a compacted PREFIX GENERATION
        (gen-model compaction) read strictly before its live generation."""
        return self.prefix_gen_seq != NO_PARENT_BASE

    def with_prefix_gen(self, prefix_gen_seq: Int64) -> HashRange:
        """A COPY of this range carrying the prefix-generation token (the
        gen-model collapse annotation). Clears the split lineage back-edges
        (`parent_pid`/`parent_split_offset`) the same way `collapse_lineage`
        does — the child now reads its OWN prefix generation instead of the
        shared parent prefix — while preserving merge lineage + bounds."""
        return HashRange(
            hash_lo=self.hash_lo,
            hash_hi=self.hash_hi,
            pid=self.pid,
            parent_pid=NO_PARENT_PID,
            parent_split_offset=NO_PARENT_BASE,
            merge_pred_a_pid=self.merge_pred_a_pid,
            merge_pred_b_pid=self.merge_pred_b_pid,
            prefix_gen_seq=prefix_gen_seq,
        )


# =============================================================================
# RetiredRange — a tombstoned parent partition (the lineage record).
# =============================================================================


comptime NO_MERGE_PID: Int = -1


@fieldwise_init
struct RetiredRange(Copyable, Movable, Deinitable):
    """A RETIRED (frozen) parent/predecessor partition — the lineage tombstone
    for BOTH a SPLIT (1->2) and a MERGE (2->1). POD.

    SPLIT tombstone: when partition `P` splits into A,B, `P` is removed from
    `ranges` and appended here with `child_a_pid`/`child_b_pid` set + `merged_
    into_pid == NO_MERGE_PID`. The split children carry `parent_pid` back-edges.

    MERGE tombstone: when adjacent A,B merge into C, BOTH A and B
    are removed from `ranges` and appended here as TWO tombstones, each with
    `merged_into_pid == C` + `child_a_pid`/`child_b_pid == NO_MERGE_PID`. The
    merged child C carries `merge_pred_a_pid`/`merge_pred_b_pid` back-edges. A
    merge tombstone's `hash_lo`/`hash_hi` are that PREDECESSOR's own (range-pure)
    subrange — so the consumer reads each predecessor fully with no row filter.

    The lineage is thus reachable from BOTH directions (child->parent via the
    HashRange fields, parent->child via this list); the read-order builder walks
    child->parent.

    Field layout:
      var pid: Int                 — the retired (frozen) pid (a split parent OR a
                                     merge predecessor).
      var hash_lo: UInt64          — the retired pid's full range lo (a split
                                     parent covers both children; a merge
                                     predecessor covers only its own subrange).
      var hash_hi: UInt64          — the retired pid's full range hi.
      var frozen_at_offset: Int64  — the freeze offset X: a
                                     LOWER BOUND on this pid's final tail. The
                                     consumer reads the manifest to its ACTUAL
                                     tail, so an in-flight flush
                                     past X is still read.
      var child_a_pid: Int         — SPLIT only: the lower-subrange child pid
                                     (`[lo, mid)`); `NO_MERGE_PID` for a merge
                                     predecessor tombstone.
      var child_b_pid: Int         — SPLIT only: the upper-subrange child pid
                                     (`[mid, hi)`); `NO_MERGE_PID` for a merge
                                     predecessor tombstone.
      var merged_into_pid: Int     — MERGE only: the merged child pid C this
                                     predecessor folded into; `NO_MERGE_PID` for
                                     a split parent tombstone. This is the
                                     discriminant: `merged_into_pid != NO_MERGE_
                                     PID` <=> a merge predecessor tombstone.
    """

    var pid: Int
    var hash_lo: UInt64
    var hash_hi: UInt64
    var frozen_at_offset: Int64
    var child_a_pid: Int
    var child_b_pid: Int
    var merged_into_pid: Int

    @staticmethod
    def split_parent(
        pid: Int,
        hash_lo: UInt64,
        hash_hi: UInt64,
        frozen_at_offset: Int64,
        child_a_pid: Int,
        child_b_pid: Int,
    ) -> RetiredRange:
        """A SPLIT-parent tombstone (1->2): records the two child pids + the
        freeze offset. `merged_into_pid == NO_MERGE_PID` marks it a split."""
        return RetiredRange(
            pid=pid,
            hash_lo=hash_lo,
            hash_hi=hash_hi,
            frozen_at_offset=frozen_at_offset,
            child_a_pid=child_a_pid,
            child_b_pid=child_b_pid,
            merged_into_pid=NO_MERGE_PID,
        )

    @staticmethod
    def merge_predecessor(
        pid: Int,
        hash_lo: UInt64,
        hash_hi: UInt64,
        frozen_at_offset: Int64,
        merged_into_pid: Int,
    ) -> RetiredRange:
        """A MERGE-predecessor tombstone (one of the two parents of a 2->1
        merge): records the merged child pid + this predecessor's
        freeze offset. `child_a_pid`/`child_b_pid == NO_MERGE_PID`."""
        return RetiredRange(
            pid=pid,
            hash_lo=hash_lo,
            hash_hi=hash_hi,
            frozen_at_offset=frozen_at_offset,
            child_a_pid=NO_MERGE_PID,
            child_b_pid=NO_MERGE_PID,
            merged_into_pid=merged_into_pid,
        )

    @always_inline
    def is_merge(self) -> Bool:
        """True iff this is a MERGE-predecessor tombstone (folded into a child),
        False iff a SPLIT-parent tombstone (forked into two children)."""
        return self.merged_into_pid != NO_MERGE_PID


# =============================================================================
# PartitionMap — the versioned, mode-flagged ordered range map.
# =============================================================================


struct PartitionMap(Copyable, Movable, Deinitable):
    """The topic's durable partition map — an ordered, gap-free, non-overlapping
    list of hash-ranges covering the full `[0, 2^64)` fnv1a-64 hash space, each
    mapping to a stable partition id. The source of truth for routing
    (`range_containing_pid`) and partition-set enumeration.

    Fields:
      var version: Int             — monotone epoch; the `If-Match` CAS guard
                                     (bumped on every split/merge). 1 for a
                                     freshly-created map.
      var mode: UInt8              — PARTITION_MODE_FIXED | PARTITION_MODE_AUTO.
                                     Only an `auto` map may `split()`.
      var ranges: List[HashRange]  — the ordered ranges (by `hash_lo` ascending),
                                     contiguous + gap-free, covering `[0, 2^64)`.
      var next_pid: Int            — the monotone pid allocator:
                                     the NEXT fresh pid a split hands a child.
                                     Children get NEW pids, never the parent's
                                     (correctness/clarity — a child manifest
                                     prefix is a fresh `<...>/<child_pid>`,
                                     never the parent's). For a `fixed(N)` map
                                     this is N (pids 0..N-1 consumed); for an
                                     `auto_seed` map it is 1.
      var retired: List[RetiredRange] — the lineage tombstones: parents that
                                     have split. Empty for a never-split map.

    INVARIANTS (held by construction + enforced by `validate`):
      * `ranges[0].hash_lo == 0`.
      * `ranges[i].hash_hi == ranges[i+1].hash_lo` for every non-last i
        (gap-free + non-overlapping).
      * `ranges[last].hash_hi == UInt64.MAX` (treated inclusive == 2^64).
    """

    var version: Int
    var mode: UInt8
    var ranges: List[HashRange]
    var next_pid: Int
    var retired: List[RetiredRange]

    def __init__(
        out self,
        version: Int,
        mode: UInt8,
        var ranges: List[HashRange],
        next_pid: Int,
        var retired: List[RetiredRange],
    ):
        self.version = version
        self.mode = mode
        self.ranges = ranges^
        self.next_pid = next_pid
        self.retired = retired^

    def __init__(out self, version: Int, mode: UInt8, var ranges: List[HashRange]):
        """Compat ctor (3-arg) used by `fixed(N)` + tests that hand-build a map.
        Derives `next_pid` as `max(pid)+1` over the supplied ranges (so a
        subsequent `split` never reuses a live pid) and starts with an empty
        `retired` list."""
        var max_pid = -1
        for i in range(len(ranges)):
            if ranges[i].pid > max_pid:
                max_pid = ranges[i].pid
        self.version = version
        self.mode = mode
        self.ranges = ranges^
        self.next_pid = max_pid + 1
        self.retired = List[RetiredRange]()

    def copy(self) -> Self:
        return Self(
            version=self.version,
            mode=self.mode,
            ranges=self.ranges.copy(),
            next_pid=self.next_pid,
            retired=self.retired.copy(),
        )

    # -------------------------------------------------------------------------
    # fixed(N) — the degenerate static equal-width map.
    # -------------------------------------------------------------------------

    @staticmethod
    def fixed(num_partitions: Int) raises -> PartitionMap:
        """Build the FIXED-mode static map: `N` equal-width ranges over the full
        `[0, 2^64)` hash space, `pid = i`, `mode = fixed`, `version = 1`.

        Range i = `[i * quantum, (i+1) * quantum)` where `quantum = 2^64 / N`,
        and the LAST range absorbs the `2^64 % N` remainder (its `hash_hi` is
        `UInt64.MAX` == inclusive `2^64`). This is the high-bits bucketing the
        routing reduction reads — and the degenerate equal-width map that
        classic Kafka `% N` falls out of under the high-bits
        reduction.

        `quantum` is computed without overflowing 2^64: `2^64 / N ==
        floor((2^64 - 1) / N)` for N >= 2 because `2^64 - 1 == N*q + r` with
        `r <= N-1 < N`, so `(2^64)/N` has the same floor. N == 1 is the single
        full-range partition `[0, 2^64)` (`hash_lo = 0`, `hash_hi = MAX`).
        """
        if num_partitions < 1:
            raise Error(
                "PartitionMap.fixed: num_partitions must be >= 1 (got "
                + String(num_partitions)
                + ")"
            )
        var ranges = List[HashRange]()
        var u64_max = UInt64.MAX
        if num_partitions == 1:
            # Single full-space range.
            ranges.append(HashRange.original(UInt64(0), u64_max, 0))
            return PartitionMap(
                version=1, mode=PARTITION_MODE_FIXED, ranges=ranges^
            )
        var n = UInt64(num_partitions)
        # quantum = floor(2^64 / N) == floor((2^64 - 1) / N) for N >= 2 (see
        # docstring). This is the equal-width quantum; each non-last range is
        # exactly `quantum` wide; the last range absorbs the remainder.
        var quantum = u64_max / n
        for i in range(num_partitions):
            var lo = quantum * UInt64(i)
            if i == num_partitions - 1:
                # Last range absorbs the remainder: hi = 2^64 (stored MAX,
                # treated inclusive).
                ranges.append(HashRange.original(lo, u64_max, i))
            else:
                var hi = quantum * UInt64(i + 1)
                ranges.append(HashRange.original(lo, hi, i))
        return PartitionMap(
            version=1, mode=PARTITION_MODE_FIXED, ranges=ranges^
        )

    # -------------------------------------------------------------------------
    # auto_seed — the AUTO-mode initial 1-range full-space map.
    # -------------------------------------------------------------------------

    @staticmethod
    def auto_seed() -> PartitionMap:
        """Build the AUTO-mode seed map: ONE full-space range `[0, 2^64)` -> pid
        0, `mode = auto`, `version = 1`, `next_pid = 1` (pid 0 consumed by the
        seed range). This is the native-pipeline topic's birth state: a single
        partition that the split mechanism + the auto-trigger grow into a
        lineage forest."""
        var ranges = List[HashRange]()
        ranges.append(HashRange.original(UInt64(0), UInt64.MAX, 0))
        return PartitionMap(
            version=1,
            mode=PARTITION_MODE_AUTO,
            ranges=ranges^,
            next_pid=1,
            retired=List[RetiredRange](),
        )

    # -------------------------------------------------------------------------
    # range_containing_pid — the ROUTING primitive (binary search).
    # -------------------------------------------------------------------------

    @always_inline
    def _is_last(self, i: Int) -> Bool:
        return i == len(self.ranges) - 1

    def range_containing_pid(self, hash: UInt64) raises -> Int:
        """Return the pid of the range whose `[lo, hi)` contains `hash`. Binary
        search over the ordered ranges — O(log P). This is THE routing primitive
        (replaces `% num_partitions`): a key's partition = the range its full
        64-bit fnv1a hash falls into (the high-bits reduction).

        Honors the last-range-inclusive representation: range i matches iff
        `hash >= lo_i AND (i is last OR hash < hi_i)`. Because the ranges are
        contiguous + gap-free over `[0, 2^64)`, EVERY hash matches exactly one
        range (total + deterministic)."""
        var n = len(self.ranges)
        if n == 0:
            raise Error(
                "PartitionMap.range_containing_pid: empty map (no ranges)"
            )
        var lo_i = 0
        var hi_i = n - 1
        while lo_i <= hi_i:
            var mid = (lo_i + hi_i) // 2
            ref r = self.ranges[mid]
            if hash < r.hash_lo:
                hi_i = mid - 1
            elif self._is_last(mid):
                # Last range's hi is inclusive (== 2^64). hash >= lo here.
                return r.pid
            elif hash < r.hash_hi:
                return r.pid
            else:
                lo_i = mid + 1
        # Unreachable for a valid (gap-free, full-space) map.
        raise Error(
            "PartitionMap.range_containing_pid: hash "
            + String(hash)
            + " fell outside the covered range space (map invariant violated)"
        )

    @always_inline
    def num_partitions(self) -> Int:
        """The number of LIVE partitions == the number of ranges. The consumer
        enumerates partitions over the pids of these ranges."""
        return len(self.ranges)

    def pids(self) -> List[Int]:
        """The ordered list of live partition pids (one per range). The consumer
        enumerates partitions over THIS list (not a raw `0..num_partitions-1`):
        for a fixed map the pids ARE `0..N-1`, but reading them from the map
        keeps the consumer correct when the scaler assigns sparse pids."""
        var out = List[Int]()
        for i in range(len(self.ranges)):
            out.append(self.ranges[i].pid)
        return out^

    @always_inline
    def _range_index_for_pid(self, pid: Int) -> Int:
        """Index of the LIVE range owning `pid`, or -1 if no live range has it
        (already retired / never existed)."""
        for i in range(len(self.ranges)):
            if self.ranges[i].pid == pid:
                return i
        return -1

    @always_inline
    def retired_for_pid(self, pid: Int) -> Optional[RetiredRange]:
        """The `RetiredRange` tombstone for a frozen parent `pid`, or None if
        `pid` is not a retired parent. Used by the consumer's lineage walk to
        find a child's frozen-parent freeze offset + subrange."""
        for i in range(len(self.retired)):
            if self.retired[i].pid == pid:
                return Optional[RetiredRange](self.retired[i].copy())
        return Optional[RetiredRange](None)

    # -------------------------------------------------------------------------
    # split — the SPLIT PRIMITIVE: replace pid's range with two
    # children at the hash midpoint, record lineage, bump version, retire parent.
    # -------------------------------------------------------------------------

    def split(self, pid: Int) raises -> PartitionMap:
        """Split the LIVE partition `pid` (range `[lo, hi)`) into two children
        at the hash-space midpoint `mid = lo + (hi - lo) / 2`:
          * child_a owns `[lo, mid)`, child_b owns `[mid, hi)`.
          * BOTH children get FRESH pids from the monotone `next_pid` counter —
            NEVER the parent's pid (correctness/clarity: each child manifest
            prefix is a new `<...>/<child_pid>`, the parent's prefix is frozen).
          * BOTH children carry lineage: `parent_pid = pid` and
            `parent_split_offset = parent_split_offset` (the freeze offset X the
            CALLER passes in via `split_at_offset` — see below). This is what
            lets the consumer read parent-prefix-then-child in per-key order.
          * the parent `pid` is REMOVED from `ranges` and appended to `retired`
            (the tombstone carries X + both child pids).
          * `version` is bumped (the `If-Match` CAS guard) and `next_pid`
            advances by 2.

        Returns a NEW map (PartitionMap is a value; this never mutates `self` —
        the caller CAS-persists the returned map via `persist_update`, and on a
        CAS miss re-reads + re-splits, exactly like the manifest append).

        NOTE — `split()` takes NO freeze offset here: the freeze offset X is the
        DATA-PLANE concern (the parent manifest's `next_offset` at split time),
        read by the orchestrator from the parent's `CasManifestStore.read_head`
        and threaded in via `split_at(pid, X)`. This bare `split(pid)` is the
        metadata-only midpoint split used when X is supplied separately; the
        canonical entry point is `split_at`. (Kept as a thin shim over
        `split_at` with X = `NO_PARENT_BASE` for the pure-metadata unit tests
        that don't have a manifest.)
        """
        return self.split_at(pid, NO_PARENT_BASE)

    def split_at(self, pid: Int, split_at_offset: Int64) raises -> PartitionMap:
        """`split(pid)` with the EXPLICIT freeze offset X (`split_at_offset`):
        the parent manifest's committed `next_offset` at split time. This is
        the canonical entry point the data-plane orchestrator
        calls after reading the parent's manifest head. See `split` for the
        full mechanics."""
        if self.mode != PARTITION_MODE_AUTO:
            raise Error(
                "PartitionMap.split: only an AUTO-mode topic may split (a"
                " fixed/Kafka topic NEVER splits). mode="
                + mode_name(self.mode)
            )
        var idx = self._range_index_for_pid(pid)
        if idx < 0:
            raise Error(
                "PartitionMap.split: pid "
                + String(pid)
                + " is not a LIVE partition (already retired / never existed)"
            )
        var parent = self.ranges[idx].copy()
        var lo = parent.hash_lo
        var hi = parent.hash_hi
        # Hash-space midpoint. For the LAST range hi is UInt64.MAX (inclusive ==
        # 2^64); `lo + (hi - lo) / 2` is still a valid interior point (no
        # overflow: hi - lo fits in u64, the half is < the whole). The child_b
        # upper bound inherits the parent's hi exactly (so child_b stays the
        # last range when the parent was last — preserving the
        # `last.hash_hi == MAX` invariant).
        var mid = lo + (hi - lo) / UInt64(2)
        if mid <= lo or (mid >= hi and hi != UInt64.MAX):
            # A range of width 1 (lo == hi-1) cannot split into two positive-
            # width children: mid would equal lo. This is the hot-KEY ceiling
            # at its limit — a single hash-point range. Fail loud.
            raise Error(
                "PartitionMap.split: range [lo="
                + String(lo)
                + ", hi="
                + String(hi)
                + ") for pid "
                + String(pid)
                + " is too narrow to split (width <= 1; a single hash-point"
                " cannot be split — the hot-key ceiling)"
            )

        var child_a_pid = self.next_pid
        var child_b_pid = self.next_pid + 1

        # Build the new ranges list: copy all live ranges, replacing the parent
        # at `idx` with child_a then child_b (preserving ascending lo order —
        # child_a.lo == lo < mid == child_b.lo, and the neighbors are unchanged).
        var new_ranges = List[HashRange]()
        for i in range(len(self.ranges)):
            if i == idx:
                new_ranges.append(
                    HashRange.split_child(
                        hash_lo=lo,
                        hash_hi=mid,
                        pid=child_a_pid,
                        parent_pid=pid,
                        parent_split_offset=split_at_offset,
                    )
                )
                new_ranges.append(
                    HashRange.split_child(
                        hash_lo=mid,
                        hash_hi=hi,
                        pid=child_b_pid,
                        parent_pid=pid,
                        parent_split_offset=split_at_offset,
                    )
                )
            else:
                new_ranges.append(self.ranges[i].copy())

        var new_retired = self.retired.copy()
        new_retired.append(
            RetiredRange.split_parent(
                pid=pid,
                hash_lo=lo,
                hash_hi=hi,
                frozen_at_offset=split_at_offset,
                child_a_pid=child_a_pid,
                child_b_pid=child_b_pid,
            )
        )

        var out = PartitionMap(
            version=self.version + 1,
            mode=self.mode,
            ranges=new_ranges^,
            next_pid=self.next_pid + 2,
            retired=new_retired^,
        )
        out.validate()  # the split must keep the map gap-free + full-space.
        return out^

    # -------------------------------------------------------------------------
    # merge — the MERGE PRIMITIVE: fold two
    # ADJACENT live ranges into one child, record lineage, bump version, retire
    # both parents.
    # -------------------------------------------------------------------------

    @always_inline
    def _adjacent_index_pair(self, pid_a: Int, pid_b: Int) raises -> Int:
        """Index `i` such that `ranges[i].pid == pid_a` AND `ranges[i+1].pid ==
        pid_b` (A is the LOWER-subrange live range, B the immediate UPPER
        neighbor). Raises if A,B are not both live OR not adjacent in that order
        (a merge is only valid for two ADJACENT live ranges, A below B). The
        ranges list is kept in ascending `hash_lo` order, so adjacency ==
        consecutive indices with `ranges[i].hash_hi == ranges[i+1].hash_lo`."""
        var ia = self._range_index_for_pid(pid_a)
        var ib = self._range_index_for_pid(pid_b)
        if ia < 0:
            raise Error(
                "PartitionMap.merge: pid_a "
                + String(pid_a)
                + " is not a LIVE partition (retired / never existed)"
            )
        if ib < 0:
            raise Error(
                "PartitionMap.merge: pid_b "
                + String(pid_b)
                + " is not a LIVE partition (retired / never existed)"
            )
        if ib != ia + 1:
            raise Error(
                "PartitionMap.merge: pids "
                + String(pid_a)
                + " and "
                + String(pid_b)
                + " are not ADJACENT in ascending order (a merge folds two"
                " adjacent ranges A[lo,mid) + B[mid,hi); A must be the lower"
                " neighbor of B). idx_a="
                + String(ia)
                + " idx_b="
                + String(ib)
            )
        # Adjacency is gap-free by the map invariant, but assert defensively.
        if self.ranges[ia].hash_hi != self.ranges[ib].hash_lo:
            raise Error(
                "PartitionMap.merge: ranges for pids "
                + String(pid_a)
                + " / "
                + String(pid_b)
                + " are not contiguous (A.hi != B.lo) — map invariant violated"
            )
        return ia

    def merge(self, pid_a: Int, pid_b: Int) raises -> PartitionMap:
        """`merge_at(pid_a, pid_b, NO_PARENT_BASE, NO_PARENT_BASE)` — the
        metadata-only adjacent merge used by pure-metadata unit tests that don't
        have manifests. The canonical entry point is `merge_at` (which carries
        the two freeze offsets read from the predecessors' manifest heads)."""
        return self.merge_at(pid_a, pid_b, NO_PARENT_BASE, NO_PARENT_BASE)

    def merge_at(
        self,
        pid_a: Int,
        pid_b: Int,
        frozen_a_offset: Int64,
        frozen_b_offset: Int64,
    ) raises -> PartitionMap:
        """Merge two ADJACENT live ranges A=`[lo, mid)` (pid_a) + B=`[mid, hi)`
        (pid_b) into ONE child C=`[lo, hi)`:
          * C gets a FRESH pid from the monotone `next_pid` counter — never A's or
            B's pid (each predecessor manifest prefix stays frozen at its own pid;
            C's manifest prefix is a new `<...>/<C_pid>`).
          * C carries MERGE lineage: `merge_pred_a_pid = pid_a`, `merge_pred_b_pid
            = pid_b`. This lets the consumer read A[0..tail] then B[0..tail] then
            C[0..] in per-key order. A and B are RANGE-PURE (disjoint
            subranges) so NO per-row filter is needed — each is read fully.
          * BOTH A and B are REMOVED from `ranges` (replaced by the single C) and
            appended to `retired` as TWO merge-predecessor tombstones (each carries
            its own freeze offset + `merged_into_pid = C`).
          * `version` is bumped (the If-Match CAS guard) and `next_pid` advances
            by 1 (one new child).

        `frozen_a_offset`/`frozen_b_offset` are the predecessors' committed
        `next_offset`s at merge time (the data-plane orchestrator reads each from
        its manifest head). They are LOWER BOUNDS on the predecessors' tails:
        the consumer reads each predecessor manifest to its ACTUAL tail, so an
        in-flight flush past the recorded offset is still read.

        PURE METADATA: no segment is moved or rewritten. A and B's segments
        stay exactly where they are; C
        only ever holds NEW post-merge records.

        Returns a NEW map (PartitionMap is a value; the caller CAS-persists it).
        Raises if the map is `fixed` (a Kafka topic never merges),
        if A,B are not both live + adjacent (A below B), or on a min-partitions
        floor violation handled by the caller (merge of the last range is
        rejected by adjacency — a single range has no neighbor)."""
        if self.mode != PARTITION_MODE_AUTO:
            raise Error(
                "PartitionMap.merge: only an AUTO-mode topic may merge (a"
                " fixed/Kafka topic NEVER merges). mode="
                + mode_name(self.mode)
            )
        var ia = self._adjacent_index_pair(pid_a, pid_b)
        var ib = ia + 1
        var a = self.ranges[ia].copy()
        var b = self.ranges[ib].copy()
        var lo = a.hash_lo
        var hi = b.hash_hi  # inherit B's hi exactly (preserves last == MAX).

        var child_pid = self.next_pid

        # Build the new ranges list: copy all live ranges, replacing the A,B pair
        # at [ia, ib] with the single merged child C (preserving ascending lo
        # order — C.lo == A.lo, C.hi == B.hi, neighbors unchanged).
        var new_ranges = List[HashRange]()
        for i in range(len(self.ranges)):
            if i == ia:
                new_ranges.append(
                    HashRange.merged_child(
                        hash_lo=lo,
                        hash_hi=hi,
                        pid=child_pid,
                        merge_pred_a_pid=pid_a,
                        merge_pred_b_pid=pid_b,
                    )
                )
            elif i == ib:
                continue  # B is folded into C (already emitted at ia).
            else:
                new_ranges.append(self.ranges[i].copy())

        var new_retired = self.retired.copy()
        new_retired.append(
            RetiredRange.merge_predecessor(
                pid=pid_a,
                hash_lo=a.hash_lo,
                hash_hi=a.hash_hi,
                frozen_at_offset=frozen_a_offset,
                merged_into_pid=child_pid,
            )
        )
        new_retired.append(
            RetiredRange.merge_predecessor(
                pid=pid_b,
                hash_lo=b.hash_lo,
                hash_hi=b.hash_hi,
                frozen_at_offset=frozen_b_offset,
                merged_into_pid=child_pid,
            )
        )

        var out = PartitionMap(
            version=self.version + 1,
            mode=self.mode,
            ranges=new_ranges^,
            next_pid=self.next_pid + 1,
            retired=new_retired^,
        )
        out.validate()  # the merge must keep the map gap-free + full-space.
        return out^

    # -------------------------------------------------------------------------
    # collapse_lineage — drop a frozen SPLIT parent's lineage edge after a
    # compaction tick rewrote its segments into range-pure children. Pure
    # metadata: the parent tombstone is removed and
    # the children's back-edges to it are cleared, so a future read-order build
    # NO LONGER reads the parent prefix. The parent's (now-orphaned) segments are
    # left for retention to reap.
    # -------------------------------------------------------------------------

    def collapse_lineage(self, parent_pid: Int) raises -> PartitionMap:
        """Collapse the lineage of a frozen SPLIT parent `parent_pid` whose
        segments have been compacted into its children's range-pure manifests.
        After this:
          * `parent_pid` is removed from `retired` (it is no longer a read step).
          * its two children's `parent_pid`/`parent_split_offset` back-edges are
            cleared to `NO_PARENT_PID`/`NO_PARENT_BASE` (they become ORIGINAL-
            shaped live ranges — the consumer no longer reads the parent prefix).
          * `version` is bumped (the If-Match CAS guard).

        This DROPS the child read's effective lineage depth by one:
        a child that walked parent->child now reads only its own manifest (which,
        post-compaction, holds the parent's range-pure rows too). Returns a NEW
        map. Raises if `parent_pid` is not a SPLIT-parent tombstone (a merge
        predecessor or a non-retired pid)."""
        # Find the split-parent tombstone.
        var t_idx = -1
        for i in range(len(self.retired)):
            if self.retired[i].pid == parent_pid and not self.retired[i].is_merge():
                t_idx = i
                break
        if t_idx < 0:
            raise Error(
                "PartitionMap.collapse_lineage: pid "
                + String(parent_pid)
                + " is not a SPLIT-parent tombstone (not retired, or a merge"
                " predecessor) — only a compacted split parent's lineage may be"
                " collapsed"
            )
        var child_a = self.retired[t_idx].child_a_pid
        var child_b = self.retired[t_idx].child_b_pid

        # Clear the children's back-edges (they become ORIGINAL-shaped — but
        # ONLY if the back-edge points at THIS parent; a child that has itself
        # been re-split keeps its own lineage). A child that was further split is
        # no longer a live range (it's retired), so we only touch LIVE children.
        var new_ranges = List[HashRange]()
        for i in range(len(self.ranges)):
            ref r = self.ranges[i]
            if (r.pid == child_a or r.pid == child_b) and r.parent_pid == parent_pid:
                new_ranges.append(
                    HashRange.original(r.hash_lo, r.hash_hi, r.pid)
                )
            else:
                new_ranges.append(r.copy())

        # Drop the parent tombstone.
        var new_retired = List[RetiredRange]()
        for i in range(len(self.retired)):
            if i == t_idx:
                continue
            new_retired.append(self.retired[i].copy())

        var out = PartitionMap(
            version=self.version + 1,
            mode=self.mode,
            ranges=new_ranges^,
            next_pid=self.next_pid,
            retired=new_retired^,
        )
        out.validate()
        return out^

    # -------------------------------------------------------------------------
    # collapse_lineage_with_prefix_gen — drop a frozen SPLIT parent's edge after
    # the GEN-MODEL compaction tick migrated the parent's range-pure rows into
    # each child's SEPARATE from-0 PREFIX-GENERATION manifest, read STRICTLY
    # BEFORE the child's live generation. The DUAL of `collapse_lineage` for
    # the HOT-CHILD case: instead of
    # re-appending parent rows at the child's live tail (which is forbidden when
    # the child is non-empty — it would invert per-key order), the parent rows
    # live in the child's prefix generation, so the live offsets are UNCHANGED
    # (committed-offset stability) and the read order reads prefix-then-live.
    # -------------------------------------------------------------------------

    def collapse_lineage_with_prefix_gen(
        self,
        parent_pid: Int,
        child_a_prefix_gen_seq: Int64,
        child_b_prefix_gen_seq: Int64,
    ) raises -> PartitionMap:
        """Collapse a frozen SPLIT parent `parent_pid` whose range-pure rows have
        been migrated into its children's PREFIX-GENERATION manifests (the
        gen-model HOT-CHILD compaction). After this:
          * `parent_pid` is removed from `retired` (no longer a read step — the
            depth reduction).
          * each LIVE child whose `parent_pid` back-edge points at THIS parent
            gets its `prefix_gen_seq` set (to `child_a_prefix_gen_seq` /
            `child_b_prefix_gen_seq` by which child it is) and its split
            back-edge cleared (`with_prefix_gen`). The child now reads its OWN
            prefix generation strictly before its live generation, NOT the shared
            parent. The live generation's offsets `[0, hwm)` are PHYSICALLY
            untouched (committed-offset stability).
          * `version` is bumped (the If-Match CAS guard).

        A child that carries `NO_PARENT_BASE` for its seq (the gen-model
        migrated NO committed rows into it — e.g. all parent rows hashed to the
        other child) is left WITHOUT a prefix generation (its back-edge is still
        cleared — the parent is gone). Returns a NEW map. Raises if `parent_pid`
        is not a SPLIT-parent tombstone (a merge predecessor / non-retired pid)."""
        var t_idx = -1
        for i in range(len(self.retired)):
            if self.retired[i].pid == parent_pid and not self.retired[i].is_merge():
                t_idx = i
                break
        if t_idx < 0:
            raise Error(
                "PartitionMap.collapse_lineage_with_prefix_gen: pid "
                + String(parent_pid)
                + " is not a SPLIT-parent tombstone (not retired, or a merge"
                " predecessor) — only a compacted split parent's lineage may be"
                " collapsed"
            )
        var child_a = self.retired[t_idx].child_a_pid
        var child_b = self.retired[t_idx].child_b_pid

        # Annotate the live children with their prefix-generation seq + clear
        # the back-edge (only the children whose back-edge points at THIS
        # parent; a re-split child is no longer a live range, so untouched).
        var new_ranges = List[HashRange]()
        for i in range(len(self.ranges)):
            ref r = self.ranges[i]
            if r.pid == child_a and r.parent_pid == parent_pid:
                new_ranges.append(r.with_prefix_gen(child_a_prefix_gen_seq))
            elif r.pid == child_b and r.parent_pid == parent_pid:
                new_ranges.append(r.with_prefix_gen(child_b_prefix_gen_seq))
            else:
                new_ranges.append(r.copy())

        # Drop the parent tombstone (the depth reduction).
        var new_retired = List[RetiredRange]()
        for i in range(len(self.retired)):
            if i == t_idx:
                continue
            new_retired.append(self.retired[i].copy())

        var out = PartitionMap(
            version=self.version + 1,
            mode=self.mode,
            ranges=new_ranges^,
            next_pid=self.next_pid,
            retired=new_retired^,
        )
        out.validate()
        return out^

    # -------------------------------------------------------------------------
    # validate — assert the gap-free / full-space invariants.
    # -------------------------------------------------------------------------

    def validate(self) raises:
        """Assert the map invariants: non-empty, `ranges[0].hash_lo == 0`,
        contiguous + gap-free (`ranges[i].hash_hi == ranges[i+1].hash_lo`), and
        the last range's `hash_hi == UInt64.MAX` (covers up to 2^64). Raises a
        clear contract error on any violation (a corrupt / malformed map)."""
        var n = len(self.ranges)
        if n == 0:
            raise Error("PartitionMap.validate: empty map (no ranges)")
        if self.ranges[0].hash_lo != UInt64(0):
            raise Error(
                "PartitionMap.validate: first range hash_lo != 0 (got "
                + String(self.ranges[0].hash_lo)
                + ")"
            )
        for i in range(n - 1):
            if self.ranges[i].hash_hi != self.ranges[i + 1].hash_lo:
                raise Error(
                    "PartitionMap.validate: gap/overlap between range "
                    + String(i)
                    + " (hi="
                    + String(self.ranges[i].hash_hi)
                    + ") and range "
                    + String(i + 1)
                    + " (lo="
                    + String(self.ranges[i + 1].hash_lo)
                    + ")"
                )
            if self.ranges[i].hash_lo >= self.ranges[i].hash_hi:
                raise Error(
                    "PartitionMap.validate: non-positive-width range "
                    + String(i)
                )
        if self.ranges[n - 1].hash_hi != UInt64.MAX:
            raise Error(
                "PartitionMap.validate: last range hash_hi != UInt64.MAX"
                " (does not cover up to 2^64); got "
                + String(self.ranges[n - 1].hash_hi)
            )

    # -------------------------------------------------------------------------
    # encode / decode — compact JSON (matches BrokerTopicConfig's codec style).
    # -------------------------------------------------------------------------

    def encode(self) -> List[UInt8]:
        """Serialize to a compact JSON object (UTF-8 bytes). Matches the
        `config.json` style (`BrokerTopicConfig.encode`): low-rate, written once
        per topic, so JSON readability is worth the bytes. Layout:

          {"version":1,"mode":"fixed","hash":"fnv1a64","ranges":[
             {"lo":0,"hi":9223372036854775808,"pid":0},
             {"lo":9223372036854775808,"hi":18446744073709551615,"pid":1}]}

        UInt64 values render as unsigned decimal (the `String(UInt64)` form).
        """
        var s = String('{"version":')
        s += String(self.version)
        s += String(',"mode":"')
        s += mode_name(self.mode)
        s += String('","hash":"')
        s += PARTITION_MAP_HASH_ID
        s += String('","next_pid":')
        s += String(self.next_pid)
        s += String(',"ranges":[')
        for i in range(len(self.ranges)):
            if i > 0:
                s += String(",")
            ref r = self.ranges[i]
            s += String('{"lo":')
            s += String(r.hash_lo)
            s += String(',"hi":')
            s += String(r.hash_hi)
            s += String(',"pid":')
            s += String(r.pid)
            s += String(',"ppid":')
            s += String(r.parent_pid)
            s += String(',"psoff":')
            s += String(r.parent_split_offset)
            s += String(',"mpa":')
            s += String(r.merge_pred_a_pid)
            s += String(',"mpb":')
            s += String(r.merge_pred_b_pid)
            s += String(',"pgs":')
            s += String(r.prefix_gen_seq)
            s += String("}")
        s += String('],"retired":[')
        for i in range(len(self.retired)):
            if i > 0:
                s += String(",")
            ref t = self.retired[i]
            s += String('{"rpid":')
            s += String(t.pid)
            s += String(',"rlo":')
            s += String(t.hash_lo)
            s += String(',"rhi":')
            s += String(t.hash_hi)
            s += String(',"rfoff":')
            s += String(t.frozen_at_offset)
            s += String(',"rca":')
            s += String(t.child_a_pid)
            s += String(',"rcb":')
            s += String(t.child_b_pid)
            s += String(',"rmi":')
            s += String(t.merged_into_pid)
            s += String("}")
        s += String("]}")
        var b = s.as_bytes()
        var out = List[UInt8]()
        for i in range(len(b)):
            out.append(b[i])
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> PartitionMap:
        """Parse the compact JSON object written by `encode`. Tolerant
        BYTE-LEVEL forward-scan (the writer is the only producer of this format)
        — same discipline as `BrokerTopicConfig.decode`. Byte-level (not
        String-indexed) for robustness on the Mojo 1.0.0b1 String codepoint API;
        the map JSON is ASCII so byte == char."""
        var n = len(bytes)

        # version
        var v_at = _json_find_after(bytes, String('"version":'), 0)
        if v_at < 0:
            raise Error("PartitionMap.decode: missing 'version' field")
        var version = _parse_int_at(bytes, v_at)

        # mode
        var m_at = _json_find_after(bytes, String('"mode":"'), 0)
        if m_at < 0:
            raise Error("PartitionMap.decode: missing 'mode' field")
        var mode_str = _parse_ascii_string_at(bytes, m_at)
        var mode = mode_from_name(mode_str)

        # next_pid (optional for forward-compat with a pre-lineage map: -1
        # sentinel here, the ctor below derives max(pid)+1 if it stays -1).
        var np_at = _json_find_after(bytes, String('"next_pid":'), 0)
        var parsed_next_pid = -1
        if np_at >= 0:
            parsed_next_pid = _parse_int_at(bytes, np_at)

        # The ranges array ENDS at the `]` that closes it, which is immediately
        # followed by either `,"retired"` or `}`. Bound the per-range scan so a
        # `"lo":`-shaped marker can never leak past the ranges array. (The
        # retired entries use `"rlo":` keys which do NOT contain the `"lo":`
        # marker bytes, but bounding is the robust discipline.)
        var ranges_open = _json_find_after(bytes, String('"ranges":['), 0)
        if ranges_open < 0:
            raise Error("PartitionMap.decode: missing 'ranges' field")
        var ranges_end = _find_array_close(bytes, ranges_open)

        # ranges: [ {lo,hi,pid,ppid,psoff}, ... ]
        var lo_marker = _str_bytes(String('"lo":'))
        var ranges = List[HashRange]()
        var q = ranges_open
        while q < ranges_end:
            var lo_at = _bytes_find(bytes, lo_marker, q)
            if lo_at < 0 or lo_at >= ranges_end:
                break
            var lo_val = _parse_u64_at(bytes, lo_at + len(lo_marker))
            var hi_at = _json_find_after(bytes, String('"hi":'), lo_at)
            if hi_at < 0:
                raise Error("PartitionMap.decode: range missing 'hi'")
            var hi_val = _parse_u64_at(bytes, hi_at)
            var pid_at = _json_find_after(bytes, String('"pid":'), hi_at)
            if pid_at < 0:
                raise Error("PartitionMap.decode: range missing 'pid'")
            var pid_val = _parse_int_at(bytes, pid_at)
            # SPLIT-lineage fields (optional for forward-compat — default to
            # no-parent).
            var ppid_val = NO_PARENT_PID
            var psoff_val = NO_PARENT_BASE
            var ppid_at = _json_find_after(bytes, String('"ppid":'), pid_at)
            if ppid_at >= 0 and ppid_at < ranges_end:
                ppid_val = _parse_int_at(bytes, ppid_at)
                var psoff_at = _json_find_after(
                    bytes, String('"psoff":'), ppid_at
                )
                if psoff_at >= 0 and psoff_at < ranges_end:
                    psoff_val = Int64(_parse_int_at(bytes, psoff_at))
            # MERGE-lineage fields (optional for forward-compat — default to
            # no-predecessor).
            var mpa_val = NO_PARENT_PID
            var mpb_val = NO_PARENT_PID
            var mpa_at = _json_find_after(bytes, String('"mpa":'), pid_at)
            if mpa_at >= 0 and mpa_at < ranges_end:
                mpa_val = _parse_int_at(bytes, mpa_at)
                var mpb_at = _json_find_after(bytes, String('"mpb":'), mpa_at)
                if mpb_at >= 0 and mpb_at < ranges_end:
                    mpb_val = _parse_int_at(bytes, mpb_at)
            # PREFIX-GENERATION field (optional for forward-compat — a pre-gen-
            # model map omits it → NO_PARENT_BASE == no prefix generation).
            var pgs_val = NO_PARENT_BASE
            var pgs_at = _json_find_after(bytes, String('"pgs":'), pid_at)
            if pgs_at >= 0 and pgs_at < ranges_end:
                pgs_val = Int64(_parse_int_at(bytes, pgs_at))
            ranges.append(
                HashRange(
                    hash_lo=lo_val,
                    hash_hi=hi_val,
                    pid=pid_val,
                    parent_pid=ppid_val,
                    parent_split_offset=psoff_val,
                    merge_pred_a_pid=mpa_val,
                    merge_pred_b_pid=mpb_val,
                    prefix_gen_seq=pgs_val,
                )
            )
            q = pid_at + 1
        if len(ranges) == 0:
            raise Error("PartitionMap.decode: no ranges parsed")

        # retired: [ {rpid,rlo,rhi,rfoff,rca,rcb}, ... ] (optional).
        var retired = List[RetiredRange]()
        var rpid_marker = _str_bytes(String('"rpid":'))
        var r = _json_find_after(bytes, String('"retired":['), 0)
        if r >= 0:
            while r < n:
                var rpid_at = _bytes_find(bytes, rpid_marker, r)
                if rpid_at < 0:
                    break
                var rpid_val = _parse_int_at(
                    bytes, rpid_at + len(rpid_marker)
                )
                var rlo_at = _json_find_after(bytes, String('"rlo":'), rpid_at)
                var rhi_at = _json_find_after(bytes, String('"rhi":'), rpid_at)
                var rfoff_at = _json_find_after(
                    bytes, String('"rfoff":'), rpid_at
                )
                var rca_at = _json_find_after(bytes, String('"rca":'), rpid_at)
                var rcb_at = _json_find_after(bytes, String('"rcb":'), rpid_at)
                if (
                    rlo_at < 0
                    or rhi_at < 0
                    or rfoff_at < 0
                    or rca_at < 0
                    or rcb_at < 0
                ):
                    raise Error(
                        "PartitionMap.decode: retired entry missing a field"
                    )
                # MERGE discriminant (optional for forward-compat — default to
                # NO_MERGE_PID == a SPLIT-parent tombstone).
                var rmi_val = NO_MERGE_PID
                var rmi_at = _json_find_after(bytes, String('"rmi":'), rpid_at)
                if rmi_at >= 0:
                    rmi_val = _parse_int_at(bytes, rmi_at)
                retired.append(
                    RetiredRange(
                        pid=rpid_val,
                        hash_lo=_parse_u64_at(bytes, rlo_at),
                        hash_hi=_parse_u64_at(bytes, rhi_at),
                        frozen_at_offset=Int64(_parse_int_at(bytes, rfoff_at)),
                        child_a_pid=_parse_int_at(bytes, rca_at),
                        child_b_pid=_parse_int_at(bytes, rcb_at),
                        merged_into_pid=rmi_val,
                    )
                )
                r = rcb_at + 1

        # Derive next_pid if the encoded map predates the field (sentinel -1).
        var next_pid = parsed_next_pid
        if next_pid < 0:
            var max_pid = -1
            for i in range(len(ranges)):
                if ranges[i].pid > max_pid:
                    max_pid = ranges[i].pid
            for i in range(len(retired)):
                if retired[i].child_a_pid > max_pid:
                    max_pid = retired[i].child_a_pid
                if retired[i].child_b_pid > max_pid:
                    max_pid = retired[i].child_b_pid
                if retired[i].merged_into_pid > max_pid:
                    max_pid = retired[i].merged_into_pid
            next_pid = max_pid + 1

        return PartitionMap(
            version=version,
            mode=mode,
            ranges=ranges^,
            next_pid=next_pid,
            retired=retired^,
        )


# =============================================================================
# Object-store persistence — create-if-absent on first write; read; If-Match update.
# =============================================================================


def persist_create_if_absent[
    Store: ConditionalWriteStore
](store: Store, cluster: String, topic: String, map: PartitionMap) raises:
    """Create the topic's partition map at
    `<cluster>/_meta/topics/<topic>/partition_map.json` IF ABSENT, via
    `conditional_put` + `WritePrecondition.if_none_match_star()`. Concurrent
    producers don't clobber: exactly one create wins; a loser sees the 412
    precondition conflict and leaves the existing map in place (this MVP writes
    the map once at topic creation and never mutates it, so a loser need only
    NOT overwrite — the existing map is authoritative).

    A 412 precondition conflict is SWALLOWED (the map already exists, which is
    the success case for create-if-absent under concurrency). Any OTHER error
    re-raises."""
    var key = partition_map_key(cluster, topic)
    try:
        _ = store.conditional_put(
            Path.parse(key), map.encode(), WritePrecondition.if_none_match_star()
        )
    except e:
        if not _conflict_is_precondition(String(e)):
            raise e^
        # 412 == the map already exists. Create-if-absent succeeded logically
        # (the existing map is authoritative). Do NOT overwrite.


def read_partition_map[
    Store: ConditionalWriteStore
](store: Store, cluster: String, topic: String) raises -> PartitionMap:
    """Read + decode the topic's partition map from
    `<cluster>/_meta/topics/<topic>/partition_map.json`. Raises if absent (the
    topic was never produced to / no producer created the map yet) — a clear
    contract error rather than a silent zero-partition read."""
    var bytes = store.get(Path.parse(partition_map_key(cluster, topic)))
    return PartitionMap.decode(bytes)


@fieldwise_init
struct MapWithEtag(Movable, Deinitable):
    """A partition map plus the object's current ETag — the `If-Match` token a
    split CAS needs. Returned by `read_partition_map_with_etag`.

    Field layout:
      var map: PartitionMap — the decoded map.
      var etag: String      — the object's current ETag (the `expected_version`
                              a subsequent `persist_update` compares against).
    """

    var map: PartitionMap
    var etag: String


def read_partition_map_with_etag[
    Store: ConditionalWriteStore
](store: Store, cluster: String, topic: String) raises -> MapWithEtag:
    """Read the map AND its current ETag (via `head` + `get`). The split CAS
    reads the map with its etag, computes the split, then `persist_update`s the
    new map gated on that etag — a stale etag (someone else split first) loses
    the CAS and the caller re-reads + re-evaluates."""
    var key = Path.parse(partition_map_key(cluster, topic))
    var meta = store.head(key)
    var bytes = store.get(key)
    return MapWithEtag(map=PartitionMap.decode(bytes), etag=meta.etag)


def persist_update[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    map: PartitionMap,
    expected_version: String,
) raises:
    """Versioned `If-Match` UPDATE of the partition map (the strict CAS the
    split/merge scaler uses). Writes the new map ONLY IF the
    object's current etag equals `expected_version`; a stale etag raises the 412
    precondition conflict the caller re-evaluates against the moved map.

    Exercised by the split mechanism: `split_topic` reads the
    map+etag, computes `map.split_at(pid, X)`, then calls this to commit. A
    concurrent split that won the CAS first moves the etag → this raises → the
    caller re-reads + re-splits (exactly the manifest-append CAS discipline)."""
    var key = partition_map_key(cluster, topic)
    _ = store.compare_and_swap(Path.parse(key), map.encode(), expected_version)


def try_persist_update[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    map: PartitionMap,
    expected_version: String,
) raises -> Bool:
    """`persist_update` that returns False on a CAS MISS (a stale etag —
    someone else updated the map first) instead of raising, so the split
    orchestrator's retry loop reads cleanly. Any NON-precondition error still
    raises. Returns True iff the If-Match write landed."""
    try:
        persist_update[Store](store, cluster, topic, map, expected_version)
        return True
    except e:
        if _conflict_is_precondition(String(e)):
            return False
        raise e^


# =============================================================================
# JSON byte-scan helpers (mirror BrokerTopicConfig's, kept local to this file).
# =============================================================================


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _bytes_find(hay: List[UInt8], needle: List[UInt8], start: Int) -> Int:
    var nlen = len(needle)
    if nlen == 0:
        return start
    var hlen = len(hay)
    var i = start if start >= 0 else 0
    while i + nlen <= hlen:
        var ok = True
        for j in range(nlen):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _json_find_after(hay: List[UInt8], key: String, start: Int) -> Int:
    var needle = _str_bytes(key)
    var idx = _bytes_find(hay, needle, start)
    if idx < 0:
        return -1
    return idx + len(needle)


def _find_array_close(hay: List[UInt8], open_at: Int) -> Int:
    """Index of the `]` that closes the array whose `[` is at `open_at - 1`
    (i.e. `open_at` is the first byte INSIDE the array). The ranges/retired
    arrays contain only flat `{...}` objects (no nested arrays), so the FIRST
    `]` at/after `open_at` closes the array. Returns `len(hay)` if not found
    (degenerate / truncated — the caller's bounded scan then reads to EOF)."""
    var i = open_at
    var n = len(hay)
    while i < n:
        if hay[i] == UInt8(93):  # ']'
            return i
        i += 1
    return n


def _parse_ascii_string_at(bytes: List[UInt8], start: Int) -> String:
    """Read a JSON string body starting AT `start` (just after the opening
    quote) up to the next `"`. ASCII (mode names are plain identifiers)."""
    var out = String("")
    var i = start
    var n = len(bytes)
    while i < n:
        var c = bytes[i]
        if c == UInt8(34):  # '"'
            break
        out += chr(Int(c))
        i += 1
    return out^


def _parse_int_at(bytes: List[UInt8], start: Int) raises -> Int:
    """Read a (possibly negative) decimal integer starting at `start`, skipping
    leading whitespace."""
    var i = start
    var n = len(bytes)
    while i < n and bytes[i] == UInt8(32):  # space
        i += 1
    var sign = 1
    if i < n and bytes[i] == UInt8(45):  # '-'
        sign = -1
        i += 1
    var v = 0
    var saw = False
    while i < n:
        var c = bytes[i]
        if c < UInt8(48) or c > UInt8(57):
            break
        v = v * 10 + Int(c - UInt8(48))
        saw = True
        i += 1
    if not saw:
        raise Error(
            "PartitionMap.decode: expected integer at " + String(start)
        )
    return sign * v


def _parse_u64_at(bytes: List[UInt8], start: Int) raises -> UInt64:
    """Read an unsigned decimal integer (full UInt64 range) starting at `start`,
    skipping leading whitespace. The hash bounds render as unsigned decimal up
    to `18446744073709551615` (UInt64.MAX) — accumulating in UInt64 handles the
    full range without Int overflow."""
    var i = start
    var n = len(bytes)
    while i < n and bytes[i] == UInt8(32):  # space
        i += 1
    var v = UInt64(0)
    var saw = False
    while i < n:
        var c = bytes[i]
        if c < UInt8(48) or c > UInt8(57):
            break
        v = v * UInt64(10) + UInt64(Int(c - UInt8(48)))
        saw = True
        i += 1
    if not saw:
        raise Error(
            "PartitionMap.decode: expected unsigned integer at " + String(start)
        )
    return v


def _conflict_is_precondition(msg: String) -> Bool:
    """True iff a `conditional_put` Error string is a precondition (412)
    conflict — the create-if-absent loser case (the map already exists). Mirrors
    `broker_producer_spec._config_conflict_is_precondition`."""
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )
