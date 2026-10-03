# =============================================================================
# komira_k8s/k8s_config.mojo — in-cluster config loader (token + CA + host)
# =============================================================================
#
# Load the service-account bearer token, the cluster CA cert, and the namespace
# from the canonical pod paths. The apiserver host and port are PARAMETERS:
# the caller supplies them (a binary takes them as command-line flags set by
# whoever deploys it); this library reads no environment variables.
#   (1) TOKEN REFRESH — modern K8s SA tokens are short-lived PROJECTED tokens
#       (kubelet rotates the file, default ~1h). A long-lived control-plane
#       client MUST re-read SA_DIR/token before each request. `read_token()`
#       does exactly that (cheap ~1 KB read); the cached token in the config is
#       only the bootstrap value.
#   (2) REAL FILE IO — file reads go through the stdlib `open()` context
#       manager (`_read_file_str`), returning an owned String. A hand-rolled
#       `external_call["open"]` would collide with the stdlib `open` builtin
#       signature in a consumer TU. No UnsafePointer crosses the module
#       boundary.
#
# UAF discipline: every byte->String conversion goes through
# `owned_utf8_string` (an owning copy), NEVER a form that can BORROW a dropping
# local's heap buffer and dangle. The token / CA / namespace are read off LOCAL
# byte lists that drop at function return, so this matters here.
# =============================================================================

from komira_http_client.auth import BearerTokenSource

from komira_k8s.k8s_text import strip_trailing_ws


# The canonical in-pod service-account directory. Production reads bare names
# (token / ca.crt / namespace) under here; tests point a custom dir at fixtures.
comptime SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


# -----------------------------------------------------------------------------
# _read_file_str — read a whole file into an owned String via stdlib open().
# -----------------------------------------------------------------------------
def _read_file_str(path: String) raises -> String:
    """Read the whole file at `path` into an owned `String` via the stdlib
    `open()` context manager + `.read()`.

    We use stdlib `open()` rather than a hand-rolled `external_call["open"]`:
    the latter's `open`/`read`/`close` FFI declarations
    collide with the stdlib's `open` builtin signature when both are in scope
    in a consumer TU, failing to lower ('existing function with conflicting
    signature'). stdlib `open().read()` is the encapsulated file-read primitive
    — no UnsafePointer crosses any boundary; the return is an owned String.

    Note: `.read()` already returns an owned String, so no extra
    owned_utf8_string copy is needed here (that helper is for the byte->String
    seams in k8s_tls / k8s_text where a dropping local would dangle)."""
    with open(path, "r") as f:
        return f.read()


# -----------------------------------------------------------------------------
# _parse_apiserver_url — split "https://host[:port]" into (host, port).
# -----------------------------------------------------------------------------
def _parse_apiserver_url(url: String) raises -> Tuple[String, String]:
    """Parse an apiserver base URL `https://host[:port][/...]` into `(host,
    port)`. The apiserver is always TLS, so a non-`https://` scheme (or a
    missing scheme) is rejected. The port defaults to `"443"` when omitted. Any
    trailing path / slash after the authority is dropped (the K8s base is just
    the authority — paths are appended by the client's path builders).

    No URL library / regex — a small hand scan over an ASCII String. Returns
    owned Strings; no borrowed slice escapes (UAF discipline)."""
    var scheme = String("https://")
    var sb = scheme.as_bytes()
    var ub = url.as_bytes()
    var n = len(ub)
    # Require the exact `https://` prefix.
    var ok = n >= len(sb)
    if ok:
        for i in range(len(sb)):
            if ub[i] != sb[i]:
                ok = False
                break
    if not ok:
        raise Error(
            "k8s_config.from_explicit: apiserver URL must start with"
            " 'https://' (got '" + url + "'); the apiserver is always TLS"
        )
    # Authority runs from after the scheme to the first '/' (or end).
    var start = len(sb)
    var end = start
    while end < n and ub[end] != UInt8(ord("/")):
        end += 1
    # Split the authority on the LAST ':' (none => default port).
    var colon = -1
    var j = start
    while j < end:
        if ub[j] == UInt8(ord(":")):
            colon = j
        j += 1
    var host = String("")
    var port = String("443")
    if colon < 0:
        for k in range(start, end):
            host += chr(Int(ub[k]))
    else:
        for k in range(start, colon):
            host += chr(Int(ub[k]))
        var p = String("")
        for k in range(colon + 1, end):
            p += chr(Int(ub[k]))
        if p.byte_length() > 0:
            port = p
    if host.byte_length() == 0:
        raise Error(
            "k8s_config.from_explicit: apiserver URL has no host: '" + url + "'"
        )
    return (host^, port^)


# =============================================================================
# InClusterConfig — the loaded config: CA + namespace + apiserver host/port,
# plus the SA directory so the token can be RE-READ per request (rotation).
# =============================================================================
struct InClusterConfig(Copyable, Movable):
    """The in-cluster K8s config. `token` is the bootstrap SA token read at
    load time; production re-reads it per request via `read_token()` (the
    projected token rotates). `ca_pem` / `namespace` / apiserver host+port are
    stable for the pod's lifetime.

    `sa_dir` + the bare filenames are retained so `read_token()` can re-read
    the live token file. In a real pod, `sa_dir = SA_DIR` and `token_file =
    "token"`; tests point them at fixtures with their own names."""

    var token: String
    var ca_pem: String
    var namespace: String
    var apiserver_host: String
    var apiserver_port: String
    var sa_dir: String
    var token_filename: String

    def __init__(out self):
        self.token = String("")
        self.ca_pem = String("")
        self.namespace = String("")
        self.apiserver_host = String("")
        self.apiserver_port = String("")
        self.sa_dir = String("")
        self.token_filename = String("token")

    def apiserver_base_url(self) -> String:
        """Https://<host>:<port> — the apiserver base for all requests."""
        return (
            String("https://")
            + self.apiserver_host
            + ":"
            + self.apiserver_port
        )

    def apiserver_port_u16(self) raises -> UInt16:
        var p = atol(self.apiserver_port)
        if p <= 0 or p > 65535:
            raise Error(
                "k8s_config: invalid apiserver port '" + self.apiserver_port
                + "'"
            )
        return UInt16(p)

    def read_token(self) raises -> String:
        """Re-read the live SA token file (projected-token rotation).
        Cheap ~1 KB read; the simplest correct refresh strategy (no TTL
        parsing). Falls back to the cached bootstrap token if the path is
        empty (e.g. a test that didn't supply an sa_dir)."""
        if self.sa_dir.byte_length() == 0:
            return self.token
        var p = self.sa_dir + "/" + self.token_filename
        return strip_trailing_ws(_read_file_str(p))

    def token_source(self) -> K8sTokenSource:
        """A `BearerTokenSource` (komira_http auth seam) that re-reads THIS
        config's SA token per request. Pass into a
        `BearerTokenProvider[K8sTokenSource]` to drive the pluggable auth seam
        with projected-token rotation.

        For an out-of-cluster config (`from_explicit`, empty `sa_dir`), the
        `K8sTokenSource` has no file to re-read and returns the in-memory
        bootstrap token on every call (a STATIC source) — the rotation path is
        unchanged for the in-cluster case (non-empty `sa_dir`)."""
        return K8sTokenSource(
            self.sa_dir, self.token_filename, self.token
        )

    @staticmethod
    def from_explicit(
        apiserver_url: String, ca_pem: String, token: String
    ) raises -> InClusterConfig:
        """Build a config from EXPLICIT values (the out-of-cluster / dev-host
        path — e.g. a `kind` cluster reached from the host). No pod filesystem,
        no kubeconfig YAML parsing (Mojo has no YAML parser; the harness extracts
        the three values from kubeconfig via `kubectl` / `kind get kubeconfig`).

        `apiserver_url` is `https://host[:port]` — parsed into host + port
        (default 443 when the port is omitted; a non-`https://` scheme is
        rejected — the apiserver is always TLS). `ca_pem` pins the cluster CA
        (the kind CA that signed the apiserver cert). `token` is a STATIC SA
        bearer token held in memory: `sa_dir` is left empty so `read_token()` /
        `token_source()` return this token verbatim on every request (no file
        re-read). The in-cluster projected-token ROTATION path is untouched —
        it is keyed on a non-empty `sa_dir`, which only the in-pod loaders set.

        Returns the same `InClusterConfig` surface `K8sPodClient` already
        consumes (apiserver_host / apiserver_port_u16() / ca_pem /
        token_source() / read_token()), so the client needs zero change. The
        SNI / cert-verify override lives on `K8sPodClient.__init__`."""
        var host: String
        var port: String
        host, port = _parse_apiserver_url(apiserver_url)
        var cfg = InClusterConfig()
        cfg.apiserver_host = host
        cfg.apiserver_port = port
        cfg.ca_pem = ca_pem
        cfg.token = token
        cfg.namespace = String("default")
        # sa_dir stays "" => read_token() / token_source() return the static
        # in-memory token (no file re-read). Rotation path is in-cluster only.
        cfg.sa_dir = String("")
        return cfg^


# =============================================================================
# K8sTokenSource — the projected-SA-token `BearerTokenSource` (rotation).
# =============================================================================
struct K8sTokenSource(BearerTokenSource, Copyable, Movable):
    """Conforms to komira_http's `BearerTokenSource`: `fetch_token()` re-reads
    the live SA token file on EVERY call, so a `BearerTokenProvider` built over
    it picks up a rotated projected token automatically (no provider-side
    cache). Falls back to the cached bootstrap token when `sa_dir` is empty
    (off-cluster tests with a fixed token).

    POD-ish: three owned Strings (sa_dir / token_filename / bootstrap fallback).
    No byte-slab, no wildcard origin."""

    var _sa_dir: String
    var _token_filename: String
    var _bootstrap: String

    def __init__(
        out self, sa_dir: String, token_filename: String, bootstrap: String
    ):
        self._sa_dir = sa_dir
        self._token_filename = token_filename
        self._bootstrap = bootstrap

    def fetch_token(self) raises -> String:
        """Re-read the live SA token (rotation) or return the bootstrap token if
        no sa_dir was configured. Owned String — no dangling slice escapes."""
        if self._sa_dir.byte_length() == 0:
            return self._bootstrap
        var p = self._sa_dir + "/" + self._token_filename
        return strip_trailing_ws(_read_file_str(p))


# =============================================================================
# Loaders.
# =============================================================================
def load_in_cluster_config(
    apiserver_host: String, apiserver_port: String
) raises -> InClusterConfig:
    """Production loader — read token + ca.crt + namespace from SA_DIR. This is
    the in-pod path.

    `apiserver_host` / `apiserver_port` are the in-cluster apiserver address
    (inside a pod, the values Kubernetes publishes as the service host and
    port). The caller passes them explicitly — a binary takes them as
    command-line flags — so this loader reads no environment."""
    return load_in_cluster_config_from(
        SA_DIR,
        String("token"),
        String("ca.crt"),
        String("namespace"),
        apiserver_host,
        apiserver_port,
    )


def load_in_cluster_config_from(
    sa_dir: String,
    token_filename: String,
    ca_filename: String,
    ns_filename: String,
    host: String,
    port: String,
) raises -> InClusterConfig:
    """Loader with explicit paths + host/port. Production calls
    `load_in_cluster_config(host, port)` (canonical pod paths). Tests call this
    with fixture filenames so the loader runs off-cluster.

    Re-reads happen via `read_token()`; this populates the bootstrap snapshot."""
    var cfg = InClusterConfig()
    cfg.sa_dir = sa_dir
    cfg.token_filename = token_filename
    cfg.token = strip_trailing_ws(_read_file_str(sa_dir + "/" + token_filename))
    cfg.ca_pem = _read_file_str(sa_dir + "/" + ca_filename)
    cfg.namespace = strip_trailing_ws(
        _read_file_str(sa_dir + "/" + ns_filename)
    )
    cfg.apiserver_host = host
    cfg.apiserver_port = port
    if cfg.namespace.byte_length() == 0:
        cfg.namespace = String("default")
    return cfg^
