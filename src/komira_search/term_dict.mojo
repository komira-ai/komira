# =============================================================================
# komira_search/term_dict.mojo
#   The TWO-STAGE term dictionary for ONE text field.
# =============================================================================
#
# Upstream contract: komira_search/inverted.mojo (the inverted index's
# FinalizedIndex read surface). Downstream contract: the split writer +
# SearchCore (the searcher).
#
# -----------------------------------------------------------------------------
# WHAT IT DOES
# -----------------------------------------------------------------------------
#   * TermDictBuilder.build_from_finalized(read fi) — one-shot build from a
#     FinalizedIndex by a SINGLE ascending-ordinal walk (NO re-sort: the
#     FinalizedIndex ordinal already IS the lexicographic position).
#   * Stage (a) SortedBlockTermMap — term-bytes -> ordinal, via sorted-block +
#     front-coding + a SEPARATE sparse-index first-term arena. The ONLY public
#     surface is lookup + serialize + deserialize (the FST-swap black box).
#   * Stage (b) TermInfoStore — ordinal -> TermInfo, a FLAT fixed-width
#     (24-byte = 3xu64-LE) array for O(1) random seek. Its format does not
#     change if stage (a) is swapped for an FST.
#   * TermDictionary — owns both stages + the field name; serialize /
#     deserialize / lookup / term_info_at / lookup_info / set_posting_location.
#
# -----------------------------------------------------------------------------
# THE FST-SWAP SEAM
# -----------------------------------------------------------------------------
# The container's offsets table makes stage (b) independently locatable/readable
# WITHOUT parsing stage (a). The named-surface discipline (TermInfoStore +
# posting reader contain NO block / sparse-index / front-decode /
# SortedBlockTermMap names — grep-auditable) is what makes an FST swap
# touch stage (a) + the deserialize dispatch ONLY.
#
# -----------------------------------------------------------------------------
# DESIGN POINTS B1–B8 (referenced by label below)
# -----------------------------------------------------------------------------
#   B1: this module uses `def` throughout (like inverted.mojo / analyzer.mojo).
#   B2: fail-loud decode bounds-safety — EVERY decoder-trusted length is
#       validated against the remaining/region bounds BEFORE any bulk read;
#       term lengths bounded by MAX_TERM_LEN; the front-decoder asserts
#       shared_prefix_len <= len(running scratch). All raise loudly on
#       violation (the split file is attacker-influenced at SearchCore query time).
#   B3: u64-LE for the variable length header fields (num_terms, num_blocks,
#       block_bytes_len, block_offset[], block_count[]) — kills the
#       u32-narrowing truncation hazard, matches the store's u64 fields.
#   B4: explicit empty-index canonical form (num_blocks=0, block_offset=[0]).
#   B5: serialize-once + fail-loud precondition (serialize raises if any
#       ordinal is still POSTING_LOC_UNSET when num_terms > 0).
#   B6: block first-terms are STRICTLY lexicographically ascending (the
#       upper_bound-minus-1 binary-search precondition).
#   B7: TermInfo stays pure-POD (guard comment on the struct).
#   B8: write_uleb128 is imported from komira_buffer.byte_buffer.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner re-audit)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature.
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * Every owning field is a POD List[Int] / List[UInt8], a plain Int,
#     or a top-level String (_field_name). NO Slab, NO heap-owning slab
#     element, NO wildcard origin, NO raw caller pointer. TermInfo is pure POD.
#     Borrowed reads return Span tied to the INNER field (origin_of(self._...)),
#     the same idiom as FinalizedIndex.
# =============================================================================

from komira_buffer.byte_buffer import ByteBuffer, write_uleb128

from .inverted import FinalizedIndex


# =============================================================================
# Module constants.
# =============================================================================

comptime BLOCK_TERMS: Int = 16
"""Terms per front-coded block (Lucene BlockTree / Tantivy SSTable convention;
locked decision). Distinct from the split writer's 128-DOC posting block. Block i covers
ordinals [i*BLOCK_TERMS, min((i+1)*BLOCK_TERMS, num_terms))."""

comptime POSTING_LOC_UNSET: Int = -1
"""Sentinel for posting_offset / posting_len before the split writer fills them. A valid
posting location is always >= 0, so -1 is an unambiguous 'the split writer has not patched
this row yet' marker."""

comptime MAX_TERM_LEN: Int = 64 * 1024
"""B2: upper bound on a single decoded term's byte length. A decoded length
exceeding this is treated as corruption and raises — guards against a
malicious / corrupt ULEB128 length prefix in the (attacker-influenced at SearchCore)
split file driving an unbounded allocation."""

# Container header constants.
comptime _MAGIC_LEN: Int = 6  # "STDICT"
comptime _STDICT_VERSION: UInt8 = 1
comptime _STORE_ROW_BYTES: Int = 24  # 3 x u64-LE


# =============================================================================
# TermInfo: the POD store record.
# =============================================================================


@fieldwise_init
struct TermInfo(Copyable, Movable, Deinitable):
    """One term's posting-list locator + statistic. The ordinal ->
    record contract that is FORMAT-FROZEN across an FST swap.

    Fields:
      posting_offset: byte offset of this term's posting list in the split's
                      posting region. RESERVED by the term dictionary (POSTING_LOC_UNSET);
                      FILLED by the split writer.
      posting_len:    byte length of this term's posting list. Same split-writer seam.
      doc_freq:       number of docs containing the term. FILLED by the term dictionary from
                      FinalizedIndex.doc_freq_at(ordinal) — single source; the split writer
                      MUST NOT recompute it.

    # MUST stay pure-POD — returned by value in Optional[TermInfo]; no
    # heap-owning field ever (a future positions handle must be an Int into a
    # side arena, never a List/Span/pointer).
    """

    var posting_offset: Int
    var posting_len: Int
    var doc_freq: Int


# =============================================================================
# Lexicographic byte compare (inline).
# =============================================================================


@always_inline
def _lex_less(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """True iff `a` < `b` in lexicographic byte order (shorter-is-less on a
    common-prefix tie). The standard min-len byte loop."""
    var la = len(a)
    var lb = len(b)
    var m = la if la < lb else lb
    for i in range(m):
        var ca = a[i]
        var cb = b[i]
        if ca != cb:
            return ca < cb
    return la < lb


@always_inline
def _lex_equal(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """True iff `a` and `b` are byte-equal."""
    var la = len(a)
    if la != len(b):
        return False
    for i in range(la):
        if a[i] != b[i]:
            return False
    return True


@always_inline
def _lex_le(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """True iff `a` <= `b` lexicographically."""
    return not _lex_less(b, a)


# =============================================================================
# SortedBlockTermMap: stage (a), the swappable black box.
# =============================================================================


struct SortedBlockTermMap(Movable, Deinitable):
    """Stage (a): term-bytes -> ordinal. v1 = sorted-block + front-coding +
    sparse offset index. The ONLY public surface is lookup + serialize +
    deserialize (the FST-swap black-box boundary). All owning fields are
    POD Lists (clean by construction).

    Deserialized in-memory form:
      _block_bytes:  all front-coded blocks concatenated.
      _block_offset: block i starts at _block_bytes[_block_offset[i]];
                     len == num_blocks + 1 (last entry is the total byte
                     length, so block i spans
                     [_block_offset[i], _block_offset[i+1])).
      _block_count:  block i holds _block_count[i] terms (the last block may be
                     a partial < BLOCK_TERMS).
      _first_bytes:  the FULL first term of each block, concatenated (the
                     sparse-index keys, for binary search WITHOUT front-decode).
      _first_offset: first-term i at [_first_offset[i], _first_offset[i+1]).
      _num_blocks / _num_terms.
    """

    var _block_bytes: List[UInt8]
    var _block_offset: List[Int]
    var _block_count: List[Int]
    var _first_bytes: List[UInt8]
    var _first_offset: List[Int]
    var _num_blocks: Int
    var _num_terms: Int

    def __init__(
        out self,
        var block_bytes: List[UInt8],
        var block_offset: List[Int],
        var block_count: List[Int],
        var first_bytes: List[UInt8],
        var first_offset: List[Int],
        num_blocks: Int,
        num_terms: Int,
    ):
        self._block_bytes = block_bytes^
        self._block_offset = block_offset^
        self._block_count = block_count^
        self._first_bytes = first_bytes^
        self._first_offset = first_offset^
        self._num_blocks = num_blocks
        self._num_terms = num_terms

    @always_inline
    def num_blocks(self) -> Int:
        return self._num_blocks

    @always_inline
    def num_terms(self) -> Int:
        return self._num_terms

    # ---- the sparse-index first-term accessor (binary-search key) ----

    def _first_term_at(
        self, b: Int
    ) raises -> Span[UInt8, origin_of(self._first_bytes)]:
        """Borrowed view of block `b`'s FULL first term (the sparse-index key).
        Origin tied to the INNER field. Raises on `b` out of range."""
        if b < 0 or b >= self._num_blocks:
            raise Error(
                "SortedBlockTermMap._first_term_at: block "
                + String(b)
                + " out of range [0, "
                + String(self._num_blocks)
                + ")"
            )
        var off = self._first_offset[b]
        var ln = self._first_offset[b + 1] - off
        return Span(self._first_bytes)[off : off + ln]

    # ---- lookup: term-bytes -> ordinal, or None ----

    def lookup(self, term_bytes: Span[UInt8, _]) raises -> Optional[Int]:
        """Stage (a): term-bytes -> ordinal, or None if absent. The FST-swap
        black-box surface (return type Optional[Int] regardless of impl).

        1. Binary-search the sparse index for the LAST block whose first term
           is <= term_bytes (std::upper_bound - 1 over _first_bytes). The first
           terms are STRICTLY ascending, the precondition for this search.
        2. Front-decode + linear-scan within that block for an EXACT match.
        """
        if self._num_blocks == 0:
            # B4: empty index — hi == 0, block == -1, no array indexed.
            return None

        # --- step 1: upper_bound - 1 binary search on first-terms ---
        var lo = 0
        var hi = self._num_blocks
        while lo < hi:
            var mid = (lo + hi) // 2
            var fmid = self._first_term_at(mid)
            if _lex_le(fmid, term_bytes):
                lo = mid + 1
            else:
                hi = mid
        var block = lo - 1
        if block < 0:
            # term_bytes < every block's first term.
            return None

        # --- step 2: front-decode + linear-scan within `block` ---
        return self._scan_block(block, term_bytes)

    def _scan_block(
        self, block: Int, term_bytes: Span[UInt8, _]
    ) raises -> Optional[Int]:
        """Front-decode block `block` term-by-term, comparing each decoded term
        to `term_bytes`. Returns block*BLOCK_TERMS + k on an exact match at
        within-block position k; None on a decoded term > term_bytes (sorted,
        so no later term matches) or block end.

        B2 fail-loud: every length read is bounds-validated against the block
        span before any bulk slice; term lengths are bounded by MAX_TERM_LEN;
        the front-decode asserts shared_prefix_len <= len(running scratch)
        before truncating."""
        var start = self._block_offset[block]
        var end = self._block_offset[block + 1]
        var count = self._block_count[block]

        # ByteBuffer cursor over JUST this block's bytes (so remaining() is the
        # block-local bound). Copy the block slice out so the cursor owns it.
        var block_buf = List[UInt8](capacity=end - start)
        for i in range(start, end):
            block_buf.append(self._block_bytes[i])
        var cur = ByteBuffer(block_buf^)

        var scratch = List[UInt8]()  # the running decoded term

        for k in range(count):
            if k == 0:
                # First term: full_len ULEB128 + full_bytes.
                var full_len = cur.read_uleb128()
                self._check_len(full_len, cur.remaining(), "full_len")
                scratch = List[UInt8]()
                cur.read_into_list(scratch, full_len)
            else:
                # Front-coded: shared_prefix_len + suffix_len + suffix_bytes.
                var shared = cur.read_uleb128()
                # B2: a corrupt shared_prefix_len > current decoded length would
                # index past the scratch buffer — fail loud BEFORE truncating.
                if shared < 0 or shared > len(scratch):
                    raise Error(
                        "SortedBlockTermMap: corrupt shared_prefix_len "
                        + String(shared)
                        + " > current decoded length "
                        + String(len(scratch))
                    )
                var suffix_len = cur.read_uleb128()
                self._check_len(suffix_len, cur.remaining(), "suffix_len")
                # Truncate scratch to the shared prefix, append the suffix.
                while len(scratch) > shared:
                    _ = scratch.pop()
                cur.read_into_list(scratch, suffix_len)
                self._check_term_len(len(scratch))

            # Compare the decoded term to the query.
            var decoded = Span(scratch)
            if _lex_equal(decoded, term_bytes):
                return block * BLOCK_TERMS + k
            if _lex_less(term_bytes, decoded):
                # Block is sorted ascending; no later term can match.
                return None
        return None

    @always_inline
    def _check_len(self, n: Int, bound: Int, what: String) raises:
        """B2: validate 0 <= n <= bound (the remaining bytes in the region)
        BEFORE any bulk read/slice of n bytes. Raises loudly on violation."""
        if n < 0 or n > bound:
            raise Error(
                "SortedBlockTermMap: decoded length "
                + what
                + "="
                + String(n)
                + " out of bounds [0, "
                + String(bound)
                + "] (corrupt term-dict bytes)"
            )

    @always_inline
    def _check_term_len(self, n: Int) raises:
        """B2: bound a decoded term's length by MAX_TERM_LEN."""
        if n > MAX_TERM_LEN:
            raise Error(
                "SortedBlockTermMap: decoded term length "
                + String(n)
                + " exceeds MAX_TERM_LEN "
                + String(MAX_TERM_LEN)
                + " (corrupt term-dict bytes)"
            )

    # ---- serialize / deserialize (B3 u64-LE) ----

    def serialize(self, mut out: List[UInt8]) raises:
        """Append the stage-(a) region bytes (B3 u64-LE for the
        variable length header fields):
          num_blocks:   u64 LE
          num_terms:    u64 LE
          block_offset[0 .. num_blocks]:  each u64 LE   (num_blocks+1 entries)
          block_count[0 .. num_blocks-1]: each u64 LE   (num_blocks entries)
          for b in [0, num_blocks):  first_len ULEB128 + first_bytes
          block_bytes_len: u64 LE
          block_bytes:     block_bytes_len bytes

        B4 empty form: num_blocks=0 -> block_offset has exactly one entry
        ([0]); block_count / first-terms empty; block_bytes_len=0.
        """
        _append_u64_le(out, UInt64(self._num_blocks))
        _append_u64_le(out, UInt64(self._num_terms))
        # block offset table (num_blocks + 1 entries).
        for i in range(self._num_blocks + 1):
            _append_u64_le(out, UInt64(self._block_offset[i]))
        # block counts (num_blocks entries).
        for i in range(self._num_blocks):
            _append_u64_le(out, UInt64(self._block_count[i]))
        # sparse-index first-terms (length-prefixed).
        for b in range(self._num_blocks):
            var off = self._first_offset[b]
            var ln = self._first_offset[b + 1] - off
            write_uleb128(ln, out)
            for i in range(off, off + ln):
                out.append(self._first_bytes[i])
        # the concatenated front-coded block bytes.
        _append_u64_le(out, UInt64(len(self._block_bytes)))
        for i in range(len(self._block_bytes)):
            out.append(self._block_bytes[i])

    @staticmethod
    def deserialize(mut cur: ByteBuffer) raises -> SortedBlockTermMap:
        """Reconstruct a SortedBlockTermMap from the cursor positioned at the
        start of a stage-(a) region. B2 fail-loud: every count/length is
        validated against the cursor's remaining bytes before any bulk read."""
        var num_blocks = Int(cur.read_u64_le())
        var num_terms = Int(cur.read_u64_le())
        if num_blocks < 0 or num_terms < 0:
            raise Error("SortedBlockTermMap.deserialize: negative count")

        # block offset table (num_blocks + 1 entries) — bound the read first.
        var n_off = num_blocks + 1
        # B2: each u64 is 8 bytes; ensure the table fits.
        if n_off * 8 > cur.remaining():
            raise Error(
                "SortedBlockTermMap.deserialize: block_offset table"
                " exceeds remaining bytes (corrupt)"
            )
        var block_offset = List[Int](capacity=n_off)
        for _ in range(n_off):
            block_offset.append(Int(cur.read_u64_le()))

        if num_blocks * 8 > cur.remaining():
            raise Error(
                "SortedBlockTermMap.deserialize: block_count table"
                " exceeds remaining bytes (corrupt)"
            )
        var block_count = List[Int](capacity=num_blocks)
        for _ in range(num_blocks):
            block_count.append(Int(cur.read_u64_le()))

        # sparse-index first-terms (length-prefixed).
        var first_bytes = List[UInt8]()
        var first_offset = List[Int](capacity=num_blocks + 1)
        first_offset.append(0)
        for _ in range(num_blocks):
            var ln = cur.read_uleb128()
            # B2: validate the length AND bound by MAX_TERM_LEN before reading.
            if ln < 0 or ln > cur.remaining():
                raise Error(
                    "SortedBlockTermMap.deserialize: first_len "
                    + String(ln)
                    + " out of bounds (corrupt)"
                )
            if ln > MAX_TERM_LEN:
                raise Error(
                    "SortedBlockTermMap.deserialize: first-term length "
                    + String(ln)
                    + " exceeds MAX_TERM_LEN (corrupt)"
                )
            cur.read_into_list(first_bytes, ln)
            first_offset.append(len(first_bytes))

        # the concatenated front-coded block bytes.
        var block_bytes_len = Int(cur.read_u64_le())
        if block_bytes_len < 0 or block_bytes_len > cur.remaining():
            raise Error(
                "SortedBlockTermMap.deserialize: block_bytes_len "
                + String(block_bytes_len)
                + " out of bounds (corrupt)"
            )
        var block_bytes = List[UInt8]()
        cur.read_into_list(block_bytes, block_bytes_len)

        return SortedBlockTermMap(
            block_bytes=block_bytes^,
            block_offset=block_offset^,
            block_count=block_count^,
            first_bytes=first_bytes^,
            first_offset=first_offset^,
            num_blocks=num_blocks,
            num_terms=num_terms,
        )


# =============================================================================
# TermInfoStore: stage (b), the stable half.
# =============================================================================
#
# NAMED-SURFACE DISCIPLINE: this struct + the future posting reader
# contain NO reference to `block`, `sparse index`, `front-decode`, or
# `SortedBlockTermMap`. It knows only "an ordinal in [0, num_terms)". This is
# what makes an FST swap touch stage (a) ONLY (grep-auditable).
# =============================================================================


struct TermInfoStore(Movable, Deinitable):
    """Stage (b): ordinal -> TermInfo, a FLAT fixed-width array. O(1) random
    access. Format-frozen across an FST swap. All owning fields POD.

      _posting_offset / _posting_len / _doc_freq: parallel, indexed by ordinal.
      _num_terms.

    Serialized as fixed-width 3xu64-LE rows (24 bytes/ordinal) so the on-disk
    store is one O(1)-seekable contiguous byte region.

    NAMED-SURFACE DISCIPLINE: this struct names NO stage-(a) internals —
    it knows only "an ordinal in [0, num_terms)". This is the grep-auditable
    invariant that makes an FST swap touch stage (a) ONLY. (The module
    header "FST-SWAP SEAM" section above describes the forbidden tokens.)
    """

    var _posting_offset: List[Int]
    var _posting_len: List[Int]
    var _doc_freq: List[Int]
    var _num_terms: Int

    def __init__(
        out self,
        var posting_offset: List[Int],
        var posting_len: List[Int],
        var doc_freq: List[Int],
        num_terms: Int,
    ):
        self._posting_offset = posting_offset^
        self._posting_len = posting_len^
        self._doc_freq = doc_freq^
        self._num_terms = num_terms

    @always_inline
    def num_terms(self) -> Int:
        return self._num_terms

    def get(self, ordinal: Int) raises -> TermInfo:
        """ordinal -> TermInfo, O(1). Raises on ordinal out of range."""
        if ordinal < 0 or ordinal >= self._num_terms:
            raise Error(
                "TermInfoStore.get: ordinal "
                + String(ordinal)
                + " out of range [0, "
                + String(self._num_terms)
                + ")"
            )
        return TermInfo(
            posting_offset=self._posting_offset[ordinal],
            posting_len=self._posting_len[ordinal],
            doc_freq=self._doc_freq[ordinal],
        )

    def set_posting_location(
        mut self, ordinal: Int, offset: Int, length: Int
    ) raises:
        """The split writer patches the posting location for `ordinal` after writing its
        posting bytes (the patch-pass seam). Raises on ordinal out of range or on
        offset/length < 0 (POSTING_LOC_UNSET is the only legal negative, and
        only as the initial state). doc_freq is NOT touched (the term dictionary owns it)."""
        if ordinal < 0 or ordinal >= self._num_terms:
            raise Error(
                "TermInfoStore.set_posting_location: ordinal "
                + String(ordinal)
                + " out of range [0, "
                + String(self._num_terms)
                + ")"
            )
        if offset < 0 or length < 0:
            raise Error(
                "TermInfoStore.set_posting_location: negative offset/length"
                " (offset="
                + String(offset)
                + ", length="
                + String(length)
                + ") — a valid posting location is >= 0"
            )
        self._posting_offset[ordinal] = offset
        self._posting_len[ordinal] = length

    def serialize(self, mut out: List[UInt8]) raises:
        """Append num_terms rows, each EXACTLY 24 bytes:
          posting_offset u64 LE + posting_len u64 LE + doc_freq u64 LE.

        B5: raises (fail-loud) if ANY ordinal is still POSTING_LOC_UNSET when
        num_terms > 0 — an unpatched store must never be silently placed."""
        for ordinal in range(self._num_terms):
            if (
                self._posting_offset[ordinal] == POSTING_LOC_UNSET
                or self._posting_len[ordinal] == POSTING_LOC_UNSET
            ):
                raise Error(
                    "TermInfoStore.serialize: ordinal "
                    + String(ordinal)
                    + " still has POSTING_LOC_UNSET — the split writer must"
                    " set_posting_location for every ordinal before serialize"
                    " (the posting-location patch pass)"
                )
            _append_u64_le(out, UInt64(self._posting_offset[ordinal]))
            _append_u64_le(out, UInt64(self._posting_len[ordinal]))
            _append_u64_le(out, UInt64(self._doc_freq[ordinal]))

    @staticmethod
    def deserialize(
        mut cur: ByteBuffer, num_terms: Int
    ) raises -> TermInfoStore:
        """Reconstruct a TermInfoStore from `num_terms` fixed-width rows at the
        cursor. B2 fail-loud: validate the whole region fits before reading."""
        if num_terms < 0:
            raise Error("TermInfoStore.deserialize: negative num_terms")
        if num_terms * _STORE_ROW_BYTES > cur.remaining():
            raise Error(
                "TermInfoStore.deserialize: store region ("
                + String(num_terms * _STORE_ROW_BYTES)
                + " bytes) exceeds remaining bytes (corrupt)"
            )
        var posting_offset = List[Int](capacity=num_terms)
        var posting_len = List[Int](capacity=num_terms)
        var doc_freq = List[Int](capacity=num_terms)
        for _ in range(num_terms):
            posting_offset.append(Int(cur.read_u64_le()))
            posting_len.append(Int(cur.read_u64_le()))
            doc_freq.append(Int(cur.read_u64_le()))
        return TermInfoStore(
            posting_offset=posting_offset^,
            posting_len=posting_len^,
            doc_freq=doc_freq^,
            num_terms=num_terms,
        )


# =============================================================================
# TermDictionary: the container the split writer places + SearchCore reads.
# =============================================================================


struct TermDictionary(Movable, Deinitable):
    """The two-stage term dictionary for ONE text field. Owns stage (a) +
    stage (b) + the field name. This is the value the split writer serializes into the
    split's term-dict region and SearchCore deserializes + queries.

      _stage_a: SortedBlockTermMap   # string -> ordinal (swappable)
      _stage_b: TermInfoStore        # ordinal -> TermInfo (frozen)
      _field_name: String            # which text field
    """

    var _stage_a: SortedBlockTermMap
    var _stage_b: TermInfoStore
    var _field_name: String

    def __init__(
        out self,
        var stage_a: SortedBlockTermMap,
        var stage_b: TermInfoStore,
        var field_name: String,
    ):
        self._stage_a = stage_a^
        self._stage_b = stage_b^
        self._field_name = field_name^

    @always_inline
    def num_terms(self) -> Int:
        return self._stage_b.num_terms()

    @always_inline
    def num_blocks(self) -> Int:
        return self._stage_a.num_blocks()

    @always_inline
    def field_name(self) -> String:
        return self._field_name

    # ---- query-time lookup (the SearchCore surface) ----

    def lookup(self, term_bytes: Span[UInt8, _]) raises -> Optional[Int]:
        """Stage (a): term-bytes -> ordinal, or None. Delegates to
        _stage_a.lookup. The FST-swap black-box surface."""
        return self._stage_a.lookup(term_bytes)

    def term_info_at(self, ordinal: Int) raises -> TermInfo:
        """Stage (b): ordinal -> TermInfo, O(1). Raises on out of range."""
        return self._stage_b.get(ordinal)

    def lookup_info(
        self, term_bytes: Span[UInt8, _]
    ) raises -> Optional[TermInfo]:
        """lookup() then term_info_at(); None if absent (SearchCore ergonomics)."""
        var ord_opt = self.lookup(term_bytes)
        if not ord_opt:
            return None
        return self.term_info_at(ord_opt.value())

    def set_posting_location(
        mut self, ordinal: Int, offset: Int, length: Int
    ) raises:
        """The split writer's patch-pass seam — delegates to the store. doc_freq
        untouched."""
        self._stage_b.set_posting_location(ordinal, offset, length)

    # ---- serialize / deserialize (the self-describing container) ----

    def serialize(self, mut out: List[UInt8]) raises:
        """Append the self-describing term-dict bytes. The split writer calls this
        AFTER it has patched every posting_offset/len via set_posting_location
        (stage-(b) serialize raises if any row is still UNSET).

        Layout:
          magic 'STDICT' (6) + version u8 + flags u8 +
          field_name_len u32 LE + field_name bytes +
          offsets table: stage_a_offset/len, stage_b_offset/len (each u64 LE) +
          stage-a region + stage-b store region.
        The offsets are RELATIVE to the region start (the first magic byte).
        """
        # --- fixed header ---
        for c in "STDICT".as_bytes():
            out.append(c)
        out.append(_STDICT_VERSION)
        out.append(0)  # flags (reserved)
        var fname = self._field_name.as_bytes()
        _append_u32_le(out, UInt32(len(fname)))
        for c in fname:
            out.append(c)

        # --- build the two stage regions into scratch buffers first so we know
        #     their lengths for the offsets table ---
        var stage_a_buf = List[UInt8]()
        self._stage_a.serialize(stage_a_buf)
        var stage_b_buf = List[UInt8]()
        self._stage_b.serialize(stage_b_buf)

        # The offsets table is 4 x u64-LE = 32 bytes. stage_a starts right after
        # the offsets table; stage_b right after stage_a.
        var header_end = len(out) + 32
        var stage_a_offset = header_end
        var stage_a_len = len(stage_a_buf)
        var stage_b_offset = stage_a_offset + stage_a_len
        var stage_b_len = len(stage_b_buf)

        _append_u64_le(out, UInt64(stage_a_offset))
        _append_u64_le(out, UInt64(stage_a_len))
        _append_u64_le(out, UInt64(stage_b_offset))
        _append_u64_le(out, UInt64(stage_b_len))

        # --- the two stages ---
        for i in range(len(stage_a_buf)):
            out.append(stage_a_buf[i])
        for i in range(len(stage_b_buf)):
            out.append(stage_b_buf[i])

    @staticmethod
    def deserialize(var data: List[UInt8]) raises -> TermDictionary:
        """Parse a serialized term-dict region back into a TermDictionary.
        Validates magic + version FIRST (raises loudly on mismatch — never
        silently mis-parses a format change), then the field name + offsets
        table, then the two stages. Owns the bytes it reads from.

        Validation order (the usual header-parse discipline):
        magic -> version -> field name -> offsets table -> stage regions. A
        magic/version mismatch raises before any variable-length read.
        """
        var cur = ByteBuffer(data^)

        # --- magic ---
        if cur.remaining() < _MAGIC_LEN:
            raise Error(
                "TermDictionary.deserialize: too short for magic (corrupt)"
            )
        var expected = "STDICT".as_bytes()
        for i in range(_MAGIC_LEN):
            if cur.read_byte() != expected[i]:
                raise Error(
                    "TermDictionary.deserialize: bad magic (expected 'STDICT')"
                )

        # --- version ---
        var version = cur.read_byte()
        if version != _STDICT_VERSION:
            raise Error(
                "TermDictionary.deserialize: unsupported version "
                + String(Int(version))
                + " (expected "
                + String(Int(_STDICT_VERSION))
                + ")"
            )
        _ = cur.read_byte()  # flags (reserved, ignored)

        # --- field name ---
        var fname_len = Int(cur.read_u32_le())
        if fname_len < 0 or fname_len > cur.remaining():
            raise Error(
                "TermDictionary.deserialize: field_name_len "
                + String(fname_len)
                + " out of bounds (corrupt)"
            )
        var fname_bytes = List[UInt8]()
        cur.read_into_list(fname_bytes, fname_len)
        # SAFETY: the field name was written from a String by the serializer; its
        # length was bounds-checked above.
        var field_name = String(
            StringSlice(unsafe_from_utf8=Span(fname_bytes))
        )

        # --- offsets table (4 x u64-LE) ---
        var stage_a_offset = Int(cur.read_u64_le())
        var stage_a_len = Int(cur.read_u64_le())
        var stage_b_offset = Int(cur.read_u64_le())
        var stage_b_len = Int(cur.read_u64_le())
        # B2: validate offsets/lengths are non-negative and in-range. Each
        # bound is len > total - offset, never offset + len > total: the u64
        # fields can sum past Int max and wrap.
        var total = cur.length()
        if (
            stage_a_offset < 0
            or stage_a_len < 0
            or stage_a_len > total - stage_a_offset
            or stage_b_offset < 0
            or stage_b_len < 0
            or stage_b_len > total - stage_b_offset
        ):
            raise Error(
                "TermDictionary.deserialize: stage offsets/lengths out of"
                " bounds (corrupt)"
            )

        # --- stage (a): seek to its region and reconstruct ---
        cur.set_position(stage_a_offset)
        var stage_a = SortedBlockTermMap.deserialize(cur)

        # --- stage (b): seek to its region (independently locatable — the
        #     FST-swap invariant) and reconstruct from num_terms rows ---
        cur.set_position(stage_b_offset)
        var num_terms = stage_b_len // _STORE_ROW_BYTES
        var stage_b = TermInfoStore.deserialize(cur, num_terms)

        return TermDictionary(
            stage_a=stage_a^,
            stage_b=stage_b^,
            field_name=field_name^,
        )


# =============================================================================
# TermDictBuilder: the build surface.
# =============================================================================


struct TermDictBuilder(Movable, Deinitable):
    """Builds a TermDictionary from the inverted index's FinalizedIndex by a single
    ascending-ordinal walk. The one-shot static method
    `build_from_finalized` is the entry point."""

    @staticmethod
    def build_from_finalized(
        imm fi: FinalizedIndex,
    ) raises -> TermDictionary:
        """The one-shot build. Walks ordinal in [0, fi.num_terms()), appending
        each term to the current front-coded block (opening a new block every
        BLOCK_TERMS terms + recording the sparse-index first-term on block
        open) and appending a store row {POSTING_LOC_UNSET, POSTING_LOC_UNSET,
        df}. Then finalizes the block/offset/count arenas into a
        SortedBlockTermMap and the store columns into a TermInfoStore.

        NO re-sort: the FinalizedIndex ordinal IS the lexicographic position
        (inverted.mojo finalize assigns ordinal == lex order), so terms arrive
        in the exact order front-coding needs. B6: because the upstream order
        is STRICT lexicographic over distinct terms, the per-block first terms
        are strictly ascending (the lookup binary-search precondition).

        `read fi` borrows — the caller retains the FinalizedIndex and may keep
        draining it for the split writer's postings.
        """
        var n = fi.num_terms()

        # --- stage (a) arenas ---
        var block_bytes = List[UInt8]()
        var block_offset = List[Int]()
        var block_count = List[Int]()
        var first_bytes = List[UInt8]()
        var first_offset = List[Int]()
        first_offset.append(0)

        # --- stage (b) store columns ---
        var posting_offset = List[Int](capacity=n)
        var posting_len = List[Int](capacity=n)
        var doc_freq = List[Int](capacity=n)

        # The previous term IN THE CURRENT BLOCK (for LCP), reset per block.
        var prev_term = List[UInt8]()
        var num_blocks = 0
        var cur_block_count = 0

        for ordinal in range(n):
            var term = fi.term_bytes_at(ordinal)  # borrowed, lex-sorted
            var df = fi.doc_freq_at(ordinal)

            if ordinal % BLOCK_TERMS == 0:
                # --- open a new block ---
                # Close out the previous block's count (if any).
                if num_blocks > 0:
                    block_count.append(cur_block_count)
                block_offset.append(len(block_bytes))
                num_blocks += 1
                cur_block_count = 0

                # Store the FULL first term in the block stream (len-prefixed).
                write_uleb128(len(term), block_bytes)
                for i in range(len(term)):
                    block_bytes.append(term[i])

                # And in the sparse-index first-term arena.
                for i in range(len(term)):
                    first_bytes.append(term[i])
                first_offset.append(len(first_bytes))

                # Reset prev_term to this full term.
                prev_term = List[UInt8]()
                for i in range(len(term)):
                    prev_term.append(term[i])
            else:
                # --- front-code against prev_term ---
                var lcp = _shared_prefix_len(prev_term, term)
                var suffix_len = len(term) - lcp
                write_uleb128(lcp, block_bytes)
                write_uleb128(suffix_len, block_bytes)
                for i in range(lcp, len(term)):
                    block_bytes.append(term[i])
                # prev_term = term (for the next LCP).
                prev_term = List[UInt8]()
                for i in range(len(term)):
                    prev_term.append(term[i])

            cur_block_count += 1

            # --- store row ---
            posting_offset.append(POSTING_LOC_UNSET)
            posting_len.append(POSTING_LOC_UNSET)
            doc_freq.append(df)

        # Close the final block's count + push the terminal block_offset entry.
        if num_blocks > 0:
            block_count.append(cur_block_count)
        block_offset.append(len(block_bytes))

        # B4: empty index canonical form falls out naturally —
        #   num_blocks=0, block_offset=[0] (single terminal entry), and the
        #   block_count / first-term arenas are empty.

        var stage_a = SortedBlockTermMap(
            block_bytes=block_bytes^,
            block_offset=block_offset^,
            block_count=block_count^,
            first_bytes=first_bytes^,
            first_offset=first_offset^,
            num_blocks=num_blocks,
            num_terms=n,
        )
        var stage_b = TermInfoStore(
            posting_offset=posting_offset^,
            posting_len=posting_len^,
            doc_freq=doc_freq^,
            num_terms=n,
        )
        return TermDictionary(
            stage_a=stage_a^,
            stage_b=stage_b^,
            field_name=fi.field_name(),
        )


# =============================================================================
# Private byte helpers.
# =============================================================================


@always_inline
def _shared_prefix_len(a: List[UInt8], b: Span[UInt8, _]) -> Int:
    """LCP (longest common prefix) byte length of `a` and `b`."""
    var la = len(a)
    var lb = len(b)
    var m = la if la < lb else lb
    var i = 0
    while i < m and a[i] == b[i]:
        i += 1
    return i


@always_inline
def _append_u32_le(mut out: List[UInt8], v: UInt32):
    """Append `v` as 4 little-endian bytes."""
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 24) & 0xFF))


@always_inline
def _append_u64_le(mut out: List[UInt8], v: UInt64):
    """Append `v` as 8 little-endian bytes."""
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 32) & 0xFF))
    out.append(UInt8((v >> 40) & 0xFF))
    out.append(UInt8((v >> 48) & 0xFF))
    out.append(UInt8((v >> 56) & 0xFF))
