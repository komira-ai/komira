# =============================================================================
# komira_github_fake/repo_handlers.mojo -- the installation routes of the
#   subset, answered for the repositories one token covers.
# =============================================================================
#
# Every route but `apps/list-repos-accessible-to-installation` names a
# repository; one the token does not cover answers 404 (handlers.mojo's
# header). Jobs of a run are those of its latest attempt (GitHub's default
# `filter=latest`); jobs of an attempt are that attempt's. A check run
# created with a conclusion is completed, as GitHub records it; a completed
# status without a conclusion is 422.
# =============================================================================

from komira_github import GitHubResponse, is_check_conclusion, is_check_status, query_param
from komira_json import JSON_OBJECT, JSON_STRING, JsonValue, parse_json_bytes

from .handlers import percent_decode, template_params
from .model import FakeCheckRun, FakeToken
from .render import (
    artifact_json,
    check_run_json,
    contents_json,
    error_response,
    job_json,
    json_response,
    page_response,
    repo_json,
    run_json,
)
from .state import FakeState


def _id(s: String) -> Int64:
    var v: Int64 = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        v = v * 10 + Int64(Int(b[i] - UInt8(ord("0"))))
    return v


def _not_found() -> GitHubResponse:
    return error_response(404, String("Not Found"))


def _str_member(doc: JsonValue, key: String, mut out: String) raises -> Bool:
    """Sets `out` to the string member `key`; False when it is present and
    not a string."""
    if not doc.has(key):
        return True
    var v = doc.get(key)
    if v.is_null():
        return True
    if v.kind_tag() != JSON_STRING:
        return False
    out = v.as_string()
    return True


def _is_sha(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 40:
        return False
    for i in range(40):
        var c = b[i]
        if not ((c >= UInt8(ord("0")) and c <= UInt8(ord("9"))) or (c >= UInt8(ord("a")) and c <= UInt8(ord("f")))):
            return False
    return True


def _check_run_write(
    mut st: FakeState, repo_id: Int64, body: List[UInt8], existing: Int
) raises -> GitHubResponse:
    """checks/create (`existing` -1) or checks/update of check_runs[existing]."""
    var doc: JsonValue
    try:
        doc = parse_json_bytes(body)
    except:
        return error_response(400, String("Problems parsing JSON"))
    if doc.kind_tag() != JSON_OBJECT:
        return error_response(400, String("Problems parsing JSON"))
    var c: FakeCheckRun
    if existing >= 0:
        c = st.check_runs[existing].copy()
    else:
        c = FakeCheckRun(st.new_id(), repo_id, String(""), String(""), String("queued"), String(""), String(""), String(""), String(""), String(""))
    var status = String("")
    var conclusion = String("")
    var ok = _str_member(doc, String("name"), c.name)
    ok = ok and _str_member(doc, String("head_sha"), c.head_sha)
    ok = ok and _str_member(doc, String("status"), status)
    ok = ok and _str_member(doc, String("conclusion"), conclusion)
    ok = ok and _str_member(doc, String("details_url"), c.details_url)
    ok = ok and _str_member(doc, String("external_id"), c.external_id)
    if doc.has(String("output")):
        var o = doc.get(String("output"))
        if o.kind_tag() != JSON_OBJECT:
            ok = False
        else:
            ok = ok and _str_member(o, String("title"), c.output_title)
            ok = ok and _str_member(o, String("summary"), c.output_summary)
    if not ok:
        return error_response(422, String("Invalid request: a member has the wrong type"))
    if c.name.byte_length() == 0:
        return error_response(422, String("Invalid request: name is required"))
    if not _is_sha(c.head_sha):
        return error_response(422, String("Invalid request: head_sha is not a commit sha"))
    if status.byte_length() > 0:
        if not is_check_status(status):
            return error_response(422, String("Invalid request: status is not valid"))
        c.status = status
    if conclusion.byte_length() > 0:
        if not is_check_conclusion(conclusion):
            return error_response(422, String("Invalid request: conclusion is not valid"))
        c.conclusion = conclusion
        c.status = String("completed")
    if c.status == "completed" and c.conclusion.byte_length() == 0:
        return error_response(422, String("Invalid request: completed needs a conclusion"))
    var out = check_run_json(c)
    if existing >= 0:
        st.check_runs[existing] = c^
        return json_response(200, out)
    st.check_runs.append(c^)
    return json_response(201, out)


def handle_installation_route(
    mut st: FakeState,
    name: String,
    path: String,
    params: List[String],
    query: String,
    body: List[UInt8],
    token: FakeToken,
    link_base: String,
) raises -> GitHubResponse:
    """One installation route for `token` (module header)."""
    if name == "apps/list-repos-accessible-to-installation":
        var items = List[String]()
        for i in range(len(st.repos)):
            if token.has_repo(st.repos[i].id):
                items.append(repo_json(st.repos[i]))
        return page_response(items, String("repositories"), query, link_base, String("/installation/repositories"))
    var ri = st.repo_index_by_name(params[0], params[1])
    if ri < 0 or not token.has_repo(st.repos[ri].id):
        return _not_found()
    var repo_id = st.repos[ri].id
    var prefix_len = (String("/repos/") + params[0] + String("/") + params[1]).byte_length()
    var link_path = String("/repositories/") + String(repo_id) + String(path[byte=prefix_len : path.byte_length()])
    var q = String("?") + query
    if name == "repos/get":
        return json_response(200, repo_json(st.repos[ri]))
    if name == "actions/list-workflow-runs-for-repo":
        var sha = query_param(q, String("head_sha"))
        var items = List[String]()
        for i in range(len(st.runs)):
            ref r = st.runs[i]
            if r.repo_id != repo_id:
                continue
            if sha and r.head_sha != sha.value():
                continue
            items.append(run_json(r, r.run_attempt))
        return page_response(items, String("workflow_runs"), query, link_base, link_path)
    if name == "actions/get-workflow-run" or name == "actions/get-workflow-run-attempt":
        var x = st.run_index(repo_id, _id(params[2]))
        if x < 0:
            return _not_found()
        var attempt = st.runs[x].run_attempt
        if name == "actions/get-workflow-run-attempt":
            attempt = _id(params[3])
            if attempt > st.runs[x].run_attempt:
                return _not_found()
        return json_response(200, run_json(st.runs[x], attempt))
    if name == "actions/list-jobs-for-workflow-run" or name == "actions/list-jobs-for-workflow-run-attempt":
        var x = st.run_index(repo_id, _id(params[2]))
        if x < 0:
            return _not_found()
        var attempt = st.runs[x].run_attempt
        if name == "actions/list-jobs-for-workflow-run-attempt":
            attempt = _id(params[3])
            if attempt > st.runs[x].run_attempt:
                return _not_found()
        var items = List[String]()
        for i in range(len(st.jobs)):
            ref j = st.jobs[i]
            if j.run_id == st.runs[x].id and j.run_attempt == attempt:
                items.append(job_json(j))
        return page_response(items, String("jobs"), query, link_base, link_path)
    if name == "actions/get-job-for-workflow-run":
        var job_id = _id(params[2])
        for i in range(len(st.jobs)):
            if st.jobs[i].id == job_id and st.jobs[i].repo_id == repo_id:
                return json_response(200, job_json(st.jobs[i]))
        return _not_found()
    if name == "actions/list-workflow-run-artifacts":
        var x = st.run_index(repo_id, _id(params[2]))
        if x < 0:
            return _not_found()
        var items = List[String]()
        for i in range(len(st.artifacts)):
            if st.artifacts[i].run_id == st.runs[x].id:
                items.append(artifact_json(st.artifacts[i]))
        return page_response(items, String("artifacts"), query, link_base, link_path)
    if name == "actions/get-artifact":
        var artifact_id = _id(params[2])
        for i in range(len(st.artifacts)):
            if st.artifacts[i].id == artifact_id and st.artifacts[i].repo_id == repo_id:
                return json_response(200, artifact_json(st.artifacts[i]))
        return _not_found()
    if name == "repos/get-collaborator-permission-level":
        var perm = st.repos[ri].permission_of(params[2])
        return json_response(
            200,
            String('{"permission":"') + perm + String('","user":{"login":"') + params[2] + String('"}}'),
        )
    if name == "checks/create":
        return _check_run_write(st, repo_id, body, -1)
    if name == "checks/update":
        var check_id = _id(params[2])
        for i in range(len(st.check_runs)):
            if st.check_runs[i].id == check_id and st.check_runs[i].repo_id == repo_id:
                return _check_run_write(st, repo_id, body, i)
        return _not_found()
    if name == "repos/get-content":
        var file_path = percent_decode(params[2])
        var git_ref = String("main")
        var asked = query_param(q, String("ref"))
        if asked:
            git_ref = percent_decode(asked.value())
        for i in range(len(st.repos[ri].files)):
            ref f = st.repos[ri].files[i]
            if f.git_ref == git_ref and f.path == file_path:
                return json_response(200, contents_json(f.path, f.content))
        return _not_found()
    return _not_found()
