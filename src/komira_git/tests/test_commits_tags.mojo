# =============================================================================
# komira_git/tests/test_commits_tags.mojo -- commits, tags, signatures.
# =============================================================================
#
# WHERE THE EXPECTED IDS COME FROM: git's own output. The payloads below use
# git's test identities and clock from git v2.47.0 t/test-lib.sh and
# t/test-lib-functions.sh (`A U Thor <author@example.com>`,
# `C O Mitter <committer@example.com>`, `test_tick` = 1112911993 -0700) and
# the tree ids of t/t0000-basic.sh (`root`) and t/oid-info/hash-info
# (`empty_tree`, `empty_blob`). Each payload was hashed by git 2.51.0
# `git hash-object -t commit|tag --stdin` (sha1) and the same in an
# `--object-format=sha256` repository (sha256); hash-object also runs git's
# fsck checks on its input, so every payload here is one git accepts.
# `tag_no_tagger` is the exception: git's strict check refuses a tag with no
# `tagger` line, so it was hashed with `--literally`. The tag `hellotag`
# follows t/t1006-cat-file.sh's `tag_content` (tagger time 0, message with
# no final newline). These are committed vectors; a build-time differential
# against a pinned git replaces them when the git oracle package lands.
#
# WHAT EACH TEST CATCHES:
#   * test_commit_vectors / test_tag_vectors: a wrong header order or
#     spelling, a lost or added byte (the id changes), a parse that does not
#     serialize back to the same bytes.
#   * test_merge_commit: extra headers lost, reordered, or their
#     continuation lines mangled; a non-UTF-8 message byte altered.
#   * test_*_refusals: each fsck rule by its exact message, and each form
#     git accepts that komira refuses (listed in commit.mojo) by its own.
#   * test_date_range: a date git writes and fsck accepts (up to 2^63-1,
#     19 digits) parsed and serialized back; 2^63 and above refused as
#     fsck's badDateOverflow refuses them.
#   * test_constructor_refusals: the checks that keep header bytes out of a
#     serialized object (a line break in an e-mail, a header key or a tag
#     name would start a new header line), each by its exact message; the
#     test reports every mismatch before it fails.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_git import (
    Commit,
    ExtraHeader,
    ObjectFormat,
    ObjectId,
    ObjectKind,
    Signature,
    Tag,
    parse_commit,
    parse_signature,
    parse_tag,
)

comptime _A = "A U Thor <author@example.com> 1112911993 -0700"
comptime _C = "C O Mitter <committer@example.com> 1112911993 -0700"


struct _Vec(Copyable, Movable):
    var format: ObjectFormat
    var root_tree: String
    var empty_tree: String
    var empty_blob: String
    var c_root: String
    var c_merge: String
    var c_empty_msg: String
    var t_annot: String
    var t_hellotag: String
    var t_no_tagger: String

    def __init__(out self, sha256: Bool):
        if not sha256:
            self.format = ObjectFormat.sha1()
            self.root_tree = "087704a96baf1c2d1c869a8b084481e121c88b5b"
            self.empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
            self.empty_blob = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
            self.c_root = "bb0e40b5d718273d8cd5d4806d4913aa21783ef4"
            self.c_merge = "38a32198129e998b087d55e4c9af279fa9e39abd"
            self.c_empty_msg = "da171eb3dec468db9f8b09a5070e14b8a6665b2f"
            self.t_annot = "64c0aef4c5c2b30b8f5b2582962b62b50f1c6c2f"
            self.t_hellotag = "8c5d39e704ad4948a00196f42e8f3b60a5ab141c"
            self.t_no_tagger = "6fae2b5e2769e58bea25ad947d511c485f7feb67"
        else:
            self.format = ObjectFormat.sha256()
            self.root_tree = "9481b52abab1b2ffeedbf9de63ce422b929f179c1b98ff7bee5f8f1bc0710751"
            self.empty_tree = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
            self.empty_blob = "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"
            self.c_root = "446da4302e2a9bb0e5616fa5790e815c87409c9dc34752f46900be33dfc687c2"
            self.c_merge = "e0378380d8082d74d619341bb31d3d0675aa45b95bccb9050d0a8f52a0861d2a"
            self.c_empty_msg = "cd5c7a92d3c827ac115e896178ae84cfffe8f35469134579cb658cc5e3a9dc57"
            self.t_annot = "8c2a133d38fe8da972f2832126d7fc944abd7d7c37da1bec4f38556eaf8f7650"
            self.t_hellotag = "da02f654a0835ad88406e9da6962ba4f90ae9226372520857f3d53162a1c9712"
            self.t_no_tagger = "26cdaf2633b9cbe394b4620d79117c30bdb0c14b2792284ba194fd9b33091a66"


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _text(b: List[UInt8]) -> String:
    """For ASCII fields only."""
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _c_root(v: _Vec) -> List[UInt8]:
    return _b(
        "tree " + v.root_tree + "\nauthor " + _A + "\ncommitter " + _C
        + "\n\nInitial commit\n"
    )


def _c_merge(v: _Vec) -> List[UInt8]:
    var out = _b(
        "tree " + v.empty_tree + "\nparent " + v.c_root + "\nparent " + v.c_root
        + "\nauthor " + _A + "\ncommitter " + _C
        + "\nencoding ISO-8859-1\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n"
        + " iQEzBAABCAAdFiEE\n -----END PGP SIGNATURE-----\n\nMerge caf"
    )
    out.append(UInt8(0xE9))
    var tail = _b("\n\nSecond paragraph.\n")
    for i in range(len(tail)):
        out.append(tail[i])
    return out^


def _c_empty_msg(v: _Vec) -> List[UInt8]:
    return _b(
        "tree " + v.empty_tree + "\nauthor " + _A + "\ncommitter " + _C + "\n\n"
    )


def _t_annot(v: _Vec) -> List[UInt8]:
    return _b(
        "object " + v.c_root + "\ntype commit\ntag v1.0\ntagger C O Mitter"
        " <committer@example.com> 1112912053 -0700\n\nRelease 1.0\n"
    )


def _t_hellotag(v: _Vec) -> List[UInt8]:
    return _b(
        "object " + v.empty_blob + "\ntype blob\ntag hellotag\ntagger C O Mitter"
        " <committer@example.com> 0 +0000\n\nThis is a tag"
    )


def _t_no_tagger(v: _Vec) -> List[UInt8]:
    return _b(
        "object " + v.empty_tree + "\ntype tree\ntag old-style\n\nNo tagger.\n"
    )


def _commit_round_trip(v: _Vec, payload: List[UInt8], want: String) raises -> Commit:
    var c = parse_commit(v.format, Span(payload))
    assert_true(_same(c.serialize(), payload))
    assert_equal(c.id().to_hex(), want)
    return c^


def _tag_round_trip(v: _Vec, payload: List[UInt8], want: String) raises -> Tag:
    var t = parse_tag(v.format, Span(payload))
    assert_true(_same(t.serialize(), payload))
    assert_equal(t.id().to_hex(), want)
    return t^


def test_commit_vectors() raises:
    for f in range(2):
        var v = _Vec(f == 1)
        var c = _commit_round_trip(v, _c_root(v), v.c_root)
        assert_equal(c.tree.to_hex(), v.root_tree)
        assert_equal(len(c.parents), 0)
        assert_equal(_text(c.author.name), "A U Thor")
        assert_equal(_text(c.author.email), "author@example.com")
        assert_equal(c.author.time, 1112911993)
        assert_equal(c.author.tz, "-0700")
        assert_equal(_text(c.committer.name), "C O Mitter")
        assert_equal(len(c.extra_headers), 0)
        assert_equal(_text(c.message), "Initial commit\n")
        var e = _commit_round_trip(v, _c_empty_msg(v), v.c_empty_msg)
        assert_equal(len(e.message), 0)
        # The same commit built from values.
        var built = Commit(
            ObjectId.parse_hex(v.format, v.root_tree),
            List[ObjectId](),
            Signature("A U Thor", "author@example.com", 1112911993, "-0700"),
            Signature("C O Mitter", "committer@example.com", 1112911993, "-0700"),
            List[ExtraHeader](),
            _b("Initial commit\n"),
        )
        assert_equal(built.id().to_hex(), v.c_root)


def test_merge_commit() raises:
    for f in range(2):
        var v = _Vec(f == 1)
        var c = _commit_round_trip(v, _c_merge(v), v.c_merge)
        assert_equal(len(c.parents), 2)
        assert_equal(c.parents[1].to_hex(), v.c_root)
        assert_equal(len(c.extra_headers), 2)
        assert_equal(_text(c.extra_headers[0].key), "encoding")
        assert_equal(_text(c.extra_headers[0].value), "ISO-8859-1")
        assert_equal(_text(c.extra_headers[1].key), "gpgsig")
        assert_equal(
            _text(c.extra_headers[1].value),
            "-----BEGIN PGP SIGNATURE-----\n\niQEzBAABCAAdFiEE\n"
            "-----END PGP SIGNATURE-----",
        )
        assert_equal(Int(c.message[9]), 0xE9)  # "Merge caf" is 9 bytes
        # Built from values: extra headers re-add the continuation spaces.
        var extra = List[ExtraHeader]()
        extra.append(ExtraHeader("encoding", "ISO-8859-1"))
        extra.append(
            ExtraHeader(
                "gpgsig",
                "-----BEGIN PGP SIGNATURE-----\n\niQEzBAABCAAdFiEE\n"
                "-----END PGP SIGNATURE-----",
            )
        )
        var parents = List[ObjectId]()
        parents.append(ObjectId.parse_hex(v.format, v.c_root))
        parents.append(ObjectId.parse_hex(v.format, v.c_root))
        var built = Commit(
            ObjectId.parse_hex(v.format, v.empty_tree),
            parents^,
            Signature("A U Thor", "author@example.com", 1112911993, "-0700"),
            Signature("C O Mitter", "committer@example.com", 1112911993, "-0700"),
            extra^,
            c.message.copy(),
        )
        assert_equal(built.id().to_hex(), v.c_merge)


def test_tag_vectors() raises:
    for f in range(2):
        var v = _Vec(f == 1)
        var a = _tag_round_trip(v, _t_annot(v), v.t_annot)
        assert_equal(a.object.to_hex(), v.c_root)
        assert_equal(a.target_kind.name(), "commit")
        assert_equal(_text(a.name), "v1.0")
        assert_true(Bool(a.tagger))
        assert_equal(a.tagger.value().time, 1112912053)
        assert_equal(_text(a.message), "Release 1.0\n")
        var h = _tag_round_trip(v, _t_hellotag(v), v.t_hellotag)
        assert_equal(h.target_kind.name(), "blob")
        assert_equal(h.tagger.value().time, 0)
        assert_equal(_text(h.message), "This is a tag")
        var n = _tag_round_trip(v, _t_no_tagger(v), v.t_no_tagger)
        assert_false(Bool(n.tagger))
        assert_equal(n.target_kind.name(), "tree")


def _commit_err(payload: String) -> String:
    var b = _b(payload)
    try:
        _ = parse_commit(ObjectFormat.sha1(), Span(b))
    except e:
        return String(e)
    return String("OK")


def _tag_err(payload: String) -> String:
    var b = _b(payload)
    try:
        _ = parse_tag(ObjectFormat.sha1(), Span(b))
    except e:
        return String(e)
    return String("OK")


def _ident_err(line: String) -> String:
    var b = _b(line)
    try:
        _ = parse_signature(Span(b), "commit author")
    except e:
        return String(e)
    return String("OK")


def test_signature_refusals() raises:
    var p = "komira_git: commit author: "
    assert_equal(_ident_err(_A), "OK")
    assert_equal(_ident_err(" <a@b> 1 +0000"), "OK")  # empty name
    assert_equal(_ident_err(""), p + "missing email")
    assert_equal(_ident_err("<a@b> 1 +0000"), p + "missing name before email")
    assert_equal(_ident_err("A > <a@b> 1 +0000"), p + "bad name")
    assert_equal(_ident_err("A U Thor 1 +0000"), p + "missing email")
    assert_equal(_ident_err("A<a@b> 1 +0000"), p + "missing space before email")
    assert_equal(_ident_err("A <a<b> 1 +0000"), p + "bad email")
    assert_equal(_ident_err("A <a@b 1 +0000"), p + "bad email")
    assert_equal(_ident_err("A <a@b>1 +0000"), p + "missing space before date")
    assert_equal(_ident_err("A <a@b> 01 +0000"), p + "zero-padded date")
    assert_equal(_ident_err("A <a@b> 0 +0000"), "OK")
    assert_equal(_ident_err("A <a@b> 0x +0000"), p + "zero-padded date")
    assert_equal(_ident_err("A <a@b>  1 +0000"), p + "extra whitespace before date")
    assert_equal(_ident_err("A <a@b> \t1 +0000"), p + "extra whitespace before date")
    assert_equal(_ident_err("A <a@b> x +0000"), p + "bad date")
    assert_equal(_ident_err("A <a@b> 1+0000"), p + "bad date")
    assert_equal(_ident_err("A <a@b> 1 0000"), p + "bad timezone")
    assert_equal(_ident_err("A <a@b> 1 +000"), p + "bad timezone")
    assert_equal(_ident_err("A <a@b> 1 +0000 "), p + "bad timezone")
    assert_equal(_ident_err("A <a@b> 1 +000x"), p + "bad timezone")
    try:
        _ = Signature("A <x>", "a@b", 1, "+0000")
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            "komira_git: signature name holds '<', '>', a line break or NUL",
        )
    try:
        _ = Signature("A", "a@b", 1, "0000")
        assert_true(False)
    except e:
        assert_equal(
            String(e),
            "komira_git: signature time zone '0000' is not +hhmm or -hhmm",
        )


def test_commit_refusals() raises:
    var t = "tree 087704a96baf1c2d1c869a8b084481e121c88b5b\n"
    var a = "author " + String(_A) + "\n"
    var c = "committer " + String(_C) + "\n"
    assert_equal(_commit_err(t + a + c + "\nm"), "OK")
    assert_equal(_commit_err(a + c + "\nm"), "komira_git: commit: missing 'tree' line")
    assert_equal(
        _commit_err("tree 087704A96BAF1C2D1C869A8B084481E121C88B5B\n" + a + c + "\n"),
        "komira_git: commit: bad 'tree' id",
    )
    assert_equal(
        _commit_err("tree 087704a9\n" + a + c + "\n"),
        "komira_git: commit: bad 'tree' id",
    )
    assert_equal(
        _commit_err(t + "parent 12\n" + a + c + "\n"),
        "komira_git: commit: bad 'parent' id",
    )
    assert_equal(_commit_err(t + c + "\n"), "komira_git: commit: missing 'author' line")
    assert_equal(
        _commit_err(t + a + a + c + "\n"),
        "komira_git: commit: more than one 'author' line",
    )
    assert_equal(_commit_err(t + a + "\n"), "komira_git: commit: missing 'committer' line")
    assert_equal(
        _commit_err(t + a + c + "m"),
        "komira_git: commit: no empty line after the header",
    )
    assert_equal(
        _commit_err(t + a + c + " cont\n\n"),
        "komira_git: commit: continuation line without a header",
    )
    assert_equal(
        _commit_err(t + a + c + "nospace\n\n"),
        "komira_git: commit: header line without a space",
    )
    var nul = _b(t + a + c + "x y")
    nul.append(UInt8(0))
    var rest = _b("\n\n")
    nul.append(rest[0])
    nul.append(rest[1])
    try:
        _ = parse_commit(ObjectFormat.sha1(), Span(nul))
        assert_true(False)
    except e:
        assert_equal(String(e), "komira_git: commit: NUL in header")
    # A parent of another format cannot be serialized into the commit.
    var parents = List[ObjectId]()
    parents.append(ObjectId.zero(ObjectFormat.sha256()))
    var mixed = Commit(
        ObjectId.zero(ObjectFormat.sha1()),
        parents^,
        Signature("A", "a@b", 1, "+0000"),
        Signature("A", "a@b", 1, "+0000"),
        List[ExtraHeader](),
        List[UInt8](),
    )
    try:
        _ = mixed.serialize()
        assert_true(False)
    except e:
        assert_equal(
            String(e), "komira_git: commit: a sha256 parent in a sha1 commit"
        )


def test_tag_refusals() raises:
    var o = "object 087704a96baf1c2d1c869a8b084481e121c88b5b\n"
    assert_equal(_tag_err(o + "type tree\ntag x\n\n"), "OK")
    assert_equal(_tag_err("type tree\ntag x\n\n"), "komira_git: tag: missing 'object' line")
    assert_equal(_tag_err("object 1\ntype tree\ntag x\n\n"), "komira_git: tag: bad 'object' id")
    assert_equal(_tag_err(o + "tag x\n\n"), "komira_git: tag: missing 'type' line")
    assert_equal(_tag_err(o + "type branch\ntag x\n\n"), "komira_git: tag: bad 'type' line")
    assert_equal(_tag_err(o + "type tree\n\n"), "komira_git: tag: missing 'tag' line")
    assert_equal(
        _tag_err(o + "type tree\ntag x\ntagger <a@b> 1 +0000\n\n"),
        "komira_git: tag tagger: missing name before email",
    )
    assert_equal(_tag_err(o + "type tree\ntag x\n"), "komira_git: tag: no empty line after the header")


def _parse_time(line: String) raises -> Int:
    var b = _b(line)
    return parse_signature(Span(b), "commit author").time


def test_date_range() raises:
    var p = "komira_git: commit author: "
    # git 2.51.0 `git commit-tree` writes this date and `git fsck --strict`
    # accepts it: fsck's badDateOverflow is by value (above 2^63-1 here,
    # where time_t is 64 bits), not by digit count.
    var line = "A <a@b> 1234567890123456789 +0000"
    assert_equal(_parse_time(line), 1234567890123456789)
    assert_equal(_parse_time("A <a@b> 9223372036854775807 +0000"), 9223372036854775807)
    var b = _b(line)
    assert_true(_same(parse_signature(Span(b), "x").serialize(), b))
    assert_equal(_ident_err("A <a@b> 9223372036854775808 +0000"), p + "date overflows")
    assert_equal(_ident_err("A <a@b> 9999999999999999999 +0000"), p + "date overflows")
    assert_equal(_ident_err("A <a@b> 10000000000000000000 +0000"), p + "date overflows")
    assert_equal(_ident_err("A <a@b> 99999999999999999999999 +0000"), p + "date overflows")


def _sig_err(name: String, email: String, time: Int, tz: String) -> String:
    try:
        _ = Signature(name, email, time, tz)
    except e:
        return String(e)
    return String("OK")


def _hdr_err(key: String, value: String) -> String:
    try:
        _ = ExtraHeader(key, value)
    except e:
        return String(e)
    return String("OK")


def _tag_name_err(name: String) -> String:
    var t = Tag(
        ObjectId.zero(ObjectFormat.sha1()),
        ObjectKind.tree(),
        List[UInt8](name.as_bytes()),
        Optional[Signature](None),
        List[ExtraHeader](),
        List[UInt8](),
    )
    try:
        _ = t.serialize()
    except e:
        return String(e)
    return String("OK")


def _expect(mut fails: String, got: String, want: String):
    if got != want:
        fails += "\n  got: " + got + "\n  want: " + want


def test_constructor_refusals() raises:
    var fails = String()
    var nul = chr(0)
    var sig_email = "komira_git: signature email holds '<', '>', a line break or NUL"
    _expect(fails, _sig_err("A", "a@b", 0, "+0000"), "OK")
    _expect(fails, _sig_err("A", "a>b", 1, "+0000"), sig_email)
    _expect(fails, _sig_err("A", "a>\nparent x", 1, "+0000"), sig_email)
    _expect(fails, _sig_err("A", "a" + nul, 1, "+0000"), sig_email)
    _expect(fails, _sig_err("A", "a@b", -1, "+0000"), "komira_git: signature time is negative")
    _expect(
        fails,
        _sig_err("A", "a@b", 1, "+000x"),
        "komira_git: signature time zone '+000x' is not +hhmm or -hhmm",
    )
    _expect(fails, _ident_err("A <a@b> 1 +000x"), "komira_git: commit author: bad timezone")
    var key_msg = "komira_git: header key holds a space, line break or NUL"
    _expect(fails, _hdr_err("k", "v\nw"), "OK")
    _expect(fails, _hdr_err("", "v"), "komira_git: header key is empty")
    _expect(fails, _hdr_err("a b", "v"), key_msg)
    _expect(fails, _hdr_err("k\nparent", "v"), key_msg)
    _expect(fails, _hdr_err("k" + nul, "v"), key_msg)
    _expect(fails, _hdr_err("k", "a" + nul), "komira_git: header value holds NUL")
    var tag_msg = "komira_git: tag: name holds a line break or NUL"
    _expect(fails, _tag_name_err("v1"), "OK")
    _expect(fails, _tag_name_err("x\ntagger A <a@b> 1 +0000"), tag_msg)
    _expect(fails, _tag_name_err("x" + nul), tag_msg)
    assert_equal(fails, "")


def main() raises:
    test_commit_vectors()
    test_merge_commit()
    test_tag_vectors()
    test_signature_refusals()
    test_date_range()
    test_constructor_refusals()
    test_commit_refusals()
    test_tag_refusals()
    print("komira_git commit and tag tests passed")
