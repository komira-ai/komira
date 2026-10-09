# =============================================================================
# komira_objectstore/path.mojo — normalized object-storage Path
# =============================================================================
#
# Mojo equivalent of Rust's `object_store::path::Path`. A normalized,
# `/`-delimited, percent-DECODED sequence of path segments WITHOUT a leading
# slash. The backend re-encodes per its URL rules at request time (each
# backend's signing layer / URL builder owns the encoding).
#
# Properties enforced by `parse`:
#   * leading `/` is stripped (and runs of leading `/` collapse to none)
#   * trailing `/` is PRESERVED (directory-prefix marker — semantic
#     distinction between `s3://bucket/a` (object key) and `s3://bucket/a/`
#     (directory prefix used by `list_with_delimiter`))
#   * empty segments (`//`) are collapsed to a single `/`
#   * `.` segments are rejected (malformed)
#   * `..` segments are rejected (malformed — no path traversal allowed)
#   * empty path after normalization yields the root Path (allowed; bucket-
#     root listing case)
#
# Directory vs file distinction (the `list_with_delimiter` callsites
# depend on it): a trailing `/` is preserved by `parse`
# because S3/GCS/Azure treat it as a directory-style prefix in
# `list_with_delimiter`. `is_dir()` returns True iff the raw form ends with
# `/` OR the path is the root (`""`).
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public method signature.
#   * ZERO wildcard origins.
#   * Backing store is a single owned `String`; no raw pointer fields.
#   * Internal byte ops use `s.as_bytes()` (`Span[Byte, _]`) — never
#     `unsafe_ptr()` directly in a public path.
# =============================================================================


@fieldwise_init
struct Path(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Normalized object-storage path.

    Invariants (post-`parse`):
      * no leading `/`
      * no `.` or `..` segments (those raise `parse`)
      * no `//` (collapsed to `/`)
      * trailing `/` preserved iff the original input had one (directory hint)

    The empty Path (`""`) represents the bucket root — valid for prefix /
    listing operations.
    """

    var _raw: String

    @staticmethod
    def parse(s: String) raises -> Path:
        """Parse + normalize. Raises on a malformed path (fail fast).

        Rejects: `.` / `..` segments anywhere in the path.
        Collapses: runs of `/` to a single `/`.
        Strips: leading `/` (any number).
        Preserves: a trailing `/` (if present and the path is non-empty
        after normalization) — directory-prefix semantics for
        `list_with_delimiter`.
        """
        var bs = s.as_bytes()
        var n = len(bs)
        if n == 0:
            return Path(String(""))

        # Strip leading `/` runs.
        var start = 0
        var slash = UInt8(ord("/"))
        while start < n and bs[start] == slash:
            start += 1
        if start >= n:
            # All slashes — bucket root.
            return Path(String(""))

        # Detect trailing slash (after lead-strip).
        var had_trailing = bs[n - 1] == slash

        # Find the inclusive end of non-slash content (trim trailing slashes
        # for segment splitting; we'll reattach the trailing `/` later).
        var end = n
        while end > start and bs[end - 1] == slash:
            end -= 1
        if end <= start:
            return Path(String(""))  # cov: unreachable bs[start] is not '/' after the lead strip, so end > start

        # Walk segments, collapsing runs of `/` and rejecting `.` / `..`.
        # PERF/SAFETY (multi-threaded conditional-store callers):
        # build the normalized output into a single pre-sized `List[UInt8]`
        # byte buffer and materialize the String ONCE at the end, instead of
        # the prior per-byte `seg += chr(...)` + `out += seg` String churn.
        # The old form did O(path_len) tiny String reallocations PER key build,
        # PER request — under K>=4 concurrent writers that high-volume small-
        # allocation churn through the bundled tcmalloc was the dominant
        # central-freelist pressure source the CAS contention amplified. One
        # pre-sized buffer + one String build collapses that to O(1)
        # allocations per parse. Byte-identical output (same normalization).
        var out_bytes = List[UInt8](capacity=end - start + 1)
        var seg_start = start
        var first = True
        var i = start
        while i <= end:
            if i == end or bs[i] == slash:
                if i > seg_start:
                    # Segment is bytes [seg_start, i). Reject `.` / `..`
                    # without materializing a String (compare bytes).
                    var seg_len = i - seg_start
                    var is_dot = seg_len == 1 and bs[seg_start] == UInt8(
                        ord(".")
                    )
                    var is_dotdot = (
                        seg_len == 2
                        and bs[seg_start] == UInt8(ord("."))
                        and bs[seg_start + 1] == UInt8(ord("."))
                    )
                    if is_dot or is_dotdot:
                        raise Error(
                            "Path: rejected '.' or '..' segment in: " + s
                        )
                    if not first:
                        out_bytes.append(slash)
                    for j in range(seg_start, i):
                        out_bytes.append(bs[j])
                    first = False
                seg_start = i + 1
            i += 1

        if had_trailing and len(out_bytes) > 0:
            out_bytes.append(slash)
        return Path(String(StringSlice(unsafe_from_utf8=Span[UInt8](out_bytes))))

    @always_inline
    def raw(self) -> String:
        """Return the normalized raw string (may be empty for root)."""
        return String(self._raw)

    @always_inline
    def is_root(self) -> Bool:
        """True iff this is the empty / bucket-root Path."""
        return self._raw.byte_length() == 0

    @always_inline
    def is_dir(self) -> Bool:
        """True iff this Path represents a directory-style prefix.

        Root is treated as a directory; otherwise, the raw form must end
        with `/`. This is the `list_with_delimiter` discriminant.
        """
        if self.is_root():
            return True
        var bs = self._raw.as_bytes()
        return bs[len(bs) - 1] == UInt8(ord("/"))

    def child(self, segment: String) raises -> Path:
        """Append a single segment. The segment must NOT contain `/` and
        must NOT be `.` or `..`. The result is a non-directory Path
        (no trailing `/`).
        """
        if segment.byte_length() == 0:
            raise Error("Path.child: empty segment")
        if segment == "." or segment == "..":
            raise Error("Path.child: rejected '.' or '..' segment")
        var slash = UInt8(ord("/"))
        var sb = segment.as_bytes()
        for i in range(len(sb)):
            if sb[i] == slash:
                raise Error("Path.child: segment must not contain '/'")
        if self.is_root():
            return Path(String(segment))
        var rb = self._raw.as_bytes()
        if rb[len(rb) - 1] == slash:
            # Already trailing-slash: just append.
            return Path(self._raw + segment)
        return Path(self._raw + "/" + segment)

    def prefix_matches(self, prefix: Path) -> Bool:
        """True iff `self`'s segment sequence starts with `prefix`'s segments.

        The comparison is segment-aligned: prefix `"foo"` matches `"foo/bar"`
        but NOT `"foobar"`. The root prefix matches every Path.
        """
        if prefix.is_root():
            return True
        var slash = UInt8(ord("/"))
        var pb = prefix._raw.as_bytes()
        var sb = self._raw.as_bytes()
        # Strip trailing `/` from prefix for comparison.
        var plen = len(pb)
        if plen > 0 and pb[plen - 1] == slash:
            plen -= 1
        var slen = len(sb)
        if slen > 0 and sb[slen - 1] == slash:
            slen -= 1
        if slen < plen:
            return False
        var i = 0
        while i < plen:
            if sb[i] != pb[i]:
                return False
            i += 1
        # If self is longer, the byte at plen must be `/` (segment boundary).
        if slen > plen:
            return sb[plen] == slash
        return True

    def filename(self) -> String:
        """Return the last segment, or empty string for root / directory paths.

        A directory Path (trailing `/`) has no filename — returns empty.
        """
        if self.is_root() or self.is_dir():
            return String("")
        var bs = self._raw.as_bytes()
        var n = len(bs)
        var slash = UInt8(ord("/"))
        # Find the last `/`.
        var i = n
        while i > 0:
            i -= 1
            if bs[i] == slash:
                # Filename = bytes (i+1 .. n), BYTE-EXACT. ⛔ NOT
                # `out += chr(Int(bs[j]))` — `chr` maps a CODE POINT to its
                # UTF-8 ENCODING, so a stored byte >= 0x80 was RE-ENCODED into
                # two and the returned filename would be a name that exists
                # nowhere. `Path.parse` above (the `out_bytes` build) is
                # byte-exact too; the two must agree.
                var out_bytes = List[UInt8]()
                for j in range(i + 1, n):
                    out_bytes.append(bs[j])
                return String(StringSlice(unsafe_from_utf8=Span(out_bytes)))
        # No slash at all — whole raw IS the filename.
        return String(self._raw)

    def __str__(self) -> String:
        return String(self._raw)

    def __eq__(self, other: Path) -> Bool:
        return self._raw == other._raw

    def __ne__(self, other: Path) -> Bool:
        return self._raw != other._raw
