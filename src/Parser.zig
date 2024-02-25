const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const Document = @import("Document.zig");
const Node = Document.Node;
const ExtraIndex = Document.ExtraIndex;
const StringIndex = Document.StringIndex;

nodes: Node.List = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
scratch_extra: std.ArrayListUnmanaged(u32) = .{},
string_bytes: std.ArrayListUnmanaged(u8) = .{},
scratch_string: std.ArrayListUnmanaged(u8) = .{},
pending_blocks: std.ArrayListUnmanaged(Block) = .{},
allocator: Allocator,

const Parser = @This();

const Block = struct {
    tag: Tag,
    data: Data,
    extra_start: usize,
    string_start: usize,

    const Tag = enum {
        /// Data is `heading`.
        heading,
        /// Data is `code_block`.
        code_block,
        /// Data is `none`.
        blockquote,
        /// Data is `none`.
        paragraph,
        /// Data is `none`.
        thematic_break,
    };

    const Data = union {
        none: void,
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
        },
        code_block: struct {
            tag: StringIndex,
            indent: usize,
            fence_len: usize,
        },
    };

    const ContentType = enum {
        blocks,
        inlines,
        nothing,
    };

    fn canAccept(b: Block) ContentType {
        return switch (b.tag) {
            .heading => .inlines,
            .code_block => .inlines,
            .blockquote => .blocks,
            .paragraph => .inlines,
            .thematic_break => .nothing,
        };
    }

    fn match(b: Block, line: []const u8) ?[]const u8 {
        const unindented = mem.trimLeft(u8, line, " \t");
        const indent = line.len - unindented.len;
        return switch (b.tag) {
            .heading => null,
            .code_block => code_block: {
                const trimmed = mem.trimRight(u8, unindented, " \t");
                if (mem.indexOfNone(u8, trimmed, "`") != null or trimmed.len != b.data.code_block.fence_len) {
                    const effective_indent = @min(indent, b.data.code_block.indent);
                    break :code_block line[effective_indent..];
                } else {
                    break :code_block null;
                }
            },
            .blockquote => if (mem.startsWith(u8, unindented, "> ") or mem.startsWith(u8, unindented, ">\t"))
                unindented[2..]
            else
                null,
            .paragraph => if (unindented.len > 0) unindented else null,
            .thematic_break => null,
        };
    }
};

pub fn init(allocator: Allocator) Allocator.Error!Parser {
    var p: Parser = .{ .allocator = allocator };
    try p.nodes.append(allocator, .{
        .tag = .root,
        .data = undefined,
    });
    try p.string_bytes.append(allocator, 0);
    return p;
}

pub fn deinit(p: *Parser) void {
    p.nodes.deinit(p.allocator);
    p.extra.deinit(p.allocator);
    p.scratch_extra.deinit(p.allocator);
    p.string_bytes.deinit(p.allocator);
    p.scratch_string.deinit(p.allocator);
    p.pending_blocks.deinit(p.allocator);
    p.* = undefined;
}

pub fn feedLine(p: *Parser, line: []const u8) Allocator.Error!void {
    var rest_line = line;
    const first_unmatched = for (p.pending_blocks.items, 0..) |b, i| {
        if (b.match(rest_line)) |rest| {
            rest_line = rest;
        } else {
            break i;
        }
    } else p.pending_blocks.items.len;

    const in_code_block = p.pending_blocks.items.len > 0 and
        p.pending_blocks.getLast().tag == .code_block;
    const code_block_end = in_code_block and
        first_unmatched + 1 == p.pending_blocks.items.len;
    // New blocks cannot be started if we are actively inside a code block or
    // are just closing one (to avoid interpreting the closing ``` as a new code
    // block start).
    var maybe_block_start = if (!in_code_block or first_unmatched + 2 <= p.pending_blocks.items.len)
        try p.startBlock(rest_line)
    else
        null;

    // This is a lazy continuation line if there are no new blocks to open and
    // the last open block is a paragraph.
    if (maybe_block_start == null and
        mem.indexOfNone(u8, rest_line, " \t") != null and
        p.pending_blocks.items.len > 0 and
        p.pending_blocks.getLast().tag == .paragraph)
    {
        try p.addScratchStringLine(rest_line);
        return;
    }

    // If a new block needs to be started, any paragraph needs to be closed,
    // even though this isn't detected as part of the closing condition for
    // paragraphs.
    if (maybe_block_start != null and
        p.pending_blocks.items.len > 0 and
        p.pending_blocks.getLast().tag == .paragraph)
    {
        try p.closeLastBlock();
    }

    while (p.pending_blocks.items.len > first_unmatched) {
        try p.closeLastBlock();
    }

    while (maybe_block_start) |block_start| : (maybe_block_start = try p.startBlock(rest_line)) {
        try p.pending_blocks.append(p.allocator, .{
            .tag = block_start.tag,
            .data = block_start.data,
            .string_start = p.scratch_string.items.len,
            .extra_start = p.scratch_extra.items.len,
        });
        // There may be more blocks to start within the same line.
        rest_line = block_start.rest;
        // Headings may only contain inline content.
        if (block_start.tag == .heading) break;
    }

    rest_line = mem.trimLeft(u8, rest_line, " \t");

    // Do not append the end of a code block (```) as textual content.
    if (code_block_end) return;

    const can_accept = if (p.pending_blocks.getLastOrNull()) |last_pending_block|
        last_pending_block.canAccept()
    else
        .blocks;
    switch (can_accept) {
        .blocks => {
            if (rest_line.len > 0) {
                try p.pending_blocks.append(p.allocator, .{
                    .tag = .paragraph,
                    .data = .{ .none = {} },
                    .string_start = p.scratch_string.items.len,
                    .extra_start = p.scratch_extra.items.len,
                });
                try p.addScratchStringLine(rest_line);
            }
        },
        .inlines => {
            try p.addScratchStringLine(rest_line);
        },
        .nothing => {},
    }
}

pub fn endInput(p: *Parser) Allocator.Error!Document {
    while (p.pending_blocks.items.len > 0) {
        try p.closeLastBlock();
    }
    try p.parseInlines(p.scratch_string.items);
    const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items));
    p.nodes.items(.data)[0] = .{ .container = .{ .children = children } };
    p.scratch_string.items.len = 0;
    p.scratch_extra.items.len = 0;

    var nodes = p.nodes.toOwnedSlice();
    errdefer nodes.deinit(p.allocator);
    const extra = try p.extra.toOwnedSlice(p.allocator);
    errdefer p.allocator.free(extra);
    const string_bytes = try p.string_bytes.toOwnedSlice(p.allocator);
    errdefer p.allocator.free(string_bytes);

    return .{
        .nodes = nodes,
        .extra = extra,
        .string_bytes = string_bytes,
    };
}

const BlockStart = struct {
    tag: Block.Tag,
    data: Block.Data,
    rest: []const u8,
};

fn startBlock(p: *Parser, line: []const u8) Allocator.Error!?BlockStart {
    const unindented = mem.trimLeft(u8, line, " \t");
    const indent = line.len - unindented.len;
    if (startHeading(unindented)) |heading| {
        return .{
            .tag = .heading,
            .data = .{ .heading = .{
                .level = heading.level,
            } },
            .rest = heading.rest,
        };
    } else if (try p.startCodeBlock(unindented)) |code_block| {
        return .{
            .tag = .code_block,
            .data = .{ .code_block = .{
                .tag = code_block.tag,
                .indent = indent,
                .fence_len = code_block.fence_len,
            } },
            .rest = "",
        };
    } else if (startBlockquote(unindented)) |rest| {
        return .{
            .tag = .blockquote,
            .data = .{ .none = {} },
            .rest = rest,
        };
    } else if (isThematicBreak(line)) {
        return .{
            .tag = .thematic_break,
            .data = .{ .none = {} },
            .rest = "",
        };
    } else {
        return null;
    }
}

const HeadingStart = struct {
    level: u3,
    rest: []const u8,
};

fn startHeading(unindented_line: []const u8) ?HeadingStart {
    var level: u3 = 0;
    return for (unindented_line, 0..) |c, i| {
        switch (c) {
            '#' => {
                if (level == 6) break null;
                level += 1;
            },
            ' ', '\t' => {
                // We must have seen at least one # by this point, since
                // unindented_line has no leading spaces.
                assert(level > 0);
                break .{
                    .level = level,
                    .rest = unindented_line[i + 1 ..],
                };
            },
            else => break null,
        }
    } else null;
}

const CodeBlockStart = struct {
    tag: StringIndex,
    fence_len: usize,
};

fn startCodeBlock(p: *Parser, unindented_line: []const u8) !?CodeBlockStart {
    var fence_len: usize = 0;
    const tag_bytes = for (unindented_line, 0..) |c, i| {
        switch (c) {
            '`' => fence_len += 1,
            else => break unindented_line[i..],
        }
    } else "";
    if (fence_len < 3 or mem.indexOfScalar(u8, tag_bytes, '`') != null) return null;
    return .{
        .tag = try p.addString(mem.trim(u8, tag_bytes, " \t")),
        .fence_len = fence_len,
    };
}

fn startBlockquote(unindented_line: []const u8) ?[]const u8 {
    return if (mem.startsWith(u8, unindented_line, "> ") or mem.startsWith(u8, unindented_line, ">\t"))
        unindented_line[2..]
    else
        null;
}

fn isThematicBreak(line: []const u8) bool {
    var char: ?u8 = null;
    var count: usize = 0;
    for (line) |c| {
        switch (c) {
            ' ', '\t' => {},
            '-', '_', '*' => {
                if (char != null and c != char.?) return false;
                char = c;
                count += 1;
            },
            else => return false,
        }
    }
    return count >= 3;
}

fn closeLastBlock(p: *Parser) !void {
    const b = p.pending_blocks.pop();
    const node = switch (b.tag) {
        .heading => heading: {
            try p.parseInlines(p.scratch_string.items[b.string_start..]);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :heading try p.addNode(.{
                .tag = .heading,
                .data = .{ .heading = .{
                    .level = b.data.heading.level,
                    .children = children,
                } },
            });
        },
        .code_block => code_block: {
            const content = try p.addString(p.scratch_string.items[b.string_start..]);
            break :code_block try p.addNode(.{
                .tag = .code_block,
                .data = .{ .code_block = .{
                    .tag = b.data.code_block.tag,
                    .content = content,
                } },
            });
        },
        .blockquote => blockquote: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :blockquote try p.addNode(.{
                .tag = .blockquote,
                .data = .{ .container = .{
                    .children = children,
                } },
            });
        },
        .paragraph => paragraph: {
            try p.parseInlines(p.scratch_string.items[b.string_start..]);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :paragraph try p.addNode(.{
                .tag = .paragraph,
                .data = .{ .container = .{
                    .children = children,
                } },
            });
        },
        .thematic_break => try p.addNode(.{
            .tag = .thematic_break,
            .data = .{ .none = {} },
        }),
    };
    p.scratch_string.items.len = b.string_start;
    p.scratch_extra.items.len = b.extra_start;
    try p.scratch_extra.append(p.allocator, @intFromEnum(node));
}

fn parseInlines(p: *Parser, content: []const u8) !void {
    const string = try p.addString(mem.trimRight(u8, content, " \t\n"));
    const node = try p.addNode(.{
        .tag = .text,
        .data = .{ .text = .{
            .content = string,
        } },
    });
    try p.scratch_extra.append(p.allocator, @intFromEnum(node));
}

fn addNode(p: *Parser, node: Node) !Node.Index {
    const index: Node.Index = @enumFromInt(@as(u32, @intCast(p.nodes.len)));
    try p.nodes.append(p.allocator, node);
    return index;
}

fn addString(p: *Parser, s: []const u8) !StringIndex {
    const index: StringIndex = @enumFromInt(@as(u32, @intCast(p.string_bytes.items.len)));
    try p.string_bytes.ensureUnusedCapacity(p.allocator, s.len + 1);
    p.string_bytes.appendSliceAssumeCapacity(s);
    p.string_bytes.appendAssumeCapacity(0);
    return index;
}

fn addExtraChildren(p: *Parser, nodes: []const Node.Index) !ExtraIndex(Node.Children) {
    const index: ExtraIndex(Node.Children) = @enumFromInt(@as(u32, @intCast(p.extra.items.len)));
    try p.extra.ensureUnusedCapacity(p.allocator, nodes.len + 1);
    p.extra.appendAssumeCapacity(@intCast(nodes.len));
    p.extra.appendSliceAssumeCapacity(@ptrCast(nodes));
    return index;
}

fn addScratchStringLine(p: *Parser, line: []const u8) !void {
    try p.scratch_string.ensureUnusedCapacity(p.allocator, line.len + 1);
    p.scratch_string.appendSliceAssumeCapacity(line);
    p.scratch_string.appendAssumeCapacity('\n');
}
