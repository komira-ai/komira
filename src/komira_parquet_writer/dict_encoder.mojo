# =============================================================================
# Dictionary encoding of string columns for the Parquet writer
# =============================================================================
#
# One pass over the column: each value is looked up in (or inserted into)
# a dictionary of unique values, and the row's dictionary index is written
# at once. Low-cardinality string columns compress well this way: instead of
# repeating the full string bytes for every row, each row stores a 4-byte
# Int32 index into the dictionary.
#
# The encoded output is a DictEncodingResult containing:
#   - indices: PrimitiveArray[DType.int32], one index per row
#   - dictionary: StringArray of unique values in insertion order
#
# The dictionary page and data page encoders (a later part of this package)
# write it. Numeric columns are `dict_encoder_numeric`.
# =============================================================================

from std.memory import memcmp

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.offset_overflow import ARROW_INT32_OFFSET_MAX
from komira_buffer.heap_region import HeapRegion
from komira_collections.hyperloglog import HyperLogLog


struct DictEncodingResult(Movable):
    """Result of dictionary encoding a string column.

    Contains the encoded indices and the dictionary of unique values.
    Uses a struct instead of a Tuple because PrimitiveArray and StringArray
    are Movable but not ImplicitlyCopyable, and Tuple element access
    requires implicit copy.

    Fields:
        success: False when the streaming cardinality pre-estimate decided
                 the column is too high-cardinality to dict-encode; in that
                 case `indices`/`dictionary` are empty and the caller must
                 fall straight to PLAIN — WITHOUT having built the full
                 dictionary (the dict-build-then-abandon waste this avoids).
        indices: PrimitiveArray[DType.int32] mapping each row to a dict entry.
        dictionary: StringArray holding the unique string values.
    """

    var success: Bool
    var indices: PrimitiveArray[DType.int32]
    var dictionary: StringArray[HeapRegion]

    def __init__(
        out self,
        var indices: PrimitiveArray[DType.int32],
        var dictionary: StringArray[HeapRegion],
    ):
        self.success = True
        self.indices = indices^
        self.dictionary = dictionary^

    def __init__(
        out self,
        success: Bool,
        var indices: PrimitiveArray[DType.int32],
        var dictionary: StringArray[HeapRegion],
    ):
        self.success = success
        self.indices = indices^
        self.dictionary = dictionary^

    @staticmethod
    def abandoned() raises -> DictEncodingResult:
        """Empty result signalling the pre-estimate aborted the dict build."""
        var empty_indices = PrimitiveArray[DType.int32].allocate(0)
        var empty_strings: List[String] = []
        var empty_dict = StringArray.from_strings(empty_strings)
        return DictEncodingResult(False, empty_indices^, empty_dict^)


# Number of leading rows sampled by the streaming cardinality pre-estimate.
# The dict-vs-PLAIN decision is made from an HLL sketch over this prefix
# (plus a worst-case linear extrapolation), BEFORE the full dictionary is
# built. Cheap: ~one FNV+splitmix hash per sampled row. 8192 is large
# enough to separate genuinely-low-cardinality columns (which we want to
# dict) from near-unique columns like TPC-H `l_comment` (which we must NOT
# dict-build-then-abandon). Mirrors DuckDB's sampled-cardinality gate.
comptime DICT_PREESTIMATE_SAMPLE_ROWS: Int = 8192

# Pre-estimate abandon ratio. If the estimated distinct/total fraction
# exceeds this, skip the full dict build entirely. Slightly looser than the
# exact 0.4 cardinality threshold the dictionary page encoder applies, so the
# cheap estimate never abandons a column the exact check would have kept —
# the exact check still runs downstream on the (rare) borderline columns.
comptime DICT_PREESTIMATE_ABANDON_RATIO: Float64 = 0.55

# Minimum row count below which the streaming pre-estimate is NOT trusted and
# the full dictionary is always built.
#
# The pre-estimate exists purely as a PERF optimization: skip a large
# dict-build that would only be thrown away on a near-unique column
# (TPC-H l_comment: 6M rows, ~28% of the encode wall when it was built and
# abandoned).
# On small inputs the dict build is cheap, so abandoning it saves nothing —
# and the gate is actively WRONG there for two reasons:
#   1. A precision-12 HLL over a handful of rows has large relative error;
#      its `estimate()` over-reports distinct count on tiny samples.
#   2. `abandon_at = Int(n * 0.55)` truncates harshly for small n (n=4 -> 2,
#      n=5 -> 2), so a genuinely low-cardinality 4-row column trips the gate.
# Both push small low/medium-cardinality columns (and the all-unique edge
# case) into a wrong `abandoned()` -> empty result for the DIRECT
# `encode_dict_column` caller. Below this threshold we always build the dict;
# the exact downstream cardinality check (the dictionary page encoder) decides
# dict-vs-PLAIN on the write path. The estimator's l_comment win is preserved
# (6M rows is far above any small threshold).
comptime DICT_PREESTIMATE_MIN_ROWS: Int = 4096


# =============================================================================
# Internal byte-content-keyed open-address dictionary table
# =============================================================================
#
# Keys reference UTF-8 byte ranges DIRECTLY inside the source column's data
# buffer (no owned `String` per row). Each entry stores
# `(data_offset, length)` into that buffer plus the assigned dict index.
# Hashing + equality operate on the borrowed bytes via a concrete-origin
# pointer obtained from the source's `view_ro()` — the pointer is held in a
# private field and never escapes this module (encapsulation rule), and its
# lifetime is bounded by the `strings` borrow that constructs it.
#
# A `Dict[String, Int]` keyed on a heap-allocated `String` per row costs
# ~30M allocations on a TPC-H lineitem write, which profiled at 73% of the
# encode wall.


struct _SpanDictTable[src_origin: Origin[mut=False]]:
    """Open-address (linear-probe) table keyed on borrowed UTF-8 byte ranges.

    `_src` is a Span over the source StringArray's data buffer, with the
    concrete immutable origin of the `view_ro()` borrow that outlives this
    table. Keys are `(offset, length)` ranges inside it; hashing and equality
    read the bytes through the span's pointer, inside `_hash` and `_eq` only.
    """

    var _src: Span[UInt8, Self.src_origin]
    # Parallel arrays indexed by slot. `_slot_used[s]` gates the slot;
    # when used, `_slot_off`/`_slot_len` describe the key's byte range and
    # `_slot_idx` is the assigned dictionary index.
    var _slot_used: List[Bool]
    var _slot_off: List[Int32]
    var _slot_len: List[Int32]
    var _slot_idx: List[Int32]
    var _mask: Int
    var _count: Int

    def __init__(
        out self,
        src: Span[UInt8, Self.src_origin],
        capacity_pow2: Int,
    ):
        self._src = src
        self._slot_used = List[Bool](capacity=capacity_pow2)
        self._slot_off = List[Int32](capacity=capacity_pow2)
        self._slot_len = List[Int32](capacity=capacity_pow2)
        self._slot_idx = List[Int32](capacity=capacity_pow2)
        for _ in range(capacity_pow2):
            self._slot_used.append(False)
            self._slot_off.append(Int32(0))
            self._slot_len.append(Int32(0))
            self._slot_idx.append(Int32(0))
        self._mask = capacity_pow2 - 1
        self._count = 0

    @always_inline
    def _hash(self, off: Int, length: Int) -> UInt64:
        """FNV-1a over the byte range, then a splitmix-style avalanche."""
        # SAFETY: `[off, off+length)` lies within `_src` (the caller passes
        # ranges from the source's own offsets buffer); the pointer has
        # `_src`'s concrete origin and is read only inside this loop.
        var p = self._src.unsafe_ptr()
        var h = UInt64(0xCBF29CE484222325)
        comptime fnv_prime = UInt64(0x00000100000001B3)
        for i in range(length):
            h = h ^ UInt64((p + off + i)[])
            h = h * fnv_prime
        # splitmix64 finalize (FNV's upper bits are weak on their own).
        var x = h + UInt64(0x9E3779B97F4A7C15)
        x = (x ^ (x >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B5)
        x = (x ^ (x >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        return x ^ (x >> UInt64(31))

    @always_inline
    def _eq(self, a_off: Int, a_len: Int, b_off: Int, b_len: Int) -> Bool:
        """Byte-equality of two ranges inside the source buffer."""
        if a_len != b_len:
            return False
        if a_len == 0:
            return True
        # SAFETY: both ranges lie within `_src`; the pointer has `_src`'s
        # concrete origin and does not outlive this call.
        var p = self._src.unsafe_ptr()
        return memcmp(p + a_off, p + b_off, a_len) == 0

    def get_or_insert(mut self, off: Int, length: Int, next_idx: Int) -> Int:
        """Return the dict index for the byte range, inserting if absent.

        Returns the existing index when the content already maps; otherwise
        records `next_idx` and returns it. The caller appends to its dict
        value list exactly when the returned index equals `next_idx`.
        """
        var slot = Int(self._hash(off, length)) & self._mask
        while self._slot_used[slot]:
            if self._eq(
                off, length,
                Int(self._slot_off[slot]), Int(self._slot_len[slot]),
            ):
                return Int(self._slot_idx[slot])
            slot = (slot + 1) & self._mask
        self._slot_used[slot] = True
        self._slot_off[slot] = Int32(off)
        self._slot_len[slot] = Int32(length)
        self._slot_idx[slot] = Int32(next_idx)
        self._count += 1
        return next_idx


@always_inline
def _next_pow2_at_least(n: Int) -> Int:
    """Smallest power of two >= max(n, 1)."""
    var p = 1
    while p < n:
        p = p << 1
    return p


def _estimate_string_cardinality(strings: StringArray[HeapRegion]) raises -> Int:
    """Streaming cardinality estimate via an HLL sketch over a row prefix.

    Hashes the borrowed bytes of the first `DICT_PREESTIMATE_SAMPLE_ROWS`
    non-null rows (zero-copy `get_span`, no heap String) into a precision-12
    HyperLogLog, then linearly extrapolates the sampled distinct count to the
    full row count. Returns an estimate of the column's total distinct count.

    This is the gate that lets `encode_dict_column` skip the full dict build
    on near-unique columns (e.g. `l_comment`) instead of building the whole
    dictionary and abandoning it.
    """
    var n = strings.length
    var sample_n = min(n, DICT_PREESTIMATE_SAMPLE_ROWS)
    if sample_n == 0:
        return 0

    var hll = HyperLogLog()
    var sampled = 0
    var i = 0
    while i < n and sampled < sample_n:
        if not strings.is_null(i):
            # Zero-copy borrowed bytes — no per-row String alloc.
            var span = strings.get_span(i)
            # SAFETY: `span.unsafe_ptr()` is a concrete-origin pointer over
            # `span`'s borrowed bytes; used only for this single hash call,
            # never stored or returned.
            var h = _hll_hash_span(span)
            hll.add_hash(h)
            sampled += 1
        i += 1

    var sampled_distinct = hll.estimate()
    if sampled >= n:
        # We saw the whole column; no extrapolation needed.
        return sampled_distinct

    # Linear extrapolation of the sampled distinct count to the full column.
    # This OVER-estimates for skewed (repeat-heavy) columns and is roughly
    # right for uniform ones — both are fine for a conservative dict gate
    # (over-estimating only risks PLAIN-encoding a borderline column).
    var scaled = Float64(sampled_distinct) * (Float64(n) / Float64(sampled))
    if scaled > Float64(n):
        scaled = Float64(n)
    return Int(scaled + 0.5)


@always_inline
def _hll_hash_span(span: Span[UInt8, _]) -> UInt64:
    """FNV-1a + splitmix64 over a borrowed byte span (no heap alloc).

    SAFETY: `span.unsafe_ptr()` is a concrete-origin pointer; read-only,
    used only within this call, never stored.
    """
    var ptr = span.unsafe_ptr()
    var length = len(span)
    var h = UInt64(0xCBF29CE484222325)
    comptime fnv_prime = UInt64(0x00000100000001B3)
    for i in range(length):
        h = h ^ UInt64((ptr + i)[])
        h = h * fnv_prime
    var x = h + UInt64(0x9E3779B97F4A7C15)
    x = (x ^ (x >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B5)
    x = (x ^ (x >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    return x ^ (x >> UInt64(31))


def encode_dict_column(strings: StringArray[HeapRegion]) raises -> DictEncodingResult:
    """Single-pass dictionary encoding for a string column (zero-copy).

    Scans all values once: for each string, looks up or inserts into the
    dictionary, and writes the dictionary index immediately.

    Two efficiency properties (vs a `Dict[String, Int]` that heap-allocates
    a `String` per row, which profiled at 73% of the encode wall):

    1. **Zero-copy keys**: rows are keyed on their borrowed UTF-8 byte ranges
       (`get_span`) through a content-keyed open-address table, NOT on owned
       `String`s. No per-row heap alloc; only one byte-copy per UNIQUE value
       when the dictionary buffer is materialized.
    2. **Streaming cardinality pre-estimate**: before building the full
       dictionary, an HLL over a row prefix estimates distinct count. If the
       column is near-unique (e.g. `l_comment`), we abandon EARLY
       (`success=False`) instead of building the whole dict then throwing it
       away. The caller falls straight to PLAIN.

    The dictionary preserves insertion order.

    Args:
        strings: The StringArray to dictionary-encode.

    Returns:
        A DictEncodingResult. When `success == False` the pre-estimate
        decided the column is too high-cardinality; the caller must
        PLAIN-encode. Otherwise:
        - indices: PrimitiveArray[DType.int32] with one index per row
        - dictionary: StringArray of unique values in insertion order

    Example:
        Input:  ["apple", "banana", "apple", "cherry", "banana"]
        Output: indices=[0, 1, 0, 2, 1], dict=["apple", "banana", "cherry"].
    """
    var n = strings.length

    if n == 0:
        # Empty input -> empty indices + empty dictionary.
        var empty_indices = PrimitiveArray[DType.int32].allocate(0)
        var empty_strings: List[String] = []
        var empty_dict = StringArray.from_strings(empty_strings)
        return DictEncodingResult(empty_indices^, empty_dict^)

    # Streaming cardinality pre-estimate: abandon the dict build EARLY when
    # the column looks near-unique. Saves the full dict-build cost on
    # high-cardinality columns (an l_comment dict-then-abandon was ~28% of
    # the encode wall).
    #
    # Only trusted at scale: below DICT_PREESTIMATE_MIN_ROWS the HLL estimate
    # is unreliable and the dict build is cheap, so we always build (see the
    # constant's rationale). This keeps the direct `encode_dict_column`
    # contract intact for small inputs (correct values, never empty) while
    # preserving the large-column abandon win. Below the threshold the table
    # is sized from the row count itself (a safe upper bound on distinct).
    var est_distinct = n
    if n >= DICT_PREESTIMATE_MIN_ROWS:
        est_distinct = _estimate_string_cardinality(strings)
        var abandon_at = Int(Float64(n) * DICT_PREESTIMATE_ABANDON_RATIO)
        if est_distinct > abandon_at:
            return DictEncodingResult.abandoned()

    # Borrow the source data buffer ONCE; the ByteView (and the raw pointer
    # we hand to the table) live exactly as long as `data_view`, which is
    # alive through the build loop below. The offsets are read via the
    # offsets view. No heap String per row.
    var data_view = strings.data.view_ro()
    var offsets_view = strings.offsets.view_ro()

    # Size the open-address table for the estimated distinct count (with
    # headroom to keep the load factor < ~0.7). Cap at 2x num rows.
    var table_cap = _next_pow2_at_least(
        min(max(est_distinct * 2, 16), max(n * 2, 16))
    )
    # The span has the concrete origin of `data_view`, which outlives
    # `table` (both live to the end of this function).
    var table = _SpanDictTable(data_view.into_span(), table_cap)

    # Accumulate the dictionary directly into Arrow (offsets, data) Lists so
    # the finalize is a single zero-re-serialize `from_buffers` adopt. One
    # byte-copy per UNIQUE value (vs the old per-row String alloc).
    var dict_offsets = List[Int32](capacity=max(est_distinct + 1, 2))
    dict_offsets.append(Int32(0))
    var dict_data = List[UInt8]()
    var dict_count = 0

    var indices = PrimitiveArray[DType.int32].allocate(n)
    # SAFETY: typed-origin pointer drop-in for the tight encode loop.
    var indices_ptr = indices._typed_ptr_mut()

    for i in range(n):
        var start = Int(offsets_view.get_typed[Int32](i))
        var end = Int(offsets_view.get_typed[Int32](i + 1))
        var slen = end - start
        var assigned = table.get_or_insert(start, slen, dict_count)
        (indices_ptr + i)[] = Int32(assigned)
        if assigned == dict_count:
            # New unique value — copy its bytes into the dict data buffer.
            if slen > 0:
                # SAFETY: `[start, end)` lies within the source data buffer;
                # `data_view` is the live borrow backing `_unsafe_ptr()`.
                var src = data_view._unsafe_ptr() + start
                for b in range(slen):
                    dict_data.append((src + b)[])
            dict_count += 1
            dict_offsets.append(Int32(len(dict_data)))

    # Keepalive: the views borrow `strings` through the loop above.
    _ = data_view
    _ = offsets_view

    # Build the dictionary StringArray from the accumulated Arrow buffers.
    var dictionary = StringArray.from_buffers(
        dict_offsets, dict_data, None, 0
    )

    return DictEncodingResult(indices^, dictionary^)


def _estimate_large_string_cardinality(
    strings: LargeStringArray[HeapRegion],
) raises -> Int:
    """The Int64-offset twin of `_estimate_string_cardinality`.

    Byte-for-byte the same sketch over the same prefix; only the array type
    (and therefore the offsets stride inside `get_span`) differs.
    """
    var n = strings.length
    var sample_n = min(n, DICT_PREESTIMATE_SAMPLE_ROWS)
    if sample_n == 0:
        return 0

    var hll = HyperLogLog()
    var sampled = 0
    var i = 0
    while i < n and sampled < sample_n:
        if not strings.is_null(i):
            var span = strings.get_span(i)
            # SAFETY: as `_estimate_string_cardinality` — the span's pointer is
            # used for this single hash call and never stored.
            var h = _hll_hash_span(span)
            hll.add_hash(h)
            sampled += 1
        i += 1

    var sampled_distinct = hll.estimate()
    if sampled >= n:
        return sampled_distinct

    var scaled = Float64(sampled_distinct) * (Float64(n) / Float64(sampled))
    if scaled > Float64(n):
        scaled = Float64(n)
    return Int(scaled + 0.5)


def encode_dict_column_large(
    strings: LargeStringArray[HeapRegion],
) raises -> DictEncodingResult:
    """Dictionary-encode a `large_string` column (the Int64-offset twin of
    `encode_dict_column`).

    Identical algorithm — HLL pre-estimate, one open-address pass, first-seen
    insertion order — reading the source offsets at Int64 stride.

    ★ IT ABANDONS (`success=False`, caller PLAIN-encodes) WHEN THE SOURCE
    PAYLOAD EXCEEDS `ARROW_INT32_OFFSET_MAX`, AND THAT IS A DELIBERATE,
    STATED LIMIT rather than an oversight:

      * `_SpanDictTable` keys each row by its `(offset, length)` **as
        `Int32`** (`_slot_off` / `_slot_len`). Above 2 GiB those slot fields
        would wrap, so two different rows could compare equal and the
        dictionary would map a row onto the wrong value — a WRONG ANSWER,
        not a refusal. Widening them is a separate change with its own
        memory cost (two extra Int32s per slot for every parquet write in
        the tree), and it buys nothing here;
      * the fallback is the PLAIN BYTE_ARRAY page encoder, which is
        width-correct at **any** size. So the column is always WRITTEN; only
        the size optimisation is skipped;
      * a column that big is also, by construction, one where dictionary
        encoding is least likely to apply — the 40% cardinality gate rejects
        anything near-unique, and the large-string columns that need Int64
        offsets are typically join keys.

    Args:
        strings: The LargeStringArray to dictionary-encode.

    Returns:
        A DictEncodingResult; `success == False` means "PLAIN-encode this".
    """
    var n = strings.length

    if n == 0:
        var empty_indices = PrimitiveArray[DType.int32].allocate(0)
        var empty_strings: List[String] = []
        var empty_dict = StringArray.from_strings(empty_strings)
        return DictEncodingResult(empty_indices^, empty_dict^)

    # See the block comment above: above the int32 ceiling the probe table's
    # Int32 slot keys cannot address the source, so refuse to dict-encode.
    if strings.data_length > ARROW_INT32_OFFSET_MAX:
        return DictEncodingResult.abandoned()

    var est_distinct = n
    if n >= DICT_PREESTIMATE_MIN_ROWS:
        est_distinct = _estimate_large_string_cardinality(strings)
        var abandon_at = Int(Float64(n) * DICT_PREESTIMATE_ABANDON_RATIO)
        if est_distinct > abandon_at:
            return DictEncodingResult.abandoned()

    var data_view = strings.data.view_ro()
    var offsets_view = strings.offsets.view_ro()

    var table_cap = _next_pow2_at_least(
        min(max(est_distinct * 2, 16), max(n * 2, 16))
    )
    # As the narrow twin: a span with `data_view`'s concrete origin.
    var table = _SpanDictTable(data_view.into_span(), table_cap)

    var dict_offsets = List[Int32](capacity=max(est_distinct + 1, 2))
    dict_offsets.append(Int32(0))
    var dict_data = List[UInt8]()
    var dict_count = 0

    var indices = PrimitiveArray[DType.int32].allocate(n)
    # SAFETY: typed-origin pointer drop-in for the tight encode loop.
    var indices_ptr = indices._typed_ptr_mut()

    for i in range(n):
        var start = Int(offsets_view.get_typed[Int64](i))
        var end = Int(offsets_view.get_typed[Int64](i + 1))
        var slen = end - start
        var assigned = table.get_or_insert(start, slen, dict_count)
        (indices_ptr + i)[] = Int32(assigned)
        if assigned == dict_count:
            if slen > 0:
                # SAFETY: `[start, end)` lies within the source data buffer;
                # `data_view` is the live borrow backing `_unsafe_ptr()`.
                var src = data_view._unsafe_ptr() + start
                for b in range(slen):
                    dict_data.append((src + b)[])
            dict_count += 1
            dict_offsets.append(Int32(len(dict_data)))

    # Keepalive: the views borrow `strings` through the loop above.
    _ = data_view
    _ = offsets_view

    var dictionary = StringArray.from_buffers(dict_offsets, dict_data, None, 0)

    return DictEncodingResult(indices^, dictionary^)
