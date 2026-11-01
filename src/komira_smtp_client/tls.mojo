# The TLS client configuration of the SMTP client.

from komira_http_core.tls import TlsConfig


def tls_client_config(trust_pem: String) raises -> TlsConfig:
    """A client configuration that verifies the server: TLS 1.3 and 1.2, the
    system roots when `trust_pem` is empty, else exactly the roots of
    `trust_pem` (the system roots are removed first). There is no way here to
    turn verification off."""
    var cfg = TlsConfig()
    cfg.set_cipher_preferences(String("default_tls13"))
    cfg.enable_verify_default()
    if trust_pem.byte_length() > 0:
        cfg.wipe_trust()
        cfg.add_trust_pem(trust_pem)
    return cfg^
