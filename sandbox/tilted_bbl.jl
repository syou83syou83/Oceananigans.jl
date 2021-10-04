using Oceananigans
using Oceananigans.Units
using Oceananigans.TurbulenceClosures: AnisotropicMinimumDissipation
using CUDA
using Printf

const Nx = 256; const Lx = 1000
const Nz = 32; const Lz = 100
const θ_rad = 0.05 # radians
const θ_deg = rad2deg(θ_rad) # degrees
const N²∞ = 1e-5
const V∞ = 0.1
const g̃ = (sin(θ_rad), 0, cos(θ_rad))

#++++ Grid
S = 1.3
z_faces(k) = Lz*(1 + tanh(S * ( (k - 1) / Nz - 1)) / tanh(S))
topo = (Periodic, Flat, Bounded)
grid = VerticallyStretchedRectilinearGrid(topology=topo,
                                          architecture = CUDA.has_cuda() ? GPU() : CPU(), 
                                          size=(Nx, Nz),
                                          x=(0, Lx), z_faces=z_faces,
                                          halo=(3,3),
                                         )
@info grid
#----

#++++ Buoyancy model and background
buoyancy = Buoyancy(model=BuoyancyTracer(), vertical_unit_vector=g̃)
tracers = :b

b∞(x, y, z, t) = N²∞ * (x*g̃[1] + z*g̃[3])
B_field = BackgroundField(b∞)

db∞dz = N²∞ * g̃[3]
grad_bc_b = GradientBoundaryCondition(-db∞dz) # db/dz + db∞/dz = 0 @ z=0
b_bcs = FieldBoundaryConditions(bottom = grad_bc_b)
#----

#+++++ Boundary Conditions
#+++++ Bottom Drag
const z₀ = 0.01 # roughness length (m)
const κ = 0.4 # von Karman constant
z₁ = znodes(Center, grid)[1]
const cᴰ = (κ / log(z₁))^2 # quadratic drag coefficient

@inline drag_u(x, y, t, u, v, cᴰ) = - cᴰ * √(u^2 + (v+V∞)^2) * u
@inline drag_v(x, y, t, u, v, cᴰ) = - cᴰ * √(u^2 + (v+V∞)^2) * (v + V∞)

drag_bc_u = FluxBoundaryCondition(drag_u, field_dependencies=(:u, :v), parameters=cᴰ)
drag_bc_v = FluxBoundaryCondition(drag_v, field_dependencies=(:u, :v), parameters=cᴰ)

u_bcs = FieldBoundaryConditions(bottom = drag_bc_u)
v_bcs = FieldBoundaryConditions(bottom = drag_bc_v)

V_bg(x, y, z, t) = V∞
V_field = BackgroundField(V_bg)
#-----

bcs = (u=u_bcs,
       v=v_bcs,
       b=b_bcs,
       )
#-----


#++++ Sponge layer definition
@inline heaviside(X) = ifelse(X < 0, zero(X), one(X))
@inline mask2nd(X) = heaviside(X) * X^2

function top_mask(x, y, z)
    z₁ = +Lz; z₀ = z₁ - Lz/5
    return mask2nd((z - z₀)/(z₁ - z₀))
end

const rate = 1/1minutes
full_sponge_0 = Relaxation(rate=rate, mask=top_mask, target=0)
forcing = (u=full_sponge_0, v=full_sponge_0, w=full_sponge_0, b=full_sponge_0)
#----

#++++ Model and ICs
model = NonhydrostaticModel(grid = grid, timestepper = :RungeKutta3,
                            advection = UpwindBiasedFifthOrder(),
                            buoyancy = buoyancy,
                            coriolis = FPlane(f=1e-4),
                            tracers = tracers,
                            closure = IsotropicDiffusivity(ν=1e-3, κ=1e-3),
                            boundary_conditions = bcs,
                            background_fields = (b=B_field, v=V_field,),
                            forcing=forcing,
                           )
println(); println(model); println()

noise(z, kick) = kick * randn() * exp(-z / (Lz/5))
u_ic(x, y, z) = noise(z, 1e-3)
set!(model, b=0, u=u_ic, w=u_ic)

ū = sum(model.velocities.u.data.parent) / (grid.Nx * grid.Ny * grid.Nz)
v̄ = sum(model.velocities.v.data.parent) / (grid.Nx * grid.Ny * grid.Nz)
w̄ = sum(model.velocities.w.data.parent) / (grid.Nx * grid.Ny * grid.Nz)

model.velocities.u.data.parent .-= ū
model.velocities.v.data.parent .-= v̄
model.velocities.w.data.parent .-= w̄
#----

#++++ Create simulation
wizard = TimeStepWizard(Δt=0.1*grid.Δzᵃᵃᶜ[1]/V∞, max_change=1.05, cfl=0.2)

# Print a progress message
progress_message(sim) =
    @printf("i: %04d, t: %s, Δt: %s, wmax = %.1e ms⁻¹, wall time: %s\n",
            sim.model.clock.iteration, prettytime(model.clock.time),
            prettytime(wizard.Δt), maximum(abs, sim.model.velocities.w),
            prettytime((time_ns() - start_time) * 1e-9))

simulation = Simulation(model, Δt=wizard, 
                        stop_time=2days, 
                        #stop_time=2hours, 
                        progress=progress_message,
                        iteration_interval=10,
                        stop_iteration=Inf,
                       )
#----


u, v, w = model.velocities
b_tot = ComputedField(model.tracers.b + model.background_fields.tracers.b)
v_tot = ComputedField(v + model.background_fields.velocities.v)
ω_y = ComputedField(∂z(u)-∂x(w))
fields = merge((; u, v_tot, w, b_tot, ω_y))
simulation.output_writers[:fields] =
NetCDFOutputWriter(model, fields, filepath = "out.tilted_bbl.nc",
                   schedule = TimeInterval(5minutes),
                   mode = "c")


@info "Starting simulation"
start_time = time_ns() # so we can print the total elapsed wall time
run!(simulation)