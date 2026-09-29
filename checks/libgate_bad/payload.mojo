@fieldwise_init
struct GatePayload(Copyable, Movable):
    var width: Int


def payload_width() -> Int:
    return GatePayload(7).width
