# =============================================================================
# src/kci_build/tests/test_build_publishable_list.mojo
#   The publishable list: what parses, every refusal by line, and --only.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_build import label_problem, parse_publishable, select_publishable

comptime _SRC = "release/publishable.txt"


def _refusal(text: String) -> String:
    try:
        _ = parse_publishable(text, String(_SRC))
    except e:
        return String(e)
    return String("<parsed>")


def test_control_comments_blanks_and_tabs() raises:
    var e = parse_publishable(
        String("# packages\n\nCONDA //src/a:a_conda\n  CONDA\t//src/b:b_conda  \n"),
        String(_SRC),
    )
    assert_equal(len(e), 2)
    assert_equal(e[0].artifact_type, String("CONDA"))
    assert_equal(e[0].target, String("//src/a:a_conda"))
    assert_equal(e[0].line, 3)
    assert_equal(e[1].target, String("//src/b:b_conda"))
    assert_equal(e[1].line, 4)


def test_refusals_name_the_file_and_line() raises:
    assert_equal(
        _refusal(String("CONDA\n")),
        String("publishable list 'release/publishable.txt': line 1: expected '<artifact_type> <target>', got 1 fields"),
    )
    assert_equal(
        _refusal(String("# x\nCONDA //a:b extra\n")),
        String("publishable list 'release/publishable.txt': line 2: expected '<artifact_type> <target>', got 3 fields"),
    )
    assert_equal(
        _refusal(String("RPM //a:b\n")),
        String("publishable list 'release/publishable.txt': line 1: unknown artifact type 'RPM'"),
    )
    assert_equal(
        _refusal(String("OCI //a:b\n")),
        String("publishable list 'release/publishable.txt': line 1: kci build does not build OCI artifacts yet (CONDA only)"),
    )
    assert_equal(
        _refusal(String("CONDA //a:b\n\nCONDA //a:b\n")),
        String("publishable list 'release/publishable.txt': line 3: target '//a:b' is already listed on line 1"),
    )
    assert_equal(
        _refusal(String("CONDA cell//a:b\n")),
        String("publishable list 'release/publishable.txt': line 1: target 'cell//a:b' must start with '//' (no cell prefix)"),
    )


def test_an_empty_list_is_refused_not_read_as_nothing() raises:
    var want = String(
        "publishable list 'release/publishable.txt' lists no targets: an empty list is refused, never read as nothing to build"
    )
    assert_equal(_refusal(String("")), want)
    assert_equal(_refusal(String("# only a comment\n\n")), want)


def test_label_problems() raises:
    assert_equal(label_problem(String("//src/a:b")), String(""))
    assert_equal(label_problem(String("//src/...")), String("is a pattern, not one target"))
    assert_equal(label_problem(String("//a:b[manifest]")), String("names a sub-target; list the target itself"))
    assert_equal(label_problem(String("//a")), String("must have exactly one ':'"))
    assert_equal(label_problem(String("//a:b:c")), String("must have exactly one ':'"))
    assert_equal(label_problem(String("//a:")), String("has no target name after ':'"))
    assert_equal(label_problem(String("a:b")), String("must start with '//' (no cell prefix)"))


def test_only_narrows_in_list_order_and_refuses_unlisted() raises:
    var e = parse_publishable(
        String("CONDA //a:one\nCONDA //a:two\nCONDA //a:three\n"), String(_SRC)
    )
    var all = select_publishable(e, List[String](), String(_SRC))
    assert_equal(len(all), 3)
    var only = List[String]()
    only.append(String("//a:three"))
    only.append(String("//a:one"))
    var some = select_publishable(e, only, String(_SRC))
    assert_equal(len(some), 2)
    assert_equal(some[0].target, String("//a:one"))
    assert_equal(some[1].target, String("//a:three"))
    var bad = List[String]()
    bad.append(String("//a:four"))
    var msg = String("")
    try:
        _ = select_publishable(e, bad, String(_SRC))
    except err:
        msg = String(err)
    assert_equal(msg, String("--only //a:four is not on the publishable list 'release/publishable.txt'"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
