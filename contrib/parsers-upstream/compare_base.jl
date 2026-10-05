# This file is a part of Julia. License is MIT: https://julialang.org/license

# Run once with the preserved reference system image and once with the embedded
# image. Compare stdout to keep the old Base parser an independent oracle.
if haskey(ENV, "PARSERS_REFERENCE_DATES")
    Base.include(Main, ENV["PARSERS_REFERENCE_DATES"])
    @eval using .Dates
else
    @eval using Dates
end
using Random

function outcome(f, T, s; kw...)
    try
        value = f(T, s; kw...)
        if value isa Union{Float16, Float32, Float64}
            return string(typeof(value), ':', bitstring(value))
        elseif value isa BigFloat
            return string("BigFloat:", precision(value), ':', signbit(value), ':', repr(value))
        end
        return repr(value)
    catch err
        return string(typeof(err), ':', sprint(showerror, err))
    end
end

function check(T, s; kw...)
    for f in (parse, tryparse)
        println(replace(repr((nameof(f), T, s, kw)), "Main.Dates." => "Dates."), '\t',
                replace(outcome(f, T, s; kw...), "Main.Dates." => "Dates."))
    end
end

for T in (Int8, Int64, Int128, UInt8, UInt64, UInt128, BigInt, Bool)
    for s in ("", " ", "\u202f", "1", "01", "00000000000000000001", "0", "-0",
              "+1", "-1", "- 1", "\u202f-\u00a042\u202f", "1\u202f", "1 2",
              "1\u202f2", "0x", "0x1", "-0x80", "- 0x80", "0x-10", "0x 10",
              "--1", "++1", "- -1", "-1 2", "0x- 10", "1\0", "true", "false",
              "\u202ftrue\u202f", "128", "9223372036854775808")
        check(T, s)
        for base in (2, 10, 16, 36, 62)
            check(T, s; base)
        end
    end
end

rng = MersenneTwister(0x50415253)
for T in (Float16, Float32, Float64)
    for s in ("", " ", "\u202f1.0", "1.0\u202f", "1.25", "-0", "0e99999",
              "1e99999", "1e-99999", "1e10", "1e-10", "inf", "-INFINITY", "nan",
              "-nan", "nan()", "-nan(payload_1)", "nan(123)", "nan(bad!)",
              "0x1.8p2", "0x1p-99999", "0x1p99999", "0x1", "0x.1p0", "1\0",
              "1.0004882812500000000000000000000000001")
        check(T, s)
    end
    for _ in 1:2000
        x = reinterpret(Float64, rand(rng, UInt64))
        isfinite(x) && check(T, string(x))
        digits = join(rand(rng, '0':'9', rand(rng, 1:100)))
        check(T, string(rand(rng, Bool) ? '-' : '+', digits, "e", rand(rng, -450:350)))
    end
end

for T in (Complex{Int}, ComplexF64, Complex{BigFloat})
    for s in ("1+2im", "- 1 + 2im", "3.2e-1 + 4.5im", "2j", "3", "nan+inf*im",
              "1 + 2m", "1\0+2im", "", "1 β+2im")
        check(T, s)
    end
end

for prec in (2, 16, 80, 256), mode in (Base.MPFR.MPFRRoundNearest,
        Base.MPFR.MPFRRoundDown, Base.MPFR.MPFRRoundUp, Base.MPFR.MPFRRoundToZero,
        Base.MPFR.MPFRRoundFromZero)
    for s in ("0.1", "-0.1", "1.234567890123456789012345678901234567890123456789",
              "0x1.8p2", "0b1.1", "1@2", "@inf@", "nan(payload)", "", "1e9999")
        check(BigFloat, s; precision=prec, rounding=mode)
    end
end

for (T, inputs) in (
    (Date, ("2024-02-29", "2024-02", "2024-", "-0001-01-01", "2024-02-30", "", "2024-001-02")),
    (DateTime, ("2024-02-29T12:34:56.123", "2024-02-29T24:00:00", "2024-02", "2024-02-29T",
                "2024-02-29T12:34:56.1230", "2024-02-29T12:34:56.1234", "2024-001-02T12:34:56", "")),
    (Time, ("12:34:56.123456789", "12:34", "12:34:56.1234567890", "24:00:00", "", "-1:02:03")),
    (Dates.Timestamp, ("2024-02-29T12:34:56.123456789", "2024-02", "2024-02-29T24:00:00", "")),
    (Dates.Timestamp{Millisecond}, ("2024-02-29T12:34:56.123", "2024-02-29T12:34:56.123456789", "")),
)
    for s in inputs
        check(T, s)
    end
end
