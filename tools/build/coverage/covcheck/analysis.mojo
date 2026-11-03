"""The inputs and the result of one analysis (analyze.mojo): the report
formats, an input file's text, the options, the source reader and what
the run measured and found. analyze.mojo imports them, so a caller may
import them from either module."""

from covcheck.exempt import Exemption
from covcheck.model import FileCov
from covcheck.mutants import Mutant
from covcheck.stats import MODE_NEUTRAL, Finding, PackageStats
from covcheck.text import read_text

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
    # Repository paths of the entry points of the program targets a test target of their package
    # depends on (programs.parse_program_targets; step 3c).
    var program_runs: Dict[String, Bool]

    def __init__(out self):
        self.mode = String(MODE_NEUTRAL)
        self.target_bp = 10000
        self.include_tests = False
        self.only_package = String("")
        self.strip_prefixes = List[String]()
        self.test_sources = Dict[String, Bool]()
        self.info_packages = List[String]()
        self.program_runs = Dict[String, Bool]()


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
    # Repository paths of the program sources left out (programs.mojo, step 3c), sorted.
    var program_paths: List[String]
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
        self.program_paths = List[String]()
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
