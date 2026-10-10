# =============================================================================
# komira_git/tree.mojo -- tree objects: parse, build, serialize.
# =============================================================================
#
# A tree's payload is a sequence of entries, each
#
#     <mode in octal, no leading zero> SP <name> NUL <raw object id>
#
# sorted by name, where a subtree's name compares as if it ended in '/'
# (so the file `a.b` sorts before the directory `a`, because '.' < '/').
#
# The modes are the five git writes: 100644 (file), 100755 (executable),
# 120000 (symlink), 40000 (tree) and 160000 (gitlink, a submodule commit).
#
# `parse_tree` refuses every tree `git fsck --strict` reports, so an accepted
# tree serializes back to the same bytes and the same id:
#   * malformed entries (no mode, no space, no NUL, a truncated id),
#   * a mode outside the five, or a zero-padded one (`040000`),
#   * an empty name, a name holding '/', the names `.` and `..`, and `.git`
#     in any letter case,
#   * entries out of order, and two entries with one name (also a file and a
#     directory of the same name that are not adjacent).
# Not checked here: the HFS+ and NTFS spellings of `.git` that
# `git fsck` also reports (`.gi‌t`, `git~1`), the `.gitmodules` checks,
# and the null id.
#
# `Tree.serialize` sorts its entries into git's order before writing them,
# so `Tree.add` may be called in any order.
# =============================================================================

from .bytes_util import _append_span, _append_str, _find_byte, _to_list
from .object_id import ObjectFormat, ObjectId, ObjectKind, hash_object

comptime MODE_BLOB: Int = 33188
"""0o100644, a regular file."""
comptime MODE_EXECUTABLE: Int = 33261
"""0o100755, an executable file."""
comptime MODE_SYMLINK: Int = 40960
"""0o120000, a symbolic link (the blob holds the target)."""
comptime MODE_TREE: Int = 16384
"""0o40000, a subtree."""
comptime MODE_GITLINK: Int = 57344
"""0o160000, a gitlink: the id is a commit in another repository."""

comptime _B_SLASH: Int = 47
comptime _B_DOT: Int = 46


def mode_text(mode: Int) -> String:
    """`mode` in octal with no leading zero: the spelling a tree entry
    carries (`100644`, `40000`)."""
    if mode == 0:
        return String("0")
    var digits = String()
    var v = mode
    while v > 0:
        digits = chr(48 + (v & 7)) + digits
        v >>= 3
    return digits^


def is_valid_mode(mode: Int) -> Bool:
    """True for the five modes git writes into a tree."""
    return (
        mode == MODE_BLOB
        or mode == MODE_EXECUTABLE
        or mode == MODE_SYMLINK
        or mode == MODE_TREE
        or mode == MODE_GITLINK
    )


def tree_entry_compare(
    a: Span[UInt8, _], a_is_tree: Bool, b: Span[UInt8, _], b_is_tree: Bool
) -> Int:
    """git's tree order (`base_name_compare`): bytewise, with a tree's name
    compared as if it ended in '/'. Negative, zero or positive."""
    var n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return Int(a[i]) - Int(b[i])
    var c1 = Int(a[n]) if n < len(a) else (_B_SLASH if a_is_tree else 0)
    var c2 = Int(b[n]) if n < len(b) else (_B_SLASH if b_is_tree else 0)
    return c1 - c2


def _check_name(name: Span[UInt8, _]) raises:
    """Refuse a name no tree may hold."""
    var n = len(name)
    if n == 0:
        raise Error("komira_git: tree entry has an empty name")
    for i in range(n):
        var c = Int(name[i])
        if c == _B_SLASH:
            raise Error("komira_git: tree entry name contains '/'")
        if c == 0:
            raise Error("komira_git: tree entry name contains NUL")
    if Int(name[0]) == _B_DOT:
        if n == 1 or (n == 2 and Int(name[1]) == _B_DOT):
            raise Error("komira_git: tree entry name is '.' or '..'")
        if n == 4:
            var g = Int(name[1]) | 32
            var i = Int(name[2]) | 32
            var t = Int(name[3]) | 32
            if g == 103 and i == 105 and t == 116:
                raise Error("komira_git: tree entry name is '.git'")


struct TreeEntry(Copyable, Movable):
    """One tree entry: its mode, its name (bytes) and the id it names."""

    var mode: Int
    var name: List[UInt8]
    var id: ObjectId

    def __init__(out self, mode: Int, var name: List[UInt8], id: ObjectId):
        self.mode = mode
        self.name = name^
        self.id = id

    def is_tree(self) -> Bool:
        """True for a subtree entry (mode 40000)."""
        return self.mode == MODE_TREE

    def kind(self) -> ObjectKind:
        """The kind of object the entry names: tree for 40000, commit for a
        gitlink, blob otherwise."""
        if self.mode == MODE_TREE:
            return ObjectKind.tree()
        if self.mode == MODE_GITLINK:
            return ObjectKind.commit()
        return ObjectKind.blob()


def _check_order(entries: List[TreeEntry]) raises:
    """Refuse entries out of git's order or sharing a name. A file and a
    directory of one name need not be adjacent (`a`, `a.c`, `a/`), so a
    directory is also checked against the run of entries before it whose
    names extend its own with a byte below '/'."""
    for j in range(1, len(entries)):
        var cmp = tree_entry_compare(
            Span(entries[j - 1].name), entries[j - 1].is_tree(),
            Span(entries[j].name), entries[j].is_tree(),
        )
        if cmp > 0:
            raise Error(
                "komira_git: tree entries out of order at entry " + String(j)
            )
        if cmp == 0:
            raise Error(
                "komira_git: tree has duplicate entry names at entry "
                + String(j)
            )
        if not entries[j].is_tree():
            continue
        var dn = len(entries[j].name)
        var i = j - 1
        while i >= 0:
            var other = Span(entries[i].name)
            var k = 0
            while k < dn and k < len(other) and other[k] == entries[j].name[k]:
                k += 1
            if k < dn:
                break
            if len(other) == dn:
                raise Error(
                    "komira_git: tree has duplicate entry names at entry "
                    + String(j)
                )
            if Int(other[dn]) >= _B_SLASH:
                break
            i -= 1


struct Tree(Copyable, Movable):
    """A tree: the object format of its ids, and its entries."""

    var format: ObjectFormat
    var entries: List[TreeEntry]

    def __init__(out self, format: ObjectFormat):
        """An empty tree of `format`."""
        self.format = format
        self.entries = List[TreeEntry]()

    def add(mut self, mode: Int, name: String, id: ObjectId) raises:
        """`add` with the bytes of `name`."""
        self.add(mode, name.as_bytes(), id)

    def add(mut self, mode: Int, name: Span[UInt8, _], id: ObjectId) raises:
        """Add an entry. Refuses a mode git does not write, a name no tree
        may hold, and an id of another object format. Order and duplicates
        are checked by `serialize`."""
        if not is_valid_mode(mode):
            raise Error(
                "komira_git: tree entry mode " + mode_text(mode)
                + " is not one git writes"
            )
        _check_name(name)
        if id.format() != self.format:
            raise Error(
                "komira_git: a " + id.format().name()
                + " id in a " + self.format.name() + " tree"
            )
        self.entries.append(TreeEntry(mode, _to_list(name, 0, len(name)), id))

    def sorted_entries(self) -> List[TreeEntry]:
        """The entries in git's tree order (a stable merge sort)."""
        var n = len(self.entries)
        var idx = List[Int](capacity=n)
        for i in range(n):
            idx.append(i)
        var tmp = List[Int](capacity=n)
        for i in range(n):
            tmp.append(i)
        var width = 1
        while width < n:
            var lo = 0
            while lo < n:
                var mid = min(lo + width, n)
                var hi = min(lo + 2 * width, n)
                var a = lo
                var b = mid
                var o = lo
                while a < mid and b < hi:
                    var ea = idx[a]
                    var eb = idx[b]
                    var c = tree_entry_compare(
                        Span(self.entries[ea].name), self.entries[ea].is_tree(),
                        Span(self.entries[eb].name), self.entries[eb].is_tree(),
                    )
                    if c <= 0:
                        tmp[o] = ea
                        a += 1
                    else:
                        tmp[o] = eb
                        b += 1
                    o += 1
                while a < mid:
                    tmp[o] = idx[a]
                    a += 1
                    o += 1
                while b < hi:
                    tmp[o] = idx[b]
                    b += 1
                    o += 1
                lo += 2 * width
            for i in range(n):
                idx[i] = tmp[i]
            width *= 2
        var out = List[TreeEntry](capacity=n)
        for i in range(n):
            out.append(self.entries[idx[i]].copy())
        return out^

    def serialize(self) raises -> List[UInt8]:
        """The tree's payload, entries in git's order. Refuses two entries
        with one name."""
        var sorted = self.sorted_entries()
        _check_order(sorted)
        var out = List[UInt8]()
        for i in range(len(sorted)):
            _append_str(out, mode_text(sorted[i].mode))
            out.append(UInt8(32))
            _append_span(out, Span(sorted[i].name))
            out.append(UInt8(0))
            sorted[i].id.append_raw_to(out)
        return out^

    def id(self) raises -> ObjectId:
        """The tree's object id (`git mktree` prints it)."""
        var payload = self.serialize()
        return hash_object(self.format, ObjectKind.tree(), Span(payload))


def parse_tree(format: ObjectFormat, payload: Span[UInt8, _]) raises -> Tree:
    """Parse a tree payload of `format`, refusing every malformation the
    header of this file lists. The entries keep their order."""
    var tree = Tree(format)
    var raw = format.raw_size()
    var pos = 0
    var n = len(payload)
    while pos < n:
        var sp = _find_byte(payload, pos, 32)
        if sp < 0:
            raise Error("komira_git: tree entry has no space after its mode")
        if sp == pos:
            raise Error("komira_git: tree entry has an empty mode")
        var mode = 0
        for i in range(pos, sp):
            var c = Int(payload[i])
            if c < 48 or c > 55:
                raise Error("komira_git: tree entry mode has a non-octal byte")
            if sp - pos > 6:
                raise Error("komira_git: tree entry mode is too long")
            mode = mode * 8 + (c - 48)
        if Int(payload[pos]) == 48:
            var spelled = String()
            for i in range(pos, sp):
                spelled += chr(Int(payload[i]))
            raise Error(
                "komira_git: tree entry mode '" + spelled + "' is zero-padded"
            )
        if not is_valid_mode(mode):
            raise Error(
                "komira_git: tree entry mode " + mode_text(mode)
                + " is not one git writes"
            )
        var nul = _find_byte(payload, sp + 1, 0)
        if nul < 0:
            raise Error("komira_git: tree entry name has no NUL terminator")
        _check_name(payload[sp + 1 : nul])
        if nul + 1 + raw > n:
            raise Error(
                "komira_git: tree entry id is truncated (need "
                + String(raw) + " bytes, " + String(n - nul - 1) + " left)"
            )
        var id = ObjectId.from_raw(format, payload[nul + 1 : nul + 1 + raw])
        tree.entries.append(TreeEntry(mode, _to_list(payload, sp + 1, nul), id))
        pos = nul + 1 + raw
    _check_order(tree.entries)
    return tree^
