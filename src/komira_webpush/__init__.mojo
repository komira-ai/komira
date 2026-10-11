"""`komira_webpush`: Web Push message encryption.

  - content_coding.mojo  the "aes128gcm" HTTP content coding (RFC 8188):
                         header, key and nonce derivation, one-record
                         encryption, multi-record decryption
  - message.mojo         Web Push message encryption (RFC 8291) on P-256
                         ECDH: `webpush_encrypt` (a fresh salt and sender
                         key per message), `webpush_encrypt_with` (the
                         salt and sender key from a `WebPushRandomness`),
                         `webpush_decrypt` (the user agent's side)

Sending (RFC 8030 and VAPID, RFC 8292) is not here.
"""

from .content_coding import (
    Aes128GcmHeader,
    Aes128GcmKeys,
    aes128gcm_decrypt,
    aes128gcm_encrypt,
    aes128gcm_keys,
    aes128gcm_parse_header,
)
from .message import (
    AUTH_SECRET_SIZE,
    MAX_PLAINTEXT_SIZE,
    PUBLIC_KEY_SIZE,
    RECORD_SIZE,
    SystemWebPushRandomness,
    WebPushRandomness,
    p256_public_key,
    webpush_decrypt,
    webpush_encrypt,
    webpush_encrypt_with,
    webpush_ikm,
)
