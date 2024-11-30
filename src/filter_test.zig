const std = @import("std");
const graph = @import("graph");
const sg = @import("sine_gen.zig");
const c = @cImport({
    @cInclude("clap/clap.h");
});
const Os9Gui = graph.gui_app.Os9Gui;

fn ms(s: f32) f32 {
    return s / 1000;
}

pub const Userdata = struct {
    sample_rate: usize,
    v: sg.Voice = .{ .freq = 440 },
};

//Linear adsr

//fn square
//fn squareduty

pub const Ports = struct {
    outbuf: [*c]f32,
};

pub const Plugin = struct {
    const NUM_OSC = 16;
    pub const ParamOutline = struct {
        name: [:0]const u8,
        min: f32 = 0,
        max: f32 = 1,
        default: f32 = 1,
    };
    const PARAMS = [_]ParamOutline{
        .{ .name = "octave", .max = 3, .min = -3 },
        .{ .name = "spread", .default = 0 },
        .{ .name = "resonance" },
        .{ .name = "frequency", .max = 20000, .default = 18000 },
        .{ .name = "amplitude", .default = 0.5 },
        .{ .name = "a", .default = 0.5, .min = 0.005, .max = 15 },
        .{ .name = "d", .default = 0.5, .min = 0.005, .max = 15 },
        .{ .name = "s", .default = 0.5, .min = 0, .max = 1 },
        .{ .name = "r", .default = 0.5, .min = 0.005, .max = 15 },
        .{ .name = "fa", .default = 0.5, .min = 0.005, .max = 15 },
        .{ .name = "fd", .default = 0.5, .min = 0.005, .max = 15 },
        .{ .name = "fs", .default = 0.5, .min = 0, .max = 1 },
        .{ .name = "fr", .default = 0.5, .min = 0.005, .max = 15 },
    };
    pub const param_ids = blk: {
        var enum_fields: [PARAMS.len]std.builtin.Type.EnumField = undefined;
        for (PARAMS, 0..) |p, i| {
            enum_fields[i] = .{
                .name = p.name,
                .value = i,
            };
        }
        break :blk @Type(.{ .Enum = .{ .tag_type = usize, .fields = &enum_fields, .decls = &.{}, .is_exhaustive = true } });
    };
    //pub const param_ids = enum(usize) {
    //    spread,
    //    octave,
    //    resonance,
    //    frequency,
    //    amplitude,
    //};
    const PARAMCOUNT = @typeInfo(param_ids).Enum.fields.len;

    plugin: c.clap_plugin_t,
    host: ?*const c.clap_host_t,
    ud: Userdata = .{},
    oscs: [NUM_OSC]sg.Osc = [_]sg.Osc{.{}} ** NUM_OSC,

    params: [PARAMCOUNT]f64,
    changed: [PARAMCOUNT]bool,

    pub fn getParam(self: *@This(), p: param_ids) f32 {
        return @floatCast(self.params[@intFromEnum(p)]);
    }
    pub fn process_generic(self: *@This(), start: usize, end: usize, ud: *Userdata, ports: Ports) void {
        const outbuf = ports.outbuf;

        const sr: f32 = @floatFromInt(ud.sample_rate);
        const dt = 1.0 / sr;
        const R = self.getParam(.resonance);
        const fc = self.getParam(.frequency);
        const gamp = self.getParam(.amplitude);
        for (start..end) |si| {
            var out: f32 = 0;
            for (&self.oscs) |*osc| {
                if (osc.adsr.state != .off) {
                    const amp = osc.adsr.getAmp(dt) * osc.vel;
                    var va: f32 = 0;
                    for (&osc.voices) |*v| {
                        va += v.getSample(dt, osc.wave);
                    }
                    const g = fc * std.math.tau * dt / 2 * osc.filter_adsr.getAmp(dt);
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
                    //out += va;
                    //Pass through this oscs filter

                    //out += amp * va / osc.voices.len;
                    //out = out / osc.voices.len;
                }
            }
            out *= gamp;
            //alpha = tau *dt * fc / (tau dt fc + 1)
            //y[i] = y[i-1] + alpha * (out - y[i-1])
            outbuf[si] = out;
        }
    }

    pub fn processEvent(self: *@This(), event: *const c.clap_event_header_t) void {
        if (event.space_id == c.CLAP_CORE_EVENT_SPACE_ID) {
            switch (event.type) {
                c.CLAP_EVENT_NOTE_ON, c.CLAP_EVENT_NOTE_OFF, c.CLAP_EVENT_NOTE_CHOKE => {
                    const note_event: *const c.clap_event_note_t = @ptrCast(@alignCast(event));
                    for (&self.oscs) |*osc| {
                        //-1 wildcard
                        if ((note_event.key == -1 or note_event.key == osc.note) and (note_event.note_id == -1 or osc.noteID == note_event.note_id)) {
                            if (event.type == c.CLAP_EVENT_NOTE_CHOKE) {
                                osc.adsr.state = .off;
                            } else {
                                osc.adsr.untrigger();
                                osc.filter_adsr.untrigger();
                            }
                        }
                    }

                    if (event.type == c.CLAP_EVENT_NOTE_ON) {
                        for (&self.oscs) |*osc| {
                            if (osc.adsr.state == .off) {
                                std.debug.print("turning note on\n", .{});
                                osc.adsr.a = self.getParam(.a);
                                osc.adsr.d = self.getParam(.d);
                                osc.adsr.s = self.getParam(.s);
                                osc.adsr.r = self.getParam(.r);
                                osc.filter_adsr.a = self.getParam(.fa);
                                osc.filter_adsr.d = self.getParam(.fd);
                                osc.filter_adsr.s = self.getParam(.fs);
                                osc.filter_adsr.r = self.getParam(.fr);
                                osc.adsr.trigger();
                                osc.filter_adsr.trigger();
                                osc.note = @intCast(note_event.key);
                                osc.noteID = note_event.note_id;
                                osc.vel = @floatCast(note_event.velocity);
                                osc.pitch = 440.0 * std.math.pow(
                                    f32,
                                    2,
                                    (@as(f32, @floatFromInt(osc.note)) - 69 + 12 * self.getParam(.octave)) / 12,
                                );
                                for (&osc.voices, 0..) |*v, i| {
                                    //v.freq = osc.pitch + spread * @as(f32, @floatFromInt(i)) * (440 / osc.pitch);

                                    v.freq = osc.pitch * (1 + @as(f32, @floatFromInt(i)) * self.getParam(.spread));
                                }
                                break;
                            }
                        }
                    }
                },
                c.CLAP_EVENT_PARAM_VALUE => {
                    const pv: *const c.clap_event_param_value_t = @ptrCast(@alignCast(event));
                    const id = pv.param_id;
                    self.params[id] = pv.value;
                },
                else => {},
            }
        }
    }
};

var global_plugin: Plugin = undefined;

pub const Extension = struct {
    var stringbuff: [256]u8 = undefined;
    export fn ext_count(_: PT) u32 {
        return Plugin.PARAMCOUNT;
    }

    export fn ext_get_info(_: PT, index: u32, info: ?*c.clap_param_info_t) bool {
        if (index >= Plugin.PARAMCOUNT)
            return false;
        const inf = Plugin.PARAMS[index];
        const in = info.?;
        in.* = std.mem.zeroes(c.clap_param_info_t);
        in.id = index;
        in.flags = 0;
        in.min_value = inf.min;
        in.max_value = inf.max;
        in.default_value = inf.default;
        const str = @tagName(@as(Plugin.param_ids, @enumFromInt(index)));
        @memcpy(in.name[0..str.len], str);
        in.name[str.len] = 0;

        return true;
    }

    export fn ext_get_value(_p: PT, id: c.clap_id, value: ?*f64) bool {
        const p: *Plugin = @ptrCast(@alignCast(_p[0].plugin_data));
        if (id < Plugin.PARAMCOUNT) {
            value.?.* = p.params[id];
            return true;
        }
        return false;
    }

    export fn ext_value_to_text(_: PT, id: c.clap_id, value: f64, display: [*c]u8, len: u32) bool {
        var fbs = std.io.FixedBufferStream([]u8){ .pos = 0, .buffer = &stringbuff };
        fbs.writer().print("{d:.2}", .{value}) catch return false;
        const slice = fbs.getWritten();
        const slen = @min(slice.len, len);
        @memcpy(display[0..slen], slice[0..slen]);
        display[slen] = 0;
        _ = id;
        return true;
    }

    export fn ext_text_to_value(_: PT, _: c.clap_id, value_text: [*c]const u8, out: [*c]f64) bool {
        out[0] = std.fmt.parseFloat(f64, std.mem.span(value_text)) catch return false;

        return true;
    }

    export fn ext_flush(_: PT, _: [*c]const c.clap_input_events_t, _: [*c]const c.clap_output_events_t) void {}
};
export const ExtensionParams = c.clap_plugin_params_t{
    .count = Extension.ext_count,
    .get_info = Extension.ext_get_info,
    .get_value = Extension.ext_get_value,
    .value_to_text = Extension.ext_value_to_text,
    .flush = null,
    .text_to_value = Extension.ext_text_to_value,
};

const PT = [*c]const c.clap_plugin_t;
const PluginClass = struct {
    const P = [*c]const c.clap_plugin;
    export fn pc_init(_p: P) bool {
        const p: *Plugin = @ptrCast(@alignCast(_p[0].plugin_data));
        for (0..Plugin.PARAMCOUNT) |pi| {
            p.params[pi] = Plugin.PARAMS[pi].default;
        }
        return true;
    }

    export fn pc_destroy(_: P) void {}

    export fn pc_activate(_p: P, sample_rate: f64, minframecount: u32, maxframecount: u32) bool {
        const p: *Plugin = @ptrCast(@alignCast(_p[0].plugin_data));
        p.ud.sample_rate = @intFromFloat(sample_rate);
        for (&p.oscs) |*o| {
            o.adsr.state = .off;
        }
        p.ud.v.freq = 220;
        _ = minframecount;
        _ = maxframecount;
        return true;
    }

    export fn pc_deactivate(_: P) void {}
    export fn pc_start_processing(_: P) bool {
        return true;
    }
    export fn pc_stop_processing(_: P) void {}
    export fn pc_reset(_: P) void {}

    export fn pc_process(p: P, _proc: [*c]const c.clap_process_t) c.clap_process_status {
        const proc = _proc[0];
        const pl = @as(*Plugin, @ptrCast(@alignCast(p[0].plugin_data)));
        if (proc.audio_outputs[0].data32 == 0 or proc.audio_outputs[0].channel_count != 1) {
            return c.CLAP_PROCESS_ERROR;
        }

        const num_event = proc.in_events[0].size.?(proc.in_events);
        var next_event_frame = if (num_event > 0) 0 else proc.frames_count;
        var event_i: usize = 0;
        var si: usize = 0;
        while (si < proc.frames_count) {
            while (event_i < num_event and next_event_frame == si) {
                const event = proc.in_events[0].get.?(proc.in_events, @intCast(event_i));
                if (event.*.time != si) {
                    next_event_frame = event.*.time;
                    break;
                }

                pl.processEvent(event);
                event_i += 1;
                if (event_i == num_event) {
                    next_event_frame = proc.frames_count;
                    break;
                }
            }

            pl.process_generic(si, next_event_frame, &pl.ud, .{
                .outbuf = proc.audio_outputs[0].data32[0],
            });
            si = next_event_frame;
        }

        return c.CLAP_PROCESS_CONTINUE;
    }

    export fn pc_get_extension(_: P, id: [*c]const u8) ?*const anyopaque {
        const sid = std.mem.span(id);
        if (std.mem.eql(u8, sid, &c.CLAP_EXT_NOTE_PORTS)) {
            return &extensionNotePorts;
        } else if (std.mem.eql(u8, sid, &c.CLAP_EXT_PARAMS)) {
            return &ExtensionParams;
        } else if (std.mem.eql(u8, sid, &c.CLAP_EXT_AUDIO_PORTS)) {
            return &extensionAudioPorts;
        }
        return null;
    }

    export fn pc_audio_port_count(_: PT, input: bool) u32 {
        if (input) {
            return 0;
        }
        return 1;
    }

    export fn pc_audio_port_get(_: PT, index: u32, input: bool, info: [*c]c.clap_audio_port_info_t) bool {
        if (input)
            return false;
        info[0].id = index;
        info[0].channel_count = 1;
        info[0].flags = c.CLAP_AUDIO_PORT_IS_MAIN;
        info[0].port_type = &c.CLAP_PORT_MONO;
        info[0].in_place_pair = c.CLAP_INVALID_ID;
        @memcpy(info[0].name[0..4], "crap");
        info[0].name[4] = 0;
        //info[0].name = @as([256]u8, "crap");
        return true;
    }

    export fn pc_on_main_thread(_: PT) void {}

    export fn pc_note_port_count(_: PT, input: bool) u32 {
        if (input)
            return 1;
        return 0;
    }
    export fn pc_note_port_get(_: PT, index: u32, input: bool, info: [*c]c.clap_note_port_info_t) bool {
        if (!input)
            return false;
        const in = &info[0];
        in.id = index;
        in.supported_dialects = c.CLAP_NOTE_DIALECT_CLAP;
        in.preferred_dialect = c.CLAP_NOTE_DIALECT_CLAP;
        const name = "note_in";
        @memcpy(in.name[0..name.len], name);
        in.name[name.len] = 0;
        return true;
    }

    export const extensionAudioPorts = c.clap_plugin_audio_ports_t{
        .count = pc_audio_port_count,
        .get = pc_audio_port_get,
    };

    export const extensionNotePorts = c.clap_plugin_note_ports_t{
        .count = pc_note_port_count,
        .get = pc_note_port_get,
    };

    export const pluginClass = c.clap_plugin_t{
        .desc = &ClapExport.pluginDescriptor,
        .plugin_data = null,
        .init = pc_init,
        .destroy = pc_destroy,
        .activate = pc_activate,
        .deactivate = pc_deactivate,
        .start_processing = pc_start_processing,
        .stop_processing = pc_stop_processing,
        .reset = pc_reset,
        .process = pc_process,
        .get_extension = pc_get_extension,
        .on_main_thread = pc_on_main_thread,
    };
};

pub const ClapExport = struct {
    pub const pluginDescriptor = c.clap_plugin_descriptor_t{
        .clap_version = c.CLAP_VERSION,
        .id = "nmalthouse.filterTest",
        .name = "test Plugin",
        .vendor = "nmalthouse",
        .description = "test plugin",
        .features = &[_][*c]const u8{
            c.CLAP_PLUGIN_FEATURE_INSTRUMENT,
            c.CLAP_PLUGIN_FEATURE_SYNTHESIZER,
            null,
        },
        .url = null,
        .manual_url = null,
        .support_url = null,
        .version = null,
    };
    export fn init(plugin_path: [*c]const u8) bool {
        _ = plugin_path;
        return true;
    }

    export fn deinit() void {}

    export fn getFactory(factory_id: [*c]const u8) ?*const anyopaque {
        const fid = std.mem.span(factory_id);
        return if (std.mem.eql(u8, fid, &c.CLAP_PLUGIN_FACTORY_ID)) @ptrCast(&plugin_factory) else null;
    }

    export fn pluginCount(factory: ?*const c.clap_plugin_factory) u32 {
        _ = factory;
        return 1;
    }

    export fn getPluginDescriptor(factory: ?*const c.clap_plugin_factory, index: u32) ?*const c.clap_plugin_descriptor_t {
        _ = factory;
        return if (index == 0) &pluginDescriptor else null;
    }

    export fn createPlugin(factory: ?*const c.clap_plugin_factory, host: ?*const c.clap_host_t, plugin_id: [*c]const u8) ?*const c.clap_plugin_t {
        if (!c.clap_version_is_compatible(host.?.clap_version) or !std.mem.eql(u8, std.mem.span(plugin_id), std.mem.span(pluginDescriptor.id))) {
            return null;
        }
        _ = factory;
        global_plugin.host = host;
        global_plugin.plugin = PluginClass.pluginClass;
        global_plugin.plugin.plugin_data = &global_plugin;
        return &global_plugin.plugin;
    }

    export const plugin_factory = c.clap_plugin_factory_t{
        .get_plugin_count = pluginCount,
        .get_plugin_descriptor = getPluginDescriptor,

        .create_plugin = createPlugin,
    };
};

export const clap_entry = c.clap_plugin_entry_t{
    .clap_version = c.CLAP_VERSION,
    .init = ClapExport.init,
    .deinit = ClapExport.deinit,
    .get_factory = ClapExport.getFactory,
};
