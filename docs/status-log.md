# Status log

Chronological record of the bring-up, including what was measured rather than assumed. Written so a
fresh session can pick this up without re-deriving it.

## Bring-up session 1 — discovery, backend, tooling

### What was established

**The device is present and is an RSPduo.** `lsusb` shows `Bus 001 Device 013: ID 1df7:3020`.
Confirmed as an RSPduo by three independent sources: the vendor's own `20-sdrplay.hwdb`
(`usb:v1DF7p3020*` → `RSPduo`), the Arch `PKGBUILD` for `libsdrplay`, and `usb.ids`. Descriptors
show vendor-specific class, one interface, no endpoints, and empty manufacturer/product/serial
strings — normal for an RSP device before the API initialises it.

**The SDRplay API was not installed.** No `libsdrplay_api` in the linker cache, no `/opt/sdrplay_api`,
no `sdrplay.service`, no `sdrplay` SoapySDR module in the SoapySDR 0.7.2 module list. So the device
could not be opened by anything.

**Root is genuinely required**, not a convenience. The USB node is `crw-rw-r-- root root`, so nothing
non-root can open it, and API 3.x puts all hardware access in `sdrplay_apiService` which the vendor
ships as a root systemd unit. `sudo` on this host requires a password, so the install is a
deliberate hand-off: the script is written and staged, the operator runs it.

**The installer is authentic.** `SDRplay_RSP_API-Linux-3.15.2.run` downloaded from the vendor
(511429 bytes, HTTP 200) and its SHA512 —
`6ded10a6…9ad85ec` — matches the upstream Arch `PKGBUILD` checksum exactly. Payload contains
`arm64/`, `armhf/`, `amd64/` slices and `inc/sdrplay_api_rspDuo.h`, i.e. aarch64 is supported and the
RSPduo is a first-class device in the API.

**The reference implementations all use the native API**, not a SoapySDR wrapper — which settled the
question of how to reach the hardware.

### What was produced

| Artifact | State |
|---|---|
| `scripts/install-sdrplay-api.sh` | written, `bash -n` clean, `shellcheck` clean; replicates the vendor `install_lib.sh` non-interactively, verifies its own result |
| `rspduo` branch of ogn-rf | written and pushed; compiles clean under `-Wall -Wextra` |
| `rspduo.h` backend | 724 lines; verified to compile against the real vendor headers |
| `src/rspduo_probe.c` | written, compiles clean under `-Wall -Wextra`; not yet run against hardware |
| `tools/spectrum.py` | **verified** against a synthetic capture: tone at +100 kHz reported at +100.1 kHz, 68.4 dB over floor, −100 kHz at floor |

### Findings worth keeping

- `sdrplay_api_Init()` **resets channel B to channel A's settings.** Channel B must be reconfigured
  with `sdrplay_api_Update()` *after* `Init()` returns. Dormant here (tuner A only) but the first
  thing anyone extending this hits. Source: `dual-tuner-recorder`.
- `fsHz` is not a top-level field of `devParams`; it lives in `devParams->fsFreq.fsHz`. Caught by
  compiling against the vendor headers before writing more code.
- ogn-rf calls `SDR.Read()`, **not** `SDR.ReadAsync()`. The acquisition loop is synchronous, which is
  why the backend needs a ring buffer rather than a callback pass-through.
- ogn-rf's config keys are unforgiving: a typo'd key is silently ignored and the built-in default is
  used. The real keys are `RF.OGN.Gain`, `RF.SampleRate`, `RF.FreqPlan`, `Position.Latitude`/`Longitude`,
  `APRS.Call` and `HTTP.Port` — the first draft of `config/ogn-rf-rspduo.conf` had three of those
  wrong and they were corrected against `ogn-rf.cc`.
- The RSPduo's ADC gives 2, 6 or 8 MHz and nothing else, so `RF.SampleRate = 2000000`.

### Next steps

1. Run `sudo ~/rspduo-deps/install-sdrplay-api.sh` — expect `RESULT: SDRplay API installed and the
   daemon is running.`
2. `scripts/probe-rspduo.sh` — record the raw `int16` peak and confirm `Shift = 8`.
3. `scripts/probe-rspduo.sh -o /tmp/868.u8` + `tools/spectrum.py` — record the 868 MHz noise floor
   and whether either OGN channel shows anything.
4. `scripts/build-ogn-rf.sh` and `scripts/run-ogn-rf.sh` — confirm the status page reports RSPduo at
   2.000 MSps.
5. Note: a clean run does not prove OGN decoding. That needs a transmitter in range, and this site
   has previously measured the 868 band as quiet.

## Bring-up session 2 — verification of everything that does not need root

The API install still has not run (the RSPduo node remains `root:root 0644` while the RTL-SDR and
LimeSDR nodes carry `plugdev` rules), so this session verified everything that could be verified
without it, and made the remaining step a single command.

### Verified without root

**The RSPduo branch does not regress the existing builds.** Built on the board with
`USE_RSPDUO=0`, i.e. as an ordinary RTL-SDR/LimeSDR binary:

```
[exit=0]
-rwxrwxr-x 1 threaded threaded 134512 ogn-rf
ogn-rf: ELF 64-bit LSB shared object, ARM aarch64, ... dynamically linked
```

Every warning in that build is pre-existing (`ogn-rf.cc:937` literal-suffix, `sysmon.h`
misleading-indentation, `ogn-rf.cc:284` format-overflow). None come from `rspduo.h` or `sdr.h`.

**The code compiles on the target toolchain, not just locally.** `g++ (Ubuntu 9.4.0)`, aarch64,
`-Wall -Wextra`, both consumers (`ogn-rf.cc`, `gsm_scan.cc`), exit 0, and:

```
=== which warnings are NEW (from rspduo.h / sdr.h)? ===
(no output)
```

**The compile-time fallback works at runtime.** A binary built without `USE_RSPDUO`, given a
configuration that asks for `rspduo`, prints:

```
SDR: RSPduo support was not compiled in (build with USE_RSPDUO=1)
```

and falls back to RTL-SDR. So a stale binary fails visibly rather than silently ignoring the
setting — which was the point of the fallback.

### One pre-existing oddity, recorded so it is not mistaken for a bug later

`ogn-rf.cc:356` prints `SDR.Open(%d, , ) fails` — a format string with placeholders that have no
arguments. The empty fields mean nothing; it is a pre-existing cosmetic defect in the branch
inherited from `limesdr`, not a config-parsing failure.

### What was produced

`scripts/bootstrap-rspduo.sh` — one `sudo` command that installs the API, then drops back to the
invoking user to run the probe, the spectrum capture, the ogn-rf build and a short ogn-rf run, and
writes every measurement to `~/rspduo-bootstrap-report.txt`. Only the install needs root; the
checks deliberately run as the user, which is how ogn-rf really runs.

Rationale: the verification is only possible once the root-owned daemon exists, so splitting
"install" and "verify" across two operator actions would waste a round trip. Steps 3-6 are
best-effort so one run reports everything that is wrong instead of stopping at the first failure.

### Still outstanding

The same five steps as session 1 — they now all live behind the bootstrap script.

## Bring-up session 3 — the ring-buffer bridge is now proven, without hardware

Still no root, so still no hardware. Instead the riskiest code in the backend was attacked
directly: the bridge from the SDRplay API's callback thread to ogn-rf's blocking `Read()` is the one
part whose correctness cannot be established by the compiler, and it turns out not to need hardware
to test.

`tests/test_rspduo_ring.cxx` stubs the handful of `sdrplay_api_*` entry points that `rspduo.h`
calls, captures the registered stream callback, and drives it directly.

```
25 checks, 0 failed
```

on x86-64 and again on the board with gcc 9.4. Covered: the int16 → u8 conversion including the 128
offset and clamping at both rails, that I and Q land in the right bytes in the right order, that a
mid-stream reset flushes the ring instead of splicing two configurations together, that an overrun
is counted rather than corrupting the ring, and that `Read()` fails instead of hanging once the
radio is closed.

### Two things this turned up, both worth keeping

- `Read()` rounds a requested count down to a multiple of 256, faithfully to `rtlsdr.h` and
  `limesdr.h`. That is correct behaviour but a trap for tests: every request in the unit test asks
  for a multiple of 256, and the first draft's small requests silently returned zero samples.
- `rspduo.h` passes a **stack-local** `sdrplay_api_CallbackFnsT` to `sdrplay_api_Init()`. That is
  right with the real library, which copies it — but the first draft of the stub saved the *pointer*
  instead of the struct and was left with a dangling reference the moment `Open()` returned, which
  segfaulted and looked exactly like a backend bug. The stub now copies by value, and the reason is
  documented in the test header so nobody re-introduces it.

### Still outstanding

Unchanged, and it is one command: `sudo scripts/bootstrap-rspduo.sh`.

## Bring-up session 4 — the device is running, and ogn-rf receives on it

The API was installed and the RSPduo came up. Everything below was measured on the hardware, and
two assumptions from earlier sessions had to be corrected.

### The install succeeded; two of my own checks were wrong

The installer reported `RESULT: installation incomplete`, and **both failures were bugs in my
verification, not in the install**:

- "libsdrplay_api not in the linker cache" — it was there. The check was
  `ldconfig -p | grep -q ...` under `set -o pipefail`: `grep -q` exits on the first match,
  `ldconfig` is killed by SIGPIPE (141), and pipefail turns that into a failure. Now read into a
  variable instead.
- "no sdrplay_apiService process" — it was running. `pgrep` matches the kernel's task name, which
  is truncated to 15 characters (`sdrplay_apiServ`), so asking for the 18-character name never
  matches. Now uses `pidof`, which compares the executable's basename and — unlike `pgrep -f` —
  cannot match the shell running the check.

A third, cosmetic one: the device-node scan printed every 0666 node on the bus, including five
unrelated RTL-SDR dongles. It now filters on vendor `1df7`.

The real outcome: library, headers, daemon, udev rule and hwdb all in place, `sdrplay.service`
active and enabled, and `lsusb` now names the device `SDRplay RSPduo`.

### What the hardware measured

Device: **RSPduo, serial 190507CB32**, API 3.15 (headers 3.15).

```
RSPduo::Open(0,868300000,2000000) => RSPduo, S/N 190507CB32
RSPduo::Open() =>  868.300 MHz,    2.000 Msps, gain reduction 20.0 dB, LNA state 0
```

**`Shift = 8` is confirmed**, by two independent measurements rather than a heuristic:

| Check | Result | Reading |
|---|---|---|
| Peak at maximum gain | 21761 (−3.0 dBFS) | the scale reaches the 16-bit rails |
| Clipping at that peak | 0 of 4 000 000 | no rail loss, so full scale is genuinely there |
| Quantisation | not all multiples of 2, 4 or 16 | no narrower ADC left-justified into 16 bits |

An earlier capture at 40 dB of gain peaked at only 1923 and my probe's first heuristic called that
"may need lowering". It was wrong: that signal was simply 24 dB below full scale. The peak alone
cannot settle the scale; the quantisation check can, and the probe now reports it.

**The gain law, measured at 868.3 MHz, LNA state 0:**

| gRdB | total gain | rms |
|---|---|---|
| 20 | 95.8 dB | −22.4 dBFS |
| 30 | 85.8 dB | −33.3 dBFS |
| 40 | 75.8 dB | −43.3 dBFS |
| 50 | 65.8 dB | −53.2 dBFS |
| 59 | 56.8 dB | −61.1 dBFS |

Exactly linear: `total = 115.8 − gRdB`. Stepping the LNA state down at `gRdB` 20 did **not** lower
the noise floor (rms went 2481 → 996 → 360 → 319 → 403 while reported gain fell 95.8 → 30.2 dB), so
on a noise-dominated band the LNA buys nothing and the LNA is held at 0, its lowest-noise setting.

**The stream is real-time.** Measured inside the capture window, not by wall clock:

| Transfer mode | Delivered | Requested | Error |
|---|---|---|---|
| BULK | 2.017 Msps | 2.000 Msps | +0.8 % |
| ISOCH | 2.025 Msps | 2.000 Msps | +1.3 % |

An earlier wall-clock measurement suggested only ~0.75–1.04 Msps and looked like a serious fault; it
was including process startup and Open/Init in the timing. Measuring the span between the first and
last callback gave the true figure.

### Reception

The chain receives real RF. Survey at `gRdB` 50:

| Centre | Noise floor | Strongest bin | Verdict |
|---|---|---|---|
| 100.0 MHz | −75.2 dBFS/Hz | **+33.9 dB over floor** | FM broadcast — the chain works |
| 433.92 MHz | −72.1 dBFS/Hz | +4.4 dB | nothing much |
| 868.300 MHz | −71.8 dBFS/Hz | +2.3 dB | quiet |
| 1090.0 MHz | −71.9 dBFS/Hz | +2.9 dB | quiet |

At maximum gain, both OGN channels sit on the noise floor (+0.1 dB at 868.200, +0.3 dB at 868.400).
So the receiver works and **there is nothing on 868 MHz to hear** — the same conclusion the LimeSDR
work reached on this site.

### ogn-rf end to end

`USE_RSPDUO=1` builds clean and links `libsdrplay_api.so.3`. Running it, the status page at
`http://xavieragx.local:8095/` reports:

```
RSPduo device #0        Serial      190507CB32
Name          RSPduo    Center frequency 868.300 MHz
Product       RSPduo    Sample rate      2.000 MHz
Tuner type    RSPduo    RF.OGN.Gain      90.0 dB
```

**"Half time slot" and "Dropped a slot" are normal here.** They looked like a fault in the new
backend, so the working LimeSDR build was run on the same machine as a control: it reports Live
Time **33.3 %** with 23 half-slots and 21 dropped slots in the same window, and the RSPduo backend
reports Live Time **33.3 %** with 22 and 20. The two backends behave identically, so that is a
property of this machine and configuration, not of the RSPduo code.

### Notes for next time

- An `ADC overload corrected` event appears on almost every capture, including ones 60 dB below
  full scale. It is a startup transient from the API, not a real overload — do not chase it.
- The status page shows `Tuner Xtal 0.000000 MHz` for the RSPduo, because `getXtalFreq()` reports
  that there is no crystal-trim interface. Cosmetic.
- `GRdB_set` starts at maximum gain in the constructor, so the stream opens at 95.8 dB and
  `setTunerGain()` settles it moments later once ogn-rf has read `RF.OGN.Gain`.

## Bring-up session 5 — both tuners working

`RF.RSPduo.DualTuner = 1` now runs both RSPduo tuners at once. Verified on the hardware, and the
two failure modes that make dual mode look like it works when it does not were both checked for.

### The constraints are real and are enforced

Dual mode is much stricter than single-tuner mode. It is not a matter of turning a second stream
on: the API accepts only a fixed set of (ADC rate, bandwidth, IF, internal decimation)
combinations, and **`IF_Zero` is not one of them** — IF_Zero is the entire basis of the
single-tuner configuration here. At a 2 MHz ADC:

| Bandwidth | IF | Decimation | Output per tuner |
|---|---|---|---|
| 0.200 MHz | 450 kHz | 4 | 500 ksps |
| 0.300 MHz | 450 kHz | 4 | 500 ksps |
| 0.600 MHz | 450 kHz | 2 | 1000 ksps |

The default is 0.6 MHz because the two European OGN channels are 200 kHz apart: a 0.2 MHz filter
centred between them sits on neither.

### The trap: Init() resets channel B

`sdrplay_api_Init()` resets channel B's settings to channel A's. Tuner B's frequency therefore has
to be written *after* `Init()` returns and pushed down with a `sdrplay_api_Update()` on
`sdrplay_api_Tuner_B`. Doing it before `Init()` leaves both tuners on the same band — which streams
perfectly happily, reports two channels, and receives the same spectrum twice.

So independence was tested the only way that proves anything: put the tuners on bands with
obviously different content and compare their spectra.

```
tuner A  99.592 MHz: strongest bin +16.9 dB over the noise floor   (FM broadcast)
tuner B 433.920 MHz: strongest bin  +1.3 dB over the noise floor   (nothing)
```

If channel B had been left on A's frequency, B would have shown the same 16.9 dB FM signal.

### What ogn-rf reports

```
RSPduo::Open() => dual-tuner mode: 2.000 MHz ADC, bw 600 kHz, IF 450 kHz, decimate by 2 => 1.000 Msps per tuner
RSPduo::Open() => tuner B tuned to  868.400 MHz (channel B re-applied after Init)
RSPduo::Open() => tuner A  868.300 MHz + tuner B both streaming,    1.000 Msps, ...
```

and the status page carries both:

```
Center frequency      868.300 MHz
Sample rate           1.000 MHz
Tuner B (dual mode)   868.400 MHz
```

Live Time drops to 16.7 % in dual mode against 33.3 % single. That is not a dual-mode defect: the
demodulator is reading 1 Msps per slot instead of 2, so it processes fewer complete slots on this
machine. Single-tuner mode remains the better default for ogn-rf; dual mode is for using the
second tuner.

### Code

The ring buffer became `RSPDuo_Ring`, one instance per tuner, each with its own lock, condition
variable and overrun count, so a slow reader on one cannot stall the other. `Read()` and
`ResetBuffer()` take a tuner index, defaulting to 0 (A). The unit test grew a dual-mode section
that feeds the A and B callbacks different patterns and confirms each is read back separately —
that is the check which would catch the channel-B reset being mishandled without hardware.

## Bring-up session 6 — decimation: the only way below 2 MHz

Asked whether the device decimates. It does, and checking properly turned up a real bug in my own
code.

### The ADC floor is hard

Asking the API for a sample rate below 2 MHz without decimation does not get snapped — it fails:

```
request 2000000 : rate 2.064 Msps delivered
request 1000000 : Init() failed: sdrplay_api_Fail
request  500000 : Init() failed: sdrplay_api_Fail
```

So decimation is not an optimisation, it is the only way to reach any rate below 2 MHz.

### Measured factors

`decimationFactor` takes powers of two up to 32. Delivered rate against a 2 MHz ADC:

| Factor | Expected | Measured | Ratio |
|---|---|---|---|
| 1 | 2.000 MSps | 2.044 | 1.02 |
| 2 | 1.000 MSps | 1.038 | 1.04 |
| 4 | 0.500 MSps | 0.515 | 1.03 |
| 8 | 0.250 MSps | 0.258 | 1.03 |
| 16 | 0.125 MSps | 0.126 | 1.01 |
| 32 | 0.0625 MSps | 0.063 | 1.02 |

### The bug this exposed

`SnapSampleRate()` returned the already-decimated output rate, but `Open()` assigned that to
`fsFreq.fsHz` and then divided by the factor again. Wrong twice: it programmed a sub-2 MHz ADC rate,
so `Init()` would have failed, and had it started it would have reported half the true rate. In
other words **every single-tuner sample rate below 2 MSps was broken**, and nothing in the 2 MSps
configuration we actually run exercised the path.

It now returns the ADC rate, and the delivered rate is that divided once by the caller. Verified
end to end: `RF.SampleRate = 1000000` runs at 1.000 Msps, where before it failed to start.

Worth recording as a lesson: the bug survived because the one configuration under test never
touched it. The unit test now pins the whole mapping — all six factors plus the 6 and 8 MHz rates —
so it cannot regress silently.

## Bring-up session 7 — the decimation ceiling, and a silent failure

Asked what the highest on-chip decimation is. I had previously written "up to 32" from convention —
the `while(Decimation<32)` cap in my own code — rather than from measurement. Measuring it gave a
better answer and a genuine trap.

**The ceiling is 32.** A factor of 33 or above makes `sdrplay_api_Init()` fail outright
(`sdrplay_api_Fail`), confirmed at 33, 40, 48, 64, 128 and 256.

**Only powers of two do anything.** The API accepts 3, 5, 6, 7, 12, 24 without complaint and then
delivers the full 2 MHz anyway — no error, no warning, no decimation:

| Factor | Expected | Delivered | Verdict |
|---|---|---|---|
| 2 | 1.0000 | 1.026 | applied |
| 4 | 0.5000 | 0.508 | applied |
| 6 | 0.3333 | 2.077 | **silently ignored** |
| 7 | 0.2857 | 3.311 | **silently ignored** |
| 8 | 0.2500 | 0.258 | applied |
| 16 | 0.1250 | 0.129 | applied |
| 32 | 0.0625 | 0.063 | applied |
| 33 | — | — | Init fails |

So the check is on *range*, not on *form*: anything up to 32 is accepted, only powers of two take
effect, above 32 is rejected. That asymmetry is the dangerous part — a factor of 6 looks like it
worked, because nothing anywhere reports that it did not.

`SnapSampleRate()` only ever produces powers of two, so the backend cannot reach the silent case.
Anything driving the API directly can, which is why the probe's `-d` now takes any value and reports
the delivered rate rather than trusting the factor asked for.

### A measurement artefact worth remembering

Asking for a short capture (40 000 samples) at a high factor produced no rate reading at all,
because the whole capture arrived in one or two callbacks and the span between first and last was
effectively zero. The rate figure only means anything when the capture spans enough callbacks to
time, so the sweeps above size the capture to the factor (roughly 1.5 M samples divided by the
factor, floored at 150 k). The first sweep, which used a fixed 40 k samples, mislabelled the
non-power-of-two runs as "no reading" for exactly this reason.

## Bring-up session 8 — 32x cannot give 1 MSps, but 1 MSps on both channels does work

Asked whether 32x decimation can give 1 MSps from both channels at once. The two halves have
opposite answers.

**32x and 1 MSps are mutually exclusive.** 32x of the 2 MHz ADC is 62.5 ksps. To reach 1 MSps at 32x
you would need a 32 MHz ADC, and the device's maximum is 8 MHz — which at 32x is 250 ksps. There is
no setting anywhere that combines them.

**1 MSps on both channels at once is not only possible, it is what dual-tuner mode already does** —
and with a factor of 2, not 32:

```
tuning      :   868.200 MHz, 1.000 MSps   (tuner A)
tuner B     :   868.400 MHz
rate        : 1.003 Msps delivered  (tuner A)
rate        : 1.003 Msps delivered  (tuner B)
```

Both tuners, 2 000 000 samples each, simultaneously. Dual mode does not use the caller's
`decimationFactor` at all: the API derives it from the combination of ADC rate, bandwidth and IF, so
it is 2 (1 Msps), 3 (2 MSps from a 6 MHz ADC) or 4 (500 ksps or 2 Msps depending on the ADC rate),
and can never be 32.

### New measurement: the higher ADC rates under-run on this USB link

Testing 6 and 8 MHz as part of this question turned up something worth knowing:

| ADC rate | Requested | Delivered | Shortfall |
|---|---|---|---|
| 2 MHz | 2.000 | 2.076 | none |
| 6 MHz | 6.000 | **3.768** | 37 % |
| 8 MHz | 8.000 | **5.480** | 32 % |

The RSPduo is on a USB 2.0 bus shared with five RTL-SDR dongles, a LimeSDR and two hubs, so
6 and 8 MSps of raw I/Q (24 and 32 MB/s) simply do not fit; the stream silently under-runs. The
shortfall propagates through decimation rather than being absorbed by it, which is the part that
would catch someone out: 8 MHz at 32x should give 250 ksps and delivers **168 ksps**, because the
decimator is fed by the data that actually crossed the bus (5.480 / 32 = 0.171).

So the practical ceiling on this machine is the 2 MHz ADC rate, which is what both the single-tuner
and dual-tuner configurations use.

## Bring-up session 9 — the decimation is NOT on the chip

Asked to check that on-chip decimation is not possible. It is worse than that: everything I wrote
about decimation happening "on chip" was an assumption, repeated across this repository and the
rspduo branch, and it is **wrong**. Two independent measurements contradict it.

### Evidence 1: the daemon's CPU does not care about the factor

`sdrplay_apiService` is the process that owns USB. If the chip decimated, the daemon would receive
32x fewer samples at factor 32 and its work would collapse. Over ten-second windows, idle accounted
for:

| | Delivered | Daemon CPU (net of idle) |
|---|---|---|
| factor 1 | 2.004 Msps | 0.61 s |
| factor 32 | 0.063 Msps | 0.56 s |

32x less output, the same work. The daemon is handling the same volume of samples either way.

### Evidence 2: an under-running ADC rate is not rescued by the factor

At an 8 MHz ADC, the bus cannot sustain the stream and delivers 5.48 Msps instead of 8. With a
factor of 32 the arithmetic says 250 ksps. Measured: **168 ksps**. That is 5.48 / 32 = 0.171 — the
stream is limited at full rate *before* the factor is applied, which cannot happen if the chip were
producing a decimated 250 ksps stream that needed only 1 MB/s of USB.

### What this means

- **Decimation does not save USB bandwidth.** The full-rate stream still crosses USB; only the rate
  handed to the client shrinks. It cannot be used to relieve a contended bus.
- It also cannot recover the shortfall of an under-running ADC rate.
- The rate reduction happens after the USB link, in the host-side API software.

What would settle it beyond doubt is a USB-level capture: `modprobe usbmon` then `tcpdump -i
usbmon0`, which needs root. That would show directly whether 32x decimation drops the traffic from
8 MB/s to 0.25 MB/s. It has not been done here.

### Correction applied

The words "on chip" have been removed from `docs/hardware.md`, the probe's messages, `docs/rspduo.md`
and the comments in `rspduo.h`. The behaviour of every measurement above stands unchanged — only the
explanation of where the decimation happens was wrong.

### Also worth recording: a receiver artefact mistaken for a signal

Chasing the aliasing test turned up a mistake of my own. A strong peak at **-408.2 kHz** appeared in
every wideband capture, and I read it as an FM broadcast station and cited "+33.9 dB over the noise
floor" as proof the receive chain worked. Retuning the centre frequency moved the peak with it — it
is a **fixed offset artefact of the receiver, not a station**.

So the claim in session 4 that "the chain receives real RF, proven by FM broadcast at 100 MHz" is not
supported by that evidence. What is still solid there is narrower: the tuner changes what it hears
when retuned, and the two tuners demonstrably receive different things. Whether anything on the air
is being received at all is not established by the -408 kHz peak.

## Bring-up session 10 — what is actually inside the box, and open drivers

Asked to research the RSPduo's internals and whether a different driver could decimate on-chip.
Sources: the vendor datasheet and introduction PDFs, the SDRplay hardware-API page, and the open
Mirics drivers.

### The silicon

From the vendor's own [RSPduo datasheet](https://sdrplay.com/wp-content/uploads/2026/06/RSPduo_Datasheet.pdf)
and the [RSPduo Introduction](https://storage.eleshop.eu/files/RSPduo-Introduction-V3.pdf):

- The radio front end is the **Mirics MSi2500**, which contains **two 14-bit ADCs**, with two
  independent tuners piped through a single USB 2.0 interface.
- **Zero IF** uses *both* ADCs, one for I and one for Q, and reaches up to 10 MHz of displayed
  bandwidth.
- **Low IF** uses *one* ADC per tuner — which is the only way both tuners can run at once. In the
  vendor's words, dual-tuner operation is "ONLY POSSIBLE IF BOTH TUNERS ARE OPERATING IN LOW IF
  MODE", and in Low IF the maximum flat passband is 1.536 MHz.
- ADC resolution depends on the sampling rate: **14-bit at 6 MHz and below, 12-bit at 8 MHz.**

This explains, from the vendor's own documentation, three things that until now were only empirical
observations here: why `IF_Zero` is rejected in dual mode, why dual-mode bandwidths stop at
1.536 MHz, and why dual mode caps at 2 MSps per tuner.

### Decimation: unresolved, and I have now claimed both answers

The `sdrplay_apiService` binary carries register-level decimation controls — `decimateControl`,
`DecimateOutScale`, `DecimateRound[0]`/`[1]` (logged as 32-bit hex register values) — alongside GPIO
and tuner-channel register calls (`GpioDualExtWrite()`, `rspDuoTunerChannelConfig`). That implies a
hardware decimator.

Against that, the daemon also contains 2541 NEON-register operands and 67 vector instructions, so
host DSP is not excluded either, and the CPU/8 MHz measurements in session 9 suggested the limit
applies before the factor. An earlier commit here asserted "no SIMD" on the strength of a grep that
did not match AArch64 syntax — that claim was wrong and has been removed.

Settling it needs `usbmon` (root): whether 32x drops the traffic from 8 MB/s to 0.25 MB/s.
Until then `docs/rspduo.md` marks "decimation does not save USB bandwidth" as unverified.

### Open drivers, and whether a different one could help

Three relevant projects:

- [libmirisdr-5](https://github.com/ericek111/libmirisdr-5) — an open driver for MSi2500/MSi001
  based SDRs. **Contains no decimation support at all** (`\bdecim` matches zero times).
- [Linux `drivers/media/usb/msi2500/msi2500.c`](https://github.com/torvalds/linux/blob/master/drivers/media/usb/msi2500/msi2500.c)
  — the in-tree driver, also with no decimation. But it exposes the MSi2500's ADC rate as
  programmable from **1.2 MHz to 15 MHz**, which is a much wider range than the 2/6/8 MHz the
  SDRplay API allows. An open driver could therefore pick a low rate *natively* instead of
  decimating to it — which would sidestep the 2 MHz floor entirely.
- [cybermunkeh/msi001-control-lab](https://github.com/cybermunkeh/msi001-control-lab) — active
  reverse engineering of MSi001/MSi2500 register control, with `MSi001_registers.md` and
  `MSi2500_transfer_verification.md`. The most likely place for the decimator registers to be
  documented by someone.

The running kernel here has no `msi2500` module (`modinfo msi2500` fails), so none of this is
presently usable on the box.

## Bring-up session 11 — are the two tuners phase-coherent?

Relevant to anyone thinking of using two antennas on the two receivers. Both tuners were pointed at
the same frequency (868.3 MHz) and the two I/Q streams compared over one second:

```
zero-lag correlation |rho| = 0.1625   phase = +116.7 deg
per-block |rho| : mean 0.1628  min 0.1554  max 0.1720
per-block phase : mean +116.6  std 3.8 deg  spread 13 deg
block phases    : +116 +114 +114 +115 +111 +116 +115 +118 +124 +123
```

**The two receive chains are phase-coherent.** The phase offset is a constant ~117 deg that moves
only 13 deg over a second, and the correlation magnitude is equally steady. So coherent combining
across the two tuners is physically possible, after calibrating out that fixed offset — the shared
ADC clock makes this work, which is exactly what the vendor's introduction describes as the one
thing dual-tuner mode cannot separate.

|rho| of 0.16 is the interesting number: the two chains are seeing mostly *independent* noise with
only a small common component. That is good news for combining (two independent noise sources, one
correlated signal is the best case for maximal-ratio combining) and it also means neither tuner is
merely an echo of the other.

Not established: whether the *external* noise seen by two separate antennas is correlated. That
depends on the antennas and their spacing, not on the receiver, and it decides how much diversity
gain is actually available.

## Bring-up session 12 — selection diversity implemented

Asked for λ/2 vertical spacing and selection diversity. Both tuners now run on one frequency and
the backend hands ogn-rf whichever saw more signal.

| | |
|---|---|
| Wavelength at 868.3 MHz | 34.5 cm |
| **λ/2 (vertical spacing to use)** | **17.3 cm** |
| Decision metric | strongest 1024-sample block (1 ms), not the window mean |
| Hysteresis | 1 dB |
| Both tuners on | 868.300 MHz |
| Measured result | A 5 / B 0 selections, Live Time 18.2 % |

### Why the mean would have been wrong

An OGN packet is a burst a few ms long inside an 0.85 s window. Averaging power over the whole
window measures mostly noise, so the selection would have been deciding on nothing. The metric
takes the strongest 1 ms block instead.

### A bug I introduced and then found

The rings were sized at 0.5 s of samples but ogn-rf reads 0.85 s. Because the two rings are
drained sequentially — A blocks for its window while B is still filling — B overflowed its ring on
every single read and had to be waited for again from scratch. Measured: 2 reads in 22 s, 9.1 %
Live Time. Sizing the rings to 2 s fixed it: 18.2 %, which matches the plain dual-mode baseline,
so the diversity overhead is now negligible.

The general lesson is the one that keeps recurring here: a ring must hold a full reader window, and
with two readers that window is effectively doubled.

### Verified, and what is not

The selection logic is covered by the unit test — the two callbacks are fed different amplitudes and
the chosen stream is checked to be the loud one, then the roles are swapped. 51 checks pass.

On the actual hardware tuner A wins every time. That is consistent with an antenna on tuner A's port
only, which is the expected result rather than a fault — but it does mean real diversity gain has
not been demonstrated, because that needs two antennas and a fade to observe. Vertical spacing of
17.3 cm is the recommended arrangement; horizontal λ spacing should be avoided, since a two-element
array at d = λ has lobes at broadside *and* endfire and nulls at ±30°.

## Bring-up session 13 — settled: 1 MSps, both tuners, one frequency, sample-aligned

Final configuration, and one check I had not made before. Both tuners were pointed at 868.300 MHz
and the two I/Q streams cross-correlated over 400 000 samples:

```
tuning      :   868.300 MHz, 1.000 MSps
tuner B     :   868.300 MHz
captured    : 400000 samples (each)
best lag    : +0 samples (0.0 us) with |rho| = 0.3714
zero-lag    : 0.3714   (same, so the peak really is at lag 0)
```

**The two streams are sample-aligned at lag 0.** Not merely sharing a clock — the same sample index
in one stream corresponds to the same instant in the other. That is what coherent processing needs,
and it was an assumption until now.

Combined with the earlier phase measurement (+116.6 deg, stable to +-3.8 deg over a second), the
pair is a genuinely coherent two-channel receiver: aligned in time, locked in phase, offset by a
constant that can be calibrated out.

### The settled configuration

```ini
RF = {
  DeviceType = "rspduo";
  SampleRate = 2000000;                    // ADC rate; the API's fixed dual combination then
                                           // gives bw 600 kHz, IF 450 kHz, decimation 2
  RSPduo = {
    DualTuner          = 1;                // both tuners, 1.000 Msps each
    SelectionDiversity = 1;                // and both on the SAME frequency
  };
};
```

`SelectionDiversity = 1` is what pins tuner B to tuner A's frequency; without it tuner B sits at
+100 kHz on the neighbouring OGN channel.

### The cost, stated plainly

Dual mode gives 600 kHz of bandwidth per tuner instead of 1536 kHz, and Live Time measured 18.2 %
against 33.3 % for single-tuner. That is the price of two coherent 1 MSps channels rather than one
2 MSps channel, and it is a real one on a quiet band.

## Bring-up session 14 — sample rate does NOT fix slot coverage

Twice I suspected ogn-rf's poor Live Time was a CPU/throughput problem that a lower sample rate
would fix. Measured properly, single-tuner, identical otherwise:

| SampleRate | Live Time | half-slot msgs | dropped |
|---|---|---|---|
| 2000000 | 21.1 % | 22 | 20 |
| 500000 | 21.1 % | 22 | 20 |

**Identical.** A 4x reduction in sample rate changed nothing, so the limitation is not sample
processing throughput. It is something in ogn-rf's slot/queue timing that is independent of rate
(and it varies run to run with machine load: 21-33 % across sessions, the same range the LimeSDR
shows).

Practical consequence: **decimation is not a lever for slot coverage**, so there is no reason to
trade bandwidth for it. That removes the main argument for running below 2 MSps in single-tuner
mode.

## Bring-up session 15 — LNAs and 868 filters fitted

Two antennas with an amplifier and an 868 MHz band filter each. Measured at gRdB 30, 2 MSps:

| | rms (int16) | dBFS |
|---|---|---|
| 868.300 MHz **before** LNA | 263.7 | −41.9 |
| 868.300 MHz **after** LNA | **889.6** | **−31.3** |

**+10.6 dB**, so the amplifiers are working and are now first in the chain, which is where they
help: they set the system noise figure, and everything after them (including the RSPduo's own front
end) contributes less.

### The crest factor collapsed, which suggests compression

| | peak | rms | crest |
|---|---|---|---|
| before | 5942 | 263.7 | 22.5 (27 dB) |
| after | 7751 | 889.6 | 8.7 (19 dB) |

The noise floor rose 10.6 dB but the peaks barely moved (2.3 dB). That asymmetry means the peaks
were already being limited, so the +10.6 dB went into the noise floor and not into the impulses.
No hard `ADC overload DETECTED` was raised at any gain setting, but the headroom at maximum gain is
now only about 3 dB rather than the 20 dB measured before the LNAs.

### The filter could not be tested this way

Levels at other frequencies are essentially the same as in band:

| 868.300 | 100.000 | 433.920 |
|---|---|---|
| −31.3 dBFS | −33.6 dBFS | −31.4 dBFS |

That is **not** evidence the filters are ineffective. With no signal present at any of those
frequencies, every reading is just the amplified noise floor, which is frequency-independent, so the
comparison carries no information about rejection. Proving the filters work needs a known strong
out-of-band signal — a nearby FM broadcast carrier, or a signal generator — and a before/after level
comparison at that frequency.

### Gain advice

`RF.OGN.Gain = 95` still measures 86 of 128 counts (7.4 bits) at maximum gain with no clipping, so
it remains a sane setting — but it now has ~3 dB of headroom instead of ~20 dB. If a strong local
transmitter appears, cut the gain rather than waiting for the overload flag, since the impulses
compress before the flag trips.

## Bring-up session 16 — first real signal, and the real bottleneck

### An aircraft overhead produced actual bursts

Four seconds of 1 MSps data, block-averaged at 1 ms:

| | median block power | peak | peak above median |
|---|---|---|---|
| Tuner A | 1.6 | 6.2 | +6.0 dB |
| Tuner B | 15.4 | 163.4 | **+10.3 dB** |

Bursts clustered at slot-like times (0.071, 0.751, 0.911, 3.631, 3.771, 3.791 s), Tuner B consistently
~5 dB above Tuner A on them. **The first confirmed real signal in the whole exercise.**

Crucially, inter-tuner |rho| **rises** during the bursts:

| | \|rho\| |
|---|---|
| quietest 50% of blocks | 0.432 |
| **loudest 0.5% of blocks** | **0.661** |

That is the signature of a common external signal rather than independent noise, which is what
distinguishes "signal present" from "noise wandering". It also says something about the diversity:
0.66 is fairly correlated, as expected for an aircraft overhead where the direct path dominates.
Diversity should earn its keep at LOW elevation, not overhead.

### Live Time is not a throughput limit either

`RF.OGN.SensTime` was 0.85 s. Swept it:

| SensTime | Live Time | half-slots | dropped |
|---|---|---|---|
| 0.85 | 18.8 % | 3 | 1 |
| 0.45 | 25.0 % | 8 | 6 |
| 0.25 | 25.0 % | 9 | 7 |

It improves once and then **plateaus at 25 %**, so the amount read is not the constraint. Reading
less does not help, which points at the acquisition loop missing slot boundaries: the outer loop
only reads when `WaitTime < 0.200`, and when an iteration overruns a second that gate skips the
slot outright rather than catching up.

**Deliberately left at 0.85.** Lowering it raises the Live Time *metric* while cutting actual
listening time from 0.85 s per second to 0.45 s, so the "improvement" is partly the metric being
computed over shorter reads rather than more packets caught. A higher number that hears less is not
progress.

### Also fixed: the receiver opened at maximum gain

The backend initialised gain to GR_DB_MIN and ogn-rf calls setTunerGain() only after Open(), so
every start streamed briefly at full gain. Harmless without an LNA, but with one in front it
overloaded the ADC — the first live run logged a burst of "ADC overload detected" at open. Now
starts mid-range.
