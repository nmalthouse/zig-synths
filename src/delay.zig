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

pub const Userdata = struct {
    const delay_len = 48000 * 2;
    const fm = 5; //fm *  jack buf_size = fft_bufsize

    input: *c.jack_port_t,
    output_port: *c.jack_port_t,
    debug_port: *c.jack_port_t,
    sample_rate: usize,
    amp: f32 = 0,
    fc: f32 = 0,

    dbuf: [delay_len]f32 = [_]f32{0} ** delay_len,
    delay_index: usize = 0,

    spread: f32 = 0,

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
    for (0..nframes) |si| {
        outbuf[si] = ud.dbuf[ud.delay_index];
        ud.dbuf[ud.delay_index] = inbuf[si] + outbuf[si] * 0.5;
        //We read an index earlier than write

        ud.delay_index = (ud.delay_index + 1) % ud.dbuf.len;
    }

    _ = dt;

    return 0;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const client_name = "delay";
    _ = alloc;

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
    _ = c.jack_connect(client, "REAPER:out3", c.jack_port_name(userdata.input));

    const stdin = std.io.getStdIn();
    while (true) {
        _ = try stdin.reader().readByte();
    }
}
