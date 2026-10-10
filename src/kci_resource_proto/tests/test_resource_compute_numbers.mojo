# =============================================================================
# test_resource_compute_numbers.mojo
# =============================================================================
#
# THE COMPUTE PRIMITIVES OF `kci.resource.v1`, AS WIRE BYTES: the
# `container_job` arm 11 (was `job`), the `worker` arm 12, `Service.command`
# 15 and `Size.gpus` 3. The field template of
# test_resource_field_numbers.mojo, in a file of its own (that file is past
# the size a Mojo source should stay under).
#
# 1. KEPT, BY BYTES ONLY. Nothing is read by name: `Resource` 12 holding a
#    worker with every field, `Resource` 11 holding a container job with its
#    `command` 9 and a `Size` with `gpus` 3, `Service` 15 and `Size` 3
#    survive decode then encode; and a container job written WITH the
#    trigger it used to have (11, a schedule) decodes without it. Every
#    failure is collected, so one run names every number that is missing.
# 2. CONTAINERJOB. 1 image, 2 args, 3 size, 4 max_retries (presence), 5
#    timeout, 6 env, 7 secret_env, 9 command (repeated, in order), 13
#    run_as; by name, binary, JSON, absent = unset; 12 is not a field; 10
#    and 11 (the trigger) are reserved: their bytes are skipped and their
#    JSON keys (`onDemand`, `schedule`) are REFUSED, never dropped; as
#    `Resource.body` 11, the second arm, under the JSON name
#    `containerJob`, and the old arm name `job` is refused.
# 3. WORKER. 1 image, 2 size, 4 args, 5 command, 6 env, 7 secret_env, 8
#    replicas (presence), 9 run_as; by name, binary, JSON, absent = unset;
#    3, 10 and 11 (a draft's scale and source) are reserved, their bytes
#    skipped; 13 is not a field; as `Resource.body` 12, the third arm.
# 4. SERVICE.COMMAND 15 (repeated, in order); by name, binary, JSON; 17 is
#    not a field (16 is `network`, test_resource_network_numbers.mojo).
# 5. SIZE. 1 cpu_millis, 2 memory_mb, 3 gpus; by name, binary, JSON, absent
#    = 0; 4 is not a field.
# 6. THE ARM CENSUS. Every declared `Resource.body` arm, by number and by
#    the oneof position the generated struct records: 10 service 1, 11
#    container job 2, 12 worker 3, 13 table 4, 14 bucket 5, 15 queue 6, 16
#    secret 7, 18 DNS zone 8, 20 service account 9, 21 topic 10, 22
#    schedule 11, 23 network 12, 24 registry 13, 25 grant 14, 26 DNS record
#    15, 27 certificate 16, 28 subscription 17, 29 subnet 18, 30 IP address
#    19, 31 event trigger 20, 80 composite instance 21. A position that
#    moves is a different arm to every reader of `_oneof0_case` (kci_cloud's
#    `body_arms`). 17, 19, 32, 33 and 90 stay held.
# The bytes are a LITERAL restatement of the proto, deliberately: deriving
# them from the generated code would agree with it by construction.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from kci_resource_proto.compute import ContainerJob, Service, Size, Worker
from kci_resource_proto.resource import Resource


# ---- a hand-written wire stream (as in test_resource_field_numbers) -------------

comptime _VARINT = 0
comptime _LEN = 2


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    _varint(b, UInt64((field << 3) | _VARINT))
    _varint(b, v)


def _str(mut b: List[UInt8], field: Int, s: String):
    _varint(b, UInt64((field << 3) | _LEN))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    _varint(b, UInt64((field << 3) | _LEN))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _ref(resource: String) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, resource)
    return b^


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4 : (v >> 4) + 1])
        out += String(digits[byte = v & 15 : (v & 15) + 1])
    return out^


def _read_varint(b: List[UInt8], mut pos: Int, mut ok: Bool) -> UInt64:
    var v: UInt64 = 0
    var shift = 0
    while pos < len(b) and shift < 64:
        var c = b[pos]
        pos += 1
        v |= UInt64(c & 0x7F) << UInt64(shift)
        if c < 0x80:
            return v
        shift += 7
    ok = False
    return 0


def _canon(b: List[UInt8], mut out: List[UInt8]) -> Bool:
    """`b` with every zero-valued record dropped, recursively, and its records
    sorted stably by field number (this codec writes zero values and writes
    plain fields before oneof fields; neither is the catalog's business).
    False when `b` does not parse as a message (varint and length-delimited
    records only: no field here is fixed-width)."""
    var fields = List[Int]()
    var records = List[List[UInt8]]()
    var pos = 0
    var ok = True
    while pos < len(b):
        var tag = _read_varint(b, pos, ok)
        if not ok or (tag >> 3) == 0:
            return False
        var rec = List[UInt8]()
        if Int(tag & 7) == _VARINT:
            var v = _read_varint(b, pos, ok)
            if not ok:
                return False
            if v == 0:
                continue
            _varint(rec, tag)
            _varint(rec, v)
        elif Int(tag & 7) == _LEN:
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
            if len(inner) == 0:
                continue
            _varint(rec, tag)
            _varint(rec, UInt64(len(inner)))
            for k in range(len(inner)):
                rec.append(inner[k])
        else:
            return False
        var j = len(fields)
        fields.append(Int(tag >> 3))
        records.append(rec^)
        while j > 0 and fields[j - 1] > fields[j]:
            var f = fields[j]
            fields[j] = fields[j - 1]
            fields[j - 1] = f
            var r = records[j].copy()
            records[j] = records[j - 1].copy()
            records[j - 1] = r^
            j -= 1
    for k in range(len(records)):
        for x in range(len(records[k])):
            out.append(records[k][x])
    return True


def _kept(got: List[UInt8], want: List[UInt8]) -> Bool:
    var cg = List[UInt8]()
    var cw = List[UInt8]()
    if not _canon(got, cg) or not _canon(want, cw):
        return False
    return _hex(cg) == _hex(cw)


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_true(
        _kept(got, want),
        what + ": re-encoding the decoded message does not give the hand-written records back\n  want "
        + _hex(want) + "\n  got  " + _hex(got),
    )


def _bytes_equal(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(_hex(a), _hex(b), what)


# ---- the messages, as bytes ------------------------------------------------------------


def _literal(s: String) -> List[UInt8]:
    """Value { 1 literal }."""
    var b = List[UInt8]()
    _str(b, 1, s)
    return b^


def _secret_ref(name: String) -> List[UInt8]:
    """SecretRef { 1 name }."""
    var b = List[UInt8]()
    _str(b, 1, name)
    return b^


def _entry(key: String, value: List[UInt8]) -> List[UInt8]:
    """One map entry: 1 key, 2 value (a message)."""
    var b = List[UInt8]()
    _str(b, 1, key)
    _msg(b, 2, value)
    return b^


def _seconds(n: Int) -> List[UInt8]:
    """google.protobuf.Duration { 1 seconds }."""
    var b = List[UInt8]()
    _uint(b, 1, UInt64(n))
    return b^


def _size(cpu: Int, mem: Int, gpus: Int) -> List[UInt8]:
    """Size { 1 cpu_millis, 2 memory_mb, 3 gpus }."""
    var b = List[UInt8]()
    _uint(b, 1, UInt64(cpu))
    _uint(b, 2, UInt64(mem))
    _uint(b, 3, UInt64(gpus))
    return b^


def _image(digest: String) -> List[UInt8]:
    """Image { 2 digest, 3 platform }."""
    var b = List[UInt8]()
    _str(b, 2, digest)
    _str(b, 3, "linux/amd64")
    return b^


def _worker() -> List[UInt8]:
    """Worker { 1 image, 2 size (with gpus), 4 args, 5 command, 6 env, 7
    secret_env, 8 replicas, 9 run_as }."""
    var b = List[UInt8]()
    _msg(b, 1, _image("sha256:77"))
    _msg(b, 2, _size(500, 256, 1))
    _str(b, 4, "--queue=work")
    _str(b, 5, "/bin/relay")
    _msg(b, 6, _entry("MODE", _literal("drain")))
    _msg(b, 7, _entry("TOKEN", _secret_ref("relay-token")))
    _uint(b, 8, 3)
    _msg(b, 9, _ref("runner"))
    return b^


def _container_job() -> List[UInt8]:
    """ContainerJob { 1 image, 2 args, 3 size (with gpus), 4 max_retries, 5
    timeout, 6 env, 7 secret_env, 9 command x2, 13 run_as }."""
    var b = List[UInt8]()
    _msg(b, 1, _image("sha256:ab"))
    _str(b, 2, "report")
    _msg(b, 3, _size(250, 128, 2))
    _uint(b, 4, 2)
    _msg(b, 5, _seconds(900))
    _msg(b, 6, _entry("MODE", _literal("full")))
    _msg(b, 7, _entry("API_TOKEN", _secret_ref("api_token")))
    _str(b, 9, "/bin/report")
    _str(b, 9, "--full")
    _msg(b, 13, _ref("runner"))
    return b^


def _resource(id: String, arm: Int, body: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    _str(b, 1, id)
    _msg(b, arm, body)
    return b^


# ---- 1. kept, by bytes only -------------------------------------------------------


def test_added_compute_numbers_are_kept() raises:
    """Catches: `Resource` 11 or 12, `Service` 15 or `Size` 3 undeclared,
    renumbered or of another wire type; any field of `Worker` or the new
    `ContainerJob.command` undeclared (each is dropped or misread on
    re-encode); and the job's old trigger still declared (a schedule written
    by an older file would be kept). Collects every failure, so the red run
    against the earlier schema names all of them."""
    var bad = List[String]()
    var w = _resource("relay", 12, _worker())
    if not _kept(encode_proto(decode_proto[Resource](w.copy())), w):
        bad.append("Resource 12 (Worker 1, 2, 4-9)")
    var j = _resource("nightly", 11, _container_job())
    if not _kept(encode_proto(decode_proto[Resource](j.copy())), j):
        bad.append("Resource 11 (ContainerJob 9 command, Size 3 gpus)")
    var s = List[UInt8]()
    _uint(s, 2, 8080)
    _str(s, 15, "/bin/serve")
    if not _kept(encode_proto(decode_proto[Service](s.copy())), s):
        bad.append("Service 15 (command)")
    var z = _size(250, 128, 2)
    if not _kept(encode_proto(decode_proto[Size](z.copy())), z):
        bad.append("Size 3 (gpus)")
    var sched = List[UInt8]()
    _str(sched, 1, "0 3 * * *")
    var old = _container_job()
    _msg(old, 11, sched)
    var moved = _resource("nightly", 11, old)
    if not _kept(encode_proto(decode_proto[Resource](moved.copy())), j):
        bad.append("ContainerJob 11 (the trigger moved out)")
    var names = String("")
    for i in range(len(bad)):
        names += String("\n  ") + bad[i]
    assert_equal(len(bad), 0, String("not kept as P8 declares them:") + names)
    print("  test_added_compute_numbers_are_kept: PASS")


# ---- 2. ContainerJob --------------------------------------------------------------


def test_container_job() raises:
    """Catches: any field at another number or wire type (two fields of one
    wire type swapped are read back by name), the command reordered or
    merged with `args`, a JSON name other than the proto3 one, an unwritten
    max_retries or run_as read as present (and an explicit 0 read as
    absent), a field declared at 12, the trigger's numbers declared again,
    its JSON keys or the old arm name silently dropped instead of refused,
    and the arm at another number or position."""
    var b = _container_job()
    var j = decode_proto[ContainerJob](b.copy())
    assert_equal(j.image.value().digest.value(), "sha256:ab", "field 1 is `image`")
    assert_equal(len(j.args), 1, "field 2 is `args`")
    assert_equal(j.args[0], "report")
    assert_equal(Int(j.size.value().cpu_millis), 250, "field 3 is `size`")
    assert_equal(Int(j.size.value().gpus), 2, "Size 3 is `gpus`")
    assert_equal(Int(j.max_retries.value()), 2, "field 4 is `max_retries`")
    assert_equal(Int(j.timeout.value().seconds), 900, "field 5 is `timeout`")
    assert_equal(j.env["MODE"].literal.value(), "full", "field 6 is `env`")
    assert_equal(j.secret_env["API_TOKEN"].name, "api_token", "field 7 is `secret_env`")
    assert_equal(len(j.command), 2, "field 9 is `command`, repeated")
    assert_equal(j.command[0], "/bin/report")
    assert_equal(j.command[1], "--full", "the command keeps its order")
    assert_equal(j.run_as.value().resource, "runner", "field 13 is `run_as`")
    _same(encode_proto(j), b, "ContainerJob")

    var text = encode_json(j)
    for want in [
        '"command":["/bin/report","--full"]',
        '"args":["report"]',
        '"maxRetries":2',
        '"timeout":"900s"',
        '"secretEnv":{"API_TOKEN":{"name":"api_token"}}',
        '"runAs":{"resource":"runner"}',
        '"size":{"cpuMillis":250,"memoryMb":128,"gpus":2}',
    ]:
        assert_true(String(want) in text, String(want) + " in ContainerJob JSON: " + text)
    _bytes_equal(
        encode_proto(decode_json[ContainerJob](text)), encode_proto(j), "ContainerJob: JSON round trip"
    )

    var none = decode_proto[ContainerJob](List[UInt8]())
    assert_true(not Bool(none.max_retries), "absent: no max_retries")
    assert_true(not Bool(none.run_as), "absent: no run_as")
    assert_equal(len(none.command), 0, "absent: no command (the image's own entrypoint)")
    var zero = List[UInt8]()
    _uint(zero, 4, 0)
    var jz = decode_proto[ContainerJob](zero.copy())
    assert_true(Bool(jz.max_retries), "an explicit max_retries of 0 is present")
    assert_equal(Int(jz.max_retries.value()), 0)

    var probe = _container_job()
    _str(probe, 12, "not-a-field")
    _same(encode_proto(decode_proto[ContainerJob](probe.copy())), _container_job(), "ContainerJob has no field 12")

    # The trigger moved out. Its bytes are skipped (on_demand 10 with a
    # non-empty payload, schedule 11 with a cron): the job decodes without
    # it, and re-encodes without it.
    var trig = _container_job()
    _str(trig, 10, "x")
    var sched = List[UInt8]()
    _str(sched, 1, "0 3 * * *")
    _str(sched, 2, "UTC")
    _msg(trig, 11, sched)
    _same(encode_proto(decode_proto[ContainerJob](trig.copy())), _container_job(), "ContainerJob 10 and 11 are reserved")
    # Its JSON keys are refused, so an authored trigger is never dropped.
    for old in ['{"onDemand":{}}', '{"schedule":{"cron":"0 3 * * *"}}']:
        var raised = False
        try:
            _ = decode_json[ContainerJob](String(old))
        except:
            raised = True
        assert_true(raised, String(old) + " is refused, not dropped")

    var rb = _resource("nightly", 11, _container_job())
    var rr = decode_proto[Resource](rb.copy())
    assert_true(Bool(rr.container_job), "body 11 is `container_job`")
    assert_equal(rr._oneof0_case, 2, "the container job is the second arm")
    var rt = encode_json(rr)
    assert_true('"containerJob":{' in rt, "Resource JSON names the arm containerJob: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a job: JSON round trip")
    var raised = False
    try:
        _ = decode_json[Resource](String('{"id":"nightly","job":{"args":["report"]}}'))
    except:
        raised = True
    assert_true(raised, "the old arm name `job` is refused, not dropped")
    print("  test_container_job: PASS")


# ---- 3. Worker --------------------------------------------------------------------


def test_worker() raises:
    """Catches: any field at another number or wire type, the command or
    args reordered, a JSON name other than the proto3 one, an unwritten
    replicas or run_as read as present (and an explicit 0 read as absent),
    a draft number (3, 10, 11) declared again, a field declared at 13, and
    the arm at another number or position."""
    var b = _worker()
    var w = decode_proto[Worker](b.copy())
    assert_equal(w.image.value().digest.value(), "sha256:77", "field 1 is `image`")
    assert_equal(Int(w.size.value().memory_mb), 256, "field 2 is `size`")
    assert_equal(Int(w.size.value().gpus), 1)
    assert_equal(len(w.args), 1, "field 4 is `args`")
    assert_equal(w.args[0], "--queue=work")
    assert_equal(len(w.command), 1, "field 5 is `command`")
    assert_equal(w.command[0], "/bin/relay")
    assert_equal(w.env["MODE"].literal.value(), "drain", "field 6 is `env`")
    assert_equal(w.secret_env["TOKEN"].name, "relay-token", "field 7 is `secret_env`")
    assert_equal(Int(w.replicas.value()), 3, "field 8 is `replicas`")
    assert_equal(w.run_as.value().resource, "runner", "field 9 is `run_as`")
    _same(encode_proto(w), b, "Worker")

    var text = encode_json(w)
    for want in [
        '"digest":"sha256:77"',
        '"size":{"cpuMillis":500,"memoryMb":256,"gpus":1}',
        '"args":["--queue=work"]',
        '"command":["/bin/relay"]',
        '"env":{"MODE":{"literal":"drain"}}',
        '"secretEnv":{"TOKEN":{"name":"relay-token"}}',
        '"replicas":3',
        '"runAs":{"resource":"runner"}',
    ]:
        assert_true(String(want) in text, String(want) + " in Worker JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Worker](text)), encode_proto(w), "Worker: JSON round trip")

    var none = decode_proto[Worker](List[UInt8]())
    assert_true(not Bool(none.replicas), "absent: no replicas (the versioned default)")
    assert_true(not Bool(none.run_as) and not Bool(none.image), "absent: no run_as, no image")
    var zero = List[UInt8]()
    _uint(zero, 8, 0)
    var wz = decode_proto[Worker](zero.copy())
    assert_true(Bool(wz.replicas), "an explicit replicas of 0 is present (validate refuses it)")
    assert_equal(Int(wz.replicas.value()), 0)

    # A draft's scale (3) and source (10, 11): skipped, not misread.
    var draft = _worker()
    _str(draft, 3, "x")
    _str(draft, 10, "x")
    _str(draft, 11, "x")
    _same(encode_proto(decode_proto[Worker](draft.copy())), _worker(), "Worker 3, 10 and 11 are reserved")
    var probe = _worker()
    _str(probe, 13, "not-a-field")
    _same(encode_proto(decode_proto[Worker](probe.copy())), _worker(), "Worker has no field 13")

    var rr = decode_proto[Resource](_resource("relay", 12, _worker()))
    assert_true(Bool(rr.worker), "body 12 is `worker`")
    assert_equal(rr._oneof0_case, 3, "the worker is the third arm")
    var rt = encode_json(rr)
    assert_true('"worker":{' in rt, "Resource JSON carries the worker: " + rt)
    _bytes_equal(encode_proto(decode_json[Resource](rt)), encode_proto(rr), "Resource with a worker: JSON round trip")
    print("  test_worker: PASS")


# ---- 4. Service.command -------------------------------------------------------------


def test_service_command() raises:
    """Catches: `command` at another number or wire type, merged with `args`
    (3) or reordered, its JSON name, and a field declared at 17."""
    var b = List[UInt8]()
    _uint(b, 2, 8080)
    _str(b, 3, "--fast")
    _str(b, 15, "/bin/serve")
    _str(b, 15, "--listen")
    var s = decode_proto[Service](b.copy())
    assert_equal(len(s.command), 2, "field 15 is `command`, repeated")
    assert_equal(s.command[0], "/bin/serve")
    assert_equal(s.command[1], "--listen", "the command keeps its order")
    assert_equal(len(s.args), 1, "`args` stays field 3")
    _same(encode_proto(s), b, "Service 15")
    var text = encode_json(s)
    assert_true('"command":["/bin/serve","--listen"]' in text, "Service JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Service](text)), encode_proto(s), "Service: JSON round trip")
    assert_equal(len(decode_proto[Service](List[UInt8]()).command), 0, "absent: no command")
    var probe = b.copy()
    _str(probe, 17, "not-a-field")
    _same(encode_proto(decode_proto[Service](probe.copy())), b, "Service has no field 17")
    print("  test_service_command: PASS")


# ---- 5. Size ------------------------------------------------------------------------


def test_size() raises:
    """Catches: `gpus` at another number or wire type (or swapped with a
    field of the same wire type: each is read back by name), its JSON name,
    an unwritten count read as anything but 0, and a field declared at 4."""
    var b = _size(1500, 2048, 4)
    var z = decode_proto[Size](b.copy())
    assert_equal(Int(z.cpu_millis), 1500, "field 1 is `cpu_millis`")
    assert_equal(Int(z.memory_mb), 2048, "field 2 is `memory_mb`")
    assert_equal(Int(z.gpus), 4, "field 3 is `gpus`")
    _same(encode_proto(z), b, "Size")
    var text = encode_json(z)
    assert_true('"gpus":4' in text, "Size JSON: " + text)
    _bytes_equal(encode_proto(decode_json[Size](text)), encode_proto(z), "Size: JSON round trip")
    assert_equal(Int(decode_proto[Size](List[UInt8]()).gpus), 0, "absent: no GPU")
    var probe = b.copy()
    _str(probe, 4, "not-a-field")
    _same(encode_proto(decode_proto[Size](probe.copy())), b, "Size has no field 4")
    print("  test_size: PASS")


# ---- 6. the arm census ----------------------------------------------------------------


def test_body_arm_census() raises:
    """Catches: any arm renumbered, and any arm's oneof position moved (an arm
    declared out of number order shifts every later position, and kci_cloud
    maps positions to fields); and a held arm declared."""
    var fields: List[Int] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 80]
    for i in range(len(fields)):
        var b = List[UInt8]()
        _str(b, 1, "x")
        _msg(b, fields[i], List[UInt8]())
        var r = decode_proto[Resource](b.copy())
        assert_equal(r._oneof0_case, i + 1, String("Resource.body ") + String(fields[i]) + " position")
        # The arm survives a re-encode (an empty body may re-encode with its
        # zero-valued fields written out, so the arm is compared, not bytes).
        var again = decode_proto[Resource](encode_proto(r))
        assert_equal(again._oneof0_case, i + 1, String("arm ") + String(fields[i]) + " re-encodes")
    for held in [17, 19, 32, 33, 90]:
        var b = List[UInt8]()
        _str(b, 1, "x")
        _msg(b, held, List[UInt8]())
        assert_equal(decode_proto[Resource](b.copy())._oneof0_case, 0, String(held) + " is held")
    print("  test_body_arm_census: PASS")


def main() raises:
    print("test_resource_compute_numbers: container_job, worker, command, gpus")
    test_added_compute_numbers_are_kept()
    test_container_job()
    test_worker()
    test_service_command()
    test_size()
    test_body_arm_census()
    print("ALL kci.resource.v1 COMPUTE FIELD-NUMBER TESTS PASSED")
