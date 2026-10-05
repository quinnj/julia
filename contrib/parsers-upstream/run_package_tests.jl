# This file is a part of Julia. License is MIT: https://julialang.org/license

# Exercise the original Parsers 3 suites against the kernels embedded in Base.
# Only module and type-display paths change; parsing inputs and expected values
# stay intact.
using Test, Dates

length(ARGS) in (1, 2) ||
    error("usage: julia run_package_tests.jl /path/to/Parsers [package]")
const use_package = length(ARGS) == 2
use_package && ARGS[2] != "package" && error("the optional mode must be 'package'")
const package_tests = joinpath(abspath(first(ARGS)), "test")

function port_test_source(source::String)
    source = replace(source,
                     r"(?m)^([ \t]*using [^\n]*?)\bParsers\b" => s"\1Base.Parsers",
                     "Parsers.DatePattern(<compiled>)" =>
                         "Base.Parsers.DatePattern(<compiled>)")
    for name in ("todate", "todatetime", "totime", "_datepattern")
        source = replace(source, "Parsers.$name" => "Dates.ParsersExt.$name")
    end
    # Private kernel helpers now live with the types that own their storage.
    for (owner, names) in (
        ("Base.GMP.ParsersExt", ("_GMP_SIZE_T", "_feeddigits!", "_flushdigits!",
         "_gmpbitsforlimbs", "_gmpcheckedaddbits", "_gmpgrowcapacity",
         "_gmpmaxvaluebits", "_gmpsize", "_limbsfordigits", "_parsebigintprefix")),
        ("Base.MPFR.ParsersExt", ("_MPFRScaleRange", "_bigfloatexponent", "_cexponent",
         "_givebigwork", "_takebigwork", "_leasedbigfloatfromparts",
         "_obviousmpfrdefault", "_prefermpfrdefault")),
    )
        for name in names
            source = replace(source, "Parsers.$name" => "$owner.$name")
        end
    end
    return source
end

module UpstreamParsersTests
using Test, Dates, Random
end

if use_package
    ENV["JULIA_PROJECT"] = Base.active_project()
    @eval UpstreamParsersTests using Parsers
else
    @eval UpstreamParsersTests using Base.Parsers
end

@testset "Parsers 3 $(use_package ? "package baseline" : "kernels embedded in Base")" begin
    for filename in ("helpers.jl", "kernels_ints.jl", "kernels_floats.jl",
                     "kernels_civil.jl", "kernels_misc.jl", "api.jl", "regressions.jl")
        path = joinpath(package_tests, filename)
        source = read(path, String)
        Base.include_string(UpstreamParsersTests,
                            use_package ? source : port_test_source(source), path)
    end
end
