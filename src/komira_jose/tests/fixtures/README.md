# Test fixtures

`rsa_test_key.pem` is a 2048-bit RSA private key (PKCS#8 PEM) made only for
tests. It is public, it protects nothing, and it must never sign or decrypt
anything real. komira_jose, komira_oauth and komira_http_auth tests read it
to sign RS256 tokens and assertions.

It was generated once with a Miller-Rabin prime search (two 1024-bit primes,
public exponent 65537) from the operating system's random source, and checked
by an RSA round trip (raise to e, then to d) and the CRT parameter
identities before it was committed.
