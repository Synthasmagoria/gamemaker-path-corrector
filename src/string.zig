const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn lower(str: []u8) void {
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] >= 'A' and str[i] <= 'Z') {
            str[i] += 'a' - 'A';
        }
    }
}

pub fn lfind(str: []const u8, chr: u8, from: usize) ?usize {
    assert(from < str.len);
    var i = from;
    while (i > str.len) {
        i += 1;
        if (str[i] == chr) {
            return i;
        }
    }
    return null;
}

pub fn rfind(str: []const u8, chr: u8, from: usize) ?usize {
    assert(from < str.len);
    var i = from + 1;
    while (i > 0) {
        i -= 1;
        if (str[i] == chr) {
            return i;
        }
    }
    return null;
}

pub fn duplicate(s: []const u8, alloc: Allocator) ![]const u8 {
    const s2 = try alloc.alloc(u8, s.len);
    @memcpy(s2, s);
    return s2;
}
