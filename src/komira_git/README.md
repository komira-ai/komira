# komira_git

Git's object model, wire primitives, pack reader and protocol state
machines in pure Mojo, with no I/O: every function maps bytes to values or
values to bytes. It is the base the storage layers and the transports
(smart HTTP) of a git server or client build on.

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
- **SHA-1 with collision detection.** `Sha1dc` (`update`, `finalize_into`,
  `digest`, `collision_found`, and the switches `set_safe_hash`,
  `set_use_ubc`, `set_detect_collision`,
  `set_detect_reduced_round_collision`) and the one-shot `sha1dc(data)`: a
  pure-Mojo port of sha1collisiondetection, the SHA-1 git hashes with.
  `hash_object` (and so `read_loose` and every `id()`) computes SHA-1 ids
  with it and raises an error starting with `OBJECT_ID_COLLISION` for an
  object holding a block of a detected collision; `is_object_id_collision`
  tells that error from the others.
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
- **Input in pieces and side-band.** `PktReader` (`feed`, `read`, `mark`,
  `rewind`, `buffered`, `take_buffered`) buffers what arrives and hands
  out pkt-lines; `append_sideband(out, band, data)` frames data on band
  `SIDEBAND_DATA`, `SIDEBAND_PROGRESS` or `SIDEBAND_ERROR`, at most
  `SIDEBAND_MAX_CHUNK` bytes a line.
- **Fetch, server side (protocol v2).** `UploadPackV2Server(agent, format)`:
  `append_advertisement`, `feed`, and `next_request`, which returns a
  `V2Request` whose `command` is `V2_LS_REFS` or `V2_FETCH` (with
  `ls_refs: LsRefsArgs` or `fetch: FetchArgs`), `V2_END` when the client
  ends the session, or `V2_NEED_MORE`. `append_ls_refs_response(out,
  args, head, refs)` lists `AdvertisedRef`s (`name`, `id`,
  `symref_target`, `peeled`; `is_unborn`, `is_symref`, `has_peeled`).
  `negotiate(args, graph)` reads the repository through a `CommitGraph`
  (`has_object`, `is_commit`, `parents`, `peel`) and returns the
  `Negotiation` (the haves to acknowledge, and `ready`);
  `FetchResponder(args)` writes the response sections in their one order:
  `append_acknowledgments`, `append_shallow_info`,
  `append_packfile_header`, then `append_pack_data`, `append_progress`,
  `append_fatal_error` and `finish`.
- **Fetch, client side.** `FetchV2Client(agent, format)`: `feed`,
  `read_advertisement` (into `capabilities`, a `ServerCapabilities` with
  `supports`, `value`, `supports_feature`), `append_ls_refs_request` and
  `read_ls_refs` (an `LsRefsResult`), `append_fetch_request` and
  `next_event`, which returns `FetchEvent`s: `FETCH_ACK`, `FETCH_NAK`,
  `FETCH_READY`, `FETCH_ROUND_END` (send the next round),
  `FETCH_SHALLOW`, `FETCH_UNSHALLOW`, `FETCH_PACK_DATA`,
  `FETCH_PROGRESS`, `FETCH_END`, or `FETCH_NEED_MORE`.
- **Push, server side (receive-pack).** `ReceivePackServer(config)` with a
  `ReceivePackConfig(agent, format, atomic, push_options)`
  (`capability_list`): `append_advertisement` (or
  `append_receive_pack_advertisement`), `feed`, `read_request` (a
  `PushRequest` of `PushCommand`s, `is_create`, `is_delete`,
  `needs_pack`) and `take_buffered` (the start of the pack). The caller
  decides each command in a `PushReport` (`reject`, `set_unpack_error`,
  `refuse_funny_refnames`, `final_reasons`, `accepted`), and
  `append_push_message` and `append_push_report` write the messages and
  the report-status. `reject` takes the verdicts git's update() makes
  (non-fast-forward, `FUNNY_REFNAME`, an update hook's refusal), and for
  those git's rules hold: an unpack failure fails every command with
  `UNPACKER_ERROR`, atomic or not; in an atomic push the first refused
  command keeps its reason and every other one reports
  `ATOMIC_PUSH_FAILURE`. git chomps one LF from each command, shallow and
  push-option line, and so does this server; libgit2 ends each command
  line with one.
- **Push, client side (send-pack).** `SendPackClient(agent, format)`:
  `feed`, `read_advertisement` (into `advertisement`, a
  `PushAdvertisement` with `supports` and `value`), `append_push_request`
  and `read_status` (a `PushStatus`).

## The protocol

The servers advertise git's own default advertisement: `agent`,
`ls-refs=unborn`, `fetch=shallow wait-for-done`, `server-option` and
`object-format` for fetch; `report-status report-status-v2 delete-refs
side-band-64k quiet atomic ofs-delta [push-options] object-format agent`
for push. A request using a feature not advertised (`filter`, `want-ref`,
`sideband-all`, `packfile-uris`) is refused with git's words for it. Push
is protocol v0 even for a v2 client, as in git: protocol v2 has no push
command.

The `shallow` feature's arguments (`shallow`, `deepen`, `deepen-relative`,
`deepen-since`, `deepen-not`) are all read and written; a `deepen-not`
ref is passed on as sent, for the repository to resolve.

Four behaviours differ from git:
- A push certificate (`push-cert`) is refused with this package's own
  message; git's receive-pack reads an unsolicited one.
- `deepen <n>` and `deepen-since <timestamp>` must be plain decimal (git's
  strtol and strtoumax would also read `0x10`, octal and an empty
  timestamp).
- `deepen` with `deepen-since` or `deepen-not` is refused when the request
  is read; git refuses it only when it would send the shallow-info.
- An atomic push with a refusal git makes before update() (a hidden ref,
  missing objects, a pre-receive hook's decline, inconsistent push
  options): git keeps each refused command's own reason and still applies
  the other commands; given to `reject`, such a refusal fails the whole
  push here (the first refused command keeps its reason, every other one
  reports `ATOMIC_PUSH_FAILURE`, none is accepted).

The repository is the caller's: which haves a server holds and whether
every want reaches one come from its `CommitGraph`; which commits a depth
cuts (the shallow and unshallow lines), the pack, and each push command's
verdict are computed by the caller and written by these state machines.
`negotiate` differs from git in one way: git stops its walk at commits
older than the oldest acknowledged have, and this walk does not, so it can
say `ready` a round sooner.

The requests the clients write and the responses the servers write are
byte for byte git's: `src/tests/conformance/komira_git_conformance`
compares them with transcripts of the pinned git on both ends.

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
the SHA-1/SHA-256 compatibility map) is not here.

## Collision detection

A SHA-1 id is computed as git computes it, with sha1collisiondetection
(see the licence notice in `sha1dc.mojo`): every 64-byte block is checked
against the 32 disturbance vectors of the known SHA-1 collision attacks,
and a block that is one half of such a near-collision is reported.
Ordinary input hashes to plain SHA-1. With detection on, the digest of a
reported input is upstream's "safe hash" (the block is compressed twice
more), not the SHA-1 its colliding twin shares. `sha1dc` and
`Sha1dc.digest` raise instead of returning it, and so does `hash_object`
for an object whose hash stream (`<kind> <size>\0`, then the payload)
holds a reported block.

Both SHAttered PDFs, hashed as they are, are reported by `sha1dc` and
`Sha1dc`. A blob whose content is one of those PDFs is not refused: its
hash stream starts with the 12-byte `blob 422435\0` header, so the
collision blocks no longer follow the PDF's own 192-byte prefix at a block
boundary, nothing is detected, and `hash_object` returns the id git gives
that blob.

The tests check the port against upstream's own test files (the digests
its `make test` asserts) and, in `komira_git_conformance`, against the C
library itself, including, for each disturbance vector, the message and
chaining value its recompression uses. A git object that holds a collision
block cannot be made from those files, so no test feeds `hash_object` a
colliding object; the detection it relies on is tested through `sha1dc`
and `Sha1dc`.

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

Hash with collision detection (FIPS 180-2's "abc" vector; ordinary input
is plain SHA-1 and reports no collision):

```mojo
from komira_git import Sha1dc, is_object_id_collision, sha1dc

var abc = List[UInt8](String("abc").as_bytes())
var digest = sha1dc(Span(abc))  # raises on a detected collision
assert_equal(digest[0], UInt8(0xA9))  # a9993e36...
var h = Sha1dc()
h.update(Span(abc))
var out = InlineArray[UInt8, 20](fill=0)
assert_false(h.finalize_into(out))  # True would mean: collision detected
assert_equal(out[19], UInt8(0x9D))  # ...9cd0d89d
assert_false(is_object_id_collision("komira_git: loose object: empty file"))
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

A protocol v2 ls-refs exchange, client and server in one process (the
transport only carries the bytes):

```mojo
from komira_git import V2_LS_REFS, AdvertisedRef, FetchV2Client, ObjectFormat, ObjectId
from komira_git import UploadPackV2Server, append_ls_refs_response

var sha1 = ObjectFormat.sha1()
var server = UploadPackV2Server("komira-git/1", sha1)
var client = FetchV2Client("komira-git/1", sha1)
var wire = List[UInt8]()
server.append_advertisement(wire)
client.feed(Span(wire))
assert_true(client.read_advertisement())
assert_true(client.capabilities.supports_feature("fetch", "shallow"))

var prefixes: List[String] = ["refs/heads/"]
var request = List[UInt8]()
client.append_ls_refs_request(request, prefixes)
server.feed(Span(request))
var r = server.next_request()
assert_equal(r.command, V2_LS_REFS)

var tip = ObjectId.parse_hex(sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
var refs = List[AdvertisedRef]()
refs.append(AdvertisedRef("refs/heads/main", tip))
refs.append(AdvertisedRef("refs/tags/v1", tip))
var head = AdvertisedRef("HEAD", tip, "refs/heads/main")
var response = List[UInt8]()
append_ls_refs_response(response, r.ls_refs, head^, refs)
client.feed(Span(response))
var listed = client.read_ls_refs()
assert_true(listed.complete)
assert_equal(len(listed.refs), 1)  # only refs/heads/ was asked for
assert_equal(listed.refs[0].name, "refs/heads/main")
```

An atomic push of two deletes, one refused by the server, so the other
fails too:

```mojo
from komira_git import AdvertisedRef, ObjectFormat, ObjectId, PushCommand, PushReport
from komira_git import ReceivePackConfig, ReceivePackServer, SendPackClient, append_push_report

var sha1 = ObjectFormat.sha1()
var tip = ObjectId.parse_hex(sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
var server = ReceivePackServer(ReceivePackConfig("komira-git/1", sha1))
var client = SendPackClient("komira-git/1", sha1)
var refs = List[AdvertisedRef]()
refs.append(AdvertisedRef("refs/heads/a", tip))
refs.append(AdvertisedRef("refs/heads/b", tip))
var wire = List[UInt8]()
server.append_advertisement(wire, refs)
client.feed(Span(wire))
assert_true(client.read_advertisement())

var commands = List[PushCommand]()
commands.append(PushCommand(tip, ObjectId.zero(sha1), "refs/heads/a"))
commands.append(PushCommand(tip, ObjectId.zero(sha1), "refs/heads/b"))
var request = List[UInt8]()
client.append_push_request(request, commands, atomic=True)
server.feed(Span(request))
var push = server.read_request()
assert_true(push.complete and push.atomic)
assert_false(push.needs_pack())  # deletes only: no pack follows

var report = PushReport(push)
report.reject(1, "protected branch")
var response = List[UInt8]()
append_push_report(response, push, report)
client.feed(Span(response))
var status = client.read_status()
assert_equal(status.unpack_status, "ok")
assert_equal(status.reasons[0], "atomic push failure")
assert_equal(status.reasons[1], "protected branch")
```
