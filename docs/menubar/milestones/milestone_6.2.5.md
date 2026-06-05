# M6.2.5 — Pocket Casts Dark Theme Styling

**Status**: DONE

> Inject between M6.2 and M6.3. Functional goal: make playback position visible so we can verify `playedUpTo`/`duration` decoding works.

## Goal

Apply the Pocket Casts dark-theme design system to the menubar popover, with special focus on making time-remaining data visible (this verifies our protobuf `episodeSync` decoding is correct).

## Color Palette (Pocket Casts Dark Theme)

| Token | Hex | Usage |
|-------|-----|-------|
| `primaryUi01` | `#292B2E` | Main popover background |
| `primaryUi04` | `#161718` | Card / darker surface |
| `primaryUi05` | `#393A3C` | Dividers |
| `primaryText01` | `#FFFFFF` | Primary text (titles) |
| `primaryText02` | `#9C9FA4` | Muted text (labels, time remaining) |
| `primaryIcon02` | `#8F97A4` | Inactive icons |
| Tint / Accent | `#F44336` | Selected pills, interactive |

## Changes

### 1. Global Background & Dividers
- Popover background → `primaryUi01`
- Dividers → `primaryUi05`
- Remove default system `Divider()` tint, use explicit color

### 2. Episode List Row (functional verification)
Each row shows:
- **Artwork placeholder**: 48×48 rounded square, `primaryUi04` background, podcast initial or generic icon
- **Episode title**: 14pt medium, `primaryText01`, 1 line + truncation
- **Time remaining**: 13pt, `primaryText02` — "22m left" format (this is `duration - playedUpTo`)
  - If `playedUpTo == 0`: show full duration, e.g. "58m"
  - If `playedUpTo >= duration`: show "Finished"
- **Bottom divider**: 1pt, `primaryUi05`, inset to align with text (not full-width)

### 3. "Total Time Remaining" Header
- Between pills/controls and the episode list
- Shows sum of `(duration - playedUpTo)` for all episodes in the queue
- 14pt medium, `primaryText02`
- This gives a single-glance confirmation that duration data is present

### 4. Now Playing Info (stream selected)
- When a stream pill is selected, show styled now-playing card:
  - Rounded rect background (`primaryUi04`)
  - Station name: 14pt medium, `primaryText01`
  - "Live Stream" label: 13pt, `primaryText02`

### 5. Pills & Controls
- Pill background (unselected): `primaryUi04`
- Pill background (selected): accent `#F44336`
- Pill text (unselected): `primaryText01`
- Pill text (selected): `#FFFFFF`
- Control icons: `primaryIcon02`, selected/hover → `primaryText01`

### 6. Footer
- Log Out / Quit: 13pt, `primaryText02`

## Out of Scope (for this milestone)
- Podcast artwork fetching (no artwork URL in protobuf response)
- Day-of-week labels (need `published` timestamp decode)
- Light theme / adaptive theming
- Progress bars on now-playing card

## Verification

After building, open the app and select the Podcast pill. You should see:
1. Each episode shows a time like "22m left" or "58m" — this confirms `duration` and `playedUpTo` are populated
2. Total time remaining shown above the list — confirms all episodes have duration data
3. If you tap an episode and it resumes from mid-episode, `playedUpTo` seek is working
