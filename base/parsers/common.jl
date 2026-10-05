# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

# result codes shared by every kernel
"Successful parse."
const RC_OK = 0x00
"The span does not match the requested grammar."
const RC_INVALID = 0x01
"The value is above the target range; fixed floats hold signed infinity."
const RC_OVERFLOW = 0x02
"A nonzero value rounded to signed zero in the target float format."
const RC_UNDERFLOW = 0x03

# Shared option-byte validation. Grammar-specific constraints stay with the
# integer and float modules that consume the byte.
@inline function _bytechar(c::Char, name::Symbol)
    UInt32(c) <= 0xff ||
        throw(ArgumentError("$name must fit in one byte, got $(repr(c))"))
    return UInt8(c)
end

# Kernels use an Int cursor and bounded fixed lookahead. Rebase spans in the
# upper half of the public index space to one checked internal window with
# guard space at both ends. Exact kernels discard the local cursor, except for
# explicit-base integer errors whose byte position is restored once.
# `parsenext` translates its cursor once at the public boundary.
const _INDEX_WINDOW_FIRST = typemin(Int) + 64

struct _IndexWindow{B <: AbstractVector{UInt8}} <: AbstractVector{UInt8}
    source::B
    origin::Int
    len::Int
end

Base.size(window::_IndexWindow) = (window.len,)
Base.axes(window::_IndexWindow) =
    (_INDEX_WINDOW_FIRST:(_INDEX_WINDOW_FIRST + window.len - 1),)
Base.IndexStyle(::Type{<:_IndexWindow}) = IndexCartesian()
@inline function Base.getindex(window::_IndexWindow, i::Int)
    offset = i - _INDEX_WINDOW_FIRST
    0 <= offset < window.len || throw(BoundsError(window, i))
    return window.source[window.origin + offset]
end

@inline _needsindexwindow(j::Int) = j > typemax(Int) ÷ 2

@inline function _indexwindow(b::AbstractVector{UInt8}, i::Int, j::Int)
    len = j - i + 1
    window = _IndexWindow(b, i, len)
    first = _INDEX_WINDOW_FIRST
    final = first + len - 1
    return window, first, final
end

@noinline _exactpositionoverflow() =
    throw(OverflowError("exact parse position is not representable"))

@inline function _restoreexactposition(window::_IndexWindow, result)
    value, code, badpos = result
    code == RC_INVALID || return result
    offset = badpos - _INDEX_WINDOW_FIRST
    0 <= offset <= window.len || _exactpositionoverflow()
    offset <= typemax(Int) - window.origin || _exactpositionoverflow()
    return (value, code, window.origin + offset)
end
