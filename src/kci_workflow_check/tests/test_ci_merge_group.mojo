# =============================================================================
# src/kci_workflow_check/tests/test_ci_merge_group.mojo -- R6 for pr.yml with
#   the merge queue's `merge_group` trigger (pull_request_events.mojo): the
#   events pr.yml may run on, what its job's `if:` and its `kci run
#   --affected-by` evaluate to on each event, and a workflow that agrees
#   followed by one mutation per branch, each of which must be reported.
#   What each test catches:
#   * the base selection: on a pull_request run the base is
#     github.event.pull_request.base.sha, on a merge_group run
#     github.event.merge_group.base_sha. A base that names the pull request's
#     base on a merge group (empty there) or swaps the two is refused;
#   * the condition: on a merge group the job runs (a skipped job is a
#     passing required check, so the queue would merge an untested change),
#     and on a pull request it runs only for a branch of this repository;
#   * the triggers: pull_request and merge_group (no value, or exactly
#     `types: [checks_requested]`); push, a manual run, pull_request_target
#     and workflow_run are still refused next to merge_group;
#   * R18: the two-event base is the only expression a script may hold.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_workflow_check import (
    BASE_EXPRESSION,
    MERGE_GROUP_BASE_EXPRESSION,
    MERGE_GROUP_CONDITION,
    PULL_REQUEST_BASE_EXPRESSION,
    RUNS,
    SAME_REPOSITORY,
    SAME_REPOSITORY_CONDITION,
    SKIPPED,
    base_for_event,
    check_workflow,
    condition_for_event,
    is_base_expression,
    is_pull_request_stage_event,
    pull_request_stage_events,
)
from kci_release_machine import parse_machine_file


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" farm_connected: true break_glass: true\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"pr\" trigger: PULL_REQUEST farm_connected: true\n"
    "  step { name: \"check\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
)

comptime _MG_TRIGGER: String = "  merge_group:\n    types: [checks_requested]\n"
comptime _IF: String = "    if: github.event_name == 'merge_group' || github.event.pull_request.head.repo.full_name == github.repository\n"
comptime _BASE: String = "github.event_name == 'merge_group' && github.event.merge_group.base_sha || github.event.pull_request.base.sha"

comptime _WF: String = (
    "name: pr\n"
    "on:\n"
    "  pull_request:\n"
    "    branches: [main]\n"
    "  merge_group:\n"
    "    types: [checks_requested]\n"
    "permissions: {}\n"
    "jobs:\n"
    "  check:\n"
    "    if: github.event_name == 'merge_group' || github.event.pull_request.head.repo.full_name == github.repository\n"
    "    runs-on: ubuntu-24.04\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          fetch-depth: 0\n"
    "      - name: farm\n"
    "        uses: ./.github/actions/farm-connect\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage pr \\\n"
    "            --affected-by ${{ github.event_name == 'merge_group' && github.event.merge_group.base_sha || github.event.pull_request.base.sha }} \\\n"
    "            --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)


def _check(wf: String) raises -> List[String]:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    return check_workflow(wf, g, List[String](), String("release/machine.textproto"), True)


def _all(f: List[String]) -> String:
    var s = String("")
    for i in range(len(f)):
        s += f[i] + String(" | ")
    return s^


def _agrees(wf: String) raises:
    var f = _check(wf)
    if len(f) != 0:
        raise Error(String("unexpected findings: ") + _all(f))


def _reports(wf: String, needle: String) raises:
    var f = _check(wf)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def _wf(old: String, new: String) raises -> String:
    var s = String(_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _pr() -> String:
    return String("pull_request")


def _mg() -> String:
    return String("merge_group")


# ---- the events ------------------------------------------------------------------


def test_the_pull_request_stage_events_are_pull_request_and_merge_group() raises:
    var e = pull_request_stage_events()
    assert_equal(len(e), 2)
    assert_equal(e[0], _pr())
    assert_equal(e[1], _mg())
    assert_true(is_pull_request_stage_event(_pr()))
    assert_true(is_pull_request_stage_event(_mg()))
    for other in ["push", "workflow_dispatch", "pull_request_target", "workflow_run", "schedule", "Merge_group", ""]:
        assert_false(is_pull_request_stage_event(String(other)), String(other))


# ---- (c) the base, by event -------------------------------------------------------


def test_the_base_is_the_events_own() raises:
    # the committed form: each event gets its own base commit
    assert_equal(String(BASE_EXPRESSION), String(_BASE))
    assert_equal(base_for_event(String(_BASE), _pr()), String(PULL_REQUEST_BASE_EXPRESSION))
    assert_equal(base_for_event(String(_BASE), _mg()), String(MERGE_GROUP_BASE_EXPRESSION))
    # the same selection written from the other event
    var other = String("github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.merge_group.base_sha")
    assert_equal(base_for_event(other, _pr()), String(PULL_REQUEST_BASE_EXPRESSION))
    assert_equal(base_for_event(other, _mg()), String(MERGE_GROUP_BASE_EXPRESSION))
    # spacing aside
    var tight = String("github.event_name=='merge_group'&&github.event.merge_group.base_sha||github.event.pull_request.base.sha")
    assert_equal(base_for_event(tight, _mg()), String(MERGE_GROUP_BASE_EXPRESSION))


def test_a_wrong_mapping_is_read_as_what_github_would_pass() raises:
    # the pull request's base alone: on a merge group it is the pull
    # request's base (empty there), not the merge group's
    var bare = String(PULL_REQUEST_BASE_EXPRESSION)
    assert_equal(base_for_event(bare, _pr()), String(PULL_REQUEST_BASE_EXPRESSION))
    assert_equal(base_for_event(bare, _mg()), String(PULL_REQUEST_BASE_EXPRESSION))
    # swapped
    var swapped = String("github.event_name == 'merge_group' && github.event.pull_request.base.sha || github.event.merge_group.base_sha")
    assert_equal(base_for_event(swapped, _pr()), String(MERGE_GROUP_BASE_EXPRESSION))
    assert_equal(base_for_event(swapped, _mg()), String(PULL_REQUEST_BASE_EXPRESSION))


def test_a_base_outside_the_grammar_reads_as_nothing() raises:
    var unread = List[String]()
    unread.append(String("github.event.pull_request.head.sha"))
    unread.append(String("github.event.pull_request.base.sha || github.event.merge_group.base_sha"))
    unread.append(String("github.event_name != 'merge_group' && github.event.pull_request.base.sha || github.event.merge_group.base_sha"))
    unread.append(String("github.event_name == 'merge_group' && github.event.merge_group.head_sha || github.event.pull_request.base.sha"))
    unread.append(String("github.event_name == 'Merge_Group' && github.event.merge_group.base_sha || github.event.pull_request.base.sha"))
    unread.append(String("(github.event_name == 'merge_group') && github.event.merge_group.base_sha || github.event.pull_request.base.sha"))
    unread.append(String("github.event_name == 'merge_group' && github.event.merge_group.base_sha || github.event.pull_request.base.sha || x"))
    unread.append(String(""))
    for i in range(len(unread)):
        assert_equal(base_for_event(unread[i], _pr()), String(""), unread[i])
        assert_equal(base_for_event(unread[i], _mg()), String(""), unread[i])


def test_the_workflow_passes_each_events_base() raises:
    _agrees(String(_WF))
    _agrees(
        _wf(
            String(_BASE),
            String("github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.merge_group.base_sha"),
        )
    )
    # the pull request's base on a merge group: refused, naming the event
    _reports(
        _wf(String(_BASE), String(PULL_REQUEST_BASE_EXPRESSION)),
        String("(on a merge_group run this passes github.event.pull_request.base.sha, not github.event.merge_group.base_sha)"),
    )
    # swapped: refused on both events
    var swapped = _wf(
        String(_BASE),
        String("github.event_name == 'merge_group' && github.event.pull_request.base.sha || github.event.merge_group.base_sha"),
    )
    _reports(swapped, String("(on a pull_request run this passes github.event.merge_group.base_sha, not github.event.pull_request.base.sha)"))
    _reports(swapped, String("(on a merge_group run this passes github.event.pull_request.base.sha, not github.event.merge_group.base_sha)"))
    # the finding says what to write
    _reports(swapped, String("it passes ${{ ") + String(_BASE) + String(" }}, written so"))


def test_without_the_merge_group_trigger_the_pull_requests_base_is_enough() raises:
    var wf = _wf(String(_MG_TRIGGER), String("")).replace(String(_BASE), String(PULL_REQUEST_BASE_EXPRESSION))
    _agrees(wf.replace(String(_IF), String("    if: ") + String(SAME_REPOSITORY_CONDITION) + String("\n")))
    # and the two-event forms are accepted there too (merge_group never fires)
    _agrees(_wf(String(_MG_TRIGGER), String("")))


# ---- the condition, by event -------------------------------------------------------


def test_the_condition_by_event() raises:
    assert_equal(condition_for_event(String(MERGE_GROUP_CONDITION), _pr()), String(SAME_REPOSITORY))
    assert_equal(condition_for_event(String(MERGE_GROUP_CONDITION), _mg()), String(RUNS))
    # the same-repository term alone skips a merge group (no pull request)
    assert_equal(condition_for_event(String(SAME_REPOSITORY_CONDITION), _pr()), String(SAME_REPOSITORY))
    assert_equal(condition_for_event(String(SAME_REPOSITORY_CONDITION), _mg()), String(SKIPPED))
    # an event test for pull_request runs a fork's pull request
    var fork = String("github.event_name == 'pull_request' || ") + String(SAME_REPOSITORY_CONDITION)
    assert_equal(condition_for_event(fork, _pr()), String(RUNS))
    # outside the grammar: nothing
    assert_equal(condition_for_event(String(SAME_REPOSITORY_CONDITION) + String(" || true"), _pr()), String(""))
    assert_equal(condition_for_event(String("always()"), _mg()), String(""))
    assert_equal(condition_for_event(String("github.event_name == 'merge_group'"), _mg()), String(""))


def test_a_merge_group_must_run_the_job() raises:
    # the same-repository term alone: skipped on a merge group, which passes the required check
    _reports(
        _wf(String(_IF), String("    if: ") + String(SAME_REPOSITORY_CONDITION) + String("\n")),
        String("pr.yml is triggered by merge_group, so the job carries `if: ") + String(MERGE_GROUP_CONDITION)
        + String("`: a merge group (built in this repository) runs the job; a job skipped on it is a passing required check"),
    )
    # inside ${{ }} it is the same condition
    _agrees(_wf(String(_IF), String("    if: ${{ ") + String(MERGE_GROUP_CONDITION) + String(" }}\n")))


def test_a_pull_request_from_a_fork_still_runs_nothing() raises:
    _reports(
        _wf(String("'merge_group' ||"), String("'pull_request' ||")),
        String("so the job carries `if: ") + String(SAME_REPOSITORY_CONDITION) + String("`"),
    )
    _reports(_wf(String(_IF), String("")), String("a pull request from a fork runs nothing"))


# ---- (a), (b) the triggers ----------------------------------------------------------


def test_merge_group_takes_no_value_or_checks_requested() raises:
    _agrees(_wf(String(_MG_TRIGGER), String("  merge_group:\n")))
    _agrees(_wf(String(_MG_TRIGGER), String("  merge_group:\n    types:\n      - checks_requested\n")))
    var want = String("R6: trigger 'merge_group' takes no value or exactly `types: [checks_requested]`")
    _reports(_wf(String(_MG_TRIGGER), String("  merge_group:\n    types: [destroyed]\n")), want)
    _reports(_wf(String(_MG_TRIGGER), String("  merge_group:\n    types: [checks_requested, destroyed]\n")), want)
    _reports(_wf(String(_MG_TRIGGER), String("  merge_group:\n    branches: [main]\n")), want)
    _reports(_wf(String(_MG_TRIGGER), String("  merge_group: checks_requested\n")), want)


def test_merge_group_alone_is_no_pull_requests_check() raises:
    _reports(_wf(String("  pull_request:\n    branches: [main]\n"), String("")), String("R6: pr.yml has no `pull_request` trigger"))


def test_other_events_are_still_refused_next_to_merge_group() raises:
    for name in ["push", "workflow_dispatch", "workflow_run", "pull_request_review", "issue_comment", "schedule"]:
        _reports(
            _wf(String(_MG_TRIGGER), String(_MG_TRIGGER) + String("  ") + String(name) + String(":\n")),
            String("R6: trigger '") + String(name) + String("': pr.yml is triggered by `pull_request` and `merge_group` alone"),
        )
    _reports(
        _wf(String(_MG_TRIGGER), String(_MG_TRIGGER) + String("  pull_request_target:\n")),
        String("R6: trigger 'pull_request_target': it runs a pull request's code with the base repository's secrets"),
    )
    # a flow list of triggers is read the same way
    _reports(
        _wf(String("  pull_request:\n    branches: [main]\n") + String(_MG_TRIGGER), String("")).replace(
            String("on:\n"), String("on: [pull_request, merge_group, push]\n")
        ),
        String("R6: trigger 'push'"),
    )


# ---- R18: the base is the only expression a script holds ----------------------------


def test_only_the_base_grammar_reaches_a_script() raises:
    assert_true(is_base_expression(String("${{ ") + String(_BASE) + String(" }}")))
    assert_true(is_base_expression(String("${{github.event.pull_request.base.sha}}")))
    assert_false(is_base_expression(String(_BASE)))
    assert_false(is_base_expression(String("${{ github.event.merge_group.head_ref }}")))
    _reports(
        _wf(String("github.event.merge_group.base_sha ||"), String("github.event.merge_group.head_ref ||")),
        String("R18: a `run:` script holds `${{ github.event_name == 'merge_group' && github.event.merge_group.head_ref"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
