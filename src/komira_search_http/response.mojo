# =============================================================================
# response.mojo — JSON HttpResponse builders
# =============================================================================
#
# The thin String-body -> HttpResponse helpers. The shim builds its
# `application/json` response from an already-serialized JSON body string, so
# it needs no dependency on an API package. Like `HttpResponse.ok`, but it sets
# `content-type: application/json` (the factory sets text/plain) and an
# accurate content-length.
#
# Pure value functions over String -> HttpResponse; no pointers.
# =============================================================================

from komira_http_core.codec.types import HttpResponse


def json_response(var body: String, status: Int32) -> HttpResponse:
    """Build an `application/json` HttpResponse from an ALREADY-serialized JSON
    body string + a status. Sets content-type + an accurate content-length."""
    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/json")
    var bytes_ref = body.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        r.body.append(bytes_ref[i])
        i = i + 1
    r.headers[String("content-length")] = String(n)
    return r^


def ok_json(var body: String) -> HttpResponse:
    """200 OK with an already-serialized JSON body."""
    return json_response(body^, Int32(200))
