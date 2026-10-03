# =============================================================================
# MapArray — Arrow-compatible key-value map columnar array
# =============================================================================
#
# Arrow format for Map:
#   A Map is physically a List of Struct{key, value} with a keys_sorted flag.
#   offsets buffer: N+1 Int32 values — offsets[i] is the start index of map i
#       in the keys/values arrays, offsets[N] is the total number of entries.
#       Map i contains entries from offsets[i] to offsets[i+1].
#   keys: a Column holding the flat array of all keys across all maps.
#   values: a Column holding the flat array of all values across all maps.
#   validity bitmap: optional, 1 bit per element (1=valid, 0=null).
#
# Keys and values are parallel arrays of the same length. This is equivalent
# to List<Struct{key, value}> in the Arrow type system.
#
# Memory is managed by MmapAlignedBuffer (offsets), Column (keys, values), and
# Bitmap (validity). No manual free needed.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_collections.slab import Slab

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.struct_array import StructArray


struct MapArray[K: MemoryRegion = HeapRegion](Movable, Sized):
    """Arrow Map array — key-value pairs per row.

    Physical layout: Int32 offsets (N+1) + keys Column + values Column.
    Map element i contains entries from offsets[i] to offsets[i+1].
    Keys and values are parallel arrays of the same length.

    Fields:
        offsets: Aligned buffer holding N+1 Int32 offset values.
        keys: Column holding the flat array of all keys across all maps.
            Type-erased so any Arrow type can be the key.
        values: Column holding the flat array of all values across all maps.
            Type-erased so any Arrow type can be the value.
        validity: Optional validity bitmap (Arrow convention: bit=1 means
            valid, bit=0 means null). None means "no nulls" (fast path).
        length: Number of logical map elements.
        null_count: Number of null (invalid) elements. 0 when validity is None.
        keys_sorted: Whether the keys within each map element are sorted.
            This is a metadata flag from the Arrow spec (Map type has a
            keys_sorted field). It does NOT enforce sorting — it is the
            producer's responsibility to guarantee ordering.
    """

    # Holder field is SharedAlignedBuffer.
    var offsets: SharedAlignedBuffer[Self.K]
    var keys: Column[HeapRegion]
    var values: Column[HeapRegion]
    var validity: Optional[Bitmap[Self.K]]
    var length: Int
    var null_count: Int
    var keys_sorted: Bool

    # --- Constructors ---

    def __init__(
        out self,
        var offsets: SharedAlignedBuffer[Self.K],
        var keys: Column[HeapRegion],
        var values: Column[HeapRegion],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        null_count: Int,
        keys_sorted: Bool,
    ):
        """Construct a MapArray directly from SharedAlignedBuffer offsets.

        SAB-accepting overload (the canonical shape).
        """
        self.offsets = offsets^
        self.keys = keys^
        self.values = values^
        self.validity = validity^
        self.length = length
        self.null_count = null_count
        self.keys_sorted = keys_sorted

    def __init__(
        out self,
        var offsets: OwnedAlignedBuffer,
        var keys: Column[HeapRegion],
        var values: Column[HeapRegion],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        null_count: Int,
        keys_sorted: Bool,
    ):
        """Construct a MapArray directly from an OwnedAlignedBuffer offsets.

        OAB-accepting overload. The OAB is
        promoted to SAB[HeapRegion] via `from_owned`. Constrained to
        `Self.K == HeapRegion` (OAB is heap-only).
        """
        comptime assert (Self.K == HeapRegion), ( "MapArray.__init__(OwnedAlignedBuffer...): OAB ctor" " requires K=HeapRegion (OAB is heap-only); borrowed-K" " arrays must use the SAB-accepting overload above." )
        self.offsets = bridge_oab_to_sab[Self.K](offsets^)
        self.keys = keys^
        self.values = values^
        self.validity = validity^
        self.length = length
        self.null_count = null_count
        self.keys_sorted = keys_sorted

    @staticmethod
    def from_string_int_maps(
        maps: List[List[Tuple[String, Int]]]
    ) raises -> MapArray[HeapRegion]:
        """Create a non-nullable MapArray of String->Int64 maps.

        Each inner list is a list of (key, value) tuples representing one
        map element. The keys become a StringArray and the values become
        a PrimitiveArray[int64], both wrapped in Columns.

        Args:
            maps: List of maps, where each map is a list of (String, Int)
                tuples. All maps are treated as valid (non-null).

        Returns:
            A new MapArray with String keys and Int64 values.
        """
        var num_maps = len(maps)

        # First pass: count total entries across all maps
        var total_entries = 0
        for i in range(num_maps):
            total_entries += len(maps[i])

        # Build offsets buffer (N+1 entries of Int32)
        # Migrated `_unsafe_data_ptr().bitcast[Int32]()` +
        # init_pointee_copy onto `MmapAlignedBuffer.set_typed[Int32]`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(
            (num_maps + 1) * int32_size
        )
        offsets_buf.set_typed[Int32](0, Int32(0))

        var offset = 0
        for i in range(num_maps):
            offset += len(maps[i])
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))
        offsets_buf.set_length(Int64((num_maps + 1) * int32_size))


        # Build keys (StringArray) and values (PrimitiveArray[int64])
        var key_strings = List[String]()
        var value_ints = List[Scalar[DType.int64]]()
        for i in range(num_maps):
            for j in range(len(maps[i])):
                key_strings.append(maps[i][j][0])
                value_ints.append(Scalar[DType.int64](maps[i][j][1]))

        var keys_arr = StringArray.from_strings(key_strings)
        var keys_col = Column.from_string(keys_arr)

        var values_arr = PrimitiveArray[DType.int64].from_list(value_ints)
        var values_col = Column.from_primitive[DType.int64](values_arr)

        return MapArray[HeapRegion](
            offsets=offsets_buf^,
            keys=keys_col^,
            values=values_col^,
            validity=None,
            length=num_maps,
            null_count=0,
            keys_sorted=False,
        )

    @staticmethod
    def from_string_int_maps_nullable(
        maps: List[List[Tuple[String, Int]]],
        valid_mask: List[Bool],
    ) raises -> MapArray[HeapRegion]:
        """Create a nullable MapArray of String->Int64 maps.

        Elements where valid_mask[i] is False are marked null. The
        corresponding entries are still stored (Arrow convention: null
        maps may have arbitrary offset spans) but the validity bit is 0.

        Args:
            maps: List of maps as (String, Int) tuple lists.
            valid_mask: Parallel list of booleans. True = valid, False = null.

        Returns:
            A new MapArray with a validity bitmap.
        """
        var num_maps = len(maps)

        # First pass: count total entries
        var total_entries = 0
        for i in range(num_maps):
            total_entries += len(maps[i])

        # Build offsets buffer
        # See from_string_int_maps above.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(
            (num_maps + 1) * int32_size
        )
        offsets_buf.set_typed[Int32](0, Int32(0))

        var offset = 0
        for i in range(num_maps):
            offset += len(maps[i])
            offsets_buf.set_typed[Int32](i + 1, Int32(offset))
        offsets_buf.set_length(Int64((num_maps + 1) * int32_size))


        # Build keys and values
        var key_strings = List[String]()
        var value_ints = List[Scalar[DType.int64]]()
        for i in range(num_maps):
            for j in range(len(maps[i])):
                key_strings.append(maps[i][j][0])
                value_ints.append(Scalar[DType.int64](maps[i][j][1]))

        var keys_arr = StringArray.from_strings(key_strings)
        var keys_col = Column.from_string(keys_arr)

        var values_arr = PrimitiveArray[DType.int64].from_list(value_ints)
        var values_col = Column.from_primitive[DType.int64](values_arr)

        # Build validity bitmap
        var null_count = 0
        var bm = Bitmap.create_all_valid(num_maps)
        for i in range(num_maps):
            if i < len(valid_mask) and not valid_mask[i]:
                bm.clear(i)
                null_count += 1

        return MapArray[HeapRegion](
            offsets=offsets_buf^,
            keys=keys_col^,
            values=values_col^,
            validity=bm^,
            length=num_maps,
            null_count=null_count,
            keys_sorted=False,
        )

    # --- Destructor ---
    # MmapAlignedBuffer, Column, and Bitmap handle their own cleanup.

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of maps in the array."""
        return self.length

    @always_inline
    def get_offset(self, index: Int) -> Int:
        """Return the start offset of map i in the keys/values arrays.

        This is the index into the keys and values Columns where map
        element `index` begins. No bounds checking for performance.

        Args:
            index: Zero-based map element index.

        Returns:
            The starting entry index for this map element.
        """
        # Migrated offset lookups onto `MmapAlignedBuffer.get_typed[Int32]`.
        return Int(self.offsets.get_typed[Int32](index))

    @always_inline
    def get_length(self, index: Int) -> Int:
        """Return the number of key-value entries in map i.

        Computed as offsets[i+1] - offsets[i]. No bounds checking for
        performance.

        Args:
            index: Zero-based map element index.

        Returns:
            Number of key-value entries in this map.
        """
        # See get_offset above.
        var start = Int(self.offsets.get_typed[Int32](index))
        var end = Int(self.offsets.get_typed[Int32](index + 1))
        return end - start

    def total_entries(self) -> Int:
        """Return the total number of key-value entries across all maps.

        This is the value of offsets[length] — the last offset entry.

        Returns:
            Total number of entries in the keys/values arrays.
        """
        if self.length == 0:
            return 0
        # See get_offset above.
        return Int(self.offsets.get_typed[Int32](self.length))

    # --- Null Handling ---

    @always_inline
    def is_null(self, index: Int) -> Bool:
        """Check if the map element at index is null.

        Returns False if no validity bitmap (all values are valid).

        Args:
            index: Zero-based element index.

        Returns:
            True if the element is null, False if valid.
        """
        if not self.validity:
            return False
        return not self.validity.value().test(index)

    # --- Column round-trip (MapArray <-> type-erased Column) ---
    #
    # A Map is logically `List<Struct<key,
    # value>>` per the Arrow spec.  We pack into a Column:
    #   _offsets     : the (N+1) Int32 map offsets
    #   _validity    : the map-level validity bitmap
    #   _children    : Slab[Column] holding ONE child Column — the entries
    #                  Struct<key, value> packed via StructArray.to_column.
    #   _field_names : the "entries" struct's field names
    #                  ([keys_name, values_name]) — Arrow spec default
    #                  is "key" and "value", but we preserve whatever was
    #                  on the source.  Currently hard-coded
    #                  ("key", "value") on round-trip from MapArray; the
    #                  C-Data import path can override these if the
    #                  schema specifies different names.
    #   _keys_sorted : the ARROW_FLAG_MAP_KEYS_SORTED bit.
    #   arrow_type   : ArrowType.MAP.

    def to_column(self) raises -> Column[HeapRegion]:
        """Pack this MapArray into a type-erased Column[HeapRegion] with
        `arrow_type == ArrowType.MAP`.  Reversible via `from_column`.
        """
        # Copy offsets.
        comptime int32_size = size_of[Int32]()
        var off_bytes = (self.length + 1) * int32_size
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        if off_bytes > 0:
            off_buf.copy_from_view(self.offsets.view_range_ro(0, off_bytes))
        off_buf.set_length(Int64(off_bytes))


        # Build the entries StructArray (keys + values) and pack into a
        # STRUCT Column. The entries are non-nullable per Arrow spec.
        var entries_names = List[String]()
        entries_names.append(String("key"))
        entries_names.append(String("value"))
        var keys_copy = self.keys.deep_copy()
        var values_copy = self.values.deep_copy()
        var entries = StructArray.from_columns_2(
            entries_names, keys_copy^, values_copy^
        )
        var entries_col = entries.to_column()

        # validity (map-level)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self.validity:
            var bm_len = self.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        # zero-length data buffer (MAP has no buffer of its own besides
        # offsets + validity).
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)


        var col = Column[HeapRegion](
            arrow_type=ArrowType.MAP,
            data=data_buf^,
            offsets=off_buf^,
            validity=validity^,
            length=self.length,
            null_count=self.null_count,
            offset=0,
        )
        var kids = Slab[Column[HeapRegion]].create(1)
        kids.append(entries_col^)
        col._children = kids^
        col._field_names.append(String("entries"))
        col._keys_sorted = self.keys_sorted
        return col^

    @staticmethod
    def from_column(col: Column[HeapRegion]) raises -> MapArray[HeapRegion]:
        """Unpack a `Column[HeapRegion]` (built by `to_column`) back into a MapArray.

        The Column carries the offsets + validity, plus ONE child Column
        (the entries Struct<key, value>).
        """
        if col.arrow_type != ArrowType.MAP:
            raise Error(
                "MapArray.from_column: arrow_type is "
                + String(col.arrow_type)
                + ", expected map"
            )
        if not col._offsets:
            raise Error("MapArray.from_column: missing offsets buffer")
        if len(col._children) != 1:
            raise Error(
                "MapArray.from_column: MAP column must have exactly 1 child"
                " (the entries struct), got " + String(len(col._children))
            )
        # The single child is the entries StructArray (packed).
        var entries = StructArray.from_column(col._children[0])
        if entries.num_fields() != 2:
            raise Error(
                "MapArray.from_column: entries struct must have exactly 2"
                " fields (key, value), got " + String(entries.num_fields())
            )
        # Move out key + value children. Slab[Column].take_at? Use
        # deep_copy via child_at to avoid Slab partial-move concerns.
        var keys_copy = entries.child_at(0).deep_copy()
        var values_copy = entries.child_at(1).deep_copy()

        # Copy offsets.
        comptime int32_size = size_of[Int32]()
        var n = col._length
        var off_bytes = (n + 1) * int32_size
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        if off_bytes > 0:
            off_buf.copy_from_view(
                col._offsets.value().view_range_ro(0, off_bytes)
            )
        off_buf.set_length(Int64(off_bytes))


        # validity
        var validity = Optional[Bitmap[HeapRegion]](None)
        if col._validity:
            var bm_len = col._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    col._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return MapArray[HeapRegion](
            offsets=off_buf^,
            keys=keys_copy^,
            values=values_copy^,
            validity=validity^,
            length=n,
            null_count=col._null_count,
            keys_sorted=col._keys_sorted,
        )
