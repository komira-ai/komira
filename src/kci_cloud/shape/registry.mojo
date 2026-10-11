# =============================================================================
# kci_cloud/shape/registry.mojo: how the shared shapes lower the REGISTRY type.
# =============================================================================
#
# A registry runs as no identity: it holds no `identity` role and no grant
# of its own (validate refuses `uses` on it). It is only granted to: an
# identity granted WRITE pushes to it, one granted READ pulls from it; those
# edges are lowered by the shape's grant rows, like every other edge. The
# roles per shape are in shapes.mojo.
#
#   * registry -> `<id>/registry`: the field `format` (`OCI`, the one format
#                 of this version), and `out.ADDRESS` = `registry.fake/<id>`
#                 (`<id>` is the author's cloud name when one is written;
#                 the name a client pushes and pulls an image as; how the
#                 node behaves, not state: never in a digest; nodes.mojo).
# =============================================================================

from kci_reconciler import InputRef
from kci_cloud.adapter import LoweredNode, Setting
from kci_cloud.catalog import FIELD_REGISTRY
from kci_cloud.registry import format_word, registry_format
from kci_resource_proto.resource import Resource

from kci_cloud.shape.metadata import fake_physical_name
from kci_cloud.shape.shapes import ProviderShape, ROLE_REGISTRY


def fake_registry_address(resource_id: String) -> String:
    return String("registry.fake/") + resource_id


def lower_registry(r: Resource, shape: ProviderShape) raises -> List[LoweredNode]:
    """A registry's one role (see the file header)."""
    if len(r.uses) > 0:
        raise Error(String("fake: registry \"") + r.id + String("\" has uses lines; validate refuses them"))
    var fields = List[Setting]()
    fields.append(Setting(String("format"), format_word(registry_format(r))))
    var base = fake_physical_name(r)
    fields.append(Setting(String("out.ADDRESS"), fake_registry_address(base if base.byte_length() > 0 else r.id)))
    var out = List[LoweredNode]()
    out.append(
        LoweredNode(
            r.id + String("/") + String(ROLE_REGISTRY),
            r.id,
            shape.kind_of(FIELD_REGISTRY, String(ROLE_REGISTRY)),
            List[String](),
            List[InputRef](),
            fields^,
        )
    )
    return out^
