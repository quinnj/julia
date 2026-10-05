# This file is a part of Julia. License is MIT: https://julialang.org/license

### Parsing utilities

_directives(::Type{DateFormat{S,T}}) where {S,T} = T.parameters

character_codes(df::Type{DateFormat{S,T}}) where {S,T} = character_codes(_directives(df))
function character_codes(directives::Core.SimpleVector)
    letters = sizehint!(Char[], length(directives))
    for (i, directive) in enumerate(directives)
        if directive <: DatePart
            letter = first(directive.parameters)
            push!(letters, letter)
        end
    end
    return letters
end

genvar(t::DataType) = Symbol(lowercase(string(nameof(t))))

"""
    tryparsenext_core(str::AbstractString, pos::Int, len::Int, df::DateFormat, raise=false)

Parse the string according to the directives within the `DateFormat`. Parsing will start at
character index `pos` and will stop when all directives are used or we have parsed up to
the end of the string, `len`. When a directive cannot be parsed the returned value
will be `nothing` if `raise` is false otherwise an exception will be thrown.

If successful, return a 3-element tuple `(values, pos, num_parsed)`:
* `values::Tuple`: A tuple which contains a value
  for each `DatePart` within the `DateFormat` in the order
  in which they occur. If the string ends before we finish parsing all the directives
  the missing values will be filled in with default values.
* `pos::Int`: The character index at which parsing stopped.
* `num_parsed::Int`: The number of values which were parsed and stored within `values`.
  Useful for distinguishing parsed values from default values.
"""
@generated function tryparsenext_core(str::AbstractString, pos::Int, len::Int,
                                      df::DateFormat, raise::Bool=false)
    directives = _directives(df)
    letters = character_codes(directives)

    tokens = Type[CONVERSION_SPECIFIERS[letter] for letter in letters]
    value_names = Symbol[genvar(t) for t in tokens]
    value_defaults = Any[CONVERSION_DEFAULTS[t] for t in tokens]

    # Pre-assign variables to defaults. Allows us to use `@goto done` without worrying about
    # unassigned variables.
    assign_defaults = Expr[]
    for (name, default) in zip(value_names, value_defaults)
        push!(assign_defaults, quote
            $name = $default
        end)
    end

    vi = 1
    parsers = Expr[]
    for i = 1:length(directives)
        if directives[i] <: DatePart
            name = value_names[vi]
            vi += 1
            push!(parsers, quote
                pos > len && @goto done
                let val = tryparsenext(directives[$i], str, pos, len, locale)
                    val === nothing && @goto error
                    $name, pos = val
                end
                num_parsed += 1
                directive_index += 1
            end)
        else
            push!(parsers, quote
                pos > len && @goto done
                let val = tryparsenext(directives[$i], str, pos, len, locale)
                    val === nothing && @goto error
                    delim, pos = val
                end
                directive_index += 1
            end)
        end
    end

    return quote
        directives = df.tokens
        locale::DateLocale = df.locale

        num_parsed = 0
        directive_index = 1

        $(assign_defaults...)
        $(parsers...)

        pos > len || @goto error

        @label done
        return $(Expr(:tuple, value_names...)), pos, num_parsed

        @label error
        if raise
            if directive_index > length(directives)
                throw(ArgumentError("Found extra characters at the end of date time string"))
            else
                d = directives[directive_index]
                throw(ArgumentError("Unable to parse date time. Expected directive $d at char $pos"))
            end
        end
        return nothing
    end
end

# Every Timestamp{P} parses the same fields
conversion_translations(::Type{T}) where {T<:TimeType} = CONVERSION_TRANSLATIONS[T]
conversion_translations(::Type{<:Timestamp}) = CONVERSION_TRANSLATIONS[Timestamp]

"""
    tryparsenext_internal(::Type{<:TimeType}, str, pos, len, df::DateFormat, raise=false)

Parse the string according to the directives within the `DateFormat`. The specified `TimeType`
type determines the type of and order of tokens returned. If the given `DateFormat` or string
does not provide a required token a default value will be used. When the string cannot be
parsed the returned value will be `nothing` if `raise` is false otherwise an exception will
be thrown.

If successful, returns a 2-element tuple `(values, pos)`:
* `values::Tuple`: A tuple which contains a value
  for each token as specified by the passed in type.
* `pos::Int`: The character index at which parsing stopped.
"""
@generated function tryparsenext_internal(::Type{T}, str::AbstractString, pos::Int, len::Int,
                                          df::DateFormat, raise::Bool=false) where T<:TimeType
    letters = character_codes(df)

    tokens = Type[CONVERSION_SPECIFIERS[letter] for letter in letters]
    value_names = Symbol[genvar(t) for t in tokens]

    output_tokens = conversion_translations(T)
    output_names = Symbol[genvar(t) for t in output_tokens]
    output_defaults = Any[CONVERSION_DEFAULTS[t] for t in output_tokens]

    # Pre-assign output variables to defaults. Ensures that all output variables are
    # assigned as the value tuple returned from `tryparsenext_core` may not include all
    # of the required variables.
    assign_defaults = Expr[
        quote
            $name = $default
        end
        for (name, default) in zip(output_names, output_defaults)
    ]

    # Unpacks the value tuple returned by `tryparsenext_core` into separate variables.
    value_tuple = Expr(:tuple, value_names...)

    # DateTime has no nanosecond field, so add an `n` field to the milliseconds. It must
    # be a whole number of milliseconds.
    normalize_fraction = if T === DateTime && Nanosecond in tokens
        quote
            millisecond_from_nanoseconds, nanosecond_remainder =
                divrem(nanosecond, Int64(1000000))
            if nanosecond_remainder != 0
                raise && throw(ArgumentError("Fractional second is not exactly representable as a DateTime"))
                return nothing
            end
            millisecond += millisecond_from_nanoseconds
        end
    else
        nothing
    end

    return quote
        val = tryparsenext_core(str, pos, len, df, raise)
        val === nothing && return nothing
        values, pos, num_parsed = val
        $(assign_defaults...)
        $value_tuple = values
        $normalize_fraction
        return $(Expr(:tuple, output_names...)), pos
    end
end

@inline function tryparsenext_sign(str::AbstractString, i::Int, len::Int)
    i > len && return nothing
    c, ii = iterate(str, i)::Tuple{Char, Int}
    if c == '+'
        return 1, ii
    elseif c == '-'
        return -1, ii
    else
        return nothing
    end
end

@inline tryparsenext_base10(str::AbstractString, i::Int, len::Int,
                           min_width::Int=1, max_width::Int=0) =
    Base.Parsers.parsedigits(str, i, len, min_width, max_width)

@inline function tryparsenext_word(str::AbstractString, i, len, locale, maxchars=0)
    word_start, word_end = i, 0
    max_pos = maxchars <= 0 ? len : min(len, nextind(str, i, maxchars-1))
    @inbounds while i <= max_pos
        c, ii = iterate(str, i)::Tuple{Char, Int}
        if isletter(c)
            word_end = i
        else
            break
        end
        i = ii
    end
    if word_end == 0
        return nothing
    else
        return SubString(str, word_start, word_end), i
    end
end

Base.parse(::Type{DateTime}, str::AbstractString, df::typeof(ISODateTimeFormat)) =
    Base.Parsers.baseparse(DateTime, str, df)

Base.parse(::Type{T}, str::AbstractString, df::DateFormat=default_format(T)) where {T<:TimeType} =
    Base.Parsers.baseparse(T, str, df)

Base.tryparse(::Type{T}, str::AbstractString, df::DateFormat=default_format(T)) where {T<:TimeType} =
    Base.Parsers.basetryparse(T, str, df)

"""
    parse_components(str::AbstractString, df::DateFormat)::Array{Any}

Parse the string into its components according to the directives in the `DateFormat`.
Each component will be a distinct type, typically a subtype of Period. The order of the
components will match the order of the `DatePart` directives within the `DateFormat`. The
number of components may be less than the total number of `DatePart` directives.
"""
@generated function parse_components(str::AbstractString, df::DateFormat)
    letters = character_codes(df)
    tokens = Type[CONVERSION_SPECIFIERS[letter] for letter in letters]

    return quote
        pos, len = firstindex(str), lastindex(str)
        val = tryparsenext_core(str, pos, len, df, #=raise=#true)
        @assert val !== nothing
        values, pos, num_parsed = val
        types = $(Expr(:tuple, tokens...))
        result = Vector{Any}(undef, num_parsed)
        for (i, typ) in enumerate(types)
            i > num_parsed && break
            result[i] = typ(values[i])  # Constructing types takes most of the time
        end
        return result
    end
end
