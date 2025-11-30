# Critical

- ECS nursery - systems during execution may spawn or register ecs thins which has a potential to invalidate all pointers. Make it so commands are recorded and only after `evaluate()` are executed.
- Chunk render optimizations:
    - Unseen chunks - figure out some way to determine if a chunk is covered up by other chunks in the players view
- Work on the server (possibly wait till 0.16 with the new async IO?)
- Better phase handling - in which order do we update the world/game state/ui/input/... Right now its a mess!
- Lights support - we can either have the lighting be calculated on the cpu or on the gpu, I would prefer the cpu since the gpu is already quite strained, but I am also often wrong about gpu performance
    1. Just stick a u32 RGBA onto vertex attributes - 2x the memory...
    2. Pack vertex attribs xxxxyyyy|zzzz?nnn|tttttttt|wwhhllll with 4 bits of light level - no colored lights, more difficult to support u16-based texture indices in the future
    3. Calculate everything in the fragment shader - have a buffer with concated per-chunk light block data, and another one with chunk light-buf offsets. If we have enough gpu it is the easiest approach
    4. Deferred shading - have a completely different shader pass that computes "light meshes", i.e. draws just the light-enduced color of the block faces. We render it to a gpu texture, and then use later for final calculations

# Non-critical

- Improve client.GpuAlloc
- Adaptive chunk processing - process a dynamic amount of chunks per frame
- Ambient occlusion - right now the block lighting is very flat, its hard to see anything
- How does transparensy, non-block models, textures work?

# Debt

- crash:
    1. src: `GpuAlloc.zig:171:9`, error: `8246:824c:1:9146: GL_INVALID_VALUE in glCopyBufferSubData(overlapping src/dst)`
    2. Happens if you just keep placing a bunch of blocks, running around in a circle.
- visual: Face AO does not take neighbouring chunks into account
- visual/probably-unfixable: SSAO cutoff, i.e. when you get close to a block face and slowly rotate the camera
- fps: what is the state of the game on iGPU?
- build: we depend on system install of SDL3.

# Done

- 30.11.2025:
    1. Improved per-face-side AO, now it is not jarring!
    2. Runtime settings: think about changing settings dynamically. Now we have a `client.zon` file that contains all settings in
    structured format. That being said, a better option may be to put the `client.zon` file into `assets`, and use it to genetate
    a basic `settings.txt` file. That way we can build the defaults into the binary (i.e. the user may delete and break everything).
    It also simplifies serialization (right now unsupported).
    3. Seemingly fixed the raycast bug, buy setting a minimum amout of `dt`.

- 23.11.2025:
    1. Implemented SSAO, this technique really needs some parameter fine-tuning to get rid of noise
    2. Implemented per-face-side AO, but this disables greedy meshing (do we care?) and also needs to have access to neighbouring chunks (didnt do this yet)

- 17.11.2025:
    1. Clean up build.zig, make it easier to add compile time options to packages
    2. ECS id mess - make all ECS id's come from the same counter, and make it easier to have globally accessable named things


- 05.11.2025:
    1. Placing/breaking - improve the raycaster 
    2. Reintroduce block placing (got removed during the deferred shading event)
    Same thing really, but now the block placement is "perfect" (at least it seems to be)
    The strategy I took was to do raycasting, and at each block along the ray check if it is 
    air or not. 
    3. Frustum culling - fix the corners getting cut off sometimes
    I approximate the frustum by a cone, and chunks by spheres. 
    The math is pretty simple (ofc it took decades to actually iron out all the bugs lol)

- 04.11.2025:
    1. Deferred shading - it would greatly (supposedly?) simplify later non-block rendering. 
    I implemented it, and the performance seems to be just worse.
    With frustum culling but without deferred shading, the fps on the balls test is 
    perfect 120, with DS it fluctuates around 100.
    Moreover, I would have to implement my own anti-aliasing, since the GPU built-in one only works
    in forward rendering.
    2. Frustum culling - skip chunks that are outside of the camera view
    I implemeted by simply projecting the chunk coordinates by the camera matrix, it does however sometimes 
    cut corners off. In addition, I now sort the chunks before drawing them.
    3. I also organized the source files some more: now the World is split from rendering.


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
