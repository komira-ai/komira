# =============================================================================
# src/kci_build/scripted_runner.mojo -- a `ProcessRunner` that answers from a
#   script: the test double for buck2.
# =============================================================================
#
# Each `ScriptedStep` expects one argv and answers with a `RunResult`. Its
# `elapsed_s` is how long the run "takes": answering it advances the
# runner's clock (`now_ns`, starting at 0) by that much, whatever the run's
# result, so a budget test is exact. Before
# answering it writes the step's stdout and stderr text to the spec's files
# and writes each of its `files` (relative paths resolve against the spec's
# cwd, parent directories are created), which is how a test stands in for
# what buck2 would have built and the build report it would have written.
#
# Every run is recorded in `calls`, its `env` included, so a test can assert
# what environment a child would have been started with.
#
# Steps are consumed in order. A run with no step left, or whose argv does
# not match the next step's, RAISES naming both argvs, and is still
# recorded in `calls`. An expected argument equal to `ANY_ARG` matches any
# one argument (a nonce, for example).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import makedirs

from kci_build.runner import (
    STDERR_TAIL_BYTES,
    ProcessRunner,
    RunResult,
    RunSpec,
    tail_text,
)

comptime ANY_ARG: String = "<any>"
"""In an expected argv: matches any one argument."""


def _parent_dir(path: String) -> String:
    var slash = path.rfind(String("/"))
    if slash <= 0:
        return String("")
    return String(path[byte = : slash])


def write_text_file(path: String, text: String) raises:
    """Write `text` to `path`, creating its parent directories."""
    var parent = _parent_dir(path)
    if parent.byte_length() > 0:
        makedirs(parent, exist_ok=True)
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


struct ScriptedStep(Copyable, Movable):
    """One expected run and its answer.

    Layout: owned values only. No pointer field."""

    var argv: List[String]
    var result: RunResult
    var stdout_text: String
    var stderr_text: String
    var file_paths: List[String]
    var file_texts: List[String]
    var elapsed_ns: Int

    def __init__(
        out self,
        var argv: List[String],
        exit_code: Int32 = Int32(0),
        var stdout_text: String = String(""),
        var stderr_text: String = String(""),
        timed_out: Bool = False,
        elapsed_s: Int = 0,
    ):
        self.argv = argv^
        self.result = RunResult(
            exit_code,
            timed_out=timed_out,
            stderr_tail=tail_text(stderr_text, STDERR_TAIL_BYTES),
        )
        self.elapsed_ns = elapsed_s * 1_000_000_000
        self.stdout_text = stdout_text^
        self.stderr_text = stderr_text^
        self.file_paths = List[String]()
        self.file_texts = List[String]()

    def writes(mut self, var path: String, var text: String):
        """Have this step write `text` to `path` before it answers."""
        self.file_paths.append(path^)
        self.file_texts.append(text^)


def _argv_text(argv: List[String]) -> String:
    var s = String("[")
    for i in range(len(argv)):
        if i > 0:
            s += String(" ")
        s += argv[i]
    return s + String("]")


def _matches(expected: List[String], got: List[String]) -> Bool:
    if len(expected) != len(got):
        return False
    for i in range(len(expected)):
        if expected[i] != ANY_ARG and expected[i] != got[i]:
            return False
    return True


struct ScriptedRunner(ProcessRunner):
    """Answers runs from a script of `ScriptedStep`s (see the file header).

    Layout: owned values only. No pointer field."""

    var steps: List[ScriptedStep]
    var next_step: Int
    var calls: List[RunSpec]
    var clock_ns: Int

    def __init__(out self):
        self.steps = List[ScriptedStep]()
        self.next_step = 0
        self.calls = List[RunSpec]()
        self.clock_ns = 0

    def now_ns(self) -> Int:
        """The scripted clock: 0, plus every answered step's `elapsed_s`."""
        return self.clock_ns

    def expect(mut self, var step: ScriptedStep):
        self.steps.append(step^)

    def remaining(self) -> Int:
        """Steps not yet consumed. A finished test expects 0."""
        return len(self.steps) - self.next_step

    def run(mut self, spec: RunSpec) raises -> RunResult:
        self.calls.append(spec.copy())
        if self.next_step >= len(self.steps):
            raise Error(
                String("ScriptedRunner: unexpected run ") + _argv_text(spec.argv)
                + String(": the script has no step left")
            )
        ref step = self.steps[self.next_step]
        if not _matches(step.argv, spec.argv):
            raise Error(
                String("ScriptedRunner: unexpected run ")
                + _argv_text(spec.argv)
                + String(": expected ")
                + _argv_text(step.argv)
            )
        self.next_step += 1
        self.clock_ns += step.elapsed_ns
        for i in range(len(step.file_paths)):
            var p = step.file_paths[i].copy()
            if not p.startswith(String("/")) and spec.cwd.byte_length() > 0:
                p = spec.cwd + String("/") + p
            write_text_file(p, step.file_texts[i])
        write_text_file(spec.stdout_path, step.stdout_text)
        write_text_file(spec.stderr_path, step.stderr_text)
        return step.result.copy()
