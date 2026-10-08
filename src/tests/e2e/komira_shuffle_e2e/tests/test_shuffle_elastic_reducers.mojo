# Reducers pull partitions by claim (`claim_partition`, a create-if-absent of
# `_claims/<k>`), however many there are and whenever they join or leave, and
# every partition is consumed exactly once. Every task is its own
# `shuffle_task` process over one LocalFs root under $TEST_TMPDIR. The map
# output is written and sealed once (snapshot S0 of every object but the
# claims); each round below starts with no claims, and after each:
#   * every partition 0..R-1 was claimed by exactly one worker, and reduced by
#     that worker only (one SHUFFLE_REDUCE line per partition, from its owner);
#   * each partition's bytes are its rows computed in this test, exactly once
#     (komira_shuffle_e2e.rows: this test has no no-fault baseline run; the
#     computed rows are what every round is compared with);
#   * there are R claim objects and the rest of the store equals S0.
#
# Rounds:
#   race x3      four workers start at once (three times over, a fresh set of
#                processes each time);
#   two          two workers at once;
#   leave/join   worker 0 alone, limited to one claim: it takes partition 0
#                and leaves; then three workers join at once and must share the
#                other R-1 between them, leaving partition 0 alone.
from komira_runtime_paths import test_tmpdir

from komira_shuffle_e2e.children import TaskOutcome
from komira_shuffle_e2e.harness import ShuffleRun, fail, require_ok, snapshot_diff, task_bin_from_args, word

comptime P = 4
comptime R = 8
comptime ROWS = 8


struct Round(Movable):
    """What the workers of one round claimed and read."""

    var name: String
    var owner: List[String]  # per partition: the claimant's label, "" if none
    var claims_of: List[Int]  # per partition: how many workers claimed it
    var bytes: List[String]  # per partition: the bytes its owner read

    def __init__(out self, var name: String):
        self.name = name^
        self.owner = List[String]()
        self.claims_of = List[Int]()
        self.bytes = List[String]()
        for _ in range(R):
            self.owner.append(String(""))
            self.claims_of.append(0)
            self.bytes.append(String(""))

    def add(mut self, o: TaskOutcome) raises:
        var scenario = String("elastic reducers: ") + self.name
        require_ok(o, scenario, "a pool worker failed")
        for line in o.lines_with("SHUFFLE_CLAIM"):
            var k = atol(word(line, "partition"))
            self.claims_of[k] += 1
            if self.claims_of[k] > 1:
                raise fail(
                    scenario,
                    "partition " + String(k) + " was claimed by more than one worker (" + self.owner[k] + " and "
                    + o.label + "): the claim did not fence it",
                )
            self.owner[k] = o.label.copy()
        for line in o.lines_with("SHUFFLE_REDUCE"):
            var k = atol(word(line, "partition"))
            if self.owner[k] != o.label:
                raise fail(scenario, o.label + " reduced partition " + String(k) + " without owning its claim")
            if self.bytes[k].byte_length() > 0:
                raise fail(scenario, "partition " + String(k) + " was reduced twice")
            self.bytes[k] = word(line, "bytes")

    def finish(self, mut run: ShuffleRun, s0: List[String]) raises:
        var scenario = String("elastic reducers: ") + self.name
        for k in range(R):
            if self.claims_of[k] != 1:
                raise fail(scenario, "partition " + String(k) + " was claimed " + String(self.claims_of[k]) + " times")
            run.require_reduce_matches_rows(k, self.bytes[k], scenario, "the claimant's read")
        if run.claims() != R:
            raise fail(scenario, "the store holds " + String(run.claims()) + " claim objects, not " + String(R))
        var diff = snapshot_diff(s0, run.snapshot())
        if diff.byte_length() > 0:
            raise fail(scenario, "the reducers changed the map output or the seal:" + diff)
        run.clear_claims()
        if run.claims() != 0:
            raise fail(scenario, "the claims could not be cleared for the next round")


def _race(mut run: ShuffleRun, s0: List[String], workers: Int, var name: String) raises:
    var r = Round(name^)
    var hs = List[Int]()
    for w in range(workers):
        hs.append(run.start_pool(w))
    for h in hs:
        r.add(run.wait(h))
    r.finish(run, s0)


def _leave_then_join(mut run: ShuffleRun, s0: List[String]) raises:
    comptime S = "elastic reducers: leave/join"
    var r = Round(String("leave/join"))
    var leaver = run.wait(run.start_pool(0, 1))
    require_ok(leaver, S, "the worker limited to one claim failed")
    if leaver.field("SHUFFLE_POOL", "won") != "1":
        raise fail(S, "the worker limited to one claim did not leave after one\n" + leaver.describe())
    r.add(leaver)
    if r.owner[0] != "pool worker 0":
        raise fail(S, "the first worker, alone, did not get partition 0")
    var hs = List[Int]()
    for w in range(1, 4):
        hs.append(run.start_pool(w))
    var joined = 0
    for h in hs:
        var o = run.wait(h)
        joined += atol(o.field("SHUFFLE_POOL", "won"))
        r.add(o)
    if joined != R - 1:
        raise fail(S, "the workers that joined claimed " + String(joined) + " partitions, not the " + String(R - 1) + " left")
    r.finish(run, s0)


def main() raises:
    comptime S = "elastic reducers"
    var bin = task_bin_from_args()
    var run = ShuffleRun(bin, test_tmpdir() + "/shuffle", P, R, ROWS)
    run.run_maps(S)
    var committed = run.seal(S)
    if committed != run.all_producers():
        raise fail(S, "the driver sealed producers " + committed + ", not " + run.all_producers())
    var s0 = run.snapshot()
    if run.claims() != 0:
        raise fail(S, "claim objects exist before any reducer ran")
    for i in range(3):
        _race(run, s0, 4, String("race ") + String(i + 1) + " of four workers")
    _race(run, s0, 2, String("two workers"))
    _leave_then_join(run, s0)
    print("test_shuffle_elastic_reducers: PASS")
