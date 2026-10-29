"""Murmur's start and stop cues: short, bright pops synthesized locally, no samples.

Start rises (a bubble popping up), stop falls back down. Each pop is a fast
pitch glide with a 2 ms attack, a soft tone an octave below for body, and a
quick decay, so it reads as a crisp "pop" even at low volume.
Run: python3 Tools/GenerateSounds.py Resources
"""
import math
from pathlib import Path
import struct
import sys
import wave

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
sample_rate = 44100

# (start Hz, end Hz, offset s, length s, gain)
cues = {
    "start": [(520, 780, 0.000, 0.10, 0.55), (780, 1170, 0.060, 0.12, 0.50)],
    "finish": [(1170, 780, 0.000, 0.10, 0.50), (780, 520, 0.060, 0.13, 0.55)],
}

for name, pops in cues.items():
    count = int(0.21 * sample_rate)
    samples = [0.0] * count
    for start_hz, end_hz, offset, length, gain in pops:
        phase = 0.0
        first = int(offset * sample_rate)
        for index in range(int(length * sample_rate)):
            p = index / sample_rate
            progress = p / length
            # Glide fast at first, then settle: a pop, not a slide.
            frequency = start_hz + (end_hz - start_hz) * (1 - (1 - progress) ** 3)
            phase += 2 * math.pi * frequency / sample_rate
            attack = min(1.0, p / 0.002)
            release = min(1.0, (length - p) / 0.02)
            envelope = attack * release * math.exp(-p * 30)
            # Mostly pure, with a touch of the second harmonic for warmth.
            tone = math.sin(phase) + 0.12 * math.sin(phase * 2)
            if first + index < count:
                samples[first + index] += tone * envelope * gain
    # A one-pole low-pass rounds off the edges, like a real pop rather than a beep.
    smoothed, previous = [], 0.0
    for value in samples:
        previous += 0.55 * (value - previous)
        smoothed.append(previous * 1.25)
    samples = smoothed
    frames = b"".join(struct.pack("<h", int(max(-1, min(1, value)) * 32767)) for value in samples)
    with wave.open(str(destination / f"{name}.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(frames)
