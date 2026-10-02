# =============================================================================
# komira_gcp_core/pagination.mojo — pageToken / nextPageToken paging (AIP-158).
# =============================================================================
#
# A Google List method takes `pageToken` and answers with `nextPageToken`;
# an absent or empty `nextPageToken` is the last page. The token rides in the
# query string of a GET (`with_page_token`) or in the request body of a POST
# (Cloud Logging's `entries:list`); either way the caller builds each request
# itself, over komira_http's `Connector`, and uses `PageCursor` for the
# bookkeeping. This package owns no transport and no paging driver.
#
# The cursor stops on a server that hands back the token it was just given
# (it would otherwise page forever) and at `max_pages`, and says which.
# The body is read for `nextPageToken` only; a refusal names byte counts. A
# 2xx page is as server-chosen as an error body, so it is parsed under the
# same nesting limit (`MAX_PARSE_DEPTH`) by komira_json's strict,
# non-recursive parser, which also refuses ill-formed UTF-8.
# =============================================================================

from komira_json import JsonValue, JSON_STRING, parse_json_bytes
from komira_gcp_core.status import MAX_PARSE_DEPTH


comptime DEFAULT_MAX_PAGES: Int = 1000


def next_page_token(body: List[UInt8]) raises -> String:
    """The response's `nextPageToken`, or "" on the last page.

    Raises if the body is not UTF-8 JSON, not an object, nests deeper than
    `MAX_PARSE_DEPTH`, or the field is not a string; the message names the
    body's byte count and komira_json's reason (a fixed phrase plus a line
    and column), never its content. There is deliberately no size cap here:
    a legitimate list page can be large."""
    var doc = JsonValue()
    try:
        doc = parse_json_bytes(body, MAX_PARSE_DEPTH)
    except e:
        raise Error(
            String("next_page_token: the ") + String(len(body))
            + "-byte list response is not a JSON document ("
            + String(e) + ")"
        )
    if not doc.is_object():
        raise Error(
            String("next_page_token: the ") + String(len(body))
            + "-byte list response is not a JSON object"
        )
    if not doc.has("nextPageToken"):
        return String()
    var v = doc.get("nextPageToken")
    if v.is_null():
        return String()
    if v.kind_tag() != JSON_STRING:
        raise Error("next_page_token: nextPageToken is not a string")
    return v.as_string()


def _is_unreserved(b: UInt8) -> Bool:
    var c = Int(b)
    return (
        (c >= ord("A") and c <= ord("Z"))
        or (c >= ord("a") and c <= ord("z"))
        or (c >= ord("0") and c <= ord("9"))
        or c == ord("-") or c == ord(".") or c == ord("_") or c == ord("~")
    )


def _hex_digit(n: UInt8) -> String:
    if n < 10:
        return chr(Int(n) + ord("0"))
    return chr(Int(n) - 10 + ord("A"))


def percent_encode(value: String) -> String:
    """RFC 3986 percent-encoding of everything but the unreserved set."""
    var out = String()
    for c in value.as_bytes():
        if _is_unreserved(c):
            out += chr(Int(c))
        else:
            out += "%" + _hex_digit(c >> 4) + _hex_digit(c & 0x0F)
    return out^


def with_page_token(url: String, token: String) -> String:
    """`url` with `pageToken=<token>` appended (percent-encoded); `url`
    unchanged for an empty token (the first page)."""
    if token.byte_length() == 0:
        return url.copy()
    var sep = "&" if url.find("?") >= 0 else "?"
    return url + sep + "pageToken=" + percent_encode(token)


struct PageCursor(Copyable, Movable, Deinitable):
    """The paging state of one List call."""

    var _token: String
    var _pages: Int
    var _max_pages: Int
    var _done: Bool

    def __init__(out self, max_pages: Int = DEFAULT_MAX_PAGES) raises:
        if max_pages < 1:
            raise Error(String("PageCursor: max_pages must be >= 1, got ") + String(max_pages))
        self._token = String()
        self._pages = 0
        self._max_pages = max_pages
        self._done = False

    def page_token(self) -> String:
        """The token to send with the next request ("" for the first page)."""
        return self._token.copy()

    def pages(self) -> Int:
        return self._pages

    def done(self) -> Bool:
        return self._done

    def advance(mut self, next_token: String) raises:
        """Record a received page and its `nextPageToken`.

        Raises when the server repeats the token it was sent, or when another
        page would exceed `max_pages`."""
        if self._done:
            raise Error("PageCursor: advance after the last page")
        self._pages += 1
        if next_token.byte_length() == 0:
            self._done = True
            return
        if next_token == self._token:
            raise Error(
                String("PageCursor: the server returned the page token it was sent (page ")
                + String(self._pages) + "); stopping instead of looping"
            )
        if self._pages >= self._max_pages:
            raise Error(
                String("PageCursor: more than ") + String(self._max_pages)
                + " pages; stopping"
            )
        self._token = next_token.copy()


