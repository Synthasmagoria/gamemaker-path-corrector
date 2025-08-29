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

pub fn printinfo(stdout: *std.io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try stdout.print("info: " ++ fmt ++ "\n", args);
}

pub fn prints(str: []const u8) void {
    print("{s}\n", .{str});
}

pub fn printd(a: anytype) void {
    print("{d}\n", .{a});
}

pub fn init_fsmap(alloc: Allocator, dir_path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var fs_map = std.StringHashMapUnmanaged([]const u8).empty;
    var dir = try std.fs.openDirAbsolute(dir_path, .{.iterate = true});
    defer dir.close();
    var walker = try dir.walk(alloc);
    while (try walker.next()) |item| {
        if (item.kind == .file and
            std.mem.count(u8, item.path, &.{std.fs.path.sep}) == 2 and
            std.mem.eql(u8, std.fs.path.extension(item.path), ".yy")) {
            const k = try alloc.dupe(u8, item.path);
            string.lower(k);
            const v = try alloc.dupe(u8, item.path);
            try fs_map.put(alloc, k, v);
        }
    }
    return fs_map;
}

const RELATIVE_PATH_LENGTH_MAX: usize = 2048;
const BROKEN_PATH_LIST_STARTING_CAPACITY = 1000;

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
        try printerr(stderr, "Couldn't find resources array in project file", .{});
        return;
    }

    const absolute_project_directory = std.fs.path.dirname(absolute_project_path) orelse unreachable; // <- is this really true tho?
    const resources_array_header = resources.?.get_array_header();
    var project_directory = try std.fs.openDirAbsolute(absolute_project_directory, .{});
    defer project_directory.close();
    var broken_paths = try std.ArrayList([]const u8).initCapacity(alloc, BROKEN_PATH_LIST_STARTING_CAPACITY);
    var broken_paths_renamable = try std.ArrayList([]const u8).initCapacity(alloc, BROKEN_PATH_LIST_STARTING_CAPACITY);
    const fsmap = try init_fsmap(alloc, absolute_project_directory);

    for (0..cast.i2u(resources_array_header.count)) |i| {
        const node = resources.?.get_array_child(i);
        if (node.query("id/path")) |path_node| {
            std.debug.assert(path_node.is_type(zpl.AdtNodeType.String));
            const rel_path = @constCast(std.mem.span(path_node.data.string));
            project_directory.access(rel_path, .{}) catch {
                if (rel_path.len > RELATIVE_PATH_LENGTH_MAX) {
                    try printerr(
                        stderr,
                        "Relative path length '{d}' exceeded maximum path length '{d}'",
                        .{rel_path.len, RELATIVE_PATH_LENGTH_MAX});
                    return;
                }
                try broken_paths.append(alloc, try alloc.dupe(u8, rel_path));

                var path_buffer = [_]u8{0} ** RELATIVE_PATH_LENGTH_MAX;
                const path_buffer_slice = path_buffer[0..rel_path.len];
                @memcpy(path_buffer_slice, rel_path);
                string.lower(path_buffer_slice);
                if (fsmap.contains(path_buffer_slice)) {
                    try broken_paths_renamable.append(alloc, try alloc.dupe(u8, path_buffer_slice));
                }
            };
        } else {
            unreachable; // Every resource entry should have this
        }
    }

    print("Broken paths: {d}, renamable: {d}\n", .{broken_paths.items.len, broken_paths_renamable.items.len});
    // TODO: Options to view the path lists and unrenamable paths

}
