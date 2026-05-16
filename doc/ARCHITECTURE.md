# Architecture Guide

A walkthrough of the codebase for anyone wanting to understand or extend it.

---

## Project Layout

```
overlay/                 ← shared framework package
├── overlay.odin         ← Wayland lifecycle, EGL init, frame loop
└── egl.odin             ← minimal EGL FFI bindings

neko/                    ← desktop cat app
└── main.odin            ← cat AI, sprites, GL setup, drawing

protocols/               ← hand-written Wayland protocol bindings
└── wlr_layer_shell.odin ← zwlr_layer_shell_v1 + zwlr_layer_surface_v1

deps/odin-wayland/       ← vendored Wayland client bindings (git submodule)
```

---

## The Overlay Framework (`overlay/`)

The framework handles everything needed to create a fullscreen, transparent, click-through, GPU-rendered overlay on Wayland. Apps just provide 4 callbacks.

### App Interface

```odin
overlay.App :: struct {
    title:      cstring,   // layer-shell namespace
    tick_ms:    u32,       // animation tick interval (0 = every frame)
    on_init:    proc(screen_w, screen_h: int) -> bool,
    on_update:  proc(),    // called every tick_ms
    on_draw:    proc(),    // called every frame (GL context current)
    on_cleanup: proc(),    // called before teardown
}
```

### Lifecycle

```
overlay.run(app)
  ├── install_signal_handlers()    ← SIGINT/SIGTERM → clean exit
  ├── wl_display_connect()         ← connect to compositor
  ├── registry → bind globals      ← compositor, layer_shell, output
  ├── create wl_surface            ← the drawable surface
  ├── set empty input region       ← click-through
  ├── create layer_surface         ← fullscreen transparent overlay
  ├── wl_surface.commit()          ← triggers configure event
  │
  │   configure event:
  │   ├── init_egl()               ← EGL display/surface/context, GL 3.3 core
  │   ├── app.on_init(w, h)        ← app loads textures, compiles shaders
  │   ├── app.on_draw()            ← first frame
  │   ├── request_frame()          ← register callback BEFORE commit
  │   └── eglSwapBuffers()         ← presents frame (calls wl_surface_commit)
  │
  └── event loop
        └── frame_done()           ← compositor-driven (~60fps)
              ├── app.on_update()  ← every tick_ms
              ├── app.on_draw()    ← every frame
              ├── request_frame()  ← BEFORE swap
              └── eglSwapBuffers() ← present + commit
```

### Why a global state?

Wayland callbacks are C function pointers (`proc "c"`). They can't capture Odin closures or receive arbitrary context. A single global struct in the overlay package is the pragmatic choice (and what most C Wayland clients do).

The `global_context` variable stores Odin's runtime context (allocator, logger) at startup. Every `proc "c"` callback restores it with `context = global_context`.

### EGL Rendering Pipeline

The framework creates a transparent GL context on the Wayland surface:

```
wl_display → eglGetDisplay → eglInitialize
           → eglChooseConfig (RGBA8, ALPHA_SIZE=8)
           → wl_egl_window_create(wl_surface, w, h)
           → eglCreateWindowSurface
           → eglCreateContext (OpenGL 3.3 core)
           → eglMakeCurrent
           → gl.load_up_to(3, 3, eglGetProcAddress)
```

Key details:
- **`EGL_ALPHA_SIZE = 8`** is critical — without it the overlay is opaque
- **`eglSwapBuffers`** calls `wl_surface_commit()` internally — don't double-commit
- **Frame callbacks** must be registered BEFORE `eglSwapBuffers` or they deadlock
- **Premultiplied alpha**: Wayland expects premultiplied, so use `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`

### The Fullscreen Overlay Approach

Instead of a small surface that moves (layer-shell doesn't support arbitrary positioning), the framework creates a fullscreen transparent surface:

- `set_anchor({.top, .bottom, .left, .right})` — stretch to fill output
- `set_size(0, 0)` — let compositor pick dimensions
- `set_exclusive_zone(-1)` — don't push other windows
- Empty input region — all clicks pass through

### Signal Handling

SIGINT and SIGTERM set `ctx.running = false`. The event loop checks this flag each time `wl_display_dispatch` returns (which happens every frame thanks to the compositor-driven frame callback).

---

## Neko App (`neko/`)

The cat app implements the 4 overlay callbacks:

### Sprites & Chroma Key

AI-generated sprites have green (#00FF00) backgrounds. During `on_init`, each sprite is:
1. Loaded via `stb_image`
2. Scaled to 128×128
3. Chroma keyed (pixels within distance 80 of pure green → transparent)
4. Premultiplied (R,G,B multiplied by alpha)
5. Uploaded to a GL texture via `glTexImage2D`

### Cat State Machine

```
        ┌─────────┐
        │  Idle    │ ← initial state
        │ (3-10t) │
        └────┬────┘
             │ timer expires
     ┌───────┴───────┐
     │ roll d10      │
     │ 0-5: walk     │
     │ 6-9: sleep    │
     └───┬───────┬───┘
         ▼       ▼
    ┌─────────┐ ┌──────────┐
    │ Walking │ │ Sleeping │
    │(15-40t) │ │ (10-25t) │
    │ move 3px│ │          │
    │ per tick│ │          │
    └────┬────┘ └────┬─────┘
         │           │
         └─────┬─────┘
               │ timer expires
               ▼
         ┌─────────┐
         │  Idle    │
         └─────────┘
```

- **t** = animation tick = 250ms
- Walking moves `cat_x` by `WALK_SPEED * cat_dir` each tick
- Bounces off screen edges (reverses `cat_dir`)
- Sprite selected by state + direction

### GL Rendering

Each frame:
1. `glClear` with transparent black
2. Bind the sprite texture for current state/direction
3. Set `u_translate` uniform to `(cat_x, cat_y)`
4. Draw a textured quad (two triangles)

The vertex shader converts pixel coordinates to NDC using a `u_screen` uniform.

### Adding New States

1. Add to `Cat_State` enum
2. Add a `Sprite_Frame` field to `Cat`
3. Load it in `neko_init`
4. Add transition logic in `neko_update`
5. Add case in `neko_draw`

---

## Extending the Protocol Bindings

`protocols/wlr_layer_shell.odin` follows the exact pattern that `wayland-scanner private-code` generates in C. If you need to add bindings for another protocol:

1. Find the XML: `ls /usr/share/wayland-protocols/` or `/usr/share/wlr-protocols/`
2. Generate C reference: `wayland-scanner private-code foo.xml /dev/stdout`
3. Copy the type table, message arrays, and interface init pattern
4. Key rule: the message `signature` string and the `types` pointer offset must match exactly

The signature characters: `i`=int, `u`=uint, `s`=string, `o`=object, `n`=new_id, `a`=array, `h`=fd, `f`=fixed. `?` before `o` means nullable. A digit prefix means "since version N".

---

## Writing a New App

To create a new overlay app (e.g. matrix rain):

1. Create `matrix/main.odin` with `package matrix`
2. Import `ov "../overlay"` and `gl "vendor:OpenGL"`
3. Implement `on_init`, `on_update`, `on_draw`, `on_cleanup`
4. Call `ov.run({...})` in `main`
5. Build with `./build.sh matrix run`

The framework handles all Wayland, EGL, and lifecycle concerns. Your app only needs to make GL calls.
