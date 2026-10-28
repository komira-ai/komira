# =============================================================================
# sink_capability -- the sink triples a host serves, and admission
# =============================================================================
#
# The table is data: it names no sink type and no operator. A segment's sink
# is the triple `(sink_kind, sink_key_dtype, sink_orientation)` of its
# descriptor; `admit_segment` raises `LOWERING_SINK_UNSERVED` for a triple with
# no row, so a plan whose sink nothing can run is refused at lowering and is
# never turned into some other sink.
#
# `spillable` is False for every row: no row has a spill path yet.
# =============================================================================

from komira_physical_plan.physical_plan import (
    SegmentDescPod,
    SINK_AGG,
    SINK_SORT,
    SINK_TOPN,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_PARTITION_BY,
    SINK_PARTITION_TOPN,
    SINK_SMJ_BUILD,
    SINK_ASOF_JOIN,
    SINK_JOIN_PROBE,
    SINK_ORIENT_COLUMNAR,
    SINK_ORIENT_DICT_ENCODED,
    KEY_DTYPE_NONE,
    KEY_DTYPE_I64,
    KEY_DTYPE_I32,
    KEY_DTYPE_F64,
    KEY_DTYPE_F32,
    KEY_DTYPE_STRING,
)
from komira_lowering.lowered_plan import LOWERING_SINK_UNSERVED


@fieldwise_init
struct SinkRow(Copyable, Movable):
    """One served triple."""

    var sink_kind: UInt8
    var key_dtype: UInt8
    var orientation: UInt8
    var spillable: Bool


def _row(kind: UInt8, key: UInt8, orientation: UInt8) -> SinkRow:
    return SinkRow(kind, key, orientation, False)


def sink_capability() -> List[SinkRow]:
    """The rows a host serves, in table order."""
    var rows = List[SinkRow]()
    rows.append(_row(SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_AGG, KEY_DTYPE_I64, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_AGG, KEY_DTYPE_I32, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_AGG, KEY_DTYPE_F64, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_AGG, KEY_DTYPE_F32, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_AGG, KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED))
    rows.append(_row(SINK_AGG, KEY_DTYPE_STRING, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    rows.append(_row(SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    return rows^


def is_sink_served(sink_kind: UInt8, key_dtype: UInt8, orientation: UInt8) -> Bool:
    """True when the table has a row for the triple."""
    var rows = sink_capability()
    for i in range(len(rows)):
        if (
            rows[i].sink_kind == sink_kind
            and rows[i].key_dtype == key_dtype
            and rows[i].orientation == orientation
        ):
            return True
    return False


def sink_kind_name(sink_kind: UInt8) -> String:
    if sink_kind == SINK_AGG:
        return "SINK_AGG"
    if sink_kind == SINK_SORT:
        return "SINK_SORT"
    if sink_kind == SINK_TOPN:
        return "SINK_TOPN"
    if sink_kind == SINK_COLLECT:
        return "SINK_COLLECT"
    if sink_kind == SINK_HASH_BUILD:
        return "SINK_HASH_BUILD"
    if sink_kind == SINK_PARTITION_BY:
        return "SINK_PARTITION_BY"
    if sink_kind == SINK_PARTITION_TOPN:
        return "SINK_PARTITION_TOPN"
    if sink_kind == SINK_SMJ_BUILD:
        return "SINK_SMJ_BUILD"
    if sink_kind == SINK_ASOF_JOIN:
        return "SINK_ASOF_JOIN"
    if sink_kind == SINK_JOIN_PROBE:
        return "SINK_JOIN_PROBE"
    return "SINK_" + String(Int(sink_kind))


def key_dtype_name(key_dtype: UInt8) -> String:
    if key_dtype == KEY_DTYPE_NONE:
        return "NONE"
    if key_dtype == KEY_DTYPE_I64:
        return "I64"
    if key_dtype == KEY_DTYPE_I32:
        return "I32"
    if key_dtype == KEY_DTYPE_F64:
        return "F64"
    if key_dtype == KEY_DTYPE_F32:
        return "F32"
    if key_dtype == KEY_DTYPE_STRING:
        return "STRING"
    return "KEY_" + String(Int(key_dtype))


def orientation_name(orientation: UInt8) -> String:
    if orientation == SINK_ORIENT_COLUMNAR:
        return "COLUMNAR"
    if orientation == SINK_ORIENT_DICT_ENCODED:
        return "DICT_ENCODED"
    return "ORIENT_" + String(Int(orientation))


def triple_name(sink_kind: UInt8, key_dtype: UInt8, orientation: UInt8) -> String:
    """`(SINK_AGG, I64, COLUMNAR)`: the text a refusal and a render use."""
    return (
        "("
        + sink_kind_name(sink_kind)
        + ", "
        + key_dtype_name(key_dtype)
        + ", "
        + orientation_name(orientation)
        + ")"
    )


def admit_segment(segment: SegmentDescPod) raises:
    """Raise `LOWERING_SINK_UNSERVED`, naming the triple and the segment, when
    the segment's sink has no row in the table."""
    if not is_sink_served(
        segment.sink_kind, segment.sink_key_dtype, segment.sink_orientation
    ):
        raise Error(
            String(LOWERING_SINK_UNSERVED)
            + ": segment "
            + String(segment.seg_id)
            + " ends in "
            + triple_name(
                segment.sink_kind, segment.sink_key_dtype, segment.sink_orientation
            )
            + ", which no row of the sink capability table serves"
        )


def admit_plan(segments: List[SegmentDescPod]) raises:
    """Admit every segment, in order; the first unserved triple raises."""
    for i in range(len(segments)):
        admit_segment(segments[i])
