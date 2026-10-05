from std.testing import assert_equal, assert_true, assert_false

from change_map.plan import KIND_AFFECTED, KIND_VACUOUS, KIND_WIDENED, Verdict
from change_map.report import json_string, one_line, render_json, render_seconds, render_summary, render_targets, render_units_answer
from change_map.units import affected_units, parse_units_file


def _list(*items: String) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i])
    return out^


def _verdict(kind: String, reason: String, targets: List[String]) -> Verdict:
    return Verdict(kind, reason, targets.copy(), 3, 2, _list("a warning"))


def test_units_reached() raises:
    var u = parse_units_file(
        "enc\t//src/komira_encoding:komira_encoding_conda\nenc\t//src/komira_encoding:docs\n"
        + "lints\t//:docs\nlints\t//:shell_lint\nall\t//release:komira_all\n"
    )
    var hit = affected_units(u, _list("//:shell_lint", "//src/komira_encoding:docs"), "komira")
    assert_equal(len(hit), 2)
    assert_equal(hit[0], "enc")  # in the units file's order, once each
    assert_equal(hit[1], "lints")
    assert_equal(len(affected_units(u, _list("//elsewhere:x"), "komira")), 0)


def test_a_unit_target_with_a_subtarget_or_the_cell_name_matches() raises:
    var u = parse_units_file("enc\tkomira//src/x:x_conda[release]\n")
    assert_equal(len(affected_units(u, _list("//src/x:x_conda"), "komira")), 1)


def test_a_package_pattern_names_the_targets_it_matches() raises:
    # the derived checks of the release template are patterns, not labels
    var u = parse_units_file(
        "pkg\t//src/x/...\nroot\t//:\nfn\ttests//functional/...\nlone\t//src/y:\nall_tests\ttests//...\n"
    )
    var got = affected_units(u, _list("//src/x/sub/deep:t"), "komira")
    assert_equal(len(got), 1)
    assert_equal(got[0], "pkg")  # the package and everything below it
    assert_equal(len(affected_units(u, _list("//src/x:x"), "komira")), 1)
    assert_equal(len(affected_units(u, _list("//src/xy:x"), "komira")), 0)  # a prefix of a name is not a package below it
    assert_equal(affected_units(u, _list("//:docs"), "komira")[0], "root")
    assert_equal(len(affected_units(u, _list("//src:docs"), "komira")), 0)  # `//:` is the root package only
    assert_equal(affected_units(u, _list("//src/y:y"), "komira")[0], "lone")
    assert_equal(len(affected_units(u, _list("//src/y/z:y"), "komira")), 0)  # `//src/y:` is one package
    var f = affected_units(u, _list("tests//functional/a:t"), "komira")
    assert_equal(len(f), 2)  # a pattern is per cell: the tests cell's, not the root's
    assert_equal(f[0], "fn")
    assert_equal(f[1], "all_tests")
    assert_equal(len(affected_units(u, _list("//functional/a:t"), "komira")), 0)
    assert_equal(len(affected_units(parse_units_file("everything\tkomira//...\n"), _list("//a/b:c"), "komira")), 1)


def test_a_units_file_it_cannot_read_is_an_error() raises:
    var bad = List[String]()
    bad.append("enc only-one-field\n")
    bad.append("\n")
    bad.append("enc\t\n")
    bad.append("a\tb\tc\n")
    for i in range(len(bad)):
        var failed = False
        try:
            _ = parse_units_file(bad[i])
        except:
            failed = True
        assert_true(failed)


def test_the_protocol_answer() raises:
    var v = _verdict(KIND_AFFECTED, "", _list("//a:a"))
    assert_equal(render_units_answer(v, _list("enc", "lints")), "UNIT enc\nUNIT lints\nAFFECTED 2\n")
    assert_equal(render_units_answer(v, List[String]()), "AFFECTED 0\n")
    var w = _verdict(KIND_WIDENED, "one\ntwo", _list("//a:a"))
    assert_equal(render_units_answer(w, _list("enc")), "WIDENED one two\n")


def test_text() raises:
    var v = _verdict(KIND_AFFECTED, "", _list("//a:a", "//b:b"))
    assert_equal(render_targets(v), "//a:a\n//b:b\n")
    assert_equal(render_targets(_verdict(KIND_VACUOUS, "x", List[String]())), "")
    assert_equal(render_seconds(5), "0.005s")
    assert_equal(render_seconds(312), "0.312s")
    assert_equal(render_seconds(12034), "12.034s")
    assert_equal(
        render_summary(v, 312),
        "affected: AFFECTED: 2 target(s) from 3 file(s), 2 seed(s), 0.312s",
    )
    assert_true(render_summary(_verdict(KIND_WIDENED, "why", List[String]()), 1).endswith(" -- why"))


def test_json() raises:
    assert_equal(json_string("a\"b\\c\nd\te"), "\"a\\\"b\\\\c\\nd\\te\"")
    assert_equal(json_string("café"), "\"café\"")
    assert_equal(one_line("a\r\nb"), "a  b")
    var v = _verdict(KIND_WIDENED, "r", _list("//a:a"))
    assert_equal(
        render_json(v, 7),
        '{"verdict":"WIDENED","reason":"r","widened":true,"files":3,"seeds":2,"milliseconds":7,'
        + '"warnings":["a warning"],"targets":["//a:a"]}\n',
    )
    assert_true(render_json(_verdict(KIND_AFFECTED, "", _list("//a:a")), 7).find('"widened":false') >= 0)


def main() raises:
    test_units_reached()
    test_a_unit_target_with_a_subtarget_or_the_cell_name_matches()
    test_a_package_pattern_names_the_targets_it_matches()
    test_a_units_file_it_cannot_read_is_an_error()
    test_the_protocol_answer()
    test_text()
    test_json()
    print("test_units_and_report: PASS")
