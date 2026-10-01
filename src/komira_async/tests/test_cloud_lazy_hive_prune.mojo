# =============================================================================
# test_cloud_lazy_hive_prune.mojo
# =============================================================================
# The cloud lazy-Hive prune (S3 + GCS).
#
# Two no-network seam assertions:
#
#   THE PRUNE OVER A CLOUD-SHAPED FS. A `_RecordingFs` FileSystem
#        conformer records every prefix handed to `fs.list(prefix)` and
#        returns a canned per-prefix listing. Drive
#        `PrunedHiveDiscovery.open_pruned[_RecordingFs]` over a 2-partition
#        Hive layout with a `region == us` predicate and assert that the
#        ONLY prefix `fs.list` was issued against is the targeted
#        `base/region=us/` — the `region=eu/` prefix is NEVER listed (the
#        marquee "never list pruned partitions" win, the same assertion
#        made on LocalFs, now parameterized over a NON-LocalFs
#        conformer). This proves `open_pruned`'s `fs.list(targeted_prefix)`
#        is what prunes and is FULLY FS-generic (works on any conformer,
#        including the cloud ones whose gate opens).
#
#   IN-list fan-out over the recording FS: `region IN (us, eu)` lists
#        BOTH targeted prefixes (and ONLY those two — never the base), and
#        an UN-pruned (empty-predicate) discovery lists the base ONCE.
#
# The engine GATE assertion (`pq_data_can_carry_hive[S3Fs]/[GcsFs]/[LocalFs]
# /[AzureFs]`) lives with `komira_parquet`, which owns
# `pq_data_can_carry_hive`.
#
# Tested at the DISCOVERY SEAM (no typed-read / ctx.materialize binding) —
# avoids the source-mode compile (same discipline as
# test_pruned_hive_discovery).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion
from komira_async.fs.file_system import FileSystem, WriteMode
from komira_async.fs.footer_region import FooterRegion
from komira_async.fs.shallow_dir_entry import ShallowDirEntry
from komira_async.fs.file_discovery import GlobDiscoveryOptions
from komira_async.fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrunedHiveDiscovery,
)


# =============================================================================
# A minimal FileSystem conformer that RECORDS every `list(prefix)` call.
# =============================================================================
# Models the cloud-FS shape for the prune seam: `list(prefix)` returns the
# canned leaf paths under that prefix (recursive, like S3Fs/GcsFs.list) and
# pushes the requested prefix into `_listed_prefixes`. Every other trait
# method is an unreachable stub (open_pruned only calls `fs.list`). This is
# a TEST DOUBLE — it never touches the network and has no Connector.
#
# `is_dir` returns True (open_pruned does not call it, but the trait requires
# a body). The associated File / WriteFile are trivial POD handles.


struct _MockHandle(Movable, Deinitable):
    var _id: Int

    def __init__(out self, id: Int):
        self._id = id


struct _RecordingFs(FileSystem, Movable, Deinitable):
    """A FileSystem test double that records the prefixes passed to `list`
    and replies with a canned per-prefix recursive listing. Models the cloud
    `list(key_prefix)` shape (bare keys, recursive) so the prune-at-prefix
    assertion runs over a NON-LocalFs conformer without any network."""

    comptime File = _MockHandle
    comptime WriteFile = _MockHandle
    # NOT mmap-backed (cloud shape); the lazy-Hive gate is the point.
    comptime IS_MMAP_BACKED: Bool = False
    comptime SUPPORTS_LAZY_HIVE: Bool = True

    # The full set of leaf object keys this mock "store" holds (bare keys,
    # like an S3 bucket listing).
    var _all_keys: List[String]
    # Every prefix `list` was called with, in call order (the recording).
    # Held in a length-1 `Slab[List[String]]` so the trait's `list(self)`
    # (NON-mut self, per the FileSystem contract) can append to it via the
    # blessed `get_mut_interior(0)` interior-mutability pattern — exactly the
    # shape S3Fs/GcsFs use for their lazy transport slot.
    var _listed_prefixes: Slab[List[String]]

    def __init__(out self, var all_keys: List[String]) raises:
        self._all_keys = all_keys^
        self._listed_prefixes = Slab[List[String]]()
        self._listed_prefixes.append(List[String]())

    def __init__(out self, var _all_keys: List[String], var _listed_prefixes: Slab[List[String]]):
        self._all_keys = _all_keys^
        self._listed_prefixes = _listed_prefixes^

    def clone(self) -> Self:
        # `open_pruned` NEVER clones the FS (it only calls `fs.list`), so this
        # is an unreachable trait stub. Returns a copy that shares the store
        # but carries an EMPTY recording slab (length-0) — the assertions read
        # the ORIGINAL instance's recording, not a clone's. Non-raising (the
        # empty-Slab ctor does not allocate), as the trait requires.
        return Self(_all_keys=self._all_keys.copy(), _listed_prefixes=Slab[List[String]]())

    # ---- recording accessors (read the recording from immutable self) ----
    def num_listed(self) -> Int:
        return len(self._listed_prefixes[0])

    def listed_at(self, i: Int) -> String:
        return self._listed_prefixes[0][i]

    # ---- the ONLY two functional methods open_pruned reaches ----
    def list(self, prefix: String) raises -> List[String]:
        """Record `prefix`, then return every stored key that begins with it
        (recursive, like S3Fs/GcsFs `list`)."""
        ref rec = self._listed_prefixes.get_mut_interior(0)
        rec.append(String(prefix))
        var out = List[String]()
        for i in range(len(self._all_keys)):
            if self._all_keys[i].startswith(prefix):
                out.append(self._all_keys[i].copy())
        return out^

    def is_dir(self, path: String) raises -> Bool:
        return True

    # ---- unreachable stubs (open_pruned never calls these) ----
    def list_dir_shallow(
        self, dir: String
    ) raises -> List[ShallowDirEntry]:
        # SHALLOW one-level probe primitive promoted onto the FileSystem trait.
        # `open_pruned` reaches only `fs.list` (the
        # recursive listing above), never the shallow probe, so this is an
        # unreachable conformance stub — the prune-seam assertions read the
        # `_listed_prefixes` recording from `list`, not this.
        raise Error("_RecordingFs.list_dir_shallow: unused by the prune seam")

    def open(self, path: String) raises -> Self.File:
        raise Error("_RecordingFs.open: unused by the prune seam")

    def read_at(
        self, mut file: Self.File, offset: Int64, length: Int64,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        raise Error("_RecordingFs.read_at: unused")

    def read_ranges_prefetched(
        self, mut file: Self.File, ranges: List[Tuple[Int64, Int64]],
    ) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
        raise Error("_RecordingFs.read_ranges_prefetched: unused")

    def prefetch_depth(self) -> Int:
        return 64

    def supports_random_read(self) -> Bool:
        return True

    def read_footer(self, path: String, window: Int) raises -> FooterRegion:
        raise Error("_RecordingFs.read_footer: unused")

    def file_size(self, path: String) raises -> Int:
        raise Error("_RecordingFs.file_size: unused")

    def open_write(
        self, path: String, mode: WriteMode,
    ) raises -> Self.WriteFile:
        raise Error("_RecordingFs.open_write: unused")

    def write_at(
        self, mut file: Self.WriteFile, data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("_RecordingFs.write_at: unused")

    def pwrite_at(
        self, file: Self.WriteFile, offset: Int64, data: Span[UInt8, _],
    ) raises -> Int64:
        raise Error("_RecordingFs.pwrite_at: unused")

    def close_write(self, var file: Self.WriteFile) raises -> None:
        raise Error("_RecordingFs.close_write: unused")


# =============================================================================
# Fixtures
# =============================================================================


def _hive_keys() -> List[String]:
    """A 2-partition Hive layout under base `t/region=.../`. Bare keys, like
    an S3/GCS bucket listing (the cloud `list` returns relative keys)."""
    var k = List[String]()
    k.append(String("t/region=us/part-0.parquet"))
    k.append(String("t/region=us/part-1.parquet"))
    k.append(String("t/region=eu/part-0.parquet"))
    return k^


def _region_cols() -> List[String]:
    var c = List[String]()
    c.append(String("region"))
    return c^


def _region_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.STRING)
    return t^


# =============================================================================
# the prune over a cloud-shaped FS (the marquee assertion)
# =============================================================================


def test_open_pruned_lists_only_targeted_prefix_over_cloud_fs() raises:
    """region == 'us' over the recording (cloud-shaped) FS: open_pruned issues
    fs.list against ONLY `t/region=us/`. The `t/region=eu/` prefix is NEVER
    listed (the marquee prune-at-list win, now over a NON-LocalFs conformer).
    The base `t/` is never listed either (the prefix is pinned)."""
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("region"), String("us"), ArrowType.STRING)
    )
    var p = PartitionPredicate(constraints=preds^)
    var fs = _RecordingFs(_hive_keys())

    var disc = PrunedHiveDiscovery.open_pruned(
        fs,
        String("t/"),
        _region_cols(),
        _region_types(),
        p,
        GlobDiscoveryOptions.default(),
    )

    # ---- THE PRUNE WITNESS: exactly ONE prefix listed, and it is region=us ----
    assert_equal(fs.num_listed(), 1)
    assert_equal(fs.listed_at(0), String("t/region=us/"))
    # The pruned partition prefix was NEVER handed to fs.list.
    for i in range(fs.num_listed()):
        assert_false(fs.listed_at(i) == String("t/region=eu/"))
        assert_false(fs.listed_at(i) == String("t/"))

    # ---- and the survivors are exactly the two us leaf files ----
    assert_equal(disc.num_paths(), 2)
    assert_equal(disc.path_at(0), String("t/region=us/part-0.parquet"))
    assert_equal(disc.path_at(1), String("t/region=us/part-1.parquet"))
    # partition value reconstructed = "us" for both survivors.
    var pv0 = disc.partition_values_at(0)
    assert_equal(pv0.values[0], String("us"))


def test_open_pruned_in_list_lists_both_targeted_prefixes() raises:
    """region IN (us, eu) over the recording FS: open_pruned lists BOTH
    targeted prefixes and ONLY those two — the base
    `t/` is never listed. All three leaf files survive."""
    var vals = List[String]()
    vals.append(String("us"))
    vals.append(String("eu"))
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.in_list(String("region"), vals, ArrowType.STRING))
    var p = PartitionPredicate(constraints=preds^)
    var fs = _RecordingFs(_hive_keys())

    var disc = PrunedHiveDiscovery.open_pruned(
        fs,
        String("t/"),
        _region_cols(),
        _region_types(),
        p,
        GlobDiscoveryOptions.default(),
    )

    # Exactly the two targeted prefixes were listed (order = IN-list order).
    assert_equal(fs.num_listed(), 2)
    assert_equal(fs.listed_at(0), String("t/region=us/"))
    assert_equal(fs.listed_at(1), String("t/region=eu/"))
    # Base never listed.
    for i in range(fs.num_listed()):
        assert_false(fs.listed_at(i) == String("t/"))
    assert_equal(disc.num_paths(), 3)


def test_open_pruned_empty_predicate_lists_base_once() raises:
    """No predicate -> the un-pruned shape: the base `t/` is listed ONCE
    (everything under it) and all three files survive. Confirms the recording
    FS + open_pruned compose for the degenerate (no-prune) case too."""
    var p = PartitionPredicate.empty()
    var fs = _RecordingFs(_hive_keys())

    var disc = PrunedHiveDiscovery.open_pruned(
        fs,
        String("t/"),
        _region_cols(),
        _region_types(),
        p,
        GlobDiscoveryOptions.default(),
    )

    assert_equal(fs.num_listed(), 1)
    assert_equal(fs.listed_at(0), String("t/"))
    assert_equal(disc.num_paths(), 3)


def main() raises:
    var suite = TestSuite()
    suite.test[test_open_pruned_lists_only_targeted_prefix_over_cloud_fs]()
    suite.test[test_open_pruned_in_list_lists_both_targeted_prefixes]()
    suite.test[test_open_pruned_empty_predicate_lists_base_once]()
    suite^.run()
