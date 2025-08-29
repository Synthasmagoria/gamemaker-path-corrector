const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

pub fn init_list(alloc: Allocator) !std.ArrayList([]u8) {
    var args = try std.process.argsWithAllocator(alloc);
    var arg_list = try std.ArrayList([]u8).initCapacity(alloc, 10);
    while (args.next()) |arg| {
        try arg_list.append(alloc, try alloc.dupe(u8, arg));
    }
    return arg_list;
}

pub fn is_help(str: []u8) bool {
    return
        mem.eql(u8, str, "--help") or
        mem.eql(u8, str, "-h");
}

pub fn print_help_message(out: *std.io.Writer) !void {
    const msg =
        \\--- GAMEMAKER PATH CORRECTOR ---
        \\Usage: gamemaker-path-corrector <project path>
        \\If on windows, make sure that case sensitivity is turned on for project folder
        \\https://learn.microsoft.com/en-us/windows/wsl/case-sensitivity#change-the-case-sensitivity-of-files-and-directories
    ;
    try out.print("{s}\n", .{msg});
}

pub const ArgumentsVerifyListError = error{
    TooFewArguments,
    TooManyArguments
};

pub fn verify_list(list: std.ArrayList([]u8)) ArgumentsVerifyListError!void {
    switch (list.items.len) {
        0, 1 => {
            return ArgumentsVerifyListError.TooFewArguments;
        },
        2 => {
            return;
        },
        else => {
            return ArgumentsVerifyListError.TooManyArguments;
        },
    }
}

pub const ArgumentsProjectPathVerifyError = error{
    Empty,
    InvalidExtension,
    NotAbsolute,
    PointsToFolder,
    CouldntOpen
};
pub fn verify_project_path(path: []u8) !void {
    if (path.len == 0) {
        return ArgumentsProjectPathVerifyError.Empty;
    }
    if (std.fs.path.basename(path).len == 0) {
        return ArgumentsProjectPathVerifyError.PointsToFolder;
    }
    if (!mem.eql(u8, std.fs.path.extension(path), ".yyp")) {
        return ArgumentsProjectPathVerifyError.InvalidExtension;
    }
    if (!std.fs.path.isAbsolute(path)) {
        return ArgumentsProjectPathVerifyError.NotAbsolute;
    }
    std.fs.accessAbsolute(path, .{}) catch {
        return ArgumentsProjectPathVerifyError.CouldntOpen;
    };
}
