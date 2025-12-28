pub const c = @cImport({
    // sdl
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_image/SDL_image.h");
    // imgui
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cDefine("CIMGUI_USE_OPENGL3", "");
    @cDefine("CIMGUI_USE_SDL3", "");
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");
});

pub const c_str = [*:0]const u8;
