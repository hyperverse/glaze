# glaze — a Wayland overlay framework 🖥️

A GPU-rendered transparent overlay framework for Wayland, built in [Odin](https://odin-lang.org). Uses `wlr-layer-shell` + EGL/OpenGL 3.3 to render fullscreen click-through overlays on any compatible compositor.

Designed for [Niri](https://github.com/YaLTeR/niri), but works on any compositor supporting `wlr-layer-shell-unstable-v1` (Sway, Hyprland, etc).

## Apps

### neko 🐱

A desktop cat that wanders around your screen. Walks, sleeps, idles — all with direction-aware sprites and a simple state machine.

```bash
./build.sh neko run
```

## Dependencies

```bash
sudo pacman -S odin mesa wayland wlr-protocols
```

## Build & Run

```bash
chmod +x build.sh
./build.sh neko run        # build and run the cat
./build.sh neko build      # just build
./build.sh neko debug      # build with debug symbols
```

The build script auto-discovers apps. Any directory with a `main.odin` is a valid target.

## Project Structure

```
overlay/     — shared framework (Wayland + EGL + layer-shell + frame loop)
neko/        — desktop cat app
protocols/   — hand-written wlr-layer-shell Odin bindings
deps/        — vendored odin-wayland (git submodule)
assets/      — sprite PNGs
bin/         — build output (gitignored)
```

## Writing a New App

Create a directory with a `main.odin`:

```odin
package myapp

import ov "../overlay"
import gl "vendor:OpenGL"

main :: proc() {
    ov.run({
        title      = "myapp",
        tick_ms    = 16,         // update every 16ms (~60fps)
        on_init    = my_init,    // GL context ready — load textures, compile shaders
        on_update  = my_update,  // called every tick_ms
        on_draw    = my_draw,    // called every frame
        on_cleanup = my_cleanup, // free GL resources
    })
}
```

Then build with `./build.sh myapp run`.

## Status

Work in progress — learning project for Wayland, EGL, and Odin.
