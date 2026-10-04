# =============================================================================
# src/kci_ci_check/tests/test_ci_manual_gate.mojo -- rule R13: a stage whose
#   machine file names a `manual_gate` input runs only when a manual run sets
#   that input true. A fixture that agrees, then one mutation per way to
#   lose the gate (no `if:`, the conjunct removed or negated, an `||` that
#   reaches the job without it, the input undeclared, not boolean, or true by
#   default), each of which must be reported.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_ci_check import check_workflow
from kci_release_machine import parse_machine_file


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"publish-gamma\" environment: \"gamma\"\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"gamma\" }\n"
    "}\n"
    "stage { name: \"publish-prod\" environment: \"prod\" after: \"publish-gamma\"\n"
    "  manual_gate: \"publish_prod\"\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"prod\" }\n"
    "}\n"
)

comptime _IF: String = (
    "    if: github.event_name == 'workflow_dispatch' && inputs.publish_prod == true && inputs.dry_run == false\n"
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
    "        default: \"\"\n"
    "      publish_prod:\n"
    "        type: boolean\n"
    "        default: false\n"
    "permissions: {}\n"
    "jobs:\n"
    "  publish-gamma:\n"
    "    runs-on: ubuntu-24.04\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage publish-gamma --summary-file x\n"
    "  publish-prod:\n"
    "    needs: publish-gamma\n"
    "    if: github.event_name == 'workflow_dispatch' && inputs.publish_prod == true && inputs.dry_run == false\n"
    "    runs-on: ubuntu-24.04\n"
    "    environment: prod\n"
    "    permissions:\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage publish-prod --summary-file x\n"
)


def _token_stages() -> List[String]:
    var tokens = List[String]()
    tokens.append(String("publish-gamma"))
    tokens.append(String("publish-prod"))
    return tokens^


def _findings(wf: String) raises -> List[String]:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    return check_workflow(wf, g, _token_stages(), String("release/machine.textproto"))


def _mutated(old: String, new: String) raises -> String:
    var s = String(_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _if(expr: String) raises -> String:
    return _mutated(String(_IF), String("    if: ") + expr + String("\n"))


def _all(f: List[String]) -> String:
    var all = String("")
    for i in range(len(f)):
        all += f[i] + String(" | ")
    return all^


def _reports(wf: String, needle: String) raises:
    var f = _findings(wf)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def _agrees(wf: String) raises:
    var f = _findings(wf)
    if len(f) != 0:
        raise Error(String("unexpected finding(s): ") + _all(f))


comptime _NO_CONJUNCT: String = (
    "R13: stage 'publish-prod' has manual_gate 'publish_prod': its job's `if:` must have the top-level conjunct"
    " `inputs.publish_prod == true`"
)


def test_the_fixture_agrees() raises:
    _agrees(String(_WF))


def test_the_conjunct_may_stand_anywhere_in_the_conjunction() raises:
    _agrees(_if(String("inputs.publish_prod == true")))
    _agrees(_if(String("${{ inputs.dry_run == false &&  inputs.publish_prod==true }}")))
    _agrees(_if(String("(github.event_name == 'workflow_dispatch' || false) && inputs.publish_prod == true")))
    # `&&` and `||` inside a quoted string are text, not operators
    _agrees(_if(String("inputs.publish_prod == true && github.ref != 'a || b && c'")))


def test_r13_no_if_is_refused() raises:
    var f = _findings(_mutated(String(_IF), String("")))
    assert_equal(len(f), 1, _all(f))
    assert_true(f[0].startswith(String("line ")), f[0])
    assert_true(f[0].find(String("job 'publish-prod': ") + String(_NO_CONJUNCT)) > 0, f[0])


def test_r13_the_conjunct_removed_is_refused() raises:
    _reports(_if(String("github.event_name == 'workflow_dispatch' && inputs.dry_run == false")), String(_NO_CONJUNCT))
    _reports(_if(String("inputs.publish_prod == false")), String(_NO_CONJUNCT))
    _reports(_if(String("inputs.publish_prod")), String(_NO_CONJUNCT))
    _reports(_if(String("inputs.other == true")), String(_NO_CONJUNCT))


def test_r13_a_negated_or_nested_conjunct_is_refused() raises:
    # the conjunct must be top-level: inside `!( ... )` it gates nothing
    _reports(_if(String("inputs.dry_run == false && !(github.event_name == 'push' && inputs.publish_prod == true)")), String(_NO_CONJUNCT))
    _reports(_if(String("(inputs.publish_prod == true)")), String(_NO_CONJUNCT))


def test_r13_a_top_level_or_is_refused() raises:
    # `a && gate || b` runs the job on b alone
    _reports(
        _if(String("inputs.publish_prod == true || github.event_name == 'push'")),
        String("R13: stage 'publish-prod': its job's `if:` has a top-level `||`"),
    )
    _reports(
        _if(String("github.event_name == 'push' || inputs.publish_prod == true && inputs.dry_run == false")),
        String("top-level `||`"),
    )


def test_r13_the_input_is_declared_boolean_and_false_by_default() raises:
    _reports(
        _mutated(String("      publish_prod:\n        type: boolean\n        default: false\n"), String("")),
        String("R13: stage 'publish-prod' has manual_gate 'publish_prod', and workflow_dispatch declares no input `publish_prod`"),
    )
    _reports(
        _mutated(String("      publish_prod:\n        type: boolean\n"), String("      publish_prod:\n        type: string\n")),
        String("R13: workflow_dispatch input `publish_prod` (the manual gate of stage 'publish-prod') is not `type: boolean`"),
    )
    _reports(
        _mutated(String("        type: boolean\n        default: false\n"), String("        type: boolean\n        default: true\n")),
        String("R13: workflow_dispatch input `publish_prod` (the manual gate of stage 'publish-prod') is not `default: false`"),
    )
    _reports(
        _mutated(String("        type: boolean\n        default: false\n"), String("        type: boolean\n")),
        String("is not `default: false`"),
    )


def test_a_stage_without_a_gate_needs_no_if() raises:
    # publish-gamma names no manual_gate: no R13 finding about it
    var f = _findings(String(_WF))
    for i in range(len(f)):
        assert_true(f[i].find(String("publish-gamma")) < 0, f[i])
    assert_equal(len(f), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
