"""OBJECT STORES — a listing's COMMON PREFIX must be the KEY'S OWN BYTES.

★ THE HAZARD. Rebuilding a substring of a key with a per-byte
`out += chr(Int(b))` loop — as `DelimiterFaithfulConditionalStore`'s
`_df_substr_from` / `_df_substr_range` must NOT do at the two sites that build
`common_prefixes` and split the remainder — corrupts non-ASCII keys.

`chr(Int(b))` maps a byte to the CODEPOINT of that number, and appending a
codepoint to a String UTF-8-ENCODES it. So a byte >= 0x80 comes back out as the
TWO bytes of its Latin-1 codepoint: 0xC3 -> U+00C3 -> `0xC3 0x83`. Any key with
a non-ASCII byte would therefore yield a common prefix that is a DOUBLE ENCODING
of itself — a string that is not a prefix of any key in the store.

★ WHY THIS IS A GATE HOLE AND NOT MERELY A BUG. Recursive walks that ERASE a
tree of keys and AUDIT that erasure descend by feeding `common_prefixes` BACK IN
as the next prefix. A double-encoded prefix matches nothing, so the walk
silently returns ZERO keys for that subtree: the sweep erases nothing under it,
and the AUDIT that is supposed to prove the sweep complete reports zero
survivors — over exactly the non-ASCII input class (`refs/heads/機能` is a
valid git ref name). The gate cannot see the input class it exists to check.
That is worse than a missing gate, because it prints green.

★ A REAL GCS LISTING IS BYTE-FAITHFUL (it decodes protobuf strings without a
per-byte `chr`), so this is a TEST-SUBSTRATE hazard: this store is the
substrate hermetic falsifiers run on, and it is load-bearing for whether any
assertion about erasure means anything.

THE FAILURE IT CATCHES: with key `p/\xe6\xa9\x9fx/leaf`, a `chr`-based store
lists `p/` as common_prefixes[0] == `p/\xc3\xa6\xc2\xa9\xc2\x9fx/` — 4 bytes
longer than the 9-byte truth, and listing THAT prefix returns 0 objects and 0
common prefixes, so the subtree is invisible. GATE 3's round trip is the same
measurement stated as a walk: the recursive descent must find the ASCII leaf
AND the non-ASCII one.
"""

from komira_objectstore.path import Path
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)


comptime _Store = DelimiterFaithfulConditionalStore


def _hex(b: List[UInt8]) -> String:
    comptime digits = String("0123456789abcdef")
    var d = digits.as_bytes()
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(d[Int(b[i] >> 4)]))
        out += chr(Int(d[Int(b[i] & 0xF)]))
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _put(mut store: _Store, key: String) raises:
    var body = List[UInt8]()
    body.append(UInt8(120))
    _ = store.put(Path.parse(key), body)


def _walk(
    mut store: _Store, prefix: String, mut out: List[String], depth: Int
) raises:
    """Descend by feeding `common_prefixes` back in — the SAME shape as every
    production mount walk and every falsifier's audit."""
    if depth > 20:
        return
    var res = store.list_with_delimiter(Path.parse(prefix))
    for i in range(len(res.objects)):
        out.append(res.objects[i].location)
    for i in range(len(res.common_prefixes)):
        _walk(store, res.common_prefixes[i], out, depth + 1)


def main() raises:
    # A non-leaf component carrying a multi-byte UTF-8 codepoint. `機` is
    # U+6A5F = e6 a9 9f — the same shape as `refs/heads/機能`, which stock
    # `git check-ref-format` accepts and this host now accepts too.
    var nonascii = String("機") + String("x")
    var mid = String("p/") + nonascii + String("/")
    var leaf = mid + String("leaf")

    var store = _Store()
    _put(store, leaf)
    _put(store, String("p/ascii/leaf"))

    # -------------------------------------------------------------------------
    # GATE 1 — the common prefix must be the key's OWN BYTES.
    # -------------------------------------------------------------------------
    var res = store.list_with_delimiter(Path.parse(String("p/")))
    if len(res.common_prefixes) != 2:
        raise Error(
            "GATE1: expected 2 common prefixes under `p/`, got "
            + String(len(res.common_prefixes))
        )
    var found = False
    var got = String("")
    for i in range(len(res.common_prefixes)):
        if res.common_prefixes[i].find(String("ascii")) < 0:
            got = res.common_prefixes[i].copy()
            found = True
    if not found:
        raise Error("GATE1: the non-ASCII common prefix is absent entirely")
    if got != mid:
        raise Error(
            "GATE1: the common prefix is not the key's bytes. A per-byte"
            " `chr(Int(b))` rebuild re-encodes every byte >= 0x80 as the TWO"
            " bytes of its Latin-1 codepoint, so the returned prefix is a"
            " DOUBLE ENCODING and is a prefix of NO key in the store."
            " expected="
            + _hex(_bytes(mid))
            + " ("
            + String(len(mid.as_bytes()))
            + " bytes) got="
            + _hex(_bytes(got))
            + " ("
            + String(len(got.as_bytes()))
            + " bytes)"
        )
    print("GATE 1 (common prefix is byte-faithful) OK")

    # -------------------------------------------------------------------------
    # GATE 2 — that prefix must be USABLE as the next listing's prefix. This is
    # the property the recursive walks actually depend on; gate 1 alone would
    # pass for a prefix that is byte-equal but that the store cannot match.
    # -------------------------------------------------------------------------
    var res2 = store.list_with_delimiter(Path.parse(got))
    if len(res2.objects) != 1:
        raise Error(
            "GATE2: listing the returned common prefix `"
            + _hex(_bytes(got))
            + "` found "
            + String(len(res2.objects))
            + " objects, expected 1. A prefix a store hands back that the same"
            " store then matches NOTHING against makes every recursive mount"
            " walk silently skip the subtree — the sweep erases nothing there"
            " and the audit still reports 0 survivors."
        )
    if res2.objects[0].location != leaf:
        raise Error(
            "GATE2: listing `" + got + "` returned the wrong key: "
            + res2.objects[0].location
        )
    print("GATE 2 (the returned prefix is usable as a prefix) OK")

    # -------------------------------------------------------------------------
    # GATE 3 — THE WALK. The property in the shape production uses it.
    # -------------------------------------------------------------------------
    var seen = List[String]()
    _walk(store, String("p/"), seen, 0)
    if len(seen) != 2:
        raise Error(
            "GATE3: a recursive descent over `p/` found "
            + String(len(seen))
            + " of 2 keys. A walk that cannot reach a subtree is exactly a"
            " sweep that cannot erase it and an audit that cannot see the"
            " survivors."
        )
    var saw_leaf = False
    for i in range(len(seen)):
        if seen[i] == leaf:
            saw_leaf = True
    if not saw_leaf:
        raise Error(
            "GATE3: the walk missed the non-ASCII-component key `"
            + _hex(_bytes(leaf))
            + "`; it found: "
            + String(len(seen))
            + " key(s), none of them it"
        )
    print("GATE 3 (the recursive walk reaches a non-ASCII subtree) OK")

    # -------------------------------------------------------------------------
    # GATE 4 — the leaf split must be byte-faithful too. `_df_substr_from`
    # builds the remainder that decides leaf-vs-rollup; a double-encoded
    # remainder still has no '/' so it is classified correctly, but the
    # ObjectMeta must carry the REAL key. Assert the key round-trips to a
    # readable object.
    # -------------------------------------------------------------------------
    var direct = store.list_with_delimiter(Path.parse(mid))
    if len(direct.objects) != 1:
        raise Error(
            "GATE4: direct listing of the true prefix found "
            + String(len(direct.objects))
            + " objects, expected 1"
        )
    var body = store.get(Path.parse(direct.objects[0].location))
    if len(body) != 1:
        raise Error(
            "GATE4: the listed key `"
            + direct.objects[0].location
            + "` is not readable — the listing returned a key that is not the"
            " stored key"
        )
    print("GATE 4 (listed keys are the stored keys) OK")

    print("ALL GATES PASS — delimiter listing is byte-faithful")
