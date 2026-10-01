# =============================================================================
# komira_async.fs.footer_window_hints — the ADAPTIVE speculative window
# =============================================================================
#
#
# WHY THIS EXISTS
# ---------------
# `FOOTER_SPECULATIVE_WINDOW` is the number of trailing bytes a `read_footer`
# conformer fetches before it knows where the footer starts. A fixed
# constant cannot be right: wide-schema files (ClickBench `hits` at ~2.4 MB,
# the h2o suite at 0.4-1 MB) exceed a 256 KiB window, and on each of those the
# speculation is a guaranteed MISS, which on an object store costs 2 round
# trips plus a wasted transfer: exactly the cost the speculative window
# exists to remove. Footer size is a property of the DATA, so a different
# constant would only go stale the first time someone writes a wider table.
# So the window is learned instead.
#
# THE MODEL
# ---------
# Footer size is a function of (column count x row-group count x whether
# page-index / column-index blobs are present). Those are dataset properties,
# essentially uniform across the files of one dataset and wildly different
# between datasets (TPC-H SF1 `lineitem` 123,815 B vs ClickBench
# `hits_canonical` 2,439,324 B — a 20x spread). So:
#
#   * The hint is keyed by DIRECTORY, not by file. Keying by file would be
#     useless: the session footer cache already memoizes the parsed footer per
#     path, so the same file is never re-fetched within a session. The payoff
#     is entirely on the SIBLINGS — a glob over a 100-file dataset misses once
#     and speculates correctly 99 times.
#   * The hint is stored in the session footer cache (`ParquetMetadataCache`),
#     which is the object whose lifetime is "this SessionContext" and which
#     already owns the miss path. No global mutable state.
#   * Growth is bounded (`FOOTER_WINDOW_MAX`) and quantized
#     (`FOOTER_WINDOW_GRANULARITY`) so N siblings converge on ONE window
#     rather than ratcheting per file.
#
# Cold behaviour is unchanged: an unseen dataset speculates with
# `FOOTER_SPECULATIVE_WINDOW`, so the measured 5.0x-under-RTT hit path is not
# disturbed. The adaptation only changes what happens on the second and later
# files of a dataset whose footers do not fit.
#
# Concurrency: NOT thread-safe, same contract as its owner
# `ParquetMetadataCache` — mutated only from the EngineContext-owning thread,
# on the (serial) footer-miss path.
# =============================================================================

from komira_async.fs.footer_region import (
    FOOTER_SPECULATIVE_WINDOW,
    next_footer_window,
)


def footer_hint_key(path: String) -> String:
    """The dataset key a footer-size hint is filed under: the path's parent
    directory (everything up to and including the last `/`), or the empty
    string for a bare filename.

    Works uniformly for local paths (`/data/tpch/lineitem.parquet` ->
    `/data/tpch/`) and object-store URIs / keys
    (`s3://bucket/hits/part-0.parquet` -> `s3://bucket/hits/`), because the
    only separator either uses is `/`. A partitioned Hive layout keys per LEAF
    directory, which is the right granularity: sibling
    partitions of one table share a schema, so their learned windows agree and
    the per-partition duplication costs only a few list slots.
    """
    var b = path.as_bytes()
    var n = len(b)
    var cut = -1
    for i in range(n):
        if b[n - 1 - i] == UInt8(47):  # '/'
            cut = n - i
            break
    if cut <= 0:
        return String("")
    return String(path[byte=0:cut])


struct FooterWindowHints(Movable, Deinitable):
    """Per-dataset learned speculative-window sizes.

    Two parallel `List`s with a linear-scan lookup, matching the shape of the
    other session-scoped caches in this package. N is the number of DISTINCT
    directories touched by one session — single digits for every bench and
    production shape we have (a 1000-partition Hive scan is the worst case at
    1000 short strings, ~50 KB, still trivial).
    """

    var _keys: List[String]
    var _windows: List[Int]
    var _observe_count: Int
    """Number of `observe` calls that RAISED a key's window (i.e. taught the
    store something). A diagnostic seam: a test that asserts adaptation
    happened must be able to see it, and a correctness-only assertion cannot.
    """

    def __init__(out self):
        self._keys = List[String]()
        self._windows = List[Int]()
        self._observe_count = 0

    def copy(self) -> Self:
        """Deep copy of the hint table."""
        var out = Self()
        out._keys = self._keys.copy()
        out._windows = self._windows.copy()
        out._observe_count = self._observe_count
        return out^

    def _find(self, key: String) -> Int:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return i
        return -1

    def suggest(self, path: String) -> Int:
        """The window to speculate with for `path`.

        `FOOTER_SPECULATIVE_WINDOW` for a dataset this session has never
        observed; otherwise the learned window for `path`'s directory.
        """
        var idx = self._find(footer_hint_key(path))
        if idx < 0:
            return FOOTER_SPECULATIVE_WINDOW
        return self._windows[idx]

    def observe(mut self, path: String, footer_len: Int) -> None:
        """Record that `path`'s footer (metadata blob PLUS the 8-byte trailer)
        was `footer_len` bytes.

        Monotone: a dataset's window only ever grows within a session. A
        shrink would let a large-footer file and a small-footer file in one
        directory oscillate, re-paying the extra round trip forever.
        """
        if footer_len <= 0:
            return
        var want = next_footer_window(footer_len)
        var key = footer_hint_key(path)
        var idx = self._find(key)
        if idx < 0:
            self._keys.append(key)
            self._windows.append(want)
            if want > FOOTER_SPECULATIVE_WINDOW:
                self._observe_count = self._observe_count + 1
            return
        if want > self._windows[idx]:
            self._windows[idx] = want
            self._observe_count = self._observe_count + 1

    def adaptation_count(self) -> Int:
        """How many times a learned window was RAISED above what was already
        known. Zero for a session whose every footer fit the cold default."""
        return self._observe_count

    def dataset_count(self) -> Int:
        """Number of distinct datasets with a recorded hint."""
        return len(self._keys)
