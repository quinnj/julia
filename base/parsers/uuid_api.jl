# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

function _tryparseuuid(buf, i, j, ::Val{Throw}) where {Throw}
    u, rc = parseuuid(buf, i, j)
    rc == RC_OK && return Base.UUID(u)
    Throw || return nothing
    throw(ArgumentError("Malformed UUID string: $(_q(_spanstring(buf, i, j)))"))
end

_dispatch(::Type{Base.UUID}, buf, i, j, throwing) = _tryparseuuid(buf, i, j, throwing)
@inline _dispatchdefault(::Type{Base.UUID}, buf, i, j, throwing) =
    _tryparseuuid(buf, i, j, throwing)
