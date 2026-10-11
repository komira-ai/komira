# =============================================================================
# komira_git/tests/test_trees.mojo -- tree build, serialize, parse.
# =============================================================================
#
# WHERE THE EXPECTED IDS COME FROM:
#   * git v2.47.0 t/t0000-basic.sh, "Basics of the basics": `simpletree`
#     (one empty file `should-be-empty`), and the "various types of objects"
#     tree: `subp3d`, `path3d`, `path2d` and `root`, sha1 and sha256. The
#     tests rebuild each tree from the recipe in that script (files
#     `hello $p\n`, symlinks to `hello $p`) and compare ids.
#   * The sort-rule tree (`sortrule` below) is git's own output: git 2.51.0
#     `git mktree --missing` fed the five entries in the scrambled order
#     `a0, a/, a.b, a-b, sub` printed 7d24f848... (sha1) and 7127363c...
#     (sha256, in an `--object-format=sha256` repository), and
#     `git ls-tree` listed them in the order a-b, a.b, a, a0, sub. These are
#     committed vectors; a build-time differential against a pinned git
#     replaces them when the git oracle package lands.
#   * git 2.51.0 `git hash-object -t tree` refuses the two-entry tree
#     `a/` then `a.b` with "treeNotSorted" and `a.b` then `040000 a` with
#     "zeroPaddedFilemode": the two refusals pinned below.
#
# WHAT EACH TEST CATCHES (mutants named in the PR):
#   * test_sort_rule_tree: a tree sort without the '/' suffix rule (plain
#     bytewise names put `a` first and the id changes).
#   * test_t0000_trees: a subtree mode written `040000` (every tree holding
#     a subtree changes id), a wrong entry layout, a wrong sort.
#   * test_parse_*: each refusal by its exact message.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    MODE_BLOB,
    MODE_EXECUTABLE,
    MODE_GITLINK,
    MODE_SYMLINK,
    MODE_TREE,
    ObjectFormat,
    ObjectId,
    ObjectKind,
    Tree,
    hash_object,
    is_valid_mode,
    mode_text,
    parse_tree,
    tree_entry_compare,
)


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _blob(format: ObjectFormat, content: String) raises -> ObjectId:
    var data = _b(content)
    return hash_object(format, ObjectKind.blob(), Span(data))


def _id(format: ObjectFormat, hex: String) raises -> ObjectId:
    return ObjectId.parse_hex(format, hex)


def _raw_entry(mut out: List[UInt8], mode: String, name: String, id: ObjectId):
    """Append one tree entry exactly as given (no checks, no sorting)."""
    var m = mode.as_bytes()
    for i in range(len(m)):
        out.append(m[i])
    out.append(UInt8(32))
    var n = name.as_bytes()
    for i in range(len(n)):
        out.append(n[i])
    out.append(UInt8(0))
    id.append_raw_to(out)


def _parse_err(format: ObjectFormat, payload: List[UInt8]) -> String:
    try:
        _ = parse_tree(format, Span(payload))
    except e:
        return String(e)
    return String("OK")


def _add_err(mode: Int, name: String) -> String:
    var t = Tree(ObjectFormat.sha1())
    try:
        t.add(mode, name, ObjectId.zero(ObjectFormat.sha1()))
    except e:
        return String(e)
    return String("OK")


def _t0000_root(format: ObjectFormat) raises -> List[String]:
    """Build the t0000 trees; return [subp3d, path3d, path2d, root] hex."""
    var subp3 = Tree(format)
    subp3.add(MODE_SYMLINK, "file3sym", _blob(format, "hello path3/subp3/file3"))
    subp3.add(MODE_BLOB, "file3", _blob(format, "hello path3/subp3/file3\n"))
    var subp3_id = subp3.id()

    var path3 = Tree(format)
    path3.add(MODE_TREE, "subp3", subp3_id)
    path3.add(MODE_BLOB, "file3", _blob(format, "hello path3/file3\n"))
    path3.add(MODE_SYMLINK, "file3sym", _blob(format, "hello path3/file3"))
    var path3_id = path3.id()

    var path2 = Tree(format)
    path2.add(MODE_BLOB, "file2", _blob(format, "hello path2/file2\n"))
    path2.add(MODE_SYMLINK, "file2sym", _blob(format, "hello path2/file2"))
    var path2_id = path2.id()

    var root = Tree(format)
    root.add(MODE_TREE, "path3", path3_id)
    root.add(MODE_SYMLINK, "path0sym", _blob(format, "hello path0"))
    root.add(MODE_TREE, "path2", path2_id)
    root.add(MODE_BLOB, "path0", _blob(format, "hello path0\n"))
    var out = List[String]()
    out.append(subp3_id.to_hex())
    out.append(path3_id.to_hex())
    out.append(path2_id.to_hex())
    out.append(root.id().to_hex())
    return out^


def test_simpletree() raises:
    for f in range(2):
        var format = ObjectFormat.sha1()
        var want = String("7bb943559a305bdd6bdee2cef6e5df2413c3d30a")
        var want_empty = String("4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        if f == 1:
            format = ObjectFormat.sha256()
            want = "1710c07a6c86f9a3c7376364df04c47ee39e5a5e221fcdd84b743bc9bb7e2bc5"
            want_empty = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
        var t = Tree(format)
        t.add(MODE_BLOB, "should-be-empty", _blob(format, ""))
        assert_equal(t.id().to_hex(), want)
        assert_equal(Tree(format).id().to_hex(), want_empty)


def test_t0000_trees() raises:
    var s1 = _t0000_root(ObjectFormat.sha1())
    assert_equal(s1[0], "3c5e5399f3a333eddecce7a9b9465b63f65f51e2")
    assert_equal(s1[1], "21ae8269cacbe57ae09138dcc3a2887f904d02b3")
    assert_equal(s1[2], "58a09c23e2ca152193f2786e06986b7b6712bdbe")
    assert_equal(s1[3], "087704a96baf1c2d1c869a8b084481e121c88b5b")
    var s2 = _t0000_root(ObjectFormat.sha256())
    assert_equal(
        s2[0], "76b4ef482d4fa1c754390344cf3851c7f883b27cf9bc999c6547928c46aeafb7"
    )
    assert_equal(
        s2[1], "9b60497be959cb830bf3f0dc82bcc9ad9e925a24e480837ade46b2295e47efe1"
    )
    assert_equal(
        s2[2], "00e4b32b96e7e3d65d79112dcbea53238a22715f896933a62b811377e2650c17"
    )
    assert_equal(
        s2[3], "9481b52abab1b2ffeedbf9de63ce422b929f179c1b98ff7bee5f8f1bc0710751"
    )


def _sortrule(format: ObjectFormat, commit_hex: String) raises -> Tree:
    var t = Tree(format)
    var empty_blob = _blob(format, "")
    var empty = List[UInt8]()
    t.add(MODE_BLOB, "a0", empty_blob)
    t.add(MODE_TREE, "a", hash_object(format, ObjectKind.tree(), Span(empty)))
    t.add(MODE_BLOB, "a.b", empty_blob)
    t.add(MODE_EXECUTABLE, "a-b", empty_blob)
    t.add(MODE_GITLINK, "sub", _id(format, commit_hex))
    return t^


def test_sort_rule_tree() raises:
    var t1 = _sortrule(
        ObjectFormat.sha1(), "bb0e40b5d718273d8cd5d4806d4913aa21783ef4"
    )
    assert_equal(t1.id().to_hex(), "7d24f8484c6d580088293e3c966d716a9958c8dd")
    var order = t1.sorted_entries()
    assert_equal(len(order), 5)
    assert_equal(String(unsafe_from_utf8=Span(order[0].name)), "a-b")
    assert_equal(String(unsafe_from_utf8=Span(order[1].name)), "a.b")
    assert_equal(String(unsafe_from_utf8=Span(order[2].name)), "a")
    assert_equal(String(unsafe_from_utf8=Span(order[3].name)), "a0")
    assert_equal(String(unsafe_from_utf8=Span(order[4].name)), "sub")
    assert_true(order[2].kind() == ObjectKind.tree())
    assert_true(order[4].kind() == ObjectKind.commit())
    assert_true(order[0].kind() == ObjectKind.blob())
    var t2 = _sortrule(
        ObjectFormat.sha256(),
        "446da4302e2a9bb0e5616fa5790e815c87409c9dc34752f46900be33dfc687c2",
    )
    assert_equal(
        t2.id().to_hex(),
        "7127363c002710f0c8b802e73e73c84fc7b8b4da9ade3fbee6786710199b78b9",
    )
    # The comparator itself: a directory compares as name + '/'.
    var a = _b("a")
    var ab = _b("a.b")
    assert_true(tree_entry_compare(Span(ab), False, Span(a), True) < 0)
    assert_true(tree_entry_compare(Span(a), False, Span(ab), False) < 0)
    var a_dir = _b("a")
    assert_true(tree_entry_compare(Span(a), False, Span(a_dir), True) < 0)


def test_parse_round_trip() raises:
    var format = ObjectFormat.sha1()
    var t = _sortrule(format, "bb0e40b5d718273d8cd5d4806d4913aa21783ef4")
    var bytes = t.serialize()
    var back = parse_tree(format, Span(bytes))
    assert_equal(len(back.entries), 5)
    assert_equal(back.entries[2].mode, MODE_TREE)
    assert_equal(back.entries[0].mode, MODE_EXECUTABLE)
    var again = back.serialize()
    assert_equal(len(again), len(bytes))
    for i in range(len(bytes)):
        assert_equal(again[i], bytes[i])
    assert_equal(back.id().to_hex(), "7d24f8484c6d580088293e3c966d716a9958c8dd")


def test_modes() raises:
    assert_equal(mode_text(MODE_TREE), "40000")
    assert_equal(mode_text(MODE_BLOB), "100644")
    assert_equal(mode_text(MODE_EXECUTABLE), "100755")
    assert_equal(mode_text(MODE_SYMLINK), "120000")
    assert_equal(mode_text(MODE_GITLINK), "160000")
    assert_true(is_valid_mode(MODE_GITLINK))
    assert_false(is_valid_mode(33204))  # 0o100664
    assert_equal(
        _add_err(33204, "x"), "komira_git: tree entry mode 100664 is not one git writes"
    )


def test_add_name_refusals() raises:
    assert_equal(_add_err(MODE_BLOB, ""), "komira_git: tree entry has an empty name")
    assert_equal(_add_err(MODE_BLOB, "a/b"), "komira_git: tree entry name contains '/'")
    assert_equal(_add_err(MODE_BLOB, "a" + chr(0) + "b"), "komira_git: tree entry name contains NUL")
    assert_equal(_add_err(MODE_BLOB, "."), "komira_git: tree entry name is '.' or '..'")
    assert_equal(_add_err(MODE_TREE, ".."), "komira_git: tree entry name is '.' or '..'")
    assert_equal(_add_err(MODE_TREE, ".git"), "komira_git: tree entry name is '.git'")
    assert_equal(_add_err(MODE_BLOB, ".GiT"), "komira_git: tree entry name is '.git'")
    assert_equal(_add_err(MODE_BLOB, ".gitignore"), "OK")
    assert_equal(_add_err(MODE_BLOB, "..."), "OK")
    var t = Tree(ObjectFormat.sha1())
    try:
        t.add(MODE_BLOB, "x", ObjectId.zero(ObjectFormat.sha256()))
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: a sha256 id in a sha1 tree")


def test_duplicates() raises:
    var format = ObjectFormat.sha1()
    var blob = _blob(format, "")
    var empty = List[UInt8]()
    var tree_id = hash_object(format, ObjectKind.tree(), Span(empty))
    # Adjacent duplicates.
    var t = Tree(format)
    t.add(MODE_BLOB, "a", blob)
    t.add(MODE_EXECUTABLE, "a", blob)
    try:
        _ = t.serialize()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: tree has duplicate entry names at entry 1")
    # A file and a directory named `a`, with `a.c` sorted between them.
    var u = Tree(format)
    u.add(MODE_TREE, "a", tree_id)
    u.add(MODE_BLOB, "a.c", blob)
    u.add(MODE_BLOB, "a", blob)
    try:
        _ = u.serialize()
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: tree has duplicate entry names at entry 2")
    var raw = List[UInt8]()
    _raw_entry(raw, "100644", "a", blob)
    _raw_entry(raw, "100644", "a.c", blob)
    _raw_entry(raw, "40000", "a", tree_id)
    assert_equal(
        _parse_err(format, raw),
        "komira_git: tree has duplicate entry names at entry 2",
    )
    # Not duplicates: `a` file, `a.c`, `a0`, `b` directory.
    var ok = List[UInt8]()
    _raw_entry(ok, "100644", "a", blob)
    _raw_entry(ok, "100644", "a.c", blob)
    _raw_entry(ok, "100644", "a0", blob)
    _raw_entry(ok, "40000", "b", tree_id)
    assert_equal(_parse_err(format, ok), "OK")


def test_parse_refusals() raises:
    var format = ObjectFormat.sha1()
    var blob = _blob(format, "")
    var empty = List[UInt8]()
    var tree_id = hash_object(format, ObjectKind.tree(), Span(empty))
    # git refuses this order (treeNotSorted): directory `a` before `a.b`.
    var naive = List[UInt8]()
    _raw_entry(naive, "40000", "a", tree_id)
    _raw_entry(naive, "100644", "a.b", blob)
    assert_equal(
        _parse_err(format, naive), "komira_git: tree entries out of order at entry 1"
    )
    # git refuses this (zeroPaddedFilemode).
    var padded = List[UInt8]()
    _raw_entry(padded, "100644", "a.b", blob)
    _raw_entry(padded, "040000", "a", tree_id)
    assert_equal(
        _parse_err(format, padded),
        "komira_git: tree entry mode '040000' is zero-padded",
    )
    var bad_mode = List[UInt8]()
    _raw_entry(bad_mode, "100664", "a", blob)
    assert_equal(
        _parse_err(format, bad_mode),
        "komira_git: tree entry mode 100664 is not one git writes",
    )
    var non_octal = List[UInt8]()
    _raw_entry(non_octal, "100648", "a", blob)
    assert_equal(
        _parse_err(format, non_octal),
        "komira_git: tree entry mode has a non-octal byte",
    )
    var no_mode = List[UInt8]()
    _raw_entry(no_mode, "", "a", blob)
    assert_equal(_parse_err(format, no_mode), "komira_git: tree entry has an empty mode")
    var dotgit = List[UInt8]()
    _raw_entry(dotgit, "40000", ".Git", tree_id)
    assert_equal(_parse_err(format, dotgit), "komira_git: tree entry name is '.git'")
    var no_name = List[UInt8]()
    _raw_entry(no_name, "100644", "", blob)
    assert_equal(_parse_err(format, no_name), "komira_git: tree entry has an empty name")
    var no_space = _b("100644")
    assert_equal(
        _parse_err(format, no_space),
        "komira_git: tree entry has no space after its mode",
    )
    var no_nul = _b("100644 abc")
    assert_equal(
        _parse_err(format, no_nul), "komira_git: tree entry name has no NUL terminator"
    )
    var truncated = List[UInt8]()
    _raw_entry(truncated, "100644", "a", blob)
    for _ in range(13):
        _ = truncated.pop()
    assert_equal(
        _parse_err(format, truncated),
        "komira_git: tree entry id is truncated (need 20 bytes, 7 left)",
    )
    # A sha1-sized entry read as sha256 is truncated too.
    var short = List[UInt8]()
    _raw_entry(short, "100644", "a", blob)
    assert_equal(
        _parse_err(ObjectFormat.sha256(), short),
        "komira_git: tree entry id is truncated (need 32 bytes, 20 left)",
    )
    assert_equal(_parse_err(format, List[UInt8]()), "OK")


def main() raises:
    test_simpletree()
    test_t0000_trees()
    test_sort_rule_tree()
    test_parse_round_trip()
    test_modes()
    test_add_name_refusals()
    test_duplicates()
    test_parse_refusals()
    print("komira_git tree tests passed")
