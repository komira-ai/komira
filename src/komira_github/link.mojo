# =============================================================================
# komira_github/link.mojo -- GitHub's pagination: the `Link` header.
# =============================================================================
#
# A list answer that has more pages carries
#   Link: <https://api.github.com/...?per_page=100&page=2>; rel="next",
#         <https://api.github.com/...?per_page=100&page=5>; rel="last"
# (RFC 8288; GitHub's "Using pagination in the REST API"). The last page has
# no `rel="next"`; that, and only that, ends a walk.
#
# The client does not send the URL a Link names. GitHub may spell a
# repository's list as `/repositories/<id>/...` rather than the path that was
# asked for, and a Link is response data: sending the installation token to
# whatever URL it names would let one bad answer move the token elsewhere.
# So `link_next_page` reads only the `page` number from the next link, and
# the client asks the same allowlisted route again with that page. A next
# link without a positive decimal `page` is refused (`BAD_RESPONSE`), so a
# cursor-paginated answer is never read as complete, and two `next` links
# are refused rather than one chosen.
# =============================================================================

from .error import KIND_BAD_RESPONSE, github_error
from .header import ascii_lower


@fieldwise_init
struct LinkEntry(Copyable, Movable, Deinitable):
    """One link-value: the URI between `<` and `>` and its `rel` values
    (lower case, split at spaces)."""

    var uri: String
    var rels: List[String]


def _is_ws(c: UInt8) -> Bool:
    return c == UInt8(ord(" ")) or c == UInt8(ord("\t"))


def _bad(detail: String) -> Error:
    return github_error(KIND_BAD_RESPONSE, String("Link header: ") + detail)


def parse_link_header(header: String) raises -> List[LinkEntry]:
    """Every link-value of `header`. Raises on a value that does not start
    with `<`, an unclosed `<`, or an unclosed quoted parameter."""
    var b = header.as_bytes()
    var n = len(b)
    var out = List[LinkEntry]()
    var i = 0
    while True:
        while i < n and (_is_ws(b[i]) or b[i] == UInt8(ord(","))):
            i += 1
        if i >= n:
            break
        if b[i] != UInt8(ord("<")):
            raise _bad("a link-value does not start with <")
        var close = header.find(">", i + 1)
        if close < 0:
            raise _bad("a link-value has no closing >")
        var uri = String(header[byte = i + 1 : close])
        i = close + 1
        var rels = List[String]()
        # Parameters: *( OWS ";" OWS name [ "=" value ] ) up to a ',' or the end.
        while True:
            while i < n and _is_ws(b[i]):
                i += 1
            if i >= n or b[i] == UInt8(ord(",")):
                break
            if b[i] != UInt8(ord(";")):
                raise _bad("a link parameter does not start with ;")
            i += 1
            while i < n and _is_ws(b[i]):
                i += 1
            var name_start = i
            while (
                i < n
                and b[i] != UInt8(ord("="))
                and b[i] != UInt8(ord(";"))
                and b[i] != UInt8(ord(","))
                and not _is_ws(b[i])
            ):
                i += 1
            var name = ascii_lower(String(header[byte=name_start:i]))
            while i < n and _is_ws(b[i]):
                i += 1
            var value = String("")
            if i < n and b[i] == UInt8(ord("=")):
                i += 1
                while i < n and _is_ws(b[i]):
                    i += 1
                if i < n and b[i] == UInt8(ord('"')):
                    var endq = header.find('"', i + 1)
                    if endq < 0:
                        raise _bad("a quoted link parameter is not closed")
                    value = String(header[byte = i + 1 : endq])
                    i = endq + 1
                else:
                    var vs = i
                    while i < n and b[i] != UInt8(ord(";")) and b[i] != UInt8(ord(",")) and not _is_ws(b[i]):
                        i += 1
                    value = String(header[byte=vs:i])
            if name == "rel":
                # rel is a space-separated list of relation types.
                var vb = value.as_bytes()
                var s = 0
                for k in range(len(vb) + 1):
                    if k == len(vb) or _is_ws(vb[k]):
                        if k > s:
                            rels.append(ascii_lower(String(value[byte=s:k])))
                        s = k + 1
        out.append(LinkEntry(uri^, rels^))
    return out^


def query_param(uri: String, key: String) -> Optional[String]:
    """The value of the first `key=` in the query of `uri` (after its `?`,
    before any `#`), as written; None when absent."""
    var q = uri.find("?")
    if q < 0:
        return None
    var end = uri.find("#", q)
    if end < 0:
        end = uri.byte_length()
    var query = String(uri[byte = q + 1 : end])
    var b = query.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == UInt8(ord("&")):
            var pair = String(query[byte=start:i])
            var eq = pair.find("=")
            if eq >= 0 and String(pair[byte=0:eq]) == key:
                return String(pair[byte = eq + 1 : pair.byte_length()])
            start = i + 1
    return None


def link_next_page(header: String) raises -> Int:
    """The `page` of the one `rel="next"` link in `header`; 0 when there is
    no next link (the last page). Raises on two next links and on a next
    link whose `page` is absent or not a positive decimal of at most 9
    digits."""
    var links = parse_link_header(header)
    var found = -1
    for i in range(len(links)):
        for k in range(len(links[i].rels)):
            if links[i].rels[k] == "next":
                if found >= 0:
                    raise _bad("more than one rel=next link")
                found = i
    if found < 0:
        return 0
    var page = query_param(links[found].uri, String("page"))
    if not page:
        raise _bad("the next link has no page parameter")
    var p = page.value()
    var pb = p.as_bytes()
    if len(pb) == 0 or len(pb) > 9 or pb[0] == UInt8(ord("0")):
        raise _bad("the next link's page is not a positive number")
    var v = 0
    for i in range(len(pb)):
        if pb[i] < UInt8(ord("0")) or pb[i] > UInt8(ord("9")):
            raise _bad("the next link's page is not a positive number")
        v = v * 10 + Int(pb[i] - UInt8(ord("0")))
    return v
