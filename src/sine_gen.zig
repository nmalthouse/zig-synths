const std = @import("std");
const graph = @import("graph");
const c = @cImport({
    @cInclude("jack/jack.h");
    @cInclude("jack/midiport.h");
    @cInclude("fftw3.h");
});
const Os9Gui = graph.gui_app.Os9Gui;
const NUM_OSC = 16;

fn ms(s: f32) f32 {
    return s / 1000;
}

var param_mutex = std.Thread.Mutex{};
const Param = struct {
    spread: f32 = 0,
    phase: f32 = 0,
    octave: i32 = 0,
    freq: f32 = 440,
    amp: f32 = 0.2,
    fc: f32 = 5000,
    R: f32 = 1,

    m_adsr: Envelope = .{},
    f_adsr: Envelope = .{},

    wave1: Osc.Waveform = .w_saw,
};
var params: Param = .{};
pub const Userdata = struct {
    const fm = 5; //fm *  jack buf_size = fft_bufsize

    param: Param = .{},

    midi_in: *c.jack_port_t,
    output_port: *c.jack_port_t,
    debug_port: *c.jack_port_t,
    sample_rate: usize,
    amp: f32 = 0,
    fc: f32 = 0,

    spread: f32 = 0,

    oscs: [NUM_OSC]Osc = [_]Osc{.{}} ** NUM_OSC,

    prev: f32 = 0,

    R: f32 = 1,
};

//Linear adsr
pub const Envelope = struct {
    pub const State = enum {
        attack,
        decay,
        sustain,
        release,
        off,
    };
    a: f32 = ms(10),
    d: f32 = ms(1),
    s: f32 = 1,
    r: f32 = ms(50),

    state: State = .off,
    t: f32 = 0,

    pub fn trigger(self: *@This()) void {
        self.t = 0;
        self.state = .attack;
    }

    pub fn untrigger(self: *@This()) void {
        if (self.state == .release or self.state == .off)
            return;
        self.state = .release;
        self.t = 0;
    }

    pub fn tryAdv(self: *@This(), current: f32, next: State) void {
        if (self.t > current) {
            self.t = 0;
            self.state = next;
        }
    }

    pub fn getAmp(self: *@This(), dt: f32) f32 {
        switch (self.state) {
            .attack => self.tryAdv(self.a, .decay),
            .decay => self.tryAdv(self.d, .sustain),
            .sustain => {},
            .release => self.tryAdv(self.r, .off),
            .off => return 0,
        }
        const val = switch (self.state) {
            .off => return 0,
            .attack => self.t / self.a,
            .decay => self.t * (self.s - 1) / self.d + 1,
            .sustain => self.s,
            .release => -self.s * self.t / self.r + self.s,
        };

        self.t += dt;
        return val;
    }
};

pub const Osc = struct {
    const num_voice = 3;
    pub const Waveform = enum(u8) {
        w_sin,
        w_saw,
        w_square,

        pub fn fun(self: @This(), th: f32) f32 {
            return switch (self) {
                .w_sin => sin(th),
                .w_saw => saw(th),
                .w_square => square(th),
            };
        }
    };

    vel: f32 = 1,
    note: u8 = 0,
    pitch: f32 = 1,

    voices: [num_voice]Voice = [_]Voice{.{}} ** num_voice,
    wave: Waveform = .w_saw,

    adsr: Envelope = .{},
    filter_adsr: Envelope = .{},

    filter_state: [2]f32 = undefined,
};

pub const Voice = struct {
    freq: f32 = 1,
    t: f32 = 0,
    phase: f32 = 0,

    pub fn getSample(vo: *@This(), dt: f32, wave: Osc.Waveform) f32 {
        const out = wave.fun(std.math.tau * vo.freq * vo.t + vo.phase);
        vo.t += dt;

        if (vo.t > 1.0 / vo.freq)
            vo.t = @mod(vo.t, 1.0 / vo.freq);
        return out;
    }
};

fn sin(th: f32) f32 {
    return @sin(th);
}

fn saw(theta: f32) f32 {
    const th = @mod(theta, std.math.tau) - std.math.pi;
    return th / std.math.pi;
}

fn square(theta: f32) f32 {
    const th = @mod(theta, std.math.tau);
    if (th >= std.math.pi)
        return -1;
    return 1;
}

fn squareDC(theta: f32, duty: f32) f32 {
    const th = @mod(theta, std.math.tau);
    if (th > std.math.tau * duty)
        return -1;
    return 1;
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
    const dbgbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.debug_port, nframes).?));

    const sr: f32 = @floatFromInt(ud.sample_rate);
    const dt = 1.0 / sr;

    if (param_mutex.tryLock()) {
        defer param_mutex.unlock();
        ud.param = params;
        ud.spread = params.spread;
        ud.fc = params.fc;
        ud.R = params.R;
        ud.amp = params.amp;
        for (&ud.oscs) |*osc| {
            osc.wave = params.wave1;
            osc.adsr.a = params.m_adsr.a;
            osc.adsr.d = params.m_adsr.d;
            osc.adsr.s = params.m_adsr.s;
            osc.adsr.r = params.m_adsr.r;

            osc.filter_adsr.a = params.f_adsr.a;
            osc.filter_adsr.d = params.f_adsr.d;
            osc.filter_adsr.s = params.f_adsr.s;
            osc.filter_adsr.r = params.f_adsr.r;
        }
    }

    //const alpha = std.math.tau * dt * ud.fc / (std.math.tau * dt * ud.fc + 1);

    //const G = g / (g + 1);

    //const w1: f32 = 200 * std.math.tau;
    //const w2: f32 = 200 * std.math.tau;
    const R = ud.R;
    //const R = (w1 + w2) / (2 * @sqrt(w1 * w2));

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
                                    osc.adsr.untrigger();
                                    osc.filter_adsr.untrigger();
                                }
                            }
                        },
                        .note_on => {
                            for (&ud.oscs) |*osc| {
                                if (osc.adsr.state == .off) {
                                    osc.adsr.trigger();
                                    osc.filter_adsr.trigger();
                                    osc.note = me.buffer[1];
                                    osc.vel = 128.0 / @as(f32, @floatFromInt(me.buffer[2]));
                                    osc.pitch = 440.0 * std.math.pow(
                                        f32,
                                        2,
                                        (@as(f32, @floatFromInt(osc.note)) - 69 + @as(f32, @floatFromInt(12 * ud.param.octave))) / 12,
                                    );
                                    for (&osc.voices, 0..) |*v, i| {
                                        //v.freq = osc.pitch + spread * @as(f32, @floatFromInt(i)) * (440 / osc.pitch);

                                        v.freq = osc.pitch * (1 + @as(f32, @floatFromInt(i)) * ud.spread);
                                    }
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
        for (&ud.oscs) |*osc| {
            if (osc.adsr.state != .off) {
                const amp = osc.adsr.getAmp(dt) * osc.vel;
                var va: f32 = 0;
                for (&osc.voices) |*v| {
                    va += v.getSample(dt, osc.wave);
                }
                const g = ud.fc * std.math.tau * dt / 2 * osc.filter_adsr.getAmp(dt);
                const g1 = 2 * R + g;
                const d = 1 / (1 + 2 * R * g + std.math.pow(f32, g, 2));
                const x = amp * va / osc.voices.len;
                const s1 = &osc.filter_state[0];
                const s2 = &osc.filter_state[1];
                const HP = (x - g1 * s1.* - s2.*) * d;
                const v1 = g * HP;
                const BP = v1 + s1.*;
                s1.* = BP + v1;
                const v2 = g * BP;
                const LP = v2 + s2.*;
                s2.* = LP + v2;
                out += LP;
                //Pass through this oscs filter

                //out += amp * va / osc.voices.len;
                //out = out / osc.voices.len;
            }
        }
        out *= ud.amp;
        //alpha = tau *dt * fc / (tau dt fc + 1)
        //y[i] = y[i-1] + alpha * (out - y[i-1])
        dbgbuf[si] = out;
        outbuf[si] = out;
        //outbuf[si] = (ud.prev + alpha * (out - ud.prev));

        //outbuf[si] = beta * ud.prev + (1 - beta) * out;
        //ud.prev = outbuf[si];
    }

    return 0;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const client_name = "sinegen";

    //var xosh = std.rand.DefaultPrng.init(0);
    //const rand = xosh.random();
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

    blk: {
        const inf = std.fs.cwd().openFile("params.json", .{}) catch break :blk;
        const sl = try inf.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(sl);
        const parsed = try std.json.parseFromSlice(Param, alloc, sl, .{});
        params = parsed.value;
        parsed.deinit();
    }

    var userdata = Userdata{
        .midi_in = c.jack_port_register(client, "mid_in", c.JACK_DEFAULT_MIDI_TYPE, c.JackPortIsInput, 0) orelse return,
        .output_port = c.jack_port_register(client, "output", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,
        .debug_port = c.jack_port_register(client, "debug", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,
        .sample_rate = c.jack_get_sample_rate(client),
    };
    _ = c.jack_set_process_callback(client, process, &userdata);

    //_ = c.jack_connect(client, c.jack_port_name(userdata.output_port), "REAPER:in1");
    _ = c.jack_connect(client, c.jack_port_name(userdata.output_port), "delay:input");
    _ = c.jack_connect(client, c.jack_port_name(userdata.debug_port), "REAPER:in2");
    _ = c.jack_connect(client, "REAPER:MIDI Output 3", c.jack_port_name(userdata.midi_in));

    _ = c.jack_activate(client);

    const do_gui = true;
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
                    const b = 0.01;
                    param_mutex.lock();
                    defer param_mutex.unlock();
                    os9gui.sliderLog(&params.spread, 0, 1, "spread {d:.2}", .{params.spread * 100}, b);
                    os9gui.sliderEx(&params.amp, 0, 0.5, "amp {d:.2}", .{params.amp});
                    os9gui.sliderEx(&params.octave, -3, 3, "oct {d}", .{params.octave});
                    os9gui.hr();

                    os9gui.sliderLog(&params.m_adsr.a, 0.005, 15, "att {d:.2}", .{params.m_adsr.a * 1000}, b);
                    os9gui.sliderLog(&params.m_adsr.d, 0.005, 15, "dec {d:.2}", .{params.m_adsr.d * 1000}, b);
                    os9gui.sliderEx(&params.m_adsr.s, 0.0, 1, "sus {d:.2}", .{params.m_adsr.s});
                    os9gui.sliderLog(&params.m_adsr.r, 0.005, 15, "rel {d:.2}", .{params.m_adsr.r * 1000}, b);
                    os9gui.hr();
                    os9gui.label("Filter: ", .{});
                    os9gui.sliderLog(&params.f_adsr.a, 0.005, 15, "att {d:.2}", .{params.f_adsr.a * 1000}, b);
                    os9gui.sliderLog(&params.f_adsr.d, 0.005, 15, "dec {d:.2}", .{params.f_adsr.d * 1000}, b);
                    os9gui.sliderEx(&params.f_adsr.s, 0.0, 1, "sus {d:.2}", .{params.f_adsr.s});
                    os9gui.sliderLog(&params.f_adsr.r, 0.005, 15, "rel {d:.2}", .{params.f_adsr.r * 1000}, b);
                    os9gui.hr();
                    os9gui.sliderEx(&params.fc, 100, 18000, "fc {d:.2}", .{params.fc});
                    os9gui.sliderEx(&params.R, 0, 1, "R {d:.2}", .{params.R});
                    try os9gui.radio(&params.wave1);
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

    {
        var outf = try std.fs.cwd().createFile("params.json", .{});
        try std.json.stringify(params, .{}, outf.writer());
        outf.close();
    }
}
