# =============================================================================
# komira_telemetry_store.segment_entry: `TelemetrySegmentEntry`, THE MANIFEST
#   BODY THAT CARRIES A TIME RANGE.
# =============================================================================
#
# The CAS manifest (`komira_objectstore/cas_manifest.mojo`) treats a chunk body
# as ENTIRELY OPAQUE, so a new dataset rides the existing substrate (CAS append,
# `_HEAD`, tombstones, the reaper) by supplying a new body type and nothing
# else.
#
# -- WHY THIS IS NOT A SEARCH-INDEX SPLIT SUMMARY -----------------------------
# A split summary of a text index carries a doc-id range and no time range. The
# one thing this dataset needs is a time range: it is what lets "the last 200
# lines", the most common log query, prune to the few objects that can hold
# them instead of fetching EVERY live object. So the body is its own type, with
# the time range as the pruning key.
#
# What is reused is the SUBSTRATE and the SEMANTICS: `CasManifestStore` for the
# append/replay/tombstone lifecycle, and the merge-input skip set below for
# compaction.
#
# -- `merge_input_uuids` IS NOT OPTIONAL AND IS NOT DEAD WEIGHT ---------------
# It is the compaction dup-window mechanism. During the publish -> tombstone
# window a merged segment AND its inputs are BOTH live, and a reader that does
# not skip absorbed inputs DOUBLE-COUNTS EVERY ROW. On a metrics dashboard that
# is a silently doubled rate; in logs it is every line twice. Do not drop this
# field because compaction "looks atomic": the window is real.
#
# -- ENCODING -----------------------------------------------------------------
# A dependency-free fixed binary envelope, the same discipline as the
# manifest's own chunk encoding. No JSON, no serde import. Every reader is
# FAIL-LOUD: a truncated or unknown-version body RAISES. A codec that folds a
# short read to a zero-valued entry publishes `[min_ts=0,max_ts=0]`, which
# prunes IN for every query and OUT of every correct answer.
#
# NO POINTER CROSSES A MODULE BOUNDARY. POD + owned (`String` / `InlineArray` /
# `List[UInt8]` / `Int64` / `Bool`).
# =============================================================================


comptime TELEMETRY_SEGMENT_ENTRY_VERSION: UInt8 = 2
"""Body schema version. A decoder REFUSES an unknown version rather than
guessing a field layout.

Version 1 is permanently reserved and is refused BY NAME. It was stamped by two
different field orders:

    layout A: [ver][uuid16][LP object_key][min_ts][max_ts][min_sid][max_sid]
              [rows][bytes][merge_ops][LP merge_uuids][sidecar]
    layout B: [ver][uuid16][min_ts][max_ts][min_sid][max_sid][rows][bytes]
              [merge_ops][sidecar][LP object_key][LP merge_uuids]

Because the version bytes agreed, neither decoder refused the other's bytes: a
cross-decode can return without raising and report a range built from the
object key's length prefix and text bytes, a range overlapping every query. No
error, wrong data. So `1` is an ambiguity, not a layout, and `decode` refuses
it rather than picking one of the two.

NEVER REUSE 1. A future format goes to 3."""

comptime TELEMETRY_SEGMENT_ENTRY_VERSION_AMBIGUOUS: UInt8 = 1
"""The burned version. Named, not inlined, so the refusal below cannot drift
from the constant it is about."""

comptime TELEMETRY_UUID_BYTES: Int = 16


# =============================================================================
# §1 — little-endian primitives (the CAS manifest's own conventions).
# =============================================================================


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error(
            "telemetry segment entry: truncated i64 at offset "
            + String(off)
            + " (corrupt body)"
        )
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def _put_lp_str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    _put_i64_le(out, Int64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _get_lp_str(bytes: List[UInt8], mut off: Int) raises -> String:
    var n = Int(_get_i64_le(bytes, off))
    off += 8
    if n < 0:
        raise Error("telemetry segment entry: negative length-prefix (corrupt)")
    if off + n > len(bytes):
        raise Error(
            "telemetry segment entry: truncated length-prefixed field ("
            + String(off + n)
            + " > "
            + String(len(bytes))
            + "; corrupt body)"
        )
    var raw = List[UInt8](capacity=n)
    for i in range(n):
        raw.append(bytes[off + i])
    off += n
    return String(StringSlice(unsafe_from_utf8=Span(raw)))


# =============================================================================
# §2 — the entry.
# =============================================================================


@fieldwise_init
struct TelemetrySegmentEntry(Copyable, Movable, Deinitable):
    """One published telemetry segment's catalog entry — the opaque CAS-manifest
    chunk body for the `logs` and `metrics` datasets.

    Fields, and what each one is FOR:

      version           body schema version (= TELEMETRY_SEGMENT_ENTRY_VERSION).
      segment_uuid      16 bytes; also the tail of `object_key`'s basename, and
                        the identity a merge names in `merge_input_uuids`.
      object_key        the FULL `.parquet` key. A reader GETs EXACTLY this —
                        it is never reconstructed from parts, so a layout change
                        cannot orphan already-published data.
      min_ts_ns/max_ts_ns
                        THE PRUNING KEY. Inclusive, closed. It is the reason a
                        time-range read can skip an object WITHOUT FETCHING IT.
      min_series_id/max_series_id
                        metrics' second pruning axis (sort key `(series_id, ts)`).
                        ZERO/ZERO for logs, whose sort key is `(ts)` alone.
      row_count         rows in the object.
      byte_size         bytes PUT — the compactor's selection input.
      merge_ops         0 = raw, >0 = produced by compaction (its maturity).
      merge_input_uuids FLAT 16-byte groups. The dup-window skip set; see the
                        header. Empty for a raw segment.
      has_text_sidecar  whether `telemetry_text_sidecar_key(object_key)` exists.
                        The sidecar's key is DERIVED, so this one bit is all a
                        reader needs — no second manifest, no pairing LIST.

    POD + owned; no pointers, no Slab, no heap-owning byte-slab element."""

    var version: UInt8
    var segment_uuid: InlineArray[UInt8, TELEMETRY_UUID_BYTES]
    var object_key: String
    var min_ts_ns: Int64
    var max_ts_ns: Int64
    var min_series_id: Int64
    var max_series_id: Int64
    var row_count: Int64
    var byte_size: Int64
    var merge_ops: Int64
    var merge_input_uuids: List[UInt8]
    var has_text_sidecar: Bool

    @always_inline
    def is_merged(self) -> Bool:
        return self.merge_ops > Int64(0)

    @always_inline
    def num_merge_inputs(self) -> Int:
        return len(self.merge_input_uuids) // TELEMETRY_UUID_BYTES

    def overlaps_time(self, t0_ns: Int64, t1_ns: Int64) -> Bool:
        """THE FILE-LEVEL PRUNE. Does this segment's CLOSED [min_ts,max_ts]
        intersect the CLOSED query range [t0,t1]?

        Deliberately INCLUSIVE at both ends, because a row exactly at `t1` is in
        the answer and an exclusive comparison would drop the object holding it.

        IT IS A `can_match`, NOT A `does_match`, AND THE ASYMMETRY IS
        LOAD-BEARING. True only says the ranges intersect; rows are still
        filtered after decode. A gate that could return False for a segment
        holding a matching row would LOSE DATA silently, so the test is
        deliberately the conservative one.

        Named `overlaps_time`, not `overlaps`: it says which AXIS, because there
        is a second one directly below."""
        return not (self.max_ts_ns < t0_ns or self.min_ts_ns > t1_ns)

    def overlaps_series(self, lo: Int64, hi: Int64) -> Bool:
        """The metrics-only series prune, same conservative shape.

        A LOG ENTRY CARRIES `0/0` AND WOULD BE PRUNED BY ANY NON-ZERO FILTER.
        A planner must apply this ONLY when the caller supplied a series
        filter; calling it unguarded on the log dataset returns zero
        segments for a bucket full of them."""
        return not (self.max_series_id < lo or self.min_series_id > hi)


def make_raw_segment_entry(
    var object_key: String,
    min_ts_ns: Int64,
    max_ts_ns: Int64,
    row_count: Int64,
    byte_size: Int64,
    segment_uuid: InlineArray[UInt8, TELEMETRY_UUID_BYTES],
) raises -> TelemetrySegmentEntry:
    """A RAW (uncompacted) log entry with the key first and no sidecar flag.

    IT IS `make_log_segment_entry` WITH THE ARGUMENTS SHUFFLED AND IT
    DELEGATES TO IT: it does not re-implement the field defaults. A second
    place that decides what `merge_ops`/`min_series_id` are for a raw segment
    is a defect waiting."""
    return make_log_segment_entry(
        segment_uuid.copy(),
        object_key^,
        min_ts_ns,
        max_ts_ns,
        row_count,
        byte_size,
        False,
    )


def make_log_segment_entry(
    var segment_uuid: InlineArray[UInt8, TELEMETRY_UUID_BYTES],
    var object_key: String,
    min_ts_ns: Int64,
    max_ts_ns: Int64,
    row_count: Int64,
    byte_size: Int64,
    has_text_sidecar: Bool,
) raises -> TelemetrySegmentEntry:
    """A RAW (`merge_ops = 0`) entry for a `logs` segment.

    `min_series_id`/`max_series_id` are ZERO: logs sort on `(ts)` alone and have
    no series axis. They are carried anyway so ONE body type serves both
    datasets: one container, two schemas."""
    if max_ts_ns < min_ts_ns:
        raise Error(
            "telemetry segment entry: max_ts_ns < min_ts_ns ("
            + String(max_ts_ns)
            + " < "
            + String(min_ts_ns)
            + ") — an inverted range prunes IN for nothing and OUT for"
            " everything"
        )
    if row_count <= Int64(0):
        raise Error(
            "telemetry segment entry: row_count="
            + String(row_count)
            + " — an empty segment must not be published; its [min,max] would"
            " be meaningless and a reader would GET an object with no rows"
        )
    return TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION,
        segment_uuid^,
        object_key^,
        min_ts_ns,
        max_ts_ns,
        Int64(0),
        Int64(0),
        row_count,
        byte_size,
        Int64(0),
        List[UInt8](),
        has_text_sidecar,
    )


def make_metric_segment_entry(
    var segment_uuid: InlineArray[UInt8, TELEMETRY_UUID_BYTES],
    var object_key: String,
    min_ts_ns: Int64,
    max_ts_ns: Int64,
    min_series_id: Int64,
    max_series_id: Int64,
    row_count: Int64,
    byte_size: Int64,
) raises -> TelemetrySegmentEntry:
    """A RAW (`merge_ops = 0`) entry for a `metrics` segment, the SECOND
    dataset of "one container, two schemas".

    THE ONE THING THAT DIFFERS FROM `make_log_segment_entry` IS THE SERIES
    AXIS, AND IT IS THE WHOLE REASON THE TWO DATASETS ARE SEPARATE. `metrics`
    sorts `(series_id, ts)`; `logs` sorts `(ts)` alone. So a metrics entry
    carries a REAL `[min_series_id, max_series_id]` where a log entry carries
    0/0, and a reader with a series filter prunes on it before fetching a byte.

    `has_text_sidecar` IS NOT A PARAMETER, AND ITS ABSENCE IS THE POINT. The
    metrics dataset has no text sidecar: a metric point has no message to index. Accepting the flag here would let a
    caller set a bit whose derived key (`telemetry_text_sidecar_key`) names an
    object nothing ever writes, and a reader that trusted it would GET a 404 and
    fold it to "no matches".

    THE SERIES RANGE IS REFUSED WHEN INVERTED, for the same reason the time
    range is: `overlaps_series` answers False for every filter against an
    inverted range, so the segment would be invisible to every series-filtered
    query forever rather than noisy once."""
    if max_ts_ns < min_ts_ns:
        raise Error(
            "telemetry segment entry: max_ts_ns < min_ts_ns ("
            + String(max_ts_ns)
            + " < "
            + String(min_ts_ns)
            + ") — an inverted range prunes IN for nothing and OUT for"
            " everything"
        )
    if max_series_id < min_series_id:
        raise Error(
            "telemetry segment entry: max_series_id < min_series_id ("
            + String(max_series_id)
            + " < "
            + String(min_series_id)
            + ") — an inverted series range makes the segment invisible to"
            " every series-filtered query rather than noisy once"
        )
    if row_count <= Int64(0):
        raise Error(
            "telemetry segment entry: row_count="
            + String(row_count)
            + " — an empty segment must not be published; its [min,max] would"
            " be meaningless and a reader would GET an object with no rows"
        )
    return TelemetrySegmentEntry(
        TELEMETRY_SEGMENT_ENTRY_VERSION,
        segment_uuid^,
        object_key^,
        min_ts_ns,
        max_ts_ns,
        min_series_id,
        max_series_id,
        row_count,
        byte_size,
        Int64(0),
        List[UInt8](),
        False,
    )


# =============================================================================
# §3 — the codec. FAIL-LOUD in both directions.
# =============================================================================


def encode_telemetry_segment_entry(
    e: TelemetrySegmentEntry,
) -> List[UInt8]:
    """Serialize to the fixed binary envelope. Field order is the struct's."""
    var out = List[UInt8]()
    out.append(e.version)
    for i in range(TELEMETRY_UUID_BYTES):
        out.append(e.segment_uuid[i])
    _put_lp_str(out, e.object_key)
    _put_i64_le(out, e.min_ts_ns)
    _put_i64_le(out, e.max_ts_ns)
    _put_i64_le(out, e.min_series_id)
    _put_i64_le(out, e.max_series_id)
    _put_i64_le(out, e.row_count)
    _put_i64_le(out, e.byte_size)
    _put_i64_le(out, e.merge_ops)
    _put_i64_le(out, Int64(len(e.merge_input_uuids)))
    for i in range(len(e.merge_input_uuids)):
        out.append(e.merge_input_uuids[i])
    out.append(UInt8(1) if e.has_text_sidecar else UInt8(0))
    return out^


def decode_telemetry_segment_entry(
    body: List[UInt8],
) raises -> TelemetrySegmentEntry:
    """Parse the envelope. RAISES on an empty, truncated, or unknown-version
    body — never returns a zero-valued entry.

    A zero-valued entry would carry `[min_ts=0, max_ts=0]`, which
    `overlaps_time()` answers TRUE for any range containing the epoch and FALSE for
    every real one. A codec that folds a bad read to a default is therefore not
    'lenient'; it is a pruning oracle that lies."""
    if len(body) == 0:
        raise Error("telemetry segment entry: empty body (corrupt chunk)")
    var version = body[0]
    if version == TELEMETRY_SEGMENT_ENTRY_VERSION_AMBIGUOUS:
        # THE RESERVED VERSION. Refused BY NAME, ahead of the generic
        # unknown-version arm, because "version 1" is not an old format this
        # build could be taught to read: it is two formats that were never
        # distinguishable from each other.
        raise Error(
            "telemetry segment entry: REFUSING body version 1 ("
            + String(len(body))
            + "-byte body). Version 1 is AMBIGUOUS: two incompatible field"
            " orders were both published under it ([ver][uuid][LP"
            " object_key][min_ts]... and"
            " [ver][uuid][min_ts]...[sidecar][LP object_key])."
            " Decoding it would pick one at random and return a plausible"
            " entry with a wrong time range and a wrong object key, RAISING"
            " NOTHING. This build writes and reads version "
            + String(Int(TELEMETRY_SEGMENT_ENTRY_VERSION))
            + " only. Re-publish the segment; do not try to read this chunk."
        )
    if version != TELEMETRY_SEGMENT_ENTRY_VERSION:
        raise Error(
            "telemetry segment entry: unknown body version "
            + String(Int(version))
            + " (this build understands "
            + String(Int(TELEMETRY_SEGMENT_ENTRY_VERSION))
            + ") — refusing to guess the field layout"
        )
    var off = 1
    if off + TELEMETRY_UUID_BYTES > len(body):
        raise Error("telemetry segment entry: truncated segment_uuid")
    var uuid = InlineArray[UInt8, TELEMETRY_UUID_BYTES](fill=UInt8(0))
    for i in range(TELEMETRY_UUID_BYTES):
        uuid[i] = body[off + i]
    off += TELEMETRY_UUID_BYTES
    var object_key = _get_lp_str(body, off)
    var min_ts = _get_i64_le(body, off)
    off += 8
    var max_ts = _get_i64_le(body, off)
    off += 8
    var min_sid = _get_i64_le(body, off)
    off += 8
    var max_sid = _get_i64_le(body, off)
    off += 8
    var row_count = _get_i64_le(body, off)
    off += 8
    var byte_size = _get_i64_le(body, off)
    off += 8
    var merge_ops = _get_i64_le(body, off)
    off += 8
    var n_merge = Int(_get_i64_le(body, off))
    off += 8
    if n_merge < 0 or off + n_merge > len(body):
        raise Error(
            "telemetry segment entry: truncated merge_input_uuids (corrupt)"
        )
    if n_merge % TELEMETRY_UUID_BYTES != 0:
        raise Error(
            "telemetry segment entry: merge_input_uuids length "
            + String(n_merge)
            + " is not a multiple of "
            + String(TELEMETRY_UUID_BYTES)
            + " (corrupt) — a partial uuid would make the dup-window skip"
            " match the wrong segment"
        )
    var merge_inputs = List[UInt8](capacity=n_merge)
    for i in range(n_merge):
        merge_inputs.append(body[off + i])
    off += n_merge
    if off + 1 > len(body):
        raise Error("telemetry segment entry: truncated has_text_sidecar flag")
    var has_sidecar = body[off] != UInt8(0)
    # `make_log_segment_entry` refuses an inverted range at PUBLISH time, but a
    # compacted entry and a hand-built one both bypass that constructor, so the
    # only place that covers every entry is here. An inverted range never
    # overlaps any query, so the segment is invisible forever rather than noisy
    # once — which is the same "prunes itself out of every query" failure the
    # header is about, arrived at from a different direction.
    if max_ts < min_ts:
        raise Error(
            "telemetry segment entry: inverted time range for '"
            + object_key
            + "' (min_ts_ns="
            + String(min_ts)
            + " > max_ts_ns="
            + String(max_ts)
            + ") — REFUSED: such a segment would never overlap any query and"
            " would be invisible forever rather than noisy once"
        )
    return TelemetrySegmentEntry(
        version,
        uuid^,
        object_key^,
        min_ts,
        max_ts,
        min_sid,
        max_sid,
        row_count,
        byte_size,
        merge_ops,
        merge_inputs^,
        has_sidecar,
    )


def uuid_in_flat(flat: List[UInt8], u: InlineArray[UInt8, TELEMETRY_UUID_BYTES]) -> Bool:
    """Is `u` one of the 16-byte groups in `flat`? The merge-input skip-set
    membership test."""
    var n = len(flat) // TELEMETRY_UUID_BYTES
    for g in range(n):
        var base = g * TELEMETRY_UUID_BYTES
        var hit = True
        for i in range(TELEMETRY_UUID_BYTES):
            if flat[base + i] != u[i]:
                hit = False
                break
        if hit:
            return True
    return False
