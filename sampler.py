"""
SQL-SYNTH sampler -- chop a record you own into a tracker kit, inside SQL Server.

  python sampler.py load track.wav                 # store, detect BPM, slice (16-bit WAV)
  python sampler.py load track.wav --bpm 145       # give a hint if the detection is off
  python sampler.py bars 1                         # bar map + loudness, to pick a section
  python sampler.py make 1 --from 64 --count 32    # kit + patterns from slices 64-95, then play
  python sampler.py make 1 --from 64 --count 32 --decimate 1 --no-remix

Any MP3/FLAC you own converts with e.g.:  ffmpeg -i track.mp3 -ac 2 -ar 44100 -sample_fmt s16 track.wav
Playback is handled by modplayer.py (same folder).
"""
import argparse, os, subprocess, sys, time

import pyodbc


def connect(a):
    cs = (f"DRIVER={{{a.driver}}};SERVER={a.server};DATABASE={a.database};"
          "TrustServerCertificate=yes;")
    cs += f"UID={a.user};PWD={a.password};" if a.user else "Trusted_Connection=yes;"
    return pyodbc.connect(cs, autocommit=True)


def first_resultset(cur):
    while cur.description is None:
        if not cur.nextset():
            return None
    return cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="localhost")
    ap.add_argument("--database", default="SqlSynth")
    ap.add_argument("--driver", default="ODBC Driver 18 for SQL Server")
    ap.add_argument("--user"); ap.add_argument("--password")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("load"); p.add_argument("wav")
    p.add_argument("--bpm", type=float); p.add_argument("--spb", type=int, default=1, choices=[1, 2, 4],
                                                       help="slices per beat")
    p = sub.add_parser("bars"); p.add_argument("source", type=int)
    p = sub.add_parser("make"); p.add_argument("source", type=int)
    p.add_argument("--from", dest="first", type=int, default=0)
    p.add_argument("--count", type=int, default=32)
    p.add_argument("--decimate", type=int, default=2, help="1 = full rate, 2 = 22 kHz (default)")
    p.add_argument("--title")
    p.add_argument("--no-remix", action="store_true")
    p.add_argument("--no-play", action="store_true")
    a = ap.parse_args()

    conn = connect(a)
    cur = conn.cursor()

    if a.cmd == "load":
        data = open(a.wav, "rb").read()
        name = os.path.splitext(os.path.basename(a.wav))[0][:100]
        print(f"  Sending {name} ({len(data) / 1e6:.1f} MB) -- SQL Server is parsing and listening for the beat...")
        t0 = time.perf_counter()
        cur.execute("EXEC synth.LoadWav @Wav = ?, @Name = ?, @Bpm = ?, @SlicesPerBeat = ?",
                    pyodbc.Binary(data), name, a.bpm, a.spb)
        r = first_resultset(cur).fetchone()
        print(f"  SourceId {r.SourceId}: {r.Seconds}s, {r.SampleRate} Hz, {r.Channels}ch")
        print(f"  BPM {r.Bpm}, first beat at {r.FirstBeatSec}s, {r.Slices} slices")
        print(f"  store {r.StoreSec}s, beat detection {r.DetectSec}s, total {time.perf_counter() - t0:.1f}s")
        print(f"\n  Next:  python sampler.py bars {r.SourceId}")
        return

    if a.cmd == "bars":
        cur.execute("EXEC synth.SamplerBars ?", a.source)
        print("  bar  slice  time      loudness")
        for r in cur.fetchall():
            print(f"  {r.Bar:3d}  {r.FirstSlice:5d}  {r.StartsAt}  {r.Loudness}")
        return

    if a.cmd == "make":
        t0 = time.perf_counter()
        cur.execute("EXEC synth.SamplerMakeSong @SourceId=?, @FirstSlice=?, @SliceCount=?, @Decimate=?, @Title=?, @Remix=?",
                    a.source, a.first, a.count, a.decimate, a.title, 0 if a.no_remix else 1)
        r = first_resultset(cur).fetchone()
        print(f"  ModId {r.ModId}: '{r.Title}' tempo {r.Tempo}, {r.SongLength} positions, "
              f"{r.SamplePoints:,} sample points, {r.Seconds}s -- built in {time.perf_counter() - t0:.1f}s")
        if not a.no_play:
            here = os.path.dirname(os.path.abspath(__file__))
            args = [sys.executable, os.path.join(here, "modplayer.py"), "--mod", str(r.ModId),
                    "--server", a.server, "--database", a.database, "--driver", a.driver]
            if a.user:
                args += ["--user", a.user, "--password", a.password or ""]
            subprocess.call(args)


if __name__ == "__main__":
    main()
