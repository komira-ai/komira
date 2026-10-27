# =============================================================================
# group_offsets.mojo: committed offsets of Kafka consumer groups, stored as
# objects in the broker's object store.
# =============================================================================
#
# A consumer with a `group.id` commits "the next offset to read" per (group,
# topic, partition) and fetches it on restart. The offsets live in the same
# conditional-write store type the data plane uses, so the group tree sits
# beside the segment and manifest tree in one object store. The wire codecs for
# the group APIs are in komira_kafka_server.wire.consumer_group; this module is
# the store side only.
#
# Key layout, one object per partition:
#   <cluster>/_meta/groups/<group_id>/offsets/<topic>/<partition>.json
# whose body is {"offset": <int64>, "metadata": "<str>",
# "commit_timestamp": <int64>}. A commit is an unconditional `put`: the last
# write per partition wins, and the store does not order commits: the caller
# must check the member generation before it commits. In the key, `%` and `/`
# of a group id are percent-encoded. The JSON is written and read by hand
# (three scalar fields), so the module has no JSON dependency.
#
# No pointer type appears in any signature: the store is owned by value and
# offsets flow as scalars and owned Strings.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


# =============================================================================
# §1 — The committed-offset record (typed view of the JSON body).
# =============================================================================


struct CommittedOffset(Copyable, Movable, Deinitable):
    """A committed offset for one (group, topic, partition): the next offset the
    consumer should read, plus optional metadata + the commit wall-clock."""

    var offset: Int64
    var metadata: String
    var commit_timestamp: Int64

    def __init__(
        out self,
        offset: Int64,
        var metadata: String,
        commit_timestamp: Int64,
    ):
        self.offset = offset
        self.metadata = metadata^
        self.commit_timestamp = commit_timestamp

    def copy(self) -> Self:
        return Self(self.offset, self.metadata.copy(), self.commit_timestamp)


# =============================================================================
# §2 — A fetched (topic, partition, committed-offset) triple — used by the
#      "all topics for this group" LIST path to carry back the parsed key.
# =============================================================================


struct FetchedOffset(Copyable, Movable, Deinitable):
    var topic: String
    var partition: Int32
    var record: CommittedOffset

    def __init__(
        out self, var topic: String, partition: Int32, var record: CommittedOffset
    ):
        self.topic = topic^
        self.partition = partition
        self.record = record^

    def copy(self) -> Self:
        return Self(self.topic.copy(), self.partition, self.record.copy())


# =============================================================================
# §3 — JSON body encode / parse (hand-rolled; 3 scalar fields, no lib).
# =============================================================================


def _json_escape(s: String) -> String:
    """Escape `"` and `\\` for embedding in the metadata JSON string value.
    Metadata is small + caller-controlled; this covers the two JSON-significant
    chars."""
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("\\")):
            out.append(UInt8(ord("\\")))
        # The raw byte, not `chr(c)`: a byte of a multibyte UTF-8 sequence is
        # not a codepoint.
        out.append(c)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def encode_offset_json(rec: CommittedOffset) -> List[UInt8]:
    """Serialize a CommittedOffset to the JSON body bytes."""
    var s = String('{"offset":')
    s += String(rec.offset)
    s += String(',"metadata":"')
    s += _json_escape(rec.metadata)
    s += String('","commit_timestamp":')
    s += String(rec.commit_timestamp)
    s += String("}")
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _find_key(s: String, key: String, start: Int) -> Int:
    """Return the byte index just past `"<key>":` in `s` at/after `start`, or
    -1 if not found."""
    var needle = String('"') + key + String('":')
    var idx = s.find(needle, start)
    if idx < 0:
        return -1
    return idx + len(needle.as_bytes())


def _parse_int64_at(s: String, pos: Int) -> Int64:
    """Parse a (possibly negative) base-10 Int64 beginning at byte `pos`,
    skipping leading whitespace. Stops at the first non-digit."""
    var bs = s.as_bytes()
    var i = pos
    var n = len(bs)
    while i < n and (bs[i] == UInt8(ord(" ")) or bs[i] == UInt8(ord("\t"))):
        i += 1
    var neg = False
    if i < n and bs[i] == UInt8(ord("-")):
        neg = True
        i += 1
    var v = Int64(0)
    while i < n:
        var c = bs[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            break
        v = v * Int64(10) + Int64(Int(c) - ord("0"))
        i += 1
    return -v if neg else v


def _parse_string_at(s: String, pos: Int) -> String:
    """Parse a JSON string value beginning at byte `pos` (which must point at
    the opening `"`), handling `\\"` and `\\\\` escapes. Returns the unescaped
    contents."""
    var bs = s.as_bytes()
    var i = pos
    var n = len(bs)
    while i < n and (bs[i] == UInt8(ord(" ")) or bs[i] == UInt8(ord("\t"))):
        i += 1
    if i >= n or bs[i] != UInt8(ord('"')):
        return String("")
    i += 1  # skip opening quote
    var out = List[UInt8]()
    while i < n:
        var c = bs[i]
        if c == UInt8(ord("\\")) and i + 1 < n:
            out.append(bs[i + 1])
            i += 2
            continue
        if c == UInt8(ord('"')):
            break
        out.append(c)
        i += 1
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def decode_offset_json(body: List[UInt8]) raises -> CommittedOffset:
    """Parse the JSON body bytes back to a CommittedOffset. Tolerant of field
    order; uses keyed lookups rather than positional parsing."""
    var s = String(StringSlice(unsafe_from_utf8=Span(body)))
    var off_pos = _find_key(s, String("offset"), 0)
    if off_pos < 0:
        raise Error("group_offsets: malformed offset JSON (no 'offset')")
    var offset = _parse_int64_at(s, off_pos)
    var meta = String("")
    var meta_pos = _find_key(s, String("metadata"), 0)
    if meta_pos >= 0:
        meta = _parse_string_at(s, meta_pos)
    var ts = Int64(0)
    var ts_pos = _find_key(s, String("commit_timestamp"), 0)
    if ts_pos >= 0:
        ts = _parse_int64_at(s, ts_pos)
    return CommittedOffset(offset, meta^, ts)


# =============================================================================
# §4 — Key layout helpers.
# =============================================================================


def _group_path_segment(group_id: String) -> String:
    """The group id as one path segment: `%` and `/` are percent-encoded, so a
    group id holding `/` cannot name another group's subtree."""
    var out = List[UInt8]()
    var bs = group_id.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        if c == UInt8(ord("%")):
            out.extend(String("%25").as_bytes())
        elif c == UInt8(ord("/")):
            out.extend(String("%2F").as_bytes())
        else:
            out.append(c)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _group_offsets_prefix(cluster: String, group_id: String) -> String:
    """`<cluster>/_meta/groups/<group_id>/offsets/` — the directory prefix for
    a group's committed offsets (used by the LIST-all-topics path)."""
    return (
        cluster
        + String("/_meta/groups/")
        + _group_path_segment(group_id)
        + String("/offsets/")
    )


def _offset_key(
    cluster: String, group_id: String, topic: String, partition: Int32
) -> String:
    """`<cluster>/_meta/groups/<group_id>/offsets/<topic>/<partition>.json` —
    the per-partition committed-offset object key."""
    return (
        _group_offsets_prefix(cluster, group_id)
        + topic
        + String("/")
        + String(Int(partition))
        + String(".json")
    )


def _parse_topic_partition_from_key(
    key: String, prefix: String
) -> Tuple[String, Int32, Bool]:
    """Recover `(topic, partition, ok)` from a full offset key given the group
    prefix. The tail after `prefix` is `<topic>/<partition>.json`; topic names
    may themselves contain `/`, so split on the LAST `/` and strip `.json`.

    Returns ok=False if the key does not match the expected shape."""
    var kb = key.as_bytes()
    var pb = prefix.as_bytes()
    if len(kb) <= len(pb):
        return (String(""), Int32(0), False)
    # Confirm the key starts with the prefix.
    for i in range(len(pb)):
        if kb[i] != pb[i]:
            return (String(""), Int32(0), False)
    # tail = key[len(prefix):]
    var tail_start = len(pb)
    var n = len(kb)
    # Must end with ".json".
    var suffix = String(".json").as_bytes()
    if n - tail_start < len(suffix):
        return (String(""), Int32(0), False)
    for j in range(len(suffix)):
        if kb[n - len(suffix) + j] != suffix[j]:
            return (String(""), Int32(0), False)
    var content_end = n - len(suffix)  # exclusive end of "<topic>/<partition>"
    # Find the LAST '/' within [tail_start, content_end).
    var slash = UInt8(ord("/"))
    var last_slash = -1
    var i = tail_start
    while i < content_end:
        if kb[i] == slash:
            last_slash = i
        i += 1
    if last_slash < 0 or last_slash <= tail_start:
        return (String(""), Int32(0), False)
    # topic = key[tail_start:last_slash]; partition = key[last_slash+1:content_end]
    var topic = String(StringSlice(unsafe_from_utf8=kb[tail_start:last_slash]))
    var part_str = String(
        StringSlice(unsafe_from_utf8=kb[last_slash + 1 : content_end])
    )
    var part = Int32(0)
    var pn = part_str.as_bytes()
    if len(pn) == 0:
        return (String(""), Int32(0), False)
    for k in range(len(pn)):
        var c = pn[k]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return (String(""), Int32(0), False)
        part = part * Int32(10) + Int32(Int(c) - ord("0"))
    return (topic^, part, True)


def _is_method_prefix_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("."))
    )


def _is_not_found(msg: String) -> Bool:
    """True iff a store error says the object is absent, decided by where the
    marker sits and never by whether the text holds it. Store errors name the
    object key, and the key holds a group id and a topic, which are free text
    (only `/` and `%` are encoded), so any marker may appear inside the key of
    an unrelated 403 or 5xx and turn it into "never committed". Two forms are
    accepted:
      * the message starts with `StoreError[NOT_FOUND]`, the cloud stores'
        canonical kind token (the key comes after it);
      * the message starts with the in-tree stores' own method prefix (letters,
        digits, `_` and `.` only, for example `InMemoryConditionalStore.get`)
        followed by `: not_found (404)`. The prefix cannot hold a space or a
        bracket, so key text cannot stand in for it."""
    if msg.startswith("StoreError[NOT_FOUND]"):
        return True
    var bs = msg.as_bytes()
    var i = 0
    while i < len(bs) and _is_method_prefix_byte(bs[i]):
        i += 1
    if i == 0:
        return False
    var marker = String(": not_found (404)").as_bytes()
    if len(bs) - i < len(marker):
        return False
    for k in range(len(marker)):
        if bs[i + k] != marker[k]:
            return False
    return True


# =============================================================================
# §5 — GroupOffsetStore — the typed API over the ConditionalWriteStore.
# =============================================================================


struct GroupOffsetStore[
    Storage: CloneableConditionalWriteStore = SharedInMemoryConditionalStore
](Movable, Deinitable):
    """Committed-offset persistence for Kafka consumer groups over the shared
    `ConditionalWriteStore`.

    Owns a handle to the SAME store TYPE the data plane uses (a
    `CloneableConditionalWriteStore` — in-memory twin by default, OR
    `S3ConditionalStore[C]` for durability), so the group tree lives alongside
    the segment/manifest tree in one object store. last-write-wins per
    partition (a `put`, not a conditional write): the store does not order
    commits, so a stale committer (a member that lost its partition in a
    rebalance) overwrites a newer offset unless the caller checks the member
    generation before calling `commit`.

    `commit` / `fetch` are the OffsetCommit / OffsetFetch primitives;
    `fetch_all_for_group` LISTs the group prefix for the "null topics ==
    all topics" OffsetFetch path.
    """

    var _store: Self.Storage
    var _cluster: String

    def __init__(out self, var store: Self.Storage, var cluster: String):
        self._store = store^
        self._cluster = cluster

    # -- commit (OffsetCommit) ------------------------------------------------

    def commit(
        mut self,
        group_id: String,
        topic: String,
        partition: Int32,
        rec: CommittedOffset,
    ) raises:
        """Persist `rec` as the committed offset for (group, topic, partition).
        last-write-wins (`put`). An empty topic or a negative partition is
        refused: it could be written but never listed."""
        if len(topic.as_bytes()) == 0 or partition < Int32(0):
            raise Error(
                "group_offsets: cannot commit an empty topic or a negative"
                " partition"
            )
        var key = _offset_key(self._cluster, group_id, topic, partition)
        var path = Path.parse(key)
        var body = encode_offset_json(rec)
        _ = self._store.put(path, body^)

    # -- fetch one (OffsetFetch, explicit partition) --------------------------

    def fetch(
        mut self,
        group_id: String,
        topic: String,
        partition: Int32,
    ) raises -> Optional[CommittedOffset]:
        """Read the committed offset for (group, topic, partition). Returns None
        if no offset has been committed (the caller maps None to the -1
        sentinel)."""
        var key = _offset_key(self._cluster, group_id, topic, partition)
        var path = Path.parse(key)
        # `get` raises a not_found (404) Error when the object is absent; treat
        # that as "no committed offset" rather than propagating.
        try:
            var body = self._store.get(path)
            return Optional(decode_offset_json(body^))
        except e:
            var msg = String(e)
            if _is_not_found(msg):
                return Optional[CommittedOffset]()
            raise Error(msg)

    # -- fetch all (OffsetFetch with null topics == all topics) ---------------

    def fetch_all_for_group(
        mut self, group_id: String
    ) raises -> List[FetchedOffset]:
        """List the group's offset prefix and return every committed
        (topic, partition, offset). Used by the OffsetFetch "all topics" path.

        An object store lists one level at a time: a key below the prefix
        (`<topic>/<partition>.json`) is not among the listing's `objects`, only
        its `<topic>/` prefix is among the `common_prefixes`. So the listing
        walks the prefixes it is given, to any depth (a topic name may contain
        `/`), and keeps the objects whose key has the offset shape."""
        var prefix_str = _group_offsets_prefix(self._cluster, group_id)
        var out = List[FetchedOffset]()
        var pending = List[String]()
        pending.append(prefix_str)
        while len(pending) > 0:
            var current = pending.pop()
            var listing = self._store.list_with_delimiter(Path.parse(current))
            for i in range(len(listing.objects)):
                ref obj = listing.objects[i]
                var tp = _parse_topic_partition_from_key(
                    obj.location, prefix_str
                )
                if not tp[2]:
                    continue
                var body = self._store.get(Path.parse(obj.location))
                var rec = decode_offset_json(body^)
                out.append(FetchedOffset(tp[0], tp[1], rec^))
            for i in range(len(listing.common_prefixes)):
                ref sub = listing.common_prefixes[i]
                # Only a prefix strictly below the one just listed is walked,
                # so a store that repeats a prefix cannot loop.
                if len(sub.as_bytes()) > len(
                    current.as_bytes()
                ) and sub.startswith(current):
                    pending.append(sub)
        return out^
