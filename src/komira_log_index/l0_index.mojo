# =============================================================================
# komira_log_index.l0_index: the L0 cheap unsorted-posting builder and the L0
# split (a SPLIT_VERSION=1 container with an additive footer slot).
# =============================================================================
#
# This module owns the cheap, searchable-on-land index the drain produces. The
# expensive optimized index (sorted two-stage term dictionary, BM25
# precompute, field-norm average, block-max) is left to a later compaction.
#
# WHAT L0 BUILDS:
#   * the unsorted posting: a term-hash -> doc-ids open-addressing map, built
#     incrementally per document, with one posting per distinct term per
#     document, carrying the per-document term frequency (TF). There is no
#     sorted two-stage dictionary, no delta+bitpack codec, no BM25 precompute,
#     no field-norm average and no block-max.
#   * the `_source` doc store: `komira_search.DocStoreBuilder` is reused
#     verbatim, so the doc-store region is byte-identical to the optimized
#     writer's (a merge re-derives `message` from the `_source`).
#   * the columnar fast fields: `serialize_fastfields_region` is reused verbatim
#     over the same classified columns and the same per-row field-norm token
#     count (captured from the same single analyze pass the posting tokenizes
#     with), so the fast-field region is byte-identical to the optimized
#     writer's and a merge finds every typed field.
#
# THE L0 SPLIT FORMAT (additive footer, not a new front magic): a
# SPLIT_VERSION=1 container with an EMPTY term-dictionary region, an EMPTY
# postings region, a POPULATED doc store, a POPULATED fast-field region and the
# L0 posting blob in the additive `l0_posting` footer slot. `SplitView.parse`
# reads it (it rejects any version other than 1) through the footer's
# graceful-degrade path. What tells an L0 split from an optimized one is the
# presence of the `l0_posting` footer slot (`SplitView.has_l0_posting()`), not a
# front byte, so a read fan-out routes per split.
#
# This module has no UnsafePointer in any signature. All substrate is plain
# `List[UInt8]`, `List[Int]`, `List[UInt64]` and `List[List[Int]]`. The borrowed
# StringColumnView the analyzer reads has a concrete origin.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.batch_view import batch_view_over, BatchView
from komira_buffer.byte_buffer import write_uleb128, write_uleb128_u64

from komira_hash import fnv1a_64

from komira_search.analyzer import (
    AnalyzerConfig,
    analyze_text_column_resolved,
    resolve_stopwords_for,
)
from komira_search.fast_fields import (
    FastFieldSpec,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
    FIELDNORM_NAME,
    _storage_dtype_for_arrow_type_id,
)
from komira_search.sink import _ingest_numeric_column
from komira_search.split import (
    DocStoreBuilder,
    serialize_split,
    FOOTER_NO_TOTAL_TOKENS,
)

from komira_log_index.transpose import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
)


# =============================================================================
# 1. The L0-posting region codec (the only net-new codec; everything else is
#       REUSED). FROZEN byte layout — the L0 read path + a future compaction
#       rebuild decode against it.
# =============================================================================

comptime L0_POSTING_VERSION: UInt8 = 1
"""L0-posting region schema version (the additive `l0_posting` footer slot)."""


# Region layout (an opaque blob to split.mojo; this module owns it):
#
#   header:
#     version    u8        (L0_POSTING_VERSION)
#     num_terms  ULEB128   (distinct terms over the whole segment, dense order)
#     num_docs   ULEB128   (the segment's doc count — for bounds validation)
#
#   TIER 1 — per distinct term (in dense insertion order):
#     term_hash  u64 LE    (fnv1a_64 of the analyzed term)
#     doc_freq   ULEB128   (number of docs that contain this term)
#
#   TIER 2 — per term, two parallel homogeneous ULEB128 runs (SoA):
#     doc_id deltas[]      ULEB128 run (ASCENDING doc-ids by construction, so a
#                                       simple per-term delta is enough — NO
#                                       bitpack at L0; first delta is the absolute
#                                       doc-id, subsequent are gaps)
#     per-doc tf[]         ULEB128 run (the TF of the term in each of those docs)


# -----------------------------------------------------------------------------
# L0PostingBuilder — the incremental per-doc term-hash -> (doc-ids, tfs) map.
# Open-addressing probe table over dense parallel SoA, extended to carry
# per-doc TF. Plain List storage.
# -----------------------------------------------------------------------------


struct L0PostingBuilder(Movable, Deinitable):
    """Build-side: an open-addressing term-hash -> dense-term-index probe table +
    parallel dense `_keys` / `_postings` (doc-ids) / `_tfs` (per-doc TF) SoA.
    Incremental: `add_doc_terms` is called once per doc with that doc's analyzed
    tokens; it dedups distinct terms within the doc, appends the doc-id to each
    distinct term's posting list (ascending by construction — docs are added in
    doc-id order), and records the per-doc TF.

    The doc-ids are ascending because `add_doc_terms` is driven in row order with a
    monotone doc-id, so the per-term posting list is sorted with no extra work."""

    var _table: List[Int]  # open-addressing: dense-term-index + 1 (0 = empty).
    var _mask: Int
    var _keys: List[UInt64]  # dense term hashes (one per distinct term).
    var _postings: List[List[Int]]  # parallel doc-ids lists (ascending).
    var _tfs: List[List[Int]]  # parallel per-doc TF lists.
    var _num_docs: Int
    # per-doc dedup scratch (REUSED across docs; cleared per doc) — the term-hash
    # and a running TF tally, parallel.
    var _seen_hashes: List[UInt64]
    var _seen_tfs: List[Int]

    def __init__(out self, table_pow2: Int = 14):
        var cap = 1
        for _ in range(table_pow2):
            cap = cap * 2
        self._table = List[Int]()
        for _ in range(cap):
            self._table.append(0)
        self._mask = cap - 1
        self._keys = List[UInt64]()
        self._postings = List[List[Int]]()
        self._tfs = List[List[Int]]()
        self._num_docs = 0
        self._seen_hashes = List[UInt64]()
        self._seen_tfs = List[Int]()

    @always_inline
    def num_docs(self) -> Int:
        return self._num_docs

    @always_inline
    def num_terms(self) -> Int:
        return len(self._keys)

    @always_inline
    def _find_or_insert(mut self, h: UInt64) -> Int:
        """Return the dense term index for hash `h`, inserting if absent."""
        var idx = Int(h) & self._mask
        while True:
            var slot1 = self._table[idx]
            if slot1 == 0:
                var dense = len(self._keys)
                self._keys.append(h)
                self._postings.append(List[Int]())
                self._tfs.append(List[Int]())
                self._table[idx] = dense + 1
                return dense
            var dense = slot1 - 1
            if self._keys[dense] == h:
                return dense
            idx = (idx + 1) & self._mask

    def add_doc_terms(mut self, term_hashes: List[UInt64]):
        """Add one document's tokens (already-hashed, in token order, with
        duplicates) to the posting. Dedups distinct terms within the doc, tallies
        per-distinct-term TF, and appends `doc_id` + TF to each distinct term's
        posting/tf lists. `doc_id` is the running `_num_docs` (monotone) — so the
        per-term posting lists stay ASCENDING with no sort.

        The hashing happens at the CALL SITE (so the caller tokenizes ONCE and
        feeds both the posting and the fieldnorm from one analyze pass)."""
        var doc_id = self._num_docs
        self._seen_hashes.clear()
        self._seen_tfs.clear()
        for ti in range(len(term_hashes)):
            var h = term_hashes[ti]
            # dedup within this doc (linear scan — log docs have few distinct).
            var found = -1
            for s in range(len(self._seen_hashes)):
                if self._seen_hashes[s] == h:
                    found = s
                    break
            if found >= 0:
                self._seen_tfs[found] += 1
            else:
                self._seen_hashes.append(h)
                self._seen_tfs.append(1)
        # Commit this doc's distinct terms to the posting (first-occurrence order).
        for s in range(len(self._seen_hashes)):
            var dense = self._find_or_insert(self._seen_hashes[s])
            self._postings[dense].append(doc_id)
            self._tfs[dense].append(self._seen_tfs[s])
        self._num_docs += 1

    def serialize_region(self) raises -> List[UInt8]:
        """Emit the FROZEN L0-posting region bytes (layout above). Returns an EMPTY
        list iff there are no distinct terms (a 0-doc / all-stopword segment) —
        the caller then writes an OPTIMIZED-shaped split (no l0_posting slot)."""
        var num_terms = len(self._keys)
        if num_terms == 0:
            return List[UInt8]()
        var out = List[UInt8]()
        out.append(L0_POSTING_VERSION)
        write_uleb128(num_terms, out)
        write_uleb128(self._num_docs, out)
        # TIER 1: (term_hash u64 LE, doc_freq ULEB128) per term, dense order.
        for d in range(num_terms):
            var h = self._keys[d]
            for b in range(8):
                out.append(UInt8((h >> UInt64(8 * b)) & UInt64(0xFF)))
            write_uleb128(len(self._postings[d]), out)
        # TIER 2a: per-term ascending doc-id deltas (first = absolute id).
        for d in range(num_terms):
            ref pl = self._postings[d]
            var prev = 0
            for i in range(len(pl)):
                var docid = pl[i]
                if docid < prev:
                    raise Error(
                        "L0PostingBuilder.serialize_region: doc-ids not"
                        " ascending (term " + String(d) + ")"
                    )
                var delta = docid - prev if i > 0 else docid
                # `docid >= prev` (checked above, with prev starting at 0), so
                # `delta` is never negative: the unsigned writer needs no
                # second sign test per posting.
                write_uleb128_u64(UInt64(delta), out)
                prev = docid
        # TIER 2b: per-term per-doc TF runs (parallel to the doc-id runs).
        for d in range(num_terms):
            ref tl = self._tfs[d]
            for i in range(len(tl)):
                write_uleb128(tl[i], out)
        return out^


# =============================================================================
# 2. The L0-posting READ side: deserialize the region + an O(1) term-hash probe
#       returning (doc-ids, tfs). This is what the per-split L0 read route
#       drives; here it is the in-package correctness surface (the test oracle
#       checks the round-tripped query against an independent brute force).
# =============================================================================


def _read_uleb128(region: Span[UInt8, _], mut off: Int, end: Int) raises -> Int:
    """Read one ULEB128 from `region[off..end)`, advancing `off`. Fail-loud on
    truncation or a > 10-byte encoding (the split is untrusted input). The
    result is an `Int`, so a value of 2^63 or more comes back negative; every
    caller must reject a negative result."""
    var result = UInt64(0)
    var shift = UInt64(0)
    var nbytes = 0
    while True:
        if off >= end:
            raise Error("L0 posting: ULEB128 truncated")
        if nbytes >= 10:
            raise Error("L0 posting: ULEB128 too long")
        var b = region[off]
        off += 1
        nbytes += 1
        result |= (UInt64(b) & UInt64(0x7F)) << shift
        if (UInt64(b) & UInt64(0x80)) == UInt64(0):
            break
        shift += UInt64(7)
    return Int(result)


struct L0PostingIndex(Movable, Deinitable):
    """The parsed L0-posting region: an open-addressing term-hash -> dense-index
    probe table + the per-term (doc-ids, tfs). Built ONCE at read time from the
    `l0_posting` region bytes. POD List substrate. Query: hash the
    analyzed term, probe -> (ascending doc-ids, per-doc TF)."""

    var _table: List[Int]  # open-addressing: dense-index + 1 (0 = empty).
    var _mask: Int
    var _keys: List[UInt64]
    var _postings: List[List[Int]]
    var _tfs: List[List[Int]]
    var _num_docs: Int

    def __init__(
        out self,
        var keys: List[UInt64],
        var postings: List[List[Int]],
        var tfs: List[List[Int]],
        num_docs: Int,
    ):
        self._keys = keys^
        self._postings = postings^
        self._tfs = tfs^
        self._num_docs = num_docs
        # Build a power-of-two probe table sized > num_terms (load < 0.5).
        var nt = len(self._keys)
        var cap = 1
        while cap < (nt * 2 + 1):
            cap = cap * 2
        self._table = List[Int]()
        for _ in range(cap):
            self._table.append(0)
        self._mask = cap - 1
        for d in range(nt):
            var idx = Int(self._keys[d]) & self._mask
            while self._table[idx] != 0:
                idx = (idx + 1) & self._mask
            self._table[idx] = d + 1

    @staticmethod
    def deserialize(region: Span[UInt8, _]) raises -> L0PostingIndex:
        """Parse the FROZEN L0-posting region. Every bound is checked and raises."""
        var n = len(region)
        if n < 1:
            raise Error("L0PostingIndex.deserialize: empty region")
        var off = 0
        var ver = Int(region[off])
        off += 1
        if ver != Int(L0_POSTING_VERSION):
            raise Error(
                "L0PostingIndex.deserialize: unsupported version " + String(ver)
            )
        var num_terms = _read_uleb128(region, off, n)
        var num_docs = _read_uleb128(region, off, n)
        if num_terms < 0 or num_docs < 0:
            raise Error("L0PostingIndex.deserialize: negative count")
        # TIER 1: (term_hash u64 LE, doc_freq) per term.
        var keys = List[UInt64]()
        var doc_freqs = List[Int]()
        for _ in range(num_terms):
            if off + 8 > n:
                raise Error("L0PostingIndex.deserialize: truncated term_hash")
            var h = UInt64(0)
            for b in range(8):
                h |= UInt64(region[off + b]) << UInt64(8 * b)
            off += 8
            keys.append(h)
            var df = _read_uleb128(region, off, n)
            if df < 0:
                raise Error("L0PostingIndex.deserialize: negative doc_freq")
            doc_freqs.append(df)
        # TIER 2a: per-term ascending doc-id deltas -> absolute ids.
        var postings = List[List[Int]]()
        for d in range(num_terms):
            var pl = List[Int]()
            var prev = 0
            for i in range(doc_freqs[d]):
                var delta = _read_uleb128(region, off, n)
                if i > 0 and delta < 1:
                    raise Error(
                        "L0PostingIndex.deserialize: doc-ids not strictly"
                        " ascending"
                    )
                var docid = delta if i == 0 else prev + delta
                if docid < 0 or docid >= num_docs:
                    raise Error(
                        "L0PostingIndex.deserialize: doc-id out of range"
                    )
                pl.append(docid)
                prev = docid
            postings.append(pl^)
        # TIER 2b: per-term per-doc TF runs.
        var tfs = List[List[Int]]()
        for d in range(num_terms):
            var tl = List[Int]()
            for _ in range(doc_freqs[d]):
                var tf = _read_uleb128(region, off, n)
                if tf < 1:
                    raise Error("L0PostingIndex.deserialize: tf below 1")
                tl.append(tf)
            tfs.append(tl^)
        return L0PostingIndex(keys^, postings^, tfs^, num_docs)

    @always_inline
    def num_docs(self) -> Int:
        return self._num_docs

    @always_inline
    def num_terms(self) -> Int:
        return len(self._keys)

    def _probe(self, h: UInt64) -> Int:
        """Return the dense term index for hash `h`, or -1 if absent."""
        var idx = Int(h) & self._mask
        while True:
            var slot1 = self._table[idx]
            if slot1 == 0:
                return -1
            var dense = slot1 - 1
            if self._keys[dense] == h:
                return dense
            idx = (idx + 1) & self._mask

    def doc_ids_for_hash(self, h: UInt64) -> List[Int]:
        """The ascending doc-ids posting list for term-hash `h` (empty if
        absent). The doc-ids are slot indices into the _source doc-store."""
        var dense = self._probe(h)
        if dense < 0:
            return List[Int]()
        var out = List[Int]()
        ref pl = self._postings[dense]
        for i in range(len(pl)):
            out.append(pl[i])
        return out^

    def tfs_for_hash(self, h: UInt64) -> List[Int]:
        """The per-doc TF list (parallel to doc_ids_for_hash) for term-hash `h`."""
        var dense = self._probe(h)
        if dense < 0:
            return List[Int]()
        var out = List[Int]()
        ref tl = self._tfs[dense]
        for i in range(len(tl)):
            out.append(tl[i])
        return out^

    def query_term(
        self, term: String, config: AnalyzerConfig
    ) raises -> List[Int]:
        """Analyze the single query `term`, hash the FIRST analyzed token, probe
        -> the ascending matching doc-ids (exact, complete). Empty if the term
        analyzes to nothing or is absent. This is the searchable-on-land L0
        query path (membership; TF-rank rides tfs_for_hash)."""
        var stopwords = resolve_stopwords_for(config)
        # The analyzer's column path is the index-side tokenizer; for a free query
        # string we tokenize via a 1-cell column would be heavier — instead hash
        # the single term the SAME way the build did (fnv1a over the analyzed
        # token bytes). The build tokenized via analyze_text_column_resolved over
        # the message column; a query term is a single token, so we tokenize it
        # through the same _analyze pathway by reusing the analyzer over a 1-row
        # column is unnecessary: the build's per-token hash is fnv1a_64 over the
        # analyzed term bytes. We reproduce ONE analyzed token here.
        var tokens = _analyze_query_tokens(term, config, stopwords)
        if len(tokens) == 0:
            return List[Int]()
        var h = fnv1a_64(tokens[0].as_bytes())
        return self.doc_ids_for_hash(h)


# -----------------------------------------------------------------------------
# _analyze_query_tokens — tokenize a free query string into analyzed term Strings
# via the SAME analyzer the build uses (so a query term's bytes hash identically
# to the indexed term's bytes). Reuses analyze_text_column_resolved over a 1-cell
# column so the tokenizer/stopword/casefold path is byte-identical to the build.
# -----------------------------------------------------------------------------


def _analyze_query_tokens(
    term: String, config: AnalyzerConfig, stopwords: List[String]
) raises -> List[String]:
    from komira_arrow.column import Column
    from komira_arrow.record_batch import RecordBatchBuilder
    from komira_arrow.schema import Field, SchemaBuilder
    from komira_arrow.string_array import StringArray

    var sb = SchemaBuilder()
    sb.add_field(Field(LOG_INDEX_TEXT_FIELD, ArrowType.STRING, False))
    var schema = sb.build()
    var cells = List[String]()
    cells.append(term)
    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_string(StringArray.from_strings(cells)))
    var batch = rb.build(schema^)
    var bv = batch_view_over(batch)
    var col = bv.col_str(0)
    var af = analyze_text_column_resolved(col, 0, config, stopwords)
    var out = List[String]()
    for ti in range(af.len()):
        out.append(af.tokens[ti].term)
    return out^


# =============================================================================
# 3. The L0 SEGMENT builder: ingest typed RecordBatches into the cheap posting
#       + the REUSED docstore + the REUSED THFF, then serialize the L0 split
#       (SPLIT_VERSION=1 additive-footer container).
# =============================================================================


def _classify_l0_specs(schema: Schema) raises -> List[FastFieldSpec]:
    """Classify every column EXCEPT the text field + the _source field into a
    FastFieldSpec, USING THE EXACT SAME classification ladder SearchSink.init_sink
    uses (dispatch on the storage DType, not Field.dtype). This guarantees
    the L0 THFF region is built over the SAME column set as the optimized writer
    -> byte-identical THFF. A column literally named '__fieldnorm__' is REJECTED
    (the reserved-name guard, mirrored from the sink)."""
    var n = schema.num_columns()
    var ti = -1
    var si = -1
    for c in range(n):
        var name = schema.field_name(c)
        if name == LOG_INDEX_TEXT_FIELD:
            ti = c
        if name == LOG_INDEX_SOURCE_FIELD:
            si = c
    if ti < 0:
        raise Error(
            "L0 segment: text field '" + LOG_INDEX_TEXT_FIELD
            + "' not found in schema"
        )
    if si < 0:
        raise Error(
            "L0 segment: _source field '" + LOG_INDEX_SOURCE_FIELD
            + "' not found in schema"
        )
    var specs = List[FastFieldSpec]()
    for c in range(n):
        if c == ti or c == si:
            continue
        var f = schema.field_at(c)
        if f.name == FIELDNORM_NAME:
            raise Error(
                "L0 segment: '" + FIELDNORM_NAME + "' is a reserved name"
            )
        var atid = f.arrow_type.type_id
        var storage = _storage_dtype_for_arrow_type_id(atid)
        var readable = (
            storage == DType.int32
            or storage == DType.int64
            or storage == DType.float32
            or storage == DType.float64
        )
        if f.arrow_type.is_temporal():
            if storage == DType.int32 or storage == DType.int64:
                specs.append(
                    FastFieldSpec(f.name, c, FIELD_CLASS_DATE, atid, storage)
                )
        elif f.arrow_type.is_numeric():
            if readable:
                specs.append(
                    FastFieldSpec(f.name, c, FIELD_CLASS_NUMERIC, atid, storage)
                )
        elif f.arrow_type == ArrowType.STRING:
            # `storage` is the not-a-fast-field sentinel here: STRING is not in
            # `_storage_dtype_for_arrow_type_id`'s ladder, and `storage_dtype`
            # is unused for FIELD_CLASS_KEYWORD. Passing `storage` through
            # leaves the sentinel itself to komira_search, which owns it.
            specs.append(
                FastFieldSpec(
                    f.name, c, FIELD_CLASS_KEYWORD, atid, storage
                )
            )
    return specs^


struct L0SegmentBuilder(Movable, Deinitable):
    """Builds ONE L0 cheap-posting split segment from the typed log-index
    RecordBatches (the transpose output). It runs the SAME column ingest the
    optimized writer runs for the docstore + THFF + fieldnorm — but does the CHEAP
    L0 posting INSTEAD of the heavy inverted index. MOVE-ONLY (owns POD builders).

    Lifecycle:
      var b = L0SegmentBuilder(schema, text_field, source_field)
      for batch in batches: b.add_batch(batch^)
      var split = b.serialize_split_bytes(field_name, split_uuid)
    """

    var _schema: Schema
    var _text_col_idx: Int
    var _source_col_idx: Int
    var _analyzer: AnalyzerConfig
    var _posting: L0PostingBuilder
    var _docstore: DocStoreBuilder
    var _specs: List[FastFieldSpec]
    var _num_builders: List[NumericFastFieldBuilder]
    var _kw_builders: List[KeywordFastFieldBuilder]
    var _fieldnorm: NumericFastFieldBuilder
    var _num_docs: Int

    def __init__(out self, var schema: Schema) raises:
        """Resolve the text + _source column indices and classify the fast-field
        columns (the SAME ladder as SearchSink.init_sink — byte-identical THFF)."""
        var n = schema.num_columns()
        var ti = -1
        var si = -1
        for c in range(n):
            var name = schema.field_name(c)
            if name == LOG_INDEX_TEXT_FIELD:
                ti = c
            if name == LOG_INDEX_SOURCE_FIELD:
                si = c
        if ti < 0:
            raise Error("L0SegmentBuilder: text field not found")
        if si < 0:
            raise Error("L0SegmentBuilder: _source field not found")
        var specs = _classify_l0_specs(schema)
        self._text_col_idx = ti
        self._source_col_idx = si
        self._analyzer = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
        self._posting = L0PostingBuilder()
        self._docstore = DocStoreBuilder()
        # One builder per spec (positional by field_class walk order — the SAME
        # order serialize_fastfields_region expects).
        self._num_builders = List[NumericFastFieldBuilder]()
        self._kw_builders = List[KeywordFastFieldBuilder]()
        for s in range(len(specs)):
            ref spec = specs[s]
            if spec.field_class == FIELD_CLASS_KEYWORD:
                self._kw_builders.append(KeywordFastFieldBuilder())
            else:
                self._num_builders.append(
                    NumericFastFieldBuilder(
                        spec.arrow_type_id, spec.storage_dtype
                    )
                )
        self._specs = specs^
        self._fieldnorm = NumericFastFieldBuilder(
            ArrowType.INT64.type_id, DType.int64
        )
        self._num_docs = 0
        self._schema = schema^

    @always_inline
    def num_docs(self) -> Int:
        return self._num_docs

    def add_batch(mut self, var rb: RecordBatch) raises:
        """Ingest one typed batch: tokenize the text column ONCE per row (feeding
        BOTH the cheap L0 posting AND the THFF fieldnorm from that single
        analyze), append each row's _source cell to the docstore (REUSED), and
        append each classified column's per-doc value to the THFF builders
        (REUSED via the sink's _ingest_numeric_column / keyword append). This is
        BYTE-IDENTICAL to the optimized writer for the docstore + THFF + fieldnorm
        — only the inverted index is replaced by the cheap posting."""
        var bv = batch_view_over(rb)
        var n = bv.n_rows()

        # ---- text path: tokenize ONCE per row -> posting + fieldnorm. ----
        var text_col = bv.col_str(self._text_col_idx)
        var stopwords = resolve_stopwords_for(self._analyzer)
        for r in range(n):
            var af = analyze_text_column_resolved(
                text_col, r, self._analyzer, stopwords
            )
            # fieldnorm = the per-row token count (the SAME value the optimized
            # writer captures from add_text_column — byte-identical THFF).
            self._fieldnorm.append_int(af.len(), is_null=False)
            # posting: hash each token (the SAME fnv1a_64 over the analyzed term
            # bytes the inverted builder uses), feed the per-doc term-hash multiset.
            var hashes = List[UInt64]()
            for ti in range(af.len()):
                hashes.append(fnv1a_64(af.tokens[ti].term.as_bytes()))
            self._posting.add_doc_terms(hashes)

        # ---- doc-store path: append each row's _source cell. ----
        var src_col = bv.col_str(self._source_col_idx)
        for r in range(n):
            var cell = src_col.get(r).to_string()
            self._docstore.append(cell.as_bytes())

        # ---- THFF path: append each classified column's per-doc value (REUSED
        #      sink ingest — byte-identical). ----
        var num_idx = 0
        var kw_idx = 0
        for s in range(len(self._specs)):
            ref spec = self._specs[s]
            if spec.field_class == FIELD_CLASS_KEYWORD:
                var kcol = bv.col_str(spec.col_idx)
                for r in range(n):
                    var is_null = bv.col_is_null(spec.col_idx, r)
                    if is_null:
                        self._kw_builders[kw_idx].append(String(""), True)
                    else:
                        self._kw_builders[kw_idx].append(
                            kcol.get(r).to_string(), False
                        )
                kw_idx += 1
            else:
                _ingest_numeric_column(
                    bv, spec, n, self._num_builders[num_idx]
                )
                num_idx += 1

        self._num_docs += n

    def serialize_split_bytes(
        mut self,
        field_name: String,
        split_uuid: InlineArray[UInt8, 16],
    ) raises -> List[UInt8]:
        """Emit the L0 split: a SPLIT_VERSION=1 additive-footer container with an
        EMPTY term-dict + EMPTY postings region, a POPULATED docstore + THFF, and
        the L0 posting blob in the `l0_posting` footer slot. PARSEABLE by
        SplitView.parse; the discriminator is the `l0_posting` slot.

        The empty inverted index is supplied via an EMPTY FinalizedIndex (0 terms)
        + an EMPTY TermDictionary — serialize_split writes a 0-length term-dict +
        postings region for them. The THFF region is built via the SAME
        serialize_fastfields_region the optimized writer uses (byte-identical)."""
        from komira_search.inverted import InvertedIndexBuilder
        from komira_search.term_dict import TermDictBuilder

        var doc_count = self._docstore.num_docs()
        var min_doc = 0
        var max_doc = 0
        if doc_count > 0:
            max_doc = doc_count - 1
        else:
            min_doc = 0  # empty-split sentinel

        # Empty inverted index (0 terms) -> empty term-dict + empty postings.
        var empty_inv = InvertedIndexBuilder.create(self._text_field())
        var fi = empty_inv.finalize()
        var term_dict = TermDictBuilder.build_from_finalized(fi)

        # The THFF region — byte-identical to the optimized writer's (same
        # serialize_fastfields_region over the same builders + the same fieldnorm).
        var ff_region = serialize_fastfields_region(
            self._specs, self._num_builders, self._kw_builders, self._fieldnorm
        )

        # The per-split total token count (the O(1) avgdl footer slot) — the SAME
        # value the optimized writer supplies (the fieldnorm sum). For an L0 split
        # this is what makes the additive footer chain hole-free so the l0_posting
        # slot is reachable.
        var total_tokens = FOOTER_NO_TOTAL_TOKENS
        if doc_count > 0:
            total_tokens = self._fieldnorm.total_value()

        # The cheap L0 posting blob — the additive `l0_posting` footer region.
        var l0_region = self._posting.serialize_region()

        return serialize_split(
            fi,
            term_dict^,
            self._docstore,
            field_name,
            split_uuid,
            min_doc,
            max_doc,
            doc_count,
            ff_region^,
            total_tokens,
            List[Int](),  # token_counts empty -> NO BLOCKMAX (L0 has none)
            l0_region^,
        )

    @always_inline
    def _text_field(self) -> String:
        return LOG_INDEX_TEXT_FIELD
