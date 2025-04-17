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
const AllocatedImage = @import("images.zig").AllocatedImage(1);
const Core = @import("core.zig");
const Device = @import("device.zig").Device;
const PhysicalDevice = @import("device.zig").PhysicalDevice;
const vk_alloc_cbs = @import("core.zig").vkallocationcallbacks;

pub const FrameSubmitContext = struct {
    swapchain_semaphore: c.VkSemaphore = null,
    render_semaphore: c.VkSemaphore = null,
    render_fence: c.VkFence = null,
    command_pool: c.VkCommandPool = null,
    command_buffer: c.VkCommandBuffer = null,
    swapchain_image_index: u32 = 0,
    renderattachmentformat: c.VkFormat = c.VK_FORMAT_R16G16B16A16_SFLOAT,
    depth_format: c.VkFormat = c.VK_FORMAT_D32_SFLOAT,
    colorattachment: AllocatedImage = undefined,
    resolvedattachment: AllocatedImage = undefined,
    depthstencilattachment: AllocatedImage = undefined,

    pub fn init(self: *FrameSubmitContext, core: *Core) void {
        const semaphore_ci = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_ci = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        const command_pool_info = graphics_cmd_pool_info(core.physicaldevice);
        debug.check_vk_panic(c.vkCreateCommandPool(
            core.device.handle,
            &command_pool_info,
            vk_alloc_cbs,
            &self.command_pool,
        ));
        const command_buffer_info = graphics_cmdbuffer_info(self.command_pool);
        debug.check_vk_panic(c.vkAllocateCommandBuffers(
            core.device.handle,
            &command_buffer_info,
            &self.command_buffer,
        ));
        debug.check_vk_panic(c.vkCreateSemaphore(
            core.device.handle,
            &semaphore_ci,
            vk_alloc_cbs,
            &self.swapchain_semaphore,
        ));
        debug.check_vk_panic(c.vkCreateSemaphore(
            core.device.handle,
            &semaphore_ci,
            vk_alloc_cbs,
            &self.render_semaphore,
        ));
        debug.check_vk_panic(c.vkCreateFence(
            core.device.handle,
            &fence_ci,
            vk_alloc_cbs,
            &self.render_fence,
        ));
    }

    pub fn createRenderAttachments(core: *Core) void {
        var self = &core.images;
        const extent: c.VkExtent3D = .{
            .width = self.swapchain_extent.width,
            .height = self.swapchain_extent.height,
            .depth = 1,
        };
        self.extent3d[0] = extent;

        const draw_image_ci: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = self.renderattachmentformat,
            .extent = extent,
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_4_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT,
        };

        const draw_image_ai: c.VmaAllocationCreateInfo = .{
            .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };

        debug.check_vk_panic(c.vmaCreateImage(
            core.gpuallocator,
            &draw_image_ci,
            &draw_image_ai,
            &self.colorattachment.image,
            &self.colorattachment.allocation,
            null,
        ));
        const draw_image_view_ci: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = self.colorattachment.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.renderattachmentformat,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        debug.check_vk_panic(c.vkCreateImageView(
            core.device.handle,
            &draw_image_view_ci,
            Core.vkallocationcallbacks,
            &self.colorattachment.views[0],
        ));
        const resolved_image_ci: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = self.renderattachmentformat,
            .extent = extent,
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        };

        const resolved_image_ai: c.VmaAllocationCreateInfo = .{
            .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };

        debug.check_vk_panic(c.vmaCreateImage(
            core.gpuallocator,
            &resolved_image_ci,
            &resolved_image_ai,
            &self.resolvedattachment.image,
            &self.resolvedattachment.allocation,
            null,
        ));
        const resolved_view_ci: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = self.resolvedattachment.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.renderattachmentformat,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        debug.check_vk_panic(c.vkCreateImageView(
            core.device.handle,
            &resolved_view_ci,
            Core.vkallocationcallbacks,
            &self.resolvedattachment.views[0],
        ));

        const depth_extent = extent;
        const depth_image_ci: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = self.depth_format,
            .extent = depth_extent,
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_4_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT |
                c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT,
        };

        debug.check_vk_panic(c.vmaCreateImage(
            core.gpuallocator,
            &depth_image_ci,
            &draw_image_ai,
            &self.depthstencilattachment.image,
            &self.depthstencilattachment.allocation,
            null,
        ));

        const depth_image_view_ci: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = self.depthstencilattachment.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.depth_format,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        debug.check_vk_panic(c.vkCreateImageView(
            core.device.handle,
            &depth_image_view_ci,
            Core.vkallocationcallbacks,
            &self.depthstencilattachment.views[0],
        ));
    }

    pub fn deinit(self: *FrameSubmitContext, core: *Core) void {
        c.vkDestroyCommandPool(core.device.handle, self.command_pool, vk_alloc_cbs);
        c.vkDestroyFence(core.device.handle, self.render_fence, vk_alloc_cbs);
        c.vkDestroySemaphore(core.device.handle, self.render_semaphore, vk_alloc_cbs);
        c.vkDestroySemaphore(core.device.handle, self.swapchain_semaphore, vk_alloc_cbs);
    }

    pub fn submitBegin(frame: *FrameSubmitContext, core: *Core) !void {
        const timeout: u64 = 4_000_000_000; // 4 second in nanonesconds
        const images = &core.images;
        debug.check_vk_panic(c.vkWaitForFences(core.device.handle, 1, &frame.render_fence, c.VK_TRUE, timeout));

        core.swapchain.acquireNextImage(core, frame, timeout);
        debug.check_vk(c.vkResetFences(core.device.handle, 1, &frame.render_fence)) catch
            @panic("Failed to reset render fence");
        debug.check_vk(c.vkResetCommandBuffer(frame.command_buffer, 0)) catch
            @panic("Failed to reset command buffer");

        const cmd = frame.command_buffer;
        const cmd_begin_info: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };

        const draw_extent = core.swapchain.draw_extent;

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
        const draw_extent = core.swapchain.draw_extent;
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
            draw_extent,
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
        debug.check_vk(c.vkResetFences(core.device.handle, 1, &self.fence)) catch
            @panic("Failed to reset immidiate fence");
        debug.check_vk(c.vkResetCommandBuffer(self.command_buffer, 0)) catch
            @panic("Failed to reset immidiate command buffer");
        const cmd = self.command_buffer;

        const commmand_begin_ci: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        debug.check_vk(c.vkBeginCommandBuffer(cmd, &commmand_begin_ci)) catch
            @panic("Failed to begin command buffer");
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
