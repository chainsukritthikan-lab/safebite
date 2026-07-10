# Simracing Open-World Game — Architecture Blueprint & Core Implementation

> A design and engineering blueprint for a game that combines **Assetto Corsa / iRacing-grade
> vehicle dynamics** with a **GTA V-scale living open world**.
> Working title: **APEX: Open Roads**.

---

## Table of Contents

1. [Core Architecture & Tech Stack](#1-core-architecture--tech-stack)
2. [Hardcore Simracing Physics Engine](#2-hardcore-simracing-physics-engine)
3. [Open-World Environment Mechanics](#3-open-world-environment-mechanics)
4. [Game Loop & Progression](#4-game-loop--progression)
5. [MVP Roadmap](#5-mvp-roadmap)

---

## 1. Core Architecture & Tech Stack

### 1.1 Engine choice: Unreal Engine 5 + a custom vehicle dynamics core

| Option | Open-world tooling | Physics fidelity | Verdict |
|---|---|---|---|
| **UE5** | World Partition, Nanite, Lumen, HLOD, Mass AI — best-in-class out of the box | Chaos Vehicles is *not* sim-grade, but UE lets you bypass it entirely | ✅ **Recommended** |
| Unity (DOTS/ECS) | Streaming must be largely hand-rolled; ECS traffic is excellent | PhysX vehicle module is arcade; custom physics equally possible | Viable for a small team already fluent in C# |
| Custom engine | Total control (this is the AC/iRacing route) | Perfect | 3–5 years of engine work before gameplay. Only with an experienced engine team |

**The key insight:** no stock engine vehicle solver (Chaos Vehicles, PhysX WheelCollider) is
acceptable for simracing. Every serious sim writes its own tire/suspension/drivetrain solver and
uses the engine only for **collision queries, rendering, streaming, audio, and rigid-body
integration of *non-player* objects**.

So the architecture is:

```
┌─────────────────────────────────────────────────────────────┐
│                      UE5 (game thread, 60–120 Hz)           │
│  Rendering · Streaming · Traffic AI · Audio · UI · Netcode  │
└───────────────▲─────────────────────────────▲───────────────┘
                │ state snapshots              │ collision/query API
┌───────────────┴─────────────────────────────┴───────────────┐
│           CUSTOM VEHICLE DYNAMICS CORE (own thread)          │
│   Fixed timestep 400–1000 Hz · deterministic · double-prec.  │
│   Tires · Suspension kinematics · Aero · Drivetrain · Diff   │
└──────────────────────────────────────────────────────────────┘
```

- The dynamics core is a **plain C++ library with zero engine dependencies** (unit-testable,
  runs headless for telemetry regression, reusable if you ever switch engines).
- It runs on a dedicated thread at a **fixed timestep** (iRacing: 360 Hz; AC: 333 Hz;
  modern target: **600 Hz** physics with 1000+ Hz tire sub-stepping under high slip).
- The game thread consumes interpolated snapshots for rendering; force-feedback is sampled
  straight from the physics thread at wheelbase rate (typically 360 Hz+) to avoid FFB latency.

### 1.2 The "streaming world vs. precise physics" problem

Three problems appear when you put a 400 Hz sim car in a 100 km² world:

**(a) Floating-point precision.** At 30 km from origin, `float` resolution is ~2–4 mm — fatal for
a tire model resolving 0.1 mm contact-patch deflections.

- **Solution 1 — Large World Coordinates:** UE5 already uses doubles for world transforms.
  Keep the dynamics core in **double precision** for positions, `float`/SIMD for local-frame
  force math (forces are computed in the car's local frame anyway, so magnitudes stay small).
- **Solution 2 — Origin rebasing for the physics island:** the dynamics core simulates in a
  **local frame centered on the player car**, re-anchored every ~2 km. World→local conversion
  happens only at the query boundary (raycasts, collision).

**(b) Collision geometry availability.** The car must never fall through an unstreamed tile.

- Split streaming into **two independent rings**:
  - **Visual ring** (Nanite meshes, buildings, foliage): radius ~2 km, latency-tolerant.
  - **Physics ring** (road collision + grip map + surface metadata): radius ~600 m at 300 km/h,
    **blocking-guaranteed** — the streaming scheduler prioritizes physics tiles along the
    velocity vector (predictive prefetch: `prefetch_center = pos + vel * 4s`).
- Roads get a dedicated lightweight representation: a **spline-based road network** with
  per-lane profiles + a heightfield/mesh per tile. The spline network is tiny (few MB for the
  whole map) and is *always resident* — so even in a catastrophic streaming stall the car has
  an analytic road surface to stand on.

**(c) Fixed-timestep physics vs. variable frame rate.** Standard accumulator pattern, plus:
the physics thread never blocks on the render thread. Traffic vehicles use a cheaper 3-DOF
model stepped at 60 Hz inside the engine's own solver; only the player car (and nearby
multiplayer cars) run the full 600 Hz core.

### 1.3 Tech stack summary

| Layer | Choice |
|---|---|
| Engine | Unreal Engine 5.4+ (World Partition, Mass Entity, LWC) |
| Vehicle dynamics | Custom C++20 library ("ApexDyn"), SIMD (ISPC or xsimd), fixed 600 Hz |
| World streaming | World Partition + custom physics-tile ring + always-resident road spline DB |
| Traffic / crowds | Mass Entity (ECS) — 3 LOD tiers of vehicle simulation |
| Grip / surface state | Custom "Dynamic Surface Layer" — GPU-updated virtual texture + CPU mirror (§3.2) |
| Telemetry | Built-in MoTeC-compatible logger (i2 export), shared-memory API for dashboards |
| Netcode (later) | Deterministic-ish lockstep is impossible here → snapshot interpolation @ 60 Hz w/ client-side prediction of own car only |
| FFB / input | DirectInput/SDL + vendor SDKs (Simucube, Fanatec, Moza), 360 Hz FFB thread |

---

## 2. Hardcore Simracing Physics Engine

This is the product. Everything else is context around it.

### 2.1 Tire model — the heart of the sim

Use a **brush-model-informed Magic Formula (Pacejka MF-6.2-style) with combined slip, load
sensitivity, and a 3-node thermal model**. This is the AC-family approach: empirically stable,
tunable per tire compound, cheap enough for 1000 Hz.

**Slip quantities** (per wheel, computed in the contact-patch frame):

- **Slip angle** `α = atan2(v_lat, |v_long|)` — angle between wheel heading and velocity.
- **Slip ratio** `κ = (ω·Re − v_long) / max(|v_long|, v_min)` — normalized rotational slip.
- At near-zero speed, switch to a **relaxation-length / bristle formulation** to avoid the
  divide-by-zero jitter that plagues naive implementations (this is what makes or breaks
  standing starts and pit-box behavior).

**Grip curve** (per axis, before combining):

```
F = D · sin(C · atan(B·s − E·(B·s − atan(B·s))))
```

- `B` stiffness factor — initial slope (cornering stiffness / braking stiffness)
- `C` shape factor — where the curve peaks and how it falls off
- `D` peak factor — `D = μ · Fz`, with **load sensitivity**: `μ(Fz) = μ0 · (Fz/Fz0)^(−ε)`,
  ε ≈ 0.05–0.15. This single term is why weight transfer *loses* total grip and why aero cars
  behave differently — do not skip it.
- `E` curvature factor — post-peak drop-off (street tire: gentle; slick: sharp cliff)

**Combined slip:** normalize both slips against their peak values and scale by a friction
ellipse:

```
ρ = sqrt( (κ/κ_peak)² + (α/α_peak)² )        // combined utilization
Fx = Fx_pure(κ') · (κ/κ_peak)/ρ · G_xα        // weighted by direction of demand
Fy = Fy_pure(α') · (α/α_peak)/ρ · G_yκ
```

**Thermal model — 3 nodes per tire** (surface, carcass/core, gas):

- Heat **in**: friction power `P = |Fx·v_sx| + |Fy·v_sy|` (sliding energy) + hysteresis from
  carcass deflection (function of load × deflection rate) + brake-disc radiation into the rim.
- Heat **out**: convection to air (`h ∝ v^0.8`), conduction to track surface.
- Grip multiplier is a **bell curve around optimal temp** (slick: ~85–105 °C, street: ~40–70 °C):
  `μ_temp = exp(−((T_surf − T_opt)/T_width)²)`.
- **Pressure** follows gas temperature (ideal gas from cold pressure), and pressure shifts the
  load-sensitivity and contact-patch shape (over-pressure → crowned patch → less peak grip,
  faster center wear).
- **Wear**: integrate sliding energy at the surface node into a wear depth per rib
  (inner/center/outer ribs let camber and pressure produce realistic uneven wear).
  Wear reduces `D` (peak grip) slowly, then sharply past the cords.

**Flat-spotting:** lock-ups dump enormous sliding energy at one patch → store a per-tire
flat-spot magnitude + phase → inject a periodic vertical force at `ω` into the suspension. Free
immersion, cheap to implement, and it makes braking discipline matter.

### 2.2 Suspension geometry & weight transfer

Model each corner as a **kinematic linkage evaluated as lookup curves** (the AC/rF2 approach —
full multibody like BeamNG is overkill and hurts determinism):

- Author real geometry (double wishbone / MacPherson / multilink) in a setup tool; bake
  **camber-vs-travel, toe-vs-travel, caster, roll-center height, anti-dive/anti-squat** curves.
- Runtime evaluates the curves from suspension travel + steering rack position. You get correct
  **camber gain in roll**, bump steer, and jacking forces at lookup-table cost.

**Per-corner force stack (each physics tick):**

1. **Spring:** `F_s = k · (x − x_rest)` with progressive/packer options; separate **bump stop**
   polynomial when travel exceeds packer gap.
2. **Damper:** 4-segment digressive curve — low-speed bump/rebound (body control, feel) and
   high-speed bump/rebound (curbs, bumps), exactly like real setup sheets.
3. **Anti-roll bar:** `F_arb = k_arb · (x_left − x_right)` applied antisymmetrically.
4. **Load transfer** emerges naturally from rigid-body dynamics + these forces — do **not**
   script "weight transfer"; simulate sprung mass properly and it falls out. Model **unsprung
   mass** per corner (wheel, upright, brake) as its own 1-DOF body on the spring/damper — this
   is what makes curbs, kerb-hopping, and mid-corner bumps feel real.
5. **Anti-geometry:** longitudinal forces at the contact patch are split between the spring path
   and the linkage path per the baked anti-dive/anti-squat percentages.

### 2.3 Aerodynamics

- **Component-based aero:** each element (front splitter, floor/diffuser, rear wing, body) has
  `CL·A` and `CD·A` maps as functions of **ride height (front & rear), rake, yaw, and element
  setting** (wing angle clicks). Ground-effect floors get a steep ride-height sensitivity —
  this creates real behaviors: bottoming → sudden downforce loss, high-speed compression, etc.
- Apply each element's force at its own application point → aero balance shifts with rake
  exactly like real telemetry shows.
- **Drag & top speed:** `F_d = ½ρ v² CD·A`, plus rolling resistance and driveline losses.
- **Slipstreaming (open world!):** every significant vehicle publishes a **wake volume** — a
  frustum behind it (~4 car lengths at 100%, decaying over ~25–40 m, expanding with distance).
  A car inside a wake samples: `ρ_eff = ρ · (1 − w·drag_relief)` for drag (tow), and
  `CL_eff = CL · (1 − w·df_loss)` for downforce (dirty air → understeer when close). Traffic
  trucks on the highway give a *big* tow — an emergent open-world mechanic street racers will
  exploit organically.
- **Wind:** global wind vector + gusting noise feeds into airspeed. Cheap, big immersion.

### 2.4 Drivetrain (brief but required)

Torque path: engine (RPM-torque map + inertia) → clutch (torsional spring-damper) → gearbox
(ratio + inertia + shift model) → differential (**clutch-pack LSD with preload / power / coast
ramp angles** — the single biggest handling component after tires) → wheels. Simulate engine
braking, and fuel mass affecting CoG. Turbo lag as a first-order boost state. All of it runs
inside the 600 Hz loop; the diff especially cannot be approximated without killing corner-exit
behavior.

### 2.5 Reference implementation — vehicle physics core (C++)

Engine-agnostic, fixed-timestep, per-wheel force computation. This is a *compressed but
honest* skeleton of the real thing — every formula shown is the one you'd ship, with the
authoring-data plumbing and SIMD stripped for readability.

```cpp
// =====================================================================
// ApexDyn — vehicle dynamics core (excerpt)
// Fixed timestep, deterministic, engine-agnostic. dt = 1/600 s.
// Conventions: ISO vehicle frame. X forward, Y left, Z up. SI units.
// =====================================================================
#include <cmath>
#include <array>
#include <algorithm>

struct Vec3 { double x{}, y{}, z{}; /* +, -, *, dot, cross omitted */ };

// ---------------------------------------------------------------------
// Tire: Magic-Formula lateral/longitudinal + combined slip + thermal
// ---------------------------------------------------------------------
struct TireParams {
    // Pacejka-style coefficients (per compound, from authoring tool)
    double Bx = 15.0, Cx = 1.65, Ex = 0.60;   // longitudinal
    double By = 9.5,  Cy = 1.45, Ey = 0.97;   // lateral
    double mu0 = 1.35;          // peak friction at reference load
    double Fz0 = 4200.0;        // reference load [N]
    double loadSens = 0.10;     // ε: μ = μ0·(Fz/Fz0)^-ε
    double peakSlipRatio = 0.11;
    double peakSlipAngle = 0.105;             // rad (~6 deg)
    double relaxLenLat = 0.32, relaxLenLong = 0.18;  // [m]
    // Thermal
    double Topt = 92.0, Twidth = 42.0;        // grip bell curve [°C]
    double surfHeatCap = 1900.0, coreHeatCap = 9500.0;  // [J/K]
    double kSurfCore = 45.0;                  // conduction [W/K]
    double hConvRef = 9.0;                    // convection base [W/K per (m/s)^0.8]
    double radius = 0.33;                     // loaded radius [m]
    double rollRes = 0.012;
};

struct TireState {
    double Tsurface = 26.0, Tcore = 26.0;     // [°C]
    double wear = 0.0;                        // 0..1
    double flatSpot = 0.0, flatSpotPhase = 0.0;
    double slipAngleFilt = 0.0, slipRatioFilt = 0.0;  // relaxation states
};

struct TireOutput {
    double Fx = 0, Fy = 0;        // contact patch forces [N]
    double Mz = 0;                // self-aligning torque [N·m] (FFB!)
    double slipAngle = 0, slipRatio = 0;
    double dissipation = 0;       // sliding power [W] → heat, wear
};

static double magicFormula(double s, double B, double C, double D, double E) {
    const double Bs = B * s;
    return D * std::sin(C * std::atan(Bs - E * (Bs - std::atan(Bs))));
}

TireOutput tireStep(const TireParams& p, TireState& st,
                    double Fz,            // normal load [N]
                    double vLong, double vLat,  // contact patch velocity, wheel frame [m/s]
                    double omega,         // wheel spin [rad/s]
                    double surfaceGrip,   // dynamic grip map sample, ~0.55 wet .. 1.08 rubbered
                    double dt)
{
    TireOutput out{};
    if (Fz <= 1.0) { st.slipAngleFilt *= 0.9; st.slipRatioFilt *= 0.9; return out; } // airborne

    // ---- Instantaneous slip (guarded at low speed) ----
    const double vx = std::max(std::abs(vLong), 0.3);        // [m/s] guard
    const double rawKappa = (omega * p.radius - vLong) / vx;
    const double rawAlpha = std::atan2(vLat, vx);

    // ---- Relaxation length: slip builds over rolled distance, not instantly ----
    // dS/dt = (v/L)·(S_raw − S).  Gives correct transient response & low-speed stability.
    const double vAbs  = std::max(std::hypot(vLong, vLat), 0.1);
    st.slipRatioFilt += (vAbs / p.relaxLenLong) * (rawKappa - st.slipRatioFilt) * dt;
    st.slipAngleFilt += (vAbs / p.relaxLenLat ) * (rawAlpha - st.slipAngleFilt) * dt;
    const double kappa = st.slipRatioFilt, alpha = st.slipAngleFilt;

    // ---- Peak friction: base × load sensitivity × temperature × wear × surface ----
    const double muLoad = p.mu0 * std::pow(Fz / p.Fz0, -p.loadSens);
    const double dT     = (st.Tsurface - p.Topt) / p.Twidth;
    const double muTemp = std::exp(-dT * dT);                 // bell curve
    const double muWear = 1.0 - 0.35 * st.wear * st.wear;     // gentle, then a cliff via wear>1 → cords
    const double mu     = muLoad * (0.65 + 0.35 * muTemp) * muWear * surfaceGrip;
    const double D      = mu * Fz;

    // ---- Pure-slip forces ----
    const double FxPure = magicFormula(kappa, p.Bx, p.Cx, D, p.Ex);
    const double FyPure = magicFormula(alpha, p.By, p.Cy, D, p.Ey);

    // ---- Combined slip: friction-ellipse weighting ----
    const double nk = kappa / p.peakSlipRatio, na = alpha / p.peakSlipAngle;
    const double rho = std::max(std::hypot(nk, na), 1e-6);
    out.Fx =  FxPure * std::abs(nk) / rho;                    // sign carried by FxPure(kappa)
    out.Fy = -FyPure * std::abs(na) / rho;                    // opposes lateral slip

    // ---- Self-aligning torque (pneumatic trail collapses past peak → FFB lightness) ----
    const double trail = 0.035 * std::max(0.0, 1.0 - std::abs(na));  // [m]
    out.Mz = -out.Fy * trail;

    // ---- Rolling resistance ----
    out.Fx -= p.rollRes * Fz * ((vLong > 0) - (vLong < 0));

    // ---- Thermal + wear bookkeeping ----
    const double vSlipX = omega * p.radius - vLong;
    const double vSlipY = vLat;
    out.dissipation = std::abs(out.Fx * vSlipX) + std::abs(out.Fy * vSlipY);   // [W]
    const double hConv = p.hConvRef * std::pow(std::max(vAbs, 1.0), 0.8);
    const double Tair = 24.0, Ttrack = 30.0;                  // fed from weather system
    st.Tsurface += dt / p.surfHeatCap *
        ( 0.85 * out.dissipation                              // sliding heat → surface
        - p.kSurfCore * (st.Tsurface - st.Tcore)              // conduct to core
        - hConv * (st.Tsurface - Tair)                        // convection
        - 25.0 * (st.Tsurface - Ttrack));                     // conduction to road
    st.Tcore    += dt / p.coreHeatCap *
        ( 0.15 * out.dissipation                              // carcass hysteresis share
        + p.kSurfCore * (st.Tsurface - st.Tcore));
    st.wear += out.dissipation * dt * 2.5e-9 * (1.0 + 3.0 * std::max(0.0, dT)); // hot = faster wear

    out.slipAngle = alpha; out.slipRatio = kappa;
    return out;
}

// ---------------------------------------------------------------------
// Suspension corner: spring + damper + ARB + kinematic camber/toe curves
// ---------------------------------------------------------------------
struct SuspensionParams {
    double springRate = 95000.0;              // [N/m]
    double bumpStopGap = 0.055, bumpStopRate = 6.5e5;
    double travelMax = 0.10;                  // [m] each way
    // 4-segment damper [N·s/m]: lowBump, hiBump, lowReb, hiReb; knee [m/s]
    double dLB = 6500, dHB = 2800, dLR = 8200, dHR = 3400, knee = 0.10;
    double arbRate = 42000.0;                 // [N/m] of relative travel
    // Baked kinematics: linearized here; real build uses LUT curves
    double camberStatic = -3.2 * M_PI/180, camberGainPerM = -28.0 * M_PI/180;
    double toeStatic = 0.15 * M_PI/180,   bumpSteerPerM =  1.5 * M_PI/180;
    double unsprungMass = 42.0;               // [kg]
    double antiSquat = 0.25;                  // fraction of Fx through linkage
};

struct CornerState { double travel = 0, travelVel = 0; };

double damperForce(const SuspensionParams& s, double v) {
    if (v > 0)  return -( v <  s.knee ? s.dLB * v : s.dLB*s.knee + s.dHB*(v - s.knee)); // bump
    v = -v;     return  ( v <  s.knee ? s.dLR * v : s.dLR*s.knee + s.dHR*(v - s.knee)); // rebound
}

// ---------------------------------------------------------------------
// Vehicle: 4 corners + rigid body + drivetrain (excerpt of the step fn)
// ---------------------------------------------------------------------
struct VehicleState {
    Vec3 pos, vel;                 // world (double precision, local island frame)
    Vec3 angVel;                   // body frame
    double quat[4] = {1,0,0,0};
    std::array<double,4> wheelOmega{};        // FL, FR, RL, RR
    std::array<CornerState,4> corners{};
    std::array<TireState,4> tires{};
    double engineRPM = 900, gear = 1, fuel = 45.0;
};

struct SurfaceQuery {          // provided by the engine-side query layer
    bool   hit;
    Vec3   point, normal;
    double grip;               // dynamic grip map sample  (§3.2)
    double bumpHeight;         // micro-roughness for road noise
};

// One 600 Hz tick, per wheel (inner loop shown; rigid-body integration,
// drivetrain and diff omitted for brevity — see drivetrain module):
//
//   1. Raycast/shapecast from corner hardpoint along -Z_body → SurfaceQuery
//   2. travel      = restLength − hitDistance   (clamped to travelMax)
//   3. Fspring     = k·travel (+ bumpstop past gap)
//      Fdamper     = damperForce(travelVel)
//      Farb        = arbRate · (travel − travelOppositeSide)
//      Fz          = max(0, Fspring + Fdamper + Farb) projected on surface normal
//   4. camber      = camberStatic + camberGainPerM · travel   (+ steer-axis effects)
//      toe/steer   → build wheel basis on the surface plane
//   5. vContact    = bodyVelocityAt(cornerPos) expressed in wheel basis
//   6. tireStep(params, state, Fz, v.long, v.lat, wheelOmega, surface.grip, dt)
//   7. Apply Fx, Fy at contact point (split via antiSquat between hub & body),
//      Fz along normal; accumulate Mz for the steering column → FFB
//   8. wheelOmega += (driveTorque − brakeTorque − Fx·radius) / wheelInertia · dt
//
// The full loop also handles: unsprung mass as 1-DOF body per corner,
// aero forces per element (ride-height sampled maps), fuel/CoG update,
// flat-spot excitation injected into Fz at wheel rotation frequency.
```

**What makes this "sim" and not "arcade":**

1. Forces come **only** from slip — there is no scripted "grip assist", no fake yaw damping,
   no speed-scaled steering. Understeer/oversneer/traction loss are emergent.
2. **Relaxation lengths** give real transient response (turn-in bite, mid-corner bump recovery)
   and stable low-speed behavior without hacks.
3. **Load sensitivity + thermal + wear + surface grip** all multiply into `D` — so setup,
   driving style, weather, and track evolution genuinely change the car.
4. `Mz` (self-aligning torque) is computed physically → **force feedback is a physics output**,
   not a canned effect. The FFB lightening past the grip peak is how drivers feel the limit.

---

## 3. Open-World Environment Mechanics

### 3.1 Dynamic Traffic AI

Built on UE5 **Mass Entity (ECS)** with three simulation LODs:

| Tier | Range | Simulation |
|---|---|---|
| **T0 — Full** | < 150 m | 3-DOF bicycle-model vehicle, per-agent perception & behavior tree, rendered |
| **T1 — Simplified** | 150–600 m | Spline-follow with kinematic lane logic, simplified avoidance, rendered as LOD/impostor |
| **T2 — Statistical** | > 600 m | No individual agents — per-road-segment density/flow values that *spawn* T1 agents as you approach, tuned so traffic feels continuous and never "pops" into existence in view |

**Behavior model (T0/T1)** — every agent runs a utility stack:

1. **Lane keeping** on the always-resident road spline network (same DB physics uses).
2. **IDM car-following** (Intelligent Driver Model) for gap keeping — proven, cheap, produces
   realistic emergent jams and shockwaves.
3. **MOBIL lane changes** — change lanes when it improves own utility without forcing others
   to brake beyond a politeness threshold. Per-driver personality scalars (aggression,
   attention, desired speed offset) sampled from distributions → a living, varied population.
4. **Traffic law layer:** signals, stop signs, right-of-way, speed limits — obeyed per the
   attention/aggression personality (some drivers roll stops, speed +10%).

**Reacting to a 300 km/h player** — the special sauce:

- **Threat perception cone:** agents raycast rear approach; reaction triggers scale with
  closing speed. At high closing speeds agents get a *delayed then decisive* response
  (human-like: mirror-check latency 0.6–1.4 s from personality, then commit to pulling right/
  left based on player's lateral trajectory prediction, not random).
- **Panic realism, bounded:** small chance of a *wrong* response (brake instead of yield,
  freeze in lane) scaled by the driver's attention stat — this creates the "traffic is the
  boss fight" tension street racing needs, while prediction-based yielding keeps it fair.
- **Emergent consequences:** near-misses honk and swerve; collisions trigger hazard lights,
  pulled-over cars, rubber-necking slowdowns upstream (IDM handles the jam automatically),
  and eventually police response scaling with your Heat level.
- **Fairness guarantee for racing:** during sanctioned street race events, the traffic
  *director* (a global system) can shape density along the route (never zero — just bounded)
  and forbids T2→T1 spawns inside a corridor ahead of racers, so no car ever materializes
  120 m in front of a 300 km/h pack. Spawn-ahead distance is always `≥ v_player · 6 s`.

### 3.2 Dynamic Track Surface — the living grip map

The physics-defining feature that fuses the two genres. Every road in the world has evolving
surface state that the tire model samples every tick.

**Data structure:**

- A **Runtime Virtual Texture "Surface State Layer"** covering all drivable surfaces,
  4 channels at ~10 cm/texel near the player (mip-chained coarser at distance):
  - `R` — **rubber** (0–1): laid down by tires sliding at high temperature
  - `G` — **wetness** (0–1): rain accumulation minus drainage/drying
  - `B` — **contaminant** (0–1): dust, dirt, gravel dragged onto road, oil from damaged cars
  - `A` — **standing water** (puddle depth, from a static drainage/flow bake of the road mesh)
- **GPU** updates the layer (rain fall/dry compute shader, tire deposit splats) and renders it
  (darkened racing line, glossy wet patches, dust film — the grip map *is* the visual).
- A **CPU mirror** of tiles within the physics ring (the ~600 m physics streaming ring from
  §1.2) is kept in sync at 10 Hz so the 600 Hz tire loop reads grip from plain memory, never
  the GPU. Physics correctness never depends on framerate.

**Grip composition sampled per contact patch:**

```
grip = baseSurface(asphaltType)                    // fresh asphalt 1.00, concrete 0.96, worn 0.92
     × (1 + 0.07 · rubber · (1 − wetness·1.5))     // rubber helps dry, HURTS wet (greasy!)
     × wetnessCurve(wetness)                       // 1.0 → ~0.75 damp → ~0.62 soaked
     × (1 − 0.35 · contaminant)                    // dust/dirt/oil
     × puddlePenalty(waterDepth, v, tireWidth)     // → aquaplaning: grip → ~0.1 above critical speed
                                                   //    v_aqua ≈ 6.35·sqrt(pressure_psi) [mph] heuristic
```

**Dynamics over time:**

- **Rubbering-in:** every tire deposits `dissipation · deposit_rate` into `R` along its contact
  patch splat. Race events on a street circuit visibly *carve a darker racing line over the
  event* — grip on line improves lap by lap, offline stays "green". Traffic lanes rubber up
  where commuters drive, which is *not* the racing line — so public roads have grip exactly
  where racers don't want it. Brilliant emergent tension, zero scripting.
- **Greasing up:** high `rubber` × rising `wetness` = the classic "greasy" phase — the formula
  above makes a rubbered line *worse* than offline in early rain, exactly like real racing.
  Drivers who know to move offline when rain starts get rewarded.
- **Drying:** evaporation rate from sun/temperature/wind + **cars themselves dry the line** —
  each pass displaces water along the splat. A drying line emerges after rain, again for free.
- **Contamination flow:** off-road excursions drag dirt onto asphalt (splat decays over
  minutes); crashes leak oil (persistent slick until cleanup event or rain washes it);
  gravel-trap exits drop stones (particle + grip splat combo).
- **Persistence:** the layer streams to disk with world tiles — the world *remembers*. Your
  favorite touge gets visibly, physically more rubbered over your career.

### 3.3 Weather & time

Rain intensity drives the wetness compute pass; track temperature (time of day, sun exposure,
shade from buildings — sample the lightmap!) feeds tire thermal and drying rate. Night lowers
track temp → different setup windows for night street events vs. midday track days. All of it
flows through the *same* grip pipeline; there are no special-cased "rain physics".

---

## 4. Game Loop & Progression

### 4.1 Career: "From the streets to the podium" — one continuous world

No menus-as-teleports. The career is geography:

**Act structure (all in the same map, all drivable between):**

1. **Grassroots (open world):** you own a used street car. Content: highway runs, touge time
   attacks (point-to-point mountain passes), sprint street races, "pink slip" rivals, car
   meets (social hubs, mission board). Earn cash + **Reputation**.
2. **The Bridge:** reputation unlocks **track-day invitations** at the world's circuits
   (2–3 real-style circuits physically placed in the map — an industrial-area kart/club track,
   a permanent GP circuit outside the city, a touge-adjacent hillclimb course). You *drive
   to the track*, through the paddock gate, to your garage slot. Track days teach the sim
   layer: passing rules, flags, tire prep, telemetry.
3. **Licensed racing:** club series → national GT/formula ladders. Real stakes: entry fees,
   scrutineering (your street-tuned car may be *illegal* for a class — build purposefully),
   contracts, team offers. Signature events close public roads into **temporary street
   circuits** (the city GP) — the two worlds literally merge.
4. **Endgame duality:** hold both careers at once. Pro racing pays for the street life;
   street reputation feeds a black-market parts economy pro racing can't touch. Heat from
   street racing risks your racing license — a real strategic tension.

**Seamless transitions, concretely:** circuits are normal world geometry behind gates. An
"event" is just: a registration handshake (at the gate or via phone UI), a session state
machine (practice/quali/race with the sim rule set: flags, penalties, parc fermé), and traffic
director orders (close circuit to traffic). Leave the gate, and the same car, same tire wear,
same fuel, is on public roads again — where the sim rule set drops away but physics never changes.

### 4.2 Damage, maintenance & tuning economy

**Damage model (physics-coupled, three layers):**

- **Mechanical:** suspension arms bend (permanently offsets that corner's baked kinematic
  curves — a bent car pulls and eats a tire edge, exactly like reality), radiators leak →
  engine temp climbs → power loss → head-gasket failure; gearbox synchro wear from flat
  shifts; brake fade → fluid boil with overuse.
- **Structural/visual:** deformation + detachables, mostly cosmetic but aero elements that
  break *lose their force contribution* (splitter gone = front downforce gone).
- **Wear (continuous, always on):** tires (§2.1), brake pads/discs, engine hours (oil quality
  window, rebuild intervals), clutch. Everything degrades from *use profile*, not a timer —
  telemetry shows a track day costs ~X in consumables, so running costs are strategy.

**Maintenance loop:** garage inspection screen = a real setup sheet: per-rib tire temps/wear,
damper histograms, ride-height rake, alignment after that curb strike. Choose: fix now (parts +
labor + time), run it worn (risk), or upgrade. Street shops are cheap/slow/no-questions-asked;
pro paddock service is instant/expensive/logged (scrutineering sees everything).

**Tuning:** full sim setup surface — alignment, springs/dampers/ARBs, aero clicks, diff ramps,
gear stacks, tire pressures/compounds, fuel — saved as setups per venue. **Telemetry is the
teacher:** built-in MoTeC-style overlay (speed/throttle/brake/steer traces, tire temps, sector
deltas, ghost comparison). Progression = knowledge: the game never sells "grip +5%" upgrades;
it sells *parts with real parameter consequences* and teaches you to exploit them.

**Economy sinks & faucets:** faucets — race purses, street wagers, sponsor contracts,
deliveries/liveries; sinks — consumables, repairs, entry fees, insurance (street heat raises
premiums), garage rent, parts. Target: a mid-career player funds ~70% of running costs from
winnings, so driving well *is* the economy.

---

## 5. MVP Roadmap

**Prime directive: the tire model IS the product. Nothing else matters until one car feels
right on one flat pad.** Every phase has an exit test — do not advance without passing it.

### Phase 0 — Foundations (2–4 weeks)
- UE5 project, LWC on; **ApexDyn** C++ lib skeleton (own repo, zero UE deps, unit tests).
- Fixed-timestep physics thread + snapshot interpolation into UE. dt = 1/600 s.
- Wheel/pedal input at physics rate; keyboard fallback.
- **Exit test:** a rigid box on 4 raycast springs drops onto a plane, settles with zero jitter,
  identical trajectory across runs (determinism harness in CI).

### Phase 1 — One car on a skidpad (6–10 weeks) ← *the make-or-break phase*
- Implement §2 core: MF tire w/ combined slip + relaxation lengths, suspension corners
  (spring/damper/ARB, linearized kinematics), simple engine + 1 diff (start: open, then LSD),
  steering with physical `Mz` → FFB out.
- Test environment: **flat pad + skidpad circles + one 3-corner mini track**. No art.
- Build the **telemetry logger first** — you cannot tune what you cannot see. Validate against
  known ground truth: steady-state skidpad lateral g vs. hand-calculated, braking distance,
  understeer gradient, step-steer transient shape.
- **Exit test (feel, measured):** hold a 40 m skidpad circle at the limit with throttle
  modulation; provoke and *catch* oversteer on countersteer using FFB cues alone; trail-brake
  rotation works. Get 3–5 sim-racer testers; iterate until they say "this feels like a sim."

### Phase 2 — The sim layer complete (6–8 weeks)
- Thermal + wear + pressure, flat spots; full damper curves + bump stops + kinematic LUTs;
  component aero with ride-height maps; clutch-pack LSD ramps; fuel mass.
- Setup screen (alignment, pressures, springs, wings) + MoTeC-compatible telemetry export.
- **Exit test:** setup changes produce directionally-correct, telemetry-visible handling
  changes (more rear wing → measurable high-speed balance shift; −0.5° front camber → outer-rib
  temp change).

### Phase 3 — Surface & weather vertical slice (4–6 weeks)
- Dynamic Surface Layer (§3.2) on the mini track: rubbering, rain wetness, drying line,
  aquaplaning. GPU visual + CPU mirror.
- **Exit test:** 20 laps visibly rubber the line and improve lap times ~0.5–1%; rain flips
  the rubbered line to greasy; a drying line emerges and lap times recover.

### Phase 4 — Open-world slice (8–12 weeks)
- **One district:** ~4 km highway loop + one touge + connecting streets (~10 km² tile set).
- World Partition streaming + the physics-ring/road-spline guarantee (§1.2); origin handling
  verified at map edges.
- Traffic v1: T0/T1 tiers, IDM+MOBIL, high-speed threat response. 60–120 agents.
- **Exit test:** 30 min free-roam at up to 300 km/h — zero physics pops, zero unfair traffic
  spawns, streaming never stalls the physics thread (instrumented).

### Phase 5 — Game loop slice (6–8 weeks)
- One street sprint event + one track-day at a small club circuit placed in the district,
  entered by driving there. Cash, one rival, tire wear + basic repair economy. Save/load
  including surface-state persistence.
- **Exit test:** a new player goes street race → earn → repair/tune → track day in one
  45-minute session without a menu teleport, and can articulate why the track felt different
  (rubber, tires, setup).

### Phase 6 — Evaluate & scale
- Now — and only now — decide: bigger map, car list, multiplayer (snapshot netcode; own-car
  prediction only), career depth, licensing. The physics core, telemetry, surface system, and
  streaming contracts from phases 0–5 are the moat; everything after is content production.

**Team-shape note:** phases 0–2 need 1–2 senior physics programmers + 1 vehicle-dynamics
tuner (or a very committed sim racer with telemetry literacy). Do not staff art before
phase 3; grey-box everything. The #1 killer of this genre-fusion is building the city first
and the tires last — this roadmap is the inverse, on purpose.

---

*End of blueprint. Companion implementation lives alongside this document; the ApexDyn
excerpt in §2.5 is the seed of the real module.*
