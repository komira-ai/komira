"""`kci_cloud_mem`: the in-memory reference clouds of kci.

  * `MemCloud` ("mem"): complete; the executable specification of a
    cloud and the offline test double.
  * `MemLiteCloud` ("mem-lite"): partial (no `job`, no public ingress);
    the offline proof that a graph a cloud cannot host is refused before
    anything is created.

Both deploy into a `MemStore` (state, a failed flag per node and a call
log) and pass the `kci_cloud` conformance kit. `fail_at_call = k` builds
the faulty variant: the k-th mutating call is refused once, which is how a
partial apply and its recovery are tested offline.
"""

from kci_cloud_mem.mem_store import MemStore
from kci_cloud_mem.nodes import MemGrantNode, MemRunNode, mem_host, mem_url
from kci_cloud_mem.clouds import MemLiteCloud, MemCloud
