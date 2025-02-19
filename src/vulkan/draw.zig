const Core = @import("core.zig");
const check_vk = @import("debug.zig").check_vk;
const FrameContext = @import("framecontext.zig");
const c = @import("../clibs.zig");
const std = @import("std");
const log = std.log.scoped(.draw);
const transition_image = @import("commands.zig").transition_image;
const copy_image_to_image = @import("commands.zig").copy_image_to_image;

pub fn draw(core: *Core) void {
    const timeout: u64 = 4_000_000_000; // 4 second in nanonesconds
    const frame_index = core.framecontext.current;
    const frame = core.framecontext.frames[frame_index];
    check_vk(c.vkWaitForFences(core.device.handle, 1, &frame.render_fence, c.VK_TRUE, timeout)) catch |err| {
        log.err("Failed to wait for render fence with error: {s}", .{@errorName(err)});
        @panic("Failed to wait for render fence");
    };

    var swapchain_image_index: u32 = undefined;
    var e = c.vkAcquireNextImageKHR(core.device.handle, core.swapchain.handle, timeout, frame.swapchain_semaphore, null, &swapchain_image_index);
    if (e == c.VK_ERROR_OUT_OF_DATE_KHR) {
        // log.warn("out of date", .{});
        core.resize_request = true;
        return;
    }
    check_vk(c.vkResetFences(core.device.handle, 1, &frame.render_fence)) catch @panic("Failed to reset render fence");
    const cmd = frame.command_buffer;
    check_vk(c.vkResetCommandBuffer(cmd, 0)) catch @panic("Failed to reset command buffer");

    const cmd_begin_info = std.mem.zeroInit(c.VkCommandBufferBeginInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });

    check_vk(c.vkBeginCommandBuffer(cmd, &cmd_begin_info)) catch @panic("Failed to begin command buffer");

    transition_image(cmd, core.swapchain.images[swapchain_image_index], c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
    // const clearvalue = c.VkClearColorValue{ .float32 = .{ 0, 0.1, 0.1, 1 } };
    // const clearrange = c.VkImageSubresourceRange{
    //     .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
    //     .levelCount = 1,
    //     .layerCount = 1,
    // };
    // c.vkCmdClearColorImage(cmd, core.swapchain.images[swapchain_image_index], c.VK_IMAGE_LAYOUT_GENERAL, &clearvalue, 1, &clearrange);
    const extent = core.swapchain.extent;

    const color_attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = core.swapchain.image_views[swapchain_image_index],
        .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
    };

    const render_info: c.VkRenderingInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
    };

    const viewport: c.VkViewport = .{
        .x = 0.0,
        .y = 0.0,
        .width = @as(f32, @floatFromInt(extent.width)),
        .height = @as(f32, @floatFromInt(extent.height)),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    const scissor: c.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    c.vkCmdBeginRendering(cmd, &render_info);
    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, core.pipelines[0]);
    c.vkCmdSetViewport(cmd, 0, 1, &viewport);
    c.vkCmdSetScissor(cmd, 0, 1, &scissor);
    core.vkCmdDrawMeshTasksEXT.?(cmd, 1, 1, 1);
    c.vkCmdEndRendering(cmd);

    transition_image(cmd, core.swapchain.images[swapchain_image_index], c.VK_IMAGE_LAYOUT_GENERAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);

    check_vk(c.vkEndCommandBuffer(cmd)) catch @panic("Failed to end command buffer");

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

    check_vk(c.vkQueueSubmit2(core.device.graphics_queue, 1, &submit, frame.render_fence)) catch |err| {
        std.log.err("Failed to submit to graphics queue with error: {s}", .{@errorName(err)});
        @panic("Failed to submit to graphics queue");
    };

    const present_info = c.VkPresentInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &frame.render_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &core.swapchain.handle,
        .pImageIndices = &swapchain_image_index,
    };
    e = c.vkQueuePresentKHR(core.device.graphics_queue, &present_info);
    core.frame_number +%= 1;
    core.framecontext.switch_frame();
}
