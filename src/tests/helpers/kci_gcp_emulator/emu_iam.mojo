# =============================================================================
# kci_gcp_emulator/emu_iam.mojo: the IAM v1 service-account paths.
# =============================================================================
#
#   GET    /v1/projects/<p>/serviceAccounts              list (pageSize,
#          pageToken; at most `page_cap` accounts a page, so a client must
#          follow nextPageToken)
#   POST   /v1/projects/<p>/serviceAccounts              create
#          (`accountId` 6 to 30 of [a-z0-9-], starting with a letter and
#          not ending with `-`; a description over 256 bytes is refused)
#   GET    /v1/projects/<p>/serviceAccounts/<email>      get
#   PATCH  /v1/projects/<p>/serviceAccounts/<email>      patch: the
#          `updateMask` names the fields written (displayName, description)
#   DELETE /v1/projects/<p>/serviceAccounts/<email>      delete (its policy
#          goes with it)
#   POST   .../<email>:getIamPolicy, .../<email>:setIamPolicy
# A missing account is 404 NOT_FOUND, an existing id 409 ALREADY_EXISTS, a
# malformed request 400 INVALID_ARGUMENT, each in the google.rpc.Status
# envelope.
# =============================================================================

from komira_json import JsonValue

from kci_gcp_emulator.emu_http import EmuRequest, EmuResponse, failure, ok, parse_object, str_member
from kci_gcp_emulator.emu_policy import get_policy, set_policy
from kci_gcp_emulator.emu_state import ACCOUNT_DESCRIPTION_MAX, EmuAccount, GcpEmulator


def account_json(emu: GcpEmulator, a: EmuAccount) raises -> String:
    var out = JsonValue.empty_object()
    out.set_member(String("name"), JsonValue.from_string(emu.account_name(a.email)))
    out.set_member(String("projectId"), JsonValue.from_string(emu.project.copy()))
    out.set_member(String("uniqueId"), JsonValue.from_string(a.unique_id.copy()))
    out.set_member(String("email"), JsonValue.from_string(a.email.copy()))
    if a.display_name.byte_length() > 0:
        out.set_member(String("displayName"), JsonValue.from_string(a.display_name.copy()))
    out.set_member(String("etag"), JsonValue.from_string(String("MDEwMjE5MjA=")))
    if a.description.byte_length() > 0:
        out.set_member(String("description"), JsonValue.from_string(a.description.copy()))
    out.set_member(String("oauth2ClientId"), JsonValue.from_string(a.unique_id.copy()))
    return out.serialize()


def valid_account_id(id: String) -> Bool:
    var b = id.as_bytes()
    if len(b) < 6 or len(b) > 30:
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
    if end > len(emu.accounts):
        end = len(emu.accounts)
    var text = String("{\"accounts\":[")
    for i in range(start, end):
        if i > start:
            text += String(",")
        text += account_json(emu, emu.accounts[i])
    text += String("]")
    if end < len(emu.accounts):
        text += String(",\"nextPageToken\":\"") + String(end) + String("\"")
    text += String("}")
    return ok(text)


def _create(mut emu: GcpEmulator, req: EmuRequest) raises -> EmuResponse:
    var body = parse_object(req.body)
    var id = str_member(body, String("accountId"))
    if not valid_account_id(id):
        return failure(400, String("accountId must be 6 to 30 of [a-z0-9-], start with a letter and not end with -"))
    var sa = JsonValue.empty_object()
    if body.has("serviceAccount"):
        sa = body.get("serviceAccount")
    var desc = str_member(sa, String("description"))
    if desc.byte_length() > ACCOUNT_DESCRIPTION_MAX:
        return failure(400, String("the description is longer than 256 bytes"))
    var email = emu.email_of(id)
    if emu.account_index(email) >= 0:
        return failure(409, String("Service account ") + id + String(" already exists"), String("ALREADY_EXISTS"))
    var account = EmuAccount(id, email, str_member(sa, String("displayName")), desc, emu.fresh_id())
    emu.accounts.append(account.copy())
    emu.mutations += 1
    emu.count_create(email)
    if emu.take_race(email):
        return failure(409, String("Service account ") + id + String(" already exists"), String("ALREADY_EXISTS"))
    if emu.take_fail_after(email):
        return failure(504, String("The create did not answer in time"))
    return ok(account_json(emu, account))


def _patch(mut emu: GcpEmulator, i: Int, req: EmuRequest) raises -> EmuResponse:
    var body = parse_object(req.body)
    var mask = str_member(body, String("updateMask"))
    if mask.byte_length() == 0:
        return failure(400, String("updateMask is required"))
    var sa = JsonValue.empty_object()
    if body.has("serviceAccount"):
        sa = body.get("serviceAccount")
    var fields = mask.split(",")
    for k in range(len(fields)):
        var f = String(fields[k])
        if f == "description":
            var desc = str_member(sa, String("description"))
            if desc.byte_length() > ACCOUNT_DESCRIPTION_MAX:
                return failure(400, String("the description is longer than 256 bytes"))
            emu.accounts[i].description = desc^
        elif f == "displayName" or f == "display_name":
            emu.accounts[i].display_name = str_member(sa, String("displayName"))
        else:
            return failure(400, String("updateMask names a field that cannot be patched: ") + f)
    emu.mutations += 1
    return ok(account_json(emu, emu.accounts[i]))


def serve_iam(mut emu: GcpEmulator, req: EmuRequest) raises -> EmuResponse:
    var base = String("/v1/projects/") + emu.project + String("/serviceAccounts")
    if not req.path.startswith(base):
        return failure(404, String("no IAM path ") + req.path)
    var tail = String(req.path[byte = base.byte_length() : req.path.byte_length()])
    if tail.byte_length() == 0:
        if req.method == "GET":
            return _list(emu, req)
        if req.method == "POST":
            return _create(emu, req)
        return failure(400, String("method ") + req.method + String(" on the account collection"))
    if not tail.startswith("/"):
        return failure(404, String("no IAM path ") + req.path)
    var item = String(tail[byte = 1 : tail.byte_length()])
    var verb = String("")
    var colon = item.find(":")
    if colon >= 0:
        verb = String(item[byte = colon + 1 : item.byte_length()])
        var head = String(item[byte=0:colon])
        item = head^
    var i = emu.account_index(item)
    if i < 0:
        return failure(404, String("Unknown service account ") + item)
    var name = emu.account_name(item)
    if verb == "getIamPolicy" and req.method == "POST":
        return get_policy(emu, name)
    if verb == "setIamPolicy" and req.method == "POST":
        return set_policy(emu, name, req.body)
    if verb.byte_length() > 0:
        return failure(400, String("unknown method :") + verb)
    if req.method == "GET":
        return ok(account_json(emu, emu.accounts[i]))
    if req.method == "PATCH":
        return _patch(emu, i, req)
    if req.method == "DELETE":
        _ = emu.accounts.pop(i)
        var p = emu.policy_index(name)
        if p >= 0:
            _ = emu.policies.pop(p)
        emu.mutations += 1
        return ok(String("{}"))
    return failure(400, String("method ") + req.method + String(" on an account"))
