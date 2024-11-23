const std = @import("std");
const graph = @import("graph");
const c = @cImport({
    @cInclude("jack/jack.h");
    @cInclude("jack/midiport.h");
    @cInclude("fftw3.h");
});
const Os9Gui = graph.gui_app.Os9Gui;

var param_mutex = std.Thread.Mutex{};
const Param = struct {
    spread: f32 = 0,
    phase: f32 = 0,
    freq: f32 = 440,
    amp: f32 = 0.2,
};
var params: Param = .{};
pub const Userdata = struct {
    const fm = 5; //fm *  jack buf_size = fft_bufsize

    midi_in: *c.jack_port_t,
    output_port: *c.jack_port_t,
    sample_rate: usize,
    modfr: f32 = 1,
    modt: f32 = 0,
    t: f32 = 0,

    nvoice: usize = 16,
    spread: f32 = 0,

    voices: [16]Voice = [_]Voice{.{ .freq = 440, .amp = 0.5 }} ** 16,

    v1: Voice = .{ .freq = 440, .amp = 0.5 },

    oscs: [4]Osc = [_]Osc{.{}} ** 4,
};

pub const Osc = struct {
    note: u8 = 0,
    pitch: f32 = 1,
    voice: Voice = .{},
    active: bool = false,
};

pub const Voice = struct {
    freq: f32 = 1,
    t: f32 = 0,
    amp: f32 = 0.5,
    phase: f32 = 0,

    pub fn getSample(vo: *@This(), dt: f32) f32 {
        const out = vo.amp * saw(std.math.tau * vo.freq * vo.t + vo.phase);
        vo.t += dt;

        if (vo.t > 1.0 / vo.freq)
            vo.t = @mod(vo.t, 1.0 / vo.freq);
        return out;
    }
};

fn saw(theta: f32) f32 {
    const th = @mod(theta, std.math.tau) - std.math.pi;
    return th / std.math.pi;
}

//fn square
//fn squareduty

pub export fn process(nframes: c.jack_nframes_t, arg: ?*anyopaque) c_int {
    const ud: *Userdata = @ptrCast(@alignCast(arg.?));

    const mid_buf: [*c]u8 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.midi_in, nframes).?));
    const num_midi = c.jack_midi_get_event_count(mid_buf);
    var midi_index: usize = 0; //Index into mid_buf
    var mid_event: ?c.jack_midi_event_t = .{};
    if (midi_index >= num_midi or c.jack_midi_event_get(&mid_event.?, mid_buf, @intCast(midi_index)) != 0)
        mid_event = null;
    midi_index += 1;

    const outbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.output_port, nframes).?));

    const sr: f32 = @floatFromInt(ud.sample_rate);
    const dt = 1.0 / sr;

    if (param_mutex.tryLock()) {
        defer param_mutex.unlock();
        for (&ud.voices, 0..) |*v, i| {
            const fi = @as(f32, @floatFromInt(i));
            //v.phase = fi * params.phase;

            v.freq = params.freq + fi * params.spread;
            v.amp = params.amp;
        }
    }

    for (0..nframes) |si| {
        while (mid_event != null and mid_event.?.time >= si) {
            const me = &mid_event.?;
            switch (me.size) {
                3 => {
                    const ev = me.buffer[0];
                    const hi = ev >> 4;
                    const Msg = enum(u8) {
                        note_off = 0x8,
                        note_on = 0x9,
                        _,
                    };
                    switch (@as(Msg, @enumFromInt(hi))) {
                        .note_off => {
                            for (&ud.oscs) |*osc| {
                                if (osc.note == me.buffer[1]) {
                                    osc.active = false;
                                }
                            }
                        },
                        .note_on => {
                            for (&ud.oscs) |*osc| {
                                if (!osc.active) {
                                    osc.active = true;
                                    osc.note = me.buffer[1];
                                    osc.pitch = 440.0 * std.math.pow(f32, 2, (@as(f32, @floatFromInt(osc.note)) - 69) / 12);
                                    osc.voice.freq = osc.pitch;
                                    break;
                                }
                            }

                            // 440 * 2^(x/12) //shift x right by 69 as midi 69: 440hz
                        },
                        _ => {},
                    }
                },
                else => {},
            }
            if (midi_index >= num_midi or c.jack_midi_event_get(&mid_event.?, mid_buf, @intCast(midi_index)) != 0)
                mid_event = null;
            midi_index += 1;
        }
        var out: f32 = 0;
        var num_active: f32 = 0.001;
        for (&ud.oscs) |*osc| {
            if (osc.active) {
                out += osc.voice.getSample(dt);
                num_active += 1;
            }
        }
        outbuf[si] = out / num_active;
        //for (&ud.voices) |*vo| {
        //    out += vo.amp * saw(std.math.tau * vo.freq * vo.t + vo.phase);
        //    vo.t += dt;

        //    if (vo.t > 1.0 / vo.freq)
        //        vo.t = @mod(vo.t, 1.0 / vo.freq);
        //}
        //outbuf[si] = out / @as(f32, @floatFromInt(ud.voices.len));
    }

    return 0;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const client_name = "sinegen";

    var xosh = std.rand.DefaultPrng.init(0);
    const rand = xosh.random();
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
        .midi_in = c.jack_port_register(client, "mid_in", c.JACK_DEFAULT_MIDI_TYPE, c.JackPortIsInput, 0) orelse return,
        .output_port = c.jack_port_register(client, "output", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,
        .sample_rate = c.jack_get_sample_rate(client),
    };
    for (&userdata.voices, 0..) |*v, i| {
        const fi = @as(f32, @floatFromInt(i));
        v.phase = rand.float(f32);
        //v.phase = fi * 20.0 / 1000;

        v.freq += fi * 0;
    }
    _ = c.jack_set_process_callback(client, process, &userdata);

    _ = c.jack_connect(client, c.jack_port_name(userdata.output_port), "REAPER:in1");
    _ = c.jack_connect(client, "REAPER:MIDI Output 3", c.jack_port_name(userdata.midi_in));

    _ = c.jack_activate(client);

    const do_gui = false;
    if (do_gui) {
        var win = try graph.SDL.Window.createWindow("zig-game-engine", .{});
        defer win.destroyWindow();

        var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/fonts/roboto.ttf", 30, win.getDpi(), .{});
        defer font.deinit();

        var draw = graph.ImmediateDrawingContext.init(alloc, win.getDpi());
        defer draw.deinit();

        var os9gui = try Os9Gui.init(alloc, try std.fs.cwd().openDir("ratgraph", .{}), 2);
        defer os9gui.deinit();

        while (!win.should_exit) {
            try draw.begin(0x3fbaeaff, win.screen_dimensions.toF());
            win.pumpEvents();
            const is: graph.Gui.InputState = .{
                .mouse = win.mouse,
                .key_state = &win.key_state,
                .keys = win.keys.slice(),
                .mod_state = win.mod,
            };
            try os9gui.beginFrame(is, &win);
            if (try os9gui.beginTlWindow(graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y))) {
                defer os9gui.endTlWindow();
                _ = try os9gui.beginV();
                defer os9gui.endL();
                _ = os9gui.button("hello");

                {
                    param_mutex.lock();
                    defer param_mutex.unlock();
                    os9gui.sliderEx(&params.spread, 0, 100, "spread {d:.2}", .{params.spread});
                    os9gui.sliderEx(&params.spread, 0, 0.5, "spread {d:.2}", .{params.spread});
                    //os9gui.sliderEx(&params.spread, params.spread - 1, params.spread + 1, "spread {d:.2}", .{params.spread});
                    os9gui.sliderEx(&params.phase, 0, 10, "phase {d:.2}", .{params.phase});
                    os9gui.sliderEx(&params.freq, 100, 440, "freq {d:.2}", .{params.freq});
                    os9gui.sliderEx(&params.amp, 0, 0.5, "amp {d:.2}", .{params.amp});
                }
            }
            try os9gui.endFrame(&draw);

            try draw.end(null);
            win.swap();
        }
    } else {
        const stdin = std.io.getStdIn();
        while (true) {
            _ = try stdin.reader().readByte();
        }
    }
}
