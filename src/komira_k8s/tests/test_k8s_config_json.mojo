# =============================================================================
# test_k8s_config_json.mojo — config loader + manifest serialize + PodPhase
# derivation + Status-envelope unit tests.
# =============================================================================
#
# The offline parse gate. No cluster, no TLS. Runs the production loader /
# serializer / derivation over captured apiserver response fixtures (declared
# as test data). This pins the exact field-extraction logic a reconciler
# depends on.
# =============================================================================

from komira_k8s.k8s_config import (
    InClusterConfig,
    load_in_cluster_config_from,
)
from komira_k8s.k8s_json import (
    build_pod_manifest,
    derive_pod_phase,
    parse_pod_deletion_ack,
    parse_pod_list,
    parse_pod_liveness,
    pod_kind,
    pod_name,
    pod_uid,
    pod_deletion_grace_seconds,
    pod_deletion_timestamp,
    status_phase_str,
    status_reason,
    parse_json,
)
from komira_k8s.k8s_types import (
    PodCreateSpec,
    PodDeletionAck,
    PodLiveness,
    EnvVar,
    KeyValue,
    POD_PENDING,
    POD_RUNNING,
    POD_SUCCEEDED,
    POD_FAILED,
    POD_NOTFOUND,
)
from komira_k8s.k8s_client import (
    liveness_outcome_for_status,
    LIVENESS_PRESENT,
    LIVENESS_ABSENT,
    LIVENESS_ERROR,
    pods_collection_path,
    pod_resource_path,
    pod_log_subpath,
)
from komira_k8s.k8s_config import K8sTokenSource
from komira_http_client.auth import BearerTokenProvider, StaticTokenSource
from komira_http_client.header_map import HeaderMap


# The fixtures are declared as test data, and the test runs from the directory
# that holds them at their repository paths.
comptime _FIXTURES_DIR = "src/komira_k8s/tests/fixtures"


def _fixtures_dir() -> String:
    """The directory holding the k8s fixtures, relative to the test's working
    directory."""
    return String(_FIXTURES_DIR)


def _expect_str(
    label: String, got: String, want: String, mut fails: Int
) raises:
    if got == want:
        print("  PASS:", label, "=", got)
    else:
        print("  FAIL:", label, "got='" + got + "' want='" + want + "'")
        fails += 1


def _expect_int(label: String, got: Int, want: Int, mut fails: Int):
    if got == want:
        print("  PASS:", label, "=", got)
    else:
        print("  FAIL:", label, "got=", got, "want=", want)
        fails += 1


# =============================================================================
# Test 1 — in-cluster config loader (token + CA + namespace + base URL).
# =============================================================================
def test_config_loader(mut fails: Int) raises:
    print("\n-- test 1: in-cluster config loader --")
    var fx = _fixtures_dir()
    var cfg = load_in_cluster_config_from(
        fx,
        String("token"),
        String("ca.crt"),
        String("namespace"),
        String("10.96.0.1"),
        String("443"),
    )
    # The SA token is a JWT (starts with "eyJ").
    var tb = cfg.token.as_bytes()
    var tok_prefix = String("")
    for i in range(3):
        if i < len(tb):
            tok_prefix += chr(Int(tb[i]))
    _expect_str(String("token JWT prefix"), tok_prefix, String("eyJ"), fails)
    # The token must NOT have a trailing newline (strip_trailing_ws).
    if len(tb) > 0 and tb[len(tb) - 1] == UInt8(0x0A):
        print("  FAIL: token has a trailing newline (strip failed)")
        fails += 1
    else:
        print("  PASS: token has no trailing newline")
    # CA is a PEM.
    var ca_ok = (
        len(cfg.ca_pem.as_bytes()) > 0
        and cfg.ca_pem.as_bytes()[0] == UInt8(ord("-"))
    )
    if ca_ok:
        print("  PASS: CA is PEM ('-' prefix), bytes:", len(cfg.ca_pem.as_bytes()))
    else:
        print("  FAIL: CA is not a PEM")
        fails += 1
    _expect_str(String("namespace"), cfg.namespace, String("default"), fails)
    _expect_str(
        String("apiserver base url"),
        cfg.apiserver_base_url(),
        String("https://10.96.0.1:443"),
        fails,
    )
    _expect_int(
        String("apiserver port u16"),
        Int(cfg.apiserver_port_u16()),
        443,
        fails,
    )
    # Token refresh: read_token() re-reads the file and matches the cached one.
    var refreshed = cfg.read_token()
    if refreshed == cfg.token:
        print("  PASS: read_token() re-read matches bootstrap token")
    else:
        print("  FAIL: read_token() differs from bootstrap")
        fails += 1


# =============================================================================
# Test 2 — path builders.
# =============================================================================
def test_paths(mut fails: Int) raises:
    print("\n-- test 2: apiserver path builders --")
    _expect_str(
        String("collection path"),
        pods_collection_path(String("default")),
        String("/api/v1/namespaces/default/pods"),
        fails,
    )
    _expect_str(
        String("resource path"),
        pod_resource_path(String("example-jobs"), String("job-abc")),
        String("/api/v1/namespaces/example-jobs/pods/job-abc"),
        fails,
    )


# =============================================================================
# Test 3 — manifest serializer (PodCreateSpec -> JSON, re-parse, assert).
# =============================================================================
def test_manifest_serialize(mut fails: Int) raises:
    print("\n-- test 3: manifest serializer --")
    var spec = PodCreateSpec(
        String("job-runner-1"), String("example-jobs"), String("busybox:1.36")
    )
    spec.args.append(String("--job-id"))
    spec.args.append(String("abc-123"))
    spec.env.append(EnvVar(String("RUST_LOG"), String("info")))
    spec.cpu = String("256m")
    spec.memory = String("512Mi")
    spec.labels.append(KeyValue(String("app"), String("example-job")))
    spec.labels.append(
        KeyValue(String("example.dev/job-id"), String("abc-123"))
    )
    spec.labels.append(
        KeyValue(String("example.dev/managed-by"), String("example-job-manager"))
    )
    var manifest = build_pod_manifest(spec)
    print("  manifest:", manifest)
    # Round-trip through the parser to prove well-formedness + fields.
    var jv = parse_json(manifest)
    _expect_str(String("kind"), pod_kind(jv), String("Pod"), fails)
    _expect_str(String("name"), pod_name(jv), String("job-runner-1"), fails)

    # spec.restartPolicy = Never
    var sp = jv.get(String("spec"))
    var rp = sp.get(String("restartPolicy"))
    _expect_str(String("restartPolicy"), rp.as_string(), String("Never"), fails)

    # containers[0]: image, imagePullPolicy, args, env, resources
    var containers = sp.get(String("containers"))
    var c0 = containers.children[0].copy()
    _expect_str(
        String("image"),
        c0.get(String("image")).as_string(),
        String("busybox:1.36"),
        fails,
    )
    _expect_str(
        String("imagePullPolicy"),
        c0.get(String("imagePullPolicy")).as_string(),
        String("IfNotPresent"),
        fails,
    )
    var args = c0.get(String("args"))
    _expect_int(String("args count"), len(args.children), 2, fails)
    _expect_str(
        String("args[1]"),
        args.children[1].copy().as_string(),
        String("abc-123"),
        fails,
    )
    var env = c0.get(String("env"))
    _expect_int(String("env count"), len(env.children), 1, fails)
    var env0 = env.children[0].copy()
    _expect_str(
        String("env[0].name"),
        env0.get(String("name")).as_string(),
        String("RUST_LOG"),
        fails,
    )
    var res = c0.get(String("resources"))
    var reqs = res.get(String("requests"))
    _expect_str(
        String("resources.requests.cpu"),
        reqs.get(String("cpu")).as_string(),
        String("256m"),
        fails,
    )
    _expect_str(
        String("resources.requests.memory"),
        reqs.get(String("memory")).as_string(),
        String("512Mi"),
        fails,
    )
    # labels
    var meta = jv.get(String("metadata"))
    var labels = meta.get(String("labels"))
    _expect_str(
        String("labels.app"),
        labels.get(String("app")).as_string(),
        String("example-job"),
        fails,
    )


# =============================================================================
# Test 4 — response parse + PodPhase derivation over captured fixtures.
# =============================================================================
def _read_fixture(fx: String, name: String) raises -> String:
    with open(fx + "/" + name, "r") as f:
        return f.read()


def test_response_parse(mut fails: Int) raises:
    print("\n-- test 4: apiserver response parse + PodPhase derivation --")
    var fx = _fixtures_dir()

    # CREATE response (201): kind=Pod, name=probe-created, phase=Pending.
    var create_jv = parse_json(_read_fixture(fx, String("create_pod_resp.json")))
    _expect_str(String("CREATE kind"), pod_kind(create_jv), String("Pod"), fails)
    _expect_str(
        String("CREATE name"), pod_name(create_jv), String("probe-created"), fails
    )
    var create_phase = derive_pod_phase(create_jv)
    _expect_int(
        String("CREATE derived phase = Pending"),
        create_phase.tag,
        POD_PENDING,
        fails,
    )

    # GET response (200): kind=Pod, 36-char uid, containerStatuses waiting =>
    # Pending (the fixture's pod is ContainerCreating).
    var get_jv = parse_json(_read_fixture(fx, String("get_pod_resp.json")))
    _expect_str(String("GET kind"), pod_kind(get_jv), String("Pod"), fails)
    _expect_str(
        String("GET name"), pod_name(get_jv), String("probe-created"), fails
    )
    var uid = pod_uid(get_jv)
    _expect_int(String("GET uid is 36-char UUID"), len(uid.as_bytes()), 36, fails)
    var get_phase = derive_pod_phase(get_jv)
    # containerStatuses[0].state.waiting => Pending (preferred over status.phase)
    _expect_int(
        String("GET derived phase = Pending (waiting)"),
        get_phase.tag,
        POD_PENDING,
        fails,
    )
    print("    GET phase raw:", get_phase.raw)

    # DELETE response (200): a deletionTimestamp is now set.
    var del_jv = parse_json(_read_fixture(fx, String("delete_pod_resp.json")))
    _expect_str(String("DELETE kind"), pod_kind(del_jv), String("Pod"), fails)
    var dts = pod_deletion_timestamp(del_jv)
    if len(dts.as_bytes()) > 0:
        print("  PASS: DELETE carries deletionTimestamp:", dts)
    else:
        print("  FAIL: DELETE missing deletionTimestamp")
        fails += 1


# =============================================================================
# Test 4b — THE DELETION-EVIDENCE PAIR: `PodDeletionAck` + `PodLiveness` over
# the SAME captured apiserver bodies.
# =============================================================================
#
# ⭐ THE POINT OF THIS TEST, IN ONE LINE: `derive_pod_phase` reads `status.*`
#   and NEVER `metadata`, so through `get_pod_status` alone a pod that is
#   TERMINATING (deletion accepted, grace period running, containers possibly
#   still up on an unreachable node) is INDISTINGUISHABLE from a healthy one.
#   The two structs below are how that evidence leaves the wire layer.
#
# The DELETE fixture is a capture from a live kind apiserver (identifiers,
# timestamps and node name neutralised), so the claim "a pod DELETE returns 200
# with the Pod object, carrying its deletionTimestamp and its 30-second
# deadline" is grounded in a real response rather than in the API docs.
def test_deletion_evidence(mut fails: Int) raises:
    print("\n-- test 4b: PodDeletionAck / PodLiveness --")
    var fx = _fixtures_dir()
    var del_jv = parse_json(_read_fixture(fx, String("delete_pod_resp.json")))

    # ---- the grace period is READ, not assumed ----
    _expect_int(
        String("DELETE deletionGracePeriodSeconds"),
        pod_deletion_grace_seconds(del_jv),
        30,
        fails,
    )
    # ⛔ ABSENT IS -1, NOT 0. Zero is a REAL value on this wire and it means
    #   FORCE DELETE — the apiserver drops the object WITHOUT waiting for the
    #   kubelet to confirm the containers stopped. Reporting an absent field as
    #   0 renders an ordinary 30s grace as a force-delete in the one string an
    #   operator reads to decide whether a stuck pod needs a human.
    _expect_int(
        String("absent grace => -1 (NOT 0, which means force-delete)"),
        pod_deletion_grace_seconds(
            parse_json(String('{"kind":"Pod","metadata":{"name":"p"}}'))
        ),
        -1,
        fails,
    )

    # ---- the ACK: what the apiserver said when we asked it to delete ----
    var ack = parse_pod_deletion_ack(del_jv)
    if ack.accepted and ack.is_marked() and ack.grace_period_seconds == 30:
        print("  PASS: ack accepted + marked + grace 30s")
    else:
        print("  FAIL: ack did not carry the accepted deletion")
        fails += 1
    if ack.deadline_phrase().find(String("grace 30s")) >= 0:
        print(
            "  PASS: deadline_phrase names the deadline:", ack.deadline_phrase()
        )
    else:
        print("  FAIL: deadline_phrase does not name the deadline")
        fails += 1
    # The 404 swallow is an observation of its own — NOT an accepted delete.
    var gone_ack = PodDeletionAck.already_absent()
    if (
        gone_ack.already_gone
        and not gone_ack.accepted
        and not gone_ack.is_marked()
    ):
        print("  PASS: the 404 swallow is 'nothing to delete', not 'I deleted it'")
    else:
        print("  FAIL: the 404 swallow conflates two observations")
        fails += 1

    # ---- LIVENESS over the same body: present + terminating ----
    var live = parse_pod_liveness(del_jv)
    if live.present and live.is_terminating():
        print("  PASS: liveness sees present + TERMINATING")
    else:
        print("  FAIL: liveness did not see the deletion mark")
        fails += 1
    # ⭐ THE GAP, ASSERTED DIRECTLY: the phase derivation is blind to it.
    var blind = derive_pod_phase(del_jv)
    _expect_int(
        String("derive_pod_phase is BLIND to the deletion (still Pending)"),
        blind.tag,
        POD_PENDING,
        fails,
    )
    _expect_int(
        String("...and liveness carries that SAME phase verbatim"),
        live.phase.tag,
        blind.tag,
        fails,
    )

    # ---- the OBSERVED ABSENCE has exactly one constructor ----
    var absent = PodLiveness.absent()
    if (not absent.present) and (not absent.is_terminating()):
        print("  PASS: PodLiveness.absent() is not present and not terminating")
    else:
        print("  FAIL: PodLiveness.absent() is malformed")
        fails += 1


# =============================================================================
# Test 4c — WHICH HTTP STATUSES CONSTITUTE AN OBSERVED ABSENCE.
# =============================================================================
#
# ⛔⛔ EXACTLY ONE STATUS MEANS ABSENT, AND IT IS 404. Everything else that is
#   not a 200 is an ERROR the verb RAISES on. "I could not ask" and "it is not
#   there" are different facts, and reporting the first as the second is the
#   unobserved absence a verified revert must refuse: it would let a job be
#   re-placed while its prior pod is still running, giving ONE job TWO live
#   supervisors.
#
# This is a pure Int -> Int function precisely so this table can exist. Inside
# the verb it would be three lines of an `if` ladder that only a live cluster
# could exercise.
def test_liveness_outcome_table(mut fails: Int) raises:
    print("\n-- test 4c: liveness outcome per HTTP status --")
    _expect_int(
        String("200 => PRESENT"),
        liveness_outcome_for_status(200),
        LIVENESS_PRESENT,
        fails,
    )
    _expect_int(
        String("404 => ABSENT (the ONLY observed absence)"),
        liveness_outcome_for_status(404),
        LIVENESS_ABSENT,
        fails,
    )
    # Every one of these has been mistaken for "gone" in some client somewhere.
    var errs = List[Int]()
    errs.append(0)  # transport / TLS fault, no HTTP response at all
    errs.append(202)
    errs.append(301)
    errs.append(400)
    errs.append(401)  # token rotated
    errs.append(403)  # RBAC misconfigured
    errs.append(409)
    errs.append(410)  # "Gone" — the NAME says absent; the semantics do not
    errs.append(422)
    errs.append(429)  # throttled
    errs.append(500)
    errs.append(502)
    errs.append(503)
    errs.append(504)
    for i in range(len(errs)):
        _expect_int(
            String("HTTP ") + String(errs[i]) + " => ERROR, never ABSENT",
            liveness_outcome_for_status(errs[i]),
            LIVENESS_ERROR,
            fails,
        )


# =============================================================================
# Test 5 — synthetic PodPhase derivation (terminated success / failure / phase
# fallback) — the paths the fixtures don't cover.
# =============================================================================
def test_phase_derivation_synthetic(mut fails: Int) raises:
    print("\n-- test 5: synthetic PodPhase derivation --")

    # terminated exitCode 0 => Succeeded.
    var succ = parse_json(
        String(
            '{"kind":"Pod","status":{"phase":"Running","containerStatuses":'
            '[{"state":{"terminated":{"exitCode":0,"reason":"Completed"}}}]}}'
        )
    )
    _expect_int(
        String("terminated:0 => Succeeded"),
        derive_pod_phase(succ).tag,
        POD_SUCCEEDED,
        fails,
    )

    # terminated exitCode 137 => Failed with exit_code carried.
    var fail = parse_json(
        String(
            '{"kind":"Pod","status":{"phase":"Running","containerStatuses":'
            '[{"state":{"terminated":{"exitCode":137,"reason":"OOMKilled",'
            '"message":"killed"}}}]}}'
        )
    )
    var fph = derive_pod_phase(fail)
    _expect_int(String("terminated:137 => Failed"), fph.tag, POD_FAILED, fails)
    if fph.exit_code and fph.exit_code.value() == 137:
        print("  PASS: Failed exit_code = 137")
    else:
        print("  FAIL: Failed exit_code not 137")
        fails += 1

    # running container => Running.
    var run = parse_json(
        String(
            '{"kind":"Pod","status":{"phase":"Running","containerStatuses":'
            '[{"state":{"running":{"startedAt":"2026-10-01T00:00:00Z"}}}]}}'
        )
    )
    _expect_int(
        String("running => Running"), derive_pod_phase(run).tag, POD_RUNNING, fails
    )

    # no containerStatuses => fall back to status.phase = Succeeded.
    var phase_only = parse_json(
        String('{"kind":"Pod","status":{"phase":"Succeeded"}}')
    )
    _expect_int(
        String("phase fallback => Succeeded"),
        derive_pod_phase(phase_only).tag,
        POD_SUCCEEDED,
        fails,
    )


# =============================================================================
# Test 6 — Status envelope (403 Forbidden) parse.
# =============================================================================
def test_status_envelope(mut fails: Int) raises:
    print("\n-- test 6: Status envelope parse --")
    var fx = _fixtures_dir()
    var list_jv = parse_json(_read_fixture(fx, String("list_pods.json")))
    var k = pod_kind(list_jv)
    print("    LIST/Status kind:", k)
    # The captured list fixture is the pre-RBAC 403 Status (default SA).
    if k == String("Status"):
        _expect_str(
            String("403 Status reason"),
            status_reason(list_jv),
            String("Forbidden"),
            fails,
        )
        print("    (proves the bearer token AUTHENTICATED — error is authZ)")
    else:
        # If the fixture is a real PodList, just confirm it parses.
        print("    (LIST fixture is a PodList kind:", k, ")")

    # Also test a synthetic Status envelope.
    var status = parse_json(
        String(
            '{"kind":"Status","status":"Failure","reason":"NotFound",'
            '"code":404,"message":"pods \\"x\\" not found"}'
        )
    )
    _expect_str(
        String("synthetic Status reason"),
        status_reason(status),
        String("NotFound"),
        fails,
    )


def _expect_true(label: String, got: Bool, mut fails: Int):
    if got:
        print("  PASS:", label)
    else:
        print("  FAIL:", label, "(expected True)")
        fails += 1


# =============================================================================
# test 7 — parse_pod_list over a synthetic PodList (the list verb).
# =============================================================================
def test_parse_pod_list(mut fails: Int) raises:
    print("\n-- test 7: parse_pod_list (synthetic PodList) --")
    var body = String(
        '{"kind":"PodList","items":['
        '{"metadata":{"name":"alpha","namespace":"example"},'
        '"status":{"phase":"Running","containerStatuses":[{"state":'
        '{"running":{}}}]}},'
        '{"metadata":{"name":"beta","namespace":"example"},'
        '"status":{"phase":"Succeeded","containerStatuses":[{"state":'
        '{"terminated":{"exitCode":0}}}]}},'
        '{"metadata":{"name":"gamma","namespace":"example"},'
        '"status":{"phase":"Pending","containerStatuses":[{"state":'
        '{"waiting":{"reason":"ContainerCreating"}}}]}}'
        "]}"
    )
    var summaries = parse_pod_list(parse_json(body))
    _expect_int(String("pod count"), len(summaries), 3, fails)
    if len(summaries) == 3:
        _expect_str(String("pod[0].name"), summaries[0].name, String("alpha"), fails)
        _expect_str(
            String("pod[0].namespace"), summaries[0].namespace,
            String("example"), fails,
        )
        _expect_int(
            String("pod[0].phase==Running"),
            summaries[0].phase.tag, POD_RUNNING, fails,
        )
        _expect_int(
            String("pod[1].phase==Succeeded"),
            summaries[1].phase.tag, POD_SUCCEEDED, fails,
        )
        _expect_int(
            String("pod[2].phase==Pending"),
            summaries[2].phase.tag, POD_PENDING, fails,
        )

    # Empty / missing items => empty list, not a crash.
    var empty = parse_pod_list(parse_json(String('{"kind":"PodList"}')))
    _expect_int(String("missing-items => empty"), len(empty), 0, fails)


# =============================================================================
# test 8 — log subresource path (the logs verb).
# =============================================================================
def test_log_path(mut fails: Int) raises:
    print("\n-- test 8: pod_log_subpath --")
    _expect_str(
        String("log subpath"),
        pod_log_subpath(String("example"), String("worker-0")),
        String("/api/v1/namespaces/example/pods/worker-0/log"),
        fails,
    )


# =============================================================================
# test 9 — pluggable auth seam: bearer header injected via AuthProvider, token
# re-read per call (rotation). Request FRAMING is owned by komira_http's
# HttpClient; the seam this module owns is the `AuthProvider` -> `HeaderMap`
# decoration + the K8sTokenSource rotation. We assert on the HeaderMap the
# provider produces, not on hand-rolled wire bytes.
# =============================================================================
def test_auth_seam(mut fails: Int) raises:
    print("\n-- test 9: pluggable AuthProvider seam --")

    # The static provider decorates a HeaderMap with the bearer header.
    var prov = BearerTokenProvider(StaticTokenSource(String("tok-abc")))
    var headers = HeaderMap()
    prov.apply(headers)
    var auth_val = headers.get(String("Authorization"))
    _expect_true(
        String("Authorization header present (static provider)"),
        auth_val.__bool__(),
        fails,
    )
    if auth_val.__bool__():
        _expect_str(
            String("Authorization: Bearer tok-abc"),
            auth_val.value(), String("Bearer tok-abc"), fails,
        )

    # K8sTokenSource with no sa_dir returns the bootstrap token (off-cluster).
    var src = K8sTokenSource(String(""), String("token"), String("boot-tok"))
    _expect_str(
        String("K8sTokenSource bootstrap fallback"),
        src.fetch_token(), String("boot-tok"), fails,
    )
    # Driven through a provider, it injects the bootstrap token.
    var prov2 = BearerTokenProvider(src^)
    var headers2 = HeaderMap()
    prov2.apply(headers2)
    var auth_val2 = headers2.get(String("Authorization"))
    _expect_true(
        String("K8sTokenSource via provider => bearer header"),
        auth_val2.__bool__()
        and auth_val2.value() == String("Bearer boot-tok"),
        fails,
    )


# =============================================================================
# test 10 — out-of-cluster config (from_explicit): URL parse + static token.
# The off-cluster path (dev host / kind) — server URL + CA PEM + SA token are
# supplied EXPLICITLY (no pod FS, no kubeconfig YAML). Reuses the in-cluster
# surface (apiserver_host / apiserver_port_u16 / ca_pem / token_source /
# read_token) so K8sPodClient needs zero change.
# =============================================================================
def test_out_of_cluster_config(mut fails: Int) raises:
    print("\n-- test 10: out-of-cluster config (from_explicit) --")

    var fake_ca = String(
        "-----BEGIN CERTIFICATE-----\nMIIBfakefakefake\n"
        "-----END CERTIFICATE-----\n"
    )
    var fake_tok = String("eyJhbGciOiJSUzI1NiJ9.fake.token")

    # explicit https://host:port — host+port parsed, CA+token stored.
    var cfg = InClusterConfig.from_explicit(
        String("https://127.0.0.1:6443"), fake_ca, fake_tok
    )
    _expect_str(String("OOC host"), cfg.apiserver_host, String("127.0.0.1"), fails)
    _expect_int(
        String("OOC port u16"), Int(cfg.apiserver_port_u16()), 6443, fails
    )
    _expect_str(
        String("OOC base url"),
        cfg.apiserver_base_url(),
        String("https://127.0.0.1:6443"),
        fails,
    )
    # CA PEM round-trips verbatim.
    _expect_str(String("OOC ca_pem round-trip"), cfg.ca_pem, fake_ca, fails)
    # Static token: read_token() returns the in-memory token (no file re-read
    # because sa_dir is empty), and token_source().fetch_token() agrees.
    _expect_str(String("OOC read_token"), cfg.read_token(), fake_tok, fails)
    _expect_str(
        String("OOC token_source fetch"),
        cfg.token_source().fetch_token(),
        fake_tok,
        fails,
    )

    # Default port: scheme with no :port => 443.
    var cfg_default = InClusterConfig.from_explicit(
        String("https://kubernetes.default.svc"), fake_ca, fake_tok
    )
    _expect_str(
        String("OOC default-port host"),
        cfg_default.apiserver_host,
        String("kubernetes.default.svc"),
        fails,
    )
    _expect_int(
        String("OOC default-port == 443"),
        Int(cfg_default.apiserver_port_u16()),
        443,
        fails,
    )

    # Trailing slash on the base URL is tolerated (stripped).
    var cfg_slash = InClusterConfig.from_explicit(
        String("https://10.0.0.5:443/"), fake_ca, fake_tok
    )
    _expect_str(
        String("OOC trailing-slash host"),
        cfg_slash.apiserver_host,
        String("10.0.0.5"),
        fails,
    )
    _expect_int(
        String("OOC trailing-slash port"),
        Int(cfg_slash.apiserver_port_u16()),
        443,
        fails,
    )

    # A bare http:// scheme is rejected (apiserver is always TLS).
    var raised_http = False
    try:
        var _bad = InClusterConfig.from_explicit(
            String("http://127.0.0.1:6443"), fake_ca, fake_tok
        )
    except:
        raised_http = True
    _expect_true(String("OOC rejects http:// scheme"), raised_http, fails)

    # A missing-scheme URL is rejected.
    var raised_noscheme = False
    try:
        var _bad2 = InClusterConfig.from_explicit(
            String("127.0.0.1:6443"), fake_ca, fake_tok
        )
    except:
        raised_noscheme = True
    _expect_true(String("OOC rejects missing scheme"), raised_noscheme, fails)


def main() raises:
    print("== komira_k8s config + JSON unit tests ==")
    var fails = 0
    test_config_loader(fails)
    test_paths(fails)
    test_manifest_serialize(fails)
    test_response_parse(fails)
    test_deletion_evidence(fails)
    test_liveness_outcome_table(fails)
    test_phase_derivation_synthetic(fails)
    test_status_envelope(fails)
    test_parse_pod_list(fails)
    test_log_path(fails)
    test_auth_seam(fails)
    test_out_of_cluster_config(fails)
    print("\n== RESULT:", "ALL PASS" if fails == 0 else (String(fails) + " FAILURE(S)"), "==")
    if fails != 0:
        raise Error("komira_k8s unit tests: " + String(fails) + " failure(s)")
