# =============================================================================
# kci_cloud/registry.mojo: the rules of the REGISTRY primitive.
# =============================================================================
#
# A `registry` is a private store of artifacts of one format. GRAPH findings,
# true on every cloud, that validate collects for a registry
# (`registry_findings`):
#   * a registry runs as no identity, so it has no `uses` lines (write the
#     line on the workload that pushes to it or pulls from it);
#   * its `format` is written: an unset format is refused, never read as a
#     default, so a stored list always says what its registry holds;
#   * its `format` is one this kci knows (OCI): a number from a later schema
#     is refused rather than lowered as something else.
#
# Who may push (WRITE) and pull (READ) is a grant like any other: the
# catalog row lists the verbs, and validate's edge rules refuse any other.
# =============================================================================

from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import FIELD_REGISTRY


comptime FORMAT_OCI: Int = 1
"""`kci.resource.v1.OCI`: container images and the other artifacts an OCI
distribution client pushes and pulls."""


def format_word(format: Int) -> String:
    """The name of a declared format (`OCI`), else the bare number."""
    if format == FORMAT_OCI:
        return String("OCI")
    return String(format)


def registry_format(r: Resource) -> Int:
    """The `format` number of the registry `r`, or 0 for any other type."""
    if not r.registry:
        return 0
    return r.registry.value().format.value


def registry_findings(field: Int, r: Resource) -> List[Finding]:
    """Every graph finding of the registry `r` (by its body `field`); empty
    for any other type."""
    var out = List[Finding]()
    if field != FIELD_REGISTRY:
        return out^
    if len(r.uses) > 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("uses"),
                String(
                    "a registry runs as no identity, so it cannot use another resource;"
                    " write the uses line on the workload that pushes to it or pulls from it"
                ),
            )
        )
    var format = registry_format(r)
    if format == 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("registry.format"),
                String("no format: a registry names the format of what it holds (OCI)"),
            )
        )
    elif format != FORMAT_OCI:
        out.append(
            Finding(
                FINDING_GRAPH,
                r.id,
                String("registry.format"),
                String("format ") + String(format) + String(" is not a format this kci knows (OCI)"),
            )
        )
    return out^
