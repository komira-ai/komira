# =============================================================================
# kci_cloud_mem/mem_store.mojo: the memory a reference cloud deploys to.
# =============================================================================
#
# What exists (per engine node: its digest, the URL it serves, and whether
# it is in the failed state) and every mutating call the cloud served, in
# order. Shared by a cloud and the nodes it lowers through an `ArcPointer`,
# so a test can read both the state and the call log after a run. Nothing
# here is a network or a clock.
#
# THE FAULTY VARIANT. `fail_at_call = k` (1-based, 0 = never) makes the k-th
# mutating call raise instead of acting, once: nothing changes and nothing is
# logged for it, as when a cloud API refuses a request. It is how a partial
# apply (some nodes landed, the rest pending) and its recovery are tested
# offline. `fail(id)` puts a present node into the failed state (a new
# version that never became ready); the next create or update clears it.
# =============================================================================


struct MemStore(Movable):
    var ids: List[String]
    var digests: List[String]
    var urls: List[String]
    var failed: List[Bool]
    var calls: List[String]
    var fail_at_call: Int
    var _attempts: Int

    def __init__(out self, fail_at_call: Int = 0):
        self.ids = List[String]()
        self.digests = List[String]()
        self.urls = List[String]()
        self.failed = List[Bool]()
        self.calls = List[String]()
        self.fail_at_call = fail_at_call
        self._attempts = 0

    def find(self, id: String) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def is_failed(self, i: Int) -> Bool:
        return self.failed[i]

    def _admit(mut self, verb: String, id: String) raises:
        """Count one mutating call; raise, without acting, if it is the one
        the faulty variant refuses."""
        self._attempts += 1
        if self.fail_at_call > 0 and self._attempts == self.fail_at_call:
            raise Error(
                String("mem: injected fault on call ")
                + String(self._attempts)
                + String(" (")
                + verb
                + String(" ")
                + id
                + String(")")
            )

    def put(mut self, verb: String, id: String, digest: String, url: String) raises:
        self._admit(verb, id)
        self.calls.append(verb + String(" ") + id)
        var i = self.find(id)
        if i < 0:
            self.ids.append(id)
            self.digests.append(digest)
            self.urls.append(url)
            self.failed.append(False)
        else:
            self.digests[i] = digest
            self.urls[i] = url
            self.failed[i] = False

    def remove(mut self, id: String) raises:
        """Idempotent: removing what is not there is a no-op, but still a
        served call."""
        self._admit(String("delete"), id)
        self.calls.append(String("delete ") + id)
        var i = self.find(id)
        if i < 0:
            return
        _ = self.ids.pop(i)
        _ = self.digests.pop(i)
        _ = self.urls.pop(i)
        _ = self.failed.pop(i)

    def tamper(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("mem: cannot tamper with absent node ") + id)
        self.digests[i] = String("changed-out-of-band")

    def fail(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("mem: cannot fail absent node ") + id)
        self.failed[i] = True
