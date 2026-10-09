# The dispatchers protoc-gen-mojo-routes generates for
# example/library/v1/library_service.proto, driven with requests and fake
# handlers that record what they were called with. Each test names the
# emitter defect it catches.

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_proto_codec import decode_json

from komira_routes_fixture.library_service_routes import (
    BookServiceHandler,
    BookServiceRoutes,
    ShelfServiceHandler,
    ShelfServiceRoutes,
)
from komira_routes_fixture_messages.library import (
    Book,
    CreateBookRequest,
    DeleteBookRequest,
    DeleteBookResponse,
    GetBookRequest,
    GetShelfRequest,
    ListBooksRequest,
    ListBooksResponse,
    SearchShelvesRequest,
    SearchShelvesResponse,
    Shelf,
)


comptime _Rt = BlockingRuntime[NoopSink]


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


# ---- fake handlers: each records the RPC it ran and the bound fields ----


struct Books(BookServiceHandler):
    var last: String

    def __init__(out self):
        self.last = String("")

    def get_book[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var request: GetBookRequest
    ) raises -> Book:
        _ = reactor
        self.last = String("GetBook ") + request.shelf + String(" ") + String(request.book_id)
        if request.book_id == Int64(404):
            raise Error("no book 404")
        return decode_json[Book](String('{"title": "t"}'))

    def list_books[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var request: ListBooksRequest
    ) raises -> ListBooksResponse:
        _ = reactor
        var drafts = String("unset")
        if request.include_drafts:
            drafts = String(request.include_drafts.value())
        self.last = (
            String("ListBooks ")
            + request.shelf
            + String(" ")
            + String(request.page_size)
            + String(" ")
            + request.page_token
            + String(" ")
            + drafts
        )
        return decode_json[ListBooksResponse](String("{}"))

    def create_book[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var request: CreateBookRequest
    ) raises -> Book:
        _ = reactor
        var title = String("none")
        if request.book:
            title = String(request.book.value().title)
        self.last = String("CreateBook ") + request.shelf + String(" ") + title
        return decode_json[Book](String('{"title": "t"}'))

    def delete_book[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var request: DeleteBookRequest
    ) raises -> DeleteBookResponse:
        _ = reactor
        self.last = String("DeleteBook ") + request.shelf + String(" ") + String(request.book_id)
        return decode_json[DeleteBookResponse](String("{}"))

    def error_response(mut self, rpc: String, error: Error) -> HttpResponse:
        self.last = String("error ") + rpc + String(": ") + String(error)
        return HttpResponse(status=Int32(409))


struct Shelves(ShelfServiceHandler):
    var last: String

    def __init__(out self):
        self.last = String("")

    def get_shelf[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var request: GetShelfRequest
    ) raises -> Shelf:
        _ = reactor
        self.last = String("GetShelf ") + request.shelf
        return decode_json[Shelf](String("{}"))

    def search_shelves[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var request: SearchShelvesRequest
    ) raises -> SearchShelvesResponse:
        _ = reactor
        self.last = String("SearchShelves ") + request.query + String(" ") + String(request.limit)
        return decode_json[SearchShelvesResponse](String("{}"))

    def error_response(mut self, rpc: String, error: Error) -> HttpResponse:
        self.last = String("error ") + rpc + String(": ") + String(error)
        return HttpResponse(status=Int32(409))


# ---- requests ----


def _req(
    method: HttpMethod, var path: String, var query: String = String(""), var body: String = String("")
) -> HttpRequest:
    var r = HttpRequest()
    r.method = method
    r.path = path^
    r.query_string = query^
    var b = body.as_bytes()
    for i in range(len(b)):
        r.body.append(b[i])
    return r^


def _body(resp: HttpResponse) -> String:
    var s = String("")
    for i in range(len(resp.body)):
        s = s + chr(Int(resp.body[i]))
    return s^


def _book(
    mut routes: BookServiceRoutes[Books],
    mut reactor: Reactor[_Rt.Sink],
    var req: HttpRequest,
) raises -> Int:
    """Dispatch `req` with the handler's record cleared; the status."""
    routes.handler.last = String("")
    var resp = routes.dispatch[_Rt](reactor, req^)
    return Int(resp.status)


def _shelf(
    mut routes: ShelfServiceRoutes[Shelves],
    mut reactor: Reactor[_Rt.Sink],
    var req: HttpRequest,
) raises -> Int:
    routes.handler.last = String("")
    var resp = routes.dispatch[_Rt](reactor, req^)
    return Int(resp.status)


comptime GET = HttpMethod.get()
comptime POST = HttpMethod.post()
comptime PUT = HttpMethod.put()
comptime DELETE = HttpMethod.delete()


# ---- tests ----


def test_every_rpc_is_routed_through_each_binding() raises:
    """Every RPC of both services, the last of each included, through each of
    its bindings. Catches an emitter that skips an RPC or a binding."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    var shelves = ShelfServiceRoutes[Shelves](Shelves())

    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/s/books/7"))), 200)
    assert_equal(books.handler.last, String("GetBook s 7"))
    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/s/books"))), 200)
    assert_equal(books.handler.last, String("ListBooks s 0  unset"))
    assert_equal(
        _book(books, reactor, _req(POST, String("/v1/shelves/s/books"), body=String('{"book": {"title": "x"}}'))),
        200,
    )
    assert_equal(books.handler.last, String("CreateBook s x"))
    assert_equal(_book(books, reactor, _req(DELETE, String("/v1/shelves/s/books/7"))), 200)
    assert_equal(books.handler.last, String("DeleteBook s 7"))

    assert_equal(_shelf(shelves, reactor, _req(GET, String("/v1/shelves/s"))), 200)
    assert_equal(shelves.handler.last, String("GetShelf s"))
    assert_equal(_shelf(shelves, reactor, _req(GET, String("/v1/shelves/s/info"))), 200)
    assert_equal(shelves.handler.last, String("GetShelf s"))
    assert_equal(
        _shelf(shelves, reactor, _req(POST, String("/v1/shelves:search"), body=String('{"query": "q", "limit": 3}'))),
        200,
    )
    assert_equal(shelves.handler.last, String("SearchShelves q 3"))


def test_the_response_is_the_handlers_message_as_json() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    var resp = books.dispatch[_Rt](reactor, _req(GET, String("/v1/shelves/s/books/7")))
    assert_equal(Int(resp.status), 200)
    assert_equal(resp.headers[String("content-type")], String("application/json"))
    var got = decode_json[Book](_body(resp))
    assert_equal(got.title, String("t"))


def test_a_known_path_under_another_method_is_405() raises:
    """Catches a dispatcher that answers 404 for a path some route matches."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    var shelves = ShelfServiceRoutes[Shelves](Shelves())
    assert_equal(_book(books, reactor, _req(POST, String("/v1/shelves/s/books/7"))), 405)
    assert_equal(_book(books, reactor, _req(PUT, String("/v1/shelves/s/books"))), 405)
    assert_equal(_shelf(shelves, reactor, _req(GET, String("/v1/shelves:search"))), 405)
    assert_equal(_shelf(shelves, reactor, _req(DELETE, String("/v1/shelves/s"))), 405)
    assert_equal(books.handler.last, String(""))
    # A path no route matches is 404.
    assert_equal(_book(books, reactor, _req(GET, String("/v1/nowhere"))), 404)
    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/s/books/7/pages"))), 404)


def test_an_unknown_json_field_is_refused() raises:
    """Catches a dispatcher that decodes the body leniently."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    var path = String("/v1/shelves/s/books")
    assert_equal(
        _book(books, reactor, _req(POST, path.copy(), body=String('{"book": {"title": "x"}, "bogus": 1}'))), 400
    )
    assert_equal(
        _book(books, reactor, _req(POST, path.copy(), body=String('{"book": {"title": "x", "bogus": 1}}'))), 400
    )
    assert_equal(books.handler.last, String(""), "the handler is not called")
    assert_equal(_book(books, reactor, _req(POST, path.copy(), body=String("{"))), 400)
    assert_equal(_book(books, reactor, _req(POST, path.copy(), body=String('{"book": {"title": "x"}}'))), 200)
    # An empty body is the empty message.
    assert_equal(_book(books, reactor, _req(POST, path)), 200)
    assert_equal(books.handler.last, String("CreateBook s none"))


def test_path_values_bind_by_field_type() raises:
    """Catches a path variable bound to the wrong field, not unescaped, or
    not checked against its field's type."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/a%20b%2Fc/books/42"))), 200)
    assert_equal(books.handler.last, String("GetBook a b/c 42"))
    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/s/books/-9223372036854775808"))), 200)
    assert_equal(books.handler.last, String("GetBook s -9223372036854775808"))
    for bad in [
        String("/v1/shelves/s/books/x"),
        String("/v1/shelves/s/books/9223372036854775808"),
        String("/v1/shelves/s/books/4%2"),
        String("/v1/shelves/%zz/books/4"),
        String("/v1/shelves/%FF/books/4"),
    ]:
        assert_equal(_book(books, reactor, _req(GET, bad.copy())), 400, bad)
    # The path value overrides the same field in the body.
    assert_equal(
        _book(
            books,
            reactor,
            _req(POST, String("/v1/shelves/s1/books"), body=String('{"shelf": "s2", "book": {"title": "x"}}')),
        ),
        200,
    )
    assert_equal(books.handler.last, String("CreateBook s1 x"))


def test_query_values_bind_by_field_type() raises:
    """Catches a query parameter bound by one spelling only, an unknown one
    ignored, or a value not checked against its field's type."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    var shelves = ShelfServiceRoutes[Shelves](Shelves())
    var books_path = String("/v1/shelves/s/books")
    assert_equal(
        _book(books, reactor, _req(GET, books_path.copy(), String("pageSize=5&page_token=a%2Bb+c&includeDrafts=true"))), 200
    )
    assert_equal(books.handler.last, String("ListBooks s 5 a+b c True"))
    assert_equal(_book(books, reactor, _req(GET, books_path.copy(), String("page_size=-2&include_drafts=false"))), 200)
    assert_equal(books.handler.last, String("ListBooks s -2  False"))
    for bad in [
        String("bogus=1"),
        String("tags=x"),
        String("shelf=t"),
        String("pageSize=x"),
        String("pageSize=2147483648"),
        String("includeDrafts=yes"),
    ]:
        assert_equal(_book(books, reactor, _req(GET, books_path.copy(), bad.copy())), 400, bad)
    assert_equal(books.handler.last, String(""))
    # A route whose fields are all in the path takes no query; a route
    # without a body takes no body; a route with a body takes no query.
    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/s/books/7"), String("x=1"))), 400)
    assert_equal(_book(books, reactor, _req(GET, books_path.copy(), body=String("{}"))), 400)
    assert_equal(
        _shelf(shelves, reactor, _req(POST, String("/v1/shelves:search"), String("limit=1"), String("{}"))), 400
    )


def test_a_handler_raise_is_mapped_by_the_handler() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var books = BookServiceRoutes[Books](Books())
    assert_equal(_book(books, reactor, _req(GET, String("/v1/shelves/s/books/404"))), 409)
    assert_true(books.handler.last.startswith("error GetBook: "), books.handler.last)
    assert_true("no book 404" in books.handler.last, books.handler.last)


def main() raises:
    test_every_rpc_is_routed_through_each_binding()
    test_the_response_is_the_handlers_message_as_json()
    test_a_known_path_under_another_method_is_405()
    test_an_unknown_json_field_is_refused()
    test_path_values_bind_by_field_type()
    test_query_values_bind_by_field_type()
    test_a_handler_raise_is_mapped_by_the_handler()
    print("PASS test_routes_dispatch")
