const std = @import("std");
const Document = @import("Document.zig");
const Parser = @import("Parser.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input =
        \\Hello, world!
        \\
        \\Another paragraph.
        \\
        \\---
        \\lol
        \\
        \\# Some code
        \\
        \\```zig
        \\std.debug.print("Hello, world!", .{});
        \\
        \\// End
        \\```
        \\
        \\> Quote
        \\> More quote
        \\
    ;

    var parser = try Parser.init(gpa);
    defer parser.deinit();

    var lines = std.mem.split(u8, input, "\n");
    while (lines.next()) |line| {
        try parser.feedLine(line);
    }
    var doc = try parser.endInput();
    defer doc.deinit(gpa);

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    try doc.render(stdout_buf.writer());
    try stdout_buf.flush();
}
