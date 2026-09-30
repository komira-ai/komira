# =============================================================================
# BOOLEAN ARRAY — Arrow-spec 1-bit-packed boolean column
# =============================================================================
#
# Arrow BooleanArray stores one bit per boolean value, LSB-first within each
# byte — identical layout to Arrow validity bitmaps. This is 8x more compact
# than using 1 byte per boolean (PrimitiveArray[DType.bool]).
#
# Internally wraps a Bitmap for the data buffer and an Optional[Bitmap[HeapRegion]] for
# the null/validity bitmap.
#
# Convention (matching Arrow):
#   Data bitmap:     1 = True, 0 = False
#   Validity bitmap: 1 = valid (not null), 0 = null
# =============================================================================

from ..io.heap_region import HeapRegion
from .bitmap import Bitmap


struct BooleanArray(Movable, Sized):
    """Arrow-spec 1-bit-packed boolean column.

    Fields:
        data:       Packed boolean values (1 bit per element).
        validity:   Null bitmap (None = no nulls, all elements valid).
        length:     Number of logical boolean elements.
        null_count: Number of null elements (0 when validity is None).
    """

    var data: Bitmap[HeapRegion]
    var validity: Optional[Bitmap[HeapRegion]]
    var length: Int
    var null_count: Int

    # --- LIFECYCLE ---

    def __init__(out self):
        """Internal: create an empty BooleanArray."""
        self.data = Bitmap[HeapRegion]()
        self.validity = Optional[Bitmap[HeapRegion]](None)
        self.length = 0
        self.null_count = 0

    @staticmethod
    def allocate(length: Int) -> BooleanArray:
        """Allocate a non-nullable BooleanArray with all values False.

        Args:
            length: Number of boolean elements.

        Returns:
            A new BooleanArray with all bits cleared (False), no validity bitmap.
        """
        var arr = BooleanArray()
        arr.data = Bitmap.create(length)
        arr.validity = Optional[Bitmap[HeapRegion]](None)
        arr.length = length
        arr.null_count = 0
        return arr^

    @staticmethod
    def allocate_nullable(length: Int) -> BooleanArray:
        """Allocate a nullable BooleanArray with all values False, all valid.

        Args:
            length: Number of boolean elements.

        Returns:
            A new BooleanArray with all data bits cleared (False) and all
            validity bits set (all elements are valid / not null).
        """
        var arr = BooleanArray()
        arr.data = Bitmap.create(length)
        arr.validity = Optional[Bitmap[HeapRegion]](Bitmap.create_all_valid(length))
        arr.length = length
        arr.null_count = 0
        return arr^

    @staticmethod
    def from_bitmap(var data: Bitmap[HeapRegion]) -> BooleanArray:
        """Wrap an existing Bitmap as a non-nullable BooleanArray.

        The Bitmap is consumed (transferred) — caller must not use it after.

        Args:
            data: The bitmap to wrap. Ownership is transferred.

        Returns:
            A new BooleanArray backed by the given bitmap.
        """
        var arr = BooleanArray()
        arr.length = data.length
        arr.null_count = 0
        arr.validity = Optional[Bitmap[HeapRegion]](None)
        arr.data = data^
        return arr^

    # --- ELEMENT ACCESS ---

    def get(self, index: Int) raises -> Bool:
        """Read the boolean value at `index`.

        Args:
            index: Element index (0-based).

        Returns:
            True if the bit is set, False otherwise.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error("BooleanArray.get: index out of bounds")
        return self.data.test(index)

    def set(mut self, index: Int, value: Bool):
        """Write the boolean value at `index`.

        Args:
            index: Element index (0-based).
            value: True to set the bit, False to clear it.
        """
        if value:
            self.data.set(index)
        else:
            self.data.clear(index)

    # --- NULLABILITY ---

    def is_null(self, index: Int) raises -> Bool:
        """Check whether the element at `index` is null.

        Args:
            index: Element index (0-based).

        Returns:
            True if the element is null, False if valid.
            Always returns False when there is no validity bitmap.

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error("BooleanArray.is_null: index out of bounds")
        if self.validity:
            return not self.validity.value().test(index)
        return False

    def _set_null(mut self, index: Int):
        """Mark the element at `index` as null.

        If no validity bitmap exists, one is created with all elements valid
        before marking the given index as null.

        Args:
            index: Element index (0-based).
        """
        if not self.validity:
            self.validity = Optional[Bitmap[HeapRegion]](Bitmap.create_all_valid(self.length))
        # ⛔ IDEMPOTENT, AND THAT IS THE WHOLE POINT. The bump is
        # conditional on the row being VALID right now, so marking an
        # ALREADY-NULL row is a no-op on the count. An UNCONDITIONAL
        # `null_count += 1` double-counted every row that two writers both
        # imposed a NULL on, leaving the validity BITMAP correct and the COUNT
        # wrong -- which is invisible to a value assertion and rides straight
        # out over the wire (arrow IPC `FieldNode.null_count`,
        # C-Data `ArrowArray.null_count`).
        #
        # THE FAILURE CASE: the pattern kernels' `_apply_validity` ASSIGNS
        # `null_count`, and the EXPR_STRING_OP projection arm then re-imposes
        # the same child validity through this method -- 1 NULL counted as 2.
        # `primitive_array._set_null`'s docstring argues "no double-count"
        # from callers ASSIGNING the count AFTER a `_set_null` loop; that
        # argument does not hold when the assignment comes FIRST.
        #
        # The sibling `_set_valid` below already recomputes from the bitmap.
        if self.validity.value().test(index):
            self.null_count += 1
        self.validity.value().clear(index)

    def _set_valid(mut self, index: Int):
        """Mark the element at `index` as valid (not null).

        No-op if there is no validity bitmap.

        Args:
            index: Element index (0-based).
        """
        if self.validity:
            self.validity.value().set(index)
            # Recompute null_count from validity bitmap
            self.null_count = self.validity.value().null_count()

    # --- AGGREGATES ---

    def true_count(self) -> Int:
        """Count the number of True values (set bits) in the data bitmap.

        Uses popcount which is SIMD-accelerated on modern CPUs.

        Returns:
            Number of elements whose data bit is 1.
        """
        return self.data.popcount()

    def false_count(self) -> Int:
        """Count the number of False values (unset bits) in the data bitmap.

        Returns:
            Number of elements whose data bit is 0.
        """
        return self.length - self.data.popcount()

    # --- SIZED ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of logical boolean elements."""
        return self.length
