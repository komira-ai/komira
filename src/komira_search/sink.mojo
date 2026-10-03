# =============================================================================
# komira_search/sink.mojo
#   The SearchSink (Sink-trait conformer) + the move-only IndexCore.
# =============================================================================
#
# Upstream: the analyzer, the inverted index, the term dictionary. Container:
# komira_search/split.mojo (serialize_split + DocStoreBuilder). S3: the split
# upload helper in komira_search_s3 (the ONLY S3-touching code).
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE OWNS
# -----------------------------------------------------------------------------
#   * IndexCore — the move-only build core: owns the InvertedIndexBuilder (which
#     owns the per-term Slab accumulator) + the
#     DocStoreBuilder. Ingests text columns column-at-a-time (REUSING
#     InvertedIndexBuilder.add_text_column) + appends each
#     row's _source cell. flush_segment runs the flush sequence and
#     returns the OWNED split bytes.
#   * SearchSink — the DataFrame write operator. Conforms komira_core's Sink
#     (init_sink / accept_batch / finish; inherit default accept_row_blocks;
#     is_text_output_sink -> False). Move-only (it owns an IndexCore with a
#     Slab; copying it would mean two writers to one split = corruption).
#
# S3 handle ownership: SearchSink holds NO S3 client field (the
# S3Client[C] is parametric + move-only + per-worker-no-Arc; a client field on a
# moved-into-WriteSpec sink would be a dangling-field hazard). It stores only
# the S3 destination strings + the session S3 CONFIG (POD value types). The
# S3Client[C] is constructed SCOPE-LOCALLY in the split_upload helper (lifetime =
# stack frame the compiler tracks), never a field. SearchSink stays NON-[C]-
# parametric. SearchSink.finish() builds the split bytes and (for the unit
# path) leaves the PUT to a caller that holds the connector; the MinIO-gated
# integration test drives split_upload directly.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner self-audit)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public signature.
#   * ZERO wildcard origins, ZERO unsafe_from_address, ZERO take_pointee.
#   * IndexCore transitively owns a Slab (via InvertedIndexBuilder), so it
#     is MOVE-ONLY. The DocStoreBuilder it adds is all-POD List substrate. NO
#     new heap-owning byte-slab element. SearchSink is move-only. _split_uuid is
#     InlineArray[UInt8, 16]: no heap.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.collections.batch_view import batch_view_over
from komira_core.source.sink import Sink

from .analyzer import (
    AnalyzerConfig,
    FIELD_CLASS_TEXT,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
)
from .fast_fields import (
    FastFieldSpec,
    _DTYPE_NOT_A_FAST_FIELD,
    NumericFastFieldBuilder,
    KeywordFastFieldBuilder,
    serialize_fastfields_region,
    _storage_dtype_for_arrow_type_id,
    _is_float_dtype,
    FIELDNORM_NAME,
)
from .inverted import InvertedIndexBuilder
from .split import DocStoreBuilder, serialize_split, FOOTER_NO_TOTAL_TOKENS

from std.memory import bitcast

from komira_core.collections.batch_view import BatchView


# =============================================================================
# Fast-field column ingest helper (DType-dispatch, fail-loud; fast_fields J1).
# =============================================================================


def _ingest_numeric_column[
    o: Origin[mut=False]
](
    bv: BatchView[o],
    spec: FastFieldSpec,
    n: Int,
    mut builder: NumericFastFieldBuilder,
) raises:
    """Append `n` rows of one NUMERIC/DATE fast-field column to `builder`.

    fast_fields J1 — the read dispatches on the spec's STORAGE DType (NOT Field.dtype, which
    is DType.invalid for DATE32/DATE64/...; the storage DType comes from
    _storage_dtype_for_arrow_type_id). DATE32 reads through col_i32, DATE64/
    TIMESTAMP_* through col_i64 — their PHYSICAL dtype. The ladder RAISES on an
    unhandled DType (never falls through to col_i64 — that mis-route corrupts
    the bit pattern). Float cells are appended as IEEE-754 bit
    patterns. Nulls captured via BatchView.col_is_null (DType-agnostic).
    """
    var dt = spec.storage_dtype
    var ci = spec.col_idx
    if dt == DType.int64:
        var col = bv.col_i64(ci)
        for r in range(n):
            builder.append_int(Int(col.load[1](r)[0]), bv.col_is_null(ci, r))
    elif dt == DType.int32:
        var col = bv.col_i32(ci)
        for r in range(n):
            builder.append_int(Int(col.load[1](r)[0]), bv.col_is_null(ci, r))
    elif dt == DType.float64:
        var col = bv.col_f64(ci)
        for r in range(n):
            var v = col.load[1](r)[0]
            builder.append_float_bits(
                bitcast[DType.uint64](v), bv.col_is_null(ci, r)
            )
    elif dt == DType.float32:
        var col = bv.col_f32(ci)
        for r in range(n):
            var v = col.load[1](r)[0]
            builder.append_float_bits(
                UInt64(bitcast[DType.uint32](v)), bv.col_is_null(ci, r)
            )
    else:
        # Fail-loud (fast_fields J1): no col_i8/i16/u* typed accessor on BatchView, so
        # a column whose storage DType is one of those classified-but-unreadable
        # types must RAISE rather than mis-read through col_i64. (init_sink could
        # be tightened to skip them; raising here is the defensive backstop.)
        raise Error(
            "IndexCore.add_documents: fast-field column '"
            + spec.name
            + "' has storage DType "
            + String(dt)
            + " with no BatchView typed accessor (fast fields read i32/i64/f32/f64;"
            " widen init_sink classification or skip this column)"
        )


# =============================================================================
# IndexCore: the move-only build core.
# =============================================================================


struct IndexCore(Movable, Deinitable):
    """The build-side core: owns the InvertedIndexBuilder (which owns the
    per-term Slab accumulator) + the DocStoreBuilder. MOVE-ONLY (the Slab is
    move-only). One IndexCore == one split segment (single split, no flush
    triggers).

    doc-id assignment: assigns doc_id = _next_doc_id++ per row across ALL
    batches (monotonic, dense, ascending from _min_doc_id == 0 for the first
    segment). This satisfies the inverted index's ascending-doc-id HARD invariant
    (InvertedIndexBuilder.add_document) and the doc-store slot ==
    doc_id - min_doc_id convention.
    """

    var _inverted: InvertedIndexBuilder
    var _docstore: DocStoreBuilder
    var _analyzer: AnalyzerConfig
    var _next_doc_id: Int
    var _min_doc_id: Int
    var _have_doc: Bool
    # The fast-fields builders (POD List substrate, NOT
    # byte-slab elements). `_specs` is the classified-column directory resolved
    # in init_sink; `_num_builders` / `_kw_builders` are positionally indexed by
    # walking `_specs` (numeric/date -> _num_builders, keyword -> _kw_builders);
    # `_fieldnorm` is the reserved "__fieldnorm__" numeric field.
    var _specs: List[FastFieldSpec]
    var _num_builders: List[NumericFastFieldBuilder]
    var _kw_builders: List[KeywordFastFieldBuilder]
    var _fieldnorm: NumericFastFieldBuilder

    def __init__(
        out self,
        var inverted: InvertedIndexBuilder,
        var analyzer: AnalyzerConfig,
        var specs: List[FastFieldSpec],
    ):
        self._inverted = inverted^
        self._docstore = DocStoreBuilder()
        self._analyzer = analyzer^
        self._next_doc_id = 0
        self._min_doc_id = 0
        self._have_doc = False
        # Allocate one builder per spec (positional by field_class walk order).
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
        # The fieldnorm rides the same numeric machinery; stored as INT64.
        self._fieldnorm = NumericFastFieldBuilder(
            ArrowType.INT64.type_id, DType.int64
        )

    @staticmethod
    def create(
        field_name: String,
        analyzer: AnalyzerConfig,
        var specs: List[FastFieldSpec] = List[FastFieldSpec](),
    ) raises -> IndexCore:
        """Build an empty IndexCore for one text field + its classified
        fast-field columns."""
        return IndexCore(
            inverted=InvertedIndexBuilder.create(field_name),
            analyzer=analyzer.copy(),
            specs=specs^,
        )

    @always_inline
    def num_docs(self) -> Int:
        return self._docstore.num_docs()

    def add_documents(
        mut self,
        var rb: RecordBatch,
        text_col_idx: Int,
        source_col_idx: Int,
    ) raises:
        """Column-at-a-time ingest. Two views co-exist over ONE local `rb`
        under one origin:
          var bv = batch_view_over(rb)
          var text_col = bv.col_str(text_col_idx)
          var src_col  = bv.col_str(source_col_idx)
        For the text path REUSE InvertedIndexBuilder.add_text_column
        (it wraps the per-row analyze+add_document loop and
        bumps doc-ids). For the doc-store path append each row's _source cell
        (one-copy via to_string().as_bytes()).

        doc-ids are assigned base = self._next_doc_id .. + n - 1 across this
        batch; add_text_column bumps the inverted index in lockstep.
        """
        var bv = batch_view_over(rb)
        var n = bv.n_rows()
        var base = self._next_doc_id

        # ---- text path: reuse the column-at-a-time driver ----
        # Capture the per-row token count (the fieldnorm) from the SAME
        # single tokenization via the additive out-param.
        var text_col = bv.col_str(text_col_idx)
        var token_counts = List[Int]()
        self._inverted.add_text_column(
            text_col, base, self._analyzer, token_counts
        )
        for r in range(len(token_counts)):
            self._fieldnorm.append_int(token_counts[r], is_null=False)

        # ---- doc-store path: append each row's _source cell (one copy) ----
        var src_col = bv.col_str(source_col_idx)
        for r in range(n):
            # One O(cell) copy via to_string() (the fallback;
            # there is NO zero-copy Span accessor on StringView, and reaching
            # the column's internal pointer surfaces a forbidden wildcard origin).
            var cell = src_col.get(r).to_string()
            self._docstore.append(cell.as_bytes())

        # ---- fast-fields path: append each classified column's per-doc
        #      value via the BatchView typed accessors + col_is_null. The
        #      ingest read dispatches on the spec's STORAGE DType (never on
        #      Field.dtype, which is invalid for DATE32 etc), and the dtype
        #      ladder RAISES on an unhandled DType (never falls through). ----
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
                # NUMERIC / DATE -> the numeric builder; dispatch on STORAGE DType.
                _ingest_numeric_column(
                    bv, spec, n, self._num_builders[num_idx]
                )
                num_idx += 1

        if not self._have_doc and n > 0:
            self._min_doc_id = base
            self._have_doc = True
        self._next_doc_id = base + n

    def flush_segment(
        mut self,
        field_name: String,
        split_uuid: Array[UInt8, 16],
    ) raises -> List[UInt8]:
        """The flush sequence: finalize -> build term-dict -> hand
        (fi, term_dict^, doc_store, ...) to serialize_split (the SINGLE patch-pass
        owner) -> return the OWNED split bytes. The S3 PUT is the caller's
        thin wrapper (split_upload).

        flush_segment does NOT itself call set_posting_location — that is
        serialize_split's job.
        """
        from .term_dict import TermDictBuilder

        var fi = self._inverted.finalize()
        var term_dict = TermDictBuilder.build_from_finalized(fi)

        var doc_count = self._docstore.num_docs()
        var min_doc = self._min_doc_id
        var max_doc = 0
        if doc_count > 0:
            max_doc = min_doc + doc_count - 1
        else:
            min_doc = 0  # sentinel for empty split

        # Build the "THFF" fast-fields region (PURE, no S3) and hand it to
        # serialize_split. An empty region (no specs + 0 fieldnorm docs) yields a
        # split without fast fields (footer slot 0/0 — fast_fields J6).
        var ff_region = serialize_fastfields_region(
            self._specs, self._num_builders, self._kw_builders, self._fieldnorm
        )

        # Per-split total token count for the O(1) BM25 b>0 avgdl footer slot:
        # the sum of every doc's "__fieldnorm__" (which the fieldnorm builder
        # already holds), so the reader computes avgdl = total / doc_count in
        # O(1) instead of summing the whole fieldnorm column per query. For an
        # empty split (no docs) leave the slot absent (FOOTER_NO_TOTAL_TOKENS) —
        # the reader has nothing to normalize against anyway.
        var total_tokens = FOOTER_NO_TOTAL_TOKENS
        if doc_count > 0:
            total_tokens = self._fieldnorm.total_value()

        # Block-max WAND plumbing: the dense per-doc token counts (`dl` by
        # slot) the codec folds into per-block min_dl for the BLOCKMAX skip-list.
        # The fieldnorm builder already holds them; serialize_split emits BLOCKMAX
        # iff these are non-empty AND total_tokens >= 0 (both gate on the same
        # fieldnorm data, so the footer-chain invariant is naturally satisfied).
        # An empty split (no docs) supplies an empty list -> BLOCKMAX absent.
        var token_counts = List[Int]()
        if doc_count > 0:
            token_counts = self._fieldnorm.token_counts()

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
            token_counts^,
        )


# =============================================================================
# SearchSink: the Sink-trait conformer.
# =============================================================================


struct SearchSink(Sink, Movable):
    """Write destination that builds ONE immutable search split from its feeding
    DataFrame. Conforms komira_core's Sink (the DataFrame terminal-sink trait, NOT
    MorselSinkImpl). Move-only: owns an IndexCore (which owns the
    InvertedIndexBuilder/Slab + the doc-store builder).

        ctx.run(df^.write_to(SearchSink(bucket, key_prefix, index, text_field)))

    Lifecycle (Sink trait):
      init_sink(schema): resolve the ONE text field's column index + the _source
        column index (a DESIGNATED _source STRING column); construct the
        IndexCore.
      accept_batch(rb): IndexCore.add_documents.
      finish(): IndexCore.flush_segment -> serialize_split. The split bytes are
        retained in self._split_bytes for the caller / the integration PUT.

    NO S3 client field. Only the S3 destination strings + (in production) the
    session S3 CONFIG POD. The S3Client[C] is constructed SCOPE-LOCALLY in
    split_upload, never a field.
    """

    var _bucket: String
    var _key_prefix: String
    var _index: String
    var _text_field: String
    var _source_field: String
    var _split_uuid: Array[UInt8, 16]
    var _core: Optional[IndexCore]
    var _schema: Optional[Schema]
    var _text_col_idx: Int
    var _source_col_idx: Int
    var _split_bytes: List[UInt8]
    var _finished: Bool

    def __init__(
        out self,
        var bucket: String,
        var key_prefix: String,
        var index: String,
        var text_field: String,
        split_uuid: Array[UInt8, 16],
        var source_field: String = String("_source"),
    ):
        """Construct a SearchSink. `split_uuid` is the 16-byte UUID the caller
        mints (the object key is key_prefix/<index>/splits/<uuid>.split; the
        sink does NOT generate the key path or publish meta.json — it embeds
        the UUID and the caller PUTs to the resolved key)."""
        self._bucket = bucket^
        self._key_prefix = key_prefix^
        self._index = index^
        self._text_field = text_field^
        self._source_field = source_field^
        self._split_uuid = split_uuid.copy()
        self._core = Optional[IndexCore](None)
        self._schema = Optional[Schema](None)
        self._text_col_idx = -1
        self._source_col_idx = -1
        self._split_bytes = List[UInt8]()
        self._finished = False

    # --- Sink trait conformance ---

    def init_sink(mut self, schema: Schema) raises:
        """Record the output schema; resolve the text field's column index + the
        designated _source column index. Construct the IndexCore with the
        v1 TEXT analyzer for the text field.

        Also CLASSIFY the remaining columns (everything except the text
        col + the _source col) into FastFieldSpecs:
          * is_numeric() AND storage DType in {i32,i64,f32,f64} -> NUMERIC
          * is_temporal() AND storage DType in {i32,i64}        -> DATE
          * == STRING                                           -> KEYWORD
          * everything else (BOOL/BINARY/nested/Interval/Time/Duration/i8/i16/
            uint*/composite temporals) -> SKIPPED (not a fast field).
        Dispatch is on arrow_type_id -> a STORAGE DType (_storage_dtype_for_
        arrow_type_id), NOT on Field.dtype (which is DType.invalid for DATE32
        etc — fast_fields J1). A user column literally named '__fieldnorm__'
        is REJECTED (the reserved-name collision guard)."""
        self._schema = Optional[Schema](schema.copy())
        var n = schema.num_columns()
        var ti = -1
        var si = -1
        for c in range(n):
            var name = schema.field_name(c)
            if name == self._text_field:
                ti = c
            if name == self._source_field:
                si = c
        if ti < 0:
            raise Error(
                "SearchSink.init_sink: text field '"
                + self._text_field
                + "' not found in schema"
            )
        if si < 0:
            raise Error(
                "SearchSink.init_sink: _source field '"
                + self._source_field
                + "' not found in schema (a designated _source STRING"
                " column is required; the ingest shim supplies it)"
            )
        self._text_col_idx = ti
        self._source_col_idx = si

        # ---- fast-field classification. ----
        var specs = List[FastFieldSpec]()
        for c in range(n):
            if c == ti or c == si:
                continue
            var f = schema.field_at(c)
            if f.name == FIELDNORM_NAME:
                raise Error(
                    "SearchSink.init_sink: '"
                    + FIELDNORM_NAME
                    + "' is a reserved name (the doc-length fieldnorm)"
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
                # DATE only for the storage-aliasable i32/i64 subset.
                if storage == DType.int32 or storage == DType.int64:
                    specs.append(
                        FastFieldSpec(
                            f.name, c, FIELD_CLASS_DATE, atid, storage
                        )
                    )
                # else: composite/unaliasable temporal -> SKIP.
            elif f.arrow_type.is_numeric():
                if readable:
                    specs.append(
                        FastFieldSpec(
                            f.name, c, FIELD_CLASS_NUMERIC, atid, storage
                        )
                    )
                # else: i8/i16/uint* (no BatchView phase-0 accessor) -> SKIP.
            elif f.arrow_type == ArrowType.STRING:
                specs.append(
                    FastFieldSpec(
                        # PLACEHOLDER — was DType.invalid
                        f.name, c, FIELD_CLASS_KEYWORD, atid,
                        _DTYPE_NOT_A_FAST_FIELD,
                    )
                )
            # else: BOOL / BINARY / nested / DICTIONARY -> SKIP (out of scope).

        self._core = Optional[IndexCore](
            IndexCore.create(
                self._text_field,
                AnalyzerConfig.text(self._text_field),
                specs^,
            )
        )

    def accept_batch(mut self, var rb: RecordBatch) raises:
        """Feed one batch to the IndexCore (tokenize text column + append _source
        cells). Move-takes rb."""
        if not self._core:
            raise Error("SearchSink.accept_batch: init_sink was not called")
        self._core.value().add_documents(
            rb^, self._text_col_idx, self._source_col_idx
        )

    def finish(mut self) raises:
        """Flush the ONE segment: finalize -> term-dict -> posting region (patch)
        -> serialize term-dict -> doc-store -> serialize_split. The owned split
        bytes are retained in self._split_bytes for the caller / integration
        PUT."""
        if not self._core:
            raise Error("SearchSink.finish: init_sink was not called")
        self._split_bytes = self._core.value().flush_segment(
            self._text_field, self._split_uuid
        )
        self._finished = True

    def is_text_output_sink(self) -> Bool:
        """False — the split is a binary container, not a CSV/JSONL text stream.
        (Prevents the cast_to_varchar wrapper from firing.)"""
        return False

    # --- SearchSink-specific result retrieval (NOT on the Sink trait) ---

    @always_inline
    def is_finished(self) -> Bool:
        return self._finished

    def split_bytes_len(self) -> Int:
        """Byte length of the produced split (0 before finish())."""
        return len(self._split_bytes)

    def take_split_bytes(mut self) raises -> List[UInt8]:
        """Move the produced split bytes out (caller owns them; e.g. to hand to
        split_upload). Raises if finish() was not called."""
        if not self._finished:
            raise Error(
                "SearchSink.take_split_bytes: finish() was not called"
            )
        var out = self._split_bytes^
        self._split_bytes = List[UInt8]()
        return out^

    def object_key(self) -> String:
        """The resolved object key for this split: <key_prefix>/<index>/splits/
        <uuid>.split. The caller PUTs to this key."""
        var hexdigits = "0123456789abcdef"
        var hb = hexdigits.as_bytes()
        var uuid_hex = String("")
        for i in range(16):
            var b = Int(self._split_uuid[i])
            uuid_hex += chr(Int(hb[(b >> 4) & 0xF]))
            uuid_hex += chr(Int(hb[b & 0xF]))
        # Strip a single trailing '/' from the prefix (byte-level, no String
        # __getitem__ — Mojo's String has no byte index/slice operator).
        var pb = self._key_prefix.as_bytes()
        var plen = len(pb)
        if plen > 0 and pb[plen - 1] == UInt8(47):  # '/'
            plen -= 1
        var prefix_buf = List[UInt8]()
        for i in range(plen):
            prefix_buf.append(pb[i])
        var prefix = String(StringSlice(unsafe_from_utf8=Span(prefix_buf)))
        return prefix + "/" + self._index + "/splits/" + uuid_hex + ".split"

    @always_inline
    def bucket(self) -> String:
        return self._bucket
