# =============================================================================
# komira_search/inverted.mojo
#   The IN-MEMORY inverted index for ONE text field.
# =============================================================================
#
# Upstream contract: komira_search/analyzer.mojo.
#
# It consumes (doc_id, AnalyzedField) and accumulates a term -> ascending
# doc-ids + parallel per-doc term-frequencies index. The finalize() read
# surface is what the term dictionary and the split writer drain.
#
# -----------------------------------------------------------------------------
# WHAT IT DOES
# -----------------------------------------------------------------------------
#   * InvertedIndexBuilder.add_document(doc_id, af) — accumulate one analyzed
#     document's text field. Reduces the token MULTISET to per-distinct-term TF,
#     then appends one (doc_id, tf) posting per (term, doc) into a FLAT shared
#     arena via a per-term O(1) forward-linked chain.
#   * InvertedIndexBuilder.add_text_column(col, base_doc_id, config) — the
#     column-at-a-time Arrow driver (closes the IndexCore loop).
#   * InvertedIndexBuilder.finalize() -> FinalizedIndex — compact each term's
#     posting chain into a CONTIGUOUS ascending slice, assign lexicographic
#     term ORDINALs, freeze.
#   * FinalizedIndex — ordinal-indexed random-access drain: term_bytes_at,
#     doc_freq_at, posting_doc_ids_at, posting_tfs_at (borrowed Spans, no copy).
#
# -----------------------------------------------------------------------------
# THE TERM DIRECTORY (salt/sentinel collision)
# -----------------------------------------------------------------------------
# Salt-packed open-addressing directory, the same scheme as the engine's
# distinct-aggregation `_DistinctDirectory`. The load-bearing detail:
#   * sentinel EMPTY = 0 (UInt64).
#   * salt_of(h) = (h >> 48) | (UInt64(1) << 15)  — the `| (1<<15)` FORCES the
#     salt nonzero, so term_id 0 with an all-zero-top-16-bit hash never aliases
#     EMPTY.
#   * odd probe stride = ((salt & mask) | 1)  — coprime with power-of-2 cap.
#   * packed word = (salt << 48) | UInt64(term_id).
#   * idx mask = (UInt64(1) << 48) - 1.
# Hash collisions tiebreak by comparing interned term bytes (a salt match is NOT
# a term match).
#
# -----------------------------------------------------------------------------
# THE DRAIN SURFACE (Slab has no safe Span accessor)
# -----------------------------------------------------------------------------
# Slab[T] exposes NO safe tight-origin Span accessor (only the forbidden
# _wild_ptr / get_mut_interior -> MutExternalOrigin, and the forbidden raw
# _unsafe_ptr). So FinalizedIndex stores its COMPACTED arenas as List[Int] /
# List[UInt8] (NOT Slab) and returns borrowed Spans the established way:
# `Span[Int, origin_of(self._doc_ids_final)]` — the same constraint as
# Slab.get returning `ref [self._bytes] T` (origin tied to the INNER field, not
# bare self) — the same idiom as a string arena's get_span ->
# `Span[UInt8, origin_of(self.bytes)]`. The BUILDER keeps Slab + the
# forward-linked chain for the O(1) streaming append; finalize() compacts the
# chains INTO the List arenas.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner re-audit below)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature.
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * Every owning field is a Slab[POD] (TermEntry / Int / UInt8), a
#     List[POD] (UInt64 / Int), or a top-level String (the field name). NO
#     Slab[String] / Slab[Slab] / Slab[List], NO heap-owning slab element, NO
#     wildcard-origin owning field. TermEntry is a PURE POD (all scalar fields).
#     The interned term bytes live FLAT in a Slab[UInt8] arena, addressed by
#     (off, len) — NOT as String slab elements.
#   * InvertedIndexBuilder is MOVE-ONLY (Slab is Movable, NOT Copyable).
# =============================================================================

from komira_core.collections.slab import Slab
from komira_core.collections.string_column_view import StringColumnView

from komira_eval import fnv1a_64_over_bytes

from .analyzer import (
    AnalyzedField,
    AnalyzerConfig,
    Token,
    analyze_text_column,
    analyze_text_column_resolved,
    resolve_stopwords_for,
)


# =============================================================================
# Term-directory constants (the same scheme as the engine's
#      _DistinctDirectory / _DenseAggDirectory).
# =============================================================================

comptime _DIR_EMPTY_SLOT: UInt64 = 0
"""Empty-slot sentinel: salt==0 AND term_id==0. A real term_id of 0 carries a
nonzero salt (forced by `| (1 << 15)` in `_salt_of`), so it is distinguishable
from EMPTY. This is the load-bearing part."""

comptime _DIR_SALT_SHIFT: Int = 48
"""term_id occupies bits [47:0]; salt occupies bits [63:48]."""

comptime _DIR_IDX_MASK: UInt64 = (UInt64(1) << 48) - 1
"""Low-48-bit mask to extract the stored term_id from a packed word."""

comptime _DIR_INITIAL_CAP: Int = 64
"""Initial directory slot count (power-of-2). create() default."""


@always_inline
def _salt_of(h: UInt64) -> UInt64:
    """High-16-bit salt, forced nonzero so it never collides with the empty
    sentinel. VERBATIM mirror of the engine's `_distinct_salt_of`.
    The `| (UInt64(1) << 15)` is what makes term_id 0 with an all-zero-top-16-bit
    hash safe (its packed word is `(salt << 48) | 0` with salt != 0, != EMPTY).
    """
    var s = h >> UInt64(_DIR_SALT_SHIFT)
    return s | (UInt64(1) << 15)


@always_inline
def _salt_stride(salt: UInt64, mask: UInt64) -> UInt64:
    """Odd probe stride derived from the salt. Odd is coprime with the
    power-of-2 capacity, so the probe visits every slot before repeating.
    VERBATIM mirror of the engine's `_distinct_salt_stride`."""
    return (salt & mask) | 1


# =============================================================================
# TermEntry: the POD index element (ONE struct).
# =============================================================================


@fieldwise_init
struct TermEntry(Copyable, Movable, Deinitable):
    """The per-term build-phase index record. A PURE POD — every field is a
    trivially copyable scalar. NO heap-owning field (no String, no List, no
    OwnedPointer). This is what makes `Slab[TermEntry]` safe: the slab
    element owns no heap allocation, so there is no inner pointer for a
    destroy-recreate byte-reuse cycle to reinterpret.

    The term STRING bytes are NOT stored here; they live FLAT in the
    `_term_bytes: Slab[UInt8]` arena, addressed by (term_str_off, term_str_len).
    The postings live in the shared `_doc_ids` / `_tfs` arenas, walked via the
    `head_idx`/`tail_idx` forward-linked chain (`_next`).

    Fields (the SINGLE authoritative struct):
      hash:         fnv1a_64(term.as_bytes()) — the directory key + the
                    collision-tiebreak fast-reject.
      term_str_off: byte offset of this term's interned bytes in _term_bytes.
      term_str_len: length in bytes of this term's interned bytes. LOAD-BEARING
                    for `term_bytes_at`; MUST carry through finalize.
      head_idx:     arena index of this term's FIRST posting (-1 if none).
      tail_idx:     arena index of this term's LAST posting (-1 if none). Lets
                    `_append_posting` link in O(1).
      postings_len: number of (doc_id, tf) entries == doc_freq (one posting per
                    (term, doc) pair, so postings_len IS the doc-freq — derived,
                    never drift-prone).

    `postings_start` is NOT a field here. It is assigned at finalize() into the
    FinalizedIndex's SEPARATE per-ordinal finalized layout — finalize does NOT
    mutate TermEntry in place.
    """

    var hash: UInt64
    var term_str_off: Int
    var term_str_len: Int
    var head_idx: Int
    var tail_idx: Int
    var postings_len: Int


# =============================================================================
# FinalizedIndex: the frozen read surface the term dictionary + split writer drain.
# =============================================================================


struct FinalizedIndex(Movable, Deinitable):
    """The frozen, drainable read surface produced by
    `InvertedIndexBuilder.finalize()`. Owns the COMPACTED posting arenas + the
    interned term bytes + a per-ordinal finalized layout, in ASCENDING
    LEXICOGRAPHIC term order (ordinal == sorted position).

    Storage is List-backed (NOT Slab) precisely so the drain methods can return
    borrowed `Span`s with a tight inner-field origin:
    Slab[T] has no safe tight-origin Span accessor (only the forbidden
    wildcard/raw ones). Every field is POD (List[Int] / List[UInt8] / Int /
    String), so there is no owning pointer field by construction.

    Surface (ordinal-indexed random access — strictly more general than a
    forward iterator; lets the term dictionary + split writer walk in lockstep):
      num_terms / term_count / field_name
      term_bytes_at(ordinal)      -> borrowed Span[UInt8] over interned bytes
      doc_freq_at(ordinal)        -> Int (== postings_len for that term)
      posting_doc_ids_at(ordinal) -> borrowed Span[Int], ASCENDING
      posting_tfs_at(ordinal)     -> borrowed Span[Int], parallel to doc-ids
    """

    # ---- compacted, contiguous posting arenas (ASCENDING per term) ----
    var _doc_ids_final: List[Int]
    var _tfs_final: List[Int]

    # ---- interned term bytes (flat; addressed by per-ordinal off/len) ----
    var _term_bytes_final: List[UInt8]

    # ---- per-ORDINAL finalized layout (parallel; indexed by lex ordinal) ----
    var _postings_start: List[Int]  # start index into _doc_ids_final / _tfs_final
    var _postings_len: List[Int]    # == doc-freq for the term at this ordinal
    var _term_off: List[Int]        # byte offset into _term_bytes_final
    var _term_len: List[Int]        # byte length into _term_bytes_final

    var _field_name: String
    var _num_terms: Int

    def __init__(
        out self,
        var doc_ids_final: List[Int],
        var tfs_final: List[Int],
        var term_bytes_final: List[UInt8],
        var postings_start: List[Int],
        var postings_len: List[Int],
        var term_off: List[Int],
        var term_len: List[Int],
        var field_name: String,
        num_terms: Int,
    ):
        self._doc_ids_final = doc_ids_final^
        self._tfs_final = tfs_final^
        self._term_bytes_final = term_bytes_final^
        self._postings_start = postings_start^
        self._postings_len = postings_len^
        self._term_off = term_off^
        self._term_len = term_len^
        self._field_name = field_name^
        self._num_terms = num_terms

    @always_inline
    def num_terms(self) -> Int:
        """Number of distinct terms in the index."""
        return self._num_terms

    @always_inline
    def term_count(self) -> Int:
        """Alias for num_terms (the term-dict spelling)."""
        return self._num_terms

    @always_inline
    def field_name(self) -> String:
        """The text field this index covers."""
        return self._field_name

    # ---- the term dictionary drains THIS, in ASCENDING ORDINAL order ----

    def term_bytes_at(
        self, ordinal: Int
    ) raises -> Span[UInt8, origin_of(self._term_bytes_final)]:
        """The interned, lexicographically-sorted term bytes for `ordinal`.
        Borrowed view over the owned _term_bytes_final arena (no copy). The
        origin is tied to the INNER field — NOT bare
        __origin_of(self) — so the compiler tracks liveness transitively.

        Raises on ordinal out of range [0, num_terms).
        """
        if ordinal < 0 or ordinal >= self._num_terms:
            raise Error(
                "FinalizedIndex.term_bytes_at: ordinal out of range [0, "
                + String(self._num_terms)
                + ")"
            )
        var off = self._term_off[ordinal]
        var ln = self._term_len[ordinal]
        return Span[UInt8, origin_of(self._term_bytes_final)](
            unsafe_ptr=self._term_bytes_final.unsafe_ptr() + off, length=ln
        )

    def doc_freq_at(self, ordinal: Int) raises -> Int:
        """== postings_len for the term at `ordinal`. One of the three TermInfo
        fields {posting offset, posting len, doc-freq}; the index supplies
        doc-freq, the split writer fills offset/len when it writes posting bytes.

        Raises on ordinal out of range.
        """
        if ordinal < 0 or ordinal >= self._num_terms:
            raise Error(
                "FinalizedIndex.doc_freq_at: ordinal out of range [0, "
                + String(self._num_terms)
                + ")"
            )
        return self._postings_len[ordinal]

    # ---- the split writer drains THIS, per ordinal, to emit posting bytes -

    def posting_doc_ids_at(
        self, ordinal: Int
    ) raises -> Span[Int, origin_of(self._doc_ids_final)]:
        """ASCENDING doc-id slice for the term at `ordinal`. The split writer chunks this by
        128, delta-encodes + bitpacks per block, varints the final partial
        block. Borrowed view (no copy, no UnsafePointer crosses the module
        boundary); origin tied to the inner arena field.

        Raises on ordinal out of range.
        """
        if ordinal < 0 or ordinal >= self._num_terms:
            raise Error(
                "FinalizedIndex.posting_doc_ids_at: ordinal out of range [0, "
                + String(self._num_terms)
                + ")"
            )
        var start = self._postings_start[ordinal]
        var ln = self._postings_len[ordinal]
        return Span[Int, origin_of(self._doc_ids_final)](
            unsafe_ptr=self._doc_ids_final.unsafe_ptr() + start, length=ln
        )

    def posting_tfs_at(
        self, ordinal: Int
    ) raises -> Span[Int, origin_of(self._tfs_final)]:
        """Parallel per-doc TF slice for the term at `ordinal` (same length as
        posting_doc_ids_at). The split writer bitpacks these directly (no delta). Borrowed
        view; origin tied to the inner arena field.

        Raises on ordinal out of range.
        """
        if ordinal < 0 or ordinal >= self._num_terms:
            raise Error(
                "FinalizedIndex.posting_tfs_at: ordinal out of range [0, "
                + String(self._num_terms)
                + ")"
            )
        var start = self._postings_start[ordinal]
        var ln = self._postings_len[ordinal]
        return Span[Int, origin_of(self._tfs_final)](
            unsafe_ptr=self._tfs_final.unsafe_ptr() + start, length=ln
        )


# =============================================================================
# InvertedIndexBuilder: the streaming, single-field, in-memory builder.
# =============================================================================


struct InvertedIndexBuilder(Movable, Deinitable):
    """In-memory inverted index for ONE text field. Term -> ascending doc-ids +
    parallel per-doc term-frequencies. Build-only; the finalize() read surface
    is what the term dictionary and the split writer consume.

    MOVE-ONLY: `Slab[T]` is Movable + Sized, NOT
    Copyable, so this struct is Movable + Deinitable. Thread it via
    `builder^`; there is no copy path.

    Every owning field is a Slab[POD] (TermEntry / Int / UInt8) or a
    List[UInt64] (the directory, POD) or a single top-level String (the field
    name). NO field holds a heap-owning slab element, a wildcard origin, or a
    raw caller pointer.

    NOT thread-safe: the indexer drives add_document single-threaded per
    field-builder (one builder per text field). Parallelism, if added later, is
    per-field-builder fan-out, not intra-builder.
    """

    # ---- term directory (salt-packed open addressing, keyed on FNV hash) ----
    # SAFETY: List[UInt64] is POD; the directory packs (salt | term_id) per
    # slot. Sentinel = _DIR_EMPTY_SLOT. The dense term_id is stable across grow
    # (rehash the directory only; never move the dense arenas). Mirrors
    # the engine's _DistinctDirectory.
    var _dir: List[UInt64]
    var _dir_cap: Int  # power-of-2 capacity
    var _n_terms: Int  # number of distinct terms == _terms.len()

    # ---- the dense, stable-index term index (one TermEntry per term) ----
    var _terms: Slab[TermEntry]

    # ---- interned term bytes (flat arena) ----
    var _term_bytes: Slab[UInt8]

    # ---- the posting arenas (flat, shared across ALL terms) ----
    # During the streaming build a term's postings are NOT contiguous; they form
    # a singly-linked chain over these flat arenas (head_idx/tail_idx in
    # TermEntry, links in _next). finalize() walks each chain into a contiguous
    # ascending slice. NO Slab[Slab[Int]] (a nested slab owns heap per element).
    var _doc_ids: Slab[Int]  # per-(term,doc) doc-id
    var _tfs: Slab[Int]      # parallel per-(term,doc) tf
    var _next: Slab[Int]     # _next[i] = arena idx of NEXT posting in chain, -1=end

    var _field_name: String
    var _last_doc_id: Int   # monotonicity floor
    var _have_doc: Bool     # has any document been added (gates the floor)
    var _finalized: Bool

    # ---- per-doc TF reduce scratch (PERF: reused across docs, NOT re-alloc'd) -
    # `_doc_tf_by_term[term_id]` holds the running term-frequency for the term
    # within the document currently being added (0 between docs). `_doc_touched`
    # lists the term_ids first-seen in THIS doc, in first-occurrence order — that
    # order is the posting-append order, identical to parallel
    # (doc_term_ids, doc_tfs) lists, so output is byte-identical. After a doc the
    # touched entries are reset to 0 (O(distinct), not O(n_terms)). Both are
    # POD List[Int] (no heap-owning element, no byte-slab element).
    var _doc_tf_by_term: List[Int]
    var _doc_touched: List[Int]

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(
        out self,
        var dir: List[UInt64],
        dir_cap: Int,
        var terms: Slab[TermEntry],
        var term_bytes: Slab[UInt8],
        var doc_ids: Slab[Int],
        var tfs: Slab[Int],
        var next: Slab[Int],
        var field_name: String,
    ):
        self._dir = dir^
        self._dir_cap = dir_cap
        self._n_terms = 0
        self._terms = terms^
        self._term_bytes = term_bytes^
        self._doc_ids = doc_ids^
        self._tfs = tfs^
        self._next = next^
        self._field_name = field_name^
        self._last_doc_id = 0
        self._have_doc = False
        self._finalized = False
        self._doc_tf_by_term = List[Int]()
        self._doc_touched = List[Int]()

    @staticmethod
    def create(field_name: String) raises -> InvertedIndexBuilder:
        """Empty builder for one text field. Directory pre-sized to
        _DIR_INITIAL_CAP (64) slots."""
        return InvertedIndexBuilder._with_dir_cap(field_name, _DIR_INITIAL_CAP)

    @staticmethod
    def create_with_capacity(
        field_name: String, expected_terms: Int, expected_postings: Int
    ) raises -> InvertedIndexBuilder:
        """Pre-reserve the directory + arenas to avoid early growth churn.
        Optional perf path; create() is the default.

        `expected_terms` sizes the directory (rounded up to a power-of-2 with
        ~0.67 load headroom) + the term/byte arenas; `expected_postings` sizes
        the posting arenas. Both are hints — the builder grows past them.
        """
        # Directory cap: round up to power-of-2 covering expected_terms at
        # ~0.67 load (terms * 3 / 2), min _DIR_INITIAL_CAP.
        var want = (expected_terms * 3) // 2
        var cap = _DIR_INITIAL_CAP
        while cap < want:
            cap = cap * 2
        var b = InvertedIndexBuilder._with_dir_cap(field_name, cap)
        if expected_terms > 0:
            b._terms.reserve(expected_terms)
            # ~8 bytes/term is a rough intern-arena hint.
            b._term_bytes.reserve(expected_terms * 8)
        if expected_postings > 0:
            b._doc_ids.reserve(expected_postings)
            b._tfs.reserve(expected_postings)
            b._next.reserve(expected_postings)
        return b^

    @staticmethod
    def _with_dir_cap(
        field_name: String, dir_cap: Int
    ) raises -> InvertedIndexBuilder:
        """Build an empty builder with a sentinel-filled directory of `dir_cap`
        slots (caller guarantees dir_cap is a power-of-2 >= 1)."""
        var dir = List[UInt64](capacity=dir_cap)
        for _ in range(dir_cap):
            dir.append(_DIR_EMPTY_SLOT)
        return InvertedIndexBuilder(
            dir=dir^,
            dir_cap=dir_cap,
            terms=Slab[TermEntry](),
            term_bytes=Slab[UInt8](),
            doc_ids=Slab[Int](),
            tfs=Slab[Int](),
            next=Slab[Int](),
            field_name=field_name,
        )

    # -------------------------------------------------------------------------
    # Accessors
    # -------------------------------------------------------------------------

    @always_inline
    def field_name(self) -> String:
        return self._field_name

    @always_inline
    def num_terms(self) -> Int:
        return self._n_terms

    @always_inline
    def is_finalized(self) -> Bool:
        return self._finalized

    # -------------------------------------------------------------------------
    # Directory probe + grow
    # -------------------------------------------------------------------------

    def _term_bytes_equal(
        self, term_id: Int, term_span: Span[UInt8, _]
    ) raises -> Bool:
        """Tiebreak a hash/salt match: compare the interned bytes for `term_id`
        against `term_span`. A salt match is NOT a term match (hash collisions
        must keep distinct terms distinct — test case 9)."""
        ref e = self._terms.get(term_id)
        var ln = e.term_str_len
        if ln != len(term_span):
            return False
        var off = e.term_str_off
        for i in range(ln):
            if self._term_bytes.get(off + i) != term_span[i]:
                return False
        return True

    def _find_term(
        self, h: UInt64, term_span: Span[UInt8, _]
    ) raises -> Int:
        """Probe the directory for an EXISTING term matching (h, term_span).
        Returns the term_id, or -1 if absent. Salt-stride open addressing with
        a full-bytes tiebreak on a salt match."""
        var mask = UInt64(self._dir_cap - 1)
        var salt = _salt_of(h)
        var stride = _salt_stride(salt, mask)
        var slot = (h & mask)
        while True:
            var word = self._dir[Int(slot)]
            if word == _DIR_EMPTY_SLOT:
                return -1
            # Salt fast-reject: only compare bytes when the salt matches.
            if (word >> UInt64(_DIR_SALT_SHIFT)) == salt:
                var cand = Int(word & _DIR_IDX_MASK)
                if self._term_bytes_equal(cand, term_span):
                    return cand
            slot = (slot + stride) & mask

    def _insert_word(mut self, h: UInt64, term_id: Int):
        """Probe from h&mask with the salt-stride; write the packed
        (salt | term_id) word into the first EMPTY slot. Used by insert + grow.
        VERBATIM mirror of `_DistinctDirectory._insert_word`."""
        var mask = UInt64(self._dir_cap - 1)
        var salt = _salt_of(h)
        var stride = _salt_stride(salt, mask)
        var slot = (h & mask)
        var packed = (salt << UInt64(_DIR_SALT_SHIFT)) | UInt64(term_id)
        while True:
            if self._dir[Int(slot)] == _DIR_EMPTY_SLOT:
                self._dir[Int(slot)] = packed
                return
            slot = (slot + stride) & mask

    def _maybe_grow_dir(mut self) raises:
        """Grow BEFORE an insert if at the ~0.67 load threshold, so the new term
        lands in the larger directory. Rehash directory-ONLY off the dense
        TermEntry.hash side data; the dense _terms arena NEVER moves, so every
        term_id stays stable (mirror of _DistinctDirectory._grow)."""
        if self._n_terms < (self._dir_cap * 2) // 3:
            return
        var new_cap = self._dir_cap * 2
        var new_dir = List[UInt64](capacity=new_cap)
        for _ in range(new_cap):
            new_dir.append(_DIR_EMPTY_SLOT)
        self._dir = new_dir^
        self._dir_cap = new_cap
        # Re-probe every existing term from its stored hash.
        for term_id in range(self._n_terms):
            var h = self._terms.get(term_id).hash
            self._insert_word(h, term_id)

    def _intern_term(mut self, term_span: Span[UInt8, _]) raises -> Int:
        """Copy `term_span`'s bytes into the flat _term_bytes arena. Returns the
        byte OFFSET of the interned bytes (the length is `len(term_span)`, known
        at the call site)."""
        var off = self._term_bytes.len()
        for i in range(len(term_span)):
            self._term_bytes.append(term_span[i])
        return off

    def _find_or_insert(
        mut self, h: UInt64, term_span: Span[UInt8, _]
    ) raises -> Int:
        """Find the term_id for (h, term_span), inserting a new dense TermEntry
        (with its bytes interned) if absent. Returns the term_id."""
        var existing = self._find_term(h, term_span)
        if existing >= 0:
            return existing
        # New term: grow the directory if needed (BEFORE the insert), intern the
        # bytes, append the dense TermEntry, write the directory word.
        self._maybe_grow_dir()
        var ln = len(term_span)
        var off = self._intern_term(term_span)
        var term_id = self._n_terms
        self._terms.append(
            TermEntry(
                hash=h,
                term_str_off=off,
                term_str_len=ln,
                head_idx=-1,
                tail_idx=-1,
                postings_len=0,
            )
        )
        self._insert_word(h, term_id)
        self._n_terms += 1
        return term_id

    # -------------------------------------------------------------------------
    # Posting append (Strategy A: per-term forward-linked chain)
    # -------------------------------------------------------------------------

    def _append_posting(
        mut self, term_id: Int, doc_id: Int, tf: Int
    ) raises:
        """Append one (doc_id, tf) posting to `term_id`'s chain in O(1).

        Write at the next free arena index (== _doc_ids.len()), link the term's
        old tail's _next to it (or set head_idx if first), advance tail_idx,
        bump postings_len. Postings arrive in ascending doc_id order by
        construction (add_document enforces the monotonic doc_id floor), so the
        chain is ascending and finalize() needs no sort."""
        var new_idx = self._doc_ids.len()
        self._doc_ids.append(doc_id)
        self._tfs.append(tf)
        self._next.append(-1)

        # Snapshot the term's current head/tail into plain Ints, ending the
        # _terms borrow BEFORE we mutate _next (no two simultaneous live mut
        # borrows of self; no cross-slab ref aliasing).
        var old_head = self._terms.get(term_id).head_idx
        var old_tail = self._terms.get(term_id).tail_idx
        var new_len = self._terms.get(term_id).postings_len + 1

        if old_head < 0:
            # First posting for this term: head == tail == new.
            ref e = self._terms.get(term_id)
            e.head_idx = new_idx
            e.tail_idx = new_idx
            e.postings_len = new_len
        else:
            # Link the old tail's _next to the new posting (separate POD slab;
            # __setitem__ replaces the slot, ending that borrow immediately).
            self._next[old_tail] = new_idx
            # Advance tail + bump postings_len on the TermEntry.
            ref e = self._terms.get(term_id)
            e.tail_idx = new_idx
            e.postings_len = new_len

    # -------------------------------------------------------------------------
    # add_document (the entry point)
    # -------------------------------------------------------------------------

    def add_document(mut self, doc_id: Int, var af: AnalyzedField) raises:
        """Add ONE analyzed document's text field to the index.

        Contract (matches the analyzer's AnalyzedField contract):
          * af.tokens is a TF-countable MULTISET in emission order (NOT deduped).
          * doc_id MUST be >= the last doc_id seen (this
            is a HARD `raise`, NOT a debug_assert — debug_assert is
            release-elided, and a release violation silently yields unsorted
            postings -> garbage delta in the split writer. The "doc_id non-decreasing by
            construction" invariant is what makes delta-encoding sound, so it is
            fail-loud).
          * Token.position is IGNORED (reserved for phrase queries).

        Algorithm:
          1. Reduce the multiset to per-distinct-term TF for THIS doc (a small
             local scratch keyed on term_id, drained per call).
          2. For each (distinct term, per_doc_tf): hash the term bytes, find or
             insert the term, append the posting.

        Raises:
          If the builder is already finalized.
          If doc_id < the last doc_id seen (monotonicity).
        """
        if self._finalized:
            raise Error(
                "InvertedIndexBuilder.add_document: builder is already"
                " finalized; no further documents may be added"
            )
        if self._have_doc and doc_id < self._last_doc_id:
            raise Error(
                "InvertedIndexBuilder.add_document: doc_id "
                + String(doc_id)
                + " < last doc_id "
                + String(self._last_doc_id)
                + " (doc-ids MUST be non-decreasing — the ascending-by-"
                "construction invariant that makes posting delta-encoding sound)"
            )
        self._have_doc = True
        self._last_doc_id = doc_id

        var n = af.len()
        if n == 0:
            return

        # ---- Step 1: reduce the multiset to per-distinct-term TF for THIS doc.
        # PERF-CRITICAL (search index-build per-bulk latency): tally
        # TF in O(1) per token through the term_id-indexed `_doc_tf_by_term`
        # accumulator + first-occurrence-ordered `_doc_touched` list, replacing
        # an O(distinct) linear scan over a per-doc (doc_term_ids, doc_tfs)
        # pair. For a fat doc (~thousands of tokens, ~tens of distinct terms in a
        # repeating-vocabulary corpus) that scan is O(tokens * distinct); this is
        # O(tokens + distinct). The scratch lists are builder fields REUSED across
        # docs (cleared touched-only after each doc — O(distinct)), so the two
        # per-doc `List[Int]()` allocations are also eliminated. Output is
        # byte-identical: `_doc_touched` records first-occurrence order (the same
        # order the old `doc_term_ids` did), so the posting-append order, the
        # per-term TF tallies, and postings_len == doc-freq are all unchanged
        # (regression-guarded by test_search_inverted + the keystone BM25 golden).
        var touched_start = len(self._doc_touched)
        for ti in range(n):
            ref tok = af.tokens[ti]
            var h = fnv1a_64_over_bytes(tok.term.as_bytes())
            var term_id = self._find_or_insert(h, tok.term.as_bytes())
            # Grow the dense accumulator to cover a freshly-inserted term_id
            # (find_or_insert assigns dense ids in [0, _n_terms); a new id == the
            # old _n_terms, so at most one append per new term).
            while len(self._doc_tf_by_term) <= term_id:
                self._doc_tf_by_term.append(0)
            if self._doc_tf_by_term[term_id] == 0:
                # First occurrence of this term in THIS doc: record it (in
                # first-occurrence order) so the posting append order is stable.
                self._doc_touched.append(term_id)
            self._doc_tf_by_term[term_id] += 1

        # ---- Step 2: append exactly one posting per distinct term in this doc,
        # in first-occurrence order. Reset each touched accumulator slot to 0 as
        # we drain it (O(distinct) reset — the accumulator is left all-zero for
        # the next doc), then shrink `_doc_touched` back to its pre-doc length.
        for k in range(touched_start, len(self._doc_touched)):
            var tid = self._doc_touched[k]
            self._append_posting(tid, doc_id, self._doc_tf_by_term[tid])
            self._doc_tf_by_term[tid] = 0
        # Drop this doc's touched entries (keep the capacity for reuse).
        while len(self._doc_touched) > touched_start:
            _ = self._doc_touched.pop()

    # -------------------------------------------------------------------------
    # add_text_column (closes the IndexCore loop)
    # -------------------------------------------------------------------------

    def add_text_column[
        origin: Origin[mut=False]
    ](
        mut self,
        col: StringColumnView[origin],
        base_doc_id: Int,
        config: AnalyzerConfig,
        mut token_counts: List[Int],
    ) raises:
        """Column-at-a-time driver (closes IndexCore.add_documents).
        For row r in [0, col.length()):  (the row count
        accessor is `length()`, NOT len()/__len__)
          af = analyze_text_column(col, r, config)   # the analyzer
          token_counts.append(af.len())              # the fieldnorm
          self.add_document(base_doc_id + r, af^)
        `base_doc_id` is the running doc-id offset across DocBatches (monotonic).
        This keeps the analyzer call INSIDE the search package (no AnalyzedField
        list materialized across the whole column).

        `token_counts` is an OUT-param that receives one
        per-row token count (`AnalyzedField.len()`) BEFORE the move into
        add_document — captured from the SAME single tokenization (no double-
        tokenize). This is the doc-length FIELDNORM the BM25 b>0 path consumes.
        It is PURELY additive (an extra out-param + one append) — the inverted
        index's doc-freqs / TF tallies / posting order do not depend on it
        (regression-guarded in test_search_inverted +
        a doc-freqs-unchanged assertion in test_search_fast_fields).

        Raises:
          If the builder is finalized; from analyze_text_column (non-TEXT field,
          out-of-range row, unknown stopword tag); or on monotonicity.
        """
        # PERF-CRITICAL (search index-build per-bulk latency):
        # resolve the stopword set ONCE per batch (33 String allocs), NOT once
        # per row inside analyze_text_column. resolve_stopwords_for also performs
        # the non-text fail-loud guard once here. Then drive
        # analyze_text_column_resolved per row with the hoisted set. Output is
        # byte-identical to the per-row analyze_text_column path (doc-freqs / TF
        # tallies / posting order unchanged — regression-guarded by
        # test_search_inverted + test_search_fast_fields).
        var stopwords = resolve_stopwords_for(config)
        var n = col.length()
        for r in range(n):
            var af = analyze_text_column_resolved(col, r, config, stopwords)
            token_counts.append(af.len())
            self.add_document(base_doc_id + r, af^)

    # -------------------------------------------------------------------------
    # finalize (compact chains -> contiguous; assign lex ordinals)
    # -------------------------------------------------------------------------

    def finalize(mut self) raises -> FinalizedIndex:
        """Freeze the build into a FinalizedIndex.

        Performs:
          1. Compute the LEXICOGRAPHIC order of the distinct terms by their
             interned bytes -> assign term ORDINAL = sorted position (NOT
             insertion order — the term dictionary's sorted blocks need lex order).
          2. For each term in ascending ORDINAL order: walk its forward-linked
             posting chain into a CONTIGUOUS ascending slice in fresh
             _doc_ids_final / _tfs_final arenas; copy its interned bytes into a
             fresh _term_bytes_final arena; record per-ordinal
             (postings_start, postings_len, term_off, term_len). Chains were
             ascending by construction, so this is a stable copy — no sort.
          3. Mark _finalized = True (add_document after finalize raises).

        Returns the FinalizedIndex value the caller owns (moved out). The
        builder's own arenas are left in a destructor-safe (drained) state.
        """
        var nt = self._n_terms

        # ---- Step 1: lexicographic ordinal permutation (term_id by lex order).
        # order[ordinal] = the build-order term_id at that lexicographic rank.
        var order = List[Int]()
        for t in range(nt):
            order.append(t)
        self._sort_terms_lex(order)

        # ---- Step 2: compact each term's chain into contiguous arenas.
        var doc_ids_final = List[Int]()
        var tfs_final = List[Int]()
        var term_bytes_final = List[UInt8]()
        var postings_start = List[Int]()
        var postings_len = List[Int]()
        var term_off = List[Int]()
        var term_len = List[Int]()

        for ordinal in range(nt):
            var term_id = order[ordinal]
            # Snapshot the entry's scalar fields into plain Ints (TermEntry is a
            # Copyable POD; this ends the _terms borrow before we read the byte /
            # posting slabs below).
            var head = self._terms.get(term_id).head_idx
            var plen = self._terms.get(term_id).postings_len
            var t_off = self._terms.get(term_id).term_str_off
            var t_len = self._terms.get(term_id).term_str_len

            # Term bytes: copy the interned bytes into the final arena.
            var new_term_off = len(term_bytes_final)
            for i in range(t_len):
                term_bytes_final.append(self._term_bytes.get(t_off + i))
            term_off.append(new_term_off)
            term_len.append(t_len)

            # Postings: walk the chain (ascending by construction) into a
            # contiguous slice.
            var start = len(doc_ids_final)
            postings_start.append(start)
            postings_len.append(plen)
            var cur = head
            while cur >= 0:
                doc_ids_final.append(self._doc_ids.get(cur))
                tfs_final.append(self._tfs.get(cur))
                cur = self._next.get(cur)

        self._finalized = True

        return FinalizedIndex(
            doc_ids_final=doc_ids_final^,
            tfs_final=tfs_final^,
            term_bytes_final=term_bytes_final^,
            postings_start=postings_start^,
            postings_len=postings_len^,
            term_off=term_off^,
            term_len=term_len^,
            field_name=self._field_name,
            num_terms=nt,
        )

    # -------------------------------------------------------------------------
    # lexicographic term sort (by interned bytes)
    # -------------------------------------------------------------------------

    def _term_less(self, a_term_id: Int, b_term_id: Int) raises -> Bool:
        """Lexicographic byte-order compare of two terms by their interned
        bytes. Returns True iff term `a_term_id` < term `b_term_id`."""
        # Read the per-term (off, len) WITHOUT a whole-struct copy: TermEntry is
        # Copyable but NOT ImplicitlyCopyable, so bind a ref and read fields.
        var a_off = self._terms.get(a_term_id).term_str_off
        var a_len = self._terms.get(a_term_id).term_str_len
        var b_off = self._terms.get(b_term_id).term_str_off
        var b_len = self._terms.get(b_term_id).term_str_len
        var m = a_len if a_len < b_len else b_len
        for i in range(m):
            var ca = self._term_bytes.get(a_off + i)
            var cb = self._term_bytes.get(b_off + i)
            if ca != cb:
                return ca < cb
        # Common prefix equal -> shorter sorts first.
        return a_len < b_len

    def _sort_terms_lex(self, mut order: List[Int]) raises:
        """In-place insertion sort of `order` (term_ids) into ascending
        lexicographic term order. Insertion sort is fine: the distinct-term set
        per single text field per build batch is modest, and finalize is a
        once-per-build cost (NOT a hot loop). A faster sort can replace it if
        a profile ever shows it matters; the contract is only that ordinal ==
        lexicographic position."""
        var n = len(order)
        for i in range(1, n):
            var key = order[i]
            var j = i - 1
            while j >= 0 and self._term_less(key, order[j]):
                order[j + 1] = order[j]
                j -= 1
            order[j + 1] = key
