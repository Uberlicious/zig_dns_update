const std = @import("std");
const c = @cImport({
    @cInclude("syslog.h");
});

const Allocator = std.mem.Allocator;

const cloudflare = @import("cloudflare.zig");
const CloudflareClient = cloudflare.CloudflareClient;
const AsusRouter = @import("asus_router.zig").AsusRouter;

var syslog_initialized: bool = false;

pub const log_level = .err;
pub const std_options = .{
    .logFn = log,
};

pub fn GetIp(allocator: Allocator) ![]u8 {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var client: std.http.Client = .{ .allocator = arena };
    defer client.deinit();

    var response = std.ArrayList(u8).init(allocator);
    const request = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = "https://ipv4.icanhazip.com" },
        .response_storage = .{ .dynamic = &response },
    });

    if (request.status != std.http.Status.ok) {
        return error.RequestNotOkay;
    }

    // check if last character is newlinw and remove
    if (response.getLast() == 10) {
        _ = response.pop();
    }
    const return_array = try response.toOwnedSlice();
    return return_array;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (!syslog_initialized) {
        c.openlog("dns_update", 0, c.LOG_USER);
        syslog_initialized = true;
    }

    const pri: c_int = switch (message_level) {
        std.log.Level.debug => c.LOG_DEBUG,
        std.log.Level.info => c.LOG_INFO,
        std.log.Level.err => c.LOG_ERR,
        else => c.LOG_INFO,
    };

    // allocPrintZ to get null terminated string
    const formatted_msg: [:0]const u8 = std.fmt.allocPrintZ(std.heap.page_allocator, format, args) catch "log formatting error";

    c.syslog(pri, "%s", &formatted_msg[0]);

    {
        const stderr = std.io.getStdErr().writer();
        stderr.print("syslog: [{s}] {s}\n", .{ message_level.asText(), formatted_msg }) catch return;
    }
}

// caller must deinit map result
pub fn GetEnv(allocator: Allocator) !std.StringHashMap([]const u8) {
    // const log_scoped = std.log.scoped(.GetEnv);
    const f: std.fs.File = try std.fs.cwd().openFile(".env", .{});

    const contents = try f.readToEndAlloc(allocator, 4096);
    defer allocator.free(contents);
    var split_lines = std.mem.splitAny(u8, contents, "\r\n");

    var env_map = std.StringHashMap([]const u8).init(allocator);

    while (split_lines.next()) |line| {
        if (line.len == 0) continue;

        var split_line = std.mem.splitScalar(u8, line, '=');
        const key = split_line.next();
        const value = split_line.next();

        if (key != null and value != null) {
            const key_copy = try allocator.dupe(u8, key.?);
            const value_copy = try allocator.dupe(u8, value.?);
            const item = try env_map.getOrPut(key_copy);
            item.value_ptr.* = value_copy;
        }
    }

    return env_map;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var env_vars = try GetEnv(allocator);
    defer env_vars.deinit();
    // const api_key = env_vars.get("cloudflare_api_key") orelse return error.NoApiKeyProvided;
    // const domain = env_vars.get("domain") orelse return error.NoDomainProvided;

    // const cfClient = CloudflareClient.init(api_key);
    // const zoneResponse = try cfClient.get(
    //     allocator,
    //     cloudflare.ListZonesResponse,
    //     "https://api.cloudflare.com/client/v4/zones",
    // );
    // defer zoneResponse.deinit();

    // var zone_id: ?[]const u8 = undefined;
    // for (zoneResponse.value.result) |zone| {
    //     if (std.mem.eql(u8, zone.name, domain)) {
    //         zone_id = zone.id;
    //     }
    // }

    // if (zone_id == null) {
    //     return error.NoDomainFound;
    // }

    // const recordResponse = try cfClient.get(
    //     std.heap.page_allocator,
    //     cloudflare.ListRecordsReponse,
    //     try std.fmt.allocPrint(allocator, "https://api.cloudflare.com/client/v4/zones/{s}/dns_records?type=A", .{zone_id.?}),
    // );
    // defer recordResponse.deinit();

    // const currentIp = try GetIp(allocator);

    // for (recordResponse.value.result) |record| {
    //     if (std.mem.eql(u8, record.content orelse "", currentIp)) {
    //         std.log.info("no update needed - name: {s}", .{record.name.?});
    //     } else {
    //         std.log.info("update required - name: {s} old_ip: {s} new_ip: {s}", .{record.name.?, record.content.?, currentIp});
    //         const newRecord = cloudflare.Record{
    //             .content = currentIp,
    //         };
    //         try cfClient.c_patch(
    //             allocator,
    //             newRecord,
    //             try std.fmt.allocPrint(allocator, "https://api.cloudflare.com/client/v4/zones/{s}/dns_records/{s}", .{ zone_id.?, record.id.? }),
    //         );
    //     }
    // }

    // check for AsusRouter Vars
    const router_ip = env_vars.get("router_ip") orelse return error.NoRouterIPProvided;
    const router_user = env_vars.get("router_user") orelse return error.NoRouterUserProvided;
    const router_password = env_vars.get("router_password") orelse return error.NoRouterPasswordProvided;

    var router = AsusRouter.init(allocator, router_ip);
    std.debug.print("IP: {s}\n", .{router.ip});
    // defer router.deinit();

    try router.login(router_user, router_password);
    std.debug.print("\u{001b}[36mTokenHeader: {s}", .{router.token_header});
}
