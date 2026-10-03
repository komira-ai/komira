# =============================================================================
# komira_fs.glob — pure glob pattern-matching engine
# =============================================================================
# Pure-function module. NO filesystem dispatch, NO I/O — only string/pattern
# logic. The discovery layer (the FileDiscovery trait + impls) drives
# `fs.list` against the static prefix this module computes, then filters the
# candidates client-side via `glob_match_path`.
#
# Glob syntax = POSIX glob + `**` globstar + `{a,b}` braces:
#   * `*` `?` `[abc]` `[a-z]` `[!abc]` `[[:digit:]]` ... — POSIX per-segment,
#     delegated to libc `fnmatch()`. We do NOT reimplement the
#     character-class / collation / negation long tail; libc gets it right.
#   * `**` — recursive globstar (zero-or-more path segments); at most ONE per
#     pattern (mirrors DuckDB `HasMultipleCrawl`). Built in the Mojo layer.
#   * `{a,b,c}` — brace alternation, cartesian across multiple groups;
#     pre-expanded to N patterns before discovery. A differentiator
#     (DuckDB lacks braces). Built in the Mojo layer.
#
# Pointer discipline:
#   * NO UnsafePointer in any public signature.
#   * The ONE raw-pointer site is `_fnmatch_segment`, which derives a NUL-
#     terminated C string from a caller-owned local `String` and hands it to
#     libc `fnmatch` via `external_call`. The pointer lives and dies inside
#     that helper (a `# SAFETY:` block documents the contract); no pointer
#     crosses a module boundary.
#   * safe across destroy-recreate by construction: every function here is pure (no struct
#     fields, no byte-slab storage, no wildcard origins).
# =============================================================================

from std.ffi import external_call


# =============================================================================
# fnmatch(3) flag constants.
# =============================================================================
# These are the POSIX-mandated bit positions, stable across glibc (Linux) and
# the BSD/macOS libc (the two toolchain targets).
# We match a SINGLE path segment at a time (the `**`
# walk owns cross-segment matching), so:
#   * FNM_PATHNAME is NOT set — a single segment never contains `/`, so the
#     "`*` does not match `/`" rule is moot, and leaving it off keeps the
#     semantics uniform between the two libcs.
#   * FNM_PERIOD is set per the dispatch brief — a leading `.` in the name
#     must be matched explicitly by a leading `.` in the pattern (POSIX
#     hidden-file rule). Hive segments like `dt=2026-11-04` never start with
#     `.`, and `part-0.parquet` has its `.` mid-segment (unaffected), so this
#     is the safe POSIX default.
#   * FNM_NOESCAPE is NOT set, so `\` escaping works per POSIX.
#
# Linux glibc <fnmatch.h>:  NOESCAPE=1<<1, PATHNAME=1<<0, PERIOD=1<<2
# BSD/macOS <fnmatch.h>:    NOMATCH=1, NOESCAPE=0x01, PATHNAME=0x02,
#                           PERIOD=0x04
# The PERIOD bit differs between the two libcs (Linux 0x04 vs BSD 0x04 — both
# 0x04 in practice for PERIOD); we use the glibc value 0x04 which matches BSD.
# =============================================================================
comptime FNM_PERIOD: Int32 = 4
comptime FNM_NOMATCH: Int32 = 1


# =============================================================================
# Metachar / separator byte constants (UInt8, to avoid Int->UInt8 implicit
# conversion on every byte comparison — matches the `pod_spec.mojo` idiom of
# `var COLON = UInt8(ord(":"))`).
# =============================================================================
comptime _STAR: UInt8 = UInt8(ord("*"))
comptime _QMARK: UInt8 = UInt8(ord("?"))
comptime _LBRACKET: UInt8 = UInt8(ord("["))
comptime _LBRACE: UInt8 = UInt8(ord("{"))
comptime _RBRACE: UInt8 = UInt8(ord("}"))
comptime _COMMA: UInt8 = UInt8(ord(","))
comptime _SLASH: UInt8 = UInt8(ord("/"))


# =============================================================================
# has_glob: cheap metachar scan.
# =============================================================================


def has_glob(pattern: String) -> Bool:
    """True iff `pattern` contains any glob metacharacter (`* ? [ {`).

    Used by the discovery layer to detect glob-vs-literal-vs-directory before
    doing any work. A pattern with no metachar falls through
    to the single-file / `is_dir` two-way detect (zero behavior change for
    literal paths).

    Note: `=` is NOT a glob
    metachar — Hive layouts must pass through `has_glob` as literals.

    Args:
        pattern: The path-spec string.

    Returns:
        True iff `* ? [ {` appears anywhere in `pattern`.
    """
    var bs = pattern.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        if c == _STAR or c == _QMARK or c == _LBRACKET or c == _LBRACE:
            return True
    return False


# =============================================================================
# brace_expand: {a,b,c} cartesian alternation.
# =============================================================================


def _find_first_brace_group(
    pattern: String,
) -> Tuple[Int, Int]:
    """Locate the FIRST balanced `{...}` group in `pattern`. Returns
    `(open_idx, close_idx)` (byte offsets of `{` and its matching `}`), or
    `(-1, -1)` if there is no balanced brace group.

    Nested braces are handled by depth counting: the matching `}` for the
    FIRST `{` is the one that returns depth to zero. (Inner groups are
    expanded by the recursive `brace_expand` driver, not here.)
    """
    var bs = pattern.as_bytes()
    var open_idx = -1
    for i in range(len(bs)):
        if bs[i] == _LBRACE:
            open_idx = i
            break
    if open_idx < 0:
        return (-1, -1)
    var depth = 0
    for j in range(open_idx, len(bs)):
        if bs[j] == _LBRACE:
            depth += 1
        elif bs[j] == _RBRACE:
            depth -= 1
            if depth == 0:
                return (open_idx, j)
    # Unbalanced `{` with no closing `}` — treat as a literal (no group).
    return (-1, -1)


def _split_top_level_commas(inner: String) -> List[String]:
    """Split `inner` (the text BETWEEN a `{` and its matching `}`) on commas
    that are at brace-depth zero. Commas inside a nested `{...}` belong to the
    inner group and are NOT split here.

    Example: `a,b{c,d},e` -> [`a`, `b{c,d}`, `e`].
    An empty alternative (`{a,,b}`) yields an empty-string element (POSIX/bash
    semantics: `{a,,b}` -> `a`, ``, `b`).
    """
    var out = List[String]()
    var bs = inner.as_bytes()
    var depth = 0
    var seg_start = 0
    for i in range(len(bs)):
        var c = bs[i]
        if c == _LBRACE:
            depth += 1
        elif c == _RBRACE:
            depth -= 1
        elif c == _COMMA and depth == 0:
            out.append(_slice_str(inner, seg_start, i))
            seg_start = i + 1
    out.append(_slice_str(inner, seg_start, len(bs)))
    return out^


def _slice_str(s: String, start: Int, end: Int) -> String:
    """Byte-range slice of `s` -> `s[start:end]` as an owned String, BYTE-EXACT.

    ⛔ DO NOT REWRITE THIS AS `out += chr(Int(bs[i]))`. That was this
    function's body until 2026-09-07, and the docstring above it CLAIMED
    "UTF-8-byte-safe" while the body was the opposite: `chr` maps a CODE POINT
    to its UTF-8 ENCODING, so every stored byte >= 0x80 was RE-ENCODED into
    two. `data/city=Zürich/*.parquet` split to `data/city=ZÃ¼rich/` — and
    `split_static_prefix` feeds that static prefix straight to `fs.list`, so
    the listed prefix DOES NOT EXIST and the glob matches NOTHING. ASCII is
    the corruption's fixed point, which is why the all-ASCII bench corpus
    never saw it.
    """
    var bs = s.as_bytes()
    # `StringSlice(unsafe_from_utf8=)` is the in-tree byte-exact spelling
    # (`komira_core/collections/string_column_view.mojo:145`); LENGTH-EXPLICIT,
    # unlike `String(unsafe_from_utf8_ptr=)`, which stops at the first NUL.
    return String(StringSlice(unsafe_from_utf8=bs[start:end]))


def brace_expand(pattern: String) -> List[String]:
    """Expand `{a,b,c}` brace alternation into N concrete patterns.
    Cartesian across MULTIPLE brace groups; recursive for
    NESTED groups. A pattern with no braces returns `[pattern]` unchanged.

    Examples:
        `x/{a,b}/y`        -> [`x/a/y`, `x/b/y`]
        `{a,b}/{c,d}`      -> [`a/c`, `a/d`, `b/c`, `b/d`]   (cartesian)
        `x/{a,{b,c}}/y`    -> [`x/a/y`, `x/b/y`, `x/c/y`]    (nested)
        `data/part.parquet`-> [`data/part.parquet`]          (no braces)

    Algorithm: find the FIRST balanced `{...}` group, split its inner text on
    top-level commas into alternatives, substitute each alternative back into
    `prefix + alt + suffix`, and recurse on each result (so any remaining or
    nested braces are expanded in turn). Terminates because each recursion
    strips one `{` (the inner text of the consumed group can re-introduce
    braces only from a NESTED group, which is strictly smaller).

    This is a differentiator — DuckDB lacks brace expansion.
    """
    var bs = pattern.as_bytes()
    var grp = _find_first_brace_group(pattern)
    var open_idx = grp[0]
    var close_idx = grp[1]
    if open_idx < 0:
        # No balanced brace group — terminal.
        var out = List[String]()
        out.append(pattern.copy())
        return out^

    var prefix = _slice_str(pattern, 0, open_idx)
    var suffix = _slice_str(pattern, close_idx + 1, len(bs))
    var inner = _slice_str(pattern, open_idx + 1, close_idx)
    var alts = _split_top_level_commas(inner)

    var out = List[String]()
    for ai in range(len(alts)):
        var substituted = prefix + alts[ai] + suffix
        # Recurse: `substituted` may still contain further (cartesian or
        # nested) brace groups.
        var sub_expanded = brace_expand(substituted)
        for si in range(len(sub_expanded)):
            out.append(sub_expanded[si].copy())
    return out^


# =============================================================================
# split_static_prefix: static leading prefix + residual pattern.
# =============================================================================


def split_static_prefix(pattern: String) -> Tuple[String, String]:
    """Split `pattern` at the FIRST path segment that contains a glob
    metachar. Returns `(static_prefix, residual)`:

      * `static_prefix` — the longest LEADING run of complete path segments
        (each ending in `/`) that contain NO glob metachar. This bounds the
        `fs.list` request (object stores have no server-side glob).
      * `residual` — the remainder of the pattern, matched client-side via
        `glob_match_path`.

    Examples:
        `data/year=*/part-*.parquet`  -> (`data/`, `year=*/part-*.parquet`)
        `data/file.parquet`           -> (`data/file.parquet`, ``)  (no glob)
        `*.parquet`                   -> (``, `*.parquet`)  (glob in seg 0)
        `a/b/c/*.parquet`             -> (`a/b/c/`, `*.parquet`)
        `events/**/data.parquet`      -> (`events/`, `**/data.parquet`)

    The static prefix always ends at a `/` boundary (we never split a segment
    mid-way), so the prefix is a valid directory/key prefix for `fs.list`.
    A pattern with no glob at all returns `(pattern, "")` — the whole path is
    the prefix and there is no residual (the caller treats it as a literal).
    """
    var bs = pattern.as_bytes()
    # Walk segments; track the byte index just past the last `/` that bounds a
    # fully-static leading run.
    var prefix_end = 0  # bytes [0, prefix_end) are the static prefix
    var seg_has_glob = False
    for i in range(len(bs)):
        var c = bs[i]
        if c == _STAR or c == _QMARK or c == _LBRACKET or c == _LBRACE:
            seg_has_glob = True
        if c == _SLASH:
            if seg_has_glob:
                # This segment (ending here) had a glob -> the static prefix
                # stops at the PREVIOUS segment boundary (`prefix_end`).
                var static_prefix = _slice_str(pattern, 0, prefix_end)
                var residual = _slice_str(pattern, prefix_end, len(bs))
                return (static_prefix^, residual^)
            # Segment was fully static -> extend the prefix past this `/`.
            prefix_end = i + 1
            seg_has_glob = False

    # Reached end of pattern. The final (trailing) segment had no `/`.
    if seg_has_glob:
        var static_prefix = _slice_str(pattern, 0, prefix_end)
        var residual = _slice_str(pattern, prefix_end, len(bs))
        return (static_prefix^, residual^)
    # No glob anywhere -> whole pattern is the static prefix, empty residual.
    return (pattern.copy(), String())


# =============================================================================
# _fnmatch_segment: POSIX per-segment match via libc fnmatch (FFI).
# =============================================================================


def _fnmatch_segment(pattern: String, name: String) -> Bool:
    """POSIX `fnmatch()` for ONE path segment. Delegates `*`, `?`,
    `[abc]`, `[a-z]`, `[!abc]`, and `[[:digit:]]`-style POSIX character
    classes to libc — correct and free; we do NOT reimplement them.

    FFI-BOUNDARY: libc `fnmatch(const char *pattern, const char *string,
    int flags)`.
    # SAFETY: `c_pat` and `c_name` are NUL-terminated C strings owned by THIS
    # function's stack frame (`pattern` / `name` are borrowed args; the
    # `.as_c_string_slice()` materializes a NUL-terminated view backed by the
    # caller's owned String for the duration of the call). `fnmatch` READS
    # both and never retains either pointer. Neither pointer escapes this
    # function — no UnsafePointer crosses the module boundary. Mirrors the
    # `external_call["fopen"...]` c-string idiom in `local_fs.mojo:88`.

    Returns:
        True iff libc `fnmatch` returns 0 (match). FNM_NOMATCH (and any
        error rc) -> False.
    """
    # `as_c_string_slice` is a mutating method (it NUL-terminates in place), so
    # we materialize owned mutable locals first — matches the `local_fs.mojo`
    # `var path` / `var mode_str` idiom (:88-90). The C strings are backed by
    # THESE locals and outlive the `external_call` (which only reads them).
    var pat_local = pattern.copy()
    var name_local = name.copy()
    var c_pat = pat_local.as_c_string_slice().unsafe_ptr()
    var c_name = name_local.as_c_string_slice().unsafe_ptr()
    var rc = external_call["fnmatch", Int32](c_pat, c_name, FNM_PERIOD)
    return rc == 0


# =============================================================================
# glob_match_path: full path match with `**` globstar handling.
# =============================================================================


def _split_segments(s: String) -> List[String]:
    """Split `s` on `/` into path segments. A trailing `/` yields a trailing
    empty segment (so `dir/` -> [`dir`, ``]); the caller's segment-matching
    handles empties naturally (an empty pattern segment matches only an empty
    name segment via fnmatch)."""
    var out = List[String]()
    for seg in s.split("/"):
        out.append(String(seg))
    return out^


def _count_globstars(segs: List[String]) -> Int:
    """Count segments equal to exactly `**`."""
    var n = 0
    for i in range(len(segs)):
        if segs[i] == String("**"):
            n += 1
    return n


def _match_from(
    pat_segs: List[String],
    pi: Int,
    path_segs: List[String],
    ti: Int,
) -> Bool:
    """Recursive segment-by-segment matcher with `**` globstar support.

    Matches `pat_segs[pi:]` against `path_segs[ti:]`. A `**` pattern segment
    matches ZERO OR MORE path segments: we try consuming 0, 1, 2,
    ... path segments and recurse on the remainder (standard `**` automaton /
    backtrack). All other pattern segments match exactly one path segment via
    `_fnmatch_segment`.
    """
    # Both exhausted -> match.
    if pi == len(pat_segs):
        return ti == len(path_segs)

    if pat_segs[pi] == String("**"):
        # `**` consumes k >= 0 path segments. Try every suffix of path_segs.
        # k = 0 first (zero-segment match: `dir/**/x` matches `dir/x`).
        for k in range(ti, len(path_segs) + 1):
            if _match_from(pat_segs, pi + 1, path_segs, k):
                return True
        return False

    # Non-globstar pattern segment needs exactly one path segment.
    if ti == len(path_segs):
        return False
    if not _fnmatch_segment(pat_segs[pi], path_segs[ti]):
        return False
    return _match_from(pat_segs, pi + 1, path_segs, ti + 1)


def glob_match_path(pattern: String, path: String) raises -> Bool:
    """Full PATH match: split both `pattern` and `path` into `/`
    segments and match segment-by-segment via libc `fnmatch`, with `**`
    globstar handling.

    `**` semantics:
      * Matches ZERO OR MORE path segments — `dir/**/x` matches BOTH `dir/x`
        (zero levels) AND `dir/a/b/x` (two levels).
      * At most ONE `**` per pattern — more than one RAISES (mirrors DuckDB's
        `HasMultipleCrawl` rule).

    Per-segment matching (everything below a `/`) is libc `fnmatch` (POSIX
    `*` `?` `[...]` ranges, `[!...]` negation, `[[:digit:]]` classes).

    Symlink-loop safety is a WALK concern (directory traversal), not a
    match concern — this function is pure pattern logic over already-listed
    candidate paths. The walk that produces `path` candidates is responsible
    for canonicalizing real-paths to break symlink cycles.

    Args:
        pattern: A glob pattern (already brace-expanded — callers run
            `brace_expand` first; a `{` here is matched literally by fnmatch).
        path:    A concrete candidate path (no wildcards).

    Raises:
        If `pattern` contains more than one `**` segment.

    Returns:
        True iff the full path matches the pattern.
    """
    var pat_segs = _split_segments(pattern)
    var path_segs = _split_segments(path)

    var n_globstar = _count_globstars(pat_segs)
    if n_globstar > 1:
        raise Error(
            String(
                "glob_match_path: pattern has more than one '**' globstar"
                " (only one recursive '**' is allowed per pattern): "
            )
            + pattern
        )

    return _match_from(pat_segs, 0, path_segs, 0)
