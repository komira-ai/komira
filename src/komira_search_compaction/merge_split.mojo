# =============================================================================
# komira_search_compaction/merge_split.mojo — the merge: K splits into one.
# =============================================================================
#
# The merge re-indexes. Given the bytes of K input splits, it reconstructs the
# recoverable content of every input and feeds it through the same
# `SearchSink` pipeline that writes any split, so no new format code exists.
#
# Typed fast-field columns are carried forward, not re-inferred. The merge
# reads each input's already-typed fast-field columns with `FastFieldReader`,
# dispatching on the field class and encoding recorded in the input, and
# re-derives only the text field: it extracts the text field from the verbatim
# `_source` blob and tokenizes it again with the sink's analyzer, so index-time
# and query-time analysis stay symmetric. It builds one pre-resolved Arrow
# `RecordBatch` (the text field, `_source`, and each fast field as its resolved
# typed nullable column) and feeds `init_sink`, `accept_batch` and `finish`, so
# the sink classifies columns by their Arrow types. Re-inferring the types from
# JSON would be wrong: two splits that each ingested fine could then become
# unmergeable, or the merged type could silently differ.
#
# Type reconciliation across inputs: identical class and encoding are used
# as they are; an integer field meeting a float field is widened to FLOAT64; any
# other combination fails the merge with an error that names the field, and the
# caller leaves the inputs live.
#
# Scores shift across a compaction. A merged split computes its own average
# document length, field norms and document count over the combined documents,
# so absolute BM25 scores (and possibly rank) differ from the scores of the
# inputs. The merged split scores identically to one ingest of the union of the
# documents.
#
# The merged `SplitSummary` records the UUIDs of its inputs
# (`make_merged_split_summary`), so a catalog read skips the inputs while the
# merged split is live and publishing the merge and retiring its inputs look
# atomic.
#
# The merged object key is content-addressed: a deterministic function of the
# sorted input UUID set, so a re-run that picks the same inputs writes the same
# key, which is a harmless overwrite. The merged split itself gets a fresh UUID
# and a fresh dense document-id space 0..M-1.
#
# No pointer appears in any signature.
# =============================================================================

from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from komira_json import JsonValue, parse_json_value

from komira_search.analyzer import (
    AnalyzerConfig,
    FIELD_CLASS_KEYWORD,
    FIELD_CLASS_NUMERIC,
    FIELD_CLASS_DATE,
)
from komira_search.fast_fields import (
    FastFieldReader,
    FIELDNORM_NAME,
    FF_ENC_FOR_BITPACK,
    FF_ENC_KEYWORD_DICT,
    FF_ENC_FLOAT_FULL,
)
from komira_search.sink import SearchSink
from komira_search.source import read_docstore_source
from komira_search.split import SplitView


# =============================================================================
# A resolved merge-column type (the carry-forward reconciliation kind).
# =============================================================================

comptime MCOL_KEYWORD: Int = 0
"""A STRING (keyword) merge column."""
comptime MCOL_INT64: Int = 1
"""An INT64 (numeric/date FF_ENC_FOR_BITPACK) merge column."""
comptime MCOL_FLOAT64: Int = 2
"""A FLOAT64 (FF_ENC_FLOAT_FULL) merge column."""


def _mcol_for_encoding(field_class: UInt8, encoding: UInt8) -> Int:
    """Map the RESOLVED (field_class, encoding) read off a split's THFF
    directory to a merge-column kind. Keyword -> STRING; float-encoded ->
    FLOAT64; everything else numeric/date (FF_ENC_FOR_BITPACK) -> INT64 (a DATE
    flows through the i64 accessor — its physical storage)."""
    if field_class == FIELD_CLASS_KEYWORD:
        return MCOL_KEYWORD
    if encoding == FF_ENC_FLOAT_FULL:
        return MCOL_FLOAT64
    return MCOL_INT64


def _arrow_type_for_mcol(mcol: Int) -> ArrowType:
    if mcol == MCOL_KEYWORD:
        return ArrowType.STRING
    elif mcol == MCOL_INT64:
        return ArrowType.INT64
    else:
        return ArrowType.FLOAT64


def _mcol_name(mcol: Int) -> StaticString:
    if mcol == MCOL_KEYWORD:
        return "keyword(string)"
    elif mcol == MCOL_INT64:
        return "long(int64)"
    else:
        return "double(float64)"


# =============================================================================
# Per-field accumulator (carries the
# RESOLVED merge-column kind, NOT a re-inferred one).
# =============================================================================


struct _MergeFieldAccum(Copyable, Movable, Deinitable):
    """One union-schema fast-field across all inputs, in first-seen order. Holds
    the per-row cells already widened to the reconciled merge-column kind. POD

    Copyable+Movable (not Movable-only): a `List[_MergeFieldAccum]` needs a
    Copyable element."""

    var name: String
    var mcol: Int
    var valid: List[Bool]
    var str_vals: List[String]
    var i64_vals: List[Int64]
    var f64_vals: List[Float64]

    def __init__(out self, var name: String, mcol: Int):
        self.name = name^
        self.mcol = mcol
        self.valid = List[Bool]()
        self.str_vals = List[String]()
        self.i64_vals = List[Int64]()
        self.f64_vals = List[Float64]()

    def _pad_to(mut self, n: Int):
        """Back-fill null cells up to `n` rows (a doc/input that lacks this
        field)."""
        while len(self.valid) < n:
            self.valid.append(False)
            if self.mcol == MCOL_KEYWORD:
                self.str_vals.append(String(""))
            elif self.mcol == MCOL_INT64:
                self.i64_vals.append(Int64(0))
            else:
                self.f64_vals.append(Float64(0.0))

    def _widen_to_float(mut self) raises:
        """Reconciliation: a field first seen as INT64 then seen as FLOAT64 in
        a later split -> widen the already-stored int cells to float (lossless)
        + flip the kind."""
        if self.mcol == MCOL_FLOAT64:
            return
        if self.mcol != MCOL_INT64:
            raise Error(
                "merge: cannot widen field '" + self.name + "' of kind "
                + _mcol_name(self.mcol) + " to float"
            )
        var widened = List[Float64](capacity=len(self.i64_vals))
        for i in range(len(self.i64_vals)):
            widened.append(Float64(self.i64_vals[i]))
        self.f64_vals = widened^
        self.i64_vals = List[Int64]()
        self.mcol = MCOL_FLOAT64


def _find_accum(fields: List[_MergeFieldAccum], name: String) -> Int:
    for i in range(len(fields)):
        if fields[i].name == name:
            return i
    return -1


# =============================================================================
# content_addressed_merge_key: deterministic key from the sorted input UUIDs.
# =============================================================================


def _uuid_less(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return a[i] < b[i]
    return False


comptime _FNV64_OFFSET: UInt64 = 0xCBF29CE484222325
comptime _FNV64_PRIME: UInt64 = 0x100000001B3


def _fnv1a64(data: List[UInt8], seed: UInt64) -> UInt64:
    """FNV-1a 64-bit over `data`, mixed with `seed` (so two passes with distinct
    seeds give two independent 64-bit halves -> a 128-bit content digest).
    Dependency-free (the same FNV discipline as the metastore's framing)."""
    var h = _FNV64_OFFSET ^ seed
    for i in range(len(data)):
        h = (h ^ UInt64(Int(data[i]))) * _FNV64_PRIME
    return h


def _u64_hex(v: UInt64) -> String:
    var hexdigits = "0123456789abcdef"
    var hb = hexdigits.as_bytes()
    var out = String("")
    for i in range(16):  # 16 hex chars = 64 bits, MSB first.
        var shift = UInt64((15 - i) * 4)
        var nib = Int((v >> shift) & UInt64(0xF))
        out += chr(Int(hb[nib]))
    return out^


def content_addressed_merge_key(
    key_prefix: String,
    index: String,
    input_uuids: List[Array[UInt8, 16]],
) -> String:
    """The merged `.split` object key = a deterministic function of the SORTED
    input split-UUID set. A re-run that picks the SAME input set produces
    the SAME key -> the PUT is a harmless overwrite (idempotency / overlap
    safety, test #4).

    The key is content-addressed via a FIXED-LENGTH 128-bit digest (two
    independent FNV-1a-64 hashes of the sorted UUID bytes), NOT the raw
    concatenated UUIDs — a merge set of up to MAX_MERGE_FACTOR=12 UUIDs would
    otherwise produce a 384-hex-char object name that an object store may reject
    (object names have a length / character bound). The
    digest is deterministic in the SORTED set, so the content-addressing property
    holds (same set -> same digest -> same key). Layout:
      <prefix>/<index>/splits/merged-<32 hex chars>.split."""
    # Sort a copy of the uuids (insertion sort; merge sets are small <= 12).
    var sorted = List[Array[UInt8, 16]]()
    for i in range(len(input_uuids)):
        sorted.append(input_uuids[i].copy())
    for i in range(1, len(sorted)):
        var v = sorted[i].copy()
        var j = i - 1
        while j >= 0 and _uuid_less(v, sorted[j]):
            sorted[j + 1] = sorted[j].copy()
            j -= 1
        sorted[j + 1] = v^
    # Flatten the sorted UUID bytes, then hash to a fixed 128-bit digest.
    var flat = List[UInt8]()
    for i in range(len(sorted)):
        for k in range(16):
            flat.append(sorted[i][k])
    var h_lo = _fnv1a64(flat, UInt64(0))
    var h_hi = _fnv1a64(flat, UInt64(0x9E3779B97F4A7C15))  # a distinct seed.
    var digest = _u64_hex(h_hi) + _u64_hex(h_lo)  # 32 hex chars.
    # Strip a single trailing '/' from the prefix.
    var pb = key_prefix.as_bytes()
    var plen = len(pb)
    if plen > 0 and pb[plen - 1] == UInt8(47):  # '/'
        plen -= 1
    var prefix_buf = List[UInt8]()
    for i in range(plen):
        prefix_buf.append(pb[i])
    # SAFETY: `prefix_buf` is a prefix of the bytes of a valid UTF-8 `String`,
    # cut only just before a trailing ASCII '/', so it is valid UTF-8.
    var prefix = String(StringSlice(unsafe_from_utf8=Span(prefix_buf)))
    return prefix + "/" + index + "/splits/merged-" + digest + ".split"


# =============================================================================
# Column builders (typed nullable).
# =============================================================================


def _str_col_nullable(
    values: List[String], valid: List[Bool]
) raises -> Column[HeapRegion]:
    return Column.from_string(
        StringArray.from_strings_with_validity(values, valid)
    )


def _i64_col_nullable(
    raw: List[Int64], valid: List[Bool]
) raises -> Column[HeapRegion]:
    var n = len(raw)
    comptime es = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, raw[i])
    buf.set_length(Int64(n * es))
    var bm = Bitmap.create_all_valid(n)
    var null_count = 0
    for i in range(n):
        if not valid[i]:
            bm.clear(i)
            null_count += 1
    var arr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), null_count, 0
    )
    return Column.from_primitive[DType.int64](arr)


def _f64_col_nullable(
    raw: List[Float64], valid: List[Bool]
) raises -> Column[HeapRegion]:
    var n = len(raw)
    comptime es = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * es)
    for i in range(n):
        buf.set_typed[Scalar[DType.float64]](i, raw[i])
    buf.set_length(Int64(n * es))
    var bm = Bitmap.create_all_valid(n)
    var null_count = 0
    for i in range(n):
        if not valid[i]:
            bm.clear(i)
            null_count += 1
    var arr = PrimitiveArray[DType.float64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), null_count, 0
    )
    return Column.from_primitive[DType.float64](arr)


# =============================================================================
# MergeResult: the merged split bytes + its summary fields.
# =============================================================================


@fieldwise_init
struct MergeResult(Movable, Deinitable):
    """The merge reducer's output: the merged `.split` bytes + the metadata the
    caller needs to publish its SplitSummary (the UUID/doc_count/min/max come
    from the SplitView footer; the object_key is the content-addressed key the
    caller PUT to; the input-UUID set + merge_ops feed make_merged_split_summary
    for the merged-input hiding and the maturity guard)."""

    var split_bytes: List[UInt8]
    var merged_uuid: Array[UInt8, 16]
    var doc_count: Int
    var input_uuids_flat: List[UInt8]
    var merge_ops: Int64

    def take_split_bytes(mut self) -> List[UInt8]:
        """Move ONLY the merged split bytes out (the other fields — merge_ops /
        input_uuids_flat / doc_count / merged_uuid — are scalars or small Lists
        the caller reads BY COPY before calling this).

        `compact_once` writes the split bytes to the store. This uses the
        move-then-reset idiom of `SearchSink.take_split_bytes`: move the field
        out, then re-seat it as an empty List so `self` stays whole and drops
        normally, with no partial move."""
        var out = self.split_bytes^
        self.split_bytes = List[UInt8]()
        return out^


# =============================================================================
# merge_split_bytes: the reducer.
# =============================================================================


def merge_split_bytes(
    input_split_bytes: List[List[UInt8]],
    index: String,
    bucket: String,
    key_prefix: String,
    text_field: String,
    merged_uuid: Array[UInt8, 16],
    object_key: String,
) raises -> MergeResult:
    """Merge K input splits' bytes into ONE merged `.split` via RE-INDEX.

    Reads each input (in publish order, doc-id ascending within each): the
    verbatim `_source` blob (the doc-store) + each fast-field column at its
    RESOLVED type (no re-inference). Re-derives `body` by JSON-extracting
    the text field from `_source` and re-tokenizing it through the SearchSink's
    analyzer (analyzer symmetry). Builds ONE pre-resolved typed RecordBatch and
    feeds the SearchSink pipeline.

    Cross-split reconciliation: identical merge-column kind -> use; int<->float
    -> widen FLOAT64; else FAIL THE MERGE (raise — the caller leaves the inputs
    live). The merged split gets a fresh dense 0..M-1 doc-id space + the passed
    `merged_uuid`.

    Returns the merged bytes + the metadata for the merged SplitSummary."""
    if len(input_split_bytes) == 0:
        raise Error("merge_split_bytes: no input splits to merge")

    # ---- Pass 1: read every input -> the union body / _source / typed fields ---
    var body_values = List[String]()
    var source_values = List[String]()
    var fields = List[_MergeFieldAccum]()
    var input_uuids = List[Array[UInt8, 16]]()
    var doc_index = 0  # the dense merged row counter (0..M-1).

    for ii in range(len(input_split_bytes)):
        # Parse the input split (consumes a COPY of its bytes; the caller keeps
        # ownership of the original List for content-addressing).
        var view = SplitView.parse(input_split_bytes[ii].copy())
        input_uuids.append(view.split_uuid())
        var n_docs = view.doc_count()
        var min_id = view.min_doc_id()

        # The fast-field reader for this input (parses the THFF directory once).
        var reader = FastFieldReader(view)

        # Resolve this input's fast-field directory ONCE: (name, mcol). Skip the
        # reserved __fieldnorm__ (re-derived from re-tokenization, not carried).
        var ff_names = List[String]()
        var ff_mcols = List[Int]()
        for fi in range(reader.num_fields()):
            var meta = reader.entry_meta_at(fi)
            var fname = meta[0]
            if fname == FIELDNORM_NAME:
                continue
            ff_names.append(fname)
            ff_mcols.append(_mcol_for_encoding(meta[1], meta[2]))

        # ---- per-doc loop over this input ----
        var docstore = view.docstore_region()
        for slot in range(n_docs):
            var doc_id = min_id + slot
            # _source blob (verbatim JSON line). read_docstore_source decodes per
            # the compressed_flag, so the merge inherits LZ4 decompression
            # automatically (an LZ4 OR an old uncompressed input both read back to
            # the same JSON line); the merged split is re-written compressed via
            # the SearchSink/DocStoreBuilder default.
            var src = read_docstore_source(docstore, slot)
            source_values.append(src.copy())

            # body = the text field JSON-extracted from _source (re-derive
            # ONLY the text field; the OTHER fields come pre-typed from the
            # readers, no dynamic re-inference).
            var doc = parse_json_value(src)
            if not doc.is_object():
                raise Error(
                    "merge: _source blob is not a JSON object (corrupt split)"
                )
            var body_text = String("")
            if doc.has(text_field):
                body_text = doc.get(text_field).as_string()
            body_values.append(body_text)

            # Each carried fast-field for THIS input doc.
            for k in range(len(ff_names)):
                var fname = ff_names[k]
                var this_mcol = ff_mcols[k]
                var ai = _find_accum(fields, fname)
                if ai < 0:
                    # First occurrence across all inputs: fix the kind, back-fill
                    # nulls for the docs before this one.
                    var acc = _MergeFieldAccum(fname.copy(), this_mcol)
                    acc._pad_to(doc_index)
                    _append_cell(acc, reader, view, fname, this_mcol, doc_id)
                    fields.append(acc^)
                else:
                    # Reconcile the kind, then append.
                    _reconcile_and_append(
                        fields[ai], reader, view, fname, this_mcol, doc_id
                    )

            # Pad every union field NOT present in this input with a null cell.
            for fi in range(len(fields)):
                if len(fields[fi].valid) <= doc_index:
                    fields[fi]._pad_to(doc_index + 1)

            doc_index += 1

    # ---- Build the pre-resolved typed RecordBatch. ----
    var rb = _build_merged_batch(text_field, body_values, source_values, fields)
    var schema = rb.schema.copy()

    # ---- Feed the SearchSink pipeline -> merged split bytes. ----
    var sink = SearchSink(
        bucket.copy(),
        key_prefix.copy(),
        index.copy(),
        text_field.copy(),
        merged_uuid,
    )
    sink.init_sink(schema)
    sink.accept_batch(rb^)
    sink.finish()
    var merged_bytes = sink.take_split_bytes()

    # ---- The input UUID set (flat 16*n) + merge_ops. ----
    var flat = List[UInt8]()
    for i in range(len(input_uuids)):
        for k in range(16):
            flat.append(input_uuids[i][k])
    _ = object_key  # the caller writes to this key; carried for symmetry.

    return MergeResult(
        merged_bytes^,
        merged_uuid.copy(),
        doc_index,
        flat^,
        Int64(1),
    )


def _append_cell(
    mut acc: _MergeFieldAccum,
    reader: FastFieldReader,
    view: SplitView,
    name: String,
    this_mcol: Int,
    doc_id: Int,
) raises:
    """Read the fast-field cell at `doc_id` from `reader` (dispatched on the
    RESOLVED kind) and append it to a SAME-kind accumulator. `this_mcol ==
    acc.mcol` is the caller's guarantee for the first occurrence; reconciliation
    is in `_reconcile_and_append`."""
    if acc.mcol == MCOL_KEYWORD:
        var c = reader.fast_field_keyword(view, name, doc_id)
        if c:
            acc.valid.append(True)
            acc.str_vals.append(c.value())
        else:
            acc.valid.append(False)
            acc.str_vals.append(String(""))
    elif acc.mcol == MCOL_INT64:
        var c = reader.fast_field_i64(view, name, doc_id)
        if c:
            acc.valid.append(True)
            acc.i64_vals.append(c.value())
        else:
            acc.valid.append(False)
            acc.i64_vals.append(Int64(0))
    else:  # MCOL_FLOAT64
        var c = reader.fast_field_f64(view, name, doc_id)
        if c:
            acc.valid.append(True)
            acc.f64_vals.append(c.value())
        else:
            acc.valid.append(False)
            acc.f64_vals.append(Float64(0.0))


def _reconcile_and_append(
    mut acc: _MergeFieldAccum,
    reader: FastFieldReader,
    view: SplitView,
    name: String,
    this_mcol: Int,
    doc_id: Int,
) raises:
    """Cross-split reconciliation for a field already established in `acc`:
      * identical kind -> read at the established kind + append.
      * int<->float (either direction) -> widen the column to FLOAT64, then read
        the int cell as float (lossless).
      * anything else (e.g. keyword vs numeric) -> FAIL THE MERGE (raise; the
        caller leaves the inputs live — a stated, non-silent policy)."""
    if this_mcol == acc.mcol:
        _append_cell(acc, reader, view, name, this_mcol, doc_id)
        return
    # int<->float widening.
    var int_float = (
        (acc.mcol == MCOL_INT64 and this_mcol == MCOL_FLOAT64)
        or (acc.mcol == MCOL_FLOAT64 and this_mcol == MCOL_INT64)
    )
    if int_float:
        acc._widen_to_float()  # no-op if already float
        # Read THIS doc's cell at its native kind, widen to float.
        if this_mcol == MCOL_INT64:
            var c = reader.fast_field_i64(view, name, doc_id)
            if c:
                acc.valid.append(True)
                acc.f64_vals.append(Float64(c.value()))
            else:
                acc.valid.append(False)
                acc.f64_vals.append(Float64(0.0))
        else:
            var c = reader.fast_field_f64(view, name, doc_id)
            if c:
                acc.valid.append(True)
                acc.f64_vals.append(c.value())
            else:
                acc.valid.append(False)
                acc.f64_vals.append(Float64(0.0))
        return
    # Irreconcilable conflict -> fail the merge (leave inputs live).
    raise Error(
        "merge: field '" + name + "' has incompatible types across splits ("
        + _mcol_name(acc.mcol) + " vs " + _mcol_name(this_mcol)
        + ") — merge aborted, inputs left live (non-silent reconciliation"
        " policy)"
    )


def _build_merged_batch(
    text_field: String,
    body_values: List[String],
    source_values: List[String],
    fields: List[_MergeFieldAccum],
) raises -> RecordBatch:
    """Build the N-column merged DocBatch — PRE-RESOLVED typed columns:
      {<text_field>: STRING non-null, _source: STRING non-null,
       <field_1>: <reconciled type> nullable, ...}
    init_sink resolves text/_source by NAME and classifies each typed column by
    its ARROW TYPE (no JSON re-inference)."""
    var ta = StringArray.from_strings(body_values)
    var sa = StringArray.from_strings(source_values)
    var sb = SchemaBuilder()
    sb.add_field(Field(text_field, ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    for fi in range(len(fields)):
        sb.add_field(
            Field(
                fields[fi].name,
                _arrow_type_for_mcol(fields[fi].mcol),
                True,
            )
        )
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2 + len(fields))
    rb.add_column(Column.from_string(ta^))
    rb.add_column(Column.from_string(sa^))
    for fi in range(len(fields)):
        ref f = fields[fi]
        if f.mcol == MCOL_KEYWORD:
            rb.add_column(_str_col_nullable(f.str_vals, f.valid))
        elif f.mcol == MCOL_INT64:
            rb.add_column(_i64_col_nullable(f.i64_vals, f.valid))
        else:
            rb.add_column(_f64_col_nullable(f.f64_vals, f.valid))
    return rb.build(schema^)
