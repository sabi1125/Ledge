# Ledge

A personal, Alcove-style notch app for your MacBook Pro. It's for your own use only, and it's never released.

## Using it

- **Music:** when something plays (Apple Music, Spotify, YouTube in a browser, anything that shows in Control Center), the notch widens to show the album art and a waveform.
- **Open the island:** hover over the notch, or click it. Its pages are **Music** (shown only when something's loaded in a player), **Calendar**, **Timer** and **Notes**. Swipe left or right with two fingers to move between them, or click the dots at the top right. Switch any page off in settings. With the trackpad tick on, you feel a light tick as it opens.
- **Music:** scrub, play/pause and skip. In the small music view (closed island), a two-finger swipe skips tracks.
- **Calendar:** today's date and your next events from the Calendar app, with a **Join** button for Zoom, Meet, Teams and Webex links. It asks for Calendar access the first time.
- **Timer:** pick a preset or add minutes, then Start. While it runs, the countdown shows in orange beside the notch. When it's done, a "Timer done" pill drops down with a sound.
- **Pomodoro:** use the Timer / Pomodoro switch on the Timer page. Focus (25 min, red) and breaks (5 min, green) alternate, with a long break (15 min) after 4 focus sessions. Use Skip to jump to the next phase and Reset to start over. The countdown shows beside the notch, and a pop and sound mark each phase change. Lengths, number of sessions, and auto-start are in settings. Only one of the timer and the pomodoro counts down at a time.
- **Stay awake:** the coffee cup in the open island's top bar keeps your Mac awake (like `caffeinate`). Click it for your default length, or right-click or hold it to choose 15 min, 30 min, 1 h, 2 h, or until you turn it off. It turns orange with the time left, and a short pop shows when it starts and ends. In settings you can choose the default length, whether the screen stays on too, and whether to stay awake automatically while charging. Closing the lid still sleeps the Mac.
- **Notes:** click and type. It saves automatically to `~/Library/Application Support/Ledge/Notes.txt`. The island stays open while you type. Press **Esc** or click elsewhere to close it.
- **Indicators:** volume, brightness, plugging in the charger, and low battery (20%, 10%, 5%) all show in the notch.
- **Settings:** open Ledge from Spotlight or the Applications folder, or right-click the island and choose Ledge Settings. The island grows into a wide settings panel (it isn't one of the swipe pages). Switch any page, indicator or behavior on or off, pick an animation style, check for updates, or quit. Close it with ✕, Done, Esc, or a click anywhere else.
- **Animation styles:** Morph and blur, Drop down, Stretch, or Calm (the default). Picking one replays the settings panel in that style. In every style the content only fades, so nothing shrinks or zooms.

## External displays

Screens without a notch get a floating pill at the top center, like the original iPhone Dynamic Island. It has the same features and stays visible on normal desktops. It's kept off full-screen desktops (apps and videos) at the macOS level, so it never flickers when you swipe. On a full-screen desktop, rest the pointer at the top edge and the pill fades in along with the menu bar, then fades out when you move away. It also hides during Mission Control. Turn it off with "Show Ledge on other displays" in settings.

## Clean menu bar

Menu bar icons are removed in **System Settings → Menu Bar** (there's a button in Ledge's settings). Turn off every app, and for Apple's icons, keep only **Wi-Fi** and **Battery**. This removes them completely.

Ledge also has an optional "Hide other apps' menu bar icons" setting (off). It squeezes icons into macOS's hidden-items overflow and leaves macOS's overflow chevron showing, so it's only useful for apps that can't be turned off in System Settings. When it's on, it needs Accessibility access, and **⌃⌥⌘M** shows the hidden icons for 8 seconds.

## Updating

In Ledge's settings, **Check for updates** compares your copy with GitHub (`sabi1125/Ledge`), lists what's new, and **Update and restart** pulls it and reinstalls. Or, from the terminal:

```bash
~/Ledge/scripts/install.sh
```

Either way, this rebuilds the app, replaces `/Applications/Ledge.app` and restarts it. Permissions such as Accessibility carry over, because every build is signed with the same personal certificate, **Ledge Local Signing**, which lives in your login keychain. If that certificate is ever deleted, builds fall back to ad-hoc signing, and macOS will then ask for Accessibility again after each update.

## Volume and brightness keys

Ledge handles these keys itself, so only its drop-down indicator appears and macOS's pop-up doesn't. This needs Accessibility. Without it, the keys work normally with the macOS pop-up. ⇧⌥ + key changes the level in smaller steps.

## Uninstalling

Quit Ledge (right-click the notch → Quit), delete `/Applications/Ledge.app`, and remove it from System Settings → General → Login Items.

## How it's built

- `Sources/Ledge`: the app (SwiftUI + AppKit). It has a floating panel over the notch, the island views, and monitors for volume, brightness and battery, plus the menu bar hider.
- `Sources/LedgeCore`: pure logic with unit tests (`swift test`).
- `Bridge/`: the music bridge. macOS only shares now-playing info with Apple-signed programs, so Ledge runs a small library inside `/usr/bin/perl`, which is Apple-signed, to read it. This is the same workaround other notch apps use.
- Log file: `~/Library/Logs/Ledge.log`.
- `Ledge --snapshot DIR` draws every island state to PNG files using sample data.
- Debug: posting the distributed notification `local.sabir.ledge.record` with `"<style>|<folder>"` makes Ledge play that animation on the notch and save it frame by frame.
