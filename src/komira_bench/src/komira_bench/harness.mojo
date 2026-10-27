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
# output has one format to read. `<value>` is the measured number, or `-` when
# the program was asked to hide its times (`--hide-times`): the shape of the
# output is then the same on every machine, which is what a smoke run compares.
#
# The command line is `--total-ops=N`, `--caps=A,B,...`, `--hide-times` and
# `--help`; `parse_args` reads it, and refuses anything else by name instead of
# running a benchmark with settings the user did not mean.
# =============================================================================

from std.sys import argv


struct Param(Copyable, Movable):
    """One `<name>=<int>` parameter of a measurement line."""

    var name: String
    var value: Int

    def __init__(out self, name: String, value: Int):
        self.name = name
        self.value = value


def result_line(
    op: String,
    params: List[Param],
    metric: String,
    value: Float64,
    hide_times: Bool = False,
) -> String:
    """The `RESULT` line of one measurement; `value` prints as `-` when hidden."""
    var line = String("RESULT ") + op
    for i in range(len(params)):
        line += " " + params[i].name + "=" + String(params[i].value)
    line += " " + metric + "="
    if hide_times:
        line += "-"
    else:
        line += String(value)
    return line


struct BenchArgs(Copyable, Movable):
    """The settings every benchmark program takes from its command line."""

    var total_ops: Int
    var caps: List[Int]
    var hide_times: Bool
    var help: Bool

    def __init__(out self, total_ops: Int, var caps: List[Int]):
        self.total_ops = total_ops
        self.caps = caps^
        self.hide_times = False
        self.help = False


def _positive_int(flag: String, text: String) raises -> Int:
    var n = 0
    var ok = True
    try:
        n = atol(text)
    except:
        ok = False
    if not ok or n <= 0:
        raise Error(
            "komira_bench: "
            + flag
            + " must be a positive integer, got '"
            + text
            + "'"
        )
    return n


def _value_of(arg: String, prefix: String) -> String:
    return String(arg[byte = prefix.byte_length() : arg.byte_length()])


def parse_args(
    args: List[String], default_total_ops: Int, default_caps: List[Int]
) raises -> BenchArgs:
    """Read the command line (without the program name); an argument that is
    not one of the four flags, or a bad number, raises naming it. A flag given
    twice keeps its last value."""
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
        + "  --caps=A,B,...  ring capacities to measure (default "
        + caps
        + ")\n"
        + "  --hide-times    print `-` for every measured value, so the output"
        + " is the same on every machine\n"
        + "  --help          this text"
    )


def without_program(all: List[String]) -> List[String]:
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
    return without_program(all)
