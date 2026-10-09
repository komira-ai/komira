# =============================================================================
# kci_gcp_emulator/emu_policy.mojo: getIamPolicy and setIamPolicy, for an
# account (IAM) and for the project (Cloud Resource Manager) alike.
# =============================================================================
#
# A policy is read as `{"version":1,"etag":<base64>,"bindings":[...]}` (no
# `bindings` member when it has none). A write replaces the bindings with
# the request's, when the request's etag is the current one or absent;
# a stale etag is refused 409 ABORTED, as IAM refuses a lost
# read-modify-write. Every membership the write ADDS (a role and a member
# the policy did not hold) is a create of that binding: it is counted, and
# it is where the race and fail-after hooks fire (emu_state.mojo).
# =============================================================================

from komira_encoding import base64_encode
from komira_json import JsonValue

from kci_gcp_emulator.emu_http import EmuResponse, failure, ok, parse_object, str_member
from kci_gcp_emulator.emu_state import EmuBinding, EmuPolicy, GcpEmulator


def etag_of(version: Int) -> String:
    var raw = String("v") + String(version)
    return base64_encode(Span(raw.as_bytes()))


def policy_json(p: EmuPolicy) raises -> String:
    var out = JsonValue.empty_object()
    out.set_member(String("version"), JsonValue.from_i64(1))
    out.set_member(String("etag"), JsonValue.from_string(etag_of(p.version)))
    var bindings = JsonValue.empty_array()
    for i in range(len(p.bindings)):
        if len(p.bindings[i].members) == 0:
            continue
        var b = JsonValue.empty_object()
        b.set_member(String("role"), JsonValue.from_string(p.bindings[i].role.copy()))
        var members = JsonValue.empty_array()
        for k in range(len(p.bindings[i].members)):
            members.push(JsonValue.from_string(p.bindings[i].members[k].copy()))
        b.set_member(String("members"), members^)
        bindings.push(b^)
    if bindings.array_len() > 0:
        out.set_member(String("bindings"), bindings^)
    return out.serialize()


def get_policy(mut emu: GcpEmulator, resource: String) raises -> EmuResponse:
    var i = emu.policy_of(resource)
    return ok(policy_json(emu.policies[i]))


def _bindings_of(doc: JsonValue) raises -> List[EmuBinding]:
    var out = List[EmuBinding]()
    if not doc.has("bindings"):
        return out^
    var arr = doc.get("bindings")
    for i in range(arr.array_len()):
        var b = arr.element_at(i)
        var role = str_member(b, String("role"))
        var members = List[String]()
        if b.has("members"):
            var m = b.get("members")
            for k in range(m.array_len()):
                members.append(m.element_at(k).as_string())
        if b.has("condition"):
            raise Error("emulator: a conditional binding is not modelled")
        out.append(EmuBinding(role, members^))
    return out^


def set_policy(mut emu: GcpEmulator, resource: String, body: String) raises -> EmuResponse:
    var req = parse_object(body)
    if not req.has("policy"):
        return failure(400, String("setIamPolicy: the request has no policy"))
    var doc = req.get("policy")
    var i = emu.policy_of(resource)
    var etag = str_member(doc, String("etag"))
    if etag.byte_length() > 0 and etag != etag_of(emu.policies[i].version):
        return failure(409, String("There were concurrent policy changes"), String("ABORTED"))
    var next = EmuPolicy(resource)
    var bindings = _bindings_of(doc)
    for b in range(len(bindings)):
        for m in range(len(bindings[b].members)):
            next.add(bindings[b].members[m], bindings[b].role)
    var added = List[String]()
    for b in range(len(next.bindings)):
        for m in range(len(next.bindings[b].members)):
            if not emu.policies[i].has(next.bindings[b].members[m], next.bindings[b].role):
                added.append(emu.binding_key(resource, next.bindings[b].members[m], next.bindings[b].role))
    next.version = emu.policies[i].version + 1
    emu.policies[i] = next^
    emu.mutations += 1
    var raced = False
    var timed_out = False
    for k in range(len(added)):
        emu.count_create(added[k])
        if emu.take_race(added[k]):
            raced = True
        if emu.take_fail_after(added[k]):
            timed_out = True
    if raced:
        return failure(409, String("There were concurrent policy changes"), String("ABORTED"))
    if timed_out:
        return failure(504, String("The policy write did not answer in time"))
    return ok(policy_json(emu.policies[i]))
