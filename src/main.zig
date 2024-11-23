const std = @import("std");
const graph = @import("graph");
const c = @cImport({
    @cInclude("jack/jack.h");
    @cInclude("fftw3.h");
});

const notes = [12][]const u8{ "A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#" };

var note_state: [12]f32 = [_]f32{0} ** 12;
var note_mutex = std.Thread.Mutex{};

pub const Userdata = struct {
    const fm = 5; //fm *  jack buf_size = fft_bufsize
    input_port: *c.jack_port_t,
    output_port: *c.jack_port_t,

    fft_in: []f32,
    fft_out: []c.fftwf_complex,
    plan: c.fftwf_plan,
    ftcount: u8 = 0,
};

pub fn fmag(a: [2]f32) f32 {
    return @sqrt(a[0] * a[0] + a[1] * a[1]);
}

var done = true;
pub export fn process(nframes: c.jack_nframes_t, arg: ?*anyopaque) c_int {
    const ud: *Userdata = @ptrCast(@alignCast(arg.?));
    const inbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.input_port, nframes).?));
    const outbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.output_port, nframes).?));
    @memcpy(outbuf[0..nframes], inbuf[0..nframes]);
    const offset = ud.ftcount * nframes;
    @memcpy(ud.fft_in[offset .. nframes + offset], inbuf[0..nframes]);

    //for (ud.fft_in[0..nframes]) |*it| {
    //    const in: f32 = std.math.pi * it.* / @as(f32, @floatFromInt(nframes));
    //    it.* = @sin(in) * @sin(in);
    //}
    ud.ftcount += 1;
    if (ud.ftcount == Userdata.fm) {
        ud.ftcount = 0;
        c.fftwf_execute(ud.plan);
        var max: f32 = 0;
        for (ud.fft_out) |item| {
            const mag = @sqrt(item[0] * item[0] + item[1] * item[1]);
            max = @floatCast(@max(mag, max));
        }
        //Algo
        //Step through discard any below thresh
        //find local maximums by storing prev and comparing
        //create list of 0-4 local maximums
        //do the funny average thing
        done = false;
        if (!done) {
            const si = 48000;
            const mag_thresh = 10;
            var last: f32 = 0;
            var last_inc: bool = false;
            const SI = struct {
                i: usize,
                mag: f32,
                pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
                    return lhs.mag < rhs.mag;
                }
            };
            var maxes: [5]SI = undefined;
            var max_i: usize = 0;
            for (ud.fft_out, 0..) |item, i| {
                const mag = @sqrt(item[0] * item[0] + item[1] * item[1]);

                if (mag > mag_thresh) {
                    if (mag < last) {
                        if (last_inc) {
                            if (max_i >= maxes.len)
                                break;
                            maxes[max_i] = .{ .i = i - 1, .mag = last }; // last starts as 0, mag can never be less, so index should never underflow
                            max_i += 1;
                        }
                        last_inc = false;
                        //last was a local max
                    } else {
                        last_inc = true;
                    }
                }
                last = mag;

                //std.debug.print("{d},{d}\n", .{ mag, freq });
                //if (mag > 1)
                //std.debug.print("{d:.2}:{d:.2},\t", .{ mag, freq });
                //if (i % 256 == 0)
                //    std.debug.print("\n", .{});
            }
            //const df = 1 / t;
            var printed = false;

            //t is the length of our window in seconds, num frames / sample rate
            const t: f32 = @as(f32, @floatFromInt(nframes * Userdata.fm)) / si;
            {
                const maxsort = maxes[0..max_i];
                std.sort.insertion(SI, maxsort, {}, SI.lessThan);
                note_mutex.lock();
                defer note_mutex.unlock();
                for (0..12) |i| {
                    note_state[i] = 0;
                }

                const cutoff = 10000;
                for (maxsort) |m| {
                    //Dividing the fft index by t gives us the frequency
                    const high = @as(f32, @floatFromInt(m.i)) / t;

                    // 12 tet freq from note: 440 * 2^(x/12)
                    //Convert frequency to a 12tet note number
                    const note_n = 12 * std.math.log2(high / 440.0);
                    if (@abs(note_n) < 10000 and high < cutoff) {
                        const note = @mod(@as(i32, @intFromFloat(@round(note_n))), 12);
                        note_state[@intCast(note)] = m.mag;

                        std.debug.print("i:{d} mag: {d:.2}f:{d:.2} {s} + {d:.2} cts\n", .{ m.i, m.mag, high, notes[@intCast(note)], note_n - @round(note_n) });
                    }
                }
            }
            if (false) {
                for (maxes[0..max_i]) |m| {
                    const high: f32 = @as(f32, @floatFromInt(m.i)) / t;
                    const note_n = 12 * std.math.log2(high / 440.0);
                    //n = 12 × log2(freq/440)
                    if (m.i == 0 or m.i == ud.fft_out.len - 1)
                        continue;

                    //const left = fmag(ud.fft_out[m - 1]);
                    //const center = fmag(ud.fft_out[m]);
                    //const right = fmag(ud.fft_out[m + 1]);

                    //const lmid = (center - left);
                    //const lh = @sqrt(lmid * lmid + df * df);

                    //const rmid = (center - right);
                    //const rh = @sqrt(rmid * rmid + df * df);

                    //const mi: f32 = @floatFromInt(m);
                    //const lav = (mi - 1) / t + (df * (lmid / lh));
                    //const rav = (mi + 1) / t - (df * (rmid / rh));
                    //const av = (lav + rav + mi / t) / 3;

                    const note = @mod(@as(i32, @intFromFloat(@round(note_n))), 12);

                    std.debug.print("{d:.2}\t {d:.1} st{d:.2} {s}\n", .{ fmag(ud.fft_out[m.i]), high, note_n, notes[@intCast(note)] });
                    printed = true;
                    //std.debug.print("{d},{d} {d} {d}, [{d}, {d}]\n", .{ high, av, lav, rav, (mi - 1) / t, (mi + 1) / t });
                }
            }
            if (printed)
                std.debug.print("\n", .{});
        }

        done = true;
    }
    //std.debug.print("{d}\n", .{max * @as(f32, @floatFromInt(nframes))});
    //std.debug.print("{d}\n", .{max});

    return 0;
}

//pub export fn synthProcess(nframes: c.jack_nframes_t, arg: ?*anyopaque) c_int{
//    const freq = 220;
//    const ud: *Userdata = @ptrCast(@alignCast(arg.?));
//    const inbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.input_port, nframes).?));
//    const outbuf: [*c]f32 = @ptrCast(@alignCast(c.jack_port_get_buffer(ud.output_port, nframes).?));
//}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const client_name = "fuckoff";

    //const system_in_regex = "PCM.*capture_FR";
    const system_in_regex = "Firefox.*3411";

    var status: c.jack_status_t = undefined;
    const client = c.jack_client_open(
        client_name,
        c.JackNullOption,
        &status,
    );
    if (client == null) {
        std.debug.print("client can't work\n", .{});
    }

    const buf_size = c.jack_get_buffer_size(client);

    var userdata = Userdata{
        .input_port = c.jack_port_register(client, "input", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsInput, 0) orelse return,
        .output_port = c.jack_port_register(client, "output", c.JACK_DEFAULT_AUDIO_TYPE, c.JackPortIsOutput, 0) orelse return,

        .fft_in = try alloc.alloc(f32, buf_size * Userdata.fm),
        .fft_out = try alloc.alloc(c.fftwf_complex, buf_size * Userdata.fm),
        .plan = undefined,
    };
    defer {
        alloc.free(userdata.fft_in);
        alloc.free(userdata.fft_out);
    }
    userdata.plan = c.fftwf_plan_dft_r2c_1d(@intCast(buf_size * Userdata.fm), @ptrCast(@alignCast(userdata.fft_in)), @ptrCast(@alignCast(userdata.fft_out)), c.FFTW_ESTIMATE);
    _ = c.jack_set_process_callback(client, process, &userdata);

    _ = c.jack_activate(client);

    var input: ?[*c]const u8 = null;
    { //TESTING CODE

        const name = c.jack_get_client_name(client);
        std.debug.print("client name: {s}\n", .{name});

        const pn = c.jack_port_name(userdata.input_port);
        std.debug.print("port name {s}\n", .{pn});

        const port_names = c.jack_get_ports(client, system_in_regex, null, 0);

        if (port_names != null) {
            var i: usize = 0;
            var port = port_names[i];
            while (port != null) : (port = port_names[i]) {
                i += 1;
                std.debug.print("Connecting matching input port: {s}\n", .{port});
                input = port;
                break;
            }
            //TODO free the stupid crappy jack memory pointer pointer string crap.
        }
        //c.jack_free();
    }
    if (input) |in| {
        switch (c.jack_connect(client, in, c.jack_port_name(userdata.input_port))) {
            0 => {},
            else => std.debug.print("Error connecting to {s}\n", .{in}),
        }
    }

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
            note_mutex.lock();
            defer note_mutex.unlock();
            var x: f32 = 0;
            const w = 100;
            for (note_state) |n| {
                if (n > 1) {
                    const alpha: u32 = @intFromFloat(std.math.clamp(0xff * (n / 30), 0, 0xff));
                    draw.rect(graph.Rec(x, 0, w, 100), 0xff00ff + alpha);
                }
                x += w;
            }
            for (0..12) |i| {
                const fi: f32 = @floatFromInt(i);

                draw.text(.{ .x = fi * w, .y = 0 }, notes[i], &font, 100, 0xffffffff);
            }
        }

        try draw.end(null);
        win.swap();
    }
}
