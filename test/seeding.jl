using ADRIA
using ADRIA: distribute_seeded_corals, site_k
using Test
using Distributions
using NamedDims

@testset "Seeding distribution" begin
    # first test function on example domain
    dom = ADRIA.load_domain(joinpath(@__DIR__, "..", "examples", "Example_domain"), 45)

    # extract inputs for function
    total_site_area = site_area(dom)
    k = site_k(dom)
    current_cover = zeros(size(total_site_area))

    # calculate available space
    available_space = vec((total_site_area .* k) .- current_cover)

    @testset "Test for Seeding Distribtion ($i)" for i in 1:10
        prefseedsites = rand(1:length(total_site_area), 5)

        # Randomly generate seeded area
        seeded_area = NamedDimsArray(rand(Uniform(0.0, 500.0), 3), taxa=["N_seed_TA", "N_seed_CA", "N_seed_SM"])

        # evaluate seeding distributions
        seed_dist = distribute_seeded_corals(total_site_area, prefseedsites, available_space, seeded_area)

        # Area to be seeded for each site
        total_area_seed = seed_dist'.* total_site_area[prefseedsites]

        # total area of seeded corals
        total_area_coral_out = sum(total_area_seed, dims=1)(1)

        # absolute available area to seed for selected sites
        selected_avail_space = available_space[prefseedsites]

        abs_seed_area = seed_dist("N_seed_TA") .* total_site_area[prefseedsites]

        # index of max proportion for available space
        max_ind_out = findfirst(abs_seed_area .== maximum(abs_seed_area))
        max_ind = findfirst(selected_avail_space .== maximum(selected_avail_space))

        # index of min proportion for available space
        min_ind_out = findfirst(abs_seed_area .== minimum(abs_seed_area))
        min_ind = findfirst(selected_avail_space .== minimum(selected_avail_space))

        @test (abs(seeded_area("N_seed_TA") - total_area_coral_out("N_seed_TA")) < 10^-5) && (abs(seeded_area("N_seed_CA") - total_area_coral_out("N_seed_CA")) < 10^-5) && (abs(seeded_area("N_seed_SM") - total_area_coral_out("N_seed_SM")) < 10^-5) || "Area of corals seeded not equal to (colony area) * (number or corals)"
        @test all((seed_dist("N_seed_TA") .< 1) .&& (seed_dist("N_seed_CA") .< 1) .&& (seed_dist("N_seed_SM") .< 1)) || "Some proportions of seeded corals greater than 1"
        @test all((seed_dist("N_seed_TA") .>= 0) .&& (seed_dist("N_seed_CA") .>= 0) .&& (seed_dist("N_seed_SM") .>= 0)) || "Some proportions of seeded corals less than zero"
        @test all((seeded_area("N_seed_TA") .<= selected_avail_space) .&& (seeded_area("N_seed_CA") .<= selected_avail_space) .&& (seeded_area("N_seed_SM") .<= selected_avail_space)) || "Area seeded greater than available area"
        @test (max_ind_out == max_ind) || "Maximum distributed proportion of seeded coral not seeded in largest available area."
        @test (min_ind_out == min_ind) || "Minimum distributed proportion of seeded coral not seeded in smallest available area."
    end
end
