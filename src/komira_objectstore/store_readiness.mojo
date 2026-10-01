# =============================================================================
# komira_objectstore/store_readiness.mojo — "is this object store actually
#   reachable?", the READINESS predicate an object-store-backed app answers
#   `GET /healthz` with.
# =============================================================================
#
# WHY THIS EXISTS. An HTTP surface that keeps its durable state in an object
# store must not answer `GET /healthz` with an UNCONDITIONAL 200 that touches no
# store: behind a platform startup probe at that path, an app whose bucket does
# not exist — or whose runtime identity cannot read it — would go Ready, take
# traffic, and only fail on the first real request. This is the predicate such a
# surface answers `/healthz` with instead.
#
# ★ NOT A SUBSTITUTE FOR PROVISIONING. Creating the bucket is the deployer's job.
# What THIS predicate asserts is that the provisioning actually TOOK on THIS
# revision: create skipped/failed, wrong project, missing read grant, stale
# credentials, DNS/TLS failure, backend 5xx.
#
# ★ WHY `list_with_delimiter` AND NOT `head` — THE WHOLE POINT OF THIS MODULE.
# A `head` on a sentinel OBJECT cannot distinguish the two cases that matter:
#
#     bucket exists, object absent   -> 404
#     bucket does NOT exist          -> 404
#
# A conformer that maps both to the same "absent" signal (or that raises on both)
# makes readiness either blind or useless. A LIST scoped to a prefix separates them
# cleanly at the protocol level: GCS answers a list against a MISSING bucket with a
# bucket-level NOT_FOUND / PERMISSION_DENIED error, while a list against an existing
# bucket under a prefix that happens to hold nothing is a perfectly successful EMPTY
# page. So: an error means NOT READY, an empty result means READY. That distinction is
# the check that catches an un-provisioned bucket.
#
# ★ WHY A SENTINEL PREFIX, AND WHY IT IS NOT OPTIONAL. `ObjectStore
# .list_with_delimiter(prefix)` DRAINS EVERY PAGE (the GCS conformer loops to a
# 100_000-page cap). Listing a broad prefix on a
# populated bucket would therefore issue thousands of RPCs per probe. The sentinel
# prefix below is written by NO code path in any app, so the listing is guaranteed to
# return ONE empty page => EXACTLY ONE round-trip, with no data dependency (readiness
# never depends on the app holding any content) and no dependence on bucket size.
# Do not "generalise" this to the app's real prefix.
#
# NOT CACHED, deliberately. The cost is already ONE list per call, and the caller
# set of `/healthz` is bounded: a platform startup probe (period in seconds, and it
# stops once the revision is Ready) plus, at most, a deploy-time HTTP check. No
# user request path touches it. Adding a cache would need mutable per-app state —
# cost with no benefit.
#
# ENCAPSULATION: generic over the `ObjectStore` base trait (so it works for every
# refinement — `ConditionalWriteStore`, `CloneableConditionalWriteStore` — and for
# LocalFs / InMemory / GCS alike). Takes the store by `read` ref, returns a plain
# `Bool`, NEVER raises (the whole point is to convert a store error into a verdict),
# and holds no state. No UnsafePointer, no wildcard origin.
# =============================================================================

from .path import Path
from .store import ObjectStore


# The prefix the readiness listing is scoped to. NEVER written by any app: apps key
# their data under their own prefixes (for example `rooms/`, `calendars/` or
# `<repo>.git/`). The leading+trailing `__` make an
# accidental collision with a future app's real prefix implausible rather than merely
# unlikely. So this list is guaranteed to come back EMPTY in ONE page on a healthy
# bucket => exactly one round-trip, zero data dependency.
#
# The trailing `/` is the directory hint `Path.parse` preserves, so the listing is a
# hierarchical (delimiter) list under a single synthetic folder rather than a bucket
# scan.
comptime STORE_READINESS_PROBE_PREFIX: String = "__komira_readiness_probe__/"


def object_store_reachable[S: ObjectStore](imm store: S) -> Bool:
    """READINESS: `True` iff `store`'s backing bucket/container is reachable AND the
    caller is authorized to list it; `False` on ANY failure.

    ONE hierarchical listing under `STORE_READINESS_PROBE_PREFIX` — a prefix nothing
    writes, so a healthy store answers with a single EMPTY page (one round-trip) and
    only a real fault (bucket missing, wrong project, no objectAdmin/objectViewer,
    bad credentials, DNS/TLS failure, 5xx) raises.

    NEVER RAISES. Every error — including a malformed-path error from `Path.parse`,
    which cannot happen for the constant above but is caught anyway so this function
    is total — collapses to `False`. A readiness probe that can raise would turn a
    "not ready" into a 500 and lose the distinction the caller needs.

    An EMPTY result is READY, not "not ready": absence of objects is the expected
    answer for a prefix nothing writes. Only the ERROR channel signals unreachable.
    See the module header for why this is a LIST and not a `head`."""
    try:
        _ = store.list_with_delimiter(
            Path.parse(STORE_READINESS_PROBE_PREFIX)
        )
        return True
    except:
        return False
