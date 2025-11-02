# Critical

- Block placement/destruction
- Chunk render optimizations:
    - Draw faces in separate draw calls - allows cheap face culling
    - Greedy meshing - combine quads with the same texture into a larger quad
    - Frustum culling - skip chunks that are outside of the camera view
    - Unseen chunks - figure out some way to determine if a chunk is covered up by other chunks in the players view
- Work on the server
- Fix client.GpuAlloc.full\_realloc

# Non-critical

- Try out the ECS-free version of client.Controller
- Improve client.GpuAlloc
- Adaptive chunk processing - process a dynamic amount of chunks per frame

