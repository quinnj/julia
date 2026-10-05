# This file is a part of Julia. License is MIT: https://julialang.org/license

# Run with a freshly built native image to verify staged inclusion and adapters.
const P = Base.Parsers
@assert !any(id -> id.name == "Dates", keys(Base.loaded_modules))

paths = last.(Base._included_files)
stages = ("/parsers/Parsers.jl", "/base/parse.jl", "/parsers/civil.jl",
          "/base/gmp.jl", "/parsers/bigints.jl", "/base/mpfr.jl",
          "/parsers/bigfloats.jl", "/base/uuid.jl", "/parsers/uuid_api.jl")
positions = map(stages) do suffix
    index = findfirst(path -> endswith(path, suffix), paths)
    @assert index !== nothing suffix
    index
end
@assert issorted(positions)
@assert all(m -> m.module === Base.GMP.ParsersExt, methods(P.parsebigint))
@assert all(m -> m.module === Base.MPFR.ParsersExt, methods(P.parsebigfloat))
@assert parentmodule(P.BigWork) === Base.MPFR.ParsersExt
@assert length(Base.MPFR.ParsersExt._BIGWORKSLOTS) == Threads.maxthreadid()
@assert isempty(Base.Docs.undocumented_names(P))

@assert parse(Int, "- 0x80") == -128
@assert parse(Float64, "1.25") === 1.25
@assert parse(BigInt, "123456789012345678901234567890") ==
        big"123456789012345678901234567890"
mode = Base.MPFR.MPFRRoundDown
exact = parse(BigFloat, "0.1"; precision=80, rounding=mode)
padded = parse(BigFloat, "0.1\u202f"; precision=80, rounding=mode)
@assert precision(exact) == precision(padded) == 80
@assert exact == padded
@assert P.parsenext(Float64, codeunits("1.25,"), 1, 5) === (1.25, 5, P.RC_OK)
@assert !any(id -> id.name == "Dates", keys(Base.loaded_modules))

using Dates
@assert parse(Date, "2024-02") == Date(2024, 2, 1)
@assert parse(DateTime, "2024-02-29T24:00:00") == DateTime(2024, 3, 1)
@assert parse(Time, "12:34:56.123456789") == Time(12, 34, 56, 123, 456, 789)
@assert P.parse(Time, "12:34:56.123456789"; dateformat=Dates.ISOTimeFormat) ==
        Time(12, 34, 56, 123, 456, 789)
@assert parse(Dates.Timestamp, "2024-02-29T12:34:56.123456789") ==
        Dates.Timestamp(2024, 2, 29, 12, 34, 56, 123, 456, 789)
@assert tryparse(Dates.Timestamp{Millisecond}, "2024-02-29T12:34:56.123456789") === nothing
println("Verified native Julia ", VERSION, ": early parser core, GMP/MPFR ownership, ",
        "documentation, runtime workspace initialization, and lazy Dates adapters.")
