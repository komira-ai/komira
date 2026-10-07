# =============================================================================
# ipc_nested_buffer_check.mojo: Buffer-descriptor counts and STRUCT child
# lengths for the nested RecordBatch decoders.
# =============================================================================
#
# The nested decoders (`decode_record_batch_message_nested` and
# `decode_record_batch_message_nested_zerocopy`) walk the schema in pre-order
# and read `buffers[buffer_idx + k]` for each node. The Buffer list comes from
# the message, so a message can carry fewer descriptors than its schema walk
# reads; indexing past the list traps and aborts the process. FieldNode
# indices are checked where they are read (`check_node_index`); this file
# does the same for Buffer indices:
#
#   * `nested_node_buffer_count` returns how many Buffer descriptors one node
#     reads itself (its children count their own), following the decoder's
#     arm for that type: 0 where the arm raises before reading any buffer;
#   * `check_node_buffers` refuses the node when the RecordBatch does not
#     carry that many descriptors from the node's first buffer on, before the
#     arm reads one.
#
# `check_struct_child_length` refuses a STRUCT child whose length is not the
# STRUCT's length (see its docstring for the format rule).
# =============================================================================

from komira_arrow.arrow_types import ArrowType

# A count larger than any Buffer list: a view node's variadic count is an
# untrusted Int64, and `2 + count` must not wrap.
comptime _SATURATED = 1 << 62


def nested_node_buffer_count(
    t: ArrowType,
    n_children: Int,
    inner_size: Int,
    fixed_width: Int,
    view_col_idx: Int,
    variadic_buffer_counts: List[Int64],
    zerocopy: Bool,
) -> Int:
    """The number of Buffer descriptors the nested decoder's arm for type `t`
    reads for this node, children excluded.

    `fixed_width` is the decoder's bytes-per-value for `t` (0 when `t` is not
    a fixed-width primitive). `zerocopy` selects the zero-copy decoder's arms,
    which refuse BOOL and the view types, and check a LIST's or MAP's child
    count before reading. Where the arm raises before reading any buffer
    (an invalid spec, an unsupported type, a view index the message does not
    carry) the count is 0, so that arm's own refusal is the one raised.
    """
    if t == ArrowType.NULL:
        return 0
    if t == ArrowType.BOOL:
        return 0 if zerocopy else 2
    if fixed_width > 0:
        return 2  # validity + values
    if (
        t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
    ):
        return 3  # validity + offsets + data
    if t == ArrowType.FIXED_SIZE_BINARY:
        return 2 if inner_size > 0 else 0
    if t == ArrowType.FIXED_SIZE_LIST:
        return 1 if (inner_size > 0 and n_children == 1) else 0
    if (
        t == ArrowType.LIST
        or t == ArrowType.LARGE_LIST
        or t == ArrowType.MAP
    ):
        # validity + offsets. The copy-on-read arms read both before they
        # check the child count; the zero-copy arms check it first.
        if zerocopy and n_children != 1:
            return 0
        return 2
    if t == ArrowType.STRUCT:
        return 1  # validity
    if t == ArrowType.UNION_SPARSE:
        return 1  # type ids
    if t == ArrowType.UNION_DENSE:
        return 2  # type ids + offsets
    if t == ArrowType.BINARY_VIEW or t == ArrowType.UTF8_VIEW:
        if zerocopy:
            return 0
        if view_col_idx < 0 or view_col_idx >= len(variadic_buffer_counts):
            return 0
        var n_variadic = Int(variadic_buffer_counts[view_col_idx])
        if n_variadic < 0:
            return 0
        if n_variadic > _SATURATED:
            return _SATURATED
        return 2 + n_variadic  # validity + views + variadic data buffers
    if t == ArrowType.LIST_VIEW or t == ArrowType.LARGE_LIST_VIEW:
        if zerocopy or n_children != 1:
            return 0
        return 3  # validity + offsets + sizes
    return 0


def check_node_buffers(
    context: StringLiteral,
    node_index: Int,
    buffer_index: Int,
    needed: Int,
    n_buffers: Int,
) raises:
    """Refuse a node that reads `needed` Buffer descriptors starting at
    `buffer_index` when the RecordBatch carries only `n_buffers`."""
    if needed <= 0:
        return
    # Written as a subtraction so that a large `needed` cannot wrap.
    if buffer_index < 0 or needed > n_buffers - buffer_index:
        raise Error(
            String(context)
            + ": field node #"
            + String(node_index)
            + " reads "
            + String(needed)
            + " buffers from buffer #"
            + String(buffer_index)
            + " but the RecordBatch has "
            + String(n_buffers)
            + " buffers"
        )


def check_struct_child_length(
    context: StringLiteral,
    struct_node_index: Int,
    struct_length: Int,
    child: Int,
    child_node_index: Int,
    child_length: Int,
) raises:
    """Refuse a STRUCT child whose length differs from the STRUCT's.

    Arrow Columnar Format, "Struct Layout": a struct array has one child
    array per field, and child entry i is valid only if bit i of the
    struct's validity bitmap and bit i of the child's are both set (the
    "Struct Validity" paragraph), so struct slot i is child slot i. An IPC
    FieldNode (Message.fbs, `struct FieldNode { length; null_count; }`)
    carries no offset, so in a RecordBatch a child shorter than its STRUCT
    leaves struct slots with no child value. The format text does not state
    that a longer child is invalid; this decoder refuses it as well, as a
    policy: the Arrow C++ IPC writer slices each child to the struct's
    window before writing it, so it never writes a longer child. The
    policy has an interoperability cost: a writer that serialises C Data
    Interface arrays as stored (nanoarrow's IPC encoder writes each child's
    own length) emits a longer child for a struct sliced at offset 0, and
    this decoder refuses that stream. Arrow C++ reads it (its validation
    needs only child length >= struct offset + length). arrow-rs's IPC
    reader builds the struct with `StructArray::try_new`, which refuses a
    validity bitmap (present only when the STRUCT has nulls) whose length
    differs from the children's, and children whose lengths differ from
    each other; otherwise the struct takes the children's length. A
    top-level STRUCT column then fails the row-count check of
    `RecordBatch::try_new_with_options` and the batch is refused. A
    no-null STRUCT under a parent whose validation bounds the child's
    length only from below is read: with the children's length under
    LIST, LARGE_LIST, MAP, LIST_VIEW, LARGE_LIST_VIEW or a dense UNION,
    and sliced to the list's window under FIXED_SIZE_LIST. A sparse UNION
    requires each child's length to equal its own and refuses it.
    """
    if child_length != struct_length:
        raise Error(
            String(context)
            + ": field node #"
            + String(child_node_index)
            + " (child "
            + String(child)
            + " of the STRUCT at field node #"
            + String(struct_node_index)
            + ") has length "
            + String(child_length)
            + " but the STRUCT has length "
            + String(struct_length)
        )
