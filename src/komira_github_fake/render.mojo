# =============================================================================
# komira_github_fake/render.mojo -- the fake's objects as GitHub's JSON, and
#   GitHub's page shape and Link header.
# =============================================================================
#
# Each object carries the members GitHub documents for it that a client of
# the subset reads (ids, names, statuses, conclusions); not every member
# GitHub sends.
#
# Pages follow GitHub: `per_page` (default 30, at most 100) and `page`
# (default 1) from the query; the body is `{"total_count":N,"<key>":[...]}`;
# when there is a page after this one, a `Link` header names `next` and
# `last` (and `prev` and `first` after page 1), each an absolute URL under
# `link_base`. A repository's lists are linked under
# `/repositories/<id>/...`, as GitHub spells them, not the path that was
# asked for.
# =============================================================================

from komira_datetime import Timestamp, format_rfc3339
from komira_encoding import base64_encode
from komira_github import GitHubResponse, query_param
from komira_json import write_json_string

from .model import FakeArtifact, FakeCheckRun, FakeInstallation, FakeJob, FakeRepo, FakeRun


def js(s: String) -> String:
    """`s` as a JSON string literal."""
    var buf = List[UInt8]()
    write_json_string(buf, s)
    return String(unsafe_from_utf8=Span(buf))


def js_or_null(s: String) -> String:
    if s.byte_length() == 0:
        return String("null")
    return js(s)


def json_response(status: Int, body: String) -> GitHubResponse:
    var b = List[UInt8]()
    b.extend(Span(body.as_bytes()))
    var resp = GitHubResponse(status, b^)
    resp.add_header(String("Content-Type"), String("application/json; charset=utf-8"))
    return resp^


def error_response(status: Int, message: String) -> GitHubResponse:
    """`{"message":"<message>"}` with `status`."""
    return json_response(status, String('{"message":') + js(message) + String("}"))


def rfc3339(unix_s: Int64) raises -> String:
    return format_rfc3339(Timestamp(Int(unix_s), 0))


def permissions_json(perms: List[String]) -> String:
    """`["contents:read", ...]` as GitHub's `{"contents":"read",...}`."""
    var out = String("{")
    for i in range(len(perms)):
        var c = perms[i].find(":")
        if c < 0:
            continue
        if out.byte_length() > 1:
            out += ","
        out += js(String(perms[i][byte=0:c])) + String(":") + js(
            String(perms[i][byte = c + 1 : perms[i].byte_length()])
        )
    return out + String("}")


def repo_json(r: FakeRepo) -> String:
    return (
        String('{"id":')
        + String(r.id)
        + String(',"name":')
        + js(r.name)
        + String(',"full_name":')
        + js(r.full_name())
        + String(',"owner":{"login":')
        + js(r.owner)
        + String('},"private":true}')
    )


def installation_json(inst: FakeInstallation) -> String:
    var suspended = String("null")
    if inst.suspended:
        suspended = js(String("2026-09-01T00:00:00Z"))
    return (
        String('{"id":')
        + String(inst.id)
        + String(',"account":{"login":')
        + js(inst.account)
        + String('},"repository_selection":"selected","permissions":')
        + permissions_json(inst.permissions)
        + String(',"suspended_at":')
        + suspended
        + String("}")
    )


def run_json(r: FakeRun, attempt: Int64) -> String:
    return (
        String('{"id":')
        + String(r.id)
        + String(',"head_sha":')
        + js(r.head_sha)
        + String(',"status":')
        + js(r.status)
        + String(',"conclusion":')
        + js_or_null(r.conclusion)
        + String(',"run_attempt":')
        + String(attempt)
        + String(',"repository":{"id":')
        + String(r.repo_id)
        + String("}}")
    )


def job_json(j: FakeJob) -> String:
    return (
        String('{"id":')
        + String(j.id)
        + String(',"run_id":')
        + String(j.run_id)
        + String(',"run_attempt":')
        + String(j.run_attempt)
        + String(',"name":')
        + js(j.name)
        + String(',"status":')
        + js(j.status)
        + String(',"conclusion":')
        + js_or_null(j.conclusion)
        + String("}")
    )


def artifact_json(a: FakeArtifact) -> String:
    return (
        String('{"id":')
        + String(a.id)
        + String(',"name":')
        + js(a.name)
        + String(',"size_in_bytes":')
        + String(a.size_in_bytes)
        + String(',"expired":false,"workflow_run":{"id":')
        + String(a.run_id)
        + String("}}")
    )


def check_run_json(c: FakeCheckRun) -> String:
    var output = String('{"title":') + js_or_null(c.output_title) + String(',"summary":') + js_or_null(
        c.output_summary
    ) + String("}")
    return (
        String('{"id":')
        + String(c.id)
        + String(',"name":')
        + js(c.name)
        + String(',"head_sha":')
        + js(c.head_sha)
        + String(',"status":')
        + js(c.status)
        + String(',"conclusion":')
        + js_or_null(c.conclusion)
        + String(',"details_url":')
        + js_or_null(c.details_url)
        + String(',"external_id":')
        + js_or_null(c.external_id)
        + String(',"output":')
        + output
        + String("}")
    )


def contents_json(path: String, content: List[UInt8]) -> String:
    """A file as `repos/get-content` returns it: base64 with a line break
    after every 60 characters, as GitHub wraps it."""
    var b64 = base64_encode(Span[UInt8, origin_of(content)](content))
    var wrapped = String("")
    var b = b64.as_bytes()
    var start = 0
    while start < len(b):
        var end = start + 60
        if end > len(b):
            end = len(b)
        wrapped += String(b64[byte=start:end]) + String("\n")
        start = end
    var name = path
    var slash = path.rfind("/")
    if slash >= 0:
        name = String(path[byte = slash + 1 : path.byte_length()])
    return (
        String('{"type":"file","encoding":"base64","size":')
        + String(len(content))
        + String(',"name":')
        + js(name)
        + String(',"path":')
        + js(path)
        + String(',"content":')
        + js(wrapped)
        + String("}")
    )


def _small_int(text: Optional[String], default: Int) -> Int:
    """A decimal of 1-6 digits, else `default`."""
    if not text:
        return default
    var b = text.value().as_bytes()
    if len(b) == 0 or len(b) > 6:
        return default
    var v = 0
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return default
        v = v * 10 + Int(b[i] - UInt8(ord("0")))
    return v


def page_response(
    items: List[String], items_key: String, query: String, link_base: String, link_path: String
) -> GitHubResponse:
    """One page of `items` (module header)."""
    var q = String("?") + query
    var per_page = _small_int(query_param(q, String("per_page")), 30)
    if per_page < 1:
        per_page = 30
    if per_page > 100:
        per_page = 100
    var page = _small_int(query_param(q, String("page")), 1)
    if page < 1:
        page = 1
    var total = len(items)
    var last = (total + per_page - 1) // per_page
    if last < 1:
        last = 1
    var body = String('{"total_count":') + String(total) + String(",") + js(items_key) + String(":[")
    var start = (page - 1) * per_page
    var n = 0
    for i in range(start, start + per_page):
        if i >= total:
            break
        if n > 0:
            body += ","
        body += items[i]
        n += 1
    body += "]}"
    var resp = json_response(200, body)
    if page < last or page > 1:
        var base = link_base + link_path + String("?per_page=") + String(per_page) + String("&page=")
        var link = String("")
        if page > 1:
            link += String("<") + base + String(page - 1) + String('>; rel="prev", ')
        if page < last:
            link += String("<") + base + String(page + 1) + String('>; rel="next", ')
        link += String("<") + base + String(last) + String('>; rel="last", ')
        link += String("<") + base + String("1") + String('>; rel="first"')
        resp.add_header(String("Link"), link^)
    return resp^
