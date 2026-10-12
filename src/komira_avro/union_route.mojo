# =============================================================================
# union_route.mojo — where each writer value lands when a union is involved.
# =============================================================================
#
# The Avro 1.11 union rules, applied per writer value:
#   - writer union, reader not a union: the writer's selected branch is resolved
#     against the reader's type; a branch that does not resolve is an error
#     signalled when a value of that branch is read;
#   - reader union, writer not a union: the writer's type is resolved against
#     a reader branch; none matching is an error at resolution;
#   - both unions: each writer branch is resolved against a reader branch.
# "Matches" here is the spec's: the same primitive type, a named type of the
# same name (and, for fixed, size), or a type promotion. When several reader
# branches match, the branch of the writer's own type wins over an earlier
# branch the value would only be promoted to (the Java reference
# implementation's choice; the spec says "the first that matches"). Among
# promotions the first branch wins.
#
# A writer `null` value is a null row of the output column. That includes a
# null branch read into a reader that is not a union, which is what the
# two-branch nullable path has always done.
#
# This file holds the resolve-time half (plain data, no decode). The decode
# half is `ActionTableInterpreter._decode_union_route` in action_table.mojo.
# =============================================================================

from .avro_schema import (
    AvroSchema,
    AvroNode,
    avro_kind_name,
    AVRO_KIND_NULL,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_ENUM,
    AVRO_KIND_ARRAY,
    AVRO_KIND_MAP,
    AVRO_KIND_UNION,
    AVRO_KIND_FIXED,
)


# =============================================================================
# Type-promotion tags (type-promotion rule). The reader's target *physical*
# accumulator family; the value is read as the writer's wire kind then
# widened. string<->bytes is a reinterpret (UTF-8 round-trip), not a numeric
# widen.
# =============================================================================

comptime PROMOTE_NONE: Int8 = 0
comptime PROMOTE_TO_LONG: Int8 = 1     # int → long
comptime PROMOTE_TO_FLOAT: Int8 = 2    # int/long → float
comptime PROMOTE_TO_DOUBLE: Int8 = 3   # int/long/float → double
comptime PROMOTE_STRING_TO_BYTES: Int8 = 4
comptime PROMOTE_BYTES_TO_STRING: Int8 = 5


def _promotion_tag(writer_kind: Int, reader_kind: Int) -> Int8:
    """Return the PROMOTE_* tag for a writer→reader scalar promotion,
    PROMOTE_NONE if the kinds are identical, or -1 if it is not a legal
    promotion. The 6 numeric promotions + string↔bytes (type-promotion rule)."""
    if writer_kind == reader_kind:
        return PROMOTE_NONE
    if writer_kind == AVRO_KIND_INT and reader_kind == AVRO_KIND_LONG:
        return PROMOTE_TO_LONG
    if (
        (writer_kind == AVRO_KIND_INT or writer_kind == AVRO_KIND_LONG)
        and reader_kind == AVRO_KIND_FLOAT
    ):
        return PROMOTE_TO_FLOAT
    if (
        (
            writer_kind == AVRO_KIND_INT
            or writer_kind == AVRO_KIND_LONG
            or writer_kind == AVRO_KIND_FLOAT
        )
        and reader_kind == AVRO_KIND_DOUBLE
    ):
        return PROMOTE_TO_DOUBLE
    if writer_kind == AVRO_KIND_STRING and reader_kind == AVRO_KIND_BYTES:
        return PROMOTE_STRING_TO_BYTES
    if writer_kind == AVRO_KIND_BYTES and reader_kind == AVRO_KIND_STRING:
        return PROMOTE_BYTES_TO_STRING
    return -1  # illegal promotion


def _named_types_match(writer: AvroNode, reader: AvroNode) -> Bool:
    """For named types (record / enum / fixed): the writer type matches the
    reader type if their fullnames are equal OR the writer's fullname is one of
    the reader type's aliases (named-type by-fullname matching)."""
    if writer.name == reader.name:
        return True
    for i in range(len(reader.aliases)):
        if reader.aliases[i] == writer.name:
            return True
    return False


# =============================================================================
# Union shape.
# =============================================================================


def is_general_union(schema: AvroSchema, idx: Int) -> Bool:
    """True iff node `idx` is a union that is NOT the two-branch nullable shape
    union[null, T] / union[T, null] (which collapses to a nullable T column).
    A general union reads as an Arrow dense union, one child per branch."""
    ref n = schema.nodes[idx]
    if n.kind != AVRO_KIND_UNION:
        return False
    if len(n.children) == 2:
        if (
            schema.nodes[n.children[0]].kind == AVRO_KIND_NULL
            or schema.nodes[n.children[1]].kind == AVRO_KIND_NULL
        ):
            return False
    return True


def union_branch_name(schema: AvroSchema, idx: Int) -> String:
    """The Arrow child name of a union branch: the named type's fullname, else
    the Avro type name ("int", "string", "null", ...)."""
    ref n = schema.nodes[idx]
    if n.name.byte_length() > 0:
        return n.name
    return avro_kind_name(n.kind)


# =============================================================================
# Routes.
# =============================================================================

comptime ROUTE_READ: Int8 = 0  # read the value (with `promote_to`)
comptime ROUTE_NULL: Int8 = 1  # writer null: a null row, nothing on the wire
comptime ROUTE_NO_MATCH: Int8 = 2  # no reader type matches: raise on read
comptime ROUTE_UNSUPPORTED: Int8 = 3  # matches, but the value kind has no column


@fieldwise_init
struct BranchRoute(Copyable, Movable):
    """Where one writer value lands. One per writer union branch, or a single
    route when the writer is not a union."""

    var status: Int8  # ROUTE_*
    var wire_kind: Int  # the writer's kind for this value
    var fixed_size: Int  # writer fixed size (AVRO_KIND_FIXED)
    var promote_to: Int8  # PROMOTE_* (PROMOTE_NONE = read as is)
    # The reader union branch the value lands in (its dense-union type id), or
    # -1 when the reader field is not a general union.
    var target: Int


@fieldwise_init
struct UnionRouteData(Copyable, Movable):
    """A field whose writer or reader type is a general union."""

    var writer_is_union: Bool  # a union tag precedes each value on the wire
    var routes: List[BranchRoute]


comptime _MATCH_NONE: Int = -1


def _match(writer: AvroSchema, widx: Int, reader: AvroSchema, ridx: Int) -> Int:
    """Resolve writer type `widx` against reader type `ridx` (neither a
    union): the PROMOTE_* tag (PROMOTE_NONE for the same type) or _MATCH_NONE."""
    ref w = writer.nodes[widx]
    ref r = reader.nodes[ridx]
    if w.kind == r.kind:
        if w.kind == AVRO_KIND_RECORD or w.kind == AVRO_KIND_ENUM:
            if not _named_types_match(w, r):
                return _MATCH_NONE
        elif w.kind == AVRO_KIND_FIXED:
            if w.size != r.size or not _named_types_match(w, r):
                return _MATCH_NONE
        return Int(PROMOTE_NONE)
    var promo = _promotion_tag(w.kind, r.kind)
    if promo < 0:
        return _MATCH_NONE
    return Int(promo)


def _route_one(
    writer: AvroSchema,
    widx: Int,
    reader: AvroSchema,
    rtype_idx: Int,
) -> BranchRoute:
    """Route one writer (non-union) type into the reader field type."""
    ref w = writer.nodes[widx]
    ref rnode = reader.nodes[rtype_idx]
    var target = -1
    var promo = _MATCH_NONE
    var null_only = False
    if rnode.kind == AVRO_KIND_UNION:
        var branches = rnode.children.copy()
        var general = is_general_union(reader, rtype_idx)
        # The writer's own type first, then the first promotion.
        for b in range(len(branches)):
            if _match(writer, widx, reader, branches[b]) == Int(PROMOTE_NONE):
                target = b
                promo = Int(PROMOTE_NONE)
                break
        if promo == _MATCH_NONE:
            for b in range(len(branches)):
                var m = _match(writer, widx, reader, branches[b])
                if m != _MATCH_NONE:
                    target = b
                    promo = m
                    break
        if not general:
            target = -1  # a nullable column, not a dense union
    elif w.kind == AVRO_KIND_NULL:
        # A writer null into a non-union reader: a null row (see header).
        null_only = True
        promo = Int(PROMOTE_NONE)
    else:
        promo = _match(writer, widx, reader, rtype_idx)
    var status: Int8
    if promo == _MATCH_NONE:
        status = ROUTE_NO_MATCH
        target = -1
    elif w.kind == AVRO_KIND_NULL or null_only:
        status = ROUTE_NULL
    elif (
        w.kind == AVRO_KIND_RECORD
        or w.kind == AVRO_KIND_ENUM
        or w.kind == AVRO_KIND_ARRAY
        or w.kind == AVRO_KIND_MAP
    ):
        status = ROUTE_UNSUPPORTED
    else:
        status = ROUTE_READ
    return BranchRoute(
        status=status,
        wire_kind=w.kind,
        fixed_size=w.size,
        promote_to=Int8(promo) if promo != _MATCH_NONE else PROMOTE_NONE,
        target=target,
    )


def build_union_route(
    writer: AvroSchema, wtype_idx: Int, reader: AvroSchema, rtype_idx: Int
) raises -> UnionRouteData:
    """Routes for a field whose writer or reader type is a general union.
    Raises UNION_NO_MATCHING_BRANCH when no writer value could ever be read
    (a non-union writer type that matches no reader branch)."""
    ref wnode = writer.nodes[wtype_idx]
    var routes = List[BranchRoute]()
    var writer_is_union = wnode.kind == AVRO_KIND_UNION
    if writer_is_union:
        for b in range(len(wnode.children)):
            routes.append(_route_one(writer, wnode.children[b], reader, rtype_idx))
    else:
        routes.append(_route_one(writer, wtype_idx, reader, rtype_idx))
        if routes[0].status == ROUTE_NO_MATCH:
            raise Error(
                "AvroResolutionError.UNION_NO_MATCHING_BRANCH: writer type "
                + avro_kind_name(wnode.kind)
                + " matches no branch of the reader union"
            )
    return UnionRouteData(writer_is_union=writer_is_union, routes=routes^)
