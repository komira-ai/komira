# =============================================================================
# src/kci_workflow_check/id_token.mojo -- which stages need a CI identity
#   token (R4, rules.mojo's header), and which channels files that takes.
# =============================================================================
#
# A stage needs `id-token: write` on its job when one of its steps
# authenticates by OIDC from CI:
#
#   * a PUBLISH step whose channel publishes by OIDC trusted publishing
#     (read from the channels file the step names);
#   * a DEPLOY step: kci authenticates to a cell from CI by OIDC only;
#   * a PUBLISH step into a cell (`cells`/`cell`, kci_release_machine's
#     deploy.mojo): the same. Such a step names no channels file, so
#     `channels_paths` skips it and `id_token_stages` never looks for one.
#
# Farm-connected stages need the token too; rules.mojo's R4 adds them, not
# this file. A part job of a split stage holds no token whatever its stage
# needs (R9).
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_release_channel import Channel, find_channel, parse_channels_file
from kci_release_machine import ReleaseMachine


struct ChannelsFile(Copyable, Movable):
    """A channels file's path, as a machine-file step names it, and its
    text. Layout: owned Strings. No pointer field."""

    var path: String
    var text: String

    def __init__(out self, var path: String, var text: String):
        self.path = path^
        self.text = text^


def _channels_text(files: List[ChannelsFile], path: String) raises -> String:
    for i in range(len(files)):
        if files[i].path == path:
            return files[i].text.copy()
    raise Error(String("the channels file '") + path + String("' was not given"))


def channels_paths(g: ReleaseMachine) -> List[String]:
    """Every distinct channels path a PUBLISH step to a channel names, in
    file order: what `id_token_stages` needs read. A PUBLISH into a cell
    names no channels file and adds nothing."""
    var out = List[String]()
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            ref s = g.stages[i].steps[k]
            if not s.is_publish() or s.names_cell():
                continue
            var seen = False
            for j in range(len(out)):
                if out[j] == s.channels:
                    seen = True
            if not seen:
                out.append(s.channels.copy())
    return out^


def _channel_is_oidc(ch: Channel) -> Bool:
    for i in range(len(ch.repositories)):
        ref r = ch.repositories[i]
        if r.credential and r.credential.value().is_oidc_trusted_publishing():
            return True
    return False


def id_token_stages(g: ReleaseMachine, files: List[ChannelsFile]) raises -> List[String]:
    """The stages that need a CI identity token (file header): those with a
    DEPLOY step, a PUBLISH step into a cell, or a PUBLISH step whose channel
    publishes by OIDC trusted publishing. Raises when a channels file a
    PUBLISH to a channel names is not given or is refused, or names no such
    channel."""
    var out = List[String]()
    for i in range(len(g.stages)):
        ref st = g.stages[i]
        var needs = False
        for k in range(len(st.steps)):
            ref s = st.steps[k]
            if s.is_deploy():
                needs = True
                continue
            if not s.is_publish():
                continue
            if s.names_cell():
                # a PUBLISH into a cell: OIDC to the cell, and no channels file
                needs = True
                continue
            var channels = parse_channels_file(_channels_text(files, s.channels))
            var ch = find_channel(channels, s.channel)
            if _channel_is_oidc(ch):
                needs = True
        if needs:
            out.append(st.name.copy())
    return out^
