# =============================================================================
# store_support.mojo: what the group offset store and the group coordinator
#                     share about the objects they keep in a store.
# =============================================================================
#
# The key segment of a group id, and the reading of a store error as "the
# object is absent" or "a conditional write lost its race". Both readings are
# decided by where a marker sits in the message, never by whether the text holds
# it: store errors name the object key, the key holds a group id and a topic,
# and those are free text.
#
# No pointer type appears in any signature.
# =============================================================================


def group_path_segment(group_id: String) -> String:
    """The group id as one path segment: `%` and `/` are percent-encoded, so a
    group id holding `/` cannot name another group's subtree."""
    var out = List[UInt8]()
    var bs = group_id.as_bytes()
    for i in range(len(bs)):
        var c = bs[i]
        if c == UInt8(ord("%")):
            out.extend(String("%25").as_bytes())
        elif c == UInt8(ord("/")):
            out.extend(String("%2F").as_bytes())
        else:
            out.append(c)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _is_method_prefix_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("."))
    )


def _is_kind_message(
    msg: String, cloud_prefix: String, in_tree_marker: String
) -> Bool:
    """True iff `msg` starts with `cloud_prefix`, or starts with a method prefix
    (letters, digits, `_` and `.` only, for example
    `InMemoryConditionalStore.get`) followed by `in_tree_marker`. The method
    prefix cannot hold a space or a bracket, so key text cannot stand in for
    it."""
    if msg.startswith(cloud_prefix):
        return True
    var bs = msg.as_bytes()
    var i = 0
    while i < len(bs) and _is_method_prefix_byte(bs[i]):
        i += 1
    if i == 0:
        return False
    var marker = in_tree_marker.as_bytes()
    if len(bs) - i < len(marker):
        return False
    for k in range(len(marker)):
        if bs[i + k] != marker[k]:
            return False
    return True


def is_not_found(msg: String) -> Bool:
    """True iff a store error says the object is absent. Two forms are
    accepted: the message starts with `StoreError[NOT_FOUND]`, the cloud
    stores' canonical kind token (the key comes after it), or it starts with an
    in-tree store's method prefix followed by `: not_found (404)`."""
    return _is_kind_message(
        msg, String("StoreError[NOT_FOUND]"), String(": not_found (404)")
    )


def is_lost_cas(msg: String) -> Bool:
    """True iff a store error says a conditional write lost its race (HTTP
    412). Two forms are accepted: the message starts with
    `StoreError[PRECONDITION]`, or it starts with an in-tree store's method
    prefix followed by `: precondition (412)`. A failure that only names a
    key holding `412`, `precondition` or `If-Match` is not a lost swap."""
    return _is_kind_message(
        msg,
        String("StoreError[PRECONDITION]"),
        String(": precondition (412)"),
    )
