# =============================================================================
# test_job_vm_s0_fields_refused — the declared-but-not-honoured job-VM BUNDLE
#   fields PARSE, and `validate_bundle` REFUSES EACH ONE BY NAME until the
#   deploy honours it.
# =============================================================================
#
#   VALUE_FROM_COMPUTE_ENV_* (x5), arg / parameter -> refused until resolved
#   VALUE_FROM_COMPUTE_ENV_* (x5), any `env` entry -> NEVER (argv-only)
#   AppParameter.from_build (arm 6)                -> refused until resolved
#   RunContainer.own_identity                      -> refused until composed
#   RunContainer.reads_telemetry JOB_VM_STATE      -> refused until granted
#   Wave.api_edge_services                         -> refused until composed
#   BuildTarget.file_role / repository_role        -> refused until staged
#
# ── WHY A REFUSAL PER FIELD, AND WHY EACH IS NAMED ───────────────────────────
# Each of these PARSES and RE-EMITS (`test_emit_completeness` holds that) and
# NOTHING composes, resolves or grants from it yet. Parsed-then-ignored is the
# fail-quiet answer: the author reads the bundle as saying something the deploy
# never does. And an EXPECT_* arg sourced from an unresolved `VALUE_FROM_*` is
# worse than ignored — it is omitted from argv and the validator grades the VM
# against its own default: a hollow green.
#
# ── THE LEGS ─────────────────────────────────────────────────────────────────
#   (C) the CONTROL: the base bundle validates CLEAN — so every refusal below is
#       caused by the ONE line each case adds, not by the fixture.
#   (V) each COMPUTE_ENV ValueFrom, on a validate-step ARG, on a validate-step
#       ENV var, on a served PARAMETER and on a wave ENV OVERRIDE — the refusal
#       lives in the shared fan-in helpers, so every channel must inherit it.
#       ⛔ The two ENV channels are refused PERMANENTLY: a binary's configuration
#       is a command-line flag, so a validator's EXPECT_* configuration is
#       argv-only — the run id's and the lifecycle env name's rule (b) — so their
#       refusal must say ARGV-ONLY and must NOT carry the "becomes honourable
#       when …" promise. The ARG and PARAMETER channels keep the
#       declared-but-not-honoured refusal until the resolution lands on argv.
#   (F)(O)(T)(W)(B) one case per remaining field.
#   Each case asserts the refusal names the FIELD and says "DECLARED but not yet
#   honoured".
#
# ⚠ COLLECT-EVERY-RED: every case runs; `main` reports every failure.
# Pure parse + validate. No cloud.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_bundle.parser import parse_bundle
from kci_bundle.validate import validate_bundle


def _bundle(
    build_extra: String,
    spec_extra: String,
    step_extra: String,
    wave_extra: String,
) -> String:
    """One valid bundle (the `test_validate._vpc_egress_bundle` shape) with FOUR splice points — a build target,
    the spec, one run_container step, and the wave — each empty in the control."""
    return (
        String(
            "kind: APP_KIND_API\n"
            'name: "svc"\n'
            'build { name: "service" dockerfile: "Dockerfile" }\n'
            'build { name: "integ" dockerfile: "Dockerfile.integ"'
        )
        + build_extra
        + String(" }\nspec {\n  image { from_build: \"service\" }\n  port: 8080\n")
        + spec_extra
        + String(
            "}\n"
            "waves {\n"
            '  env: "gamma"\n'
            "  validate {\n"
            '    name: "integ"\n'
            "    run_container {\n"
            '      image { from_build: "integ" }\n'
            "      gate_on: GATE_ON_EXIT_CODE\n"
        )
        + step_extra
        + String("    }\n  }\n")
        + wave_extra
        + String("}\n")
    )


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _expect_s0_refusal(
    text: String, what: String, field_needle: String
) raises:
    var errs = _errs(text)
    var hit = False
    for ref e in errs:
        if e.find(field_needle) >= 0 and e.find(
            String("DECLARED but not yet honoured")
        ) >= 0:
            hit = True
    var joined = String("")
    for ref e in errs:
        joined += String("\n    ") + e
    assert_true(
        hit,
        what
        + String(": validate_bundle must REFUSE '")
        + field_needle
        + String("' BY NAME, saying it is declared but not yet honoured. errors:")
        + joined,
    )


def _expect_permanent_env_refusal(text: String, what: String, vf: String) raises:
    """The `env`-channel refusal: names the value, says ARGV-ONLY, says a
    binary's configuration is a command-line FLAG, and does NOT promise a later
    change. Checked on the ONE error that names `vf`."""
    var errs = _errs(text)
    var hit = String("")
    for ref e in errs:
        if e.find(vf) >= 0:
            hit = e
    var joined = String("")
    for ref e in errs:
        joined += String("\n    ") + e
    assert_true(
        hit.byte_length() > 0,
        what + String(": validate_bundle must REFUSE '") + vf
        + String("' on an env channel. errors:") + joined,
    )
    assert_true(
        hit.find(String("ARGV-ONLY")) >= 0
        and hit.find(String("command-line FLAG")) >= 0,
        what + String(": the env-channel refusal must say ARGV-ONLY and that")
        + String(" configuration is a command-line FLAG — got: ") + hit,
    )
    assert_true(
        hit.find(String("becomes honourable")) < 0,
        what + String(": the env-channel refusal is PERMANENT and must NOT")
        + String(" promise a later change — got: ") + hit,
    )


# =============================================================================
# (C) the control
# =============================================================================
def test_the_base_bundle_validates_clean() raises:
    var errs = _errs(_bundle(String(""), String(""), String(""), String("")))
    var joined = String("")
    for ref e in errs:
        joined += String("\n    ") + e
    assert_equal(
        len(errs),
        0,
        String("(C) the base bundle must validate CLEAN, or every case below")
        + String(" proves nothing about its own line:")
        + joined,
    )
    print("  (C) the_base_bundle_validates_clean: PASS")


def _vf_names() -> List[String]:
    var v = List[String]()
    v.append(String("VALUE_FROM_COMPUTE_ENV_SERVICE_ACCOUNT"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_SUBNETWORK"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_ZONE"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_PROJECT"))
    v.append(String("VALUE_FROM_COMPUTE_ENV_PLACER"))
    return v^


# =============================================================================
# (V) every COMPUTE_ENV ValueFrom, on every channel
# =============================================================================
def test_every_compute_env_value_from_is_refused_on_every_channel() raises:
    for ref vf in _vf_names():
        var arg = (
            String('      args { name: "EXPECT_X" type: PARAM_TYPE_STRING')
            + String(" required: true value_from: ")
            + vf
            + String(" }\n")
        )
        _expect_s0_refusal(
            _bundle(String(""), String(""), arg, String("")),
            String("(V) validate-step arg ") + vf,
            vf,
        )
        var env = (
            String('      env { name: "EXPECT_X" value_from: ')
            + vf
            + String(" }\n")
        )
        _expect_permanent_env_refusal(
            _bundle(String(""), String(""), env, String("")),
            String("(V) validate-step env ") + vf,
            vf,
        )
        var prm = (
            String('  parameters { name: "EXPECT_X" type: PARAM_TYPE_STRING')
            + String(" value_from: ")
            + vf
            + String(" }\n")
        )
        _expect_s0_refusal(
            _bundle(String(""), prm, String(""), String("")),
            String("(V) served parameter ") + vf,
            vf,
        )
        var eo = (
            String('  env_override { name: "EXPECT_X" value_from: ')
            + vf
            + String(" }\n")
        )
        _expect_permanent_env_refusal(
            _bundle(String(""), String(""), String(""), eo),
            String("(V) wave env_override ") + vf,
            vf,
        )
    print("  (V) every_compute_env_value_from_is_refused_on_every_channel: PASS")


# =============================================================================
# (F) from_build — on a validate-step arg and on a served parameter
# =============================================================================
def test_from_build_is_refused() raises:
    _expect_s0_refusal(
        _bundle(
            String(""),
            String(""),
            String(
                '      args { name: "VM_PROBE_IMAGE" type: PARAM_TYPE_STRING'
                ' required: true from_build: "integ" }\n'
            ),
            String(""),
        ),
        String("(F) validate-step arg"),
        String("from_build"),
    )
    _expect_s0_refusal(
        _bundle(
            String(""),
            String(
                '  parameters { name: "VM_POD_LOADER_URL" type: PARAM_TYPE_STRING'
                ' from_build: "integ" }\n'
            ),
            String(""),
            String(""),
        ),
        String("(F) served parameter"),
        String("from_build"),
    )
    print("  (F) from_build_is_refused: PASS")


# =============================================================================
# (O)(T) the run_container fields
# =============================================================================
def test_own_identity_and_the_vm_state_read_are_refused() raises:
    _expect_s0_refusal(
        _bundle(
            String(""),
            String(""),
            String('      own_identity: "jm-vm-validator"\n'),
            String(""),
        ),
        String("(O) own_identity"),
        String("own_identity"),
    )
    _expect_s0_refusal(
        _bundle(
            String(""),
            String(""),
            String("      reads_telemetry: TELEMETRY_READ_JOB_VM_STATE\n"),
            String(""),
        ),
        String("(T) reads_telemetry JOB_VM_STATE"),
        String("TELEMETRY_READ_JOB_VM_STATE"),
    )
    print("  (O)(T) own_identity_and_the_vm_state_read_are_refused: PASS")


# =============================================================================
# (W)(B) the wave allow-list and the two build-target roles
# =============================================================================
def test_the_wave_and_build_fields_are_refused() raises:
    _expect_s0_refusal(
        _bundle(
            String(""),
            String(""),
            String(""),
            String('  api_edge_services: "orders-api-gcp-us-central1"\n'),
        ),
        String("(W) api_edge_services"),
        String("api_edge_services"),
    )
    _expect_s0_refusal(
        _bundle(
            String(" file_role: FILE_ROLE_POD_LOADER_BUNDLE"),
            String(""),
            String(""),
            String(""),
        ),
        String("(B) file_role"),
        String("file_role"),
    )
    _expect_s0_refusal(
        _bundle(
            String(" repository_role: REPOSITORY_ROLE_JOB_IMAGES"),
            String(""),
            String(""),
            String(""),
        ),
        String("(B) repository_role"),
        String("repository_role"),
    )
    print("  (W)(B) the_wave_and_build_fields_are_refused: PASS")


def main() raises:
    print("test_job_vm_s0_fields_refused:")
    var fails = List[String]()
    try:
        test_the_base_bundle_validates_clean()
    except e:
        fails.append(String("(C) ") + String(e))
    try:
        test_every_compute_env_value_from_is_refused_on_every_channel()
    except e:
        fails.append(String("(V) ") + String(e))
    try:
        test_from_build_is_refused()
    except e:
        fails.append(String("(F) ") + String(e))
    try:
        test_own_identity_and_the_vm_state_read_are_refused()
    except e:
        fails.append(String("(O)(T) ") + String(e))
    try:
        test_the_wave_and_build_fields_are_refused()
    except e:
        fails.append(String("(W)(B) ") + String(e))
    for ref f in fails:
        print("  RED ", f)
    if len(fails) > 0:
        raise Error(
            String("test_job_vm_s0_fields_refused: ")
            + String(len(fails))
            + String(" case(s) RED")
        )
    print("test_job_vm_s0_fields_refused: ALL PASS")
