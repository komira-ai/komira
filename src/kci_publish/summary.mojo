# =============================================================================
# src/kci_publish/summary.mojo -- the NEW NAMES block of a job summary
#   (markdown), what the approver of a publishing stage reads before
#   approving it.
# =============================================================================
#
#   ### NEW NAMES on komira-ai/prod
#
#   Stage `publish-prod`, step `publish`, channel `prod`.
#
#   - `komira_all`
#
# The heading always names the channel's path. Below it comes each new name,
# or the word `none` when the channel was read and holds every name, or
# `not read: <why>` when it was not read: an unread channel never reads as
# "none".
#
# Pure: renders the text it is given; no I/O.
# =============================================================================

from .lookahead import NewNamesReport


def new_names_markdown(r: NewNamesReport) -> String:
    """The block for one PUBLISH step (file header), ending in a blank
    line."""
    var s = String("### NEW NAMES on ") + r.where() + String("\n\n")
    s += (
        String("Stage `") + r.stage + String("`, step `") + r.step + String("`, channel `") + r.channel
        + String("`.\n\n")
    )
    if not r.read:
        s += String("not read: ")
        if r.detail.startswith(String("not read: ")):
            s += String(r.detail[byte = 10 :])
        else:
            s += r.detail
        s += String("\n\n")
        return s^
    if len(r.names) == 0:
        s += String("none\n\n")
        return s^
    for i in range(len(r.names)):
        s += String("- `") + r.names[i] + String("`\n")
    s += String("\n")
    return s^
