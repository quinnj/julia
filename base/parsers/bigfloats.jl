# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

module ParsersExt

import ..MPFR: BigFloat
import Base.GMP: BigInt
import Base.Parsers: _dispatch, _dispatchdefault, basetryparse, parse, parsebigfloat, parsenext
using Base.Parsers: DecParts, RC_INVALID, RC_OK, RC_OVERFLOW, RC_UNDERFLOW,
                   _DECPARTS_NO_DIGIT, _decimalbyte, _decompose, _decomposeprefix,
                   _digitrunend, _floatgroupbyte, _hasbyte, _hexexponentdigit,
                   _indexwindow, _lower, _matchspecial, _matchspecialprefix,
                   _needsindexwindow, _prefixbounds, _q, _runprefix,
                   _signedhexexponent, _spanstring, _startshexprefix, _stripws,
                   degroup!, parsefloat64
using Base.GMP.ParsersExt: _GMP_SIZE_T, _Limb, _feeddigits!, _flushdigits!,
                         _gmpbitsforlimbs, _gmpcapacityoverflow, _gmpcheckedaddbits,
                         _gmpsize, _limbsfordigits

# Powers of five for the BigFloat scaling path, built at precompile time.
# Covers every exponent reachable from ~150 significant digits around the
# double range; rarer exponents compute fresh. Entries are READ-ONLY — the
# scaling code must never hand them to an in-place GMP op's output slot.
const _POW5BIG = [BigInt(5)^k for k in 0:512]

"""
    BigWork()

Reusable workspace for `parsebigfloat`: the coefficient, division remainder,
long power of five, and decimal-digit buffer live here so a column loop grows
them once instead of allocating them per value. GMP objects are
finalizer-registered. Never share one workspace across concurrent tasks.
"""
mutable struct BigWork
    const M::BigInt
    const R::BigInt
    const P::BigInt
    pow5exponent::Int
    const digits::Vector{UInt8}
end
BigWork() = BigWork(BigInt(0), BigInt(0), BigInt(1), 0, UInt8[])

@inline function _pow5big(ws::BigWork, k::Int)
    k <= 512 && return @inbounds(_POW5BIG[k + 1])
    if ws.pow5exponent != k
        Base.GMP.MPZ.set_si!(ws.P, 5)
        Base.GMP.MPZ.pow_ui!(ws.P, ws.P, k % Culong)
        ws.pow5exponent = k
    end
    return ws.P
end

# One workspace per thread, handed out by atomic swap: a task takes the slot's
# workspace and leaves `nothing`, so a task that migrates threads mid-parse or
# an interleaved task on the same thread can never share it — they allocate a
# fresh one instead, and the slot keeps whichever workspace comes back last.
mutable struct BigWorkSlot
    @atomic ws::Union{Nothing, BigWork}
end
const _BIGWORKSLOTS = BigWorkSlot[]

@inline function _takebigwork()
    tid = Threads.threadid()
    tid <= length(_BIGWORKSLOTS) || return BigWork()
    slot = @inbounds _BIGWORKSLOTS[tid]
    ws = @atomicswap :acquire_release slot.ws = nothing
    return ws === nothing ? BigWork() : ws
end

@inline function _givebigwork(ws::BigWork)
    tid = Threads.threadid()
    tid <= length(_BIGWORKSLOTS) || return nothing
    slot = @inbounds _BIGWORKSLOTS[tid]
    @atomic :release slot.ws = ws
    return nothing
end

function __init__()
    append!(_BIGWORKSLOTS, BigWorkSlot(nothing) for _ in 1:Threads.maxthreadid())
    return nothing
end

# One correctly-rounded store into a fresh BigFloat: our prec-bit integer
# mantissa is exact under mpfr_set_z, the 2^e scale is exact under mul_2si,
# and the sign flips in place — one MPFR allocation, no ldexp/unary-minus
# temporaries.
struct _MPFRScaleRange <: Exception
    exponent::Int128
end

@inline function _cexponent(::Type{C}, exponent::Integer) where {C <: Signed}
    wide = Int128(exponent)
    typemin(C) <= wide <= typemax(C) || throw(_MPFRScaleRange(wide))
    return C(wide)
end

function _assemble(M::BigInt, e::Int, neg::Bool, prec::Int)
    v = BigFloat(; precision=prec)
    ccall((:mpfr_set_z, Base.MPFR.libmpfr), Int32,
          (Ref{BigFloat}, Ref{BigInt}, Int32), v, M, 0)
    ce = _cexponent(Clong, e)
    ccall((:mpfr_mul_2si, Base.MPFR.libmpfr), Int32,
          (Ref{BigFloat}, Ref{BigFloat}, Clong, Int32), v, v, ce, 0)
    neg && ccall((:mpfr_neg, Base.MPFR.libmpfr), Int32,
                 (Ref{BigFloat}, Ref{BigFloat}, Int32), v, v, 0)
    return v
end

@inline _roundup(::RoundingMode{:Nearest}, neg, rbit, sticky, odd) =
    rbit && (sticky || odd)
@inline _roundup(::RoundingMode{:ToZero}, neg, rbit, sticky, odd) = false
@inline _roundup(::RoundingMode{:FromZero}, neg, rbit, sticky, odd) = rbit || sticky
@inline _roundup(::RoundingMode{:Up}, neg, rbit, sticky, odd) =
    !neg && (rbit || sticky)
@inline _roundup(::RoundingMode{:Down}, neg, rbit, sticky, odd) =
    neg && (rbit || sticky)
_roundup(mode::RoundingMode, neg, rbit, sticky, odd) =
    throw(ArgumentError("BigFloat does not support rounding mode $mode"))
# MPFR's enum keeps the public path free of a RoundingMode type union.
@inline function _roundup(mode::Base.MPFR.MPFRRoundingMode, neg, rbit, sticky, odd)
    mode == Base.MPFR.MPFRRoundNearest && return rbit && (sticky || odd)
    mode == Base.MPFR.MPFRRoundToZero && return false
    mode == Base.MPFR.MPFRRoundFromZero && return rbit || sticky
    mode == Base.MPFR.MPFRRoundUp && return !neg && (rbit || sticky)
    mode == Base.MPFR.MPFRRoundDown && return neg && (rbit || sticky)
    throw(ArgumentError("BigFloat does not support rounding mode $mode"))
end
const _ROUNDING = Union{RoundingMode, Base.MPFR.MPFRRoundingMode}

# Round the nonnegative integer magnitude `M * 2^e2` once at `prec` bits, then
# apply the sign. `sticky` states that nonzero bits exist below M's low bit.
function _roundbig!(M::BigInt, e2::Int, neg::Bool, prec::Int,
                    mode::_ROUNDING, sticky::Bool=false)
    MPZ = Base.GMP.MPZ
    nb = Int(MPZ.sizeinbase(M, 2))
    if nb > prec
        drop = nb - prec
        rbit = MPZ.tstbit(M, (drop - 1) % Culong)
        sticky = sticky || (drop > 1 && Int(MPZ.scan1(M, 0)) < drop - 1)
        MPZ.fdiv_q_2exp!(M, drop % Culong)
        odd = MPZ.tstbit(M, Culong(0))
        if _roundup(mode, neg, rbit, sticky, odd)
            MPZ.add_ui!(M, 1)
            if Int(MPZ.sizeinbase(M, 2)) > prec
                MPZ.fdiv_q_2exp!(M, Culong(1))
                drop += 1
            end
        end
        return _assemble(M, Base.checked_add(e2, drop), neg, prec)
    end
    # Decimal division always keeps guard bits, so a sticky remainder cannot
    # reach this exact branch. Validate the mode here as well for exact inputs.
    _roundup(mode, neg, false, false, false)
    return _assemble(M, e2, neg, prec)
end

"""
    parsebigfloat(buf, i, j, decimal=UInt8('.'); prec=precision(BigFloat)) -> (BigFloat, rc)

Correctly rounded BigFloat at `prec` bits, with `rounding` defaulting to the
current MPFR rounding mode. It accepts the decimal and hexadecimal grammar and
special spellings of `parsefloat64`. Decimal digits go through GMP's numeric
digit-to-limb converter, not a string parser. A long coefficient first becomes
a bounded leading interval. Equal rounded endpoints prove the result; only an
endpoint disagreement converts the full exact coefficient. Integer powers of
five and two then produce one correctly rounded value. MPFR stores that value;
it does not parse the token.

Prove-out range bound: decimal magnitudes beyond ~10^±65536 return
`RC_OVERFLOW`. This keeps Julia integer scaling bounded. No subnormal
handling is needed inside that range — BigFloat's exponent field dwarfs it.
"""
function parsebigfloat(buf::AbstractVector{UInt8}, i::Int, j::Int, decimal::UInt8=UInt8('.');
                       prec::Int=precision(BigFloat),
                       rounding::RoundingMode=Base.Rounding.rounding(BigFloat))
    return _withbigwork() do ws
        parsebigfloat(buf, i, j, decimal, ws; prec, rounding)
    end
end

function parsebigfloat(buf::AbstractVector{UInt8}, i::Int, j::Int,
                       decimal::UInt8, ws::BigWork; prec::Int=precision(BigFloat),
                       rounding::RoundingMode=Base.Rounding.rounding(BigFloat))
    if _needsindexwindow(j)
        window, first, final = _indexwindow(buf, i, j)
        return _parsebigfloatexact(window, first, final, decimal, ws; prec,
                                   rounding)
    end
    return _parsebigfloatexact(buf, i, j, decimal, ws; prec, rounding)
end

function _parsebigfloatexact(buf::AbstractVector{UInt8}, i::Int, j::Int,
                             decimal::UInt8, ws::BigWork;
                             prec::Int=precision(BigFloat),
                             rounding::RoundingMode=Base.Rounding.rounding(BigFloat))
    prec >= 2 || throw(ArgumentError("prec must be ≥ 2"))
    _roundup(rounding, false, false, false, false)  # validate even for zero/specials
    k = i
    @inbounds if k <= j && (buf[k] == UInt8('-') || buf[k] == UInt8('+'))
        k += 1
    end
    @inbounds if k < j && buf[k] == UInt8('0') && _lower(buf[k + 1]) == UInt8('x')
        return _parsebigfloathex(buf, i, j, ws; prec, rounding)
    end
    sp, matched = _matchspecial(buf, i, j)
    matched && return (BigFloat(sp; precision=prec), RC_OK)
    parts, rc = _decompose(buf, i, j, decimal)
    rc == RC_OK || return (BigFloat(0; precision=prec), rc)
    return _bigfloatfromparts(buf, i, j, decimal, parts, ws, prec, rounding)
end

# Unary minus on a BigFloat allocates at the global default precision, so
# signed zero/Inf early returns must construct the signed value at `prec`
@inline _signedzero(neg::Bool, prec::Int) = BigFloat(neg ? -0.0 : 0.0; precision=prec)
@inline _signedinf(neg::Bool, prec::Int) = BigFloat(neg ? -Inf : Inf; precision=prec)

function _scaledbigint!(M::BigInt, q::Int, neg::Bool, ws::BigWork,
                        prec::Int, rounding::_ROUNDING)
    # value = M × 10^q = M × 5^q × 2^q — pure integer scaling, one rounding:
    #   q ≥ 0: N = M·5^q is exact and value = N × 2^q
    #   q < 0: N = ⌊M·2^s / 5^-q⌋ with enough guard bits; the remainder
    #          is sticky and value = N × 2^(q-s).
    MPZ = Base.GMP.MPZ
    sticky = false
    if q >= 0
        q > 0 && MPZ.mul!(M, _pow5big(ws, q))
        e2 = q
    else
        kwide = -Int128(q)
        if kwide > typemax(Int)
            return (_signedzero(neg, prec), RC_UNDERFLOW)
        end
        k = Int(kwide)
        d5 = _pow5big(ws, k)
        s = max(0, prec + 3 + Int(MPZ.sizeinbase(d5, 2)) -
                   Int(MPZ.sizeinbase(M, 2)))
        MPZ.mul_2exp!(M, s % Culong)
        MPZ.tdiv_qr!(M, ws.R, M, d5)
        sticky = !iszero(ws.R)
        e2wide = Int128(q) - Int128(s)
        if e2wide < typemin(Int)
            return (_signedzero(neg, prec), RC_UNDERFLOW)
        elseif e2wide > typemax(Int)
            return (_signedinf(neg, prec), RC_OVERFLOW)
        end
        e2 = Int(e2wide)
    end
    value = _roundbig!(M, e2, neg, prec, rounding, sticky)
    return (value, isinf(value) ? RC_OVERFLOW : iszero(value) ? RC_UNDERFLOW : RC_OK)
end

@inline function _decimalintervaldigits(prec::Int)
    # ceil(prec*log10(2)) significant decimal digits identify a `prec`-bit
    # value. Ten more digits make the conservative interval much narrower than
    # one ulp. Endpoint agreement below is the proof; this count affects only
    # how often the exact full-coefficient fallback is needed.
    digits = cld(widemul(prec, 30103), 100000) + 10
    digits <= typemax(Int) || _gmpcapacityoverflow()
    return max(1, Int(digits))
end

# Convert decomposed decimal parts. Long coefficients first convert a bounded
# leading interval. If both interval endpoints round to the same value, every
# possible omitted suffix has that result. Only an endpoint disagreement takes
# the exact full-coefficient path.
function _bigfloatfromparts(buf::AbstractVector{UInt8}, i::Int, j::Int, decimal::UInt8,
                            parts::DecParts, ws::BigWork, prec::Int, rounding::_ROUNDING,
                            groupmark=nothing)
    if parts.mant == 0
        return (_signedzero(parts.neg, prec), RC_OK)
    end
    # Freeze significant digits and track the true power of ten. The range test
    # uses the full coefficient exponent, not DecParts.exp10 (which is relative
    # to its truncated 19-digit mantissa).
    M = ws.M
    digstart = parts.digoffset <= 0 ? _DECPARTS_NO_DIGIT :
               i + Int(parts.digoffset) - 1
    if groupmark === nothing && j - i + 1 <= _decimalintervaldigits(prec)
        # ndig is bounded by the span, so the interval proof below can never
        # trigger; feed the coefficient limbs directly
        q, inrange = _bigmantissadirect!(M, buf, i, digstart, j, decimal)
        inrange || return (_signedzero(parts.neg, prec), RC_OVERFLOW)
        return _scaledbigint!(M, q, parts.neg, ws, prec, rounding)
    end
    q, inrange = _collectbigmantissa!(ws.digits, buf, i, digstart, j, decimal,
                                      groupmark)
    inrange || return (_signedzero(parts.neg, prec), RC_OVERFLOW)
    digits = ws.digits
    ndig = length(digits)
    keep = min(ndig, _decimalintervaldigits(prec))
    omitted = ndig - keep
    if omitted > 0
        tailnonzero = false
        @inbounds for index in (keep + 1):ndig
            tailnonzero |= digits[index] != 0
        end
        qshortwide = Int128(q) + Int128(omitted)
        typemin(Int) <= qshortwide <= typemax(Int) || _gmpcapacityoverflow()
        qshort = Int(qshortwide)

        _setdecimaldigits!(M, digits, keep)
        lower = _scaledbigint!(M, qshort, parts.neg, ws, prec, rounding)
        tailnonzero || return lower

        _setdecimaldigits!(M, digits, keep)
        Base.GMP.MPZ.add_ui!(M, 1)
        upper = _scaledbigint!(M, qshort, parts.neg, ws, prec, rounding)
        lower[2] == upper[2] && isequal(lower[1], upper[1]) && return lower
    end

    _setdecimaldigits!(M, digits, ndig)
    return _scaledbigint!(M, q, parts.neg, ws, prec, rounding)
end

@inline function _withbigwork(f::F) where {F}
    ws = _takebigwork()
    try
        return f(ws)
    finally
        _givebigwork(ws)
    end
end

# Arbitrary-precision C99 hexadecimal float. Hexadecimal input is already a
# binary rational, so collecting every nibble into a BigInt and applying one
# `_roundbig!` operation gives exact MPFR-compatible rounding without a string
# conversion.
function _parsebigfloathex(buf::AbstractVector{UInt8}, i::Int, j::Int,
                           ws::BigWork; prec::Int, rounding::RoundingMode)
    value, nextpos, rc = _parsebigfloathexprefix(buf, i, j, ws;
                                                  prec, rounding)
    nextpos > j || return (BigFloat(0; precision=prec), RC_INVALID)
    return (value, rc)
end

function _parsebigfloathexprefix(buf::AbstractVector{UInt8}, i::Int, j::Int,
                                 ws::BigWork; prec::Int,
                                 rounding::RoundingMode)
    orig = i
    neg = false
    @inbounds begin
        b = buf[i]
        neg = b == UInt8('-')
        (neg || b == UInt8('+')) && (i += 1)
        (i < j && buf[i] == UInt8('0') &&
         _lower(buf[i + 1]) == UInt8('x')) ||
            return (BigFloat(0; precision=prec), orig, RC_INVALID)
    end
    i += 2
    M = ws.M
    MPZ = Base.GMP.MPZ
    MPZ.set_si!(M, 0)
    sawdigit = false
    infrac = false
    nfrac = 0
    coefficientbits = 0
    @inbounds while i <= j
        b = buf[i]
        d = b - UInt8('0')
        if d > 0x09
            d = _lower(b) - UInt8('a')
            if d > 0x05
                if b == UInt8('.') && !infrac
                    infrac = true
                    i += 1
                    continue
                end
                break
            end
            d += 0x0a
        end
        sawdigit = true
        if infrac
            if nfrac == typemax(Int)
                return (_signedzero(neg, prec), i + 1, RC_UNDERFLOW)
            end
            nfrac += 1
        end
        if coefficientbits == 0
            d != 0 && (coefficientbits = 8 - leading_zeros(d))
        else
            coefficientbits = _gmpcheckedaddbits(coefficientbits, 4)
        end
        MPZ.mul_2exp!(M, Culong(4))
        MPZ.add_ui!(M, d % UInt)
        i += 1
    end
    sawdigit || return (BigFloat(0; precision=prec), orig, RC_INVALID)

    commit = i
    pexp = zero(UInt128)
    eneg = false
    @inbounds if i <= j && _lower(buf[i]) == UInt8('p')
        k = i + 1
        if k <= j
            b = buf[k]
            eneg = b == UInt8('-')
            (eneg || b == UInt8('+')) && (k += 1)
        end
        estart = k
        while k <= j
            d = buf[k] - UInt8('0')
            d <= 0x09 || break
            pexp = _hexexponentdigit(pexp, d)
            k += 1
        end
        k > estart && (commit = k)
        commit == i && begin
            pexp = zero(UInt128)
            eneg = false
        end
    end

    iszero(M) && begin
        return (_signedzero(neg, prec), commit, RC_OK)
    end
    ewide = _signedhexexponent(pexp, eneg) - Int128(4) * Int128(nfrac)
    if ewide < typemin(Int)
        return (_signedzero(neg, prec), commit, RC_UNDERFLOW)
    elseif ewide > typemax(Int)
        return (_signedinf(neg, prec), commit, RC_OVERFLOW)
    end
    v = try
        _roundbig!(M, Int(ewide), neg, prec, rounding)
    catch err
        underflow = if err isa _MPFRScaleRange
            err.exponent < 0
        elseif err isa OverflowError
            # The only checked Int operation below this point adds a positive
            # rounding shift, so its overflow is necessarily above typemax.
            false
        else
            rethrow()
        end
        if underflow
            return (_signedzero(neg, prec), commit, RC_UNDERFLOW)
        end
        return (_signedinf(neg, prec), commit, RC_OVERFLOW)
    end
    rc = isinf(v) ? RC_OVERFLOW : iszero(v) ? RC_UNDERFLOW : RC_OK
    return (v, commit, rc)
end

# BigFloat prefix parsing shares the float-family token grammar and hands the
# resulting state directly to the limb converter. The converter may reread
# digits to build the arbitrary-precision mantissa, but it does not rescan the
# grammar or call a whole-value parser.
@inline function _leasedbigfloathexprefix(buf, i::Int, j::Int, prec::Int,
                                          rounding::RoundingMode)
    ws = _takebigwork()
    try
        return _parsebigfloathexprefix(buf, i, j, ws; prec, rounding)
    finally
        _givebigwork(ws)
    end
end

@inline function _leasedbigfloatfromparts(buf, i::Int, stop::Int,
                                          decimal::UInt8, parts::DecParts,
                                          prec::Int, rounding::RoundingMode,
                                          groupmark)
    ws = _takebigwork()
    try
        return _bigfloatfromparts(buf, i, stop, decimal, parts, ws, prec,
                                  rounding, groupmark)
    finally
        _givebigwork(ws)
    end
end

function _parsebigfloatprefix(buf::AbstractVector{UInt8}, i::Int, j::Int,
                              decimal::UInt8, groupmark,
                              rounding::RoundingMode)
    orig = i
    prec = precision(BigFloat)
    _roundup(rounding, false, false, false, false)
    gm = _floatgroupbyte(groupmark, decimal)

    k = i
    @inbounds if k <= j && (buf[k] == UInt8('-') || buf[k] == UInt8('+'))
        k += 1
    end
    k <= j || return (BigFloat(0; precision=prec), orig, RC_INVALID)

    @inbounds first = buf[k]
    lower = _lower(first)
    if lower == UInt8('i') || lower == UInt8('n')
        special, nextpos, matched = _matchspecialprefix(buf, i, j)
        matched && return (BigFloat(special; precision=prec), nextpos, RC_OK)
    end
    if _startshexprefix(buf, k, j)
        return _leasedbigfloathexprefix(buf, i, j, prec, rounding)
    end
    (first - UInt8('0') <= 0x09 || first == decimal) ||
        return (BigFloat(0; precision=prec), orig, RC_INVALID)

    parts, nextpos, rc = _decomposeprefix(buf, i, j, decimal, gm)
    rc == RC_OK || return (BigFloat(0; precision=prec), orig, rc)
    value, rc = _leasedbigfloatfromparts(buf, i, nextpos - 1, decimal, parts,
                                         prec, rounding, gm)
    return (value, nextpos, rc)
end

# Resolve the decimal position and first significant digit together. An
# unknown `digstart` is the cold bounded-state case: syntax is already valid,
# so this prepass only reads coefficient digits and separators and stops before
# e/E. Track the point separately because a rebased prefix window can contain
# index zero.
function _bigmantissaprepass(buf::AbstractVector{UInt8}, i::Int, j::Int,
                             digstart::Int, decimal::UInt8)
    point = 0
    pointfound = false
    if digstart != _DECPARTS_NO_DIGIT
        @inbounds for p in i:(digstart - 1)
            if buf[p] == decimal
                point = p
                pointfound = true
                break
            end
        end
    else
        @inbounds while i <= j
            byte = buf[i]
            digit = byte - UInt8('0')
            digit <= 0x09 && digit != 0 && begin
                digstart = i
                break
            end
            _lower(byte) == UInt8('e') && break
            if byte == decimal
                point = i
                pointfound = true
            end
            i += 1
        end
    end
    infrac = pointfound
    frac = infrac ? digstart - point - 1 : 0
    return (digstart, infrac, frac)
end

# Read the exponent of an already-validated decimal coefficient. UInt64 keeps
# the common 18-digit branch correct on 32-bit platforms; Int128 combines it
# with the coefficient scale before the bounded BigFloat range decision.
@inline function _bigfloatexponent(buf::AbstractVector{UInt8}, k::Int, j::Int,
                                   offset::Int, frac::Int)
    @inbounds begin
        k += 1
        eneg = buf[k] == UInt8('-')
        (eneg || buf[k] == UInt8('+')) && (k += 1)
        expv = zero(UInt64)
        if j - k + 1 <= 18
            while k <= j
                expv = 10expv + UInt64(buf[k] - UInt8('0'))
                k += 1
            end
        else
            # Only exponents within this bound can make |q + ndig| <= 65536.
            # A fixed cap would lose cancellation against a long coefficient.
            aoff = abs(Int128(offset))
            limit = UInt64(min(aoff + 65536, Int128(typemax(UInt64))))
            limit10, limitdigit = divrem(limit, UInt64(10))
            while k <= j
                d = UInt64(buf[k] - UInt8('0'))
                (expv > limit10 || (expv == limit10 && d > limitdigit)) &&
                    return (0, false)
                expv = 10expv + d
                k += 1
            end
        end
        signedexp = eneg ? -Int128(expv) : Int128(expv)
        abs(signedexp + Int128(offset)) > 65536 && return (0, false)
        q = signedexp - Int128(frac)
        typemin(Int) <= q <= typemax(Int) || return (0, false)
        return (Int(q), true)
    end
end

# Convert a numeric digit buffer to GMP limbs without invoking a string parser.
@inline function _setdecimaldigits!(big::BigInt, digits::Vector{UInt8}, ndig::Int)
    nlimbs = _limbsfordigits(_Limb, ndig)
    big.alloc < nlimbs &&
        Base.GMP.MPZ.realloc2!(big, _gmpbitsforlimbs(nlimbs))
    rawsize = GC.@preserve big digits begin
        ccall((:__gmpn_set_str, Base.GMP.libgmp), _GMP_SIZE_T,
              (Ptr{_Limb}, Ptr{UInt8}, Csize_t, Cint),
              big.d, pointer(digits), ndig, 10)
    end
    0 <= rawsize <= nlimbs || _gmpcapacityoverflow()
    big.size = _gmpsize(Int(rawsize))
    return big
end

# Collect significant digits and their decimal scale from an already validated
# token. The boolean is false when the magnitude is outside the bounded
# BigFloat kernel range.
# Short ungrouped coefficients skip the freeze-into-`ws.digits` pass that only
# the long-input interval proof needs: the digit runs feed the coefficient
# limbs directly, as the prefix kernels do. The traversal mirrors the ungrouped
# _collectbigmantissa! exactly.
function _bigmantissadirect!(big::BigInt, buf::AbstractVector{UInt8}, i::Int,
                             digstart::Int, j::Int, decimal::UInt8)
    digstart, infrac, frac = _bigmantissaprepass(buf, i, j, digstart, decimal)
    stop1 = _digitrunend(buf, digstart, j)
    infrac && (frac += stop1 - digstart)
    start2 = stop1
    stop2 = stop1
    @inbounds if stop1 <= j && buf[stop1] == decimal
        start2 = stop1 + 1
        stop2 = _digitrunend(buf, start2, j)
        frac += stop2 - start2
    end
    ndig = (stop1 - digstart) + (stop2 - start2)
    k = stop2
    q, inrange = @inbounds(k <= j) ?
        _bigfloatexponent(buf, k, j, ndig - frac, frac) :
        (-frac, abs(ndig - frac) <= 65536)
    inrange || return (0, false)

    nlimbs = _limbsfordigits(_Limb, ndig)
    big.alloc < nlimbs &&
        Base.GMP.MPZ.realloc2!(big, _gmpbitsforlimbs(nlimbs))
    GC.@preserve big begin
        limbs = big.d
        size, acc, nacc, _ = _feeddigits!(limbs, 0, zero(UInt64), 0, buf,
                                          digstart, stop1)
        size, acc, nacc, _ = _feeddigits!(limbs, size, acc, nacc, buf,
                                          start2, stop2)
        size = _flushdigits!(limbs, size, acc, nacc)
    end
    big.size = _gmpsize(size)
    return (q, true)
end

function _collectbigmantissa!(digits::Vector{UInt8},
                              buf::AbstractVector{UInt8}, i::Int,
                              digstart::Int, j::Int, decimal::UInt8)
    # A decimal point BEFORE the first significant digit ("0.001") puts the
    # whole mantissa in the fraction, and the skipped zeros between the point
    # and digstart are fractional positions too.
    digstart, infrac, frac = _bigmantissaprepass(buf, i, j, digstart, decimal)
    # digit runs (shape validated by _decompose): [digstart, stop1), then
    # after a decimal point [start2, stop2); an exponent marker may follow
    stop1 = _digitrunend(buf, digstart, j)
    infrac && (frac += stop1 - digstart)
    start2 = stop1
    stop2 = stop1
    @inbounds if stop1 <= j && buf[stop1] == decimal
        start2 = stop1 + 1
        stop2 = _digitrunend(buf, start2, j)
        frac += stop2 - start2
    end
    ndig = (stop1 - digstart) + (stop2 - start2)
    k = stop2
    q, inrange = @inbounds(k <= j) ?
        _bigfloatexponent(buf, k, j, ndig - frac, frac) :
        (-frac, abs(ndig - frac) <= 65536)
    inrange || return (0, false)

    resize!(digits, ndig)
    target = 1
    @inbounds for source in digstart:(stop1 - 1)
        digits[target] = buf[source] - UInt8('0')
        target += 1
    end
    @inbounds for source in start2:(stop2 - 1)
        digits[target] = buf[source] - UInt8('0')
        target += 1
    end
    return (q, true)
end

@inline _collectbigmantissa!(digits::Vector{UInt8},
                             buf::AbstractVector{UInt8}, i::Int,
                             digstart::Int, j::Int, decimal::UInt8,
                             ::Nothing) =
    _collectbigmantissa!(digits, buf, i, digstart, j, decimal)

# Numeric construction for an already-validated grouped decimal token. The
# prefix grammar has already selected `j`; this pass only feeds every digit to
# GMP and derives the exact scale, skipping validated marks as it goes.
function _collectbigmantissa!(digits::Vector{UInt8},
                              buf::AbstractVector{UInt8}, i::Int,
                              digstart::Int, j::Int, decimal::UInt8,
                              groupmark::UInt8)
    digstart, infrac, frac = _bigmantissaprepass(buf, i, j, digstart, decimal)

    # Freeze significant digits into the reusable converter buffer while the
    # validated token is traversed. GMP's limb converter then builds the
    # coefficient with its subquadratic large-input algorithm. This is numeric
    # conversion, not another grammar scan or a whole-value parser call.
    empty!(digits)
    ndig = 0
    k = digstart
    @inbounds while k <= j
        b = buf[k]
        d = b - UInt8('0')
        if d <= 0x09
            ndig += 1
            push!(digits, d)
        elseif _lower(b) == UInt8('e')
            break
        elseif b == decimal
            infrac = true
        end
        infrac && d <= 0x09 && (frac += 1)
        k += 1
    end
    q, inrange = @inbounds(k <= j) ?
        _bigfloatexponent(buf, k, j, ndig - frac, frac) :
        (-frac, abs(ndig - frac) <= 65536)
    inrange || return (0, false)
    return (q, true)
end
function _parsebigfloatspan(buf, i, j, decimal::UInt8, groupmark,
                            rounding::RoundingMode)
    gm = _floatgroupbyte(groupmark, decimal)
    special, isspecial = gm === nothing ? (0.0, false) : _matchspecial(buf, i, j)
    isspecial && return (BigFloat(special; precision=precision(BigFloat)), RC_OK)
    if gm !== nothing && _hasbyte(buf, i, j, gm)
        scratch = Vector{UInt8}(undef, max(j - i + 1, 8))
        n = degroup!(scratch, buf, i, j, gm, decimal)
        if n >= 0
            return parsebigfloat(scratch, 1, n, decimal; rounding)
        end
        return (BigFloat(0), RC_INVALID)
    end
    return parsebigfloat(buf, i, j, decimal; rounding)
end

@inline _mpfrrounding(rounding::Base.MPFR.MPFRRoundingMode) = rounding
@inline _mpfrrounding(rounding::RoundingMode) =
    convert(Base.MPFR.MPFRRoundingMode, rounding)

@inline function _mpfr_strtofr!(value::BigFloat, ptr::Ptr{UInt8},
                                rounding::Base.MPFR.MPFRRoundingMode)
    endpoint = Ref{Ptr{UInt8}}()
    ccall((:mpfr_strtofr, Base.MPFR.libmpfr), Cint,
          (Ref{BigFloat}, Cstring, Ref{Ptr{UInt8}}, Cint, Base.MPFR.MPFRRoundingMode),
          value, ptr, endpoint, 0, rounding)
    return endpoint[]
end

@inline function _finishmpfr(ptr::Ptr{UInt8}, n::Int,
                            rounding::Base.MPFR.MPFRRoundingMode, prec::Int=precision(BigFloat))
    value = BigFloat(; precision=prec)
    endpoint = _mpfr_strtofr!(value, ptr, rounding)
    return (value, endpoint == ptr + n ? RC_OK : RC_INVALID)
end

const _BIGFLOAT_POW10 = ntuple(i -> UInt64(10)^(i - 1), 20)

@inline function _magnituderounding(rounding::Base.MPFR.MPFRRoundingMode, neg::Bool)
    neg || return rounding
    rounding == Base.MPFR.MPFRRoundUp && return Base.MPFR.MPFRRoundDown
    rounding == Base.MPFR.MPFRRoundDown && return Base.MPFR.MPFRRoundUp
    return rounding
end

# A short decimal whose UInt64 significand is exact at the target precision,
# or needs no later decimal scaling, needs one result allocation and a small
# number of MPFR operations. This avoids the general MPFR string scanner.
# A significand that would round before a nontrivial scale stays on the
# general path, which prevents double rounding.
@inline function _smallbigfloat(parts::DecParts,
                                rounding::Base.MPFR.MPFRRoundingMode, prec::Int=precision(BigFloat))
    (!parts.truncated && parts.ndig <= 19) || return nothing
    q = Int(parts.exp10)
    abs(q) <= 19 || return nothing
    factor = @inbounds _BIGFLOAT_POW10[abs(q) + 1]
    factor <= typemax(Culong) || return nothing
    mant = parts.mant
    mant <= typemax(Culong) || return nothing
    # With q == 0, mpfr_set_ui is the only rounding operation. It can round
    # the exact UInt64 directly even when the coefficient is wider than prec.
    (mant == 0 || q == 0 || 64 - leading_zeros(mant) <= prec) || return nothing

    value = BigFloat(; precision=prec)
    magrounding = _magnituderounding(rounding, parts.neg)
    ccall((:mpfr_set_ui, Base.MPFR.libmpfr), Cint,
          (Ref{BigFloat}, Culong, Base.MPFR.MPFRRoundingMode),
          value, Culong(mant), magrounding)
    if q > 0
        ccall((:mpfr_mul_ui, Base.MPFR.libmpfr), Cint,
              (Ref{BigFloat}, Ref{BigFloat}, Culong, Base.MPFR.MPFRRoundingMode),
              value, value, Culong(factor), magrounding)
    elseif q < 0
        ccall((:mpfr_div_ui, Base.MPFR.libmpfr), Cint,
              (Ref{BigFloat}, Ref{BigFloat}, Culong, Base.MPFR.MPFRRoundingMode),
              value, value, Culong(factor), magrounding)
    end
    if parts.neg
        ccall((:mpfr_neg, Base.MPFR.libmpfr), Cint,
              (Ref{BigFloat}, Ref{BigFloat}, Base.MPFR.MPFRRoundingMode),
              value, value, rounding)
    end
    return (value, RC_OK)
end

# The kernel's rounding modes; MPFR's faithful mode has no kernel equivalent.
@inline _kernelsupports(rounding::Base.MPFR.MPFRRoundingMode) =
    rounding == Base.MPFR.MPFRRoundNearest || rounding == Base.MPFR.MPFRRoundToZero ||
    rounding == Base.MPFR.MPFRRoundUp || rounding == Base.MPFR.MPFRRoundDown ||
    rounding == Base.MPFR.MPFRRoundFromZero

@noinline function _bigfloatfromdecimalpartswide(
        buf, i::Int, j::Int, decimal::UInt8, parts::DecParts,
        rounding::Base.MPFR.MPFRRoundingMode, prec::Int=precision(BigFloat))
    workspace = _takebigwork()
    try
        return _bigfloatfromparts(buf, i, j, decimal, parts, workspace,
                                  prec, rounding)
    finally
        _givebigwork(workspace)
    end
end

@inline function _bigfloatfromdecimalparts(
        buf, i::Int, j::Int, decimal::UInt8, parts::DecParts,
        rounding::Base.MPFR.MPFRRoundingMode, prec::Int=precision(BigFloat))
    if j - i + 1 <= 20
        fast = _smallbigfloat(parts, rounding, prec)
        fast === nothing || return fast
    end
    return _bigfloatfromdecimalpartswide(buf, i, j, decimal, parts, rounding, prec)
end

# A decimal spelling converts in Julia: the short exact path, then the limb
# kernel with a per-thread workspace. OVERFLOW means the magnitude is beyond
# the kernel's scaling range; INVALID means the decimal grammar rejected it.
function _bigfloatdecimal(buf, i::Int, j::Int, decimal::UInt8,
                          rounding::Base.MPFR.MPFRRoundingMode, prec::Int=precision(BigFloat))
    parts, rc = _decompose(buf, i, j, decimal)
    rc == RC_OK || return (BigFloat(0), rc)
    return _bigfloatfromdecimalparts(buf, i, j, decimal, parts, rounding, prec)
end

function _bigfloatgrouped(buf, i::Int, j::Int, decimal::UInt8, gm::UInt8,
                          rounding::Base.MPFR.MPFRRoundingMode, prec::Int=precision(BigFloat))
    scratch = Vector{UInt8}(undef, j - i + 1)
    m = degroup!(scratch, buf, i, j, gm, decimal)
    m >= 0 || return (BigFloat(0), RC_INVALID)
    return _bigfloatdecimal(scratch, 1, m, decimal, rounding, prec)
end

@inline function _obviousmpfrdefault(buf, k::Int, j::Int)
    k <= j || return false
    @inbounds begin
        byte = buf[k]
        lower = _lower(byte)
        (byte == UInt8('@') || lower == UInt8('i') ||
         lower == UInt8('n')) && return true
        return byte == UInt8('0') && k < j &&
               _lower(buf[k + 1]) == UInt8('b')
    end
end

# `_digitrunend` returns one-past the digit run. Avoid that unrepresentable
# sentinel only for a whole-value source whose final index is typemax(Int).
@inline function _alldecimaldigits(buf, k::Int, j::Int)
    j < typemax(Int) && return _digitrunend(buf, k, j) > j
    @inbounds while k < j
        buf[k] - UInt8('0') <= 0x09 || return false
        k += 1
    end
    return @inbounds buf[j] - UInt8('0') <= 0x09
end

# The short MPFR scanner is cheaper than the limb workspace for a 20-digit
# integer, which cannot use `_smallbigfloat`. Leading-zero spellings stay on
# the small Julia path.
@inline function _prefermpfrdefault(buf, k::Int, j::Int)
    bodybytes = j - k + 1
    bodybytes >= 20 || return false
    @inbounds buf[k] == UInt8('0') && return false
    return _alldecimaldigits(buf, k, j)
end

function _parsebigfloatpublic(buf, i::Int, j::Int, decimal::UInt8, groupmark,
                              rounding, prec::Int=precision(BigFloat))
    i <= j || return (BigFloat(0), RC_INVALID)
    mpfrrounding = _mpfrrounding(rounding)
    gm = _floatgroupbyte(groupmark, decimal)
    n = j - i + 1

    special, isspecial = _matchspecial(buf, i, j)
    isspecial && return (BigFloat(special; precision=prec), RC_OK)

    @inbounds b = buf[i]
    k = i + Int((b == UInt8('-')) | (b == UInt8('+')))
    @inbounds ishex = k < j && buf[k] == UInt8('0') &&
                      _lower(buf[k + 1]) == UInt8('x')
    normalizegroup = !ishex && gm !== nothing && _hasbyte(buf, i, j, gm)
    normalizedecimal = !ishex && decimal != UInt8('.')
    defaultgrammar = gm === nothing && decimal == UInt8('.')
    kernelrounding = _kernelsupports(mpfrrounding)

    directmpfr = defaultgrammar && n <= 20 &&
                 (_obviousmpfrdefault(buf, k, j) ||
                  (!(buf isa Base.CodeUnits{UInt8,String} &&
                     j == length(buf)) &&
                   _prefermpfrdefault(buf, k, j)))

    # In-range custom decimal/group syntax converts in Julia because it needs
    # Parsers' grammar. Default decimals whose span cannot exceed the interval
    # threshold use the same Julia path — the limb kernel beats MPFR's
    # string parser there. Longer default values go straight to MPFR: it is
    # BigFloat's native conversion engine and avoids constructing a full-size
    # BigInt coefficient before rounding it back to the requested precision.
    # This boundary does not affect `parsebigfloat` or prefix parsing, which
    # stay self-contained. A validated configured value outside the limb
    # kernel's range is normalized below and then passed to MPFR.
    if !ishex && kernelrounding && !directmpfr &&
       (!defaultgrammar || n <= _decimalintervaldigits(prec))
        if defaultgrammar
            parts, rc = _decompose(buf, i, j, decimal)
            if rc == RC_OK
                value, rc = _bigfloatfromdecimalparts(
                    buf, i, j, decimal, parts, mpfrrounding, prec)
                rc == RC_OK && return (value, RC_OK)
            end
        else
            value, rc = normalizegroup ?
                _bigfloatgrouped(buf, i, j, decimal, gm, mpfrrounding, prec) :
                _bigfloatdecimal(buf, i, j, decimal, mpfrrounding, prec)
            rc == RC_OK && return (value, RC_OK)
            rc == RC_INVALID && return (value, rc)
        end
    end

    # MPFR's faithful mode has no kernel equivalent. Configured
    # decimal grammar must still be Parsers grammar: validate it before the
    # native conversion so MPFR-only forms such as `1@2` and `nan(payload)` do
    # not become valid only because the rounding mode changed. When a group
    # mark is present, validate the normalized span and reuse it immediately.
    if !ishex && !defaultgrammar && !kernelrounding
        if normalizegroup
            scratch = Vector{UInt8}(undef, n + 1)
            m = degroup!(scratch, buf, i, j, gm, decimal)
            m >= 0 || return (BigFloat(0), RC_INVALID)
            _, rc = _decompose(scratch, 1, m, decimal)
            rc == RC_OK || return (BigFloat(0), rc)
            if normalizedecimal
                @inbounds for index in 1:m
                    scratch[index] == decimal && (scratch[index] = UInt8('.'))
                end
            end
            @inbounds scratch[m + 1] = 0x00
            GC.@preserve scratch begin
                return _finishmpfr(pointer(scratch), m, mpfrrounding, prec)
            end
        end
        _, rc = _decompose(buf, i, j, decimal)
        rc == RC_OK || return (BigFloat(0), rc)
    end

    # Julia Strings carry a trailing NUL. The whole-string/default-decimal path
    # can therefore go straight to MPFR with no temporary byte buffer.
    if !normalizegroup && !normalizedecimal &&
       buf isa Base.CodeUnits{UInt8, String} && j == length(buf)
        GC.@preserve buf begin
            return _finishmpfr(pointer(buf.s, i), n, mpfrrounding, prec)
        end
    end

    scratch = Vector{UInt8}(undef, n + 1)
    if normalizegroup
        m = degroup!(scratch, buf, i, j, gm, decimal)
        m >= 0 || return (BigFloat(0), RC_INVALID)
        n = m
    else
        @inbounds for offset in 0:(n - 1)
            scratch[offset + 1] = buf[i + offset]
        end
    end
    if normalizedecimal
        @inbounds for k in 1:n
            scratch[k] == decimal && (scratch[k] = UInt8('.'))
        end
    end
    @inbounds scratch[n + 1] = 0x00
    GC.@preserve scratch begin
        return _finishmpfr(pointer(scratch), n, mpfrrounding, prec)
    end
end

@inline function _validbigfloatstart(buf, i::Int, j::Int, decimal::UInt8)
    i <= j || return false
    @inbounds begin
        byte = buf[i]
        (byte == UInt8('-') || byte == UInt8('+')) && (i += 1)
        i <= j || return false
        byte = buf[i]
        lower = _lower(byte)
        return byte - UInt8('0') <= 0x09 || byte == decimal ||
               lower == UInt8('i') || lower == UInt8('n') || byte == UInt8('@')
    end
end

@noinline _throwbigfloat(buf, i::Int, j::Int) =
    throw(ArgumentError("cannot parse $(_q(_spanstring(buf, i, j))) as BigFloat"))

function _tryparsebig(::Type{BigFloat}, buf, i, j, decimal::UInt8, groupmark,
                      rounding, ::Val{Throw}) where {Throw}
    orig_i, orig_j = i, j
    i, j = _stripws(buf, i, j)
    if !_validbigfloatstart(buf, i, j, decimal)
        Throw || return nothing
        return _throwbigfloat(buf, orig_i, orig_j)
    end
    if buf isa Base.CodeUnits{UInt8,String} && j == length(buf) &&
       decimal == UInt8('.') && groupmark === nothing
        @inbounds byte = buf[i]
        k = i + Int((byte == UInt8('-')) | (byte == UInt8('+')))
        if _prefermpfrdefault(buf, k, j)
            n = j - i + 1
            mpfrrounding = _mpfrrounding(rounding)
            value, rc = GC.@preserve buf begin
                _finishmpfr(pointer(buf.s, i), n, mpfrrounding)
            end
            rc == RC_OK && return value
        end
    end
    v, rc = _parsebigfloatpublic(buf, i, j, decimal, groupmark, rounding)
    rc == RC_OK && return v
    Throw || return nothing
    return _throwbigfloat(buf, orig_i, orig_j)
end
_dispatch(::Type{BigFloat}, buf, i, j, throwing; decimal::Char='.', groupmark=nothing,
          rounding=Base.MPFR.rounding_raw(BigFloat)) =
    _tryparsebig(BigFloat, buf, i, j, _decimalbyte(decimal), groupmark, rounding, throwing)
@inline _dispatchdefault(::Type{BigFloat}, buf, i, j, throwing) =
    _tryparsebig(BigFloat, buf, i, j, UInt8('.'), nothing,
                 Base.MPFR.rounding_raw(BigFloat), throwing)
# The omitted keyword uses a concrete marker. Resolving the current task-local
# BigFloat mode through literal branches prevents the generated keyword wrapper
# from widening it back to abstract `RoundingMode`.
struct _DefaultBigFloatRounding end
const _DEFAULT_BIGFLOAT_ROUNDING = _DefaultBigFloatRounding()

@inline function _parsenextbigfloat(buf::AbstractVector{UInt8}, pos::Integer,
                                    last::Integer, decimal::Char, groupmark,
                                    ::_DefaultBigFloatRounding)
    rounding = Base.Rounding.rounding(BigFloat)
    rounding == RoundNearest &&
        return _parsenextbigfloat(buf, pos, last, decimal, groupmark, RoundNearest)
    rounding == RoundToZero &&
        return _parsenextbigfloat(buf, pos, last, decimal, groupmark, RoundToZero)
    rounding == RoundUp &&
        return _parsenextbigfloat(buf, pos, last, decimal, groupmark, RoundUp)
    rounding == RoundDown &&
        return _parsenextbigfloat(buf, pos, last, decimal, groupmark, RoundDown)
    rounding == RoundFromZero &&
        return _parsenextbigfloat(buf, pos, last, decimal, groupmark, RoundFromZero)
    throw(ArgumentError("unsupported BigFloat rounding mode: $rounding"))
end

# Explicit rounding modes specialize directly at the same boundary.
@inline function _parsenextbigfloat(buf::AbstractVector{UInt8}, pos::Integer,
                                    last::Integer, decimal::Char, groupmark,
                                    rounding::R) where {R <: RoundingMode}
    b, i, j = _prefixbounds(buf, pos, last)
    i > j && return (BigFloat(0), i, RC_INVALID)
    dec = _decimalbyte(decimal)
    return _runprefix(b, i, j) do source, first, final
        _parsebigfloatprefix(source, first, final, dec, groupmark, rounding)
    end
end

function parsenext(::Type{BigFloat}, buf::AbstractVector{UInt8}, pos::Integer,
                   last::Integer; decimal::Char='.', groupmark=nothing,
                   rounding::Union{RoundingMode, _DefaultBigFloatRounding}=
                       _DEFAULT_BIGFLOAT_ROUNDING)
    return _parsenextbigfloat(buf, pos, last, decimal, groupmark, rounding)
end


# Ordinary Base parsing keeps MPFR's base, precision, and rounding keywords.
# Decimal input uses the same span engine as the checked Parsers API. Native
# non-decimal bases and grammar/range fallbacks remain owned by MPFR.
function basetryparse(::Type{BigFloat}, s::AbstractString; base::Integer=0,
                      precision::Integer=Base.MPFR._precision_with_base_2(BigFloat),
                      rounding::Base.MPFR.MPFRRoundingMode=Base.MPFR.rounding_raw(BigFloat))
    source = !isempty(s) && isspace(s[end]) ? String(rstrip(s)) : String(s)
    Base.containsnul(source) && Base.unsafe_convert(Cstring, source)
    if base == 0
        GC.@preserve source begin
            buf = codeunits(source)
            i, j = _stripws(buf, 1, length(buf))
            value, code = _parsebigfloatpublic(buf, i, j, UInt8('.'), nothing,
                                              rounding, Int(precision))
            return code == RC_OK ? value : nothing
        end
    end
    value = BigFloat(; precision)
    code = ccall((:mpfr_set_str, Base.MPFR.libmpfr), Cint,
                 (Ref{BigFloat}, Cstring, Cint, Base.MPFR.MPFRRoundingMode),
                 value, source, base, rounding)
    return code == 0 ? value : nothing
end

end # module ParsersExt

@eval Base.Parsers const BigWork = $ParsersExt.BigWork
