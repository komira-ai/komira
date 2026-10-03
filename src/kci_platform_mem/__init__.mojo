"""`kci_platform_mem`: the in-memory reference platforms of kci.

  * `MemPlatform` ("mem"): complete; the executable specification of a
    platform and the offline test double.
  * `MemLitePlatform` ("mem-lite"): partial (no `job`, no public ingress);
    the offline proof that a graph a platform cannot host is refused before
    anything is created.

Both deploy into a `MemCloud` (state plus a call log) and pass the
`kci_platform` conformance kit.
"""

from kci_platform_mem.mem_cloud import MemCloud
from kci_platform_mem.nodes import MemGrantNode, MemRunNode, mem_host, mem_url
from kci_platform_mem.platforms import MemLitePlatform, MemPlatform
