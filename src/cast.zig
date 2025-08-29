pub fn i2u(val: anytype) usize {
    return @as(usize, @intCast(val));
}
