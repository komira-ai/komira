# =============================================================================
# komira_async.fs.footer_region — FooterRegion (speculative tail read)
# =============================================================================
# the return type of
# `FileSystem.read_footer`.
#
# WHY THIS TYPE EXISTS
# --------------------
# `read_footer` used to return a bare `List[UInt8]` — the trailing region of
# the file — which forced every caller that also needed the TOTAL file size
# (all of them: the parquet metadata offset is `file_size - 8 -
# metadata_length`) to make a SECOND, SERIALLY-DEPENDENT metadata call
# (`fs.file_size(path)` = an HTTP HEAD on every object store). On a
# high-latency object store that second call is a full round trip that buys
# nothing: an HTTP ranged GET already carries the total object size in its
# `Content-Range: bytes A-B/TOTAL` response header.
#
# Bundling `(bytes, offset, file_size)` into ONE return value lets a cloud
# conformer satisfy the whole footer open with a SINGLE **suffix range**
# request — no HEAD, no size known in
# advance. A HEAD+GET pair is otherwise 2 of the serially-dependent round
# trips in the parquet footer preamble.
#
# THE SPECULATIVE WINDOW — ADAPTIVE, NOT A CONSTANT
# -------------------------------------------------
# The window is how many trailing bytes a conformer fetches without knowing
# where the footer starts. It trades ONE cost against another, both costs of
# the `read_ranges` override seam (the S3 filesystem): round trips vs bytes
# fetched and discarded.
#
# A fixed 8 MiB discards almost all of what it transfers on a typical
# ~120 KB footer (TPC-H SF1 `lineitem.parquet`). A fixed 256 KiB is wrong the
# other way: wide-schema files (ClickBench `hits` at ~2.4 MB, the h2o suite at
# 0.4-1 MB) exceed it, and on every one of those the "speculation" is a
# guaranteed MISS — on an object store, 2 round trips plus a wasted 256 KiB
# transfer, precisely the cost this lever exists to remove.
#
# A fixed constant cannot be right: footer size scales with (columns x row
# groups) and is a property of the DATASET, not of the code. So the window is
# now ADAPTIVE — `FooterWindowHints` (`footer_window_hints.mojo`) remembers
# the footer size actually observed per dataset in the session footer cache
# and speculates with `next_footer_window(observed)` next time. The constant
# below is only the COLD default: what we guess the FIRST time we touch a
# dataset we have never seen.
#
# Footers larger than the window are still handled by the caller with ONE
# exact follow-up read — correctness never depends on the guess, only cost.
# =============================================================================


# The number of trailing bytes a `read_footer` conformer speculatively
# fetches for a dataset it has NEVER SEEN. Not a claim that every footer
# fits: see the file header. Warm speculation uses `FooterWindowHints`.
comptime FOOTER_SPECULATIVE_WINDOW: Int = 256 * 1024

# Ceiling on an ADAPTED window. A learned window is a wasted transfer if the
# next file's footer is smaller, so growth is bounded: past 16 MiB the
# one-extra-round-trip miss is cheaper than the speculative over-fetch.
# (`hits_canonical`, the largest footer in the corpus at 2.33 MiB, is 7x
# under this.)
comptime FOOTER_WINDOW_MAX: Int = 16 * 1024 * 1024

# Granularity a learned window is rounded up to, so that N sibling files with
# footers differing by a few bytes converge on ONE window value instead of
# ratcheting per file.
comptime FOOTER_WINDOW_GRANULARITY: Int = 64 * 1024


def next_footer_window(observed_footer_len: Int) -> Int:
    """The window to speculate with, having observed a footer of
    `observed_footer_len` bytes (metadata blob + the 8-byte trailer) in this
    dataset.

    Policy:
      * Never below `FOOTER_SPECULATIVE_WINDOW` — the cold default is already
        cheap, and shrinking risks re-missing on a marginally larger sibling.
      * Otherwise `observed + 1/8 headroom`, rounded UP to
        `FOOTER_WINDOW_GRANULARITY`. The headroom matters because sibling
        files in one dataset have footers within a few percent of each other
        (same schema, similar row-group counts) but not identical — a window
        pinned exactly at the first observation would miss on the second file
        about half the time.
      * Clamped at `FOOTER_WINDOW_MAX`.

    Monotone in `observed_footer_len`, and `next_footer_window(x) >= x` for
    every `x <= FOOTER_WINDOW_MAX` — the property the adaptive guard asserts
    against the real corpus footer sizes.
    """
    if observed_footer_len <= FOOTER_SPECULATIVE_WINDOW:
        return FOOTER_SPECULATIVE_WINDOW
    var want = observed_footer_len + (observed_footer_len >> 3)
    # Round up to the granularity.
    var g = FOOTER_WINDOW_GRANULARITY
    var rounded = ((want + g - 1) // g) * g
    if rounded > FOOTER_WINDOW_MAX:
        return FOOTER_WINDOW_MAX
    return rounded


struct FooterRegion(Movable, Deinitable):
    """A file's trailing byte region plus the metadata a caller would
    otherwise need a second round trip to learn.

    Fields:
        bytes:     The trailing region. `bytes[0]` is at file offset
                   `offset`; `len(bytes) == file_size - offset`.
        offset:    File offset of `bytes[0]`.
        file_size: TOTAL size of the file / object in bytes. This is the
                   value that used to require a separate `fs.file_size(path)`
                   HEAD; conformers now source it from the ranged-GET
                   `Content-Range` header (cloud) or the stat/seek they
                   already perform (local).

    Invariant: `offset + len(bytes) == file_size`. A conformer that cannot
    honor that must raise rather than return a partial region — callers
    locate the parquet trailer by indexing from the END of `bytes`, and a
    region that does not actually reach EOF would silently mis-locate it.
    """

    var bytes: List[UInt8]
    var offset: Int
    var file_size: Int

    def __init__(out self, var bytes: List[UInt8], offset: Int, file_size: Int):
        self.bytes = bytes^
        self.offset = offset
        self.file_size = file_size

    @always_inline
    def len(self) -> Int:
        """Number of bytes in the region."""
        return len(self.bytes)

    @always_inline
    def covers(self, file_offset: Int, length: Int) -> Bool:
        """True iff `[file_offset, file_offset+length)` lies wholly inside
        this region — i.e. the speculative window was generous enough and
        the caller needs no follow-up read."""
        return file_offset >= self.offset and (
            file_offset + length <= self.offset + len(self.bytes)
        )


def speculative_tail_start(
    file_size: Int, window: Int = FOOTER_SPECULATIVE_WINDOW
) -> Int:
    """File offset at which a `window`-sized tail read starts for a file of
    `file_size` bytes (clamped at 0 for small files).

    Shared by every conformer that DOES know the size up front (local stat,
    or a cloud backend whose range API cannot express a suffix range) so the
    clamping policy lives in exactly one place. `window` defaults to the COLD
    default; warm callers pass the value `FooterWindowHints.suggest` learned
    for this dataset."""
    var w = window
    if w < 8:
        # A conformer must always return at least the format trailer.
        w = 8
    if file_size <= w:
        return 0
    return file_size - w
