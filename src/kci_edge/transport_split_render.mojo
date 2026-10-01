# =============================================================================
# kci_edge/transport_split_render.mojo — the ROUTING for a transport split.
#   Render the front door's rules for a transport split, for the two clouds
#   whose edge can express one.
# =============================================================================
#
# ★ WHY THIS EXISTS AS A RENDER AND NOT AS PROSE. "A second backend per app is an
#   existing pattern" is true of a PATH split and false of a METHOD split, and the
#   difference is not visible in a description. A load-balancer route rule that
#   carries `paths` / `backend` and NO method field renders to
#   `pathMatchers[].pathRules[]` — which is path-only by construction. So an app
#   whose halves sit on different paths (a chat server, a git server) can be
#   split with such a routing table, and a CalDAV server cannot be split by it at
#   all. Rendering both shapes is what makes that a fact somebody can check
#   rather than a claim.
#
# WHAT IS RENDERED:
#   * `render_gcp_route_rules` — the url-map `routeRules[]` fragment, using
#     `matchRules[].headerMatches[]` with `headerName: ":method"`. This is the
#     shape a path-only renderer cannot produce, and the reason the option is
#     alive on GCP at all.
#   * `render_aws_listener_rules` — the ELBv2 `create-rule --conditions` JSON,
#     using the first-class `http-request-method` condition. The portable twin.
#   There is deliberately NO CloudFront or Azure Front Door render: both edges
#   lack the method-match primitive, so a render would be config that cannot be
#   applied. `split_verdict` refuses those combinations before this file is
#   reached, and a renderer that emitted something anyway would defeat it.
#
# ⚠ THESE RENDERS ARE NOT WIRED INTO A DEPLOY. They are text a human can diff
#   against a live url-map and a test can pin. Wiring them means adding a method
#   field to the load-balancer route rule (and the deploy manifest's web route
#   rule) and moving the url-map body from `pathRules` to `routeRules` — a real
#   change to the front door's routing model.
#
# ENCAPSULATION: pure String render. NO UnsafePointer, NO wildcard origin, no
#   I/O.
# =============================================================================

from kci_edge.transport_split import RouteFacet


def lb_prefix_of(pattern: String) -> String:
    """An app route PATTERN -> the load-balancer PATH PREFIX that covers it.

    `/calendars/{owner}/{c}/{item}` -> `/calendars/`; `/rooms/{room}/send` ->
    `/rooms/`; `/healthz` -> `/healthz`; `/{repo}/git-upload-pack` -> `/`.

    ★ THE TRANSLATION IS TRUNCATE-AT-THE-FIRST-VARIABLE-SEGMENT, and it must
    round UP (cover more) rather than down. An LB prefix that covered LESS than
    the pattern would leave real requests unmatched and falling through to the
    default backend — which on a split front door is the managed gateway, i.e.
    the backend that cannot serve them. Covering more is visible (two rules
    overlap and priority decides); covering less is a 404 nobody attributes to
    the url-map.

    ⚠ `/{repo}/...` truncating to `/` is not a defect of this function, it is the
    shape of git's URL space: the repo name is the FIRST segment, so every
    git-wire path is under the root and no prefix narrower than `/` covers it.
    That is why a git server's split is expressed with a SUFFIX discriminator
    (matching `<first>.git`) rather than a prefix, with its git rules as
    explicit per-repo paths or a `.git`-suffix regex rather than a prefix
    match. A caller that hands this a `{capture}`-first pattern and uses the
    `/` it gets back has routed the whole site to one backend."""
    var segs = List[String]()
    var cur = String("")
    var b = pattern.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(47):  # '/'
            segs.append(cur^)
            cur = String("")
        else:
            cur += chr(Int(b[i]))
    segs.append(cur^)

    var out = String("")
    var truncated = False
    for s in range(len(segs)):
        var seg = segs[s].copy()
        if len(seg.as_bytes()) == 0:
            continue
        var vb = seg.as_bytes()
        if vb[0] == UInt8(123) or seg == String("*"):  # '{' or a bare '*'
            truncated = True
            break
        out += String("/") + seg
    if truncated:
        return out + String("/")
    if len(out.as_bytes()) == 0:
        return String("/")
    return out^


def exotic_methods_of(facets: List[RouteFacet]) -> List[String]:
    """The DISTINCT extension verbs in an inventory, in first-seen order.

    First-seen rather than sorted so the rendered rule order tracks the app's own
    table order — a reviewer diffing the render against the app's route table reads
    them in the same sequence. Wildcard (`""`) rows are skipped: they have no verb
    to match on, and a rule matching the empty method matches nothing. An app with
    a wildcard row therefore renders FEWER rules than it needs, which is why
    `is_standard_http_method("")` classifies such a row exotic — the census
    refuses to call the app splittable, and this render is never reached."""
    var out = List[String]()
    for i in range(len(facets)):
        if facets[i].rides_managed_gateway():
            continue
        var m = facets[i].method.copy()
        if len(m.as_bytes()) == 0:
            continue
        var seen = False
        for s in range(len(out)):
            if out[s] == m:
                seen = True
                break
        if seen:
            continue
        out.append(m^)
    return out^


def exotic_prefixes_of(facets: List[RouteFacet]) -> List[String]:
    """The DISTINCT LB path prefixes carrying at least one exotic row, first-seen
    order. The paths the split's exotic rules must cover."""
    var out = List[String]()
    for i in range(len(facets)):
        if facets[i].rides_managed_gateway():
            continue
        var p = lb_prefix_of(facets[i].path_pattern)
        var seen = False
        for s in range(len(out)):
            if out[s] == p:
                seen = True
                break
        if seen:
            continue
        out.append(p^)
    return out^


def render_gcp_route_rules(
    facets: List[RouteFacet],
    managed_backend: String,
    exotic_backend: String,
) -> String:
    """The GCP url-map `routeRules[]` fragment for a METHOD split.

    ★ THE ONE LINE THAT MAKES THIS POSSIBLE is `"headerName": ":method"`.
    `HttpHeaderMatch` documents it: "For matching against the HTTP request's
    authority, use a headerMatch with the header name \":authority\". For matching
    a request's method, use the headerName \":method\"." Without it every rule
    here would have to be a `pathRules[]` entry and the two halves would be
    inseparable on a shared path.

    PRIORITY ORDER IS THE WHOLE CORRECTNESS ARGUMENT. `routeRules` are evaluated
    by ascending `priority`, first match wins, so every EXOTIC rule is emitted
    BEFORE the managed catch-all. Emitting the catch-all first would send
    `PROPFIND /calendars/x` to the managed gateway, which is precisely the
    misroute the split exists to prevent — and it would do so silently, with a
    405 from a proxy rather than an error from the config.

    ONE RULE PER (prefix, method) PAIR rather than one rule listing every method:
    `matchRules[].headerMatches[]` entries are ANDed, so a single rule with five
    `:method` matches matches NOTHING (no request has five methods at once). This
    is the shape of bug that reads correct and routes nothing."""
    var methods = exotic_methods_of(facets)
    var prefixes = exotic_prefixes_of(facets)
    var out = String('"routeRules": [\n')
    var priority = 1
    for p in range(len(prefixes)):
        for m in range(len(methods)):
            out += String("  {\n")
            out += String('    "priority": ') + String(priority) + String(",\n")
            out += String('    "description": "transport split: ')
            out += methods[m] + String(" ") + prefixes[p]
            out += String(' -> the exotic backend",\n')
            out += String('    "matchRules": [{\n')
            out += String('      "prefixMatch": "') + prefixes[p] + String(
                '",\n'
            )
            out += String('      "headerMatches": [{\n')
            out += String('        "headerName": ":method",\n')
            out += String('        "exactMatch": "') + methods[m] + String(
                '"\n'
            )
            out += String("      }]\n")
            out += String("    }],\n")
            out += String('    "service": "') + exotic_backend + String('"\n')
            out += String("  },\n")
            priority += 1
    # THE MANAGED CATCH-ALL, LAST. Every request that matched no exotic rule.
    out += String("  {\n")
    out += String('    "priority": ') + String(priority) + String(",\n")
    out += String(
        '    "description": "everything else -> the managed gateway",\n'
    )
    out += String('    "matchRules": [{ "prefixMatch": "/" }],\n')
    out += String('    "service": "') + managed_backend + String('"\n')
    out += String("  }\n")
    out += String("]\n")
    return out^


def render_aws_listener_rules(
    facets: List[RouteFacet],
    managed_target: String,
    exotic_target: String,
) -> String:
    """The AWS ELBv2 listener rules for the SAME split — the portability twin.

    ★ `http-request-method` is a FIRST-CLASS condition and the AWS docs state
    "You can specify standard or custom HTTP methods", with `["CUSTOM-METHOD"]`
    as their own example. So unlike GCP, both the MATCH and the FORWARD of an
    extension verb are documented, and this render carries no caveat.

    THE SHAPE DIFFERS FROM GCP IN ONE WAY THAT MATTERS: an ALB rule may hold at
    most ONE `http-request-method` condition, but that condition takes UP TO THREE
    values which are ORed. So the render packs methods three-to-a-rule rather than
    one-to-a-rule. Packing them is not an optimization — an ALB listener has a
    rule quota, and a CalDAV server's five verbs across its prefixes would
    otherwise spend more rules than the split is worth. The three-value chunking
    loop below is where that limit lives; a fourth value in a chunk is rejected
    by the API."""
    var methods = exotic_methods_of(facets)
    var prefixes = exotic_prefixes_of(facets)
    var out = String("[\n")
    var priority = 10
    for p in range(len(prefixes)):
        var start = 0
        while start < len(methods):
            var stop = start + 3
            if stop > len(methods):
                stop = len(methods)
            out += String("  {\n")
            out += String('    "Priority": ') + String(priority) + String(",\n")
            out += String('    "Conditions": [\n')
            out += String('      { "Field": "path-pattern",')
            out += String(' "PathPatternConfig": { "Values": ["')
            out += prefixes[p]
            if prefixes[p].endswith(String("/")):
                out += String("*")
            out += String('"] } },\n')
            out += String('      { "Field": "http-request-method",')
            out += String(' "HttpRequestMethodConfig": { "Values": [')
            for m in range(start, stop):
                if m > start:
                    out += String(", ")
                out += String('"') + methods[m] + String('"')
            out += String("] } }\n")
            out += String("    ],\n")
            out += String(
                '    "Actions": [{ "Type": "forward", "TargetGroupArn": "'
            )
            out += exotic_target + String('" }]\n')
            out += String("  },\n")
            priority += 1
            start = stop
    out += String("  {\n")
    out += String('    "Priority": "default",\n')
    out += String('    "Conditions": [],\n')
    out += String('    "Actions": [{ "Type": "forward", "TargetGroupArn": "')
    out += managed_target + String('" }]\n')
    out += String("  }\n")
    out += String("]\n")
    return out^
