const gpubackend = @import("vulkan/core.zig");
const std = @import("std");
const c = @import("clibs");
const Core = @import("vulkan/core.zig");
const Swapchain = @import("vulkan/swapchain.zig");
const Window = @import("window.zig");
const FrameSubmitContext = commands.FrameSubmitContext;
const buffer = @import("vulkan/buffers.zig");
const Vertex = buffer.Vertex;
const gltf = @import("gltf.zig");
const commands = @import("vulkan/commands.zig");
const create = @import("vulkan/buffers.zig").create;
const SceneDataUniform = buffer.SceneDataUniform;
const Allocator = @import("vulkan/descriptormanager.zig").Allocator;
const Writer = @import("vulkan/descriptormanager.zig").Writer;
const log = std.log.scoped(.app);
const geometry = @import("geometry");
const Quat = geometry.Quat(f32);
const Vec3 = geometry.Vec3(f32);
const Vec4 = geometry.Vec4(f32);
const Mat4x4 = geometry.Mat4x4(f32);

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
    const allocator = gpa.allocator();
    var window: Window = .init(1200, 1000);
    defer window.deinit();
    var engine: gpubackend = .init(allocator, &window);
    defer engine.deinit();
    var pipelines = Pipelines{};
    pipelines.init(&engine);
    defer pipelines.deinit(&engine);
    initScene(&engine, &pipelines);
    loop(&engine, &window, &pipelines);
}

const Pipelines = struct {
    meshshader: @import("vulkan/pipelines/meshshader.zig") = .{},
    vertexshader: @import("vulkan/pipelines/vertexshader.zig") = .{},

    pub fn init(self: *@This(), core: *Core) void {
        inline for (std.meta.fields(Pipelines)) |field| {
            @field(self, field.name).init(core);
        }
    }

    pub fn deinit(self: *@This(), core: *Core) void {
        inline for (std.meta.fields(Pipelines)) |field| {
            @field(self, field.name).deinit(core);
        }
    }
};

pub fn FrameSubmitContexts(frames_in_flight: comptime_int) type {
    return struct {
        frames: [frames_in_flight]FrameSubmitContext = .{FrameSubmitContext{}} ** frames_in_flight,
        current: u8 = 0,

        pub fn switch_frame(self: *FrameSubmitContexts) void {
            self.current = (self.current + 1) % frames_in_flight;
        }
    };
}

pub fn uploadSceneData(core: *Core, frame: *FrameSubmitContext, view: Mat4x4) void {
    var scene_uniform_data: *SceneDataUniform = @alignCast(@ptrCast(frame.buffers.scenedata.info.pMappedData.?));
    scene_uniform_data.view = view;
    scene_uniform_data.proj = Mat4x4.perspective(
        std.math.degreesToRadians(60.0),
        @as(f32, @floatFromInt(frame.draw_extent.width)) / @as(f32, @floatFromInt(frame.draw_extent.height)),
        0.1,
        1000.0,
    );
    scene_uniform_data.viewproj = Mat4x4.mul(scene_uniform_data.proj, scene_uniform_data.view);
    scene_uniform_data.sunlight_dir = .{ .x = 0.1, .y = 0.1, .z = 1, .w = 1 };
    scene_uniform_data.sunlight_color = .{ .x = 0, .y = 0, .z = 0, .w = 1 };
    scene_uniform_data.ambient_color = .{ .x = 1, .y = 0.6, .z = 0, .w = 1 };

    var poses: *[2]Mat4x4 = @alignCast(@ptrCast(frame.buffers.poses.info.pMappedData.?));

    var time: f32 = @floatFromInt(core.framenumber);
    time /= 100;
    var mod = Mat4x4.rotation(.{ .x = 1.0, .y = 0.0, .z = 0.0 }, time / 2.0);
    mod = mod.rotate(.{ .x = 0.0, .y = 1.0, .z = 0.0 }, time);
    mod = mod.translate(.{ .x = 2.0, .y = 2.0, .z = 2.0 });
    poses[0] = Mat4x4.identity;
    poses[1] = mod;
}

// FIX this is only temporary
pub fn initScene(core: *Core, pipelines: *Pipelines) void {
    var sizes = [_]Allocator.PoolSizeRatio{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .ratio = 1 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .ratio = 1 },
    };
    core.descriptorallocator.init(core.device.handle, 10, &sizes, core.cpuallocator);
    core.buffers.indirect = buffer.createIndirect(core, 1);

    // FIX this is hardcoded two objects for the time beeing
    const resourses1: buffer.ResourceEntry = .{ .pose = 0, .object = 0, .vertex_offset = 0 };
    const resourses2: buffer.ResourceEntry = .{ .pose = 1, .object = 1, .vertex_offset = 199 };
    const resources: [2]buffer.ResourceEntry = .{ resourses1, resourses2 };
    const resources_slice = std.mem.sliceAsBytes(&resources);

    core.buffers.resourcetable = buffer.createSSBO(core, resources_slice.len, true);
    buffer.upload(core, resources_slice, core.buffers.resourcetable);

    core.sets[0] = core.descriptorallocator.allocate(
        core.device.handle,
        pipelines.vertexshader.resourcelayout,
        null,
    );
    core.sets[1] = core.descriptorallocator.allocate(
        core.device.handle,
        pipelines.meshshader.resourcelayout,
        null,
    );

    {
        var writer = Writer.init(core.cpuallocator);
        defer writer.deinit();
        writer.writeBuffer(
            0,
            core.buffers.resourcetable.buffer,
            @sizeOf(buffer.ResourceEntry) * 2,
            0,
            c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        );
        writer.updateSet(core.device.handle, core.sets[0]);
        writer.updateSet(core.device.handle, core.sets[1]);
    }

    // Per frame FIX engine architechture, and who owns what, think data oriented. We want to
    // have the engine own the bare miniumum and all application specific data needs to be owned by the caller,
    // e.g. this file
    for (&core.framecontexts.frames) |*frame| {
        frame.buffers.scenedata = buffer.create(
            core,
            @sizeOf(buffer.SceneDataUniform),
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.VMA_MEMORY_USAGE_CPU_TO_GPU,
        );

        // FIX only two hardcoded poses for the time beeing
        frame.buffers.poses = buffer.create(
            core,
            @sizeOf(Mat4x4) * 2,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                c.VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            c.VMA_MEMORY_USAGE_CPU_TO_GPU,
        );

        const adr = buffer.getDeviceAddress(core, frame.buffers.poses);

        var scene_uniform_data: *buffer.SceneDataUniform = @alignCast(@ptrCast(frame.buffers.scenedata.info.pMappedData.?));
        scene_uniform_data.pose_buffer_address = adr;

        frame.sets[0] = frame.descriptors.allocate(core.device.handle, pipelines.vertexshader.scenedatalayout, null);
        frame.sets[1] = frame.descriptors.allocate(core.device.handle, pipelines.meshshader.scenedatalayout, null);
        {
            var writer = Writer.init(core.cpuallocator);
            defer writer.deinit();
            writer.writeBuffer(
                0,
                frame.buffers.scenedata.buffer,
                @sizeOf(buffer.SceneDataUniform),
                0,
                c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            );
            writer.updateSet(core.device.handle, frame.sets[0]);
            writer.updateSet(core.device.handle, frame.sets[1]);
        }
    }
    const ico = gltf.load_meshes(core.cpuallocator, "assets/icosphere.glb") catch @panic("Failed to load mesh");
    const numlinesx = 99;
    const numlinesy = 99;
    const totalLines = numlinesx + numlinesy + 1;
    var lines: [totalLines]Vertex = undefined;

    // Calculate the bounds based on the number of *segments*, which is numLines - 1
    const spacing = 1;
    const halfWidth = (numlinesx - 1) * spacing * 0.5;
    const halfDepth = (numlinesy - 1) * spacing * 0.5;
    const color: Vec4 = .new(0.024, 0.024, 0.024, 1.0);
    const xcolor: Vec4 = .new(1.000, 0.162, 0.078, 1.0);
    const ycolor: Vec4 = .new(0.529, 0.949, 0.204, 1.0);
    const zcolor: Vec4 = .new(0.114, 0.584, 0.929, 1.0);
    const rgba8: f32 = @bitCast(color.packU8());
    const xcol: f32 = @bitCast(xcolor.packU8());
    const ycol: f32 = @bitCast(ycolor.packU8());
    const zcol: f32 = @bitCast(zcolor.packU8());

    // Generate lines parallel to the Z-axis (varying X)
    var i: u32 = 0;
    while (i < numlinesx) : (i += 1) {
        const floati: f32 = @floatFromInt(i); // X coord changes
        const x = (floati * spacing) - halfDepth;
        const p0: Vec3 = .new(x, -halfWidth, 0); // Z extent fixed
        const p1: Vec3 = .new(x, halfWidth, 0); // Z extent fixed
        const p2: Vec4 = .zeros;
        // No allocation needed here, append moves the struct
        if (i == numlinesx / 2) {
            lines[i] = .new(p0, p1, p2, 0.2, ycol);
        } else {
            lines[i] = .new(p0, p1, p2, 0.08, rgba8);
        }
    }

    // Generate lines parallel to the X-axis (varying Z)
    var j: u32 = 0;
    while (j < numlinesy) : (j += 1) {
        const floatj: f32 = @floatFromInt(j);
        const y = (floatj * spacing) - halfWidth; // Z coord changes
        const p0: Vec3 = .new(-halfDepth, y, 0); // X extent fixed
        const p1: Vec3 = .new(halfDepth, y, 0); // X extent fixed
        const p2: Vec4 = .zeros;
        if (j == numlinesy / 2) {
            lines[i + j] = .new(p0, p1, p2, 0.2, xcol);
        } else {
            lines[i + j] = .new(p0, p1, p2, 0.08, rgba8);
        }
    }

    const p0: Vec3 = .new(0, 0, -halfDepth); // X extent fixed
    const p1: Vec3 = .new(0, 0, halfDepth); // X extent fixed
    const p2: Vec4 = .zeros;
    lines[i + j] = .new(p0, p1, p2, 0.2, zcol);
    const icoverts = ico.items[0].vertices;
    // for (icoverts) |v| {
    //     std.debug.print("{}", .{v.position});
    // }
    const total_len = icoverts.len + lines.len;
    // const total_len = icoverts.len;
    const result = core.cpuallocator.alloc(Vertex, total_len) catch @panic("");
    @memcpy(result[0..lines.len], lines[0..]);
    @memcpy(result[lines.len..], icoverts[0..]);
    defer core.cpuallocator.free(result);
    const indc = ico.items[0].indices;
    core.buffers.vertex = buffer.createSSBO(core, @sizeOf(Vertex) * result.len, true);
    core.buffers.index = buffer.createIndex(core, @sizeOf(u32) * indc.len);
    buffer.upload(core, std.mem.sliceAsBytes(indc), core.buffers.index);
    buffer.upload(core, std.mem.sliceAsBytes(result), core.buffers.vertex);
    const adr = buffer.getDeviceAddress(core, core.buffers.vertex);
    var drawcommands: *c.VkDrawIndexedIndirectCommand = @alignCast(@ptrCast(core.buffers.indirect.info.pMappedData.?));
    drawcommands.firstIndex = 0;
    drawcommands.firstInstance = 0;
    drawcommands.indexCount = 240; //240
    drawcommands.instanceCount = 1;
    drawcommands.vertexOffset = 199;

    for (&core.framecontexts.frames) |*frame| {
        var scene_uniform_data: *buffer.SceneDataUniform = @alignCast(@ptrCast(frame.buffers.scenedata.info.pMappedData.?));
        scene_uniform_data.vertex_buffer_address = adr;
    }
}

pub fn loop(engine: *Core, window: *Window, pipelines: *Pipelines) void {
    var timer = std.time.Timer.start() catch @panic("Failed to start timer");
    var delta: u64 = undefined;

    var camerarot: Quat = .identity;
    var camerapos: Vec3 = .{ .x = 0, .y = -5, .z = 8 };
    camerarot.rotatePitch(std.math.degreesToRadians(60));
    camerarot.rotateYaw(std.math.degreesToRadians(180));
    camerarot.rotateRoll(std.math.degreesToRadians(180));

    Window.check_sdl_bool(c.SDL_SetWindowRelativeMouseMode(window.sdl_window, true));
    window.state.capture_mouse = true;

    while (!window.state.quit) {
        window.processInput();
        if (window.state.w) camerapos.translateForward(&camerarot, 0.1);
        if (window.state.s) camerapos.translateForward(&camerarot, -0.1);
        if (window.state.a) camerapos.translatePitch(&camerarot, -0.1);
        if (window.state.d) camerapos.translatePitch(&camerarot, 0.1);
        if (window.state.q) camerapos.translateWorldZ(-0.1);
        if (window.state.e) camerapos.translateWorldZ(0.1);
        camerarot.rotatePitch(-window.state.mouse_y / 150);
        camerarot.rotateWorldZ(-window.state.mouse_x / 150);
        if (engine.framenumber % 100 == 0) {
            delta = timer.read();
            log.info("FPS: {d}                        \x1b[1A", .{
                @as(u32, (@intFromFloat(100_000_000_000.0 / @as(f32, @floatFromInt(delta))))),
            });
            timer.reset();
        }
        if (engine.resizerequest) {
            window.get_size(&engine.images.swapchain_extent.width, &engine.images.swapchain_extent.height);
            Swapchain.resize(engine);
            continue;
        }
        var frame = &engine.framecontexts.frames[engine.framecontexts.current];
        frame.submitBegin(engine) catch continue;
        uploadSceneData(engine, frame, camerarot.view(camerapos));
        pipelines.vertexshader.draw(engine, frame);
        pipelines.meshshader.draw(engine, frame);
        frame.submitEnd(engine);
    }
}
