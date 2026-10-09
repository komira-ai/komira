"""The command line of `mutate` (tools/build/coverage/README.md, "Mutation
score"):

    mutate list --src-dir <dir> --file <path>... --sample <n> --seed <s> --out <list>
    mutate apply --src <file> --path <path> --id <id> --out <file>
    mutate score --list <list> --label <label> --src-repo <prefix>
                 --out-tsv <mutants.tsv> --out-md <summary.md>
                 [--mutant <id> --precompile <status>
                    [--test <name> --build <status> --run <status>]...]...

`list` writes the list file of the `--file`s (paths in the package, read
under `--src-dir`; `--sample 0` keeps every mutant). `apply` writes the file
`--src` with mutant `--id` applied (`--path` is the file's path in the
package, which the id names); the id `baseline` writes it unchanged. `score` reads each sampled mutant's step
statuses and writes the report; every mutant of the list must be given
exactly once, and so must the baseline (`--mutant baseline`), the library
unchanged through the same steps: unless every one of its steps is ok, the
harness is broken and nothing is scored (exit 1).

Exit status: 0 done, 1 an input is malformed or a mutant unknown, 2 bad usage.
"""

from std.io import FileDescriptor

from mutate.gen import Mutant, Suppressed, apply, generate
from mutate.sample import parse_list, render_list
from mutate.score import BASELINE, Scored, TestSteps, check_baseline, render_mutants, render_summary, verdict

comptime EXIT_OK = 0
comptime EXIT_INPUT = 1
comptime EXIT_USAGE = 2


def read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return String(from_utf8_lossy=f.read_bytes())


def write_text(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _value(args: List[String], i: Int) raises -> String:
    if i + 1 >= len(args):
        raise Error("usage: " + args[i] + " needs a value")
    return args[i + 1]


def _int(s: String) raises -> Int:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error("usage: `" + s + "` is not a count")
    var v = 0
    for c in b:
        if Int(c) < 48 or Int(c) > 57:
            raise Error("usage: `" + s + "` is not a count")
        v = v * 10 + Int(c) - 48
    return v


def run_list(args: List[String]) raises:
    var src_dir = String("")
    var out = String("")
    var seed = String("")
    var n = -1
    var files = List[String]()
    var i = 1
    while i < len(args):
        var a = args[i]
        var v = _value(args, i)
        if a == "--src-dir":
            src_dir = v
        elif a == "--file":
            files.append(v)
        elif a == "--sample":
            n = _int(v)
        elif a == "--seed":
            seed = v
        elif a == "--out":
            out = v
        else:
            raise Error("usage: list: unknown flag " + a)
        i += 2
    if src_dir == "" or out == "" or n < 0:
        raise Error("usage: list needs --src-dir, --sample and --out")
    var mutants = List[Mutant]()
    var suppressed = List[Suppressed]()
    for f in files:
        var g = generate(f, read_text(src_dir + "/" + f))
        for m in g.mutants:
            mutants.append(m.copy())
        for s in g.suppressed:
            suppressed.append(s.copy())
    write_text(out, render_list(mutants, suppressed, n, seed))


def run_apply(args: List[String]) raises:
    var src = String("")
    var path = String("")
    var id = String("")
    var out = String("")
    var i = 1
    while i < len(args):
        var a = args[i]
        var v = _value(args, i)
        if a == "--src":
            src = v
        elif a == "--path":
            path = v
        elif a == "--id":
            id = v
        elif a == "--out":
            out = v
        else:
            raise Error("usage: apply: unknown flag " + a)
        i += 2
    if src == "" or path == "" or id == "" or out == "":
        raise Error("usage: apply needs --src, --path, --id and --out")
    var text = read_text(src)
    var g = generate(path, text)
    if id == BASELINE:
        write_text(out, text)
        return
    for m in g.mutants:
        if m.id() == id:
            write_text(out, apply(text, m))
            return
    raise Error("no mutant `" + id + "` in " + path)


def run_score(args: List[String]) raises:
    var list_path = String("")
    var label = String("")
    var src_repo = String("")
    var out_tsv = String("")
    var out_md = String("")
    var ids = List[String]()
    var pre = List[String]()
    var steps = List[List[TestSteps]]()
    var i = 1
    while i < len(args):
        var a = args[i]
        var v = _value(args, i)
        if a == "--list":
            list_path = v
        elif a == "--label":
            label = v
        elif a == "--src-repo":
            src_repo = v
        elif a == "--out-tsv":
            out_tsv = v
        elif a == "--out-md":
            out_md = v
        elif a == "--mutant":
            ids.append(v)
            pre.append(String(""))
            steps.append(List[TestSteps]())
        elif a == "--precompile":
            if len(ids) == 0:
                raise Error("usage: --precompile before any --mutant")
            pre[len(pre) - 1] = read_text(v)
        elif a == "--test":
            if len(ids) == 0:
                raise Error("usage: --test before any --mutant")
            steps[len(steps) - 1].append(TestSteps(v, String(""), String("")))
        elif a == "--build" or a == "--run":
            if len(ids) == 0 or len(steps[len(steps) - 1]) == 0:
                raise Error("usage: " + a + " before any --test")
            ref ts = steps[len(steps) - 1]
            if a == "--build":
                ts[len(ts) - 1].build = read_text(v)
            else:
                ts[len(ts) - 1].run = read_text(v)
        else:
            raise Error("usage: score: unknown flag " + a)
        i += 2
    if list_path == "" or out_tsv == "" or out_md == "":
        raise Error("usage: score needs --list, --out-tsv and --out-md")
    var lf = parse_list(read_text(list_path))
    var b = -1
    for k in range(len(ids)):
        if ids[k] == BASELINE:
            if b >= 0:
                raise Error("the baseline was given twice")
            b = k
    if b < 0:
        raise Error("no baseline (`--mutant baseline`): without it a broken harness would score every mutant killed")
    check_baseline(pre[b], steps[b])
    if len(ids) - 1 != len(lf.rows):
        raise Error("the list names " + String(len(lf.rows)) + " mutants; " + String(len(ids) - 1) + " were given")
    var rows = List[Scored]()
    for r in range(len(lf.rows)):
        ref row = lf.rows[r]
        var at = -1
        for k in range(len(ids)):
            if ids[k] == row.id:
                if at >= 0:
                    raise Error("mutant `" + row.id + "` given twice")
                at = k
        if at < 0:
            raise Error("mutant `" + row.id + "` of the list was not given")
        if pre[at] == "":
            raise Error("mutant `" + row.id + "`: no --precompile")
        for t in steps[at]:
            if t.build == "" or t.run == "":
                raise Error("mutant `" + row.id + "`: test " + t.name + " needs --build and --run")
        try:
            rows.append(Scored(row.path, row.line, row.col, row.operator, row.description, verdict(pre[at], steps[at])))
        except e:
            raise Error("mutant `" + row.id + "`: " + String(e))
    var sup_ids = List[String]()
    var sup_why = List[String]()
    for s in lf.suppressed:
        sup_ids.append(s.id)
        sup_why.append(s.kind + ": " + s.reason)
    write_text(out_tsv, render_mutants(rows, src_repo))
    write_text(out_md, render_summary(label, lf.header, rows, src_repo, sup_ids, sup_why))


def run(args: List[String]) -> Int:
    """Runs the command line `args` (without the program name)."""
    var err = FileDescriptor(2)
    if len(args) == 0:
        print("mutate: usage: mutate list|apply|score ...", file=err)
        return EXIT_USAGE
    try:
        if args[0] == "list":
            run_list(args)
        elif args[0] == "apply":
            run_apply(args)
        elif args[0] == "score":
            run_score(args)
        else:
            print(String("mutate: usage: unknown command ") + args[0], file=err)
            return EXIT_USAGE
    except e:
        var msg = String(e)
        print(String("mutate: ") + msg, file=err)
        return EXIT_USAGE if msg.startswith("usage:") else EXIT_INPUT
    return EXIT_OK
