# =============================================================================
# test_described_resource_envelopes.mojo — the descriptor driver's envelopes
# and forwards.
# =============================================================================
#
# What is pinned, each a separate test, driving `DescribedResource` directly:
#
#   1. THE READ ENVELOPE (`read_status`, `read_presence`, and the re-read in
#      `outputs` after a mutation): a not-found is ABSENT (no outputs), a read
#      that finds nothing is ABSENT, and ANY OTHER RAISE PROPAGATES — an
#      AccessDenied is never laundered into "absent". `read_presence` reports
#      a present object with an empty digest and never digests.
#   2. THE DELETE ENVELOPE: a not-found is a no-op; any other raise
#      propagates.
#   3. THE DESCRIPTOR DEFAULTS reach the driver: no undeletable reason, an
#      unclassified fault domain, no ownership stamping, and create_owned /
#      adopt_owned refuse; no references, a no-op bind, and wanted.
#   4. THE DRIVER FORWARDS EACH OF THOSE to a descriptor that overrides it.
#   5. A DESCRIPTOR THAT LEAVES `outputs` AT THE DEFAULT produces no value.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from kci_reconciler import (
    ResourceStatus,
    Creds,
    CellScope,
    OwnerStamp,
    Outputs,
    ResolvedInputs,
    RES_ABSENT,
    RES_PRESENT_DRIFTED,
    RES_PRESENT_MATCHED,
    RETAIN_DELETE,
    RETAIN_UNDELETABLE,
    FAULT_UNSET,
    FAULT_USER,
)
from kci_reconciler.described_resource import ResourceDescriptor, DescribedResource


# What the next read does.
comptime _FOUND = 0
comptime _NOT_FOUND = 1
comptime _DENIED = 2
comptime _EMPTY = 3


struct _Log(Movable):
    var read_mode: Int
    var delete_mode: Int
    var digest_raises: Bool
    var calls: List[String]

    def __init__(out self):
        self.read_mode = _FOUND
        self.delete_mode = _FOUND
        self.digest_raises = False
        self.calls = List[String]()


struct _Spec(Copyable, Movable, Deinitable):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    def __init__(out self, *, copy: Self):
        self.name = copy.name.copy()


struct _View(Copyable, Movable, Deinitable):
    var found: Bool
    var url: String

    def __init__(out self, found: Bool, url: String):
        self.found = found
        self.url = url

    def __init__(out self, *, copy: Self):
        self.found = copy.found
        self.url = copy.url.copy()


def _read(mut log: ArcPointer[_Log], spec: _Spec) raises -> _View:
    log[].calls.append(String("read"))
    if log[].read_mode == _NOT_FOUND:
        raise Error(String("NotFound: ") + spec.name)
    if log[].read_mode == _DENIED:
        raise Error(String("AccessDenied: cannot read ") + spec.name)
    if log[].read_mode == _EMPTY:
        return _View(False, String(""))
    return _View(True, String("https://") + spec.name + String(".example.com"))


def _delete(mut log: ArcPointer[_Log], physical_id: String) raises:
    log[].calls.append(String("delete ") + physical_id)
    if log[].delete_mode == _NOT_FOUND:
        raise Error(String("NotFound: ") + physical_id)
    if log[].delete_mode == _DENIED:
        raise Error(String("Throttling: slow down"))


struct _Plain(ResourceDescriptor, Movable, Deinitable):
    """Only the required verbs: every default is the trait's."""

    comptime Spec = _Spec
    comptime View = _View

    var _log: ArcPointer[_Log]

    def __init__(out self, log: ArcPointer[_Log]):
        self._log = log.copy()

    def read(mut self, spec: _Spec, token: String) raises -> _View:
        return _read(self._log, spec)

    def is_not_found(self, msg: String) -> Bool:
        return msg.startswith("NotFound")

    def exists(self, view: _View) -> Bool:
        return view.found

    def physical_id(self, view: _View) -> String:
        return view.url

    def desired_digest(self, spec: _Spec) raises -> String:
        if self._log[].digest_raises:
            raise Error("a digest was taken")
        return spec.name.copy()

    def live_digest(self, spec: _Spec, view: _View) raises -> String:
        if self._log[].digest_raises:
            raise Error("a digest was taken")
        return spec.name.copy()

    def retention(self, spec: _Spec) -> Int:
        return RETAIN_DELETE

    def reason(self, spec: _Spec, verb: Int, live: ResourceStatus) raises -> String:
        return String("")

    def create(mut self, spec: _Spec, token: String) raises -> String:
        self._log[].calls.append(String("create"))
        return String("https://") + spec.name + String(".example.com")

    def update(mut self, spec: _Spec, token: String) raises:
        pass

    def delete(mut self, spec: _Spec, physical_id: String, token: String) raises:
        _delete(self._log, physical_id)

    def outputs(self, spec: _Spec, view: _View) -> Outputs:
        var o = Outputs()
        o.set(String("URL"), view.url)
        return o^


struct _Stamping(ResourceDescriptor, Movable, Deinitable):
    """Overrides every default the driver forwards."""

    comptime Spec = _Spec
    comptime View = _View

    var _log: ArcPointer[_Log]

    def __init__(out self, log: ArcPointer[_Log]):
        self._log = log.copy()

    def read(mut self, spec: _Spec, token: String) raises -> _View:
        return _read(self._log, spec)

    def is_not_found(self, msg: String) -> Bool:
        return msg.startswith("NotFound")

    def exists(self, view: _View) -> Bool:
        return view.found

    def physical_id(self, view: _View) -> String:
        return view.url

    def desired_digest(self, spec: _Spec) raises -> String:
        return spec.name.copy()

    def live_digest(self, spec: _Spec, view: _View) raises -> String:
        return spec.name.copy()

    def retention(self, spec: _Spec) -> Int:
        return RETAIN_UNDELETABLE

    def reason(self, spec: _Spec, verb: Int, live: ResourceStatus) raises -> String:
        return String("")

    def create(mut self, spec: _Spec, token: String) raises -> String:
        return String("")

    def update(mut self, spec: _Spec, token: String) raises:
        pass

    def delete(mut self, spec: _Spec, physical_id: String, token: String) raises:
        pass

    def undeletable_reason(self, spec: _Spec) -> String:
        return String("deleting ") + spec.name + String(" deletes every image in it")

    def fault_domain(mut self, spec: _Spec, verb: String) raises -> Int:
        if verb == "create":
            return FAULT_USER
        return FAULT_UNSET

    def stamps_ownership(self) -> Bool:
        return True

    def create_owned(mut self, spec: _Spec, stamp: OwnerStamp, token: String) raises -> String:
        self._log[].calls.append(String("create_owned ") + stamp.identity())
        return String("pid-") + spec.name

    def adopt_owned(
        mut self, spec: _Spec, stamp: OwnerStamp, physical_id: String, token: String
    ) raises:
        self._log[].calls.append(String("adopt ") + physical_id + String(" ") + stamp.identity())


def _plain(log: ArcPointer[_Log]) -> DescribedResource[_Plain]:
    return DescribedResource[_Plain](_Plain(log), _Spec(String("repo")), String("repo"), List[String]())


def _err_read_status(mut n: DescribedResource[_Plain]) -> String:
    try:
        _ = n.read_status(Creds.none())
    except e:
        return String(e)
    return String("")


def _err_read_presence(mut n: DescribedResource[_Plain]) -> String:
    try:
        _ = n.read_presence(Creds.none())
    except e:
        return String(e)
    return String("")


def _err_outputs(mut n: DescribedResource[_Plain]) -> String:
    try:
        _ = n.outputs(String("pid"), Creds.none())
    except e:
        return String(e)
    return String("")


def _err_delete(mut n: DescribedResource[_Plain]) -> String:
    try:
        n.delete(String("pid-repo"), Creds.none())
    except e:
        return String(e)
    return String("")


# ---- 1. the read envelope ---------------------------------------------------------


def test_read_status_envelope() raises:
    var log = ArcPointer[_Log](_Log())
    var n = _plain(log)
    assert_equal(n.read_status(Creds.none()).phase, RES_PRESENT_MATCHED)
    log[].read_mode = _NOT_FOUND
    assert_equal(n.read_status(Creds.none()).phase, RES_ABSENT)
    log[].read_mode = _EMPTY
    log[].digest_raises = True
    assert_equal(n.read_status(Creds.none()).phase, RES_ABSENT, "an empty read is absent, undigested")
    log[].digest_raises = False
    log[].read_mode = _DENIED
    assert_equal(_err_read_status(n), "AccessDenied: cannot read repo")
    print("  test_read_status_envelope: PASS")


def test_read_presence_envelope() raises:
    var log = ArcPointer[_Log](_Log())
    var n = _plain(log)
    log[].digest_raises = True
    var live = n.read_presence(Creds.none())
    assert_equal(live.phase, RES_PRESENT_DRIFTED)
    assert_equal(live.physical_id, "https://repo.example.com")
    assert_equal(live.live_digest, "")
    log[].digest_raises = False
    log[].read_mode = _NOT_FOUND
    assert_equal(n.read_presence(Creds.none()).phase, RES_ABSENT)
    log[].read_mode = _EMPTY
    assert_equal(n.read_presence(Creds.none()).phase, RES_ABSENT)
    log[].read_mode = _DENIED
    assert_equal(_err_read_presence(n), "AccessDenied: cannot read repo")
    print("  test_read_presence_envelope: PASS")


def test_outputs_after_a_mutation_reread_through_the_envelope() raises:
    var log = ArcPointer[_Log](_Log())
    var n = _plain(log)
    # Each create drops the last view, so `outputs` reads again.
    _ = n.create(Creds.none())
    log[].read_mode = _NOT_FOUND
    assert_equal(n.outputs(String("pid"), Creds.none()).count(), 0, "not found: none")
    _ = n.create(Creds.none())
    log[].read_mode = _EMPTY
    assert_equal(n.outputs(String("pid"), Creds.none()).count(), 0, "empty read: none")
    _ = n.create(Creds.none())
    log[].read_mode = _DENIED
    assert_equal(_err_outputs(n), "AccessDenied: cannot read repo")
    _ = n.create(Creds.none())
    log[].read_mode = _FOUND
    var o = n.outputs(String("pid"), Creds.none())
    assert_equal(o.count(), 1)
    assert_equal(o.get(String("URL")).value(), "https://repo.example.com")
    print("  test_outputs_after_a_mutation_reread_through_the_envelope: PASS")


# ---- 2. the delete envelope -------------------------------------------------------


def test_delete_envelope() raises:
    var log = ArcPointer[_Log](_Log())
    var n = _plain(log)
    log[].delete_mode = _NOT_FOUND
    assert_equal(_err_delete(n), "", "an already-gone object is a no-op")
    log[].delete_mode = _DENIED
    assert_equal(_err_delete(n), "Throttling: slow down")
    assert_equal(len(log[].calls), 2)
    print("  test_delete_envelope: PASS")


# ---- 3. the descriptor defaults ------------------------------------------------------


def test_descriptor_defaults_reach_the_driver() raises:
    var log = ArcPointer[_Log](_Log())
    var n = _plain(log)
    assert_equal(n.undeletable_reason(), "")
    assert_equal(n.fault_domain(String("create")), FAULT_UNSET)
    assert_false(n.stamps_ownership())
    var stamp = CellScope(String("shop"), String("blue")).stamp(String("repo"), String("repo"))
    var created = String("")
    try:
        _ = n.create_owned(stamp, Creds.none())
    except e:
        created = String(e)
    assert_equal(created, "this descriptor does not stamp ownership")
    var adopted = String("")
    try:
        n.adopt_owned(stamp, String("pid-repo"), Creds.none())
    except e:
        adopted = String(e)
    assert_equal(adopted, "this descriptor cannot adopt an existing object")
    assert_equal(len(n.input_refs()), 0, "no references by default")
    n.bind_inputs(ResolvedInputs())
    assert_true(n.wanted(), "wanted by default")
    print("  test_descriptor_defaults_reach_the_driver: PASS")


def test_a_descriptor_without_outputs_produces_none() raises:
    # `_Stamping` leaves `outputs` at the default: a found object still
    # produces no named value.
    var log = ArcPointer[_Log](_Log())
    var n = DescribedResource[_Stamping](
        _Stamping(log), _Spec(String("images")), String("images/repo"), List[String]()
    )
    assert_equal(n.read_status(Creds.none()).phase, RES_PRESENT_MATCHED)
    assert_equal(n.outputs(String("pid"), Creds.none()).count(), 0)
    print("  test_a_descriptor_without_outputs_produces_none: PASS")


# ---- 4. the forwards ----------------------------------------------------------------


def test_the_driver_forwards_each_override() raises:
    var log = ArcPointer[_Log](_Log())
    var n = DescribedResource[_Stamping](
        _Stamping(log), _Spec(String("images")), String("images/repo"), List[String](), String("images")
    )
    assert_equal(n.retention(), RETAIN_UNDELETABLE)
    assert_equal(n.undeletable_reason(), "deleting images deletes every image in it")
    assert_equal(n.fault_domain(String("create")), FAULT_USER)
    assert_equal(n.fault_domain(String("update")), FAULT_UNSET)
    assert_true(n.stamps_ownership())
    var stamp = CellScope(String("shop"), String("blue")).stamp(String("images"), String("images/repo"))
    assert_equal(n.create_owned(stamp, Creds.none()), "pid-images")
    n.adopt_owned(stamp, String("pid-old"), Creds.none())
    assert_equal(len(log[].calls), 2)
    assert_equal(log[].calls[0], "create_owned kci:v1 owner=shop/blue/images/repo")
    assert_equal(log[].calls[1], "adopt pid-old kci:v1 owner=shop/blue/images/repo")
    print("  test_the_driver_forwards_each_override: PASS")


def main() raises:
    print("test_described_resource_envelopes:")
    test_read_status_envelope()
    test_read_presence_envelope()
    test_outputs_after_a_mutation_reread_through_the_envelope()
    test_delete_envelope()
    test_descriptor_defaults_reach_the_driver()
    test_the_driver_forwards_each_override()
    test_a_descriptor_without_outputs_produces_none()
    print("ALL DESCRIPTOR ENVELOPE TESTS PASSED")
