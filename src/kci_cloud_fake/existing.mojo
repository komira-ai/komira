# =============================================================================
# kci_cloud_fake/existing.mojo: what the fake clouds read for an adoption,
#   and how they release an object.
# =============================================================================
#
# `read_existing` (kci_cloud's safe adoption reads it before planning) is one
# READ of the object at a node, eventually consistent like every read of the
# fake (`FakeStore.read`): present or not, whether it carries a complete kci
# stamp (any identity), its kind, the cloud name it stands under, and the
# fields of its shape the fake can read: every `name=value` of its stored
# digest (`kind|name=value|...`, how the fake keeps an object's state), in
# order. A value that holds `|` is not readable this way; no fake field
# writes one. `release` drops every kci label of the object, by its physical
# id (the node id: the fake keeps every object at its node id), and changes
# nothing else.
#
# `planted_like` is the object an adoption expects: the state, kind and name
# a node declares, built the way the node builds its own digest
# (`static_digest`), so an apply that adopts it finds it matched.
# =============================================================================

from std.memory import ArcPointer

from kci_reconciler import Creds
from kci_cloud import ExistingObject, LoweredNode, OwnedRecord, Setting, standard_identity_of

from kci_cloud_fake.fake_store import FakeStore
from kci_cloud_fake.nodes import static_digest


def digest_fields(digest: String) -> List[Setting]:
    """Every `name=value` of a stored digest after its kind, in order."""
    var out = List[Setting]()
    var parts = digest.split("|")
    for i in range(1, len(parts)):
        var part = String(parts[i])
        var at = part.find("=")
        if at <= 0:
            continue
        out.append(Setting(String(part[byte=0:at]), String(part[byte = at + 1 : part.byte_length()])))
    return out^


def read_existing(store: ArcPointer[FakeStore], node: LoweredNode) -> ExistingObject:
    """One read of the object at `node` (the file header)."""
    var v = store[].read(node.id)
    if not v.present:
        return ExistingObject()
    return ExistingObject(
        True,
        standard_identity_of(v.labels).byte_length() > 0,
        v.kind.copy(),
        v.name.copy(),
        digest_fields(v.digest),
    )


def release(store: ArcPointer[FakeStore], record: OwnedRecord) raises:
    """Drop every kci label of the object `record` names."""
    store[].release(record.id)


def planted_like(store: ArcPointer[FakeStore], node: LoweredNode) raises:
    """Plant, unstamped, the object `node` declares: its kind, its state as
    the node renders it, and its cloud name."""
    store[].plant_object(node.id, node.kind, static_digest(node), node.field(String("physical_name")))
