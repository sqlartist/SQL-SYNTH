/* =====================================================================
   SQL-SYNTH  |  05_mod_engine.sql
   synth.LoadMod           parse a .mod file (varbinary) into tables
   synth.BuildModTimeline  the "conductor": rows -> ticks, effects resolved
   synth.RenderMod         set-based stereo resampler + mixer -> WAV/PCM
   synth.ModInfo           what the player needs to know
   Requires 02_render.sql (for synth.LE16/LE32).
   ===================================================================== */
USE SqlSynth;
GO

/* Stage 3 columns, added in place so already-loaded modules survive. */
IF COL_LENGTH('synth.ModSample', 'RateScale') IS NULL
    ALTER TABLE synth.ModSample ADD RateScale float NOT NULL CONSTRAINT DF_ModSample_RateScale DEFAULT 1.0;
IF COL_LENGTH('synth.ModSample', 'Bits') IS NULL
    ALTER TABLE synth.ModSample ADD Bits tinyint NOT NULL CONSTRAINT DF_ModSample_Bits DEFAULT 8;
GO

/* Zero-terminated Amiga string -> varchar, non-printables as spaces. */
CREATE OR ALTER FUNCTION synth.ModString (@b varbinary(100))
RETURNS varchar(100)
AS
BEGIN
    DECLARE @i int = 1, @n int = ISNULL(DATALENGTH(@b), 0), @out varchar(100) = '', @c int;
    WHILE @i <= @n
    BEGIN
        SET @c = CAST(SUBSTRING(@b, @i, 1) AS tinyint);
        IF @c = 0 BREAK;
        SET @out += CASE WHEN @c BETWEEN 32 AND 126 THEN CHAR(@c) ELSE ' ' END;
        SET @i += 1;
    END;
    RETURN RTRIM(@out);
END;
GO

/* 44-byte WAV header, 16-bit PCM, any channel count. */
CREATE OR ALTER FUNCTION synth.WavHeaderEx (@DataBytes bigint, @SampleRate int, @Channels int)
RETURNS binary(44)
AS
BEGIN
    RETURN CAST('RIFF' AS binary(4)) + synth.LE32(36 + @DataBytes)
         + CAST('WAVE' AS binary(4))
         + CAST('fmt ' AS binary(4)) + synth.LE32(16)
         + synth.LE16(1)
         + synth.LE16(@Channels)
         + synth.LE32(@SampleRate)
         + synth.LE32(@SampleRate * 2 * @Channels)
         + synth.LE16(2 * @Channels)
         + synth.LE16(16)
         + CAST('data' AS binary(4)) + synth.LE32(@DataBytes);
END;
GO

/* =====================================================================
   THE CONDUCTOR
   Playing a MOD is inherently sequential at the row level: Fxx changes
   the speed, Bxx/Dxx jump around, slides carry state from row to row.
   So this walks the song one row at a time -- a few thousand iterations.
   Within a row, every channel and every tick is computed set-based,
   because each effect has a closed form in the tick number k.
   The output (synth.ModTick) is a flat list of "channel c plays sample s
   from position p at step d and volume v for this many output samples",
   which is all the set-based renderer needs.
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.BuildModTimeline
    @ModId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @sr int, @songLen int, @chans int;
    SELECT @sr = SampleRate, @songLen = SongLength, @chans = Channels
    FROM synth.Mod WHERE ModId = @ModId;
    IF @sr IS NULL THROW 50020, 'synth.BuildModTimeline: unknown ModId', 1;

    DELETE synth.ModTick WHERE ModId = @ModId;
    DELETE synth.ModRow  WHERE ModId = @ModId;

    DECLARE @speed int = 6, @tempo int = 125,          -- ProTracker defaults: 6 ticks/row, 50 Hz
            @pos int = 0, @row int = 0, @seq int = 0,
            @t float = 0.0,                            -- song time, seconds
            @tickSec float, @pat int,
            @nextPos int, @nextRow int, @jumpPos int, @breakRow int, @stop bit, @v int;

    DECLARE @visited TABLE (Position int NOT NULL, RowNo int NOT NULL, PRIMARY KEY (Position, RowNo));

    /* Table variables, not temp tables: in a loop of thousands of tiny
       statements, temp-table statistics trigger constant recompiles. */
    DECLARE @ch TABLE
    (
        Channel int PRIMARY KEY, Latch int, PlaySample int, Finetune int,
        Period float, Target float, PortaSpeed int, Volume int,
        VibPos int, VibSpeed int, VibDepth int, Pos float, Scale float
    );
    INSERT @ch SELECT value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0 FROM GENERATE_SERIES(0, @chans - 1);

    DECLARE @cell TABLE (Channel int PRIMARY KEY, SampleNo int, Period int, Effect int, Param int);

    DECLARE @tick TABLE
    (
        Channel int, K int, StartSample bigint, TickSamples int, PlaySample int,
        Volume int, BasePeriod float, Step float, PosAtStart float, Effect int,
        PRIMARY KEY (Channel, K)
    );

    /* The loop only writes to these buffers; the permanent tables get one
       bulk insert at the end instead of thousands of logged single inserts. */
    DECLARE @rowbuf TABLE
    (
        SeqNo int PRIMARY KEY, Position int, PatternNo int, RowNo int,
        StartSample bigint, Speed int, Tempo int
    );
    DECLARE @tickbuf TABLE
    (
        StartSample bigint, Channel int, TickSamples int, SampleNo int,
        PosAtStart float, Step float, Volume int,
        PRIMARY KEY (StartSample, Channel)
    );

    WHILE @pos < @songLen AND @seq < 60000
    BEGIN
        -- A row we've already played means the song has looped: stop there.
        IF EXISTS (SELECT 1 FROM @visited WHERE Position = @pos AND RowNo = @row) BREAK;
        INSERT @visited VALUES (@pos, @row);

        SELECT @pat = PatternNo FROM synth.ModOrder WHERE ModId = @ModId AND Position = @pos;

        DELETE @cell;
        INSERT @cell (Channel, SampleNo, Period, Effect, Param)
        SELECT c.value, ISNULL(n.SampleNo, 0), ISNULL(n.Period, 0), ISNULL(n.Effect, 0), ISNULL(n.Param, 0)
        FROM GENERATE_SERIES(0, @chans - 1) c
        LEFT JOIN synth.ModNote n
               ON n.ModId = @ModId AND n.PatternNo = @pat AND n.RowNo = @row AND n.Channel = c.value;

        /* ---- global effects: Fxx speed/tempo, Bxx jump, Dxx break ---- */
        SELECT @v = NULL, @jumpPos = NULL, @breakRow = NULL, @stop = 0;
        SELECT TOP (1) @v = Param FROM @cell WHERE Effect = 15 AND Param BETWEEN 1 AND 31 ORDER BY Channel DESC;
        IF @v IS NOT NULL SET @speed = @v;
        SET @v = NULL;
        SELECT TOP (1) @v = Param FROM @cell WHERE Effect = 15 AND Param >= 32 ORDER BY Channel DESC;
        IF @v IS NOT NULL SET @tempo = @v;
        IF EXISTS (SELECT 1 FROM @cell WHERE Effect = 15 AND Param = 0) SET @stop = 1;
        SELECT TOP (1) @jumpPos  = Param FROM @cell WHERE Effect = 11 ORDER BY Channel DESC;
        SELECT TOP (1) @breakRow = (Param / 16) * 10 + (Param % 16) FROM @cell WHERE Effect = 13 ORDER BY Channel DESC;
        IF @breakRow > 63 SET @breakRow = 0;

        SET @tickSec = 2.5E0 / @tempo;

        INSERT @rowbuf (SeqNo, Position, PatternNo, RowNo, StartSample, Speed, Tempo)
        VALUES (@seq, @pos, @pat, @row, CAST(ROUND(@t * @sr, 0) AS bigint), @speed, @tempo);

        /* ---- tick 0: note triggers and one-shot effects, per channel ---- */
        UPDATE ch SET
            Latch      = n.Latch,
            PlaySample = CASE WHEN n.Trig = 1 THEN n.Latch ELSE ch.PlaySample END,
            Finetune   = CASE WHEN n.Trig = 1 THEN ISNULL(sm.Finetune, 0) ELSE ch.Finetune END,
            Scale      = CASE WHEN n.Trig = 1 THEN ISNULL(sm.RateScale, 1.0) ELSE ch.Scale END,
            Period     = fp.P,
            Target     = CASE WHEN c.Period > 0 AND c.Effect IN (3, 5) THEN c.Period ELSE ch.Target END,
            PortaSpeed = CASE WHEN c.Effect = 3 AND c.Param > 0 THEN c.Param ELSE ch.PortaSpeed END,
            VibSpeed   = CASE WHEN c.Effect = 4 AND c.Param / 16 > 0 THEN c.Param / 16 ELSE ch.VibSpeed END,
            VibDepth   = CASE WHEN c.Effect = 4 AND c.Param % 16 > 0 THEN c.Param % 16 ELSE ch.VibDepth END,
            VibPos     = CASE WHEN n.Trig = 1 THEN 0 ELSE ch.VibPos END,
            Pos        = CASE WHEN n.Trig = 1
                              THEN CASE WHEN c.Effect = 9 THEN c.Param * 256.0 ELSE 0.0 END   -- 9xx sample offset
                              ELSE ch.Pos END,
            Volume     = fv.V
        FROM @ch ch
        JOIN @cell c ON c.Channel = ch.Channel
        CROSS APPLY (SELECT CASE WHEN c.SampleNo > 0 THEN c.SampleNo ELSE ch.Latch END AS Latch,
                            CASE WHEN c.Period > 0 AND c.Effect NOT IN (3, 5) THEN 1 ELSE 0 END AS Trig) n
        LEFT JOIN synth.ModSample sm ON sm.ModId = @ModId AND sm.SampleNo = n.Latch
        CROSS APPLY (SELECT CASE WHEN n.Trig = 1 THEN CAST(c.Period AS float) ELSE ch.Period END AS P0) p0
        CROSS APPLY (SELECT CASE WHEN c.Effect = 14 AND c.Param / 16 = 1 THEN GREATEST(113.0, p0.P0 - c.Param % 16)  -- E1x
                                 WHEN c.Effect = 14 AND c.Param / 16 = 2 THEN LEAST(856.0, p0.P0 + c.Param % 16)     -- E2x
                                 ELSE p0.P0 END AS P) fp
        CROSS APPLY (SELECT CASE WHEN c.Effect = 12 THEN LEAST(c.Param, 64)                                           -- Cxx
                                 WHEN c.SampleNo > 0 THEN ISNULL(CAST(sm.Volume AS int), 0)
                                 ELSE ch.Volume END AS V0) v0
        CROSS APPLY (SELECT CASE WHEN c.Effect = 14 AND c.Param / 16 = 10 THEN LEAST(64, v0.V0 + c.Param % 16)       -- EAx
                                 WHEN c.Effect = 14 AND c.Param / 16 = 11 THEN GREATEST(0, v0.V0 - c.Param % 16)     -- EBx
                                 ELSE v0.V0 END AS V) fv;

        /* ---- ticks 0..speed-1, every channel at once ---- */
        DELETE @tick;
        INSERT @tick (Channel, K, StartSample, TickSamples, PlaySample, Volume, BasePeriod, Step, PosAtStart, Effect)
        SELECT ch.Channel, k.value, ts.S0, CAST(ts.S1 - ts.S0 AS int), ch.PlaySample, v.Vol, pb.P, st.Step,
               ch.Pos + ISNULL(SUM(st.Step * (ts.S1 - ts.S0))
                               OVER (PARTITION BY ch.Channel ORDER BY k.value
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0.0),
               c.Effect
        FROM @ch ch
        JOIN @cell c ON c.Channel = ch.Channel
        CROSS JOIN GENERATE_SERIES(0, @speed - 1) k
        CROSS APPLY (SELECT CAST(ROUND((@t +  k.value      * @tickSec) * @sr, 0) AS bigint) AS S0,
                            CAST(ROUND((@t + (k.value + 1) * @tickSec) * @sr, 0) AS bigint) AS S1) ts
        CROSS APPLY (SELECT c.Param / 16 AS X, c.Param % 16 AS Y) xy
        -- volume: Axy slide (also 5xy, 6xy), ECx cut
        CROSS APPLY (SELECT CASE
                 WHEN c.Effect = 14 AND xy.X = 12 AND k.value >= xy.Y THEN 0
                 WHEN c.Effect IN (5, 6, 10)
                      THEN GREATEST(0, LEAST(64, ch.Volume + k.value * CASE WHEN xy.X > 0 THEN xy.X ELSE -xy.Y END))
                 ELSE ch.Volume END AS Vol) v
        -- persistent pitch: 1xx up, 2xx down, 3xx/5xy tone portamento toward Target
        CROSS APPLY (SELECT CASE
                 WHEN c.Effect = 1 THEN GREATEST(113.0, ch.Period - c.Param * k.value)
                 WHEN c.Effect = 2 THEN LEAST(856.0, ch.Period + c.Param * k.value)
                 WHEN c.Effect IN (3, 5) AND ch.Target > 0 THEN
                      CASE WHEN ch.Period > ch.Target THEN GREATEST(ch.Target, ch.Period - ch.PortaSpeed * k.value)
                           ELSE LEAST(ch.Target, ch.Period + ch.PortaSpeed * k.value) END
                 ELSE ch.Period END AS P) pb
        -- momentary pitch: 0xy arpeggio, 4xy/6xy vibrato
        CROSS APPLY (SELECT CASE
                 WHEN c.Effect = 0 AND c.Param > 0
                      THEN pb.P / POWER(CAST(2 AS float),
                                        (CASE k.value % 3 WHEN 0 THEN 0 WHEN 1 THEN xy.X ELSE xy.Y END) / 12.0E0)
                 WHEN c.Effect IN (4, 6)
                      THEN pb.P + ch.VibDepth * 2.0 * SIN(2.0 * PI() * (ch.VibPos + ch.VibSpeed * k.value) / 64.0)
                 ELSE pb.P END AS P) pp
        -- Paula: PAL clock / (2 * period) samples per second, finetune in 1/8 semitones
        CROSS APPLY (SELECT CASE WHEN pp.P > 0 AND ch.PlaySample > 0
                                 THEN 3546894.6 * ch.Scale * POWER(CAST(2 AS float), ch.Finetune / 96.0E0) / (pp.P * @sr)
                                 ELSE 0.0 END AS Step) st;

        INSERT @tickbuf (StartSample, Channel, TickSamples, SampleNo, PosAtStart, Step, Volume)
        SELECT StartSample, Channel, TickSamples, PlaySample, PosAtStart, Step, Volume
        FROM @tick
        WHERE PlaySample > 0 AND Volume > 0 AND Step > 0 AND TickSamples > 0;

        /* ---- carry state into the next row ---- */
        UPDATE ch SET
            Volume = t.Volume,
            Period = CASE WHEN t.Effect IN (1, 2, 3, 5) THEN t.BasePeriod ELSE ch.Period END,
            VibPos = CASE WHEN t.Effect IN (4, 6) THEN (ch.VibPos + ch.VibSpeed * @speed) % 64 ELSE ch.VibPos END,
            Pos    = t.PosAtStart + t.Step * t.TickSamples
        FROM @ch ch
        JOIN @tick t ON t.Channel = ch.Channel AND t.K = @speed - 1;

        /* ---- advance ---- */
        SET @t += @speed * @tickSec;
        SET @seq += 1;
        IF @stop = 1 BREAK;

        IF @jumpPos IS NOT NULL
            SELECT @nextPos = @jumpPos, @nextRow = ISNULL(@breakRow, 0);
        ELSE IF @breakRow IS NOT NULL
            SELECT @nextPos = @pos + 1, @nextRow = @breakRow;
        ELSE IF @row = 63
            SELECT @nextPos = @pos + 1, @nextRow = 0;
        ELSE
            SELECT @nextPos = @pos, @nextRow = @row + 1;

        SELECT @pos = @nextPos, @row = @nextRow;
    END;

    BEGIN TRANSACTION;

    INSERT synth.ModRow (ModId, SeqNo, Position, PatternNo, RowNo, StartSample, Speed, Tempo)
    SELECT @ModId, SeqNo, Position, PatternNo, RowNo, StartSample, Speed, Tempo FROM @rowbuf;

    INSERT synth.ModTick (ModId, StartSample, Channel, TickSamples, SampleNo, PosAtStart, Step, Volume)
    SELECT @ModId, StartSample, Channel, TickSamples, SampleNo, PosAtStart, Step, Volume FROM @tickbuf;

    UPDATE synth.Mod
    SET TotalSamples = CAST(ROUND(@t * @sr, 0) AS bigint) + @sr        -- + 1s for tails
    WHERE ModId = @ModId;

    /* ---- the tracker display, ProTracker style: C-2 01 A0F ---- */
    UPDATE r SET Line = l.Line
    FROM synth.ModRow r
    CROSS APPLY
    (
        SELECT STRING_AGG(f.Cell, ' | ') WITHIN GROUP (ORDER BY c.value) AS Line
        FROM GENERATE_SERIES(0, @chans - 1) c
        LEFT JOIN synth.ModNote n
               ON n.ModId = r.ModId AND n.PatternNo = r.PatternNo AND n.RowNo = r.RowNo AND n.Channel = c.value
        CROSS APPLY (SELECT CAST(ROUND(12.0 * LOG(856.0 / NULLIF(n.Period, 0), 2), 0) AS int) AS I) nt
        CROSS APPLY (SELECT
              CASE WHEN n.Period > 0 THEN
                   CASE WHEN nt.I BETWEEN 0 AND 59
                        THEN SUBSTRING('C-C#D-D#E-F-F#G-G#A-A#B-', (nt.I % 12) * 2 + 1, 2) + CAST(nt.I / 12 + 1 AS varchar(1))
                        ELSE '???' END
                   ELSE '...' END
            + ' ' + CASE WHEN n.SampleNo > 0 THEN CONVERT(varchar(2), CAST(n.SampleNo AS binary(1)), 2) ELSE '..' END
            + ' ' + CASE WHEN n.Effect > 0 OR n.Param > 0
                         THEN SUBSTRING('0123456789ABCDEF', n.Effect + 1, 1) + CONVERT(varchar(2), CAST(n.Param AS binary(1)), 2)
                         ELSE '...' END AS Cell) f
    ) l
    WHERE r.ModId = @ModId;

    COMMIT;
END;
GO

/* =====================================================================
   THE LOADER -- the .mod file is parsed by T-SQL.
     From SSMS:   DECLARE @m varbinary(max) =
                    (SELECT BulkColumn FROM OPENROWSET(BULK N'C:\mods\tune.mod', SINGLE_BLOB) b);
                  EXEC synth.LoadMod @m;
     From Python: modplayer.py --load tune.mod
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.LoadMod
    @Mod        varbinary(max),
    @SampleRate int = 44100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @clock0 datetime2(3) = SYSDATETIME(), @clock1 datetime2(3);
    DECLARE @len bigint = DATALENGTH(@Mod);
    IF @len IS NULL OR @len < 1084
        THROW 50010, 'synth.LoadMod: too short to be a 31-sample MOD file', 1;

    DECLARE @tag char(4) = CAST(SUBSTRING(@Mod, 1081, 4) AS char(4));
    DECLARE @chans int = CASE
        WHEN @tag IN ('M.K.', 'M!K!', 'FLT4', '4CHN') THEN 4
        WHEN @tag LIKE '[1-9]CHN'     THEN CAST(LEFT(@tag, 1) AS int)
        WHEN @tag LIKE '[1-3][0-9]CH' THEN CAST(LEFT(@tag, 2) AS int)
    END;
    IF @chans IS NULL OR @chans > 32
        THROW 50011, 'synth.LoadMod: unrecognised tag at offset 1080 (supported: M.K., M!K!, FLT4, xCHN, xxCH)', 1;

    DECLARE @songLen int = CAST(SUBSTRING(@Mod, 951, 1) AS tinyint);
    IF @songLen NOT BETWEEN 1 AND 128
        THROW 50012, 'synth.LoadMod: song length byte out of range', 1;

    -- 128-byte order list at offset 952; pattern count = highest entry + 1.
    -- ProTracker scans all 128 entries, but some files leave junk past the
    -- song length -- if that makes the file look truncated, trust the song.
    DECLARE @patCount int = 1 + (SELECT MAX(CAST(SUBSTRING(@Mod, 953 + o.value, 1) AS tinyint))
                                 FROM GENERATE_SERIES(0, 127) o);
    IF @len < 1084 + CAST(@patCount AS bigint) * 64 * @chans * 4
        SET @patCount = 1 + (SELECT MAX(CAST(SUBSTRING(@Mod, 953 + o.value, 1) AS tinyint))
                             FROM GENERATE_SERIES(0, @songLen - 1) o);
    DECLARE @dataStart bigint = 1084 + CAST(@patCount AS bigint) * 64 * @chans * 4;   -- 0-based
    IF @len < @dataStart
        THROW 50013, 'synth.LoadMod: file truncated inside the pattern data', 1;

    BEGIN TRANSACTION;

    INSERT synth.Mod (Title, Tag, Channels, SongLength, PatternCount, SampleRate, RawFile)
    VALUES (synth.ModString(SUBSTRING(@Mod, 1, 20)), @tag, @chans, @songLen, @patCount, @SampleRate, @Mod);
    DECLARE @ModId int = SCOPE_IDENTITY();

    INSERT synth.ModOrder (ModId, Position, PatternNo)
    SELECT @ModId, o.value, CAST(SUBSTRING(@Mod, 953 + o.value, 1) AS tinyint)
    FROM GENERATE_SERIES(0, @songLen - 1) o;

    /* 31 sample headers, 30 bytes each, from offset 20. The words are
       big-endian -- the 68000's byte order -- which is exactly how SQL
       Server casts binary to int. No byte-swapping needed on the way in. */
    DROP TABLE IF EXISTS #smp;
    WITH h AS
    (
        SELECT s.value AS SampleNo, 21 + (s.value - 1) * 30 AS O FROM GENERATE_SERIES(1, 31) s
    ),
    f AS
    (
        SELECT SampleNo,
               synth.ModString(SUBSTRING(@Mod, O, 22))           AS Name,
               CAST(SUBSTRING(@Mod, O + 22, 2) AS int) * 2        AS HdrLen,
               CAST(SUBSTRING(@Mod, O + 24, 1) AS tinyint) & 15   AS Ft,
               CAST(SUBSTRING(@Mod, O + 25, 1) AS tinyint)        AS Vol,
               CAST(SUBSTRING(@Mod, O + 26, 2) AS int) * 2        AS LpStart,
               CAST(SUBSTRING(@Mod, O + 28, 2) AS int) * 2        AS LpLen
        FROM h
    )
    SELECT f.SampleNo, f.Name, f.Ft, f.Vol, f.LpStart, f.LpLen,
           @dataStart + SUM(CAST(f.HdrLen AS bigint)) OVER (ORDER BY f.SampleNo ROWS UNBOUNDED PRECEDING)
                      - f.HdrLen AS Offs,
           f.HdrLen
    INTO #smp
    FROM f;

    INSERT synth.ModSample (ModId, SampleNo, Name, LengthBytes, Finetune, Volume, LoopStart, LoopLength)
    SELECT @ModId, s.SampleNo, LEFT(s.Name, 22), ln.Len,
           CASE WHEN s.Ft > 7 THEN s.Ft - 16 ELSE s.Ft END,
           CASE WHEN s.Vol > 64 THEN 64 ELSE s.Vol END,
           lp.LStart, lp.LLen
    FROM #smp s
    CROSS APPLY (SELECT CAST(GREATEST(CAST(0 AS bigint), LEAST(CAST(s.HdrLen AS bigint), @len - s.Offs)) AS int) AS Len) ln  -- truncated files
    CROSS APPLY (SELECT CASE WHEN s.LpLen <= 2 OR s.LpStart >= ln.Len THEN 0 ELSE s.LpStart END AS LStart,
                        CASE WHEN s.LpLen <= 2 OR s.LpStart >= ln.Len THEN 0
                             ELSE LEAST(s.LpLen, ln.Len - s.LpStart) END AS LLen) lp;

    /* Sample data: split the file into 8000-byte chunks first, so that the
       per-byte SUBSTRING works on in-row varbinary(8000), not the LOB. */
    DROP TABLE IF EXISTS #chunk;
    CREATE TABLE #chunk (ChunkNo bigint PRIMARY KEY, Bytes varbinary(8000) NOT NULL);
    INSERT #chunk (ChunkNo, Bytes)
    SELECT c.value, CAST(SUBSTRING(@Mod, c.value * 8000 + 1, 8000) AS varbinary(8000))
    FROM GENERATE_SERIES(CAST(0 AS bigint), (@len - 1) / 8000) c;

    INSERT synth.ModSampleData (ModId, SampleNo, Idx, Value)
    SELECT @ModId, ms.SampleNo, i.value, CASE WHEN b.V > 127 THEN b.V - 256 ELSE b.V END   -- signed 8-bit
    FROM synth.ModSample ms
    JOIN #smp s ON s.SampleNo = ms.SampleNo
    CROSS APPLY GENERATE_SERIES(0, ms.LengthBytes - 1, 1) i          -- explicit step: empty when length is 0
    CROSS APPLY (SELECT s.Offs + i.value AS A) ab
    JOIN #chunk ck ON ck.ChunkNo = ab.A / 8000
    CROSS APPLY (SELECT CAST(SUBSTRING(ck.Bytes, CAST(ab.A % 8000 AS int) + 1, 1) AS tinyint) AS V) b
    WHERE ms.ModId = @ModId;

    /* Pattern cells: 64 rows x channels x 4 bytes, from offset 1084.
         sample = hi nibble of byte0 | hi nibble of byte2
         period = lo nibble of byte0 : byte1   (12 bits)
         effect = lo nibble of byte2, param = byte3                        */
    INSERT synth.ModNote (ModId, PatternNo, RowNo, Channel, SampleNo, Period, Effect, Param)
    SELECT @ModId, p.value, r.value, c.value, x.SampleNo, x.Period, x.Effect, x.Param
    FROM GENERATE_SERIES(0, @patCount - 1) p
    CROSS JOIN GENERATE_SERIES(0, 63) r
    CROSS JOIN GENERATE_SERIES(0, @chans - 1) c
    CROSS APPLY (SELECT CAST(SUBSTRING(@Mod, 1085 + ((p.value * 64 + r.value) * @chans + c.value) * 4, 4) AS binary(4)) AS B) cell
    CROSS APPLY (SELECT CAST(SUBSTRING(cell.B, 1, 1) AS tinyint) AS B0, CAST(SUBSTRING(cell.B, 2, 1) AS tinyint) AS B1,
                        CAST(SUBSTRING(cell.B, 3, 1) AS tinyint) AS B2, CAST(SUBSTRING(cell.B, 4, 1) AS tinyint) AS B3) y
    CROSS APPLY (SELECT (y.B0 & 240) | (y.B2 / 16) AS SampleNo,
                        (y.B0 & 15) * 256 + y.B1   AS Period,
                        y.B2 & 15                  AS Effect,
                        y.B3                       AS Param) x
    WHERE cell.B <> 0x00000000;

    COMMIT;
    SET @clock1 = SYSDATETIME();

    EXEC synth.BuildModTimeline @ModId;

    SELECT m.ModId, m.Title, m.Tag, m.Channels, m.SongLength, m.PatternCount,
           (SELECT COUNT(*) FROM synth.ModSample     WHERE ModId = m.ModId AND LengthBytes > 0) AS Samples,
           (SELECT COUNT(*) FROM synth.ModSampleData WHERE ModId = m.ModId)                     AS SamplePoints,
           (SELECT COUNT(*) FROM synth.ModRow        WHERE ModId = m.ModId)                     AS RowsPlayed,
           CAST(m.TotalSamples * 1.0 / m.SampleRate AS decimal(9, 2))                           AS Seconds,
           DATEDIFF(millisecond, @clock0, @clock1) / 1000.0                                     AS ParseSec,
           DATEDIFF(millisecond, @clock1, SYSDATETIME()) / 1000.0                               AS ConductSec
    FROM synth.Mod m WHERE m.ModId = @ModId;
END;
GO

CREATE OR ALTER PROCEDURE synth.ModInfo
    @ModId int
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ModId, Title, Channels, SampleRate, TotalSamples FROM synth.Mod WHERE ModId = @ModId;
END;
GO

/* =====================================================================
   THE MIXER
   For every tick of every channel, GENERATE_SERIES over its output
   samples; position = PosAtStart + i * Step; nearest-neighbour lookup
   (no interpolation -- that's the authentic Paula crunch); loop wrap
   with modulo; pan ProTracker-style L R R L; SUM per output sample.
   Output: 16-bit stereo, as a complete WAV or raw PCM for streaming.
   ===================================================================== */
CREATE OR ALTER PROCEDURE synth.RenderMod
    @ModId        int,
    @StartSample  bigint = 0,
    @SampleCount  bigint = NULL,
    @WithHeader   bit    = 1,
    @Stats        bit    = 0          -- 1 = also return a second result set of work counts
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @nTicks int = 0, @nPoints int = 0, @nLookups int = 0, @nMixed int = 0;
    DECLARE @sr int, @total bigint, @gain float, @sep float;
    SELECT @sr = SampleRate, @total = TotalSamples, @gain = MasterGain, @sep = StereoSeparation
    FROM synth.Mod WHERE ModId = @ModId;
    IF @sr IS NULL THROW 50030, 'synth.RenderMod: unknown ModId', 1;
    IF @total IS NULL THROW 50031, 'synth.RenderMod: run synth.BuildModTimeline first', 1;

    IF @SampleCount IS NULL OR @StartSample + @SampleCount > @total
        SET @SampleCount = @total - @StartSample;

    DECLARE @Pcm varbinary(max) = 0x;

    IF @SampleCount > 0
    BEGIN
        DECLARE @last bigint = @StartSample + @SampleCount - 1;
        DECLARE @near float = 0.5 + @sep / 2.0,        -- weight on a channel's own side
                @far  float = 0.5 - @sep / 2.0;
        DECLARE @scale float = @gain / (128.0 * 64.0); -- 8-bit sample x 6-bit volume -> [-1, 1]

        /* Ticks sounding in this chunk (a tick never exceeds ~0.08s, so
           looking back 8192 samples for its start is plenty). */
        DROP TABLE IF EXISTS #tk;
        SELECT t.Channel, t.StartSample, t.TickSamples, t.SampleNo, t.PosAtStart, t.Step, t.Volume,
               s.LengthBytes, s.LoopStart, s.LoopLength,
               CASE WHEN s.Bits = 16 THEN 1.0E0 / 256 ELSE 1.0E0 END AS BitScale
        INTO #tk
        FROM synth.ModTick t
        JOIN synth.ModSample s ON s.ModId = t.ModId AND s.SampleNo = t.SampleNo
        WHERE t.ModId = @ModId
          AND t.StartSample BETWEEN @StartSample - 8192 AND @last
          AND t.StartSample + t.TickSamples - 1 >= @StartSample
          AND s.LengthBytes > 0;
        SET @nTicks = @@ROWCOUNT;

        /* Materialised in steps, so the optimiser always has real row
           counts to plan with. (One big CTE let it pick a plan that re-ran
           the whole mix for every output sample.) */

        -- 1. only the sample data this chunk can touch
        DROP TABLE IF EXISTS #sd;
        SELECT d.SampleNo, d.Idx,
               CAST(d.Value AS float) * CASE WHEN s.Bits = 16 THEN 1.0E0 / 256 ELSE 1.0E0 END AS V
        INTO #sd
        FROM synth.ModSampleData d
        JOIN synth.ModSample s ON s.ModId = d.ModId AND s.SampleNo = d.SampleNo
        WHERE d.ModId = @ModId
          AND d.SampleNo IN (SELECT SampleNo FROM #tk);
        SET @nPoints = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX IX_sd ON #sd (SampleNo, Idx);

        -- 2. every (output sample, channel) -> which sample point, at what weights
        DROP TABLE IF EXISTS #pt;
        SELECT g.value AS n, tk.SampleNo, m.Idx,
               tk.Volume * CASE WHEN tk.Channel % 4 IN (0, 3) THEN @near ELSE @far END AS WL,
               tk.Volume * CASE WHEN tk.Channel % 4 IN (0, 3) THEN @far ELSE @near END AS WR
        INTO #pt
        FROM #tk tk
        CROSS APPLY GENERATE_SERIES(GREATEST(tk.StartSample, @StartSample),
                                    LEAST(tk.StartSample + tk.TickSamples - 1, @last),
                                    CAST(1 AS bigint)) g
        CROSS APPLY (SELECT CAST(FLOOR(tk.PosAtStart + (g.value - tk.StartSample) * tk.Step) AS bigint) AS P) p
        CROSS APPLY (SELECT CAST(CASE
                 WHEN tk.LoopLength > 2 AND p.P >= tk.LoopStart + tk.LoopLength
                      THEN tk.LoopStart + (p.P - tk.LoopStart) % tk.LoopLength
                 WHEN p.P < tk.LengthBytes THEN p.P
                 END AS int) AS Idx) m                                       -- NULL = sample has ended
        WHERE m.Idx IS NOT NULL;
        SET @nLookups = @@ROWCOUNT;

        -- 3. look up and mix: SUM per output sample
        DROP TABLE IF EXISTS #mix;
        SELECT p.n, SUM(sd.V * p.WL) * @scale AS L, SUM(sd.V * p.WR) * @scale AS R
        INTO #mix
        FROM #pt p
        JOIN #sd sd ON sd.SampleNo = p.SampleNo AND sd.Idx = p.Idx
        GROUP BY p.n;
        SET @nMixed = @@ROWCOUNT;
        CREATE UNIQUE CLUSTERED INDEX IX_mix ON #mix (n);

        -- 4. clip, quantise, byte-swap, hex, STRING_AGG in sample order
        DECLARE @hex varchar(max);

        WITH q AS
        (
            SELECT s.value AS n,
                   CAST(ROUND(32767.0 * CASE WHEN ISNULL(m.L, 0) > 1 THEN 1 WHEN ISNULL(m.L, 0) < -1 THEN -1 ELSE ISNULL(m.L, 0) END, 0) AS int) AS L,
                   CAST(ROUND(32767.0 * CASE WHEN ISNULL(m.R, 0) > 1 THEN 1 WHEN ISNULL(m.R, 0) < -1 THEN -1 ELSE ISNULL(m.R, 0) END, 0) AS int) AS R
            FROM GENERATE_SERIES(@StartSample, @last) s
            LEFT JOIN #mix m ON m.n = s.value
        )
        SELECT @hex = STRING_AGG(CAST(CONVERT(varchar(8),
                        SUBSTRING(CAST(L AS binary(4)), 4, 1) + SUBSTRING(CAST(L AS binary(4)), 3, 1)
                      + SUBSTRING(CAST(R AS binary(4)), 4, 1) + SUBSTRING(CAST(R AS binary(4)), 3, 1), 2)
                      AS varchar(max)), '') WITHIN GROUP (ORDER BY n)
        FROM q
        OPTION (RECOMPILE);

        SET @Pcm = CONVERT(varbinary(max), @hex, 2);
    END;

    IF @WithHeader = 1
        SET @Pcm = synth.WavHeaderEx(DATALENGTH(@Pcm), @sr, 2) + @Pcm;

    SELECT @Pcm AS Pcm;

    IF @Stats = 1
        SELECT @nTicks AS Ticks, @nPoints AS SamplePoints, @nLookups AS Lookups, @nMixed AS MixedSamples;
END;
GO
