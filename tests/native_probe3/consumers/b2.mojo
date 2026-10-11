# Probe 3's program for B2 and B3: s2n-tls called by raw external_call, no
# komira Mojo import, linked against libkomira_http_core_native.so only. Its
# aws-lc (libkomira_crypto_native.so.1) is found through http_core's own
# DT_RUNPATH $ORIGIN, or (B3, no DT_RUNPATH) not at all.
from std.ffi import external_call
from p3util import report


def main() raises:
    var rc_init = external_call["komira_s2n_init", Int32]()
    var cfg = external_call["komira_s2n_config_new", Int]()
    var pref = String("default_tls13")
    var rc_pref = external_call["komira_s2n_config_set_cipher_preferences", Int32](cfg, pref.as_c_string_slice().unsafe_ptr())
    _ = pref.byte_length()  # keep-alive: s2n reads the name during the call only
    var conn = external_call["komira_s2n_connection_new", Int](Int32(1))  # S2N_CLIENT
    var rc_set = external_call["komira_s2n_connection_set_config", Int32](conn, cfg)
    var rc_cfree = external_call["komira_s2n_connection_free", Int32](conn)
    var rc_free = external_call["komira_s2n_config_free", Int32](cfg)
    var ok = rc_init == 0 and cfg != 0 and rc_pref == 0 and conn != 0 and rc_set == 0 and rc_cfree == 0 and rc_free == 0
    _ = report(
        "s2n_raw_config_and_connection",
        ok,
        "komira_s2n_init " + String(rc_init) + ", set_cipher_preferences(default_tls13) " + String(rc_pref) + ", connection_set_config " + String(rc_set),
    )
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
