"""The sample of mutants a run builds, and the list file that names it.

`sample(ids, n, seed)` keeps the `n` mutants whose `fnv1a64(seed + "\\n" +
id)` is smallest (ties by position), in their original order; `n` of 0, or
not below the count, keeps all. A mutant's place in the sample depends only on
its own id, the seed and the other ids' hashes, so a change elsewhere in a
package moves few mutants in or out of the sample, and the build actions of
a mutant that stays are the same actions (tools/build/coverage/README.md, "Mutation score").

The list file (`render_list`, `parse_list`) is what the build reads to
declare one set of actions per sampled mutant:

    # mutate list: <total> mutants, <sampled> sampled, seed <seed>
    # suppressed<TAB><kind><TAB><id><TAB><reason>
    <id><TAB><path><TAB><line><TAB><col><TAB><operator><TAB><description>

one `suppressed` comment per mutant a marker suppressed, then one row per
sampled mutant. A description holds no tab and no line end.
"""

from mutate.gen import Mutant, Suppressed


def fnv1a64(s: String) -> UInt64:
    var h: UInt64 = 14695981039346656037
    for c in s.as_bytes():
        h = h ^ UInt64(c)
        h = h * 1099511628211
    return h


def _merge_sort(mut idx: List[Int], keys: List[UInt64]):
    """Sorts `idx` by (keys[i], i), stably."""
    var n = len(idx)
    if n < 2:
        return
    var tmp = idx.copy()
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                var a = idx[i]
                var b = idx[j]
                if keys[b] < keys[a] or (keys[b] == keys[a] and b < a):
                    tmp[k] = b
                    j += 1
                else:
                    tmp[k] = a
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        for q in range(n):
            idx[q] = tmp[q]
        width *= 2


def sample(ids: List[String], n: Int, seed: String) -> List[Int]:
    """The positions in `ids` of the sample, ascending (module docstring)."""
    var out = List[Int]()
    if n <= 0 or n >= len(ids):
        for i in range(len(ids)):
            out.append(i)
        return out^
    var keys = List[UInt64]()
    var idx = List[Int]()
    for i in range(len(ids)):
        keys.append(fnv1a64(seed + "\n" + ids[i]))
        idx.append(i)
    _merge_sort(idx, keys)
    var keep = List[Bool]()
    for _ in range(len(ids)):
        keep.append(False)
    for i in range(n):
        keep[idx[i]] = True
    for i in range(len(ids)):
        if keep[i]:
            out.append(i)
    return out^


def _clean(s: String) -> String:
    """`s` with every tab, carriage return and line feed made a space."""
    var out = String("")
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 9 or c == 10 or c == 13:
            out += String(s[byte=start:i]) + " "
            start = i + 1
    out += String(s[byte = start : len(b)])
    return out^


def render_list(mutants: List[Mutant], suppressed: List[Suppressed], n: Int, seed: String) -> String:
    var ids = List[String]()
    for m in mutants:
        ids.append(m.id())
    var keep = sample(ids, n, seed)
    var out = String("# mutate list: ") + String(len(mutants)) + " mutants, " + String(len(keep)) + " sampled, seed " + _clean(seed) + "\n"
    for s in suppressed:
        out += String("# suppressed\t") + s.kind + "\t" + s.id + "\t" + _clean(s.reason) + "\n"
    for i in keep:
        ref m = mutants[i]
        out += ids[i] + "\t" + m.path + "\t" + String(m.line) + "\t" + String(m.col) + "\t" + m.operator + "\t" + _clean(m.description) + "\n"
    return out^


struct ListRow(Copyable, Movable):
    var id: String
    var path: String
    var line: Int
    var col: Int
    var operator: String
    var description: String

    def __init__(out self, id: String, path: String, line: Int, col: Int, operator: String, description: String):
        self.id = id
        self.path = path
        self.line = line
        self.col = col
        self.operator = operator
        self.description = description


struct ListFile(Movable):
    var header: String
    var rows: List[ListRow]
    var suppressed: List[Suppressed]

    def __init__(out self):
        self.header = String("")
        self.rows = List[ListRow]()
        self.suppressed = List[Suppressed]()


def split_tabs(s: String) -> List[String]:
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or Int(b[i]) == 9:
            out.append(String(s[byte=start:i]))
            start = i + 1
    return out^


def _number(s: String, what: String) raises -> Int:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error(what + " `" + s + "` is not a number")
    var v = 0
    for c in b:
        if Int(c) < 48 or Int(c) > 57:
            raise Error(what + " `" + s + "` is not a number")
        v = v * 10 + Int(c) - 48
    return v


def parse_list(text: String) raises -> ListFile:
    var lf = ListFile()
    var b = text.as_bytes()
    var start = 0
    var n = 0
    for i in range(len(b)):
        if Int(b[i]) != 10:
            continue
        var line = String(text[byte=start:i])
        start = i + 1
        n += 1
        if line.startswith("# suppressed\t"):
            var f = split_tabs(line)
            if len(f) != 4:
                raise Error("list line " + String(n) + ": a suppressed row has 4 fields")
            lf.suppressed.append(Suppressed(f[2], f[1], f[3]))
            continue
        if line.startswith("# mutate list: "):
            lf.header = line
            continue
        if line.startswith("#"):
            continue
        var f = split_tabs(line)
        if len(f) != 6:
            raise Error("list line " + String(n) + ": a row has 6 tab-separated fields, not " + String(len(f)))
        lf.rows.append(ListRow(f[0], f[1], _number(f[2], String("line")), _number(f[3], String("col")), f[4], f[5]))
    if start != len(b):
        raise Error("the list file does not end with a line feed")
    return lf^
