# =============================================================================
# src/komira_http/tests/test_header_map.mojo — HeaderMap unit tests
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.client.header_map import (
    HeaderMap,
    ci_byte_eq_sab_static,
    parse_sab_int64,
    sab_to_string,
    sab_to_string_lower,
)


def test_empty_is_empty() raises:
    var h = HeaderMap()
    assert_true(h.is_empty())
    assert_equal(h.len(), 0)
    assert_false(h.contains(String("anything")))


def test_insert_one() raises:
    var h = HeaderMap()
    h.insert(String("Host"), String("example.com"))
    assert_equal(h.len(), 1)
    assert_true(h.contains(String("host")))
    assert_true(h.contains(String("HOST")))
    assert_true(h.contains(String("Host")))
    var v = h.get(String("HoSt"))
    assert_true(v.__bool__())
    assert_equal(v.value(), String("example.com"))


def test_insert_replaces() raises:
    var h = HeaderMap()
    h.insert(String("X-Header"), String("first"))
    h.insert(String("X-Header"), String("second"))
    assert_equal(h.len(), 1)
    var v = h.get(String("X-Header"))
    assert_equal(v.value(), String("second"))


def test_append_keeps_all() raises:
    var h = HeaderMap()
    h.append(String("Set-Cookie"), String("a=1"))
    h.append(String("Set-Cookie"), String("b=2"))
    h.append(String("Set-Cookie"), String("c=3"))
    assert_equal(h.len(), 3)
    var all = h.get_all(String("set-cookie"))
    assert_equal(all.__len__(), 3)
    assert_equal(all[0], String("a=1"))
    assert_equal(all[1], String("b=2"))
    assert_equal(all[2], String("c=3"))


def test_get_returns_first() raises:
    var h = HeaderMap()
    h.append(String("Warning"), String("199 - alpha"))
    h.append(String("Warning"), String("199 - beta"))
    var v = h.get(String("Warning"))
    assert_equal(v.value(), String("199 - alpha"))


def test_remove() raises:
    var h = HeaderMap()
    h.append(String("X-Trace"), String("a"))
    h.append(String("X-Trace"), String("b"))
    h.insert(String("Host"), String("example.com"))
    assert_equal(h.len(), 3)
    h.remove(String("x-trace"))
    assert_equal(h.len(), 1)
    assert_false(h.contains(String("X-Trace")))
    assert_true(h.contains(String("Host")))


def test_insert_replaces_appended() raises:
    """insert() must replace ALL existing entries for the name."""
    var h = HeaderMap()
    h.append(String("Vary"), String("Accept"))
    h.append(String("Vary"), String("Origin"))
    assert_equal(h.len(), 2)
    h.insert(String("Vary"), String("*"))
    assert_equal(h.len(), 1)
    assert_equal(h.get(String("Vary")).value(), String("*"))


def test_case_insensitive_match() raises:
    var h = HeaderMap()
    h.insert(String("Content-Type"), String("application/json"))
    assert_true(h.contains(String("CONTENT-TYPE")))
    assert_true(h.contains(String("content-type")))
    assert_true(h.contains(String("Content-type")))
    assert_equal(
        h.get(String("CONTENT-TYPE")).value(),
        String("application/json"),
    )


def test_get_missing_is_none() raises:
    var h = HeaderMap()
    h.insert(String("Host"), String("example.com"))
    var v = h.get(String("Authorization"))
    assert_false(v.__bool__())


def test_get_all_empty_is_empty_list() raises:
    var h = HeaderMap()
    var all = h.get_all(String("X-Missing"))
    assert_equal(all.__len__(), 0)


def test_iteration_order_preserves_insert() raises:
    var h = HeaderMap()
    h.insert(String("Host"), String("example.com"))
    h.insert(String("User-Agent"), String("test/1.0"))
    h.insert(String("Accept"), String("*/*"))
    var es = h.entries()
    assert_equal(es.__len__(), 3)
    assert_equal(es[0].name, String("host"))
    assert_equal(es[1].name, String("user-agent"))
    assert_equal(es[2].name, String("accept"))


def test_get_view_returns_value_bytes() raises:
    """Option C: get_view returns an SAB clone whose bytes match the
    inserted value, with no String materialization."""
    var h = HeaderMap()
    h.insert(String("Content-Type"), String("application/json"))
    var v = h.get_view(String("content-type"))
    assert_true(v.__bool__())
    var sab = v.value().copy()
    assert_equal(sab.length, 16)
    # Materialize through helper to confirm byte equality.
    assert_equal(sab_to_string(sab), String("application/json"))


def test_get_view_missing_is_none() raises:
    var h = HeaderMap()
    h.insert(String("Host"), String("example.com"))
    var v = h.get_view(String("Authorization"))
    assert_false(v.__bool__())


def test_get_view_static_matches_get_view() raises:
    """get_view_static against a StaticString literal must return the
    same value as get_view against a runtime String of the same name."""
    var h = HeaderMap()
    h.insert(String("Content-Length"), String("1024"))
    var v_dyn = h.get_view(String("content-length"))
    var v_static = h.get_view_static("content-length")
    assert_true(v_dyn.__bool__())
    assert_true(v_static.__bool__())
    assert_equal(
        sab_to_string(v_dyn.value()),
        sab_to_string(v_static.value()),
    )


def test_get_int64_parses_decimal() raises:
    """Option C: get_int64 parses a non-negative Int64 directly from
    value bytes — no String materialization, no Int(String) round-trip."""
    var h = HeaderMap()
    h.insert(String("Content-Length"), String("1048576"))
    var n = h.get_int64(String("Content-Length"))
    assert_true(n.__bool__())
    assert_equal(n.value(), Int64(1048576))


def test_get_int64_missing_is_none() raises:
    var h = HeaderMap()
    var n = h.get_int64(String("Content-Length"))
    assert_false(n.__bool__())


def test_get_int64_non_digit_is_none() raises:
    """parse_sab_int64 returns None on any non-digit byte (no parse-int
    exception path)."""
    var h = HeaderMap()
    h.insert(String("Content-Length"), String("12k"))
    var n = h.get_int64(String("Content-Length"))
    assert_false(n.__bool__())


def test_contains_static() raises:
    """contains_static against a StaticString literal must yield the
    same Bool as contains against a runtime String of the same name."""
    var h = HeaderMap()
    h.insert(String("host"), String("example.com"))
    assert_true(h.contains_static("host"))
    assert_true(h.contains_static("HOST"))
    assert_false(h.contains_static("authorization"))


def test_entry_at_view_yields_sab_pair() raises:
    """entry_at_view returns the SAB-backed name + value pair. Byte-
    compares against the wire-form name (not lowercased) — Option-C
    sigv4_layer uses ci_byte_eq_sab_static to do CI matching."""
    var h = HeaderMap()
    h.insert(String("X-Custom-Header"), String("value-abc"))
    var entry = h.entry_at_view(0)
    # Names are stored in wire form; lowercasing is on materialization.
    assert_equal(sab_to_string_lower(entry.name), String("x-custom-header"))
    assert_equal(sab_to_string(entry.value), String("value-abc"))


def test_ci_byte_eq_sab_static_canonical() raises:
    """The free-function ci_byte_eq_sab_static is case-insensitive on
    both sides; used by sigv4_layer / h2_client for byte-direct skip-
    list compares against header-name literals."""
    var h = HeaderMap()
    h.insert(String("AUTHORIZATION"), String("Bearer x"))
    var entry = h.entry_at_view(0)
    assert_true(ci_byte_eq_sab_static(entry.name, "authorization"))
    assert_true(ci_byte_eq_sab_static(entry.name, "AUTHORIZATION"))
    assert_false(ci_byte_eq_sab_static(entry.name, "host"))


def test_parse_sab_int64_empty_is_none() raises:
    """Standalone helper: empty SAB returns None (mirrors the empty-
    Content-Length header semantics)."""
    var h = HeaderMap()
    h.insert(String("X-Empty"), String(""))
    var entry = h.entry_at_view(0)
    var n = parse_sab_int64(entry.value)
    assert_false(n.__bool__())


def test_clear() raises:
    var h = HeaderMap()
    h.insert(String("Host"), String("example.com"))
    h.append(String("X-A"), String("1"))
    h.append(String("X-A"), String("2"))
    assert_equal(h.len(), 3)
    h.clear()
    assert_equal(h.len(), 0)
    assert_true(h.is_empty())


def main() raises:
    test_empty_is_empty()
    test_insert_one()
    test_insert_replaces()
    test_append_keeps_all()
    test_get_returns_first()
    test_remove()
    test_insert_replaces_appended()
    test_case_insensitive_match()
    test_get_missing_is_none()
    test_get_all_empty_is_empty_list()
    test_iteration_order_preserves_insert()
    # Option C migration view-API regressions:
    test_get_view_returns_value_bytes()
    test_get_view_missing_is_none()
    test_get_view_static_matches_get_view()
    test_get_int64_parses_decimal()
    test_get_int64_missing_is_none()
    test_get_int64_non_digit_is_none()
    test_contains_static()
    test_entry_at_view_yields_sab_pair()
    test_ci_byte_eq_sab_static_canonical()
    test_parse_sab_int64_empty_is_none()
    test_clear()
    print("OK: test_header_map")
