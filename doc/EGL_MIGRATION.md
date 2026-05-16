# EGL Migration Plan

Migrate neko's rendering from CPU-based `wl_shm` to GPU-based EGL/OpenGL. This preserves the entire Wayland surface/layer-shell architecture and cat AI — only the buffer pipeline changes.

---

## Why

- GPU rendering unlocks shader effects (glow, blur, shadows, color grading)
- Hardware-accelerated scaling, rotation, and alpha blending
- Foundation for future transparent overlay projects beyond neko
- DMA-BUF path avoids CPU↔GPU copies entirely

## What stays the same

- `wl_display_connect`, registry, global binding
- `zwlr_layer_shell_v1` — layer surface creation, configure/ack, anchors
- Empty input region (click-through)
- Signal handling (SIGINT/SIGTERM)
- Cat state machine, sprite selection, animation timer
- Frame callback loop structure (`wl_surface.frame`)

## What changes

| Current (SHM) | New (EGL/OpenGL) |
|---|---|
| `wl_shm` global | Not needed — remove binding |
| `shm_open` + `mmap` + `wl_shm_pool` + `wl_buffer` | `wl_egl_window` + EGL display/surface/context |
| `state.buf_data[y*w+x] = pixel` | `glTexImage2D` + textured quad |
| `wl_surface_attach(buffer)` + `wl_surface_commit()` | `eglSwapBuffers()` (handles attach+commit) |
| Chroma key in `load_sprite()` | Still needed, but output goes to GL texture instead of pixel array |
| `clear_rect()` per-pixel zeroing | `glClear(GL_COLOR_BUFFER_BIT)` |
| Manual damage tracking | EGL/compositor handle this automatically |

---

## Step-by-step migration

### Step 1: Install dependencies

```bash
# Should already be present on Arch with Niri, but verify:
pacman -Q mesa wayland
# Need the dev headers for linking:
# libwayland-egl.so, libEGL.so, libGL.so (all part of mesa)
```

### Step 2: Write `wayland-egl` bindings (~10 lines)

The `wayland-egl` API is tiny — just 3 functions. Create `src/wl_egl.odin`:

```odin
package neko

import wl "../deps/odin-wayland"
import "core:c"

foreign import wl_egl_lib "system:wayland-egl"

@(default_calling_convention = "c")
foreign wl_egl_lib {
    wl_egl_window_create  :: proc(surface: ^wl.surface, w: c.int, h: c.int) -> rawptr ---
    wl_egl_window_destroy :: proc(window: rawptr) ---
    wl_egl_window_resize  :: proc(window: rawptr, w: c.int, h: c.int, dx: c.int, dy: c.int) ---
}
```

### Step 3: Write EGL bindings (~80 lines)

Check if Odin's `vendor:EGL` exists on your system:

```bash
ls /usr/lib/odin/vendor/EGL/ 2>/dev/null
```

If not, write minimal EGL bindings in `src/egl.odin`. Only these functions are needed:

```
eglGetDisplay            — get EGL display from wl_display
eglInitialize            — init EGL
eglChooseConfig          — pick a visual config (RGBA8888 with alpha)
eglCreateContext         — create OpenGL ES context
eglCreateWindowSurface   — bind to wl_egl_window
eglMakeCurrent           — activate context
eglSwapBuffers           — present frame (this commits to Wayland)
eglDestroySurface        — cleanup
eglDestroyContext        — cleanup
eglTerminate             — cleanup
```

Key EGL config attributes for transparent overlay:
```c
EGL_RED_SIZE,   8,
EGL_GREEN_SIZE, 8,
EGL_BLUE_SIZE,  8,
EGL_ALPHA_SIZE, 8,    // ← critical for transparency
EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
EGL_NONE
```

The `EGL_ALPHA_SIZE = 8` is what makes the overlay transparent — without it, the compositor treats the surface as opaque.

### Step 4: Write OpenGL bindings or use `vendor:OpenGL`

Check availability:
```bash
ls /usr/lib/odin/vendor/OpenGL/ 2>/dev/null
```

Odin's `vendor:OpenGL` should work. You only need a small subset:

```
glClearColor, glClear
glEnable(GL_BLEND), glBlendFunc
glGenTextures, glBindTexture, glTexImage2D, glTexParameteri
glUseProgram, glVertexAttribPointer, glDrawArrays
```

If using OpenGL ES 2.0 (recommended for Wayland), you'll write a minimal shader pair:

**Vertex shader** (~10 lines):
```glsl
attribute vec2 a_pos;
attribute vec2 a_uv;
varying vec2 v_uv;
uniform mat4 u_projection;
uniform vec2 u_translate;
void main() {
    gl_Position = u_projection * vec4(a_pos + u_translate, 0.0, 1.0);
    v_uv = a_uv;
}
```

**Fragment shader** (~5 lines):
```glsl
precision mediump float;
varying vec2 v_uv;
uniform sampler2D u_texture;
void main() {
    gl_FragColor = texture2D(u_texture, v_uv);
}
```

### Step 5: Restructure `main.odin`

Replace the SHM sections. The new flow in `main()`:

```
main()
  load_all_sprites()           ← same, but output stays as byte arrays
  install_signal_handlers()    ← same
  wl_display_connect()         ← same
  bind globals                 ← remove wl_shm, keep compositor + layer_shell
  create wl_surface            ← same
  set input region             ← same
  create layer_surface         ← same
  configure/ack                ← same

  ── NEW: EGL setup ──
  egl_display = eglGetDisplay(wl_display)
  eglInitialize(egl_display)
  eglChooseConfig(... ALPHA_SIZE=8 ...)
  egl_window = wl_egl_window_create(wl_surface, width, height)
  egl_surface = eglCreateWindowSurface(egl_display, config, egl_window)
  egl_context = eglCreateContext(egl_display, config, ...)
  eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context)

  ── NEW: GL setup ──
  compile shaders, create program
  upload sprite textures via glTexImage2D (one texture per sprite)
  set up a quad VBO (two triangles, 6 vertices)
  set up orthographic projection matrix

  ── frame loop (same structure) ──
  frame_done callback:
      update_cat()                     ← same
      glClearColor(0, 0, 0, 0)        ← transparent clear
      glClear(GL_COLOR_BUFFER_BIT)
      bind current sprite texture
      set u_translate = (cat_x, cat_y)
      glDrawArrays(GL_TRIANGLES, ...)
      eglSwapBuffers()                 ← replaces attach+damage+commit
      request next frame callback

  ── cleanup ──
  eglDestroySurface, eglDestroyContext, eglTerminate
  wl_egl_window_destroy
  layer_surface_destroy, surface_destroy
```

### Step 6: Modify `layer_surface_configure`

The configure handler now creates the EGL window instead of the SHM buffer:

```odin
layer_surface_configure :: proc "c" (...) {
    layer.layer_surface_ack_configure(ls, serial)
    if !state.configured {
        state.configured = true
        state.screen_w = int(width)
        state.screen_h = int(height)

        // NEW: create EGL window + surface
        init_egl()

        // NEW: compile shaders, upload textures
        init_gl()

        // Draw first frame
        draw_frame_gl()
        eglSwapBuffers(state.egl_display, state.egl_surface)

        request_frame()
    }
}
```

### Step 7: Modify `load_sprite`

Keep the stb_image loading and chroma key logic, but instead of storing an `[]u32` pixel array, upload to a GL texture:

```odin
Sprite_Frame :: struct {
    texture: u32,  // GL texture ID (was: pixels []u32)
    width:   int,
    height:  int,
}

load_sprite :: proc(path: cstring) -> (Sprite_Frame, bool) {
    // ... same stb_image load + chroma key ...
    // ... same premultiply alpha ...

    // Instead of returning pixels, upload to GPU:
    tex: u32
    glGenTextures(1, &tex)
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA,
                 SPRITE_SIZE, SPRITE_SIZE, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, raw_data(pixels))
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)

    delete(pixels)  // CPU-side data no longer needed
    return Sprite_Frame{texture = tex}, true
}
```

### Step 8: Remove SHM code

Delete from `main.odin`:
- `create_buffer()` proc entirely
- `state.buffer`, `state.buf_data`, `state.buf_fd` fields
- `clear_rect()` proc
- `posix.shm_open`, `linux.mmap`, `posix.ftruncate` imports
- `wl.shm` binding in registry listener

---

## File plan after migration

```
src/
├── main.odin          ← cat AI + Wayland lifecycle + GL draw loop
├── wl_egl.odin        ← wayland-egl FFI (3 functions)
├── egl.odin           ← EGL FFI (~15 functions + constants)
└── shaders.odin       ← vertex + fragment shader source strings

protocols/
└── wlr_layer_shell.odin  ← unchanged
```

## Risk areas

1. **EGL config with alpha** — must request `EGL_ALPHA_SIZE = 8` or the overlay is opaque. This is the #1 mistake people make.
2. **Premultiplied alpha** — Wayland expects premultiplied. OpenGL's default blend is `GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA` (straight alpha). For premultiplied: `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`.
3. **EGL platform** — use `eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wl_display, ...)` if available, otherwise `eglGetDisplay(wl_display)` works on mesa.
4. **Frame callback + eglSwapBuffers** — `eglSwapBuffers` already calls `wl_surface.commit()` internally. You still need `wl_surface.frame()` for throttling, but don't call `wl_surface_commit()` manually or you'll double-commit.
5. **wl_egl_window lifetime** — must be created after `wl_surface` but before `eglCreateWindowSurface`. Destroyed after EGL surface is destroyed.

## Estimated effort

| Task | Lines | Difficulty |
|------|-------|-----------|
| `wl_egl.odin` bindings | ~15 | Easy |
| `egl.odin` bindings | ~80 | Medium (constants, types) |
| EGL init/teardown | ~50 | Medium |
| GL shader setup | ~60 | Medium |
| GL draw loop | ~30 | Easy |
| Remove SHM code | -80 | Easy |
| **Net change** | ~+155 | — |

The bindings are the tedious part. The actual rendering logic gets *simpler* — `glClear` + bind texture + draw quad + swap replaces the manual pixel loops.
