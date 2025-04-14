const std = @import("std");
const log = std.log.scoped(.commands);
const c = @import("clibs");
const buffers = @import("buffers.zig");
const debug = @import("debug.zig");
const descriptormanager = @import("descriptormanager.zig");
const geometry = @import("geometry");
const Mat4x4 = geometry.Mat4x4(f32);
const Allocator = descriptormanager.Allocator;
const Writer = descriptormanager.Writer;
const Core = @import("core.zig");
const Device = @import("device.zig").Device;
const PhysicalDevice = @import("device.zig").PhysicalDevice;
const vk_alloc_cbs = @import("core.zig").vkallocationcallbacks;

pub const frames_in_flight = 2;

pub const FrameSubmitContext = struct {
    swapchain_semaphore: c.VkSemaphore = null,
    render_semaphore: c.VkSemaphore = null,
    render_fence: c.VkFence = null,
    command_pool: c.VkCommandPool = null,
    command_buffer: c.VkCommandBuffer = null,
    // descriptors: Allocator = .{},
    // buffers: buffers.PerFrameBuffers = undefined,
    // sets: [2]c.VkDescriptorSet = undefined,
    // swapchain_image_index: u32 = 0,
    // draw_extent: c.VkExtent2D = undefined,

    // pub fn destroyBuffers(self: *FrameSubmitContext, core: *Core) void {
    //     c.vmaDestroyBuffer(core.gpuallocator, self.buffers.scenedata.buffer, self.buffers.scenedata.allocation);
    //     c.vmaDestroyBuffer(core.gpuallocator, self.buffers.poses.buffer, self.buffers.poses.allocation);
    // }

    pub fn submitBegin(frame: *FrameSubmitContext, core: *Core) !void {
        const timeout: u64 = 4_000_000_000; // 4 second in nanonesconds
        const images = &core.images;
        debug.check_vk_panic(c.vkWaitForFences(core.device.handle, 1, &frame.render_fence, c.VK_TRUE, timeout));

        const e = c.vkAcquireNextImageKHR(
            core.device.handle,
            core.swapchain.handle,
            timeout,
            frame.swapchain_semaphore,
            null,
            &frame.swapchain_image_index,
        );
        if (e == c.VK_ERROR_OUT_OF_DATE_KHR) {
            core.resizerequest = true;
            return error.SwapchainOutOfDate;
        }

        debug.check_vk(c.vkResetFences(core.device.handle, 1, &frame.render_fence)) catch @panic("Failed to reset render fence");
        debug.check_vk(c.vkResetCommandBuffer(frame.command_buffer, 0)) catch @panic("Failed to reset command buffer");

        const cmd = frame.command_buffer;
        const cmd_begin_info: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };

        var draw_extent: c.VkExtent2D = .{};
        const render_scale = 1;
        draw_extent.width = @intFromFloat(@as(f32, @floatFromInt(@min(
            images.swapchain_extent.width,
            images.swapchain_extent.width,
        ))) * render_scale);
        draw_extent.height = @intFromFloat(@as(f32, @floatFromInt(@min(
            images.swapchain_extent.height,
            images.swapchain_extent.height,
        ))) * render_scale);
        frame.draw_extent = draw_extent;

        debug.check_vk(c.vkBeginCommandBuffer(cmd, &cmd_begin_info)) catch @panic("Failed to begin command buffer");
        const clearvalue = c.VkClearColorValue{ .float32 = .{ 0.014, 0.014, 0.014, 1 } };

        transition_image(
            cmd,
            images.resolvedattachment.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        );

        const color_attachment: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = images.colorattachment.views[0],
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .resolveImageView = images.resolvedattachment.views[0],
            .resolveImageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = c.VK_RESOLVE_MODE_AVERAGE_BIT,
            .clearValue = .{ .color = clearvalue },
        };
        const depth_attachment: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = images.depthstencilattachment.views[0],
            .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0.0 } },
        };

        const render_info: c.VkRenderingInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = draw_extent,
            },
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment,
            .pDepthAttachment = &depth_attachment,
        };

        const viewport: c.VkViewport = .{
            .x = 0.0,
            .y = 0.0,
            .width = @as(f32, @floatFromInt(draw_extent.width)),
            .height = @as(f32, @floatFromInt(draw_extent.height)),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };

        const scissor: c.VkRect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = draw_extent,
        };

        c.vkCmdBeginRendering(cmd, &render_info);
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);
    }

    pub fn submitEnd(frame: *FrameSubmitContext, core: *Core) void {
        const images = core.images;
        const cmd = frame.command_buffer;
        c.vkCmdEndRendering(cmd);
        transition_image(
            cmd,
            images.resolvedattachment.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        );
        transition_image(
            cmd,
            images.swapchain[frame.swapchain_image_index],
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        );
        copy_image_to_image(
            cmd,
            images.resolvedattachment.image,
            images.swapchain[frame.swapchain_image_index],
            frame.draw_extent,
            images.swapchain_extent,
        );
        transition_image(
            cmd,
            core.images.swapchain[frame.swapchain_image_index],
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        );

        debug.check_vk(c.vkEndCommandBuffer(cmd)) catch @panic("Failed to end command buffer");

        const cmd_info = c.VkCommandBufferSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = cmd,
        };

        const wait_info = c.VkSemaphoreSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = frame.swapchain_semaphore,
            .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT_KHR,
        };

        const signal_info = c.VkSemaphoreSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = frame.render_semaphore,
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
        };

        const submit = c.VkSubmitInfo2{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &cmd_info,
            .waitSemaphoreInfoCount = 1,
            .pWaitSemaphoreInfos = &wait_info,
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = &signal_info,
        };

        debug.check_vk(c.vkQueueSubmit2(core.device.graphics_queue, 1, &submit, frame.render_fence)) catch |err| {
            std.log.err("Failed to submit to graphics queue with error: {s}", .{@errorName(err)});
            @panic("Failed to submit to graphics queue");
        };

        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &frame.render_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &core.swapchain.handle,
            .pImageIndices = &frame.swapchain_image_index,
        };
        _ = c.vkQueuePresentKHR(core.device.graphics_queue, &present_info);
        core.framenumber +%= 1;
        core.framecontexts.switch_frame();
    }
};

// TODO maybe move this
pub const FrameSubmitContexts = struct {
    frames: [frames_in_flight]FrameSubmitContext = .{FrameSubmitContext{}} ** frames_in_flight,
    current: u8 = 0,

    pub fn init(core: *Core) void {
        const semaphore_ci = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_ci = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (&core.framecontexts.frames) |*frame| {
            const command_pool_info = graphics_cmd_pool_info(core.physicaldevice);
            debug.check_vk_panic(c.vkCreateCommandPool(
                core.device.handle,
                &command_pool_info,
                vk_alloc_cbs,
                &frame.command_pool,
            ));
            const command_buffer_info = graphics_cmdbuffer_info(frame.command_pool);
            debug.check_vk_panic(c.vkAllocateCommandBuffers(
                core.device.handle,
                &command_buffer_info,
                &frame.command_buffer,
            ));
            debug.check_vk_panic(c.vkCreateSemaphore(
                core.device.handle,
                &semaphore_ci,
                vk_alloc_cbs,
                &frame.swapchain_semaphore,
            ));
            debug.check_vk_panic(c.vkCreateSemaphore(
                core.device.handle,
                &semaphore_ci,
                vk_alloc_cbs,
                &frame.render_semaphore,
            ));
            debug.check_vk_panic(c.vkCreateFence(
                core.device.handle,
                &fence_ci,
                vk_alloc_cbs,
                &frame.render_fence,
            ));
            // var ratios = [_]Allocator.PoolSizeRatio{
            //     .{ .ratio = 3, .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE },
            //     .{ .ratio = 3, .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER },
            //     .{ .ratio = 3, .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER },
            //     .{ .ratio = 4, .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER },
            // };
            // frame.descriptors.init(core.device.handle, 1000, &ratios, core.cpuallocator);
        }
    }

    pub fn deinit(core: *Core) void {
        for (&core.framecontexts.frames) |*frame| {
            c.vkDestroyCommandPool(core.device.handle, frame.command_pool, vk_alloc_cbs);
            c.vkDestroyFence(core.device.handle, frame.render_fence, vk_alloc_cbs);
            c.vkDestroySemaphore(core.device.handle, frame.render_semaphore, vk_alloc_cbs);
            c.vkDestroySemaphore(core.device.handle, frame.swapchain_semaphore, vk_alloc_cbs);
            // frame.descriptors.deinit(core.device.handle);
            // frame.destroyBuffers(core);
        }
    }

    pub fn switch_frame(self: *FrameSubmitContexts) void {
        self.current = (self.current + 1) % frames_in_flight;
    }
};

pub const SubmitContext = struct {
    fence: c.VkFence = null,
    command_pool: c.VkCommandPool = null,
    command_buffer: c.VkCommandBuffer = null,

    pub fn init(self: *@This(), device: Device, physicaldevice: PhysicalDevice) void {
        const command_pool_ci: c.VkCommandPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = physicaldevice.graphics_queue_family,
        };

        const upload_fence_ci: c.VkFenceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        };

        debug.check_vk_panic(c.vkCreateFence(
            device.handle,
            &upload_fence_ci,
            Core.vkallocationcallbacks,
            &self.fence,
        ));
        log.info("Created sync structures", .{});

        debug.check_vk_panic(c.vkCreateCommandPool(
            device.handle,
            &command_pool_ci,
            Core.vkallocationcallbacks,
            &self.command_pool,
        ));

        const upload_command_buffer_ai: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        debug.check_vk_panic(c.vkAllocateCommandBuffers(
            device.handle,
            &upload_command_buffer_ai,
            &self.command_buffer,
        ));
    }

    pub fn deinit(self: *@This(), device: Device) void {
        c.vkDestroyCommandPool(device.handle, self.command_pool, Core.allocationcallbacks);
        c.vkDestroyFence(device.handle, self.fence, Core.allocationcallbacks);
    }

    pub fn begin(core: *Core) void {
        var self = &core.asynccontext;
        debug.check_vk(c.vkResetFences(core.device.handle, 1, &self.fence)) catch @panic("Failed to reset immidiate fence");
        debug.check_vk(c.vkResetCommandBuffer(self.command_buffer, 0)) catch @panic("Failed to reset immidiate command buffer");
        const cmd = self.command_buffer;

        const commmand_begin_ci: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        debug.check_vk(c.vkBeginCommandBuffer(cmd, &commmand_begin_ci)) catch @panic("Failed to begin command buffer");
    }

    pub fn end(core: *Core) void {
        var self = &core.asynccontext;
        const cmd = self.command_buffer;
        debug.check_vk(c.vkEndCommandBuffer(cmd)) catch @panic("Failed to end command buffer");

        const cmd_info: c.VkCommandBufferSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = cmd,
        };
        const submit_info: c.VkSubmitInfo2 = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &cmd_info,
        };
        debug.check_vk_panic(c.vkQueueSubmit2(core.device.graphics_queue, 1, &submit_info, self.fence));
        debug.check_vk_panic(c.vkWaitForFences(core.device.handle, 1, &self.fence, c.VK_TRUE, 1_000_000_000));
    }
};

pub fn graphics_cmd_pool_info(physical_device: PhysicalDevice) c.VkCommandPoolCreateInfo { // does support compute aswell
    return c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = physical_device.graphics_queue_family,
    };
}

pub fn graphics_cmdbuffer_info(pool: c.VkCommandPool) c.VkCommandBufferAllocateInfo {
    return c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
}

pub fn transition_image(
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    current_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
) void {
    var barrier: c.VkImageMemoryBarrier2 = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2 };
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT | c.VK_ACCESS_2_MEMORY_READ_BIT;
    barrier.oldLayout = current_layout;
    barrier.newLayout = new_layout;

    const aspect_mask: u32 = if (new_layout == c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL) blk: {
        break :blk c.VK_IMAGE_ASPECT_DEPTH_BIT;
    } else blk: {
        break :blk c.VK_IMAGE_ASPECT_COLOR_BIT;
    };
    const subresource_range: c.VkImageSubresourceRange = .{
        .aspectMask = aspect_mask,
        .baseMipLevel = 0,
        .levelCount = c.VK_REMAINING_MIP_LEVELS,
        .baseArrayLayer = 0,
        .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
    };

    barrier.image = image;
    barrier.subresourceRange = subresource_range;

    const dep_info = std.mem.zeroInit(c.VkDependencyInfoKHR, .{
        .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO_KHR,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    });

    c.vkCmdPipelineBarrier2(cmd, &dep_info);
}

pub fn copy_image_to_image(
    cmd: c.VkCommandBuffer,
    src: c.VkImage,
    dst: c.VkImage,
    src_size: c.VkExtent2D,
    dst_size: c.VkExtent2D,
) void {
    var blit_region = c.VkImageBlit2{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_BLIT_2, .pNext = null };
    blit_region.srcOffsets[1].x = @intCast(src_size.width);
    blit_region.srcOffsets[1].y = @intCast(src_size.height);
    blit_region.srcOffsets[1].z = 1;
    blit_region.dstOffsets[1].x = @intCast(dst_size.width);
    blit_region.dstOffsets[1].y = @intCast(dst_size.height);
    blit_region.dstOffsets[1].z = 1;
    blit_region.srcSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    blit_region.srcSubresource.baseArrayLayer = 0;
    blit_region.srcSubresource.layerCount = 1;
    blit_region.srcSubresource.mipLevel = 0;
    blit_region.dstSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    blit_region.dstSubresource.baseArrayLayer = 0;
    blit_region.dstSubresource.layerCount = 1;
    blit_region.dstSubresource.mipLevel = 0;

    var blit_info = c.VkBlitImageInfo2{ .sType = c.VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2, .pNext = null };
    blit_info.srcImage = src;
    blit_info.srcImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    blit_info.dstImage = dst;
    blit_info.dstImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    blit_info.regionCount = 1;
    blit_info.pRegions = &blit_region;
    blit_info.filter = c.VK_FILTER_NEAREST;

    c.vkCmdBlitImage2(cmd, &blit_info);
}
