# =============================================================================
# komira_k8s/k8s_client.mojo — the K8sPodClient facade
# =============================================================================
#
# The entire production API: a thin assembly over config (k8s_config) +
# TLS/HTTP (k8s_tls) + JSON (k8s_json). The pod verbs:
#
#   create_pod(spec)              POST  /api/v1/namespaces/{ns}/pods
#   get_pod_status(ns, name)      GET   /api/v1/namespaces/{ns}/pods/{name}
#   get_pod_liveness(ns, name)    GET   .../pods/{name}
#   delete_pod(ns, name)          DELETE .../pods/{name}
#
# ⭐ `get_pod_liveness` IS A FOURTH READ VERB, NOT A WIDENING OF THE THIRD, AND
#   THE SEPARATION IS THE POINT. `get_pod_status` returns a `PodPhase` that a
#   job reconciler's entire ladder matches on; changing what it derives
#   changes every job's lifecycle. `get_pod_liveness` answers a DIFFERENT
#   question — "does this object still exist, and is it marked for deletion" —
#   over the same GET. See
#   `PodLiveness` (k8s_types.mojo) for why `PodPhase` structurally cannot answer
#   it: `derive_pod_phase` reads `status.*` and never `metadata`.
#
# The three idempotency swallows (load-bearing):
#   * create swallows HTTP 409 (already exists)  -> Ok
#   * get    maps     HTTP 404 -> PodPhase::NotFound
#   * delete swallows HTTP 404 (already gone)    -> Ok, `already_gone=True`
#
# Encapsulation: the public surface is typed values (PodCreateSpec, PodPhase,
# String) + `raises`. No UnsafePointer, JsonValue, or socket fd crosses the
# module boundary. The token is RE-READ per request (projected-token
# rotation) via cfg.read_token().
# =============================================================================

from komira_http.client.auth import BearerTokenProvider

from komira_k8s.k8s_config import InClusterConfig, K8sTokenSource
from komira_k8s.k8s_tls import (
    k8s_https_request_authed_blocking,
    HttpResponse,
)
from komira_k8s.k8s_json import (
    build_pod_manifest,
    derive_pod_phase,
    parse_pod_deletion_ack,
    parse_pod_list,
    parse_pod_liveness,
    status_reason,
    status_message,
    status_code,
    parse_json,
)
from komira_k8s.k8s_types import (
    PodCreateSpec,
    PodDeletionAck,
    PodLiveness,
    PodPhase,
    PodSummary,
    K8sError,
    K8S_ERR_FORBIDDEN,
    K8S_ERR_INVALID,
    K8S_ERR_UNAUTHORIZED,
    K8S_ERR_TRANSPORT,
    K8S_ERR_PROTOCOL,
)


# The SNI / cert CN the apiserver presents. K8s apiserver certs carry
# "kubernetes" (and the service IPs/DNS as SANs); the in-cluster client uses
# "kubernetes" as the server name.
comptime APISERVER_SNI = "kubernetes"


# -----------------------------------------------------------------------------
# Path builders.
# -----------------------------------------------------------------------------
def pods_collection_path(namespace: String) -> String:
    """POST (create) / GET (list) — the pod collection in a namespace."""
    return String("/api/v1/namespaces/") + namespace + "/pods"


def pod_resource_path(namespace: String, name: String) -> String:
    """GET (read) / DELETE — a single named pod."""
    return pods_collection_path(namespace) + "/" + name


def pod_log_subpath(namespace: String, name: String) -> String:
    """GET — the pod log subresource (`.../pods/<name>/log`). Query params
    (container / tailLines / previous) are appended by `get_pod_logs`."""
    return pod_resource_path(namespace, name) + "/log"


def _append_query(q: String, key: String, value: String) -> String:
    """Append `key=<encoded value>` to a query string `q`, choosing `?` for the
    first param and `&` thereafter. The value is percent-encoded; the key is a
    fixed ASCII identifier (no encoding needed)."""
    var sep = String("?") if q.byte_length() == 0 else String("&")
    return q + sep + key + "=" + _percent_encode_query(value)


def _percent_encode_query(s: String) -> String:
    """Percent-encode a query-parameter VALUE per RFC 3986. The labelSelector
    value contains `=` and `,` (e.g. `app=foo,tier=web`) which MUST be encoded
    in a query string. Unreserved chars (ALPHA / DIGIT / -._~) pass through;
    everything else becomes %XX."""
    var out = String()
    for b in s.as_bytes():
        var c = Int(b)
        var unreserved = (
            (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("a") and c <= ord("z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
            or c == ord(".")
            or c == ord("_")
            or c == ord("~")
        )
        if unreserved:
            out += chr(c)
        else:
            out += "%"
            out += _hex2(c)
    return out^


def _hex2(v: Int) -> String:
    var hi = (v >> 4) & 0xF
    var lo = v & 0xF
    return _hex1(hi) + _hex1(lo)


def _hex1(v: Int) -> String:
    if v < 10:
        return chr(ord("0") + v)
    return chr(ord("A") + (v - 10))


# =============================================================================
# WHICH HTTP STATUSES CONSTITUTE AN **OBSERVED ABSENCE**.
# =============================================================================
#
# ⭐⭐ THIS IS A SEPARATE, PURE FUNCTION FOR ONE REASON: IT IS THE SENTENCE THE
#   WHOLE VERIFIED-REVERT CONTRACT RESTS ON (a revert may report a pod gone only
#   when it OBSERVED it gone), AND IT IS THE ONE A LATER READER
#   IS MOST LIKELY TO "SIMPLIFY" INTO A BUG. Written inline inside the verb it
#   is three unremarkable lines of an `if` ladder that a live cluster is needed
#   to exercise; written here it is a total function over an Int that a
#   hermetic test can drive across every status the apiserver emits.
#
# ⛔ EXACTLY ONE STATUS MEANS ABSENT, AND IT IS 404. Everything else that is not
#   a 200 is an ERROR — 401 (token rotated), 403 (RBAC), 429 (throttled), 500,
#   502, 503, a TLS fault reported as 0. **NONE of them may become an absence.**
#   "I could not ask" and "it is not there" are different facts, and reporting
#   the first as the second is precisely the unobserved absence the
#   verified-revert verb exists to refuse: it would let a job be re-placed while
#   its prior pod is still running, producing TWO live supervisors driving one
#   job's phase.
# -----------------------------------------------------------------------------
comptime LIVENESS_PRESENT: Int = 0
"""HTTP 200 — the apiserver handed back the object. It exists."""

comptime LIVENESS_ABSENT: Int = 1
"""HTTP 404 — the apiserver says there is no such object. AN OBSERVED ABSENCE,
and the only wire outcome that is one."""

comptime LIVENESS_ERROR: Int = 2
"""Anything else. We did not learn whether the object exists; the verb RAISES so
the caller reports COULD-NOT-OBSERVE rather than an absence."""


def liveness_outcome_for_status(status: Int) -> Int:
    """Map an HTTP status from a pod GET to `LIVENESS_PRESENT` /
    `LIVENESS_ABSENT` / `LIVENESS_ERROR`.

    ⛔ THE DEFAULT ARM IS `LIVENESS_ERROR`, AND IT MUST STAY THE DEFAULT. A
    ladder whose fall-through were `ABSENT` would turn every apiserver outage,
    every expired token and every RBAC misconfiguration into "the pod is gone" —
    an answer that authorises re-placing a job whose pod is still running."""
    if status == 200:
        return LIVENESS_PRESENT
    if status == 404:
        return LIVENESS_ABSENT
    return LIVENESS_ERROR


# =============================================================================
# K8sPodClient — the 3-verb facade.
# =============================================================================
struct K8sPodClient(Movable):
    """The narrow K8s pod client. Owns the `InClusterConfig`; constructed once
    and moved into the caller's app state. Each operation opens a fresh
    TLS connection (Connection: close — the right shape for a control plane's
    low QPS) and re-reads the SA token (projected-token rotation)."""

    var _cfg: InClusterConfig
    var _verify_cert: Bool
    var _server_name: String

    def __init__(
        out self,
        var cfg: InClusterConfig,
        verify_cert: Bool = True,
        server_name: String = String(APISERVER_SNI),
    ):
        """`cfg` is the config (in-cluster loader OR `from_explicit`).

        `verify_cert` (default True) pins `cfg.ca_pem` (wipe OS roots +
        add_trust_pem) — keep True in production AND for kind (the kind CA is in
        the supplied PEM). `server_name` is the TLS SNI / cert CN to validate
        against: defaults to the in-cluster `"kubernetes"`. For out-of-cluster
        use the apiserver is reached at `127.0.0.1:<port>` but the cert's CN is
        the apiserver — kind certs carry `kubernetes` / `127.0.0.1` SANs, so the
        harness sets `server_name` to whichever SAN the extracted cert presents
        (commonly `"kubernetes"`)."""
        self._cfg = cfg^
        self._verify_cert = verify_cert
        self._server_name = server_name

    def config(ref self) -> ref [self._cfg] InClusterConfig:
        return self._cfg

    # -------------------------------------------------------------------------
    # _do — one apiserver round-trip with the live (re-read) token.
    #
    # The transport is `komira_http`'s HttpClient over a CA-pinned
    # TlsConnector, driven SYNCHRONOUSLY via a `BlockingRuntime` that
    # `k8s_https_request_authed_blocking` stands up on the calling thread. The
    # verbs stay reactor-free — single-shot, low-QPS control plane — while the
    # `[RT]`-parametric capability lives on the transport
    # (`k8s_https_request_authed[RT]`) for async callers.
    # -------------------------------------------------------------------------
    def _do(
        self, method: String, path: String, body: String
    ) raises -> HttpResponse:
        # Pluggable auth seam: a BearerTokenProvider over the config's
        # K8sTokenSource. The provider's `apply` re-reads the SA token file on
        # every request (projected-token rotation) — the rotation lives
        # inside the komira_http auth seam, not hand-wired here.
        var auth = BearerTokenProvider(self._cfg.token_source())
        return k8s_https_request_authed_blocking(
            self._cfg.ca_pem,
            self._server_name,
            self._verify_cert,
            self._cfg.apiserver_host,
            self._cfg.apiserver_port_u16(),
            method,
            path,
            auth,
            body,
        )

    # -------------------------------------------------------------------------
    # _classify_error — map a non-2xx apiserver response to a typed K8sError.
    # The caller decides idempotency swallows BEFORE calling this (409/404 are
    # handled per-verb); this maps the remaining error codes.
    # -------------------------------------------------------------------------
    def _classify_error(self, resp: HttpResponse) raises -> K8sError:
        var reason = String("")
        var detail: String
        # The apiserver returns a `kind: Status` envelope on every error; parse
        # it best-effort (a transport-layer 5xx may not be JSON).
        try:
            var jv = parse_json(resp.body)
            reason = status_reason(jv)
            detail = status_message(jv)
            var sc = status_code(jv)
            if sc != 0 and resp.status == 0:
                pass  # body code only used if HTTP status missing (rare)
        except:
            detail = resp.body  # non-JSON body (e.g. raw 5xx text)

        var c = resp.status
        if c == 401:
            return K8sError(K8S_ERR_UNAUTHORIZED, c, reason, detail)
        if c == 403:
            return K8sError(K8S_ERR_FORBIDDEN, c, reason, detail)
        if c == 422 or c == 400:
            return K8sError(K8S_ERR_INVALID, c, reason, detail)
        if c >= 500:
            return K8sError(K8S_ERR_TRANSPORT, c, reason, detail)
        return K8sError(K8S_ERR_PROTOCOL, c, reason, detail)

    # =========================================================================
    # create_pod — POST manifest; 2xx => Ok; 409 => Ok (idempotent).
    # =========================================================================
    def create_pod(self, spec: PodCreateSpec) raises:
        """Create a pod from a typed `PodCreateSpec`. 201/200 => Ok; 409 (pod
        already exists) is SWALLOWED => Ok (idempotent create). Other non-2xx
        => typed K8sError."""
        var path = pods_collection_path(spec.namespace)
        var body = build_pod_manifest(spec)
        var resp = self._do(String("POST"), path, body)
        if resp.status == 200 or resp.status == 201:
            return
        if resp.status == 409:
            return  # idempotency swallow: pod already exists
        raise self._classify_error(resp).as_error()

    # =========================================================================
    # get_pod_status — GET; 200 => derive phase; 404 => NotFound.
    # =========================================================================
    def get_pod_status(
        self, namespace: String, name: String
    ) raises -> PodPhase:
        """Read a pod's status and derive a `PodPhase`. 200 => derived phase
        (containerStatuses[0].state.* preferred, else status.phase); 404 =>
        PodPhase::NotFound (idempotency map). Other non-2xx => typed K8sError."""
        var path = pod_resource_path(namespace, name)
        var resp = self._do(String("GET"), path, String(""))
        if resp.status == 404:
            return PodPhase.not_found()  # idempotency map
        if resp.status == 200:
            var jv = parse_json(resp.body)
            return derive_pod_phase(jv)
        raise self._classify_error(resp).as_error()

    # =========================================================================
    # get_pod_liveness — THE FOURTH READ VERB.
    #   GET; 200 => present + deletion mark + phase; 404 => OBSERVED ABSENCE.
    # =========================================================================
    def get_pod_liveness(
        self, namespace: String, name: String
    ) raises -> PodLiveness:
        """Read whether a pod still EXISTS, and whether it is marked for
        deletion. The same GET as `get_pod_status`, reporting the two
        `metadata` fields that function structurally cannot see.

        ⭐ WHY THIS EXISTS AT ALL. On Kubernetes a `DELETE` is not a removal:
        it writes `metadata.deletionTimestamp` and starts a grace period, and
        the object survives — READABLE, with its containers possibly STILL
        RUNNING — until the kubelet confirms termination. A pod on an
        unreachable node stays that way indefinitely. `derive_pod_phase` reads
        `status.*` only, so it reports such a pod as `Running`: through
        `get_pod_status` alone, `Terminating` and `Running` are the same answer.

        THE THREE OUTCOMES, and the mapping is `liveness_outcome_for_status`:
          * **200** — `PodLiveness(present=True, ...)` carrying
            `deletionTimestamp` / `deletionGracePeriodSeconds` / the derived
            phase.
          * **404** — `PodLiveness.absent()`. ⭐ THE OBSERVED ABSENCE. This is
            the only wire outcome in this client that authorises a caller to
            report a pod GONE.
          * **anything else** — RAISES a typed `K8sError`. ⛔ A 403, a 500 or a
            transport fault MUST NOT become an absence: we did not learn whether
            the pod exists, and saying we did would let a job be re-placed while
            its prior supervisor is still running.

        ⛔ DO NOT "SIMPLIFY" THIS INTO `get_pod_status(...) == NotFound`. That
        composition answers the same thing only until anything caches a
        terminal or a tombstone — at which point "NotFound" stops meaning
        "observed absent"."""
        var path = pod_resource_path(namespace, name)
        var resp = self._do(String("GET"), path, String(""))
        var outcome = liveness_outcome_for_status(resp.status)
        if outcome == LIVENESS_ABSENT:
            return PodLiveness.absent()
        if outcome == LIVENESS_PRESENT:
            return parse_pod_liveness(parse_json(resp.body))
        raise self._classify_error(resp).as_error()

    # =========================================================================
    # delete_pod — DELETE; 200/202 => Ok; 404 => Ok (idempotent).
    # =========================================================================
    def delete_pod(
        self, namespace: String, name: String
    ) raises -> PodDeletionAck:
        """Delete a pod. 200/202 => Ok; 404 (already gone) is SWALLOWED => Ok
        (idempotent delete). Other non-2xx => typed K8sError.

        ⭐ IT RETURNS WHAT THE APISERVER SAID. A pod DELETE answers **200 with
        the Pod object** — carrying the `deletionTimestamp` it just wrote and
        the `deletionGracePeriodSeconds` it just started. That is observed, not
        assumed: a capture from a live kind apiserver is this package's DELETE
        test fixture. It is the one piece of evidence the apiserver hands back
        for free — *"I accepted your deletion, here is its deadline"*.

        ⛔⛔ THE ACK IS NOT AN ABSENCE. `accepted=True` means the deletion is
        durable in etcd, NOT that anything stopped; the containers may still be
        running, and on an unreachable node they may run forever. Confirm with
        `get_pod_liveness`. A caller that reads this return as "it is gone" has
        re-created the bug a verified revert exists to prevent.

        The query string is EMPTY: this verb sends no
        `gracePeriodSeconds`, and ⛔ must not start. `?gracePeriodSeconds=0` is
        a FORCE delete, which removes the API object without waiting for
        confirmation that the container stopped — it MANUFACTURES the 404 a
        caller is required to OBSERVE."""
        var path = pod_resource_path(namespace, name)
        var resp = self._do(String("DELETE"), path, String(""))
        if resp.status == 200 or resp.status == 202:
            # A 200 body IS the Pod object. A 202 (or any accepted response
            # whose body is not a Pod) parses to an ack with no mark — honest:
            # accepted, deadline unknown. A malformed body must not fail a
            # delete that the apiserver accepted, so the parse is best-effort.
            try:
                return parse_pod_deletion_ack(parse_json(resp.body))
            except:
                return PodDeletionAck(True, False, String(""), -1)
        if resp.status == 404:
            return PodDeletionAck.already_absent()  # idempotency swallow
        raise self._classify_error(resp).as_error()

    # =========================================================================
    # get_pod_logs — GET .../pods/<name>/log (text body, NOT JSON).
    # =========================================================================
    def get_pod_logs(
        self,
        namespace: String,
        name: String,
        container: String = String(""),
        tail_lines: Int = -1,
        previous: Bool = False,
    ) raises -> String:
        """Fetch a pod's container log (forensics when a job fails). GET
        `/api/v1/namespaces/<ns>/pods/<name>/log`. The response body is PLAIN
        TEXT (not JSON), returned verbatim as an owned String.

        Optional query params:
          * `container`   — which container's log (required for multi-container
                            pods; "" => the pod's single/default container).
          * `tail_lines`  — last N lines only (-1 => the full log).
          * `previous`    — the PREVIOUS terminated container's log (crash
                            forensics) instead of the current one.

        200 => the log text. 404 => raises (pod/container gone — unlike get,
        a missing pod is not an idempotent no-op for logs). Other non-2xx =>
        typed K8sError (the error body IS a JSON Status envelope, so classify
        runs)."""
        var path = pod_log_subpath(namespace, name)
        var q = String("")
        if container.byte_length() > 0:
            q = _append_query(q, String("container"), container)
        if tail_lines >= 0:
            q = _append_query(q, String("tailLines"), String(tail_lines))
        if previous:
            q = _append_query(q, String("previous"), String("true"))
        var resp = self._do(String("GET"), path + q, String(""))
        if resp.status == 200:
            return resp.body
        raise self._classify_error(resp).as_error()

    # =========================================================================
    # list_pods — GET .../pods?labelSelector=... -> [PodSummary].
    # =========================================================================
    def list_pods(
        self, namespace: String, label_selector: String = String("")
    ) raises -> List[PodSummary]:
        """List pods in a namespace (orphan-pod GC + ops listing). GET
        `/api/v1/namespaces/<ns>/pods?labelSelector=...`. Parses the `PodList`
        and returns one `PodSummary` (name + namespace + derived phase) per
        item — the phase derivation matches `get_pod_status` exactly.

        `label_selector` ("" => all pods in the namespace) is a K8s selector
        expression like `app=example,example.dev/managed-by=job-manager`; it is
        percent-encoded into the query. 200 => the parsed list (possibly empty);
        non-2xx => typed K8sError."""
        var path = pods_collection_path(namespace)
        var q = String("")
        if label_selector.byte_length() > 0:
            q = _append_query(
                q, String("labelSelector"), label_selector
            )
        var resp = self._do(String("GET"), path + q, String(""))
        if resp.status == 200:
            var jv = parse_json(resp.body)
            return parse_pod_list(jv)
        raise self._classify_error(resp).as_error()
