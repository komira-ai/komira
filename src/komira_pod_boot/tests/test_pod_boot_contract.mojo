# =============================================================================
# tests/test_pod_boot_contract.mojo — the falsifiers for the VM-boot contract.
# =============================================================================
#
# ⛔ WHAT FAILS IF THIS FILE IS WRONG, AND WHY IT IS NOT A CRASH. The contract is
# an agreement between two programs that never link and never run on the same
# machine: a placement conformer EXPORTS environment variables into a
# booting VM, and the pod loader READS them. Nothing type-checks that. A rename
# on one side produces a VM that boots, runs the customer's job, heartbeats to
# NOBODY, and — because instance-state polling still notices the machine going
# away — reports the job as finished.
#
# So the assertions here are about the SHAPE OF THE AGREEMENT, not behaviour:
#   §1 the four core names exist, are non-empty and are PAIRWISE DISTINCT (two names
#      that collapse to one string silently drop a value);
#   §2 the GCE metadata keys are likewise distinct, and are NOT equal to the env
#      names (they are a different namespace with different legal characters);
#   §3 the install path is ABSOLUTE (a boot script `exec`s it from an unknown cwd);
#   §4 the wire form ROUND-TRIPS with every container preserved — a converter
#      that keeps only the first container silently discards the rest.
#
# FARM lane: pure String in / String out. No socket, no process, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_k8s.k8s_types import EnvVar
from komira_placement.compose_renderer import (
    ComposePodSpec,
    ComposeService,
    ComposePortMapping,
)

from komira_pod_boot.pod_boot_contract import (
    ENV_POD_SPEC_JSON,
    ENV_HEARTBEAT_HOST,
    ENV_JOB_ID,
    ENV_POD_NAME,
    ENV_TASK_TIMEOUT_S,
    GCE_META_POD_SPEC,
    GCE_META_HEARTBEAT_HOST,
    GCE_META_JOB_ID,
    GCE_META_POD_NAME,
    GCE_META_TASK_TIMEOUT_S,
    ENV_HEARTBEAT_SCHEME,
    ENV_HEARTBEAT_AUTH,
    GCE_META_HEARTBEAT_SCHEME,
    GCE_META_HEARTBEAT_AUTH,
    DEFAULT_HEARTBEAT_PORT_HTTP,
    DEFAULT_HEARTBEAT_PORT_HTTPS,
    POD_LOADER_INSTALL_PATH,
    parse_task_timeout_s,
    resolve_heartbeat_target,
    render_heartbeat_host,
    serialize_pod_spec_json,
    deserialize_pod_spec_json,
)


def _all_distinct(names: List[String]) -> Bool:
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            if names[i] == names[j]:
                return False
    return True


# =============================================================================
# §1 — the four core environment variable names (pod spec, heartbeat host,
# job id, pod name).
# =============================================================================
def test_the_four_env_names_are_present_and_pairwise_distinct() raises:
    var names = List[String]()
    names.append(String(ENV_POD_SPEC_JSON))
    names.append(String(ENV_HEARTBEAT_HOST))
    names.append(String(ENV_JOB_ID))
    names.append(String(ENV_POD_NAME))
    for i in range(len(names)):
        assert_true(
            names[i].byte_length() > 0,
            (
                "an EMPTY contract name is the worst case: an empty variable"
                " name names nothing on every platform, so the boot silently"
                " carries no value at all"
            ),
        )
    assert_true(
        _all_distinct(names),
        (
            "two contract names that collapse to one string make one export"
            " overwrite the other — a value silently lost between the conformer"
            " and the loader"
        ),
    )


# =============================================================================
# §2 — GCE's metadata-key transport of the same four core values.
# =============================================================================
def test_the_gce_metadata_keys_are_distinct_and_not_the_env_names() raises:
    var keys = List[String]()
    keys.append(GCE_META_POD_SPEC)
    keys.append(GCE_META_HEARTBEAT_HOST)
    keys.append(GCE_META_JOB_ID)
    keys.append(GCE_META_POD_NAME)
    for i in range(len(keys)):
        assert_true(keys[i].byte_length() > 0, "a metadata key must be named")
    assert_true(_all_distinct(keys), "the four metadata keys are distinct")
    # A metadata key and an env name are DIFFERENT namespaces with different
    # legal characters (GCE keys are lowercase-hyphen; env names are uppercase-
    # underscore). Equality between them would mean one was pasted for the other.
    assert_false(
        GCE_META_POD_SPEC == String(ENV_POD_SPEC_JSON),
        "the GCE metadata key is not the environment variable name",
    )
    assert_false(
        GCE_META_HEARTBEAT_HOST == String(ENV_HEARTBEAT_HOST),
        "the GCE metadata key is not the environment variable name",
    )


# =============================================================================
# §3 — the install path.
# =============================================================================
def test_the_pod_loader_install_path_is_ABSOLUTE() raises:
    """A boot script `exec`s this path from a cwd nobody controls. A relative
    path resolves against whatever cloud-init happened to be in, so the VM boots,
    fails to exec, and bills until an operator notices."""
    assert_true(
        POD_LOADER_INSTALL_PATH.byte_length() > 1,
        "the install path is named",
    )
    assert_equal(
        POD_LOADER_INSTALL_PATH.as_bytes()[0],
        UInt8(ord("/")),
        "and it is ABSOLUTE — a boot script execs it from an unknown cwd",
    )


# =============================================================================
# §4 — the wire form round-trips, with EVERY container preserved.
# =============================================================================
def test_the_pod_spec_round_trips_with_every_container_preserved() raises:
    """THE CONTAINER-DROP GUARD. The whole reason the pod spec has its own wire
    form is that a multi-container placement must arrive on the VM with ALL its
    containers; a k8s-shaped converter that keeps only `containers[0]` drops the
    rest. Three
    services in, three services out, fields intact."""
    var pod = ComposePodSpec(String("pod-rt"), String("pod-rt-net"))

    var app = ComposeService(String("app"), String("registry/app:1"))
    app.command.append(String("--port"))
    app.command.append(String("8080"))
    app.environment.append(EnvVar(String("LOG"), String("info")))
    app.ports.append(ComposePortMapping(String("http"), 8080, 8080))
    pod.services.append(app^)

    var db = ComposeService(String("db"), String("registry/pg:16"))
    pod.services.append(db^)

    var side = ComposeService(String("sidecar"), String("registry/side:2"))
    side.command.append(String("--watch"))
    pod.services.append(side^)

    var json = serialize_pod_spec_json(pod)
    var back = deserialize_pod_spec_json(json^)

    assert_equal(back.name, String("pod-rt"), "the pod name survives")
    assert_equal(back.network, String("pod-rt-net"), "the network survives")
    assert_equal(
        len(back.services), 3,
        (
            "ALL THREE services survive — this is the container-drop guard,"
            " and the reason the pod spec has a wire form at all"
        ),
    )
    assert_equal(back.services[0].name, String("app"), "service 0 name")
    assert_equal(
        back.services[0].image, String("registry/app:1"),
        (
            "★ THE IMAGE SURVIVES. It is what the pod loader hands the container"
            " runtime — the one field that says what the customer's code IS"
        ),
    )
    assert_equal(len(back.services[0].command), 2, "command survives")
    assert_equal(back.services[0].command[1], String("8080"), "and its argv")
    assert_equal(
        back.services[0].environment[0].name, String("LOG"), "env name"
    )
    assert_equal(
        back.services[0].environment[0].value, String("info"), "env value"
    )
    assert_equal(back.services[0].ports[0].target, 8080, "port target")
    assert_equal(back.services[1].image, String("registry/pg:16"), "svc 1 image")
    assert_equal(back.services[2].name, String("sidecar"), "svc 2 name")


def test_a_value_carrying_JSON_METACHARACTERS_round_trips() raises:
    """Env values come from a job row, so they carry quotes, backslashes and
    newlines. An unescaped one does not corrupt a field — it breaks the DOCUMENT,
    and the VM boots with a pod spec that will not parse."""
    var pod = ComposePodSpec(String("p"), String("n"))
    var svc = ComposeService(String("s"), String("img"))
    svc.environment.append(
        EnvVar(String("Q"), String('a "quoted" \\ value') + String("\n2"))
    )
    pod.services.append(svc^)

    var json = serialize_pod_spec_json(pod)
    var back = deserialize_pod_spec_json(json^)
    assert_equal(
        back.services[0].environment[0].value,
        String('a "quoted" \\ value') + String("\n2"),
        "quote / backslash / newline all survive the round-trip",
    )


# =============================================================================
# §5 — the FIFTH name: the job's OWN declared max runtime.
#
# ⛔ WHAT FAILS IF THIS SECTION IS WRONG. On AWS this value is the ONLY run cap
# that exists (`RunInstances` has no `maxRunDuration`), so an unread or
# mis-parsed timeout is a hung job billing an EC2 instance by the hour with the
# job row saying RUNNING. The two failure directions are opposite and only one
# is loud:
#   * a non-empty value silently read as "no deadline" -> the hang is unbounded;
#   * an EMPTY value read as a deadline of 0 -> every streaming job is killed on
#     its first tick and reported as the customer's failure.
# So `None` and "refuse" are asserted SEPARATELY, and the boundary between them
# is exactly emptiness.
# =============================================================================


def test_the_timeout_name_joins_the_contract_and_stays_DISTINCT() raises:
    """`ENV_TASK_TIMEOUT_S` / `GCE_META_TASK_TIMEOUT_S` are part of the
    contract, so a conformer declaring a deadline and the loader reading it use
    one name rather than each inventing their own."""
    var names = List[String]()
    names.append(String(ENV_POD_SPEC_JSON))
    names.append(String(ENV_HEARTBEAT_HOST))
    names.append(String(ENV_JOB_ID))
    names.append(String(ENV_POD_NAME))
    names.append(String(ENV_TASK_TIMEOUT_S))
    assert_true(
        String(ENV_TASK_TIMEOUT_S).byte_length() > 0,
        "the timeout env name is non-empty",
    )
    assert_true(
        _all_distinct(names),
        "the FIVE env names are pairwise distinct — a collision drops a value",
    )
    var keys = List[String]()
    keys.append(GCE_META_POD_SPEC)
    keys.append(GCE_META_HEARTBEAT_HOST)
    keys.append(GCE_META_JOB_ID)
    keys.append(GCE_META_POD_NAME)
    keys.append(GCE_META_TASK_TIMEOUT_S)
    assert_true(
        _all_distinct(keys),
        "the FIVE GCE metadata keys are pairwise distinct",
    )
    assert_false(
        GCE_META_TASK_TIMEOUT_S == String(ENV_TASK_TIMEOUT_S),
        "the GCE transport key is not the env name (different namespaces)",
    )


def test_an_EMPTY_timeout_is_NO_DEADLINE_and_is_not_an_error() raises:
    """EMPTY => `None` => the job runs until it finishes.

    ⛔ THIS IS THE STREAMING-JOB CASE AND IT IS THE DEFAULT. If this ever became
    a refusal, every job that legitimately declared no runtime would fail to
    boot; if it ever became `Some(0)`, every one of them would be killed on the
    first tick and reported as the customer's code failing."""
    var none = parse_task_timeout_s(String(""))
    assert_false(
        Bool(none), "an EMPTY declared timeout is None — NO deadline"
    )


def test_a_POSITIVE_integer_timeout_decodes_to_that_many_seconds() raises:
    """A positive integer is that many seconds, verbatim."""
    var some = parse_task_timeout_s(String("900"))
    assert_true(Bool(some), "a positive declared timeout decodes")
    assert_equal(some.value(), 900, "900 seconds, verbatim")
    var one = parse_task_timeout_s(String("1"))
    assert_equal(one.value(), 1, "the smallest legal deadline survives")


def test_a_NON_NUMERIC_timeout_is_REFUSED_and_never_degraded_to_None() raises:
    """⛔ THE ASSERTION THAT MATTERS, AND IT IS ABOUT THE FAIL DIRECTION.

    A value that ARRIVED and could not be understood means somebody DID declare
    a deadline and this VM is about to run without one. Degrading it to `None`
    is byte-identical, at the call site, to the streaming-job case — so the two
    opposite situations would become indistinguishable and the expensive one
    would be silent.

    The 404-body case is the concrete instance: GCE answers a missing metadata
    attribute with `404` AND A BODY, so a renderer that omitted the key would
    hand the loader that text."""
    var raised = False
    var msg = String("")
    try:
        _ = parse_task_timeout_s(String("Not Found"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a non-numeric declared timeout is REFUSED")
    # ⚠ ASSERT ON THE TEXT, not merely that something raised: the `<= 0` branch
    # below raises too, so `raised` alone cannot tell the two refusals apart —
    # and the message naming the offending value IS the deliverable.
    assert_true(
        msg.find(String("Not Found")) >= 0,
        "the refusal names the value it saw, not just that it was wrong",
    )


def test_a_ZERO_timeout_is_REFUSED_rather_than_read_as_no_deadline() raises:
    """`"0"` is legible and means "already expired" — a placement that can never
    do any work. It is NOT a spelling of "no deadline"; EMPTY is."""
    var raised = False
    var msg = String("")
    try:
        _ = parse_task_timeout_s(String("0"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a ZERO declared timeout is REFUSED")
    assert_true(
        msg.find(String("POSITIVE")) >= 0,
        "the zero refusal is the POSITIVE-value one, not the non-numeric one",
    )


def test_a_NEGATIVE_timeout_is_REFUSED_by_the_DIGITS_rule() raises:
    """A leading `-` is not a digit, so it never reaches `atol`. Pinned because
    the alternative — parsing then range-checking — is where a signed value
    slips through as a huge unsigned one."""
    var raised = False
    try:
        _ = parse_task_timeout_s(String("-5"))
    except e:
        raised = True
    assert_true(raised, "a negative declared timeout is REFUSED")


# =============================================================================
# §6 — THE TRANSPORT HALF OF THE CALLBACK.
#
# ⛔⛔ WHAT THIS GUARDS. `ENV_HEARTBEAT_HOST` says WHERE the job manager is and
# nothing about HOW to reach it. A loader that hard-codes the missing half
# (plaintext, port 8088, no credential) cannot reach a job manager served as an
# HTTPS-only service on 443 behind an invoker role: the beats never reach the
# wire at all.
# =============================================================================


def test_the_transport_names_join_the_contract_and_stay_DISTINCT() raises:
    """The sixth and seventh env names, and their two GCE metadata keys, are
    present, non-empty and pairwise distinct from every name already in the
    contract — the §1/§2 property extended, for the same reason: two names that
    collapse to one string silently drop a value."""
    var env_names = List[String]()
    env_names.append(String(ENV_POD_SPEC_JSON))
    env_names.append(String(ENV_HEARTBEAT_HOST))
    env_names.append(String(ENV_JOB_ID))
    env_names.append(String(ENV_POD_NAME))
    env_names.append(String(ENV_TASK_TIMEOUT_S))
    env_names.append(String(ENV_HEARTBEAT_SCHEME))
    env_names.append(String(ENV_HEARTBEAT_AUTH))
    for i in range(len(env_names)):
        assert_true(
            env_names[i].byte_length() > 0, "no contract name may be empty"
        )
    assert_true(
        _all_distinct(env_names),
        "all SEVEN env names are pairwise distinct",
    )

    var meta_keys = List[String]()
    meta_keys.append(GCE_META_POD_SPEC)
    meta_keys.append(GCE_META_HEARTBEAT_HOST)
    meta_keys.append(GCE_META_JOB_ID)
    meta_keys.append(GCE_META_POD_NAME)
    meta_keys.append(GCE_META_TASK_TIMEOUT_S)
    meta_keys.append(GCE_META_HEARTBEAT_SCHEME)
    meta_keys.append(GCE_META_HEARTBEAT_AUTH)
    assert_true(
        _all_distinct(meta_keys),
        "all SEVEN GCE metadata keys are pairwise distinct",
    )


def test_a_BARE_HOST_with_no_scheme_is_UNCHANGED_plaintext_8088() raises:
    """⭐ THE COMPATIBLE DEFAULT, and it is the one that has to hold first. A
    placement that exports a bare host and no scheme must resolve to plaintext
    on the in-cluster listener's port, or a scheme-less placement silently
    re-points its traffic."""
    var t = resolve_heartbeat_target(String("jm.internal"), String(""))
    assert_equal(t.host, String("jm.internal"), "the host is untouched")
    assert_equal(
        t.port,
        DEFAULT_HEARTBEAT_PORT_HTTP,
        "an unschemed bare host keeps the in-cluster listener's port",
    )
    assert_false(t.use_tls, "an unschemed callback stays PLAINTEXT")


def test_an_https_URL_resolves_to_TLS_on_443_NOT_on_8088() raises:
    """⛔⛔ THE CORE CASE. A Cloud Run job manager's only address is
    `https://<service>-<suffix>.run.app`, which carries NO port. Resolving that
    to the plaintext listener's 8088 — which is what a scheme-blind default does
    — produces a dial that goes nowhere while every log line reports a correct
    TLS transport."""
    var t = resolve_heartbeat_target(
        String("https://job-manager-example-abcdefghij-uc.a.run.app"),
        String(""),
    )
    assert_true(t.use_tls, "an https:// callback dials TLS")
    assert_equal(
        t.port,
        DEFAULT_HEARTBEAT_PORT_HTTPS,
        "⭐ a TLS callback with no explicit port defaults to 443, NEVER 8088",
    )
    assert_equal(
        t.host,
        String("job-manager-example-abcdefghij-uc.a.run.app"),
        "the scheme is STRIPPED from the host — the dial takes an authority,"
        " and a host carrying 'https://' resolves to nothing",
    )
    assert_equal(t.scheme(), String("https"), "the scheme word round-trips")


def test_a_URL_with_a_TRAILING_SLASH_still_yields_a_bare_authority() raises:
    """The service registry publishes a BASE URL, and a base URL may carry a
    trailing slash. `send_heartbeat` appends `/internal/heartbeat` itself, so a
    path surviving into the host would build `…app//internal/heartbeat` — or,
    worse, make the host itself unresolvable."""
    var t = resolve_heartbeat_target(String("https://jm.example.com/"), String(""))
    assert_equal(t.host, String("jm.example.com"), "the trailing slash is gone")
    assert_true(t.use_tls, "and the scheme still selects TLS")


def test_an_EXPLICIT_port_beats_the_scheme_default_in_both_directions() raises:
    """A self-hosted job manager on `:8443` must keep its port, and so must an
    in-cluster one on a non-default plaintext port. The scheme picks a DEFAULT;
    it does not override what was stated."""
    var tls = resolve_heartbeat_target(String("https://jm.example.com:8443"), String(""))
    assert_equal(tls.port, 8443, "an explicit TLS port wins over 443")
    assert_true(tls.use_tls, "and it is still TLS")
    var plain = resolve_heartbeat_target(String("jm.internal:9099"), String(""))
    assert_equal(plain.port, 9099, "an explicit plaintext port wins over 8088")
    assert_false(plain.use_tls, "and it is still plaintext")


def test_the_SCHEME_ENV_alone_selects_TLS_and_443_for_a_bare_host() raises:
    """The GCE transport stamps the scheme as its own metadata key, so a bare
    host plus `KOMIRA_HEARTBEAT_SCHEME=https` must reach the same place an
    `https://` URL does. Both spellings exist because one renderer holds a URL
    (registry-resolved) and the other may hold a host."""
    var t = resolve_heartbeat_target(String("jm.example.com"), String("https"))
    assert_true(t.use_tls, "the scheme env alone selects TLS")
    assert_equal(t.port, DEFAULT_HEARTBEAT_PORT_HTTPS, "…and 443 with it")


def test_a_SCHEME_that_CONTRADICTS_the_URL_is_REFUSED() raises:
    """⛔ TWO CONFIGURED VALUES THAT DISAGREE ARE A REFUSAL, NOT A PRECEDENCE
    RULE. Letting one win silently means somebody is reading a different value
    than they think, and the consequence is a dial at the wrong port — the
    failure mode this whole §6 exists to close."""
    var raised = False
    try:
        _ = resolve_heartbeat_target(String("https://jm.example.com"), String("http"))
    except e:
        raised = True
        assert_true(
            String(e).find(String("CONTRADICTS")) >= 0,
            "the refusal names the disagreement",
        )
    assert_true(raised, "a scheme contradicting the URL is REFUSED")


def test_an_UNRECOGNISED_scheme_is_REFUSED_never_coerced_to_plaintext() raises:
    """⛔ A typo'd scheme coerced to `http` would dial in the clear at a TLS
    port and report an ordinary transport error forever — indistinguishable
    from a job manager that is merely down. This is the MALFORMED-CONTRACT
    class (`ENV_POD_SPEC_JSON`'s), which raises; it is NOT the unreachable-host
    class, which the supervisor must always tolerate."""
    var raised = False
    try:
        _ = resolve_heartbeat_target(String("jm.example.com"), String("htps"))
    except e:
        raised = True
        assert_true(
            String(e).find(String("htps")) >= 0,
            "the refusal names the value it saw",
        )
    assert_true(raised, "an unrecognised scheme is REFUSED")


def test_an_EMPTY_host_is_NOT_refused_here_the_refusal_is_at_PLACEMENT() raises:
    """⛔ THE SPLIT THAT MUST NOT COLLAPSE. "Is there a target at all" is
    answered by the placement conformer, BEFORE the instance exists. A
    supervisor that refused to start because it could not reach home would
    kill the workload it exists to supervise, so this parser tolerates an empty
    host and only refuses a MALFORMED one."""
    var t = resolve_heartbeat_target(String(""), String(""))
    assert_equal(t.host, String(""), "an empty host parses, it does not raise")
    assert_false(t.use_tls, "and stays plaintext")


# =============================================================================
# ⛔⛔ A MALFORMED HOST IS REFUSED, NEVER DIALLED AS WRITTEN.
#
# Both placement callers pass `raw_scheme=""`, so a resolver whose raise arms
# all needed a NON-empty scheme would never raise at placement, and "a
# malformed value is refused before an instance exists" would be vacuous.
# Without the host checks, each value below would resolve SILENTLY to a target
# nobody configured: `HTTPS://h` and `htps://h` to the host `HTTPS:` / `htps:`
# in PLAINTEXT on 8088, `h:abc` and `h:` to a host still carrying its colon,
# `https://` to an EMPTY host on 443 (past the placement's empty-string check,
# which reads the RAW value), and `h:70000` to a port the send site's
# `UInt16(...)` wraps to 4464.
#
# The cases pass `raw_scheme=""` deliberately — the PLACEMENT shape — so the
# only raise arms that can fire are the host checks.
# =============================================================================


def _assert_host_refused(raw_host: String, must_name: String, why: String) raises:
    """`raw_host` (at the placement shape, no scheme) RAISES, and the message
    names both the variable and `must_name` — the part that tells an operator
    what was wrong with it."""
    var raised = False
    var m = String("")
    # Filled only on the defect: WHERE the dial would have gone, because "did
    # not raise" alone does not say what the loader would have done instead.
    var resolved = String("")
    try:
        var t = resolve_heartbeat_target(raw_host, String(""))
        resolved = (
            String("host='")
            + t.host
            + String("' port=")
            + String(t.port)
            + (String(" TLS") if t.use_tls else String(" PLAINTEXT"))
        )
    except e:
        raised = True
        m = String(e)
    assert_true(
        raised,
        why
        + " — '"
        + raw_host
        + "' must be REFUSED, but it resolved to "
        + resolved,
    )
    assert_true(
        m.find(String(ENV_HEARTBEAT_HOST)) >= 0,
        why + " — the refusal names " + String(ENV_HEARTBEAT_HOST) + ": " + m,
    )
    assert_true(
        m.find(must_name) >= 0,
        why + " — the refusal says '" + must_name + "': " + m,
    )


def test_the_URL_scheme_is_matched_CASE_INSENSITIVELY() raises:
    """⛔ RFC 3986 §3.1: a scheme is case-insensitive. A case-sensitive prefix
    match would turn `HTTPS://h` into the host `HTTPS:` dialled in PLAINTEXT on
    8088 — the exact silent coercion the scheme refusal exists to prevent, one
    input over."""
    var t = resolve_heartbeat_target(String("HTTPS://jm.example.com"), String(""))
    assert_true(
        t.use_tls,
        "⭐ `HTTPS://` is TLS — got host='" + t.host + "' port=" + String(t.port),
    )
    assert_equal(t.port, DEFAULT_HEARTBEAT_PORT_HTTPS, "…on 443")
    assert_equal(t.host, String("jm.example.com"), "…with the scheme stripped")
    var p = resolve_heartbeat_target(String("Http://jm.internal"), String(""))
    assert_false(p.use_tls, "`Http://` is plaintext")
    assert_equal(p.port, DEFAULT_HEARTBEAT_PORT_HTTP, "…on 8088")
    assert_equal(p.host, String("jm.internal"), "…with the scheme stripped")
    # The HOST keeps its case: only the scheme is case-insensitive here, and a
    # DNS name's case is not this parser's to rewrite.
    var h = resolve_heartbeat_target(String("https://JM.Example.com"), String(""))
    assert_equal(h.host, String("JM.Example.com"), "the host is not lowered")


def test_a_TYPOD_or_FOREIGN_URL_scheme_is_REFUSED_never_glued_into_the_host() raises:
    """⛔ ANY `<scheme>://` THAT IS NOT http/https IS REFUSED. Without this,
    `htps://jm.x` slash-cuts to the host `htps:` and is dialled in plaintext."""
    _assert_host_refused(
        String("htps://jm.example.com"),
        String("is not a callback scheme"),
        "a typo'd `htps://`",
    )
    _assert_host_refused(
        String("grpc://jm.example.com"),
        String("is not a callback scheme"),
        "a foreign `grpc://`",
    )
    _assert_host_refused(
        String("://jm.example.com"),
        String("is not a callback scheme"),
        "an EMPTY scheme before `://`",
    )


def test_a_COLON_that_is_not_a_PORT_is_REFUSED() raises:
    """⛔ A `:` THAT IS PRESENT IS A PORT OR A REFUSAL. Keeping the colon of
    `h:abc` / `h:` in the host would dial a name that cannot resolve — for the
    life of the placement, looking exactly like a job manager that is down."""
    _assert_host_refused(
        String("jm.example.com:"), String("is not a port number"), "`h:`"
    )
    _assert_host_refused(
        String("jm.example.com:abc"), String("is not a port number"), "`h:abc`"
    )
    _assert_host_refused(
        String("https://jm.example.com:"),
        String("is not a port number"),
        "a URL ending in `:`",
    )
    _assert_host_refused(
        String("jm.example.com:123456"),
        String("is not a port number"),
        "a six-digit port (refused BEFORE `atol`, never an overflow)",
    )


def test_a_PORT_outside_1_to_65535_is_REFUSED_and_the_bounds_are_ACCEPTED() raises:
    """⛔ CHECKED BEFORE THE VALUE REACHES `UInt16(...)` AT THE SEND SITE, where
    70000 wraps SILENTLY to 4464 — a dial at a port nobody configured."""
    _assert_host_refused(
        String("jm.example.com:70000"),
        String("outside 1..65535"),
        "`h:70000`",
    )
    _assert_host_refused(
        String("jm.example.com:99999"),
        String("outside 1..65535"),
        "`h:99999`",
    )
    _assert_host_refused(
        String("jm.example.com:0"), String("outside 1..65535"), "`h:0`"
    )
    var lo = resolve_heartbeat_target(String("jm.example.com:1"), String(""))
    assert_equal(lo.port, 1, "port 1 is a legal port")
    var hi = resolve_heartbeat_target(String("jm.example.com:65535"), String(""))
    assert_equal(hi.port, 65535, "port 65535 is a legal port")


def test_a_URL_or_a_PORT_with_NO_HOST_is_REFUSED() raises:
    """⛔ `https://` IS NOT THE SAME STATEMENT AS AN UNSET VALUE. An empty
    `raw_host` is tolerated here (the refusal for "nobody configured this" is at
    placement); a NON-empty one that names no host is malformed. Unchecked,
    `https://` would become an EMPTY host stamped as `:443`, slipping past the
    placement's empty-string check, which reads the raw value."""
    _assert_host_refused(
        String("https://"), String("names no host"), "a bare `https://`"
    )
    _assert_host_refused(
        String("http://"), String("names no host"), "a bare `http://`"
    )
    _assert_host_refused(
        String(":8088"), String("names no host"), "a port with no host"
    )
    _assert_host_refused(
        String("https:///internal"),
        String("names no host"),
        "a URL whose authority is empty",
    )


def test_an_UNBRACKETED_colon_is_REFUSED_and_a_BRACKETED_IPv6_literal_is_not() raises:
    """⛔ `a:b:80` HAS A HOST THAT STILL CONTAINS `:` AFTER THE PORT IS TAKEN —
    not a DNS name, not an IPv4 literal, and an IPv6 literal must be bracketed.
    The bracketed forms keep working (a `:` INSIDE `[...]` is not a port
    separator)."""
    _assert_host_refused(
        String("a:b:80"), String("still contains ':'"), "`a:b:80`"
    )
    var v6 = resolve_heartbeat_target(String("[fd00::1]:8088"), String(""))
    assert_equal(v6.host, String("[fd00::1]"), "a bracketed v6 host survives")
    assert_equal(v6.port, 8088, "…and its explicit port is taken")
    var v6_bare = resolve_heartbeat_target(String("https://[fd00::1]"), String(""))
    assert_equal(v6_bare.host, String("[fd00::1]"), "no port: the brackets stay")
    assert_equal(
        v6_bare.port,
        DEFAULT_HEARTBEAT_PORT_HTTPS,
        "…and the scheme default applies — the `:` inside the brackets is not"
        " read as a port",
    )


# =============================================================================
# ⛔⛔ THE WRITER'S OUTPUT ROUND-TRIPS THROUGH THE READER.
#
# A strict reader can turn a writer's output into a refusal. `:8088` is "names
# no host", and an EC2 renderer that rendered `:8088` for an EMPTY callback URL
# (which the AWS job manager tolerates on purpose: a VM job still runs and
# self-terminates) would make the loader raise at boot and exit before spawning
# anything, and the boot script would go straight to `shutdown -h now`: a VM
# that runs NOTHING, where an empty host would have run the workload and only
# lost its beats. Each side's own tests stay green because none of them feeds
# one side's output into the other.
# =============================================================================


def _assert_round_trips(raw_host: String, raw_scheme: String) raises:
    """`raw_host`/`raw_scheme` resolves; the writer renders it; the loader's
    reader resolves the RENDERED pair back to the same host, port and TLS bit,
    and does NOT raise."""
    var t = resolve_heartbeat_target(raw_host, raw_scheme)
    var wire_host = render_heartbeat_host(t)
    var wire_scheme = t.scheme()
    var label = (
        String("('")
        + raw_host
        + String("', '")
        + raw_scheme
        + String("') -> stamped ")
        + String(ENV_HEARTBEAT_HOST)
        + String("='")
        + wire_host
        + String("' ")
        + String(ENV_HEARTBEAT_SCHEME)
        + String("='")
        + wire_scheme
        + String("'")
    )
    var err = String("")
    var back_host = String("<unset>")
    var back_port = -1
    var back_tls = not t.use_tls
    try:
        var back = resolve_heartbeat_target(wire_host, wire_scheme)
        back_host = back.host
        back_port = back.port
        back_tls = back.use_tls
    except e:
        err = String(e)
    assert_equal(
        err,
        String(""),
        "⛔ the loader's READER refuses what the WRITER rendered: " + label,
    )
    assert_equal(back_host, t.host, "the host survives the round trip: " + label)
    assert_equal(back_port, t.port, "the port survives the round trip: " + label)
    assert_equal(
        back_tls, t.use_tls, "the TLS bit survives the round trip: " + label
    )


def test_every_ACCEPTED_target_ROUND_TRIPS_through_the_writer_and_the_reader() raises:
    """★ `resolve_heartbeat_target(render_heartbeat_host(t), t.scheme()) == t`
    for every `t` the resolver accepts. The EMPTY rows go last. They are the
    shape the EC2 renderer produces for an empty callback URL, which is
    tolerated upstream by design."""
    _assert_round_trips(String("jm.internal"), String(""))
    _assert_round_trips(String("jm.internal"), String("https"))
    _assert_round_trips(String("10.0.0.9:8081"), String(""))
    _assert_round_trips(String("10.128.0.7:8081"), String("http"))
    _assert_round_trips(String("https://job-manager-aws.example.com"), String(""))
    _assert_round_trips(
        String("https://job-manager-example-x.a.run.app/"), String("")
    )
    _assert_round_trips(String("http://jm.internal:9000"), String(""))
    _assert_round_trips(String("HTTPS://jm.example.com:8443"), String(""))
    _assert_round_trips(String("jm.example.com:1"), String(""))
    _assert_round_trips(String("jm.example.com:65535"), String("https"))
    _assert_round_trips(String("[fd00::1]:8088"), String(""))
    _assert_round_trips(String("https://[fd00::1]"), String(""))
    # ⛔ THE EMPTY-HOST ROWS. An empty host is accepted by the reader, so the
    # writer must render something the reader also accepts.
    _assert_round_trips(String(""), String(""))
    _assert_round_trips(String(""), String("http"))
    _assert_round_trips(String(""), String("https"))
    assert_equal(
        render_heartbeat_host(resolve_heartbeat_target(String(""), String(""))),
        String(""),
        "an EMPTY host renders EMPTY, never ':8088'",
    )


def main() raises:
    print("=== test_pod_boot_contract ===")
    test_the_four_env_names_are_present_and_pairwise_distinct()
    test_the_gce_metadata_keys_are_distinct_and_not_the_env_names()
    test_the_pod_loader_install_path_is_ABSOLUTE()
    test_the_pod_spec_round_trips_with_every_container_preserved()
    test_a_value_carrying_JSON_METACHARACTERS_round_trips()
    test_the_timeout_name_joins_the_contract_and_stays_DISTINCT()
    test_an_EMPTY_timeout_is_NO_DEADLINE_and_is_not_an_error()
    test_a_POSITIVE_integer_timeout_decodes_to_that_many_seconds()
    test_a_NON_NUMERIC_timeout_is_REFUSED_and_never_degraded_to_None()
    test_a_ZERO_timeout_is_REFUSED_rather_than_read_as_no_deadline()
    test_a_NEGATIVE_timeout_is_REFUSED_by_the_DIGITS_rule()
    test_the_transport_names_join_the_contract_and_stay_DISTINCT()
    test_a_BARE_HOST_with_no_scheme_is_UNCHANGED_plaintext_8088()
    test_an_https_URL_resolves_to_TLS_on_443_NOT_on_8088()
    test_a_URL_with_a_TRAILING_SLASH_still_yields_a_bare_authority()
    test_an_EXPLICIT_port_beats_the_scheme_default_in_both_directions()
    test_the_SCHEME_ENV_alone_selects_TLS_and_443_for_a_bare_host()
    test_a_SCHEME_that_CONTRADICTS_the_URL_is_REFUSED()
    test_an_UNRECOGNISED_scheme_is_REFUSED_never_coerced_to_plaintext()
    test_an_EMPTY_host_is_NOT_refused_here_the_refusal_is_at_PLACEMENT()
    test_the_URL_scheme_is_matched_CASE_INSENSITIVELY()
    test_a_TYPOD_or_FOREIGN_URL_scheme_is_REFUSED_never_glued_into_the_host()
    test_a_COLON_that_is_not_a_PORT_is_REFUSED()
    test_a_PORT_outside_1_to_65535_is_REFUSED_and_the_bounds_are_ACCEPTED()
    test_a_URL_or_a_PORT_with_NO_HOST_is_REFUSED()
    test_an_UNBRACKETED_colon_is_REFUSED_and_a_BRACKETED_IPv6_literal_is_not()
    test_every_ACCEPTED_target_ROUND_TRIPS_through_the_writer_and_the_reader()
    print(
        "PASS test_pod_boot_contract: four distinct env names / four distinct"
        " GCE metadata keys / absolute install path / 3-container round-trip"
        " with images preserved / JSON metacharacter escaping / the FIFTH"
        " (declared-runtime) name: empty=None, positive=seconds, and"
        " non-numeric / zero / negative REFUSED by name / the SIXTH+SEVENTH"
        " (transport) names: bare host unchanged at plaintext 8088, an https"
        " URL at TLS 443, trailing slash stripped, explicit port wins, a"
        " contradicting scheme and an unrecognised scheme REFUSED, and an"
        " EMPTY host tolerated because that refusal belongs at PLACEMENT /"
        " a MALFORMED host REFUSED at the placement shape: URL scheme matched"
        " case-insensitively, a typo'd or foreign `x://` refused, a `:` that is"
        " not a port refused, a port outside 1..65535 refused (bounds"
        " accepted), a URL or `:port` naming no host refused, and an"
        " unbracketed `:` refused while a bracketed IPv6 literal still resolves"
        " / every accepted target, EMPTY included, round-trips through the"
        " writer and the reader"
    )
