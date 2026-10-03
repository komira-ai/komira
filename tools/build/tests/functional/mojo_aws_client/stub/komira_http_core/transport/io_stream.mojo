"""The `Connector` trait of komira_http_core.transport.io_stream, as the
bound a client-mode generated client puts on its connector parameter.

The real trait also declares the connection's stream type and `connect`,
which reach komira_async; no code of this cell opens a connection, so the
stub declares the trait's supertraits and nothing else. A struct that
conforms to the real trait conforms to this one.
"""


trait Connector(Movable, Deinitable):
    """A connector the stub transport takes from a client's factory and
    never connects."""

    pass
