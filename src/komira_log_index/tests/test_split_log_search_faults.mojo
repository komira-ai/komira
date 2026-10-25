# =============================================================================
# test_split_log_search_faults.mojo
#   `SplitIndexLogSearch.scan` driven directly: the zero-timestamp window rule
#   through the real scan, and the contract that a store fault or a corrupt
#   split raises instead of becoming an empty page.
# =============================================================================
#
# Defects caught:
#   - a scan that filtered a `timestamp_ns == 0` hit by the window (the rule is
#     exercised through the real search and the real filter, not through a
#     hand-built hit);
#   - a scan that swallowed a missing split object or an undecodable split and
#     answered with a short or empty page, which an operator reads as "no such
#     line".
#
# Hermetic: `SharedInMemoryConditionalStore`, no cloud, no thread.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true

from komira_log import LogRecordView

from komira_log_index import L0BuildTask, SplitIndexLogSearch

from komira_log_query import ServiceLogQuery

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_search_catalog import (
    SearchMetastore,
    list_live_splits_across_shards_with_seq,
    make_shard_id,
    shard_manifest_prefix,
)


comptime _META_ROOT: String = "index/logs/meta"
comptime _INDEX: String = "logs"
comptime _Store = SharedInMemoryConditionalStore
comptime _Reader = SplitIndexLogSearch[_Store]

comptime _BASE_MS: Int64 = 1788307200_000  # 2026-09-02T00:00:00Z, milliseconds
comptime _NOW_NS: Int64 = 1788307200_000_000_000 * 4


def _view(var message: String, wall_ms: Int64) -> LogRecordView:
    return LogRecordView(
        UInt8(2),
        UInt16(0),
        UInt32(7),
        UInt32(3),
        UInt64(0),
        UInt64(0xABCD),
        wall_ms,
        message^,
        String("faults_test"),
        List[String](),
        List[String](),
    )


def _uuid(seq: Int) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    u[8] = UInt8(seq)
    return u^


def _publish(
    store: _Store, var message: String, wall_ms: Int64, seq: Int
) raises:
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))
    var manifest = CasManifestStore[_Store](
        store.clone(),
        shard_manifest_prefix(String(_META_ROOT), shard),
        RetryPolicy.fast_test(),
    )
    var metastore = SearchMetastore[_Store](manifest^, String(_INDEX))
    var views = List[LogRecordView]()
    views.append(_view(message^, wall_ms))
    var task = L0BuildTask[_Store](
        views^,
        store.clone(),
        metastore^,
        String(_META_ROOT),
        String(_INDEX),
        _uuid(seq),
    )
    var result = task.run()
    assert_true(result.published, "harness: the split was published")


def _reader(store: _Store) raises -> _Reader:
    return _Reader(store.clone(), String(_META_ROOT), String(_INDEX))


def _first_split_key(store: _Store) raises -> String:
    var live = list_live_splits_across_shards_with_seq(
        store, String(_META_ROOT), String(_INDEX)
    )
    assert_true(len(live) > 0, "harness: a live split exists")
    return live[0].summary.object_key.copy()


def test_01_a_zero_timestamp_hit_survives_a_window_that_excludes_zero() raises:
    var store = _Store()
    var word = String("zerotsprobeword")
    # Three records sharing the term: no timestamp (0), inside the window,
    # and after the window.
    _publish(store, String("no clock ") + word.copy(), Int64(0), 1)
    _publish(store, String("in window ") + word.copy(), _BASE_MS, 2)
    _publish(store, String("too late ") + word.copy(), _BASE_MS + 100_000, 3)
    var inside = _BASE_MS * Int64(1_000_000)

    var r = _reader(store)
    var page = r.scan(
        ServiceLogQuery(inside - Int64(1), inside + Int64(1), word.copy(), 50)
    )
    assert_equal(
        page.total_matches, 3, "1: the index matched all three records"
    )
    var saw_zero = False
    var saw_inside = False
    for i in range(len(page.hits)):
        var ts = page.hits[i].timestamp_ns
        if ts == Int64(0):
            saw_zero = True
        elif ts == inside:
            saw_inside = True
        else:
            assert_true(False, "1: a hit outside the window was kept")
    assert_true(saw_zero, "1: the zero-timestamp hit is kept, never windowed out")
    assert_true(saw_inside, "1: and the in-window hit is kept")
    assert_equal(len(page.hits), 2, "1: the late record alone was dropped")


def test_02_a_missing_split_object_raises_not_an_empty_page() raises:
    var store = _Store()
    var word = String("faultprobeword")
    _publish(store, String("fault probe ") + word.copy(), _BASE_MS, 1)
    # Sanity: the split is found while its object exists.
    var r0 = _reader(store)
    var ok = r0.scan(ServiceLogQuery(Int64(0), _NOW_NS, word.copy(), 50))
    assert_equal(len(ok.hits), 1, "2: found while the object exists")

    store.delete(Path.parse(_first_split_key(store)))
    var raised = False
    var r1 = _reader(store)
    try:
        _ = r1.scan(
            ServiceLogQuery(Int64(0), _NOW_NS, word.copy(), 50)
        )
    except:
        raised = True
    assert_true(
        raised,
        "2: a catalogued split whose object is gone raises; it does not"
        " become a page with no hits",
    )


def test_03_a_corrupt_split_raises_not_an_empty_page() raises:
    var store = _Store()
    var word = String("corruptprobeword")
    _publish(store, String("corrupt probe ") + word.copy(), _BASE_MS, 1)
    var garbage = List[UInt8]()
    for i in range(256):
        garbage.append(UInt8(i % 251))
    _ = store.put(Path.parse(_first_split_key(store)), garbage)

    var raised = False
    var r1 = _reader(store)
    try:
        _ = r1.scan(
            ServiceLogQuery(Int64(0), _NOW_NS, word.copy(), 50)
        )
    except:
        raised = True
    assert_true(
        raised,
        "3: bytes that are not a split raise; they do not become an empty page",
    )


def test_04_a_far_future_timestamp_is_published_and_found() raises:
    # wall_ms * 1e6 is above 2^62 here, which once made the split writer loop
    # forever. SIGALRM ends the process if that returns.
    _ = external_call["alarm", UInt32](UInt32(60))
    var store = _Store()
    var word = String("farfutureprobeword")
    var far = _BASE_MS * Int64(3)
    _publish(store, String("far ") + word.copy(), far, 1)
    _publish(store, String("near ") + word.copy(), _BASE_MS, 2)
    var r = _reader(store)
    var page = r.scan(
        ServiceLogQuery(Int64(0), Int64.MAX, word.copy(), 50)
    )
    _ = external_call["alarm", UInt32](UInt32(0))
    assert_equal(len(page.hits), 2, "4: both records are found")
    assert_equal(
        page.hits[0].timestamp_ns,
        far * Int64(1_000_000),
        "4: the far-future record sorts first, with its exact timestamp",
    )
    assert_equal(
        page.hits[1].timestamp_ns,
        _BASE_MS * Int64(1_000_000),
        "4: then the near one",
    )


def main() raises:
    test_01_a_zero_timestamp_hit_survives_a_window_that_excludes_zero()
    test_02_a_missing_split_object_raises_not_an_empty_page()
    test_03_a_corrupt_split_raises_not_an_empty_page()
    test_04_a_far_future_timestamp_is_published_and_found()
