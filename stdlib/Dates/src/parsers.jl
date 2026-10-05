# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see base/parsers/LICENSE.md.

# DateFormat translation and value construction belong to Dates; Base owns the
# byte-oriented kernels and their checked entry points.
module ParsersExt

import ..Dates
import Base.Parsers: parse, tryparse, compilepattern, _dispatch, _dispatchdefault,
                    baseparse, basetryparse
using Base.Parsers: CivilParts, DatePattern, PatternOp, CivilNames, CivilNamesBox,
                   CivilNameTable, daysfromcivil, _patternkind, _kindhasdate,
                   _kindhastime, _ENGLISH_CIVIL_NAMES_BOX, _makepattern,
                   ISO_DATE, ISO_DATETIME, ISO_TIME, _cachedpattern,
                   _HAS_DATE, _HAS_TIME, _parsecivilvalidated, _needsindexwindow,
                   parseiso10, parseiso19, parseiso19frac, parseiso8, parseiso8frac,
                   _bytes, _indexwindow, _spanstring, RC_OK

# =============================================================================
# Dates adapters. The civil kernels produce a `CivilParts` record through pure
# integer arithmetic. This file owns conversion to Dates values and translates
# a `DateFormat` into a kernel pattern. The public API dispatches on Dates
# types, but civil.jl remains independent of the Dates stdlib.
# =============================================================================

@inline todate(c::CivilParts) = Dates.Date(Dates.UTD(daysfromcivil(c.year, c.month, c.day)))

@inline function todatetime(c::CivilParts)
    days = daysfromcivil(c.year, c.month, c.day)
    ms = Int64(c.nanosecond) ÷ 1_000_000
    return Dates.DateTime(Dates.UTM(((days * 24 + c.hour) * 60 + c.minute) * 60_000 +
                                    Int64(c.second) * 1000 + ms))
end

@inline totime(c::CivilParts) =
    Dates.Time(Dates.Nanosecond(((Int64(c.hour) * 60 + c.minute) * 60 + c.second) *
                                1_000_000_000 + c.nanosecond))

# Translate `Dates.DateFormat` tokens directly. Reconstructing a format string
# is lossy: an escaped token such as `\m` has already become `Dates.Delim('m')`,
# and the DateFormat also carries the locale used for textual month/day names.
# The adapter owns DateFormat translation and caching. Civil plan construction,
# execution selection, and String-pattern caching remain in civil.jl.
function _datepartop(t::Dates.DatePart{c}) where {c}
    width = t.width
    width >= 1 || throw(ArgumentError("date format token '$c' has invalid width $width"))

    kind = _patternkind(c)
    kind != 0 || throw(ArgumentError("unsupported DateFormat token '$c'"))
    hasdate = _kindhasdate(kind)
    hastime = _kindhastime(kind)

    # DateFormat's `fixed` bit is the parsing contract. In the civil bytecode,
    # 0xff marks an unbounded non-fixed numeric field; fixed widths above 255
    # use the civil program's extended encoding. CivilParts stores at most
    # nanoseconds, so fractional seconds remain limited to nine digits.
    maxwidth = if kind == 7
        t.fixed ? width : 9
    elseif kind <= 6 || kind == 11
        t.fixed ? Int(width) : Int(typemax(UInt8))
    elseif kind in (9, 10, 13, 14)
        t.fixed ? Int(width) : 0
    else
        0
    end
    kind == 7 && width > 9 &&
        throw(ArgumentError("subsecond date format token has unsupported width $width"))
    return PatternOp(kind, maxwidth, t.fixed), hasdate, hastime
end

function _pushdelimiter!(ops::Vector{PatternOp}, t::Dates.Delim)
    d = t.d
    if d isa AbstractChar
        # Dates.Delim{Char,N} means the same character repeated N times.
        n = Int(typeof(t).parameters[2])
        bytes = codeunits(string(d))
        for _ in 1:n, b in bytes
            push!(ops, PatternOp(8, b, true))
        end
    else
        for b in codeunits(String(d))
            push!(ops, PatternOp(8, b, true))
        end
    end
    return ops
end

"""
    compilepattern(df::Dates.DateFormat) -> DatePattern

Compile a `Dates.DateFormat` directly into the byte-oriented pattern program.
Escaped literals and the DateFormat's locale tables are preserved.
"""
function compilepattern(df::Dates.DateFormat)
    Base.@nospecialize df
    ops = PatternOp[]
    natural = PatternOp[]
    hasdate = false
    hastime = false
    hasnames = false
    for t in df.tokens
        if t isa Dates.DatePart
            op, token_hasdate, token_hastime = _datepartop(t)
            push!(ops, op)
            push!(natural, _naturalop(op, t))
            hasdate |= token_hasdate
            hastime |= token_hastime
            hasnames |= op.kind in (0x09, 0x0a, 0x0d, 0x0e)
        elseif t isa Dates.Delim
            _pushdelimiter!(ops, t)
            _pushdelimiter!(natural, t)
        else
            throw(ArgumentError("unsupported DateFormat token $(typeof(t))"))
        end
    end
    locale = df.locale
    names = !hasnames || locale === Dates.ENGLISH ? _ENGLISH_CIVIL_NAMES_BOX :
            CivilNamesBox(CivilNames(CivilNameTable(locale.month_abbr_value, Val(24)),
                                     CivilNameTable(locale.month_value, Val(24)),
                                     CivilNameTable(locale.day_of_week_abbr_value, Val(14)),
                                     CivilNameTable(locale.day_of_week_value, Val(14))))
    return _makepattern(ops, natural, hasdate, hastime, names)
end

# The fixed fast path reads each numeric field at the token's own width ("mm"
# is two digits, "yyyy" four). Dates' variable-width rule still governs: every
# other shape uses the compiled executor or general interpreter, which reads
# the same values whenever the fixed attempt would have succeeded.
@inline function _naturalop(op::PatternOp, t::Dates.DatePart)
    (1 <= op.kind <= 7 && 1 <= t.width) || return op
    return PatternOp(op.kind, Int(t.width), true)
end

# A canonical English DateFormat carries its source in its type. Reconstruct
# the format once during specialization and embed its pointer-sized plan.
# Tuple identity uses Julia's value-based `===` for these immutable tokens, so
# the guard checks delimiter values, field widths, and fixed bits in one bounded
# operation. Hand-built same-type tokens that differ at runtime use the cache.
# DatePattern is an opaque pointer-sized handle, so a canonical compiled plan
# can be embedded even when its source DateFormat has many tuple-shaped tokens.
# Execution crosses a function barrier so inference does not expand the
# interpreter into each public adapter specialization.

struct _RuntimeDateFormatEntry
    locale::Dates.DateLocale
    tokens::Tuple
    pattern::DatePattern
end

struct _RuntimeDateFormatBucket
    entries::Vector{_RuntimeDateFormatEntry}
    locale_sensitive::Bool
end

mutable struct _RuntimeDateFormatCache
    @atomic table::Dict{DataType, _RuntimeDateFormatBucket}
end

const _RUNTIME_DATEFORMAT_CACHE =
    _RuntimeDateFormatCache(Dict{DataType, _RuntimeDateFormatBucket}())
const _RUNTIME_DATEFORMAT_LOCK = ReentrantLock()
const _RUNTIME_DATEFORMAT_CACHE_MAX = 256
const _RUNTIME_DATEFORMAT_BUCKET_MAX = 8

struct _CanonicalDateFormatEntry
    locale::Dates.DateLocale
    pattern::DatePattern
end

struct _CanonicalDateFormatBucket
    entries::Vector{_CanonicalDateFormatEntry}
end

mutable struct _CanonicalDateFormatCache
    @atomic table::Dict{DataType, _CanonicalDateFormatBucket}
end

const _CANONICAL_DATEFORMAT_CACHE =
    _CanonicalDateFormatCache(Dict{DataType, _CanonicalDateFormatBucket}())

@inline _sametokens(left::Tuple, right::Tuple) = left === right

@inline function _findruntimepattern(bucket::_RuntimeDateFormatBucket,
                                     locale::Dates.DateLocale, tokens::Tuple)
    @inbounds for entry in bucket.entries
        (!bucket.locale_sensitive || entry.locale === locale) &&
            _sametokens(entry.tokens, tokens) &&
            return entry.pattern
    end
    return nothing
end

function _formattypeuseslocale(tokens_type)
    tokens_type isa DataType && tokens_type <: Tuple || return true
    # An abstract tuple parameter can hold locale-sensitive DateParts even if
    # the first value cached under it contains only numeric fields. Key such a
    # bucket by locale from its first entry so later name formats cannot reuse
    # a plan compiled from another locale.
    isconcretetype(tokens_type) || return true
    for token_type in tokens_type.parameters
        token_type <: Dates.DatePart || continue
        c = token_type.parameters[1]
        c in ('u', 'U', 'e', 'E') && return true
    end
    return false
end

@inline function _findcanonicalpattern(bucket::_CanonicalDateFormatBucket,
                                       locale::Dates.DateLocale)
    @inbounds for entry in bucket.entries
        entry.locale === locale && return entry.pattern
    end
    return nothing
end

@inline function _lookupcanonicalpattern(format_type::DataType,
                                         locale::Dates.DateLocale)::Union{DatePattern, Nothing}
    table = @atomic :acquire _CANONICAL_DATEFORMAT_CACHE.table
    bucket = get(table, format_type, nothing)
    bucket === nothing && return nothing
    return _findcanonicalpattern(bucket, locale)
end

@noinline function _cachecanonicalformat!(format_type::DataType, source::Symbol,
                                          locale::Dates.DateLocale)::DatePattern
    return lock(_RUNTIME_DATEFORMAT_LOCK) do
        table = @atomic :acquire _CANONICAL_DATEFORMAT_CACHE.table
        bucket = get(table, format_type, nothing)
        if bucket !== nothing
            pattern = _findcanonicalpattern(bucket, locale)
            pattern === nothing || return pattern
        end
        df = Dates.DateFormat(String(source), locale)
        typeof(df) === format_type ||
            throw(ArgumentError("DateFormat source and token type do not agree"))
        pattern = compilepattern(df)
        entries = bucket === nothing ? _CanonicalDateFormatEntry[] :
                                       copy(bucket.entries)
        length(entries) >= _RUNTIME_DATEFORMAT_BUCKET_MAX && deleteat!(entries, 1)
        push!(entries, _CanonicalDateFormatEntry(locale, pattern))
        updated = copy(table)
        if bucket === nothing && length(updated) >= _RUNTIME_DATEFORMAT_CACHE_MAX
            delete!(updated, first(keys(updated)))
        end
        updated[format_type] = _CanonicalDateFormatBucket(entries)
        @atomic :release _CANONICAL_DATEFORMAT_CACHE.table = updated
        return pattern
    end
end

@inline function _canonicalformatplan(format_type::DataType, source::Symbol,
                                      locale::Dates.DateLocale)::DatePattern
    pattern = _lookupcanonicalpattern(format_type, locale)
    pattern === nothing || return pattern
    return _cachecanonicalformat!(format_type, source, locale)
end

Base.@constprop :none @noinline function _lookupruntimepattern(
        format_type::DataType, locale::Dates.DateLocale,
        tokens::Tuple)::Union{DatePattern, Nothing}
    table = @atomic :acquire _RUNTIME_DATEFORMAT_CACHE.table
    bucket = get(table, format_type, nothing)
    bucket === nothing && return nothing
    return _findruntimepattern(bucket, locale, tokens)
end

Base.@nospecializeinfer @noinline function _cacheruntimeformat!(
        df::Dates.DateFormat, format_type::DataType)::DatePattern
    Base.@nospecialize df
    return lock(_RUNTIME_DATEFORMAT_LOCK) do
        table = @atomic :acquire _RUNTIME_DATEFORMAT_CACHE.table
        bucket = get(table, format_type, nothing)
        if bucket !== nothing
            pattern = _findruntimepattern(bucket, df.locale, df.tokens)
            pattern === nothing || return pattern
        end
        pattern = compilepattern(df)
        locale_sensitive = bucket === nothing ?
            _formattypeuseslocale(format_type.parameters[2]) : bucket.locale_sensitive
        entries = bucket === nothing ? _RuntimeDateFormatEntry[] : copy(bucket.entries)
        length(entries) >= _RUNTIME_DATEFORMAT_BUCKET_MAX && deleteat!(entries, 1)
        storedlocale = locale_sensitive ? df.locale : Dates.ENGLISH
        push!(entries, _RuntimeDateFormatEntry(storedlocale, df.tokens, pattern))
        updated = copy(table)
        if bucket === nothing && length(updated) >= _RUNTIME_DATEFORMAT_CACHE_MAX
            delete!(updated, first(keys(updated)))
        end
        updated[format_type] = _RuntimeDateFormatBucket(entries, locale_sensitive)
        @atomic :release _RUNTIME_DATEFORMAT_CACHE.table = updated
        return pattern
    end
end

Base.@constprop :none @noinline function _runtimeformatplan(df::F)::DatePattern where
                                                        {F <: Dates.DateFormat}
    pattern = _lookupruntimepattern(F, df.locale, df.tokens)
    pattern === nothing || return pattern
    return _cacheruntimeformat!(df, F)
end

@generated function _translatedpattern(df::Dates.DateFormat{S, T}) where {S, T}
    fallback = :(_runtimeformatplan(df))
    S isa Symbol || return fallback
    reconstructed = try
        Dates.DateFormat(String(S))
    catch
        return fallback
    end
    typeof(reconstructed) === Dates.DateFormat{S, T} || return fallback
    pattern = compilepattern(reconstructed)
    expected = QuoteNode(reconstructed.tokens)
    if _formattypeuseslocale(T)
        canonical = :(df.locale === Dates.ENGLISH ? $pattern :
                      _canonicalformatplan($(Dates.DateFormat{S, T}),
                                           $(QuoteNode(S)), df.locale))
        return :(df.tokens === $expected ? $canonical : $fallback)
    end
    return :(df.tokens === $expected ? $pattern : $fallback)
end

# --- dates ----------------------------------------------------------------------------

@inline _datepattern(::Nothing, ::Type{Dates.Date}) = ISO_DATE
@inline _datepattern(::Nothing, ::Type{Dates.DateTime}) = ISO_DATETIME
@inline _datepattern(::Nothing, ::Type{Dates.Time}) = ISO_TIME
@inline _datepattern(fmt::AbstractString, ::Type) = _cachedpattern(fmt)
@inline _datepattern(fmt::Dates.DateFormat, ::Type) = _translatedpattern(fmt)
@inline _datepattern(p::DatePattern, ::Type) = p

@inline _todates(::Type{Dates.Date}, c::CivilParts) = todate(c)
@inline _todates(::Type{Dates.DateTime}, c::CivilParts) = todatetime(c)
@inline _todates(::Type{Dates.Time}, c::CivilParts) = totime(c)

@inline _civilvalidation(::Type{Dates.Date}) = _HAS_DATE
@inline _civilvalidation(::Type{Dates.DateTime}) = _HAS_DATE | _HAS_TIME
@inline _civilvalidation(::Type{Dates.Time}) = _HAS_TIME

@inline _dateparts(::Type{T}, buf, i, j, dateformat) where {T <: Dates.TimeType} =
    _parsecivilvalidated(buf, i, j, _datepattern(dateformat, T), _civilvalidation(T))

# Keep the dominant default shapes out of the plan machinery. `parsecivil`
# retains the same accelerators for kernel callers, but reaching them through
# the type-erased plan barrier costs more than parsing the ISO fields
# themselves.
@inline function _dateparts(::Type{Dates.Date}, buf, i, j, ::Nothing)
    if j - i == 9 && !_needsindexwindow(j)
        c, rc = parseiso10(buf, i)
        rc == RC_OK && return (c, rc)
    end
    return _parsecivilvalidated(buf, i, j, ISO_DATE, _civilvalidation(Dates.Date))
end
@inline function _dateparts(::Type{Dates.DateTime}, buf, i, j, ::Nothing)
    n = j - i + 1
    if !_needsindexwindow(j)
        if n == 19
            c, rc = parseiso19(buf, i)
            rc == RC_OK && return (c, rc)
        elseif 21 <= n <= 29
            c, rc = parseiso19frac(buf, i, j)
            rc == RC_OK && return (c, rc)
        end
    end
    return _parsecivilvalidated(buf, i, j, ISO_DATETIME,
                                _civilvalidation(Dates.DateTime))
end
@inline function _dateparts(::Type{Dates.Time}, buf, i, j, ::Nothing)
    n = j - i + 1
    if !_needsindexwindow(j)
        if n == 8
            c, rc = parseiso8(buf, i)
            rc == RC_OK && return (c, rc)
        elseif 10 <= n <= 18
            c, rc = parseiso8frac(buf, i, j)
            rc == RC_OK && return (c, rc)
        end
    end
    return _parsecivilvalidated(buf, i, j, ISO_TIME, _civilvalidation(Dates.Time))
end

@inline function _tryparsedate(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int, dateformat,
                               ::Val{Throw}) where {T <: Dates.TimeType, Throw}
    if i > j
        Throw || return nothing
        throw(ArgumentError("cannot parse \"\" as $T" *
                            (dateformat === nothing ? "" :
                             " with format $(repr(dateformat))")))
    end
    c, rc = _dateparts(T, buf, i, j, dateformat)
    rc == RC_OK && return _todates(T, c)
    Throw || return nothing
    throw(ArgumentError("cannot parse \"$(_spanstring(buf, i, j))\" as $T" *
                        (dateformat === nothing ? "" : " with format $(repr(dateformat))")))
end

# Large DateFormat types resolve to the same pointer-sized DatePattern. Keep
# execution behind one type-erased plan barrier so inference does not rebuild
# the civil executor for every tuple-shaped DateFormat type.
Base.@constprop :none @noinline function _tryparsedateruntime(
        ::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
        pattern::DatePattern) where {T <: Dates.TimeType}
    return _tryparsedate(T, buf, i, j, pattern, Val(false))
end

@noinline function _throwdateformatfailure(::Type{T}, buf::AbstractVector{UInt8},
                                           i::Int, j::Int,
                                           dateformat::Dates.DateFormat) where {T <: Dates.TimeType}
    Base.@nospecialize dateformat
    throw(ArgumentError("cannot parse \"$(_spanstring(buf, i, j))\" as $T" *
                        " with format $(repr(dateformat))"))
end

_dispatch(::Type{T}, buf, i, j, throwing; dateformat=nothing) where {T <: Dates.TimeType} =
    _tryparsedate(T, buf, i, j, dateformat, throwing)
@inline _dispatchdefault(::Type{T}, buf, i, j, throwing) where {T <: Dates.TimeType} =
    _tryparsedate(T, buf, i, j, nothing, throwing)

# Date and time targets need concrete keyword wrappers on Julia 1.10. Keep the
# keyword sorter shallow. DateFormat translation selects its compiled plan;
# execution then crosses a bounded positional barrier.

Base.@constprop :none @noinline function _executedateplan(
        ::Type{T}, s, pattern::DatePattern) where {T <: Dates.TimeType}
    GC.@preserve s begin
        buf = _bytes(s)
        return _tryparsedateruntime(T, buf, 1, length(buf), pattern)
    end
end

@noinline function _throwdateformatwhole(::Type{T}, s,
                                         dateformat::Dates.DateFormat) where
                                         {T <: Dates.TimeType}
    Base.@nospecialize dateformat
    GC.@preserve s begin
        buf = _bytes(s)
        return _throwdateformatfailure(T, buf, 1, length(buf), dateformat)
    end
end

Base.@constprop :none @noinline function _executedatespanplan(
        ::Type{T}, buf::AbstractVector{UInt8}, first::Integer, last::Integer,
        pattern::DatePattern) where {T <: Dates.TimeType}
    bytes = _bytes(buf)
    i, j = Int(first), Int(last)
    if _needsindexwindow(j)
        window, i, j = _indexwindow(bytes, i, j)
        return _tryparsedateruntime(T, window, i, j, pattern)
    end
    return _tryparsedateruntime(T, bytes, i, j, pattern)
end

@generated function _parsedatewhole(::Type{T},
                                    s::S, dateformat::F,
                                    ::Val{Throw}) where
                                    {T <: Dates.TimeType,
                                     S <: Union{AbstractString, AbstractVector{UInt8}},
                                     F, Throw}
    if F <: Dates.DateFormat
        resolve = :(_datepattern(dateformat, T))
        execute = :(_executedateplan(T, s, $resolve))
        Throw || return execute
        return quote
            value = $execute
            value === nothing && _throwdateformatwhole(T, s, dateformat)
            return value::T
        end
    end
    return quote
        GC.@preserve s begin
            buf = _bytes(s)
            return _tryparsedate(T, buf, 1, length(buf), dateformat,
                                 Val(Throw))
        end
    end
end

@inline function parse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                       dateformat=nothing) where {T <: Dates.TimeType}
    return _parsedatewhole(T, s, dateformat, Val(true))::T
end

@inline function tryparse(::Type{T}, s::Union{AbstractString, AbstractVector{UInt8}};
                          dateformat=nothing) where {T <: Dates.TimeType}
    return _parsedatewhole(T, s, dateformat, Val(false))
end

@generated function _parsedatespan(::Type{T}, buf::B, first::I, last::J,
                                   dateformat::F, ::Val{Throw}) where
                                   {T <: Dates.TimeType,
                                    B <: AbstractVector{UInt8}, I <: Integer,
                                    J <: Integer, F, Throw}
    isformat = F <: Dates.DateFormat
    resolve = isformat ?
              :(_datepattern(dateformat, T)) : nothing
    if isformat
        execute = :(_executedatespanplan(T, buf, first, last, pattern))
        Throw || return quote
            checkbounds(buf, first:last)
            pattern = $resolve
            return $execute
        end
        return quote
            checkbounds(buf, first:last)
            pattern = $resolve
            value = $execute
            if value === nothing
                bytes = _bytes(buf)
                i, j = Int(first), Int(last)
                if _needsindexwindow(j)
                    window, i, j = _indexwindow(bytes, i, j)
                    _throwdateformatfailure(T, window, i, j, dateformat)
                end
                _throwdateformatfailure(T, bytes, i, j, dateformat)
            end
            return value::T
        end
    end
    directvalue = :(_tryparsedate(T, bytes, i, j, dateformat, Val(Throw)))
    windowvalue = :(_tryparsedate(T, window, i, j, dateformat, Val(Throw)))
    return quote
        checkbounds(buf, first:last)
        bytes = _bytes(buf)
        i, j = Int(first), Int(last)
        if _needsindexwindow(j)
            window, i, j = _indexwindow(bytes, i, j)
            return $windowvalue
        end
        return $directvalue
    end
end

@inline function parse(::Type{T}, buf::AbstractVector{UInt8},
                       first::Integer, last::Integer;
                       dateformat=nothing) where {T <: Dates.TimeType}
    return _parsedatespan(T, buf, first, last, dateformat, Val(true))::T
end

@inline function tryparse(::Type{T}, buf::AbstractVector{UInt8},
                          first::Integer, last::Integer;
                          dateformat=nothing) where {T <: Dates.TimeType}
    return _parsedatespan(T, buf, first, last, dateformat, Val(false))
end


# Canonical whole-value shapes use the civil kernels. DateFormat remains an
# extensible grammar: omitted trailing fields, custom tokens, and custom
# TimeType constructors use its generated token program and shared digit kernel.
@inline _defaultformat(::Type{Dates.Date}, df) = df === Dates.ISODateFormat
@inline _defaultformat(::Type{Dates.DateTime}, df) = df === Dates.ISODateTimeFormat
@inline _defaultformat(::Type{Dates.Time}, df) = df === Dates.ISOTimeFormat
@inline _defaultformat(::Type{T}, df) where {T<:Dates.Timestamp} = df === Dates.ISOTimestampFormat
@inline _defaultformat(::Type, df) = false

@inline _canonicalshape(::Type{Dates.Date}, n) = n == 10
@inline _canonicalshape(::Type{Dates.DateTime}, n) = n == 19 || 21 <= n <= 23
@inline _canonicalshape(::Type{Dates.Time}, n) = n == 8 || 10 <= n <= 18
@inline _canonicalshape(::Type{T}, n) where {T<:Dates.Timestamp} = n == 19 || 21 <= n <= 29

@inline _basecivilvalue(::Type{Dates.Date}, c::CivilParts) = Dates.Date(c.year, c.month, c.day)
@inline _basecivilvalue(::Type{Dates.DateTime}, c::CivilParts) =
    Dates.DateTime(c.year, c.month, c.day, c.hour, c.minute, c.second, Int64(c.nanosecond) ÷ 1000000)
@inline _basecivilvalue(::Type{Dates.Time}, c::CivilParts) =
    Dates.Time(c.hour, c.minute, c.second, 0, 0, Int64(c.nanosecond))
@inline function _basecivilvalue(::Type{T}, c::CivilParts) where {T<:Dates.Timestamp}
    args = (c.year, Int64(c.month), Int64(c.day), Int64(c.hour), Int64(c.minute),
            Int64(c.second), Int64(0), Int64(0), Int64(c.nanosecond))
    Dates.validargs(T, args...) === nothing || return nothing
    return T(args...)
end

function _defaultdatefast(::Type{T}, s::Base.DenseUTF8String, df) where {T<:Dates.TimeType}
    _defaultformat(T, df) && _canonicalshape(T, ncodeunits(s)) || return nothing
    GC.@preserve s begin
        bytes = _bytes(s)
        # Timestamp shares DateTime's civil fields; its constructor enforces
        # the chosen resolution and range instead of truncating subsecond bits.
        target = T <: Dates.Timestamp ? Dates.DateTime : T
        n = length(bytes)
        parts, code = if target === Dates.Date
            parseiso10(bytes, 1)
        elseif target === Dates.DateTime
            n == 19 ? parseiso19(bytes, 1) : parseiso19frac(bytes, 1, n)
        else
            n == 8 ? parseiso8(bytes, 1) : parseiso8frac(bytes, 1, n)
        end
        code == RC_OK || return nothing
        return _basecivilvalue(T, parts)
    end
end
_defaultdatefast(::Type, ::AbstractString, df) = nothing

function baseparse(::Type{T}, str::AbstractString, df::Dates.DateFormat) where {T<:Dates.TimeType}
    fast = _defaultdatefast(T, str, df)
    fast === nothing || return fast
    pos, len = firstindex(str), lastindex(str)
    pos > len && throw(ArgumentError("Cannot parse an empty string as a Date or Time"))
    result = Dates.tryparsenext_internal(T, str, pos, len, df, true)
    @assert result !== nothing
    values, _ = result
    return T(values...)::T
end

function basetryparse(::Type{T}, str::AbstractString, df::Dates.DateFormat) where {T<:Dates.TimeType}
    fast = _defaultdatefast(T, str, df)
    fast === nothing || return fast
    pos, len = firstindex(str), lastindex(str)
    pos > len && return nothing
    result = Dates.tryparsenext_internal(T, str, pos, len, df, false)
    result === nothing && return nothing
    values, _ = result
    Dates.validargs(T, values...) === nothing || return nothing
    return T(values...)::T
end

function baseparse(::Type{Dates.DateTime}, s::AbstractString, df::typeof(Dates.ISODateTimeFormat))
    fast = _defaultdatefast(Dates.DateTime, s, df)
    fast === nothing || return fast
    i, end_pos = firstindex(s), lastindex(s)
    i > end_pos && throw(ArgumentError("Cannot parse an empty string as a DateTime"))

    coefficient = 1
    local dy
    dm = dd = Int64(1)
    th = tm = ts = tms = Int64(0)
    @label error begin
        @label done begin
            # Optional sign
            let val = Dates.tryparsenext_sign(s, i, end_pos)
                if val !== nothing
                    coefficient, i = val
                end
            end

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1)
                val === nothing && break error
                dy, i = val
                i > end_pos && break done
            end

            c, i = iterate(s, i)::Tuple{Char, Int}
            c != '-' && break error
            i > end_pos && break done

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1, 2)
                val === nothing && break error
                dm, i = val
                i > end_pos && break done
            end

            c, i = iterate(s, i)::Tuple{Char, Int}
            c != '-' && break error
            i > end_pos && break done

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1, 2)
                val === nothing && break error
                dd, i = val
                i > end_pos && break done
            end

            c, i = iterate(s, i)::Tuple{Char, Int}
            c != 'T' && break error
            i > end_pos && break done

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1, 2)
                val === nothing && break error
                th, i = val
                i > end_pos && break done
            end

            c, i = iterate(s, i)::Tuple{Char, Int}
            c != ':' && break error
            i > end_pos && break done

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1, 2)
                val === nothing && break error
                tm, i = val
                i > end_pos && break done
            end

            c, i = iterate(s, i)::Tuple{Char, Int}
            c != ':' && break error
            i > end_pos && break done

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1, 2)
                val === nothing && break error
                ts, i = val
                i > end_pos && break done
            end

            c, i = iterate(s, i)::Tuple{Char, Int}
            c != '.' && break error
            i > end_pos && break done

            let val = Dates.tryparsenext_base10(s, i, end_pos, 1, 3)
                val === nothing && break error
                tms, j = val
                tms *= 10 ^ (3 - (j - i))
                j > end_pos || break error
            end
        end

        return Dates.DateTime(dy * coefficient, dm, dd, th, tm, ts, tms)
    end
    throw(ArgumentError("Invalid DateTime string"))
end

end # module ParsersExt
