# The naming and grouping of the derived checks (change_map/derive.mojo),
# welded to //tools/build/ci:change_map: //tools/build/ci:derive_checks
# cannot be built while one fails, so a naming kci would refuse never reaches
# the per-change check.
#
# - NAMES: (label, the unit names already declared, the check name it must
#   get). Each row holds one rule: lower case, any other code point one `_`
#   (a byte-wise `_` per UTF-8 byte gives `komira__` for `komiraé` and is
#   red), `pkg_` before a name not starting with a letter, the src/tests
#   kinds, `tools_`, `repo_root`, `functional_tests`, and `_package` until
#   the name is free. Every answer must also be `[a-z][a-z0-9_]*`.
# - PATTERNS: (label, the pattern of the check it lands in). A test-only
#   package keeps a pattern of its own, not one shared by all of src/tests:
#   a pattern of `//src/tests/...` builds every test package for a change to
#   one and is red here.
# - the pattern grammar (`is_pattern`, `matches`): a name that only shares a
#   prefix with a package is not below it, `//:` is the root package only,
#   and a pattern is per cell.

from std.testing import assert_equal, assert_false, assert_true

from change_map.derive import check_name, derive, group_pattern, is_pattern, is_valid_name, matches, unit_name
from change_map.units import UnitTargets


def _taken(*names: String) -> Dict[String, Bool]:
    var out = Dict[String, Bool]()
    for i in range(len(names)):
        out[names[i]] = True
    return out^


def _none() -> Dict[String, Bool]:
    return Dict[String, Bool]()


def _name(label: String, taken: Dict[String, Bool], want: String) raises:
    var got = check_name(label, taken)
    assert_equal(got, want, String("check_name(") + label + String(")"))
    assert_true(is_valid_name(got), String("not a name kci accepts: ") + got)


def test_the_names() raises:
    _name("//src/komira_clock:komira_clock", _none(), "komira_clock")
    _name("//src/komira-x.y:t", _none(), "komira_x_y")
    _name("//src/Komira_Up:komira_clock", _none(), "komira_up")
    _name("//src/3d:t", _none(), "pkg_3d")
    _name("//src/_x:t", _none(), "pkg__x")
    _name("//src/komira+x:t", _none(), "komira_x")
    _name("//src/komiraé:t", _none(), "komira_")
    _name("//Bench/a:t", _none(), "bench")
    _name("//tools/Foo:t", _none(), "tools_foo")
    _name("//tools/9z:t", _none(), "tools_9z")
    _name("//src:t", _none(), "src")
    _name("//src/tests/e2e/komira_x_e2e:t", _none(), "komira_x_e2e")
    _name("//src/tests/helpers/komira_y/sub:t", _none(), "komira_y")
    _name("//src/tests/e2e:t", _none(), "tests")
    _name("//src/tests:t", _none(), "tests")
    _name("//:t", _none(), "repo_root")
    _name("tests//functional/x:t", _none(), "functional_tests")
    _name("//src/Komira_Up:t", _taken("komira_up"), "komira_up_package")
    _name("//src/a:t", _taken("a", "a_package"), "a_package_package")


def test_a_name_is_lowered_and_mangled_per_code_point() raises:
    assert_equal(unit_name("ABC"), "abc")
    assert_equal(unit_name("aé中b"), "a__b")  # two code points, two `_`
    assert_equal(unit_name(""), "pkg_")
    assert_true(is_valid_name("a_9"))
    assert_false(is_valid_name("9a"))
    assert_false(is_valid_name("_a"))
    assert_false(is_valid_name("aB"))
    assert_false(is_valid_name(""))


def _pattern(label: String, want: String) raises:
    assert_equal(group_pattern(label), want, String("group_pattern(") + label + String(")"))
    # derive() over the label alone: the one check, named by check_name, with that pattern
    var d = derive(UnitTargets(), [label])
    assert_equal(len(d.names), 1)
    assert_equal(d.names[0], check_name(label, _none()))
    assert_equal(len(d.patterns[0]), 1)
    assert_equal(d.patterns[0][0], want)


def test_the_patterns() raises:
    _pattern("//src/komira_clock:komira_clock", "//src/komira_clock/...")
    _pattern("//src/tests/e2e/komira_x_e2e:t", "//src/tests/e2e/komira_x_e2e/...")
    _pattern("//src/tests/conformance/komira_c_conformance:t", "//src/tests/conformance/komira_c_conformance/...")
    _pattern("//src/tests/helpers/komira_y/sub:t", "//src/tests/helpers/komira_y/...")
    _pattern("//src/tests/e2e:t", "//src/tests/e2e:")
    _pattern("//src:t", "//src:")
    _pattern("//tools/build/ci:affected", "//tools/build/...")
    _pattern("//docs/design:x", "//docs/...")
    _pattern("//:docs", "//:")
    _pattern("tests//functional/a/b:t", "tests//functional/...")


def test_every_name_derived_from_the_table_is_one_kci_accepts() raises:
    var labels: List[String] = [
        "//src/komira_clock:komira_clock", "//src/komira-x.y:t", "//src/Komira_Up:komira_clock", "//src/3d:t",
        "//src/_x:t", "//src/komira+x:t", "//src/komiraé:t", "//Bench/a:t", "//tools/Foo:t", "//tools/9z:t",
        "//src:t", "//src/tests/e2e/komira_x_e2e:t", "//src/tests/helpers/komira_y/sub:t", "//src/tests/e2e:t",
        "//src/tests:t", "//:t", "tests//functional/x:t",
    ]
    var declared = UnitTargets()
    for i in range(2):
        declared.names.append(String("u_") + String(i))
        declared.targets.append(String("//nothing:") + String(i))
    var d = derive(declared, labels)
    assert_true(len(d.names) > 0)
    for i in range(len(d.names)):
        assert_true(is_valid_name(d.names[i]), String("derived ") + d.names[i])


def test_the_pattern_grammar() raises:
    assert_true(is_pattern("//src/x/..."))
    assert_true(is_pattern("//:"))
    assert_true(is_pattern("tests//functional/..."))
    assert_false(is_pattern("//..."))  # the whole cell is matched as a label, never derived around
    assert_false(is_pattern("//src/x:x"))
    assert_false(is_pattern("src/x/..."))
    assert_true(matches("//src/x/...", "//src/x:x"))
    assert_true(matches("//src/x/...", "//src/x/sub:t"))
    assert_false(matches("//src/x/...", "//src/xy:t"))  # a shared prefix is not a package below it
    assert_true(matches("//:", "//:docs"))
    assert_false(matches("//:", "//src:docs"))  # `//:` is the root package only
    assert_true(matches("//src/y:", "//src/y:y"))
    assert_false(matches("//src/y:", "//src/y/z:y"))
    assert_false(matches("//functional/...", "tests//functional/a:t"))  # per cell
    assert_true(matches("tests//functional/...", "tests//functional/a:t"))
    assert_true(matches("//src/x:x", "//src/x:x"))
    assert_false(matches("//src/x:x", "//src/x:y"))


def main() raises:
    test_the_names()
    test_a_name_is_lowered_and_mangled_per_code_point()
    test_the_patterns()
    test_every_name_derived_from_the_table_is_one_kci_accepts()
    test_the_pattern_grammar()
    print("test_derive_naming: PASS")
