# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

module ParsersExt

import ..GMP: BigInt
import Base.Parsers: _dispatch, _dispatchdefault, baseparse_internal, parsebigint, parsenext
using Base.Parsers: RC_INVALID, RC_OK, RC_OVERFLOW, _POW10U64, _digits19,
                   _digitvalue, _hasbyte, _indexwindow, _integerprefixconfig,
                   _intgroupbyte, _intprefix, _needsindexwindow, _normalizebase,
                   _prefixbounds, _q, _restoreexactposition, _runprefix,
                   _spanstring, _stripws, _isws, parseint_preamble,
                   degroupint!, parseint, parseint64

const _GMP_SIZE_T = Clong

# --- decimal digits to limbs, in Julia --------------------------------------------
# Digits gather eight at a time into chunks of _chunkdigits(L) decimal digits
# (19 for 64-bit limbs, 9 for 32-bit), and each chunk multiply-accumulates into
# the BigInt's own limb storage. GMP never sees a digit string: it allocates,
# and the finished limb count is written to the size field.
const _Limb = Base.GMP.Limb
@inline _chunkdigits(::Type{UInt64}) = 19
@inline _chunkdigits(::Type{UInt32}) = 9
@inline _chunkmult(::Type{UInt64}) = UInt64(10)^19
@inline _chunkmult(::Type{UInt32}) = UInt32(10)^9
@inline _widelimb(::Type{UInt64}) = UInt128
@inline _widelimb(::Type{UInt32}) = UInt64

# limbs ← limbs × mult + add over `size` little-endian limbs; the new size
@inline function _mulacc!(limbs::Ptr{L}, size::Int, mult::L, add::L) where {L <: Unsigned}
    W = _widelimb(L)
    carry = W(add)
    for l in 1:size
        p = W(unsafe_load(limbs, l)) * W(mult) + carry
        unsafe_store!(limbs, p % L, l)
        carry = p >> (8 * sizeof(L))
    end
    if carry != 0
        size += 1
        unsafe_store!(limbs, carry % L, size)
    end
    return size
end

# Limbs that hold `ndig` decimal digits: ⌈ndig·log2(10)⌉ bits, rounded up.
@inline function _limbsfordigits(::Type{L}, ndig::Int) where {L <: Unsigned}
    ndig >= 0 || throw(ArgumentError("digit count must be nonnegative"))
    bits = (widemul(ndig, 3402) >> 10) + 1
    limbs = cld(bits, 8 * sizeof(L))
    limbs <= typemax(Int) ||
        throw(OverflowError("BigInt limb count is not representable"))
    return Int(limbs)
end

@noinline _gmpcapacityoverflow() =
    throw(OverflowError("BigInt value exceeds GMP's representable limb capacity"))

@inline function _gmpbitsforlimbs(nlimbs::Int, limbbits::Int=8 * sizeof(_Limb))
    limbbits > 0 || throw(ArgumentError("limb width must be positive"))
    0 <= nlimbs <= typemax(Cint) || _gmpcapacityoverflow()
    bits = UInt128(nlimbs) * UInt128(limbbits)
    bits <= UInt128(typemax(Int)) || _gmpcapacityoverflow()
    bits <= UInt128(typemax(Culong)) || _gmpcapacityoverflow()
    return Int(bits)
end

@inline _gmpmaxvaluebits() = min(UInt128(typemax(Int)),
                                 UInt128(typemax(Culong)),
                                 UInt128(typemax(Cint)) * UInt128(8 * sizeof(_Limb)))

@inline function _gmpcheckedaddbits(bits::Int, add::Int)
    bits >= 0 && add >= 0 || _gmpcapacityoverflow()
    total = UInt128(bits) + UInt128(add)
    total <= _gmpmaxvaluebits() || _gmpcapacityoverflow()
    return Int(total)
end

@inline function _gmpsize(size::Int)
    -typemax(Cint) <= size <= typemax(Cint) || _gmpcapacityoverflow()
    return Cint(size)
end

@inline function _gmpgrowcapacity(size::Int, capacity::Int)
    size < typemax(Cint) || _gmpcapacityoverflow()
    needed = size + 1
    doubled = capacity <= typemax(Cint) ÷ 2 ? 2capacity : Int(typemax(Cint))
    return max(needed, max(4, doubled))
end

# Feed buf[k : stop-1] into chunks; `acc`/`nacc` carry a partial chunk between
# calls so a decimal point can split a digit run. Completed chunks flush into
# the limbs. Returns (size, acc, nacc, ok).
@inline function _feeddigits!(limbs::Ptr{L}, size::Int, acc::UInt64, nacc::Int,
                              buf::AbstractVector{UInt8}, k::Int, stop::Int) where {L <: Unsigned}
    while k < stop
        t = min(_chunkdigits(L) - nacc, stop - k)
        v, ok = _digits19(buf, k, t)
        ok || return (size, acc, nacc, false)
        acc = acc * @inbounds(_POW10U64[t + 1]) + v
        nacc += t
        k += t
        if nacc == _chunkdigits(L)
            size = _mulacc!(limbs, size, _chunkmult(L), acc % L)
            acc = zero(UInt64)
            nacc = 0
        end
    end
    return (size, acc, nacc, true)
end

@inline function _flushdigits!(limbs::Ptr{L}, size::Int, acc::UInt64, nacc::Int) where {L <: Unsigned}
    nacc == 0 && return size
    return _mulacc!(limbs, size, @inbounds(_POW10U64[nacc + 1]) % L, acc % L)
end

"""
    parsebigint(buf, i, j) -> (BigInt, rc)

Exact-span BigInt: sign and decimal digits only (the strict integer grammar,
same as `parseint64` without the width limit). The digits become limb-sized
decimal chunks that multiply-accumulate straight into the BigInt's limbs, so
the only GMP involvement is the allocation.
"""
function parsebigint(buf::AbstractVector{UInt8}, i::Int, j::Int)
    if _needsindexwindow(j)
        window, first, final = _indexwindow(buf, i, j)
        return _parsebigintdecimalexact(window, first, final)
    end
    return _parsebigintdecimalexact(buf, i, j)
end

function _parsebigintdecimalexact(buf::AbstractVector{UInt8}, i::Int, j::Int)
    i > j && return (BigInt(0), RC_INVALID)
    neg = false
    @inbounds begin
        b = buf[i]
        if b == UInt8('-') || b == UInt8('+')
            neg = b == UInt8('-')
            i += 1
        end
    end
    i > j && return (BigInt(0), RC_INVALID)
    @inbounds while i < j && buf[i] == UInt8('0')
        i += 1
    end
    nlimbs = _limbsfordigits(_Limb, j - i + 1)
    big = BigInt(; nbits=_gmpbitsforlimbs(nlimbs))
    GC.@preserve big begin
        limbs = big.d
        size, acc, nacc, ok = _feeddigits!(limbs, 0, zero(UInt64), 0, buf, i, j + 1)
        ok || return (BigInt(0), RC_INVALID)
        size = _flushdigits!(limbs, size, acc, nacc)
    end
    big.size = _gmpsize(neg ? -size : size)          # the top limb is nonzero, as GMP requires
    return (big, RC_OK)
end

"""
    parsebigint(buf, i, j, base) -> (BigInt, rc, badpos)

Exact-span arbitrary-radix BigInt parser for bases 2 through 62. The digit
mapping is identical to `parseint`. `badpos` identifies an invalid
digit; arbitrary precision means this overload cannot return `RC_OVERFLOW`.
"""
function parsebigint(buf::AbstractVector{UInt8}, i::Int, j::Int, base::Int)
    2 <= base <= 62 || throw(ArgumentError("base must be between 2 and 62"))
    if _needsindexwindow(j)
        window, first, final = _indexwindow(buf, i, j)
        result = _parsebigintradixexact(window, first, final, base)
        return _restoreexactposition(window, result)
    end
    return _parsebigintradixexact(buf, i, j, base)
end

function _parsebigintradixexact(buf::AbstractVector{UInt8}, i::Int, j::Int,
                                base::Int)
    i > j && return (BigInt(0), RC_INVALID, i)
    orig = i
    neg = false
    @inbounds begin
        b = buf[i]
        if b == UInt8('-') || b == UInt8('+')
            neg = b == UInt8('-')
            i += 1
        end
    end
    i > j && return (BigInt(0), RC_INVALID, orig)
    big = BigInt(0)
    MPZ = Base.GMP.MPZ
    @inbounds while i <= j
        d = _digitvalue(buf[i], base)
        (d == 0xff || d >= base) && return (BigInt(0), RC_INVALID, i)
        MPZ.mul_ui!(big, base % UInt)
        MPZ.add_ui!(big, d % UInt)
        i += 1
    end
    neg && MPZ.neg!(big)
    return (big, RC_OK, 0)
end

# Largest count whose radix power fits in one GMP limb. Prefix parsing gathers
# this many digits before one limb-wise multiply-add. It therefore discovers
# the token end and builds the BigInt in the same pass, without a digit-string
# rescan or a call to GMP's string parser.
const _BIGINT_RADIX_CHUNK_DIGITS = ntuple(61) do n
    b = _Limb(n + 1)
    power = one(_Limb)
    count = 0
    while power <= typemax(_Limb) ÷ b
        power *= b
        count += 1
    end
    count
end
const _BIGINT_PREFIX_STACK_LIMBS = 4
const _ZERO_BIGINT_PREFIX_LIMBS = ntuple(_ -> zero(_Limb), Val(5))

@inline function _bigintprefixmulacc(limbs::NTuple{5, L}, size::Int,
                                     mult::L, add::L) where {L <: Unsigned}
    W = _widelimb(L)
    carry = W(add)
    @inbounds for l in 1:size
        product = W(limbs[l]) * W(mult) + carry
        limbs = Base.setindex(limbs, product % L, l)
        carry = product >> (8 * sizeof(L))
    end
    if carry != 0
        size += 1
        limbs = Base.setindex(limbs, carry % L, size)
    end
    return (limbs, size)
end

function _bigintprefixfromlimbs(limbs::NTuple{5, L}, size::Int,
                                capacity::Int) where {L <: Unsigned}
    limbbits = 8 * sizeof(L)
    big = BigInt(; nbits=_gmpbitsforlimbs(max(capacity, 1), limbbits))
    GC.@preserve big begin
        @inbounds for l in 1:size
            unsafe_store!(big.d, limbs[l], l)
        end
    end
    big.size = _gmpsize(size)
    return big
end

@inline function _bigintprefixcapacity!(big::BigInt, size::Int, capacity::Int,
                                        limbbits::Int)
    size < capacity && return (big.d, capacity)
    # GMP must know how many manually-written limbs to preserve if it moves
    # the allocation.
    big.size = _gmpsize(size)
    capacity = _gmpgrowcapacity(size, capacity)
    Base.GMP.MPZ.realloc2!(big, _gmpbitsforlimbs(capacity, limbbits))
    return (big.d, capacity)
end

@inline function _bigintprefixmulacc!(big::BigInt, size::Int, capacity::Int,
                                      mult::_Limb, add::_Limb, limbbits::Int)
    GC.@preserve big begin
        limbs, capacity =
            _bigintprefixcapacity!(big, size, capacity, limbbits)
        size = _mulacc!(limbs, size, mult, add)
    end
    big.size = _gmpsize(size)
    return (size, capacity)
end

function _parsebigintprefix(buf::AbstractVector{UInt8}, pos::Int, last::Int,
                            base, groupmark)
    k, b, gm, neg, valid = _integerprefixconfig(Val(true), buf, pos, last,
                                                base, groupmark)
    valid || return (BigInt(0), pos, RC_INVALID)
    @inbounds begin
        firstdigit = k <= last ? _digitvalue(buf[k], b) : 0xff
        firstdigit < b || return (BigInt(0), pos, RC_INVALID)
    end

    limbbits = 8 * sizeof(_Limb)
    chunkdigits = @inbounds _BIGINT_RADIX_CHUNK_DIGITS[b - 1]
    abase = _Limb(b)
    acc = zero(_Limb)
    multiplier = one(_Limb)
    nchunk = 0
    size = 0
    small = _ZERO_BIGINT_PREFIX_LIMBS
    big = nothing
    capacity = 0
    sawdigit = false

    @inbounds while k <= last
        digit = _digitvalue(buf[k], b)
        if digit < b
            sawdigit = true
            acc = acc * abase + _Limb(digit)
            multiplier *= abase
            nchunk += 1
            if nchunk == chunkdigits
                if big === nothing
                    small, size = _bigintprefixmulacc(small, size, multiplier,
                                                      acc)
                    if size > _BIGINT_PREFIX_STACK_LIMBS
                        big = _bigintprefixfromlimbs(small, size,
                            2 * _BIGINT_PREFIX_STACK_LIMBS)
                        capacity = Int(big.alloc)
                    end
                else
                    size, capacity = _bigintprefixmulacc!(big, size, capacity,
                                                          multiplier, acc,
                                                          limbbits)
                end
                acc = zero(_Limb)
                multiplier = one(_Limb)
                nchunk = 0
            end
            k += 1
        elseif gm !== nothing && sawdigit && buf[k] == gm && k < last &&
               _digitvalue(buf[k + 1], b) < b
            k += 1
        else
            break
        end
    end
    if nchunk != 0
        if big === nothing
            small, size = _bigintprefixmulacc(small, size, multiplier, acc)
            if size > _BIGINT_PREFIX_STACK_LIMBS
                big = _bigintprefixfromlimbs(small, size,
                    2 * _BIGINT_PREFIX_STACK_LIMBS)
                capacity = Int(big.alloc)
            end
        else
            size, capacity = _bigintprefixmulacc!(big, size, capacity,
                                                  multiplier, acc, limbbits)
        end
    end

    # The first-byte check above establishes this, but retain the invariant at
    # the result boundary if the loop changes later.
    sawdigit || return (BigInt(0), pos, RC_INVALID)
    big === nothing && (big = _bigintprefixfromlimbs(small, size, size))
    big.size = _gmpsize(neg ? -size : size)
    return (big, k, RC_OK)
end

function _tryparsebig(::Type{BigInt}, buf, i, j, base, groupmark,
                      ::Val{Throw}) where {Throw}
    orig_i, orig_j = i, j
    i, j = _stripws(buf, i, j)
    base = _normalizebase(base)
    if i > j
        Throw && throw(ArgumentError("input string is empty or only contains whitespace"))
        return nothing
    end
    dstart, b, prefixed = _intprefix(buf, i, j, base)
    gm = _intgroupbyte(groupmark, b)
    if prefixed && dstart > j
        Throw && throw(ArgumentError("premature end of integer: $(_q(_spanstring(buf, orig_i, orig_j)))"))
        return nothing
    end
    if prefixed && @inbounds(buf[dstart]) == UInt8('+')
        # GMP (and so Base) accepts '-' between a radix prefix and the digits
        # but rejects '+'
        Throw && throw(ArgumentError("invalid BigInt: $(_q(_spanstring(buf, orig_i, orig_j)))"))
        return nothing
    end
    pbuf, pi, pj = buf, prefixed ? dstart : i, j
    if gm !== nothing && _hasbyte(pbuf, pi, pj, gm)
        scratch = Vector{UInt8}(undef, max(pj - pi + 1, 8))
        n = degroupint!(scratch, pbuf, pi, pj, gm, b)
        if n < 0
            v, rc = BigInt(0), RC_INVALID
        else
            pbuf, pi, pj = scratch, 1, n
            if b == 10
                v, rc = parsebigint(pbuf, pi, pj)
            else
                v, rc, _ = parsebigint(pbuf, pi, pj, b)
            end
        end
    elseif b == 10
        v, rc = parsebigint(pbuf, pi, pj)
    else
        v, rc, _ = parsebigint(pbuf, pi, pj, b)
    end
    prefixed && @inbounds(buf[i] == UInt8('-')) && rc == RC_OK &&
        Base.GMP.MPZ.neg!(v)
    rc == RC_OK && return v
    Throw || return nothing
    throw(ArgumentError("invalid BigInt: $(_q(_spanstring(buf, orig_i, orig_j)))"))
end
_dispatch(::Type{BigInt}, buf, i, j, throwing; base=nothing, groupmark=nothing) =
    _tryparsebig(BigInt, buf, i, j, base, groupmark, throwing)
@inline _dispatchdefault(::Type{BigInt}, buf, i, j, throwing) =
    _tryparsebig(BigInt, buf, i, j, nothing, nothing, throwing)
function parsenext(::Type{BigInt}, buf::AbstractVector{UInt8}, pos::Integer,
                   last::Integer; base=nothing, groupmark=nothing)
    b, i, j = _prefixbounds(buf, pos, last)
    i > j && return (BigInt(0), i, RC_INVALID)
    return _runprefix(b, i, j) do source, first, final
        _parsebigintprefix(source, first, final, base, groupmark)
    end
end


# GMP's string grammar permits whitespace between digits and a second minus
# sign after Base's preamble. Normalize that grammar before the limb kernel;
# GMP itself never receives the digit string.
function baseparse_internal(::Type{BigInt}, s::AbstractString, first::Int,
                            last::Int, base::Integer, raise::Bool)
    str = first == firstindex(s) && last == lastindex(s) ? String(s) :
          String(SubString(s, first, last))
    sign, radix, i = parseint_preamble(true, Int(base), str, firstindex(str), lastindex(str))
    if !(2 <= radix <= 62)
        raise && throw(ArgumentError("invalid base: base must be 2 ≤ base ≤ 62, got $radix"))
        return nothing
    end
    if i == 0
        raise && throw(ArgumentError("premature end of integer: $(repr(str))"))
        return nothing
    end
    buf = codeunits(str)
    j = length(buf)
    while i <= j && _isws(buf[i]); i += 1; end
    valid = i <= j && buf[i] != UInt8('+') &&
            !(buf[i] == UInt8('-') && i < j && _isws(buf[i+1]))
    value, code = if valid
        if any(_isws, @view buf[i:j])
            digits = UInt8[b for b in @view(buf[i:j]) if !_isws(b)]
            radix == 10 ? parsebigint(digits, 1, length(digits)) :
                          parsebigint(digits, 1, length(digits), radix)[1:2]
        else
            radix == 10 ? parsebigint(buf, i, j) : parsebigint(buf, i, j, radix)[1:2]
        end
    else
        (BigInt(0), RC_INVALID)
    end
    if code == RC_OK
        sign < 0 && Base.GMP.MPZ.neg!(value)
        return value
    end
    raise && throw(ArgumentError("invalid BigInt: $(repr(str))"))
    return nothing
end

end # module ParsersExt
