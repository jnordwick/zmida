const std = @import("std");

pub fn main(minimal: std.process.Init.Minimal) void {
    var iterator = minimal.args.iterate();

    // Skip the first argument (the program's executable name/path)
    //    _ = iterator.skip();

    // Loop through the remaining provided arguments
    while (iterator.next()) |arg| {
        std.debug.print("Passed argument: {s}\n", .{arg});
    }
}
