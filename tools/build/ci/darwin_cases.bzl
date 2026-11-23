"""The cases of the macOS part of the pull request check (darwin.bzl), which cases.bxl runs.

Table cases: darwin_select over lists written out here, every shape the selector can print (an
aggregate, the default aggregate, the `:lib` of a set package, the other targets of a set package,
a package outside the set, a sub-package, the tests cell, a bare `//` label, blank and padded
lines, a line that is not a label, nothing). Real cases: the shipped list and the shipped set
agree, so what the pull request builds for macOS is a part of what release-macos.yml builds.
"""

load(":darwin.bzl", "BROKEN", "NONE", "SOME", "WHOLE", "darwin_select")

_SET = "komira//release:mopm_darwin_libs"
_AGGREGATES = ["komira//ci:pr", "komira//ci:pr_default"]
_PACKAGES = ["a", "b", "c"]

def _case(name, affected, kind, targets = None, reason = None):
    got = darwin_select(affected, _PACKAGES, _AGGREGATES, _SET)
    out = []
    if got.kind != kind:
        out.append("darwin {}: kind {} ({}), wanted {}".format(name, got.kind, got.reason, kind))
    if targets != None and got.targets != targets:
        out.append("darwin {}: targets {}, wanted {}".format(name, got.targets, targets))
    if reason != None and reason not in got.reason:
        out.append("darwin {}: reason '{}' does not say '{}'".format(name, got.reason, reason))
    return out

def darwin_table_cases():
    out = []
    out += _case("the aggregate builds the whole set", ["komira//ci:pr"], WHOLE, [_SET], "komira//ci:pr")
    out += _case("the default aggregate builds the whole set", ["komira//ci:pr_default"], WHOLE, [_SET], "komira//ci:pr_default")
    out += _case("an aggregate wins over the libraries beside it", ["komira//src/a:lib", "komira//ci:pr_default"], WHOLE, [_SET])
    out += _case(
        "the libraries reached, in the set's order, once each",
        ["komira//src/c:lib", "komira//src/a:lib", "komira//src/c:lib", "komira//src/a:ci"],
        SOME,
        ["komira//src/a:lib", "komira//src/c:lib"],
        "2 of the 3",
    )
    out += _case("the other targets of a set package build nothing for macOS", ["komira//src/b:ci", "komira//src/b:conda", "komira//src/b:b"], NONE, [])
    out += _case("a library outside the set builds nothing for macOS", ["komira//src/z:lib"], NONE, [])
    out += _case("a sub-package of a set package is not its library", ["komira//src/a/sub:lib", "komira//src/ab:lib"], NONE, [])
    out += _case("the tests cell is never built for macOS", ["tests//functional/src/a:lib"], NONE, [])
    out += _case("a bare label is the komira cell's", ["//src/b:lib"], SOME, ["komira//src/b:lib"])
    out += _case("blank and padded lines", ["", "  komira//src/a:lib  ", "\t"], SOME, ["komira//src/a:lib"])
    out += _case("nothing affected builds nothing", [], NONE, [], "no library")
    out += _case("a line that is not a label is refused", ["komira//src/a:lib", "affected: AFFECTED: 1 file(s)"], BROKEN, [], "not a target label")
    out += _case("a label with no target name is refused", ["komira//src/a"], BROKEN, [])
    return out

def darwin_real_cases(ctx, packages, darwin_set):
    """The shipped list `packages` (DARWIN_PACKAGES) names exactly the libraries `darwin_set` builds,
    and the whole list selected is the whole set: a package added to one and not the other fails."""
    out = []
    node = ctx.uquery().eval(darwin_set)
    libs = sorted([str(t) for t in list(node)[0].get_attr("libs")]) if node else []
    selected = darwin_select(["komira//src/{}:lib".format(p) for p in packages], packages, _AGGREGATES, darwin_set)
    if not libs:
        out.append("darwin real: {} has no `libs`: the set changed shape".format(darwin_set))
    if selected.kind != SOME or sorted(selected.targets) != libs:
        out.append("darwin real: selecting every package of DARWIN_PACKAGES gives {} ({}), but {} builds {}".format(selected.targets, selected.kind, darwin_set, libs))
    return out
