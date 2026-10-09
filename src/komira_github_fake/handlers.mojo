# =============================================================================
# komira_github_fake/handlers.mojo -- each route of the subset, answered from
#   FakeState as GitHub answers it.
# =============================================================================
#
# fake.mojo has already matched the route and checked the credential; these
# functions read the path parameters and the body and answer.
#
# Installation tokens (`apps/create-installation-access-token`): the body is
# empty (every repository and permission of the installation) or an object
# whose only members are `repository_ids` (integers), `repositories` (names)
# and `permissions` (name -> read|write). Each repository must be one of the
# installation's and each permission one it grants, else 422, as GitHub
# answers. The token gets exactly the repositories asked for (all of the
# installation's when none are named) and the permissions asked for plus
# `metadata:read` (GitHub always includes it); it expires 3600 s after the
# fake's clock. A suspended installation gets 403.
#
# Installation routes answer only for repositories the token covers: any
# other repository is 404, as GitHub hides repositories a token cannot see.
# =============================================================================

from komira_github import (
    GitHubResponse,
    is_check_conclusion,
    is_check_status,
    path_segments,
    query_param,
)
from komira_json import JSON_ARRAY, JSON_OBJECT, JSON_STRING, JsonValue, parse_json_bytes

from .model import FakeCheckRun, FakeRepo, FakeToken, grants
from .render import (
    artifact_json,
    check_run_json,
    contents_json,
    error_response,
    installation_json,
    job_json,
    json_response,
    page_response,
    permissions_json,
    repo_json,
    rfc3339,
    run_json,
)
from .state import FakeState


comptime TOKEN_LIFETIME_S: Int64 = 3600


def template_params(template: String, path: String) -> List[String]:
    """The values of `template`'s parameters in `path`, in order; `{path}`
    is every remaining segment joined by `/`. The route already matched."""
    var t = path_segments(template)
    var p = path_segments(path)
    var out = List[String]()
    for i in range(len(t)):
        if t[i] == "{path}":
            var rest = String("")
            for k in range(i, len(p)):
                if k > i:
                    rest += "/"
                rest += p[k]
            out.append(rest^)
            break
        if t[i].startswith("{"):
            out.append(p[i])
    return out^


def _hex(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c - UInt8(ord("0")))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c - UInt8(ord("a"))) + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c - UInt8(ord("A"))) + 10
    return -1


def percent_decode(s: String) raises -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        if b[i] == UInt8(ord("%")):
            if i + 2 >= len(b) or _hex(b[i + 1]) < 0 or _hex(b[i + 2]) < 0:
                raise Error("bad escape")
            out.append(UInt8(_hex(b[i + 1]) * 16 + _hex(b[i + 2])))
            i += 3
            continue
        out.append(b[i])
        i += 1
    return String(unsafe_from_utf8=Span(out))


def _id(s: String) -> Int64:
    var v: Int64 = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        v = v * 10 + Int64(Int(b[i] - UInt8(ord("0"))))
    return v


# --- the App's routes ---------------------------------------------------------


def mint_installation_token(mut st: FakeState, installation_id: Int64, body: List[UInt8]) raises -> GitHubResponse:
    """`apps/create-installation-access-token` (module header)."""
    var ii = st.installation_index(installation_id)
    if ii < 0:
        return error_response(404, String("Not Found"))
    if st.installations[ii].suspended:
        return error_response(403, String("This installation has been suspended"))
    var inst = st.installations[ii].copy()
    var repo_ids = List[Int64]()
    var perms = List[String]()
    var named_perms = False
    if len(body) > 0:
        var doc: JsonValue
        try:
            doc = parse_json_bytes(body)
        except:
            return error_response(400, String("Problems parsing JSON"))
        if doc.kind_tag() != JSON_OBJECT:
            return error_response(400, String("Problems parsing JSON"))
        for m in range(doc.num_members()):
            var key = doc.key_at(m)
            var v = doc.value_at(m)
            if key == "repository_ids":
                if v.kind_tag() != JSON_ARRAY:
                    return error_response(422, String("repository_ids is not an array"))
                for k in range(v.array_len()):
                    var e = v.element_at(k)
                    if not e.is_integral_number():
                        return error_response(422, String("repository_ids holds a non-integer"))
                    var rid = e.as_int64()
                    if not inst.has_repo(rid):
                        return error_response(422, String("There is at least one repository that does not exist or is not accessible to the parent installation."))
                    repo_ids.append(rid)
            elif key == "repositories":
                if v.kind_tag() != JSON_ARRAY:
                    return error_response(422, String("repositories is not an array"))
                for k in range(v.array_len()):
                    var e = v.element_at(k)
                    if e.kind_tag() != JSON_STRING:
                        return error_response(422, String("repositories holds a non-string"))
                    var ri = st.repo_index_by_name(inst.account, e.as_string())
                    if ri < 0 or not inst.has_repo(st.repos[ri].id):
                        return error_response(422, String("There is at least one repository that does not exist or is not accessible to the parent installation."))
                    repo_ids.append(st.repos[ri].id)
            elif key == "permissions":
                if v.kind_tag() != JSON_OBJECT:
                    return error_response(422, String("permissions is not an object"))
                named_perms = True
                for k in range(v.num_members()):
                    var level = v.value_at(k)
                    if level.kind_tag() != JSON_STRING:
                        return error_response(422, String("a permission level is not a string"))
                    var p = v.key_at(k) + String(":") + level.as_string()
                    if not grants(inst.permissions, p):
                        return error_response(422, String("The permissions requested are not granted to this installation."))
                    perms.append(p)
            else:
                return error_response(422, String("unknown member ") + key)
    if len(repo_ids) == 0:
        repo_ids = inst.repo_ids.copy()
    if not named_perms:
        perms = inst.permissions.copy()
    if not grants(perms, String("metadata:read")):
        perms.append(String("metadata:read"))
    st.tokens_minted += 1
    var token = String("ghs_fake") + String(st.new_id())
    var expires_at = st.now + TOKEN_LIFETIME_S
    var repos_json = String("[")
    for i in range(len(repo_ids)):
        var ri = st.repo_index(repo_ids[i])
        if i > 0:
            repos_json += ","
        repos_json += repo_json(st.repos[ri])
    repos_json += "]"
    var body_out = (
        String('{"token":"')
        + token
        + String('","expires_at":"')
        + rfc3339(expires_at)
        + String('","permissions":')
        + permissions_json(perms)
        + String(',"repository_selection":"selected","repositories":')
        + repos_json
        + String("}")
    )
    st.tokens.append(FakeToken(token, installation_id, repo_ids^, perms^, expires_at))
    return json_response(201, body_out)


def handle_app_route(mut st: FakeState, name: String, params: List[String], body: List[UInt8], issuer: String) raises -> GitHubResponse:
    if name == "apps/get-authenticated":
        return json_response(
            200, String('{"id":1,"slug":"fake-app","client_id":"') + issuer + String('"}')
        )
    if name == "apps/get-installation":
        var ii = st.installation_index(_id(params[0]))
        if ii < 0:
            return error_response(404, String("Not Found"))
        return json_response(200, installation_json(st.installations[ii]))
    if name == "apps/get-repo-installation":
        var ri = st.repo_index_by_name(params[0], params[1])
        if ri >= 0:
            for i in range(len(st.installations)):
                if st.installations[i].has_repo(st.repos[ri].id):
                    return json_response(200, installation_json(st.installations[i]))
        return error_response(404, String("Not Found"))
    if name == "apps/create-installation-access-token":
        return mint_installation_token(st, _id(params[0]), body)
    return error_response(404, String("Not Found"))
