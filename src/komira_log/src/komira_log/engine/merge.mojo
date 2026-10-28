# =============================================================================
# komira_log.engine.merge — log-merge k-way timestamp merge (P3).
# =============================================================================
#
# The read-side merge for the per-core-segments output model. Each core writes
# its own `{base}.core{N}.log` segment, already in per-core timestamp order (a
# core drains its own ring in order). The global chronological view is a
# standard k-way merge of those already-sorted streams — O(records · log N),
# no full sort. The merge lives ENTIRELY on the read side: zero hot/drain-path
# coordination cost.
#
# # The sort key — the rendered ISO-8601 timestamp prefix
#
# Each line is `YYYY-MM-DDThh:mm:ss.mmmZ LEVEL [module] message ...`
# (pattern_layout.format_timestamp_ms). The leading fixed-width, zero-padded
# ISO-8601 timestamp is **lexicographically chronological** — comparing the
# leading timestamp token as a String orders the lines by wall-time exactly,
# with no parse-to-int needed. (All segments derive their wall-time from the
# SAME system-wide invariant counter via the shared anchor —
# so cross-core ordering by this key is correct to within the per-core drain
# skew.)
#
# # API
#
# `merge_segment_lines(segments: List[List[String]]) -> List[String]` is the
# pure core: N already-sorted line streams → one globally-ordered stream. The
# log-merge CLI / `merge_segment_files(paths)` convenience reads the files
# and calls it. The follow (`-f`) mode is the same merge over a tail-loop
# (conceptual; the batch merge is the load-bearing piece + what the test pins).
#
# # Encapsulation
#
# Pure value flow over owned `List[String]` / `List[List[String]]`. No
# `UnsafePointer`, no wildcard origin, no fd handling here (the caller reads the
# files; this module merges already-materialized lines).
# =============================================================================

from std.io import FileHandle


# -----------------------------------------------------------------------------
# Extract the leading timestamp token (up to the first space) — the merge key.
# A line with no space sorts by the whole line. Lexicographic comparison of this
# fixed-width ISO-8601 prefix is chronological.
# -----------------------------------------------------------------------------


def _ts_key(line: String) -> String:
    var b = line.as_bytes()
    var k = 0
    while k < len(b) and b[k] != UInt8(ord(" ")):
        k += 1
    # BYTE-EXACT. ⛔ NOT `out += chr(Int(b[i]))` — `chr` maps a CODE POINT to
    # its UTF-8 ENCODING and RE-ENCODES every byte >= 0x80 into two. A
    # well-formed line's key IS an ASCII timestamp, but the documented fallback
    # ("a line with no space sorts by the whole line") makes the WHOLE LINE the
    # key, and a log line is not ASCII. ⚠ The doubling happens to be
    # ORDER-PRESERVING (0x80-0xBF -> C2 xx, 0xC0-0xFF -> C3 xx, both monotone
    # and above every ASCII byte), so no merge ORDER was observably wrong — but
    # the function returned bytes that are not the ones it claims to return, and
    # that is what the next reader copies.
    var key = List[UInt8]()
    for i in range(k):
        key.append(b[i])
    return String(StringSlice(unsafe_from_utf8=Span(key)))


@always_inline
def _key_lt(a: String, b: String) -> Bool:
    """`a < b` lexicographically (String has no built-in <; compare bytes)."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(n):
        if ab[i] < bb[i]:
            return True
        if ab[i] > bb[i]:
            return False
    return len(ab) < len(bb)


# -----------------------------------------------------------------------------
# merge_segment_lines — the pure k-way merge. Each input stream is assumed
# already sorted by `_ts_key` (per-core timestamp order). Returns the globally
# chronological stream.
#
# Implementation: a simple N-way min-cursor merge (N is the core count, small —
# a bounded scan per output record is fine; a heap is the O(log N) refinement
# the design names but unnecessary at realistic N). Stable: ties keep
# lower-core-index order.
# -----------------------------------------------------------------------------


def merge_segment_lines(segments: List[List[String]]) -> List[String]:
    var n = len(segments)
    var out = List[String]()
    # Per-segment read cursor.
    var cursors = List[Int]()
    var total = 0
    for s in range(n):
        cursors.append(0)
        total += len(segments[s])

    for _ in range(total):
        # Pick the segment whose head line has the smallest ts key. Stable:
        # only REPLACE the running best on a STRICTLY-smaller key, so equal
        # keys keep the lower segment index (lower core wins ties).
        var best = -1
        var best_key = String("")
        for s in range(n):
            if cursors[s] >= len(segments[s]):
                continue
            var key = _ts_key(segments[s][cursors[s]])
            if best == -1:
                best = s
                best_key = key^
            elif _key_lt(key, best_key):
                best = s
                best_key = key^
        if best == -1:
            break  # cov: unreachable the loop runs once per input line and each pass takes one, so some cursor always has a line left
        out.append(segments[best][cursors[best]])
        cursors[best] = cursors[best] + 1

    return out^


# -----------------------------------------------------------------------------
# File-reading convenience: read each segment file into its lines, then merge.
# -----------------------------------------------------------------------------


def _read_lines(path: String) raises -> List[String]:
    var f = FileHandle(path, "r")
    var content = String(f.read())
    var lines = List[String]()
    # BYTE-EXACT line split. ⛔ NOT `cur += chr(Int(b[i]))` — `chr` maps a CODE
    # POINT to its UTF-8 ENCODING, so every byte >= 0x80 of a log line would be
    # RE-ENCODED into two and the MERGED output would be a mojibaked copy of its
    # inputs. The record boundary is a single ASCII `\n`, so the
    # only correct handling of the payload is to copy its bytes through.
    #
    var cur = List[UInt8]()
    var b = content.as_bytes()
    var nl = UInt8(ord("\n"))
    for i in range(len(b)):
        if b[i] == nl:
            lines.append(String(StringSlice(unsafe_from_utf8=Span(cur))))
            cur = List[UInt8]()
        else:
            cur.append(b[i])
    # A trailing partial line (no newline) is still a record.
    if len(cur) > 0:
        lines.append(String(StringSlice(unsafe_from_utf8=Span(cur))))
    return lines^


def merge_segment_files(paths: List[String]) raises -> List[String]:
    """Read each `{base}.core{N}.log` segment + k-way-timestamp-merge them into
    one globally chronological stream. The batch form of log-merge."""
    var segments = List[List[String]]()
    for i in range(len(paths)):
        segments.append(_read_lines(paths[i]))
    return merge_segment_lines(segments)
