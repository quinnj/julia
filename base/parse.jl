# This file is a part of Julia. License is MIT: https://julialang.org/license

## string to integer functions ##

"""
    parse(type, str; base)

Parse a string as a number. For `Integer` types, a base can be specified
(the default is 10). For floating-point types, the string is parsed as a decimal
floating-point number.  `Complex` types are parsed from decimal strings
of the form `"R±Iim"` as a `Complex(R,I)` of the requested type; `"i"` or `"j"` can also be
used instead of `"im"`, and `"R"` or `"Iim"` are also permitted.
If the string does not contain a valid number, an error is raised.

!!! compat "Julia 1.1"
    `parse(Bool, str)` requires at least Julia 1.1.

# Examples
```jldoctest
julia> parse(Int, "1234")
1234

julia> parse(Int, "1234", base = 5)
194

julia> parse(Int, "afc", base = 16)
2812

julia> parse(Float64, "1.2e-3")
0.0012

julia> parse(Complex{Float64}, "3.2e-1 + 4.5im")
0.32 + 4.5im
```
"""
parse(T::Type, str; base = Int)
parse(::Type{Union{}}, slurp...; kwargs...) = error("cannot parse a value as Union{}")

parse(T::Type{<:Integer}, c::AbstractChar; base::Integer=10) =
    Parsers.baseparse(T, c; base)

# Keep these internal extension points for custom Real and Integer types.
tryparse_internal(T::Type{<:Integer}, s::AbstractString, i::Int, j::Int,
                  base::Integer, raise::Bool) =
    Parsers.baseparse_internal(T, s, i, j, base, raise)

@inline function check_valid_base(base)
    if 2 <= base <= 62
        return base
    end
    throw(ArgumentError("invalid base: base must be 2 ≤ base ≤ 62, got $base"))
end

"""
    tryparse(type, str; base)

Like [`parse`](@ref), but returns either a value of the requested type,
or [`nothing`](@ref) if the string does not contain a valid number.
"""
function tryparse(::Type{T}, s::AbstractString; base::Union{Nothing,Integer} = nothing) where {T<:Integer}
    # Zero base means, "figure it out"
    tryparse_internal(T, s, firstindex(s), lastindex(s), base===nothing ? 0 : check_valid_base(base), false)
end

function parse(::Type{T}, s::AbstractString; base::Union{Nothing,Integer} = nothing) where {T<:Integer}
    v = tryparse_internal(T, s, firstindex(s), lastindex(s), base===nothing ? 0 : check_valid_base(base), true)
    v === nothing && error("should not happen")
    convert(T, v)
end
tryparse(::Type{Union{}}, slurp...; kwargs...) = error("cannot parse a value as Union{}")

tryparse(T::Type{<:Union{Float16,Float32,Float64}}, s::AbstractString) =
    Parsers.basetryparse(T, s)
tryparse_internal(T::Type{<:Union{Float16,Float32,Float64}}, s::AbstractString,
                  i::Int, j::Int) = Parsers.baseparse_internal(T, s, i, j)
tryparse_internal(T::Type{<:Complex}, s::AbstractString, i::Int, j::Int,
                  raise::Bool) = Parsers.baseparse_internal(T, s, i, j, raise)

# fallback methods for tryparse_internal
tryparse_internal(::Type{T}, s::AbstractString, startpos::Int, endpos::Int) where T<:Real =
    startpos == firstindex(s) && endpos == lastindex(s) ? tryparse(T, s) : tryparse(T, SubString(s, startpos, endpos))
function tryparse_internal(::Type{T}, s::AbstractString, startpos::Int, endpos::Int, raise::Bool) where T<:Real
    result = tryparse_internal(T, s, startpos, endpos)
    if raise && result === nothing
        _parse_failure(T, s, startpos, endpos)
    end
    return result
end
function tryparse_internal(::Type{T}, s::AbstractString, raise::Bool; kwargs...) where T<:Real
    result = tryparse(T, s; kwargs...)
    if raise && result === nothing
        _parse_failure(T, s)
    end
    return result
end
@noinline _parse_failure(T, s::AbstractString, startpos = firstindex(s), endpos = lastindex(s)) =
    throw(ArgumentError(LazyString("cannot parse ", repr(s[startpos:endpos]), " as ", T)))

tryparse_internal(::Type{T}, s::AbstractString, startpos::Int, endpos::Int, raise::Bool) where T<:Integer =
    tryparse_internal(T, s, startpos, endpos, 10, raise)

parse(::Type{T}, s::AbstractString; kwargs...) where T<:Real =
    convert(T, tryparse_internal(T, s, true; kwargs...))
parse(::Type{T}, s::AbstractString) where T<:Complex =
    convert(T, tryparse_internal(T, s, firstindex(s), lastindex(s), true))

tryparse(T::Type{Complex{S}}, s::AbstractString) where S<:Real =
    tryparse_internal(T, s, firstindex(s), lastindex(s), false)
