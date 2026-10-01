# =============================================================================
# src/komira_http/client/redirect_policy.mojo — the REDIRECT POLICY a
#   scriptable client shares: which statuses redirect, how a `Location`
#   resolves, how many hops are allowed, and which host a credential may reach.
# =============================================================================
#
# ⛔ THIS FILE IS POLICY, NOT A LOOP. There is no `send` in here and there must
# never be one. Every client that follows redirects keeps its OWN loop above its
# OWN transport seam (`OciCopier._follow_redirects` over `OciTransport`, the
# package-registry clients over theirs), because a redirect is protocol control
# flow and a loop buried under the seam cannot be SCRIPTED: the falsifier for a
# redirect is "queue a 302, queue the answer, assert over the conversation", and
# that needs the loop to be in the client the test drives. What those loops
# share — and what must not drift between them — is the handful of decisions
# below, so they live here, once.
#
# `RedirectLayer` (`redirect.mojo`, the `HttpService` middleware) is a
# DIFFERENT consumer with a different credential rule (RFC 6454 origin =
# scheme + host + port, stripped once and never re-attached) and its own
# `Url`-based `Location` parser. It shares only the status predicate.
#
# ─── THE CREDENTIAL RULE ────────────────────────────────────────────────────
# A credential is scoped to the host it was minted for. It is carried to a hop
# ONLY when that hop's host equals the ORIGINAL request's host — never merely the
# PREVIOUS hop's, which would let an `A -> B -> B` chain walk the credential onto
# B. That is why `carries_credential` takes the original host and has no
# parameter a previous hop could be passed through: the wrong comparison is not
# spellable. The rule is stated over the whole `Authorization` VALUE, so it
# holds identically for a registry bearer (`Bearer <token>`), Artifact
# Registry's `Basic oauth2accesstoken:<token>`, and an upload token.
#
# The host comparison is EXACT BYTES, deliberately. DNS names are
# case-insensitive, so `REGISTRY.example` and `registry.example` are one host;
# comparing them exactly withholds the credential from a hop that could have
# had it. That direction fails CLOSED — the hop answers 401 and says so — where
# a normalising comparison is a second parser that can disagree with the one
# that dials.
#
# ─── WHY THE LOCATION RESOLVER RETURNS DATA ─────────────────────────────────
# `resolve_redirect_location` never raises: every refusal is a KIND on the
# returned `RedirectTarget`. Each client renders its own refusal text in its own
# vocabulary ("the registry answered…", "the package index answered…"), and the
# policy — which shapes are followed, which are refused, how a host and a path
# split — stays one decision here.
#
# Encapsulation: owned `String` values across every boundary; no
# UnsafePointer, no wildcard origin, no `unsafe_from_address`.
# =============================================================================


# =============================================================================
# §1 — the hop budget and the status predicate.
# =============================================================================

# One hop is what Artifact Registry uses for a blob download; the budget exists
# so a server that loops (or a `Location` that points back at itself) fails
# with a diagnosis instead of hanging the caller forever.
comptime MAX_REDIRECT_HOPS: Int = 5


@always_inline
def is_redirect_status(status: Int) -> Bool:
    """True for the five HTTP statuses that mean "ask over there": 301, 302,
    303, 307, 308.

    300 (Multiple Choices), 304 (Not Modified) and 305/306 are NOT here: none of
    them names one URL to follow. The method-rewriting distinction between the
    five (303 turns a POST into a GET; 307/308 preserve the method) is the
    CALLER's to apply — a client that only ever follows GETs may treat all five
    alike."""
    return (
        status == 301
        or status == 302
        or status == 303
        or status == 307
        or status == 308
    )


# =============================================================================
# §2 — resolving a `Location`.
# =============================================================================

# The kinds `resolve_redirect_location` can answer. `RESOLVED` is the only kind
# with a host and a path to follow; every other kind is a REFUSAL, and the
# caller must not follow anything.
comptime REDIRECT_RESOLVED: Int = 0
comptime REDIRECT_REFUSED_NO_LOCATION: Int = 1
comptime REDIRECT_REFUSED_PLAINTEXT: Int = 2
comptime REDIRECT_REFUSED_NO_PATH: Int = 3
comptime REDIRECT_REFUSED_EMPTY_HOST: Int = 4
comptime REDIRECT_REFUSED_UNRESOLVABLE: Int = 5


struct RedirectTarget(Copyable, Movable, Deinitable):
    """Where a `Location` resolves to: the HOST to ask and the `/path?query` to
    ask it for — already separated, because a per-request-host transport needs
    them apart — or the reason it may not be followed.

    `host` and `path` are meaningful only when `kind == REDIRECT_RESOLVED`; on a
    refusal both are empty.

    Pointer safety: an Int and owned String fields only. No pointer field."""

    var kind: Int
    var host: String
    var path: String

    def __init__(out self, kind: Int, var host: String, var path: String):
        self.kind = kind
        self.host = host^
        self.path = path^

    def copy(self) -> Self:
        return RedirectTarget(self.kind, self.host.copy(), self.path.copy())

    def is_resolved(self) -> Bool:
        return self.kind == REDIRECT_RESOLVED


def _refused(kind: Int) -> RedirectTarget:
    return RedirectTarget(kind, String(""), String(""))


def resolve_redirect_location(
    current_host: String, location: String
) -> RedirectTarget:
    """Resolve a `Location` header value against the host that issued it.

    Three followed shapes and four refusals, each deliberate:
      * `https://host/path`  — absolute; the host changes.
      * `//host/path`        — scheme-relative; inherits HTTPS. Tested BEFORE
                               the absolute-path arm, because it also starts
                               with `/`, and treating it as a path would send
                               the request to the wrong host with a
                               right-looking URL.
      * `/path?query`        — absolute path on the SAME host (a container
                               registry's answer to a blob GET).
      * empty                — NO_LOCATION: there is no URL to follow.
      * `http://…`           — PLAINTEXT: following it would carry the
                               transfer, and possibly a credential, in the
                               clear; silently upgrading the scheme would be
                               inventing a URL the server did not name.
      * `https://host` with no path, or an empty host — NO_PATH / EMPTY_HOST: a
                               host root is not a resource, and defaulting it to
                               `/` would turn a malformed redirect into a
                               confident request for the wrong thing.
      * anything else        — UNRESOLVABLE. A path-relative `Location` is legal
                               HTTP, but resolving one wrongly produces a
                               confident request for the wrong object, so it is
                               refused rather than guessed. Scheme matching is
                               exact, so `HTTP://…` lands here too — refused,
                               never followed.

    Never raises: a refusal is a kind, not an exception (see the header)."""
    if location.byte_length() == 0:
        return _refused(REDIRECT_REFUSED_NO_LOCATION)
    if location.startswith(String("http://")):
        return _refused(REDIRECT_REFUSED_PLAINTEXT)
    if location.startswith(String("https://")):
        return _split_authority(String(location[byte=8:]))
    if location.startswith(String("//")):
        return _split_authority(String(location[byte=2:]))
    if location.startswith(String("/")):
        return RedirectTarget(
            REDIRECT_RESOLVED, current_host.copy(), location.copy()
        )
    return _refused(REDIRECT_REFUSED_UNRESOLVABLE)


def _split_authority(after_scheme: String) -> RedirectTarget:
    """Split `host/path…` into its host and its path (the path keeps its
    leading `/` and any query string)."""
    var slash = after_scheme.find(String("/"))
    if slash < 0:
        return _refused(REDIRECT_REFUSED_NO_PATH)
    if slash == 0:
        return _refused(REDIRECT_REFUSED_EMPTY_HOST)
    return RedirectTarget(
        REDIRECT_RESOLVED,
        String(after_scheme[byte=:slash]),
        String(after_scheme[byte=slash:]),
    )


# =============================================================================
# §3 — the credential rule.
# =============================================================================


def is_authorization_header(name: String) -> Bool:
    """True iff `name` is `Authorization`, compared ASCII-case-insensitively.

    A client's hop loop copies every header of the original request EXCEPT
    this one, and re-attaches the credential only where `carries_credential`
    says it may. The comparison ignores case because HTTP header names do: a
    client that dropped only the exact spelling it happens to write today
    would carry a differently-cased copy to every hop."""
    var want = String("authorization")
    if name.byte_length() != want.byte_length():
        return False
    var got_bytes = name.as_bytes()
    var want_bytes = want.as_bytes()
    for i in range(len(want_bytes)):
        var c = got_bytes[i]
        if c >= UInt8(65) and c <= UInt8(90):
            c += UInt8(32)
        if c != want_bytes[i]:
            return False
    return True


def carries_credential(original_host: String, hop_host: String) -> Bool:
    """True iff a credential minted for `original_host` may be sent to a hop
    whose host is `hop_host`.

    Compared against the ORIGINAL request's host, never the previous hop's —
    there is deliberately no parameter a previous hop could be passed through
    (see the header). Exact bytes: a case-variant of the same host is withheld
    the credential, which fails closed."""
    return hop_host == original_host


def authorization_for_hop(
    original_host: String, hop_host: String, authorization: String
) -> String:
    """The `Authorization` value a hop may carry: `authorization` itself when
    the hop is on the original host, EMPTY otherwise.

    The value is opaque here — `Bearer …`, `Basic …` and an upload token are
    all scoped the same way — and EMPTY means "send no `Authorization` header
    at all", never "send an empty one"."""
    if carries_credential(original_host, hop_host):
        return authorization.copy()
    return String("")
