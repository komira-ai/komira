# The cases the Node runtime runs (node_cases.mojo) against the corpus of
# komira_udf_spike_abi.
#
# What it proves: the corpus has 38 cases and the Node runtime runs 30, each
# of them with its entry rewritten to `fixtures.js#<name>`; the eight it
# leaves out are the ones named, and `select_cases` raises UDF_CASES_CHANGED
# when a name it is told to leave out is not in the corpus.
#
# Defects caught: a list of left-out cases gone stale (a case renamed or
# removed in the corpus would silently run, or silently not), an entry not
# rewritten (the runtime would refuse it as no `bundle.js#export`), a case
# dropped that was not meant to be.
#
# Mutant planted: select_cases not rewriting the entry: red (entries are
# bare names).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import load_cases
from komira_udf_spike_node.node_cases import left_out_cases, node_cases, select_cases

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime CORPUS = 38
comptime RUN = 30


def main() raises:
    var corpus = load_cases(CASES)
    assert_equal(len(corpus), CORPUS, "cases in the corpus")
    var cases = node_cases(CASES)
    assert_equal(len(cases), RUN, "cases the Node runtime runs")
    assert_equal(len(left_out_cases()), CORPUS - RUN, "cases left out")
    var seen_never_ends = False
    for i in range(len(cases)):
        ref c = cases[i]
        assert_true(c.name not in left_out_cases(), c.name + " is left out")
        if c.spec.entry != "":
            assert_true(c.spec.entry.startswith("fixtures.js#"), c.name + ": entry " + c.spec.entry)
        if c.name == "fault_frame_never_ends":
            seen_never_ends = True
    assert_true(seen_never_ends, "the frame that never ends is user code and runs")
    var raised = False
    try:
        _ = select_cases(corpus, ["no_such_case"])
    except e:
        raised = String(e).startswith("UDF_CASES_CHANGED")
    assert_true(raised, "a stale left-out name must raise UDF_CASES_CHANGED")
    print("test_node_cases: ok")
