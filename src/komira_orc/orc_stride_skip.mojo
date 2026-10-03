# =============================================================================
# orc_stride_skip.mojo — ORC row-index stride decode + skip.
# =============================================================================
#
# Per-stripe ROW_INDEX streams carry per-stride (default 10K
# rows) ColumnStatistics (min/max/null-count). For a selective range predicate
# flowing through the read path, strides whose [min,max] is disjoint from the
# predicate cannot contain a matching row and are skipped before they reach the
# Arrow output. This is the third level of the ORC scan-side skip cascade:
#   (1) column-projection  (2) stripe-stats  (3) stride-stats [THIS MODULE]
#   (4) stride-bloom [hangs off the same per-stride loop]
#
# Predicate surface: the predicate type is `komira_core.plan.expr.Expr`
# (predicates travel as `Expr` + `ScalarValue`, exactly as the Parquet page
# pruner takes them). This module supports the range-predicate subset (col <op> int-literal, AND /
# OR composition); every unsupported shape degrades CONSERVATIVELY to all-pass
# (the stride survives) so a stride is NEVER falsely skipped.
#
# Skip mechanism (HONEST framing): the column decoder is not yet resumable, so
# this module decodes the whole stripe and DROPS the rows belonging to skipped
# strides (a post-decode stride filter). The result is correct (rows in
# surviving strides only) and the stride-skip count is real. Saving the decode
# work via the ROW_INDEX positions[] seek table is not implemented yet.
#
# Encapsulation: public API takes a borrowed Span + a borrowed Expr and returns
# an owned result. No UnsafePointer crosses the module boundary; stride stats
# are small POD lists.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch
from komira_core.helpers.compiler_helpers import gather_batch

from komira_core.plan.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_IN_LIST,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_core.plan.scalar_value import ScalarValue

from komira_core.collections.slab import Slab
from komira_core.arrow.record_batch import RecordBatchBuilder

from .footer import (
    OrcFileTail,
    StripeFooter,
    StripeInformation,
    OrcRowIndex,
    OrcColumnStatistics,
    OrcStripeStatistics,
    Metadata,
    OrcBloomFilterEntry,
    OrcBloomFilterIndex,
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER_UTF8,
    ORC_COMPRESSION_NONE,
)
from .orc_schema import (
    OrcSchema,
    orc_node_to_arrow,
    ORC_KIND_STRUCT,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_DATE,
)
from .orc_codec import decompress_stream
from .orc_reader import (
    _parse_tail_codec_aware,
    read_orc_bytes,
    _resolve_projection,
    _build_output_schema,
    _locate_streams,
    _checked_file_span,
    _gather_column_streams,
)
from .column_decoder import ColumnAcc, make_accumulator, decode_stripe_column
from .bloom_filter import OrcBloomFilter


# =============================================================================
# OrcFilteredResult — the stride-skip read result.
# =============================================================================


struct OrcFilteredResult(Movable):
    """Result of a stride-skipping ORC read.

    Fields:
        batch:           The Arrow RecordBatch of rows in SURVIVING strides only.
        strides_total:   Total strides examined across all stripes.
        strides_skipped: Strides proven predicate-disjoint and skipped.
    """

    var batch: RecordBatch
    var strides_total: Int
    var strides_skipped: Int

    def __init__(
        out self, var batch: RecordBatch, strides_total: Int, strides_skipped: Int
    ):
        self.batch = batch^
        self.strides_total = strides_total
        self.strides_skipped = strides_skipped


# =============================================================================
# Per-stride descriptor: a contiguous file-row range + per-column stats.
# =============================================================================


struct _Stride(Copyable, Movable):
    """One stride: its absolute file-row range + per-output-column statistics +
    per-output-column bloom filters."""

    var row_start: Int  # absolute row index in the file
    var row_count: Int
    var col_stats: List[OrcColumnStatistics]  # indexed by OUTPUT column
    # Per-output-column bloom. `col_has_bloom[c]` is True iff this
    # stride has a usable (utf8bitset) bloom for output column c.
    var col_has_bloom: List[Bool]
    var col_blooms: List[OrcBloomFilterEntry]

    def __init__(out self, row_start: Int, row_count: Int):
        self.row_start = row_start
        self.row_count = row_count
        self.col_stats = List[OrcColumnStatistics]()
        self.col_has_bloom = List[Bool]()
        self.col_blooms = List[OrcBloomFilterEntry]()

    def copy(self) -> Self:
        var c = _Stride(self.row_start, self.row_count)
        c.col_stats = self.col_stats.copy()
        c.col_has_bloom = self.col_has_bloom.copy()
        c.col_blooms = self.col_blooms.copy()
        return c^


# =============================================================================
# Predicate vs stride-stats: does a single op-literal leaf keep this stride?
# =============================================================================
#
# Returns True iff the stride MIGHT contain a matching row (conservative). A
# False return is a proof that no row in the stride can match (safe to skip).


def _int_leaf_keeps_stride(
    st: OrcColumnStatistics, op: UInt8, lit: Int64
) -> Bool:
    # Without int stats we cannot prove disjointness — keep the stride.
    if not st.has_int or st.number_of_values == 0:
        return True
    var lo = st.int_min
    var hi = st.int_max
    if op == BIN_EQ:
        return lit >= lo and lit <= hi
    elif op == BIN_NE:
        # Only prunable if the stride is a single constant equal to lit.
        if lo == hi and lo == lit:
            return False
        return True
    elif op == BIN_LT:
        return lo < lit
    elif op == BIN_LE:
        return lo <= lit
    elif op == BIN_GT:
        return hi > lit
    elif op == BIN_GE:
        return hi >= lit
    return True


# =============================================================================
# Expr walk: does the predicate keep this stride? (per-stride evaluation)
# =============================================================================
#
# Mirrors `page_pruner._picks_for_column_in_expr` discipline:
#   - AND  -> a stride is kept iff BOTH sides keep it.
#   - OR   -> a stride is kept iff EITHER side keeps it.
#   - leaf -> col <op> int-literal against THIS stride's stats for that column.
#   - unsupported shape (non-int literal, col-op-col, cast, string-op, ...) ->
#     conservative keep (True).


def _expr_keeps_stride(
    expr: Expr,
    col_names: List[String],
    stride: _Stride,
) raises -> Bool:
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        if op == BIN_AND:
            ref l = expr.binary_left_ref()
            ref r = expr.binary_right_ref()
            var lk = _expr_keeps_stride(l, col_names, stride)
            if not lk:
                return False
            return _expr_keeps_stride(r, col_names, stride)
        if op == BIN_OR:
            ref l = expr.binary_left_ref()
            ref r = expr.binary_right_ref()
            var lk = _expr_keeps_stride(l, col_names, stride)
            if lk:
                return True
            return _expr_keeps_stride(r, col_names, stride)
        if (
            op == BIN_EQ
            or op == BIN_NE
            or op == BIN_LT
            or op == BIN_LE
            or op == BIN_GT
            or op == BIN_GE
        ):
            return _comparison_keeps_stride(expr, op, col_names, stride)
        # Arithmetic / other binary op — conservative keep.
        return True
    # Non-binary node — conservative keep.
    return True


def _comparison_keeps_stride(
    expr: Expr,
    op: UInt8,
    col_names: List[String],
    stride: _Stride,
) raises -> Bool:
    ref left = expr.binary_left_ref()
    ref right = expr.binary_right_ref()
    var ltag = left.tag
    var rtag = right.tag

    # Canonical `col <op> literal`.
    if ltag == EXPR_COL_REF and rtag == EXPR_LITERAL:
        var name = left.col_ref_name()
        var col = _output_col_index(col_names, name)
        if col < 0:
            return True
        var lit = right.literal_value()
        if not lit.is_int():
            return True
        return _int_leaf_keeps_stride(stride.col_stats[col], op, lit.int_val)

    # `literal <op> col` — swap the operator.
    if rtag == EXPR_COL_REF and ltag == EXPR_LITERAL:
        var name = right.col_ref_name()
        var col = _output_col_index(col_names, name)
        if col < 0:
            return True
        var lit = left.literal_value()
        if not lit.is_int():
            return True
        var swapped = op
        if op == BIN_LT:
            swapped = BIN_GT
        elif op == BIN_LE:
            swapped = BIN_GE
        elif op == BIN_GT:
            swapped = BIN_LT
        elif op == BIN_GE:
            swapped = BIN_LE
        return _int_leaf_keeps_stride(
            stride.col_stats[col], swapped, lit.int_val
        )

    # col-op-col, cast(col)-op-lit, etc — conservative keep.
    return True


@always_inline
def _output_col_index(col_names: List[String], name: String) -> Int:
    for i in range(len(col_names)):
        if col_names[i] == name:
            return i
    return -1


# =============================================================================
# Stride-bloom: the 4th cascade level (after stride-stats).
# =============================================================================
#
# Bloom fires ONLY on equality / IN predicates (orc-cpp PredicateLeaf.cc:607-622
# `shouldEvaluateBloomFilter` admits EQUALS / NULL_SAFE_EQUALS / IN only). Range
# predicates rely on the stride min/max. Every other shape — and any column
# without a usable bloom — degrades CONSERVATIVELY to all-pass (keep), so a
# stride is NEVER falsely skipped. A bloom miss is a PROOF of absence (modulo the
# bloom's own no-false-negative guarantee), so a False return is safe to skip.
#
# Mirrors `_expr_keeps_stride` shape:
#   AND  -> kept iff BOTH sides keep.
#   OR   -> kept iff EITHER side keeps.
#   col = lit  / lit = col  -> probe THIS stride's bloom for that column.
#   col IN (...)            -> kept iff ANY listed value MIGHT be present.
#   anything else           -> conservative keep.


def _expr_bloom_keeps_stride(
    expr: Expr,
    col_names: List[String],
    col_kinds: List[Int],
    stride: _Stride,
) raises -> Bool:
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        if op == BIN_AND:
            ref l = expr.binary_left_ref()
            ref r = expr.binary_right_ref()
            if not _expr_bloom_keeps_stride(l, col_names, col_kinds, stride):
                return False
            return _expr_bloom_keeps_stride(r, col_names, col_kinds, stride)
        if op == BIN_OR:
            ref l = expr.binary_left_ref()
            ref r = expr.binary_right_ref()
            if _expr_bloom_keeps_stride(l, col_names, col_kinds, stride):
                return True
            return _expr_bloom_keeps_stride(r, col_names, col_kinds, stride)
        if op == BIN_EQ:
            return _eq_bloom_keeps_stride(expr, col_names, col_kinds, stride)
        # Non-equality binary op: bloom does not apply -> conservative keep.
        return True
    if expr.tag == EXPR_IN_LIST:
        return _in_bloom_keeps_stride(expr, col_names, col_kinds, stride)
    # Non-binary, non-IN node -> conservative keep.
    return True


def _eq_bloom_keeps_stride(
    expr: Expr,
    col_names: List[String],
    col_kinds: List[Int],
    stride: _Stride,
) raises -> Bool:
    """`col = lit` / `lit = col` against THIS stride's bloom for that column."""
    ref left = expr.binary_left_ref()
    ref right = expr.binary_right_ref()
    var ltag = left.tag
    var rtag = right.tag

    if ltag == EXPR_COL_REF and rtag == EXPR_LITERAL:
        var col = _output_col_index(col_names, left.col_ref_name())
        if col < 0:
            return True
        return _bloom_leaf_keeps(stride, col, col_kinds[col], right.literal_value())
    if rtag == EXPR_COL_REF and ltag == EXPR_LITERAL:
        var col = _output_col_index(col_names, right.col_ref_name())
        if col < 0:
            return True
        return _bloom_leaf_keeps(stride, col, col_kinds[col], left.literal_value())
    # col-op-col / cast etc -> conservative keep.
    return True


def _in_bloom_keeps_stride(
    expr: Expr,
    col_names: List[String],
    col_kinds: List[Int],
    stride: _Stride,
) raises -> Bool:
    """`col IN (v0, v1, ...)` -> kept iff ANY listed value might be present."""
    ref child = expr.in_list_child_ref()
    if child.tag != EXPR_COL_REF:
        return True
    var col = _output_col_index(col_names, child.col_ref_name())
    if col < 0:
        return True
    ref values = expr.in_list_values_ref()
    if len(values) == 0:
        return True
    for i in range(len(values)):
        if _bloom_leaf_keeps(stride, col, col_kinds[col], values[i]):
            return True
    # Every listed value proven absent by the bloom -> safe to skip.
    return False


def _bloom_leaf_keeps(
    stride: _Stride, col: Int, kind: Int, lit: ScalarValue
) raises -> Bool:
    """Probe `stride`'s bloom for output column `col` with literal `lit`. Returns
    True (keep) unless the bloom PROVES the value absent. Any unusable-bloom /
    type-mismatch case degrades to keep."""
    if col >= len(stride.col_has_bloom) or not stride.col_has_bloom[col]:
        return True  # no usable bloom -> cannot disprove -> keep
    ref entry = stride.col_blooms[col]
    if not entry.has_utf8bitset or len(entry.utf8bitset) == 0:
        return True
    var bf = OrcBloomFilter(entry.num_hash_functions, entry.utf8bitset.copy())

    # Dispatch the probe by the column's ORC type so the hash kernel matches the
    # one the writer used (Wang64 for ints, Wang64-double for float/double,
    # Murmur3 for strings).
    if (
        kind == ORC_KIND_BYTE
        or kind == ORC_KIND_SHORT
        or kind == ORC_KIND_INT
        or kind == ORC_KIND_LONG
        or kind == ORC_KIND_DATE
    ):
        if not lit.is_int():
            return True
        return bf.test_long(lit.int_val)
    elif kind == ORC_KIND_FLOAT or kind == ORC_KIND_DOUBLE:
        if lit.is_float():
            return bf.test_double(lit.float_val)
        if lit.is_int():
            return bf.test_double(Float64(lit.int_val))
        return True
    elif kind == ORC_KIND_STRING:
        if not lit.is_string():
            return True
        return bf.test_string(lit.string_val)
    # Other kinds -> no bloom semantics -> keep.
    return True


# =============================================================================
# Build the per-file stride table from the stripe ROW_INDEX streams.
# =============================================================================


def _stripe_footer_for(
    file_bytes: Span[UInt8, _],
    stripe: StripeInformation,
    codec: Int,
    block_size: Int,
) raises -> StripeFooter:
    _checked_file_span(
        len(file_bytes),
        stripe.stripe_footer_start(),
        stripe.stripe_footer_end(),
        "stripe footer (stride-skip)",
    )
    var sf_raw = file_bytes[
        stripe.stripe_footer_start() : stripe.stripe_footer_end()
    ]
    var sf_bytes = decompress_stream(sf_raw, codec, block_size)
    return StripeFooter.parse(sf_bytes)


# =============================================================================
# ⚠ ONE VALIDATED STREAM WALK, NOT THREE.
# =============================================================================
#
# `_find_row_index_bytes` and `_find_bloom_filter_index` must not carry their
# OWN hand-written copy of the `off += s.length` cumulative walk that
# `orc_reader._locate_streams` does. A copy that slices `file_bytes[start:end]`
# on unvalidated writer-chosen lengths stays exposed when another copy is
# hardened, and every copy is a chance for the next person to add another.
#
# Both delegate to the single VALIDATED `_locate_streams`, which bounds each
# span against the file. The walk runs once per (stripe, column) probe, not per
# row, so materializing the full location list costs nothing measurable and buys
# one place where the check has to be right.


def _find_row_index_bytes(
    file_bytes: Span[UInt8, _],
    sf: StripeFooter,
    stripe: StripeInformation,
    col_id: Int,
    codec: Int,
    block_size: Int,
) raises -> OrcRowIndex:
    """Locate + decompress + parse the ROW_INDEX stream for `col_id`. Returns an
    empty RowIndex when the column has no ROW_INDEX stream."""
    var locs = _locate_streams(sf, stripe, len(file_bytes))
    for i in range(len(locs)):
        var loc = locs[i].copy()
        if loc.kind == ORC_STREAM_ROW_INDEX and loc.column == col_id:
            var raw = file_bytes[loc.start : loc.end]
            var decompressed = decompress_stream(raw, codec, block_size)
            return OrcRowIndex.parse(Span(decompressed))
    return OrcRowIndex()


def _find_bloom_filter_index(
    file_bytes: Span[UInt8, _],
    sf: StripeFooter,
    stripe: StripeInformation,
    col_id: Int,
    codec: Int,
    block_size: Int,
) raises -> OrcBloomFilterIndex:
    """Locate + decompress + parse the BLOOM_FILTER_UTF8 stream for `col_id`.
    Returns an empty BloomFilterIndex when the column has no usable bloom stream
    (so the cascade degrades to all-pass for that column — never a false-skip)."""
    var locs = _locate_streams(sf, stripe, len(file_bytes))
    for i in range(len(locs)):
        var loc = locs[i].copy()
        if loc.kind == ORC_STREAM_BLOOM_FILTER_UTF8 and loc.column == col_id:
            var raw = file_bytes[loc.start : loc.end]
            var decompressed = decompress_stream(raw, codec, block_size)
            return OrcBloomFilterIndex.parse(Span(decompressed))
    return OrcBloomFilterIndex()


def _build_stride_table(
    file_bytes: Span[UInt8, _],
    tail: OrcFileTail,
    schema: OrcSchema,
    col_node_ids: List[Int],
    codec: Int,
    block_size: Int,
) raises -> List[_Stride]:
    """Walk every stripe's ROW_INDEX + BLOOM_FILTER_UTF8 streams into a flat
    per-file stride table (stats = cascade level 3, bloom = level 4).

    A stripe with NO ROW_INDEX produces ONE all-stripe stride (no stats, no
    bloom) so the cascade degrades to whole-stripe (conservative keep)."""
    var strides = List[_Stride]()
    var file_row = 0
    for s in range(tail.footer.num_stripes()):
        var stripe = tail.footer.stripes[s].copy()
        var sf = _stripe_footer_for(file_bytes, stripe, codec, block_size)

        # Parse each output column's RowIndex + BloomFilterIndex for this stripe.
        var per_col = List[OrcRowIndex]()
        var per_col_bloom = List[OrcBloomFilterIndex]()
        var n_strides_in_stripe = 0
        for c in range(len(col_node_ids)):
            var ri = _find_row_index_bytes(
                file_bytes, sf, stripe, col_node_ids[c], codec, block_size
            )
            if len(ri.entries) > n_strides_in_stripe:
                n_strides_in_stripe = len(ri.entries)
            per_col.append(ri^)
            var bi = _find_bloom_filter_index(
                file_bytes, sf, stripe, col_node_ids[c], codec, block_size
            )
            per_col_bloom.append(bi^)

        if n_strides_in_stripe == 0:
            # No ROW_INDEX: one stride covering the whole stripe, no stats/bloom.
            var stride = _Stride(file_row, stripe.number_of_rows)
            for _c in range(len(col_node_ids)):
                stride.col_stats.append(OrcColumnStatistics())
                stride.col_has_bloom.append(False)
                stride.col_blooms.append(OrcBloomFilterEntry())
            strides.append(stride^)
            file_row += stripe.number_of_rows
            continue

        # The writer's stride size = footer.row_index_stride. Derive per-stride
        # row counts (the last stride may be short).
        var stride_size = tail.footer.row_index_stride
        if stride_size <= 0:
            stride_size = stripe.number_of_rows
        var consumed = 0
        for k in range(n_strides_in_stripe):
            var rc = stripe.number_of_rows - consumed
            if rc > stride_size:
                rc = stride_size
            if rc < 0:
                rc = 0
            var stride = _Stride(file_row + consumed, rc)
            for c in range(len(col_node_ids)):
                if k < len(per_col[c].entries):
                    stride.col_stats.append(
                        per_col[c].entries[k].statistics.copy()
                    )
                else:
                    stride.col_stats.append(OrcColumnStatistics())
                # Per-stride bloom: only present if the column has a bloom index
                # AND it has an entry for stride k AND that entry has utf8bitset.
                if (
                    k < len(per_col_bloom[c].entries)
                    and per_col_bloom[c].entries[k].has_utf8bitset
                ):
                    stride.col_has_bloom.append(True)
                    stride.col_blooms.append(per_col_bloom[c].entries[k].copy())
                else:
                    stride.col_has_bloom.append(False)
                    stride.col_blooms.append(OrcBloomFilterEntry())
            strides.append(stride^)
            consumed += rc
        file_row += stripe.number_of_rows
    return strides^


# =============================================================================
# Public: stride-skipping ORC read.
# =============================================================================


def read_orc_bytes_filtered(
    file_bytes: Span[UInt8, _], predicate: Expr
) raises -> OrcFilteredResult:
    """Decode an ORC file, skipping strides proven disjoint from `predicate`.

    Returns the rows in SURVIVING strides only (a superset of the predicate-
    matching rows — caller applies any row-level filter). `strides_skipped` is
    the count of strides proven non-matching by the per-stride min/max stats."""
    var tail = _parse_tail_codec_aware(file_bytes)
    var schema = OrcSchema.from_types(tail.footer.types.copy())
    var codec = tail.post_script.compression
    var block_size = tail.post_script.compression_block_size

    var root = schema.node(0)
    if root.kind != ORC_KIND_STRUCT:
        raise Error(
            "OrcDecodeError.ROOT_NOT_STRUCT: stride-skip read needs a top-level"
            " struct"
        )

    # Output columns = root struct's direct children (the same projection the
    # whole-file reader uses).
    var col_node_ids = List[Int]()
    var col_names = List[String]()
    var col_kinds = List[Int]()
    for i in range(len(root.subtypes)):
        col_node_ids.append(root.subtypes[i])
        col_kinds.append(schema.node(root.subtypes[i]).kind)
        if i < len(root.field_names):
            col_names.append(root.field_names[i])
        else:
            col_names.append(String("_col") + String(i))

    var strides = _build_stride_table(
        file_bytes, tail, schema, col_node_ids, codec, block_size
    )

    # Evaluate the predicate against each stride -> keep mask. A stride survives
    # iff BOTH cascade levels keep it: level 3 (stride min/max stats)
    # AND level 4 (stride bloom on equality/IN predicates). Both are
    # conservative-keep, so AND-composition can only ADD skips — never falsely
    # skip a stride that might contain a matching row.
    var keep = List[Bool]()
    var skipped = 0
    for i in range(len(strides)):
        var stats_keep = _expr_keeps_stride(predicate, col_names, strides[i])
        var k = stats_keep
        if stats_keep:
            var bloom_keep = _expr_bloom_keeps_stride(
                predicate, col_names, col_kinds, strides[i]
            )
            k = bloom_keep
        keep.append(k)
        if not k:
            skipped += 1

    # Decode the whole file, then drop skipped-stride rows.
    var full = read_orc_bytes(file_bytes)

    if skipped == 0:
        return OrcFilteredResult(full^, len(strides), 0)

    # Build the surviving-row index list from the keep mask.
    var keep_rows = List[Int]()
    for i in range(len(strides)):
        if keep[i]:
            var st = strides[i].copy()
            for r in range(st.row_start, st.row_start + st.row_count):
                keep_rows.append(r)

    var filtered = gather_batch(full, keep_rows)
    return OrcFilteredResult(filtered^, len(strides), skipped)


# =============================================================================
# Cascade levels 1-2: column-projection + stripe-stats prune.
# =============================================================================
#
# These are the two COARSEST scan-side skip levels — they sit ABOVE
# stride-stats:
#
#   (1) column-projection — decode only the referenced leaf columns. Wired
#       through `read_orc_bytes_projected` in orc_reader.mojo; here it threads a
#       projection list into the per-stripe decode so a pruned read also pays to
#       decode only the projected columns.
#   (2) stripe-stats prune — before decoding a stripe, evaluate the predicate
#       against the stripe's footer-`Metadata` ColumnStatistics (the SAME
#       per-stripe min/max the stride path trusts at finer granularity)
#       and SKIP whole stripes proven disjoint. A pruned stripe is never
#       decoded — a real decode-work saving, not a post-decode row drop.
#
# Conservative: any unsupported predicate shape, missing stat, or absent
# Metadata blob => keep the stripe (never a false-skip). So the surviving rows
# are byte-equal to a full scan, making `read_orc_bytes` a valid oracle.


struct OrcPrunedResult(Movable):
    """Result of a stripe-pruning (+ optionally projected) ORC read.

    Fields:
        batch:           Arrow RecordBatch of rows in SURVIVING stripes only,
                         containing only the projected columns.
        stripes_total:   Total stripes in the file.
        stripes_skipped: Stripes proven predicate-disjoint and never decoded.
    """

    var batch: RecordBatch
    var stripes_total: Int
    var stripes_skipped: Int

    def __init__(
        out self,
        var batch: RecordBatch,
        stripes_total: Int,
        stripes_skipped: Int,
    ):
        self.batch = batch^
        self.stripes_total = stripes_total
        self.stripes_skipped = stripes_skipped


def _parse_stripe_stats(
    file_bytes: Span[UInt8, _],
    tail: OrcFileTail,
    codec: Int,
    block_size: Int,
) raises -> Metadata:
    """Locate + decompress + parse the file `Metadata` blob (per-stripe stats).
    Returns an empty `Metadata` when the blob is absent (then the prune degrades
    to keep-all)."""
    if tail.metadata_end <= tail.metadata_start:
        return Metadata()
    var raw = file_bytes[tail.metadata_start : tail.metadata_end]
    # The Metadata blob is chunk-framed + codec-compressed (NONE => identity).
    var decompressed = decompress_stream(raw, codec, block_size)
    return Metadata.parse(Span(decompressed))


def _stripe_keeps(
    predicate: Expr,
    col_names: List[String],
    col_node_ids: List[Int],
    stripe_stats: OrcStripeStatistics,
) raises -> Bool:
    """Evaluate `predicate` against ONE stripe's stats via the `_expr_keeps_*`
    Expr-walk (reused at stripe granularity). Builds a synthetic `_Stride` whose
    `col_stats` is ordered by OUTPUT column (mapping output col -> node id ->
    the stripe's ColumnStatistics). A missing stat => empty stats => keep."""
    var st = _Stride(0, 0)
    for c in range(len(col_node_ids)):
        var node = col_node_ids[c]
        if node >= 0 and node < len(stripe_stats.col_stats):
            st.col_stats.append(stripe_stats.col_stats[node].copy())
        else:
            st.col_stats.append(OrcColumnStatistics())
        # No bloom at stripe granularity (bloom is per-stride).
        st.col_has_bloom.append(False)
        st.col_blooms.append(OrcBloomFilterEntry())
    return _expr_keeps_stride(predicate, col_names, st)


def read_orc_bytes_pruned(
    file_bytes: Span[UInt8, _],
    predicate: Expr,
    projection: List[Int],
) raises -> OrcPrunedResult:
    """Decode an ORC file with cascade levels 1-2: column-projection +
    stripe-stats prune.

    `projection` is the list of output-column indices (into the root struct's
    direct children, caller order); EMPTY => all columns. Stripes proven
    disjoint from `predicate` by their per-stripe min/max stats are skipped
    (never decoded). Surviving stripes' projected columns are accumulated in
    order into one RecordBatch.

    Composes ABOVE stride skip: a caller wanting the full cascade applies stride-
    skip / stride-bloom (read_orc_bytes_filtered) on the surviving rows."""
    var tail = _parse_tail_codec_aware(file_bytes)
    var schema = OrcSchema.from_types(tail.footer.types.copy())
    var codec = tail.post_script.compression
    var block_size = tail.post_script.compression_block_size

    var root = schema.node(0)
    if root.kind != ORC_KIND_STRUCT:
        raise Error(
            "OrcDecodeError.ROOT_NOT_STRUCT: pruned read needs a top-level"
            " struct"
        )

    # Resolve projection -> child positions, then output node ids + names.
    var child_positions = _resolve_projection(schema, projection)
    var out_schema = _build_output_schema(schema, child_positions)
    var n_cols = len(child_positions)
    var col_node_ids = List[Int]()
    var col_names = List[String]()
    for j in range(n_cols):
        var pos = child_positions[j]
        var node = root.subtypes[pos]
        col_node_ids.append(node)
        if pos < len(root.field_names):
            col_names.append(root.field_names[pos])
        else:
            col_names.append(String("_col") + String(pos))

    # Per-stripe stats from the Metadata blob (empty => keep all stripes).
    var meta = _parse_stripe_stats(file_bytes, tail, codec, block_size)

    var n_stripes = tail.footer.num_stripes()

    # One accumulator per projected output column, appended across surviving
    # stripes (mirrors the whole-file accumulator; skipped stripes never decode).
    var accs = Slab[ColumnAcc]()
    for j in range(n_cols):
        var node = col_node_ids[j]
        var child = schema.node(node)
        var at = orc_node_to_arrow(schema, node)
        accs.append(make_accumulator(child.kind, at))

    var skipped = 0
    for s in range(n_stripes):
        # Stripe-stats prune: skip the whole stripe if proven disjoint.
        if s < len(meta.per_stripe_stats):
            var keep = _stripe_keeps(
                predicate, col_names, col_node_ids, meta.per_stripe_stats[s]
            )
            if not keep:
                skipped += 1
                continue

        var stripe = tail.footer.stripes[s].copy()
        _checked_file_span(
            len(file_bytes),
            stripe.stripe_footer_start(),
            stripe.stripe_footer_end(),
            "stripe " + String(s) + " footer (stride-skip)",
        )
        var sf_raw = file_bytes[
            stripe.stripe_footer_start() : stripe.stripe_footer_end()
        ]
        var sf_bytes = decompress_stream(sf_raw, codec, block_size)
        var sf = StripeFooter.parse(sf_bytes)
        var locs = _locate_streams(sf, stripe, len(file_bytes))

        for j in range(n_cols):
            var node = col_node_ids[j]
            var child = schema.node(node)
            if node >= len(sf.columns):
                raise Error(
                    "OrcDecodeError.MISSING_ENCODING: column id "
                    + String(node)
                    + " has no ColumnEncoding entry"
                )
            var encoding = sf.columns[node].copy()
            var col_streams = _gather_column_streams(
                locs, file_bytes, node, codec, block_size
            )
            decode_stripe_column(
                accs[j],
                child.kind,
                encoding.kind,
                encoding.dictionary_size,
                col_streams,
                stripe.number_of_rows,
            )

    var builder = RecordBatchBuilder.with_capacity(n_cols)
    for j in range(n_cols):
        var acc = accs.take_slot_unchecked(j)
        builder.add_column(acc^.build())
    # SAFETY CONTRACT (Slab.take_slot_unchecked): every slot has been moved out
    # and is now uninitialized; mark the slab empty so its destructor does NOT
    # destroy the moved-out slots (mirrors orc_reader._read_orc_bytes_core).
    accs.set_len_unchecked(0)
    var batch = builder.build(out_schema.copy())
    return OrcPrunedResult(batch^, n_stripes, skipped)
