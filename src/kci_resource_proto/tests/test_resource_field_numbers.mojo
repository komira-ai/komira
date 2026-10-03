# =============================================================================
# test_resource_field_numbers.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS for `kci.resource.v1`, stated as WIRE BYTES.
#
# A proto field number is what is stored. Renumbering a field is legal to
# protoc and compiles clean; a list written before the change and read after
# it does not fail to parse, it decodes as the WRONG field. Nothing in the
# toolchain objects, so this file is the guard.
#
# HOW EACH MESSAGE IS PINNED. For every message, a byte stream is written by
# hand here, field by field, with the number the proto declares and a value
# no other field of that message holds. Then:
#   1. it is decoded, and every field is read back BY NAME. This is the half
#      that catches two fields of one wire type swapping numbers (a cron and a
#      timezone, say): a pure round trip would re-encode the swapped value at
#      the swapped number and come out byte-identical.
#   2. the decoded message is encoded again and must give the hand-written
#      records back (zero values aside; see `_canon`). This catches a field
#      moved to a number nothing else uses (the value is skipped as unknown on
#      decode and missing on encode) and a changed wire type.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
#
# ALSO PINNED: the two v1 `Resource.body` arms (10 service, 11 job) by number
# AND by which field each fills; the HELD numbers (body 12 to 19 for the later
# types, 90 for the escape hatch, `Resource` 3, `Value` 4) decode as unknown
# today, so nothing else has taken them; the retired field 4 is ignored; and
# every enum's ordinals in both directions, held values undeclared.
#
# THE FIELDS ADDED AFTER THE FIRST DRAFT, each pinned the same two ways:
# `Image.platform` 3 (`ArtifactPlatform` 1 os, 2 cpu), `SecretRef` 1 name,
# `Service.secret_env` 12, `Job.env` 6 and `Job.secret_env` 7. And
# `test_added_numbers_are_kept` restates them with decode and encode ONLY, so
# it compiles against a schema without them and fails there at run time: a
# number the schema does not declare is dropped on re-encode.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_proto, encode_proto
from kci_resource_proto.resource import (
    Access,
    ArtifactPlatform,
    Cpu,
    Image,
    Job,
    Os,
    Output,
    Portability,
    Ref,
    Resource,
    ResourceList,
    SecretRef,
    Service,
    Uses,
    Value,
)


# ---- a hand-written wire stream ------------------------------------------------

comptime _VARINT = 0
comptime _LEN = 2


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _tag(mut b: List[UInt8], field: Int, wire_type: Int):
    _varint(b, UInt64((field << 3) | wire_type))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    _tag(b, field, _VARINT)
    _varint(b, v)


def _str(mut b: List[UInt8], field: Int, s: String):
    _tag(b, field, _LEN)
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    _tag(b, field, _LEN)
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _empty(mut b: List[UInt8], field: Int):
    _msg(b, field, List[UInt8]())


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


# ⚠ THIS CODEC WRITES PROTO3 ZERO VALUES. Its binary encoder emits a scalar
# field at its default (`port: 0`, `health_path: ""`, `retain: 0`) where
# canonical protobuf omits it, and both forms decode identically. Comparing raw
# bytes would pin that codec behaviour, not the catalog, so both sides are
# canonicalized first: a record whose value is zero (a 0 varint, an all-zero
# fixed field, or a length-delimited record whose canonical content is empty)
# is dropped, recursively. What this cannot see (an empty sub-message, such as
# `public {}`) is pinned by the named-field and oneof-case assertions instead.
#
# ⚠ AND IT WRITES A MESSAGE'S PLAIN FIELDS BEFORE ITS ONEOF FIELDS (an
# `Image` with a digest and a platform comes out as 3 then 2). Protobuf fixes
# the order of records only WITHIN one field number (a repeated field), so the
# canonical form also sorts each level's records by field number, stably:
# records of different fields compare in any order, a repeated field's
# elements keep theirs.


def _read_varint(b: List[UInt8], mut pos: Int, mut ok: Bool) -> UInt64:
    var v: UInt64 = 0
    var shift: UInt64 = 0
    while pos < len(b) and shift < 64:
        var c = b[pos]
        pos += 1
        v |= UInt64(c & 0x7F) << shift
        if (c & 0x80) == 0:
            return v
        shift += 7
    ok = False
    return v


def _canon(b: List[UInt8], mut out: List[UInt8]) -> Bool:
    """`b` as a message with every zero-valued record dropped, recursively,
    and its records sorted stably by field number. False when `b` does not
    parse as a message (it is then compared raw)."""
    var fields = List[Int]()
    var records = List[List[UInt8]]()
    if not _canon_records(b, fields, records):
        return False
    # Stable insertion sort by field number: equal numbers keep their order.
    var order = List[Int]()
    for i in range(len(fields)):
        var j = len(order)
        order.append(i)
        while j > 0 and fields[order[j - 1]] > fields[i]:
            order[j] = order[j - 1]
            j -= 1
        order[j] = i
    for k in range(len(order)):
        ref rec = records[order[k]]
        for x in range(len(rec)):
            out.append(rec[x])
    return True


def _canon_records(
    b: List[UInt8], mut fields: List[Int], mut records: List[List[UInt8]]
) -> Bool:
    """The non-zero records of `b`, each canonicalized, in wire order."""
    var pos = 0
    var ok = True
    while pos < len(b):
        var tag = _read_varint(b, pos, ok)
        if not ok or (tag >> 3) == 0:
            return False
        var wt = Int(tag & 7)
        if wt == _VARINT:
            var v = _read_varint(b, pos, ok)
            if not ok:
                return False
            if v != 0:
                var rec = List[UInt8]()
                _varint(rec, tag)
                _varint(rec, v)
                fields.append(Int(tag >> 3))
                records.append(rec^)
        elif wt == _LEN:
            var n = Int(_read_varint(b, pos, ok))
            if not ok or pos + n > len(b):
                return False
            var content = List[UInt8]()
            for k in range(n):
                content.append(b[pos + k])
            pos += n
            var inner = List[UInt8]()
            if not _canon(content, inner):
                inner = content^
            if len(inner) > 0:
                var rec = List[UInt8]()
                _varint(rec, tag)
                _varint(rec, UInt64(len(inner)))
                for k in range(len(inner)):
                    rec.append(inner[k])
                fields.append(Int(tag >> 3))
                records.append(rec^)
        elif wt == 1 or wt == 5:
            var width = 8 if wt == 1 else 4
            if pos + width > len(b):
                return False
            var nonzero = False
            for k in range(width):
                if b[pos + k] != 0:
                    nonzero = True
            if nonzero:
                var rec = List[UInt8]()
                _varint(rec, tag)
                for k in range(width):
                    rec.append(b[pos + k])
                fields.append(Int(tag >> 3))
                records.append(rec^)
            pos += width
        else:
            return False
    return True


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    var cg = List[UInt8]()
    var cw = List[UInt8]()
    assert_true(_canon(got, cg), what + ": the encoding does not parse")
    assert_true(_canon(want, cw), what + ": the hand-written bytes do not parse")
    var ok = len(cg) == len(cw)
    if ok:
        for i in range(len(cg)):
            if cg[i] != cw[i]:
                ok = False
                break
    assert_true(
        ok,
        what
        + ": re-encoding the decoded message does not give the hand-written"
        + " records back (zero values aside), so a field number or wire type"
        + " moved.\n  want "
        + _hex(want)
        + "\n  got  "
        + _hex(got),
    )


# Small sub-messages, each written once.


def _ref(resource: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, resource)
    return b^


def _ref_out(resource: String, output: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, resource)
    _uint(b, 2, UInt64(output))
    return b^


def _duration(seconds: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, UInt64(seconds))
    return b^


def _size(cpu_millis: Int, memory_mb: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, UInt64(cpu_millis))
    _uint(b, 2, UInt64(memory_mb))
    return b^


def _scale(lo: Int, hi: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, UInt64(lo))
    _uint(b, 2, UInt64(hi))
    return b^


def _action_output(action: String, name: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, action)
    _str(b, 2, name)
    return b^


def _image_from_action(action: String, name: String) -> List[UInt8]:
    var b = List[UInt8]()
    _msg(b, 1, _action_output(action, name))
    return b^


def _image_digest(digest: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 2, digest)
    return b^


def _platform(os: Int, cpu: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _uint(b, 1, UInt64(os))
    _uint(b, 2, UInt64(cpu))
    return b^


def _secret(name: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, name)
    return b^


def _entry(key: String, value: List[UInt8]) -> List[UInt8]:
    """One map entry: 1 key, 2 value (a message)."""
    var b = List[UInt8]()
    _str(b, 1, key)
    _msg(b, 2, value)
    return b^


def _literal(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, s)
    return b^


# ---- references -------------------------------------------------------------------


def test_ref() raises:
    """Ref: 1 resource; oneof output { 2 standard, 3 named }."""
    var b = _ref_out("jobs", Output.HOST)
    var r = decode_proto[Ref](b.copy())
    assert_equal(r.resource, "jobs")
    assert_equal(r._oneof0_case, 1, "field 2 is the `standard` arm")
    assert_equal(r.standard.value().value, Output.HOST)
    _same(encode_proto(r), b, "Ref.standard")

    var n = List[UInt8]()
    _str(n, 1, "search")
    _str(n, 3, "endpoint")
    var rn = decode_proto[Ref](n.copy())
    assert_equal(rn._oneof0_case, 2, "field 3 is the `named` arm")
    assert_equal(rn.named.value(), "endpoint")
    _same(encode_proto(rn), n, "Ref.named")

    # Neither arm: the resource itself (an identity reference).
    var bare = _ref("orders")
    var rb = decode_proto[Ref](bare.copy())
    assert_equal(rb._oneof0_case, 0, "no arm set names the resource itself")
    _same(encode_proto(rb), bare, "Ref bare")
    print("  test_ref: PASS")


def test_uses() raises:
    """Uses: 1 target, 2 access."""
    var b = List[UInt8]()
    _msg(b, 1, _ref("billing"))
    _uint(b, 2, UInt64(Access.CALL))
    var u = decode_proto[Uses](b.copy())
    assert_equal(u.target.value().resource, "billing")
    assert_equal(u.access.value, Access.CALL)
    _same(encode_proto(u), b, "Uses")
    print("  test_uses: PASS")


def test_value_arms() raises:
    """Value: oneof v { 1 literal, 2 param, 3 ref }; 4 held."""
    var lit = List[UInt8]()
    _str(lit, 1, "plain")
    var v1 = decode_proto[Value](lit.copy())
    assert_equal(v1._oneof0_case, 1)
    assert_equal(v1.literal.value(), "plain")
    _same(encode_proto(v1), lit, "Value.literal")

    var par = List[UInt8]()
    _str(par, 2, "region_param")
    var v2 = decode_proto[Value](par.copy())
    assert_equal(v2._oneof0_case, 2)
    assert_equal(v2.param.value(), "region_param")
    _same(encode_proto(v2), par, "Value.param")

    var rf = List[UInt8]()
    _msg(rf, 3, _ref_out("jobs", Output.HOST))
    var v3 = decode_proto[Value](rf.copy())
    assert_equal(v3._oneof0_case, 3)
    assert_equal(v3.ref_.value().resource, "jobs")
    _same(encode_proto(v3), rf, "Value.ref")

    # 4 is held: a secret never rides a Value (it is a `SecretRef` on the
    # service or job). Undeclared today, so unknown.
    var sec = List[UInt8]()
    _msg(sec, 4, _ref("stripe_key"))
    var v4 = decode_proto[Value](sec.copy())
    assert_equal(v4._oneof0_case, 0, "Value field 4 is held, not declared")
    print("  test_value_arms: PASS")


def test_image_arms() raises:
    """Image: oneof source { 1 output, 2 digest }."""
    var o = List[UInt8]()
    _msg(o, 1, _action_output("build", "docs_bundle"))
    var c = decode_proto[Image](o.copy())
    assert_equal(c._oneof0_case, 1)
    assert_equal(c.output.value().action, "build")
    assert_equal(c.output.value().name, "docs_bundle")
    _same(encode_proto(c), o, "Image.output")

    var d = List[UInt8]()
    _str(d, 2, "sha256:cd")
    var cd = decode_proto[Image](d.copy())
    assert_equal(cd._oneof0_case, 2)
    assert_equal(cd.digest.value(), "sha256:cd")
    _same(encode_proto(cd), d, "Image.digest")

    # No platform: the field is absent (a reader takes the v1 default).
    assert_true(not Bool(cd.platform), "Image.platform is unset when not written")
    print("  test_image_arms: PASS")


def test_image_platform() raises:
    """Image: 3 platform, beside either source arm. ArtifactPlatform: 1 os,
    2 cpu."""
    var p = _platform(Os.LINUX, Cpu.X86_64)
    var ap = decode_proto[ArtifactPlatform](p.copy())
    assert_equal(ap.os.value, Os.LINUX, "ArtifactPlatform field 1 is `os`")
    assert_equal(ap.cpu.value, Cpu.X86_64, "ArtifactPlatform field 2 is `cpu`")
    _same(encode_proto(ap), p, "ArtifactPlatform")

    # os and cpu are told apart by number, not by a shared value.
    var swapped = List[UInt8]()
    _uint(swapped, 2, UInt64(Cpu.X86_64))
    var only_cpu = decode_proto[ArtifactPlatform](swapped.copy())
    assert_equal(only_cpu.os.value, Os.OS_UNSET, "field 2 does not fill `os`")
    assert_equal(only_cpu.cpu.value, Cpu.X86_64)

    var o = List[UInt8]()
    _msg(o, 1, _action_output("build", "api_image"))
    _msg(o, 3, _platform(Os.LINUX, Cpu.X86_64))
    var io = decode_proto[Image](o.copy())
    assert_equal(io._oneof0_case, 1, "platform does not touch the source arm")
    assert_equal(io.output.value().name, "api_image")
    assert_equal(io.platform.value().os.value, Os.LINUX)
    assert_equal(io.platform.value().cpu.value, Cpu.X86_64)
    _same(encode_proto(io), o, "Image.output + platform")

    var d = List[UInt8]()
    _str(d, 2, "sha256:ef")
    _msg(d, 3, _platform(Os.LINUX, Cpu.X86_64))
    var idg = decode_proto[Image](d.copy())
    assert_equal(idg._oneof0_case, 2)
    assert_equal(idg.digest.value(), "sha256:ef")
    assert_equal(idg.platform.value().cpu.value, Cpu.X86_64)
    _same(encode_proto(idg), d, "Image.digest + platform")

    # An undeclared value survives decode as its number: the schema cannot
    # refuse it, the validate phase does (linux x86_64 only in v1).
    var other = decode_proto[ArtifactPlatform](_platform(2, 2))
    assert_equal(other.os.value, 2)
    assert_equal(other.cpu.value, 2)
    print("  test_image_platform: PASS")


def test_secret_ref() raises:
    """SecretRef: 1 name. One field, and it is a name."""
    var b = _secret("db_password")
    var s = decode_proto[SecretRef](b.copy())
    assert_equal(s.name, "db_password")
    _same(encode_proto(s), b, "SecretRef")

    var held = List[UInt8]()
    _str(held, 1, "db_password")
    _str(held, 2, "not-a-field")
    var sh = decode_proto[SecretRef](held.copy())
    _same(encode_proto(sh), b, "SecretRef has no field 2")
    print("  test_secret_ref: PASS")


def test_added_numbers_are_kept() raises:
    """Decode and encode only, nothing read by name: every number added after
    the first draft must survive a round trip. Against a schema that lacks one
    it is unknown, dropped on re-encode, and this fails."""
    var img = List[UInt8]()
    _str(img, 2, "sha256:01")
    _msg(img, 3, _platform(1, 1))
    _same(encode_proto(decode_proto[Image](img.copy())), img, "Image 3")

    var svc = List[UInt8]()
    _uint(svc, 2, 8080)
    _msg(svc, 12, _entry("DB_PASSWORD", _secret("db_password")))
    _same(encode_proto(decode_proto[Service](svc.copy())), svc, "Service 12")

    var job = List[UInt8]()
    _str(job, 2, "report")
    _msg(job, 6, _entry("MODE", _literal("full")))
    _msg(job, 7, _entry("API_TOKEN", _secret("api_token")))
    _same(encode_proto(decode_proto[Job](job.copy())), job, "Job 6 and 7")
    print("  test_added_numbers_are_kept: PASS")


# ---- Resource and its body arms --------------------------------------------------


def _arm_of(r: Resource) -> String:
    """Which body field is filled, by name; "" if none."""
    if r.service:
        return "service"
    if r.job:
        return "job"
    return ""


def test_resource_body_arms_are_10_and_11() raises:
    """Each v1 body arm, by number AND by the field it fills.

    The arm numbers are the adapter registry's key (one adapter per arm), so a
    renumber would hand a resource to another type's adapter.
    """
    var names = List[String]()
    names.append("service")
    names.append("job")
    for i in range(len(names)):
        var field = 10 + i
        var b = List[UInt8]()
        _str(b, 1, "r")
        _empty(b, field)
        var r = decode_proto[Resource](b.copy())
        assert_equal(
            _arm_of(r),
            names[i],
            String("Resource.body field ") + String(field) + " fills",
        )
        assert_equal(r._oneof0_case, i + 1, "the arm index follows the number")
        _same(
            encode_proto(r),
            b,
            String("Resource.body field ") + String(field),
        )
    print("  test_resource_body_arms_are_10_and_11: PASS")


def test_held_body_numbers_are_undeclared() raises:
    """12 to 19 are held for the later types (worker, table, bucket, queue,
    secret, site, domain, mail_relay) and 90 for the escape hatch. Today each
    decodes as an unknown field: no arm set, dropped on re-encode. When a type
    lands at its held number this test changes with it; anything else taking
    one of these numbers is a mistake."""
    var held = List[Int]()
    for n in range(12, 20):
        held.append(n)
    held.append(90)
    var head = List[UInt8]()
    _str(head, 1, "r")
    for k in range(len(held)):
        var b = head.copy()
        _empty(b, held[k])
        var r = decode_proto[Resource](b.copy())
        assert_equal(
            r._oneof0_case,
            0,
            String("Resource.body field ") + String(held[k]) + " is held",
        )
        _same(
            encode_proto(r),
            head,
            String("held field ") + String(held[k]) + " is unknown",
        )
    print("  test_held_body_numbers_are_undeclared: PASS")


def test_fields_3_and_4_are_not_declared() raises:
    """3 is held for retention (data-bearing types only); 4 (a retired stage
    filter) is reserved. Both decode as unknown: skipped, dropped on
    re-encode."""
    var head = List[UInt8]()
    _str(head, 1, "r")
    var b = head.copy()
    _uint(b, 3, 1)
    _uint(b, 4, 1)
    var r = decode_proto[Resource](b.copy())
    assert_equal(_arm_of(r), "")
    _same(encode_proto(r), head, "fields 3 and 4 are unknown")
    print("  test_fields_3_and_4_are_not_declared: PASS")


def test_resource_header_fields() raises:
    """Resource: 1 id, 2 uses; then the body."""
    var u = List[UInt8]()
    _msg(u, 1, _ref("nightly"))
    _uint(u, 2, UInt64(Access.CALL))
    var b = List[UInt8]()
    _str(b, 1, "api")
    _msg(b, 2, u)
    _empty(b, 10)
    var r = decode_proto[Resource](b.copy())
    assert_equal(r.id, "api")
    assert_equal(len(r.uses), 1)
    assert_equal(r.uses[0].target.value().resource, "nightly")
    assert_equal(r.uses[0].access.value, Access.CALL)
    assert_equal(_arm_of(r), "service")
    _same(encode_proto(r), b, "Resource header")

    var lst = List[UInt8]()
    _msg(lst, 1, b)
    _msg(lst, 1, b)
    var l = decode_proto[ResourceList](lst.copy())
    assert_equal(len(l.resource), 2, "ResourceList: 1 resource (repeated)")
    _same(encode_proto(l), lst, "ResourceList")
    print("  test_resource_header_fields: PASS")


# ---- the v1 types: service and job -------------------------------------------------


def test_service() raises:
    """Service: 1 image .. 9 max_concurrency; oneof { 10 public, 11 internal };
    12 secret_env."""
    var env_value = List[UInt8]()
    _msg(env_value, 3, _ref_out("jobs", Output.HOST))
    var env_entry = List[UInt8]()
    _str(env_entry, 1, "JOBS_ADDR")
    _msg(env_entry, 2, env_value)

    var b = List[UInt8]()
    _msg(b, 1, _image_from_action("build", "api_image"))
    _uint(b, 2, 8080)
    _str(b, 3, "serve")
    _str(b, 3, "--fast")
    _msg(b, 4, env_entry)
    _msg(b, 5, _size(1000, 512))
    _msg(b, 6, _scale(1, 20))
    _str(b, 7, "/healthz")
    _msg(b, 8, _duration(30))
    _uint(b, 9, 80)
    _empty(b, 10)
    _msg(b, 12, _entry("DB_PASSWORD", _secret("db_password")))
    var s = decode_proto[Service](b.copy())
    assert_equal(s.image.value().output.value().action, "build")
    assert_equal(s.image.value().output.value().name, "api_image")
    assert_equal(Int(s.port), 8080)
    assert_equal(len(s.args), 2)
    assert_equal(s.args[0], "serve")
    assert_equal(s.args[1], "--fast")
    assert_equal(s.env["JOBS_ADDR"].ref_.value().resource, "jobs")
    assert_equal(
        s.env["JOBS_ADDR"].ref_.value().standard.value().value, Output.HOST
    )
    assert_equal(Int(s.size.value().cpu_millis), 1000)
    assert_equal(Int(s.size.value().memory_mb), 512)
    assert_equal(Int(s.scale.value().min), 1)
    assert_equal(Int(s.scale.value().max), 20)
    assert_equal(s.health_path, "/healthz")
    assert_equal(Int(s.request_timeout.value().seconds), 30)
    assert_equal(Int(s.max_concurrency), 80)
    assert_equal(s._oneof0_case, 1, "field 10 is `public`")
    assert_true(Bool(s.public), "field 10 is `public`")
    assert_equal(len(s.secret_env), 1, "field 12 is `secret_env`")
    assert_equal(s.secret_env["DB_PASSWORD"].name, "db_password")
    assert_true("DB_PASSWORD" not in s.env, "a secret is not an env value")
    _same(encode_proto(s), b, "Service (public)")

    var i = List[UInt8]()
    _uint(i, 2, 9000)
    _empty(i, 11)
    var si = decode_proto[Service](i.copy())
    assert_equal(si._oneof0_case, 2, "field 11 is `internal`")
    assert_true(Bool(si.internal), "field 11 is `internal`")
    _same(encode_proto(si), i, "Service (internal)")
    print("  test_service: PASS")


def test_job() raises:
    """Job: 1 image .. 5 timeout; 6 env, 7 secret_env; oneof { 10 on_demand,
    11 schedule }."""
    var env_ref = List[UInt8]()
    _msg(env_ref, 3, _ref_out("api", Output.URL))
    var sched = List[UInt8]()
    _str(sched, 1, "0 3 * * *")
    _str(sched, 2, "UTC")
    var b = List[UInt8]()
    _msg(b, 1, _image_digest("sha256:ab"))
    _str(b, 2, "report")
    _msg(b, 3, _size(250, 128))
    _uint(b, 4, 2)
    _msg(b, 5, _duration(900))
    _msg(b, 6, _entry("MODE", _literal("full")))
    _msg(b, 6, _entry("API_URL", env_ref))
    _msg(b, 7, _entry("API_TOKEN", _secret("api_token")))
    _msg(b, 11, sched)
    var j = decode_proto[Job](b.copy())
    assert_equal(j.image.value()._oneof0_case, 2, "Image field 2 is `digest`")
    assert_equal(j.image.value().digest.value(), "sha256:ab")
    assert_equal(j.args[0], "report")
    assert_equal(Int(j.size.value().cpu_millis), 250)
    assert_equal(Int(j.max_retries), 2)
    assert_equal(Int(j.timeout.value().seconds), 900)
    assert_equal(len(j.env), 2, "field 6 is `env`")
    assert_equal(j.env["MODE"].literal.value(), "full")
    assert_equal(j.env["API_URL"].ref_.value().resource, "api")
    assert_equal(j.env["API_URL"].ref_.value().standard.value().value, Output.URL)
    assert_equal(len(j.secret_env), 1, "field 7 is `secret_env`")
    assert_equal(j.secret_env["API_TOKEN"].name, "api_token")
    assert_equal(j._oneof0_case, 2, "field 11 is `schedule`")
    assert_equal(j.schedule.value().cron, "0 3 * * *")
    assert_equal(j.schedule.value().timezone, "UTC")
    _same(encode_proto(j), b, "Job (schedule)")

    var d = List[UInt8]()
    _str(d, 2, "once")
    _empty(d, 10)
    var jd = decode_proto[Job](d.copy())
    assert_equal(jd._oneof0_case, 1, "field 10 is `on_demand`")
    assert_true(Bool(jd.on_demand))
    _same(encode_proto(jd), d, "Job (on_demand)")
    print("  test_job: PASS")


# ---- enums ---------------------------------------------------------------------


def _enum_row(got_name: String, want_name: String, n: Int, what: String) raises:
    assert_equal(
        got_name,
        want_name,
        what + " ordinal " + String(n) + " renders its own name",
    )


def test_enum_ordinals() raises:
    """Every enum value by number AND by name: the number is what is stored.
    The held values (Output 3, 4; Access 2 to 6) render as bare numbers, i.e.
    nothing has taken them."""
    var outputs = List[String]()
    outputs.append("OUTPUT_UNSET")
    outputs.append("URL")
    outputs.append("HOST")
    for n in range(len(outputs)):
        _enum_row(Output(n).json_name(), outputs[n], n, "Output")
        assert_equal(Output.from_json_name(outputs[n]).value, n)
    for n in range(3, 5):
        assert_equal(Output(n).json_name(), String(n), "Output value held")

    var access = List[String]()
    access.append("ACCESS_UNSET")
    access.append("CALL")
    for n in range(len(access)):
        _enum_row(Access(n).json_name(), access[n], n, "Access")
        assert_equal(Access.from_json_name(access[n]).value, n)
    for n in range(2, 7):
        assert_equal(Access(n).json_name(), String(n), "Access value held")

    var port = List[String]()
    port.append("PORTABILITY_UNSET")
    port.append("PORTABLE")
    port.append("PLATFORM_BOUND")
    for n in range(len(port)):
        _enum_row(Portability(n).json_name(), port[n], n, "Portability")
        assert_equal(Portability.from_json_name(port[n]).value, n)
    assert_equal(Portability(3).json_name(), "3", "Portability has three values")

    # The artifact platform: v1 declares linux and x86_64 only.
    _enum_row(Os(0).json_name(), "OS_UNSET", 0, "Os")
    _enum_row(Os(1).json_name(), "LINUX", 1, "Os")
    assert_equal(Os.from_json_name("LINUX").value, 1)
    assert_equal(Os(2).json_name(), "2", "Os has two values in v1")
    _enum_row(Cpu(0).json_name(), "CPU_UNSET", 0, "Cpu")
    _enum_row(Cpu(1).json_name(), "X86_64", 1, "Cpu")
    assert_equal(Cpu.from_json_name("X86_64").value, 1)
    assert_equal(Cpu(2).json_name(), "2", "Cpu has two values in v1")
    print("  test_enum_ordinals: PASS")


def main() raises:
    print("test_resource_field_numbers: the kci.resource.v1 wire census")
    test_ref()
    test_uses()
    test_value_arms()
    test_image_arms()
    test_image_platform()
    test_secret_ref()
    test_added_numbers_are_kept()
    test_resource_body_arms_are_10_and_11()
    test_held_body_numbers_are_undeclared()
    test_fields_3_and_4_are_not_declared()
    test_resource_header_fields()
    test_service()
    test_job()
    test_enum_ordinals()
    print("ALL kci.resource.v1 FIELD-NUMBER TESTS PASSED")
