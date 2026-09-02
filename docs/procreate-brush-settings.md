# Procreate's brush settings, as a taxonomy

Transcribed from a Procreate 5.x brush studio (Spanish UI), one brush, by
octolex. Spanish names are kept alongside the English, because the Spanish is
what was actually observed and translating twice loses information.

**Caveat, stated by the person who collected it:** this is *one* brush, and
some settings appear or change meaning depending on other settings. Treat it
as the shape of the space, not a complete specification.

Why it is here: `core/include/core/brush.h` says the taxonomy is the expensive
thing to change and the individual fields are cheap. This is the reference for
getting the taxonomy right before the brush editor is built on top of it.

Legend: ✅ we have it · 🔶 partial · ⬜ missing

---

## Trayectoria del trazo — Stroke path

| | Setting | Type |
|---|---|---|
| ✅ | Espaciado — Spacing | percentage |
| ⬜ | Variación de espaciado — Spacing jitter | percentage |
| ✅ | Variación lateral — Lateral jitter (our `scatter`) | percentage |
| ⬜ | Variación lineal — Linear jitter (along the path) | percentage |
| ⬜ | Desvanecer — Fade | option |

## Estabilización — Stabilization

| | Setting | Type |
|---|---|---|
| 🔶 | StreamLine → Cantidad — Amount (our `smoothing`) | percentage |
| ⬜ | StreamLine → Presión — Pressure | percentage |
| ⬜ | Estabilización → Cantidad — Amount | percentage |
| ⬜ | Filtro de movimiento → Cantidad, Expresión | percentage |

Three *separate* smoothing mechanisms, not one. We have a single `smoothing`
that corresponds to StreamLine.

## Ahusamiento — Taper

| | Setting | Type |
|---|---|---|
| 🔶 | Ahusamiento con presión — Pressure taper | **Vector2D** |
| ⬜ | Ahusamiento con toque — Touch taper | **Vector2D** |
| ⬜ | Vincular tamaños de puntas — Link tip sizes | bool |
| 🔶 | Tamaño — Size | percentage |
| ⬜ | Opacidad — Opacity | percentage |
| ⬜ | Presión — Pressure | maximum level |
| ⬜ | Punta — Tip | choice |
| ⬜ | Animación de punta — Tip animation | bool |
| ⬜ | Ahusamiento clásico — Classic taper | bool |

Taper is a **Vector2D** (start and end as one control), and start/end are
separate for pressure versus touch. We have three scalars and no touch/pressure
split.

## Forma — Shape

| | Setting | Type |
|---|---|---|
| ⬜ | Origen de forma — Shape source | texture |
| ⬜ | Estilo de entrada — Input style | enum: Touch only, Angle, Angle + rotation |
| ⬜ | Relativa al trazo — Relative to stroke | bool |
| ✅ | Rotación / Giro — Rotation / Spin | percentage |
| ⬜ | Número — Count | integer |
| ⬜ | Variación de número — Count jitter | percentage |
| ⬜ | Aleatorio — Random | bool |
| ⬜ | Voltear X / Y — Flip X / Y | bool |
| ✅ | Redondez — Roundness (ellipse widget) | ellipse control |
| ⬜ | Redondez por presión — Roundness by pressure | percentage |
| ⬜ | Redondez con inclinación — Roundness by tilt | percentage |
| ⬜ | Variación vertical / horizontal de redondez | percentage |
| ⬜ | Filtrado de forma — Shape filtering | enum: None, Classic, Improved |

**Count** is the notable gap: Procreate stamps *N* shapes per dab.

## Grano — Grain

| | Setting | Type |
|---|---|---|
| 🔶 | Origen del grano — Grain source | texture (ours is generated, not chosen) |
| ✅ | Comportamiento del grano — Grain behaviour | enum: **Movimiento, Texturizado** |
| ⬜ | Movimiento — Movement *amount* | percentage |
| 🔶 | Escala — Scale | percentage (ours is canvas px) |
| ⬜ | Zoom | percentage |
| ⬜ | Rotación — Rotation | percentage |
| ✅ | Profundidad — Depth | percentage |
| ⬜ | Profundidad mínima — Minimum depth | percentage |
| ⬜ | Variación de profundidad — Depth jitter | percentage |
| ⬜ | Variación de diferencia — Difference jitter | bool |
| ⬜ | **Modo de fusión — Blend mode** | blend mode enum |
| ⬜ | Brillo — Brightness | percentage |
| ⬜ | Contraste — Contrast | percentage |
| ⬜ | Filtrado de grano — Grain filtering | enum: None, Classic, Improved |

**Our two anchoring modes match Procreate's exactly** — Movimiento/Texturizado
is Rolling/Canvas. But Movement is also an *amount*, so the scroll rate is a
parameter rather than locked 1:1 to arc length as ours is.

**Grain composites through a blend mode.** Ours multiplies, which is one mode
of many, and is why a grained stroke currently reads as a uniform veil.

## Renderizado — Rendering

| | Setting | Type |
|---|---|---|
| ⬜ | **Estilo de renderizado — Rendering style** | enum: Light / Uniform / Intense / Heavy Glaze, Uniform / Intense Blending |
| 🔶 | Flujo — Flow | **maximum level** |
| ⬜ | Bordes húmedos — Wet edges | percentage |
| ⬜ | Bordes quemados — Burnt edges (+ mode) | percentage, blend mode |
| ⬜ | Modo de fusión — Blend mode | blend mode enum |
| ⬜ | Fusión de luminancia — Luminance blend | bool |
| ⬜ | **Umbral alfa — Alpha threshold** | bool |
| ⬜ | **Cantidad de umbral — Threshold amount** | percentage |
| ⬜ | Modo de combinación normal clásico | bool |

**There is no Maximum/Buildup switch.** Accumulation is expressed as a
*rendering style* with six named values, and Flow is a "maximum level" rather
than a plain slider. Our binary switch is a cruder cut through the same space.

**Alpha threshold** is the mechanism that makes grain read as tooth rather than
as a veil: coverage is thresholded against the grain rather than scaled by it.

## Mezcla húmeda — Wet mix

Dilución, Cantidad, Ataque, Arrastre, Grado, Desenfoque, Variación de
desenfoque, Variación de humedad. All ⬜ — this is a whole wet-media simulation
we have not started.

## Dinámica de color — Color dynamics

Stamp colour jitter, stroke colour jitter, colour by pressure, colour by tilt,
colour by rotation — each with Hue / Saturation / Brightness / Darkness /
Secondary colour. All ⬜.

## Dinámica — Dynamics

| | Setting | Type |
|---|---|---|
| ✅ | Velocidad → Tamaño — Speed → Size | percentage |
| 🔶 | Velocidad → Opacidad — Speed → Opacity | percentage |
| ⬜ | Velocidad → Espaciado — Speed → Spacing | percentage |
| ✅ | Variación → Tamaño — Jitter → Size | percentage |
| ✅ | Variación → Opacidad — Jitter → Opacity | percentage |

## Apple Pencil

| | Setting | Type |
|---|---|---|
| ⬜ | Presión — Pressure | **pressure graph widget** |
| ✅ | Presión → Tamaño, Opacidad, Flujo | percentage |
| ⬜ | Inclinación — Tilt | **tilt view widget** |
| 🔶 | Inclinación → Opacidad, Degradado, Flujo, Tamaño | percentage |
| ⬜ | Compresión de tamaño — Size compression | bool |
| ⬜ | Rotación → Tamaño, Opacidad, Flujo | percentage |
| ⬜ | Contorno del puntero — Cursor outline | enum: None, Contrast, Active colour |
| ⬜ | Flotante → Presión estimada — Hover estimated pressure | percentage |
| ⬜ | Relleno flotante — Hover fill | enum: None, Shape, All |

**Pressure is a graph, not a slider.** This confirms the note already in
ROADMAP.md: our exponent-based `Response.curve` has to become a spline before a
brush editor exposes it.

## Propiedades — Properties

| | Setting | Type |
|---|---|---|
| ⬜ | Orientar con la pantalla — Orient to screen | bool |
| ⬜ | Fuerza de dedo — Finger strength | percentage |
| ✅ | Tamaño máximo / mínimo — Max / min size | percentage |
| 🔶 | Opacidad máxima — Max opacity | maximum level |
| ⬜ | Opacidad mínima — Min opacity | percentage |

## Materiales, Vista previa, Acerca de

3D metallic/roughness maps, a live preview box, and brush metadata with a reset
point. All ⬜, and none of it is on our path.

---

## What this changes for us

1. **Grain anchoring is right.** Movimiento/Texturizado is Rolling/Canvas.
2. **Grain needs a blend mode, not a multiply.** Plus brightness and contrast
   on the map, and a minimum depth.
3. **Alpha threshold is the missing mechanism** for grain that bites at the
   edges instead of veiling the whole stroke.
4. **Maximum/Buildup should become a rendering style.** Procreate has no such
   toggle; it has six named styles and Flow as a ceiling.
5. **The pressure response must become a spline.** It is a graph in Procreate,
   and our exponent cannot express what a graph can.
6. **Taper is a Vector2D, split by pressure versus touch.**
7. **Shape has a Count.** N stamps per dab, with jitter and randomisation.
