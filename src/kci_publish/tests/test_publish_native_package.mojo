# =============================================================================
# src/kci_publish/tests/test_publish_native_package.mojo -- a release set
#   holding the native package (`komira_native`, kind `native`: the packer's
#   libkomira_native.so.1, no Mojo) and a library that requires it.
# =============================================================================
#
# The set is ExampleRelease with `add_native("komira_beta")`: komira_alpha,
# komira_beta (requires komira_alpha and `komira_native ==1.0.0
# h01234567_3`), komira_native DECLARED AFTER komira_beta, and the
# metapackage of all three.
#
# ROWS
#   (1) step 0 reads it: every member verifies (the native metadata.json is
#       read), lockstep and the requirement closure pass, and the BUILD
#       step's name check finds nothing open;
#   (2) the native package's own requirements are exactly the guard and one
#       `__glibc >=<floor>`: a compiler pin, a second floor, no floor, an
#       outside package and a missing guard are each refused, naming it; the
#       library's pin on it at another build is refused; a metapackage
#       without its row is refused naming `native 'komira_native'`;
#   (2b) the floor is a version: `__glibc <=2.34`, `__glibc ==2.34` and a
#       floor that is not digits and dots (`>=abc`, `>=2..34`, `>=2.34.`,
#       `>=.2`) are each refused by name; a requirement given twice (the
#       guard, the floor) is ONE refusal, "listed twice", and nothing else;
#       a metapackage row naming a package outside the set says it is
#       neither a library nor the native package;
#   (3) the PUBLISH targets put komira_native BEFORE komira_beta, which
#       requires it, although the artifacts file declares it after; the
#       metapackage stays last;
#   (4) NEW NAMES: on a channel holding older files of every other name,
#       the whole step publishes, uploads the native package, and reports
#       `komira_native` as its one new name; once the channel holds a file
#       of komira_native, no name is new.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, ScriptedPkgTransport,
# StaticSecretStore; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_true

from komira_secret_store import StaticSecretStore

from kci_api import EXIT_OK, MemoryRecorder
from kci_api import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    ActionsOidcEnv,
    NoWaitSleeper,
    PublishCredential,
    PublishReport,
    PublishRequest,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    EXAMPLE_HOST,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    example_channel_path,
    example_loaded,
    example_targets,
    write_example_inputs,
)
from kci_publish.verify import require_closure
from kci_release_set import KIND_NATIVE, ReleaseMember, undeclared_requirements


comptime _TOKEN: String = "pfx-native-secret-0123456789abcdefgh"
comptime _NATIVE_PIN: String = "komira_native ==1.0.0 h01234567_3"


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pnp_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _release() -> ExampleRelease:
    var r = ExampleRelease()
    r.add_native(String("komira_beta"))
    return r^


def _index(members: List[ReleaseMember], name: String) -> Int:
    for i in range(len(members)):
        if members[i].artifact == name:
            return i
    return -1


def _members(tag: String) raises -> List[ReleaseMember]:
    var r = _release()
    var d = _root(tag)
    r.write(d)
    return example_loaded(r, d).members.copy()


def _refused(members: List[ReleaseMember], needle: String) raises:
    var raised = False
    try:
        require_closure(members)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String("'") + String(e) + String("' does not say '") + needle + String("'"))
    assert_true(raised, String("not refused; expected: ") + needle)


def test_step_zero_reads_the_native_package() raises:
    var m = _members(String("read"))
    assert_equal(len(m), 4)
    var n = _index(m, String("komira_native"))
    assert_true(n > _index(m, String("komira_beta")), "the artifacts file declares the native package after its requirer")
    assert_equal(m[n].conda.kind, String(KIND_NATIVE))
    assert_true(m[n].conda.is_native())
    assert_equal(len(m[n].conda.lib_files), 2)
    assert_equal(m[n].conda.lib_files[1].path, String("lib/libkomira_native.so.1"))
    assert_equal(m[n].conda.mojo_pin, String(""))
    var beta = _index(m, String("komira_beta"))
    var pinned = False
    for d in range(len(m[beta].conda.depends)):
        if m[beta].conda.depends[d] == String(_NATIVE_PIN):
            pinned = True
    assert_true(pinned, "komira_beta requires the native package at the set's version and build")
    require_closure(m)
    assert_equal(len(undeclared_requirements(m)), 0)
    print("  test_step_zero_reads_the_native_package: PASS")


def test_the_native_package_requires_only_the_guard_and_one_glibc_floor() raises:
    var m = _members(String("closure"))
    var n = _index(m, String("komira_native"))
    var who = String("artifact 'komira_native': ")
    m[n].conda.depends.append(String("mojo-compiler ==1.0.0"))
    _refused(m, who + String("requirement 'mojo-compiler ==1.0.0' is not the guard '__linux' or '__glibc >=<floor>'"))
    m = _members(String("closure"))
    m[n].conda.depends.append(String("__glibc >=2.17"))
    _refused(m, who + String("requires 2 '__glibc >=<floor>'; the native package requires exactly one"))
    m = _members(String("closure"))
    _ = m[n].conda.depends.pop(1)
    _refused(m, who + String("requires 0 '__glibc >=<floor>'; the native package requires exactly one"))
    m = _members(String("closure"))
    m[n].conda.depends[1] = String("__glibc >=")
    _refused(m, who + String("requirement '__glibc >=' is not the guard"))
    m = _members(String("closure"))
    m[n].conda.depends.append(String("openssl >=3"))
    _refused(m, who + String("requirement 'openssl >=3' is not the guard"))
    m = _members(String("closure"))
    m[n].conda.depends[0] = String("__osx")
    _refused(m, who + String("does not require the platform guard '__linux'"))
    m = _members(String("closure"))
    var beta = _index(m, String("komira_beta"))
    for d in range(len(m[beta].conda.depends)):
        if m[beta].conda.depends[d] == String(_NATIVE_PIN):
            m[beta].conda.depends[d] = String("komira_native ==1.0.0 h01234567_2")
    _refused(m, String("artifact 'komira_beta': requirement 'komira_native ==1.0.0 h01234567_2'"))
    m = _members(String("closure"))
    var meta = _index(m, String("komira"))
    var rows = m[meta].conda.members.copy()
    m[meta].conda.members.clear()
    for i in range(len(rows)):
        if rows[i].name != String("komira_native"):
            m[meta].conda.members.append(rows[i].copy())
    _refused(m, String("native 'komira_native' of this set is not a member"))
    print("  test_the_native_package_requires_only_the_guard_and_one_glibc_floor: PASS")


def _only(members: List[ReleaseMember], line: String) raises:
    """require_closure refuses with exactly the one refusal `line`."""
    var got = String("<not refused>")
    try:
        require_closure(members)
    except e:
        got = String(e)
    assert_equal(got, String("PUBLISH step: requirement closure refused:\n  ") + line)


def test_the_glibc_floor_is_a_version_and_a_twice_is_one_refusal() raises:
    var who = String("artifact 'komira_native': ")
    for bad in ["__glibc <=2.34", "__glibc ==2.34", "__glibc >=abc", "__glibc >=2..34", "__glibc >=2.34.", "__glibc >=.2"]:
        var m = _members(String("floor"))
        var n = _index(m, String("komira_native"))
        m[n].conda.depends[1] = String(bad)
        _refused(
            m, who + String("requirement '") + String(bad) + String("' is not the guard '__linux' or '__glibc >=<floor>'")
        )
    for twice in ["__linux", "__glibc >=2.34"]:
        var m = _members(String("twice"))
        var n = _index(m, String("komira_native"))
        m[n].conda.depends.append(String(twice))
        _only(m, who + String("requirement '") + String(twice) + String("' is listed twice"))
    var m = _members(String("outside"))
    var meta = _index(m, String("komira"))
    m[meta].conda.members[0].name = String("komira_gamma")
    _refused(m, String("member 'komira_gamma' is neither a library nor the native package of this set"))
    print("  test_the_glibc_floor_is_a_version_and_a_twice_is_one_refusal: PASS")


def test_the_native_package_is_published_before_its_requirer() raises:
    var r = _release()
    var d = _root(String("order"))
    r.write(d)
    var t = example_targets(r, d)
    assert_equal(len(t), 4)
    var native = -1
    var beta = -1
    for i in range(len(t)):
        if t[i].artifact == String("komira_native"):
            native = i
        if t[i].artifact == String("komira_beta"):
            beta = i
    assert_true(native >= 0 and beta >= 0)
    assert_true(native < beta, String("komira_native at ") + String(native) + String(", komira_beta at ") + String(beta))
    assert_true(t[3].is_metapackage, "the metapackage stays last")
    print("  test_the_native_package_is_published_before_its_requirer: PASS")


def _channel(native_held: Bool) raises -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    if native_held:
        ch.put(String("linux-64"), String("komira_native-0.9.0-h00000000_1.conda"), _bytes(String("old n")))
    return ch^


def _flow(req: PublishRequest, mut reg: RegistrySet[ScriptedChannel, PublishCredential], mut result: KciRunResult) raises -> PublishReport:
    var store = StaticSecretStore()
    store.put(String(EXAMPLE_TOKEN_SECRET), String(_TOKEN))
    var sl = NoWaitSleeper()
    var rec = MemoryRecorder()
    return publish_flow(
        req, result, rec, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, RunOptions(2, 0, 2, 0, 0, 2, 0), sl
    )


def test_new_names_list_the_native_package_the_first_time() raises:
    var r = _release()
    var req = write_example_inputs(r, _root(String("names")), String("example-stable"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(False), PublishCredential())
    var result = KciRunResult(String("run"), String("publish"))
    var rep = _flow(req, reg, result)
    assert_equal(rep.exit_code(), EXIT_OK, String("\n").join(rep.lines))
    assert_true(rep.names_known)
    assert_equal(String(",").join(rep.new_names), String("komira_native"))
    assert_true(rep.has_line_containing(String("NEW NAME 'komira_native': the channel holds no file of it yet")))
    assert_equal(len(result.new_names), 1)
    assert_equal(result.new_names[0].name, String("komira_native"))
    assert_true(reg.transport().holds(String("linux-64"), r.file_name(String("komira_native"))))
    # a channel that already holds a file of the name: nothing is new
    var req2 = write_example_inputs(r, _root(String("names_held")), String("example-stable"))
    var reg2 = RegistrySet[ScriptedChannel, PublishCredential](_channel(True), PublishCredential())
    var result2 = KciRunResult(String("run"), String("publish"))
    var rep2 = _flow(req2, reg2, result2)
    assert_equal(rep2.exit_code(), EXIT_OK, String("\n").join(rep2.lines))
    assert_equal(len(rep2.new_names), 0)
    print("  test_new_names_list_the_native_package_the_first_time: PASS")


def main() raises:
    test_step_zero_reads_the_native_package()
    test_the_native_package_requires_only_the_guard_and_one_glibc_floor()
    test_the_glibc_floor_is_a_version_and_a_twice_is_one_refusal()
    test_the_native_package_is_published_before_its_requirer()
    test_new_names_list_the_native_package_the_first_time()
    print("test_publish_native_package: ALL PASS")
