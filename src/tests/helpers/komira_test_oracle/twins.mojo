# =============================================================================
# komira_test_oracle/twins.mojo -- each oracle answer against its HAND twin.
# =============================================================================
#
# An ORACLE case (oracle/<shard>/<case>.sql) has a HAND twin: the
# expectation komira_plan_conformance derives by hand from the query
# semantics document for the same rows (or, for a shard the corpus does not
# hold yet, twins/<shard>/<case>.tsv here). check_twins reads, under a root,
# every DuckDB answer `oracle/<shard>/<case>.tsv` and every HAND file
# `hand/<shard>/<case>.tsv` (BUCK stages both), pairs them by name, and holds
# each answer to its twin BY VALUE: the answer is read with
# komira_plan_harness's duckdb_tsv under the twin's schema and policy, then
# compared with compare_canon. Every problem is reported, not only the first:
# an answer with no twin, a twin with no answer, an answer that does not
# read under the twin's schema, and each mismatch.
# =============================================================================

from std.os import listdir
from std.pathlib import Path

from komira_plan_harness import (
    compare_canon,
    duckdb_tsv_canon,
    parse_canon,
    parse_duckdb_tsv,
)


struct TwinReport(Movable):
    var compared: Int
    var problems: List[String]

    def __init__(out self):
        self.compared = 0
        self.problems = List[String]()


def check_twin(name: String, answer_tsv: String, hand_text: String) -> List[String]:
    """The problems of one answer against its twin (none when they agree)."""
    var res = List[String]()
    try:
        var hand = parse_canon(hand_text)
        var answer = duckdb_tsv_canon(parse_duckdb_tsv(answer_tsv), hand)
        var report = compare_canon(hand, answer)
        if not report.ok():
            res.append(name + ": the DuckDB answer and its HAND twin differ: " + String(report))
    except e:
        res.append(name + ": " + String(e))
    return res^


def pair_names(answers: List[String], hands: List[String]) -> List[String]:
    """An answer with no twin, and a twin with no answer, by name."""
    var res = List[String]()
    for a in answers:
        var found = False
        for h in hands:
            if h == a:
                found = True
        if not found:
            res.append(a + ": a DuckDB answer with no HAND twin")
    for h in hands:
        var found = False
        for a in answers:
            if a == h:
                found = True
        if not found:
            res.append(h + ": a HAND twin with no DuckDB answer")
    return res^


def _names(top: String) raises -> List[String]:
    """`<shard>/<case>` of every `<top>/<shard>/<case>.tsv`, sorted."""
    var res = List[String]()
    if not Path(top).exists():
        return res^
    for shard in listdir(top):
        var dir_path = top + "/" + shard
        for f in listdir(dir_path):
            if f.endswith(".tsv"):
                res.append(shard + "/" + String(f[byte = 0 : f.byte_length() - 4]))
    sort(res)
    return res^


def check_twins(root: String) raises -> TwinReport:
    var report = TwinReport()
    var answers = _names(root + "/oracle")
    var hands = _names(root + "/hand")
    for p in pair_names(answers, hands):
        report.problems.append(p)
    for a in answers:
        for h in hands:
            if h == a:
                report.compared += 1
                var answer_text = Path(root + "/oracle/" + a + ".tsv").read_text()
                var hand_text = Path(root + "/hand/" + a + ".tsv").read_text()
                for p in check_twin(a, answer_text, hand_text):
                    report.problems.append(p)
    return report^
