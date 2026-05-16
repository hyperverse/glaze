# neko — A Wayland Desktop Cat in Odin

A desktop cat that wanders around the screen, sleeps, walks, and peeks around corners. Built as a standalone Wayland client in Odin, targeting Niri via `wlr-layer-shell`.

## Background

This is a learning side-project with two goals:
1. **Learn Wayland** — hands-on, from the protocol level (not abstracted by a toolkit)
2. **Learn Odin** — real project with meaningful C interop, manual memory management, and visual output

The cat runs as a standalone Wayland client using the `wlr-layer-shell` protocol to create a transparent overlay surface. It renders sprite animations via shared memory (`wl_shm`) and runs a simple state machine for cat behaviors.

> [!NOTE]
> DMS was considered as a host (it has a `"desktop"` plugin type), but that would abstract away all the Wayland learning. A standalone client is the right call here.

---

## System Dependencies

### Already installed
- `wayland` 1.25.0 — core Wayland client library
- `wayland-protocols` 1.48 — standard protocol extensions

### Need to install

| Package | Source | Purpose |
|---|---|---|
| `odin` | `pacman -S odin` (extra repo) | The Odin compiler |
| `wlr-protocols` | `pacman -S wlr-protocols` (extra repo) | Provides `wlr-layer-shell-unstable-v1.xml` |

```bash
sudo pacman -S odin wlr-protocols
```

> [!IMPORTANT]
> Both packages are in the official Arch `extra` repo — no AUR needed.

---

## Project Structure

```
/home/paul/work/fun/cat/
├── build.sh                    # Simple build script
├── README.md                   # Project documentation
│
├── src/                        # Application source
│   ├── main.odin               # Entry point, event loop
│   ├── wayland.odin            # Display connection, registry, globals
│   ├── surface.odin            # Layer surface creation & management
│   ├── shm.odin                # Shared memory buffer allocation
│   ├── renderer.odin           # Pixel blitting, sprite rendering
│   ├── cat.odin                # Cat state machine & behavior AI
│   └── sprite.odin             # Sprite sheet loading & frame indexing
│
├── deps/                       # Vendored dependencies (git submodules)
│   └── odin-wayland/           # yasinkaraaslan/odin-wayland
│
├── protocols/                  # Generated protocol bindings
│   └── wlr_layer_shell.odin   # Generated from XML via scanner
│
└── assets/                     # Sprite sheets & config
    └── cat/                    # Cat sprite frames
        ├── idle_*.png
        ├── walk_*.png
        ├── sleep_*.png
        └── peek_*.png
```

### Build command
```bash
odin build src/ -collection:deps=deps -collection:protocols=protocols -out:neko
```

---

## Proposed Changes — Phased Milestones

Each phase is a self-contained, testable milestone. You can stop at any phase and have something working.

---

### Phase 0: Project Skeleton & Toolchain

**Goal:** Verify Odin compiles, vendor dependencies, generate layer-shell bindings.

#### [NEW] [build.sh](file:///home/paul/work/fun/cat/build.sh)
- Build script wrapping the `odin build` command with collection flags
- Clean + build targets

#### [NEW] [README.md](file:///home/paul/work/fun/cat/README.md)
- Project description, build instructions, dependency list

#### Steps
1. Install `odin` and `wlr-protocols` via pacman
2. `git init` the project
3. Add `odin-wayland` as a git submodule in `deps/`
4. Use the odin-wayland scanner to generate `wlr_layer_shell.odin` from `/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml`
5. Write a trivial `main.odin` that prints "hello neko" to verify the toolchain

---

### Phase 1: Wayland Hello World

**Goal:** Connect to the Wayland display, bind core globals, prove lifecycle works.

#### [NEW] [src/main.odin](file:///home/paul/work/fun/cat/src/main.odin)
- Connect to `wl_display`
- Get `wl_registry`
- Bind `wl_compositor`, `wl_shm`, `zwlr_layer_shell_v1`
- Print discovered globals, then disconnect cleanly

#### What you learn
- Wayland display connection
- Registry and global binding
- Odin `foreign import` for `libwayland-client`
- The odin-wayland bindings API surface

---

### Phase 2: Layer Surface — A Colored Rectangle

**Goal:** Create a visible `wlr-layer-shell` surface on the overlay layer. Render a solid-color rectangle.

#### [NEW] [src/surface.odin](file:///home/paul/work/fun/cat/src/surface.odin)
- Create `wl_surface` via compositor
- Request `zwlr_layer_surface_v1` from layer shell
- Configure: overlay layer, no anchor (floating), fixed size (e.g. 64×64)
- Handle `configure` event → `ack_configure`

#### [NEW] [src/shm.odin](file:///home/paul/work/fun/cat/src/shm.odin)
- `memfd_create` → `ftruncate` → `mmap` for pixel buffer
- Create `wl_shm_pool` + `wl_buffer`
- Format: `WL_SHM_FORMAT_ARGB8888` (for transparency)

#### [NEW] [src/renderer.odin](file:///home/paul/work/fun/cat/src/renderer.odin)
- Fill buffer with a solid color (premultiplied alpha)
- `wl_surface.attach` + `wl_surface.commit`

#### What you learn
- Layer shell protocol flow (the hardest Wayland part)
- Shared memory buffer management
- Premultiplied alpha, pixel formats
- The configure/ack dance

> [!TIP]
> Start with a bright magenta rectangle so you can't miss it on screen. Once it appears on the overlay layer above your windows, you know the plumbing works.

---

### Phase 3: Sprite Rendering

**Goal:** Load a PNG sprite sheet and render individual frames into the buffer.

#### [NEW] [src/sprite.odin](file:///home/paul/work/fun/cat/src/sprite.odin)
- Load PNG files (Odin's `vendor:stb/image` or manual)
- Parse sprite sheet: grid of frames, indexed by animation + frame number
- Blit a single frame into the ARGB8888 buffer with alpha

#### [MODIFY] [src/renderer.odin](file:///home/paul/work/fun/cat/src/renderer.odin)
- Replace solid color fill with sprite frame blitting
- Clear buffer to transparent (0x00000000) before drawing
- Damage tracking: only mark changed region for compositor

#### What you learn
- Image loading in Odin (vendor libs or C interop)
- Pixel-level buffer manipulation
- Damage regions for efficient rendering

---

### Phase 4: Animation Loop

**Goal:** Animate the sprite — cycle through frames at a fixed rate.

#### [MODIFY] [src/main.odin](file:///home/paul/work/fun/cat/src/main.odin)
- Frame-based event loop using `wl_display_dispatch` + frame callbacks
- Target ~10-15 FPS (sprite animation doesn't need 60)
- Advance animation frame counter each tick

#### [MODIFY] [src/renderer.odin](file:///home/paul/work/fun/cat/src/renderer.odin)
- Double buffering: swap between two `wl_buffer`s to avoid tearing
- Request frame callback → render next frame on callback

#### What you learn
- Wayland frame callback mechanism
- Double buffering strategy
- Smooth animation timing

---

### Phase 5: Cat AI — State Machine & Movement

**Goal:** The cat *does things*. Wanders, sleeps, idles.

#### [NEW] [src/cat.odin](file:///home/paul/work/fun/cat/src/cat.odin)
- State enum: `Idle`, `Walking`, `Sleeping`, `Peeking`
- Transition rules with randomized timers:
  - `Idle` → (after 3-8s) → `Walking` or `Sleeping`
  - `Walking` → moves position → (after 2-5s) → `Idle`
  - `Sleeping` → (after 10-30s) → `Idle`
  - `Peeking` → (triggered near screen edge) → `Idle`
- Position tracking (x, y on screen)
- Movement velocity during walk state
- Screen bounds awareness (output geometry)

#### [MODIFY] [src/surface.odin](file:///home/paul/work/fun/cat/src/surface.odin)
- Update layer surface position based on cat state
- Or: use a fullscreen transparent overlay and blit cat at position within buffer

> [!WARNING]
> **Position approach choice needed:** Layer-shell surfaces can be anchored to screen edges but don't support arbitrary (x,y) positioning natively. Two approaches:
> 1. **Fullscreen transparent overlay** — one big transparent surface, blit cat sprite at (x,y) within it. Simple but wastes memory.
> 2. **Move via margins** — anchor to a corner and use `set_margin` to offset. Hacky but more memory-efficient.
>
> Recommend approach 1 (fullscreen overlay) for simplicity. The buffer is only `screen_width × screen_height × 4 bytes` ≈ 32MB for 4K, and you clear + redraw only the cat's bounding box each frame.

#### What you learn
- Simple game AI / state machines
- Screen geometry from Wayland outputs
- The positioning tradeoff in layer-shell

---

### Phase 6: Polish & Personality

**Goal:** Make the cat feel alive.

#### Enhancements (pick and choose)
- **Directional walking** — cat faces left/right based on movement
- **Edge awareness** — cat peeks around screen edges, hides partially off-screen
- **Yawn/stretch transitions** — intermediate animations between states
- **Gravity feel** — cat prefers bottom of screen, "sits" on the panel/bar area
- **Multi-monitor** — bind to `wl_output` events, pick a monitor
- **Niri IPC integration** — read `niri msg --json windows` to "sit on" window title bars (advanced, partially viable given Niri's limited position data)
- **Config file** — KDL or simple text file for speed, animation preferences

---

## Decisions (Resolved)

> [!NOTE]
> **Sprite assets:** AI-generated sketches first to establish the sprite poses/proportions. Then Paul's family member (professional artist) will redraw them as proper hand-drawn art. The AI sprites serve as reference/placeholder.

> [!NOTE]
> **Layer-shell bindings:** Hand-written. More educational, and the protocol is small (~15 structs/functions). No scanner dependency.

> [!NOTE]
> **Scope:** Phased approach approved. Phases 0–4 = learning core, Phase 5 = cat AI, Phase 6 = polish.

---

## Verification Plan

### Per-Phase Testing
| Phase | Verification |
|---|---|
| 0 | `odin build` succeeds, `./neko` prints hello |
| 1 | Program prints discovered Wayland globals and exits cleanly |
| 2 | A colored rectangle appears as an overlay on the Niri desktop |
| 3 | A cat sprite frame appears instead of the rectangle |
| 4 | The cat sprite animates (cycles frames) |
| 5 | The cat wanders, sleeps, and transitions between states |
| 6 | Feels polished and alive |

### Manual Verification
- Each phase: run `./neko` on your Niri session, observe the desktop
- Check Niri layer rules if the overlay doesn't appear: may need `layer-rule` in `config.kdl`

---

## Learning Resources

These will be useful as you work through the phases:

| Resource | What it covers |
|---|---|
| [The Wayland Book](https://wayland-book.com) | Best intro to the Wayland protocol, covers everything through Phase 2 |
| [wayland.app](https://wayland.app) | Protocol reference — look up any interface/event/request |
| [odin-wayland repo](https://github.com/yasinkaraaslan/odin-wayland) | Binding API, examples, scanner |
| [Odin overview](https://odin-lang.org/docs/overview/) | Language reference |
| [wlr-layer-shell XML](file:///usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml) | The protocol source of truth (after installing `wlr-protocols`) |
