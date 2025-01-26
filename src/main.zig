const std = @import("std");
const graphics = @import("vulkan/core.zig");
const c = @import("clibs.zig");
const Window = @import("window.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const window_extent = c.VkExtent2D{ .width = 1600, .height = 900 };
    var win = Window.init(window_extent);
    defer win.deinit();
    graphics.run(gpa, &win);
}
