# =============================================================================
# src/kci_api/result_rows.mojo -- the rows of the result document and the
#   words their keys hold (result.mojo's header says what each key means).
# =============================================================================
#
# Pure values; no pointer, no file I/O.
# =============================================================================

from kci_api.result_deploy import ResultDeploy


comptime ARTIFACT_BUILT: String = "BUILT"
comptime ARTIFACT_WOULD_BUILD: String = "WOULD_BUILD"
comptime ARTIFACT_UPLOADED: String = "UPLOADED"
comptime ARTIFACT_ALREADY_PRESENT: String = "ALREADY_PRESENT"
comptime ARTIFACT_WOULD_UPLOAD: String = "WOULD_UPLOAD"
comptime ARTIFACT_NOT_REACHED: String = "NOT_REACHED"

comptime VALIDATION_VALIDATED: String = "VALIDATED"
comptime VALIDATION_WOULD_VALIDATE: String = "WOULD_VALIDATE"
comptime VALIDATION_NOT_REACHED: String = "NOT_REACHED"

comptime VALIDATION_ENVIRONMENT_ENV: String = "ENV"
"""`validations[].environment` of a validation that ran on this machine."""
comptime VALIDATION_ENVIRONMENT_CONTAINER: String = "CONTAINER"
"""`validations[].environment` of a validation that ran in a container."""

comptime CREDENTIAL_PROBE_MINTED: String = "MINTED"
comptime CREDENTIAL_PROBE_NOT_UNDER_CI: String = "NOT_UNDER_CI"
comptime CREDENTIAL_PROBE_NOT_OIDC: String = "NOT_OIDC"

comptime CREDENTIAL_PROBE_NOT_RUN_NOTE: String = "credential probe NOT RUN (not under GitHub Actions)"
"""What the evidence line and the summary say next to the outcome of a run
whose PUBLISH step recorded NOT_UNDER_CI: a green dry run outside CI never
exchanged a token, so it cannot be read as covering the OIDC mint."""

comptime WORKFLOW_PATH_PREFIX: String = ".github/workflows/"
comptime WORKFLOW_NOT_REACHED: String = "not reached"
"""`workflow.reason` of a record written before the workflow check ran."""


def all_artifact_effects() -> List[String]:
    """What a step did to an artifact (`artifacts[].effect`)."""
    var out = List[String]()
    out.append(String(ARTIFACT_BUILT))
    out.append(String(ARTIFACT_WOULD_BUILD))
    out.append(String(ARTIFACT_UPLOADED))
    out.append(String(ARTIFACT_ALREADY_PRESENT))
    out.append(String(ARTIFACT_WOULD_UPLOAD))
    out.append(String(ARTIFACT_NOT_REACHED))
    return out^


def all_validation_effects() -> List[String]:
    """What happened to a validation (`validations[].effect`)."""
    var out = List[String]()
    out.append(String(VALIDATION_VALIDATED))
    out.append(String(VALIDATION_WOULD_VALIDATE))
    out.append(String(VALIDATION_NOT_REACHED))
    return out^


def all_credential_probes() -> List[String]:
    """The non-empty values of `steps[].credential_probe`."""
    var out = List[String]()
    out.append(String(CREDENTIAL_PROBE_MINTED))
    out.append(String(CREDENTIAL_PROBE_NOT_UNDER_CI))
    out.append(String(CREDENTIAL_PROBE_NOT_OIDC))
    return out^


def credential_probe_note(steps: List[ResultStep]) -> String:
    """`CREDENTIAL_PROBE_NOT_RUN_NOTE` when a step recorded the credential
    probe NOT_UNDER_CI, else ""."""
    for i in range(len(steps)):
        if steps[i].credential_probe == CREDENTIAL_PROBE_NOT_UNDER_CI:
            return String(CREDENTIAL_PROBE_NOT_RUN_NOTE)
    return String("")


def reserved_result_keys() -> List[String]:
    """Names kept for the deploy side (result.mojo's header) and never
    emitted yet. The other deploy names are step-row keys now
    (result_deploy.mojo `deploy_step_keys`)."""
    var out = List[String]()
    out.append(String("security_relevant_changes"))
    return out^


struct ResultError(Copyable, Movable):
    """`error`: a stable id (errors.mojo) and a message for people.

    Layout: owned Strings. No pointer field."""

    var id: String
    var message: String

    def __init__(out self, var id: String, var message: String):
        self.id = id^
        self.message = message^


struct ResultStep(Copyable, Movable):
    """One step of the stage: whether it was selected, its outcome once it
    ran ("" for an unselected step), a PUBLISH step's --plan credential
    probe ("" when none was made), and the deploy keys of a step that names
    its cell (`deploy`, result_deploy.mojo; empty otherwise).

    Layout: owned Strings, a Bool and an owned ResultDeploy. No pointer
    field."""

    var name: String
    var kind: String
    var platform: String
    var selected: Bool
    var outcome: String
    var credential_probe: String
    var deploy: ResultDeploy

    def __init__(out self, var name: String, var kind: String, var platform: String, var outcome: String):
        """A selected step that ran, with its outcome."""
        self.name = name^
        self.kind = kind^
        self.platform = platform^
        self.selected = True
        self.outcome = outcome^
        self.credential_probe = String("")
        self.deploy = ResultDeploy()

    @staticmethod
    def unselected(var name: String, var kind: String, var platform: String) -> ResultStep:
        """A step `--only` did not select: no outcome."""
        var s = ResultStep(name^, kind^, platform^, String(""))
        s.selected = False
        return s^


struct ResultValidationCheck(Copyable, Movable):
    """One check a validation made: what it expected, what it got, and
    whether they agree.

    Layout: owned Strings and a Bool. No pointer field."""

    var check: String
    var expected: String
    var got: String
    var ok: Bool

    def __init__(out self, var check: String, var expected: String, var got: String, ok: Bool):
        self.check = check^
        self.expected = expected^
        self.got = got^
        self.ok = ok


struct ResultValidation(Copyable, Movable):
    """One validation of a step (file header).

    Layout: owned Strings and a List of owned rows. No pointer field."""

    var name: String
    var step: String
    var kind: String
    var effect: String
    var outcome: String
    var checks: List[ResultValidationCheck]
    var environment: String
    var pixi_sha256: String
    var channel_url: String
    var skip_reason: String

    def __init__(out self, var name: String, var step: String, var kind: String, var effect: String, var outcome: String):
        self.name = name^
        self.step = step^
        self.kind = kind^
        self.effect = effect^
        self.outcome = outcome^
        self.checks = List[ResultValidationCheck]()
        self.environment = String("")
        self.pixi_sha256 = String("")
        self.channel_url = String("")
        self.skip_reason = String("")


struct ResultNewName(Copyable, Movable):
    """A declared name a PUBLISH step's channel holds no file of yet.

    Layout: owned Strings. No pointer field."""

    var stage: String
    var step: String
    var channel: String
    var name: String

    def __init__(out self, var stage: String, var step: String, var channel: String, var name: String):
        self.stage = stage^
        self.step = step^
        self.channel = channel^
        self.name = name^


struct ResultArtifact(Copyable, Movable):
    """One artifact row (file header).

    Layout: owned Strings and a Bool. No pointer field."""

    var effect: String
    var artifact_type: String
    var build: String
    var file: String
    var indexed: Bool
    var name: String
    var platform: String
    var revision: String
    var sha256: String
    var state_after: String
    var state_before: String
    var subdir: String
    var version: String

    def __init__(out self):
        self.effect = String("")
        self.artifact_type = String("")
        self.build = String("")
        self.file = String("")
        self.indexed = False
        self.name = String("")
        self.platform = String("")
        self.revision = String("")
        self.sha256 = String("")
        self.state_after = String("")
        self.state_before = String("")
        self.subdir = String("")
        self.version = String("")


