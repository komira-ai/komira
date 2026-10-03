# =============================================================================
# kci_platform_mem/mem_cloud.mojo: the memory a reference platform deploys to.
# =============================================================================
#
# What exists (per engine node: its digest and the URL it serves) and every
# mutating call the platform served, in order. Shared by a platform and the
# nodes it lowers through an `ArcPointer`, so a test can read both the state
# and the call log after a run. Nothing here is a network or a clock.
# =============================================================================


struct MemCloud(Movable):
    var ids: List[String]
    var digests: List[String]
    var urls: List[String]
    var calls: List[String]

    def __init__(out self):
        self.ids = List[String]()
        self.digests = List[String]()
        self.urls = List[String]()
        self.calls = List[String]()

    def find(self, id: String) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def put(mut self, verb: String, id: String, digest: String, url: String):
        self.calls.append(verb + String(" ") + id)
        var i = self.find(id)
        if i < 0:
            self.ids.append(id)
            self.digests.append(digest)
            self.urls.append(url)
        else:
            self.digests[i] = digest
            self.urls[i] = url

    def remove(mut self, id: String):
        """Idempotent: removing what is not there is a no-op, but still a
        served call."""
        self.calls.append(String("delete ") + id)
        var i = self.find(id)
        if i < 0:
            return
        _ = self.ids.pop(i)
        _ = self.digests.pop(i)
        _ = self.urls.pop(i)

    def tamper(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("mem: cannot tamper with absent node ") + id)
        self.digests[i] = String("changed-out-of-band")
