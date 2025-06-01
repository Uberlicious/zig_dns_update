const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const AsusRouter = struct {
    arena: Allocator,
    arena_allocator: ArenaAllocator, 
    ip: []const u8,
    token_header: []const u8 = undefined,

    pub fn init(allocator: Allocator, ip: []const u8) AsusRouter {
        var arena_allocator = std.heap.ArenaAllocator.init(allocator);
        const arena = arena_allocator.allocator();

        return AsusRouter{ 
            .arena = arena,
            .arena_allocator = arena_allocator,
            .ip = ip,
        };
    }

    pub fn deinit(self: AsusRouter) void {
        self.arena_allocator.deinit();
    }

    pub fn login(self: *AsusRouter, user: []const u8, password: []const u8) !void {
        var client: std.http.Client = .{ .allocator = self.arena };
        defer client.deinit();

        const headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        };
    
        const referer = try std.fmt.allocPrint(self.arena, "http://{s}/Main_login.asp", .{self.ip});
        const extraHeaders: []const std.http.Header = &.{
            .{ .name = "Referer", .value = referer }
        };

        const login_url = try std.fmt.allocPrint(self.arena, "http://{s}/login.cgi", .{self.ip});
        const uri = try std.Uri.parse(login_url);
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try client.open(
            .POST,
            uri,
            .{
                .server_header_buffer = &server_header_buffer,
                .headers = headers,
                .extra_headers = extraHeaders,
                .keep_alive = true,
            },
        );

        defer req.deinit();

        const login_string = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{user, password});

        var buffer: [0x100]u8 = undefined;
        const encoded_login = std.base64.standard.Encoder.encode(&buffer, login_string);

        const body = try std.fmt.allocPrint(self.arena, "group_id=&action_mode=&action_script=&action_wait=5&current_page=Main_Login.asp&next_page=index.asp&login_authorization={s}&login_captcha=", .{encoded_login});
        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();
        try req.writer().writeAll(body);
        try req.finish();
        try req.wait();

        var headerItr = req.response.iterateHeaders();
        while (headerItr.next()) |h| {
            std.debug.print("name: {s:<16} value: {s}\n", .{h.name, h.value});
            if (std.mem.eql(u8, h.name, "Set-Cookie")) {
                var tokens = std.mem.splitScalar(u8, h.value, ';');
                self.token_header = tokens.first();
            }
        }
    }
};