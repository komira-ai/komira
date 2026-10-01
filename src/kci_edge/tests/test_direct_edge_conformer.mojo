# =============================================================================
# test_direct_edge_conformer.mojo — the DIRECT/on-prem NO-OP `API_EDGE`
#   conformer gate (on-prem uses NO edge resource — the published edge URL
#   EQUALS the backend URL, scheme preserved verbatim).
# =============================================================================
#
# HERMETIC (no cloud, no seams AT ALL — the conformer's realization is ZERO
# resources). Proves the normative verb contract:
#   (1) OUTPUT CONTRACT: create publishes edge URL == backend URL VERBATIM —
#       including a plain-HTTP local URL (`http://localhost:8088` — the neutral
#       contract promises resolvability, NOT public TLS).
#   (2) SINGLE_PATH publishes the JOINED URL including `route_path` (consumers
#       never append or derive); CATCH_ALL publishes the bare base.
#   (3) read_status is PURE: ABSENT before the backend URL resolves; MATCHED
#       after (no drift is possible); update/delete are no-ops.
#   (4) The FRESH-FIRST-APPLY window: create before the backend URL converged
#       records nothing (placeholder physical id); the converge-poll re-read
#       (read_status) publishes once the backend records — end-to-end through
#       the real apply_graph engine over the erased node.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_iac import ResourceGraph, InMemoryStateStore
from kci_iac.resource import Creds, VERB_CREATE, VERB_NOOP, RETAIN_DELETE
from kci_iac.engine import apply_graph

from kci_edge import (
    DirectEdge,
    make_direct_edge_node,
    BackendAddressAccumulator,
    EdgeOutcomeAccumulator,
    EDGE_ROUTE_MODE_SINGLE_PATH,
    EDGE_ROUTE_MODE_CATCH_ALL,
    api_edge_client_node_id,
    api_edge_inbound_node_id,
    join_edge_url,
)


# The on-prem/local backend URL — deliberately PLAIN HTTP + a port: the output
# contract preserves the scheme VERBATIM (no https rewrite, no host rewrite).
comptime _LOCAL_URL: String = "http://localhost:8088"
comptime _CLUSTER_URL: String = "http://example-svc.example.svc.cluster.local"


def test_catch_all_publishes_backend_url_verbatim() raises:
    """CATCH_ALL: the published edge URL EQUALS the backend URL, scheme
    preserved verbatim (the on-prem output contract), and the physical id IS
    the URL."""
    var backend = BackendAddressAccumulator()
    backend.record_address(_LOCAL_URL)
    var acc = EdgeOutcomeAccumulator()
    var lid = api_edge_client_node_id(String("example-api"))
    var deps = List[String]()
    deps.append(String("example-api-svc"))
    var edge = DirectEdge(
        lid,
        EDGE_ROUTE_MODE_CATCH_ALL,
        String(""),
        backend.share(),
        acc.share(),
        deps^,
    )

    # read_status: the backend URL resolves -> MATCHED (no drift possible).
    var live = edge.read_status(Creds.none())
    assert_true(live.is_matched(), "resolvable backend URL -> MATCHED")

    var pid = edge.create(Creds.none())
    assert_equal(pid, _LOCAL_URL, "the physical id IS the URL")
    assert_equal(
        acc.url_for(lid),
        _LOCAL_URL,
        "published edge URL == backend URL, scheme verbatim (http preserved)",
    )
    assert_equal(edge.retention(), RETAIN_DELETE, "RETAIN_DELETE")
    # update / delete are no-ops (nothing raises; the URL stays recorded).
    edge.update(Creds.none())
    edge.delete(pid, Creds.none())
    assert_equal(acc.url_for(lid), _LOCAL_URL, "no-op verbs keep the URL")
    print("  test_catch_all_publishes_backend_url_verbatim: PASS")


def test_single_path_publishes_joined_url() raises:
    """SINGLE_PATH: the published URL is the JOINED URL including `route_path`
    (consumers never append)."""
    var backend = BackendAddressAccumulator()
    backend.record_address(_CLUSTER_URL)
    var acc = EdgeOutcomeAccumulator()
    var lid = api_edge_inbound_node_id(String("webhook"))
    var edge = DirectEdge(
        lid,
        EDGE_ROUTE_MODE_SINGLE_PATH,
        String("/hooks/inbound"),
        backend.share(),
        acc.share(),
        List[String](),
    )
    _ = edge.create(Creds.none())
    assert_equal(
        acc.url_for(lid),
        _CLUSTER_URL + String("/hooks/inbound"),
        "SINGLE_PATH publishes the joined URL (cluster-internal host verbatim)",
    )
    print("  test_single_path_publishes_joined_url: PASS")


def test_join_edge_url_normalizes_exactly_one_separator() raises:
    """join_edge_url: trailing-`/` base + leading-`/` path normalize to ONE
    separator; the scheme/host are never rewritten; empty path -> base verbatim."""
    assert_equal(
        join_edge_url(String("http://localhost:8088/"), String("/hooks/inbound")),
        String("http://localhost:8088/hooks/inbound"),
        "trailing+leading slash normalize to one",
    )
    assert_equal(
        join_edge_url(String("http://h:1"), String("p")),
        String("http://h:1/p"),
        "missing separators inserted",
    )
    assert_equal(
        join_edge_url(String("https://h"), String("")),
        String("https://h"),
        "empty path -> base verbatim",
    )
    print("  test_join_edge_url_normalizes_exactly_one_separator: PASS")


def test_fresh_window_absent_then_converge_poll_publishes() raises:
    """The fresh-first-apply window (the verb contract + the module-header
    record-on-read discipline): read_status is ABSENT before the backend URL
    resolves; create records NOTHING (placeholder physical id = the logical
    id); once the backend node records its URL, the converge-poll re-read
    (read_status) publishes it."""
    var backend = BackendAddressAccumulator()  # EMPTY — backend not yet serving
    var acc = EdgeOutcomeAccumulator()
    var lid = api_edge_client_node_id(String("example-app"))
    var edge = DirectEdge(
        lid,
        EDGE_ROUTE_MODE_CATCH_ALL,
        String(""),
        backend.share(),
        acc.share(),
        List[String](),
    )
    var live = edge.read_status(Creds.none())
    assert_true(live.is_absent(), "no backend URL yet -> ABSENT")
    var pid = edge.create(Creds.none())
    assert_equal(pid, lid, "fresh window: placeholder physical id = logical id")
    assert_equal(acc.count(), 0, "fresh window: nothing published yet")

    # The backend node converges + records its URL (as its read_status would).
    backend.record_address(_LOCAL_URL)
    var live2 = edge.read_status(Creds.none())
    assert_true(live2.is_matched(), "backend URL resolvable -> MATCHED")
    assert_equal(
        acc.url_for(lid), _LOCAL_URL,
        "the converge-poll re-read published the URL",
    )
    print("  test_fresh_window_absent_then_converge_poll_publishes: PASS")


def test_erased_node_applies_through_the_engine() raises:
    """The erased DirectEdge node drives through the REAL apply_graph engine —
    with ZERO cloud seams anywhere in the graph (the conformer touches none by
    construction; the mapper-level zero-seam-calls check lives with the
    mapper's own tests). Two applies pin the two live shapes:
      * apply #1 (genuinely fresh — backend URL not yet converged): ABSENT ->
        VERB_CREATE with the placeholder physical id (nothing published yet).
      * apply #2 (a re-deploy after the backend converged + recorded): the
        read_status MATCHED path -> VERB_NOOP, physical id == the URL, and the
        record-on-read publishes into the outcome sink."""
    var backend = BackendAddressAccumulator()  # EMPTY — a genuinely fresh env
    var acc = EdgeOutcomeAccumulator()
    var lid = api_edge_client_node_id(String("example-api"))
    var g = ResourceGraph()
    g.add(
        make_direct_edge_node(
            lid,
            EDGE_ROUTE_MODE_CATCH_ALL,
            String(""),
            backend.share(),
            acc.share(),
            List[String](),
        )
    )
    var store = InMemoryStateStore()
    var applied = apply_graph(g, Creds.none(), store)
    assert_equal(len(applied), 1, "the DirectEdge node applied")
    assert_equal(applied[0].logical_id, lid, "per-mode logical id")
    assert_equal(
        applied[0].verb, VERB_CREATE, "fresh env CREATEs (the record verb)"
    )
    assert_equal(
        applied[0].physical_id, lid,
        "fresh window: the placeholder physical id (URL not yet known)",
    )
    assert_equal(acc.count(), 0, "fresh window: nothing published yet")

    # The backend node converges + records its URL; a re-deploy NOOPs and the
    # record-on-read publishes (the converge-poll re-read shape).
    backend.record_address(_LOCAL_URL)
    var store2 = InMemoryStateStore()
    var applied2 = apply_graph(g, Creds.none(), store2)
    assert_equal(applied2[0].verb, VERB_NOOP, "resolvable backend URL -> NOOP")
    assert_equal(
        applied2[0].physical_id, _LOCAL_URL, "physical id = the URL"
    )
    assert_equal(acc.url_for(lid), _LOCAL_URL, "the outcome sink is populated")
    print("  test_erased_node_applies_through_the_engine: PASS")


def main() raises:
    test_catch_all_publishes_backend_url_verbatim()
    test_single_path_publishes_joined_url()
    test_join_edge_url_normalizes_exactly_one_separator()
    test_fresh_window_absent_then_converge_poll_publishes()
    test_erased_node_applies_through_the_engine()
    print(
        "OK: test_direct_edge_conformer (the DIRECT no-op API_EDGE conformer —"
        " edge URL == backend URL, scheme verbatim)"
        " — all assertions passed"
    )
