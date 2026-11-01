# =============================================================================
# test_raw_store.mojo -- RawStore on an in-memory conditional-write store.
# =============================================================================
#
#   once per hash   the same bytes put under two surface tags are one record: the
#                   second put reports it was not created, writes nothing and
#                   leaves the first record's tag and time; different bytes are
#                   two records; the key is the hash of the bytes, whatever the
#                   tag or the time.
#   read back       a payload (NUL and non-UTF-8 bytes included) comes back byte
#                   for byte with its tag and time, through the same handle and a
#                   second handle on the same data; an absent key is "no record",
#                   a malformed key is refused; two prefixes are two stores.
#   listing         list_hashes returns every key ascending, whatever order they
#                   were put in; an object not named like a record is reported.
#   conflicts       a write that loses to another writer's record of the same
#                   bytes is reported as not created and the rival's record
#                   stays; a record of other bytes under the same key is refused
#                   by put and never replaced; a store failure is raised and is
#                   never read as a lost race or as "absent".
#   damage          an object that does not decode, or whose payload does not
#                   hash to its name, is refused on read.
# No test reads a clock or the environment.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg_sources import (
    RawRecord,
    RawStore,
    check_same_payload,
    encode_raw_record,
    raw_content_hash,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

comptime Mem = SharedInMemoryConditionalStore


struct _Faults(Movable):
    """What the double does wrong; shared so a test can arm it after the move."""

    var races: Int
    var rival_body: List[UInt8]
    var head_fails: Bool
    var get_fails: Bool
    var put_fails: Bool

    def __init__(out self):
        self.races = 0
        self.rival_body = List[UInt8]()
        self.head_fails = False
        self.get_fails = False
        self.put_fails = False


struct _FaultyStore(ConditionalWriteStore):
    """An in-memory store that can lose a race on purpose: before a conditional
    write it commits `rival_body` at the same path, so the write finds the object
    there. It can also fail `head`, `get` and `conditional_put` outright."""

    var inner: Mem
    var faults: ArcPointer[_Faults]

    def __init__(out self, var inner: Mem, var faults: ArcPointer[_Faults]):
        self.inner = inner^
        self.faults = faults^

    def head(self, path: Path) raises -> ObjectMeta:
        if self.faults[].head_fails:
            raise Error("transport reset by peer")
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if self.faults[].put_fails:
            raise Error("disk full")
        if self.faults[].races > 0:
            self.faults[].races -= 1
            _ = self.inner.put(path, self.faults[].rival_body.copy())
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if self.faults[].get_fails:
            raise Error("connection refused")
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _bytes(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def _store() raises -> RawStore[Mem]:
    return RawStore[Mem](Mem(), String("lake"))


def _object_path(key: String) raises -> Path:
    return Path.parse("lake/raw/" + key + ".rawrec")


def test_the_same_bytes_under_two_tags_are_one_record() raises:
    var rs = _store()
    var payload = _bytes([1, 2, 3, 4])
    var first = rs.put("kind-a", payload, Int64(100))
    assert_true(first.created)
    var second = rs.put("kind-b", payload, Int64(200))
    assert_false(second.created)
    assert_equal(second.content_hash, first.content_hash)
    var keys = rs.list_hashes()
    assert_equal(len(keys), 1)
    assert_equal(keys[0], first.content_hash)
    var rec = rs.get(first.content_hash)
    assert_equal(rec.surface_tag, "kind-a")
    assert_equal(rec.received_at, Int64(100))


def test_the_key_is_the_hash_of_the_bytes_whatever_the_tag_or_time() raises:
    var rs = _store()
    var payload = _bytes([9, 8, 7])
    var put = rs.put("kind-z", payload, Int64(5))
    assert_equal(put.content_hash, raw_content_hash(payload))
    var other = rs.put("kind-z", _bytes([9, 8, 6]), Int64(5))
    assert_true(other.created)
    assert_true(other.content_hash != put.content_hash)
    assert_equal(len(rs.list_hashes()), 2)


def test_a_payload_reads_back_byte_for_byte() raises:
    var rs = _store()
    var payload = _bytes([0, 255, 0, 200, 10, 0xC3, 0x28, 0])
    var put = rs.put("kind-a", payload, Int64(-9))
    var rec = rs.get(put.content_hash)
    assert_equal(rec.surface_tag, "kind-a")
    assert_equal(rec.received_at, Int64(-9))
    assert_equal(len(rec.payload), len(payload))
    for i in range(len(payload)):
        assert_equal(rec.payload[i], payload[i])
    assert_equal(rec.content_hash(), put.content_hash)
    assert_true(rs.has(put.content_hash))
    var found = rs.find(put.content_hash)
    assert_true(Bool(found))
    assert_equal(found.value().surface_tag, "kind-a")
    assert_equal(rs.prefix(), "lake")


def test_an_empty_payload_is_a_record() raises:
    var rs = _store()
    var put = rs.put("kind-a", List[UInt8](), Int64(1))
    assert_true(put.created)
    assert_equal(len(rs.get(put.content_hash).payload), 0)


def test_a_second_handle_on_the_same_data_sees_the_record() raises:
    var data = Mem()
    var writer = RawStore[Mem](data.clone(), String("lake"))
    var put = writer.put("kind-a", _bytes([4, 5]), Int64(3))
    var reader = RawStore[Mem](data.clone(), String("lake"))
    assert_true(reader.has(put.content_hash))
    assert_equal(reader.get(put.content_hash).surface_tag, "kind-a")
    assert_false(reader.put("kind-b", _bytes([4, 5]), Int64(4)).created)


def test_two_prefixes_are_two_stores() raises:
    var data = Mem()
    var a = RawStore[Mem](data.clone(), String("lake-a"))
    var b = RawStore[Mem](data.clone(), String("lake-b"))
    var put = a.put("kind-a", _bytes([1]), Int64(1))
    assert_false(b.has(put.content_hash))
    assert_equal(len(b.list_hashes()), 0)
    assert_true(b.put("kind-a", _bytes([1]), Int64(1)).created)


def test_an_absent_key_is_no_record_and_a_malformed_key_is_refused() raises:
    var rs = _store()
    var absent = "0123456789abcdef"
    assert_false(rs.has(absent))
    assert_false(Bool(rs.find(absent)))
    with assert_raises(contains="no record is stored under 0123456789abcdef"):
        _ = rs.get(absent)
    with assert_raises(contains="'nope' is not a content hash"):
        _ = rs.has("nope")
    with assert_raises(contains="'0123456789ABCDEF' is not a content hash"):
        _ = rs.find("0123456789ABCDEF")


def test_a_tag_that_cannot_be_stored_writes_nothing() raises:
    var rs = _store()
    with assert_raises(contains="surface tag must not be empty"):
        _ = rs.put("", _bytes([1]), Int64(1))
    assert_equal(len(rs.list_hashes()), 0)


def test_a_prefix_that_cannot_be_used_is_refused() raises:
    with assert_raises(contains="raw store prefix must not be empty"):
        _ = RawStore[Mem](Mem(), String(""))
    with assert_raises(contains="raw store prefix must not start or end with '/'"):
        _ = RawStore[Mem](Mem(), String("/lake"))


def test_keys_list_ascending_whatever_the_order_they_were_put_in() raises:
    var rs = _store()
    var want = List[String]()
    for i in range(6):
        want.append(rs.put("kind-a", _bytes([i, 7, 7]), Int64(i)).content_hash)
    var got = rs.list_hashes()
    assert_equal(len(got), 6)
    for i in range(5):
        assert_true(got[i] < got[i + 1])
    for i in range(6):
        var seen = False
        for j in range(6):
            if got[j] == want[i]:
                seen = True
        assert_true(seen)


def test_an_object_not_named_like_a_record_is_reported() raises:
    var data = Mem()
    var rs = RawStore[Mem](data.clone(), String("lake"))
    _ = rs.put("kind-a", _bytes([1]), Int64(1))
    _ = data.put(Path.parse("lake/raw/stray.txt"), _bytes([1]))
    with assert_raises(contains="'lake/raw/stray.txt' is not a raw record name"):
        _ = rs.list_hashes()


def test_a_write_that_loses_to_the_same_bytes_is_not_created_and_the_rival_stays() raises:
    var data = Mem()
    var faults = ArcPointer[_Faults](_Faults())
    var rs = RawStore[_FaultyStore](_FaultyStore(data.clone(), faults.copy()), String("lake"))
    var payload = _bytes([6, 6, 6])
    faults[].races = 1
    faults[].rival_body = encode_raw_record(RawRecord("rival", Int64(42), payload.copy()))
    var put = rs.put("mine", payload, Int64(1))
    assert_false(put.created)
    var rec = rs.get(put.content_hash)
    assert_equal(rec.surface_tag, "rival")
    assert_equal(rec.received_at, Int64(42))


def test_a_write_that_loses_to_other_bytes_is_refused_and_the_rival_stays() raises:
    var data = Mem()
    var faults = ArcPointer[_Faults](_Faults())
    var rs = RawStore[_FaultyStore](_FaultyStore(data.clone(), faults.copy()), String("lake"))
    var payload = _bytes([6, 6, 6])
    var key = raw_content_hash(payload)
    var rival = encode_raw_record(RawRecord("rival", Int64(42), _bytes([1, 1])))
    faults[].races = 1
    faults[].rival_body = rival.copy()
    with assert_raises(contains="hashes to"):
        _ = rs.put("mine", payload, Int64(1))
    var stored = data.get(_object_path(key))
    assert_equal(len(stored), len(rival))
    for i in range(len(rival)):
        assert_equal(stored[i], rival[i])


def test_a_stored_record_of_other_bytes_under_one_hash_is_a_collision() raises:
    var key = raw_content_hash(_bytes([1, 2]))
    var held = RawRecord("t", Int64(1), _bytes([1, 2]))
    check_same_payload(held, _bytes([1, 2]), key)
    with assert_raises(contains="a record with different bytes is already stored under " + key):
        check_same_payload(held, _bytes([1, 3]), key)
    with assert_raises(contains="(a hash collision); refusing to replace it"):
        check_same_payload(held, _bytes([1]), key)


def test_a_store_failure_is_raised_not_read_as_a_race_or_as_absent() raises:
    var faults = ArcPointer[_Faults](_Faults())
    var rs = RawStore[_FaultyStore](_FaultyStore(Mem(), faults.copy()), String("lake"))
    var put = rs.put("kind-a", _bytes([1]), Int64(1))
    faults[].put_fails = True
    with assert_raises(contains="disk full"):
        _ = rs.put("kind-a", _bytes([2]), Int64(1))
    faults[].put_fails = False
    faults[].head_fails = True
    with assert_raises(contains="transport reset by peer"):
        _ = rs.has(put.content_hash)
    faults[].head_fails = False
    faults[].get_fails = True
    with assert_raises(contains="connection refused"):
        _ = rs.find(put.content_hash)
    faults[].get_fails = False
    assert_equal(len(rs.list_hashes()), 1)


def test_an_object_that_does_not_decode_is_refused() raises:
    var data = Mem()
    var rs = RawStore[Mem](data.clone(), String("lake"))
    var key = "0123456789abcdef"
    _ = data.put(_object_path(key), _bytes([1, 2, 3]))
    with assert_raises(contains="RawStore: "):
        _ = rs.get(key)


def test_an_object_whose_payload_does_not_hash_to_its_name_is_refused() raises:
    var data = Mem()
    var rs = RawStore[Mem](data.clone(), String("lake"))
    var key = "0123456789abcdef"
    var body = encode_raw_record(RawRecord("t", Int64(1), _bytes([1, 2])))
    _ = data.put(_object_path(key), body^)
    with assert_raises(contains="holds a payload that hashes to " + raw_content_hash(_bytes([1, 2]))):
        _ = rs.get(key)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
