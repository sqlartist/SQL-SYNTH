"""
Writes setbased.mod -- an original 4-channel ProTracker module for testing
the SQL-SYNTH MOD player. Every instrument is synthesised here as 8-bit
samples, and the patterns deliberately exercise the supported effects:
  0xy arpeggio, 1xx/2xx pitch slides, 3xx tone portamento, 4xy vibrato,
  9xx sample offset, Axy volume slide, Bxx jump, Cxx volume, Dxx break,
  ECx note cut, EAx/EBx fine volume, Fxx speed/tempo.
"""
import math, random, struct

RATE = 16574  # playback rate of C-3 (period 214) on a PAL Amiga
PERIODS = [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
           428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
           214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113]
NAMES = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]


def P(note):  # "E-1" -> period
    return PERIODS[NAMES.index(note[:2]) + 12 * (int(note[2]) - 1)]


def s8(vals):
    out = bytes((max(-128, min(127, int(round(v * 127)))) & 255) for v in vals)
    return out + (b"\x00" if len(out) % 2 else b"")


random.seed(1985)
kick = s8([math.sin(2 * math.pi * (50 * t + 110 * 0.03 * (1 - math.exp(-t / 0.03)))) * math.exp(-t / 0.09)
           for t in (i / RATE for i in range(int(RATE * 0.26)))])
snare = s8([(0.75 * random.uniform(-1, 1) + 0.5 * math.sin(2 * math.pi * 190 * t) * math.exp(-t / 0.03)) * math.exp(-t / 0.06)
            for t in (i / RATE for i in range(int(RATE * 0.2)))])
n = [random.uniform(-1, 1) for _ in range(int(RATE * 0.06) + 1)]
hat = s8([(n[i + 1] - n[i]) * 0.6 * math.exp(-(i / RATE) / 0.015) for i in range(len(n) - 1)])
bass = s8([(2 * (i / 64) - 1) * 0.9 for i in range(64)])                  # one saw cycle, looped
lead = s8([0.7 if i < 10 else -0.7 for i in range(32)])                    # ~30% pulse, looped
pad = s8([0.8 * (4 * abs(i / 64 - 0.5) - 1) for i in range(64)])           # triangle, looped

# (name, data, finetune, volume, loop_start, loop_len) -- loop values in bytes
SAMPLES = [("kick", kick, 0, 64, 0, 0), ("snare", snare, 0, 56, 0, 0), ("hat", hat, 0, 40, 0, 0),
           ("bass saw", bass, 0, 48, 0, 64), ("lead pulse", lead, 0, 36, 0, 32), ("pad tri", pad, 0, 40, 0, 64)]

KICK, SNARE, HAT, BASS, LEAD, PAD = 1, 2, 3, 4, 5, 6
CH_DRUM, CH_BASS, CH_LEAD, CH_HAT = 0, 1, 2, 3        # ProTracker pans L R R L


def empty():
    return [[(0, 0, 0, 0) for _ in range(4)] for _ in range(64)]


def put(p, row, ch, note=None, smp=0, fx=0, param=0):
    p[row][ch] = (smp, P(note) if note else 0, fx, param)


def drums(p, bars=4, kick_on=True):
    for b in range(bars):
        r = b * 16
        if kick_on:
            for k in (0, 6, 10):
                put(p, r + k, CH_DRUM, "C-2", KICK)
        put(p, r + 4, CH_DRUM, "C-2", SNARE)
        put(p, r + 12, CH_DRUM, "C-2", SNARE)
        put(p, r + 7, CH_DRUM, "C-2", SNARE, 0xC, 0x12)          # ghost note via Cxx
        for h in range(0, 16, 2):
            put(p, r + h, CH_HAT, "C-3", HAT, 0xC, 0x28 if h % 4 else 0x40)


BASSLINE = [(0, "E-1"), (3, "E-2"), (6, "E-1"), (8, "G-1"), (11, "A-1"), (14, "B-1")]


def bassline(p, slide=False):
    for b in range(4):
        for off, note in BASSLINE:
            if slide and off == 14 and b % 2 == 1:
                put(p, b * 16 + off, CH_BASS, "D-2", 0, 0x3, 0x18)     # tone portamento up to D-2
            else:
                put(p, b * 16 + off, CH_BASS, note, BASS)


pats = []

# 0: intro -- set speed/tempo, drums, pad swelling in with a volume slide
p = empty(); drums(p)
put(p, 0, CH_HAT, "C-3", HAT, 0xF, 0x06)                  # F06 speed 6
put(p, 0, CH_LEAD, "E-2", PAD, 0xC, 0x04)                 # pad, quiet
put(p, 1, CH_LEAD, None, 0, 0xF, 0x87)                    # F87 tempo 135
for r in range(2, 60, 2):
    put(p, r, CH_LEAD, None, 0, 0xA, 0x10)                # A10 slide up
put(p, 60, CH_LEAD, None, 0, 0xE, 0xB8)                   # EB8 fine volume down
pats.append(p)

# 1: drums + bass, with tone portamento slides
p = empty(); drums(p); bassline(p, slide=True); pats.append(p)

# 2: full -- lead arpeggios (minor/major chords) and a vibrato hold
p = empty(); drums(p); bassline(p)
for b in range(4):
    r = b * 16
    put(p, r + 0, CH_LEAD, "E-3", LEAD, 0x0, 0x37)        # E minor arpeggio
    for k in range(1, 6):
        put(p, r + k, CH_LEAD, None, 0, 0x0, 0x37)
    put(p, r + 6, CH_LEAD, "E-3", LEAD, 0xE, 0xC3)        # ECx cut at tick 3
    put(p, r + 8, CH_LEAD, "C-3", LEAD, 0x0, 0x47)        # C major arpeggio
    for k in range(9, 12):
        put(p, r + k, CH_LEAD, None, 0, 0x0, 0x47)
    put(p, r + 12, CH_LEAD, "B-2", LEAD, 0x4, 0x46)       # vibrato
    put(p, r + 13, CH_LEAD, None, 0, 0x4, 0x00)           # vibrato, remembered params
    put(p, r + 14, CH_LEAD, None, 0, 0x1, 0x02)           # 1xx pitch up
    put(p, r + 15, CH_LEAD, None, 0, 0x2, 0x04)           # 2xx pitch down
pats.append(p)

# 3: break -- no kick, snare roll using 9xx offsets and rising volume; D00 at row 48
p = empty(); drums(p, bars=2, kick_on=False)
for i, r in enumerate(range(32, 48)):
    put(p, r, CH_DRUM, "C-2", SNARE, 0xC, 0x10 + i * 3)
for i, r in enumerate(range(32, 48, 2)):
    put(p, r, CH_HAT, "C-3", HAT, 0x9, 0x02)              # 9xx: start the hat 512 bytes in
put(p, 0, CH_BASS, "E-1", BASS)
put(p, 0, CH_LEAD, None, 0, 0xC, 0x00)                   # silence the lead
for r in range(1, 48):
    put(p, r, CH_BASS, None, 0, 0x2, 0x01)                # long slow pitch dive
put(p, 47, CH_LEAD, None, 0, 0xD, 0x00)                   # pattern break -> next position, row 0
pats.append(p)

# 4: outro -- drums and bass fading with Axy, then B00 (loops to start = end of song)
p = empty(); drums(p); bassline(p)
for r in range(32, 64):
    if p[r][CH_BASS] == (0, 0, 0, 0):
        put(p, r, CH_BASS, None, 0, 0xA, 0x02)            # A02 slide down
put(p, 63, CH_LEAD, None, 0, 0xB, 0x00)
pats.append(p)

ORDER = [0, 1, 2, 2, 3, 1, 2, 4]

out = bytearray(b"set-based breakbeat".ljust(20, b"\x00"))
for i in range(31):
    if i < len(SAMPLES):
        name, data, ft, vol, ls, ll = SAMPLES[i]
        out += name.encode().ljust(22, b"\x00")
        out += struct.pack(">HBBHH", len(data) // 2, ft & 15, vol, ls // 2, max(1, ll // 2))
    else:
        out += b"\x00" * 22 + struct.pack(">HBBHH", 0, 0, 0, 0, 1)
out += bytes([len(ORDER), 127]) + bytes(ORDER + [0] * (128 - len(ORDER))) + b"M.K."
for p in pats:
    for row in p:
        for smp, per, fx, prm in row:
            out += bytes([(smp & 0xF0) | (per >> 8), per & 0xFF, ((smp & 0x0F) << 4) | fx, prm])
for s in SAMPLES:
    out += s[1]

open("setbased.mod", "wb").write(out)
print(f"setbased.mod: {len(out)} bytes, {len(pats)} patterns, order {ORDER}")
