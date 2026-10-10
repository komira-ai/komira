# HTTP routes from protobuf services: mojo_routes_proto_library

```python
load("@komira//tools/build/mojo:proto.bzl", "mojo_routes_proto_library")
```

`mojo_routes_proto_library(name, srcs, outs, messages, deps, proto_deps,
import_prefix, test_srcs, test_data)` runs protoc with
`protoc-gen-mojo-routes`, which serves the services of `srcs` over HTTP from
their RPCs' `(google.api.http)` rules. For each `.proto` declaring a service
it writes `<stem>_routes.mojo` (stated in `outs`): per service a handler trait
with one method per RPC, `<service>_router()` building
`komira_http_server`'s `Router` (one route per HTTP binding), and
`<Service>Routes[H]`, a `RequestDispatcher` that binds the request message from
path variables, query parameters and a `body: "*"` JSON body (unknown fields
and parameters are refused with 400), answers 405 for a known path under
another method (its `Allow` header names the path's methods), and writes the
response as proto3 JSON. `<Service>Routes` is a `RoutedDispatcher`, so one
server serves several services through `komira_http_server`'s
`ComposedRoutes[*Services]`. `messages` is the Mojo
proto library of the request and response messages (its import name is where
the routes module imports them from; it is added to `deps`); `proto_deps` lets
protoc resolve the imports, `google/api/annotations.proto` included. Like the
welded `mojo_proto_library`, it is two targets, `<name>_gen` and the library
`<name>`, so `test_srcs` gate the package. What the plugin refuses is listed
in [`../src/routes/mod.rs`](../src/routes/mod.rs);
this directory ([`BUCK`](BUCK)) is its fixture and tests.

The plugin, `komira//tools/build/proto-codegen:protoc-gen-mojo-routes`, is
part of the protoc toolchain described in
[Protobuf](../../mojo/README.md#protobuf-mojo_proto_library), with the other
Mojo proto rules.
