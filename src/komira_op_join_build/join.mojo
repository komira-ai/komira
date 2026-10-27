# =============================================================================
# join -- `HashJoinBuilder`, the build side of the single-INT64-key hash join
# =============================================================================
#
# The build side is indexed by join key with SEPARATE CHAINING: each bucket of
# a power-of-two `hash_table` holds the head of a chain and every build row
# links to the next row with the same hash, so 1:N and N:M key relationships
# keep every match (open addressing with one slot per key, Robin Hood
# included, would drop duplicates). Chains are LIFO: the latest row inserted
# is the head. Capacity is the power of two at or above `1.4 * rows + 1`, at
# least 16; keys hash with Fibonacci hashing (`_hash_join_key`).
#
# THE SHIPPED CHAIN-ENTRY LAYOUT (`fused=True`, `nobi=True`): one interleaved
# 16-byte record per build row in `key_next` (`[2i]` the key, `[2i+1]` the
# link), so a chain step touches one cache line, and no `build_indices`
# array: the build row IS the chain index. The split layout (`build_keys` +
# `next_chain`, with `build_indices`) stays reachable as the differential
# oracle. Under PAYLOAD-INLINE the record is 32 bytes and carries one build
# column in word 2 (`komira_join_assembly.join_payload_inline`).
#
# SQL KEY SEMANTICS: a NULL key matches nothing. A NULL build key is recorded
# (so a RIGHT/FULL join's unmatched-build sweep emits it) but never linked into
# a bucket; a NULL probe key skips the walk.
#
# The probe kernels live in their own modules (`join_probe_inner`,
# `join_probe_inner_ps`, `join_probe_semi_anti`, `join_probe_outer`) as free
# functions over a borrowed builder; the methods below forward to them, so a
# caller writes `builder.probe_inner(keys)`.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily
from komira_join_assembly.join_payload_inline import JOIN_KN_WORDS, JOIN_KN_WORDS_PAY

from .join_build_serial import (
    hash_join_build as _hash_join_build,
    hash_join_build_with_bloom as _hash_join_build_with_bloom,
)
from .join_probe_inner import (
    avg_chain_length as _avg_chain_length,
    count_inner_matches as _count_inner_matches,
    probe_inner as _probe_inner,
    probe_inner_chunk as _probe_inner_chunk_entry,
    probe_inner_into as _probe_inner_into_entry,
)
from .join_probe_outer import (
    probe_full as _probe_full,
    probe_left as _probe_left,
    probe_left_into as _probe_left_into_entry,
    probe_right as _probe_right,
)
from .join_probe_semi_anti import (
    probe_anti as _probe_anti,
    probe_anti_count as _probe_anti_count,
    probe_semi as _probe_semi,
    probe_semi_count as _probe_semi_count,
)


# Sentinel value for end-of-chain and empty hash slots.
comptime _CHAIN_END: Int = -1


# Fibonacci hashing constant for 64-bit: 2^64 / phi -- resolved at compile time.
comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15


# Chunk size for chunked probe output. 65536 rows keeps working set in L2 cache
# (65536 * 2 * 8 bytes = 1MB for index pairs, plus gather I/O).
comptime PROBE_CHUNK_SIZE: Int = 65536


# Software prefetch distance: issue prefetch for a probe row this many iterations
# ahead. Tuned for L2 cache latency (~12 cycles); measured on Intel Sapphire
# Rapids and AMD Zen 4, values 4-16 are within 5% of optimal.
comptime _PREFETCH_DISTANCE: Int = 8



@always_inline
def _hash_join_key(key: Int64) -> UInt64:
    """Compute a hash for a join key.

    Uses Fibonacci hashing (multiply by golden ratio constant) which
    distributes keys well across power-of-2 table sizes.

    Args:
        key: The join key value.

    Returns:
        A 64-bit hash value.
    """
    var h = UInt64(key) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    return h


# The single-key INT64 join bloom is built with `HashFamily.fibonacci_join()`,
# so the bloom hashes with the SAME `_hash_join_key` the probe computes for the
# bucket: the probe calls `bloom.might_contain_join_key(key, h)` with its
# precomputed `h`, one hash for both. Correct for any family, because
# `might_contain_join_key` / `insert_join_key` dispatch on the bloom's own
# family, so build and probe cannot disagree.


@always_inline
def _join_bloom_hash_family() -> HashFamily:
    """Hash family for in-memory single-key int64 join blooms: FIBONACCI_JOIN, so
    the probe's precomputed HT hash doubles as the bloom hash (no second hash).
    """
    return HashFamily.fibonacci_join()


# =============================================================================
# ProbeInnerState -- cursor for chunked inner join probing
# =============================================================================


struct ProbeInnerState(Movable, Copyable, Deinitable):
    """Cursor state for resumable chunked inner join probing.

    Tracks the current position in the probe loop so that
    probe_inner_chunk() can yield small chunks of matches without
    building the full 50M-entry index list.

    Fields:
        probe_pos: Next probe-side row index to process.
        chain_pos: Current chain position within a hash bucket.
            _CHAIN_END means start a new probe row.
        done: True when all probe rows have been exhausted.
    """

    var probe_pos: Int
    var chain_pos: Int
    var done: Bool

    def __init__(out self):
        """Create a new probe state at the beginning."""
        self.probe_pos = 0
        self.chain_pos = _CHAIN_END
        self.done = False


# =============================================================================
# HashJoinBuilder -- Build side of a hash join
# =============================================================================


struct HashJoinBuilder(Movable):
    """Build side of a hash join.

    Indexes the smaller table by the join key for O(1) probe lookups.
    Uses separate chaining to handle duplicate keys: each hash bucket
    points to the head of a chain, and the next_chain array links
    entries with the same hash.

    Build phase: iterate all rows of the build table, hash each key,
    and insert into the chain at the corresponding bucket. LIFO ordering
    means the most recently inserted row is the chain head.

    Probe phase: for each probe key, hash it, look up the bucket, walk
    the chain comparing keys, and emit (build_idx, probe_idx) pairs for
    all matches.

    Fields:
        build_keys: The build-side key values, indexed by insertion order.
            EMPTY under the fused layout -- see `key_next`.
        build_indices: Original row indices from the build table. It is the
            IDENTITY (`build_indices[i] == i`) on every producer in the tree, and
            EMPTY under the `nobi` layout (the SHIPPED one),
            where the probe uses `chain_idx` directly. Read it through
            `build_row_at`.
        hash_table: Hash buckets mapping to chain heads. -1 = empty.
        next_chain: Per-row chain links. next_chain[i] points to the
            next row in the same bucket's chain. -1 = end of chain.
        capacity: Hash table capacity (always a power of 2).
    """

    var build_keys: List[Int64]
    var build_indices: List[Int]
    var hash_table: List[Int]
    var next_chain: List[Int]
    # ---- CHAIN-ENTRY LAYOUT ------------------------------------------------
    # `key_next` is the FUSED alternative to the `build_keys` + `next_chain`
    # PAIR: 16-byte records, `key_next[2i]` the key at build row i and
    # `key_next[2i + 1]` its chain link. It is populated -- and those two arrays
    # left EMPTY -- exactly when `_fused` is True. Never both layouts at once:
    # carrying both would double the build's write traffic and make the lever's
    # own A/B measure its instrumentation.
    var key_next: List[Int64]
    # The build ROW COUNT, valid on BOTH layouts. ⚠ `len(self.build_keys)` was
    # this quantity at 14 sites and is NOT it under the fused layout, where that
    # list is empty. Read this field.
    var num_build: Int
    # `build_indices` is elided: it is empty, and `chain_idx` IS the build row.
    var _bi_elided: Bool
    # `build_keys` / `next_chain` are elided in favour of `key_next`.
    var _fused: Bool
    # ---- PAYLOAD-INLINE ------------------------
    # When True the fused entry is FOUR words -- `[key, next, payload, pad]`,
    # 32 B -- instead of two, and `key_next[4i + 2]` carries a copy of ONE
    # build-side column so the probe's existing chain touch yields it and the
    # per-output-row random gather out of that column is deleted outright.
    #
    # ⚠ IMPLIES `_fused`. There is no payload layout over the split
    # `build_keys` + `next_chain` pair: the whole mechanism is that the payload
    # shares a cache line with the key the walk has already loaded.
    #
    # ⚠ THE PAD WORD IS THE LEVER, NOT WASTE. A 24 B entry holds exactly the
    # same information and is 25% WORSE -- 2 of every 8 records then straddle a
    # 64 B line, so a quarter of the chain visits become two line touches. At 32 B the walk touches the SAME number of lines it does at
    # 16 B, so the extra 16 bytes are free. Table: `join_payload_inline`.
    var _pay_inline: Bool
    # Which BUILD-BATCH column `key_next[4i + 2]` is a copy of, or -1.
    #
    # ⛔ IT IS CARRIED ON THE BUILDER ON PURPOSE. The consumers that must know
    # (the probe operator's staged and deferred arms) already hold the builder,
    # so identifying the payload here reaches both without a new constructor
    # parameter -- and, more importantly, keeps "which column is inlined" in
    # exactly ONE place. Two places would be a silent wrong answer the moment
    # they disagreed.
    var _pay_build_col: Int
    var capacity: Int
    var bloom: BloomFilter
    # When False, the bloom is an empty placeholder and EVERY probe-side bloom
    # call MUST be skipped: `BloomFilter()` holds a NULL buffer, the block index
    # is a multiply-shift (no division traps on zero blocks), and the bounds
    # check is a `debug_assert`, so an unguarded call reads 32 bytes at address
    # 0. The driver sets it: a join whose probe consumes no dynamic filter
    # skips the bloom prefill entirely.
    var _use_bloom: Bool

    def __init__(out self, var build_keys: List[Int64], var build_indices: List[Int],
                 var hash_table: List[Int], var next_chain: List[Int], capacity: Int,
                 var bloom: BloomFilter, use_bloom: Bool = True,
                 var key_next: List[Int64] = List[Int64](),
                 num_build: Int = -1,
                 bi_elided: Bool = False, fused: Bool = False,
                 pay_inline: Bool = False,
                 pay_build_col: Int = -1) raises:
        """Construct a HashJoinBuilder with explicit fields.

        Args:
            build_keys: Build-side key values. Ownership is transferred.
            build_indices: Build-side row indices. Ownership is transferred.
            hash_table: Hash bucket array. Ownership is transferred.
            next_chain: Chain link array. Ownership is transferred.
            capacity: Hash table capacity.
            bloom: Bloom filter populated with all build-side keys (when
                `use_bloom` is True), or an empty placeholder (when
                `use_bloom` is False).
            use_bloom: Whether the bloom is populated and probe-side
                `might_contain_int64` checks are valid.
            pay_inline: PAYLOAD-INLINE chain-entry layout -- `key_next` holds
                FOUR words per build row, the third being a copy of build
                column `pay_build_col`. Requires `fused`.
            pay_build_col: The build-batch column `key_next[4i + 2]` copies, or
                -1 when `pay_inline` is False.
        """
        # Resolve the row count BEFORE the moves below consume the lists. A
        # caller that passes `num_build = -1` (one that builds the split layout)
        # gets `len(build_keys)`.
        var n_rows = num_build if num_build >= 0 else len(build_keys)
        self.build_keys = build_keys^
        self.build_indices = build_indices^
        self.hash_table = hash_table^
        self.next_chain = next_chain^
        self.key_next = key_next^
        self.num_build = n_rows
        self._bi_elided = bi_elided
        self._fused = fused
        # ⚠ REFUSED, NOT CLAMPED. A payload layout over the split
        # `build_keys` + `next_chain` pair would read `key_next` (which is
        # EMPTY there) at stride 4 and return garbage keys -- a wrong answer,
        # not a slow path. The constructor is the one place every producer
        # passes through, so the invariant is stated here once instead of at
        # each build site.
        if pay_inline and not fused:
            raise Error(
                "HashJoinBuilder: pay_inline requires fused (payload-inline is"
                " a WIDENING of the fused entry, not an alternative layout)"
            )
        self._pay_inline = pay_inline
        self._pay_build_col = pay_build_col if pay_inline else -1
        self.capacity = capacity
        self.bloom = bloom^
        self._use_bloom = use_bloom

    # -------------------------------------------------------------------------
    # LAYOUT-TOLERANT ACCESSORS
    #
    # ⚠ THESE ARE FOR THE COLD CONSUMERS ONLY, AND DELIBERATELY SO. They carry a
    # RUNTIME branch on a field, which is correct everywhere and free nowhere; the
    # hot probe loops instead take a COMPTIME-specialised body (`_probe_*[fused,
    # nobi]`) so the default arm compiles to byte-for-byte the pre-lever loop and
    # the A/B is not measuring a branch this instrumentation added. Use an
    # accessor where the site is already bounds-checked (`probe_right`,
    # `probe_full`, `compiler_join_chunked`'s flatten pass); use the comptime
    # body where the site hoists raw pointers.
    # -------------------------------------------------------------------------

    @always_inline
    def build_row_at(self, chain_idx: Int) -> Int:
        """The ORIGINAL build-table row index for chain entry `chain_idx`.

        Under the `nobi` layout -- the SHIPPED one -- this IS `chain_idx` and no
        array is consulted -- `build_indices[i] == i` on every producer in the
        tree, so the array only ever returned the number used to read it."""
        if self._bi_elided:
            return chain_idx
        return self.build_indices[chain_idx]

    @always_inline
    def kn_stride(self) -> Int:
        """Words per fused chain entry: 2 shipped, 4 under payload-inline.

        ⚠ EVERY READER OF `key_next` MUST MULTIPLY BY THIS AND NOT BY 2. A site
        that keeps the literal reads entry 2i where it meant entry i -- keys
        belonging to other rows and links into the middle of the array -- which
        surfaces as a join that silently loses and invents matches, not as a
        crash.
        """
        return JOIN_KN_WORDS_PAY if self._pay_inline else JOIN_KN_WORDS

    @always_inline
    def chain_key_at(self, chain_idx: Int) -> Int64:
        """The build key stored at chain entry `chain_idx`, either layout."""
        if self._fused:
            return self.key_next[self.kn_stride() * chain_idx]
        return self.build_keys[chain_idx]

    @always_inline
    def chain_next_at(self, chain_idx: Int) -> Int:
        """The chain link out of entry `chain_idx`, either layout."""
        if self._fused:
            return Int(self.key_next[self.kn_stride() * chain_idx + 1])
        return self.next_chain[chain_idx]

    @always_inline
    def chain_pay_at(self, chain_idx: Int) raises -> Int64:
        """The INLINED build payload for chain entry `chain_idx`.

        ⛔ ONLY MEANINGFUL UNDER `_pay_inline`, AND IT RAISES OTHERWISE. On the
        shipped layout the word this would return is the NEXT ENTRY'S KEY -- a
        wrong answer of the right type, in a column the caller is about to
        emit. There is no plausible default here, so there is no default.
        """
        if not self._pay_inline:
            raise Error(
                "HashJoinBuilder.chain_pay_at: this index carries no inlined"
                " payload (the payload-inline flag off, or the width gate"
                " declined this join)"
            )
        return self.key_next[JOIN_KN_WORDS_PAY * chain_idx + 2]

    @always_inline
    def pay_build_col(self) -> Int:
        """The build-batch column the inlined payload copies, or -1."""
        return self._pay_build_col

    @always_inline
    def pay_inline(self) -> Bool:
        """Does this index carry an inlined build payload in its entries?"""
        return self._pay_inline

    @always_inline
    def uses_bloom(self) -> Bool:
        """Will a probe of this index consult the bloom filter?

        ⭐ THIS IS BLOOML1'S "TOOK EFFECT" OBSERVABLE, AND IT IS STRUCTURAL
        RATHER THAN A COUNTER ON PURPOSE. Declining a bloom is value-invariant,
        so no answer-comparing test can see the difference, and a counter can
        only say the predicate DECIDED — a build that notched the decline and
        then populated the filter anyway moves every counter correctly. This
        field is what the probe actually reads, so asserting it is the only
        assertion a build of that shape cannot satisfy.
        """
        return self._use_bloom

    def _refuse_pay_inline(self, kernel: StaticString) raises:
        """Guard for a kernel that hoists `key_next` at the SHIPPED stride.

        ⛔ NOT DEFENSIVE PROGRAMMING -- THE ALTERNATIVE TO A SILENT WRONG
        ANSWER. NINE kernels hoist `key_next` onto a raw pointer and index it
        `2 * chain_idx`. Exactly THREE were taught the wide stride -- the two
        chunked INNER probes and their shared row-at-a-time tail -- because
        those are the ones the lever is FOR. The other SIX (`_probe_inner_into`,
        `_probe_semi`, `_probe_semi_count`, `_probe_left_into`, `_probe_anti`,
        `_probe_anti_count`) would read entry 2i where they meant entry i --
        keys belonging to other rows, links into the middle of the array -- and
        produce a join result with a plausible row count and wrong contents.

        ⚠ `count_inner_matches`, `probe_right` and `probe_full` are NOT in
        either list and need no guard: they walk through `chain_key_at` /
        `chain_next_at`, which are stride-aware, so they are already CORRECT
        under the wide layout (merely not accelerated by it).

        Arming is confined to the INNER chunked path by the driver, so this
        cannot fire in production today. It is stated anyway because a runtime
        convention that holds only while one driver stays correct is exactly
        what the type system cannot enforce, and a refusal is the only outcome
        that cannot be mistaken for success.
        """
        if self._pay_inline:
            raise Error(
                String("HashJoinBuilder.")
                + String(kernel)
                + ": this kernel reads the chain entry at the SHIPPED 16-byte"
                " stride and cannot walk a payload-inline (32-byte) index. The"
                " payload-inline gate must not arm an index this kernel probes."
            )

    # -------------------------------------------------------------------------
    # BUILD -- `join_build_serial`
    # -------------------------------------------------------------------------

    @staticmethod
    def build_with_bloom(
        keys: PrimitiveArray[DType.int64],
        var bloom: BloomFilter,
        nobi: Bool = True,
        fused: Bool = True,
    ) raises -> HashJoinBuilder:
        """Build the index over a caller's PRE-POPULATED bloom. See
        `join_build_serial.hash_join_build_with_bloom`."""
        return _hash_join_build_with_bloom(keys, bloom^, nobi, fused)

    @staticmethod
    def build(
        keys: PrimitiveArray[DType.int64],
        build_bloom: Bool = True,
        nobi: Bool = True,
        fused: Bool = True,
        var pay_values: List[Int64] = List[Int64](),
        pay_build_col: Int = -1,
    ) raises -> HashJoinBuilder:
        """Build the index from the build-side key column, serially. See
        `join_build_serial.hash_join_build`."""
        return _hash_join_build(
            keys,
            build_bloom=build_bloom,
            nobi=nobi,
            fused=fused,
            pay_values=pay_values^,
            pay_build_col=pay_build_col,
        )

    # -------------------------------------------------------------------------
    # PROBES -- the kernels are free functions over a borrowed builder, in
    # `join_probe_inner`, `join_probe_semi_anti` and `join_probe_outer`; these
    # methods forward to them.
    # -------------------------------------------------------------------------

    def probe_inner_into(
        self,
        probe_keys: PrimitiveArray[DType.int64],
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """INNER probe appending (build row, probe row) pairs to the caller's
        lists. See `join_probe_inner.probe_inner_into`."""
        _probe_inner_into_entry(self, probe_keys, build_matches, probe_matches)

    def probe_inner(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Tuple[List[Int], List[Int]]:
        """INNER probe returning (build rows, probe rows)."""
        return _probe_inner(self, probe_keys)

    def avg_chain_length(self) -> Int:
        """Build rows per non-empty bucket (at least 1); O(capacity)."""
        return _avg_chain_length(self)

    def count_inner_matches(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Int:
        """The number of INNER pairs, without materialising them."""
        return _count_inner_matches(self, probe_keys)

    def probe_inner_start(self) -> ProbeInnerState:
        """A cursor at the start of a chunked INNER probe."""
        return ProbeInnerState()

    def probe_inner_chunk[
        o_build: Origin[mut=True],
        o_probe: Origin[mut=True],
        o_pay: Origin[mut=True],
    ](
        self,
        probe_keys: PrimitiveArray[DType.int64],
        mut state: ProbeInnerState,
        build_buf: Span[Int, o_build],
        probe_buf: Span[Int, o_probe],
        pay_buf: Span[Int64, o_pay],
        chunk_capacity: Int,
    ) raises -> Int:
        """The next chunk of INNER pairs into the caller's spans; 0 when the
        probe is exhausted. See `join_probe_inner.probe_inner_chunk`."""
        return _probe_inner_chunk_entry(
            self, probe_keys, state, build_buf, probe_buf, pay_buf,
            chunk_capacity,
        )

    def probe_semi(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> List[Int]:
        """Probe rows with at least one match, each once."""
        return _probe_semi(self, probe_keys)

    def probe_semi_count(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Int:
        """`len(probe_semi(probe_keys))` without the list."""
        return _probe_semi_count(self, probe_keys)

    def probe_anti(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> List[Int]:
        """Probe rows with no match (a NULL probe key has none)."""
        return _probe_anti(self, probe_keys)

    def probe_anti_count(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Int:
        """`len(probe_anti(probe_keys))` without the list."""
        return _probe_anti_count(self, probe_keys)

    def probe_left_into(
        self,
        probe_keys: PrimitiveArray[DType.int64],
        mut build_matches: List[Int],
        mut probe_matches: List[Int],
    ) raises:
        """LEFT probe appending pairs, -1 for an unmatched probe row."""
        _probe_left_into_entry(self, probe_keys, build_matches, probe_matches)

    def probe_left(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Tuple[List[Int], List[Int]]:
        """LEFT probe returning (build rows or -1, probe rows)."""
        return _probe_left(self, probe_keys)

    def probe_right(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Tuple[List[Int], List[Int]]:
        """RIGHT probe: matches, then every unmatched build row with -1."""
        return _probe_right(self, probe_keys)

    def probe_full(
        self, probe_keys: PrimitiveArray[DType.int64]
    ) raises -> Tuple[List[Int], List[Int]]:
        """FULL probe: matches, unmatched probe rows (-1 build), then
        unmatched build rows (-1 probe)."""
        return _probe_full(self, probe_keys)
