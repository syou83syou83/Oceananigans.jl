using Oceananigans.MultiRegion

# Tracer patch for visualization
Gaussian(x, y, L) = exp(-(x^2 + y^2) / 2L^2)

prescribed_velocities() = PrescribedVelocityFields(u=(λ, ϕ, z, t=0) -> 0.1 * cosd(ϕ))

function Δ_min(grid) 
    ϕᵃᶜᵃ_max = maximum(abs, ynodes(Center, grid))
    Δx_min = grid.radius * cosd(ϕᵃᶜᵃ_max) * deg2rad(grid.Δλᶜᵃᵃ)
    Δy_min = grid.radius * deg2rad(grid.Δφᵃᶜᵃ)
    return min(Δx_min, Δy_min)
end

function Δ_min(grid::RectilinearGrid) 
    Δx_min = min_Δx(grid)
    Δy_min = min_Δy(grid)
    return min(Δx_min, Δy_min)
end

function solid_body_tracer_advection_test(grid; regions = 1)

    mrg = MultiRegionGrid(grid, partition = XPartition(regions))

    if grid isa RectilinearGrid
        L = 0.1
    else
        L = 24 
    end

    model = HydrostaticFreeSurfaceModel(grid = mrg,
                                        tracers = (:c, :d, :e),
                                        velocities = prescribed_velocities(),
                                        free_surface = ExplicitFreeSurface(),
                                        momentum_advection = nothing,
                                        tracer_advection = WENO5(grid = grid),
                                        coriolis = nothing,
                                        buoyancy = nothing,
                                        closure  = nothing)

    # Tracer patch for visualization
    Gaussian(x, y, L) = exp(-(x^2 + y^2) / 2L^2)

    # Tracer patch parameters
    cᵢ(x, y, z) = Gaussian(x, 0, L)
    dᵢ(x, y, z) = Gaussian(0, y, L)
    eᵢ(x, y, z) = Gaussian(x, y, L)

    set!(model, c=cᵢ, d=dᵢ, e=eᵢ)

    # Time-scale for tracer advection across the smallest grid cell
    advection_time_scale = Δ_min(grid) / U
    
    Δt = 0.1advection_time_scale
    
    for step in 1:10
        time_step!(model, Δt)
    end
    return model.tracers
end

function solid_body_rotation_test(grid; regions = 1)

    mrg = MultiRegionGrid(grid, partition = XPartition(regions))

    free_surface = ExplicitFreeSurface(gravitational_acceleration = 1)
    coriolis     = HydrostaticSphericalCoriolis(rotation_rate = 0)

    model = HydrostaticFreeSurfaceModel(grid = mrg,
                                        momentum_advection = VectorInvariant(),
                                        free_surface = free_surface,
                                        coriolis = coriolis,
                                        tracers = :c,
                                        tracer_advection = WENO5(grid = grid),
                                        buoyancy = nothing,
                                        closure = nothing)

    g = model.free_surface.gravitational_acceleration
    R = grid.radius
    Ω = model.coriolis.rotation_rate

    uᵢ(λ, φ, z) = 0.1 * cosd(φ)
    ηᵢ(λ, φ)    = (R * Ω * 0.1 + 0.1^2 / 2) * sind(φ)^2 / g

    cᵢ(λ, φ, z) = Gaussian(λ, φ - 5, 10)

    set!(model, u=uᵢ, η=ηᵢ, c=cᵢ)

    Δt = 0.1 * Δ_min(grid)  / sqrt(g * grid.Lz) 

    for step in 1:10
        time_step!(model, Δt)
    end

    return merge(model.velocities, model.tracers)
end

Nx = 32; Ny = 32

# A rectilinear domain
grid_rect = RectilinearGrid(architecture, size = (Nx, Ny, 1),
                                    halo = (3, 3, 3),
                                    topology = (Periodic, Bounded, Bounded),
                                    x = (0, 1),
                                    y = (0, 1),
                                    z = (0, 1))

grid_lat = LatitudeLongitudeGrid(architecture, size = (Nx, Ny, 1),
                                    halo = (3, 3, 3),
                                    radius = 1, latitude = (-80, 80),
                                    longitude = (-180, 180), z = (-1, 0))

@testset "Testing multi region tracer advection" begin
    for grid in [grid_rect, grid_lat]
    
        cs, ds, es = solid_body_tracer_advection_test(grid)
        
        cs = interior(cs);
        ds = interior(ds);
        es = interior(es);

        for regions in [2, 4, 8]
            @info "  Testing $regions partitions on $(typeof(grid).name.wrapper)"
            c, d, e = solid_body_tracer_advection_test(grid; regions=regions)

            c = construct_regionally(interior, c)
            d = construct_regionally(interior, d)
            e = construct_regionally(interior, e)
            
            for region in 1:regions
                init = Int(size(csi, 1) / regions) * (region - 1) + 1
                fin  = Int(size(csi, 1) / regions) * region
                @test all(c[region] .== cs[init:fin, :, :])
                @test all(d[region] .== ds[init:fin, :, :])
                @test all(e[region] .== es[init:fin, :, :])
            end
        end
    end
end

@testset "Testing multi region solid body rotation" begin
    
    grid = grid_lat
    us, vs, ws, cs = solid_body_rotation_test(grid)
        
    us = interior(us);
    vs = interior(vs);
    ws = interior(ws);
    cs = interior(cs);
    
    for regions in [2, 4, 8]
        @info "  Testing $regions partitions on $(typeof(grid).name.wrapper)"
        u, v, w, c = solid_body_rotation_test(grid; regions=regions)

        u = construct_regionally(interior, u)
        v = construct_regionally(interior, v)
        w = construct_regionally(interior, w)
        c = construct_regionally(interior, c)
            
        for region in 1:regions
            @show region
            init = Int(size(cs, 1) / regions) * (region - 1) + 1
            fin  = Int(size(cs, 1) / regions) * region
            @show @test all(u[region] .== us[init:fin, :, :])
            @show @test all(v[region] .== vs[init:fin, :, :])
            @show @test all(w[region] .== ws[init:fin, :, :])
            @show @test all(c[region] .== cs[init:fin, :, :])
        end
    end
end



