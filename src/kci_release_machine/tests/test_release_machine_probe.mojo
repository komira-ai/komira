# =============================================================================
# src/kci_release_machine/tests/test_release_machine_probe.mojo
#   The DEPLOY_PROBE validation kind's grammar: a probe read back through the
#   parser, a red case for each field rule (probe.mojo), and the pairing of
#   kinds with steps (graph.mojo): CONDA_* on PUBLISH only, DEPLOY_PROBE on
#   DEPLOY only. Each refusal is asserted by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_machine import (
    PROBE_TIMEOUT_MAX_SECONDS,
    StageStep,
    StageValidation,
    has_probe,
    is_probe_case_id,
    parse_machine_file,
)


comptime _SRC: String = "machine file"

comptime _IMAGE: String = "registry.example.invalid/probe@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

comptime _WHERE: String = "machine file: line 6: validation 'probe' of step 'deploy' of stage 'staging'"
"""Where every probe refusal of `_probe_machine` points: its block opens on
line 6."""


def _probe_machine(fields: String) -> String:
    """One stage, one DEPLOY step, one validation block of `fields` opening
    on line 6."""
    return (
        String("schema_version: 1\nname: \"shop\"\nstage {\n name: \"staging\"\n")
        + String(" step {\n  validation {") + fields + String(" }\n")
        + String("  name: \"deploy\" kind: DEPLOY cells: \"release/cells.textproto\" cell: \"staging\"")
        + String(" resources: \"deploy/app.json\"\n }\n}\n")
    )


def _probe(rest: String) -> String:
    """A probe's name and kind, then `rest`."""
    return String(" name: \"probe\" kind: DEPLOY_PROBE ") + rest


def _ok(extra: String = String("")) -> String:
    """A probe with every required field (image, timeout_seconds, one
    expect), then `extra`."""
    return _probe(
        String("image: \"") + String(_IMAGE) + String("\" timeout_seconds: 60 expect: \"health\" ") + extra
    )


def _refusal(text: String) -> String:
    try:
        _ = parse_machine_file(text, String(_SRC))
    except e:
        return String(e)
    return String("")


def _assert_refused(text: String, want: String) raises:
    var got = _refusal(text)
    if got.find(want) < 0:
        raise Error(String("expected a refusal containing '") + want + String("', got: '") + got + String("'"))


# ---- read back ---------------------------------------------------------------


def test_a_probe_reads_back() raises:
    var g = parse_machine_file(
        _probe_machine(
            _ok(
                String("args: \"--checks=smoke\" args: \"-v\" target { resource: \"api\" output: \"url\" }")
                + String(" expect: \"login\"")
            )
        ),
        String(_SRC),
    )
    ref v = g.stages[0].steps[0].validations[0]
    assert_equal(v.name, String("probe"))
    assert_equal(v.kind, String("DEPLOY_PROBE"))
    assert_equal(v.image, String(_IMAGE))
    assert_equal(len(v.args), 2)
    assert_equal(v.args[0], String("--checks=smoke"))
    assert_equal(v.args[1], String("-v"))
    assert_equal(v.target_resource, String("api"))
    assert_equal(v.target_output, String("url"))
    assert_equal(v.timeout_seconds, 60)
    assert_equal(len(v.expects), 2)
    assert_equal(v.expects[0], String("health"))
    assert_equal(v.expects[1], String("login"))
    assert_equal(v.line, 6)
    assert_true(v.wrote(String("target")))
    assert_false(v.wrote(String("install")))


def test_a_probe_with_no_target_or_args_reads_back() raises:
    var g = parse_machine_file(_probe_machine(_ok()), String(_SRC))
    ref v = g.stages[0].steps[0].validations[0]
    assert_equal(len(v.args), 0)
    assert_false(v.wrote(String("target")))
    assert_equal(v.target_resource, String(""))


# ---- image -------------------------------------------------------------------


def test_image_is_required_and_pinned_by_digest() raises:
    _assert_refused(
        _probe_machine(_probe(String("timeout_seconds: 60 expect: \"health\""))),
        String(_WHERE) + String(" has no image (the probe image, pinned by digest)"),
    )
    # a tag is refused: it names whatever the registry serves today
    _assert_refused(
        _probe_machine(_probe(String("image: \"registry.example.invalid/probe:1.0\" timeout_seconds: 60 expect: \"h\""))),
        String(_WHERE) + String(" has image 'registry.example.invalid/probe:1.0'; a probe image is pinned by digest"),
    )
    # a digest that is not 64 lowercase hex
    _assert_refused(
        _probe_machine(
            _probe(String("image: \"registry.example.invalid/probe@sha256:ABC\" timeout_seconds: 60 expect: \"h\""))
        ),
        String(" has image 'registry.example.invalid/probe@sha256:ABC'; a probe image is pinned by digest"),
    )


def test_every_probe_on_a_step_is_checked() raises:
    # A valid probe on line 6, then a second probe on line 7 whose image is a
    # tag: the second is refused, so the field rules hold for every probe on a
    # step, not only the first.
    var second = (
        String(" }\n  validation { name: \"probe2\" kind: DEPLOY_PROBE")
        + String(" image: \"registry.example.invalid/probe:1.0\" timeout_seconds: 60 expect: \"h\"")
    )
    _assert_refused(
        _probe_machine(_ok() + second),
        String("machine file: line 7: validation 'probe2' of step 'deploy' of stage 'staging'")
        + String(" has image 'registry.example.invalid/probe:1.0'; a probe image is pinned by digest"),
    )
    # and two valid probes are accepted
    var g = parse_machine_file(
        _probe_machine(
            _ok()
            + String(" }\n  validation { name: \"probe2\" kind: DEPLOY_PROBE image: \"")
            + String(_IMAGE)
            + String("\" timeout_seconds: 30 expect: \"login\"")
        ),
        String(_SRC),
    )
    assert_equal(len(g.stages[0].steps[0].validations), 2)
    assert_equal(g.stages[0].steps[0].validations[1].line, 7)


# ---- args --------------------------------------------------------------------


def test_args_may_not_carry_the_flags_kci_appends() raises:
    _assert_refused(
        _probe_machine(_ok(String("args: \"--validation-run-id=mine\""))),
        String(_WHERE) + String(" has args '--validation-run-id=mine'; kci appends --validation-run-id and")
        + String(" --target-url itself"),
    )
    _assert_refused(
        _probe_machine(_ok(String("args: \"--target-url\""))),
        String(_WHERE) + String(" has args '--target-url'; kci appends"),
    )
    # every arg is checked, not only the first: a harmless first arg, then
    # the flag kci appends
    _assert_refused(
        _probe_machine(_ok(String("args: \"-v\" args: \"--target-url=x\""))),
        String(_WHERE) + String(" has args '--target-url=x'; kci appends"),
    )
    # a flag that only starts with the same letters is the image's own
    var g = parse_machine_file(_probe_machine(_ok(String("args: \"--target-urls=a,b\""))), String(_SRC))
    assert_equal(g.stages[0].steps[0].validations[0].args[0], String("--target-urls=a,b"))


# ---- target ------------------------------------------------------------------


def test_target_needs_a_resource_and_an_output() raises:
    _assert_refused(
        _probe_machine(_ok(String("target { output: \"url\" }"))),
        String(_WHERE) + String(" has a target with no resource (the resource whose output it reads)"),
    )
    _assert_refused(
        _probe_machine(_ok(String("target { resource: \"api\" }"))),
        String(_WHERE) + String(" has a target with no output (the output of resource 'api' it reads)"),
    )
    _assert_refused(
        _probe_machine(_ok(String("target { }"))),
        String(_WHERE) + String(" has a target with no resource"),
    )
    _assert_refused(
        _probe_machine(_ok(String("target { resource: \"api\" output: \"url\" port: \"80\" }"))),
        String("unknown field 'port' in the target of validation 'probe' (expected resource, output)"),
    )
    _assert_refused(
        _probe_machine(_ok(String("target { resource: \"a\" resource: \"b\" output: \"url\" }"))),
        String("field 'resource' is set twice in the target of validation 'probe'"),
    )
    _assert_refused(
        _probe_machine(_ok(String("target { resource: \"a\" output: \"url\" } target { resource: \"a\" output: \"url\" }"))),
        String("field 'target' is set twice in validation 'probe'"),
    )


# ---- timeout_seconds ---------------------------------------------------------


def test_timeout_is_required_and_bounded() raises:
    _assert_refused(
        _probe_machine(_probe(String("image: \"") + String(_IMAGE) + String("\" expect: \"health\""))),
        String(_WHERE) + String(" has no timeout_seconds"),
    )
    var head = String("image: \"") + String(_IMAGE) + String("\" expect: \"health\" timeout_seconds: ")
    _assert_refused(
        _probe_machine(_probe(head + String("0"))),
        String(_WHERE) + String(" has timeout_seconds 0; it is 1 to 3600"),
    )
    _assert_refused(
        _probe_machine(_probe(head + String("3601"))),
        String(_WHERE) + String(" has timeout_seconds 3601; it is 1 to 3600"),
    )
    _assert_refused(
        _probe_machine(_probe(head + String("\"60\""))),
        String("field 'timeout_seconds' of validation 'probe' is '60'; it is a whole number of seconds"),
    )
    # both ends of the range are accepted
    assert_equal(PROBE_TIMEOUT_MAX_SECONDS, 3600)
    var one = parse_machine_file(_probe_machine(_probe(head + String("1"))), String(_SRC))
    assert_equal(one.stages[0].steps[0].validations[0].timeout_seconds, 1)
    var most = parse_machine_file(_probe_machine(_probe(head + String("3600"))), String(_SRC))
    assert_equal(most.stages[0].steps[0].validations[0].timeout_seconds, 3600)


# ---- expect ------------------------------------------------------------------


def test_expect_ids() raises:
    var head = String("image: \"") + String(_IMAGE) + String("\" timeout_seconds: 60")
    _assert_refused(
        _probe_machine(_probe(head)),
        String(_WHERE) + String(" has no expect (a case id the image reports on)"),
    )
    _assert_refused(
        _probe_machine(_probe(head + String(" expect: \"Health\""))),
        String(_WHERE) + String(" has expect 'Health'; a case id is [a-z0-9_-]+"),
    )
    _assert_refused(
        _probe_machine(_probe(head + String(" expect: \"\""))),
        String(_WHERE) + String(" has expect ''; a case id is [a-z0-9_-]+"),
    )
    _assert_refused(
        _probe_machine(_probe(head + String(" expect: \"a\" expect: \"b\" expect: \"a\""))),
        String(_WHERE) + String(" names expect 'a' twice"),
    )
    # every expect is checked, not only the first: a valid first id, then a
    # bad one
    _assert_refused(
        _probe_machine(_probe(head + String(" expect: \"health\" expect: \"Bad\""))),
        String(_WHERE) + String(" has expect 'Bad'; a case id is [a-z0-9_-]+"),
    )
    # a repeat is found against every earlier id, not only the first
    _assert_refused(
        _probe_machine(_probe(head + String(" expect: \"a\" expect: \"b\" expect: \"b\""))),
        String(_WHERE) + String(" names expect 'b' twice"),
    )
    assert_true(is_probe_case_id(String("login_2-fast")))
    assert_false(is_probe_case_id(String("a.b")))
    assert_false(is_probe_case_id(String("a b")))


def test_case_id_bad_byte_last() raises:
    # the bad byte is the last one, so a loop that stops one byte early lets
    # it through
    assert_false(is_probe_case_id(String("ab.")))
    assert_false(is_probe_case_id(String("abC")))
    assert_false(is_probe_case_id(String("health.")))
    var head = String("image: \"") + String(_IMAGE) + String("\" timeout_seconds: 60")
    _assert_refused(
        _probe_machine(_probe(head + String(" expect: \"health.\""))),
        String(_WHERE) + String(" has expect 'health.'; a case id is [a-z0-9_-]+"),
    )


def test_case_id_byte_bounds() raises:
    # just above 'z' (123..126) and non-ASCII: a dropped upper bound on
    # [a-z] lets these through
    assert_false(is_probe_case_id(String("a{")))
    assert_false(is_probe_case_id(String("a|")))
    assert_false(is_probe_case_id(String("a~")))
    assert_false(is_probe_case_id(String("aé")))
    # the neighbours of every other class bound: '`' (96), '/' (47), ':' (58),
    # ',' (44), '.' (46), '^' (94), '@' (64), 'A', 'Z'
    assert_false(is_probe_case_id(String("a`")))
    assert_false(is_probe_case_id(String("a/")))
    assert_false(is_probe_case_id(String("a:")))
    assert_false(is_probe_case_id(String("a,")))
    assert_false(is_probe_case_id(String("a.")))
    assert_false(is_probe_case_id(String("a^")))
    assert_false(is_probe_case_id(String("a@")))
    assert_false(is_probe_case_id(String("aA")))
    assert_false(is_probe_case_id(String("aZ")))
    # every bound itself is in [a-z0-9_-]+, so none can be tightened
    assert_true(is_probe_case_id(String("a")))
    assert_true(is_probe_case_id(String("z")))
    assert_true(is_probe_case_id(String("0")))
    assert_true(is_probe_case_id(String("9")))
    assert_true(is_probe_case_id(String("_")))
    assert_true(is_probe_case_id(String("-")))
    assert_true(is_probe_case_id(String("a-z_09")))


# ---- has_probe ---------------------------------------------------------------


def test_has_probe_looks_at_every_validation() raises:
    # Through the parser a DEPLOY step carries DEPLOY_PROBE validations only
    # (graph.mojo), so the promoted-DEPLOY rule cannot reach a probe that is
    # not first. has_probe is public and says "at least one": a step whose
    # probe is its second validation has one.
    var step = StageStep(1)
    step.kind = String("DEPLOY")
    assert_false(has_probe(step))
    var smoke = StageValidation(2)
    smoke.kind = String("CONDA_INSTALL_SMOKE")
    step.validations.append(smoke^)
    assert_false(has_probe(step))
    var probe = StageValidation(3)
    probe.kind = String("DEPLOY_PROBE")
    step.validations.append(probe^)
    assert_true(has_probe(step))


# ---- the CONDA_* fields, and secret_env ---------------------------------------


def test_a_probe_writes_no_conda_field() raises:
    var fields = List[String]()
    fields.append(String("install: \"komira_all\""))
    fields.append(String("compiler_channel: \"https://conda.example\""))
    fields.append(String("extra_channel: \"conda-forge\""))
    fields.append(String("program: \"release/s.mojo\""))
    fields.append(String("smoke: README"))
    fields.append(String("wait_for_index_seconds: 1800"))
    var names = List[String]()
    names.append(String("install"))
    names.append(String("compiler_channel"))
    names.append(String("extra_channel"))
    names.append(String("program"))
    names.append(String("smoke"))
    names.append(String("wait_for_index_seconds"))
    for i in range(len(fields)):
        _assert_refused(
            _probe_machine(_ok(fields[i])),
            String(_WHERE) + String(" is a DEPLOY_PROBE validation and has ") + names[i]
            + String(": it belongs to a CONDA_INSTALL_SMOKE or CONDA_INSTALL_ENV validation"),
        )


def test_secret_env_is_refused() raises:
    _assert_refused(
        _probe_machine(_ok(String("secret_env: \"TOKEN\""))),
        String("line 6: validation 'probe' has secret_env: a validation passes no secret in its environment"),
    )


# ---- kinds and steps ---------------------------------------------------------


comptime _PUBLISH_HEAD: String = (
    "  name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"release/artifacts.textproto\""
    " channels: \"release/channels.textproto\" channel: \"gamma\"\n"
)

comptime _BUILD_HEAD: String = (
    "  name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"release/artifacts.textproto\"\n"
)

comptime _SMOKE_FIELDS: String = (
    " name: \"smoke\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\" program: \"release/smoke.mojo\""
    " image: \"registry.example.invalid/pixi:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
    " compiler_channel: \"https://conda.modular.com/max\""
)

comptime _ENV_FIELDS: String = (
    " name: \"env\" kind: CONDA_INSTALL_ENV install: \"komira_all\" compiler_channel: \"https://conda.modular.com/max\""
)


def _step_machine(head: String, fields: String) -> String:
    """One stage, one step of `head`, one validation of `fields` opening on
    line 6."""
    return (
        String("schema_version: 1\nname: \"shop\"\nstage {\n name: \"release\"\n step {\n  validation {")
        + fields + String(" }\n") + head + String(" }\n}\n")
    )


def test_conda_kinds_are_refused_on_a_deploy_step() raises:
    _assert_refused(
        _probe_machine(String(_SMOKE_FIELDS)),
        String("line 6: validation 'smoke' of step 'deploy' of stage 'staging': a CONDA_INSTALL_SMOKE validation")
        + String(" belongs to a PUBLISH step (it checks what the step published)"),
    )
    _assert_refused(
        _probe_machine(String(_ENV_FIELDS)),
        String("line 6: validation 'env' of step 'deploy' of stage 'staging': a CONDA_INSTALL_ENV validation")
        + String(" belongs to a PUBLISH step"),
    )


def test_a_probe_is_refused_on_build_and_on_publish() raises:
    _assert_refused(
        _step_machine(String(_PUBLISH_HEAD), _ok()),
        String("line 6: validation 'probe' of step 'publish' of stage 'release': a DEPLOY_PROBE validation belongs")
        + String(" to a DEPLOY step (it checks the cell the step deployed into)"),
    )
    _assert_refused(
        _step_machine(String(_BUILD_HEAD), _ok()),
        String("line 6: validation 'probe' of step 'build' of stage 'release': a DEPLOY_PROBE validation belongs")
        + String(" to a DEPLOY step"),
    )


def test_conda_kinds_write_no_probe_field() raises:
    var fields = List[String]()
    fields.append(String(" args: \"-v\""))
    fields.append(String(" target { resource: \"api\" output: \"url\" }"))
    fields.append(String(" timeout_seconds: 60"))
    fields.append(String(" expect: \"health\""))
    var names = List[String]()
    names.append(String("args"))
    names.append(String("target"))
    names.append(String("timeout_seconds"))
    names.append(String("expect"))
    for i in range(len(fields)):
        _assert_refused(
            _step_machine(String(_PUBLISH_HEAD), String(_SMOKE_FIELDS) + fields[i]),
            String("validation 'smoke' of step 'publish' of stage 'release' is a CONDA_INSTALL_SMOKE validation and")
            + String(" has ") + names[i] + String(": it belongs to a DEPLOY_PROBE validation"),
        )
    _assert_refused(
        _step_machine(String(_PUBLISH_HEAD), String(_ENV_FIELDS) + String(" timeout_seconds: 0")),
        String("is a CONDA_INSTALL_ENV validation and has timeout_seconds: it belongs to a DEPLOY_PROBE validation"),
    )
    # the same validations without a probe field are accepted on PUBLISH
    var g = parse_machine_file(_step_machine(String(_PUBLISH_HEAD), String(_SMOKE_FIELDS)), String(_SRC))
    assert_equal(g.stages[0].steps[0].validations[0].kind, String("CONDA_INSTALL_SMOKE"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
