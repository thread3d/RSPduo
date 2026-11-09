# How the RSPduo backend is wired into ogn-rf, and how to verify it

All source changes live in the `rspduo` branch of
[`thread3d/ogn-rf`](https://github.com/thread3d/ogn-rf). This document explains the shape of that
change, so the code can be reviewed without reading 700 lines of header.

## Where the branch sits

The branch is built on the multi-radio layer that the `limesdr` branch introduced, not on `master`.
That matters and is worth stating plainly:

```
master ──┬── krakensdr
         └── limesdr ──── rspduo
```

`master` has only `rtlsdr.h`, and ogn-rf.cc talks to the radio through it directly. The `limesdr`
branch added `sdr.h` — a selection layer that keeps the `RTLSDR` interface but dispatches to another
backend — and `limesdr.h`. Adding the RSPduo to that layer rather than duplicating it means one
abstraction with three implementations instead of two divergent copies of the same idea.

The consequence to be aware of: `rspduo` therefore also contains the LimeSDR commits. If this ever
goes upstream as an independent patch, it would need rebasing onto `master` with `sdr.h` carried
across.

## The changed files

| File | Change |
|---|---|
| `rspduo.h` | **new** — `class RSPDuo`, the backend (724 lines) |
| `sdr.h` | adds `RSP_DUO`, `HaveRSPDuo()`, `setRspDuoMode()`, and dispatch to `Rsp` in every method |
| `Makefile` | `USE_RSPDUO` → `-DUSE_RSPDUO -I$(RSPDUO_PREFIX)/include`, `-lsdrplay_api` |
| `ogn-rf.cc` | `RF.DeviceType = "rspduo"` parsing (via `getTypeByString`) |
| `docs/rspduo.md` | **new** — backend notes, in the ogn-rf tree |

`RF.DeviceType` accepts `rspduo`, `rsp-duo`, `sdrplay` and `duo`. A binary built without
`USE_RSPDUO` still accepts the config but falls back to RTL-SDR and prints why, so a stale binary
fails visibly rather than silently.

## The one structural decision: callback to blocking read

This is the whole design, and it is worth understanding before reading the code.

The SDRplay API is asynchronous:

```c
sdrplay_api_CallbackFnsT cbs;
cbs.StreamACbFn = StreamACb;        // called on the API's thread, with (short *xi, short *xq, ...)
sdrplay_api_Init(dev, &cbs, this);  // returns immediately, streaming begins
```

ogn-rf is synchronous. In `RF_Acq::Exec()`:

```c
SDR.ResetBuffer();
int Read = SDR.Read(*Buffer, SamplesToRead);    // must block until the samples exist
```

Note it is `SDR.Read()`, not `SDR.ReadAsync()` — ogn-rf drives the radio from its own loop. So the
backend has to convert one model into the other:

```
sdrplay_apiService (USB)
        │
        ▼
   API thread ──► StreamACb ──► convert to u8 ──► ring buffer (2 MiB)
                                                        │
   ogn-rf acquisition loop ──► Read() ──► drains ◄──────┘
```

`Read()` waits on a condition variable; the callback signals it. Three details in that bridge
matter:

- **Overrun.** If the ring is full, the callback discards the whole backlog and increments
  `Overflows` rather than delivering a torn buffer or silently overwriting. A torn buffer would
  corrupt the pulse filter's timing estimate.
- **Reset.** The API's `reset` flag means it restarted the stream (rate or tuner change). The queued
  samples belong to the old configuration, so the ring is flushed. Splicing them onto the new
  configuration would fabricate a continuous stream across two different frequencies.
- **Stop.** `CancelAsync()` sets `Stopped` and broadcasts, so a `Read()` blocked on an empty ring
  returns instead of hanging when the device goes away mid-read.

## Verification

Three levels, cheapest first. Each is designed to localise a failure rather than just report one.

### 1. Is the device and API healthy?

```bash
scripts/probe-rspduo.sh
```

Independent of ogn-rf entirely. Reports the API version, every device the service can see, and then
captures and reports statistics. Expected on success:

```
SDRplay API probe
=================
API version : 3.15 (headers 3.15)
devices     : 1
  #0 RSPduo     S/N 0000000000
tuning      :   868.300 MHz, 2.000 MSps, IF gain reduction 40 dB, LNA state 0
captured    : 2000000 samples
raw I       : min -30214  max  30198  mean    -0.31
shift 8     : samples look left-justified in 16 bits - consistent with shift 8
```

A failure here is a device, udev or daemon problem — not a receiver problem.

### 2. Is anything on the air?

```bash
scripts/probe-rspduo.sh -o /tmp/868.u8
tools/spectrum.py /tmp/868.u8 --rate 2000000 --freq 868300000
```

`spectrum.py` reports the noise floor, the strongest offset, and the two OGN channels by default.
The script itself is verified against a synthetic capture: a tone placed at +100 kHz is reported at
`+100.1 kHz, 68.4 dB over the floor`, with `-100.0 kHz` sitting at the floor. So a correct-looking
result means the analysis is right; whether anything is *on* 868 MHz is a property of the antenna
and the neighbourhood.

If both channels are quiet, the floor is the antenna, not the radio — the LimeSDR work on this same
site measured the 868 band as quiet with both OGN channels within half a dB of the noise floor.

### 3. Does ogn-rf run on it?

```bash
scripts/build-ogn-rf.sh
scripts/run-ogn-rf.sh
```

Then `http://xavieragx.local:8095/` should show `DeviceType = RSPduo`, a centre frequency of
868.200/868.400 MHz depending on the time slot, and 2.000 MHz sample rate.

Two traps make a working ogn-rf look dead, both handled by `run-ogn-rf.sh`:

- **stdin.** `main()` breaks out of its command loop on EOF from stdin. Under nohup, a service
  manager, or plain `< /dev/null`, ogn-rf exits immediately having received nothing. The script
  keeps stdin open with `sleep infinity |`.
- **stdout buffering.** When stdout is a pipe or file it is block-buffered, so a kill throws away
  the log. `stdbuf -oL -eL` fixes it.

Watch for `Half time slot` in the log — that means the demodulator is not keeping up, and the fix is
`RF.OGN.SensTime` or a faster host, not a radio setting.

## What "working" will and will not prove

Running cleanly proves the radio, the API, the conversion, the rate and the timing are all right.
It does **not** prove OGN decoding, because that needs a transmitter in range. On-site, the 868 MHz
band has previously measured as quiet, so a correctly-working receiver can legitimately show no
aircraft — exactly the state the LimeSDR work ended in.
