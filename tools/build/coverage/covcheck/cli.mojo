"""The command line: `covcheck report` and `covcheck gate` (see README.md).

Exit codes: 0 the outputs were written (whatever they conclude); 1 an input
is malformed, a report path is unmapped, or an output cannot be written;
2 bad usage; 3 (`gate` only) `--mode enforce` and the package has a finding
(a test-only package, `--info-package`, has information, never a finding).
"""

from std.io import FileDescriptor
from std.os import listdir, makedirs

from covcheck.analyze import FORMAT_BRANCH_LCOV, FORMAT_COBERTURA, FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.annotate import (
    DEFAULT_MAX_ANNOTATIONS,
    DiffCoverage,
    annotations,
    annotations_json,
    cap_annotations,
    cap_note,
    diff_coverage,
    touched_packages,
)
from covcheck.checkrun import body_name, checkrun_bodies, valid_sha
from covcheck.diff import parse_diff
from covcheck.paths import RepoFiles, package_of, parse_repo_files
from covcheck.ratchet import parse_ratchet, render_ratchet
from covcheck.result import gate_json, report_json
from covcheck.stats import MODE_ENFORCE, MODE_NEUTRAL, valid_mode
from covcheck.summary import render_summary, truncate_summary
from covcheck.text import parse_count, read_bytes, read_text, render_bp_or_na, split_on, substr, suffix, write_text

comptime EXIT_OK: Int = 0
comptime EXIT_INPUT: Int = 1
comptime EXIT_USAGE: Int = 2
comptime EXIT_GATE: Int = 3

comptime USAGE_MARK = "usage: "

comptime USAGE_REPORT = (
    "covcheck report --repo-files F --diff F --head-sha SHA --source-root DIR"
    + " (--cobertura [PKGDIR=]F | --lcov [PKGDIR=]F)... [--branch-lcov [PKGDIR=]F]... [--mutants [PKGDIR=]F]..."
    + " [--strip-prefix P]... --ratchet F [--mode census|neutral|enforce] [--target-bp N]"
    + " [--include-tests] [--info-package DIR]... [--name N] [--max-annotations N] --summary-out F --checkrun-dir D --result-out F"
    + " [--annotations-out F] [--ratchet-out F]"
)
comptime USAGE_GATE = (
    "covcheck gate --package DIR --repo-files F --source-root DIR"
    + " [--cobertura [PKGDIR=]F | --lcov [PKGDIR=]F]... [--branch-lcov [PKGDIR=]F]... [--mutants [PKGDIR=]F]..."
    + " [--strip-prefix P]... --ratchet F --mode census|neutral|enforce [--target-bp N]"
    + " [--include-tests] [--test-source P]... [--info-package DIR]... --result-out F --summary-out F"
)


struct FileArg(Copyable, Movable):
    """`--cobertura`, `--lcov`, `--branch-lcov` or `--mutants`
    `[PKGDIR=]FILE`."""

    var format: String
    var pkgdir: String
    var file: String

    def __init__(out self, format: String, pkgdir: String, file: String):
        self.format = format
        self.pkgdir = pkgdir
        self.file = file


struct Args(Copyable, Movable):
    var command: String
    var values: Dict[String, String]
    var reports: List[FileArg]
    var mutants: List[FileArg]
    var strip_prefixes: List[String]
    var test_sources: List[String]
    var info_packages: List[String]
    var include_tests: Bool

    def __init__(out self):
        self.command = String("")
        self.values = Dict[String, String]()
        self.reports = List[FileArg]()
        self.mutants = List[FileArg]()
        self.strip_prefixes = List[String]()
        self.test_sources = List[String]()
        self.info_packages = List[String]()
        self.include_tests = False

    def get(self, flag: String) -> String:
        """The value of `flag`, or the empty string."""
        return self.values.get(flag, String(""))


def _usage(why: String) raises:
    raise Error(String(USAGE_MARK) + why)


def file_arg(format: String, v: String) -> FileArg:
    """`[PKGDIR=]FILE`: the package directory is before the first `=`
    (without a trailing `/`); a FILE holding `=` is given as `=FILE`."""
    var eq = v.find("=")
    if eq < 0:
        return FileArg(format, String(""), v)
    var dir = substr(v, 0, eq)
    while dir.endswith("/"):
        dir = substr(dir, 0, dir.byte_length() - 1)
    return FileArg(format, dir, suffix(v, eq + 1))


def parse_args(args: List[String]) raises -> Args:
    """`args` without the program name. Raises `usage: ...` on bad usage."""
    var a = Args()
    if len(args) == 0:
        _usage(String("give a command: report or gate"))
    a.command = args[0]
    var report = a.command == String("report")
    if not report and a.command != String("gate"):
        _usage(String("unknown command '") + a.command + String("' (report or gate)"))
    var single = split_on(String("--repo-files --source-root --ratchet --mode --target-bp --summary-out --result-out"), 32)
    if report:
        single.extend(split_on(String("--diff --head-sha --name --checkrun-dir --ratchet-out --max-annotations --annotations-out"), 32))
    else:
        single.append(String("--package"))
    var i = 1
    while i < len(args):
        var flag = args[i]
        if flag == String("--include-tests"):
            a.include_tests = True
            i += 1
            continue
        var known = (
            flag == String("--cobertura") or flag == String("--lcov") or flag == String("--branch-lcov")
            or flag == String("--mutants") or flag == String("--strip-prefix") or flag == String("--info-package")
        )
        if flag == String("--test-source") and not report:
            known = True
        for k in range(len(single)):
            if single[k] == flag:
                known = True
        if not known:
            _usage(String("unknown flag '") + flag + String("' for ") + a.command)
        if i + 1 >= len(args):
            _usage(String("'") + flag + String("' needs a value"))
        var v = args[i + 1]
        if v.byte_length() == 0:
            _usage(String("'") + flag + String("' has an empty value"))
        i += 2
        if flag == String("--cobertura"):
            a.reports.append(file_arg(String(FORMAT_COBERTURA), v))
        elif flag == String("--lcov"):
            a.reports.append(file_arg(String(FORMAT_LCOV), v))
        elif flag == String("--branch-lcov"):
            a.reports.append(file_arg(String(FORMAT_BRANCH_LCOV), v))
        elif flag == String("--mutants"):
            a.mutants.append(file_arg(String("mutants"), v))
        elif flag == String("--strip-prefix"):
            a.strip_prefixes.append(v)
        elif flag == String("--test-source"):
            a.test_sources.append(v)
        elif flag == String("--info-package"):
            # A test-only package's directory (analyze.mojo, step 8), a
            # repository directory as package_of names it.
            var d = v
            while d.endswith("/"):
                d = substr(d, 0, d.byte_length() - 1)
            if d.byte_length() == 0 or d.startswith("/") or d.find("//") >= 0 or d == String("."):
                _usage(String("--info-package '") + v + String("' is not a repository directory"))
            a.info_packages.append(d)
        else:
            if flag in a.values:
                _usage(String("'") + flag + String("' is given twice"))
            a.values[flag] = v
    var required = split_on(String("--repo-files --source-root --ratchet --summary-out --result-out"), 32)
    if report:
        required.extend(split_on(String("--diff --head-sha --checkrun-dir"), 32))
    else:
        required.append(String("--package"))
        required.append(String("--mode"))
    for k in range(len(required)):
        if required[k] not in a.values:
            _usage(a.command + String(" needs ") + required[k])
    # `gate` takes none: a library with no test has no report, and its
    # package, always measured by the gate, is then NotMeasured. A branch
    # record file (`--branch-lcov`) is no line report, and is read with
    # either format.
    var line_reports = List[FileArg]()
    for k in range(len(a.reports)):
        if a.reports[k].format != String(FORMAT_BRANCH_LCOV):
            line_reports.append(a.reports[k].copy())
    if len(line_reports) == 0 and report:
        _usage(a.command + String(" needs at least one --cobertura or --lcov report"))
    for k in range(1, len(line_reports)):
        if line_reports[k].format != line_reports[0].format:
            _usage(String("give --cobertura or --lcov reports, not both (their branch identities differ)"))
    var mode = a.get(String("--mode"))
    if mode.byte_length() > 0 and not valid_mode(mode):
        _usage(String("--mode '") + mode + String("' is not census, neutral or enforce"))
    var t = a.get(String("--target-bp"))
    if t.byte_length() > 0:
        var v = parse_count(t)
        if v < 0 or v > 10000:
            _usage(String("--target-bp '") + t + String("' is not a number of basis points from 0 to 10000"))
    var cap = a.get(String("--max-annotations"))
    if cap.byte_length() > 0 and parse_count(cap) < 1:
        _usage(String("--max-annotations '") + cap + String("' is not a number of annotations of 1 or more"))
    if report and not valid_sha(a.get(String("--head-sha"))):
        _usage(String("--head-sha '") + a.get(String("--head-sha")) + String("' is not 40 lowercase hex digits"))
    return a^


def max_annotations(a: Args) -> Int:
    """`--max-annotations` (checked by `parse_args`), else the default."""
    var v = a.get(String("--max-annotations"))
    if v.byte_length() == 0:
        return DEFAULT_MAX_ANNOTATIONS
    return parse_count(v)


def _options(a: Args) -> Options:
    var o = Options()
    var mode = a.get(String("--mode"))
    o.mode = mode if mode.byte_length() > 0 else String(MODE_NEUTRAL)
    var t = a.get(String("--target-bp"))
    if t.byte_length() > 0:
        o.target_bp = parse_count(t)
    o.include_tests = a.include_tests
    o.strip_prefixes = a.strip_prefixes.copy()
    if a.command == String("gate"):
        o.only_package = a.get(String("--package"))
    for i in range(len(a.test_sources)):
        o.test_sources[a.test_sources[i]] = True
    o.info_packages = a.info_packages.copy()
    return o^


def _read_inputs(fs: List[FileArg]) raises -> List[Input]:
    var out = List[Input]()
    for i in range(len(fs)):
        out.append(Input(fs[i].format, fs[i].pkgdir, fs[i].file, read_text(fs[i].file)))
    return out^


def _analysis(a: Args, repo: RepoFiles) raises -> Analysis:
    var ratchet_path = a.get(String("--ratchet"))
    var ratchet = parse_ratchet(read_text(ratchet_path), ratchet_path)
    return analyze(
        _read_inputs(a.reports), _read_inputs(a.mutants), repo, ratchet,
        Sources(a.get(String("--source-root"))), _options(a),
    )


def _title(an: Analysis) -> String:
    return (
        String("line ") + render_bp_or_na(an.total.line_bp()) + String(", branch ")
        + render_bp_or_na(an.total.branch_bp()) + String(", ") + String(len(an.findings))
        + String(" findings") + (String(", ") + String(len(an.info_findings)) + String(" info") if len(an.info_findings) > 0 else String(""))
        + String(" (") + an.mode + String(")")
    )


def run_report(a: Args) raises -> Int:
    var repo_path = a.get(String("--repo-files"))
    var repo = parse_repo_files(read_bytes(repo_path), repo_path)
    var diff_path = a.get(String("--diff"))
    var d = parse_diff(read_text(diff_path), diff_path)
    var an = _analysis(a, repo)
    var touched = touched_packages(an, d, repo)
    var dc = diff_coverage(an, d, repo, a.include_tests)
    var anns = annotations(an, d, touched)
    var cap = max_annotations(a)
    var anns_out = a.get(String("--annotations-out"))
    var summary = render_summary(an, touched, dc, True, String(""), cap_note(len(anns), cap, anns_out.byte_length() > 0))
    var name = a.get(String("--name"))
    if name.byte_length() == 0:
        name = String("coverage")
    var bodies = checkrun_bodies(
        name, a.get(String("--head-sha")), _title(an), truncate_summary(summary), an.conclusion, cap_annotations(anns, cap)
    )
    var dir = a.get(String("--checkrun-dir"))
    makedirs(dir, exist_ok=True)
    if len(listdir(dir)) > 0:
        raise Error(String("--checkrun-dir ") + dir + String(" is not empty: every file in it would be sent"))
    write_text(a.get(String("--summary-out")), summary)
    write_text(a.get(String("--result-out")), report_json(an, touched, dc))
    for i in range(len(bodies)):
        write_text(dir + String("/") + body_name(i), bodies[i])
    if anns_out.byte_length() > 0:
        write_text(anns_out, annotations_json(anns))
    var rout = a.get(String("--ratchet-out"))
    if rout.byte_length() > 0:
        write_text(rout, render_ratchet(an.proposal))
    return EXIT_OK


def run_gate(a: Args) raises -> Int:
    var repo_path = a.get(String("--repo-files"))
    var repo = parse_repo_files(read_bytes(repo_path), repo_path)
    var pkg = a.get(String("--package"))
    if not repo.has_buck(pkg):
        raise Error(String("--package ") + pkg + String(" holds no BUCK file in --repo-files"))
    # A --test-source names a file of the gated package (a welded test
    # outside its tests/): anything else is a mistake that would set aside
    # nothing.
    for i in range(len(a.test_sources)):
        var t = a.test_sources[i]
        if t not in repo.files:
            raise Error(String("--test-source ") + t + String(" is not a file of --repo-files"))
        if package_of(t, repo) != pkg:
            raise Error(String("--test-source ") + t + String(" is in the package ") + package_of(t, repo) + String(", not --package ") + pkg)
    var an = _analysis(a, repo)
    write_text(a.get(String("--summary-out")), render_summary(an, List[String](), DiffCoverage(), False, pkg))
    write_text(a.get(String("--result-out")), gate_json(an, pkg))
    if an.mode == String(MODE_ENFORCE) and len(an.findings) > 0:
        return EXIT_GATE
    return EXIT_OK


def run(args: List[String]) -> Int:
    """Runs the command line `args` (without the program name); errors go
    to stderr. Returns the exit code."""
    var err = FileDescriptor(2)
    try:
        var parsed = parse_args(args)
        try:
            if parsed.command == String("report"):
                return run_report(parsed)
            return run_gate(parsed)
        except e:
            print(String("covcheck: ") + String(e), file=err)
            return EXIT_INPUT
    except e:
        print(String("covcheck: ") + String(e), file=err)
        print(String("usage: ") + String(USAGE_REPORT), file=err)
        print(String("       ") + String(USAGE_GATE), file=err)
        return EXIT_USAGE
