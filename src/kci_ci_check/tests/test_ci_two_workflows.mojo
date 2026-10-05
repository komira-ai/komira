# =============================================================================
# src/kci_ci_check/tests/test_ci_two_workflows.mojo -- the two workflow files
#   are held apart. The release workflow (kci.yml) runs the stages that are not
#   a PULL_REQUEST stage and has NO `pull_request` trigger, so a pull request
#   never reaches (or shows a skipped) release job; the pull request's check
#   (pr.yml, test_ci_pull_request.mojo) runs the PULL_REQUEST stage alone.
#   Each file is refused when read as the other.
# =============================================================================

from std.testing import TestSuite, assert_true

from kci_ci_check import ChannelsFile, check_running_workflow, check_workflow
from kci_release_machine import parse_machine_file


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" farm_connected: true\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"publish-gamma\" environment: \"gamma\" after: \"build\"\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"gamma\" }\n"
    "}\n"
    "stage { name: \"pr\" trigger: PULL_REQUEST farm_connected: true\n"
    "  step { name: \"check\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
)

# the release workflow: NO pull_request trigger, no `if:` keeping a pull request out
comptime _RELEASE: String = (
    "name: kci\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "permissions: {}\n"
    "jobs:\n"
    "  build:\n"
    "    environment: build\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: ./.github/actions/farm-connect\n"
    "      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    "  publish-gamma:\n"
    "    needs: build\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - run: kci run --stage publish-gamma --plan --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)

comptime _PR_JOB: String = (
    "  pr:\n"
    "    if: github.event.pull_request.head.repo.full_name == github.repository\n"
    "    runs-on: ubuntu-24.04\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          fetch-depth: 0\n"
    "      - uses: ./.github/actions/farm-connect\n"
    "      - run: kci run --stage pr --affected-by ${{ github.event.pull_request.base.sha }} --summary-file x\n"
)


def _tokens() -> List[String]:
    var t = List[String]()
    t.append(String("publish-gamma"))
    return t^


def _check(wf: String, pull_request_file: Bool) raises -> List[String]:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    return check_workflow(wf, g, _tokens(), String("release/machine.textproto"), pull_request_file)


def _all(f: List[String]) -> String:
    var s = String("")
    for i in range(len(f)):
        s += f[i] + String(" | ")
    return s^


def _reports(wf: String, needle: String) raises:
    var f = _check(wf, False)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def _mut(old: String, new: String) raises -> String:
    var s = String(_RELEASE)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def test_the_release_workflow_agrees_with_no_job_for_the_pull_request_stage() raises:
    var f = _check(String(_RELEASE), False)
    if len(f) != 0:
        raise Error(String("unexpected findings: ") + _all(f))


def test_a_pull_request_trigger_is_refused_in_the_release_workflow() raises:
    var want = String("R6: trigger 'pull_request': the release workflow is triggered by push and workflow_dispatch only")
    _reports(_mut(String("  workflow_dispatch:\n"), String("  pull_request:\n  workflow_dispatch:\n")), want)
    _reports(_mut(String("  workflow_dispatch:\n"), String("  pull_request:\n    branches: [main]\n  workflow_dispatch:\n")), want)
    _reports(
        _mut(String("  workflow_dispatch:\n"), String("  pull_request_target:\n  workflow_dispatch:\n")),
        String("R6: trigger 'pull_request_target'"),
    )
    # the other events that can run a pull request's code
    var others = List[String]()
    for n in ["pull_request_review", "pull_request_review_comment", "issue_comment", "workflow_run", "merge_group", "workflow_call", "schedule"]:
        others.append(String(n))
    for i in range(len(others)):
        _reports(
            _mut(String("  workflow_dispatch:\n"), String("  ") + others[i] + String(":\n  workflow_dispatch:\n")),
            String("R6: trigger '") + others[i] + String("': the release workflow's triggers are push and workflow_dispatch only"),
        )


def test_a_release_job_needs_no_condition_keeping_a_pull_request_out() raises:
    # the fixture's jobs have no `if:`; a condition that says so is allowed too
    var f = _check(
        _mut(String("  build:\n    environment: build\n"), String("  build:\n    if: github.event_name != 'pull_request'\n    environment: build\n")),
        False,
    )
    if len(f) != 0:
        raise Error(String("unexpected findings: ") + _all(f))


def test_the_pull_request_stage_has_no_job_in_the_release_workflow() raises:
    _reports(
        String(_RELEASE) + String(_PR_JOB),
        String("R6: job 'pr' runs the PULL_REQUEST stage 'pr'; the pull request's check is the one job of pr.yml"),
    )
    _reports(
        String(_RELEASE)
        + String("  pr-part:\n    steps:\n      - run: kci run --stage pr --only step:check --summary-file x\n"),
        String("R6: job 'pr-part' runs a part of stage 'pr', a PULL_REQUEST stage, which runs whole in the one job of pr.yml"),
    )
    # with a pull_request trigger AND the job (the old single-file shape)
    var old_shape = _mut(String("  workflow_dispatch:\n"), String("  pull_request:\n  workflow_dispatch:\n")) + String(_PR_JOB)
    _reports(old_shape, String("R6: trigger 'pull_request'"))
    _reports(old_shape, String("R6: job 'pr' runs the PULL_REQUEST stage"))


def test_the_release_workflow_still_holds_the_rest() raises:
    _reports(_mut(String("  push:\n    branches: [main]\n"), String("  push:\n")), String("R6: the push trigger is exactly `branches: [main]`"))
    _reports(_mut(String("      revision:\n"), String("      rev:\n")), String("R7: workflow_dispatch takes no input `revision`"))
    _reports(
        _mut(String("    environment: gamma\n    permissions:\n      id-token: write\n"), String("    environment: gamma\n    permissions: write-all\n")),
        String("job 'publish-gamma': R4: `permissions: write-all` grants permissions no map names"),
    )
    _reports(
        _mut(String("kci run --stage build --summary-file"), String("kci run --stage build --affected-by ${{ github.event.pull_request.base.sha }} --summary-file")),
        String("job 'build': R6: `kci run` carries --affected-by, but stage 'build' is a PUSH stage"),
    )


def test_each_file_is_refused_when_read_as_the_other() raises:
    var as_pr = _check(String(_RELEASE), True)
    assert_true(len(as_pr) > 0, String("kci.yml read as pr.yml is not refused"))
    var pr_yml = String(
        "name: pr\non:\n  pull_request:\npermissions: {}\njobs:\n  check:\n"
    ) + String(_PR_JOB).replace(String("  pr:\n"), String("")).replace(String("    if: "), String("    if: "))
    # (the job body above sits under `check:` already; pr.yml's own fixture is in test_ci_pull_request.mojo)
    var as_release = _check(pr_yml, False)
    assert_true(len(as_release) > 0, String("pr.yml read as the release workflow is not refused"))


def test_check_running_workflow_picks_the_role() raises:
    var g = parse_machine_file(String(_MACHINE), String("release/machine.textproto"))
    var files = List[ChannelsFile]()
    files.append(
        ChannelsFile(
            String("c.textproto"),
            String(
                "schema_version: 1\n"
                "channel { name: \"gamma\" visibility: PUBLIC repository { artifact_type: CONDA"
                " location: \"https://prefix.dev/komira-ai/gamma\" push_identity: \"repo:komira-ai/komira:environment:gamma\""
                " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
            ),
        )
    )
    var ok = check_running_workflow(g, files, String(_RELEASE), String("release/machine.textproto"))
    assert_true(len(ok) == 0, _all(ok))
    var wrong = check_running_workflow(g, files, String(_RELEASE), String("release/machine.textproto"), True)
    assert_true(len(wrong) > 0, String("the release workflow passed as the pull request's"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
