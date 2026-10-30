# =============================================================================
# edge_policy -- what the driver does with each edge tag and order key
# =============================================================================
#
# The edge kinds of a segment (`SegmentDescPod.edge_tags`, one per entry of
# `deps`) are a closed set. The driver reads a tag to pick a policy and refuses
# a tag it has no policy for, by name, before any segment runs.
#
#   E1_MORSEL_STREAM    wait: the consumer starts after the producer finished
#   E2_INGEST_STREAM    wait: the producer is not streamed into the consumer
#                       yet, so the consumer starts after the producer's
#                       combine and finalize, as for E3
#   E3_PUBLISH_WAIT     wait: the consumer starts after the producer's combine
#                       and finalize
#   E4_PARTITION_WISE   refused: no policy yet
#   E5_INDEPENDENT      none: the dependency is a scheduling relation only, the
#                       consumer does not wait for the producer
#
# The combine order of a segment (`order_key_kind`) is checked the same way:
# ORDER_NONE and ORDER_PARTITION_ID are served; ORDER_ROW_RANGE needs a source
# that claims grains and is refused.

from komira_physical_plan.physical_plan import (
    EDGE_E1_MORSEL_STREAM,
    EDGE_E2_INGEST_STREAM,
    EDGE_E3_PUBLISH_WAIT,
    EDGE_E4_PARTITION_WISE,
    EDGE_E5_INDEPENDENT,
    ORDER_NONE,
    ORDER_PARTITION_ID,
    ORDER_ROW_RANGE,
)

comptime POLICY_WAIT: UInt8 = 0
"""The consumer waits until the producer segment has finished."""

comptime POLICY_NONE: UInt8 = 1
"""The consumer does not wait for the producer."""


def edge_tag_name(tag: UInt8) -> String:
    """The spelling of an edge tag in messages."""
    if tag == EDGE_E1_MORSEL_STREAM:
        return String("E1_MORSEL_STREAM")
    if tag == EDGE_E2_INGEST_STREAM:
        return String("E2_INGEST_STREAM")
    if tag == EDGE_E3_PUBLISH_WAIT:
        return String("E3_PUBLISH_WAIT")
    if tag == EDGE_E4_PARTITION_WISE:
        return String("E4_PARTITION_WISE")
    if tag == EDGE_E5_INDEPENDENT:
        return String("E5_INDEPENDENT")
    return String("edge tag ") + String(Int(tag))


def edge_policy(tag: UInt8) raises -> UInt8:
    """The policy for `tag`: `POLICY_WAIT` or `POLICY_NONE`.

    Raises, naming the tag, for E4 and for a value that is no edge tag.
    """
    if (
        tag == EDGE_E1_MORSEL_STREAM
        or tag == EDGE_E2_INGEST_STREAM
        or tag == EDGE_E3_PUBLISH_WAIT
    ):
        return POLICY_WAIT
    if tag == EDGE_E5_INDEPENDENT:
        return POLICY_NONE
    raise Error(
        "komira_pipeline_exec: the driver has no policy for "
        + edge_tag_name(tag)
    )


def order_key_name(kind: UInt8) -> String:
    """The spelling of an order key kind in messages."""
    if kind == ORDER_NONE:
        return String("ORDER_NONE")
    if kind == ORDER_PARTITION_ID:
        return String("ORDER_PARTITION_ID")
    if kind == ORDER_ROW_RANGE:
        return String("ORDER_ROW_RANGE")
    return String("order key kind ") + String(Int(kind))


def check_order_key(kind: UInt8) raises:
    """Raise, naming the kind, unless the driver serves `kind`."""
    if kind == ORDER_NONE or kind == ORDER_PARTITION_ID:
        return
    raise Error(
        "komira_pipeline_exec: the driver cannot serve "
        + order_key_name(kind)
        + ": no source claims grains yet"
    )
