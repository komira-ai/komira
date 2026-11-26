"""The cases of the Mojo 1.2.0 part of the pull request check (mojo_next.bzl), which cases.bxl runs.

Table cases: mojo_next_select over lists written out here, every shape the selector can print (an
aggregate, the default aggregate, an aggregate beside other labels, a package's targets with and
without its coverage roots, the coverage tools' fixtures and a package whose name only starts like
theirs, the tests cell, a bare `//` label, duplicates, blank and padded lines, a line that is not a
label, nothing). Real cases: each shipped aggregate twin holds exactly the check set's roots that
are not coverage roots, so a root added to the check set is built with 1.2.0 unless it measures
coverage.
"""

load(":mojo_next.bzl", "BROKEN", "NONE", "SOME", "WHOLE", "is_coverage_root", "mojo_next_answer", "mojo_next_select")

_AGGREGATES = {
    "komira//ci:pr": "komira//ci:pr_mojo_next",
    "komira//ci:pr_default": "komira//ci:pr_default_mojo_next",
}

def _case(name, affected, kind, targets = None, reason = None):
    got = mojo_next_select(affected, _AGGREGATES)
    out = []
    if got.kind != kind:
        out.append("mojo_next {}: kind {} ({}), wanted {}".format(name, got.kind, got.reason, kind))
    if targets != None and got.targets != targets:
        out.append("mojo_next {}: targets {}, wanted {}".format(name, got.targets, targets))
    if reason != None and reason not in got.reason:
        out.append("mojo_next {}: reason '{}' does not say '{}'".format(name, got.reason, reason))
    return out

def mojo_next_table_cases():
    out = []
    out += _case("the aggregate builds its twin", ["komira//ci:pr"], WHOLE, ["komira//ci:pr_mojo_next"], "komira//ci:pr")
    out += _case("the default aggregate builds its twin", ["komira//ci:pr_default"], WHOLE, ["komira//ci:pr_default_mojo_next"], "komira//ci:pr_default")
    out += _case("an aggregate wins over the labels beside it", ["komira//src/a:lib", "komira//ci:pr_default"], WHOLE, ["komira//ci:pr_default_mojo_next"])
    out += _case(
        "a package's targets but its coverage roots, in the list's order, once each",
        ["komira//src/a:ci", "komira//src/a:coverage", "komira//src/a:conda", "komira//src/a:coverage_floor", "komira//src/a:ci"],
        SOME,
        ["komira//src/a:ci", "komira//src/a:conda"],
        "2 of the 4 affected targets (2 coverage roots",
    )
    out += _case(
        "the coverage tools' fixtures are left to the default compiler, their sub-packages too",
        ["tests//functional/coverage:branch_counts_threads", "tests//negative/coverage:branchnoprof", "tests//functional/coverage/sub:x", "komira//src/b:b"],
        SOME,
        ["komira//src/b:b"],
    )
    out += _case(
        "a package whose name only starts like a fixture's, or a target only named like a root, is built",
        ["tests//functional/coverage_extra:x", "tests//functional/readme_api_coverage:ok", "komira//:coverage_census", "komira//src/c:coverage_floor_cases"],
        SOME,
        ["tests//functional/coverage_extra:x", "tests//functional/readme_api_coverage:ok", "komira//:coverage_census", "komira//src/c:coverage_floor_cases"],
    )
    out += _case("only coverage roots build nothing with 1.2.0", ["komira//src/a:coverage_floor", "tests//functional/coverage:branch_info"], NONE, [], "no target but coverage roots")
    out += _case("a bare label is the komira cell's", ["//src/b:b"], SOME, ["komira//src/b:b"])
    out += _case("blank and padded lines", ["", "  komira//src/a:ci  ", "\t"], SOME, ["komira//src/a:ci"])
    out += _case("nothing affected builds nothing", [], NONE, [], "reaches no target")
    out += _case("a line that is not a label is refused", ["komira//src/a:ci", "affected: AFFECTED: 1 file(s)"], BROKEN, [], "not a target label")
    out += _case("a label with no target name is refused", ["komira//src/a"], BROKEN, [])
    out += _answer_case("a refusal is the failure, with no log and no labels", ["nope"], 'mojo_next: BROKEN: "nope" is not a target label: the selector\'s output changed shape', None, [])
    out += _answer_case("an answer is one log line and its labels", ["komira//src/a:coverage", "komira//src/a:ci"], None, "mojo_next: SOME: 1 of the 2 affected targets (1 coverage roots left to the default compiler)", ["komira//src/a:ci"])
    return out

def _answer_case(name, affected, failure, log, stdout):
    got = mojo_next_answer(affected, _AGGREGATES)
    if (got.failure, got.log, got.stdout) != (failure, log, stdout):
        return ["mojo_next answer {}: ({}, {}, {}), wanted ({}, {}, {})".format(name, repr(got.failure), repr(got.log), got.stdout, repr(failure), repr(log), stdout)]
    return []

def mojo_next_real_cases(ctx, twins):
    """Each twin (`{aggregate: twin}`) holds exactly the aggregate's roots that are no coverage root, and
    the aggregate holds at least one coverage root, so the filter has something to leave out."""
    out = []
    for aggregate, twin in twins.items():
        a = ctx.uquery().eval(aggregate)
        t = ctx.uquery().eval(twin)
        if not a or not t:
            out.append("mojo_next real: {} or {} does not exist".format(aggregate, twin))
            continue
        roots = sorted([str(x) for x in list(a)[0].get_attr("deps")])
        held = sorted([str(x) for x in list(t)[0].get_attr("deps")])
        want = [r for r in roots if not is_coverage_root(r)]
        if held != want:
            extra = [x for x in held if x not in want]
            missing = [x for x in want if x not in held]
            out.append("mojo_next real: {} is not {} without its coverage roots: extra {}, missing {}".format(twin, aggregate, extra[:5], missing[:5]))
        if len(want) == len(roots):
            out.append("mojo_next real: {} holds no coverage root, so this case proves nothing".format(aggregate))
    return out
