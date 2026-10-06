from std.testing import assert_equal, assert_true, assert_false

from change_map.cells import parse_cells
from change_map.labels import normalize_label, root_spelling, strip_config, strip_subtarget
from change_map.rules import parse_rules, pattern_matches


def _raises(text: String) -> Bool:
    try:
        _ = parse_rules(text)
    except:
        return True
    return False


def test_patterns() raises:
    assert_true(pattern_matches("tools/build/**", "tools/build/mojo/defs.bzl"))
    assert_false(pattern_matches("tools/build/**", "tools/builder/x"))
    assert_false(pattern_matches("tools/build/**", "tools/build"))
    assert_true(pattern_matches("tools/buck2*", "tools/buck2"))
    assert_true(pattern_matches("tools/buck2*", "tools/buck2/pin.txt"))
    assert_false(pattern_matches("tools/buck2*", "tools/buckx"))
    assert_true(pattern_matches("*.md", "docs/a/b.md"))
    assert_false(pattern_matches("*.md", "docs/a/b.mdx"))
    assert_true(pattern_matches(".buckconfig", ".buckconfig"))
    assert_false(pattern_matches(".buckconfig", ".buckconfig.local.example"))


def test_the_rules_grammar() raises:
    var r = parse_rules(
        "# a comment\n\nuniverse //...\nwiden prelude/** the rules every target uses\ninert *.md\n"
    )
    assert_equal(len(r.universe), 1)
    assert_equal(len(r.widen), 1)
    assert_equal(len(r.inert), 1)
    assert_equal(r.widen_reason("prelude/x.bzl"), "prelude/**: the rules every target uses")
    assert_equal(r.widen_reason("src/x.mojo"), "")
    assert_true(r.is_inert("a/b.md"))
    assert_false(r.is_inert("a/b.txt"))


def test_a_line_it_cannot_read_is_an_error() raises:
    assert_true(_raises("widen prelude/**\n"))  # no reason
    assert_true(_raises("widen\n"))
    assert_true(_raises("keep prelude/** why\n"))
    assert_true(_raises("widen a*b/c why\n"))  # a `*` in the middle matches nothing
    assert_true(_raises("widen ** why\n"))
    assert_true(_raises("inert *.md extra\n"))
    assert_true(_raises("universe a b\n"))


def test_cells() raises:
    var c = parse_cells(
        "[cells]\n  komira = .\n  # comment\n  tests = tools/build/tests\n  toolchains = tools/build/cells/toolchains\n"
        + "  none = none\n\n[build]\n  other = x\n"
    )
    assert_equal(c.root, "komira")
    assert_equal(len(c.names), 3)
    assert_equal(c.package_pattern("src/komira_core"), "komira//src/komira_core:")
    assert_equal(c.package_pattern(""), "komira//:")
    assert_equal(c.package_pattern("tools/build/tests/functional"), "tests//functional:")
    assert_equal(c.package_pattern("tools/build/tests"), "tests//:")
    assert_equal(c.package_pattern("tools/build/testsuite"), "komira//tools/build/testsuite:")


def test_a_buckconfig_with_no_root_cell_is_an_error() raises:
    var failed = False
    try:
        _ = parse_cells("[cells]\n  tests = tools/build/tests\n")
    except:
        failed = True
    assert_true(failed)


def test_labels() raises:
    assert_equal(strip_config("komira//a:b (komira//p:linux#03cc)"), "komira//a:b")
    assert_equal(strip_subtarget("//a:b[release]"), "//a:b")
    assert_equal(root_spelling("komira//a:b", "komira"), "//a:b")
    assert_equal(root_spelling("tests//a:b", "komira"), "tests//a:b")
    assert_equal(root_spelling("komiraX//a:b", "komira"), "komiraX//a:b")
    assert_equal(normalize_label("komira//src/x:x_conda[release] (komira//p:l#1)", "komira"), "//src/x:x_conda")


def main() raises:
    test_patterns()
    test_the_rules_grammar()
    test_a_line_it_cannot_read_is_an_error()
    test_cells()
    test_a_buckconfig_with_no_root_cell_is_an_error()
    test_labels()
    print("test_rules_cells_labels: PASS")
