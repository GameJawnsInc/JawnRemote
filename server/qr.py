"""
Tiny QR Code generator -- pure Python stdlib, no dependencies.

Scope: byte mode, Version 3, error-correction level M, mask pattern 0.
That's a 29x29 grid holding up to 44 data codewords -- ample for the short
LAN URLs we encode (e.g. http://255.255.255.255:65535/ is ~31 codewords).
Fixing the version/ecc/mask keeps this a single Reed-Solomon block with no
interleaving and no version-info modules, so the whole thing stays small.

`matrix(text)` returns a 29x29 list of lists of bool (True = dark module),
with NO quiet zone -- the caller adds the border when rendering.

Verified byte-for-byte against the `qrcode` library (version=3,
ERROR_CORRECT_M, mask_pattern=0, MODE_8BIT_BYTE) in dev; only stdlib ships.
"""

VERSION = 3
SIZE = 29              # 17 + 4*VERSION
DATA_CW = 44          # data codewords (V3-M, single block)
EC_CW = 26            # error-correction codewords (V3-M)
ECL_FORMAT_BITS = 0   # ECC level M -> 0b00
MASK = 0              # mask pattern 0: (row + col) % 2 == 0

# --------------------------------------------------------------------------- #
#  GF(256) arithmetic for Reed-Solomon (QR primitive polynomial 0x11D)
# --------------------------------------------------------------------------- #
_EXP = [0] * 512
_LOG = [0] * 256


def _init_gf():
    x = 1
    for i in range(255):
        _EXP[i] = x
        _LOG[x] = i
        x <<= 1
        if x & 0x100:
            x ^= 0x11D
    for i in range(255, 512):
        _EXP[i] = _EXP[i - 255]


_init_gf()


def _gf_mul(a, b):
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_generator(n):
    """Generator polynomial of degree n, coefficients high-to-low, leading 1."""
    g = [1]
    for i in range(n):
        new = [0] * (len(g) + 1)
        for j, c in enumerate(g):
            new[j] ^= c
            new[j + 1] ^= _gf_mul(c, _EXP[i])
        g = new
    return g


def _rs_ec(data, n):
    """Return the n error-correction codewords for the data codewords."""
    g = _rs_generator(n)
    rem = list(data) + [0] * n
    for i in range(len(data)):
        coef = rem[i]
        if coef:
            for j in range(n + 1):
                rem[i + j] ^= _gf_mul(g[j], coef)
    return rem[-n:]


# --------------------------------------------------------------------------- #
#  Bit stream -> codewords
# --------------------------------------------------------------------------- #
def _codewords(text):
    data = text.encode("utf-8")
    if len(data) > DATA_CW - 2:
        raise ValueError("text too long for a Version 3 / M QR code")
    bits = []

    def put(val, n):
        for i in range(n - 1, -1, -1):
            bits.append((val >> i) & 1)

    put(0b0100, 4)              # byte mode
    put(len(data), 8)           # char count (8 bits for versions 1-9)
    for byte in data:
        put(byte, 8)

    cap = DATA_CW * 8
    put(0, min(4, cap - len(bits)))     # terminator
    while len(bits) % 8 != 0:           # pad to byte boundary
        bits.append(0)

    cw = []
    for i in range(0, len(bits), 8):
        b = 0
        for bit in bits[i:i + 8]:
            b = (b << 1) | bit
        cw.append(b)

    pad = [0xEC, 0x11]
    i = 0
    while len(cw) < DATA_CW:
        cw.append(pad[i % 2])
        i += 1
    return cw


# --------------------------------------------------------------------------- #
#  Module placement
# --------------------------------------------------------------------------- #
def _blank():
    mods = [[False] * SIZE for _ in range(SIZE)]
    func = [[False] * SIZE for _ in range(SIZE)]
    return mods, func


def _set(mods, func, r, c, val):
    if 0 <= r < SIZE and 0 <= c < SIZE:
        mods[r][c] = bool(val)
        func[r][c] = True


def _finders(mods, func):
    for (fr, fc) in [(0, 0), (0, SIZE - 7), (SIZE - 7, 0)]:
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                if dr in (-1, 7) or dc in (-1, 7):
                    val = False                      # separator
                else:
                    val = (dr in (0, 6) or dc in (0, 6) or
                           (2 <= dr <= 4 and 2 <= dc <= 4))
                _set(mods, func, fr + dr, fc + dc, val)


def _timing(mods, func):
    for i in range(SIZE):
        if not func[6][i]:
            _set(mods, func, 6, i, i % 2 == 0)
        if not func[i][6]:
            _set(mods, func, i, 6, i % 2 == 0)


def _alignment(mods, func):
    cr = cc = SIZE - 7        # single alignment pattern centered at (22, 22)
    for dr in range(-2, 3):
        for dc in range(-2, 3):
            val = (abs(dr) == 2 or abs(dc) == 2 or (dr == 0 and dc == 0))
            _set(mods, func, cr + dr, cc + dc, val)


def _getbit(x, i):
    return (x >> i) & 1


def _format(mods, func):
    data = (ECL_FORMAT_BITS << 3) | MASK
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    bits = ((data << 10) | rem) ^ 0x5412      # 15-bit format string
    bits = int(format(bits, "015b")[::-1], 2)  # placed LSB-first (matches readers)

    for i in range(6):
        _set(mods, func, 8, i, _getbit(bits, i))
    _set(mods, func, 8, 7, _getbit(bits, 6))
    _set(mods, func, 8, 8, _getbit(bits, 7))
    _set(mods, func, 7, 8, _getbit(bits, 8))
    for i in range(9, 15):
        _set(mods, func, 14 - i, 8, _getbit(bits, i))

    for i in range(7):
        _set(mods, func, SIZE - 1 - i, 8, _getbit(bits, i))
    for i in range(7, 15):
        _set(mods, func, 8, SIZE - 15 + i, _getbit(bits, i))
    _set(mods, func, SIZE - 8, 8, True)       # dark module


def _place_data(mods, func, codewords):
    bit = 0
    total = len(codewords) * 8
    right = SIZE - 1
    while right > 0:
        if right == 6:
            right = 5
        for vert in range(SIZE):
            for j in range(2):
                col = right - j
                upward = ((right + 1) & 2) == 0
                row = (SIZE - 1 - vert) if upward else vert
                if not func[row][col]:
                    v = 0
                    if bit < total:
                        v = _getbit(codewords[bit >> 3], 7 - (bit & 7))
                    if (row + col) % 2 == 0:        # mask pattern 0
                        v ^= 1
                    mods[row][col] = bool(v)
                    bit += 1
        right -= 2


def matrix(text):
    """Return the QR modules for `text` as a 29x29 list of lists of bool."""
    cw = _codewords(text)
    cw = cw + _rs_ec(cw, EC_CW)        # 44 data + 26 EC = 70 codewords
    mods, func = _blank()
    _finders(mods, func)
    _timing(mods, func)
    _alignment(mods, func)
    _format(mods, func)
    _place_data(mods, func, cw)
    return mods
