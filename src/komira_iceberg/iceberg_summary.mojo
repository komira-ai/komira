# =============================================================================
# iceberg_summary.mojo — read the CURRENT snapshot's `summary` map back.
# =============================================================================
#
# An ingest process can stamp the last-applied per-shard stream position INTO
# the Iceberg snapshot `summary` map on each commit (via `commit_with_summary`),
# so the resume point rides the SAME atomic commit as the data: there is NO
# separate checkpoint store. On startup it DERIVES the resume point by reading
# the LATEST committed snapshot's summary. This module is that read:
#
#   current version -> v<N>.metadata.json -> current snapshot -> summary map
#
# It returns the summary as a `List[SummaryKV]` (every key/value pair, incl. the
# count fields AND any stamped position KVs), and `summary_value_for` looks up
# one key (returning "" when absent: the cold-start signal for a shard). If the
# table has NEVER been committed, it returns an empty summary.
#
# Encapsulation: the store is taken by `ref`; every buffer is an owned
# List[UInt8]; the return is an owned List[SummaryKV]. ZERO UnsafePointer in any
# signature; ZERO wildcard origins.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .iceberg_metadata_json import SummaryKV
from .iceberg_version import current_version, metadata_json_key
from .iceberg_json_scan import (
    read_json_string_at,
    bare_int64_field,
    bytes_to_str,
    snapshot_objects,
)


# =============================================================================
# Public API.
# =============================================================================


def read_current_snapshot_summary[
    Store: ConditionalWriteStore, o: Origin[mut=True]
](ref [o] store: Store, location: String) raises -> List[SummaryKV]:
    """Read the `summary` map of the table's CURRENT snapshot through `store`.

    Walks the current metadata version (`current_version`) -> its
    v<N>.metadata.json -> the current snapshot object -> its `summary` object,
    and returns EVERY key/value pair (the count metrics AND any stamped position
    KVs). Returns an EMPTY list if the table has never been committed (no
    metadata version) — the cold-start case, where the ingest resumes every
    shard from the stream's oldest record. A failure to read is never the
    cold-start case: only a proven absence is."""
    var version = current_version(store, location)
    if version == 0:
        return List[SummaryKV]()
    var meta = bytes_to_str(
        store.get(Path.parse(metadata_json_key(location, version)))
    )
    return _current_snapshot_summary(meta)


@always_inline
def summary_value_for(summary: List[SummaryKV], key: String) -> String:
    """Return the value for `key` in `summary`, or "" if absent. An ingest
    process uses "" as the cold-start signal for a shard whose position has never
    been committed."""
    for i in range(len(summary)):
        if _str_eq(summary[i].key, key):
            return String(summary[i].value)
    return String("")


# =============================================================================
# Internal: locate + parse the current snapshot's summary object.
# =============================================================================


def _current_snapshot_summary(json: String) raises -> List[SummaryKV]:
    """Find the current snapshot's `summary` object in metadata.json and parse
    its key/value pairs.

    Reads `current-snapshot-id`, scans the `snapshots` array for the snapshot
    object whose `snapshot-id` matches, and parses that object's `summary` map.
    Matches by id (not position) to be robust."""
    var cur_id = bare_int64_field(json, "current-snapshot-id")
    var snaps = snapshot_objects(json)
    for i in range(len(snaps)):
        if bare_int64_field(snaps[i], "snapshot-id") == cur_id:
            return parse_summary_object(snaps[i])
    return List[SummaryKV]()


def parse_summary_object(snap_obj: String) raises -> List[SummaryKV]:
    """Parse the `"summary":{...}` object of a snapshot object into KV pairs.

    OUR own metadata: the summary is a flat object of `"k":"v"` string entries
    (all values are JSON strings — the shipped count fields are stored as
    strings, and stamped position KVs are strings). A targeted scanner reads the
    key + string value pairs at depth 1."""
    var out = List[SummaryKV]()
    var at = snap_obj.find('"summary":{')
    if at < 0:
        return out^
    var bs = snap_obj.as_bytes()
    var n = len(bs)
    var i = at + String('"summary":{').byte_length()
    while i < n:
        # skip whitespace / commas.
        while i < n and (
            bs[i] == UInt8(ord(" "))
            or bs[i] == UInt8(ord(","))
            or bs[i] == UInt8(ord("\t"))
            or bs[i] == UInt8(ord("\n"))
            or bs[i] == UInt8(ord("\r"))
        ):
            i += 1
        if i >= n:
            break
        if bs[i] == UInt8(ord("}")):
            break  # end of the summary object
        if bs[i] != UInt8(ord('"')):
            # not a key start — bail defensively (should not happen in OUR json).
            break
        var key = read_json_string_at(snap_obj, i)
        i = key.end
        # skip whitespace to the ':'.
        while i < n and bs[i] != UInt8(ord(":")):
            i += 1
        i += 1  # past ':'
        while i < n and (
            bs[i] == UInt8(ord(" "))
            or bs[i] == UInt8(ord("\t"))
            or bs[i] == UInt8(ord("\n"))
            or bs[i] == UInt8(ord("\r"))
        ):
            i += 1
        if i >= n or bs[i] != UInt8(ord('"')):
            # a non-string value — OUR summary only emits strings, so bail.
            break
        var value = read_json_string_at(snap_obj, i)
        i = value.end
        out.append(SummaryKV(String(key.text), String(value.text)))
    return out^


@always_inline
def _str_eq(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return False
    return True
