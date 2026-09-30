# =============================================================================
# InMemoryRegistry — singleton registry for in-memory RecordBatch sources
# =============================================================================
#
# Since LogicalPlan Scan nodes store a path string, in-memory sources need a
# way to pass the actual RecordBatch. We use a simple registry keyed by the
# path string (which doubles as a lookup name for in-memory sources).
#
# Mojo does not support module-level global vars. We use a struct with a
# static heap-allocated singleton pattern. The registry is created on first
# access and freed via clear().
#
# Also provides a scan cache for Parquet file dedup: when the same file is
# scanned multiple times within a single query (e.g., self-join in CB-20),
# the first scan is cached and subsequent scans copy from cache instead of
# re-reading from disk.
# =============================================================================

from ..arrow.schema import RecordBatch
from ..collections import Slab


struct InMemoryRegistry(Movable):
    """Registry for in-memory RecordBatch sources.

    Stores RecordBatch values in Slab (handles ownership automatically).
    The pipeline compiler looks up batches by name when executing
    Scan(SOURCE_IN_MEMORY).

    Also provides a scan cache for Parquet file dedup: when the same file is
    scanned multiple times within a single query (e.g., self-join in CB-20),
    the first scan is cached and subsequent scans copy from cache instead of
    re-reading from disk.
    """
    var _names: List[String]
    var _batches: Slab[RecordBatch]
    # Scan cache: file_path -> RecordBatch (full scan, no filter)
    var _scan_cache_paths: List[String]
    var _scan_cache_batches: Slab[RecordBatch]

    def __init__(out self):
        self._names = List[String]()
        self._batches = Slab[RecordBatch]()
        self._scan_cache_paths = List[String]()
        self._scan_cache_batches = Slab[RecordBatch]()

    def register(mut self, name: String, var batch: RecordBatch):
        """Register a RecordBatch. Ownership is transferred to the registry."""
        self._names.append(name)
        self._batches.append(batch^)

    def lookup(self, name: String) raises -> ref [self._batches._bytes] RecordBatch:
        """Look up a RecordBatch by name.

        Returns a borrow of the RecordBatch stored in the registry. Mojo's
        borrow tracker keeps `self` (and therefore `self._batches`) alive for
        the duration of the returned reference -- no raw pointer, no wildcard
        origin, no lifetime laundering. The returned origin mirrors the
        underlying Slab's `__getitem__` so lifetime composes cleanly.
        """
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._batches[i]
        raise Error("InMemoryRegistry: table not found: '" + name + "'")

    def size(self) -> Int:
        """Return the number of registered (name, batch) entries.

        Used by the scan-dedup pass to generate collision-free synthetic
        names of the form `__scan_dedup_<N>` without peeking at internal
        fields.
        """
        return len(self._names)

    def total_rows(self) -> Int:
        """Sum of `num_rows()` over every registered batch — read-only.

        The plan-prepare spine has two costs that scale with the RESIDENT DATA rather than with the plan:
        `_inline_registry_scans` deep-copies every registered batch into the
        plan, and the agg-CSE `structural_id` walk hashes those same batches'
        bytes. Both are bracketed as named serial phases, and a phase's work
        unit has to be the thing that actually scales — `size()` (entry count)
        is 2 for a two-table join whether the tables hold 150 K rows or 6 M.
        This is the denominator those brackets report.
        """
        var total = 0
        for i in range(len(self._batches)):
            total += self._batches[i].num_rows()
        return total

    def scan_cache_index(self, path: String) -> Optional[Int]:
        """Look up the index of a cached Parquet scan result by file path.

        Returns the slot index into `self._scan_cache_batches` (which can be
        accessed via the usual `__getitem__` ref-returning API) or `None`.
        Callers using this should keep the registry borrowed across the
        subsequent `[index]` read so Mojo's borrow tracker protects the slot.
        """
        for i in range(len(self._scan_cache_paths)):
            if self._scan_cache_paths[i] == path:
                return Optional[Int](i)
        return None

    def scan_cache_store(mut self, path: String, var batch: RecordBatch):
        """Cache a Parquet scan result. Ownership is transferred to the registry."""
        self._scan_cache_paths.append(path)
        self._scan_cache_batches.append(batch^)

    def merge_from(mut self, var other: InMemoryRegistry):
        """Move all entries from `other` into `self`.

        Takes ownership of `other` (caller uses `registry^`). Used by
        DataFrame.join() to merge two registries (one from each side).
        Batches are moved, not copied.
        """
        for i in range(len(other._names)):
            self._names.append(other._names[i])
        # Slab.extend has a `mut src` overload that consumes `src` in
        # place. We cannot use `extend(var src)` here because Mojo
        # forbids partial moves out of a `var struct` field.
        self._batches.extend(other._batches)
        # other is consumed and destroyed here -- Slab handles cleanup.

    def clear(mut self):
        """Free all registered batches and scan cache."""
        self._names = List[String]()
        self._batches.clear()
        self._scan_cache_paths = List[String]()
        self._scan_cache_batches.clear()
    # No __del__ needed -- compiler-synthesized destructor calls
    # Slab.__del__ which destroys all RecordBatch values.


def _make_registry() -> InMemoryRegistry:
    """Create a new empty registry. Used as module-level initialization."""
    return InMemoryRegistry()
