# =============================================================================
# src/kci_release_machine/tests/test_release_machine_parse.mojo
#   A machine file read back through the parser, and every refusal of
#   parse.mojo and graph.mojo, each asserted by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_machine import machine_schema_version, parse_machine_file


comptime _SRC: String = "machine file"

comptime _BUILD_STEP: String = (
    "step { name: \"build\" kind: BUILD platform: \"linux-x86_64\""
    " declarations: \"release/artifacts.textproto\" }\n"
)
comptime _PUBLISH_STEP: String = (
    "step {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n"
    "  declarations: \"release/artifacts.textproto\"\n"
    "  channels: \"release/channels.textproto\"\n  channel: \"prod\"\n}\n"
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
    assert_equal(p.steps[0].channel, String("prod"))
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
    _assert_refused(_one_stage(String(" name: \"b\"\n env: \"b\"\n") + String(_BUILD_STEP)), String("unknown field 'env' in stage 'b'"))
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


# ---- stage environment, farm_connected, validations --------------------------

comptime _SMOKE: String = (
    "  validation {\n    name: \"install-smoke\"\n    kind: CONDA_INSTALL_SMOKE\n    install: \"komira_all\"\n"
    "    extra_channel: \"https://conda.modular.com/max\"\n    extra_channel: \"conda-forge\"\n"
    "    program: \"release/smoke/smoke_komira_encoding.mojo\"\n  }\n"
)


def _publish_step(channel: String, validations: String) -> String:
    return (
        String("step {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n")
        + String("  declarations: \"release/artifacts.textproto\"\n")
        + String("  channels: \"release/channels.textproto\"\n  channel: \"") + channel + String("\"\n")
        + validations + String("}\n")
    )


def _three_stages() -> String:
    """The release machine's shape: build (farm-connected), publish-gamma in
    environment gamma with an install smoke, publish-prod in environment prod
    after it."""
    return (
        String("schema_version: 1\n")
        + String("stage {\n name: \"build\"\n farm_connected: true\n") + String(_BUILD_STEP) + String("}\n")
        + String("stage {\n name: \"publish-gamma\"\n environment: \"gamma\"\n after: \"build\"\n")
        + _publish_step(String("gamma"), String(_SMOKE)) + String("}\n")
        + String("stage {\n name: \"publish-prod\"\n environment: \"prod\"\n after: \"publish-gamma\"\n")
        + _publish_step(String("prod"), String("")) + String("}\n")
    )


def _with_validation(fields: String) -> String:
    """One PUBLISH stage whose step holds one validation block of `fields`;
    the validation block opens on line 11."""
    return _one_stage(
        String(" name: \"p\"\n")
        + _publish_step(String("gamma"), String("  validation { ") + fields + String(" }\n"))
    )


comptime _V_OK: String = "name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\" program: \"s/smoke.mojo\""


def test_three_stages_read_back() raises:
    var g = parse_machine_file(_three_stages(), String(_SRC))
    assert_equal(len(g.stages), 3)
    var b = g.stage(String("build"))
    assert_true(b.farm_connected)
    # an unset environment is the stage's name
    assert_equal(b.environment, String("build"))
    var gm = g.stage(String("publish-gamma"))
    assert_equal(gm.environment, String("gamma"))
    assert_false(gm.farm_connected)
    assert_equal(gm.after, String("build"))
    assert_equal(gm.steps[0].channel, String("gamma"))
    assert_equal(len(gm.steps[0].validations), 1)
    ref v = gm.steps[0].validations[0]
    assert_equal(v.name, String("install-smoke"))
    assert_equal(v.kind, String("CONDA_INSTALL_SMOKE"))
    assert_equal(v.install, String("komira_all"))
    assert_equal(len(v.extra_channels), 2)
    assert_equal(v.extra_channels[0], String("https://conda.modular.com/max"))
    assert_equal(v.extra_channels[1], String("conda-forge"))
    assert_equal(v.program, String("release/smoke/smoke_komira_encoding.mojo"))
    # an unset tool is pixi
    assert_equal(v.tool, String("pixi"))
    assert_equal(v.line, 18)
    var p = g.stage(String("publish-prod"))
    assert_equal(p.environment, String("prod"))
    assert_equal(p.after, String("publish-gamma"))
    assert_equal(len(p.steps[0].validations), 0)
    var names = gm.validation_names()
    assert_equal(len(names), 1)
    assert_equal(names[0], String("install-smoke"))


def test_stage_environment() raises:
    _assert_refused(
        _one_stage(String(" name: \"b\"\n environment: \"Prod\"\n") + String(_BUILD_STEP)),
        String("line 2: stage 'b' has environment 'Prod'; an environment name is [a-z][a-z0-9-]*"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n environment: \"x\"\n environment: \"y\"\n") + String(_BUILD_STEP)),
        String("field 'environment' is set twice in stage 'b'"),
    )


def test_farm_connected() raises:
    var g = parse_machine_file(
        _one_stage(String(" name: \"b\"\n farm_connected: false\n") + String(_BUILD_STEP)), String(_SRC)
    )
    assert_false(g.stages[0].farm_connected)
    _assert_refused(
        _one_stage(String(" name: \"b\"\n farm_connected: yes\n") + String(_BUILD_STEP)),
        String("line 4: field 'farm_connected' of stage 'b' is 'yes'; it is true or false"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n farm_connected: true\n farm_connected: true\n") + String(_BUILD_STEP)),
        String("field 'farm_connected' is set twice in stage 'b'"),
    )
    # the job that holds a tailnet node must not hold a publishing token
    _assert_refused(
        _one_stage(String(" name: \"p\"\n farm_connected: true\n") + _publish_step(String("gamma"), String(""))),
        String("line 2: stage 'p' is farm-connected and has PUBLISH step 'publish': a farm-connected stage may not publish"),
    )


def test_validation_reads_back_alone() raises:
    var g = parse_machine_file(_with_validation(String(_V_OK)), String(_SRC))
    ref v = g.stages[0].steps[0].validations[0]
    assert_equal(v.name, String("v"))
    assert_equal(len(v.extra_channels), 0)
    assert_equal(v.tool, String("pixi"))
    assert_equal(v.line, 11)


def test_validation_belongs_to_a_publish_step() raises:
    var text = _one_stage(
        String(" name: \"b\"\n step {\n name: \"s\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\"\n")
        + String(" validation { ") + String(_V_OK) + String(" }\n }\n")
    )
    assert_equal(
        _refusal(text),
        String("machine file: line 6: validation 'v' of step 's' of stage 'b': a validation belongs to a PUBLISH step")
        + String(" (it checks what the step published)"),
    )


def test_validation_fields() raises:
    _assert_refused(
        _with_validation(String("kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"s.mojo\"")),
        String("line 11: a validation of step 'publish' of stage 'p' has no name"),
    )
    _assert_refused(
        _with_validation(String("name: \"Smoke\" kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"s.mojo\"")),
        String("has name 'Smoke'; a validation name is [a-z][a-z0-9-]*"),
    )
    _assert_refused(
        _with_validation(String("name: \"v\" install: \"a\" program: \"s.mojo\"")),
        String("validation 'v' of step 'publish' of stage 'p' has no kind (CONDA_INSTALL_SMOKE)"),
    )
    _assert_refused(
        _with_validation(String("name: \"v\" kind: PYTEST install: \"a\" program: \"s.mojo\"")),
        String("validation kind 'PYTEST' is not CONDA_INSTALL_SMOKE"),
    )
    _assert_refused(
        _with_validation(String("name: \"v\" kind: CONDA_INSTALL_SMOKE program: \"s.mojo\"")),
        String("validation 'v' of step 'publish' of stage 'p' has no install (the package to install)"),
    )
    _assert_refused(
        _with_validation(String("name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"a\"")),
        String("has no program (the smoke program to run)"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" tool: conda")),
        String("has tool 'conda'; this kci installs with pixi"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" tool: pixi tool: pixi")),
        String("field 'tool' is set twice in validation 'v'"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" timeout: 5")),
        String("unknown field 'timeout' in validation 'v' (expected name, kind, install, extra_channel, program, tool)"),
    )


def test_validation_extra_channel() raises:
    _assert_refused(
        _with_validation(String(_V_OK) + String(" extra_channel: \"http://conda.modular.com/max\"")),
        String("has extra_channel 'http://conda.modular.com/max'; an extra channel is an https:// URL or conda-forge"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" extra_channel: \"bioconda\"")),
        String("has extra_channel 'bioconda'"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" extra_channel: \"https://\"")),
        String("has extra_channel 'https://'"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" extra_channel: \"conda-forge\" extra_channel: \"conda-forge\"")),
        String("names extra_channel 'conda-forge' twice"),
    )


def test_validation_program_path() raises:
    var bad = List[String]()
    bad.append(String("/abs/smoke.mojo"))
    bad.append(String("smoke.py"))
    bad.append(String("release/../smoke.mojo"))
    bad.append(String(".mojo"))
    for i in range(len(bad)):
        _assert_refused(
            _with_validation(
                String("name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"") + bad[i] + String("\"")
            ),
            String("has program '") + bad[i] + String("'; a program is a relative path to a .mojo file inside the repository"),
        )


def test_validation_names_are_unique_in_a_stage() raises:
    # two validations of one step
    _assert_refused(
        _one_stage(
            String(" name: \"p\"\n")
            + _publish_step(
                String("gamma"),
                String("  validation { ") + String(_V_OK) + String(" }\n  validation { ") + String(_V_OK) + String(" }\n"),
            )
        ),
        String("stage 'p' has two validations named 'v' (first on line 11)"),
    )
    # one in each of two steps of the same stage
    var two_steps = _one_stage(
        String(" name: \"p\"\n")
        + _publish_step(String("gamma"), String("  validation { ") + String(_V_OK) + String(" }\n"))
        + String("step {\n  name: \"again\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n")
        + String("  declarations: \"d\"\n  channels: \"c\"\n  channel: \"prod\"\n")
        + String("  validation { ") + String(_V_OK) + String(" }\n}\n")
    )
    _assert_refused(two_steps, String("stage 'p' has two validations named 'v'"))
    # the same name in two stages is fine
    var g = parse_machine_file(
        String("schema_version: 1\n")
        + String("stage { name: \"a\" ") + _publish_step(String("gamma"), String("validation { ") + String(_V_OK) + String(" }")) + String("}\n")
        + String("stage { name: \"b\" ") + _publish_step(String("prod"), String("validation { ") + String(_V_OK) + String(" }")) + String("}\n"),
        String(_SRC),
    )
    assert_equal(len(g.stages), 2)


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
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d\" channel: \"prod\" }\n")),
        String("is a BUILD step: channels and channel belong to a PUBLISH step"),
    )
    _assert_refused(
        _one_stage(String(" name: \"p\"\n step { name: \"s\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d\" channel: \"prod\" }\n")),
        String("has no channels"),
    )
    _assert_refused(
        _one_stage(String(" name: \"p\"\n step { name: \"s\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d\" channels: \"c\" }\n")),
        String("has no channel (the channel to publish to)"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
