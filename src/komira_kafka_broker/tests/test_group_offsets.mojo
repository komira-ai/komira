# =============================================================================
# tests/test_group_offsets.mojo
#
# Committed consumer-group offsets (group_offsets.mojo), offline, over the
# in-memory conditional-write stores of komira_objectstore.
#
# What each test proves, and the defect it catches:
#   * commit then fetch returns the offset, metadata and commit timestamp; an
#     uncommitted partition, topic or group is None, never an error; a later
#     commit replaces the earlier one; committing the same record twice leaves
#     one entry. A commit written under the wrong key, or a fetch that reads
#     another partition's key, fails here.
#   * groups, topics, partitions and clusters do not see each other's offsets,
#     including group ids that are prefixes of one another ("g1", "g10").
#   * fetch_all_for_group lists every committed (topic, partition) of one group
#     and only that group, with topics that contain "/" and partitions of
#     several digits, and skips objects under the group prefix that are not
#     offsets. It is run over the plain in-memory store, which returns every
#     key under a prefix, and over DelimiterFaithfulConditionalStore, which
#     answers a listing the way S3 does (direct children in `objects`, deeper
#     keys behind `common_prefixes`). A listing that reads only `objects` finds
#     nothing on the second.
#   * the JSON body round-trips negative numbers and a metadata string with a
#     quote and a backslash, tolerates field order, and a body with no
#     "offset" is refused.
#   * store failures are not hidden: a commit whose put raises (a failed
#     conditional write) raises and stores nothing, a fetch whose get raises
#     for any reason but "not found" raises that error rather than answering
#     None, and a failing list raises from fetch_all_for_group.
#   * a fetch error is read as "no offset" only when it says not found by a
#     token a key cannot hold: a 403 naming partition 404, 1404, topic x404 or
#     topic not_found raises.
#   * metadata with multibyte UTF-8 round-trips byte for byte.
#   * a group id holding "/" does not list another group's offsets; an empty
#     topic or a negative partition is refused at commit.
#   * two handles over one shared store see each other's commits.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_broker.group_offsets import (
    CommittedOffset,
    FetchedOffset,
    GroupOffsetStore,
    decode_offset_json,
    encode_offset_json,
)
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


def _rec(offset: Int64) -> CommittedOffset:
    return CommittedOffset(offset, String(""), Int64(1))


def _new_store() -> GroupOffsetStore[SharedInMemoryConditionalStore]:
    return GroupOffsetStore(SharedInMemoryConditionalStore(), String("test-cluster"))


# =============================================================================
# A store that fails one verb, delegating the rest to a shared in-memory store.
# =============================================================================

comptime _FAIL_NONE: Int = 0
comptime _FAIL_PUT: Int = 1
comptime _FAIL_GET: Int = 2
comptime _FAIL_GET_NOT_FOUND: Int = 3
comptime _FAIL_LIST: Int = 4
comptime _FAIL_GET_KEYED: Int = 5
comptime _FAIL_GET_KEYED_NOT_FOUND: Int = 6
comptime _FAIL_GET_STATUS_404: Int = 7


struct _FailingStore(CloneableConditionalWriteStore):
    var _inner: SharedInMemoryConditionalStore
    var _mode: Int

    def __init__(out self, var inner: SharedInMemoryConditionalStore, mode: Int):
        self._inner = inner^
        self._mode = mode

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._mode)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        if self._mode == _FAIL_LIST:
            raise Error("list failed: connection reset by peer")
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        if self._mode == _FAIL_PUT:
            raise Error(
                "put failed: precondition (412) — If-Match etag mismatch"
            )
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if self._mode == _FAIL_GET:
            raise Error("get failed: connection reset by peer")
        if self._mode == _FAIL_GET_NOT_FOUND:
            raise Error("get failed: not_found (404)")
        if self._mode == _FAIL_GET_KEYED:
            # A production-shaped error: it names the object key.
            raise Error(
                "StoreError[PERMISSION_DENIED] get s3://b/" + path.raw()
                + " status=403 denied"
            )
        if self._mode == _FAIL_GET_KEYED_NOT_FOUND:
            raise Error(
                "StoreError[NOT_FOUND] get s3://b/" + path.raw()
                + " status=404 no such key"
            )
        if self._mode == _FAIL_GET_STATUS_404:
            raise Error("get gs://b/" + path.raw() + " status=404")
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


# =============================================================================
# commit and fetch.
# =============================================================================


def test_commit_then_fetch() raises:
    var s = _new_store()
    s.commit(
        String("g1"),
        String("topic-a"),
        Int32(0),
        CommittedOffset(Int64(42), String("meta"), Int64(1000)),
    )
    var got = s.fetch(String("g1"), String("topic-a"), Int32(0))
    assert_true(Bool(got), "expected a committed offset")
    assert_equal(got.value().offset, Int64(42))
    assert_equal(got.value().metadata, "meta")
    assert_equal(got.value().commit_timestamp, Int64(1000))


def test_unknown_group_topic_and_partition_are_none() raises:
    var s = _new_store()
    s.commit(String("g1"), String("t"), Int32(0), _rec(Int64(5)))
    assert_false(Bool(s.fetch(String("g1"), String("t"), Int32(7))), "partition")
    assert_false(Bool(s.fetch(String("g1"), String("other"), Int32(0))), "topic")
    assert_false(Bool(s.fetch(String("nobody"), String("t"), Int32(0))), "group")
    var empty = _new_store()
    assert_false(Bool(empty.fetch(String("g1"), String("t"), Int32(0))), "empty")


def test_overwrite_returns_latest() raises:
    var s = _new_store()
    s.commit(String("g1"), String("t"), Int32(0), _rec(Int64(5)))
    s.commit(String("g1"), String("t"), Int32(0), _rec(Int64(99)))
    assert_equal(s.fetch(String("g1"), String("t"), Int32(0)).value().offset, Int64(99))
    # A commit may move the offset back, as a consumer that seeks does.
    s.commit(String("g1"), String("t"), Int32(0), _rec(Int64(3)))
    assert_equal(s.fetch(String("g1"), String("t"), Int32(0)).value().offset, Int64(3))


def test_repeated_commit_is_idempotent() raises:
    var s = _new_store()
    for _ in range(3):
        s.commit(
            String("g1"),
            String("t"),
            Int32(0),
            CommittedOffset(Int64(17), String("m"), Int64(55)),
        )
    var got = s.fetch(String("g1"), String("t"), Int32(0))
    assert_equal(got.value().offset, Int64(17))
    assert_equal(got.value().metadata, "m")
    assert_equal(got.value().commit_timestamp, Int64(55))
    assert_equal(len(s.fetch_all_for_group(String("g1"))), 1)
    # Fetching does not change what is stored.
    var again = s.fetch(String("g1"), String("t"), Int32(0))
    assert_equal(again.value().offset, Int64(17))


def test_negative_one_offset_is_a_value_not_absence() raises:
    var s = _new_store()
    s.commit(String("g1"), String("t"), Int32(0), _rec(Int64(-1)))
    var got = s.fetch(String("g1"), String("t"), Int32(0))
    assert_true(Bool(got), "a committed -1 is a committed offset")
    assert_equal(got.value().offset, Int64(-1))


def test_isolation_between_groups_topics_partitions() raises:
    var s = _new_store()
    s.commit(String("g1"), String("ta"), Int32(0), _rec(Int64(10)))
    s.commit(String("g1"), String("ta"), Int32(1), _rec(Int64(20)))
    s.commit(String("g1"), String("tb"), Int32(0), _rec(Int64(30)))
    s.commit(String("g2"), String("ta"), Int32(0), _rec(Int64(777)))
    assert_equal(s.fetch(String("g1"), String("ta"), Int32(0)).value().offset, Int64(10))
    assert_equal(s.fetch(String("g1"), String("ta"), Int32(1)).value().offset, Int64(20))
    assert_equal(s.fetch(String("g1"), String("tb"), Int32(0)).value().offset, Int64(30))
    assert_equal(s.fetch(String("g2"), String("ta"), Int32(0)).value().offset, Int64(777))
    assert_false(Bool(s.fetch(String("g2"), String("ta"), Int32(1))), "g2 sees g1")
    assert_false(Bool(s.fetch(String("g2"), String("tb"), Int32(0))), "g2 sees g1")


def test_clusters_do_not_see_each_other() raises:
    var inner = SharedInMemoryConditionalStore()
    var a = GroupOffsetStore(inner.clone(), String("cluster-a"))
    var b = GroupOffsetStore(inner.clone(), String("cluster-b"))
    a.commit(String("g"), String("t"), Int32(0), _rec(Int64(1)))
    assert_false(Bool(b.fetch(String("g"), String("t"), Int32(0))), "fetch")
    assert_equal(len(b.fetch_all_for_group(String("g"))), 0)
    assert_equal(len(a.fetch_all_for_group(String("g"))), 1)


def test_two_handles_over_one_store_share_commits() raises:
    var inner = SharedInMemoryConditionalStore()
    var writer = GroupOffsetStore(inner.clone(), String("c"))
    var reader = GroupOffsetStore(inner.clone(), String("c"))
    writer.commit(String("g"), String("t"), Int32(2), _rec(Int64(8)))
    assert_equal(reader.fetch(String("g"), String("t"), Int32(2)).value().offset, Int64(8))


# =============================================================================
# fetch_all_for_group.
# =============================================================================


def _assert_listing[
    S: CloneableConditionalWriteStore
](mut s: GroupOffsetStore[S]) raises:
    s.commit(String("g1"), String("alpha"), Int32(0), _rec(Int64(1)))
    s.commit(String("g1"), String("alpha"), Int32(1), _rec(Int64(2)))
    s.commit(String("g1"), String("beta"), Int32(0), _rec(Int64(3)))
    s.commit(String("g1"), String("orders/eu"), Int32(12), _rec(Int64(4)))
    # Another group, a group whose id extends this one's, must not appear.
    s.commit(String("other"), String("alpha"), Int32(0), _rec(Int64(999)))
    s.commit(String("g10"), String("alpha"), Int32(0), _rec(Int64(998)))

    var all = s.fetch_all_for_group(String("g1"))
    assert_equal(len(all), 4)
    var seen = List[Bool]()
    for _ in range(4):
        seen.append(False)
    for i in range(len(all)):
        ref f = all[i]
        if f.topic == "alpha" and f.partition == Int32(0):
            assert_equal(f.record.offset, Int64(1))
            seen[0] = True
        elif f.topic == "alpha" and f.partition == Int32(1):
            assert_equal(f.record.offset, Int64(2))
            seen[1] = True
        elif f.topic == "beta" and f.partition == Int32(0):
            assert_equal(f.record.offset, Int64(3))
            seen[2] = True
        elif f.topic == "orders/eu" and f.partition == Int32(12):
            assert_equal(f.record.offset, Int64(4))
            seen[3] = True
        else:
            raise Error(
                "unexpected entry " + f.topic + "/" + String(Int(f.partition))
            )
    for i in range(4):
        assert_true(seen[i], "missing entry " + String(i))
    assert_equal(len(s.fetch_all_for_group(String("g10"))), 1)
    assert_equal(len(s.fetch_all_for_group(String("nobody"))), 0)


def test_fetch_all_for_group_over_the_plain_store() raises:
    var s = _new_store()
    _assert_listing(s)


def test_fetch_all_for_group_over_a_delimiter_faithful_store() raises:
    var s = GroupOffsetStore(
        DelimiterFaithfulConditionalStore(), String("test-cluster")
    )
    _assert_listing(s)


def test_fetch_all_skips_objects_that_are_not_offsets() raises:
    var inner = SharedInMemoryConditionalStore()
    var s = GroupOffsetStore(inner.clone(), String("c"))
    s.commit(String("g"), String("t"), Int32(0), _rec(Int64(5)))
    var junk = List[UInt8]()
    junk.append(UInt8(ord("x")))
    var base = String("c/_meta/groups/g/offsets/")
    _ = inner.put(Path.parse(base + "README.txt"), junk)  # no .json suffix
    _ = inner.put(Path.parse(base + "t/notanumber.json"), junk)  # bad partition
    _ = inner.put(Path.parse(base + "t/.json"), junk)  # empty partition
    _ = inner.put(Path.parse(base + "loose.json"), junk)  # no topic segment
    var all = s.fetch_all_for_group(String("g"))
    assert_equal(len(all), 1)
    assert_equal(all[0].topic, "t")
    assert_equal(all[0].partition, Int32(0))


# =============================================================================
# The JSON body.
# =============================================================================


def test_json_roundtrip_negative_and_escape() raises:
    var rec = CommittedOffset(
        Int64(-1), String('with"quote\\and-backslash'), Int64(-7)
    )
    var back = decode_offset_json(encode_offset_json(rec))
    assert_equal(back.offset, Int64(-1))
    assert_equal(back.commit_timestamp, Int64(-7))
    assert_equal(back.metadata, 'with"quote\\and-backslash')


def test_json_roundtrips_multibyte_utf8_metadata() raises:
    var meta = String("café 日本\"q\"")
    var rec = CommittedOffset(Int64(1), meta.copy(), Int64(2))
    var body = encode_offset_json(rec)
    var back = decode_offset_json(body)
    assert_equal(back.metadata, meta)
    assert_equal(len(back.metadata.as_bytes()), len(meta.as_bytes()))
    # A second round trip does not grow it.
    var again = decode_offset_json(encode_offset_json(back))
    assert_equal(len(again.metadata.as_bytes()), len(meta.as_bytes()))
    # Through the store.
    var s = _new_store()
    s.commit(String("g"), String("t"), Int32(0), rec)
    assert_equal(s.fetch(String("g"), String("t"), Int32(0)).value().metadata, meta)


def test_json_body_layout() raises:
    var body = encode_offset_json(
        CommittedOffset(Int64(42), String("m"), Int64(9))
    )
    assert_equal(
        String(StringSlice(unsafe_from_utf8=Span(body))),
        '{"offset":42,"metadata":"m","commit_timestamp":9}',
    )


def test_json_decode_tolerates_field_order_and_missing_optionals() raises:
    var reordered = List[UInt8](
        '{"commit_timestamp": 5, "metadata": "x", "offset": 77}'.as_bytes()
    )
    var r1 = decode_offset_json(reordered)
    assert_equal(r1.offset, Int64(77))
    assert_equal(r1.metadata, "x")
    assert_equal(r1.commit_timestamp, Int64(5))
    var only_offset = List[UInt8]('{"offset":3}'.as_bytes())
    var r2 = decode_offset_json(only_offset)
    assert_equal(r2.offset, Int64(3))
    assert_equal(r2.metadata, "")
    assert_equal(r2.commit_timestamp, Int64(0))


def test_json_without_an_offset_is_refused() raises:
    var body = List[UInt8]('{"metadata":"x"}'.as_bytes())
    var message = String("")
    var raised = False
    try:
        var r = decode_offset_json(body)
        _ = r^
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a body with no offset was accepted")
    assert_true(message.find("malformed offset JSON") >= 0, message)


def test_committed_offset_and_fetched_offset_copy() raises:
    var f = FetchedOffset(String("t"), Int32(3), CommittedOffset(Int64(8), String("m"), Int64(2)))
    var c = f.copy()
    f.record.offset = Int64(0)
    assert_equal(c.topic, "t")
    assert_equal(c.partition, Int32(3))
    assert_equal(c.record.offset, Int64(8))
    assert_equal(c.record.metadata, "m")


# =============================================================================
# Store failures.
# =============================================================================


def test_failed_conditional_write_raises_and_stores_nothing() raises:
    var inner = SharedInMemoryConditionalStore()
    var s = GroupOffsetStore(_FailingStore(inner.clone(), _FAIL_PUT), String("c"))
    var message = String("")
    var raised = False
    try:
        s.commit(String("g"), String("t"), Int32(0), _rec(Int64(5)))
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a failed write was swallowed")
    assert_true(message.find("precondition (412)") >= 0, message)
    var reader = GroupOffsetStore(inner.clone(), String("c"))
    assert_false(Bool(reader.fetch(String("g"), String("t"), Int32(0))), "stored")


def test_fetch_raises_a_store_error_that_is_not_not_found() raises:
    var inner = SharedInMemoryConditionalStore()
    var seed = GroupOffsetStore(inner.clone(), String("c"))
    seed.commit(String("g"), String("t"), Int32(0), _rec(Int64(5)))
    var s = GroupOffsetStore(_FailingStore(inner.clone(), _FAIL_GET), String("c"))
    var message = String("")
    var raised = False
    try:
        var got = s.fetch(String("g"), String("t"), Int32(0))
        _ = got^
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a transport failure was reported as no offset")
    assert_true(message.find("connection reset by peer") >= 0, message)


def test_fetch_reads_a_not_found_error_as_no_offset() raises:
    var s = GroupOffsetStore(
        _FailingStore(SharedInMemoryConditionalStore(), _FAIL_GET_NOT_FOUND),
        String("c"),
    )
    assert_false(Bool(s.fetch(String("g"), String("t"), Int32(0))), "not found")


def _fetch_raises(topic: String, partition: Int32, mode: Int) raises -> Bool:
    var s = GroupOffsetStore(
        _FailingStore(SharedInMemoryConditionalStore(), mode), String("c")
    )
    try:
        var got = s.fetch(String("g"), topic, partition)
        _ = got^
    except:
        return True
    return False


def test_fetch_does_not_read_a_key_as_a_not_found_status() raises:
    # The error names the object key; a key that spells 404 or not_found must
    # not make a 403 look like an absent object.
    assert_true(_fetch_raises(String("t"), Int32(404), _FAIL_GET_KEYED), "404")
    assert_true(_fetch_raises(String("t"), Int32(1404), _FAIL_GET_KEYED), "1404")
    assert_true(_fetch_raises(String("x404"), Int32(0), _FAIL_GET_KEYED), "x404")
    assert_true(
        _fetch_raises(String("not_found"), Int32(0), _FAIL_GET_KEYED),
        "not_found",
    )


def test_fetch_reads_every_not_found_spelling_as_no_offset() raises:
    assert_false(_fetch_raises(String("t"), Int32(404), _FAIL_GET_KEYED_NOT_FOUND))
    assert_false(_fetch_raises(String("t"), Int32(0), _FAIL_GET_STATUS_404))


def test_group_id_with_a_slash_does_not_leak_into_another_group() raises:
    var s = _new_store()
    s.commit(String("a"), String("t"), Int32(0), _rec(Int64(1)))
    s.commit(String("a/offsets/b"), String("t"), Int32(0), _rec(Int64(2)))
    var all_a = s.fetch_all_for_group(String("a"))
    assert_equal(len(all_a), 1)
    assert_equal(all_a[0].record.offset, Int64(1))
    var all_b = s.fetch_all_for_group(String("a/offsets/b"))
    assert_equal(len(all_b), 1)
    assert_equal(all_b[0].record.offset, Int64(2))
    var got = s.fetch(String("a/offsets/b"), String("t"), Int32(0))
    assert_equal(got.value().offset, Int64(2))
    # `%` in a group id does not collide with the encoding of `/`.
    s.commit(String("p%2Fq"), String("t"), Int32(0), _rec(Int64(3)))
    s.commit(String("p/q"), String("t"), Int32(0), _rec(Int64(4)))
    assert_equal(
        s.fetch(String("p%2Fq"), String("t"), Int32(0)).value().offset,
        Int64(3),
    )
    assert_equal(
        s.fetch(String("p/q"), String("t"), Int32(0)).value().offset, Int64(4)
    )


def test_unlistable_commits_are_refused() raises:
    var s = _new_store()
    var raised = False
    try:
        s.commit(String("g"), String(""), Int32(0), _rec(Int64(1)))
    except e:
        raised = String(e).find("empty topic") >= 0
    assert_true(raised, "empty topic")
    raised = False
    try:
        s.commit(String("g"), String("t"), Int32(-1), _rec(Int64(1)))
    except e:
        raised = String(e).find("negative partition") >= 0
    assert_true(raised, "negative partition")


def test_failing_list_raises_from_fetch_all() raises:
    var s = GroupOffsetStore(
        _FailingStore(SharedInMemoryConditionalStore(), _FAIL_LIST), String("c")
    )
    var message = String("")
    var raised = False
    try:
        var all = s.fetch_all_for_group(String("g"))
        _ = all^
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a failed listing was reported as no offsets")
    assert_true(message.find("list failed") >= 0, message)


def main() raises:
    test_commit_then_fetch()
    test_unknown_group_topic_and_partition_are_none()
    test_overwrite_returns_latest()
    test_repeated_commit_is_idempotent()
    test_negative_one_offset_is_a_value_not_absence()
    test_isolation_between_groups_topics_partitions()
    test_clusters_do_not_see_each_other()
    test_two_handles_over_one_store_share_commits()
    test_fetch_all_for_group_over_the_plain_store()
    test_fetch_all_for_group_over_a_delimiter_faithful_store()
    test_fetch_all_skips_objects_that_are_not_offsets()
    test_json_roundtrip_negative_and_escape()
    test_json_body_layout()
    test_json_decode_tolerates_field_order_and_missing_optionals()
    test_json_without_an_offset_is_refused()
    test_committed_offset_and_fetched_offset_copy()
    test_failed_conditional_write_raises_and_stores_nothing()
    test_fetch_raises_a_store_error_that_is_not_not_found()
    test_fetch_reads_a_not_found_error_as_no_offset()
    test_failing_list_raises_from_fetch_all()
    test_fetch_does_not_read_a_key_as_a_not_found_status()
    test_fetch_reads_every_not_found_spelling_as_no_offset()
    test_group_id_with_a_slash_does_not_leak_into_another_group()
    test_unlistable_commits_are_refused()
    test_json_roundtrips_multibyte_utf8_metadata()
    print("test_group_offsets: ALL PASS")
