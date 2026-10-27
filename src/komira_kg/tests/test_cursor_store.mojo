# =============================================================================
# test_cursor_store.mojo -- CursorStore on an in-memory conditional-write store.
# =============================================================================
#
#   write and read  a saved cursor reads back field for field, through the same
#                   handle and through a second handle on the same data; a second
#                   save replaces the first; an absent cursor loads unseeded.
#   keys            a cursor belongs to its (partition id, source key) pair, and
#                   pairs that concatenate to the same text stay apart.
#   conflicts       of two writers that read the same version, the first write
#                   lands and the second is reported as lost and changes nothing;
#                   a write quoting a stale version, or "create" over an existing
#                   cursor, is lost the same way; a lost writer can read again and
#                   then write.
#   bounded retries save retries a lost race and succeeds when a later attempt
#                   wins; it raises, with the rival's cursor in place, when every
#                   attempt loses; it refuses fewer than one attempt.
#   failures        a store error is raised and is never read as "no cursor" or as
#                   a lost race.
#   stored objects  an object that does not decode, or that holds another pair's
#                   cursor, is refused on read and on list; an object that is not
#                   a cursor object is skipped by list; an over-size field is
#                   refused before anything is written.
# No test reads a clock or the environment.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg import CursorStore, SurfaceCursor, encode_cursor
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


struct _Faults(Movable):
    """What the double does wrong; shared so a test can arm it after the move."""

    var races: Int
    var rival_body: List[UInt8]
    var head_fails: Bool
    var put_fails: Bool

    def __init__(out self):
        self.races = 0
        self.rival_body = List[UInt8]()
        self.head_fails = False
        self.put_fails = False


struct _FaultyStore(ConditionalWriteStore):
    """An in-memory store that can lose a race on purpose: before a conditional
    write it commits `rival_body` at the same path, so the write's version is
    stale. It can also fail `head` and `conditional_put` outright."""

    var inner: SharedInMemoryConditionalStore
    var faults: ArcPointer[_Faults]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var faults: ArcPointer[_Faults],
    ):
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
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _cursor(
    partition: String, source: String, token: String, mark: Int, at: Int
) -> SurfaceCursor:
    return SurfaceCursor(partition, source, token, Int64(mark), Int64(at))


def _store() -> CursorStore[SharedInMemoryConditionalStore]:
    return CursorStore[SharedInMemoryConditionalStore](
        SharedInMemoryConditionalStore(), String("state")
    )


def _locations(store: SharedInMemoryConditionalStore) raises -> List[String]:
    var listing = store.list_with_delimiter(Path.parse("state/cursor/"))
    var out = List[String]()
    for i in range(len(listing.objects)):
        out.append(listing.objects[i].location)
    return out^


def test_a_saved_cursor_reads_back_field_for_field() raises:
    var cs = _store()
    cs.save(_cursor("p1", "feed", "tok-1", 1700, 1800), 3)
    var got = cs.load("p1", "feed")
    assert_equal(got.partition_id, "p1")
    assert_equal(got.source_key, "feed")
    assert_equal(got.token, "tok-1")
    assert_equal(got.watermark, Int64(1700))
    assert_equal(got.synced_at, Int64(1800))
    assert_true(got.is_seeded())
    var r = cs.read("p1", "feed")
    assert_true(r.found)
    assert_true(len(r.version.as_bytes()) > 0)
    assert_true(cs.has("p1", "feed"))
    assert_equal(cs.prefix(), "state")


def test_a_cursor_survives_a_second_handle_on_the_same_data() raises:
    var data = SharedInMemoryConditionalStore()
    var writer = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    writer.save(_cursor("p1", "feed", "tok", 5, 6), 3)
    var reader = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    var got = reader.load("p1", "feed")
    assert_equal(got.token, "tok")
    assert_equal(got.watermark, Int64(5))
    assert_equal(got.synced_at, Int64(6))


def test_a_second_save_replaces_the_first() raises:
    var cs = _store()
    cs.save(_cursor("p1", "feed", "old", 1, 1), 3)
    cs.save(_cursor("p1", "feed", "new", 2, 2), 3)
    var got = cs.load("p1", "feed")
    assert_equal(got.token, "new")
    assert_equal(got.watermark, Int64(2))
    assert_equal(len(cs.list_cursors()), 1)


def test_an_absent_cursor_loads_unseeded() raises:
    var cs = _store()
    var got = cs.load("p1", "feed")
    assert_equal(got.partition_id, "p1")
    assert_equal(got.source_key, "feed")
    assert_equal(got.token, "")
    assert_equal(got.watermark, Int64(0))
    assert_equal(got.synced_at, Int64(0))
    assert_false(got.is_seeded())
    assert_false(cs.has("p1", "feed"))
    var r = cs.read("p1", "feed")
    assert_false(r.found)
    assert_equal(r.version, "")


def test_a_cursor_belongs_to_its_partition_and_source() raises:
    var cs = _store()
    cs.save(_cursor("p1", "feed", "a", 1, 0), 3)
    cs.save(_cursor("p2", "feed", "b", 2, 0), 3)
    cs.save(_cursor("p1", "other", "c", 3, 0), 3)
    # These two pairs concatenate to the same text.
    cs.save(_cursor("ab", "c", "d", 4, 0), 3)
    cs.save(_cursor("a", "bc", "e", 5, 0), 3)
    assert_equal(cs.load("p1", "feed").token, "a")
    assert_equal(cs.load("p2", "feed").token, "b")
    assert_equal(cs.load("p1", "other").token, "c")
    assert_equal(cs.load("ab", "c").token, "d")
    assert_equal(cs.load("a", "bc").token, "e")
    assert_equal(len(cs.list_cursors()), 5)
    assert_false(cs.has("p2", "other"))


def test_of_two_writers_that_read_the_same_version_the_second_loses() raises:
    var data = SharedInMemoryConditionalStore()
    var a = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    var b = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    a.save(_cursor("p", "feed", "base", 1, 1), 3)
    var seen_by_a = a.read("p", "feed")
    var seen_by_b = b.read("p", "feed")
    assert_equal(seen_by_a.version, seen_by_b.version)
    assert_true(a.try_save(_cursor("p", "feed", "from-a", 2, 2), seen_by_a.version))
    assert_false(b.try_save(_cursor("p", "feed", "from-b", 3, 3), seen_by_b.version))
    var now = b.load("p", "feed")
    assert_equal(now.token, "from-a")
    assert_equal(now.watermark, Int64(2))
    # The loser reads again and then lands.
    var again = b.read("p", "feed")
    assert_true(b.try_save(_cursor("p", "feed", "from-b", 3, 3), again.version))
    assert_equal(a.load("p", "feed").token, "from-b")


def test_create_loses_to_an_existing_cursor() raises:
    var cs = _store()
    assert_true(cs.try_save(_cursor("p", "feed", "first", 1, 1), String("")))
    assert_false(cs.try_save(_cursor("p", "feed", "second", 2, 2), String("")))
    assert_equal(cs.load("p", "feed").token, "first")


def test_a_stale_version_loses_and_changes_nothing() raises:
    var cs = _store()
    cs.save(_cursor("p", "feed", "v1", 1, 1), 3)
    var stale = cs.read("p", "feed").version
    cs.save(_cursor("p", "feed", "v2", 2, 2), 3)
    assert_false(cs.try_save(_cursor("p", "feed", "v3", 3, 3), stale))
    assert_equal(cs.load("p", "feed").token, "v2")
    var fresh = cs.read("p", "feed").version
    assert_true(cs.try_save(_cursor("p", "feed", "v3", 3, 3), fresh))
    assert_equal(cs.load("p", "feed").token, "v3")


def test_a_write_with_a_version_over_an_absent_cursor_loses() raises:
    var cs = _store()
    assert_false(cs.try_save(_cursor("p", "feed", "x", 1, 1), String("etag-1")))
    assert_false(cs.has("p", "feed"))


struct _Rig(Movable):
    var store: CursorStore[_FaultyStore]
    var faults: ArcPointer[_Faults]

    def __init__(
        out self,
        var store: CursorStore[_FaultyStore],
        var faults: ArcPointer[_Faults],
    ):
        self.store = store^
        self.faults = faults^


def _faulty(races: Int, rival: SurfaceCursor) raises -> _Rig:
    var faults = ArcPointer[_Faults](_Faults())
    faults[].races = races
    faults[].rival_body = encode_cursor(rival)
    var cs = CursorStore[_FaultyStore](
        _FaultyStore(SharedInMemoryConditionalStore(), faults.copy()),
        String("state"),
    )
    return _Rig(cs^, faults^)


def test_save_retries_a_lost_race_and_lands_on_a_later_attempt() raises:
    var rival = _cursor("p", "feed", "rival", 9, 9)
    var rig = _faulty(2, rival)
    ref cs = rig.store
    cs.save(_cursor("p", "feed", "mine", 1, 1), 3)
    assert_equal(cs.load("p", "feed").token, "mine")


def test_save_raises_when_every_attempt_loses() raises:
    var rival = _cursor("p", "feed", "rival", 9, 9)
    var rig = _faulty(2, rival)
    ref cs = rig.store
    with assert_raises(contains="lost the compare-and-set race on all 2 attempts"):
        cs.save(_cursor("p", "feed", "mine", 1, 1), 2)
    var now = cs.load("p", "feed")
    assert_equal(now.token, "rival")
    assert_equal(now.watermark, Int64(9))


def test_save_needs_at_least_one_attempt() raises:
    var cs = _store()
    with assert_raises(contains="at least one attempt"):
        cs.save(_cursor("p", "feed", "x", 1, 1), 0)
    with assert_raises(contains="at least one attempt"):
        cs.save(_cursor("p", "feed", "x", 1, 1), -1)
    assert_false(cs.has("p", "feed"))


def test_a_failed_read_is_not_read_as_no_cursor() raises:
    var rig = _faulty(0, _cursor("p", "feed", "rival", 9, 9))
    ref cs = rig.store
    cs.save(_cursor("p", "feed", "mine", 1, 1), 3)
    rig.faults[].head_fails = True
    with assert_raises(contains="transport reset"):
        _ = cs.load("p", "feed")
    with assert_raises(contains="transport reset"):
        _ = cs.has("p", "feed")
    with assert_raises(contains="transport reset"):
        cs.save(_cursor("p", "feed", "again", 2, 2), 3)


def test_a_failed_write_is_raised_and_not_reported_as_a_lost_race() raises:
    var rig = _faulty(0, _cursor("p", "feed", "rival", 9, 9))
    ref cs = rig.store
    rig.faults[].put_fails = True
    with assert_raises(contains="disk full"):
        _ = cs.try_save(_cursor("p", "feed", "x", 1, 1), String(""))
    with assert_raises(contains="disk full"):
        cs.save(_cursor("p", "feed", "x", 1, 1), 3)


def test_an_object_that_does_not_decode_is_refused() raises:
    var data = SharedInMemoryConditionalStore()
    var cs = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    cs.save(_cursor("p", "feed", "tok", 1, 1), 3)
    var locs = _locations(data)
    assert_equal(len(locs), 1)
    var body = data.get(Path.parse(locs[0]))
    var cut = List[UInt8]()
    for i in range(len(body) - 3):
        cut.append(body[i])
    _ = data.put(Path.parse(locs[0]), cut^)
    with assert_raises(contains="truncated"):
        _ = cs.load("p", "feed")
    with assert_raises(contains="truncated"):
        _ = cs.list_cursors()
    with assert_raises(contains="truncated"):
        cs.save(_cursor("p", "feed", "new", 2, 2), 3)


def test_an_object_holding_another_pairs_cursor_is_refused() raises:
    var data = SharedInMemoryConditionalStore()
    var cs = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    cs.save(_cursor("p", "one", "tok-1", 1, 1), 3)
    var locs = _locations(data)
    # The body of another pair's cursor, planted at the object of this pair.
    _ = data.put(
        Path.parse(locs[0]), encode_cursor(_cursor("p", "two", "tok-2", 2, 2))
    )
    with assert_raises(contains="hash collision"):
        _ = cs.load("p", "one")
    with assert_raises(contains="hash collision"):
        cs.save(_cursor("p", "one", "tok-3", 3, 3), 3)


def test_list_skips_objects_that_are_not_cursor_objects() raises:
    var data = SharedInMemoryConditionalStore()
    var cs = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    cs.save(_cursor("p", "feed", "tok", 1, 1), 3)
    var note = List[UInt8]()
    note.append(UInt8(104))
    _ = data.put(Path.parse("state/cursor/README.txt"), note^)
    var all = cs.list_cursors()
    assert_equal(len(all), 1)
    assert_equal(all[0].token, "tok")


def test_the_object_key_is_under_the_prefix_and_per_pair() raises:
    var data = SharedInMemoryConditionalStore()
    var cs = CursorStore[SharedInMemoryConditionalStore](
        data.clone(), String("state")
    )
    cs.save(_cursor("p", "feed", "a", 1, 1), 3)
    cs.save(_cursor("p", "other", "b", 1, 1), 3)
    var locs = _locations(data)
    assert_equal(len(locs), 2)
    assert_true(locs[0].startswith("state/cursor/"))
    assert_true(locs[0].endswith(".cur"))
    assert_true(locs[0] != locs[1])


def test_an_oversize_field_is_refused_before_anything_is_written() raises:
    var cs = _store()
    var big = String("")
    for _ in range(65537):
        big += "x"
    with assert_raises(contains="over the limit"):
        cs.save(_cursor("p", "feed", big, 1, 1), 3)
    assert_false(cs.has("p", "feed"))
    with assert_raises(contains="over the limit"):
        _ = cs.try_save(_cursor("p", "feed", big, 1, 1), String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
