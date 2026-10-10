"""The numbers of one package, and the findings drawn from them.

Every percentage is an integer number of basis points (1/100 of a percent),
`hit * 10000 // found`, rounded down; -1 stands for n/a (nothing measured).
"""

from covcheck.text import basis_points

comptime MODE_CENSUS = "census"
comptime MODE_NEUTRAL = "neutral"
comptime MODE_ENFORCE = "enforce"

comptime BELOW_TARGET = "BelowTarget"
comptime NOT_MEASURED = "NotMeasured"
comptime BRANCH_NOT_MEASURED = "BranchNotMeasured"
comptime REGRESSION = "Regression"
comptime MISSING_ROW = "MissingRow"
comptime EXTRA_ROW = "ExtraRow"
comptime BRANCH_FLOOR_MISSING = "BranchFloorMissing"
comptime MUTANT_SURVIVED = "MutantSurvived"
comptime EXEMPTION_WITHOUT_REASON = "ExemptionWithoutReason"
comptime STALE_EXEMPTION = "StaleExemption"
comptime UNMEASURED_FILE = "UnmeasuredFile"
comptime BRANCH_UNMEASURED_FILE = "BranchUnmeasuredFile"
comptime DECLARATION_ONLY_FILE = "DeclarationOnlyFile"

comptime NO_FLOOR: Int = -1


struct PackageStats(Copyable, Movable):
    """What was measured in one package, after test sources were set aside
    and exemptions applied, and the package's ratchet row. `files` counts
    every file in the numbers, the files no report gave a record included;
    `unmeasured_files` those of them that raised `UnmeasuredFile`; `has_records` is whether a report had a line record (or an
    exempted line) in the package at all; `has_branch_records` whether a
    report had a branch record in it (before exemptions)."""

    var package: String
    var files: Int
    var unmeasured_files: Int
    var has_records: Bool
    var has_branch_records: Bool
    var line_found: Int
    var line_hit: Int
    var branch_found: Int
    var branch_hit: Int
    var exempt_lines: Int
    var mutants: Int
    var killed: Int
    var survived: Int
    var timeout: Int
    var error: Int
    var has_row: Bool
    var line_floor: Int
    var branch_floor: Int

    def __init__(out self, package: String):
        self.package = package
        self.files = 0
        self.unmeasured_files = 0
        self.has_records = False
        self.has_branch_records = False
        self.line_found = 0
        self.line_hit = 0
        self.branch_found = 0
        self.branch_hit = 0
        self.exempt_lines = 0
        self.mutants = 0
        self.killed = 0
        self.survived = 0
        self.timeout = 0
        self.error = 0
        self.has_row = False
        self.line_floor = NO_FLOOR
        self.branch_floor = NO_FLOOR

    def line_bp(self) -> Int:
        """Line coverage in basis points; -1 when no line was measured."""
        return basis_points(self.line_hit, self.line_found)

    def branch_bp(self) -> Int:
        """Branch coverage in basis points; -1 when the package has no
        branch record."""
        return basis_points(self.branch_hit, self.branch_found)

    def mutation_bp(self) -> Int:
        """Killed mutants per mutant in basis points; -1 with no mutant."""
        return basis_points(self.killed, self.mutants)


struct Finding(Copyable, Movable):
    """One reason a package (or a line of it) misses the policy.

    `metric` is `line`, `branch` or empty; `measured` and `bound` are basis
    points (the target or the floor) or -1 when they do not apply; `path`
    and `line` place the finding in a file (line 0: the whole file), or are
    empty and 0; `count` is the number of lines an `UnmeasuredFile` counts
    uncovered, or a `DeclarationOnlyFile` would have counted, -1 for every
    other finding."""

    var kind: String
    var package: String
    var metric: String
    var measured: Int
    var bound: Int
    var path: String
    var line: Int
    var message: String
    var count: Int

    def __init__(
        out self,
        kind: String,
        package: String,
        metric: String,
        measured: Int,
        bound: Int,
        path: String,
        line: Int,
        message: String,
        count: Int = -1,
    ):
        self.kind = kind
        self.package = package
        self.metric = metric
        self.measured = measured
        self.bound = bound
        self.path = path
        self.line = line
        self.message = message
        self.count = count


def is_info_package(package: String, dirs: List[String]) -> Bool:
    """Whether `package` is one of `dirs` (`--info-package`, a test-only
    package's directory) or under one, at a path-segment boundary: `src/tests`
    covers `src/tests/e2e/x`, not `src/testsuite`."""
    for i in range(len(dirs)):
        if package == dirs[i] or package.startswith(dirs[i] + String("/")):
            return True
    return False


def valid_mode(mode: String) -> Bool:
    return mode == String(MODE_CENSUS) or mode == String(MODE_NEUTRAL) or mode == String(MODE_ENFORCE)


def conclusion_of(mode: String, findings: Int, regressions: Int) -> String:
    """The check run's conclusion: `failure` with any `Regression` (a
    ratchet floor holds in every mode, so coverage can only go up);
    otherwise `neutral` in census and neutral mode whatever was found, and
    in enforce mode `failure` with any finding, else `success`."""
    if regressions > 0:
        return String("failure")
    if mode != String(MODE_ENFORCE):
        return String("neutral")
    if findings > 0:
        return String("failure")
    return String("success")
