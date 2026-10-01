# =============================================================================
# komira_k8s/k8s_types.mojo — typed public surface (PodCreateSpec / PodPhase /
# K8sError / EnvVar / KeyValue)
# =============================================================================
#
# The typed values the K8s pod client takes and
# returns. JSON is an INTERNAL wire detail (k8s_json.mojo); these types are
# what crosses the public boundary — no JsonValue, no UnsafePointer, no socket
# fd escapes.
#
# Encapsulation: every field is an owned safe type (String / Int / List of
# owned structs). All structs are Movable; constructed once and moved into the
# caller's app state. No heap-owning fields stored in any byte-slab (there are
# no byte-slabs in this package).
# =============================================================================


# -----------------------------------------------------------------------------
# EnvVar / KeyValue — the small POD-ish records inside a PodCreateSpec.
# -----------------------------------------------------------------------------
@fieldwise_init
struct EnvVar(Copyable, Movable):
    """A container environment variable (name=value). The reconciler sets
    RUST_LOG and similar via this."""

    var name: String
    var value: String


@fieldwise_init
struct KeyValue(Copyable, Movable):
    """A metadata label (key=value), e.g. `app`, a job id, a managed-by
    marker."""

    var key: String
    var value: String


# -----------------------------------------------------------------------------
# PodCreateSpec — the typed manifest input to create_pod (NOT raw JSON).
# -----------------------------------------------------------------------------
struct PodCreateSpec(Copyable, Movable):
    """Typed pod-create input. The fields a job pod needs.
    `restart_policy=Never`
    and `image_pull_policy=IfNotPresent` are constants, not fields."""

    var name: String
    var namespace: String
    var image: String
    var args: List[String]  # container args (CLI flags)
    var env: List[EnvVar]  # container env (incl. RUST_LOG)
    var cpu: String  # Quantity, e.g. "256m" ("" => omit)
    var memory: String  # Quantity, e.g. "512Mi" ("" => omit)
    var labels: List[KeyValue]

    def __init__(out self, name: String, namespace: String, image: String):
        """Minimal spec — name + namespace + image; the rest default empty.
        Callers append args/env/labels and set cpu/memory after construction."""
        self.name = name
        self.namespace = namespace
        self.image = image
        self.args = List[String]()
        self.env = List[EnvVar]()
        self.cpu = String("")
        self.memory = String("")
        self.labels = List[KeyValue]()


# -----------------------------------------------------------------------------
# PodSummary — one entry in a list_pods result (name + namespace + phase). Just
# enough for orphan-pod GC + ops listing; NOT the full Pod object.
# -----------------------------------------------------------------------------
struct PodSummary(Copyable, Movable):
    """A single pod as returned by `list_pods`: its name, namespace, and
    derived `PodPhase`. The reconciler / GC uses (name, phase); namespace is
    carried for cross-namespace listings. Plain owned fields — no byte-slab,
    no wildcard origin."""

    var name: String
    var namespace: String
    var phase: PodPhase

    def __init__(
        out self, name: String, namespace: String, var phase: PodPhase
    ):
        self.name = name
        self.namespace = namespace
        self.phase = phase^


# -----------------------------------------------------------------------------
# PodPhase — the status enum the reconciler matches on. A tag + carried fields (exit_code / message / raw), Mojo-shaped.
# -----------------------------------------------------------------------------
comptime POD_PENDING: Int = 0
comptime POD_RUNNING: Int = 1
comptime POD_SUCCEEDED: Int = 2
comptime POD_FAILED: Int = 3
comptime POD_NOTFOUND: Int = 4
comptime POD_UNKNOWN: Int = 5


struct PodPhase(Copyable, Movable):
    """The pod-status the reconciler maps to a job transition. `tag` is one of
    the POD_* constants; `exit_code` is set only for Failed (container
    terminated non-zero); `message` carries the failure reason; `raw` is the
    underlying apiserver phase/reason string for diagnostics."""

    var tag: Int
    var exit_code: Optional[Int]
    var message: String
    var raw: String

    def __init__(out self, tag: Int):
        self.tag = tag
        self.exit_code = None
        self.message = String("")
        self.raw = String("")

    @staticmethod
    def pending(raw: String = String("Pending")) -> PodPhase:
        var p = PodPhase(POD_PENDING)
        p.raw = raw
        return p^

    @staticmethod
    def running(raw: String = String("Running")) -> PodPhase:
        var p = PodPhase(POD_RUNNING)
        p.raw = raw
        return p^

    @staticmethod
    def succeeded(raw: String = String("Succeeded")) -> PodPhase:
        var p = PodPhase(POD_SUCCEEDED)
        p.exit_code = Optional[Int](0)
        p.raw = raw
        return p^

    @staticmethod
    def failed(exit_code: Int, message: String, raw: String) -> PodPhase:
        var p = PodPhase(POD_FAILED)
        p.exit_code = Optional[Int](exit_code)
        p.message = message
        p.raw = raw
        return p^

    @staticmethod
    def not_found() -> PodPhase:
        var p = PodPhase(POD_NOTFOUND)
        p.raw = String("NotFound")
        return p^

    @staticmethod
    def unknown(raw: String) -> PodPhase:
        var p = PodPhase(POD_UNKNOWN)
        p.raw = raw
        return p^

    def is_terminal(self) -> Bool:
        """True if the pod reached a terminal state (Succeeded / Failed /
        NotFound) — the reconciler stops polling on terminal."""
        return (
            self.tag == POD_SUCCEEDED
            or self.tag == POD_FAILED
            or self.tag == POD_NOTFOUND
        )

    def tag_name(self) -> StaticString:
        if self.tag == POD_PENDING:
            return "Pending"
        if self.tag == POD_RUNNING:
            return "Running"
        if self.tag == POD_SUCCEEDED:
            return "Succeeded"
        if self.tag == POD_FAILED:
            return "Failed"
        if self.tag == POD_NOTFOUND:
            return "NotFound"
        return "Unknown"


# =============================================================================
# THE DELETION-EVIDENCE PAIR — `PodDeletionAck` (what the DELETE said) and
# `PodLiveness` (what a fresh GET says).
# =============================================================================
#
# ⭐ READ THIS BEFORE CHANGING EITHER STRUCT. These two types exist for ONE
#   reason, and it is a correctness reason rather than an ergonomic one.
#
#   ON KUBERNETES, DELETION IS ASYNCHRONOUS. A `DELETE` that returns 200 has
#   not removed anything: it has written `metadata.deletionTimestamp` into
#   etcd and started a grace period, and the apiserver removes the object only
#   after the kubelet confirms the containers stopped. A pod whose NODE IS
#   UNREACHABLE therefore stays `Terminating` INDEFINITELY, WITH ITS
#   CONTAINERS STILL RUNNING.
#
#   ⛔ AND `PodPhase` CANNOT SEE THAT. `derive_pod_phase` reads
#   `status.containerStatuses[0].state.*` and falls back to `status.phase` —
#   it never consults `metadata`. So a terminating pod whose container is
#   still up derives `Running`, byte-for-byte identically to a pod nobody
#   asked to delete. `deletionTimestamp` lives in `metadata`, and these are
#   the two values that carry it out of the wire layer.
#
# ⛔ WHY NOT WIDEN `get_pod_status` / `PodPhase` INSTEAD. `PodPhase` is what
#   a job reconciler's whole ladder matches on; changing what it
#   derives changes every job's lifecycle. A separate read verb returning a
#   separate type changes nothing that already exists.
# -----------------------------------------------------------------------------


struct PodDeletionAck(Copyable, Movable):
    """WHAT THE APISERVER SAID WHEN WE ASKED IT TO DELETE — the response body
    of `delete_pod`, which for a k8s pod DELETE is the Pod object itself.

    ⛔ THIS IS NOT AN OBSERVATION OF ABSENCE AND MUST NEVER BE READ AS ONE. It
    is an observation that a deletion was ACCEPTED, plus the DEADLINE the
    apiserver attached to it. The absence has to be observed separately, by a
    fresh read (`PodLiveness`).

    `accepted`      — the apiserver returned 200/202: it took the deletion and
                      (for 200) handed back the marked object.
    `already_gone`  — the apiserver returned 404: there was NOTHING TO DELETE.
                      ⛔ Kept as its own field rather than folded into
                      `accepted`, because "I deleted it" and "there was nothing
                      there" are two different observations and collapsing them
                      is exactly the swallow a verified revert must refuse.
    `deletion_timestamp` — `metadata.deletionTimestamp`, "" when the body
                      carried none (a 202, a 404, or a non-conforming proxy).
    `grace_period_seconds` — `metadata.deletionGracePeriodSeconds`, or -1 when
                      absent. ⛔ -1, NOT 0: zero is a REAL value on the wire and
                      it means FORCE DELETE (remove the object without waiting
                      for the kubelet), which is the single most dangerous
                      value this field can hold. "Absent" and "forced" must not
                      be the same byte."""

    var accepted: Bool
    var already_gone: Bool
    var deletion_timestamp: String
    var grace_period_seconds: Int

    def __init__(
        out self,
        accepted: Bool,
        already_gone: Bool,
        deletion_timestamp: String,
        grace_period_seconds: Int,
    ):
        self.accepted = accepted
        self.already_gone = already_gone
        self.deletion_timestamp = deletion_timestamp
        self.grace_period_seconds = grace_period_seconds

    @staticmethod
    def already_absent() -> PodDeletionAck:
        """The 404 swallow: the apiserver had no such pod, so nothing was
        deleted and no deadline exists."""
        return PodDeletionAck(False, True, String(""), -1)

    def is_marked(self) -> Bool:
        """True iff the acknowledged body carried a `deletionTimestamp` — i.e.
        the apiserver's reclamation intent is DURABLE IN ETCD and the cluster
        owns finishing it. Still not an absence."""
        return self.deletion_timestamp.byte_length() > 0

    def deadline_phrase(self) -> String:
        """A human phrase naming the accepted deletion and its deadline, for the
        `raw` an operator reads. Empty when the DELETE carried no mark.

        ⚠ THIS IS THE OPERATOR'S ONLY CLOCK. "Terminating, 4 seconds in" is
        normal; "Terminating, 40 minutes in" means the node is unreachable and a
        human must force-delete. Both are the same TAG, so the distinction lives
        entirely in this string."""
        if not self.is_marked():
            return String("")
        var s = String("DELETE accepted, deletionTimestamp=")
        s += self.deletion_timestamp
        if self.grace_period_seconds >= 0:
            s += ", grace "
            s += String(self.grace_period_seconds)
            s += "s"
        else:
            s += ", grace UNSTATED"
        return s^


struct PodLiveness(Copyable, Movable):
    """WHAT A FRESH READ SAYS EXISTS RIGHT NOW — the return of the fourth
    `K8sPodClient` read verb, `get_pod_liveness`.

    `present` — the GET returned an object (200). **`False` ONLY on a 404.** A
                403, a 500, a TLS fault or a malformed body RAISES; none of them
                may ever produce `present=False`, because "I could not ask" is
                not "it is not there".
    `deletion_timestamp` / `grace_period_seconds` — `metadata.*`, the two fields
                `PodPhase` structurally cannot see. See `PodDeletionAck` for why
                the grace sentinel is -1 and not 0.
    `phase`   — the SAME `derive_pod_phase` the reconciler's `get_pod_status`
                uses, so a liveness read and a status poll never disagree about
                what the containers are doing."""

    var present: Bool
    var deletion_timestamp: String
    var grace_period_seconds: Int
    var phase: PodPhase

    def __init__(
        out self,
        present: Bool,
        deletion_timestamp: String,
        grace_period_seconds: Int,
        var phase: PodPhase,
    ):
        self.present = present
        self.deletion_timestamp = deletion_timestamp
        self.grace_period_seconds = grace_period_seconds
        self.phase = phase^

    @staticmethod
    def absent() -> PodLiveness:
        """THE OBSERVED ABSENCE — a GET that returned 404. This is the ONLY
        value in this module that authorises a caller to report a pod gone, and
        it is constructible from exactly one wire outcome on purpose."""
        return PodLiveness(False, String(""), -1, PodPhase.not_found())

    def is_terminating(self) -> Bool:
        """True iff the pod is present AND carries a `deletionTimestamp` — the
        state `PodPhase` alone reports as `Running`.

        ⚠ THERE IS DELIBERATELY NO `terminating_phrase()` HERE to sit beside
        `PodDeletionAck.deadline_phrase()`. The operator-facing deadline is
        composed from BOTH observations at one caller site,
        because `deletionGracePeriodSeconds` is OPTIONAL on a read and the
        DELETE's own response is where it is guaranteed. Two spellings of that
        phrase is exactly the drift that leaves one of them wrong."""
        return self.present and self.deletion_timestamp.byte_length() > 0


# -----------------------------------------------------------------------------
# K8sError — the typed error the client raises for non-idempotent failures.
# Carried in a Mojo `Error` message string with a stable prefix so callers can
# classify; `K8sError.*` constructors build the canonical message.
# -----------------------------------------------------------------------------
comptime K8S_ERR_FORBIDDEN: Int = 0  # 403 — RBAC misconfig, fail loud
comptime K8S_ERR_INVALID: Int = 1  # 422 / 400 — bad manifest
comptime K8S_ERR_UNAUTHORIZED: Int = 2  # 401 — token rotated / bad
comptime K8S_ERR_TRANSPORT: Int = 3  # 5xx / TLS / IO — retryable
comptime K8S_ERR_PROTOCOL: Int = 4  # malformed response / unexpected status


struct K8sError(Copyable, Movable):
    """A classified apiserver / transport error. The client raises a Mojo
    `Error` whose message is `to_message()`; the `kind` tag lets callers
    decide retry vs fail-loud. Built from the apiserver `Status` envelope
    (reason + code + message) for HTTP errors, or from the transport layer."""

    var kind: Int
    var http_code: Int  # 0 if no HTTP response (transport error)
    var reason: String  # apiserver Status.reason (e.g. "Forbidden")
    var detail: String  # apiserver Status.message or transport detail

    def __init__(
        out self, kind: Int, http_code: Int, reason: String, detail: String
    ):
        self.kind = kind
        self.http_code = http_code
        self.reason = reason
        self.detail = detail

    def kind_name(self) -> StaticString:
        if self.kind == K8S_ERR_FORBIDDEN:
            return "Forbidden"
        if self.kind == K8S_ERR_INVALID:
            return "Invalid"
        if self.kind == K8S_ERR_UNAUTHORIZED:
            return "Unauthorized"
        if self.kind == K8S_ERR_TRANSPORT:
            return "Transport"
        return "Protocol"

    def to_message(self) -> String:
        var m = String("K8sError(") + self.kind_name() + ", http="
        m += String(self.http_code)
        if self.reason.byte_length() > 0:
            m += ", reason=" + self.reason
        if self.detail.byte_length() > 0:
            m += ", detail=" + self.detail
        m += ")"
        return m^

    def as_error(self) -> Error:
        return Error(self.to_message())
