# =============================================================================
# komira_core.collections -- generic collection types
# =============================================================================
#
# Slab[T: Deinitable] — the unified typed slab. Per-method
#   Movable refinement gates growth operations (append/pop/extend/...).
#   Non-Movable T (Atomic-bearing structs) uses create_prefilled(n) +
#   init_slot[init_fn](i) / get_mut_interior(idx).
#
# OwnedFd — RAII wrapper for a POSIX file descriptor. Single-owner
#   close-on-drop via OwnedPointer[Int32].
#
# DynValue[MAX_SIZE] — Type-erased inline storage for any Movable value
#   up to MAX_SIZE bytes. Used by DynAccumulator for cold-path storage.
# =============================================================================

from .batch_view import BatchView, ColView, BoolColView, batch_view_over
from .bloom_filter import BloomFilter, HashFamily, xxhash64, xxhash64_int64
from .byte_buffer import ByteBuffer, write_uleb128
from .byte_view import ByteView, ByteViewPair
from .chunk_typed import (
    ChunkTyped,
    chunk_typed_from_view,
    chunk_typed_from_view_with_sel,
)
from .column_builder import ColumnBuilder
from .dyn_value import DynValue
from .in_list_filter import IN_LIST_THRESHOLD, InListFilter
from .multi_column_builder import (
    ColumnSink,
    ColumnSlot,
    MultiColumnBuilder,
    column_slot,
)
from .owned_fd import OwnedFd
from .range_filter import RangeFilter
from .variadic_pack import VariadicElement, VariadicPack
from .selectivity_tracker import (
    BLOOM_SELECTIVITY_THRESHOLD,
    IN_LIST_SELECTIVITY_THRESHOLD,
    RANGE_SELECTIVITY_THRESHOLD,
    SelectivityTracker,
)
from .slab import Slab
from .string_column_view import (
    BinaryColumnView,
    StringColumnView,
    StringView,
)
