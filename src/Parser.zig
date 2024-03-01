//! A Markdown parser producing `Document`s.
//!
//! The parser operates at two levels: at the outer level, the parser accepts
//! the content of an input document line by line and begins building the _block
//! structure_ of the document. This creates a stack of currently open blocks.
//!
//! When the parser detects the end of a block, it closes the block, popping it
//! from the open block stack and completing any additional parsing of the
//! block's content. For blocks which contain parseable inline content, this
//! invokes the inner level of the parser, handling the _inline structure_ of
//! the block.
//!
//! Inline parsing scans through the collected inline content of a block. When
//! it encounters a character that could indicate the beginning of an inline, it
//! either handles the inline right away (if possible) or adds it to a pending
//! inlines stack. When an inline is completed, it is added to a list of
//! completed inlines, which (along with any surrounding text nodes) will become
//! the children of the parent inline or the block whose inline content is being
//! parsed.

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

/// A block element which is still receiving children.
const Block = struct {
    tag: Tag,
    data: Data,
    extra_start: usize,
    string_start: usize,

    const Tag = enum {
        /// Data is `list`.
        list,
        /// Data is `list_item`.
        list_item,
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
        list: struct {
            tight: bool,
            marker: ListMarker,
            /// Between 0 and 999,999,999, inclusive.
            start: u30,
        },
        list_item: struct {
            indent: usize,
        },
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
        },
        code_block: struct {
            tag: StringIndex,
            fence_len: usize,
            indent: usize,
        },

        const ListMarker = enum { @"-", @"*", number };
    };

    const ContentType = enum {
        blocks,
        inlines,
        raw_inlines,
        nothing,
    };

    fn canAccept(b: Block) ContentType {
        return switch (b.tag) {
            .list,
            .list_item,
            .blockquote,
            => .blocks,

            .heading,
            .paragraph,
            => .inlines,

            .code_block,
            => .raw_inlines,

            .thematic_break,
            => .nothing,
        };
    }

    /// Attempts to continue `b` using the contents of `line`. If successful,
    /// returns the remaining portion of `line` to be considered part of `b`
    /// (e.g. for a blockquote, this would be everything except the leading
    /// `>`). If unsuccessful, returns null.
    fn match(b: Block, line: []const u8) ?[]const u8 {
        const unindented = mem.trimLeft(u8, line, " \t");
        const indent = line.len - unindented.len;
        return switch (b.tag) {
            .list => line,
            .list_item => if (indent > b.data.list_item.indent)
                line[b.data.list_item.indent..]
            else
                null,
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
            .blockquote => if (mem.startsWith(u8, unindented, ">"))
                unindented[1..]
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

/// Accepts a single line of content. `line` should not have a trailing line
/// ending character.
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
        !isBlank(rest_line) and
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
        try p.appendBlockStart(block_start);
        // There may be more blocks to start within the same line.
        rest_line = block_start.rest;
        // Headings may only contain inline content.
        if (block_start.tag == .heading) break;
        // An opening code fence does not contain any additional block or inline
        // content to process.
        if (block_start.tag == .code_block) return;
    }

    // Do not append the end of a code block (```) as textual content.
    if (code_block_end) return;

    const can_accept = if (p.pending_blocks.getLastOrNull()) |last_pending_block|
        last_pending_block.canAccept()
    else
        .blocks;
    const rest_line_trimmed = mem.trimLeft(u8, rest_line, " \t");
    switch (can_accept) {
        .blocks => {
            if (!isBlank(rest_line)) {
                try p.appendBlockStart(.{
                    .tag = .paragraph,
                    .data = .{ .none = {} },
                    .rest = undefined,
                });
                try p.addScratchStringLine(rest_line_trimmed);
            }
        },
        .inlines => try p.addScratchStringLine(rest_line_trimmed),
        .raw_inlines => try p.addScratchStringLine(rest_line),
        .nothing => {},
    }
}

/// Completes processing of the input and returns the parsed document.
pub fn endInput(p: *Parser) Allocator.Error!Document {
    while (p.pending_blocks.items.len > 0) {
        try p.closeLastBlock();
    }
    // There should be no inline content pending after closing the last open
    // block.
    assert(p.scratch_string.items.len == 0);

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

/// Data describing the start of a new block element.
const BlockStart = struct {
    tag: Tag,
    data: Data,
    rest: []const u8,

    const Tag = enum {
        /// Data is `list_item`.
        list_item,
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
        list_item: struct {
            marker: Block.Data.ListMarker,
            number: u30,
            indent: usize,
        },
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
        },
        code_block: struct {
            tag: StringIndex,
            fence_len: usize,
            indent: usize,
        },
    };
};

fn appendBlockStart(p: *Parser, block_start: BlockStart) !void {
    // Close the last block if it is a list and the new block is not a list item
    // or not of the same marker type.
    if (p.pending_blocks.getLastOrNull()) |last_pending_block| {
        if (last_pending_block.tag == .list and
            (block_start.tag != .list_item or
            block_start.data.list_item.marker != last_pending_block.data.list.marker))
        {
            try p.closeLastBlock();
        }
    }

    // Start a new list if the new block is a list item and there is no
    // containing list yet.
    if (block_start.tag == .list_item and
        (p.pending_blocks.items.len == 0 or p.pending_blocks.getLast().tag != .list))
    {
        try p.pending_blocks.append(p.allocator, .{
            .tag = .list,
            .data = .{ .list = .{
                .tight = true,
                .marker = block_start.data.list_item.marker,
                .start = block_start.data.list_item.number,
            } },
            .string_start = p.scratch_string.items.len,
            .extra_start = p.scratch_extra.items.len,
        });
    }

    const tag: Block.Tag, const data: Block.Data = switch (block_start.tag) {
        .list_item => .{ .list_item, .{ .list_item = .{
            .indent = block_start.data.list_item.indent,
        } } },
        .heading => .{ .heading, .{ .heading = .{
            .level = block_start.data.heading.level,
        } } },
        .code_block => .{ .code_block, .{ .code_block = .{
            .tag = block_start.data.code_block.tag,
            .fence_len = block_start.data.code_block.fence_len,
            .indent = block_start.data.code_block.indent,
        } } },
        .blockquote => .{ .blockquote, .{ .none = {} } },
        .paragraph => .{ .paragraph, .{ .none = {} } },
        .thematic_break => .{ .thematic_break, .{ .none = {} } },
    };

    try p.pending_blocks.append(p.allocator, .{
        .tag = tag,
        .data = data,
        .string_start = p.scratch_string.items.len,
        .extra_start = p.scratch_extra.items.len,
    });
}

fn startBlock(p: *Parser, line: []const u8) !?BlockStart {
    const unindented = mem.trimLeft(u8, line, " \t");
    const indent = line.len - unindented.len;
    if (isThematicBreak(line)) {
        // Thematic breaks take precedence over list items.
        return .{
            .tag = .thematic_break,
            .data = .{ .none = {} },
            .rest = "",
        };
    } else if (startListItem(unindented)) |list_item| {
        return .{
            .tag = .list_item,
            .data = .{ .list_item = .{
                .marker = list_item.marker,
                .number = list_item.number,
                .indent = indent,
            } },
            .rest = list_item.rest,
        };
    } else if (startHeading(unindented)) |heading| {
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
                .fence_len = code_block.fence_len,
                .indent = indent,
            } },
            .rest = "",
        };
    } else if (startBlockquote(unindented)) |rest| {
        return .{
            .tag = .blockquote,
            .data = .{ .none = {} },
            .rest = rest,
        };
    } else {
        return null;
    }
}

const ListItemStart = struct {
    marker: Block.Data.ListMarker,
    number: u30,
    rest: []const u8,
};

fn startListItem(unindented_line: []const u8) ?ListItemStart {
    if (mem.startsWith(u8, unindented_line, "- ")) {
        return .{
            .marker = .@"-",
            .number = undefined,
            .rest = unindented_line[2..],
        };
    } else if (mem.startsWith(u8, unindented_line, "* ")) {
        return .{
            .marker = .@"*",
            .number = undefined,
            .rest = unindented_line[2..],
        };
    }

    const number_end = mem.indexOfNone(u8, unindented_line, "0123456789") orelse return null;
    const after_number = unindented_line[number_end..];
    if (!mem.startsWith(u8, after_number, ". ")) {
        return null;
    }
    const number = std.fmt.parseInt(u30, unindented_line[0..number_end], 10) catch return null;
    if (number > 999_999_999) return null;
    return .{
        .marker = .number,
        .number = number,
        .rest = after_number[2..],
    };
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
            ' ' => {
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
    // Code block tags may not contain backticks, since that would create
    // potential confusion with inline code spans.
    if (fence_len < 3 or mem.indexOfScalar(u8, tag_bytes, '`') != null) return null;
    return .{
        .tag = try p.addString(mem.trim(u8, tag_bytes, " ")),
        .fence_len = fence_len,
    };
}

fn startBlockquote(unindented_line: []const u8) ?[]const u8 {
    return if (mem.startsWith(u8, unindented_line, ">"))
        unindented_line[1..]
    else
        null;
}

fn isThematicBreak(line: []const u8) bool {
    var char: ?u8 = null;
    var count: usize = 0;
    for (line) |c| {
        switch (c) {
            ' ' => {},
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
        .list => list: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :list try p.addNode(.{
                .tag = .list,
                .data = .{ .list = .{
                    .info = .{
                        .tight = b.data.list.tight,
                        .ordered = b.data.list.marker == .number,
                        .start = b.data.list.start,
                    },
                    .children = children,
                } },
            });
        },
        .list_item => list_item: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :list_item try p.addNode(.{
                .tag = .list_item,
                .data = .{ .container = .{
                    .children = children,
                } },
            });
        },
        .heading => heading: {
            const children = try p.parseInlines(p.scratch_string.items[b.string_start..]);
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
            const children = try p.parseInlines(p.scratch_string.items[b.string_start..]);
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
    try p.addScratchExtraNode(node);
}

const InlineParser = struct {
    parent: *Parser,
    content: []const u8,
    pos: usize = 0,
    pending_inlines: std.ArrayListUnmanaged(PendingInline) = .{},
    completed_inlines: std.ArrayListUnmanaged(CompletedInline) = .{},

    const PendingInline = struct {
        tag: Tag,
        data: Data,
        start: usize,

        const Tag = enum {
            /// Data is `emphasis`.
            emphasis,
            /// Data is `none`.
            link,
            /// Data is `none`.
            image,
        };

        const Data = union {
            none: void,
            emphasis: struct {
                underscore: bool,
                run_len: usize,
            },
        };
    };

    const CompletedInline = struct {
        node: Node.Index,
        start: usize,
        len: usize,
    };

    fn deinit(ip: *InlineParser) void {
        ip.pending_inlines.deinit(ip.parent.allocator);
        ip.completed_inlines.deinit(ip.parent.allocator);
    }

    /// Parses all of `ip.content`, returning the children of the node
    /// containing the inline content.
    fn parse(ip: *InlineParser) Allocator.Error!ExtraIndex(Node.Children) {
        while (ip.pos < ip.content.len) : (ip.pos += 1) {
            switch (ip.content[ip.pos]) {
                '\\' => ip.pos += 1,
                '[' => try ip.pending_inlines.append(ip.parent.allocator, .{
                    .tag = .link,
                    .data = .{ .none = {} },
                    .start = ip.pos,
                }),
                '!' => if (ip.pos + 1 < ip.content.len and ip.content[ip.pos + 1] == '[') {
                    try ip.pending_inlines.append(ip.parent.allocator, .{
                        .tag = .image,
                        .data = .{ .none = {} },
                        .start = ip.pos,
                    });
                    ip.pos += 1;
                },
                ']' => try ip.parseLink(),
                '*', '_' => try ip.parseEmphasis(),
                '`' => try ip.parseCodeSpan(),
                else => {},
            }
        }

        const children = try ip.encodeChildren(0, ip.content.len);
        // There may be pending inlines after parsing (e.g. unclosed emphasis
        // runs), but there must not be any completed inlines, since those
        // should all be part of `children`.
        assert(ip.completed_inlines.items.len == 0);
        return children;
    }

    /// Parses a link, starting at the `]` at the end of the link text. `ip.pos`
    /// is left at the closing `)` of the link target or at the closing `]` if
    /// there is none.
    fn parseLink(ip: *InlineParser) !void {
        var i = ip.pending_inlines.items.len;
        while (i > 0) {
            i -= 1;
            if (ip.pending_inlines.items[i].tag == .link or
                ip.pending_inlines.items[i].tag == .image) break;
        } else return;
        const opener = ip.pending_inlines.items[i];
        ip.pending_inlines.shrinkRetainingCapacity(i);
        const text_start = switch (opener.tag) {
            .link => opener.start + 1,
            .image => opener.start + 2,
            else => unreachable,
        };

        if (ip.pos + 1 >= ip.content.len or ip.content[ip.pos + 1] != '(') return;
        const text_end = ip.pos;

        const target_start = text_end + 2;
        var target_end = target_start;
        var nesting_level: usize = 1;
        while (target_end < ip.content.len) : (target_end += 1) {
            switch (ip.content[target_end]) {
                '\\' => target_end += 1,
                '(' => nesting_level += 1,
                ')' => {
                    if (nesting_level == 1) break;
                    nesting_level -= 1;
                },
                else => {},
            }
        } else return;
        ip.pos = target_end;

        const children = try ip.encodeChildren(text_start, text_end);
        const target = try ip.encodeLinkTarget(target_start, target_end);

        const link = try ip.parent.addNode(.{
            .tag = switch (opener.tag) {
                .link => .link,
                .image => .image,
                else => unreachable,
            },
            .data = .{ .link = .{
                .target = target,
                .children = children,
            } },
        });
        try ip.completed_inlines.append(ip.parent.allocator, .{
            .node = link,
            .start = opener.start,
            .len = ip.pos - opener.start + 1,
        });
    }

    fn encodeLinkTarget(ip: *InlineParser, start: usize, end: usize) !StringIndex {
        // For efficiency, we can encode directly into string_bytes rather than
        // creating a temporary string and then encoding it, since this process
        // is entirely linear.
        const string_top = ip.parent.string_bytes.items.len;
        errdefer ip.parent.string_bytes.shrinkRetainingCapacity(string_top);

        var text_iter: TextIterator = .{ .content = ip.content[start..end] };
        while (text_iter.next()) |content| {
            switch (content) {
                .char => |c| try ip.parent.string_bytes.append(ip.parent.allocator, c),
                .text => |s| try ip.parent.string_bytes.appendSlice(ip.parent.allocator, s),
                .line_break => try ip.parent.string_bytes.append(ip.parent.allocator, '\n'),
            }
        }
        try ip.parent.string_bytes.append(ip.parent.allocator, 0);
        return @enumFromInt(string_top);
    }

    /// Parses emphasis, starting at the beginning of a run of `*` or `_`
    /// characters. `ip.pos` is left at the last character in the run after
    /// parsing.
    fn parseEmphasis(ip: *InlineParser) !void {
        const char = ip.content[ip.pos];
        var start = ip.pos;
        while (ip.pos + 1 < ip.content.len and ip.content[ip.pos + 1] == char) {
            ip.pos += 1;
        }
        var len = ip.pos - start + 1;
        const can_open = start + len < ip.content.len and
            !std.ascii.isWhitespace(ip.content[start + len]);
        const can_close = start > 0 and
            !std.ascii.isWhitespace(ip.content[start - 1]);
        const underscore = char == '_';

        if (can_close and ip.pending_inlines.items.len > 0) {
            var i = ip.pending_inlines.items.len;
            while (i > 0 and len > 0) {
                i -= 1;
                const opener = &ip.pending_inlines.items[i];
                if (opener.tag != .emphasis or
                    opener.data.emphasis.underscore != underscore) continue;

                const close_len = @min(opener.data.emphasis.run_len, len);
                const opener_end = opener.start + opener.data.emphasis.run_len;

                const emphasis = try ip.encodeEmphasis(opener_end, start, close_len);
                const emphasis_start = opener_end - close_len;
                const emphasis_len = start - emphasis_start + close_len;
                try ip.completed_inlines.append(ip.parent.allocator, .{
                    .node = emphasis,
                    .start = emphasis_start,
                    .len = emphasis_len,
                });

                // There may still be other openers further down in the
                // stack to close, or part of this run might serve as an
                // opener itself.
                start += close_len;
                len -= close_len;

                // Remove any pending inlines above this on the stack, since
                // closing this emphasis will prevent them from being closed.
                // Additionally, if this opener is completely consumed by
                // being closed, it can be removed.
                opener.data.emphasis.run_len -= close_len;
                if (opener.data.emphasis.run_len == 0) {
                    ip.pending_inlines.shrinkRetainingCapacity(i);
                } else {
                    ip.pending_inlines.shrinkRetainingCapacity(i + 1);
                }
            }
        }

        if (can_open and len > 0) {
            try ip.pending_inlines.append(ip.parent.allocator, .{
                .tag = .emphasis,
                .data = .{ .emphasis = .{
                    .underscore = underscore,
                    .run_len = len,
                } },
                .start = start,
            });
        }
    }

    /// Encodes emphasis specified by a run of `run_len` emphasis characters,
    /// with `start..end` being the range of content contained within the
    /// emphasis.
    fn encodeEmphasis(ip: *InlineParser, start: usize, end: usize, run_len: usize) !Node.Index {
        const children = try ip.encodeChildren(start, end);
        var inner = switch (run_len % 3) {
            1 => try ip.parent.addNode(.{
                .tag = .emphasis,
                .data = .{ .container = .{
                    .children = children,
                } },
            }),
            2 => try ip.parent.addNode(.{
                .tag = .strong,
                .data = .{ .container = .{
                    .children = children,
                } },
            }),
            0 => strong_emphasis: {
                const strong = try ip.parent.addNode(.{
                    .tag = .strong,
                    .data = .{ .container = .{
                        .children = children,
                    } },
                });
                break :strong_emphasis try ip.parent.addNode(.{
                    .tag = .emphasis,
                    .data = .{ .container = .{
                        .children = try ip.parent.addExtraChildren(&.{strong}),
                    } },
                });
            },
            else => unreachable,
        };

        var run_left = run_len;
        while (run_left > 3) : (run_left -= 3) {
            const strong = try ip.parent.addNode(.{
                .tag = .strong,
                .data = .{ .container = .{
                    .children = try ip.parent.addExtraChildren(&.{inner}),
                } },
            });
            inner = try ip.parent.addNode(.{
                .tag = .emphasis,
                .data = .{ .container = .{
                    .children = try ip.parent.addExtraChildren(&.{strong}),
                } },
            });
        }

        return inner;
    }

    /// Parses a code span, starting at the beginning of the opening backtick
    /// run. `ip.pos` is left at the last character in the closing run after
    /// parsing.
    fn parseCodeSpan(ip: *InlineParser) !void {
        const opener_start = ip.pos;
        ip.pos = mem.indexOfNonePos(u8, ip.content, ip.pos, "`") orelse ip.content.len;
        const opener_len = ip.pos - opener_start;

        const start = ip.pos;
        const end = while (mem.indexOfScalarPos(u8, ip.content, ip.pos, '`')) |closer_start| {
            ip.pos = mem.indexOfNonePos(u8, ip.content, closer_start, "`") orelse ip.content.len;
            const closer_len = ip.pos - closer_start;

            if (closer_len == opener_len) break closer_start;
        } else unterminated: {
            ip.pos = ip.content.len;
            break :unterminated ip.content.len;
        };

        var content = if (start < ip.content.len)
            ip.content[start..end]
        else
            "";
        // This single space removal rule allows code spans to be written which
        // start or end with backticks.
        if (mem.startsWith(u8, content, " `")) content = content[1..];
        if (mem.endsWith(u8, content, "` ")) content = content[0 .. content.len - 1];

        const text = try ip.parent.addNode(.{
            .tag = .code_span,
            .data = .{ .text = .{
                .content = try ip.parent.addString(content),
            } },
        });
        try ip.completed_inlines.append(ip.parent.allocator, .{
            .node = text,
            .start = opener_start,
            .len = ip.pos - opener_start,
        });
        // Ensure ip.pos is pointing at the last character of the
        // closer, not after it.
        ip.pos -= 1;
    }

    /// Encodes children parsed in the content range `start..end`. The children
    /// will be text nodes and any completed inlines within the range.
    fn encodeChildren(ip: *InlineParser, start: usize, end: usize) !ExtraIndex(Node.Children) {
        const scratch_extra_top = ip.parent.scratch_extra.items.len;
        defer ip.parent.scratch_extra.shrinkRetainingCapacity(scratch_extra_top);

        var child_index = ip.completed_inlines.items.len;
        while (child_index > 0 and ip.completed_inlines.items[child_index - 1].start >= start) {
            child_index -= 1;
        }
        const start_child_index = child_index;

        var pos = start;
        while (child_index < ip.completed_inlines.items.len) : (child_index += 1) {
            const child_inline = ip.completed_inlines.items[child_index];
            // Completed inlines must be strictly nested within the encodable
            // content.
            assert(child_inline.start >= pos and child_inline.start + child_inline.len <= end);

            if (child_inline.start > pos) {
                try ip.encodeTextNode(pos, child_inline.start);
            }
            try ip.parent.addScratchExtraNode(child_inline.node);

            pos = child_inline.start + child_inline.len;
        }
        ip.completed_inlines.shrinkRetainingCapacity(start_child_index);

        if (pos < end) {
            try ip.encodeTextNode(pos, end);
        }

        const children = ip.parent.scratch_extra.items[scratch_extra_top..];
        return try ip.parent.addExtraChildren(@ptrCast(children));
    }

    /// Encodes textual content `ip.content[start..end]` to `scratch_extra`. The
    /// encoded content may include both `text` and `line_break` nodes.
    fn encodeTextNode(ip: *InlineParser, start: usize, end: usize) !void {
        // For efficiency, we can encode directly into string_bytes rather than
        // creating a temporary string and then encoding it, since this process
        // is entirely linear.
        const string_top = ip.parent.string_bytes.items.len;
        errdefer ip.parent.string_bytes.shrinkRetainingCapacity(string_top);

        var string_start = string_top;
        var text_iter: TextIterator = .{ .content = ip.content[start..end] };
        while (text_iter.next()) |content| {
            switch (content) {
                .char => |c| try ip.parent.string_bytes.append(ip.parent.allocator, c),
                .text => |s| try ip.parent.string_bytes.appendSlice(ip.parent.allocator, s),
                .line_break => {
                    if (ip.parent.string_bytes.items.len > string_start) {
                        try ip.parent.string_bytes.append(ip.parent.allocator, 0);
                        try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                            .tag = .text,
                            .data = .{ .text = .{
                                .content = @enumFromInt(string_start),
                            } },
                        }));
                        string_start = ip.parent.string_bytes.items.len;
                    }
                    try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                        .tag = .line_break,
                        .data = .{ .none = {} },
                    }));
                },
            }
        }
        if (ip.parent.string_bytes.items.len > string_start) {
            try ip.parent.string_bytes.append(ip.parent.allocator, 0);
            try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                .tag = .text,
                .data = .{ .text = .{
                    .content = @enumFromInt(string_start),
                } },
            }));
        }
    }

    /// An iterator over parts of textual content, handling unescaping of
    /// escaped characters and line breaks.
    const TextIterator = struct {
        content: []const u8,
        pos: usize = 0,

        const Content = union(enum) {
            char: u8,
            text: []const u8,
            line_break,
        };

        const replacement = "\u{FFFD}";

        fn next(iter: *TextIterator) ?Content {
            if (iter.pos >= iter.content.len) return null;
            if (iter.content[iter.pos] == '\\') {
                iter.pos += 1;
                return switch (iter.nextCodepoint() orelse return null) {
                    .char => |c| if (c == '\n') .line_break else .{ .char = c },
                    else => |content| content,
                };
            }
            return iter.nextCodepoint();
        }

        fn nextCodepoint(iter: *TextIterator) ?Content {
            if (iter.pos >= iter.content.len) return null;
            switch (iter.content[iter.pos]) {
                0 => {
                    iter.pos += 1;
                    return .{ .text = replacement };
                },
                1...127 => |c| {
                    iter.pos += 1;
                    return .{ .char = c };
                },
                else => |b| {
                    const cp_len = std.unicode.utf8ByteSequenceLength(b) catch {
                        iter.pos += 1;
                        return .{ .text = replacement };
                    };
                    const is_valid = iter.pos + cp_len < iter.content.len and
                        std.unicode.utf8ValidateSlice(iter.content[iter.pos..][0..cp_len]);
                    const cp_encoded = if (is_valid)
                        iter.content[iter.pos..][0..cp_len]
                    else
                        replacement;
                    iter.pos += cp_len;
                    return .{ .text = cp_encoded };
                },
            }
        }
    };
};

fn parseInlines(p: *Parser, content: []const u8) !ExtraIndex(Node.Children) {
    var ip: InlineParser = .{
        .parent = p,
        .content = mem.trimRight(u8, content, " \t\n"),
    };
    defer ip.deinit();
    return try ip.parse();
}

fn addNode(p: *Parser, node: Node) !Node.Index {
    const index: Node.Index = @enumFromInt(@as(u32, @intCast(p.nodes.len)));
    try p.nodes.append(p.allocator, node);
    return index;
}

fn addString(p: *Parser, s: []const u8) !StringIndex {
    if (s.len == 0) return .empty;

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

fn addScratchExtraNode(p: *Parser, node: Node.Index) !void {
    try p.scratch_extra.append(p.allocator, @intFromEnum(node));
}

fn addScratchStringLine(p: *Parser, line: []const u8) !void {
    try p.scratch_string.ensureUnusedCapacity(p.allocator, line.len + 1);
    p.scratch_string.appendSliceAssumeCapacity(line);
    p.scratch_string.appendAssumeCapacity('\n');
}

fn isBlank(line: []const u8) bool {
    return mem.indexOfNone(u8, line, " \t") == null;
}
