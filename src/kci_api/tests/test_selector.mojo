# =============================================================================
# src/kci_api/tests/test_selector.mojo
#   The `--only` grammar: step:<name> and validation:<name>, every refusal by
#   its message, the scope words, and the prefix-safe evidence line.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    SCOPE_FULL,
    SCOPE_SELECTIVE,
    STEP_NAME_MAX_BYTES,
    is_step_name,
    parse_selector,
    parse_selectors,
    run_evidence_line,
    scope_of,
)


def _sel(text: String) -> String:
    try:
        return parse_selector(text).canonical()
    except e:
        return String(e)


def _all(texts: List[String]) -> String:
    try:
        var s = parse_selectors(texts)
        var out = String("")
        for i in range(len(s)):
            if i > 0:
                out += String(" ")
            out += s[i].canonical()
        return out^
    except e:
        return String(e)


def test_both_prefixes() raises:
    assert_equal(_sel(String("step:publish")), String("step:publish"))
    assert_equal(_sel(String("validation:smoke-1")), String("validation:smoke-1"))
    var s = parse_selector(String("step:build"))
    assert_true(s.is_step())
    assert_false(s.is_validation())
    assert_equal(s.name, String("build"))
    assert_true(parse_selector(String("validation:v")).is_validation())


def test_refusals() raises:
    assert_equal(_sel(String("publish")), String("--only 'publish' is not step:<name> or validation:<name>"))
    assert_equal(_sel(String("stage:prod")), String("--only 'stage:prod': 'stage' is not a selector kind (step or validation)"))
    assert_equal(_sel(String("Step:build")), String("--only 'Step:build': 'Step' is not a selector kind (step or validation)"))
    assert_equal(
        _sel(String("step:")),
        String("--only 'step:': name '' is not [a-z][a-z0-9-]*, at most 63 bytes, not ending in '-'"),
    )
    assert_true(_sel(String("step:Build")).find(String("name 'Build' is not")) >= 0)
    assert_true(_sel(String("step:build-")).find(String("name 'build-' is not")) >= 0)
    assert_true(_sel(String("step:a:b")).find(String("name 'a:b' is not")) >= 0)
    assert_true(_sel(String("step:1x")).find(String("name '1x' is not")) >= 0)


def test_name_length_edge() raises:
    assert_equal(STEP_NAME_MAX_BYTES, 63)
    var n63 = String("a") * 63
    var n64 = String("a") * 64
    assert_true(is_step_name(n63))
    assert_false(is_step_name(n64))
    assert_equal(_sel(String("step:") + n63), String("step:") + n63)
    assert_true(_sel(String("step:") + n64).find(String("at most 63 bytes")) >= 0)


def test_duplicate_refused_order_kept() raises:
    var t = List[String]()
    t.append(String("step:publish"))
    t.append(String("validation:smoke"))
    t.append(String("step:build"))
    assert_equal(_all(t), String("step:publish validation:smoke step:build"))
    t.append(String("step:publish"))
    assert_equal(_all(t), String("--only 'step:publish' is given twice"))
    # the same name under the other kind is a different selector
    var u = List[String]()
    u.append(String("step:smoke"))
    u.append(String("validation:smoke"))
    assert_equal(_all(u), String("step:smoke validation:smoke"))


def test_scope_and_evidence_line() raises:
    var none = List[String]()
    var one = List[String]()
    one.append(String("step:publish"))
    assert_equal(scope_of(none), String(SCOPE_FULL))
    assert_equal(scope_of(one), String(SCOPE_SELECTIVE))
    var full = run_evidence_line(String(SCOPE_FULL), String("release"), none, String("SUCCEEDED"))
    var sel = run_evidence_line(String(SCOPE_SELECTIVE), String("release"), one, String("SUCCEEDED"))
    assert_equal(full, String("kci: FULL run of stage release: SUCCEEDED"))
    assert_equal(
        sel, String("kci: SELECTIVE run of stage release (step:publish): SUCCEEDED -- not a full run")
    )
    # prefix-safe: a grep for the full line's prefix never matches a selective run
    assert_false(sel.startswith(String("kci: FULL run")))
    var refused = 0
    try:
        _ = run_evidence_line(String(SCOPE_FULL), String("release"), one, String("SUCCEEDED"))
    except e:
        refused += 1
    try:
        _ = run_evidence_line(String(SCOPE_SELECTIVE), String("release"), none, String("SUCCEEDED"))
    except e:
        refused += 1
    try:
        _ = run_evidence_line(String("PARTIAL"), String("release"), none, String("SUCCEEDED"))
    except e:
        refused += 1
    assert_equal(refused, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
