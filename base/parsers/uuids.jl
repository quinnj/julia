# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

"""
    parseuuid(buf, i, j) -> (UInt128, rc)

The canonical 8-4-4-4-12 dashed hex form, case-insensitive — exactly the
spellings `Base.tryparse(UUID, s)` accepts. Returns the raw UInt128; thin
adapters construct `Base.UUID` (mirroring the CivilParts/Dates split).
"""
function parseuuid(buf::AbstractVector{UInt8}, i::Int, j::Int)
    j - i + 1 == 36 || return (UInt128(0), RC_INVALID)
    @inbounds begin
        (buf[i + 8] == UInt8('-')) & (buf[i + 13] == UInt8('-')) &
        (buf[i + 18] == UInt8('-')) & (buf[i + 23] == UInt8('-')) ||
            return (UInt128(0), RC_INVALID)
    end
    # 8-4-4-4-12 → four 8-hex-char words. The 4-char groups pair up via their
    # low 32 bits (loads at 9|14 and 19|24); every load stays inside the span.
    w1 = _load8(buf, i)
    w2 = (_load8(buf, i + 9) & 0x00000000ffffffff) | (_load8(buf, i + 14) << 32)
    w3 = (_load8(buf, i + 19) & 0x00000000ffffffff) | (_load8(buf, i + 24) << 32)
    w4 = _load8(buf, i + 28)
    v1, ok1 = _hex8(w1)
    v2, ok2 = _hex8(w2)
    v3, ok3 = _hex8(w3)
    v4, ok4 = _hex8(w4)
    ok1 & ok2 & ok3 & ok4 || return (UInt128(0), RC_INVALID)
    return ((UInt128(v1) << 96) | (UInt128(v2) << 64) | (UInt128(v3) << 32) | UInt128(v4), RC_OK)
end

# Eight ASCII hex chars (either case) in one word → (UInt32 value, valid). Byte
# k of `w` is character k, so the first character is the most significant
# nibble of the result. Branch-free: lowercase, range-test digits and a-f
# lanes with the borrow-free trick, pick the nibble as (b & 0x0f) + 9·isalpha
# ('a'..'f' have low nibbles 1..6), then fold the eight nibbles together.
@inline function _hex8(w::UInt64)
    w |= 0x2020202020202020                       # 'A'..'F' → 'a'..'f'; digits unchanged
    # digit lanes: bytes in 0x30..0x39; alpha lanes: bytes in 0x61..0x66
    d = w ⊻ 0x3030303030303030                     # digit ⇒ 0x00..0x09
    a = w ⊻ 0x6060606060606060                     # 'a'..'f' ⇒ 0x01..0x06
    isdig = ((d + 0x7676767676767676) & 0x8080808080808080) ⊻ 0x8080808080808080  # d <= 9 ⇒ no carry into bit 7
    isalp = ((a + 0x7979797979797979) & 0x8080808080808080) ⊻ 0x8080808080808080  # a <= 6
    isalp &= ((a - 0x0101010101010101) & 0x8080808080808080) ⊻ 0x8080808080808080 # a >= 1
    # each lane must be exactly one of the two, and high bytes (>= 0x80) never
    # qualify: exclude them via the byte's own high bit
    hi = w & 0x8080808080808080
    ok = ((isdig | isalp) & ~hi) == 0x8080808080808080
    nib = (w & 0x0f0f0f0f0f0f0f0f) + ((isalp >> 7) * 0x09)   # + 9 on alpha lanes
    # fold 8 nibbles (byte lanes) into 32 bits, first char most significant
    t = ((nib & 0x000f000f000f000f) << 4) | ((nib & 0x0f000f000f000f00) >> 8)
    t = ((t & 0x000000ff000000ff) << 8) | ((t & 0x00ff000000ff0000) >> 16)
    t = ((t & 0x000000000000ffff) << 16) | ((t & 0x0000ffff00000000) >> 32)
    return (UInt32(t & 0xffffffff), ok)
end
