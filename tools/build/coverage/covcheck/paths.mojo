"""From a path in a coverage report to a file of the repository.

The repository is the output of `git ls-files -z`: NUL-terminated paths.
Every report path is mapped in this order:

1. The longest `--strip-prefix` it starts with is removed. A prefix matches
   at a path-segment boundary only (it ends with `/`, or the path continues
   with `/` after it); the `/` left at the front is dropped.
2. Buck2 output paths: when the path holds a segment `__<name>__` followed
   by a segment of 16 or more hex digits (the `buck-out/v2/art/...` copy of a
   package's sources, as in
   `buck-out/v2/art/<cell>/src/m/__m__/fedcba9876543210/src/m/x.mojo`),
   the path is what follows the hex segment (`src/m/x.mojo`).
3. A relative path that is a repository file is that file. A leading `./`
   is dropped first.
4. When the report was given as `PKGDIR=FILE`, a relative path that is not a
   repository file is tried as `PKGDIR/path` (kcov writes a test's own
   sources relative to its package: `tests/test_x.mojo`). If that is not a
   repository file, the path is unmapped (an error) when
   `PKGDIR/<first segment>` is a repository directory, or when the path has
   no `/` (a source directly in the package) and `PKGDIR` is a repository
   directory.
5. What is left: an absolute path is outside the repository (ignored, and
   counted). A relative path whose first segment is a top-level directory
   of the repository is unmapped (an error: it names a repository file
   that is not there, so the report and the checkout disagree); any other
   relative path (`oss/modular/mojo/stdlib/...`, the Mojo standard library)
   is outside the repository.

A test's generated main (`generated_test_main`): the build names each
welded test's main by its output path in the package, in its report and to
the gate (tools/build/mojo/coverage.bzl), and a generated one (the layout
probe a mojo_aws_client or mojo_gcp_client generates under `gen/<name>/`)
is no file of the checkout. An unmapped path is that test's main, and no
error, when all of these hold: the report is the test's own
(`.../cov/tests/<stem>.xml`, or its branch records `.../cov/branch/<stem>.info`),
the path's file name is `<stem>.mojo`, a directory above it holds a BUCK
file, and its own directory is none of the repository's (an output
directory). The caller sets it aside as a test source; every other
unmapped path, a missing file in a repository directory included, stays an
error.
"""

from covcheck.text import byte_at, first_segment, is_hex, split_on, substr, suffix

comptime MAPPED: Int = 0
comptime OUTSIDE: Int = 1
comptime UNMAPPED: Int = 2


struct RepoFiles(Copyable, Movable):
    """The files of the repository, their directories, and the directories
    that hold a `BUCK` file."""

    var files: Dict[String, Bool]
    var dirs: Dict[String, Bool]
    var buck_dirs: Dict[String, Bool]
    var root_buck: Bool

    def __init__(out self):
        self.files = Dict[String, Bool]()
        self.dirs = Dict[String, Bool]()
        self.buck_dirs = Dict[String, Bool]()
        self.root_buck = False

    def add(mut self, path: String):
        self.files[path] = True
        var i = path.rfind("/")
        var name = suffix(path, i + 1)
        if name == String("BUCK"):
            if i < 0:
                self.root_buck = True
            else:
                self.buck_dirs[substr(path, 0, i)] = True
        while i > 0:
            var d = substr(path, 0, i)
            if d in self.dirs:
                break
            self.dirs[d] = True
            i = d.rfind("/")

    def has_file(self, path: String) -> Bool:
        return path in self.files

    def has_dir(self, path: String) -> Bool:
        return path in self.dirs

    def has_buck(self, d: String) -> Bool:
        """Whether directory `d` holds a BUCK file (`(root)`: the top)."""
        if d == String("(root)"):
            return self.root_buck
        return d in self.buck_dirs


def repo_files_of(list: List[String]) -> RepoFiles:
    var r = RepoFiles()
    for i in range(len(list)):
        r.add(list[i])
    return r^


def parse_repo_files(raw: List[UInt8], origin: String) raises -> RepoFiles:
    """The paths of `git ls-files -z` output: each one NUL-terminated."""
    var r = RepoFiles()
    if len(raw) > 0 and raw[len(raw) - 1] != UInt8(0):
        raise Error(origin + String(": not NUL-terminated paths (give the output of `git ls-files -z`)"))
    var start = 0
    for i in range(len(raw)):
        if raw[i] == UInt8(0):
            if i > start:
                var sub = List[UInt8](capacity=i - start)
                for k in range(start, i):
                    sub.append(raw[k])
                r.add(String(from_utf8_lossy=sub))
            start = i + 1
    return r^


struct Mapped(Copyable, Movable):
    """Where a report path landed: `MAPPED` with the repository path,
    `OUTSIDE`, or `UNMAPPED` with what was looked for."""

    var kind: Int
    var path: String

    def __init__(out self, kind: Int, path: String):
        self.kind = kind
        self.path = path


def _strip(path: String, prefixes: List[String]) -> String:
    var best = -1
    for i in range(len(prefixes)):
        var p = prefixes[i]
        var n = p.byte_length()
        if n == 0 or not path.startswith(p):
            continue
        if not p.endswith("/") and path.byte_length() > n and byte_at(path, n) != 47:
            continue
        if best < 0 or n > prefixes[best].byte_length():
            best = i
    if best < 0:
        return path
    var rest = suffix(path, prefixes[best].byte_length())
    while rest.startswith("/"):
        rest = suffix(rest, 1)
    return rest^


def _is_hash(seg: String) -> Bool:
    if seg.byte_length() < 16:
        return False
    for i in range(seg.byte_length()):
        if not is_hex(byte_at(seg, i)):
            return False
    return True


def _buck_out(path: String) -> String:
    """The repository path in a Buck2 output path, or the empty string."""
    var segs = split_on(path, 47)
    for i in range(len(segs) - 2):
        var s = segs[i]
        if s.byte_length() > 4 and s.startswith("__") and s.endswith("__") and _is_hash(segs[i + 1]):
            var out = String("")
            for k in range(i + 2, len(segs)):
                if k > i + 2:
                    out += String("/")
                out += segs[k]
            return out^
    return String("")


def map_path(raw: String, pkgdir: String, prefixes: List[String], repo: RepoFiles) -> Mapped:
    """Where the report path `raw` (from a report given with `pkgdir`, or
    the empty string) lands; see the module header for the order."""
    var path = _strip(raw, prefixes)
    var built = _buck_out(path)
    if built.byte_length() > 0:
        path = built
    while path.startswith("./"):
        path = suffix(path, 2)
    if path.startswith("/"):
        return Mapped(OUTSIDE, path)
    if repo.has_file(path):
        return Mapped(MAPPED, path)
    if pkgdir.byte_length() > 0:
        var joined = pkgdir + String("/") + path
        if repo.has_file(joined):
            return Mapped(MAPPED, joined)
        if repo.has_dir(pkgdir + String("/") + first_segment(path)):
            return Mapped(UNMAPPED, joined)
        if path.find("/") < 0 and repo.has_dir(pkgdir):
            return Mapped(UNMAPPED, joined)
    if path.find("/") > 0 and repo.has_dir(first_segment(path)):
        return Mapped(UNMAPPED, path)
    return Mapped(OUTSIDE, path)


def report_test_main(origin: String) -> String:
    """`<stem>.mojo` when `origin` names a test's own coverage output as the
    build writes it (`.../cov/tests/<stem>.xml`, `.../cov/branch/<stem>.info`),
    else the empty string."""
    var segs = split_on(origin, 47)
    var n = len(segs)
    if n < 3 or segs[n - 3] != String("cov"):
        return String("")
    var ext: String
    if segs[n - 2] == String("tests"):
        ext = String(".xml")
    elif segs[n - 2] == String("branch"):
        ext = String(".info")
    else:
        return String("")
    var name = segs[n - 1]
    var k = name.byte_length() - ext.byte_length()
    if k <= 0 or not name.endswith(ext):
        return String("")
    return substr(name, 0, k) + String(".mojo")


def generated_test_main(origin: String, path: String, repo: RepoFiles) -> Bool:
    """Whether `path`, which `map_path` left unmapped, is the generated main
    of the test whose report is `origin` (see the module header)."""
    var want = report_test_main(origin)
    var i = path.rfind("/")
    if want.byte_length() == 0 or i <= 0 or suffix(path, i + 1) != want:
        return False
    var d = substr(path, 0, i)
    if repo.has_dir(d):
        return False
    var j = d.rfind("/")
    while j > 0:
        d = substr(d, 0, j)
        if d in repo.buck_dirs:
            return True
        j = d.rfind("/")
    return False


def package_of(path: String, repo: RepoFiles) raises -> String:
    """The nearest directory above the repository file `path` that holds a
    BUCK file; `(root)` when that is only the top directory; an error when
    there is none."""
    var i = path.rfind("/")
    while i > 0:
        var d = substr(path, 0, i)
        if d in repo.buck_dirs:
            return d
        i = d.rfind("/")
    if repo.root_buck:
        return String("(root)")
    raise Error(String("no BUCK file in any directory above ") + path + String(", and none at the top"))


def is_test_source(path: String, package: String) -> Bool:
    """Whether `path` is under the `tests/` directory directly inside its
    package."""
    if package == String("(root)"):
        return path.startswith("tests/")
    return path.startswith(package + String("/tests/"))
