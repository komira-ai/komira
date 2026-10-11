"""The verdict of each mutant, from the statuses of its build steps, and the
report: covcheck's mutants file and a Markdown summary.

A step's status file is written by `mut_step.sh`; its first line is one of

    ok              the command exited 0
    fail <status>   it exited <status>, not 0
    timeout <secs>  it ran out of its time limit and was killed
    skipped         a step it waits for was not `ok`, so it did not run

A mutant's steps are its library's precompile, then per welded test its
build and its run. Its verdict, first rule that holds:

| status | when |
|---|---|
| `error` | the precompile is not `ok`: the mutated library does not compile |
| `killed` | some test's run is `fail` (an assertion, a crash, the memory cap) |
| `timeout` | some test's run is `timeout` |
| `error` | some test's build is not `ok`: the mutated library does not compile where that test instantiates it |
| `survived` | every build and run is `ok` |

A test that does not compile is not a kill: `mojo precompile` does not
instantiate generic code, so a mutant the compiler rejects (a tuple index
out of range, a type that no longer conforms) is often first rejected when
a test is built against it. That is the compiler's verdict on a stillborn
mutant, not a test's: the mutant is `error`, outside the score's
numerator, unless another test's run killed it or timed out.

A `skipped` step whose prerequisites were `ok`, or any other first line,
is refused: the statuses disagree with how the steps were declared.

The score is covcheck's: `killed * 10000 / total` basis points, total
counting every sampled mutant, `error` and `timeout` included.
"""

comptime KILLED = "killed"
comptime SURVIVED = "survived"
comptime TIMEOUT = "timeout"
comptime ERROR = "error"

# The id of the baseline: the library unchanged, built and tested through
# the same steps as every mutant (`check_baseline`).
comptime BASELINE = "baseline"


struct TestSteps(Copyable, Movable):
    var name: String
    var build: String
    var run: String

    def __init__(out self, name: String, build: String, run: String):
        self.name = name
        self.build = build
        self.run = run


struct Verdict(Copyable, Movable):
    """`log` is the output of the compile that decided an `error` (the
    status text after its first line); empty otherwise."""

    var status: String
    var why: String
    var log: String

    def __init__(out self, status: String, why: String, log: String = ""):
        self.status = status
        self.why = why
        self.log = log


def first_line(text: String) -> String:
    var b = text.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) == 10:
            return String(text[byte=0:i])
    return text


def after_first_line(text: String) -> String:
    var b = text.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) == 10:
            return String(text[byte = i + 1 : len(b)])
    return String("")


def _kind(text: String, what: String) raises -> String:
    """`ok`, `fail`, `timeout` or `skipped`, from a status's first line."""
    var status = first_line(text)
    if status == "ok" or status == "skipped":
        return status
    if status.startswith("fail ") and status.byte_length() > 5:
        return String("fail")
    if status.startswith("timeout ") and status.byte_length() > 8:
        return String("timeout")
    raise Error(what + ": status `" + status + "` is not ok, fail <n>, timeout <s> or skipped")


def _detail(text: String) -> String:
    var status = first_line(text)
    return String(status[byte = status.find(" ") + 1 : status.byte_length()])


def verdict(precompile: String, tests: List[TestSteps]) raises -> Verdict:
    """The verdict from the steps' status texts (module docstring)."""
    var pk = _kind(precompile, String("precompile"))
    if pk != "ok":
        for t in tests:
            if _kind(t.build, t.name + " build") != "skipped" or _kind(t.run, t.name + " run") != "skipped":
                raise Error(t.name + ": ran although the precompile was " + pk)
        if pk == "skipped":
            raise Error("precompile: skipped, but it waits for nothing")
        if pk == "timeout":
            return Verdict(String(ERROR), String("the mutated library's compile timed out after ") + _detail(precompile) + " s")
        return Verdict(String(ERROR), String("the mutated library does not compile (exit ") + _detail(precompile) + ")", after_first_line(precompile))
    var killed = String("")
    var timed_out = String("")
    var stillborn = String("")
    var stillborn_log = String("")
    for t in tests:
        var bk = _kind(t.build, t.name + " build")
        var rk = _kind(t.run, t.name + " run")
        if bk == "skipped":
            raise Error(t.name + " build: skipped, but the precompile was ok")
        if bk != "ok" and rk != "skipped":
            raise Error(t.name + " run: ran although its build was " + bk)
        if bk == "ok" and rk == "skipped":
            raise Error(t.name + " run: skipped, but its build was ok")
        if killed == "" and rk == "fail":
            killed = t.name + ": failed (exit " + _detail(t.run) + ")"
        if timed_out == "" and rk == "timeout":
            timed_out = t.name + ": timed out after " + _detail(t.run) + " s"
        if stillborn == "" and bk == "fail":
            stillborn = t.name + ": does not compile against the mutated library (exit " + _detail(t.build) + ")"
            stillborn_log = after_first_line(t.build)
        if stillborn == "" and bk == "timeout":
            stillborn = t.name + ": its compile against the mutated library timed out after " + _detail(t.build) + " s"
    if killed != "":
        return Verdict(String(KILLED), killed)
    if timed_out != "":
        return Verdict(String(TIMEOUT), timed_out)
    if stillborn != "":
        return Verdict(String(ERROR), stillborn, stillborn_log)
    return Verdict(String(SURVIVED), String("every test passed"))


def check_baseline(precompile: String, tests: List[TestSteps]) raises:
    """Refuses unless every step of the baseline (the library unchanged) is
    `ok`: a harness that fails an unchanged library's tests would count
    every mutant killed. The error names the first step that is not, with
    its output."""
    if first_line(precompile) != "ok":
        raise Error("the baseline (the library unchanged) did not pass its precompile: " + first_line(precompile) + "; the mutation harness is broken, nothing is scored\n" + after_first_line(precompile))
    for t in tests:
        if first_line(t.build) != "ok":
            raise Error("the baseline (the library unchanged) did not pass " + t.name + " build: " + first_line(t.build) + "; the mutation harness is broken, nothing is scored\n" + after_first_line(t.build))
        if first_line(t.run) != "ok":
            raise Error("the baseline (the library unchanged) did not pass " + t.name + " run: " + first_line(t.run) + "; the mutation harness is broken, nothing is scored\n" + after_first_line(t.run))


struct Scored(Copyable, Movable):
    """One mutant of the list with its verdict."""

    var path: String
    var line: Int
    var col: Int
    var operator: String
    var description: String
    var verdict: Verdict

    def __init__(out self, path: String, line: Int, col: Int, operator: String, description: String, var verdict: Verdict):
        self.path = path
        self.line = line
        self.col = col
        self.operator = operator
        self.description = description
        self.verdict = verdict^


struct Totals(Copyable, Movable):
    var killed: Int
    var survived: Int
    var timeout: Int
    var error: Int

    def __init__(out self):
        self.killed = 0
        self.survived = 0
        self.timeout = 0
        self.error = 0

    def total(self) -> Int:
        return self.killed + self.survived + self.timeout + self.error


def totals(rows: List[Scored]) -> Totals:
    var t = Totals()
    for r in rows:
        var s = r.verdict.status
        if s == KILLED:
            t.killed += 1
        elif s == SURVIVED:
            t.survived += 1
        elif s == TIMEOUT:
            t.timeout += 1
        else:
            t.error += 1
    return t^


def render_bp(hit: Int, total: Int) -> String:
    """`hit * 10000 / total` basis points as a percentage, `n/a` for none."""
    if total == 0:
        return String("n/a")
    var bp = hit * 10000 // total
    var frac = bp % 100
    return String(bp // 100) + "." + (String("0") if frac < 10 else String("")) + String(frac) + "%"


def _score_line(t: Totals) -> String:
    return (
        String("killed ") + String(t.killed) + " of " + String(t.total()) + " (" + render_bp(t.killed, t.total()) + "); survived "
        + String(t.survived) + ", timeout " + String(t.timeout) + ", error " + String(t.error)
    )


def _last_lines(text: String, n: Int) -> String:
    """The last `n` lines of `text`, ending with a line feed."""
    var b = text.as_bytes()
    var end = len(b)
    if end > 0 and Int(b[end - 1]) == 10:
        end -= 1
    var start = end
    var seen = 0
    while start > 0:
        if Int(b[start - 1]) == 10:
            seen += 1
            if seen == n:
                break
        start -= 1
    return String(text[byte=start:end]) + "\n"


def render_mutants(rows: List[Scored], src_repo: String) -> String:
    """covcheck's mutants file (tools/build/coverage/README.md, "The mutants
    file"): paths are `src_repo` + the path in the package."""
    var out = String("# mutation score: ") + _score_line(totals(rows)) + "\n"
    for r in rows:
        out += src_repo + r.path + "\t" + String(r.line) + "\t" + r.verdict.status + "\t" + r.operator + "\tcol " + String(r.col) + ": " + r.description + "; " + r.verdict.why + "\n"
    return out^


def render_summary(label: String, header: String, rows: List[Scored], src_repo: String, suppressed_ids: List[String], suppressed_why: List[String]) -> String:
    var t = totals(rows)
    var out = String("# Mutation score: ") + label + "\n\n"
    out += String("Score: ") + _score_line(t) + ".\n"
    out += String("Detected (killed or timeout): ") + render_bp(t.killed + t.timeout, t.total()) + "; score over compiling mutants: " + render_bp(t.killed, t.total() - t.error) + ".\n\n"
    out += String("List: `") + header + "`\n\n"
    out += String("## Survivors\n\n")
    var any = False
    for r in rows:
        if r.verdict.status == SURVIVED:
            out += String("- `") + src_repo + r.path + ":" + String(r.line) + ":" + String(r.col) + "` " + r.operator + ": " + r.description + "\n"
            any = True
    if not any:
        out += String("None.\n")
    out += String("\n## Timeouts and errors\n\n")
    any = False
    for r in rows:
        if r.verdict.status == TIMEOUT or r.verdict.status == ERROR:
            out += String("- `") + src_repo + r.path + ":" + String(r.line) + ":" + String(r.col) + "` " + r.operator + " (" + r.verdict.status + "): " + r.verdict.why + "\n"
            any = True
    if not any:
        out += String("None.\n")
    out += String("\n## Compiler output\n\nOf each `error`: the last lines of the compile that failed.\n\n")
    any = False
    for r in rows:
        if r.verdict.log.byte_length() > 0:
            out += String("`") + src_repo + r.path + ":" + String(r.line) + ":" + String(r.col) + "` " + r.operator + ":\n\n```text\n" + _last_lines(r.verdict.log, 12) + "```\n\n"
            any = True
    if not any:
        out += String("None.\n")
    out += String("\n## Suppressed by a marker (need approval)\n\n")
    if len(suppressed_ids) == 0:
        out += String("None.\n")
    for i in range(len(suppressed_ids)):
        out += String("- `") + src_repo + suppressed_ids[i] + "`: " + suppressed_why[i] + "\n"
    return out^
