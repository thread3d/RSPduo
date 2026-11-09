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
