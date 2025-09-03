const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const builtin = @import("builtin");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const arguments = @import("args.zig");
const c = @import("c.zig").c;
const zpl = @import("zpl.zig");

const ConfidentStringBuilder = struct {
    buffer: []u8,
    index: usize,
    pub fn append(self: *ConfidentStringBuilder, str: []const u8) void {
        @memcpy(self.buffer[self.index..self.index + str.len], str);
        self.index += str.len;
    }
};

pub fn path_change_basename_noext_alloc(alloc: Allocator, path: []const u8, new_name: []const u8) ![]const u8 {
    const old_basename_noext = path_basename_noext(path);
    const renamed_buffer = try alloc.alloc(u8, path.len - old_basename_noext.len + new_name.len);
    var renamed_builder = ConfidentStringBuilder{.buffer = renamed_buffer, .index = 0};

    const dir_copy_length = path.len - fs.path.basename(path).len;
    renamed_builder.append(path[0..dir_copy_length]);
    renamed_builder.append(new_name);
    renamed_builder.append(fs.path.extension(path));
    return renamed_builder.buffer;
}

pub fn path_basename_noext(path: []const u8) []const u8 {
    return path_truncate_extension(fs.path.basename(path));
}

pub fn yy_set_sound_file_string(alloc: Allocator, dir: fs.Dir, path: []const u8, sound_file_name: []const u8) !void {
    const f = dir.openFile(path, .{}) catch {
        try printerr("Couldn't open sound resource at '{s}'\n", .{path});
        return;
    };
    const json5_string = try f.readToEndAlloc(alloc, std.math.maxInt(usize));
    f.close();

    const zpl_alloc = c.zpl_heap_allocator();
    defer c.zpl_free_all(zpl_alloc);
    var root: zpl.AdtNode = undefined;
    const json5_error = c.zpl_json_parse(@ptrCast(&root), json5_string.ptr, zpl_alloc);
    switch (json5_error) {
        c.ZPL_JSON_ERROR_NONE => {},
        else => {
            try printerr("Couldn't parse JSON5 in .yy sound resource for some reason '{s}'", .{path});
            return;
        }
    }

    if ((&root).query_type("soundFile", zpl.AdtNodeType.String)) |sound_file_node| {
        const original_sound_file_string = std.mem.span(sound_file_node.data.string);
        const original_sound_file_extension = fs.path.extension(original_sound_file_string);
        sound_file_node.data.string = try std.mem.joinZ(alloc, "", &.{sound_file_name, original_sound_file_extension});
    }

    const zpl_string = c.zpl_json_write_string(zpl_alloc, @ptrCast(&root), 0);
    const json5_str_new = mem.span(@as([*:0]u8, @ptrCast(zpl_string)));
    try dir.writeFile(.{.data = json5_str_new, .sub_path = path});
}

pub fn dupez(alloc: Allocator, str: []const u8) ![*:0]u8 {
    const strz = try alloc.alloc(u8, str.len + 1);
    @memcpy(strz[0..str.len], str);
    strz[str.len] = 0;
    return @ptrCast(strz.ptr);
}

const DirectoryFixFilesResult = struct {
    renamed_files: usize,
    renamed_resource: bool
};
pub fn directory_fix_files(alloc: Allocator, fix: PathFixSuggestion, proj_dir: fs.Dir, dirpath: []const u8, out: *DirectoryFixFilesResult, dry_run: bool) !void {
    const iterable_dir = proj_dir.openDir(dirpath, .{.iterate = true, .access_sub_paths = false}) catch {
        const msg =
            \\Couldn't open directory {s}
            \\Please try again, or rename manually
            \\
        ;
        try printerr(msg, .{dirpath});
        return;
    };
    const is_sound_resource = std.mem.containsAtLeast(u8, dirpath, 1, "sounds" ++ [_]u8{fs.path.sep});
    var walker = try iterable_dir.walk(alloc);
    const new_name = path_basename_noext(fix.new_path);
    const new_name_lower = try string_allocate_lower(alloc, new_name);

    while (try walker.next()) |item| {
        if (item.kind != .file) {
            continue;
        }
        const current_name = path_truncate_extension(item.basename);
        const current_name_lower = try string_allocate_lower(alloc, current_name);

        if (mem.eql(u8, new_name_lower, current_name_lower)) {
            const renamed_path = try path_change_basename_noext_alloc(alloc, item.path, new_name);
            //print("{s} -> {s}\n", .{item.path, renamed_path});
            if (dry_run) {
                continue;
            }
            iterable_dir.rename(item.path, renamed_path) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {
                        try printerr(
                            "Couldn't rename {s} to {s}. File already existed. Please rename manually",
                            .{item.path, renamed_path});
                        continue;
                    },
                    else => {
                        try printerr(
                            "Couldn't rename {s} to {s}. Please rename manually",
                            .{item.path, renamed_path});
                        continue;
                    }
                }
            };
            if (mem.eql(u8, fs.path.extension(item.path), ".yy")) {
                out.renamed_resource = true;
                if (is_sound_resource) {
                    try yy_set_sound_file_string(alloc, iterable_dir, renamed_path, path_basename_noext(renamed_path));
                }
            } else {
                out.renamed_files += 1;
            }
        }
    }
}

pub fn path_truncate_extension(path: []const u8) []const u8 {
    return path[0..path.len - fs.path.extension(path).len];
}

pub fn string_lower(str: []u8) void {
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] >= 'A' and str[i] <= 'Z') {
            str[i] += 'a' - 'A';
        }
    }
}

pub fn string_allocate_lower(alloc: Allocator, str: []const u8) ![]const u8 {
    const str_lower = try alloc.dupe(u8, str);
    string_lower(@constCast(str_lower));
    return str_lower;
}

pub fn dupe_string_buffer(buffer: []u8, string: []const u8) []const u8 {
    // TODO: Return error
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
            const k = try alloc.alloc(u8, item.path.len);
            if (builtin.os.tag == .windows) {
                _ = std.mem.replace(u8, item.path, &.{fs.path.sep_windows}, &.{fs.path.sep_posix}, k);
            }
            string_lower(k);
            const v = try alloc.dupe(u8, item.path);
            try fs_map.put(alloc, k, v);
        }
    }
    return fs_map;
}

const PathFixSuggestion = struct {
    old_path: []const u8,
    new_path: []const u8
};

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
    const fsmap = try init_fsmap(alloc, absolute_project_directory);
    var path_buffer = [_]u8{0} ** RELATIVE_PATH_LENGTH_MAX;
    var path_fix_suggestion = try std.ArrayList(PathFixSuggestion).initCapacity(alloc, BROKEN_PATH_LIST_STARTING_CAPACITY);

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
                const new_path = try alloc.dupe(u8, rel_path);
                try broken_paths.append(alloc, try alloc.dupe(u8, new_path));

                const rel_path_lower = @constCast(dupe_string_buffer(&path_buffer, rel_path));
                string_lower(rel_path_lower);
                if (fsmap.get(rel_path_lower)) |old_path| {
                    try path_fix_suggestion.append(alloc, .{.old_path = old_path, .new_path = new_path});
                }
            };
        } else {
            unreachable; // TODO: Error code. Corrupted project
        }
    }

    // TODO: Options to view the path lists and unrenamable paths
    try stdout.print("Path analysis done\n", .{});
    try stdout.print("Broken resource paths: {d}/{d}\n", .{broken_paths.items.len, resources_array_header.count});
    try stdout.print("Fixable resource paths: {d}/{d}\n", .{path_fix_suggestion.items.len, broken_paths.items.len});
    try stdout.print("Continue (y/n): ", .{});
    try stdout.flush();
    var continue_input = [1]u8{0};
    _ = stdin.readSliceShort(&continue_input) catch {
        try printerr("Failed to read input", .{});
        return;
    };
    string_lower(&continue_input);
    var dry_run: bool = false;
    if (continue_input[0] == 'y') {
    } else if (continue_input[0] == 'n') {
        try stdout.print("Aborting...\n", .{});
        try stdout.flush();
        return;
    } else if (continue_input[0] == 'd') {
        dry_run = true;
    } else {
        try printerr("Invalid input", .{});
        return;
    }

    var renamed_dirs: usize = 0;
    var renamed_resources: usize = 0;
    var renamed_files: usize = 0;

    var rename_arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer rename_arena_alloc.deinit();
    const rename_alloc = rename_arena_alloc.allocator();

    for (path_fix_suggestion.items) |path_fix| {
        if (fs.path.dirname(path_fix.old_path)) |res_dirname| {
            var result = DirectoryFixFilesResult{.renamed_files = 0, .renamed_resource = false};
            try directory_fix_files(rename_alloc, path_fix, project_directory, res_dirname, &result, dry_run);
            renamed_files += result.renamed_files;
            if (result.renamed_resource) {
                renamed_resources += 1;
            }
        }

        const old_directory = fs.path.dirname(path_fix.old_path);
        if (old_directory == null) {
            try printerr("Something went wrong 1. Please contact author.", .{});
            continue;
        }
        const new_directory = fs.path.dirname(path_fix.new_path);
        if (new_directory == null) {
            try printerr("Something went wrong 2. Please contact author", .{});
            continue;
        }

        if (!dry_run) {
            project_directory.rename(old_directory.?, new_directory.?) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {
                        const msg =
                            \\Couldn't rename directory '{s}' to '{s}'.
                            \\Something already exists with the same name.
                            \\Please rename manually.
                            \\
                        ;
                        try printerr(msg, .{old_directory.?, new_directory.?});
                    },
                    else => {
                        const msg =
                            \\Couldn't rename directory '{s}' to '{s}'.
                            \\Please rename manually.
                            \\
                        ;
                        try printerr(msg, .{old_directory.?, new_directory.?});
                    }
                }
                continue;
            };
            renamed_dirs += 1;
        }

        _ = rename_arena_alloc.reset(.retain_capacity);
    }

    try stdout.print("Done!\n", .{});
    try stdout.print("Renamed resources: {d}/{d}\n", .{renamed_resources, path_fix_suggestion.items.len});
    try stdout.print("Renamed folders: {d}/{d}\n", .{renamed_dirs, path_fix_suggestion.items.len});
    try stdout.print("Additional renamed files: {d}\n", .{renamed_files});
    try stdout.flush();
}
