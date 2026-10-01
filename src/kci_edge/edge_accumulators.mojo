# =============================================================================
# kci_edge/edge_accumulators.mojo — the provider-neutral edge output->input seams.
# =============================================================================
#
# WHY A NEUTRAL HOME. The `API_EDGE` resource node (kind 19) is realized per
# target: a cloud gateway (GCP, and in future AWS/Azure), or the DIRECT no-op
# conformer on Kubernetes / local compose, where on-prem uses no edge resource
# at all. The DIRECT conformer must be usable by an on-prem build with zero
# cloud deps, so the shared accumulator seams it reads and writes live here
# (deps: `kci_iac` + std only), not in a cloud bridge package. The GCP bridge
# (`komira_gcp_bridge`) imports and re-exports `BackendAddressAccumulator`.
#
# TWO SEAMS, TWO DIRECTIONS:
#   * `BackendAddressAccumulator` — INPUT: the backend ServerlessCompute node
#     records its LIVE serving URL (read_status, off the live service read); the
#     edge node reads it (GCP: the OpenAPI x-google-backend address +
#     jwt_audience; DIRECT: the published edge URL ITSELF — edge URL == backend
#     URL, the on-prem contract).
#   * `EdgeOutcomeAccumulator` — OUTPUT: each edge node records its PUBLISHED
#     edge URL (keyed by the node's logical_id — N edge nodes share ONE sink),
#     and the driver reads the entries after apply_graph to publish
#     `service/<logical_id>` -> URL to the registry. It is KEYED because one
#     manifest may carry N edge nodes (two edges in front of one backend may
#     coexist).
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ArcPointer interior — a SINGLE-thread synchronous apply_graph drive, NOT
# concurrent state under a fork-join barrier. Flat owned Strings / a List of
# flat-String rows; no wildcard origin, no byte-slab, ZERO UnsafePointer, so no
# stale-pointer hazard across destroy and recreate.
# =============================================================================

from std.memory import ArcPointer


# -----------------------------------------------------------------------------
# BackendAddressAccumulator — the backend's LIVE serving URL, backend -> edge.
# (`komira_gcp_bridge` re-exports it.)
# -----------------------------------------------------------------------------
struct _BackendAddrState(Movable):
    """The accumulator interior — the backend's runtime serving URL (a single
    owned String; no wildcard, no byte-slab)."""

    var address: String

    def __init__(out self):
        self.address = String("")


struct BackendAddressAccumulator(Movable, Deinitable):
    """A shared, mutable accumulator the backend ServerlessCompute node writes its
    LIVE serving URL into (via `record_address`, off the `CloudRunService.uri` its
    `read_status` reads) and the edge node reads via `address()` at create time
    (GCP: to stamp the OpenAPI x-google-backend address at the REAL backend URL;
    DIRECT: as the published edge URL itself). Behind an
    `ArcPointer[_BackendAddrState]` so a `share()`d handle each node holds points
    at ONE state. Single-threaded synchronous drive. Empty until the
    backend node's read_status found a live service (a fresh first-deploy falls
    back per-conformer; a steady-state reconcile reads the converged live URL)."""

    var _p: ArcPointer[_BackendAddrState]

    def __init__(out self):
        self._p = ArcPointer[_BackendAddrState](_BackendAddrState())

    def __init__(out self, *, var _share: ArcPointer[_BackendAddrState]):
        self._p = _share^

    def share(self) -> BackendAddressAccumulator:
        """A SECOND handle over ONE `_BackendAddrState` (the backend node writes;
        the edge node reads). SAFETY: ArcPointer ref-counted shared ownership;
        a single-thread synchronous apply_graph."""
        return BackendAddressAccumulator(
            _share=ArcPointer[_BackendAddrState](copy=self._p)
        )

    def record_address(mut self, address: String):
        """Record the backend's LIVE serving URL (the backend node's read_status
        reads it off `CloudRunService.uri`). Idempotent — the last writer wins;
        an empty uri is not recorded (keeps the edge-side fallback in effect)."""
        if address.byte_length() > 0:
            self._p[].address = address

    def address(self) -> String:
        """The accumulated backend serving URL (empty until the backend node's
        read_status found a live service). The GCP edge stamps this into the
        OpenAPI x-google-backend address when non-empty; the DIRECT edge
        publishes it verbatim (edge URL == backend URL)."""
        return self._p[].address


# -----------------------------------------------------------------------------
# EdgeOutcomeAccumulator — the published edge URL(s), edge -> driver (KEYED).
# -----------------------------------------------------------------------------
struct _EdgeUrlRow(Copyable, Movable):
    """One (logical_id -> published URL + ORIGIN) row. Flat Strings.

    ★ TWO FIELDS, ONE OBSERVATION, AND THAT IS THE WHOLE POINT. For a SINGLE_PATH
    edge the published `url` carries the route (`https://host/hooks/inbound`) while
    the `origin` is the bare scheme+authority (`https://host`). A consumer that
    needs the origin and is handed only the url has exactly two ways to get it, and
    BOTH are defects: STRIP THE KNOWN SUFFIX (silently wrong the day the route
    changes), or
    RE-PARSE the url (a second implementation of `edge_origin_from_host`, which is
    the drift this package exists to prevent). So the conformer — which holds the
    ONE observed hostname and the ONE formatter — records both, and neither
    consumer derives anything."""

    var logical_id: String
    var url: String
    var origin: String

    def __init__(
        out self, var logical_id: String, var url: String, var origin: String
    ):
        self.logical_id = logical_id^
        self.url = url^
        self.origin = origin^


struct _EdgeOutcomeState(Movable):
    """The accumulator interior — the per-edge-node published URLs, in
    first-recorded order (deterministic driver publish order). A typed List of
    flat-String rows; no wildcard, no byte-slab."""

    var rows: List[_EdgeUrlRow]

    def __init__(out self):
        self.rows = List[_EdgeUrlRow]()


struct EdgeOutcomeAccumulator(Movable, Deinitable):
    """The shared OUTPUT sink every kind-19 edge node reports its PUBLISHED edge
    URL into, KEYED by the node's `logical_id` (one manifest may carry N edge
    nodes that coexist), and the driver reads after `apply_graph` to publish
    `service/<logical_id>` -> URL to the registry. The published shape:
    CATCH_ALL records the bare base `scheme://host`; SINGLE_PATH records the
    JOINED URL including `route_path` — consumers never append or derive.
    Single-threaded synchronous drive."""

    var _p: ArcPointer[_EdgeOutcomeState]

    def __init__(out self):
        self._p = ArcPointer[_EdgeOutcomeState](_EdgeOutcomeState())

    def __init__(out self, *, var _share: ArcPointer[_EdgeOutcomeState]):
        self._p = _share^

    def share(self) -> EdgeOutcomeAccumulator:
        """A SECOND handle over ONE `_EdgeOutcomeState` (each edge node holds a
        share()d handle; the driver reads the aggregate). SAFETY: ArcPointer
        ref-counted shared ownership; a single-thread synchronous apply_graph."""
        return EdgeOutcomeAccumulator(
            _share=ArcPointer[_EdgeOutcomeState](copy=self._p)
        )

    def record_url(
        mut self, logical_id: String, url: String, origin: String
    ):
        """Record `logical_id`'s published edge URL (the conformer
        joins `route_path` for SINGLE_PATH before recording) AND the bare ORIGIN
        that url was built on. Idempotent: a re-record of the same key overwrites
        in place (last writer wins — the converge-poll re-read path); an EMPTY url
        is not recorded (the fresh-first-deploy window keeps the key absent rather
        than publishing an empty row).

        ⛔ `origin` IS A REQUIRED ARGUMENT, NOT A DEFAULTED ONE. A default would
        let a call site record a url with no origin and nothing would say so — the
        origin reader would then see "no public front door observed" for an edge
        that plainly has one, which is indistinguishable from the pre-converge
        window it is supposed to mean. Every conformer already holds the value
        (it built the url out of it), so the third argument costs a caller
        nothing and closes the only way this can be half-recorded."""
        if url.byte_length() == 0:
            return
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                self._p[].rows[i].url = url.copy()
                self._p[].rows[i].origin = origin.copy()
                return
        self._p[].rows.append(
            _EdgeUrlRow(logical_id.copy(), url.copy(), origin.copy())
        )

    def logical_ids(self) -> List[String]:
        """The recorded edge-node logical_ids, in first-recorded order (the
        driver's deterministic registry-publish order)."""
        var out = List[String]()
        for i in range(len(self._p[].rows)):
            out.append(self._p[].rows[i].logical_id.copy())
        return out^

    def url_for(self, logical_id: String) -> String:
        """The published URL recorded for `logical_id` (empty when that edge
        node has not converged its URL — the driver skips the registry write
        rather than publishing an empty URL)."""
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                return self._p[].rows[i].url.copy()
        return String("")

    def origin_for(self, logical_id: String) -> String:
        """The bare ORIGIN (scheme+authority, no route, no trailing slash) of the
        edge recorded for `logical_id` — EMPTY when that edge node has not
        converged.

        ⛔ EMPTY MEANS "NO PUBLIC FRONT DOOR HAS BEEN OBSERVED", NEVER "use
        something else" — the `edge_origin_from_host` discipline, verbatim,
        because this is the same value travelling one hop further. The one caller
        that persists it (a deployment record's ingress origin) must write NOTHING on
        empty rather than `""`: a stored empty string satisfies every presence
        check, so a reader treats the app as having a public address and publishes
        nothing to a third party that can reach it."""
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                return self._p[].rows[i].origin.copy()
        return String("")

    def first_url(self) -> String:
        """The FIRST recorded edge URL (empty when none) — the
        edge-URL sentinel resolution for the common
        one-edge-per-bundle shape (a single client-facing edge). A multi-edge
        bundle's validate step should key on the registry row instead."""
        if len(self._p[].rows) == 0:
            return String("")
        return self._p[].rows[0].url.copy()

    def count(self) -> Int:
        """The number of edge nodes that recorded a published URL."""
        return len(self._p[].rows)
