# Stream Lab

Stream Lab is an observation-only macOS command-line experiment for comparing AVPlayer state, timed metadata, station-feed entries, and human markers on one replayable timeline. It does not change production playback or infer that the newest feed entry is audible.

The trace/reducer library is Foundation-only. Live capture uses AVFoundation and one explicitly supplied stream URL.

## Current status

Phases 1–3 are complete; the 52-test package suite passes. `capture` and `replay` have been exercised against a local fixture, two attended KCRW AAC/HLS sessions, and one attended KEXP AAC/ICY session; all replay offline. KEXP supplied pre-roll and title metadata, a feed airbreak, and real pause/resume observations, but only three named song markers—not a station timing distribution. A tested selection policy remains outstanding. See the [M10 execution handoff](../../../docs/menubar/milestones/milestone_10_handoff.md), [KCRW results](../../../docs/menubar/experiments/2026-09-26_kcrw_hls_attended.md), and [KEXP results](../../../docs/menubar/experiments/2026-09-27_kexp_aac_attended.md). No production player behavior has changed.

Exit codes: `0` success, `2` usage error (the message is followed by the usage text), `1` any other failure.

## Build and test

From the PocketRadio shell repository:

```bash
swift build --package-path pocket-radio-menubar/Tools/StreamLab
swift test --package-path pocket-radio-menubar/Tools/StreamLab
```

From this directory:

```bash
swift build
swift test
```

Tests use synthetic values only. They do not contact stations, play audio, access accounts, or require credentials.

## Command interface

### Capture

The output file must not already exist.

```bash
swift run --package-path pocket-radio-menubar/Tools/StreamLab stream-lab capture \
  --station kcrw \
  --stream-url 'https://example.invalid/explicit-stream' \
  --output /tmp/kcrw-stream-lab.jsonl \
  --duration 300 \
  --feed-interval 30
```

Required options:

| Option | Meaning |
|---|---|
| `--station kcrw\|kexp` | Selects the station feed parser and default public feed URL |
| `--stream-url URL` | Explicit HTTP(S) stream or local `file://` fixture |
| `--output FILE` | New JSONL trace path; existing files are never overwritten |

Optional options:

| Option | Default | Meaning |
|---|---:|---|
| `--duration SECONDS` | `300` | Capture length, from 1 through 7200 seconds |
| `--feed-interval SECONDS` | `30` | Serial feed-poll interval, from 5 through 300 seconds |
| `--feed-url URL` | Station default | Explicit HTTP(S) feed endpoint |
| `--no-feed` | Off | Disable feed requests; cannot be combined with `--feed-url` |
| `--muted` | Off | Mute AVPlayer output; this prevents an audible-marker experiment |

Do not put signed URLs, credentials, or tokens in shell history or shared documentation. The trace strips URL credentials, queries, and fragments, but input handling is not a secret-management system.

During capture, enter a command followed by Return:

| Command | Recorded action |
|---|---|
| `1` | `heard_song_change` marker |
| `2` | `lyric_landmark` marker |
| `3` | `wrong_artwork` marker |
| `p` | `pause_requested`, then pause AVPlayer |
| `r` | `resume_requested`, then resume AVPlayer |
| `q` | End the capture |

`Ctrl-C` and `SIGTERM` also request a clean end event.

### Replay

```bash
swift run --package-path pocket-radio-menubar/Tools/StreamLab stream-lab replay /tmp/kcrw-stream-lab.jsonl
```

Replay reads only the trace file. It contacts no stream, station feed, account service, or Supabase.

Output is a deterministic text report: a session header, an elapsed-time timeline, a `clock` section, a `feed transitions` section, per-kind counts, and a restatement of the evidence boundary. It depends only on the recorded event sequence, so the same trace always renders byte-identically. Feed entries appear as `top-candidate=`, never as the audible track.

The `clock` section compares the wall-clock span against the monotonic span and names any gap
over 2s. Monotonic time comes from `ProcessInfo.systemUptime`, which freezes while the system is
suspended, so a capture that slept can otherwise pass as a clean shorter one. **Read this section
before trusting any timing number.** Use `caffeinate -is` to prevent the gap in the first place.

The `feed transitions` section includes untitled non-music entries (such as KEXP `airbreak`),
identified by kind, without claiming they were audible. It estimates when the origin held each new feed-top entry, relative
to that entry's claimed airtime. It subtracts recorded HTTP `age` from response receipt times;
missing or invalid `age` is currently treated as zero, not independent proof of freshness. A stale
preceding response may provide no positive publish-lag lower bound, leaving only an upper bound.
The bounds are therefore not necessarily one poll interval apart. They describe feed availability,
not an audible song boundary. A cached entry can still arrive well before buffered playback reaches
that song; cache age alone does not limit playback-aligned title timing.

Replay fails with a single line and a nonzero status when the trace is truncated, incomplete, out of order, or written for an unsupported schema.

## Experiment protocol

### 1. Establish the build

Record:

- menubar commit and dirty state;
- Stream Lab test result;
- macOS version;
- station and sanitized explicit endpoint;
- known transport, if verified rather than inferred;
- output route and whether playback is muted.

Never substitute a station name for the exact stream variant. Different endpoints can have different buffering and metadata behavior.

### 2. Run a local smoke capture

Use synthetic or rights-cleared local audio. Disable the feed unless the fixture includes a local feed service.

The smoke capture passes only when:

- the file contains one start and one explicit end;
- player state samples are present;
- pause and resume markers are present;
- replay succeeds after network access is removed;
- replay produces the same observation snapshots as the captured event sequence.

A plain local audio file can validate playback-signal capture. It cannot validate Icecast metadata interleaving, HLS program-date behavior, or live feed timing.

### 3. Run live observation sessions

For each explicit KCRW and KEXP stream variant:

1. Start an audible capture on the intended output route.
2. Mark each clearly heard song change with `1`.
3. Use `2` only for a recognizable lyric landmark.
4. Exercise one pause/resume cycle.
5. Let the session end cleanly or enter `q`.
6. Disconnect the network.
7. Replay the trace.
8. Compare observations using elapsed time as the diagnostic axis.

Use a short one-transition capture as a command smoke test. For any timing conclusion, observe at least five transitions per station/stream variant and report the distribution and worst case. Do not present a single transition as station policy.

### 4. Keep evidence categories separate

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| Monotonic `elapsedSeconds` | Ordering and intervals inside one capture | Correspondence to an external UTC timestamp |
| Root `wallTime` | Millisecond UTC correlation | A monotonic timing axis or audible boundary |
| AVPlayer media time/ranges | Player-item position and buffering observations | What an external output device emitted at that instant |
| `programDate` | AVPlayer's media-to-date observation when available | Verified song identity or boundary |
| Timed metadata | Metadata delivered for the player item and its recorded range | Guaranteed first audible sample of a song |
| Feed entry and `playedAt` | Broadcaster-side published evidence | That buffered listener audio has reached that entry |
| Human marker | A coarse report of what the listener noticed | Subsecond ground truth |

Feed-top and player metadata remain separate candidates throughout capture and replay. Persisted UTC correlation dates (`wallTime`, `programDate`, and parsed `playedAt`) use millisecond resolution. Monotonic elapsed time and media time retain full `Double` precision and define interval measurement and ordering. A system-clock correction may move wall time backward without invalidating a trace.

## Results record

Create one record per session. Do not include secrets or unredacted paths.

```markdown
### Session <local label>

- Date:
- Menubar commit / dirty state:
- Test result:
- macOS:
- Station:
- Sanitized stream endpoint:
- Transport, and how verified:
- Feed endpoint or disabled:
- Output route:
- Duration:
- Trace filename retained locally:
- Clean end reason:

#### Counts

- Heard-song-change markers:
- Lyric-landmark markers:
- Metadata observations:
- Feed responses / failures:
- Stalls, waits, or media-time jumps:

#### Comparisons

| Transition | Human marker elapsed | Metadata elapsed/range | Feed receipt and provider time | Notes/uncertainty |
|---|---:|---|---|---|
| 1 | | | | |

#### Result

- Observed:
- Not observed:
- Conflicting evidence:
- Limits:
- Follow-up test or policy decision:
```

Keep real trace files and any audio reference local unless their privacy and sharing constraints have been reviewed explicitly.

## Trace and privacy boundaries

Current intended protections:

- newline-delimited JSON with a 32 MiB default limit;
- exclusive creation and owner-only `0600` permissions;
- no recorded audio;
- no account lookup, cookies, credential store, defaults, or Supabase writes;
- ephemeral feed requests without ambient cookies, URL credentials, or disk cache;
- standalone and embedded HTTP(S)/file URL redaction;
- bounded metadata strings and feed responses.

Redaction is defense in depth, not permission to supply credentials. Review a trace before sharing it outside the local machine.

## Failure interpretation

- A missing end event means the capture is incomplete.
- A size-limit or metadata-capacity failure must not be reported as a successful capture.
- A feed failure does not imply player failure.
- A player state change does not make feed-top audible.
- A backward wall-clock adjustment does not imply elapsed time moved backward.
- A successful replay proves deterministic handling of recorded observations, not the correctness of an automatic lyric-alignment policy.
