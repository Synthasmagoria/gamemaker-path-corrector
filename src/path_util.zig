const string = @import("string.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn up(path: []const u8) []const u8 {
    const last_slash = string.rfind(path, '/', path.len - 1) orelse 0;
    return path[0..last_slash + 1];
}

pub fn is_absolute(a: []const u8) bool {
    return a[0] == '/';
}

pub fn combine_alloc(a: []const u8, b: []const u8, alloc: Allocator) ![]const u8 {
    const a_last = a[a.len - 1];
    const b_first = b[0];
    const slash = '/';
    if (a_last == slash and b_first == slash) {
        var str = try alloc.alloc(u8, a.len - 1 + b.len);
        @memcpy(str[0..a.len], a);
        @memcpy(str[a.len..], b[1..]);
        return str;
    } else if (a_last == slash or b_first == slash) {
        var str = try alloc.alloc(u8, a.len + b.len);
        @memcpy(str[0..a.len], a);
        @memcpy(str[a.len..], b);
        return str;
    } else {
        var str = try alloc.alloc(u8, a.len + 1 + b.len);
        @memcpy(str[0..a.len], a);
        str[a.len] = '/';
        @memcpy(str[a.len + 1 ..], b);
        return str;
    }
}
