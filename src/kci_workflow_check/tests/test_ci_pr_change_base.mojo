# =============================================================================
# src/kci_workflow_check/tests/test_ci_pr_change_base.mojo -- R6's change base:
#   what pr.yml passes as `kci run --stage pr --affected-by`.
# =============================================================================
#
# THE DEFECT this file pins: pr.yml builds the pull request's merge commit
# (`github.sha`, the commit GitHub made by merging the head into main's tip
# at that moment) but passed `${{ github.event.pull_request.base.sha }}`, the
# main of the pull request EVENT. Once main moves past that commit, kci's
# `git diff <base>...<merge commit>` holds every change merged to main in
# between, so a documentation-only pull request was charged with a later
# `tools/build/**` change and widened to every unit. The merge commit's first
# parent IS the main it was merged into, so the change base is `HEAD^1`
# (kci holds HEAD to --revision-id): pull_request.mojo's CHANGE_BASE_LINE
# sets `change_base`, and the one `kci run` passes `"$change_base"`.
#
# Each case below is a mutation of a workflow that agrees: the event's base
# (the old pr.yml, which the lint accepted before the fix), any other value,
# the line missing, moved after the `kci run`, altered, or the variable
# changed elsewhere in the script; and R18, which no longer lets any `${{ }}`
# into a script. Only the public entry points (`check_workflow`) are used.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_workflow_check import check_workflow
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

comptime _BASE_LINE: String = (
    "          if ! git rev-parse --verify --quiet HEAD^2 > /dev/null || ! change_base=$(git rev-parse --verify HEAD^1);"
    " then echo \"::error::the change base is the merge commit's first parent, and HEAD is not a merge commit\"; exit 1; fi\n"
)

comptime _KCI: String = (
    "          \"$RUNNER_TEMP/kci/kci\" run --stage pr \\\n"
    "            --affected-by \"$change_base\" \\\n"
    "            --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)

comptime _HEAD: String = (
    "name: pr\n"
    "on:\n"
    "  pull_request:\n"
    "    branches: [main]\n"
    "permissions: {}\n"
    "jobs:\n"
    "  check:\n"
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
)

# The kci step as pr.yml wrote it before the fix: the event's base commit.
comptime _EVENT_BASE_KCI: String = (
    "          \"$RUNNER_TEMP/kci/kci\" run --stage pr \\\n"
    "            --affected-by ${{ github.event.pull_request.base.sha }} \\\n"
    "            --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)

comptime _WIDENS: String = (
    "is the base branch when the event fired, not the first parent of the merge commit the job builds:"
    " once the base branch moves, every change merged to it since then is counted as the pull request's own"
    " and widens the check"
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


def _script(body: String) -> String:
    return String(_HEAD) + body


def _good() -> String:
    return _script(String(_BASE_LINE) + String(_KCI))


def _swap(old: String, new: String) raises -> String:
    var s = _good()
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


# ---- the fix: the merge commit's first parent ----------------------------------


def test_the_merge_commits_first_parent_agrees() raises:
    _agrees(_good())
    # other lines before it in the same script (pr.yml's deadline lines)
    _agrees(_script(String("          budget_s=1\n") + String(_BASE_LINE) + String(_KCI)))


# ---- THE DEFECT: the event's base.sha widens the change -------------------------


def test_the_events_base_sha_is_refused_because_it_widens_the_change() raises:
    # pr.yml as it was: the lint accepted this, so the check diffed main's
    # later merges as the pull request's own
    _reports(_script(String(_EVENT_BASE_KCI)), String(_WIDENS))
    # with the change base line present too: the argument is what kci reads
    _reports(_script(String(_BASE_LINE) + String(_EVENT_BASE_KCI)), String(_WIDENS))
    # quoted, `=`, and the spacing inside ${{ }}: the same commit
    _reports(
        _swap(String("--affected-by \"$change_base\""), String("--affected-by \"${{ github.event.pull_request.base.sha }}\"")),
        String(_WIDENS),
    )
    _reports(
        _swap(String("--affected-by \"$change_base\""), String("--affected-by=${{github.event.pull_request.base.sha}}")),
        String(_WIDENS),
    )


def test_any_other_base_is_refused() raises:
    var want = String("it passes --affected-by \"$change_base\" after the line `if ! git rev-parse")
    for other in [
        "origin/main",
        "${{ github.event.pull_request.head.sha }}",
        "\"$GITHUB_BASE_REF\"",
        "HEAD~1",
        "\"${change_base}\"",
    ]:
        _reports(_swap(String("\"$change_base\" \\\n"), String(other) + String(" \\\n")), want)
    # no --affected-by at all
    _reports(
        _swap(String("            --affected-by \"$change_base\" \\\n"), String("")),
        String("so its `kci run` carries --affected-by \"$change_base\" after the line"),
    )


# ---- the line that sets it -------------------------------------------------------


def test_the_change_base_is_set_by_the_line_before_the_kci_run() raises:
    var unset = String("the script does not set it before")
    # no line
    _reports(_script(String(_KCI)), unset)
    # after the kci run
    _reports(_script(String(_KCI) + String(_BASE_LINE)), unset)
    # the event's base under the variable's name
    _reports(_script(String("          change_base=\"$BASE_SHA\"\n") + String(_KCI)), unset)
    # the line altered: the grandparent, no merge-commit check, inside a condition
    _reports(_swap(String("--verify HEAD^1)"), String("--verify HEAD~2)")), unset)
    _reports(
        _swap(String("if ! git rev-parse --verify --quiet HEAD^2 > /dev/null || "), String("if ")),
        unset,
    )
    _reports(_swap(String(_BASE_LINE), String("          true && ") + String(String(_BASE_LINE).lstrip())), unset)


def test_nothing_else_names_the_change_base() raises:
    var twice = String("exactly twice, where it is set and as --affected-by")
    _reports(_script(String(_BASE_LINE) + String("          change_base=\"$1\"\n") + String(_KCI)), twice)
    _reports(_script(String(_BASE_LINE) + String("          read -r change_base < base.txt\n") + String(_KCI)), twice)
    _reports(_script(String(_BASE_LINE) + String("          export change_base\n") + String(_KCI)), twice)


# ---- R18: no expression in a script, the event's base included -------------------


def test_no_expression_reaches_the_script() raises:
    # before the fix R18 let `${{ github.event.pull_request.base.sha }}` into a
    # script as the one exception; nothing needs it now
    _reports(
        _swap(
            String("            --summary-file"),
            String("            --context base=${{ github.event.pull_request.base.sha }} --summary-file"),
        ),
        String("R18: a `run:` script holds `${{ github.event.pull_request.base.sha }}`"),
    )
    var f = _check(_script(String(_EVENT_BASE_KCI)))
    var r18 = 0
    for i in range(len(f)):
        if f[i].find(String("R18")) >= 0:
            r18 += 1
    assert_equal(r18, 1, _all(f))
    assert_true(len(f) == 2, _all(f))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
