# Critical

- Work on the server (possibly wait till 0.16 with the new async IO?)
- Lighting support 
- Transparency support
- Generic model rendering - for enemies/players/blocks with crazy models.

# Non-critical

- Possible use for face bits: decals. 
    We have 4+4 unused bits, maybe we can put multiple decals into these bits. 
    (decal as in a second texture to put on top of the base texture)
    1. Grass changes color with season, while the underlying dirt does not (2 bits?)
    2. Block breaking cracks (3 bits?)
    3. Highlight block we are looking at (1 bit)
    4. Maybe footprints or something? Or some ambient cracks?
    
- Better phase handling - in which order do we update the world/game state/ui/input/... Right now its a mess!

# Debt

- fps: what is the state of the game on iGPU?
- build: we depend on system install of SDL3.
- culling: when frustum culling, I just take the maximum of FOV's, but that doesnt actually produce a circle that covers the whole screen (the old circle at corners vs circle at side middles thing)
- renderer: there is a maximum allocation size on the gpu, (around 4gigs or `-Dworld_size=128` on flat world).

# Done

- 03.01.2026
    1. Improve BlockManager - now the whole inheritance thing makes more sense, I just treat files as generic 
        Values: bool | str | arr[str] | Map[str, str] and to inherit I just add extra entries to maps recursively.
        For the textures problem, I went with a texture slot idea.

- 02.01.2026 (again didnt update the doc):
    1. Worked on the BlockManager - something to store and process all block data.
        It definitely needs a couple more iterations to be good, this time the big question is how to make 
        block defintion file format good? 
        There is a difficult to achieve balance between copy-pasting defintions and code complexity.
        My first idea was to have blocks potentially inherit from other block defs, that way we can avoid 
        copy-pasting the same "normal block model" segment in every file, we just derive from a `basic.zon` 
        and then override the texture for example.
        Then, I wanted to make it so a block can have related states described in the same file, so that we 
        can for example derive from `basic_with_slabs` to get all the slab models automatically.
        This causes a couple of issues. 
        We again want to avoid needless copy-pasting, so a block state inherits from the parent state, 
        but what if the top-level block inherits from another block with another set of states?
        We basically get into a multiple-inheritance scenario (bad).
        Another issue is that we support multiple faces with multiple textures. 
        I.e. we can have multple `.left` faces, like in a stair block we have the bottom stair left side and a top 
        stair left side, and technically, from the renderer point of view, we can make it so the bottom half 
        and the top half have different textures.
        But how do we describe it in a simple file format, while still supporting the inheritance idea, 
        and the states idea?

- 29.12.2025 (not really, havent updated this doc in a while):
    1. After a number of iterations, introduced a new chunk manager: it generates/meshes/handles `set_block` all in multiple (configurable count) threads.
    Initially I struggled a lot with synchronization: meshing requires read access to neighbouring chunk, but there are also caches involved, to avoid hashmap access on every emited face.
    The main cause for complexity is that I had an event queue per chunk, so I had to ensure everything worked regardless of the state of the neighbouring chunk.
    Now, the strategy is much simpler: I have a single event queue for the whole world, and the chunk manager switches between different phases defined by these events.
    That means the state of each individual chunk is much easier to track.
    2. Ambient occlusion improvements. 
    AO has bothered me for a while: SSAO was mid on its own (apparently it looks mid in every single other game I tried lol), and per-face AO was ugly. 
    After realizing SSAO will not get much better, I have switched my attention to face AO, and finally made it handle corners.
    This caused a dramatic improvement to the visuals!
    3. Textures. 
    I finally decided to add textures to the game. 
    The main reason is that I realized a lot of graphical issues were exacerbated by blocks having flat color as their texture. 
    This emphasized many negative aspects of my graphics system: noisy AO, aliasing, etc. 
    I sat down and made a simple TextureAtlas class with some basic textures and it actually made a big improvement to how the game looks and feels.
    4. Custom models. 
    I have spent quite some time thinking about how should I handle custom models.
    The problem of just having a generic instaced model renderer for anything that is not a full block is obvious: quite a bit of things are not full blocks (slabs, stairs, ...).
    Plus there is no real way to use face AO for generic models.
    After staring at the way I pack information for Face data in BlockRenderer, I saw that there are a lot of free bits that I can take advantage of. 
    I can encode a simple blocky (as in made of rects and only has 90 degree edges) model in these bits.
    Basically imagine we have a face and a normal, they form a 3D coordinate system uvw (w is normal).
    If we wanted a slab for example, I could say it is just a face with half the hight (v=0.5) of a normal face for the sides, and a full face but offset by -0.5 into the block (w=-0.5) for the top side.
    For a stair we can use a combination of uv-scale and uvw-offset.
    At that point, the layout was: xxxxyyyy|zzzznnn?|aaaaaaaa|???????? for the first 32bits (the second 32 bit section was for textures (16bit) + future use for colors).
    After thinking about it, I realized I can move the normal into ChunkData, since it is mostly repeated.
    I also realized there is some invalid/visually identical cases for AO bits, and I was able to compress it down to just 47 cases => 6 bits.
    So I have 14 bits free.
    The first idea was to encode offset and scale directly into the leftower bits.
    The problem is that 14 bits was enough only for resolution of 1/4 meters (2 bits per component => 10bits)
    I could do 1/8th for uv scale and offset and 1/4 for w for the whole 14 bits.
    Removing invalid cases did not help to reduce the memory usage.
    Another option was to use some bits as an index to a models buffer on the GPU, where I can put whatever model I want. 
    I did not know which way would be better, but now I am convinced a separate models buffer is much more powerful.
        - I have much more control over the number of bits used, I can twaek it depending on how many models I want to support.
        - Most of the models that are accessible using the direct encoding idea are useless, I can do a lot more by storing only interesting models in a separate buffer.

- 14.12.2025:
    1. Using a thread pool for building chunks, speeds up the process massively, plus it is a first experiment with multithreading in the app. I had to change how the allocators work.
    2. Added a command to draw perf flamegraph
    3. Using the flamegraph, I was able to wastly improve performance on flat and wavy worlds.
    4. Now chunks can look at neighbour chunks when building mesh. This required an RwLock on `World.active`, which I think can be (and should be) removed.

- 13.12.2025:
    1. Continued working on occlusion culling. I went with a simple and effective solution: don't draw the chunk if the neighbouring chunks have full-block faces, it cuts the amt of rendered chunks from 900 to 300 on flat world.
    2. Adaptive chunk processing - process a dynamic amount of chunks per frame. I just run 
    the thing for 1ms, in the future we will need threads.
    3. block placing: sometimes it was possible to break blocks behind other blocks, which appeared after I fixed the old infinite loop bug; I made it so now dt+=eps and that seems to have fixed both bugs.


- 07.12.2025:
    1. Worked on GpuAlloc. 
    Now it is at least a lot more clear how it works (I did not work on the performance). 
    I also seemingly fixed the crash at realloc, at least I could not replicate it after the rewrite.
    It was easy to replicate before.
    2. Worked on occlusion culling. First, I implemented a (buggy ofc) CPU version, and, it sucks.
    Well, it dropped rendered chunks by around 20%, but it was also quite expensive CPU-wise. 
    I want to try out a GPU based version, that just renders occluders and sees what happens.
    I have partially implemented this, but it is now a bit late so I have to leave it for next week.

- 06.12.2025:
    1. Worked a bit on FXAA, it didnt turn out all that well.

- 01.12.2025:
    1. Now settings are setup by two files: `assets/SettingsMenu.zon` and `./client.zon`. 
    The idea is `SettingsMenu` contains default values and UI setup info (slider range, ...), and is 
    built into the final executable. The second file only stores key-value pairs, and is accessed at 
    runtime. That way it is easy to write save/load/restore functionality, and it is "impossible" to 
    break everything by writing junk into the settings file.

- 30.11.2025:
    1. Improved per-face-side AO, now it is not jarring!
    2. Runtime settings: think about changing settings dynamically. Now we have a `client.zon` file that contains all settings in
    structured format. That being said, a better option may be to put the `client.zon` file into `assets`, and use it to genetate
    a basic `settings.txt` file. That way we can build the defaults into the binary (i.e. the user may delete and break everything).
    It also simplifies serialization (right now unsupported).
    3. Seemingly fixed the raycast bug, buy setting a minimum amout of `dt`.
    4. SSAO: fixed a floating point precision issue: going over powers of 2 created banding artifacts.
    5. SSAO: using SSAO only within some distance range (i.e. 5-30 blocks). 
    SSAO improves image clarity quite a bit when it is just in the background, but being close-up, there are very notisable artifacts.

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
