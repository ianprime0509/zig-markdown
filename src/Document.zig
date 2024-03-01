//! An abstract tree representation of a Markdown document.

const std = @import("std");
const Allocator = std.mem.Allocator;

nodes: Node.List.Slice,
extra: []u32,
string_bytes: []u8,

const Document = @This();

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) {
        root = 0,
        _,
    };
    pub const List = std.MultiArrayList(Node);

    pub const Tag = enum {
        /// Data is `container`.
        root,

        // Blocks
        /// Data is `list`.
        list,
        /// Data is `container`.
        list_item,
        /// Data is `heading`.
        heading,
        /// Data is `code_block`.
        code_block,
        /// Data is `container`.
        blockquote,
        /// Data is `container`.
        paragraph,
        /// Data is `none`.
        thematic_break,

        // Inlines
        /// Data is `link`.
        link,
        /// Data is `link`.
        image,
        /// Data is `container`.
        strong,
        /// Data is `container`.
        emphasis,
        /// Data is `text`.
        code_span,
        /// Data is `text`.
        text,
        /// Data is `none`.
        line_break,
    };

    pub const Data = union {
        none: void,
        container: struct {
            children: ExtraIndex(Children),
        },
        text: struct {
            content: StringIndex,
        },
        list: struct {
            info: packed struct {
                tight: bool,
                ordered: bool,
                /// Between 0 and 999,999,999, inclusive.
                start: u30,
            },
            children: ExtraIndex(Children),
        },
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
            children: ExtraIndex(Children),
        },
        code_block: struct {
            tag: StringIndex,
            content: StringIndex,
        },
        link: struct {
            target: StringIndex,
            children: ExtraIndex(Children),
        },
    };

    /// Trailing: `len` times `Node.Index`
    pub const Children = struct {
        len: u32,
    };
};

pub fn ExtraIndex(comptime T: type) type {
    return enum(u32) {
        _,

        pub const Payload = T;
    };
}

/// The index of a null-terminated string in `string_bytes`.
pub const StringIndex = enum(u32) {
    empty = 0,
    _,
};

pub fn deinit(doc: *Document, allocator: Allocator) void {
    doc.nodes.deinit(allocator);
    allocator.free(doc.extra);
    allocator.free(doc.string_bytes);
    doc.* = undefined;
}

pub fn render(doc: Document, writer: anytype) @TypeOf(writer).Error!void {
    try doc.renderNode(.root, writer, false);
}

fn renderNode(doc: Document, node: Node.Index, writer: anytype, tight_paragraphs: bool) !void {
    const data = doc.nodes.items(.data)[@intFromEnum(node)];
    switch (doc.nodes.items(.tag)[@intFromEnum(node)]) {
        .root => {
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNode(child, writer, false);
            }
        },
        .list => {
            if (data.list.info.ordered) {
                if (data.list.info.start == 1) {
                    try writer.writeAll("<ol>\n");
                } else {
                    try writer.print("<ol start=\"{}\">\n", .{data.list.info.start});
                }
            } else {
                try writer.writeAll("<ul>\n");
            }
            for (doc.extraChildren(data.list.children)) |child| {
                try doc.renderNode(child, writer, data.list.info.tight);
            }
            if (data.list.info.ordered) {
                try writer.writeAll("</ol>\n");
            } else {
                try writer.writeAll("</ul>\n");
            }
        },
        .list_item => {
            try writer.writeAll("<li>");
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNode(child, writer, tight_paragraphs);
            }
            try writer.writeAll("</li>\n");
        },
        .heading => {
            try writer.print("<h{}>", .{data.heading.level});
            for (doc.extraChildren(data.heading.children)) |child| {
                try doc.renderNode(child, writer, false);
            }
            try writer.print("</h{}>\n", .{data.heading.level});
        },
        .code_block => {
            const tag = doc.string(data.code_block.tag);
            const content = doc.string(data.code_block.content);
            if (tag.len > 0) {
                try writer.print("<pre><code class=\"{q}\">{}</code></pre>\n", .{ fmtHtml(tag), fmtHtml(content) });
            } else {
                try writer.print("<pre><code>{}</code></pre>\n", .{fmtHtml(content)});
            }
        },
        .blockquote => {
            try writer.writeAll("<blockquote>\n");
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNode(child, writer, tight_paragraphs);
            }
            try writer.writeAll("</blockquote>\n");
        },
        .paragraph => {
            if (!tight_paragraphs) {
                try writer.writeAll("<p>");
            }
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNode(child, writer, false);
            }
            if (!tight_paragraphs) {
                try writer.writeAll("</p>\n");
            }
        },
        .thematic_break => {
            try writer.writeAll("<hr />\n");
        },
        .link => {
            const target = doc.string(data.link.target);
            try writer.print("<a href=\"{q}\">", .{fmtHtml(target)});
            for (doc.extraChildren(data.link.children)) |child| {
                try doc.renderNode(child, writer, undefined);
            }
            try writer.writeAll("</a>");
        },
        .image => {
            const target = doc.string(data.link.target);
            try writer.print("<img src=\"{q}\" alt=\"", .{fmtHtml(target)});
            for (doc.extraChildren(data.link.children)) |child| {
                try doc.renderNodeText(child, writer);
            }
            try writer.writeAll("\" />");
        },
        .strong => {
            try writer.writeAll("<strong>");
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNode(child, writer, undefined);
            }
            try writer.writeAll("</strong>");
        },
        .emphasis => {
            try writer.writeAll("<em>");
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNode(child, writer, undefined);
            }
            try writer.writeAll("</em>");
        },
        .code_span => {
            const content = doc.string(data.text.content);
            try writer.print("<code>{}</code>", .{fmtHtml(content)});
        },
        .text => {
            const content = doc.string(data.text.content);
            try writer.print("{}", .{fmtHtml(content)});
        },
        .line_break => {
            try writer.writeAll("<br />\n");
        },
    }
}

fn renderNodeText(doc: Document, node: Node.Index, writer: anytype) !void {
    const data = doc.nodes.items(.data)[@intFromEnum(node)];
    switch (doc.nodes.items(.tag)[@intFromEnum(node)]) {
        .root,
        .list,
        .list_item,
        .heading,
        .code_block,
        .blockquote,
        .paragraph,
        .thematic_break,
        => unreachable, // Blocks

        .link, .image => {
            for (doc.extraChildren(data.link.children)) |child| {
                try doc.renderNodeText(child, writer);
            }
        },
        .strong => {
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNodeText(child, writer);
            }
        },
        .emphasis => {
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderNodeText(child, writer);
            }
        },
        .code_span, .text => {
            const content = doc.string(data.text.content);
            try writer.print("{q}", .{fmtHtml(content)});
        },
        .line_break => {
            try writer.writeAll("\n");
        },
    }
}

fn fmtHtml(bytes: []const u8) std.fmt.Formatter(formatHtml) {
    return .{ .data = bytes };
}

fn formatHtml(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    const escape_quote = std.mem.eql(u8, fmt, "q");
    for (bytes) |b| {
        switch (b) {
            '<' => try writer.writeAll("&lt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => if (escape_quote) {
                try writer.writeAll("&quot;");
            } else {
                try writer.writeByte('"');
            },
            else => try writer.writeByte(b),
        }
    }
}

pub fn ExtraData(comptime T: type) type {
    return struct { data: T, end: usize };
}

pub fn extraData(d: Document, index: anytype) ExtraData(@TypeOf(index).Payload) {
    const Payload = @TypeOf(index).Payload;
    const fields = @typeInfo(Payload).Struct.fields;
    var i: usize = @intFromEnum(index);
    var result: Payload = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => d.extra[i],
            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{ .data = result, .end = i };
}

pub fn extraChildren(d: Document, index: ExtraIndex(Node.Children)) []const Node.Index {
    const children = d.extraData(index);
    return @ptrCast(d.extra[children.end..][0..children.data.len]);
}

pub fn string(d: Document, index: StringIndex) [:0]const u8 {
    const start = @intFromEnum(index);
    return std.mem.span(@as([*:0]u8, @ptrCast(d.string_bytes[start..].ptr)));
}
