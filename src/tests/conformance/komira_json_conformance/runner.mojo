# =============================================================================
# runner.mojo -- run one parser over the whole suite and gate the result
# =============================================================================
#
# `conformance_main` is the whole of a parser's welded test. It loads the
# suite (suite.mojo: every file, exactly the pinned counts), reads the
# parser's allowlist, and feeds every file not listed as ABORTS: to the
# parser's testee (testees.mojo), printing each verdict as it lands, so if an
# unlisted file aborts the process the log ends at the file before it (files
# run in bytewise name order). Then it runs each ABORTS: file alone in a child
# process (the test's own executable, `--child <file>`) and records how the
# child ended, so the gate (gate.mojo) can tell a stale ABORTS: line from a
# live one. It raises with every gate problem when there is one.
# =============================================================================

from std.sys import argv, exit

from komira_runtime_paths import executable_path, read_data
from komira_supervisor import ChildSpec, Supervisor

from komira_json_conformance.gate import (
    AbortCheck,
    FileResult,
    V_ACCEPT,
    V_BOUNDARY,
    V_MISREAD,
    V_REJECT,
    aborting_files,
    gate,
    parse_allowlist,
    verdict_name,
)
from komira_json_conformance.suite import (
    SuiteFile,
    kind_name,
    kind_of,
    load_suite,
    suite_dir,
    suite_file_bytes,
)
from komira_json_conformance.testees import (
    MISREAD,
    NOT_UTF8,
    is_crash_only,
    run_testee,
)

# The argument that makes a test executable run one file and exit.
comptime CHILD_FLAG = "--child"


def allowlist_path(parser: String) -> String:
    """The allowlist's test_data destination (its path in the repository)."""
    return "src/tests/conformance/komira_json_conformance/allowlists/" + parser + ".txt"


def run_one(parser: String, name: String, b: List[UInt8]) -> FileResult:
    """`parser`'s verdict on one file. A testee error starting NOT_UTF8 is the
    harness's String boundary and one starting MISREAD is the harness's check
    of the parser's output; any other error is the parser's rejection."""
    var kind: UInt8 = 2
    try:
        kind = kind_of(name)
    except:
        pass
    try:
        run_testee(parser, b)
        return FileResult(name=name, kind=kind, verdict=V_ACCEPT, detail=String(""))
    except e:
        var detail = String(e)
        var v = V_REJECT
        if detail.startswith(NOT_UTF8):
            v = V_BOUNDARY
        elif detail.startswith(MISREAD):
            v = V_MISREAD
        return FileResult(name=name, kind=kind, verdict=v, detail=detail^)


def run_parser(
    parser: String, suite: List[SuiteFile], skip: List[String]
) -> List[FileResult]:
    """`parser`'s verdict on every file of `suite` except those in `skip`,
    each printed as soon as it is known."""
    var out = List[FileResult]()
    for ref f in suite:
        var skipped = False
        for ref s in skip:
            if s == f.name:
                skipped = True
                break
        if skipped:
            continue
        var r = run_one(parser, f.name, f.bytes)
        print(parser, r.describe(), flush=True)
        out.append(r^)
    return out^


def run_self(exe: String, name: String, args: List[String]) raises -> AbortCheck:
    """Run `exe` with `args` in a child process and record how it ended
    (`name` labels the record): died by a signal, or exited."""
    var spec = ChildSpec(exe)
    var line = exe.copy()
    for ref a in args:
        spec.with_arg(a)
        line += " " + a
    var sup = Supervisor()
    if sup.spawn(spec) <= Int32(0):
        sup.close()
        raise Error("cannot spawn " + line)
    var out_err = sup.drain_both(sup.stdout_fd(), sup.stderr_fd())
    var info = sup.wait_exit()
    sup.close()
    var died = info.signal >= Int32(0)
    var how = (
        String("signal ") + String(Int(info.signal)) if died else String("exit ")
        + String(Int(info.exit_code))
    )
    return AbortCheck(
        name=name, died=died, how=how^, output=out_err[0] + "\n" + out_err[1]
    )


def check_abort(exe: String, name: String) raises -> AbortCheck:
    """Run the ABORTS: file `name` alone in a child: this executable with
    `--child <name>`."""
    var args: List[String] = [String(CHILD_FLAG), name]
    return run_self(exe, name, args)


def run_child(parser: String, name: String) raises:
    """The child side: one file, its verdict on stdout, then exit."""
    var r = run_one(parser, name, suite_file_bytes(suite_dir(), name))
    print("CHILD", verdict_name(r.verdict), r.describe(), flush=True)


def gate_parser(parser: String, allowlist: String) raises -> List[String]:
    """Run `parser` over the suite against the allowlist text `allowlist`
    (ABORTS: files in children) and return every gate problem."""
    var suite = load_suite()
    var entries = parse_allowlist(allowlist)
    var skip = aborting_files(entries)
    var results = run_parser(parser, suite, skip)
    var exe = executable_path()
    var aborts = List[AbortCheck]()
    for ref s in skip:
        var a = check_abort(exe, s)
        print(parser, "ABORTS: child for", s, "ended by", a.how, flush=True)
        aborts.append(a^)
    var counts: List[Int] = [0, 0, 0, 0]
    for ref r in results:
        counts[Int(r.verdict)] += 1
    var names = List[String]()
    for ref f in suite:
        names.append(f.name)
    var crash_only = is_crash_only(parser)
    var problems = gate(parser, crash_only, results, entries, aborts, names)
    print(
        parser, ":", len(results), "files run:", counts[Int(V_ACCEPT)], "ACCEPT,",
        counts[Int(V_REJECT)], "REJECT,", counts[Int(V_BOUNDARY)], "BOUNDARY,",
        counts[Int(V_MISREAD)], "MISREAD;", len(skip), "ABORTS: files run in children;",
        len(entries), "allowlist entries;", "crash-only" if crash_only else "verdicts gated",
    )
    return problems^


def check_parser(parser: String) raises:
    """`parser`'s conformance test: raises unless the gate passes."""
    var problems = gate_parser(parser, read_data(allowlist_path(parser)))
    if len(problems) > 0:
        var msg = String(parser + ": " + String(len(problems)) + " conformance problem(s):")
        for ref p in problems:
            msg += "\n  " + p
        raise Error(msg)


def conformance_main(parser: String) raises:
    """A parser test's `main`: the whole test, or with `--child <file>` one
    file in a child (check_abort)."""
    var args = argv()
    if len(args) >= 3 and String(args[1]) == CHILD_FLAG:
        run_child(parser, String(args[2]))
        exit(0)  # the child is done: not the parent's PASS line
    check_parser(parser)
