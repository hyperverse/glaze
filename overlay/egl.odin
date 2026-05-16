// Minimal EGL bindings for Wayland OpenGL rendering
package overlay

import "core:c"

EGLDisplay :: rawptr
EGLConfig  :: rawptr
EGLSurface :: rawptr
EGLContext :: rawptr
EGLNativeDisplayType :: rawptr
EGLNativeWindowType  :: rawptr

EGLint :: c.int
EGLBoolean :: c.uint

// EGL constants
EGL_ALPHA_SIZE        : EGLint : 0x3021
EGL_BLUE_SIZE         : EGLint : 0x3022
EGL_GREEN_SIZE        : EGLint : 0x3023
EGL_RED_SIZE          : EGLint : 0x3024
EGL_SURFACE_TYPE      : EGLint : 0x3033
EGL_WINDOW_BIT        : EGLint : 0x0004
EGL_RENDERABLE_TYPE   : EGLint : 0x3040
EGL_OPENGL_BIT        : EGLint : 0x0008
EGL_NONE              : EGLint : 0x3038
EGL_CONTEXT_MAJOR_VERSION : EGLint : 0x3098
EGL_CONTEXT_MINOR_VERSION : EGLint : 0x30FB
EGL_CONTEXT_OPENGL_PROFILE_MASK : EGLint : 0x30FD
EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT : EGLint : 0x00000001
EGL_NO_CONTEXT        : EGLContext = nil
EGL_NO_SURFACE        : EGLSurface = nil
EGL_NO_DISPLAY        : EGLDisplay = nil
EGL_OPENGL_API        : c.uint = 0x30A2

foreign import egl_lib "system:EGL"

@(default_calling_convention = "c")
foreign egl_lib {
	eglGetDisplay            :: proc(display_id: EGLNativeDisplayType) -> EGLDisplay ---
	eglInitialize            :: proc(dpy: EGLDisplay, major: ^EGLint, minor: ^EGLint) -> EGLBoolean ---
	eglChooseConfig          :: proc(dpy: EGLDisplay, attrib_list: [^]EGLint, configs: [^]EGLConfig, config_size: EGLint, num_config: ^EGLint) -> EGLBoolean ---
	eglCreateContext         :: proc(dpy: EGLDisplay, config: EGLConfig, share_context: EGLContext, attrib_list: [^]EGLint) -> EGLContext ---
	eglCreateWindowSurface   :: proc(dpy: EGLDisplay, config: EGLConfig, win: EGLNativeWindowType, attrib_list: [^]EGLint) -> EGLSurface ---
	eglMakeCurrent           :: proc(dpy: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) -> EGLBoolean ---
	eglSwapBuffers           :: proc(dpy: EGLDisplay, surface: EGLSurface) -> EGLBoolean ---
	eglDestroySurface        :: proc(dpy: EGLDisplay, surface: EGLSurface) -> EGLBoolean ---
	eglDestroyContext        :: proc(dpy: EGLDisplay, ctx: EGLContext) -> EGLBoolean ---
	eglTerminate             :: proc(dpy: EGLDisplay) -> EGLBoolean ---
	eglBindAPI               :: proc(api: c.uint) -> EGLBoolean ---
	eglGetProcAddress        :: proc(procname: cstring) -> rawptr ---
	eglGetError              :: proc() -> EGLint ---
}
