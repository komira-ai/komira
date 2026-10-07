from std.testing import assert_equal, assert_true

from change_map.rules import read_rules

# The shipped rules.txt, held to the paths that must never be mapped by guess:
# a change to any of them can reach every target through the configuration, the
# rules or the toolchain, so it widens. Deleting a line of rules.txt fails here.

comptime RULES_FILE = "tools/build/ci/rules.txt"


def test_what_must_widen_widens() raises:
    var r = read_rules(RULES_FILE)
    var must = List[String]()
    must.append(".buckconfig")
    must.append(".buckconfig.local.example")
    must.append("buck2")
    must.append("tools/buck2/main")
    must.append("prelude/cxx/cxx.bzl")
    must.append("tools/build/platforms/BUCK")
    must.append("tools/build/cells/toolchains/BUCK")
    must.append("tools/build/mojo/defs.bzl")
    must.append("tools/build/ci/rules.txt")
    must.append("tools/build/ci/affected.mojo")
    must.append("third_party/snappy/pin.bzl")
    for i in range(len(must)):
        assert_true(r.widen_reason(must[i]).byte_length() > 0)


def test_what_is_ordinary_does_not_widen() raises:
    var r = read_rules(RULES_FILE)
    var ordinary = List[String]()
    ordinary.append("src/komira_collections/BUCK")
    ordinary.append("src/komira_collections/slab.mojo")
    ordinary.append("docs/ci.md")
    ordinary.append("release/artifacts.textproto")
    ordinary.append(".github/workflows/ci.yml")
    ordinary.append("tools/core_split/no_mixed_closure.sh")
    for i in range(len(ordinary)):
        assert_equal(r.widen_reason(ordinary[i]), "")


def test_the_universe_is_both_cells_of_buildable_targets() raises:
    var r = read_rules(RULES_FILE)
    assert_equal(len(r.universe), 2)
    assert_equal(r.universe[0], "//...")
    assert_equal(r.universe[1], "tests//...")


def test_inert_is_only_what_builds_nothing() raises:
    var r = read_rules(RULES_FILE)
    assert_true(r.is_inert("README.md"))
    assert_true(r.is_inert("LICENSE"))
    assert_true(not r.is_inert("src/x/x.mojo"))
    assert_true(not r.is_inert("release/channels.textproto"))


def main() raises:
    test_what_must_widen_widens()
    test_what_is_ordinary_does_not_widen()
    test_the_universe_is_both_cells_of_buildable_targets()
    test_inert_is_only_what_builds_nothing()
    print("test_rules_file: PASS")
