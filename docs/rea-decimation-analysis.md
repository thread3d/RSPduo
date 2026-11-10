# What the vendor daemon actually does with the decimation factor

Static analysis of `sdrplay_apiService` (Ghidra 12.3 via REA), binary SHA-256
`6f66cea632d90bb3e39dbe8d042ed986ff9931bff7c36d4546c6806edaa46107`, the aarch64 daemon
installed by `SDRplay_RSP_API-Linux-3.15.2.run`. This is inspection of a binary running on the
licensed machine; no vendor code is reproduced here.

## The question

Repeatedly wrong about this earlier: is the decimation applied in the RSPduo's silicon, or by the
host software? The `usbmon` test that would settle it needs root, so it went unanswered.

## What the decompilation shows

### 1. The configuration handler, `FUN_0010ca20`

Called once per tuner (`1 << tuner` bitmask: bit 0 = A, bit 1 = B). It reads a per-tuner block and
takes three bytes: `enable` at +0x4a, `factor` at +0x4b, `wideBandSignal` at +0x4c.

**The factor is validated by a bitmask test:**

```c
if ((0x1e < (byte)(factor - 2)) ||
    ((0x40004045UL >> ((factor - 2) & 0x3f)) & 1) == 0) goto zero_it;
```

`0x40004045` has bits **0, 2, 6, 14, 30** set, so `factor - 2` must be one of those, i.e. the only
accepted factors are **2, 4, 8, 16, 32**.

That is an exact, mechanism-level explanation of the behaviour measured on hardware: factors 3, 5, 6,
7, 12, 24 are accepted without complaint and do nothing, because they fail this test and jump to a
path that sets `OutScale = 0` and `Round[0] = Round[1] = 0` — decimation simply disabled, with no
error raised.

It also derives, for factor N:

| field | value |
|---|---|
| `OutScale` | `log2(N)` — 1, 2, 3, 4, 5 |
| `Round[0]` | `+2^(OutScale-1)` = `+N/2` |
| `Round[1]` | `-N/2` |

### 2. The function it calls, `FUN_001189a0`

Contains **no sample arithmetic at all**. Its whole job is to size the USB transfer pipeline:
it computes `NumActivePackets` — the number of in-flight transfers — as `4x` for factors 2 to 16 and
`8x` for factor 32, taking the maximum across both tuners, then logs `NumActivePackets = %d`.

So the decimation setting's *only* direct effect visible in this path is to change how many USB
buffers the host keeps outstanding.

### 3. The daemon can write device registers, but does not do so here

It imports `libusb_control_transfer` alongside `libusb_bulk_transfer` and `libusb_submit_transfer`.
Register writes are therefore available — but the decimation configuration path reaches neither.

## Conclusion, and its confidence

`OutScale = log2(N)` with `Round = +-N/2` is what a **software boxcar average** looks like: a
right-shift by `log2(N)` and a round-half-up offset of `N/2`, i.e. `out = (sum + N/2) >> log2(N)`.
It is not what a hardware decimator register map looks like.

Weighing that against everything else gathered:

| Evidence | Points to |
|---|---|
| `OutScale`/`Round` are shift and rounding constants | host software |
| No device write anywhere in the decimation path | host software |
| Daemon CPU unchanged at factor 1 vs 32 (0.61 s vs 0.56 s for 32x the output) | host software |
| 8 MHz ADC at factor 32 gives 168 ksps, matching bus-limited 5.48/32 | host software |
| The strings `decimateControl` / `DecimateOutScale` looked like register names | retracted — they are log tags, not registers |

**The decimation is applied in host software, not on the RSPduo silicon.** That is now the
well-supported reading, and it retracts the "on-chip" claim in the earlier documents.

## What is still not established

- **The summing loop itself has not been read.** The conclusion rests on the constants and the
  absence of a device write, not on an observed accumulation loop. The consumer of those fields is
  inside `FUN_0012b684` (530 instructions, 84 basic blocks, 49 callees), which has been sized but
  not decompiled. That is the single remaining step to make this observation rather than inference.
- **Nothing here says whether the MSi2500 has an unused hardware decimator.** This is a driver fact.
  Silicon capability needs a datasheet or register probing, not driver analysis.
- **Why `NumActivePackets` scales *up* with decimation is unexplained.** More output reduction
  producing more outstanding USB transfers is the opposite of what a device-side decimator would
  suggest, and is consistent with the host still receiving full-rate data and needing deeper
  buffering to decimate it — but that is a conjecture, not an observation.

## Reproducing

```bash
open_binary   rea-targets/sdrplay_apiService        # Ghidra 12.3
search_strings "decimat"                            # -> 0x130320, 0x130330, ...
xrefs          0x130330                             # -> 0x10cb48
procedure_pseudo_code FUN_0010ca20                  # the bitmask and the OutScale/Round derivation
procedure_pseudo_code FUN_001189a0                  # NumActivePackets only
```
