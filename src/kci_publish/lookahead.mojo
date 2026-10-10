# =============================================================================
# src/kci_publish/lookahead.mojo -- NEW NAMES: which declared names a
#   PUBLISH step's channel holds no file of yet, for the step itself and for
#   the PUBLISH steps of the stages after it.
# =============================================================================
#
# Which names a release publishes is its artifacts file's. The approver of
# a publishing stage must see the names that stage will publish for the first
# time BEFORE approving it. A job held for approval prints nothing until it is
# approved, so the stage before it reports them: `kci run --stage S` reports
# the new names of every PUBLISH step of each stage whose `after` is S.
#
#   new_names_of(report, ...)    a step's own new names, from its report
#   read_new_names(...)          one channel, read ANONYMOUSLY (repodata
#                                listings and the set's files by download,
#                                the same reads and the same HELD rule as
#                                step 1, plan.mojo)
#   lookahead_new_names(...)     a later stage's PUBLISH step: step 0's
#                                checks (`prepare_release`), then
#                                `read_new_names`
#
# A report is READ or NOT READ, never "no new names" by default:
#   * a PRIVATE channel is not read: reading it needs that stage's
#     credential, which this stage does not hold. That is neither a pass nor
#     a failure of this stage;
#   * a listing or a file that could not be read (CANNOT_TELL) is not read:
#     an unread listing never makes a name new, and never makes it held;
#   * a step 0 refusal of the later stage's request is not read, naming why.
#
# Encapsulation: owned values; the registry set is borrowed `mut`. No
# pointer, no wildcard origin.
# =============================================================================

from std.ffi import abort

from komira_http_client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet
from kci_pkg_upload.coordinate import repo_host
from kci_pkg_upload.prefix_dev_registry import prefix_dev_channel
from kci_release_channel import Channel

from .channel_state import read_channel
from .flow import prepare_release
from .plan import STATE_ABSENT, STATE_DIFFERENT, STATE_SAME, PublishTarget, new_names
from .report import PublishReport
from .request import PublishRequest
from .upload import PublishCredential
from .workers import ChannelTransport, HttpChannelTransport


struct NewNamesReport(Copyable, Movable):
    """The new names of one PUBLISH step's channel (file header). `read`
    False means `names` means nothing and `detail` says why.

    Layout: owned values only. No pointer field."""

    var stage: String
    var step: String
    var channel: String
    var channel_path: String
    var read: Bool
    var names: List[String]
    var detail: String

    def __init__(out self, var stage: String, var step: String, var channel: String):
        self.stage = stage^
        self.step = step^
        self.channel = channel^
        self.channel_path = String("")
        self.read = False
        self.names = List[String]()
        self.detail = String("")

    def where(self) -> String:
        """`<namespace>/<channel>` when known, else the channel's name."""
        if self.channel_path.byte_length() > 0:
            return self.channel_path.copy()
        return self.channel.copy()


def new_names_of(r: PublishReport, stage: String, step: String) -> NewNamesReport:
    """A PUBLISH step's own new names, from its report."""
    var out = NewNamesReport(stage.copy(), step.copy(), r.channel.copy())
    out.channel_path = r.channel_path.copy()
    if r.names_known:
        out.read = True
        out.names = r.new_names.copy()
    else:
        out.detail = String("the step did not read which names the channel holds (see its outcome)")
    return out^


def read_new_names[T: ChannelTransport](
    mut registry: RegistrySet[T, PublishCredential],
    channel: Channel,
    targets: List[PublishTarget],
    stage: String,
    step: String,
) -> NewNamesReport:
    """`channel`'s new names for `targets`, read anonymously (file header).
    Never raises; sends nothing but reads."""
    var out = NewNamesReport(stage.copy(), step.copy(), channel.name.copy())
    if len(targets) == 0:
        out.detail = String("the release set is empty")
        return out^
    try:
        out.channel_path = prefix_dev_channel(targets[0].coordinate.repo)
    except e:
        out.detail = String(e)
        return out^
    if not channel.is_public():
        out.detail = (
            String("not read: channel '") + channel.name
            + String("' is PRIVATE; reading it needs the credential of stage '") + stage + String("'")
        )
        return out^
    try:
        registry.credential().configure(SURFACE_PREFIX_DEV, repo_host(targets[0].coordinate.repo), String(""))
    except e:
        out.detail = String(e)  # cov: unreachable prefix_dev_channel above refused every repo repo_host refuses
        return out^  # cov: unreachable prefix_dev_channel above refused every repo repo_host refuses
    var read = read_channel(registry, targets)
    if not read.names_read:
        out.detail = String("cannot tell which names the channel holds: ") + read.names_detail
        return out^
    for i in range(len(read.states)):
        var k = read.states[i].kind
        if k != STATE_ABSENT and k != STATE_SAME and k != STATE_DIFFERENT:
            out.detail = (
                String("cannot tell: ") + targets[i].where() + String(": ") + read.states[i].detail
            )
            return out^
    out.read = True
    out.names = new_names(targets, read)
    return out^


def lookahead_new_names[T: ChannelTransport](
    mut registry: RegistrySet[T, PublishCredential], req: PublishRequest
) -> NewNamesReport:
    """A later stage's PUBLISH step (`req`, built for that stage): step 0's
    checks, then `read_new_names`. Never raises."""
    var plan_req = req.copy()
    plan_req.plan = True
    try:
        var p = prepare_release(plan_req)
        return read_new_names(registry, p.channel, p.targets, req.stage, req.step_name)
    except e:
        var out = NewNamesReport(req.stage.copy(), req.step_name.copy(), req.channel.copy())
        out.detail = String("not read: ") + String(e)
        return out^


comptime _Conn = TlsConnector[KernelTcpConnector]
comptime _Http = HttpChannelTransport[_Conn]


def _mk_connector(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("NEW NAMES: TLS connector for ") + host + String(": ") + String(e))


def lookahead_new_names_https(req: PublishRequest) -> NewNamesReport:
    """`lookahead_new_names` over the real HTTPS transport."""
    var registry = RegistrySet[_Http, PublishCredential](_Http(_mk_connector), PublishCredential())
    return lookahead_new_names(registry, req)
