// neko — a desktop cat pet for Wayland
// Uses the overlay framework for Wayland/EGL lifecycle.
package neko

import ov "../overlay"
import gl "vendor:OpenGL"
import "core:fmt"
import "core:c"
import "core:math"
import "core:math/rand"
import stbi "vendor:stb/image"

// --- Constants ---
SPRITE_SIZE :: 128
WALK_SPEED  :: 3

// Chroma key
CHROMA_R :: 0
CHROMA_G :: 255
CHROMA_B :: 0
CHROMA_THRESHOLD :: 80

// --- Types ---

Sprite_Frame :: struct {
	texture: u32,
	width:   int,
	height:  int,
}

Cat_State :: enum {
	Idle,
	Walking,
	Sleeping,
}

// --- App state (global — accessed from overlay callbacks) ---

Cat :: struct {
	// Sprites
	idle_frame:  Sprite_Frame,
	walk_right:  Sprite_Frame,
	walk_left:   Sprite_Frame,
	sleep_frame: Sprite_Frame,

	// GL
	shader_program: u32,
	vao:            u32,
	vbo:            u32,
	u_translate:    i32,
	u_screen:       i32,

	// State machine
	cat_state:   Cat_State,
	anim_frame:  int,
	state_timer: int,
	cat_x:       int,
	cat_y:       int,
	cat_dir:     int,

	// Screen (cached from init)
	screen_w:    int,
	screen_h:    int,
}

cat: Cat

// --- Shaders ---

VERTEX_SHADER :: `#version 330 core
layout (location = 0) in vec2 a_pos;
layout (location = 1) in vec2 a_uv;
out vec2 v_uv;
uniform vec2 u_translate;
uniform vec2 u_screen;
void main() {
    vec2 pos = a_pos + u_translate;
    vec2 ndc = (pos / u_screen) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = a_uv;
}
`

FRAGMENT_SHADER :: `#version 330 core
in vec2 v_uv;
out vec4 frag_color;
uniform sampler2D u_texture;
void main() {
    frag_color = texture(u_texture, v_uv);
}
`

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
	pixels := make([]u8, SPRITE_SIZE * SPRITE_SIZE * 4)

	for y in 0..<SPRITE_SIZE {
		for x in 0..<SPRITE_SIZE {
			sx := x * src_w / SPRITE_SIZE
			sy := y * src_h / SPRITE_SIZE
			si := (sy * src_w + sx) * 4

			r := u32(data[si + 0])
			g := u32(data[si + 1])
			b := u32(data[si + 2])
			a := u32(data[si + 3])

			dr := int(r) - CHROMA_R
			dg := int(g) - CHROMA_G
			db := int(b) - CHROMA_B
			dist := math.sqrt(f64(dr*dr + dg*dg + db*db))
			if dist < CHROMA_THRESHOLD {
				a = 0
			}

			r = r * a / 255
			g = g * a / 255
			b = b * a / 255

			di := (y * SPRITE_SIZE + x) * 4
			pixels[di + 0] = u8(r)
			pixels[di + 1] = u8(g)
			pixels[di + 2] = u8(b)
			pixels[di + 3] = u8(a)
		}
	}

	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(
		gl.TEXTURE_2D, 0, i32(gl.RGBA),
		SPRITE_SIZE, SPRITE_SIZE, 0,
		gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels),
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))

	delete(pixels)
	return Sprite_Frame{texture = tex, width = SPRITE_SIZE, height = SPRITE_SIZE}, true
}

// --- Overlay callbacks ---

neko_init :: proc(screen_w, screen_h: int) -> bool {
	cat.screen_w = screen_w
	cat.screen_h = screen_h

	// Shaders
	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		fmt.eprintln("error: shader compilation failed")
		return false
	}
	cat.shader_program = program
	cat.u_translate = gl.GetUniformLocation(program, "u_translate")
	cat.u_screen    = gl.GetUniformLocation(program, "u_screen")

	// Quad VBO
	s := f32(SPRITE_SIZE)
	quad := [?]f32{
		0, 0,  0, 0,
		s, 0,  1, 0,
		0, s,  0, 1,
		s, 0,  1, 0,
		s, s,  1, 1,
		0, s,  0, 1,
	}

	gl.GenVertexArrays(1, &cat.vao)
	gl.BindVertexArray(cat.vao)
	gl.GenBuffers(1, &cat.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, cat.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad), &quad, gl.STATIC_DRAW)

	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 4 * size_of(f32), 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 4 * size_of(f32), 2 * size_of(f32))

	// Blending for premultiplied alpha
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)

	gl.Viewport(0, 0, i32(screen_w), i32(screen_h))

	gl.UseProgram(cat.shader_program)
	gl.Uniform2f(cat.u_screen, f32(screen_w), f32(screen_h))

	// Load sprites
	cat.idle_frame, ok = load_sprite("assets/sprites/idle.png")
	if !ok do return false
	cat.walk_right, ok = load_sprite("assets/sprites/walk1.png")
	if !ok do return false
	cat.walk_left, ok = load_sprite("assets/sprites/walk2.png")
	if !ok do return false
	cat.sleep_frame, ok = load_sprite("assets/sprites/sleep.png")
	if !ok do return false

	fmt.println("  ✓ all sprites loaded (idle, walk_right, walk_left, sleep)")

	// Initial position
	cat.cat_state = .Idle
	cat.cat_dir = 1
	cat.state_timer = 3
	cat.cat_x = screen_w / 2 - SPRITE_SIZE / 2
	cat.cat_y = screen_h - SPRITE_SIZE - 20

	return true
}

neko_update :: proc() {
	cat.state_timer -= 1

	switch cat.cat_state {
	case .Idle:
		if cat.state_timer <= 0 {
			roll := rand.int31() % 10
			if roll < 6 {
				cat.cat_state = .Walking
				cat.state_timer = 15 + int(rand.int31() % 25)
				if rand.int31() % 2 == 0 {
					cat.cat_dir = 1
				} else {
					cat.cat_dir = -1
				}
			} else {
				cat.cat_state = .Sleeping
				cat.state_timer = 10 + int(rand.int31() % 15)
			}
		}

	case .Walking:
		cat.anim_frame += 1
		cat.cat_x += cat.cat_dir * WALK_SPEED

		if cat.cat_x <= 10 {
			cat.cat_x = 10
			cat.cat_dir = 1
		} else if cat.cat_x >= cat.screen_w - SPRITE_SIZE - 10 {
			cat.cat_x = cat.screen_w - SPRITE_SIZE - 10
			cat.cat_dir = -1
		}

		if cat.state_timer <= 0 {
			cat.cat_state = .Idle
			cat.state_timer = 3 + int(rand.int31() % 8)
		}

	case .Sleeping:
		if cat.state_timer <= 0 {
			cat.cat_state = .Idle
			cat.state_timer = 2 + int(rand.int31() % 5)
		}
	}
}

neko_draw :: proc() {
	gl.ClearColor(0, 0, 0, 0)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	gl.UseProgram(cat.shader_program)
	gl.Uniform2f(cat.u_translate, f32(cat.cat_x), f32(cat.cat_y))

	// Pick sprite by state + direction
	sprite: ^Sprite_Frame
	switch cat.cat_state {
	case .Idle:     sprite = &cat.idle_frame
	case .Walking:
		if cat.cat_dir > 0 {
			sprite = &cat.walk_right
		} else {
			sprite = &cat.walk_left
		}
	case .Sleeping: sprite = &cat.sleep_frame
	}

	gl.BindTexture(gl.TEXTURE_2D, sprite.texture)
	gl.BindVertexArray(cat.vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
}

neko_cleanup :: proc() {
	if cat.shader_program != 0 do gl.DeleteProgram(cat.shader_program)
	if cat.vbo != 0 do gl.DeleteBuffers(1, &cat.vbo)
	if cat.vao != 0 do gl.DeleteVertexArrays(1, &cat.vao)

	if cat.idle_frame.texture != 0  do gl.DeleteTextures(1, &cat.idle_frame.texture)
	if cat.walk_right.texture != 0  do gl.DeleteTextures(1, &cat.walk_right.texture)
	if cat.walk_left.texture != 0   do gl.DeleteTextures(1, &cat.walk_left.texture)
	if cat.sleep_frame.texture != 0 do gl.DeleteTextures(1, &cat.sleep_frame.texture)
}

// --- Entry point ---

main :: proc() {
	ov.run({
		title      = "neko",
		tick_ms    = 250,
		on_init    = neko_init,
		on_update  = neko_update,
		on_draw    = neko_draw,
		on_cleanup = neko_cleanup,
	})
}
