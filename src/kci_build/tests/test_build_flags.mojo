# =============================================================================
# src/kci_build/tests/test_build_flags.mojo
#   `kci build` flags: both spellings, defaults, and each refusal.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import BUILD_USAGE, parse_build_flags


def _base() -> List[String]:
    var a = List[String]()
    a.append(String("--buck2"))
    a.append(String("/opt/buck2"))
    a.append(String("--repo-root=/repo"))
    a.append(String("--publishable"))
    a.append(String("release/publishable.txt"))
    a.append(String("--probe-target"))
    a.append(String("//tools/build/kci:farm_probe"))
    a.append(String("--out-dir=out"))
    a.append(String("--log-dir"))
    a.append(String("logs"))
    return a^


def _with(var extra: List[String]) -> List[String]:
    var a = _base()
    a.extend(extra^)
    return a^


def _one(s: String) -> List[String]:
    var l = List[String]()
    l.append(s)
    return l^


def _refusal(args: List[String]) raises -> String:
    try:
        _ = parse_build_flags(args)
    except e:
        var s = String(e)
        var nl = s.find(String("\n"))
        assert_true(nl > 0)
        assert_equal(String(s[byte = nl + 1 :]), String(BUILD_USAGE))
        return String(s[byte = :nl])
    return String("<parsed>")


def test_control_required_flags_and_defaults() raises:
    var f = parse_build_flags(_base())
    assert_false(f.help)
    ref r = f.request
    assert_equal(r.buck2_path, String("/opt/buck2"))
    assert_equal(r.repo_root, String("/repo"))
    assert_equal(r.publishable_file, String("release/publishable.txt"))
    assert_equal(r.probe_target, String("//tools/build/kci:farm_probe"))
    assert_equal(r.out_dir, String("out"))
    assert_equal(r.log_dir, String("logs"))
    assert_equal(r.probe_timeout_s, 120)
    assert_equal(r.build_timeout_s, 3600)
    assert_equal(len(r.only), 0)
    assert_equal(len(r.buck2_config), 0)
    assert_equal(r.target_platforms, String(""))


def test_optional_and_repeatable_flags() raises:
    var x = List[String]()
    x.append(String("--only=//a:one"))
    x.append(String("--only"))
    x.append(String("//a:two"))
    x.append(String("--buck2-config"))
    x.append(String("build.jobs=8"))
    x.append(String("--buck2-config=komira_re.linux_properties=pool=x"))
    x.append(String("--target-platforms=//p:linux"))
    x.append(String("--probe-timeout-s=30"))
    x.append(String("--build-timeout-s"))
    x.append(String("900"))
    var f = parse_build_flags(_with(x^))
    ref r = f.request
    assert_equal(len(r.only), 2)
    assert_equal(r.only[1], String("//a:two"))
    assert_equal(len(r.buck2_config), 2)
    assert_equal(r.buck2_config[1], String("komira_re.linux_properties=pool=x"))
    assert_equal(r.target_platforms, String("//p:linux"))
    assert_equal(r.probe_timeout_s, 30)
    assert_equal(r.build_timeout_s, 900)


def test_help_stops_parsing() raises:
    var a = _one(String("--help"))
    a.append(String("--nonsense"))
    assert_true(parse_build_flags(a).help)


def test_each_required_flag_is_named_when_missing() raises:
    var names = List[String]()
    names.append(String("--buck2"))
    names.append(String("--repo-root"))
    names.append(String("--publishable"))
    names.append(String("--probe-target"))
    names.append(String("--out-dir"))
    names.append(String("--log-dir"))
    for n in range(len(names)):
        var a = List[String]()
        var b = _base()
        var i = 0
        while i < len(b):
            if b[i] == names[n]:
                i += 2
                continue
            if b[i].startswith(names[n] + String("=")):
                i += 1
                continue
            a.append(b[i].copy())
            i += 1
        assert_equal(_refusal(a), String("kci build: ") + names[n] + String(" is required"))


def test_refusals() raises:
    assert_equal(_refusal(_with(_one(String("--log-dir=again")))), String("kci build: --log-dir is given twice"))
    assert_equal(_refusal(_with(_one(String("--color=always")))), String("kci build: unknown flag '--color'"))
    assert_equal(_refusal(_with(_one(String("stray")))), String("kci build: unexpected argument 'stray'"))
    assert_equal(_refusal(_with(_one(String("--only")))), String("kci build: --only needs a value"))
    assert_equal(_refusal(_with(_one(String("--only= ")))), String("kci build: --only has an EMPTY value"))
    assert_equal(
        _refusal(_with(_one(String("--only=//a/...")))),
        String("kci build: --only '//a/...' is a pattern, not one target"),
    )
    var twice = List[String]()
    twice.append(String("--only=//a:b"))
    twice.append(String("--only=//a:b"))
    assert_equal(_refusal(_with(twice^)), String("kci build: --only //a:b is given twice"))
    assert_equal(
        _refusal(_with(_one(String("--buck2-config=nokey")))),
        String("kci build: --buck2-config 'nokey' is not key=value"),
    )
    assert_equal(
        _refusal(_with(_one(String("--buck2-config=komira.execution=local")))),
        String("kci build: --buck2-config may not set komira.execution: kci build always builds on the farm"),
    )
    assert_equal(
        _refusal(_with(_one(String("--buck2-config=kci.probe_nonce=1")))),
        String("kci build: --buck2-config may not set kci.probe_nonce: kci build sets it"),
    )
    var bads = List[String]()
    bads.append(String("0"))
    bads.append(String("-5"))
    bads.append(String("1.5"))
    bads.append(String("9999999999"))
    for i in range(len(bads)):
        assert_equal(
            _refusal(_with(_one(String("--build-timeout-s=") + bads[i]))),
            String("kci build: --build-timeout-s must be a positive whole number of seconds; got '")
            + bads[i]
            + String("'"),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
