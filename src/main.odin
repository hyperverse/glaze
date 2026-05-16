// neko — a desktop cat pet for Wayland (Niri)
// Phase 3+4: Sprite rendering with animation loop
package neko

import wl "../deps/odin-wayland"
import layer "../protocols"
import "core:fmt"
import "core:c"
import "core:mem"
import "core:math"
import "core:sys/linux"
import "core:sys/posix"
import "base:runtime"
import stbi "vendor:stb/image"

// --- Constants ---
SPRITE_SIZE :: 128              // Sprite display size (scaled from source)
STRIDE      :: SPRITE_SIZE * 4  // 4 bytes per pixel (ARGB8888)
BUF_SIZE    :: STRIDE * SPRITE_SIZE

// Animation timing
FRAME_INTERVAL_MS :: 300   // ms between animation frames
WALK_SPEED        :: 2     // pixels per frame tick

// Chroma key color (green screen)
CHROMA_R :: 0
CHROMA_G :: 255
CHROMA_B :: 0
CHROMA_THRESHOLD :: 80     // distance threshold for chroma keying

// --- Sprite frame ---
Sprite_Frame :: struct {
	pixels: []u32,  // ARGB8888 premultiplied, SPRITE_SIZE x SPRITE_SIZE
}

// --- Cat state machine ---
Cat_State :: enum {
	Idle,
	Walking,
	Sleeping,
}

// --- Global state ---
State :: struct {
	display:       ^wl.display,
	compositor:    ^wl.compositor,
	shm:           ^wl.shm,
	layer_shell:   ^layer.layer_shell,
	output:        ^wl.output,

	wl_surface:    ^wl.surface,
	layer_surface: ^layer.layer_surface,
	configured:    bool,

	buffer:        ^wl.buffer,
	buf_data:      [^]u32,
	buf_fd:        posix.FD,

	running:       bool,
	closed:        bool,

	// Sprites
	idle_frame:    Sprite_Frame,
	walk_frames:   [2]Sprite_Frame,
	sleep_frame:   Sprite_Frame,

	// Animation
	cat_state:     Cat_State,
	anim_frame:    int,
	last_time_ms:  u32,

	// Position (within a virtual screen space — for now just walk back and forth)
	cat_x:         int,
	cat_dir:       int,  // 1 = right, -1 = left
	walk_timer:    int,  // ticks until state change
}

state: State
global_context: runtime.Context

// --- Sprite loading ---

load_sprite :: proc(path: cstring) -> (Sprite_Frame, bool) {
	w, h, channels: c.int
	data := stbi.load(path, &w, &h, &channels, 4)  // force RGBA
	if data == nil {
		fmt.eprintfln("error: failed to load sprite: %s", path)
		return {}, false
	}
	defer stbi.image_free(data)

	src_w := int(w)
	src_h := int(h)

	// Allocate the output buffer at SPRITE_SIZE x SPRITE_SIZE
	pixels := make([]u32, SPRITE_SIZE * SPRITE_SIZE)

	// Scale and convert: stbi gives RGBA, we need ARGB premultiplied
	for y in 0..<SPRITE_SIZE {
		for x in 0..<SPRITE_SIZE {
			// Nearest-neighbor sampling from source
			sx := x * src_w / SPRITE_SIZE
			sy := y * src_h / SPRITE_SIZE
			si := (sy * src_w + sx) * 4

			r := u32(data[si + 0])
			g := u32(data[si + 1])
			b := u32(data[si + 2])
			a := u32(data[si + 3])

			// Chroma key: if close to green, make transparent
			dr := int(r) - CHROMA_R
			dg := int(g) - CHROMA_G
			db := int(b) - CHROMA_B
			dist := math.sqrt(f64(dr*dr + dg*dg + db*db))
			if dist < CHROMA_THRESHOLD {
				a = 0
			}

			// Premultiply alpha
			r = r * a / 255
			g = g * a / 255
			b = b * a / 255

			// ARGB8888
			pixels[y * SPRITE_SIZE + x] = (a << 24) | (r << 16) | (g << 8) | b
		}
	}

	return Sprite_Frame{pixels = pixels}, true
}

load_all_sprites :: proc() -> bool {
	ok: bool

	state.idle_frame, ok = load_sprite("assets/sprites/idle.png")
	if !ok do return false
	fmt.println("  ✓ idle sprite loaded")

	state.walk_frames[0], ok = load_sprite("assets/sprites/walk1.png")
	if !ok do return false
	state.walk_frames[1], ok = load_sprite("assets/sprites/walk2.png")
	if !ok do return false
	fmt.println("  ✓ walk sprites loaded (2 frames)")

	state.sleep_frame, ok = load_sprite("assets/sprites/sleep.png")
	if !ok do return false
	fmt.println("  ✓ sleep sprite loaded")

	return true
}

// --- Registry listener ---

registry_global :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint, iface: cstring, version: uint) {
	context = global_context
	switch iface {
	case wl.compositor_interface.name:
		state.compositor = cast(^wl.compositor)wl.registry_bind(registry, name, &wl.compositor_interface, 4)
	case wl.shm_interface.name:
		state.shm = cast(^wl.shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
	case layer.layer_shell_interface.name:
		state.layer_shell = cast(^layer.layer_shell)wl.registry_bind(registry, name, &layer.layer_shell_interface, 4)
	case wl.output_interface.name:
		if state.output == nil {
			state.output = cast(^wl.output)wl.registry_bind(registry, name, &wl.output_interface, 4)
		}
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

registry_listener := wl.registry_listener{
	global        = registry_global,
	global_remove = registry_global_remove,
}

// --- Layer surface listener ---

layer_surface_configure :: proc "c" (
	data: rawptr,
	ls: ^layer.layer_surface,
	serial: u32,
	width: u32,
	height: u32,
) {
	context = global_context
	layer.layer_surface_ack_configure(ls, serial)

	if !state.configured {
		state.configured = true

		if !create_buffer() {
			state.running = false
			return
		}

		// Draw first frame and start animation loop
		draw_current_frame()
		wl.surface_attach(state.wl_surface, state.buffer, 0, 0)
		wl.surface_damage(state.wl_surface, 0, 0, SPRITE_SIZE, SPRITE_SIZE)

		// Request first frame callback
		request_frame()

		wl.surface_commit(state.wl_surface)
		fmt.println("✓ surface mapped with sprite!")
	}
}

layer_surface_closed :: proc "c" (data: rawptr, ls: ^layer.layer_surface) {
	context = global_context
	state.closed = true
	state.running = false
}

layer_surface_listener := layer.layer_surface_listener{
	configure = layer_surface_configure,
	closed    = layer_surface_closed,
}

// --- Frame callback (animation loop) ---

frame_done :: proc "c" (data: rawptr, callback: ^wl.callback, time_ms: uint) {
	context = global_context

	// Destroy the old callback
	wl.callback_destroy(callback)

	t := u32(time_ms)

	// Check if enough time has passed for an animation tick
	if state.last_time_ms == 0 {
		state.last_time_ms = t
	}

	elapsed := t - state.last_time_ms
	if elapsed >= FRAME_INTERVAL_MS {
		state.last_time_ms = t
		update_cat()
	}

	// Draw current frame
	draw_current_frame()

	// Submit the frame
	wl.surface_attach(state.wl_surface, state.buffer, 0, 0)
	wl.surface_damage(state.wl_surface, 0, 0, SPRITE_SIZE, SPRITE_SIZE)

	// Request next frame
	request_frame()

	wl.surface_commit(state.wl_surface)
}

frame_listener := wl.callback_listener{
	done = frame_done,
}

request_frame :: proc() {
	cb := wl.surface_frame(state.wl_surface)
	wl.callback_add_listener(cb, &frame_listener, nil)
}

// --- Cat state machine ---

update_cat :: proc() {
	state.walk_timer -= 1

	switch state.cat_state {
	case .Idle:
		// After some idle ticks, start walking or sleeping
		if state.walk_timer <= 0 {
			// Alternate between walking and sleeping
			if state.anim_frame % 4 == 3 {
				state.cat_state = .Sleeping
				state.walk_timer = 8  // sleep for 8 ticks
			} else {
				state.cat_state = .Walking
				state.walk_timer = 12 // walk for 12 ticks
				// Random direction
				if state.anim_frame % 2 == 0 {
					state.cat_dir = 1
				} else {
					state.cat_dir = -1
				}
			}
		}

	case .Walking:
		state.anim_frame += 1
		if state.walk_timer <= 0 {
			state.cat_state = .Idle
			state.walk_timer = 5
		}

	case .Sleeping:
		if state.walk_timer <= 0 {
			state.cat_state = .Idle
			state.walk_timer = 4
			state.anim_frame += 1
		}
	}
}

// --- Drawing ---

get_current_sprite :: proc() -> ^Sprite_Frame {
	switch state.cat_state {
	case .Idle:
		return &state.idle_frame
	case .Walking:
		return &state.walk_frames[state.anim_frame % 2]
	case .Sleeping:
		return &state.sleep_frame
	}
	return &state.idle_frame
}

draw_current_frame :: proc() {
	sprite := get_current_sprite()
	if sprite == nil || len(sprite.pixels) == 0 do return

	// Blit sprite into the SHM buffer
	for i in 0..<(SPRITE_SIZE * SPRITE_SIZE) {
		state.buf_data[i] = sprite.pixels[i]
	}
}

// --- Shared memory buffer ---

create_buffer :: proc() -> bool {
	name := fmt.caprintf("/neko_shm_%v", cast(uintptr)state.display)
	fd := posix.shm_open(name, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if fd < 0 {
		fmt.eprintfln("error: shm_open failed: %v", posix.errno())
		return false
	}
	posix.shm_unlink(name)
	state.buf_fd = fd

	ret := posix.ftruncate(auto_cast fd, auto_cast BUF_SIZE)
	if ret == .FAIL {
		fmt.eprintln("error: ftruncate failed")
		return false
	}

	data_raw, err := linux.mmap(0, BUF_SIZE, {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
	if err != .NONE {
		fmt.eprintfln("error: mmap failed: %v", err)
		return false
	}
	state.buf_data = cast([^]u32)data_raw

	pool := wl.shm_create_pool(state.shm, auto_cast fd, BUF_SIZE)
	state.buffer = wl.shm_pool_create_buffer(pool, 0, SPRITE_SIZE, SPRITE_SIZE, STRIDE, .argb8888)
	wl.shm_pool_destroy(pool)

	fmt.printfln("✓ buffer: %dx%d ARGB8888", SPRITE_SIZE, SPRITE_SIZE)
	return true
}

// --- Entry point ---

main :: proc() {
	global_context = context

	fmt.println("neko — Wayland desktop cat 🐱")
	fmt.println("==============================")

	// Load sprites first (before Wayland connection)
	fmt.println("\nloading sprites:")
	if !load_all_sprites() {
		fmt.eprintln("error: sprite loading failed")
		return
	}

	// Initialize cat state
	state.cat_state = .Idle
	state.cat_dir = 1
	state.walk_timer = 3
	state.anim_frame = 0

	// Connect to Wayland
	state.display = wl.display_connect(nil)
	if state.display == nil {
		fmt.eprintln("error: failed to connect to Wayland display")
		return
	}
	defer wl.display_disconnect(state.display)
	fmt.println("\n✓ connected to Wayland display")

	// Bind globals
	registry := wl.display_get_registry(state.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(state.display)

	if state.compositor == nil || state.shm == nil || state.layer_shell == nil {
		fmt.eprintln("error: missing required globals")
		return
	}
	fmt.println("✓ all globals bound")

	// Create surface
	state.wl_surface = wl.compositor_create_surface(state.compositor)

	// Click-through
	empty_region := wl.compositor_create_region(state.compositor)
	wl.surface_set_input_region(state.wl_surface, empty_region)
	wl.region_destroy(empty_region)

	// Layer surface on overlay
	state.layer_surface = layer.layer_shell_get_layer_surface(
		state.layer_shell,
		state.wl_surface,
		cast(^wl.output)nil,
		.overlay,
		"neko",
	)

	layer.layer_surface_set_size(state.layer_surface, SPRITE_SIZE, SPRITE_SIZE)
	layer.layer_surface_set_anchor(state.layer_surface, {.bottom, .right})
	layer.layer_surface_set_exclusive_zone(state.layer_surface, -1)
	layer.layer_surface_set_margin(state.layer_surface, 0, 60, 60, 0)
	layer.layer_surface_set_keyboard_interactivity(state.layer_surface, .none)

	layer.layer_surface_add_listener(state.layer_surface, &layer_surface_listener, nil)

	// Initial commit triggers configure
	wl.surface_commit(state.wl_surface)
	fmt.println("✓ waiting for configure...")

	// Event loop
	state.running = true
	for state.running {
		if wl.display_dispatch(state.display) < 0 {
			fmt.eprintln("error: display_dispatch failed")
			break
		}
	}

	// Cleanup
	if state.buffer != nil do wl.buffer_destroy(state.buffer)
	if state.buf_data != nil do linux.munmap(state.buf_data, BUF_SIZE)
	if state.buf_fd >= 0 do posix.close(state.buf_fd)
	if !state.closed do layer.layer_surface_destroy(state.layer_surface)
	wl.surface_destroy(state.wl_surface)

	// Free sprite memory
	delete(state.idle_frame.pixels)
	delete(state.walk_frames[0].pixels)
	delete(state.walk_frames[1].pixels)
	delete(state.sleep_frame.pixels)

	fmt.println("✓ neko exited cleanly")
}
