# =============================================================================
# komira_job_supervisor/heartbeat_auth.mojo: how a heartbeat authenticates.
# =============================================================================
#
# The heartbeat endpoint belongs to whoever runs the supervisor, and so does
# the way a request to it is authenticated. This file is the seam: a
# `HeartbeatAuth` conformer turns one outgoing request into the headers it
# must carry. The supervisor ships exactly one conformer, `NoHeartbeatAuth`
# (no credential); an embedding binary that needs a credential implements the
# trait itself and hands its conformer to `HttpHeartbeatReporter`.
#
# WHY THE SEAM RETURNS HEADERS, NOT A TOKEN. A bearer token is one header, but
# a request-signing scheme signs the method, the target and the body and emits
# several. `headers` takes all three, so either shape is one conformer with no
# change to the caller.
#
# THE RULES EVERY CONFORMER IS HELD TO:
#   * a failure RAISES; it never returns an empty list. Sending the beat
#     without the credential the operator asked for would be refused at the
#     endpoint and look like a network failure, and "cannot authenticate"
#     must not share a code path with "the network blipped";
#   * a raised Error never carries the credential, nor any part of it;
#   * `attaches_credential()` is True iff `headers` can return credential
#     material. A credential never travels over plaintext: the HTTP reporter
#     refuses that pair when it is built and again before every beat, before
#     `headers` is called and before anything is dialled.
#
# ENCAPSULATION: value-typed surface (String and List[UInt8] in,
# List[HeaderEntry] out). No pointer type crosses this boundary.
# =============================================================================

from komira_http_client.header_map import HeaderEntry


trait HeartbeatAuth(Movable, Deinitable):
    """Produces the authentication headers for one heartbeat request."""

    def name(self) -> String:
        """A short name for this scheme, for log lines and refusals. Never
        credential material."""
        ...

    def attaches_credential(self) -> Bool:
        """True iff `headers` can return credential material, which must
        then never travel over plaintext."""
        ...

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        """The headers for one request: `method` (e.g. "POST"), the full
        endpoint `url`, and the exact request `body`. RAISES on failure; the
        Error never carries the credential."""
        ...


struct NoHeartbeatAuth(HeartbeatAuth):
    """No credential: every request goes out with no authentication header.
    The default, for an endpoint the network itself protects."""

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("none")

    def attaches_credential(self) -> Bool:
        return False

    def headers(
        mut self, method: String, url: String, body: List[UInt8]
    ) raises -> List[HeaderEntry]:
        _ = method
        _ = url
        _ = len(body)
        return List[HeaderEntry]()


def credential_rides_in_clear[A: HeartbeatAuth](use_tls: Bool, auth: A) -> Bool:
    """True iff `auth` would attach a credential to a request that goes out in
    PLAINTEXT: the one (transport, auth) pair that is never allowed. Every
    refusal of the pair asks this, so the refusals cannot disagree."""
    return (not use_tls) and auth.attaches_credential()
