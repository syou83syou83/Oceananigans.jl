using Oceananigans
using Oceananigans.Grids

using Oceananigans.Coriolis:
    HydrostaticSphericalCoriolis,
    VectorInvariantEnergyConserving,
    VectorInvariantEnstrophyConserving

using Oceananigans.Models.HydrostaticFreeSurfaceModels:
    HydrostaticFreeSurfaceModel,
    VectorInvariant,
    ExplicitFreeSurface

using Oceananigans.Utils: prettytime, hours
using Oceananigans.OutputWriters: JLD2OutputWriter, TimeInterval, IterationInterval

using Oceananigans.MultiRegion

using Statistics
using JLD2
using Printf

const U = 0.1

solid_body_rotation(φ) = U * cosd(φ)
solid_body_geostrophic_height(φ, R, Ω, g) = (R * Ω * U + U^2 / 2) * sind(φ)^2 / g

# In addition to the solid body rotation solution, we paint a Gaussian tracer patch
# on the spherical strip to visualize the rotation.

function run_solid_body_rotation(; architecture = CPU(),
                                   Nx = 90,
                                   Ny = 30,
                                   dev = nothing, 
                                   coriolis_scheme = VectorInvariantEnstrophyConserving())

    # A spherical domain
    grid = LatitudeLongitudeGrid(architecture, size = (Nx, Ny, 1),
                                 radius = 1,
                                 latitude = (-80, 80),
                                 longitude = (-180, 180),
                                 z = (-1, 0))

    if dev isa Nothing
        mrg = grid
    else
        mrg = MultiRegionGrid(grid, partition = XPartition(length(dev)), devices = dev)
    end

    @show mrg

    free_surface = ExplicitFreeSurface(gravitational_acceleration = 1)

    coriolis = HydrostaticSphericalCoriolis(rotation_rate = 1,
                                            scheme = coriolis_scheme)

    model = HydrostaticFreeSurfaceModel(grid = mrg,
                                        momentum_advection = VectorInvariant(),
                                        free_surface = free_surface,
                                        coriolis = coriolis,
                                        tracers = :c,
                                        tracer_advection = WENO5(),
                                        buoyancy = nothing,
                                        closure = nothing)

    g = model.free_surface.gravitational_acceleration
    R = grid.radius
    Ω = model.coriolis.rotation_rate

    uᵢ(λ, φ, z) = solid_body_rotation(φ)
    ηᵢ(λ, φ)    = solid_body_geostrophic_height(φ, R, Ω, g)

    # Tracer patch for visualization
    Gaussian(λ, φ, L) = exp(-(λ^2 + φ^2) / 2L^2)

    # Tracer patch parameters
    L = 10 # degree
    φ₀ = 5 # degrees

    cᵢ(λ, φ, z) = Gaussian(λ, φ - φ₀, L)

    set!(model, u=uᵢ, η=ηᵢ, c=cᵢ)

    gravity_wave_speed = sqrt(g * grid.Lz) # hydrostatic (shallow water) gravity wave speed

    # Time-scale for gravity wave propagation across the smallest grid cell
    wave_propagation_time_scale = min(grid.radius * cosd(maximum(abs, grid.φᵃᶜᵃ)) * deg2rad(grid.Δλᶜᵃᵃ),
                                      grid.radius * deg2rad(grid.Δφᵃᶜᵃ)) / gravity_wave_speed

    Δt = 0.1wave_propagation_time_scale

    simulation = Simulation(model,
                            Δt = Δt,
                            stop_iteration = 10)

                            # stop_time = super_rotations * super_rotation_period)

    progress(sim) = @info(@sprintf("Iter: %d, time: %.1f, Δt: %.3f", #, max|c|: %.2f",
                                   sim.model.clock.iteration, sim.model.clock.time,
                                   sim.Δt)) #, maximum(abs, sim.model.tracers.c)))

    simulation.callbacks[:progress] = Callback(progress, IterationInterval(500))

    run!(simulation)

    @show simulation.run_wall_time
    return simulation
end

using BenchmarkTools

simulation_serial = run_solid_body_rotation(Nx=256,  Ny=256, architecture=GPU())
simulation_parall = run_solid_body_rotation(Nx=512,  Ny=512, dev = (0, 1), architecture=GPU())

using BenchmarkTools

time_step!(simulation_serial.model, 1)
trial_serial = @benchmark begin
    CUDA.@sync time_step!(simulation_serial.model, 1)
end samples = 10

time_step!(simulation_parall.model, 1)
trial_parall = @benchmark begin
    CUDA.@sync time_step!(simulation_parall.model, 1)
end samples = 10