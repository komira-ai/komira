# kci_publish

One PUBLISH step of a kci stage: publish the release set a BUILD step left in
`<release-dir>/<platform>/` to a conda channel, or refuse it whole.

Before any request (step 0) it re-verifies every declared member over its
bytes with the same `kci_release_set.verify_member` the build ran, and checks
lockstep against the `--release-version` file, the requirement closure, that
`release.json` names the requested revision and platform, and its set hash.
Step 1 reads the channel by download: a file of ours already present with
other bytes stops the run with nothing written, a listing that could not be
read is `INDETERMINATE`, and names the channel has never held are reported
as NEW NAMES, never refused. Steps 2 to 4 upload the missing members on up to
`--concurrency` worker threads (never with `force`), read every member back,
and publish the metapackage last. The step ends in a `kci_api` outcome word
and error id and puts its rows into the run's result document; a release
whose every file is already in the channel byte for byte is `NOOP`, exit 0.
A dry run (`plan`) writes nothing.

The channel is reached through the `ChannelTransport` seam: the
`HttpChannelTransport` for a real channel, or `ScriptedChannel`, an
in-memory channel. The package names no channel, account or organisation;
those come from the files and flags it is given. For a PUBLISH step into a
cell, `load_cell_release` makes the same load (every member re-verified,
`release.json` naming the revision and platform, the set hash equal to the
one the run was handed) and returns the set's images, each with the digest
the set names for it (`CellImage`); `kci_cli` pushes them. `kci_publish.release_fixture`
writes a complete example release (three members, an artifacts file, a
channels file and a release-version file) for tests and examples.

## Examples

A publish into an in-memory channel uploads every member, metapackage last;
running the same step again is a no-op:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from komira_secret_store import StaticSecretStore
from kci_api import MemoryRecorder, RunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import ActionsOidcEnv, NoWaitSleeper, PublishCredential, PublishReport, PublishRequest
from kci_publish import RunOptions, ScriptedChannel, publish_flow
from kci_publish.release_fixture import EXAMPLE_HOST, EXAMPLE_TOKEN_SECRET, ExampleRelease, example_channel_path
from kci_publish.release_fixture import write_example_inputs

def publish_once(req: PublishRequest, mut reg: RegistrySet[ScriptedChannel, PublishCredential], mut result: RunResult) raises -> PublishReport:
    var store = StaticSecretStore()
    store.put(EXAMPLE_TOKEN_SECRET, "example-token-not-a-secret")
    var recorder = MemoryRecorder()
    var sleeper = NoWaitSleeper()
    var opts = RunOptions(2, 0, 2, 0, 0, 2, 0)
    return publish_flow(
        req, result, recorder, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, opts, sleeper
    )

var release = ExampleRelease()
var req = write_example_inputs(release, mkdtemp() + "/publish", "example-stable")
var channel = ScriptedChannel(EXAMPLE_HOST, example_channel_path("example-stable"), "linux-64")
var reg = RegistrySet[ScriptedChannel, PublishCredential](channel^, PublishCredential())

var result = RunResult("run", "publish")
var report = publish_once(req, reg, result)
assert_equal(report.outcome(), "SUCCEEDED")
assert_equal(report.exit_code(), 0)
assert_equal(len(result.artifacts), 3)
assert_equal(result.artifacts[2].name, "komira")  # the metapackage goes last
for i in range(3):
    assert_equal(result.artifacts[i].effect, "UPLOADED")
    assert_equal(result.artifacts[i].state_after, "present-same")
assert_equal(len(result.new_names), 3)  # the channel held none of these names

var writes = reg.transport().write_count()
var again_result = RunResult("run", "publish")
var again = publish_once(req, reg, again_result)
assert_equal(again.outcome(), "NOOP")
assert_equal(again.exit_code(), 0)
assert_equal(reg.transport().write_count(), writes)  # nothing written the second time
```

A channel that already holds one of our file names with other bytes stops
the step before anything is uploaded:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from kci_api import RunResult
from kci_pkg_upload import RegistrySet
from kci_publish import PublishCredential, ScriptedChannel
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, write_example_inputs

var release = ExampleRelease()
var req = write_example_inputs(release, mkdtemp() + "/stop", "example-stable")
var channel = ScriptedChannel(EXAMPLE_HOST, example_channel_path("example-stable"), "linux-64")
var other: List[UInt8] = [0x6E, 0x6F, 0x74]  # "not" our metapackage
channel.put("linux-64", release.file_name("komira"), other^)
var reg = RegistrySet[ScriptedChannel, PublishCredential](channel^, PublishCredential())

var result = RunResult("run", "publish")
var report = publish_once(req, reg, result)
assert_equal(report.outcome(), "REFUSED")
assert_equal(report.exit_code(), 3)
assert_equal(result.error.id, "KCI-E-PUBLISH-DIFFERENT-BYTES")
assert_equal(reg.transport().write_count(), 0)
```

A dry run reads the channel and reports what it would upload, writing
nothing:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from kci_api import RunResult
from kci_pkg_upload import RegistrySet
from kci_publish import PublishCredential, ScriptedChannel
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, write_example_inputs

var req = write_example_inputs(ExampleRelease(), mkdtemp() + "/plan", "example-stable", True)
var reg = RegistrySet[ScriptedChannel, PublishCredential](
    ScriptedChannel(EXAMPLE_HOST, example_channel_path("example-stable"), "linux-64"), PublishCredential()
)
var result = RunResult("run", "publish")
var report = publish_once(req, reg, result)
assert_equal(report.exit_code(), 0)
assert_true(report.has_line_containing("DRY RUN: nothing was uploaded; 3 file(s) would be"))
assert_true(result.plan)
assert_equal(result.artifacts[0].effect, "WOULD_UPLOAD")
assert_equal(reg.transport().write_count(), 0)
```
