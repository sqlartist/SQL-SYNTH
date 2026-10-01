"""
SQL-SYNTH MOD player -- SQL Server parses the module, conducts it and mixes it.
Python sends the file in, streams stereo PCM out to the speakers, and shows a
tracker, a graphic equaliser and live SQL Server statistics while it plays.

  pip install pyodbc sounddevice numpy rich

  python modplayer.py --load setbased.mod      # parse + play (T-SQL does the parsing)
  python modplayer.py --list                   # modules in the database
  python modplayer.py --mod 3 --save out.wav   # play a loaded module, keep a copy
  python modplayer.py --mod 3 --prerender      # if the realtime factor is below 1x
  python modplayer.py --mod 3 --plain          # scrolling text only, no dashboard
"""
import argparse, bisect, os, queue, sys, threading, time, wave

import pyodbc

try:
    import sounddevice as sd
except (ImportError, OSError):      # OSError = PortAudio missing
    sd = None
try:
    import numpy as np
    from rich.console import Group
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    HAVE_UI = True
except ImportError:
    HAVE_UI = False


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


# ---------------------------------------------------------------- equaliser --
BANDS = 20
BAR_H = 12
LEVELS = " ▁▂▃▄▅▆▇█"


class Equaliser:
    """FFT of the audio actually leaving the speakers, in log-spaced bands,
    with falling bars and peak-hold dots like a 90s hi-fi."""

    def __init__(self, sr):
        self.sr = sr
        self.n = 2048
        self.window = np.hanning(self.n)
        freqs = np.fft.rfftfreq(self.n, 1 / sr)
        edges = np.geomspace(40, min(16000, sr / 2 - 1), BANDS + 1)
        self.bins = [np.where((freqs >= lo) & (freqs < hi))[0] for lo, hi in zip(edges[:-1], edges[1:])]
        fmt = lambda e: f"{e / 1000:.0f}k" if e >= 9500 else f"{e / 1000:.1f}k" if e >= 1000 else f"{e:.0f}"
        self.labels = "".join(f"{fmt(e):<6}" for e in edges[:-1:2])            # a label every other bar
        self.bars = np.zeros(BANDS)
        self.peaks = np.zeros(BANDS)
        self.vu = [0.0, 0.0]

    def update(self, pcm_bytes):
        if len(pcm_bytes) < self.n * 4:
            target = np.zeros(BANDS)
            self.vu = [0.0, 0.0]
        else:
            st = np.frombuffer(pcm_bytes[-self.n * 4:], dtype="<i2").reshape(-1, 2) / 32768.0
            self.vu = [float(np.sqrt(np.mean(st[:, 0] ** 2))), float(np.sqrt(np.mean(st[:, 1] ** 2)))]
            spec = np.abs(np.fft.rfft(st.mean(axis=1) * self.window)) / (self.n / 4)
            db = np.array([20 * np.log10(np.sqrt(np.mean(spec[b] ** 2)) + 1e-9) if len(b) else -90 for b in self.bins])
            target = np.clip((db + 60) / 60, 0, 1) * BAR_H        # -60 dB .. 0 dB
        self.bars = np.maximum(target, self.bars - 0.8)            # fall slowly
        self.peaks = np.where(self.bars >= self.peaks, self.bars, self.peaks - 0.15)

    def render(self):
        t = Text()
        for row in range(BAR_H, 0, -1):
            colour = "red" if row > BAR_H * 0.85 else "yellow" if row > BAR_H * 0.6 else "green"
            for b in range(BANDS):
                h, pk = self.bars[b], self.peaks[b]
                if h >= row:
                    ch = "█"
                elif h > row - 1:
                    ch = LEVELS[int((h - (row - 1)) * 8)]
                elif row - 1 < pk <= row:
                    ch = "▔"
                else:
                    ch = " "
                t.append(ch * 2 + " ", style=colour)
            t.append("\n")
        t.append(self.labels + "Hz", style="dim")
        t.append("\n")
        for name, v in zip("LR", self.vu):
            n = int(min(1.0, v * 3) * (BANDS * 3 - 4))
            t.append(f"{name} ", style="bold")
            t.append("■" * n, style="green" if v < 0.2 else "yellow" if v < 0.3 else "red")
            t.append("\n")
        return t


# ---------------------------------------------------------------- main -------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="localhost")
    ap.add_argument("--database", default="SqlSynth")
    ap.add_argument("--driver", default="ODBC Driver 18 for SQL Server")
    ap.add_argument("--user"); ap.add_argument("--password")
    ap.add_argument("--load", help=".mod file to load into the database, then play")
    ap.add_argument("--mod", type=int, help="ModId to play (default: most recently loaded)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--rate", type=int, default=44100, help="sample rate used when loading")
    ap.add_argument("--chunk", type=float, default=2.0, help="seconds of audio per SQL call")
    ap.add_argument("--save", help="write the rendered audio to this .wav file")
    ap.add_argument("--prerender", action="store_true", help="render everything before playing")
    ap.add_argument("--plain", action="store_true", help="no dashboard, just scrolling rows")
    a = ap.parse_args()
    ui = HAVE_UI and not a.plain and sd is not None

    conn = connect(a)
    cur = conn.cursor()

    if a.list:
        cur.execute("SELECT ModId, Title, Tag, Channels, CAST(TotalSamples * 1.0 / SampleRate AS decimal(9,1)) "
                    "FROM synth.Mod ORDER BY ModId")
        for r in cur.fetchall():
            print(f"  {r[0]:4d}  {r[1]:<20} {r[2]}  {r[3]}ch  {r[4]}s")
        return

    if a.load:
        data = open(a.load, "rb").read()
        print(f"  Loading {os.path.basename(a.load)} ({len(data):,} bytes) -- T-SQL is parsing it...")
        t0 = time.perf_counter()
        cur.execute("EXEC synth.LoadMod @Mod = ?, @SampleRate = ?", pyodbc.Binary(data), a.rate)
        r = first_resultset(cur).fetchone()
        print(f"  ModId {r.ModId}: '{r.Title}' {r.Tag} {r.Channels}ch, {r.PatternCount} patterns, "
              f"{r.Samples} samples ({r.SamplePoints:,} points), {r.RowsPlayed} rows, {r.Seconds}s "
              f"-- parse {r.ParseSec}s, conduct {r.ConductSec}s, total {time.perf_counter() - t0:.1f}s")
        a.mod = r.ModId

    if a.mod is None:
        cur.execute("SELECT MAX(ModId) FROM synth.Mod")
        a.mod = cur.fetchone()[0]
        if a.mod is None:
            sys.exit("No modules loaded yet -- use --load file.mod")

    cur.execute("EXEC synth.ModInfo ?", a.mod)
    info = cur.fetchone()
    if info is None:
        sys.exit(f"ModId {a.mod} not found")
    sr, total = int(info.SampleRate), int(info.TotalSamples)
    cur.execute("SELECT StartSample, Position, RowNo, Line FROM synth.ModRow WHERE ModId = ? ORDER BY SeqNo", a.mod)
    rows = [(int(r.StartSample), f"{r.Position:02X}:{r.RowNo:02d}  {r.Line}") for r in cur.fetchall()]
    row_starts = [r[0] for r in rows]
    cur.execute("SELECT @@VERSION")
    version = cur.fetchone()[0].split("\n")[0].strip()

    title = f"{info.Title}  --  {info.Channels} channels, {sr} Hz stereo, {total / sr:.1f}s"
    if not ui:
        print(f"\n  {title}\n")

    chunk = int(a.chunk * sr)
    q = queue.Queue()
    stats = {"chunks": 0, "rendered": 0.0, "wall": 0.0, "last_wall": 0.0, "last_x": 0.0,
             "cpu": 0, "reads": 0, "writes": 0, "ticks": 0, "points": 0, "lookups": 0,
             "spid": "?", "srv_cpu_start": None, "srv_cpu": 0, "srv_reads": 0}
    t_start = time.perf_counter()

    def producer():
        try:
            render_all()
        except Exception as e:                      # don't die silently in the background
            sys.stderr.write(f"\n  SQL render failed: {e}\n")
            os._exit(1)

    def render_all():
        pconn = connect(a)
        pcur = pconn.cursor()
        pcur.execute("SELECT @@SPID")
        stats["spid"] = pcur.fetchone()[0]
        for start in range(0, total, chunk):
            t0 = time.perf_counter()
            pcur.execute("EXEC synth.RenderMod @ModId=?, @StartSample=?, @SampleCount=?, @WithHeader=0, @Stats=1",
                         a.mod, start, min(chunk, total - start))
            pcm = bytes(pcur.fetchone()[0] or b"")
            w = None
            if pcur.nextset():
                w = pcur.fetchone()
            took = time.perf_counter() - t0
            secs = len(pcm) / 4 / sr
            # a session can always see its own row in sys.dm_exec_sessions
            pcur.execute("SELECT cpu_time, logical_reads, writes FROM sys.dm_exec_sessions WHERE session_id = @@SPID")
            s = pcur.fetchone()
            stats.update(chunks=stats["chunks"] + 1, rendered=stats["rendered"] + secs,
                         wall=stats["wall"] + took, last_wall=took,
                         last_x=secs / took if took else 0.0,
                         srv_cpu=s.cpu_time, srv_reads=s.logical_reads)
            if w is not None:
                stats.update(ticks=w.Ticks, points=w.SamplePoints, lookups=w.Lookups)
            if not ui:
                sys.stderr.write(f"\r  [SQL mixed {secs:.1f}s in {took:.2f}s = {stats['last_x']:.1f}x realtime]   ")
            q.put(pcm)
        q.put(None)

    def write_wav(path, pcm):
        with wave.open(path, "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm)

    if a.prerender or sd is None:
        print("  Pre-rendering in SQL Server...")
        producer()
        allpcm = bytearray()
        while (p := q.get()) is not None:
            allpcm += p
        print(f"\n  rendered {stats['rendered']:.1f}s of audio in {stats['wall']:.1f}s")
        if sd is None:
            path = a.save or "sqlsynth_mod.wav"
            write_wav(path, bytes(allpcm))
            print(f"  sounddevice not available -- wrote {path}")
            if os.name == "nt":
                import winsound
                winsound.PlaySound(path, winsound.SND_FILENAME)
            return
        q = queue.Queue(); q.put(bytes(allpcm)); q.put(None)
    else:
        threading.Thread(target=producer, daemon=True).start()

    buf, history = bytearray(), bytearray()      # history = everything played so far
    lock = threading.Lock()
    played = [0]
    eof = [False]
    finished = threading.Event()

    def feeder():
        while (p := q.get()) is not None:
            with lock:
                buf.extend(p)
        eof[0] = True

    def callback(outdata, frames, t, status):
        need = frames * 4
        with lock:
            n = min(need, len(buf))
            outdata[:n] = buf[:n]
            history.extend(buf[:n])
            del buf[:n]
        if n < need:
            outdata[n:] = b"\x00" * (need - n)
            if eof[0] and n == 0:
                raise sd.CallbackStop
        played[0] += n // 4

    threading.Thread(target=feeder, daemon=True).start()
    sys.stderr.write(f"  Rendering the first {a.chunk:g}s in SQL Server...")
    t_wait = time.perf_counter()
    while len(buf) < min(chunk, total) * 4 and not eof[0]:
        time.sleep(0.01)
        if time.perf_counter() - t_wait > 30:
            sys.stderr.write("\n  Still waiting after 30s -- check sys.dm_exec_requests for blocking.")
            t_wait = float("inf")
    sys.stderr.write("\n")

    def mmss(sec):
        return f"{int(sec // 60):02d}:{int(sec % 60):02d}"

    def dashboard(eq):
        pos = played[0] / sr
        cur_row = max(0, bisect.bisect_right(row_starts, played[0]) - 1)
        tr = Text()
        for i in range(cur_row - 7, cur_row + 6):
            if 0 <= i < len(rows):
                tr.append(rows[i][1] + "\n", style="bold black on cyan" if i == cur_row else "white" if i > cur_row else "dim")
            else:
                tr.append("\n")
        ahead = (len(buf) / 4) / sr
        tab = Table.grid(padding=(0, 1))
        tab.add_column(style="cyan", justify="right"); tab.add_column()
        x = stats["last_x"]
        tab.add_row("session", f"spid {stats['spid']}")
        tab.add_row("chunks", f"{stats['chunks']}  ({stats['rendered']:.0f}s of {total / sr:.0f}s rendered)")
        tab.add_row("last chunk", f"{stats['last_wall']:.2f}s")
        tab.add_row("realtime", Text(f"{x:.2f}x", style="green" if x >= 1.2 else "yellow" if x >= 1 else "red"))
        tab.add_row("buffered", Text(f"{ahead:.1f}s ahead", style="green" if ahead > 1 else "red"))
        tab.add_row("session CPU", f"{stats['srv_cpu']:,} ms")
        tab.add_row("session reads", f"{stats['srv_reads']:,}")
        tab.add_row("ticks/chunk", f"{stats['ticks']:,}")
        tab.add_row("sample pts", f"{stats['points']:,}")
        tab.add_row("lookups", f"{stats['lookups']:,} joined")
        eq_panel = Panel(eq.render(), title="graphic equaliser", border_style="green")
        sql_panel = Panel(tab, title="SQL Server", subtitle=version[:40], border_style="magenta")
        lay = Layout()
        lay.split_column(Layout(Panel(tr, title=f"{title}   {mmss(pos)} / {mmss(total / sr)}",
                                      border_style="cyan"), size=15),
                         Layout(name="bottom"))
        lay["bottom"].split_row(Layout(eq_panel, ratio=3), Layout(sql_panel, ratio=2))
        return lay

    with sd.RawOutputStream(samplerate=sr, channels=2, dtype="int16",
                            callback=callback, finished_callback=finished.set):
        if ui:
            eq = Equaliser(sr)
            with Live(dashboard(eq), refresh_per_second=25, screen=True) as live:
                while not finished.is_set():
                    with lock:
                        recent = bytes(history[-eq.n * 4:])
                    eq.update(recent)
                    live.update(dashboard(eq))
                    time.sleep(0.04)
        else:
            shown = 0
            while not finished.is_set():
                while shown < len(rows) and rows[shown][0] <= played[0]:
                    print("  " + rows[shown][1])
                    shown += 1
                time.sleep(0.005)

    print(f"  played {played[0] / sr:.1f}s; SQL rendered {stats['rendered']:.1f}s in {stats['wall']:.1f}s "
          f"({stats['rendered'] / stats['wall'] if stats['wall'] else 0:.2f}x realtime), "
          f"SQL CPU {stats['srv_cpu']:,} ms")
    if a.save:
        write_wav(a.save, bytes(history))
        print(f"  saved {a.save}")


if __name__ == "__main__":
    main()
