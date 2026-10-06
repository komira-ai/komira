"""The coverage of one file, as every reader produces it.

A line is instrumented when the report has a record for it; its count is the
sum of the counts every record for it carried, so a line any test reached is
covered whichever report said so. A branch is keyed by a string unique within
its file (`<line>,<block>,<branch>` from lcov, `<line>,c,<i>` from
Cobertura) and its count is summed the same way; a branch counted 0, or that
lcov marked `-` (its block never ran), is a branch not taken.
"""

from covcheck.text import parse_count, saturating_add, sort_ints


struct FileCov(Copyable, Movable):
    """The lines and branches one report (or several, merged) records for
    one path."""

    var path: String
    var hits: Dict[Int, Int]
    var branches: Dict[String, Int]

    def __init__(out self, path: String):
        self.path = path
        self.hits = Dict[Int, Int]()
        self.branches = Dict[String, Int]()

    def add_line(mut self, line: Int, count: Int) raises:
        if line in self.hits:
            self.hits[line] = saturating_add(self.hits[line], count)
        else:
            self.hits[line] = count

    def add_branch(mut self, key: String, taken: Int) raises:
        if key in self.branches:
            self.branches[key] = saturating_add(self.branches[key], taken)
        else:
            self.branches[key] = taken

    def absorb(mut self, other: FileCov) raises:
        """Adds every count of `other` to this file's."""
        for e in other.hits.items():
            self.add_line(e.key, e.value)
        for e in other.branches.items():
            self.add_branch(e.key, e.value)

    def line_found(self) -> Int:
        return len(self.hits)

    def line_hit(self) -> Int:
        var n = 0
        for e in self.hits.items():
            if e.value > 0:
                n += 1
        return n

    def branch_found(self) -> Int:
        return len(self.branches)

    def branch_hit(self) -> Int:
        var n = 0
        for e in self.branches.items():
            if e.value > 0:
                n += 1
        return n

    def lines(self) -> List[Int]:
        """The instrumented lines, ascending."""
        var out = List[Int](capacity=len(self.hits))
        for e in self.hits.items():
            out.append(e.key)
        sort_ints(out)
        return out^


def branch_line(key: String) -> Int:
    """The line of a branch key (the number before its first comma)."""
    var c = key.find(",")
    return parse_count(String(key[byte=0:c])) if c > 0 else -1


def merge_by_path(var files: List[FileCov]) raises -> List[FileCov]:
    """`files` with every path once, in order of first appearance; the
    counts of a repeated path are summed into its first entry."""
    var out = List[FileCov]()
    var at = Dict[String, Int]()
    for i in range(len(files)):
        var p = files[i].path
        if p in at:
            out[at[p]].absorb(files[i])
        else:
            at[p] = len(out)
            out.append(files[i].copy())
    return out^
