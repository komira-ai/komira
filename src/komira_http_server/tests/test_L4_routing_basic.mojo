# =============================================================================
# tests/test_L4_routing_basic.mojo
# =============================================================================
#
# L4 routing unit tests ( L4).
# Coverage:
#   * Exact path match            (`GET /healthz`)
#   * Method dispatch             (same path, different methods)
#   * 404 fallback                (no path match)
#   * 405 disposition helper      (path matched but method didn't)
#   * Param match                 (`GET /users/:id` → path_params["id"])
#   * Multiple params in one path
#   * Wildcard prefix match       (`GET /api/*`)
#   * Route-conflict detection    (duplicate registration raises)
#   * Bad-pattern rejection       (empty pattern, lone `:`, mid-pattern `*`)
#   * Method-set parsing          (HttpMethod.parse round-trip)
# =============================================================================

from std.collections.dict import Dict
from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HttpMethod,
)
from komira_http_server.routing import Router


def test_method_parse_round_trip() raises:
    """HttpMethod.parse for the 7 canonical methods + UNKNOWN."""
    assert_equal(Int(HttpMethod.parse("GET").code), Int(HTTP_METHOD_GET))
    assert_equal(Int(HttpMethod.parse("POST").code), Int(HTTP_METHOD_POST))
    assert_equal(Int(HttpMethod.parse("PUT").code), 3)
    assert_equal(Int(HttpMethod.parse("DELETE").code), 4)
    assert_equal(Int(HttpMethod.parse("PATCH").code), 5)
    assert_equal(Int(HttpMethod.parse("HEAD").code), 6)
    assert_equal(Int(HttpMethod.parse("OPTIONS").code), 7)
    assert_true(HttpMethod.parse("FOO").is_unknown())
    assert_true(HttpMethod.parse("").is_unknown())
    # Names round-trip.
    assert_equal(HttpMethod.get().name(), String("GET"))
    assert_equal(HttpMethod.post().name(), String("POST"))


def test_exact_path_match() raises:
    """Exact-path route match returns the registered handler id."""
    var r = Router()
    r.add(HttpMethod.get(), "/healthz", 42)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/healthz", params)
    assert_true(hid.__bool__())
    assert_equal(hid.value(), 42)


def test_method_dispatch_distinguishes_methods() raises:
    """Same path, two methods → two handlers."""
    var r = Router()
    r.add(HttpMethod.get(), "/users", 1)
    r.add(HttpMethod.post(), "/users", 2)
    var params = Dict[String, String]()
    var hg = r.match_route(HttpMethod.get(), "/users", params)
    assert_true(hg.__bool__())
    assert_equal(hg.value(), 1)
    var hp = r.match_route(HttpMethod.post(), "/users", params)
    assert_true(hp.__bool__())
    assert_equal(hp.value(), 2)


def test_404_fallback_no_match() raises:
    """No registered route → match_route returns None."""
    var r = Router()
    r.add(HttpMethod.get(), "/healthz", 0)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/missing", params)
    assert_false(hid.__bool__())


def test_405_disposition_via_has_path_match() raises:
    """Path matched but method didn't → match_route is None but
    has_path_match() is True. Caller uses this disambiguation to return
    405 vs 404."""
    var r = Router()
    r.add(HttpMethod.get(), "/orders/:id", 0)
    var params = Dict[String, String]()
    # POST /orders/42 — path matches, method doesn't.
    var hid = r.match_route(HttpMethod.post(), "/orders/42", params)
    assert_false(hid.__bool__())
    assert_true(r.has_path_match("/orders/42"))
    assert_false(r.has_path_match("/totally/different"))


def test_allowed_methods_are_the_paths_routes() raises:
    """`allowed_methods(path)`: the method of every route matching the path,
    each once, in registration order; a route of another path (or of the
    same prefix) is not counted. Catches a list that stops at the first
    matching route: the last route registered for the path is DELETE."""
    var r = Router()
    r.add(HttpMethod.get(), "/orders/:id", 0)
    r.add(HttpMethod.get(), "/orders", 1)
    r.add(HttpMethod.put(), "/orders/:id", 2)
    r.add(HttpMethod.get(), "/orders/:id/lines", 3)
    r.add(HttpMethod.put(), "/orders/*", 4)
    r.add(HttpMethod.delete(), "/orders/:id", 5)
    var got = r.allowed_methods("/orders/42")
    assert_equal(len(got), 3)
    assert_true(got[0] == HttpMethod.get())
    assert_true(got[1] == HttpMethod.put())
    assert_true(got[2] == HttpMethod.delete())
    assert_equal(len(r.allowed_methods("/invoices/1")), 0)


def test_param_match() raises:
    """`/users/:id` matches `/users/42` and binds id=42."""
    var r = Router()
    r.add(HttpMethod.get(), "/users/:id", 7)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/users/42", params)
    assert_true(hid.__bool__())
    assert_equal(hid.value(), 7)
    var got_id = params.find(String("id"))
    assert_true(got_id.__bool__())
    assert_equal(got_id.value(), String("42"))


def test_multiple_params() raises:
    """`/users/:uid/posts/:pid` binds both params."""
    var r = Router()
    r.add(HttpMethod.get(), "/users/:uid/posts/:pid", 9)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/users/alice/posts/42", params)
    assert_true(hid.__bool__())
    assert_equal(hid.value(), 9)
    var uid = params.find(String("uid"))
    var pid = params.find(String("pid"))
    assert_true(uid.__bool__())
    assert_true(pid.__bool__())
    assert_equal(uid.value(), String("alice"))
    assert_equal(pid.value(), String("42"))


def test_param_no_match_when_length_differs() raises:
    """Param pattern is fixed-arity; an extra segment shouldn't match."""
    var r = Router()
    r.add(HttpMethod.get(), "/users/:id", 0)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/users/42/extra", params)
    assert_false(hid.__bool__())


def test_wildcard_prefix() raises:
    """`/api/*` matches `/api/v1/anything/...`."""
    var r = Router()
    r.add(HttpMethod.get(), "/api/*", 5)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/api/v1/health", params)
    assert_true(hid.__bool__())
    assert_equal(hid.value(), 5)
    # /api itself (no children) still matches the wildcard.
    var hid2 = r.match_route(HttpMethod.get(), "/api", params)
    assert_true(hid2.__bool__())


def test_wildcard_does_not_match_other_prefixes() raises:
    """`/api/*` does NOT match `/other`."""
    var r = Router()
    r.add(HttpMethod.get(), "/api/*", 0)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/other", params)
    assert_false(hid.__bool__())


def test_route_conflict_duplicate_registration_raises() raises:
    """Registering the same (method, pattern) twice raises."""
    var r = Router()
    r.add(HttpMethod.get(), "/users/:id", 1)
    var raised = False
    try:
        r.add(HttpMethod.get(), "/users/:id", 2)
    except e:
        raised = True
        _ = e
    assert_true(raised)


def test_bad_pattern_empty_param_raises() raises:
    """A lone ':' segment (`/users/:`) raises."""
    var r = Router()
    var raised = False
    try:
        r.add(HttpMethod.get(), "/users/:", 0)
    except e:
        raised = True
        _ = e
    assert_true(raised)


def test_bad_pattern_midwildcard_raises() raises:
    """Wildcard '*' must be the tail segment; `/api/*/x` raises."""
    var r = Router()
    var raised = False
    try:
        r.add(HttpMethod.get(), "/api/*/x", 0)
    except e:
        raised = True
        _ = e
    assert_true(raised)


def test_root_path_match() raises:
    """`/` matches the empty segment list (request to the root)."""
    var r = Router()
    r.add(HttpMethod.get(), "/", 99)
    var params = Dict[String, String]()
    var hid = r.match_route(HttpMethod.get(), "/", params)
    assert_true(hid.__bool__())
    assert_equal(hid.value(), 99)


def test_router_len() raises:
    """Router.len reflects registration count."""
    var r = Router()
    assert_equal(r.len(), 0)
    r.add(HttpMethod.get(), "/a", 0)
    r.add(HttpMethod.get(), "/b", 1)
    r.add(HttpMethod.post(), "/c", 2)
    assert_equal(r.len(), 3)


def main() raises:
    test_method_parse_round_trip()
    test_exact_path_match()
    test_method_dispatch_distinguishes_methods()
    test_404_fallback_no_match()
    test_405_disposition_via_has_path_match()
    test_allowed_methods_are_the_paths_routes()
    test_param_match()
    test_multiple_params()
    test_param_no_match_when_length_differs()
    test_wildcard_prefix()
    test_wildcard_does_not_match_other_prefixes()
    test_route_conflict_duplicate_registration_raises()
    test_bad_pattern_empty_param_raises()
    test_bad_pattern_midwildcard_raises()
    test_root_path_match()
    test_router_len()
    print("PASS komira_http L4 routing basic")
