# =============================================================================
# iceberg_writer_state.mojo — ids and the prior table state a commit builds on.
# =============================================================================
#
# Two helpers of `iceberg_writer`:
#
#   * unique ids: the table uuid and the snapshot ids come from a UUIDv7 (a
#     48-bit millisecond timestamp and CSPRNG bytes from komira_uuid), so two
#     writers on different hosts never mint the same id.
#
#   * the prior state: the snapshot history, the running totals, the schemas an
#     earlier snapshot was written with and the partition spec of the current
#     metadata.json, recovered by a targeted scan of the file this package
#     wrote (never a general JSON parse).
#
# Encapsulation: ZERO UnsafePointer in any signature; ZERO wildcard origins.
# =============================================================================

from komira_uuid.uuid import generate_uuidv7

from .iceberg_json_scan import (
    bare_int64_field,
    json_str_field,
    object_array_items,
    snapshot_objects,
)
from .iceberg_metadata_json import SnapshotInfo, SummaryKV
from .iceberg_summary import parse_summary_object


# =============================================================================
# Unique ids.
# =============================================================================


def gen_table_uuid() raises -> String:
    """A fresh UUIDv7 in 8-4-4-4-12 text, for a table uuid or a metadata file
    name. Raises when the system entropy source fails."""
    return generate_uuidv7().to_hyphenated()


def gen_snapshot_id() raises -> Int64:
    """A positive, unique snapshot id: 63 bits of a fresh UUIDv7 (the low eight
    bytes, which hold the random part), never 0. Iceberg snapshot ids are signed
    longs, conventionally positive."""
    var bytes = generate_uuidv7().as_bytes()
    var v = UInt64(0)
    for i in range(8, 16):
        v = (v << UInt64(8)) | UInt64(bytes[i])
    v = v & UInt64(0x7FFFFFFFFFFFFFFF)
    if v == UInt64(0):
        v = UInt64(1)
    return Int64(v)


# =============================================================================
# The prior state.
# =============================================================================


struct PriorState(Copyable, Movable, Deinitable):
    """What the latest metadata.json holds that the next one carries on.

    Fields:
      var snapshots: List[SnapshotInfo] — the snapshot history, oldest first.
      var total_files: Int              — cumulative data files (last snapshot).
      var total_records: Int64          — cumulative records (last snapshot).
      var schemas: List[String]         — the raw JSON of each schema object.
    """

    var snapshots: List[SnapshotInfo]
    var total_files: Int
    var total_records: Int64
    var schemas: List[String]

    def __init__(out self):
        self.snapshots = List[SnapshotInfo]()
        self.total_files = 0
        self.total_records = Int64(0)
        self.schemas = List[String]()

    def copy(self) -> Self:
        var s = Self()
        for i in range(len(self.snapshots)):
            s.snapshots.append(self.snapshots[i].copy())
        s.total_files = self.total_files
        s.total_records = self.total_records
        for i in range(len(self.schemas)):
            s.schemas.append(String(self.schemas[i]))
        return s^


def _is_standard_summary_key(key: String) -> Bool:
    """The summary keys `snapshot_json` itself writes from a SnapshotInfo's
    fields; every other key of a recovered summary is an extra to carry."""
    return (
        key == String("operation")
        or key == String("added-data-files")
        or key == String("added-records")
        or key == String("total-data-files")
        or key == String("total-records")
    )


def parse_prior_state(json: String) raises -> PriorState:
    """Recover the snapshot history, the totals and the schemas from the
    metadata.json this package wrote.

    Each snapshot object is rebuilt from the fields `snapshot_json` writes, its
    `operation` and every summary key beyond the standard counts included, so a
    snapshot rewritten into the next metadata.json keeps its whole summary.
    The totals come from the LAST snapshot's summary."""
    var st = PriorState()
    var objs = snapshot_objects(json)
    for i in range(len(objs)):
        st.snapshots.append(_parse_one_snapshot(objs[i]))
    if len(st.snapshots) > 0:
        ref last = st.snapshots[len(st.snapshots) - 1]
        st.total_files = last.total_files
        st.total_records = last.total_records
    var sch = object_array_items(json, "schemas")
    for i in range(len(sch)):
        st.schemas.append(sch[i].copy())
    return st^


def _parse_one_snapshot(obj: String) raises -> SnapshotInfo:
    """Parse one snapshot object (the exact shape `snapshot_json` writes)."""
    var sid = bare_int64_field(obj, "snapshot-id")
    var seq = bare_int64_field(obj, "sequence-number")
    var ts = bare_int64_field(obj, "timestamp-ms")
    var mlist = json_str_field(obj, "manifest-list")
    var schema_id = Int(bare_int64_field(obj, "schema-id"))
    var parent = Int64(-1)
    if obj.find('"parent-snapshot-id"') >= 0:
        parent = bare_int64_field(obj, "parent-snapshot-id")
    var summary = parse_summary_object(obj)
    var operation = String("append")
    var total_files = 0
    var total_records = Int64(0)
    var added_files = 0
    var added_records = Int64(0)
    var extras = List[SummaryKV]()
    for i in range(len(summary)):
        ref kv = summary[i]
        if kv.key == String("operation"):
            operation = String(kv.value)
        elif kv.key == String("total-data-files"):
            total_files = Int(_parse_int64(kv.value))
        elif kv.key == String("total-records"):
            total_records = _parse_int64(kv.value)
        elif kv.key == String("added-data-files"):
            added_files = Int(_parse_int64(kv.value))
        elif kv.key == String("added-records"):
            added_records = _parse_int64(kv.value)
        if not _is_standard_summary_key(kv.key):
            extras.append(kv.copy())
    return SnapshotInfo(
        sid,
        seq,
        ts,
        mlist^,
        added_files,
        added_records,
        total_files,
        total_records,
        schema_id,
        parent,
        extras^,
        operation^,
    )


def _parse_int64(s: String) raises -> Int64:
    """A (possibly negative) base-10 integer; raises when it has no digits."""
    var bs = s.as_bytes()
    var v = Int64(0)
    var neg = False
    var i = 0
    if len(bs) > 0 and bs[0] == UInt8(ord("-")):
        neg = True
        i = 1
    var any = False
    while i < len(bs):
        var d = Int(bs[i])
        if d < ord("0") or d > ord("9"):
            break
        v = v * Int64(10) + Int64(d - ord("0"))
        any = True
        i += 1
    if not any:
        raise Error("iceberg metadata: not a number: '" + s + "'")
    return -v if neg else v
