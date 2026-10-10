# =============================================================================
# kci_cloud_fake/secrets.mojo: how the fake clouds lower the SECRET type, and
# the `secret_env` of a workload's run node (or of the node holding its
# container, where that is an object of its own).
# =============================================================================
#
# A secret runs as no identity: it holds no `identity` role and no grant
# (validate refuses `uses` on it), and it is only granted to (READ, WRITE,
# READ_WRITE).
#
#   * secret -> `<id>/secret` on every shape (the roles per shape are in
#     shapes.mojo): the CONTAINER, with no value and no modelled field, and
#     `secret_named` (it exposes NAME; how the node behaves, not state). Its
#     digest is its kind alone, so nothing kci writes ever holds a value.
#   * `secret_env` of a run node, in key order (`secret_env_fields`):
#       - by name: one desired field `<kind>.secret_env.<KEY>` =
#         `[<store>/]<name>[@<version>]`, as before;
#       - by `secret`: an INPUT on the secret's id, output NAME, at
#         `<kind>.secret_env.<KEY>` (kci resolves the id to `<id>/secret`,
#         so the run waits for the secret and binds its cloud name at apply
#         time), and, when a version is pinned, the desired field
#         `<kind>.secret_env.<KEY>.version`.
#     A secret's value is never in kci's memory, so it is never in a digest.
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud import FIELD_SECRET, LoweredNode, Setting
from kci_resource_proto.refs import SecretRef
from kci_resource_proto.resource import Resource

from kci_cloud_fake.shapes import ProviderShape, ROLE_SECRET


comptime SECRET_NAMED = "secret_named"
"""The desired field that makes a node expose a secret's NAME."""


def lower_secret(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A secret's one role: its container, with no modelled field."""
    if len(r.uses) > 0:
        raise Error(String("fake: secret \"") + r.id + String("\" has uses lines; validate refuses them"))
    var fields = List[Setting]()
    fields.append(Setting(String(SECRET_NAMED), String("true")))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_SECRET),
            r.id,
            shape.kind_of(FIELD_SECRET, String(ROLE_SECRET)),
            List[String](),
            List[InputRef](),
            fields^,
        )
    )
    return out^


def secret_env_fields(
    kind: String, secrets: Dict[String, SecretRef], mut fields: List[Setting], mut refs: List[InputRef]
):
    """`secret_env` in key order (see the file header): a reference by name
    as a field, a reference to a `secret` resource as an input on its NAME
    (and its pinned version as a field)."""
    var keys = List[String]()
    for entry in secrets.items():
        keys.append(entry.key.copy())
    for i in range(1, len(keys)):
        var k = i
        while k > 0 and keys[k] < keys[k - 1]:
            var t = keys[k].copy()
            keys[k] = keys[k - 1].copy()
            keys[k - 1] = t^
            k -= 1
    for i in range(len(keys)):
        try:
            ref s = secrets[keys[i]]
            var field = kind + String(".secret_env.") + keys[i]
            if s.secret:
                # The secret by its resource id: kci resolves its primary node.
                refs.append(InputRef(s.secret.value().resource.copy(), String("NAME"), field.copy()))
                if s.version:
                    fields.append(Setting(field + String(".version"), s.version.value().copy()))
                continue
            var text = String("")
            if s.store:
                text += s.store.value() + String("/")
            text += s.name
            if s.version:
                text += String("@") + s.version.value()
            fields.append(Setting(field^, text^))
        except:
            pass  # a key just read from the map is in it
