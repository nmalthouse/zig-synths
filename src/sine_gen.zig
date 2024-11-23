const std = @import("std");
const graph = @import("graph");
const c = @cImport({
    @cInclude("jack/jack.h");
    @cInclude("fftw3.h");
});

var param_mutex = std.Thread.Mutex{};
pub const Userdata = struct {
    const fm = 5; //fm *  jack buf_size = fft_bufsize
    output_port: *c.jack_port_t,
    sample_rate: usize,
    modfr: f32 = 1,
    modt: f32 = 0,
    t: f32 = 0,

    nvoice: usize = 16,
    spread: f32 = 0,

    voices: [8]Voice = [_]Voice{.{ .freq = 440, .amp = 0.5 }} ** 8,

    v1: Voice = .{ .freq = 440, .amp = 0.5 },
};

pub const Voice = struct {
    freq: f32 = 1,
    t: f32 = 0,
    amp: f32 = 0,
    phase: f32 = 0,
};

fn saw(theta: f32) f32 {
    const th = @mod(theta, std.math.tau) - std.math.pi;
    return th / std.math.pi;
}

pub export fn process(nframes: c.jack_nframes_t, arg: ?*anyopaque) c_int {
    const ud: *Userdata = @ptrCast(@alignCast(arg.?));
    const outbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.output_port, nframes).?));

    const sr: f32 = @floatFromInt(ud.sample_rate);
    const dt = 1.0 / sr;

    for (0..nframes) |si| {
        var out: f32 = 0;
        for (&ud.voices) |*vo| {
            out += vo.amp * saw(std.math.tau * vo.freq * vo.t + vo.phase);
            vo.t += dt;

            if (vo.t > 1.0 / vo.freq)
                vo.t = @mod(vo.t, 1.0 / vo.freq);
        }

        //const fr = freq;
        ////const fr = freq * (@sin(std.math.tau * ud.modfr * ud.modt) + 1);
        //const period = 1.0 / fr;
        //for (0..ud.nvoice) |nv| {
        //    //out += (0.5) * saw(std.math.tau * fr * ud.t + @as(f32, @floatFromInt(nv)) * period / 5);
        //    out += (0.5) * saw(std.math.tau * fr * ud.t + @as(f32, @floatFromInt(nv)) * period / 5);
        //}
        //outbuf[si] = out / @as(f32, @floatFromInt(ud.nvoice));
        outbuf[si] = out / @as(f32, @floatFromInt(ud.voices.len));

        //ud.t += 1.0 / sr;
        //ud.modt += 1.0 / sr;

        //if (ud.modt > 1.0 / ud.modfr)
        //    ud.modt = @mod(ud.modt, 1.0 / ud.modfr);

        //if (ud.t > period) {
        //    ud.t = @mod(ud.t, period);
        //}
    }

    return 0;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const client_name = "sinegen";

    //const system_in_regex = "PCM.*capture_FR";

    var status: c.jack_status_t = undefined;
    const client = c.jack_client_open(
        client_name,
        c.JackNullOption,
        &status,
    );
    if (client == null) {
        std.debug.print("client can't work\n", .{});
    }

    var userdata = Userdata{
        .output_port = c.jack_port_register(client, "output", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,
        .sample_rate = c.jack_get_sample_rate(client),
    };
    for (&userdata.voices, 0..) |*v, i| {
        const fi = @as(f32, @floatFromInt(i));
        v.phase = fi * 20.0 / 1000;

        v.freq += fi * 0;
    }
    _ = c.jack_set_process_callback(client, process, &userdata);

    _ = c.jack_connect(client, c.jack_port_name(userdata.output_port), "REAPER:in1");

    _ = c.jack_activate(client);

    var win = try graph.SDL.Window.createWindow("zig-game-engine", .{});
    defer win.destroyWindow();

    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/fonts/roboto.ttf", 30, win.getDpi(), .{});
    defer font.deinit();

    var draw = graph.ImmediateDrawingContext.init(alloc, win.getDpi());
    defer draw.deinit();

    while (!win.should_exit) {
        try draw.begin(0x3fbaeaff, win.screen_dimensions.toF());
        win.pumpEvents();
        {
            param_mutex.lock();
            defer param_mutex.unlock();
        }

        try draw.end(null);
        win.swap();
    }
}
