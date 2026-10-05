# This file is a part of Julia. License is MIT: https://julialang.org/license
# Derived from Parsers.jl; see LICENSE.md in this directory.

"""
    Base.Parsers

Byte-span parsing kernels and compatibility front ends for Base's scalar parsing
APIs. `parse` and `tryparse` check whole inputs or inclusive byte spans;
`parsenext` also reports the consumed prefix and a status code.

The fixed-width core loads before the scalar parsing front ends, GMP, and MPFR. Civil patterns are
added after sorting. GMP, MPFR, UUID, and Dates provide typed adapters when their
own types are available. The module exports no names and has no package dependencies.
"""
module Parsers

include("parsers/common.jl")
include("parsers/ints.jl")
include("parsers/floats.jl")
include("parsers/uuids.jl")
include("parsers/bools.jl")
include("parsers/api.jl")
include("parsers/basecompat.jl")

# Implemented by the modules that own the arbitrary-precision types.
function parsebigint end
function parsebigfloat end

public parse, tryparse, parsenext,
       RC_OK, RC_INVALID, RC_OVERFLOW, RC_UNDERFLOW,
       parseint, parsefloat, parsebool, parsebigint, parsebigfloat, parseuuid, parsecivil,
       compilepattern, DatePattern, CivilParts, BigWork

end # module Parsers
