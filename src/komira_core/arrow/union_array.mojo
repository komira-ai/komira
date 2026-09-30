# =============================================================================
# UnionArray — Arrow-compatible Union columnar array (sparse + dense)
# =============================================================================
#
# Arrow format for unions (per the Arrow columnar spec):
#
#   * Sparse union (+us:I,J,...):
#       1 buffer:  types buffer (N Int8 type-ids).
#       N child arrays, EACH the same length N as the parent.
#       NO validity bitmap on the union itself (nullness is determined
#       exclusively by the child arrays — Arrow spec).
#
#   * Dense union (+ud:I,J,...):
#       2 buffers: types buffer (N Int8 type-ids) + offsets buffer (N Int32).
#       N child arrays, each with independent length.
#       Offsets[i] is the row-index into the child selected by types[i].
#       NO validity bitmap on the union itself.
#
# Type-ids: a non-negative Int8 per slot. They are NOT necessarily 0..N-1;
# the format string `+us:I,J,...` declares the mapping from logical
# type-id -> child-index.  The Field's `_union_type_ids: List[Int]` carries
# the parallel-to-children type-id list; the Column-level `_type_ids` slot
# mirrors it on the type-erased Column.
#
# Children are stored in a `Slab[Column]` — same pattern as StructArray.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from ..collections.slab import Slab

from std.memory import ArcPointer

from .owned_aligned_buffer import OwnedAlignedBuffer
from .shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from .arrow_types import ArrowType
from .bitmap import Bitmap
from .column import Column
from ..io.heap_region import HeapRegion
from ..io.memory_region import MemoryRegion


struct UnionArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """Arrow Union array — sparse or dense mixed-type column.

    Layout:
      mode      : ArrowType.UNION_SPARSE or ArrowType.UNION_DENSE.
      type_ids  : List[Int] of declared type-ids, parallel to `_children`.
                  Length == num_children. Per Arrow spec, type-id values are
                  non-negative Int8s but are otherwise arbitrary.
      types_buf : N Int8 type-id values (one per parent row).  For each row,
                  types_buf[i] identifies which child the value lives in.
      offsets   : Dense-only.  N Int32 values; offsets[i] is the row-index
                  into the child array selected by `types_buf[i]`.  Empty
                  for sparse unions.
      _children : Slab[Column] holding the N child Columns.  For sparse,
                  every child's length equals the parent's length.  For
                  dense, child lengths are independent.
      length    : Number of parent rows (== len(types_buf)).

    Unions have NO validity bitmap of their own (per Arrow spec); each row's
    nullness is determined entirely by the selected child's validity.
    """

    var mode: ArrowType
    var type_ids: List[Int]
    # Holder fields are SharedAlignedBuffer.
    var types_buf: SharedAlignedBuffer[Self.K]
    var offsets_buf: Optional[SharedAlignedBuffer[Self.K]]
    var _children: Slab[Column[HeapRegion]]
    var length: Int

    # --- Constructors ---

    def __init__(out self):
        """Create an empty sparse UnionArray with 0 children and 0 rows.

        Constrained to K=HeapRegion because the
        no-arg ctor constructs HeapRegion-backed empty buffers.
        """
        comptime assert (Self.K == HeapRegion), ( "UnionArray.__init__(): no-arg empty ctor requires" " K=HeapRegion (MmapAlignedBuffer[64](1) is HeapRegion-backed)." )
        self.mode = ArrowType.UNION_SPARSE
        self.type_ids = List[Int]()
        # Build a SAB[Self.K] over a 1-byte HeapRegion
        # (mirrors the `MmapAlignedBuffer[64, Self.K](1)` placeholder; the
        # set_length(0) below logically empties the addressable extent).
        var placeholder_bytes = List[UInt8]()
        placeholder_bytes.append(0)
        var placeholder_region = HeapRegion(placeholder_bytes^)
        var arc_heap = ArcPointer[HeapRegion](placeholder_region^)
        var arc_self_k = rebind[ArcPointer[Self.K]](arc_heap^)
        self.types_buf = SharedAlignedBuffer[Self.K](
            region=arc_self_k^, offset=0, length=1
        )
        self.types_buf.set_length(0)

        self.offsets_buf = None
        self._children = Slab[Column[HeapRegion]]()
        self.length = 0

    @staticmethod
    def _build_sparse(
        type_ids: List[Int],
        var types_buf: OwnedAlignedBuffer,
        var children: Slab[Column[HeapRegion]],
        length: Int,
    ) raises -> UnionArray[HeapRegion]:
        """Internal: assemble a sparse UnionArray from validated components.

        Ctor accepts OAB types_buf; bridges to SAB[HeapRegion] via
        `bridge_oab_to_sab`.
        """
        var ua = UnionArray[HeapRegion]()
        ua.mode = ArrowType.UNION_SPARSE
        ua.type_ids = type_ids.copy()
        ua.types_buf = bridge_oab_to_sab[HeapRegion](types_buf^)
        ua.offsets_buf = None
        ua._children = children^
        ua.length = length
        return ua^

    @staticmethod
    def _build_dense(
        type_ids: List[Int],
        var types_buf: OwnedAlignedBuffer,
        var offsets_buf: OwnedAlignedBuffer,
        var children: Slab[Column[HeapRegion]],
        length: Int,
    ) raises -> UnionArray[HeapRegion]:
        """Internal: assemble a dense UnionArray from validated components.

        Bridges both OAB inputs to SAB[HeapRegion].
        """
        var ua = UnionArray[HeapRegion]()
        ua.mode = ArrowType.UNION_DENSE
        ua.type_ids = type_ids.copy()
        ua.types_buf = bridge_oab_to_sab[HeapRegion](types_buf^)
        ua.offsets_buf = Optional(bridge_oab_to_sab[HeapRegion](offsets_buf^))
        ua._children = children^
        ua.length = length
        return ua^

    @staticmethod
    def sparse_from_children_2(
        type_ids: List[Int],
        types: List[Int8],
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
    ) raises -> UnionArray[HeapRegion]:
        """Create a sparse UnionArray from 2 child columns + a parallel
        types-buffer list.  Both children MUST have the same length as the
        types list (Arrow sparse-union invariant).

        Args:
            type_ids: Two declared type-ids matching the children's order.
                Length must be 2.
            types: Per-row Int8 type-id (one entry per parent row).  Must
                match one of the entries in `type_ids`.
            col0: First child column (selected when row's type == type_ids[0]).
            col1: Second child column.

        Returns:
            A new sparse UnionArray.

        Raises:
            Error on type-ids count mismatch or child-length mismatch.
        """
        if len(type_ids) != 2:
            raise Error(
                "UnionArray.sparse_from_children_2: expected 2 type-ids, got "
                + String(len(type_ids))
            )
        var n = len(types)
        if col0._length != n:
            raise Error(
                "UnionArray.sparse_from_children_2: child 0 length ("
                + String(col0._length)
                + ") != types buffer length ("
                + String(n)
                + ")"
            )
        if col1._length != n:
            raise Error(
                "UnionArray.sparse_from_children_2: child 1 length ("
                + String(col1._length)
                + ") != types buffer length ("
                + String(n)
                + ")"
            )
        comptime int8_size = size_of[Int8]()
        var types_buf = OwnedAlignedBuffer(max(n * int8_size, 1))
        for i in range(n):
            types_buf.set_typed[Int8](i, types[i])
        types_buf.set_length(Int64(n * int8_size))


        var kids = Slab[Column[HeapRegion]].create(2)
        kids.append(col0^)
        kids.append(col1^)
        return UnionArray[HeapRegion]._build_sparse(type_ids, types_buf^, kids^, n)

    @staticmethod
    def dense_from_children_2(
        type_ids: List[Int],
        types: List[Int8],
        offsets: List[Int32],
        var col0: Column[HeapRegion],
        var col1: Column[HeapRegion],
    ) raises -> UnionArray[HeapRegion]:
        """Create a dense UnionArray from 2 child columns + types + offsets.

        Children may have INDEPENDENT lengths.  `offsets[i]` is the row-index
        into the child selected by `types[i]`.

        Args:
            type_ids: Two declared type-ids matching the children's order.
            types: Per-row Int8 type-id; length is the parent length.
            offsets: Per-row Int32 offset into the selected child.  Length
                must equal types' length.
            col0: First child column.
            col1: Second child column.

        Returns:
            A new dense UnionArray.

        Raises:
            Error on count mismatches or out-of-range offsets.
        """
        if len(type_ids) != 2:
            raise Error(
                "UnionArray.dense_from_children_2: expected 2 type-ids, got "
                + String(len(type_ids))
            )
        var n = len(types)
        if len(offsets) != n:
            raise Error(
                "UnionArray.dense_from_children_2: offsets length ("
                + String(len(offsets))
                + ") != types length ("
                + String(n)
                + ")"
            )
        comptime int8_size = size_of[Int8]()
        comptime int32_size = size_of[Int32]()
        var types_buf = OwnedAlignedBuffer(max(n * int8_size, 1))
        for i in range(n):
            types_buf.set_typed[Int8](i, types[i])
        types_buf.set_length(Int64(n * int8_size))


        var offsets_buf = OwnedAlignedBuffer(max(n * int32_size, 1))
        for i in range(n):
            offsets_buf.set_typed[Int32](i, offsets[i])
        offsets_buf.set_length(Int64(n * int32_size))


        var kids = Slab[Column[HeapRegion]].create(2)
        kids.append(col0^)
        kids.append(col1^)
        return UnionArray[HeapRegion]._build_dense(
            type_ids, types_buf^, offsets_buf^, kids^, n
        )

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Number of parent rows."""
        return self.length

    @always_inline
    def num_children(self) -> Int:
        """Number of child columns."""
        return len(self._children)

    @always_inline
    def child_at(self, index: Int) -> ref [self._children._bytes] Column[HeapRegion]:
        """Safe reference to the child Column[HeapRegion] at `index`."""
        return self._children[index]

    @always_inline
    def type_id_at(self, row: Int) -> Int8:
        """Type-id of the value at parent row `row` (from the types buffer)."""
        return self.types_buf.get_typed[Int8](row)

    @always_inline
    def offset_at(self, row: Int) raises -> Int32:
        """Dense union only: offset into the selected child at parent row
        `row`.  Raises on sparse unions (offsets buffer is empty)."""
        if not self.offsets_buf:
            raise Error("UnionArray.offset_at: sparse union has no offsets buffer")
        return self.offsets_buf.value().get_typed[Int32](row)

    @always_inline
    def is_dense(self) -> Bool:
        """True iff this is a dense union (has an offsets buffer)."""
        return self.mode == ArrowType.UNION_DENSE

    @always_inline
    def is_sparse(self) -> Bool:
        """True iff this is a sparse union (no offsets buffer)."""
        return self.mode == ArrowType.UNION_SPARSE

    # --- Column round-trip (UnionArray <-> type-erased Column) ---
    #
    # Layout on the Column:
    #   arrow_type : ArrowType.UNION_SPARSE / UNION_DENSE.
    #   _data      : types buffer (N Int8) — mirrors the Arrow types buffer.
    #   _offsets   : dense-only Int32 offsets buffer (None for sparse).
    #   _validity  : ALWAYS None — unions have no validity bitmap (Arrow spec).
    #   _children  : Slab[Column] of N children.
    #   _type_ids  : List[Int] of declared type-ids, parallel to `_children`.

    def to_column(self) raises -> Column[HeapRegion]:
        """Pack this UnionArray into a type-erased Column.  Reversible via
        `from_column`."""
        # Copy types buffer (Int8, length == self.length).
        comptime int8_size = size_of[Int8]()
        var types_bytes = self.length * int8_size
        var types_copy = OwnedAlignedBuffer(max(types_bytes, 1))
        if types_bytes > 0:
            types_copy.copy_from_view(
                self.types_buf.view_range_ro(0, types_bytes)
            )
        types_copy.set_length(Int64(types_bytes))


        # Dense-only: copy offsets buffer (Int32, length == self.length).
        var off_copy_opt = Optional[OwnedAlignedBuffer](None)
        if self.is_dense():
            comptime int32_size = size_of[Int32]()
            var off_bytes = self.length * int32_size
            var off_copy = OwnedAlignedBuffer(max(off_bytes, 1))
            if off_bytes > 0 and self.offsets_buf:
                off_copy.copy_from_view(
                    self.offsets_buf.value().view_range_ro(0, off_bytes)
                )
            off_copy.set_length(Int64(off_bytes))

            off_copy_opt = off_copy^

        var col = Column[HeapRegion](
            arrow_type=self.mode,
            data=types_copy^,
            offsets=off_copy_opt^,
            validity=None,  # unions have no validity bitmap
            length=self.length,
            null_count=0,
            offset=0,
        )

        # Deep-copy children + carry the declared type-ids.
        var nchild = self.num_children()
        var kids = Slab[Column[HeapRegion]].create(max(nchild, 1))
        for i in range(nchild):
            kids.append(self.child_at(i).deep_copy())
        col._children = kids^
        col._type_ids = self.type_ids.copy()
        return col^

    @staticmethod
    def from_column(col: Column[HeapRegion]) raises -> UnionArray[HeapRegion]:
        """Unpack a `Column[HeapRegion]` (built by `to_column`) back into a UnionArray."""
        if (
            col.arrow_type != ArrowType.UNION_SPARSE
            and col.arrow_type != ArrowType.UNION_DENSE
        ):
            raise Error(
                "UnionArray.from_column: arrow_type is "
                + String(col.arrow_type)
                + ", expected union[sparse] or union[dense]"
            )
        var nchild = len(col._children)
        var n_type_ids = len(col._type_ids)
        if n_type_ids != nchild:
            raise Error(
                "UnionArray.from_column: type-ids length ("
                + String(n_type_ids)
                + ") != children length ("
                + String(nchild)
                + ")"
            )

        # Copy types buffer.
        comptime int8_size = size_of[Int8]()
        var types_bytes = col._length * int8_size
        var types_copy = OwnedAlignedBuffer(max(types_bytes, 1))
        if types_bytes > 0:
            types_copy.copy_from_view(col._data.view_range_ro(0, types_bytes))
        types_copy.set_length(Int64(types_bytes))


        # Deep-copy children.
        var kids = Slab[Column[HeapRegion]].create(max(nchild, 1))
        for i in range(nchild):
            kids.append(col._children[i].deep_copy())

        if col.arrow_type == ArrowType.UNION_SPARSE:
            return UnionArray[HeapRegion]._build_sparse(
                col._type_ids, types_copy^, kids^, col._length
            )

        # Dense — copy offsets buffer too.
        if not col._offsets:
            raise Error(
                "UnionArray.from_column: dense union missing offsets buffer"
            )
        comptime int32_size = size_of[Int32]()
        var off_bytes = col._length * int32_size
        var off_copy = OwnedAlignedBuffer(max(off_bytes, 1))
        if off_bytes > 0:
            off_copy.copy_from_view(
                col._offsets.value().view_range_ro(0, off_bytes)
            )
        off_copy.set_length(Int64(off_bytes))

        return UnionArray[HeapRegion]._build_dense(
            col._type_ids, types_copy^, off_copy^, kids^, col._length
        )
