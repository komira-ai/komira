# komira_git

Git's object model and wire primitives in pure Mojo, with no I/O: every
function maps bytes to values or values to bytes. It holds the object model
and the pack reader that the protocol and storage layers of a git server or
client build on.

- **Object formats and ids.** `ObjectFormat.sha1()` and
  `ObjectFormat.sha256()` (`from_name`, `raw_size`, `hex_size`, `name`).
  An `ObjectId` carries its format, so ids of the two formats never compare
  equal: `ObjectId.parse_hex`, `from_raw`, `zero`, `to_hex`, `raw_bytes`,
  `append_raw_to`, `append_hex_to`, `byte_at`, `is_zero`, `format`.
  `hash_object(format, kind, payload)` is what `git hash-object -t <kind>`
  prints: the hash of `object_header(kind, size)` (`<kind> <size>\0`) then
  the payload. `ObjectKind` is `commit`, `tree`, `blob` or `tag`
  (`from_name`, `from_code`, `code` (git's type numbers 1 to 4), `name`).
- **Trees.** `Tree(format)`, `Tree.add(mode, name, id)`, `sorted_entries`,
  `serialize`, `id`; `parse_tree(format, payload)`; `TreeEntry` (`mode`,
  `name`, `id`, `is_tree`, `kind`). The modes are the five git writes
  (`MODE_BLOB`, `MODE_EXECUTABLE`, `MODE_SYMLINK`, `MODE_TREE`,
  `MODE_GITLINK`; `is_valid_mode`, `mode_text`), and the order is git's:
  `tree_entry_compare` compares a subtree's name as if it ended in `/`.
- **Commits and tags.** `Commit` (`serialize`, `id`, `format`) and
  `parse_commit`; `Tag` (`serialize`, `id`, `format`) and `parse_tag`;
  their `Signature`s (`serialize`, `append_to`; `parse_signature`) and
  `ExtraHeader`s (`append_to`; `encoding`, `gpgsig`, `mergetag`, ... kept in
  order).
- **Loose objects.** `encode_loose(kind, payload)` (zlib at
  `LOOSE_LEVEL`, git's level 1), `decode_loose(bytes, max_size)` into a
  `LooseObject`, `read_loose(expected_id, bytes, max_size)`, which also
  checks the hash, and `loose_path(id)`.
- **pkt-line.** `append_pkt_data`, `append_pkt_text`, `append_pkt_flush`,
  `append_pkt_delim`, `append_pkt_response_end`, and the sans-I/O reader
  `read_pkt_line(data, offset)`, which returns a `PktLine` of kind
  `PKT_DATA`, `PKT_FLUSH`, `PKT_DELIM`, `PKT_RESPONSE_END`, or
  `PKT_NEED_MORE` when the input ends mid-line (`PKT_MAX_PAYLOAD`,
  `PKT_MAX_LENGTH`).
- **Ref names.** `check_ref_format(name, allow_onelevel, refspec_pattern)`
  (and `check_ref_name` over bytes), `is_valid_ref_name` and
  `normalize_ref_name`: the rules of `git check-ref-format`, checked in
  git's order, each refusal naming its rule.
- **Packs.** `index_pack(format, pack, limits)` does what `git index-pack`
  does: it checks the header and the trailer, walks every entry, resolves
  OFS_DELTA and REF_DELTA entries (a REF_DELTA base may be anywhere in the
  pack) and returns an `IndexedPack`: the `PackIndex` and, per entry in pack
  order, a `PackEntryInfo` (`id`, `kind`, `type_code`, `offset`,
  `packed_size`, `crc32`, `depth`, `base_id`, as `git verify-pack -v` lists
  them). `index_thin_pack` also takes `ExternalBases`, the objects a thin
  pack's deltas may name outside it. `read_pack_object(pack, index, id,
  limits)` (and `read_thin_pack_object`) reads one object as a
  `PackObject` (`kind`, `payload`) and refuses one that does not hash to
  `id`. `PackIndex` (`count`, `id_at`, `offset_at`, `crc32_at`, `find`,
  `pack_checksum`) is written as an index v2 file by `serialize` (byte-equal
  to `git index-pack`'s; offsets over a threshold, 0x7fffffff by default, in
  the eight-byte table) and read by `parse_pack_index`. `apply_delta(base,
  delta, max_size)` and `read_delta_header` are git's delta format.
  `PackLimits` bounds the object count, each object's size, the delta chain
  depth (4095 by default, the deepest `git pack-objects` writes) and the
  bytes one index or read call may inflate (`max_inflate_ratio` times the
  pack size plus one object), each checked before the work it bounds.

## What the parsers accept

Each parser refuses what `git fsck` reports as an error, plus these forms
git accepts but does not write today, so an accepted object serializes back
to its own bytes and id:

- an id spelled in upper-case hex;
- a commit or tag with no empty line after its header;
- more than one space, or a tab, between an ident's `>` and its date (git
  fsck skips them; older git wrote them);
- an extra header line holding no space, and a line starting with a space
  directly after `committer`, `tag` or `tagger` (a continuation of a header
  that is not kept as an extra header);
- a zero-padded or legacy tree mode such as `100664`.

An ident date is accepted up to 2^63-1 (19 digits), as `git fsck` accepts
it; above that it is refused as fsck's badDateOverflow refuses it.
A tag with no `tagger` line (early tags such as Linux's `v2.6.11-tree`
have none) is accepted, as `git fsck` accepts it. A tree name of `.`, `..` or `.git` (any letter case) is
refused; the HFS+ and NTFS spellings of `.git` that `git fsck` also
reports are not yet checked.

## Object formats

SHA-1 is the format in use today. Ids carry their format from the start,
and the object layer already hashes and
parses SHA-256 objects (32-byte ids in trees, 64-digit ids in commit and tag
headers), checked against git's own SHA-256 vectors. What a SHA-256
repository needs beyond objects (the protocol's `object-format` capability,
the SHA-1/SHA-256 compatibility map) is not here. SHA-1 here is plain
SHA-1: collision detection is a separate, later module.

## Examples

Hash a blob and build a tree, under both formats (ids from git's test
suite, `t/oid-info/hash-info` and `t/t0000-basic.sh`):

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_git import MODE_BLOB, ObjectFormat, ObjectKind, Tree, hash_object

var empty = List[UInt8]()
for f in range(2):
    var format = ObjectFormat.sha1() if f == 0 else ObjectFormat.sha256()
    var blob = hash_object(format, ObjectKind.blob(), Span(empty))
    var tree = Tree(format)
    tree.add(MODE_BLOB, "should-be-empty", blob)
    if f == 0:
        assert_equal(blob.to_hex(), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        assert_equal(tree.id().to_hex(), "7bb943559a305bdd6bdee2cef6e5df2413c3d30a")
    else:
        assert_equal(
            tree.id().to_hex(),
            "1710c07a6c86f9a3c7376364df04c47ee39e5a5e221fcdd84b743bc9bb7e2bc5",
        )
```

Parse a commit, read its fields, and get the same bytes and id back:

```mojo
from komira_git import ObjectFormat, parse_commit

var text = String(
    "tree "
    "087704a96baf1c2d1c869a8b084481e121c88b5b"
    "\n"
    "author A U Thor <author@example.com> 1112911993 -0700\n"
    "committer C O Mitter <committer@example.com> 1112911993 -0700\n"
    "\nInitial commit\n"
)
var payload = List[UInt8](text.as_bytes())
var commit = parse_commit(ObjectFormat.sha1(), Span(payload))
assert_equal(commit.author.time, 1112911993)
assert_equal(commit.committer.tz, "-0700")
assert_equal(len(commit.parents), 0)
assert_equal(len(commit.serialize()), len(payload))
assert_equal(commit.id().to_hex(), "bb0e40b5d718273d8cd5d4806d4913aa21783ef4")
```

Write a loose object and read it back by id:

```mojo
from komira_git import ObjectFormat, ObjectKind, encode_loose, hash_object, loose_path, read_loose

var content = List[UInt8](String("hello path0\n").as_bytes())
var id = hash_object(ObjectFormat.sha1(), ObjectKind.blob(), Span(content))
var file = encode_loose(ObjectKind.blob(), Span(content))
var back = read_loose(id, Span(file), 1 << 20)
assert_true(back.kind == ObjectKind.blob())
assert_equal(len(back.payload), 12)
assert_equal(loose_path(id), "f8/7290f8eb2cbbea7857214459a0739927eab154")
```

Frame and read pkt-lines (the examples of gitprotocol-common):

```mojo
from komira_git import PKT_DATA, PKT_FLUSH, PKT_NEED_MORE, append_pkt_flush, append_pkt_text, read_pkt_line

var wire = List[UInt8]()
append_pkt_text(wire, "a\n")
append_pkt_flush(wire)
var first = read_pkt_line(Span(wire), 0)
assert_equal(first.kind, PKT_DATA)
assert_equal(first.consumed, 6)  # "0006a\n"
var second = read_pkt_line(Span(wire), first.consumed)
assert_equal(second.kind, PKT_FLUSH)
var half = List[UInt8](String("0006a").as_bytes())
assert_equal(read_pkt_line(Span(half), 0).kind, PKT_NEED_MORE)
```

Check ref names as `git check-ref-format` does:

```mojo
from komira_git import check_ref_format, is_valid_ref_name, normalize_ref_name

assert_true(is_valid_ref_name("refs/heads/main"))
assert_false(is_valid_ref_name("refs/heads/topic.lock"))
assert_false(is_valid_ref_name("refs/heads/v@{1}"))
assert_true(is_valid_ref_name("main", allow_onelevel=True))
assert_equal(normalize_ref_name("refs///heads/main"), "refs/heads/main")
try:
    check_ref_format("refs/heads/a..b")
    assert_true(False)
except e:
    assert_equal(String(e), "komira_git: bad ref name: contains '..'")
```

Apply a delta (a copy of the base's first five bytes, then an insert):

```mojo
from komira_git import apply_delta

var base = List[UInt8](String("hello, world").as_bytes())
var delta = List[UInt8]()
for b in [12, 8, 0x90, 5, 3, 33, 33, 33]:
    delta.append(UInt8(b))
var out = apply_delta(Span(base), Span(delta), 1 << 20)
assert_equal(len(out), 8)  # "hello!!!"
assert_equal(Int(out[4]), 111)
assert_equal(Int(out[5]), 33)
```
