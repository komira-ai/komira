# =============================================================================
# src/kci_build/tests/test_build_flags.mojo
#   Every `kci build` flag in both spellings, every refusal naming its flag,
#   and every flag the buck2-specific verb had now refused as unknown.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import BUILD_USAGE, DEFAULT_BUILD_TIMEOUT_S, parse_build_flags


def _args(*items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(String(s))
    return l^


def _full() -> List[String]:
    return _args(
        "--declarations", "release/decls.textproto",
        "--work-dir", "/work/repo",
        "--out-dir", "out",
        "--log-dir", "logs",
    )


def _refusal(args: List[String]) -> String:
    try:
        _ = parse_build_flags(args)
    except e:
        return String(e)
    return String("<parsed>")


def _expect(args: List[String], why: String) raises:
    assert_equal(_refusal(args), String("kci build: ") + why + String("\n") + String(BUILD_USAGE))


def test_every_flag_space_spelling() raises:
    var a = _full()
    a.append(String("--build-timeout-s"))
    a.append(String("120"))
    var f = parse_build_flags(a)
    assert_false(f.help)
    assert_equal(f.request.declarations_file, String("release/decls.textproto"))
    assert_equal(f.request.work_dir, String("/work/repo"))
    assert_equal(f.request.out_dir, String("out"))
    assert_equal(f.request.log_dir, String("logs"))
    assert_equal(f.request.build_timeout_s, 120)


def test_every_flag_equals_spelling() raises:
    var f = parse_build_flags(
        _args(
            "--declarations=d.textproto",
            "--work-dir=/w",
            "--out-dir=/o",
            "--log-dir=/l",
            "--build-timeout-s=7",
        )
    )
    assert_equal(f.request.declarations_file, String("d.textproto"))
    assert_equal(f.request.work_dir, String("/w"))
    assert_equal(f.request.out_dir, String("/o"))
    assert_equal(f.request.log_dir, String("/l"))
    assert_equal(f.request.build_timeout_s, 7)


def test_timeout_default() raises:
    assert_equal(parse_build_flags(_full()).request.build_timeout_s, DEFAULT_BUILD_TIMEOUT_S)
    assert_equal(DEFAULT_BUILD_TIMEOUT_S, 3600)


def test_help() raises:
    assert_true(parse_build_flags(_args("--help")).help)


def _without(flag: String) -> List[String]:
    var full = _full()
    var out = List[String]()
    var i = 0
    while i < len(full):
        if full[i] == flag:
            i += 2
            continue
        out.append(full[i].copy())
        i += 1
    return out^


def test_each_required_flag() raises:
    for f in ["--declarations", "--work-dir", "--out-dir", "--log-dir"]:
        _expect(_without(String(f)), String(f) + String(" is required"))


def test_each_flag_given_twice() raises:
    for f in ["--declarations", "--work-dir", "--out-dir", "--log-dir", "--build-timeout-s"]:
        var a = _full()
        a.append(String(f) + String("=/x1"))
        a.append(String(f) + String("=/x2"))
        if String(f) == "--build-timeout-s":
            a = _full()
            a.append(String("--build-timeout-s=1"))
            a.append(String("--build-timeout-s=2"))
        _expect(a, String(f) + String(" is given twice"))


def test_each_flag_with_an_empty_value() raises:
    for f in ["--declarations", "--work-dir", "--out-dir", "--log-dir", "--build-timeout-s"]:
        _expect(_args(String(f) + String("=")), String(f) + String(" has an EMPTY value"))
        _expect(_args(String(f), String("  ")), String(f) + String(" has an EMPTY value"))


def test_each_flag_with_no_value() raises:
    for f in ["--declarations", "--work-dir", "--out-dir", "--log-dir", "--build-timeout-s"]:
        _expect(_args(String(f)), String(f) + String(" needs a value"))


def test_positional_argument() raises:
    _expect(_args("//src/x:y"), String("unexpected argument '//src/x:y'"))


def test_work_dir_must_be_absolute() raises:
    var a = _without(String("--work-dir"))
    a.append(String("--work-dir"))
    a.append(String("repo"))
    _expect(
        a,
        String("--work-dir 'repo' is not an absolute path: it is the cwd every build resolves against"),
    )


def test_timeout_must_be_a_positive_integer() raises:
    for v in ["0", "-1", "1.5", "x", "1234567890"]:
        var a = _full()
        a.append(String("--build-timeout-s=") + String(v))
        _expect(
            a,
            String("--build-timeout-s must be a positive whole number of seconds; got '")
            + String(v) + String("'"),
        )


def test_every_deleted_flag_is_unknown() raises:
    for f in [
        "--buck2", "--repo-root", "--publishable", "--only", "--buck2-config",
        "--target-platforms", "--probe-target", "--probe-timeout-s",
    ]:
        var a = _full()
        a.append(String(f) + String("=x"))
        _expect(a, String("unknown flag '") + String(f) + String("'"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
