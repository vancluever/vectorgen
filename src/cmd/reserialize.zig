const std = @import("std");
const vectorgen = @import("vectorgen");
const z2d = @import("z2d");

const Options = struct {
    in_file: ?[]const u8 = null,
    out_file: ?[]const u8 = null,
};

// Populated at startup
var err_writer: ?*std.Io.Writer = null;
var err_alloc: ?std.mem.Allocator = null;

// Our default font (DejaVu Sans)
const default_font_data = @embedFile("fonts/DejaVuSans.ttf");

fn help(w: *std.Io.Writer) !void {
    try w.print(
        \\reserialize - Convert existing serializations to .z2d.zon files
        \\
        \\usage: reserialize [OPTION]... [TEXT]
        \\
        \\  -help         Show this help
        \\  -in  FILE     Read from file instead of stdin
        \\  -out FILE     Output to file instead of stdout
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
        if (std.mem.eql(u8, arg, "-help")) {
            help(&stdout_writer.interface) catch return 1;
            return 0;
        } else if (std.mem.eql(u8, arg, "-in")) {
            options.in_file = args_it.next() orelse return err("an input file is needed when using -in");
        } else if (std.mem.eql(u8, arg, "-out")) {
            options.out_file = args_it.next() orelse return err("an output file is needed when using -out");
        } else {
            return fmtErr("unknown option: {s}", .{arg});
        }
    }

    // Determine where we're reading from.
    const in_file: ?std.Io.File = if (options.in_file) |in_filename|
        std.Io.Dir.cwd().openFile(init.io, in_filename, .{}) catch |open_err|
            return fmtErr("cannot open file {s} for reading: {t}", .{ in_filename, open_err })
    else
        null;
    defer if (in_file) |f| f.close(init.io);
    var in_file_reader_buf: [1024]u8 = undefined;
    var in_reader = if (in_file) |f|
        f.reader(init.io, &in_file_reader_buf)
    else
        std.Io.File.stdin().reader(init.io, &stdout_writer_buf);

    // Open output file if we have it. Otherwise we use stdout later
    const out_file: ?std.Io.File = if (options.out_file) |out_filename|
        std.Io.Dir.cwd().createFile(init.io, out_filename, .{}) catch |open_err|
            return fmtErr("cannot open file {s} for writing: {t}", .{ out_filename, open_err })
    else
        null;
    defer if (out_file) |f| f.close(init.io);
    var out_file_writer_buf: [1024]u8 = undefined;
    var out_writer = if (out_file) |f| f.writer(init.io, &out_file_writer_buf) else null;

    // Read our path in from input. Limit size to 1MB for now. TODO: we can
    // drop this if/when we have the serialization functions take a reader.
    const path_serialized: []const u8 = in_reader.interface.readAllocShort(init.gpa, 1048576) catch |read_err|
        return fmtErr("error reading input: {t}", .{read_err});
    defer init.gpa.free(path_serialized);
    var path = z2d.Path.loadSerialized(init.gpa, path_serialized) catch |load_serialize_error|
        return fmtErr("error loading serialization: {t}", .{load_serialize_error});
    defer path.deinit(init.gpa);

    // Finally ready to serialize the path to the file.
    runSerialize(
        init.gpa,
        &path,
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
    path: *z2d.Path,
    writer: *std.Io.Writer,
) !void {
    try vectorgen.serializePathToZon(alloc, path, writer);
    try writer.flush();
}

fn writeSuccess(writer: *std.Io.Writer, out_filename: []const u8) !void {
    try writer.print("OK - write to {s} successful.\n", .{out_filename});
    try writer.flush();
}
