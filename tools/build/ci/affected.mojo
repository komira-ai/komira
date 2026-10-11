"""affected: the targets a change affects.

    affected --base <rev>          the change is `git diff <rev>...HEAD`
    affected --files <file>        the change is the paths in <file>, NUL- or
                                   newline-separated (git diff -z output); with
                                   --base too, <rev> is the tree a deleted file's
                                   package is read from
      --units-file <file>          answer in kci's protocol: the units of the
                                   file (`<unit>\\t<target>` lines) the change
                                   reaches, then `AFFECTED <n>`, `WIDENED <why>`
                                   or `BROKEN <why>`
      --coverage                   instead of a change: the targets no unit of
                                   --units-file builds or depends on (exit 12
                                   when there is one)
      --json                       one JSON object instead of a label per line
      --rules <file>               the widening rules (tools/build/ci/rules.txt)
      --buckconfig <file>          the cell table (.buckconfig)
      --buck2 <path>               the buck2 to ask (./buck2)
      --isolation-dir <name>       asked of buck2 under that isolation dir
      --buck2-arg <arg>            one more argument before buck2's subcommand

Run it from the repository root. Prints one target label per line (root-cell
labels as `//pkg:name`) and, on stderr, the warnings and one summary line.

Exit: 0 the affected targets (or an empty change: nothing printed); 10 WIDENED,
every target printed and the reason on stderr; 11 VACUOUS, a change whose files
reach no target; 12 --coverage found a target no unit covers; 13 BROKEN, a
query of the graph failed (buck2's error on stderr, after the target it names
when it names one; nothing printed): never a widening; 2 bad usage; 5 cannot
tell (git diff, or the listing of a widened answer's targets, failed). With
--units-file the exit is 0 for every answer it can give: kci reads the last
stdout line.
"""

from std.io import FileDescriptor
from std.sys import argv, exit
from std.time import perf_counter_ns

from buildtools.bytes import read_file, to_string

from change_map.cells import read_cells
from change_map.graph import BuckGraph
from change_map.labels import normalize_label
from change_map.plan import KIND_AFFECTED, KIND_BROKEN, KIND_EMPTY, KIND_VACUOUS, KIND_WIDENED, compute, uncovered
from change_map.process import run_captured
from change_map.report import render_json, render_seconds, render_summary, render_targets, render_units_answer
from change_map.rules import read_rules
from change_map.units import UnitTargets, affected_units, parse_units_file

comptime _STDERR: FileDescriptor = FileDescriptor(2)
comptime EXIT_WIDENED: Int = 10
comptime EXIT_VACUOUS: Int = 11
comptime EXIT_UNCOVERED: Int = 12
comptime EXIT_BROKEN: Int = 13
comptime EXIT_USAGE: Int = 2
comptime EXIT_CANNOT_TELL: Int = 5


def _say(line: String):
    print(line, file=_STDERR)


def _usage(why: String):
    _say(String("affected: ") + why)
    _say(String("usage: affected (--base <rev> | --files <file> [--base <rev>]) [--units-file <file>] [--json] [--rules <file>]"))
    _say(String("                [--buckconfig <file>] [--buck2 <path>] [--isolation-dir <name>] [--buck2-arg <arg>]"))
    exit(EXIT_USAGE)


def _paths_of(raw: List[UInt8]) -> List[String]:
    """The paths in `raw`: NUL-separated when it holds a NUL (git diff -z),
    else one per line."""
    var sep = 10
    for i in range(len(raw)):
        if raw[i] == UInt8(0):
            sep = 0
            break
    var out = List[String]()
    var start = 0
    for i in range(len(raw) + 1):
        if i == len(raw) or Int(raw[i]) == sep:
            if i > start:
                var chunk = List[UInt8](capacity=i - start)
                for k in range(start, i):
                    chunk.append(raw[k])
                out.append(to_string(chunk))
            start = i + 1
    return out^


def _run() raises:
    var args = argv()
    var base = String("")
    var files_path = String("")
    var units_path = String("")
    var as_json = False
    var coverage = False
    var rules_path = String("tools/build/ci/rules.txt")
    var buckconfig = String(".buckconfig")
    var buck2 = String("./buck2")
    var buck2_args = List[String]()
    var i = 1
    while i < len(args):
        var a = String(args[i])
        if a == String("--json"):
            as_json = True
            i += 1
            continue
        if a == String("--coverage"):
            coverage = True
            i += 1
            continue
        if a == String("--help") or a == String("-h"):
            print("affected: see tools/build/ci/affected.mojo")
            exit(0)
        if i + 1 >= len(args):
            _usage(String("'") + a + String("' needs a value"))
        var v = String(args[i + 1])
        if a == String("--base"):
            base = v
        elif a == String("--files"):
            files_path = v
        elif a == String("--units-file"):
            units_path = v
        elif a == String("--rules"):
            rules_path = v
        elif a == String("--buckconfig"):
            buckconfig = v
        elif a == String("--buck2"):
            buck2 = v
        elif a == String("--isolation-dir"):
            buck2_args.append(String("--isolation-dir"))
            buck2_args.append(v)
        elif a == String("--buck2-arg"):
            buck2_args.append(v)
        else:
            _usage(String("unknown flag '") + a + String("'"))
        i += 2
    if coverage and units_path.byte_length() == 0:
        _usage(String("--coverage needs --units-file"))
    if base.byte_length() == 0 and files_path.byte_length() == 0 and not coverage:
        _usage(String("give --base, or --files (with --base to read deleted files' packages from)"))
    if as_json and units_path.byte_length() > 0:
        _usage(String("--json and --units-file are two answers; give one"))

    var started = Int(perf_counter_ns())
    var paths = List[String]()
    try:
        var rules = read_rules(rules_path)
        var cells = read_cells(buckconfig)
        if len(rules.universe) == 0:
            raise Error(String("the rules file '") + rules_path + String("' names no universe"))
        if coverage:
            pass
        elif files_path.byte_length() > 0:
            var raw = read_file(files_path)
            paths = _paths_of(raw^)
        else:
            var diff = List[String]()
            diff.append(String("diff"))
            diff.append(String("-z"))
            diff.append(String("--name-only"))
            diff.append(String("--no-renames"))
            diff.append(base + String("...HEAD"))
            var d = run_captured(String("git"), diff^)
            if not d.ok():
                raise Error(String("git diff ") + base + String("...HEAD failed: ") + d.stderr)
            var out = List[UInt8]()
            var ob = d.stdout.as_bytes()
            for k in range(len(ob)):
                out.append(ob[k])
            paths = _paths_of(out^)
        var units = UnitTargets()
        if units_path.byte_length() > 0:
            units = parse_units_file(to_string(read_file(units_path)))
        var graph = BuckGraph(buck2^, buck2_args^, base^, cells^, rules.universe.copy())
        if coverage:
            var wanted = List[String]()
            for k in range(len(units.targets)):
                wanted.append(normalize_label(units.targets[k], graph.cells.root))
            var held = graph.closure(wanted)
            var left = uncovered(graph.all_targets(), held)
            for k in range(len(left)):
                print(left[k])
            var cms = (Int(perf_counter_ns()) - started) // 1_000_000
            _say(String("affected: coverage: ") + String(len(left)) + String(" target(s) no unit builds or depends on, ") + render_seconds(cms))
            exit(EXIT_UNCOVERED if len(left) > 0 else 0)
        var verdict = compute(rules, paths, graph)
        var ms = (Int(perf_counter_ns()) - started) // 1_000_000
        for k in range(len(verdict.warnings)):
            _say(String("affected: WARN ") + verdict.warnings[k])
        _say(render_summary(verdict, ms))
        if units_path.byte_length() > 0:
            var names = affected_units(units, verdict.targets, graph.cells.root)
            print(render_units_answer(verdict, names), end="")
            exit(0)
        if as_json:
            print(render_json(verdict, ms), end="")
        else:
            print(render_targets(verdict), end="")
        if verdict.kind == String(KIND_WIDENED):
            exit(EXIT_WIDENED)
        if verdict.kind == String(KIND_BROKEN):
            exit(EXIT_BROKEN)
        if verdict.kind == String(KIND_VACUOUS):
            exit(EXIT_VACUOUS)
        exit(0)
    except e:
        _say(String("affected: cannot tell: ") + String(e))
        exit(EXIT_CANNOT_TELL)


def main():
    try:
        _run()
    except e:
        _say(String("affected: cannot tell: ") + String(e))
        exit(EXIT_CANNOT_TELL)
