# =============================================================================
# komira_gcp_core/nesting.mojo — the nesting-depth guard before every parse.
# =============================================================================
#
# `komira_serde.json_value.parse_json_value` is recursive descent with no depth
# limit of its own, so a document's nesting depth is the parser's STACK depth.
# Every body this package parses is server-chosen — an error envelope
# (`status.mojo`) and a 2xx list page alike (`pagination.mojo`) — so each is
# checked here first: a server must not be able to choose how deep the
# process recurses. A body of `[[[[...` would otherwise overflow the stack and
# kill the process instead of raising.
#
# This is a package-internal helper: it is not re-exported from the root.
# =============================================================================


comptime MAX_PARSE_DEPTH: Int = 64
"""A body nesting `[`/`{` deeper than this is not parsed. A Google error
envelope or list page is a handful of levels deep."""


def nesting_within(body: List[UInt8], max_depth: Int) -> Bool:
    """Whether the JSON-ish `body` nests `[`/`{` at most `max_depth` deep,
    ignoring brackets inside strings (escapes honoured). Linear, no recursion,
    reads nothing but the bytes."""
    var depth = 0
    var in_string = False
    var escaped = False
    for i in range(len(body)):
        var c = Int(body[i])
        if in_string:
            if escaped:
                escaped = False
            elif c == ord("\\"):
                escaped = True
            elif c == ord('"'):
                in_string = False
            continue
        if c == ord('"'):
            in_string = True
        elif c == ord("[") or c == ord("{"):
            depth += 1
            if depth > max_depth:
                return False
        elif c == ord("]") or c == ord("}"):
            depth -= 1
    return True
