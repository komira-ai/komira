"""From the reports, the repository and the policy to the per-package numbers
and the findings: the one computation both `covcheck report` and
`covcheck gate` run, so the PR check and the build gate cannot disagree.

1. Each report is read (lcov or Cobertura) and each of its paths mapped
   (paths.mojo): a path outside the repository is counted and set aside, a
   test's generated main (paths.generated_test_main) is counted as a test
   source and set aside, any other unmapped path is an error naming every
   one.
2. The files are merged by repository path (hits summed per line, so a line
   any test binary reached is covered).
3. Each file's package is the nearest directory with a BUCK file. With
   `only_package`, the files of every other package are dropped here. Test
   sources (`<package>/tests/...`, and each path of `test_sources`: a
   welded test elsewhere in its package, named by the gate) are counted and
   dropped unless `include_tests`.
3b. A kept `.mojo` file whose first line is the header `# @generated`
   (generated.mojo) leaves the run here: its report records, its branch
   records and its mutants are dropped, and step 4 skips it, so it is
   neither measured nor counted as a file no test compiled, and is in no
   floor. `Analysis.generated_paths` lists them.
4. Each kept file's source is read for exemption markers (exempt.mojo).
   Then the full source: a package is measured when a report names a kept
   file in it (with or without records), and the gated package
   (`only_package`) always is, and so is each package given a hold
   (`held`; held.mojo). Every `.mojo` file of the repository whose
   package is a measured one, that no report gives a line or branch record,
   and that is not a left-out test source, is read from the checkout and
   counted as a file no test compiled: each executable line (lexer.mojo's
   heuristic) a line record with 0 hits, then exemptions applied as for any
   file. Such a file with a line left raises `UnmeasuredFile` and is counted
   in `unmeasured_files`; one with no line left (an `__init__.mojo` of
   imports, every line exempted) raises nothing and is listed only for its
   markers, if it has any. A declaration-only file (decls.mojo: traits
   whose methods have no body, `comptime` declarations, imports) with no
   marker and no branch record counts no line either: it emits no code.
   It is not counted as a file, and raises `DeclarationOnlyFile`, which is
   information (`info_findings`), never counted.
5. The mutants are read and mapped the same way.
6. Per package: lines, branches, exemptions, mutants; the metrics it holds.
7. Findings: `BelowTarget` (line, and branch when measured, below
   `target_bp`), `NotMeasured` (a package in the run, the gated package
   included, with no line record and no exempted line, while `target_bp` is
   above 0: nothing was measured, so it cannot be shown to meet the
   target; a package whose only lines are those of files no test compiled
   is still not measured), `BranchNotMeasured` (a package with a line
   record and no branch record in any report, before exemptions, and no
   kept file a branch record file names, while `target_bp` is above 0:
   line coverage alone is not shown to meet a line-and-branch target, so a
   report without branch data, such as kcov's, never passes in enforce
   mode; a branch record file's `SF` with no `BRDA`, a file whose code the
   test held with no decision in it, measures its package's branches, of
   which there are none), one
   `MutantSurvived` per surviving mutant, `UnmeasuredFile` per file no test
   compiled (its message says the line and branch measurements disagree
   when the file's branch records show an arm taken),
   `BranchUnmeasuredFile` per file with a line record, in a package a branch
   record file names a kept file of, that no branch record file names and
   whose line report gives no branch record (its branches were not read,
   and would count as none),
   `ExemptionWithoutReason` and `StaleExemption`. A metric the package
   holds (held.mojo) turns its threshold finding into a `Regression`: a
   held line below `target_bp` or with no line record and no exempted line
   (in place of NotMeasured), a held branch below it or with no branch
   record (in place of BranchNotMeasured). A gated package with no
   executable line and no exempted one (`only_package`: every source of
   its library counted, so a library whose sources are all generated) has
   nothing to cover, and an unmeasured held metric of it is no finding. A
   metric at or above `target_bp` that the package does not hold is
   `ReachedTarget`, information (`info_findings`) for every package but a
   test-only one: it says to add the metric to the package's marker.
8. Test-only packages: the findings of a package that is one of
   `info_packages` (`--info-package`, the directories of policy.bzl's
   COVERAGE_INFO_ONLY_DIRS) or under one are moved to `info_findings`. Such
   a package is measured and reported as any other, but held to no target:
   its findings are information, never counted (the conclusion, a gate's
   exit and the annotation level read `findings` alone). A test-only
   package has no hold (held.mojo refuses its marker).
9. Report only (no number or finding depends on it yet):
   each kept file with a line record is read for the functions it declares
   (decls.mojo), and every function with a body none of whose lines has a
   record is listed in `unrecorded_functions` with its class (decls.mojo:
   `plain`, `always_inline`, `comptime_if`) and the count of its executable
   lines that carry no exemption marker with a reason. The line numbers
   above cannot see such a function, but only a `plain` one is evidence
   that no test calls it: an inlined or comptime-gated function a test
   calls can have no record of its own. A file with branch records and no
   line record lists none: no line record says which lines held code.
10. The conclusion (stats.conclusion_of), over `findings` after step 8:
    `failure` with any `Regression` in every mode, so a hold fails even in
    census mode; otherwise by mode.

The line reports must all be lcov or all Cobertura: the two formats
identify a line's branches differently, so one file in both would count its
branches twice. Branch record files (`--branch-lcov`, branch_lcov.mojo) are
a separate input, read with either: their branches join the line report's
file of the same repository path (or, for a file no line report gives a
record, the file counted from its source in step 4), and one file may not
take branches from both (one source of branch data per file). Where
branch record files give one location a different number of decisions,
the files with the most decisions there are summed and the others'
records at it are dropped (branch_lcov.drop_smaller_copies); one decision
given a different number of arms is refused (branch_lcov.DecisionShapes),
and so is one branch record file naming a repository path twice (two spellings that map to it). These checks cover
the files kept in step 3 only: a file left out counts nowhere.
"""

from covcheck.branch_lcov import DecisionShapes, drop_smaller_copies, parse_branch_lcov
from covcheck.cobertura import parse_cobertura
from covcheck.decls import declaration_only, declared_functions, unrecorded_functions
from covcheck.generated import is_generated
from covcheck.exempt import STATUS_NO_REASON, STATUS_STALE, Exemption, apply_exemptions, scan_markers
from covcheck.lcov import parse_lcov
from covcheck.lexer import executable_lines
from covcheck.model import FileCov, merge_by_path
from covcheck.mutants import KILLED, SURVIVED, TIMEOUT, Mutant, parse_mutants
from covcheck.paths import MAPPED, OUTSIDE, RepoFiles, generated_test_main, is_test_source, map_path, package_of
from covcheck.held import Held
from covcheck.platform_gate import Cand, platform_gated
from covcheck.uncompiled import Evidence, declared_twice, drop_lines, drop_unreliable, is_uncompiled_report, unreliable_lines
from covcheck.stats import (
    BELOW_TARGET,
    BRANCH_NOT_MEASURED,
    BRANCH_UNMEASURED_FILE,
    DECLARATION_ONLY_FILE,
    NOT_MEASURED,
    EXEMPTION_WITHOUT_REASON,
    REACHED_TARGET,
    REGRESSION,
    MODE_NEUTRAL,
    MUTANT_SURVIVED,
    STALE_EXEMPTION,
    UNMEASURED_FILE,
    Finding,
    PackageStats,
    conclusion_of,
    is_info_package,
)
from covcheck.text import join, line_key, read_text, render_bp, sort_by_keys, sort_strings

comptime FORMAT_LCOV = "lcov"
comptime FORMAT_COBERTURA = "cobertura"
comptime FORMAT_BRANCH_LCOV = "branch-lcov"


struct Input(Copyable, Movable):
    """One input file's text: a coverage report (`format` lcov or
    cobertura), a branch record file (branch-lcov) or a mutants file (`format` mutants), and the package
    directory it was given with (`PKGDIR=FILE`, else empty)."""

    var format: String
    var pkgdir: String
    var origin: String
    var text: String

    def __init__(out self, format: String, pkgdir: String, origin: String, text: String):
        self.format = format
        self.pkgdir = pkgdir
        self.origin = origin
        self.text = text


struct Options(Copyable, Movable):
    var mode: String
    var target_bp: Int
    var include_tests: Bool
    var only_package: String
    var strip_prefixes: List[String]
    # Repository paths of test sources outside `<package>/tests/`, set aside
    # as those are (`gate --test-source`).
    var test_sources: Dict[String, Bool]
    # The directories of test-only packages (`--info-package`; step 8).
    var info_packages: List[String]

    def __init__(out self):
        self.mode = String(MODE_NEUTRAL)
        self.target_bp = 10000
        self.include_tests = False
        self.only_package = String("")
        self.strip_prefixes = List[String]()
        self.test_sources = Dict[String, Bool]()
        self.info_packages = List[String]()


struct Sources(Copyable, Movable):
    """The repository's source files: `texts` first (a test's table), else
    read from the checkout at `root`."""

    var root: String
    var texts: Dict[String, String]

    def __init__(out self, root: String):
        self.root = root
        self.texts = Dict[String, String]()

    def read(self, path: String) raises -> String:
        if path in self.texts:
            return self.texts[path]
        if self.root.byte_length() == 0:
            raise Error(String("no source for ") + path)
        try:
            return read_text(self.root + String("/") + path)
        except e:
            raise Error(String("cannot read the source ") + path + String(" under --source-root ") + self.root + String(": ") + String(e))


struct UnrecordedFunction(Copyable, Movable):
    """A function of a measured file none of whose lines has a record
    (step 9): its package, file, `def` line, name, `kind` (decls.mojo's
    class) and `lines`, its executable lines that carry no exemption marker
    with a reason."""

    var package: String
    var path: String
    var line: Int
    var name: String
    var kind: String
    var lines: Int

    def __init__(out self, package: String, path: String, line: Int, name: String, kind: String, lines: Int):
        self.package = package
        self.path = path
        self.line = line
        self.name = name
        self.kind = kind
        self.lines = lines


struct ExcludedFile(Copyable, Movable):
    """What buildrules' report of the code no test compiled gave a file that the numbers leave out
    (uncompiled.mojo): `lines` line records and `arms` branch arms of functions a test was seen to
    call (an inlined function's lines, the lines of a gated function's arms)."""

    var package: String
    var path: String
    var lines: Int
    var arms: Int

    def __init__(out self, package: String, path: String):
        self.package = package
        self.path = path
        self.lines = 0
        self.arms = 0


struct GatedFunction(Copyable, Movable):
    """A function of buildrules' uncompiled report left out of the numbers because every call to it is in a
    compile-time arm this target did not compile (platform_gate.mojo): its package, file, name, `def` line
    and the `lines` of it that were left out."""

    var package: String
    var path: String
    var name: String
    var line: Int
    var lines: Int

    def __init__(out self, package: String, path: String, name: String, line: Int, lines: Int):
        self.package = package
        self.path = path
        self.name = name
        self.line = line
        self.lines = lines


struct Analysis(Copyable, Movable):
    """What one run measured and found. `files` holds the kept files (with
    exemptions applied), `file_packages` the package of each, `unmeasured`
    whether each is a file no report named (counted from its source);
    `packages`
    is sorted by package; `exemptions`, `mutants` and
    `unrecorded_functions` by path then line.
    `info_dirs` are the options' `info_packages`, `info_packages` the
    measured packages they cover (in `packages` order) and `info_findings`
    those packages' findings, which `findings` does not hold (step 8),
    then every `ReachedTarget` (step 7) and every package's
    `DeclarationOnlyFile` (step 4)."""

    var mode: String
    var target_bp: Int
    var files: List[FileCov]
    var file_packages: List[String]
    var unmeasured: List[Bool]
    var packages: List[PackageStats]
    var exemptions: List[Exemption]
    var mutants: List[Mutant]
    var mutant_packages: List[String]
    var findings: List[Finding]
    var unrecorded_functions: List[UnrecordedFunction]
    # The files the uncompiled report gave lines or arms that are left out of the numbers (path order).
    var excluded: List[ExcludedFile]
    # The platform-gated functions (path, line order) and the branch arms left out with them.
    var platform_gated: List[GatedFunction]
    var platform_gated_arms: Int
    var info_dirs: List[String]
    var info_packages: List[String]
    var info_findings: List[Finding]
    var ignored_files: Int
    var excluded_test_files: Int
    # Repository paths of the generated sources left out (generated.mojo), sorted.
    var generated_paths: List[String]
    var ignored_mutants: Int
    var excluded_test_mutants: Int
    var total: PackageStats
    var conclusion: String

    def __init__(out self):
        self.mode = String(MODE_NEUTRAL)
        self.target_bp = 10000
        self.files = List[FileCov]()
        self.file_packages = List[String]()
        self.unmeasured = List[Bool]()
        self.packages = List[PackageStats]()
        self.exemptions = List[Exemption]()
        self.mutants = List[Mutant]()
        self.mutant_packages = List[String]()
        self.findings = List[Finding]()
        self.unrecorded_functions = List[UnrecordedFunction]()
        self.excluded = List[ExcludedFile]()
        self.platform_gated = List[GatedFunction]()
        self.platform_gated_arms = 0
        self.info_dirs = List[String]()
        self.info_packages = List[String]()
        self.info_findings = List[Finding]()
        self.generated_paths = List[String]()
        self.ignored_files = 0
        self.excluded_test_files = 0
        self.ignored_mutants = 0
        self.excluded_test_mutants = 0
        self.total = PackageStats(String("(total)"))
        self.conclusion = String("neutral")

    def package_index(self, package: String) -> Int:
        for i in range(len(self.packages)):
            if self.packages[i].package == package:
                return i
        return -1

    def excluded_lines(self) -> Int:
        var n = 0
        for i in range(len(self.excluded)):
            n += self.excluded[i].lines
        return n

    def platform_gated_lines(self) -> Int:
        var n = 0
        for i in range(len(self.platform_gated)):
            n += self.platform_gated[i].lines
        return n

    def excluded_arms(self) -> Int:
        var n = 0
        for i in range(len(self.excluded)):
            n += self.excluded[i].arms
        return n

    def file_index(self, path: String) -> Int:
        for i in range(len(self.files)):
            if self.files[i].path == path:
                return i
        return -1


def _parse_report(inp: Input) raises -> List[FileCov]:
    if inp.format == String(FORMAT_LCOV):
        return parse_lcov(inp.text, inp.origin)
    if inp.format == String(FORMAT_COBERTURA):
        return parse_cobertura(inp.text, inp.origin)
    if inp.format == String(FORMAT_BRANCH_LCOV):
        return parse_branch_lcov(inp.text, inp.origin)
    raise Error(String("unknown report format ") + inp.format)


def _unmapped(origin: String, raw: String, tried: String) -> String:
    return origin + String(": ") + raw + String(" (looked for ") + tried + String(")")


def _stats_at(mut a: Analysis, mut at: Dict[String, Int], package: String) raises -> Int:
    if package not in at:
        at[package] = len(a.packages)
        a.packages.append(PackageStats(package))
    return at[package]


def _keep(package: String, path: String, opts: Options) -> Int:
    """0 keep, 1 another package (gate), 2 a test source left out."""
    if opts.only_package.byte_length() > 0 and package != opts.only_package:
        return 1
    if not opts.include_tests and (is_test_source(path, package) or path in opts.test_sources):
        return 2
    return 0


def _generated_path(path: String, repo: RepoFiles, sources: Sources, opts: Options, mut seen: Dict[String, Bool]) raises -> Bool:
    """Whether `path` is a kept file whose source marks itself generated
    (generated.mojo). A file `_keep` sets aside is not read; a source that
    cannot be read is not generated here (the step that needs it raises)."""
    if path in seen:
        return seen[path]
    var pkg = _package_or_empty(path, repo)
    var gen = False
    if pkg.byte_length() > 0 and path.endswith(".mojo") and _keep(pkg, path, opts) == 0:
        try:
            gen = is_generated(sources.read(path))
        except:
            gen = False
    seen[path] = gen
    return gen


def _package_or_empty(path: String, repo: RepoFiles) -> String:
    try:
        return package_of(path, repo)
    except:
        return String("")


def _unmeasured_files(
    mut a: Analysis,
    mut at: Dict[String, Int],
    mut exemptions: List[Exemption],
    measured: Dict[String, Bool],
    named: Dict[String, Bool],
    pending: Dict[String, FileCov],
    repo: RepoFiles,
    sources: Sources,
    opts: Options,
    mut notes: List[Finding],
    mut skipped: Dict[String, Bool],
    left_lines: Dict[String, Dict[Int, Bool]],
) raises -> List[Finding]:
    """Step 4's full source: counts every file of a `measured` package that
    is not `named` (no line report gives it a record), with the branches
    `pending` holds for it (branch record files'); returns their
    `UnmeasuredFile` findings, and adds a `DeclarationOnlyFile` to `notes`
    for each declaration-only file it counts nothing of."""
    var paths = List[String]()
    for e in repo.files.items():
        var path = e.key
        if not path.endswith(".mojo") or path in named:
            continue
        var pkg = _package_or_empty(path, repo)
        if pkg.byte_length() == 0 or pkg not in measured or _keep(pkg, path, opts) != 0:
            continue
        paths.append(path)
    sort_strings(paths)
    var out = List[Finding]()
    for i in range(len(paths)):
        var pkg = package_of(paths[i], repo)
        var text = sources.read(paths[i])
        if is_generated(text):
            skipped[paths[i]] = True
            continue
        var f = FileCov(paths[i])
        var exe = executable_lines(text)
        var markers = scan_markers(paths[i], text)
        if len(exe) > 0 and len(markers) == 0 and paths[i] not in pending and declaration_only(text):
            notes.append(Finding(
                String(DECLARATION_ONLY_FILE), pkg, String(""), -1, -1, paths[i], 0,
                String("UnmeasuredFile (declaration-only): no test binary compiled this file, and it declares only traits whose methods have no body, comptime values and imports, which emit no code: its ")
                + String(len(exe)) + String(" executable lines by the heuristic are not counted"),
                len(exe),
            ))
            continue
        # The lines the uncompiled report left out (uncompiled.mojo) are left out here too: the two
        # passes count one file the same way.
        for k in range(len(exe)):
            if paths[i] in left_lines and exe[k] in left_lines[paths[i]]:
                continue
            f.add_line(exe[k], 0)
        if paths[i] in pending:
            f.absorb(pending[paths[i]])
        var branches = f.branch_found()
        var removed = apply_exemptions(f, markers)
        for e in range(len(markers)):
            exemptions.append(markers[e].copy())
        var found = f.line_found()
        if found == 0 and len(markers) == 0 and branches == 0:
            continue
        var k = _stats_at(a, at, pkg)
        a.packages[k].files += 1
        if branches > 0:
            a.packages[k].has_branch_records = True
        a.packages[k].branch_found += f.branch_found()
        a.packages[k].branch_hit += f.branch_hit()
        a.packages[k].exempt_lines += removed
        a.packages[k].line_found += found
        if found > 0:
            a.packages[k].unmeasured_files += 1
            # Its branch records may show it ran: then the line and branch
            # measurements disagree, and the finding says so.
            var taken = f.branch_hit()
            var why = String("no test binary compiled this file: its ")
            if taken > 0:
                why = (
                    String("no line report names this file, yet its branch records show ") + String(taken)
                    + String(" arm(s) taken: the line and branch measurements disagree on whether it ran; its ")
                )
            out.append(Finding(
                String(UNMEASURED_FILE), pkg, String(""), -1, -1, paths[i], 0,
                why + String(found) + String(" executable lines count as not covered"),
                found,
            ))
        a.files.append(f^)
        a.file_packages.append(pkg)
        a.unmeasured.append(True)
    return out^


def _below(package: String, metric: String, bp: Int, target: Int, held: Bool) -> Finding:
    """BelowTarget, or a Regression when the package holds `metric`."""
    var why = metric + String(" ") + render_bp(bp) + String(" is below the target ") + render_bp(target)
    if held:
        return Finding(String(REGRESSION), package, metric, bp, target, String(""), 0, why + String(", which coverage_held holds it at"))
    return Finding(String(BELOW_TARGET), package, metric, bp, target, String(""), 0, why)


def _reached(package: String, metric: String, bp: Int, target: Int) -> Finding:
    return Finding(
        String(REACHED_TARGET), package, metric, bp, target, String(""), 0,
        metric + String(" ") + render_bp(bp) + String(" reaches the target ") + render_bp(target)
        + String(": hold it, adding `") + metric + String("` to ") + package + String("/coverage_held, once every library of the package reaches it"),
    )


def _package_texts(pkg: String, repo: RepoFiles, sources: Sources) -> Dict[String, String]:
    """The sources of `pkg` (`.mojo` files of its directory tree, tests included), by path; a file that cannot be
    read is left out."""
    var texts = Dict[String, String]()
    for e in repo.files.items():
        if not e.key.endswith(".mojo") or _package_or_empty(e.key, repo) != pkg:
            continue
        try:
            texts[e.key] = sources.read(e.key)
        except:
            pass
    return texts^


def _platform_gate(
    reports: List[Input],
    mapped: List[FileCov],
    repo: RepoFiles,
    sources: Sources,
    opts: Options,
    mut a: Analysis,
    mut gated_lines: Dict[String, Dict[Int, Bool]],
    called: Dict[String, Evidence],
) raises:
    """Finds the platform-gated functions among those of the uncompiled line reports (platform_gate.mojo): fills
    `gated_lines` with their own lines per path and `a.platform_gated` with each, in path and line order."""
    # The lines each file has in the uncompiled line reports.
    var unc = Dict[String, Dict[Int, Bool]]()
    for r in range(len(reports)):
        if not is_uncompiled_report(reports[r].origin) or reports[r].format == String(FORMAT_BRANCH_LCOV):
            continue
        var fs = _parse_report(reports[r])
        for i in range(len(fs)):
            var m = map_path(fs[i].path, reports[r].pkgdir, opts.strip_prefixes, repo)
            if m.kind != MAPPED:
                continue
            if m.path not in unc:
                unc[m.path] = Dict[Int, Bool]()
            for e in fs[i].hits.items():
                unc[m.path][e.key] = True
    if len(unc) == 0:
        return
    # The lines the tests' reports give a record, per path.
    var recorded = Dict[String, Dict[Int, Bool]]()
    for i in range(len(mapped)):
        if mapped[i].path not in recorded:
            recorded[mapped[i].path] = Dict[Int, Bool]()
        for e in mapped[i].hits.items():
            recorded[mapped[i].path][e.key] = True
    # The candidates by package, with each one's own lines (to leave out).
    var by_pkg = Dict[String, List[Cand]]()
    var own_of = Dict[String, List[Int]]()
    var pkg_names = List[String]()
    var pkg_dups = Dict[String, Dict[String, Bool]]()
    var unc_paths = List[String]()
    for e in unc.items():
        unc_paths.append(e.key)
    sort_strings(unc_paths)
    for pi in range(len(unc_paths)):
        var path = unc_paths[pi]
        var pkg = _package_or_empty(path, repo)
        if pkg.byte_length() == 0:
            continue
        var src = sources.read(path)
        var fns = declared_functions(src)
        # What the call evidence leaves out already is not reported a second time.
        if pkg not in pkg_dups:
            pkg_dups[pkg] = declared_twice(_package_texts(pkg, repo, sources))
        var pcalled = Evidence()
        if pkg in called:
            pcalled = called[pkg].copy()
        var by_evidence = unreliable_lines(src, path, pcalled, pkg_dups[pkg])
        for k in range(len(fns)):
            var own = List[Int]()
            var evidenced = True
            for q in range(len(fns[k].lines)):
                if fns[k].lines[q] in unc[path]:
                    own.append(fns[k].lines[q])
                    if fns[k].lines[q] not in by_evidence:
                        evidenced = False
            if len(own) == 0 or evidenced:
                continue
            if pkg not in by_pkg:
                by_pkg[pkg] = List[Cand]()
                pkg_names.append(pkg)
            by_pkg[pkg].append(Cand(path, fns[k].name, fns[k].line, len(own)))
            own_of[path + String(":") + String(fns[k].line)] = own^
    sort_strings(pkg_names)
    for pk in range(len(pkg_names)):
        var pkg = pkg_names[pk]
        # The package's sources, tests included: the call sites are searched there.
        var texts = _package_texts(pkg, repo, sources)
        var flags = platform_gated(texts, recorded, by_pkg[pkg])
        for c in range(len(flags)):
            if not flags[c]:
                continue
            ref cand = by_pkg[pkg][c]
            a.platform_gated.append(GatedFunction(pkg, cand.path, cand.name, cand.line, cand.lines))
            var own = own_of[cand.path + String(":") + String(cand.line)].copy()
            if cand.path not in gated_lines:
                gated_lines[cand.path] = Dict[Int, Bool]()
            for q in range(len(own)):
                gated_lines[cand.path][own[q]] = True


def analyze(
    reports: List[Input],
    mutant_inputs: List[Input],
    repo: RepoFiles,
    held: Held,
    sources: Sources,
    opts: Options,
) raises -> Analysis:
    """See the module header. Raises on malformed input and on unmapped
    paths (every one named)."""
    var a = Analysis()
    a.mode = opts.mode
    a.target_bp = opts.target_bp
    a.info_dirs = opts.info_packages.copy()
    var errors = List[String]()
    var first_line = -1
    for r in range(len(reports)):
        if reports[r].format == String(FORMAT_BRANCH_LCOV):
            continue
        if first_line < 0:
            first_line = r
        elif reports[r].format != reports[first_line].format:
            raise Error(
                String("the reports mix ") + reports[first_line].format + String(" (") + reports[first_line].origin + String(") and ")
                + reports[r].format + String(" (") + reports[r].origin
                + String("): the formats identify branches differently, so give one format")
            )

    # 1-2: read, map, merge. A branch record file's files are kept apart
    # (`bmapped`, `borigins`) until the checks below.
    var mapped = List[FileCov]()
    var bmapped = List[FileCov]()
    var borigins = List[String]()
    # A repository path's first line report with a branch record for it.
    var line_branches = Dict[String, String]()
    var outside = Dict[String, Bool]()
    var generated = Dict[String, Bool]()
    # The code no test compiled (uncompiled.mojo) is read after every other report: what it may leave out
    # needs the evidence the others give (the lines a test hit that call a function).
    # The calls the hit lines make, per package (a call in another package is no evidence), and the function names
    # each package declares more than once.
    var called = Dict[String, Evidence]()
    var dups_of = Dict[String, Dict[String, Bool]]()
    # What the uncompiled report left out, per path, and the lines of it (the files-no-test-compiled
    # pass leaves them out too).
    var left_lines = Dict[String, Dict[Int, Bool]]()
    var excluded_at = Dict[String, Int]()
    var any_uncompiled = False
    for r in range(len(reports)):
        if is_uncompiled_report(reports[r].origin):
            any_uncompiled = True
    for pass_no in range(2 if any_uncompiled else 1):
      if pass_no == 1:
        var hit_of = Dict[String, Dict[Int, Bool]]()
        for i in range(len(mapped)):
            for e in mapped[i].hits.items():
                if e.value > 0:
                    if mapped[i].path not in hit_of:
                        hit_of[mapped[i].path] = Dict[Int, Bool]()
                    hit_of[mapped[i].path][e.key] = True
        for e in hit_of.items():
            # A hit line of a file whose source is not here (a test's generated main) gives no evidence.
            try:
                var cpkg = _package_or_empty(e.key, repo)
                if cpkg not in called:
                    called[cpkg] = Evidence()
                called[cpkg].add(e.key, sources.read(e.key), e.value)
            except:
                pass
      var gated_lines = Dict[String, Dict[Int, Bool]]()
      if pass_no == 1:
        _platform_gate(reports, mapped, repo, sources, opts, a, gated_lines, called)
      for r in range(len(reports)):
        if is_uncompiled_report(reports[r].origin) != (pass_no == 1):
            continue
        var fs = _parse_report(reports[r])
        var branch_file = reports[r].format == String(FORMAT_BRANCH_LCOV)
        # The repository paths this branch record file names: two spellings
        # of one would sum one test's arms twice.
        var once = Dict[String, Bool]()
        for i in range(len(fs)):
            var m = map_path(fs[i].path, reports[r].pkgdir, opts.strip_prefixes, repo)
            if m.kind == MAPPED:
                var f = fs[i].copy()
                f.path = m.path
                if pass_no == 1:
                    # Buildrules' report of the code no test compiled: what a test was seen to
                    # call, and is inlined or dropped on this platform, is left out (uncompiled.mojo).
                    var dpkg = _package_or_empty(m.path, repo)
                    if dpkg not in dups_of:
                        dups_of[dpkg] = declared_twice(_package_texts(dpkg, repo, sources))
                    var dcalled = Evidence()
                    if dpkg in called:
                        dcalled = called[dpkg].copy()
                    var d = drop_unreliable(f, sources.read(m.path), m.path, dcalled, dups_of[dpkg])
                    if d.lines > 0 or d.arms > 0:
                        if m.path not in excluded_at:
                            excluded_at[m.path] = len(a.excluded)
                            a.excluded.append(ExcludedFile(_package_or_empty(m.path, repo), m.path))
                        a.excluded[excluded_at[m.path]].lines += d.lines
                        a.excluded[excluded_at[m.path]].arms += d.arms
                    if m.path in gated_lines:
                        var g = drop_lines(f, gated_lines[m.path])
                        a.platform_gated_arms += g.arms
                        if g.lines > 0:
                            if m.path not in left_lines:
                                left_lines[m.path] = Dict[Int, Bool]()
                            for e in g.line_set.items():
                                left_lines[m.path][e.key] = True
                    if d.lines > 0:
                        if m.path not in left_lines:
                            left_lines[m.path] = Dict[Int, Bool]()
                        for e in d.line_set.items():
                            left_lines[m.path][e.key] = True
                    if f.line_found() == 0 and f.branch_found() == 0:
                        continue
                if branch_file:
                    if m.path in once:
                        raise Error(
                            reports[r].origin + String(": SF ") + fs[i].path + String(" is ") + m.path
                            + String(", which an earlier SF of this file names: one test's records would be counted twice")
                        )
                    once[m.path] = True
                    bmapped.append(f^)
                    borigins.append(reports[r].origin)
                    continue
                if f.branch_found() > 0 and m.path not in line_branches:
                    line_branches[m.path] = reports[r].origin
                mapped.append(f^)
            elif m.kind == OUTSIDE:
                outside[fs[i].path] = True
            elif generated_test_main(reports[r].origin, m.path, repo):
                generated[m.path] = True
            else:
                errors.append(_unmapped(reports[r].origin, fs[i].path, m.path))
    a.ignored_files = len(outside)
    # A test's generated main has no source to measure, with or without
    # `include_tests`: a test source left out of its package's numbers.
    for e in generated.items():
        var p = e.key
        if _keep(_package_or_empty(p, repo), p, opts) != 1:
            a.excluded_test_files += 1

    # 5 (read first, so every unmapped path of every input is named at once).
    var muts = List[Mutant]()
    for r in range(len(mutant_inputs)):
        var ms = parse_mutants(mutant_inputs[r].text, mutant_inputs[r].origin)
        for i in range(len(ms)):
            var m = map_path(ms[i].path, mutant_inputs[r].pkgdir, opts.strip_prefixes, repo)
            if m.kind == MAPPED:
                var mu = ms[i].copy()
                mu.path = m.path
                muts.append(mu^)
            elif m.kind == OUTSIDE:
                a.ignored_mutants += 1
            else:
                errors.append(_unmapped(mutant_inputs[r].origin, ms[i].path, m.path))
    if len(errors) > 0:
        raise Error(String("unmapped paths (each names a repository directory but no repository file):\n  ") + join(errors, String("\n  ")))

    # Generated sources (generated.mojo) leave every list: no record of one
    # is read, whether a test reached it or not.
    var left_out = Dict[String, Bool]()
    var seen = Dict[String, Bool]()
    var line_kept = List[FileCov]()
    for i in range(len(mapped)):
        if _generated_path(mapped[i].path, repo, sources, opts, seen):
            left_out[mapped[i].path] = True
        else:
            line_kept.append(mapped[i].copy())
    mapped = line_kept^
    var branch_kept = List[FileCov]()
    var origins_kept = List[String]()
    for i in range(len(bmapped)):
        if _generated_path(bmapped[i].path, repo, sources, opts, seen):
            left_out[bmapped[i].path] = True
        else:
            branch_kept.append(bmapped[i].copy())
            origins_kept.append(borigins[i])
    bmapped = branch_kept^
    borigins = origins_kept^
    var muts_kept = List[Mutant]()
    for i in range(len(muts)):
        if _generated_path(muts[i].path, repo, sources, opts, seen):
            left_out[muts[i].path] = True
        else:
            muts_kept.append(muts[i].copy())
    muts = muts_kept^

    # The checks of the branch records, over the files kept (step 3): a
    # file left out counts nowhere, so its records are not checked.
    var shapes = DecisionShapes()
    # The packages a branch record file names a kept file of: their files
    # with line records must each be named by one (BranchUnmeasuredFile).
    var branch_pkgs = Dict[String, Bool]()
    var bkept = List[Int]()
    for i in range(len(bmapped)):
        var bpkg = _package_or_empty(bmapped[i].path, repo)
        if bpkg.byte_length() == 0 or _keep(bpkg, bmapped[i].path, opts) != 0:
            continue
        branch_pkgs[bpkg] = True
        if bmapped[i].path in line_branches and bmapped[i].branch_found() > 0:
            raise Error(
                bmapped[i].path + String(": branch records come from both the line report ") + line_branches[bmapped[i].path]
                + String(" and the branch record file ") + borigins[i]
                + String(": give one source of branch data per file (they identify branches differently)")
            )
        bkept.append(i)
    # Where tests' copies of one location hold different numbers of
    # decisions, only the tests with the most count there.
    drop_smaller_copies(bmapped, bkept)
    for i in bkept:
        shapes.add(bmapped[i], borigins[i])
    var bmerged = merge_by_path(bmapped^)
    var branch_of = Dict[String, Int]()
    for i in range(len(bmerged)):
        branch_of[bmerged[i].path] = i
    var merged = merge_by_path(mapped^)
    # A path only a branch record file names joins the list with its
    # branches alone (no line record: counted from its source below).
    var in_lines = Dict[String, Bool]()
    for i in range(len(merged)):
        in_lines[merged[i].path] = True
    for i in range(len(bmerged)):
        if bmerged[i].path not in in_lines:
            merged.append(FileCov(bmerged[i].path))

    # 3-4, 6: packages, test sources, exemptions, counts.
    var at = Dict[String, Int]()
    var exemptions = List[Exemption]()
    var measured = Dict[String, Bool]()
    if opts.only_package.byte_length() > 0:
        measured[opts.only_package] = True
    for e in held.packages.items():
        if not repo.has_buck(e.key):
            raise Error(String("coverage_held of ") + e.key + String(": the directory has no BUCK file"))
        if _keep(e.key, e.key + String("/BUCK"), opts) == 0:
            measured[e.key] = True
    var named = Dict[String, Bool]()
    var pending = Dict[String, FileCov]()
    var branch_unmeasured = List[Finding]()
    var unrecorded = List[UnrecordedFunction]()
    for i in range(len(merged)):
        var pkg = package_of(merged[i].path, repo)
        var keep = _keep(pkg, merged[i].path, opts)
        if keep == 2:
            a.excluded_test_files += 1
        if keep != 0:
            continue
        measured[pkg] = True
        var path = merged[i].path
        if merged[i].line_found() == 0 and merged[i].branch_found() == 0:
            # Named with no record (an lcov `SF:` straight to
            # `end_of_record`, a Cobertura class with no line, a file only a
            # branch record file names): no line of it was measured, so its
            # source is counted as a file no test compiled, with the
            # branches of the branch record files. The package is in the
            # run all the same (NotMeasured if no other file gives it a
            # line record).
            var kp = _stats_at(a, at, pkg)
            if path in branch_of:
                a.packages[kp].has_branch_records = True
                pending[path] = bmerged[branch_of[path]].copy()
            continue
        named[path] = True
        # A file with line records in a package whose branch records are
        # read, that no branch record file names (and whose line report
        # gives no branch of its own): cov_branch_classify names every
        # measured file its test holds code of, so this one's branches were
        # not read, and counting it as 0 of 0 would lift the package's
        # branch number.
        if pkg in branch_pkgs and path not in branch_of and path not in line_branches and merged[i].line_found() > 0:
            branch_unmeasured.append(Finding(
                String(BRANCH_UNMEASURED_FILE), pkg, String(""), -1, -1, path, 0,
                String("a line report names this file, but no branch record file of its package does: its branches were")
                + String(" not measured (cov_branch_classify names every measured file its test holds code of), so the")
                + String(" package's branch numbers leave it out"),
            ))
        var f = merged[i].copy()
        if path in branch_of:
            f.absorb(bmerged[branch_of[path]])
        var text = sources.read(f.path)
        var markers = scan_markers(f.path, text)
        # 9: before the exemptions take any record away; only with line
        # records (branch records alone say nothing about lines).
        if f.line_found() > 0:
            var marked = Dict[Int, Bool]()
            for e in range(len(markers)):
                # A marker without a reason exempts nothing (exempt.mojo).
                if markers[e].reason.byte_length() > 0:
                    marked[markers[e].line] = True
            var fns = unrecorded_functions(text, f.hits, marked)
            for k in range(len(fns)):
                unrecorded.append(UnrecordedFunction(pkg, path, fns[k].line, fns[k].name, fns[k].kind, len(fns[k].lines)))
        var branches = f.branch_found()
        var removed = apply_exemptions(f, markers)
        var k = _stats_at(a, at, pkg)
        a.packages[k].files += 1
        # A file a branch record file names, with or without arms
        # (cov_branch_classify names every measured file the test holds
        # code of), has its branches measured.
        if branches > 0 or path in branch_of:
            a.packages[k].has_branch_records = True
        if f.line_found() > 0 or removed > 0:
            a.packages[k].has_records = True
        a.packages[k].exempt_lines += removed
        a.packages[k].line_found += f.line_found()
        a.packages[k].line_hit += f.line_hit()
        a.packages[k].branch_found += f.branch_found()
        a.packages[k].branch_hit += f.branch_hit()
        for e in range(len(markers)):
            exemptions.append(markers[e].copy())
        a.files.append(f^)
        a.file_packages.append(pkg)
        a.unmeasured.append(False)
    var decl_notes = List[Finding]()
    var unmeasured_findings = _unmeasured_files(a, at, exemptions, measured, named, pending, repo, sources, opts, decl_notes, left_out, left_lines)
    var left_keys = List[String]()
    for e in left_out.items():
        left_keys.append(e.key)
    sort_strings(left_keys)
    a.generated_paths = left_keys^
    var mut_pkgs = List[String]()
    var kept_muts = List[Mutant]()
    for i in range(len(muts)):
        var pkg = package_of(muts[i].path, repo)
        var keep = _keep(pkg, muts[i].path, opts)
        if keep == 2:
            a.excluded_test_mutants += 1
        if keep != 0:
            continue
        var k = _stats_at(a, at, pkg)
        a.packages[k].mutants += 1
        if muts[i].status == String(KILLED):
            a.packages[k].killed += 1
        elif muts[i].status == String(SURVIVED):
            a.packages[k].survived += 1
        elif muts[i].status == String(TIMEOUT):
            a.packages[k].timeout += 1
        else:
            a.packages[k].error += 1
        kept_muts.append(muts[i].copy())
        mut_pkgs.append(pkg)
    # The gated package and each held one are in the run, measured or not.
    for e in measured.items():
        _ = _stats_at(a, at, e.key)

    # Sorted outputs.
    var pkeys = List[String]()
    for i in range(len(a.packages)):
        pkeys.append(a.packages[i].package)
    var porder = sort_by_keys(pkeys)
    var sorted_pkgs = List[PackageStats]()
    for i in range(len(porder)):
        var p = a.packages[porder[i]].copy()
        p.held_line = held.line(p.package)
        p.held_branch = held.branch(p.package)
        sorted_pkgs.append(p^)
    a.packages = sorted_pkgs^
    var ekeys = List[String]()
    for i in range(len(exemptions)):
        ekeys.append(line_key(exemptions[i].path, exemptions[i].line))
    var eorder = sort_by_keys(ekeys)
    for i in range(len(eorder)):
        a.exemptions.append(exemptions[eorder[i]].copy())
    var mkeys = List[String]()
    for i in range(len(kept_muts)):
        mkeys.append(line_key(kept_muts[i].path, kept_muts[i].line))
    var morder = sort_by_keys(mkeys)
    for i in range(len(morder)):
        a.mutants.append(kept_muts[morder[i]].copy())
        a.mutant_packages.append(mut_pkgs[morder[i]])
    var ukeys = List[String]()
    for i in range(len(unrecorded)):
        ukeys.append(line_key(unrecorded[i].path, unrecorded[i].line))
    var uorder = sort_by_keys(ukeys)
    for i in range(len(uorder)):
        a.unrecorded_functions.append(unrecorded[uorder[i]].copy())
    var xkeys = List[String]()
    for i in range(len(a.excluded)):
        xkeys.append(a.excluded[i].path)
    var xorder = sort_by_keys(xkeys)
    var xsorted = List[ExcludedFile]()
    for i in range(len(xorder)):
        xsorted.append(a.excluded[xorder[i]].copy())
    a.excluded = xsorted^
    var gkeys = List[String]()
    for i in range(len(a.platform_gated)):
        gkeys.append(line_key(a.platform_gated[i].path, a.platform_gated[i].line))
    var gorder = sort_by_keys(gkeys)
    var gsorted = List[GatedFunction]()
    for i in range(len(gorder)):
        gsorted.append(a.platform_gated[gorder[i]].copy())
    a.platform_gated = gsorted^

    # 7: findings.
    var findings = List[Finding]()
    var reached = List[Finding]()
    var t = opts.target_bp
    for i in range(len(a.packages)):
        ref p = a.packages[i]
        var lbp = p.line_bp()
        var bbp = p.branch_bp()
        # A gated library with nothing to cover holds nothing unmeasured.
        var nothing = opts.only_package.byte_length() > 0 and p.line_found == 0 and p.exempt_lines == 0
        var info = is_info_package(p.package, opts.info_packages)
        if p.held_line and lbp < 0 and p.exempt_lines == 0 and not nothing and t > 0:
            findings.append(Finding(
                String(REGRESSION), p.package, String("line"), -1, t, String(""), 0,
                String("line is held (coverage_held) and no line of this package was measured (no report for it, or none of its paths mapped to it)"),
            ))
        elif not p.has_records and t > 0:
            findings.append(Finding(
                String(NOT_MEASURED), p.package, String("line"), -1, t, String(""), 0,
                String("no line of this package was measured (no report for it, or none of its paths mapped to it)"),
            ))
        if lbp >= 0 and lbp < t:
            findings.append(_below(p.package, String("line"), lbp, t, p.held_line))
        elif lbp >= 0 and t > 0 and not p.held_line and not info:
            reached.append(_reached(p.package, String("line"), lbp, t))
        if p.held_branch and not p.has_branch_records and not nothing and t > 0:
            findings.append(Finding(
                String(REGRESSION), p.package, String("branch"), -1, t, String(""), 0,
                String("branch is held (coverage_held) and no branch of this package was measured (no report names a file of it with branch records)"),
            ))
        elif p.has_records and not p.has_branch_records and t > 0:
            findings.append(Finding(
                String(BRANCH_NOT_MEASURED), p.package, String("branch"), -1, t, String(""), 0,
                String("no branch of this package was measured (no report names a file of it with branch records:")
                + String(" kcov's Cobertura holds none, and a gate reads its tests' branch records only for a library of")
                + String(" COVERAGE_BRANCH_GATE, tools/build/coverage/policy.bzl): its branch coverage cannot be shown to meet the target"),
            ))
        if bbp >= 0 and bbp < t:
            findings.append(_below(p.package, String("branch"), bbp, t, p.held_branch))
        elif bbp >= 0 and t > 0 and not p.held_branch and not info:
            reached.append(_reached(p.package, String("branch"), bbp, t))
    for i in range(len(unmeasured_findings)):
        findings.append(unmeasured_findings[i].copy())
    for i in range(len(branch_unmeasured)):
        findings.append(branch_unmeasured[i].copy())
    for i in range(len(a.mutants)):
        ref m = a.mutants[i]
        if m.status == String(SURVIVED):
            findings.append(Finding(
                String(MUTANT_SURVIVED), a.mutant_packages[i], String(""), -1, -1, m.path, m.line,
                String("mutant survived: ") + m.operator + (String(": ") + m.description if m.description.byte_length() > 0 else String("")),
            ))
    for i in range(len(a.exemptions)):
        ref e = a.exemptions[i]
        var pkg = package_of(e.path, repo)
        if e.status == String(STATUS_NO_REASON):
            findings.append(Finding(
                String(EXEMPTION_WITHOUT_REASON), pkg, String(""), -1, -1, e.path, e.line,
                String("a coverage exemption with no reason"),
            ))
        elif e.status == String(STATUS_STALE):
            findings.append(Finding(
                String(STALE_EXEMPTION), pkg, String(""), -1, -1, e.path, e.line,
                String("a coverage exemption on a line the tests execute"),
            ))
    var fkeys = List[String]()
    for i in range(len(findings)):
        fkeys.append(
            findings[i].package + String("\x00") + line_key(findings[i].path, findings[i].line)
            + String("\x00") + findings[i].kind + String("\x00") + findings[i].metric
        )
    var forder = sort_by_keys(fkeys)
    # 8: a test-only package's findings are information.
    for i in range(len(forder)):
        if is_info_package(findings[forder[i]].package, opts.info_packages):
            a.info_findings.append(findings[forder[i]].copy())
        else:
            a.findings.append(findings[forder[i]].copy())
    # A metric to hold, then declaration-only files: information in every
    # package.
    for i in range(len(reached)):
        a.info_findings.append(reached[i].copy())
    for i in range(len(decl_notes)):
        a.info_findings.append(decl_notes[i].copy())
    for i in range(len(a.packages)):
        if is_info_package(a.packages[i].package, opts.info_packages):
            a.info_packages.append(a.packages[i].package)

    for i in range(len(a.packages)):
        ref p = a.packages[i]
        a.total.files += p.files
        a.total.line_found += p.line_found
        a.total.line_hit += p.line_hit
        a.total.branch_found += p.branch_found
        a.total.branch_hit += p.branch_hit
        a.total.exempt_lines += p.exempt_lines
        a.total.mutants += p.mutants
        a.total.killed += p.killed
        a.total.survived += p.survived
        a.total.timeout += p.timeout
        a.total.error += p.error
    # Step 10: a test-only package's findings are in info_findings, so they
    # fail nothing.
    var regressions = 0
    for i in range(len(a.findings)):
        if a.findings[i].kind == String(REGRESSION):
            regressions += 1
    a.conclusion = conclusion_of(opts.mode, len(a.findings), regressions)
    return a^
