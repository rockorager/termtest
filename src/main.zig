//! Application entry point.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

const Mode = enum {
    rgb,
    index,
    bg_ascii,
    square_emoji,
    emoji,
    zwj_emoji,
    all,

    fn parse(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "rgb")) return .rgb;
        if (std.mem.eql(u8, value, "index")) return .index;
        if (std.mem.eql(u8, value, "bg-ascii") or std.mem.eql(u8, value, "bg_ascii")) return .bg_ascii;
        if (std.mem.eql(u8, value, "square-emoji") or std.mem.eql(u8, value, "square_emoji")) return .square_emoji;
        if (std.mem.eql(u8, value, "emoji")) return .emoji;
        if (std.mem.eql(u8, value, "flame-emoji") or std.mem.eql(u8, value, "flame_emoji")) return .emoji;
        if (std.mem.eql(u8, value, "zwj-emoji") or std.mem.eql(u8, value, "zwj_emoji")) return .zwj_emoji;
        if (std.mem.eql(u8, value, "all")) return .all;
        return null;
    }

    fn name(mode: Mode) []const u8 {
        return switch (mode) {
            .rgb => "rgb",
            .index => "index",
            .bg_ascii => "bg-ascii",
            .square_emoji => "square-emoji",
            .emoji => "flame-emoji",
            .zwj_emoji => "zwj-emoji",
            .all => "all",
        };
    }
};

const Config = struct {
    mode: Mode = .all,
    width: ?usize = null,
    height: ?usize = null,
    seconds: u64 = 5,
    runtime_seconds: ?u64 = null,
    json: bool = false,
    alt_screen: bool = true,
};

const RunConfig = struct {
    mode: Mode,
    width: usize,
    height: usize,
    screen_width: usize,
    screen_height: usize,
    seconds: u64,
    runtime_seconds: ?u64,
    json: bool,
    alt_screen: bool,
};

const ScreenSize = struct {
    width: usize,
    height: usize,
};

const Stats = struct {
    frames_attempted: u64 = 0,
    frames_written: u64 = 0,
    dropped_frames: u64 = 0,
    partial_frames: u64 = 0,
    bytes_written: u64 = 0,

    fn add(self: *Stats, other: Stats) void {
        self.frames_attempted += other.frames_attempted;
        self.frames_written += other.frames_written;
        self.dropped_frames += other.dropped_frames;
        self.partial_frames += other.partial_frames;
        self.bytes_written += other.bytes_written;
    }
};

const WriteResult = union(enum) {
    complete: usize,
    partial: usize,
    would_block,
};

const WriteError = error{Unexpected};

const tio_cgwinsz = 0x5413;
const cycle_modes = [_]Mode{ .rgb, .index, .bg_ascii, .square_emoji, .emoji, .zwj_emoji };
const terminal_restore_alt = "\x1b[0m\x1b[?2027l\x1b[?25h\x1b[?1049l";
const terminal_restore_normal = "\x1b[0m\x1b[?2027l\x1b[?25h\n";

var stop_requested: std.atomic.Value(bool) = .init(false);
var signal_count: std.atomic.Value(u32) = .init(0);
var terminal_active: std.atomic.Value(bool) = .init(false);
var terminal_alt_screen: std.atomic.Value(bool) = .init(false);
var terminal_original_flags: std.atomic.Value(u32) = .init(0);
var terminal_fd: std.atomic.Value(posix.fd_t) = .init(posix.STDOUT_FILENO);

const fire_palette_256 = [_]u8{
    0,   233, 234, 52,  53,  88,  89,  94,  95,
    96,  130, 131, 132, 133, 172, 214, 215, 220,
    220, 221, 3,   226, 227, 230, 195, 230,
};

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

const fire_palette_rgb = [_]Rgb{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 7, .g = 7, .b = 7 },
    .{ .r = 16, .g = 16, .b = 16 },
    .{ .r = 47, .g = 0, .b = 0 },
    .{ .r = 63, .g = 0, .b = 0 },
    .{ .r = 95, .g = 0, .b = 0 },
    .{ .r = 95, .g = 0, .b = 0 },
    .{ .r = 135, .g = 95, .b = 0 },
    .{ .r = 135, .g = 95, .b = 95 },
    .{ .r = 135, .g = 95, .b = 135 },
    .{ .r = 175, .g = 95, .b = 0 },
    .{ .r = 175, .g = 95, .b = 95 },
    .{ .r = 175, .g = 95, .b = 135 },
    .{ .r = 175, .g = 95, .b = 175 },
    .{ .r = 215, .g = 135, .b = 0 },
    .{ .r = 255, .g = 175, .b = 0 },
    .{ .r = 255, .g = 175, .b = 95 },
    .{ .r = 255, .g = 215, .b = 0 },
    .{ .r = 255, .g = 215, .b = 0 },
    .{ .r = 255, .g = 215, .b = 95 },
    .{ .r = 128, .g = 128, .b = 0 },
    .{ .r = 255, .g = 255, .b = 0 },
    .{ .r = 255, .g = 255, .b = 95 },
    .{ .r = 255, .g = 255, .b = 215 },
    .{ .r = 215, .g = 255, .b = 255 },
    .{ .r = 255, .g = 255, .b = 215 },
};

const ascii_ramp = ".,:-=+*#%@";
const max_intensity: u8 = fire_palette_256.len - 1;

const Fire = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    tick: u64 = 0,

    fn init(allocator: std.mem.Allocator, width: usize, terminal_height: usize) !Fire {
        const height = try std.math.mul(usize, terminal_height, 2);
        const len = try std.math.mul(usize, width, height);
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 0);

        var fire: Fire = .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .tick = 0,
        };
        fire.seedBottom();
        return fire;
    }

    fn deinit(self: *Fire, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    fn seedBottom(self: *Fire) void {
        const y = self.height - 1;
        for (0..self.width) |x| {
            self.pixels[y * self.width + x] = max_intensity;
        }
    }

    fn stokeBottom(self: *Fire, rng: std.Random) void {
        const y = self.height - 1;
        for (0..self.width) |x| {
            const flicker = rng.intRangeAtMost(u8, 0, 7);
            self.pixels[y * self.width + x] = max_intensity - flicker;
        }
    }

    fn get(self: Fire, x: usize, y: usize) u8 {
        return self.pixels[y * self.width + x];
    }
};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) {
        try writeAll(posix.STDERR_FILENO, "termtest currently uses Linux fcntl/write syscalls for nonblocking PTY writes.\n");
        return error.UnsupportedOperatingSystem;
    }

    const allocator = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    const parsed_config = parseConfig(&args) catch |err| switch (err) {
        error.Help => {
            try usage(posix.STDERR_FILENO);
            return;
        },
        else => return err,
    };

    const terminal = openTerminal() orelse posix.STDERR_FILENO;
    defer {
        if (terminal != posix.STDOUT_FILENO and terminal != posix.STDERR_FILENO) _ = linux.close(terminal);
    }
    terminal_fd.store(terminal, .seq_cst);

    const screen_size = detectScreenSize(init.environ_map, terminal);
    const config: RunConfig = .{
        .mode = parsed_config.mode,
        .width = parsed_config.width orelse screen_size.width,
        .height = parsed_config.height orelse if (screen_size.height > 1) screen_size.height - 1 else 1,
        .screen_width = screen_size.width,
        .screen_height = screen_size.height,
        .seconds = parsed_config.seconds,
        .runtime_seconds = parsed_config.runtime_seconds,
        .json = parsed_config.json,
        .alt_screen = parsed_config.alt_screen,
    };

    if (config.width == 0 or config.height == 0) {
        try writeAll(posix.STDERR_FILENO, "width and height must be greater than zero\n");
        return error.InvalidArgument;
    }

    installSignalHandlers();

    var stats: Stats = .{};
    var mode_stats = [_]Stats{.{}} ** cycle_modes.len;
    var mode_elapsed_ns = [_]u64{0} ** cycle_modes.len;
    const elapsed_ns = blk: {
        const original_flags = try setFdNonblocking(terminal, true);
        terminal_original_flags.store(original_flags, .seq_cst);
        terminal_alt_screen.store(config.alt_screen, .seq_cst);
        terminal_active.store(true, .seq_cst);
        defer restoreTerminalNormal();

        if (config.alt_screen) {
            _ = try writeFrame(terminal, "\x1b[?1049h\x1b[?2027h\x1b[?25l\x1b[2J\x1b[H");
        } else {
            _ = try writeFrame(terminal, "\x1b[?2027h\x1b[?25l\x1b[2J\x1b[H");
        }

        var fire = try Fire.init(allocator, config.width, config.height);
        defer fire.deinit(allocator);

        var prng = std.Random.DefaultPrng.init(monotonicNanos());
        const rng = prng.random();

        const start = monotonicNanos();
        const per_mode_ns = config.seconds * std.time.ns_per_s;
        const total_ns = if (config.runtime_seconds) |runtime_seconds|
            runtime_seconds * std.time.ns_per_s
        else if (config.mode == .all)
            per_mode_ns * cycle_modes.len
        else
            per_mode_ns;
        const deadline = start + total_ns;
        var buffer: std.Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var chunk_index: usize = 0;
        const chunks_per_sweep = fire.height / 2 + 1;

        while (!stop_requested.load(.seq_cst) and monotonicNanos() < deadline) {
            const now = monotonicNanos();
            const elapsed = now - start;
            const mode = activeMode(config.mode, elapsed, per_mode_ns);
            if (chunk_index == 0) updateFire(&fire, rng);
            buffer.clearRetainingCapacity();
            try buildChunk(&buffer.writer, mode, fire, chunk_index);
            const chunk = buffer.written();

            var frame_stats: Stats = .{ .frames_attempted = 1 };
            switch (try writeFrame(terminal, chunk)) {
                .complete => |bytes_written| {
                    frame_stats.frames_written = 1;
                    frame_stats.bytes_written = bytes_written;
                },
                .partial => |bytes_written| {
                    frame_stats.partial_frames = 1;
                    frame_stats.bytes_written = bytes_written;
                },
                .would_block => frame_stats.dropped_frames = 1,
            }

            stats.add(frame_stats);
            const index = modeIndex(mode);
            mode_stats[index].add(frame_stats);
            mode_elapsed_ns[index] += monotonicNanos() - now;
            chunk_index = (chunk_index + 1) % chunks_per_sweep;
        }

        break :blk monotonicNanos() - start;
    };

    try report(config, stats, mode_stats, mode_elapsed_ns, elapsed_ns);
}

fn parseConfig(args: *std.process.Args.Iterator) !Config {
    var config: Config = .{};
    var mode_seen = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.Help;
        if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            config.alt_screen = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--seconds") or std.mem.eql(u8, arg, "-s")) {
            config.seconds = try parseNext(u64, args, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--runtime") or std.mem.eql(u8, arg, "-r")) {
            config.runtime_seconds = try parseNext(u64, args, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "-w")) {
            config.width = try parseNext(usize, args, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--height") or std.mem.eql(u8, arg, "-hgt")) {
            config.height = try parseNext(usize, args, arg);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--seconds=")) {
            config.seconds = try std.fmt.parseInt(u64, arg[10..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--runtime=")) {
            config.runtime_seconds = try std.fmt.parseInt(u64, arg[10..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--width=")) {
            config.width = try std.fmt.parseInt(usize, arg[8..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--height=")) {
            config.height = try std.fmt.parseInt(usize, arg[9..], 10);
            continue;
        }

        if (!mode_seen) {
            if (Mode.parse(arg)) |mode| {
                config.mode = mode;
                mode_seen = true;
                continue;
            }
        }

        try writeAll(posix.STDERR_FILENO, "unknown argument or mode: ");
        try writeAll(posix.STDERR_FILENO, arg);
        try writeAll(posix.STDERR_FILENO, "\n");
        try usage(posix.STDERR_FILENO);
        return error.InvalidArgument;
    }

    return config;
}

fn parseNext(comptime T: type, args: *std.process.Args.Iterator, flag: []const u8) !T {
    const value = args.next() orelse {
        try writeAll(posix.STDERR_FILENO, "missing value for ");
        try writeAll(posix.STDERR_FILENO, flag);
        try writeAll(posix.STDERR_FILENO, "\n");
        return error.InvalidArgument;
    };
    return std.fmt.parseInt(T, value, 10);
}

fn openTerminal() ?posix.fd_t {
    return posix.openatZ(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch null;
}

fn detectScreenSize(environ_map: *const std.process.Environ.Map, preferred_fd: posix.fd_t) ScreenSize {
    return getScreenSize(preferred_fd) orelse
        getScreenSize(posix.STDOUT_FILENO) orelse
        getScreenSize(posix.STDERR_FILENO) orelse
        getScreenSize(posix.STDIN_FILENO) orelse
        getScreenSizeFromEnv(environ_map) orelse
        ScreenSize{ .width = 80, .height = 24 };
}

fn getScreenSize(fd: posix.fd_t) ?ScreenSize {
    var size: posix.winsize = undefined;
    const rc = linux.ioctl(fd, tio_cgwinsz, @intFromPtr(&size));
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => return null,
    }
    if (size.col == 0 or size.row == 0) return null;
    return .{
        .width = size.col,
        .height = size.row,
    };
}

fn getScreenSizeFromEnv(environ_map: *const std.process.Environ.Map) ?ScreenSize {
    const columns_text = environ_map.get("COLUMNS") orelse return null;
    const lines_text = environ_map.get("LINES") orelse return null;
    const width = std.fmt.parseInt(usize, columns_text, 10) catch return null;
    const height = std.fmt.parseInt(usize, lines_text, 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

fn usage(fd: posix.fd_t) !void {
    try writeAll(fd,
        \\usage: termtest [mode] [options]
        \\
        \\modes:
        \\  rgb        24-bit foreground colors + block glyphs
        \\  index      256-color indexed foreground colors + block glyphs
        \\  bg-ascii   256-color background colors + ASCII characters
        \\  square-emoji colored square emoji cells
        \\  flame-emoji  flame/explosion emoji cells (also: emoji)
        \\  zwj-emoji    smile/person emoji, including ZWJ sequences
        \\  all        rotate through every mode
        \\
        \\options:
        \\  -s, --seconds N     seconds per mode; for one mode, run duration unless --runtime is set (default: 5)
        \\  -r, --runtime N     total runtime; cycle modes until this many seconds elapse
        \\  -w, --width N       generated terminal width (default: detected screen width)
        \\      --height N      generated fire height below the title (default: detected screen height - 1)
        \\      --json          print final report as JSON instead of a table
        \\      --no-alt-screen draw in the current screen instead of the alternate screen
        \\
    );
}

fn activeMode(mode: Mode, elapsed_ns: u64, per_mode_ns: u64) Mode {
    if (mode != .all) return mode;
    if (per_mode_ns == 0) return cycle_modes[0];
    const index = (elapsed_ns / per_mode_ns) % cycle_modes.len;
    return cycle_modes[index];
}

fn modeIndex(mode: Mode) usize {
    return switch (mode) {
        .rgb => 0,
        .index => 1,
        .bg_ascii => 2,
        .square_emoji => 3,
        .emoji => 4,
        .zwj_emoji => 5,
        .all => unreachable,
    };
}

fn updateFire(fire: *Fire, rng: std.Random) void {
    fire.tick += 1;
    var y: usize = 1;
    while (y < fire.height) : (y += 1) {
        var x: usize = 0;
        while (x < fire.width) : (x += 1) {
            const src = fire.get(x, y);
            const r = rng.intRangeAtMost(u8, 0, 4);
            const decay: u8 = if (rng.intRangeAtMost(u8, 0, 2) == 0) 1 else 0;

            const dst_x_signed = @as(isize, @intCast(x)) + 2 - @as(isize, @intCast(r));
            if (dst_x_signed < 0 or dst_x_signed >= @as(isize, @intCast(fire.width))) continue;

            const dst_x: usize = @intCast(dst_x_signed);
            const dst_idx = (y - 1) * fire.width + dst_x;
            fire.pixels[dst_idx] = if (src > decay) src - decay else 0;
        }
    }

    fire.stokeBottom(rng);
}

fn buildChunk(writer: *std.Io.Writer, mode: Mode, fire: Fire, chunk_index: usize) !void {
    if (chunk_index == 0) {
        try writer.writeAll("\x1b[H");
        try renderTitle(writer, mode.name(), fire.width);
        return;
    }

    const display_rows = fire.height / 2;
    const row = display_rows - chunk_index;
    switch (mode) {
        .rgb => try renderHalfBlockRgbRow(writer, fire, row),
        .index => try renderHalfBlockIndexRow(writer, fire, row),
        .bg_ascii => try renderBackgroundAsciiRow(writer, fire, row),
        .square_emoji => try renderEmojiRow(writer, fire, row, .square),
        .emoji => try renderEmojiRow(writer, fire, row, .flame),
        .zwj_emoji => try renderEmojiRow(writer, fire, row, .zwj),
        .all => unreachable,
    }
}

fn renderTitle(writer: *std.Io.Writer, title: []const u8, width: usize) !void {
    try writer.writeAll("\x1b[0m\x1b[2K");
    const prefix = "termtest: ";
    const full_title_width = prefix.len + title.len;
    const title_width = @min(full_title_width, width);
    const padding = (width - title_width) / 2;
    for (0..padding) |_| {
        try writer.writeByte(' ');
    }
    if (width <= prefix.len) {
        try writer.writeAll(prefix[0..width]);
    } else {
        const mode_width = @min(title.len, width - prefix.len);
        try writer.print("{s}{s}", .{ prefix, title[0..mode_width] });
    }
}

fn renderHalfBlockRgbRow(writer: *std.Io.Writer, fire: Fire, row: usize) !void {
    try writer.print("\x1b[{d};1H", .{row + 2});
    var prev_hi: ?u8 = null;
    var prev_lo: ?u8 = null;
    const y = row * 2;
    for (0..fire.width) |x| {
        const hi = fire.get(x, y);
        const lo = fire.get(x, y + 1);
        if (prev_hi == null or prev_hi.? != hi) {
            const color = fire_palette_rgb[hi];
            try writer.print("\x1b[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
            prev_hi = hi;
        }
        if (prev_lo == null or prev_lo.? != lo) {
            const color = fire_palette_rgb[lo];
            try writer.print("\x1b[48;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
            prev_lo = lo;
        }
        try writer.writeAll("▀");
    }
    try writer.writeAll("\x1b[0m");
}

fn renderHalfBlockIndexRow(writer: *std.Io.Writer, fire: Fire, row: usize) !void {
    try writer.print("\x1b[{d};1H", .{row + 2});
    var prev_hi: ?u8 = null;
    var prev_lo: ?u8 = null;
    const y = row * 2;
    for (0..fire.width) |x| {
        const hi = fire.get(x, y);
        const lo = fire.get(x, y + 1);
        if (prev_hi == null or prev_hi.? != hi) {
            try writer.print("\x1b[38;5;{d}m", .{fire_palette_256[hi]});
            prev_hi = hi;
        }
        if (prev_lo == null or prev_lo.? != lo) {
            try writer.print("\x1b[48;5;{d}m", .{fire_palette_256[lo]});
            prev_lo = lo;
        }
        try writer.writeAll("▀");
    }
    try writer.writeAll("\x1b[0m");
}

fn renderBackgroundAsciiRow(writer: *std.Io.Writer, fire: Fire, row: usize) !void {
    try writer.print("\x1b[{d};1H", .{row + 2});
    var prev_bg: ?u8 = null;
    var prev_fg: ?u8 = null;
    const y = row * 2;
    for (0..fire.width) |x| {
        const hi = fire.get(x, y);
        const lo = fire.get(x, y + 1);
        const intensity: u8 = @intCast((@as(u16, hi) + lo) / 2);
        const fg: u8 = if (intensity < 16) 231 else 16;
        if (prev_bg == null or prev_bg.? != intensity) {
            try writer.print("\x1b[48;5;{d}m", .{fire_palette_256[intensity]});
            prev_bg = intensity;
        }
        if (prev_fg == null or prev_fg.? != fg) {
            try writer.print("\x1b[38;5;{d}m", .{fg});
            prev_fg = fg;
        }
        try writer.writeByte(asciiForIntensity(intensity, x, row, fire.tick));
    }
    try writer.writeAll("\x1b[0m");
}

fn renderEmojiRow(writer: *std.Io.Writer, fire: Fire, row: usize, kind: EmojiKind) !void {
    try writer.print("\x1b[{d};1H", .{row + 2});
    const y = row * 2;
    var x: usize = 0;
    while (x < fire.width) : (x += 2) {
        const next_x = @min(x + 1, fire.width - 1);
        const total = @as(u16, fire.get(x, y)) +
            fire.get(next_x, y) +
            fire.get(x, y + 1) +
            fire.get(next_x, y + 1);
        const intensity: u8 = @intCast(total / 4);
        try writer.writeAll(emojiForIntensity(intensity, kind, x, row, fire.tick));
    }
}

fn asciiForIntensity(intensity: u8, x: usize, y: usize, tick: u64) u8 {
    const seed = glyphSeed(intensity, x, y, tick);
    const band = @as(usize, intensity) * 6 / (max_intensity + 1);
    const group = switch (band) {
        0 => ".,`'",
        1 => ":;!i",
        2 => "-=~+",
        3 => "*xvV",
        4 => "#%&$",
        else => "@MW8",
    };
    return group[@intCast(seed % group.len)];
}

const EmojiKind = enum {
    square,
    flame,
    zwj,
};

const square_emoji_0 = [_][]const u8{ "  ", "⬛", "⚫", "◼️" };
const square_emoji_1 = [_][]const u8{ "🟫", "🤎", "◾" };
const square_emoji_2 = [_][]const u8{ "🟥", "🔴", "❤️" };
const square_emoji_3 = [_][]const u8{ "🟧", "🟠", "🔶" };
const square_emoji_4 = [_][]const u8{ "🟨", "🟡", "⭐" };
const square_emoji_5 = [_][]const u8{ "⬜", "⚪", "💫" };

const flame_emoji_0 = [_][]const u8{ "  ", "▫️", "▪️" };
const flame_emoji_1 = [_][]const u8{ "🧱", "🪵", "🌑" };
const flame_emoji_2 = [_][]const u8{ "💥", "🌋", "❤️‍🔥" };
const flame_emoji_3 = [_][]const u8{ "🔥", "♨️", "❤️‍🔥" };
const flame_emoji_4 = [_][]const u8{ "✨", "🌟", "⚡" };
const flame_emoji_5 = [_][]const u8{ "💫", "⚡", "✨" };

const zwj_emoji_0 = [_][]const u8{ "  ", "🙂", "😐" };
const zwj_emoji_1 = [_][]const u8{ "😃", "😅", "🙃" };
const zwj_emoji_2 = [_][]const u8{ "🥵", "😵‍💫", "🤯" };
const zwj_emoji_3 = [_][]const u8{ "🧑‍🚒", "👩‍🚒", "👨‍🚒" };
const zwj_emoji_4 = [_][]const u8{ "🧑‍🏭", "👩‍🏭", "👨‍🏭" };
const zwj_emoji_5 = [_][]const u8{ "👨‍👩‍👧‍👦", "👩‍👩‍👧‍👦", "👨‍👨‍👧‍👦" };

fn emojiForIntensity(intensity: u8, kind: EmojiKind, x: usize, y: usize, tick: u64) []const u8 {
    const seed = glyphSeed(intensity, x, y, tick);
    const band = @as(usize, intensity) * 6 / (max_intensity + 1);
    const options = switch (kind) {
        .square => switch (band) {
            0 => square_emoji_0[0..],
            1 => square_emoji_1[0..],
            2 => square_emoji_2[0..],
            3 => square_emoji_3[0..],
            4 => square_emoji_4[0..],
            else => square_emoji_5[0..],
        },
        .flame => switch (band) {
            0 => flame_emoji_0[0..],
            1 => flame_emoji_1[0..],
            2 => flame_emoji_2[0..],
            3 => flame_emoji_3[0..],
            4 => flame_emoji_4[0..],
            else => flame_emoji_5[0..],
        },
        .zwj => switch (band) {
            0 => zwj_emoji_0[0..],
            1 => zwj_emoji_1[0..],
            2 => zwj_emoji_2[0..],
            3 => zwj_emoji_3[0..],
            4 => zwj_emoji_4[0..],
            else => zwj_emoji_5[0..],
        },
    };
    return options[@intCast(seed % options.len)];
}

fn glyphSeed(intensity: u8, x: usize, y: usize, tick: u64) u64 {
    var seed = tick *% 0x9e3779b97f4a7c15;
    seed ^= @as(u64, @intCast(x)) *% 0xbf58476d1ce4e5b9;
    seed ^= @as(u64, @intCast(y)) *% 0x94d049bb133111eb;
    seed ^= @as(u64, intensity) *% 0x2545f4914f6cdd1d;
    seed ^= seed >> 30;
    seed *%= 0xbf58476d1ce4e5b9;
    seed ^= seed >> 27;
    seed *%= 0x94d049bb133111eb;
    seed ^= seed >> 31;
    return seed;
}

fn installSignalHandlers() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
    posix.sigaction(.HUP, &action, null);
    posix.sigaction(.QUIT, &action, null);
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .seq_cst);
    const previous = signal_count.fetchAdd(1, .seq_cst);
    if (previous > 0) {
        restoreTerminalFromSignal();
        linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
    }
}

fn restoreTerminalNormal() void {
    if (!terminal_active.swap(false, .seq_cst)) return;
    const fd = terminal_fd.load(.seq_cst);
    restoreFdFlags(fd, terminal_original_flags.load(.seq_cst));
    const bytes = if (terminal_alt_screen.load(.seq_cst)) terminal_restore_alt else terminal_restore_normal;
    writeAll(fd, bytes) catch {};
}

fn restoreTerminalFromSignal() void {
    if (!terminal_active.swap(false, .seq_cst)) return;
    const fd = terminal_fd.load(.seq_cst);
    _ = linux.fcntl(fd, linux.F.SETFL, terminal_original_flags.load(.seq_cst));
    const bytes = if (terminal_alt_screen.load(.seq_cst)) terminal_restore_alt else terminal_restore_normal;
    _ = linux.write(fd, bytes.ptr, bytes.len);
}

fn setFdNonblocking(fd: posix.fd_t, enabled: bool) !u32 {
    const got = linux.fcntl(fd, linux.F.GETFL, 0);
    switch (posix.errno(got)) {
        .SUCCESS => {},
        else => |err| {
            try writeAll(posix.STDERR_FILENO, "fcntl(F_GETFL) failed\n");
            return posix.unexpectedErrno(err);
        },
    }

    const original: u32 = @intCast(got);
    var flags: linux.O = @bitCast(original);
    flags.NONBLOCK = enabled;
    const raw_flags: u32 = @bitCast(flags);
    const set = linux.fcntl(fd, linux.F.SETFL, raw_flags);
    switch (posix.errno(set)) {
        .SUCCESS => return original,
        else => |err| {
            try writeAll(posix.STDERR_FILENO, "fcntl(F_SETFL) failed\n");
            return posix.unexpectedErrno(err);
        },
    }
}

fn restoreFdFlags(fd: posix.fd_t, flags: u32) void {
    _ = linux.fcntl(fd, linux.F.SETFL, flags);
}

fn writeFrame(fd: posix.fd_t, bytes: []const u8) WriteError!WriteResult {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + written, bytes.len - written);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) return if (written == 0) .would_block else .{ .partial = written };
                written += count;
            },
            .INTR => continue,
            .AGAIN => return if (written == 0) .would_block else .{ .partial = written },
            else => return error.Unexpected,
        }
    }
    return .{ .complete = written };
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + written, bytes.len - written);
        switch (posix.errno(rc)) {
            .SUCCESS => written += @intCast(rc),
            .INTR => continue,
            .AGAIN => continue,
            else => return error.Unexpected,
        }
    }
}

fn monotonicNanos() u64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => unreachable,
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn report(
    config: RunConfig,
    stats: Stats,
    mode_stats: [cycle_modes.len]Stats,
    mode_elapsed_ns: [cycle_modes.len]u64,
    elapsed_ns: u64,
) !void {
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer out.deinit();

    if (config.json) {
        try writeReportJson(&out.writer, config, stats, mode_stats, mode_elapsed_ns, elapsed_s);
    } else {
        try writeReportTable(&out.writer, config, stats, mode_stats, mode_elapsed_ns, elapsed_s);
    }
    try out.writer.writeByte('\n');

    try writeAll(posix.STDOUT_FILENO, out.written());
}

fn writeReportJson(
    writer: *std.Io.Writer,
    config: RunConfig,
    stats: Stats,
    mode_stats: [cycle_modes.len]Stats,
    mode_elapsed_ns: [cycle_modes.len]u64,
    elapsed_s: f64,
) !void {
    var jw: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try jw.beginObject();

    try jw.objectField("config");
    try jw.beginObject();
    try jw.objectField("mode");
    try jw.write(config.mode.name());
    try jw.objectField("seconds_per_mode");
    try jw.write(config.seconds);
    try jw.objectField("runtime_seconds");
    try jw.write(config.runtime_seconds);
    try jw.objectField("screen");
    try jw.beginObject();
    try jw.objectField("width");
    try jw.write(config.screen_width);
    try jw.objectField("height");
    try jw.write(config.screen_height);
    try jw.endObject();
    try jw.objectField("grid");
    try jw.beginObject();
    try jw.objectField("width");
    try jw.write(config.width);
    try jw.objectField("height");
    try jw.write(config.height);
    try jw.endObject();
    try jw.endObject();

    try jw.objectField("total");
    try writeStatsJson(&jw, stats, elapsed_s);

    try jw.objectField("modes");
    try jw.beginArray();
    if (config.mode == .all) {
        for (cycle_modes, 0..) |mode, index| {
            const mode_elapsed_s = @as(f64, @floatFromInt(mode_elapsed_ns[index])) / @as(f64, @floatFromInt(std.time.ns_per_s));
            try writeModeStatsJson(&jw, mode.name(), mode_stats[index], mode_elapsed_s);
        }
    } else {
        const index = modeIndex(config.mode);
        const mode_elapsed_s = @as(f64, @floatFromInt(mode_elapsed_ns[index])) / @as(f64, @floatFromInt(std.time.ns_per_s));
        try writeModeStatsJson(&jw, config.mode.name(), mode_stats[index], mode_elapsed_s);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeReportTable(
    writer: *std.Io.Writer,
    config: RunConfig,
    stats: Stats,
    mode_stats: [cycle_modes.len]Stats,
    mode_elapsed_ns: [cycle_modes.len]u64,
    elapsed_s: f64,
) !void {
    try writer.print(
        \\
        \\termtest complete
        \\  mode:             {s}
        \\  screen:           {d}x{d}
        \\  grid:             {d}x{d}
        \\  seconds/mode:     {d}
        \\
        \\stats:
        \\  mode          elapsed   MiB/s    MiB      attempted  accepted   complete   partial  zero-drop  drop%
        \\  ------------  --------  -------  -------  ---------  ---------  ---------  -------  ---------  ------
        \\
    , .{
        config.mode.name(),
        config.screen_width,
        config.screen_height,
        config.width,
        config.height,
        config.seconds,
    });

    try writeStatsTableRow(writer, "total", stats, elapsed_s);
    if (config.mode == .all) {
        for (cycle_modes, 0..) |mode, index| {
            const mode_elapsed_s = @as(f64, @floatFromInt(mode_elapsed_ns[index])) / @as(f64, @floatFromInt(std.time.ns_per_s));
            try writeStatsTableRow(writer, mode.name(), mode_stats[index], mode_elapsed_s);
        }
    } else {
        const index = modeIndex(config.mode);
        const mode_elapsed_s = @as(f64, @floatFromInt(mode_elapsed_ns[index])) / @as(f64, @floatFromInt(std.time.ns_per_s));
        try writeStatsTableRow(writer, config.mode.name(), mode_stats[index], mode_elapsed_s);
    }
}

fn writeStatsTableRow(writer: *std.Io.Writer, label: []const u8, stats: Stats, elapsed_s: f64) !void {
    const safe_elapsed_s = if (elapsed_s == 0.0) 1.0 else elapsed_s;
    const writes_accepted = stats.frames_written + stats.partial_frames;
    const mib = @as(f64, @floatFromInt(stats.bytes_written)) / (1024.0 * 1024.0);
    const mib_per_s = mib / safe_elapsed_s;
    const blocked_pct = if (stats.frames_attempted == 0)
        0.0
    else
        @as(f64, @floatFromInt(stats.dropped_frames)) * 100.0 / @as(f64, @floatFromInt(stats.frames_attempted));

    try writer.print(
        \\  {s:<12}  {d:>7.3}s  {d:>7.2}  {d:>7.2}  {d:>9}  {d:>9}  {d:>9}  {d:>7}  {d:>9}  {d:>5.1}%
        \\
    , .{
        label,
        elapsed_s,
        mib_per_s,
        mib,
        stats.frames_attempted,
        writes_accepted,
        stats.frames_written,
        stats.partial_frames,
        stats.dropped_frames,
        blocked_pct,
    });
}

fn writeModeStatsJson(jw: *std.json.Stringify, name: []const u8, stats: Stats, elapsed_s: f64) !void {
    try jw.beginObject();
    try jw.objectField("mode");
    try jw.write(name);
    try jw.objectField("stats");
    try writeStatsJson(jw, stats, elapsed_s);
    try jw.endObject();
}

fn writeStatsJson(jw: *std.json.Stringify, stats: Stats, elapsed_s: f64) !void {
    const safe_elapsed_s = if (elapsed_s == 0.0) 1.0 else elapsed_s;
    const writes_accepted = stats.frames_written + stats.partial_frames;
    const mib = @as(f64, @floatFromInt(stats.bytes_written)) / (1024.0 * 1024.0);
    const mib_per_s = mib / safe_elapsed_s;
    const drop_pct = if (stats.frames_attempted == 0)
        0.0
    else
        @as(f64, @floatFromInt(stats.dropped_frames)) * 100.0 / @as(f64, @floatFromInt(stats.frames_attempted));

    try jw.beginObject();
    try jw.objectField("elapsed_seconds");
    try jw.write(elapsed_s);
    try jw.objectField("bytes_written");
    try jw.write(stats.bytes_written);
    try jw.objectField("mib_written");
    try jw.write(mib);
    try jw.objectField("mib_per_second");
    try jw.write(mib_per_s);
    try jw.objectField("writes_attempted");
    try jw.write(stats.frames_attempted);
    try jw.objectField("writes_accepted");
    try jw.write(writes_accepted);
    try jw.objectField("writes_complete");
    try jw.write(stats.frames_written);
    try jw.objectField("writes_partial");
    try jw.write(stats.partial_frames);
    try jw.objectField("writes_blocked");
    try jw.write(stats.dropped_frames);
    try jw.objectField("blocked_percent");
    try jw.write(drop_pct);
    try jw.endObject();
}
