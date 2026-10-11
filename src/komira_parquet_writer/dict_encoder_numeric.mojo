# =============================================================================
# Dictionary encoding of numeric columns for the Parquet writer
# =============================================================================
#
# INT32 / INT64 / FLOAT32 / FLOAT64 (any fixed-width numeric dtype): one pass
# keyed on each value's EXACT bits, abandoned (`success=False`, the caller
# PLAIN-encodes) when the column holds more than
# `NUMERIC_DICT_MAX_CARDINALITY` distinct values, with a sampled
# cardinality pre-estimate that refuses a build the column can never keep.
# String columns are `dict_encoder`.
# =============================================================================

from std.memory import bitcast

from komira_arrow.primitive_array import PrimitiveArray

from .dict_encoder import DICT_PREESTIMATE_SAMPLE_ROWS, _next_pow2_at_least


# Cardinality cap for numeric dictionary encoding. Matches DuckDB's
# `MAX_DICT_CARDINALITY` heuristic — beyond this, the index width + dict
# page overhead overwhelms the per-value savings (each PLAIN INT64 value
# is 8 bytes; a 32K dict + ceil(log2(32K))=15-bit indices crosses over
# around 30K unique values).
comptime NUMERIC_DICT_MAX_CARDINALITY: Int = 32 * 1024

# --- numeric cardinality PRE-ESTIMATE knobs (see the block comment above
# `_sample_numeric_cardinality`) ---------------------------------------------
#
# Minimum distinct fraction EACH sampling pass must show before the estimate
# is allowed to refuse a dict build.
#
# ⚠ THIS WAS 95, AND 95 REFUSES A COLUMN SITTING EXACTLY ON THE CAP. The
# inversion that justified it — `E[u]/s = (1 - e^(-s/D)) / (s/D)` — is the
# INFINITE-POPULATION (sample-with-replacement) occupancy identity, i.e. the
# `n -> inf` limit. The writer never sees that limit: a column of `n` rows
# holding `D` distinct values has each value on `n/D` rows, and a sample of
# `s` POSITIONS draws them WITHOUT replacement, so
#
#     E[u] = D * (1 - (1 - s/n)^(n/D))
#
# and the finite-population value is materially HIGHER exactly where it
# matters — when `n` is within a few multiples of the cap, so each value sits
# on only a handful of rows. Worked, at `s = 4,096` and `D = 32,768` (a
# column ON the cap, which the exact build KEEPS):
#
#     n = 68,000 -> E[u]/s = 96.8%     n = 200,000 -> 94.9%
#     n = 100,000 -> 95.8%             n = 1,000,000 -> 93.9%
#
# The old 95% threshold sits UNDER the first two. `E[u]/s` is monotone
# decreasing in `n`, and below `n ~ 68,000` the extrapolation condition (c)
# is what refuses to fire, so 96.8% is the worst case over the whole
# refusable range. 98 clears it by 1.2 points — about 4 sigma of the
# sampling noise on `u` (std ~ 13 counts = 0.3 points at these rates).
#
# ⛔ DO NOT LOWER THIS BACK TO 95 TO "RECOVER COVERAGE". What 98 costs is
# columns whose cardinality is between 1x and ~1.6x the cap: they pay the
# doomed build, exactly as they did before the pre-estimate existed. What 95
# cost was REFUSING columns UNDER the cap — a silent compression regression
# with nothing red. Those two are not commensurable.
comptime NUMERIC_DICT_PREESTIMATE_UNIQUE_PCT: Int = 98

# Rows visited by EACH sampling pass. 4,096 is the sample size the threshold
# above is calibrated for, and `_sample_numeric_cardinality` reaching fewer
# than this is a REFUSAL TO REFUSE, never a scaled-down decision — see
# condition (0) in the block comment.
comptime NUMERIC_DICT_SAMPLE_ROWS_PER_PASS: Int = DICT_PREESTIMATE_SAMPLE_ROWS // 2

# Consecutive rows per block in the BLOCKED pass.
comptime NUMERIC_DICT_SAMPLE_BLOCK_LEN: Int = 128

# The extrapolated cardinality must clear the cap by this factor before the
# estimate refuses. Guards the SHORT near-unique column (33,000 distinct rows
# extrapolates to 33,000 — barely over the cap, so build it and let the exact
# check decide).
comptime NUMERIC_DICT_PREESTIMATE_ABANDON_FACTOR: Int = 2

# Floor for the probe table's initial slot count. Matches the historical
# `_NumericDictTable(64)` literal so a tiny column allocates no more than it
# used to.
comptime NUMERIC_DICT_TABLE_MIN_SLOTS: Int = 64


# =============================================================================
# Numeric dictionary encoding (INT32 / INT64 / FLOAT32 / FLOAT64)
# =============================================================================
#
# Mirrors the string-side `encode_dict_column` shape, but keyed on the
# Scalar's EXACT bit-pattern (cast to Int64) so the same table can hash any
# fixed-width numeric dtype.
#
# ⛔ THE FLOAT KEY IS AN IDENTITY, NOT AN SQL-EQUALITY CLASS. Canonicalising
# NaN and signed zero "so SQL equality semantics are preserved" is a silent
# data-corrupting write defect: the encoder stores the FIRST-SEEN member of
# each collapsed class, so a `+0.0` that arrives after a `-0.0` is written to
# disk as `-0.0`. A dictionary page is a LOSSLESS re-encoding, not a
# grouping. See `_float64_exact_bits` for the full invariant.
#
# The dict values are stored as a `List[Scalar[dtype]]` in insertion
# order; this is the simplest form to memcpy into the PLAIN-encoded
# DICTIONARY_PAGE body downstream. We do NOT round-trip through
# `PrimitiveArray` because the dict page wants a flat byte-packed value
# stream, not an Arrow array.
#
# This encoder ABORTS early (via `success=False`) when cardinality
# exceeds `NUMERIC_DICT_MAX_CARDINALITY`; callers should fall back to
# PLAIN encoding. The threshold matches DuckDB's `MAX_DICT_CARDINALITY`.


@always_inline
def _float32_exact_bits(v: Float32) -> Int64:
    """Map a Float32 to its EXACT Int64 key -- its bits, sign-extended.

    AN IDENTITY, NOT A HASH-CANONICALISATION; see `_float64_exact_bits`.
    `Int32 -> Int64` sign-extension is INJECTIVE, so two Float32 values with
    different bit patterns can never collide on this key.
    """
    return Int64(bitcast[DType.int32, 1](v.to_bits()))


@always_inline
def _float64_exact_bits(v: Float64) -> Int64:
    """Map a Float64 to its EXACT Int64 key -- its bits, nothing else.

    DO NOT INTRODUCE A CANONICALISATION HERE (collapsing `-0.0` onto `+0.0`,
    or every NaN onto one sentinel, as a join key's hash does). A JOIN key
    MUST collapse a class that SQL calls equal; a DICTIONARY PAGE MUST NOT.

    THE INVARIANT: a parquet dictionary page is a LOSSLESS RE-ENCODING of the
    value stream, not a grouping. `dict_values[code]` must reproduce the
    source value BIT FOR BIT, so two rows may share a dictionary entry only
    if they are BITWISE IDENTICAL. Keying on the SQL-equality class and then
    storing the FIRST-SEEN member of that class (`encode_numeric_dict_column`
    appends `val` the first time a key is seen) rewrites every LATER member
    as the FIRST one's bits: a FLOAT64 column `[-0.0, 1.5, -2.5, +0.0, 8.0]`
    is written as `[-0.0, 1.5, -2.5, -0.0, 8.0]`, wrong bytes for every
    reader. It is invisible to every value comparison, because `0.0 == -0.0`
    is True in Mojo, in Python, in DuckDB and in SQL; only a SIGN-BIT read
    sees it (`tests/test_dict_encoder_numeric_direct.mojo` reads it).

    WHAT THIS MEANS FOR A CONSUMER THAT COMPARES DICTIONARY INDICES:
      * `code_a != code_b` does not imply the VALUES differ: `+0.0` and
        `-0.0` are two entries that compare equal. Parquet never promised
        it; a dictionary predicate is evaluated on each dictionary VALUE
        into a LUT and then mapped over codes, which stays correct under
        duplicate entries.
      * `code_a == code_b` implies BITWISE-IDENTICAL values. That is the
        property the writer's losslessness needs.

    NaN PAYLOADS ARE PRESERVED BY THE SAME ARGUMENT. `NaN != NaN` is not a
    hazard for the probe table because the key is compared as an Int64 and
    never as a float.

    Float statistics are unaffected: they are computed from the source
    values (`writer_float_stats`), never from the dictionary.
    """
    return bitcast[DType.int64, 1](v.to_bits())


@always_inline
def _scalar_to_exact_int64_key[dtype: DType](v: Scalar[dtype]) -> Int64:
    """EXACT, INJECTIVE Int64 dictionary key for a Scalar[dtype].

    Every arm is injective on the source bit pattern -- that is the contract
    the dictionary's losslessness rests on, and the reason this is NOT the
    canonicalisation a join uses to hash a join key.
    Integer dtypes widen to Int64 (no information is lost up to Int64);
    floats bitcast through their exact-bits helpers.
    """
    comptime if dtype == DType.float64:
        return _float64_exact_bits(rebind[Float64](v))
    elif dtype == DType.float32:
        return _float32_exact_bits(rebind[Float32](v))
    else:
        # All integer dtypes (INT8..INT64, UINT8..UINT64): widen via Int64
        # ctor. Signed/unsigned 64-bit widths preserve their full bit
        # pattern under the cast on a two's-complement target.
        return Int64(v)


# =============================================================================
# Flat open-addressed numeric dictionary probe table (AOS, MurmurHash64)
# =============================================================================
#
# In place of the stdlib `Dict[Int64, Int]` (SwissTable), which profiled as
# the largest parquet-write encode CPU term (~20% of wall). For the dominant
# case on TPC-H lineitem (every
# dict-numeric column is <64 distinct: l_linenumber ~7, l_quantity ~50,
# l_discount/l_tax ~11, date INT32s), a small flat open-address table that
# fits in L1 — cheap MurmurHash64-2-multiply + linear probing over ONE
# contiguous AOS slot array — beats the SwissTable's group-probe + per-byte
# hash with no cache misses and warm branch prediction.
#
# Layout: parallel `List[Int64]` (exact value bits) + `List[Int32]` (dict
# indices). The index slot doubles as the occupancy flag: `idx == -1` means
# empty. A real dict index is always `>= 0`, and the key `0`
# (valid for integer 0 / +0.0) is NOT used as a sentinel, so key=0 collides
# with nothing. Both element types are register-passable POD scalars — no
# heap-owning field, so no wildcard-origin hazard.
#
# Insertion-order invariant (byte-identical output gate): a NEW key is only
# ever recorded the first time it is seen in the scan, and the caller appends
# to `dict_values` exactly then — so the dict-value order and the per-row
# indices are bit-for-bit identical to a `Dict`-keyed build. The hash
# table is an internal lookup accelerator; it does not influence which value
# gets which index.


comptime _DICT_EMPTY_SLOT: Int32 = -1


@always_inline
def _murmur64(key: Int64) -> UInt64:
    """MurmurHash64 finalizer (2-multiply, branchless) over an Int64 key.

    Mirrors DuckDB's numeric `MurmurHash64` (`types/hash.hpp:38-49`): a pair
    of multiply-xorshift rounds. Far cheaper than FNV's per-byte loop for a
    fixed 8-byte key, and good avalanche for the low-distinct integer/float
    bit patterns the parquet dict columns carry.
    """
    var h = UInt64(key)
    h = h ^ (h >> UInt64(33))
    h = h * UInt64(0xFF51AFD7ED558CCD)
    h = h ^ (h >> UInt64(33))
    h = h * UInt64(0xC4CEB9FE1A85EC53)
    h = h ^ (h >> UInt64(33))
    return h


struct _NumericDictTable:
    """Open-address (linear-probe) flat AOS table: exact Int64 key -> dict index.

    Internal-only accelerator for `encode_numeric_dict_column[dtype]`. Holds two
    parallel contiguous lists indexed by slot; no pointer escapes this struct.
    Grows (rehash) when the load factor would exceed ~0.7.
    """

    var _keys: List[Int64]
    var _idxs: List[Int32]
    var _mask: Int
    var _count: Int
    # Number of times `_grow` ran. ⚠ NOT bookkeeping: it is the ONLY
    # observable that separates "abandoned after building the whole
    # dictionary" from "abandoned before building it" — both return a
    # byte-identical `abandoned()` result, deliberately. The regression
    # guard for PARQUET-WRITE-NUMERIC-DICT-PREESTIMATE reads it through
    # `NumericDictEncodingResult.table_grows`; without it the defect is
    # invisible to any black-box assertion and only a stopwatch can see it.
    var _grows: Int

    @always_inline
    def __init__(out self, capacity_pow2: Int):
        self._keys = List[Int64](capacity=capacity_pow2)
        self._idxs = List[Int32](capacity=capacity_pow2)
        # `resize` is a bulk fill; the prior per-slot `append` loop paid a
        # capacity check per element and was 2 x capacity_pow2 calls on
        # EVERY construction and every grow (262,016 of them per FLOAT64
        # column on a 100K-row write).
        self._keys.resize(capacity_pow2, Int64(0))
        self._idxs.resize(capacity_pow2, _DICT_EMPTY_SLOT)
        self._mask = capacity_pow2 - 1
        self._count = 0
        self._grows = 0

    @always_inline
    def grows(self) -> Int:
        """How many rehash-doublings this table has paid."""
        return self._grows

    @always_inline
    def _grow(mut self):
        """Double capacity and re-probe every live entry (rare on low-card)."""
        var new_cap = (self._mask + 1) << 1
        var old_keys = self._keys^
        var old_idxs = self._idxs^
        self._keys = List[Int64](capacity=new_cap)
        self._idxs = List[Int32](capacity=new_cap)
        self._keys.resize(new_cap, Int64(0))
        self._idxs.resize(new_cap, _DICT_EMPTY_SLOT)
        self._mask = new_cap - 1
        self._grows += 1
        var old_n = len(old_idxs)
        # SAFETY: contiguous backing buffers; bounded by `old_n` / `new_cap`.
        var ok_ptr = old_keys.unsafe_ptr()
        var oi_ptr = old_idxs.unsafe_ptr()
        var nk_ptr = self._keys.unsafe_ptr()
        var ni_ptr = self._idxs.unsafe_ptr()
        for i in range(old_n):
            var idx = (oi_ptr + i)[]
            if idx == _DICT_EMPTY_SLOT:
                continue
            var key = (ok_ptr + i)[]
            var slot = Int(_murmur64(key)) & self._mask
            while (ni_ptr + slot)[] != _DICT_EMPTY_SLOT:
                slot = (slot + 1) & self._mask
            (nk_ptr + slot)[] = key
            (ni_ptr + slot)[] = idx

    @always_inline
    def get_or_insert(mut self, key: Int64, next_idx: Int) -> Int:
        """Return the dict index for `key`, inserting `next_idx` if absent.

        Returns the existing index when the key already maps; otherwise
        records `next_idx` and returns it. The caller appends to its
        `dict_values` list exactly when the returned value equals `next_idx`,
        preserving first-seen insertion order (byte-identical output gate).
        """
        # SAFETY: `_keys`/`_idxs` are contiguous, length == _mask+1; `slot`
        # is masked into range on every step. No pointer escapes.
        var keys_ptr = self._keys.unsafe_ptr()
        var idxs_ptr = self._idxs.unsafe_ptr()
        var slot = Int(_murmur64(key)) & self._mask
        while (idxs_ptr + slot)[] != _DICT_EMPTY_SLOT:
            if (keys_ptr + slot)[] == key:
                return Int((idxs_ptr + slot)[])
            slot = (slot + 1) & self._mask
        (keys_ptr + slot)[] = key
        (idxs_ptr + slot)[] = Int32(next_idx)
        self._count += 1
        # Keep load factor < ~0.7 to bound probe length on the rare
        # higher-cardinality case (low-card columns never reach this).
        if self._count * 10 >= (self._mask + 1) * 7:
            self._grow()
        return next_idx


struct NumericDictEncodingResult[dtype: DType](Movable):
    """Result of dictionary-encoding a numeric column.

    Fields:
        success: False when cardinality exceeded the threshold; in that
                 case `indices` and `dict_values` are empty and the caller
                 must fall back to PLAIN encoding.
        indices: PrimitiveArray[DType.int32] mapping each row to a dict
                 entry. Only meaningful when `success == True`.
        dict_values: List of unique Scalar[dtype] values in insertion
                 order. Ready to memcpy into a PLAIN DICTIONARY_PAGE body.
    """

    var success: Bool
    var indices: PrimitiveArray[DType.int32]
    var dict_values: List[Scalar[Self.dtype]]
    # Rehash-doublings paid by the internal probe table on the way to this
    # result. ⚠ It is the ONLY thing that distinguishes an abandon the
    # pre-estimate took for free from an abandon paid for with a full
    # dict build — both results are otherwise byte-identical, on purpose.
    # `tests/test_numeric_dict_preestimate.mojo` asserts it is 0 on the
    # 100%-distinct shape; do not delete it to "clean up" the struct.
    var table_grows: Int
    # Slot count the internal probe table was BORN at (0 when no table was
    # built). ⚠ Same reason as `table_grows`, different failure: an
    # OVER-sized table grows ZERO times, so `table_grows` cannot see it at
    # all. `size_hint` was initialised to `n_valid`, and only the sampled
    # branch overwrote it, so every column below the sampling gate was
    # pre-sized off its ROW COUNT — a 3,000-row / 2-distinct column born at
    # 8,192 slots (98 KB of zero-fill) instead of 64 (768 B). The committed
    # `test_tiny_column_is_unaffected` could not catch it either: n = 12 is
    # the one size in 0..4,095 that lands back on the 64-slot floor.
    # `test_small_column_is_born_at_the_minimum_table` reads this field.
    var table_start_slots: Int

    def __init__(
        out self,
        success: Bool,
        var indices: PrimitiveArray[DType.int32],
        var dict_values: List[Scalar[Self.dtype]],
        table_grows: Int = 0,
        table_start_slots: Int = 0,
    ):
        self.success = success
        self.indices = indices^
        self.dict_values = dict_values^
        self.table_grows = table_grows
        self.table_start_slots = table_start_slots

    @staticmethod
    def abandoned(
        table_grows: Int, table_start_slots: Int
    ) -> NumericDictEncodingResult[Self.dtype]:
        """Return an empty result signalling cardinality overflow.

        `table_grows` records how much probe-table growth was paid before
        the column was abandoned — 0 when the cardinality pre-estimate
        refused the build up front, ~10 when the full dictionary was
        built and thrown away. `table_start_slots` is 0 on the free abandon
        for the same reason: no table was ever born.
        """
        var empty_indices = PrimitiveArray[DType.int32].allocate(0)
        var empty_values = List[Scalar[Self.dtype]]()
        return NumericDictEncodingResult[Self.dtype](
            False, empty_indices^, empty_values^, table_grows, table_start_slots
        )


# =============================================================================
# Numeric cardinality PRE-ESTIMATE — refusing a dictionary the column can
# never let us keep
# =============================================================================
#
# ★ WHY THIS EXISTS. On a 100%-distinct FLOAT64 column a plain build runs
# the FULL dictionary and then throws every byte of it away: the dictionary
# page encoder stops the instant `success == False`, BEFORE statistics,
# thrift, def-levels or RLE, so nothing below the abandon point survives. And
# it does it in the most expensive shape available — the probe table is born
# at 64 slots and has to reach 65,536, ~10 zero-fill-and-rehash steps, with
# 92% of the 406,092 table operations per column being that growth cascade
# against 32,769 real inserts. Measured at 4.63% of a single-row-group
# write's profile, on the thread that drives the write.
#
# The STRING arm (`_estimate_string_cardinality` in `dict_encoder`) already
# samples, estimates and refuses the build up front. This is that gate for
# the numeric arm.
#
# ⛔ THE GATE IS ONE-SIDED ONLY UNDER A PRECONDITION, AND THE PRECONDITION IS
# PART OF THE GATE. Refusing a column the exact build would have KEPT is a
# silent compression regression — it writes BYTE_STREAM_SPLIT /
# DELTA_BINARY_PACKED where a dictionary page belonged, and nothing goes red.
#
# ⚠ THIS PARAGRAPH USED TO READ "ONE-SIDED BY CONSTRUCTION". IT WAS NOT, AND
# SAYING SO IS HOW THE NEXT ENGINEER STOPS CHECKING. There is no construction
# argument available: a sample of 4,096 rows cannot PROVE anything about a
# column of 100,000, and every "by construction" claim here has in fact been
# an assumption about how the sample is drawn. Four shapes have now broken it,
# each found after the claim was re-asserted:
#
#   1. RUN-STRUCTURED — a sorted key reads 100% distinct under a pure stride.
#      Patched by adding the BLOCKED pass.
#   2. TILED — a repeating cycle reads 100% distinct under blocks. Patched by
#      adding the STRIDED pass. "By construction" was then re-asserted.
#   3. SPARSE / NULLABLE — `sampled` is the count of NON-NULL rows hit, and
#      the landed sampler skipped a null with `continue` and never made it up,
#      so the sample COLLAPSED as the null fraction rose (at 7% non-null,
#      s = 287, not 4,096) while the threshold stayed calibrated for 4,096.
#      A half-null FLOAT64 column with 32,000 distinct values — 768 under the
#      cap — was refused.
#   4. NEAR-CAP FINITE POPULATION — the threshold itself was inverted with the
#      wrong model (see `NUMERIC_DICT_PREESTIMATE_UNIQUE_PCT`). A plainly
#      shuffled column of 32,000 distinct values over 100,000 rows, no nulls
#      and no structure at all, read 95.4% and was refused.
#
# So the honest statement, which is what this gate now enforces, is:
#
#   ★ ONE-SIDED UNDER A SAMPLE OF s = NUMERIC_DICT_SAMPLE_ROWS_PER_PASS ROWS
#     DRAWN UNIFORMLY OVER THE WHOLE COLUMN.
#
# FIVE conditions must ALL hold, and (0) is the precondition made executable:
#
#   (0) EVERY pass actually REACHED `s`. `_sample_numeric_cardinality` walks
#       PAST a null inside the run's own region rather than giving up the
#       slot, so an ordinary nullable column still yields a full sample; a
#       column too sparse or too null-CLUSTERED to fill one simply does not
#       get the optimisation. A scaled-down sample is never a scaled-down
#       decision — the threshold does not scale with s, it is calibrated AT s.
#   (a) `n_valid > NUMERIC_DICT_MAX_CARDINALITY`. Below the cap the exact
#       build can NEVER abandon, so neither may the estimate. This is also
#       the gate on SAMPLING AT ALL: between `DICT_PREESTIMATE_MIN_ROWS` and
#       the cap the refusal is structurally unreachable, so the two (now
#       three) probe tables and 12,288 probes bought nothing there.
#   (b) EVERY pass is at least `NUMERIC_DICT_PREESTIMATE_UNIQUE_PCT` %
#       distinct — the finite-population threshold, derived at that constant.
#   (c) the linear extrapolation clears the cap by
#       `NUMERIC_DICT_PREESTIMATE_ABANDON_FACTOR`. This keeps a column that
#       is near-unique but simply too SHORT to overflow the dictionary, and
#       it is what covers the regime `n_valid` barely over the cap, where
#       (b) cannot discriminate at all (a cap-sized all-distinct column reads
#       100% however it is sampled).
#   (d) THREE spreads agree, not two. Each alone has a column shape it reads
#       as unique when it is not, and each added spread can only NARROW the
#       refusal — requiring one more conjunct cannot create a mis-refusal:
#         * BLOCKED — 32 runs of 128 CONSECUTIVE rows. Immune to periodicity;
#           it is what refuses a run-length-structured column (shape 1).
#         * STRIDED — every (n/4096)-th row. Immune to locality; it is what
#           refuses a TILED column (shape 2).
#         * SCATTERED — one row per stratum of width n/4096, at a
#           MurmurHash-jittered offset INSIDE that stratum. Both of the other
#           two are arithmetic progressions, so a cycle whose period is
#           coprime to the step reads 100% distinct under BOTH: `i % 30011`
#           over 100,000 rows is 30,011 distinct — 2,757 under the cap — and
#           blocked and strided each read it 4,096/4,096. Only a spread that
#           is not an arithmetic progression can see it. Stratifying (rather
#           than hashing over the whole array) keeps the positions distinct,
#           so no row is double-counted as distinct evidence.
#
# EXACT, NOT HLL. Each pass's distinct count is counted exactly in a pre-sized
# `_NumericDictTable` (load factor 0.5, so it cannot rehash). At 4,096 samples
# that is the same order of work as a precision-12 HLL (whose `rho` step is
# itself a scalar loop) and it takes estimator error out of the decision
# entirely, so the refusal is argued from the sample statistic alone.
#
# SIZING IS A SEPARATE, STRICTLY BYTE-IDENTICAL USE OF THE SAME SAMPLES. The
# probe table is born at twice the LARGEST pass's own distinct count — NEVER
# at the extrapolation. ⛔ Extrapolating for sizing would allocate a
# 65,536-slot (786 KB) table for the <64-distinct lineitem columns the
# historical `64` literal exists to keep in L1: `l_quantity` is ~50 distinct
# over 6M rows and extrapolates to ~73,000. The sampled distinct count is a
# HARD LOWER BOUND on the column's cardinality and cannot do that.
# ⛔ AND `size_hint` STARTS AT 0, NOT AT `n_valid`. It was `n_valid`, and only
# the sampled branch overwrote it, so every column BELOW the sampling gate was
# pre-sized straight off its ROW COUNT — the one thing the paragraph above
# forbids: n_valid = 3,000 with two distinct values was born at 8,192 slots
# (98 KB of zero-fill) instead of 64 (768 B). Unsampled means UNKNOWN, and
# unknown must fall through to `NUMERIC_DICT_TABLE_MIN_SLOTS`.
# The table is an internal accelerator — `dict_values` order and the per-row
# indices come from first-seen scan order and do not depend on its capacity —
# so sizing can never change a written byte. `table_start_slots` on the result
# is what lets a test SEE that, since nothing else about the output moves.


@fieldwise_init
struct _NumericSampleStats(Copyable, Movable):
    """Exact distinct count over a strided sample of a numeric column.

    Fields:
        sampled: Non-null rows actually visited.
        distinct: EXACT number of distinct exact-bit keys among them.
    """

    var sampled: Int
    var distinct: Int


def _sample_numeric_cardinality[dtype: DType](
    array: PrimitiveArray[dtype],
    n_valid: Int,
    block_len: Int,
    scatter: Bool,
) raises -> _NumericSampleStats:
    """Count distinct values EXACTLY over one spread of the whole column.

    Lays `NUMERIC_DICT_SAMPLE_ROWS_PER_PASS` rows out as `target / block_len`
    runs of `block_len` rows, each run owning a DISJOINT region of the array
    so no row is ever counted twice as distinct evidence. `block_len == 1` is
    a pure stride and `block_len == 128` the blocked pass; `scatter` starts
    each run at a MurmurHash-jittered offset inside its own region, which is
    the only one of the three that is not an arithmetic progression.

    ⛔ A NULL DOES NOT COST THE SAMPLE A SLOT. The first version of this
    `continue`d past a null and moved on, so `sampled` — the denominator the
    95% (now 98%) threshold is calibrated against — collapsed with the null
    fraction: at 7% non-null a "4,096-row sample" was 287 rows, and the
    threshold read off it refused columns 27,000 under the cap. The walk now
    continues forward (wrapping once inside the run's OWN region, never into
    the next one) until the run has its `block_len` non-null rows. A column
    too sparse or too null-clustered to fill the sample returns a SHORT one,
    and the caller treats short as "do not refuse" — never as a decision
    scaled down to fit.

    Each value is keyed with the same injective `_scalar_to_exact_int64_key`
    the real build uses, into a probe table pre-sized to twice the target —
    load factor tops out at 0.5, so this table can never rehash.

    Args:
        array: The column being considered for dictionary encoding.
        n_valid: Non-null row count (`length - null_count`).
        block_len: Rows per run (>= 1).
        scatter: Jitter each run's start inside its own region.

    Returns:
        `_NumericSampleStats` with the rows visited and their exact
        distinct count. `sampled < NUMERIC_DICT_SAMPLE_ROWS_PER_PASS` means
        the column could not fill the sample.
    """
    var n = array.length
    var target = min(n_valid, NUMERIC_DICT_SAMPLE_ROWS_PER_PASS)
    if target <= 0:
        return _NumericSampleStats(0, 0)

    var blk = max(min(block_len, target), 1)
    var num_blocks = max(target // blk, 1)
    # Each run owns `region` consecutive rows and never reads outside them.
    var region = max(n // num_blocks, blk)

    var probe = _NumericDictTable(_next_pow2_at_least(max(target * 2, 16)))
    var has_nulls = array.null_count > 0
    var sampled = 0
    var distinct = 0
    for b in range(num_blocks):
        var base = b * region
        if base >= n:
            break
        var limit = min(base + region, n)
        var width = limit - base
        var cursor = base
        if scatter:
            cursor = base + Int(_murmur64(Int64(b)) % UInt64(max(width, 1)))
        var got = 0
        var steps = 0
        while steps < width and got < blk and sampled < target:
            var row = cursor
            steps += 1
            cursor += 1
            if cursor >= limit:
                cursor = base
            if has_nulls and array.is_null(row):
                continue
            var val = array.load[1](row)[0]
            var key = _scalar_to_exact_int64_key[dtype](val)
            var assigned = probe.get_or_insert(key, distinct)
            if assigned == distinct:
                distinct += 1
            sampled += 1
            got += 1
    return _NumericSampleStats(sampled, distinct)


@always_inline
def _sample_is_near_unique(sample: _NumericSampleStats) -> Bool:
    """True iff the pass saw at least UNIQUE_PCT % distinct values."""
    if sample.sampled <= 0:
        return False
    return (
        sample.distinct * 100
        >= sample.sampled * NUMERIC_DICT_PREESTIMATE_UNIQUE_PCT
    )


@always_inline
def _sample_is_full(sample: _NumericSampleStats) -> Bool:
    """True iff the pass reached the sample size the threshold assumes.

    ⛔ Condition (0) of the one-sidedness argument. `UNIQUE_PCT` is calibrated
    AT `NUMERIC_DICT_SAMPLE_ROWS_PER_PASS`; read off a smaller sample it means
    something else entirely, and what it meant was "refuse columns under the
    cap". Short sample => no refusal, never a rescaled one.
    """
    return sample.sampled >= NUMERIC_DICT_SAMPLE_ROWS_PER_PASS


def encode_numeric_dict_column[dtype: DType](
    array: PrimitiveArray[dtype],
) raises -> NumericDictEncodingResult[dtype]:
    """Single-pass dictionary encoding for a numeric column.

    Walks the array once: takes each value's EXACT bits as the key
    (`_scalar_to_exact_int64_key`, injective -- see its docstring for why
    an SQL-equality key corrupted the output), looks up or inserts into the
    table, and writes the dictionary index. Bails early with
    `success=False` if cardinality exceeds `NUMERIC_DICT_MAX_CARDINALITY`.

    Null rows are skipped (their slot in `indices` is left at zero —
    callers must filter via the validity bitmap before writing the
    data-page index stream). The dict is built only from non-null
    values, mirroring DuckDB's behaviour.

    Args:
        array: The PrimitiveArray to dictionary-encode.

    Returns:
        A NumericDictEncodingResult[dtype]. When `success == False` the
        caller should fall back to PLAIN encoding via
        `encode_plain_column[dtype]`.
    """
    var n = array.length

    if n == 0:
        var empty_indices = PrimitiveArray[DType.int32].allocate(0)
        var empty_values = List[Scalar[dtype]]()
        return NumericDictEncodingResult[dtype](True, empty_indices^, empty_values^)

    var has_nulls = array.null_count > 0
    # ⚠ `null_count` is a CACHED field, not a recount. It is used here only
    # to SIZE the sample and the extrapolation denominator — never to decide
    # whether a row is null (the sample and the build both call `is_null`),
    # so a stale value costs accuracy, never correctness.
    var n_valid = n - array.null_count

    # ------------------------------------------------------------------
    # CARDINALITY PRE-ESTIMATE (see the block comment above
    # `_sample_numeric_cardinality` for the one-sidedness argument).
    #
    # Three spreads, and two independent jobs off them:
    #   * REFUSE a build the column can never let us keep (the doomed build
    #     above) —
    #     needs ALL THREE spreads to agree AND each to have reached the full
    #     sample size, because each alone has a column shape it reads as
    #     unique when it is not;
    #   * SIZE the probe table so the survivors stop paying the ~10-step
    #     zero-fill-and-rehash cascade from 64 slots.
    #
    # ⛔ THE SAMPLING GATE IS THE CAP, NOT `DICT_PREESTIMATE_MIN_ROWS`. It was
    # `n_valid >= DICT_PREESTIMATE_MIN_ROWS` (4,096) while the refusal needs
    # `n_valid > NUMERIC_DICT_MAX_CARDINALITY` (32,768), so across that whole
    # band the passes ran and COULD NOT refuse — they were priced as "probe
    # inserts" but each also builds an 8,192-slot `_NumericDictTable`
    # (~96 KB of List capacity plus a `resize` zero-fill), so a 4,096-row
    # column with 5 distinct values paid ~288 KB of memset to learn a number
    # only the sizing could use. Sizing alone does not pay for that: such a
    # column sizes to 64 slots either way.
    # ------------------------------------------------------------------
    # ⛔ 0, NOT `n_valid` — "not sampled" means UNKNOWN, and unknown must fall
    # through to the historical 64-slot floor, not pre-size off the row count.
    var size_hint = 0
    if n_valid > NUMERIC_DICT_MAX_CARDINALITY:
        var blocked = _sample_numeric_cardinality[dtype](
            array, n_valid, NUMERIC_DICT_SAMPLE_BLOCK_LEN, False
        )
        var strided = _sample_numeric_cardinality[dtype](
            array, n_valid, 1, False
        )
        var scattered = _sample_numeric_cardinality[dtype](
            array, n_valid, 1, True
        )
        # The LARGEST pass's exact distinct count is the best hard LOWER
        # bound on the column's cardinality, and it is the sizing input.
        # Deliberately NOT the extrapolation — see the block comment.
        size_hint = max(
            max(blocked.distinct, strided.distinct), scattered.distinct
        )

        # `distinct / sampled * n_valid >= FACTOR * CAP`, cross-multiplied to
        # stay in exact integers (no Float64 anywhere in the decision). Read
        # off the SMALLEST pass, so a spread that merely looks unique because
        # of the column's structure cannot carry the refusal on its own.
        var lo_d = blocked.distinct
        var lo_s = blocked.sampled
        if strided.distinct * lo_s < lo_d * strided.sampled:
            lo_d = strided.distinct
            lo_s = strided.sampled
        if scattered.distinct * lo_s < lo_d * scattered.sampled:
            lo_d = scattered.distinct
            lo_s = scattered.sampled
        var clears_cap = lo_s > 0 and (
            lo_d * n_valid
            >= lo_s
            * NUMERIC_DICT_PREESTIMATE_ABANDON_FACTOR
            * NUMERIC_DICT_MAX_CARDINALITY
        )
        # Condition (0): the threshold below is calibrated AT
        # `NUMERIC_DICT_SAMPLE_ROWS_PER_PASS`. A pass that could not fill its
        # sample (a sparse or null-clustered column) forfeits the refusal —
        # it does not get a rescaled one.
        var full_sample = (
            _sample_is_full(blocked)
            and _sample_is_full(strided)
            and _sample_is_full(scattered)
        )
        if (
            full_sample
            and _sample_is_near_unique(blocked)
            and _sample_is_near_unique(strided)
            and _sample_is_near_unique(scattered)
            and clears_cap
        ):
            # The dictionary is structurally guaranteed to be discarded.
            # `table_grows = 0` and `table_start_slots = 0`: no table was ever
            # born, which is the whole point and the only thing a black-box
            # test can see.
            return NumericDictEncodingResult[dtype].abandoned(0, 0)

    # Flat open-address AOS probe table (MurmurHash64 + linear probe) keyed
    # on the EXACT Int64 bit pattern (see `_NumericDictTable` for why not the
    # stdlib `Dict`). Born at twice the sampled distinct count
    # (floor 64, ceiling 2x the abandon cap): every dict-numeric lineitem
    # column is <64 distinct and still lands in L1, while a genuinely
    # mid-cardinality column stops paying ten doublings to get where the
    # sample already said it was going.
    # ⚠ `size_hint == 0` means NOT SAMPLED, and it lands on
    # `NUMERIC_DICT_TABLE_MIN_SLOTS` — the historical `_NumericDictTable(64)`
    # literal — which is the whole point of initialising it to 0 rather than
    # to `n_valid`. `table_start_slots` carries the answer out so a test can
    # assert on it; nothing else about the result moves with capacity.
    var start_slots = _next_pow2_at_least(
        max(
            min(size_hint * 2, NUMERIC_DICT_MAX_CARDINALITY * 2),
            NUMERIC_DICT_TABLE_MIN_SLOTS,
        )
    )
    var table = _NumericDictTable(start_slots)
    var dict_values = List[Scalar[dtype]]()

    # `indices` is sized to `n` (the row count), not the non-null count.
    # Null rows get index 0 (a sentinel); the data-page emitter must
    # filter via the validity bitmap before encoding the index stream.
    # This matches the string-side shape where null slots are written
    # then later compacted out.
    var indices = PrimitiveArray[DType.int32].allocate(n)
    # SAFETY: typed-origin pointer drop-in for the tight encode loop.
    var indices_ptr = indices._typed_ptr_mut()

    for i in range(n):
        if has_nulls and array.is_null(i):
            (indices_ptr + i)[] = Int32(0)
            continue
        # `load[1]` is the SIMD scalar-load fast path; cheaper than
        # the raises `get` path (see string-side comment for parity).
        var val = array.load[1](i)[0]
        var key = _scalar_to_exact_int64_key[dtype](val)
        var next_idx = len(dict_values)
        var assigned = table.get_or_insert(key, next_idx)
        if assigned == next_idx:
            # New unique value — record it in first-seen order (byte-identical
            # to the prior Dict-keyed build: dict_values order + per-row
            # indices are unchanged).
            if next_idx >= NUMERIC_DICT_MAX_CARDINALITY:
                # Too many unique values — abandon and fall back to PLAIN.
                # `table.grows()` is what the pre-estimate exists to drive to
                # zero; carrying it out is how the regression guard sees the
                # difference between this abandon and a free one.
                return NumericDictEncodingResult[dtype].abandoned(
                    table.grows(), start_slots
                )
            dict_values.append(val)
        (indices_ptr + i)[] = Int32(assigned)

    return NumericDictEncodingResult[dtype](
        True, indices^, dict_values^, table.grows(), start_slots
    )
