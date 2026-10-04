# =============================================================================
# src/kci_stage_graph/tests/test_stage_selection.mojo
#   `resolve_selection`: `kci run --only ...` against one stage. A step
#   selector selects its step; one that matches nothing is refused with the
#   stage's names; a validation selector selects that validation and no
#   step; a step selector selects its step and the step's validations; any
#   selector makes the run SELECTIVE; steps run in file order.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_contract import SCOPE_FULL, SCOPE_SELECTIVE, Selector, parse_selectors
from kci_stage_graph import Selection, Stage, parse_machine_file, resolve_selection


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"release\"\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" }\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"gamma\"\n"
    "    validation { name: \"install-smoke\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\" program: \"s.mojo\" }\n"
    "    validation { name: \"read-back\" kind: CONDA_INSTALL_SMOKE install: \"komira_encoding\" program: \"s.mojo\" }\n"
    "  }\n"
    "}\n"
)


def _stage() raises -> Stage:
    return parse_machine_file(String(_MACHINE), String("machine file")).stage(String("release"))


def _resolve(texts: List[String]) raises -> Selection:
    return resolve_selection(_stage(), parse_selectors(texts))


def _refusal(texts: List[String]) -> String:
    try:
        _ = _resolve(texts)
    except e:
        return String(e)
    return String("<selected>")


def test_no_selector_is_full() raises:
    var s = _resolve(List[String]())
    assert_equal(s.scope, String(SCOPE_FULL))
    assert_equal(len(s.steps), 2)
    assert_true(s.steps[0])
    assert_true(s.steps[1])
    assert_equal(len(s.only), 0)
    # a full run runs every validation, in file order
    assert_equal(len(s.validations), 2)
    assert_equal(s.validations[0], String("install-smoke"))
    assert_equal(s.validations[1], String("read-back"))


def test_step_selector_selects_its_step() raises:
    var t = List[String]()
    t.append(String("step:publish"))
    var s = _resolve(t)
    assert_equal(s.scope, String(SCOPE_SELECTIVE))
    assert_false(s.steps[0])
    assert_true(s.steps[1])
    assert_equal(s.selected_count(), 1)
    assert_equal(len(s.only), 1)
    assert_equal(s.only[0], String("step:publish"))
    # a selected step brings its own validations
    assert_equal(len(s.validations), 2)
    var b = List[String]()
    b.append(String("step:build"))
    var only_build = _resolve(b)
    assert_equal(len(only_build.validations), 0)


def test_every_step_selected_is_still_selective() raises:
    var t = List[String]()
    t.append(String("step:build"))
    t.append(String("step:publish"))
    var s = _resolve(t)
    assert_equal(s.selected_count(), 2)
    assert_equal(s.scope, String(SCOPE_SELECTIVE))


def test_file_order_not_argv_order() raises:
    var t = List[String]()
    t.append(String("step:publish"))
    t.append(String("step:build"))
    var s = _resolve(t)
    # the steps run in machine-file order: build (index 0) before publish
    assert_true(s.steps[0])
    assert_true(s.steps[1])
    # `only` keeps the order given, for the record
    assert_equal(s.only[0], String("step:publish"))
    assert_equal(s.only[1], String("step:build"))


def test_no_match_is_refused_with_the_names() raises:
    var t = List[String]()
    t.append(String("step:deploy"))
    assert_equal(
        _refusal(t),
        String("--only 'step:deploy' matches no step of stage 'release'; its steps: build, publish;")
        + String(" its validations: install-smoke, read-back"),
    )
    # one bad selector among good ones still refuses the run
    var u = List[String]()
    u.append(String("step:build"))
    u.append(String("step:nope"))
    assert_true(_refusal(u).find(String("--only 'step:nope' matches no step")) >= 0)


def test_validation_selector_selects_the_validation_only() raises:
    var t = List[String]()
    t.append(String("validation:install-smoke"))
    var s = _resolve(t)
    assert_equal(s.scope, String(SCOPE_SELECTIVE))
    # no step runs: the validation checks what an earlier run published
    assert_equal(s.selected_count(), 0)
    assert_equal(len(s.validations), 1)
    assert_equal(s.validations[0], String("install-smoke"))
    assert_equal(s.only[0], String("validation:install-smoke"))


def test_step_and_one_of_its_validations_is_not_doubled() raises:
    var t = List[String]()
    t.append(String("validation:read-back"))
    t.append(String("step:publish"))
    var s = _resolve(t)
    assert_true(s.steps[1])
    # each validation once, in file order
    assert_equal(len(s.validations), 2)
    assert_equal(s.validations[0], String("install-smoke"))
    assert_equal(s.validations[1], String("read-back"))


def test_unknown_validation_is_refused_with_the_names() raises:
    var t = List[String]()
    t.append(String("validation:smoke"))
    assert_equal(
        _refusal(t),
        String("--only 'validation:smoke' matches no validation of stage 'release'; its steps: build, publish;")
        + String(" its validations: install-smoke, read-back"),
    )


def test_a_stage_without_validations_says_none() raises:
    var g = parse_machine_file(
        String("schema_version: 1\nstage { name: \"build\"\n")
        + String("  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" } }\n"),
        String("machine file"),
    )
    var t = List[String]()
    t.append(String("validation:smoke"))
    try:
        _ = resolve_selection(g.stage(String("build")), parse_selectors(t))
        raise Error(String("not refused"))
    except e:
        assert_equal(
            String(e),
            String("--only 'validation:smoke' matches no validation of stage 'build'; its steps: build;")
            + String(" its validations: (none)"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
