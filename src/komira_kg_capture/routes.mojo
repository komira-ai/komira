# =============================================================================
# routes -- the seam where a host adds routes to the capture server.
# =============================================================================
#
# The server carries the routes every deployment has: capture, structured ingest
# and health. Whatever else a host serves over the graph (a read of its own
# shape, a derived view, a write-back) is a `CaptureRoutes` conformer the host
# gives the server when it builds it. The server authenticates and size-limits a
# request before it asks the host's routes anything, so a host route is never
# reachable without the token, and a path no route claims is a 404.
#
# A route is lent the working set merged at the head, read-only: the server
# keeps that set warm, so a route that only reads pays no merge when the head has
# not moved. A route that must write does so through its own handle on the store;
# the server notices the head move on the next request and merges again.
# =============================================================================

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_kg import SnapshotWorkingSet


trait CaptureRoutes(Movable, Deinitable):
    """Extra routes served over the loaded working set."""

    def handles(self, method: HttpMethod, path: String) -> Bool:
        """Whether this set serves `method` on `path`. The server asks only
        after the request passed authentication and the size limit, and only for
        a path the server itself does not serve.
        """
        ...

    def handle(
        mut self,
        var request: HttpRequest,
        working_set: SnapshotWorkingSet,
        now_ms: Int64,
    ) raises -> HttpResponse:
        """Answer a request that `handles` accepted.

        Args:
            request: The request (consumed).
            working_set: The graph merged at the head; empty, with the
                embedder's dimension, when nothing has been written yet.
            now_ms: The server's clock, read once for this request.

        Returns:
            The response.

        Raises:
            Any error; the server answers 500 with a fixed message and does not
            repeat the error's text.
        """
        ...


struct NoRoutes(CaptureRoutes):
    """A route set with no route: the server for a host that adds none."""

    def __init__(out self):
        pass

    def handles(self, method: HttpMethod, path: String) -> Bool:
        return False

    def handle(
        mut self,
        var request: HttpRequest,
        working_set: SnapshotWorkingSet,
        now_ms: Int64,
    ) raises -> HttpResponse:
        raise Error("NoRoutes: no route is served")
