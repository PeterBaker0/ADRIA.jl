using NCDatasets

"""
    EnvLayer{S, TF}

Store environmental data layers used for scenario
"""
mutable struct EnvLayer{S<:AbstractString,TF}
    dpkg_path::S
    site_data_fn::S
    const site_id_col::S
    const unique_site_id_col::S
    init_coral_cov_fn::S
    connectivity_fn::S
    DHW_fn::S
    wave_fn::S
    const timeframe::TF
end

"""
    Domain{M,I,D,S,V,T,X}

Core ADRIA domain. Represents study area.
"""
mutable struct Domain{Σ<:NamedMatrix{<:Real},M<:NamedMatrix{<:Real},I<:Vector{Int64},D<:DataFrame,S<:String,V<:Vector{Float64},T<:Vector{String},X<:AbstractArray{<:Real},Y<:AbstractArray{<:Real},Z<:AbstractArray{<:Real}}
    const name::S  # human-readable name
    RCP::S  # RCP scenario represented
    env_layer_md::EnvLayer  # Layers used
    scenario_invoke_time::S  # time latest set of scenarios were run
    const TP_data::Σ  # site connectivity data
    const in_conn::V  # sites ranked by incoming connectivity strength (i.e., number of incoming connections)
    const out_conn::V  # sites ranked by outgoing connectivity strength (i.e., number of outgoing connections)
    const strongpred::I  # strongest predecessor
    site_data::D  # table of site data (depth, carrying capacity, etc)
    site_distances::Z  # Matrix of distances between each site
    median_site_distance::Float64
    const site_id_col::S  # column to use as site ids, also used by the connectivity dataset (indicates order of `TP_data`)
    const unique_site_id_col::S  # column of unique site ids
    init_coral_cover::M  # initial coral cover dataset
    const coral_growth::CoralGrowth  # coral
    const site_ids::T  # Site IDs that are represented (i.e., subset of site_data[:, site_id_col], after missing sites are filtered)
    const removed_sites::T  # indices of sites that were removed. Used to align site_data, DHW, connectivity, etc.
    dhw_scens::X  # DHW scenarios
    wave_scens::Y  # wave scenarios

    # Parameters
    model::Model  # core model
    sim_constants::SimConstants
end

"""
Barrier function to create Domain struct without specifying Intervention/Criteria/Coral/SimConstant parameters.
"""
function Domain(name::String, rcp::String, env_layers::EnvLayer, TP_base::NamedMatrix{<:T}, in_conn::Vector{Float64}, out_conn::Vector{Float64},
    strongest_predecessor::Vector{Int64}, site_data::DataFrame, site_distances::Matrix{Float64}, median_site_distance::Float64, site_id_col::String, unique_site_id_col::String,
    init_coral_cover::NamedMatrix{<:T}, coral_growth::CoralGrowth, site_ids::Vector{String}, removed_sites::Vector{String},
    DHWs::AbstractArray{<:T}, waves::AbstractArray{<:T})::Domain where {T<:Real}

    # Update minimum site depth to be considered if default bounds are deeper than the deepest site in the cluster
    criteria::Criteria = Criteria()
    sim_constants::SimConstants = SimConstants()

    if criteria.depth_min.bounds[1] > maximum(site_data.depth_med)
        min_depth = minimum(site_data.depth_med)
        fields = fieldnames(typeof(criteria))
        c_spec = (; zip(fields, [getfield(criteria, f) for f in fields])...)
        @set! c_spec.depth_min.bounds = (min_depth, minimum([min_depth + 2.0, maximum(site_data.depth_med)]))

        # Update number of sites to consider for distance-based spreading
        max_top_n = ceil(Int64, 2.0 * length(site_ids) ./ 3.0)
        if (criteria.top_n.bounds[2] > max_top_n) || (criteria.top_n.bounds[1] < sim_constants.nsiteint)
            @set! c_spec.top_n.bounds = (sim_constants.nsiteint, minimum([10, max_top_n]))
        end

        criteria = Criteria(c_spec...)
    end

    model::Model = Model((EnvironmentalLayer(DHWs, waves), Intervention(), criteria, Coral()))

    return Domain(name, rcp, env_layers, "", TP_base, in_conn, out_conn, strongest_predecessor, site_data, site_distances, median_site_distance, site_id_col, unique_site_id_col,
        init_coral_cover, coral_growth, site_ids, removed_sites, DHWs, waves,
        model, sim_constants)
end

"""
    site_distance(site_data::DataFrame)::Matrix

Calculate matrix of unique distances between sites.
"""

function site_distances(site_data::DataFrame)::Tuple{Matrix{Float64},Float64}
    site_centroids = centroids(site_data)
    longitudes = first.(site_centroids)
    latitudes = last.(site_centroids)

    nsites = size(site_data)[1]
    dist = zeros(nsites, nsites)
    @inbounds for jj = 1:nsites
        @inbounds for ii = 1:nsites
            dist[ii, jj] = haversine([longitudes[ii], latitudes[ii]], [longitudes[jj], latitudes[jj]])
        end
    end
    dist[diagind(dist)] .= NaN
    median_site_dist = median(dist[.!isnan.(dist)])
    return dist, median_site_dist
end

"""
    Domain(name::String, rcp::String, timeframe::Vector, site_data_fn::String, site_id_col::String, unique_site_id_col::String, init_coral_fn::String,
           conn_path::String, dhw_fn::String, wave_fn::String)::Domain

Convenience constructor for Domain.

# Arguments
- `name` : Name of domain
- `dpkg_path` : location of data package
- `rcp` : RCP scenario represented
- `timeframe` : Time steps represented
- `site_data_fn` : File name of spatial data used
- `site_id_col` : Column holding name of reef the site is associated with (non-unique)
- `unique_site_id_col` : Column holding unique site names/ids
- `init_coral_fn` : Name of file holding initial coral cover values
- `conn_path` : Path to directory holding connectivity data
- `dhw_fn` : Filename of DHW data cube in use
- `wave_fn` : Filename of wave data cube
"""
function Domain(name::String, dpkg_path::String, rcp::String, timeframe::Vector, site_data_fn::String, site_id_col::String, unique_site_id_col::String, init_coral_fn::String,
    conn_path::String, dhw_fn::String, wave_fn::String)::Domain

    env_layer_md::EnvLayer = EnvLayer(dpkg_path, site_data_fn, site_id_col, unique_site_id_col, init_coral_fn, conn_path, dhw_fn, wave_fn, timeframe)

    local site_data::DataFrame
    try
        site_data = GeoDataFrames.read(site_data_fn)
    catch err
        if !isfile(site_data_fn)
            error("Provided site data path is not valid or missing: $(site_data_fn).")
        else
            rethrow(err)
        end
    end

    # Sort data to maintain consistent order
    sort!(site_data, Symbol[Symbol(unique_site_id_col)])

    u_sids::Vector{String} = site_data[!, unique_site_id_col]

    # If site id column is missing then derive it from the Unique IDs
    if !in(site_id_col, names(site_data))
        site_data[!, site_id_col] .= String[d[2] for d in split.(u_sids, "_"; limit=2)]
    end

    site_data.row_id = 1:nrow(site_data)

    conn_ids::Vector{String} = site_data[:, site_id_col]
    site_conn::NamedTuple = site_connectivity(conn_path, u_sids)
    conns::NamedTuple = connectivity_strength(site_conn.TP_base)

    # Filter out missing entries
    site_data = site_data[coalesce.(in.(conn_ids, [site_conn.site_ids]), false), :]
    site_dists::Matrix{Float64}, median_site_distance::Float64 = site_distances(site_data)

    coral_growth::CoralGrowth = CoralGrowth(nrow(site_data))
    n_sites::Int64 = coral_growth.n_sites

    # TODO: Clean these repetitive lines up
    if endswith(dhw_fn, ".mat")
        dhw::NamedArray{Float32} = load_mat_data(dhw_fn, "dhw", site_data)
    elseif endswith(dhw_fn, ".nc")
        dhw = load_env_data(dhw_fn, "dhw", site_data)
    else
        dhw = NamedArray(zeros(Float32, length(timeframe), n_sites, 50))
    end

    if endswith(wave_fn, ".mat")
        waves::NamedArray{Float32} = load_mat_data(wave_fn, "wave", site_data)
    elseif endswith(wave_fn, ".nc")
        waves = load_env_data(wave_fn, "Ub", site_data)
    else
        waves = NamedArray(zeros(Float32, length(timeframe), n_sites, 50))
    end

    if endswith(init_coral_fn, ".mat")
        coral_cover::NamedArray{Float32} = load_mat_data(init_coral_fn, "covers", site_data)
    elseif endswith(init_coral_fn, ".nc")
        coral_cover = load_covers(init_coral_fn, "covers", site_data)
    else
        @warn "Using random initial coral cover"
        coral_cover = NamedArray(rand(Float32, coral_growth.n_species, n_sites))
    end

    msg::String = "Provided time frame must match timesteps in DHW and wave data"
    msg = msg * "\n Got: $(length(timeframe)) | $(size(dhw, 1)) | $(size(waves, 1))"

    @assert length(timeframe) == size(dhw, 1) == size(waves, 1) msg

    return Domain(name, rcp, env_layer_md, site_conn.TP_base, conns.in_conn, conns.out_conn, conns.strongest_predecessor,
        site_data, site_dists, median_site_distance, site_id_col, unique_site_id_col, coral_cover, coral_growth,
        site_conn.site_ids, site_conn.truncated, dhw, waves)
end

"""
    load_domain(path::String, rcp::Int64)
    load_domain(path::String, rcp::String)
    load_domain(path::String)

Load domain specification from data package.

# Arguments
- `path` : location of data package
- `rcp` : RCP scenario to run. If none provided, no data path is set.
"""
function load_domain(path::String, rcp::String)::Domain
    domain_name::String = basename(path)
    if length(domain_name) == 0
        domain_name = basename(dirname(path))
    end

    dpkg_details::Dict{String,Any} = _load_dpkg(path)
    dpkg_version = dpkg_details["version"]

    # Handle compatibility
    this_version = parse(VersionNumber, dpkg_version)
    if this_version >= v"0.2.1"
        # Extract the time frame represented in this data package
        timeframe = dpkg_details["simulation_metadata"]["timeframe"]
    else
        # Default to 2025-2099
        timeframe = (2025, 2099)
    end

    if length(timeframe) == 2
        @assert timeframe[1] < timeframe[2] "Start date/year specified in data package must be < end date/year"
        # If only two elements, assume a range is specified.
        # Collate the time steps as a full list if necessary
        timeframe = collect(timeframe[1]:timeframe[2])
    end

    conn_path::String = joinpath(path, "connectivity/")
    site_data::String = joinpath(path, "site_data")

    site_path::String = joinpath(site_data, "$(domain_name).gpkg")
    init_coral_cov::String = joinpath(site_data, "coral_cover.nc")

    if !isempty(rcp)
        dhw::String = joinpath(path, "DHWs", "dhwRCP$(rcp).nc")
        wave::String = joinpath(path, "waves", "wave_RCP$(rcp).nc")
    else
        dhw = ""
        wave = ""
    end

    return Domain(
        domain_name,
        path,
        rcp,
        timeframe,
        site_path,
        "reef_siteid",
        "reef_siteid",
        init_coral_cov,
        conn_path,
        dhw,
        wave
    )
end
function load_domain(path::String, rcp::Int64)::Domain
    return load_domain(path, "$rcp")
end
function load_domain(path::String)::Domain
    return load_domain(path, "")
end


function unique_sites(d::Domain)::Vector{String}
    return d.site_data[:, d.unique_site_id_col]
end


"""
    param_table(d::Domain)::DataFrame

Get model fieldnames and their parameter values.
"""
function param_table(d::Domain)::DataFrame
    f_names::Vector{String} = collect(string.(d.model[:fieldname]))
    vals::Vector{<:Real} = collect(d.model[:val])
    p_df::DataFrame = DataFrame(OrderedDict(k => v for (k, v) in zip(f_names, vals)))

    p_df[!, :RCP] .= d.RCP  # Add entry to indicate which RCP scenario was used

    return p_df
end


"""
    model_spec(d::Domain)::DataFrame
    model_spec(d::Domain, filepath::String)::Nothing

Get model specification as DataFrame with lower and upper bounds.
If a filepath is provided, writes the specification out to file with ADRIA metadata.
"""
function model_spec(d::Domain)::DataFrame
    return model_spec(d.model)
end
function model_spec(d::Domain, filepath::String)::Nothing
    version = PkgVersion.Version(@__MODULE__)
    vers_id = "v$(version)"

    open(filepath, "w") do io
        write(io, "# Generated with ADRIA.jl $(vers_id) on $(replace(string(now()), "T"=>"_", ":"=>"_", "."=>"_"))\n")
    end

    model_spec(d) |> CSV.write(filepath, writeheader=true, append=true)

    return
end
function model_spec(m::Model)
    spec = DataFrame(m)
    bnds = spec[!, :bounds]
    spec[!, :full_bounds] = bnds
    spec[!, :lower_bound] = first.(bnds)
    spec[!, :upper_bound] = getindex.(bnds, 2)
    spec[!, :component] = replace.(string.(spec[:, :component]), "ADRIA." => "")
    spec[!, :is_constant] = spec[:, :lower_bound] .== spec[:, :upper_bound]

    select!(spec, Not(:bounds))

    # Reorder so name/description appears at end
    # makes viewing as CSV a little nicer given description can be very long
    select!(spec, Not([:name, :description]), [:name, :description])

    return spec
end


"""
    update_params!(d::Domain, params::DataFrameRow)

Update given domain with new parameter values.
Maps sampled continuous values to discrete values for categorical variables.
"""
function update_params!(d::Domain, params::Union{AbstractVector,DataFrameRow})::Nothing
    p_df::DataFrame = DataFrame(d.model)[!, [:fieldname, :val, :ptype, :bounds]]

    try
        p_df[!, :val] .= collect(params[Not("RCP")])
    catch err
        if isa(err, ArgumentError)
            if !occursin("RCP", "$err")
                error("Error occurred loading scenario samples. $err")
            else
                p_df[!, :val] .= collect(params)
            end
        end
    end

    to_floor = (p_df.ptype .== "integer")
    if any(to_floor)
        p_df[to_floor, :val] .= map_to_discrete.(p_df[to_floor, :val], getindex.(p_df[to_floor, :bounds], 2))
    end

    # Update with new parameters
    update!(d.model, p_df)

    return nothing
end


"""
    component_params(m::Model, component::Type)::DataFrame
    component_params(spec::DataFrame, component::Type)::DataFrame
    component_params(m::Model, components::Vector)::DataFrame
    component_params(spec::DataFrame, components::Vector)::DataFrame

Extract parameters for a specific model component.
"""
function component_params(m::Model, component::Type)::DataFrame
    return component_params(model_spec(m), component)
end
function component_params(spec::DataFrame, component::Type)::DataFrame
    return spec[spec.component.==replace.(string(component), "ADRIA." => ""), :]
end
function component_params(m::Model, components::Vector)::DataFrame
    return component_params(model_spec(m), components)
end
function component_params(spec::DataFrame, components::Vector)::DataFrame
    return spec[spec.component.∈[replace.(string.(components), "ADRIA." => "")], :]
end

"""
    site_selection(domain::Domain, criteria::DataFrame, area_to_seed::Float64, ts::Int, n_reps::Int, alg_ind::Int)

# Arguments
- domain : ADRIA Domain type, indicating geographical domain to perform site selection over.
- criteria : DataFrame of criteria weightings and thresholds (can be a scenario DataFrame).
- area_to_seed : area of coral to be seeded at each time step in km^2
- ts : time step at which seeding and/or shading is being undertaken.
- n_reps : number of dhw/wave replicates to use in site selection.
- scen_ind : scenario id for criteria (if using a scenario DataFrame, otherwise use scen_id = 1).
- alg_ind : MCDA algorithm to use in site selection.

# Returns
- Matrix : n_reps * sites * 3 (last dimension indicates: site_id, seeding rank, shading rank)
"""
function site_selection(domain::Domain, criteria::DataFrame, area_to_seed::Float64, ts::Int, n_reps::Int, alg_ind::Int64)
    # Site Data
    site_d = domain.site_data
    sr = domain.in_conn
    so = domain.out_conn
    area = site_area(domain)

    # Weights for connectivity , waves (ww), high cover (whc) and low
    wtwaves = criteria.wave_stress[scen_ind]           # weight of wave damage in MCDA
    wtheat = criteria.heat_stress[scen_ind]            # weight of heat damage in MCDA
    wtconshade = criteria.shade_connectivity[scen_ind] # weight of connectivity for shading in MCDA
    wtinconnseed = criteria.in_seed_connectivity[scen_ind]   # weight of connectivity for seeding in MCDA
    wtoutconnseed = criteria.out_seed_connectivity[scen_ind]   # weight of connectivity for seeding in MCDA
    wthicover = criteria.coral_cover_high[scen_ind]    # weight of high coral cover in MCDA (high cover gives preference for seeding corals but high for SRM)
    wtlocover = criteria.coral_cover_low[scen_ind]     # weight of low coral cover in MCDA (low cover gives preference for seeding corals but high for SRM)
    wtpredecseed = criteria.seed_priority[scen_ind]    # weight for the importance of seeding sites that are predecessors of priority reefs
    wtpredecshade = criteria.shade_priority[scen_ind]  # weight for the importance of shading sites that are predecessors of priority reefs
    wtzonesseed = criteria.zone_seed[scen_ind]    # weight for the importance of seeding sites that are predecessors of priority reefs
    wtzonesshade = criteria.zone_shade[scen_ind]  # weight for the importance of shading sites that are predecessors of priority reefs

    depth_min = criteria.depth_min[scen_ind]
    depth_offset = criteria.depth_offset[scen_ind]

    # Filter out sites outside of desired depth range
    max_depth = depth_min + depth_offset
    depth_criteria = (site_d.depth_med .<= max_depth) .& (site_d.depth_med .>= depth_min)

    depth_priority = collect(1:size(site_d, 1))[depth_criteria]

    max_cover = site_d.k / 100.0  # Max coral cover at each site

    n_siteint = domain.sim_constants.nsiteint
    w_scens = domain.wave_scens
    dhw_scen = domain.dhw_scens

    sumcover = sum(domain.init_coral_cover, dims=2)
    sumcover = sumcover / 100.0

    ranks = zeros(n_reps, length(depth_priority), 3)

    for i = 1:n_reps
        # site_id, seeding rank, shading rank
        rankingsin = [depth_priority zeros(Int64, (length(depth_priority), 1)) zeros(Int64, (length(depth_priority), 1))]
        prefseedsites = zeros(Int64, (1, n_siteint))
        prefshadesites = zeros(Int64, (1, n_siteint))
        dhw_step = dhw_scen[ts, :, i]
        heatstressprob = dhw_step

        # create DMCA structure
        w_step = w_scens[ts, :, i]
        damprob = w_step

        mcda_vars = DMCDA_vars(
            depth_priority,
            n_siteint,
            domain.sim_constants.prioritysites,
            domain.sim_constants.priorityzones,
            site_d.zone_type,
            domain.strongpred,
            sr,
            so,
            damprob,
            heatstressprob,
            site_d.depth_med,
            sumcover,
            max_cover,
            area,
            area_to_seed * criteria.coral_cover_tol[scen_ind],
            criteria.deployed_coral_risk_tol[scen_ind],
            domain.site_distances,
            criteria.dist_thresh[scen_ind],
            criteria.top_n[scen_ind],
            wtinconnseed,
            wtoutconnseed,
            wtconshade,
            wtwaves,
            wtheat,
            wthicover,
            wtlocover,
            wtpredecseed,
            wtpredecshade,
            wtzonesseed,
            wtzonesshade
        )

        (_, _, rankings) = guided_site_selection(mcda_vars, alg_ind, true, true, prefseedsites, prefshadesites, rankingsin)
        ranks[i, :, :] = rankings
    end

    return ranks
end


"""
    site_area(domain::Domain)::Vector{Float64}
Get site area for the given domain.
"""
function site_area(domain::Domain)::Vector{Float64}
    return domain.site_data.area
end

"""
    site_k_area(domain::Domain)::Vector{Float64}
Get maximum coral cover area for the given domain in absolute area.
"""
function site_k_area(domain::Domain)::Vector{Float64}
    return site_k(domain) .* site_area(domain)
end

"""
    relative_leftover_space(domain::Domain)::Vector{Float64}
    relative_leftover_space(site_k::Matrix{Float64}, site_coral_cover::Matrix{Float64})::Matrix{Float64}

Get proportion of leftover space, given site_k and proportional cover on each site, summed over species.
"""
function relative_leftover_space(domain::Domain, site_coral_cover::Matrix{Float64})::Matrix{Float64}
    return relative_leftover_space(site_k(domain)', site_coral_cover)
end
function relative_leftover_space(site_k::AbstractArray{Float64,2}, site_coral_cover::Matrix{Float64})::Matrix{Float64}
    return max.(site_k .- site_coral_cover, 0.0)
end


"""
    site_k(domain::Domain)::Vector{Float64}

Get maximum coral cover area as a proportion of site area.
"""
function site_k(domain::Domain)::Vector{Float64}
    return domain.site_data.k ./ 100.0
end

"""Extract the time steps represented in the data package."""
function timesteps(domain::Domain)
    return domain.env_layer_md.timeframe
end

"""Get the path to the DHW data associated with the domain."""
function get_DHW_data(d::Domain, RCP::String)::String
    return joinpath(d.env_layer_md.dpkg_path, "DHWs", "dhwRCP$(RCP).nc")
end

"""Get the path to the wave data associated with the domain."""
function get_wave_data(d::Domain, RCP::String)::String
    return joinpath(d.env_layer_md.dpkg_path, "waves", "wave_RCP$(RCP).nc")
end

"""
    switch_RCPs!(d::Domain, RCP::String)::Domain

Switch environmental datasets to represent the given RCP.
"""
function switch_RCPs!(d::Domain, RCP::String)::Domain
    @set! d.env_layer_md.DHW_fn = get_DHW_data(d, RCP)
    @set! d.env_layer_md.wave_fn = get_wave_data(d, RCP)
    @set! d.RCP = RCP

    @set! d.dhw_scens = load_env_data(d.env_layer_md.DHW_fn, "dhw", d.site_data)
    @set! d.wave_scens = load_env_data(d.env_layer_md.wave_fn, "Ub", d.site_data)

    return d
end


function Base.show(io::IO, mime::MIME"text/plain", d::Domain)

    df = model_spec(d)
    println("""
    Domain: $(d.name)

    Number of sites: $(nrow(d.site_data))
    Site data file: $(d.env_layer_md.site_data_fn)
    Connectivity file: $(d.env_layer_md.connectivity_fn)
    DHW file: $(d.env_layer_md.DHW_fn)
    Wave file: $(d.env_layer_md.wave_fn)
    Timeframe: $(d.env_layer_md.timeframe[1]) - $(d.env_layer_md.timeframe[end])

    Model Specification:
    - Parameters: $(nrow(df))
    - Number of constants: $(nrow(df[df.is_constant .== true, :]))
    """)

    # println("\nEcosystem model specification:")
    # show(io, mime, model_spec(d)[:, [:component, :fieldname, :val, :full_bounds, :dists, :is_constant]])
end
