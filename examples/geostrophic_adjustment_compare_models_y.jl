# # Geostrophic adjustment using Oceananigans.HydrostaticFreeSurfaceMode l
#
# This example demonstrates how to simulate the one-dimensional geostrophic adjustment of a
# free surface using `Oceananigans.HydrostaticFreeSurfaceModel`. Here, we solve the hydrostatic
# Boussinesq equations beneath a free surface with a small-amplitude about rest ``z = 0``,
# with boundary conditions expanded around ``z = 0``, and free surface dynamics linearized under 
# the assumption # ``η / H \ll 1``, where ``η`` is the free surface displacement, and ``H`` is 
# the total depth of the fluid.
#
# ## Install dependencies
#
# First let's make sure we have all required packages installed.

# ```julia
# using Pkg
# pkg"add Oceananigans, JLD2, Plots"
# ```

# ## A one-dimensional domain
#
# We use a one-dimensional domain of geophysical proportions,

using Oceananigans
using Oceananigans.Utils: kilometers

grid = RegularCartesianGrid(size = (1, 128, 1),
                            x = (0, 1), y = (0, 1000kilometers), z = (-400, 0),
                            topology = (Bounded, Periodic, Bounded))

# and Coriolis parameter appropriate for the mid-latitudes on Earth,

coriolis = FPlane(f=1e-4)

# ## Building a `HydrostaticFreeSurfaceModel`
#
# We use `grid` and `coriolis` to build a simple `HydrostaticFreeSurfaceModel`,

using Oceananigans.Models: HydrostaticFreeSurfaceModel
using Oceananigans.Models: ShallowWaterModel

model = HydrostaticFreeSurfaceModel(grid=grid, coriolis=coriolis)
model2= ShallowWaterModel(grid=grid,
                          coriolis=coriolis,
                          gravitational_acceleration=model.free_surface.gravitational_acceleration,
                          architecture=CPU())

# ## A geostrophic adjustment initial value problem
#
# We pose a geostrophic adjustment problem that consists of a partially-geostrophic
# Gaussian height field complemented by a geostrophic y-velocity,

Gaussian(y, L) = exp(-y^2 / 2L^2)

U = 0.1 # geostrophic velocity
L = grid.Ly / 40 # Gaussian width
y₀ = grid.Ly / 4 # Gaussian center

uᵍ(x, y, z) =  U * (y - y₀) / L * Gaussian(y - y₀, L)

g = model.free_surface.gravitational_acceleration

η₀ = coriolis.f * U * L / g # geostrohpic free surface amplitude

ηᵍ(x, y, z) = η₀ * Gaussian(y - y₀, L)

# We use an initial height field that's twice the geostrophic solution,
# thus superimposing a geostrophic and ageostrophic component in the free
# surface displacement field:

ηⁱ(x, y, z) = 2 * ηᵍ(x, y, z)

 hⁱ(x, y, z) = 2 * ηᵍ(x, y, z) + grid.Lz
uhⁱ(x, y, z) = uᵍ(x, y, z) * hⁱ(x, y, z)
# We set the initial condition to ``vᵍ`` and ``ηⁱ``,

set!(model,  u=uᵍ,   η=ηⁱ)
set!(model2, uh=uhⁱ, h=hⁱ)

# ## Running a `Simulation`
#
# We pick a time-step that resolves the surface dynamics,

gravity_wave_speed = sqrt(g * grid.Lz) # hydrostatic (shallow water) gravity wave speed

wave_propagation_time_scale = model.grid.Δy / gravity_wave_speed

simulation  = Simulation(model,  Δt = 0.1 * wave_propagation_time_scale, stop_iteration = 1000)
simulation2 = Simulation(model2, Δt = 0.1 * wave_propagation_time_scale, stop_iteration = 1000)


# ## Output
#
# We output the velocity field and free surface displacement,

output_fields = merge(model.velocities, (η=model.free_surface.η,))
output_fields2 = merge(model2.solution)

using Oceananigans.OutputWriters: JLD2OutputWriter, IterationInterval

simulation.output_writers[:fields] = JLD2OutputWriter(model, output_fields,
                                                      schedule = IterationInterval(10),
                                                      prefix = "geostrophic_adjustment",
                                                      force = true)

simulation2.output_writers[:fields] = JLD2OutputWriter(model2, output_fields2,
                                                       schedule = IterationInterval(10),
                                                       prefix = "geostrophic_adjustment2",
                                                       force = true)

run!(simulation)
run!(simulation2)

# ## Visualizing the results

using JLD2, Plots, Printf, Oceananigans.Grids
using Oceananigans.Utils: hours
using IJulia

yη = yw = yv = ynodes(model.free_surface.η)
yu = ynodes(model.velocities.u)

file = jldopen(simulation.output_writers[:fields].filepath)

iterations = parse.(Int, keys(file["timeseries/t"]))

anim = @animate for (i, iter) in enumerate(iterations)

    u = file["timeseries/u/$iter"][1, :, 1]
    v = file["timeseries/v/$iter"][1, :, 1]
    η = file["timeseries/η/$iter"][1, :, 1]
    t = file["timeseries/t/$iter"]

    titlestr = @sprintf("Geostrophic adjustment at t = %.1f hours", t / hours)

    u_plot = plot(yu / kilometers, u, linewidth = 2, title = titlestr,
                  label = "", xlabel = "y (km)", ylabel = "u (m s⁻¹)")

    v_plot = plot(yu / kilometers, v, linewidth = 2,
                  label = "", xlabel = "y (km)", ylabel = "v (m s⁻¹)")

    η_plot = plot(yη / kilometers, η, linewidth = 2,
                  label = "", xlabel = "y (km)", ylabel = "η (m)", ylims = (-η₀/10, 2η₀))

    plot(u_plot, v_plot, η_plot, layout = (3, 1), size = (800, 600))
end

close(file)

mp4(anim, "geostrophic_adjustment.mp4", fps = 15) # hide



### Now for ShallowWaterModel

yη = yw = yv = ynodes(model2.solution.h)
yu = ynodes(model2.solution.uh)

file2 = jldopen(simulation2.output_writers[:fields].filepath)

iterations2 = parse.(Int, keys(file2["timeseries/t"]))

anim = @animate for (i, iter) in enumerate(iterations2)

    uh = file2["timeseries/uh/$iter"][1, :, 1]
    vh = file2["timeseries/vh/$iter"][1, :, 1]
     h = file2["timeseries/h/$iter"][1, :, 1]
     t = file2["timeseries/t/$iter"]

    v = 0.5*(vh[2:end] .+ vh[1:end-1]) ./ h[1:end-1]
    u = uh ./ h
    η = h .- grid.Lz

    titlestr = @sprintf("Geostrophic adjustment2 at t = %.1f hours", t / hours)

    u_plot = plot(yu / kilometers, u, linewidth = 2, title = titlestr,
                  label = "", xlabel = "y (km)", ylabel = "u (m s⁻¹)")

    v_plot = plot(yv[2:end] / kilometers, v, linewidth = 2,
                  label = "", xlabel = "y (km)", ylabel = "v (m s⁻¹)")

    η_plot = plot(yη / kilometers, η, linewidth = 2,
                  label = "", xlabel = "y (km)", ylabel = "η (m)", ylims = (-η₀/10, 2η₀))

    plot(u_plot, v_plot, η_plot, layout = (3, 1), size = (800, 600))
end

close(file2)

mp4(anim, "geostrophic_adjustment2.mp4", fps = 15) # hide
