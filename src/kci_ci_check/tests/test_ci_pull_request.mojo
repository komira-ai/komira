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

from kci_ci_check import (
    NODE_SCALAR,
    ChannelsFile,
    WorkflowDoc,
    WorkflowNode,
    check_running_workflow,
    check_workflow,
    check_workflow_doc,
    condition_expression,
    excludes_pull_request,
    kci_run_calls,
    read_workflow,
)
from kci_release_machine import parse_machine_file


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" farm_connected: true break_glass: true\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"publish-gamma\" environment: \"gamma\" after: \"build\" break_glass: true\n"
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
    "    paths-ignore:\n"
    "      - 'docs/**'\n"
    "      - '**.md'\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "      reason:\n"
    "        type: string\n"
    "        required: true\n"
    "      dry_run:\n"
    "        type: boolean\n"
    "        default: false\n"
    "  pull_request:\n"
    "permissions: {}\n"
    "concurrency:\n"
    "  group: kci-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number)"
    " || github.event_name == 'push' && github.ref == 'refs/heads/main' && 'release-main' || inputs.dry_run && format('plan-{0}', github.run_id) || format('ref-{0}', github.ref_name) }}\n"
    "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n"
    "jobs:\n"
    "  build:\n"
    "    if: github.event_name != 'pull_request'\n"
    "    outputs:\n"
    "      set_hash: ${{ steps.kci.outputs.set_hash }}\n"
    "    environment: build\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          ref: ${{ env.REVISION }}\n"
    "      - name: the revision this run releases\n"
    "        run: |\n"
    "          case \"$REVISION\" in\n"
    "            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n"
    "          esac\n"
    "          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n"
    "          if [ \"$GITHUB_EVENT_NAME\" = push ]; then\n"
    "            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"
    "              { echo \"refused: a push releases the commit it pushed ($GITHUB_SHA), not $REVISION\"; exit 1; }\n"
    "          else\n"
    "            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n"
    "              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n"
    "          fi\n"
    "      - uses: ./.github/actions/farm-connect\n"
    "      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    "      - name: the prod line\n"
    "        if: always()\n"
    "        run: echo prod line\n"
    "  publish-gamma:\n"
    "    needs: build\n"
    "    if: github.event_name != 'pull_request' && needs.build.outputs.release == 'true'\n"
    "    env:\n"
    "      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          ref: ${{ env.REVISION }}\n"
    "      - name: the revision this run releases\n"
    "        run: |\n"
    "          case \"$REVISION\" in\n"
    "            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n"
    "          esac\n"
    "          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n"
    "          if [ \"$GITHUB_EVENT_NAME\" = push ]; then\n"
    "            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"
    "              { echo \"refused: a push releases the commit it pushed ($GITHUB_SHA), not $REVISION\"; exit 1; }\n"
    "          else\n"
    "            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n"
    "              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n"
    "          fi\n"
    "      - run: kci run --stage publish-gamma --plan --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"
    "      - name: the prod line\n"
    "        if: always()\n"
    "        run: echo prod line\n"
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


def _other_triggers() -> List[String]:
    """Events other than push, workflow_dispatch and pull_request. A release
    job's `github.event_name != 'pull_request'` does not keep out the first
    six: each can run a pull request's code (a review or a comment on it, a
    merge-queue candidate, a calling workflow's event, the code workflow_run
    follows). schedule is off the allow-list too."""
    var t = List[String]()
    t.append(String("pull_request_review"))
    t.append(String("pull_request_review_comment"))
    t.append(String("issue_comment"))
    t.append(String("workflow_run"))
    t.append(String("merge_group"))
    t.append(String("workflow_call"))
    t.append(String("schedule"))
    return t^


def test_an_event_off_the_allow_list_is_refused() raises:
    var others = _other_triggers()
    for i in range(len(others)):
        var name = others[i].copy()
        _reports(
            _wf(String("  pull_request:\n"), String("  pull_request:\n  ") + name + String(":\n")),
            String("R6: trigger '") + name + String("': a workflow's triggers are push, workflow_dispatch and pull_request only"),
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


def test_an_event_name_term_is_read_exactly() raises:
    # accepted: `github.event_name` then `!=` or `==`, then one single-quoted
    # literal of [a-z_]+, then nothing
    assert_true(excludes_pull_request(String("github.event_name=='push'")))
    assert_true(excludes_pull_request(String("github.event_name  !=  'pull_request'")))
    # GitHub compares strings case-insensitively: a literal in another case is
    # not read, whichever operator it follows
    assert_false(excludes_pull_request(String("github.event_name == 'PULL_REQUEST'")))
    assert_false(excludes_pull_request(String("github.event_name == 'Pull_Request'")))
    assert_false(excludes_pull_request(String("github.event_name != 'PULL_REQUEST'")))
    assert_false(excludes_pull_request(String("github.event_name == 'PUSH'")))
    # nothing after the literal: an operator inside what looked like one literal
    assert_false(excludes_pull_request(String("github.event_name == 'push' != 'x'")))
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' == 'x'")))
    assert_false(excludes_pull_request(String("github.event_name == 'push')")))
    assert_false(excludes_pull_request(String("github.event_name == 'push'x")))
    # a GitHub literal is single-quoted; a double-quoted one is not read
    assert_false(excludes_pull_request(String("github.event_name != \"pull_request\"")))
    assert_false(excludes_pull_request(String("github.event_name == \"push\"")))
    # the literal is [a-z_]+ only
    assert_false(excludes_pull_request(String("github.event_name == 'pu-sh'")))
    assert_false(excludes_pull_request(String("github.event_name == 'pu sh'")))
    assert_false(excludes_pull_request(String("github.event_name == ''")))
    assert_false(excludes_pull_request(String("github.event_name != ''")))
    # `==` is read only for push and workflow_dispatch
    assert_false(excludes_pull_request(String("github.event_name == 'release'")))
    assert_false(excludes_pull_request(String("github.event_name == 'schedule'")))
    assert_false(excludes_pull_request(String("github.event_name == 'pull_request_review'")))
    # no other operator, no other left-hand side
    assert_false(excludes_pull_request(String("github.event_name <= 'pull_request'")))
    assert_false(excludes_pull_request(String("github.event_name <= 'push'")))
    assert_false(excludes_pull_request(String("github.event_name = 'push'")))
    assert_false(excludes_pull_request(String("github.event_names != 'pull_request'")))
    assert_false(excludes_pull_request(String("GITHUB.EVENT_NAME == 'push'")))


def test_a_release_job_condition_in_another_case_is_refused() raises:
    var want = String("runs stage 'publish-gamma', a release stage, and the workflow is triggered by pull_request, so the job's `if:` keeps a pull request out")
    var old = String("github.event_name != 'pull_request' && needs")
    _reports(_wf(old, String("github.event_name == 'PULL_REQUEST' && needs")), want)
    _reports(_wf(old, String("github.event_name == 'Pull_Request' && needs")), want)


def test_a_release_job_condition_with_an_operator_in_the_literal_is_refused() raises:
    var want = String("runs stage 'publish-gamma', a release stage, and the workflow is triggered by pull_request, so the job's `if:` keeps a pull request out")
    var old = String("github.event_name != 'pull_request' && needs")
    _reports(_wf(old, String("github.event_name == 'push' != 'x' && needs")), want)
    _reports(_wf(old, String("github.event_name == 'release' && needs")), want)


# The probes: each holds the exact event term between two `&&`, and each is
# TRUE on a pull request in GitHub. Only a top-level conjunction is read.
def _probes() -> List[String]:
    var p = List[String]()
    p.append(String("!(true && github.event_name != 'pull_request' && true)"))
    p.append(String("toJSON(true && github.event_name != 'pull_request' && true)"))
    p.append(String("format('{0}', true && github.event_name != 'pull_request' && true)"))
    p.append(String("(needs.build.outputs.release == 'true' && github.event_name != 'pull_request' && true) == false"))
    p.append(String("contains('ab', 'c') == (true && github.event_name != 'pull_request' && true)"))
    p.append(String("${{ !(true && github.event_name != 'pull_request' && true) }}"))
    # a partial `${{ }}` makes the whole `if:` a format() string, always truthy
    p.append(String("github.event_name != 'pull_request' && ${{ true }}"))
    p.append(String("github.event_name != 'pull_request' && '${{ github.sha }}' != ''"))
    return p^


def test_only_a_top_level_conjunction_is_read() raises:
    var probes = _probes()
    for i in range(len(probes)):
        if excludes_pull_request(probes[i]):
            raise Error(String("read as release-only: ") + probes[i])
    # no grouping, negation, call, index or object filter anywhere
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' && (true)")))
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' && !false")))
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' && always()")))
    assert_false(excludes_pull_request(String("github[true && github.event_name != 'pull_request' && true] == null")))
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' && github.*.x")))
    # one outer `${{ }}` at most, and no other `${{` or `}}`, even in a literal
    assert_false(excludes_pull_request(String("${{ github.event_name != 'pull_request' }} && ${{ true }}")))
    assert_false(excludes_pull_request(String("${{ github.event_name != 'pull_request' && '}}' == 'x' }}")))
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' && '${{' == 'x'")))
    # an opening `${{` with no closing `}}` is no wrapper
    assert_false(excludes_pull_request(String("${{ github.event_name != 'pull_request' && truexx")))
    # an unterminated literal
    assert_false(excludes_pull_request(String("github.event_name != 'pull_request' && 'x")))
    # `&&` and parentheses inside a literal are literal text
    assert_true(excludes_pull_request(String("needs.a.outputs.b == 'x && (y)' && github.event_name != 'pull_request'")))
    assert_true(excludes_pull_request(String("needs.a.outputs.b == 'it''s' && github.event_name == 'push'")))
    assert_true(excludes_pull_request(String("${{ github.event_name != 'pull_request' && needs.a.outputs.n >= 2 }}")))


def test_a_release_job_condition_that_is_not_a_top_level_conjunction_is_refused() raises:
    var want = String("runs stage 'publish-gamma', a release stage, and the workflow is triggered by pull_request, so the job's `if:` keeps a pull request out")
    var old = String("    if: github.event_name != 'pull_request' && needs.build.outputs.release == 'true'\n")
    var probes = _probes()
    for i in range(len(probes)):
        # double-quoted: a plain scalar starting with `!` is a YAML tag (no probe
        # holds a `"` or a backslash)
        _reports(_wf(old, String("    if: \"") + probes[i] + String("\"\n")), want)
    # every release job behind the negated conjunction: each is reported
    var neg = String("    if: (true && github.event_name != 'pull_request' && needs.build.outputs.release == 'true') == false\n")
    var wf = _wf(old, neg)
    var build_old = String("    if: github.event_name != 'pull_request'\n")
    if wf.find(build_old) < 0:
        raise Error(String("fixture has no build condition"))
    wf = wf.replace(build_old, neg)
    _reports(wf, want)
    _reports(wf, String("job 'build': R6: runs stage 'build', a release stage"))


comptime _BUILD_IF: String = "    if: github.event_name != 'pull_request'\n"
comptime _GAMMA_IF: String = "    if: github.event_name != 'pull_request' && needs.build.outputs.release == 'true'\n"
comptime _BUILD_EXPR: String = "${{ github.event_name != 'pull_request' }}"
comptime _GAMMA_EXPR: String = "${{ github.event_name != 'pull_request' && needs.build.outputs.release == 'true' }}"


def _format_strings(expr: String) -> List[String]:
    """`if:` values (written after `if:`, to the line's end) inside the
    subset the reader reads that hold `expr` and are not exactly it: a space
    inside quotes around it, text before it, a second `${{ }}`. GitHub reads
    each as a format string, always true."""
    var v = List[String]()
    v.append(String("\" ") + expr + String("\""))
    v.append(String("\"") + expr + String(" \""))
    v.append(String("x") + expr)
    v.append(expr + String(" && ${{ true }}"))
    return v^


def _reports_each(old: String, values: List[String], needle: String) raises:
    for i in range(len(values)):
        try:
            _reports(_wf(old, String("    if: ") + values[i] + String("\n")), needle)
        except e:
            raise Error(String("`if: ") + values[i] + String("`: ") + String(e))


def test_a_release_job_condition_github_reads_as_a_format_string_is_refused() raises:
    _reports_each(
        String(_BUILD_IF), _format_strings(String(_BUILD_EXPR)), String("job 'build': R6: runs stage 'build', a release stage")
    )
    _reports_each(
        String(_GAMMA_IF),
        _format_strings(String(_GAMMA_EXPR)),
        String("job 'publish-gamma': R6: runs stage 'publish-gamma', a release stage"),
    )
    # the string reader alone: whitespace around one `${{ }}` is a format string
    assert_false(excludes_pull_request(String(_BUILD_EXPR) + String(" ")))
    assert_false(excludes_pull_request(String(" ") + String(_BUILD_EXPR)))
    assert_false(excludes_pull_request(String(_BUILD_EXPR) + String("\t")))
    assert_false(excludes_pull_request(String(_BUILD_EXPR) + String("\n")))


def _outside_the_subset(expr: String) -> List[Tuple[String, String]]:
    """`if:` values holding `expr` written outside the subset the reader
    reads, each with what the reader says: block scalars (any style), a TAB,
    a single-quoted scalar carried past its line by `''`."""
    var v = List[Tuple[String, String]]()
    for h in ["|", "|-", "|+", ">", ">-", ">+"]:
        v.append((String(h) + String("\n      ") + expr, String("block scalar")))
    v.append((expr + String("\t"), String("a TAB")))
    v.append((String("\"") + expr + String("\t\""), String("a TAB")))
    v.append((String("\"\t") + expr + String("\""), String("a TAB")))
    v.append((String("'") + expr.replace(String("'"), String("''")) + String("''\n    || ''a: b''") + String("'"), String("an escaped quote")))
    return v^


def test_a_job_condition_outside_the_subset_is_cannot_tell() raises:
    var conds = List[Tuple[String, String]]()
    conds.append((String(_BUILD_IF), String(_BUILD_EXPR)))
    conds.append((String(_GAMMA_IF), String(_GAMMA_EXPR)))
    conds.append((String(_FORK_IF), String("${{ ") + String(_FORK) + String(" }}")))
    conds.append((String(_BUILD_IF), String("github.event_name != 'pull_request'")))
    conds.append((String(_FORK_IF), String(_FORK)))
    for c in range(len(conds)):
        var values = _outside_the_subset(conds[c][1])
        for i in range(len(values)):
            try:
                _cannot_tell(String(_MACHINE), _wf(conds[c][0], String("    if: ") + values[i][0] + String("\n")), values[i][1])
            except e:
                raise Error(String("`if: ") + values[i][0] + String("`: ") + String(e))


def _block_if_findings(job: String, old: String, expr: String, block: Bool) raises -> List[String]:
    """The findings on the workflow whose job `job` has `if:` holding exactly
    `expr` (read double-quoted), with that node's block flag set to `block`:
    the reader never builds a block `if:`, so the rule's own guard is held
    on a document built so."""
    var doc = read_workflow(_wf(old, String("    if: \"") + expr + String("\"\n")))
    var cond = doc.child(doc.child(doc.child(0, String("jobs")), String(job)), String("if"))
    if cond < 0 or doc.text(cond) != expr:
        raise Error(String("no `if:` holding the expression on job ") + job)
    doc.nodes[cond].block = block
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    return check_workflow_doc(doc, g, _tokens(), String("release/machine.textproto"))


def _has(f: List[String], needle: String) -> Bool:
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return True
    return False


def test_the_block_scalar_is_refused_by_its_style_not_its_indentation() raises:
    # The block flag alone refuses each condition: with the text exactly
    # `${{ <it> }}`, the same node read as a quoted scalar agrees.
    var cases = List[Tuple[String, String, String, String]]()
    cases.append((String("build"), String(_BUILD_IF), String(_BUILD_EXPR), String("job 'build': R6: runs stage 'build', a release stage")))
    cases.append((String("publish-gamma"), String(_GAMMA_IF), String(_GAMMA_EXPR), String("job 'publish-gamma': R6: runs stage 'publish-gamma', a release stage")))
    cases.append((String("pr"), String(_FORK_IF), String("${{ ") + String(_FORK) + String(" }}"), String("R6: stage 'pr' is a PULL_REQUEST stage, so the job carries `if: ")))
    for i in range(len(cases)):
        var job = cases[i][0]
        assert_true(_has(_block_if_findings(job, cases[i][1], cases[i][2], True), cases[i][3]), job)
        var quoted = _block_if_findings(job, cases[i][1], cases[i][2], False)
        if len(quoted) != 0:
            raise Error(job + String(": unexpected findings: ") + _all(quoted))


def test_a_release_job_condition_that_is_exactly_one_expression_agrees() raises:
    _agrees(String(_MACHINE), _wf(String(_BUILD_IF), String("    if: ") + String(_BUILD_EXPR) + String("\n")))
    _agrees(String(_MACHINE), _wf(String(_GAMMA_IF), String("    if: \"") + String(_GAMMA_EXPR) + String("\"\n")))
    # a trailing comment is not part of the value
    _agrees(String(_MACHINE), _wf(String(_BUILD_IF), String("    if: ") + String(_BUILD_EXPR) + String(" # release only\n")))


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


comptime _FORK_IF: String = "    if: github.event.pull_request.head.repo.full_name == github.repository\n"
comptime _FORK: String = "github.event.pull_request.head.repo.full_name == github.repository"


def test_the_fork_condition_is_exactly_one_expression() raises:
    var expr = String("${{ ") + String(_FORK) + String(" }}")
    _agrees(String(_MACHINE), _wf(String(_FORK_IF), String("    if: ") + expr + String("\n")))
    _agrees(String(_MACHINE), _wf(String(_FORK_IF), String("    if: ${{") + String(_FORK) + String("}}\n")))
    _agrees(String(_MACHINE), _wf(String(_FORK_IF), String("    if: \"") + expr + String("\"\n")))
    _agrees(String(_MACHINE), _wf(String(_FORK_IF), String("    if: '") + expr + String("'\n")))
    _agrees(String(_MACHINE), _wf(String(_FORK_IF), String("    if: \" ") + String(_FORK) + String(" \"\n")))


def test_a_fork_condition_github_reads_as_a_format_string_is_refused() raises:
    # always true on GitHub: a fork's pull request, a push or a manual run
    # would run the job
    var expr = String("${{ ") + String(_FORK) + String(" }}")
    var values = _format_strings(expr)
    values.append(String("' ") + expr + String("'"))
    values.append(String("'") + expr + String(" '"))
    _reports_each(
        String(_FORK_IF),
        values,
        String("R6: stage 'pr' is a PULL_REQUEST stage, so the job carries `if: ") + String(_FORK),
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


def test_write_all_is_refused_on_a_pull_request_job() raises:
    # `write-all` grants `id-token: write` with no map entry naming it
    var machine = String(_MACHINE).replace(String("trigger: PULL_REQUEST farm_connected: true"), String("trigger: PULL_REQUEST"))
    var wf = _wf(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    wf = wf.replace(String("    permissions:\n      contents: read\n      id-token: write\n"), String("    permissions: write-all\n"))
    _reports_on(machine, wf, String("job 'pr': R4: `permissions: write-all` grants permissions no map names"))
    _reports_on(machine, wf, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))
    # on the farm-connected stage's job, which does need the token
    _reports(_wf(String("    permissions:\n      contents: read\n      id-token: write\n"), String("    permissions: write-all\n")), String("job 'pr': R4: `permissions: write-all` grants permissions no map names"))


def test_write_all_is_refused_at_the_workflow_level() raises:
    var wf = _wf(String("permissions: {}\n"), String("permissions: write-all\n"))
    _reports(wf, String("workflow: R4: `permissions: write-all` grants permissions no map names"))
    _reports(wf, String("R4: `id-token: write` at the workflow level reaches every job"))


def test_write_all_is_refused_on_a_release_job() raises:
    var wf = _wf(String("    environment: gamma\n    permissions:\n      id-token: write\n"), String("    environment: gamma\n    permissions: write-all\n"))
    _reports_on(String(_MACHINE), wf, String("job 'publish-gamma': R4: `permissions: write-all` grants permissions no map names"))


def _not_farm_connected() raises -> Tuple[String, String]:
    """The pull request stage without the farm connection, and its workflow:
    the pr job keeps its fork condition (every pull request job carries it)
    and loses the farm connection and its identity token; the release jobs
    are unchanged."""
    var machine = String(_MACHINE).replace(String("trigger: PULL_REQUEST farm_connected: true"), String("trigger: PULL_REQUEST"))
    var wf = _wf(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    wf = wf.replace(String("      contents: read\n      id-token: write\n"), String("      contents: read\n"))
    return (machine^, wf^)


def _block_styles() -> List[String]:
    var s = List[String]()
    s.append(String("|-"))
    s.append(String(">"))
    s.append(String(">-"))
    return s^


def test_an_id_token_block_scalar_on_a_pull_request_job_is_cannot_tell() raises:
    # a block scalar's value is `write` once folded: outside the subset
    var base = _not_farm_connected()
    var styles = _block_styles()
    for i in range(len(styles)):
        var wf = base[1].replace(
            String("      contents: read\n"), String("      contents: read\n      id-token: ") + styles[i] + String("\n        write\n")
        )
        _cannot_tell(base[0], wf, String("block scalar"))


def test_an_id_token_block_scalar_at_the_workflow_level_is_cannot_tell() raises:
    var base = _not_farm_connected()
    var styles = _block_styles()
    for i in range(len(styles)):
        var wf = base[1].replace(
            String("permissions: {}\n"), String("permissions:\n  id-token: ") + styles[i] + String("\n    write\n")
        )
        _cannot_tell(base[0], wf, String("block scalar"))


def test_an_id_token_block_scalar_on_a_release_job_is_cannot_tell() raises:
    # `build` without the farm connection needs no token
    var machine = String(_MACHINE).replace(String("stage { name: \"build\" farm_connected: true"), String("stage { name: \"build\""))
    var styles = _block_styles()
    for i in range(len(styles)):
        var job = _wf(
            String("    environment: build\n    permissions:\n      id-token: write\n    steps:\n"),
            String("    environment: build\n    permissions:\n      id-token: ") + styles[i] + String("\n        write\n    steps:\n"),
        )
        _cannot_tell(machine, job, String("block scalar"))


def test_only_a_plain_read_or_none_withholds_the_id_token() raises:
    var base = _not_farm_connected()
    # plain `read` and `none` grant nothing
    _agrees(base[0], base[1].replace(String("      contents: read\n"), String("      contents: read\n      id-token: read\n")))
    _agrees(base[0], base[1].replace(String("      contents: read\n"), String("      contents: read\n      id-token: none\n")))
    # anything else is a grant: quoted, a mapping, empty (a block scalar is
    # outside the subset: cannot tell)
    var others = List[String]()
    others.append(String("'read'\n"))
    others.append(String("\"none\"\n"))
    others.append(String("{}\n"))
    others.append(String("\n"))
    for i in range(len(others)):
        var wf = base[1].replace(String("      contents: read\n"), String("      contents: read\n      id-token: ") + others[i])
        _reports_on(base[0], wf, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))


def test_a_permissions_scalar_other_than_plain_read_all_is_refused() raises:
    var others = List[String]()
    others.append(String("'read-all'\n"))
    others.append(String("\"read-all\"\n"))
    others.append(String("Read-All\n"))
    others.append(String("write-all\n"))
    for i in range(len(others)):
        var wf = _wf(String("permissions: {}\n"), String("permissions: ") + others[i])
        _reports(wf, String("workflow: R4: `permissions: "))
        _reports(wf, String("R4: `id-token: write` at the workflow level reaches every job"))
    # a list is no permissions form at all
    _reports(_wf(String("permissions: {}\n"), String("permissions: [write-all]\n")), String("workflow: R4: `permissions:` is a list"))
    # a block scalar is outside the subset
    _cannot_tell(String(_MACHINE), _wf(String("permissions: {}\n"), String("permissions: |-\n  read-all\n")), String("block scalar"))
    _cannot_tell(String(_MACHINE), _wf(String("permissions: {}\n"), String("permissions: >-\n  write-all\n")), String("block scalar"))


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


def test_a_quoted_permissions_key_is_cannot_tell() raises:
    # `"id\x2dtoken": write` is `id-token: write` once the escape is decoded
    var base = _not_farm_connected()
    var keys = List[String]()
    keys.append(String("\"id\\x2dtoken\": write"))
    keys.append(String("\"id\\x2Dtoken\": write"))
    keys.append(String("\"id\\u002dtoken\": write"))
    for i in range(len(keys)):
        _cannot_tell(base[0], _job_perms(base[1], keys[i]), String("a quoted key"))
        _cannot_tell(base[0], _top_perms(base[1], keys[i]), String("a quoted key"))
    # `"permi\x73sions": write-all` is `permissions: write-all`
    var wa = String("\"permi\\x73sions\": write-all\n")
    _cannot_tell(
        base[0], base[1].replace(String("    permissions:\n      contents: read\n"), String("    ") + wa), String("a quoted key")
    )
    _cannot_tell(base[0], base[1].replace(String("permissions: {}\n"), wa), String("a quoted key"))
    # unescaped too: the subset has no quoted key
    _cannot_tell(base[0], _job_perms(base[1], String("'id-token': write")), String("a quoted key"))


def test_a_merge_key_in_permissions_is_cannot_tell() raises:
    var base = _not_farm_connected()
    var job = base[1].replace(String("      contents: read\n"), String("      contents: read\n      <<:\n        id-token: write\n"))
    _cannot_tell(base[0], job, String("merge key"))
    var top = base[1].replace(String("permissions: {}\n"), String("permissions:\n  contents: read\n  <<:\n    id-token: write\n"))
    _cannot_tell(base[0], top, String("merge key"))


def _doc_findings(machine: String, doc: WorkflowDoc) raises -> List[String]:
    var g = parse_machine_file(machine, String("machine file"))
    return check_workflow_doc(doc, g, _tokens(), String("release/machine.textproto"))


def _doc_reports(machine: String, doc: WorkflowDoc, needle: String) raises:
    var f = _doc_findings(machine, doc)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def _rekeyed(wf: String, old: String, new: String) raises -> WorkflowDoc:
    """`wf` read, then every mapping key `old` renamed `new` in the tree: a
    document the reader never builds (it refuses a rule key in another case
    and keys that differ only in case), so the rules' own guards are held
    on their own."""
    var d = read_workflow(wf)
    var hits = 0
    for n in range(len(d.nodes)):
        for k in range(len(d.nodes[n].keys)):
            if d.nodes[n].keys[k] == old:
                d.nodes[n].keys[k] = new.copy()
                hits += 1
    if hits == 0:
        raise Error(String("no key '") + old + String("'"))
    return d^


def test_an_id_token_key_in_another_case_is_refused() raises:
    var base = _not_farm_connected()
    var keys = List[String]()
    keys.append(String("Id-Token: write"))
    keys.append(String("ID-TOKEN: write"))
    keys.append(String("id-Token: read"))
    for i in range(len(keys)):
        _cannot_tell(base[0], _job_perms(base[1], keys[i]), String("in another case"))
        _cannot_tell(base[0], _top_perms(base[1], keys[i]), String("in another case"))
    # the rule's own guard, on a document the reader never builds
    var job = _rekeyed(_job_perms(base[1], String("id-token: read")), String("id-token"), String("Id-Token"))
    _doc_reports(base[0], job, String("job 'pr': R4: permissions key 'Id-Token'"))
    _doc_reports(base[0], job, String("job 'pr': R4: has `id-token: write`, but stage 'pr' publishes to no OIDC channel"))
    var top = _rekeyed(_top_perms(base[1], String("id-token: read")), String("id-token"), String("ID-TOKEN"))
    _doc_reports(base[0], top, String("workflow: R4: permissions key 'ID-TOKEN'"))
    _doc_reports(base[0], top, String("R4: `id-token: write` at the workflow level reaches every job"))


def test_permissions_keys_that_differ_only_in_case_are_refused() raises:
    var base = _not_farm_connected()
    _cannot_tell(base[0], _job_perms(base[1], String("Contents: write")), String("repeated"))
    _cannot_tell(base[0], _top_perms(base[1], String("contents: read\n  CONTENTS: write")), String("repeated"))
    # the rule's own guard
    var job = _rekeyed(_job_perms(base[1], String("actions: write")), String("actions"), String("Contents"))
    _doc_reports(base[0], job, String("job 'pr': R4: permissions keys 'contents' and 'Contents'"))


def test_a_permissions_key_in_another_case_is_refused() raises:
    var base = _not_farm_connected()
    var job = base[1].replace(String("    permissions:\n      contents: read\n"), String("    Permissions: write-all\n"))
    _cannot_tell(base[0], job, String("key 'Permissions' is the key 'permissions' in another case"))
    var top = base[1].replace(String("permissions: {}\n"), String("PERMISSIONS: write-all\n"))
    _cannot_tell(base[0], top, String("key 'PERMISSIONS' is the key 'permissions' in another case"))
    # the rule's own guard
    var jd = _rekeyed(base[1].replace(String("    permissions:\n      contents: read\n"), String("    permissions: write-all\n")), String("permissions"), String("Permissions"))
    _doc_reports(base[0], jd, String("job 'pr': R4: key 'Permissions' is `permissions` in another case"))


def test_read_all_and_an_empty_map_are_accepted() raises:
    _agrees(String(_MACHINE), _wf(String("permissions: {}\n"), String("permissions: read-all\n")))


def test_a_push_stage_never_carries_affected_by() raises:
    _reports(
        _wf(String("kci run --stage build --summary-file"), String("kci run --stage build --affected-by ${{ github.event.pull_request.base.sha }} --summary-file")),
        String("job 'build': R6: `kci run` carries --affected-by, but stage 'build' is a PUSH stage"),
    )


comptime _RUNS_ON: String = "    runs-on: ubuntu-24.04\n"
comptime _RUNNER_FINDING: String = "so the job runs on `runs-on: ubuntu-24.04`, written as that plain scalar"


def test_a_pull_request_job_runs_on_the_hosted_runner_only() raises:
    """R6: the pr job's `runs-on` is exactly the plain scalar `ubuntu-24.04`.
    Every other runner (self-hosted, a label list, an expression, a runner
    group, a fork-conditional) is refused, each row by the rule's finding or
    by the reader's cannot tell."""
    _agrees(String(_MACHINE), String(_WF))
    # (the runs-on lines, the finding or cannot-tell needle, cannot tell?)
    var rows = List[Tuple[String, String, Bool]]()
    rows.append((String("    runs-on: self-hosted\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: [self-hosted, linux]\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: [ubuntu-24.04]\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on:\n      - ubuntu-24.04\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: ${{ vars.RUNNER }}\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: ${{ github.event.pull_request.head.ref }}\n"), String(_RUNNER_FINDING), False))
    rows.append((
        String("    runs-on: ${{ github.event.pull_request.head.repo.fork && 'self-hosted' || 'ubuntu-24.04' }}\n"),
        String(_RUNNER_FINDING), False,
    ))
    rows.append((String("    runs-on:\n      group: big-runners\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on:\n      group: big-runners\n      labels: [ubuntu-24.04]\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on:\n      labels: ubuntu-24.04\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: komira-farm\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: ubuntu-latest\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: ubuntu-24.04-arm\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: Ubuntu-24.04\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: 'ubuntu-24.04'\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: \"ubuntu-24.04\"\n"), String(_RUNNER_FINDING), False))
    rows.append((String("    runs-on: |-\n      ubuntu-24.04\n"), String("block scalar"), True))
    rows.append((String("    runs-on: ''\n"), String(_RUNNER_FINDING), False))
    rows.append((String(""), String(_RUNNER_FINDING), False))
    rows.append((String("    Runs-On: self-hosted\n"), String("in another case"), True))
    rows.append((String("    runs-on: ubuntu-24.04\n    runs-on: self-hosted\n"), String("repeated in one mapping"), True))
    var missed = String("")
    var n = 0
    for i in range(len(rows)):
        var wf = _wf(String(_RUNS_ON), rows[i][0])
        try:
            if rows[i][2]:
                _cannot_tell(String(_MACHINE), wf, rows[i][1])
            else:
                _reports(wf, String("job 'pr': R6: stage 'pr' is a PULL_REQUEST stage, ") + rows[i][1])
        except e:
            n += 1
            missed += String("\n  row ") + String(i) + String(" `") + String(rows[i][0].strip()) + String("`")
    if n > 0:
        raise Error(String(n) + String(" of ") + String(len(rows)) + String(" runs-on rows not refused:") + missed)
    # a trailing comment is not part of the value
    _agrees(String(_MACHINE), _wf(String(_RUNS_ON), String("    runs-on: ubuntu-24.04 # GitHub-hosted\n")))
    # a release job's runner is not R6's
    _agrees(String(_MACHINE), _wf(String("    environment: gamma\n"), String("    environment: gamma\n    runs-on: self-hosted\n")))


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
