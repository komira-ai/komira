# =============================================================================
# src/kci_validate/network.mojo -- whether this machine has a network at
#   all: the one case an ENV validation does not FAIL but cannot run.
# =============================================================================
#
# Before the channel is read, kci asks each DECLARED remote host once,
# anonymously (`GET /`, no Authorization header, no redirect followed): the
# step's channel, the compiler channel and each extra channel (`conda-forge`
# is conda.anaconda.org). A LOCAL `file:///` channel has no host and is not
# asked (the compiler channel still is: mojo-compiler comes from it). The answer is classified by host:
#
#   every host answered      the network is up; the validation runs.
#                            ANY HTTP status is an answer: a 401, a 404 or a
#                            5xx means the host was reached, so whatever is
#                            wrong is the channel's, judged by the checks
#                            after this one (a FAIL, never a skip)
#   NO host answered         no network: the validation cannot run. Its
#                            outcome is INDETERMINATE (kci_api: "kci cannot
#                            say whether the end state holds; never a pass",
#                            exit 5) with a `skip_reason` naming each host and
#                            its error. Not VALIDATION_FAILED: nothing about
#                            the release was judged
#   some answered, some not  FAIL: the network is up, so a declared host that
#                            does not answer is a failure of what the
#                            validation depends on
#
# "Did not answer" is a transport fault: no HTTP response at all (a name that
# does not resolve, a refused or timed-out connection, a TLS failure). The
# row names each host's error, so a TLS failure reads as one.
#
# Encapsulation: owned values; the transport is borrowed `mut`. No pointer,
# no wildcard origin.
# =============================================================================

from komira_http_core.codec.types import HTTP_METHOD_GET

from kci_pkg_upload import PkgRequest, PkgTransport
from kci_pkg_upload.transport import try_exchange
from kci_release_machine import StageValidation

from .channel_index import ChannelUrl
from .container import channel_url_of

comptime CHECK_NETWORK: String = "network"


struct HostAnswer(Copyable, Movable):
    """One declared host, asked once: `answered` with `status`, or the
    transport fault in `detail`.

    Layout: owned Strings, a Bool and an Int. No pointer field."""

    var host: String
    var answered: Bool
    var status: Int
    var detail: String

    def __init__(out self, var host: String, answered: Bool, status: Int, var detail: String):
        self.host = host^
        self.answered = answered
        self.status = status
        self.detail = detail^

    def describe(self) -> String:
        if self.answered:
            return self.host + String(" answered ") + String(self.status)
        return self.host + String(" did not answer (") + self.detail + String(")")


def declared_hosts(channel_url: String, validation: StageValidation) raises -> List[String]:
    """The hosts of the step's channel, the compiler channel and the extra
    channels, each once, in that order; a `file:///` channel names none.
    RAISES on a location that is neither an https:// nor a file:/// URL."""
    var urls = List[String]()
    urls.append(channel_url.copy())
    urls.append(validation.compiler_channel.copy())
    for i in range(len(validation.extra_channels)):
        urls.append(channel_url_of(validation.extra_channels[i]))
    var out = List[String]()
    for i in range(len(urls)):
        var u = ChannelUrl(urls[i])
        if u.is_local():
            # a file:/// channel is this machine's directory: no host to ask
            continue
        var h = u.host.copy()
        var seen = False
        for j in range(len(out)):
            if out[j] == h:
                seen = True
        if not seen:
            out.append(h^)
    return out^


def probe_hosts[T: PkgTransport](mut transport: T, hosts: List[String]) -> List[HostAnswer]:
    """`GET /` of each host, once, anonymously (file header)."""
    var out = List[HostAnswer]()
    for i in range(len(hosts)):
        var req = PkgRequest(HTTP_METHOD_GET, hosts[i].copy(), String("/"))
        var r = try_exchange(transport, req)
        if r.ok:
            out.append(HostAnswer(hosts[i].copy(), True, Int(r.response.status), String("")))
        else:
            out.append(HostAnswer(hosts[i].copy(), False, 0, r.fault.copy()))
    return out^


def answered_count(answers: List[HostAnswer]) -> Int:
    var n = 0
    for i in range(len(answers)):
        if answers[i].answered:
            n += 1
    return n


def describe_answers(answers: List[HostAnswer]) -> String:
    var s = String("")
    for i in range(len(answers)):
        if i > 0:
            s += String("; ")
        s += answers[i].describe()
    return s^
