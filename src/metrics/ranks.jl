using NamedArrays, NamedDims
import ADRIA: timesteps


function seed_ranks(rs::ResultSet; kwargs...)
    selected = slice_results(rs.ranks[intervention=1]; kwargs...)
    nsteps, nsites = size(selected)

    ts = timesteps(rs)

    @assert length(ts) == nsteps

    r_ids = rs.site_data.reef_siteid
    if haskey(kwargs, :sites)
        r_ids = r_ids[kwargs[:sites]]
    end

    if length(r_ids) != nsites
        @warn "Length of reef ids do not match number of sites"
    end

    return NamedArray(unname(selected), (ts, r_ids, collect(1:size(selected, 3))), ("timesteps", "sites", "scenarios"))
end

"""
    top_n_seeded_sites(rs::ResultSet, n::Int64; kwargs...)

Get the top n seeded sites over time by their unique site id.
Lower rank values are better (e.g., 1 = first choice)

# Arguments
- rs : ResultSet
- n : `n` sites to retrieve
- kwargs : dimensions to slice across

# Returns
NamedDimsArray : [sites, [Site Index, Unique ID, Rank], scenarios]
"""
function top_n_seeded_sites(rs::ResultSet, n::Int64; kwargs...)
    ranked_sites = seed_ranks(rs; kwargs...)

    r_ids = rs.site_data.reef_siteid
    min_rank = length(r_ids) + 1
    # ranked_sites[ranked_sites .== min_rank]

    c_ranks = mean(ranked_sites, dims=1)
    top_sites = Array{Union{String, Int32, Float32, Missing}}(undef, n, 3, size(ranked_sites, 3))
    for scen in axes(ranked_sites, 3)
        flat = vec(c_ranks[1, :, scen])

        idx = partialsortperm(flat, 1:n)

        rank_score = flat[idx]
        if all(rank_score .== min_rank)
            top_sites[:, :, scen] .= missing
            continue
        end

        top_sites[:, 1, scen] .= Int32.(idx)
        top_sites[:, 2, scen] .= r_ids[idx]
        top_sites[:, 3, scen] .= rank_score
    end

    return NamedDimsArray(top_sites, (:sites, :site_ranks, :scenarios))
end