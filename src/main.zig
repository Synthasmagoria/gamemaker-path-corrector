const std = @import("std");
const builtin = std.builtin;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const arguments = @import("args.zig");
const c = @import("c.zig").c;
const zpl = @import("zpl.zig");
const cast = @import("cast.zig");
const string = @import("string.zig");

pub fn printerr(stderr: *std.io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try stderr.print("error: " ++ fmt ++ "\n", args);
}

pub fn prints(str: []const u8) void {
    print("{s}\n", .{str});
}

pub fn printd(a: anytype) void {
    print("{d}\n", .{a});
}

pub fn init_fsmap(alloc: Allocator, dir_path: []const u8) !std.StringHashMap([]const u8) {
    var fs_map = std.StringHashMap([]const u8).init(alloc);
    const dir = try std.fs.openDirAbsolute(dir_path, .{.iterate = true});
    var walker = try dir.walk(alloc);
    while (try walker.next()) |item| {
        const key = try alloc.dupe(u8, item.path);
        string.lower(key);
        try fs_map.put(key, item.path);
    }
    return fs_map;
}

pub fn main() !void {
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try arguments.init_list(alloc);
    arguments.verify_list(args) catch |err| {
        switch (err) {
            error.TooFewArguments => {
                try arguments.print_help_message(stderr);
            },
            error.TooManyArguments => {
                try printerr(stderr, "Too many arguments ({d})", .{args.items.len - 1});
                try arguments.print_help_message(stderr);
            }
        }
        try stderr.flush();
        return;
    };

    const absolute_project_path = args.items[1];
    arguments.verify_project_path(absolute_project_path) catch |err| {
        switch (err) {
            error.Empty => {
                try printerr(stderr, "Empty path", .{});
            },
            error.InvalidExtension => {
                const extension = std.fs.path.extension(absolute_project_path);
                try printerr(stderr, "Invalid extension '{s}'. Expected .yyp", .{extension});
            },
            error.NotAbsolute => {
                try printerr(stderr, "Path was not absolute. Must start with a '/'", .{});
            },
            error.PointsToFolder => {
                try printerr(stderr, "Path points to folder (trailing /)", .{});
            },
            error.CouldntOpen => {
                try printerr(stderr, "Couldn't open file at location", .{});
            }
        }
        try stderr.flush();
        return;
    };

    var root: zpl.AdtNode = undefined;
    const zpl_alloc = c.zpl_heap_allocator();
    const json5_error = try zpl.parse_json5(alloc, zpl_alloc, absolute_project_path, &root);
    switch (json5_error) {
        c.ZPL_JSON_ERROR_NONE => {},
        else => {
            try printerr(stderr, "Couldn't parse JSON5 for some reason", .{});
            return;
        }
    }

    const resources = root.query_type("resources", zpl.AdtNodeType.Array);
    if (resources == null) {
        try printerr(stderr, "Couldn't find resources array in YYP", .{});
        return;
    }

    const absolute_project_directory = std.fs.path.dirname(absolute_project_path) orelse unreachable; // <- is this really true tho?
    const fs_map = try init_fsmap(alloc, absolute_project_directory);
    _ = fs_map;

    const resources_array_header = resources.?.get_array_header();
    var broken_paths = try std.ArrayList([]const u8).initCapacity(alloc, cast.i2u(resources_array_header.count));
    for (0..cast.i2u(resources_array_header.count)) |i| {

        const node = resources.?.get_array_child(i);

        if (node.query("id/path")) |path_node| {
            std.debug.assert(path_node.is_type(zpl.AdtNodeType.String));
            const rel_path = @constCast(std.mem.span(path_node.data.string));
            const absolute_resource_path = try std.fs.path.join(alloc, &.{absolute_project_directory, rel_path});

            std.fs.accessAbsolute(absolute_resource_path, .{}) catch {
                try broken_paths.append(alloc, absolute_resource_path);
            };
        } else {
            // FAIL CASE:
        }
    }
}
