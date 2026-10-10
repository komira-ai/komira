# =============================================================================
# kci_cloud/values.mojo: the checks of a configuration VALUE (`Value`), true on
# every cloud.
# =============================================================================
#
# A `Value` is a literal, a release machine parameter or a `Ref` to an output
# another resource produces. Validate refuses (`check_value`):
#   * a parameter: parameters are substituted before a cloud sees the graph,
#     so one left is unresolved;
#   * a `Value` with no arm;
#   * a `Ref` (`check_value_ref`) that names its own resource, names no
#     resource of the list, asks for a named output (only the escape hatch,
#     which this kci does not have, has those), asks for no output, or asks
#     for an output the producer's type does not expose.
# Used for `env` of every workload (compute.mojo) and for the
# values of a DNS record (dns.mojo).
# =============================================================================

from kci_resource_proto.refs import Ref, Value
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import FINDING_GRAPH, Finding
from kci_cloud.catalog import Catalog, body_field


def _index_of_id(resources: List[Resource], id: String) -> Int:
    for i in range(len(resources)):
        if resources[i].id == id:
            return i
    return -1


def check_value_ref(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    path: String,
    r: Ref,
    mut out: List[Finding],
):
    """A `Ref` used as a VALUE: it must name another resource of the list and
    one of the outputs that resource's type exposes."""
    if r.resource == owner:
        out.append(
            Finding(FINDING_GRAPH, owner, path, String("refers to its own resource"))
        )
        return
    var p = _index_of_id(resources, r.resource)
    if p < 0:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("ref to missing resource \"") + r.resource + String("\""),
            )
        )
        return
    if r._oneof0_case == 2:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String(
                    "a named output is only for the escape hatch, which this kci"
                    " does not have"
                ),
            )
        )
        return
    if r._oneof0_case != 1:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("a value ref must name an output of \"")
                + r.resource
                + String("\""),
            )
        )
        return
    var output = r.standard.value().json_name()
    var field: Int
    try:
        field = body_field(resources[p])
    except:
        return  # the producer's own missing type is reported on the producer
    var t = catalog.index_of(field)
    if t < 0 or not catalog.types[t].exposes_output(output):
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("\"")
                + r.resource
                + String("\" (")
                + catalog.name_of(field)
                + String(") does not expose ")
                + output,
            )
        )


def check_value(
    catalog: Catalog,
    resources: List[Resource],
    owner: String,
    path: String,
    v: Value,
    mut out: List[Finding],
):
    var arm = v._oneof0_case
    if arm == 1:
        return
    if arm == 3:
        check_value_ref(catalog, resources, owner, path, v.ref_.value(), out)
        return
    if arm == 2:
        out.append(
            Finding(
                FINDING_GRAPH,
                owner,
                path,
                String("release parameter \"")
                + v.param.value()
                + String(
                    "\" is unresolved; parameters are substituted before a cloud"
                    " sees the graph"
                ),
            )
        )
        return
    out.append(Finding(FINDING_GRAPH, owner, path, String("has no value")))
