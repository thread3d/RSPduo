# The RSPduo, the API, and the measurements behind the choices

## The device

| | |
|---|---|
| Model | SDRplay RSPduo |
| USB ID | `1DF7:3020` — confirmed against `usb.ids` and the vendor's own `20-sdrplay.hwdb`, which maps `usb:v1DF7p3020*` to `RSPduo` |
| Tuners | two (A and B), `SDRPLAY_MAX_TUNERS_PER_DEVICE == 2` |
| ADC | 12-bit, reported as `int16` per sample |
| Tuner range | 1 kHz – 2 GHz |
| Analog bandwidths | 0.200, 0.300, 0.600, 1.536, 5.000, 6.000, 7.000, 8.000 MHz |
| Single-tuner sample rates | 2, 6, 8 MHz |
| Bias tee | **none** (the RSP2 and RSPdx have one) |

How the device enumerates from the host's point of view, before the API has done anything:

```
$ lsusb -d 1df7:3020
Bus 001 Device 013: ID 1df7:3020
  bDeviceClass 255 (Vendor Specific), 1 interface, 0 endpoints in alt setting 0
  iManufacturer 0, iProduct 0, iSerial 0   <- no strings until the API loads firmware
```

The empty string descriptors are normal and are *not* a fault: the RSP devices present themselves
as a bare vendor-specific class, and `libsdrplay_api` is what brings them to life. It also means
`lsusb` shows no product name until the vendor `hwdb` entry is installed.

## Why the native API rather than a SoapySDR wrapper

The LimeSDR backend here goes through SoapySDR, because SoapyLMS7 was already present and does a
good job. For the RSPduo the choice went the other way, for three reasons:

1. **All four reference implementations use the native API** — DuoTools, SDRduoDisplay,
   DuoDX-recorder and dual-tuner-recorder. They are the de facto documentation for the corners of
   this API, and matching them means their findings apply directly.
2. **No SoapySDRPlay module exists on this system.** SoapySDR 0.7.2 is installed with HackRF,
   LMS7, airspy, bladeRF, osmosdr, RedPitaya and rtlsdr support — but no SDRplay module. Using
   SoapySDR would mean building `SoapySDRPlay3` from source as an extra layer between ogn-rf and
   the same API the native path calls directly.
3. **Dual-tuner mode is only reachable through the native API.** It is not used by ogn-rf (see
   below), but the option stays open.

The cost is a direct dependency on `libsdrplay_api`, which is closed source but freely
redistributable for use with the vendor's hardware.

## The two operational facts that matter

### `sdrplay_api_Init()` resets channel B to channel A

From `dual-tuner-recorder`, at the point where it configures tuner B:

> since sdrplay_api_Init() resets channelB settings to channelA values

So in dual-tuner mode, channel B's `rfFreq`, `gain` and bandwidth must be written with
`sdrplay_api_Update()` **after** `Init()` returns. Configuring B before `Init()` silently produces
two tuners on the same frequency. This backend does not use tuner B, so the trap is dormant — but
it is recorded here because it is the first thing anyone extending this to dual tuners will hit.

### The API service is mandatory

`libsdrplay_api` is a client. `sdrplay_api_Open()` connects to `sdrplay_apiService` and returns
`sdrplay_api_ServiceNotResponding` if it is not there. The failure looks like a dead device, so
both `build-ogn-rf.sh` and `run-ogn-rf.sh` check `systemctl is-active sdrplay` up front, and
`rspduo_probe` explains the error rather than just printing it.

## Sample rate: why 2000000 and not 2048000

The RSPduo's ADC runs at 2, 6 or 8 MHz in single-tuner mode. ogn-rf's own default is 2048000 Hz,
which is an RTL-SDR rate and not obtainable here. Because the backend snaps a requested rate to the
nearest supported one, asking for 2048000 would produce a working radio at 2000000 — with the OGN
channels about 2 % away from where the frequency plan expects them. That is the kind of error that
looks like "no aircraft heard today" rather than a bug.

`SnapSampleRate()` therefore snaps and `Open()` prints what it applied, and the configuration asks
for 2000000 explicitly. Rates below 2 MHz are reached with the API's decimation factor rather than
by changing the ADC rate.

## The conversion scale, and how to settle it

`RTLSDR` hands ogn-rf interleaved 8-bit **unsigned** I/Q with 128 as zero. The RSPduo delivers
12-bit samples in `int16`. The backend does:

```c
Val = (xi[i] >> Shift) + 128;   // Shift = 8, clamped to 0..255
```

`Shift = 8` assumes the 12-bit samples are left-justified in the 16-bit word, so a full-scale
signal peaks near 32767. `rspduo_probe` measures exactly this and says so:

```
raw I       : min -30214  max  30198  mean    -0.31
peak        : 30214  (a full-scale 16-bit stream peaks near 32767)
shift 8     : samples look left-justified in 16 bits - consistent with shift 8
```

If instead the peak comes back near 2000, the samples are not left-justified and the shift belongs
at 4. `Shift` is a member of `RSPDuo`, not a constant, precisely so this can be corrected in one
place after measuring.

The measurement to run is a known-level signal — a signal generator into the antenna port is the
clean one, but a busy broadcast band works too, since what is being checked is the raw `int16`
range rather than an absolute level.

## Gain

The RSPduo has no discrete tuner gain table; the API describes gain as a pair:

- `gRdB` — IF gain *reduction*, 20–59 dB in the `NORMAL` range (`MAX_BB_GR` is 59)
- `LNAstate` — LNA step, 0 = most gain; the count is band dependent
  (`RSPDUO_NUM_LNA_STATES` 10 generally, 5 for the AM port, 7 for AM, 9 for L band)

`setTunerGain()` holds `gRdB` at 40 dB and picks the LNA state closest to the requested gain, then
republishes the gain table from the range the device itself reports (`gainVals.max` / `.min`). The
table is rebuilt on open and after every gain change because the LNA step size is band dependent.

AGC is explicitly disabled: ogn-rf owns the gain, and an AGC fighting it would make the pulse
filter's threshold meaningless.

## The overload event

`ClassEventCb` reports `sdrplay_api_PowerOverloadChange` but deliberately does not act on it.
Clearing an overload requires an `sdrplay_api_Update()` call with
`sdrplay_api_Update_Ctrl_OverloadMsgAck`, and calling `Update()` from the event callback thread is
not safe. For OGN this is the right trade: a momentary overload in a busy band is normal, and the
demodulator tolerates it. If the probe prints overload events continuously, the answer is to lower
the gain, not to acknowledge in the callback.

## DC offset and IQ imbalance correction

Left enabled (the API default), and made explicit in `Open()` so the behaviour is visible. The
correction notches a few kHz at the exact centre frequency, 868.300 MHz — which sits between the two
OGN channels, not on either of them, so it costs nothing. For pure spectrum work where an unmodified
centre matters, set `DcOffsetCorrect = 0`.
