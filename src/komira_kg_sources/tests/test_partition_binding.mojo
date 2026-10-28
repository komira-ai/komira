# =============================================================================
# test_partition_binding.mojo -- PartitionBindingStore on an in-memory
#   conditional-write store.
# =============================================================================
#
#   binding      a partition binds one raw store prefix and one lineage prefix,
#                with its source system, kind and facet, and reads back field for
#                field, through the same handle and a second handle; an unbound
#                partition is "no binding"; two prefixes are two stores.
#   one binding  binding the same partition again with the same values is a
#                no-op reporting it was not created; any other values (system,
#                kind, facet, raw store, lineage) are refused with an error naming
#                what is bound, and the first binding stays.
#   vocabulary   a source system outside the host's set is refused, and so is
#                every system when the set is empty; a kind or facet outside a
#                non-empty set is refused, and any is allowed when the set is
#                empty; nothing is written by a refused bind.
#   shape        an empty partition id, system or kind, a control byte, a bad
#                prefix and a raw store prefix equal to or nested with the lineage
#                prefix are refused.
#   listing      bindings list ordered by partition id; a stray object, a damaged
#                one and one stored under another partition's name are reported.
#   stored form  the body round trips; every strict prefix, an unknown version
#                and trailing bytes are refused.
#   failures     a store error is raised, never read as "unbound"; an object that
#                holds another partition's binding is refused.
# No test reads a clock or the environment.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_kg_format import fnv1a64_hex
from komira_kg_sources import (
    PartitionBinding,
    PartitionBindingStore,
    decode_binding,
    encode_binding,
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


def _systems() -> List[String]:
    var out = List[String]()
    out.append("alpha-sys")
    out.append("beta-sys")
    return out^


def _binding(partition: String) -> PartitionBinding:
    return PartitionBinding(
        partition, "alpha-sys", "kind-1", "facet-1", "lake/raw-" + partition, "lake/graph-" + partition
    )


def _store() raises -> PartitionBindingStore[Mem]:
    return PartitionBindingStore[Mem](Mem(), String("meta"), _systems())


def _object_path(partition: String) raises -> Path:
    return Path.parse("meta/binding/" + fnv1a64_hex(partition.as_bytes()) + ".bind")


def _refuses(body: List[UInt8]) -> Bool:
    try:
        _ = decode_binding(body)
    except e:
        _ = e
        return True
    return False


def test_a_partition_binds_one_raw_store_and_one_lineage() raises:
    var bs = _store()
    assert_true(bs.bind(_binding("part-1")))
    var got = bs.get("part-1")
    assert_equal(got.partition_id, "part-1")
    assert_equal(got.source_system, "alpha-sys")
    assert_equal(got.source_kind, "kind-1")
    assert_equal(got.facet, "facet-1")
    assert_equal(got.raw_prefix, "lake/raw-part-1")
    assert_equal(got.lineage_prefix, "lake/graph-part-1")
    assert_true(bs.has("part-1"))
    assert_equal(bs.prefix(), "meta")


def test_an_unbound_partition_is_no_binding() raises:
    var bs = _store()
    assert_false(bs.has("part-1"))
    assert_false(Bool(bs.find("part-1")))
    with assert_raises(contains="partition 'part-1' is unbound"):
        _ = bs.get("part-1")
    assert_equal(len(bs.list_bindings()), 0)


def test_a_binding_is_seen_through_a_second_handle_and_not_through_another_prefix() raises:
    var data = Mem()
    var a = PartitionBindingStore[Mem](data.clone(), String("meta"), _systems())
    var b = PartitionBindingStore[Mem](data.clone(), String("meta"), _systems())
    var other = PartitionBindingStore[Mem](data.clone(), String("elsewhere"), _systems())
    assert_true(a.bind(_binding("part-1")))
    assert_equal(b.get("part-1").source_kind, "kind-1")
    assert_false(other.has("part-1"))
    assert_false(b.bind(_binding("part-1")))


def test_binding_the_same_values_again_is_a_no_op() raises:
    var bs = _store()
    assert_true(bs.bind(_binding("part-1")))
    assert_false(bs.bind(_binding("part-1")))
    assert_equal(len(bs.list_bindings()), 1)


def test_a_different_binding_for_a_bound_partition_is_refused_and_the_first_stays() raises:
    var bs = _store()
    assert_true(bs.bind(_binding("part-1")))
    var other_raw = _binding("part-1")
    other_raw.raw_prefix = "lake/raw-other"
    with assert_raises(contains="partition 'part-1' is already bound (system 'alpha-sys', kind 'kind-1', facet 'facet-1', raw store 'lake/raw-part-1', lineage 'lake/graph-part-1'); a partition binds one raw store and one lineage"):
        _ = bs.bind(other_raw)
    var other_lineage = _binding("part-1")
    other_lineage.lineage_prefix = "lake/graph-other"
    with assert_raises(contains="already bound"):
        _ = bs.bind(other_lineage)
    var other_system = _binding("part-1")
    other_system.source_system = "beta-sys"
    with assert_raises(contains="already bound"):
        _ = bs.bind(other_system)
    var other_kind = _binding("part-1")
    other_kind.source_kind = "kind-2"
    with assert_raises(contains="already bound"):
        _ = bs.bind(other_kind)
    var other_facet = _binding("part-1")
    other_facet.facet = ""
    with assert_raises(contains="already bound"):
        _ = bs.bind(other_facet)
    var got = bs.get("part-1")
    assert_equal(got.raw_prefix, "lake/raw-part-1")
    assert_equal(got.lineage_prefix, "lake/graph-part-1")
    assert_equal(got.source_system, "alpha-sys")
    assert_equal(got.source_kind, "kind-1")
    assert_equal(got.facet, "facet-1")


def test_an_unknown_source_system_is_refused_against_the_hosts_set() raises:
    var bs = _store()
    var b = _binding("part-1")
    b.source_system = "gamma-sys"
    with assert_raises(contains="unknown source system 'gamma-sys' (known: alpha-sys, beta-sys)"):
        _ = bs.bind(b)
    assert_false(bs.has("part-1"))
    b.source_system = "beta-sys"
    assert_true(bs.bind(b))
    assert_equal(bs.get("part-1").source_system, "beta-sys")


def test_an_empty_set_of_systems_refuses_every_bind() raises:
    var bs = PartitionBindingStore[Mem](Mem(), String("meta"), List[String]())
    with assert_raises(contains="unknown source system 'alpha-sys' (known: )"):
        _ = bs.bind(_binding("part-1"))


def test_kinds_and_facets_are_checked_only_against_a_non_empty_set() raises:
    var kinds = List[String]()
    kinds.append("kind-1")
    var facets = List[String]()
    facets.append("facet-1")
    facets.append("")
    var bs = PartitionBindingStore[Mem](Mem(), String("meta"), _systems(), kinds^, facets^)
    var wrong_kind = _binding("part-1")
    wrong_kind.source_kind = "kind-9"
    with assert_raises(contains="unknown source kind 'kind-9' (known: kind-1)"):
        _ = bs.bind(wrong_kind)
    var wrong_facet = _binding("part-1")
    wrong_facet.facet = "facet-9"
    with assert_raises(contains="unknown facet 'facet-9' (known: facet-1, )"):
        _ = bs.bind(wrong_facet)
    assert_equal(len(bs.list_bindings()), 0)
    var no_facet = _binding("part-1")
    no_facet.facet = ""
    assert_true(bs.bind(no_facet))
    var free = _store()
    var open_binding = _binding("part-2")
    open_binding.source_kind = "anything"
    open_binding.facet = "whatever"
    assert_true(free.bind(open_binding))


def test_a_binding_that_is_not_well_formed_is_refused() raises:
    var bs = _store()
    var empty_id = _binding("part-1")
    empty_id.partition_id = ""
    with assert_raises(contains="partition id must not be empty"):
        _ = bs.bind(empty_id)
    var empty_system = _binding("part-1")
    empty_system.source_system = ""
    with assert_raises(contains="source system must not be empty"):
        _ = bs.bind(empty_system)
    var empty_kind = _binding("part-1")
    empty_kind.source_kind = ""
    with assert_raises(contains="source kind must not be empty"):
        _ = bs.bind(empty_kind)
    var control = _binding("part-1")
    control.facet = "a\nb"
    with assert_raises(contains="facet must not hold a control byte"):
        _ = bs.bind(control)
    var bad_raw = _binding("part-1")
    bad_raw.raw_prefix = "/lake"
    with assert_raises(contains="raw store prefix must not start or end with '/'"):
        _ = bs.bind(bad_raw)
    var bad_lineage = _binding("part-1")
    bad_lineage.lineage_prefix = "a//b"
    with assert_raises(contains="lineage prefix must not hold '//'"):
        _ = bs.bind(bad_lineage)
    assert_equal(len(bs.list_bindings()), 0)


def test_the_raw_store_and_the_lineage_must_not_share_a_directory() raises:
    var bs = _store()
    var same = _binding("part-1")
    same.lineage_prefix = same.raw_prefix.copy()
    with assert_raises(contains="must differ and neither may lie under the other"):
        _ = bs.bind(same)
    var under = _binding("part-1")
    under.lineage_prefix = under.raw_prefix + "/graph"
    with assert_raises(contains="must differ and neither may lie under the other"):
        _ = bs.bind(under)
    var over = _binding("part-1")
    over.raw_prefix = over.lineage_prefix + "/raw"
    with assert_raises(contains="must differ and neither may lie under the other"):
        _ = bs.bind(over)
    var near = _binding("part-1")
    near.raw_prefix = "lake/data"
    near.lineage_prefix = "lake/data2"
    assert_true(bs.bind(near))


def test_a_prefix_that_cannot_be_used_is_refused() raises:
    with assert_raises(contains="binding store prefix must not be empty"):
        _ = PartitionBindingStore[Mem](Mem(), String(""), _systems())


def test_bindings_list_ordered_by_partition_id() raises:
    var bs = _store()
    assert_true(bs.bind(_binding("part-c")))
    assert_true(bs.bind(_binding("part-a")))
    assert_true(bs.bind(_binding("part-b")))
    var all = bs.list_bindings()
    assert_equal(len(all), 3)
    assert_equal(all[0].partition_id, "part-a")
    assert_equal(all[1].partition_id, "part-b")
    assert_equal(all[2].partition_id, "part-c")
    assert_equal(all[1].raw_prefix, "lake/raw-part-b")


def test_a_stray_object_in_the_binding_directory_is_reported() raises:
    var data = Mem()
    var bs = PartitionBindingStore[Mem](data.clone(), String("meta"), _systems())
    _ = data.put(Path.parse("meta/binding/notes.txt"), List[UInt8]())
    with assert_raises(contains="'meta/binding/notes.txt' is not a binding name"):
        _ = bs.list_bindings()


def test_a_damaged_object_is_refused_on_read_and_on_list() raises:
    var data = Mem()
    var bs = PartitionBindingStore[Mem](data.clone(), String("meta"), _systems())
    var junk = List[UInt8]()
    junk.append(UInt8(1))
    junk.append(UInt8(9))
    _ = data.put(_object_path("part-1"), junk.copy())
    with assert_raises(contains="PartitionBindingStore: truncated"):
        _ = bs.get("part-1")
    with assert_raises(contains="PartitionBindingStore: truncated"):
        _ = bs.list_bindings()


def test_an_object_holding_another_partitions_binding_is_refused() raises:
    var data = Mem()
    var bs = PartitionBindingStore[Mem](data.clone(), String("meta"), _systems())
    # The object that part-2 would live at holds part-1's binding.
    _ = data.put(_object_path("part-2"), encode_binding(_binding("part-1")))
    with assert_raises(contains="holds the binding of another partition (a hash collision)"):
        _ = bs.get("part-2")
    with assert_raises(contains="holds a partition id that does not hash to its name"):
        _ = bs.list_bindings()
    # A bind of part-2 meets the object, reads it back and refuses, writing nothing.
    with assert_raises(contains="holds the binding of another partition"):
        _ = bs.bind(_binding("part-2"))


def test_a_store_failure_is_raised_not_read_as_unbound() raises:
    var faults = ArcPointer[_Faults](_Faults())
    var bs = PartitionBindingStore[_FaultyStore](
        _FaultyStore(Mem(), faults.copy()), String("meta"), _systems()
    )
    assert_true(bs.bind(_binding("part-1")))
    faults[].put_fails = True
    with assert_raises(contains="disk full"):
        _ = bs.bind(_binding("part-2"))
    faults[].put_fails = False
    faults[].get_fails = True
    with assert_raises(contains="connection refused"):
        _ = bs.find("part-1")
    with assert_raises(contains="connection refused"):
        _ = bs.has("part-1")
    faults[].get_fails = False
    assert_false(bs.has("part-2"))


def test_a_binding_round_trips_through_its_stored_form() raises:
    var back = decode_binding(encode_binding(_binding("part-1")))
    assert_true(back.same_as(_binding("part-1")))
    var emptied = _binding("part-1")
    emptied.facet = ""
    assert_true(decode_binding(encode_binding(emptied)).same_as(emptied))
    assert_false(back.same_as(emptied))


def test_every_strict_prefix_of_a_stored_binding_is_refused() raises:
    var body = encode_binding(_binding("part-1"))
    assert_false(_refuses(body))
    for n in range(len(body)):
        var cut = List[UInt8]()
        for i in range(n):
            cut.append(body[i])
        assert_true(_refuses(cut))


def test_an_unknown_version_and_trailing_bytes_are_refused() raises:
    var body = encode_binding(_binding("part-1"))
    var versioned = body.copy()
    versioned[0] = UInt8(2)
    with assert_raises(contains="format version 2 is not the supported 1"):
        _ = decode_binding(versioned)
    var long = body.copy()
    long.append(UInt8(0))
    with assert_raises(contains="1 trailing bytes after the last field"):
        _ = decode_binding(long)


def test_a_field_over_the_size_limit_is_refused_by_the_encoder() raises:
    var b = _binding("part-1")
    var big = String("")
    for _ in range(65537):
        big += "x"
    b.facet = big^
    with assert_raises(contains="facet is 65537 bytes"):
        _ = encode_binding(b)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
