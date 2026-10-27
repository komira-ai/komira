# =============================================================================
# komira_telemetry_read/tests/test_telemetry_scan_backends.mojo
#   The same plan on two object-store behaviours that disagree about listing, so
#   writer-shard discovery cannot depend on either.
# =============================================================================
#
# What each case would catch if it were wrong:
#   7   shard discovery that needs `common_prefixes` (a local-filesystem store
#       never populates it) finds zero shards and reports an empty bucket.
#   7b  shard discovery that reads `objects` alone (a delimiter-faithful store
#       hides nested keys behind a rollup) finds zero shards, silently.
#
# Both backends are exercised for real: the local-filesystem store writes under
# the build's private test temp directory, the other is an in-memory store with
# object-store delimiter semantics. LIST fidelity is the point, so neither is
# replaced by the plain in-memory store.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_shard_keys import shard_manifest_prefix

from komira_telemetry_store.keys import (
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    telemetry_data_key,
    telemetry_partition_prefix,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TelemetrySegmentEntry,
    encode_telemetry_segment_entry,
    make_raw_segment_entry,
)
from komira_runtime_paths import test_tmpdir

from komira_telemetry_read.scan_plan import plan_telemetry_scan

# 2026-09-15T00:00:00Z in nanoseconds. Every timestamp below is this plus an
# offset, so the cases are clock-independent and the day boundary is exact.
comptime _SEP15: Int64 = 1789430400_000_000_000
comptime _HOUR: Int64 = 3_600_000_000_000
comptime _DAY: Int64 = 86_400_000_000_000


# ---------------------------------------------------------------------------
# Fixture writer. It publishes catalog entries by hand: a catalog entry plus a
# placeholder object body, the smallest thing that exercises the planner. The
# decode is exercised against REAL Parquet bytes in
# test_telemetry_segment_read.mojo, where the writer in komira_telemetry_store
# produces the objects.
# ---------------------------------------------------------------------------


def _uuid16(seed: Int) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 37 + i * 11) % 256)
    return u^


def _lineage(day: String, writer_id: String) raises -> String:
    return shard_manifest_prefix(
        telemetry_partition_prefix(
            String(TELEMETRY_ROOT), String(TELEMETRY_DATASET_LOGS), day
        ),
        writer_id,
    )


def _data_key(day: String, seed: Int, min_ts: Int64) raises -> String:
    return telemetry_data_key(
        String(TELEMETRY_ROOT),
        String(TELEMETRY_DATASET_LOGS),
        day,
        min_ts // Int64(1_000_000),
        _uuid16(seed),
    )


def _append[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage, day: String, writer_id: String, var entry: TelemetrySegmentEntry
) raises:
    """Append one entry through a FRESH manifest handle, which keeps the durable
    `_HEAD` caught up with the tail."""
    var manifest = CasManifestStore[Storage](
        storage.clone(), _lineage(day, writer_id), RetryPolicy.fast_test()
    )
    _ = manifest.append(encode_telemetry_segment_entry(entry), Int64(1))


def _publish_segment[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    day: String,
    writer_id: String,
    seed: Int,
    min_ts: Int64,
    max_ts: Int64,
    var body: String,
) raises -> String:
    """Write one data object and append its catalog entry. Returns the key."""
    var key = _data_key(day, seed, min_ts)
    var bytes = List[UInt8]()
    var b = body.as_bytes()
    for i in range(len(b)):
        bytes.append(b[i])
    _ = storage.put(Path.parse(key), bytes^)
    var entry = make_raw_segment_entry(
        key.copy(),
        min_ts,
        max_ts,
        Int64(1),
        Int64(body.byte_length()),
        _uuid16(seed),
    )
    _append(storage, day, writer_id, entry^)
    return key^


def _has_key(keys: List[String], want: String) -> Bool:
    for i in range(len(keys)):
        if keys[i] == want:
            return True
    return False


def _unique() -> String:
    """A per-call hex nonce, so a second run in the same scratch directory does
    not re-open a directory an earlier run wrote."""
    var x = UInt64(perf_counter_ns())
    x ^= x >> UInt64(33)
    x *= UInt64(0xFF51AFD7ED558CCD)
    x ^= x >> UInt64(33)
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((x >> UInt64(shift)) & UInt64(0xF))
        if nib < 10:
            out += chr(0x30 + nib)
        else:
            out += chr(0x61 + nib - 10)
        shift -= 4
    return out^


# =============================================================================
# CASE 7 - THE SAME PLAN ON A BACKEND THAT NEVER POPULATES `common_prefixes`.
#
# The hazard is silent in both directions. `LocalFsConditionalStore` returns
# nested keys as OBJECTS and always an empty `common_prefixes`, while a cloud
# store and `DelimiterFaithfulConditionalStore` populate it and hide nested keys
# behind a rollup. A discovery that DEPENDS on either behaviour works on exactly
# one backend and returns silence on the other. `_discover_shard_ids` folds the
# UNION, which is why the same code answers both.
#
# The scratch root comes from the build's private test temp directory, and is
# unique per run: `LocalFsConditionalStore` re-opens an existing directory
# (deliberately, so a relaunch re-opens what it wrote), so a fixed path would
# accumulate one more catalog entry per re-run.
# =============================================================================
def test_07_the_same_plan_holds_on_a_backend_with_no_common_prefixes() raises:
    var root = (
        test_tmpdir() + String("/komira_telemetry_scan_plan_case7_")
    ) + _unique()
    var store = LocalFsConditionalStore(root.copy())
    var w = String("writer-a")
    var k14 = _publish_segment(
        store, String("20260914"), w, 21, _SEP15 - _DAY,
        _SEP15 - _DAY + _HOUR, String("day14"),
    )
    var k15 = _publish_segment(
        store, String("20260915"), w, 22, _SEP15, _SEP15 + _HOUR, String("day15"),
    )

    var plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _SEP15, _SEP15 + _HOUR
    )
    var keys = plan.object_keys()
    assert_equal(
        len(keys),
        1,
        "7: shard discovery works on a backend whose `common_prefixes` is"
        " ALWAYS EMPTY: a descent that depended on it would find ZERO shards"
        " here and report an empty bucket",
    )
    assert_equal(keys[0], k15, "7: and it is the right object")
    assert_false(_has_key(keys, k14), "7: the other day still prunes")
    assert_equal(
        plan.shards_replayed, 1, "7: exactly one writer shard was discovered"
    )


# =============================================================================
# CASE 7b - THE OTHER HALF OF THE UNION FOLD: a backend that HONOURS the
# delimiter, returning each `<shard_id>/` as a `common_prefix` and HIDING the
# nested keys behind that rollup.
#
# Case 7 alone is not discriminating: `SharedInMemoryConditionalStore` also
# returns an empty `common_prefixes`, so every other case already covers the
# "objects-derived" half of the fold. On a delimiter-faithful backend a
# discovery that derived shard ids from `objects` alone finds ZERO shards and
# reports an empty bucket, silently. Cases 7 and 7b together make the union fold
# load-bearing: neither half alone can fail.
# =============================================================================
def test_07b_the_same_plan_holds_on_a_delimiter_faithful_backend() raises:
    var store = DelimiterFaithfulConditionalStore()
    var w = String("writer-a")
    var k14 = _publish_segment(
        store, String("20260914"), w, 71, _SEP15 - _DAY,
        _SEP15 - _DAY + _HOUR, String("day14"),
    )
    var k15 = _publish_segment(
        store, String("20260915"), w, 72, _SEP15, _SEP15 + _HOUR, String("day15"),
    )

    var plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _SEP15, _SEP15 + _HOUR
    )
    var keys = plan.object_keys()
    assert_equal(
        len(keys),
        1,
        "7b: shard discovery works on a backend that HONOURS the delimiter and"
        " hides nested keys behind a `<shard_id>/` rollup",
    )
    assert_equal(keys[0], k15, "7b: and it is the right object")
    assert_false(_has_key(keys, k14), "7b: the other day still prunes")
    assert_equal(
        plan.shards_replayed, 1, "7b: exactly one writer shard was discovered"
    )
    assert_equal(
        plan.entries_replayed,
        1,
        "7b: and its catalog really was replayed: a zero here would mean the"
        " shard was found but its manifest was not read, which len(keys)==0"
        " alone cannot distinguish",
    )


def main() raises:
    test_07_the_same_plan_holds_on_a_backend_with_no_common_prefixes()
    test_07b_the_same_plan_holds_on_a_delimiter_faithful_backend()
    print("test_telemetry_scan_backends: OK")
