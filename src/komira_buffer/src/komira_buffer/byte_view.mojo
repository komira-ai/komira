# =============================================================================
# ByteView[mut, origin] -- unified contiguous byte-range view
# =============================================================================
#
# ByteView is Rust's `&[u8]` / `&mut [u8]` -- ONE struct parameterized on
# mut: Bool via the `origin` parameter. Read methods are universal; write
# methods are gated via receiver refinement so they appear callable only
# when mut=True.
#
# It is the origin-tied replacement for raw-pointer byte escapes on
# MmapAlignedBuffer / ByteBuffer / Slab.
#
# Canonical spellings:
#   - Struct header:  struct ByteView[mut: Bool, //, origin: Origin[mut=mut]]
#   - Immutable view: ByteView[Origin[mut=False]]
#   - Mutable   view: ByteView[Origin[mut=True]]
#   - Callers typically write `ByteView[my_origin]` and let `mut` infer.
#
# split_at / ByteViewPair:
#   Returning `Tuple[ByteView[mut=True, o], ByteView[mut=True, o]]` from a
#   splitter FAILS to compile on 0.26.3 -- the Tuple ctor receives both
#   aliasing mutable views simultaneously and the exclusivity check fires.
#   ByteViewPair[mut, origin] is the workaround: default-construct empty,
#   then field-assign the halves one at a time.
#
# Module-private escape:
#   _unsafe_ptr() exists solely for decoder hot loops within this module
#   (only files under the core packages may call it). It does NOT
#   cross the module boundary to callers.
# =============================================================================

from std.memory import UnsafePointer, unsafe_memcpy, unsafe_memset
from std.sys import size_of

# the core packages imports nothing from the core packages, so this
# does NOT create a collections <-> simd cycle.
from komira_simd.fast_copy import fast_copy_bytes


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (the stdlib has no
    `UnsafePointer[T, o]()` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (modular/mojo/proposals/non-null-pointer.md); `None` is
    # the all-zero (NULL) bit pattern. Origin `o` is the caller's concrete
    # origin (here `Self.origin`). The NULL/empty view is len-0-gated so the
    # dangling pointer is never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


struct ByteView[mut: Bool, //, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Movable
):
    """Unified contiguous byte-range view (Rust's `&[u8]` / `&mut [u8]`).

    Parameters:
        mut: Whether the view permits mutation (inferred from `origin`).
        origin: The origin the backing pointer is tied to.

    Read methods (`len`, `read_*_at`, `sub`, `split_at`, `split_first`,
    `split_last`, `copy_to`, `load_simd`) are universal -- callable on any
    ByteView. Write methods (`write_*_at`, `write_bytes_at`, `fill`,
    `store_simd`) are gated via receiver refinement (self: ByteView[mut=True, _])
    so a call on a `mut=False` view fails to compile with
    "no matching method".
    """

    # SAFETY: `_data` is tied to `Self.origin`. Module-private field --
    # all access is routed through the typed read/slice methods below.
    # The `//` syntax in the struct header marks `mut` as inferred from
    # the `origin` argument at use-sites.
    var _data: UnsafePointer[UInt8, Self.origin]
    var _len: Int

    # =========================================================================
    # Construction
    # =========================================================================

    @always_inline
    def __init__(out self):
        """Empty view (length 0, dangling pointer).

        Used by `ByteViewPair.__init__` to default-construct
        both halves of a split before field-assigning them one at a time.
        """
        self._data = _null_ptr[UInt8, Self.origin]()
        self._len = 0

    @always_inline
    def __init__(
        out self, ptr: UnsafePointer[UInt8, Self.origin], length: Int
    ):
        """Construct a view over `length` bytes starting at `ptr`.

        Args:
            ptr: Origin-tied pointer to the first byte.
            length: Number of bytes in the view. Must be >= 0.
        """
        self._data = ptr
        self._len = length

    # =========================================================================
    # Universal accessors (any mut)
    # =========================================================================

    @always_inline
    def len(self) -> Int:
        """Return the number of bytes in the view."""
        return self._len

    # =========================================================================
    # Typed reads (byte-offset addressed) -- universal, any mut
    # =========================================================================

    @always_inline
    def read_u8_at(self, offset: Int) -> UInt8:
        """Read a UInt8 at `offset`. PANICS if offset+1 > len()."""
        debug_assert(
            offset >= 0 and offset + 1 <= self._len,
            "ByteView.read_u8_at: offset+1 > len",
        )
        # SAFETY: offset is bounds-checked.
        return (self._data + offset)[]

    @always_inline
    def read_u16_le_at(self, offset: Int) -> UInt16:
        """Read a little-endian UInt16 at `offset`.

        PANICS if offset+2 > len(). Uses an unaligned scalar load (width=1)
        via bitcast; the compiler emits an unaligned load instruction so
        the caller does not need to align the view.
        """
        debug_assert(
            offset >= 0 and offset + 2 <= self._len,
            "ByteView.read_u16_le_at: offset+2 > len",
        )
        # SAFETY: offset is bounds-checked; unaligned load is sound on x86/arm.
        return (
            (self._data + offset).bitcast[UInt16]().load[alignment=1]()
        )

    @always_inline
    def read_u32_le_at(self, offset: Int) -> UInt32:
        """Read a little-endian UInt32 at `offset`. PANICS if offset+4 > len()."""
        debug_assert(
            offset >= 0 and offset + 4 <= self._len,
            "ByteView.read_u32_le_at: offset+4 > len",
        )
        return (
            (self._data + offset).bitcast[UInt32]().load[alignment=1]()
        )

    @always_inline
    def read_u64_le_at(self, offset: Int) -> UInt64:
        """Read a little-endian UInt64 at `offset`. PANICS if offset+8 > len()."""
        debug_assert(
            offset >= 0 and offset + 8 <= self._len,
            "ByteView.read_u64_le_at: offset+8 > len",
        )
        return (
            (self._data + offset).bitcast[UInt64]().load[alignment=1]()
        )

    @always_inline
    def read_i32_le_at(self, offset: Int) -> Int32:
        """Read a little-endian Int32 at `offset`. PANICS if offset+4 > len()."""
        debug_assert(
            offset >= 0 and offset + 4 <= self._len,
            "ByteView.read_i32_le_at: offset+4 > len",
        )
        return (
            (self._data + offset).bitcast[Int32]().load[alignment=1]()
        )

    @always_inline
    def read_i64_le_at(self, offset: Int) -> Int64:
        """Read a little-endian Int64 at `offset`. PANICS if offset+8 > len()."""
        debug_assert(
            offset >= 0 and offset + 8 <= self._len,
            "ByteView.read_i64_le_at: offset+8 > len",
        )
        return (
            (self._data + offset).bitcast[Int64]().load[alignment=1]()
        )

    # =========================================================================
    # Structural ops -- universal, any mut. All return views with the same
    # origin as `self`, preserving the mut bit automatically.
    # =========================================================================

    @always_inline
    def sub(self, start: Int, length: Int) -> ByteView[Self.origin]:
        """Return a sub-view over `length` bytes starting at `start`.

        ⚠ Does NOT panic in a shipped build. The guard below is a
        `debug_assert`, which is compiled out at `ASSERT=none`. Callers
        handling values that came off the wire MUST validate before calling;
        see `komira_arrow/dict_code_bounds.mojo`.
        """
        debug_assert(
            start >= 0 and start + length <= self._len,
            "ByteView.sub: start+length > len",
        )
        return ByteView[Self.origin](self._data + start, length)

    @always_inline
    def split_at(self, mid: Int) -> ByteViewPair[Self.origin]:
        """Split this view into two non-overlapping halves at `mid`.

        PANICS if mid > len() (mid == len() is OK -- empty tail).

        Returns `ByteViewPair` (NOT a `Tuple`): returning
        `Tuple[ByteView[mut=True, o], ByteView[mut=True, o]]` fails on
        0.26.3 exclusivity-check: the Tuple ctor receives both aliasing
        mutable views simultaneously. ByteViewPair works around this by
        default-constructing empty, then field-assigning one at a time.
        """
        debug_assert(
            mid >= 0 and mid <= self._len,
            "ByteView.split_at: mid > len",
        )
        var pair = ByteViewPair[Self.origin]()
        pair.lhs = ByteView[Self.origin](self._data, mid)
        pair.rhs = ByteView[Self.origin](
            self._data + mid, self._len - mid
        )
        return pair^

    @always_inline
    def split_first(self) -> Tuple[UInt8, ByteView[Self.origin]]:
        """Split off the first byte. Returns (first_byte, tail_view).

        PANICS if the view is empty.
        """
        debug_assert(self._len > 0, "ByteView.split_first: empty view")
        var first = (self._data + 0)[]
        var tail = ByteView[Self.origin](self._data + 1, self._len - 1)
        return Tuple(first, tail^)

    @always_inline
    def split_last(self) -> Tuple[UInt8, ByteView[Self.origin]]:
        """Split off the last byte. Returns (last_byte, prefix_view).

        PANICS if the view is empty.
        """
        debug_assert(self._len > 0, "ByteView.split_last: empty view")
        var last = (self._data + (self._len - 1))[]
        var prefix = ByteView[Self.origin](self._data, self._len - 1)
        return Tuple(last, prefix^)

    def copy_to(
        self, mut dest: List[UInt8], start: Int, length: Int
    ):
        """Copy `length` bytes starting at `start` into `dest` (appended).

        PANICS if start+length > len() or start < 0.
        """
        debug_assert(
            start >= 0 and start + length <= self._len,
            "ByteView.copy_to: start+length > len",
        )
        for i in range(length):
            # SAFETY: i in [0, length); start+i in [0, _len) by precondition.
            dest.append((self._data + start + i)[])

    # =========================================================================
    # Typed element access (for callers migrating off _unsafe_data_ptr().bitcast[T]())
    # =========================================================================

    @always_inline
    def get_typed[
        T: TrivialRegisterPassable & Copyable
    ](self, index: Int) -> T:
        """Return the T at element-index `index` (byte-offset = index * size_of[T]()).

        Intended as a drop-in replacement for `ptr.bitcast[T]()[index]` at
        call sites that can express the slot by element index (most PLAIN
        decoders).

        ⚠ Does NOT panic in a shipped build. The guard below is a
        `debug_assert` and is compiled out at `ASSERT=none`. An `index`
        derived from untrusted input must be validated by the caller — this
        is the read that the dictionary-code gathers bottom out in. See
        `komira_arrow/dict_code_bounds.mojo`.
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0 and (index + 1) * sz <= self._len,
            "ByteView.get_typed: element index out of range",
        )
        # SAFETY: bounds-checked above; T is TrivialRegisterPassable.
        return (self._data + index * sz).bitcast[T]()[]

    @always_inline
    def set_typed[
        T: TrivialRegisterPassable & Copyable
    ](self, index: Int, val: T) where Self.mut:
        """Store the T at element-index `index` (byte-offset = index * size_of[T]()).

        PANICS if (index + 1) * size_of[T]() > len() or index < 0.
        """
        comptime sz = size_of[T]()
        debug_assert(
            index >= 0 and (index + 1) * sz <= self._len,
            "ByteView.set_typed: element index out of range",
        )
        # SAFETY: bounds-checked above; T is TrivialRegisterPassable.
        (self._mut_data() + index * sz).bitcast[T]()[] = val

    # =========================================================================
    # SIMD bulk load -- universal, any mut (hot kernels)
    # =========================================================================

    @always_inline
    def load_simd[
        T: DType, width: Int
    ](self, byte_offset: Int) -> SIMD[T, width]:
        """Load `width` lanes of `T` starting at `byte_offset`.

        PANICS if byte_offset + width*sizeof[T]() > len() or
        byte_offset < 0.

        Parameters:
            T: The DType of each lane.
            width: The SIMD vector width.
        """
        comptime lane_bytes = size_of[T]() * width
        debug_assert(
            byte_offset >= 0 and byte_offset + lane_bytes <= self._len,
            "ByteView.load_simd: byte_offset + width*size_of[T] > len",
        )
        # SAFETY: bounds-checked above; unaligned load is sound.
        return (
            (self._data + byte_offset)
            .bitcast[Scalar[T]]()
            .load[width=width, alignment=1]()
        )

    # =========================================================================
    # Write methods -- `where Self.mut`-gated to require mut=True
    # -------------------------------------------------------------------------
    # Calling any of these on a `ByteView[Origin[mut=False]]` fails at compile
    # time with "invalid call ...: violated constraint". Negative test verifies
    # this.
    #
    # MOJO 1.0.0 MIGRATION -- the receiver-refinement spelling is gone.
    # `def m(self: ByteView[mut=True, _], ...)` is rejected: "'self' argument
    # must have type 'Self'; use a 'where' clause to constrain the 'Self' type
    # instead". The replacement is `def m(self, ...) where Self.mut:`.
    #
    # ⚠ MEASURED: `where` gates the CALL but does NOT refine the BODY. All
    # three spellings -- `where Self.mut`, `where Self.origin.mut`, and a
    # Span-backed field -- still fail the body with "expression must be
    # mutable in assignment", because inside the generic body `Self.origin`
    # is still `Origin[mut=Self.mut]` with `mut` unresolved. `_mut_data()`
    # below is the single place that closes that gap.
    # =========================================================================

    @always_inline
    def _mut_data(
        self,
    ) -> UnsafePointer[
        UInt8, Self.origin.unsafe_mut_cast[True]()
    ] where Self.mut:
        """The backing pointer, re-typed at a mutable origin.

        # SAFETY: `where Self.mut` is a COMPILE-TIME PROOF that `Self.origin`
        # is a mutable origin -- a caller holding a `mut=False` view cannot
        # reach this method at all (negative test: "violated constraint").
        # The cast therefore only restates what the gate already established;
        # it does not widen anyone's access. `unsafe_mut_cast[True]()` keeps
        # the CONCRETE origin (it is `Self.origin` with `mut` flipped), so
        # lifetime tracking is preserved -- this is NOT a wildcard origin and
        # does not fall under the `MutAnyOrigin`/`MutExternalOrigin` ban.
        # Note `unsafe_origin_cast` cannot be used here: it
        # requires the target origin to have the SAME `mut` as the source
        # ("cannot be converted from 'MutOrigin' to 'Origin[mut=mut]'").
        #
        # Every write method routes through this one accessor, so the module
        # has exactly ONE mutability cast rather than 13.
        """
        return self._data.unsafe_mut_cast[True]()

    @always_inline
    def write_u8_at(
        self, offset: Int, val: UInt8
    ) where Self.mut:
        """Store a UInt8 at `offset`. PANICS if offset+1 > len()."""
        debug_assert(
            offset >= 0 and offset + 1 <= self._len,
            "ByteView.write_u8_at: offset+1 > len",
        )
        (self._mut_data() + offset)[] = val

    @always_inline
    def write_u16_le_at(
        self, offset: Int, val: UInt16
    ) where Self.mut:
        """Store a little-endian UInt16 at `offset`. PANICS if offset+2 > len()."""
        debug_assert(
            offset >= 0 and offset + 2 <= self._len,
            "ByteView.write_u16_le_at: offset+2 > len",
        )
        (self._mut_data() + offset).bitcast[UInt16]().store[alignment=1](val)

    @always_inline
    def write_u32_le_at(
        self, offset: Int, val: UInt32
    ) where Self.mut:
        """Store a little-endian UInt32 at `offset`. PANICS if offset+4 > len()."""
        debug_assert(
            offset >= 0 and offset + 4 <= self._len,
            "ByteView.write_u32_le_at: offset+4 > len",
        )
        (self._mut_data() + offset).bitcast[UInt32]().store[alignment=1](val)

    @always_inline
    def write_u64_le_at(
        self, offset: Int, val: UInt64
    ) where Self.mut:
        """Store a little-endian UInt64 at `offset`. PANICS if offset+8 > len()."""
        debug_assert(
            offset >= 0 and offset + 8 <= self._len,
            "ByteView.write_u64_le_at: offset+8 > len",
        )
        (self._mut_data() + offset).bitcast[UInt64]().store[alignment=1](val)

    @always_inline
    def write_i32_le_at(
        self, offset: Int, val: Int32
    ) where Self.mut:
        """Store a little-endian Int32 at `offset`. PANICS if offset+4 > len()."""
        debug_assert(
            offset >= 0 and offset + 4 <= self._len,
            "ByteView.write_i32_le_at: offset+4 > len",
        )
        (self._mut_data() + offset).bitcast[Int32]().store[alignment=1](val)

    @always_inline
    def write_i64_le_at(
        self, offset: Int, val: Int64
    ) where Self.mut:
        """Store a little-endian Int64 at `offset`. PANICS if offset+8 > len()."""
        debug_assert(
            offset >= 0 and offset + 8 <= self._len,
            "ByteView.write_i64_le_at: offset+8 > len",
        )
        (self._mut_data() + offset).bitcast[Int64]().store[alignment=1](val)

    def write_bytes_at(
        self, offset: Int, src: ByteView[_]
    ) where Self.mut:
        """Copy bytes from `src` into this view starting at `offset`.

        PANICS if offset+src.len() > len() or offset < 0.

        Scalar per-byte loop; overlap-safe (can be used when `src` and
        `self` alias). For non-aliasing bulk copy on codec hot paths,
        prefer `copy_from_view_at` (memcpy-backed).
        """
        debug_assert(
            offset >= 0 and offset + src._len <= self._len,
            "ByteView.write_bytes_at: offset+src.len > len",
        )
        for i in range(src._len):
            # SAFETY: both ranges bounds-checked above.
            (self._mut_data() + offset + i)[] = (src._data + i)[]

    @always_inline
    def copy_from_view_at(
        self, offset: Int, src: ByteView[_]
    ) where Self.mut:
        """Bulk memcpy: copy `src.len()` bytes from `src` into `self` at `offset`.

        PANICS if offset+src.len() > len() or offset < 0.

        Equivalent to `memcpy(self._mut_data() + offset, src._data, src.len())`.
        Caller MUST ensure `src` and `self` do NOT alias -- on overlap the
        behavior is undefined (memcpy semantics). For overlap-safe copy
        use `write_bytes_at`, which is a scalar loop.

        Intended for codec hot paths (snappy / zlib / zstd literal emit)
        where per-byte scalar loops dominate runtime. Pointer arithmetic
        stays inside this module.
        """
        debug_assert(
            offset >= 0 and offset + src._len <= self._len,
            "ByteView.copy_from_view_at: offset+src.len > dst.len",
        )
        # SAFETY: bounds-checked above; caller guarantees non-overlap.
        # `fast_copy_bytes` is the unconditional bulk-copy kernel here.
        # SAFETY: the destination span names the RECEIVER'S OWN origin,
        # so its lifetime stays tracked (`unsafe_mut_cast[True]()` keeps the
        # concrete origin; no wildcard escape).
        # The pointer is bounds-checked above and does not escape
        # (`fast_copy_bytes` takes Spans and re-casts internally).
        fast_copy_bytes(
            Span[UInt8, Self.origin.unsafe_mut_cast[True]()](
                unsafe_ptr=self._mut_data() + offset,
                length=src._len,
            ),
            Span[UInt8, src.origin](
                unsafe_ptr=src._data, length=src._len
            ),
        )

    def fill(self, val: UInt8) where Self.mut:
        """Set every byte in this view to `val`."""
        if self._len <= 0:
            return
        unsafe_memset(self._mut_data(), val, self._len)

    @always_inline
    def store_simd[
        T: DType, width: Int
    ](
        self,
        byte_offset: Int,
        val: SIMD[T, width],
    ) where Self.mut:
        """Store `width` lanes of `T` starting at `byte_offset`.

        PANICS if byte_offset + width*sizeof[T]() > len() or
        byte_offset < 0.

        Parameters:
            T: The DType of each lane.
            width: The SIMD vector width.
        """
        comptime lane_bytes = size_of[T]() * width
        debug_assert(
            byte_offset >= 0 and byte_offset + lane_bytes <= self._len,
            "ByteView.store_simd: byte_offset + width*size_of[T] > len",
        )
        (self._mut_data() + byte_offset).bitcast[Scalar[T]]().store[
            alignment=1
        ](val)

    # =========================================================================
    # Arrow-bit-packed boolean helpers
    # -------------------------------------------------------------------------
    # BooleanArray output kernels need
    # two bit-level helpers on top of the existing byte-aligned write surface
    # (write_u8_at + read_u8_at). LSB-first within each byte (bit 0 of byte 0
    # = element 0), matching the Arrow Columnar Format spec for BooleanArray
    # and validity bitmaps.
    #
    # Both methods are receiver-refined for mut=True (consistent with the
    # other write_* methods above). Calling on a mut=False view fails to
    # compile.
    # =========================================================================

    @always_inline
    def store_bool_bitpacked(
        self, byte_i: Int, byte_val: UInt8
    ) where Self.mut:
        """Store one byte of bit-packed booleans (LSB-first within each
        byte = element 0..7 occupy bits 0..7 of byte `byte_i`).

        Thin wrapper over `write_u8_at`. Exists so the filter
        `_default_run_filter_self` body and downstream BooleanArray-output
        kernels have a clear, named API for the chunk-emit path rather than
        reaching for the generic byte writer.

        PANICS if byte_i+1 > len() or byte_i < 0.
        """
        debug_assert(
            byte_i >= 0 and byte_i + 1 <= self._len,
            "ByteView.store_bool_bitpacked: byte_i+1 > len",
        )
        (self._mut_data() + byte_i)[] = byte_val

    @always_inline
    def store_bool_one(
        self, bit_i: Int, value: Bool
    ) where Self.mut:
        """Set a single bit at element index `bit_i` (LSB-first within
        each byte). Used by the tail loop in `_default_run_filter_self`
        when `n_bits % 8 != 0`.

        Read-modify-write on a single byte; do NOT use in a hot inner
        loop covering whole batches -- prefer `store_bool_bitpacked` per
        byte for the bulk path.

        PANICS if bit_i < 0 or (bit_i >> 3) >= len().
        """
        var byte_i = bit_i >> 3
        var bit_in_byte = bit_i & 7
        debug_assert(
            bit_i >= 0 and byte_i < self._len,
            "ByteView.store_bool_one: bit_i out of range",
        )
        var existing = (self._mut_data() + byte_i)[]
        var mask = UInt8(1) << UInt8(bit_in_byte)
        if value:
            (self._mut_data() + byte_i)[] = existing | mask
        else:
            (self._mut_data() + byte_i)[] = existing & ~mask

    # =========================================================================
    # Stdlib bridge: Span[Byte, origin] over the same bytes (origin-preserving)
    # =========================================================================

    # =========================================================================
    # Origin-WIDENING reborrow (the single-origin band seam)
    # -------------------------------------------------------------------------
    # `reborrow_under` re-labels this view's origin onto a CONTAINING owner's
    # borrow origin `o2`, taking a `ref [o2] witness` so the compiler ties the
    # result to a LIVE borrow of that owner (no free/wildcard origin — the
    # result's lifetime is tracked against `witness`). This is the PUBLIC seam
    # that lets a producer bundle spans that physically live in DIFFERENT fields
    # of one owner under ONE coherent `origin` — exactly what `BandView[o]`
    # requires: the key/dict spans live in the ctx's
    # `_band_slots`, while a ZERO-COPY aggregand span lives in a cursor's decode
    # page-window scratch — BOTH owned by the ctx, so BOTH reborrow under
    # `origin_of(ctx)` into one bundle. It replaces the module-private
    # `_unsafe_ptr().unsafe_origin_cast[o]()` dance `BatchView` runs inline
    # with a named, SAFETY-documented method callable from
    # OUTSIDE the core packages (e.g. a Parquet producer, which cannot
    # reach `_unsafe_ptr`). Encapsulation-clean: ByteView in, ByteView out — no
    # UnsafePointer in the signature, no wildcard origin (`o2` is a concrete,
    # witnessed origin).
    # =========================================================================

    @always_inline
    def reborrow_under[
        W: AnyType, o2: Origin[mut=False], //
    ](self, ref [o2] witness: W) -> ByteView[o2]:
        """Reborrow these bytes UNDER the containing owner's read origin `o2`
        (inferred from `witness`), widening the view's origin.

        The result is a read-only (`mut=False`) `ByteView[o2]` over the SAME
        bytes; its lifetime is tracked against the `witness` borrow, so it stays
        valid exactly as long as the caller holds `witness`.

        USE: a producer that owns both a band-slot arena AND the
        per-column decode cursors (e.g. the parquet `ColumnDecodeContext`) calls
        this to place a cursor-page-window span and a band-slot span into ONE
        `BandView[origin_of(ctx)]`:

            var agg = cursor.grain_view_ro(n * w).reborrow_under(ctx)  # zero-copy
            var key = ctx.band_value_view_ro(k, n * 4)                 # or reborrow
            band.push_flat_col_page_view(agg, w)

        SAFETY (the ONE caller obligation): the caller GUARANTEES `witness`
        TRANSITIVELY OWNS the backing bytes — i.e. `o2` is a valid, containing
        origin for `self._data` (the bytes do not outlive `witness`). This is the
        same containment guarantee `BatchView`'s inline `unsafe_origin_cast[Self.
        origin]` relies on (the batch owns the column slab). The witness form is
        STRICTLY safer than a free-origin cast: you can only widen to an origin
        you are actively borrowing, so the type system still forbids naming a
        dead origin. Passing a `witness` that does NOT own the bytes is a
        contract violation (undefined behaviour), exactly as for the wrapped
        `unsafe_origin_cast`.
        """
        # SAFETY: per the method contract, `witness` transitively owns these
        # bytes, so `o2` is a containing origin for `self._data`. Narrow mut to
        # read (no-op when already read), then re-tie the origin to `o2`. The
        # `_data` escape stays INSIDE this module (byte_view.mojo is under
        # the core packages); only the widened SAFE
        # `ByteView[o2]` crosses back to the caller — no raw pointer, no
        # wildcard origin.
        return ByteView[o2](
            self._data.unsafe_mut_cast[False]().unsafe_origin_cast[o2](),
            self._len,
        )

    @always_inline
    def into_span(self) -> Span[Byte, Self.origin]:
        """Return a `Span[Byte, Self.origin]` over the same bytes.

        Bridge to stdlib APIs that accept `Span[Byte]` (notably
        `String(unsafe_from_utf8=...)`, file IO bytes, and other stdlib
        consumers). The span's origin is `Self.origin`, so the compiler
        tracks its liveness against the same backing storage as the view.

        Use case: writing buffer bytes to a FileHandle via the
        `String(unsafe_from_utf8=Span[Byte])` idiom while keeping the origin
        tied to the source MmapAlignedBuffer.

        SAFETY: the span's lifetime is tracked by `Self.origin`. No
        wildcard widening occurs; the caller's existing borrow of
        `self` keeps the span valid.
        """
        # Span[Byte, origin] takes (ptr, length) per stdlib span.mojo ctor.
        return Span[Byte, Self.origin](unsafe_ptr=self._data, length=self._len)

    # =========================================================================
    # Module-private escape (only files in the core packages may
    # call this)
    # =========================================================================

    @always_inline
    def _unsafe_ptr(self) -> UnsafePointer[UInt8, Self.origin]:
        """Module-private: raw origin-tied pointer for decoder hot loops.

        SAFETY: caller must not escape the pointer past `self`'s lifetime.
        File-private discipline: this pointer does NOT cross the module
        boundary via this method -- callers are other files under
        the core packages only.
        """
        return self._data


# =============================================================================
# ByteViewPair -- workaround struct for split_at
# =============================================================================


struct ByteViewPair[mut: Bool, //, origin: Origin[mut=mut]](Movable):
    """Pair of non-overlapping ByteView slices produced by `split_at`.

    Constructed empty-then-assigned to satisfy Mojo 0.26.3's exclusivity
    check on `Tuple[ByteView[mut=True, o], ByteView[mut=True, o]]`: the
    Tuple ctor receives both aliasing mutable views simultaneously, which
    is (correctly) rejected.

    Usage:
        var pair = view.split_at(mid)
        # access pair.lhs and pair.rhs independently.

    Parameters:
        mut: Whether the pair's halves permit mutation.
        origin: The origin both halves are tied to (shared with the
            source view).
    """

    var lhs: ByteView[Self.origin]
    var rhs: ByteView[Self.origin]

    @always_inline
    def __init__(out self):
        """Default-construct with two empty halves.

        Callers (specifically `ByteView.split_at`) fill the halves by
        direct field assignment -- never simultaneously as ctor args.
        This avoids passing two aliasing mutable views to the Tuple
        constructor (the exclusivity-check failure).
        """
        self.lhs = ByteView[Self.origin]()
        self.rhs = ByteView[Self.origin]()
