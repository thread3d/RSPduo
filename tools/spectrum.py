#!/usr/bin/env python3
"""Averaged periodogram for a raw interleaved u8 I/Q capture.

Reads what rspduo_probe writes (-o out.u8): interleaved unsigned 8-bit I and Q with 128 as zero,
which is the same layout librtlsdr produces.

    python3 spectrum.py capture.u8 --rate 2000000 --freq 868300000

Prints the power at a set of offsets from the centre frequency, and the offset of the strongest
bin away from DC, which is what tells you whether the antenna is connected to anything.

With --plot, writes a PNG (needs matplotlib). Without it, only numpy is required.
"""

import argparse
import sys

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required:  python3 -m pip install --user numpy")


def load(path, max_samples):
    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size < 4:
        sys.exit("%s is too short to contain any samples" % path)
    if raw.size % 2:
        raw = raw[:-1]
    n = raw.size // 2
    if max_samples and n > max_samples:
        n = max_samples
    iq = raw[:2 * n].astype(np.float32) - 128.0
    # de-interleave
    return iq[0::2] + 1j * iq[1::2]


def periodogram(iq, rate, nperseg, overlap):
    """Welch-style averaged periodogram, in dBFS/Hz."""
    step = nperseg - overlap
    if iq.size < nperseg:
        nperseg = 1
        while nperseg * 2 <= iq.size:
            nperseg *= 2
        if nperseg < 16:
            sys.exit("capture too short for a spectrum (%d samples)" % iq.size)
        step = nperseg // 2

    window = np.hanning(nperseg).astype(np.float32)
    win_power = np.sum(window ** 2)
    acc = np.zeros(nperseg, dtype=np.float64)
    count = 0
    for start in range(0, iq.size - nperseg + 1, step):
        seg = iq[start:start + nperseg] * window
        spec = np.fft.fftshift(np.fft.fft(seg))
        acc += np.abs(spec) ** 2
        count += 1
    if count == 0:
        sys.exit("capture too short for a spectrum")

    acc /= count
    # normalise so a full-scale sine reads 0 dB, then express as density
    psd = acc / (win_power * 127.0 ** 2)
    psd /= (rate / nperseg)
    freqs = np.fft.fftshift(np.fft.fftfreq(nperseg, d=1.0 / rate))
    return freqs, 10.0 * np.log10(psd + 1e-30)


def main():
    ap = argparse.ArgumentParser(description="averaged periodogram of a raw u8 I/Q capture")
    ap.add_argument("path")
    ap.add_argument("--rate", type=float, default=2e6, help="sample rate in Hz (default 2e6)")
    ap.add_argument("--freq", type=float, default=868.3e6, help="centre frequency in Hz")
    ap.add_argument("--nperseg", type=int, default=4096, help="FFT size (default 4096)")
    ap.add_argument("--overlap", type=int, default=None, help="overlap samples (default nperseg/2)")
    ap.add_argument("--max-samples", type=int, default=8_000_000, help="cap on samples read")
    ap.add_argument("--plot", metavar="PNG", help="write a plot here (needs matplotlib)")
    ap.add_argument("--marker", type=float, action="append", default=None,
                    help="offset in kHz to report explicitly; may be repeated")
    args = ap.parse_args()

    overlap = args.nperseg // 2 if args.overlap is None else args.overlap
    iq = load(args.path, args.max_samples)
    freqs, psd = periodogram(iq, args.rate, args.nperseg, overlap)

    print("capture     : %s" % args.path)
    print("samples     : %d (%.3f s at %.3f MSps)" % (iq.size, iq.size / args.rate, args.rate / 1e6))
    print("centre      : %.3f MHz" % (args.freq / 1e6))
    print("noise floor : %.1f dBFS/Hz (median)" % float(np.median(psd)))

    # Ignore the middle bin, which is DC and therefore dominated by LO leakage and any DC
    # correction notch rather than by anything on the air.
    guard = max(1, int(0.002 * len(freqs)))
    mid = len(freqs) // 2
    mask = np.ones(len(freqs), dtype=bool)
    mask[mid - guard:mid + guard] = False
    strongest = np.argmax(np.where(mask, psd, -np.inf))
    print("strongest   : %+8.1f kHz at %.1f dBFS/Hz (%+.1f dB over the floor)" % (
        freqs[strongest] / 1e3, psd[strongest], psd[strongest] - float(np.median(psd))))

    # Report the OGN channels by default: 868.200 and 868.400 are +-100 kHz from 868.300.
    markers = args.marker if args.marker else [-100.0, 100.0]
    floor = float(np.median(psd))
    print("offsets     :")
    for off_khz in markers:
        # Read the bin at the offset actually asked for. Reporting the strongest bin within a
        # window instead would label a noise spike with a frequency nobody requested.
        idx = int(np.argmin(np.abs(freqs - off_khz * 1e3)))
        print("  %+8.1f kHz : %8.1f dBFS/Hz  (%.1f dB over floor)" % (
            off_khz, psd[idx], psd[idx] - floor))

    if args.plot:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
        except ImportError:
            sys.exit("matplotlib is required for --plot")
        plt.figure(figsize=(10, 5))
        plt.plot(freqs / 1e3, psd, linewidth=0.8)
        plt.xlabel("offset from %.3f MHz [kHz]" % (args.freq / 1e6))
        plt.ylabel("dBFS/Hz")
        plt.title("RSPduo periodogram")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(args.plot, dpi=120)
        print("plot        : %s" % args.plot)

    return 0


if __name__ == "__main__":
    sys.exit(main())
