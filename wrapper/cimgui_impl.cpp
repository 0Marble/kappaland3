
#include <backends/imgui_impl_opengl3.h>
#include <backends/imgui_impl_sdl3.h>

extern "C" {

bool ig_ImplOpenGL3_Init(const char *glsl_version) {
  return ImGui_ImplOpenGL3_Init(glsl_version);
}
void ig_ImplOpenGL3_Shutdown(void) { ImGui_ImplOpenGL3_Shutdown(); }
void ig_ImplOpenGL3_NewFrame(void) { ImGui_ImplOpenGL3_NewFrame(); }
void ig_ImplOpenGL3_RenderDrawData(ImDrawData *draw_data) {
  ImGui_ImplOpenGL3_RenderDrawData(draw_data);
}
bool ig_ImplOpenGL3_CreateDeviceObjects(void) {
  ImGui_ImplOpenGL3_CreateDeviceObjects();
}
void ig_ImplOpenGL3_DestroyDeviceObjects(void) {
  ImGui_ImplOpenGL3_DestroyDeviceObjects();
}
void ig_ImplOpenGL3_UpdateTexture(ImTextureData *tex) {
  ImGui_ImplOpenGL3_UpdateTexture(tex);
}

bool ig_ImplSDL3_InitForOpenGL(SDL_Window *window, void *sdl_gl_context) {
  return ImGui_ImplSDL3_InitForOpenGL(window, sdl_gl_context);
}
void ig_ImplSDL3_Shutdown(void) { ImGui_ImplSDL3_Shutdown(); }
void ig_ImplSDL3_NewFrame(void) { ImGui_ImplSDL3_NewFrame(); }
bool ig_ImplSDL3_ProcessEvent(const SDL_Event *event) {
  return ImGui_ImplSDL3_ProcessEvent(event);
}
void ig_ImplSDL3_SetGamepadMode(ImGui_ImplSDL3_GamepadMode mode,
                                SDL_Gamepad **manual_gamepads_array,
                                int manual_gamepads_count) {
  ig_ImplSDL3_SetGamepadMode(mode, manual_gamepads_array,
                             manual_gamepads_count);
}
}
