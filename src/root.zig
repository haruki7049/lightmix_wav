const std = @import("std");
const builtin = @import("builtin");
const sample = @import("sample.zig");

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const bad_type = "sample type must be u8, i16, i24, or f32";

fn readFloat(comptime T: type, reader: anytype) !T {
    var f: T = undefined;
    try reader.readNoEof(std.mem.asBytes(&f));
    return f;
}

const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    alaw = 6,
    mulaw = 7,
    extensible = 0xFFFE,
    _,
};

const FormatChunk = packed struct {
    code: FormatCode,
    channels: u16,
    sample_rate: u32,
    bytes_per_second: u32,
    block_align: u16,
    bits: u16,

    fn parse(reader: anytype, chunk_size: usize) !FormatChunk {
        if (chunk_size < @sizeOf(FormatChunk)) {
            return error.InvalidSize;
        }
        const fmt = try reader.readStruct(FormatChunk);
        if (chunk_size > @sizeOf(FormatChunk)) {
            try reader.skipBytes(chunk_size - @sizeOf(FormatChunk), .{});
        }
        return fmt;
    }

    fn validate(self: FormatChunk) !void {
        switch (self.code) {
            .pcm, .ieee_float, .extensible => {},
            else => {
                std.log.debug("unsupported format code {x}", .{@intFromEnum(self.code)});
                return error.Unsupported;
            },
        }
        if (self.channels == 0) {
            return error.InvalidValue;
        }
        switch (self.bits) {
            0 => return error.InvalidValue,
            8, 16, 24, 32 => {},
            else => {
                std.log.debug("unsupported bits per sample {}", .{self.bits});
                return error.Unsupported;
            },
        }
        const expected_bps: u32 = @intCast((self.bits / 8) * self.sample_rate * self.channels);
        if (self.bytes_per_second != expected_bps) {
            std.log.debug("invalid bytes_per_second", .{});
            return error.InvalidValue;
        }
    }
};

/// Loads wav file from stream. Read and convert samples to a desired type.
pub fn Decoder(comptime InnerReaderType: type) type {
    return struct {
        const Self = @This();

        const ReaderType = std.io.CountingReader(InnerReaderType);
        const Error = ReaderType.Error || error{ EndOfStream, InvalidFileType, InvalidArgument, InvalidSize, InvalidValue, Overflow, Unsupported };

        counting_reader: ReaderType,
        fmt: FormatChunk,
        data_start: usize,
        data_size: usize,

        pub fn sampleRate(self: *const Self) usize {
            return @intCast(self.fmt.sample_rate);
        }

        pub fn channels(self: *const Self) usize {
            return @intCast(self.fmt.channels);
        }

        pub fn bits(self: *const Self) usize {
            return @intCast(self.fmt.bits);
        }

        /// Number of samples remaining.
        pub fn remaining(self: *const Self) usize {
            const sample_size = self.bits() / 8;
            const bytes_remaining = self.data_size + self.data_start - self.counting_reader.bytes_read;

            std.debug.assert(bytes_remaining % sample_size == 0);
            return bytes_remaining / sample_size;
        }

        /// Parse and validate headers/metadata. Prepare to read samples.
        fn init(inner_reader: InnerReaderType) Error!Self {
            comptime std.debug.assert(builtin.target.cpu.arch.endian() == .little);

            const counting_reader = std.io.countingReader(inner_reader);

            var chunk_id = try inner_reader.readBytesNoEof(4);
            if (!std.mem.eql(u8, "RIFF", &chunk_id)) {
                std.log.debug("not a RIFF file", .{});
                return error.InvalidFileType;
            }

            const file_size_le = try inner_reader.readInt(u32, .little);
            // total_size is file size + 8 per RIFF spec
            const total_size: usize = @as(usize, @intCast(file_size_le)) + 8;

            chunk_id = try inner_reader.readBytesNoEof(4);
            if (!std.mem.eql(u8, "WAVE", &chunk_id)) {
                std.log.debug("not a WAVE file", .{});
                return error.InvalidFileType;
            }

            // Iterate through chunks. Require fmt and data.
            var fmt: ?FormatChunk = null;
            var data_size: usize = 0; // Bytes in data chunk.
            var chunk_size: usize = 0;
            while (true) {
                chunk_id = try inner_reader.readBytesNoEof(4);
                chunk_size = try inner_reader.readInt(u32, .little);

                if (std.mem.eql(u8, "fmt ", &chunk_id)) {
                    fmt = try FormatChunk.parse(inner_reader, chunk_size);
                    try fmt.?.validate();

                    // TODO Support 32-bit aligned i24 blocks.
                    const bytes_per_sample = @as(usize, @intCast(fmt.?.block_align)) / @as(usize, @intCast(fmt.?.channels));
                    if (bytes_per_sample * 8 != @as(usize, @intCast(fmt.?.bits))) {
                        return error.Unsupported;
                    }
                } else if (std.mem.eql(u8, "data", &chunk_id)) {
                    // Expect data chunk to be last.
                    data_size = chunk_size;
                    break;
                } else {
                    std.log.info("skipping unrecognized chunk {s}", .{chunk_id});
                    try inner_reader.skipBytes(chunk_size, .{});
                }
            }

            if (fmt == null) {
                std.log.debug("no fmt chunk present", .{});
                return error.InvalidFileType;
            }

            std.log.info(
                "{}(bits={}) sample_rate={} channels={} size=0x{x}",
                .{ fmt.?.code, fmt.?.bits, fmt.?.sample_rate, fmt.?.channels, total_size },
            );

            const data_start = counting_reader.bytes_read;
            if (data_start + data_size > total_size) {
                return error.InvalidSize;
            }
            if (data_size % (@as(usize, @intCast(fmt.?.channels)) * @as(usize, @intCast(fmt.?.bits)) / 8) != 0) {
                return error.InvalidSize;
            }

            return .{
                .counting_reader = counting_reader,
                .fmt = fmt.?,
                .data_start = data_start,
                .data_size = data_size,
            };
        }

        /// Read samples from stream and converts to type T. Supports PCM encoded ints and IEEE float.
        /// Multi-channel samples are interleaved: samples for time `t` for all channels are written to
        /// `t * channels`. Thus, `buf.len` must be evenly divisible by `channels`.
        ///
        /// Errors:
        ///     InvalidArgument - `buf.len` not evenly divisible `channels`.
        ///
        /// Returns: number of bytes read. 0 indicates end of stream.
        pub fn read(self: *Self, comptime T: type, buf: []T) Error!usize {
            return switch (self.fmt.code) {
                .pcm => switch (self.fmt.bits) {
                    8 => self.readInternal(u8, T, buf),
                    16 => self.readInternal(i16, T, buf),
                    24 => self.readInternal(i24, T, buf),
                    32 => self.readInternal(i32, T, buf),
                    else => std.debug.panic("invalid decoder state, unexpected fmt bits {}", .{self.fmt.bits}),
                },
                .ieee_float => self.readInternal(f32, T, buf),
                else => std.debug.panic("invalid decoder state, unexpected fmt code {}", .{@intFromEnum(self.fmt.code)}),
            };
        }

        fn readInternal(self: *Self, comptime S: type, comptime T: type, buf: []T) Error!usize {
            var reader = self.counting_reader.reader();

            const limit = @min(buf.len, self.remaining());
            var i: usize = 0;
            while (i < limit) : (i += 1) {
                const value = switch (@typeInfo(S)) {
                    .float => try readFloat(S, reader),
                    .int => try reader.readInt(S, .little),
                    else => @compileError(bad_type),
                };
                buf[i] = sample.convert(T, value);
            }
            return i;
        }
    };
}

pub fn decoder(reader: anytype) !Decoder(@TypeOf(reader)) {
    return Decoder(@TypeOf(reader)).init(reader);
}

/// Encode audio samples to wav file. Must call `finalize()` once complete. Samples will be encoded
/// with type T (PCM int or IEEE float).
pub fn Encoder(bit_type: BitType) type {
    return struct {
        const Self = @This();

        writer_buf: [1024]u8 = undefined,
        writer: std.fs.File.Writer,
        fmt: FormatChunk,
        data_size: usize = 0,

        pub fn init(
            f: std.fs.File,
            sample_rate: usize,
            channels: usize,
        ) !Self {
            var self: Self = .{
                .writer = undefined,
                .fmt = undefined,
            };
            self.writer = f.writer(&self.writer_buf);

            const bits = switch (bit_type) {
                .u8 => 8,
                .i16 => 16,
                .i24 => 24,
                .f32 => 32,
            };

            if (sample_rate == 0 or sample_rate > std.math.maxInt(u32)) {
                std.log.debug("invalid sample_rate {}", .{sample_rate});
                return error.InvalidArgument;
            }
            if (channels == 0 or channels > std.math.maxInt(u16)) {
                std.log.debug("invalid channels {}", .{channels});
                return error.InvalidArgument;
            }
            const bytes_per_second = sample_rate * channels * bits / 8;
            if (bytes_per_second > std.math.maxInt(u32)) {
                std.log.debug("bytes_per_second, {}, too large", .{bytes_per_second});
                return error.InvalidArgument;
            }

            self.fmt = .{
                .code = switch (bit_type) {
                    .u8, .i16, .i24 => .pcm,
                    .f32 => .ieee_float,
                },
                .channels = @intCast(channels),
                .sample_rate = @intCast(sample_rate),
                .bytes_per_second = @intCast(bytes_per_second),
                .block_align = @intCast(channels * bits / 8),
                .bits = @intCast(bits),
            };

            // Write a placeholder header first.
            // This reserves space and moves the file cursor forward.
            try self.writeHeader();

            return self;
        }

        /// Write samples of type S to stream after converting to type T. Supports PCM encoded ints and
        /// IEEE float. Multi-channel samples must be interleaved: samples for time `t` for all channels
        /// are written to `t * channels`.
        pub fn write(self: *Self, comptime S: type, buf: []const S) !void {
            for (buf) |x| {
                switch (bit_type) {
                    .u8 => {
                        // writeInt expects a value of the same type parameter.
                        try self.writer.interface.writeInt(u8, sample.convert(u8, x), .little);
                        self.data_size += @bitSizeOf(u8) / 8;
                    },
                    .i16 => {
                        // writeInt expects a value of the same type parameter.
                        try self.writer.interface.writeInt(i16, sample.convert(i16, x), .little);
                        self.data_size += @bitSizeOf(i16) / 8;
                    },
                    .i24 => {
                        // writeInt expects a value of the same type parameter.
                        try self.writer.interface.writeInt(i24, sample.convert(i24, x), .little);
                        self.data_size += @bitSizeOf(i24) / 8;
                    },
                    .f32 => {
                        const f: f32 = sample.convert(f32, x);
                        try self.writer.interface.writeAll(std.mem.asBytes(&f));
                        self.data_size += @bitSizeOf(f32) / 8;
                    },
                }
            }
        }

        fn writeHeader(self: *Self) !void {
            // Size of RIFF header + fmt id/size + fmt chunk + data id/size.
            const header_size: usize = 12 + 8 + @sizeOf(@TypeOf(self.fmt)) + 8;
            const total_file_size = header_size + self.data_size - 8; // RIFF size field excludes "RIFF" and the size field itself.

            if (header_size + self.data_size > std.math.maxInt(u32)) {
                return error.Overflow;
            }

            try self.writer.interface.writeAll("RIFF");
            try self.writer.interface.writeInt(u32, @intCast(total_file_size), .little); // Overwritten by finalize().
            try self.writer.interface.writeAll("WAVE");

            try self.writer.interface.writeAll("fmt ");
            try self.writer.interface.writeInt(u32, @sizeOf(@TypeOf(self.fmt)), .little);
            var fmt_buf: @TypeOf(self.fmt) = self.fmt;
            try self.writer.interface.writeAll(std.mem.asBytes(&fmt_buf));

            try self.writer.interface.writeAll("data");
            try self.writer.interface.writeInt(u32, @intCast(self.data_size), .little);
        }

        /// Must be called once writing is complete. Writes total size to file header.
        pub fn finalize(self: *Self) !void {
            try self.writer.interface.flush();
            try self.writer.seekTo(0);
            try self.writeHeader();
            try self.writer.interface.flush();
        }
    };
}

pub fn encoder(
    comptime bit_type: BitType,
    file: std.fs.File,
    sample_rate: usize,
    channels: usize,
) !Encoder(bit_type) {
    return Encoder(bit_type).init(file, sample_rate, channels);
}

const BitType = enum { u8, i16, i24, f32 };

// Tests (kept identical in intent). Ensure test data files and `sample.zig` exist.
test "pcm(bits=8) sample_rate=22050 channels=1" {
    const test_data: []const u8 = @embedFile("test_data/pcm8_22050_mono.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(@as(usize, 22050), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 1), wav_decoder.channels());
    try expectEqual(@as(usize, 8), wav_decoder.bits());
    try expectEqual(@as(usize, 104676), wav_decoder.remaining());

    var buf: [64]f32 = undefined;
    while (true) {
        if (try wav_decoder.read(f32, &buf) < buf.len) {
            break;
        }
    }
}

test "pcm(bits=16) sample_rate=44100 channels=2" {
    const data_len: usize = 312542;

    const test_data: []const u8 = @embedFile("test_data/pcm16_44100_stereo.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(@as(usize, 44100), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, data_len), wav_decoder.remaining());

    const buf = try std.testing.allocator.alloc(i16, data_len);
    defer std.testing.allocator.free(buf);

    try expectEqual(data_len, try wav_decoder.read(i16, buf));
    try expectEqual(@as(usize, 0), try wav_decoder.read(i16, buf));
    try expectEqual(@as(usize, 0), wav_decoder.remaining());
}

test "pcm(bits=24) sample_rate=48000 channels=1" {
    const test_data: []const u8 = @embedFile("test_data/pcm24_48000_mono.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(@as(usize, 48000), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 1), wav_decoder.channels());
    try expectEqual(@as(usize, 24), wav_decoder.bits());
    try expectEqual(@as(usize, 508800), wav_decoder.remaining());

    var buf: [1]f32 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try expectEqual(@as(usize, 1), try wav_decoder.read(f32, &buf));
    }
    try expectEqual(@as(usize, 507800), wav_decoder.remaining());

    while (true) {
        const samples_read = try wav_decoder.read(f32, &buf);
        if (samples_read == 0) {
            break;
        }
        try expectEqual(@as(usize, 1), samples_read);
    }
}

test "pcm(bits=24) sample_rate=44100 channels=2" {
    const test_data: []const u8 = @embedFile("test_data/pcm24_44100_stereo.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(@as(usize, 44100), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, 24), wav_decoder.bits());
    try expectEqual(@as(usize, 157952), wav_decoder.remaining());

    var buf: [1]f32 = undefined;
    while (true) {
        const samples_read = try wav_decoder.read(f32, &buf);
        if (samples_read == 0) {
            break;
        }
        try expectEqual(@as(usize, 1), samples_read);
    }
}

test "ieee_float(bits=32) sample_rate=48000 channels=2" {
    const test_data: []const u8 = @embedFile("test_data/float32_48000_stereo.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(@as(usize, 48000), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, 32), wav_decoder.bits());
    try expectEqual(@as(usize, 592342), wav_decoder.remaining());

    var buf: [64]f32 = undefined;
    while (true) {
        if (try wav_decoder.read(f32, &buf) < buf.len) {
            break;
        }
    }
}

test "ieee_float(bits=32) sample_rate=96000 channels=2" {
    const test_data: []const u8 = @embedFile("test_data/float32_96000_stereo.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(@as(usize, 96000), wav_decoder.sampleRate());
    try expectEqual(@as(usize, 2), wav_decoder.channels());
    try expectEqual(@as(usize, 32), wav_decoder.bits());
    try expectEqual(@as(usize, 67744), wav_decoder.remaining());

    var buf: [64]f32 = undefined;
    while (true) {
        if (try wav_decoder.read(f32, &buf) < buf.len) {
            break;
        }
    }

    try expectEqual(@as(usize, 0), wav_decoder.remaining());
}

test "error truncated" {
    const test_data: []const u8 = @embedFile("test_data/error-trunc.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());
    var buf: [3000]f32 = undefined;
    try expectError(error.EndOfStream, wav_decoder.read(f32, &buf));
}

test "error data_size too big" {
    const test_data: []const u8 = @embedFile("test_data/error-data_size1.wav");
    var stream = std.io.fixedBufferStream(test_data);

    var wav_decoder = try decoder(stream.reader());

    var buf: [1]u8 = undefined;
    var i: usize = 0;
    while (i < 44100) : (i += 1) {
        try expectEqual(@as(usize, 1), try wav_decoder.read(u8, &buf));
    }
    try expectError(error.EndOfStream, wav_decoder.read(u8, &buf));
}

fn testEncodeDecode(comptime T: type, comptime sample_rate: usize, allocator: std.mem.Allocator) !void {
    const twopi = std.math.pi * 2.0;
    const freq = 440.0;
    const secs = 3;
    const increment = freq / @as(f32, @floatFromInt(sample_rate)) * twopi;

    var tmp_dir: std.testing.TmpDir = std.testing.tmpDir(.{});
    tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("example.wav", .{});
    var wav_encoder = try encoder(T, file, sample_rate, 1);

    var phase: f32 = 0.0;
    var i: usize = 0;
    while (i < secs * sample_rate) : (i += 1) {
        try wav_encoder.write(f32, &.{std.math.sin(phase)});
        phase += increment;
    }

    try wav_encoder.finalize();
    //try stream.seekTo(0);

    // ----------------- Decoder ------------------------

    const data: []const u8 = try file.readToEndAlloc(allocator, 1024);
    var stream = std.io.fixedBufferStream(data);

    var wav_decoder = try decoder(stream.reader());
    try expectEqual(sample_rate, wav_decoder.sampleRate());
    try expectEqual(@as(usize, 1), wav_decoder.channels());
    try expectEqual(secs * sample_rate, wav_decoder.remaining());

    phase = 0.0;
    i = 0;
    while (i < secs * sample_rate) : (i += 1) {
        var value: [1]f32 = undefined;
        try expectEqual(try wav_decoder.read(f32, &value), 1);
        try std.testing.expectApproxEqAbs(std.math.sin(phase), value[0], 0.0001);
        phase += increment;
    }

    try expectEqual(@as(usize, 0), wav_decoder.remaining());
}

//test "encode-decode sine" {
//    const allocator = std.testing.allocator;
//
//    try testEncodeDecode(f32, 44100, allocator);
//    try testEncodeDecode(i24, 48000, allocator);
//    try testEncodeDecode(i16, 44100, allocator);
//}
