//! An abstract tree representation of a Markdown document.

const std = @import("std");
const assert = std.debug.assert;
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
        /// Data is `list_item`.
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
            children: ExtraIndex,
        },
        text: struct {
            content: StringIndex,
        },
        list: struct {
            start: ListStart,
            children: ExtraIndex,
        },
        list_item: struct {
            tight: bool,
            children: ExtraIndex,
        },
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
            children: ExtraIndex,
        },
        code_block: struct {
            tag: StringIndex,
            content: StringIndex,
        },
        link: struct {
            target: StringIndex,
            children: ExtraIndex,
        },
    };

    /// The starting number of a list. This is either a number between 0 and
    /// 999,999,999, inclusive, or `unordered` to indicate an unordered list.
    pub const ListStart = enum(u30) {
        // When https://github.com/ziglang/zig/issues/104 is implemented, this
        // type can be more naturally expressed as ?u30. As it is, we want
        // values to fit within 4 bytes, so ?u30 does not yet suffice for
        // storage.
        unordered = std.math.maxInt(u30),
        _,

        pub fn asNumber(start: ListStart) ?u30 {
            if (start == .unordered) return null;
            assert(@intFromEnum(start) <= 999_999_999);
            return @intFromEnum(start);
        }
    };

    /// Trailing: `len` times `Node.Index`
    pub const Children = struct {
        len: u32,
    };
};

pub const ExtraIndex = enum(u32) { _ };

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

pub fn Renderer(comptime Writer: type, comptime Context: type) type {
    return struct {
        renderFn: *const fn (
            r: Self,
            doc: Document,
            node: Node.Index,
            writer: Writer,
        ) Writer.Error!void = renderDefault,
        context: Context,

        const Self = @This();

        pub fn render(r: Self, doc: Document, writer: Writer) Writer.Error!void {
            try r.renderFn(r, doc, .root, writer);
        }

        pub fn renderDefault(
            r: Self,
            doc: Document,
            node: Node.Index,
            writer: Writer,
        ) Writer.Error!void {
            const data = doc.nodes.items(.data)[@intFromEnum(node)];
            switch (doc.nodes.items(.tag)[@intFromEnum(node)]) {
                .root => {
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                },
                .list => {
                    if (data.list.start.asNumber()) |start| {
                        if (start == 1) {
                            try writer.writeAll("<ol>\n");
                        } else {
                            try writer.print("<ol start=\"{}\">\n", .{start});
                        }
                    } else {
                        try writer.writeAll("<ul>\n");
                    }
                    for (doc.extraChildren(data.list.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    if (data.list.start.asNumber() != null) {
                        try writer.writeAll("</ol>\n");
                    } else {
                        try writer.writeAll("</ul>\n");
                    }
                },
                .list_item => {
                    try writer.writeAll("<li>");
                    for (doc.extraChildren(data.list_item.children)) |child| {
                        if (data.list_item.tight and doc.nodes.items(.tag)[@intFromEnum(child)] == .paragraph) {
                            const para_data = doc.nodes.items(.data)[@intFromEnum(child)];
                            for (doc.extraChildren(para_data.container.children)) |para_child| {
                                try r.renderFn(r, doc, para_child, writer);
                            }
                        } else {
                            try r.renderFn(r, doc, child, writer);
                        }
                    }
                    try writer.writeAll("</li>\n");
                },
                .heading => {
                    try writer.print("<h{}>", .{data.heading.level});
                    for (doc.extraChildren(data.heading.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.print("</h{}>\n", .{data.heading.level});
                },
                .code_block => {
                    const tag = doc.string(data.code_block.tag);
                    const content = doc.string(data.code_block.content);
                    if (tag.len > 0) {
                        try writer.print("<pre><code class=\"{}\">{}</code></pre>\n", .{ fmtHtml(tag), fmtHtml(content) });
                    } else {
                        try writer.print("<pre><code>{}</code></pre>\n", .{fmtHtml(content)});
                    }
                },
                .blockquote => {
                    try writer.writeAll("<blockquote>\n");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</blockquote>\n");
                },
                .paragraph => {
                    try writer.writeAll("<p>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</p>\n");
                },
                .thematic_break => {
                    try writer.writeAll("<hr />\n");
                },
                .link => {
                    const target = doc.string(data.link.target);
                    try writer.print("<a href=\"{}\">", .{fmtHtml(target)});
                    for (doc.extraChildren(data.link.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</a>");
                },
                .image => {
                    const target = doc.string(data.link.target);
                    try writer.print("<img src=\"{}\" alt=\"", .{fmtHtml(target)});
                    for (doc.extraChildren(data.link.children)) |child| {
                        try doc.renderInlineNodeText(child, writer);
                    }
                    try writer.writeAll("\" />");
                },
                .strong => {
                    try writer.writeAll("<strong>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</strong>");
                },
                .emphasis => {
                    try writer.writeAll("<em>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
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
    };
}

pub fn render(doc: Document, writer: anytype) @TypeOf(writer).Error!void {
    const renderer: Renderer(@TypeOf(writer), void) = .{ .context = {} };
    try renderer.render(doc, writer);
}

/// Renders an inline node as plain text.
pub fn renderInlineNodeText(
    doc: Document,
    node: Node.Index,
    writer: anytype,
) @TypeOf(writer).Error!void {
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
                try doc.renderInlineNodeText(child, writer);
            }
        },
        .strong => {
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderInlineNodeText(child, writer);
            }
        },
        .emphasis => {
            for (doc.extraChildren(data.container.children)) |child| {
                try doc.renderInlineNodeText(child, writer);
            }
        },
        .code_span, .text => {
            const content = doc.string(data.text.content);
            try writer.print("{}", .{fmtHtml(content)});
        },
        .line_break => {
            try writer.writeAll("\n");
        },
    }
}

pub fn fmtHtml(bytes: []const u8) std.fmt.Formatter(formatHtml) {
    return .{ .data = bytes };
}

fn formatHtml(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    for (bytes) |b| {
        switch (b) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(b),
        }
    }
}

pub fn ExtraData(comptime T: type) type {
    return struct { data: T, end: usize };
}

pub fn extraData(doc: Document, comptime T: type, index: ExtraIndex) ExtraData(T) {
    const fields = @typeInfo(T).Struct.fields;
    var i: usize = @intFromEnum(index);
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => doc.extra[i],
            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{ .data = result, .end = i };
}

pub fn extraChildren(doc: Document, index: ExtraIndex) []const Node.Index {
    const children = doc.extraData(Node.Children, index);
    return @ptrCast(doc.extra[children.end..][0..children.data.len]);
}

pub fn string(doc: Document, index: StringIndex) [:0]const u8 {
    const start = @intFromEnum(index);
    return std.mem.span(@as([*:0]u8, @ptrCast(doc.string_bytes[start..].ptr)));
}
