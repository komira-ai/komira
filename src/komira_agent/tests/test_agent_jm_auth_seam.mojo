# =============================================================================
# komira_agent/tests/test_agent_jm_auth_seam.mojo
#   THE SUPERVISOR CAN AUTHENTICATE TO AN IAM-GATED JOB MANAGER.
# =============================================================================
#
# ⛔⛔ THE DEFECT. Every finite job's supervisor beats to
# `POST /internal/heartbeat`, and the agent had ZERO token support:
# `send_heartbeat` built exactly ONE header (`Content-Type:
# application/protobuf`) and no metadata-server client existed in the agent.
# A job manager deployed as a Cloud Run service that is NOT `public_invoker`
# answers 403 at the Google Frontend on EVERY route. So a supervisor in a
# customer container could not authenticate and every beat was refused at the
# door.
#
# ⛔ AND A SECOND, INDEPENDENT DEFECT ON THE SAME PATH, WHICH ARM 3 IS ABOUT.
# `AgentConfig.from_env` defaulted `THORIUM_AGENT_JM_PORT` to a flat `8081`
# regardless of scheme. `pod_spec._split_url_host_port` returns an EMPTY port
# for a URL carrying none — and a Cloud Run URL
# (`https://job-manager-….run.app`) carries none — so a correctly `https`-
# schemed agent dialled `https://host:8081` while Cloud Run serves 443. TLS was
# threaded CORRECTLY and the port was still wrong. Fixing auth without fixing
# this produces a perfectly-signed request sent to a closed port.
#
# ★ WHAT THIS TEST IS. It walks the seam in the order the value travels —
# posture spelling -> audience derivation -> env -> headers -> the SERIALIZED
# WIRE — because each half is green on its own while the seam is broken. A test
# of `jm_audience` alone passes with a client that never attaches the header; a
# test of the header list alone passes with an audience that the ingress edge
# rejects.
#
# ⚠ EVERY ARM CARRIES A CONTROL, per `test_agent_https_transport_seam.mojo`'s
# rule: an assertion that "gcp-metadata yields a token" is satisfied by a
# function that returns a header unconditionally, so each arm is paired with the
# case that must come back EMPTY / REFUSED.
#
# ⚠ THE MINTER IS A SEAM SO THIS FILE IS HOST-INDEPENDENT. Asserting "the mint
# fails because metadata.google.internal does not resolve here" would be a test
# of the BUILD BOX and would flip green-to-red the day the suite runs on a GCE
# worker. `ScriptedMinter` / `FailingMinter` make the refusal a property of the
# POSTURE, which is the thing actually being claimed. Nothing here dials.
#
# ⚠ THE WIRE HALF OF ARM 9 LIVES NEXT DOOR. ARM 9 pins that the config reader
# refuses a credential posture over plaintext; the SEND-SITE refusal (nothing
# minted, nothing dialled) needs a loopback listener and a thread, so it is its
# own file: `test_heartbeat_no_credential_in_clear.mojo`.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.body import BytesBody
from komira_http_client.client import build_request_with_body
from komira_http_client.header_map import HeaderEntry, HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod

from komira_agent.agent_config import AgentConfig
from komira_agent.heartbeat_client import HEARTBEAT_STATUS_AUTH_UNAVAILABLE
# The env names ARM 9 sets: the agent's placement contract, the names the job
# manager's pod render stamps and `AgentConfig.from_env` reads.
comptime AGENT_ENV_JM_PORT: StaticString = "THORIUM_AGENT_JM_PORT"
comptime AGENT_ENV_JM_SCHEME: StaticString = "THORIUM_AGENT_JM_SCHEME"
comptime AGENT_ENV_JM_AUTH: StaticString = "THORIUM_AGENT_JM_AUTH"
from komira_agent.jm_auth import (
    GcpMetadataMinter,
    JmAuthMode,
    JmTokenMinter,
    jm_audience,
    jm_auth_headers,
    parse_jm_auth_mode,
)


# =============================================================================
# helpers
# =============================================================================
comptime _CANNED_JWT: String = (
    "eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2ptLmV4YW1wbGUifQ.c2lnbmF0dXJl"
)


def _setenv(name: String, value: String):
    """libc setenv (tests only — the `test_agent_https_transport_seam` idiom)."""
    var name_str = name
    var value_str = value
    var name_ptr = name_str.as_c_string_slice().unsafe_ptr()
    var value_ptr = value_str.as_c_string_slice().unsafe_ptr()
    var _rc = external_call["setenv", Int32](name_ptr, value_ptr, Int32(1))


def _unsetenv(name: String):
    """libc unsetenv. ⚠ LOAD-BEARING FOR ARM 3, NOT TIDINESS: the arm's whole
    subject is what happens when THORIUM_AGENT_JM_PORT is ABSENT, and env is
    process-global — a sibling arm's `_setenv` would otherwise decide this
    arm's verdict."""
    var name_str = name
    var name_ptr = name_str.as_c_string_slice().unsafe_ptr()
    var _rc = external_call["unsetenv", Int32](name_ptr)


def _required_agent_env():
    """The three REQUIRED THORIUM_AGENT_* vars, so `from_env` reaches the
    fields the arms are about instead of fail-fasting on a missing job id."""
    _setenv(
        String("THORIUM_AGENT_JOB_ID"),
        String("11111111-2222-3333-4444-555555555555"),
    )
    _setenv(String("THORIUM_AGENT_POD_NAME"), String("pod-jm-auth-seam"))
    _setenv(String("THORIUM_AGENT_JOB_BINARY"), String("/bin/true"))
    _setenv(String("THORIUM_AGENT_JM_HOST"), String("jm.example.com"))
    # This file is about auth + port; keep the posture arms from leaking into
    # the port arms and vice versa.
    _unsetenv(String("THORIUM_AGENT_JM_AUTH"))
    _unsetenv(String("THORIUM_AGENT_JM_AUDIENCE"))


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


def _head_of(var req_bytes: List[UInt8]) -> String:
    """The serialized request as a LOWERCASED String.

    ⚠ LOWERCASED ON PURPOSE. The assertion is that the header IS ON THE WIRE,
    not that the writer chose a particular capitalisation — HTTP header names
    are case-insensitive (RFC 9110 §5.1) and an arm that pinned `Authorization`
    exactly would go red on a writer change that broke nothing."""
    return String(unsafe_from_utf8=Span(req_bytes)).lower()


struct ScriptedMinter(JmTokenMinter):
    """A minter that returns a canned JWT without touching a network. Lets ARM
    4 assert the token reaches the WIRE on a box with no metadata server."""

    var token: String
    var calls: Int

    def __init__(out self, var token: String):
        self.token = token^
        self.calls = 0

    def mint(mut self, audience: String) raises -> String:
        self.calls += 1
        return self.token


struct FailingMinter(JmTokenMinter):
    """A minter that always raises — the off-GCP / no-metadata-server case,
    reproduced deterministically instead of by being off GCP."""

    var _placeholder: UInt8

    def __init__(out self):
        self._placeholder = UInt8(0)

    def mint(mut self, audience: String) raises -> String:
        raise Error("agent jm auth: metadata identity GET failed: HTTP 404")


# =============================================================================
# ARM 1 — the audience is the JM's SERVICE URL, and the default port is OMITTED.
# =============================================================================
def test_jm_audience_omits_the_default_port() raises:
    """Google validates an ID token's `aud` against the Cloud Run service URL —
    `https://job-manager-….run.app`, with NO `:443`. A token minted for
    `https://host:443` is REJECTED at the ingress edge, and the agent cannot
    tell that apart from having sent no token at all.

    RED before the fix: `jm_audience` did not exist — there was nothing to mint
    an audience for, because there was no minting."""
    assert_equal(
        jm_audience(String("https"), String("jm.example.com"), UInt16(443)),
        String("https://jm.example.com"),
        "the Cloud Run audience must omit the default 443 -- a token minted for"
        " https://host:443 is refused at the ingress edge",
    )
    # CONTROL: a NON-default port is rendered, or a self-hosted JM on :8443
    # would get an audience naming a port it does not serve.
    assert_equal(
        jm_audience(String("https"), String("jm.example.com"), UInt16(8443)),
        String("https://jm.example.com:8443"),
        "CONTROL: a non-default https port must be rendered",
    )
    # CONTROL: the plaintext in-cluster shape is unchanged and still carries its
    # port -- this arm must not be satisfied by a function that drops every port.
    assert_equal(
        jm_audience(String("http"), String("jm.local"), UInt16(8081)),
        String("http://jm.local:8081"),
        "CONTROL: the in-cluster http:8081 audience still carries its port",
    )
    assert_equal(
        jm_audience(String("http"), String("jm.local"), UInt16(80)),
        String("http://jm.local"),
        "CONTROL: 80 is http's default and is omitted too",
    )
    print("  test_jm_audience_omits_the_default_port: PASS")


# =============================================================================
# ARM 2 — the posture is a CLOSED SET and a typo REFUSES.
# =============================================================================
def test_jm_auth_posture_is_a_closed_set() raises:
    """⛔ A TYPO MUST RAISE, NOT FALL BACK TO `none`. A misspelled posture that
    silently degraded would beat bearer-less into a 403 forever while every log
    line said the agent was healthy — the fail-open shape the heartbeat contract exists
    to remove. Refusing at boot surfaces the mistake at its cause.

    RED before the fix: `parse_jm_auth_mode` and `JmAuthMode` did not exist."""
    var gcp = parse_jm_auth_mode(String("gcp-metadata"))
    assert_false(
        gcp.is_none(),
        "'gcp-metadata' must select a real posture",
    )
    # CONTROL: absent/empty is `none`, which is today's behaviour -- so an
    # unstamped placement is byte-identical to the pre-fix agent.
    var none_mode = parse_jm_auth_mode(String(""))
    assert_true(
        none_mode.is_none(),
        "CONTROL: an ABSENT posture must be `none` -- every existing manifest"
        " renders unchanged",
    )

    # CONTROLS: four near-misses, each of which must REFUSE. Without these the
    # arm above is satisfied by a parser that returns gcp_metadata for anything
    # non-empty.
    var rejected = 0
    var probes = List[String]()
    probes.append(String("GCP-METADATA"))  # wrong case
    probes.append(String("gcp_metadata"))  # underscore, the likeliest typo
    probes.append(String("iam"))           # the JM's own spelling, not ours
    probes.append(String("true"))          # a boolean, not a posture
    probes.append(String(" gcp-metadata")) # leading space
    for i in range(len(probes)):
        try:
            var _m = parse_jm_auth_mode(probes[i])
        except e:
            rejected += 1
    assert_equal(
        rejected,
        len(probes),
        "CONTROL: every near-miss spelling must RAISE -- a posture that accepts"
        " near-misses cannot tell an operator which spelling is canonical",
    )
    print("  test_jm_auth_posture_is_a_closed_set: PASS")


# =============================================================================
# ARM 3 — ★ THE BEHAVIOURAL FAIL-FIRST: the JM port default is SCHEME-AWARE.
# =============================================================================
def test_https_with_no_port_defaults_to_443() raises:
    """⛔ THE ONE ARM THAT WAS RED ON UNMODIFIED SOURCE WITHOUT A COMPILE ERROR.

    Measured against the untouched tree: with THORIUM_AGENT_JM_SCHEME=https and
    THORIUM_AGENT_JM_PORT UNSET, `from_env()` produced jm_port=8081 and
    jm_uses_tls=True — i.e. `https://jm.example.com:8081`, while Cloud Run
    serves 443. Every other arm in this file is red BEFORE only as a compile
    error (the surface did not exist), which is a weaker red than this one."""
    _required_agent_env()
    _setenv(String("THORIUM_AGENT_JM_SCHEME"), String("https"))
    _unsetenv(String("THORIUM_AGENT_JM_PORT"))
    var cfg = AgentConfig.from_env()
    assert_true(
        cfg.jm_uses_tls(),
        "precondition: the https scheme still selects TLS",
    )
    assert_equal(
        Int(cfg.jm_port),
        443,
        "an https JM with no explicit port must default to 443 -- a Cloud Run"
        " URL carries no port, so 8081 dialled a closed port with a perfectly"
        " correct TLS transport",
    )
    assert_equal(
        cfg.jm_auth_audience(),
        String("https://jm.example.com"),
        "the derived audience must be the service URL with no port",
    )

    # CONTROL: http with no port keeps TODAY'S 8081 exactly, so every
    # in-cluster manifest renders byte-identically. Without this control the
    # arm above is satisfied by defaulting everything to 443.
    _setenv(String("THORIUM_AGENT_JM_SCHEME"), String("http"))
    _unsetenv(String("THORIUM_AGENT_JM_PORT"))
    var http_cfg = AgentConfig.from_env()
    assert_equal(
        Int(http_cfg.jm_port),
        8081,
        "CONTROL: http with no port must keep the pre-existing 8081",
    )

    # CONTROL: an EXPLICIT port always wins over the scheme default, under both
    # schemes -- a default that overrode an operator's explicit value would be
    # a worse bug than the one being fixed.
    _setenv(String("THORIUM_AGENT_JM_SCHEME"), String("https"))
    _setenv(String("THORIUM_AGENT_JM_PORT"), String("9443"))
    var explicit_cfg = AgentConfig.from_env()
    assert_equal(
        Int(explicit_cfg.jm_port),
        9443,
        "CONTROL: an explicit port is never overridden by the scheme default",
    )
    assert_equal(
        explicit_cfg.jm_auth_audience(),
        String("https://jm.example.com:9443"),
        "CONTROL: a non-default explicit port reaches the audience",
    )
    _unsetenv(String("THORIUM_AGENT_JM_PORT"))
    print("  test_https_with_no_port_defaults_to_443: PASS")


def test_the_posture_and_audience_come_off_the_placement_env() raises:
    """The declared posture and the audience override travel from the placement
    env into the config. ⛔ A TYPO IN THE POSTURE ABORTS `from_env` ITSELF —
    at boot, not at the first 403.

    RED before the fix: neither var was read; `AgentConfig` had no such field."""
    _required_agent_env()
    _setenv(String("THORIUM_AGENT_JM_SCHEME"), String("https"))
    _unsetenv(String("THORIUM_AGENT_JM_PORT"))

    _setenv(String("THORIUM_AGENT_JM_AUTH"), String("gcp-metadata"))
    var cfg = AgentConfig.from_env()
    assert_false(
        cfg.jm_auth_mode.is_none(),
        "a stamped THORIUM_AGENT_JM_AUTH must reach AgentConfig -- without"
        " this the placement cannot turn auth on at all",
    )

    # The override wins over the derived audience when present.
    _setenv(
        String("THORIUM_AGENT_JM_AUDIENCE"),
        String("https://proxy.example.com"),
    )
    var over_cfg = AgentConfig.from_env()
    assert_equal(
        over_cfg.jm_auth_audience(),
        String("https://proxy.example.com"),
        "an explicit audience override must win over the derived one",
    )
    _unsetenv(String("THORIUM_AGENT_JM_AUDIENCE"))

    # CONTROL: an ABSENT posture is `none` -- the default, and byte-identical
    # to the pre-fix agent.
    _unsetenv(String("THORIUM_AGENT_JM_AUTH"))
    var default_cfg = AgentConfig.from_env()
    assert_true(
        default_cfg.jm_auth_mode.is_none(),
        "CONTROL: an unstamped placement must default to `none`",
    )

    # CONTROL: a TYPO'd posture refuses `from_env` outright.
    _setenv(String("THORIUM_AGENT_JM_AUTH"), String("gcp_metadata"))
    var raised = False
    try:
        var _c = AgentConfig.from_env()
    except e:
        raised = True
    assert_true(
        raised,
        "CONTROL: a misspelled posture must abort boot -- degrading it to"
        " `none` would beat bearer-less into a 403 forever",
    )
    _unsetenv(String("THORIUM_AGENT_JM_AUTH"))
    print("  test_the_posture_and_audience_come_off_the_placement_env: PASS")


# =============================================================================
# ARM 4 — ★ THE WIRE ARM. The token reaches the SERIALIZED REQUEST.
# =============================================================================
def test_the_bearer_reaches_the_serialized_request() raises:
    """★ THE ARM THAT ACTUALLY FALSIFIES THE DEFECT. Everything above proves the
    decision is EXPRESSIBLE; this proves it reaches the bytes.

    It feeds `jm_auth_headers`' output through the SAME `HeaderMap` +
    `build_request_with_body` path `send_heartbeat` uses and reads
    `ClientRequest.request_bytes` — the serialized head, i.e. the actual wire.

    RED before the fix: `send_heartbeat` appended exactly one header and there
    was no second one to append."""
    var minter = ScriptedMinter(_CANNED_JWT)
    var body = List[UInt8]()
    body.append(UInt8(0x08))
    var auth = jm_auth_headers[ScriptedMinter](
        JmAuthMode.gcp_metadata(),
        minter,
        String("https://jm.example.com"),
        String("POST"),
        String("/internal/heartbeat"),
        body,
    )
    assert_equal(
        len(auth), 1, "the gcp-metadata posture must produce exactly one header"
    )
    assert_equal(
        minter.calls, 1, "the posture must actually have called the minter"
    )

    var headers = HeaderMap()
    headers.append(String("Content-Type"), String("application/protobuf"))
    for i in range(len(auth)):
        headers.append(auth[i].name, auth[i].value)
    var req = build_request_with_body[BytesBody](
        HttpMethod(code=HTTP_METHOD_POST),
        Url.https(
            String("jm.example.com"),
            UInt16(443),
            String("/internal/heartbeat"),
        ),
        headers^,
        BytesBody.from_bytes(body.copy()),
    )
    var head = _head_of(req.request_bytes.copy())
    assert_true(
        _contains(head, String("authorization: bearer ") + _CANNED_JWT.lower()),
        "the bearer credential must appear on the SERIALIZED wire -- a header"
        " list nothing serializes authenticates nothing",
    )
    assert_true(
        _contains(head, String("content-type: application/protobuf")),
        "the pre-existing Content-Type must survive unchanged",
    )
    _ = req^

    # CONTROL: under `none` the SAME path emits NO authorization at all, and
    # the request is byte-identical to the pre-fix one. Without this the arm
    # above is satisfied by a builder that always attaches a bearer.
    var none_minter = ScriptedMinter(_CANNED_JWT)
    var none_auth = jm_auth_headers[ScriptedMinter](
        JmAuthMode.none(),
        none_minter,
        String("https://jm.example.com"),
        String("POST"),
        String("/internal/heartbeat"),
        body,
    )
    assert_equal(
        len(none_auth), 0, "CONTROL: posture `none` must add no header"
    )
    assert_equal(
        none_minter.calls,
        0,
        "CONTROL: posture `none` must not even CALL the minter -- a mint has a"
        " network cost and a credential lifetime, neither of which an unstamped"
        " placement asked for",
    )
    var none_headers = HeaderMap()
    none_headers.append(
        String("Content-Type"), String("application/protobuf")
    )
    for i in range(len(none_auth)):
        none_headers.append(none_auth[i].name, none_auth[i].value)
    var none_req = build_request_with_body[BytesBody](
        HttpMethod(code=HTTP_METHOD_POST),
        Url.https(
            String("jm.example.com"),
            UInt16(443),
            String("/internal/heartbeat"),
        ),
        none_headers^,
        BytesBody.from_bytes(body.copy()),
    )
    var none_head = _head_of(none_req.request_bytes.copy())
    assert_false(
        _contains(none_head, String("authorization")),
        "CONTROL: posture `none` must serialize NO authorization header",
    )
    _ = none_req^
    print("  test_the_bearer_reaches_the_serialized_request: PASS")


# =============================================================================
# ARM 5 — ★ FAIL-CLOSED. A mint failure RAISES; it never degrades.
# =============================================================================
def test_a_mint_failure_refuses_rather_than_sending_bearer_less() raises:
    """⛔ THE ARM THAT KEEPS THE TWO FAILURES APART. If a mint failure returned
    an empty header list, the beat would go out bearer-less, 403 at the ingress
    edge, and arrive back at the agent loop as an ordinary transport failure —
    making "this image cannot authenticate" indistinguishable from "the network
    blipped". The heartbeat contract's premise is that those two must never share a code
    path.

    RED before the fix: there was no posture to fail closed on."""
    var failing = FailingMinter()
    var body = List[UInt8]()
    var raised = False
    try:
        var _h = jm_auth_headers[FailingMinter](
            JmAuthMode.gcp_metadata(),
            failing,
            String("https://jm.example.com"),
            String("POST"),
            String("/internal/heartbeat"),
            body,
        )
    except e:
        raised = True
    assert_true(
        raised,
        "a mint failure under a DECLARED posture must RAISE -- returning an"
        " empty list would send the beat bearer-less into a 403",
    )

    # CONTROL: the SAME failing minter under posture `none` returns an empty
    # list and does NOT raise. This is what proves the refusal belongs to the
    # POSTURE and not to the minter -- without it, the arm above is satisfied
    # by a seam that raises unconditionally.
    var failing2 = FailingMinter()
    var ok_list = jm_auth_headers[FailingMinter](
        JmAuthMode.none(),
        failing2,
        String("https://jm.example.com"),
        String("POST"),
        String("/internal/heartbeat"),
        body,
    )
    assert_equal(
        len(ok_list),
        0,
        "CONTROL: under `none` even a failing minter yields an empty list and"
        " no raise -- the refusal is the posture's, not the minter's",
    )

    # The agent-visible outcome of that refusal is DISTINCT from "never
    # connected" (status 0). Conflating them is the collapse the heartbeat contract
    # removes, so the sentinel must not be 0 and must not be a real HTTP status.
    assert_true(
        HEARTBEAT_STATUS_AUTH_UNAVAILABLE < 0,
        "AUTH_UNAVAILABLE must be negative -- it must never collide with a"
        " real HTTP status, and must never equal 0 (`never connected`)",
    )
    print(
        "  test_a_mint_failure_refuses_rather_than_sending_bearer_less: PASS"
    )


# =============================================================================
# ARM 6 — the credential never reaches a string a human copies.
# =============================================================================
def test_the_token_never_reaches_an_error_or_a_mode_name() raises:
    """An exception string is the most-copied text in an incident, and a JWT
    pasted into a ticket is a credential leak with a long tail. So the raise
    carries the HTTP status and the MODE, never the token.

    ⚠ THIS ARM IS ABOUT A DISCIPLINE THAT NOTHING ELSE ENFORCES. `jm_auth.mojo`
    could carry the token into an error at any future edit and every other arm
    here would stay green."""
    # The canned JWT's three segments, so a partial leak is caught too.
    var seg_a = String("eyJhbGciOiJSUzI1NiJ9")
    var seg_b = String("eyJhdWQiOiJodHRwczovL2ptLmV4YW1wbGUifQ")
    var seg_c = String("c2lnbmF0dXJl")

    var failing = FailingMinter()
    var body = List[UInt8]()
    var msg = String("")
    try:
        var _h = jm_auth_headers[FailingMinter](
            JmAuthMode.gcp_metadata(),
            failing,
            String("https://jm.example.com"),
            String("POST"),
            String("/internal/heartbeat"),
            body,
        )
    except e:
        msg = String(e)
    assert_true(
        msg.byte_length() > 0, "precondition: the arm produced an error string"
    )
    assert_false(
        _contains(msg, seg_a)
        or _contains(msg, seg_b)
        or _contains(msg, seg_c),
        "no part of a credential may appear in an error string",
    )

    # `name()` renders the POSTURE, which is what a log line is allowed to say.
    assert_equal(
        JmAuthMode.gcp_metadata().name(),
        String("gcp-metadata"),
        "name() must render the mode -- it is the only auth fact the heartbeat"
        " WARN line is permitted to carry",
    )
    assert_equal(
        JmAuthMode.none().name(),
        String("none"),
        "CONTROL: the `none` posture renders as a posture, not as empty",
    )
    assert_false(
        _contains(JmAuthMode.gcp_metadata().name(), seg_a),
        "CONTROL: name() carries no credential material",
    )
    print("  test_the_token_never_reaches_an_error_or_a_mode_name: PASS")


# =============================================================================
# ARM 7 — the PRODUCTION minter is a real conformer, constructible off GCP.
# =============================================================================
def test_the_gcp_minter_is_a_constructible_conformer() raises:
    """`GcpMetadataMinter` is a real `JmTokenMinter` the agent can hold.

    ⚠ CONSTRUCTION ONLY — NOTHING IS DIALLED. Proving it mints needs a metadata
    server, which is a host-bound rig; what this arm establishes is that the
    production conformer is a value `jm_auth_headers` accepts, which is the
    thing that did not compile before. ARM 4 covers the behaviour through the
    scripted conformer precisely so this one does not need a network."""
    var m = GcpMetadataMinter()
    _ = m^
    print("  test_the_gcp_minter_is_a_constructible_conformer: PASS")


# =============================================================================
# ARM 9 — (plaintext, credential) is refused where the agent's posture is
#         RESOLVED. The send-site half: `test_heartbeat_no_credential_in_clear`.
# =============================================================================
def _from_env_refusal() -> String:
    """`AgentConfig.from_env()`'s error text, or "" when it did not raise."""
    try:
        var _c = AgentConfig.from_env()
    except e:
        return String(e)
    return String("")


def test_from_env_refuses_a_credential_posture_over_plaintext() raises:
    """⛔ `AgentConfig.from_env` REFUSES (plaintext, gcp-metadata) AT BOOT, naming
    both variables. The send-time refusal (`test_heartbeat_no_credential_in_
    clear`) keeps the token off the wire; this one says so at the cause, once,
    instead of as a stream of refused beats.

    The variable names are the placement contract the job manager's pod render
    stamps (the constants above).

    RED before the fix: `from_env` accepted the pair and returned a config
    whose every beat would have minted and sent the token in the clear."""
    var scheme_var = String(AGENT_ENV_JM_SCHEME)
    var auth_var = String(AGENT_ENV_JM_AUTH)
    _required_agent_env()
    _unsetenv(String(AGENT_ENV_JM_PORT))
    _setenv(auth_var, String("gcp-metadata"))

    _setenv(scheme_var, String("http"))
    var explicit_http = _from_env_refusal()
    # An ABSENT scheme is plaintext too -- it is `from_env`'s own default.
    _unsetenv(scheme_var)
    var absent_scheme = _from_env_refusal()

    # CONTROL: https + gcp-metadata is the legal credential posture.
    _setenv(scheme_var, String("https"))
    var legal = _from_env_refusal()
    # CONTROL: plaintext with NO credential is unchanged.
    _setenv(scheme_var, String("http"))
    _unsetenv(auth_var)
    var plain = _from_env_refusal()
    # Clean up BEFORE asserting: a later arm reads the same process env.
    _unsetenv(scheme_var)

    assert_true(
        explicit_http.byte_length() > 0,
        "⛔ (scheme http, posture gcp-metadata) must be REFUSED at boot --"
        " every beat would mint an ID token and send it in the clear",
    )
    assert_true(
        absent_scheme.byte_length() > 0,
        "⛔ an ABSENT scheme is plaintext, so (absent, gcp-metadata) must be"
        " refused too",
    )
    assert_true(
        _contains(explicit_http, scheme_var)
        and _contains(explicit_http, auth_var),
        "the refusal names BOTH variables, since either one is the fix: "
        + explicit_http,
    )
    # …and the ABSENT-scheme arm is refused for the SAME reason. A byte-length
    # check alone is satisfied by any unrelated raise, which would leave this
    # arm unpinned without anyone noticing.
    assert_true(
        _contains(absent_scheme, String("PLAINTEXT"))
        and _contains(absent_scheme, scheme_var)
        and _contains(absent_scheme, auth_var),
        "(absent scheme, gcp-metadata) is refused as a credential over"
        " PLAINTEXT, naming both variables: " + absent_scheme,
    )
    assert_equal(
        legal,
        String(""),
        "CONTROL: (https, gcp-metadata) is accepted",
    )
    assert_equal(
        plain,
        String(""),
        "CONTROL: (http, none) is accepted -- the in-cluster posture is"
        " unchanged",
    )
    print(
        "  test_from_env_refuses_a_credential_posture_over_plaintext: PASS"
    )


def main() raises:
    print("test_agent_jm_auth_seam:")
    test_jm_audience_omits_the_default_port()
    test_jm_auth_posture_is_a_closed_set()
    test_https_with_no_port_defaults_to_443()
    test_the_posture_and_audience_come_off_the_placement_env()
    test_the_bearer_reaches_the_serialized_request()
    test_a_mint_failure_refuses_rather_than_sending_bearer_less()
    test_the_token_never_reaches_an_error_or_a_mode_name()
    test_the_gcp_minter_is_a_constructible_conformer()
    test_from_env_refuses_a_credential_posture_over_plaintext()
    print("test_agent_jm_auth_seam: ALL PASS")
