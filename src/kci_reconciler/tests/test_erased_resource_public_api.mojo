# =============================================================================
# kci_reconciler/tests/test_erased_resource_public_api.mojo — `ErasedResource`
#   has ONE public way in, `erase[R](resource^)`, and no pointer type in its
#   public API.
# =============================================================================
#
# The rule: an untracked-origin pointer type may appear only in a function body
# and in a private signature or field. `ErasedResource`'s constructor takes the
# type-erased home and 22 fn-ptrs whose types expand to
# `UnsafePointer[UInt8, MutUntrackedOrigin]`, so that constructor must be private.
#
# §A drives a concrete conformer through `ErasedResource.erase` ONLY, and checks
#    that every verb this file touches reaches the conformer (a verb whose value
#    differs from the trait default, so a missing forward reads as the default).
# §B reads erased_resource.mojo and checks the shape that keeps the constructor
#    private: `*` first, then only underscore-named parameters; `erase` exists;
#    and no public `def` signature in the file names a pointer type or an
#    untracked origin.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true, assert_false

from kci_reconciler import (
    Resource,
    ResourceStatus,
    ChangeAction,
    Creds,
    ErasedResource,
    RES_PRESENT_MATCHED,
    RETAIN_KEEP,
    CONVERGE_IN_PLACE,
    VERB_UPDATE,
    FAULT_CUSTOMER,
)

comptime _SRC = "src/kci_reconciler/erased_resource.mojo"


# =============================================================================
# §A — a probe whose every answer differs from the trait default.
# =============================================================================
struct _Probe(Resource, Movable, Deinitable):
    var id: String
    var created: Int

    def __init__(out self, id: String):
        self.id = id
        self.created = 0

    def logical_id(mut self) -> String:
        return self.id

    def depends_on(mut self) -> List[String]:
        var d = List[String]()
        d.append(String("upstream"))
        return d^

    def retention(mut self) -> Int:
        return RETAIN_KEEP

    def undeletable_reason(mut self) -> String:
        return String("probe-reason")

    def read_status(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.matched(
            String("phys-") + creds.token, String("digest")
        )

    def plan(mut self, live: ResourceStatus) raises -> ChangeAction:
        return ChangeAction(self.id, VERB_UPDATE, live.physical_id, RETAIN_KEEP)

    def create(mut self, creds: Creds) raises -> String:
        self.created += 1
        return String("made-") + String(self.created)

    def update(mut self, creds: Creds) raises:
        pass

    def delete(mut self, physical_id: String, creds: Creds) raises:
        pass

    def converge_mode(mut self, live: ResourceStatus) raises -> Int:
        return CONVERGE_IN_PLACE

    def fault_domain(mut self, verb: String) raises -> Int:
        return FAULT_CUSTOMER

    def owner(mut self) -> String:
        return String("probe-owner")

    def read_presence(mut self, creds: Creds) raises -> ResourceStatus:
        return ResourceStatus.matched(String("presence"), String(""))

    def stamps_ownership(mut self) -> Bool:
        return True

    def wanted(mut self) -> Bool:
        return False


def test_erase_is_a_complete_way_in() raises:
    """Everything a caller needs, reached through `erase` and the verbs alone."""
    var e = ErasedResource.erase(_Probe(String("node-a")))
    assert_equal(e.logical_id(), String("node-a"))
    var deps = e.depends_on()
    assert_equal(len(deps), 1)
    assert_equal(deps[0], String("upstream"))
    assert_equal(e.retention(), RETAIN_KEEP)
    assert_equal(e.undeletable_reason(), String("probe-reason"))
    var live = e.read_status(Creds(String("t1")))
    assert_equal(live.phase, RES_PRESENT_MATCHED)
    assert_equal(live.physical_id, String("phys-t1"))
    var act = e.plan(live)
    assert_equal(act.verb, VERB_UPDATE)
    assert_equal(act.reason, String("phys-t1"))
    assert_equal(e.converge_mode(live), CONVERGE_IN_PLACE)
    assert_equal(e.fault_domain(String("create")), FAULT_CUSTOMER)
    assert_equal(e.owner(), String("probe-owner"))
    assert_equal(
        e.read_presence(Creds.none()).physical_id, String("presence")
    )
    assert_true(e.stamps_ownership())
    assert_false(e.wanted())
    # The erased R is driven in place: its state persists across calls.
    assert_equal(e.create(Creds.none()), String("made-1"))
    assert_equal(e.create(Creds.none()), String("made-2"))


# =============================================================================
# §B — the source shape that keeps the constructor private.
# =============================================================================
def _depth_delta(s: String) -> Int:
    """Opening minus closing `(`/`[` brackets in `s`."""
    var d = 0
    for b in s.as_bytes():
        if b == UInt8(ord("(")) or b == UInt8(ord("[")):
            d += 1
        elif b == UInt8(ord(")")) or b == UInt8(ord("]")):
            d -= 1
    return d


def _signatures(src: String) -> List[String]:
    """Every `def` signature in `src`, joined onto one line (from `def` to the
    `:` that ends it, tracking brackets so a multi-line signature is whole)."""
    var out = List[String]()
    var lines = src.split("\n")
    var i = 0
    while i < len(lines):
        var line = String(lines[i])
        var stripped = String(line.strip())
        if stripped.startswith("def "):
            var sig = stripped
            var depth = _depth_delta(stripped)
            while depth > 0 and i + 1 < len(lines):
                i += 1
                var more = String(String(lines[i]).strip())
                sig += String(" ") + more
                depth += _depth_delta(more)
            out.append(sig)
        i += 1
    return out^


def _def_name(sig: String) -> String:
    var rest = String(sig[byte=4:])
    var end = rest.byte_length()
    for j in range(rest.byte_length()):
        var b = rest.as_bytes()[j]
        if b == UInt8(ord("(")) or b == UInt8(ord("[")):
            end = j
            break
    return String(rest[byte=0:end])


def test_constructor_is_keyword_only_and_underscore_named() raises:
    var src = Path(_SRC).read_text()
    var found = 0
    for sig in _signatures(src):
        if _def_name(sig) != String("__init__"):
            continue
        found += 1
        var open = sig.find("(")
        var params = String(sig[byte=open + 1 : sig.rfind(")")])
        var parts = params.split(",")
        assert_equal(String(parts[0].strip()), String("out self"))
        assert_equal(
            String(parts[1].strip()),
            String("*"),
            String("the constructor must be keyword-only: ") + sig,
        )
        for k in range(2, len(parts)):
            var p = String(parts[k].strip())
            if p == "":
                continue
            if p.startswith("var "):
                var tail = String(p[byte=4:])
                p = tail
            assert_true(
                p.startswith("_"),
                String("a public constructor parameter: ") + p,
            )
    assert_equal(found, 1, String("exactly one ErasedResource constructor"))
    assert_true(
        String("def erase[R: Resource](var resource: R) -> ErasedResource:")
        in src
    )


def test_no_public_signature_names_a_pointer() raises:
    var src = Path(_SRC).read_text()
    var public = 0
    for sig in _signatures(src):
        var name = _def_name(sig)
        if name.startswith("_") and name != String("__init__"):
            continue  # private: a trampoline or helper
        if name == String("__init__"):
            continue  # checked above: every parameter is private
        public += 1
        assert_false(
            String("UnsafePointer") in sig,
            String("a pointer type in a public signature: ") + sig,
        )
        assert_false(
            String("Origin") in sig,
            String("an origin in a public signature: ") + sig,
        )
        assert_false(
            String("OwnedPointer") in sig,
            String("a pointer type in a public signature: ") + sig,
        )
    # erase + the Resource verbs; a scan that found none proves nothing.
    assert_true(public >= 20, String("public signatures seen: ") + String(public))


def main() raises:
    test_erase_is_a_complete_way_in()
    test_constructor_is_keyword_only_and_underscore_named()
    test_no_public_signature_names_a_pointer()
    print("ALL ERASED-RESOURCE PUBLIC-API TESTS PASSED")
