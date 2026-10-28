# =============================================================================
# flight_ticket.mojo: the broker ticket codec {topic, offset, partition}.
# =============================================================================
#
# A Flight `Ticket` carries opaque bytes. The broker encodes {topic,
# start_offset, partition} into them so DoGet can resume from where
# GetFlightInfo pointed and target the right partition. The encoding is a tiny
# protobuf message (field 1 = topic string, field 2 = start_offset int64,
# field 3 = partition int64), so it stays self-describing and
# forward-compatible. It is private to the broker: a client never inspects it
# and round-trips the opaque bytes.
#
# Field 3 (partition) is backward-compatible: a ticket without it has no field
# 3 (proto3 omits a zero varint) and decodes to partition 0, the
# single-partition default. A partition of 0 is likewise omitted on encode, so
# a ticket for partition 0 is byte-identical to a ticket that predates the
# field.
#
# Typed values only; encode appends to an owned List[UInt8]; decode walks a
# Span through PbFieldCursor.
# =============================================================================

from komira_protobuf import (
    PbFieldCursor,
    pb_write_varint_field,
    pb_write_string_field,
)


struct BrokerTicket(Copyable, Movable, Deinitable):
    """The broker's internal Ticket payload: {topic, start_offset, partition}.

    `partition` selects the topic partition for DoGet. Defaults to
    0 (the single-partition shape); an absent field-3 ticket decodes to 0, so
    the pre-multi-partition wire is unchanged."""

    var topic: String
    var start_offset: Int64
    var partition: Int64

    def __init__(
        out self, var topic: String, start_offset: Int64, partition: Int64 = Int64(0)
    ):
        self.topic = topic^
        self.start_offset = start_offset
        self.partition = partition

    def encode(self) -> List[UInt8]:
        """Encode to the opaque ticket bytes (field 1 = topic, 2 = offset,
        3 = partition). proto3 omits zero-valued offset + partition, so a
        partition-0 ticket is byte-identical to a ticket without the field."""
        var out = List[UInt8]()
        pb_write_string_field(out, 1, self.topic)
        if self.start_offset != 0:
            pb_write_varint_field(out, 2, UInt64(self.start_offset))
        if self.partition != 0:
            pb_write_varint_field(out, 3, UInt64(self.partition))
        return out^

    @staticmethod
    def decode(bytes: Span[UInt8, _]) raises -> BrokerTicket:
        var topic = String("")
        var offset = Int64(0)
        var partition = Int64(0)  # absent field 3 -> partition 0 (back-compat).
        var cur = PbFieldCursor.over(bytes)
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                topic = cur.read_string()
            elif tag.field_number == 2:
                offset = Int64(cur.read_varint())
            elif tag.field_number == 3:
                partition = Int64(cur.read_varint())
            else:
                cur.skip()
        return BrokerTicket(topic^, offset, partition)
