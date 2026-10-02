# =============================================================================
# src/kci_build/tests/test_build_report.mojo
#   Reading buck2's build report. The control text has the shape buck2
#   writes (captured from a real `buck2 build --build-report` of a target and
#   one of its sub-targets): cell-qualified keys, sub-target outputs under the
#   target's own key, paths relative to project_root.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import parse_build_report

comptime _REPORT = """{
  "trace_id": "t",
  "success": false,
  "results": {
    "komira//pkgs:alpha": {
      "success": "SUCCESS",
      "outputs": {
        "DEFAULT": ["buck-out/v2/art/komira/h/pkgs/__alpha__/alpha-1.0.0-h0_0.conda"],
        "manifest": ["buck-out/v2/art/komira/h/pkgs/__alpha__/alpha.json"]
      },
      "other_outputs": {},
      "configured": {},
      "errors": []
    },
    "komira//pkgs:beta": {
      "success": "FAIL",
      "outputs": {},
      "errors": [{"message_content": "Action failed: compile beta"}, "raw"]
    },
    "komira//pkgs:gamma": {
      "success": "SUCCESS",
      "outputs": {"DEFAULT": ["/abs/g1", "/abs/g2"]},
      "errors": []
    }
  },
  "failures": {},
  "project_root": "/repo",
  "truncated": false,
  "strings": {}
}"""


def _targets() -> List[String]:
    var t = List[String]()
    t.append(String("//pkgs:alpha"))
    t.append(String("//pkgs:beta"))
    t.append(String("//pkgs:gamma"))
    t.append(String("//pkgs:delta"))
    return t^


def test_results_follow_the_requested_order() raises:
    var r = parse_build_report(String(_REPORT), String("r.json"), _targets(), String("manifest"))
    assert_equal(len(r), 4)
    assert_true(r[0].found)
    assert_true(r[0].success)
    assert_equal(len(r[0].default_outputs), 1)
    assert_equal(
        r[0].default_outputs[0],
        String("/repo/buck-out/v2/art/komira/h/pkgs/__alpha__/alpha-1.0.0-h0_0.conda"),
    )
    assert_equal(r[0].sub_outputs[0], String("/repo/buck-out/v2/art/komira/h/pkgs/__alpha__/alpha.json"))
    assert_true(r[1].found)
    assert_false(r[1].success)
    assert_equal(r[1].error, String('Action failed: compile beta; "raw"'))
    assert_equal(len(r[2].default_outputs), 2)
    assert_equal(r[2].default_outputs[0], String("/abs/g1"))
    assert_equal(len(r[2].sub_outputs), 0)
    assert_false(r[3].found)


def test_a_broken_report_is_refused() raises:
    var msgs = List[String]()
    var texts = List[String]()
    texts.append(String("{"))
    texts.append(String('{"success": true}'))
    texts.append(String('{"results": []}'))
    texts.append(String('{"results": {"c//pkgs:alpha": {"success": "SUCCESS", "outputs": {"DEFAULT": "x"}}}}'))
    for i in range(len(texts)):
        try:
            _ = parse_build_report(texts[i], String("r.json"), _targets(), String("manifest"))
            msgs.append(String("<parsed>"))
        except e:
            msgs.append(String(e))
    assert_true(msgs[0].startswith(String("build report 'r.json': not JSON: ")))
    assert_equal(msgs[1], String("build report 'r.json': has no 'results' object"))
    assert_equal(msgs[2], String("build report 'r.json': 'results' is not an object"))
    assert_equal(msgs[3], String("build report 'r.json': outputs 'DEFAULT' is not a list"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
