# =============================================================================
# src/kci_stage_graph/tests/test_stage_graph_parse.mojo
#   A machine file read back through the parser, and every refusal of
#   parse.mojo and graph.mojo, each asserted by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_stage_graph import machine_schema_version, parse_machine_file


comptime _SRC: String = "machine file"

comptime _BUILD_STEP: String = (
    "step { name: \"build\" kind: BUILD platform: \"linux-x86_64\""
    " declarations: \"release/artifacts.textproto\" }\n"
)
comptime _PUBLISH_STEP: String = (
    "step {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n"
    "  declarations: \"release/artifacts.textproto\"\n"
    "  channels: \"release/channels.textproto\"\n  channel: \"komira\"\n}\n"
)


def _two_stages() -> String:
    return (
        String("schema_version: 1\n")
        + String("stage {\n name: \"build\"\n") + String(_BUILD_STEP) + String("}\n")
        + String("stage {\n name: \"prod\"\n after: \"build\"\n") + String(_PUBLISH_STEP) + String("}\n")
    )


def _refusal(text: String) -> String:
    try:
        _ = parse_machine_file(text, String(_SRC))
    except e:
        return String(e)
    return String("")


def _assert_refused(text: String, needle: String) raises:
    var got = _refusal(text)
    if got.find(needle) < 0:
        raise Error(String("expected a refusal containing '") + needle + String("', got: '") + got + String("'"))


def _one_stage(stage_body: String) -> String:
    return String("schema_version: 1\nstage {\n") + stage_body + String("}\n")


def test_two_stages_read_back() raises:
    var g = parse_machine_file(_two_stages(), String(_SRC))
    assert_equal(g.schema_version, 1)
    assert_equal(len(g.stages), 2)
    var b = g.stage(String("build"))
    assert_equal(b.after, String(""))
    assert_equal(len(b.steps), 1)
    assert_true(b.steps[0].is_build())
    assert_equal(b.steps[0].platform, String("linux-x86_64"))
    assert_equal(b.steps[0].declarations, String("release/artifacts.textproto"))
    var p = g.stage(String("prod"))
    assert_equal(p.after, String("build"))
    assert_true(p.steps[0].is_publish())
    assert_equal(p.steps[0].name, String("publish"))
    assert_equal(p.steps[0].channels, String("release/channels.textproto"))
    assert_equal(p.steps[0].channel, String("komira"))
    assert_true(p.has_kind(String("PUBLISH")))
    assert_false(p.has_kind(String("BUILD")))


def test_a_stage_may_mix_kinds() raises:
    var text = _one_stage(String(" name: \"all\"\n") + String(_BUILD_STEP) + String(_PUBLISH_STEP))
    var g = parse_machine_file(text, String(_SRC))
    var kinds = g.stage(String("all")).step_kinds()
    assert_equal(len(kinds), 2)
    assert_equal(kinds[0], String("BUILD"))
    assert_equal(kinds[1], String("PUBLISH"))


def test_unknown_stage_lists_the_stages() raises:
    var g = parse_machine_file(_two_stages(), String(_SRC))
    try:
        _ = g.stage(String("staging"))
        raise Error(String("not refused"))
    except e:
        assert_equal(String(e), String("the machine file has no stage 'staging'; its stages: build, prod"))


def test_schema_version_missing_or_newer() raises:
    _assert_refused(
        String("stage { name: \"b\" ") + String(_BUILD_STEP) + String("}\n"), String("schema_version")
    )
    _assert_refused(String("schema_version: 2\n") + String("stage { name: \"b\" ") + String(_BUILD_STEP) + String("}\n"), String("newer kci"))
    try:
        _ = machine_schema_version(String("schema_version: 9\n"), String(_SRC))
        raise Error(String("not refused"))
    except e:
        assert_true(String(e).find(String("newer kci")) >= 0)
    assert_equal(machine_schema_version(_two_stages(), String(_SRC)), 1)


def test_no_stage() raises:
    _assert_refused(String("schema_version: 1\n"), String("machine file declares no stage"))


def test_unknown_fields() raises:
    _assert_refused(String("schema_version: 1\nstages {}\n"), String("unknown top-level field 'stages'"))
    _assert_refused(_one_stage(String(" name: \"b\"\n environment: \"b\"\n") + String(_BUILD_STEP)), String("unknown field 'environment' in stage 'b'"))
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" action: BUILD }\n")),
        String("unknown field 'action' in a step of stage 'b'"),
    )


def test_set_twice_and_unclosed() raises:
    _assert_refused(_one_stage(String(" name: \"b\"\n name: \"c\"\n") + String(_BUILD_STEP)), String("field 'name' is set twice in stage 'b'"))
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" }\n")),
        String("field 'kind' is set twice"),
    )
    _assert_refused(String("schema_version: 1\nstage {\n name: \"b\"\n"), String("stage 'b' is not closed"))


def test_stage_names() raises:
    _assert_refused(_one_stage(String(_BUILD_STEP)), String("a stage has no name"))
    _assert_refused(_one_stage(String(" name: \"Prod\"\n") + String(_BUILD_STEP)), String("stage name 'Prod' is not"))
    _assert_refused(_one_stage(String(" name: \"prod-\"\n") + String(_BUILD_STEP)), String("stage name 'prod-' is not"))
    var long = String("a")
    for _ in range(63):
        long += String("b")
    _assert_refused(_one_stage(String(" name: \"") + long + String("\"\n") + String(_BUILD_STEP)), String("is not [a-z]"))
    var dup = (
        String("schema_version: 1\nstage { name: \"b\" ") + String(_BUILD_STEP) + String("}\n")
        + String("stage { name: \"b\" ") + String(_BUILD_STEP) + String("}\n")
    )
    _assert_refused(dup, String("stage 'b' is declared twice (first on line 2)"))


def test_after_names_an_earlier_stage() raises:
    var later = (
        String("schema_version: 1\nstage { name: \"prod\" after: \"build\" ") + String(_PUBLISH_STEP) + String("}\n")
        + String("stage { name: \"build\" ") + String(_BUILD_STEP) + String("}\n")
    )
    _assert_refused(later, String("stage 'prod' runs after 'build', which is not a stage declared above it"))
    _assert_refused(_one_stage(String(" name: \"b\" after: \"b\"\n") + String(_BUILD_STEP)), String("stage 'b' runs after itself"))


def test_steps() raises:
    _assert_refused(_one_stage(String(" name: \"b\"\n")), String("stage 'b' has no step"))
    var two = _one_stage(String(" name: \"b\"\n") + String(_BUILD_STEP) + String(_BUILD_STEP))
    _assert_refused(two, String("stage 'b' has two steps named 'build'"))
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"Build\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" }\n")),
        String("has name 'Build'"),
    )


def test_step_kinds() raises:
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"d\" kind: DEPLOY platform: \"linux-x86_64\" declarations: \"d\" }\n")),
        String("is a DEPLOY step: that kind needs a newer kci"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"d\" kind: VALIDATE platform: \"linux-x86_64\" declarations: \"d\" }\n")),
        String("has kind 'VALIDATE'; a step is BUILD or PUBLISH"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"d\" platform: \"linux-x86_64\" declarations: \"d\" }\n")),
        String("has no kind"),
    )


def test_validation_needs_a_newer_kci() raises:
    # `step.validation` is reserved: refused, naming its line, like DEPLOY
    var text = _one_stage(
        String(" name: \"b\"\n step {\n name: \"s\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\"\n")
        + String(" validation { name: \"smoke\" }\n }\n")
    )
    assert_equal(
        _refusal(text),
        String("machine file: line 6: step 's' of stage 'b' declares a validation: validations need a newer kci")
        + String(" (this kci runs BUILD and PUBLISH steps)"),
    )
    # before the step's name is read, the step is named by its stage
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { validation { name: \"v\" } name: \"s\" }\n")),
        String("line 4: a step of stage 'b' declares a validation"),
    )


def test_step_inputs() raises:
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD declarations: \"d\" }\n")),
        String("step 's' of stage 'b' has no platform"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"darwin-arm64\" declarations: \"d\" }\n")),
        String("darwin-arm64"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" }\n")),
        String("has no declarations"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" channel: \"komira\" }\n")),
        String("is a BUILD step: channels and channel belong to a PUBLISH step"),
    )
    _assert_refused(
        _one_stage(String(" name: \"p\"\n step { name: \"s\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d\" channel: \"komira\" }\n")),
        String("has no channels"),
    )
    _assert_refused(
        _one_stage(String(" name: \"p\"\n step { name: \"s\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d\" channels: \"c\" }\n")),
        String("has no channel (the channel to publish to)"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
