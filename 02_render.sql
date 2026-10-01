/* =====================================================================
   SQL-SYNTH  |  02_render.sql
   The engine: noise generator, WAV header, and the set-based renderer.
   ===================================================================== */
USE SqlSynth;
GO

/* ---------------------------------------------------------------------
   Deterministic white noise. A pure function of the sample index, so
   there's no state to carry between rows and it parallelises freely.
   Integer hash (multiply / xor-shift / multiply / xor-shift) mapped to
   the range [-1, 1).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION synth.Noise (@n bigint)
RETURNS TABLE
AS
RETURN
WITH a AS (SELECT (@n * CAST(2654435761 AS bigint)) % CAST(4294967296 AS bigint) AS x),
     b AS (SELECT x ^ (x / 65536) AS x FROM a),
     c AS (SELECT (x * CAST(73244475 AS bigint)) % CAST(4294967296 AS bigint) AS x FROM b),
     d AS (SELECT x ^ (x / 65536) AS x FROM c)
SELECT CAST(x AS float) / 2147483648.0 - 1.0 AS w
FROM d;
GO

/* ---------------------------------------------------------------------
   Little-endian integer packing. CAST(int AS binary) is big-endian, and
   WAV wants little-endian, so we reverse the bytes.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION synth.LE16 (@v int)
RETURNS binary(2)
AS
BEGIN
    DECLARE @b binary(4) = CAST(@v AS binary(4));
    RETURN SUBSTRING(@b, 4, 1) + SUBSTRING(@b, 3, 1);
END;
GO

CREATE OR ALTER FUNCTION synth.LE32 (@v bigint)
RETURNS binary(4)
AS
BEGIN
    DECLARE @b binary(8) = CAST(@v AS binary(8));
    RETURN SUBSTRING(@b, 8, 1) + SUBSTRING(@b, 7, 1) + SUBSTRING(@b, 6, 1) + SUBSTRING(@b, 5, 1);
END;
GO

/* 44-byte RIFF/WAVE header for 16-bit mono PCM. */
CREATE OR ALTER FUNCTION synth.WavHeader (@DataBytes bigint, @SampleRate int)
RETURNS binary(44)
AS
BEGIN
    RETURN CAST('RIFF' AS binary(4)) + synth.LE32(36 + @DataBytes)
         + CAST('WAVE' AS binary(4))
         + CAST('fmt ' AS binary(4)) + synth.LE32(16)
         + synth.LE16(1)                      -- PCM
         + synth.LE16(1)                      -- mono
         + synth.LE32(@SampleRate)
         + synth.LE32(@SampleRate * 2)        -- byte rate
         + synth.LE16(2)                      -- block align
         + synth.LE16(16)                     -- bits per sample
         + CAST('data' AS binary(4)) + synth.LE32(@DataBytes);
END;
GO

/* ---------------------------------------------------------------------
   Timing facts the player needs to stay in sync with the audio.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE synth.SongInfo
    @SongId int
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SongId, s.Title, s.SampleRate, s.Bpm,
           s.SampleRate * 60.0 / s.Bpm / s.RowsPerBeat                        AS SamplesPerRow,
           t.SongRows,
           CAST(CEILING(t.SongRows * s.SampleRate * 60.0 / s.Bpm / s.RowsPerBeat) AS bigint)
             + s.SampleRate                                                   AS TotalSamples  -- + 1s tail
    FROM synth.Song s
    CROSS APPLY (SELECT SUM(CAST(p.PatternRows AS int)) AS SongRows
                 FROM synth.SongOrder so
                 JOIN synth.Pattern p ON p.PatternId = so.PatternId
                 WHERE so.SongId = s.SongId) t
    WHERE s.SongId = @SongId;
END;
GO

/* ---------------------------------------------------------------------
   THE RENDERER
   Renders samples [@StartSample, @StartSample + @SampleCount) of a song.
     1. Expand the song into note events with absolute sample positions.
     2. For each event, GENERATE_SERIES over the samples it sounds for,
        and compute oscillator x envelope for every one of them.
     3. Mix = SUM(...) GROUP BY sample index.
     4. Soft clip, quantise to 16-bit, byte-swap to little-endian,
        hex-encode, STRING_AGG in sample order, convert back to binary.
   Returns one row, one column: Pcm varbinary(max). With @WithHeader = 1
   it's a complete .wav file; with 0 it's raw PCM for streaming.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE synth.RenderPcm
    @SongId       int,
    @StartSample  bigint = 0,
    @SampleCount  bigint = NULL,       -- NULL = to the end of the song
    @WithHeader   bit    = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sr int, @bpm float, @rpb int, @gain float;
    SELECT @sr = SampleRate, @bpm = Bpm, @rpb = RowsPerBeat, @gain = MasterGain
    FROM synth.Song WHERE SongId = @SongId;

    IF @sr IS NULL THROW 50001, 'synth.RenderPcm: unknown SongId', 1;

    DECLARE @spr float = @sr * 60.0 / @bpm / @rpb;            -- samples per row
    DECLARE @songRows int = ISNULL(
        (SELECT SUM(CAST(p.PatternRows AS int))
         FROM synth.SongOrder so JOIN synth.Pattern p ON p.PatternId = so.PatternId
         WHERE so.SongId = @SongId), 0);
    DECLARE @total bigint = CAST(CEILING(@songRows * @spr) AS bigint) + @sr;   -- + 1s tail

    IF @SampleCount IS NULL OR @StartSample + @SampleCount > @total
        SET @SampleCount = @total - @StartSample;

    DECLARE @Pcm varbinary(max) = 0x;

    IF @SampleCount > 0
    BEGIN
        DECLARE @last bigint = @StartSample + @SampleCount - 1;
        DECLARE @twoPi float = 2.0 * PI();

        /* 1. Note events -> sample positions ------------------------------ */
        DROP TABLE IF EXISTS #ev;
        SELECT  ROW_NUMBER() OVER (ORDER BY e.AbsRow, e.Channel)       AS EventId,
                i.Waveform,
                CAST(ROUND(e.AbsRow * @spr, 0) AS bigint)               AS StartS,
                e.LengthRows * @spr / @sr                               AS DurSec,
                440.0 * POWER(CAST(2 AS float), (CAST(e.Note AS float) - 69.0) / 12.0) AS Freq,
                e.Velocity * i.Volume                                   AS Amp,
                i.AttackSec, i.DecaySec, i.Sustain, i.ReleaseSec, i.Drive,
                CAST(ROUND(e.AbsRow * @spr, 0) AS bigint)
                  + CAST(CEILING(@sr * CASE WHEN i.Waveform IN ('kick','snare','hat')
                                            THEN 7.0 * i.DecaySec
                                            ELSE e.LengthRows * @spr / @sr + 7.0 * i.ReleaseSec
                                       END) AS bigint)                  AS EndS
        INTO    #ev
        FROM    synth.SongEvent e
        JOIN    synth.Instrument i ON i.InstrumentId = e.InstrumentId
        WHERE   e.SongId = @SongId;

        DELETE #ev WHERE EndS < @StartSample OR StartS > @last;

        /* 2. Every sample of every sounding voice ------------------------- */
        DROP TABLE IF EXISTS #voice;
        CREATE TABLE #voice (n bigint NOT NULL, v float NOT NULL);

        -- 2a. Ordinary oscillators and drums
        INSERT #voice (n, v)
        SELECT  g.value,
                ev.Amp * env.e * sat.y
        FROM    #ev ev
        CROSS APPLY GENERATE_SERIES(GREATEST(ev.StartS, @StartSample), LEAST(ev.EndS, @last)) g
        CROSS APPLY (SELECT CAST(g.value - ev.StartS AS float) / @sr AS t) tt
        CROSS APPLY (SELECT ev.Freq * tt.t AS ph) p                         -- phase, in cycles
        CROSS APPLY (SELECT p.ph - FLOOR(p.ph) AS fr) f
        CROSS APPLY synth.Noise(g.value)     nz
        CROSS APPLY synth.Noise(g.value - 1) nz1
        CROSS APPLY (SELECT CASE ev.Waveform
                 WHEN 'sine'     THEN SIN(@twoPi * p.ph)
                 WHEN 'square'   THEN CASE WHEN f.fr < 0.5 THEN 1.0 ELSE -1.0 END
                 WHEN 'saw'      THEN 2.0 * f.fr - 1.0
                 WHEN 'triangle' THEN 4.0 * ABS(f.fr - 0.5) - 1.0
                 WHEN 'noise'    THEN nz.w
                 -- kick: sine whose pitch falls exponentially 150 Hz -> 45 Hz (phase is the integral)
                 WHEN 'kick'     THEN SIN(@twoPi * (45.0 * tt.t + 105.0 * 0.035 * (1.0 - EXP(-tt.t / 0.035))))
                 -- snare: noise burst over a 185 Hz body
                 WHEN 'snare'    THEN 0.7 * nz.w + 0.4 * SIN(@twoPi * 185.0 * tt.t) * EXP(-tt.t / 0.04)
                 -- hat: first difference of noise = a one-tap high-pass filter, no recursion needed
                 WHEN 'hat'      THEN 0.5 * (nz.w - nz1.w)
                 END AS x) osc
        CROSS APPLY (SELECT CASE
                 WHEN ev.Waveform IN ('kick','snare','hat') THEN EXP(-tt.t / ev.DecaySec)
                 WHEN tt.t <= ev.DurSec THEN
                      CASE WHEN tt.t < ev.AttackSec THEN tt.t / ev.AttackSec
                           ELSE ev.Sustain + (1.0 - ev.Sustain) * EXP(-(tt.t - ev.AttackSec) / ev.DecaySec) END
                 ELSE
                      CASE WHEN ev.DurSec < ev.AttackSec THEN ev.DurSec / ev.AttackSec
                           ELSE ev.Sustain + (1.0 - ev.Sustain) * EXP(-(ev.DurSec - ev.AttackSec) / ev.DecaySec) END
                      * EXP(-(tt.t - ev.DurSec) / ev.ReleaseSec)
                 END AS e) env
        CROSS APPLY (SELECT osc.x * (1.0 + ev.Drive) / (1.0 + ev.Drive * ABS(osc.x)) AS y) sat
        WHERE   ev.Waveform <> 'acid';

        -- 2b. Acid: additive saw, harmonic k weighted 1/k * exp(-k / brightness).
        --     Brightness falls with its own envelope, so the "filter" closes
        --     over each note -- the classic squelch, as a SUM over harmonics.
        INSERT #voice (n, v)
        SELECT  a.n, a.Amp * env.e * (a.x * (1.0 + a.Drive) / (1.0 + a.Drive * ABS(a.x)))
        FROM
        (
            SELECT  g.value AS n, ev.EventId, ev.Amp, ev.Drive, ev.DurSec,
                    ev.AttackSec, ev.DecaySec, ev.Sustain, ev.ReleaseSec,
                    CAST(g.value - ev.StartS AS float) / @sr AS t,
                    0.9 * SUM(SIN(@twoPi * h.value * ev.Freq * (CAST(g.value - ev.StartS AS float) / @sr))
                              / h.value
                              * EXP(-h.value / (1.2 + 16.0 * EXP(-(CAST(g.value - ev.StartS AS float) / @sr) / ev.DecaySec)))
                             ) AS x
            FROM    #ev ev
            CROSS APPLY GENERATE_SERIES(GREATEST(ev.StartS, @StartSample), LEAST(ev.EndS, @last)) g
            CROSS JOIN GENERATE_SERIES(1, 40) h
            WHERE   ev.Waveform = 'acid'
              AND   h.value * ev.Freq < @sr / 2.0                          -- stay under Nyquist
              -- skip harmonics the "filter" has already rolled off (weight < e^-6);
              -- as each note's filter closes, it costs fewer rows
              AND   h.value <= 6.0 * (1.2 + 16.0 * EXP(-(CAST(g.value - ev.StartS AS float) / @sr) / ev.DecaySec)) + 1.0
            GROUP BY g.value, ev.EventId, ev.StartS, ev.Amp, ev.Drive, ev.DurSec,
                     ev.AttackSec, ev.DecaySec, ev.Sustain, ev.ReleaseSec
        ) a
        CROSS APPLY (SELECT CASE
                 WHEN a.t <= a.DurSec THEN
                      CASE WHEN a.t < a.AttackSec THEN a.t / a.AttackSec
                           ELSE a.Sustain + (1.0 - a.Sustain) * EXP(-(a.t - a.AttackSec) / a.DecaySec) END
                 ELSE
                      CASE WHEN a.DurSec < a.AttackSec THEN a.DurSec / a.AttackSec
                           ELSE a.Sustain + (1.0 - a.Sustain) * EXP(-(a.DurSec - a.AttackSec) / a.DecaySec) END
                      * EXP(-(a.t - a.DurSec) / a.ReleaseSec)
                 END AS e) env;

        /* 3 + 4. Mix, clip, quantise, pack ------------------------------- */
        DECLARE @hex varchar(max);

        WITH mix AS
        (
            SELECT n, SUM(v) AS x FROM #voice GROUP BY n
        ),
        smp AS
        (
            SELECT  s.value AS n,
                    ISNULL(m.x, 0.0) * @gain AS x
            FROM    GENERATE_SERIES(@StartSample, @last) s
            LEFT JOIN mix m ON m.n = s.value
        ),
        q AS
        (
            SELECT  n,
                    CAST(ROUND(32767.0 *
                        CASE WHEN x >  1.0 THEN  1.0
                             WHEN x < -1.0 THEN -1.0
                             ELSE 1.5 * x - 0.5 * x * x * x         -- cubic soft clip
                        END, 0) AS int) AS i
            FROM smp
        )
        SELECT @hex = STRING_AGG(
                   CAST(CONVERT(varchar(4),
                        SUBSTRING(CAST(i AS binary(4)), 4, 1) + SUBSTRING(CAST(i AS binary(4)), 3, 1), 2)
                   AS varchar(max)), '')
               WITHIN GROUP (ORDER BY n)
        FROM q;

        SET @Pcm = CONVERT(varbinary(max), @hex, 2);
    END;

    IF @WithHeader = 1
        SET @Pcm = synth.WavHeader(DATALENGTH(@Pcm), @sr) + @Pcm;

    SELECT @Pcm AS Pcm;
END;
GO
