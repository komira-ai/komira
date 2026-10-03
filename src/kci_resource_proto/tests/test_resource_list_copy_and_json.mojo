# =============================================================================
# test_resource_list_copy_and_json.mojo
# =============================================================================
#
# Two properties a consumer of the catalog relies on and the field-number
# census does not cover:
#
# 1. A `List[Resource]` can be COPIED and the copy dropped without touching
#    the original. On Mojo 1.0.0 a struct with an explicit `__deinit__` and no
#    explicit copy constructor can get a TRIVIAL synthesized copy, so
#    `List.copy()` copies its elements with memcpy and the copy and the
#    original share String buffers: dropping the copy frees them under the
#    original. Every generated message here has an explicit `__deinit__`, and
#    the deploy engine copies resource lists, so this is pinned on the real
#    catalog types with strings longer than the inline capacity.
#
# 2. The proto3 JSON form round-trips a whole list, under the camelCase names
#    an author's tooling sees (`healthPath`, `schedule`, `timezone`), and
#    re-encodes to the same binary bytes.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.resource import Resource, ResourceList


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _str(mut b: List[UInt8], field: Int, s: String):
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    _varint(b, UInt64(field << 3))
    _varint(b, v)


# 48 bytes: above the inline capacity of a String, so it owns a heap buffer.
def _long(tag: String, i: Int) -> String:
    var s = tag + String("-") + String(i) + String("-")
    while s.byte_length() < 48:
        s += "x"
    return s^


def _service_resource(i: Int) -> List[UInt8]:
    """A `service` whose every string is heap-owned."""
    var target = List[UInt8]()
    _str(target, 1, _long("target", i))
    var uses = List[UInt8]()
    _msg(uses, 1, target)
    _uint(uses, 2, 1)  # CALL
    var literal = List[UInt8]()
    _str(literal, 1, _long("value", i))
    var entry = List[UInt8]()
    _str(entry, 1, _long("KEY", i))
    _msg(entry, 2, literal)
    var svc = List[UInt8]()
    _uint(svc, 2, 8080)
    _str(svc, 3, _long("arg", i))
    _msg(svc, 4, entry)
    _str(svc, 7, _long("/healthz", i))
    _msg(svc, 10, List[UInt8]())
    var r = List[UInt8]()
    _str(r, 1, _long("api", i))
    _msg(r, 2, uses)
    _msg(r, 10, svc)
    return r^


def _job_resource(i: Int) -> List[UInt8]:
    var sched = List[UInt8]()
    _str(sched, 1, _long("cron", i))
    _str(sched, 2, _long("tz", i))
    var digest = List[UInt8]()
    _str(digest, 2, _long("sha256", i))
    var job = List[UInt8]()
    _msg(job, 1, digest)
    _str(job, 2, _long("report", i))
    _msg(job, 11, sched)
    var r = List[UInt8]()
    _str(r, 1, _long("job", i))
    _msg(r, 11, job)
    return r^


comptime _N = 8


def _list_bytes() -> List[UInt8]:
    var b = List[UInt8]()
    for i in range(_N):
        _msg(b, 1, _service_resource(i))
        _msg(b, 1, _job_resource(i))
    return b^


def _check_originals(lst: List[Resource], what: String) raises:
    assert_equal(len(lst), 2 * _N, what + ": length")
    for i in range(_N):
        ref a = lst[2 * i]
        assert_equal(a.id, _long("api", i), what + ": service id")
        assert_equal(
            a.uses[0].target.value().resource,
            _long("target", i),
            what + ": uses target",
        )
        ref svc = a.service.value()
        assert_equal(svc.args[0], _long("arg", i), what + ": args")
        assert_equal(
            svc.env[_long("KEY", i)].literal.value(),
            _long("value", i),
            what + ": env",
        )
        assert_equal(svc.health_path, _long("/healthz", i), what + ": health")
        ref j = lst[2 * i + 1]
        assert_equal(j.id, _long("job", i), what + ": job id")
        ref job = j.job.value()
        assert_equal(
            job.image.value().digest.value(), _long("sha256", i), what + ": image"
        )
        assert_equal(job.args[0], _long("report", i), what + ": job args")
        assert_equal(job.schedule.value().cron, _long("cron", i), what + ": cron")
        assert_equal(
            job.schedule.value().timezone, _long("tz", i), what + ": timezone"
        )


def test_list_copy_does_not_alias_the_original() raises:
    var lst = decode_proto[ResourceList](_list_bytes())
    _check_originals(lst.resource, "decoded")

    # Copy the list, drop the copy, then churn same-size allocations. With a
    # trivial copy the originals' buffers are freed here and reused below.
    var copied = lst.resource.copy()
    _check_originals(copied, "the copy")
    _ = copied^
    var churn = List[String]()
    for i in range(256):
        churn.append(_long("CHURN", i))
    _check_originals(lst.resource, "the original after the copy was dropped")
    assert_equal(len(churn), 256)

    # The same for a copy of the whole message.
    var whole = lst.copy()
    _ = whole^
    var churn2 = List[String]()
    for i in range(256):
        churn2.append(_long("CHURN2", i))
    _check_originals(lst.resource, "the original after a message copy")
    print("  test_list_copy_does_not_alias_the_original: PASS")


def test_json_round_trip_of_a_list() raises:
    var bytes = _list_bytes()
    var lst = decode_proto[ResourceList](bytes.copy())
    var text = encode_json(lst)
    for key in ['"healthPath"', '"schedule"', '"timezone"', '"uses"']:
        assert_true(
            String(key) in text,
            String("proto3 JSON carries ") + String(key) + ": " + text,
        )
    assert_true('"access":"CALL"' in text, "an enum renders by name: " + text)
    var back = decode_json[ResourceList](text)
    _check_originals(back.resource, "after JSON")
    # Compared against the encoding of the list as first decoded, not the
    # hand-written bytes: this codec also writes zero-valued scalars.
    var first = encode_proto(lst)
    var again = encode_proto(back)
    assert_equal(len(again), len(first), "JSON round trip: binary length")
    for i in range(len(first)):
        assert_equal(again[i], first[i], "JSON round trip: byte " + String(i))
    print("  test_json_round_trip_of_a_list: PASS")


def main() raises:
    print("test_resource_list_copy_and_json")
    test_list_copy_does_not_alias_the_original()
    test_json_round_trip_of_a_list()
    print("ALL kci.resource.v1 LIST-COPY AND JSON TESTS PASSED")
