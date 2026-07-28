//! The rollback projection: copy-on-write logical pages.
//!
//! `ARCHITECTURE.md` §5.1 gives this projection one line — "Logical fixed-size
//! copy-on-write chunk pages" — and §5.2 gives it two operations: "Snapshot = copy dirty
//! logical pages into a ring. Rollback = swap page pointers, re-simulate the causal
//! closure."
//!
//! **"Page" is an engine-owned logical block.** §18.16, and it is stated four separate
//! times across the corpus because the tempting implementation is `mprotect` plus a
//! fault handler, which gives dirty tracking for free, works beautifully on desktop, and
//! does not exist on Web. By the time that matters the design is load-bearing. So: pages
//! are allocations this module owns, dirty bits are set explicitly by whoever mutates,
//! and copying is `@memcpy`.
//!
//! **Dirty state lives here, not in the chunk.** §18.5 forbids per-field metadata in
//! chunks from any subsystem, and rollback bookkeeping is exactly the kind of subsystem
//! that would otherwise add a version stamp per row. The page table is the "beside the
//! database" that §5.2 prescribes.
//!
//! The ring is bounded and its depth is a rollback-window decision, not a memory one:
//! `BENCHMARK_CONTRACT.md` §5 permits ladder step 4 — authoritative correction with no
//! local re-simulation — in ≤ 0.5% of predicted ticks, and a ring too shallow to reach
//! the mispredicted tick forces step 4 every time.

const std = @import("std");

pub const PageIndex = u32;
pub const invalid_page: PageIndex = std.math.maxInt(PageIndex);

/// One versioned snapshot of the world's pages.
///
/// Holds page *indices*, not page bytes. Copy-on-write means an unchanged page is shared
/// between every snapshot that did not modify it, which is what makes snapshotting cost
/// proportional to churn rather than to world size — the property §5.2 is buying with the
/// word "dirty".
pub const Snapshot = struct {
    tick: u64,
    pages: []PageIndex,
};

/// Fixed-size copy-on-write page store with a bounded snapshot ring.
pub fn Store(comptime page_bytes: usize, comptime ring_depth: usize) type {
    return struct {
        const Self = @This();

        pub const page_size: usize = page_bytes;
        pub const depth: usize = ring_depth;

        const Page = struct {
            bytes: [page_bytes]u8,
            /// Snapshots referring to this page. A page is recyclable at zero.
            refs: u32,
        };

        gpa: std.mem.Allocator,
        pages: std.ArrayList(Page),
        free_pages: std.ArrayList(PageIndex),

        /// Live page per logical slot.
        live: std.ArrayList(PageIndex),
        /// Whether the live page has been written since the last snapshot.
        dirty: std.ArrayList(bool),

        ring: [ring_depth]?Snapshot,
        ring_next: usize,
        tick: u64,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .pages = .empty,
                .free_pages = .empty,
                .live = .empty,
                .dirty = .empty,
                .ring = @splat(null),
                .ring_next = 0,
                .tick = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.ring) |maybe| {
                if (maybe) |s| self.gpa.free(s.pages);
            }
            self.pages.deinit(self.gpa);
            self.free_pages.deinit(self.gpa);
            self.live.deinit(self.gpa);
            self.dirty.deinit(self.gpa);
            self.* = undefined;
        }

        fn allocPage(self: *Self) !PageIndex {
            if (self.free_pages.pop()) |idx| {
                self.pages.items[idx].refs = 1;
                @memset(&self.pages.items[idx].bytes, 0);
                return idx;
            }
            const idx: PageIndex = @intCast(self.pages.items.len);
            try self.pages.append(self.gpa, .{ .bytes = @splat(0), .refs = 1 });
            return idx;
        }

        fn release(self: *Self, idx: PageIndex) void {
            if (idx == invalid_page) return;
            const p = &self.pages.items[idx];
            std.debug.assert(p.refs > 0);
            p.refs -= 1;
            if (p.refs == 0) self.free_pages.append(self.gpa, idx) catch {
                // The free list is an optimization; losing an entry leaks one page for
                // the process lifetime rather than failing a tick. §18.8 forbids
                // allocation failure from being a frame-loop error path.
            };
        }

        /// Add a logical slot, returning its index.
        pub fn addSlot(self: *Self) !u32 {
            const idx = try self.allocPage();
            try self.live.append(self.gpa, idx);
            try self.dirty.append(self.gpa, true);
            return @intCast(self.live.items.len - 1);
        }

        pub fn slotCount(self: Self) u32 {
            return @intCast(self.live.items.len);
        }

        /// Read-only view. Does not dirty the slot — a system that only reads must not
        /// cause a page copy, or snapshot cost stops tracking churn.
        pub fn read(self: *const Self, slot: u32) *const [page_bytes]u8 {
            return &self.pages.items[self.live.items[slot]].bytes;
        }

        /// Mutable view. Copies on write if the live page is shared with a snapshot, and
        /// marks the slot dirty.
        pub fn write(self: *Self, slot: u32) !*[page_bytes]u8 {
            const current = self.live.items[slot];
            if (self.pages.items[current].refs > 1) {
                const fresh = try self.allocPage();
                @memcpy(&self.pages.items[fresh].bytes, &self.pages.items[current].bytes);
                self.release(current);
                self.live.items[slot] = fresh;
            }
            self.dirty.items[slot] = true;
            return &self.pages.items[self.live.items[slot]].bytes;
        }

        /// Capture the current page set. §5.2's "copy dirty logical pages into a ring" —
        /// except nothing is copied here at all: taking a reference is enough, and the
        /// copy happens later and only if someone writes. Dirty flags clear so the next
        /// snapshot's cost again tracks only what changed.
        pub fn snapshot(self: *Self) !void {
            const pages = try self.gpa.alloc(PageIndex, self.live.items.len);
            @memcpy(pages, self.live.items);
            for (pages) |idx| self.pages.items[idx].refs += 1;

            if (self.ring[self.ring_next]) |old| {
                for (old.pages) |idx| self.release(idx);
                self.gpa.free(old.pages);
            }
            self.ring[self.ring_next] = .{ .tick = self.tick, .pages = pages };
            self.ring_next = (self.ring_next + 1) % ring_depth;

            @memset(self.dirty.items, false);
            self.tick += 1;
        }

        pub fn findSnapshot(self: *const Self, tick: u64) ?Snapshot {
            for (self.ring) |maybe| {
                if (maybe) |s| {
                    if (s.tick == tick) return s;
                }
            }
            return null;
        }

        /// §5.2's "swap page pointers". No bytes move: the live set is repointed at the
        /// snapshot's pages, which is why rollback cost is independent of world size and
        /// depends only on what the re-simulation then touches.
        pub fn rollbackTo(self: *Self, tick: u64) error{SnapshotEvicted}!void {
            const snap = self.findSnapshot(tick) orelse return error.SnapshotEvicted;
            std.debug.assert(snap.pages.len <= self.live.items.len);

            for (snap.pages, 0..) |idx, slot| {
                if (self.live.items[slot] == idx) continue;
                self.release(self.live.items[slot]);
                self.pages.items[idx].refs += 1;
                self.live.items[slot] = idx;
            }
            @memset(self.dirty.items, true);
            self.tick = tick;
        }

        pub fn dirtyCount(self: Self) u32 {
            var n: u32 = 0;
            for (self.dirty.items) |d| {
                if (d) n += 1;
            }
            return n;
        }

        /// Pages currently allocated. The measure that matters for §2.1's memory ceiling.
        pub fn residentPages(self: Self) u32 {
            return @intCast(self.pages.items.len - self.free_pages.items.len);
        }
    };
}

// ---------------------------------------------------------------------------

const TestStore = Store(64, 4);

test "a fresh slot reads as zero" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();
    for (s.read(slot)) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "writing after a snapshot copies, so the snapshot is unchanged" {
    // The whole point of copy-on-write. If this failed, a rollback would restore state
    // that had already been mutated.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();

    (try s.write(slot))[0] = 0xAA;
    try s.snapshot();

    (try s.write(slot))[0] = 0xBB;
    try std.testing.expectEqual(@as(u8, 0xBB), s.read(slot)[0]);

    try s.rollbackTo(0);
    try std.testing.expectEqual(@as(u8, 0xAA), s.read(slot)[0]);
}

test "reading does not dirty a slot" {
    // Snapshot cost must track churn. A read that dirties turns every tick into a full
    // copy and the word "dirty" in §5.2 stops meaning anything.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();
    try s.snapshot();

    try std.testing.expectEqual(@as(u32, 0), s.dirtyCount());
    _ = s.read(slot);
    try std.testing.expectEqual(@as(u32, 0), s.dirtyCount());
    _ = try s.write(slot);
    try std.testing.expectEqual(@as(u32, 1), s.dirtyCount());
}

test "an unchanged page is shared rather than copied" {
    // Snapshot cost proportional to churn, not to world size — the property that makes
    // snapshotting affordable at the §1.1 census.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    for (0..8) |_| _ = try s.addSlot();

    try s.snapshot();
    const before = s.residentPages();

    // Touch one of eight.
    _ = try s.write(3);
    try std.testing.expectEqual(before + 1, s.residentPages());
}

test "rollback moves no bytes" {
    // §5.2: "swap page pointers". Cost is independent of world size.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    for (0..4) |_| _ = try s.addSlot();
    try s.snapshot();

    for (0..4) |i| (try s.write(@intCast(i)))[0] = 0xFF;
    const resident = s.residentPages();

    try s.rollbackTo(0);
    // Rolling back releases the copies but allocates nothing.
    try std.testing.expect(s.residentPages() <= resident);
    for (0..4) |i| try std.testing.expectEqual(@as(u8, 0), s.read(@intCast(i))[0]);
}

test "the ring is bounded and evicts oldest first" {
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();

    for (0..TestStore.depth) |i| {
        (try s.write(slot))[0] = @intCast(i);
        try s.snapshot();
    }
    try std.testing.expect(s.findSnapshot(0) != null);

    // One more evicts tick 0.
    (try s.write(slot))[0] = 0xEE;
    try s.snapshot();
    try std.testing.expect(s.findSnapshot(0) == null);
}

test "rolling back past the ring reports eviction rather than guessing" {
    // BENCHMARK_CONTRACT.md §5 caps ladder step 4 at 0.5% of predicted ticks under
    // `regional`. A silent failure here would look like a mysterious desync instead of a
    // ring that is too shallow, which is a tuning decision the caller has to make.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();
    for (0..TestStore.depth + 2) |_| {
        _ = try s.write(slot);
        try s.snapshot();
    }
    try std.testing.expectError(error.SnapshotEvicted, s.rollbackTo(0));
}

test "pages are recycled, so a steady state does not grow" {
    // A 45-minute soak (§7) at 64 Hz is 172,800 ticks. Leaking one page per tick is not
    // survivable on a 1.8 GB mobile budget.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();

    for (0..64) |_| {
        _ = try s.write(slot);
        try s.snapshot();
    }
    const steady = s.residentPages();

    for (0..256) |_| {
        _ = try s.write(slot);
        try s.snapshot();
    }
    try std.testing.expectEqual(steady, s.residentPages());
}

test "rollback then re-simulate reaches the same bytes as never rolling back" {
    // The correctness property rollback exists to provide, stated directly.
    var s = TestStore.init(std.testing.allocator);
    defer s.deinit();
    const slot = try s.addSlot();

    (try s.write(slot))[0] = 1;
    try s.snapshot(); // tick 0 captured
    (try s.write(slot))[0] = 2;
    try s.snapshot();
    const with_history = s.read(slot)[0];

    try s.rollbackTo(0);
    (try s.write(slot))[0] = 2; // re-simulate the same input
    try std.testing.expectEqual(with_history, s.read(slot)[0]);
}
