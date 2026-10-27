# =============================================================================
# group_assignor.mojo: the range assignor and the protocol choice.
# =============================================================================
#
# Kafka's default range assignor: per subscribed topic, the topic's P
# partitions are split into contiguous ranges across the M members that
# subscribe to it, sorted by member id. Member i (0-based) gets ceil(P/M) or
# floor(P/M) consecutive partitions: the first (P mod M) members get one extra.
# M > P gives the trailing members none. The result is deterministic.
# =============================================================================

from komira_kafka_server.wire.consumer_group import AssignedTopicPartitions


def range_assign(
    member_ids: List[String], topic: String, num_partitions: Int
) -> List[AssignedTopicPartitions]:
    """Assign `num_partitions` of `topic` across `member_ids` (which MUST be
    pre-sorted ascending) using Kafka's RangeAssignor: contiguous ranges, the
    first (P mod M) members get one extra partition, M > P => trailing members
    get none.

    Returns one AssignedTopicPartitions per member (in member_ids order),
    including empty assignments for members that got no partition (so the caller
    can build each member's assignment blob)."""
    var m = len(member_ids)
    var out = List[AssignedTopicPartitions]()
    if m == 0:
        return out^
    var base = num_partitions // m
    var extra = num_partitions % m
    var next = 0
    for i in range(m):
        var count = base + (1 if i < extra else 0)
        var parts = List[Int32]()
        for _ in range(count):
            parts.append(Int32(next))
            next += 1
        out.append(AssignedTopicPartitions(topic.copy(), parts^))
    return out^


def _sort_strings_ascending(var xs: List[String]) -> List[String]:
    """Insertion sort (member counts are tiny). Deterministic ascending order —
    the RangeAssignor + leader election both depend on it."""
    var n = len(xs)
    for i in range(1, n):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            var tmp = xs[j - 1].copy()
            xs[j - 1] = xs[j].copy()
            xs[j] = tmp^
            j -= 1
    return xs^




def pick_protocol_name(protocols_names: List[String]) -> String:
    """Pick the assignor the group will use. We prefer "range" (the Kafka
    default + what we implement); if the member did not offer "range" we take
    the first offered name (and still assign by range — every stock assignor's
    SyncGroup assignment blob is the same ConsumerProtocolAssignment wire
    shape)."""
    for i in range(len(protocols_names)):
        if protocols_names[i] == String("range"):
            return String("range")
    if len(protocols_names) > 0:
        return protocols_names[0].copy()
    return String("range")
