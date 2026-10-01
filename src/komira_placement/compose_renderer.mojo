# =============================================================================
# komira_placement/compose_renderer.mojo — the NATIVE multi-container
# RENDERER.
# =============================================================================
#
# `PlacementSpec` is multi-container at the SPEC level
# (`PlacementSpec.containers: List[ContainerSpec]`), but the k8s bridge
# `PlacementSpec.to_pod_spec()` is single-container by construction: it renders
# `containers[0]` and DROPS `containers[1:]` by design (the k8s `PodCreateSpec`
# is single-container — see `PlacementSpec.to_pod_spec`). So a multi-container
# PlacementSpec (the co-located shape — an app container + a Postgres
# container, + sibling containers) cannot actually be PLACED through the
# single-container bridge.
#
# THE RENDERER (this module): a multi-container PlacementSpec has NO PodCreateSpec
# bridge; it renders to a NATIVE multi-container DESCRIPTOR — a docker-compose-
# shaped value type (`ComposePodSpec`) that a LOCAL runner (the no-cloud
# verification path) AND a cloud-VM supervisor can BOTH consume. The renderer is
# PURE value-type code over `PlacementSpec`:
#
#   render_compose(PlacementSpec) -> ComposePodSpec
#
# preserving ALL N containers (their images / commands / args / env / ports),
# with a SHARED network so the app reaches Postgres BY NAME (a co-located pod).
# It NEVER routes through to_pod_spec().
#
# WHY a compose shape (not a k8s Pod manifest): the verification path is
# "render N containers + run them together via docker-compose / pod-on-a-box"
# and "verify against a fake and a local process runner rendering N real
# subprocesses." A compose spec is the lowest-common-denominator descriptor that
# a `docker compose up` on a VM, a local subprocess runner, and a cloud
# supervisor pod-loader can all consume; a k8s Pod manifest would bind us to a
# cluster the cloud path (a plain compute box) does not have. The descriptor is
# backend-neutral data; `to_compose_yaml()` serializes it for the
# docker-compose / cloud-supervisor consumer; a local compose runner consumes
# the SAME `ComposePodSpec` value directly (no YAML round-trip) to spawn N
# co-located subprocesses on loopback.
#
# ENCAPSULATION + gap6: ordinary control-plane value structs — plain owned
# fields (String / Int / List of owned structs). No UnsafePointer, no wildcard
# origin, no byte-slab. Every struct is Copyable + Movable (matching the
# PlacementSpec / ContainerSpec it renders from). This is a value-only transform;
# the placement (spawning) is the runner's job, not the renderer's.
# =============================================================================

from komira_k8s.k8s_types import EnvVar
from komira_placement.placement_types import (
    PlacementSpec,
    ContainerSpec,
    PortSpec,
)


# -----------------------------------------------------------------------------
# ComposePortMapping — one published port of a compose service. `published` is
# the host-side port (what siblings + the outside world reach), `target` the
# container-internal listen port. On a co-located pod (one network namespace /
# loopback) published == target — a sibling reaches the service at
# localhost:<published>. Carried distinctly so a cloud supervisor that
# remaps ports (host:container) has the field it needs without a renderer change.
# -----------------------------------------------------------------------------
@fieldwise_init
struct ComposePortMapping(Copyable, Movable):
    """A published port of a compose service: `published` (host) -> `target`
    (container). `name` is the symbolic port name carried from the PortSpec
    (e.g. "http", "pg"). On a co-located pod published == target (loopback)."""

    var name: String
    var published: Int
    var target: Int


# -----------------------------------------------------------------------------
# ComposeService — one service (== one container) in a compose pod. Mirrors a
# docker-compose `services:` entry: the service `name` (the network alias a
# sibling reaches it by — `localhost`/`postgres`/`komira-app`), the `image`, the
# `command` (entrypoint + args, flattened — compose's `command:` list), the
# `environment` (KEY=VALUE list), and the published `ports`. Plain owned fields.
# -----------------------------------------------------------------------------
struct ComposeService(Copyable, Movable):
    """One service in a `ComposePodSpec` — the rendered form of one
    `ContainerSpec`. `name` is the service / network-alias name; `image` the
    container image; `command` the flattened entrypoint+args (compose's
    `command:`); `environment` the env (carried as `EnvVar` name/value pairs);
    `ports` the published port mappings. A sibling service reaches this one at
    `<name>:<target>` on the shared compose network (or `localhost:<published>`
    on a co-located loopback pod)."""

    var name: String
    var image: String
    var command: List[String]
    var environment: List[EnvVar]
    var ports: List[ComposePortMapping]

    def __init__(out self, name: String, image: String):
        self.name = name
        self.image = image
        self.command = List[String]()
        self.environment = List[EnvVar]()
        self.ports = List[ComposePortMapping]()

    def env_value(self, key: String) -> String:
        """The value of env `key`, or "" if absent (inspection helper for tests
        / a cloud supervisor reading the rendered env)."""
        for i in range(len(self.environment)):
            if self.environment[i].name == key:
                return self.environment[i].value
        return String("")


# -----------------------------------------------------------------------------
# ComposePodSpec — the NATIVE multi-container descriptor. The whole co-located
# pod: a `name` (the compose project / pod name), a `network` name (the shared
# network all services join — how the app reaches Postgres BY NAME), and the
# `services` (one per container, ALL N preserved — the whole point). This is the
# value a docker-compose `up`, a local compose runner, and a cloud
# supervisor all consume.
# -----------------------------------------------------------------------------
struct ComposePodSpec(Copyable, Movable):
    """The rendered multi-container target. `name` is the compose project / pod
    name (from the PlacementSpec's placement handle); `network` is the shared
    network the services join (default `<name>-net`) — the mechanism by which a
    sibling reaches another by service name; `services` holds ALL N rendered
    containers (never just `services[0]` — the renderer's contract is that no
    container is dropped). Backend-neutral data; serialize via `to_compose_yaml`
    for a docker-compose / cloud-supervisor consumer, or consume directly (the
    a local compose runner spawns one subprocess per service)."""

    var name: String
    var network: String
    var services: List[ComposeService]

    def __init__(out self, name: String, network: String):
        self.name = name
        self.network = network
        self.services = List[ComposeService]()

    def service_count(self) -> Int:
        return len(self.services)

    def service_index(self, name: String) -> Int:
        """Index of service `name`, or -1 if absent."""
        for i in range(len(self.services)):
            if self.services[i].name == name:
                return i
        return -1

    def to_compose_yaml(self) -> String:
        """Serialize to a docker-compose v3 YAML document — the form a
        `docker compose -f - up` on a VM (or the cloud-supervisor pod-loader)
        consumes. Every service is on the shared `network` so a service reaches
        a sibling by service name. This is a faithful but minimal renderer (the
        fields the co-located pod needs: image, command, environment, ports,
        network); it is deterministic for snapshot tests."""
        var out = String("version: \"3.8\"\n")
        out += String("name: ") + self.name + String("\n")
        out += String("networks:\n")
        out += String("  ") + self.network + String(":\n")
        out += String("    driver: bridge\n")
        out += String("services:\n")
        for si in range(len(self.services)):
            ref svc = self.services[si]
            out += String("  ") + svc.name + String(":\n")
            out += String("    image: ") + svc.image + String("\n")
            if len(svc.command) > 0:
                out += String("    command:\n")
                for ci in range(len(svc.command)):
                    out += String("      - \"") + svc.command[ci] + String("\"\n")
            if len(svc.environment) > 0:
                out += String("    environment:\n")
                for ei in range(len(svc.environment)):
                    out += (
                        String("      ")
                        + svc.environment[ei].name
                        + String(": \"")
                        + svc.environment[ei].value
                        + String("\"\n")
                    )
            if len(svc.ports) > 0:
                out += String("    ports:\n")
                for pi in range(len(svc.ports)):
                    out += (
                        String("      - \"")
                        + String(svc.ports[pi].published)
                        + String(":")
                        + String(svc.ports[pi].target)
                        + String("\"\n")
                    )
            out += String("    networks:\n")
            out += String("      - ") + self.network + String("\n")
        return out^


# -----------------------------------------------------------------------------
# render_compose — the RENDERER. PlacementSpec -> ComposePodSpec, preserving ALL
# N containers. Pure value-type code; NEVER routes through to_pod_spec().
# -----------------------------------------------------------------------------
def render_compose(spec: PlacementSpec) raises -> ComposePodSpec:
    """Render a (multi-container) `PlacementSpec` to the NATIVE multi-container
    `ComposePodSpec`. ALL N containers are preserved (image / command+args / env
    / ports) — the renderer's contract is that no container is dropped (contrast
    `to_pod_spec()`, which keeps only `containers[0]`). The shared network name
    is derived from the unit name (`<name>-net`); every service joins it so the
    app reaches a sibling (e.g. Postgres) BY SERVICE NAME.

    Raises on an empty placement (zero containers — a malformed unit that cannot
    be rendered to a runnable pod)."""
    if len(spec.containers) == 0:
        raise Error(
            String("render_compose: placement spec for ")
            + spec.name
            + String(" has no containers (cannot render an empty pod)")
        )

    var network = spec.name + String("-net")
    var pod = ComposePodSpec(spec.name, network)

    for ci in range(len(spec.containers)):
        ref c = spec.containers[ci]
        var svc = ComposeService(c.name, c.image)

        # command = entrypoint override (command) ++ args (compose flattens the
        # entrypoint + args into one `command:` list — the same flattening the
        # local subprocess argv uses).
        for i in range(len(c.command)):
            svc.command.append(c.command[i])
        for i in range(len(c.args)):
            svc.command.append(c.args[i])

        # environment carried verbatim (the app's DATABASE_URL points at the
        # sibling Postgres service BY NAME — set by the caller building the spec).
        for i in range(len(c.env)):
            svc.environment.append(c.env[i].copy())

        # ports: a co-located pod publishes each container port on the shared
        # network at the same number (loopback / one netns) so a sibling reaches
        # it at <service>:<port>. published == target on the co-located pod.
        for i in range(len(c.ports)):
            ref p = c.ports[i]
            svc.ports.append(
                ComposePortMapping(p.name, p.container_port, p.container_port)
            )

        pod.services.append(svc^)

    return pod^
