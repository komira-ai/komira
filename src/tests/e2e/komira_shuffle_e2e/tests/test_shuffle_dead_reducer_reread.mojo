# A reducer that dies is replaced by a fresh one that reads its partition
# again, and gets the same bytes as a run in which nothing died; the death and
# the re-read leave the map output and the seal as they were. Every task is
# its own `shuffle_task` process over a LocalFs root under $TEST_TMPDIR.
#
# The phases run in this order:
#   faulted    after the maps and the seal (snapshot S0 of every object: key,
#              size, content etag):
#                * the reducer of partition 2 is SIGKILLed inside the
#                  production read_shuffle_partition, after it read the seal
#                  and the first of its four slices (shuffle_task's
#                  `first-slice` stage); the store must equal S0;
#                * another is SIGKILLed after read_shuffle_partition returned
#                  the whole partition, before reporting; the store must equal
#                  S0;
#   baseline   only then, a no-fault run in a root of its own: every
#              partition's bytes equal the rows computed in this test
#              (komira_shuffle_e2e.rows). It runs after the kills so that a
#              reduce that changes the store is reported at the kill that
#              did it, not as a baseline failure;
#   re-read    back in the faulted root:
#                * two fresh reducers of partition 2 run at once: each reads
#                  the baseline's bytes exactly; then every partition is read
#                  again and must equal the baseline; the store must equal S0,
#                  with one seal chunk and one `_entries` chunk per producer.
from komira_runtime_paths import test_tmpdir

from komira_shuffle_e2e.harness import ShuffleRun, fail, require_ok, snapshot_diff, task_bin_from_args

comptime P = 4
comptime R = 4
comptime ROWS = 8
comptime VICTIM = 2


def _baseline(bin: String, root: String) raises -> List[String]:
    comptime S = "dead reducer re-read: baseline"
    var run = ShuffleRun(bin, root, P, R, ROWS)
    run.run_maps(S)
    _ = run.seal(S)
    var out = List[String]()
    for k in range(R):
        var got = run.reduce(k, S)
        run.require_reduce_matches_rows(k, got, S, "the no-fault run")
        out.append(got)
    return out^


def _require_unchanged(run: ShuffleRun, s0: List[String], scenario: String, after: String) raises:
    var diff = snapshot_diff(s0, run.snapshot())
    if diff.byte_length() > 0:
        raise fail(scenario, after + " changed the map output or the seal:" + diff)


def main() raises:
    comptime S = "dead reducer re-read"
    var bin = task_bin_from_args()
    var tmp = test_tmpdir()
    var run = ShuffleRun(bin, tmp + "/faulted", P, R, ROWS)
    run.run_maps(S)
    _ = run.seal(S)
    var s0 = run.snapshot()
    if len(s0) == 0:
        raise fail(S, "the store is empty after the maps and the seal")

    var mid = run.start_reduce(VICTIM, "first-slice")
    run.kill_when_parked(mid, "first-slice", S)
    _require_unchanged(run, s0, S, "the reducer killed inside read_shuffle_partition after its first slice")

    var late = run.start_reduce(VICTIM, "read")
    run.kill_when_parked(late, "read", S)
    _require_unchanged(run, s0, S, "the reducer killed after reading its whole partition")

    var base = _baseline(bin, tmp + "/baseline")

    var a = run.start_reduce(VICTIM)
    var b = run.start_reduce(VICTIM)
    var oa = run.wait(a)
    var ob = run.wait(b)
    require_ok(oa, S, "the first replacement reducer failed")
    require_ok(ob, S, "the second replacement reducer failed")
    for o in [oa.field("SHUFFLE_REDUCE", "bytes"), ob.field("SHUFFLE_REDUCE", "bytes")]:
        if o != base[VICTIM]:
            raise fail(
                S,
                "the re-read of partition " + String(VICTIM) + " is not byte-identical to the no-fault run"
                + "\n  baseline " + base[VICTIM] + "\n  re-read  " + o,
            )

    for k in range(R):
        var got = run.reduce(k, S)
        if got != base[k]:
            raise fail(
                S,
                "after the dead reducers, partition " + String(k) + " differs from the no-fault run"
                + "\n  baseline " + base[k] + "\n  re-read  " + got,
            )
    _require_unchanged(run, s0, S, "the re-reads")
    if run.seal_chunks() != 1:
        raise fail(S, "the seal has " + String(run.seal_chunks()) + " chunks after the re-reads, not 1")
    if run.entries_chunks() != P:
        raise fail(S, "_entries has " + String(run.entries_chunks()) + " chunks after the re-reads, not " + String(P))
    print("test_shuffle_dead_reducer_reread: PASS")
