#!/usr/bin/env python3
"""
Generate Siri-style PTT beep sounds (WAV).
- start: single short beep (listening)
- send:  three short beeps (processing/sending)
- error: low two-tone "cancel" sound (failure/empty)

Writes to REPO/ptt-beeps/ (or path given as first arg).
"""
import math
import struct
import sys
from pathlib import Path

SAMPLE_RATE = 44100


def write_wav(path: Path, samples: list[float]) -> None:
    """Write float samples (-1..1) as 16-bit mono WAV."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        # WAV header
        n = len(samples)
        data_size = n * 2
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        for s in samples:
            x = max(-1, min(1, s))
            f.write(struct.pack("<h", int(x * 32767)))


def sine(freq: float, duration_sec: float, volume: float = 0.4) -> list[float]:
    n = int(SAMPLE_RATE * duration_sec)
    return [
        volume * math.sin(2 * math.pi * freq * i / SAMPLE_RATE)
        for i in range(n)
    ]


def silence(duration_sec: float) -> list[float]:
    n = int(SAMPLE_RATE * duration_sec)
    return [0.0] * n


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "ptt-beeps"
    out_dir = out_dir.resolve()

    # Single beep — "listening" (Siri-style: one short tone)
    start = sine(523, 0.14, 0.35)
    write_wav(out_dir / "ptt-start.wav", start)

    # Triple beep — "searching / sending"
    beep = sine(523, 0.11, 0.35)
    gap = silence(0.07)
    send = beep + gap + beep + gap + beep
    write_wav(out_dir / "ptt-send.wav", send)

    # Error / cancel — descending two-tone (obvious "nope" sound)
    err_hi = sine(440, 0.1, 0.4)
    err_lo = sine(220, 0.2, 0.38)
    error = err_hi + silence(0.05) + err_lo
    write_wav(out_dir / "ptt-error.wav", error)

    print(f"Generated PTT beeps in {out_dir}:")
    print("  ptt-start.wav  — single beep (listening)")
    print("  ptt-send.wav   — beep beep beep (sending)")
    print("  ptt-error.wav  — cancel sound (failure/empty)")


if __name__ == "__main__":
    main()
