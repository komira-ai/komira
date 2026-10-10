# =============================================================================
# src/kci_cli/seam.mojo -- `StageSteps`: everything a run does outside this
#   process (dispatch.mojo's header), and `StepEnd`, how one step ended.
# =============================================================================
#
# `LibrarySteps` (library_verbs.mojo) is the real one; the welded tests drive
# recording fakes.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_build import BuildRequest
from kci_api import OUTCOME_NOOP, OUTCOME_SUCCEEDED, ResultValidation
from kci_api import RunResult as KciRunResult
from kci_publish import NewNamesReport, PublishRequest
from kci_validate import ValidateRequest

from .args import SecretStoreChoice
from .recorder import CliRecorder


struct StepEnd(Copyable, Movable):
    """How one step ended: its outcome and first error id (kci_api),
    the lines to print, retry advice stronger than the exit number's ("" for
    the default), whether it changed something outside this machine, and
    its markdown for the job summary ("" for none; a PUBLISH step's NEW
    NAMES block).

    Layout: owned values only. No pointer field."""

    var outcome: String
    var error_id: String
    var message: String
    var lines: List[String]
    var retry: String
    var changed_outside: Bool
    var summary: String

    def __init__(out self, var outcome: String, var error_id: String, var message: String):
        self.outcome = outcome^
        self.error_id = error_id^
        self.message = message^
        self.lines = List[String]()
        self.retry = String("")
        self.changed_outside = False
        self.summary = String("")

    def ok(self) -> Bool:
        return self.outcome == OUTCOME_SUCCEEDED or self.outcome == OUTCOME_NOOP


trait StageSteps:
    """Everything a run does outside this process (file header). One method
    per step kind: the step's request in, how it ended out; each adds its
    own row, artifacts, new names and first error to `result`, and may call
    `recorder.begin` again before its own first effect. Then the reads the
    run makes around its steps: a later stage's NEW NAMES, a platform-set
    variable, and the committed workflow file."""

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        ...

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        ...

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        """One validation of a step (file header, 6): its row, VALIDATED
        with an outcome and its checks, or WOULD_VALIDATE under --plan.
        Never raises: a validation that cannot run is a failed check."""
        ...

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        """The NEW NAMES of a later stage's PUBLISH step `req` (file header,
        7): reads only, never raises; a channel not read says why."""
        ...

    def platform_env(mut self, name: String) -> String:
        """A platform-set variable's value, "" when unset (file header, 4)."""
        ...

    def committed_file(mut self, commit: String, path: String) raises -> String:
        """The text of `path` as committed at `commit` (`git show
        <commit>:<path>` in the directory kci runs in). Raises when it
        cannot be read."""
        ...

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        """Whether `commit` is on `of`'s history (`git merge-base
        --is-ancestor`, in the directory kci runs in; file header, 4a).
        Raises when git cannot tell: a shallow clone, a ref it does not
        know."""
        ...

    def main_tip_past(mut self, revision: String) raises -> String:
        """THE ADMISSION CHECK's read (dispatch.mojo's header, 4c): fetch
        main, then main's tip when main holds a commit after `revision`
        that a push would release (one touching anything but `docs/**` and
        `*.md`, first-parent, as the prod line counts), else "" (`revision`
        is main's releasable tip). Raises when git cannot tell: a shallow
        clone, a fetch that fails, a revision git does not know."""
        ...

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        """The set hash the release directory `platform_dir` recomputes to
        under `artifacts_file` (file header, 4b). Raises when the directory
        is refused."""
        ...
