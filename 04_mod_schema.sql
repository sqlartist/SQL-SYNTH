/* =====================================================================
   SQL-SYNTH  |  04_mod_schema.sql
   Stage 2: a ProTracker .mod player. The module file itself is parsed
   by T-SQL, its instruments are real 8-bit Amiga samples held as rows,
   and SQL Server resamples and mixes them like Paula did.
   ===================================================================== */
USE SqlSynth;
GO

DROP TABLE IF EXISTS synth.ModRow;
DROP TABLE IF EXISTS synth.ModTick;
DROP TABLE IF EXISTS synth.ModNote;
DROP TABLE IF EXISTS synth.ModOrder;
DROP TABLE IF EXISTS synth.ModSampleData;
DROP TABLE IF EXISTS synth.ModSample;
DROP TABLE IF EXISTS synth.Mod;
GO

CREATE TABLE synth.Mod
(
    ModId             int IDENTITY(1,1) PRIMARY KEY,
    Title             varchar(20)    NOT NULL,
    Tag               char(4)        NOT NULL,          -- 'M.K.', '6CHN', ...
    Channels          tinyint        NOT NULL,
    SongLength        tinyint        NOT NULL,          -- positions in the order list
    PatternCount      smallint       NOT NULL,
    SampleRate        int            NOT NULL DEFAULT 44100 CHECK (SampleRate BETWEEN 8000 AND 96000),
    MasterGain        float          NOT NULL DEFAULT 0.6,
    StereoSeparation  float          NOT NULL DEFAULT 0.6 CHECK (StereoSeparation BETWEEN 0 AND 1),  -- 1 = hard Amiga panning
    TotalSamples      bigint         NULL,              -- filled in by synth.BuildModTimeline
    LoadedAt          datetime2(0)   NOT NULL DEFAULT SYSDATETIME(),
    RawFile           varbinary(max) NOT NULL
);

CREATE TABLE synth.ModSample
(
    ModId        int          NOT NULL REFERENCES synth.Mod(ModId) ON DELETE CASCADE,
    SampleNo     tinyint      NOT NULL,                  -- 1..31
    Name         varchar(22)  NOT NULL,
    LengthBytes  int          NOT NULL,
    Finetune     smallint     NOT NULL,                  -- -8..7, in eighths of a semitone
    Volume       tinyint      NOT NULL,                  -- 0..64
    LoopStart    int          NOT NULL,                  -- bytes
    LoopLength   int          NOT NULL,                  -- bytes; <= 2 means no loop
    RateScale    float        NOT NULL DEFAULT 1.0,      -- sampler slices: native rate / 8287 Hz (C-2)
    Bits         tinyint      NOT NULL DEFAULT 8,        -- 8 for MOD samples, 16 for sampler slices
    CONSTRAINT PK_ModSample PRIMARY KEY (ModId, SampleNo)
);

/* One row per 8-bit sample point. A typical module is 50k-500k rows. */
CREATE TABLE synth.ModSampleData
(
    ModId     int       NOT NULL,
    SampleNo  tinyint   NOT NULL,
    Idx       int       NOT NULL,
    Value     smallint  NOT NULL,                        -- signed: -128..127 (8-bit) or 16-bit
    CONSTRAINT PK_ModSampleData PRIMARY KEY (ModId, SampleNo, Idx),
    CONSTRAINT FK_ModSampleData FOREIGN KEY (ModId, SampleNo)
        REFERENCES synth.ModSample(ModId, SampleNo) ON DELETE CASCADE
);

CREATE TABLE synth.ModOrder
(
    ModId      int       NOT NULL REFERENCES synth.Mod(ModId) ON DELETE CASCADE,
    Position   tinyint   NOT NULL,
    PatternNo  tinyint   NOT NULL,
    CONSTRAINT PK_ModOrder PRIMARY KEY (ModId, Position)
);

/* Non-empty pattern cells only. */
CREATE TABLE synth.ModNote
(
    ModId      int       NOT NULL REFERENCES synth.Mod(ModId) ON DELETE CASCADE,
    PatternNo  tinyint   NOT NULL,
    RowNo      tinyint   NOT NULL,
    Channel    tinyint   NOT NULL,
    SampleNo   tinyint   NOT NULL,                       -- 0 = none
    Period     smallint  NOT NULL,                       -- Amiga period, 0 = none (428 = C-2)
    Effect     tinyint   NOT NULL,                       -- 0..15
    Param      tinyint   NOT NULL,                       -- 0..255
    CONSTRAINT PK_ModNote PRIMARY KEY (ModId, PatternNo, RowNo, Channel)
);

/* The conductor's output: what every channel is doing on every tick.
   The renderer reads nothing else.                                    */
CREATE TABLE synth.ModTick
(
    ModId        int      NOT NULL REFERENCES synth.Mod(ModId) ON DELETE CASCADE,
    StartSample  bigint   NOT NULL,
    Channel      tinyint  NOT NULL,
    TickSamples  int      NOT NULL,
    SampleNo     tinyint  NOT NULL,
    PosAtStart   float    NOT NULL,                      -- position in the sample at tick start
    Step         float    NOT NULL,                      -- sample points advanced per output sample
    Volume       tinyint  NOT NULL,                      -- 0..64
    CONSTRAINT PK_ModTick PRIMARY KEY (ModId, StartSample, Channel)
);

/* The played sequence of rows (after jumps and breaks), for display. */
CREATE TABLE synth.ModRow
(
    ModId        int           NOT NULL REFERENCES synth.Mod(ModId) ON DELETE CASCADE,
    SeqNo        int           NOT NULL,
    Position     tinyint       NOT NULL,
    PatternNo    tinyint       NOT NULL,
    RowNo        tinyint       NOT NULL,
    StartSample  bigint        NOT NULL,
    Speed        tinyint       NOT NULL,
    Tempo        tinyint       NOT NULL,
    Line         varchar(600)  NULL,
    CONSTRAINT PK_ModRow PRIMARY KEY (ModId, SeqNo)
);
GO
