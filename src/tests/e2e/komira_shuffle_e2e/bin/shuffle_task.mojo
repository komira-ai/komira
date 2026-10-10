# =============================================================================
# shuffle_task -- one task of a shuffle, as its own process: a map, the driver
# (the seal), a reduce of one partition, or a pool reducer that pulls
# partitions by claim. Every task opens a `LocalFsConditionalStore` on the one
# `--root` directory the test gives them all; the store is the only thing the
# processes share.
#
#   --role=map     --producer=P   sink_shuffle_write of producer P's rows
#   --role=driver                 seal_step over producers 0..P-1
#   --role=reduce  --partition=K  read_shuffle_partition(K)
#   --role=pool    --worker=W [--max-claims=N]
#                                 for K in 0..R-1: claim_partition(K); for each
#                                 won, read_shuffle_partition(K); stop after N
#                                 wins (N = 0: no limit)
#   common: --root=DIR --producers=P --partitions=R --rows-per=N
#           [--shuffle-id=1 --step=0]
#
# `--die-after=STAGE` makes the task stop at STAGE, print `PARKED <stage>` and
# wait to be killed (the test SIGKILLs it); a task nobody kills exits 4 after
# 120 s. Stages: `segment` (map: the `.seg` is written, the `_entries` entry is
# not), `entry` (map: the whole sink write is done, the task has not reported),
# `first-slice` (reduce: inside `read_shuffle_partition`, after the seal and
# the first `.seg` slice of K are read and before the rest are), `read`
# (reduce: `read_shuffle_partition` returned, nothing is reported).
#
# The `first-slice` stop is made by the store, not by komira_shuffle: the
# reduce runs the production `read_shuffle_partition` over `_StopAtFirstSlice`,
# a store that passes every call through to `LocalFsConditionalStore` and,
# right after returning the bytes of the first range read of a `.seg` object
# (the first slice; the seal reads touch only `_seal` and `_entries`
# objects), parks the process. So the kill lands mid-read in the code a real
# reducer runs.
#
# The `segment` stage writes the `.seg` the way `sink_shuffle_write` does,
# through the package's public pieces (HashPartitioner, encode_partition_body,
# SegWriter, write_segment); the sink has no stop point between its two writes.
#
# Output, one line each, flushed: `SHUFFLE_MAP producer=P ok`,
# `SHUFFLE_DRIVER committed=0,1,..`, `SHUFFLE_CLAIM worker=W partition=K`,
# `SHUFFLE_REDUCE partition=K rows=N bytes=<hex>`, `SHUFFLE_POOL worker=W
# won=N`. A task that fails prints `SHUFFLE_ERROR <message>` and exits 1.
# =============================================================================

from std.sys import argv, exit
from std.time import perf_counter_ns, sleep

from komira_objectstore.local_fs_conditional_store import LocalFsConditionalStore
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore, ConditionalWriteStore, ObjectStore
from komira_objectstore.types import CoalescePolicy, ListResult, ObjectMeta, WritePrecondition
from komira_shuffle.claim import claim_partition
from komira_shuffle.partitioner import HashPartitioner
from komira_shuffle.seal_driver import seal_step
from komira_shuffle.segment import SegWriter, write_segment
from komira_shuffle.sink import (
    ShuffleRow,
    encode_partition_body,
    shuffle_segment_key,
    sink_shuffle_write,
)
from komira_shuffle.source import decode_partition_payloads, read_shuffle_partition
from komira_shuffle_e2e.rows import producer_rows, to_hex

comptime _PARK_LIMIT_NS = 120 * 1_000_000_000


struct Flags(Movable):
    var role: String
    var root: String
    var die_after: String
    var shuffle_id: Int64
    var step: Int64
    var producers: Int
    var partitions: Int
    var rows_per: Int
    var producer: Int
    var partition: Int
    var worker: Int
    var max_claims: Int

    def __init__(out self) raises:
        self.role = String("")
        self.root = String("")
        self.die_after = String("")
        self.shuffle_id = 1
        self.step = 0
        self.producers = -1
        self.partitions = -1
        self.rows_per = -1
        self.producer = -1
        self.partition = -1
        self.worker = 0
        self.max_claims = 0
        var raw = argv()
        for i in range(1, len(raw)):
            var a = String(raw[i])
            if not a.startswith("--") or a.find("=") < 0:
                raise Error("shuffle_task: argument is not --name=value: " + a)
            var eq = a.find("=")
            var name = String(a[byte=2:eq])
            var value = String(a[byte=eq + 1:])
            if name == "role":
                self.role = value
            elif name == "root":
                self.root = value
            elif name == "die-after":
                self.die_after = value
            elif name == "shuffle-id":
                self.shuffle_id = Int64(atol(value))
            elif name == "step":
                self.step = Int64(atol(value))
            elif name == "producers":
                self.producers = atol(value)
            elif name == "partitions":
                self.partitions = atol(value)
            elif name == "rows-per":
                self.rows_per = atol(value)
            elif name == "producer":
                self.producer = atol(value)
            elif name == "partition":
                self.partition = atol(value)
            elif name == "worker":
                self.worker = atol(value)
            elif name == "max-claims":
                self.max_claims = atol(value)
            else:
                raise Error("shuffle_task: unknown flag --" + name)
        if self.root.byte_length() == 0:
            raise Error("shuffle_task: --root is required")
        if self.producers <= 0 or self.partitions <= 0 or self.rows_per <= 0:
            raise Error("shuffle_task: --producers, --partitions and --rows-per are required")

    def expected_producers(self) -> List[Int64]:
        var out = List[Int64]()
        for p in range(self.producers):
            out.append(Int64(p))
        return out^


def _say(line: String):
    print(line, flush=True)


def _park(stage: String):
    """Report the stop point and wait to be killed. Not synchronisation: the
    test acts on the `PARKED` line; the loop only keeps the process alive."""
    _say(String("PARKED ") + stage)
    var start = Int(perf_counter_ns())
    while Int(perf_counter_ns()) - start < _PARK_LIMIT_NS:
        sleep(0.05)
    _say(String("SHUFFLE_ERROR parked at ") + stage + " for 120 s and was never killed")
    exit(4)


def _run_map(f: Flags) raises:
    var store = LocalFsConditionalStore(f.root.copy())
    var rows = producer_rows(f.producer, f.rows_per, f.partitions)
    if f.die_after == "segment":
        var partitioner = HashPartitioner(Int64(f.partitions))
        var buckets = List[List[ShuffleRow]]()
        for _ in range(f.partitions):
            buckets.append(List[ShuffleRow]())
        for i in range(len(rows)):
            buckets[partitioner.partition_for(rows[i].key)].append(rows[i].copy())
        var w = SegWriter()
        for p in range(f.partitions):
            w.append_partition(encode_partition_body(buckets[p]), Int64(len(buckets[p])))
        var key = Path.parse(shuffle_segment_key(f.shuffle_id, f.step, Int64(f.producer)))
        _ = write_segment(store, key, w^)
        _park("segment")
    var entry = sink_shuffle_write(store, f.shuffle_id, f.step, Int64(f.producer), Int64(f.partitions), rows)
    _ = entry^
    if f.die_after == "entry":
        _park("entry")
    _say(String("SHUFFLE_MAP producer=") + String(f.producer) + " ok")


def _run_driver(f: Flags) raises:
    var store = LocalFsConditionalStore(f.root.copy())
    var seal = seal_step(store, f.shuffle_id, f.step, Int64(f.partitions), f.expected_producers())
    var line = String("SHUFFLE_DRIVER committed=")
    for i in range(len(seal.committed_producers)):
        if i > 0:
            line += ","
        line += String(seal.committed_producers[i])
    _say(line)


def _reduce_one(store: LocalFsConditionalStore, f: Flags, partition: Int) raises:
    var body = read_shuffle_partition(store, f.shuffle_id, f.step, Int64(partition), f.expected_producers())
    if f.die_after == "read":
        _park("read")
    var rows = len(decode_partition_payloads(body))
    _say(
        String("SHUFFLE_REDUCE partition=") + String(partition) + " rows=" + String(rows)
        + " bytes=" + to_hex(body)
    )


struct _StopAtFirstSlice(CloneableConditionalWriteStore, ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """`LocalFsConditionalStore`, except that the first `get_range` of a
    `.seg` object returns its bytes to nobody: the process parks there (see
    the module header). Clones park the same way."""

    var inner: LocalFsConditionalStore

    def __init__(out self, var inner: LocalFsConditionalStore):
        self.inner = inner^

    def clone(self) -> Self:
        return Self(self.inner.clone())

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(self, path: Path, bytes: List[UInt8], precond: WritePrecondition) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(self, path: Path, bytes: List[UInt8], expected_version: String) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(self, path: Path, start: Int64, length: Int64) raises -> List[UInt8]:
        var bytes = self.inner.get_range(path, start, length)
        if path.raw().endswith(".seg"):
            _park("first-slice")
        return bytes^

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _run_reduce(f: Flags) raises:
    var store = LocalFsConditionalStore(f.root.copy())
    if f.die_after == "first-slice":
        var stopping = _StopAtFirstSlice(store^)
        _ = read_shuffle_partition(stopping, f.shuffle_id, f.step, Int64(f.partition), f.expected_producers())
        raise Error("shuffle_task: the read of partition " + String(f.partition) + " fetched no .seg slice")
    _reduce_one(store, f, f.partition)


def _run_pool(f: Flags) raises:
    var store = LocalFsConditionalStore(f.root.copy())
    var won = 0
    for k in range(f.partitions):
        if f.max_claims > 0 and won >= f.max_claims:
            break
        if not claim_partition(store, f.shuffle_id, f.step, Int64(k)):
            continue
        _say(String("SHUFFLE_CLAIM worker=") + String(f.worker) + " partition=" + String(k))
        _reduce_one(store, f, k)
        won += 1
    _say(String("SHUFFLE_POOL worker=") + String(f.worker) + " won=" + String(won))


def main():
    try:
        var f = Flags()
        if f.role == "map":
            _run_map(f)
        elif f.role == "driver":
            _run_driver(f)
        elif f.role == "reduce":
            _run_reduce(f)
        elif f.role == "pool":
            _run_pool(f)
        else:
            raise Error("shuffle_task: --role must be map, driver, reduce or pool, not '" + f.role + "'")
    except e:
        _say(String("SHUFFLE_ERROR ") + String(e))
        exit(1)
