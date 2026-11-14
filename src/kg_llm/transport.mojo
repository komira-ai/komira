# =============================================================================
# transport -- the two network seams: post a JSON body, get the body back.
# =============================================================================
#
# A model client builds a request body and parses a response body; it does not
# touch the network. A transport carries the bytes: it posts the body to an
# address and returns what the server answered. Where the address is, which
# path the request goes to, which header carries the credential and how long to
# wait are all configuration of the conformer, not arguments of the call, so a
# client never sees them.
#
# There are two traits because the two endpoints differ (a chat model and an
# embedding model are separate services with separate paths), not because their
# shape differs. The conformers over HTTP are in `http_transport`; the scripted
# ones used by tests are in `scripted_transport`.
#
# A transport raises when the server did not answer with a success status, when
# the answer was cut short, longer than the bound it was given, or not UTF-8
# text. It does not retry: a failed call is one failed call, and the caller
# decides whether to ask again.
# =============================================================================


trait ChatTransport(Movable, Deinitable):
    """Post a chat-completions request body, return the response body.

    All methods take an immutable `self`.
    """

    def complete(self, request_json: String) raises -> String:
        """Post the request and return the response body.

        Args:
            request_json: The complete JSON request body.

        Returns:
            The response body, valid UTF-8 text, as the server sent it.
        """
        ...


trait EmbedTransport(Movable, Deinitable):
    """Post an embeddings request body, return the response body.

    All methods take an immutable `self`.
    """

    def complete(self, request_json: String) raises -> String:
        """Post the request and return the response body.

        Args:
            request_json: The complete JSON request body.

        Returns:
            The response body, valid UTF-8 text, as the server sent it.
        """
        ...
