# =============================================================================
# test_transport_split_render.mojo — the transport-split render gate: the
#   ROUTING the split needs, rendered for the two clouds whose edge can express it.
# =============================================================================
#
# WHAT THIS PINS, and why each case is a real defect it would otherwise ship:
#   (1) PRIORITY ORDER — every exotic rule precedes the managed catch-all. The
#       reverse order routes PROPFIND to the gateway that 405s it, silently.
#   (2) ONE RULE PER (prefix, method) on GCP — `headerMatches[]` entries are
#       ANDed, so one rule listing five `:method` matches matches NOTHING. The
#       shape that reads correct and routes nothing.
#   (3) `lb_prefix_of` ROUNDS UP. A prefix narrower than the pattern leaves real
#       requests falling through to the managed backend, which cannot serve them.
#   (4) The AWS render packs methods THREE to a rule — the ALB's documented
#       per-condition value limit, and the reason caldav's rule count stays sane.
#   (5) ⚠ THE GIT SHAPE. `/{repo}/...` truncates to `/`, which would route the
#       whole site to the exotic backend. Pinned as a caller hazard rather than
#       silently "fixed", because the fix is a suffix discriminator, not a prefix.
#
# HERMETIC: pure String renders. No cloud, no network, no store.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from kci_edge import (
    RouteFacet,
    lb_prefix_of,
    exotic_methods_of,
    exotic_prefixes_of,
    render_gcp_route_rules,
    render_aws_listener_rules,
)


def _count(haystack: String, needle: String) -> Int:
    """Count NON-overlapping occurrences — used to assert a rule COUNT rather
    than merely that a rule exists."""
    var n = 0
    var start = 0
    var hb = haystack.byte_length()
    var nb = needle.byte_length()
    if nb == 0:
        return 0
    while start + nb <= hb:
        if String(haystack[byte=start : start + nb]) == needle:
            n += 1
            start += nb
        else:
            start += 1
    return n


def _caldav_shape() -> List[RouteFacet]:
    """The caldav shape: two prefixes, three extension verbs, plus managed rows
    that share a path with them."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/healthz")))
    f.append(RouteFacet(String("GET"), String("/calendars/{o}/{c}/{i}")))
    f.append(RouteFacet(String("PUT"), String("/calendars/{o}/{c}/{i}")))
    f.append(RouteFacet(String("PROPFIND"), String("/calendars/{o}/{c}/{i}")))
    f.append(RouteFacet(String("REPORT"), String("/calendars/{o}/{c}")))
    f.append(RouteFacet(String("MKCALENDAR"), String("/calendars/{o}/{c}")))
    f.append(RouteFacet(String("PROPFIND"), String("/addressbooks/{o}")))
    return f^


# =============================================================================
# 1 — the pattern -> LB-prefix translation.
# =============================================================================


def test_prefix_truncates_at_the_first_variable_segment() raises:
    """The literal head of the pattern, with a trailing `/` marking that it was
    truncated (so a caller can tell `/healthz` — a whole path — from
    `/calendars/` — a prefix)."""
    assert_equal(
        lb_prefix_of(String("/calendars/{o}/{c}/{i}")), String("/calendars/")
    )
    assert_equal(lb_prefix_of(String("/rooms/{room}/send")), String("/rooms/"))
    assert_equal(lb_prefix_of(String("/addressbooks/{o}")), String("/addressbooks/"))
    assert_equal(lb_prefix_of(String("/healthz")), String("/healthz"))
    assert_equal(lb_prefix_of(String("/repos/{repo}")), String("/repos/"))


def test_prefix_rounds_up_never_down() raises:
    """★ A prefix must COVER its pattern. The rendered prefix is a byte-prefix of
    the pattern's literal head in every case, so no request the pattern matches
    can fail to match the prefix. A translation that rounded DOWN would drop real
    requests into the managed backend, which is the backend that cannot serve
    them — a 404 nobody attributes to the url-map."""
    var pats = List[String]()
    pats.append(String("/calendars/{o}/{c}/{i}"))
    pats.append(String("/rooms/{room}/timeline"))
    pats.append(String("/repos/{repo}"))
    pats.append(String("/healthz"))
    for i in range(len(pats)):
        var pre = lb_prefix_of(pats[i])
        var head = pre.copy()
        if head.endswith(String("/")) and head.byte_length() > 1:
            var trimmed = String(head[byte = 0 : head.byte_length() - 1])
            head = trimmed^
        assert_true(
            pats[i].startswith(head),
            String("prefix covers pattern: ") + pats[i],
        )


def test_capture_first_pattern_collapses_to_root_and_that_is_the_git_hazard() raises:
    """⚠ THE ONE THAT WILL BITE. git's repo name is the FIRST segment, so every
    wire path is `/{repo}/...` and truncating at the first variable segment
    yields `/` — a prefix that matches the entire site.

    Pinned as a FACT so nobody uses this function for a git server and routes
    everything to the git backend. A git server's real discriminator is the
    `.git` SUFFIX on the first segment, which a prefix match cannot express — it
    needs a regex or per-repo paths."""
    assert_equal(lb_prefix_of(String("/{repo}/git-upload-pack")), String("/"))
    assert_equal(lb_prefix_of(String("/{repo}/info/refs")), String("/"))


# =============================================================================
# 2 — the distinct-verb and distinct-prefix extraction.
# =============================================================================


def test_exotic_methods_are_distinct_and_in_table_order() raises:
    """First-seen order, deduped — so a reviewer diffing the render against the
    app's route table reads the verbs in the same sequence."""
    var m = exotic_methods_of(_caldav_shape())
    assert_equal(len(m), 3, "PROPFIND, REPORT, MKCALENDAR")
    assert_equal(m[0], String("PROPFIND"), "first-seen order")
    assert_equal(m[1], String("REPORT"))
    assert_equal(m[2], String("MKCALENDAR"))


def test_wildcard_method_rows_are_skipped_by_the_render() raises:
    """A row with no verb has nothing to match on. It is skipped here — and that
    is safe ONLY because the census already classified such a row exotic, so
    `split_verdict` refuses the app before this render is reached. If the two ever
    disagree, an app renders fewer rules than it needs and the missing verb falls
    through to the managed gateway."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String(""), String("/x/{y}")))
    f.append(RouteFacet(String("PROPFIND"), String("/x/{y}")))
    var m = exotic_methods_of(f)
    assert_equal(len(m), 1, "only the named verb renders")
    assert_equal(m[0], String("PROPFIND"))


def test_exotic_prefixes_are_distinct() raises:
    var p = exotic_prefixes_of(_caldav_shape())
    assert_equal(len(p), 2, "/calendars/ and /addressbooks/")
    assert_equal(p[0], String("/calendars/"))
    assert_equal(p[1], String("/addressbooks/"))


# =============================================================================
# 3 — the GCP url-map render.
# =============================================================================


def test_gcp_render_emits_the_method_matcher() raises:
    """★ The one line that makes the split possible on GCP."""
    var doc = render_gcp_route_rules(
        _caldav_shape(),
        String("caldav-managed-backend"),
        String("caldav-exotic-backend"),
    )
    assert_true(
        String('"headerName": ":method"') in doc,
        "the documented pseudo-header match",
    )
    assert_true(String('"exactMatch": "PROPFIND"') in doc, "PROPFIND matched")
    assert_true(String('"exactMatch": "MKCALENDAR"') in doc, "MKCALENDAR matched")


def test_gcp_render_is_one_rule_per_prefix_method_pair() raises:
    """★ NOT one rule listing every method. `matchRules[].headerMatches[]` entries
    are ANDed, so a single rule with three `:method` matches matches NOTHING — no
    request carries three methods. 2 prefixes x 3 verbs = 6 exotic rules, plus the
    managed catch-all = 7."""
    var doc = render_gcp_route_rules(
        _caldav_shape(), String("managed"), String("exotic")
    )
    assert_equal(_count(doc, String('"priority"')), 7, "6 exotic + 1 catch-all")
    assert_equal(
        _count(doc, String('"headerName": ":method"')),
        6,
        "exactly one method matcher per exotic rule",
    )
    # ...and each rule carries exactly one headerMatches entry.
    assert_equal(
        _count(doc, String('"headerMatches": [{')),
        6,
        "one headerMatches array per exotic rule, never a multi-entry AND",
    )


def test_gcp_exotic_rules_all_precede_the_managed_catch_all() raises:
    """★ PRIORITY ORDER IS THE CORRECTNESS ARGUMENT. `routeRules` evaluate by
    ascending priority, first match wins. If the catch-all came first, every
    PROPFIND would reach the managed gateway and 405 — silently, because a proxy's
    405 looks like an app decision."""
    var doc = render_gcp_route_rules(
        _caldav_shape(), String("managed-be"), String("exotic-be"),
    )
    var catch_all = doc.find(String("everything else"))
    var last_exotic = doc.rfind(String('"headerName": ":method"'))
    assert_true(catch_all >= 0, "the catch-all is rendered")
    assert_true(last_exotic >= 0, "exotic rules are rendered")
    assert_true(
        last_exotic < catch_all,
        "★ every exotic rule precedes the managed catch-all",
    )
    # The catch-all is the LAST priority, and it points at the managed backend.
    assert_true(String('"priority": 7') in doc, "the catch-all is priority 7")
    assert_true(
        String('"matchRules": [{ "prefixMatch": "/" }]') in doc,
        "the catch-all matches everything",
    )
    assert_true(String('"service": "managed-be"') in doc, "-> managed")


def test_gcp_render_with_no_exotic_route_is_just_the_catch_all() raises:
    """An app with nothing to move renders ONE rule pointing at the managed
    backend — i.e. the unsplit front door. Rendering a split for an unsplit
    app must not invent an empty exotic backend to route to."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/a")))
    var doc = render_gcp_route_rules(f, String("managed"), String("exotic"))
    assert_equal(_count(doc, String('"priority"')), 1, "one rule")
    assert_false(String(":method") in doc, "no method matcher needed")
    assert_false(String('"service": "exotic"') in doc, "nothing routed to it")


# =============================================================================
# 4 — the AWS ALB render (the portability twin).
# =============================================================================


def test_aws_render_uses_the_first_class_method_condition() raises:
    """`http-request-method` — documented to accept custom methods, so unlike the
    GCP row nothing here rests on an unverified behaviour."""
    var doc = render_aws_listener_rules(
        _caldav_shape(), String("arn:managed"), String("arn:exotic")
    )
    assert_true(
        String('"Field": "http-request-method"') in doc, "the condition"
    )
    assert_true(String('"PROPFIND"') in doc, "PROPFIND")
    assert_true(String('"MKCALENDAR"') in doc, "MKCALENDAR")


def test_aws_render_packs_at_most_three_methods_per_rule() raises:
    """★ The ALB's documented limit: "You can specify up to three match
    evaluations per condition." Three verbs across two prefixes packs into 2
    rules, not 6 — which is what keeps a five-verb app inside the listener's rule
    quota. A fourth value in a chunk is rejected by the API, so this is a
    correctness bound, not a tidiness one."""
    var doc = render_aws_listener_rules(
        _caldav_shape(), String("arn:managed"), String("arn:exotic")
    )
    assert_equal(
        _count(doc, String('"Field": "http-request-method"')),
        2,
        "3 verbs pack into ONE condition per prefix; 2 prefixes = 2 rules",
    )
    assert_equal(_count(doc, String('"Priority"')), 3, "2 exotic + the default")


def test_aws_render_splits_a_fourth_verb_into_a_second_rule() raises:
    """The chunk boundary, exercised. Four verbs on one prefix must become TWO
    rules (3 + 1), because a condition takes at most three values."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("PROPFIND"), String("/c/{x}")))
    f.append(RouteFacet(String("PROPPATCH"), String("/c/{x}")))
    f.append(RouteFacet(String("REPORT"), String("/c/{x}")))
    f.append(RouteFacet(String("MKCOL"), String("/c/{x}")))
    var doc = render_aws_listener_rules(f, String("arn:m"), String("arn:e"))
    assert_equal(
        _count(doc, String('"Field": "http-request-method"')),
        2,
        "4 verbs -> 3 + 1 -> two conditions",
    )


def test_aws_path_pattern_gets_a_wildcard_on_a_truncated_prefix() raises:
    """An ALB `path-pattern` is a glob, not a prefix: `/calendars/` matches only
    that exact path. The render appends `*` to a truncated prefix so it covers the
    sub-paths, and does NOT append one to a whole path like `/healthz` — where a
    wildcard would silently capture `/healthz-internal`."""
    var doc = render_aws_listener_rules(
        _caldav_shape(), String("arn:m"), String("arn:e")
    )
    assert_true(String('"/calendars/*"') in doc, "truncated prefix gets a *")
    assert_true(String('"/addressbooks/*"') in doc, "and so does the other")
    assert_false(String('"/healthz*"') in doc, "a whole path does not")


def test_aws_default_action_is_the_managed_target() raises:
    """The `default` rule is the managed gateway — the same posture as the GCP
    catch-all, so a request matching no exotic rule lands in the same place on
    both clouds. A split whose fall-through differed per cloud would be two
    different products wearing one name."""
    var doc = render_aws_listener_rules(
        _caldav_shape(), String("arn:managed"), String("arn:exotic")
    )
    var default_at = doc.find(String('"Priority": "default"'))
    var last_method = doc.rfind(String("http-request-method"))
    assert_true(
        last_method < default_at, "exotic rules precede the default"
    )
    assert_true(String('"TargetGroupArn": "arn:managed"') in doc, "-> managed")


def main() raises:
    test_prefix_truncates_at_the_first_variable_segment()
    test_prefix_rounds_up_never_down()
    test_capture_first_pattern_collapses_to_root_and_that_is_the_git_hazard()
    test_exotic_methods_are_distinct_and_in_table_order()
    test_wildcard_method_rows_are_skipped_by_the_render()
    test_exotic_prefixes_are_distinct()
    test_gcp_render_emits_the_method_matcher()
    test_gcp_render_is_one_rule_per_prefix_method_pair()
    test_gcp_exotic_rules_all_precede_the_managed_catch_all()
    test_gcp_render_with_no_exotic_route_is_just_the_catch_all()
    test_aws_render_uses_the_first_class_method_condition()
    test_aws_render_packs_at_most_three_methods_per_rule()
    test_aws_render_splits_a_fourth_verb_into_a_second_rule()
    test_aws_path_pattern_gets_a_wildcard_on_a_truncated_prefix()
    test_aws_default_action_is_the_managed_target()
    print(
        "OK: test_transport_split_render (the GCP"
        " `:method` routeRules render + the AWS http-request-method twin;"
        " priority order, the AND hazard, and the git prefix hazard)"
        " — all assertions passed"
    )
