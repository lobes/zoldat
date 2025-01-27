const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const TextView = vaxis.widgets.TextView;
const border = vaxis.widgets.border;
const Size = vaxis.Window.Size;

const log = std.log.scoped(.main);

// Internal events and Vaxis events can be posted into the same queue
// to allow for a single event loop with exhaustive switching
const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    foo: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();

        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    // There are a lot of writes in the render loop
    // so a buffered writer gives better performance #why?
    var buffered_writer = tty.bufferedWriter();
    const writer = buffered_writer.writer().any();

    var vx = try vaxis.init(alloc, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(alloc, tty.anyWriter());

    //
    var loop: vaxis.Loop(Event) = .{
        .vaxis = &vx,
        .tty = &tty,
    };
    try loop.init();

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try loop.start();
    defer loop.stop();

    // Optionally enter the alternate screen #why?
    try vx.enterAltScreen(writer);

    // We change colour index every keypress for the border
    var color_idx: u8 = 0;

    var player_input = TextInput.init(alloc, &vx.unicode);
    defer player_input.deinit();

    try vx.setMouseMode(writer, true);

    try buffered_writer.flush();
    // Sends queries to terminal to detect certain features. This should
    // _always_ be called, but is left to the application to decide when
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    // Game loop. Vaxis provides a thread safe, blocking, buffered
    // queue which can serve as the primary event queue for an application
    while (true) {
        // nextEvent blocks until an event is in the queue
        const event = loop.nextEvent();

        //log.debug("event: {}", .{event}); // **uncomment to see events

        // exhaustive switching ftw. Vaxis will send events if your Event
        // enum has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                // rgb border
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
                if (key.matches('c', .{ .ctrl = true })) {
                    // ctrl+c to exit
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    // ctrl+l to refresh queue #wotitdo?
                    vx.queueRefresh();
                } else if (key.matches('n', .{ .ctrl = true })) {
                    // #wotitdo?
                    try vx.notify(tty.anyWriter(), "vaxis", "hello from vaxis");

                    // pause event loop, spawn and wait for child process, resume event loop
                    loop.stop();
                    var child = std.process.Child.init(&.{"hx"}, alloc);
                    _ = try child.spawnAndWait();
                    try loop.start();

                    try vx.enterAltScreen(tty.anyWriter());
                    vx.queueRefresh();
                } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                    // enter or ctrl+j to clear the text input
                    player_input.clearAndFree();
                } else {
                    // update the text input
                    try player_input.update(.{ .key_press = key });
                }
            },

            // winsize events are sent to the application to ensure that all
            // resizes occur in the main thread. This lets us avoid expensive
            // locks on the screen. All applications must handle this event
            // unless they aren't using a screen (IE only detecting features)
            //
            // This is the only call that the core of Vaxis needs an allocator
            // for. The allocations are because we keep a copy of each cell to
            // optimize renders. When resize is called, we allocated two slices:
            // one for the screen, and one for our buffered screen. Each cell in
            // the buffered screen contains an ArrayList(u8) to be able to store
            // the grapheme for that cell Each cell is initialized with a size
            // of 1, which is sufficient for all of ASCII. Anything requiring
            // more than one byte will incur an allocation on the first render
            // after it is drawn. Thereafter, it will not allocate unless the
            // screen is resized
            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            else => {},
        }

        // vx.window() returns the root window. This window is the size of the
        // terminal and can spawn child windows as logical areas. Child windows
        // cannot draw outside of their bounds
        const win = vx.window();

        // set the window title
        try vx.setTitle(tty.anyWriter(), "zoldat");

        // Clear the entire space because we are drawing in immediate mode.
        // vaxis double buffers the screen. This new frame will be compared to
        // the old and only updated cells will be drawn
        win.clear();

        // draw the text_input using a bordered window
        const Style: vaxis.Style = .{
            .fg = .{ .index = color_idx },
            .blink = true,
        };
        const x_offset: usize = @intCast((@divFloor(win.width, 2)) -| 20);
        const y_offset: usize = @intCast((@divFloor(win.height, 2)) -| 3);
        const child = win.child(.{
            .x_off = x_offset,
            .y_off = y_offset,
            .width = Size{ .limit = 40 },
            .height = Size{ .limit = 3 },
            .border = .{
                .where = .all,
                .style = Style,
            },
        });

        const label = "Enter name:";
        const label_segment: Cell.Segment = .{
            .text = label,
            .style = Style,
        };
        _ = try child.printSegment(label_segment, .{ .row_offset = 1, .col_offset = 1 });
        const input_x = label.len + 2;
        player_input.draw(child.child(.{
            .x_off = input_x,
            .y_off = 1,
            .width = Size{ .limit = 40 - input_x },
            .height = Size{ .limit = 1 },
        }));

        // Render the screen
        try vx.render(writer);
        try buffered_writer.flush();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
