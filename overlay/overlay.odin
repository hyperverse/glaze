// overlay — Wayland layer-shell + EGL/OpenGL framework
// Provides a fullscreen transparent GPU-rendered overlay.
// Apps supply callbacks for init, update, draw, and cleanup.
package overlay

import wl "../deps/odin-wayland"
import layer "../protocols"
import gl "vendor:OpenGL"
import "core:fmt"
import "core:sys/posix"
import "base:runtime"

// --- App interface ---
// Implement these callbacks and pass them to run().

App :: struct {
	title:      cstring,       // layer-shell namespace (e.g. "neko", "matrix")
	tick_ms:    u32,           // animation tick interval; 0 = every frame
	on_init:    proc(screen_w, screen_h: int) -> bool,  // GL context is current
	on_update:  proc(),        // called every tick_ms
	on_draw:    proc(),        // called every frame (GL context is current)
	on_cleanup: proc(),        // called before teardown
}

// --- Framework state ---

State :: struct {
	display:       ^wl.display,
	compositor:    ^wl.compositor,
	layer_shell:   ^layer.layer_shell,
	output:        ^wl.output,

	wl_surface:    ^wl.surface,
	layer_surface: ^layer.layer_surface,
	configured:    bool,

	screen_w:      int,
	screen_h:      int,

	// EGL
	egl_display:   EGLDisplay,
	egl_surface:   EGLSurface,
	egl_context:   EGLContext,
	egl_window:    ^wl.egl_window,

	running:       bool,
	closed:        bool,
	last_time_ms:  u32,

	app:           App,
}

ctx: State
global_context: runtime.Context

// --- Public accessors ---

screen_width  :: proc() -> int { return ctx.screen_w }
screen_height :: proc() -> int { return ctx.screen_h }

// --- Signal handling ---

signal_handler :: proc "c" (sig: posix.Signal) {
	ctx.running = false
}

install_signal_handlers :: proc() {
	posix.signal(.SIGINT,  signal_handler)
	posix.signal(.SIGTERM, signal_handler)
}

// --- EGL setup ---

gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(cast(^rawptr)p)^ = eglGetProcAddress(name)
}

init_egl :: proc() -> bool {
	ctx.egl_display = eglGetDisplay(cast(EGLNativeDisplayType)ctx.display)
	if ctx.egl_display == EGL_NO_DISPLAY {
		fmt.eprintln("error: eglGetDisplay failed")
		return false
	}

	major, minor: EGLint
	if eglInitialize(ctx.egl_display, &major, &minor) == 0 {
		fmt.eprintln("error: eglInitialize failed")
		return false
	}
	fmt.printfln("  EGL %d.%d", major, minor)

	if eglBindAPI(EGL_OPENGL_API) == 0 {
		fmt.eprintln("error: eglBindAPI(EGL_OPENGL_API) failed")
		return false
	}

	// RGBA8 with alpha — critical for transparent overlay
	config_attribs := [?]EGLint{
		EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
		EGL_RED_SIZE,        8,
		EGL_GREEN_SIZE,      8,
		EGL_BLUE_SIZE,       8,
		EGL_ALPHA_SIZE,      8,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
		EGL_NONE,
	}

	config: EGLConfig
	num_configs: EGLint
	if eglChooseConfig(ctx.egl_display, raw_data(config_attribs[:]), &config, 1, &num_configs) == 0 || num_configs == 0 {
		fmt.eprintfln("error: eglChooseConfig failed (err=0x%x)", eglGetError())
		return false
	}

	ctx.egl_window = wl.egl_window_create(ctx.wl_surface, ctx.screen_w, ctx.screen_h)
	if ctx.egl_window == nil {
		fmt.eprintln("error: wl_egl_window_create failed")
		return false
	}

	ctx.egl_surface = eglCreateWindowSurface(ctx.egl_display, config, cast(EGLNativeWindowType)ctx.egl_window, nil)
	if ctx.egl_surface == EGL_NO_SURFACE {
		fmt.eprintfln("error: eglCreateWindowSurface failed (err=0x%x)", eglGetError())
		return false
	}

	context_attribs := [?]EGLint{
		EGL_CONTEXT_MAJOR_VERSION, 3,
		EGL_CONTEXT_MINOR_VERSION, 3,
		EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
		EGL_NONE,
	}

	ctx.egl_context = eglCreateContext(ctx.egl_display, config, EGL_NO_CONTEXT, raw_data(context_attribs[:]))
	if ctx.egl_context == EGL_NO_CONTEXT {
		fmt.eprintfln("error: eglCreateContext failed (err=0x%x)", eglGetError())
		return false
	}

	if eglMakeCurrent(ctx.egl_display, ctx.egl_surface, ctx.egl_surface, ctx.egl_context) == 0 {
		fmt.eprintfln("error: eglMakeCurrent failed (err=0x%x)", eglGetError())
		return false
	}

	gl.load_up_to(3, 3, gl_set_proc_address)

	fmt.println("  ✓ EGL + OpenGL 3.3 core initialized")
	return true
}

// --- Wayland listeners ---

registry_global :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint, iface: cstring, version: uint) {
	context = global_context
	switch iface {
	case wl.compositor_interface.name:
		ctx.compositor = cast(^wl.compositor)wl.registry_bind(registry, name, &wl.compositor_interface, 4)
	case layer.layer_shell_interface.name:
		ctx.layer_shell = cast(^layer.layer_shell)wl.registry_bind(registry, name, &layer.layer_shell_interface, 4)
	case wl.output_interface.name:
		if ctx.output == nil {
			ctx.output = cast(^wl.output)wl.registry_bind(registry, name, &wl.output_interface, 4)
		}
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

registry_listener := wl.registry_listener{
	global        = registry_global,
	global_remove = registry_global_remove,
}

layer_surface_configure :: proc "c" (
	data: rawptr,
	ls: ^layer.layer_surface,
	serial: u32,
	width: u32,
	height: u32,
) {
	context = global_context
	layer.layer_surface_ack_configure(ls, serial)

	if !ctx.configured {
		ctx.configured = true
		ctx.screen_w = int(width)
		ctx.screen_h = int(height)
		fmt.printfln("  screen: %dx%d", ctx.screen_w, ctx.screen_h)

		if !init_egl() {
			ctx.running = false
			return
		}

		// Call app init — GL context is now current
		if ctx.app.on_init != nil {
			if !ctx.app.on_init(ctx.screen_w, ctx.screen_h) {
				ctx.running = false
				return
			}
		}

		// Draw first frame + start frame loop.
		// Frame callback must be registered BEFORE eglSwapBuffers
		// (which calls wl_surface_commit internally).
		if ctx.app.on_draw != nil do ctx.app.on_draw()
		request_frame()
		eglSwapBuffers(ctx.egl_display, ctx.egl_surface)

		fmt.printfln("✓ overlay mapped (%s)", ctx.app.title)
	}
}

layer_surface_closed :: proc "c" (data: rawptr, ls: ^layer.layer_surface) {
	context = global_context
	ctx.closed = true
	ctx.running = false
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
	if ctx.last_time_ms == 0 do ctx.last_time_ms = t

	tick_ms := ctx.app.tick_ms
	if tick_ms == 0 do tick_ms = 16  // default ~60fps

	elapsed := t - ctx.last_time_ms
	if elapsed >= tick_ms {
		ctx.last_time_ms = t
		if ctx.app.on_update != nil do ctx.app.on_update()
	}

	if ctx.app.on_draw != nil do ctx.app.on_draw()

	// Frame callback before swap — see configure handler comment
	request_frame()
	eglSwapBuffers(ctx.egl_display, ctx.egl_surface)
}

frame_listener := wl.callback_listener{
	done = frame_done,
}

request_frame :: proc() {
	cb := wl.surface_frame(ctx.wl_surface)
	wl.callback_add_listener(cb, &frame_listener, nil)
}

// --- Main entry point ---

run :: proc(app: App) {
	global_context = context
	ctx.app = app

	title := app.title if app.title != nil else "overlay"
	fmt.printfln("%s — Wayland overlay (EGL/OpenGL)", title)
	fmt.println("============================================")

	install_signal_handlers()

	// Connect to Wayland
	ctx.display = wl.display_connect(nil)
	if ctx.display == nil {
		fmt.eprintln("error: failed to connect to Wayland display")
		return
	}
	defer wl.display_disconnect(ctx.display)
	fmt.println("\n✓ connected to Wayland display")

	// Bind globals
	registry := wl.display_get_registry(ctx.display)
	wl.registry_add_listener(registry, &registry_listener, nil)
	wl.display_roundtrip(ctx.display)

	if ctx.compositor == nil || ctx.layer_shell == nil {
		fmt.eprintln("error: missing required globals (compositor or layer_shell)")
		return
	}
	fmt.println("✓ globals bound")

	// Create surface
	ctx.wl_surface = wl.compositor_create_surface(ctx.compositor)

	// Click-through (empty input region)
	empty_region := wl.compositor_create_region(ctx.compositor)
	wl.surface_set_input_region(ctx.wl_surface, empty_region)
	wl.region_destroy(empty_region)

	// Fullscreen transparent overlay
	ctx.layer_surface = layer.layer_shell_get_layer_surface(
		ctx.layer_shell,
		ctx.wl_surface,
		cast(^wl.output)nil,
		.overlay,
		title,
	)

	layer.layer_surface_set_size(ctx.layer_surface, 0, 0)
	layer.layer_surface_set_anchor(ctx.layer_surface, {.top, .bottom, .left, .right})
	layer.layer_surface_set_exclusive_zone(ctx.layer_surface, -1)
	layer.layer_surface_set_keyboard_interactivity(ctx.layer_surface, .none)

	layer.layer_surface_add_listener(ctx.layer_surface, &layer_surface_listener, nil)

	wl.surface_commit(ctx.wl_surface)
	fmt.println("✓ waiting for configure...")

	// Event loop
	ctx.running = true
	for ctx.running {
		if wl.display_dispatch(ctx.display) < 0 {
			if !ctx.running do break
			fmt.eprintln("error: display_dispatch failed")
			break
		}
	}

	// Cleanup
	fmt.println("\nshutting down...")

	if ctx.app.on_cleanup != nil do ctx.app.on_cleanup()

	// EGL cleanup
	if ctx.egl_display != EGL_NO_DISPLAY {
		eglMakeCurrent(ctx.egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)
		if ctx.egl_surface != EGL_NO_SURFACE do eglDestroySurface(ctx.egl_display, ctx.egl_surface)
		if ctx.egl_context != EGL_NO_CONTEXT do eglDestroyContext(ctx.egl_display, ctx.egl_context)
		eglTerminate(ctx.egl_display)
	}
	if ctx.egl_window != nil do wl.egl_window_destroy(ctx.egl_window)

	// Wayland cleanup
	if !ctx.closed do layer.layer_surface_destroy(ctx.layer_surface)
	wl.surface_destroy(ctx.wl_surface)

	fmt.printfln("✓ %s exited cleanly", title)
}
