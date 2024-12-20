const std = @import("std");
const graph = @import("graph");
const c = @cImport({
    @cInclude("jack/jack.h");
    @cInclude("jack/midiport.h");
});
const Os9Gui = graph.gui_app.Os9Gui;
const NUM_OSC = 32;

fn ms(s: f32) f32 {
    return s / 1000;
}
var param_mutex = std.Thread.Mutex{};
const Param = struct {
    R: f32 = 1,
    fc: f32 = 500,

    bp: f32 = 0,
    lp: f32 = 0,
    hp: f32 = 0,

    delay_len: usize = 48000,

    kind: enum {
        bp,
        lp,
        hp,
    } = .bp,

    feedback: f32 = 0.5,
    wet: f32 = 1.0,
    dry: f32 = 1.0,
};
var params: Param = .{};

pub const Userdata = struct {
    const DELAY_MAX_LEN = 48000 * 4;
    const fm = 5; //fm *  jack buf_size = fft_bufsize

    param: Param = .{},
    input: *c.jack_port_t,
    output_port: *c.jack_port_t,
    debug_port: *c.jack_port_t,
    sample_rate: usize,
    amp: f32 = 0,
    fc: f32 = 0,

    dbuf: [DELAY_MAX_LEN]f32 = [_]f32{0} ** DELAY_MAX_LEN,
    delay_index: usize = 0,

    spread: f32 = 0,
    s: [2]f32 = undefined,

    prev: f32 = 0,
};

//Linear adsr

//fn square
//fn squareduty

pub export fn process(nframes: c.jack_nframes_t, arg: ?*anyopaque) c_int {
    const ud: *Userdata = @ptrCast(@alignCast(arg.?));

    const inbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.input, nframes).?));
    const outbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.output_port, nframes).?));

    const sr: f32 = @floatFromInt(ud.sample_rate);
    const dt = 1.0 / sr;
    if (param_mutex.tryLock()) {
        ud.param = params;
        defer param_mutex.unlock();
    }
    const fc = ud.param.fc;
    const g = fc * std.math.tau * dt / 2;
    const R = ud.param.R;
    const g1 = 2 * R + g;
    const d = 1 / (1 + 2 * R * g + std.math.pow(f32, g, 2));
    for (0..nframes) |si| {
        //only filter
        //We read an index earlier than write

        outbuf[si] = ud.dbuf[ud.delay_index] * ud.param.wet + inbuf[si] * ud.param.dry;
        //outbuf[si] = BP * ud.param.bp + HP * ud.param.hp + LP * ud.param.lp;
        //ud.dbuf[ud.delay_index] = inbuf[si] + outbuf[si] * feedback;

        const x = inbuf[si] + outbuf[si] * ud.param.feedback;
        const s1 = &ud.s[0];
        const s2 = &ud.s[1];
        const HP = (x - g1 * s1.* - s2.*) * d;
        const v1 = g * HP;
        const BP = v1 + s1.*;
        s1.* = BP + v1;
        const v2 = g * BP;
        const LP = v2 + s2.*;
        s2.* = LP + v2;

        ud.dbuf[ud.delay_index] = BP * ud.param.bp + HP * ud.param.hp + LP * ud.param.lp;

        ud.delay_index = (ud.delay_index + 1) % ud.param.delay_len;
    }
    for (ud.param.delay_len..Userdata.DELAY_MAX_LEN) |i| {
        ud.dbuf[i] = 0;
    }

    return 0;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const client_name = "delay";

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

    var userdata = Userdata{
        .input = c.jack_port_register(client, "input", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsInput, 0) orelse return,
        .output_port = c.jack_port_register(client, "output", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,
        .debug_port = c.jack_port_register(client, "debug", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,
        .sample_rate = c.jack_get_sample_rate(client),
    };
    _ = c.jack_set_process_callback(client, process, &userdata);
    _ = c.jack_activate(client);
    _ = c.jack_connect(client, c.jack_port_name(userdata.output_port), "REAPER:in1");
    _ = c.jack_connect(client, "sinegen:output", c.jack_port_name(userdata.input));

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
                    param_mutex.lock();
                    defer param_mutex.unlock();
                    os9gui.sliderEx(&params.R, 0.001, 1, "R {d:.2}", .{params.R});
                    os9gui.sliderEx(&params.fc, 100, 18000, "fc {d:.2}", .{params.fc});
                    os9gui.hr();
                    os9gui.sliderEx(&params.lp, -1, 1, "lp {d:.2}", .{params.lp});
                    os9gui.sliderEx(&params.bp, -1, 1, "bp {d:.2}", .{params.bp});
                    os9gui.sliderEx(&params.hp, -1, 1, "hp {d:.2}", .{params.hp});
                    os9gui.hr();
                    os9gui.sliderEx(&params.delay_len, 48000 / 1000, Userdata.DELAY_MAX_LEN, "delay len {d:.2}", .{params.delay_len});
                    os9gui.sliderEx(&params.feedback, 0, 1, "feedback {d:.2}", .{params.feedback});
                    os9gui.sliderEx(&params.wet, 0, 1, "wet {d:.2}", .{params.feedback});
                    os9gui.sliderEx(&params.dry, 0, 1, "dry {d:.2}", .{params.feedback});
                    try os9gui.radio(&params.kind);
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
