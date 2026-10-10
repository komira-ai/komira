# =============================================================================
# komira_search/split.mojo
#   The immutable split CONTAINER (serialize + parse) + the inline
#   posting-block codec + the minimal doc-store.
# =============================================================================
#
# Upstream contract: komira_search/{inverted,term_dict}.mojo (the inverted
# index's FinalizedIndex + the TermDictionary). Downstream contract:
# SearchCore (the searcher) reads this container footer-first.
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE OWNS (PURE, S3-FREE, unit-testable)
# -----------------------------------------------------------------------------
#   * The FROZEN inline 128-doc posting-block codec: _encode_posting_list
#     / _decode_posting_list + the LSB-first bitpack helpers
#     (_pack_bits_lsb_first / _unpack_bits_lsb_first / _min_bit_width). This is
#     the SearchCore DECODE CONTRACT — the byte layout is frozen here.
#   * DocStoreBuilder — accumulates per-doc UNCOMPRESSED _source blobs during
#     ingest; serializes the minimal doc-store region. One-copy
#     append over a Span[UInt8]. Dense-ascending precondition asserted.
#   * serialize_split — the SINGLE patch-pass owner: writes the posting
#     region + set_posting_location per ordinal + term_dict.serialize EXACTLY
#     ONCE, then assembles magic + header-meta + termdict + postings + docstore
#     + footer (footer LAST). PURE: no S3, no file I/O, no global state.
#   * SplitView.parse — the footer-first reader stub (fail-loud bounds
#     validation). SearchCore builds the BM25 posting walk on this same
#     footer-first surface.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION / SAFETY (owner self-audit)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY public (or private) signature.
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * DocStoreBuilder is all POD List[UInt8] / List[Int]; SplitView owns a
#     List[UInt8] and returns Spans tied to the INNER field
#     (origin_of(self._bytes)) — the same idiom as FinalizedIndex /
#     TermDictionary. NO Slab, NO heap-owning slab element, NO wildcard origin.
#     split_uuid is InlineArray[UInt8, 16]: no heap, no move-corruption
#     surface.
# =============================================================================

from komira_buffer.byte_buffer import ByteBuffer, write_uleb128
from komira_compression.lz4 import lz4_compress, lz4_decompress

from .inverted import FinalizedIndex
from .term_dict import TermDictionary


# =============================================================================
# Container constants (FROZEN — the SearchCore contract).
# =============================================================================

comptime SPLIT_MAGIC_LEN: Int = 8
"""'THSPLIT' (7 ASCII) + version byte. Validated FIRST."""

comptime SPLIT_VERSION: UInt8 = 1
"""Format version. The literal 8-byte prefix is "THSPLIT\\x01"."""

comptime FOOTER_MAGIC_LEN: Int = 4
"""'THSF' footer sentinel — appears at footer start AND at EOF."""

comptime FOOTER_VERSION: UInt8 = 1
"""Footer schema version. Every reader parses the SAME footer (reserved slots).

ADDITIVE-EXTENSIBILITY CONTRACT (do NOT bump for additive trailing slots): the
footer body is self-delimiting via the trailing `footer_len` u32, so a NEW
writer may APPEND extra u64 slots after the last known slot and an OLD reader
(which stops after the slots it knows) ignores them. The reader detects a NEW
trailing slot by checking `cur.remaining() >= 8` after the known slots — present
=> read it, absent => the split predates the slot (graceful degrade). Bump
FOOTER_VERSION only for a NON-additive layout change."""

comptime FOOTER_NO_TOTAL_TOKENS: Int = -1
"""Sentinel for serialize_split's `total_token_count` param: the caller did not
supply a per-split total token count, so the footer omits the
`total_token_count` slot (an older footer shape). Readers fall back to the
O(doc_count) column-sum path."""

comptime POSTING_BLOCK_DOCS: Int = 128
"""Docs per posting block. The unit the split writer slices + SearchCore decodes."""

comptime BLOCKMAX_VERSION: UInt8 = 1
"""WAND Phase 2 (BMW) BLOCKMAX-region schema version. The region is an ADDITIVE,
optional trailing region (footer slot 0/0 = absent; an OLD reader ignores it, a
NEW reader uses it, the scorer FALLS BACK to Phase-1 term-max WAND / brute on an
old split). Bump only for a NON-additive BLOCKMAX layout change. The layout
is two-tier (see `_serialize_blockmax_region`)."""

comptime DOCSTORE_FLAG_UNCOMPRESSED: UInt8 = 0
"""Doc-store `compressed_flag` value: blob_area holds verbatim UNCOMPRESSED
blobs (an uncompressed split). The reader returns blobs verbatim."""

comptime DOCSTORE_FLAG_LZ4: UInt8 = 1
"""Doc-store `compressed_flag` value: blob_area holds per-blob LZ4 RAW-BLOCK
compressed bytes; `uncompressed_len[i]` is the original size the reader passes
to lz4_decompress. A storage win (the `_source` blobs are most of a split's
bytes and JSON compresses well). Backward-compatible: a 0-flag split still reads
verbatim, distinguished by the flag byte (the split writer reserved it)."""


# =============================================================================
# The inline LSB-first bitpack codec (small, no Parquet dependency).
# =============================================================================


@always_inline
def _min_bit_width(max_value: Int) -> Int:
    """Smallest bit width that can represent `max_value` (>= 0). Returns 0 for
    max_value == 0 (an all-zero column needs zero residual bytes). For
    max_value > 0, the number of significant bits.

    Examples: 0 -> 0, 1 -> 1, 2 -> 2, 3 -> 2, 255 -> 8, 256 -> 9.
    """
    if max_value <= 0:
        return 0
    var w = 0
    var v = max_value
    while v > 0:
        w += 1
        v = v >> 1
    return w


@always_inline
def _packed_byte_count(count: Int, bit_width: Int) -> Int:
    """Number of bytes a `count`-value bitpacked run at `bit_width` occupies:
    ceil(count * bit_width / 8). Zero when bit_width == 0 (the width-0 case)."""
    return (count * bit_width + 7) >> 3


def _pack_bits_lsb_first(
    values: Span[Int, _], count: Int, bit_width: Int, mut out: List[UInt8]
) raises:
    """Append the LSB-first bitpacking of `values[0:count]` at `bit_width` bits
    each to `out`. Bit 0 of value 0 is the LSB of the first emitted byte; bits
    fill toward the MSB, then spill into the next byte. width==0 emits ZERO
    bytes (all values are 0 by the min-bit-width contract).

    Every value MUST be >= 0 (a negative would set high bits and corrupt the
    pack). Asserted defensively.
    """
    if bit_width == 0:
        return
    if bit_width < 0 or bit_width > 64:
        raise Error(
            "_pack_bits_lsb_first: bit_width "
            + String(bit_width)
            + " out of range [0, 64]"
        )
    var total_bytes = _packed_byte_count(count, bit_width)
    # Grow a zero-filled scratch region, then OR bits in.
    var base = len(out)
    for _ in range(total_bytes):
        out.append(0)
    var bit_pos = 0
    for i in range(count):
        var v = values[i]
        if v < 0:
            raise Error(
                "_pack_bits_lsb_first: negative value at index "
                + String(i)
                + " (bitpack requires non-negative values)"
            )
        var uv = UInt64(v)
        for b in range(bit_width):
            if (uv >> UInt64(b)) & UInt64(1) != UInt64(0):
                var abs_bit = bit_pos + b
                var byte_idx = base + (abs_bit >> 3)
                var bit_in_byte = abs_bit & 7
                out[byte_idx] = out[byte_idx] | (UInt8(1) << UInt8(bit_in_byte))
        bit_pos += bit_width


def _unpack_bits_lsb_first(
    src: Span[UInt8, _],
    src_off: Int,
    count: Int,
    bit_width: Int,
    mut out: List[Int],
) raises:
    """Append `count` values, each `bit_width` bits LSB-first, decoded from
    `src` starting at byte offset `src_off`, to `out`. The exact inverse of
    `_pack_bits_lsb_first`. width==0 appends `count` zeros (no source bytes
    consumed). Used by `_decode_posting_list` (the split writer round-trip test + the SearchCore
    decode seam).

    Raises if the packed run would read past `src` (fail-loud — the split is
    attacker-influenced at SearchCore query time).
    """
    if bit_width == 0:
        for _ in range(count):
            out.append(0)
        return
    if bit_width < 0 or bit_width > 64:
        raise Error(
            "_unpack_bits_lsb_first: bit_width "
            + String(bit_width)
            + " out of range [0, 64]"
        )
    var total_bytes = _packed_byte_count(count, bit_width)
    if src_off < 0 or src_off + total_bytes > len(src):
        raise Error(
            "_unpack_bits_lsb_first: packed run ["
            + String(src_off)
            + ", "
            + String(src_off + total_bytes)
            + ") exceeds source length "
            + String(len(src))
            + " (corrupt)"
        )
    var bit_pos = 0
    for _ in range(count):
        var v = UInt64(0)
        for b in range(bit_width):
            var abs_bit = bit_pos + b
            var byte_idx = src_off + (abs_bit >> 3)
            var bit_in_byte = abs_bit & 7
            var bit = (src[byte_idx] >> UInt8(bit_in_byte)) & UInt8(1)
            if bit != UInt8(0):
                v = v | (UInt64(1) << UInt64(b))
        out.append(Int(v))
        bit_pos += bit_width


# =============================================================================
# The posting-list encode/decode (the FROZEN SearchCore decode contract).
# =============================================================================
#
# Per-term layout (at postings_region[off .. off+len)), self-delimiting given
# doc_count (which SearchCore reads from TermInfo.doc_freq):
#
#   doc_count : ULEB128                       (== fi.doc_freq_at(ordinal))
#   for each block of up to POSTING_BLOCK_DOCS docs (last may be partial):
#     first_doc_id  : ULEB128                 (absolute doc-id of block's doc 0)
#     doc_bit_width : u8                       (width of the docs-1..count-1
#                                               delta bitpack; 0 if count==1)
#     <bitpacked doc-id deltas for docs 1..count-1, LSB-first, doc_bit_width>
#         delta[i] = doc_id[i] - doc_id[i-1]   (all >= 1, strictly ascending)
#     tf_bit_width  : u8                       (width of the TF bitpack;
#                                               0 if all TFs equal 0)
#     <bitpacked TFs for docs 0..count-1, LSB-first, tf_bit_width>
#
# Number of blocks = ceil(doc_count / POSTING_BLOCK_DOCS). The block structure
# is self-describing given doc_count (no per-block count is stored: every block
# but the last has exactly POSTING_BLOCK_DOCS docs; the last has the remainder).
# =============================================================================


def _encode_posting_list(
    doc_ids: Span[Int, _], tfs: Span[Int, _], mut out: List[UInt8]
) raises:
    """Encode one term's ascending posting list (doc_ids + parallel tfs) into
    the FROZEN block format, appending to `out`. Validates non-negativity.

    Preconditions (enforced upstream by the inverted index, re-asserted here):
      * len(doc_ids) == len(tfs).
      * doc_ids strictly ascending (so each intra-block delta >= 1).
    """
    var n = len(doc_ids)
    if n != len(tfs):
        raise Error(
            "_encode_posting_list: doc_ids/tfs length mismatch ("
            + String(n)
            + " vs "
            + String(len(tfs))
            + ")"
        )
    if n < 0:
        raise Error("_encode_posting_list: negative doc_count")  # cov: unreachable n is a len()
    write_uleb128(n, out)
    var pos = 0
    while pos < n:
        var block_count = POSTING_BLOCK_DOCS
        if n - pos < block_count:
            block_count = n - pos

        # ---- doc-id sub-block: absolute first + bitpacked deltas (1..) ----
        var first_doc = doc_ids[pos]
        if first_doc < 0:
            raise Error(
                "_encode_posting_list: negative doc_id at index " + String(pos)
            )
        write_uleb128(first_doc, out)

        var deltas = List[Int]()
        var max_delta = 0
        for i in range(1, block_count):
            var prev = doc_ids[pos + i - 1]
            var cur = doc_ids[pos + i]
            var d = cur - prev
            if d <= 0:
                raise Error(
                    "_encode_posting_list: non-ascending doc-ids at index "
                    + String(pos + i)
                    + " (delta "
                    + String(d)
                    + " <= 0; ascending-by-construction invariant violated)"
                )
            deltas.append(d)
            if d > max_delta:
                max_delta = d
        var doc_bw = _min_bit_width(max_delta)
        out.append(UInt8(doc_bw))
        _pack_bits_lsb_first(Span(deltas), len(deltas), doc_bw, out)

        # ---- TF sub-block: bitpacked, no delta ----
        var tf_block = List[Int]()
        var max_tf = 0
        for i in range(block_count):
            var t = tfs[pos + i]
            if t < 0:
                raise Error(
                    "_encode_posting_list: negative tf at index "
                    + String(pos + i)
                )
            tf_block.append(t)
            if t > max_tf:
                max_tf = t
        var tf_bw = _min_bit_width(max_tf)
        out.append(UInt8(tf_bw))
        _pack_bits_lsb_first(Span(tf_block), block_count, tf_bw, out)

        pos += block_count


def _encode_posting_list_with_blockmeta(
    doc_ids: Span[Int, _],
    tfs: Span[Int, _],
    token_counts: Span[Int, _],
    min_doc_id: Int,
    mut out: List[UInt8],
    mut block_byte_offset: List[Int],
    mut block_last_docid: List[Int],
    mut block_max_tf: List[Int],
    mut block_min_dl: List[Int],
) raises -> Int:
    """WAND Phase 2 (BMW) twin of `_encode_posting_list`: emits the EXACT SAME
    FROZEN byte layout into `out` (so a split's posting bytes are byte-identical
    whether or not BLOCKMAX is captured), while ALSO appending per-block metadata
    needed by the BMW skip-list. Returns the number of blocks appended.

    Per-block metadata appended (one entry per 128-doc block, in block order):
      * block_byte_offset[b]: the byte offset of block `b`'s start RELATIVE to the
        start of THIS term's posting region (i.e. relative to where `out` was when
        this call began, AFTER the doc_count ULEB). Lets the BMW cursor LAND on a
        block without decoding the intervening blocks — the block-skip destination.
      * block_last_docid[b]: the LARGEST doc-id in block `b` (the skip-list
        ceiling; lets the pivot loop decide WHETHER to skip a block).
      * block_max_tf[b]: the max tf over the block's docs (already folded by the
        codec to pick tf_bw — retained instead of discarded).
      * block_min_dl[b]: the MINIMUM `dl` (token count) over the block's docs,
        clamped >= 0. `token_counts` is dense per-slot (slot = doc_id-min_doc_id).
        A missing/zero cell reads dl=0 (the smallest dl), which is the MOST
        favorable for the upper bound (f decreases in dl) -> the bound rounds UP
        over the scorer's per-doc norm=1.0 degrade. The block bound at query time
        is `idf * f(block_max_tf, block_min_dl)` via the SAME bm25_score_contribution
        the scorer uses — a TRUE upper bound on every doc in the
        block.

    Preconditions (same as _encode_posting_list + the dense token_counts):
      * len(doc_ids) == len(tfs).
      * doc_ids strictly ascending.
      * token_counts[doc_id - min_doc_id] is the per-doc dl (len >= max slot+1).
    """
    var n = len(doc_ids)
    if n != len(tfs):
        raise Error(
            "_encode_posting_list_with_blockmeta: doc_ids/tfs length mismatch ("
            + String(n)
            + " vs "
            + String(len(tfs))
            + ")"
        )
    if n < 0:
        raise Error("_encode_posting_list_with_blockmeta: negative doc_count")  # cov: unreachable n is a len()
    write_uleb128(n, out)
    # Block byte offsets are RELATIVE to the start of the per-block run (the byte
    # just AFTER the doc_count ULEB), matching how the BMW cursor seeks: it reads
    # doc_count first, then lands on a block at `region_off + block_data_base +
    # block_byte_offset[b]` where block_data_base is the post-doc_count cursor.
    var block_data_base = len(out)
    var pos = 0
    var n_blocks = 0
    while pos < n:
        var block_count = POSTING_BLOCK_DOCS
        if n - pos < block_count:
            block_count = n - pos

        # Record this block's start byte offset (relative to block_data_base).
        block_byte_offset.append(len(out) - block_data_base)

        # ---- doc-id sub-block: absolute first + bitpacked deltas (1..) ----
        var first_doc = doc_ids[pos]
        if first_doc < 0:
            raise Error(
                "_encode_posting_list_with_blockmeta: negative doc_id at index "
                + String(pos)
            )
        write_uleb128(first_doc, out)

        var deltas = List[Int]()
        var max_delta = 0
        for i in range(1, block_count):
            var prev = doc_ids[pos + i - 1]
            var cur = doc_ids[pos + i]
            var d = cur - prev
            if d <= 0:
                raise Error(
                    "_encode_posting_list_with_blockmeta: non-ascending doc-ids"
                    " at index "
                    + String(pos + i)
                )
            deltas.append(d)
            if d > max_delta:
                max_delta = d
        var doc_bw = _min_bit_width(max_delta)
        out.append(UInt8(doc_bw))
        _pack_bits_lsb_first(Span(deltas), len(deltas), doc_bw, out)

        # The block's LAST doc-id (the skip ceiling).
        block_last_docid.append(doc_ids[pos + block_count - 1])

        # ---- TF sub-block: bitpacked, no delta ----
        var tf_block = List[Int]()
        var max_tf = 0
        for i in range(block_count):
            var t = tfs[pos + i]
            if t < 0:
                raise Error(
                    "_encode_posting_list_with_blockmeta: negative tf at index "
                    + String(pos + i)
                )
            tf_block.append(t)
            if t > max_tf:
                max_tf = t
        var tf_bw = _min_bit_width(max_tf)
        out.append(UInt8(tf_bw))
        _pack_bits_lsb_first(Span(tf_block), block_count, tf_bw, out)

        block_max_tf.append(max_tf)

        # The block's MINIMUM dl (token count) over its docs, clamped >= 0. A doc
        # whose slot is missing from token_counts (defensive) reads dl=0 (the most
        # favorable for the upper bound, so the bound still rounds up).
        var min_dl = -1
        for i in range(block_count):
            var slot = doc_ids[pos + i] - min_doc_id
            var dl = 0
            if slot >= 0 and slot < len(token_counts):
                dl = token_counts[slot]
                if dl < 0:
                    dl = 0
            if min_dl < 0 or dl < min_dl:
                min_dl = dl
        if min_dl < 0:
            min_dl = 0
        block_min_dl.append(min_dl)

        pos += block_count
        n_blocks += 1
    return n_blocks


def _decode_posting_list(
    src: Span[UInt8, _],
    region_off: Int,
    region_len: Int,
    mut out_doc_ids: List[Int],
    mut out_tfs: List[Int],
) raises:
    """Decode one term's posting list from `src[region_off .. region_off+
    region_len)` back into ascending doc-ids + parallel tfs. The exact inverse
    of `_encode_posting_list` — the reusable SearchCore decode helper + the split writer
    round-trip test. Fail-loud bounds validation throughout.
    """
    if region_off < 0 or region_len < 0 or region_off + region_len > len(src):
        raise Error(
            "_decode_posting_list: region ["
            + String(region_off)
            + ", "
            + String(region_off + region_len)
            + ") out of bounds [0, "
            + String(len(src))
            + ")"
        )
    # A cursor over the term's own byte range (relative reads, absolute checks).
    var cur = region_off
    var end = region_off + region_len

    # ---- doc_count : ULEB128 (hand-decoded so we stay span-relative) ----
    var dc_res = _read_uleb128_span(src, cur, end)
    var doc_count = dc_res[0]
    cur = dc_res[1]
    if doc_count < 0:
        raise Error("_decode_posting_list: negative doc_count (corrupt)")

    var decoded = 0
    while decoded < doc_count:
        var block_count = POSTING_BLOCK_DOCS
        if doc_count - decoded < block_count:
            block_count = doc_count - decoded

        # ---- doc-id sub-block ----
        var fd_res = _read_uleb128_span(src, cur, end)
        var first_doc = fd_res[0]
        cur = fd_res[1]
        if first_doc < 0:
            raise Error("_decode_posting_list: negative first_doc (corrupt)")
        if cur >= end:
            raise Error("_decode_posting_list: truncated before doc_bit_width")
        var doc_bw = Int(src[cur])
        cur += 1
        var n_deltas = block_count - 1
        var deltas = List[Int]()
        _unpack_bits_lsb_first(src, cur, n_deltas, doc_bw, deltas)
        cur += _packed_byte_count(n_deltas, doc_bw)
        # reconstruct absolute doc-ids
        var running = first_doc
        out_doc_ids.append(running)
        for i in range(n_deltas):
            running += deltas[i]
            out_doc_ids.append(running)

        # ---- TF sub-block ----
        if cur >= end:
            raise Error("_decode_posting_list: truncated before tf_bit_width")
        var tf_bw = Int(src[cur])
        cur += 1
        _unpack_bits_lsb_first(src, cur, block_count, tf_bw, out_tfs)
        cur += _packed_byte_count(block_count, tf_bw)

        decoded += block_count


def _decode_posting_block(
    src: Span[UInt8, _],
    region_off: Int,
    region_len: Int,
    block_data_base_rel: Int,
    block_byte_off: Int,
    block_count: Int,
    mut out_doc_ids: List[Int],
    mut out_tfs: List[Int],
) raises:
    """WAND Phase 2 (BMW): decode ONE 128-doc posting block in place, WITHOUT
    decoding the blocks before it. `block_byte_off` is the block's start RELATIVE
    to the term's post-doc_count base (== `_encode_posting_list_with_blockmeta`'s
    recorded `block_byte_offset[b]`); `block_data_base_rel` is the byte offset of
    that base RELATIVE to `region_off` (the cursor position after the doc_count
    ULEB). `block_count` is the number of docs in THIS block (the BLOCKMAX tier-1
    num_blocks + doc_freq determine it: every block but the last is full).

    This is the block-skip DESTINATION primitive: the BMW cursor uses the per-block
    `block_byte_offset` skip-list to LAND on a block and decode only it, so a
    skipped block pays ZERO decode (vs the strictly-sequential _decode_posting_list
    which pays O(bytes-to-landing)). The decoded doc-ids/tfs are byte-identical to
    the corresponding slice of a full _decode_posting_list. Fail-loud bounds.
    """
    if region_off < 0 or region_len < 0 or region_off + region_len > len(src):
        raise Error("_decode_posting_block: term region out of bounds")
    var end = region_off + region_len
    var cur = region_off + block_data_base_rel + block_byte_off
    if cur < region_off or cur >= end:
        raise Error("_decode_posting_block: block offset out of region")
    if block_count <= 0:
        raise Error("_decode_posting_block: non-positive block_count")

    # ---- doc-id sub-block ----
    var fd_res = _read_uleb128_span(src, cur, end)
    var first_doc = fd_res[0]
    cur = fd_res[1]
    if first_doc < 0:
        raise Error("_decode_posting_block: negative first_doc (corrupt)")
    if cur >= end:
        raise Error("_decode_posting_block: truncated before doc_bit_width")
    var doc_bw = Int(src[cur])
    cur += 1
    var n_deltas = block_count - 1
    var deltas = List[Int]()
    _unpack_bits_lsb_first(src, cur, n_deltas, doc_bw, deltas)
    cur += _packed_byte_count(n_deltas, doc_bw)
    var running = first_doc
    out_doc_ids.append(running)
    for i in range(n_deltas):
        running += deltas[i]
        out_doc_ids.append(running)

    # ---- TF sub-block ----
    if cur >= end:
        raise Error("_decode_posting_block: truncated before tf_bit_width")
    var tf_bw = Int(src[cur])
    cur += 1
    _unpack_bits_lsb_first(src, cur, block_count, tf_bw, out_tfs)


def _decode_posting_block_dids_only(
    src: Span[UInt8, _],
    region_off: Int,
    region_len: Int,
    block_data_base_rel: Int,
    block_byte_off: Int,
    block_count: Int,
    mut out_doc_ids: List[Int],
) raises:
    """WAND Phase 2 (BMW): decode ONE block's DOC-IDS only — STOP before the TF
    sub-block unpack. This is the union-merge driver: it pays the cheap delta
    unpack (needed for the exact total_matches union) but skips the TF unpack for
    blocks whose docs are never scored. A scored block re-decodes (doc-ids + tfs)
    via `_decode_posting_block` — paid only for the few above-theta blocks, so on
    long posting lists the bulk of the TF unpack work is skipped. Fail-loud."""
    if region_off < 0 or region_len < 0 or region_off + region_len > len(src):
        raise Error("_decode_posting_block_dids_only: term region out of bounds")
    var end = region_off + region_len
    var cur = region_off + block_data_base_rel + block_byte_off
    if cur < region_off or cur >= end:
        raise Error("_decode_posting_block_dids_only: block offset out of region")
    if block_count <= 0:
        raise Error("_decode_posting_block_dids_only: non-positive block_count")

    var fd_res = _read_uleb128_span(src, cur, end)
    var first_doc = fd_res[0]
    cur = fd_res[1]
    if first_doc < 0:
        raise Error("_decode_posting_block_dids_only: negative first_doc")
    if cur >= end:
        raise Error("_decode_posting_block_dids_only: truncated before doc_bw")
    var doc_bw = Int(src[cur])
    cur += 1
    var n_deltas = block_count - 1
    var deltas = List[Int]()
    _unpack_bits_lsb_first(src, cur, n_deltas, doc_bw, deltas)
    var running = first_doc
    out_doc_ids.append(running)
    for i in range(n_deltas):
        running += deltas[i]
        out_doc_ids.append(running)


def _read_uleb128_span(
    src: Span[UInt8, _], start: Int, end: Int
) raises -> Tuple[Int, Int]:
    """Decode a ULEB128 from `src` starting at `start`, bounded by `end`.
    Returns (value, next_offset). Fail-loud: raises on truncation or > 10-byte
    overflow (validate lengths ourselves; ByteBuffer.read_uleb128 SILENTLY
    truncates on overflow, which is unsafe for an attacker-influenced split)."""
    var result = 0
    var shift = 0
    var pos = start
    var nbytes = 0
    while True:
        if pos >= end:
            raise Error("_read_uleb128_span: ran past region end (corrupt)")
        var byte = Int(src[pos])
        pos += 1
        nbytes += 1
        # The 10th byte lands at bit 63: only 0x00 or 0x01 fits in 64 bits.
        if nbytes == 10 and byte > 0x01:
            if byte & 0x80 != 0:
                raise Error("_read_uleb128_span: varint exceeds 10 bytes (corrupt)")
            raise Error("_read_uleb128_span: varint overflows 64 bits (corrupt)")
        result = result | ((byte & 0x7F) << shift)
        if byte & 0x80 == 0:
            break
        shift += 7
    return (result, pos)


# =============================================================================
# DocStoreBuilder: per-doc _source blobs (minimal doc-store).
# =============================================================================


struct DocStoreBuilder(Movable, Deinitable):
    """Accumulates per-doc _source blobs during ingest; serializes the minimal
    doc-store region at flush. The `_source` blobs are most of a split's
    bytes, so the doc-store is the biggest storage-cost lever — it
    LZ4-compresses each blob at serialize. The format RESERVES the
    compressed-flag byte + per-blob uncompressed_len, so compression is purely
    additive: a NEW split sets compressed_flag = DOCSTORE_FLAG_LZ4 and stores
    LZ4-compressed blobs; an OLD split (flag 0) reads verbatim, distinguished by
    the flag byte. All-POD List substrate (clean).

    The builder always accumulates UNCOMPRESSED blobs during ingest; compression
    happens ONCE at serialize (per-blob LZ4 raw block via
    komira_compression's lz4 codec). `_compress` (default True) toggles it — set it
    False to write an uncompressed split (the backward-compat test
    path).

    Doc-store slot index = doc_id - min_doc_id is dense-only. `append`
    assigns slots in arrival order (slot i == the i-th appended doc); the
    SearchSink assigns doc_id = _next_doc_id++ (strictly increasing, dense), so
    slot i corresponds to doc_id = min_doc_id + i by construction. The dense
    invariant holds because append is the ONLY mutator and increments by one.
    """

    var _blob_area: List[UInt8]
    """Concatenated UNCOMPRESSED _source blobs (the accumulator; compression is
    applied at serialize, never here)."""
    var _blob_offset: List[Int]
    """num_docs + 1 cumulative offsets into the UNCOMPRESSED _blob_area
    (relative). [0] == 0. (At serialize, compressed splits rebuild a parallel
    compressed offset table; this one indexes the uncompressed accumulator.)"""
    var _uncompressed_len: List[Int]
    """Per-doc uncompressed byte length (the size lz4_decompress needs to
    reconstruct each blob; equals the compressed-blob slot length only when
    uncompressed)."""
    var _num_docs: Int
    var _compress: Bool
    """When True (default), serialize LZ4-compresses each blob and emits
    DOCSTORE_FLAG_LZ4; when False, emits the verbatim uncompressed
    region (DOCSTORE_FLAG_UNCOMPRESSED) for the backward-compat path."""

    def __init__(out self, compress: Bool = True):
        self._blob_area = List[UInt8]()
        self._blob_offset = List[Int]()
        self._blob_offset.append(0)  # the leading 0 (canonical form)
        self._uncompressed_len = List[Int]()
        self._num_docs = 0
        self._compress = compress

    @always_inline
    def num_docs(self) -> Int:
        return self._num_docs

    def append(mut self, source_bytes: Span[UInt8, _]) raises:
        """Append one doc's _source blob to the UNCOMPRESSED accumulator.
        Takes a Span (one-copy from the column cell). Length is non-negative
        by construction; the dense-ascending invariant holds because this
        is the only mutator and bumps _num_docs by exactly one. Compression (if
        enabled) is deferred to serialize."""
        var ln = len(source_bytes)
        if ln < 0:
            raise Error("DocStoreBuilder.append: negative source length")  # cov: unreachable ln is a len()
        for i in range(ln):
            self._blob_area.append(source_bytes[i])
        self._blob_offset.append(len(self._blob_area))
        self._uncompressed_len.append(ln)
        self._num_docs += 1

    def serialize(self, mut out: List[UInt8]) raises:
        """Emit the doc-store region into `out`:

          num_docs              : u64 LE
          compressed_flag       : u8   (0 = UNCOMPRESSED; 1 = LZ4 raw block)
          blob_offset[0..n]     : each u64 LE (n+1 entries, RELATIVE to blob area)
          uncompressed_len[0..n): each u64 LE (n entries — the ORIGINAL sizes)
          blob_area             : concatenated blobs (verbatim, or per-blob LZ4)

        When `_compress` is True, each blob is LZ4-compressed independently;
        `blob_offset` then indexes the COMPRESSED blob area and
        `uncompressed_len[i]` carries the original size the reader passes to
        lz4_decompress. An empty blob (ln == 0) compresses to an empty slot
        (lz4_compress returns []) so the reader's uncompressed_len == 0 path
        reconstructs it without an FFI call. When `_compress` is False, the
        verbatim uncompressed region is emitted (DOCSTORE_FLAG_UNCOMPRESSED)."""
        _append_u64_le(out, UInt64(self._num_docs))

        if not self._compress:
            # ---- UNCOMPRESSED region (backward-compat path). ----
            out.append(DOCSTORE_FLAG_UNCOMPRESSED)
            for i in range(len(self._blob_offset)):
                var v = self._blob_offset[i]
                if v < 0:
                    raise Error(
                        "DocStoreBuilder.serialize: negative blob_offset"
                    )
                _append_u64_le(out, UInt64(v))
            for i in range(len(self._uncompressed_len)):
                var v = self._uncompressed_len[i]
                if v < 0:
                    raise Error(
                        "DocStoreBuilder.serialize: negative uncompressed_len"
                    )
                _append_u64_le(out, UInt64(v))
            for i in range(len(self._blob_area)):
                out.append(self._blob_area[i])
            return

        # ---- LZ4-compressed region: compress each blob, rebuild offsets. ----
        out.append(DOCSTORE_FLAG_LZ4)
        var comp_area = List[UInt8]()
        var comp_offset = List[Int]()
        comp_offset.append(0)
        for slot in range(self._num_docs):
            var u_start = self._blob_offset[slot]
            var u_end = self._blob_offset[slot + 1]
            var u_len = u_end - u_start
            if u_len < 0:
                raise Error("DocStoreBuilder.serialize: negative blob length")
            if u_len == 0:
                # Empty blob: empty compressed slot (reader's uncompressed_len ==
                # 0 path reconstructs it; no FFI call). offset unchanged.
                comp_offset.append(len(comp_area))
                continue
            var blob_span = Span(self._blob_area)[u_start : u_start + u_len]
            var compressed = lz4_compress(blob_span)
            for i in range(len(compressed)):
                comp_area.append(compressed[i])
            comp_offset.append(len(comp_area))

        # blob_offset over the COMPRESSED area (n+1 entries).
        for i in range(len(comp_offset)):
            _append_u64_le(out, UInt64(comp_offset[i]))
        # uncompressed_len[i] — the ORIGINAL size (drives lz4_decompress).
        for i in range(len(self._uncompressed_len)):
            var v = self._uncompressed_len[i]
            if v < 0:
                raise Error(
                    "DocStoreBuilder.serialize: negative uncompressed_len"
                )
            _append_u64_le(out, UInt64(v))
        for i in range(len(comp_area)):
            out.append(comp_area[i])


# =============================================================================
# Little-endian scalar append helpers (private; mirror term_dict's).
# =============================================================================


@always_inline
def _append_u32_le(mut out: List[UInt8], value: UInt32):
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))


@always_inline
def _append_u64_le(mut out: List[UInt8], value: UInt64):
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))
    out.append(UInt8((value >> 32) & 0xFF))
    out.append(UInt8((value >> 40) & 0xFF))
    out.append(UInt8((value >> 48) & 0xFF))
    out.append(UInt8((value >> 56) & 0xFF))


# =============================================================================
# serialize_split: the SINGLE patch-pass owner — PURE, no S3.
# =============================================================================


def serialize_split(
    imm fi: FinalizedIndex,
    var term_dict: TermDictionary,
    imm doc_store: DocStoreBuilder,
    field_name: String,
    split_uuid: Array[UInt8, 16],
    min_doc_id: Int,
    max_doc_id: Int,
    doc_count: Int,
    var fastfields_region: List[UInt8] = List[UInt8](),
    total_token_count: Int = FOOTER_NO_TOTAL_TOKENS,
    token_counts: List[Int] = List[Int](),
    var l0_posting_region: List[UInt8] = List[UInt8](),
) raises -> List[UInt8]:
    """Build the WHOLE immutable split as an owned List[UInt8]. PURE: no S3, no
    file I/O, no global state.

    `total_token_count` (additive, default FOOTER_NO_TOTAL_TOKENS == absent): the
    sum of every doc's "__fieldnorm__" token count over the split. When >= 0 it
    is written into an ADDITIVE trailing footer slot so the BM25 b>0 reader can
    compute `avgdl = total_token_count / doc_count` in O(1) (instead of summing
    the whole "__fieldnorm__" column at query time — the query-latency-scales-
    with-index-size defect). The sink supplies it for free at finish (it already
    holds the per-doc token counts). When FOOTER_NO_TOTAL_TOKENS the slot is
    omitted entirely (the older footer shape) and the reader degrades to the
    column-sum path — backward-compatible both directions.

    `token_counts` (WAND Phase-2 BMW, additive, default empty == BLOCKMAX absent):
    the dense per-doc `dl` (token count) by slot (slot = doc_id - min_doc_id). The
    plumbing the sink supplies for free at finish (it already holds them in the
    "__fieldnorm__" builder). When non-empty AND total_token_count >= 0, an
    additive optional BLOCKMAX region + footer slot pair is written: per term, the
    per-block `(byte_offset, last_docid, max_tf, min_dl)` skip-list the BMW scorer
    uses to skip whole posting blocks (the decode-skip win over Phase-1 term-max
    WAND). An OLD reader ignores the BLOCKMAX footer slot (0/0 = absent) and the
    scorer falls back to Phase-1 term-max WAND / brute — backward-compatible both
    directions. The block bound is recomputed at query time from the query's own
    avgdl + idf (NOT stored as a roundtripped f64), so there is no avgdl-staleness
    footgun and no quantization to round.

    This is the SINGLE owner of the patch pass:
      1. write the posting region from `fi` (FROZEN 128-doc blocks), patching
         `term_dict.set_posting_location(o, off_rel, len)` per ordinal;
      2. `term_dict.serialize(termdict_region)` EXACTLY ONCE (it raises if any
         ordinal is still POSTING_LOC_UNSET);
      3. `doc_store.serialize(docstore_region)`;
      4. assemble magic+version + header-meta + termdict + postings + docstore +
         fastfields + (optional) BLOCKMAX + footer (offsets computed after region
         sizes are known; footer LAST).

    `term_dict` is `var` for MUTATION (set_posting_location needs mut
    self), NOT consumption (serialize is a read borrow). The owned value is
    discarded after serialize.
    """
    var num_terms = fi.num_terms()

    # WAND Phase 2 (BMW): emit a BLOCKMAX region iff per-doc token counts are
    # supplied AND the split carries a usable total (so avgdl is resolvable). The
    # ordering invariant: when BLOCKMAX is present we MUST also write the
    # total_token_count slot (never leave a hole in the additive footer chain) —
    # naturally satisfied here because both gate on the same fieldnorm data.
    var want_blockmax = len(token_counts) > 0 and total_token_count >= 0

    # ---- Step 1: write the posting region + PATCH each ordinal. When
    # BLOCKMAX is wanted, capture per-block metadata via the blockmeta encoder
    # (byte-identical posting output; ONLY the per-block skip-list is extra). The
    # per-term block run is recorded into parallel SoA lists for the tier-2 dump.
    var postings_region = List[UInt8]()
    var bm_num_blocks = List[Int]()  # tier-1: blocks per term (parallel to ord).
    var bm_block_byte_offset = List[Int]()  # tier-2 flat SoA runs (over all blk).
    var bm_block_last_docid = List[Int]()
    var bm_block_max_tf = List[Int]()
    var bm_block_min_dl = List[Int]()
    for o in range(num_terms):
        var off_rel = len(postings_region)
        var doc_ids = fi.posting_doc_ids_at(o)
        var tfs = fi.posting_tfs_at(o)
        if want_blockmax:
            var nb = _encode_posting_list_with_blockmeta(
                doc_ids,
                tfs,
                Span(token_counts),
                min_doc_id,
                postings_region,
                bm_block_byte_offset,
                bm_block_last_docid,
                bm_block_max_tf,
                bm_block_min_dl,
            )
            bm_num_blocks.append(nb)
        else:
            _encode_posting_list(doc_ids, tfs, postings_region)
        var len_rel = len(postings_region) - off_rel
        # Recorded (off_rel, len_rel) are non-negative by construction.
        if off_rel < 0 or len_rel < 0:
            raise Error("serialize_split: negative posting (offset, len)")  # cov: unreachable both are len() differences of a growing list
        term_dict.set_posting_location(o, off_rel, len_rel)

    # ---- Step 2: serialize the term-dict region EXACTLY ONCE ----
    var termdict_region = List[UInt8]()
    term_dict.serialize(termdict_region)

    # ---- Step 3: serialize the doc-store region ----
    var docstore_region = List[UInt8]()
    doc_store.serialize(docstore_region)

    # ---- Step 3b: serialize the (optional) BLOCKMAX region (WAND Phase 2). ----
    var blockmax_region = List[UInt8]()
    if want_blockmax:
        _serialize_blockmax_region(
            num_terms,
            bm_num_blocks,
            bm_block_byte_offset,
            bm_block_last_docid,
            bm_block_max_tf,
            bm_block_min_dl,
            blockmax_region,
        )

    # ---- Step 4: assemble. Compute absolute offsets as we lay regions down. -
    var out = List[UInt8]()

    # (a) front magic + version (8 bytes; validated FIRST by parse).
    for c in "THSPLIT".as_bytes():
        out.append(c)
    out.append(SPLIT_VERSION)

    # (b) header-meta region (separate from footer, sniff-without-footer).
    #     field_name_len u32 + field_name bytes + split_uuid 16B +
    #     doc_count u64 + min_doc_id u64 + max_doc_id u64.
    var fname = field_name.as_bytes()
    _append_u32_le(out, UInt32(len(fname)))
    for c in fname:
        out.append(c)
    for i in range(16):
        out.append(split_uuid[i])
    if doc_count < 0 or min_doc_id < 0 or max_doc_id < 0:
        raise Error("serialize_split: negative doc_count / min / max doc-id")
    _append_u64_le(out, UInt64(doc_count))
    _append_u64_le(out, UInt64(min_doc_id))
    _append_u64_le(out, UInt64(max_doc_id))

    # (c) term-dict region (ABSOLUTE offset recorded for the footer).
    var termdict_offset = len(out)
    var termdict_len = len(termdict_region)
    for i in range(termdict_len):
        out.append(termdict_region[i])

    # (d) postings region.
    var postings_offset = len(out)
    var postings_len = len(postings_region)
    for i in range(postings_len):
        out.append(postings_region[i])

    # (e) doc-store region.
    var docstore_offset = len(out)
    var docstore_len = len(docstore_region)
    for i in range(docstore_len):
        out.append(docstore_region[i])

    # (e2) fast-fields region (fast-fields — laid AFTER doc-store, BEFORE footer).
    #      An empty region (default) keeps a split without fast fields (offset/len 0/0).
    var fastfields_offset = len(out)
    var fastfields_len = len(fastfields_region)
    for i in range(fastfields_len):
        out.append(fastfields_region[i])
    if fastfields_len == 0:
        fastfields_offset = 0  # canonical "absent" sentinel.

    # (e3) BLOCKMAX region (WAND Phase 2 — laid AFTER fast-fields, BEFORE footer).
    #      Absent (empty) keeps the footer slot 0/0 (an OLD reader / a fall-back
    #      to Phase-1 term-max WAND).
    var blockmax_offset = len(out)
    var blockmax_len = len(blockmax_region)
    for i in range(blockmax_len):
        out.append(blockmax_region[i])
    if blockmax_len == 0:
        blockmax_offset = 0  # canonical "absent" sentinel.

    # (e4) L0-POSTING region (LSM logger L0 — laid AFTER blockmax, BEFORE footer).
    #      The writer copies the caller's bytes verbatim. PRESENT on an L0 (cheap drain) split, ABSENT (empty) on an
    #      optimized split — the FORMAT DISCRIMINATOR is the presence of this
    #      region's footer slot. split.mojo treats it as an opaque blob
    #      (offset/len only) and specifies no byte layout for it. No reader in
    #      this package decodes it: SearchCore refuses a split that carries it.
    var l0_posting_offset = len(out)
    var l0_posting_len = len(l0_posting_region)
    for i in range(l0_posting_len):
        out.append(l0_posting_region[i])
    if l0_posting_len == 0:
        l0_posting_offset = 0  # canonical "absent" sentinel (an optimized split).

    # (f) FOOTER (written LAST; authoritative; read footer-first by SearchCore).
    var footer_start = len(out)
    for c in "THSF".as_bytes():
        out.append(c)
    out.append(FOOTER_VERSION)
    # split-level metadata (self-contained; duplicates header-meta).
    _append_u32_le(out, UInt32(len(fname)))
    for c in fname:
        out.append(c)
    for i in range(16):
        out.append(split_uuid[i])
    _append_u64_le(out, UInt64(doc_count))
    _append_u64_le(out, UInt64(min_doc_id))
    _append_u64_le(out, UInt64(max_doc_id))
    # region offset table (ABSOLUTE offset + len, each u64 LE).
    _append_u64_le(out, UInt64(termdict_offset))
    _append_u64_le(out, UInt64(termdict_len))
    _append_u64_le(out, UInt64(postings_offset))
    _append_u64_le(out, UInt64(postings_len))
    _append_u64_le(out, UInt64(docstore_offset))
    _append_u64_le(out, UInt64(docstore_len))
    # fast-fields region offset table (fast-fields — FILLED; 0/0 = absent).
    _append_u64_le(out, UInt64(fastfields_offset))  # fastfields_offset
    _append_u64_le(out, UInt64(fastfields_len))  # fastfields_len
    # RESERVED (additive; 0/0 = absent).
    _append_u64_le(out, UInt64(0))  # bloom_offset
    _append_u64_le(out, UInt64(0))  # bloom_len
    # ADDITIVE trailing slot (after the reserved bloom slots): per-split total
    # token count, for O(1) BM25 b>0 avgdl. Written ONLY when supplied (>= 0) —
    # otherwise the slot is omitted and the footer keeps its earlier shape (an
    # old reader stops at the bloom slots; a new reader detects absence via the
    # footer_len-bounded remaining-bytes check). 8 bytes when present.
    #
    # The additive-chain ordering invariant: when BLOCKMAX is present we append a
    # SECOND optional pair (blockmax_offset/len) AFTER this slot, so the total
    # slot MUST be written unconditionally whenever blockmax is — never leave a
    # hole in the chain (a reader can't disambiguate "no total + blockmax" from
    # "total + 8 trailing bytes" otherwise). `want_blockmax` already requires
    # total_token_count >= 0, so this is naturally satisfied; asserted here.
    if want_blockmax and total_token_count < 0:
        raise Error(  # cov: unreachable want_blockmax already requires total_token_count >= 0
            "serialize_split: BLOCKMAX present but total_token_count absent"
            " (additive-chain hole)"
        )
    # The L0-posting slot sits at chain position 3 (after total + blockmax), so it
    # is reachable ONLY if total_token_count is present (>= 0). For an L0 split
    # doc_count > 0 always supplies it, but assert the chain invariant fail-loud.
    if l0_posting_len > 0 and total_token_count < 0:
        raise Error(
            "serialize_split: l0_posting present but total_token_count absent"
            " (additive-chain hole — supply total_token_count for the L0 split)"
        )
    if total_token_count >= 0:
        _append_u64_le(out, UInt64(total_token_count))  # total_token_count
    # The ADDITIVE-CHAIN ordering after total_token_count is:
    #     [total_token_count:8] [blockmax pair:16] [l0_posting pair:16]
    # Each later slot is reachable by the parse's remaining-bytes check ONLY if
    # every EARLIER slot in the chain is present (no holes). So when the L0-posting
    # slot follows, the blockmax pair MUST be emitted even when absent (written
    # 0/0) to keep the chain contiguous — otherwise the parser cannot disambiguate
    # "blockmax + 16 trailing l0 bytes" from "no blockmax + l0 read as blockmax".
    # The LSM logger L0 split has NO blockmax (empty postings) but DOES carry the
    # l0_posting region, so it relies on this hole-free encoding.
    var want_l0_posting = l0_posting_len > 0
    if blockmax_len > 0 or want_l0_posting:
        # blockmax pair (0/0 when absent — preserves the chain for l0_posting).
        _append_u64_le(out, UInt64(blockmax_offset))  # blockmax_offset
        _append_u64_le(out, UInt64(blockmax_len))  # blockmax_len
    # L0-POSTING footer slot pair (LSM logger L0 — ADDITIVE, after blockmax). This
    # is the FORMAT DISCRIMINATOR: present (len > 0) => an L0 cheap-posting split;
    # absent => an optimized split. SearchCore construction raises on a split
    # that carries it (SearchCore has no l0_posting reader).
    # A new reader detects it via the footer_len-bounded remaining-
    # bytes check (>= 16 after the blockmax pair). 0/0 is NEVER written here — the
    # slot is emitted ONLY when the region is genuinely present.
    if want_l0_posting:
        _append_u64_le(out, UInt64(l0_posting_offset))  # l0_posting_offset
        _append_u64_le(out, UInt64(l0_posting_len))  # l0_posting_len
    # footer_len: byte length of THIS footer body, EXCLUDING the trailing
    # footer_len u32 + trailing "THSF" (lets SearchCore seek back from EOF).
    var footer_len = len(out) - footer_start
    _append_u32_le(out, UInt32(footer_len))
    for c in "THSF".as_bytes():
        out.append(c)
    _ = num_terms  # (silence unused if num_terms==0)
    return out^


# =============================================================================
# BLOCKMAX region (WAND Phase 2 / BMW). Additive, two-tier.
# =============================================================================
#
# Region layout (laid after fast-fields, before footer; footer slot 0/0 = absent):
#
#   header:
#     version    u8        (BLOCKMAX_VERSION)
#     num_terms  ULEB128   (== fi.num_terms(); parallel to TermInfo ordinals)
#
#   TIER 1 — per-term summary (read for every BMW-eligible term):
#     for each ordinal o (in ordinal order):
#       num_blocks         ULEB128   (== ceil(doc_freq / 128))
#       block_tier_offset  ULEB128   (start index into the TIER-2 flat SoA arrays)
#
#   TIER 2 — dense per-block SoA (one entry per block across ALL terms, in the
#            same flat order TIER 1's block_tier_offset indexes):
#     block_byte_offset[]  ULEB128 run  (byte offset of block start RELATIVE to the
#                                        term's post-doc_count base — the block-skip
#                                        DESTINATION)
#     block_last_docid[]   ULEB128 run  (largest doc-id in the block — skip ceiling)
#     block_max_tf[]       ULEB128 run  (per-block max tf — the bound's tf input)
#     block_min_dl[]       ULEB128 run  (per-block min dl, clamped >= 0 — the bound's
#                                        dl input; the block bound = idf *
#                                        f(max_tf, min_dl), recomputed at query time)
#
# The block bound is NOT stored as a roundtripped f64 — only its integer inputs
# (max_tf, min_dl) are stored, and the query recomputes idf * f(max_tf, min_dl)
# via the SAME bm25_score_contribution the scorer uses. This makes the bound
# exact-by-construction (no f64 storage drift), backward-compat trivial, and
# sidesteps the avgdl-staleness footgun (the bound uses the query's avgdl, which
# is read from the SAME footer total the scorer reads).


def _serialize_blockmax_region(
    num_terms: Int,
    bm_num_blocks: List[Int],
    bm_block_byte_offset: List[Int],
    bm_block_last_docid: List[Int],
    bm_block_max_tf: List[Int],
    bm_block_min_dl: List[Int],
    mut out: List[UInt8],
) raises:
    """Emit the BLOCKMAX region (two-tier SoA) into `out`. The four
    tier-2 SoA lists are flat over all blocks (in ordinal order, blocks within a
    term in block order); `bm_num_blocks` is parallel to ordinals."""
    if len(bm_num_blocks) != num_terms:
        raise Error(
            "_serialize_blockmax_region: num_blocks/num_terms mismatch ("
            + String(len(bm_num_blocks))
            + " vs "
            + String(num_terms)
            + ")"
        )
    out.append(BLOCKMAX_VERSION)
    write_uleb128(num_terms, out)

    # TIER 1: per-term (num_blocks, block_tier_offset). block_tier_offset is the
    # running cumulative block index (the start of this term's run in tier 2).
    var cum = 0
    for o in range(num_terms):
        var nb = bm_num_blocks[o]
        if nb < 0:
            raise Error("_serialize_blockmax_region: negative num_blocks")
        write_uleb128(nb, out)
        write_uleb128(cum, out)
        cum += nb
    var total_blocks = cum
    if (
        len(bm_block_byte_offset) != total_blocks
        or len(bm_block_last_docid) != total_blocks
        or len(bm_block_max_tf) != total_blocks
        or len(bm_block_min_dl) != total_blocks
    ):
        raise Error(
            "_serialize_blockmax_region: tier-2 SoA length mismatch (expected "
            + String(total_blocks)
            + ")"
        )

    # TIER 2: the four homogeneous ULEB128 runs (SoA — future SIMD-friendly).
    for b in range(total_blocks):
        var v = bm_block_byte_offset[b]
        if v < 0:
            raise Error("_serialize_blockmax_region: negative block_byte_offset")
        write_uleb128(v, out)
    for b in range(total_blocks):
        var v = bm_block_last_docid[b]
        if v < 0:
            raise Error("_serialize_blockmax_region: negative block_last_docid")
        write_uleb128(v, out)
    for b in range(total_blocks):
        var v = bm_block_max_tf[b]
        if v < 0:
            raise Error("_serialize_blockmax_region: negative block_max_tf")
        write_uleb128(v, out)
    for b in range(total_blocks):
        var v = bm_block_min_dl[b]
        if v < 0:
            raise Error("_serialize_blockmax_region: negative block_min_dl")
        write_uleb128(v, out)


# =============================================================================
# BlockMaxIndex: the parsed BLOCKMAX region (WAND Phase 2 read side).
# =============================================================================


struct BlockMaxIndex(Movable, Deinitable):
    """The parsed BLOCKMAX region (deserialized ONCE at SearchCore construction).
    POD List substrate (clean: all List[Int], stack/owned, never a byte-slab
    element). The BMW scorer reads, per query term ordinal `o`:
      * num_blocks(o) -> the count of 128-doc blocks in that term's posting list;
      * block_byte_offset(o, b), block_last_docid(o, b), block_max_tf(o, b),
        block_min_dl(o, b) -> the per-block skip-list entry.
    Offsets into the flat tier-2 SoA are resolved via the tier-1 block_tier_offset
    captured at deserialize.

    NOTE: a per-term `num_blocks` of 0 means doc_freq == 0 (a term with no
    postings); the BMW cursor treats it as an exhausted list."""

    var _num_blocks: List[Int]
    """Tier-1: blocks per ordinal (len == num_terms)."""
    var _tier_offset: List[Int]
    """Tier-1: each ordinal's start index into the flat tier-2 SoA arrays."""
    var _block_byte_offset: List[Int]
    """Tier-2 SoA: per-block byte offset (relative to term post-doc_count base)."""
    var _block_last_docid: List[Int]
    """Tier-2 SoA: per-block last doc-id (skip ceiling)."""
    var _block_max_tf: List[Int]
    """Tier-2 SoA: per-block max tf (bound tf input)."""
    var _block_min_dl: List[Int]
    """Tier-2 SoA: per-block min dl, clamped >= 0 (bound dl input)."""

    def __init__(
        out self,
        var num_blocks: List[Int],
        var tier_offset: List[Int],
        var block_byte_offset: List[Int],
        var block_last_docid: List[Int],
        var block_max_tf: List[Int],
        var block_min_dl: List[Int],
    ):
        self._num_blocks = num_blocks^
        self._tier_offset = tier_offset^
        self._block_byte_offset = block_byte_offset^
        self._block_last_docid = block_last_docid^
        self._block_max_tf = block_max_tf^
        self._block_min_dl = block_min_dl^

    @staticmethod
    def deserialize(region: Span[UInt8, _]) raises -> BlockMaxIndex:
        """Parse the BLOCKMAX region (two-tier SoA). Fail-loud bounds (the
        split is attacker-influenced at query time)."""
        var n = len(region)
        if n < 1:
            raise Error("BlockMaxIndex.deserialize: empty region")
        var off = 0
        var ver = Int(region[off])
        off += 1
        if ver != Int(BLOCKMAX_VERSION):
            raise Error(
                "BlockMaxIndex.deserialize: unsupported BLOCKMAX version "
                + String(ver)
            )
        var nt_res = _read_uleb128_span(region, off, n)
        var num_terms = nt_res[0]
        off = nt_res[1]
        if num_terms < 0:
            raise Error("BlockMaxIndex.deserialize: negative num_terms")

        # TIER 1: per-term (num_blocks, block_tier_offset).
        var num_blocks = List[Int]()
        var tier_offset = List[Int]()
        var total_blocks = 0
        for _ in range(num_terms):
            var nb_res = _read_uleb128_span(region, off, n)
            var nb = nb_res[0]
            off = nb_res[1]
            var to_res = _read_uleb128_span(region, off, n)
            var to = to_res[0]
            off = to_res[1]
            if nb < 0 or to < 0:
                raise Error("BlockMaxIndex.deserialize: negative tier-1 value")
            num_blocks.append(nb)
            tier_offset.append(to)
            total_blocks += nb

        # TIER 2: four homogeneous ULEB128 runs of `total_blocks` each.
        var block_byte_offset = List[Int]()
        var block_last_docid = List[Int]()
        var block_max_tf = List[Int]()
        var block_min_dl = List[Int]()
        for _ in range(total_blocks):
            var r = _read_uleb128_span(region, off, n)
            block_byte_offset.append(r[0])
            off = r[1]
        for _ in range(total_blocks):
            var r = _read_uleb128_span(region, off, n)
            block_last_docid.append(r[0])
            off = r[1]
        for _ in range(total_blocks):
            var r = _read_uleb128_span(region, off, n)
            block_max_tf.append(r[0])
            off = r[1]
        for _ in range(total_blocks):
            var r = _read_uleb128_span(region, off, n)
            block_min_dl.append(r[0])
            off = r[1]

        return BlockMaxIndex(
            num_blocks^,
            tier_offset^,
            block_byte_offset^,
            block_last_docid^,
            block_max_tf^,
            block_min_dl^,
        )

    @always_inline
    def num_terms(self) -> Int:
        return len(self._num_blocks)

    @always_inline
    def num_blocks(self, ordinal: Int) -> Int:
        return self._num_blocks[ordinal]

    @always_inline
    def _flat_index(self, ordinal: Int, block: Int) -> Int:
        return self._tier_offset[ordinal] + block

    @always_inline
    def block_byte_offset(self, ordinal: Int, block: Int) -> Int:
        return self._block_byte_offset[self._flat_index(ordinal, block)]

    @always_inline
    def block_last_docid(self, ordinal: Int, block: Int) -> Int:
        return self._block_last_docid[self._flat_index(ordinal, block)]

    @always_inline
    def block_max_tf(self, ordinal: Int, block: Int) -> Int:
        return self._block_max_tf[self._flat_index(ordinal, block)]

    @always_inline
    def block_min_dl(self, ordinal: Int, block: Int) -> Int:
        return self._block_min_dl[self._flat_index(ordinal, block)]


# =============================================================================
# SplitView: the footer-first reader stub (fail-loud) + SearchCore seam.
# =============================================================================


struct SplitView(Movable, Deinitable):
    """Owns the split bytes; exposes footer-first region access. The split writer unit
    test parses this to assert structure; SearchCore (searcher) builds its real reader
    on this same footer-first surface.

    Parse validation order (the split is attacker-influenced at SearchCore query
    time, so this is load-bearing):
      1. front magic "THSPLIT" + version FIRST;
      2. total_len >= minimum-footer-size before reading the trailing footer_len;
      3. footer_len <= total_len - (footer_len_field + trailing_magic) before
         seeking back;
      4. each region (offset,len): offset+len <= total_len AND offset >= 8 (past
         magic) AND regions non-overlapping — BEFORE slicing any Span;
      5. bound every decoded length against remaining.

    Borrowed region accessors return Span[UInt8, origin_of(self._bytes)] tied to
    the INNER owned field — the established idiom.
    """

    var _bytes: List[UInt8]
    var _field_name: String
    var _doc_count: Int
    var _min_doc_id: Int
    var _max_doc_id: Int
    var _split_uuid: Array[UInt8, 16]
    var _termdict_offset: Int
    var _termdict_len: Int
    var _postings_offset: Int
    var _postings_len: Int
    var _docstore_offset: Int
    var _docstore_len: Int
    var _fastfields_offset: Int
    var _fastfields_len: Int
    var _has_total_token_count: Bool
    """True iff the footer carried the ADDITIVE total_token_count slot."""
    var _total_token_count: Int
    """Sum of every doc's "__fieldnorm__" token count (valid only when
    _has_total_token_count). Drives the O(1) BM25 b>0 avgdl read."""
    var _blockmax_offset: Int
    """ABSOLUTE byte offset of the BLOCKMAX region (WAND Phase 2 / BMW), or 0 when
    absent (an OLD split / Phase-1 fall-back)."""
    var _blockmax_len: Int
    """Byte length of the BLOCKMAX region, or 0 when absent."""
    var _l0_posting_offset: Int
    """ABSOLUTE byte offset of the L0-POSTING region (LSM logger L0 cheap-posting
    blob), or 0 when absent (an optimized split). The FORMAT DISCRIMINATOR."""
    var _l0_posting_len: Int
    """Byte length of the L0-POSTING region, or 0 when absent (an optimized
    split)."""

    def __init__(
        out self,
        var bytes: List[UInt8],
        var field_name: String,
        doc_count: Int,
        min_doc_id: Int,
        max_doc_id: Int,
        split_uuid: Array[UInt8, 16],
        termdict_offset: Int,
        termdict_len: Int,
        postings_offset: Int,
        postings_len: Int,
        docstore_offset: Int,
        docstore_len: Int,
        fastfields_offset: Int = 0,
        fastfields_len: Int = 0,
        has_total_token_count: Bool = False,
        total_token_count: Int = 0,
        blockmax_offset: Int = 0,
        blockmax_len: Int = 0,
        l0_posting_offset: Int = 0,
        l0_posting_len: Int = 0,
    ):
        self._bytes = bytes^
        self._field_name = field_name^
        self._doc_count = doc_count
        self._min_doc_id = min_doc_id
        self._max_doc_id = max_doc_id
        self._split_uuid = split_uuid.copy()
        self._termdict_offset = termdict_offset
        self._termdict_len = termdict_len
        self._postings_offset = postings_offset
        self._postings_len = postings_len
        self._docstore_offset = docstore_offset
        self._docstore_len = docstore_len
        self._fastfields_offset = fastfields_offset
        self._fastfields_len = fastfields_len
        self._has_total_token_count = has_total_token_count
        self._total_token_count = total_token_count
        self._blockmax_offset = blockmax_offset
        self._blockmax_len = blockmax_len
        self._l0_posting_offset = l0_posting_offset
        self._l0_posting_len = l0_posting_len

    @staticmethod
    def parse(var bytes: List[UInt8]) raises -> SplitView:
        """Validate the container front-to-back-to-footer and build a SplitView
        over the owned bytes. Fail-loud on any corruption."""
        var total = len(bytes)

        # ---- (1) front magic + version FIRST ----
        if total < SPLIT_MAGIC_LEN:
            raise Error("SplitView.parse: too short for magic (corrupt)")
        var expected = "THSPLIT".as_bytes()
        for i in range(7):
            if bytes[i] != expected[i]:
                raise Error(
                    "SplitView.parse: bad magic (expected 'THSPLIT')"
                )
        if bytes[7] != SPLIT_VERSION:
            raise Error(
                "SplitView.parse: unsupported version "
                + String(Int(bytes[7]))
                + " (expected "
                + String(Int(SPLIT_VERSION))
                + ")"
            )

        # ---- (2) minimum footer presence: trailing footer_len u32 + "THSF" ----
        # The footer body is at least: "THSF"(4) + ver(1) + fname_len(4) +
        # uuid(16) + doc_count/min/max(24) + 6 region u64s(48) + 4 reserved
        # u64s(32) = 129 bytes minimum (fname_len 0). Plus trailing u32 + "THSF".
        var min_footer_total = 129 + 4 + FOOTER_MAGIC_LEN
        if total < SPLIT_MAGIC_LEN + min_footer_total:
            raise Error("SplitView.parse: too short for footer (corrupt)")

        # trailing "THSF" sentinel.
        var fmagic = "THSF".as_bytes()
        for i in range(FOOTER_MAGIC_LEN):
            if bytes[total - FOOTER_MAGIC_LEN + i] != fmagic[i]:
                raise Error("SplitView.parse: bad trailing footer magic")

        # footer_len u32 sits just before the trailing "THSF".
        var fl_pos = total - FOOTER_MAGIC_LEN - 4
        var footer_len = Int(
            UInt32(bytes[fl_pos])
            | (UInt32(bytes[fl_pos + 1]) << 8)
            | (UInt32(bytes[fl_pos + 2]) << 16)
            | (UInt32(bytes[fl_pos + 3]) << 24)
        )

        # ---- (3) footer_len in range; locate footer start ----
        if footer_len < 0 or footer_len > total - (4 + FOOTER_MAGIC_LEN):
            raise Error("SplitView.parse: footer_len out of range (corrupt)")
        var footer_start = total - (4 + FOOTER_MAGIC_LEN) - footer_len
        if footer_start < SPLIT_MAGIC_LEN:
            raise Error("SplitView.parse: footer start before header (corrupt)")

        # Parse the footer via a ByteBuffer cursor (bounds-checked reads).
        # Re-own a COPY of just the footer body for the cursor (cheap; footer is
        # tiny). The main bytes stay owned by the SplitView.
        var footer_body = List[UInt8]()
        for i in range(footer_len):
            footer_body.append(bytes[footer_start + i])
        var cur = ByteBuffer(footer_body^)

        # footer magic "THSF".
        for i in range(FOOTER_MAGIC_LEN):
            if cur.read_byte() != fmagic[i]:
                raise Error("SplitView.parse: bad footer-start magic")
        var fver = cur.read_byte()
        if fver != FOOTER_VERSION:
            raise Error(
                "SplitView.parse: unsupported footer version "
                + String(Int(fver))
            )
        var fname_len = Int(cur.read_u32_le())
        if fname_len < 0 or fname_len > cur.remaining():
            raise Error("SplitView.parse: footer field_name_len out of bounds")
        var fname_bytes = List[UInt8]()
        cur.read_into_list(fname_bytes, fname_len)
        # SAFETY: the field name was written from a String by the split writer; its
        # length was bounds-checked above.
        var field_name = String(StringSlice(unsafe_from_utf8=Span(fname_bytes)))
        var uuid = Array[UInt8, 16](fill=0)
        for i in range(16):
            uuid[i] = cur.read_byte()
        var doc_count = Int(cur.read_u64_le())
        var min_doc_id = Int(cur.read_u64_le())
        var max_doc_id = Int(cur.read_u64_le())
        var termdict_offset = Int(cur.read_u64_le())
        var termdict_len = Int(cur.read_u64_le())
        var postings_offset = Int(cur.read_u64_le())
        var postings_len = Int(cur.read_u64_le())
        var docstore_offset = Int(cur.read_u64_le())
        var docstore_len = Int(cur.read_u64_le())
        # fast-fields region slot (fast-fields — CAPTURE, do not discard; 0/0 = absent).
        var fastfields_offset = Int(cur.read_u64_le())
        var fastfields_len = Int(cur.read_u64_le())
        # reserved slots (read + discard; 0/0).
        _ = cur.read_u64_le()  # bloom_offset
        _ = cur.read_u64_le()  # bloom_len

        # ADDITIVE trailing slot (after the reserved bloom slots): per-split total
        # token count for O(1) BM25 b>0 avgdl. Present iff the footer body still
        # has >= 8 unread bytes (a NEW writer appended it; an OLD writer did not).
        # The footer_body cursor is bounded to exactly `footer_len` bytes, so this
        # never over-reads into the trailing footer_len u32 / "THSF" sentinel.
        var has_total_token_count = False
        var total_token_count = 0
        if cur.remaining() >= 8:
            has_total_token_count = True
            total_token_count = Int(cur.read_u64_le())
            if total_token_count < 0:
                raise Error(
                    "SplitView.parse: negative total_token_count (corrupt)"
                )

        # ADDITIVE BLOCKMAX footer slot pair (WAND Phase 2 / BMW), present iff the
        # footer body still has >= 16 unread bytes AFTER the total_token_count slot
        # (blockmax is ONLY ever written after total_token_count, never
        # standalone — the chain order guarantees no ambiguity). 0/0 = absent
        # (an OLD split / Phase-1 fall-back).
        var blockmax_offset = 0
        var blockmax_len = 0
        if cur.remaining() >= 16:
            blockmax_offset = Int(cur.read_u64_le())
            blockmax_len = Int(cur.read_u64_le())
            if blockmax_offset < 0 or blockmax_len < 0:
                raise Error(
                    "SplitView.parse: negative blockmax offset/len (corrupt)"
                )

        # ADDITIVE L0-POSTING footer slot pair (LSM logger L0), present iff the
        # footer body still has >= 16 unread bytes AFTER the blockmax slot (the
        # l0_posting slot is ONLY ever written after the blockmax pair, which is
        # written 0/0 when absent to keep the chain hole-free — so this read is
        # unambiguous). Present (len > 0) => the FORMAT DISCRIMINATOR: an L0
        # cheap-posting split (SearchCore construction refuses it).
        # 0/0 / absent => an optimized split.
        var l0_posting_offset = 0
        var l0_posting_len = 0
        if cur.remaining() >= 16:
            l0_posting_offset = Int(cur.read_u64_le())
            l0_posting_len = Int(cur.read_u64_le())
            if l0_posting_offset < 0 or l0_posting_len < 0:
                raise Error(
                    "SplitView.parse: negative l0_posting offset/len (corrupt)"
                )

        # ---- (4) validate each region: in-bounds, past-magic, non-overlapping
        _validate_region(
            "termdict", termdict_offset, termdict_len, total, footer_start
        )
        _validate_region(
            "postings", postings_offset, postings_len, total, footer_start
        )
        _validate_region(
            "docstore", docstore_offset, docstore_len, total, footer_start
        )
        # Non-overlap + ordering. Core regions: termdict -> postings -> docstore.
        # The fast-fields region, WHEN PRESENT (len > 0), sits between
        # docstore_end and footer_start. WAND Phase 2: the BLOCKMAX region, WHEN
        # PRESENT, sits AFTER fast-fields and BEFORE footer. A populated split
        # otherwise fails parse (the load-bearing gotcha: a correct writer
        # producing a reader-rejected split). The on-disk region order is:
        #   termdict -> postings -> docstore -> [fastfields] -> [blockmax] -> footer
        if fastfields_len < 0 or fastfields_offset < 0:
            raise Error("SplitView.parse: negative fast-fields offset/len")
        if blockmax_len > 0:
            _validate_region(
                "blockmax", blockmax_offset, blockmax_len, total, footer_start
            )
        # `prev_end` walks the trailing edge of each present region in order:
        # termdict -> postings -> docstore -> [fastfields] -> [blockmax] -> footer.
        if termdict_offset + termdict_len > postings_offset:
            raise Error("SplitView.parse: regions overlap / out of order")
        if postings_offset + postings_len > docstore_offset:
            raise Error("SplitView.parse: regions overlap / out of order")
        var prev_end = docstore_offset + docstore_len
        if fastfields_len > 0:
            _validate_region(
                "fastfields",
                fastfields_offset,
                fastfields_len,
                total,
                footer_start,
            )
            if prev_end > fastfields_offset:
                raise Error(
                    "SplitView.parse: regions overlap / out of order"
                    " (with fast-fields)"
                )
            prev_end = fastfields_offset + fastfields_len
        if blockmax_len > 0:
            if prev_end > blockmax_offset:
                raise Error(
                    "SplitView.parse: regions overlap / out of order"
                    " (with blockmax)"
                )
            prev_end = blockmax_offset + blockmax_len
        if l0_posting_len > 0:
            _validate_region(
                "l0_posting",
                l0_posting_offset,
                l0_posting_len,
                total,
                footer_start,
            )
            if prev_end > l0_posting_offset:
                raise Error(
                    "SplitView.parse: regions overlap / out of order"
                    " (with l0_posting)"
                )
            prev_end = l0_posting_offset + l0_posting_len
        if prev_end > footer_start:
            raise Error("SplitView.parse: regions overlap / out of order")  # cov: unreachable each present region was validated to end by footer_start

        return SplitView(
            bytes=bytes^,
            field_name=field_name^,
            doc_count=doc_count,
            min_doc_id=min_doc_id,
            max_doc_id=max_doc_id,
            split_uuid=uuid,
            termdict_offset=termdict_offset,
            termdict_len=termdict_len,
            postings_offset=postings_offset,
            postings_len=postings_len,
            docstore_offset=docstore_offset,
            docstore_len=docstore_len,
            fastfields_offset=fastfields_offset,
            fastfields_len=fastfields_len,
            has_total_token_count=has_total_token_count,
            total_token_count=total_token_count,
            blockmax_offset=blockmax_offset,
            blockmax_len=blockmax_len,
            l0_posting_offset=l0_posting_offset,
            l0_posting_len=l0_posting_len,
        )

    # ---- footer metadata accessors ----

    @always_inline
    def field_name(self) -> String:
        return self._field_name

    @always_inline
    def doc_count(self) -> Int:
        return self._doc_count

    @always_inline
    def min_doc_id(self) -> Int:
        return self._min_doc_id

    @always_inline
    def max_doc_id(self) -> Int:
        return self._max_doc_id

    @always_inline
    def split_uuid(self) -> Array[UInt8, 16]:
        return self._split_uuid.copy()

    @always_inline
    def termdict_offset(self) -> Int:
        return self._termdict_offset

    @always_inline
    def termdict_len(self) -> Int:
        return self._termdict_len

    @always_inline
    def postings_offset(self) -> Int:
        return self._postings_offset

    @always_inline
    def postings_len(self) -> Int:
        return self._postings_len

    @always_inline
    def docstore_offset(self) -> Int:
        return self._docstore_offset

    @always_inline
    def docstore_len(self) -> Int:
        return self._docstore_len

    @always_inline
    def fastfields_offset(self) -> Int:
        return self._fastfields_offset

    @always_inline
    def fastfields_len(self) -> Int:
        return self._fastfields_len

    @always_inline
    def has_fastfields(self) -> Bool:
        """True iff this split carries a fast-fields region (len > 0).
        A split without fast-fields returns False."""
        return self._fastfields_len > 0

    @always_inline
    def has_total_token_count(self) -> Bool:
        """True iff the footer carried the ADDITIVE per-split total_token_count
        slot (a split written with the O(1)-avgdl writer). A split written by an
        older writer returns False, and the BM25 b>0 reader degrades to the
        O(doc_count) column-sum path."""
        return self._has_total_token_count

    @always_inline
    def total_token_count(self) -> Int:
        """The per-split total token count (sum of every doc's "__fieldnorm__"),
        for O(1) `avgdl = total_token_count / doc_count`. Valid ONLY when
        has_total_token_count() is True (else 0 — DO NOT use it for avgdl; fall
        back to the column-sum path)."""
        return self._total_token_count

    @always_inline
    def blockmax_offset(self) -> Int:
        return self._blockmax_offset

    @always_inline
    def blockmax_len(self) -> Int:
        return self._blockmax_len

    @always_inline
    def has_blockmax(self) -> Bool:
        """True iff this split carries a WAND Phase 2 (BMW) BLOCKMAX region
        (len > 0). A split written by an older writer (or with no usable
        fieldnorm) returns False, and the scorer falls back to Phase-1 term-max
        WAND / brute (byte-identical result either way)."""
        return self._blockmax_len > 0

    @always_inline
    def l0_posting_offset(self) -> Int:
        return self._l0_posting_offset

    @always_inline
    def l0_posting_len(self) -> Int:
        return self._l0_posting_len

    @always_inline
    def has_l0_posting(self) -> Bool:
        """True iff this split carries an LSM logger L0 cheap-posting region
        (len > 0). This is the FORMAT DISCRIMINATOR: an L0 (cheap drain)
        split returns True (empty term-dict + non-empty l0_posting); an optimized
        split returns False (populated term-dict + no l0_posting). No reader in
        this package decodes the l0_posting region: SearchCore construction
        (`SearchCore(bytes)` and `SearchCore.from_view`) raises when this is
        True."""
        return self._l0_posting_len > 0

    @always_inline
    def total_len(self) -> Int:
        return len(self._bytes)

    # ---- borrowed region accessors (Span tied to the INNER field) ----
    # Each is a slice of `Span(self._bytes)`, so it cannot reach past `_bytes`.
    # The offsets and lengths are checked against `len(self._bytes)` by
    # `_validate_region` when the split is parsed.

    def term_dict_region(
        self,
    ) -> Span[UInt8, origin_of(self._bytes)]:
        """The verbatim term-dict region bytes (== TermDictionary.serialize)."""
        return Span(self._bytes)[self._termdict_offset : self._termdict_offset + self._termdict_len]

    def postings_region(
        self,
    ) -> Span[UInt8, origin_of(self._bytes)]:
        """The posting-lists region bytes (FROZEN 128-doc blocks per ordinal)."""
        return Span(self._bytes)[self._postings_offset : self._postings_offset + self._postings_len]

    def docstore_region(
        self,
    ) -> Span[UInt8, origin_of(self._bytes)]:
        """The doc-store region bytes."""
        return Span(self._bytes)[self._docstore_offset : self._docstore_offset + self._docstore_len]

    def fastfields_region(
        self,
    ) -> Span[UInt8, origin_of(self._bytes)]:
        """The fast-fields region bytes ("THFF"...; fast-fields). Span tied to the INNER
        _bytes field origin (the SearchCore gotcha — NOT a Span param). An EMPTY span
        when absent (has_fastfields() False)."""
        return Span(self._bytes)[self._fastfields_offset : self._fastfields_offset + self._fastfields_len]

    def blockmax_region(
        self,
    ) -> Span[UInt8, origin_of(self._bytes)]:
        """The BLOCKMAX region bytes (WAND Phase 2 / BMW two-tier SoA skip-list).
        Span tied to the INNER _bytes field origin. An EMPTY span
        when absent (has_blockmax() False)."""
        return Span(self._bytes)[self._blockmax_offset : self._blockmax_offset + self._blockmax_len]

    def l0_posting_region(
        self,
    ) -> Span[UInt8, origin_of(self._bytes)]:
        """The LSM logger L0 cheap-posting region bytes, an opaque blob whose
        layout this package does not specify or decode. Span tied to the INNER
        _bytes field origin. An EMPTY span when absent (has_l0_posting()
        False — an optimized split)."""
        return Span(self._bytes)[self._l0_posting_offset : self._l0_posting_offset + self._l0_posting_len]


def _validate_region(
    name: String, offset: Int, length: Int, total: Int, footer_start: Int
) raises:
    """A region must be in-bounds, past the 8-byte magic, and entirely
    before the footer. A length of 0 means the region is empty (valid: an empty
    posting region for a 0-term split). For a 0-len region we only require the
    offset to be sane (in [8, footer_start])."""
    if length < 0 or offset < 0:
        raise Error(
            "SplitView.parse: region '" + name + "' negative offset/len"
        )
    if offset < SPLIT_MAGIC_LEN:
        raise Error(
            "SplitView.parse: region '" + name + "' offset before magic"
        )
    if offset > total:
        raise Error("SplitView.parse: region '" + name + "' offset past EOF")
    if length > footer_start - offset:  # not offset + length: it can wrap Int
        raise Error(
            "SplitView.parse: region '"
            + name
            + "' extends past footer start (offset "
            + String(offset)
            + " + len "
            + String(length)
            + " > "
            + String(footer_start)
            + ")"
        )
