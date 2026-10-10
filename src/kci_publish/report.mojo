# =============================================================================
# src/kci_publish/report.mojo -- how a PUBLISH step ended, and its part of
#   the run's result document (kci_api's `kci.result`).
# =============================================================================
#
# `PublishReport` is the step's working record: the REASON it stopped (a
# word of this file, kept for people and for the result's error id), whether
# any upload LANDED in this run, one row per file, and the lines printed
# beside it. It is not a document: the one document is the result file, and
# `record_publish_result` puts this step's part into it.
#
# THE OUTCOME follows from the reason and from whether an upload landed
# (kci_api's outcome words; the exit number is the contract's, so this
# package spells none):
#
#   reason                 nothing landed       an upload landed   error id
#   PUBLISHED              SUCCEEDED            SUCCEEDED          -
#   ALREADY_PUBLISHED      NOOP                 (cannot happen)    -
#   SUPERSEDED             SUPERSEDED (exit 0)  (cannot happen)    -
#   REFUSED                REFUSED              (cannot happen)    the check's
#   STOP_DIFFERENT_BYTES   REFUSED              PARTIAL            KCI-E-PUBLISH-DIFFERENT-BYTES
#   FAILED                 FAILED               PARTIAL            KCI-E-PUBLISH-UPLOAD, or
#                                                                  KCI-E-CREDENTIAL
#   CANNOT_TELL            INDETERMINATE        INDETERMINATE      KCI-E-CANNOT-TELL
#   PARTIAL                PARTIAL              PARTIAL            KCI-E-PUBLISH-UPLOAD
#   READ_BACK_MISMATCH     PARTIAL, retry       PARTIAL, retry     KCI-E-PUBLISH-READ-BACK
#                          NEEDS_HUMAN          NEEDS_HUMAN
#
# So publishing a release whose every file is already in the channel with
# the same bytes is NOOP: exit 0, the end state holds. It is not a red job,
# and there is no second "green" number. A dry run that found nothing wrong
# is SUCCEEDED (exit 0) with every file it would send marked WOULD_UPLOAD.
#
# NEW NAMES are part of the report, not of the outcome: `new_names` lists the
# set names the channel held no file of at step 1 (`names_known` False when
# step 1 could not tell), and `record_publish_result` puts them into the
# result's `new_names[]`. `credential_probe` is a dry run's probe of the
# publishing credential (flow.mojo): MINTED, NOT_UNDER_CI or NOT_OIDC, and ""
# when the run is not a dry run or stopped before the probe.
#
# ⛔ NO SECRET: nothing a credential produced is placed in a row, a line or
# the error message -- only file names, digests, states and the channel's
# answers, which kci_pkg_upload has already passed through its
# credential-echo redaction.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_api import (
    STEP_KIND_PUBLISH,
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ARTIFACT_WOULD_UPLOAD,
    ERROR_CANNOT_TELL,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    ERROR_PUBLISH_READ_BACK,
    ERROR_PUBLISH_UPLOAD,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    OUTCOME_SUPERSEDED,
    RETRY_NEEDS_HUMAN,
    ResultNewName,
    ResultStep,
    ResultArtifact,
    exit_code_of,
    platform_of_conda_subdir,
    require_error_id,
)
from kci_api import RunResult as KciRunResult

from .plan import STATE_ABSENT, STATE_NOT_READ, STATE_SAME, PublishTarget, state_name


comptime REASON_PUBLISHED: String = "PUBLISHED"
comptime REASON_ALREADY_PUBLISHED: String = "ALREADY_PUBLISHED"
comptime REASON_REFUSED: String = "REFUSED"
comptime REASON_FAILED: String = "FAILED"
comptime REASON_CANNOT_TELL: String = "CANNOT_TELL"
comptime REASON_STOP_DIFFERENT_BYTES: String = "STOP_DIFFERENT_BYTES"
comptime REASON_PARTIAL: String = "PARTIAL"
comptime REASON_READ_BACK_MISMATCH: String = "READ_BACK_MISMATCH"
comptime REASON_SUPERSEDED: String = "SUPERSEDED"
"""A never-backward run whose channel's newest build descends from the
release (run.mojo, THE SPLIT): nothing uploaded, exit 0."""

comptime EFFECT_WORD_UPLOADED: String = "uploaded"
"""A file row's `effect` when this run's upload of it landed."""


struct FileRow(Copyable, Movable):
    """One file's row. Layout: owned values. No pointer."""

    var name: String
    var file: String
    var subdir: String
    var file_name: String
    var version: String
    var sha256_hex: String
    var state_before: Int
    var effect: String
    var state_after: Int
    var indexed: Bool

    def __init__(out self, t: PublishTarget):
        self.name = t.coordinate.distribution.copy()
        self.file = t.where()
        self.subdir = t.coordinate.subdir.copy()
        self.file_name = t.coordinate.file_name.copy()
        self.version = t.coordinate.version.copy()
        self.sha256_hex = t.sha256_hex.copy()
        self.state_before = STATE_NOT_READ
        self.effect = String("none")
        self.state_after = STATE_NOT_READ
        self.indexed = False


struct PublishReport(Copyable, Movable):
    """How the step ended (file header). Layout: owned values only. No
    pointer field."""

    var reason: String
    var error_id: String
    var channel: String
    var channel_path: String
    var plan: Bool
    var credential_probe: String
    var names_known: Bool
    var new_names: List[String]
    var set_hash: String
    var release_commit: String
    var has_produced_by: Bool
    var produced_by_run_id: String
    var produced_by_attempt: Int
    var files: List[FileRow]
    var lines: List[String]
    var build_number: Int
    """The release's build number (`h<8 hex>_<N>`), -1 when not read."""
    var previous_build: Int
    """A never-backward publish's `previous_build_number` (plan.mojo), -1
    for none or not read."""

    def __init__(out self):
        self.reason = String(REASON_PUBLISHED)
        self.error_id = String("")
        self.channel = String("")
        self.channel_path = String("")
        self.plan = False
        self.credential_probe = String("")
        self.names_known = False
        self.new_names = List[String]()
        self.set_hash = String("")
        self.release_commit = String("")
        self.has_produced_by = False
        self.produced_by_run_id = String("")
        self.produced_by_attempt = 0
        self.files = List[FileRow]()
        self.lines = List[String]()
        self.build_number = -1
        self.previous_build = -1

    @staticmethod
    def refused(var error_id: String, var message: String) -> PublishReport:
        """A report for a run stopped by a check before any request:
        `message`'s lines, reason REFUSED."""
        var r = PublishReport()
        r.stop(String(REASON_REFUSED), error_id^, message^)
        return r^

    def stop(mut self, var reason: String, var error_id: String, message: String):
        """End with `reason` and `error_id`, adding `message`'s lines, then
        the RESULT line."""
        self.reason = reason^
        self.error_id = error_id^
        var parts = message.split(String("\n"))
        for i in range(len(parts)):
            if String(parts[i]).byte_length() > 0:
                self.lines.append(String(parts[i]))
        self.finish_line()

    def end(mut self, var reason: String):
        """End with `reason` and the error id that reason carries (file
        header), then the RESULT line."""
        var id = String("")
        if reason == REASON_STOP_DIFFERENT_BYTES:
            id = String(ERROR_PUBLISH_DIFFERENT_BYTES)
        elif reason == REASON_FAILED or reason == REASON_PARTIAL:
            id = String(ERROR_PUBLISH_UPLOAD)
        elif reason == REASON_CANNOT_TELL:
            id = String(ERROR_CANNOT_TELL)
        elif reason == REASON_READ_BACK_MISMATCH:
            id = String(ERROR_PUBLISH_READ_BACK)
        self.reason = reason^
        self.error_id = id^
        self.finish_line()

    def landed(self) -> Bool:
        """Whether any upload of this run landed."""
        for i in range(len(self.files)):
            if self.files[i].effect == EFFECT_WORD_UPLOADED:
                return True
        return False

    def outcome(self) -> String:
        """The outcome word (file header)."""
        if self.reason == REASON_PUBLISHED:
            return String(OUTCOME_SUCCEEDED)
        if self.reason == REASON_ALREADY_PUBLISHED:
            return String(OUTCOME_NOOP)
        if self.reason == REASON_SUPERSEDED and not self.landed():
            return String(OUTCOME_SUPERSEDED)
        if self.reason == REASON_CANNOT_TELL:
            return String(OUTCOME_INDETERMINATE)
        if self.reason == REASON_PARTIAL or self.reason == REASON_READ_BACK_MISMATCH:
            return String(OUTCOME_PARTIAL)
        if self.landed():
            return String(OUTCOME_PARTIAL)
        if self.reason == REASON_FAILED:
            return String(OUTCOME_FAILED)
        return String(OUTCOME_REFUSED)  # REFUSED, STOP_DIFFERENT_BYTES

    def retry(self) -> String:
        """Retry advice stronger than the exit number's default, or "" for
        the default (kci_api's exit table)."""
        if self.reason == REASON_READ_BACK_MISMATCH:
            return String(RETRY_NEEDS_HUMAN)
        return String("")

    def exit_code(self) raises -> Int:
        """The exit number (kci_api's exit table)."""
        if self.error_id.byte_length() > 0:
            require_error_id(self.error_id)
        return exit_code_of(self.outcome(), self.error_id)

    def ok(self) -> Bool:
        var o = self.outcome()
        return o == OUTCOME_SUCCEEDED or o == OUTCOME_NOOP

    def has_line_containing(self, needle: String) -> Bool:
        for i in range(len(self.lines)):
            if self.lines[i].find(needle) >= 0:
                return True
        return False

    def finish_line(mut self):
        self.lines.append(
            String("RESULT outcome=")
            + self.outcome()
            + String(" reason=")
            + self.reason
            + String(" set_hash=")
            + self.set_hash
        )


def artifact_effect_of(row: FileRow, plan: Bool) -> String:
    """A file row's `artifacts[].effect` in the result document."""
    if row.effect == EFFECT_WORD_UPLOADED:
        return String(ARTIFACT_UPLOADED)
    if row.effect == "skipped" or (row.effect == "none" and row.state_before == STATE_SAME):
        return String(ARTIFACT_ALREADY_PRESENT)
    if plan and row.effect == "none" and row.state_before == STATE_ABSENT:
        return String(ARTIFACT_WOULD_UPLOAD)
    return String(ARTIFACT_NOT_REACHED)


def record_publish_result(
    r: PublishReport,
    step_name: String,
    stage: String,
    revision: String,
    platform: String,
    mut result: KciRunResult,
) raises:
    """Put this step's part into the run's result document: its row (its
    name, kind PUBLISH, a dry run's credential probe), the channel, the plan
    flag, the recomputed set hash, who produced the release, one artifact row
    per file, one `new_names[]` row per name new to the channel, and the
    first error (its message is the report's lines, which hold no secret)."""
    var outcome = r.outcome()
    var row_step = ResultStep(step_name.copy(), String(STEP_KIND_PUBLISH), platform.copy(), outcome.copy())
    if r.plan:
        row_step.credential_probe = r.credential_probe.copy()
    result.steps.append(row_step^)
    for i in range(len(r.new_names)):
        result.new_names.append(
            ResultNewName(stage.copy(), step_name.copy(), r.channel.copy(), r.new_names[i].copy())
        )
    result.channel = r.channel.copy()
    result.plan = r.plan
    if r.set_hash.byte_length() > 0:
        result.set_hash = r.set_hash.copy()
    if r.has_produced_by:
        result.has_release_produced_by = True
        result.release_produced_by_run_id = r.produced_by_run_id.copy()
        result.release_produced_by_attempt = r.produced_by_attempt
    for i in range(len(r.files)):
        ref f = r.files[i]
        var row = ResultArtifact()
        row.effect = artifact_effect_of(f, r.plan)
        row.artifact_type = String("CONDA")
        row.file = f.file_name.copy()
        row.indexed = f.indexed
        row.name = f.name.copy()
        row.platform = platform_of_conda_subdir(f.subdir)
        row.revision = revision.copy()
        row.sha256 = f.sha256_hex.copy()
        row.state_after = state_name(f.state_after)
        row.state_before = state_name(f.state_before)
        row.subdir = f.subdir.copy()
        row.version = f.version.copy()
        result.artifacts.append(row^)
    if r.error_id.byte_length() > 0:
        var message = String("")
        for i in range(len(r.lines)):
            if r.lines[i].startswith(String("RESULT ")):
                continue
            if message.byte_length() > 0:
                message += String("\n")
            message += r.lines[i]
        result.set_error(r.error_id.copy(), message^)
