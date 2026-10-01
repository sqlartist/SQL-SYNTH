/* =====================================================================
   SQL-SYNTH  |  01_schema.sql
   A tracker-style synthesiser that lives entirely inside SQL Server.
   Music is stored as data (instruments, patterns, song order) and the
   audio is rendered set-based by synth.RenderPcm.
   Requires SQL Server 2022+ (GENERATE_SERIES, GREATEST/LEAST).
   ===================================================================== */
IF DB_ID('SqlSynth') IS NULL CREATE DATABASE SqlSynth;
GO
ALTER DATABASE SqlSynth SET COMPATIBILITY_LEVEL = 170;   -- GENERATE_SERIES needs 160+ (use 160 on SQL 2022)
GO
USE SqlSynth;
GO
IF SCHEMA_ID('synth') IS NULL EXEC('CREATE SCHEMA synth');
GO

DROP VIEW  IF EXISTS synth.TrackerLine;
DROP VIEW  IF EXISTS synth.SongEvent;
DROP TABLE IF EXISTS synth.SongOrder;
DROP TABLE IF EXISTS synth.PatternNote;
DROP TABLE IF EXISTS synth.Pattern;
DROP TABLE IF EXISTS synth.Song;
DROP TABLE IF EXISTS synth.Instrument;
GO

/* An instrument is an oscillator plus an envelope.
   Tonal waveforms use ADSR (Attack linear, Decay/Release as exponential
   time constants). Drum waveforms (kick/snare/hat) ignore the note length
   and simply decay with time constant DecaySec.
   'acid' is an additive band-limited saw whose harmonics are rolled off
   by an envelope -- a low-pass filter sweep done without recursion.     */
CREATE TABLE synth.Instrument
(
    InstrumentId  tinyint      NOT NULL PRIMARY KEY,
    Name          varchar(30)  NOT NULL,
    Waveform      varchar(10)  NOT NULL
        CHECK (Waveform IN ('sine','square','saw','triangle','noise','acid','kick','snare','hat')),
    AttackSec     float        NOT NULL DEFAULT 0.005 CHECK (AttackSec > 0),
    DecaySec      float        NOT NULL DEFAULT 0.2   CHECK (DecaySec  > 0),
    Sustain       float        NOT NULL DEFAULT 0.6,
    ReleaseSec    float        NOT NULL DEFAULT 0.1   CHECK (ReleaseSec > 0),
    Volume        float        NOT NULL DEFAULT 0.5,
    Drive         float        NOT NULL DEFAULT 0     -- 0 = clean, higher = more saturation
);

CREATE TABLE synth.Song
(
    SongId        int           NOT NULL PRIMARY KEY,
    Title         varchar(100)  NOT NULL,
    Bpm           float         NOT NULL CHECK (Bpm > 0),
    RowsPerBeat   tinyint       NOT NULL DEFAULT 4 CHECK (RowsPerBeat > 0),     -- 4 = sixteenth-note rows
    SampleRate    int           NOT NULL DEFAULT 44100 CHECK (SampleRate BETWEEN 8000 AND 96000),
    MasterGain    float         NOT NULL DEFAULT 0.8
);

CREATE TABLE synth.Pattern
(
    PatternId     int           NOT NULL PRIMARY KEY,
    Name          varchar(30)   NOT NULL,
    PatternRows   tinyint       NOT NULL DEFAULT 16 CHECK (PatternRows > 0)   -- keep PatternNote.RowNo below this
);

/* One cell of the tracker grid: a note on a channel at a row. */
CREATE TABLE synth.PatternNote
(
    PatternId     int      NOT NULL REFERENCES synth.Pattern(PatternId),
    Channel       tinyint  NOT NULL,
    RowNo         tinyint  NOT NULL,
    InstrumentId  tinyint  NOT NULL REFERENCES synth.Instrument(InstrumentId),
    Note          tinyint  NOT NULL,                 -- MIDI note number, 69 = A4 = 440 Hz
    LengthRows    tinyint  NOT NULL DEFAULT 1,
    Velocity      float    NOT NULL DEFAULT 1.0,
    CONSTRAINT PK_PatternNote PRIMARY KEY (PatternId, Channel, RowNo)
);

CREATE TABLE synth.SongOrder
(
    SongId        int       NOT NULL REFERENCES synth.Song(SongId),
    Position      smallint  NOT NULL,
    PatternId     int       NOT NULL REFERENCES synth.Pattern(PatternId),
    CONSTRAINT PK_SongOrder PRIMARY KEY (SongId, Position)
);
GO

/* Every note in the song, on the absolute row timeline. */
CREATE VIEW synth.SongEvent
AS
WITH o AS
(
    SELECT so.SongId, so.Position, so.PatternId,
           SUM(CAST(p.PatternRows AS int)) OVER (PARTITION BY so.SongId ORDER BY so.Position
                                                 ROWS UNBOUNDED PRECEDING)
           - p.PatternRows AS StartRow
    FROM synth.SongOrder so
    JOIN synth.Pattern   p ON p.PatternId = so.PatternId
)
SELECT o.SongId, o.Position, pn.Channel,
       o.StartRow + pn.RowNo AS AbsRow,
       pn.LengthRows, pn.InstrumentId, pn.Note, pn.Velocity
FROM o
JOIN synth.PatternNote pn ON pn.PatternId = o.PatternId;
GO

/* The song as a ProTracker-style display: one line per row. */
CREATE VIEW synth.TrackerLine
AS
SELECT so.SongId, so.Position, so.PatternId, r.value AS RowNo,
       STRING_AGG(
           CASE WHEN pn.Note IS NULL THEN '... ..'
                ELSE SUBSTRING('C-C#D-D#E-F-F#G-G#A-A#B-', (pn.Note % 12) * 2 + 1, 2)
                     + CAST(pn.Note / 12 - 1 AS varchar(2))
                     + ' ' + RIGHT('0' + CAST(pn.InstrumentId AS varchar(3)), 2)
           END, ' | ') WITHIN GROUP (ORDER BY c.Channel) AS Line
FROM synth.SongOrder so
JOIN synth.Pattern p ON p.PatternId = so.PatternId
CROSS APPLY GENERATE_SERIES(0, CAST(p.PatternRows AS int) - 1) r
CROSS JOIN (SELECT DISTINCT Channel FROM synth.PatternNote) c
LEFT JOIN synth.PatternNote pn
       ON pn.PatternId = so.PatternId AND pn.Channel = c.Channel AND pn.RowNo = r.value
GROUP BY so.SongId, so.Position, so.PatternId, r.value;
GO
