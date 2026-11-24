# =============================================================================
# sql_e2e/corpus.mojo -- the cases, DuckDB's answers and the refusal list.
# =============================================================================
#
# A corpus is read from a root directory the BUCK stages:
#
#   cases/<case>.sql    comment lines (`--`), then one SELECT
#   answers/<case>.tsv  the pinned DuckDB's answer to that SELECT, written
#                       by komira_test_oracle's run.sql (header, then rows)
#   refusals.tsv        `#` comment lines, then `<case> TAB <step>: <reason>`
#                       for each case komira refuses by name
#
# Every case has an answer and every answer a case; a refusal names a case,
# once, and its text starts with one of run_sql's five steps. Each breach is
# a problem of the corpus, named, never a skip.
# =============================================================================

from std.os import listdir
from std.pathlib import Path

comptime REFUSALS_FILE = "refusals.tsv"


def run_sql_steps() -> List[String]:
    """The steps of run_sql, the first word of every refusal it gives."""
    return ["parse", "bind", "optimize", "lower", "execute"]


struct SqlCase(Copyable, Movable):
    """One case: its name, its SQL file's text and DuckDB's answer."""

    var name: String
    var sql: String
    var answer: String

    def __init__(out self, name: String, sql: String, answer: String):
        self.name = name
        self.sql = sql
        self.answer = answer


struct Refusal(Copyable, Movable):
    """A case komira refuses, with the refusal it must give."""

    var name: String
    var message: String

    def __init__(out self, name: String, message: String):
        self.name = name
        self.message = message


struct Corpus(Movable):
    """The cases (sorted by name), the refusals, and what is wrong with them."""

    var cases: List[SqlCase]
    var refusals: List[Refusal]
    var problems: List[String]

    def __init__(out self):
        self.cases = List[SqlCase]()
        self.refusals = List[Refusal]()
        self.problems = List[String]()

    def refusal_of(self, name: String) -> Optional[String]:
        """The refusal listed for `name`, or None when none is."""
        for r in self.refusals:
            if r.name == name:
                return r.message
        return None


def query_text(case_sql: String) -> String:
    """The SELECT of a case file: its lines but the `--` comments and the
    blank ones, joined by single spaces."""
    var out = String()
    for line in case_sql.split("\n"):
        var l = String(line)
        if l.startswith("--") or l == "":
            continue
        if out.byte_length() > 0:
            out += " "
        out += l
    return out^


def _stems(dir: String, suffix: String) raises -> List[String]:
    """The names of the files in `dir` ending in `suffix`, without it,
    sorted; empty when `dir` does not exist."""
    var out = List[String]()
    if not Path(dir).exists():
        return out^
    for entry in listdir(dir):
        var f = String(entry)
        if f.endswith(suffix) and f.byte_length() > suffix.byte_length():
            out.append(String(f[byte = 0 : f.byte_length() - suffix.byte_length()]))
    sort(out)
    return out^


def _contains(names: List[String], name: String) -> Bool:
    for n in names:
        if n == name:
            return True
    return False


def parse_refusals(
    text: String,
    cases: List[String],
    mut refusals: List[Refusal],
    mut problems: List[String],
):
    """Append the refusals listed in `text` to `refusals`, and its problems
    to `problems`: a line that is not `<case> TAB <step>: <reason>`, a case
    named twice, a name with no case."""
    var line_no = 0
    for line in text.split("\n"):
        line_no += 1
        var l = String(line)
        if l == "" or l.startswith("#"):
            continue
        var where = String(REFUSALS_FILE) + " line " + String(line_no) + ": "
        var parts = l.split("\t")
        if len(parts) != 2 or parts[0].byte_length() == 0:
            problems.append(where + "not <case> TAB <step>: <reason>")
            continue
        var name = String(parts[0])
        var message = String(parts[1])
        var stepped = False
        for step in run_sql_steps():
            if message.startswith(step + ": ") and message.byte_length() > step.byte_length() + 2:
                stepped = True
        if not stepped:
            problems.append(where + "the refusal does not start with a step of run_sql and its reason: " + message)
            continue
        if not _contains(cases, name):
            problems.append(name + ": a refusal for no case")
            continue
        var twice = False
        for r in refusals:
            if r.name == name:
                twice = True
        if twice:
            problems.append(name + ": listed in " + String(REFUSALS_FILE) + " twice")
            continue
        refusals.append(Refusal(name, message))


def load_corpus(root: String) raises -> Corpus:
    """The corpus staged under `root`: every case paired with its answer, the
    refusal list, and every problem of the pairing and the list."""
    var corpus = Corpus()
    var cases = _stems(root + "/cases", ".sql")
    var answers = _stems(root + "/answers", ".tsv")
    for c in cases:
        if not _contains(answers, c):
            corpus.problems.append(c + ": a case with no DuckDB answer")
    for a in answers:
        if not _contains(cases, a):
            corpus.problems.append(a + ": a DuckDB answer with no case")
    for c in cases:
        if _contains(answers, c):
            corpus.cases.append(
                SqlCase(
                    c,
                    Path(root + "/cases/" + c + ".sql").read_text(),
                    Path(root + "/answers/" + c + ".tsv").read_text(),
                )
            )
    var listed = String()
    if Path(root + "/" + REFUSALS_FILE).exists():
        listed = Path(root + "/" + REFUSALS_FILE).read_text()
    parse_refusals(listed, cases, corpus.refusals, corpus.problems)
    return corpus^
