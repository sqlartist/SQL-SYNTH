/* =====================================================================
   SQL-SYNTH  |  03_demo_song.sql
   "Set-Based Breakbeat" -- an original big-beat style test tune.
   135 BPM, E minor, 16-row patterns (one bar of sixteenths each).
   ===================================================================== */
USE SqlSynth;
GO

DELETE synth.SongOrder;
DELETE synth.PatternNote;
DELETE synth.Pattern;
DELETE synth.Song;
DELETE synth.Instrument;

INSERT synth.Instrument (InstrumentId, Name, Waveform, AttackSec, DecaySec, Sustain, ReleaseSec, Volume, Drive)
VALUES (1, 'Kick',      'kick',   0.001, 0.22,  0.0, 0.01, 0.85, 0.8),
       (2, 'Snare',     'snare',  0.001, 0.09,  0.0, 0.01, 0.60, 0.5),
       (3, 'HatClosed', 'hat',    0.001, 0.025, 0.0, 0.01, 0.30, 0.0),
       (4, 'HatOpen',   'hat',    0.001, 0.14,  0.0, 0.01, 0.22, 0.0),
       (5, 'Acid',      'acid',   0.003, 0.11,  0.45, 0.04, 0.55, 2.5),
       (6, 'Stab',      'square', 0.004, 0.12,  0.25, 0.10, 0.10, 0.0),
       (7, 'Sub',       'sine',   0.005, 0.40,  0.85, 0.05, 0.45, 0.3),
       (8, 'Riser',     'noise',  1.60,  5.00,  1.0,  0.02, 0.12, 0.0);

INSERT synth.Song (SongId, Title, Bpm, RowsPerBeat, SampleRate, MasterGain)
VALUES (1, 'Set-Based Breakbeat', 135, 4, 44100, 0.65);

INSERT synth.Pattern (PatternId, Name, PatternRows)
VALUES (1, 'Beat', 16), (2, 'Beat+Acid', 16), (3, 'Full', 16), (4, 'Break', 16), (5, 'Drop', 16);

/* Channels:  0 kick | 1 snare | 2 hats | 3 acid | 4-5 stab | 6 sub | 7 fx */

-- Pattern 1: the breakbeat
INSERT synth.PatternNote (PatternId, Channel, RowNo, InstrumentId, Note, LengthRows, Velocity)
VALUES (1, 0,  0, 1, 36, 1, 1.00), (1, 0,  6, 1, 36, 1, 0.80), (1, 0, 10, 1, 36, 1, 0.95),
       (1, 1,  4, 2, 38, 1, 1.00), (1, 1,  7, 2, 38, 1, 0.30), (1, 1, 12, 2, 38, 1, 1.00),
       (1, 1, 15, 2, 38, 1, 0.35),
       (1, 2,  0, 3, 42, 1, 0.9),  (1, 2,  2, 3, 42, 1, 0.6),  (1, 2,  4, 3, 42, 1, 0.9),
       (1, 2,  6, 3, 42, 1, 0.6),  (1, 2,  8, 3, 42, 1, 0.9),  (1, 2, 10, 3, 42, 1, 0.6),
       (1, 2, 12, 3, 42, 1, 0.9),  (1, 2, 14, 4, 46, 1, 0.8);

-- Patterns 2, 3, 5 all start from the same drums
INSERT synth.PatternNote (PatternId, Channel, RowNo, InstrumentId, Note, LengthRows, Velocity)
SELECT p.PatternId, pn.Channel, pn.RowNo, pn.InstrumentId, pn.Note, pn.LengthRows, pn.Velocity
FROM synth.PatternNote pn
CROSS JOIN (VALUES (2), (3), (5)) p(PatternId)
WHERE pn.PatternId = 1;

-- The acid line (E minor), on 2, 3, 4 and 5
INSERT synth.PatternNote (PatternId, Channel, RowNo, InstrumentId, Note, LengthRows, Velocity)
SELECT p.PatternId, 3, a.RowNo, 5, a.Note, a.LengthRows, a.Velocity
FROM (VALUES ( 0, 40, 1, 1.00), ( 2, 40, 1, 0.70), ( 3, 52, 1, 0.90), ( 5, 43, 1, 0.75),
             ( 6, 40, 1, 0.70), ( 8, 45, 2, 1.00), (10, 40, 1, 0.70), (11, 50, 1, 0.95),
             (13, 47, 1, 0.80), (14, 43, 2, 0.75)) a(RowNo, Note, LengthRows, Velocity)
CROSS JOIN (VALUES (2), (3), (4), (5)) p(PatternId);

-- Stabs: a bare fifth (E-B, then D-A) across two channels, on 3 and 5
INSERT synth.PatternNote (PatternId, Channel, RowNo, InstrumentId, Note, LengthRows, Velocity)
SELECT p.PatternId, s.Channel, s.RowNo, 6, s.Note, s.LengthRows, 1.0
FROM (VALUES (4,  0, 64, 2), (5,  0, 71, 2),
             (4,  6, 64, 1), (5,  6, 71, 1),
             (4, 10, 62, 3), (5, 10, 69, 3)) s(Channel, RowNo, Note, LengthRows)
CROSS JOIN (VALUES (3), (5)) p(PatternId);

-- Pattern 4: the break -- no kick, hats, a snare roll and a noise riser
INSERT synth.PatternNote (PatternId, Channel, RowNo, InstrumentId, Note, LengthRows, Velocity)
VALUES (4, 2,  0, 3, 42, 1, 0.8), (4, 2,  2, 3, 42, 1, 0.5), (4, 2,  4, 3, 42, 1, 0.8), (4, 2,  6, 3, 42, 1, 0.5),
       (4, 1,  8, 2, 38, 1, 0.30), (4, 1,  9, 2, 38, 1, 0.35), (4, 1, 10, 2, 38, 1, 0.45), (4, 1, 11, 2, 38, 1, 0.55),
       (4, 1, 12, 2, 38, 1, 0.65), (4, 1, 13, 2, 38, 1, 0.75), (4, 1, 14, 2, 38, 1, 0.90), (4, 1, 15, 2, 38, 1, 1.00),
       (4, 7,  0, 8, 60, 16, 1.0);

-- Pattern 5: the drop -- everything plus a sub bass
INSERT synth.PatternNote (PatternId, Channel, RowNo, InstrumentId, Note, LengthRows, Velocity)
VALUES (5, 6,  0, 7, 40, 6, 1.0), (5, 6,  8, 7, 45, 4, 1.0), (5, 6, 12, 7, 43, 4, 1.0);

-- Arrangement
INSERT synth.SongOrder (SongId, Position, PatternId)
VALUES (1, 0, 1), (1, 1, 1), (1, 2, 2), (1, 3, 2), (1, 4, 3), (1, 5, 3),
       (1, 6, 4), (1, 7, 5), (1, 8, 5), (1, 9, 5), (1, 10, 3), (1, 11, 1);
GO

/* Try it:
     EXEC synth.SongInfo 1;
     SELECT RowNo, Line FROM synth.TrackerLine WHERE SongId = 1 AND Position = 7 ORDER BY RowNo;
     EXEC synth.RenderPcm @SongId = 1, @StartSample = 0, @SampleCount = 44100;   -- first second, as a .wav
*/
