# SQL-SYNTH: a tracker synthesiser inside SQL Server

The music is stored as data: instruments, 16-row patterns and a song order. SQL Server renders the audio itself, set-based. Python only fetches the bytes and plays them.

## Run it

1. In SSMS, run `01_schema.sql`, then `02_render.sql`, then `03_demo_song.sql`. You need SQL Server 2022 or later.
2. Install the Python packages: `pip install pyodbc sounddevice`
3. Start the player: `python player.py`. For SQL authentication, add `--server MYBOX --user sa --password ...`.

Useful options:

- `--save tune.wav` writes what was played to a file.
- `--prerender` renders the whole song first, then plays it. Use this if the realtime factor drops below 1x.
- `--chunk 4` sets how many seconds of audio each SQL call renders.

You can also test it with SQL alone. `EXEC synth.RenderPcm 1, 0, 44100;` returns a complete `.wav` for the first second. Save the cell to a file and it will play.

## How the render works (`synth.RenderPcm`)

| Step | Set-based trick |
|---|---|
| Sample clock | `GENERATE_SERIES` over the samples each note sounds for. |
| Oscillators | Sine, square, saw and triangle come from the phase: `Freq * t` and its fractional part. |
| Kick | A sine whose pitch falls from 150 Hz to 45 Hz. The phase is the closed-form integral. |
| Noise | A pure integer hash of the sample index, so it needs no state or `RAND()`. |
| Hi-hat | Noise(n) − Noise(n−1). This is a one-tap high-pass filter with no recursion. |
| Acid bass | An additive saw, `SUM` over up to 40 harmonics. The rolloff envelope closes on each note, which is the filter sweep. |
| Mixing | `SUM(v) GROUP BY n` |
| Output | Cubic soft clip, then `int` to `binary(4)` and a byte swap to little-endian. Each sample is hex-encoded, joined with `STRING_AGG ... WITHIN GROUP (ORDER BY n)`, and the string is converted back to `varbinary`. The 44-byte RIFF header is built by `synth.WavHeader`. |

If it runs slower than realtime, set `synth.Song.SampleRate` to 22050. That's Amiga-flavoured, and it halves the work. Most of the cost is in the acid bass.

`preview_set_based_breakbeat.wav` shows what the SQL should produce. 

## Stage 2: ProTracker MOD player

1. Run `04_mod_schema.sql`, then `05_mod_engine.sql`.
2. Play the demo module: `python modplayer.py --load setbased.mod`. T-SQL parses the file, conducts it, then mixes it in stereo.
3. Play any other 4 to 32-channel `.mod` file the same way. `--list` shows what's loaded, and `--mod N` replays one.

You can also load a file from SSMS. The path is on the server:

```sql
DECLARE @m varbinary(max) = (SELECT BulkColumn FROM OPENROWSET(BULK N'C:\mods\tune.mod', SINGLE_BLOB) b);
EXEC synth.LoadMod @m;
EXEC synth.RenderMod @ModId = 1;   -- the whole song as a stereo .wav
```

How it's built:

- **`synth.LoadMod`** parses the binary. The header words are big-endian, the 68000's byte order, which is also how SQL Server casts `binary` to `int`. So no byte-swapping is needed on the way in; it's WAV on the way out that needs it. Sample bytes are read through 8000-byte chunks rather than from the LOB.
- **`synth.BuildModTimeline`** is the conductor. It is the one deliberately procedural part. It walks the song row by row, because `Fxx`, `Bxx`, `Dxx` and slides carry state from row to row. Within each row, all channels and ticks are computed set-based, because every effect has a closed form in the tick number. The result goes to `synth.ModTick`: channel, sample, start position, step and volume for each tick.
- **`synth.RenderMod`** is set-based. It reads each position as `PosAtStart + i * Step` and looks up the nearest sample point, with no interpolation, like Paula. Loops wrap with a modulo, channels are panned L R R L, and the mix is a `SUM` grouped by output sample.
- **Supported effects:** `0` arpeggio, `1`/`2` slides, `3` tone portamento, `4` vibrato, `5`/`6` combos, `9` sample offset, `A` volume slide, `B` jump, `C` volume, `D` break, `E1`/`E2`/`EA`/`EB`/`EC`, `F` speed/tempo. Everything else is ignored for now. If a song loops back to a row it has already played, that's treated as the end.
- **Settings:** stereo width and volume are in `synth.Mod.StereoSeparation` and `MasterGain`. To change the sample rate, update `synth.Mod.SampleRate`, then `EXEC synth.BuildModTimeline @ModId`.

`preview_setbased_mod.wav` is the numpy copy of this engine playing `setbased.mod`. It was checked against libopenmpt's render of the same file: the structure lines up, and the timing differs by about 0.1%, because libopenmpt rounds the tick length.

## Stage 3: the sampler

Chop a record you own into a tracker kit.

1. Re-run `05_mod_engine.sql`. It adds two columns in place, so your loaded modules are kept. Then run `06_sampler.sql`.
2. Convert your copy to a 16-bit WAV: `ffmpeg -i track.mp3 -ac 2 -ar 44100 -sample_fmt s16 track.wav`
3. Load it: `python sampler.py load track.wav`. SQL Server stores it, finds the BPM and first beat, and cuts it into beat slices.
4. Pick a section: `python sampler.py bars 1` prints a bar map with a loudness meter.
5. Build and play: `python sampler.py make 1 --from 64 --count 32`. `--from` is a slice number from the `bars` list, and the range has to fit inside the track.

What `make` produces:

- **Straight patterns** replay the section exactly.
- **A stutter edit** repeats and gates slices.
- **A chipmunk pattern** plays slices an octave up.
- **A half-time pattern** plays slices an octave down.

After that, remix by hand with `synth.PutNote` and `synth.SetOrder`, then run `EXEC synth.BuildModTimeline @ModId` and play it again.

How the beat detection works (`synth.DetectBeats`):

- It measures energy in 5 ms windows, and treats a jump in log energy as an onset.
- It autocorrelates the onsets by self-joining the window table.
- The tempo score is R(L) + R(2L)/2 + R(4L)/4. Plain autocorrelation reads a breakbeat as 2/3 of the real tempo.
- A comb search then tries 101 tempos × every phase × every beat. That pins the BPM to about 0.01% and finds the first beat.
- If it gets the tempo wrong, pass `--bpm` as a hint.

The slices play at tempo = round(BPM), so a 141.7 BPM record plays back at 142. That's too small a difference to hear.

`preview_sampler_remix.wav` is the numpy copy of this pipeline, run on the SQL-generated test tune from stage 1, re-rendered at 141.7 BPM with a 0.37 s silent intro. It detected 141.702 BPM and put the first beat at 0.369 s.

## Next

- Stage 3 ideas: more effects (`E6x` pattern loop, `E9x` retrigger, `EDx` note delay), linear interpolation as an option, and a tracker display in the style of the Amiga.
