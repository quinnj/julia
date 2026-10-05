# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

# =============================================================================
# The public surface: parse / tryparse with the documented checked semantics,
# byte-span forms, and parsenext for tokenizers. Fixed-width values use the
# span-exact kernels. Public BigFloat conversion uses the Julia
# limb kernel where documented; MPFR handles longer default values and the
# additional validated grammar/range cases.
# =============================================================================

const _INTS = Union{_SIGNED, _UNSIGNED}
const _FLOATS = Union{Float64, Float32, Float16}

# --- byte views of the input ----------------------------------------------------
# The kernels take AbstractVector{UInt8}. Strings use their allocation-free
# CodeUnits view. Arbitrary byte vectors stay as views: `_load8` has pointer
# fast paths for contiguous storage and a safe scalar gather for other layouts.
_bytes(v::Vector{UInt8}) = v
_bytes(s::Base.DenseUTF8String) = codeunits(s)
_bytes(s::AbstractString) = codeunits(String(s))
_bytes(c::Base.CodeUnits{UInt8, <:Base.DenseUTF8String}) = c
@inline function _bytes(v::AbstractVector{UInt8})
    Base.require_one_based_indexing(v)
    return v
end

# ASCII whitespace accepted by the checked byte-span API.
@inline _isws(b::UInt8) = b == UInt8(' ') || (UInt8('\t') <= b <= UInt8('\r'))
@inline function _stripws(buf::AbstractVector{UInt8}, i::Int, j::Int)
    i <= j || return (i, j)
    @inbounds (_isws(buf[i]) | _isws(buf[j])) || return (i, j)
    @inbounds while i <= j && _isws(buf[i]); i += 1; end
    @inbounds while j >= i && _isws(buf[j]); j -= 1; end
    return i, j
end
_spanstring(buf::AbstractVector{UInt8}, i::Int, j::Int) =
    i > j ? "" : String(buf[i:j])
# Base's error messages show the input through `repr` (escapes visible)
_q(s::String) = repr(s)

# --- integers ---------------------------------------------------------------------

"""
    tryparse(T, buf, i, j; base=nothing, groupmark=nothing) -> Union{T, Nothing}
"""
@inline function _tryparseint(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                              ::Nothing, ::Nothing,
                              ::Val{Throw}) where {T <: _INTS, Throw}
    orig_i, orig_j = i, j
    i, j = _stripws(buf, i, j)
    if i > j
        Throw && throw(ArgumentError("input string is empty or only contains whitespace"))
        return nothing
    end
    @inbounds if T <: _UNSIGNED && (buf[i] == UInt8('-') || buf[i] == UInt8('+'))
        Throw && throw(ArgumentError("invalid base 10 digit '$(Char(buf[i]))' in $(_q(_spanstring(buf, orig_i, orig_j)))"))
        return nothing
    end
    @inbounds b = buf[i]
    k = i + Int((b == UInt8('-')) | (b == UInt8('+')))
    @inbounds if k < j && buf[k] == UInt8('0')
        c = buf[k + 1]
        if c == UInt8('x') || c == UInt8('o') || c == UInt8('b')
            return _tryparseintradix(T, buf, orig_i, orig_j, i, j, nothing, nothing,
                                     Val(Throw))
        end
    end
    v, rc = parseint(T, buf, i, j)
    rc == RC_OK && return v
    Throw || return nothing
    bad = rc == RC_INVALID ? _firstbad10(buf, i, j) : 0
    _throwintfailure(buf, orig_i, orig_j, i, j, 10, rc, bad)
end

@inline function _tryparseint(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                              base, groupmark,
                              ::Val{Throw}) where {T <: _INTS, Throw}
    orig_i, orig_j = i, j
    i, j = _stripws(buf, i, j)
    if i > j
        Throw && throw(ArgumentError("input string is empty or only contains whitespace"))
        return nothing
    end
    # Decimal input is the dominant public call. Avoid setting up the
    # arbitrary-radix route unless the first bytes can actually be a radix
    # prefix. This matters on Julia 1.10, where the otherwise-dead keyword and
    # tuple setup remains visible for short and invalid-first-byte inputs.
    if base === nothing
        @inbounds if T <: _UNSIGNED && (buf[i] == UInt8('-') || buf[i] == UInt8('+'))
            Throw && throw(ArgumentError("invalid base 10 digit '$(Char(buf[i]))' in $(_q(_spanstring(buf, orig_i, orig_j)))"))
            return nothing
        end
        k = i
        @inbounds (buf[k] == UInt8('-') || buf[k] == UInt8('+')) && (k += 1)
        prefixed = false
        @inbounds if k < j && buf[k] == UInt8('0')
            c = buf[k + 1]
            prefixed = c == UInt8('x') || c == UInt8('o') || c == UInt8('b')
        end
        if !prefixed
            if groupmark === nothing
                v, rc = parseint(T, buf, i, j)
                bad = rc == RC_INVALID && Throw ? _firstbad10(buf, i, j) : 0
            else
                gm = _intgroupbyte(groupmark, 10)
                v, rc, bad = _parsegroupeddecimal(T, buf, i, j, gm, false, true)
            end
            rc == RC_OK && return v
            Throw || return nothing
            _throwintfailure(buf, orig_i, orig_j, i, j, 10, rc, bad)
        end
    end

    return _tryparseintradix(T, buf, orig_i, orig_j, i, j, base, groupmark,
                             Val(Throw))
end

# Prefixes and explicit bases need the full arbitrary-radix setup. Keep that
# uncommon branch out of the inlined decimal parser so its code size does not
# tax short scalar calls.
@noinline function _tryparseintradix(::Type{T}, buf::AbstractVector{UInt8},
                                     orig_i::Int, orig_j::Int, i::Int, j::Int,
                                     base, groupmark,
                                     ::Val{Throw}) where {T <: _INTS, Throw}
    base = _normalizebase(base)
    @inbounds if T <: _UNSIGNED && (buf[i] == UInt8('-') || buf[i] == UInt8('+'))
        # Base: any sign is an invalid digit for an unsigned type
        Throw && throw(ArgumentError("invalid base $(something(base, 10)) digit '$(Char(buf[i]))' in $(_q(_spanstring(buf, orig_i, orig_j)))"))
        return nothing
    end
    dstart, b, prefixed = _intprefix(buf, i, j, base)
    gm = _intgroupbyte(groupmark, b)
    if prefixed
        # sign (if any) sits before the prefix; the digits follow it
        neg = @inbounds buf[i] == UInt8('-')
        if dstart > j
            Throw && throw(ArgumentError("premature end of integer: $(_q(_spanstring(buf, orig_i, orig_j)))"))
            return nothing
        end
        pbuf, pi, pj = buf, dstart, j
        if gm !== nothing
            if T <: _SIGNED
                v, rc, bad = parsegroupedprefixedint(T, buf, dstart, j, gm, b, neg)
            else
                v, rc, bad = parsegroupedint(T, buf, dstart, j, gm, b)
            end
        elseif T <: _SIGNED
            v, rc, bad = parseprefixedint(T, pbuf, pi, pj, b, neg)
        else
            v, rc, bad = parseint(T, pbuf, pi, pj, b)
        end
        rc == RC_OK && return v
    elseif gm !== nothing
        v, rc, bad = parsegroupedint(T, buf, i, j, gm, b)
        rc == RC_OK && return v
    else
        if b == 10
            # Keep the common public path on the small decimal kernel. The
            # arbitrary-base wrapper only adds the invalid-byte position, so
            # compute that detail on the cold throwing failure path.
            v, rc = parseint(T, buf, i, j)
            bad = rc == RC_INVALID && Throw ? _firstbad10(buf, i, j) : 0
        else
            v, rc, bad = parseint(T, buf, i, j, b)
        end
        rc == RC_OK && return v
    end
    Throw || return nothing
    _throwintfailure(buf, orig_i, orig_j, i, j, b, rc, bad)
end

@noinline function _throwintfailure(buf, orig_i, orig_j, i, j, b, rc, bad)
    s = _spanstring(buf, orig_i, orig_j)
    rc == RC_OVERFLOW && throw(OverflowError("overflow parsing $(_q(s))"))
    # invalid: Base names the first offending character; a sign with nothing
    # after it counts as empty
    k = max(bad, i)
    @inbounds if k > j || (k == i && (buf[k] == UInt8('-') || buf[k] == UInt8('+')) && k == j)
        throw(ArgumentError("input string is empty or only contains whitespace"))
    end
    @inbounds _isws(buf[k]) &&                     # digits, whitespace, then more: Base's wording
        throw(ArgumentError("extra characters after whitespace in $(_q(s))"))
    ch = first(String(buf[k:(k + min(3, j - k))]))
    # repr, matching Base: control and invalid bytes appear escaped, not raw
    throw(ArgumentError("invalid base $b digit $(repr(ch)) in $(_q(s))"))
end

# --- floats -----------------------------------------------------------------------

@inline _parsefloatspan(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                        decimal::UInt8, groupmark) where {T <: _FLOATS} =
    _parsefloatspan(T, buf, i, j, decimal, groupmark, Val(false))

@inline function _parsefloatspan(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                                 decimal::UInt8, groupmark,
                                 ::Val{Whole}) where {T <: _FLOATS, Whole}
    v = zero(T)
    rc = RC_INVALID
    gm = _floatgroupbyte(groupmark, decimal)
    if i <= j
        k = i
        @inbounds if buf[k] == UInt8('-') || buf[k] == UInt8('+')
            k += 1
        end
        probespecial = @inbounds gm !== nothing && k <= j &&
            (_lower(buf[k]) == UInt8('i') || _lower(buf[k]) == UInt8('n'))
        special, isspecial = probespecial ? _matchspecial(buf, i, j) : (0.0, false)
        if isspecial
            v, rc = T(special), RC_OK
        elseif @inbounds(k < j && buf[k] == UInt8('0') &&
                         _lower(buf[k + 1]) == UInt8('x'))
            v, rc = _parsehexfloat(T, buf, i, j)
        elseif gm !== nothing && T !== Float16
            v, rc, handled = _floatgroupedsmall(T, buf, i, j, decimal, gm)
            if !handled
                if _hasbyte(buf, i, j, gm)
                    v, rc = parsegroupedfloatpublic(T, buf, i, j, decimal, gm)
                else
                    v, rc = parsefloatpublic(T, buf, i, j, decimal)
                end
            end
        elseif gm !== nothing && _hasbyte(buf, i, j, gm)
            v, rc = parsegroupedfloatpublic(T, buf, i, j, decimal, gm)
        else
            v, rc = Whole ? parsefloatwholepublic(T, buf, i, j, decimal) :
                            parsefloatpublic(T, buf, i, j, decimal)
        end
    end
    return (v, rc)
end

@inline function _tryparsefloat(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                                decimal::UInt8, groupmark,
                                ::Val{Throw}) where {T <: _FLOATS, Throw}
    return _tryparsefloat(T, buf, i, j, decimal, groupmark, Val(Throw), Val(false))
end

@inline function _tryparsefloat(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                                decimal::UInt8, groupmark, ::Val{Throw},
                                whole::Val{Whole}) where {T <: _FLOATS, Throw, Whole}
    orig_i, orig_j = i, j
    i, j = _stripws(buf, i, j)
    v, rc = _parsefloatspan(T, buf, i, j, decimal, groupmark, whole)
    if rc == RC_OK
        return v
    end
    # The kernel still holds the rounded ±Inf / ±0 for callers that want it.
    # Whole-value parsing rejects every nonzero spelling outside the finite
    # target range. This policy is deterministic across platforms and never
    # delegates fixed-float conversion to Julia's private C parser.
    Throw || return nothing
    throw(ArgumentError("cannot parse $(_q(_spanstring(buf, orig_i, orig_j))) as $T"))
end

# --- bools --------------------------------------------------------------------------

@inline function _tryparsebool(buf::AbstractVector{UInt8}, i::Int, j::Int, trues, falses,
                               ::Val{Throw}) where {Throw}
    orig_i, orig_j = i, j
    i, j = _stripws(buf, i, j)
    if trues === nothing && falses === nothing
        # "true"/"false"/"1"/"0" exactly; Base additionally falls back to
        # integer parsing ("01", "0x1") — a documented deliberate difference
        if i == j
            @inbounds b = buf[i]
            ((b == UInt8('1')) | (b == UInt8('0'))) && return b == UInt8('1')
        else
            v, rc = parsebool(buf, i, j)
            rc == RC_OK && return v
        end
    else
        trues !== nothing && matchsentinel(buf, i, j, trues) && return true
        falses !== nothing && matchsentinel(buf, i, j, falses) && return false
    end
    Throw || return nothing
    i > j && throw(ArgumentError(orig_i > orig_j ? "input string is empty" :
                                                  "input string only contains whitespace"))
    throw(ArgumentError("invalid Bool representation: $(_q(_spanstring(buf, orig_i, orig_j)))"))
end

# --- dispatch: the public functions -------------------------------------------------------

"""
    Base.Parsers.parse(T, s; kw...) -> T
    Base.Parsers.parse(T, bytes, first, last; kw...) -> T
    Base.Parsers.tryparse(T, s; kw...) -> Union{T, Nothing}
    Base.Parsers.tryparse(T, bytes, first, last; kw...) -> Union{T, Nothing}

Parse the whole of `s` (an `AbstractString` or byte vector) — or the byte span
`bytes[first:last]` — as `T`. `parse` throws `Base.parse`'s errors on failure
(`ArgumentError` for malformed input, `OverflowError` for integers out of
range); `tryparse` returns `nothing`. Numbers and `Bool` tolerate surrounding
ASCII whitespace; dates and UUIDs must fill the span exactly. Byte vectors must
use one-based axes.

Keywords:
  * `base`      fixed integers and `BigInt`: 2 ≤ base ≤ 62; when omitted,
                `0x`/`0o`/`0b` prefixes select 16/8/2 (Base's rule)
  * `decimal`   floats: the decimal separator character (default `'.'`)
  * `groupmark` numbers: a digit-group separator to ignore (`1,000,000`)
  * `rounding`  `BigFloat`: a supported `RoundingMode` (current MPFR mode by default)
  * `trues`/`falses`  Bool: replacement lists of nonempty spellings (`["yes"]`, `["no"]`)
  * `dateformat` Date/DateTime/Time: a format string, `Dates.DateFormat`, or
                 compiled `Base.Parsers.DatePattern`

Supported `T`: `Int8`…`Int128`, `UInt8`…`UInt128`, `Bool`, `Float16`,
`Float32`, `Float64`, `BigInt`, `BigFloat`, and `Base.UUID`. Loading `Dates`
adds `Date`, `DateTime`, and `Time` adapters.
"""
function parse end

"""
    Base.Parsers.tryparse(T, input; kw...) -> Union{T, Nothing}
    Base.Parsers.tryparse(T, bytes, first, last; kw...) -> Union{T, Nothing}

Like [`parse`](@ref), but return `nothing` for malformed or out-of-range input.
Invalid configuration and invalid byte bounds still throw. Supported targets
and keywords are the same as for `parse`.
"""
function tryparse end

# every entry funnels to one (T, buf, i, j, Val(throwing)) dispatcher
_dispatch(::Type{T}, buf, i, j, throwing; base=nothing, groupmark=nothing) where {T <: _INTS} =
    _tryparseint(T, buf, i, j, base, groupmark, throwing)
_dispatch(::Type{T}, buf, i, j, throwing; decimal::Char='.', groupmark=nothing) where {T <: _FLOATS} =
    _tryparsefloat(T, buf, i, j, _decimalbyte(decimal), groupmark, throwing)
_dispatch(::Type{Bool}, buf, i, j, throwing; trues=nothing, falses=nothing) =
    _tryparsebool(buf, i, j, _bytelist(trues), _bytelist(falses), throwing)
_dispatch(::Type{T}, buf, i, j, throwing) where {T} =
    throw(ArgumentError("Parsers does not know how to parse $T (supported: integers of every " *
                        "width, Bool, Float16/32/64, BigInt, BigFloat, UUID, Date, DateTime, Time)"))

# Empty keyword splats were still visible in Julia 1.10 scalar calls. Keep the
# common no-keyword route positional so each destination reaches its hot parser
# without constructing or dispatching through a keyword wrapper.
@inline _dispatchdefault(::Type{T}, buf, i, j, throwing) where {T <: _INTS} =
    _tryparseint(T, buf, i, j, nothing, nothing, throwing)
@inline _dispatchdefault(::Type{T}, buf, i, j, throwing) where {T <: _FLOATS} =
    _tryparsefloat(T, buf, i, j, UInt8('.'), nothing, throwing)
@inline _dispatchdefault(::Type{Bool}, buf, i, j, throwing) =
    _tryparsebool(buf, i, j, nothing, nothing, throwing)
@inline _dispatchdefault(::Type{T}, buf, i, j, throwing) where {T} =
    _dispatch(T, buf, i, j, throwing)

@inline _sentinellengthbytes(s::AbstractString) = ncodeunits(s)
@inline _sentinellengthbytes(s) = length(s)
@inline function _checkbytelist(xs)
    for s in xs
        _sentinellengthbytes(s) > 0 ||
            throw(ArgumentError("Bool spellings must not be empty"))
    end
    return xs
end

@inline _bytelist(::Nothing) = nothing
@inline _bytelist(xs::AbstractVector{<:Union{String, SubString{String}}}) =
    _checkbytelist(xs)
@inline _bytelist(xs::Tuple{Vararg{Union{String, SubString{String}}}}) =
    _checkbytelist(xs)
@inline _bytelist(xs::Vector{Vector{UInt8}}) = _checkbytelist(xs)
@inline function _bytelist(xs)
    # String(::Vector{UInt8}) steals the caller's buffer; copy byte vectors
    normalized = Vector{UInt8}[x isa AbstractVector{UInt8} ? Vector{UInt8}(x) :
                               Vector{UInt8}(codeunits(String(x))) for x in xs]
    return _checkbytelist(normalized)
end

# Fixed-width integers are the most common scalar target. Give their two
# keywords a concrete public method so Julia 1.10 does not retain the generic
# keyword-splat dispatch in short whole-value and byte-span calls.
@inline function parse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                       base=nothing, groupmark=nothing) where {T <: _INTS}
    GC.@preserve s begin
        buf = _bytes(s)
        return _tryparseint(T, buf, 1, length(buf), base, groupmark, Val(true))::T
    end
end
@inline function tryparse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                          base=nothing, groupmark=nothing) where {T <: _INTS}
    GC.@preserve s begin
        buf = _bytes(s)
        return _tryparseint(T, buf, 1, length(buf), base, groupmark, Val(false))
    end
end
@inline function parse(::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer;
                       base=nothing, groupmark=nothing) where {T <: _INTS}
    checkbounds(buf, first:last)
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return _tryparseint(T, window, i, j, base, groupmark, Val(true))::T
    end
    return _tryparseint(T, bytes, i, j, base, groupmark, Val(true))::T
end
@inline function tryparse(::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer;
                          base=nothing, groupmark=nothing) where {T <: _INTS}
    checkbounds(buf, first:last)
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return _tryparseint(T, window, i, j, base, groupmark, Val(false))
    end
    return _tryparseint(T, bytes, i, j, base, groupmark, Val(false))
end

# Fixed-width floats need the same concrete wrapper on Julia 1.10. Keeping the
# supported keywords explicit also rejects misspellings before parser work.
@inline function parse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                       decimal::Char='.', groupmark=nothing) where {T <: _FLOATS}
    GC.@preserve s begin
        buf = _bytes(s)
        return _tryparsefloat(T, buf, 1, length(buf), _decimalbyte(decimal),
                              groupmark, Val(true), Val(true))::T
    end
end
@inline function tryparse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                          decimal::Char='.', groupmark=nothing) where {T <: _FLOATS}
    GC.@preserve s begin
        buf = _bytes(s)
        return _tryparsefloat(T, buf, 1, length(buf), _decimalbyte(decimal),
                              groupmark, Val(false), Val(true))
    end
end
@inline function parse(::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer;
                       decimal::Char='.', groupmark=nothing) where {T <: _FLOATS}
    checkbounds(buf, first:last)
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return _tryparsefloat(T, window, i, j, _decimalbyte(decimal),
                              groupmark, Val(true))::T
    end
    return _tryparsefloat(T, bytes, i, j, _decimalbyte(decimal), groupmark,
                          Val(true))::T
end
@inline function tryparse(::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer;
                          decimal::Char='.', groupmark=nothing) where {T <: _FLOATS}
    checkbounds(buf, first:last)
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return _tryparsefloat(T, window, i, j, _decimalbyte(decimal),
                              groupmark, Val(false))
    end
    return _tryparsefloat(T, bytes, i, j, _decimalbyte(decimal), groupmark,
                          Val(false))
end

# whole-input forms: hold the source alive across the zero-copy byte view
function parse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}}; kw...) where {T}
    GC.@preserve s begin
        buf = _bytes(s)
        return (isempty(kw) ? _dispatchdefault(T, buf, 1, length(buf), Val(true)) :
                              _dispatch(T, buf, 1, length(buf), Val(true); kw...))::T
    end
end
function tryparse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}}; kw...) where {T}
    GC.@preserve s begin
        buf = _bytes(s)
        return isempty(kw) ? _dispatchdefault(T, buf, 1, length(buf), Val(false)) :
                             _dispatch(T, buf, 1, length(buf), Val(false); kw...)
    end
end
# byte-span forms
function parse(::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer; kw...) where {T}
    checkbounds(buf, first:last)
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return (isempty(kw) ? _dispatchdefault(T, window, i, j, Val(true)) :
                              _dispatch(T, window, i, j, Val(true); kw...))::T
    end
    return (isempty(kw) ? _dispatchdefault(T, bytes, i, j, Val(true)) :
                          _dispatch(T, bytes, i, j, Val(true); kw...))::T
end
function tryparse(::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer; kw...) where {T}
    checkbounds(buf, first:last)
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return isempty(kw) ? _dispatchdefault(T, window, i, j, Val(false)) :
                             _dispatch(T, window, i, j, Val(false); kw...)
    end
    return isempty(kw) ? _dispatchdefault(T, bytes, i, j, Val(false)) :
                         _dispatch(T, bytes, i, j, Val(false); kw...)
end

# --- parsenext: the tokenizer primitive ---------------------------------------

"""
    Base.Parsers.parsenext(T, bytes, pos, last; kw...) -> (value, nextpos, code)

Parse the longest well-formed value of `T` that starts at `bytes[pos]`.
`nextpos` is the first byte not consumed. `code` is `RC_OK`, `RC_INVALID`,
`RC_OVERFLOW`, or `RC_UNDERFLOW`; range tokens are consumed and retain the
kernel's range value. No whitespace is skipped.
If a token consumes byte `typemax(Int)`, the one-past `nextpos` cannot be
represented and the function throws `OverflowError`.

Token recognition and conversion state advance together. The implementation
does not first scan a token boundary and then call a whole-value parser on the
same span.

The supported targets are the integer types, `Float16`/`Float32`/`Float64`,
`BigInt`, `BigFloat`, and `Bool`. Their `base`, radix-prefix, `decimal`,
`groupmark`, and `trues`/`falses` rules match the corresponding whole-value
grammars. Custom Bool lists replace the default spellings. `BigFloat`
tokenization uses the bounded low-level decimal, hexadecimal, and special-value
grammar and accepts its `RoundingMode` values. It reports values outside that
kernel's documented decimal prove-out range with a range code. It does not
accept MPFR-only spellings handled by public whole-value parsing.
"""
function parsenext end

@inline function _prefixbounds(buf::AbstractVector{UInt8}, pos::Integer,
                               last::Integer)
    b = _bytes(buf)
    (typemin(Int) <= pos <= typemax(Int) &&
     typemin(Int) <= last <= typemax(Int)) ||
        throw(BoundsError(b, pos:last))
    i, j = Int(pos), Int(last)
    n = length(b)
    nonempty = i <= j && 1 <= i && j <= n
    emptyend = i > j && j == n && i > 0 && i - 1 == n
    (nonempty || emptyend) ||
        throw(BoundsError(b, i:j))
    return b, i, j
end

# Prefix kernels use an ordinary `Int` as their cursor and therefore need room
# for bounded lookahead plus one index after the input span. Very high public
# spans are rebased to a window that starts near `typemin(Int)` with bounded
# low-side guard space. This keeps every internal index and lookahead
# representable and leaves normal one-based hot paths unchanged. Position state
# distinguishes a real index zero from its no-position marker. The public result
# is translated back once. Consuming the final addressable byte has no
# representable `nextpos`, so report that fact instead of wrapping the cursor.
@noinline _prefixendoverflow() =
    throw(OverflowError("parsenext consumed byte at typemax(Int); nextpos is not representable"))

@inline function _restoreprefix(window::_IndexWindow, result)
    value, nextpos, code = result
    offset = nextpos - _INDEX_WINDOW_FIRST
    0 <= offset <= window.len || _prefixendoverflow()
    offset <= typemax(Int) - window.origin || _prefixendoverflow()
    return (value, window.origin + offset, code)
end

@inline function _runprefix(f::F, b::AbstractVector{UInt8}, i::Int,
                            j::Int) where {F}
    if _needsindexwindow(j)
        window, first, final = _indexwindow(b, i, j)
        return _restoreprefix(window, f(window, first, final))
    end
    return f(b, i, j)
end

# Keep the rare high-index source type out of the normal fixed-float
# specialization. Passing both source types through the higher-order
# `_runprefix` seam prevents Julia from inlining the short decimal path.
@noinline function _parsenextfloatwindow(::Type{T},
                                         b::B, i::Int, j::Int,
                                         decimal::UInt8, groupmark::G) where
                                         {T <: _FLOATS,
                                          B <: AbstractVector{UInt8}, G}
    window, first, final = _indexwindow(b, i, j)
    result = _parsefloatprefix(T, window, first, final, decimal, groupmark)
    return _restoreprefix(window, result)
end

function parsenext(::Type{T}, buf::AbstractVector{UInt8}, pos::Integer,
                   last::Integer; kw...) where {T}
    _prefixbounds(buf, pos, last)
    throw(ArgumentError("parsenext does not support $T"))
end

function parsenext(::Type{T}, buf::AbstractVector{UInt8}, pos::Integer,
                   last::Integer; base=nothing,
                   groupmark=nothing) where {T <: _INTS}
    b, i, j = _prefixbounds(buf, pos, last)
    i > j && return (zero(T), i, RC_INVALID)
    return _runprefix(b, i, j) do source, first, final
        _parseintprefix(T, source, first, final, base, groupmark)
    end
end

@inline function parsenext(::Type{T}, buf::AbstractVector{UInt8}, pos::Integer,
                           last::Integer; decimal::Char='.',
                           groupmark=nothing) where {T <: _FLOATS}
    b, i, j = _prefixbounds(buf, pos, last)
    i > j && return (zero(T), i, RC_INVALID)
    dec = _decimalbyte(decimal)
    _needsindexwindow(j) &&
        return _parsenextfloatwindow(T, b, i, j, dec, groupmark)
    return _parsefloatprefix(T, b, i, j, dec, groupmark)
end

function parsenext(::Type{Bool}, buf::AbstractVector{UInt8}, pos::Integer,
                   last::Integer; trues=nothing, falses=nothing)
    b, i, j = _prefixbounds(buf, pos, last)
    i > j && return (false, i, RC_INVALID)
    ts = _bytelist(trues)
    fs = _bytelist(falses)
    return _runprefix(b, i, j) do source, first, final
        _parseboolprefix(source, first, final, ts, fs)
    end
end
