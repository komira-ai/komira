# =============================================================================
# config.mojo: the value-typed configuration of the search HTTP dispatcher
# =============================================================================
#
# A plain value type. The library reads no environment variable and no file; the
# program that mounts the dispatcher parses its own flags and passes the values
# to the constructor. It names no storage service: where the split objects and
# the catalog live is decided by the store the program hands the dispatcher, and
# the two prefixes below are key prefixes inside that store.
#
# `__init__` validates every field and raises on a value the dispatcher could
# not honour (an empty prefix, a `..` segment, a non-positive limit), so a
# misconfigured program fails at start-up and not on its first request.
# =============================================================================

comptime DEFAULT_TEXT_FIELD: String = "body"
"""The default name of an index's text field."""

comptime SOURCE_FIELD: String = "_source"
"""The designated `_source` column (`SearchSink.init_sink` raises if absent)."""

comptime DEFAULT_MAX_BODY_BYTES: Int = 32 * 1024 * 1024
"""The default request body limit (32 MiB). A `_bulk` body costs memory in
proportion to its size (the parser holds the body, its lines and the batch)."""

comptime DEFAULT_MAX_SPLITS_PER_SEARCH: Int = 1024
"""The default cap on the live splits one `_search` reads. Each split is read
and searched in turn and the per-split results are held until the merge, so the
cap bounds both the time and the memory of one request."""

comptime MAX_KEY_PREFIX_BYTES: Int = 512
"""The longest key prefix or meta root accepted."""


def _is_clean_prefix(prefix: String) -> Bool:
    """True iff `prefix` is a non-empty object-key prefix with no control
    byte, no backslash and no empty, `.` or `..` segment (a trailing `/` is
    allowed)."""
    var b = prefix.as_bytes()
    var n = len(b)
    if n == 0 or n > MAX_KEY_PREFIX_BYTES:
        return False
    var seg_len = 0
    var seg_dots = 0
    for i in range(n):
        var c = b[i]
        if c < UInt8(32) or c == UInt8(127) or c == UInt8(92):  # control, '\'
            return False
        if c == UInt8(47):  # '/'
            if seg_len == 0 and i > 0:
                return False  # an empty segment ("a//b")
            if seg_len > 0 and seg_dots == seg_len and seg_len <= 2:
                return False  # "." or ".."
            seg_len = 0
            seg_dots = 0
        else:
            seg_len += 1
            if c == UInt8(46):  # '.'
                seg_dots += 1
    if seg_len > 0 and seg_dots == seg_len and seg_len <= 2:
        return False
    return True


struct SearchHttpConfig(Copyable, Movable, Deinitable):
    """The configuration of a `SearchHttpDispatcher`.

    Fields:
      meta_root:  the key prefix of the catalog. The catalog of index `<i>` is
                  the manifest lineage under `<meta_root>/<i>/meta`, and each
                  dispatcher writes into its own sub-lineage below it.
      key_prefix: the key prefix of the split objects. A split is written to
                  `<key_prefix>/<i>/splits/<uuid>.split`.
      text_field: the name of the one text field of every index (the `_bulk`
                  handler extracts it from each document, the `_search` handler
                  searches it).
      node_id:    a stable identity of this node, folded into the dispatcher's
                  catalog sub-lineage id (`<node_id>-<pid>-<worker>`) so two
                  nodes never share a sub-lineage. May be empty (the process id
                  still tells processes apart).
      max_body_bytes: a request body longer than this is refused with 413
                  before it is parsed.
      max_splits_per_search: a `_search` over an index with more live splits
                  than this is refused with 503 before any split is read.
    """

    var meta_root: String
    var key_prefix: String
    var text_field: String
    var node_id: String
    var max_body_bytes: Int
    var max_splits_per_search: Int

    def __init__(
        out self,
        var meta_root: String,
        var key_prefix: String,
        var text_field: String = String(DEFAULT_TEXT_FIELD),
        var node_id: String = String(""),
        max_body_bytes: Int = DEFAULT_MAX_BODY_BYTES,
        max_splits_per_search: Int = DEFAULT_MAX_SPLITS_PER_SEARCH,
    ) raises:
        """Validate and take the values. Raises on an unusable prefix (empty,
        over 512 bytes, a control byte or backslash, an empty, `.` or `..`
        segment), an empty text field or one that collides with the
        `_source` column, a node id with a control byte, or a limit below 1."""
        if not _is_clean_prefix(meta_root):
            raise Error(
                "SearchHttpConfig: meta_root must be a non-empty key prefix"
                " without an empty, '.' or '..' segment"
            )
        if not _is_clean_prefix(key_prefix):
            raise Error(
                "SearchHttpConfig: key_prefix must be a non-empty key prefix"
                " without an empty, '.' or '..' segment"
            )
        if text_field.byte_length() == 0:
            raise Error("SearchHttpConfig: text_field must not be empty")
        if text_field == String(SOURCE_FIELD):
            raise Error("SearchHttpConfig: text_field must not be _source")
        var nb = node_id.as_bytes()
        for i in range(len(nb)):
            if nb[i] < UInt8(32) or nb[i] == UInt8(127):
                raise Error("SearchHttpConfig: node_id has a control byte")
        if max_body_bytes < 1:
            raise Error("SearchHttpConfig: max_body_bytes must be at least 1")
        if max_splits_per_search < 1:
            raise Error(
                "SearchHttpConfig: max_splits_per_search must be at least 1"
            )
        self.meta_root = meta_root^
        self.key_prefix = key_prefix^
        self.text_field = text_field^
        self.node_id = node_id^
        self.max_body_bytes = max_body_bytes
        self.max_splits_per_search = max_splits_per_search

    def __init__(out self, *, copy: Self):
        """A field-by-field copy; the source was validated when it was built."""
        self.meta_root = copy.meta_root.copy()
        self.key_prefix = copy.key_prefix.copy()
        self.text_field = copy.text_field.copy()
        self.node_id = copy.node_id.copy()
        self.max_body_bytes = copy.max_body_bytes
        self.max_splits_per_search = copy.max_splits_per_search
