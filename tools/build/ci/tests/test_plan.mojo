from std.testing import assert_equal, assert_true, assert_false

from buildtools.bytes import bytes_less

from change_map.graph import Graph, PackageOf, PACKAGE_FOUND, PACKAGE_NONE, PACKAGE_UNKNOWN
from change_map.plan import KIND_AFFECTED, KIND_EMPTY, KIND_VACUOUS, KIND_WIDENED, Verdict, compute, uncovered
from change_map.report import render_units_answer
from change_map.rules import Rules, parse_rules, read_rules
from change_map.units import affected_units, parse_units_file

# The fake repository:
#
#   //lib/a:a  <-  //lib/b:b  <-  //app:app        (a is loaded by macros/defs.bzl,
#   //docs:doc_tree lists docs/x.md                  as are lib/b's BUCK and app's)
#   //tools/x:y                                     (nothing depends on it)
#
# `a.mojo` is listed by //lib/a:a, `b.mojo` by //lib/b:b. `gone/old.mojo` was
# in package lib/b at the base and is deleted; `removed/x.mojo` was in package
# `removed`, which is gone.

comptime RULES = """
universe //...
widen tools/build/** the build system is loaded by every target
widen .buckconfig the configuration of every target
inert *.md
inert LICENSE
"""


def _list(*items: String) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i])
    return out^


struct FakeGraph(Graph, Movable):
    var existing: List[String]
    var owner_of: Dict[String, List[String]]
    var including: Dict[String, List[String]]
    var base_package: Dict[String, String]
    var packages: List[String]
    var universe: List[String]
    var dependents: Dict[String, List[String]]
    var package_targets: Dict[String, List[String]]
    var base_known: Bool
    var fail_owners: Bool
    var fail_rdeps: Bool
    var rdeps_error: String
    var empty_rdeps: Bool
    var asked_owners: Int
    var asked_paths: List[String]

    def __init__(out self):
        self.existing = _list(
            "lib/a/a.mojo", "lib/a/BUCK", "lib/b/b.mojo", "lib/b/BUCK", "app/main.mojo", "app/BUCK",
            "docs/x.md", "macros/defs.bzl", "macros/loose.bzl", "NOTES.md", "stray.txt",
            "tools/build/cells/toolchains/BUCK", ".buckconfig", "tools/x/y.mojo",
        )
        self.owner_of = Dict[String, List[String]]()
        self.owner_of["lib/a/a.mojo"] = _list("//lib/a:a")
        self.owner_of["lib/b/b.mojo"] = _list("//lib/b:b")
        self.owner_of["app/main.mojo"] = _list("//app:app")
        self.owner_of["docs/x.md"] = _list("//docs:doc_tree")
        self.owner_of["tools/x/y.mojo"] = _list("//tools/x:y")
        self.including = Dict[String, List[String]]()
        self.including["macros/defs.bzl"] = _list("lib/a", "lib/b")
        self.base_package = Dict[String, String]()
        self.base_package["gone/old.mojo"] = "lib/b"
        self.base_package["removed/x.mojo"] = "removed"
        self.packages = _list("lib/a", "lib/b", "app", "docs", "tools/x")
        self.universe = _list("//app:app", "//docs:doc_tree", "//lib/a:a", "//lib/b:b", "//tools/x:y")
        self.dependents = Dict[String, List[String]]()
        self.dependents["//lib/a:a"] = _list("//lib/b:b")
        self.dependents["//lib/b:b"] = _list("//app:app")
        self.package_targets = Dict[String, List[String]]()
        self.package_targets["//lib/a:"] = _list("//lib/a:a")
        self.package_targets["//lib/b:"] = _list("//lib/b:b")
        self.package_targets["//app:"] = _list("//app:app")
        self.base_known = True
        self.fail_owners = False
        self.fail_rdeps = False
        self.rdeps_error = String("")
        self.empty_rdeps = False
        self.asked_owners = 0
        self.asked_paths = List[String]()

    def file_exists(mut self, path: String) raises -> Bool:
        for i in range(len(self.existing)):
            if self.existing[i] == path:
                return True
        return False

    def owners(mut self, paths: List[String]) raises -> List[List[String]]:
        self.asked_owners += 1
        for i in range(len(paths)):
            self.asked_paths.append(paths[i])
        if self.fail_owners:
            raise Error("buck2 uquery failed")
        var out = List[List[String]]()
        for i in range(len(paths)):
            if paths[i] in self.owner_of:
                out.append(self.owner_of[paths[i]].copy())
            else:
                out.append(List[String]())
        return out^

    def packages_including(mut self, bzl: String) raises -> List[String]:
        if bzl in self.including:
            return self.including[bzl].copy()
        return List[String]()

    def package_at_base(mut self, path: String) raises -> PackageOf:
        if not self.base_known:
            return PackageOf(PACKAGE_UNKNOWN)
        if path in self.base_package:
            return PackageOf(PACKAGE_FOUND, self.base_package[path])
        return PackageOf(PACKAGE_NONE)

    def has_package(mut self, dir: String) raises -> Bool:
        for i in range(len(self.packages)):
            if self.packages[i] == dir:
                return True
        return False

    def package_pattern(mut self, dir: String) raises -> String:
        return String("//") + dir + String(":")

    def rdeps(mut self, seeds: List[String]) raises -> List[String]:
        if self.fail_rdeps:
            raise Error("cquery failed")
        if self.rdeps_error.byte_length() > 0:
            raise Error(self.rdeps_error)
        if self.empty_rdeps:
            return List[String]()
        var out = List[String]()
        var work = List[String]()
        for i in range(len(seeds)):
            if seeds[i] in self.package_targets:
                for k in range(len(self.package_targets[seeds[i]])):
                    work.append(self.package_targets[seeds[i]][k])
            else:
                work.append(seeds[i])
        while len(work) > 0:
            var t = work.pop()
            var seen = False
            for i in range(len(out)):
                if out[i] == t:
                    seen = True
            if seen:
                continue
            out.append(t)
            if t in self.dependents:
                for k in range(len(self.dependents[t])):
                    work.append(self.dependents[t][k])
        return out^

    def all_targets(mut self) raises -> List[String]:
        return self.universe.copy()

    def closure(mut self, targets: List[String]) raises -> List[String]:
        # the targets and what they depend on: a dependent's dependency is the
        # reverse of `dependents`
        var out = List[String]()
        for i in range(len(targets)):
            out.append(targets[i])
        var grew = True
        while grew:
            grew = False
            for dep in self.dependents.keys():
                for k in range(len(self.dependents[dep])):
                    if _has(out, self.dependents[dep][k]) and not _has(out, dep):
                        out.append(dep)
                        grew = True
        return out^


def _has(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _compute(files: List[String], mut g: FakeGraph) raises -> Verdict:
    return compute(parse_rules(String(RULES)), files, g)


def _widened_everything(v: Verdict, g: FakeGraph) raises:
    assert_equal(v.kind, String(KIND_WIDENED))
    assert_equal(len(v.targets), len(g.universe))
    assert_true(v.reason.byte_length() > 0)


def test_a_leaf_source_reaches_what_depends_on_it() raises:
    var g = FakeGraph()
    var v = _compute(_list("lib/a/a.mojo"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_equal(len(v.targets), 3)
    assert_true(_has(v.targets, "//lib/a:a"))
    assert_true(_has(v.targets, "//lib/b:b"))
    assert_true(_has(v.targets, "//app:app"))
    assert_false(_has(v.targets, "//tools/x:y"))
    assert_equal(v.seeds, 1)
    assert_equal(v.files, 1)


def test_the_top_of_the_graph_reaches_only_itself() raises:
    var g = FakeGraph()
    var v = _compute(_list("app/main.mojo"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_equal(len(v.targets), 1)


def test_an_inert_file_that_a_target_owns_is_mapped() raises:
    var g = FakeGraph()
    var v = _compute(_list("docs/x.md"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_equal(len(v.targets), 1)
    assert_equal(v.targets[0], "//docs:doc_tree")
    assert_equal(len(v.warnings), 0)


def test_an_ownerless_inert_file_alone_is_vacuous() raises:
    var g = FakeGraph()
    var v = _compute(_list("NOTES.md"), g)
    assert_equal(v.kind, String(KIND_VACUOUS))
    assert_equal(len(v.targets), 0)
    assert_true(v.reason.find("NOTES.md") >= 0)
    assert_equal(len(v.warnings), 1)
    assert_true(v.warnings[0].find("NOTES.md") >= 0)


def test_an_ownerless_inert_file_does_not_widen_the_rest() raises:
    var g = FakeGraph()
    var v = _compute(_list("NOTES.md", "lib/a/a.mojo"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_equal(len(v.targets), 3)
    assert_equal(len(v.warnings), 1)


def test_an_ownerless_file_no_rule_names_widens_everything() raises:
    var g = FakeGraph()
    var v = _compute(_list("lib/a/a.mojo", "stray.txt"), g)
    _widened_everything(v, g)
    assert_true(v.reason.find("stray.txt") >= 0)
    assert_true(len(v.warnings) >= 1)


def test_a_bzl_reaches_every_package_that_loads_it() raises:
    var g = FakeGraph()
    var v = _compute(_list("macros/defs.bzl"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_true(_has(v.targets, "//lib/a:a"))
    assert_true(_has(v.targets, "//lib/b:b"))
    assert_true(_has(v.targets, "//app:app"))
    assert_false(_has(v.targets, "//docs:doc_tree"))
    assert_equal(v.seeds, 2)


def test_a_bzl_no_BUCK_file_loads_widens() raises:
    var g = FakeGraph()
    var v = _compute(_list("macros/loose.bzl"), g)
    _widened_everything(v, g)
    assert_true(v.reason.find("loose.bzl") >= 0)


def test_a_BUCK_file_reaches_its_whole_package() raises:
    var g = FakeGraph()
    var v = _compute(_list("lib/b/BUCK"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_true(_has(v.targets, "//lib/b:b"))
    assert_true(_has(v.targets, "//app:app"))
    assert_false(_has(v.targets, "//lib/a:a"))


def test_a_deleted_file_is_looked_up_in_the_base_tree() raises:
    var g = FakeGraph()
    var v = _compute(_list("gone/old.mojo"), g)
    assert_equal(v.kind, String(KIND_AFFECTED))
    assert_true(_has(v.targets, "//lib/b:b"))
    assert_true(_has(v.targets, "//app:app"))
    assert_false(_has(v.targets, "//lib/a:a"))
    # nothing asked buck2 about a file the tree no longer has
    assert_false(_has(g.asked_paths, "gone/old.mojo"))


def test_a_deleted_file_of_a_deleted_package_widens() raises:
    var g = FakeGraph()
    _widened_everything(_compute(_list("removed/x.mojo"), g), g)


def test_a_deleted_file_with_no_base_revision_widens() raises:
    var g = FakeGraph()
    g.base_known = False
    var v = _compute(_list("gone/old.mojo"), g)
    _widened_everything(v, g)
    assert_true(v.reason.find("base") >= 0)


def test_a_deleted_file_no_package_held_widens() raises:
    var g = FakeGraph()
    _widened_everything(_compute(_list("never/was.mojo"), g), g)


def test_a_toolchain_change_widens_everything() raises:
    var g = FakeGraph()
    var v = _compute(_list("tools/build/cells/toolchains/BUCK"), g)
    _widened_everything(v, g)
    assert_true(v.reason.find("tools/build/**") >= 0)


def test_a_widening_file_widens_even_beside_mapped_ones() raises:
    var g = FakeGraph()
    _widened_everything(_compute(_list("lib/a/a.mojo", ".buckconfig"), g), g)


def test_an_empty_change_is_empty_and_asks_nothing() raises:
    var g = FakeGraph()
    var v = _compute(List[String](), g)
    assert_equal(v.kind, String(KIND_EMPTY))
    assert_equal(len(v.targets), 0)
    assert_equal(g.asked_owners, 0)


def test_the_same_file_twice_counts_once() raises:
    var g = FakeGraph()
    var v = _compute(_list("lib/a/a.mojo", "lib/a/a.mojo"), g)
    assert_equal(v.files, 1)


def test_a_failing_owner_query_widens_never_passes() raises:
    var g = FakeGraph()
    g.fail_owners = True
    var v = _compute(_list("lib/a/a.mojo"), g)
    _widened_everything(v, g)
    assert_true(v.reason.find("buck2 uquery failed") >= 0)


def test_a_failing_rdeps_query_widens() raises:
    var g = FakeGraph()
    g.fail_rdeps = True
    _widened_everything(_compute(_list("lib/a/a.mojo"), g), g)


# What BuckGraph.rdeps raised in the per-change check when the universe held
# a target that fails analysis by design (a negative fixture naming a target
# not visible to it): buck2's own text, as `_buck` wraps it.
comptime UNCONFIGURABLE: String = (
    String("buck2 cquery failed (exit 3): [2026-10-10T01:02:37.138+00:00] Build ID: 67a6")
    + String(" Command failed:  Error looking up configured node")
    + String(" tests//negative/node/visibility:node_not_visible")
    + String(" (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)  Caused by:")
    + String("     `komira//third_party/node:node` is not visible to")
    + String(" `tests//negative/node/visibility:node_not_visible`")
)


def test_a_target_the_universe_cannot_configure_is_named_and_never_widens() raises:
    # A target outside the change that buck2 cannot configure breaks the
    # query for every change. Widening would turn it into every unit on every
    # change (the check times out, the cause buried in a reason); the answer
    # is "cannot tell", naming the target, so the change that planted it is
    # refused by its own check and the next one is not silently widened.
    var g = FakeGraph()
    g.rdeps_error = String(UNCONFIGURABLE)
    var raised = String("")
    try:
        var v = _compute(_list("lib/a/a.mojo"), g)
        raised = String("no error: ") + v.kind + String(" ") + String(len(v.targets)) + String(" target(s)")
    except e:
        raised = String(e)
    assert_true(
        raised.startswith(String("the universe holds a target buck2 cannot configure: tests//negative/node/visibility:node_not_visible")),
        raised,
    )
    # buck2's cause stays in the message
    assert_true(raised.find(String("is not visible to")) >= 0, raised)


def test_an_rdeps_answer_of_nothing_widens() raises:
    var g = FakeGraph()
    g.empty_rdeps = True
    _widened_everything(_compute(_list("lib/a/a.mojo"), g), g)


def test_the_targets_are_sorted_and_unique() raises:
    var g = FakeGraph()
    var v = _compute(_list("lib/a/a.mojo", "lib/b/b.mojo", "docs/x.md"), g)
    for i in range(1, len(v.targets)):
        assert_true(bytes_less(v.targets[i - 1], v.targets[i]))


def test_coverage_is_what_no_unit_builds_or_depends_on() raises:
    var g = FakeGraph()
    # a unit on //app:app holds app, b and a; docs and tools/x are uncovered
    var held = g.closure(_list("//app:app"))
    var left = uncovered(g.all_targets(), held)
    assert_equal(len(left), 2)
    assert_equal(left[0], "//docs:doc_tree")
    assert_equal(left[1], "//tools/x:y")
    assert_equal(len(uncovered(g.all_targets(), g.all_targets())), 0)


# The release template's wiring, end to end over the fake repository: the
# changed files of a pull request, the SHIPPED rules.txt, a units file of the
# shape kci writes, and the exact text kci reads back. A row of this table is
# the answer `kci run --stage pr` would act on.

def _units_text() -> String:
    return String(
        "docs_unit\t//docs:\nlib_a\t//lib/a/...\nlib_b\t//lib/b:\napp\t//app:app\ntools_x\t//tools/...\n"
    )


def _answer(files: List[String]) raises -> String:
    var g = FakeGraph()
    var rules = read_rules(String("tools/build/ci/rules.txt"))
    var v = compute(rules, files, g)
    var units = parse_units_file(_units_text())
    var names = affected_units(units, v.targets, String("komira"))
    return render_units_answer(v, names)


def test_the_answer_kci_reads_for_a_table_of_changes() raises:
    # a doc: its link check, nothing else
    assert_equal(_answer(_list("docs/x.md")), "UNIT docs_unit\nAFFECTED 1\n")
    # a source: its package and everything above it, units in the units file's order
    assert_equal(_answer(_list("lib/a/a.mojo")), "UNIT lib_a\nUNIT lib_b\nUNIT app\nAFFECTED 3\n")
    assert_equal(_answer(_list("lib/b/b.mojo")), "UNIT lib_b\nUNIT app\nAFFECTED 2\n")
    assert_equal(_answer(_list("app/main.mojo")), "UNIT app\nAFFECTED 1\n")
    assert_equal(_answer(_list("tools/x/y.mojo")), "UNIT tools_x\nAFFECTED 1\n")
    # a .bzl: every package that loads it, and what is above them
    assert_equal(_answer(_list("macros/defs.bzl")), "UNIT lib_a\nUNIT lib_b\nUNIT app\nAFFECTED 3\n")
    # a BUCK file: its package
    assert_equal(_answer(_list("lib/b/BUCK")), "UNIT lib_b\nUNIT app\nAFFECTED 2\n")
    # two files: the union, once each
    assert_equal(
        _answer(_list("docs/x.md", "app/main.mojo")),
        "UNIT docs_unit\nUNIT app\nAFFECTED 2\n",
    )
    # a deleted file: the package that held it
    assert_equal(_answer(_list("gone/old.mojo")), "UNIT lib_b\nUNIT app\nAFFECTED 2\n")


def test_the_answer_for_what_cannot_be_mapped_is_widened_with_a_reason() raises:
    var cannot = List[List[String]]()
    cannot.append(_list(".buckconfig"))
    cannot.append(_list("tools/build/cells/toolchains/BUCK"))
    cannot.append(_list("stray.txt"))
    cannot.append(_list("macros/loose.bzl"))
    cannot.append(_list("lib/a/a.mojo", ".buckconfig"))
    for i in range(len(cannot)):
        var a = _answer(cannot[i])
        assert_true(a.startswith("WIDENED "))
        assert_true(a.find("UNIT") < 0)
        assert_equal(len(a.split("\n")), 2)  # one line and the trailing newline


def test_a_non_empty_change_reaching_nothing_is_never_answered_as_everything() raises:
    # VACUOUS: no unit, and no widening: kci refuses `AFFECTED 0` (a check
    # over nothing is not a pass); answering WIDENED would build everything
    # and pass a change nothing maps.
    assert_equal(_answer(_list("NOTES.md")), "AFFECTED 0\n")
    assert_equal(_answer(_list("NOTES.md", "LICENSE")), "AFFECTED 0\n")
    # the empty change prints the same, and kci refuses it before asking
    assert_equal(_answer(List[String]()), "AFFECTED 0\n")


def main() raises:
    test_coverage_is_what_no_unit_builds_or_depends_on()
    test_a_leaf_source_reaches_what_depends_on_it()
    test_the_top_of_the_graph_reaches_only_itself()
    test_an_inert_file_that_a_target_owns_is_mapped()
    test_an_ownerless_inert_file_alone_is_vacuous()
    test_an_ownerless_inert_file_does_not_widen_the_rest()
    test_an_ownerless_file_no_rule_names_widens_everything()
    test_a_bzl_reaches_every_package_that_loads_it()
    test_a_bzl_no_BUCK_file_loads_widens()
    test_a_BUCK_file_reaches_its_whole_package()
    test_a_deleted_file_is_looked_up_in_the_base_tree()
    test_a_deleted_file_of_a_deleted_package_widens()
    test_a_deleted_file_with_no_base_revision_widens()
    test_a_deleted_file_no_package_held_widens()
    test_a_toolchain_change_widens_everything()
    test_a_widening_file_widens_even_beside_mapped_ones()
    test_an_empty_change_is_empty_and_asks_nothing()
    test_the_same_file_twice_counts_once()
    test_a_failing_owner_query_widens_never_passes()
    test_a_failing_rdeps_query_widens()
    test_a_target_the_universe_cannot_configure_is_named_and_never_widens()
    test_an_rdeps_answer_of_nothing_widens()
    test_the_targets_are_sorted_and_unique()
    test_the_answer_kci_reads_for_a_table_of_changes()
    test_the_answer_for_what_cannot_be_mapped_is_widened_with_a_reason()
    test_a_non_empty_change_reaching_nothing_is_never_answered_as_everything()
    print("test_plan: PASS")
