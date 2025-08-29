const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const builtin = std.builtin;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const arguments = @import("args.zig");
const c = @import("c.zig").c;
const zpl = @import("zpl.zig");

pub fn string_lower(str: []u8) void {
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] >= 'A' and str[i] <= 'Z') {
            str[i] += 'a' - 'A';
        }
    }
}

pub fn dupe_string_buffer(buffer: []u8, string: []const u8) []const u8 {
    const buffer_slice = buffer[0..string.len];
    @memcpy(buffer_slice, string);
    return buffer_slice;
}

pub fn printerr(comptime fmt: []const u8, args: anytype) !void {
    try stderr.print("error: " ++ fmt ++ "\n", args);
    try stderr.flush();
}

pub fn printerr_noflush(comptime fmt: []const u8, args: anytype) !void {
    try stderr.print("error: " ++ fmt ++ "\n", args);
}

pub fn printinfo(comptime fmt: []const u8, args: anytype) !void {
    try stdout.print("info: " ++ fmt ++ "\n", args);
    try stdout.flush();
}

pub fn printinfo_noflush(comptime fmt: []const u8, args: anytype) !void {
    try stdout.print("info: " ++ fmt ++ "\n", args);
}

// TODO: Automatically remove in release mode
pub fn prints(str: []const u8) void {
    print("{s}\n", .{str});
}

pub fn printd(a: anytype) void {
    print("{d}\n", .{a});
}

pub fn init_fsmap(alloc: Allocator, dir_path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var fs_map = std.StringHashMapUnmanaged([]const u8).empty;
    var dir = try fs.openDirAbsolute(dir_path, .{.iterate = true});
    defer dir.close();
    var walker = try dir.walk(alloc);
    while (try walker.next()) |item| {
        if (item.kind == .file and
            mem.count(u8, item.path, &.{fs.path.sep}) == 2 and
            mem.eql(u8, fs.path.extension(item.path), ".yy")) {
            const k = try alloc.dupe(u8, item.path);
            string_lower(k);
            const v = try alloc.dupe(u8, item.path);
            try fs_map.put(alloc, k, v);
        }
    }
    return fs_map;
}

const RELATIVE_PATH_LENGTH_MAX: usize = 2048;
const BROKEN_PATH_LIST_STARTING_CAPACITY = 1000;
const IO_BUFFER_SIZE = 1024;

var stderr_buffer: [IO_BUFFER_SIZE]u8 = undefined;
var stderr_writer: fs.File.Writer = undefined;
var stderr: *std.io.Writer = undefined;

var stdout_buffer: [IO_BUFFER_SIZE]u8 = undefined;
var stdout_writer: fs.File.Writer = undefined;
var stdout: *std.io.Writer = undefined;

var stdin_buffer: [IO_BUFFER_SIZE]u8 = undefined;
var stdin_reader: fs.File.Reader = undefined;
var stdin: *std.io.Reader = undefined;

pub fn init() void {
    stderr_writer = fs.File.stderr().writer(&stderr_buffer);
    stderr = &stderr_writer.interface;
    stdout_writer = fs.File.stdout().writer(&stdout_buffer);
    stdout = &stdout_writer.interface;
    stdin_reader = fs.File.stdin().reader(&stdin_buffer);
    stdin = &stdin_reader.interface;
}

pub fn main() !void {
    init();
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    const args = try arguments.init_list(alloc);
    arguments.verify_list(args) catch |err| {
        switch (err) {
            error.TooFewArguments => {
                try arguments.print_help_message(stderr);
            },
            error.TooManyArguments => {
                try printerr("Too many arguments ({d})", .{args.items.len - 1});
                try arguments.print_help_message(stderr);
            }
        }
        return;
    };

    const absolute_project_path = args.items[1];
    arguments.verify_project_path(absolute_project_path) catch |err| {
        switch (err) {
            error.Empty => {
                try printerr("Empty path", .{});
            },
            error.InvalidExtension => {
                const extension = fs.path.extension(absolute_project_path);
                try printerr("Invalid extension '{s}'. Expected .yyp", .{extension});
            },
            error.NotAbsolute => {
                try printerr("Path was not absolute. Must start with a '/'", .{});
            },
            error.PointsToFolder => {
                try printerr("Path points to folder (trailing /)", .{});
            },
            error.CouldntOpen => {
                try printerr("Couldn't open file at location", .{});
            }
        }
        return;
    };

    var root: zpl.AdtNode = undefined;
    const zpl_alloc = c.zpl_heap_allocator();
    const json5_error = try zpl.parse_json5(alloc, zpl_alloc, absolute_project_path, &root);
    switch (json5_error) {
        c.ZPL_JSON_ERROR_NONE => {},
        else => {
            try printerr("Couldn't parse JSON5 for some reason", .{});
            return;
        }
    }

    const resources = root.query_type("resources", zpl.AdtNodeType.Array);
    if (resources == null) {
        try printerr("Couldn't find resources array in project file", .{});
        return;
    }

    const absolute_project_directory = fs.path.dirname(absolute_project_path) orelse unreachable; // <- is this really true tho?
    const resources_array_header = resources.?.get_array_header();
    var project_directory = try fs.openDirAbsolute(absolute_project_directory, .{});
    defer project_directory.close();
    var broken_paths = try std.ArrayList([]const u8).initCapacity(alloc, BROKEN_PATH_LIST_STARTING_CAPACITY);
    var broken_paths_renamable = try std.ArrayList([]const u8).initCapacity(alloc, BROKEN_PATH_LIST_STARTING_CAPACITY);
    const fsmap = try init_fsmap(alloc, absolute_project_directory);
    var path_buffer = [_]u8{0} ** RELATIVE_PATH_LENGTH_MAX;

    for (0..@as(usize, @intCast(resources_array_header.count))) |i| {
        const node = resources.?.get_array_child(i);
        if (node.query("id/path")) |path_node| {
            std.debug.assert(path_node.is_type(zpl.AdtNodeType.String));
            const rel_path = @constCast(mem.span(path_node.data.string));
            project_directory.access(rel_path, .{}) catch {
                if (rel_path.len > RELATIVE_PATH_LENGTH_MAX) {
                    try printerr(
                        "Relative path length '{d}' exceeded maximum path length '{d}'",
                        .{rel_path.len, RELATIVE_PATH_LENGTH_MAX});
                    return;
                }
                try broken_paths.append(alloc, try alloc.dupe(u8, rel_path));

                const rel_path_lower = @constCast(dupe_string_buffer(&path_buffer, rel_path));
                string_lower(rel_path_lower);
                if (fsmap.contains(rel_path_lower)) {
                    try broken_paths_renamable.append(alloc, try alloc.dupe(u8, rel_path));
                }
            };
        } else {
            unreachable; // TODO: Error code. Corrupted project
        }
    }

    // TODO: Options to view the path lists and unrenamable paths
    try stdout.print("Path analysis done\n", .{});
    try stdout.print("Broken resource paths: {d}/{d}\n", .{broken_paths.items.len, resources_array_header.count});
    try stdout.print("Fixable resource paths: {d}/{d}\n", .{broken_paths_renamable.items.len, broken_paths.items.len});
    try stdout.print("Continue (y/n): ", .{});
    try stdout.flush();
    var continue_input = [1]u8{0};
    _ = stdin.readSliceShort(&continue_input) catch {
        try printerr("Failed to read input", .{});
        return;
    };
    string_lower(&continue_input);
    if (continue_input[0] == 'y') {
    } else if (continue_input[0] == 'n') {
        try stdout.print("Aborting\n", .{});
        try stdout.flush();
        return;
    } else {
        try printerr("Invalid input", .{});
        return;
    }

    var current_path_key_buffer = [_]u8{0} ** RELATIVE_PATH_LENGTH_MAX;
    var rename_path_buffer = [_]u8{0} ** RELATIVE_PATH_LENGTH_MAX;
    var renamed_dirs: i64 = 0;
    var renamed_files: i64 = 0;
    for (broken_paths_renamable.items) |right_path| {
        var right_path_iterator = try fs.path.componentIterator(right_path);
        const right_path_resource_component = right_path_iterator.last();

        const current_path_key = @constCast(dupe_string_buffer(&current_path_key_buffer, right_path));
        string_lower(current_path_key);
        const current_path = fsmap.get(current_path_key) orelse unreachable;

        const rename_path = @constCast(dupe_string_buffer(&rename_path_buffer, current_path));
        const resource_rename_start = right_path_resource_component.?.path.len - right_path_resource_component.?.name.len;
        @memcpy(rename_path[resource_rename_start..], right_path[resource_rename_start..]);
        project_directory.rename(current_path, rename_path) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    try printerr(
                        "Couldn't rename file '{s}' to '{s}'. It already exists. Please rename manually.",
                        .{current_path, rename_path});
                },
                else => {
                    try printerr(
                        "Couldn't rename file '{s}' to '{s}'",
                        .{current_path, rename_path});
                }
            }
            renamed_files -= 1;
        };
        renamed_files += 1;

        const right_path_directory_component = right_path_iterator.previous();
        const directory_rename_start =
            right_path_directory_component.?.path.len -
            right_path_directory_component.?.name.len;
        @memcpy(rename_path[directory_rename_start..], right_path[directory_rename_start..]);

        const directory_end = right_path_directory_component.?.path.len;
        const current_directory = current_path[0..directory_end];
        const rename_directory = rename_path[0..directory_end];
        project_directory.rename(current_directory, rename_directory) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    try printerr(
                        "Couldn't rename directory '{s}' to '{s}'. It already exists. Please rename manually.",
                        .{current_directory, rename_directory});
                },
                else => {
                    try printerr("Couldn't rename directory '{s}' to '{s}'",
                        .{current_directory, rename_directory});
                }
            }
            renamed_dirs -= 1;
        };
        renamed_dirs += 1;
    }

    try stdout.print("Done\n", .{});
    try stdout.print("Renamed files: {d}/{d}\n", .{renamed_files, broken_paths_renamable.items.len});
    try stdout.print("Renamed folders: {d}/{d}\n", .{renamed_dirs, broken_paths_renamable.items.len});
    try stdout.flush();
}
