# =============================================================================
# kci_gcp_emulator/emu_run.mojo: the Cloud Run Admin v2 job paths.
# =============================================================================
#
#   POST   /v2/projects/<p>/locations/<r>/jobs?jobId=<id>   create
#   GET    /v2/projects/<p>/locations/<r>/jobs              list (pageSize,
#          pageToken; at most `page_cap` jobs a page)
#   GET    /v2/projects/<p>/locations/<r>/jobs/<id>         get
#   PATCH  /v2/projects/<p>/locations/<r>/jobs/<id>         update: the body
#          is the whole job, which replaces what the job holds
#   DELETE /v2/projects/<p>/locations/<r>/jobs/<id>         delete
# The body of a create or an update is the job's JSON. The service sets
# `name`, `uid`, `generation`, `etag` and the terminal condition (`Ready`,
# CONDITION_SUCCEEDED, or CONDITION_FAILED for a job put in the failed
# state, until its next update), and refuses labels outside GCP's rule
# (a key of [a-z0-9_-] starting with a letter, a value of [a-z0-9_-], each
# at most 63 bytes, at most 64 labels). A mutating call answers a
# long-running operation that is already done: the emulator applies every
# change before it answers.
# =============================================================================

from komira_json import JsonValue

from kci_gcp_emulator.emu_http import (
    EmuRequest,
    EmuResponse,
    failure,
    ok,
    parse_object,
    str_member,
    with_member,
    without_member,
)
from kci_gcp_emulator.emu_state import EmuJob, GcpEmulator


comptime LABELS_MAX = 64


def _valid_job_id(id: String) -> Bool:
    var b = id.as_bytes()
    if len(b) == 0 or len(b) > 63:
        return False
    if not (b[0] >= UInt8(ord("a")) and b[0] <= UInt8(ord("z"))):
        return False
    if b[len(b) - 1] == UInt8(ord("-")):
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("a") and c <= ord("z")) or (c >= ord("0") and c <= ord("9")) or c == ord("-")):
            return False
    return True


def _label_text_ok(s: String, key: Bool) -> Bool:
    var b = s.as_bytes()
    if len(b) > 63 or (key and len(b) == 0):
        return False
    if key and not (b[0] >= UInt8(ord("a")) and b[0] <= UInt8(ord("z"))):
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("a") and c <= ord("z")) or (c >= ord("0") and c <= ord("9")) or c == ord("_") or c == ord("-")):
            return False
    return True


def label_problem(job: JsonValue) raises -> String:
    """Why the job's labels break GCP's rule, or empty."""
    if not job.has("labels"):
        return String("")
    var labels = job.get("labels")
    if not labels.is_object():
        return String("labels is not an object")
    if labels.num_members() > LABELS_MAX:
        return String("more than 64 labels")
    for i in range(labels.num_members()):
        var k = labels.key_at(i)
        var v = labels.value_at(i)
        if not v.is_string():
            return String("label ") + k + String(" is not a string")
        if not _label_text_ok(k, True) or not _label_text_ok(v.as_string(), False):
            return String("label ") + k + String(" breaks the label rule")
    return String("")


def _condition(failed: Bool) raises -> JsonValue:
    var c = JsonValue.empty_object()
    c.set_member(String("type"), JsonValue.from_string(String("Ready")))
    var state = String("CONDITION_FAILED") if failed else String("CONDITION_SUCCEEDED")
    c.set_member(String("state"), JsonValue.from_string(state^))
    return c^


def job_json(j: EmuJob) raises -> String:
    var body = with_member(j.body, String("terminalCondition"), _condition(j.failed))
    return body.serialize()


def _operation(mut emu: GcpEmulator) -> String:
    var name = (
        String("projects/") + emu.project + String("/locations/") + emu.region + String("/operations/op-")
        + emu.fresh_id()
    )
    return String("{\"name\":\"") + name + String("\",\"done\":true}")


def _stored(name: String, var body: JsonValue, generation: Int) raises -> JsonValue:
    var out = without_member(body, String("terminalCondition"))
    out = with_member(out, String("name"), JsonValue.from_string(name.copy()))
    out = with_member(out, String("uid"), JsonValue.from_string(String("uid-") + name))
    out = with_member(out, String("generation"), JsonValue.from_string(String(generation)))
    out = with_member(out, String("etag"), JsonValue.from_string(String("\"g") + String(generation) + String("\"")))
    out = with_member(out, String("reconciling"), JsonValue.from_bool(False))
    return out^


def _list(mut emu: GcpEmulator, req: EmuRequest) raises -> EmuResponse:
    var size = 20
    var asked = req.query(String("pageSize"))
    if asked.byte_length() > 0:
        size = atol(asked)
    if size > emu.page_cap:
        size = emu.page_cap
    var start = 0
    var token = req.query(String("pageToken"))
    if token.byte_length() > 0:
        start = atol(token)
    var end = start + size
    if end > len(emu.jobs):
        end = len(emu.jobs)
    var text = String("{\"jobs\":[")
    for i in range(start, end):
        if i > start:
            text += String(",")
        text += job_json(emu.jobs[i])
    text += String("]")
    if end < len(emu.jobs):
        text += String(",\"nextPageToken\":\"") + String(end) + String("\"")
    text += String("}")
    return ok(text)


def _create(mut emu: GcpEmulator, req: EmuRequest) raises -> EmuResponse:
    var id = req.query(String("jobId"))
    if not _valid_job_id(id):
        return failure(400, String("jobId must be 1 to 63 of [a-z0-9-], start with a letter and not end with -"))
    var body = parse_object(req.body)
    if str_member(body, String("name")).byte_length() > 0:
        return failure(400, String("a job to create must not name itself; the name is the parent and jobId"))
    var why = label_problem(body)
    if why.byte_length() > 0:
        return failure(400, why)
    var name = emu.job_name(id)
    if emu.job_index(name) >= 0:
        return failure(409, String("Resource '") + id + String("' already exists."), String("ALREADY_EXISTS"))
    var stored = _stored(name, body^, 1)
    emu.jobs.append(EmuJob(name, stored^))
    emu.mutations += 1
    emu.count_create(name)
    if emu.take_race(name):
        return failure(409, String("Resource '") + id + String("' already exists."), String("ALREADY_EXISTS"))
    if emu.take_fail_after(name):
        return failure(504, String("The create did not answer in time"))
    return ok(_operation(emu))


def _update(mut emu: GcpEmulator, i: Int, req: EmuRequest) raises -> EmuResponse:
    var body = parse_object(req.body)
    var why = label_problem(body)
    if why.byte_length() > 0:
        return failure(400, why)
    var held = str_member(emu.jobs[i].body, String("generation"))
    var generation = (atol(held) if held.byte_length() > 0 else 0) + 1
    var name = emu.jobs[i].name.copy()
    var stored = _stored(name, body^, generation)
    emu.jobs[i].body = stored^
    emu.jobs[i].failed = False
    emu.mutations += 1
    return ok(_operation(emu))


def serve_run(mut emu: GcpEmulator, req: EmuRequest) raises -> EmuResponse:
    var base = String("/v2/projects/") + emu.project + String("/locations/") + emu.region + String("/jobs")
    if not req.path.startswith(base):
        return failure(404, String("no Run path ") + req.path)
    var tail = String(req.path[byte = base.byte_length() : req.path.byte_length()])
    if tail.byte_length() == 0:
        if req.method == "GET":
            return _list(emu, req)
        if req.method == "POST":
            return _create(emu, req)
        return failure(400, String("method ") + req.method + String(" on the job collection"))
    if not tail.startswith("/"):
        return failure(404, String("no Run path ") + req.path)
    var name = emu.job_name(String(tail[byte = 1 : tail.byte_length()]))
    var i = emu.job_index(name)
    if i < 0:
        return failure(404, String("Resource '") + name + String("' was not found"))
    if req.method == "GET":
        return ok(job_json(emu.jobs[i]))
    if req.method == "PATCH":
        return _update(emu, i, req)
    if req.method == "DELETE":
        _ = emu.jobs.pop(i)
        emu.mutations += 1
        return ok(_operation(emu))
    return failure(400, String("method ") + req.method + String(" on a job"))
