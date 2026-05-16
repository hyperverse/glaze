// neko — a desktop cat pet for Wayland (Niri)
// Phase 5: Fullscreen overlay with cat AI and movement
package neko

import wl "../deps/odin-wayland"
import layer "../protocols"
import "core:fmt"
import "core:c"
import "core:math"
import "core:math/rand"
import "core:sys/linux"
import "core:sys/posix"
import "base:runtime"
import stbi "vendor:stb/image"

// --- Constants ---
SPRITE_SIZE :: 128  // Each sprite frame is 128x128 after scaling

// Animation timing
FRAME_INTERVAL_MS :: 250   // ms between animation ticks
WALK_SPEED        :: 3     // pixels per animation tick

// Chroma key
CHROMA_R :: 0
CHROMA_G :: 255
CHROMA_B :: 0
CHROMA_THRESHOLD :: 80

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

	// Fullscreen buffer
	buffer:        ^wl.buffer,
	buf_data:      [^]u32,
	buf_fd:        posix.FD,
	screen_w:      int,
	screen_h:      int,

	running:       bool,
	closed:        bool,

	// Sprites
	idle_frame:    Sprite_Frame,
	walk_frames:   [2]Sprite_Frame,
	sleep_frame:   Sprite_Frame,

	// Animation state
	cat_state:     Cat_State,
	anim_frame:    int,
	last_time_ms:  u32,
	state_timer:   int,      // ticks remaining in current state

	// Position & direction
	cat_x:         int,      // top-left x of sprite on screen
	cat_y:         int,      // top-left y of sprite on screen
	cat_dir:       int,      // 1 = right, -1 = left
	prev_x:        int,      // previous position for damage tracking
	prev_y:        int,
}

state: State
global_context: runtime.Context

// --- Sprite loading ---

load_sprite :: proc(path: cstring) -> (Sprite_Frame, bool) {
	w, h, channels: c.int
	data := stbi.load(path, &w, &h, &channels, 4)
	if data == nil {
		fmt.eprintfln("error: failed to load sprite: %s", path)
		return {}, false
	}
	defer stbi.image_free(data)

	src_w := int(w)
	src_h := int(h)
	pixels := make([]u32, SPRITE_SIZE * SPRITE_SIZE)

	for y in 0..<SPRITE_SIZE {
		for x in 0..<SPRITE_SIZE {
			sx := x * src_w / SPRITE_SIZE
			sy := y * src_h / SPRITE_SIZE
			si := (sy * src_w + sx) * 4

			r := u32(data[si + 0])
			g := u32(data[si + 1])
			b := u32(data[si + 2])
			a := u32(data[si + 3])

			// Chroma key
			dr := int(r) - CHROMA_R
			dg := int(g) - CHROMA_G
			db := int(b) - CHROMA_B
			dist := math.sqrt(f64(dr*dr + dg*dg + db*db))
			if dist < CHROMA_THRESHOLD {
				a = 0
			}

			// Premultiply
			r = r * a / 255
			g = g * a / 255
			b = b * a / 255

			pixels[y * SPRITE_SIZE + x] = (a << 24) | (r << 16) | (g << 8) | b
		}
	}

	return Sprite_Frame{pixels = pixels}, true
}

load_all_sprites :: proc() -> bool {
	ok: bool

	state.idle_frame, ok = load_sprite("assets/sprites/idle.png")
	if !ok do return false

	state.walk_frames[0], ok = load_sprite("assets/sprites/walk1.png")
	if !ok do return false
	state.walk_frames[1], ok = load_sprite("assets/sprites/walk2.png")
	if !ok do return false

	state.sleep_frame, ok = load_sprite("assets/sprites/sleep.png")
	if !ok do return false

	fmt.println("  ✓ all sprites loaded (idle, walk×2, sleep)")
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
		state.screen_w = int(width)
		state.screen_h = int(height)
		fmt.printfln("  screen: %dx%d", state.screen_w, state.screen_h)

		if !create_buffer() {
			state.running = false
			return
		}

		// Place cat on the ground, center of screen
		state.cat_x = state.screen_w / 2 - SPRITE_SIZE / 2
		state.cat_y = state.screen_h - SPRITE_SIZE - 20  // 20px above bottom
		state.prev_x = state.cat_x
		state.prev_y = state.cat_y

		// Draw first frame
		draw_frame()

		wl.surface_attach(state.wl_surface, state.buffer, 0, 0)
		wl.surface_damage(state.wl_surface, 0, 0, state.screen_w, state.screen_h)
		request_frame()
		wl.surface_commit(state.wl_surface)

		fmt.println("✓ fullscreen overlay mapped — cat is loose!")
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

// --- Frame callback ---

frame_done :: proc "c" (data: rawptr, callback: ^wl.callback, time_ms: uint) {
	context = global_context
	wl.callback_destroy(callback)

	t := u32(time_ms)
	if state.last_time_ms == 0 do state.last_time_ms = t

	elapsed := t - state.last_time_ms
	if elapsed >= FRAME_INTERVAL_MS {
		state.last_time_ms = t
		state.prev_x = state.cat_x
		state.prev_y = state.cat_y
		update_cat()
	}

	draw_frame()

	wl.surface_attach(state.wl_surface, state.buffer, 0, 0)

	// Damage only the old and new sprite rectangles
	damage_sprite_rect(state.prev_x, state.prev_y)
	damage_sprite_rect(state.cat_x, state.cat_y)

	request_frame()
	wl.surface_commit(state.wl_surface)
}

damage_sprite_rect :: proc(x, y: int) {
	// Clamp to screen bounds for damage reporting
	dx := max(0, x)
	dy := max(0, y)
	dw := min(SPRITE_SIZE, state.screen_w - dx)
	dh := min(SPRITE_SIZE, state.screen_h - dy)
	if dw > 0 && dh > 0 {
		wl.surface_damage(state.wl_surface, dx, dy, dw, dh)
	}
}

frame_listener := wl.callback_listener{
	done = frame_done,
}

request_frame :: proc() {
	cb := wl.surface_frame(state.wl_surface)
	wl.callback_add_listener(cb, &frame_listener, nil)
}

// --- Cat AI ---

update_cat :: proc() {
	state.state_timer -= 1

	switch state.cat_state {
	case .Idle:
		if state.state_timer <= 0 {
			// Choose next action
			roll := rand.int31() % 10
			if roll < 6 {
				// Walk (60% chance)
				state.cat_state = .Walking
				state.state_timer = 15 + int(rand.int31() % 25)
				// Pick direction
				if rand.int31() % 2 == 0 {
					state.cat_dir = 1
				} else {
					state.cat_dir = -1
				}
			} else {
				// Sleep (40% chance)
				state.cat_state = .Sleeping
				state.state_timer = 10 + int(rand.int31() % 15)
			}
		}

	case .Walking:
		state.anim_frame += 1

		// Move the cat
		state.cat_x += state.cat_dir * WALK_SPEED

		// Bounce off screen edges
		if state.cat_x <= 10 {
			state.cat_x = 10
			state.cat_dir = 1
		} else if state.cat_x >= state.screen_w - SPRITE_SIZE - 10 {
			state.cat_x = state.screen_w - SPRITE_SIZE - 10
			state.cat_dir = -1
		}

		if state.state_timer <= 0 {
			state.cat_state = .Idle
			state.state_timer = 3 + int(rand.int31() % 8)
		}

	case .Sleeping:
		if state.state_timer <= 0 {
			state.cat_state = .Idle
			state.state_timer = 2 + int(rand.int31() % 5)
		}
	}
}

// --- Drawing ---

get_current_sprite :: proc() -> ^Sprite_Frame {
	switch state.cat_state {
	case .Idle:     return &state.idle_frame
	case .Walking:  return &state.walk_frames[state.anim_frame % 2]
	case .Sleeping: return &state.sleep_frame
	}
	return &state.idle_frame
}

draw_frame :: proc() {
	sw := state.screen_w
	sh := state.screen_h

	// Clear old sprite position to transparent
	clear_rect(state.prev_x, state.prev_y)

	// Blit the current sprite at the cat's position
	sprite := get_current_sprite()
	flip := state.cat_dir < 0  // flip horizontally when walking left

	for sy in 0..<SPRITE_SIZE {
		for sx in 0..<SPRITE_SIZE {
			pixel := sprite.pixels[sy * SPRITE_SIZE + sx]
			if pixel == 0 do continue  // skip fully transparent

			// Flip horizontally if needed
			dx := state.cat_x + (flip ? (SPRITE_SIZE - 1 - sx) : sx)
			dy := state.cat_y + sy

			// Bounds check
			if dx >= 0 && dx < sw && dy >= 0 && dy < sh {
				state.buf_data[dy * sw + dx] = pixel
			}
		}
	}
}

clear_rect :: proc(x, y: int) {
	sw := state.screen_w
	sh := state.screen_h
	for cy in 0..<SPRITE_SIZE {
		for cx in 0..<SPRITE_SIZE {
			px := x + cx
			py := y + cy
			if px >= 0 && px < sw && py >= 0 && py < sh {
				state.buf_data[py * sw + px] = 0x00000000
			}
		}
	}
}

// --- Shared memory buffer ---

create_buffer :: proc() -> bool {
	sw := state.screen_w
	sh := state.screen_h
	stride := sw * 4
	buf_size := stride * sh

	name := fmt.caprintf("/neko_shm_%v", cast(uintptr)state.display)
	fd := posix.shm_open(name, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if fd < 0 {
		fmt.eprintfln("error: shm_open failed: %v", posix.errno())
		return false
	}
	posix.shm_unlink(name)
	state.buf_fd = fd

	ret := posix.ftruncate(auto_cast fd, auto_cast buf_size)
	if ret == .FAIL {
		fmt.eprintln("error: ftruncate failed")
		return false
	}

	data_raw, err := linux.mmap(0, uint(buf_size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
	if err != .NONE {
		fmt.eprintfln("error: mmap failed: %v", err)
		return false
	}
	state.buf_data = cast([^]u32)data_raw

	// Start fully transparent
	for i in 0..<(sw * sh) {
		state.buf_data[i] = 0x00000000
	}

	pool := wl.shm_create_pool(state.shm, auto_cast fd, buf_size)
	state.buffer = wl.shm_pool_create_buffer(pool, 0, sw, sh, stride, .argb8888)
	wl.shm_pool_destroy(pool)

	fmt.printfln("✓ buffer: %dx%d ARGB8888 (%d KB)", sw, sh, buf_size / 1024)
	return true
}

// --- Entry point ---

main :: proc() {
	global_context = context

	fmt.println("neko — Wayland desktop cat 🐱")
	fmt.println("==============================")

	// Load sprites
	fmt.println("\nloading sprites:")
	if !load_all_sprites() {
		fmt.eprintln("error: sprite loading failed")
		return
	}

	// Initialize cat
	state.cat_state = .Idle
	state.cat_dir = 1
	state.state_timer = 3
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
	fmt.println("✓ globals bound")

	// Create surface
	state.wl_surface = wl.compositor_create_surface(state.compositor)

	// Click-through (empty input region)
	empty_region := wl.compositor_create_region(state.compositor)
	wl.surface_set_input_region(state.wl_surface, empty_region)
	wl.region_destroy(empty_region)

	// Fullscreen transparent overlay:
	// Anchor all 4 edges + size 0,0 → compositor assigns full output size
	state.layer_surface = layer.layer_shell_get_layer_surface(
		state.layer_shell,
		state.wl_surface,
		cast(^wl.output)nil,
		.overlay,
		"neko",
	)

	layer.layer_surface_set_size(state.layer_surface, 0, 0)  // let compositor decide
	layer.layer_surface_set_anchor(state.layer_surface, {.top, .bottom, .left, .right})
	layer.layer_surface_set_exclusive_zone(state.layer_surface, -1)
	layer.layer_surface_set_keyboard_interactivity(state.layer_surface, .none)

	layer.layer_surface_add_listener(state.layer_surface, &layer_surface_listener, nil)

	// Initial commit triggers configure with screen dimensions
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
	if state.buf_data != nil {
		linux.munmap(state.buf_data, uint(state.screen_w * state.screen_h * 4))
	}
	if state.buf_fd >= 0 do posix.close(state.buf_fd)
	if !state.closed do layer.layer_surface_destroy(state.layer_surface)
	wl.surface_destroy(state.wl_surface)

	delete(state.idle_frame.pixels)
	delete(state.walk_frames[0].pixels)
	delete(state.walk_frames[1].pixels)
	delete(state.sleep_frame.pixels)

	fmt.println("✓ neko exited cleanly")
}
