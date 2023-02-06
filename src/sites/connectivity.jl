"""
    site_connectivity(file_loc, site_order; con_cutoff=0.02, agg_func=mean, swap=false)::NamedTuple

Create transitional probability matrix indicating connectivity between
sites, level of centrality, and the strongest predecessor for each site.

NOTE: Transposes transitional probability matrix if `swap == true`
      If multiple files are read in, this assumes all file rows/cols
      follow the same order as the first file read in.

# Examples
```julia
    site_connectivity("MooreTPmean.csv", site_order)
    site_connectivity("MooreTPmean.csv", site_order; con_cutoff=0.02, agg_func=mean, swap=true)
```

# Arguments
- file_loc : str, path to data file (or datasets) to load.
               If a folder, searches subfolders as well.
- unique_ids : Vector, of unique site ids in their expected order
- site_order : Vector, of indices mapping duplicate conn_ids to their unique ID positions
- con_cutoff : float, percent thresholds of max for weak connections in
                network (defined by user or defaults in simConstants)
- agg_func : function_handle, defaults to `mean`.
- swap : boolean, whether to transpose data.

# Returns
NamedTuple:
- TP_data : Matrix, containing the transition probability for all sites
- truncated : ID of sites removed
- site_ids : ID of sites kept
"""
function site_connectivity(file_loc::String, unique_site_ids::Vector{String};
    con_cutoff::Float64=1e-6, agg_func::Function=mean, swap::Bool=false)::NamedTuple

    local extracted_TP = []
    if isdir(file_loc)
        con_file1 = nothing
        con_files::Vector{String} = String[]
        for (root, _, files) in walkdir(file_loc)
            append!(con_files, map((x) -> joinpath(root, x), files))
            conn_data = [
                # We skip the first column (with drop=[1]) as this is the source site index column
                Matrix(CSV.read(fn, DataFrame, comment="#", missingstring=["NA"], transpose=swap, types=Float64, drop=[1]))
                for fn in con_files
            ]

            if length(conn_data) > 0
                # Add mean TP for a single year
                push!(extracted_TP, agg_func(conn_data))
            end

            if isnothing(con_file1) && length(con_files) > 0
                # Keep first file
                # We skip the first column (with drop=[1]) as this is the source site index column
                con_file1 = CSV.read(con_files[1], DataFrame, comment="#", missingstring=["NA"], transpose=swap, types=Float64, drop=[1])
            end

            con_files = String[]
        end

        # Mean of across all years
        extracted_TP = agg_func(extracted_TP)

    elseif isfile(file_loc)
        con_files = String[file_loc]

        con_file1 = CSV.read(con_files[1], DataFrame, comment="#", missingstring=["NA"], transpose=swap, types=Float64, drop=[1])
        extracted_TP = Matrix(file1)
    else
        error("Could not find location: $(file_loc)")
    end

    # Get site ids from first file
    con_site_ids::Vector{String} = names(con_file1)
    con_site_ids = [x[1] for x in split.(con_site_ids, "_v"; limit=2)]

    # Get IDs missing in con_site_ids
    invalid_ids::Vector{String} = setdiff(con_site_ids, unique_site_ids)

    # Get IDs missing in site_order
    append!(invalid_ids, setdiff(unique_site_ids, con_site_ids))

    # Identify IDs that do not appear in `invalid_ids`
    valid_ids = [x ∉ invalid_ids ? x : missing for x in unique_site_ids]
    valid_idx = .!ismissing.(valid_ids)

    # Align IDs
    unique_site_ids = coalesce(unique_site_ids[valid_idx])
    site_order = [findfirst(c_id .== con_site_ids) for c_id in unique_site_ids]

    if length(invalid_ids) > 0
        if length(invalid_ids) >= length(con_site_ids)
            error("All sites appear to be missing from data set. Aborting.")
        end

        @warn "The following sites (n=$(length(invalid_ids))) were not found in site_ids and were removed:\n$(invalid_ids)"
    end

    # Reorder all data into expected form
    extracted_TP = extracted_TP[site_order, site_order]

    if con_cutoff > 0.0
        extracted_TP[extracted_TP.<con_cutoff] .= 0.0
    end

    TP_base = NamedDimsArray(sparse(extracted_TP), Source=unique_site_ids, Receiving=unique_site_ids)
    @assert all(0.0 .<= TP_base .<= 1.0) "Connectivity data not scaled between 0 - 1"

    return (TP_base=TP_base, truncated=invalid_ids, site_ids=unique_site_ids)
end
function site_connectivity(file_loc::String, unique_site_ids::Vector{T};
    con_cutoff::Float64=1e-6, agg_func::Function=mean, swap::Bool=false)::NamedTuple where {T<:AbstractString}

    # Remove any row marked as missing
    if any(ismissing.(unique_site_ids))
        @warn "Removing entries marked as `missing` from provided list of sites."
        unique_site_ids::Vector{String} = String.(unique_site_ids[.!ismissing.(unique_site_ids)])
    else
        unique_site_ids = String.(unique_site_ids)
    end

    return site_connectivity(file_loc, unique_site_ids;
        con_cutoff=con_cutoff, agg_func=agg_func, swap=swap)
end


"""
    connectivity_strength(TP_base::AbstractArray)::NamedTuple

Generate array of outdegree connectivity strength for each node and its
strongest predecessor.

# Returns
NamedTuple:
- in_conn : sites ranked by incoming connectivity
- out_conn : sites ranked by outgoing connectivity
- strongest_predecessor : strongest predecessor for each site
"""
function connectivity_strength(TP_base::AbstractArray)::NamedTuple

    g = SimpleDiGraph(TP_base)

    # ew_base = weights(g)  # commented out ew_base are all equally weighted anyway...

    # Measure centrality based on number of incoming connections
    # C1 = indegree_centrality(g)
    # C2 = outdegree_centrality(g)
    C1 = betweenness_centrality(g)
    C2 = 1.0 .- katz_centrality(g)

    # strong_pred = closeness_centrality(g)

    # For each edge, find strongly connected predecessor (by number of connections)
    strong_pred = zeros(Int64, size(C1)...)
    for v_id in vertices(g)
        incoming = inneighbors(g, v_id)

        if length(incoming) > 0
            # For each incoming connection, find the one with most "in"
            # connections themselves
            in_conns = Int64[length(inneighbors(g, in_id)) for in_id in incoming]

            # Find index of predecessor with most connections
            # (use `first` to get the first match in case of a tie)
            most_conns = maximum(in_conns)
            idx = first(findall(in_conns .== most_conns))
            strong_pred[v_id] = incoming[idx]
        else
            strong_pred[v_id] = 0
        end
    end

    return (in_conn=C1, out_conn=C2, strongest_predecessor=strong_pred)
end
