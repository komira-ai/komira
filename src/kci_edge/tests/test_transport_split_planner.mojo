# =============================================================================
# test_transport_split_planner.mojo — the transport-split planner gate: the
#   transport classifier, the split census (and its decisive
#   `shared_path_count`), the per-cloud capability table, and the verdict's
#   refusal arms.
# =============================================================================
#
# HERMETIC: pure values in, pure values out. No cloud, no network, no store, no
#   clock. Deliberately carries NO app dependency: the facets below are
#   synthetic inventories of the three shapes that matter (disjoint paths, a
#   shared path, a bulk route), so a break in an app package cannot take the
#   planner's own gate red with it.
#
# WHAT THIS PINS, and why each case exists:
#   (1) The classifier's ORDER. An upgrade outranks a verb outranks a size —
#       reversing any pair silently routes a real route to the wrong backend.
#   (2) `shared_path_count` — the number that decides the option. Two rows on
#       ONE path, one managed and one exotic, is the CalDAV shape; the census
#       must report it as 1 shared path and not as "60% managed".
#   (3) The four cited capability rows, INCLUDING the two negatives: CloudFront
#       and Azure Front Door cannot express a method split, so an app with a
#       shared path is refused there — which is the portability answer.
#   (4) The verdict's refusal ORDER: an unverified half outranks everything, so
#       a plan is never reported "blocked on routing" when it is also unsafe.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from kci_edge import (
    TRANSPORT_JSON,
    TRANSPORT_EXT_METHOD,
    TRANSPORT_UPGRADE,
    TRANSPORT_BULK,
    MANAGED_GATEWAY_BODY_CAP_BYTES,
    CLOUD_RUN_HTTP1_BODY_CAP_BYTES,
    BACKEND_BODY_CAP_UNLIMITED,
    transport_class_name,
    is_standard_http_method,
    classify_transport,
    RouteFacet,
    split_census,
    census_line,
    edge_gcp_api_gateway,
    edge_gcp_global_alb,
    edge_aws_alb,
    edge_aws_cloudfront,
    edge_azure_front_door,
    VERIFIER_NONE,
    VERIFIER_APP_MIDDLEWARE,
    VERIFIER_EDGE_JWT,
    verifier_name,
    verifier_is_weaker_than,
    SplitPlan,
    split_verdict,
    verdict_name,
    SPLIT_PROCEED,
    SPLIT_UNNECESSARY,
    SPLIT_INEXPRESSIBLE,
    SPLIT_UNREACHABLE,
    SPLIT_UNVERIFIED_HALF,
    SPLIT_EDGE_CANNOT_CARRY,
    SPLIT_BACKEND_CAP,
    SPLIT_VERIFIER_ASYMMETRY,
)


# =============================================================================
# 1 — the classifier.
# =============================================================================


def test_standard_verb_set_is_the_intersection() raises:
    """The guaranteed-minimum verb set is exactly get/put/post/delete/patch/
    options/head — the intersection of what OpenAPI can spell, what Azure Front
    Door's `RequestMethod` accepts, and what CloudFront's `AllowedMethods`
    enumerates. Anything outside it is an extension verb SOMEWHERE."""
    assert_true(is_standard_http_method(String("GET")), "GET")
    assert_true(is_standard_http_method(String("PUT")), "PUT")
    assert_true(is_standard_http_method(String("POST")), "POST")
    assert_true(is_standard_http_method(String("DELETE")), "DELETE")
    assert_true(is_standard_http_method(String("PATCH")), "PATCH")
    assert_true(is_standard_http_method(String("OPTIONS")), "OPTIONS")
    assert_true(is_standard_http_method(String("HEAD")), "HEAD")
    # The five CalDAV/CardDAV verbs a DAV route table declares.
    assert_false(is_standard_http_method(String("PROPFIND")), "PROPFIND")
    assert_false(is_standard_http_method(String("REPORT")), "REPORT")
    assert_false(is_standard_http_method(String("MKCALENDAR")), "MKCALENDAR")
    assert_false(is_standard_http_method(String("MKCOL")), "MKCOL")
    assert_false(is_standard_http_method(String("PROPPATCH")), "PROPPATCH")


def test_any_method_wildcard_row_is_not_standard() raises:
    """★ A route table's ANY-METHOD row (`method == ""`) classifies as
    an EXTENSION verb, not as a standard one.

    This is the fail-closed arm, and it is load-bearing: a wildcard row COULD
    carry PROPFIND, so treating it as ordinary would let an app be reported
    splittable at CloudFront on the strength of a row nobody has enumerated. The
    census is allowed to over-report the exotic half; it is not allowed to
    under-report it."""
    assert_false(is_standard_http_method(String("")), "empty method")
    assert_equal(
        classify_transport(String(""), 0, False),
        TRANSPORT_EXT_METHOD,
        "an any-method row is exotic until enumerated",
    )


def test_classifier_order_upgrade_outranks_verb_outranks_size() raises:
    """The decline-strength order. Each pair below is a real routing decision:
    reversing it sends a route to a backend that cannot serve it."""
    # (a) UPGRADE outranks everything — a WebSocket on a standard verb inside the
    #     cap is still unservable by the managed wrapper.
    assert_equal(
        classify_transport(String("GET"), 0, True),
        TRANSPORT_UPGRADE,
        "GET + upgrade -> UPGRADE, not JSON",
    )
    # (b) EXT_METHOD outranks BULK — a 1-byte PROPFIND is still unspellable.
    assert_equal(
        classify_transport(String("PROPFIND"), 1, False),
        TRANSPORT_EXT_METHOD,
        "a tiny PROPFIND is still EXT_METHOD",
    )
    # (c) BULK only when the verb is standard AND the body exceeds the cap.
    assert_equal(
        classify_transport(
            String("POST"), MANAGED_GATEWAY_BODY_CAP_BYTES + 1, False
        ),
        TRANSPORT_BULK,
        "a standard verb over the 32 MB cap -> BULK",
    )
    # (d) Exactly AT the cap is still JSON — the documented cap is inclusive, and
    #     an off-by-one here would move a whole class of routes for no reason.
    assert_equal(
        classify_transport(
            String("POST"), MANAGED_GATEWAY_BODY_CAP_BYTES, False
        ),
        TRANSPORT_JSON,
        "exactly at the cap is still managed",
    )
    assert_equal(
        classify_transport(String("GET"), 0, False),
        TRANSPORT_JSON,
        "an ordinary GET is managed",
    )


def test_class_and_verifier_names_are_stable_tokens() raises:
    """The census line and every refusal message are built from these, so a
    report and the gate that checked it quote the same string."""
    assert_equal(transport_class_name(TRANSPORT_JSON), String("json"))
    assert_equal(transport_class_name(TRANSPORT_EXT_METHOD), String("ext-method"))
    assert_equal(transport_class_name(TRANSPORT_UPGRADE), String("upgrade"))
    assert_equal(transport_class_name(TRANSPORT_BULK), String("bulk"))
    assert_equal(transport_class_name(999), String("unknown"))
    assert_equal(verifier_name(VERIFIER_EDGE_JWT), String("edge-jwt"))
    assert_equal(
        verifier_name(VERIFIER_APP_MIDDLEWARE), String("app-middleware")
    )
    assert_equal(verifier_name(VERIFIER_NONE), String("none"))
    assert_equal(verdict_name(SPLIT_PROCEED), String("PROCEED"))
    assert_equal(verdict_name(SPLIT_INEXPRESSIBLE), String("INEXPRESSIBLE"))


# =============================================================================
# 2 — the census, and the number that decides the option.
# =============================================================================


def _disjoint_facets() -> List[RouteFacet]:
    """The MESSAGING / REPO-HOSTING shape: the exotic routes sit on their OWN paths, so
    the split is a PATH split every edge can express."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/rooms/{room}/timeline")))
    f.append(RouteFacet(String("POST"), String("/rooms/{room}/send")))
    f.append(RouteFacet(String("POST"), String("/register")))
    f.append(
        RouteFacet(String("GET"), String("/sync"), 0, True, True)
    )  # the upgrade, on its own path and its own port
    return f^


def _shared_path_facets() -> List[RouteFacet]:
    """The CALDAV shape: one path, two transports. `GET` and `PROPFIND` on the
    SAME pattern is what a path-only edge cannot separate."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/calendars/{o}/{c}/{i}")))
    f.append(RouteFacet(String("PUT"), String("/calendars/{o}/{c}/{i}")))
    f.append(RouteFacet(String("PROPFIND"), String("/calendars/{o}/{c}/{i}")))
    f.append(RouteFacet(String("REPORT"), String("/calendars/{o}/{c}")))
    f.append(RouteFacet(String("GET"), String("/healthz")))
    return f^


def test_disjoint_split_needs_no_method_match() raises:
    """4 rows, 1 exotic, and the exotic one is alone on `/sync` — so no path
    carries both halves and `needs_method_match()` is False. This is the shape
    that makes the option cheap."""
    var c = split_census(_disjoint_facets())
    assert_equal(c.total, 4, "4 rows")
    assert_equal(c.managed, 3, "3 managed")
    assert_equal(c.upgrade, 1, "1 upgrade")
    assert_equal(c.exotic(), 1, "1 exotic")
    assert_equal(c.shared_path_count, 0, "no path carries both halves")
    assert_false(c.needs_method_match(), "a PATH split suffices")
    assert_true(c.needs_second_backend(), "one upgrade still costs a service")
    assert_equal(c.distinct_port_count, 1, "the upgrade is on its own port")
    assert_equal(c.managed_permille(), 750, "3/4 = 750 per mille")


def test_shared_path_split_requires_method_match() raises:
    """5 rows, 2 exotic — and BOTH exotic verbs sit on patterns that also carry a
    managed verb... except `REPORT /calendars/{o}/{c}`, whose pattern carries no
    managed row. So exactly ONE pattern is shared, and one shared pattern is
    enough to force a method match."""
    var c = split_census(_shared_path_facets())
    assert_equal(c.total, 5, "5 rows")
    assert_equal(c.managed, 3, "GET+PUT on the item, GET /healthz")
    assert_equal(c.ext_method, 2, "PROPFIND + REPORT")
    assert_equal(
        c.shared_path_count,
        1,
        "only /calendars/{o}/{c}/{i} carries both halves",
    )
    assert_true(c.needs_method_match(), "a PATH split CANNOT express this")


def test_shared_path_counted_once_per_pattern() raises:
    """Three exotic verbs on ONE shared path is ONE shared path, not three. The
    count is of PATTERNS the edge must disambiguate, which is what an edge's
    rule budget is spent on."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/c/{x}")))
    f.append(RouteFacet(String("PROPFIND"), String("/c/{x}")))
    f.append(RouteFacet(String("PROPPATCH"), String("/c/{x}")))
    f.append(RouteFacet(String("REPORT"), String("/c/{x}")))
    var c = split_census(f)
    assert_equal(c.ext_method, 3, "3 exotic rows")
    assert_equal(c.shared_path_count, 1, "on ONE shared pattern")


def test_empty_inventory_is_not_a_split() raises:
    """A degenerate census must not report a favourable ratio. Zero rows is zero
    per mille, not 100% — an empty inventory means the derivation failed, and a
    gate that reads it as 'fully managed' is a gate that passes on no data."""
    var c = split_census(List[RouteFacet]())
    assert_equal(c.total, 0, "no rows")
    assert_equal(c.managed_permille(), 0, "0, never 1000")
    assert_false(c.needs_second_backend(), "nothing to move")


def test_census_line_is_a_stable_string() raises:
    """The line a report quotes. Pinned verbatim so a silent change to the
    format cannot make two runs' numbers incomparable."""
    var c = split_census(_shared_path_facets())
    assert_equal(
        census_line(String("caldav"), c),
        String(
            "caldav total=5 managed=3 exotic=2 (ext=2 upgrade=0 bulk=0)"
            " shared_paths=1 managed_permille=600"
        ),
        "the census line",
    )


# =============================================================================
# 3 — the per-cloud capability table. Each row is a cited fact.
# =============================================================================


def test_gcp_alb_can_match_method_the_refuted_claim() raises:
    """★ THE REFUTATION. `HttpHeaderMatch.headerName` documents `":method"`
    explicitly, so a GCP url-map CAN send PROPFIND and GET on one path to two
    backends. The capability row says so, and carries the URL."""
    var alb = edge_gcp_global_alb()
    assert_true(alb.can_match_method, "GCP global ALB matches on :method")
    assert_true(
        String("HttpHeaderMatch") in alb.citation,
        "the row carries the doc that establishes it",
    )
    # ...and the thing that is NOT established is named, not assumed.
    assert_true(
        len(alb.unverified.as_bytes()) > 0,
        "forwarding an extension verb is UNVERIFIED and says so",
    )


def test_aws_alb_is_the_strongest_method_split_primitive() raises:
    """AWS's `http-request-method` condition admits CUSTOM methods by
    documentation, so unlike the GCP row both MATCHING and FORWARDING are cited —
    nothing is left unverified."""
    var alb = edge_aws_alb()
    assert_true(alb.can_match_method, "http-request-method")
    assert_true(alb.forwards_extension_methods, "custom methods, documented")
    assert_equal(
        len(alb.unverified.as_bytes()), 0, "no unverified field on this row"
    )


def test_the_two_negative_rows_are_the_portability_answer() raises:
    """⛔ CloudFront's `AllowedMethods` is a fixed three-choice enum and Azure
    Front Door's `RequestMethod` enumerates seven standard verbs. Neither can
    express a method split, so an app with a shared path is not splittable
    there — whatever the route ratio says."""
    var cf = edge_aws_cloudfront()
    assert_false(cf.can_match_method, "CloudFront: fixed method enum")
    assert_false(cf.forwards_extension_methods, "and no PROPFIND spelling")
    var afd = edge_azure_front_door()
    assert_false(afd.can_match_method, "AFD RequestMethod: 7 standard verbs")


def test_managed_gateway_cannot_front_its_own_split() raises:
    """The managed gateway is in the table to record that it cannot be the front
    of the split: no method match, no extension verb, no upgrade. Its ONE
    irreplaceable property is being public WITHOUT an `allUsers` binding."""
    var gw = edge_gcp_api_gateway()
    assert_false(gw.can_match_method, "OpenAPI has a fixed method list")
    assert_false(gw.carries_upgrade, "Streaming is not supported")
    assert_true(
        gw.public_without_allusers,
        "★ the property the split gives up: public without allUsers",
    )
    # And the LB, which CAN carry the exotic half, does NOT have that property.
    assert_false(
        edge_gcp_global_alb().public_without_allusers,
        "a serverless NEG -> Cloud Run hop needs an allUsers binding",
    )


# =============================================================================
# 4 — the verdict. Every refusal names itself, in strength order.
# =============================================================================


def _plan(
    var edge_name: String, exotic_verifier: Int, reachable: Bool
) -> SplitPlan:
    """A plan over the GCP global ALB row with the two fields under test varied."""
    _ = edge_name
    return SplitPlan(
        String("fixture"),
        edge_gcp_global_alb(),
        VERIFIER_APP_MIDDLEWARE,
        exotic_verifier,
        reachable,
    )


def test_an_unverified_exotic_half_is_refused_first() raises:
    """★ THE ONE REFUSAL THAT OUTRANKS EVERYTHING. A plan whose exotic half has
    no verifier is the model that answers 200 to `Bearer
    not-a-real-grant-token`. It is refused even when the routing is expressible
    and the backend is reachable, and the reason says which model it is."""
    var c = split_census(_shared_path_facets())
    var v = split_verdict(c, _plan(String("gcp"), VERIFIER_NONE, True))
    assert_equal(v.code, SPLIT_UNVERIFIED_HALF, "refused")
    assert_true(
        String("not-a-real-grant-token") in v.reason,
        "the reason names the model it is refusing",
    )
    assert_false(v.proceeds(), "and it does not proceed")


def test_no_exotic_route_is_UNNECESSARY_not_PROCEED() raises:
    """An app already wholly on the managed gateway gets a distinct verdict.
    Reporting PROCEED would authorize provisioning a second backend for nothing —
    two deploys and two authz caches bought with no route moved."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/a")))
    f.append(RouteFacet(String("POST"), String("/b")))
    var v = split_verdict(
        split_census(f), _plan(String("gcp"), VERIFIER_APP_MIDDLEWARE, True)
    )
    assert_equal(v.code, SPLIT_UNNECESSARY, "nothing to split")


def test_shared_path_on_a_path_only_edge_is_INEXPRESSIBLE() raises:
    """The CalDAV-shape census against CloudFront and Azure Front Door. The
    refusal states the shared-path count and names the edge, because "it does not
    work" is not something anyone can act on."""
    var c = split_census(_shared_path_facets())
    var cf_plan = SplitPlan(
        String("caldav"),
        edge_aws_cloudfront(),
        VERIFIER_APP_MIDDLEWARE,
        VERIFIER_APP_MIDDLEWARE,
        True,
    )
    var cf = split_verdict(c, cf_plan)
    assert_equal(cf.code, SPLIT_INEXPRESSIBLE, "CloudFront cannot express it")
    assert_true(String("aws-cloudfront") in cf.reason, "names the edge")
    assert_true(String("1 path") in cf.reason, "names the shared-path count")

    var afd_plan = SplitPlan(
        String("caldav"),
        edge_azure_front_door(),
        VERIFIER_APP_MIDDLEWARE,
        VERIFIER_APP_MIDDLEWARE,
        True,
    )
    assert_equal(
        split_verdict(c, afd_plan).code,
        SPLIT_INEXPRESSIBLE,
        "Azure Front Door cannot express it either",
    )


def test_disjoint_split_survives_a_path_only_edge() raises:
    """The paired control: the MESSAGING / REPO-HOSTING shape has NO shared path, so a
    path-only edge is not refused for inexpressibility. CloudFront still declines
    it — on the UPGRADE, a different and correctly-named reason."""
    var c = split_census(_disjoint_facets())
    var cf = SplitPlan(
        String("acme-chat"),
        edge_aws_cloudfront(),
        VERIFIER_APP_MIDDLEWARE,
        VERIFIER_APP_MIDDLEWARE,
        True,
    )
    var v = split_verdict(c, cf)
    assert_true(
        v.code != SPLIT_INEXPRESSIBLE,
        "a disjoint split is expressible at a path-only edge",
    )
    # CloudFront DOES carry a WebSocket, so the disjoint messaging split proceeds
    # there — the one place in this file where the AWS row is the permissive one.
    assert_equal(v.code, SPLIT_PROCEED, "CloudFront carries the upgrade")


def test_reachability_is_refused_separately_from_routing() raises:
    """★ The GCP finding. Routing is expressible (the ALB matches `:method`) and
    the halves are both verified — and the split is STILL refused, because the
    second backend has no public hop that avoids the `allUsers` binding
    `iam.allowedPolicyMemberDomains` rejects. A verdict that folded this into
    "inexpressible" would send someone to fix the url-map."""
    var c = split_census(_shared_path_facets())
    var v = split_verdict(
        c, _plan(String("gcp"), VERIFIER_APP_MIDDLEWARE, False)
    )
    assert_equal(v.code, SPLIT_UNREACHABLE, "reachability, not routing")
    assert_true(
        String("allUsers") in v.reason, "the reason names the binding"
    )


def test_a_proceed_carries_its_unverified_caveat() raises:
    """A PROCEED that rests on an unchecked platform behaviour must say so AT THE
    POINT OF DECISION. The GCP row's extension-verb FORWARDING is undocumented,
    so a CalDAV proceed there is conditional and the verdict carries it."""
    var c = split_census(_shared_path_facets())
    var v = split_verdict(
        c, _plan(String("gcp"), VERIFIER_APP_MIDDLEWARE, True)
    )
    assert_equal(v.code, SPLIT_PROCEED, "expressible + reachable")
    assert_true(
        String("forwards_extension_methods") in v.caveat,
        "and the unverified capability rides with it",
    )


def test_edge_cannot_carry_is_distinct_from_inexpressible() raises:
    """An edge that CAN match the method but CANNOT forward the verb gets its own
    verdict: the routing is fine, the transport is not. Constructed from the
    AWS-ALB row with forwarding withheld, so the arm is reachable without
    inventing a cloud."""
    var c = split_census(_shared_path_facets())
    var half = edge_aws_alb()
    half.forwards_extension_methods = False
    var v = split_verdict(
        c,
        SplitPlan(
            String("caldav"),
            half^,
            VERIFIER_APP_MIDDLEWARE,
            VERIFIER_APP_MIDDLEWARE,
            True,
        ),
    )
    assert_equal(v.code, SPLIT_EDGE_CANNOT_CARRY, "transport, not routing")
    assert_true(String("extension verbs") in v.reason, "names the transport")


# =============================================================================
# 5 — THE NO-OP SPLIT. Moving a route off a capped edge onto a capped backend.
# =============================================================================


def _bulk_facets() -> List[RouteFacet]:
    """The REPO-HOSTING shape: standard verbs, one 512 MiB payload route, on its own
    path. Everything about the ROUTING is easy; the size is the whole problem."""
    var f = List[RouteFacet]()
    f.append(RouteFacet(String("GET"), String("/repos/{repo}")))
    f.append(RouteFacet(String("POST"), String("/repos")))
    f.append(
        RouteFacet(
            String("POST"),
            String("/{repo}/git-receive-pack"),
            512 * 1024 * 1024,
        )
    )
    return f^


def test_census_carries_the_largest_body_in_the_inventory() raises:
    """The verdict needs the app's real envelope, not just "some row is bulk"."""
    var c = split_census(_bulk_facets())
    assert_equal(c.bulk, 1, "one bulk row")
    assert_equal(
        c.max_body_bytes, 512 * 1024 * 1024, "the 512 MiB git push"
    )


def test_cloud_run_http1_caps_at_the_SAME_32_MiB_as_the_gateway() raises:
    """★ THE FACT THAT MAKES A BULK SPLIT A NO-OP, and it is not obvious: Cloud
    Run's own HTTP/1 request cap is the SAME 32 MiB as the API Gateway's. Moving
    a 512 MiB push off the gateway onto a second Cloud Run service over HTTP/1
    changes which component answers 413, not whether one does."""
    assert_equal(
        CLOUD_RUN_HTTP1_BODY_CAP_BYTES,
        MANAGED_GATEWAY_BODY_CAP_BYTES,
        "the second backend is capped exactly where the first was",
    )


def test_bulk_split_onto_an_http1_cloud_run_backend_is_refused() raises:
    """★ SPLIT_BACKEND_CAP. Routing expressible, edge carries it, both halves
    verified, backend reachable — and the split is STILL refused, because the
    second Cloud Run service over HTTP/1 cannot accept the body either.

    The refusal is its own arm rather than folded into EDGE_CANNOT_CARRY because
    the fix is neither the url-map nor the IAM binding: it is the backend's
    protocol (h2) or its platform."""
    var c = split_census(_bulk_facets())
    var v = split_verdict(
        c,
        SplitPlan(
            String("acme-git"),
            edge_gcp_global_alb(),
            VERIFIER_APP_MIDDLEWARE,
            VERIFIER_APP_MIDDLEWARE,
            True,
            CLOUD_RUN_HTTP1_BODY_CAP_BYTES,
        ),
    )
    assert_equal(v.code, SPLIT_BACKEND_CAP, "the no-op split, refused")
    assert_true(
        String("which component answers 413") in v.reason,
        "the reason says what moving the route actually buys",
    )


def test_the_same_split_proceeds_on_an_uncapped_backend() raises:
    """The paired control, and the actionable half of the finding: the SAME
    census and the SAME edge PROCEED once the exotic backend has no body cap — an
    h2 Cloud Run hop, an ECS/Fargate task behind an ALB, a Container App. So the
    repo-hosting fix is a PROTOCOL decision, and the planner points at it."""
    var c = split_census(_bulk_facets())
    var v = split_verdict(
        c,
        SplitPlan(
            String("acme-git"),
            edge_gcp_global_alb(),
            VERIFIER_APP_MIDDLEWARE,
            VERIFIER_APP_MIDDLEWARE,
            True,
            BACKEND_BODY_CAP_UNLIMITED,
        ),
    )
    assert_equal(v.code, SPLIT_PROCEED, "uncapped backend -> proceed")


def test_backend_cap_does_not_fire_when_the_app_fits() raises:
    """A capped backend is fine for an app that never approaches it — the
    messaging app's /sync upgrade carries no body. The arm must not refuse every
    capped backend on principle, only one the app actually overruns."""
    var v = split_verdict(
        split_census(_disjoint_facets()),
        SplitPlan(
            String("acme-chat"),
            edge_gcp_global_alb(),
            VERIFIER_APP_MIDDLEWARE,
            VERIFIER_APP_MIDDLEWARE,
            True,
            CLOUD_RUN_HTTP1_BODY_CAP_BYTES,
        ),
    )
    assert_equal(v.code, SPLIT_PROCEED, "the messaging app fits inside 32 MiB")


# =============================================================================
# 6 — THE VERIFIER ASYMMETRY, and when it appears.
# =============================================================================


def test_verifier_order_is_a_named_decision() raises:
    """NONE < APP_MIDDLEWARE < EDGE_JWT. Stated as a function so the ordering is
    a decision somebody made, not an accident of which constant got which int."""
    assert_true(
        verifier_is_weaker_than(VERIFIER_NONE, VERIFIER_APP_MIDDLEWARE),
        "nothing < the app's own gate",
    )
    assert_true(
        verifier_is_weaker_than(VERIFIER_APP_MIDDLEWARE, VERIFIER_EDGE_JWT),
        "the app's gate < a check the request never gets past",
    )
    assert_false(
        verifier_is_weaker_than(VERIFIER_EDGE_JWT, VERIFIER_EDGE_JWT),
        "equal is not weaker",
    )


def test_symmetric_passthrough_plan_is_not_flagged() raises:
    """★ THE PASSTHROUGH SHAPE, and the reason this option is not an auth
    regression there. A client-passthrough edge
    (`EdgeAuthPolicy.client_passthrough()`) leaves the app's middleware as the
    sole authorizer on the managed half. So both halves sit at APP_MIDDLEWARE and
    there is no asymmetry to flag."""
    var v = split_verdict(
        split_census(_disjoint_facets()),
        SplitPlan(
            String("acme-chat"),
            edge_gcp_global_alb(),
            VERIFIER_APP_MIDDLEWARE,
            VERIFIER_APP_MIDDLEWARE,
            True,
        ),
    )
    assert_equal(v.code, SPLIT_PROCEED, "symmetric under passthrough")


def test_the_asymmetry_fires_when_the_managed_half_verifies_at_the_edge() raises:
    """★ An identity-JWT edge makes the managed half EDGE_JWT; a split whose
    exotic half is still APP_MIDDLEWARE puts the WEAKER check on the half
    carrying the app's data. Refused ahead of every routing arm, because a
    security regression is not a routing problem."""
    var v = split_verdict(
        split_census(_disjoint_facets()),
        SplitPlan(
            String("acme-chat"),
            edge_gcp_global_alb(),
            VERIFIER_EDGE_JWT,
            VERIFIER_APP_MIDDLEWARE,
            True,
        ),
    )
    assert_equal(v.code, SPLIT_VERIFIER_ASYMMETRY, "the weaker half is flagged")
    assert_true(
        String("carrying the app's data") in v.reason,
        "the reason says which half is weaker and why that matters",
    )
    assert_equal(verdict_name(v.code), String("VERIFIER_ASYMMETRY"))


def test_an_exotic_half_that_keeps_pace_proceeds() raises:
    """The actionable half: an exotic backend that ALSO verifies at the edge —
    an Envoy `jwt_authn` filter with `remote_jwks` — restores the
    symmetry and the split proceeds. So the arm names a requirement, not a
    dead end."""
    var v = split_verdict(
        split_census(_disjoint_facets()),
        SplitPlan(
            String("acme-chat"),
            edge_gcp_global_alb(),
            VERIFIER_EDGE_JWT,
            VERIFIER_EDGE_JWT,
            True,
        ),
    )
    assert_equal(v.code, SPLIT_PROCEED, "both halves verify at the edge")


def test_a_STRONGER_exotic_half_is_not_flagged() raises:
    """Asymmetry is directional. An exotic half verified MORE strongly than the
    managed one is an improvement, not a regression, and must not be refused —
    otherwise the arm blocks the very fix it exists to demand."""
    var v = split_verdict(
        split_census(_disjoint_facets()),
        SplitPlan(
            String("acme-chat"),
            edge_gcp_global_alb(),
            VERIFIER_APP_MIDDLEWARE,
            VERIFIER_EDGE_JWT,
            True,
        ),
    )
    assert_equal(v.code, SPLIT_PROCEED, "stronger is fine")


def main() raises:
    test_standard_verb_set_is_the_intersection()
    test_any_method_wildcard_row_is_not_standard()
    test_classifier_order_upgrade_outranks_verb_outranks_size()
    test_class_and_verifier_names_are_stable_tokens()
    test_disjoint_split_needs_no_method_match()
    test_shared_path_split_requires_method_match()
    test_shared_path_counted_once_per_pattern()
    test_empty_inventory_is_not_a_split()
    test_census_line_is_a_stable_string()
    test_gcp_alb_can_match_method_the_refuted_claim()
    test_aws_alb_is_the_strongest_method_split_primitive()
    test_the_two_negative_rows_are_the_portability_answer()
    test_managed_gateway_cannot_front_its_own_split()
    test_an_unverified_exotic_half_is_refused_first()
    test_no_exotic_route_is_UNNECESSARY_not_PROCEED()
    test_shared_path_on_a_path_only_edge_is_INEXPRESSIBLE()
    test_disjoint_split_survives_a_path_only_edge()
    test_reachability_is_refused_separately_from_routing()
    test_a_proceed_carries_its_unverified_caveat()
    test_edge_cannot_carry_is_distinct_from_inexpressible()
    test_census_carries_the_largest_body_in_the_inventory()
    test_cloud_run_http1_caps_at_the_SAME_32_MiB_as_the_gateway()
    test_bulk_split_onto_an_http1_cloud_run_backend_is_refused()
    test_the_same_split_proceeds_on_an_uncapped_backend()
    test_backend_cap_does_not_fire_when_the_app_fits()
    test_verifier_order_is_a_named_decision()
    test_symmetric_passthrough_plan_is_not_flagged()
    test_the_asymmetry_fires_when_the_managed_half_verifies_at_the_edge()
    test_an_exotic_half_that_keeps_pace_proceeds()
    test_a_STRONGER_exotic_half_is_not_flagged()
    print(
        "OK: test_transport_split_planner (the transport-split"
        " classifier, the shared-path census, the four CITED per-cloud"
        " capability rows, and the verdict's refusal order)"
        " — all assertions passed"
    )
