# =============================================================================
# src/kci_build/tests/test_runner_env.mojo
#   RunSpec's child environment: None (inherit) by default; `set_env` takes
#   exactly a list of NAME=value entries holding PATH and refuses anything
#   else; ScriptedRunner records it; SupervisorRunner refuses an explicit
#   environment that is empty before starting anything.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import RunSpec, ScriptedRunner, ScriptedStep, SupervisorRunner, check_child_env, env_entry_name


def _spec() -> RunSpec:
    var argv = List[String]()
    argv.append(String("--version"))
    return RunSpec(String("pixi"), argv^, String(""), 5, String("/dev/null"), String("/dev/null"))


def _entries(a: String, b: String = String("")) -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def _refusal(entries: List[String]) raises -> String:
    var s = _spec()
    try:
        s.set_env(entries.copy())
    except e:
        assert_false(Bool(s.env))
        return String(e)
    return String("<accepted>")


def test_default_is_inherit() raises:
    assert_false(Bool(_spec().env))


def test_set_env_is_exactly_the_list() raises:
    var s = _spec()
    s.set_env(_entries(String("PATH=/x"), String("HOME=/h")))
    assert_true(Bool(s.env))
    ref got = s.env.value()
    assert_equal(len(got), 2)
    assert_equal(got[0], String("PATH=/x"))
    assert_equal(got[1], String("HOME=/h"))
    # a value may hold `=` and may be empty
    s.set_env(_entries(String("PATH=/x"), String("OPT=a=b")))
    s.set_env(_entries(String("PATH=")))


def test_set_env_refusals() raises:
    assert_equal(
        _refusal(List[String]()),
        String("an explicit child environment is empty: it would inherit this process's environment"),
    )
    assert_equal(_refusal(_entries(String("HOME=/h"))), String("an explicit child environment holds no PATH"))
    assert_equal(_refusal(_entries(String("PATH=/x"), String("NOEQ"))), String("child environment entry 'NOEQ' is not NAME=value"))
    assert_equal(_refusal(_entries(String("PATH=/x"), String("=v"))), String("child environment entry '=v' is not NAME=value"))
    assert_equal(_refusal(_entries(String("PATH=/x"), String("1A=v"))), String("child environment entry '1A=v' is not NAME=value"))
    assert_equal(_refusal(_entries(String("PATH=/x"), String("A-B=v"))), String("child environment entry 'A-B=v' is not NAME=value"))
    assert_equal(_refusal(_entries(String("PATH=/x"), String("PATH=/y"))), String("the child environment sets 'PATH' twice"))
    assert_equal(env_entry_name(String("A=b=c")), String("A"))
    assert_equal(env_entry_name(String("A")), String(""))


def test_scripted_runner_records_the_env() raises:
    var runner = ScriptedRunner()
    var argv = List[String]()
    argv.append(String("--version"))
    runner.expect(ScriptedStep(argv^))
    var s = _spec()
    s.set_env(_entries(String("PATH=/x")))
    _ = runner.run(s)
    assert_equal(len(runner.calls), 1)
    assert_true(Bool(runner.calls[0].env))
    assert_equal(runner.calls[0].env.value()[0], String("PATH=/x"))


def test_supervisor_refuses_an_empty_explicit_env_before_starting() raises:
    var s = _spec()
    # the field is public: an empty list set directly is still refused
    s.env = List[String]()
    var runner = SupervisorRunner()
    try:
        _ = runner.run(s)
    except e:
        assert_equal(
            String(e), String("an explicit child environment is empty: it would inherit this process's environment")
        )
        return
    raise Error(String("an empty explicit environment was run"))


def test_check_child_env_accepts_a_minimal_list() raises:
    check_child_env(_entries(String("PATH=/usr/bin")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
