# =============================================================================
# Column -- type-erased Arrow column container
# =============================================================================
#
# A Column holds any Arrow array type behind a uniform interface. Instead of
# using Variant (which requires listing every DType instantiation) or a trait
# vtable (complex in Mojo), we store raw buffers + ArrowType tag. The caller
# uses the ArrowType (typically from a Schema) to cast to the correct typed
# array at access time.
#
# Storage layout per ArrowType category:
#   Fixed-width (INT8..FLOAT64): data buffer only, optional validity bitmap
#   Boolean:                     data buffer (Bitmap), optional validity bitmap
#   String/Binary:               data buffer + offsets buffer, optional validity
#   Dictionary:                  indices column + dict column (nested Columns)
#
# This is deliberately simple: no ArcPointer, no vtable, no heap indirection.
# The Column owns its data and is Movable (not Copyable).
# =============================================================================

from std.memory import alloc, unsafe_memcpy
from std.sys import size_of

from komira_core.collections.byte_view import ByteView
from komira_core.collections.slab import Slab
from komira_core.arrow.dict_code_bounds import validate_dict_codes

from .owned_aligned_buffer import OwnedAlignedBuffer
from .shared_aligned_buffer import (
    SharedAlignedBuffer,
    bridge_oab_to_sab,
)
from .arrow_types import ArrowType, widen_offset_type
from .offset_overflow import ARROW_INT32_OFFSET_MAX, should_promote_offsets
from ..io.heap_region import HeapRegion
from ..io.memory_region import MemoryRegion
from ..helpers.planner_scale_counter import (
    planner_scale_note_content_hash_bytes,
)
from .bitmap import Bitmap
from .boolean_array import BooleanArray
from .binary_array import BinaryArray
from .large_binary_array import LargeBinaryArray
from .large_string_array import LargeStringArray
from .primitive_array import PrimitiveArray
from .string_array import StringArray
from .dictionary_array import StringDictionaryArray
from .decimal_array import Decimal128Array, DECIMAL128_BYTE_WIDTH
from .decimal256_array import Decimal256Array, DECIMAL256_BYTE_WIDTH
from .interval_mdn_array import (
    IntervalMonthDayNanoArray,
    INTERVAL_MDN_BYTE_WIDTH,
)
from .list_array import ListArray
from .struct_array import StructArray
from .map_array import MapArray
from .union_array import UnionArray
from komira_core.dtype_sentinel import DTYPE_NONE


# =============================================================================
# COLUMN VIEW ELIMINATION — `as_primitive` shares instead of copying
# =============================================================================
#
# A naive `Column.as_primitive` MEMCPYs the column's value window into a
# freshly-malloc'd `OwnedAlignedBuffer` on every call. On a scan-heavy query
# that copy is the single largest symbol, and it runs at an IPC around 0.16: the
# loop is MEMORY-STALLED, not issue-bound. You cannot make a stalled copy
# faster by issuing fewer instructions — you have to not do it.
#
# The value copy is **not needed**. `PrimitiveArray.data` and `Column._data`
# are the SAME type (`SharedAlignedBuffer[K]`, Arc-refcounted), and every
# `PrimitiveArray` VALUE accessor honors an element `offset`
# (`get`/`set`/`view_ro`/`view_mut`/`slice`/`_unsafe_data_ptr` all index
# `self.offset + i`). So for a NON-NULLABLE column the whole body reduces to an
# Arc refcount bump that carries `_offset` through. The share arm is
# unconditional; there is no switch that selects the copy for a
# non-nullable column.
#
# ★ NON-NULLABLE ONLY — the gate is load-bearing, not conservatism theatre.
# The copy does DOUBLE DUTY: it also REBASES the window to `offset == 0` for
# BOTH values and validity, and consumers may depend on the rebased-validity
# half of that invariant: they read a bare `arr.validity` and index it from
# bit 0, ignoring `arr.offset`. The shared validity mergers
# (`comparison_kleene.merge_cmp_validity`,
# `compiler_helpers.clone_array_validity`,
# `compiler_helpers.merge_binary_arith_validity`) honour the operands'
# offsets. A few per-row walks elsewhere (a binary-fn operator's
# `validity.value().test(i)` walk, a parquet decode helper's
# `view_range_ro(0, bm_bytes)`) still read validity from bit 0; they are
# LATENT, because both `can_share_as_primitive` (which returns False on
# `self._validity` before any other test) and the share branch REFUSE a
# column carrying a validity bitmap.
#     ⚠ LATENT IS NOT FIXED. Each one becomes a WRONG-ANSWER site the moment
#     the nullability half of the gate is widened — wrong null mask, wrong
#     null_count, no crash. Do NOT widen `as_primitive`'s
#     `not self._validity` guard, `can_share_as_primitive`, or the morsel
#     splitter's `not src_col._validity` gate until those readers honour
#     `.offset`. Citing their latency as a reason to relax the gate is
#     circular: the gate is what makes them latent.
#
# `Column.slice` hit the exact same seam and resolved it the exact same way —
# see its docstring, "NOT safe for the raw `validity.test(i)` readers ...
# `split_record_batch` therefore uses the zero-copy slice ONLY for
# NON-nullable columns and diverts nullable columns to the copy slice".
# `as_primitive` follows that precedent. The nullable arm keeps the copy
# verbatim, so its bytes are unchanged.
#
# SOUNDNESS of the sharing itself is the same argument `Column.share` already
# relies on (and states in its docstring): Arrow buffers are immutable on every
# consumer path, and the zero-copy mmap decode ALREADY aliases these bytes
# PROT_READ across the Column -> RecordBatch chain. The residual hazard is
# narrower: a caller that MUTATES an `as_primitive` result in place
# (`PrimitiveArray.set` / `set_valid` / `set_null` / `_unsafe_data_ptr`) would,
# under sharing, write THROUGH to the source column. No consumer does; the
# `mut PrimitiveArray` parameters in the function operators are the
# freshly-allocated `out` / `out_mask`. STATED RESIDUAL: a call-site audit
# cannot see a mutation through a re-binding alias (`var b = a; b.set(...)`).
#
# ★ THE MIRROR HAZARD. The other half is "does anyone mutate the SOURCE while
# a share is alive" — under a copy that is invisible, under a share the holder
# sees it change underneath. `Column` exposes NO `mut self` method that writes
# `_data`, and every `<x>._data.<accessor>` call site outside this file is a
# READ (`view_ro` / `view_range_ro` / `get_typed` / `read_u*` / `load_simd` /
# `len` / `_typed_ptr_ro`). So a Column's value bytes are written at
# CONSTRUCTION and never after — which is the immutability premise the whole
# soundness argument above rests on. ⇒ If you ever add a mutating `Column`
# method, this sharing is one of the things it invalidates.
#
# Guarded by the column-view-elimination oracle test (VALUES) and the
# sliced-column `as_primitive` byte-equivalence test (EXTENT — buffer size,
# `offset == 0`, and the downstream copies sized off them). Both assert against
# an independently computed SPEC rather than against whichever branch runs.
# The oracle's write-through test is the MECHANISM guard: it is the only test
# that can distinguish a share from a memcpy at all — it WRITES through one
# handle and READS another — because a correct copy and a correct share agree
# on every observable a spec oracle checks.
# =============================================================================


# =============================================================================
# Content-hash helpers (Column.content_hash)
# =============================================================================


@always_inline
def _dict_value_dtype_tag(dt: DType) -> UInt64:
    """Map a numeric-dictionary value `DType` to a small stable tag for the
    content hash. `DType` is a stdlib type with no guaranteed-stable int
    serialization across compiler versions, so we map the handful of dtypes a
    numeric dictionary column can carry (plus `invalid` for string-dict /
    non-dict columns) to explicit constants."""
    if dt == DType.int32:
        return UInt64(1)
    if dt == DType.int64:
        return UInt64(2)
    if dt == DType.float32:
        return UInt64(3)
    if dt == DType.float64:
        return UInt64(4)
    return UInt64(0)  # DTYPE_NONE (string-dict / non-dict)


def _fold_buffer_bytes[
    K: MemoryRegion
](seed: UInt64, imm buf: SharedAlignedBuffer[K]) -> UInt64:
    """Fold every byte of `buf` into a running FNV-1a hash, returning the
    updated accumulator. 8 bytes at a time over the aligned body, then a
    byte-at-a-time tail. Byte access is via the tracked `ByteView`
    (`as_view()`) — no raw pointer crosses the function boundary.

    COUNTER. `n` is added to the process-wide
    `planner_scale_content_hash_bytes` accumulator BEFORE the fold. This is the
    ONE place a content hash reads bytes, so counting here cannot drift from
    the cost it stands for, and reading the counter's DELTA across a region
    attributes the fold to that region exactly. It is a side effect on a
    separate atomic and is incapable of changing `h` — the content-derived
    structural identity contract (guarded by
    `test_factory_cache_layer1_hit`) is untouched. Cost is one relaxed
    `fetch_add` in front of an O(n) loop over (typically) megabytes.
    """
    comptime prime = UInt64(0x00000100000001B3)
    var h = seed
    var n = buf.len()
    try:
        planner_scale_note_content_hash_bytes(n)
    except:
        pass
    h = (h ^ UInt64(n)) * prime  # length-prefix so empty vs non-empty differ
    var view = buf.as_view()
    var u64_end = (n >> 3) << 3
    var i = 0
    while i < u64_end:
        h = (h ^ view.read_u64_le_at(i)) * prime
        i += 8
    while i < n:
        h = (h ^ UInt64(view.read_u8_at(i))) * prime
        i += 1
    return h


struct Column[K: MemoryRegion = HeapRegion](Movable):
    """A type-erased Arrow column. Holds raw buffers + type metadata.

    The caller checks arrow_type (typically from the Schema) and uses the
    appropriate as_*() method to get a typed view of the data.

    Parameters:
        K: The MemoryRegion type backing the data / offsets / dict_data /
           validity buffers. Defaults to HeapRegion (owning). K=MmapRegion
           is the zero-copy IPC path (read-only mmap-borrowed data).
           The K parameter carries the buffer region type through the
           holder. Default K=HeapRegion means `Column` sites need no
           per-call annotation. Mirrors PrimitiveArray[dtype, K]
           and the StringArray[K] cascade. Nested `_children: Slab[Column[HeapRegion]]`
           remains at the default K (HeapRegion) — child Columns are the
           type-erased recursive payload and persist via Slab, which
           requires a concrete K binding; HeapRegion is the canonical
           persisted shape.

    Fields:
        arrow_type: The ArrowType tag identifying the concrete array type.
        _data: Primary data buffer (values for primitives, packed bits for
            boolean, UTF-8/raw bytes for string/binary).
        _offsets: Optional offsets buffer for variable-length types
            (string, binary). None for fixed-width and boolean.
        _validity: Optional validity bitmap. None means no nulls.
        _length: Number of logical elements.
        _null_count: Number of null elements.
        _offset: Element offset for zero-copy slicing.
        _dict_indices: Optional Column pointer for dictionary indices.
            Only used when arrow_type == DICTIONARY. Heap-allocated because
            Column contains Column (recursive type).
        _dict_values: Optional Column pointer for dictionary values.
            Only used when arrow_type == DICTIONARY.
    """

    var arrow_type: ArrowType
    # Holder fields flipped
    # `MmapAlignedBuffer[64, Self.K]` -> `SharedAlignedBuffer[Self.K]` (incl.
    # the Optional-wrapped offsets / dict_data).
    var _data: SharedAlignedBuffer[Self.K]
    var _offsets: Optional[SharedAlignedBuffer[Self.K]]
    var _validity: Optional[Bitmap[Self.K]]
    var _length: Int
    var _null_count: Int
    var _offset: Int
    var _dict_data: Optional[SharedAlignedBuffer[Self.K]]
    var _dict_size: Int
    # byte width of the
    # indices buffer (`_data`) for DICTIONARY columns. Defaults to 4
    # (Int32) for backward compat with `from_dictionary(StringDictionaryArray)`;
    # `from_int64_dict_indices` sets this to 8 (Int64). The Arrow IPC
    # encoder reads this to emit n*_dict_index_byte_width bytes per
    # column; the Schema-side Field._dict_index_type drives the FB
    # DictionaryEncoding.indexType bit_width independently (Schema-side
    # is the source of truth for the wire metadata; this Column-side
    # field is the source of truth for the indices buffer byte layout
    # they MUST agree at encode time).
    var _dict_index_byte_width: Int
    # Value-type tag for NUMERIC
    # dictionary columns. The string DICTIONARY shape (`from_dictionary` /
    # `from_int64_dict_indices`) carries its values as `_offsets` (Int32
    # offsets) + `_dict_data` (packed UTF-8 bytes); for those this stays
    # `DTYPE_NONE`. A NUMERIC dictionary column (`from_numeric_dict`)
    # carries `_offsets=None` and packs a FLAT numeric value buffer of
    # `_dict_size` entries into `_dict_data`, with this field set to the
    # value DType (int32 / int64 / float32 / float64). Consumers discriminate
    # string-dict vs numeric-dict via `is_numeric_dict()` (this field !=
    # invalid), NOT by inspecting `_offsets`. Plain DType field — Column is a
    # value type (moved/copied, never a pool member), so no stale-pointer
    # hazard.
    var _dict_value_dtype: DType
    # decimal precision/scale, mirrored
    # from the Schema.Field (Arrow carries (p,s) in DataType AND redundantly
    # in the array — we do the same).  Zero for non-decimal columns.  Plain
    # Int fields — Column is a value type that gets moved/copied, not a
    # pool member, so no stale-pointer hazard.
    var _decimal_p: Int
    var _decimal_s: Int
    # Nested-type children.  For LIST, this
    # holds exactly one child Column (the item type).  For STRUCT, this
    # holds N child Columns (one per field).  For MAP, this holds exactly
    # one child Column (a STRUCT<key, value> "entries" column).  Empty for
    # non-nested arrow types.  Slab is the right collection (Column is
    # Movable but not Copyable, ruling out List[Column]).  `_field_names`
    # carries STRUCT child names (parallel to `_children`); empty for
    # LIST/MAP/non-nested.  `_keys_sorted` mirrors Arrow's
    # `ARROW_FLAG_MAP_KEYS_SORTED` for MAP (False otherwise).
    var _children: Slab[Column[HeapRegion]]
    var _field_names: List[String]
    var _keys_sorted: Bool
    # Per-child declared type-id list for
    # UNION_SPARSE / UNION_DENSE columns.  Parallel to `_children` — length
    # equals `len(_children)`.  Empty for non-union columns.  Mirrors the
    # `+us:I,J,...` / `+ud:I,J,...` format-string suffix and Field's
    # `_union_type_ids` slot.
    var _type_ids: List[Int]
    #
    # inner size for FIXED_SIZE_BINARY (byte_width per row) +
    # FIXED_SIZE_LIST (element count per row). 0 for non-fixed-size
    # types. Plain Int — Column is a value type, no stale-pointer hazard.
    var _inner_size: Int

    # --- Move ---

    # --- Constructors ---

    # --- Cross-module OAB setters ---
    # The OAB-accepting variants used by callers that build with
    # OwnedAlignedBuffer. Each promotes via `bridge_oab_to_sab[Self.K]`. Constrained to
    # K=HeapRegion because OAB is heap-only by construction.

    def _set_dict_data_from_oab(
        mut self,
        var dict_data_buf: OwnedAlignedBuffer,
    ):
        """Bridge OAB -> Optional[SAB] field assignment for `_dict_data`."""
        comptime assert (Self.K == HeapRegion), ( "Column._set_dict_data_from_oab: OAB is heap-only;" " borrowed-K Columns must use the SAB setters." )
        self._dict_data = Optional(bridge_oab_to_sab[Self.K](dict_data_buf^))

    def _set_dict_data_from_opt_oab(
        mut self,
        var dict_data: Optional[OwnedAlignedBuffer],
    ):
        """Bridge Optional[OAB] -> Optional[SAB] field assignment."""
        comptime assert (Self.K == HeapRegion), ( "Column._set_dict_data_from_opt_oab: OAB is heap-only;" " borrowed-K Columns must use the SAB setters." )
        if dict_data:
            var oab = dict_data.take()
            self._dict_data = Optional(bridge_oab_to_sab[Self.K](oab^))
        else:
            self._dict_data = None

    def _set_offsets_from_oab(
        mut self,
        var offsets_buf: OwnedAlignedBuffer,
    ):
        """Bridge OAB -> Optional[SAB] field assignment for `_offsets`."""
        comptime assert (Self.K == HeapRegion), ( "Column._set_offsets_from_oab: OAB is heap-only;" " borrowed-K Columns must use the SAB setters." )
        self._offsets = Optional(bridge_oab_to_sab[Self.K](offsets_buf^))

    def _set_offsets_from_opt_oab(
        mut self,
        var offsets: Optional[OwnedAlignedBuffer],
    ):
        """Bridge Optional[OAB] -> Optional[SAB] field assignment."""
        comptime assert (Self.K == HeapRegion), ( "Column._set_offsets_from_opt_oab: OAB is heap-only;" " borrowed-K Columns must use the SAB setters." )
        if offsets:
            var oab = offsets.take()
            self._offsets = Optional(bridge_oab_to_sab[Self.K](oab^))
        else:
            self._offsets = None

    def _set_data_from_oab(
        mut self,
        var data_buf: OwnedAlignedBuffer,
    ):
        """Bridge OAB -> SAB field assignment for `_data`."""
        comptime assert (Self.K == HeapRegion), ( "Column._set_data_from_oab: OAB is heap-only;" " borrowed-K Columns must use the SAB setters." )
        self._data = bridge_oab_to_sab[Self.K](data_buf^)

    def __init__(out self):
        """Create an empty Column with NULL type.

        Constrained to K=HeapRegion
        because `MmapAlignedBuffer[64](0)` produces a HeapRegion-backed
        empty buffer; the no-arg ctor is the canonical "placeholder
        / NULL" shape and is used only on the owning (HeapRegion) side.
        Borrowed-K Columns (K=MmapRegion) must use the typed
        `from_borrowed_*` factories.

        Delegates to the typed `__init__` with K-correct empty buffers
        constructed via `MmapAlignedBuffer[64, Self.K](0)` (size-ctor honors
        Self.K via Self.K=HeapRegion + MmapAlignedBuffer's own constrained
        ctor).
        """
        comptime assert (Self.K == HeapRegion), ( "Column.__init__(): no-arg empty ctor requires K=HeapRegion" " (OwnedAlignedBuffer(0) is HeapRegion-backed); borrowed-K" " Columns must use the typed from_borrowed_* factories." )
        # Migrated from `MmapAlignedBuffer[64, Self.K](0)` to
        # `OwnedAlignedBuffer(0)`. Column's OAB-accepting ctor (line ~357)
        # promotes to SAB[HeapRegion] internally.
        self = Self(
            arrow_type=ArrowType.NULL,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=None,
            length=0,
            null_count=0,
            offset=0,
        )

    def __init__(
        out self,
        arrow_type: ArrowType,
        var data: SharedAlignedBuffer[Self.K],
        var offsets: Optional[SharedAlignedBuffer[Self.K]],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        null_count: Int,
        offset: Int,
    ):
        """Construct a Column directly from SharedAlignedBuffer components.

        SAB-accepting overload (the eventual canonical
        ctor). Callers that already hold SAB-typed buffers — e.g. moved-out
        via `Optional[SAB].take()` from another Column, or migrated owners
        post-Skip the MmapAlignedBuffer bridge.
        """
        self.arrow_type = arrow_type
        self._data = data^
        self._offsets = offsets^
        self._validity = validity^
        self._length = length
        self._null_count = null_count
        self._offset = offset
        self._dict_data = None
        self._dict_size = 0
        self._dict_index_byte_width = 4
        self._dict_value_dtype = DTYPE_NONE
        self._decimal_p = 0
        self._decimal_s = 0
        self._children = Slab[Column[HeapRegion]]()
        self._field_names = List[String]()
        self._keys_sorted = False
        self._type_ids = List[Int]()
        self._inner_size = 0

    def __init__(
        out self,
        arrow_type: ArrowType,
        var data: OwnedAlignedBuffer,
        var offsets: Optional[OwnedAlignedBuffer],
        var validity: Optional[Bitmap[Self.K]],
        length: Int,
        null_count: Int,
        offset: Int,
    ):
        """Construct a Column directly from OwnedAlignedBuffer components.

        OAB-accepting overload — mirror of the
        SAB overload above. Each OAB is promoted to
        `SharedAlignedBuffer[HeapRegion]` via `from_owned`, then field-assigned
        through `bridge_ab_to_sab`-equivalent rebind. Constrained to
        `Self.K == HeapRegion` because OAB is heap-only by construction
        (mmap-backed paths must route through
        `SharedAlignedBuffer.borrow_from_mmap`); borrowed-K Columns continue
        to use the typed `from_borrowed_*` factories or the SAB-accepting
        overload above.
        """
        comptime assert (Self.K == HeapRegion), ( "Column.__init__(OwnedAlignedBuffer...): OAB ctor requires" " K=HeapRegion (OAB is heap-only); borrowed-K Columns must" " use the SAB-accepting overload or the typed" " from_borrowed_* factories." )
        self.arrow_type = arrow_type
        # SAB itself is not ImplicitlyCopyable so `rebind[SAB[Self.K]](
        # SAB.from_owned(...))` is rejected by the typechecker. Bridge via
        # `bridge_oab_to_sab[Self.K]` (mirror of `bridge_ab_to_sab[Self.K]`),
        # which rebinds the inner ArcPointer[HeapRegion] -> ArcPointer[Self.K]
        # (ArcPointer IS ImplicitlyCopyable via its Arc refcount) and
        # reconstructs the SAB field-wise. The K=HeapRegion constraint above
        # makes the rebind type-equivalent.
        self._data = bridge_oab_to_sab[Self.K](data^)
        if offsets:
            var off_oab = offsets.take()
            self._offsets = Optional(bridge_oab_to_sab[Self.K](off_oab^))
        else:
            self._offsets = None
        self._validity = validity^
        self._length = length
        self._null_count = null_count
        self._offset = offset
        self._dict_data = None
        self._dict_size = 0
        self._dict_index_byte_width = 4
        self._dict_value_dtype = DTYPE_NONE
        self._decimal_p = 0
        self._decimal_s = 0
        self._children = Slab[Column[HeapRegion]]()
        self._field_names = List[String]()
        self._keys_sorted = False
        self._type_ids = List[Int]()
        self._inner_size = 0

    def deep_copy(self) raises -> Column[HeapRegion]:
        """Deep-copy this Column.  Used by
        the LIST/STRUCT/MAP wire-in to clone child Columns when packing
        them into the type-erased `_children` slot, and at unpacking time
        when reconstructing the typed array.

        Copies every buffer (data, offsets, dict_data, validity).
        Recursively deep-copies all child Columns in `_children`.
        Preserves all metadata (decimal p/s, field names, keys_sorted).
        """
        var col = Column[HeapRegion]()
        col.arrow_type = self.arrow_type
        # Copy primary data buffer.
        var data_bytes = self._data.len()
        var data_buf = OwnedAlignedBuffer(max(data_bytes, 1))
        if data_bytes > 0:
            data_buf.copy_from_view(self._data.view_range_ro(0, data_bytes))
        data_buf.set_length(Int64(data_bytes))

        # Bridge OAB -> SAB[HeapRegion] at field assignment.
        col._data = bridge_oab_to_sab[HeapRegion](data_buf^)
        # Copy offsets if present.
        if self._offsets:
            var off_bytes = self._offsets.value().len()
            var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
            if off_bytes > 0:
                off_buf.copy_from_view(
                    self._offsets.value().view_range_ro(0, off_bytes)
                )
            off_buf.set_length(Int64(off_bytes))

            col._offsets = Optional(bridge_oab_to_sab[HeapRegion](off_buf^))
        # Copy validity if present.
        if self._validity:
            var bm_len = self._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            col._validity = bm^
        col._length = self._length
        col._null_count = self._null_count
        col._offset = self._offset
        # Copy dict_data if present.
        if self._dict_data:
            var dd_bytes = self._dict_data.value().len()
            var dd_buf = OwnedAlignedBuffer(max(dd_bytes, 1))
            if dd_bytes > 0:
                dd_buf.copy_from_view(
                    self._dict_data.value().view_range_ro(0, dd_bytes)
                )
            dd_buf.set_length(Int64(dd_bytes))

            col._dict_data = Optional(bridge_oab_to_sab[HeapRegion](dd_buf^))
        col._dict_size = self._dict_size
        col._dict_index_byte_width = self._dict_index_byte_width
        col._dict_value_dtype = self._dict_value_dtype
        col._decimal_p = self._decimal_p
        col._decimal_s = self._decimal_s
        # Recursively deep-copy children (LIST/STRUCT/MAP).
        if len(self._children) > 0:
            var kids = Slab[Column[HeapRegion]].create(len(self._children))
            for i in range(len(self._children)):
                kids.append(self._children[i].deep_copy())
            col._children = kids^
        # Copy STRUCT field names.
        for i in range(len(self._field_names)):
            col._field_names.append(self._field_names[i])
        col._keys_sorted = self._keys_sorted
        # Copy UNION declared type-ids.
        for i in range(len(self._type_ids)):
            col._type_ids.append(self._type_ids[i])
        # 5 FIXED_SIZE_* inner size.
        col._inner_size = self._inner_size
        return col^

    def share(self) raises -> Self:
        """Arc-SHARE this Column: build a new Column whose every buffer field
        ALIASES this column's bytes via an Arc refcount bump — NO byte copy.
        The zero-copy dual of `deep_copy` (which memcpy's every buffer).

        Field-for-field mirror of `deep_copy` — KEEP THE TWO IN SYNC:
          * `_data` / `_offsets` / `_dict_data`  -> `SharedAlignedBuffer.share`
          * `_validity`                          -> `Bitmap.share`
          * `_children` (LIST/STRUCT/MAP/UNION)  -> recursive `Column.share`
          * every metadata scalar + `_field_names` / `_type_ids` list -> copied
        `_offset` is preserved (as `deep_copy` does); column accessors apply it,
        so `share()` reads every logical cell IDENTICALLY to `deep_copy()` /
        `copy_column()` — the byte-equivalence oracle asserts this.

        SOUNDNESS: Arrow buffers are immutable on every consumer path (join
        build/probe, agg, filter, project, and `split_record_batch` all READ
        and emit NEW batches; the zero-copy mmap decode already aliases these
        buffers under PROT_READ). Sharing therefore never exposes a
        write-through-alias hazard. The mmap keepalive cookie is cloned inside
        `SharedAlignedBuffer.share`, so an mmap-backed source stays munmap-
        pinned for the shared column's lifetime.

        Returns `Column[Self.K]`; RecordBatch columns are always
        `Column[HeapRegion]` (the mmap zero-copy case rides as a HeapRegion-
        typed SAB + keepalive cookie, not `K=MmapRegion`), so `share()` on a
        `RecordBatch` column yields `Column[HeapRegion]`.
        """
        # Optional buffer fields share() into the correct K before the ctor.
        var offsets_shared = Optional[SharedAlignedBuffer[Self.K]](None)
        if self._offsets:
            offsets_shared = Optional[SharedAlignedBuffer[Self.K]](
                self._offsets.value().share()
            )
        var validity_shared = Optional[Bitmap[Self.K]](None)
        if self._validity:
            validity_shared = Optional[Bitmap[Self.K]](
                self._validity.value().share()
            )
        # The SAB-accepting ctor zero-defaults dict / children / decimal /
        # names / type-ids / inner-size; every one is restored below (mirror
        # of `deep_copy`'s field list).
        var col = Self(
            arrow_type=self.arrow_type,
            data=self._data.share(),
            offsets=offsets_shared^,
            validity=validity_shared^,
            length=self._length,
            null_count=self._null_count,
            offset=self._offset,
        )
        # Dictionary payload (string + numeric dict).
        if self._dict_data:
            col._dict_data = Optional(self._dict_data.value().share())
        col._dict_size = self._dict_size
        col._dict_index_byte_width = self._dict_index_byte_width
        col._dict_value_dtype = self._dict_value_dtype
        # Decimal (p, s).
        col._decimal_p = self._decimal_p
        col._decimal_s = self._decimal_s
        # Nested children (LIST/STRUCT/MAP/UNION) — recursive share.
        if len(self._children) > 0:
            var kids = Slab[Column[HeapRegion]].create(len(self._children))
            for i in range(len(self._children)):
                kids.append(self._children[i].share())
            col._children = kids^
        # STRUCT field names / UNION type-ids / keys_sorted / inner size.
        for i in range(len(self._field_names)):
            col._field_names.append(self._field_names[i])
        col._keys_sorted = self._keys_sorted
        for i in range(len(self._type_ids)):
            col._type_ids.append(self._type_ids[i])
        col._inner_size = self._inner_size
        return col^

    def supports_zero_copy_slice(self) -> Bool:
        """VECTOR-NATIVE INC-3 (design §B.1): True iff `slice()` can produce a
        zero-copy row window via `_offset` — i.e. every accessor for this layout
        honors `_offset`. This is a conservative WHITELIST of the fixed-width
        numeric / temporal / DECIMAL128 / DICTIONARY layouts whose accessors add
        `_offset` (verified byte-identical by the split-on-slice oracle). Every
        other layout returns False and the caller (`split_record_batch`) uses the
        copy slice — notably plain STRING / BINARY (as_string/as_binary read
        offsets from position 0, IGNORING `_offset` — see `_slice_variable_width`
        note), BOOL (bit-packed; a non-byte-aligned `_offset` needs bit-shift
        handling), and nested (LIST/STRUCT/MAP/UNION child offsets don't compose
        with a parent `_offset`)."""
        var t = self.arrow_type
        return (
            t == ArrowType.INT8 or t == ArrowType.UINT8
            or t == ArrowType.INT16 or t == ArrowType.UINT16
            or t == ArrowType.INT32 or t == ArrowType.UINT32
            or t == ArrowType.INT64 or t == ArrowType.UINT64
            or t == ArrowType.FLOAT16 or t == ArrowType.FLOAT32
            or t == ArrowType.FLOAT64
            or t == ArrowType.DATE32 or t == ArrowType.DATE64
            or t == ArrowType.TIMESTAMP or t == ArrowType.TIMESTAMP_S
            or t == ArrowType.TIMESTAMP_MS or t == ArrowType.TIMESTAMP_US
            or t == ArrowType.TIMESTAMP_NS
            or t == ArrowType.DECIMAL128
            or t == ArrowType.DICTIONARY
        )

    def slice(self, start: Int, length: Int) raises -> Self:
        """VECTOR-NATIVE INC-3 (design §B.1): zero-copy ROW slice — Arc-share
        every buffer (refcount++, NO memcpy) and return a Column viewing
        `[start, start+length)` of self's logical rows via `_offset`. The RG->
        chunk reslice enabler that replaces the per-column memcpy in
        `split_record_batch` with an Arc refcount bump.

        Byte-identical reads to the copy-based `_slice_column` for every layout
        where `supports_zero_copy_slice()` is True (fixed-width / boolean /
        DECIMAL / DICTIONARY — their accessors honor `_offset`). RAISES for
        STRING/BINARY/nested (accessors ignore `_offset`); the caller must gate
        on `supports_zero_copy_slice()` and use the copy path for those.

        VALIDITY IS OFFSET-BASED. When self is nullable the
        result SHARES the WHOLE-column validity bitmap and carries `_offset > 0`,
        so a per-row validity lookup on the result is `validity.test(_offset + i)`,
        NOT `validity.test(i)`. This is correct — and required — for the
        offset-honoring consumers (`as_primitive`, which rebases the window to
        offset 0; the batch_slice / sort / join validity walks). It is NOT safe
        for the raw `validity.test(i)` readers that assume the copy-path invariant
        (post-split morsel columns are `_offset == 0` with validity rebased to bit
        0). `split_record_batch` therefore uses the zero-copy slice ONLY for
        NON-nullable columns and diverts nullable columns to the copy slice (which
        rebases validity to a fresh 0-based window bitmap). Direct callers that
        read the result via an offset-honoring accessor may slice nullable columns.

        `_null_count` is recomputed for the window (share() copied the whole-
        column count); for a non-nullable column (`_validity is None`) this is 0
        with no scan. The dict payload (`_dict_data`/`_offsets` for DICTIONARY)
        is shared WHOLE — codes are addressed by `_offset`, the per-RG dict page
        is not sliced (design §B.1)."""
        debug_assert(
            start >= 0 and length >= 0 and start + length <= self._length,
            "Column.slice: [start, start+length) out of range",
        )
        if not self.supports_zero_copy_slice():
            raise Error(
                "Column.slice: layout does not honor _offset (STRING/BINARY/"
                "nested); gate on supports_zero_copy_slice() and use the copy"
                " slice for this column"
            )
        var col = self.share()
        col._offset = self._offset + start
        col._length = length
        # Recompute the window null_count (share() copied the whole-column value).
        if col._validity:
            ref vb = col._validity.value()
            var nulls = 0
            for i in range(length):
                if not vb.test(col._offset + i):
                    nulls += 1
            col._null_count = nulls
        else:
            col._null_count = 0
        return col^

    # --- Factory: from typed arrays ---

    @staticmethod
    def from_primitive[dtype: DType](arr: PrimitiveArray[dtype]) -> Column[HeapRegion]:
        """Create a Column from a PrimitiveArray (copies data).

        Parameters:
            dtype: The DType of the PrimitiveArray.

        Args:
            arr: The PrimitiveArray to wrap.

        Returns:
            A new Column owning copies of the array's buffers.
        """
        # Migrated buffer memcpys onto `copy_from_view` (memcpy-backed).
        comptime elem_size = size_of[Scalar[dtype]]()
        var total_elems = arr.offset + arr.length
        var data_bytes = total_elems * elem_size
        var data_buf = OwnedAlignedBuffer(max(data_bytes, 1))
        if data_bytes > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, data_bytes))
        data_buf.set_length(Int64(data_bytes))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.from_dtype(dtype),
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=arr.offset,
        )

    @staticmethod
    def from_primitive_shared[dtype: DType](
        var arr: PrimitiveArray[dtype]
    ) raises -> Column[HeapRegion]:
        """ZERO-COPY sibling of `from_primitive`: the SAME Column, with every
        buffer ARC-SHARED off `arr` instead of memcpy'd out of it.

        Field-for-field mirror of `from_primitive` — **KEEP THE TWO IN SYNC**;
        the ONLY difference is `copy_from_view` -> `.share()` (plus the
        `set_length` mirror below). Same `arrow_type`, same `length`, same
        `null_count`, same `offset`, same logical cells.

        ## THE ALIASING ARGUMENT (stated, not implicit)

        `arr` is taken **BY VALUE**, so this factory CONSUMES it. That is the
        whole safety argument, and it is structural rather than a convention a
        future caller can quietly break:

        * After the shares below, the returned Column and the moved-in `arr`
          are the only two handles on those bytes; `arr` is destroyed at the end
          of this function, leaving the Column as the SOLE owner (Arc refcount
          back to 1). A caller therefore CANNOT retain a second handle — the
          borrow checker took it away at the call.
        * The intended caller shape is the dict-resolve arm of
          `_decode_column_pages`: `resolve_int64` / `resolve_int32` /
          `resolve_float32` / `resolve_float64` each build their output buffer
          FRESH (`OwnedAlignedBuffer` -> `PrimitiveArray`, refcount 1) and
          return it as an owned local that the arm moves straight in here and
          never touches again.
        * Even if some future caller DID hold a share, Arrow buffers are
          immutable on every consumer path — the same invariant `Column.share`,
          `share_batch` and the zero-copy mmap decode already rest on. The
          by-value signature is belt AND braces.

        ⚠ Contrast with `from_primitive`, which is deliberately left BORROWING:
        callers that need to keep their `PrimitiveArray` must keep paying the
        memcpy. Do not "unify" the two by making this one borrow.

        The `set_length` calls are the length half of the mirror, not an
        optimisation: `from_primitive` sizes its fresh buffers to exactly
        `(offset + length) * elem_size` and `(bm_len + 7) >> 3`, so a source
        buffer that was over-allocated would otherwise leave the shared Column
        with a LONGER `_data` than the copied one and diverge under a later
        `deep_copy`. `SharedAlignedBuffer._length` is a per-HANDLE field (see
        `SharedAlignedBuffer.share`), so truncating the share does not touch
        the source buffer or the region.

        Parameters:
            dtype: The DType of the PrimitiveArray.

        Args:
            arr: The PrimitiveArray to CONSUME. Its buffers become the
                returned Column's buffers with no byte copy.

        Returns:
            A Column aliasing `arr`'s buffers (Arc refcount, no memcpy).

        Raises:
            Error if `arr`'s data buffer is shorter than the
            `(offset + length) * elem_size` bytes its own header claims — the
            case where `from_primitive`'s `view_range_ro` would have been
            out of range.
        """
        comptime elem_size = size_of[Scalar[dtype]]()
        var total_elems = arr.offset + arr.length
        var data_bytes = total_elems * elem_size

        var data_shared = arr.data.share()
        if data_bytes > Int(data_shared.len()):
            raise Error(
                "Column.from_primitive_shared: data buffer holds "
                + String(Int(data_shared.len()))
                + " bytes but the array header claims "
                + String(data_bytes)
                + " ((offset + length) * elem_size)"
            )
        data_shared.set_length(Int64(data_bytes))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = arr.validity.value().share()
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                if bm_bytes > Int(bm.buffer.len()):
                    raise Error(
                        "Column.from_primitive_shared: validity buffer is"
                        " shorter than the bitmap length claims"
                    )
                bm.buffer.set_length(bm_bytes)
            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.from_dtype(dtype),
            data=data_shared^,
            offsets=Optional[SharedAlignedBuffer[HeapRegion]](None),
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=arr.offset,
        )

    @staticmethod
    def from_primitive_with_arrow_type[dtype: DType](
        arr: PrimitiveArray[dtype], arrow_type: ArrowType
    ) -> Column[HeapRegion]:
        """Create a Column from a PrimitiveArray with an EXPLICIT ArrowType
        override (copies data).  Used by Phase E for the storage-DType-shaped
        but logically-distinct types: Time32_S/MS, Time64_US/NS,
        Duration_S/MS/US/NS, Interval_YEAR_MONTH (Int32 storage),
        Interval_DAY_TIME (Int64 storage).  The buffer layout matches the
        underlying DType; only the ArrowType discriminator differs.

        Parameters:
            dtype: The storage DType of the PrimitiveArray.

        Args:
            arr: The PrimitiveArray providing the bytes.
            arrow_type: The ArrowType tag to stamp on the resulting Column.
        """
        comptime elem_size = size_of[Scalar[dtype]]()
        var total_elems = arr.offset + arr.length
        var data_bytes = total_elems * elem_size
        var data_buf = OwnedAlignedBuffer(max(data_bytes, 1))
        if data_bytes > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, data_bytes))
        data_buf.set_length(Int64(data_bytes))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=arr.offset,
        )

    @staticmethod
    def from_string(arr: StringArray) -> Column[HeapRegion]:
        """Create a Column from a StringArray (copies data).

        Args:
            arr: The StringArray to wrap.

        Returns:
            A new Column owning copies of the array's buffers.
        """
        # Copy offsets
        # Migrated all buffer memcpys onto `copy_from_view`.
        comptime int32_size = size_of[Int32]()
        var offsets_bytes = (arr.length + 1) * int32_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(arr.offsets.view_range_ro(0, offsets_bytes))
        offsets_buf.set_length(Int64(offsets_bytes))


        # Copy data
        var data_buf = OwnedAlignedBuffer(max(arr.data_length, 1))
        if arr.data_length > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, arr.data_length))
        data_buf.set_length(Int64(arr.data_length))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.STRING,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    @staticmethod
    def from_string_shared(
        var arr: StringArray[HeapRegion],
    ) raises -> Column[HeapRegion]:
        """ZERO-COPY sibling of `from_string`: the SAME Column, with every
        buffer ARC-SHARED off `arr` instead of memcpy'd out of it.

        Field-for-field mirror of `from_string` — **KEEP THE TWO IN SYNC**; the
        ONLY differences are `copy_from_view` -> `.share()` and the bounds
        checks that replace `view_range_ro`'s range validation. Same
        `arrow_type`, same `length`, same `null_count`, same `offset`, same
        logical cells, same BYTE LENGTHS on all three buffers.

        The string-shaped counterpart of `from_primitive_shared`; read that
        docstring too — the argument is the same one, and the two must not
        drift apart.

        ## THE ALIASING ARGUMENT (stated, not implicit)

        `arr` is taken **BY VALUE**, so this factory CONSUMES it. That is the
        whole safety argument, and it is structural rather than a convention a
        future caller can quietly break:

        * After the shares below, the returned Column and the moved-in `arr`
          are the only two handles on those bytes; `arr` is destroyed at the
          end of this function, leaving the Column as the SOLE owner (Arc
          refcount back to 1). A caller CANNOT retain a second handle — the
          borrow checker took it away at the call.
        * The intended callers are the BYTE_ARRAY dictionary-fallback arm of
          `_decode_column_pages`, whose two producers each build BOTH output
          buffers FRESH and return them as an owned local:
            - `_concat_string_arrays` allocates `offsets_buf` / `data_buf` as
              `OwnedAlignedBuffer` (refcount 1), fills them, `set_length`s both
              to exactly the byte counts `from_string` would have produced, and
              moves them into the returned `StringArray`. It aliases NOTHING
              from its input pages — it memcpy's out of them and drains the
              slab. ⚠ When the parquet decoder moves a SINGLE-page chunk out
              whole, it returns that one page instead of
              rebuilding it — which does not weaken the argument above, because
              the page is MOVED out of the slab and the slab is drained in the
              same breath, so what arrives here is still uniquely owned. The
              handover contract is unchanged; only the provenance of the bytes
              is.
            - `_expand_with_nulls_string` returns
              `StringArray.from_strings_with_validity(...)`, built from freshly
              materialised `List[String]` / `List[Bool]`. It borrows `values`
              only to READ, and shares no buffer with it.
          Both therefore hand over uniquely-owned bytes, which is why the
          `share` is a refcount bump on a refcount of 1 rather than a widening
          of an existing alias.
        * Even if some future caller DID hold a share, Arrow buffers are
          immutable on every consumer path — the same invariant `Column.share`,
          `share_batch`, `from_primitive_shared` and the zero-copy mmap decode
          already rest on. The by-value signature is belt AND braces.

        ⭐ WHY THE `as_primitive` NON-NULLABLE GATE (see the file header, ~line
        86) DOES NOT APPLY HERE, AND THIS IS THE PART TO CHECK IF YOU ARE
        WIDENING THIS. That gate exists because sharing a validity bitmap off a
        source with a NON-ZERO `offset` is silently wrong for the population of
        consumers that read a bare `validity` and index it from bit 0, ignoring
        `offset`. The hazard needs a non-zero offset to bite, and it cannot
        arise on this factory: **`StringArray` HAS NO `offset` FIELD** (its
        fields are `offsets`, `data`, `validity`, `length`, `data_length`,
        `null_count`), so its validity is always bit-0-based, and this factory
        emits `offset=0` exactly as `from_string` does. The shared bitmap and
        the copied one therefore have identical bits at identical bit indices
        over an identical length — the offset-blind readers are CORRECT here
        for the same reason they are correct today. ⛔ Do NOT read this as
        licence to share a validity bitmap off a source that DOES carry an
        offset window.

        The `set_length` calls are the length half of the mirror, not an
        optimisation: `from_string` sizes its fresh buffers to exactly
        `(length + 1) * 4`, `data_length` and `(bm_len + 7) >> 3`, so a source
        buffer that was over-allocated would otherwise leave the shared Column
        with LONGER buffers than the copied one and diverge under a later
        `deep_copy` or `content_hash`. `SharedAlignedBuffer._length` is a
        per-HANDLE field (see `SharedAlignedBuffer.share`, which copies
        `length` into the new handle), so truncating the share does not touch
        the source buffer or the region.

        ⚠ Contrast with `from_string`, which is deliberately left BORROWING:
        its ~40 call sites include many that keep their `StringArray` alive
        afterwards and must keep paying the memcpy. Do not "unify" the two by
        making this one borrow.

        Args:
            arr: The StringArray to CONSUME. Its buffers become the returned
                Column's buffers with no byte copy.

        Returns:
            A Column aliasing `arr`'s buffers (Arc refcount, no memcpy).

        Raises:
            Error if any of `arr`'s buffers is shorter than its own header
            claims — the cases where `from_string`'s `view_range_ro` would
            have been out of range.
        """
        comptime int32_size = size_of[Int32]()

        # Share offsets — `from_string` copies exactly `(length + 1) * 4` B.
        var offsets_bytes = (arr.length + 1) * int32_size
        var offsets_shared = arr.offsets.share()
        if offsets_bytes > Int(offsets_shared.len()):
            raise Error(
                "Column.from_string_shared: offsets buffer holds "
                + String(Int(offsets_shared.len()))
                + " bytes but the array header claims "
                + String(offsets_bytes)
                + " ((length + 1) * 4)"
            )
        offsets_shared.set_length(Int64(offsets_bytes))

        # Share data — `from_string` copies exactly `data_length` B.
        var data_shared = arr.data.share()
        if arr.data_length > Int(data_shared.len()):
            raise Error(
                "Column.from_string_shared: data buffer holds "
                + String(Int(data_shared.len()))
                + " bytes but the array header claims "
                + String(arr.data_length)
                + " (data_length)"
            )
        data_shared.set_length(Int64(arr.data_length))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = arr.validity.value().share()
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                if bm_bytes > Int(bm.buffer.len()):
                    raise Error(
                        "Column.from_string_shared: validity buffer is"
                        " shorter than the bitmap length claims"
                    )
                bm.buffer.set_length(bm_bytes)
            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.STRING,
            data=data_shared^,
            offsets=Optional[SharedAlignedBuffer[HeapRegion]](offsets_shared^),
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    @staticmethod
    def from_boolean(arr: BooleanArray) -> Column[HeapRegion]:
        """Create a Column from a BooleanArray (copies data).

        Args:
            arr: The BooleanArray to wrap.

        Returns:
            A new Column owning copies of the array's buffers.
        """
        # Migrated buffer memcpys onto `copy_from_view`.
        var bm_bytes = (arr.length + 7) >> 3
        var data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
        if bm_bytes > 0:
            data_buf.copy_from_view(
                arr.data.buffer.view_range_ro(0, bm_bytes)
            )
        data_buf.set_length(Int64(bm_bytes))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var valid_len = arr.validity.value().length
            var valid_bm = Bitmap.create(valid_len)
            var valid_bytes = (valid_len + 7) >> 3
            if valid_bytes > 0:
                valid_bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, valid_bytes)
                )
                valid_bm.buffer.set_length(valid_bytes)

            validity = valid_bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.BOOL,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    @staticmethod
    def from_binary(arr: BinaryArray[HeapRegion]) -> Column[HeapRegion]:
        """Create a Column from a BinaryArray[HeapRegion] (copies data).

        Args:
            arr: The BinaryArray to wrap.

        Returns:
            A new Column owning copies of the array's buffers.
        """
        # Copy offsets
        # Migrated buffer memcpys onto `copy_from_view`.
        comptime int32_size = size_of[Int32]()
        var offsets_bytes = (arr.length + 1) * int32_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(arr.offsets.view_range_ro(0, offsets_bytes))
        offsets_buf.set_length(Int64(offsets_bytes))


        # Copy data
        var data_buf = OwnedAlignedBuffer(max(arr.data_length, 1))
        if arr.data_length > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, arr.data_length))
        data_buf.set_length(Int64(arr.data_length))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.BINARY,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    @staticmethod
    def from_strings_promoting(
        imm values: List[String],
        *,
        offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
    ) raises -> Column[HeapRegion]:
        """Build a STRING column, PROMOTING to LARGE_STRING past the ceiling.

        ★ THE DRAIN-SIDE TWIN OF `_parallel_string_gather`'s promotion. A
        producer that stages its output in a `List[String]` and finishes with
        `Column.from_string(StringArray.from_strings(v))` REFUSES at
        `ARROW_INT32_OFFSET_MAX` (`StringArray.from_strings` calls
        `check_int32_offsets` before allocating). That refusal is correct on
        its own terms -- a narrow-typed answer does not exist at those byte
        counts -- but at a site that is free to widen its TAG it throws away an
        answer it could have given. This is the one spelling of "widen instead
        of refuse" for those sites.

        ⚠ THE PROMOTION IS CONDITIONAL, AND THAT IS LOAD-BEARING, NOT
        CONSERVATISM. The output TYPE is user-visible: a consumer that switches
        on `string` would see `large_string` instead. Promoting only when the
        byte total actually demands it means EVERY column that fits today keeps
        its exact current type, so the type change is confined to inputs that
        produce no answer at all right now. An unconditional promotion would
        re-type every string column in the tree to buy nothing.

        ⚠ IT HONOURS A LOWERED TRIP POINT, deliberately. `offset_promote_at`
        is passed to `should_promote_offsets`, so it lowers the TRIP POINT
        and nothing else -- the wide arm below is otherwise unreachable
        outside a multi-GB, multi-minute run, i.e. unreachable in any unit
        test, i.e. unable to go red on a regression. The trip point is capped
        at the real ceiling and can only ever be LOWERED, so the default
        behaviour is `total > ARROW_INT32_OFFSET_MAX` and nothing else.

        The byte total is summed here rather than taken from the caller: it is
        one O(n) pass of `byte_length()` reads against a loop that is about to
        memcpy every one of those bytes, so it is not measurable, and taking it
        as a parameter would be a second place for it to be computed wrongly.

        Args:
            values: The staged output values.
            offset_promote_at: Promotion trip point in bytes (see
                `offset_overflow.clamp_offset_promote_at`). Defaults to the
                production ceiling.

        Returns:
            A `Column` with `arrow_type == STRING` when the total fits an
            Int32 offsets buffer, else `arrow_type == LARGE_STRING`.
        """
        var total_bytes = 0
        for i in range(len(values)):
            total_bytes += values[i].byte_length()

        if should_promote_offsets(total_bytes, offset_promote_at):
            return Column.from_large_string(
                LargeStringArray.from_strings(values)
            )
        return Column.from_string(StringArray.from_strings(values))

    @staticmethod
    def from_strings_with_validity_promoting(
        imm values: List[String],
        imm valid: List[Bool],
        producer: StaticString = "",
        *,
        offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
    ) raises -> Column[HeapRegion]:
        """The NULLABLE twin of `from_strings_promoting`.

        ★ WHY THIS EXISTS SEPARATELY. `from_strings_promoting` covers the
        non-nullable drain only. Every GROUPED drain carries a key-validity
        list (a NULL group is a real group, distinct from the empty string),
        so it calls `StringArray.from_strings_with_validity` and needs its own
        promoting spelling. A `GROUP BY url` over ~100M rows with ~18M
        distinct urls produces ~3.4 GB of output keys and would refuse
        without it.

        THE NULL ACCOUNTING MATCHES THE NARROW TWIN EXACTLY. A null contributes
        ZERO bytes and takes a zero-length offset slot, and the `i < len(valid)`
        guard is the same one — so a `valid` list shorter than the value list
        reads as all-valid on both arms, and the byte total this promotion
        decision is made on is the byte total the chosen constructor will
        allocate. Deciding on a DIFFERENT total from the one the constructor
        computes is the way this helper could silently mis-promote, so the sum
        below is the narrow constructor's own sum, not an approximation of it.

        ⚠ CONDITIONAL, for the reason `from_strings_promoting` states: the
        output TYPE is user-visible, so a column that fits today keeps `string`
        and only a column that has no narrow answer at all widens.

        Args:
            values: Per-row string content (placeholder for null rows).
            valid: Per-row validity flags; `len(valid) == len(values)`.
            producer: Identity of the CALLING producer, for the overflow
                message if the narrow arm still refuses for another reason.
            offset_promote_at: Promotion trip point in bytes (see
                `offset_overflow.clamp_offset_promote_at`). Defaults to the
                production ceiling.

        Returns:
            A `Column` with `arrow_type == STRING` when the total fits an
            Int32 offsets buffer, else `arrow_type == LARGE_STRING`.
        """
        var total_bytes = 0
        for i in range(len(values)):
            if i < len(valid) and not valid[i]:
                continue
            total_bytes += values[i].byte_length()

        if should_promote_offsets(total_bytes, offset_promote_at):
            return Column.from_large_string(
                LargeStringArray.from_strings_with_validity(values, valid)
            )
        return Column.from_string(
            StringArray.from_strings_with_validity(values, valid, producer)
        )

    @staticmethod
    def from_large_string(arr: LargeStringArray[HeapRegion]) -> Column[HeapRegion]:
        """Create a Column from a LargeStringArray[HeapRegion] (copies data).

        Identical shape to `from_string` except the offsets buffer holds
        Int64 entries instead of Int32 (Arrow LargeUtf8 layout, supports
        >2 GB of total string data).

        Args:
            arr: The LargeStringArray to wrap.

        Returns:
            A new Column owning copies of the array's buffers
            (arrow_type == LARGE_STRING).
        """
        # Copy offsets (Int64-sized).
        comptime int64_size = size_of[Int64]()
        var offsets_bytes = (arr.length + 1) * int64_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(arr.offsets.view_range_ro(0, offsets_bytes))
        offsets_buf.set_length(Int64(offsets_bytes))


        # Copy data
        var data_buf = OwnedAlignedBuffer(max(arr.data_length, 1))
        if arr.data_length > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, arr.data_length))
        data_buf.set_length(Int64(arr.data_length))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.LARGE_STRING,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    @staticmethod
    def from_large_binary(arr: LargeBinaryArray[HeapRegion]) -> Column[HeapRegion]:
        """Create a Column from a LargeBinaryArray[HeapRegion] (copies data).

        Identical shape to `from_binary` except the offsets buffer holds
        Int64 entries (Arrow LargeBinary layout, supports >2 GB of total
        binary data).

        Args:
            arr: The LargeBinaryArray to wrap.

        Returns:
            A new Column owning copies of the array's buffers
            (arrow_type == LARGE_BINARY).
        """
        comptime int64_size = size_of[Int64]()
        var offsets_bytes = (arr.length + 1) * int64_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(arr.offsets.view_range_ro(0, offsets_bytes))
        offsets_buf.set_length(Int64(offsets_bytes))


        var data_buf = OwnedAlignedBuffer(max(arr.data_length, 1))
        if arr.data_length > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, arr.data_length))
        data_buf.set_length(Int64(arr.data_length))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return Column[HeapRegion](
            arrow_type=ArrowType.LARGE_BINARY,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    @staticmethod
    def from_dictionary(arr: StringDictionaryArray) -> Column[HeapRegion]:
        """Create a Column from a StringDictionaryArray (copies data).

        Storage layout for dictionary columns:
            _data: int32 indices buffer (4 bytes per row)
            _offsets: dictionary string offsets (int32 array, dict_size + 1 entries)
            _dict_data: dictionary string bytes
            _dict_size: number of unique dictionary entries

        Args:
            arr: The StringDictionaryArray to wrap.

        Returns:
            A new Column with arrow_type == DICTIONARY.
        """
        comptime int32_size = size_of[Int32]()

        # Copy indices into _data
        # Migrated buffer memcpys onto `copy_from_view`.
        var total_idx = arr.length
        var idx_bytes = total_idx * int32_size
        var idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
        if idx_bytes > 0:
            idx_buf.copy_from_view(
                arr.indices.data.view_range_ro(0, idx_bytes)
            )
        idx_buf.set_length(Int64(idx_bytes))


        # Copy dictionary offsets into _offsets
        var dict_size = len(arr.dictionary)
        var dict_offsets_bytes = (dict_size + 1) * int32_size
        var dict_offsets_buf = OwnedAlignedBuffer(dict_offsets_bytes)
        dict_offsets_buf.copy_from_view(
            arr.dictionary.offsets.view_range_ro(0, dict_offsets_bytes)
        )
        dict_offsets_buf.set_length(Int64(dict_offsets_bytes))


        # Copy dictionary string data into _dict_data
        var dict_data_len = arr.dictionary.data_length
        var dict_data_buf = OwnedAlignedBuffer(max(dict_data_len, 1))
        if dict_data_len > 0:
            dict_data_buf.copy_from_view(
                arr.dictionary.data.view_range_ro(0, dict_data_len)
            )
        dict_data_buf.set_length(Int64(dict_data_len))


        # Copy validity bitmap for indices if present
        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.indices.validity:
            var bm_len = arr.indices.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.indices.validity.value().buffer.view_range_ro(
                        0, bm_bytes
                    )
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=idx_buf^,
            offsets=dict_offsets_buf^,
            validity=validity^,
            length=arr.length,
            null_count=arr.indices.null_count,
            offset=0,
        )
        # _dict_data is Optional[SAB]; bridge from OAB.
        col._dict_data = Optional(bridge_oab_to_sab[HeapRegion](dict_data_buf^))
        col._dict_size = dict_size
        # `_dict_index_byte_width` already defaults to 4 (Int32) in
        # Column's primary __init__; explicit-set documents intent.
        col._dict_index_byte_width = 4
        return col^

    @staticmethod
    def from_int64_dict_indices(
        var indices: List[Int64],
        var dict_values: List[String],
        var validity: Optional[Bitmap[HeapRegion]] = None,
        var null_count: Int = 0,
    ) raises -> Column[HeapRegion]:
        """Create a DICTIONARY-typed Column with Int64 (8-byte) indices.

        Wire-side
        sibling factory for `from_dictionary` that bypasses the v1
        `StringDictionaryArray[Int32]` shape so callers can stage a
        column with >2G dict entries (or simply test the Int64-indices
        wire path).

        Storage layout (mirrors `from_dictionary` except indices width):
            _data: Int64 indices buffer (8 bytes per row)
            _offsets: Int32 dictionary string offsets (dict_size + 1)
            _dict_data: dictionary string bytes
            _dict_size: number of unique dictionary entries
            _dict_index_byte_width: 8 (key difference from from_dictionary)

        Args:
            indices: Per-row Int64 indices into `dict_values`.
            dict_values: The dictionary VALUES (one String per entry).
            validity: Optional validity bitmap for the rows (clear bit
                = NULL row at that position).
            null_count: Number of null rows (must match `validity` if
                provided).

        Returns:
            A new DICTIONARY Column whose indices buffer holds 8-byte
            indices.

        Raises:
            Error if any index is out of range
            [0, len(dict_values)).
        """
        comptime int32_size = size_of[Int32]()
        comptime int64_size = size_of[Int64]()
        var n_rows = len(indices)
        var dict_size = len(dict_values)

        # Validate indices.
        for i in range(n_rows):
            var idx = Int(indices[i])
            if idx < 0 or idx >= dict_size:
                raise Error(
                    "Column.from_int64_dict_indices: index "
                    + String(idx)
                    + " at row "
                    + String(i)
                    + " out of range [0, "
                    + String(dict_size)
                    + ")"
                )

        # Indices buffer: n_rows × Int64 LE.
        var idx_bytes = n_rows * int64_size
        var idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
        for i in range(n_rows):
            # Treat Int64 as 8-byte LE little-endian write (consistent
            # with PrimitiveArray[DType.int64] storage convention).
            var v = UInt64(Int(indices[i]) & 0xFFFFFFFFFFFFFFFF)
            for b in range(8):
                idx_buf.write_u8_at(
                    i * 8 + b, UInt8(Int((v >> UInt64(b * 8)) & UInt64(0xFF)))
                )
        idx_buf.set_length(Int64(idx_bytes))


        # Compute total dict byte size + offsets. Use as_bytes() len to
        # honor UTF-8 byte count rather than code-point count.
        var dict_data_len = 0
        for i in range(dict_size):
            dict_data_len += len(dict_values[i].as_bytes())
        var dict_offsets_bytes = (dict_size + 1) * int32_size
        var dict_offsets_buf = OwnedAlignedBuffer(max(dict_offsets_bytes, 1))
        var dict_data_buf = OwnedAlignedBuffer(max(dict_data_len, 1))
        var cursor = 0
        dict_offsets_buf.write_u32_le_at(0, UInt32(0))
        for i in range(dict_size):
            var s = dict_values[i]
            var sb = s.as_bytes()
            var slen = len(sb)
            for j in range(slen):
                dict_data_buf.write_u8_at(cursor + j, sb[j])
            cursor += slen
            dict_offsets_buf.write_u32_le_at((i + 1) * 4, UInt32(cursor))
        dict_offsets_buf.set_length(Int64(dict_offsets_bytes))

        dict_data_buf.set_length(Int64(dict_data_len))


        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=idx_buf^,
            offsets=dict_offsets_buf^,
            validity=validity^,
            length=n_rows,
            null_count=null_count,
            offset=0,
        )
        # _dict_data is Optional[SAB]; bridge from OAB.
        col._dict_data = Optional(bridge_oab_to_sab[HeapRegion](dict_data_buf^))
        col._dict_size = dict_size
        col._dict_index_byte_width = 8
        _ = indices^
        _ = dict_values^
        return col^

    # -------------------------------------------------------------------------
    # NUMERIC dictionary Column.
    #
    # The numeric analogue of `from_dictionary`. Strictly LESS pointer surface
    # than the string dict type that already ships (it drops the string
    # offsets/bytes): owned `SharedAlignedBuffer` codes (`_data`) + an owned
    # numeric dict-values buffer (`_dict_data`), `_offsets=None`, no wildcard
    # fields, no List-in-slab. Discriminated from a string dict by
    # `_dict_value_dtype != DTYPE_NONE` (see `is_numeric_dict`).
    #
    # Storage layout for NUMERIC dictionary columns:
    #     _data:       int32 OR int64 per-row codes (width = code byte width)
    #     _offsets:    None (the discriminator vs the string dict shape)
    #     _dict_data:  flat numeric value buffer, `_dict_size` entries widened
    #                  to the value DType (int32/int64/float32/float64)
    #     _dict_size:  number of distinct dictionary entries
    #     _dict_index_byte_width: code byte width (4 for int32, 8 for int64)
    #     _dict_value_dtype: the value DType
    # -------------------------------------------------------------------------

    @staticmethod
    def from_numeric_dict[
        code_dt: DType, val_dt: DType
    ](
        var codes: PrimitiveArray[code_dt],
        var dict_values: List[Int64],
    ) raises -> Column[HeapRegion]:
        """Create a NUMERIC DICTIONARY Column from per-row codes + numeric
        dict values.

        Parameters:
            code_dt: DType of the per-row codes (int32 or int64). Sets
                `_dict_index_byte_width`.
            val_dt: Value DType the codes resolve to (int32/int64/float32/
                float64). Stored in `_dict_value_dtype`; consumers read
                values via `dict_value_i64` / `dict_value_f64`.

        Args:
            codes: Per-row dictionary indices, NOT gathered to values.
                `codes.length` is the row count (NULL-bearing columns carry
                the codes' validity bitmap).
            dict_values: Distinct dictionary entries in dictionary order,
                widened to Int64 (the form `dict_entries_as_int64()` /
                float bit-pattern as-Int64 produces). Entry `codes[r]`
                resolves to `dict_values[codes[r]]`.

        Returns:
            A new Column with `arrow_type == DICTIONARY`, `is_numeric_dict()`
            True, owning copies of the codes + dict-value buffers.
        """
        comptime assert code_dt == DType.int32 or code_dt == DType.int64, "Column.from_numeric_dict: codes must be int32 or int64"
        comptime code_size = size_of[Scalar[code_dt]]()
        comptime val_size = size_of[Scalar[val_dt]]()
        var dict_size = len(dict_values)

        # Copy the codes into `_data` (preserve the codes' validity bitmap).
        var n_rows = codes.length
        var code_bytes = n_rows * code_size

        # ROBUSTNESS GATE (ASSERT=none hardening). THIS IS THE
        # BOUNDARY: it is the one place per column chunk where an untrusted
        # code stream binds to a dictionary. Nothing downstream re-checks —
        # `dict_value_i64` / `dict_value_f64` / `resolve_numeric_dict_to_flat`
        # index `_dict_data` with the raw code through `ByteView.get_typed`,
        # whose `debug_assert` is inert at ASSERT=none.
        #
        # ⚠ This path is EXACTLY the one the round-1 `resolve_*` fix missed:
        # the numeric dict-VECTOR (preserve_dict) arm exists precisely so the
        # codes are NOT gathered, so `resolve_int32`'s gate never runs on it.
        # One bulk min/max pass per chunk; see `validate_dict_codes`.
        validate_dict_codes[code_dt](
            codes.data.view_range_ro(0, max(code_bytes, 0)),
            n_rows,
            dict_size,
            "Column.from_numeric_dict",
        )

        var code_buf = OwnedAlignedBuffer(max(code_bytes, 1))
        if code_bytes > 0:
            code_buf.copy_from_view(codes.data.view_range_ro(0, code_bytes))
        code_buf.set_length(Int64(code_bytes))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if codes.validity:
            var bm_len = codes.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    codes.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)
            validity = bm^

        # Pack the dict values into `_dict_data` as a flat val_dt buffer.
        var dict_bytes = dict_size * val_size
        var dict_buf = OwnedAlignedBuffer(max(dict_bytes, 1))

        comptime if val_dt == DType.float64:
            for e in range(dict_size):
                # Int64 bits ARE the Float64 bit pattern (producer packs the
                # bitcast); store them back as Float64 LE bytes.
                dict_buf.write_u64_le_at(
                    e * 8, UInt64(dict_values[e].cast[DType.uint64]())
                )
        elif val_dt == DType.float32:
            for e in range(dict_size):
                dict_buf.write_u32_le_at(
                    e * 4,
                    UInt32(
                        (dict_values[e] & Int64(0xFFFFFFFF)).cast[
                            DType.uint64
                        ]()
                    ),
                )
        elif val_dt == DType.int64:
            for e in range(dict_size):
                dict_buf.write_u64_le_at(
                    e * 8, UInt64(dict_values[e].cast[DType.uint64]())
                )
        elif val_dt == DType.int32:
            for e in range(dict_size):
                dict_buf.write_u32_le_at(
                    e * 4,
                    UInt32(
                        (dict_values[e] & Int64(0xFFFFFFFF)).cast[
                            DType.uint64
                        ]()
                    ),
                )
        else:
            comptime assert False, ( "Column.from_numeric_dict: val_dt must be int32/int64/" "float32/float64" )
        dict_buf.set_length(Int64(dict_bytes))

        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=code_buf^,
            offsets=None,
            validity=validity^,
            length=n_rows,
            null_count=codes.null_count,
            offset=0,
        )
        col._dict_data = Optional(bridge_oab_to_sab[HeapRegion](dict_buf^))
        col._dict_size = dict_size
        col._dict_index_byte_width = code_size
        col._dict_value_dtype = val_dt
        _ = codes^
        _ = dict_values^
        return col^

    @staticmethod
    def from_numeric_dict_codes_view[
        code_dt: DType, val_dt: DType
    ](
        codes_view: ByteView[_],
        n_rows: Int,
        var dict_values: List[Int64],
    ) raises -> Column[HeapRegion]:
        """build a NON-NULL NUMERIC DICTIONARY
        Column by COPYING the per-row codes out of a borrowed `codes_view`
        (the per-worker recycled `_codes_scratch`) + numeric dict values.

        Identical semantics to `from_numeric_dict` for the NON-NULL case (no
        validity bitmap, `null_count == 0`), but sources the codes from a
        borrowed ByteView instead of consuming an owning `PrimitiveArray`. This
        is what lets the parquet decode recycle ONE grow-only codes buffer
        across row groups: the codes are COPIED into the Column's own
        `code_buf` exactly as `from_numeric_dict` does, so the recycled
        source buffer stays in the context and is reused for the next RG.

        `codes_view` must cover at least `n_rows * size_of[Scalar[code_dt]]()`
        bytes. Parameters / value-DType packing mirror `from_numeric_dict`.
        """
        comptime assert code_dt == DType.int32 or code_dt == DType.int64, "Column.from_numeric_dict_codes_view: codes must be int32 or int64"
        comptime code_size = size_of[Scalar[code_dt]]()
        comptime val_size = size_of[Scalar[val_dt]]()
        var dict_size = len(dict_values)

        var code_bytes = n_rows * code_size

        # ROBUSTNESS GATE (ASSERT=none hardening). Same boundary
        # as `from_numeric_dict` — this is its recycled-buffer twin, and
        # fixing only one of the two is how this defect class keeps coming
        # back. See that method's note and `validate_dict_codes`.
        validate_dict_codes[code_dt](
            codes_view, n_rows, dict_size, "Column.from_numeric_dict_codes_view"
        )

        var code_buf = OwnedAlignedBuffer(max(code_bytes, 1))
        if code_bytes > 0:
            code_buf.copy_from_view(codes_view)
        code_buf.set_length(Int64(code_bytes))

        var dict_bytes = dict_size * val_size
        var dict_buf = OwnedAlignedBuffer(max(dict_bytes, 1))

        comptime if val_dt == DType.float64:
            for e in range(dict_size):
                dict_buf.write_u64_le_at(
                    e * 8, UInt64(dict_values[e].cast[DType.uint64]())
                )
        elif val_dt == DType.float32:
            for e in range(dict_size):
                dict_buf.write_u32_le_at(
                    e * 4,
                    UInt32(
                        (dict_values[e] & Int64(0xFFFFFFFF)).cast[
                            DType.uint64
                        ]()
                    ),
                )
        elif val_dt == DType.int64:
            for e in range(dict_size):
                dict_buf.write_u64_le_at(
                    e * 8, UInt64(dict_values[e].cast[DType.uint64]())
                )
        elif val_dt == DType.int32:
            for e in range(dict_size):
                dict_buf.write_u32_le_at(
                    e * 4,
                    UInt32(
                        (dict_values[e] & Int64(0xFFFFFFFF)).cast[
                            DType.uint64
                        ]()
                    ),
                )
        else:
            comptime assert False, ( "Column.from_numeric_dict_codes_view: val_dt must be" " int32/int64/float32/float64" )
        dict_buf.set_length(Int64(dict_bytes))

        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=code_buf^,
            offsets=None,
            validity=None,
            length=n_rows,
            null_count=0,
            offset=0,
        )
        col._dict_data = Optional(bridge_oab_to_sab[HeapRegion](dict_buf^))
        col._dict_size = dict_size
        col._dict_index_byte_width = code_size
        col._dict_value_dtype = val_dt
        _ = dict_values^
        return col^

    @staticmethod
    def from_string_dict_codes_view(
        codes_view: ByteView[_],
        n_rows: Int,
        var dict_offsets: List[Int32],
        var dict_bytes: List[UInt8],
    ) raises -> Column[HeapRegion]:
        """STRING-COC SP1: build a WORKER-SAFE NON-NULL STRING
        DICTIONARY Column by COPYING (1) the per-row int32 codes out of a borrowed
        `codes_view` (a recycled per-worker FIXED buffer, so the codes are copied
        immediately) + (2) the per-RG dict int32 OFFSETS (`dict_size + 1`
        cumulative entries, `dict_offsets[0]==0`) + (3) the packed dict UTF-8
        BYTES — none of which is a StringArray / StringDictionaryArray.

        The STRING twin of `from_numeric_dict_codes_view`: the numeric arm resolves
        codes to flat numeric dict values; this arm keeps the BYTE-backed dict
        (offsets + UTF-8 bytes) so the agg fold resolves code->bytes inline over the
        Column's `string_dict_*_view` accessors and the StringArray is built ONLY on
        the serial post-barrier drain (the cross-thread-ArcPointer crash
        class — NO StringArray/StringDictionaryArray is ever constructed or dropped
        on a worker thread). Field layout mirrors `from_dictionary`:
            _data: int32 codes buffer (4 bytes per row), COPIED from `codes_view`
            _offsets: int32 dict offsets (`dict_size + 1` entries), entry `e`'s
                bytes span `[offsets[e], offsets[e+1])` of `_dict_data`
            _dict_data: packed UTF-8 dict bytes
            _dict_size: `len(dict_offsets) - 1`
            _dict_value_dtype: invalid (the string-dict discriminant vs numeric)

        `codes_view` must cover `>= n_rows * 4` bytes. `dict_offsets` / `dict_bytes`
        are the worker-safe per-RG dict (the cursor's `str_dict_offsets_copy` /
        `str_dict_bytes_copy`), passed by value (no cursor borrow across the fold).
        NON-NULL only (no validity bitmap, `null_count == 0`) — the cursor declines
        a nullable string-dict RG per-RG (the abort path), so a chunk reaching here
        is dense.
        """
        comptime int32_size = size_of[Int32]()
        var dict_size = len(dict_offsets) - 1
        if dict_size < 0:
            dict_size = 0

        # (1) Copy the per-row int32 codes into _data (from the recycled view).
        var code_bytes = n_rows * int32_size
        var idx_buf = OwnedAlignedBuffer(max(code_bytes, 1))
        if code_bytes > 0:
            idx_buf.copy_from_view(codes_view)
        idx_buf.set_length(Int64(code_bytes))

        # (2) Pack the dict int32 offsets ((dict_size + 1) entries) into _offsets.
        var dict_offsets_bytes = (dict_size + 1) * int32_size
        var dict_offsets_buf = OwnedAlignedBuffer(max(dict_offsets_bytes, 1))
        for e in range(dict_size + 1):
            dict_offsets_buf.write_u32_le_at(
                e * int32_size,
                UInt32(Int(dict_offsets[e]) & 0xFFFFFFFF),
            )
        dict_offsets_buf.set_length(Int64(dict_offsets_bytes))

        # (3) Pack the dict UTF-8 bytes into _dict_data.
        var dict_data_len = len(dict_bytes)
        var dict_data_buf = OwnedAlignedBuffer(max(dict_data_len, 1))
        for i in range(dict_data_len):
            dict_data_buf.write_u8_at(i, dict_bytes[i])
        dict_data_buf.set_length(Int64(dict_data_len))

        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=idx_buf^,
            offsets=dict_offsets_buf^,
            validity=None,
            length=n_rows,
            null_count=0,
            offset=0,
        )
        col._dict_data = Optional(bridge_oab_to_sab[HeapRegion](dict_data_buf^))
        col._dict_size = dict_size
        # Codes are int32 (4 bytes); `_dict_value_dtype` stays `invalid` (the
        # string-dict discriminant vs the numeric-dict layout — see is_string_dict).
        col._dict_index_byte_width = int32_size
        _ = dict_offsets^
        _ = dict_bytes^
        return col^

    # --- Accessors ---

    @always_inline
    def length(self) -> Int:
        """Return the number of logical elements in this column."""
        return self._length

    @always_inline
    def null_count(self) -> Int:
        """Return the number of null elements."""
        return self._null_count

    @always_inline
    def is_null_at(self, row: Int) -> Bool:
        """True iff logical element `row` is NULL — for ANY arrow type.

        ★ TYPE-AGNOSTIC BY CONSTRUCTION, NOT BY LUCK. Arrow's validity bitmap
        has ONE layout for every type: one bit per logical element, LSB-first,
        1 = valid. Nothing about it depends on the value encoding, so a caller
        that needs only NULL-ness — `count(<col>)` being the canonical one —
        can answer without knowing the type at all, and without a per-family
        typed accessor. `utf8_is_null_at` already said this in its own
        docstring ("width-agnostic"); it is narrower only because of where it
        was added, not because the property is narrower.

        ⚠ IT HONOURS `_offset`, AND THAT IS THE HALF THAT IS EASY TO GET WRONG.
        `Column.slice` shares the WHOLE-column bitmap and carries `_offset > 0`
        into the result, so a per-row lookup on a slice is
        `validity.test(_offset + i)` — its docstring states exactly this. The
        STRING/BINARY/nested accessors ignore `_offset` and are still correct
        because `slice()` REFUSES those layouts (`supports_zero_copy_slice()`
        is False), so their `_offset` is always 0 and the two spellings
        coincide there.

        No validity buffer means NO NULLS (Arrow's fast path), which is the
        same answer `StringArray.is_null` / `PrimitiveArray.is_null` /
        `utf8_is_null_at` all give.
        """
        if not self._validity:
            return False
        return not self._validity.value().test(self._offset + row)

    @always_inline
    def offset(self) -> Int:
        """Return the element offset (for sliced columns)."""
        return self._offset

    def content_hash(self, seed: UInt64) -> UInt64:
        """Fold this column's CONTENT into a running FNV-1a hash, returning
        the updated accumulator.

        Content = the column's structural shape (arrow type tag, logical
        length, null count, element offset, decimal precision/scale, fixed
        inner-size, dict index width / value dtype) + the RAW BYTES of every
        backing buffer (`_data`, `_offsets`, `_validity`, `_dict_data`),
        recursing into nested `_children` (LIST / STRUCT / MAP / UNION).

        This is the column-level half of the **content-derived structural
        identity** that `InMemorySource.structural_id()` folds into the plan
        `structural_hash` (see `in_memory_source.mojo`). It must be:
          * STABLE — two columns built from byte-identical data hash equal
            (so two structurally-identical in-mem plans dedup / cache-hit).
          * DISCRIMINATING — two columns over different data (or different
            offsets / validity / nesting) hash differently (so CSE never
            merges two genuinely-distinct in-mem tables into a false
            self-join).

        Byte access is confined to THIS struct (the buffers are private
        fields); the public surface stays `UInt64 -> UInt64`. No
        `UnsafePointer` crosses the module boundary.
        """
        comptime prime = UInt64(0x00000100000001B3)
        var h = seed
        h = (h ^ UInt64(self.arrow_type.type_id)) * prime
        h = (h ^ UInt64(self._length)) * prime
        h = (h ^ UInt64(self._null_count)) * prime
        h = (h ^ UInt64(self._offset)) * prime
        h = (h ^ UInt64(self._decimal_p)) * prime
        h = (h ^ UInt64(self._decimal_s)) * prime
        h = (h ^ UInt64(self._inner_size)) * prime
        h = (h ^ UInt64(self._dict_index_byte_width)) * prime
        h = (h ^ _dict_value_dtype_tag(self._dict_value_dtype)) * prime
        h = (h ^ UInt64(self._dict_size)) * prime
        # Primary VALUES buffer.
        h = _fold_buffer_bytes(h, self._data)
        # Offsets buffer (var-width / string-dict offsets).
        if self._offsets:
            h = (h ^ UInt64(0xF1)) * prime
            h = _fold_buffer_bytes(h, self._offsets.value())
        # Validity bitmap bytes.
        if self._validity:
            h = (h ^ UInt64(0xF2)) * prime
            h = _fold_buffer_bytes(h, self._validity.value().buffer)
        # Dictionary value bytes (string-dict packed UTF-8 / numeric-dict flat).
        if self._dict_data:
            h = (h ^ UInt64(0xF3)) * prime
            h = _fold_buffer_bytes(h, self._dict_data.value())
        # Nested children (LIST / STRUCT / MAP / UNION) — recurse in order.
        for i in range(len(self._children)):
            h = (h ^ UInt64(0xF4)) * prime
            h = self._children[i].content_hash(h)
        return h

    def values_view_native[
        lo: Origin[mut=False], //,
    ](ref [lo] self) -> ByteView[lo]:
        """Borrow this column's primary VALUES buffer (`_data`) as a tracked
        immutable `ByteView` (origin inferred from the receiver borrow).

        P-2.D.ZC zero-copy bridge: the column-native batch's `column_unified[T]`
        reads a fixed-width column's typed cells directly out of this view —
        sharing the column's Arc-refcounted buffer with NO copy. The returned
        view spans the WHOLE `_data` buffer; the typed accessor honors
        `_offset` (the element slice offset) itself via the byte stride. The
        ByteView's origin is bound to `self` (the column), so the column must
        outlive the view — and a wrapped `ColumnNativeBatch` owns the column
        slab for exactly that lifetime.

        Used only by the per-column (wrapped) `ColumnNativeBatch` storage mode;
        the contiguous-body mode addresses cells via the THSPLC body view.
        """
        # SAFETY: widen the field's intrinsic sub-origin to the named `lo` via
        # the confined pointer cast (the SAB's Arc keeps the bytes pinned while
        # `self` is alive). Mirrors `body_view` / `ColumnAppendix.view`; repeated
        # here because `as_view`'s origin param is inferred-only so cannot be
        # forced to `lo` at the call site.
        var v = self._data.as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())

    @always_inline
    def has_offsets_buffer(self) -> Bool:
        """True iff this column carries an offsets buffer (var-width types).
        P-2.D.ZC: lets a wrapped `ColumnNativeBatch` synthesize a
        `ColumnDescriptor.has_offsets()` without a contiguous body."""
        return Bool(self._offsets)

    @always_inline
    def has_validity_buffer(self) -> Bool:
        """True iff this column carries a validity bitmap. P-2.D.ZC."""
        return Bool(self._validity)

    @always_inline
    def dict_index_byte_width(self) -> Int:
        """Indices buffer byte width for DICTIONARY columns (4 or 8).

        Defaults to 4
        (Int32) for the legacy `from_dictionary` path; set to 8 by
        `from_int64_dict_indices` for >2G dict entries. The Arrow IPC
        encoder's `encode_dictionary` reads this to emit
        `n * dict_index_byte_width` bytes for the indices buffer.
        """
        return self._dict_index_byte_width

    # -------------------------------------------------------------------------
    # NUMERIC dictionary accessors.
    # The ONE shared consumer seam — both agg paths (HashAggTable_Untyped and
    # the typed FlatHashAggSink) fold over these accessors instead of each
    # kernel re-implementing the codes->value gather.
    # -------------------------------------------------------------------------

    @always_inline
    def is_numeric_dict(self) -> Bool:
        """True iff this is a NUMERIC dictionary column (codes + flat numeric
        dict values). False for plain columns AND for string dictionary
        columns (which carry `_offsets` + packed bytes, value dtype invalid).
        """
        return (
            self.arrow_type == ArrowType.DICTIONARY
            and self._dict_value_dtype != DTYPE_NONE
        )

    @always_inline
    def dict_value_dtype(self) -> DType:
        """The value DType a numeric dictionary column's codes resolve to
        (int32/int64/float32/float64). `DTYPE_NONE` for non-numeric-dict
        columns."""
        return self._dict_value_dtype

    @always_inline
    def dict_size(self) -> Int:
        """Number of distinct dictionary entries (numeric or string dict)."""
        return self._dict_size

    @always_inline
    def dict_code_at(self, row: Int) -> Int:
        """Per-row dictionary CODE at `row` for a numeric dictionary column.

        Honors `_offset` (the element slice offset) and the code byte width
        (`_dict_index_byte_width`, 4 for int32 codes / 8 for int64 codes).
        Precondition: `is_numeric_dict()` is True.
        """
        var idx = self._offset + row
        if self._dict_index_byte_width == 8:
            return Int(self._data.get_typed[Scalar[DType.int64]](idx))
        return Int(self._data.get_typed[Scalar[DType.int32]](idx))

    @always_inline
    def dict_value_i64(self, code: Int) -> Int64:
        """Resolve dictionary `code` to its Int64 value for an integer
        numeric dictionary column. Reads the flat value buffer in `_dict_data`
        at `code * value_byte_width`. Precondition: value dtype is int32 or
        int64 (callers route on `dict_value_dtype()`)."""
        if self._dict_value_dtype == DType.int64:
            return self._dict_data.value().get_typed[Scalar[DType.int64]](code)
        # int32 — sign-extend via Int64 widen.
        return Int64(
            Int(self._dict_data.value().get_typed[Scalar[DType.int32]](code))
        )

    @always_inline
    def dict_value_f64(self, code: Int) -> Float64:
        """Resolve dictionary `code` to its Float64 value for a floating
        numeric dictionary column. Reads the flat value buffer in `_dict_data`
        at `code * value_byte_width`. Precondition: value dtype is float32 or
        float64 (callers route on `dict_value_dtype()`)."""
        if self._dict_value_dtype == DType.float64:
            return self._dict_data.value().get_typed[Scalar[DType.float64]](code)
        return Float64(
            self._dict_data.value().get_typed[Scalar[DType.float32]](code)
        )

    # -------------------------------------------------------------------------
    # STREAM-SCAN D0: DICTIONARY layout split.
    #
    # `arrow_type == DICTIONARY` is ONE tag over TWO physically-distinct Column
    # layouts. Operators MUST branch on `is_numeric_dict()` / `is_string_dict()`
    # (the `_offsets` / `_dict_value_dtype` discriminators), NEVER the bare tag
    # — a numeric-dict column at a string-dict-only site (`as_dictionary()`)
    # RAISES, and a string-dict-only int32-code read over a wide-code numeric
    # dict MISREADS.
    #
    #   NUMERIC dict:  `_offsets == None`, `_dict_value_dtype != invalid`,
    #                  `_dict_data` is a flat numeric value buffer. Codes are
    #                  `_dict_index_byte_width` (4 or 8) wide.
    #   STRING dict:   `_offsets` present (int32 dict-string offsets,
    #                  `_dict_size + 1` entries), `_dict_value_dtype == invalid`,
    #                  `_dict_data` is packed UTF-8 dict bytes. Per-row codes in
    #                  `_data` are int32 (`_dict_index_byte_width == 4`).
    # -------------------------------------------------------------------------

    @always_inline
    def is_dictionary(self) -> Bool:
        """True iff this Column carries the DICTIONARY tag (either layout).

        Convenience probe — operators that need to distinguish the two
        physical layouts MUST further call `is_numeric_dict()` /
        `is_string_dict()`, not act on this tag alone.
        """
        return self.arrow_type == ArrowType.DICTIONARY

    @always_inline
    def is_string_dict(self) -> Bool:
        """True iff this is a STRING dictionary column (int32 codes + packed
        UTF-8 dict bytes addressed by `_offsets`).

        The complement of `is_numeric_dict()` within the DICTIONARY tag: a
        string dict carries `_offsets` (and leaves `_dict_value_dtype ==
        invalid`), while a numeric dict has `_offsets == None`. False for plain
        columns AND for numeric dictionary columns.
        """
        return (
            self.arrow_type == ArrowType.DICTIONARY
            and self._dict_value_dtype == DTYPE_NONE
            and Bool(self._offsets)
        )

    @always_inline
    def string_byte_length_at(self, row: Int) -> Int:
        """Per-row UTF-8 BYTE LENGTH at `row` for a plain STRING (int32-offset)
        column, WITHOUT reconstructing a `StringArray`. Honors `_offset`.

        WHY THIS EXISTS. The byte-budgeted
        join chunk planner has to price EVERY output row before any allocation,
        which for a wide string join is tens of millions of rows x 2 string
        columns. The other two accessors both make that impossible:

          * `RecordBatch.column_as_string(i)` -> `Column.as_string()` **COPIES
            the whole offsets AND data buffer** — a multi-GB memcpy just to
            read lengths.
          * `Column.as_string()` also reads `_offsets[0 .. _length]` and IGNORES
            `_offset` entirely, so on a SLICED column it returns the wrong
            strings (the offset-blind-read defect class); this accessor is
            written the other way on purpose.

        O(1), allocation-free, `_offset`-correct — the STRING sibling of
        `string_dict_code_at` below.

        Precondition: `arrow_type == ArrowType.STRING` and `_offsets` is Some
        (the caller gates on `is_plain_string()`). NOT valid for DICTIONARY
        (whose `_offsets` addresses the shared dict payload, not per-row values)
        nor for LARGE_STRING (whose offsets are int64).

        Args:
            row: Zero-based LOGICAL row index within the slice.

        Returns:
            The number of UTF-8 bytes the value at `row` occupies in `_data`.
        """
        var i = self._offset + row
        var start = Int(self._offsets.value().get_typed[Int32](i))
        var end = Int(self._offsets.value().get_typed[Int32](i + 1))
        return end - start

    @always_inline
    def is_plain_string(self) -> Bool:
        """True iff this Column is a plain int32-offset STRING column — i.e.
        exactly the layout whose per-row values are addressed by `_offsets` and
        whose GATHERED output can overflow the Arrow int32 offset limit.

        Deliberately False for DICTIONARY (a gather emits codes + a SHARED
        dictionary, so its output offsets are bounded by the DISTINCT count, not
        the output row count — see the dictionary arm of the gather in
        helpers/compiler_helpers.mojo) and for
        LARGE_STRING (int64 offsets, no 2 GiB ceiling). The join chunk planner
        prices only the columns this returns True for.
        """
        return self.arrow_type == ArrowType.STRING and Bool(self._offsets)

    # -------------------------------------------------------------------------
    # STREAM-SCAN D0: worker-safe STRING-dict CODE accessors.
    #
    # PARALLEL to the numeric-dict accessor family (`dict_code_at` /
    # `dict_value_*`), NOT an overload of it. These expose the int32 per-row
    # codes + the raw dict payload (offsets + UTF-8 bytes) as byte-backed
    # `ByteView`s / scalars WITHOUT constructing a StringArray /
    # StringDictionaryArray — that is the cross-thread-ArcPointer crash
    # class. A worker thread MAY read these (codes + raw bytes only); the
    # StringArray/StringDictionaryArray reconstruction (`as_dictionary()`)
    # happens ONLY on the serial post-barrier drain.
    #
    # The returned `ByteView`s are origin-bound to `self` (the column must
    # outlive the view); the wrapping `ColumnNativeBatch` / RecordBatch owns
    # the column for exactly that lifetime. P3 computes the predicate-over-codes
    # LUT directly over these.
    # -------------------------------------------------------------------------

    @always_inline
    def string_dict_code_at(self, row: Int) -> Int:
        """Per-row int32 dictionary CODE at `row` for a STRING dictionary
        column. Honors `_offset` (the element slice offset). Precondition:
        `is_string_dict()` is True (codes are always int32 for string dict)."""
        var idx = self._offset + row
        return Int(self._data.get_typed[Scalar[DType.int32]](idx))

    def numeric_dict_codes_view[
        lo: Origin[mut=False], //,
    ](ref [lo] self) -> ByteView[lo]:
        """Borrow the per-row codes buffer (`_data`, the WHOLE buffer) of a
        NUMERIC dictionary column as a byte-backed `ByteView` — the numeric
        twin of `string_dict_codes_view`. Codes are `dict_index_byte_width()`
        bytes wide; the caller honors `offset()` itself. Precondition:
        `is_numeric_dict()` is True."""
        # SAFETY: mirrors `string_dict_codes_view` / `values_view_native`.
        var v = self._data.as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())

    def string_dict_codes_view[
        lo: Origin[mut=False], //,
    ](ref [lo] self) -> ByteView[lo]:
        """Borrow the per-row int32 codes buffer (`_data`) of a STRING
        dictionary column as a byte-backed `ByteView` (origin inferred from
        the receiver borrow, mirroring `values_view_native`).

        Codes are int32; the byte length spans the whole `_data` buffer. The
        caller honors `_offset` itself via the int32 stride (`code at row` =
        `view.get_typed[Int32](self.offset() + row)`). Precondition:
        `is_string_dict()` is True. NO StringArray is constructed — worker-safe.

        The BatchView seam re-labels the inferred sub-origin onto the batch
        origin via a confined `unsafe_origin_cast` (the same shape
        `ColumnNativeBatch` uses on `values_view_native`); direct callers
        (the test, P3 worker code) get the inferred receiver origin.
        """
        # SAFETY: mirrors `values_view_native`. The SAB's Arc keeps the codes
        # bytes pinned while `self` is alive; `lo` is a real ASAP-tracked origin
        # bound to the receiver borrow, not a wildcard. Pointer arithmetic is
        # confined to this method body.
        var v = self._data.as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())

    def string_dict_offsets_view[
        lo: Origin[mut=False], //,
    ](ref [lo] self) raises -> ByteView[lo]:
        """Borrow the dict-string int32 OFFSETS buffer (`_offsets`) of a STRING
        dictionary column as a byte-backed `ByteView` (origin = receiver).

        The offsets buffer has `_dict_size + 1` int32 entries; entry `e`'s
        bytes span `[offsets[e], offsets[e+1])` of the dict-bytes view. Raises
        if `_offsets` is missing (i.e. this is NOT a string dict column).
        Precondition: `is_string_dict()` is True. NO StringArray constructed.
        """
        if not self._offsets:
            raise Error(
                "Column.string_dict_offsets_view: not a STRING dictionary"
                " column (missing dict offsets); is_string_dict() is False"
            )
        # SAFETY: see `string_dict_codes_view`. Origin `lo` bound to receiver.
        var v = self._offsets.value().as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())

    def string_dict_bytes_view[
        lo: Origin[mut=False], //,
    ](ref [lo] self) raises -> ByteView[lo]:
        """Borrow the packed dict-string UTF-8 BYTES buffer (`_dict_data`) of a
        STRING dictionary column as a byte-backed `ByteView` (origin =
        receiver).

        Dict entry `e`'s UTF-8 bytes span `[offsets[e], offsets[e+1])`. Raises
        if `_dict_data` is missing. Precondition: `is_string_dict()` is True.
        NO StringArray / StringDictionaryArray is constructed — worker-safe.
        """
        if not self._dict_data:
            raise Error(
                "Column.string_dict_bytes_view: not a STRING dictionary"
                " column (missing dict data); is_string_dict() is False"
            )
        # SAFETY: see `string_dict_codes_view`. Origin `lo` bound to receiver.
        var v = self._dict_data.value().as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())

    def string_dict_value_at[
        lo: Origin[mut=False], //,
    ](ref [lo] self, code: Int) raises -> ByteView[lo]:
        """VECTOR-NATIVE INC-1 (design §B.3): resolve dict entry `code` -> its
        UTF-8 bytes as a receiver-origin `ByteView`, WITHOUT constructing a
        StringArray. The design's named missing primitive — a thin compose of
        `string_dict_offsets_view` + `string_dict_bytes_view`: entry `code`'s
        bytes span `[offsets[code], offsets[code+1])` of the packed dict-bytes
        buffer.

        This is the per-dict-entry resolve the dict-native key path uses to
        canonicalize a code -> resolved bytes ONCE per distinct entry (D), not
        once per row (N). Returns a `ByteView` origin-bound to `self` (the
        column must outlive the view; no `StringArray`, no Arc share on the
        worker, no wildcard origin). Raises if this is
        not a STRING dictionary column (`_offsets` / `_dict_data` missing).

        ⚠ UNCHECKED PRECONDITION: `0 <= code < dict_cardinality`. NOTHING in
        this method enforces it — `get_typed` and `.sub` below are both
        `debug_assert`-only and therefore inert at ASSERT=none. This is a
        per-ROW resolve on the dict-native key path, so the check does not
        belong here; it belongs where the code stream enters the system.
        For codes read out of a Parquet file that boundary is
        `DictionaryDecoder.resolve_as_string_dict`, which range-checks the
        whole stream once per chunk (`komira_parquet/dictionary.mojo`).
        A NEW producer of string-dict codes MUST do the same — see
        `komira_core/arrow/dict_code_bounds.mojo`.
        """
        if not self._offsets or not self._dict_data:
            raise Error(
                "Column.string_dict_value_at: not a STRING dictionary column"
                " (missing dict offsets/data); is_string_dict() is False"
            )
        # SAFETY: see `string_dict_codes_view`. Both views re-labelled onto the
        # receiver origin `lo` (the SAB Arc keeps the dict payload pinned while
        # `self` is alive).
        # ⚠ `.sub` does NOT bounds-check the [start, end) slice — its guard is
        # a `debug_assert` (`byte_view.mojo`), compiled out at ASSERT=none.
        # `code` is validated upstream (see the docstring), which is what
        # actually makes this read sound.
        var offs = self._offsets.value().as_view()
        var start = Int(offs.get_typed[Scalar[DType.int32]](code))
        var end = Int(offs.get_typed[Scalar[DType.int32]](code + 1))
        var bytes = self._dict_data.value().as_view()
        var full = ByteView[lo](
            bytes._unsafe_ptr().unsafe_origin_cast[lo](), bytes.len()
        )
        return full.sub(start, end - start)

    def dict_clone(self) raises -> Column[HeapRegion]:
        """Deep-clone a DICTIONARY column independent of the source batch,
        dispatching on the physical layout.

        STREAM-SCAN D0: replaces the bare `Column.from_dictionary(
        col.as_dictionary())` clone at the partition / topn output-emit sites,
        which RAISES on a numeric-dict column. A numeric dict clones via
        `resolve_numeric_dict_to_flat()` (independent flat values, the logical
        type the schema reports); a string dict round-trips via
        `as_dictionary()`. Precondition: `is_dictionary()` is True.
        """
        if self.is_numeric_dict():
            return self.resolve_numeric_dict_to_flat()
        if self.is_string_dict():
            return Column.from_dictionary(self.as_dictionary())
        raise Error(
            "Column.dict_clone: column is not DICTIONARY (arrow_type "
            + String(self.arrow_type)
            + ")"
        )

    def resolve_numeric_dict_to_flat(self) raises -> Column[HeapRegion]:
        """Materialize a NUMERIC dictionary column to a FLAT primitive Column
        (gather `dict_value(code)` per row). Used by consumers that cannot read
        the dict-vec shape (e.g. the filter predicate evaluator), so they see
        the same flat values the eager `resolve_int*` path produced. Preserves
        the codes' validity bitmap. Precondition: `is_numeric_dict()` is True.
        """
        comptime int64_size = size_of[Int64]()
        comptime int32_size = size_of[Int32]()
        comptime f64_size = size_of[Float64]()
        comptime f32_size = size_of[Float32]()
        var n = self._length
        var vdt = self._dict_value_dtype

        # Copy the codes' validity bitmap, REBASING the window
        # `[_offset, _offset + _length)` to bit 0 — the returned Column carries
        # `offset=0`, so its consumers read `validity.test(i)`.
        #
        # ⛔ NOT A RAW BYTE COPY FROM BIT 0. The VALUES below are windowed —
        # `dict_code_at(r)` adds `_offset` — so on a column with
        # `_offset != 0` a raw copy would pair row `r`'s VALUE with row
        # `r - _offset`'s NULL BIT. Silent, and it does not even need a null
        # to be present at the wrong place to be wrong.
        #
        # Reachable shape: `Column.slice` is zero-copy for DICTIONARY and
        # deliberately SHARES the whole-column bitmap with `_offset > 0` (see its
        # docstring). `split_record_batch` diverts nullable columns to the copy
        # slice, but nothing in this method's contract says so, and the
        # multi-key join's NULL handling makes this method's validity output
        # load-bearing for a JOIN KEY.
        #
        # Same rebase `as_primitive` already performs for the identical reason.
        # `_null_count` is left as-is rather than recomputed: it describes the
        # logical window by the Column invariant, and `Column.slice` recomputes
        # it for the window it produces.
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm = Bitmap.create(n)
            Bitmap.copy_bits_into(
                bm, 0, self._validity.value(), self._offset, n
            )
            validity = bm^

        if vdt == DType.int64:
            var buf = OwnedAlignedBuffer(max(n * int64_size, 1))
            for r in range(n):
                buf.write_u64_le_at(
                    r * 8,
                    self.dict_value_i64(self.dict_code_at(r)).cast[
                        DType.uint64
                    ](),
                )
            buf.set_length(Int64(n * int64_size))
            return Column[HeapRegion](
                arrow_type=ArrowType.INT64, data=buf^, offsets=None,
                validity=validity^, length=n, null_count=self._null_count,
                offset=0,
            )
        elif vdt == DType.int32:
            var buf = OwnedAlignedBuffer(max(n * int32_size, 1))
            for r in range(n):
                buf.write_u32_le_at(
                    r * 4,
                    (
                        self.dict_value_i64(self.dict_code_at(r))
                        & Int64(0xFFFFFFFF)
                    ).cast[DType.uint64]().cast[DType.uint32](),
                )
            buf.set_length(Int64(n * int32_size))
            return Column[HeapRegion](
                arrow_type=ArrowType.INT32, data=buf^, offsets=None,
                validity=validity^, length=n, null_count=self._null_count,
                offset=0,
            )
        elif vdt == DType.float64:
            var buf = OwnedAlignedBuffer(max(n * f64_size, 1))
            for r in range(n):
                buf.set_typed[Scalar[DType.float64]](
                    r, self.dict_value_f64(self.dict_code_at(r))
                )
            buf.set_length(Int64(n * f64_size))
            return Column[HeapRegion](
                arrow_type=ArrowType.FLOAT64, data=buf^, offsets=None,
                validity=validity^, length=n, null_count=self._null_count,
                offset=0,
            )
        else:
            # float32
            var buf = OwnedAlignedBuffer(max(n * f32_size, 1))
            for r in range(n):
                buf.set_typed[Scalar[DType.float32]](
                    r,
                    self.dict_value_f64(self.dict_code_at(r)).cast[
                        DType.float32
                    ](),
                )
            buf.set_length(Int64(n * f32_size))
            return Column[HeapRegion](
                arrow_type=ArrowType.FLOAT32, data=buf^, offsets=None,
                validity=validity^, length=n, null_count=self._null_count,
                offset=0,
            )

    # --- Typed access: reconstruct typed arrays from raw buffers ---
    # These methods create typed views WITHOUT copying the underlying data.
    # The returned array borrows the Column's buffers. The Column MUST outlive
    # the returned reference.
    #
    # For move-based access (where the Column is consumed), use the take_*
    # methods instead.

    def as_primitive[dtype: DType](self) raises -> PrimitiveArray[dtype]:
        """Reconstruct a PrimitiveArray view from this Column's buffers.

        The data is COPIED into a new PrimitiveArray because PrimitiveArray
        owns its MmapAlignedBuffer. For zero-copy access, use the MmapAlignedBuffer
        view API (`view_ro` / `view_mut`).

        Parameters:
            dtype: The expected DType. Must match the Column's storage
                DType. Temporal types
                (Time32_S/MS, Time64_US/NS, Duration_*, Interval_YEAR_MONTH,
                Interval_DAY_TIME) and DATE32/DATE64 share storage DType
                with INT32/INT64; this accessor allows the caller to take
                an int32/int64 view of those storage-compatible types so
                the existing PrimitiveArray-shaped compute kernels work
                without needing per-logical-type wrappers.

        Returns:
            A new PrimitiveArray holding a copy of this Column's data.

        Raises:
            Error if the Column's arrow_type's storage DType does not
            match the requested dtype.
        """
        var expected = ArrowType.from_dtype(dtype)
        var storage_compatible = self.arrow_type == expected
        # Temporal-on-int storage compatibility.
        # Each temporal type maps to a fixed storage DType:
        #   * int32: DATE32, TIME32_S, TIME32_MS, INTERVAL_YEAR_MONTH
        #   * int64: DATE64, TIME64_US, TIME64_NS, DURATION_*, INTERVAL_DAY_TIME,
        #            TIMESTAMP*
        if not storage_compatible:
            if dtype == DType.int32 and (
                self.arrow_type == ArrowType.DATE32
                or self.arrow_type == ArrowType.TIME32_S
                or self.arrow_type == ArrowType.TIME32_MS
                or self.arrow_type == ArrowType.INTERVAL_YEAR_MONTH
            ):
                storage_compatible = True
            elif dtype == DType.int64 and (
                self.arrow_type == ArrowType.DATE64
                or self.arrow_type == ArrowType.TIME64_US
                or self.arrow_type == ArrowType.TIME64_NS
                or self.arrow_type.is_duration()
                or self.arrow_type == ArrowType.INTERVAL_DAY_TIME
                or self.arrow_type.is_timestamp()
            ):
                storage_compatible = True
        if not storage_compatible:
            raise Error(
                "Column.as_primitive: arrow_type mismatch: column is "
                + String(self.arrow_type)
                + " but requested "
                + String(expected)
            )
        # ---------------------------------------------------------------
        # COLUMN VIEW ELIMINATION: zero-copy branch, NON-NULLABLE ONLY.
        #
        # Arc-SHARE THE WINDOW's bytes instead of memcpy'ing them into a fresh
        # malloc. `share_range_as` narrows the shared buffer to exactly
        # `[_offset, _offset + _length)`, so the returned array is
        # INDISTINGUISHABLE from the copy below on every observable the copy
        # path guarantees — same `length`, same `offset` (0), same
        # `data.len() == _length * elem_size`, same values, same
        # `load_simd`/`store_simd` bound — and differs ONLY in that the bytes
        # are aliased rather than duplicated. The column-view-elimination
        # oracle test asserts the value half of that equivalence; the
        # sliced-column `as_primitive` byte-equivalence test asserts the extent
        # half (buffer size, `offset == 0`, and the two downstream copies that
        # are sized off them).
        #
        # ⛔ DO NOT "SIMPLIFY" THIS TO `share_as` + `offset=self._offset`.
        # That spelling is WRONG, in a way that is silent on values and loud
        # only in DRAM. It hands every call site a result whose buffer is the
        # WHOLE source column, and two ordinary continuations —
        # `Column.from_primitive` and `PrimitiveArray.slice`, both of which
        # copy `[0, offset + length)` from byte 0 — then copy the PREFIX. That
        # is precisely the O(total_rows^2 / morsel_rows) shape this accessor's
        # window copy exists to kill, reintroduced one level downstream on a
        # marching per-morsel `_offset` (the partition scan and partition
        # top-N sinks compose exactly that). The whole-buffer share also
        # widened `_length`, which is what `load_simd`'s bounds assert reads —
        # so a kernel over-reading past its window stopped being caught.
        #
        # `not self._validity` is the CORRECTNESS GATE, not a heuristic: the
        # copy also rebases VALIDITY to bit 0, and a large population of
        # consumers reads `arr.validity` from bit 0 while ignoring
        # `arr.offset` (clone_array_validity, merge_binary_arith_validity,
        # merge_cmp_validity behind every kleene predicate finalize, the
        # per-row `validity.test(i)` walks in join/binary-fn). Sharing a
        # nullable column's bitmap would make all of them silently wrong.
        # Same resolution `Column.slice` + `split_record_batch` already
        # adopted for this seam. A nullable column
        # therefore falls through to the copy path verbatim.
        #
        # Checked BEFORE the first side-effecting op (the `OwnedAlignedBuffer`
        # allocation below). `null_count` is 0 by construction here — it must
        # match the copy path's `window_null_count`, which is 0 whenever
        # `_validity` is absent, NOT `self._null_count`.
        #
        # ⭐ UNCONDITIONAL. See the block at the top of this file for the
        # soundness argument, the mutation audit, and the ONE residual it
        # carries — a mutation reached through a re-binding alias, which a
        # call-site audit cannot see.
        #
        # ⛔⛔ THE COPY PATH BELOW IS NOT DEAD AND MUST NOT BE "FINISHED OFF".
        # It is what EVERY NULLABLE COLUMN takes — this `if` guards on
        # `not self._validity` and falls through otherwise. The copy does
        # DOUBLE DUTY there: it REBASES the window to `offset == 0` for values
        # AND validity, and offset-blind validity readers survive elsewhere
        # (a binary-fn operator walk, a parquet decode helper) that are
        # latent-unreachable ONLY because this branch refuses a column carrying
        # a bitmap. Sharing a nullable column's bitmap makes all of them
        # silently wrong — wrong null mask, wrong null_count, no crash.
        # ---------------------------------------------------------------
        comptime elem_size = size_of[Scalar[dtype]]()
        if not self._validity:
            return PrimitiveArray[dtype](
                self._data.share_range_as[HeapRegion](
                    self._offset * elem_size, self._length * elem_size
                ),
                self._length,
                Optional[Bitmap[HeapRegion]](None),
                0,
                0,
            )

        # Copy only the WINDOW [_offset, _offset+_length) of the data buffer,
        # NOT the [0, _offset+_length) prefix. On an Arc-sliced morsel
        # (Column.slice) _offset
        # marches monotonically across the morsels of a resident probe batch,
        # so a prefix-copy was O(total_rows^2 / morsel_rows) DRAM traffic. The
        # returned PrimitiveArray is rebased to offset=0 (every accessor indexes
        # [0, _length) so value semantics are identical). Mirrors
        # _slice_fixed_width (morsel.mojo). `elem_size` is hoisted above the
        # zero-copy arm, which needs the same constant to size its window.
        var win_bytes = self._length * elem_size
        var buf = OwnedAlignedBuffer(max(win_bytes, 1))
        if win_bytes > 0:
            buf.copy_from_view(
                self._data.view_range_ro(self._offset * elem_size, win_bytes)
            )
        buf.set_length(Int64(win_bytes))


        # Rebase the validity bitmap to the window [_offset, _offset+_length)
        # -> [0, _length) and recompute the window null_count (mirror
        # _slice_fixed_width). Skipped for a non-nullable column.
        var validity = Optional[Bitmap[HeapRegion]](None)
        var window_null_count = 0
        if self._validity:
            var bm = Bitmap.create(self._length)
            Bitmap.copy_bits_into(
                bm, 0, self._validity.value(), self._offset, self._length
            )
            window_null_count = self._length - bm.popcount()
            validity = bm^

        return PrimitiveArray[dtype](
            buf^, self._length, validity^, window_null_count, 0
        )

    def can_share_as_primitive[dtype: DType](self) -> Bool:
        """True iff `share_as_primitive[dtype]()` may serve this Column.

        Storage-compatible with `dtype` (same rule `as_primitive` applies, temporal-
        on-int included) AND carrying NO validity bitmap. See
        `share_as_primitive` for why the nullability half of the gate is
        load-bearing rather than conservatism."""
        if self._validity:
            return False
        var expected = ArrowType.from_dtype(dtype)
        if self.arrow_type == expected:
            return True
        if dtype == DType.int32 and (
            self.arrow_type == ArrowType.DATE32
            or self.arrow_type == ArrowType.TIME32_S
            or self.arrow_type == ArrowType.TIME32_MS
            or self.arrow_type == ArrowType.INTERVAL_YEAR_MONTH
        ):
            return True
        if dtype == DType.int64 and (
            self.arrow_type == ArrowType.DATE64
            or self.arrow_type == ArrowType.TIME64_US
            or self.arrow_type == ArrowType.TIME64_NS
            or self.arrow_type.is_duration()
            or self.arrow_type == ArrowType.INTERVAL_DAY_TIME
            or self.arrow_type.is_timestamp()
        ):
            return True
        return False

    def share_as_primitive[dtype: DType](self) raises -> PrimitiveArray[dtype]:
        """Arc-SHARE this Column's value buffer as a PrimitiveArray — the zero-copy
        twin of `as_primitive`, for a caller that has AUDITED its consumers.

        THE SCOPED ACCESSOR, NOT THE GLOBAL FLAG — AND THE TWO ARE NO LONGER
        ALTERNATIVES. `as_primitive` shares on its own account for a
        NON-NULLABLE column, unconditionally. This method exists for the case
        that never covers: a caller that wants the share to CARRY `_offset`
        (see the next paragraph) and has enumerated its own consumers to earn
        it — the same resolution `share_as_string()` /
        `can_share_as_string()` adopted.

        The IN-list kernels read through `arr.view_ro()` (the offset-aware
        PrimitiveArray accessor) and are pinned by an offset-honoring IN-list
        test in `komira_compiler`, and no consumer mutates through an alias.

        ⚠ AND NOTE WHAT THIS ACCESSOR STILL DOES THAT `as_primitive` NO LONGER
        DOES. This one carries `_offset` onto the returned array; `as_primitive`'s
        zero-copy arm shares the WINDOW and rebases to
        `offset == 0`, so that it stays indistinguishable from its own copy path
        (see the block at the top of this file for why — two downstream copies
        are sized off `offset + length` and read from byte 0). The offset-carrying
        shape here is DELIBERATE and is pinned by an offset-carrying key-column
        byte-equivalence test in `komira_sdk`: this accessor's callers have each
        enumerated their consumers as value-accessor-only, so they never reach
        those downstream copies. A caller that cannot say that should use
        `as_primitive`.

        ⚠ THE GATE IS RE-DERIVED HERE, NOT COPIED. `share_as_string`'s author left
        the standing instruction not to inherit the nullability carve-out without
        re-deriving what THIS accessor's copy rebased. `as_primitive`'s copy rebases
        BOTH halves: the value window to `offset == 0`, and the validity bitmap from
        `_offset` to bit 0. The value rebase is free to give up — every
        `PrimitiveArray` value accessor (`get`/`set`/`view_ro`/`view_mut`/`slice`/
        `_unsafe_data_ptr`) indexes `self.offset + i`, so an offset-carrying share
        reads byte-identically. The VALIDITY rebase is not: `clone_array_validity`,
        `merge_binary_arith_validity` and `merge_cmp_validity` (behind every kleene
        predicate finalize) all read a bare `arr.validity` from bit 0 and ignore
        `arr.offset`. So the gate is NON-NULLABLE, and it lands in the same place
        `as_primitive`'s did — by the same derivation, not by inheritance.

        ⚠ CALLER'S OBLIGATION — the residual hazard the block at the top of this file names. Under
        sharing, a consumer that MUTATES the result in place (`PrimitiveArray.set` /
        `set_valid` / `set_null` / `_unsafe_data_ptr` / `view_mut`) writes THROUGH to
        the source Column. Every caller of this method must be able to enumerate its
        consumers and show they are read-only. Do not reach for this from a site
        where that set is open-ended — call `as_primitive` and take the copy.

        Raises if the gate does not hold, so a misuse is LOUD. Check
        `can_share_as_primitive[dtype]()` first to fall back to the copy."""
        if not self.can_share_as_primitive[dtype]():
            raise Error(
                "Column.share_as_primitive: gate not met (arrow_type "
                + String(self.arrow_type)
                + " vs requested "
                + String(ArrowType.from_dtype(dtype))
                + ", has_validity="
                + String(Bool(self._validity))
                + ") — call as_primitive for the copy path"
            )
        return PrimitiveArray[dtype](
            self._data.share_as[HeapRegion](),
            self._length,
            Optional[Bitmap[HeapRegion]](None),
            0,
            self._offset,
        )

    # --- DECIMAL128 ---

    @staticmethod
    def from_decimal128(arr: Decimal128Array[HeapRegion]) raises -> Column[HeapRegion]:
        """Create a Column from a Decimal128Array[HeapRegion] (copies data + (p,s))."""
        var total_elems = arr.length
        var byte_len = total_elems * DECIMAL128_BYTE_WIDTH
        var data_buf = OwnedAlignedBuffer(max(byte_len, 1))
        if byte_len > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, byte_len))
        data_buf.set_length(Int64(byte_len))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(arr.validity.value().buffer.view_range_ro(0, bm_bytes))
                bm.buffer.set_length(bm_bytes)

            validity = bm^
        var col = Column[HeapRegion](
            arrow_type=ArrowType.DECIMAL128,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )
        col._decimal_p = arr.precision
        col._decimal_s = arr.scale
        return col^

    def as_decimal128(self) raises -> Decimal128Array[HeapRegion]:
        """Reconstruct a Decimal128Array[HeapRegion] view from this Column's buffers
        (copies data; uses the carried (precision, scale))."""
        if self.arrow_type != ArrowType.DECIMAL128:
            raise Error(
                "Column.as_decimal128: arrow_type is "
                + String(self.arrow_type)
                + ", expected decimal128"
            )
        if self._decimal_p < 1:
            raise Error("Column.as_decimal128: column carries no precision/scale metadata")
        var byte_len = self._length * DECIMAL128_BYTE_WIDTH
        var src_byte_off = self._offset * DECIMAL128_BYTE_WIDTH
        var buf = OwnedAlignedBuffer(max(byte_len, 1))
        if byte_len > 0:
            buf.copy_from_view(self._data.view_range_ro(src_byte_off, byte_len))
        buf.set_length(Int64(byte_len))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm = Bitmap.copy_slice_from(self._validity.value(), self._offset, self._length)
            validity = bm^
        var arr = Decimal128Array[HeapRegion]()
        # Decimal*/Interval Array.data is now SAB; bridge.
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = validity^
        arr.length = self._length
        arr.null_count = self._null_count
        arr.precision = self._decimal_p
        arr.scale = self._decimal_s
        return arr^

    # --- DECIMAL256 ---

    @staticmethod
    def from_decimal256(arr: Decimal256Array[HeapRegion]) raises -> Column[HeapRegion]:
        """Create a Column from a Decimal256Array[HeapRegion] (copies data + (p,s))."""
        var total_elems = arr.length
        var byte_len = total_elems * DECIMAL256_BYTE_WIDTH
        var data_buf = OwnedAlignedBuffer(max(byte_len, 1))
        if byte_len > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, byte_len))
        data_buf.set_length(Int64(byte_len))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^
        var col = Column[HeapRegion](
            arrow_type=ArrowType.DECIMAL256,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )
        col._decimal_p = arr.precision
        col._decimal_s = arr.scale
        return col^

    def as_decimal256(self) raises -> Decimal256Array[HeapRegion]:
        """Reconstruct a Decimal256Array[HeapRegion] view from this Column's buffers
        (copies data; uses the carried (precision, scale))."""
        if self.arrow_type != ArrowType.DECIMAL256:
            raise Error(
                "Column.as_decimal256: arrow_type is "
                + String(self.arrow_type)
                + ", expected decimal256"
            )
        if self._decimal_p < 1:
            raise Error("Column.as_decimal256: column carries no precision/scale metadata")
        var byte_len = self._length * DECIMAL256_BYTE_WIDTH
        var src_byte_off = self._offset * DECIMAL256_BYTE_WIDTH
        var buf = OwnedAlignedBuffer(max(byte_len, 1))
        if byte_len > 0:
            buf.copy_from_view(self._data.view_range_ro(src_byte_off, byte_len))
        buf.set_length(Int64(byte_len))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm = Bitmap.copy_slice_from(self._validity.value(), self._offset, self._length)
            validity = bm^
        var arr = Decimal256Array[HeapRegion]()
        # Decimal*/Interval Array.data is now SAB; bridge.
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = validity^
        arr.length = self._length
        arr.null_count = self._null_count
        arr.precision = self._decimal_p
        arr.scale = self._decimal_s
        return arr^

    # --- INTERVAL_MONTH_DAY_NANO ---

    @staticmethod
    def from_interval_mdn(arr: IntervalMonthDayNanoArray[HeapRegion]) raises -> Column[HeapRegion]:
        """Create a Column from an IntervalMonthDayNanoArray[HeapRegion] (copies data).

        Mirrors `from_decimal128` / `from_decimal256` at the 16-byte byte-slab
        layout — Arrow's INTERVAL_MONTH_DAY_NANO carries (int32 months,
        int32 days, int64 nanos) packed contiguously per element.  The
        Column-level layout is otherwise identical to other fixed-width
        types (data buffer + optional validity bitmap).
        """
        var total_elems = arr.length
        var byte_len = total_elems * INTERVAL_MDN_BYTE_WIDTH
        var data_buf = OwnedAlignedBuffer(max(byte_len, 1))
        if byte_len > 0:
            data_buf.copy_from_view(arr.data.view_range_ro(0, byte_len))
        data_buf.set_length(Int64(byte_len))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if arr.validity:
            var bm_len = arr.validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    arr.validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^
        return Column[HeapRegion](
            arrow_type=ArrowType.INTERVAL_MONTH_DAY_NANO,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=arr.length,
            null_count=arr.null_count,
            offset=0,
        )

    def as_interval_mdn(self) raises -> IntervalMonthDayNanoArray[HeapRegion]:
        """Reconstruct an IntervalMonthDayNanoArray[HeapRegion] from this Column's
        16-byte byte-slab buffer.  Copies data; honors `_offset`."""
        if self.arrow_type != ArrowType.INTERVAL_MONTH_DAY_NANO:
            raise Error(
                "Column.as_interval_mdn: arrow_type is "
                + String(self.arrow_type)
                + ", expected interval[month_day_nano]"
            )
        var byte_len = self._length * INTERVAL_MDN_BYTE_WIDTH
        var src_byte_off = self._offset * INTERVAL_MDN_BYTE_WIDTH
        var buf = OwnedAlignedBuffer(max(byte_len, 1))
        if byte_len > 0:
            buf.copy_from_view(self._data.view_range_ro(src_byte_off, byte_len))
        buf.set_length(Int64(byte_len))

        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm = Bitmap.copy_slice_from(
                self._validity.value(), self._offset, self._length
            )
            validity = bm^
        var arr = IntervalMonthDayNanoArray[HeapRegion]()
        # Decimal*/Interval Array.data is now SAB; bridge.
        arr.data = bridge_oab_to_sab[HeapRegion](buf^)
        arr.validity = validity^
        arr.length = self._length
        arr.null_count = self._null_count
        return arr^

    # --- LIST<T> / STRUCT / MAP wire-in ---

    @staticmethod
    def from_list(arr: ListArray[HeapRegion]) raises -> Column[HeapRegion]:
        """Create a type-erased Column (`arrow_type == ArrowType.LIST`) from a
        ListArray.

        Generalized past the Utf8-child specialization — the child
        Column rides in the new `_children` slot, supporting LIST<Int32>,
        LIST<Decimal128>, LIST<Struct>, etc.  Thin forward to
        `ListArray.to_column` (the pack logic lives there to keep the
        Column-level method count manageable)."""
        return arr.to_column()

    def as_list(self) raises -> ListArray[HeapRegion]:
        """Reconstruct a ListArray[HeapRegion] (with first-class `child: Column`) from
        this Column's buffers + `_children[0]`.
        Phase G — supports any child arrow_type.

        Constrained to K=HeapRegion; ListArray.from_column
        takes Column[HeapRegion]. Nested-type unpack is HeapRegion-only.
        The deep_copy() round-trip is a no-op cost in the common case
        (self IS Column[HeapRegion]); the type-system requires an explicit
        bridge from Column[Self.K] to Column[HeapRegion].
        """
        comptime assert (Self.K == HeapRegion), "Column.as_list: requires K=HeapRegion (ListArray.from_column takes Column[HeapRegion])."
        return ListArray.from_column(self.deep_copy())

    def as_list_of_string(self) raises -> ListArray[HeapRegion]:
        """Reconstruct a STRING-child ListArray[HeapRegion] from this Column's buffers
        (the Column must have been built by `from_list`).
        Alias for the regexp call sites; equivalent to
        `as_list()` followed by a runtime check that the child is STRING."""
        comptime assert (Self.K == HeapRegion), "Column.as_list_of_string: requires K=HeapRegion."
        var la = ListArray.from_column(self.deep_copy())
        if la.child.arrow_type != ArrowType.STRING:
            raise Error(
                "Column.as_list_of_string: child arrow_type is "
                + String(la.child.arrow_type)
                + ", expected STRING"
            )
        return la^

    @staticmethod
    def from_struct(arr: StructArray) raises -> Column[HeapRegion]:
        """Create a type-erased Column (`arrow_type == ArrowType.STRUCT`)
        from a StructArray.  Phase G wire-in.  Thin forward to
        `StructArray.to_column`."""
        return arr.to_column()

    def as_struct(self) raises -> StructArray:
        """Reconstruct a StructArray from this Column's `_children` +
        `_field_names`.  Phase G wire-in."""
        comptime assert (Self.K == HeapRegion), "Column.as_struct: requires K=HeapRegion."
        return StructArray.from_column(self.deep_copy())

    @staticmethod
    def from_map(arr: MapArray[HeapRegion]) raises -> Column[HeapRegion]:
        """Create a type-erased Column (`arrow_type == ArrowType.MAP`)
        from a MapArray.  Phase G wire-in.  Thin forward to
        `MapArray.to_column`."""
        return arr.to_column()

    def as_map(self) raises -> MapArray[HeapRegion]:
        """Reconstruct a MapArray[HeapRegion] from this Column's offsets + entries
        child + `_keys_sorted`.  Phase G wire-in."""
        comptime assert (Self.K == HeapRegion), "Column.as_map: requires K=HeapRegion."
        return MapArray.from_column(self.deep_copy())

    # --- UNION wire-in ---

    @staticmethod
    def from_union(arr: UnionArray[HeapRegion]) raises -> Column[HeapRegion]:
        """Create a type-erased Column (`arrow_type == ArrowType.UNION_SPARSE`
        or `UNION_DENSE`) from a UnionArray.  Phase H wire-in.  Thin forward
        to `UnionArray.to_column`."""
        return arr.to_column()

    def as_union(self) raises -> UnionArray[HeapRegion]:
        """Reconstruct a UnionArray[HeapRegion] from this Column's types buffer + (dense
        only) offsets buffer + `_children` + `_type_ids`.  Phase H wire-in."""
        comptime assert (Self.K == HeapRegion), "Column.as_union: requires K=HeapRegion."
        return UnionArray.from_column(self.deep_copy())

    # --- FIXED_SIZE_LIST factory ---

    @staticmethod
    def from_fixed_size_list(
        var child: Column[HeapRegion],
        list_size: Int,
        length: Int,
        var validity: Optional[Bitmap[HeapRegion]] = None,
        null_count: Int = 0,
    ) raises -> Column[HeapRegion]:
        """Create a FIXED_SIZE_LIST Column with a single fixed-width
        inner child.

        Args:
            child: Inner Column. Must have exactly `length * list_size`
                rows (Arrow spec invariant).
            list_size: Number of inner elements per parent row.
            length: Number of parent rows.
            validity: Optional validity bitmap.
            null_count: Number of null parent rows.

        Storage shape: validity only (NO offsets; element count per
        row is fixed at `list_size`, carried on Column._inner_size).
        Child column carries the flattened inner values.
        """
        if list_size <= 0:
            raise Error(
                "Column.from_fixed_size_list: list_size must be > 0; got "
                + String(list_size)
            )
        if child._length != length * list_size:
            raise Error(
                "Column.from_fixed_size_list: child length "
                + String(child._length)
                + " != length * list_size = "
                + String(length * list_size)
            )
        var col = Column[HeapRegion](
            arrow_type=ArrowType.FIXED_SIZE_LIST,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        col._inner_size = list_size
        col._children.append(child^)
        return col^

    # --- FIXED_SIZE_BINARY factory ---

    @staticmethod
    def from_fixed_size_binary(
        var data: OwnedAlignedBuffer,
        byte_width: Int,
        length: Int,
        var validity: Optional[Bitmap[HeapRegion]] = None,
        null_count: Int = 0,
    ) -> Column[HeapRegion]:
        """Create a FIXED_SIZE_BINARY Column from a flat byte slab.

        Args:
            data: Flat byte buffer holding `length` × `byte_width` bytes.
            byte_width: Per-row byte width (e.g. 16 for Decimal128-backed,
                32 for Decimal256-backed, N for pa.binary(N) interop).
            length: Number of logical rows.
            validity: Optional validity bitmap.
            null_count: Number of null rows (0 if all-non-null).

        Storage shape: identical to DECIMAL128 / DECIMAL256 / INTERVAL_MDN
        — flat byte slab, no offsets buffer. The byte_width is carried
        on Column._inner_size.
        """
        var col = Column[HeapRegion](
            arrow_type=ArrowType.FIXED_SIZE_BINARY,
            data=data^,
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        col._inner_size = byte_width
        return col^

    # --- Zero-copy borrowed-buffer factories ---
    #
    # Construct non-owning Columns that borrow into externally-managed
    # bytes (typically the IPC frame buffer). The returned Column's
    # buffers have `capacity == 0` (sentinel: __del__ is a no-op) so
    # no memory is freed when the Column drops.
    #
    # SAFETY: the source bytes referenced by the views MUST outlive
    # the returned Column. Caller responsibility (the borrowed
    # MmapAlignedBuffer's MutExternalOrigin field-type drops origin
    # tracking; same shape as PrimitiveArray.from_view).
    #
    # Sibling pattern: Column.from_borrowed_*
    # is the Column-level analogue of PrimitiveArray.from_view. Used
    # by ipc_decoder_dispatch.decode_record_batch_zerocopy to construct
    # Columns whose buffers point into the IPC body bytes — zero memcpy
    # on the hot path.

    @staticmethod
    def from_borrowed_primitive_no_nulls(
        arrow_type: ArrowType,
        data_view: ByteView[_],
        length: Int,
    ) -> Column[HeapRegion]:
        """Construct a non-owning fixed-width primitive Column borrowing
        into `data_view`'s bytes. All-non-null (null_count == 0; no
        validity bitmap).

        Use for INT*, UINT*, FLOAT*, DATE*, TIME*, TIMESTAMP*, DURATION*,
        INTERVAL_*, DECIMAL128/256 columns where every element is valid.
        Nullable primitive columns are not covered by this factory.

        SAFETY: see module-level header at the zero-copy factory section.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(data_view)
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data_buf^,
            offsets=None,
            validity=None,
            length=length,
            null_count=0,
            offset=0,
        )

    @staticmethod
    def from_borrowed_varlen_no_nulls(
        arrow_type: ArrowType,
        data_view: ByteView[_],
        offsets_view: ByteView[_],
        length: Int,
    ) -> Column[HeapRegion]:
        """Construct a non-owning variable-length Column (STRING/BINARY/
        LARGE_STRING/LARGE_BINARY) borrowing into `data_view` (raw bytes)
        and `offsets_view` (Int32 or Int64 offsets buffer). All-non-null
        (null_count == 0).

        SAFETY: see module-level header at the zero-copy factory section.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(data_view)
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var offsets_buf = SharedAlignedBuffer.from_borrowed_view(offsets_view)
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=None,
            length=length,
            null_count=0,
            offset=0,
        )

    @staticmethod
    def from_borrowed_primitive_nullable(
        arrow_type: ArrowType,
        data_view: ByteView[_],
        validity_view: ByteView[_],
        length: Int,
        null_count: Int,
    ) -> Column[HeapRegion]:
        """Nullable variant of `from_borrowed_primitive_no_nulls`. The
        validity bitmap also borrows into the source bytes (typically
        the IPC body's validity buffer slice).

        SAFETY: see module-level header at the zero-copy factory section.
        Both `data_view` and `validity_view` must share the same
        source-bytes-outlive-Column contract.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(data_view)
        var validity = Bitmap.from_borrowed_view(validity_view, length)
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )

    @staticmethod
    def from_borrowed_varlen_nullable(
        arrow_type: ArrowType,
        data_view: ByteView[_],
        offsets_view: ByteView[_],
        validity_view: ByteView[_],
        length: Int,
        null_count: Int,
    ) -> Column[HeapRegion]:
        """Nullable variant of `from_borrowed_varlen_no_nulls`. All three
        buffers (data, offsets, validity) borrow from the source bytes.

        SAFETY: see module-level header at the zero-copy factory section.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(data_view)
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var offsets_buf = SharedAlignedBuffer.from_borrowed_view(offsets_view)
        var validity = Bitmap.from_borrowed_view(validity_view, length)
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )

    # --- Nested-type borrowed factories ---
    #
    # The nested zero-copy decoder constructs the parent Column via
    # these factories (with borrowed validity / offsets / type_ids
    # buffers), then appends recursively-decoded child Columns to
    # `_children`. Child Columns may themselves be borrowed (via
    # from_borrowed_primitive_* etc.) or owning, transparently.
    #
    # SAFETY: same contract as the flat from_borrowed_* factories —
    # the source bytes referenced by every view MUST outlive the
    # returned Column (and its children, recursively).

    @staticmethod
    def from_borrowed_struct(
        validity_view: ByteView[_],
        length: Int,
        null_count: Int,
    ) -> Column[HeapRegion]:
        """STRUCT Column with borrowed validity bitmap only (NO data,
        NO offsets). Caller appends decoded child Columns via
        `column._children.append(child^)`. When null_count == 0, pass
        an empty `validity_view` (length 0) to skip the bitmap.
        """
        var validity = Optional[Bitmap[HeapRegion]](None)
        if null_count > 0:
            validity = Bitmap.from_borrowed_view(validity_view, length)
        return Column[HeapRegion](
            arrow_type=ArrowType.STRUCT,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )

    @staticmethod
    def from_borrowed_list(
        arrow_type: ArrowType,
        offsets_view: ByteView[_],
        validity_view: ByteView[_],
        length: Int,
        null_count: Int,
    ) -> Column[HeapRegion]:
        """LIST / LARGE_LIST / MAP Column with borrowed offsets +
        validity buffers (NO data buffer). Caller appends 1 decoded
        child Column. When null_count == 0, pass an empty `validity_view`.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var offsets_buf = SharedAlignedBuffer.from_borrowed_view(offsets_view)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if null_count > 0:
            validity = Bitmap.from_borrowed_view(validity_view, length)
        # Migrated. Was `MmapAlignedBuffer[64, HeapRegion](0)` for
        # data + `_borrow_from_view`-built `offsets_buf`. Now uses
        # `SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(0))` for the empty
        # data placeholder so both args are SAB-typed (routes through Column's
        # SAB-accepting ctor) and offsets_buf is SAB-direct.
        return Column[HeapRegion](
            arrow_type=arrow_type,
            data=SharedAlignedBuffer.from_owned(OwnedAlignedBuffer(0)),
            offsets=Optional[SharedAlignedBuffer[HeapRegion]](offsets_buf^),
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )

    @staticmethod
    def from_borrowed_fixed_size_binary(
        data_view: ByteView[_],
        validity_view: ByteView[_],
        length: Int,
        null_count: Int,
        byte_width: Int,
    ) -> Column[HeapRegion]:
        """FIXED_SIZE_BINARY Column. Values buffer holds `length *
        byte_width` bytes; `_inner_size` carries the byte_width.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(data_view)
        var validity = Optional[Bitmap[HeapRegion]](None)
        if null_count > 0:
            validity = Bitmap.from_borrowed_view(validity_view, length)
        var col = Column[HeapRegion](
            arrow_type=ArrowType.FIXED_SIZE_BINARY,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        col._inner_size = byte_width
        return col^

    @staticmethod
    def from_borrowed_fixed_size_list(
        validity_view: ByteView[_],
        length: Int,
        null_count: Int,
        list_size: Int,
    ) -> Column[HeapRegion]:
        """FIXED_SIZE_LIST Column with borrowed validity (NO offsets;
        NO data). `_inner_size` carries the list_size. Caller appends
        1 decoded child Column with `length * list_size` rows.
        """
        var validity = Optional[Bitmap[HeapRegion]](None)
        if null_count > 0:
            validity = Bitmap.from_borrowed_view(validity_view, length)
        var col = Column[HeapRegion](
            arrow_type=ArrowType.FIXED_SIZE_LIST,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        col._inner_size = list_size
        return col^

    @staticmethod
    def from_borrowed_union_sparse(
        type_ids_view: ByteView[_],
        length: Int,
        null_count: Int,
    ) -> Column[HeapRegion]:
        """UNION_SPARSE Column. type_ids stored in `_data` (Int8 per
        Arrow spec). NO validity, NO offsets.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(type_ids_view)
        return Column[HeapRegion](
            arrow_type=ArrowType.UNION_SPARSE,
            data=data_buf^,
            offsets=None,
            validity=None,
            length=length,
            null_count=null_count,
            offset=0,
        )

    @staticmethod
    def from_borrowed_union_dense(
        type_ids_view: ByteView[_],
        offsets_view: ByteView[_],
        length: Int,
        null_count: Int,
    ) -> Column[HeapRegion]:
        """UNION_DENSE Column. type_ids in `_data` (Int8); offsets
        (Int32). NO validity per Arrow spec.
        """
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var data_buf = SharedAlignedBuffer.from_borrowed_view(type_ids_view)
        # Migrated from `MmapAlignedBuffer[64]._borrow_from_view`.
        var offsets_buf = SharedAlignedBuffer.from_borrowed_view(offsets_view)
        return Column[HeapRegion](
            arrow_type=ArrowType.UNION_DENSE,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=None,
            length=length,
            null_count=null_count,
            offset=0,
        )

    # --- Nested-type accessors ---

    @always_inline
    def num_children(self) -> Int:
        """Number of child Columns (LIST=1, MAP=1, STRUCT=N, others=0)."""
        return len(self._children)

    @always_inline
    def child_at(self, index: Int) -> ref [self._children._bytes] Column[HeapRegion]:
        """Safe reference to the child Column at `index`. The reference
        lifetime is tied to this Column's child storage."""
        return self._children[index]

    @always_inline
    def field_name(self, index: Int) -> String:
        """STRUCT field name at `index`. Empty if non-STRUCT or out of range."""
        if index >= 0 and index < len(self._field_names):
            return self._field_names[index]
        return String("")

    @always_inline
    def keys_sorted(self) -> Bool:
        """MAP's `keys_sorted` flag (mirrors ARROW_FLAG_MAP_KEYS_SORTED)."""
        return self._keys_sorted

    @always_inline
    def type_ids(self) -> List[Int]:
        """UNION declared per-child type-id list (empty for non-union).
        """
        return self._type_ids.copy()

    @always_inline
    def decimal_precision(self) -> Int:
        """Decimal precision (0 for non-decimal columns)."""
        return self._decimal_p

    @always_inline
    def decimal_scale(self) -> Int:
        """Decimal scale (0 for non-decimal columns)."""
        return self._decimal_s

    def as_string(self) raises -> StringArray[HeapRegion]:
        """Reconstruct a StringArray view from this Column's buffers.

        The data is COPIED into a new StringArray.

        Returns:
            A new StringArray holding a copy of this Column's data.

        Raises:
            Error if the Column's arrow_type is not STRING.
        """
        if self.arrow_type != ArrowType.STRING:
            raise Error(
                "Column.as_string: arrow_type is "
                + String(self.arrow_type)
                + ", expected string"
            )
        if not self._offsets:
            raise Error("Column.as_string: missing offsets buffer")

        # Copy offsets buffer
        # Migrated buffer memcpys + offset lookup onto view API.
        comptime int32_size = size_of[Int32]()
        var offsets_bytes = (self._length + 1) * int32_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(
            self._offsets.value().view_range_ro(0, offsets_bytes)
        )
        offsets_buf.set_length(Int64(offsets_bytes))


        # Get total data length from last offset
        var data_length = Int(
            self._offsets.value().get_typed[Int32](self._length)
        )

        # Copy data buffer
        var data_buf = OwnedAlignedBuffer(max(data_length, 1))
        if data_length > 0:
            data_buf.copy_from_view(self._data.view_range_ro(0, data_length))
        data_buf.set_length(Int64(data_length))


        # Copy validity bitmap if present
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm_len = self._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return StringArray(
            offsets=offsets_buf^,
            data=data_buf^,
            validity=validity^,
            length=self._length,
            data_length=data_length,
            null_count=self._null_count,
        )

    def can_share_as_string(self) -> Bool:
        """True iff `share_as_string()` can return a zero-copy alias of this
        column's STRING buffers that reads byte-identically to `as_string()`.

        The three conditions are all CORRECTNESS gates, not heuristics:

        * `arrow_type == STRING` — the layout `share_as_string` reproduces.
        * `_offsets` present — `as_string` raises without it.
        * `_offset == 0` — `as_string` copies `offsets[0 .. _length]` and
          `data[0 .. offsets[_length]]` and copies validity from BIT 0,
          i.e. it reads the column as if `_offset` were 0 and IGNORES it
          (`supports_zero_copy_slice()` excludes STRING for exactly this
          reason). A share therefore reproduces `as_string`'s bytes only at
          `_offset == 0`. No public path can build an `_offset > 0` plain
          STRING column today (`Column.slice` RAISES for STRING), so this
          gate is a guard against a future one, not a live diversion.

        Callers that want the copy unconditionally keep calling `as_string()`.
        """
        return (
            self.arrow_type == ArrowType.STRING
            and self._offsets.__bool__()
            and self._offset == 0
        )

    def share_as_string(self) raises -> StringArray[HeapRegion]:
        """Arc-SHARE this STRING column's buffers as a StringArray — the
        zero-copy dual of `as_string()`, which memcpy's every buffer.

        Member of the existing `share` family (`Column.share` /
        `SharedAlignedBuffer.share` / `Bitmap.share`), NOT a second version of
        `as_string`: the two differ in OWNERSHIP, not in the values they read.
        Every field of the returned `StringArray` is set to the value
        `as_string()` would have set (`length`, `data_length =
        offsets[_length]`, `null_count`) — only the buffers alias instead of
        being copied; `data_base_offset` exposes the aliasing.

        WHY IT EXISTS: the composite join's key extract
        (`extract_join_key_columns_typed`) turned a 20M-row / 1.12 GB probe
        key column into a fresh 1.12 GB allocation on every call, purely to
        hand the probe kernel something to byte-compare against. The probe
        reads it through `view_ro()` only — there is no mutation API on
        `StringArray` at all (no `mut self` method exists) — so the copy bought
        nothing but a first-touch page-fault storm over ~273k fresh pages.

        SOUNDNESS is `Column.share`'s argument verbatim: Arrow buffers are
        immutable on every consumer path, and the zero-copy mmap decode
        ALREADY aliases these bytes PROT_READ across the Column -> RecordBatch
        chain. The `_mmap_keepalive` cookie rides along inside
        `SharedAlignedBuffer.share_as`, so an mmap-backed source stays
        munmap-pinned for the returned array's lifetime.

        ⚠ Unlike `as_primitive`'s share branch, VALIDITY IS SAFE TO SHARE HERE.
        That branch had to exclude nullable columns because the copy REBASED
        validity from `_offset` to bit 0 and its consumers read from bit 0.
        `as_string` never rebased anything — it copies validity from bit 0 and
        ignores `_offset` — so at the `_offset == 0` this method requires, the
        shared bitmap and the copied bitmap have identical bits at identical
        indices.

        Raises:
            Error if `can_share_as_string()` is False — callers gate on it and
            fall back to `as_string()`.
        """
        if not self.can_share_as_string():
            raise Error(
                "Column.share_as_string: requires a plain STRING column with"
                " an offsets buffer and _offset == 0; arrow_type is "
                + String(self.arrow_type)
                + ", _offset is "
                + String(self._offset)
                + " (gate on can_share_as_string() and use as_string())"
            )
        comptime assert (Self.K == HeapRegion), ( "Column.share_as_string: only K=HeapRegion columns can be shared" " into a StringArray[HeapRegion]; RecordBatch columns are always" " HeapRegion-typed (mmap rides as a keepalive cookie, not as K)." )
        var data_length = Int(
            self._offsets.value().get_typed[Int32](self._length)
        )
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            ref src_bm = self._validity.value()
            validity = Bitmap[HeapRegion](
                src_bm.buffer.share_as[HeapRegion](), src_bm.length
            )
        return StringArray[HeapRegion](
            offsets=self._offsets.value().share_as[HeapRegion](),
            data=self._data.share_as[HeapRegion](),
            validity=validity^,
            length=self._length,
            data_length=data_length,
            null_count=self._null_count,
        )

    def as_boolean(self) raises -> BooleanArray:
        """Reconstruct a BooleanArray view from this Column's buffers.

        The data is COPIED into a new BooleanArray.

        Returns:
            A new BooleanArray holding a copy of this Column's data.

        Raises:
            Error if the Column's arrow_type is not BOOL.
        """
        if self.arrow_type != ArrowType.BOOL:
            raise Error(
                "Column.as_boolean: arrow_type is "
                + String(self.arrow_type)
                + ", expected bool"
            )
        # Copy the data bitmap
        # Migrated buffer memcpys onto `copy_from_view`.
        var data_bm = Bitmap.create(self._length)
        var bm_bytes = (self._length + 7) >> 3
        if bm_bytes > 0:
            data_bm.buffer.copy_from_view(
                self._data.view_range_ro(0, bm_bytes)
            )
            data_bm.buffer.set_length(bm_bytes)


        # Copy validity bitmap if present
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var valid_len = self._validity.value().length
            var valid_bm = Bitmap.create(valid_len)
            var valid_bytes = (valid_len + 7) >> 3
            if valid_bytes > 0:
                valid_bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(
                        0, valid_bytes
                    )
                )
                valid_bm.buffer.set_length(valid_bytes)

            validity = valid_bm^

        var arr = BooleanArray()
        arr.data = data_bm^
        arr.validity = validity^
        arr.length = self._length
        arr.null_count = self._null_count
        return arr^

    def as_binary(self) raises -> BinaryArray[HeapRegion]:
        """Reconstruct a BinaryArray[HeapRegion] view from this Column's buffers.

        The data is COPIED into a new BinaryArray.

        Returns:
            A new BinaryArray holding a copy of this Column's data.

        Raises:
            Error if the Column's arrow_type is not BINARY.
        """
        if self.arrow_type != ArrowType.BINARY:
            raise Error(
                "Column.as_binary: arrow_type is "
                + String(self.arrow_type)
                + ", expected binary"
            )
        if not self._offsets:
            raise Error("Column.as_binary: missing offsets buffer")

        # Copy offsets buffer
        # Migrated buffer memcpys + offset lookup onto view API.
        comptime int32_size = size_of[Int32]()
        var offsets_bytes = (self._length + 1) * int32_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(
            self._offsets.value().view_range_ro(0, offsets_bytes)
        )
        offsets_buf.set_length(Int64(offsets_bytes))


        # Get total data length from last offset
        var data_length = Int(
            self._offsets.value().get_typed[Int32](self._length)
        )

        # Copy data buffer
        var data_buf = OwnedAlignedBuffer(max(data_length, 1))
        if data_length > 0:
            data_buf.copy_from_view(self._data.view_range_ro(0, data_length))
        data_buf.set_length(Int64(data_length))


        # Copy validity bitmap if present
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm_len = self._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return BinaryArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=validity^,
            length=self._length,
            data_length=data_length,
            null_count=self._null_count,
        )

    def as_large_string(self) raises -> LargeStringArray[HeapRegion]:
        """Reconstruct a LargeStringArray[HeapRegion] view from this Column's buffers.

        Identical to `as_string()` except offsets are Int64.  Copies all
        buffer bytes.

        Raises:
            Error if the Column's arrow_type is not LARGE_STRING.
        """
        if self.arrow_type != ArrowType.LARGE_STRING:
            raise Error(
                "Column.as_large_string: arrow_type is "
                + String(self.arrow_type)
                + ", expected large_string"
            )
        if not self._offsets:
            raise Error("Column.as_large_string: missing offsets buffer")

        comptime int64_size = size_of[Int64]()
        var offsets_bytes = (self._length + 1) * int64_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(
            self._offsets.value().view_range_ro(0, offsets_bytes)
        )
        offsets_buf.set_length(Int64(offsets_bytes))


        # Total data length from last offset (Int64).
        var data_length = Int(
            self._offsets.value().get_typed[Int64](self._length)
        )

        var data_buf = OwnedAlignedBuffer(max(data_length, 1))
        if data_length > 0:
            data_buf.copy_from_view(self._data.view_range_ro(0, data_length))
        data_buf.set_length(Int64(data_length))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm_len = self._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return LargeStringArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=validity^,
            length=self._length,
            data_length=data_length,
            null_count=self._null_count,
        )

    # =========================================================================
    # OFFSET-WIDTH RESPELLING
    # =========================================================================

    def widened_to_int64_offsets(self) raises -> Column[HeapRegion]:
        """The Int64-offset respelling of this Int32-offset varlen column.

        ★ WHY THIS EXISTS. `STRING` and `LARGE_STRING` carry THE SAME VALUES;
        they differ only in the width of the offsets buffer. Every other member
        of the BYTE_ARRAY family is reachable from a decoded STRING column by a
        pure TAG SWAP (`decode_helpers._relabel_byte_array_binary`), but these
        two are not — and that function says so in its own docstring. This is
        the missing half: a RE-OFFSET, which is the only byte movement the
        respelling actually requires.

        The data buffer is copied verbatim and the validity bitmap bit-for-bit;
        only the offsets are rewritten, `Int32` -> `Int64`, value for value. So
        this is O(rows) on a buffer of 4-byte entries, not O(bytes).

        ⚠ IT IS A RESPELLING AND MAY NOT BE ANYTHING ELSE. Only the two
        transitions the Arrow spec defines a wide sibling for are accepted:

            STRING -> LARGE_STRING   (C-Data "u" -> "U")
            BINARY -> LARGE_BINARY   (C-Data "z" -> "Z")

        Anything else RAISES rather than returning `self` unchanged. A silent
        no-op here would let a caller believe it had widened a column it had
        not, and the tag/buffer disagreement that follows is exactly the class
        of defect `widen_offset_type` was written to make impossible.

        ⚠ `_offset != 0` IS REFUSED, NOT IGNORED. The width-agnostic readers
        below document that no public path builds an `_offset > 0` plain STRING
        column (`Column.slice` refuses STRING), so a non-zero one reaching here
        means an invariant broke upstream; re-offsetting from index 0 would
        silently shift every value by `_offset` rows.

        Returns:
            A new owning `Column` with the wide tag and an Int64 offsets
            buffer, carrying the same rows, values, nulls and null_count.

        Raises:
            Error if `arrow_type` has no wide sibling, if the offsets buffer is
            absent, or if `_offset` is non-zero.
        """
        var wide = widen_offset_type(self.arrow_type)
        if wide == self.arrow_type:
            raise Error(
                "Column.widened_to_int64_offsets: arrow_type "
                + String(self.arrow_type)
                + " has no Int64-offset sibling in the Arrow columnar spec"
            )
        if not self._offsets:
            raise Error(
                "Column.widened_to_int64_offsets: missing offsets buffer"
            )
        if self._offset != 0:
            raise Error(
                "Column.widened_to_int64_offsets: refusing a sliced column"
                " (_offset == "
                + String(self._offset)
                + "); re-offsetting from row 0 would shift every value"
            )

        comptime int32_size = size_of[Int32]()
        comptime int64_size = size_of[Int64]()
        var n = self._length

        # ⚠⚠ BOUNDS-CHECK THE *SOURCE* BUFFER BEFORE READING IT, AND THIS GUARD
        # WAS ADDED BECAUSE A MUTATION FOUND ITS ABSENCE. Mutation M2
        # changed the read below from `get_typed[Int32]` to
        # `get_typed[Int64]` on the same i32 buffer; the test binary
        # SEGFAULTED with no test output at all rather than failing an
        # assertion, because `get_typed` does no bounds checking and the loop
        # ran off the end of a buffer half the width it was reading.
        #
        # The crash was the mutation's, but the missing guard is REAL: an
        # offsets buffer shorter than `(n + 1) * 4` reaching here — a truncated
        # file, a decoder that set `_length` before filling offsets — would
        # OOB-read live memory instead of raising. A reader must not segfault
        # on malformed input.
        var need_offset_bytes = (n + 1) * int32_size
        var have_offset_bytes = self._offsets.value().len()
        if have_offset_bytes < need_offset_bytes:
            raise Error(
                "Column.widened_to_int64_offsets: offsets buffer holds "
                + String(have_offset_bytes)
                + " bytes, need "
                + String(need_offset_bytes)
                + " for "
                + String(n)
                + " rows at Int32 width"
            )

        # Offsets: (n + 1) entries, value for value at the wider width.
        var offsets_bytes = (n + 1) * int64_size
        var new_offsets = OwnedAlignedBuffer(offsets_bytes)
        for i in range(n + 1):
            new_offsets.set_typed[Int64](
                i, Int64(self._offsets.value().get_typed[Int32](i))
            )
        new_offsets.set_length(Int64(offsets_bytes))

        # Data: the value bytes the last offset accounts for. Read from the
        # OFFSETS rather than from `_data.len()` — a decoder is free to hand
        # back a buffer with slack past the final offset, and copying the
        # slack would make the widened column's data_length disagree with its
        # own offsets.
        var data_length = Int(
            self._offsets.value().get_typed[Int32](n)
        ) if n >= 0 else 0
        if data_length < 0:
            raise Error(
                "Column.widened_to_int64_offsets: negative final offset "
                + String(data_length)
            )
        var avail = self._data.len()
        if data_length > avail:
            raise Error(
                "Column.widened_to_int64_offsets: final offset "
                + String(data_length)
                + " exceeds the data buffer ("
                + String(avail)
                + " bytes)"
            )
        var new_data = OwnedAlignedBuffer(max(data_length, 1))
        if data_length > 0:
            new_data.copy_from_view(self._data.view_range_ro(0, data_length))
        new_data.set_length(Int64(data_length))

        # Validity: layout is identical at both offset widths.
        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm_len = self._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)
            validity = bm^

        return Column[HeapRegion](
            arrow_type=wide,
            data=new_data^,
            offsets=new_offsets^,
            validity=validity^,
            length=n,
            null_count=self._null_count,
            offset=0,
        )

    # =========================================================================
    # WIDTH-AGNOSTIC PER-ROW UTF-8 READS.
    #
    # ⚠ THESE EXIST BECAUSE THE PER-CELL RENDERERS COPIED THE WHOLE COLUMN PER
    # CELL. `plan_exec._cell` and `table_display._cell_value` both spelled a
    # single cell as `batch.column_as_string(c).get(r)` — an O(column) buffer
    # copy to read O(1) bytes, once per rendered cell. That was merely wasteful
    # on a narrow column and is UNUSABLE on a promoted one: a `large_string`
    # column exists in this tree only because it passed 2 GiB, so twenty rows
    # of `df.show()` over ten columns would have memcpy'd ~470 GB to print a
    # 20-row grid. Rendering a cell must not be O(column).
    #
    # They are also the ONE place the Int32/Int64 offset discrimination has to
    # live for the per-cell surfaces: a caller writes `utf8_value_at(r)` and
    # gets the right width, instead of an `elif at == LARGE_STRING` arm that
    # every future renderer has to remember to add.
    #
    # `_offset` IS IGNORED, DELIBERATELY AND CONSISTENTLY WITH `as_string()` /
    # `as_large_string()`, which copy `offsets[0 .. _length]` and read validity
    # from bit 0 (see `can_share_as_string`'s note: no public path builds an
    # `_offset > 0` plain STRING column, since `Column.slice` refuses STRING).
    # A divergence here would make the per-cell read disagree with the bulk
    # read on the same column, which is worse than either convention.
    # =========================================================================

    def utf8_value_at(self, row: Int) raises -> String:
        """The UTF-8 value at `row`, for a STRING or LARGE_STRING column.

        Reads the two bounding offsets at the column's own width and copies
        only that row's bytes — no full-column materialisation.

        Args:
            row: Zero-based row index.

        Returns:
            The row's value as an owned String.

        Raises:
            Error if the column is neither STRING nor LARGE_STRING, if the
            offsets buffer is absent, or if `row` is out of range.
        """
        var is_wide = self.arrow_type == ArrowType.LARGE_STRING
        if not is_wide and self.arrow_type != ArrowType.STRING:
            raise Error(
                "Column.utf8_value_at: arrow_type is "
                + String(self.arrow_type)
                + ", expected string or large_string"
            )
        if not self._offsets:
            raise Error("Column.utf8_value_at: missing offsets buffer")
        if row < 0 or row >= self._length:
            raise Error(
                "Column.utf8_value_at: row "
                + String(row)
                + " out of range [0, "
                + String(self._length)
                + ")"
            )

        var start: Int
        var end: Int
        if is_wide:
            start = Int(self._offsets.value().get_typed[Int64](row))
            end = Int(self._offsets.value().get_typed[Int64](row + 1))
        else:
            start = Int(self._offsets.value().get_typed[Int32](row))
            end = Int(self._offsets.value().get_typed[Int32](row + 1))

        var str_len = end - start
        if str_len <= 0:
            return String("")

        var scratch = List[UInt8](capacity=str_len + 1)
        self._data.view_ro().copy_to(scratch, start, str_len)
        scratch.append(UInt8(0))
        # SAFETY: `scratch` is alive across the call; the String ctor copies
        # from a NUL-terminated UTF-8 buffer. Mirrors `StringArray.get` /
        # `LargeStringArray.get` exactly — no raw pointer escapes this module.
        var result = String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())
        return result

    @always_inline
    def utf8_is_null_at(self, row: Int) -> Bool:
        """True iff `row` is null. False when the column carries no validity
        bitmap (Arrow's "no nulls" fast path), matching `StringArray.is_null`
        and `LargeStringArray.is_null`. Width-agnostic: the validity bitmap
        layout is identical for STRING and LARGE_STRING."""
        if not self._validity:
            return False
        return not self._validity.value().test(row)

    def as_large_binary(self) raises -> LargeBinaryArray[HeapRegion]:
        """Reconstruct a LargeBinaryArray[HeapRegion] view from this Column's buffers.

        Identical to `as_binary()` except offsets are Int64.  Copies all
        buffer bytes.

        Raises:
            Error if the Column's arrow_type is not LARGE_BINARY.
        """
        if self.arrow_type != ArrowType.LARGE_BINARY:
            raise Error(
                "Column.as_large_binary: arrow_type is "
                + String(self.arrow_type)
                + ", expected large_binary"
            )
        if not self._offsets:
            raise Error("Column.as_large_binary: missing offsets buffer")

        comptime int64_size = size_of[Int64]()
        var offsets_bytes = (self._length + 1) * int64_size
        var offsets_buf = OwnedAlignedBuffer(offsets_bytes)
        offsets_buf.copy_from_view(
            self._offsets.value().view_range_ro(0, offsets_bytes)
        )
        offsets_buf.set_length(Int64(offsets_bytes))


        var data_length = Int(
            self._offsets.value().get_typed[Int64](self._length)
        )

        var data_buf = OwnedAlignedBuffer(max(data_length, 1))
        if data_length > 0:
            data_buf.copy_from_view(self._data.view_range_ro(0, data_length))
        data_buf.set_length(Int64(data_length))


        var validity = Optional[Bitmap[HeapRegion]](None)
        if self._validity:
            var bm_len = self._validity.value().length
            var bm = Bitmap.create(bm_len)
            var bm_bytes = (bm_len + 7) >> 3
            if bm_bytes > 0:
                bm.buffer.copy_from_view(
                    self._validity.value().buffer.view_range_ro(0, bm_bytes)
                )
                bm.buffer.set_length(bm_bytes)

            validity = bm^

        return LargeBinaryArray[HeapRegion](
            offsets=offsets_buf^,
            data=data_buf^,
            validity=validity^,
            length=self._length,
            data_length=data_length,
            null_count=self._null_count,
        )

    def as_dictionary(self) raises -> StringDictionaryArray:
        """Reconstruct a StringDictionaryArray from this Column's buffers.

        The data is COPIED into new PrimitiveArray and StringArray instances.

        Storage layout for dictionary columns:
            _data: int32 indices buffer
            _offsets: dictionary string offsets
            _dict_data: dictionary string bytes
            _dict_size: number of unique dictionary entries

        Returns:
            A new StringDictionaryArray holding copies of the indices and
            dictionary data.

        Raises:
            Error if the Column's arrow_type is not DICTIONARY.
            Error if the dictionary data buffers are missing.
        """
        if self.arrow_type != ArrowType.DICTIONARY:
            raise Error(
                "Column.as_dictionary: arrow_type is "
                + String(self.arrow_type)
                + ", expected dictionary"
            )
        if not self._offsets:
            raise Error("Column.as_dictionary: missing dictionary offsets")
        if not self._dict_data:
            raise Error("Column.as_dictionary: missing dictionary data")

        comptime int32_size = size_of[Int32]()

        # Reconstruct indices PrimitiveArray[int32] — copy only the WINDOW
        # [_offset, _offset+_length) of the int32 CODE buffer, NOT the
        # [0, _length) prefix. `Column.slice`
        # zero-copy-slices a STRING-dict column by sharing the whole code buffer
        # and carrying `_offset > 0`; a [0,_length) copy here returns the WRONG
        # codes on a mid-stream morsel (real corruption reachable via
        # `dict_clone()` at the partition / topn output-emit sites). Mirrors
        # `as_primitive`'s window copy / `_slice_fixed_width`.
        # The dict payload (`_offsets` / `_dict_data`) is addressed by the CODE,
        # so it is copied WHOLE below — only the code buffer honors `_offset`.
        # Byte-identical on the `_offset == 0` default (non-sliced) path.
        # Migrated buffer memcpys + offset lookup onto view API.
        var idx_bytes = self._length * int32_size
        var idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
        if idx_bytes > 0:
            idx_buf.copy_from_view(
                self._data.view_range_ro(self._offset * int32_size, idx_bytes)
            )
        idx_buf.set_length(Int64(idx_bytes))


        # Rebase the validity bitmap to the window [_offset, _offset+_length) ->
        # [0, _length) and recompute the window null_count (mirror as_primitive).
        var idx_validity = Optional[Bitmap[HeapRegion]](None)
        var window_null_count = 0
        if self._validity:
            var bm = Bitmap.create(self._length)
            Bitmap.copy_bits_into(
                bm, 0, self._validity.value(), self._offset, self._length
            )
            window_null_count = self._length - bm.popcount()
            idx_validity = bm^

        var indices = PrimitiveArray[DType.int32](
            idx_buf^, self._length, idx_validity^, window_null_count, 0
        )

        # Reconstruct dictionary StringArray
        var dict_offsets_bytes = (self._dict_size + 1) * int32_size
        var dict_offsets_buf = OwnedAlignedBuffer(dict_offsets_bytes)
        dict_offsets_buf.copy_from_view(
            self._offsets.value().view_range_ro(0, dict_offsets_bytes)
        )
        dict_offsets_buf.set_length(Int64(dict_offsets_bytes))


        # Get data length from the last offset
        var dict_data_len = Int(
            self._offsets.value().get_typed[Int32](self._dict_size)
        )

        var dict_data_buf = OwnedAlignedBuffer(max(dict_data_len, 1))
        if dict_data_len > 0:
            dict_data_buf.copy_from_view(
                self._dict_data.value().view_range_ro(0, dict_data_len)
            )
        dict_data_buf.set_length(Int64(dict_data_len))


        var dictionary = StringArray(
            offsets=dict_offsets_buf^,
            data=dict_data_buf^,
            validity=Optional[Bitmap[HeapRegion]](None),
            length=self._dict_size,
            data_length=dict_data_len,
            null_count=0,
        )

        return StringDictionaryArray(indices^, dictionary^, self._length)
