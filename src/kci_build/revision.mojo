# =============================================================================
# src/kci_build/revision.mojo -- the release stamp, derived from git at the
#   commit `--revision-id` names, before any build runs.
# =============================================================================
#
# `kci build --revision-id <C>` takes the release commit as a FULL commit id
# (40 lowercase hex; an abbreviated id is refused by the flag parser, because
# it names a commit only while no other commit shares its prefix). Here, in
# `--work-dir`, through the same `ProcessRunner` as the builds (argv, never a
# shell; stdout to `<log>/_git_<k>.stdout`, a name no artifact can take:
# declaration names start with a letter), kci runs, in order:
#
#   1. git rev-parse --is-shallow-repository      must print `false`
#   2. git rev-parse --verify HEAD                must print C exactly
#   3. git status --porcelain --untracked-files=no
#                                                 must print nothing
#   4. git log -1 --first-parent --format=%H C -- . :(exclude)docs
#        :(exclude)*.md :(exclude).github         the stamp's commit S
#   5. git rev-list --count --first-parent S      the build number N
#   6. git log -1 --format=%ct S                  S's commit time, seconds
#
# and returns `ReleaseStamp(C, S, N, seconds * 1000)`: the values of
# `{revision_id}`, `{source_commit}`, `{build_number}` and `{timestamp_ms}`.
# Steps 4 to 6 are the rule of tools/build/package/release_version.sh (the
# newest first-parent commit at or below C that touches anything but
# documentation, so a documentation-only commit never raises N). kci publish
# compares every built package against that script's output at the release
# commit and refuses a difference, so if the two ever disagree no package of
# the run is shipped.
#
# Refused (REFUSED, naming what was found, before any build):
#   * a SHALLOW clone: the first-parent count there is the clone's depth,
#     not the history's, so N would be wrong. kci does not deepen the clone
#     (that would be a network fetch inside a build verb); the job checks out
#     with full history (actions/checkout `fetch-depth: 0`, or
#     `git fetch --unshallow`) and runs kci again;
#   * HEAD that is not C: the work dir holds other bytes than the commit the
#     stamp would name;
#   * a modified tracked file: the same, for bytes not yet committed
#     (untracked files are not the checkout's, e.g. a local buckconfig);
#   * C with no commit touching anything but documentation;
#   * any git command that exits non-zero (not a git checkout, an unknown
#     commit), or prints something that is not one line of the expected shape.
# A git that cannot be started, or that times out, is CANNOT_TELL.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from kci_artifact_declaration import ReleaseStamp

from kci_build.request import EXIT_CANNOT_TELL, EXIT_OK, EXIT_REFUSED, BuildRequest
from kci_build.runner import ProcessRunner, RunResult, RunSpec

comptime GIT_PROGRAM: String = "git"
"""Found on PATH, as a build system's program name is."""

comptime GIT_TIMEOUT_S: Int = 300
"""Per git command."""


struct StampResult(Copyable, Movable):
    """A derived stamp, or why there is none (`exit_code` != EXIT_OK).

    Layout: owned values only. No pointer field."""

    var exit_code: Int
    var message: String
    var stamp: Optional[ReleaseStamp]

    def __init__(out self, exit_code: Int, var message: String):
        self.exit_code = exit_code
        self.message = message^
        self.stamp = None

    def __init__(out self, var stamp: ReleaseStamp):
        self.exit_code = EXIT_OK
        self.message = String("")
        self.stamp = stamp^

    def ok(self) -> Bool:
        return self.exit_code == EXIT_OK


def _argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


struct _Git(Movable):
    """Runs one git command after another and keeps the first stop.

    Layout: owned values only. No pointer field."""

    var work_dir: String
    var log_dir: String
    var calls: Int
    var stop: Optional[StampResult]

    def __init__(out self, var work_dir: String, var log_dir: String):
        self.work_dir = work_dir^
        self.log_dir = log_dir^
        self.calls = 0
        self.stop = None

    def _refuse(mut self, why: String):
        self.stop = StampResult(EXIT_REFUSED, String("kci build: --revision-id: ") + why)

    def line[R: ProcessRunner](mut self, mut runner: R, var args: List[String]) -> String:
        """The one line `git <args>` printed (trailing newline removed), or
        "" with `stop` set. A command that printed nothing gives "" and no
        stop; a caller that needs a value refuses that itself."""
        if self.stop:
            return String("")
        self.calls += 1
        var base = self.log_dir + String("/_git_") + String(self.calls)
        var spec = RunSpec(
            String(GIT_PROGRAM),
            args^,
            self.work_dir.copy(),
            GIT_TIMEOUT_S,
            base + String(".stdout"),
            base + String(".stderr"),
        )
        var r: RunResult
        try:
            r = runner.run(spec)
        except e:
            self.stop = StampResult(
                EXIT_CANNOT_TELL,
                String("kci build: --revision-id: `") + spec.command_line()
                + String("` could not be started: ") + String(e),
            )
            return String("")
        if r.timed_out:
            self.stop = StampResult(
                EXIT_CANNOT_TELL,
                String("kci build: --revision-id: `") + spec.command_line() + String("` timed out"),
            )
            return String("")
        if not r.ok():
            var why = String("`") + spec.command_line() + String("` ") + r.describe()
            if r.stderr_tail.byte_length() > 0:
                why += String(": ") + String(r.stderr_tail.strip())
            self._refuse(why)
            return String("")
        var text: String
        try:
            text = Path(spec.stdout_path).read_text()
        except e:
            self.stop = StampResult(
                EXIT_CANNOT_TELL,
                String("kci build: --revision-id: the output of `") + spec.command_line()
                + String("` cannot be read: ") + String(e),
            )
            return String("")
        if text.endswith(String("\n")):
            var trimmed = String(text[byte = : text.byte_length() - 1])
            text = trimmed^
        if text.find(String("\n")) >= 0:
            self._refuse(
                String("`") + spec.command_line() + String("` printed more than one line: '")
                + text + String("'")
            )
            return String("")
        return text^


def _is_lower_hex_40(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 40:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def _positive_decimal(s: String) -> Int:
    """`s` as a positive decimal of at most 18 digits, or -1."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 18:
        return -1
    var n = 0
    for i in range(len(b)):
        if b[i] < UInt8(48) or b[i] > UInt8(57):
            return -1
        n = n * 10 + Int(b[i] - UInt8(48))
    return n if n > 0 else -1


def derive_release_stamp[R: ProcessRunner](req: BuildRequest, mut runner: R) -> StampResult:
    """The stamp of `req.revision_id` (file header). `req.log_dir` must
    exist; `req.revision_id` was checked by the flag parser."""
    var rev = req.revision_id.copy()
    var git = _Git(req.work_dir.copy(), req.log_dir.copy())
    var shallow = git.line(runner, _argv("rev-parse", "--is-shallow-repository"))
    if not git.stop and shallow != "false":
        if shallow == "true":
            git._refuse(
                String("--work-dir '") + req.work_dir
                + String("' is a SHALLOW clone: the first-parent commit count there is the clone's")
                + String(" depth, not the history's, so the build number would be wrong; check out")
                + String(" with full history (actions/checkout fetch-depth: 0, or")
                + String(" `git fetch --unshallow`) and run kci build again")
            )
        else:
            git._refuse(
                String("`git rev-parse --is-shallow-repository` printed '") + shallow
                + String("', neither 'true' nor 'false'")
            )
    var head = git.line(runner, _argv("rev-parse", "--verify", "HEAD"))
    if not git.stop and head != rev:
        git._refuse(
            String("'") + rev + String("' is not the commit checked out in --work-dir '")
            + req.work_dir + String("' (HEAD is '") + head
            + String("'): the stamp would name a commit whose bytes are not the ones built")
        )
    var dirty = git.line(runner, _argv("status", "--porcelain", "--untracked-files=no"))
    if not git.stop and dirty.byte_length() > 0:
        git._refuse(
            String("--work-dir '") + req.work_dir
            + String("' has modified tracked files (") + dirty
            + String("): the stamp would name a commit whose bytes are not the ones built")
        )
    var source = git.line(
        runner,
        _argv(
            "log", "-1", "--first-parent", "--format=%H", rev, "--", ".",
            ":(exclude)docs", ":(exclude)*.md", ":(exclude).github",
        ),
    )
    if not git.stop and source.byte_length() == 0:
        git._refuse(
            String("no first-parent commit at or below '") + rev
            + String("' touches anything but documentation: there is nothing to release")
        )
    if not git.stop and not _is_lower_hex_40(source):
        git._refuse(String("`git log` printed '") + source + String("', not a full commit id"))
    var count = git.line(runner, _argv("rev-list", "--count", "--first-parent", source))
    var n = -1
    if not git.stop:
        n = _positive_decimal(count)
        if n < 0:
            git._refuse(String("`git rev-list --count` printed '") + count + String("', not a positive count"))
    var seconds = git.line(runner, _argv("log", "-1", "--format=%ct", source))
    var ts = -1
    if not git.stop:
        ts = _positive_decimal(seconds)
        if ts < 0 or ts > 9_000_000_000_000:
            git._refuse(String("`git log --format=%ct` printed '") + seconds + String("', not a commit time"))
    if git.stop:
        return git.stop.take()
    try:
        return StampResult(ReleaseStamp(rev^, source^, n, ts * 1000))
    except e:
        return StampResult(EXIT_REFUSED, String("kci build: --revision-id: ") + String(e))
