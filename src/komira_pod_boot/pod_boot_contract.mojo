# =============================================================================
# komira_pod_boot/pod_boot_contract.mojo — THE ONE PLACE the VM-boot contract
#   between a PLACEMENT CONFORMER and the ON-VM POD LOADER is spelled.
# =============================================================================
#
# ★ WHY THIS FILE EXISTS, AND WHY IT IS HERE AND NOT IN A CLOUD BRIDGE.
#
# Booting a job onto a bare VM is a hand-off between two programs that never
# link against each other and never run on the same machine:
#
#   the PLACEMENT CONFORMER                      the ON-VM POD LOADER
#   (the GCE conformer / Ec2VmPodManager)
#            |                                        ^
#            |  renders a boot script that EXPORTS ...|... which the loader READS
#            +----------------------------------------+
#
# The hand-off is a set of ENVIRONMENT VARIABLE NAMES. Nothing type-checks it: a
# conformer that exports one spelling of the heartbeat-host name while the
# loader reads another compiles, deploys, boots, and reports a job that never
# heartbeats — because instance-state polling still notices the machine going
# away, the job even looks finished.
#
# ⛔ SO THE NAMES ARE DECLARED **ONCE**, HERE, AND EVERY SIDE IMPORTS THEM.
#   Adding a second spelling for one of these concepts is the defect, not the
#   fix. If a name must change, change it here — the renderers and the reader
#   move together or the build breaks.
#
# ⛔ AND THE HOME IS A PACKAGE OF ITS OWN: a CLOUD BRIDGE would make the AWS
#   boot path import a package named after the other cloud. This library's
#   `deps` is the whole dep closure: `komira_placement` and `komira_k8s`.
#
# ⚠ THE CHANNEL. Today the boot script writes these values (from EC2 user-data,
#   or from GCE instance metadata) into the process environment of the loader
#   binary it `exec`s, and the loader takes no argv. That channel belongs to
#   the loader, not to this library, which only names the values; moving them
#   to flags is a change to the loader and both renderers together. While the
#   channel is an environment, absent and empty are the same bytes, so the
#   loader must RAISE on an empty pod spec rather than boot a VM that runs
#   nothing.
# =============================================================================

from komira_k8s.k8s_types import EnvVar

from komira_placement.compose_renderer import (
    ComposePodSpec,
    ComposeService,
    ComposePortMapping,
)



# -----------------------------------------------------------------------------
# §1 — the core environment variable names. The contract.
#
# ⚠ `StaticString`, NOT `String`, and that is load-bearing: the loader's
# environment reader takes a `StaticString`, so a `String` here would force every reader to
# launder the name through a conversion — and a name you have to convert is a
# name somebody eventually retypes as a literal. Build a String from it
# (`String(ENV_JOB_ID)`) at the few sites that CONCATENATE.
# -----------------------------------------------------------------------------

comptime ENV_POD_SPEC_JSON: StaticString = "KOMIRA_POD_SPEC_JSON"
"""The serialized `ComposePodSpec` (ALL N containers). REQUIRED — a boot with
this unset or empty is a REFUSAL, never a VM that idles and bills."""

comptime ENV_HEARTBEAT_HOST: StaticString = "KOMIRA_HEARTBEAT_HOST"
"""The job manager's in-VPC callback `host` or `host:port`. REQUIRED in
practice: a loader with no heartbeat target runs the workload and tells nobody,
which is the failure mode that made this whole gap invisible."""

comptime ENV_JOB_ID: StaticString = "KOMIRA_JOB_ID"
"""The job row id every heartbeat is stamped with. The job manager looks the row
up BY THIS VALUE, so a placement that boots without it heartbeats into a 404."""

comptime ENV_POD_NAME: StaticString = "KOMIRA_POD_NAME"
"""This placement's unit name, echoed on the heartbeat so the job row records
which pod reported."""

comptime ENV_TASK_TIMEOUT_S: StaticString = "KOMIRA_TASK_TIMEOUT_S"
"""★★ THE JOB'S OWN DECLARED MAX RUNTIME, IN SECONDS — the fifth name, and the
ONLY OPTIONAL one. EMPTY / UNSET means **NO DEADLINE**, which is the correct and
intended reading for a streaming or otherwise infinite job; a positive integer
means the job declared it should be finished by then and the loader tears the
pod down and reports FAILED once it is not.

⛔ IT IS A HANG SAFETY-NET, NOT A SCHEDULING KNOB, AND IT MAY NOT BE DEFAULTED
TO A CONSTANT. As `PlacementSpec.task_timeout_s` states, the deadline has to
come from the step's own declared need, never from a constant, because a
deadline shorter than the work kills a healthy job MID-RUN and reports it as a failure of the customer's code, and a
SIGKILL runs no cleanup. So `None` propagates as EMPTY here and nothing invents
a number for it.

⛔ AND IT IS THE **ONLY** RUN CAP AWS HAS. EC2 `RunInstances` carries no
per-instance wall-clock cap (GCE's `scheduling.maxRunDuration` has no EC2
equivalent — an EC2 run cap is an out-of-band EventBridge/Lambda reaper holding
its own state, which is a second thing to leak). The loader-side deadline is
therefore the PORTABLE mechanism: ONE implementation in the ONE supervisor both
clouds run. On GCE it is additionally backstopped platform-side by
`Scheduling.max_run_duration`, which survives the supervisor dying — the guest
deadline cannot bound a guest that never started."""


# -----------------------------------------------------------------------------
# §1b — THE SIXTH AND SEVENTH NAMES: HOW to reach the callback, not WHERE.
#
# ⛔⛔ WHY THEY EXIST. `ENV_HEARTBEAT_HOST` says WHERE the job manager is and
# NOTHING about how to talk to it. A loader that fills in the missing half by
# hard-coding it (plain HTTP on 8088, no credential) cannot reach a job manager
# served as an HTTPS-only service on 443 behind an invoker role: its beats never
# reach the wire at all — not a 403, not a 404.
#
# These two names are the boot-contract spelling, for the on-VM loader, of the
# transport and credential decisions `komira_agent`'s `AgentConfig` makes for an
# agent (`jm_uses_tls()` / `jm_auth_mode` / `jm_auth_audience()`). The AUDIENCE
# is DERIVED by the loader from the resolved target rather than carried.
# -----------------------------------------------------------------------------

comptime ENV_HEARTBEAT_SCHEME: StaticString = "KOMIRA_HEARTBEAT_SCHEME"
"""`http` or `https` — the TRANSPORT half of the callback, and with it the
DEFAULT PORT. EMPTY means `http`, which is byte-identical to every placement
made before this name existed.

⛔ IT SELECTS THE PORT AS WELL AS THE SCHEME, AND SEPARATING THEM IS THE BUG
THIS NAME EXISTS TO PREVENT. A correctly `https`-schemed caller that goes on
defaulting to its plaintext port dials `https://host:8081` while the service
listens on 443: the transport decision LOOKS right in every log line and the
connection goes nowhere. `resolve_heartbeat_target` therefore owns both, in one
function, over both inputs.

⚠ AN UNRECOGNISED VALUE IS **REFUSED**, NOT COERCED TO PLAINTEXT. A typo'd
`htps` silently coerced would dial in the clear at a TLS port and report an
ordinary transport error forever. That refusal is about a MALFORMED CONTRACT —
the `ENV_POD_SPEC_JSON` class — and is NOT the same thing as refusing to start
because the job manager is unreachable, which this loader must never do."""

comptime ENV_HEARTBEAT_AUTH: StaticString = "KOMIRA_HEARTBEAT_AUTH"
"""The DECLARED credential posture for the callback: EMPTY (no credential, the
default) or `gcp-metadata` (a Google-signed OIDC ID token
minted off the instance metadata server, audience = the JM's own service URL).
The spellings are `komira_agent.jm_auth.parse_jm_auth_mode`'s, which is also the
parser — one vocabulary, one reader.

⛔ DECLARED, NEVER DERIVED FROM THE SCHEME, the same rule `komira_agent`
applies, repeated at the boot contract: an `https` job manager
reached from an EC2 instance has no GCP metadata server, so a fail-closed derive
would red every AWS beat and a fail-open one would send it bearer-less into a
403 — re-creating exactly the never-beat-at-all / beat-then-stopped ambiguity
this channel exists to remove.

⚠ A TYPO RAISES rather than degrading to no-credential, for the same reason
`AgentConfig` refuses one: a misspelled posture that silently fell back would
beat bearer-less into a 403 forever while every log line said the loader was
healthy."""


# -----------------------------------------------------------------------------
# §2 — GCE's transport of the same values: instance METADATA keys.
#
# GCE has no user-data channel, so the values ride as custom metadata attributes
# and the startup script curls them into the environment. The key names are
# GCP's transport of the contract above, so they are declared beside it — one
# file to read to know what a booting GCE VM is told.
#
# (EC2 needs no equivalent: cloud-init user-data IS the script, so the AWS
# renderer exports the §1 names directly.)
# -----------------------------------------------------------------------------

comptime GCE_META_POD_SPEC: String = "komira-pod-spec"
comptime GCE_META_HEARTBEAT_HOST: String = "komira-heartbeat-host"
comptime GCE_META_JOB_ID: String = "komira-job-id"
comptime GCE_META_POD_NAME: String = "komira-pod-name"
comptime GCE_META_TASK_TIMEOUT_S: String = "komira-task-timeout-s"
"""⚠ ALWAYS STAMPED, EMPTY WHEN THERE IS NO DEADLINE — never omitted. GCE's
metadata endpoint answers **404 with a body** for an absent attribute and the
startup script's fetch is a plain `curl -s`, so an omitted key does not export
an empty value: it exports the 404's TEXT, which the loader would then have to
either reject (a VM that refuses to boot and reports nothing) or silently read
as no-deadline. Stamping the key unconditionally makes absent-vs-empty a
question the wire never asks."""

comptime GCE_META_HEARTBEAT_SCHEME: String = "komira-heartbeat-scheme"
"""The GCE transport of `ENV_HEARTBEAT_SCHEME`. The GCE conformer ALWAYS
stamps it (`http` or `https`, resolved at placement), and the startup
script fetches it with the OPTIONAL form — `curl -sf … || true` — so an absent
key exports EMPTY (= `http`) rather than the 404's body.

⛔ THE OPTIONAL FETCH HAS ONE LIVE COST. A TRANSIENT metadata-server failure
also exports EMPTY, which downgrades a stamped `https` to plaintext at the
stamped port. That downgraded dial is NOT merely a lost beat: the POSTURE is
fetched separately and survives, so a sender that mints whenever the posture is
not `none` would put a Google-signed ID token in the `Authorization` header of
a plaintext HTTP request.

Three things hold against it: the fetch retries transient failures (`--retry 5
--retry-connrefused`, so a blip rarely becomes EMPTY); the loader REFUSES
(plaintext, credential) at boot, naming this key; and the heartbeat sender
refuses the pair per beat before the mint and before the dial. If the downgrade
still happens, the VM refuses to supervise and says why -- a lost job, loudly,
never a leaked token."""

comptime GCE_META_HEARTBEAT_AUTH: String = "komira-heartbeat-auth"
"""The GCE transport of `ENV_HEARTBEAT_AUTH`. ALWAYS stamped by the GCE
conformer — EMPTY when there is no credential — and fetched,
like the scheme above, with the OPTIONAL `curl -sf … || true` form: an absent
key (or a transient metadata failure) exports EMPTY, i.e. NO credential, rather
than the 404's TEXT, which `parse_jm_auth_mode` would refuse and turn into a VM
that boots and refuses to supervise.

⛔ THE POSTURE IS VALIDATED AT PLACEMENT, NOT FIRST ON THE VM. The GCE
conformer runs the same `parse_jm_auth_mode` over the value before any cloud
call, so a typo (`gcp_metadata`, `none`) is refused while it
still costs a no-op instead of an instance that bills until its run cap."""


# -----------------------------------------------------------------------------
# §2b — the SCHEME vocabulary and the two default ports it selects between.
# -----------------------------------------------------------------------------

comptime HEARTBEAT_SCHEME_HTTP: String = "http"
comptime HEARTBEAT_SCHEME_HTTPS: String = "https"

comptime DEFAULT_HEARTBEAT_PORT_HTTP: Int = 8088
"""The in-cluster / in-VPC job manager's `/internal/heartbeat` listener. This is
the value the loader defaulted to unconditionally before a scheme existed."""

comptime DEFAULT_HEARTBEAT_PORT_HTTPS: Int = 443
"""⛔ A TLS CALLBACK DEFAULTS HERE AND NOT TO 8088. A Cloud Run job manager's
only address is `https://<service>-<suffix>.run.app` — which carries NO port, so
a bare host arriving with `https` has to pick one, and picking the plaintext
listener's port produces a dial that goes nowhere while every log line reports a
correct TLS transport."""


struct HeartbeatTarget(Copyable, Movable, ImplicitlyCopyable):
    """WHERE the callback goes and HOW: a bare `host`, a resolved `port`, and the
    transport bit. Produced only by `resolve_heartbeat_target`, so the
    scheme-selects-the-port rule has exactly one implementation.

    Plain value fields (no pointer field); no pointer crosses this boundary."""

    var host: String
    var port: Int
    var use_tls: Bool

    def __init__(out self, var host: String, port: Int, use_tls: Bool):
        self.host = host^
        self.port = port
        self.use_tls = use_tls

    def scheme(self) -> String:
        """The scheme word this target dials with — the inverse of the parse,
        so an audience can be rendered without re-deriving the bit."""
        return (
            String(HEARTBEAT_SCHEME_HTTPS)
            if self.use_tls
            else String(HEARTBEAT_SCHEME_HTTP)
        )


def _sub(s: String, start: Int, end: Int) -> String:
    """The byte substring `s[start:end)`, rebuilt char-by-char. ⚠ NOT
    cosmetic: Mojo 1.0.0's `String` does not support the `s[a:b]` slice syntax,
    so every substring in this module goes through here.

    ⚠ ASCII-ONLY BY CONSTRUCTION: each byte is re-encoded as its own code point,
    so a multi-byte UTF-8 sequence would be garbled. Every split point in this
    module is an ASCII delimiter found by `find`/`rfind`, and a heartbeat host is
    a DNS name or an IP literal, so no caller here can reach that case."""
    var out = String("")
    var bytes = s.as_bytes()
    var lo = start
    if lo < 0:
        lo = 0
    var hi = end
    if hi > len(bytes):
        hi = len(bytes)
    for i in range(lo, hi):
        out += chr(Int(bytes[i]))
    return out^


def _is_all_digits(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return False
    return True


comptime _MAX_TCP_PORT: Int = 65535
"""The largest port a TCP dial can name. ⛔ Checked BEFORE the value reaches
`UInt16(...)` at the send site, where 70000 would otherwise wrap SILENTLY to
4464 — a dial at a port nobody configured, reported as an ordinary transport
error forever."""


def _malformed_heartbeat_host(raw_host: String, why: String) -> Error:
    """The ONE sentence every malformed-host refusal ends in, so the operator
    always sees the value, the variable it arrived in, and the accepted shapes."""
    return Error(
        String("pod boot contract: ")
        + String(ENV_HEARTBEAT_HOST)
        + String("='")
        + raw_host
        + String("' is malformed: ")
        + why
        + String(
            ". Accepted: a bare host, host:port with a port in 1..65535, or an"
            " http:// / https:// base URL (scheme matched case-insensitively)."
            " It is REFUSED rather than dialled as written: a value that cannot"
            " name an endpoint retries into nothing for the life of the"
            " placement, which is indistinguishable from a job manager that is"
            " merely down."
        )
    )


def resolve_heartbeat_target(
    raw_host: String, raw_scheme: String
) raises -> HeartbeatTarget:
    """Decode `ENV_HEARTBEAT_HOST` + `ENV_HEARTBEAT_SCHEME` into the one triple
    the loader dials: host, port, TLS-or-not.

    ★ ONE FUNCTION FOR BOTH, BECAUSE THE SCHEME SELECTS THE PORT. Splitting the
    two decisions across two call sites produces a correctly `https`-schemed
    dial at a plaintext port (see `ENV_HEARTBEAT_SCHEME`); that is the reason
    this is not two helpers.

    ⭐ `raw_host` MAY BE A FULL URL, AND THAT IS THE SHAPE THE REGISTRY HANDS
    BACK. The address a hosted job manager is reachable at is published as
    `https://<service>.example.com` — a base URL, not a host — so a caller that
    resolved it registry-first has a URL in hand and must not have to take it
    apart itself. A scheme in the URL and a non-empty `raw_scheme` that DISAGREE
    are REFUSED rather than one silently winning: two configured values that
    contradict each other mean somebody is reading a different one than they
    think, and the failure would be a dial at the wrong port.

    THE TABLE (there is no other outcome):

      raw_host             raw_scheme   -> outcome
      -------------------  -----------  ----------------------------------------
      `https://h`          "" | https   TLS, port 443 unless `h` carried `:port`
      `http://h`           "" | http    plaintext, port 8088 unless `h` carried
      `https://h`          http         ⛔ RAISE — the disagreement
      `http://h`           https        ⛔ RAISE — the disagreement
      `h`                  https        TLS, port 443 unless `h` carried `:port`
      `h`                  "" | http    plaintext, port 8088 unless `:port`
      (any)                anything else ⛔ RAISE — not a scheme
      `<other>://h`        (any)        ⛔ RAISE — not http/https (`htps://`,
                                          `grpc://`); NEVER glued into the host
      `https://` / `:8088` (any)        ⛔ RAISE — a URL/port with NO host
      `h:` / `h:abc`       (any)        ⛔ RAISE — a `:` that is not a port
      `h:0` / `h:70000`    (any)        ⛔ RAISE — outside 1..65535
      `a:b:80`             (any)        ⛔ RAISE — an unbracketed `:` in the host
                                          (an IPv6 literal must be `[..]:port`)
      `""`                 "" | http(s) EMPTY host, scheme-default port

    The URL prefix is matched CASE-INSENSITIVELY (`HTTPS://h` is TLS): RFC 3986
    schemes are case-insensitive, and a case-sensitive match would turn
    `HTTPS://h` into the host `HTTPS:` dialled in PLAINTEXT on 8088 — the exact
    silent coercion the scheme refusal below exists to prevent.

    ⚠ AN EMPTY `raw_host` IS **NOT** REFUSED HERE. "Is there a target at all" is
    answered at PLACEMENT (by the conformer, before the instance exists),
    deliberately and not in the supervisor: a
    supervisor that refuses to start because it cannot reach home KILLS THE
    WORKLOAD IT IS SUPERVISING. What this function refuses is a MALFORMED
    CONTRACT — the `ENV_POD_SPEC_JSON` class — never an unreachable one. A
    NON-empty `raw_host` that yields no host (`https://`, `:8088`) is malformed,
    not absent, and IS refused: the two are different statements, and only the
    first is "nobody configured this"."""
    var scheme_in = raw_scheme.lower()
    var host = raw_host
    var use_tls: Bool
    var scheme_from_url = String("")

    var lowered = raw_host.lower()
    if lowered.startswith(String("https://")):
        scheme_from_url = String(HEARTBEAT_SCHEME_HTTPS)
        host = _sub(host, 8, len(host.as_bytes()))
    elif lowered.startswith(String("http://")):
        scheme_from_url = String(HEARTBEAT_SCHEME_HTTP)
        host = _sub(host, 7, len(host.as_bytes()))

    # ⛔ ANY OTHER `<scheme>://` IS REFUSED, NEVER GLUED INTO THE HOST. Without
    # this, `htps://jm.x` slash-cuts to the host `htps:` and dials it in
    # plaintext — a typo'd scheme silently coerced, one layer below the
    # `raw_scheme` refusal that promises it never is. The test is on the FIRST
    # `/`: a `://` that starts the authority is a scheme; one inside a path is
    # not ours to judge (the path is cut off below).
    var sep = host.find(String("://"))
    var first_slash = host.find(String("/"))
    if sep >= 0 and first_slash == sep + 1:
        raise _malformed_heartbeat_host(
            raw_host,
            String("'")
            + _sub(host, 0, sep)
            + String(
                "://' is not a callback scheme (only http:// and https:// are)"
            ),
        )

    # A base URL may carry a trailing slash (or a path); the dial takes the
    # AUTHORITY only — `send_heartbeat` appends `/internal/heartbeat` itself.
    if first_slash >= 0:
        host = _sub(host, 0, first_slash)

    if scheme_from_url.byte_length() > 0:
        if (
            scheme_in.byte_length() > 0
            and scheme_in != scheme_from_url
        ):
            raise Error(
                String("pod boot contract: ")
                + String(ENV_HEARTBEAT_SCHEME)
                + String("='")
                + raw_scheme
                + String("' CONTRADICTS the scheme in ")
                + String(ENV_HEARTBEAT_HOST)
                + String("='")
                + raw_host
                + String(
                    "'. Two configured values that disagree mean somebody is"
                    " reading a different one than they think, and the result"
                    " would be a dial at the wrong port. Set one of them, or"
                    " set both to the same scheme."
                )
            )
        use_tls = scheme_from_url == String(HEARTBEAT_SCHEME_HTTPS)
    elif scheme_in.byte_length() == 0:
        # EMPTY => plaintext: byte-identical to every placement made before
        # `ENV_HEARTBEAT_SCHEME` existed.
        use_tls = False
    elif scheme_in == String(HEARTBEAT_SCHEME_HTTPS):
        use_tls = True
    elif scheme_in == String(HEARTBEAT_SCHEME_HTTP):
        use_tls = False
    else:
        raise Error(
            String("pod boot contract: ")
            + String(ENV_HEARTBEAT_SCHEME)
            + String("='")
            + raw_scheme
            + String(
                "' is not a scheme. It must be '"
            )
            + String(HEARTBEAT_SCHEME_HTTP)
            + String("', '")
            + String(HEARTBEAT_SCHEME_HTTPS)
            + String(
                "', or EMPTY (which means http). It is NOT coerced to"
                " plaintext: a typo'd scheme silently downgraded would dial in"
                " the clear at a TLS port and report an ordinary transport"
                " error forever."
            )
        )

    var port = (
        DEFAULT_HEARTBEAT_PORT_HTTPS if use_tls
        else DEFAULT_HEARTBEAT_PORT_HTTP
    )
    # An EXPLICIT `:port` in the authority always wins over the scheme default.
    # ⛔ A `:` THAT IS PRESENT IS A PORT OR A REFUSAL — never left in the host.
    # Keeping the colon of `h:abc` / `h:` in the host would dial a name that
    # cannot resolve. A `:` inside a bracketed IPv6 literal (`[::1]`) is not a
    # port separator, so only a `:` AFTER the last `]` is considered.
    var colon = host.rfind(String(":"))
    var close_bracket = host.rfind(String("]"))
    if colon >= 0 and colon > close_bracket:
        var maybe_port = _sub(host, colon + 1, len(host.as_bytes()))
        # The length bound runs BEFORE `atol`, so a digit run too long for an
        # `Int` is a refusal and never an overflow.
        if not _is_all_digits(maybe_port) or maybe_port.byte_length() > 5:
            raise _malformed_heartbeat_host(
                raw_host,
                String("the text after ':' ('")
                + maybe_port
                + String("') is not a port number"),
            )
        var explicit_port = atol(maybe_port)
        if explicit_port < 1 or explicit_port > _MAX_TCP_PORT:
            raise _malformed_heartbeat_host(
                raw_host,
                String("port ")
                + String(explicit_port)
                + String(" is outside 1..65535"),
            )
        port = explicit_port
        host = _sub(host, 0, colon)

    if host.find(String(":")) >= 0 and not host.startswith(String("[")):
        raise _malformed_heartbeat_host(
            raw_host,
            String("the host part '")
            + host
            + String(
                "' still contains ':' (an IPv6 literal must be bracketed,"
                " `[addr]:port`)"
            ),
        )

    if host.byte_length() == 0 and raw_host.byte_length() > 0:
        raise _malformed_heartbeat_host(
            raw_host,
            String(
                "it names no host (a URL or a ':port' with an empty authority"
                " is not the same statement as an unset value)"
            ),
        )

    return HeartbeatTarget(host^, port, use_tls)


def render_heartbeat_host(hb: HeartbeatTarget) -> String:
    """The WRITER half of `resolve_heartbeat_target`: the `ENV_HEARTBEAT_HOST`
    value a placement renderer stamps for a resolved target. Stamp it together
    with `hb.scheme()` as `ENV_HEARTBEAT_SCHEME`.

    ★ HOMED BESIDE THE READER, AND BOTH RENDERERS CALL IT. With the GCE
    renderer and the EC2 renderer (`build_vm_bootstrap`) each spelling
    `hb.host + ":" + port` inline, the writers' tests cover only the writers and
    the reader's tests cover only the reader, so no test feeds a writer's output
    back into the reader. The property that matters is
    `resolve_heartbeat_target(render_heartbeat_host(t), t.scheme()) == t` for
    every `t` the resolver accepts, and it can only be pinned once there is ONE
    writer to pin. `test_pod_boot_contract` pins it.

    ⛔ AN EMPTY HOST RENDERS EMPTY, NEVER `:<port>`. The reader tolerates an
    empty host ("no target"; the supervisor still runs the workload) but
    REFUSES `:8088` ("names no host"). The EC2 renderer reaches the empty case
    whenever the AWS job manager has no callback URL configured, which it
    tolerates on purpose (a VM job still runs and self-terminates). Rendering
    `:8088` there would make the loader raise at boot, so it would exit before
    starting anything and the VM would shut down having run nothing. The empty
    render carries no port, and none is lost: the reader
    gives an empty host the scheme's default port, which is the port it had."""
    if hb.host.byte_length() == 0:
        return String("")
    return hb.host + String(":") + String(hb.port)


# -----------------------------------------------------------------------------
# §3 — where the pod loader binary lives on a booted VM.
#
# Declared here for the same reason as the names above: the boot script that
# `exec`s this path and the image build that PUTS a binary there are in
# different packages on different clouds, and a path typo produces a VM that
# boots, finds nothing to exec, and bills.
# -----------------------------------------------------------------------------

comptime POD_LOADER_INSTALL_PATH: String = "/opt/komira/pod-loader-supervisor"
"""The absolute path a booted VM runs. The pod loader's boot bundle places the
binary here, mode 0755."""

comptime POD_LOADER_LIB_DIR: String = "/opt/mojo/lib"
"""⛔ THE `LD_LIBRARY_PATH` A BOOTED VM MUST SET, AND WHY "JUST FETCH THE BINARY"
IS NOT A DESIGN. A Mojo binary DT_NEEDs Mojo runtime shared objects
(`libKGENCompilerRTShared.so` and friends) that exist in NO distribution — so a
bare ELF dropped on a stock AMI or a stock Debian image cannot `execve` at all.

⇒ the boot artifact is a TARBALL — the binary at `POD_LOADER_INSTALL_PATH` plus
this directory's `.so` closure. Both clouds fetch and extract the SAME tarball;
neither bakes a machine image.

⚠ The path is `/opt/mojo/lib` and not `/opt/komira/lib` because that is where
the Mojo runtime libraries are staged in every shipped image; changing it here
alone would set `LD_LIBRARY_PATH` to an empty directory."""


def parse_task_timeout_s(raw: String) raises -> Optional[Int]:
    """Decode `ENV_TASK_TIMEOUT_S` / `GCE_META_TASK_TIMEOUT_S` into the loader's
    deadline. EMPTY (and only empty) => `None` => NO DEADLINE. Otherwise the
    value must be a run of ASCII digits denoting a POSITIVE number of seconds.

    ⛔ A NON-EMPTY VALUE THAT IS NOT A POSITIVE INTEGER IS A **REFUSAL**, NOT A
    `None`. The two are opposite failures and only one of them is silent: a
    value that arrived and could not be understood means somebody DID declare a
    deadline and the machine is about to run without one — and the reason the
    whole `komira_pod_boot` package exists is that a VM which runs the customer's
    workload while quietly disagreeing with the control plane bills by the hour
    and reports nothing. `"0"` is refused for the same reason it is not `None`:
    it is a legible number that would mean "already expired", i.e. a placement
    that can never do any work.

    ⚠ It also catches the 404-body case the GCE transport can produce
    (`GCE_META_TASK_TIMEOUT_S`) if the key is ever omitted — the refusal names
    the value it saw rather than merely that it was wrong."""
    if raw.byte_length() == 0:
        return Optional[Int]()
    var bytes = raw.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            raise Error(
                String("pod boot contract: ")
                + String(ENV_TASK_TIMEOUT_S)
                + String(" is not a positive integer number of seconds: '")
                + raw
                + String(
                    "'. Empty means NO DEADLINE; anything else must be digits."
                    " A value that arrived and could not be read means a"
                    " deadline WAS declared and this VM is about to run without"
                    " one."
                )
            )
    var secs = atol(raw)
    if secs <= 0:
        raise Error(
            String("pod boot contract: ")
            + String(ENV_TASK_TIMEOUT_S)
            + String("='")
            + raw
            + String(
                "' is not a POSITIVE number of seconds. A zero deadline is a"
                " placement that is expired before it starts; leave the value"
                " EMPTY to declare no deadline."
            )
        )
    return Optional[Int](secs)


def sh_quote(v: String) -> String:
    """Single-quote a value for a rendered VM boot script, POSIX-portably.

    ⛔ NOT COSMETIC, AND IT IS HOMED HERE BECAUSE BOTH RENDERERS NEED IT. A
    container image, an argv element, an env value or a bundle URL comes from a
    job row; an UNQUOTED one carrying a space silently splits into two shell
    words — a DIFFERENT command running as the customer's job. `Ec2VmPodManager.
    build_vm_bootstrap` (EC2 user-data) and the GCE startup-script renderer
    render two different scripts for the ONE boot contract this
    module declares, so a quoting rule that lived in one of them would be a
    correctness property only one cloud had.

    A single quote inside the value is closed, escaped and reopened (`'\\''`) —
    the only form that works in every POSIX shell, since a backslash does not
    escape inside single quotes."""
    var out = String("'")
    var b = v.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x27):  # a literal single quote
            out += String("'\\''")
        else:
            var one = List[UInt8]()
            one.append(b[i])
            out += String(unsafe_from_utf8=Span(one))
    out += String("'")
    return out^


# =============================================================================
# §4 — the WIRE FORM of the contract: the pod-spec JSON codec.
#
# ⛔ HOMED HERE, WITH THE NAMES, AND NOT IN A CLOUD BRIDGE. Both placement
# conformers SERIALIZE (into GCE metadata / EC2 user-data) and the pod loader
# DESERIALIZES, so the codec has three consumers across two clouds and one
# binary. In a cloud bridge it would make `komira_aws_bridge` import a package
# named after the other cloud.
#
# It serializes `ComposePodSpec` (from `komira_placement`) and `EnvVar` (from
# `komira_k8s`), the only two dependencies of this package.
# =============================================================================

def _json_escape(s: String) -> String:
    """Escape a String for embedding inside a JSON double-quoted string: `"` ->
    `\\"`, `\\` -> `\\\\`, and the control chars (newline / tab / carriage-return)
    -> their JSON escapes. Deterministic (snapshot-stable)."""
    var out = String("")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == UInt8(ord('"')):
            out += String('\\"')
        elif b == UInt8(ord("\\")):
            out += String("\\\\")
        elif b == UInt8(ord("\n")):
            out += String("\\n")
        elif b == UInt8(ord("\t")):
            out += String("\\t")
        elif b == UInt8(ord("\r")):
            out += String("\\r")
        else:
            out += chr(Int(b))
    return out^


def _json_unescape(s: String) -> String:
    """Inverse of `_json_escape` — decode a JSON-escaped string body back to its
    raw value (`\\"` -> `"`, `\\\\` -> `\\`, `\\n`/`\\t`/`\\r` -> the control char)."""
    var out = String("")
    var bytes = s.as_bytes()
    var i = 0
    var n = len(bytes)
    while i < n:
        var b = bytes[i]
        if b == UInt8(ord("\\")) and i + 1 < n:
            var nb = bytes[i + 1]
            if nb == UInt8(ord('"')):
                out += String('"')
            elif nb == UInt8(ord("\\")):
                out += String("\\")
            elif nb == UInt8(ord("n")):
                out += String("\n")
            elif nb == UInt8(ord("t")):
                out += String("\t")
            elif nb == UInt8(ord("r")):
                out += String("\r")
            else:
                out += chr(Int(nb))
            i += 2
        else:
            out += chr(Int(b))
            i += 1
    return out^


def _qstr(s: String) -> String:
    """A JSON-quoted, escaped string literal: `"<escaped>"`."""
    return String('"') + _json_escape(s) + String('"')


# =============================================================================
# §4a — serialize: ComposePodSpec -> the ENV_POD_SPEC_JSON value (the provider
# side).
# =============================================================================
def serialize_pod_spec_json(pod: ComposePodSpec) raises -> String:
    """Serialize a `ComposePodSpec` (ALL N services) to the `ENV_POD_SPEC_JSON`
    value the provider stamps (on GCE, as the `GCE_META_POD_SPEC` instance
    metadata). The shape:
        {"name":"<pod>","network":"<net>","services":[
           {"name":"<svc>","image":"<img>","command":["..."],
            "environment":[{"name":"<k>","value":"<v>"}],
            "ports":[{"name":"<p>","published":<int>,"target":<int>}]}, ...]}
    Every container is preserved (a converter that keeps only the first
    container would silently drop the rest). Deterministic
    (the services / command / env / ports are emitted in list order)."""
    var out = String("{")
    out += String('"name":') + _qstr(pod.name)
    out += String(',"network":') + _qstr(pod.network)
    out += String(',"services":[')
    for si in range(len(pod.services)):
        if si > 0:
            out += String(",")
        ref svc = pod.services[si]
        out += String("{")
        out += String('"name":') + _qstr(svc.name)
        out += String(',"image":') + _qstr(svc.image)
        # command[]
        out += String(',"command":[')
        for ci in range(len(svc.command)):
            if ci > 0:
                out += String(",")
            out += _qstr(svc.command[ci])
        out += String("]")
        # environment[{name,value}]
        out += String(',"environment":[')
        for ei in range(len(svc.environment)):
            if ei > 0:
                out += String(",")
            out += String('{"name":') + _qstr(svc.environment[ei].name)
            out += String(',"value":') + _qstr(svc.environment[ei].value)
            out += String("}")
        out += String("]")
        # ports[{name,published,target}]
        out += String(',"ports":[')
        for pi in range(len(svc.ports)):
            if pi > 0:
                out += String(",")
            ref p = svc.ports[pi]
            out += String('{"name":') + _qstr(p.name)
            out += String(',"published":') + String(p.published)
            out += String(',"target":') + String(p.target)
            out += String("}")
        out += String("]")
        out += String("}")
    out += String("]}")
    return out^


# =============================================================================
# §4b — a minimal recursive-descent JSON reader for the fixed pod-spec shape (the
# VM side). NOT a general JSON parser — it reads exactly the shape §4a emits.
# =============================================================================
struct _JsonReader(Movable):
    """A tiny cursor over the JSON bytes that reads exactly the fixed pod-spec
    shape §4a emits. Skips whitespace, reads quoted strings (un-escaping), integers,
    and the structural tokens. Raises on a shape mismatch (a malformed pod spec is
    a hard error the VM boot must fail on)."""

    var src: String
    var pos: Int
    var n: Int

    def __init__(out self, var src: String):
        self.n = len(src.as_bytes())
        self.src = src^
        self.pos = 0

    def _byte(self) -> Int:
        if self.pos >= self.n:
            return -1
        return Int(self.src.as_bytes()[self.pos])

    def _skip_ws(mut self):
        while self.pos < self.n:
            var b = Int(self.src.as_bytes()[self.pos])
            if b == ord(" ") or b == ord("\n") or b == ord("\t") or b == ord("\r"):
                self.pos += 1
            else:
                break

    def _expect(mut self, ch: Int) raises:
        self._skip_ws()
        if self._byte() != ch:
            raise Error(
                String("pod-spec JSON: expected '")
                + chr(ch)
                + String("' at byte ")
                + String(self.pos)
            )
        self.pos += 1

    def _peek(mut self) -> Int:
        self._skip_ws()
        return self._byte()

    def _read_string(mut self) raises -> String:
        """Read a JSON double-quoted string, un-escaping the body."""
        self._expect(ord('"'))
        var raw = String("")
        while self.pos < self.n:
            var b = Int(self.src.as_bytes()[self.pos])
            if b == ord("\\") and self.pos + 1 < self.n:
                # carry the escape pair verbatim into `raw`; _json_unescape decodes.
                raw += chr(b)
                raw += chr(Int(self.src.as_bytes()[self.pos + 1]))
                self.pos += 2
                continue
            if b == ord('"'):
                self.pos += 1
                return _json_unescape(raw)
            raw += chr(b)
            self.pos += 1
        raise Error(String("pod-spec JSON: unterminated string"))

    def _read_int(mut self) raises -> Int:
        self._skip_ws()
        var num = String("")
        if self._byte() == ord("-"):
            num += String("-")
            self.pos += 1
        var digits = 0
        while self.pos < self.n:
            var b = Int(self.src.as_bytes()[self.pos])
            if b >= ord("0") and b <= ord("9"):
                num += chr(b)
                digits += 1
                self.pos += 1
            else:
                break
        if digits == 0:
            raise Error(
                String("pod-spec JSON: expected integer at byte ")
                + String(self.pos)
            )
        return atol(num)

    def _read_key(mut self) raises -> String:
        """Read a `"key":` token, returning the key."""
        var key = self._read_string()
        self._expect(ord(":"))
        return key^


def deserialize_pod_spec_json(var json: String) raises -> ComposePodSpec:
    """Parse an `ENV_POD_SPEC_JSON` value (the shape §4a emits) back into a
    `ComposePodSpec` with ALL services preserved (the round-trip
    `test_pod_boot_contract` guards). The VM's pod loader calls this at boot.
    Raises on a malformed spec (a VM boot must fail loudly on a bad pod spec)."""
    var r = _JsonReader(json^)
    r._expect(ord("{"))
    var name = String("")
    var network = String("")
    # The fixed top-level keys come in order name, network, services (§4a), but we
    # read key-by-key defensively (order-independent at the object level).
    var pod_name_set = False
    var pod = ComposePodSpec(String(""), String(""))

    while True:
        var k = r._read_key()
        if k == String("name"):
            name = r._read_string()
            pod_name_set = True
        elif k == String("network"):
            network = r._read_string()
        elif k == String("services"):
            r._expect(ord("["))
            # rebuild `pod` now that name/network are known (they precede services
            # in §4a's emit order — pod_name_set guards a malformed early services).
            if not pod_name_set:
                raise Error(
                    String("pod-spec JSON: 'services' before 'name'/'network'")
                )
            pod = ComposePodSpec(name, network)
            if r._peek() != ord("]"):
                while True:
                    pod.services.append(_read_service(r))
                    if r._peek() == ord(","):
                        r._expect(ord(","))
                        continue
                    break
            r._expect(ord("]"))
        else:
            raise Error(
                String("pod-spec JSON: unexpected top-level key '") + k
                + String("'")
            )
        if r._peek() == ord(","):
            r._expect(ord(","))
            continue
        break
    r._expect(ord("}"))
    return pod^


def _read_service(mut r: _JsonReader) raises -> ComposeService:
    """Read one `{"name","image","command","environment","ports"}` service object."""
    r._expect(ord("{"))
    var name = String("")
    var image = String("")
    var command = List[String]()
    var environment = List[EnvVar]()
    var ports = List[ComposePortMapping]()
    while True:
        var k = r._read_key()
        if k == String("name"):
            name = r._read_string()
        elif k == String("image"):
            image = r._read_string()
        elif k == String("command"):
            r._expect(ord("["))
            if r._peek() != ord("]"):
                while True:
                    command.append(r._read_string())
                    if r._peek() == ord(","):
                        r._expect(ord(","))
                        continue
                    break
            r._expect(ord("]"))
        elif k == String("environment"):
            r._expect(ord("["))
            if r._peek() != ord("]"):
                while True:
                    environment.append(_read_env_entry(r))
                    if r._peek() == ord(","):
                        r._expect(ord(","))
                        continue
                    break
            r._expect(ord("]"))
        elif k == String("ports"):
            r._expect(ord("["))
            if r._peek() != ord("]"):
                while True:
                    ports.append(_read_port(r))
                    if r._peek() == ord(","):
                        r._expect(ord(","))
                        continue
                    break
            r._expect(ord("]"))
        else:
            raise Error(
                String("pod-spec JSON: unexpected service key '") + k + String("'")
            )
        if r._peek() == ord(","):
            r._expect(ord(","))
            continue
        break
    r._expect(ord("}"))
    var svc = ComposeService(name, image)
    svc.command = command^
    svc.environment = environment^
    svc.ports = ports^
    return svc^


def _read_env_entry(mut r: _JsonReader) raises -> EnvVar:
    """Read one `{"name","value"}` env object -> an EnvVar."""
    r._expect(ord("{"))
    var ename = String("")
    var evalue = String("")
    while True:
        var k = r._read_key()
        if k == String("name"):
            ename = r._read_string()
        elif k == String("value"):
            evalue = r._read_string()
        else:
            raise Error(
                String("pod-spec JSON: unexpected env key '") + k + String("'")
            )
        if r._peek() == ord(","):
            r._expect(ord(","))
            continue
        break
    r._expect(ord("}"))
    return EnvVar(ename, evalue)


def _read_port(mut r: _JsonReader) raises -> ComposePortMapping:
    """Read one `{"name","published","target"}` port object."""
    r._expect(ord("{"))
    var pname = String("")
    var published = 0
    var target = 0
    while True:
        var k = r._read_key()
        if k == String("name"):
            pname = r._read_string()
        elif k == String("published"):
            published = r._read_int()
        elif k == String("target"):
            target = r._read_int()
        else:
            raise Error(
                String("pod-spec JSON: unexpected port key '") + k + String("'")
            )
        if r._peek() == ord(","):
            r._expect(ord(","))
            continue
        break
    r._expect(ord("}"))
    return ComposePortMapping(pname, published, target)
