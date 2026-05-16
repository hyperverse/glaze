// Hand-written Odin bindings for wlr-layer-shell-unstable-v1
// Protocol source: /usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml
// Verified against: wayland-scanner private-code output
// Pattern follows deps/odin-wayland/xdg/shell.odin
#+build linux
package wlr_layer_shell

// Type table for the protocol — matches the C scanner's output exactly.
// C: wlr_layer_shell_unstable_v1_types[]
//   [0] NULL
//   [1] NULL
//   [2] NULL
//   [3] NULL
//   [4] &zwlr_layer_surface_v1_interface
//   [5] &wl_surface_interface
//   [6] &wl_output_interface
//   [7] NULL  (layer uint)
//   [8] NULL  (namespace string)
//   [9] NULL  (xdg_popup — we use nil since we don't import xdg)
@(private)
layer_shell_types := []^interface {
	nil,                         // 0
	nil,                         // 1
	nil,                         // 2
	nil,                         // 3
	&layer_surface_interface,    // 4: get_layer_surface -> new_id
	&wl.surface_interface,       // 5: get_layer_surface -> surface arg
	&wl.output_interface,        // 6: get_layer_surface -> output arg (nullable)
	nil,                         // 7: get_layer_surface -> layer (uint)
	nil,                         // 8: get_layer_surface -> namespace (string)
	nil,                         // 9: get_popup -> xdg_popup (not imported)
}

// --- zwlr_layer_shell_v1 ---

layer_shell :: struct {}

layer_shell_set_user_data :: proc "contextless" (ls: ^layer_shell, user_data: rawptr) {
	proxy_set_user_data(cast(^proxy)ls, user_data)
}

layer_shell_get_user_data :: proc "contextless" (ls: ^layer_shell) -> rawptr {
	return proxy_get_user_data(cast(^proxy)ls)
}

// Create a layer surface for an existing surface.
LAYER_SHELL_GET_LAYER_SURFACE :: 0
layer_shell_get_layer_surface :: proc "contextless" (
	ls: ^layer_shell,
	surface_: ^wl.surface,
	output_: ^wl.output,    // may be nil to let compositor choose
	layer_: layer,
	namespace_: cstring,
) -> ^layer_surface {
	ret := proxy_marshal_flags(
		cast(^proxy)ls,
		LAYER_SHELL_GET_LAYER_SURFACE,
		&layer_surface_interface,
		proxy_get_version(cast(^proxy)ls),
		0,
		nil,                     // new_id placeholder
		surface_,                // wl_surface object
		output_,                 // wl_output object (nullable)
		cast(uint)layer_,        // layer enum as uint
		namespace_,              // string
	)
	return cast(^layer_surface)ret
}

// Destroy the layer_shell object (since version 3).
LAYER_SHELL_DESTROY :: 1
layer_shell_destroy :: proc "contextless" (ls: ^layer_shell) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SHELL_DESTROY, nil, proxy_get_version(cast(^proxy)ls), 1)
}

layer_shell_error :: enum {
	role               = 0,
	invalid_layer      = 1,
	already_constructed = 2,
}

layer :: enum u32 {
	background = 0,
	bottom     = 1,
	top        = 2,
	overlay    = 3,
}

@(private)
layer_shell_requests := []message {
	// Signature from C scanner: "no?ous"
	{"get_layer_surface", "no?ous", raw_data(layer_shell_types)[4:]},
	{"destroy", "3", raw_data(layer_shell_types)[0:]},
}

layer_shell_interface : interface


// --- zwlr_layer_surface_v1 ---

layer_surface :: struct {}

layer_surface_set_user_data :: proc "contextless" (ls: ^layer_surface, user_data: rawptr) {
	proxy_set_user_data(cast(^proxy)ls, user_data)
}

layer_surface_get_user_data :: proc "contextless" (ls: ^layer_surface) -> rawptr {
	return proxy_get_user_data(cast(^proxy)ls)
}

LAYER_SURFACE_SET_SIZE :: 0
layer_surface_set_size :: proc "contextless" (ls: ^layer_surface, width: u32, height: u32) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_SIZE, nil, proxy_get_version(cast(^proxy)ls), 0, cast(uint)width, cast(uint)height)
}

LAYER_SURFACE_SET_ANCHOR :: 1
layer_surface_set_anchor :: proc "contextless" (ls: ^layer_surface, anchor_: anchor) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_ANCHOR, nil, proxy_get_version(cast(^proxy)ls), 0, transmute(u32)anchor_)
}

LAYER_SURFACE_SET_EXCLUSIVE_ZONE :: 2
layer_surface_set_exclusive_zone :: proc "contextless" (ls: ^layer_surface, zone: i32) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_EXCLUSIVE_ZONE, nil, proxy_get_version(cast(^proxy)ls), 0, cast(int)zone)
}

LAYER_SURFACE_SET_MARGIN :: 3
layer_surface_set_margin :: proc "contextless" (ls: ^layer_surface, top: i32, right: i32, bottom: i32, left: i32) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_MARGIN, nil, proxy_get_version(cast(^proxy)ls), 0, cast(int)top, cast(int)right, cast(int)bottom, cast(int)left)
}

LAYER_SURFACE_SET_KEYBOARD_INTERACTIVITY :: 4
layer_surface_set_keyboard_interactivity :: proc "contextless" (ls: ^layer_surface, ki: keyboard_interactivity) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_KEYBOARD_INTERACTIVITY, nil, proxy_get_version(cast(^proxy)ls), 0, cast(uint)ki)
}

// get_popup uses types[9] = &xdg_popup (nil since we don't import xdg)
LAYER_SURFACE_GET_POPUP :: 5
layer_surface_get_popup :: proc "contextless" (ls: ^layer_surface, popup: rawptr) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_GET_POPUP, nil, proxy_get_version(cast(^proxy)ls), 0, popup)
}

LAYER_SURFACE_ACK_CONFIGURE :: 6
layer_surface_ack_configure :: proc "contextless" (ls: ^layer_surface, serial: u32) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_ACK_CONFIGURE, nil, proxy_get_version(cast(^proxy)ls), 0, cast(uint)serial)
}

LAYER_SURFACE_DESTROY :: 7
layer_surface_destroy :: proc "contextless" (ls: ^layer_surface) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_DESTROY, nil, proxy_get_version(cast(^proxy)ls), 1)
}

LAYER_SURFACE_SET_LAYER :: 8
layer_surface_set_layer :: proc "contextless" (ls: ^layer_surface, layer_: layer) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_LAYER, nil, proxy_get_version(cast(^proxy)ls), 0, cast(uint)layer_)
}

LAYER_SURFACE_SET_EXCLUSIVE_EDGE :: 9
layer_surface_set_exclusive_edge :: proc "contextless" (ls: ^layer_surface, edge: anchor) {
	proxy_marshal_flags(cast(^proxy)ls, LAYER_SURFACE_SET_EXCLUSIVE_EDGE, nil, proxy_get_version(cast(^proxy)ls), 0, transmute(u32)edge)
}

// --- Events ---

layer_surface_listener :: struct {
	configure: proc "c" (data: rawptr, layer_surface: ^layer_surface, serial: u32, width: u32, height: u32),
	closed:    proc "c" (data: rawptr, layer_surface: ^layer_surface),
}

layer_surface_add_listener :: proc "contextless" (ls: ^layer_surface, listener: ^layer_surface_listener, data: rawptr) {
	proxy_add_listener(cast(^proxy)ls, cast(^generic_c_call)listener, data)
}

// --- Enums ---

keyboard_interactivity :: enum u32 {
	none      = 0,
	exclusive = 1,
	on_demand = 2,
}

anchor :: distinct bit_set[anchor_edge; u32]

anchor_edge :: enum u32 {
	top    = 0,
	bottom = 1,
	left   = 2,
	right  = 3,
}

layer_surface_error :: enum {
	invalid_surface_state          = 0,
	invalid_size                   = 1,
	invalid_anchor                 = 2,
	invalid_keyboard_interactivity = 3,
	invalid_exclusive_edge         = 4,
}

// --- Protocol message descriptors ---

@(private)
layer_surface_requests := []message {
	{"set_size",                  "uu",   raw_data(layer_shell_types)[0:]},
	{"set_anchor",                "u",    raw_data(layer_shell_types)[0:]},
	{"set_exclusive_zone",        "i",    raw_data(layer_shell_types)[0:]},
	{"set_margin",                "iiii", raw_data(layer_shell_types)[0:]},
	{"set_keyboard_interactivity","u",    raw_data(layer_shell_types)[0:]},
	{"get_popup",                 "o",    raw_data(layer_shell_types)[9:]},
	{"ack_configure",             "u",    raw_data(layer_shell_types)[0:]},
	{"destroy",                   "",     raw_data(layer_shell_types)[0:]},
	{"set_layer",                 "2u",   raw_data(layer_shell_types)[0:]},
	{"set_exclusive_edge",        "5u",   raw_data(layer_shell_types)[0:]},
}

@(private)
layer_surface_events := []message {
	{"configure", "uuu", raw_data(layer_shell_types)[0:]},
	{"closed",    "",    raw_data(layer_shell_types)[0:]},
}

layer_surface_interface : interface

// --- Interface initialization ---

@(private)
@(init)
init_interfaces_layer_shell :: proc "contextless" () {
	layer_shell_interface.name = "zwlr_layer_shell_v1"
	layer_shell_interface.version = 5
	layer_shell_interface.method_count = 2
	layer_shell_interface.event_count = 0
	layer_shell_interface.methods = raw_data(layer_shell_requests)

	layer_surface_interface.name = "zwlr_layer_surface_v1"
	layer_surface_interface.version = 5
	layer_surface_interface.method_count = 10
	layer_surface_interface.event_count = 2
	layer_surface_interface.methods = raw_data(layer_surface_requests)
	layer_surface_interface.events = raw_data(layer_surface_events)
}

// --- Imports from parent wayland package ---

import wl "../deps/odin-wayland"
fixed_t :: wl.fixed_t
proxy :: wl.proxy
message :: wl.message
interface :: wl.interface
array :: wl.array
generic_c_call :: wl.generic_c_call
proxy_add_listener :: wl.proxy_add_listener
proxy_get_listener :: wl.proxy_get_listener
proxy_get_user_data :: wl.proxy_get_user_data
proxy_set_user_data :: wl.proxy_set_user_data
proxy_get_version :: wl.proxy_get_version
proxy_marshal :: wl.proxy_marshal
proxy_marshal_flags :: wl.proxy_marshal_flags
proxy_marshal_constructor :: wl.proxy_marshal_constructor
proxy_destroy :: wl.proxy_destroy
