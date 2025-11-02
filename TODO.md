# Critical

- Block placement/destruction
- Chunk render optimizations:
    - Greedy meshing - combine quads with the same texture into a larger quad
    - Frustum culling - skip chunks that are outside of the camera view
    - Unseen chunks - figure out some way to determine if a chunk is covered up by other chunks in the players view
- Work on the server
- Fix client.GpuAlloc.full\_realloc
- Add some sort of UI

# Non-critical

- Try out the ECS-free version of client.Controller
- Improve client.GpuAlloc
- Adaptive chunk processing - process a dynamic amount of chunks per frame


# Done

02.11.2025: 
    1. Draw faces in separate draw calls - allows cheap face culling. 
    Tried it (branch chunk-split-faces), but it doesnt seem to improve fps (even makes it worse in some cases)
