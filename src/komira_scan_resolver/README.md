# komira_scan_resolver

The contract a scan kind implements so an engine can execute a plan leaf that
names it. A kind conforms to `ScanSourceResolver`: it builds a `ScanBinding`
from the scan's parameters, plans the splits one execution reads
(`plan_splits` returns a `ScanSplitPlan`), and opens a `SplitReader` per split
that answers each `poll` with a batch of rows or with the end of the split.
A `ScanSplit` has a stable key, a start and an optional stop, both
`SplitPosition`s in the kind's own byte encoding, and may list keys of splits
that must be read before it (`after`).

`drain_scan` reads a complete, bounded plan into memory: every split from
start to stop, one at a time, in `split_read_order`, stopping early once the
request's row limit or a byte budget is reached. It refuses, by name, a plan
that may still grow or has a split without a stop
(`SCAN_READ_MODE_UNBOUNDED_DRAIN`), duplicate keys, an unknown `after` key or
a cycle (`SCAN_SPLIT_PLAN_INVALID`), and a split that ends before its stop
(`SCAN_SPLIT_STALLED`). `ErasedScanSourceResolver.erase` boxes a conformer
behind one non-generic type, and `ScanSourceResolvers` holds one per kind id:
it refuses a second resolver for a kind (`SCAN_KIND_ALREADY_REGISTERED`) and
a lookup of a kind nothing serves (`SCAN_KIND_NOT_EXECUTABLE`). The erased
facade refuses a binding or position of another kind
(`SCAN_RESOLVER_FOREIGN_KIND`).

This package ships no scan kind of its own and reads no storage; the
bindings, parameters and kind descriptors it uses come from
`komira_scan_source`.

## Examples

A kind serving a fixed in-memory table as two splits of 3 and 2 rows, the
second read after the first, drained directly and through the erased set:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo module
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import ScanBinding, SCAN_EPOCH_NONE, SNAPSHOT_LIVE, scan_kind_id
from komira_scan_source.scan_kind_registry import ScanKindDescriptor
from komira_scan_source.scan_params import ScanParams
from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ErasedScanSourceResolver, ScanRequest, ScanSourceResolver, ScanSourceResolvers, SCAN_KIND_NOT_EXECUTABLE, refuse_discover_splits
from komira_scan_resolver.scan_split import ScanSplit, ScanSplitPlan, SplitDelta, SplitPoll, SplitPosition, SplitReader


comptime NUMBERS_KIND = "example.numbers"


def numbers_schema() -> Schema:
    return Schema.from_fields_1(Field("n", DType.int64, True))


def numbers_position(batches_read: Int) -> SplitPosition:
    var b = List[UInt8]()
    b.append(UInt8(batches_read))
    return SplitPosition(scan_kind_id(NUMBERS_KIND), UInt8(1), b^)


struct NumbersReader(SplitReader, Movable, Deinitable):
    """Reads one batch of `rows` rows, then answers END."""
    var rows: Int
    var batches_read: Int

    def __init__(out self, rows: Int, batches_read: Int):
        self.rows = rows
        self.batches_read = batches_read

    def poll(mut self, max_rows: Int64, max_bytes: Int64) raises -> SplitPoll:
        if self.batches_read >= 1:
            return SplitPoll.end(numbers_position(self.batches_read))
        self.batches_read = 1
        var values = List[Scalar[DType.int64]]()
        for i in range(self.rows):
            values.append(Scalar[DType.int64](Int64(i)))
        var column = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(values^)
        )
        var batch = RecordBatch.from_typed_columns_1(numbers_schema(), column^)
        return SplitPoll.rows(batch^, numbers_position(1))


struct NumbersKind(ScanSourceResolver, Movable, Deinitable):
    comptime Reader = NumbersReader

    def __init__(out self):
        pass

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        return UInt64(1)

    def descriptor(self) -> ScanKindDescriptor:
        var required = List[String]()
        required.append("table")
        return ScanKindDescriptor(
            kind_name=String(NUMBERS_KIND),
            gate=PushdownGate.reject_all(),
            snapshot_policy=SNAPSHOT_LIVE,
            required_params=required^,
        )

    def position_version(self) -> UInt8:
        return UInt8(1)

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        var fp = params.hash_into(UInt64(scan_kind_id(NUMBERS_KIND)))
        return ScanBinding(
            kind_id=scan_kind_id(NUMBERS_KIND),
            kind_name=String(NUMBERS_KIND),
            name=params.get_str("table"),
            params=params.copy(),
            schema=numbers_schema(),
            fingerprint=fp,
            structural_id=fp,
            gate=PushdownGate.reject_all(),
            snapshot_policy=SNAPSHOT_LIVE,
        )

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        var splits = List[ScanSplit]()
        splits.append(
            ScanSplit("part-0", numbers_position(0), Optional(numbers_position(1)), est_rows=3)
        )
        var after = List[String]()
        after.append("part-0")
        splits.append(
            ScanSplit("part-1", numbers_position(0), Optional(numbers_position(1)), after^, est_rows=2)
        )
        var resolved = ScanParams()
        resolved.put_i64("rows_planned", Int64(5))
        return ScanSplitPlan(splits^, True, resolved^)

    def discover_splits(self, req: ScanRequest, known: List[String]) raises -> SplitDelta:
        return refuse_discover_splits(NUMBERS_KIND)

    def open_split(self, req: ScanRequest, split: ScanSplit) raises -> NumbersReader:
        var rows = 3
        if split.split_key == "part-1":
            rows = 2
        return NumbersReader(rows, Int(split.start.bytes[0]))


def main() raises:
    var kind = NumbersKind()
    var params = ScanParams()
    params.put_str("table", "numbers")
    var binding = kind.build_binding(params)
    assert_equal(binding.name, "numbers")

    var opened = drain_scan(kind, ScanRequest(binding.copy()))
    assert_equal(opened.num_batches(), 2)
    assert_equal(opened.num_rows(), 5)
    assert_equal(opened.resolved.get_i64("rows_planned"), Int64(5))

    # A row limit stops the drain between polls.
    var limited = drain_scan(kind, ScanRequest(binding.copy(), limit=Int64(3)))
    assert_equal(limited.num_rows(), 3)

    # The same kind, erased and looked up by kind id.
    var resolvers = ScanSourceResolvers()
    resolvers.register(ErasedScanSourceResolver.erase(NumbersKind()))
    assert_true(resolvers.contains(scan_kind_id(NUMBERS_KIND)))
    var via_set = drain_scan(resolvers.get(scan_kind_id(NUMBERS_KIND)), ScanRequest(binding^))
    assert_equal(via_set.num_rows(), 5)

    var refused = String()
    try:
        _ = resolvers.get(scan_kind_id("example.other")).kind_name()
    except e:
        refused = String(e)
    assert_true(String(SCAN_KIND_NOT_EXECUTABLE) in refused)
    assert_true(NUMBERS_KIND in refused)  # the message names what is registered
```

The read order of a plan, and the checks on it, without any kind:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_scan_resolver.drain_scan import split_read_order, SCAN_SPLIT_PLAN_INVALID
from komira_scan_resolver.scan_split import ScanSplit, SplitPosition

def at(n: Int) -> SplitPosition:
    var b = List[UInt8]()
    b.append(UInt8(n))
    return SplitPosition(UInt32(7), UInt8(1), b^)

def split(key: String, var after: List[String]) -> ScanSplit:
    return ScanSplit(key, at(0), Optional(at(1)), after^)

# "merged" reads after both of its parents; plan order decides the rest.
var parents = List[String]()
parents.append("left")
parents.append("right")
var plan = List[ScanSplit]()
plan.append(split("merged", parents^))
plan.append(split("left", List[String]()))
plan.append(split("right", List[String]()))
var order = split_read_order(plan)
assert_equal(order[0], 1)
assert_equal(order[1], 2)
assert_equal(order[2], 0)

var cycle = List[ScanSplit]()
var after_b = List[String]()
after_b.append("b")
var after_a = List[String]()
after_a.append("a")
cycle.append(split("a", after_b^))
cycle.append(split("b", after_a^))
var message = String()
try:
    _ = split_read_order(cycle)
except e:
    message = String(e)
assert_true(String(SCAN_SPLIT_PLAN_INVALID) in message)
assert_true("cycle" in message)

# A position encoded by another kind is refused by name.
var refused = False
try:
    at(0).require_kind(UInt32(8), UInt8(1), "example.other", "start of 'left'")
except e:
    refused = "SCAN_RESOLVER_FOREIGN_KIND" in String(e)
assert_true(refused)
```
