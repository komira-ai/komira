"""`kci_cloud_mem`: the in-memory reference clouds of kci.

  * `MemCloud` ("mem"): complete; the executable specification of a
    cloud and the offline test double.
  * `MemLiteCloud` ("mem-lite"): partial (no `job`, no public ingress);
    the offline proof that a graph a cloud cannot host is refused before
    anything is created.

Both lower to data (the complete fixed set of roles of each type), realize
one node type (`MemNode`), deploy into a `MemStore` (state, labels as
written, a failed flag per node, unmodelled values and a call log), honour
the ownership labels (every object born stamped by the standard label
rule, read back exactly, listed per cell), and pass the `kci_cloud`
conformance kit. The faulty variant is built from constructor arguments:
`fail_at_call = k` (the k-th mutating call is refused once), `read_lag = n`
(reads lag every create and delete by n reads) and `foreign = [names]`
(objects made outside kci before it ran); the kit's race hook makes the next
create meet a second apply's object.
"""

from kci_cloud_mem.mem_store import MemStore, MemView
from kci_cloud_mem.nodes import MemNode, mem_host, mem_url, static_digest
from kci_cloud_mem.clouds import MemLiteCloud, MemCloud
