"""derive_checks: the derived checks, the `derive_checks` command of the buck2
build system in release/artifacts.textproto.

    derive_checks <units file>        what kci runs: `<unit>\\t<target>` lines
    derive_checks --from <artifacts>  the same answer from a textproto
                                      artifacts file, for a reader
      --buck2 <path>                  the buck2 to ask (default: `buck2`,
                                      found on PATH)

Run it from the repository root (`./buck2 run //tools/build/ci:derive_checks
-- ...`). What it answers on stdout, and the derivation, are
change_map/derive.mojo's header; stderr gets buck2's own error when the query
fails, and one summary line.

Exit: 0 for every answer (CHECK lines and DERIVED, or BROKEN: kci reads the
answer, not the exit); 1 the answer could not be made (an unreadable units
file, an empty universe, a group or a name the derivation must never give);
2 bad usage.
"""

from std.io import FileDescriptor
from std.sys import argv, exit

from buildtools.bytes import read_file, to_string

from change_map.derive import answer_query, query_universe, read_artifacts_text, universe_labels
from change_map.units import UnitTargets, parse_units_file

comptime _STDERR: FileDescriptor = FileDescriptor(2)


def _say(line: String):
    print(line, file=_STDERR)


def _usage(why: String):
    _say(String("derive_checks: ") + why)
    _say(String("usage: derive_checks (<units file> | --from <artifacts.textproto>) [--buck2 <path>]"))
    exit(2)


def _run() raises:
    var args = argv()
    var units_path = String("")
    var artifacts_path = String("")
    var buck2 = String("buck2")
    var i = 1
    while i < len(args):
        var a = String(args[i])
        if a == String("--from") or a == String("--buck2"):
            if i + 1 >= len(args):
                _usage(String("'") + a + String("' needs a value"))
            if a == String("--from"):
                artifacts_path = String(args[i + 1])
            else:
                buck2 = String(args[i + 1])
            i += 2
            continue
        if a.startswith(String("-")) or units_path.byte_length() > 0:
            _usage(String("unexpected argument '") + a + String("'"))
        units_path = a
        i += 1
    if (units_path.byte_length() > 0) == (artifacts_path.byte_length() > 0):
        _usage(String("give one of a units file and --from"))
    var declared = UnitTargets()
    if units_path.byte_length() > 0:
        declared = parse_units_file(to_string(read_file(units_path)))
    else:
        declared = read_artifacts_text(to_string(read_file(artifacts_path)))
    var query = query_universe(buck2)
    var answer = answer_query(declared, query)
    print(answer, end="")
    if not query.ok():
        # Any failure of the query, whatever buck2 printed: the check fails.
        _say(query.stderr)
        _say(String("derive_checks: BROKEN: the universe query failed"))
        return
    var checks = 0
    var unmatched = 0
    var lines = answer.split(String("\n"))
    for k in range(len(lines)):
        if String(lines[k]).startswith(String("UNMATCHED ")):
            unmatched += 1
        elif String(lines[k]).startswith(String("DERIVED ")):
            checks = Int(String(lines[k])[byte=8:])
    _say(
        String("derive_checks: ") + String(len(universe_labels(query.stdout))) + String(" targets, ")
        + String(len(declared.targets)) + String(" declared target(s), ") + String(checks)
        + String(" derived check(s), ") + String(unmatched) + String(" unmatched")
    )


def main():
    try:
        _run()
    except e:
        _say(String("derive_checks: ") + String(e))
        exit(1)
