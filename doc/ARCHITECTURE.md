# neko — Architecture Guide

A walkthrough of `src/main.odin` and `protocols/wlr_layer_shell.odin` for anyone wanting to understand or extend the code.

---

## High-Level Flow

```
main()
  ├── load_all_sprites()         ← load PNGs, chroma key, premultiply
  ├── install_signal_handlers()  ← SIGINT/SIGTERM → clean exit
  ├── wl_display_connect()       ← connect to Wayland compositor
  ├── registry → bind globals    ← compositor, shm, layer_shell, output
  ├── create wl_surface          ← the drawable surface
  ├── set empty input region     ← click-through (mouse passes to windows below)
  ├── create layer_surface       ← fullscreen transparent overlay
  ├── wl_surface.commit()        ← triggers configure event
  └── event loop                 ← wl_display_dispatch() in a loop
        └── frame_done()         ← called ~60fps by compositor
              ├── update_cat()   ← state machine tick (every 250ms)
              ├── draw_frame()   ← clear old pos, blit sprite at new pos
              └── commit         ← push new buffer to compositor
```

---

## Module Responsibilities

### `src/main.odin` — everything in one file (for now)

The file is organized top-to-bottom in dependency order:

| Section | Lines | Purpose |
|---------|-------|---------|
| **Constants** | top | `SPRITE_SIZE`, timing, chroma key settings |
| **Types** | after constants | `Sprite_Frame`, `Cat_State` enum, `State` struct |
| **Global state** | `state`, `global_context` | Single global — intentional for Wayland C callbacks |
| **Signal handling** | `signal_handler`, `install_signal_handlers` | POSIX signal → `state.running = false` |
| **Sprite loading** | `load_sprite`, `load_all_sprites` | stb_image → chroma key → premultiplied ARGB8888 |
| **Registry listener** | `registry_global` | Binds compositor, shm, layer_shell, output |
| **Layer surface listener** | `layer_surface_configure` | Handles the configure/ack dance, creates buffer |
| **Frame callback** | `frame_done`, `request_frame` | Animation loop driven by compositor |
| **Cat AI** | `update_cat` | State machine with random transitions |
| **Drawing** | `get_current_sprite`, `draw_frame`, `clear_rect` | Sprite selection, blit, damage tracking |
| **SHM buffer** | `create_buffer` | `shm_open` → `mmap` → `wl_shm_pool` → `wl_buffer` |
| **Entry point** | `main` | Wires everything together |

### `protocols/wlr_layer_shell.odin` — hand-written Wayland bindings

Provides two Wayland interfaces that aren't in the base `odin-wayland` package:

| Interface | Purpose |
|-----------|---------|
| `zwlr_layer_shell_v1` | Factory — creates layer surfaces |
| `zwlr_layer_surface_v1` | The surface itself — configure, ack, set size/anchor/etc |

---

## Key Concepts

### Why a global `State` struct?

Wayland callbacks are C function pointers (`proc "c"`). They can't capture Odin closures or receive arbitrary context. The `data: rawptr` parameter exists but passing the whole state through it adds casts everywhere. A single global struct is the pragmatic choice (and what most C Wayland clients do).

The `global_context` variable is needed because Odin's `context` (allocator, logger) isn't available in `proc "c"` — we save it at the start of `main()` and restore it in every callback with `context = global_context`.

### The Wayland event lifecycle

```
1. main() creates surface, sets properties, calls commit()
2. Compositor sends configure event (with screen dimensions)
3. layer_surface_configure() acks, creates SHM buffer, draws first frame
4. Requests a frame callback → commit()
5. Compositor calls frame_done() when ready for next frame
6. frame_done() updates cat, redraws, requests next callback → commit()
7. Repeat 5-6 until signal or compositor closes surface
```

The frame callback is **compositor-driven** — it fires when the compositor is ready to composite a new frame (typically 60Hz). The animation tick inside is timer-gated at 250ms to keep the cat movement speed independent of refresh rate.

### SHM buffer (shared memory)

```
shm_open("/neko_shm_xxx")   → file descriptor
ftruncate(fd, size)          → set file size = width × height × 4
mmap(fd)                     → map into our address space → buf_data
wl_shm_create_pool(fd)      → tell compositor about the shared memory
wl_shm_pool_create_buffer() → carve a buffer from the pool
```

After this, `state.buf_data` and the compositor's view of the buffer are the **same memory**. Writing to `buf_data` + calling `commit()` is all that's needed to update the display.

Format is **ARGB8888 premultiplied** — each pixel is `(A<<24 | R<<16 | G<<8 | B)` where R,G,B are pre-multiplied by alpha: `R_out = R * A / 255`.

### Chroma key (green screen removal)

The AI-generated sprites have bright green (#00FF00) backgrounds. During loading, each pixel's distance from pure green is computed. If `sqrt(dR² + dG² + dB²) < 80`, the pixel is made fully transparent. This is a simple approach that works well enough for the prototype sprites.

### The fullscreen overlay approach

Instead of a small surface that moves (layer-shell doesn't support arbitrary positioning), we create a **fullscreen transparent surface**:

- `set_anchor({.top, .bottom, .left, .right})` — stretch to fill output
- `set_size(0, 0)` — let compositor pick dimensions
- `set_exclusive_zone(-1)` — don't push other windows
- Empty input region — all clicks pass through

The 1920×1080 buffer is ~8MB but we only write to the sprite-sized area each frame. Damage reporting tells the compositor which rectangles actually changed.

### Damage tracking

Each frame, we report two damaged rectangles:
1. **Previous position** — where the sprite was (now cleared to transparent)
2. **Current position** — where the sprite is now

This lets the compositor skip recompositing the ~99% of the surface that didn't change.

---

## Cat State Machine

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
- `get_current_sprite()` picks the sprite by state + direction

### Adding new states

To add a new state (e.g. `Peeking`):

1. Add to `Cat_State` enum
2. Add a sprite field to `State` (e.g. `peek_frame: Sprite_Frame`)
3. Load it in `load_all_sprites()`
4. Add transition logic in `update_cat()`
5. Add case in `get_current_sprite()`

### Adding animation frames per state

Currently each state has one sprite (walking has one per direction). To add multi-frame animation (e.g. 4-frame walk cycle):

1. Change `walk_right: Sprite_Frame` → `walk_right: [4]Sprite_Frame`
2. Load `walk_right_1.png` through `walk_right_4.png`
3. In `get_current_sprite()`: `return &state.walk_right[state.anim_frame % 4]`
4. Increment `anim_frame` in the Walking case of `update_cat()`

---

## Extending the Bindings

`protocols/wlr_layer_shell.odin` follows the exact pattern that `wayland-scanner private-code` generates in C. If you need to add bindings for another protocol:

1. Find the XML: `ls /usr/share/wayland-protocols/` or `/usr/share/wlr-protocols/`
2. Generate C reference: `wayland-scanner private-code foo.xml /dev/stdout`
3. Copy the type table, message arrays, and interface init pattern
4. Key rule: the message `signature` string and the `types` pointer offset must match exactly

The signature characters: `i`=int, `u`=uint, `s`=string, `o`=object, `n`=new_id, `a`=array, `h`=fd, `f`=fixed. `?` before `o` means nullable. A digit prefix means "since version N".
