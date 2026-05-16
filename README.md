# neko 🐱

A desktop cat that wanders around your Wayland screen. Built in [Odin](https://odin-lang.org) as a standalone Wayland client using `wlr-layer-shell`.

Designed for [Niri](https://github.com/YaLTeR/niri), but should work on any compositor supporting `wlr-layer-shell-unstable-v1` (Sway, Hyprland, etc).

## Dependencies

```bash
sudo pacman -S odin wlr-protocols wayland
```

## Build & Run

```bash
chmod +x build.sh
./build.sh run
```

## Project Structure

```
src/         — application source (Odin)
protocols/   — hand-written wlr-layer-shell bindings
deps/        — vendored odin-wayland (git submodule)
assets/      — sprite sheets (coming soon)
```

## Status

Work in progress — learning project for Wayland and Odin.
