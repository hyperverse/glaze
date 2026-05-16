// neko — a desktop cat pet for Wayland (Niri)
// Phase 2: Layer surface with colored rectangle on the overlay layer.
package neko

import wl "../deps/odin-wayland"
import layer "../protocols"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"
import "base:runtime"

// --- Constants ---
CAT_WIDTH  :: 128
CAT_HEIGHT :: 128
STRIDE     :: CAT_WIDTH * 4  // 4 bytes per pixel (ARGB8888)
BUF_SIZE   :: STRIDE * CAT_HEIGHT

// --- Global state ---
State :: struct {
	display:       ^wl.display,
	compositor:    ^wl.compositor,
	shm:           ^wl.shm,
	layer_shell:   ^layer.layer_shell,
	output:        ^wl.output,

	// Surface state
	wl_surface:    ^wl.surface,
	layer_surface: ^layer.layer_surface,
	configured:    bool,

	// Buffer
	buffer:        ^wl.buffer,
	buf_data:      [^]u32,
	buf_fd:        posix.FD,

	// Lifecycle
	running:       bool,
	closed:        bool,
}

state: State
global_context: runtime.Context

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
	fmt.printfln("  configure: serial=%d size=%dx%d", serial, width, height)

	// Acknowledge the configure event
	layer.layer_surface_ack_configure(ls, serial)

	if !state.configured {
		state.configured = true

		// Create the shared memory buffer
		if !create_buffer() {
			fmt.eprintln("error: failed to create buffer")
			state.running = false
			return
		}

		// Draw initial content
		draw_frame()

		// Attach buffer and commit to map the surface
		wl.surface_attach(state.wl_surface, state.buffer, 0, 0)
		wl.surface_damage(state.wl_surface, 0, 0, CAT_WIDTH, CAT_HEIGHT)
		wl.surface_commit(state.wl_surface)

		fmt.println("✓ surface mapped!")
	}
}

layer_surface_closed :: proc "c" (data: rawptr, ls: ^layer.layer_surface) {
	context = global_context
	fmt.println("  layer surface closed by compositor")
	state.closed = true
	state.running = false
}

layer_surface_listener := layer.layer_surface_listener{
	configure = layer_surface_configure,
	closed    = layer_surface_closed,
}

// --- Shared memory buffer ---

create_buffer :: proc() -> bool {
	// Create a shared memory file
	name := fmt.caprintf("/neko_shm_%v", cast(uintptr)state.display)
	fd := posix.shm_open(name, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	if fd < 0 {
		fmt.eprintfln("error: shm_open failed: %v", posix.errno())
		return false
	}
	posix.shm_unlink(name)  // unlink immediately, fd keeps it alive
	state.buf_fd = fd

	// Set the size
	ret := posix.ftruncate(auto_cast fd, auto_cast BUF_SIZE)
	if ret == .FAIL {
		fmt.eprintln("error: ftruncate failed")
		return false
	}

	// Map into our address space
	data_raw, err := linux.mmap(0, BUF_SIZE, {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
	if err != .NONE {
		fmt.eprintfln("error: mmap failed: %v", err)
		return false
	}
	state.buf_data = cast([^]u32)data_raw

	// Create the Wayland buffer via wl_shm
	pool := wl.shm_create_pool(state.shm, auto_cast fd, BUF_SIZE)
	state.buffer = wl.shm_pool_create_buffer(pool, 0, CAT_WIDTH, CAT_HEIGHT, STRIDE, .argb8888)
	wl.shm_pool_destroy(pool)

	fmt.printfln("✓ buffer created: %dx%d ARGB8888 (%d bytes)", CAT_WIDTH, CAT_HEIGHT, BUF_SIZE)
	return true
}

// --- Drawing ---

draw_frame :: proc() {
	// Draw a bright magenta rectangle with rounded-ish corners
	// so it's unmissable on screen. Premultiplied alpha.
	for y in 0..<CAT_HEIGHT {
		for x in 0..<CAT_WIDTH {
			idx := y * CAT_WIDTH + x

			// Simple border check for a "rounded" feel
			border :: 4
			in_border := x < border || x >= CAT_WIDTH - border || y < border || y >= CAT_HEIGHT - border

			// Corner cutoff (crude rounded corners)
			corner_r :: 12
			in_corner := false
			corners := [4][2]int{
				{corner_r, corner_r},
				{CAT_WIDTH - corner_r - 1, corner_r},
				{corner_r, CAT_HEIGHT - corner_r - 1},
				{CAT_WIDTH - corner_r - 1, CAT_HEIGHT - corner_r - 1},
			}
			for c in corners {
				dx := x - c[0]
				dy := y - c[1]
				if dx*dx + dy*dy > corner_r*corner_r {
					// Check if we're actually in the corner quadrant
					if (x < corner_r || x >= CAT_WIDTH - corner_r) &&
					   (y < corner_r || y >= CAT_HEIGHT - corner_r) {
						in_corner = true
					}
				}
			}

			if in_corner {
				// Transparent outside rounded corners
				state.buf_data[idx] = 0x00000000
			} else if in_border {
				// Border: bright magenta, full alpha
				// ARGB premultiplied: A=0xFF, R=0xFF, G=0x00, B=0xFF
				state.buf_data[idx] = 0xFFFF00FF
			} else {
				// Interior: semi-transparent magenta
				// A=0x80 (50%), R=0x80, G=0x00, B=0x80 (premultiplied)
				state.buf_data[idx] = 0x80800080
			}
		}
	}
}

// --- Entry point ---

main :: proc() {
	global_context = context

	fmt.println("neko — Wayland desktop cat")
	fmt.println("==========================")

	// 1. Connect to display
	state.display = wl.display_connect(nil)
	if state.display == nil {
		fmt.eprintln("error: failed to connect to Wayland display")
		return
	}
	defer wl.display_disconnect(state.display)
	fmt.println("✓ connected to Wayland display")

	// 2. Discover and bind globals
	registry := wl.display_get_registry(state.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(state.display)

	if state.compositor == nil || state.shm == nil || state.layer_shell == nil {
		fmt.eprintln("error: missing required globals")
		return
	}
	fmt.println("✓ all globals bound")

	// 3. Create wl_surface
	state.wl_surface = wl.compositor_create_surface(state.compositor)
	if state.wl_surface == nil {
		fmt.eprintln("error: failed to create wl_surface")
		return
	}
	fmt.println("✓ wl_surface created")

	// 4. Set empty input region (clicks pass through the cat)
	empty_region := wl.compositor_create_region(state.compositor)
	wl.surface_set_input_region(state.wl_surface, empty_region)
	wl.region_destroy(empty_region)
	fmt.println("✓ input region set to empty (click-through)")

	// 5. Create layer surface on overlay layer
	state.layer_surface = layer.layer_shell_get_layer_surface(
		state.layer_shell,
		state.wl_surface,
		cast(^wl.output)nil,  // let compositor pick output
		.overlay,             // render above everything
		"neko",               // namespace
	)
	if state.layer_surface == nil {
		fmt.eprintln("error: failed to create layer surface")
		return
	}

	// Configure the layer surface:
	// - Fixed size (no stretching)
	// - Anchor to bottom-right corner
	// - No exclusive zone (don't push other windows)
	// - Some margin from the edge
	layer.layer_surface_set_size(state.layer_surface, CAT_WIDTH, CAT_HEIGHT)
	layer.layer_surface_set_anchor(state.layer_surface, {.bottom, .right})
	layer.layer_surface_set_exclusive_zone(state.layer_surface, -1)
	layer.layer_surface_set_margin(state.layer_surface, 0, 40, 40, 0)
	layer.layer_surface_set_keyboard_interactivity(state.layer_surface, .none)

	// Add listener for configure/closed events
	layer.layer_surface_add_listener(state.layer_surface, &layer_surface_listener, nil)

	// 6. Initial commit (no buffer) — triggers configure event
	wl.surface_commit(state.wl_surface)
	fmt.println("✓ layer surface created, waiting for configure...")

	// 7. Event loop
	state.running = true
	for state.running {
		if wl.display_dispatch(state.display) < 0 {
			fmt.eprintln("error: display_dispatch failed")
			break
		}
	}

	// 8. Cleanup
	if state.buffer != nil {
		wl.buffer_destroy(state.buffer)
	}
	if state.buf_data != nil {
		linux.munmap(state.buf_data, BUF_SIZE)
	}
	if state.buf_fd >= 0 {
		posix.close(state.buf_fd)
	}
	if !state.closed {
		layer.layer_surface_destroy(state.layer_surface)
	}
	wl.surface_destroy(state.wl_surface)

	fmt.println("✓ neko exited cleanly")
}
