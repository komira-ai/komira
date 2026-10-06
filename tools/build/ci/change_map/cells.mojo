"""The cell table of `.buckconfig`: which directory is which cell."""

from buildtools.bytes import normpath, read_file, split_words, substr, suffix, to_string


struct Cells(Copyable, Movable):
    """`names[i]` is the cell rooted at `paths[i]` (repository-relative,
    normalized). `root` is the name of the cell rooted at `.`."""

    var names: List[String]
    var paths: List[String]
    var root: String

    def __init__(out self):
        self.names = List[String]()
        self.paths = List[String]()
        self.root = String("")

    def package_pattern(self, dir: String) raises -> String:
        """`cell//rel:` for the package at the repository-relative `dir`
        ("" is the root package): the cell with the longest path holding it."""
        var best = -1
        var best_len = -1
        for i in range(len(self.names)):
            var p = self.paths[i].copy()
            var inside = p == String(".") or dir == p or dir.startswith(p + String("/"))
            var plen = 0 if p == String(".") else p.byte_length()
            if inside and plen > best_len:
                best = i
                best_len = plen
        if best < 0:
            raise Error(String("no cell holds '") + dir + String("'"))
        var rel = dir.copy()
        if best_len > 0:
            rel = suffix(dir, best_len + 1) if dir.byte_length() > best_len else String("")
        return self.names[best] + String("//") + rel + String(":")


def parse_cells(text: String) raises -> Cells:
    """The `[cells]` section of a `.buckconfig`."""
    var cells = Cells()
    var in_cells = False
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        var words = split_words(line)
        if len(words) == 0 or words[0].startswith(String("#")):
            continue
        if words[0].startswith(String("[")):
            in_cells = words[0] == String("[cells]")
            continue
        if not in_cells:
            continue
        var eq = line.find(String("="))
        if eq < 0:
            raise Error(String(".buckconfig [cells]: no `=` in '") + line + String("'"))
        var name = split_words(substr(line, 0, eq))
        var path = split_words(suffix(line, eq + 1))
        if len(name) != 1 or len(path) != 1:
            raise Error(String(".buckconfig [cells]: cannot read '") + line + String("'"))
        if path[0] == String("none"):
            continue
        var norm = normpath(path[0])
        cells.names.append(name[0])
        cells.paths.append(norm)
        if norm == String("."):
            cells.root = name[0]
    if cells.root.byte_length() == 0:
        raise Error(String(".buckconfig [cells]: no cell is rooted at `.`"))
    return cells^


def read_cells(path: String) raises -> Cells:
    return parse_cells(to_string(read_file(path)))
