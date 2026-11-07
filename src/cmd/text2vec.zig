// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2026 Chris Marchesi
const std = @import("std");
const vectorgen = @import("vectorgen");
const z2d = @import("z2d");

const Options = struct {
    text: ?[]const u8 = null,
    font_file: ?[]const u8 = null,
    font_index: ?u32 = null,
    out_file: ?[]const u8 = null,
    size: f32 = 16.0, // 12pt @96 DPI
};

// Populated at startup
var err_writer: ?*std.Io.Writer = null;
var err_alloc: ?std.mem.Allocator = null;

// Our default font (DejaVu Sans)
const default_font_data = @embedFile("fonts/DejaVuSans.ttf");

fn help(w: *std.Io.Writer) !void {
    try w.print(
        \\text2vec - Write text string as .z2d.zon file
        \\
        \\usage: text2vec [OPTION]... [TEXT]
        \\
        \\  -font FILE    Use font in FILE (.ttf, .otf, or .ttc file)
        \\  -help         Show this help
        \\  -index INDEX  Font index (for .ttc files)
        \\  -out FILE     Output to file instead of stdout
        \\  -size SIZE    Set size in pixels or points (default: 16px/12pt)
        \\                (Point sizes are calculated @96 DPI)
        \\
    ,
        .{},
    );
    try w.flush();
}

fn fmtErr(comptime fmt: []const u8, args: anytype) u8 {
    const alloc = err_alloc orelse @panic("missing error allocator");
    return err(alloc.print(fmt, args) catch return 1);
}

fn err(message: []const u8) u8 {
    const writer = err_writer orelse @panic("missing error writer");
    writer.print("Error: {s}\n", .{message}) catch return 1;
    writer.flush() catch return 1;
    help(writer) catch return 1;
    return 1;
}

pub fn main(init: std.process.Init) u8 {
    var stdout_writer_buf: [1024]u8 = undefined;
    var stderr_writer_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_writer_buf);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_writer_buf);
    var options: Options = .{};

    var args_it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    err_writer = &stderr_writer.interface;
    err_alloc = init.arena.allocator();

    _ = args_it.skip();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-font")) {
            options.font_file = args_it.next() orelse return err("a font file is required when using -font");
        } else if (std.mem.eql(u8, arg, "-help")) {
            help(&stdout_writer.interface) catch return 1;
            return 0;
        } else if (std.mem.eql(u8, arg, "-index")) {
            const idx_raw = args_it.next() orelse return err("an index is required when using -index");

            options.font_index = std.fmt.parseInt(u32, idx_raw, 10) catch return fmtErr("invalid index: {s}", .{idx_raw});
        } else if (std.mem.eql(u8, arg, "-out")) {
            options.out_file = args_it.next() orelse return err("an output file is needed when using -out");
        } else if (std.mem.eql(u8, arg, "-size")) size: {
            const size_arg = args_it.next() orelse return err("a size is expected when using -size");

            const raw_size_str, const is_pts = raw: {
                if (std.mem.endsWith(u8, size_arg, "pt")) {
                    break :raw .{ size_arg[0 .. size_arg.len - 2], true };
                } else if (std.mem.endsWith(u8, size_arg, "px")) {
                    break :raw .{ size_arg[0 .. size_arg.len - 2], false };
                } else {
                    break :raw .{ size_arg, false };
                }
            };

            invalid: {
                const raw_size_num = std.fmt.parseFloat(f32, raw_size_str) catch break :invalid;
                // Note that technically we could likely have a smaller size
                // than 1, but we're just setting this limit for sanity's sake,
                // and it looks good in code.
                if (raw_size_num < 1.0) break :invalid;
                options.size = if (is_pts) 96.0 / 72.0 * raw_size_num else raw_size_num;
                break :size;
            }

            return fmtErr("invalid size: {s}", .{size_arg});
        } else if (std.mem.eql(u8, arg, "--")) {
            if (args_it.next()) |text_arg| {
                if (options.text != null) return err("expected only one text string");
                options.text = text_arg;
            }

            break;
        } else {
            if (std.mem.startsWith(u8, arg, "-")) return fmtErr("unknown option: {s}", .{arg});
            if (options.text != null) return err("expected only one text string");
            options.text = arg;
        }
    }

    // Validate that we only have an index if we had a file supplied.
    if (options.font_index != null and options.font_file == null)
        return err("font index cannot be defined when no font is defined");

    // Load text
    const text = options.text orelse return err("text is required");

    // Open output file if we have it. Otherwise we use stdout later
    const out_file: ?std.Io.File = if (options.out_file) |out_filename|
        std.Io.Dir.cwd().createFile(init.io, out_filename, .{}) catch |open_err|
            return fmtErr("cannot open file {s} for writing: {t}", .{ out_filename, open_err })
    else
        null;
    defer if (out_file) |f| f.close(init.io);
    var out_file_writer_buf: [1024]u8 = undefined;
    var out_writer = if (out_file) |f| f.writer(init.io, &out_file_writer_buf) else null;

    // Load our font file if we have it
    var font_file: ?z2d.font.File = if (options.font_file) |font_filename|
        z2d.font.File.loadFile(init.io, init.gpa, font_filename) catch |load_err|
            return fmtErr("cannot open font file {s}: {t}", .{ font_filename, load_err })
    else
        null;
    defer if (font_file) |*f| f.deinit(init.gpa);

    // Load font by index or the default buffer
    var font = if (font_file) |f|
        f.loadFontIndex(options.font_index orelse 0) catch |load_index_err|
            return fmtErr("cannot load the font at index {d}: {t}", .{ options.font_index orelse 0, load_index_err })
    else
        z2d.font.Font.loadBufferOffset(default_font_data, 0) catch
            @panic("corrupt default font, this is a bug, please report it");

    // Finally ready to serialize the path to the file.
    runSerialize(
        init.gpa,
        &font,
        text,
        options.size,
        if (out_writer) |*w| &w.interface else &stdout_writer.interface,
    ) catch |serialization_error|
        return fmtErr("error performing serialization: {t}", .{serialization_error});

    // Done. If we've rendered to a file, just write a message that we were
    // successful.
    if (options.out_file) |out_filename|
        writeSuccess(&stdout_writer.interface, out_filename) catch
            @panic("serialization was successful, but writing confirmation message failed!");

    return 0;
}

fn runSerialize(
    alloc: std.mem.Allocator,
    font: *z2d.font.Font,
    text: []const u8,
    size: f32,
    writer: *std.Io.Writer,
) !void {
    try vectorgen.serializeTextToZon(alloc, font, text, size, writer);
    try writer.flush();
}

fn writeSuccess(writer: *std.Io.Writer, out_filename: []const u8) !void {
    try writer.print("OK - write to {s} successful.\n", .{out_filename});
    try writer.flush();
}
