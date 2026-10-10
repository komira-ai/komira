# =============================================================================
# komira_shuffle_e2e/harness.mojo -- one shuffle under test: a root directory
# shared by `shuffle_task` processes, the tasks started over it, and what the
# test reads back from the store directly.
# =============================================================================
#
# `ShuffleRun` starts tasks (each a `shuffle_task` process, see
# bin/shuffle_task.mojo) and inspects the shared root through its own
# `LocalFsConditionalStore` handle: the `_entries` chunk count, whether a seal
# exists, the `_claims` objects, and a snapshot of every other object (key,
# size, content etag) so a test can prove the map output did not change.
#
# Failure messages start `FAIL [<scenario>]:` and say what broke.
# =============================================================================

from std.sys import argv

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.local_fs_conditional_store import LocalFsConditionalStore
from komira_objectstore.path import Path
from komira_shuffle.claim import claim_key, claims_prefix
from komira_shuffle.seal_driver import entries_prefix, seal_prefix
from komira_shuffle_e2e.children import TaskGroup, TaskOutcome, line_field
from komira_shuffle_e2e.rows import expected_partition_hex

comptime TASK_TIMEOUT_MS = 60_000
comptime SIGKILL_NUMBER = 9
comptime SHUFFLE_ID = 1
comptime STEP = 0


def task_bin_from_args() raises -> String:
    """The `--task-bin=<path>` argument the mojo_test passes."""
    var raw = argv()
    for i in range(1, len(raw)):
        var a = String(raw[i])
        if a.startswith("--task-bin="):
            return String(a[byte=11:])
    raise Error("the test needs --task-bin=<path of shuffle_task> (the mojo_test's args give it)")


def fail(scenario: String, what: String) -> Error:
    return Error(String("FAIL [") + scenario + "]: " + what)


def require_ok(o: TaskOutcome, scenario: String, what: String) raises:
    if not o.ok():
        raise fail(scenario, what + "\n" + o.describe())


def require_killed(o: TaskOutcome, scenario: String, what: String) raises:
    if o.signal != SIGKILL_NUMBER:
        raise fail(scenario, what + ": the task was not ended by SIGKILL\n" + o.describe())


def sort_strings(mut xs: List[String]):
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j] < xs[j - 1]:
            xs.swap_elements(j, j - 1)
            j -= 1


def join(xs: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(xs)):
        if i > 0:
            out += sep
        out += xs[i]
    return out^


def snapshot_diff(before: List[String], after: List[String]) -> String:
    """The objects present in one snapshot and not the other ('' if equal)."""
    var out = String("")
    for a in before:
        var found = False
        for b in after:
            if a == b:
                found = True
                break
        if not found:
            out += "\n  before only: " + a
    for b in after:
        var found = False
        for a in before:
            if a == b:
                found = True
                break
        if not found:
            out += "\n  after only:  " + b
    return out^


struct ShuffleRun(Movable):
    var bin: String
    var root: String
    var producers: Int
    var partitions: Int
    var rows_per: Int
    var tasks: TaskGroup
    var store: LocalFsConditionalStore

    def __init__(out self, bin: String, root: String, producers: Int, partitions: Int, rows_per: Int) raises:
        self.bin = bin
        self.root = root
        self.producers = producers
        self.partitions = partitions
        self.rows_per = rows_per
        self.tasks = TaskGroup()
        self.store = LocalFsConditionalStore(root.copy())

    # --- starting tasks ------------------------------------------------------

    def _args(self, role: String) -> List[String]:
        var a = List[String]()
        a.append(String("--role=") + role)
        a.append(String("--root=") + self.root)
        a.append(String("--shuffle-id=") + String(SHUFFLE_ID))
        a.append(String("--step=") + String(STEP))
        a.append(String("--producers=") + String(self.producers))
        a.append(String("--partitions=") + String(self.partitions))
        a.append(String("--rows-per=") + String(self.rows_per))
        return a^

    def start_map(mut self, producer: Int, die_after: String = "") raises -> Int:
        var a = self._args("map")
        a.append(String("--producer=") + String(producer))
        if die_after.byte_length() > 0:
            a.append(String("--die-after=") + die_after)
        return self.tasks.start(String("map ") + String(producer), self.bin, a)

    def start_driver(mut self) raises -> Int:
        return self.tasks.start(String("driver"), self.bin, self._args("driver"))

    def start_reduce(mut self, partition: Int, die_after: String = "") raises -> Int:
        var a = self._args("reduce")
        a.append(String("--partition=") + String(partition))
        if die_after.byte_length() > 0:
            a.append(String("--die-after=") + die_after)
        return self.tasks.start(String("reduce ") + String(partition), self.bin, a)

    def start_pool(mut self, worker: Int, max_claims: Int = 0) raises -> Int:
        var a = self._args("pool")
        a.append(String("--worker=") + String(worker))
        a.append(String("--max-claims=") + String(max_claims))
        return self.tasks.start(String("pool worker ") + String(worker), self.bin, a)

    def wait(mut self, h: Int) -> TaskOutcome:
        return self.tasks.wait(h, TASK_TIMEOUT_MS)

    def kill_when_parked(mut self, h: Int, stage: String, scenario: String) raises:
        """Wait for task `h` to print `PARKED <stage>`, SIGKILL it, and check
        a SIGKILL is what ended it."""
        try:
            self.tasks.wait_for_line(h, String("PARKED ") + stage, TASK_TIMEOUT_MS)
        except e:
            raise fail(scenario, String("the task to be killed at '") + stage + "' never got there: " + String(e))
        var o = self.tasks.kill(h, TASK_TIMEOUT_MS)
        require_killed(o, scenario, String("killing the task parked at '") + stage + "'")

    # --- whole phases ----------------------------------------------------------

    def run_maps(mut self, scenario: String) raises:
        """Every producer's map, all at once; each must succeed."""
        var hs = List[Int]()
        for p in range(self.producers):
            hs.append(self.start_map(p))
        for h in hs:
            require_ok(self.wait(h), scenario, "a map task failed")

    def seal(mut self, scenario: String) raises -> String:
        """Run the driver; it must seal. Returns its committed producer list."""
        var o = self.wait(self.start_driver())
        require_ok(o, scenario, "the driver did not seal")
        return o.field("SHUFFLE_DRIVER", "committed")

    def reduce(mut self, partition: Int, scenario: String) raises -> String:
        """A fresh reduce of `partition`; returns the bytes it read, as hex."""
        var o = self.wait(self.start_reduce(partition))
        require_ok(o, scenario, String("the reduce of partition ") + String(partition) + " failed")
        return o.field("SHUFFLE_REDUCE", "bytes")

    def all_producers(self) -> String:
        var xs = List[String]()
        for p in range(self.producers):
            xs.append(String(p))
        return join(xs, ",")

    def expected_hex(self, partition: Int) raises -> String:
        return expected_partition_hex(partition, self.producers, self.rows_per, self.partitions)

    def require_reduce_matches_rows(mut self, partition: Int, got_hex: String, scenario: String, what: String) raises:
        var want = self.expected_hex(partition)
        if got_hex != want:
            raise fail(
                scenario,
                what + ": partition " + String(partition) + " read bytes that are not its rows exactly once"
                + "\n  expected " + want + "\n  got      " + got_hex,
            )

    # --- reading the shared root ---------------------------------------------

    def entries_chunks(self) raises -> Int:
        var m = CasManifestStore[LocalFsConditionalStore](
            self.store.clone(), entries_prefix(Int64(SHUFFLE_ID), Int64(STEP)), RetryPolicy.default()
        )
        return Int(m.read_head_authoritative().chunk_seq) + 1

    def seal_chunks(self) raises -> Int:
        var m = CasManifestStore[LocalFsConditionalStore](
            self.store.clone(), seal_prefix(Int64(SHUFFLE_ID), Int64(STEP)), RetryPolicy.default()
        )
        return Int(m.read_head_authoritative().chunk_seq) + 1

    def _keys(self) raises -> List[String]:
        var listed = self.store.list_with_delimiter(Path.parse(""))
        var out = List[String]()
        for m in listed.objects:
            out.append(m.location + " " + String(m.size) + " " + m.etag)
        sort_strings(out)
        return out^

    def snapshot(self) raises -> List[String]:
        """Every object but the claims: `key size etag`, sorted."""
        var claims = claims_prefix(Int64(SHUFFLE_ID), Int64(STEP)) + "/"
        var out = List[String]()
        for k in self._keys():
            if not k.startswith(claims):
                out.append(k)
        return out^

    def claims(self) raises -> Int:
        var claims = claims_prefix(Int64(SHUFFLE_ID), Int64(STEP)) + "/"
        var n = 0
        for k in self._keys():
            if k.startswith(claims):
                n += 1
        return n

    def clear_claims(self) raises:
        for k in range(self.partitions):
            self.store.delete(Path.parse(claim_key(Int64(SHUFFLE_ID), Int64(STEP), Int64(k))))


def word(line: String, name: String) raises -> String:
    """The `name=` value among the words of a task's output line."""
    return line_field(line, name)
