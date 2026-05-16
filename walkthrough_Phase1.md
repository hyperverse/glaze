# neko — Walkthrough

## What was built

A Wayland desktop cat pet project in Odin, targeting the Niri compositor. Phases 0 and 1 are complete.

### Project structure

```
/home/paul/work/fun/cat/
├── build.sh                              # Build script (build/debug/run/clean)
├── README.md                             # Project docs
├── .gitignore
├── src/
│   └── main.odin                         # Entry point — connects, discovers globals
├── protocols/
│   └── wlr_layer_shell.odin             # Hand-written layer-shell bindings
├── deps/
│   └── odin-wayland/                    # Git submodule
└── assets/
    └── reference/
        └── sprite_reference.png          # AI-generated sprite reference for artist
```

### Phase 0: Project Skeleton ✓

- Odin compiler (dev-2026-05) and `wlr-protocols` installed via pacman
- Git repo initialized with `odin-wayland` as a submodule
- **Hand-written `wlr-layer-shell-unstable-v1` bindings** — covers both protocol interfaces:
  - `zwlr_layer_shell_v1` — factory for creating layer surfaces (2 requests)
  - `zwlr_layer_surface_v1` — the surface itself (10 requests, 2 events)
  - All enums: `layer`, `anchor` (bit_set), `keyboard_interactivity`
  - Follows the exact same pattern as the upstream `odin-wayland/xdg/shell.odin` bindings
- Build compiles cleanly with `./build.sh build`

### Phase 1: Wayland Hello World ✓

Program connects to the Wayland display, discovers all Niri globals, and binds the four we need:

```
✓ connected to Wayland display
✓ wl_compositor bound (v6)
✓ wl_shm bound (v2)
✓ zwlr_layer_shell_v1 bound (v5)
✓ wl_output bound (v4)
🐱 all globals acquired — neko is ready!
✓ disconnected cleanly
```

### Sprite Reference

AI-generated sprite sheet reference for the artist — shows 4 animation sets (idle, walk, sleep, peek) for an orange tabby cat:

![Cat sprite reference sheet](file:///home/paul/work/fun/cat/assets/reference/sprite_reference.png)

## What's next

**Phase 2: Layer Surface** — create a visible overlay surface on the Niri desktop. This is the core Wayland plumbing: creating a `wl_surface`, requesting a layer surface from `zwlr_layer_shell_v1`, handling the configure/ack dance, allocating a shared memory buffer, and rendering a bright magenta rectangle on the overlay layer.
