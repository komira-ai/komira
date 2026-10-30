# =============================================================================
# src/kci_api/errors.mojo -- the stable error ids a result document
#   carries in `error.id`.
# =============================================================================
#
# An id is `KCI-E-<WORD>[-<WORD>...]`, each word `[A-Z0-9]+`. A driver may
# branch on an id; the message next to it is for people and may change. The
# reason a run refused or failed survives as an id, never as an exit number
# (the exit table keeps a handful of numbers; the ids say why).
#
# Three ids choose the exit number by themselves (exit_codes.mojo):
# `KCI-E-INTERNAL` is exit 1, `KCI-E-USAGE` and `KCI-E-SELECTOR` are exit 2,
# whatever the outcome word says. Every other id leaves the number to the
# outcome.
#
# The table below is the only place an id is spelled. A welded test refuses
# two rows with the same id and an id that does not match the grammar.
# Pure functions over owned values; no pointer.
# =============================================================================

comptime ERROR_INTERNAL: String = "KCI-E-INTERNAL"
comptime ERROR_USAGE: String = "KCI-E-USAGE"
comptime ERROR_RESULT_FILE: String = "KCI-E-RESULT-FILE"
comptime ERROR_FORMAT_VERSION: String = "KCI-E-FORMAT-VERSION"
comptime ERROR_FORMAT: String = "KCI-E-FORMAT"
comptime ERROR_REVISION: String = "KCI-E-REVISION"
comptime ERROR_REVISION_MISMATCH: String = "KCI-E-REVISION-MISMATCH"
comptime ERROR_PLATFORM: String = "KCI-E-PLATFORM"
comptime ERROR_PLATFORM_MISMATCH: String = "KCI-E-PLATFORM-MISMATCH"
comptime ERROR_STAGE_UNKNOWN: String = "KCI-E-STAGE-UNKNOWN"
comptime ERROR_STAGE_ENVIRONMENT: String = "KCI-E-STAGE-ENVIRONMENT"
comptime ERROR_SELECTOR: String = "KCI-E-SELECTOR"
comptime ERROR_SELECTOR_NO_MATCH: String = "KCI-E-SELECTOR-NO-MATCH"
comptime ERROR_ARTIFACT: String = "KCI-E-ARTIFACT"
comptime ERROR_BUILD_FAILED: String = "KCI-E-BUILD-FAILED"
comptime ERROR_MEMBER: String = "KCI-E-MEMBER"
comptime ERROR_SET_HASH: String = "KCI-E-SET-HASH"
comptime ERROR_CHANNEL: String = "KCI-E-CHANNEL"
comptime ERROR_CREDENTIAL: String = "KCI-E-CREDENTIAL"
comptime ERROR_PUBLISH_DIFFERENT_BYTES: String = "KCI-E-PUBLISH-DIFFERENT-BYTES"
comptime ERROR_PUBLISH_UPLOAD: String = "KCI-E-PUBLISH-UPLOAD"
comptime ERROR_PUBLISH_READ_BACK: String = "KCI-E-PUBLISH-READ-BACK"
comptime ERROR_IMAGE_PLATFORM: String = "KCI-E-IMAGE-PLATFORM"
comptime ERROR_IMAGE_PUSH: String = "KCI-E-IMAGE-PUSH"
comptime ERROR_CANNOT_TELL: String = "KCI-E-CANNOT-TELL"
comptime ERROR_WORKFLOW_MISMATCH: String = "KCI-E-WORKFLOW-MISMATCH"
comptime ERROR_VALIDATION: String = "KCI-E-VALIDATION"
comptime ERROR_AFFECTED: String = "KCI-E-AFFECTED"
comptime ERROR_AFFECTED_VACUOUS: String = "KCI-E-AFFECTED-VACUOUS"
comptime ERROR_SUPERSEDED: String = "KCI-E-SUPERSEDED"
comptime ERROR_NOT_ON_MAIN: String = "KCI-E-NOT-ON-MAIN"
comptime ERROR_BREAK_GLASS_REASON: String = "KCI-E-BREAK-GLASS-REASON"
comptime ERROR_BREAK_GLASS_REVISION: String = "KCI-E-BREAK-GLASS-REVISION"
comptime ERROR_PLAN_ON_RELEASE: String = "KCI-E-PLAN-ON-RELEASE"
comptime ERROR_CLOUD: String = "KCI-E-CLOUD"
comptime ERROR_DEPLOY: String = "KCI-E-DEPLOY"


struct ErrorRow(Copyable, Movable):
    """One error id and what it means.

    Layout: owned Strings. No pointer field."""

    var id: String
    var meaning: String

    def __init__(out self, var id: String, var meaning: String):
        self.id = id^
        self.meaning = meaning^


def error_table() -> List[ErrorRow]:
    """Every error id kci emits, with its meaning."""
    var t = List[ErrorRow]()
    t.append(ErrorRow(String(ERROR_INTERNAL), String("kci itself raised past its handlers (exit 1)")))
    t.append(ErrorRow(String(ERROR_USAGE), String("the command line is wrong; nothing was read (exit 2)")))
    t.append(ErrorRow(String(ERROR_RESULT_FILE), String("the result file could not be written")))
    t.append(ErrorRow(String(ERROR_FORMAT_VERSION), String("a file's schema_version is missing or not read by this kci")))
    t.append(ErrorRow(String(ERROR_FORMAT), String("a file kci reads is not in its format")))
    t.append(ErrorRow(String(ERROR_REVISION), String("a revision id is not a full commit id")))
    t.append(ErrorRow(String(ERROR_REVISION_MISMATCH), String("the release was built from another revision")))
    t.append(ErrorRow(String(ERROR_PLATFORM), String("a platform is unknown or not released by this kci")))
    t.append(ErrorRow(String(ERROR_PLATFORM_MISMATCH), String("an artifact or release is for another platform")))
    t.append(ErrorRow(String(ERROR_STAGE_UNKNOWN), String("the machine file has no such stage")))
    t.append(ErrorRow(String(ERROR_STAGE_ENVIRONMENT), String("the stage is not the GitHub environment its trusted publisher names")))
    t.append(ErrorRow(String(ERROR_SELECTOR), String("an --only selector is malformed or given twice (exit 2)")))
    t.append(ErrorRow(String(ERROR_SELECTOR_NO_MATCH), String("an --only selector names no step or validation of the stage")))
    t.append(ErrorRow(String(ERROR_ARTIFACT), String("an artifact is refused")))
    t.append(ErrorRow(String(ERROR_BUILD_FAILED), String("an artifact's build failed")))
    t.append(ErrorRow(String(ERROR_MEMBER), String("a built artifact's directory is refused")))
    t.append(ErrorRow(String(ERROR_SET_HASH), String("the release set's hash is not the one recorded for it")))
    t.append(ErrorRow(String(ERROR_CHANNEL), String("a release channel is refused")))
    t.append(ErrorRow(String(ERROR_CREDENTIAL), String("a channel credential is missing or refused")))
    t.append(ErrorRow(String(ERROR_PUBLISH_DIFFERENT_BYTES), String("the channel holds different bytes under the same file name")))
    t.append(ErrorRow(String(ERROR_PUBLISH_UPLOAD), String("an upload failed")))
    t.append(ErrorRow(String(ERROR_PUBLISH_READ_BACK), String("the bytes read back after an upload are not the bytes sent")))
    t.append(ErrorRow(String(ERROR_IMAGE_PLATFORM), String("an image layout is for another platform than the step's")))
    t.append(ErrorRow(String(ERROR_IMAGE_PUSH), String("an image push did not end in the pushed state")))
    t.append(ErrorRow(String(ERROR_CANNOT_TELL), String("kci cannot tell whether the end state holds")))
    t.append(ErrorRow(String(ERROR_WORKFLOW_MISMATCH), String("the CI workflow running kci does not match the machine file")))
    t.append(ErrorRow(String(ERROR_VALIDATION), String("a validation of what a step produced failed")))
    t.append(ErrorRow(String(ERROR_AFFECTED), String("a build system's affected command failed or answered outside its grammar (never a widening)")))
    t.append(ErrorRow(String(ERROR_AFFECTED_VACUOUS), String("a --affected-by change is empty, or reaches no declared unit")))
    t.append(ErrorRow(String(ERROR_SUPERSEDED), String("the channel already lists a higher build number (any name or version), an equal one of another build, or a newest build this revision does not descend from: a stage that never goes backward refuses")))
    t.append(ErrorRow(String(ERROR_NOT_ON_MAIN), String("a stage that runs only on main was run off main, or for a commit not on main's history")))
    t.append(ErrorRow(String(ERROR_BREAK_GLASS_REASON), String("a break-glass run has no reason, one that is blank once trimmed, or one over 200 bytes")))
    t.append(ErrorRow(String(ERROR_BREAK_GLASS_REVISION), String("a break-glass run that can publish names a revision other than the commit it started on, or a dry run names one not on that commit's history")))
    t.append(ErrorRow(String(ERROR_PLAN_ON_RELEASE), String("--plan on a release run (a push to main), which is never a dry run")))
    t.append(ErrorRow(String(ERROR_CLOUD), String("a cell's cloud is not built into this kci, refused the cell's settings or the deploy identity, or could not be asked who the credentials are")))
    t.append(ErrorRow(String(ERROR_DEPLOY), String("a DEPLOY step's plan or apply was refused, failed before anything was written, or stopped part-way")))
    return t^


def is_error_id_well_formed(id: String) -> Bool:
    """True iff `id` is `KCI-E-` then one or more `[A-Z0-9]+` words joined by
    single dashes."""
    if not id.startswith(String("KCI-E-")):
        return False
    var b = id.as_bytes()
    var n = len(b)
    if n == 6:
        return False
    var prev_dash = True
    for i in range(6, n):
        var c = Int(b[i])
        if c == 45:  # '-'
            if prev_dash:
                return False
            prev_dash = True
            continue
        if not ((c >= 65 and c <= 90) or (c >= 48 and c <= 57)):
            return False
        prev_dash = False
    return not prev_dash


def is_error_id(id: String) -> Bool:
    var t = error_table()
    for i in range(len(t)):
        if t[i].id == id:
            return True
    return False


def require_error_id(id: String) raises:
    """Refuse an id that is not in the table."""
    if not is_error_id(id):
        raise Error(String("error id '") + id + String("' is not in kci's error table"))
