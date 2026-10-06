# Exits with the status its one argument names: 77 in the `skip_77` fixture,
# "skipped" to automake and some test harnesses. Under `buck2 test` that must
# be a failure (exit 77), never a skip or a pass.
from std.sys import argv, exit


def main() raises:
    var raw = argv()
    if len(raw) != 2:
        raise Error("test_exit_77: expected one argument, the exit status")
    var a = String(raw[1])
    if a != "--exit=77":
        raise Error("test_exit_77: unexpected argument " + a)
    print("test_exit_77: exiting 77 (SKIP to some harnesses)")
    exit(77)
