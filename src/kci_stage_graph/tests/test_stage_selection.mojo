# =============================================================================
# src/kci_stage_graph/tests/test_stage_selection.mojo
#   `resolve_selection`: `kci run --only ...` against one stage. A step
#   selector selects its step; one that matches nothing is refused with the
#   stage's names; a validation selector is refused (no stage declares one
#   yet); any selector makes the run SELECTIVE; steps run in file order.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_contract import SCOPE_FULL, SCOPE_SELECTIVE, Selector, parse_selectors
from kci_stage_graph import Selection, Stage, parse_machine_file, resolve_selection


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"release\"\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" }\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"komira\" }\n"
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
        + String(" its validations: (none: no stage declares one yet)"),
    )
    # one bad selector among good ones still refuses the run
    var u = List[String]()
    u.append(String("step:build"))
    u.append(String("step:nope"))
    assert_true(_refusal(u).find(String("--only 'step:nope' matches no step")) >= 0)


def test_validation_selector_is_refused() raises:
    var t = List[String]()
    t.append(String("validation:smoke"))
    assert_equal(
        _refusal(t),
        String("--only 'validation:smoke' matches nothing: stage 'release' declares no validations")
        + String(" (validations need a newer kci); its steps: build, publish;")
        + String(" its validations: (none: no stage declares one yet)"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
