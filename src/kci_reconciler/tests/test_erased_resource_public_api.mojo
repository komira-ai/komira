# =============================================================================
# kci_reconciler/tests/test_erased_resource_public_api.mojo — `ErasedResource`
#   has ONE public way in, `erase[R](resource^)`, and no pointer type in its
#   public API.
# =============================================================================
#
# The rule: an untracked-origin pointer type may appear only in a function body
# and in a private signature or field, never in a public signature. The 22
# vtable fn-ptr types expand to `UnsafePointer[UInt8, MutUntrackedOrigin]`, so
# they live in the private struct `_ErasedVTable`, which the package does not
# re-export, and `ErasedResource`'s one constructor takes that struct.
#
# §A drives a concrete conformer through `ErasedResource.erase` ONLY, and checks
#    that every verb this file touches reaches the conformer (a verb whose value
#    differs from the trait default, so a missing forward reads as the default).
# §B reads erased_resource.mojo and the package `__init__.mojo` and checks:
#    the constructor is keyword-only with only underscore-named parameters;
#    `erase` exists; no public `def` signature, constructor included, and no
#    `ErasedResource` field names a pointer type, an origin, or a comptime alias
#    that expands to one; and the package does not re-export the vtable.
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
    FAULT_USER,
)

comptime _SRC = "src/kci_reconciler/erased_resource.mojo"
comptime _PKG_INIT = "src/kci_reconciler/__init__.mojo"


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
        return FAULT_USER

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
    assert_equal(e.fault_domain(String("create")), FAULT_USER)
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


def _pointer_words(src: String) raises -> List[String]:
    """`UnsafePointer`, `Origin`, and the name of every `comptime` alias in
    `src` whose definition mentions either (an alias hides the pointer type
    from a plain text check of a signature that uses it)."""
    var words = List[String]()
    words.append(String("UnsafePointer"))
    words.append(String("Origin"))
    var lines = src.split("\n")
    var i = 0
    var aliases = 0
    while i < len(lines):
        var stripped = String(String(lines[i]).strip())
        if stripped.startswith("comptime ") and String(" = ") in stripped:
            var body = stripped
            var depth = _depth_delta(stripped)
            while depth > 0 and i + 1 < len(lines):
                i += 1
                var more = String(String(lines[i]).strip())
                body += String(" ") + more
                depth += _depth_delta(more)
            var name_end = body.find(" = ")
            var name = String(body[byte=9:name_end])
            if String("UnsafePointer") in body or String("Origin") in body:
                words.append(name)
                aliases += 1
        i += 1
    # The vtable aliases; a scan that found none proves nothing.
    assert_true(aliases >= 22, String("pointer aliases seen: ") + String(aliases))
    return words^


def _struct_fields(src: String, struct_name: String) -> List[String]:
    """Every `var` field line directly in `struct <struct_name>`'s body."""
    var out = List[String]()
    var lines = src.split("\n")
    var inside = False
    for raw in lines:
        var line = String(raw)
        if line.startswith(String("struct ") + struct_name):
            inside = True
            continue
        if inside and line.byte_length() > 0 and not line.startswith(" "):
            break  # the next top-level item
        if inside and line.startswith("    var "):
            out.append(String(line.strip()))
    return out^


def test_no_public_signature_names_a_pointer() raises:
    var src = Path(_SRC).read_text()
    var words = _pointer_words(src)
    var public = 0
    var saw_init = False
    for sig in _signatures(src):
        var name = _def_name(sig)
        if name == String("__init__"):
            saw_init = True
        elif name.startswith("_"):
            continue  # private: a trampoline, helper or `__deinit__`
        public += 1
        for w in words:
            assert_false(
                w in sig,
                String("a pointer type (") + w + ") in a public signature: " + sig,
            )
        if name != String("__init__"):
            assert_false(
                String("OwnedPointer") in sig,
                String("a pointer type in a public signature: ") + sig,
            )
    assert_true(saw_init, String("the constructor was not scanned"))
    # erase + the Resource verbs; a scan that found none proves nothing.
    assert_true(public >= 20, String("public signatures seen: ") + String(public))


def test_fields_hold_the_vtable_privately() raises:
    var src = Path(_SRC).read_text()
    var words = _pointer_words(src)
    assert_true(String("struct _ErasedVTable(") in src)
    var fields = _struct_fields(src, String("ErasedResource("))
    assert_equal(len(fields), 2, String("ErasedResource fields: home + vtable"))
    for f in fields:
        assert_true(
            String(f[byte=4:]).startswith("_"), String("a public field: ") + f
        )
        for w in words:
            assert_false(
                w in f, String("a pointer type (") + w + ") in a field: " + f
            )
    var pkg = Path(_PKG_INIT).read_text()
    assert_false(
        String("_ErasedVTable") in pkg,
        String("the package re-exports the private vtable"),
    )


def main() raises:
    test_erase_is_a_complete_way_in()
    test_constructor_is_keyword_only_and_underscore_named()
    test_no_public_signature_names_a_pointer()
    test_fields_hold_the_vtable_privately()
    print("ALL ERASED-RESOURCE PUBLIC-API TESTS PASSED")
