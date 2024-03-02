const std = @import("std");
const testing = std.testing;
const Document = @import("Document.zig");
const Parser = @import("Parser.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input =
        \\- - Item 1.
        \\  - Item 2.
        \\Item 2 continued.
        \\  * New list.
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

test "empty document" {
    try testRender("", "");
    try testRender("   ", "");
    try testRender("\n \n\t\n   \n", "");
}

test "unordered lists" {
    try testRender(
        \\- Spam
        \\- Spam
        \\- Spam
        \\- Eggs
        \\- Bacon
        \\- Spam
        \\
    ,
        \\<ul>
        \\<li>Spam</li>
        \\<li>Spam</li>
        \\<li>Spam</li>
        \\<li>Eggs</li>
        \\<li>Bacon</li>
        \\<li>Spam</li>
        \\</ul>
        \\
    );
    try testRender(
        \\* Spam
        \\* Spam
        \\* Spam
        \\* Eggs
        \\* Bacon
        \\* Spam
        \\
    ,
        \\<ul>
        \\<li>Spam</li>
        \\<li>Spam</li>
        \\<li>Spam</li>
        \\<li>Eggs</li>
        \\<li>Bacon</li>
        \\<li>Spam</li>
        \\</ul>
        \\
    );
}

test "ordered lists" {
    try testRender(
        \\1. Breakfast
        \\2. Second breakfast
        \\3. Lunch
        \\2. Afternoon snack
        \\1. Dinner
        \\6. Dessert
        \\7. Midnight snack
        \\
    ,
        \\<ol>
        \\<li>Breakfast</li>
        \\<li>Second breakfast</li>
        \\<li>Lunch</li>
        \\<li>Afternoon snack</li>
        \\<li>Dinner</li>
        \\<li>Dessert</li>
        \\<li>Midnight snack</li>
        \\</ol>
        \\
    );
    try testRender(
        \\1001. Breakfast
        \\2. Second breakfast
        \\3. Lunch
        \\2. Afternoon snack
        \\1. Dinner
        \\6. Dessert
        \\7. Midnight snack
        \\
    ,
        \\<ol start="1001">
        \\<li>Breakfast</li>
        \\<li>Second breakfast</li>
        \\<li>Lunch</li>
        \\<li>Afternoon snack</li>
        \\<li>Dinner</li>
        \\<li>Dessert</li>
        \\<li>Midnight snack</li>
        \\</ol>
        \\
    );
}

test "nested lists" {
    try testRender(
        \\- - Item 1.
        \\  - Item 2.
        \\Item 2 continued.
        \\  * New list.
        \\
    ,
        \\<ul>
        \\<li><ul>
        \\<li>Item 1.</li>
        \\<li>Item 2.
        \\Item 2 continued.</li>
        \\</ul>
        \\<ul>
        \\<li>New list.</li>
        \\</ul>
        \\</li>
        \\</ul>
        \\
    );
}

test "lists with block content" {
    try testRender(
        \\1. Item 1.
        \\2. Item 2.
        \\
        \\   This one has another paragraph.
        \\3. Item 3.
        \\
        \\- > Blockquote.
        \\- - Sub-list.
        \\  - Sub-list continued.
        \\  * Different sub-list.
        \\- ## Heading.
        \\
        \\  Some contents below the heading.
        \\  1. Item 1.
        \\  2. Item 2.
        \\  3. Item 3.
        \\
    ,
        \\<ol>
        \\<li><p>Item 1.</p>
        \\</li>
        \\<li><p>Item 2.</p>
        \\<p>This one has another paragraph.</p>
        \\</li>
        \\<li><p>Item 3.</p>
        \\</li>
        \\</ol>
        \\<ul>
        \\<li><blockquote>
        \\<p>Blockquote.</p>
        \\</blockquote>
        \\</li>
        \\<li><ul>
        \\<li>Sub-list.</li>
        \\<li>Sub-list continued.</li>
        \\</ul>
        \\<ul>
        \\<li>Different sub-list.</li>
        \\</ul>
        \\</li>
        \\<li><h2>Heading.</h2>
        \\<p>Some contents below the heading.</p>
        \\<ol>
        \\<li>Item 1.</li>
        \\<li>Item 2.</li>
        \\<li>Item 3.</li>
        \\</ol>
        \\</li>
        \\</ul>
        \\
    );
}

test "headings" {
    try testRender(
        \\# Level one
        \\## Level two
        \\### Level three
        \\#### Level four
        \\##### Level five
        \\###### Level six
        \\####### Not a heading
        \\
    ,
        \\<h1>Level one</h1>
        \\<h2>Level two</h2>
        \\<h3>Level three</h3>
        \\<h4>Level four</h4>
        \\<h5>Level five</h5>
        \\<h6>Level six</h6>
        \\<p>####### Not a heading</p>
        \\
    );
}

test "headings with inline content" {
    try testRender(
        \\# Outline of `std.zig`
        \\## **Important** notes
        \\### ***Nested* inline content**
        \\
    ,
        \\<h1>Outline of <code>std.zig</code></h1>
        \\<h2><strong>Important</strong> notes</h2>
        \\<h3><strong><em>Nested</em> inline content</strong></h3>
        \\
    );
}

test "code blocks" {
    try testRender(
        \\```
        \\Hello, world!
        \\This is some code.
        \\```
        \\``` zig test
        \\const std = @import("std");
        \\
        \\test {
        \\    try std.testing.expect(2 + 2 == 4);
        \\}
        \\```
        \\
    ,
        \\<pre><code>Hello, world!
        \\This is some code.
        \\</code></pre>
        \\<pre><code class="zig test">const std = @import("std");
        \\
        \\test {
        \\    try std.testing.expect(2 + 2 == 4);
        \\}
        \\</code></pre>
        \\
    );
}

test "blockquotes" {
    try testRender(
        \\> > You miss 100% of the shots you don't take.
        \\> >
        \\> > ~ Wayne Gretzky
        \\>
        \\> ~ Michael Scott
        \\
    ,
        \\<blockquote>
        \\<blockquote>
        \\<p>You miss 100% of the shots you don't take.</p>
        \\<p>~ Wayne Gretzky</p>
        \\</blockquote>
        \\<p>~ Michael Scott</p>
        \\</blockquote>
        \\
    );
}

test "blockquote lazy continuation lines" {
    try testRender(
        \\>>>>Deeply nested blockquote
        \\>>which continues on another line
        \\and then yet another one.
        \\>>
        \\>> But now two of them have been closed.
        \\
        \\And then there were none.
        \\
    ,
        \\<blockquote>
        \\<blockquote>
        \\<blockquote>
        \\<blockquote>
        \\<p>Deeply nested blockquote
        \\which continues on another line
        \\and then yet another one.</p>
        \\</blockquote>
        \\</blockquote>
        \\<p>But now two of them have been closed.</p>
        \\</blockquote>
        \\</blockquote>
        \\<p>And then there were none.</p>
        \\
    );
}

test "paragraphs" {
    try testRender(
        \\Paragraph one.
        \\
        \\Paragraph two.
        \\Still in the paragraph.
        \\    So is this.
        \\
        \\
        \\
        \\
        \\ Last paragraph.
        \\
    ,
        \\<p>Paragraph one.</p>
        \\<p>Paragraph two.
        \\Still in the paragraph.
        \\So is this.</p>
        \\<p>Last paragraph.</p>
        \\
    );
}

test "thematic breaks" {
    try testRender(
        \\---
        \\***
        \\___
        \\          ---
        \\ - - - - - - - - - - -
        \\
    ,
        \\<hr />
        \\<hr />
        \\<hr />
        \\<hr />
        \\<hr />
        \\
    );
}

test "links" {
    try testRender(
        \\[Link](https://example.com)
        \\[Link *with inlines*](https://example.com)
        \\[Nested parens](https://example.com/nested(parens(inside)))
        \\[Escaped parens](https://example.com/\)escaped\()
        \\
    ,
        \\<p><a href="https://example.com">Link</a>
        \\<a href="https://example.com">Link <em>with inlines</em></a>
        \\<a href="https://example.com/nested(parens(inside))">Nested parens</a>
        \\<a href="https://example.com/)escaped(">Escaped parens</a></p>
        \\
    );
}

test "images" {
    try testRender(
        \\![Alt text](https://example.com/image.png)
        \\![Alt text *with inlines*](https://example.com/image.png)
        \\![Nested parens](https://example.com/nested(parens(inside)).png)
        \\![Escaped parens](https://example.com/\)escaped\(.png)
        \\
    ,
        \\<p><img src="https://example.com/image.png" alt="Alt text" />
        \\<img src="https://example.com/image.png" alt="Alt text with inlines" />
        \\<img src="https://example.com/nested(parens(inside)).png" alt="Nested parens" />
        \\<img src="https://example.com/)escaped(.png" alt="Escaped parens" /></p>
        \\
    );
}

test "emphasis" {
    try testRender(
        \\*Emphasis.*
        \\**Strong.**
        \\***Strong emphasis.***
        \\****More...****
        \\*****MORE...*****
        \\******Even more...******
        \\*******OK, this is enough.*******
        \\
    ,
        \\<p><em>Emphasis.</em>
        \\<strong>Strong.</strong>
        \\<em><strong>Strong emphasis.</strong></em>
        \\<em><strong><em>More...</em></strong></em>
        \\<em><strong><strong>MORE...</strong></strong></em>
        \\<em><strong><em><strong>Even more...</strong></em></strong></em>
        \\<em><strong><em><strong><em>OK, this is enough.</em></strong></em></strong></em></p>
        \\
    );
    try testRender(
        \\_Emphasis._
        \\__Strong.__
        \\___Strong emphasis.___
        \\____More...____
        \\_____MORE..._____
        \\______Even more...______
        \\_______OK, this is enough._______
        \\
    ,
        \\<p><em>Emphasis.</em>
        \\<strong>Strong.</strong>
        \\<em><strong>Strong emphasis.</strong></em>
        \\<em><strong><em>More...</em></strong></em>
        \\<em><strong><strong>MORE...</strong></strong></em>
        \\<em><strong><em><strong>Even more...</strong></em></strong></em>
        \\<em><strong><em><strong><em>OK, this is enough.</em></strong></em></strong></em></p>
        \\
    );
}

test "nested emphasis" {
    try testRender(
        \\**Hello, *world!***
        \\*Hello, **world!***
        \\**Hello, _world!_**
        \\_Hello, **world!**_
        \\*Hello, **nested** *world!**
        \\***Hello,* world!**
        \\__**Hello, world!**__
        \\****Hello,** world!**
        \\__Hello,_ world!_
        \\*Test**123*
        \\__Test____123__
        \\
    ,
        \\<p><strong>Hello, <em>world!</em></strong>
        \\<em>Hello, <strong>world!</strong></em>
        \\<strong>Hello, <em>world!</em></strong>
        \\<em>Hello, <strong>world!</strong></em>
        \\<em>Hello, <strong>nested</strong> <em>world!</em></em>
        \\<strong><em>Hello,</em> world!</strong>
        \\<strong><strong>Hello, world!</strong></strong>
        \\<strong><strong>Hello,</strong> world!</strong>
        \\<em><em>Hello,</em> world!</em>
        \\<em>Test</em><em>123</em>
        \\<strong>Test____123</strong></p>
        \\
    );
}

test "emphasis precedence" {
    try testRender(
        \\*First one _wins*_.
        \\_*No other __rule matters.*_
        \\
    ,
        \\<p><em>First one _wins</em>_.
        \\<em><em>No other __rule matters.</em></em></p>
        \\
    );
}

test "emphasis open and close" {
    try testRender(
        \\Cannot open: *
        \\Cannot open: _
        \\*Cannot close: *
        \\_Cannot close: _
        \\
        \\foo*bar*baz
        \\foo_bar_baz
        \\foo**bar**baz
        \\foo__bar__baz
        \\
    ,
        \\<p>Cannot open: *
        \\Cannot open: _
        \\*Cannot close: *
        \\_Cannot close: _</p>
        \\<p>foo<em>bar</em>baz
        \\foo_bar_baz
        \\foo<strong>bar</strong>baz
        \\foo__bar__baz</p>
        \\
    );
}

test "code spans" {
    try testRender(
        \\`Hello, world!`
        \\```Multiple `backticks` can be used.```
        \\`**This** does not produce emphasis.`
        \\`` `Backtick enclosed string.` ``
        \\`Delimiter lengths ```must``` match.`
        \\
        \\Unterminated ``code...
        \\
        \\Weird empty code span: `
        \\
        \\**Very important code: `hi`**
        \\
    ,
        \\<p><code>Hello, world!</code>
        \\<code>Multiple `backticks` can be used.</code>
        \\<code>**This** does not produce emphasis.</code>
        \\<code>`Backtick enclosed string.`</code>
        \\<code>Delimiter lengths ```must``` match.</code></p>
        \\<p>Unterminated <code>code...</code></p>
        \\<p>Weird empty code span: <code></code></p>
        \\<p><strong>Very important code: <code>hi</code></strong></p>
        \\
    );
}

test "backslash escapes" {
    try testRender(
        \\Not \*emphasized\*.
        \\Literal \\backslashes\\.
        \\Not code: \`hi\`.
        \\\# Not a title.
        \\#\# Also not a title.
        \\\> Not a blockquote.
        \\\- Not a list item.
        \\Any \punctuation\ characte\r can be escaped:
        \\\!\"\#\$\%\&\'\(\)\*\+\,\-\.\/\:\;\<\=\>\?\@\[\\\]\^\_\`\{\|\}\~
        \\
    ,
        \\<p>Not *emphasized*.
        \\Literal \backslashes\.
        \\Not code: `hi`.
        \\# Not a title.
        \\## Also not a title.
        \\> Not a blockquote.
        \\- Not a list item.
        \\Any \punctuation\ characte\r can be escaped:
        \\!"#$%&amp;'()*+,-./:;&lt;=>?@[\]^_`{|}~</p>
        \\
    );
}

test "hard line breaks" {
    try testRender(
        \\The iguana sits\
        \\Perched atop a short desk chair\
        \\Writing code in Zig
        \\
    ,
        \\<p>The iguana sits<br />
        \\Perched atop a short desk chair<br />
        \\Writing code in Zig</p>
        \\
    );
}

test "Unicode handling" {
    // Null bytes must be replaced.
    try testRender("\x00\x00\x00", "<p>\u{FFFD}\u{FFFD}\u{FFFD}</p>\n");

    // Invalid UTF-8 must be replaced.
    try testRender("\xC0\x80\xE0\x80\x80\xF0\x80\x80\x80", "<p>\u{FFFD}\u{FFFD}\u{FFFD}</p>\n");
    try testRender("\xED\xA0\x80\xED\xBF\xBF", "<p>\u{FFFD}\u{FFFD}</p>\n");

    // Incomplete UTF-8 must be replaced.
    try testRender("\xE2\x82", "<p>\u{FFFD}</p>\n");
}

fn testRender(input: []const u8, expected: []const u8) !void {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    var lines = std.mem.split(u8, input, "\n");
    while (lines.next()) |line| {
        try parser.feedLine(line);
    }
    var doc = try parser.endInput();
    defer doc.deinit(testing.allocator);

    var actual = std.ArrayList(u8).init(testing.allocator);
    defer actual.deinit();
    try doc.render(actual.writer());

    try testing.expectEqualStrings(expected, actual.items);
}
