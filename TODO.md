# Critical

- Block placement/destruction
- Chunk render optimizations:
    - Frustum culling - skip chunks that are outside of the camera view
    - Unseen chunks - figure out some way to determine if a chunk is covered up by other chunks in the players view
- Work on the server

# Non-critical

- Improve client.GpuAlloc
- Adaptive chunk processing - process a dynamic amount of chunks per frame
- Better phase handling - in which order do we update the world/game state/ui/input/... Right now its a mess!


# Done

- 03.11.2025:
    1. Add some sort of UI 
    Tried dvui, it does not have an sdl3+opengl backend. Techinically speaking I could make my own, but....
    Going with imgui instead.
    2. Try out the ECS-free version of client.Controller
    In the end I decided on a more flexible idea: implement generic events in the ECS!
    Removing direct ecs calls was a good idea, I realized it as soon as I tried to add mousedown into client.Keys

- 02.11.2025: 
    1. Draw faces in separate draw calls - allows cheap face culling. 
    Tried it (branch chunk-split-faces), but it doesnt seem to improve fps (even makes it worse in some cases)
    2. Fix client.GpuAlloc.full\_realloc
    The issue was that the `vert_data` vertex data was still bound to the old freed buffer.
    3. Greedy meshing - combine quads with the same texture into a larger quad
    This improved FPS on the 16x16x8 balls test by like 20 (30-60 -> 50-90), even hitting 120 sometimes
