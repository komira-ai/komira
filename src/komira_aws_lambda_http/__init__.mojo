"""`komira_aws_lambda_http` — run a shipped `RequestDispatcher` on AWS Lambda
behind API Gateway, without the dispatcher learning it is on Lambda.

Pass in the right runtime and everything works: a Lambda that receives an API
Gateway message handles it exactly as a server handles a request.

FIVE files, one seam each — THREE PAYLOAD SHAPES AND THREE LOOPS, because the
shapes OVERLAP on every field a naive converter reads. API Gateway's PROXY event
and its REQUEST-AUTHORIZER event agree on everything but `type` (see
`apigw_authorizer`'s header for the measured table); the EventBridge Scheduler
TICK and a REST-API 1.0 proxy event agree on `httpMethod` and `path` and on
carrying no `version` (see `eventbridge_tick`'s §2). One parser for any pair
would be one parser that cannot tell a request from an authorization question,
or a caller's request from a scheduled backstop.

  `apigw_v2`  the API Gateway payload-format-**2.0** proxy event <-> the
              `HttpRequest` / `HttpResponse` the dispatcher already takes. The
              version is PINNED and ASSERTED (a 1.0 event is refused, not
              coerced), `isBase64Encoded` is honoured in BOTH directions, and
              every client-supplied `x-komira-authorizer-*` header is destroyed
              on entry so an authorizer's answer cannot be forged by the caller.

  `pump`      the invoke loop, parametric over `LambdaInvocationTransport` and
              `LambdaPostResponseFlush` so it can be driven with no cloud.
              A binary's Runtime API client and its log drain are adapted to
              those traits at the binary — which is also why the dependency
              edges point down and not at any particular client or drain.

  `eventbridge_tick`
              the EventBridge Scheduler TICK. ⛔ A scheduled call arrives as a
              BARE Invoke, NOT as an HTTP event, because Scheduler CANNOT target
              an HTTPS URL — so the schedule's `path` and `http_method` travel
              as DATA in `Target.Input` and this is the far side of that
              contract. The DISCRIMINATOR IS `version`, read FIRST and in BOTH
              DIRECTIONS: this converter refuses on its PRESENCE, `apigw_v2`
              refuses on its ABSENCE, and nothing in this package may ever try
              one converter and fall back to the other. It also carries
              `classify_lambda_event` and, in `pump`, the classifying entry
              point `run_api_gateway_and_tick_pump`.

  `apigw_authorizer`
              the REQUEST-authorizer event (`"type": "REQUEST"`, ASSERTED —
              it is the ONLY field that separates it from a proxy event) and
              the SIMPLE response `{"isAuthorized": bool, "context": {...}}`.
              A non-allow serializes an EMPTY context, enforced by the
              serializer rather than by its callers.

  `authorizer_pump`
              the authorizer invoke loop. THREE answers, TWO channels: allow
              and deny are `respond_ok` (200/403 at the gateway); UNAVAILABLE,
              a conformer raise, an unparseable event and every unknown
              ordinal take the invocation ERROR channel — a 500 that API
              Gateway does NOT cache.

⛔ THE ONE ORDERING RULE IN THIS PACKAGE: the drain runs AFTER
the invocation result is posted and BEFORE the next `/invocation/next` poll.
Earlier bills the caller for an S3 conditional PUT; later runs in a frozen
sandbox. `pump.mojo`'s header carries the full argument and
`tests/test_pump_flush_ordering.mojo` goes RED on each inversion.

⚠ WHAT IS DELIBERATELY NOT HERE: the `Runtime` conformer. `AwsLambdaRuntime`
lives in `komira_async.runtime.aws_lambda_runtime` beside its sibling
`GcpCloudRunRuntime`, because it is a reactor-owning runtime and knows nothing
about HTTP. `komira_async` sits UNDER `komira_http_core`; putting the conformer
here would invert that edge.
"""

from .apigw_v2 import (
    APIGW_PAYLOAD_VERSION,
    AUTHORIZER_HEADER_PREFIX,
    api_gateway_v2_event_to_request,
    response_to_api_gateway_v2,
)
from .apigw_authorizer import (
    APIGW_AUTHORIZER_EVENT_TYPE,
    AUTHZ_ANSWER_ALLOW,
    AUTHZ_ANSWER_DENY,
    AUTHZ_ANSWER_UNAVAILABLE,
    ApiGatewayAuthorizerEvent,
    AuthorizerAnswer,
    authorizer_deny_json,
    authorizer_simple_response_json,
    parse_api_gateway_authorizer_event,
)
from .eventbridge_tick import (
    APIGW_DISCRIMINATOR_KEY,
    LAMBDA_EVENT_KIND_API_GATEWAY,
    LAMBDA_EVENT_KIND_SCHEDULED_TICK,
    TICK_METHOD_KEY,
    TICK_PATH_KEY,
    classify_lambda_event,
    eventbridge_tick_event_to_request,
)
from .authorizer_pump import LambdaAuthorizer, run_authorizer_pump
from .pump import (
    LambdaInvocationTransport,
    LambdaInvokeEvent,
    LambdaPostResponseFlush,
    NoLambdaFlush,
    announce_init_failure,
    run_api_gateway_and_tick_pump,
    run_api_gateway_pump,
)
