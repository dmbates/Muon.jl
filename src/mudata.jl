mutable struct MuData
    file::Union{HDF5.File, Nothing}
    mod::Dict{String, AnnData}

    obs::DataFrame
    obs_names::Index{<:AbstractString}
    obsm::StrAlignedMapping{Tuple{1 => 1}, MuData}
    obsp::StrAlignedMapping{Tuple{1 => 1, 2 => 1}, MuData}

    var::DataFrame
    var_names::Index{<:AbstractString}
    varm::StrAlignedMapping{Tuple{1 => 2}, MuData}
    varp::StrAlignedMapping{Tuple{1 => 2, 2 => 2}, MuData}

    function MuData(file::HDF5.File, backed=true)
        mdata = new(backed ? file : nothing)

        # this needs to go first because it's used by size() and size()
        # is used for dimensionalty checks
        mdata.obs, obs_names = read_dataframe(file["obs"])
        mdata.var, var_names = read_dataframe(file["var"])
        mdata.obs_names, mdata.var_names = Index(obs_names), Index(var_names)

        # Observations
        mdata.obsm = StrAlignedMapping{Tuple{1 => 1}}(
            mdata,
            haskey(file, "obsm") ? read_dict_of_mixed(file["obsm"]) : nothing,
        )
        mdata.obsp = StrAlignedMapping{Tuple{1 => 1, 2 => 1}}(
            mdata,
            haskey(file, "obsp") ? read_dict_of_matrices(file["obsp"]) : nothing,
        )

        # Variables
        mdata.varm = StrAlignedMapping{Tuple{1 => 2}}(
            mdata,
            haskey(file, "varm") ? read_dict_of_mixed(file["varm"]) : nothing,
        )
        mdata.varp = StrAlignedMapping{Tuple{1 => 2, 2 => 2}}(
            mdata,
            haskey(file, "varp") ? read_dict_of_matrices(file["varp"]) : nothing,
        )

        # Modalities
        mdata.mod = Dict{String, AnnData}()
        mods = HDF5.keys(file["mod"])
        for modality in mods
            mdata.mod[modality] = AnnData(file["mod"][modality], backed)
        end

        update_attr!(mdata, :var)
        update_attr!(mdata, :obs)
        return mdata
    end

    function MuData(;
        mod::Union{AbstractDict{<:AbstractString, AnnData}, Nothing}=nothing,
        obs::Union{DataFrame, Nothing}=nothing,
        obs_names::Union{AbstractVector{<:AbstractString}, Nothing}=nothing,
        var::Union{DataFrame, Nothing}=nothing,
        var_names::Union{AbstractVector{<:AbstractString}, Nothing}=nothing,
        obsm::Union{
            AbstractDict{<:AbstractString, Union{AbstractArray{<:Number}, DataFrame}},
            Nothing,
        }=nothing,
        varm::Union{
            AbstractDict{<:AbstractString, Union{AbstractArray{<:Number}, DataFrame}},
            Nothing,
        }=nothing,
        obsp::Union{AbstractDict{<:AbstractString, AbstractMatrix{<:Number}}, Nothing}=nothing,
        varp::Union{AbstractDict{<:AbstractString, AbstractMatrix <: Number}, Nothing}=nothing,
    )
        mdata = new(nothing, Dict{String, AnnData}())
        if !isnothing(mod)
            merge!(mdata.mod, mod)
        end

        # TODO: dimension checking. This needs merging dimensions of all the AnnDatas based on var_names/obs_names
        mdata.obs = isnothing(obs) ? DataFrame() : obs
        mdata.obs_names = isnothing(obs_names) ? Index(String[]) : Index(obs_names)
        mdata.var = isnothing(var) ? DataFrame() : var
        mdata.var_names = isnothing(var_names) ? Index(String[]) : Index(var_names)

        mdata.obsm = StrAlignedMapping{Tuple{1 => 1}}(mdata, obsm)
        mdata.varm = StrAlignedMapping{Tuple{1 => 2}}(mdata, varm)
        mdata.obsp = StrAlignedMapping{Tuple{1 => 1, 2 => 1}}(mdata, obsp)
        mdata.varp = StrAlignedMapping{Tuple{1 => 2, 2 => 2}}(mdata, varp)

        update_attr!(mdata, :var)
        update_attr!(mdata, :obs)
        return mdata
    end
end

function readh5mu(filename::AbstractString; backed=true)
    filename = abspath(filename) # this gets stored in the HDF5 objects for backed datasets
    if !backed
        fid = h5open(filename, "r")
    else
        fid = h5open(filename, "r+")
    end
    local mdata
    try
        mdata = MuData(fid, backed)
    finally
        if !backed
            close(fid)
        end
    end
    return mdata
end

function writeh5mu(filename::AbstractString, mudata::MuData)
    filename = abspath(filename)
    if mudata.file === nothing || filename != HDF5.filename(mudata.file)
        file = h5open(filename, "w")
        try
            write(file, mudata)
        finally
            close(file)
        end
    else
        write(mudata)
    end
end

function Base.write(parent::Union{HDF5.File, HDF5.Group}, mudata::MuData)
    if parent === mudata.file
        write(mudata)
    else
        g = create_group(parent, "mod")
        for (mod, adata) in mudata.mod
            write(g, mod, adata)
        end
        write_metadata(parent, mudata)
    end
end

function Base.write(mudata::MuData)
    if mudata.file === nothing
        throw("adata is not backed, need somewhere to write to")
    end
    for adata in values(mudata.mod)
        write(adata)
    end
    write_metadata(mudata.file, mudata)
end

function write_metadata(parent::Union{HDF5.File, HDF5.Group}, mudata::MuData)
    write_attr(parent, "obs", mudata.obs_names, shrink_attr(mudata, :obs))
    write_attr(parent, "obsm", mudata.obsm)
    write_attr(parent, "obsp", mudata.obsp)
    write_attr(parent, "var", mudata.var_names, shrink_attr(mudata, :var))
    write_attr(parent, "varm", mudata.varm)
    write_attr(parent, "varp", mudata.varp)
end

Base.size(mdata::MuData) = (length(mdata.obs_names), length(mdata.var_names))
Base.size(mdata::MuData, d::Integer) = size(mdata)[d]

Base.getindex(mdata::MuData, modality::Symbol) = mdata.mod[String(modality)]
Base.getindex(mdata::MuData, modality::AbstractString) = mdata.mod[modality]
function Base.getindex(
    mdata::MuData,
    I::Union{
        AbstractUnitRange,
        Colon,
        AbstractVector{<:Integer},
        AbstractVector{<:AbstractString},
        Number,
        AbstractString,
    },
    J::Union{
        AbstractUnitRange,
        Colon,
        AbstractVector{<:Integer},
        AbstractVector{<:AbstractString},
        Number,
        AbstractString,
    },
)
    @boundscheck begin
        i = I isa AbstractString || I isa AbstractVector{<:AbstractString} ? (:) : I
        j = J isa AbstractString || J isa AbstractVector{<:AbstractString} ? (:) : J
        checkbounds(mdata, i, j)
    end
    i, j = convertidx(I, mdata.obs_names), convertidx(J, mdata.var_names)
    newmu = MuData(
        mod=Dict{String, AnnData}(
            k => ad[
                getadidx(I, mdata.obsm[k], mdata.obs_names),
                getadidx(J, mdata.varm[k], mdata.var_names),
            ] for (k, ad) in mdata.mod
        ),
        obs=isempty(mdata.obs) ? nothing : mdata.obs[i, :],
        obs_names=mdata.obs_names[i],
        var=isempty(mdata.var) ? nothing : mdata.var[j, :],
        var_names=mdata.var_names[j],
    )
    copy_subset(mdata.obsm, newmu.obsm, i, j)
    copy_subset(mdata.varm, newmu.varm, i, j)
    copy_subset(mdata.obsp, newmu.obsp, i, j)
    copy_subset(mdata.varp, newmu.varp, i, j)
    return newmu
end

getadidx(I::Colon, ref::AbstractVector{<:Unsigned}, idx::Index{<:AbstractString}) = I
getadidx(
    I::Union{AbstractVector{<:Integer}, AbstractUnitRange},
    ref::AbstractVector{<:Unsigned},
    idx::Index{<:AbstractString},
) = filter(x -> x > 0x0, ref[I])
getadidx(
    I::Union{AbstractString, AbstractVector{<:AbstractString}},
    ref::AbstractVector{<:Unsigned},
    idx::Index{<:AbstractString},
) = getadidx(idx[I, true], ref, idx)
getadix(I::Number, ref::AbstractVector{<:Unsigned}, idx::Index{<:AbstractString}) =
    getadidx([I], ref, idx)

function Base.show(io::IO, mdata::MuData)
    compact = get(io, :compact, false)
    repr = """MuData object $(size(mdata)[1]) \u2715 $(size(mdata)[2])"""
    for (name, adata) in mdata.mod
        repr *= """\n\u2514 $(name)"""
        repr *= """\n  AnnData object $(size(adata)[1]) \u2715 $(size(adata)[2])"""
    end
    print(io, repr)
end

function Base.show(io::IO, ::MIME"text/plain", mdata::MuData)
    show(io, mdata)
end

isbacked(mdata::MuData) = mdata.file !== nothing

function update_attr!(mdata::MuData, attr::Symbol)
    globalcols = [
        col for
        col in names(getproperty(mdata, attr)) if !any(startswith.(col, keys(mdata.mod) .* ":"))
    ]
    globaldata = getproperty(mdata, attr)[!, globalcols]
    namesattr = Symbol(string(attr) * "_names")
    old_rownames = getproperty(mdata, namesattr)

    idxcol, rowcol = find_unique_colnames(mdata, attr, 2)

    if !isempty(mdata.mod)
        if length(mdata.mod) > 1
            newdf = outerjoin(
                (
                    insertcols!(
                        rename!(
                            x -> mod * ":" * x,
                            select(getproperty(ad, attr), :, copycols=false),
                        ),
                        idxcol => getproperty(ad, namesattr),
                        mod * ":" * rowcol => 1:length(getproperty(ad, namesattr)),
                    ) for (mod, ad) in mdata.mod
                )...,
                on=idxcol,
            )
        elseif length(mdata.mod) == 1
            mod, ad = iterate(mdata.mod)[1]
            newdf = insertcols!(
                rename!(x -> mod * ":" * x, select(getproperty(ad, attr), :, copycols=false)),
                idxcol => getproperty(ad, namesattr),
                mod * ":" * rowcol => 1:length(getproperty(ad, namesattr)),
            )
        end
        newdf = leftjoin(
            newdf,
            insertcols!(globaldata, idxcol => getproperty(mdata, namesattr)),
            on=idxcol,
        )
        rownames = newdf[!, idxcol]
        select!(newdf, Not(idxcol))

        try
            rownames = convert(Vector{nonmissingtype(eltype(rownames))}, rownames)
        catch e
            if e isa MethodError
                throw(
                    "New $(string(namesattr)) contain missing values. That should not happen, ever.",
                )
            else
                rethrow(e)
            end
        end
    else
        newdf = DataFrame()
        rownames = Vector{String}()
    end

    setproperty!(mdata, attr, newdf)
    setproperty!(mdata, namesattr, Index(rownames))

    mattr = Symbol(string(attr) * "m")
    for (mod, ad) in mdata.mod
        colname = mod * ":" * rowcol
        adindices = newdf[!, colname]
        select!(newdf, Not(colname))
        replace!(adindices, missing => 0)
        getproperty(mdata, mattr)[mod] =
            convert(Vector{minimum_unsigned_type_for_n(maximum(adindices))}, adindices)
    end

    keep_index = rownames .∈ (old_rownames,)
    @inbounds if sum(keep_index) != length(old_rownames)
        for (k, v) in getproperty(mdata, mattr)
            if k ∉ keys(mdata.mod)
                getproperty(mdata, mattr)[k] = v[keep_index, :]
            end
        end

        pattr = Symbol(string(attr) * "p")
        for (k, v) in getproperty(mdata, pattr)
            if k ∉ keys(mdata.mod)
                getproperty(mdata, pattr)[k] = v[keep_index, keep_index]
            end
        end
    end

    nothing
end

function shrink_attr(mdata::MuData, attr::Symbol)
    globalcols = [
        col for
        col in names(getproperty(mdata, attr)) if !any(startswith.(col, keys(mdata.mod) .* ":"))
    ]
    return disallowmissing!(select(getproperty(mdata, attr), globalcols))
end
