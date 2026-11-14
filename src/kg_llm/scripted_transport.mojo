# =============================================================================
# scripted_transport -- transports that answer from a table, for tests.
# =============================================================================
#
# A scripted transport opens no socket. A row is a piece of text and the body to
# answer with: the first row whose text occurs in the request body wins, and an
# empty text matches every request, so a test can pin a response to the exact
# piece of the request it expects (a model id, a prompt) and a request that
# lacks it is a failure rather than a silent default. A request no row matches
# raises, and the error quotes the first bytes of the request.
#
# There is one scripted transport per trait; they behave alike.
# =============================================================================

from .transport import ChatTransport, EmbedTransport

# How much of an unmatched request an error quotes.
comptime _SCRIPTED_QUOTE_BYTES: Int = 200


struct ScriptedChatTransport(ChatTransport):
    """A `ChatTransport` that answers from rows registered with `add`."""

    var _match: List[String]
    var _reply: List[String]

    def __init__(out self):
        """A transport with no rows: every call raises."""
        self._match = List[String]()
        self._reply = List[String]()

    def add(mut self, match_text: String, response_body: String):
        """Register a row.

        Args:
            match_text: Text that must occur in the request body for the row to
                answer; empty matches every request.
            response_body: The body to return.
        """
        self._match.append(match_text)
        self._reply.append(response_body)

    def complete(self, request_json: String) raises -> String:
        """The body of the first row whose text occurs in the request.

        Args:
            request_json: The request body.

        Returns:
            The registered response body.
        """
        return _scripted_lookup(
            "ScriptedChatTransport", self._match, self._reply, request_json
        )


struct ScriptedEmbedTransport(EmbedTransport):
    """An `EmbedTransport` that answers from rows registered with `add`."""

    var _match: List[String]
    var _reply: List[String]

    def __init__(out self):
        """A transport with no rows: every call raises."""
        self._match = List[String]()
        self._reply = List[String]()

    def add(mut self, match_text: String, response_body: String):
        """Register a row.

        Args:
            match_text: Text that must occur in the request body for the row to
                answer; empty matches every request.
            response_body: The body to return.
        """
        self._match.append(match_text)
        self._reply.append(response_body)

    def complete(self, request_json: String) raises -> String:
        """The body of the first row whose text occurs in the request.

        Args:
            request_json: The request body.

        Returns:
            The registered response body.
        """
        return _scripted_lookup(
            "ScriptedEmbedTransport", self._match, self._reply, request_json
        )


def _scripted_lookup(
    who: String,
    matches: List[String],
    replies: List[String],
    request_json: String,
) raises -> String:
    """The reply of the first row that matches, else a raised error."""
    for i in range(len(matches)):
        if matches[i].byte_length() == 0 or matches[i] in request_json:
            return replies[i]
    var request = request_json.as_bytes()
    var n = len(request)
    if n > _SCRIPTED_QUOTE_BYTES:
        n = _SCRIPTED_QUOTE_BYTES
    raise Error(
        who
        + ": no row matches the request, which begins "
        + String(from_utf8_lossy=request[0:n])
    )
