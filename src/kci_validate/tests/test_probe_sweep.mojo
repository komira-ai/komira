# =============================================================================
# src/kci_validate/tests/test_probe_sweep.mojo
#   The expiry sweep (probe_sweep.mojo) over kci_build's ScriptedRunner as a
#   fake docker daemon: with the daemon's SystemTime at T, a labelled
#   container started more than its maximum before T is removed and one
#   started less is left; one created and never started is measured from
#   its Created; one created long ago but started lately is measured from
#   its start. The containers to remove are not the FIRST listed, so a sweep
#   that judges only the first goes red. The runner's own clock an hour
#   ahead of the daemon's: a sweep on the wrong clock removes the young
#   container. SystemTime at `+02:00` with StartedAt in `Z`: a container 30
#   minutes old under a one-hour maximum is left, which a sweep that drops
#   the offset (two hours later) would remove. A label or a time that cannot
#   be read leaves its container and is reported.
# =============================================================================

from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_clock import now_unix_ms
from komira_datetime import Timestamp, format_rfc3339
from kci_build.scripted_runner import ScriptedRunner, ScriptedStep
from kci_validate import (
    ContainerHost,
    SweepReport,
    daemon_time_argv,
    instant_seconds,
    remove_argv,
    sweep_expired_probes,
    sweep_inspect_argv,
    sweep_list_argv,
)


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/probe_sweep/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _host() -> ContainerHost:
    return ContainerHost(String("/usr/bin/docker"), String("/usr/bin:/bin"), String("1001:118"))


struct _C(Copyable, Movable):
    var id: String
    var started: String
    var created: String
    var label: String

    def __init__(out self, var id: String, var started: String, var created: String, var label: String):
        self.id = id^
        self.started = started^
        self.created = created^
        self.label = label^


def _daemon(containers: List[_C], system_time: String, removed: List[String]) -> ScriptedRunner:
    """A daemon listing `containers`, at `system_time`, expecting `rm -f` of
    exactly `removed`, in that order."""
    var fake = ScriptedRunner()
    var listed = String("")
    var ids = List[String]()
    var inspected = String("")
    for i in range(len(containers)):
        ref c = containers[i]
        listed += c.id + String("\n")
        ids.append(c.id.copy())
        inspected += c.id + String(" ") + c.started + String(" ") + c.created + String(" ") + c.label + String("\n")
    fake.expect(ScriptedStep(sweep_list_argv(), stdout_text=listed^))
    if len(ids) == 0:
        return fake^
    fake.expect(ScriptedStep(sweep_inspect_argv(ids), stdout_text=inspected^))
    fake.expect(ScriptedStep(daemon_time_argv(), stdout_text=system_time + String("\n")))
    for i in range(len(removed)):
        fake.expect(ScriptedStep(remove_argv(removed[i])))
    return fake^


def _removals(fake: ScriptedRunner) -> List[String]:
    """The id of every `docker rm -f` the sweep ran, expected or not."""
    var out = List[String]()
    for i in range(len(fake.calls)):
        if fake.calls[i].argv[0] == String("rm"):
            out.append(fake.calls[i].argv[2].copy())
    return out^


def _joined(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


comptime NEVER: String = "0001-01-01T00:00:00Z"


def test_only_containers_past_their_own_maximum_are_removed() raises:
    var cs = List[_C]()
    # young: started 30 minutes before T under a one-hour maximum
    cs.append(_C(String("young"), String("2026-10-08T11:30:00.5Z"), String("2026-10-08T11:29:59Z"), String("3600")))
    # old: started two hours before T
    cs.append(_C(String("old"), String("2026-10-08T10:00:00.123456789Z"), String("2026-10-08T09:59:59Z"), String("3600")))
    # never started, created two hours before T: measured from Created
    cs.append(_C(String("stale"), String(NEVER), String("2026-10-08T10:00:00Z"), String("3600")))
    # never started, created ten minutes before T
    cs.append(_C(String("fresh"), String(NEVER), String("2026-10-08T11:50:00Z"), String("3600")))
    # created long ago, started fifteen minutes before T: measured from its start
    cs.append(_C(String("late"), String("2026-10-08T11:45:00Z"), String("2026-10-08T08:00:00Z"), String("3600")))
    # a short maximum, passed
    cs.append(_C(String("short"), String("2026-10-08T11:58:00Z"), String("2026-10-08T11:58:00Z"), String("65")))
    var removed = List[String]()
    for id in ["old", "stale", "short"]:
        removed.append(String(id))
    var fake = _daemon(cs, String("2026-10-08T12:00:00.987654321Z"), removed)
    var report = sweep_expired_probes(fake, _host(), _tmp(String("ages")))
    assert_equal(_joined(_removals(fake)), String("[old][stale][short]"))
    assert_equal(_joined(report.removed), String("[old][stale][short]"))
    assert_equal(_joined(report.kept), String("[young][fresh][late]"))
    assert_equal(len(report.problems), 0, _joined(report.problems))
    assert_equal(fake.remaining(), 0)


def test_the_runner_clock_plays_no_part() raises:
    # the daemon's clock is an hour BEHIND this machine's: a sweep that aged
    # containers by this machine's clock would see the young one at 90
    # minutes and remove it
    var t = Int(now_unix_ms() // 1000) - 3600
    var cs = List[_C]()
    cs.append(_C(String("young"), format_rfc3339(Timestamp(t - 1800, 0)), format_rfc3339(Timestamp(t - 1800, 0)), String("3600")))
    cs.append(_C(String("old"), format_rfc3339(Timestamp(t - 7200, 0)), format_rfc3339(Timestamp(t - 7200, 0)), String("3600")))
    var removed = List[String]()
    removed.append(String("old"))
    var fake = _daemon(cs, format_rfc3339(Timestamp(t, 0)), removed)
    var report = sweep_expired_probes(fake, _host(), _tmp(String("clock")))
    assert_equal(_joined(_removals(fake)), String("[old]"))
    assert_equal(_joined(report.kept), String("[young]"))


def test_the_daemon_offset_is_applied() raises:
    # SystemTime 14:00 at +02:00 is 12:00Z; the young container started at
    # 11:30Z, 30 minutes earlier. Read as 14:00Z it would be 150 minutes old.
    var cs = List[_C]()
    cs.append(_C(String("old"), String("2026-10-08T10:30:00Z"), String("2026-10-08T10:30:00Z"), String("3600")))
    cs.append(_C(String("young"), String("2026-10-08T11:30:00.000000001Z"), String("2026-10-08T11:30:00Z"), String("3600")))
    var removed = List[String]()
    removed.append(String("old"))
    var fake = _daemon(cs, String("2026-10-08T14:00:00.25+02:00"), removed)
    var report = sweep_expired_probes(fake, _host(), _tmp(String("offset")))
    assert_equal(_joined(_removals(fake)), String("[old]"))
    assert_equal(_joined(report.kept), String("[young]"))
    # and the reading itself: the same instant written two ways
    assert_equal(instant_seconds(String("2026-10-08T14:00:00+02:00")), instant_seconds(String("2026-10-08T12:00:00Z")))


def test_an_unreadable_container_is_left_and_reported() raises:
    var cs = List[_C]()
    cs.append(_C(String("fine"), String("2026-10-08T11:30:00Z"), String("2026-10-08T11:30:00Z"), String("3600")))
    cs.append(_C(String("nolabel"), String("2026-10-08T01:00:00Z"), String("2026-10-08T01:00:00Z"), String("soon")))
    cs.append(_C(String("zero"), String("2026-10-08T01:00:00Z"), String("2026-10-08T01:00:00Z"), String("0")))
    cs.append(_C(String("notime"), String("yesterday"), String("2026-10-08T01:00:00Z"), String("60")))
    var fake = _daemon(cs, String("2026-10-08T12:00:00Z"), List[String]())
    var report = sweep_expired_probes(fake, _host(), _tmp(String("unreadable")))
    assert_equal(len(_removals(fake)), 0)
    assert_equal(len(report.problems), 3, _joined(report.problems))
    assert_true(report.problems[0].find(String("nolabel: label 'soon'")) >= 0, report.problems[0])
    assert_true(report.problems[2].find(String("notime: start 'yesterday'")) >= 0, report.problems[2])


def test_a_failed_removal_is_reported_not_counted() raises:
    var cs = List[_C]()
    cs.append(_C(String("old"), String("2026-10-08T01:00:00Z"), String("2026-10-08T01:00:00Z"), String("60")))
    var fake = ScriptedRunner()
    var ids = List[String]()
    ids.append(String("old"))
    fake.expect(ScriptedStep(sweep_list_argv(), stdout_text=String("old\n")))
    fake.expect(ScriptedStep(sweep_inspect_argv(ids), stdout_text=String("old 2026-10-08T01:00:00Z 2026-10-08T01:00:00Z 60\n")))
    fake.expect(ScriptedStep(daemon_time_argv(), stdout_text=String("2026-10-08T12:00:00Z\n")))
    fake.expect(ScriptedStep(remove_argv(String("old")), Int32(1), stderr_text=String("removal in progress")))
    var report = sweep_expired_probes(fake, _host(), _tmp(String("rmfail")))
    assert_equal(len(report.removed), 0)
    assert_equal(len(report.problems), 1)
    assert_true(report.problems[0].find(String("removal in progress")) >= 0, report.problems[0])


def test_nothing_labelled_reads_nothing_more() raises:
    var fake = _daemon(List[_C](), String(""), List[String]())
    var report = sweep_expired_probes(fake, _host(), _tmp(String("empty")))
    assert_equal(len(fake.calls), 1)
    assert_equal(len(report.removed) + len(report.kept) + len(report.problems), 0)


def test_an_unreadable_daemon_clock_removes_nothing() raises:
    var cs = List[_C]()
    cs.append(_C(String("old"), String("2026-10-08T01:00:00Z"), String("2026-10-08T01:00:00Z"), String("60")))
    var fake = _daemon(cs, String("2026-10-08 12:00:00"), List[String]())
    var report = sweep_expired_probes(fake, _host(), _tmp(String("noclock")))
    assert_equal(len(_removals(fake)), 0)
    assert_equal(len(report.problems), 1)
    assert_true(report.problems[0].find(String("SystemTime")) >= 0, report.problems[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
