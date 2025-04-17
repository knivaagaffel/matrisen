const c = @import("clibs");
const std = @import("std");
const debug = @import("debug.zig");
const Core = @import("core.zig");
const Images = @import("images.zig");
const FrameSubmitContext = @import("commands.zig").FrameSubmitContext;
const alloc_cb = @import("core.zig").vkallocationcallbacks;
const log = std.log.scoped(.swapchain);

handle: c.VkSwapchainKHR = null,
resizerequest: bool = false,
format: c.VkFormat = undefined,
extent: c.VkExtent2D = .{},
draw_extent: c.VkExtent2D = .{},
images: []c.VkImage = &.{},
imageviews: []c.VkImageView = &.{},

const Self = @This();

pub const SupportInfo = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR = undefined,
    formats: []c.VkSurfaceFormatKHR = &.{},
    present_modes: []c.VkPresentModeKHR = &.{},

    pub fn init(a: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) SupportInfo {
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        debug.check_vk_panic(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities));

        var format_count: u32 = undefined;
        debug.check_vk_panic(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null));
        const formats = a.alloc(c.VkSurfaceFormatKHR, format_count) catch {
            log.err("failed to alloc", .{});
            @panic("");
        };
        debug.check_vk_panic(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr));

        var present_mode_count: u32 = undefined;
        debug.check_vk_panic(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null));
        const present_modes = a.alloc(c.VkPresentModeKHR, present_mode_count) catch {
            log.err("failed to alloc", .{});
            @panic("");
        };
        debug.check_vk_panic(c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            device,
            surface,
            &present_mode_count,
            present_modes.ptr,
        ));

        return .{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    pub fn deinit(self: *const SupportInfo, a: std.mem.Allocator) void {
        a.free(self.formats);
        a.free(self.present_modes);
    }
};

pub const CreateOpts = struct {
    physical_device: c.VkPhysicalDevice,
    graphics_queue_family: u32,
    present_queue_family: u32,
    device: c.VkDevice,
    surface: c.VkSurfaceKHR,
    old_swapchain: c.VkSwapchainKHR = null,
    format: c.VkSurfaceFormatKHR = undefined,
    vsync: bool = false,
    triple_buffer: bool = false,
    window_width: u32 = 0,
    window_height: u32 = 0,
    alloc_cb: ?*c.VkAllocationCallbacks = null,
};

pub fn init(core: *Core) void {
    var images = &core.images;
    const old_swapchain = null;
    const vsync = true;
    const desired_format = .{
        .format = c.VK_FORMAT_B8G8R8A8_SRGB,
        .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
    };
    const a = core.cpuallocator;

    const support_info = SupportInfo.init(a, core.physicaldevice.handle, core.surface);
    defer support_info.deinit(a);
    var format = support_info.formats[0];
    for (support_info.formats) |f| {
        if (f.format == desired_format.format and
            f.colorSpace == desired_format.colorSpace)
        {
            format = f;
            break;
        }
    }
    const present_mode = pick_present_mode(support_info.present_modes, vsync);
    // const present_mode_str = switch (present_mode) {
    //     c.Vk_PRESENT_MODE_FIFO_RELAXED_KHR => "FIFO Relaxed",
    //     c.Vk_PRESENT_MODE_MAILBOX_KHR => "Mailbox",
    //     c.Vk_PRESENT_MODE_FIFO_KHR => "FIFO",
    //     else => "unknown",
    // };
    // const format_str = switch (format.format) {
    //     c.Vk_FORMAT_B8G8R8A8_SRGB => "B8G8R8A8 SRBG",
    //     else => "unknown",
    // };
    // log.info("format: {s}, present mode: {s}", .{ format_str, present_mode_str });
    var extent = c.VkExtent2D{ .width = images.swapchain_extent.width, .height = images.swapchain_extent.height };
    extent.width = @max(support_info.capabilities.minImageExtent.width, @min(
        support_info.capabilities.maxImageExtent.width,
        extent.width,
    ));
    extent.height = @max(support_info.capabilities.minImageExtent.height, @min(
        support_info.capabilities.maxImageExtent.height,
        extent.height,
    ));
    if (support_info.capabilities.currentExtent.width != std.math.maxInt(u32)) {
        extent = support_info.capabilities.currentExtent;
    }

    const image_count = blk: {
        const desired_count = support_info.capabilities.minImageCount + 1;
        if (support_info.capabilities.maxImageCount > 0) {
            break :blk @min(desired_count, support_info.capabilities.maxImageCount);
        }
        break :blk desired_count;
    };

    var swapchain_info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = core.surface,
        .minImageCount = image_count,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .preTransform = support_info.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = old_swapchain,
    };

    if (core.physicaldevice.graphics_queue_family != core.physicaldevice.present_queue_family) {
        const queue_family_indices: []const u32 = &.{
            core.physicaldevice.graphics_queue_family,
            core.physicaldevice.present_queue_family,
        };
        swapchain_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        swapchain_info.queueFamilyIndexCount = 2;
        swapchain_info.pQueueFamilyIndices = queue_family_indices.ptr;
    } else {
        swapchain_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    }

    var swapchain: c.VkSwapchainKHR = undefined;
    debug.check_vk_panic(c.vkCreateSwapchainKHR(core.device.handle, &swapchain_info, alloc_cb, &swapchain));
    errdefer c.vkDestroySwapchainKHR(core.device.handle, swapchain, alloc_cb);

    // Try and fetch the images from the swpachain.
    var swapchain_image_count: u32 = undefined;
    debug.check_vk_panic(c.vkGetSwapchainImagesKHR(core.device.handle, swapchain, &swapchain_image_count, null));
    const swapchain_images = a.alloc(c.VkImage, swapchain_image_count) catch {
        log.err("failed to alloc", .{});
        @panic("");
    };
    errdefer a.free(swapchain_images);
    debug.check_vk_panic(c.vkGetSwapchainImagesKHR(core.device.handle, swapchain, &swapchain_image_count, swapchain_images.ptr));

    // Create image views for the swapchain images.
    const swapchain_image_views = a.alloc(c.VkImageView, swapchain_image_count) catch {
        log.err("failed to alloc", .{});
        @panic("");
    };
    errdefer a.free(swapchain_image_views);

    for (swapchain_images, swapchain_image_views) |image, *view| {
        view.* = create_swapchain_image_views(core.device.handle, image, format.format);
    }

    images.swapchain_extent = extent;
    images.swapchain_format = format.format;
    images.swapchain = swapchain_images;
    images.swapchain_views = swapchain_image_views;
    core.swapchain.handle = swapchain;
}

pub fn deinit(core: *Core) void {
    c.vkDestroySwapchainKHR(core.device.handle, core.swapchain.handle, null);
}

fn pick_present_mode(modes: []const c.VkPresentModeKHR, vsync: bool) c.VkPresentModeKHR {
    if (vsync == true) {
        for (modes) |mode| {
            if (mode == c.VK_PRESENT_MODE_FIFO_RELAXED_KHR) {
                return mode;
            }
        }
    } else {
        for (modes) |mode| {
            if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                return mode;
            }
        }
    }
    // fallback
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn make_extent(capabilities: c.VkSurfaceCapabilitiesKHR, opts: CreateOpts) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }

    var extent = c.VkExtent2D{
        .width = opts.window_width,
        .height = opts.window_height,
    };

    extent.width = @max(capabilities.minImageExtent.width, @min(capabilities.maxImageExtent.width, extent.width));
    extent.height = @max(capabilities.minImageExtent.height, @min(capabilities.maxImageExtent.height, extent.height));

    return extent;
}

fn create_swapchain_image_views(device: c.VkDevice, image: c.VkImage, format: c.VkFormat) c.VkImageView {
    const view_info = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });

    var image_view: c.VkImageView = undefined;
    debug.check_vk_panic(c.vkCreateImageView(device, &view_info, alloc_cb, &image_view));
    return image_view;
}

pub fn acquireNextImage(self: *Self, core: *Core, frame: *FrameSubmitContext, timeout: u64) !void {
    const e = c.vkAcquireNextImageKHR(
        core.device.handle,
        self.handle,
        timeout,
        frame.swapchain_semaphore,
        null,
        &frame.swapchain_image_index,
    );
    if (e == c.VK_ERROR_OUT_OF_DATE_KHR) {
        self.resizerequest = true;
        return error.SwapchainOutOfDate;
    }
}

pub fn resize(self: *Self, core: *Core) void {
    debug.check_vk(c.vkDeviceWaitIdle(core.device.handle)) catch |err| {
        std.log.err("Failed to wait for device idle with error: {s}", .{@errorName(err)});
        @panic("Failed to wait for device idle");
    };
    deinit(core);
    c.vmaDestroyImage(
        core.gpuallocator,
        self.colorattachment.image,
        self.colorattachment.allocation,
    );
    c.vkDestroyImageView(core.device.handle, core.images.colorattachment.views[0], null);
    c.vmaDestroyImage(
        core.gpuallocator,
        self.resolvedattachment.image,
        self.resolvedattachment.allocation,
    );
    c.vkDestroyImageView(core.device.handle, self.resolvedattachment.views[0], null);
    c.vmaDestroyImage(
        core.gpuallocator,
        self.depthstencilattachment.image,
        self.depthstencilattachment.allocation,
    );
    c.vkDestroyImageView(core.device.handle, self.depthstencilattachment.views[0], null);
    for (self.imageviews) |view| {
        c.vkDestroyImageView(core.device.handle, view, null);
    }
    core.swapchain = .{};
    init(core);
    Images.createRenderAttachments(core);
    self.resizerequest = false;
}
