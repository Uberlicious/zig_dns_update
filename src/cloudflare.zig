const std = @import("std");
const c = @cImport(
    @cInclude("curl/curl.h"),
);
const Allocator = std.mem.Allocator;

const ResponseInfo = struct {
    code: u64,
    message: []const u8,
};

const ResultInfo = struct {
    count: ?i32,
    page: ?i32,
    per_page: ?i32,
    total_count: ?i32,
    total_pages: ?i32,
};

const ZoneDetails = struct {
    id: []u8,
    name: []u8,
};

pub const ListZonesResponse = struct {
    errors: []ResponseInfo,
    messages: []ResponseInfo,
    success: bool,
    result: []ZoneDetails,
    result_info: ResultInfo,
};

pub const RecordSettings = struct {
    ipv4_only: ?bool = null,
    ipv6_only: ?bool = null,
};

pub const Record = struct {
    content: ?[]u8,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    proxied: ?bool = null,
    settings: ?RecordSettings = null,
    tags: ?[][]const u8 = null,
    ttl: ?i8 = null,
    type_: ?[]const u8 = null,
};

pub const ListRecordsReponse = struct {
    result: []Record,
    errors: []ResponseInfo,
    messages: []ResponseInfo,
    success: bool,
    result_info: ResultInfo,
};

pub const PatchResponse = struct {
    result: ?Record,
    errors: []ResponseInfo,
    messages: []ResponseInfo,
    success: bool,
};

pub const CloudflareClient = struct {
    auth_token: []const u8,

    pub fn init(auth_token: []const u8) CloudflareClient {
        return CloudflareClient{
            .auth_token = auth_token,
        };
    }

    // caller is responsible for freeing parsed memory
    pub fn get(self: CloudflareClient, allocator: Allocator, comptime Response: type, url: []const u8) !std.json.Parsed(Response) {
        var arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{ .allocator = arena };
        defer client.deinit();

        const headers = std.http.Client.Request.Headers{
            .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}\r\n", .{self.auth_token}) },
            .content_type = .{ .override = "application/json" },
        };

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var request = try client.open(
            .GET,
            uri,
            .{
                .server_header_buffer = &server_header_buffer,
                .headers = headers,
            },
        );
        defer request.deinit();

        try request.send();
        try request.wait();

        const body = try request.reader().readAllAlloc(arena, 4096);

        return try std.json.parseFromSlice(
            Response,
            allocator,
            body,
            .{
                .ignore_unknown_fields = true,
            },
        );
    }

    // leaving this in as a placeholder, currently does not correctly send the body as a PATCH using http
    pub fn patch(self: CloudflareClient, allocator: Allocator, body: anytype, url: []const u8) !void {
        var arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        var bodyString = std.ArrayList(u8).init(arena);
        defer bodyString.deinit();
        try std.json.stringify(body, .{ .emit_null_optional_fields = false }, bodyString.writer());

        var client: std.http.Client = .{ .allocator = arena };
        defer client.deinit();

        var server_header_buffer: [16 * 1024]u8 = undefined;
        const headers = std.http.Client.Request.Headers{
            .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}\r\n", .{self.auth_token}) },
            .content_type = .{ .override = "application/json" },
        };

        const uri = try std.Uri.parse(url);
        var request = try client.open(
            .PATCH,
            uri,
            .{
                .server_header_buffer = &server_header_buffer,
                .headers = headers,
                .keep_alive = true,
            },
        );

        defer request.deinit();

        request.transfer_encoding = .{ .content_length = bodyString.items.len };
        try request.send();
        try request.writer().writeAll(bodyString.items);
        try request.finish();
        try request.wait();

        const bodyResponse = try request.reader().readAllAlloc(arena, 4096);
        defer allocator.free(bodyResponse);

        const res = try std.json.parseFromSlice(
            PatchResponse,
            allocator,
            bodyResponse,
            .{ .ignore_unknown_fields = true },
        );
        defer res.deinit();

        if (!res.value.success) {
            for (res.value.errors) |err| {
                const log = std.log.scoped(.cloudflare_patch);
                log.err("cloudflare PATCH error: err: {s}\n", .{err.message});
            }
        }

        return;
    }

    pub fn c_patch(self: CloudflareClient, allocator: Allocator, body: anytype, url: []const u8) !void {
        const log = std.log.scoped(.c_patch);

        var arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        var bodyString = std.ArrayList(u8).init(arena);
        defer bodyString.deinit();
        try std.json.stringify(body, .{ .emit_null_optional_fields = false }, bodyString.writer());

        const curl = c.curl_easy_init();
        defer c.curl_easy_cleanup(curl);

        const auth_header = try std.fmt.allocPrint(arena, "Authorization: Bearer {s}", .{self.auth_token});
        defer arena.free(auth_header);

        const content_type_header = "Content-Type: application/json";

        var headers: ?*c.struct_curl_slist = null;
        headers = c.curl_slist_append(headers, auth_header.ptr);
        headers = c.curl_slist_append(headers, content_type_header);
        defer c.curl_slist_free_all(headers);

        if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url.ptr) != c.CURLE_OK) {
            return error.CurlUrlFailed;
        }
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, headers) != c.CURLE_OK) {
            return error.CurlHttpHeaderFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "PATCH") != c.CURLE_OK) {
            return error.CurlCustomRequestFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, bodyString.items.ptr) != c.CURLE_OK) {
            return error.CurlPostFieldsFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDSIZE, bodyString.items.len) != c.CURLE_OK) {
            return error.CurlPostFieldSizeFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != c.CURLE_OK) {
            return error.CurlWriteFailed;
        }

        var response_buffer = std.ArrayList(u8).init(arena);
        defer response_buffer.deinit();

        if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &response_buffer) != c.CURLE_OK) {
            return error.CurlWriteDataFailed;
        }

        const res = c.curl_easy_perform(curl);
        if (res != c.CURLE_OK) {
            return error.CurlPerformFailed;
        }

        const bodyResponse = response_buffer.items;

        const bodyJson = try std.json.parseFromSlice(
            PatchResponse, 
            allocator,
            bodyResponse,
            .{.ignore_unknown_fields = true},
        );

        if (bodyJson.value.success == true) {
            log.info("dns record updated - name: {s}", .{bodyJson.value.result.?.name.?});
        } else {
            var errors = std.ArrayList(u8).init(allocator);
            defer errors.deinit();
            try std.json.stringify(bodyJson.value.errors, .{}, errors.writer());
            if (bodyJson.value.result == null) {
                log.err("dns record update failed - errors: {s}", .{errors.items});
            } else {
                log.err("dns record update failed - name: {s} errors: {s}", .{bodyJson.value.result.?.name.?, errors.items});
            }
        }
    }
};

fn writeToArrayListCallback(data: *anyopaque, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    var buffer: *std.ArrayList(u8) = @alignCast(@ptrCast(user_data));
    var typed_data: [*]u8 = @ptrCast(data);
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}