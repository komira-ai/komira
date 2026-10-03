# =============================================================================
# INTERVAL_MONTH_DAY_NANO ARRAY — Arrow IntervalMonthDayNano fixed-width column
# =============================================================================
#
# Mirrors `Decimal128Array` at
# 16-byte width but the 16 bytes are a STRUCTURED TRIPLE, not a single int128:
#
#   bytes [ 0 ..  4)  =  months  (Int32, signed, little-endian)
#   bytes [ 4 ..  8)  =  days    (Int32, signed, little-endian)
#   bytes [ 8 .. 16)  =  nanos   (Int64, signed, little-endian)
#
# Per the Arrow spec (`Schema.fbs`, `IntervalUnit::MONTH_DAY_NANO`):
#   "Indicates the number of elapsed whole months (M), days (d) and
#    nanoseconds (n).  Each field is independent (e.g. there is no
#    constraint that nanoseconds have the same sign as days or that
#    the quantity of nanoseconds represents less than a day's worth
#    of time)."
#
# Comparison semantics: the Arrow spec deliberately does NOT define an
# ordering on IntervalMonthDayNano values — they have no calendar-free
# total order (1 month vs 30 days vs 31 days vs ...).  Equality IS
# well-defined (componentwise).  Hash IS well-defined (combine the three
# fields).  This module provides equality and hash; ordering (lt/gt) is
# omitted intentionally — sort/group-by paths that need a deterministic
# tie-break should use the (months, days, nanos) lex order via the
# separate `lex_lt` helper, with the caveat that lex order is NOT
# semantically meaningful.
# =============================================================================

from std.sys import size_of

from std.memory import ArcPointer

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.bitmap import Bitmap


# Bytes per IntervalMonthDayNano element — Int32 + Int32 + Int64.
comptime INTERVAL_MDN_BYTE_WIDTH = 16
comptime INTERVAL_MDN_MONTHS_OFFSET = 0
comptime INTERVAL_MDN_DAYS_OFFSET = 4
comptime INTERVAL_MDN_NANOS_OFFSET = 8


struct IntervalMonthDayNanoArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """Arrow IntervalMonthDayNano column — packed (months, days, nanos).

    Physical storage: each value is 16 bytes packed as:
        offset 0:  Int32 months (little-endian)
        offset 4:  Int32 days   (little-endian)
        offset 8:  Int64 nanos  (little-endian)

    Per the Arrow spec, the three fields are independent — no constraint
    that nanos < 1 day or that signs agree.  Comparison/ordering is
    undefined (calendar-dependent); only equality and hash are
    semantically well-defined.

    Fields:
        data:       Aligned byte buffer holding N x 16 bytes.
        validity:   Optional null bitmap (None = no nulls).
        length:     Number of IntervalMonthDayNano elements.
        null_count: Number of null elements (0 when validity is None).
    """

    # Holder field is SharedAlignedBuffer.
    var data: SharedAlignedBuffer[Self.K]
    var validity: Optional[Bitmap[HeapRegion]]
    var length: Int
    var null_count: Int

    # --- LIFECYCLE ---

    @staticmethod
    def allocate(length: Int) -> IntervalMonthDayNanoArray[HeapRegion]:
        """Allocate a non-nullable IntervalMonthDayNano array, zero-init."""
        var buf = OwnedAlignedBuffer(max(length, 1) * INTERVAL_MDN_BYTE_WIDTH)
        buf.zero()
        buf.set_length(Int64(length * INTERVAL_MDN_BYTE_WIDTH))

        var arr = IntervalMonthDayNanoArray[HeapRegion]()
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = Optional[Bitmap[HeapRegion]](None)
        arr.length = length
        arr.null_count = 0
        return arr^

    @staticmethod
    def allocate_nullable(length: Int) -> IntervalMonthDayNanoArray[HeapRegion]:
        """Allocate a nullable IntervalMonthDayNano array, all-valid."""
        var buf = OwnedAlignedBuffer(max(length, 1) * INTERVAL_MDN_BYTE_WIDTH)
        buf.zero()
        buf.set_length(Int64(length * INTERVAL_MDN_BYTE_WIDTH))

        var bm = Bitmap.create_all_valid(length)
        var arr = IntervalMonthDayNanoArray[HeapRegion]()
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = bm^
        arr.length = length
        arr.null_count = 0
        return arr^

    def __init__(out self):
        """Internal: create an empty IntervalMonthDayNanoArray.

        Constrained to K=HeapRegion (no-arg ctor
        produces a HeapRegion-backed empty buffer).
        """
        comptime assert (Self.K == HeapRegion), ( "IntervalMonthDayNanoArray.__init__(): no-arg empty ctor" " requires K=HeapRegion." )
        # Build SAB[Self.K] empty placeholder.
        var empty_region = HeapRegion(List[UInt8]())
        var arc_heap = ArcPointer[HeapRegion](empty_region^)
        var arc_self_k = rebind[ArcPointer[Self.K]](arc_heap^)
        self.data = SharedAlignedBuffer[Self.K](
            region=arc_self_k^, offset=0, length=0
        )
        self.validity = Optional[Bitmap[HeapRegion]](None)
        self.length = 0
        self.null_count = 0

    def __init__(
        out self,
        var data: OwnedAlignedBuffer,
        var validity: Optional[Bitmap[HeapRegion]],
        length: Int,
        null_count: Int,
    ):
        """Construct an IntervalMonthDayNanoArray directly from an
        OwnedAlignedBuffer.

        OAB-accepting overload. The OAB is
        promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only). The `allocate()` and
        `allocate_nullable()` factories are separate entry points.

        Args:
            data: Aligned byte buffer of length * INTERVAL_MDN_BYTE_WIDTH bytes.
            validity: Optional null bitmap.
            length: Number of IntervalMonthDayNano elements.
            null_count: Number of null elements.
        """
        comptime assert (Self.K == HeapRegion), ( "IntervalMonthDayNanoArray.__init__(OwnedAlignedBuffer...):" " OAB ctor requires K=HeapRegion (OAB is heap-only)." )
        self.data = bridge_oab_to_sab[Self.K](data^)
        self.validity = validity^
        self.length = length
        self.null_count = null_count

    # --- ELEMENT ACCESS (per-component) ---

    @always_inline
    def get_months(self, index: Int) raises -> Int32:
        """Read the months component at `index`."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.get_months: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        return self.data.read_i32_le_at(
            index * INTERVAL_MDN_BYTE_WIDTH + INTERVAL_MDN_MONTHS_OFFSET
        )

    @always_inline
    def get_days(self, index: Int) raises -> Int32:
        """Read the days component at `index`."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.get_days: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        return self.data.read_i32_le_at(
            index * INTERVAL_MDN_BYTE_WIDTH + INTERVAL_MDN_DAYS_OFFSET
        )

    @always_inline
    def get_nanos(self, index: Int) raises -> Int64:
        """Read the nanos component at `index`."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.get_nanos: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        return self.data.read_i64_le_at(
            index * INTERVAL_MDN_BYTE_WIDTH + INTERVAL_MDN_NANOS_OFFSET
        )

    @always_inline
    def get_triple(self, index: Int) raises -> Tuple[Int32, Int32, Int64]:
        """Read the (months, days, nanos) triple at `index`."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.get_triple: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        var base = index * INTERVAL_MDN_BYTE_WIDTH
        var m = self.data.read_i32_le_at(base + INTERVAL_MDN_MONTHS_OFFSET)
        var d = self.data.read_i32_le_at(base + INTERVAL_MDN_DAYS_OFFSET)
        var n = self.data.read_i64_le_at(base + INTERVAL_MDN_NANOS_OFFSET)
        return (m, d, n)

    def set_triple(
        mut self, index: Int, months: Int32, days: Int32, nanos: Int64
    ) raises:
        """Write a (months, days, nanos) triple at `index`.  If nullable,
        marks the slot as valid."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.set_triple: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        var base = index * INTERVAL_MDN_BYTE_WIDTH
        self.data.write_i32_le_at(base + INTERVAL_MDN_MONTHS_OFFSET, months)
        self.data.write_i32_le_at(base + INTERVAL_MDN_DAYS_OFFSET, days)
        self.data.write_i64_le_at(base + INTERVAL_MDN_NANOS_OFFSET, nanos)
        if self.validity:
            if not self.validity.value().test(index):
                self.null_count -= 1
            self.validity.value().set(index)

    @staticmethod
    def from_triples(
        triples: List[Tuple[Int32, Int32, Int64]]
    ) raises -> IntervalMonthDayNanoArray[HeapRegion]:
        """Build a non-nullable IntervalMonthDayNanoArray from a list of
        (months, days, nanos) triples."""
        var arr = IntervalMonthDayNanoArray[HeapRegion].allocate(len(triples))
        for i in range(len(triples)):
            var t = triples[i]
            var base = i * INTERVAL_MDN_BYTE_WIDTH
            arr.data.write_i32_le_at(base + INTERVAL_MDN_MONTHS_OFFSET, t[0])
            arr.data.write_i32_le_at(base + INTERVAL_MDN_DAYS_OFFSET, t[1])
            arr.data.write_i64_le_at(base + INTERVAL_MDN_NANOS_OFFSET, t[2])
        return arr^

    # --- NULLABILITY ---

    def is_null(self, index: Int) raises -> Bool:
        """Check if element at `index` is null."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.is_null: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        if not self.validity:
            return False
        return not self.validity.value().test(index)

    def set_null(mut self, index: Int) raises:
        """Mark element at `index` as null."""
        if index < 0 or index >= self.length:
            raise Error(
                "IntervalMonthDayNanoArray.set_null: index "
                + String(index) + " out of range [0, "
                + String(self.length) + ")"
            )
        if not self.validity:
            # Validity is Bitmap[HeapRegion] (driver-owned), even
            # for borrowed-K data. Mutation lazy-allocates a heap bitmap.
            self.validity = Bitmap.create_all_valid(self.length)
        if self.validity.value().test(index):
            self.null_count += 1
        self.validity.value().clear(index)

    # --- SIZED ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of IntervalMonthDayNano elements."""
        return self.length
