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
# ALSO PINNED: fourteen v1 `Resource.body` arms (10 service, 11 container
# job, 12 worker, 13 table, 14 bucket, 15 queue, 16 secret, 18 DNS zone, 20
# service account, 21 topic, 25 grant, 26 DNS record, 27 certificate, 28
# subscription; 22 to 24 and 29 to 31 have pins files of their own) by
# number AND by which field each fills; the retired field 4 is ignored; and
# every enum's ordinals in both directions, held values undeclared. EVERY
# HELD NUMBER (each number of each held range of each message) is pinned as
# undeclared by one table in test_resource_held_numbers.mojo.
#
# THE FIELDS ADDED AFTER THE FIRST DRAFT, each pinned the same two ways:
# `Image.platform` 3 (an OCI-style string), `SecretRef` 1 name, 2 store and
# 3 version, `Service.secret_env` 12, `ContainerJob.env` 6 and
# `ContainerJob.secret_env` 7. And
# `test_added_numbers_are_kept` restates them with decode and encode ONLY, so
# it compiles against a schema without them and fails there at run time: a
# number the schema does not declare is dropped on re-encode, and a number
# whose wire shape changed does not decode to the same bytes.
#
# RENAMED, NUMBERS KEPT: `StepOutput { step = 1, name = 2 }` (was
# `ActionOutput { action, name }`) and `Portability.CLOUD_BOUND = 2` (was
# `PLATFORM_BOUND`). PRESENCE: `Scale.min`, `ContainerJob.max_retries`,
# `SecretRef.store` and `SecretRef.version` tell "not written" from zero.
#
# THE BUCKET AND RETENTION: `Resource.retention` 3 (was held), the `bucket`
# arm 14, `Bucket` 1 object_expiry_days (presence), 2 versioning and 3 tier;
# `Retention` DELETE 1 and KEEP 2; `StorageTier` STANDARD 1, INFREQUENT 2 and
# ARCHIVE 3; `Output` ADDRESS 3 and NAME 4; `Access` READ 2, WRITE 3 and
# READ_WRITE 4. Each by wire bytes and by name, and restated in
# `test_added_numbers_are_kept`.
#
# IDENTITY AND GRANTS: the `service_account` arm 20 and the `grant` arm 25;
# `Grant` 1 principal, 2 target, 3 access and 4 cell; `Uses.cell` 4 (3 stays
# held); `Service.run_as` 14 and `ContainerJob.run_as` 13; `Access`
# DESCRIBE 8 (7 ACT_AS and 9 MANAGE stay held); `CellResource` LOGS 1,
# METRICS 2 and ARTIFACTS 3 (4 stays held). The per-cloud extensions are four numbers,
# 50 to 53, held on every primitive message, and the provider-primitive
# ranges are four, 100-299, 300-499, 500-699 and 700-899.
#
# THE TABLE: the `table` arm 13; `Table` 1 key, 2 indexes (repeated) and 3
# ttl_field (presence; 4 held); `Table.AccessPath` 1 name, 2 partition and 3
# order; `Table.Field` 1 name and 2 type; `FieldType` STRING 1, NUMBER 2 and
# BYTES 3. Each by wire bytes and by name, and restated in
# `test_added_numbers_are_kept`.
#
# MESSAGING: the `queue` arm 15, the `topic` arm 21 and the `subscription`
# arm 28 (by number and by the field each fills, here, and restated in
# `test_added_numbers_are_kept`); `Access` SEND 5 and RECEIVE 6 (in
# `test_enum_ordinals`, and restated). `Queue`, `Topic` and `Subscription`
# field by field are in test_resource_messaging_numbers.mojo, `Secret` and
# `SecretRef.secret` 4 in test_resource_secret_numbers.mojo, and `DnsZone`,
# `DnsRecord`, `Certificate` and `RecordType` in
# test_resource_dns_numbers.mojo, and `ContainerJob` (was `Job`), `Worker`,
# the `command` fields, `Size.gpus` and the census of every arm's oneof
# position in test_resource_compute_numbers.mojo (this file is past the size
# a Mojo source should stay under).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_proto, encode_proto
from kci_resource_proto.resource import (
    Access,
    Bucket,
    CellResource,
    FieldType,
    Grant,
    ContainerJob,
    Image,
    Output,
    Portability,
    Ref,
    Resource,
    ResourceList,
    Retention,
    Scale,
    SecretRef,
    Service,
    ServiceAccount,
    StepOutput,
    StorageTier,
    Table,
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


def _step_output(step: String, name: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, step)
    _str(b, 2, name)
    return b^


def _image_from_step(step: String, name: String) -> List[UInt8]:
    var b = List[UInt8]()
    _msg(b, 1, _step_output(step, name))
    return b^


def _image_digest(digest: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 2, digest)
    return b^


def _secret(name: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, name)
    return b^


def _secret_pinned(name: String, store: String, version: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, name)
    _str(b, 2, store)
    _str(b, 3, version)
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
    """Uses: 1 target, 2 access, 4 cell; 3 held."""
    var b = List[UInt8]()
    _msg(b, 1, _ref("billing"))
    _uint(b, 2, UInt64(Access.CALL))
    var u = decode_proto[Uses](b.copy())
    assert_equal(u.target.value().resource, "billing")
    assert_equal(u.access.value, Access.CALL)
    assert_equal(u.cell.value, CellResource.CELL_RESOURCE_UNSET, "absent = unset")
    _same(encode_proto(u), b, "Uses")

    var c = List[UInt8]()
    _uint(c, 2, UInt64(Access.WRITE))
    _uint(c, 4, UInt64(CellResource.METRICS))
    var uc = decode_proto[Uses](c.copy())
    assert_true(not Bool(uc.target), "a cell line has no target")
    assert_equal(uc.cell.value, CellResource.METRICS, "Uses field 4 is `cell`")
    assert_equal(uc.access.value, Access.WRITE)
    _same(encode_proto(uc), c, "Uses.cell")

    # 3 is held. A NON-EMPTY payload: an empty one would decode as a declared
    # field's zero value and re-encode to nothing, hiding it.
    var h = b.copy()
    _str(h, 3, "x")
    _same(encode_proto(decode_proto[Uses](h.copy())), b, "Uses 3 is held")
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
    """Image: oneof source { 1 output, 2 digest }. StepOutput: 1 step,
    2 name."""
    var o = List[UInt8]()
    _msg(o, 1, _step_output("build", "docs_bundle"))
    var c = decode_proto[Image](o.copy())
    assert_equal(c._oneof0_case, 1)
    assert_equal(c.output.value().step, "build", "StepOutput field 1 is `step`")
    assert_equal(c.output.value().name, "docs_bundle")
    _same(encode_proto(c), o, "Image.output")

    var d = List[UInt8]()
    _str(d, 2, "sha256:cd")
    var cd = decode_proto[Image](d.copy())
    assert_equal(cd._oneof0_case, 2)
    assert_equal(cd.digest.value(), "sha256:cd")
    _same(encode_proto(cd), d, "Image.digest")

    # No platform: the field is empty (a reader takes the v1 default,
    # linux/amd64).
    assert_equal(cd.platform, "", "Image.platform is empty when not written")

    var so = decode_proto[StepOutput](_step_output("images", "api_image"))
    assert_equal(so.step, "images")
    assert_equal(so.name, "api_image", "StepOutput field 2 is `name`")
    print("  test_image_arms: PASS")


def test_image_platform() raises:
    """Image: 3 platform, an OCI-style string, beside either source arm."""
    var o = List[UInt8]()
    _msg(o, 1, _step_output("build", "api_image"))
    _str(o, 3, "linux/amd64")
    var io = decode_proto[Image](o.copy())
    assert_equal(io._oneof0_case, 1, "platform does not touch the source arm")
    assert_equal(io.output.value().name, "api_image")
    assert_equal(io.platform, "linux/amd64", "Image field 3 is `platform`")
    _same(encode_proto(io), o, "Image.output + platform")

    var d = List[UInt8]()
    _str(d, 2, "sha256:ef")
    _str(d, 3, "linux/amd64")
    var idg = decode_proto[Image](d.copy())
    assert_equal(idg._oneof0_case, 2)
    assert_equal(idg.digest.value(), "sha256:ef")
    assert_equal(idg.platform, "linux/amd64")
    _same(encode_proto(idg), d, "Image.digest + platform")

    # A platform this kci does not accept still decodes, verbatim: the schema
    # cannot refuse it, the validate phase does (linux/amd64 only in v1).
    var other = List[UInt8]()
    _str(other, 2, "sha256:12")
    _str(other, 3, "darwin/arm64")
    var io2 = decode_proto[Image](other.copy())
    assert_equal(io2.platform, "darwin/arm64")
    _same(encode_proto(io2), other, "Image.platform other value")
    print("  test_image_platform: PASS")


def test_secret_ref() raises:
    """SecretRef: 1 name, 2 store, 3 version; store and version have
    presence. A reference, never a value."""
    var b = _secret_pinned("db_password", "default", "7")
    var s = decode_proto[SecretRef](b.copy())
    assert_equal(s.name, "db_password", "SecretRef field 1 is `name`")
    assert_equal(s.store.value(), "default", "SecretRef field 2 is `store`")
    assert_equal(s.version.value(), "7", "SecretRef field 3 is `version`")
    _same(encode_proto(s), b, "SecretRef")

    # Not written: absent. Written empty: present and empty.
    var bare = decode_proto[SecretRef](_secret("db_password"))
    assert_true(not Bool(bare.store), "an unwritten store is absent")
    assert_true(not Bool(bare.version), "an unwritten version is absent")
    var e = List[UInt8]()
    _str(e, 1, "db_password")
    _str(e, 3, "")
    var se = decode_proto[SecretRef](e.copy())
    assert_true(Bool(se.version), "a version written empty is present")
    assert_equal(se.version.value(), "")
    assert_true(not Bool(se.store))

    var held = _secret("db_password")
    _str(held, 5, "not-a-field")  # 4 is `secret` (test_resource_secret_numbers)
    var sh = decode_proto[SecretRef](held.copy())
    _same(encode_proto(sh), _secret("db_password"), "SecretRef has no field 5")
    print("  test_secret_ref: PASS")


def test_added_numbers_are_kept() raises:
    """Decode and encode only, nothing read by name: every number added after
    the first draft must survive a round trip. Against a schema that lacks one
    it is unknown, dropped on re-encode, and this fails."""
    var img = List[UInt8]()
    _str(img, 2, "sha256:01")
    _str(img, 3, "linux/amd64")
    _same(encode_proto(decode_proto[Image](img.copy())), img, "Image 3")

    var sec = _secret_pinned("db_password", "default", "3")
    _same(
        encode_proto(decode_proto[SecretRef](sec.copy())), sec, "SecretRef 2 and 3"
    )

    var svc = List[UInt8]()
    _uint(svc, 2, 8080)
    _msg(svc, 12, _entry("DB_PASSWORD", _secret("db_password")))
    _same(encode_proto(decode_proto[Service](svc.copy())), svc, "Service 12")

    var job = List[UInt8]()
    _str(job, 2, "report")
    _msg(job, 6, _entry("MODE", _literal("full")))
    _msg(job, 7, _entry("API_TOKEN", _secret("api_token")))
    _same(encode_proto(decode_proto[ContainerJob](job.copy())), job, "ContainerJob 6 and 7")

    # The bucket and retention: Resource 3 and 14, Bucket 1 to 3.
    var bkt = List[UInt8]()
    _uint(bkt, 1, 30)
    _uint(bkt, 2, 1)
    _uint(bkt, 3, 3)
    _same(encode_proto(decode_proto[Bucket](bkt.copy())), bkt, "Bucket 1 to 3")
    var res = List[UInt8]()
    _str(res, 1, "store")
    _uint(res, 3, 2)
    _msg(res, 14, bkt)
    _same(
        encode_proto(decode_proto[Resource](res.copy())), res, "Resource 3 and 14"
    )

    # Identity and grants: Service 14, ContainerJob 13, Uses 4, Grant 1 to 4,
    # Resource 20 and 25, Access 8.
    var svc_as = List[UInt8]()
    _uint(svc_as, 2, 8080)
    _msg(svc_as, 14, _ref("runner"))
    _same(encode_proto(decode_proto[Service](svc_as.copy())), svc_as, "Service 14")
    var job_as = List[UInt8]()
    _str(job_as, 2, "report")
    _msg(job_as, 13, _ref("runner"))
    _same(encode_proto(decode_proto[ContainerJob](job_as.copy())), job_as, "ContainerJob 13")
    var use_cell = List[UInt8]()
    _uint(use_cell, 2, 3)
    _uint(use_cell, 4, 1)
    _same(encode_proto(decode_proto[Uses](use_cell.copy())), use_cell, "Uses 4")
    var grant = List[UInt8]()
    _msg(grant, 1, _ref("runner"))
    _msg(grant, 2, _ref("store"))
    _uint(grant, 3, 8)
    _uint(grant, 4, 2)
    _same(encode_proto(decode_proto[Grant](grant.copy())), grant, "Grant 1 to 4")
    var acct = List[UInt8]()
    _str(acct, 1, "runner")
    _empty(acct, 20)
    _same(encode_proto(decode_proto[Resource](acct.copy())), acct, "Resource 20")
    var gres = List[UInt8]()
    _str(gres, 1, "see")
    _msg(gres, 25, grant)
    _same(encode_proto(decode_proto[Resource](gres.copy())), gres, "Resource 25")

    # The table: Resource 13, Table 1 to 3, AccessPath 1 to 3, Field 1 and 2.
    var tbl = _table()
    _same(encode_proto(decode_proto[Table](tbl.copy())), tbl, "Table 1 to 3")
    var tres = List[UInt8]()
    _str(tres, 1, "orders")
    _msg(tres, 13, tbl)
    _same(encode_proto(decode_proto[Resource](tres.copy())), tres, "Resource 13")

    # Messaging: Resource 15 (a queue, max_deliveries 3: 5), 21 (a topic) and
    # 28 (a subscription: topic 1, queue 2); Access 5 and 6 on a Uses line.
    var bodies = List[List[UInt8]]()
    bodies.append(List[UInt8]())
    _uint(bodies[0], 3, 5)
    bodies.append(List[UInt8]())
    bodies.append(List[UInt8]())
    _msg(bodies[2], 1, _ref("events"))
    _msg(bodies[2], 2, _ref("work"))
    var arms = [15, 21, 28]
    for i in range(3):
        var mres = List[UInt8]()
        _str(mres, 1, "m")
        _msg(mres, arms[i], bodies[i])
        var what = String("Resource ") + String(arms[i])
        var back = encode_proto(decode_proto[Resource](mres.copy()))
        _same(back, mres, what)
        # The topic arm is an EMPTY record, which `_same` drops as a zero
        # value: its tag and zero length must be in the re-encoding.
        var arm = List[UInt8]()
        _empty(arm, arms[i])
        var found = False
        for at in range(len(back) - 2):
            if back[at] == arm[0] and back[at + 1] == arm[1] and back[at + 2] == arm[2]:
                found = True
        assert_true(i != 1 or found, what + ": the empty topic arm was dropped")
    for verb in range(5, 7):
        var mu = List[UInt8]()
        _msg(mu, 1, _ref("work"))
        _uint(mu, 2, UInt64(verb))
        _same(encode_proto(decode_proto[Uses](mu.copy())), mu, String("Access ") + String(verb))
    print("  test_added_numbers_are_kept: PASS")


# ---- Resource and its body arms --------------------------------------------------


def _arm_of(r: Resource) -> String:
    """Which body field is filled, by name; "" if none."""
    if r.service:
        return "service"
    if r.container_job:
        return "container_job"
    if r.worker:
        return "worker"
    if r.table:
        return "table"
    if r.bucket:
        return "bucket"
    if r.queue:
        return "queue"
    if r.secret:
        return "secret"
    if r.dns_zone:
        return "dns_zone"
    if r.service_account:
        return "service_account"
    if r.topic:
        return "topic"
    if r.grant:
        return "grant"
    if r.dns_record:
        return "dns_record"
    if r.certificate:
        return "certificate"
    if r.subscription:
        return "subscription"
    return ""


def test_resource_body_arms() raises:
    """Each v1 body arm, by number AND by the field it fills.

    The arm numbers are the adapter registry's key (one adapter per arm), so a
    renumber would hand a resource to another type's adapter.
    """
    var names: List[String] = ["service", "container_job", "worker", "table", "bucket", "queue", "secret"]
    names.extend(["dns_zone", "service_account", "topic", "grant", "dns_record", "certificate", "subscription"])
    var fields: List[Int] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 21, 25, 26, 27, 28]
    for i in range(len(names)):
        var field = fields[i]
        var b = List[UInt8]()
        _str(b, 1, "r")
        _empty(b, field)
        var r = decode_proto[Resource](b.copy())
        assert_equal(
            _arm_of(r),
            names[i],
            String("Resource.body field ") + String(field) + " fills",
        )
        assert_equal(r._oneof0_case, i + 1 if field < 22 else i + 4, "the arm index follows the number (22 to 24 before 25)")
        _same(
            encode_proto(r),
            b,
            String("Resource.body field ") + String(field),
        )
    print("  test_resource_body_arms: PASS")


def test_field_3_is_retention_and_4_is_retired() raises:
    """3 is `retention` (a `Retention` enum value); 4 (a retired stage filter)
    is reserved and decodes as unknown: skipped, dropped on re-encode."""
    var head = List[UInt8]()
    _str(head, 1, "r")
    var b = head.copy()
    _uint(b, 3, UInt64(Retention.KEEP))
    var r = decode_proto[Resource](b.copy())
    assert_equal(r.retention.value, Retention.KEEP, "Resource field 3 is `retention`")
    assert_equal(_arm_of(r), "")
    _same(encode_proto(r), b, "Resource.retention")

    var d = head.copy()
    _uint(d, 3, UInt64(Retention.DELETE))
    assert_equal(
        decode_proto[Resource](d.copy()).retention.value,
        Retention.DELETE,
        "DELETE is 1",
    )

    var unset = decode_proto[Resource](head.copy())
    assert_equal(unset.retention.value, Retention.RETENTION_UNSET, "absent = unset")

    var retired = head.copy()
    _uint(retired, 4, 1)
    _same(encode_proto(decode_proto[Resource](retired.copy())), head, "field 4 is unknown")
    print("  test_field_3_is_retention_and_4_is_retired: PASS")


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


# ---- compute: the service (the container job and the worker are in
# test_resource_compute_numbers.mojo) ----------------------------------------------


def test_service() raises:
    """Service: 1 image .. 9 max_concurrency; oneof { 10 public, 11 internal };
    12 secret_env."""
    var env_value = List[UInt8]()
    _msg(env_value, 3, _ref_out("jobs", Output.HOST))
    var env_entry = List[UInt8]()
    _str(env_entry, 1, "JOBS_ADDR")
    _msg(env_entry, 2, env_value)

    var b = List[UInt8]()
    _msg(b, 1, _image_from_step("build", "api_image"))
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
    _msg(b, 14, _ref("runner"))
    var s = decode_proto[Service](b.copy())
    assert_equal(s.image.value().output.value().step, "build")
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
    assert_equal(Int(s.scale.value().min.value()), 1)
    assert_equal(Int(s.scale.value().max), 20)
    assert_equal(s.health_path, "/healthz")
    assert_equal(Int(s.request_timeout.value().seconds), 30)
    assert_equal(Int(s.max_concurrency), 80)
    assert_equal(s._oneof0_case, 1, "field 10 is `public`")
    assert_true(Bool(s.public), "field 10 is `public`")
    assert_equal(len(s.secret_env), 1, "field 12 is `secret_env`")
    assert_equal(s.secret_env["DB_PASSWORD"].name, "db_password")
    assert_true("DB_PASSWORD" not in s.env, "a secret is not an env value")
    assert_equal(s.run_as.value().resource, "runner", "field 14 is `run_as`")
    _same(encode_proto(s), b, "Service (public)")

    var i = List[UInt8]()
    _uint(i, 2, 9000)
    _empty(i, 11)
    var si = decode_proto[Service](i.copy())
    assert_equal(si._oneof0_case, 2, "field 11 is `internal`")
    assert_true(Bool(si.internal), "field 11 is `internal`")
    _same(encode_proto(si), i, "Service (internal)")
    print("  test_service: PASS")


def test_scale_min_has_presence() raises:
    """Scale: 1 min (presence), 2 max. An explicit `min: 0` (scale to zero)
    is a value; a Scale with no `min` written has none."""
    var zero = List[UInt8]()
    _uint(zero, 1, 0)
    _uint(zero, 2, 5)
    var z = decode_proto[Scale](zero.copy())
    assert_true(Bool(z.min), "an explicit min of 0 is present")
    assert_equal(Int(z.min.value()), 0)
    assert_equal(Int(z.max), 5, "Scale field 2 is `max`")

    var only_max = List[UInt8]()
    _uint(only_max, 2, 5)
    var m = decode_proto[Scale](only_max.copy())
    assert_true(not Bool(m.min), "an unwritten min is absent")
    _same(encode_proto(m), only_max, "Scale without min")
    print("  test_scale_min_has_presence: PASS")


# ---- data: bucket -----------------------------------------------------------------


def test_bucket() raises:
    """Bucket: 1 object_expiry_days (presence), 2 versioning, 3 tier; as the
    `bucket` arm 14 of a Resource with retention 3."""
    var b = List[UInt8]()
    _uint(b, 1, 30)
    _uint(b, 2, 1)
    _uint(b, 3, UInt64(StorageTier.ARCHIVE))
    var k = decode_proto[Bucket](b.copy())
    assert_equal(Int(k.object_expiry_days.value()), 30, "field 1 is `object_expiry_days`")
    assert_true(k.versioning, "field 2 is `versioning`")
    assert_equal(k.tier.value, StorageTier.ARCHIVE, "field 3 is `tier`")
    _same(encode_proto(k), b, "Bucket")

    # Presence: an explicit 0 is a value (refused at validate, never here);
    # an unwritten expiry is absent (never expire).
    var zero = List[UInt8]()
    _uint(zero, 1, 0)
    var kz = decode_proto[Bucket](zero.copy())
    assert_true(Bool(kz.object_expiry_days), "an explicit expiry of 0 is present")
    assert_equal(Int(kz.object_expiry_days.value()), 0)
    var none = decode_proto[Bucket](List[UInt8]())
    assert_true(not Bool(none.object_expiry_days), "an unwritten expiry is absent")
    assert_equal(none.tier.value, StorageTier.STORAGE_TIER_UNSET)

    var r = List[UInt8]()
    _str(r, 1, "store")
    _uint(r, 3, UInt64(Retention.DELETE))
    _msg(r, 14, b)
    var rr = decode_proto[Resource](r.copy())
    assert_equal(_arm_of(rr), "bucket", "body 14 is `bucket`")
    assert_equal(rr._oneof0_case, 5, "the bucket is the fifth arm")
    assert_equal(rr.retention.value, Retention.DELETE)
    assert_equal(Int(rr.bucket.value().object_expiry_days.value()), 30)
    _same(encode_proto(rr), r, "Resource with a bucket")
    print("  test_bucket: PASS")


def test_new_ref_outputs_and_accesses() raises:
    """A Ref to a bucket's NAME and ADDRESS, and a Uses line with each of
    READ, WRITE and READ_WRITE, by wire bytes."""
    var n = _ref_out("store", Output.NAME)
    var rn = decode_proto[Ref](n.copy())
    assert_equal(rn.standard.value().value, Output.NAME, "NAME is 4")
    _same(encode_proto(rn), n, "Ref NAME")
    var a = _ref_out("store", Output.ADDRESS)
    var ra = decode_proto[Ref](a.copy())
    assert_equal(ra.standard.value().value, Output.ADDRESS, "ADDRESS is 3")
    _same(encode_proto(ra), a, "Ref ADDRESS")

    var verbs = List[Int]()
    verbs.append(Access.READ)
    verbs.append(Access.WRITE)
    verbs.append(Access.READ_WRITE)
    for i in range(len(verbs)):
        var u = List[UInt8]()
        _msg(u, 1, _ref("store"))
        _uint(u, 2, UInt64(verbs[i]))
        var d = decode_proto[Uses](u.copy())
        assert_equal(d.access.value, verbs[i])
        assert_equal(d.access.value, i + 2, "READ, WRITE, READ_WRITE are 2, 3, 4")
        _same(encode_proto(d), u, String("Uses access ") + String(verbs[i]))
    print("  test_new_ref_outputs_and_accesses: PASS")


# ---- identity: service account and grant -------------------------------------------


def test_service_account_and_grant() raises:
    """ServiceAccount: no field. Grant: 1 principal, 2 target, 3 access,
    4 cell. As the `service_account` arm 20 and the `grant` arm 25 of a
    Resource."""
    var a = List[UInt8]()
    _str(a, 1, "runner")
    _empty(a, 20)
    var ra = decode_proto[Resource](a.copy())
    assert_equal(_arm_of(ra), "service_account", "body 20 is `service_account`")
    assert_equal(ra._oneof0_case, 9, "the service account is the ninth arm")
    _same(encode_proto(ra), a, "Resource with a service account")

    var g = List[UInt8]()
    _msg(g, 1, _ref("runner"))
    _msg(g, 2, _ref("store"))
    _uint(g, 3, UInt64(Access.READ_WRITE))
    var d = decode_proto[Grant](g.copy())
    assert_equal(d.principal.value().resource, "runner", "field 1 is `principal`")
    assert_equal(d.target.value().resource, "store", "field 2 is `target`")
    assert_equal(d.access.value, Access.READ_WRITE, "field 3 is `access`")
    assert_equal(d.cell.value, CellResource.CELL_RESOURCE_UNSET, "absent = unset")
    _same(encode_proto(d), g, "Grant (target)")

    var c = List[UInt8]()
    _msg(c, 1, _ref("runner"))
    _uint(c, 3, UInt64(Access.WRITE))
    _uint(c, 4, UInt64(CellResource.LOGS))
    var dc = decode_proto[Grant](c.copy())
    assert_true(not Bool(dc.target), "a cell grant has no target")
    assert_equal(dc.cell.value, CellResource.LOGS, "field 4 is `cell`")
    _same(encode_proto(dc), c, "Grant (cell)")

    var r = List[UInt8]()
    _str(r, 1, "see")
    _msg(r, 25, g)
    var rr = decode_proto[Resource](r.copy())
    assert_equal(_arm_of(rr), "grant", "body 25 is `grant`")
    assert_equal(rr._oneof0_case, 14, "the grant is the fourteenth arm")
    assert_equal(rr.grant.value().principal.value().resource, "runner")
    _same(encode_proto(rr), r, "Resource with a grant")

    var desc = List[UInt8]()
    _msg(desc, 1, _ref("runner"))
    _uint(desc, 2, UInt64(Access.DESCRIBE))
    var dd = decode_proto[Uses](desc.copy())
    assert_equal(dd.access.value, 8, "DESCRIBE is 8")
    _same(encode_proto(dd), desc, "Uses DESCRIBE")
    print("  test_service_account_and_grant: PASS")


# ---- data: table -------------------------------------------------------------------


def _field(name: String, ftype: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, name)
    _uint(b, 2, UInt64(ftype))
    return b^


def _path(name: String, partition: List[UInt8], order: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, name)
    _msg(b, 2, partition)
    if len(order) > 0:
        _msg(b, 3, order)
    return b^


def _table() -> List[UInt8]:
    """A key (customer STRING, placed NUMBER), two indexes and a TTL."""
    var b = List[UInt8]()
    _msg(
        b,
        1,
        _path("by-customer", _field("customer", FieldType.STRING), _field("placed", FieldType.NUMBER)),
    )
    _msg(b, 2, _path("by-sku", _field("sku", FieldType.BYTES), List[UInt8]()))
    _msg(b, 2, _path("by-state", _field("state", FieldType.STRING), _field("placed", FieldType.NUMBER)))
    _str(b, 3, "expires")
    return b^


def test_table() raises:
    """Table: 1 key, 2 indexes (repeated), 3 ttl_field (presence).
    AccessPath: 1 name, 2 partition, 3 order. Field: 1 name, 2 type. As the
    `table` arm 13 of a Resource with retention 3."""
    var b = _table()
    var t = decode_proto[Table](b.copy())
    ref key = t.key.value()
    assert_equal(key.name, "by-customer", "AccessPath field 1 is `name`")
    assert_equal(key.partition.value().name, "customer", "AccessPath 2 is `partition`, Field 1 `name`")
    assert_equal(key.partition.value().type.value, FieldType.STRING, "Field 2 is `type`")
    assert_equal(key.order.value().name, "placed", "AccessPath 3 is `order`")
    assert_equal(key.order.value().type.value, FieldType.NUMBER)
    assert_equal(len(t.indexes), 2, "Table field 2 is `indexes`, repeated, in order")
    assert_equal(t.indexes[0].name, "by-sku")
    assert_equal(t.indexes[0].partition.value().type.value, FieldType.BYTES)
    assert_true(not Bool(t.indexes[0].order), "an index with no order has none")
    assert_equal(t.indexes[1].name, "by-state")
    assert_equal(t.ttl_field.value(), "expires", "Table field 3 is `ttl_field`")
    _same(encode_proto(t), b, "Table")

    # Presence: an unwritten TTL is absent (items never expire).
    var none = decode_proto[Table](List[UInt8]())
    assert_true(not Bool(none.ttl_field), "an unwritten ttl_field is absent")
    assert_true(not Bool(none.key), "an unwritten key is absent")

    var r = List[UInt8]()
    _str(r, 1, "orders")
    _uint(r, 3, UInt64(Retention.KEEP))
    _msg(r, 13, b)
    var rr = decode_proto[Resource](r.copy())
    assert_equal(_arm_of(rr), "table", "body 13 is `table`")
    assert_equal(rr._oneof0_case, 4, "the table is the fourth arm")
    assert_equal(rr.retention.value, Retention.KEEP)
    assert_equal(rr.table.value().ttl_field.value(), "expires")
    _same(encode_proto(rr), r, "Resource with a table")
    print("  test_table: PASS")


# ---- enums ---------------------------------------------------------------------


def _enum_row(got_name: String, want_name: String, n: Int, what: String) raises:
    assert_equal(
        got_name,
        want_name,
        what + " ordinal " + String(n) + " renders its own name",
    )


def test_enum_ordinals() raises:
    """Every enum value by number AND by name: the number is what is stored.
    The held values (Output 5; Access 7 and 9; CellResource 4) render as bare
    numbers, i.e. nothing has taken them."""
    var outputs = List[String]()
    outputs.append("OUTPUT_UNSET")
    outputs.append("URL")
    outputs.append("HOST")
    outputs.append("ADDRESS")
    outputs.append("NAME")
    for n in range(len(outputs)):
        _enum_row(Output(n).json_name(), outputs[n], n, "Output")
        assert_equal(Output.from_json_name(outputs[n]).value, n)
    assert_equal(Output(5).json_name(), "5", "Output 5 (REVISION) is held")

    var access = List[String]()
    access.append("ACCESS_UNSET")
    access.append("CALL")
    access.append("READ")
    access.append("WRITE")
    access.append("READ_WRITE")
    access.append("SEND")
    access.append("RECEIVE")
    for n in range(len(access)):
        _enum_row(Access(n).json_name(), access[n], n, "Access")
        assert_equal(Access.from_json_name(access[n]).value, n)
    _enum_row(Access(8).json_name(), "DESCRIBE", 8, "Access")
    assert_equal(Access.from_json_name("DESCRIBE").value, 8)
    # 7 ACT_AS, 9 MANAGE: held.
    for n in range(7, 11):
        if n == 8:
            continue
        assert_equal(Access(n).json_name(), String(n), "Access value held")
    assert_true(not Access.is_known_json_name("ACT_AS"), "ACT_AS is not declared")
    assert_true(not Access.is_known_json_name("MANAGE"), "MANAGE is not declared")

    var cells = List[String]()
    cells.append("CELL_RESOURCE_UNSET")
    cells.append("LOGS")
    cells.append("METRICS")
    cells.append("ARTIFACTS")
    for n in range(len(cells)):
        _enum_row(CellResource(n).json_name(), cells[n], n, "CellResource")
        assert_equal(CellResource.from_json_name(cells[n]).value, n)
    assert_equal(CellResource(4).json_name(), "4", "CellResource 4 (COMPUTE) is held")
    assert_true(not CellResource.is_known_json_name("COMPUTE"), "COMPUTE is not declared")

    var retention = List[String]()
    retention.append("RETENTION_UNSET")
    retention.append("DELETE")
    retention.append("KEEP")
    for n in range(len(retention)):
        _enum_row(Retention(n).json_name(), retention[n], n, "Retention")
        assert_equal(Retention.from_json_name(retention[n]).value, n)
    assert_equal(Retention(3).json_name(), "3", "Retention has three values")

    var tiers = List[String]()
    tiers.append("STORAGE_TIER_UNSET")
    tiers.append("STANDARD")
    tiers.append("INFREQUENT")
    tiers.append("ARCHIVE")
    for n in range(len(tiers)):
        _enum_row(StorageTier(n).json_name(), tiers[n], n, "StorageTier")
        assert_equal(StorageTier.from_json_name(tiers[n]).value, n)
    assert_equal(StorageTier(4).json_name(), "4", "StorageTier has four values")

    var port = List[String]()
    port.append("PORTABILITY_UNSET")
    port.append("PORTABLE")
    port.append("CLOUD_BOUND")
    for n in range(len(port)):
        _enum_row(Portability(n).json_name(), port[n], n, "Portability")
        assert_equal(Portability.from_json_name(port[n]).value, n)
    assert_equal(Portability(3).json_name(), "3", "Portability has three values")

    var ftypes = List[String]()
    ftypes.append("FIELD_TYPE_UNSET")
    ftypes.append("STRING")
    ftypes.append("NUMBER")
    ftypes.append("BYTES")
    for n in range(len(ftypes)):
        _enum_row(FieldType(n).json_name(), ftypes[n], n, "FieldType")
        assert_equal(FieldType.from_json_name(ftypes[n]).value, n)
    assert_equal(FieldType(4).json_name(), "4", "FieldType has four values")

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
    test_resource_body_arms()
    test_field_3_is_retention_and_4_is_retired()
    test_resource_header_fields()
    test_service()
    test_scale_min_has_presence()
    test_table()
    test_bucket()
    test_service_account_and_grant()
    test_new_ref_outputs_and_accesses()
    test_enum_ordinals()
    print("ALL kci.resource.v1 FIELD-NUMBER TESTS PASSED")
