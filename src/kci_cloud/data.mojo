# =============================================================================
# kci_cloud/data.mojo: the rules of the DATA primitives (table, bucket).
# =============================================================================
#
# GRAPH findings, true on every cloud, that validate collects for a data
# resource (`data_findings`):
#   * a data resource runs as no identity, so it has no `uses` lines: it is
#     granted to, it never grants (write the line on the workload that reads
#     or writes it);
#   * a bucket's `object_expiry_days` is never an explicit 0;
#   * a table has a KEY; every access path (the key and each index) has a
#     partition field; every field it names has a name and a type (STRING,
#     NUMBER or BYTES); an `order` names a field or is left unset; every
#     index has a name, and no two access paths share one; a `ttl_field`, when
#     written, names an attribute.
#
# THE KEY IS IMMUTABLE. A new key is a new table: no cloud changes a table's
# key in place, and pretending to (delete, then create under the same id)
# would delete every item. So a changed key is REFUSED, never planned:
#   * every cloud's `<id>/table` node carries the desired field `key`
#     (`KEY_FIELD`), rendered by `table_key_text`;
#   * `list_owned` reports each table object's key as the cloud stores it
#     (`OwnedRecord.key`, the same rendering);
#   * `key_change_findings` compares the two before anything is realized
#     (deploy.mojo, on plan and apply), and names the old and the new key.
# The author gives the new table a new id; the old one is kept or deleted by
# its retention when its id leaves the file.
#
# INDEX ROLES. A cloud whose indexes are objects of their own (one composite
# index per access path) names each by `index_role(name)`: `ix-` and 5
# base32 characters of sha256(index name), 8 bytes at any depth. A cloud
# that lowers them so checks two roles of one table that collide
# (`index_role_collisions`) as a limit.
# =============================================================================

from kci_resource_proto.data import Table, Table_AccessPath, Table_Field
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding, LoweredNode, OwnedRecord
from kci_cloud.catalog import FIELD_BUCKET, FIELD_TABLE, ROLE_TABLE
from kci_cloud.grants import role_hash


comptime KEY_FIELD = "key"
"""The desired field of a `<id>/table` node holding its key
(`table_key_text`)."""
comptime INDEX_ROLE_PREFIX = "ix-"
"""The role of an index that is an object of its own: this prefix and 5
base32 characters."""
comptime INDEX_HASH_CHARS: Int = 5

comptime _FIELD_TYPE_MAX: Int = 3
"""`kci.resource.v1.FieldType`: STRING 1, NUMBER 2, BYTES 3."""


def index_role(name: String) -> String:
    """`ix-<h>`: the role of the index called `name`."""
    return String(INDEX_ROLE_PREFIX) + role_hash(name, INDEX_HASH_CHARS)


def _field_text(f: Table_Field) -> String:
    return f.name + String(":") + f.type.json_name()


def path_text(p: Table_AccessPath) -> String:
    """`<partition>:<TYPE>`, then `/<order>:<TYPE>` when the path has an
    order: `customer:STRING/placed:NUMBER`."""
    var s = String("")
    if p.partition:
        s = _field_text(p.partition.value())
    if p.order:
        s += String("/") + _field_text(p.order.value())
    return s^


def table_key_text(t: Table) -> String:
    """The key as one string (`path_text`), empty for a table with none."""
    if not t.key:
        return String("")
    return path_text(t.key.value())


def _check_field(
    id: String, where: String, f: Table_Field, what: String, mut out: List[Finding]
):
    if f.name.byte_length() == 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                where + String(".name"),
                what + String(" has no name: name the item attribute it reads"),
            )
        )
    var t = f.type.value
    if t < 1 or t > _FIELD_TYPE_MAX:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                where + String(".type"),
                String("an untyped field")
                + (String(" (\"") + f.name + String("\")") if f.name.byte_length() > 0 else String(""))
                + String(": its type is STRING, NUMBER or BYTES"),
            )
        )


def _check_path(
    id: String, where: String, p: Table_AccessPath, mut out: List[Finding]
):
    if not p.partition:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                where + String(".partition"),
                String("no partition field: an access path finds items by one"),
            )
        )
    else:
        _check_field(id, where + String(".partition"), p.partition.value(), String("the partition"), out)
    if p.order:
        ref o = p.order.value()
        if o.name.byte_length() == 0:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    id,
                    where + String(".order"),
                    String(
                        "an order with no field: name the attribute items are"
                        " sorted by, or leave order unset"
                    ),
                )
            )
        else:
            _check_field(id, where + String(".order"), o, String("the order"), out)


def _table_findings(r: Resource, mut out: List[Finding]):
    ref t = r.table.value()
    var id = r.id.copy()
    var names = List[String]()
    if not t.key:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                String("table.key"),
                String("no key: a table finds its items by a key (a partition field, and an")
                + String(" optional order field)"),
            )
        )
    else:
        _check_path(id, String("table.key"), t.key.value(), out)
        if t.key.value().name.byte_length() > 0:
            names.append(t.key.value().name.copy())
    for i in range(len(t.indexes)):
        ref ix = t.indexes[i]
        var where = String("table.indexes[") + String(i) + String("]")
        if ix.name.byte_length() == 0:
            out.append(
                Finding(FINDING_GRAPH, id, where + String(".name"), String("an index has no name"))
            )
        else:
            var dup = False
            for k in range(len(names)):
                if names[k] == ix.name:
                    dup = True
                    break
            if dup:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        id,
                        where + String(".name"),
                        String("duplicate access path name \"") + ix.name + String("\""),
                    )
                )
            else:
                names.append(ix.name.copy())
        _check_path(id, where, ix, out)
    if Bool(t.ttl_field) and t.ttl_field.value().byte_length() == 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                id,
                String("table.ttl_field"),
                String("an empty ttl_field: name the NUMBER attribute that holds an")
                + String(" item's expiry, or leave it unset so items never expire"),
            )
        )


def data_findings(field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the data resource `r` (a `table` or a
    `bucket`, by its body `field`); empty for any other type."""
    var out = List[Finding]()
    if field != FIELD_TABLE and field != FIELD_BUCKET:
        return out^
    var tname = String("table") if field == FIELD_TABLE else String("bucket")
    if field == FIELD_BUCKET:
        ref bkt = r.bucket.value()
        if Bool(bkt.object_expiry_days) and bkt.object_expiry_days.value() == 0:
            out.append(
                Finding(
                    FINDING_GRAPH,
                    r.id,
                    String("bucket.object_expiry_days"),
                    String(
                        "0 would expire every object at once; leave it unset"
                        " to keep objects until they are deleted"
                    ),
                )
            )
    else:
        _table_findings(r, out)
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                String("a ")
                + tname
                + String(
                    " runs as no identity, so it cannot use another"
                    " resource; write the uses line on the workload that"
                    " reads or writes it"
                ),
            )
        )
    return out^


def index_role_collisions(r: Resource) -> List[String]:
    """The index names of table `r` whose `index_role` repeats an earlier
    index's (empty for any other type)."""
    var out = List[String]()
    if not r.table:
        return out^
    ref t = r.table.value()
    var roles = List[String]()
    for i in range(len(t.indexes)):
        var role = index_role(t.indexes[i].name)
        for k in range(len(roles)):
            if roles[k] == role and t.indexes[k].name != t.indexes[i].name:
                out.append(t.indexes[i].name.copy())
                break
        roles.append(role^)
    return out^


def key_change_findings(nodes: List[LoweredNode], owned: List[OwnedRecord]) -> List[Finding]:
    """One finding per table whose stored key (`owned`, as the cloud reports
    it) differs from the key its `<id>/table` node now asks for. An object
    with no stored key, and a node with no key field, are never compared."""
    var out = List[Finding]()
    var suffix = String("/") + String(ROLE_TABLE)
    for i in range(len(owned)):
        ref rec = owned[i]
        if rec.key.byte_length() == 0 or not rec.owner_node.endswith(suffix):
            continue
        for k in range(len(nodes)):
            ref n = nodes[k]
            if n.id != rec.owner_node or not n.wanted:
                continue
            var want = n.field(String(KEY_FIELD))
            if want.byte_length() > 0 and want != rec.key:
                out.append(
                    Finding(
                        FINDING_GRAPH,
                        n.owner,
                        String("table.key"),
                        String("the key changed from ")
                        + rec.key
                        + String(" to ")
                        + want
                        + String(
                            ": a table's key is immutable (a new key is a new table)."
                            " Give the new table a new id; the old one is kept or"
                            " deleted by its retention when its id leaves the file"
                        ),
                    )
                )
            break
    return out^
