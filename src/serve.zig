//! `bedlam --serve` — the authoritative host, over a link.
//!
//! One Windows (or Linux) process that serves the browser client and hosts the world it
//! edits. `ARCHITECTURE.md` §2 says the editor is the engine in a client mode, so this is
//! not an editor server: it is *the* server, running the same `Host` a game would.
//!
//! **The host does no I/O and this file does no simulation.** `src/net/host.zig` produces
//! and consumes datagrams; `platform/websocket.zig` moves them. Keeping the seam there is
//! what will let a native UDP client join the same session as a browser one without the
//! host knowing the difference.
//!
//! **Assets are embedded, not read from disk.** A host is then one file to copy, and it
//! cannot serve a page that disagrees with its own binary — a stale `.wasm` beside a fresh
//! server is a schema-fingerprint mismatch at the handshake, which is correct behaviour
//! reporting a deployment mistake that should have been impossible.
//!
//! **No TLS here.** `std.crypto.tls` has a Client and no Server, and §18.13 forbids writing
//! one, so a public deployment puts a tunnel or reverse proxy in front. On a LAN, plain
//! `ws://` needs nothing. See `platform/websocket.zig` for the full argument.

const std = @import("std");
const Io = std.Io;
const bedlam = @import("bedlam_engine");
const plat = @import("bedlam_platform");

const step = bedlam.sim.step;
const session = bedlam.net.session;
const replicate = bedlam.net.replicate;
const Fixed = bedlam.fpz.Fixed;

const Decl = bedlam.schema.schema.components[0];
const Cols = step.Columns;
const ServerHost = bedlam.net.host.Host(Cols, 64, 16, 128);

/// 64, because that is the number the whole project is about. A host that quietly accepted
/// fewer would make every capacity claim untestable.
pub const max_clients = 64;

const Ws = plat.websocket_backend.?;

const assets = [_]Ws.Asset{
    .{
        .path = "/index.html",
        .content_type = "text/html; charset=utf-8",
        .bytes = @embedFile("editor_html"),
    },
    .{
        .path = "/bedlam_engine.wasm",
        .content_type = "application/wasm",
        .bytes = @embedFile("editor_wasm"),
    },
};

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, port: u16, ticks: u64) !void {
    var world = try step.seedWorld(gpa, 0xBED1A3, 24);
    defer world.deinit();

    const fp = try bedlam.schema.manifest.fingerprint(
        gpa,
        bedlam.schema.manifest.manifest,
        bedlam.schema.wire.Layout.desktop,
    );

    // A per-run secret would be better still; this is deterministic so the demo output is
    // reproducible, and it is the one value here a real deployment must replace.
    var host = try ServerHost.init(gpa, fp, @splat(0x5A), false);
    defer host.deinit();

    var server = Ws.Server.init(gpa, io, &assets);
    try server.listen(port);
    defer server.deinit();

    try out.print("\nserve\n", .{});
    try out.print("  listening    http://localhost:{d}/\n", .{server.port});
    try out.print("  schema       {s}\n", .{&fp});
    try out.print("  entities     {d}\n", .{world.liveCount()});
    try out.print("  tls          none — put a tunnel in front for a public link\n", .{});
    try out.flush();

    var ident: bedlam.wire.codec.Storage(Decl) = std.mem.zeroes(bedlam.wire.codec.Storage(Decl));
    ident.rotation = .{ Fixed.ONE, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO };

    var reply: [session.max_datagram]u8 = undefined;
    var payload: [session.max_datagram]u8 = undefined;
    var frame: [session.max_datagram]u8 = undefined;

    var tick: u64 = 0;
    var peak_clients: u32 = 0;
    var frames_sent: u64 = 0;

    while (ticks == 0 or tick < ticks) : (tick += 1) {
        // 1. Drain the network. A ring pop per message, no syscall on this thread.
        var drained: u32 = 0;
        while (drained < 256) : (drained += 1) {
            const msg = server.poll() orelse break;
            std.debug.print("[serve] rx {d} bytes from ep {d}\n", .{ msg.bytes.len, msg.endpoint });
            const key = std.mem.asBytes(&msg.endpoint);
            switch (host.receive(msg.endpoint, key, msg.bytes, &reply, &payload)) {
                .handshake => |hs| {
                    const ok = server.send(msg.endpoint, hs.reply);
                    std.debug.print("[serve] handshake reply {d} sent={} client={?d}\n", .{ hs.reply.len, ok, hs.client });
                    if (hs.client) |id| {
                        // Everything in the scene is relevant to an editor: the shared
                        // document IS the interest set. §9.4 filtering is what a game
                        // needs and is not this.
                        host.interestAll(id, &world) catch {};
                    }
                },
                .data => {
                    // §13's authoring commands land here. Nothing to apply yet — this is
                    // the transport and replication half, and the edit path is next.
                },
                .bye, .ignored => {},
            }
        }

        // 2. Step the world.
        step.step(&world, 0xBED1A3, &step.System.all);
        world.advanceTick();

        // 3. Fan out one snapshot per client, then promote whatever was acknowledged.
        for (0..max_clients) |i| {
            const id: bedlam.net.host.ClientId = @intCast(i);
            if (host.sessionOf(id) == null) continue;
            if (!server.isLive(host.clients[i].endpoint)) {
                host.drop(id);
                continue;
            }
            if (host.assemble(Decl, id, &world, &frame, 1100, ident) catch null) |bytes| {
                _ = server.send(host.clients[i].endpoint, bytes);
                frames_sent += 1;
            }
            host.absorbAcks(id) catch {};
        }

        _ = host.tick();
        peak_clients = @max(peak_clients, host.count());

        // ~60 Hz. §1.3: cadence does not vary, so this is a fixed sleep rather than
        // anything adaptive.
        plat.backend.sleepMs(16);
    }

    try out.print("  ticks        {d}\n", .{tick});
    try out.print("  peak clients {d}\n", .{peak_clients});
    try out.print("  joined/left  {d}/{d}\n", .{ host.stats.joined, host.stats.left });
    try out.print("  frames sent  {d}\n", .{frames_sent});
    try out.flush();
}
