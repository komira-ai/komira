# =============================================================================
# test_resource_held_numbers.mojo
# =============================================================================
#
# EVERY HELD NUMBER OF `kci.resource.v1`, ONE TABLE, EVERY NUMBER IN EVERY
# RANGE.
#
# A held number is promised to a later field (a primitive, an extension, a
# shape that lands as an addition). Taking it for anything else is legal to
# protoc and silent on the wire, so a test must say "nothing has taken it",
# number by number. `_HELD` below is the whole list, as data: per message,
# each held range (inclusive) and what it is held for. Every number of every
# range is probed, so taking body field 101 (or 642, or 899) fails here.
#
# THE PROBE. One record at the number, length-delimited, with the NON-EMPTY
# payload "x", after the message's own fields:
#   * undeclared: the record is skipped as unknown, and the message encodes
#     exactly as it did without it;
#   * declared as a string or bytes (repeated or not): it decodes as "x" and
#     re-encodes, so the bytes differ;
#   * declared as a message, a map, a oneof arm: "x" is a truncated record,
#     so decoding raises;
#   * declared as a number, a bool or an enum: the wire type is wrong, so
#     decoding raises (a repeated number reads "x" as one packed element and
#     re-encodes it, so the bytes differ).
# An EMPTY payload would be blind to the scalar case (a declared string reads
# "" and writes nothing), which is why the payload is "x". Both sides of the
# comparison are this codec's own encoding, so its habit of writing zero
# values cannot make them differ.
#
# THE CONTROLS. `test_the_probe_sees_a_declared_number` runs the same probe
# on one DECLARED number of each probed message and requires it to report
# "declared": a probe that could not see a declaration would pass the census
# vacuously.
#
# Held ENUM values (`Output` 5, `Access` 7 and 9, `CellResource` 4,
# `SourceEvent` 3, `InputType` 4, 7 and 8) render
# as bare numbers: no name has taken them. `Access` 5 and 6 are SEND and
# RECEIVE (messaging), declared, and pinned in test_resource_field_numbers.
#
# When a held number is declared, its row here changes in the same pull
# request as the schema. Nothing else may change a row.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import Serializable, decode_proto, encode_proto
from kci_resource_proto.composite import CompositeDefinition, InputType
from kci_resource_proto.artifacts import Registry
from kci_resource_proto.compute import ContainerJob, Service, Worker
from kci_resource_proto.data import Bucket, Table
from kci_resource_proto.identity import Grant, ServiceAccount
from kci_resource_proto.messaging import Queue, Subscription, Topic
from kci_resource_proto.names import Certificate, DnsRecord, DnsZone
from kci_resource_proto.networks import IpAddress, Network, Subnet
from kci_resource_proto.refs import Access, CellResource, Image, Output, Uses, Value
from kci_resource_proto.resource import CompositeInstance, Resource
from kci_resource_proto.secrets import Secret
from kci_resource_proto.triggers import EventTrigger, Schedule, SourceEvent


@fieldwise_init
struct Held(Copyable, Movable):
    """One held range of one message: `lo` to `hi`, inclusive."""

    var message: String
    var lo: Int
    var hi: Int
    var why: String


def _held() -> List[Held]:
    """Every held number of the schema, by message. The file header of
    resource.proto states the same list in prose."""
    var l = List[Held]()
    # Resource: header fields, then the body oneof.
    l.append(Held("Resource", 4, 4, "reserved: the retired stage filter"))
    l.append(Held("Resource", 5, 5, "a typed per-cloud settings map"))
    l.append(Held("Resource", 17, 17, "unused"))
    l.append(Held("Resource", 19, 19, "unused"))
    l.append(
        Held(
            "Resource",
            32,
            36,
            "mail domain .. virtual machine (the later neutral primitives)",
        )
    )
    l.append(Held("Resource", 90, 90, "the raw escape hatch"))
    l.append(Held("Resource", 100, 299, "provider primitives, first cloud"))
    l.append(Held("Resource", 300, 499, "provider primitives, second cloud"))
    l.append(Held("Resource", 500, 699, "provider primitives, third cloud"))
    l.append(Held("Resource", 700, 899, "provider primitives, fourth cloud"))
    # Shared shapes.
    l.append(Held("Value", 4, 4, "never a secret value"))
    l.append(Held("Image", 4, 4, "an artifact_ref source arm"))
    l.append(Held("Uses", 3, 3, "held"))
    # Composites: the instance's image and secret inputs, and the
    # definition's bindings, variants and optional components.
    l.append(Held("CompositeInstance", 6, 6, "secret inputs"))
    l.append(Held("CompositeDefinition", 8, 8, "variants chosen by capability"))
    # The primitives: per-cloud extensions 50 to 53 on each, and their own.
    l.append(Held("Service", 13, 13, "a source that may be a non-image artifact"))
    l.append(Held("Service", 50, 53, "per-cloud extensions"))
    l.append(Held("ContainerJob", 8, 8, "a source that may be a non-image artifact"))
    l.append(Held("ContainerJob", 10, 11, "reserved: the trigger, which moved out"))
    l.append(Held("ContainerJob", 50, 53, "per-cloud extensions"))
    l.append(Held("Worker", 3, 3, "reserved: a draft's scale"))
    l.append(Held("Worker", 10, 11, "reserved: a draft's source"))
    l.append(Held("Worker", 12, 12, "a source that may be a non-image artifact"))
    l.append(Held("Worker", 50, 53, "per-cloud extensions"))
    l.append(Held("Table", 4, 4, "an analytics replica"))
    l.append(Held("Table", 50, 53, "per-cloud extensions"))
    l.append(Held("Bucket", 50, 53, "per-cloud extensions"))
    l.append(Held("ServiceAccount", 50, 53, "per-cloud extensions"))
    l.append(Held("Grant", 50, 53, "per-cloud extensions"))
    l.append(Held("Queue", 50, 53, "per-cloud extensions"))
    l.append(Held("Topic", 50, 53, "per-cloud extensions"))
    l.append(Held("Subscription", 50, 53, "per-cloud extensions"))
    l.append(Held("Secret", 50, 53, "per-cloud extensions"))
    l.append(Held("DnsZone", 50, 53, "per-cloud extensions"))
    l.append(Held("DnsRecord", 50, 53, "per-cloud extensions"))
    l.append(Held("Certificate", 50, 53, "per-cloud extensions"))
    l.append(Held("Schedule", 50, 53, "per-cloud extensions"))
    l.append(Held("EventTrigger", 50, 53, "per-cloud extensions"))
    l.append(Held("Network", 50, 53, "per-cloud extensions"))
    l.append(Held("Subnet", 50, 53, "per-cloud extensions"))
    l.append(Held("IpAddress", 50, 53, "per-cloud extensions"))
    l.append(Held("Registry", 2, 2, "who may read it beyond its grants"))
    l.append(Held("Registry", 50, 53, "per-cloud extensions"))
    return l^


# ---- the probe -------------------------------------------------------------------


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _probe_record(n: Int) -> List[UInt8]:
    """Field `n`, length-delimited, payload "x"."""
    var b = List[UInt8]()
    _varint(b, UInt64((n << 3) | 2))
    _varint(b, 1)
    b.append(UInt8(ord("x")))
    return b^


def _undeclared[T: Serializable & ImplicitlyDestructible](head: List[UInt8], n: Int) raises -> Bool:
    """True iff field `n` of `T` is unknown to the generated code: the probe
    record is skipped and the message encodes as it did without it."""
    var plain = encode_proto(decode_proto[T](head.copy()))
    var b = head.copy()
    b.extend(_probe_record(n))
    var got: List[UInt8]
    try:
        got = encode_proto(decode_proto[T](b^))
    except:
        return False  # decoded as a declared message, map or number
    if len(got) != len(plain):
        return False
    for i in range(len(got)):
        if got[i] != plain[i]:
            return False
    return True


def _undeclared_in(message: String, n: Int) raises -> Bool:
    """`_undeclared` for the message called `message`, with a head that sets
    one of its own fields (so a probe is read after real content)."""
    var head = List[UInt8]()
    if message == "Resource":
        head.append(0x0A)  # 1: id
        head.append(1)
        head.append(UInt8(ord("r")))
        return _undeclared[Resource](head, n)
    if message == "Value":
        head.append(0x0A)  # 1: literal
        head.append(1)
        head.append(UInt8(ord("v")))
        return _undeclared[Value](head, n)
    if message == "CompositeInstance":
        head.append(0x0A)  # 1: definition
        head.append(1)
        head.append(UInt8(ord("d")))
        return _undeclared[CompositeInstance](head, n)
    if message == "CompositeDefinition":
        head.append(0x0A)  # 1: name
        head.append(1)
        head.append(UInt8(ord("n")))
        return _undeclared[CompositeDefinition](head, n)
    if message == "Image":
        head.append(0x12)  # 2: digest
        head.append(1)
        head.append(UInt8(ord("d")))
        return _undeclared[Image](head, n)
    if message == "Uses":
        head.append(0x10)  # 2: access
        head.append(UInt8(Access.READ))
        return _undeclared[Uses](head, n)
    if message == "Service":
        head.append(0x10)  # 2: port
        head.append(80)
        return _undeclared[Service](head, n)
    if message == "ContainerJob":
        head.append(0x12)  # 2: args
        head.append(1)
        head.append(UInt8(ord("a")))
        return _undeclared[ContainerJob](head, n)
    if message == "Worker":
        head.append(0x22)  # 4: args
        head.append(1)
        head.append(UInt8(ord("a")))
        return _undeclared[Worker](head, n)
    if message == "Table":
        head.append(0x1A)  # 3: ttl_field
        head.append(1)
        head.append(UInt8(ord("t")))
        return _undeclared[Table](head, n)
    if message == "Bucket":
        head.append(0x10)  # 2: versioning
        head.append(1)
        return _undeclared[Bucket](head, n)
    if message == "ServiceAccount":
        return _undeclared[ServiceAccount](head, n)
    if message == "Grant":
        head.append(0x18)  # 3: access
        head.append(UInt8(Access.READ))
        return _undeclared[Grant](head, n)
    if message == "Queue":
        head.append(0x18)  # 3: max_deliveries
        head.append(5)
        return _undeclared[Queue](head, n)
    if message == "Topic":
        return _undeclared[Topic](head, n)
    if message == "Subscription":
        head.append(0x0A)  # 1: topic, a Ref { resource: "t" }
        head.append(3)
        head.append(0x0A)
        head.append(1)
        head.append(UInt8(ord("t")))
        return _undeclared[Subscription](head, n)
    if message == "Secret":
        return _undeclared[Secret](head, n)
    if message == "DnsZone":
        head.append(0x0A)  # 1: name
        head.append(1)
        head.append(UInt8(ord("z")))
        return _undeclared[DnsZone](head, n)
    if message == "DnsRecord":
        head.append(0x18)  # 3: type
        head.append(3)
        return _undeclared[DnsRecord](head, n)
    if message == "Certificate":
        head.append(0x0A)  # 1: domains
        head.append(1)
        head.append(UInt8(ord("d")))
        return _undeclared[Certificate](head, n)
    if message == "Schedule":
        head.append(0x0A)  # 1: cron
        head.append(1)
        head.append(UInt8(ord("c")))
        return _undeclared[Schedule](head, n)
    if message == "EventTrigger":
        head.append(0x10)  # 2: event
        head.append(UInt8(SourceEvent.OBJECT_CREATED))
        return _undeclared[EventTrigger](head, n)
    if message == "Network":
        head.append(0x0A)  # 1: ipv4_cidr
        head.append(1)
        head.append(UInt8(ord("n")))
        return _undeclared[Network](head, n)
    if message == "Subnet":
        head.append(0x18)  # 3: zone
        head.append(2)
        return _undeclared[Subnet](head, n)
    if message == "IpAddress":
        return _undeclared[IpAddress](head, n)
    if message == "Registry":
        head.append(0x08)  # 1: format
        head.append(1)
        return _undeclared[Registry](head, n)
    raise Error(String("no probe for message ") + message)


# ---- the census --------------------------------------------------------------------


def test_every_held_number_is_undeclared() raises:
    """Every number of every row of `_held()`."""
    var rows = _held()
    var probed = 0
    for r in range(len(rows)):
        ref row = rows[r]
        assert_true(row.lo <= row.hi, row.message + ": an empty range is a typo")
        for n in range(row.lo, row.hi + 1):
            assert_true(
                _undeclared_in(row.message, n),
                row.message
                + String(" field ")
                + String(n)
                + String(" is held (")
                + row.why
                + String("), but the generated code declares it"),
            )
            probed += 1
    # 800 provider-primitive numbers alone: a range that shrank to nothing
    # by a typo would show here.
    assert_true(probed > 830, String("probed ") + String(probed) + " numbers")
    print("  test_every_held_number_is_undeclared: PASS (" + String(probed) + " numbers)")


def test_the_probe_sees_a_declared_number() raises:
    """One DECLARED number per probed message, of each wire shape: the probe
    must call it declared, or the census above proves nothing."""
    var names = List[String]()
    var nums = List[Int]()
    var what = List[String]()
    names.append("Resource")
    nums.append(13)
    what.append("the table arm (a message in a oneof)")
    names.append("Resource")
    nums.append(1)
    what.append("id (a string)")
    names.append("Resource")
    nums.append(3)
    what.append("retention (an enum)")
    names.append("Resource")
    nums.append(6)
    what.append("physical_name (an optional string)")
    names.append("Resource")
    nums.append(7)
    what.append("labels (a map)")
    names.append("Resource")
    nums.append(8)
    what.append("adopt (a bool)")
    names.append("Value")
    nums.append(2)
    what.append("param (a string oneof arm)")
    names.append("Image")
    nums.append(3)
    what.append("platform (a string)")
    names.append("Uses")
    nums.append(4)
    what.append("cell (an enum)")
    names.append("Service")
    nums.append(3)
    what.append("args (a repeated string)")
    names.append("Service")
    nums.append(4)
    what.append("env (a map)")
    names.append("Service")
    nums.append(2)
    what.append("port (a number)")
    names.append("ContainerJob")
    nums.append(13)
    what.append("run_as (a message)")
    names.append("ContainerJob")
    nums.append(9)
    what.append("command (a repeated string)")
    names.append("Resource")
    nums.append(12)
    what.append("the worker arm (a message in a oneof)")
    names.append("Worker")
    nums.append(8)
    what.append("replicas (an optional number)")
    names.append("Worker")
    nums.append(5)
    what.append("command (a repeated string)")
    names.append("Worker")
    nums.append(9)
    what.append("run_as (a message)")
    names.append("Table")
    nums.append(2)
    what.append("indexes (a repeated message)")
    names.append("Table")
    nums.append(3)
    what.append("ttl_field (an optional string)")
    names.append("Bucket")
    nums.append(1)
    what.append("object_expiry_days (an optional number)")
    names.append("Bucket")
    nums.append(2)
    what.append("versioning (a bool)")
    names.append("Grant")
    nums.append(1)
    what.append("principal (a message)")
    names.append("Resource")
    nums.append(21)
    what.append("the topic arm (an empty message in a oneof)")
    names.append("Queue")
    nums.append(1)
    what.append("ack_deadline (a well-known message)")
    names.append("Queue")
    nums.append(3)
    what.append("max_deliveries (an optional number)")
    names.append("Subscription")
    nums.append(2)
    what.append("queue (a message)")
    names.append("Resource")
    nums.append(16)
    what.append("the secret arm (an empty message in a oneof)")
    for arm in [18, 26, 27]:
        names.append("Resource")
        nums.append(arm)
        what.append("a DNS or certificate arm (a message in a oneof)")
    names.append("DnsZone")
    nums.append(1)
    what.append("name (a string)")
    names.append("DnsRecord")
    nums.append(4)
    what.append("values (a repeated message)")
    names.append("DnsRecord")
    nums.append(3)
    what.append("type (an enum)")
    names.append("Certificate")
    nums.append(1)
    what.append("domains (a repeated string)")
    for arm in [22, 31]:
        names.append("Resource")
        nums.append(arm)
        what.append("a trigger arm (a message in a oneof)")
    names.append("Schedule")
    nums.append(2)
    what.append("timezone (a string)")
    names.append("Schedule")
    nums.append(3)
    what.append("target (a message)")
    names.append("EventTrigger")
    nums.append(1)
    what.append("source (a message)")
    names.append("EventTrigger")
    nums.append(2)
    what.append("event (an enum)")
    for arm in [23, 29, 30]:
        names.append("Resource")
        nums.append(arm)
        what.append("a network arm (a message in a oneof)")
    names.append("Network")
    nums.append(1)
    what.append("ipv4_cidr (a string)")
    names.append("Subnet")
    nums.append(1)
    what.append("network (a message)")
    names.append("Subnet")
    nums.append(2)
    what.append("ipv4_cidr (a string)")
    names.append("Subnet")
    nums.append(3)
    what.append("zone (an optional number)")
    names.append("Service")
    nums.append(16)
    what.append("network (a message)")
    names.append("Resource")
    nums.append(24)
    what.append("the registry arm (a message in a oneof)")
    names.append("Registry")
    nums.append(1)
    what.append("format (an enum)")
    names.append("Resource")
    nums.append(80)
    what.append("the composite arm (a message in a oneof)")
    names.append("CompositeInstance")
    nums.append(4)
    what.append("input (a map)")
    names.append("CompositeInstance")
    nums.append(3)
    what.append("digest (an optional string)")
    names.append("CompositeDefinition")
    nums.append(4)
    what.append("component (a repeated message)")
    names.append("CompositeDefinition")
    nums.append(7)
    what.append("export (a repeated string)")
    names.append("CompositeDefinition")
    nums.append(10)
    what.append("doc (a string)")
    names.append("CompositeInstance")
    nums.append(5)
    what.append("image_input (a map of messages)")
    names.append("CompositeInstance")
    nums.append(7)
    what.append("map_input (a map of messages)")
    names.append("CompositeDefinition")
    nums.append(5)
    what.append("bind (a repeated message)")
    names.append("CompositeDefinition")
    nums.append(9)
    what.append("presence (a repeated message)")
    for i in range(len(names)):
        assert_true(
            not _undeclared_in(names[i], nums[i]),
            names[i]
            + String(" field ")
            + String(nums[i])
            + String(", ")
            + what[i]
            + String(": the probe must see a declared field"),
        )
    print("  test_the_probe_sees_a_declared_number: PASS")


def test_held_enum_values_are_unnamed() raises:
    """`Output` 5 (REVISION), `Access` 7 (ACT_AS) and 9 (MANAGE),
    `CellResource` 4 (COMPUTE), `SourceEvent` 3 (a message published to a
    topic), `InputType` 4 (DURATION), 7 (SECRET) and 8 (RETENTION): each
    renders as its bare number."""
    assert_equal(Output(5).json_name(), "5", "Output 5 is held")
    var access = List[Int]()
    access.append(7)
    access.append(9)
    for i in range(len(access)):
        assert_equal(
            Access(access[i]).json_name(),
            String(access[i]),
            String("Access ") + String(access[i]) + " is held",
        )
    assert_equal(CellResource(4).json_name(), "4", "CellResource 4 is held")
    assert_equal(SourceEvent(3).json_name(), "3", "SourceEvent 3 is held")
    for n in [4, 7, 8]:
        assert_equal(InputType(n).json_name(), String(n), String("InputType ") + String(n) + " is held")
    print("  test_held_enum_values_are_unnamed: PASS")


def main() raises:
    print("test_resource_held_numbers: every held number of kci.resource.v1")
    test_the_probe_sees_a_declared_number()
    test_every_held_number_is_undeclared()
    test_held_enum_values_are_unnamed()
    print("ALL kci.resource.v1 HELD-NUMBER TESTS PASSED")
