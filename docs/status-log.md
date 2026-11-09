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
