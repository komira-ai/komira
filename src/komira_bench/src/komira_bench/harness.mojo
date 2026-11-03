# =============================================================================
# harness.mojo -- what every komira benchmark program shares
# =============================================================================
#
# A benchmark program prints one line per measurement:
#
#   RESULT <op> [<name>=<int> ...] <metric>=<value>
#
# for example `RESULT push_pop cap=1024 ns_per_op=11.25`. `result_line` is the
# only place that spells it, so the programs agree and a script that reads the
# output has one format to read. `<op>`, each `<name>` and `<metric>` are tokens:
# one or more of `a`-`z`, `0`-`9` and `_`, so no space, `=` or line break can
# change the shape of the line; a parameter name appears at most once. `<value>`
# is the measured number, which must be finite, or `-` when the program was
# asked to hide its times (`--hide-times`): the shape of the output is then the
# same on every machine, which is what a smoke run compares. A line that would
# break these rules is refused with an error naming what is wrong.
#
# The command line is `--total-ops=N`, `--caps=A,B,...`, `--hide-times` and
# `--help` (or `-h`); `parse_args` reads it, and refuses anything else by name
# instead of running a benchmark with settings the user did not mean. A number
# is decimal digits only (no sign, no space), at least 1 and at most
# 9223372036854775807. Every argument is checked, in order, and the first one
# refused is the error, whether or not `--help` is also given; a flag given
# twice keeps its last value, and both values must be valid.
# =============================================================================

from std.math import isfinite
from std.sys import argv


comptime _INT_MAX = Int(Int64.MAX)


struct Param(Copyable, Movable):
    """One `<name>=<int>` parameter of a measurement line."""

    var name: String
    var value: Int

    def __init__(out self, name: String, value: Int):
        self.name = name
        self.value = value


def _is_token(text: String) -> Bool:
    var b = text.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("_")
        )
        if not ok:
            return False
    return True


def _check_token(what: String, text: String) raises:
    if not _is_token(text):
        raise Error(
            "komira_bench: a RESULT "
            + what
            + " is one or more of a-z, 0-9 and _, got '"
            + text
            + "'"
        )


def result_line(
    op: String,
    params: List[Param],
    metric: String,
    value: Float64,
    hide_times: Bool = False,
) raises -> String:
    """The `RESULT` line of one measurement; `value` prints as `-` when hidden.

    Raises when `op`, a parameter name or `metric` is not a token (one or more
    of `a`-`z`, `0`-`9`, `_`), when a parameter name is given twice, or when a
    shown `value` is not finite."""
    _check_token("op", op)
    var line = String("RESULT ") + op
    for i in range(len(params)):
        _check_token("parameter name", params[i].name)
        for j in range(i):
            if params[j].name == params[i].name:
                raise Error(
                    "komira_bench: the RESULT parameter '"
                    + params[i].name
                    + "' is given twice"
                )
        line += " " + params[i].name + "=" + String(params[i].value)
    _check_token("metric", metric)
    line += " " + metric + "="
    if hide_times:
        line += "-"
    else:
        if not isfinite(value):
            raise Error(
                "komira_bench: the RESULT value of '"
                + metric
                + "' is not a finite number"
            )
        line += String(value)
    return line


struct BenchArgs(Copyable, Movable):
    """The settings every benchmark program takes from its command line."""

    var total_ops: Int
    var caps: List[Int]
    var hide_times: Bool
    var help: Bool

    def __init__(out self, total_ops: Int, var caps: List[Int]) raises:
        """Raises unless `total_ops` is at least 1 and `caps` is a non-empty
        list of numbers that are each at least 1."""
        if total_ops <= 0:
            raise Error(
                "komira_bench: total_ops must be at least 1, got "
                + String(total_ops)
            )
        if len(caps) == 0:
            raise Error("komira_bench: caps must name at least one capacity")
        for i in range(len(caps)):
            if caps[i] <= 0:
                raise Error(
                    "komira_bench: a capacity must be at least 1, got "
                    + String(caps[i])
                )
        self.total_ops = total_ops
        self.caps = caps^
        self.hide_times = False
        self.help = False


def _positive_int(flag: String, text: String) raises -> Int:
    var b = text.as_bytes()
    var n = 0
    var ok = len(b) > 0
    for i in range(len(b)):
        var d = Int(b[i]) - ord("0")
        if d < 0 or d > 9 or n > (_INT_MAX - d) // 10:
            ok = False
            break
        n = n * 10 + d
    if not ok or n == 0:
        raise Error(
            "komira_bench: "
            + flag
            + " must be a positive integer (decimal digits, at most "
            + String(_INT_MAX)
            + "), got '"
            + text
            + "'"
        )
    return n


def _value_of(arg: String, prefix: String) -> String:
    return String(arg[byte = prefix.byte_length() : arg.byte_length()])


def parse_args(
    args: List[String], default_total_ops: Int, default_caps: List[Int]
) raises -> BenchArgs:
    """Read the command line (without the program name) over the program's
    defaults. Every argument is checked in order and the first that is not one
    of the four flags, or holds a bad number, raises naming it, `--help` or
    not. A flag given twice keeps its last value. Raises too when the defaults
    themselves are not valid settings (`BenchArgs`). The result owns its list
    of capacities: `default_caps` is copied, never shared."""
    var out = BenchArgs(default_total_ops, default_caps.copy())
    for i in range(len(args)):
        var a = args[i]
        if a == "--help" or a == "-h":
            out.help = True
        elif a == "--hide-times":
            out.hide_times = True
        elif a.startswith("--total-ops="):
            out.total_ops = _positive_int(
                "--total-ops", _value_of(a, "--total-ops=")
            )
        elif a.startswith("--caps="):
            var caps = List[Int]()
            var pieces = _value_of(a, "--caps=").split(",")
            for k in range(len(pieces)):
                caps.append(_positive_int("--caps", String(pieces[k])))
            out.caps = caps^
        else:
            raise Error(
                "komira_bench: unknown argument '" + a + "' (try --help)"
            )
    return out^


def usage(
    program: String, default_total_ops: Int, default_caps: List[Int]
) -> String:
    """The text `--help` prints, with the defaults the program runs with."""
    var caps = String()
    for i in range(len(default_caps)):
        if i > 0:
            caps += ","
        caps += String(default_caps[i])
    return (
        "usage: "
        + program
        + " [--total-ops=N] [--caps=A,B,...] [--hide-times] [--help]\n"
        + "  --total-ops=N   operations per measurement (default "
        + String(default_total_ops)
        + ")\n"
        + "  --caps=A,B,...  capacities to measure (default "
        + caps
        + ")\n"
        + "  --hide-times    print `-` for every measured value, so the output"
        + " is the same on every machine\n"
        + "  --help, -h      this text"
    )


def _without_program(all: List[String]) -> List[String]:
    """`all` without its first element, the program name (empty stays empty)."""
    var out = List[String]()
    for k in range(1, len(all)):
        out.append(all[k])
    return out^


def command_line() -> List[String]:
    """The process's arguments without the program name."""
    var all = List[String]()
    var raw = argv()
    for k in range(len(raw)):
        all.append(String(raw[k]))
    return _without_program(all)
