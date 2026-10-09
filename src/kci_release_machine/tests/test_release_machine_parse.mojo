# =============================================================================
# src/kci_release_machine/tests/test_release_machine_parse.mojo
#   A machine file read back through the parser, and every refusal of
#   parse.mojo and graph.mojo, each asserted by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_machine import is_digest_pinned_image, machine_schema_version, parse_machine_file


comptime _SRC: String = "machine file"

comptime _BUILD_STEP: String = (
    "step { name: \"build\" kind: BUILD platform: \"linux-x86_64\""
    " artifacts: \"release/artifacts.textproto\" }\n"
)
comptime _PUBLISH_STEP: String = (
    "step {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n"
    "  artifacts: \"release/artifacts.textproto\"\n"
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
    assert_equal(b.steps[0].artifacts, String("release/artifacts.textproto"))
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
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" action: BUILD }\n")),
        String("unknown field 'action' in a step of stage 'b'"),
    )


def test_set_twice_and_unclosed() raises:
    _assert_refused(_one_stage(String(" name: \"b\"\n name: \"c\"\n") + String(_BUILD_STEP)), String("field 'name' is set twice in stage 'b'"))
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" }\n")),
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
        _one_stage(String(" name: \"b\"\n step { name: \"Build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" }\n")),
        String("has name 'Build'"),
    )


def test_step_kinds() raises:
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"d\" kind: DEPLOY platform: \"linux-x86_64\" artifacts: \"d\" }\n")),
        String("step 'd' of stage 'b' is a DEPLOY step and has platform 'linux-x86_64': a platform is an OS plus a CPU"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"d\" kind: VALIDATE platform: \"linux-x86_64\" artifacts: \"d\" }\n")),
        String("has kind 'VALIDATE'; a step is BUILD, PUBLISH or DEPLOY"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"d\" platform: \"linux-x86_64\" artifacts: \"d\" }\n")),
        String("has no kind"),
    )


# ---- stage environment, farm_connected, validations --------------------------

comptime _IMAGE: String = (
    "registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)

comptime _SMOKE: String = (
    "  validation {\n    name: \"install\"\n    kind: CONDA_INSTALL_SMOKE\n"
    "    image: \"registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\n"
    "    install: \"komira_encoding\"\n    install: \"komira_all\"\n"
    "    compiler_channel: \"https://conda.modular.com/max\"\n    extra_channel: \"conda-forge\"\n"
    "    program: \"release/smoke/smoke_komira_encoding.mojo\"\n    wait_for_index_seconds: 600\n  }\n"
)


def _publish_step(channel: String, validations: String) -> String:
    return (
        String("step {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n")
        + String("  artifacts: \"release/artifacts.textproto\"\n")
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


comptime _V_REST: String = (
    "image: \"registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
    " compiler_channel: \"https://conda.modular.com/max\""
)
"""Every field a validation needs besides name, kind, install and program."""

comptime _V_OK: String = (
    "name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\" program: \"release/smoke.mojo\" "
    "image: \"registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
    " compiler_channel: \"https://conda.modular.com/max\""
)


def _v(fields: String) -> String:
    """`fields` plus the image and the compiler channel."""
    return fields + String(" ") + String(_V_REST)


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
    assert_equal(v.name, String("install"))
    assert_equal(v.kind, String("CONDA_INSTALL_SMOKE"))
    assert_equal(v.image, String(_IMAGE))
    assert_equal(len(v.installs), 2)
    assert_equal(v.installs[0], String("komira_encoding"))
    assert_equal(v.installs[1], String("komira_all"))
    assert_equal(v.compiler_channel, String("https://conda.modular.com/max"))
    assert_equal(len(v.extra_channels), 1)
    assert_equal(v.extra_channels[0], String("conda-forge"))
    assert_equal(v.program, String("release/smoke/smoke_komira_encoding.mojo"))
    assert_equal(v.wait_for_index_seconds, 600)
    assert_equal(v.line, 18)
    var p = g.stage(String("publish-prod"))
    assert_equal(p.environment, String("prod"))
    assert_equal(p.after, String("publish-gamma"))
    assert_equal(len(p.steps[0].validations), 0)
    var names = gm.validation_names()
    assert_equal(len(names), 1)
    assert_equal(names[0], String("install"))


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
    # the job that holds a farm network node must not hold a publishing token
    _assert_refused(
        _one_stage(String(" name: \"p\"\n farm_connected: true\n") + _publish_step(String("gamma"), String(""))),
        String("line 2: stage 'p' is farm-connected and has PUBLISH step 'publish': a farm-connected stage may not publish (the job that holds a farm network node must not hold a publishing token)"),
    )


def _pr_and_release(pr_body: String, release_after: String = String("build")) -> String:
    return (
        String("schema_version: 1\n")
        + String("stage {\n name: \"build\"\n") + String(_BUILD_STEP) + String("}\n")
        + String("stage {\n name: \"prod\"\n after: \"") + release_after + String("\"\n") + String(_PUBLISH_STEP)
        + String("}\n")
        + String("stage {\n name: \"pr\"\n") + pr_body + String("}\n")
    )


def test_trigger_defaults_to_push() raises:
    var g = parse_machine_file(_two_stages(), String(_SRC))
    for i in range(len(g.stages)):
        assert_equal(g.stages[i].trigger, String("PUSH"))
        assert_false(g.stages[i].is_pull_request())
        # a PUSH stage's environment defaults to its name
        assert_equal(g.stages[i].environment, g.stages[i].name)


def test_a_pull_request_stage_reads_back_with_no_environment() raises:
    var g = parse_machine_file(
        _pr_and_release(String(" trigger: PULL_REQUEST\n farm_connected: true\n") + String(_BUILD_STEP)), String(_SRC)
    )
    var pr = g.stage(String("pr"))
    assert_equal(pr.trigger, String("PULL_REQUEST"))
    assert_true(pr.is_pull_request())
    assert_true(pr.farm_connected)
    # no environment is defaulted: the job runs in none
    assert_equal(pr.environment, String(""))
    assert_equal(g.stage(String("prod")).environment, String("prod"))
    # PUSH written out is the default
    var push = parse_machine_file(_one_stage(String(" name: \"b\"\n trigger: PUSH\n") + String(_BUILD_STEP)), String(_SRC))
    assert_false(push.stages[0].is_pull_request())


def test_pull_request_stage_refusals() raises:
    _assert_refused(
        _one_stage(String(" name: \"b\"\n trigger: MERGE\n") + String(_BUILD_STEP)),
        String("line 2: stage 'b' has trigger 'MERGE'; a trigger is PUSH or PULL_REQUEST"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n trigger: PUSH\n trigger: PUSH\n") + String(_BUILD_STEP)),
        String("field 'trigger' is set twice in stage 'b'"),
    )
    # no environment: no secret or approval reaches a pull request's code
    _assert_refused(
        _pr_and_release(String(" trigger: PULL_REQUEST\n environment: \"pr\"\n") + String(_BUILD_STEP)),
        String("line 18: stage 'pr' is a PULL_REQUEST stage and has environment 'pr': its job runs a pull request's code in NO environment"),
    )
    # it runs after nothing, and nothing runs after it
    _assert_refused(
        _pr_and_release(String(" trigger: PULL_REQUEST\n after: \"build\"\n") + String(_BUILD_STEP)),
        String("stage 'pr' is a PULL_REQUEST stage and runs after 'build'"),
    )
    _assert_refused(
        String("schema_version: 1\n")
        + String("stage {\n name: \"pr\"\n trigger: PULL_REQUEST\n") + String(_BUILD_STEP) + String("}\n")
        + String("stage {\n name: \"prod\"\n after: \"pr\"\n") + String(_PUBLISH_STEP) + String("}\n"),
        String("line 7: stage 'prod' runs after 'pr', a PULL_REQUEST stage: no stage runs after a pull request's check"),
    )
    # BUILD steps only: nothing is published from a pull request
    _assert_refused(
        _pr_and_release(String(" trigger: PULL_REQUEST\n") + String(_BUILD_STEP) + String(_PUBLISH_STEP)),
        String("stage 'pr' is a PULL_REQUEST stage and has PUBLISH step 'publish': a pull request's check builds and never publishes"),
    )


def test_validation_reads_back_alone() raises:
    var g = parse_machine_file(_with_validation(String(_V_OK)), String(_SRC))
    ref v = g.stages[0].steps[0].validations[0]
    assert_equal(v.name, String("v"))
    assert_equal(len(v.extra_channels), 0)
    # an unset wait is the default: 30 minutes (a registry can take a
    # quarter of an hour to make a subdir's first index)
    assert_equal(v.wait_for_index_seconds, 1800)
    assert_equal(v.line, 11)


def test_validation_belongs_to_a_publish_step() raises:
    var text = _one_stage(
        String(" name: \"b\"\n step {\n name: \"s\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\"\n")
        + String(" validation { ") + String(_V_OK) + String(" }\n }\n")
    )
    assert_equal(
        _refusal(text),
        String("machine file: line 6: validation 'v' of step 's' of stage 'b': a CONDA_INSTALL_SMOKE validation belongs")
        + String(" to a PUBLISH step")
        + String(" (it checks what the step published)"),
    )


def test_validation_fields() raises:
    _assert_refused(
        _with_validation(_v(String("kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"release/s.mojo\""))),
        String("line 11: a validation of step 'publish' of stage 'p' has no name"),
    )
    _assert_refused(
        _with_validation(_v(String("name: \"Smoke\" kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"release/s.mojo\""))),
        String("has name 'Smoke'; a validation name is [a-z][a-z0-9-]*"),
    )
    _assert_refused(
        _with_validation(_v(String("name: \"v\" install: \"a\" program: \"release/s.mojo\""))),
        String("validation 'v' of step 'publish' of stage 'p' has no kind (CONDA_INSTALL_SMOKE, CONDA_INSTALL_ENV or DEPLOY_PROBE)"),
    )
    _assert_refused(
        _with_validation(_v(String("name: \"v\" kind: PYTEST install: \"a\" program: \"release/s.mojo\""))),
        String("validation kind 'PYTEST' is not CONDA_INSTALL_SMOKE, CONDA_INSTALL_ENV or DEPLOY_PROBE"),
    )
    _assert_refused(
        _with_validation(_v(String("name: \"v\" kind: CONDA_INSTALL_SMOKE program: \"release/s.mojo\""))),
        String("validation 'v' of step 'publish' of stage 'p' has no install (a package to install)"),
    )
    _assert_refused(
        _with_validation(_v(String("name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"a\""))),
        String("has no program (the program to run)"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" install: \"komira_all\"")),
        String("names install 'komira_all' twice"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" install: \"Komira\"")),
        String("has install 'Komira'; a package name is [a-z0-9_.-]+"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" tool: pixi")),
        String("unknown field 'tool' in validation 'v' (expected name, kind, image, install, compiler_channel,")
        + String(" extra_channel, program, smoke, wait_for_index_seconds, args, target, timeout_seconds, expect)"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" program: \"release/t.mojo\"")),
        String("field 'program' is set twice in validation 'v'"),
    )


comptime _V_ENV: String = (
    "name: \"v\" kind: CONDA_INSTALL_ENV install: \"komira_encoding\""
    " compiler_channel: \"https://conda.modular.com/max\" extra_channel: \"conda-forge\" wait_for_index_seconds: 1800"
)
"""A CONDA_INSTALL_ENV validation: no image, no program."""


def test_env_validation_reads_back() raises:
    var g = parse_machine_file(_with_validation(String(_V_ENV)), String(_SRC))
    ref v = g.stages[0].steps[0].validations[0]
    assert_equal(v.kind, String("CONDA_INSTALL_ENV"))
    assert_equal(v.image, String(""))
    assert_equal(v.program, String(""))
    assert_equal(len(v.installs), 1)
    assert_equal(v.wait_for_index_seconds, 1800)


def test_env_validation_runs_no_container_and_names_no_program() raises:
    # an ENV validation runs on this machine: an image is refused, digest or
    # not (any image is the container kind's field)
    _assert_refused(
        _with_validation(String(_V_ENV) + String(" image: \"") + String(_IMAGE) + String("\"")),
        String("line 11: validation 'v' of step 'publish' of stage 'p' has image '") + String(_IMAGE)
        + String("'; a CONDA_INSTALL_ENV validation runs on this machine with no container"),
    )
    # what it runs is each installed library's README, so a program is refused
    _assert_refused(
        _with_validation(String(_V_ENV) + String(" program: \"release/smoke.mojo\"")),
        String("has program 'release/smoke.mojo'; a CONDA_INSTALL_ENV validation runs each installed library's README"),
    )
    # the rest of the rules are the container kind's
    _assert_refused(
        _with_validation(String("name: \"v\" kind: CONDA_INSTALL_ENV compiler_channel: \"https://conda.modular.com/max\"")),
        String("has no install (a package to install)"),
    )
    _assert_refused(
        _with_validation(String("name: \"v\" kind: CONDA_INSTALL_ENV install: \"komira_encoding\"")),
        String("has no compiler_channel"),
    )


def test_env_validation_smoke_is_the_readme() raises:
    # omitted or written, the one word: each installed library's README
    var g = parse_machine_file(_with_validation(String(_V_ENV) + String(" smoke: README")), String(_SRC))
    assert_equal(g.stages[0].steps[0].validations[0].smoke, String("README"))
    var g0 = parse_machine_file(_with_validation(String(_V_ENV)), String(_SRC))
    assert_equal(g0.stages[0].steps[0].validations[0].smoke, String(""))
    # a closed vocabulary: a typo cannot become a validation that runs nothing
    for bad in [String("NONE"), String("readme"), String("skip")]:
        _assert_refused(
            _with_validation(String(_V_ENV) + String(" smoke: ") + bad),
            String("has smoke '") + bad + String("'; the one word is README"),
        )
    # set twice
    _assert_refused(
        _with_validation(String(_V_ENV) + String(" smoke: README smoke: README")),
        String("field 'smoke' is set twice"),
    )
    # the container kind runs its program
    _assert_refused(
        _with_validation(String(_V_OK) + String(" smoke: README")),
        String("has smoke 'README'; a CONDA_INSTALL_SMOKE validation runs its program"),
    )


def test_validation_image_is_pinned_by_digest() raises:
    var base = String("name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"release/s.mojo\"")
    base += String(" compiler_channel: \"https://conda.modular.com/max\"")
    _assert_refused(
        _with_validation(base),
        String("validation 'v' of step 'publish' of stage 'p' has no image (the container image, pinned by digest)"),
    )
    var hex64 = String("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    var bad = List[String]()
    bad.append(String("ghcr.io/prefix-dev/pixi:0.67.2-bookworm-slim"))  # a tag alone
    bad.append(String("ghcr.io/prefix-dev/pixi@sha256:") + String(hex64[byte=0:63]))  # 63 hex
    bad.append(String("ghcr.io/prefix-dev/pixi@sha256:") + hex64.upper())  # upper case
    bad.append(String("@sha256:") + hex64)  # no reference
    bad.append(String("a@b@sha256:") + hex64)  # a second @
    bad.append(String("ghcr.io/x y@sha256:") + hex64)  # a space
    bad.append(String("ghcr.io/x@sha512:") + hex64 + hex64)  # another digest
    for i in range(len(bad)):
        _assert_refused(
            _with_validation(base + String(" image: \"") + bad[i] + String("\"")),
            String("has image '") + bad[i] + String("'; an image is pinned by digest, <reference>@sha256:<64 lowercase hex>"),
        )
    assert_true(is_digest_pinned_image(String(_IMAGE)))


def test_validation_compiler_channel() raises:
    var base = String("name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"release/s.mojo\"")
    base += String(" image: \"") + String(_IMAGE) + String("\"")
    _assert_refused(
        _with_validation(base),
        String("has no compiler_channel (the channel mojo-compiler comes from)"),
    )
    _assert_refused(
        _with_validation(base + String(" compiler_channel: \"conda-forge\"")),
        String("has compiler_channel 'conda-forge'; a compiler channel is an https:// URL"),
    )
    _assert_refused(
        _with_validation(
            base + String(" compiler_channel: \"https://conda.modular.com/max\" extra_channel: \"https://conda.modular.com/max\"")
        ),
        String("names 'https://conda.modular.com/max' as compiler_channel and as extra_channel"),
    )


def test_validation_wait_for_index_seconds() raises:
    var g = parse_machine_file(_with_validation(String(_V_OK) + String(" wait_for_index_seconds: 3600")), String(_SRC))
    assert_equal(g.stages[0].steps[0].validations[0].wait_for_index_seconds, 3600)
    # 0 stays allowed and means no wait: the default applies only when unset
    var g0 = parse_machine_file(_with_validation(String(_V_OK) + String(" wait_for_index_seconds: 0")), String(_SRC))
    assert_equal(g0.stages[0].steps[0].validations[0].wait_for_index_seconds, 0)
    _assert_refused(
        _with_validation(String(_V_OK) + String(" wait_for_index_seconds: 3601")),
        String("has wait_for_index_seconds 3601; it is 0 to 3600"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" wait_for_index_seconds: \"ten\"")),
        String("field 'wait_for_index_seconds' of validation 'v' is 'ten'; it is a whole number of seconds"),
    )
    _assert_refused(
        _with_validation(String(_V_OK) + String(" wait_for_index_seconds: 1.5")),
        String("is '1.5'; it is a whole number of seconds"),
    )


def test_validation_extra_channel() raises:
    _assert_refused(
        _with_validation(String(_V_OK) + String(" extra_channel: \"http://conda.example.invalid/x\"")),
        String("has extra_channel 'http://conda.example.invalid/x'; an extra channel is an https:// URL or conda-forge"),
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
    bad.append(String("release/smoke.py"))
    bad.append(String("release/../smoke.mojo"))
    bad.append(String(".mojo"))
    # outside release/
    bad.append(String("src/smoke.mojo"))
    bad.append(String("releases/smoke.mojo"))
    for i in range(len(bad)):
        _assert_refused(
            _with_validation(
                _v(String("name: \"v\" kind: CONDA_INSTALL_SMOKE install: \"a\" program: \"") + bad[i] + String("\""))
            ),
            String("has program '") + bad[i] + String("'; a program is a relative path to a .mojo file under release/"),
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
        + String("  artifacts: \"d\"\n  channels: \"c\"\n  channel: \"prod\"\n")
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
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD artifacts: \"d\" }\n")),
        String("step 's' of stage 'b' has no platform"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"darwin-arm64\" artifacts: \"d\" }\n")),
        String("darwin-arm64"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" }\n")),
        String("has no artifacts"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" channel: \"prod\" }\n")),
        String("is a BUILD step: channels and channel belong to a PUBLISH step"),
    )
    _assert_refused(
        _one_stage(String(" name: \"p\"\n step { name: \"s\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d\" channel: \"prod\" }\n")),
        String("has no channels"),
    )
    _assert_refused(
        _one_stage(String(" name: \"p\"\n step { name: \"s\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d\" channels: \"c\" }\n")),
        String("has no channel (the channel to publish to)"),
    )


def _chain(build_bg: String, gamma_bg: String, prod_bg: String) -> String:
    """build -> gamma -> prod, each stage's `break_glass` line as given
    ("" for none)."""
    return (
        String("schema_version: 1\n")
        + String("stage {\n name: \"build\"\n") + build_bg + String(_BUILD_STEP) + String("}\n")
        + String("stage {\n name: \"gamma\"\n after: \"build\"\n") + gamma_bg + String(_PUBLISH_STEP) + String("}\n")
        + String("stage {\n name: \"prod\"\n after: \"gamma\"\n") + prod_bg + String(_PUBLISH_STEP) + String("}\n")
    )


def test_break_glass_defaults_to_false_and_reads_back() raises:
    var none = parse_machine_file(_chain(String(""), String(""), String("")), String(_SRC))
    for i in range(len(none.stages)):
        assert_false(none.stages[i].break_glass)
    var g = parse_machine_file(
        _chain(String(" break_glass: true\n"), String(" break_glass: true\n"), String(" break_glass: false\n")),
        String(_SRC),
    )
    assert_true(g.stage(String("build")).break_glass)
    assert_true(g.stage(String("gamma")).break_glass)
    assert_false(g.stage(String("prod")).break_glass)


def test_break_glass_refusals() raises:
    _assert_refused(
        _one_stage(String(" name: \"b\"\n break_glass: yes\n") + String(_BUILD_STEP)),
        String("line 4: field 'break_glass' of stage 'b' is 'yes'; it is true or false"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n break_glass: true\n break_glass: true\n") + String(_BUILD_STEP)),
        String("field 'break_glass' is set twice in stage 'b'"),
    )
    # break-glass is a PREFIX of the chain: a stage that runs after a
    # main-only stage cannot run off main
    _assert_refused(
        _chain(String(" break_glass: true\n"), String(""), String(" break_glass: true\n")),
        String("stage 'prod' is break_glass and runs after 'gamma', which is not"),
    )
    _assert_refused(
        _chain(String(""), String(" break_glass: true\n"), String("")),
        String("stage 'gamma' is break_glass and runs after 'build', which is not"),
    )
    # a pull request's check is no release stage
    _assert_refused(
        _pr_and_release(String(" trigger: PULL_REQUEST\n break_glass: true\n") + String(_BUILD_STEP)),
        String("stage 'pr' is a PULL_REQUEST stage and is break_glass"),
    )


def test_break_glass_environment() raises:
    var g = parse_machine_file(
        _chain(
            String(" break_glass: true\n"),
            String(" break_glass: true\n break_glass_environment: \"gamma-breakglass\"\n"),
            String(""),
        ),
        String(_SRC),
    )
    assert_equal(g.stage(String("gamma")).break_glass_environment, String("gamma-breakglass"))
    assert_equal(g.stage(String("gamma")).environment, String("gamma"))
    assert_equal(g.stage(String("build")).break_glass_environment, String(""))
    # only a break_glass stage has one
    _assert_refused(
        _chain(String(" break_glass: true\n"), String(" break_glass: true\n"), String(" break_glass_environment: \"p-bg\"\n")),
        String("stage 'prod' has break_glass_environment 'p-bg' and is not break_glass"),
    )
    # an environment name, and not the stage's own environment
    _assert_refused(
        _chain(String(" break_glass: true\n"), String(" break_glass: true\n break_glass_environment: \"Gamma_BG\"\n"), String("")),
        String("stage 'gamma' has break_glass_environment 'Gamma_BG'; an environment name is"),
    )
    _assert_refused(
        _chain(String(" break_glass: true\n"), String(" break_glass: true\n break_glass_environment: \"gamma\"\n"), String("")),
        String("stage 'gamma' has break_glass_environment 'gamma', the stage's own environment"),
    )
    _assert_refused(
        _chain(
            String(" break_glass: true\n"),
            String(" break_glass: true\n break_glass_environment: \"a\"\n break_glass_environment: \"b\"\n"),
            String(""),
        ),
        String("field 'break_glass_environment' is set twice in stage 'gamma'"),
    )


# ---- the parser's remaining paths: optional ':' before '{', a block left
# open, a value that is no scalar, `after` twice, `has_stage`, the
# install package-name grammar ------------------------------------------------


def test_a_colon_before_each_block_is_optional() raises:
    # `stage: {`, `step: {` and `validation: {` read as `stage {` ... do
    var text = (
        String("schema_version: 1\nstage: {\n name: \"p\"\n")
        + String("step: {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n")
        + String("  artifacts: \"a\"\n  channels: \"c\"\n  channel: \"gamma\"\n")
        + String("  validation: { ") + String(_V_OK) + String(" }\n}\n}\n")
    )
    var g = parse_machine_file(text, String(_SRC))
    assert_equal(len(g.stages), 1)
    assert_equal(g.stages[0].name, String("p"))
    assert_equal(len(g.stages[0].steps), 1)
    assert_equal(g.stages[0].steps[0].channel, String("gamma"))
    assert_equal(len(g.stages[0].steps[0].validations), 1)
    assert_equal(g.stages[0].steps[0].validations[0].name, String("v"))
    assert_equal(g.stages[0].steps[0].validations[0].line, 11)


def test_a_step_or_validation_left_open() raises:
    # the step opens on line 4 and the file ends inside it
    _assert_refused(
        String("schema_version: 1\nstage {\n name: \"b\"\n step { name: \"s\" kind: BUILD\n"),
        String("machine file: line 4: a step of stage 'b' is not closed (expected '}')"),
    )
    # the validation opens on line 11 (as `_with_validation`'s) and the
    # file ends inside it, named and unnamed
    var head = (
        String("schema_version: 1\nstage {\n name: \"p\"\n")
        + String("step {\n  name: \"publish\"\n  kind: PUBLISH\n  platform: \"linux-x86_64\"\n")
        + String("  artifacts: \"a\"\n  channels: \"c\"\n  channel: \"gamma\"\n  validation { ")
    )
    _assert_refused(
        head + String("name: \"v\" kind: CONDA_INSTALL_SMOKE\n"),
        String("machine file: line 11: validation 'v' is not closed (expected '}')"),
    )
    _assert_refused(
        head + String("kind: CONDA_INSTALL_SMOKE\n"),
        String("machine file: line 11: a validation of step 'publish' of stage 'p' is not closed (expected '}')"),
    )


def test_a_value_that_is_not_a_scalar() raises:
    _assert_refused(
        _one_stage(String(" name: {\n") + String(_BUILD_STEP)),
        String("machine file: line 3: expected a value for 'name' but got '{'"),
    )
    _assert_refused(
        _one_stage(String(" name: \"b\"\n step { name: \"s\" kind: }\n")),
        String("machine file: line 4: expected a value for 'kind' but got '}'"),
    )


def test_after_set_twice() raises:
    var text = (
        String("schema_version: 1\nstage { name: \"a\" ") + String(_BUILD_STEP) + String("}\n")
        + String("stage { name: \"b\" ") + String(_BUILD_STEP) + String("}\n")
        + String("stage {\n name: \"c\"\n after: \"a\"\n after: \"b\"\n") + String(_PUBLISH_STEP) + String("}\n")
    )
    _assert_refused(text, String("machine file: line 9: field 'after' is set twice in stage 'c'"))


def test_has_stage() raises:
    var g = parse_machine_file(_two_stages(), String(_SRC))
    assert_true(g.has_stage(String("build")))
    assert_true(g.has_stage(String("prod")))
    assert_false(g.has_stage(String("gamma")))
    assert_false(g.has_stage(String("")))
    assert_false(g.has_stage(String("pro")))


def test_install_package_name_grammar() raises:
    # every byte the grammar allows, and a digit first
    var g = parse_machine_file(
        _with_validation(String(_V_OK) + String(" install: \"9lib_a.b-c\" install: \"z0\"")), String(_SRC)
    )
    ref installs = g.stages[0].steps[0].validations[0].installs
    assert_equal(len(installs), 3)
    assert_equal(installs[1], String("9lib_a.b-c"))
    assert_equal(installs[2], String("z0"))
    # empty, and a refused byte after an allowed first byte
    _assert_refused(
        _with_validation(String(_V_OK) + String(" install: \"\"")),
        String("line 11: validation 'v' of step 'publish' of stage 'p' has install ''; a package name is [a-z0-9_.-]+"),
    )
    var bad = List[String]()
    bad.append(String("komira+x"))
    bad.append(String("komira/x"))
    bad.append(String("komira X"))
    bad.append(String("komiraA"))
    bad.append(String("a{"))
    # the neighbours of each range boundary: backtick (96) and ':' (58)
    bad.append(String("komira`x"))
    bad.append(String("komira:x"))
    # '_', '.' and '-' are allowed, but not as the first byte
    bad.append(String("_a"))
    bad.append(String(".a"))
    bad.append(String("-a"))
    for i in range(len(bad)):
        _assert_refused(
            _with_validation(String(_V_OK) + String(" install: \"") + bad[i] + String("\"")),
            String("has install '") + bad[i] + String("'; a package name is [a-z0-9_.-]+"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
