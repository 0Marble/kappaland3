# Critical

- Chunk render optimizations:
    - Frustum culling - skip chunks that are outside of the camera view
    - Unseen chunks - figure out some way to determine if a chunk is covered up by other chunks in the players view
- Work on the server
- Better phase handling - in which order do we update the world/game state/ui/input/... Right now its a mess!
- Lights support - we can either have the lighting be calculated on the cpu or on the gpu, I would prefer the cpu since the gpu is already quite strained, but I am also often wrong about gpu performance
    1. Just stick a u32 RGBA onto vertex attributes - 2x the memory...
    2. Pack vertex attribs xxxxyyyy|zzzz?nnn|tttttttt|wwhhllll with 4 bits of light level - no colored lights, more difficult to support u16-based texture indices in the future
    3. Calculate everything in the fragment shader - have a buffer with concated per-chunk light block data, and another one with chunk light-buf offsets. If we have enough gpu it is the easiest approach
    4. Deferred shading - have a completely different shader pass that computes "light meshes", i.e. draws just the light-enduced color of the block faces. We render it to a gpu texture, and then use later for final calculations

# Non-critical

- Placing/breaking - improve the raycaster
- Improve client.GpuAlloc
- Adaptive chunk processing - process a dynamic amount of chunks per frame
- Deferred shading - it would greatly (supposedly?) simplify later non-block rendering. Use the same fragment shader for everything!


# Done

- 03.11.2025:
    1. Add some sort of UI 
    Tried dvui, it does not have an sdl3+opengl backend. Techinically speaking I could make my own, but....
    Going with imgui instead.
    2. Try out the ECS-free version of client.Controller
    In the end I decided on a more flexible idea: implement generic events in the ECS!
    Removing direct ecs calls was a good idea, I realized it as soon as I tried to add mousedown into client.Keys
    3. Block placement/destruction
    Kind of working, but raycasting is still an issue, plus we need to be much more organized to handle this well.
    The process has revealed that phase ordering is actually much more important.

- 02.11.2025: 
    1. Draw faces in separate draw calls - allows cheap face culling. 
    Tried it (branch chunk-split-faces), but it doesnt seem to improve fps (even makes it worse in some cases)
    2. Fix client.GpuAlloc.full\_realloc
    The issue was that the `vert_data` vertex data was still bound to the old freed buffer.
    3. Greedy meshing - combine quads with the same texture into a larger quad
    This improved FPS on the 16x16x8 balls test by like 20 (30-60 -> 50-90), even hitting 120 sometimes
