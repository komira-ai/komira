# =============================================================================
# src/kci_ci_check/tests/test_ci_pull_request.mojo -- R6 as amended: a pull
#   request's per-change check. A machine file with a PULL_REQUEST stage; a
#   pull request workflow that agrees with it and the release workflow that
#   agrees with it, then one mutation per branch of the rule, each of which
#   must be reported; and the start-up entry point `kci run` calls.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_ci_check import (
    NODE_SCALAR,
    ChannelsFile,
    WorkflowDoc,
    WorkflowNode,
    check_running_workflow,
    check_workflow,
    condition_expression,
    kci_run_calls,
)
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
    # an event off the allow-list is refused as such in a pull request workflow too
    _reports(
        _pr(String("  pull_request:\n"), String("  merge_group:\n  pull_request:\n")),
        String("R6: trigger 'merge_group': a workflow's triggers are push, workflow_dispatch and pull_request only"),
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


comptime _FORK_IF: String = "    if: github.event.pull_request.head.repo.full_name == github.repository\n"
comptime _FORK: String = "github.event.pull_request.head.repo.full_name == github.repository"


def _fork_if(value: String) raises -> String:
    """The pull request workflow with the fork condition's `if:` value
    replaced by `value` (written after `if:`, to its line's end)."""
    return _pr(String(_FORK_IF), String("    if: ") + value + String("\n"))


def test_the_fork_condition_is_exactly_one_expression() raises:
    # GitHub evaluates these as the fork condition itself
    _agrees(String(_MACHINE), _fork_if(String("${{ ") + String(_FORK) + String(" }}")))
    _agrees(String(_MACHINE), _fork_if(String("${{") + String(_FORK) + String("}}")))
    _agrees(String(_MACHINE), _fork_if(String("\"${{ ") + String(_FORK) + String(" }}\"")))
    _agrees(String(_MACHINE), _fork_if(String("'${{ ") + String(_FORK) + String(" }}'")))
    # YAML trims a plain scalar: a tab after it is not part of the value
    _agrees(String(_MACHINE), _fork_if(String("${{ ") + String(_FORK) + String(" }}\t")))
    _agrees(String(_MACHINE), _fork_if(String("\" ") + String(_FORK) + String(" \"")))
    # a block scalar with no `${{` is the expression itself
    _agrees(String(_MACHINE), _fork_if(String("|-\n      ") + String(_FORK)))
    _agrees(String(_MACHINE), _fork_if(String("|\n      ") + String(_FORK)))


def test_a_fork_condition_github_reads_as_a_format_string_is_refused() raises:
    # Each of these holds `${{` and is not exactly `${{ <it> }}`: GitHub
    # reads it as a format string, always true, so a fork's pull request
    # (or a push, or a manual run) runs the job.
    var expr = String("${{ ") + String(_FORK) + String(" }}")
    var values = List[String]()
    values.append(String("|\n      ") + expr)
    values.append(String(">\n      ") + expr)
    values.append(String("|+\n      ") + expr)
    values.append(String("|-\n      ") + expr)
    values.append(String(">-\n      ") + expr)
    values.append(String(">+\n      ") + expr)
    values.append(String("\" ") + expr + String("\""))
    values.append(String("\"") + expr + String(" \""))
    values.append(String("' ") + expr + String("'"))
    values.append(String("'") + expr + String(" '"))
    values.append(String("\"") + expr + String("\t\""))
    values.append(String("x") + expr)
    values.append(expr + String(" && ${{ true }}"))
    for i in range(len(values)):
        try:
            _reports(
                _fork_if(values[i]),
                String("R6: stage 'pr' is a PULL_REQUEST stage and farm-connected, so the job carries `if: ") + String(_FORK),
            )
        except e:
            raise Error(String("`if: ") + values[i] + String("`: ") + String(e))


def test_a_fork_condition_carried_past_its_line_is_cannot_tell() raises:
    # `''` is an escaped quote: the scalar does not close on the `if:` line,
    # YAML carries it on to the next, and the condition GitHub reads is not
    # the one on the line.
    _cannot_tell(
        String(_MACHINE),
        _fork_if(String("'") + String(_FORK) + String(" ''\n    || ''a: b'''")),
        String("a quoted scalar not closed on its line"),
    )
    _cannot_tell(
        String(_MACHINE),
        _fork_if(String("'${{ ") + String(_FORK) + String(" }}''\n    || ''a: b'''")),
        String("a quoted scalar not closed on its line"),
    )


def _expression(text: String, block: Bool) -> Tuple[Bool, String]:
    var d = WorkflowDoc()
    var n = d.add(WorkflowNode(NODE_SCALAR, text.copy(), 1, not block, block))
    var e = String("")
    var ok = condition_expression(d, n, e)
    return (ok, e^)


def test_condition_expression_refuses_every_block_scalar_holding_an_expression() raises:
    # A block scalar's value is refused when it holds `${{`, even when its
    # text (as a reader that drops the indentation would give it) is
    # exactly `${{ <it> }}`; one with no `${{` is the expression itself.
    var expr = String("${{ ") + String(_FORK) + String(" }}")
    assert_false(_expression(expr, True)[0])
    assert_false(_expression(String("x == '${{'"), True)[0])
    var bare = _expression(String(_FORK), True)
    assert_true(bare[0])
    assert_equal(bare[1], String(_FORK))
    var quoted = _expression(expr, False)
    assert_true(quoted[0])
    assert_equal(quoted[1], String(_FORK))
    # exactly one `${{ }}`, nothing around it
    assert_false(_expression(expr + String(" "), False)[0])
    assert_false(_expression(String(" ") + expr, False)[0])
    assert_false(_expression(expr + String("\n"), False)[0])
    assert_false(_expression(String("${{ a }} && ${{ b }}"), False)[0])
    assert_false(_expression(String("${{ a == '}}' }}"), False)[0])
    assert_false(_expression(String("${{ a == '${{' }}"), False)[0])
    assert_false(_expression(String("${{ a"), False)[0])
    var spaced = _expression(String("  ") + String(_FORK) + String(" "), False)
    assert_true(spaced[0])
    assert_equal(spaced[1], String(_FORK))
    # not a scalar
    var d = WorkflowDoc()
    var m = d.add(WorkflowNode(0, String(""), 1))
    var e = String("")
    assert_false(condition_expression(d, m, e))
    assert_false(condition_expression(d, -1, e))


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


def _not_farm_connected() raises -> Tuple[String, String]:
    """The pull request stage without the farm connection, and its workflow:
    no condition, no farm connection, no identity token."""
    var machine = String(_MACHINE).replace(String("trigger: PULL_REQUEST farm_connected: true"), String("trigger: PULL_REQUEST"))
    var wf = _pr(String("    if: github.event.pull_request.head.repo.full_name == github.repository\n"), String(""))
    wf = wf.replace(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    wf = wf.replace(String("      id-token: write\n"), String(""))
    return (machine^, wf^)


def _block_styles() -> List[String]:
    var s = List[String]()
    s.append(String("|-"))
    s.append(String(">"))
    s.append(String(">-"))
    return s^


def test_an_id_token_block_scalar_is_a_grant_on_a_pull_request_job() raises:
    # a block scalar's value is `write` once folded: it grants the token
    var base = _not_farm_connected()
    var styles = _block_styles()
    for i in range(len(styles)):
        var wf = base[1].replace(
            String("      contents: read\n"), String("      contents: read\n      id-token: ") + styles[i] + String("\n        write\n")
        )
        _reports_on(base[0], wf, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))


def test_an_id_token_block_scalar_is_a_grant_at_the_pull_request_workflow_level() raises:
    var base = _not_farm_connected()
    var styles = _block_styles()
    for i in range(len(styles)):
        var wf = base[1].replace(
            String("permissions: {}\n"), String("permissions:\n  id-token: ") + styles[i] + String("\n    write\n")
        )
        _reports_on(base[0], wf, String("R4: `id-token: write` at the workflow level reaches every job"))


def test_an_id_token_block_scalar_is_a_grant_in_the_release_workflow() raises:
    # `build` without the farm connection needs no token
    var machine = String(_MACHINE).replace(String("stage { name: \"build\" farm_connected: true"), String("stage { name: \"build\""))
    var styles = _block_styles()
    for i in range(len(styles)):
        var job = _release(
            String("    environment: build\n    permissions:\n      id-token: write\n    steps:\n      - uses: ./.github/actions/farm-connect\n"),
            String("    environment: build\n    permissions:\n      id-token: ") + styles[i] + String("\n        write\n    steps:\n"),
        )
        _reports_on(machine, job, String("job 'build': R4: has `id-token: write`, but stage 'build' publishes to no OIDC channel"))
        var top = _release(String("permissions: {}\n"), String("permissions:\n  id-token: ") + styles[i] + String("\n    write\n"))
        _reports(top, String("R4: `id-token: write` at the workflow level reaches every job"))


def test_only_a_plain_read_or_none_withholds_the_id_token() raises:
    var base = _not_farm_connected()
    # plain `read` and `none` grant nothing
    _agrees(base[0], base[1].replace(String("      contents: read\n"), String("      contents: read\n      id-token: read\n")))
    _agrees(base[0], base[1].replace(String("      contents: read\n"), String("      contents: read\n      id-token: none\n")))
    # anything else is a grant: quoted, a block scalar of `read`, a mapping, empty
    var others = List[String]()
    others.append(String("'read'\n"))
    others.append(String("\"none\"\n"))
    others.append(String("|\n        read\n"))
    others.append(String("{}\n"))
    others.append(String("\n"))
    for i in range(len(others)):
        var wf = base[1].replace(String("      contents: read\n"), String("      contents: read\n      id-token: ") + others[i])
        _reports_on(base[0], wf, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))


def test_a_permissions_scalar_other_than_plain_read_all_is_refused() raises:
    var others = List[String]()
    others.append(String("'read-all'\n"))
    others.append(String("|-\n  read-all\n"))
    others.append(String(">-\n  write-all\n"))
    for i in range(len(others)):
        var wf = _pr(String("permissions: {}\n"), String("permissions: ") + others[i])
        _reports(wf, String("workflow: R4: `permissions: "))
        _reports(wf, String("R4: `id-token: write` at the workflow level reaches every job"))


def _cannot_tell(machine: String, wf: String, needle: String) raises:
    try:
        var f = _check(machine, wf)
        raise Error(String("read, expected cannot tell: ") + needle + String("; findings: ") + _all(f))
    except e:
        var m = String(e)
        if not m.startswith(String("cannot tell: ")) or m.find(needle) < 0:
            raise Error(String("expected 'cannot tell: ...") + needle + String("', got: ") + m)


def _job_perms(wf: String, entry: String) -> String:
    """`wf` (the not-farm-connected pull request workflow) with `entry` added
    to job 'pr''s permissions."""
    return wf.replace(String("      contents: read\n"), String("      contents: read\n      ") + entry + String("\n"))


def _top_perms(wf: String, entry: String) -> String:
    """`wf` with workflow-level permissions holding `entry`."""
    return wf.replace(String("permissions: {}\n"), String("permissions:\n  ") + entry + String("\n"))


def test_an_escape_in_a_double_quoted_permissions_key_is_cannot_tell() raises:
    # `"id\x2dtoken": write` is `id-token: write` once the escape is decoded
    var base = _not_farm_connected()
    var keys = List[String]()
    keys.append(String("\"id\\x2dtoken\": write"))
    keys.append(String("\"id\\x2Dtoken\": write"))
    keys.append(String("\"id\\u002dtoken\": write"))
    for i in range(len(keys)):
        _cannot_tell(base[0], _job_perms(base[1], keys[i]), String("an escape in a double-quoted key"))
        _cannot_tell(base[0], _top_perms(base[1], keys[i]), String("an escape in a double-quoted key"))
    # `"permi\x73sions": write-all` is `permissions: write-all`
    var wa = String("\"permi\\x73sions\": write-all\n")
    _cannot_tell(
        base[0], base[1].replace(String("    permissions:\n      contents: read\n"), String("    ") + wa), String("an escape in a double-quoted key")
    )
    _cannot_tell(base[0], base[1].replace(String("permissions: {}\n"), wa), String("an escape in a double-quoted key"))


def test_a_merge_key_in_permissions_is_cannot_tell() raises:
    var base = _not_farm_connected()
    var job = base[1].replace(String("      contents: read\n"), String("      contents: read\n      <<:\n        id-token: write\n"))
    _cannot_tell(base[0], job, String("merge key"))
    var top = base[1].replace(String("permissions: {}\n"), String("permissions:\n  contents: read\n  <<:\n    id-token: write\n"))
    _cannot_tell(base[0], top, String("merge key"))


def test_an_id_token_key_in_another_case_is_refused() raises:
    var base = _not_farm_connected()
    var keys = List[String]()
    keys.append(String("Id-Token: write"))
    keys.append(String("ID-TOKEN: write"))
    keys.append(String("id-Token: read"))
    for i in range(len(keys)):
        var job = _job_perms(base[1], keys[i])
        _reports_on(base[0], job, String("job 'pr': R4: permissions key '"))
        _reports_on(base[0], job, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))
        var top = _top_perms(base[1], keys[i])
        _reports_on(base[0], top, String("workflow: R4: permissions key '"))
        _reports_on(base[0], top, String("R4: `id-token: write` at the workflow level reaches every job"))


def test_permissions_keys_that_differ_only_in_case_are_refused() raises:
    var base = _not_farm_connected()
    _reports_on(base[0], _job_perms(base[1], String("Contents: write")), String("job 'pr': R4: permissions keys 'contents' and 'Contents'"))
    _reports_on(
        base[0], _top_perms(base[1], String("contents: read\n  CONTENTS: write")), String("workflow: R4: permissions keys 'contents' and 'CONTENTS'")
    )


def test_a_permissions_key_in_another_case_is_refused() raises:
    var base = _not_farm_connected()
    var job = base[1].replace(String("    permissions:\n      contents: read\n"), String("    Permissions: write-all\n"))
    _reports_on(base[0], job, String("job 'pr': R4: key 'Permissions' is `permissions` in another case"))
    var top = base[1].replace(String("permissions: {}\n"), String("PERMISSIONS: write-all\n"))
    _reports_on(base[0], top, String("workflow: R4: key 'PERMISSIONS' is `permissions` in another case"))


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
