const std = @import("std");
const z2d = @import("z2d");

/// Describes a serialized text string with its path and text metrics.
pub const SerializedText = struct {
    path: SerializedPath,
    font_extents: z2d.font.Font.Extents,
    text_extents: z2d.text.Extents,

    /// Releases serialization data and invalidates the representation.
    pub fn deinit(self: *SerializedText, alloc: std.mem.Allocator) void {
        self.path.deinit(alloc);
        self.* = undefined;
    }
};

pub const SerializeTextError = z2d.text.ShapeTextError || SerializePathError;

/// Shapes text using the respective font and size, and returns its serialized
/// representation.
///
/// The text is always positioned at (0,0) relative to its baseline. This will
/// be reflective in the path data which will always likely have a negative
/// `top` value, and possibly a negative `left` value. The returned font and
/// text extents can be used to perform text-appropriate positioning and
/// spacing (e.g., applying translations as to where you want the baseline
/// origin to be, and appropriate vertical spacing).
///
/// The caller owns the memory created for the serialization, so make sure to
/// call `deinit` on the return value when done.
pub fn serializeText(
    alloc: std.mem.Allocator,
    font: *z2d.font.Font,
    text: []const u8,
    size: f32,
) SerializeTextError!SerializedText {
    var shaped = try z2d.text.shape(alloc, font, text, 0, 0, .{
        .mode = .all,
        .size = size,
        .glyph_orientation = .baseline,
    });
    defer shaped.deinit(alloc);
    return .{
        .path = try serializePath(alloc, shaped.path()),
        .font_extents = font.extents(size),
        .text_extents = shaped.extents(),
    };
}

pub const SerializeTextToZonError = SerializeTextError || std.Io.Writer.Error;

/// Like `serializeText`, but writes .zon data to the specified writer.
pub fn serializeTextToZon(
    alloc: std.mem.Allocator,
    font: *z2d.font.Font,
    text: []const u8,
    size: f32,
    writer: *std.Io.Writer,
) SerializeTextToZonError!void {
    var serialized: SerializedText = try serializeText(alloc, font, text, size);
    defer serialized.deinit(alloc);
    try std.zon.fmt(serialized, .{}).format(writer);
}

/// Describes a serialization object with path data and dimensions.
///
/// Note that it is actually a correct case for `width` and `height` to be
/// zero. This is a possibility in the case of a single move_to -> close_path
/// pattern, which is a valid path in z2d and can render as a dot with the
/// correct line cap type when stroking. On the other hand, a negative `width`
/// and `height` are incorrect cases and will lead to undefined behavior.
pub const SerializedPath = struct {
    data: []const u8,
    len: u32,
    left: f32,
    top: f32,
    width: f32,
    height: f32,

    /// Releases serialization data and invalidates the representation.
    pub fn deinit(self: *SerializedPath, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const SerializePathError = error{
    /// The path supplied for serialization has no nodes.
    EmptyPath,
} || z2d.Path.SerializeError;

/// Serializes an existing z2d `Path` and returns its serialized
/// representation, including its extents.
///
/// The path is initially walked to generate bounding box extrema for the
/// serialization. Note that this may not be 100% exact to the final path
/// extrema, depending on curves that exist in the path, and whether or not the
/// path is filled or stroked.
///
/// Supplying an empty path to this function is an error. Asserts and assumes
/// that the path is properly formed; using this with incorrectly-formed paths
/// may result in undefined behavior.
///
/// The caller owns the memory created for the serialization, so make sure to
/// call `deinit` on the return value when done.
pub fn serializePath(alloc: std.mem.Allocator, path: *const z2d.Path) SerializePathError!SerializedPath {
    if (path.nodes.items.len == 0) return error.EmptyPath;
    if (path.nodes.items.len > std.math.maxInt(u32)) @panic("path has too many nodes to fit in a u32!!!");

    // Keep track of our extents with some helpers that allow us to cast down
    // from f64 if need be.
    const Extents = struct {
        left: f32,
        right: f32,
        top: f32,
        bottom: f32,

        fn init(x: anytype, y: anytype) @This() {
            return .{
                .left = @floatCast(x),
                .right = @floatCast(x),
                .top = @floatCast(y),
                .bottom = @floatCast(y),
            };
        }

        fn update(self: *@This(), x: anytype, y: anytype) void {
            if (x < self.left) self.left = @floatCast(x);
            if (x > self.right) self.right = @floatCast(x);
            if (y < self.top) self.top = @floatCast(y);
            if (y > self.bottom) self.bottom = @floatCast(y);
        }
    };

    // Valid paths always have at least two (technically three) nodes: move_to
    // -> close_path. The node after this is the move_to to the initial point
    // that is added for correctness, but we don't necessarily need to worry
    // about that for initializing extent values and then looping, as in that
    // case, it will be equal to our initial point below and be a no-op.
    const initial_point = path.nodes.items[0].move_to.point;
    var extents: Extents = .init(initial_point.x, initial_point.y);

    // Determine extent values
    for (path.nodes.items[1..]) |node| {
        switch (node) {
            inline .move_to, .line_to => |n| extents.update(n.point.x, n.point.y),
            .curve_to => |n| {
                extents.update(n.p1.x, n.p1.y);
                extents.update(n.p2.x, n.p2.y);
                extents.update(n.p3.x, n.p3.y);
            },
            .close_path => {},
        }
    }

    return .{
        .data = try path.serialize(alloc, false),
        .len = @intCast(path.nodes.items.len),
        .left = extents.left,
        .top = extents.top,
        .width = extents.right - extents.left,
        .height = extents.bottom - extents.top,
    };
}

pub const SerializePathToZonError = SerializePathError || std.Io.Writer.Error;

/// Like `serializePath`, but writes .zon data to the specified writer.
pub fn serializePathToZon(
    alloc: std.mem.Allocator,
    path: *const z2d.Path,
    writer: *std.Io.Writer,
) SerializePathToZonError!void {
    var serialized: SerializedPath = try serializePath(alloc, path);
    defer serialized.deinit(alloc);
    try std.zon.fmt(serialized, .{}).format(writer);
}

test "SerializedText e2e" {
    const alloc = std.testing.allocator;
    const text = "The quick brown fox jumps over the lazy dog";
    const size: f32 = 96.0 / 72.0 * 16.0; // 16pt @ 96 DPI
    var font: z2d.font.Font = try .loadBufferOffset(@embedFile("cmd/fonts/DejaVuSans.ttf"), 0);
    var shaped = try z2d.text.shape(alloc, &font, text, 0, 0, .{
        .mode = .all,
        .size = size,
        .glyph_orientation = .baseline,
    });
    defer shaped.deinit(alloc);

    var serialized = try serializeText(alloc, &font, text, size);
    defer serialized.deinit(alloc);

    const expected_path_serialized = try shaped.path().serialize(alloc, false);
    defer alloc.free(expected_path_serialized);
    const expected_path: SerializedPath = .{
        .data = expected_path_serialized,
        .len = @intCast(shaped.path().nodes.items.len),
        .left = @floatCast(shaped.extents().x_bearing),
        .top = @floatCast(shaped.extents().y_bearing),
        .width = @floatCast(shaped.extents().width),
        .height = @floatCast(shaped.extents().height),
    };
    const expected: SerializedText = .{
        .path = expected_path,
        .font_extents = font.extents(size),
        .text_extents = shaped.extents(),
    };

    try std.testing.expectEqualDeep(expected, serialized);

    var expected_text_zon_writer: std.Io.Writer.Allocating = .init(alloc);
    defer expected_text_zon_writer.deinit();
    try std.zon.fmt(expected, .{}).format(&expected_text_zon_writer.writer);

    var got_text_zon_writer: std.Io.Writer.Allocating = .init(alloc);
    defer got_text_zon_writer.deinit();
    try serializeTextToZon(alloc, &font, text, size, &got_text_zon_writer.writer);

    var expected_path_zon_writer: std.Io.Writer.Allocating = .init(alloc);
    defer expected_path_zon_writer.deinit();
    try std.zon.fmt(expected_path, .{}).format(&expected_path_zon_writer.writer);

    var got_path_zon_writer: std.Io.Writer.Allocating = .init(alloc);
    defer got_path_zon_writer.deinit();
    try serializePathToZon(alloc, shaped.path(), &got_path_zon_writer.writer);

    try std.testing.expectEqualSlices(u8, expected_text_zon_writer.written(), got_text_zon_writer.written());
    try std.testing.expectEqualSlices(u8, expected_path_zon_writer.written(), got_path_zon_writer.written());
}
