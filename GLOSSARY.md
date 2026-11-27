# ScrumTrace

A Mac app that captures a screen session with audio, transcribes and analyses it, and exports a brief and pack an agent can work from.

## Language

### Session lifecycle

**Session**:
One capture of screen and audio, together with everything derived from it.
_Avoid_: recording (as a noun for the thing; "recording" is a **Capture phase**)

**Capture phase**:
Whether a **Session** is being captured at this moment: idle, recording or paused. It describes the live app only.
_Avoid_: status, stage (for this meaning)

**Stage**:
One step of processing a captured **Session**, in fixed order: transcribing, slicing, evaluating, synthesizing, completed. Each **Stage** is either done or not done.
_Avoid_: phase, step, pipeline status

**Session status**:
The one saved word that says where a **Session** last stood: the **Capture phase** at the last save, the **Stage** in progress, completed, or **Offline failed**.
_Avoid_: pipeline status, phase

**Offline failed**:
The **Session status** when processing reached the end but part of the AI analysis could not run.

**Invalidate**:
To mark a **Stage** and every later **Stage** as not done, because their inputs changed.
_Avoid_: reset, clear, drop

### Session classifications

**Unfinished**:
A **Session** whose **Session status** is neither idle nor completed.

**Interrupted**:
A **Session** whose saved **Session status** is still recording or paused although no capture is running: capture ended without a clean stop.

**Resumable**:
An **Unfinished** **Session** whose current **Stage** may restart at launch without the person asking.

**Export ready**:
A **Session** whose synthesizing **Stage** is done and whose brief and agent context exist.

**Needs attention**:
An **Offline failed** **Session** that is not **Export ready**.

**Prunable**:
A completed **Session** that retention may delete once it is old enough.
