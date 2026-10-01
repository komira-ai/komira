# =============================================================================
# komira_svcref — the service-reference primitive. Service-name -> URL over a
#   compare-and-swap object store, plus a TTL-cached read-through lookup client.
# =============================================================================
#
# A replacement for DNS / load-balancer discovery: a service registers the URL
# it serves under its LOGICAL name at deploy time (`ServiceRegistry`), and peers
# resolve `name -> URL` from the same bucket every node reads at boot
# (`ServiceResolver`, TTL-cached). One object per service on the CAS object
# store, keyed by name, so registrations of different services never contend.
#
# Depends ONLY on `komira_objectstore` (the `ConditionalWriteStore` seam +
# Path / WritePrecondition types): no DB, no HTTP, no proto. Encapsulation:
# the surface is `String` / `Optional[String]` / `List[String]` in and out;
# no UnsafePointer crosses any boundary.
# =============================================================================

from komira_svcref.service_registry import (
    ServiceRegistry,
    ServiceResolver,
)

# The REAPING half: the orphan report value types + the pure catalog/live
# diff. `ServiceRegistry.orphan_scan` / `reap_orphans` return these; the diff is
# re-exported so a caller that already holds both name lists can report without
# a second read of the bucket.
from komira_svcref.orphan_reap import (
    OrphanReport,
    ReapOutcome,
    orphan_report,
    refuse_untrustworthy_live_set,
)
