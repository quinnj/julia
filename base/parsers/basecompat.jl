# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

# Base string grammar and extension contracts around the byte-span kernels.
import Base.Checked: add_with_overflow, mul_with_overflow

function baseparse(::Type{T}, c::AbstractChar; base::Integer = 10) where T<:Integer
    a::Int = (base <= 36 ? 10 : 36)
    2 <= base <= 62 || throw(ArgumentError("invalid base: base must be 2 ≤ base ≤ 62, got $base"))
    d = '0' <= c <= '9' ? c-'0'    :
        'A' <= c <= 'Z' ? c-'A'+10 :
        'a' <= c <= 'z' ? c-'a'+a  : throw(ArgumentError("invalid digit: $(repr(c))"))
    d < base || throw(ArgumentError("invalid base $base digit $(repr(c))"))
    convert(T, d)
end

function parseint_iterate(s::AbstractString, startpos::Int, endpos::Int)
    (0 < startpos <= endpos) || (return Char(0), 0, 0)
    j = startpos
    c, startpos = iterate(s,startpos)::Tuple{Char, Int}
    c, startpos, j
end

function parseint_preamble(signed::Bool, base::Int, s::AbstractString, startpos::Int, endpos::Int)
    c, i, j = parseint_iterate(s, startpos, endpos)

    while isspace(c)
        c, i, j = parseint_iterate(s,i,endpos)
    end
    (j == 0) && (return 0, 0, 0)

    sgn = 1
    if signed
        if c == '-' || c == '+'
            (c == '-') && (sgn = -1)
            c, i, j = parseint_iterate(s,i,endpos)
        end
    end

    while isspace(c)
        c, i, j = parseint_iterate(s,i,endpos)
    end
    (j == 0) && (return 0, 0, 0)

    if base == 0
        if c == '0' && i <= endpos
            c, i = iterate(s,i)::Tuple{Char, Int}
            base = c=='b' ? 2 : c=='o' ? 8 : c=='x' ? 16 : 10
            if base != 10
                _c, _i, j = parseint_iterate(s,i,endpos)
            end
        else
            base = 10
        end
    end
    return sgn, base, j
end

# '0':'9' -> 0:9
# 'A':'Z' -> 10:35
# 'a':'z' -> 10:35 if base <= 36, 36:61 otherwise
# input outside of that is mapped to base
@inline function __convert_digit(_c::UInt32, base::UInt32)
    _0 = UInt32('0')
    _9 = UInt32('9')
    _A = UInt32('A')
    _a = UInt32('a')
    _Z = UInt32('Z')
    _z = UInt32('z')
    a = base <= 36 ? UInt32(10) : UInt32(36) # converting here instead of via a type assertion prevents typeassert related errors
    d = _0 <= _c <= _9 ? _c-_0             :
        _A <= _c <= _Z ? _c-_A+ UInt32(10) :
        _a <= _c <= _z ? _c-_a+a           :
        base
    return d
end


function _genericinteger(::Type{T}, s::AbstractString, startpos::Int, endpos::Int, base_::Integer, raise::Bool) where T<:Integer
    sgn, base, i = parseint_preamble(T<:Signed, Int(base_), s, startpos, endpos)
    if sgn == 0 && base == 0 && i == 0
        raise && throw(ArgumentError("input string is empty or only contains whitespace"))
        return nothing
    end
    if !(2 <= base <= 62)
        raise && throw(ArgumentError(LazyString("invalid base: base must be 2 ≤ base ≤ 62, got ", base)))
        return nothing
    end
    if i == 0
        raise && throw(ArgumentError("premature end of integer: $(repr(SubString(s,startpos,endpos)))"))
        return nothing
    end
    c, i = parseint_iterate(s,i,endpos)
    if i == 0
        raise && throw(ArgumentError("premature end of integer: $(repr(SubString(s,startpos,endpos)))"))
        return nothing
    end

    base = convert(T, base)
    # Special case the common cases of base being 10 or 16 to avoid expensive runtime div
    m::T = base == 10 ? div(typemax(T) - T(9), T(10)) :
           base == 16 ? div(typemax(T) - T(15), T(16)) :
                        div(typemax(T) - base + 1, base)
    n::T = 0
    while n <= m
        # Fast path from `UInt32(::Char)`; non-ascii will be >= 0x80
        _c = reinterpret(UInt32, c) >> 24
        d::T = __convert_digit(_c, base % UInt32) # we know 2 <= base <= 62, so prevent an incorrect InexactError here
        if d >= base
            raise && throw(ArgumentError("invalid base $base digit $(repr(c)) in $(repr(SubString(s,startpos,endpos)))"))
            return nothing
        end
        n *= base
        n += d
        if i > endpos
            n *= sgn
            return n
        end
        c, i = iterate(s,i)::Tuple{Char, Int}
        isspace(c) && break
    end
    (T <: Signed) && (n *= sgn)
    while !isspace(c)
        # Fast path from `UInt32(::Char)`; non-ascii will be >= 0x80
        _c = reinterpret(UInt32, c) >> 24
        d::T = __convert_digit(_c, base % UInt32) # we know 2 <= base <= 62
        if d >= base
            raise && throw(ArgumentError("invalid base $base digit $(repr(c)) in $(repr(SubString(s,startpos,endpos)))"))
            return nothing
        end
        (T <: Signed) && (d *= sgn)

        n, ov_mul = mul_with_overflow(n, base)
        n, ov_add = add_with_overflow(n, d)
        if ov_mul | ov_add
            raise && throw(OverflowError("overflow parsing $(repr(SubString(s,startpos,endpos)))"))
            return nothing
        end
        (i > endpos) && return n
        c, i = iterate(s,i)::Tuple{Char, Int}
    end
    while i <= endpos
        c, i = iterate(s,i)::Tuple{Char, Int}
        if !isspace(c)
            raise && throw(ArgumentError("extra characters after whitespace in $(repr(SubString(s,startpos,endpos)))"))
            return nothing
        end
    end
    return n
end

function baseparse_internal(::Type{Bool}, sbuff::AbstractString,
        startpos::Int, endpos::Int, base::Integer, raise::Bool)
    if isempty(sbuff)
        raise && throw(ArgumentError("input string is empty"))
        return nothing
    end

    if isnumeric(sbuff[1])
        intres = baseparse_internal(UInt8, sbuff, startpos, endpos, base, false)
        (intres == 1) && return true
        (intres == 0) && return false
        raise && throw(ArgumentError("invalid Bool representation: $(repr(sbuff))"))
    end

    orig_start = startpos
    orig_end   = endpos

    # Ignore leading and trailing whitespace
    while startpos <= endpos && isspace(sbuff[startpos])
        startpos = nextind(sbuff, startpos)
    end
    while endpos >= startpos && isspace(sbuff[endpos])
        endpos = prevind(sbuff, endpos)
    end

    len = endpos - startpos + 1
    (len == 4) && (SubString(sbuff, startpos:startpos+3) == "true") && return true
    (len == 5) && (SubString(sbuff, startpos:startpos+4) == "false") && return false

    if raise
        substr = SubString(sbuff, orig_start, orig_end) # show input string in the error to avoid confusion
        if all(isspace, substr)
            throw(ArgumentError("input string only contains whitespace"))
        else
            throw(ArgumentError("invalid Bool representation: $(repr(substr))"))
        end
    end
    return nothing
end


baseparse_internal(T::Type{<:Integer}, s::AbstractString, i::Int, j::Int,
                   base::Integer, raise::Bool) = _genericinteger(T, s, i, j, base, raise)

# Unicode whitespace and whitespace after a sign belong to Base's string API.
# The kernels consume the resulting exact byte span, with the sign kept separate
# when whitespace or a radix prefix intervenes.
@inline function baseparse_internal(::Type{T}, s::Base.DenseUTF8String,
                                    i::Int, j::Int, base::Integer,
                                    raise::Bool) where {T<:_INTS}
    sign, radix, first = parseint_preamble(T <: Signed, Int(base), s, i, j)
    if first == 0 || !(2 <= radix <= 62)
        return raise ? _genericinteger(T, s, i, j, base, true) : nothing
    end
    last = j
    while last >= first && isspace(s[last])
        last = prevind(s, last)
    end
    buf = codeunits(s)
    value, rc, _ = if T <: Signed
        parseprefixedint(T, buf, first, last, radix, sign < 0)
    else
        parseint(T, buf, first, last, radix)
    end
    rc == RC_OK && return value::T
    return raise ? _genericinteger(T, s, i, j, base, true) : nothing
end

# Preserve the platform's NaN payload syntax and bit pattern. `nan`/`nanf`
# construct a special value; ordinary decimal/hex conversion uses Julia kernels.
function _basenanpayload(::Type{T}, buf, i, j) where {T<:_FLOATS}
    neg = false
    if i <= j && (buf[i] == UInt8('-') || buf[i] == UInt8('+'))
        neg = buf[i] == UInt8('-')
        i += 1
    end
    j - i >= 4 || return nothing
    _lower(buf[i]) == UInt8('n') && _lower(buf[i+1]) == UInt8('a') &&
        _lower(buf[i+2]) == UInt8('n') && buf[i+3] == UInt8('(') &&
        buf[j] == UInt8(')') || return nothing
    for k in (i+4):(j-1)
        raw = buf[k]
        (raw == 0x00 || raw == UInt8(')')) && return nothing
        if !Sys.isapple()
            b = _lower(raw)
            (UInt8('a') <= b <= UInt8('z') || UInt8('0') <= b <= UInt8('9') ||
             raw == UInt8('_')) || return nothing
        end
    end
    payload = _spanstring(buf, i+4, j-1)
    value = T === Float64 ? ccall(:nan, Float64, (Cstring,), payload) :
                           ccall(:nanf, Float32, (Cstring,), payload)
    return neg ? -T(value) : T(value)
end

function baseparse_internal(::Type{T}, s::AbstractString, i::Int, j::Int) where {T<:_FLOATS}
    # Preserve Float16's existing conversion through Float32, including its
    # rounding and range behavior, while using the new Float32 byte kernel.
    T === Float16 && return convert(Union{Float16,Nothing}, baseparse_internal(Float32, s, i, j))
    source = s isa Base.DenseUTF8String ? s : String(s)
    GC.@preserve source begin
        buf = codeunits(source)
        first, last = _stripws(buf, i, j)
        value, code = _parsefloatspan(T, buf, first, last, UInt8('.'), nothing)
        code == RC_OK && return value::T
        code == RC_INVALID && return _basenanpayload(T, buf, first, last)
        return nothing
    end
end
basetryparse(T::Type{<:_FLOATS}, s::AbstractString) =
    baseparse_internal(T, s, firstindex(s), lastindex(s))

# Typed owners extend these front ends without changing the early core.
function baseparse end
function basetryparse end
function baseparse_internal(::Type{Complex{T}}, s::Base.DenseUTF8String, i::Int, e::Int, raise::Bool) where {T<:Real}
    # skip initial whitespace
    while i ≤ e && isspace(s[i])
        i = nextind(s, i)
    end
    if i > e
        raise && throw(ArgumentError("input string is empty or only contains whitespace"))
        return nothing
    end

    # find index of ± separating real/imaginary parts (if any)
    i₊ = something(findnext(in(('+','-')), s, i), 0)
    if i₊ == i # leading ± sign
        i₊ = something(findnext(in(('+','-')), s, i₊+1), 0)
    end
    if i₊ != 0 && s[prevind(s, i₊)] in ('e','E') # exponent sign
        i₊ = something(findnext(in(('+','-')), s, i₊+1), 0)
    end

    # find trailing im/i/j
    iᵢ = something(findprev(in(('m','i','j')), s, e), 0)
    if iᵢ > 0 && s[iᵢ] == 'm' # im
        iᵢ = prevind(s, iᵢ)
        if s[iᵢ] != 'i'
            raise && throw(ArgumentError("expected trailing \"im\", found only \"m\""))
            return nothing
        end
    end

    if i₊ == 0 # purely real or imaginary value
        if iᵢ > i && !(iᵢ == i+1 && s[i] in ('+','-')) # purely imaginary (not "±inf")
            x = Base.tryparse_internal(T, s, i, prevind(s, iᵢ), raise)
            x === nothing && return nothing
            return Complex{T}(zero(x),x)
        else # purely real
            x = Base.tryparse_internal(T, s, i, e, raise)
            x === nothing && return nothing
            return Complex{T}(x)
        end
    end

    if iᵢ < i₊
        raise && throw(ArgumentError("missing imaginary unit"))
        return nothing # no imaginary part
    end

    # parse real part
    re = Base.tryparse_internal(T, s, i, prevind(s, i₊), raise)
    re === nothing && return nothing

    # parse imaginary part
    im = Base.tryparse_internal(T, s, i₊+1, prevind(s, iᵢ), raise)
    im === nothing && return nothing

    return Complex{T}(re, s[i₊]=='-' ? -im : im)
end

# the ±1 indexing above for ascii chars is specific to String, so convert:
baseparse_internal(T::Type{Complex{S}}, s::AbstractString, i::Int, e::Int, raise::Bool) where S<:Real =
    baseparse_internal(T, String(s), i, e, raise)


@inline function parsedigits(str::AbstractString, i::Int, len::Int, min_width::Int=1, max_width::Int=0)
    i > len && return nothing
    min_pos = min_width <= 0 ? i : i + min_width - 1
    max_pos = max_width <= 0 ? len : min(i + max_width - 1, len)
    d::Int64 = 0
    @inbounds while i <= max_pos
        c, ii = iterate(str, i)::Tuple{Char, Int}
        if '0' <= c <= '9'
            digit = Int64(c - '0')
            d > div(typemax(Int64) - digit, 10) && return nothing
            d = d * 10 + digit
        else
            break
        end
        i = ii
    end
    if i <= min_pos
        return nothing
    else
        return d, i
    end
end

@inline function parsedigits(str::Base.DenseUTF8String, i::Int, len::Int,
                            min_width::Int=1, max_width::Int=0)
    i > len && return nothing
    final = max_width <= 0 ? len : min(i + max_width - 1, len)
    bytes = codeunits(str)
    stop = _digitrunend(bytes, i, final)
    stop - i >= max(min_width, 1) || return nothing
    value, code = parseint(Int64, bytes, i, stop - 1)
    return code == RC_OK ? (value, stop) : nothing
end

function baseparse_internal(::Type{Bool}, s::Base.DenseUTF8String, i::Int, j::Int,
                            base::Integer, raise::Bool)
    isempty(s) && (raise ? throw(ArgumentError("input string is empty")) : return nothing)
    if isnumeric(s[1])
        value = baseparse_internal(UInt8, s, i, j, base, false)
        value == 1 && return true
        value == 0 && return false
        raise && throw(ArgumentError("invalid Bool representation: $(repr(s))"))
        return nothing
    end
    first, last = i, j
    while i <= j && isspace(s[i]); i = nextind(s, i); end
    while j >= i && isspace(s[j]); j = prevind(s, j); end
    GC.@preserve s begin
        value, code = parsebool(codeunits(s), i, j)
        code == RC_OK && return value::Bool
    end
    raise || return nothing
    str = SubString(s, first, last)
    all(isspace, str) && throw(ArgumentError("input string only contains whitespace"))
    throw(ArgumentError("invalid Bool representation: $(repr(str))"))
end

@inline function parsefraction(str::AbstractString, i, len, min_digits, max_digits, precision)
    ndigits = 0
    frac = Int64(0)
    @inbounds while i <= len && (max_digits == 0 || ndigits < max_digits)
        c, ii = iterate(str, i)::Tuple{Char, Int}
        '0' <= c <= '9' || break
        digit = Int64(c - '0')
        ndigits += 1
        if ndigits <= precision
            frac = 10frac + digit
        elseif digit != 0
            return nothing
        end
        i = ii
    end
    ndigits >= min_digits || return nothing
    ndigits < precision && (frac *= Int64(10) ^ (precision - ndigits))
    return frac, i
end

@inline function parsefraction(str::Base.DenseUTF8String, i, len, min_digits,
                              max_digits, precision)
    final = max_digits == 0 ? len : min(len, i + max_digits - 1)
    bytes = codeunits(str)
    stop = _digitrunend(bytes, i, final)
    ndigits = stop - i
    ndigits >= min_digits || return nothing
    ndigits == 0 && return (Int64(0), i)
    parsed = min(ndigits, precision)
    value, code = parseint(Int64, bytes, i, i + parsed - 1)
    code == RC_OK || return nothing
    for k in (i + parsed):(stop - 1)
        bytes[k] == UInt8('0') || return nothing
    end
    ndigits < precision && (value *= Int64(10)^(precision - ndigits))
    return value, stop
end
