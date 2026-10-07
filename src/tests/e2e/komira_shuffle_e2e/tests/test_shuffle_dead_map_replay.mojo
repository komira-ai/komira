# A map task that dies is run again, and the shuffle comes out as if it had
# run once: no row lost, none doubled. Every task is its own `shuffle_task`
# process over one LocalFs root under $TEST_TMPDIR.
#
# The phases run in this order:
#   baseline     first, 4 maps, the driver and 4 reduces with no fault: each
#                partition's bytes equal the rows computed in this test
#                (komira_shuffle_e2e.rows), so the oracle is checked against
#                the real pipeline before it judges the faulted runs.
#   torn         producer 2 is SIGKILLed after its `.seg` is written and
#                before its `_entries` entry: the driver must refuse to seal
#                ("torn map phase") and write no seal; producer 2 run again
#                lands its entry once (4 chunks), the driver seals 0,1,2,3, and
#                every partition reads its rows exactly once.
#   abandoned    producer 1 is SIGKILLed after its whole sink write, before it
#                reports: a scheduler would run it again. Two replays run at
#                once. `_entries` must still hold 4 chunks (the sink's
#                idempotent append is the map-replay dedup), the seal lists each
#                producer once, and no partition reads a row twice.
from komira_runtime_paths import test_tmpdir

from komira_shuffle_e2e.harness import ShuffleRun, fail, require_ok, task_bin_from_args

comptime P = 4
comptime R = 4
comptime ROWS = 8


def _baseline(bin: String, root: String) raises -> List[String]:
    comptime S = "dead map replay: baseline"
    var run = ShuffleRun(bin, root, P, R, ROWS)
    run.run_maps(S)
    var committed = run.seal(S)
    if committed != run.all_producers():
        raise fail(S, "the driver sealed producers " + committed + ", not " + run.all_producers())
    var out = List[String]()
    for k in range(R):
        var got = run.reduce(k, S)
        run.require_reduce_matches_rows(k, got, S, "the no-fault run")
        out.append(got)
    return out^


def _require_matches_baseline(mut run: ShuffleRun, base: List[String], scenario: String) raises:
    for k in range(R):
        var got = run.reduce(k, scenario)
        if got != base[k]:
            raise fail(
                scenario,
                "partition " + String(k) + " after the replay differs from the no-fault run"
                + "\n  baseline " + base[k] + "\n  replayed " + got,
            )
        run.require_reduce_matches_rows(k, got, scenario, "after the replay")


def _torn(bin: String, root: String, base: List[String]) raises:
    comptime S = "dead map replay: killed between .seg and _entries"
    var run = ShuffleRun(bin, root, P, R, ROWS)
    var hs = List[Int]()
    for p in range(P):
        if p != 2:
            hs.append(run.start_map(p))
    var victim = run.start_map(2, "segment")
    run.kill_when_parked(victim, "segment", S)
    for h in hs:
        require_ok(run.wait(h), S, "a map other than the killed one failed")
    var chunks = run.entries_chunks()
    if chunks != P - 1:
        raise fail(S, "with producer 2 killed before its entry, _entries holds " + String(chunks) + " chunks, not " + String(P - 1))

    var pre = run.wait(run.start_driver())
    if pre.ok():
        raise fail(S, "the driver sealed a step whose producer 2 has no _entries entry\n" + pre.describe())
    if pre.out.find("torn map phase") < 0:
        raise fail(S, "the driver failed, but not by refusing a torn map phase\n" + pre.describe())
    if run.seal_chunks() != 0:
        raise fail(S, "the refused driver left a seal behind (" + String(run.seal_chunks()) + " seal chunks)")

    require_ok(run.wait(run.start_map(2)), S, "the replay of producer 2 failed")
    chunks = run.entries_chunks()
    if chunks != P:
        raise fail(S, "after the replay _entries holds " + String(chunks) + " chunks for " + String(P) + " producers")
    var committed = run.seal(S)
    if committed != run.all_producers():
        raise fail(S, "the seal lists producers " + committed + ", not each of " + run.all_producers() + " once")
    _require_matches_baseline(run, base, S)


def _abandoned(bin: String, root: String, base: List[String]) raises:
    comptime S = "dead map replay: killed after its entry, replayed twice at once"
    var run = ShuffleRun(bin, root, P, R, ROWS)
    var hs = List[Int]()
    for p in range(P):
        if p != 1:
            hs.append(run.start_map(p))
    var victim = run.start_map(1, "entry")
    run.kill_when_parked(victim, "entry", S)
    for h in hs:
        require_ok(run.wait(h), S, "a map other than the killed one failed")
    var chunks = run.entries_chunks()
    if chunks != P:
        raise fail(S, "producer 1 died after its sink write but _entries holds " + String(chunks) + " chunks, not " + String(P))

    var r1 = run.start_map(1)
    var r2 = run.start_map(1)
    require_ok(run.wait(r1), S, "the first replay of producer 1 failed")
    require_ok(run.wait(r2), S, "the second replay of producer 1 failed")
    chunks = run.entries_chunks()
    if chunks != P:
        raise fail(
            S,
            "the replays of producer 1 were not deduplicated: _entries holds " + String(chunks)
            + " chunks for " + String(P) + " producers",
        )
    var committed = run.seal(S)
    if committed != run.all_producers():
        raise fail(S, "the seal lists producers " + committed + ", not each of " + run.all_producers() + " once")
    _require_matches_baseline(run, base, S)


def main() raises:
    var bin = task_bin_from_args()
    var tmp = test_tmpdir()
    var base = _baseline(bin, tmp + "/baseline")
    _torn(bin, tmp + "/torn", base)
    _abandoned(bin, tmp + "/abandoned", base)
    print("test_shuffle_dead_map_replay: PASS")
