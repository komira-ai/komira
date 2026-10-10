"""The questions the mapping asks of the repository, and the answers from
buck2 and git.

`Graph` is the seam: `plan.compute` is a pure function over it, the unit
tests answer it from tables, and `BuckGraph` answers it from the real tree.
"""

from std.os.path import exists

from buildtools.bytes import dirname, join, substr, suffix
from buildtools.json import flatten_document

from change_map.cells import Cells
from change_map.labels import normalize_label
from change_map.process import Captured, lines_of, run_captured

comptime PACKAGE_FOUND: Int = 1
comptime PACKAGE_NONE: Int = 0
comptime PACKAGE_UNKNOWN: Int = 2


struct PackageOf(Copyable, Movable):
    """The package a file belonged to: `status` is PACKAGE_FOUND (`dir` is
    its directory, "" for the root package), PACKAGE_NONE (no package held
    the file) or PACKAGE_UNKNOWN (the tree it was asked of is not available)."""

    var status: Int
    var dir: String

    def __init__(out self, status: Int, var dir: String = String("")):
        self.status = status
        self.dir = dir^


trait Graph:
    """What the mapping needs to know. Paths are repository-relative."""

    def file_exists(mut self, path: String) raises -> Bool:
        """Is the file in the changed tree?"""
        ...

    def owners(mut self, paths: List[String]) raises -> List[List[String]]:
        """Per path, the targets that list the file ([] when none does).
        Raises when the question cannot be answered for any of them."""
        ...

    def packages_including(mut self, bzl: String) raises -> List[String]:
        """The directories of the packages whose BUCK file loads `bzl`,
        directly or through other `.bzl` files."""
        ...

    def package_at_base(mut self, path: String) raises -> PackageOf:
        """The package that held `path` in the base tree."""
        ...

    def has_package(mut self, dir: String) raises -> Bool:
        """Does the changed tree have a package at `dir`?"""
        ...

    def package_pattern(mut self, dir: String) raises -> String:
        """The target pattern of every target of the package at `dir`."""
        ...

    def rdeps(mut self, seeds: List[String]) raises -> List[String]:
        """The seeds (labels or package patterns) and every target of the
        universe that depends on one of them."""
        ...

    def configure_universe(mut self) raises:
        """Configure every target of the universe; raises buck2's error when
        one cannot be (an unknown or invisible dependency)."""
        ...

    def all_targets(mut self) raises -> List[String]:
        """Every target of the universe."""
        ...

    def closure(mut self, targets: List[String]) raises -> List[String]:
        """The targets and everything they depend on, as far as the
        universe holds it."""
        ...


def _safe_path(path: String) -> Bool:
    """Only the characters a repository path has here: a path with another
    would have to be quoted for buck2's query language."""
    var b = path.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (
            (c >= 48 and c <= 57)
            or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or c == 46 or c == 47 or c == 95 or c == 45 or c == 43 or c == 64 or c == 61
        )
        if not ok:
            return False
    return True


struct BuckGraph(Graph, Movable):
    """The real tree: buck2 for targets, git for the base tree."""

    var buck2: String
    var buck2_args: List[String]
    var git: String
    var base: String
    var cells: Cells
    var universe: List[String]
    var includes: Dict[String, List[String]]
    var includes_loaded: Bool
    var base_checked: Bool

    def __init__(
        out self,
        var buck2: String,
        var buck2_args: List[String],
        var base: String,
        var cells: Cells,
        var universe: List[String],
    ):
        self.buck2 = buck2^
        self.buck2_args = buck2_args^
        self.git = String("git")
        self.base = base^
        self.cells = cells^
        self.universe = universe^
        self.includes = Dict[String, List[String]]()
        self.includes_loaded = False
        self.base_checked = False

    def _buck(self, var sub: List[String]) raises -> Captured:
        var argv = self.buck2_args.copy()
        for i in range(len(sub)):
            argv.append(sub[i])
        var r = run_captured(self.buck2, argv)
        if not r.ok():
            var tail = r.stderr.copy()
            if tail.byte_length() > 600:
                tail = suffix(tail, tail.byte_length() - 600)
            raise Error(String("buck2 ") + sub[0] + String(" failed (exit ") + String(r.exit_code) + String("): ") + tail)
        return r^

    def _git(self, var argv: List[String]) raises -> Captured:
        return run_captured(self.git, argv)

    def _universe_union(self) -> String:
        return join(self.universe, String(" + "))

    def file_exists(mut self, path: String) raises -> Bool:
        return exists(path)

    def owners(mut self, paths: List[String]) raises -> List[List[String]]:
        var out = List[List[String]]()
        if len(paths) == 0:
            return out^
        for i in range(len(paths)):
            if not _safe_path(paths[i]):
                raise Error(String("the path '") + paths[i] + String("' has a character a buck2 query cannot take"))
        var sub = List[String]()
        sub.append(String("uquery"))
        sub.append(String("--output-format"))
        sub.append(String("json"))
        sub.append(String("owner(%s)"))
        for i in range(len(paths)):
            sub.append(paths[i])
        var r = self._buck(sub^)
        # One flattened line per leaf: `<path>\t<index>\t<label>`, or
        # `<path>\t[]` for a path nothing owns.
        var flat = String()
        var raw = List[UInt8]()
        var b = r.stdout.as_bytes()
        for i in range(len(b)):
            raw.append(b[i])
        flatten_document(raw^, String(""), flat)
        var found = Dict[String, List[String]]()
        var lines = lines_of(flat)
        for i in range(len(lines)):
            var parts = lines[i].split(String("\t"))
            if len(parts) == 2 and String(parts[1]) == String("[]"):
                if String(parts[0]) not in found:
                    found[String(parts[0])] = List[String]()
            elif len(parts) == 3:
                var key = String(parts[0])
                if key not in found:
                    found[key] = List[String]()
                found[key].append(String(parts[2]))
            else:
                raise Error(String("unexpected owner answer line: '") + lines[i] + String("'"))
        for i in range(len(paths)):
            if paths[i] not in found:
                raise Error(String("buck2 gave no answer for '") + paths[i] + String("'"))
            out.append(found[paths[i]].copy())
        return out^

    def _load_includes(mut self) raises:
        if self.includes_loaded:
            return
        var ls = List[String]()
        ls.append(String("ls-files"))
        ls.append(String("--cached"))
        ls.append(String("--others"))
        ls.append(String("--exclude-standard"))
        ls.append(String("--"))
        ls.append(String(":(glob)**/BUCK"))
        var listed = self._git(ls^)
        if not listed.ok():
            raise Error(String("git ls-files failed: ") + listed.stderr)
        var files = lines_of(listed.stdout)
        if len(files) == 0:
            raise Error(String("git lists no BUCK file"))
        var rootq = List[String]()
        rootq.append(String("root"))
        rootq.append(String("--kind"))
        rootq.append(String("project"))
        var rootr = self._buck(rootq^)
        var root_lines = lines_of(rootr.stdout)
        if len(root_lines) != 1:
            raise Error(String("buck2 root printed no project root"))
        var root = root_lines[0] + String("/")
        var skip = root + String("prelude/")
        var sub = List[String]()
        sub.append(String("audit"))
        sub.append(String("includes"))
        for i in range(len(files)):
            sub.append(files[i])
        var r = self._buck(sub^)
        var current = String("")
        var have = False
        var seen = 0
        var lines = lines_of(r.stdout)
        for i in range(len(lines)):
            var line = lines[i].copy()
            if line.startswith(String("# ")):
                var buckfile = suffix(line, 2)
                current = dirname(buckfile)
                have = True
                seen += 1
            elif have and line.startswith(root) and not line.startswith(skip):
                var rel = suffix(line, root.byte_length())
                if rel in self.includes:
                    self.includes[rel].append(current)
                else:
                    var one = List[String]()
                    one.append(current)
                    self.includes[rel] = one^
        if seen != len(files):
            raise Error(
                String("buck2 audit includes answered ") + String(seen) + String(" of ") + String(len(files)) + String(" BUCK files")
            )
        self.includes_loaded = True

    def packages_including(mut self, bzl: String) raises -> List[String]:
        self._load_includes()
        if bzl in self.includes:
            return self.includes[bzl].copy()
        return List[String]()

    def _check_base(mut self) raises:
        if self.base_checked:
            return
        var argv = List[String]()
        argv.append(String("rev-parse"))
        argv.append(String("--verify"))
        argv.append(String("--quiet"))
        argv.append(self.base + String("^{commit}"))
        var r = self._git(argv^)
        if not r.ok():
            raise Error(String("'") + self.base + String("' is not a commit"))
        self.base_checked = True

    def package_at_base(mut self, path: String) raises -> PackageOf:
        if self.base.byte_length() == 0:
            return PackageOf(PACKAGE_UNKNOWN)
        self._check_base()
        var dir = dirname(path)
        while True:
            var cand = dir + String("/BUCK") if dir.byte_length() > 0 else String("BUCK")
            var argv = List[String]()
            argv.append(String("cat-file"))
            argv.append(String("-e"))
            argv.append(self.base + String(":") + cand)
            var r = self._git(argv^)
            if r.ok():
                return PackageOf(PACKAGE_FOUND, dir^)
            if dir.byte_length() == 0:
                return PackageOf(PACKAGE_NONE)
            dir = dirname(dir)

    def has_package(mut self, dir: String) raises -> Bool:
        return exists(dir + String("/BUCK") if dir.byte_length() > 0 else String("BUCK"))

    def package_pattern(mut self, dir: String) raises -> String:
        return self.cells.package_pattern(dir)

    def rdeps(mut self, seeds: List[String]) raises -> List[String]:
        var sub = List[String]()
        sub.append(String("cquery"))
        sub.append(String("rdeps(") + self._universe_union() + String(", set(") + join(seeds, String(" ")) + String("))"))
        var r = self._buck(sub^)
        var out = List[String]()
        var lines = lines_of(r.stdout)
        for i in range(len(lines)):
            out.append(normalize_label(lines[i], self.cells.root))
        return out^

    def configure_universe(mut self) raises:
        var sub = List[String]()
        sub.append(String("cquery"))
        sub.append(self._universe_union())
        _ = self._buck(sub^)

    def all_targets(mut self) raises -> List[String]:
        var sub = List[String]()
        sub.append(String("targets"))
        for i in range(len(self.universe)):
            sub.append(self.universe[i])
        var r = self._buck(sub^)
        var out = List[String]()
        var lines = lines_of(r.stdout)
        for i in range(len(lines)):
            out.append(normalize_label(lines[i], self.cells.root))
        if len(out) == 0:
            raise Error(String("the universe has no target"))
        return out^

    def closure(mut self, targets: List[String]) raises -> List[String]:
        var sub = List[String]()
        sub.append(String("cquery"))
        sub.append(String("deps(set(") + join(targets, String(" ")) + String("))"))
        var r = self._buck(sub^)
        var out = List[String]()
        var lines = lines_of(r.stdout)
        for i in range(len(lines)):
            out.append(normalize_label(lines[i], self.cells.root))
        return out^
