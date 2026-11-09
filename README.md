# RSPduo on the XavierAGX — OGN receiver backend

Working repository for getting an **SDRplay RSPduo** to act as the radio for
[`ogn-rf`](https://github.com/thread3d/ogn-rf), the Open Glider Network RF front end. It holds the
tooling, the measurements and the notes; the source changes themselves live in the `rspduo` branch
of the ogn-rf repository.

Hardware: an RSPduo plugged into `xavieragx.local` (Jetson AGX Xavier, aarch64, Ubuntu 20.04).
Target use: receive the European OGN channels at 868.200 / 868.400 MHz.

## Why this radio is different

Three properties of the RSPduo shape everything here, and none of them apply to the RTL-SDR or
LimeSDR work:

1. **It is a daemon client.** `libsdrplay_api` is a client library; every hardware access goes
   through `sdrplay_apiService`, which runs as root under systemd. Nothing opens USB directly. So
   the API has to be installed system-wide, and the daemon has to be running.
2. **Its API is callback-driven.** Samples arrive on the API's own thread. ogn-rf reads
   synchronously, so the backend bridges the two with a ring buffer.
3. **Its ADC produces 2, 6 or 8 MHz and nothing else** in single-tuner mode. An RTL-SDR-style
   2048000 Hz is not available; asking for it gets silently snapped.

## Status

| Item | State |
|---|---|
| Device identified | **confirmed** — USB `1DF7:3020` is the RSPduo |
| SDRplay API installer | **written and verified** — SHA512 matches the upstream Arch package |
| SDRplay API installed | **pending** — needs root; see below |
| `rspduo` backend for ogn-rf | **written, compiles clean** (`-Wall -Wextra`, zero warnings) |
| Backend committed and pushed | **yes** — `thread3d/ogn-rf`, branch `rspduo` |
| Conversion scale (`Shift = 8`) | **to be measured** — `rspduo_probe` reports what settles it |
| ogn-rf runs on the RSPduo | **pending** the API install |
| Live OGN packet decoding | **not yet** — needs a transmitter in range, as with any OGN receiver |

The chain up to "compiles and is wired in correctly" is done. What remains needs the API installed,
which is one command (below), and then a measurement.

## Quick start

One command does the install and the whole verification, and leaves a report:

```bash
sudo ~/projects/RSPduo/rspduo/scripts/bootstrap-rspduo.sh
cat ~/rspduo-bootstrap-report.txt
```

That is the recommended path. Only the install needs root, so the script drops back to your user
for every check afterwards — which is also how ogn-rf really runs, as a normal user talking to the
daemon rather than as root. The steps below are the same thing done by hand.

```bash
# 1. install the SDRplay API (root - the daemon and the udev rule need it)
sudo ~/projects/RSPduo/rspduo/scripts/install-sdrplay-api.sh

# 2. is the device alive? This is independent of ogn-rf.
~/projects/RSPduo/rspduo/scripts/probe-rspduo.sh -o /tmp/868.u8
python3 ~/projects/RSPduo/rspduo/tools/spectrum.py /tmp/868.u8 --rate 2000000 --freq 868300000

# 3. build ogn-rf with the RSPduo backend
git clone https://github.com/thread3d/ogn-rf.git ~/projects/RSPduo/ogn-rf
cd ~/projects/RSPduo/ogn-rf && git checkout rspduo
~/projects/RSPduo/rspduo/scripts/build-ogn-rf.sh

# 4. run the receiver
~/projects/RSPduo/rspduo/scripts/run-ogn-rf.sh
# then browse to http://xavieragx.local:8095/
```

## Why the API install needs root

The RSPduo's USB node is `root:root` mode `0664`, so nothing can open it without root, and the
vendor's design puts the privileged part in a daemon on purpose. The install writes:

| Path | What |
|---|---|
| `/opt/sdrplay_api/sdrplay_apiService` | the daemon (runs as root) |
| `/usr/local/lib/libsdrplay_api.so.3.15` | client library + `.so.3` / `.so` links |
| `/usr/local/include/sdrplay_api*.h` | API headers |
| `/etc/udev/rules.d/66-sdrplay.rules` | makes the `1df7` USB nodes accessible |
| `/etc/udev/hwdb.d/20-sdrplay.hwdb` | so `lsusb` names the model |
| `/etc/systemd/system/sdrplay.service` | starts the daemon at boot |

`scripts/install-sdrplay-api.sh` does what the vendor's `install_lib.sh` does, but
non-interactively and idempotently, and it verifies its own result instead of assuming. The one
thing it deliberately does not do is delete another package's `66-mirics.rules`.

## What is in here

```
rspduo/
├── README.md                      this file
├── config/
│   └── ogn-rf-rspduo.conf         ogn-rf configuration for the RSPduo
├── docs/
│   ├── hardware.md                the device, the API, and the measurements behind the choices
│   └── ogn-rf-integration.md      how the backend is wired in, and how to verify it
├── scripts/
│   ├── bootstrap-rspduo.sh        install + verify the whole chain in one sudo command
│   ├── install-sdrplay-api.sh     install the vendor API without the interactive installer
│   ├── build-ogn-rf.sh            build ogn-rf with USE_RSPDUO
│   ├── run-ogn-rf.sh              run it (handles the traps that make it look dead)
│   └── probe-rspduo.sh            standalone receive checker, no ogn-rf involved
├── src/
│   └── rspduo_probe.c             the checker: device info, capture statistics, I/Q dump
└── tools/
    └── spectrum.py                averaged periodogram for the captured I/Q
```

## Key numbers

| Quantity | Value | Source |
|---|---|---|
| USB ID | `1DF7:3020` | `usb.ids` / `lsusb`, and the vendor hwdb |
| API version | 3.15 | vendor payload, matches `SDRPLAY_API_VERSION` in the headers |
| Single-tuner sample rates | 2, 6, 8 MHz | API, enforced by `SnapSampleRate()` |
| OGN channels (Europe) | 868.200 / 868.400 MHz | 100 kHz either side of a 868.300 centre |
| Analog bandwidth used | 1.536 MHz | widest filter below a 2 MSps stream |
| Conversion | `(x >> 8) + 128`, clamped | same as the LimeSDR backend; measured by the probe |
| Ring buffer | 2 MiB = 1 M samples | 0.5 s at 2 MSps, absorbs scheduling jitter |

## Notes on the reference implementations

The RSPduo-specific behaviour here was cross-checked against
[DuoTools](https://github.com/msiner/DuoTools),
[SDRduoDisplay](https://github.com/lrizio/SDRduoDisplay),
[DuoDX-recorder](https://github.com/45south/DuoDX-recorder) and
[dual-tuner-recorder](https://github.com/fventuri/dual-tuner-recorder). Two findings from that
reading are recorded in `docs/hardware.md`: the `sdrplay_api_Init()` channel-B reset, and the fact
that all four tools use the native API rather than a SoapySDR wrapper — which is why this backend
does too.
