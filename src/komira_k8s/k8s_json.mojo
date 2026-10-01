# =============================================================================
# komira_k8s/k8s_json.mojo — manifest serialize (write) + PodPhase derivation
# and Status-envelope parse (read), via komira_serde
# =============================================================================
#
# JSON lives ENTIRELY inside this module — it is the wire seam, never the
# public API. The
# write path BUILDS a manifest string from a typed `PodCreateSpec`; the read
# path PARSES the apiserver JSON into targeted accessors that return only the
# fields `PodPhase` derivation needs (we do NOT deserialize a full Pod struct).
#
# PodPhase derivation: prefer `status.containerStatuses[0].state.{terminated,
# running,waiting}` — terminated exitCode 0 => Succeeded, !=0 => Failed; running
# => Running; waiting => Pending — else fall back to `status.phase`.
# =============================================================================

from komira_serde import JsonValue, parse_json_value
from komira_serde.json_value import (
    JSON_STRING,
    JSON_NUMBER,
    JSON_ARRAY,
    JSON_OBJECT,
)

from komira_k8s.k8s_types import (
    PodCreateSpec,
    PodDeletionAck,
    PodLiveness,
    PodPhase,
    PodSummary,
    POD_PENDING,
    POD_RUNNING,
    POD_SUCCEEDED,
    POD_FAILED,
    POD_UNKNOWN,
)
from komira_k8s.k8s_text import json_escape


# =============================================================================
# WRITE PATH — PodCreateSpec -> manifest JSON string.
# =============================================================================
def build_pod_manifest(spec: PodCreateSpec) -> String:
    """Serialize a typed `PodCreateSpec` into a Pod manifest JSON body for
    POST, with labels, args, env, and resources. The constants
    `restartPolicy=Never` and `imagePullPolicy=IfNotPresent` are baked in."""
    var m = String('{"apiVersion":"v1","kind":"Pod",')

    # ── metadata: name + labels ──
    m += '"metadata":{"name":"' + json_escape(spec.name) + '"'
    if len(spec.labels) > 0:
        m += ',"labels":{'
        for i in range(len(spec.labels)):
            if i > 0:
                m += ","
            m += (
                '"'
                + json_escape(spec.labels[i].key)
                + '":"'
                + json_escape(spec.labels[i].value)
                + '"'
            )
        m += "}"
    m += "}"

    # ── spec: container + restartPolicy ──
    m += ',"spec":{"restartPolicy":"Never","containers":[{'
    m += '"name":"' + json_escape(spec.name) + '"'
    m += ',"image":"' + json_escape(spec.image) + '"'
    m += ',"imagePullPolicy":"IfNotPresent"'

    # args
    if len(spec.args) > 0:
        m += ',"args":['
        for i in range(len(spec.args)):
            if i > 0:
                m += ","
            m += '"' + json_escape(spec.args[i]) + '"'
        m += "]"

    # env
    if len(spec.env) > 0:
        m += ',"env":['
        for i in range(len(spec.env)):
            if i > 0:
                m += ","
            m += (
                '{"name":"'
                + json_escape(spec.env[i].name)
                + '","value":"'
                + json_escape(spec.env[i].value)
                + '"}'
            )
        m += "]"

    # resources (requests + limits) — only emit the keys that are set
    var has_cpu = spec.cpu.byte_length() > 0
    var has_mem = spec.memory.byte_length() > 0
    if has_cpu or has_mem:
        var quant = String("{")
        var first = True
        if has_cpu:
            quant += '"cpu":"' + json_escape(spec.cpu) + '"'
            first = False
        if has_mem:
            if not first:
                quant += ","
            quant += '"memory":"' + json_escape(spec.memory) + '"'
        quant += "}"
        m += ',"resources":{"requests":' + quant + ',"limits":' + quant + "}"

    m += "}]}}"
    return m^


# =============================================================================
# READ PATH — targeted accessors over the parsed apiserver JSON.
# =============================================================================
def _obj_str(v: JsonValue, key: String) raises -> String:
    """Return the string value at `v[key]`, or "" if absent / not a string."""
    if not v.has(key):
        return String("")
    var child = v.get(key)
    if child.kind == JSON_STRING:
        return child.as_string()
    return String("")


def pod_kind(v: JsonValue) raises -> String:
    return _obj_str(v, String("kind"))


def pod_name(v: JsonValue) raises -> String:
    if not v.has(String("metadata")):
        return String("")
    return _obj_str(v.get(String("metadata")), String("name"))


def pod_uid(v: JsonValue) raises -> String:
    if not v.has(String("metadata")):
        return String("")
    return _obj_str(v.get(String("metadata")), String("uid"))


def pod_deletion_timestamp(v: JsonValue) raises -> String:
    """`metadata.deletionTimestamp` — "" when the pod is not being deleted.

    ⭐ THIS IS THE ONLY FIELD ON A POD THAT SAYS "SOMEBODY ASKED FOR THIS TO GO
    AWAY", AND `derive_pod_phase` STRUCTURALLY CANNOT SEE IT — that function
    reads `status.*` only. A terminating pod whose container is still up derives
    `Running`, identical to a pod nobody touched. See `PodLiveness`."""
    if not v.has(String("metadata")):
        return String("")
    return _obj_str(v.get(String("metadata")), String("deletionTimestamp"))


def pod_deletion_grace_seconds(v: JsonValue) raises -> Int:
    """`metadata.deletionGracePeriodSeconds`, or **-1 when absent**.

    ⛔ -1 AND NOT 0. Zero is a REAL value on this wire and it means FORCE
    DELETE — the apiserver drops the object WITHOUT waiting for the kubelet to
    confirm the containers stopped. Reporting an absent field as 0 would render
    an ordinary 30-second grace as a force-delete in the one string an operator
    reads to decide whether a stuck pod needs a human."""
    if not v.has(String("metadata")):
        return -1
    var md = v.get(String("metadata"))
    if not md.has(String("deletionGracePeriodSeconds")):
        return -1
    var g = md.get(String("deletionGracePeriodSeconds"))
    if g.kind == JSON_NUMBER:
        return Int(g.as_int64())
    return -1


def parse_pod_liveness(v: JsonValue) raises -> PodLiveness:
    """Assemble a `PodLiveness` from a PRESENT pod object (a GET that returned
    200): the two `metadata` deletion fields plus the SAME `derive_pod_phase`
    the reconciler's `get_pod_status` uses.

    ⛔ `present` IS HARD-WIRED `True` HERE, and that is deliberate: this
    function is only reachable when the apiserver handed back an object. The
    absent case has exactly one constructor (`PodLiveness.absent()`) reached
    from exactly one wire outcome (HTTP 404), so no parse failure, empty body or
    unexpected shape can ever be mistaken for an observed absence."""
    return PodLiveness(
        True,
        pod_deletion_timestamp(v),
        pod_deletion_grace_seconds(v),
        derive_pod_phase(v),
    )


def parse_pod_deletion_ack(v: JsonValue) raises -> PodDeletionAck:
    """Assemble a `PodDeletionAck` from an ACCEPTED delete's response body.

    ⭐ THE APISERVER HANDS THIS BACK FOR FREE. A pod DELETE returns **200 with the Pod object** — carrying the
    `deletionTimestamp` it just wrote and the grace period it just started —
    not a 202 and not an empty body. That is observed, not assumed: a capture
    from a live kind apiserver is this package's DELETE test fixture.

    A 202 (or any accepted response whose body is not a Pod) parses to an ack
    with no mark, which is honest: we know the deletion was accepted and we do
    NOT know its deadline."""
    return PodDeletionAck(
        True,
        False,
        pod_deletion_timestamp(v),
        pod_deletion_grace_seconds(v),
    )


def status_phase_str(v: JsonValue) raises -> String:
    """`status.phase` — the apiserver-level pod phase fallback."""
    if not v.has(String("status")):
        return String("")
    return _obj_str(v.get(String("status")), String("phase"))


# -----------------------------------------------------------------------------
# Status envelope (errors) — `{kind:"Status", reason, code, message}`.
# -----------------------------------------------------------------------------
def status_reason(v: JsonValue) raises -> String:
    return _obj_str(v, String("reason"))


def status_message(v: JsonValue) raises -> String:
    return _obj_str(v, String("message"))


def status_code(v: JsonValue) raises -> Int:
    if not v.has(String("code")):
        return 0
    var c = v.get(String("code"))
    if c.kind == JSON_NUMBER:
        return Int(c.as_int64())
    return 0


# -----------------------------------------------------------------------------
# PodPhase derivation — the load-bearing read logic.
# -----------------------------------------------------------------------------
def derive_pod_phase(v: JsonValue) raises -> PodPhase:
    """Derive a `PodPhase` from a parsed pod JSON. Prefers
    `status.containerStatuses[0].state.{terminated,running,waiting}`; falls
    back to `status.phase`."""
    if not v.has(String("status")):
        return PodPhase.unknown(String("no-status"))
    var status = v.get(String("status"))

    # ── Prefer containerStatuses[0].state.* ──
    if status.has(String("containerStatuses")):
        var cs = status.get(String("containerStatuses"))
        if cs.kind == JSON_ARRAY and len(cs.children) > 0:
            var c0 = cs.children[0].copy()
            if c0.kind == JSON_OBJECT and c0.has(String("state")):
                var state = c0.get(String("state"))
                # terminated => Succeeded (exit 0) / Failed (exit != 0)
                if state.has(String("terminated")):
                    var term = state.get(String("terminated"))
                    var exit_code = 0
                    if term.has(String("exitCode")):
                        var ec = term.get(String("exitCode"))
                        if ec.kind == JSON_NUMBER:
                            exit_code = Int(ec.as_int64())
                    if exit_code == 0:
                        return PodPhase.succeeded(String("terminated:0"))
                    var msg = _obj_str(term, String("message"))
                    var reason = _obj_str(term, String("reason"))
                    var detail = msg if msg.byte_length() > 0 else reason
                    return PodPhase.failed(
                        exit_code, detail, String("terminated:") + String(exit_code)
                    )
                # running => Running
                if state.has(String("running")):
                    return PodPhase.running(String("containerStatuses:running"))
                # waiting => Pending
                if state.has(String("waiting")):
                    var wr = _obj_str(
                        state.get(String("waiting")), String("reason")
                    )
                    return PodPhase.pending(
                        String("waiting:") + wr
                    )

    # ── Fall back to status.phase ──
    var phase = _obj_str(status, String("phase"))
    if phase == String("Pending"):
        return PodPhase.pending(phase)
    if phase == String("Running"):
        return PodPhase.running(phase)
    if phase == String("Succeeded"):
        return PodPhase.succeeded(phase)
    if phase == String("Failed"):
        var reason = _obj_str(status, String("reason"))
        var message = _obj_str(status, String("message"))
        var detail = message if message.byte_length() > 0 else reason
        return PodPhase.failed(1, detail, phase)
    if phase.byte_length() > 0:
        return PodPhase.unknown(phase)
    return PodPhase.unknown(String("no-phase"))


# -----------------------------------------------------------------------------
# PodList parse — `{kind:"PodList", items:[ <pod>, ... ]}` -> [PodSummary].
# -----------------------------------------------------------------------------
def parse_pod_list(v: JsonValue) raises -> List[PodSummary]:
    """Parse a `PodList` JSON into a list of `PodSummary` (name + namespace +
    derived phase). Each `items[i]` is a full Pod object, so we reuse
    `pod_name` + the `metadata.namespace` + `derive_pod_phase` per item — the
    SAME phase derivation as `get_pod_status`, so a
    listed pod's phase matches a direct get."""
    var out = List[PodSummary]()
    if not v.has(String("items")):
        return out^
    var items = v.get(String("items"))
    if items.kind != JSON_ARRAY:
        return out^
    for i in range(len(items.children)):
        var item = items.children[i].copy()
        var name = pod_name(item)
        var ns = String("")
        if item.has(String("metadata")):
            ns = _obj_str(item.get(String("metadata")), String("namespace"))
        var phase = derive_pod_phase(item)
        out.append(PodSummary(name, ns, phase^))
    return out^


def parse_json(body: String) raises -> JsonValue:
    """Parse a response body to a JsonValue (komira_serde). Internal only —
    JsonValue never crosses the public boundary."""
    return parse_json_value(body)
