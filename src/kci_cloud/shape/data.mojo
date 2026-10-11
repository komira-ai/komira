# =============================================================================
# kci_cloud/shape/data.mojo: how the shared shapes lower the DATA types.
# =============================================================================
#
# A data resource runs as no identity: it holds no `identity` role and no
# grant (validate refuses `uses` on it), and it is only granted to.
#
#   * bucket -> `<id>/bucket` on every shape: every modelled field with its
#     default filled in (expiry `never`, versioning, tier `STANDARD`), and
#     `stores` (it exposes NAME and ADDRESS; how the node behaves, not
#     state).
#   * table  -> `<id>/table` on every shape that hosts it, with the desired
#     field `key` (`kci_cloud.table_key_text`; the key kci refuses to
#     change) and `named` (it exposes NAME). Where the shape's indexes and
#     TTL are settings of the table (generic, aws, azure), they are fields
#     of the same node: `index.<name>` per index in the order written
#     (`kci_cloud.path_text`) and `ttl` (`none` when unset). Where they are
#     objects of their own (gcp), each index is `<id>/ix-<h>` (fields
#     `index` and `path`) and the TTL policy `<id>/ttl` (field `ttl`,
#     wanted iff `ttl_field` is set); the `table` node is then the key's
#     own index.
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud.adapter import LoweredNode, Setting
from kci_cloud.catalog import FIELD_BUCKET, FIELD_TABLE
from kci_cloud.data import (
    KEY_FIELD,
    index_role,
    path_text,
    table_key_text,
)
from kci_resource_proto.resource import Resource

from kci_cloud.shape.shapes import ProviderShape, ROLE_BUCKET, ROLE_INDEX, ROLE_TABLE, ROLE_TTL


comptime DEFAULT_EXPIRY = "never"
comptime DEFAULT_TIER = "STANDARD"
comptime DEFAULT_TTL = "none"


def _no_uses(r: Resource, what: String) raises:
    if len(r.uses) > 0:
        raise Error(
            String("fake: ") + what + String(" \"") + r.id + String("\" has uses lines; validate refuses them")
        )


def lower_bucket(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A bucket's one role, every modelled field with its default filled in.
    `stores` is how the node behaves (it exposes NAME and ADDRESS), not
    state."""
    _no_uses(r, String("bucket"))
    ref b = r.bucket.value()
    var fields = List[Setting]()
    var expiry = String(DEFAULT_EXPIRY)
    if b.object_expiry_days:
        expiry = String(Int(b.object_expiry_days.value()))
    fields.append(Setting(String("expiry_days"), expiry^))
    fields.append(Setting(String("versioning"), String("true") if b.versioning else String("false")))
    var tier = String(DEFAULT_TIER)
    if b.tier.value != 0:
        tier = b.tier.json_name()
    fields.append(Setting(String("tier"), tier^))
    fields.append(Setting(String("stores"), String("true")))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_BUCKET),
            r.id,
            shape.kind_of(FIELD_BUCKET, String(ROLE_BUCKET)),
            List[String](),
            List[InputRef](),
            fields^,
        )
    )
    return out^


def lower_table(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A table's roles on `shape` (see the file header)."""
    _no_uses(r, String("table"))
    ref t = r.table.value()
    var own_indexes = shape.has(FIELD_TABLE, String(ROLE_INDEX))
    var own_ttl = shape.has(FIELD_TABLE, String(ROLE_TTL))
    var ttl = String(DEFAULT_TTL)
    if t.ttl_field:
        ttl = t.ttl_field.value().copy()
    var fields = List[Setting]()
    fields.append(Setting(String(KEY_FIELD), table_key_text(t)))
    if not own_indexes:
        for i in range(len(t.indexes)):
            fields.append(Setting(String("index.") + t.indexes[i].name, path_text(t.indexes[i])))
    if not own_ttl:
        fields.append(Setting(String("ttl"), ttl.copy()))
    fields.append(Setting(String("named"), String("true")))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_TABLE),
            r.id,
            shape.kind_of(FIELD_TABLE, String(ROLE_TABLE)),
            List[String](),
            List[InputRef](),
            fields^,
        )
    )
    if own_indexes:
        var kind = shape.kind_of(FIELD_TABLE, String(ROLE_INDEX))
        for i in range(len(t.indexes)):
            ref ix = t.indexes[i]
            var f = List[Setting]()
            f.append(Setting(String("index"), ix.name.copy()))
            f.append(Setting(String("path"), path_text(ix)))
            out.append(
                LoweredNode(
                    r.id + String("/") + index_role(ix.name),
                    r.id,
                    kind.copy(),
                    List[String](),
                    List[InputRef](),
                    f^,
                )
            )
    if own_ttl:
        var f = List[Setting]()
        f.append(Setting(String("ttl"), ttl.copy()))
        var deps = List[String]()
        deps.append(r.id + String("/") + String(ROLE_TABLE))
        out.append(
            LoweredNode(
                r.id + String("/") + String(ROLE_TTL),
                r.id,
                shape.kind_of(FIELD_TABLE, String(ROLE_TTL)),
                deps^,
                List[InputRef](),
                f^,
                Bool(t.ttl_field),
            )
        )
    return out^
