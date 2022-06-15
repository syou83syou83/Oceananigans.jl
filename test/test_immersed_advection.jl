include("dependencies_for_runtests.jl")

using Oceananigans.ImmersedBoundaries: ImmersedBoundaryGrid, GridFittedBoundary, mask_immersed_field!
using Oceananigans.Advection: 
        _left_biased_interpolate_xᶜᵃᵃ, 
        _left_biased_interpolate_xᶠᵃᵃ, 
        _right_biased_interpolate_xᶜᵃᵃ,
        _right_biased_interpolate_xᶠᵃᵃ,
        _left_biased_interpolate_yᵃᶜᵃ, 
        _left_biased_interpolate_yᵃᶠᵃ, 
        _right_biased_interpolate_yᵃᶜᵃ,
        _right_biased_interpolate_yᵃᶠᵃ

@testset "Immersed tracer advection" begin
    @info "Running immersed advection tests..."
    for arch in archs
        advection_schemes = [UpwindBiasedFirstOrder(),
                             UpwindBiasedThirdOrder(),
                             UpwindBiasedFifthOrder(), 
                             WENO3(),
                             WENO5()]

        for adv in advection_schemes
            @testset " Test immersed tracer reconstruction [$(typeof(arch)), $(typeof(adv))]" begin
                @info "Testing immersed tracer reconstruction [$(typeof(arch)), $(typeof(adv))]"
                
                grid = RectilinearGrid(size=(10, 10), extent=(10, 10), topology=(Bounded, Bounded, Flat))
                ibg  = ImmersedBoundaryGrid(grid, GridFittedBoundary((x, y, z) -> (x < 5 || y < 5)))

                c = CenterField(ibg)
                set!(c, 1.0)
                
                wait(mask_immersed_field!(c))

                fill_halo_regions!(c)
                for i in 6:9, j in 6:9
                    @test CUDA.@allowscalar  _left_biased_interpolate_xᶠᵃᵃ(i+1, j, 1, ibg, adv, c) ≈ 1.0
                    @test CUDA.@allowscalar _right_biased_interpolate_xᶠᵃᵃ(i+1, j, 1, ibg, adv, c) ≈ 1.0
                    @test CUDA.@allowscalar  _left_biased_interpolate_yᵃᶠᵃ(i, j+1, 1, ibg, adv, c) ≈ 1.0
                    @test CUDA.@allowscalar _right_biased_interpolate_yᵃᶠᵃ(i, j+1, 1, ibg, adv, c) ≈ 1.0
                end

            end

            grid = RectilinearGrid(size=(10, 8, 1), extent=(10, 8, 1), halo = (4, 4, 4), topology=(Bounded, Periodic, Bounded))
            ibg  = ImmersedBoundaryGrid(grid, GridFittedBoundary((x, y, z) -> (x < 2)))
            for g in [grid, ibg]
                @testset " Test immersed tracer conservation [$(typeof(arch)), $(typeof(adv)), $(typeof(g).name.wrapper)]" begin
                    @info "Testing immersed tracer conservation [$(typeof(arch)), $(typeof(adv)), $(typeof(g).name.wrapper)]"

                    model = HydrostaticFreeSurfaceModel(grid = g, tracers = :c, 
                                                        free_surface = ExplicitFreeSurface(),
                                                        tracer_advection = adv, 
                                                        buoyancy = nothing,
                                                        coriolis = nothing)

                    c = model.tracers.c
                    set!(model, c = 1.0)
                    fill_halo_regions!(c)

                    η = model.free_surface.η

                    indices = model.grid == ibg ? (5:7, 3:6, 1) : (2:5, 3:6, 1)

                    interior(η, indices...) .= - 0.05
                    fill_halo_regions!(η)

                    wave_speed = sqrt(model.free_surface.gravitational_acceleration)
                    dt = 0.1 / wave_speed
                    for i in 1:10
                        time_step!(model, dt)
                    end

                    @test maximum(c) ≈ 1.0 
                    @test minimum(c) ≈ 1.0 
                    @test mean(c)    ≈ 1.0
                end
            end
        end
    end
end

using Oceananigans.Advection: VelocityStencil, VorticityStencil, WENOVectorInvariant

@testset "Immersed momentum advection" begin
    @info "Running immersed advection tests..."
    for arch in archs
        advection_schemes = [UpwindBiasedFirstOrder(),
                             UpwindBiasedThirdOrder(),
                             UpwindBiasedFifthOrder(), 
                             WENO3(),
                             WENO5()]

        for adv in advection_schemes
            @testset " Test immersed momentum reconstruction [$(typeof(arch)), $(typeof(adv))]" begin
                @info "Testing immersed momentum reconstruction [$(typeof(arch)), $(typeof(adv))]"
                
                grid = RectilinearGrid(size=(10, 10), extent=(10, 10), topology=(Bounded, Bounded, Flat))
                ibg  = ImmersedBoundaryGrid(grid, GridFittedBoundary((x, y, z) -> (x < 5 || y < 5)))

                u = XFaceField(ibg)
                v = XFaceField(ibg)
                set!(u, 1.0)
                set!(v, 1.0)
                
                wait(mask_immersed_field!(u))
                wait(mask_immersed_field!(v))

                fill_halo_regions!(u)
                fill_halo_regions!(v)

                for i in 7:9, j in 7:9
                    @test CUDA.@allowscalar  _left_biased_interpolate_xᶜᵃᵃ(i+1, j, 1, ibg, adv, u) ≈ 1.0
                    @test CUDA.@allowscalar _right_biased_interpolate_xᶜᵃᵃ(i+1, j, 1, ibg, adv, u) ≈ 1.0
                    @test CUDA.@allowscalar  _left_biased_interpolate_yᵃᶜᵃ(i, j+1, 1, ibg, adv, u) ≈ 1.0
                    @test CUDA.@allowscalar _right_biased_interpolate_yᵃᶜᵃ(i, j+1, 1, ibg, adv, u) ≈ 1.0

                    @test CUDA.@allowscalar  _left_biased_interpolate_xᶜᵃᵃ(i+1, j, 1, ibg, adv, v) ≈ 1.0
                    @test CUDA.@allowscalar _right_biased_interpolate_xᶜᵃᵃ(i+1, j, 1, ibg, adv, v) ≈ 1.0
                    @test CUDA.@allowscalar  _left_biased_interpolate_yᵃᶜᵃ(i, j+1, 1, ibg, adv, v) ≈ 1.0
                    @test CUDA.@allowscalar _right_biased_interpolate_yᵃᶜᵃ(i, j+1, 1, ibg, adv, v) ≈ 1.0
                end
            end
        end
    end
end

