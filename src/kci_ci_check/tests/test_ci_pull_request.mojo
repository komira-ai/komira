# =============================================================================
# src/kci_ci_check/tests/test_ci_pull_request.mojo -- R6 as amended: a pull
#   request's per-change check. A machine file with a PULL_REQUEST stage; a
#   pull request workflow that agrees with it and the release workflow that
#   agrees with it, then one mutation per branch of the rule, each of which
#   must be reported; and the start-up entry point `kci run` calls.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_ci_check import ChannelsFile, check_running_workflow, check_workflow, kci_run_calls
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

comptime _PR_WF: String = (
    "name: pr\n"
    "on:\n"
    "  pull_request:\n"
    "    branches: [main]\n"
    "permissions: {}\n"
    "jobs:\n"
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
    "      - name: farm\n"
    "        uses: ./.github/actions/farm-connect\n"
    "        with:\n"
    "          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage pr \\\n"
    "            --affected-by ${{ github.event.pull_request.base.sha }} \\\n"
    "            --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)

comptime _RELEASE_WF: String = (
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


def _tokens() -> List[String]:
    var t = List[String]()
    t.append(String("publish-gamma"))
    return t^


def _check(machine: String, wf: String) raises -> List[String]:
    var g = parse_machine_file(machine, String("machine file"))
    return check_workflow(wf, g, _tokens(), String("release/machine.textproto"))


def _all(f: List[String]) -> String:
    var s = String("")
    for i in range(len(f)):
        s += f[i] + String(" | ")
    return s^


def _agrees(machine: String, wf: String) raises:
    var f = _check(machine, wf)
    if len(f) != 0:
        raise Error(String("unexpected findings: ") + _all(f))


def _reports_on(machine: String, wf: String, needle: String) raises:
    var f = _check(machine, wf)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def _reports(wf: String, needle: String) raises:
    _reports_on(String(_MACHINE), wf, needle)


def _pr(old: String, new: String) raises -> String:
    var s = String(_PR_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _release(old: String, new: String) raises -> String:
    var s = String(_RELEASE_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


# ---- the two workflows that agree ----------------------------------------------


def test_the_pull_request_workflow_agrees() raises:
    _agrees(String(_MACHINE), String(_PR_WF))


def test_the_release_workflow_agrees_and_needs_no_pr_job() raises:
    _agrees(String(_MACHINE), String(_RELEASE_WF))


def test_the_affected_by_spellings_kci_accepts() raises:
    # quoted, `=`, and the spacing inside ${{ }} aside
    _agrees(String(_MACHINE), _pr(String("--affected-by ${{ github.event.pull_request.base.sha }}"), String("--affected-by \"${{ github.event.pull_request.base.sha }}\"")))
    _agrees(String(_MACHINE), _pr(String("--affected-by ${{ github.event.pull_request.base.sha }}"), String("--affected-by=${{github.event.pull_request.base.sha}}")))
    # the fork condition inside ${{ }}
    _agrees(
        String(_MACHINE),
        _pr(
            String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"),
            String("    if: ${{ github.event.pull_request.head.repo.full_name == github.repository }}\n"),
        ),
    )


def test_a_github_expression_is_one_word() raises:
    var calls = kci_run_calls(String("kci run --stage pr --affected-by ${{ github.event.pull_request.base.sha }} --summary-file x"))
    assert_equal(len(calls), 1)
    assert_true(calls[0].has_affected_by)
    assert_equal(calls[0].affected_by, String("${{ github.event.pull_request.base.sha }}"))
    assert_true(calls[0].has_summary_file)
    var none = kci_run_calls(String("kci run --stage build --summary-file x"))
    assert_false(none[0].has_affected_by)


# ---- triggers ------------------------------------------------------------------


def test_pull_request_target_is_never_a_trigger() raises:
    _reports(_pr(String("  pull_request:\n"), String("  pull_request_target:\n")), String("R6: trigger 'pull_request_target'"))
    _reports(
        _pr(String("  pull_request:\n    branches: [main]\n"), String("  pull_request:\n    branches: [main]\n  pull_request_target:\n")),
        String("R6: trigger 'pull_request_target': it runs a pull request's code with the base repository's secrets"),
    )


def test_a_pull_request_workflow_has_no_other_trigger() raises:
    _reports(
        _pr(String("  pull_request:\n"), String("  push:\n  pull_request:\n")),
        String("R6: trigger 'push' in a workflow triggered by pull_request: such a workflow has no other trigger"),
    )
    _reports(
        _pr(String("  pull_request:\n"), String("  workflow_dispatch:\n  pull_request:\n")),
        String("R6: trigger 'workflow_dispatch' in a workflow triggered by pull_request"),
    )


def test_pull_request_with_no_pull_request_stage_is_refused() raises:
    var machine = String(_MACHINE).replace(String(" trigger: PULL_REQUEST"), String(""))
    _reports_on(
        machine,
        String(_PR_WF),
        String("R6: trigger 'pull_request': the machine file declares no PULL_REQUEST stage, and a release workflow never runs a pull request's code"),
    )


# ---- which jobs run where ------------------------------------------------------


def test_a_push_stage_job_in_a_pull_request_workflow_is_refused() raises:
    var wf = String(_PR_WF) + String("  build:\n    environment: build\n    steps:\n      - run: kci run --stage build --summary-file x\n")
    _reports(wf, String("R6: job 'build' runs stage 'build', a PUSH stage, in a workflow triggered by pull_request"))
    # and a part of a PUSH stage
    var part = String(_PR_WF) + String("  smoke:\n    steps:\n      - run: kci run --stage publish-gamma --only step:publish --summary-file x\n")
    _reports(part, String("R6: job 'smoke' runs stage 'publish-gamma', a PUSH stage, in a workflow triggered by pull_request"))


def test_a_pull_request_stage_job_in_the_release_workflow_is_refused() raises:
    var wf = String(_RELEASE_WF) + String(
        "  pr:\n    steps:\n      - run: kci run --stage pr --affected-by ${{ github.event.pull_request.base.sha }}"
        " --summary-file x\n"
    )
    _reports(wf, String("R6: job 'pr' runs stage 'pr', a PULL_REQUEST stage, in a workflow not triggered by pull_request"))


def test_the_pull_request_workflow_still_needs_its_stage_job() raises:
    _reports(_pr(String("  pr:\n"), String("  check:\n")), String("R1: stage 'pr' has no job of the same id"))


# ---- the job -------------------------------------------------------------------


def test_a_pull_request_job_runs_in_no_environment() raises:
    _reports(
        _pr(String("    runs-on: ubuntu-24.04\n"), String("    runs-on: ubuntu-24.04\n    environment: pr\n")),
        String("job 'pr': R2: stage 'pr' is a PULL_REQUEST stage, so its job runs in no environment"),
    )


def test_a_pull_request_job_passes_the_base_commit() raises:
    _reports(
        _pr(String("            --affected-by ${{ github.event.pull_request.base.sha }} \\\n"), String("")),
        String("job 'pr': R6: stage 'pr' is a PULL_REQUEST stage, so its `kci run` carries --affected-by ${{ github.event.pull_request.base.sha }}"),
    )
    _reports(
        _pr(String("${{ github.event.pull_request.base.sha }}"), String("origin/main")),
        String("R6: stage 'pr' is a PULL_REQUEST stage: `--affected-by origin/main`; it passes ${{ github.event.pull_request.base.sha }}"),
    )
    _reports(
        _pr(String("github.event.pull_request.base.sha"), String("github.event.pull_request.head.sha")),
        String("`--affected-by ${{ github.event.pull_request.head.sha }}`; it passes"),
    )


def test_a_pull_request_job_fetches_the_full_history() raises:
    _reports(
        _pr(String("        with:\n          fetch-depth: 0\n"), String("")),
        String("job 'pr': R6: its checkout has no `with: fetch-depth: 0`"),
    )
    _reports(
        _pr(String("          fetch-depth: 0\n"), String("          fetch-depth: 1\n")),
        String("job 'pr': R6: its checkout has no `with: fetch-depth: 0`"),
    )
    _reports(
        _pr(String("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          fetch-depth: 0\n"), String("")),
        String("so the job checks out the full history (`uses: actions/checkout@<sha>` with `fetch-depth: 0`); it has no checkout step"),
    )


def test_a_farm_connected_pull_request_job_never_runs_a_fork() raises:
    var no_if = _pr(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String(""))
    _reports(
        no_if,
        String("R6: stage 'pr' is a PULL_REQUEST stage and farm-connected, so the job carries `if: github.event.pull_request.head.repo.full_name == github.repository`"),
    )
    # another condition is not the fork condition
    _reports(
        _pr(String("== github.repository\n"), String("== github.repository || true\n")),
        String("and farm-connected, so the job carries `if:"),
    )
    _reports(
        _pr(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String("    if: always()\n")),
        String("and farm-connected, so the job carries `if:"),
    )


def test_a_pull_request_stage_that_is_not_farm_connected() raises:
    # no credential: no condition, no farm connection, no identity token
    var machine = String(_MACHINE).replace(String("trigger: PULL_REQUEST farm_connected: true"), String("trigger: PULL_REQUEST"))
    var wf = _pr(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String(""))
    wf = wf.replace(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    wf = wf.replace(String("      id-token: write\n"), String(""))
    _agrees(machine, wf)
    # the identity token is the farm connection's only: refused here
    var token = wf.replace(String("      contents: read\n"), String("      contents: read\n      id-token: write\n"))
    _reports_on(machine, token, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel and is not farm-connected"))


def test_a_farm_connected_pull_request_job_needs_its_token() raises:
    _reports(_pr(String("      id-token: write\n"), String("")), String("job 'pr': R4: stage 'pr' is farm-connected, so the job needs `id-token: write`"))


def test_write_all_is_refused_on_a_pull_request_job() raises:
    # `write-all` grants `id-token: write` with no map entry naming it
    var machine = String(_MACHINE).replace(String("trigger: PULL_REQUEST farm_connected: true"), String("trigger: PULL_REQUEST"))
    var wf = _pr(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String(""))
    wf = wf.replace(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    wf = wf.replace(String("    permissions:\n      contents: read\n      id-token: write\n"), String("    permissions: write-all\n"))
    _reports_on(machine, wf, String("job 'pr': R4: `permissions: write-all` grants permissions no map names"))
    _reports_on(machine, wf, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))
    # on the farm-connected stage's job, which does need the token
    _reports(_pr(String("    permissions:\n      contents: read\n      id-token: write\n"), String("    permissions: write-all\n")), String("job 'pr': R4: `permissions: write-all` grants permissions no map names"))


def test_write_all_is_refused_at_the_pull_request_workflow_level() raises:
    var wf = _pr(String("permissions: {}\n"), String("permissions: write-all\n"))
    _reports(wf, String("workflow: R4: `permissions: write-all` grants permissions no map names"))
    _reports(wf, String("R4: `id-token: write` at the workflow level reaches every job"))


def test_write_all_is_refused_on_a_release_job() raises:
    var wf = _release(String("    environment: gamma\n    permissions:\n      id-token: write\n"), String("    environment: gamma\n    permissions: write-all\n"))
    _reports_on(String(_MACHINE), wf, String("job 'publish-gamma': R4: `permissions: write-all` grants permissions no map names"))


def test_read_all_and_an_empty_map_are_accepted() raises:
    _agrees(String(_MACHINE), _pr(String("permissions: {}\n"), String("permissions: read-all\n")))


def test_a_push_stage_never_carries_affected_by() raises:
    _reports(
        _release(String("kci run --stage build --summary-file"), String("kci run --stage build --affected-by ${{ github.event.pull_request.base.sha }} --summary-file")),
        String("job 'build': R6: `kci run` carries --affected-by, but stage 'build' is a PUSH stage"),
    )


def test_check_running_workflow_accepts_the_pull_request_workflow() raises:
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
    var f = check_running_workflow(g, files, String(_PR_WF), String("release/machine.textproto"))
    if len(f) != 0:
        raise Error(String("unexpected findings: ") + _all(f))
    var drift = check_running_workflow(
        g, files, _pr(String("${{ github.event.pull_request.base.sha }}"), String("HEAD~1")), String("release/machine.textproto")
    )
    assert_equal(len(drift), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
