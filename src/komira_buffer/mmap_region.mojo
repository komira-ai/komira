# =============================================================================
# mmap_region.mojo — POSIX MAP_PRIVATE+PROT_READ file-backed region.
#
# Owns one mmap'd address range; exposes a safe byte view over its bytes;
# calls munmap(2) at drop. Readers (Arrow IPC, Parquet, Avro,
# `chunked_read`) map a file once and read bytes lazily from the
# address-space-mapped region instead of `FileHandle.read_bytes(n)` + a
# copy; per-Column buffers borrow from the mapping through an
# ArcPointer-wrapped keepalive (see `mmap_aligned_buffer.mojo`).
#
# Encapsulation:
#   * The mmap syscall returns a void*. It is held in a PRIVATE field; the
#     public API surface returns a byte view and `Int` — no raw pointer
#     crosses the module boundary.
#   * `open_readonly` / `__deinit__` use FFI (`open`, `fstat`, `mmap`,
#     `munmap`, `close`) inside `external_call` blocks with `# SAFETY:`
#     justification (the FFI-boundary carve-out).
#
# Cross-platform:
#   * macOS (osx-arm64) and Linux (x86_64) both support
#     `MAP_PRIVATE + PROT_READ` on regular files opened O_RDONLY.
#   * Every platform constant (AT_FDCWD, PROT_READ, MAP_PRIVATE,
#     MAP_FAILED, MADV_WILLNEED, the page size) and the `struct stat` layout
#     are resolved in C by the posix shim, never hardcoded on the Mojo side.
#
# Lifetime story:
#   1. `MmapRegion.open_readonly(path)` → opens file, fstats for size,
#      mmaps MAP_PRIVATE+PROT_READ, closes the fd (mmap retains the
#      kernel-side mapping; the fd is unneeded post-mmap).
#   2. `region.data() -> Span[UInt8, region_origin]` returns a span
#      whose origin is tied to `self`. Borrow checker enforces the
#      span is dropped before MmapRegion.
#   3. `__deinit__` calls `munmap(addr, len)`. After this, ANY outstanding
#      span is a use-after-unmap — Mojo's lifetime tracking is what
#      prevents this.

from std.ffi import external_call
from std.memory import UnsafePointer

from komira_buffer.byte_view import ByteView
from komira_buffer.memory_region import MemoryRegion


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer (Mojo pointers are non-null by default).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer; `None` is the all-zero (NULL) bit pattern. Used here
    # ONLY for the unmapped/empty MmapRegion sentinel (`_len == 0`), never
    # dereferenced.
    #
    # NOTE: the `_addr` field origin is a wildcard at the FFI boundary (see
    # the struct docstring for why the owning-wildcard hazard does not apply
    # to kernel-managed mapped pages).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# =============================================================================
# POSIX constants are resolved in C (the posix shim), NOT here.
# =============================================================================
#
# The open / fstat / mmap / munmap syscalls are issued through the
# `komira_open_ro` / `komira_fstat_size` / `komira_mmap_ro` /
# `komira_munmap` C shims. Each shim resolves its platform constants
# (`AT_FDCWD`, `O_RDONLY`, `PROT_READ`, `MAP_PRIVATE`, `MAP_FAILED`) and
# the `struct stat` layout from the C headers, where they are correct
# per-platform.
#
# This is deliberate. `AT_FDCWD` is -2 on macOS and -100 on Linux; a Mojo
# constant holding the macOS value makes Linux reject every relative-path
# `openat` with EBADF. Resolving the constants in C eliminates that class
# of bug.


# =============================================================================
# The readahead hint (MADV_WILLNEED), and why it is here.
# =============================================================================
#
# On a COLD page cache a scan that demand-faults a mapping stalls on each
# fault; issuing `MADV_WILLNEED` lets the kernel read ahead while the footer
# parse and plan build run. A sequential external prefetch of the file
# measurably shortens a cold scan, so demand-fault stall is real and
# recoverable.
#
# ⚠ THE FAULT COUNTERS DO NOT SHOW THIS AND WILL TALK YOU OUT OF IT.
# `ru_majflt` reports very few major faults for a cold file — which reads as
# "no stalling" and is wrong. Linux `filemap_fault` takes the "found in page
# cache, not uptodate" path for a page already under in-flight readahead and
# BLOCKS ON THE FOLIO LOCK WITHOUT setting VM_FAULT_MAJOR, so the wait is
# counted as a MINOR fault. A prefetch A/B is the instrument; the fault
# counters are not.
#
# TWO STRATEGIES, because there are two kinds of consumer:
#
#   * WHOLE-MAPPING (the default) — the advice is issued ONCE, when the
#     mapping is created, over the whole mapping. Right for a consumer that
#     reads most of the file.
#   * RANGE (`advise_whole_file=False`) — the consumer advises the ranges it
#     will read, via `advise_willneed_range`. Right for a PROJECTING consumer
#     such as a Parquet scan: a projection is a property of a query and this
#     struct is a property of a file, so only the caller can size the advice.
#     The advice cost tracks the bytes advised, and a narrow projection over a
#     wide file reads a small fraction of it.
#
# WHY ONCE-PER-MAPPING IS ALSO THE WARM ANSWER. Under a session mmap pin the
# mapping OUTLIVES the query, so a per-query advice call would fire on a
# mapping that is already fully resident, every query. Issuing it in
# `open_readonly` means later queries of a session pay nothing, and the one
# call a warm first query does pay skips every page it finds in the page cache.
#
# WHY NOT `MAP_POPULATE`: it prefaults SYNCHRONOUSLY at mmap time, which
# serialises exactly the I/O that WILLNEED overlaps with the footer parse and
# plan build.
comptime ADVICE_NOT_ISSUED: Int = 2
"""`_advice_rc` for a mapping over which the WHOLE-FILE advice was not issued —
a region with no mapping (default-constructed), or one opened with
`advise_whole_file=False` because its consumer advises ranges instead.
Distinct from both 0 (advice issued, succeeded) and -1 (advice issued, syscall
failed), so "we never called it" can never be read as "it worked".

⚠ It is also the `advise_willneed_range` return for a range there was nothing to
advise (no mapping, empty length, offset past the end), for the same reason."""


# =============================================================================
# MmapRegion — owning handle for one mmap'd file region.
# =============================================================================


struct MmapRegion(MemoryRegion, Movable, Deinitable):
    """Owns one POSIX MAP_PRIVATE+PROT_READ file mapping.

    Public API:
        * `MmapRegion.open_readonly(path)` — factory.
        * `region.data()` — returns `Span[UInt8, region_origin]`.
        * `region.len()` — file size.

    Lifetime: the returned Span is borrow-checked against `self`. Drop
    the span before dropping the MmapRegion.

    Fields:
        * `_addr` — pointer to the start of the mmap'd region.
          PRIVATE. Read via `data()` only.
        * `_len` — file size in bytes (matches the mmap length).
        * The field origin is a wildcard at the FFI boundary (see SAFETY).

    SAFETY:
        * `_addr` is the return value of `mmap(2)` and is valid for
          `_len` bytes of read-only access until `munmap` is called
          in `__deinit__`.
        * The pointer is `UnsafePointer[UInt8, MutExternalOrigin]`
          as a FFI-boundary carve-out — the syscall returns a raw
          address, and Mojo's lifetime system has no way to express
          "this address is valid until I call munmap on it" without
          a wildcard. The field is OWNED by this struct (not borrowed
          from elsewhere), so the destroy-recreate hazard (struct destroy-recreate
          + tcmalloc byte reuse) DOES NOT apply: the underlying bytes
          are kernel-managed mmap'd pages, NOT heap bytes. tcmalloc
          will never reuse this address while the mapping is alive.
        * The single carve-out point is the field declaration here;
          `data()` returns a tracked Span with the receiver's origin.
        * `__deinit__` calls `munmap` and zeros the fields. If `__deinit__`
          fires while a borrowed Span is still alive, that's a
          lifetime-checker bug — but Mojo's `ref [self.field] T`
          / `ref [self] T` return mechanism is designed to prevent
          exactly that.
    """

    # SAFETY (FFI-BOUNDARY carve-out for an owning wildcard field):
    #
    # (a) WHY a wildcard is load-bearing: mmap(2) returns a raw `void*`.
    #     Mojo's lifetime system has no concrete origin to bind to the
    #     kernel-managed mmap'd page range — the only proper origin for it
    #     is the parent MmapRegion struct's own lifetime, which wildcard
    #     widening makes inferable but not enforceable. The enforcement
    #     happens at `data()` where the receiver `ref [origin] self`
    #     rebinds the pointer to the caller's origin.
    #
    # (b) WHEN the field is non-null: between `open_readonly()` and
    #     `__deinit__`. WHEN it is null/sentinel: after default `__init__()`
    #     (empty region) and before `open_readonly` populates it. The
    #     `_len == 0` flag is the sentinel; `__deinit__` skips munmap when
    #     it's 0.
    #
    # (c) Owning vs borrowed: OWNING — MmapRegion is responsible for
    #     `munmap(2)` at drop. The underlying bytes are kernel-managed
    #     mmap'd pages, NOT tcmalloc heap. The destroy-recreate hazard
    #     (tcmalloc byte reuse under a stale wildcard) does NOT apply
    #     because tcmalloc never serves an mmap'd address.
    #
    # (d) Teardown: `__deinit__` calls `munmap(_addr, _len)` and the kernel
    #     unmaps the pages. The struct is Movable (not Copyable), so
    #     there is at most one MmapRegion per kernel mapping; no
    #     double-munmap risk.
    var _addr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var _len: Int
    var _advice_rc: Int
    """What `madvise(MADV_WILLNEED)` returned for this mapping — 0 on
    success, -1 on a failed syscall, and `ADVICE_NOT_ISSUED` for a region
    that has no mapping to advise or was opened with `advise_whole_file=False`.

    This is an OBSERVABILITY field, not a switch: nothing branches on it. It
    exists so a test can assert the advice was ISSUED AND SUCCEEDED, which is
    the only externally-visible consequence of a hint syscall whose entire
    effect is on timing. `advice_rc()` is its accessor.

    `advise_whole_file=False` leaves this field at `ADVICE_NOT_ISSUED` on a
    live mapping. That is a REQUEST FOR A DIFFERENT STRATEGY, not a kill
    switch — the caller has promised to advise ranges instead, and
    `willneed_advised_bytes()` is how a test holds it to that."""

    # --- Constructors ---

    def __init__(out self):
        """Empty / null MmapRegion (no mapping). `__deinit__` is a no-op
        when `_len == 0`."""
        self._addr = _null_ptr[UInt8, MutUntrackedOrigin]()
        self._len = 0
        self._advice_rc = ADVICE_NOT_ISSUED

    @staticmethod
    def open_readonly(
        path: String, advise_whole_file: Bool = True
    ) raises -> MmapRegion:
        """Open `path` for read, mmap it MAP_PRIVATE+PROT_READ, close
        the fd, return the owning MmapRegion.

        `advise_whole_file` selects WHICH of the two readahead strategies this
        mapping uses, and there are exactly two because there are exactly two
        kinds of consumer:

          * `True` (the default) — issue `madvise(MADV_WILLNEED)` over the whole
            mapping, once, here. Right for a consumer that reads MOST of the
            file: the Arrow IPC readers, `chunked_read`, the Avro reader.
          * `False` — issue nothing here; the consumer advises the byte ranges
            it will actually read, via `advise_willneed_range`. Right for a
            PROJECTING consumer, which is what a Parquet scan is. A projection
            is a property of a QUERY and a mapping is a property of a FILE, so
            this struct cannot size the advice itself — only the caller can, and
            the flag is how it says it will.

        ⚠ It is NOT a perf kill switch and there is no "advise nothing" state: a
        `False` here is a PROMISE to advise ranges, and `willneed_advised_bytes`
        is how a test holds the caller to it. See `advise_willneed_range`.

        The fd is closed before return — mmap retains the kernel-side
        mapping reference independently of the fd lifetime (per POSIX
        spec). Holding the fd open serves no purpose for a MAP_PRIVATE
        mapping.

        Raises:
            * Error("MmapRegion.open_readonly: open(): ...") on open failure.
            * Error("MmapRegion.open_readonly: fstat(): ...") on fstat failure.
            * Error("MmapRegion.open_readonly: mmap(): ...") on mmap failure.
            * Error("MmapRegion.open_readonly: zero-length file: ...") on
              empty file (mmap with len=0 is implementation-defined; we
              raise rather than relying on POSIX behavior).
        """
        # ---- 1. open(2) read-only via the fixed-arity C shim ----------------
        # The path string needs a NUL-terminated C string. `as_c_string_slice`
        # is a mutating method (appends a NUL); needs an owned local.
        #
        # FFI-BOUNDARY: `komira_open_ro(const char *path) -> int` (the posix
        # shim, linked into every binary and test). The shim calls
        # `openat(AT_FDCWD, path, O_RDONLY)` with the C-resolved `AT_FDCWD` so
        # the dirfd is correct on macOS (-2) AND Linux (-100).
        #
        # Why a shim, not a raw `external_call["openat", Int32](_AT_FDCWD, ...)`:
        # a Mojo-side `AT_FDCWD` constant is correct on one platform only
        # (see the module header). Resolving the constant in C eliminates the
        # platform-constant hazard entirely (same shim philosophy as the
        # write path's komira_openat_creat).
        var p = path
        var fd = external_call["komira_open_ro", Int32](
            p.as_c_string_slice().unsafe_ptr(),
        )
        if Int(fd) < 0:
            raise Error(
                "MmapRegion.open_readonly: open() failed for path '"
                + path + "' (errno not surfaced)"
            )

        # ---- 2. fstat(2) for the file size via the C shim -------------------
        # FFI-BOUNDARY: `komira_fstat_size(int fd) -> long long`. The shim
        # fstats `fd` and returns `st_size` directly, so no platform-specific
        # `struct stat` byte offsets live on the Mojo side.
        var file_size = Int(
            external_call["komira_fstat_size", Int64](fd)
        )
        if file_size <= 0:
            # Close the fd before raising (best-effort cleanup).
            _ = external_call["close", Int32](fd)
            raise Error(
                "MmapRegion.open_readonly: fstat() failed or zero-length file"
                " at path '" + path + "' (file_size="
                + String(file_size) + ")"
            )

        # ---- 3. mmap(2) read-only via the C shim ----------------------------
        # FFI-BOUNDARY: `komira_mmap_ro(int fd, long long length) -> void*`.
        # The shim calls `mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0)`
        # with the C-resolved PROT_READ / MAP_PRIVATE / MAP_FAILED — so those
        # constants (like AT_FDCWD) are correct per-platform and never
        # hardcoded on the Mojo side. The shim returns NULL on MAP_FAILED, so
        # the Mojo side only branches on NULL.
        #
        # SAFETY: external_call returns a raw address. We wrap it in
        # UnsafePointer[UInt8, MutExternalOrigin] — the field declaration
        # carries the `MutExternalOrigin` for the wildcard hazard documented
        # in the struct docstring.
        #
        # The FFI return type is `Optional[UnsafePointer[...]]`, NOT the bare
        # pointer. `Pointer` is non-null BY DESIGN, so `if not addr` on a bare
        # one is rejected outright -- and this shim returns NULL on
        # MAP_FAILED, which is the single thing this call site has to be able
        # to detect. `Optional[UnsafePointer[...]]` is layout-compatible with
        # the bare pointer and `None` IS the all-zero (NULL) bit pattern, so
        # the ABI is unchanged -- the same recipe `byte_view._null_ptr`
        # documents in this package.
        var addr_opt = external_call[
            "komira_mmap_ro", Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]
        ](fd, Int64(file_size))

        # ---- 4. close(2) ----------------------------------------------------
        # Per POSIX, mmap retains the mapping; the fd can be closed
        # immediately. Close BEFORE checking mmap result so we leak no
        # fd on the error path.
        _ = external_call["close", Int32](fd)

        # ---- 5. mmap error check -------------------------------------------
        # The shim returns NULL on MAP_FAILED.
        if not addr_opt:
            raise Error(
                "MmapRegion.open_readonly: mmap() failed for path '"
                + path + "' (file_size=" + String(file_size) + ")"
            )

        # ---- 6. madvise(MADV_WILLNEED) over the whole mapping ---------------
        # See the module-level block above. Three properties make this safe
        # to issue unconditionally rather than behind a switch:
        #
        #   * It cannot change what we read. `madvise` is a hint; it moves
        #     pages into the page cache and never alters their contents (man 2
        #     madvise).
        #   * It cannot fail the open. The rc is RECORDED, not raised on. An
        #     `madvise` that returns -1 (a range the kernel declines to advise)
        #     leaves a perfectly usable demand-paged mapping.
        #   * It costs a warm session nothing after the first query for a file
        #     the session pin ADMITS, because `open_readonly` then runs ONCE per
        #     file per session. Metadata-only readers must not map the whole
        #     file (`whole_file_map_count()` below makes that assertable). A
        #     file over the pin's byte cap is never pinned, so it still pays
        #     this advice per query, by design — the pin counts those in
        #     `mmap_pin_declined()`, which is the number to read before blaming
        #     this line for a warm session's cost.
        #
        # FFI-BOUNDARY: `komira_madvise_willneed(void*, unsigned long) -> int`
        # (the posix shim). MADV_WILLNEED is resolved in C, per the AT_FDCWD
        # lesson recorded at the top of this file.
        var advice_rc = ADVICE_NOT_ISSUED
        if advise_whole_file:
            advice_rc = Int(
                external_call["komira_madvise_willneed", Int32](
                    addr_opt.value(), file_size
                )
            )

        # ---- 7. Construct MmapRegion ---------------------------------------
        var region = MmapRegion()
        region._addr = addr_opt.value()
        region._len = file_size
        region._advice_rc = advice_rc
        return region^

    # --- Destructor ---

    def __deinit__(deinit self):
        """Call `munmap(addr, len)` if a mapping is alive.

        SAFETY: `_addr` and `_len` were set by `open_readonly` from
        a successful mmap return. Calling munmap with these arguments
        is the documented inverse. After munmap, any outstanding Span
        becomes a use-after-unmap — Mojo's lifetime checker enforces
        that those spans are dropped before this destructor fires.

        We do NOT raise on munmap failure (the destructor cannot
        raise). The Linux/macOS kernel only fails munmap on EINVAL
        (bad alignment / not-a-mmap-region), neither of which can
        happen on a region we created via our own mmap.
        """
        if self._len > 0:
            # FFI-BOUNDARY: `komira_munmap(void* addr, unsigned long length)
            # -> int` (the posix shim). The kernel reads the
            # arguments and tears down the mapping; no caller-side memory is
            # read. The shim resolves `size_t` from `length` in C, keeping the
            # call site uniform with the read-path open/mmap shims.
            _ = external_call["komira_munmap", Int32](
                self._addr, self._len
            )

    # --- Accessors ---

    @always_inline
    def len(self) -> Int:
        """File size in bytes (matches the mmap length)."""
        return self._len

    @always_inline
    def is_empty(self) -> Bool:
        """True iff no mapping is alive (default-constructed)."""
        return self._len == 0

    @always_inline
    def advice_rc(self) -> Int:
        """What `madvise(MADV_WILLNEED)` returned for this mapping.

        0 — issued, succeeded. -1 — issued, the syscall failed (the mapping is
        still fully usable; it is demand-paged). `ADVICE_NOT_ISSUED` — this
        region has no mapping, or was opened with `advise_whole_file=False`.

        This exists BECAUSE the advice's entire effect is on timing: a hint
        that silently stopped being issued would look exactly like a hint that
        stopped helping, and the only place that distinction can be made
        cheaply is here."""
        return self._advice_rc

    def advise_willneed_range(self, offset: Int, length: Int) -> Int:
        """Advise `MADV_WILLNEED` over the byte range `[offset, offset+length)`
        of THIS mapping.

        Returns 0 (issued, accepted), -1 (issued, the syscall failed), or
        `ADVICE_NOT_ISSUED` when there was nothing to advise — no mapping, a
        non-positive length, or an offset past the end. The three-state return
        is the same discipline as `advice_rc()`: "we never called it" must not
        be readable as "it worked".

        WHY A RANGE FORM EXISTS. `open_readonly`'s whole-mapping advice is sized
        by the FILE; a Parquet scan's read is sized by the PROJECTION. The
        advice cost tracks the bytes advised, not the bytes read, so a narrow
        projection over a wide file pays for the whole file under the
        whole-mapping form.

        The range is page-aligned and clamped inside the C shim, where the page
        size is resolved by `sysconf(_SC_PAGESIZE)` rather than hardcoded — the
        same reason `MADV_WILLNEED` and `AT_FDCWD` are resolved there (macOS
        arm64 is 16 KiB, linux x86_64 is 4 KiB, and a hardcoded constant here
        would be an EINVAL-class bug on one of them).

        SAFETY: the FFI call reads `_addr` (valid for `_len` bytes until
        `__deinit__`) and never writes through it. `madvise` is documented not
        to modify page contents (man 2 madvise).
        """
        if self._len <= 0 or length <= 0 or offset < 0 or offset >= self._len:
            return ADVICE_NOT_ISSUED
        # FFI-BOUNDARY: `komira_madvise_willneed_range(void*, unsigned long long
        # region_len, unsigned long long offset, unsigned long long length)
        # -> int` (the posix shim).
        return Int(
            external_call["komira_madvise_willneed_range", Int32](
                self._addr, UInt64(self._len), UInt64(offset), UInt64(length)
            )
        )

    @staticmethod
    def willneed_advised_bytes() -> Int:
        """How many bytes THIS PROCESS has handed to `madvise(MADV_WILLNEED)`,
        over its whole life, across BOTH the whole-mapping and the range form.

        Monotone, process-wide, cheap (a relaxed atomic load).

        WHY IT EXISTS. The advice's entire effect is on fault traffic: the
        mapping's bytes, length and address are identical whether the advice
        covers gigabytes or 16 KiB, so "the reader stopped advising the whole
        file" is invisible to every value-based oracle and looks in a benchmark
        exactly like "the box got faster". A DELTA on this counter across a
        reader open plus a small read is the falsifier — whole-file advice moves
        it by the file size, range advice by a page or two. Same instrument
        shape, and same reason, as `whole_file_map_count()` below.
        """
        return Int(external_call["komira_madvise_willneed_bytes", Int64]())

    @staticmethod
    def whole_file_map_count() -> Int:
        """How many whole-file mappings THIS PROCESS has created, over its
        whole life.

        Monotone, process-wide, cheap (a relaxed atomic load). It counts
        successful `komira_mmap_ro` calls, which is every mapping
        `open_readonly` has ever made — there is no other path to a
        whole-file `mmap(2)`.

        WHY IT EXISTS. The session pin's invariant is "`open_readonly` runs
        ONCE per file per session". A metadata-only helper that opens a
        mmap-backed reader would eagerly map the WHOLE file just to read
        `metadata_bytes`, silently breaking that. A DELTA on this counter
        across a helper call is the falsifier: a metadata-only read must move
        it by 0, and a real reader open must move it by 1, so neither "the
        helper regressed to mapping" nor "the counter went dead" can pass
        silently."""
        return Int(external_call["komira_mmap_ro_count", Int64]())

    def data[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """Return a ByteView over the mmap'd bytes, lifetime-bound to `self`.

        The returned ByteView's origin is tied to `self` via the explicit
        `origin` parameter (the explicit origin parameter lets the return
        type and body reference the same origin identifier, which
        `origin_of(self)` in two positions does not unify).

        Borrow checker enforces:
            * ByteView dropped before MmapRegion.
            * No `data()` call mutates the region.

        SAFETY: `_addr` is alive for `_len` bytes until `__deinit__`
        fires. The receiver `ref [origin] self` keeps `self` (and
        therefore the mapping) alive for the view's origin lifetime.
        Same pattern as `mmap_aligned_buffer.view_range_ro`.
        """
        # SAFETY: the receiver `ref [origin] self` ties the view's
        # origin to `self`. The pointer `_addr` is unchanged through
        # the cast; we first flip mutability to match the receiver's
        # origin (`_mut`), then widen origin to the named parameter.
        var ptr = self._addr.unsafe_mut_cast[_mut]().unsafe_origin_cast[
            origin
        ]()
        return ByteView[origin](ptr, self._len)

    # --- MemoryRegion trait conformance ---
    #
    # The `as_view` method is the trait surface; it is a thin alias for
    # the `data()` method (same shape, same body — `data()` IS the
    # canonical `as_view` shape). Both names are kept; `data()` can be
    # retired once every caller uses `.as_view()`.
    #
    # The `length(self) -> Int64` trait method is the typed-Int64 mirror of
    # the `len(self) -> Int` accessor.

    def as_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        """MemoryRegion trait surface. Delegates to `data()`; see that
        method's docstring for full semantics + SAFETY discussion."""
        return self.data()

    def length(self) -> Int64:
        """MemoryRegion trait surface. Byte length of the mmap'd region."""
        return Int64(self._len)


# =============================================================================
# Public API surface — re-exported via `from komira_buffer.mmap_region
# import MmapRegion`.
# =============================================================================
#
# The MmapRegion struct is the sole export. Views returned from
# `data()` / `as_view()` carry their own origin parameters.
#
# See `mmap_aligned_buffer.mojo` for the sibling primitive whose
# borrowed buffers keep a mapping alive through an
# `ArcPointer[MmapRegion]` keepalive.
