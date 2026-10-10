# =============================================================================
# kci_cloud_fake/fake_store.mojo: the memory a fake cloud deploys to.
# =============================================================================
#
# What exists (per engine node: its kind, digest, the URL it serves, whether
# it is in the failed state, the LABELS it carries, its provenance
# annotation, and any out-of-band value on a field kci does not model) and
# every mutating call the cloud served, in order. Shared by a cloud and the
# nodes it lowers through an `ArcPointer`, so a test can read both the state
# and the call log after a run. Nothing here is a network or a clock.
#
# IT BEHAVES LIKE A CLOUD API WHERE KCI MUST NOT ASSUME OTHERWISE:
#   * a create of a name that exists is REFUSED (`ALREADY_EXISTS`), never
#     an overwrite: that is how a second writer of the same name is seen;
#   * an update of a name that does not exist is REFUSED (`NOT_FOUND`);
#   * labels are kept exactly as written and read back exactly; an update
#     rewrites the retention mark (`kci-retention`, the label it is handed)
#     in the same call and leaves every other label as it was;
#   * an object's NAME (the author's cloud name, `names`; empty when the
#     cloud chose it) is written by the create, or by the adoption that takes
#     it over, and by nothing else: an update or a tamper never renames.
#
# THE FAULTY VARIANT (constructor arguments, each independent):
#   * `fail_at_call = k` (1-based, 0 = never): the k-th mutating call raises
#     instead of acting, once: nothing changes and nothing is logged for it,
#     as when a cloud API refuses a request. A partial apply and its recovery.
#   * `read_lag = n`: reads are eventually consistent. After a create, the
#     next n reads of that name still see it ABSENT; after a delete, the next
#     n reads still see the old object. Lists (`list_owned`) see the truth.
#   * `foreign = [names]`: objects that exist before kci ever ran, carrying
#     no kci stamp (made by hand, or by another tool).
#   * `race_next()`: the next create meets an object a second apply of the
#     same cell created a moment earlier (same name, same labels): that
#     create is served for the other writer and logged, and this one is
#     refused as ALREADY_EXISTS.
# `fail(id)` puts a present node into the failed state (a new version that
# never became ready); the next update clears it.
# =============================================================================

from kci_reconciler import Label


struct FakeView(Copyable, Movable, Deinitable):
    """What one read of a name sees."""

    var present: Bool
    var kind: String
    var digest: String
    var url: String
    var failed: Bool
    var labels: List[Label]
    var annotation: String
    var extra: String

    def __init__(out self):
        self.present = False
        self.kind = String("")
        self.digest = String("")
        self.url = String("")
        self.failed = False
        self.labels = List[Label]()
        self.annotation = String("")
        self.extra = String("")

    def __init__(out self, *, copy: Self):
        self.present = copy.present
        self.kind = copy.kind.copy()
        self.digest = copy.digest.copy()
        self.url = copy.url.copy()
        self.failed = copy.failed
        self.labels = copy.labels.copy()
        self.annotation = copy.annotation.copy()
        self.extra = copy.extra.copy()


struct FakeStore(Movable):
    var ids: List[String]
    var kinds: List[String]
    var digests: List[String]
    var urls: List[String]
    var failed: List[Bool]
    var labels: List[List[Label]]
    var annotations: List[String]
    var extras: List[String]
    var names: List[String]
    var created: List[Int]
    var calls: List[String]
    var fail_at_call: Int
    var read_lag: Int
    var raced_id: String
    var _race_next: Bool
    var _attempts: Int
    var _seq: Int
    var _hidden: List[String]
    var _hidden_left: List[Int]
    var _ghosts: List[String]
    var _ghost_views: List[FakeView]
    var _ghost_left: List[Int]

    def __init__(
        out self,
        fail_at_call: Int = 0,
        read_lag: Int = 0,
        foreign: List[String] = List[String](),
    ):
        self.ids = List[String]()
        self.kinds = List[String]()
        self.digests = List[String]()
        self.urls = List[String]()
        self.failed = List[Bool]()
        self.labels = List[List[Label]]()
        self.annotations = List[String]()
        self.extras = List[String]()
        self.names = List[String]()
        self.created = List[Int]()
        self.calls = List[String]()
        self.fail_at_call = fail_at_call
        self.read_lag = read_lag
        self.raced_id = String("")
        self._race_next = False
        self._attempts = 0
        self._seq = 0
        self._hidden = List[String]()
        self._hidden_left = List[Int]()
        self._ghosts = List[String]()
        self._ghost_views = List[FakeView]()
        self._ghost_left = List[Int]()
        for i in range(len(foreign)):
            self.plant(foreign[i], String("foreign"))

    def find(self, id: String) -> Int:
        """The TRUE state (tests and lists); reads go through `read`."""
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1

    def _view(self, i: Int) -> FakeView:
        var v = FakeView()
        v.present = True
        v.kind = self.kinds[i].copy()
        v.digest = self.digests[i].copy()
        v.url = self.urls[i].copy()
        v.failed = self.failed[i]
        v.labels = self.labels[i].copy()
        v.annotation = self.annotations[i].copy()
        v.extra = self.extras[i].copy()
        return v^

    def read(mut self, id: String) -> FakeView:
        """One read, eventually consistent under `read_lag`."""
        for h in range(len(self._hidden)):
            if self._hidden[h] == id and self._hidden_left[h] > 0:
                self._hidden_left[h] -= 1
                return FakeView()
        var i = self.find(id)
        if i >= 0:
            return self._view(i)
        for g in range(len(self._ghosts)):
            if self._ghosts[g] == id and self._ghost_left[g] > 0:
                self._ghost_left[g] -= 1
                return self._ghost_views[g].copy()
        return FakeView()

    def _admit(mut self, verb: String, id: String) raises:
        """Count one mutating call; raise, without acting, if it is the one
        the faulty variant refuses."""
        self._attempts += 1
        if self.fail_at_call > 0 and self._attempts == self.fail_at_call:
            raise Error(
                String("fake: injected fault on call ")
                + String(self._attempts)
                + String(" (")
                + verb
                + String(" ")
                + id
                + String(")")
            )

    def _insert(
        mut self,
        id: String,
        kind: String,
        digest: String,
        url: String,
        labels: List[Label],
        annotation: String,
        name: String = String(""),
    ):
        self._seq += 1
        self.ids.append(id)
        self.kinds.append(kind)
        self.digests.append(digest)
        self.urls.append(url)
        self.failed.append(False)
        self.labels.append(labels.copy())
        self.annotations.append(annotation)
        self.extras.append(String(""))
        self.names.append(name)
        self.created.append(self._seq)
        for g in range(len(self._ghosts)):
            if self._ghosts[g] == id:
                self._ghost_left[g] = 0
        if self.read_lag > 0:
            self._hidden.append(id)
            self._hidden_left.append(self.read_lag)

    def plant(mut self, id: String, kind: String):
        """An object made outside kci: no stamp, a digest kci never writes."""
        self._seq += 1
        self.ids.append(id)
        self.kinds.append(kind)
        self.digests.append(String("made-outside-kci"))
        self.urls.append(String(""))
        self.failed.append(False)
        self.labels.append(List[Label]())
        self.annotations.append(String(""))
        self.extras.append(String(""))
        self.names.append(String(""))
        self.created.append(self._seq)

    def race_next(mut self):
        self._race_next = True

    def create(
        mut self,
        id: String,
        kind: String,
        digest: String,
        url: String,
        labels: List[Label],
        annotation: String,
        name: String = String(""),
    ) raises:
        self._admit(String("create"), id)
        if self._race_next:
            # The second apply's create of the same name lands first.
            self._race_next = False
            self.raced_id = id
            if self.find(id) < 0:
                self._insert(id, kind, digest, url, labels, annotation, name)
                self.calls.append(String("create ") + id)
        if self.find(id) >= 0:
            raise Error(String("fake: ALREADY_EXISTS: ") + id)
        self._insert(id, kind, digest, url, labels, annotation, name)
        self.calls.append(String("create ") + id)

    def update(mut self, id: String, digest: String, url: String, retention: Label) raises:
        self._admit(String("update"), id)
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: NOT_FOUND: ") + id)
        self.calls.append(String("update ") + id)
        self.digests[i] = digest
        self.urls[i] = url
        self.failed[i] = False
        var kept = List[Label]()
        for k in range(len(self.labels[i])):
            if self.labels[i][k].key != retention.key:
                kept.append(self.labels[i][k].copy())
        kept.append(retention.copy())
        self.labels[i] = kept^

    def relabel(mut self, id: String, labels: List[Label], annotation: String, name: String = String("")) raises:
        """Stamp an object (an adoption): its labels, its annotation, and
        the name the adopting node knows it by."""
        self._admit(String("relabel"), id)
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: NOT_FOUND: ") + id)
        self.calls.append(String("relabel ") + id)
        self.labels[i] = labels.copy()
        self.annotations[i] = annotation
        self.names[i] = name

    def remove(mut self, id: String) raises:
        """Idempotent: removing what is not there is a no-op, but still a
        served call."""
        self._admit(String("delete"), id)
        self.calls.append(String("delete ") + id)
        var i = self.find(id)
        if i < 0:
            return
        if self.read_lag > 0:
            self._ghosts.append(id)
            self._ghost_views.append(self._view(i))
            self._ghost_left.append(self.read_lag)
        for h in range(len(self._hidden)):
            if self._hidden[h] == id:
                self._hidden_left[h] = 0
        _ = self.ids.pop(i)
        _ = self.kinds.pop(i)
        _ = self.digests.pop(i)
        _ = self.urls.pop(i)
        _ = self.failed.pop(i)
        _ = self.labels.pop(i)
        _ = self.annotations.pop(i)
        _ = self.extras.pop(i)
        _ = self.names.pop(i)
        _ = self.created.pop(i)

    def tamper(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: cannot tamper with absent node ") + id)
        self.digests[i] = String("changed-out-of-band")

    def tamper_unmodelled(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: cannot tamper with absent node ") + id)
        self.extras[i] = String("team=payments")

    def fail(mut self, id: String) raises:
        var i = self.find(id)
        if i < 0:
            raise Error(String("fake: cannot fail absent node ") + id)
        self.failed[i] = True

    def creates_of(self, id: String) -> Int:
        var n = 0
        var want = String("create ") + id
        for i in range(len(self.calls)):
            if self.calls[i] == want:
                n += 1
        return n
