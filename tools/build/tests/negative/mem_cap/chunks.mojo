from std.time import sleep

comptime CHUNK_MIB = 64


def hold_chunks(limit: Int, hold_secs: Float64) raises -> Int:
    """Allocates and writes 64 MiB chunks, keeping every one, until it holds
    `limit` of them; prints the amount held after each; then keeps them for
    `hold_secs` (so a sampled cap sees them) and returns the sum of one byte
    read back from each chunk (so nothing is optimized away)."""
    var size = CHUNK_MIB * 1024 * 1024
    var chunks = List[List[UInt8]]()
    var total = 0
    while len(chunks) < limit:
        chunks.append(List[UInt8](length=size, fill=UInt8(len(chunks) % 251 + 1)))
        total += Int(chunks[len(chunks) - 1][size - 1])
        print("MEMCAP_FIXTURE holds", len(chunks) * CHUNK_MIB, "MiB", flush=True)
    sleep(hold_secs)
    for i in range(len(chunks)):
        total += Int(chunks[i][0]) - Int(chunks[i][size - 1])
    return total
