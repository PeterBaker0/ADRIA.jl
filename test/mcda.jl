using Test
using Distributions
import ADRIA: mcda_normalize, create_decision_matrix, create_seed_matrix, create_shade_matrix

@testset "Create decision matrix" begin

    # Dummy data to create decision matrix from
    n_sites = 5
    area = [1000.0, 800.0, 600.0, 200.0, 200.0]
    centr_out = [1.0, 0.5, 0.5, 0.5, 0.5]
    centr_in = [0.1, 0.0, 0.3, 0.1, 0.1]
    damprob = [0.05, 0.1, 0.1, 0.5, 0.0]
    heatstressprob = [0.05, 0.1, 0.1, 0.5, 0.0]
    zones_criteria = [1.0, 1.33, 0.333, 1.0, 0.333]

    # Dummy priority predecessors
    prioritysites = zeros(n_sites)
    predec = zeros(n_sites, 3)
    predec[:, 1:2] .= rand(n_sites, 2)
    predprior = predec[in.(predec[:, 1], [prioritysites']), 2]
    predprior = [x for x in predprior if !isnan(x)]
    predec[predprior, 3] .= 1.0
    risktol = 0.8

    sumcover = [0.3, 0.5, 0.9, 0.6, 0.0]
    maxcover = [0.8, 0.75, 0.95, 0.7, 0.0]

    A, filtered = create_decision_matrix(1:n_sites, centr_in, centr_out, sumcover, maxcover, area, damprob, heatstressprob, predec, zones_criteria, risktol)

    @test all(0.0 .<= A[:, 2:end-2] .<= 1.0) || "`A` decision matrix out of bounds"

    @test !any(isnan.(A)) || "NaNs found in decision matrix"
    @test !any(isinf.(A)) || "Infs found in decision matrix"

    @test A[end, 6] == 0.0 || "Site with 0 max cover should be ignored but was not"
end


@testset "MCDA seed matrix creation" begin
    wtconseedout, wtconseedin, wtwaves, wtheat, wtpredecseed, wtzonesseed, wtlocover = [1.0, 1.0, 0.7, 1.0, 0.6, 0.6, 0.6]

    # Combine decision criteria into decision matrix A
    n_sites = 5
    area = [1000.0, 800.0, 600.0, 200.0, 200.0]
    centr_out = [1.0, 0.5, 0.5, 0.5, 0.5]
    centr_in = [0.1, 0.0, 0.3, 0.1, 0.1]
    damprob = [0.05, 0.1, 0.1, 0.5, 0.0]
    heatstressprob = [0.05, 0.1, 0.1, 0.5, 0.0]
    zones_criteria = [1.0, 1.33, 0.333, 1.0, 0.333]

    # Dummy priority predecssors
    prioritysites = zeros(n_sites)
    predec = zeros(n_sites, 3)
    predec[:, 1:2] .= rand(n_sites, 2)
    predprior = predec[in.(predec[:, 1], [prioritysites']), 2]
    predprior = [x for x in predprior if !isnan(x)]
    predec[predprior, 3] .= 1.0

    sumcover = [0.3, 0.5, 0.9, 0.6, 0.0]
    maxcover = [0.8, 0.75, 0.6, 0.77, 0.0]
    min_area = 20

    A, filtered = create_decision_matrix(1:n_sites, centr_in, centr_out, sumcover, maxcover, area, damprob, heatstressprob, predec, zones_criteria, 0.8)

    SE, wse = create_seed_matrix(A, min_area, wtconseedin, wtconseedout, wtwaves, wtheat, wtpredecseed, wtzonesseed, wtlocover)

    @test (sum(filtered)) == size(A, 1) || "Site where heat stress > risktol not filtered out"
    @test size(SE, 1) == size(A, 1) - 2 || "Sites where space available<min_area not filtered out"
    @test A[3, 8] == 0.0 || "Site with k<coral cover should be set to space = 0"

    @test all(0.0 .<= SE[:, 2:end-2] .<= 1.0) || "Seeding Decision matrix values out of bounds"
end

@testset "MCDA shade matrix creation" begin
    wtconshade, wtwaves, wtheat, wtpredecshade, wtzonesshade, wthicover = [1.0, 0.7, 1.0, 0.6, 0.6, 0.6]

    # Combine decision criteria into decision matrix A
    n_sites = 5
    area = [1000.0, 800.0, 600.0, 200.0, 200.0]
    centr_out = [1.0, 0.5, 0.5, 0.5, 0.5]
    centr_in = [0.1, 0.0, 0.3, 0.1, 0.1]
    damprob = [0.05, 0.1, 0.1, 0.5, 0.0]
    heatstressprob = [0.05, 0.1, 0.1, 0.5, 0.0]
    zones_criteria = [1.0, 1.33, 0.333, 1.0, 0.333]

    # Dummy priority predecssors
    prioritysites = zeros(n_sites)
    predec = zeros(n_sites, 3)
    predec[:, 1:2] .= rand(n_sites, 2)
    predprior = predec[in.(predec[:, 1], [prioritysites']), 2]
    predprior = [x for x in predprior if !isnan(x)]
    predec[predprior, 3] .= 1.0

    sumcover = [0.75, 0.5, 0.3, 0.7, 0.0]
    maxcover = [0.8, 0.75, 0.6, 0.77, 0.0]
    area_maxcover = maxcover .* area

    A, filtered = create_decision_matrix(1:n_sites, centr_in, centr_out, sumcover, maxcover, area, damprob, heatstressprob, predec, zones_criteria, 0.8)

    SH, wsh = create_shade_matrix(A, area_maxcover[filtered], wtconshade, wtwaves, wtheat, wtpredecshade, wtzonesshade, wthicover)

    @test maximum(SH[:, 8]) == (maximum(area_maxcover[convert(Vector{Int64}, A[:, 1])] .- A[:, 8])) || "Largest site with most coral area should have highest score"

    @test all(0.0 .<= SH[:, 2:end-2] .<= 1.0) || "Shading Decision matrix values out of bounds"
end

@testset "MCDA normalisation" begin
    # randomised weights
    w = vec(rand(Uniform(0, 1), 7))

    # randomised decision matrix
    A = zeros(5, 7)
    A[:, 1] = [1.0, 2.0, 3.0, 4.0, 5.0]
    A[:, 2:6] = rand(Uniform(0, 1), (5, 5))
    A[:, 7] = rand(Uniform(100, 1000), (5, 1))

    norm_A = mcda_normalize(A[:, 2:end])
    norm_w = mcda_normalize(w)

    @test all((sqrt.(sum(norm_A .^ 2, dims=1)) .- 1.0) .< 0.0001) || "Decision matrix normalization not giving column sums = 1."
    @test (sum(norm_w) - 1.0) <= 0.001 || "MCDA weights not summing to one."
end