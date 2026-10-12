# =============================================================================
# komira_test_issuer/transport.mojo: `IssuerTokenTransport`, a komira_oauth
#   `TokenEndpointTransport` that answers from a `TestIssuer`'s token
#   endpoint in process, so a `ClientCredentialSource` runs against the test
#   issuer with no socket.
# =============================================================================
#
# The transport owns the issuer; a test reaches it as `.issuer` (through the
# source's `transport()`) to move its clock, rotate its keys or remove a
# client. `post_form(url, form)` counts the request in `posts`, raises while
# `down` is set (a connection that fails), answers 404 with an empty body for
# any URL but the issuer's token endpoint, and otherwise returns
# `TestIssuer.token_request(form)`.
#
# ENCAPSULATION: values in and out; the issuer is a field the test owns
# through the transport. No pointer crosses this file's API.
# =============================================================================

from komira_oauth import TokenEndpointReply, TokenEndpointTransport

from komira_test_issuer.issuer import TestIssuer


struct IssuerTokenTransport(TokenEndpointTransport, Movable, Deinitable):
    """The test issuer's token endpoint as a transport (see the file
    header)."""

    var issuer: TestIssuer
    var posts: Int
    var down: Bool

    def __init__(out self, var issuer: TestIssuer):
        self.issuer = issuer^
        self.posts = 0
        self.down = False

    def post_form(mut self, url: String, form: String) raises -> TokenEndpointReply:
        """See the file header."""
        self.posts += 1
        if self.down:
            raise Error("IssuerTokenTransport: the connection failed")
        if url != self.issuer.token_endpoint_url():
            return TokenEndpointReply(404, String(""))
        return self.issuer.token_request(form)
