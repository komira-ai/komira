# =============================================================================
# src/kci_release_machine/probe.mojo -- the fields of a DEPLOY_PROBE
#   validation: a digest-pinned image run against the cell a DEPLOY step
#   just deployed into.
# =============================================================================
#
#   step {
#     name: "deploy"
#     kind: DEPLOY
#     ...
#     validation {
#       name: "probe"
#       kind: DEPLOY_PROBE
#       image: "<reference>@sha256:<64 lowercase hex>"
#       args: "--checks=smoke"
#       target { resource: "api" output: "url" }
#       timeout_seconds: 300
#       expect: "health"
#       expect: "login"
#     }
#   }
#
#   image            required: pinned by digest,
#                    `<reference>@sha256:<64 lowercase hex>`; a tag is refused
#   args             repeated, optional: passed to the image as written. kci
#                    appends `--validation-run-id=<id>`, and `--target-url=<value>`
#                    when `target` is set, so an arg that is either flag is
#                    refused (the image would read two values)
#   target           optional block: `resource` and `output`, both required
#                    in it. Whether the output is a declared output of the
#                    step's resource list needs that file: the caller's, as
#                    for the cells file (this package opens no file)
#   timeout_seconds  required: 1 to PROBE_TIMEOUT_MAX_SECONDS
#   expect           repeated, at least one: a case id, [a-z0-9_-]+, no
#                    repeats
#
# A probe writes none of the CONDA_* fields (`install`, `compiler_channel`,
# `extra_channel`, `program`, `smoke`, `wait_for_index_seconds`); each is
# refused by name. `secret_env` is refused by the parser. That a probe sits
# on a DEPLOY step is graph.mojo's rule; that a promoted DEPLOY carries one is
# deploy.mojo's. Nothing here runs a probe.
#
# Every refusal starts `<source>: line N:`. Pure functions over owned values;
# no pointer, no file I/O.
# =============================================================================

from kci_api import VALIDATION_KIND_DEPLOY_PROBE

from .graph import Stage, StageStep, StageValidation, is_digest_pinned_image

comptime PROBE_TIMEOUT_MAX_SECONDS: Int = 3600
"""The longest `timeout_seconds` a DEPLOY_PROBE may declare."""

comptime PROBE_ARG_RUN_ID: String = "--validation-run-id"
"""The flag kci appends to a probe's args: the validation run id."""

comptime PROBE_ARG_TARGET_URL: String = "--target-url"
"""The flag kci appends to a probe's args when it has a `target`."""


def _at(source: String, line: Int) -> String:
    return source + String(": line ") + String(line) + String(": ")


def is_probe_case_id(case_id: String) -> Bool:
    """`[a-z0-9_-]+`: an `expect` case id."""
    var b = case_id.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45):
            return False
    return True


def _names_flag(arg: String, flag: String) -> Bool:
    """`arg` is `flag` or `flag=<anything>`."""
    return arg == flag or arg.startswith(flag + String("="))


def _conda_only_fields() -> List[String]:
    var out = List[String]()
    out.append(String("install"))
    out.append(String("compiler_channel"))
    out.append(String("extra_channel"))
    out.append(String("program"))
    out.append(String("smoke"))
    out.append(String("wait_for_index_seconds"))
    return out^


def check_probe(source: String, stage: Stage, step: StageStep, v: StageValidation) raises:
    """Every field rule of the file header, for one DEPLOY_PROBE validation
    of a DEPLOY step. Raises on the first, naming the validation's line."""
    var where = _at(source, v.line) + String("validation '") + v.name + String("' of step '") + step.name
    where += String("' of stage '") + stage.name + String("'")
    var conda = _conda_only_fields()
    for i in range(len(conda)):
        if v.wrote(conda[i]):
            raise Error(
                where + String(" is a DEPLOY_PROBE validation and has ") + conda[i]
                + String(": it belongs to a CONDA_INSTALL_SMOKE or CONDA_INSTALL_ENV validation")
            )
    if v.image.byte_length() == 0:
        raise Error(where + String(" has no image (the probe image, pinned by digest)"))
    if not is_digest_pinned_image(v.image):
        raise Error(
            where + String(" has image '") + v.image
            + String("'; a probe image is pinned by digest, <reference>@sha256:<64 lowercase hex> (a tag is refused)")
        )
    for i in range(len(v.args)):
        ref arg = v.args[i]
        if _names_flag(arg, String(PROBE_ARG_RUN_ID)) or _names_flag(arg, String(PROBE_ARG_TARGET_URL)):
            raise Error(
                where + String(" has args '") + arg + String("'; kci appends ") + String(PROBE_ARG_RUN_ID)
                + String(" and ") + String(PROBE_ARG_TARGET_URL) + String(" itself")
            )
    if v.wrote(String("target")):
        if v.target_resource.byte_length() == 0:
            raise Error(where + String(" has a target with no resource (the resource whose output it reads)"))
        if v.target_output.byte_length() == 0:
            raise Error(
                where + String(" has a target with no output (the output of resource '") + v.target_resource
                + String("' it reads)")
            )
    if not v.wrote(String("timeout_seconds")):
        raise Error(where + String(" has no timeout_seconds"))
    if v.timeout_seconds < 1 or v.timeout_seconds > PROBE_TIMEOUT_MAX_SECONDS:
        raise Error(
            where + String(" has timeout_seconds ") + String(v.timeout_seconds) + String("; it is 1 to ")
            + String(PROBE_TIMEOUT_MAX_SECONDS)
        )
    if len(v.expects) == 0:
        raise Error(where + String(" has no expect (a case id the image reports on)"))
    for i in range(len(v.expects)):
        ref case_id = v.expects[i]
        if not is_probe_case_id(case_id):
            raise Error(where + String(" has expect '") + case_id + String("'; a case id is [a-z0-9_-]+"))
        for j in range(i):
            if v.expects[j] == case_id:
                raise Error(where + String(" names expect '") + case_id + String("' twice"))


def has_probe(step: StageStep) -> Bool:
    """Whether the step carries at least one DEPLOY_PROBE validation."""
    for i in range(len(step.validations)):
        if step.validations[i].kind == VALIDATION_KIND_DEPLOY_PROBE:
            return True
    return False
