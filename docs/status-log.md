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
