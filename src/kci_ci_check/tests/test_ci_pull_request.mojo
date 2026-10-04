# =============================================================================
# src/kci_ci_check/tests/test_ci_pull_request.mojo -- R6 as amended: ONE
#   workflow runs the release stages and a pull request's per-change check.
#   On `pull_request` only the PULL_REQUEST stage's job runs (same-repository
#   pull requests only, no environment, `contents: read` and the farm
#   connection's token, the base commit, the full history); every release
#   job's `if:` keeps a pull request out. A workflow that agrees, then one
#   mutation per branch of the rule, each of which must be reported; and the
#   start-up entry point `kci run` calls.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_ci_check import ChannelsFile, check_running_workflow, check_workflow, excludes_pull_request, kci_run_calls
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

comptime _WF: String = (
    "name: kci\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "  pull_request:\n"
    "permissions: {}\n"
    "jobs:\n"
    "  build:\n"
    "    if: github.event_name != 'pull_request'\n"
    "    environment: build\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: ./.github/actions/farm-connect\n"
    "      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    "  publish-gamma:\n"
    "    needs: build\n"
    "    if: github.event_name != 'pull_request' && needs.build.outputs.release == 'true'\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - run: kci run --stage publish-gamma --plan --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
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


def _wf(old: String, new: String) raises -> String:
    var s = String(_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


# ---- the workflow that agrees --------------------------------------------------


def test_the_one_workflow_agrees() raises:
    _agrees(String(_MACHINE), String(_WF))


def test_without_a_pull_request_stage_the_workflow_has_no_pull_request_trigger() raises:
    var whole = String(_MACHINE)
    var cut = whole.find(String("stage { name: \"pr\""))
    var machine = String(whole[byte=0:cut])
    var wf = _wf(String("  pull_request:\n"), String(""))
    var pr_at = wf.find(String("  pr:\n"))
    _agrees(machine, String(wf[byte=0:pr_at]))


def test_the_affected_by_spellings_kci_accepts() raises:
    # quoted, `=`, and the spacing inside ${{ }} aside
    _agrees(String(_MACHINE), _wf(String("--affected-by ${{ github.event.pull_request.base.sha }}"), String("--affected-by \"${{ github.event.pull_request.base.sha }}\"")))
    _agrees(String(_MACHINE), _wf(String("--affected-by ${{ github.event.pull_request.base.sha }}"), String("--affected-by=${{github.event.pull_request.base.sha}}")))
    # the fork condition inside ${{ }}
    _agrees(
        String(_MACHINE),
        _wf(
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
    _reports(_wf(String("  pull_request:\n"), String("  pull_request_target:\n")), String("R6: trigger 'pull_request_target'"))
    _reports(
        _wf(String("  pull_request:\n"), String("  pull_request:\n  pull_request_target:\n")),
        String("R6: trigger 'pull_request_target': it runs a pull request's code with the base repository's secrets"),
    )


def test_pull_request_with_no_pull_request_stage_is_refused() raises:
    var machine = String(_MACHINE).replace(String(" trigger: PULL_REQUEST"), String(""))
    _reports_on(
        machine,
        String(_WF),
        String("R6: trigger 'pull_request': the machine file declares no PULL_REQUEST stage, and a release stage never runs a pull request's code"),
    )


def test_a_pull_request_stage_needs_the_pull_request_trigger() raises:
    _reports(
        _wf(String("  pull_request:\n"), String("")),
        String("R6: the machine file declares the PULL_REQUEST stage 'pr', so the workflow has a `pull_request` trigger"),
    )
    # and its job
    _reports(_wf(String("  pr:\n"), String("  check:\n")), String("R1: stage 'pr' has no job of the same id"))


def test_the_release_stays_on_push_and_dispatch() raises:
    # the workflow still releases: R7 holds with the pull_request trigger
    _reports(_wf(String("      revision:\n"), String("      rev:\n")), String("R7: workflow_dispatch takes no input `revision`"))


# ---- every release job keeps a pull request out ---------------------------------


def test_a_release_job_reachable_on_pull_request_is_refused() raises:
    var want = String("runs stage 'publish-gamma', a release stage, and the workflow is triggered by pull_request, so the job's `if:` keeps a pull request out")
    # no condition at all
    _reports(_wf(String("    if: github.event_name != 'pull_request' && needs.build.outputs.release == 'true'\n"), String("")), want)
    # a condition a pull request satisfies
    _reports(
        _wf(String("    if: github.event_name != 'pull_request' && needs.build.outputs.release == 'true'\n"), String("    if: needs.build.outputs.release == 'true'\n")),
        want,
    )
    # `||` is not read as release-only
    _reports(
        _wf(String("github.event_name != 'pull_request' && needs"), String("github.event_name != 'pull_request' || needs")),
        want,
    )
    # the event itself
    _reports(_wf(String("    if: github.event_name != 'pull_request'\n"), String("    if: github.event_name == 'pull_request'\n")), String("job 'build': R6: runs stage 'build', a release stage"))


def test_the_release_only_spellings() raises:
    assert_true(excludes_pull_request(String("github.event_name != 'pull_request'")))
    assert_true(excludes_pull_request(String("github.event_name != \"pull_request\"")))
    assert_true(excludes_pull_request(String("${{ github.event_name != 'pull_request' }}")))
    assert_true(excludes_pull_request(String("github.event_name == 'workflow_dispatch'")))
    assert_true(excludes_pull_request(String("needs.build.outputs.release == 'true' && github.event_name == 'push'")))
    assert_false(excludes_pull_request(String("github.event_name == 'pull_request'")))
    assert_false(excludes_pull_request(String("github.event_name == 'pull_request_target'")))
    assert_false(excludes_pull_request(String("github.event_name != 'push'")))
    assert_false(excludes_pull_request(String("always() || github.event_name != 'pull_request'")))
    assert_false(excludes_pull_request(String("!(github.event_name != 'pull_request')")))
    assert_false(excludes_pull_request(String("")))
    # a release job with the dispatch-only condition agrees
    _agrees(
        String(_MACHINE),
        _wf(String("github.event_name != 'pull_request' && needs.build.outputs.release == 'true'"), String("github.event_name == 'workflow_dispatch'")),
    )


def test_a_pull_request_stage_runs_whole_in_its_own_job() raises:
    var wf = String(_WF) + String(
        "  pr-part:\n    if: github.event.pull_request.head.repo.full_name == github.repository\n"
        "    steps:\n      - run: kci run --stage pr --only step:check --summary-file x\n"
    )
    _reports(wf, String("R6: job 'pr-part' runs a part of stage 'pr', a PULL_REQUEST stage, which runs whole in the job of its name"))


# ---- the pull request's job ------------------------------------------------------


def test_a_pull_request_job_runs_in_no_environment() raises:
    _reports(
        _wf(String("    runs-on: ubuntu-24.04\n"), String("    runs-on: ubuntu-24.04\n    environment: pr\n")),
        String("job 'pr': R2: stage 'pr' is a PULL_REQUEST stage, so its job runs in no environment"),
    )


def test_a_pull_request_job_never_runs_a_fork() raises:
    var want = String("R6: stage 'pr' is a PULL_REQUEST stage, so the job carries `if: github.event.pull_request.head.repo.full_name == github.repository`")
    _reports(_wf(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String("")), want)
    # another condition is not the fork condition
    _reports(_wf(String("== github.repository\n"), String("== github.repository || true\n")), want)
    _reports(
        _wf(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String("    if: github.event_name == 'pull_request'\n")),
        want,
    )
    _reports(_wf(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String("    if: always()\n")), want)


def test_a_pull_request_job_holds_minimal_permissions() raises:
    _reports(
        _wf(String("      contents: read\n      id-token: write\n"), String("      contents: read\n      id-token: write\n      pull-requests: write\n")),
        String("job 'pr': R6: stage 'pr' is a PULL_REQUEST stage, so its permissions hold only `contents: read` and, for the farm connection, `id-token: write`; it grants `pull-requests: write`"),
    )
    _reports(
        _wf(String("      contents: read\n      id-token: write\n"), String("      contents: write\n      id-token: write\n")),
        String("it grants `contents: write`"),
    )
    _reports(
        _wf(String("    permissions:\n      contents: read\n      id-token: write\n    steps:\n      - uses: actions/checkout"), String("    permissions: write-all\n    steps:\n      - uses: actions/checkout")),
        String("so its `permissions` is a mapping of `contents: read`"),
    )


def test_a_pull_request_job_passes_the_base_commit() raises:
    _reports(
        _wf(String("            --affected-by ${{ github.event.pull_request.base.sha }} \\\n"), String("")),
        String("job 'pr': R6: stage 'pr' is a PULL_REQUEST stage, so its `kci run` carries --affected-by ${{ github.event.pull_request.base.sha }}"),
    )
    _reports(
        _wf(String("${{ github.event.pull_request.base.sha }}"), String("origin/main")),
        String("R6: stage 'pr' is a PULL_REQUEST stage: `--affected-by origin/main`; it passes ${{ github.event.pull_request.base.sha }}"),
    )
    _reports(
        _wf(String("github.event.pull_request.base.sha"), String("github.event.pull_request.head.sha")),
        String("`--affected-by ${{ github.event.pull_request.head.sha }}`; it passes"),
    )


def test_a_pull_request_job_fetches_the_full_history() raises:
    _reports(
        _wf(String("        with:\n          fetch-depth: 0\n"), String("")),
        String("job 'pr': R6: its checkout has no `with: fetch-depth: 0`"),
    )
    _reports(
        _wf(String("          fetch-depth: 0\n"), String("          fetch-depth: 1\n")),
        String("job 'pr': R6: its checkout has no `with: fetch-depth: 0`"),
    )
    _reports(
        _wf(String("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          fetch-depth: 0\n"), String("")),
        String("so the job checks out the full history (`uses: actions/checkout@<sha>` with `fetch-depth: 0`); it has no checkout step"),
    )


def test_a_pull_request_stage_that_is_not_farm_connected() raises:
    # no farm connection, no identity token; the fork condition stays
    var machine = String(_MACHINE).replace(String("trigger: PULL_REQUEST farm_connected: true"), String("trigger: PULL_REQUEST"))
    var wf = _wf(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    wf = wf.replace(String("      contents: read\n      id-token: write\n"), String("      contents: read\n"))
    _agrees(machine, wf)
    # the identity token is the farm connection's only: refused here
    var token = wf.replace(String("      contents: read\n"), String("      contents: read\n      id-token: write\n"))
    _reports_on(machine, token, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel and is not farm-connected"))
    # and a fork still runs nothing
    _reports_on(
        machine,
        wf.replace(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String("")),
        String("so the job carries `if: github.event.pull_request.head.repo.full_name == github.repository`"),
    )


def test_a_farm_connected_pull_request_job_needs_its_token() raises:
    _reports(
        _wf(String("      contents: read\n      id-token: write\n"), String("      contents: read\n")),
        String("job 'pr': R4: stage 'pr' is farm-connected, so the job needs `id-token: write`"),
    )


def test_a_push_stage_never_carries_affected_by() raises:
    _reports(
        _wf(String("kci run --stage build --summary-file"), String("kci run --stage build --affected-by ${{ github.event.pull_request.base.sha }} --summary-file")),
        String("job 'build': R6: `kci run` carries --affected-by, but stage 'build' is a PUSH stage"),
    )


def test_check_running_workflow_accepts_the_workflow() raises:
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
    var f = check_running_workflow(g, files, String(_WF), String("release/machine.textproto"))
    if len(f) != 0:
        raise Error(String("unexpected findings: ") + _all(f))
    var drift = check_running_workflow(
        g, files, _wf(String("${{ github.event.pull_request.base.sha }}"), String("HEAD~1")), String("release/machine.textproto")
    )
    assert_equal(len(drift), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
