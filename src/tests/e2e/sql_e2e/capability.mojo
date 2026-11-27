# =============================================================================
# sql_e2e/capability.mojo -- one capability's cases, run as one test.
# =============================================================================
#
# The surface capability matrix (docs/surface_capability_matrix.md) names one
# test target for each filled cell. BUCK declares one mojo_test per
# capability of the SQL surface, test_sql_<capability>. It stages only that
# capability's cases with their DuckDB answers, the tables, and no refusal
# list. Each case it names must be answered and equal DuckDB's answer: a case
# komira refuses is a problem, because a refusal is not the capability
# exercised. The test's arguments name the capability and its cases
# (`--capability=<name>`, `--cases=<a>,<b>,...`). The staged corpus must hold
# exactly those cases, so a case lost or added on the way is a problem, never
# a smaller test.
# =============================================================================

from so import Session

from .corpus import Corpus
from .runner import check_corpus


def flag_value(args: List[String], name: String) raises -> String:
    """The value of `--<name>=<value>` in `args` (the test's arguments, the
    program name first). Raises naming the flag when it is absent, empty or
    given twice."""
    var want = "--" + name + "="
    var found = List[String]()
    for i in range(1, len(args)):
        if args[i].startswith(want):
            found.append(String(args[i][byte = want.byte_length() :]))
    if len(found) == 0:
        raise Error("sql_e2e: missing flag " + want + "<value> (the mojo_test's args in BUCK give it)")
    if len(found) > 1:
        raise Error("sql_e2e: flag " + want + " given " + String(len(found)) + " times")
    if found[0].byte_length() == 0:
        raise Error("sql_e2e: flag " + want + " is empty")
    return found[0]


def split_cases(text: String) -> List[String]:
    """The case names of a `--cases` value, split at every comma. An empty
    name is kept, so that check_capability reports it."""
    var out = List[String]()
    for part in text.split(","):
        out.append(String(part))
    return out^


def _count(names: List[String], name: String) -> Int:
    var n = 0
    for x in names:
        if x == name:
            n += 1
    return n


def check_capability(
    mut session: Session, corpus: Corpus, capability: String, want: List[String]
) -> List[String]:
    """Every problem of running the cases `want` of `capability`, each line
    naming the capability: a name that is empty, named twice or not staged;
    a staged case that is not named; a staged refusal list; and every problem
    check_corpus reports. A case komira refuses is one of those, since no
    refusal is listed. No problem means each named case was answered and
    equal to DuckDB's answer."""
    var problems = List[String]()
    var prefix = capability + ": "
    var seen = List[String]()
    for name in want:
        if name.byte_length() == 0:
            problems.append(prefix + "an empty case name in --cases")
            continue
        var again = _count(seen, name) > 0
        seen.append(name)
        if again:
            if _count(seen, name) == 2:
                problems.append(prefix + "case " + name + " is named twice")
            continue
        var staged = False
        for c in corpus.cases:
            if c.name == name:
                staged = True
        if not staged:
            problems.append(prefix + "case " + name + " is named but not staged")
    for c in corpus.cases:
        if _count(want, c.name) == 0:
            problems.append(prefix + "case " + c.name + " is staged but not named")
    if len(corpus.refusals) > 0:
        problems.append(prefix + "a refusal list is staged; every case of a capability must be answered")
    var report = check_corpus(session, corpus)
    for p in report.problems:
        problems.append(prefix + p)
    return problems^
