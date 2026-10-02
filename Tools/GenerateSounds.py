"""Original soft two-note cues, synthesized locally with no external samples."""
import math
from pathlib import Path
import struct
import sys
import wave

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
sample_rate = 44100
for name, notes in {
    "start": [(0.00, 0.13, 622.25), (0.055, 0.19, 932.33)],
    "finish": [(0.00, 0.16, 932.33), (0.07, 0.25, 622.25)],
}.items():
    duration = max(offset + length for offset, length, _ in notes) + 0.025
    frames = []
    for index in range(int(duration * sample_rate)):
        time = index / sample_rate
        value = 0.0
        for offset, length, frequency in notes:
            position = time - offset
            if 0 <= position < length:
                attack = min(1.0, position / 0.010)
                release = min(1.0, (length - position) / 0.055)
                envelope = attack * release * math.exp(-position * 8)
                tone = math.sin(2 * math.pi * frequency * position)
                tone += 0.13 * math.sin(2 * math.pi * frequency * 2 * position)
                value += tone * envelope * 0.24
        frames.append(struct.pack("<h", int(max(-1, min(1, value)) * 32767)))
    with wave.open(str(destination / f"{name}.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"".join(frames))
