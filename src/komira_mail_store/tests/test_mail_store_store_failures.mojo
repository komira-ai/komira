# =============================================================================
# test_mail_store_store_failures: a store failure is never read as "absent"
#
# `_FailStore` delegates to an in-memory store and, for one chosen verb, raises
# an error shaped like the cloud conformers' (the key sits inside the message:
# `StoreError[<KIND>] <verb> <scheme>://<bucket>/<key> status=<http>`) or like
# a local file system's (the key percent-encoded into a file name).
#
# fetch_message and message_exists treat a not-found error as absence and every
# other error as a failure; store_message treats a precondition error as a
# duplicate and every other error as a failure. The key is inside the message,
# so a folder `Not_Found` (key `.../not_found/...`) or a recipient
# `precondition@...` must not turn a 403 or a 500 into "absent" or "lost
# write", and a leaf must not be able to spell either.
# Catches: a credential or outage error reported as an absent message;
# a non-412 put error taken for a duplicate; a leaf that smuggles an error
# marker into the key; any error swallowed as `found = False` / `False`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_mail_store import (
    fetch_message,
    folder_message_key,
    message_exists,
    store_message,
)

comptime LEAF = "0123456789abcdef"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _hex_upper(nib: Int) -> String:
    if nib < 10:
        return chr(0x30 + nib)
    return chr(0x41 + nib - 10)


def _file_name(key: String) -> String:
    """`key` as one file name: every byte outside `[A-Za-z0-9._-]` as `%XX`."""
    var bs = key.as_bytes()
    var out = String("")
    for i in range(len(bs)):
        var c = Int(bs[i])
        var safe = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord(".")
            or c == ord("_")
            or c == ord("-")
        )
        if safe:
            out += chr(c)
        else:
            out += "%" + _hex_upper(c >> 4) + _hex_upper(c & 0xF)
    return out^


def _kind(code: Int) -> String:
    if code == 404:
        return "NOT_FOUND"
    if code == 412:
        return "PRECONDITION"
    if code == 403:
        return "PERMISSION_DENIED"
    return "TRANSPORT"


struct _FailStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """Fails `verb` (`head`, `get`, `put`, or `*` for all) with `code`.
    `style` 0 is the cloud message shape, 1 the local file system's."""

    var inner: SharedInMemoryConditionalStore
    var verb: String
    var code: Int
    var style: Int

    def __init__(out self):
        self.inner = SharedInMemoryConditionalStore()
        self.verb = String("")
        self.code = 0
        self.style = 0

    def arm(mut self, verb: String, code: Int, style: Int):
        self.verb = verb
        self.code = code
        self.style = style

    def disarm(mut self):
        self.verb = String("")

    def _check(self, verb: String, path: Path) raises:
        if self.verb != verb and self.verb != "*":
            return
        var key = path.raw()
        if self.style == 1:
            raise Error(
                "open('/var/mail/"
                + _file_name(key)
                + "'): Permission denied (errno 13)"
            )
        raise Error(
            "StoreError["
            + _kind(self.code)
            + "] "
            + verb
            + " mem://bucket/"
            + key
            + " status="
            + String(self.code)
        )

    def head(self, path: Path) raises -> ObjectMeta:
        self._check("head", path)
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._check("put", path)
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._check("get", path)
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _fetch_err(mut s: _FailStore, r: String, f: String, leaf: String) -> String:
    """The error `fetch_message` raised, or "" if it returned."""
    try:
        _ = fetch_message(s, r, f, leaf)
        return String("")
    except e:
        return String(e)


def _exists_err(mut s: _FailStore, r: String, f: String, leaf: String) -> String:
    try:
        _ = message_exists(s, r, f, leaf)
        return String("")
    except e:
        return String(e)


def _store_err(mut s: _FailStore, r: String, f: String, raw: String) -> String:
    try:
        _ = store_message(s, r, f, _bytes(raw))
        return String("")
    except e:
        return String(e)


def _needle(code: Int, style: Int) -> String:
    """What the injected error says, in either message shape."""
    if style == 1:
        return String("Permission denied")
    return String("status=") + String(code)


def _has(msg: String, needle: String) -> Bool:
    return msg.find(needle) >= 0


def _both_raise(
    mut s: _FailStore, r: String, f: String, leaf: String, needle: String
) -> Bool:
    """fetch_message and message_exists both raise an error holding `needle`."""
    return _has(_fetch_err(s, r, f, leaf), needle) and _has(
        _exists_err(s, r, f, leaf), needle
    )


def _absent(mut s: _FailStore, r: String, f: String, leaf: String) raises -> Bool:
    """fetch_message says not found and message_exists says False."""
    var got = fetch_message(s, r, f, leaf)
    return (not got.found) and (not message_exists(s, r, f, leaf))


def test_failures_in_an_ordinary_folder_propagate() raises:
    var s = _FailStore()
    var o = store_message(s, "a@x", "INBOX", _bytes("m"))
    s.arm("head", 500, 0)
    assert_true(_both_raise(s, "a@x", "INBOX", o.leaf, "status=500"), "head 500")
    s.arm("head", 403, 0)
    assert_true(_both_raise(s, "a@x", "INBOX", o.leaf, "status=403"), "head 403")
    s.arm("get", 500, 0)
    assert_true(
        _has(_fetch_err(s, "a@x", "INBOX", o.leaf), "status=500"), "get 500"
    )
    s.arm("put", 500, 0)
    assert_true(
        _has(_store_err(s, "a@x", "INBOX", "n"), "status=500"),
        "a put 500 is raised, not taken for a duplicate",
    )
    assert_true(
        _has(_store_err(s, "a@x", "Sent", "n"), "status=500"), "in a folder"
    )
    s.arm("put", 403, 1)
    assert_true(
        _has(_store_err(s, "a@x", "INBOX", "n"), "Permission denied"),
        "a local put error is raised",
    )


def test_a_not_found_error_is_absence() raises:
    var s = _FailStore()
    s.arm("head", 404, 0)
    assert_true(_absent(s, "a@x", "INBOX", LEAF), "a 404 on head is absent")
    assert_true(_absent(s, "a@x", "Sent", LEAF), "in a folder")
    # The real absence of the in-memory store reads the same.
    s.disarm()
    assert_true(_absent(s, "a@x", "INBOX", LEAF), "a real miss is absent")


def test_a_folder_named_not_found_cannot_hide_a_failure() raises:
    # The folder `Not_Found` keys as `.../not_found/...`; the error names it.
    for style in range(2):
        var s = _FailStore()
        var o = store_message(s, "r@x", "Not_Found", _bytes("m"))
        assert_true(
            _has(o.key, "not_found"), "the key spells the not-found marker"
        )
        s.arm("head", 403, style)
        assert_true(
            _both_raise(s, "r@x", "Not_Found", o.leaf, _needle(403, style)),
            "head 403",
        )
        s.arm("head", 500, style)
        assert_true(
            _both_raise(s, "r@x", "not_found", o.leaf, _needle(500, style)),
            "head 500",
        )
        s.arm("get", 403, style)
        assert_true(
            _has(
                _fetch_err(s, "r@x", "NOT_FOUND", o.leaf), _needle(403, style)
            ),
            "get 403",
        )
        # A real 404 still reads as absent in that folder.
        s.arm("head", 404, 0)
        assert_true(_absent(s, "r@x", "Not_Found", LEAF), "a 404 is absent")
        s.disarm()
        assert_true(_absent(s, "r@x", "Not_Found", LEAF), "a real miss")
        assert_true(fetch_message(s, "r@x", "Not_Found", o.leaf).found, "found")


def test_a_recipient_named_precondition_is_not_a_lost_write() raises:
    # `precondition@example.com` keys as `precondition_40example.com`.
    var s = _FailStore()
    s.arm("put", 403, 0)
    var err = _store_err(s, "precondition@example.com", "INBOX", "m")
    assert_true(_has(err, "status=403"), "the original 403 is raised: " + err)
    s.arm("put", 500, 0)
    err = _store_err(s, "Precondition@example.com", "Sent", "m")
    assert_true(_has(err, "status=500"), "the original 500 is raised: " + err)
    s.arm("put", 403, 1)
    err = _store_err(s, "precondition@example.com", "INBOX", "m")
    assert_true(_has(err, "Permission denied"), "a local error: " + err)


def test_a_lost_write_is_a_duplicate_not_a_failure() raises:
    var s = _FailStore()
    var first = store_message(s, "precondition@example.com", "INBOX", _bytes("m"))
    assert_true(first.created, "first")
    s.arm("put", 412, 0)
    var again = store_message(s, "precondition@example.com", "INBOX", _bytes("m"))
    assert_false(again.created, "a 412 over equal bytes is a duplicate")
    assert_equal(again.key, first.key, "same key")
    # A 412 over different bytes under the same key is a refused collision.
    var impostor = folder_message_key("c@x", "INBOX", first.leaf)
    _ = s.put(Path.parse(impostor), _bytes("someone else"))
    var err = _store_err(s, "c@x", "INBOX", "m")
    assert_true(_has(err, "share the content hash"), "collision: " + err)


def test_a_leaf_is_sixteen_lowercase_hex_digits() raises:
    # A store that fails everything with a 404-shaped error: a leaf that could
    # carry a marker into the key would read as "absent".
    var s = _FailStore()
    s.arm("*", 404, 0)
    var bad = List[String]()
    bad.append("x status=404")
    bad.append("[NOT_FOUND]")
    bad.append("StoreError[NOT_FOUND]")
    bad.append("NotFound")
    bad.append("NoSuchKey")
    bad.append("not_found")
    bad.append("0123456789ABCDEF")
    bad.append("0123456789abcde")
    bad.append("0123456789abcdef0")
    bad.append("0123456789abcdeg")
    bad.append("0123456789abcdef.eml")
    bad.append(" 0123456789abcdef")
    bad.append("0123456789abcde" + chr(0))
    bad.append("0123456789abcd/f")
    bad.append("..")
    bad.append(".")
    bad.append("")
    for i in range(len(bad)):
        var f = _fetch_err(s, "r@x", "INBOX", bad[i])
        assert_true(_has(f, "mail leaf"), "fetch refuses leaf " + String(i))
        var e = _exists_err(s, "r@x", "Not_Found", bad[i])
        assert_true(_has(e, "mail leaf"), "exists refuses leaf " + String(i))
    # The same store reaches a proper leaf: absent, because it is a 404.
    assert_true(_absent(s, "r@x", "INBOX", LEAF), "a hex leaf reaches the store")
    assert_true(_absent(s, "r@x", "INBOX", "ffffffffffffffff"), "all f")
    assert_true(_absent(s, "r@x", "INBOX", "0000000000000000"), "all 0")


def main() raises:
    test_failures_in_an_ordinary_folder_propagate()
    test_a_not_found_error_is_absence()
    test_a_folder_named_not_found_cannot_hide_a_failure()
    test_a_recipient_named_precondition_is_not_a_lost_write()
    test_a_lost_write_is_a_duplicate_not_a_failure()
    test_a_leaf_is_sixteen_lowercase_hex_digits()
    print("test_mail_store_store_failures: ALL PASS")
