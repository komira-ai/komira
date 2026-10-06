from std.testing import assert_equal, assert_true, assert_false

from change_map.process import lines_of, quote, run_captured


def _sh(script: String) -> List[String]:
    var a = List[String]()
    a.append("-c")
    a.append(script)
    return a^


def test_streams_stay_apart_and_the_exit_code_is_kept() raises:
    var r = run_captured("/bin/sh", _sh("printf 'to out\\n'; printf 'to err\\n' >&2; exit 3"))
    assert_equal(r.stdout, "to out\n")
    assert_equal(r.stderr, "to err\n")
    assert_equal(r.exit_code, 3)
    assert_false(r.ok())


def test_success() raises:
    var r = run_captured("/bin/sh", _sh("exit 0"))
    assert_true(r.ok())


def test_a_flood_on_stderr_does_not_stall_stdout() raises:
    var r = run_captured("/bin/sh", _sh("i=0; while [ $i -lt 4000 ]; do echo 'e e e e e e e e e e e e e e e e e e e e' >&2; i=$((i+1)); done; echo done"))
    assert_equal(r.stdout, "done\n")
    assert_true(r.stderr.byte_length() > 100000)


def test_a_program_that_is_not_there_does_not_pass() raises:
    var r = run_captured("/no/such/program", List[String]())
    assert_false(r.ok())
    assert_equal(r.exit_code, 127)


def test_arguments_are_never_shell_syntax() raises:
    var a = List[String]()
    a.append("a b; echo injected")
    a.append("it's")
    var r = run_captured("/bin/echo", a)
    assert_equal(r.stdout, "a b; echo injected it's\n")


def test_quote() raises:
    assert_equal(quote("a'b"), "'a'\\''b'")
    assert_equal(quote(""), "''")


def test_lines() raises:
    var l = lines_of("a\n\nb\r\nc")
    assert_equal(len(l), 3)
    assert_equal(l[1], "b")


def main() raises:
    test_streams_stay_apart_and_the_exit_code_is_kept()
    test_success()
    test_a_flood_on_stderr_does_not_stall_stdout()
    test_a_program_that_is_not_there_does_not_pass()
    test_arguments_are_never_shell_syntax()
    test_quote()
    test_lines()
    print("test_process: PASS")
