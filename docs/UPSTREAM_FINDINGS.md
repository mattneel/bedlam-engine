# Upstream Findings — Zig 0.16.0

Behaviour in the toolchain and standard library that Bedlam's code is shaped around. Each
entry cost real debugging time and each would have shipped as a plausible-looking bug in
Bedlam rather than as an obvious defect upstream. They are recorded here so the next person
to touch the affected file confronts the constraint rather than rediscovering it — and so
that when a future Zig release fixes one, the workaround can be removed on purpose instead
of surviving forever.

Every entry states **how it was observed**, not merely what was concluded. A note that says
"X doesn't work" and cannot be re-checked becomes folklore, which is the thing
`ARCHITECTURE.md` §7 is explicitly against.

---

## 1. `BindOptions.ip6_only` is POSIX-only and inverted

**Where it bit:** `platform/udp.zig`.

`std.Io.net.IpAddress.bind` takes `BindOptions.ip6_only`. In `std/Io/Threaded.zig`:

```zig
if (options.ip6_only) {
    if (posix.IPV6 == void) return error.OptionUnsupported;
    try setSocketOptionPosix(socket_fd, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, 0);
}
```

Two problems. The option is set to **0** — dual-stack — when `ip6_only` is **true**, which
is backwards. And this is the POSIX bind path; the Windows path never touches `V6ONLY` at
all, while Windows defaults it to 1.

**Consequence:** a socket bound to `::` on Windows is IPv6-only regardless of what was
requested, and sending to a v4-mapped address (`::ffff:127.0.0.1`) fails with
`INVALID_ADDRESS_COMPONENT`. On Linux the default happens to be dual-stack, so the same
code works — which is worse than failing everywhere, because it makes the bug a
platform-specific mystery.

**Observed:** a `::`-bound datagram socket successfully sends to `::1` and fails to
`::ffff:127.0.0.1`, on Windows 11, `zig 0.16.0`.

**What Bedlam does instead:** `Socket` binds exactly one family and records which. `Pair`
binds both and routes by the destination's family. Two sockets, one receive path — two
receive *loops* is the thing worth avoiding, not two descriptors.

**Why this mattered more than it looks:** the naive design produces an engine where IPv4
clients cannot connect to a Windows host, and the symptom reads as a NAT or firewall
problem rather than as a socket option.

---

## 2. `receiveTimeout` needs concurrency the process `Io` will not give

**Where it bit:** `platform/udp.zig`.

`std.Io.net.Socket.receiveTimeout` routes through `io.operateTimeout`, which needs
`Io.concurrent`. On Windows it returns `error.ConcurrencyUnavailable` — with a hand-built
`Io.Threaded` *and* with the `Io` that `std.process.Init` supplies, and with
`concurrent_limit` left at its `.unlimited` default. Plain blocking `receive` on the same
socket works.

**Observed:** send succeeds, `receiveTimeout` returns `ConcurrencyUnavailable`, `receive`
returns the datagram. Windows 11, `zig 0.16.0`.

**The trap is in the response, not the error.** The first version of `poll` was:

```zig
const msg = self.inner.receiveTimeout(io, buf, zero) catch return null;
```

`null` means "nothing waiting". So a permanent, structural failure was reported as an idle
network, forever. Every loopback test spun to its iteration limit and failed with
`NothingArrived` — a symptom that points at the network, not at the error being discarded
three lines away.

**What Bedlam does instead:** the bounded wait moved from the syscall into the
architecture. A receiver thread blocks on `receive` and publishes into a lock-free ring;
the frame loop's `poll` is a ring pop with no syscall and no wait. `ARCHITECTURE.md` §12
wants that decoupling regardless, and it is the same shape `platform/windows/audio.zig`
already uses.

**Rule this produced:** a `catch return null` that turns *any* error into "nothing
happened" is a bug waiting for a reason. Null must mean one specific thing.

---

## 3. A blocking `receive` interrupted by `close` panics on Windows

**Where it bit:** `platform/udp.zig`, `Receiver.stop`.

Closing a socket is the usual way to break a thread out of a blocking receive. On Windows
that yields `STATUS_CANCELLED`, and `netReceiveOneWindows` in `std/Io/Threaded.zig` has:

```zig
.CANCELLED => unreachable,
```

So it is not an error — it is a panic, in release builds a crash, on the shutdown path.

**Observed:** `reached unreachable code` at `Threaded.zig:13013` on every `Receiver.stop`
with a thread parked in `receive`.

**What Bedlam does instead:** `stop` clears `running` and sends the socket a zero-length
datagram addressed to itself. The receive returns normally, the thread re-checks `running`
and exits, and only then is the socket closed. The thread also re-checks `running` *after*
the receive so the wakeup packet is never published to the frame loop.

**Why not a timeout-based wakeup:** that is finding 2, which is what this design exists to
avoid.

---

## 4. `zig build cross` skips foreign run steps silently

**Where it bit:** `build.zig`.

Foreign-architecture `RunArtifact` steps are **skipped** unless `b.enable_qemu` is set, and
a skipped step reports success. The gate appears green precisely because it never ran.

**What Bedlam does instead:** `b.enable_qemu = true` is set in `addCrossStep` rather than
requiring `-fqemu` on the command line, so the gate cannot be green by omission.

Documented at greater length in `CI_TIERS.md` §4. Inherited from
[gkz](https://github.com/mattneel/gkz), which hit the same thing.

---

## 5. `std.net` is gone; networking lives under `std.Io`

Not a defect, but it invalidates every pre-0.16 example. `std.net.Address` is now
`std.Io.net.IpAddress`, a tagged union rather than a `sockaddr` wrapper, and every socket
operation takes an `Io`. `Io.Clock` has no `monotonic` — the equivalent is `awake`.

Recorded because the migration is mechanical but the error messages are not: a missing
`std.net` reads as a broken toolchain rather than as an API move.

---

## 6. Zig honours `SOURCE_DATE_EPOCH`, and needs it for a reproducible PE

Not a defect — a fact worth writing down, because the alternative fix is worse.

**Where it matters:** `tools/package.zig`, `scripts/reproducible.ps1`.

**Observed:** two cold builds of this repo, 30 seconds apart, produced
`bedlam_engine.exe` differing in exactly **two bytes out of 2,586,112**:

```
offset      129  '2' vs 'P'      # COFF header TimeDateStamp
offset  2488325  '2' vs 'P'      # its copy in the debug directory
```

`0x6a68db32` against `0x6a68db50` — 30 seconds, matching the gap between the builds.
Everything else was identical, **including the RSDS debug GUID** that ties the binary to its
PDB. So Zig and LLD are already reproducible on this target; one field is the wall clock.

Setting `SOURCE_DATE_EPOCH` makes two cold builds byte-identical. Verified, and verified
non-vacuously: a *different* epoch changes the output, so the check is measuring something.

**Why not rewrite the binary instead:** the debug directory timestamp participates in PDB
association for some toolchains, and M0 criterion 9 is crash capture *and symbolication*.
Zeroing a field that a symbol server may key on, to win a property the environment already
grants, is a bad trade.

---

## How to retire an entry

When a Zig upgrade fixes one of these, the workaround should be removed rather than left in
place. Each entry names the file and the mechanism, so the check is: revert the workaround,
run `zig build test` on Windows **and** `scripts/cross.ps1`, and confirm the original
observation no longer reproduces. Entries 1–3 all have tests that state the constraint
directly, so a fixed toolchain shows up as a test that has become tautological rather than
as silence.
