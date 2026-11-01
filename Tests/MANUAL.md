# Manual checks

Things the automated battery can't fake: real hardware, system permissions and macOS itself.
Run them before a release, on the release build, with Brim's debug tools off. Write the date and
macOS version at the top of a copy of this list, and note anything off next to its line.

## Keys and permissions

- [ ] Volume up, down and mute keys show Brim's HUD and no macOS indicator.
- [ ] Option + Shift + volume moves in quarter steps.
- [ ] Brightness keys show the HUD; brightness changes on the built-in display.
- [ ] Holding a volume key repeats smoothly, and the island stretches at 0 % and 100 %.
- [ ] Revoke Accessibility in System Settings while Brim runs: keys fall back to macOS. Grant it again: Brim takes them back without relaunching.
- [ ] Media keys (play/pause, next) still reach the player.

## Music

- [ ] Apple Music, Spotify and a browser video each show artwork and equalizer next to the notch.
- [ ] Pause: artwork stays 30 s, then leaves. Resume within 30 s: it stays.
- [ ] Hover opens the player; scrubbing, play/pause, next and previous work; the source label opens the app.
- [ ] A podcast longer than an hour shows the time correctly.
- [ ] Quit the player app: everything leaves and the player closes.

## Devices and power

- [ ] AirPods connect: render with both buds and battery.
- [ ] Other Bluetooth headphones, a speaker, wired headphones on the jack, a USB DAC: right icon and name.
- [ ] AirPods at 10 % or less while playing: low battery alert once.
- [ ] Plug in the charger: face and percentage. Unplug: "on battery". Reach the charge limit: "charged".
- [ ] Battery crosses 20 % and 10 % unplugged: one sad face each time.

## Displays and spaces

- [ ] External display connected: island where Settings says (all, built-in, external).
- [ ] Lid closed with an external display: island moves to it.
- [ ] Unplug the external display while the island is open: no stray window left behind.
- [ ] Full screen app on each display: ears hide there, Claude alerts still show.
- [ ] Switch Spaces quickly with three fingers: no flicker, island stays.
- [ ] Change resolution or the "More Space" scaling: island stays centered on the notch.
- [ ] Menu bar set to hide automatically: island still lines up.

## Screen recording

- [ ] ⌘⇧5 recording: stop button and timer in the ears; the stop button saves the recording.
- [ ] QuickTime screen recording: same.
- [ ] Zoom or Meet screen sharing: timer only, no stop button. It goes away when sharing stops.
- [ ] A screenshot (⌘⇧4) doesn't show the recording indicator.
- [ ] Brim itself doesn't appear in the recording.

## Claude Code and Codex

- [ ] Connect both from Settings; `~/.claude/settings.json` and `~/.codex/hooks.json` keep your other hooks.
- [ ] Permission in a terminal session: allow and deny from the notch reach Claude Code.
- [ ] Answer in the terminal instead: the alert leaves on its own.
- [ ] A question with options: pick from the notch. Multi-select: Send.
- [ ] Click an alert: the right terminal tab, VS Code window or Codex window comes forward, across Spaces.
- [ ] Two sessions asking at once: the newest permission shows, the other comes back after.
- [ ] Disconnect both: config files back as they were.

## Sleep, updates, login

- [ ] Sleep and wake with music paused, then play: artwork and controls come back.
- [ ] Wake with an external display attached and detached.
- [ ] Open at login on a fresh account: starts once, no duplicate.
- [ ] Update from the previous version through "Check for Updates": installs and relaunches with settings kept.
- [ ] First launch on a clean account: onboarding, every step, light and dark mode.
- [ ] Intel Mac (if one is around): launch, HUD, music, AirPods.

## Battery

- [ ] Overnight `scripts/test/soak.sh` with Brim, then with `--without-brim`. The drain difference should be within noise.
