const std = @import("std");
const lightmix_wav = @import("lightmix_wav");
const allocator = std.heap.page_allocator;

pub fn main() !void {
    const data: []const u8 = @embedFile("./assets/sine.wav");
    var stream = std.io.fixedBufferStream(data);

    var wav_decoder = try lightmix_wav.decoder(stream.reader());

    std.debug.print("{d}\n", .{wav_decoder.sampleRate()});
    std.debug.print("{d}\n", .{wav_decoder.channels()});
    std.debug.print("{d}\n", .{wav_decoder.bits()});
    std.debug.print("{d}\n", .{wav_decoder.remaining()});

    var buf: [64]f32 = undefined;
    var arraylist: std.array_list.Aligned(f32, null) = .empty;
    defer arraylist.deinit(allocator);

    while (true) {
        // Read samples as f32. Channels are interleaved.
        const samples_read = try wav_decoder.read(f32, &buf);

        // < ------ Do something with samples in buf. ------ >
        try arraylist.appendSlice(allocator, &buf);

        if (samples_read < buf.len) {
            break;
        }
    }

    std.debug.print("{any}\n", .{arraylist.items});
}
