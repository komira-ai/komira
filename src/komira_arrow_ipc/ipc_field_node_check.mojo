# =============================================================================
# ipc_field_node_check.mojo: FieldNode and buffer-size checks for the
# RecordBatch decoders.
# =============================================================================
#
# A RecordBatch's FieldNodes (`length`, `null_count`) are as untrusted as its
# Buffer descriptors. Every decoder sizes the buffers a column needs from the
# node's `length`: `length * width` values bytes, `ceil(length / 8)` bitmap
# bytes, `(length + 1) * width` offsets bytes. Formed with plain Int
# arithmetic, a huge length wraps (INT64 with length 2^61 needs 2^64 bytes,
# which is 0 in Int), the "buffer too small" comparison passes, and the
# column claims 2^61 rows over an empty buffer. A negative length makes every
# size negative and passes the same comparison.
#
# The decoders therefore:
#   1. refuse a node with `length < 0`, `null_count < 0` or
#      `null_count > length` (`check_field_node`), and a top-level node whose
#      length differs from the RecordBatch length (`check_top_level_node`;
#      the Arrow format requires every column of a record batch to have the
#      batch's length, and Arrow C++ and arrow-rs refuse a batch that breaks
#      it);
#   2. form every size through `checked_size_mul`, `bitmap_bytes` and
#      `offsets_bytes`, which refuse a negative count and an overflow instead
#      of wrapping;
#   3. refuse a buffer smaller than that size (`check_buffer_size`), and a
#      node that declares nulls but carries no validity bitmap
#      (`validity_present`).
#
# Every refusal names the decoder (`context`), the field node by its index in
# the RecordBatch (the body carries no field names; they live in the Schema
# message) and the buffer.
# =============================================================================

from komira_arrow_ipc.ipc_flatbuf import FieldNode


def _node(context: StringLiteral, node_index: Int) -> String:
    return String(context) + ": field node #" + String(node_index)


def check_field_node(
    context: StringLiteral, node_index: Int, length: Int, null_count: Int
) raises:
    """Refuse a FieldNode whose length or null_count is negative, or whose
    null_count exceeds its length."""
    if length < 0:
        raise Error(
            _node(context, node_index)
            + " has negative length "
            + String(length)
        )
    if null_count < 0:
        raise Error(
            _node(context, node_index)
            + " has negative null_count "
            + String(null_count)
        )
    if null_count > length:
        raise Error(
            _node(context, node_index)
            + " null_count "
            + String(null_count)
            + " exceeds its length "
            + String(length)
        )


def check_top_level_node(
    context: StringLiteral,
    column: Int,
    node_index: Int,
    length: Int,
    null_count: Int,
    rb_length: Int,
) raises:
    """`check_field_node`, then refuse a top-level column whose length is not
    the RecordBatch length."""
    check_field_node(context, node_index, length, null_count)
    if length != rb_length:
        raise Error(
            String(context)
            + ": column "
            + String(column)
            + " (field node #"
            + String(node_index)
            + ") has length "
            + String(length)
            + " but the RecordBatch length is "
            + String(rb_length)
        )


def check_record_batch_length(context: StringLiteral, rb_length: Int) raises:
    """Refuse a negative RecordBatch length (a batch with no columns has no
    node to compare it against)."""
    if rb_length < 0:
        raise Error(
            String(context)
            + ": RecordBatch length "
            + String(rb_length)
            + " is negative"
        )


def check_top_level_nodes(
    context: StringLiteral, nodes: List[FieldNode], rb_length: Int
) raises:
    """The flat decoders' gate: one FieldNode per column, so every node is a
    top-level column node and node i is column i."""
    check_record_batch_length(context, rb_length)
    for i in range(len(nodes)):
        check_top_level_node(
            context,
            i,
            i,
            Int(nodes[i].length),
            Int(nodes[i].null_count),
            rb_length,
        )


def check_node_index(
    context: StringLiteral, node_index: Int, n_nodes: Int
) raises:
    """Refuse a FieldNode index past the RecordBatch's node list (the nested
    decoders walk the list by schema, without a count check up front)."""
    if node_index < 0 or node_index >= n_nodes:
        raise Error(
            _node(context, node_index)
            + " is missing (the RecordBatch has "
            + String(n_nodes)
            + " field nodes)"
        )


def _refuse_negative(
    context: StringLiteral,
    node_index: Int,
    what: StringLiteral,
    count: Int,
) raises:
    if count < 0:
        raise Error(
            _node(context, node_index)
            + " "
            + String(what)
            + " size from a negative count "
            + String(count)
        )


def checked_size_mul(
    context: StringLiteral,
    node_index: Int,
    what: StringLiteral,
    count: Int,
    width: Int,
) raises -> Int:
    """`count * width` (`what` names the size in a refusal), refusing a negative count and a product that
    does not fit in Int. `width` is a positive per-type constant."""
    _refuse_negative(context, node_index, what, count)
    if count > Int.MAX // width:
        raise Error(
            _node(context, node_index)
            + " "
            + String(what)
            + " size overflows ("
            + String(count)
            + " x "
            + String(width)
            + ")"
        )
    return count * width


def checked_bitmap_bytes(
    context: StringLiteral,
    node_index: Int,
    what: StringLiteral,
    count: Int,
) raises -> Int:
    """`ceil(count / 8)` bytes, formed without `count + 7` (which wraps for a
    count within 7 of Int.MAX)."""
    _refuse_negative(context, node_index, what, count)
    return count // 8 + (1 if count % 8 != 0 else 0)


def checked_offsets_bytes(
    context: StringLiteral,
    node_index: Int,
    what: StringLiteral,
    count: Int,
    width: Int,
) raises -> Int:
    """`(count + 1) * width` bytes, refusing a negative count and an
    overflow of either step."""
    _refuse_negative(context, node_index, what, count)
    if count == Int.MAX:
        raise Error(
            _node(context, node_index)
            + " "
            + String(what)
            + " size overflows ("
            + String(count)
            + " + 1 entries)"
        )
    return checked_size_mul(context, node_index, what, count + 1, width)


def varlen_offsets_bytes(
    context: StringLiteral,
    node_index: Int,
    count: Int,
    width: Int,
) raises -> Int:
    """The offsets bytes a STRING/BINARY column of `count` rows needs:
    `(count + 1) * width`, except that a zero-row column may carry an empty
    offsets buffer (Arrow C++ writes one, and its reader accepts it)."""
    if count == 0:
        return 0
    return checked_offsets_bytes(
        context, node_index, "offsets buffer", count, width
    )


def check_buffer_size(
    context: StringLiteral,
    node_index: Int,
    buffer: StringLiteral,
    have: Int,
    need: Int,
    length: Int,
) raises:
    """Refuse a `buffer` of `have` bytes when the node's `length` rows need
    `need`."""
    if have < need:
        raise Error(
            String(context)
            + ": "
            + String(buffer)
            + " buffer too small (have "
            + String(have)
            + ", expected "
            + String(need)
            + ") for field node #"
            + String(node_index)
            + " ("
            + String(length)
            + " rows)"
        )


def validity_present(
    context: StringLiteral,
    node_index: Int,
    have: Int,
    length: Int,
    null_count: Int,
) raises -> Bool:
    """Whether the node carries a validity bitmap of `have` bytes. An absent
    bitmap (`have == 0`) is refused when the node declares nulls (the column
    would claim nulls it cannot locate); a present one must cover `length`
    bits."""
    if have == 0:
        if null_count > 0:
            raise Error(
                _node(context, node_index)
                + " declares "
                + String(null_count)
                + " nulls but has no validity bitmap"
            )
        return False
    check_buffer_size(
        context,
        node_index,
        "bitmap",
        have,
        checked_bitmap_bytes(context, node_index, "bitmap buffer", length),
        length,
    )
    return True
