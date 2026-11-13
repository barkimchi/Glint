"""Sign a Sparkle update archive. Drop-in replacement for Sparkle's sign_update,
with no downloaded binary: pure-Python Ed25519 (RFC 8032), deterministic output.

Usage: echo "$SPARKLE_PRIVATE_KEY" | python3 .github/sign_update.py --ed-key-file - <archive>
Prints sign_update's exact output format: sparkle:edSignature="..." length="..."

The key is Sparkle's base64-encoded 64-byte private key (32-byte seed || 32-byte
public key), as printed by Sparkle's generate_keys.
"""
import base64
import hashlib
import sys

p = 2**255 - 19
q = 2**252 + 27742317777372353535851937790883648493
d = -121665 * pow(121666, p - 2, p) % p
I = pow(2, (p - 1) // 4, p)


def xrecover(y):
    xx = (y * y - 1) * pow(d * y * y + 1, p - 2, p) % p
    x = pow(xx, (p + 3) // 8, p)
    if (x * x - xx) % p != 0:
        x = x * I % p
    if x % 2 != 0:
        x = p - x
    return x


By = 4 * pow(5, p - 2, p) % p
B = (xrecover(By), By)


def edwards(P, Q):
    (x1, y1), (x2, y2) = P, Q
    x3 = (x1 * y2 + x2 * y1) * pow(1 + d * x1 * x2 * y1 * y2, p - 2, p) % p
    y3 = (y1 * y2 + x1 * x2) * pow(1 - d * x1 * x2 * y1 * y2, p - 2, p) % p
    return (x3, y3)


def scalarmult(P, e):
    Q = (0, 1)
    while e > 0:
        if e & 1:
            Q = edwards(Q, P)
        P = edwards(P, P)
        e >>= 1
    return Q


def encodeint(y):
    return y.to_bytes(32, "little")


def encodepoint(P):
    x, y = P
    bits = bytearray(encodeint(y))
    bits[31] |= (x & 1) << 7
    return bytes(bits)


def H(m):
    return hashlib.sha512(m).digest()


def sign(seed, msg):
    h = H(seed)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    A = encodepoint(scalarmult(B, a))
    r = int.from_bytes(H(h[32:] + msg), "little") % q
    R = encodepoint(scalarmult(B, r))
    S = (r + int.from_bytes(H(R + A + msg), "little") * a) % q
    return R + encodeint(S)


def main():
    args = sys.argv[1:]
    if len(args) != 3 or args[0] != "--ed-key-file":
        sys.exit("usage: sign_update.py --ed-key-file <path|-> <archive>")
    keysrc, archive = args[1], args[2]
    keyb64 = (sys.stdin.read() if keysrc == "-" else open(keysrc).read()).strip()
    raw = base64.b64decode(keyb64)
    if len(raw) != 64:
        sys.exit("expected Sparkle's 64-byte private key, got %d bytes" % len(raw))
    data = open(archive, "rb").read()
    sig = sign(raw[:32], data)
    print('sparkle:edSignature="%s" length="%d"' % (base64.b64encode(sig).decode(), len(data)))


if __name__ == "__main__":
    main()
