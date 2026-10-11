# =============================================================================
# komira_chat_store/probe.mojo -- SendProbe, the test seam inside a send.
# =============================================================================
#
# `ChatStore` calls its probe once per allocation attempt, after it has read
# the channel's head and before it inserts the event at head + 1. A test
# probe uses that window to commit another sender's event through a second
# connection, or raises to stand for a crash. Production stores use
# `NoSendProbe`, the default, which does nothing.
# =============================================================================


trait SendProbe(Movable, Deinitable):
    def before_insert(mut self, channel_id: String, seq: Int64) raises:
        """Called with the seq the store is about to insert at. A raise
        abandons the send with that error; nothing has been written."""
        ...


struct NoSendProbe(SendProbe):
    def __init__(out self):
        pass

    @always_inline
    def before_insert(mut self, channel_id: String, seq: Int64) raises:
        pass
