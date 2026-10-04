# =============================================================================
# tests/test_L3_cors.mojo
# =============================================================================
#
# CorsMiddleware unit tests
#
# Coverage:
#   * Preflight (OPTIONS + Access-Control-Request-Method): short-circuits
#     with 204 + ACAO/ACAM/ACAH/MAX-AGE
#   * Simple request (GET): no short-circuit; after() adds ACAO header
#   * Plain OPTIONS without Access-Control-Request-Method: passes through
#   * Strict config: custom allow_origin overrides "*"
#   * Idempotency: if response already has ACAO, after() is a no-op
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.middleware import (
    CorsConfig,
    CorsMiddleware,
    RequestContext,
)


def _make_preflight_request(path: String) -> HttpRequest:
    """OPTIONS + Origin + Access-Control-Request-Method headers."""
    var r = HttpRequest(HttpMethod.options(), path)
    r.headers[String("origin")] = String("https://example.com")
    r.headers[String("access-control-request-method")] = String("POST")
    r.headers[String("access-control-request-headers")] = String(
        "Content-Type, X-Request-Id"
    )
    return r^


def _make_simple_request(method: HttpMethod, path: String) -> HttpRequest:
    var r = HttpRequest(method, path)
    r.headers[String("origin")] = String("https://example.com")
    return r^


def test_preflight_short_circuits_with_204() raises:
    """Preflight OPTIONS → 204 with ACAO/ACAM/ACAH/MAX-AGE."""
    var cors = CorsMiddleware.permissive()
    var req = _make_preflight_request(String("/api/items"))
    var ctx = RequestContext.new()
    var resp_opt = cors.before(req, ctx)
    assert_true(Bool(resp_opt))
    ref resp = resp_opt.value()
    assert_equal(Int(resp.status), 204)
    assert_true(
        resp.headers.__contains__(String("access-control-allow-origin"))
    )
    assert_equal(
        resp.headers[String("access-control-allow-origin")], String("*")
    )
    assert_true(
        resp.headers.__contains__(String("access-control-allow-methods"))
    )
    assert_true(
        resp.headers.__contains__(String("access-control-allow-headers"))
    )
    assert_true(
        resp.headers.__contains__(String("access-control-max-age"))
    )


def test_simple_get_passes_through_before() raises:
    """A simple GET (not OPTIONS) doesn't short-circuit in before()."""
    var cors = CorsMiddleware.permissive()
    var req = _make_simple_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    var resp_opt = cors.before(req, ctx)
    assert_false(Bool(resp_opt))


def test_simple_get_after_adds_acao_header() raises:
    """after() adds Access-Control-Allow-Origin to a simple-request response."""
    var cors = CorsMiddleware.permissive()
    var req = _make_simple_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    _ = cors.before(req, ctx)
    var resp = HttpResponse(status=Int32(200))
    cors.after(req, resp, ctx)
    assert_true(
        resp.headers.__contains__(String("access-control-allow-origin"))
    )
    assert_equal(
        resp.headers[String("access-control-allow-origin")], String("*")
    )
    # ACAM and ACAH are preflight-only — NOT added to simple-request responses.
    assert_false(
        resp.headers.__contains__(String("access-control-allow-methods"))
    )


def test_plain_options_passes_through() raises:
    """An OPTIONS request WITHOUT Access-Control-Request-Method is
    NOT a preflight — passes through."""
    var cors = CorsMiddleware.permissive()
    var req = HttpRequest(HttpMethod.options(), String("/x"))
    var ctx = RequestContext.new()
    var resp_opt = cors.before(req, ctx)
    assert_false(Bool(resp_opt))


def test_strict_config_custom_origin() raises:
    """Strict CorsConfig with specific allow_origin overrides the
    permissive "*" default."""
    var cfg = CorsConfig(
        allow_origin=String("https://only-this.example"),
        allow_methods=String("GET, POST"),
        allow_headers=String("Content-Type"),
        max_age_seconds=600,
        preflight_status=Int32(204),
    )
    var cors = CorsMiddleware.with_config(cfg^)
    var req = _make_preflight_request(String("/api/x"))
    var ctx = RequestContext.new()
    var resp_opt = cors.before(req, ctx)
    assert_true(Bool(resp_opt))
    ref resp = resp_opt.value()
    assert_equal(
        resp.headers[String("access-control-allow-origin")],
        String("https://only-this.example"),
    )
    assert_equal(
        resp.headers[String("access-control-allow-methods")],
        String("GET, POST"),
    )
    assert_equal(
        resp.headers[String("access-control-max-age")], String(600)
    )


def test_after_idempotent_if_acao_already_present() raises:
    """If after() sees a response that already has ACAO (e.g. set by
    a handler or another middleware), it does NOT overwrite."""
    var cors = CorsMiddleware.permissive()
    var req = _make_simple_request(HttpMethod.get(), String("/x"))
    var ctx = RequestContext.new()
    var resp = HttpResponse(status=Int32(200))
    # Pre-set ACAO to a non-default value.
    resp.headers[String("access-control-allow-origin")] = String(
        "https://override.example"
    )
    cors.after(req, resp, ctx)
    # CORS.after does NOT overwrite.
    assert_equal(
        resp.headers[String("access-control-allow-origin")],
        String("https://override.example"),
    )


def main() raises:
    test_preflight_short_circuits_with_204()
    test_simple_get_passes_through_before()
    test_simple_get_after_adds_acao_header()
    test_plain_options_passes_through()
    test_strict_config_custom_origin()
    test_after_idempotent_if_acao_already_present()
    print("test_L3_cors: OK")
