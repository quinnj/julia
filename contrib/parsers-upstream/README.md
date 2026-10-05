# Parsers 3 embedded in Base

Date: 2026-10-05. This prototype embeds released Parsers 3.0.0 and switches ordinary Base numeric, Bool, UUID, Complex, and Dates parsing to its kernels and compatibility front ends.

## Result and ownership

The integration has a workable boundary. The fixed-width core loads before `base/parse.jl`; the civil engine loads after sorting but before GMP and MPFR. GMP and MPFR extend the shared parser functions from their own `ParsersExt` modules. Dates owns DateFormat translation, locale handling, value construction, and its typed extensions. There is no Base-to-Dates import and no package dependency during bootstrap. [Driver](../../base/parsers/Parsers.jl), [Load order](../../base/Base.jl), [GMP adapter](../../base/parsers/bigints.jl), [MPFR adapter](../../base/parsers/bigfloats.jl).

This is roughly 8,200 Julia source lines across the parser files and Dates adapter, including comments and documentation. Most is the existing 3.0 implementation. The additional complexity is compatibility with Base's string APIs and its extension hooks; the algorithms do not require a new runtime library or C/C++ changes.

```text
Base compiler essentials: numbers, arrays, strings, dictionaries, I/O, locks
  → Base.Parsers fixed-width core and compatibility front ends
  → Base.parse / Base.tryparse wrappers
  → math and sorting
  → Base.Parsers civil patterns
  → GMP defines BigInt and adds GMP.ParsersExt methods
  → MPFR defines BigFloat and adds MPFR.ParsersExt methods and scratch pool
  → UUID definition and typed parser adapter
  → package loading and remaining Base
  → Dates adds Dates.ParsersExt when loaded
```

```text
base/parsers/
  Parsers.jl       early module driver; no exports
  common.jl        status codes, option validation, index windows
  ints.jl         fixed-width integer kernels and byte gathering
  floats.jl       fixed-width decimal/hex conversion and prefix kernels
  bools.jl        spelling and sentinel kernels
  uuids.jl        raw UInt128 UUID kernel
  api.jl          checked whole-input, byte-span, and prefix API
  basecompat.jl   Base string grammar, custom-number hooks, Complex composition,
                  DateFormat decimal and fractional digit scanners
  civil.jl        calendar fields, name tables, pattern compiler and execution
  bigints.jl      GMP-owned extension: decimal limbs, radix and prefix parsing
  bigfloats.jl    MPFR-owned extension: rounding, precision, workspace, fallback
  uuid_api.jl     UUID typed adapter, added after UUID exists
stdlib/Dates/src/parsers.jl
                  Dates-owned extensions and compatibility front ends
```

## Sources and assumptions

- Parsers source: clean local checkout, commit `6bf66b7ff5e4ee20beb03758eabefe5b1089f1a7`. Its source, tests, metadata, README, and license match published `v3.0.0`, commit `642c56793f5f218bb460f7da81c9f7d3da7082db`. [Metadata](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/Project.toml).
- Julia target: isolated worktree, branch `parsers-upstream-prototype`, baseline `dda42805ec500705827dcc9e6603271b215078f1`. The original Julia and Parsers checkouts remain untouched.
- This is a default scalar-parsing prototype. Existing `parse` methods on user-defined types remain valid. Composite grammars such as Rational and VersionNumber keep their type-owned framing and now use the shared integer backend for their fields. Platform triplets and CacheFlags keep their existing grammar; Julia source parsing (`Meta.parse`, JuliaSyntax) and reader-owned CSV framing are separate concerns. [Rational composition](../../base/rational.jl), [Version composition](../../base/version.jl).
- All added APIs remain namespaced. This prototype does not establish a final supported public API for Julia Base.

The following tables compare the **released package and the pinned Julia baseline**. The prototype's compatibility decisions and validation follow the tables.

## Whole-value type coverage

| Target | Julia baseline | Parsers 3 | Integration implication |
|---|---|---|---|
| `Int8`–`Int128`, `UInt8`–`UInt128`, machine `Int`/`UInt` | Generic `Integer` string parser; optional base 2–62; omitted base recognizes lowercase `0b`, `0o`, `0x`; checked overflow. Also supports parsing an individual `AbstractChar`. | All fixed widths through byte kernels; same base range and prefixes; extra digit-group separator option. Signed decimal input uses eight-byte digit gathering, with dedicated wide and unsigned paths. | The common fixed-width path can use these kernels while retaining existing generic/custom-integer and character paths. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L41-L183), [Parsers types and kernels](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/ints.jl#L341). |
| `Bool` | `true`/`false`; also an integer fallback for numeric-leading spellings such as `01` and `0x1`. | Exact `true`, `false`, `1`, `0`, or custom replacement spelling lists. | Small byte kernel; behavior is intentionally narrower than Base's numeric fallback. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L186-L234), [Parsers adapter](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L255). |
| `Float64`, `Float32` | Dense UTF-8 strings call Julia's C wrappers around C-locale `strtod`/`strtof`; generic strings convert to `String`. | Native Julia conversion: exact small case, Eisel–Lemire, exact fixed-limb midpoint comparison, and an 800-digit decimal fallback; decimal, hexadecimal, Inf/Infinity/NaN; extra decimal/group separator options. | Fixed-width conversion is independent of GMP/MPFR. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L261-L288), [C wrappers](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/src/rtutils.c#L484-L590), [Parsers algorithm](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/floats.jl#L1). |
| `Float16` | Parse as `Float32`, then convert. | Uses wider fast paths, then compares the original input at ambiguous `Float16` rounding boundaries. | Direct final rounding differs from a two-step conversion. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L285-L288), [Parsers](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/floats.jl#L1519). |
| `BigInt` | Base preamble plus GMP's `mpz_set_str` through the existing wrapper. | Decimal chunks directly build GMP limbs; arbitrary base and group separators supported. | Retains GMP dependency and BigInt representation access; loads after `gmp.jl`. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/gmp.jl#L303-L327), [Parsers](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/bigs.jl#L260). |
| `BigFloat` | MPFR string parser with `base`, `precision`, and raw MPFR rounding keywords. | Public whole-value parsing owns short/configured decimal conversion and uses MPFR's native string parser for longer/default values and additional syntax/range cases. Offers `decimal`, `groupmark`, `rounding`; low-level kernel offers `prec` and reusable `BigWork`. | This is an MPFR integration, not removal of MPFR. Whole-value API options differ. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/mpfr.jl#L407-L415), [Parsers dispatch](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L774), [Parsers kernel](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/bigs.jl#L490). |
| `Complex{T}` for `T <: Real` | Parses real-only, imaginary-only, or `R±Iim`, with `i`/`j` alternatives; delegates component spans to scalar parsers. | No complex target or kernel. | Keep Base's composition grammar. A scalar-kernel change need not reimplement it. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L292-L382), [Parsers target list](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L765). |
| `Base.UUID` | Canonical dashed 36-byte form, case-insensitive hexadecimal. | Same form, four gathered hexadecimal words; low-level result is raw `UInt128`. | `uuid.jl` can consume the kernel; kernel need not own the UUID type. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/uuid.jl#L41-L89), [Parsers](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/bigs.jl#L1048). |
| `Dates.Date`, `DateTime`, `Time` | Dates extends Base's generic functions; default and custom `DateFormat`, locale tables, generated token parsing, and constructor validation. | Pure `CivilParts` kernel plus adapters; default ISO shapes, custom format strings, `Dates.DateFormat`, and compiled `DatePattern`. | Move only the type/format/locale adapters into Dates. [Dates ownership](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/parse.jl#L324-L343), [Parsers adapter](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/dates.jl#L1). |
| `Dates.Timestamp{P}` and Dates extensions | Current master includes resolution-parametric Timestamp and extensible token/target conversion registries. | No Timestamp adapter; supported targets are Date/DateTime/Time. | Preserve existing Dates paths for unsupported targets and extensions during a prototype. [Timestamp](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/types.jl#L194-L273), [Registries](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/io.jl#L329-L371), [Parsers target list](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L765). |

## Input, result, and grammar surfaces

Base's numeric string API accepts `AbstractString`. Its fast float signatures now use `DenseUTF8String`, which includes `String`, `SubString{String}`, and dense `StringView`/`SubString{StringView}`. Integer parsing also has a character overload and internal indexed string-span methods; complex parsing uses those internal span methods. Base does not provide the equivalent public raw-byte-vector/prefix API in these implementations. [String types](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/strings/stringview.jl#L1-L6), [Numeric API and spans](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L41-L288).

Parsers exposes three layers:

| Layer | Inputs and return contract | Coverage and options |
|---|---|---|
| `parse(T, input; ...)`, `tryparse(T, input; ...)` | `AbstractString` or one-based `AbstractVector{UInt8}`; returns `T`, throws on failure, or returns `nothing`. `String`, `SubString{String}`, their byte-code views, and byte vectors use existing byte storage; other strings convert to `String`. | All targets in its target list. `base`/`groupmark` for fixed integers and BigInt; `decimal`/`groupmark` for fixed floats; `decimal`/`groupmark`/`rounding` for BigFloat; replacement `trues`/`falses`; `dateformat` for dates. [Input adapters](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L12), [Dispatch](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L740). |
| `parse(T, bytes, first, last; ...)`, `tryparse(...)` | Inclusive checked byte spans; offset-axis vectors rejected; explicitly handles high indices whose local cursor arithmetic needs rebasing. | Same target/options surface as whole-value calls. [Bounds and spans](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L854), [Index window](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/Parsers.jl#L70). |
| `parsenext(T, bytes, pos, last; ...)` | Checked prefix parsing; returns `(value, nextpos, code)`, consumes the longest valid token, skips no whitespace, retains rounded range values. Token recognition and conversion advance together. | Fixed-width numbers, BigInt, BigFloat, Bool. No date/UUID prefix parser or field/quoted-string scanner. BigFloat uses its bounded kernel grammar rather than every MPFR spelling. [Prefix contract](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L1089). |
| Exact kernels | `AbstractVector{UInt8}`, inclusive caller-controlled span; return `(value, code)`, with `badpos` for explicit-base integers. Valid bounds are a caller contract; some loads are unchecked. | `parseint`, `parsefloat`, `parsebool`, `parsebigint`, `parsebigfloat`, `parseuuid`, `parsecivil`; low-level Bool is only `true`/`false`, UUID is raw `UInt128`, date output is `CivilParts`. [Kernel contract](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/README.md#L160). |

Shared status names are `RC_OK`, `RC_INVALID`, `RC_OVERFLOW`, and `RC_UNDERFLOW`. These represent parsing outcomes, not configuration failures: invalid bases or conflicting separator choices can throw even for `tryparse`. Numeric separators must fit in a byte and cannot conflict with grammar digits/signs; group marks appear between digits, and float digit groups are in the integer coefficient portion. [Codes](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/Parsers.jl#L52), [Integer configuration](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/ints.jl#L816), [Float configuration](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/floats.jl#L11), [Float group grammar](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/floats.jl#L1328).

The civil engine recognizes `y/Y`, `m/d`, `H/I/M/S`, `s`, `u/U`, `p`, and `e/E`; it stores literal text as UTF-8 bytes. Adjacent numeric tokens have fixed widths; separated tokens are greedy. It validates Gregorian month/day/leap-year and clock ranges, carries up to nanosecond fractions, and compiles formats into opaque `DatePattern` plans with ISO/fixed/numeric-date accelerators. `CivilParts`, calendar arithmetic, pattern bytecode, English name tables, and string-pattern caches are Dates-independent. Translating Dates token objects and locale dictionaries is confined to the adapter. [Civil record](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/civil.jl#L5), [Pattern types](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/civil.jl#L249), [Token grammar](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/civil.jl#L465), [Dates translation](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/dates.jl#L21).

## Baseline compatibility differences

These are differences between the released package and the pinned Julia baseline. The default Base front ends added by this prototype handle them as described in the next section. The checked `Base.Parsers.parse` API retains the package's documented policies; it is a separate entry point from `Base.parse`.

| Area | Difference addressed by the default Base front ends |
|---|---|
| Integer whitespace | Base uses Unicode `isspace` and permits whitespace after a sign. Parsers trims ASCII whitespace only and requires sign and digits/prefix to be adjacent. [Base preamble](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L58-L91), [Parsers trimming](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L25), [Documented deltas](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/README.md#L207). |
| Boolean numeric spellings | Base accepts some integer representations of zero/one. Parsers' default set is exactly `true`, `false`, `1`, `0`; custom lists replace those defaults. [Base](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/parse.jl#L186-L219), [Parsers](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L255). |
| Fixed floats | Parsers deliberately rejects finite spellings that round to zero/infinity in checked parsing, uses direct `Float16` rounding, and does not accept C-style NaN payloads. Existing Base behavior is partly platform/library dependent. Kernels still report rounded zero/infinity plus a range code. [Parsers policy](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L236), [Documented deltas](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/README.md#L216), [Base C range handling](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/src/rtutils.c#L484-L590). |
| Arbitrary precision | BigInt's native GMP string tolerances differ from Parsers' grammar. Base BigFloat's public `base` and `precision` keywords have no matching Parsers whole-value options; Parsers' low-level `prec` option is a different API. The bounded decimal BigFloat kernel reports range codes beyond approximately `10^±65536`, while public whole-value parsing can use MPFR's full exponent range and extra spelling support. [Base BigInt](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/gmp.jl#L303-L327), [Base BigFloat](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/mpfr.jl#L407-L415), [Parsers kernel limit](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/bigs.jl#L490), [Public fallback](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L492). |
| Dates completeness and precision | Dates fills omitted trailing components with defaults, and DateTime permits `24:00:00` with zero fraction. Parsers usually requires the whole pattern, with its optional final fractional field exception; it rejects hour 24 and truncates DateTime fractions to milliseconds. [Dates defaulting](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/parse.jl#L21-L108), [Dates validation](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/types.jl#L383-L395), [Parsers adapter](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/dates.jl#L8), [Parsers rules](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/README.md#L226). |
| New Dates features on master | Current Dates has `n` for nanosecond fractions, `Timestamp{P}`, and an ISOTimeFormat containing `n`. Parsers recognizes only `s` for subseconds. Translating the current `Dates.ISOTimeFormat` therefore reaches an unsupported-token error; parsing Time with Parsers' own default/string `s` pattern is a separate path. The package README's statement that Dates supports only three fractional digits is no longer a complete description of current master. [Current tokens/defaults](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/io.jl#L185-L186), [Current ISO formats](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/io.jl#L547-L579), [Parsers rejection](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/dates.jl#L26), [Parsers token set](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/civil.jl#L465). |
| Generic strings and extensions | New dense StringView inputs currently take Base's float fast path but Parsers' generic string-copy path. Base tests also exercise strings with iterator-based behavior and custom integer/real dispatch; importing Parsers' catch-all fallback into Base would change that extension surface. [Dense strings](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/base/strings/stringview.jl#L1-L6), [Generic string tests](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/test/parse.jl#L42-L60), [Parsers input conversion](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L12), [Parsers fallback](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L789). |
| Dates extensibility | Dates permits registered format characters and TimeType conversion layouts. Parsers has a fixed token-to-op mapping and concrete conversions for three target types. Retain Dates' existing mechanism for unsupported tokens/types. [Registries](https://github.com/JuliaLang/julia/blob/dda42805ec500705827dcc9e6603271b215078f1/stdlib/Dates/src/io.jl#L329-L371), [Parsers type conversion](https://github.com/JuliaData/Parsers.jl/blob/v3.0.0/src/api.jl#L651). |

## Default routing and compatibility decisions

`base/parse.jl` is now a thin dispatch layer. Fixed integers and floats, Bool, characters, and Complex components reach `Base.Parsers`; GMP and MPFR parsing methods delegate to their typed extensions. UUID uses the byte kernel. Dates' public parse methods delegate to `Base.Parsers.baseparse`/`basetryparse` methods owned by Dates. Complete canonical ISO shapes use the civil kernels. Other DateFormats retain their generated token grammar, with numeric and fractional fields handled by shared byte scanners. [Base wrappers](../../base/parse.jl), [Compatibility engine](../../base/parsers/basecompat.jl), [Dates adapter](../../stdlib/Dates/src/parsers.jl).

| Boundary | Decision implemented |
|---|---|
| Base versus checked Parsers API | Keep Base's string contract and the checked whole/span/prefix APIs separately. Base's compatibility front ends use the same kernels, without importing Parsers' unsupported-type catch-all into Base. |
| Integer whitespace and extensions | Keep Unicode whitespace, whitespace after a sign, character parsing, custom Integer subtypes, and iterator-based strings. Dense UTF-8 inputs use the byte kernels. The original generic integer algorithm remains for custom strings/types and precise cold-path errors. |
| Bool | Retain numeric spellings such as `01` and `0x1`, and Unicode whitespace; textual spellings use the Bool kernel. |
| Float16 | Ordinary Base retains conversion through Float32, including its existing rounding/range behavior. The checked Parsers API retains direct Float16 conversion. |
| Fixed floats | Ordinary decimal and hexadecimal conversion uses Julia byte kernels. NaN payload syntax and payload bits use the platform's `nan`/`nanf` constructor; decimal conversion no longer calls `jl_try_substrtod` or `jl_try_substrtof`. |
| BigInt | GMP's permissive digit whitespace and second-minus grammar are normalized before the limb kernels. Base BigInt parsing no longer calls `MPZ.set_str!`. |
| BigFloat | Carry explicit precision and rounding through the short, limb, and native fallback paths. MPFR owns non-decimal bases, its extra grammar, and ranges outside the limb converter's bound. Embedded-NUL behavior is retained. No precision setting is temporarily changed globally. |
| BigFloat trailing whitespace | Fix the existing recursive whitespace path that discarded precision and rounding keywords. Padded input now retains the requested options. |
| Dates | Keep omitted trailing fields, `24:00:00`, DateTime precision checks, Timestamp resolution/range checks, locale tables, custom format tokens, and custom TimeTypes. `n` is recognized by civil pattern translation, repairing the two package-suite errors from the first prototype. |
| StringView | Dense StringView and substring inputs use codeunit views and pointer byte gathering. Their backing buffers are retained. |
| Type inference | Successful fixed-width kernels establish the requested result type at the compatibility boundary. Parsing an abstract string retains a concrete result type, including mapping over an empty `AbstractString` vector. |

## Bootstrap repairs

1. Early Base's include function is relative to the Base source directory. The early driver uses explicit `parsers/` paths. Civil and UUID APIs are added with the existing staged `Core.eval`/include pattern already used elsewhere in Base.
2. Three decimal constants equal to `2^63` expanded through Julia's `@int128_str`, which calls Base.parse before the parser exists. Equivalent 64-bit hexadecimal constants remove that bootstrap cycle.
3. Float powers-of-ten tables use integer exponentiation and conversion. They contain the same values without needing Math's floating exponentiation during the early stage.
4. Early Docs can record static docstrings but cannot evaluate `@doc (@doc parse)`. Static `tryparse` documentation and an explicit `parsenext` declaration work before the full Docs module loads.
5. `parsebigint` and `parsebigfloat` are empty generic declarations in the early core. Their type-owning modules add methods later. BigWork and the scratch pool belong to MPFR; the public namespaced BigWork constructor is retained as an alias. Its initializer runs after system-image loading.

## Validation

The modified native Julia identifies as `1.14.0-DEV.3494`. It builds its Base image, full system image, and standard-library package images from this checkout. Revise test targets are additional checks, not substitutes for the native bootstrap.

| Check | Result |
|---|---|
| Native release build and 110 stdlib image configurations | Passed. Final source builds the Base image, full system image, and all 110 standard-library image configurations. Local log: `julia-parsers-default-final-build.log`. |
| Original Parsers 3 kernel/API/regression suites | Passed against the final native image: 1,577,788 checks, including 17,066 deterministic regression-fuzz checks. Local log: `julia-parsers-default-final-package-tests.log`. |
| Independent original-Base comparison | Passed against the final native image: 27,742 parse/tryparse outcomes match, including float bits, explicit BigFloat precision/rounding, errors, Complex, and Dates. Only the original Dates module's printed `Main.` prefix is normalized. [Harness](../../contrib/parsers-upstream/compare_base.jl). |
| Required Base parse Revise target | Passed: 16,208 checks, including abstract-string result inference. Local log: `julia-parsers-default-final-base-revise-tests.log`. |
| Required Dates Revise target | Passed: 8,083,555 checks. Local log: `julia-parsers-default-dates-tests.log`. |
| Native Base parse, GMP/MPFR, rounding, Float16, Rational, Complex, VersionNumber, strings, BinaryPlatforms, loading, TOML and Dates | Passed: 40,701,564 checks across 29 groups. The suites retain 61 existing broken/expected-failure marks. Local log: `julia-parsers-default-final-broader-tests.log`. |
| Fresh startup, include order, documentation, scratch-pool initialization | Passed with four default threads. Dates stays unloaded while integer, float, big-number, and prefix parsing run; Dates adds its adapters on loading. [Verifier](../../contrib/parsers-upstream/verify_bootstrap.jl), Local log: `julia-parsers-default-final-startup.log`. |

Build and test logs are retained locally and are not committed. The harnesses and reproduction commands are included below.

The independent comparison runs the preserved original native system image with the original Dates source from the pinned Julia commit. That avoids turning Base-versus-Parsers tests into comparisons against the same new backend. It deliberately does not compare the old BigFloat trailing-whitespace bug as an intended result; focused tests check that padded input keeps explicit precision and rounding.

The broad runner clears the app's inherited `JULIA_PROJECT=.` and uses a separate writable first depot, with this build's standard-library depot second. Loading tests create fixture package caches. Keeping those caches out of the system depot prevents the REPL tests' temporary depots from finding them through their default-depot fallback. Earlier precompile-message count failures also reproduced with the original Base image; the final unmodified loading suite passes with isolated caches.

This is macOS ARM64 validation. Cross-platform CI, package ecosystem testing, performance gates, and final Julia API policy are still needed before an upstream PR would be ready. No PR or release was requested or created.

## Running it

```sh
cd /path/to/julia-checkout
make -j8
JULIA_TEST_FAILFAST=1 make test-revise-parse
JULIA_TEST_FAILFAST=1 make test-revise-Dates
./julia --startup-file=no --check-bounds=yes contrib/parsers-upstream/run_package_tests.jl ../Parsers
./julia --startup-file=no contrib/parsers-upstream/compare_base.jl
./julia --startup-file=no --threads=4 contrib/parsers-upstream/verify_bootstrap.jl
```

Run image rebuilds sequentially. The macOS system make can select the broader `test-%` prerequisite rule for a `test-revise-*` target, rebuilding images before tests. Direct `make -C test revise-parse` and `revise-Dates` invoke the same Revise runner once the source build is current.

For the combined native suites, use a fresh writable first depot:

```sh
env -u JULIA_PROJECT -u JULIA_BINDIR \
    JULIA_DEPOT_PATH="$PWD/../julia-parsers-validation-depot:$PWD/usr/share/julia" \
    JULIA_LOAD_PATH='@:@stdlib' JULIA_CPU_THREADS=4 JULIA_NUM_THREADS=4,1 \
    ./julia --startup-file=no --check-bounds=yes --depwarn=error \
    test/runtests.jl --buildroot="$PWD" --seed=1346458195 \
    parse gmp mpfr rounding float16 rational complex version strings \
    binaryplatforms loading TOML Dates
```

```julia
parse(Int, "- 0x80")
parse(Float64, "1.25")
parse(BigInt, "123456789012345678901234567890")
parse(BigFloat, "0.1 "; precision=80, rounding=Base.MPFR.MPFRRoundDown)
Base.Parsers.parse(Int, "1,234"; groupmark=',')
Base.Parsers.parsenext(Float64, codeunits("1.25,"), 1, 5)
using Dates
parse(Time, "12:34:56.123456789")
parse(Dates.Timestamp, "2024-02-29T12:34:56.123456789")
```
