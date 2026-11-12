# Ledge

A personal, Alcove-style notch app for your MacBook Pro. It's for your own use only, and it's never released.

## Using it

- **Music:** when something plays (Apple Music, Spotify, YouTube in a browser, anything that shows in Control Center), the notch widens to show the album art and a waveform.
- **Open the island:** hover over the notch, click it, or press **⌘L** from anywhere (⌘L again closes it; on the Notes page the cursor goes straight into the note). ⌘L is taken from every app while Ledge runs, including the browsers' "go to the address bar". Once open, it stays open until you click outside it or press **Esc**, so moving the pointer away never closes it. It always opens where you left it: the same page, and if you were in quick add or had a to-do open, right back there with what you typed. Its pages are **Music** (shown only when something's loaded in a player), **Calendar**, **Timer** and **Notes**. Swipe left or right with two fingers to move between them, click the dots at the top right, or press **⌘1–⌘4** (in the order of the dots; to Notes, the cursor goes straight into the note). Switch any page off in settings. With the trackpad tick on, you feel a light tick as it opens.
- **Music:** scrub, play/pause and skip. In the small music view (closed island), a two-finger swipe skips tracks.
- **Calendar:** today's date and your next events from the Calendar app, with a **Join** button for Zoom, Meet, Teams and Webex links. Finished events drop off, and what's next is on top: the meeting you're in, then today's meetings, then today's all-day items and anything longer than 4 hours (an "in office" block), then tomorrow the same way. It asks for Calendar access the first time.
- **Quick add:** press **⌘T** while the island is open on the to-do list, **⌃⌥E** (new event) or **⌃⌥T** (new to-do) from anywhere, or click the **+** beside the page dots on the Calendar page and type an event in one line, like "Dentist tomorrow 3pm" or "Gym fri 7-8pm". The date badge and a preview show what Ledge understood. Press **return** to save it to your iCloud calendar (the one called Personal or Home, if there is one), or **Esc** to cancel. **⌘N** opens a notes box (return makes a new line there, **⌘return** saves, and ⌘N or Esc goes back to the title line). With no day or time in the text, return saves an all-day event today, and the preview says so first. After saving, **⌘Z** or Undo removes it again. Copy and paste work while typing. If quick add closes by accident (a click elsewhere), what you typed is still there next time; Esc cancels and clears it.
- **To-dos:** the **Events · To-dos** switch at the top left of the Calendar page shows all your open to-dos from the Reminders app, in every list. With more than 2, the island opens bigger so they all show at once (past about 7 it scrolls). The order: in progress first, then due today or overdue, then no due date, then upcoming (musts first within each). Click a circle to tick one off (Undo shows for a moment), right-click it to mark it in progress, and click a to-do to open its steps. Steps are checkbox lines in its notes (`- [ ] reply to the feedback`); the list shows them as **2/4**, and the to-do you're working on shows its next step right under it. In To-dos mode the **+** adds a reminder: `! Reply to the review fri #s3 [30m]` is a must, due Friday, in the list whose name starts with "s3" (a new list if none matches, and the preview says **New list** in orange first), with a 30 min guess (kept at the end of the title, so it shows in Reminders too). While you type a `#`, your lists show under the line with their colors: **Tab** takes the first, a click takes any, and **Esc** hides them. A list name with spaces goes in with dashes (`#Side-project`). A link in the text is saved at the top of its notes (the Reminders app doesn't show links other apps save in its link field), and the ↗ opens it. In an opened to-do, Markdown links like `[google](www.google.com)` show as "google" and open on click; bare links show by their last part (a Backlog link shows as "CONTRACT-9508"). In the notes box (⌘N), typing `[] ` makes a checkbox and return continues the list. Ledge asks for Reminders access the first time.
- **Timer:** pick a preset or add minutes, then Start. While it runs, the countdown shows in orange beside the notch. When it's done, a "Timer done" pill drops down with a sound.
- **Pomodoro:** use the Timer / Pomodoro switch on the Timer page. Focus (25 min, red) and breaks (5 min, green) alternate, with a long break (15 min) after 4 focus sessions. Use Skip to jump to the next phase and Reset to start over. The countdown shows beside the notch, and a pop and sound mark each phase change. Lengths, number of sessions, and auto-start are in settings. Only one of the timer and the pomodoro counts down at a time.
- **Stay awake:** the coffee cup in the open island's top bar keeps your Mac awake (like `caffeinate`). Click it for your default length, or right-click or hold it to choose 15 min, 30 min, 1 h, 2 h, or until you turn it off. It turns orange with the time left, and a short pop shows when it starts and ends. In settings you can choose the default length, whether the screen stays on too, and whether to stay awake automatically while charging. Closing the lid still sleeps the Mac.
- **Notes:** your notes live in Apple Notes, in a folder called **Ledge** (made for you), so they're the same notes as in the Notes app and on your iPhone. The page shows the list on the left and the open note on the right: a **title** (the note's first line in Notes) and the text. Click the pencil or press **⌘N** for a new note (the cursor goes to its title); the sidebar button or **⌥⌘S** hides or shows the list; edits save to Notes a moment after you stop typing. **Search** above the list filters by title and text. The trash button deletes the open note after a second click on "Delete?" (it goes to Recently Deleted in Notes, so it can be restored). **Open in Notes** opens it in the Notes app (for pictures, tables or sharing). Like every notes box in Ledge, it sits right on the black with just the cursor, `[] ` makes a checkbox (kept as `- [ ]` text in Notes), return continues a list, and Tab / ⇧Tab indent a list line by 4 spaces. On the Notes page, Markdown is drawn as you type, like Notion: `#`/`##`/`###` headings, `**bold**`, `*italic*`, `~~struck~~`, `` `code` `` in a small box, links (⌘-click opens one), bullets (●○◆◇ by indent), numbered lists, checkboxes you can click to tick, `> ` quotes with a purple bar, ```` ``` ```` blocks in a grey box (typing ```` ``` ```` puts the closing one in for you), and `---` as a line. The marks (`##`, `**`, `` ` ``, the link address) hide and come back on the line the cursor is on, so you can edit them. Return continues a list, numbered list or quote (`2.` after `1.`), return on an empty one ends it, and return right before an item's text pushes it down. Backspace right before an item's text removes its bullet, box or `>` in one go. The text stays plain Markdown, so the Notes app shows the same note. The first time, macOS asks to let Ledge control Notes. Your old scratch note (`Notes.txt`) is moved into the Ledge folder once, as "Scratch note".
- **Indicators:** volume, brightness, plugging in the charger, and low battery (20%, 10%, 5%) all show in the notch.
- **Settings:** open Ledge from Spotlight or the Applications folder, or right-click the island and choose Ledge Settings. The island grows into a wide settings panel (it isn't one of the swipe pages). Switch any page, indicator or behavior on or off, pick an animation style, check for updates, or quit. Close it with ✕, Done, Esc, or a click anywhere else.
- **Animation styles:** Morph and blur, Drop down, Stretch, or Calm (the default). Picking one replays the settings panel in that style. In every style the content only fades, so nothing shrinks or zooms.

## External displays

Screens without a notch get a floating pill at the top center, like the original iPhone Dynamic Island. It has the same features and stays visible on normal desktops. It's kept off full-screen desktops (apps and videos) at the macOS level, so it never flickers when you swipe. On a full-screen desktop, rest the pointer at the top edge and the pill fades in along with the menu bar, then fades out when you move away. ⌘L, quick add (⌃⌥E / ⌃⌥T) and settings bring it in too, and it stays while the island is open. The notch island on the MacBook screen stays put on full-screen desktops (a full-screen browser or video), where the strip beside the notch is black anyway. It also hides during Mission Control. Turn it off with "Show Ledge on other displays" in settings.

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
