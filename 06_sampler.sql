/* =====================================================================
   SQL-SYNTH  |  06_sampler.sql
   Stage 3: the sampler. Load a WAV of a record you own, let SQL Server
   find the beat, chop it into beat slices, and turn those slices into a
   tracker kit -- the way hardcore was made on an Akai in 1992.
   The kit plays through the MOD engine (05), so re-run 05 first.

     synth.LoadWav          parse RIFF/WAVE, store it, detect BPM, slice it
     synth.DetectBeats      onset envelope -> autocorrelation -> comb search
     synth.SliceSource      cut the beat grid into slices
     synth.SamplerBars      a bar-by-bar loudness map, to pick a section
     synth.SamplerMakeSong  slices -> 16-bit kit + patterns (straight + remix)
     synth.PutNote / synth.SetOrder   remix by hand, then BuildModTimeline
   ===================================================================== */
USE SqlSynth;
GO

DROP TABLE IF EXISTS synth.SamplerSlice;
DROP TABLE IF EXISTS synth.SamplerEnvelope;
DROP TABLE IF EXISTS synth.SamplerChunk;
DROP TABLE IF EXISTS synth.SamplerSource;
GO

CREATE TABLE synth.SamplerSource
(
    SourceId       int IDENTITY(1,1) PRIMARY KEY,
    Name           varchar(100)  NOT NULL,
    SampleRate     int           NOT NULL,
    Channels       tinyint       NOT NULL,
    BlockAlign     smallint      NOT NULL,          -- bytes per frame
    Frames         bigint        NOT NULL,
    DataOffset     bigint        NOT NULL,          -- 0-based offset of the PCM data in the file
    Hop            int           NULL,              -- analysis window, in frames
    Bpm            float         NULL,
    FirstBeatSec   float         NULL,
    SlicesPerBeat  tinyint       NOT NULL DEFAULT 1,
    LoadedAt       datetime2(0)  NOT NULL DEFAULT SYSDATETIME()
);

/* The file, in 8000-byte rows: every 16-bit read is an in-row SUBSTRING. */
CREATE TABLE synth.SamplerChunk
(
    SourceId  int             NOT NULL REFERENCES synth.SamplerSource(SourceId) ON DELETE CASCADE,
    ChunkNo   bigint          NOT NULL,
    Bytes     varbinary(8000) NOT NULL,
    CONSTRAINT PK_SamplerChunk PRIMARY KEY (SourceId, ChunkNo)
);

/* ~5 ms analysis windows: energy and onset strength. */
CREATE TABLE synth.SamplerEnvelope
(
    SourceId  int    NOT NULL REFERENCES synth.SamplerSource(SourceId) ON DELETE CASCADE,
    Win       int    NOT NULL,
    Energy    float  NOT NULL,
    Onset     float  NOT NULL,
    CONSTRAINT PK_SamplerEnvelope PRIMARY KEY (SourceId, Win)
);

CREATE TABLE synth.SamplerSlice
(
    SourceId    int     NOT NULL REFERENCES synth.SamplerSource(SourceId) ON DELETE CASCADE,
    SliceNo     int     NOT NULL,
    StartFrame  bigint  NOT NULL,
    Frames      int     NOT NULL,
    CONSTRAINT PK_SamplerSlice PRIMARY KEY (SourceId, SliceNo)
);
GO

/* Little-endian readers -- WAV is Intel byte order, the reverse of MOD. */
CREATE OR ALTER FUNCTION synth.ReadLE16 (@b varbinary(2))
RETURNS int
AS
BEGIN
    RETURN CAST(SUBSTRING(@b, 2, 1) + SUBSTRING(@b, 1, 1) AS int);
END;
GO

CREATE OR ALTER FUNCTION synth.ReadLE32 (@b varbinary(4))
RETURNS bigint
AS
BEGIN
    RETURN CAST(SUBSTRING(@b, 4, 1) + SUBSTRING(@b, 3, 1) + SUBSTRING(@b, 2, 1) + SUBSTRING(@b, 1, 1) AS bigint);
END;
GO

/* =====================================================================
   BEAT DETECTION, set-based
     1. Energy of the left channel in ~5 ms windows (every 4th frame).
     2. Onset strength = rise in log energy since the previous window.
     3. Autocorrelation of the onset curve over lags for 90-180 BPM:
        a self-join on window number, scored with its 2x and 4x lags so
        breakbeats don't fool it. Best lag, refined by a parabola.
     4. Comb search: 101 candidate tempos within +/-0.5% x every phase
        x every beat of the track, scored by the onset under each beat.
        Brute force, but brute force is just a join. The winner gives the
        BPM to about 0.01% and where the first beat falls.
   Pass @Bpm to skip step 3 (step 4 still refines it).
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.DetectBeats
    @SourceId int,
    @Bpm      float = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @rate int, @frames bigint, @off bigint, @align int;
    SELECT @rate = SampleRate, @frames = Frames, @off = DataOffset, @align = BlockAlign
    FROM synth.SamplerSource WHERE SourceId = @SourceId;
    IF @rate IS NULL THROW 50050, 'synth.DetectBeats: unknown SourceId', 1;

    DECLARE @hop int = @rate / 200;                       -- 220 frames at 44.1 kHz
    DECLARE @fps float = CAST(@rate AS float) / @hop;     -- windows per second
    DECLARE @dec bigint = 4;                              -- analyse every 4th frame

    DELETE synth.SamplerEnvelope WHERE SourceId = @SourceId;

    -- 1. energy per window
    INSERT synth.SamplerEnvelope (SourceId, Win, Energy, Onset)
    SELECT @SourceId, w.Win, w.E, 0.0
    FROM
    (
        SELECT CAST(f.value / @hop AS int) AS Win, SUM(v.V * v.V) AS E
        FROM GENERATE_SERIES(CAST(0 AS bigint), @frames - 1, @dec) f
        CROSS APPLY (SELECT @off + f.value * @align AS A) a
        JOIN synth.SamplerChunk k ON k.SourceId = @SourceId AND k.ChunkNo = a.A / 8000
        CROSS APPLY (SELECT CAST(CAST(SUBSTRING(k.Bytes, CAST(a.A % 8000 AS int) + 2, 1)
                                    + SUBSTRING(k.Bytes, CAST(a.A % 8000 AS int) + 1, 1) AS smallint) AS float) / 32768.0 AS V) v
        GROUP BY CAST(f.value / @hop AS int)
    ) w;

    -- 2. onset = positive change in log energy
    WITH x AS
    (
        SELECT Win, LOG(1E-6 + Energy) AS L FROM synth.SamplerEnvelope WHERE SourceId = @SourceId
    ),
    y AS
    (
        SELECT Win, L - LAG(L, 1, L) OVER (ORDER BY Win) AS D FROM x
    )
    UPDATE e SET Onset = CASE WHEN y.D > 0 THEN y.D ELSE 0.0 END
    FROM synth.SamplerEnvelope e
    JOIN y ON y.Win = e.Win
    WHERE e.SourceId = @SourceId;

    DECLARE @nwin int = (SELECT MAX(Win) FROM synth.SamplerEnvelope WHERE SourceId = @SourceId);

    -- 3. autocorrelation for a first estimate
    IF @Bpm IS NULL
    BEGIN
        DECLARE @lagMin int = FLOOR(60.0 * @fps / 180.0), @lagMax int = CEILING(60.0 * @fps / 90.0);

        -- raw autocorrelation at every lag L, 2L and 4L in the tempo range
        DROP TABLE IF EXISTS #lags, #raw, #ac;
        SELECT DISTINCT l.value * m.M AS Lag
        INTO #lags
        FROM GENERATE_SERIES(@lagMin, @lagMax) l
        CROSS JOIN (VALUES (1), (2), (4)) m(M);

        SELECT g.Lag, SUM(a.Onset * b.Onset) AS R
        INTO #raw
        FROM #lags g
        JOIN synth.SamplerEnvelope a ON a.SourceId = @SourceId
        JOIN synth.SamplerEnvelope b ON b.SourceId = @SourceId AND b.Win = a.Win + g.Lag
        GROUP BY g.Lag;

        /* Breakbeats fool plain autocorrelation: a kick every 1.5 beats
           makes 2/3 tempo look best. A true beat also repeats at 2 and 4
           beats (half-bar, bar), so score R(L) + R(2L)/2 + R(4L)/4, with a
           gentle preference for 130 BPM (half an octave either side). */
        SELECT l.value AS Lag,
               (ISNULL(r1.R, 0) + 0.5 * ISNULL(r2.R, 0) + 0.25 * ISNULL(r4.R, 0))
               * EXP(-0.5 * SQUARE(LOG(60.0 * @fps / l.value / 130.0, 2) / 0.5)) AS R
        INTO #ac
        FROM GENERATE_SERIES(@lagMin, @lagMax) l
        LEFT JOIN #raw r1 ON r1.Lag = l.value
        LEFT JOIN #raw r2 ON r2.Lag = 2 * l.value
        LEFT JOIN #raw r4 ON r4.Lag = 4 * l.value;

        DECLARE @best int, @r0 float, @rm float, @rp float, @lag float;
        SELECT TOP (1) @best = Lag, @r0 = R FROM #ac ORDER BY R DESC;
        SELECT @rm = R FROM #ac WHERE Lag = @best - 1;
        SELECT @rp = R FROM #ac WHERE Lag = @best + 1;
        SET @lag = @best + CASE WHEN @rm IS NOT NULL AND @rp IS NOT NULL AND (@rm - 2 * @r0 + @rp) <> 0
                                THEN 0.5 * (@rm - @rp) / (@rm - 2 * @r0 + @rp) ELSE 0 END;
        SET @Bpm = 60.0 * @fps / @lag;
    END;

    -- 4. comb search over tempo x phase
    DROP TABLE IF EXISTS #cand, #score;
    SELECT c.value AS CandNo, @Bpm * (1.0 + (c.value - 50) * 0.0001) AS Bpm,
           60.0 * @fps / (@Bpm * (1.0 + (c.value - 50) * 0.0001)) AS PeriodWin
    INTO #cand
    FROM GENERATE_SERIES(0, 100) c;

    SELECT c.CandNo, ph.value AS Phase, SUM(e.Onset) AS Score
    INTO #score
    FROM #cand c
    CROSS APPLY GENERATE_SERIES(0, CAST(CEILING(c.PeriodWin) AS int) - 1) ph
    CROSS APPLY GENERATE_SERIES(0, CAST(FLOOR((@nwin - ph.value) / c.PeriodWin) AS int), 1) k
    JOIN synth.SamplerEnvelope e
      ON e.SourceId = @SourceId AND e.Win = CAST(ROUND(ph.value + k.value * c.PeriodWin, 0) AS int)
    GROUP BY c.CandNo, ph.value;

    DECLARE @phase int;
    SELECT TOP (1) @Bpm = c.Bpm, @phase = s.Phase
    FROM #score s JOIN #cand c ON c.CandNo = s.CandNo
    ORDER BY s.Score DESC, ABS(c.CandNo - 50);

    DECLARE @first float = @phase / @fps;
    IF @first > 60.0 / @Bpm - 0.015 SET @first = 0.0;      -- a phase of ~one beat is really zero

    UPDATE synth.SamplerSource
    SET Hop = @hop, Bpm = @Bpm, FirstBeatSec = @first
    WHERE SourceId = @SourceId;
END;
GO

CREATE OR ALTER PROCEDURE synth.SliceSource
    @SourceId      int,
    @SlicesPerBeat tinyint = 1            -- 1, 2 or 4
AS
BEGIN
    SET NOCOUNT ON;
    IF @SlicesPerBeat NOT IN (1, 2, 4) THROW 50051, 'synth.SliceSource: @SlicesPerBeat must be 1, 2 or 4', 1;

    DECLARE @rate int, @frames bigint, @bpm float, @first float;
    SELECT @rate = SampleRate, @frames = Frames, @bpm = Bpm, @first = FirstBeatSec
    FROM synth.SamplerSource WHERE SourceId = @SourceId;
    IF @bpm IS NULL THROW 50052, 'synth.SliceSource: run synth.DetectBeats first', 1;

    DECLARE @len float = 60.0 / @bpm / @SlicesPerBeat * @rate;     -- frames per slice
    DECLARE @start float = @first * @rate;

    DELETE synth.SamplerSlice WHERE SourceId = @SourceId;
    INSERT synth.SamplerSlice (SourceId, SliceNo, StartFrame, Frames)
    SELECT @SourceId, k.value,
           CAST(ROUND(@start + k.value * @len, 0) AS bigint),
           CAST(ROUND(@start + (k.value + 1) * @len, 0) - ROUND(@start + k.value * @len, 0) AS int)
    FROM GENERATE_SERIES(0, CAST(FLOOR((@frames - @start) / @len) AS int) - 1, 1) k;

    UPDATE synth.SamplerSource SET SlicesPerBeat = @SlicesPerBeat WHERE SourceId = @SourceId;
END;
GO

/* =====================================================================
   LOAD A WAV (16-bit PCM, mono or stereo, any sample rate)
     From SSMS:  DECLARE @w varbinary(max) =
                   (SELECT BulkColumn FROM OPENROWSET(BULK N'C:\music\track.wav', SINGLE_BLOB) b);
                 EXEC synth.LoadWav @w, 'my track';
     From Python: sampler.py load track.wav
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.LoadWav
    @Wav            varbinary(max),
    @Name           varchar(100),
    @Bpm            float   = NULL,       -- optional hint; it still gets refined
    @SlicesPerBeat  tinyint = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @SlicesPerBeat NOT IN (1, 2, 4) THROW 50044, 'synth.LoadWav: @SlicesPerBeat must be 1, 2 or 4', 1;

    DECLARE @clock0 datetime2(3) = SYSDATETIME(), @clock1 datetime2(3), @clock2 datetime2(3);
    DECLARE @len bigint = DATALENGTH(@Wav);
    IF @len IS NULL OR @len < 44 OR SUBSTRING(@Wav, 1, 4) <> 0x52494646 OR SUBSTRING(@Wav, 9, 4) <> 0x57415645
        THROW 50040, 'synth.LoadWav: not a RIFF/WAVE file', 1;

    -- walk the RIFF chunks for 'fmt ' and 'data'
    DECLARE @off bigint = 12, @id varbinary(4), @size bigint,
            @fmt int, @chans int, @rate int, @align int, @bits int, @dataOff bigint, @dataSize bigint;
    WHILE @off + 8 <= @len
    BEGIN
        SET @id   = SUBSTRING(@Wav, @off + 1, 4);
        SET @size = synth.ReadLE32(SUBSTRING(@Wav, @off + 5, 4));
        IF @id = 0x666D7420                                   -- 'fmt '
            SELECT @fmt   = synth.ReadLE16(SUBSTRING(@Wav, @off +  9, 2)),
                   @chans = synth.ReadLE16(SUBSTRING(@Wav, @off + 11, 2)),
                   @rate  = synth.ReadLE32(SUBSTRING(@Wav, @off + 13, 4)),
                   @align = synth.ReadLE16(SUBSTRING(@Wav, @off + 21, 2)),
                   @bits  = synth.ReadLE16(SUBSTRING(@Wav, @off + 23, 2));
        ELSE IF @id = 0x64617461 AND @dataOff IS NULL        -- 'data'
        BEGIN
            SET @dataOff  = @off + 8;
            SET @dataSize = LEAST(@size, @len - @dataOff);
        END;
        SET @off += 8 + @size + (@size % 2);
    END;

    IF @fmt IS NULL OR @dataOff IS NULL
        THROW 50041, 'synth.LoadWav: no fmt/data chunk found', 1;
    IF @fmt NOT IN (1, 65534) OR @bits <> 16 OR @chans NOT IN (1, 2) OR @align <> @chans * 2
        THROW 50042, 'synth.LoadWav: needs 16-bit PCM, mono or stereo (export it as 16-bit WAV)', 1;
    IF @dataOff % 2 <> 0
        THROW 50043, 'synth.LoadWav: odd data offset -- unusual file, re-export it', 1;

    BEGIN TRANSACTION;
    INSERT synth.SamplerSource (Name, SampleRate, Channels, BlockAlign, Frames, DataOffset)
    VALUES (@Name, @rate, @chans, @align, @dataSize / @align, @dataOff);
    DECLARE @SourceId int = SCOPE_IDENTITY();

    INSERT synth.SamplerChunk (SourceId, ChunkNo, Bytes)
    SELECT @SourceId, c.value, CAST(SUBSTRING(@Wav, c.value * 8000 + 1, 8000) AS varbinary(8000))
    FROM GENERATE_SERIES(CAST(0 AS bigint), (@len - 1) / 8000) c;
    COMMIT;
    SET @clock1 = SYSDATETIME();

    EXEC synth.DetectBeats @SourceId, @Bpm;
    SET @clock2 = SYSDATETIME();
    EXEC synth.SliceSource @SourceId, @SlicesPerBeat;

    SELECT s.SourceId, s.Name, s.SampleRate, s.Channels,
           CAST(s.Frames * 1.0 / s.SampleRate AS decimal(9, 2))              AS Seconds,
           CAST(s.Bpm AS decimal(9, 3))                                     AS Bpm,
           CAST(s.FirstBeatSec AS decimal(9, 3))                            AS FirstBeatSec,
           (SELECT COUNT(*) FROM synth.SamplerSlice WHERE SourceId = s.SourceId) AS Slices,
           DATEDIFF(millisecond, @clock0, @clock1) / 1000.0                  AS StoreSec,
           DATEDIFF(millisecond, @clock1, @clock2) / 1000.0                  AS DetectSec
    FROM synth.SamplerSource s WHERE s.SourceId = @SourceId;
END;
GO

/* A bar-by-bar map of the track with an ASCII loudness meter, so you can
   pick which section to sample: EXEC synth.SamplerBars 1;               */
CREATE OR ALTER PROCEDURE synth.SamplerBars
    @SourceId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @rate int, @hop int, @bpm float, @first float, @spb int;
    SELECT @rate = SampleRate, @hop = Hop, @bpm = Bpm, @first = FirstBeatSec, @spb = SlicesPerBeat
    FROM synth.SamplerSource WHERE SourceId = @SourceId;

    WITH w AS
    (
        SELECT FLOOR((e.Win * CAST(@hop AS float) / @rate - @first) * @bpm / 240.0) AS Bar,
               10.0 * LOG10(e.Energy + 1E-9) AS Db
        FROM synth.SamplerEnvelope e
        WHERE e.SourceId = @SourceId AND e.Win * CAST(@hop AS float) / @rate >= @first
    ),
    b AS
    (
        SELECT CAST(Bar AS int) AS Bar, AVG(Db) AS Db FROM w GROUP BY Bar
    )
    SELECT b.Bar + 1                                                          AS Bar,
           b.Bar * 4 * @spb                                                   AS FirstSlice,
           CONVERT(varchar(8), DATEADD(millisecond, (@first + b.Bar * 240.0 / @bpm) * 1000, 0), 114) AS StartsAt,
           REPLICATE('#', CAST(GREATEST(0, (b.Db - MIN(b.Db) OVER ()) / NULLIF(MAX(b.Db) OVER () - MIN(b.Db) OVER (), 0) * 40) AS int)) AS Loudness
    FROM b
    ORDER BY b.Bar;
END;
GO

/* =====================================================================
   SLICES -> KIT -> SONG
   Each slice becomes a 16-bit sample in a new synth.Mod, pitched so that
   C-2 plays it at its original speed (C-3 = octave up, C-1 = octave down).
   @Decimate 2 keeps every other frame (22.05 kHz): lighter, and crunchier,
   like the samplers of the day. Straight patterns replay the section
   exactly; with @Remix = 1 you also get a stutter edit, a chipmunk
   pattern and a half-time pattern to hear what the kit can do.
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.SamplerMakeSong
    @SourceId    int,
    @FirstSlice  int         = 0,
    @SliceCount  int         = 32,
    @Decimate    tinyint     = 2,
    @Title       varchar(20) = NULL,
    @Remix       bit         = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @rate int, @chans int, @align int, @off bigint, @bpm float, @spb int, @name varchar(100);
    SELECT @rate = SampleRate, @chans = Channels, @align = BlockAlign, @off = DataOffset,
           @bpm = Bpm, @spb = SlicesPerBeat, @name = Name
    FROM synth.SamplerSource WHERE SourceId = @SourceId;

    IF @rate IS NULL THROW 50060, 'synth.SamplerMakeSong: unknown SourceId', 1;
    IF @SliceCount NOT BETWEEN 1 AND 255 THROW 50061, 'synth.SamplerMakeSong: @SliceCount must be 1-255', 1;
    IF @Decimate NOT BETWEEN 1 AND 4 THROW 50062, 'synth.SamplerMakeSong: @Decimate must be 1-4', 1;
    IF (SELECT COUNT(*) FROM synth.SamplerSlice
        WHERE SourceId = @SourceId AND SliceNo BETWEEN @FirstSlice AND @FirstSlice + @SliceCount - 1) <> @SliceCount
        THROW 50063, 'synth.SamplerMakeSong: that range runs past the slices -- see synth.SamplerBars', 1;

    DECLARE @tempo int = CAST(ROUND(@bpm, 0) AS int);
    IF @tempo NOT BETWEEN 32 AND 255 THROW 50064, 'synth.SamplerMakeSong: BPM outside ProTracker tempo range 32-255', 1;

    DECLARE @scale float = (CAST(@rate AS float) / @Decimate) * 428.0 / 3546894.6;   -- C-2 = original speed
    DECLARE @rps int = 4 / @spb;                                                      -- rows per slice
    DECLARE @nStraight int = CEILING(@SliceCount * @rps / 64.0);

    BEGIN TRANSACTION;

    INSERT synth.Mod (Title, Tag, Channels, SongLength, PatternCount, SampleRate, RawFile)
    VALUES (LEFT(ISNULL(@Title, @name), 20), 'SMPL', 4, 1, 1, 44100, 0x);
    DECLARE @ModId int = SCOPE_IDENTITY();

    INSERT synth.ModSample (ModId, SampleNo, Name, LengthBytes, Finetune, Volume, LoopStart, LoopLength, RateScale, Bits)
    SELECT @ModId, s.SliceNo - @FirstSlice + 1, 'slice ' + RIGHT('0000' + CAST(s.SliceNo AS varchar(6)), 4),
           s.Frames / @Decimate, 0, 64, 0, 0, @scale, 16
    FROM synth.SamplerSlice s
    WHERE s.SourceId = @SourceId AND s.SliceNo BETWEEN @FirstSlice AND @FirstSlice + @SliceCount - 1;

    /* Slice audio: mid (L+R)/2, every @Decimate-th frame, with a 48-point
       fade at each end so the chops don't click. */
    INSERT synth.ModSampleData (ModId, SampleNo, Idx, Value)
    SELECT @ModId, ms.SampleNo, i.value, CAST(ROUND(v.V * fd.F, 0) AS smallint)
    FROM synth.ModSample ms
    JOIN synth.SamplerSlice s
      ON s.SourceId = @SourceId AND s.SliceNo = ms.SampleNo + @FirstSlice - 1
    CROSS APPLY GENERATE_SERIES(0, ms.LengthBytes - 1, 1) i
    CROSS APPLY (SELECT @off + (s.StartFrame + CAST(i.value AS bigint) * @Decimate) * @align AS A) a
    JOIN synth.SamplerChunk kl
      ON kl.SourceId = @SourceId AND kl.ChunkNo = a.A / 8000
    LEFT JOIN synth.SamplerChunk kr
      ON @chans = 2 AND kr.SourceId = @SourceId AND kr.ChunkNo = (a.A + 2) / 8000
    CROSS APPLY (SELECT
            CAST(CAST(SUBSTRING(kl.Bytes, CAST(a.A % 8000 AS int) + 2, 1)
                    + SUBSTRING(kl.Bytes, CAST(a.A % 8000 AS int) + 1, 1) AS smallint) AS float) AS L,
            CASE WHEN @chans = 2 THEN
            CAST(CAST(SUBSTRING(kr.Bytes, CAST((a.A + 2) % 8000 AS int) + 2, 1)
                    + SUBSTRING(kr.Bytes, CAST((a.A + 2) % 8000 AS int) + 1, 1) AS smallint) AS float) END AS R) lr
    CROSS APPLY (SELECT CASE WHEN @chans = 2 THEN (lr.L + lr.R) / 2.0 ELSE lr.L END AS V) v
    CROSS APPLY (SELECT CAST(LEAST(1.0, (i.value + 1) / 48.0, (ms.LengthBytes - i.value) / 48.0) AS float) AS F) fd
    WHERE ms.ModId = @ModId;

    /* Straight patterns: slice n on channel 0 every @rps rows -- replays
       the section as it was. Tempo = BPM (speed 6, 4 rows a beat). */
    INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
    SELECT @ModId, (i.value * @rps) / 64, (i.value * @rps) % 64, 0, i.value + 1, 428, 0, 0
    FROM GENERATE_SERIES(0, @SliceCount - 1) i;

    INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
    VALUES (@ModId, 0, 0, 3, 0, 0, 15, @tempo);                                    -- Fxx tempo

    DECLARE @endRow int = (@SliceCount * @rps - 1) % 64;                            -- last row used
    IF @endRow < 63 AND NOT EXISTS (SELECT 1 FROM synth.ModNote
                                    WHERE ModId = @ModId AND PatternNo = @nStraight - 1 AND RowNo = @endRow AND Channel = 3)
        INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
        VALUES (@ModId, @nStraight - 1, @endRow, 3, 0, 0, 13, 0);                  -- D00: break early

    DECLARE @order TABLE (Seq int PRIMARY KEY, PatternNo int);
    INSERT @order SELECT value, value FROM GENERATE_SERIES(0, @nStraight - 1);

    IF @Remix = 1 AND @spb = 1 AND @SliceCount >= 4
    BEGIN
        DECLARE @r1 int = @nStraight, @r2 int = @nStraight + 1, @r3 int = @nStraight + 2;

        -- R1 stutter: every 4th beat rolls the bar's downbeat, gated with EC3
        INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
        SELECT @ModId, @r1, 4 * b.value + r.value, 0,
               CASE WHEN b.value % 4 = 3 THEN (b.value - 3) % @SliceCount + 1 ELSE b.value % @SliceCount + 1 END,
               428,
               CASE WHEN b.value % 4 = 3 THEN 14  ELSE 0 END,
               CASE WHEN b.value % 4 = 3 THEN 195 ELSE 0 END
        FROM GENERATE_SERIES(0, 15) b
        JOIN GENERATE_SERIES(0, 3) r ON r.value = 0 OR b.value % 4 = 3;

        -- R2 chipmunk: each slice an octave up, twice per beat, over the original tucked underneath
        INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
        SELECT @ModId, @r2, 4 * b.value + 2 * h.value, 1, b.value % @SliceCount + 1, 214, 0, 0
        FROM GENERATE_SERIES(0, 15) b CROSS JOIN GENERATE_SERIES(0, 1) h;
        INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
        SELECT @ModId, @r2, 4 * b.value, 0, b.value % @SliceCount + 1, 428, 12, 24
        FROM GENERATE_SERIES(0, 15) b;

        -- R3 half-time: an octave down, one slice every two beats
        INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
        SELECT @ModId, @r3, 8 * j.value, 0, j.value % @SliceCount + 1, 856, 0, 0
        FROM GENERATE_SERIES(0, 7) j;

        INSERT @order VALUES (1000, @r1), (1001, @r2), (1002, 0), (1003, @r3), (1004, 0);
    END;

    INSERT synth.ModOrder (ModId, Position, PatternNo)
    SELECT @ModId, ROW_NUMBER() OVER (ORDER BY Seq) - 1, PatternNo FROM @order;

    UPDATE synth.Mod
    SET SongLength   = (SELECT COUNT(*) FROM @order),
        PatternCount = (SELECT MAX(PatternNo) + 1 FROM @order)
    WHERE ModId = @ModId;

    COMMIT;

    EXEC synth.BuildModTimeline @ModId;

    SELECT m.ModId, m.Title, @tempo AS Tempo, m.SongLength, m.PatternCount,
           (SELECT COUNT(*) FROM synth.ModSampleData WHERE ModId = m.ModId) AS SamplePoints,
           CAST(m.TotalSamples * 1.0 / m.SampleRate AS decimal(9, 2)) AS Seconds
    FROM synth.Mod m WHERE m.ModId = @ModId;
END;
GO

/* =====================================================================
   REMIX BY HAND
     EXEC synth.PutNote @ModId = 7, @Pattern = 2, @Row = 12, @Channel = 1,
                        @Sample = 5, @Note = 'C-3', @Effect = 0xE, @Param = 0xC2;
     EXEC synth.SetOrder 7, '0,1,2,2,3';
     EXEC synth.BuildModTimeline 7;     -- then play it again
   @Note NULL (or '...') = no note, just an effect. @Sample 0 = keep the last one.
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.PutNote
    @ModId    int,
    @Pattern  int,
    @Row      int,
    @Channel  int,
    @Sample   int     = 0,
    @Note     char(3) = 'C-2',
    @Effect   tinyint = 0,
    @Param    tinyint = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @period int = 0;

    IF @Note IS NOT NULL AND @Note <> '...'
    BEGIN
        DECLARE @p int = CHARINDEX(LEFT(@Note, 2), 'C-C#D-D#E-F-F#G-G#A-A#B-');
        DECLARE @semi int = CASE WHEN @p % 2 = 1 THEN (@p + 1) / 2 - 1 ELSE -1 END;
        DECLARE @oct int = TRY_CAST(RIGHT(@Note, 1) AS int);
        IF @semi < 0 OR @oct IS NULL OR @oct NOT BETWEEN 1 AND 3
            THROW 50070, 'synth.PutNote: @Note must look like C-2 or F#3 (octaves 1-3)', 1;
        SELECT @period = CAST(value AS int)
        FROM STRING_SPLIT('856,808,762,720,678,640,604,570,538,508,480,453,428,404,381,360,339,320,302,285,269,254,240,226,214,202,190,180,170,160,151,143,135,127,120,113', ',', 1)
        WHERE ordinal = (@oct - 1) * 12 + @semi + 1;
    END;

    DELETE synth.ModNote WHERE ModId = @ModId AND PatternNo = @Pattern AND RowNo = @Row AND Channel = @Channel;
    IF @period > 0 OR @Sample > 0 OR @Effect > 0 OR @Param > 0
        INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
        VALUES (@ModId, @Pattern, @Row, @Channel, @Sample, @period, @Effect, @Param);
END;
GO

CREATE OR ALTER PROCEDURE synth.SetOrder
    @ModId int,
    @Order varchar(1000)          -- e.g. '0,1,1,2'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DELETE synth.ModOrder WHERE ModId = @ModId;
    INSERT synth.ModOrder (ModId, Position, PatternNo)
    SELECT @ModId, ROW_NUMBER() OVER (ORDER BY ordinal) - 1, CAST(TRIM(value) AS int)
    FROM STRING_SPLIT(@Order, ',', 1)
    WHERE TRIM(value) <> '';
    UPDATE synth.Mod
    SET SongLength   = (SELECT COUNT(*) FROM synth.ModOrder WHERE ModId = @ModId),
        PatternCount = (SELECT MAX(PatternNo) + 1 FROM synth.ModOrder WHERE ModId = @ModId)
    WHERE ModId = @ModId;
    COMMIT;
END;
GO
