<p align="center"><img src="docs/hero.png" alt="Glint: screenshots, recordings and annotation for macOS" width="100%"></p>

<h3 align="center">Screenshots, recordings and markup for macOS.<br>One middle-click away.</h3>

<p align="center">
  <a href="https://github.com/barkimchi/Glint/releases/latest/download/Glint.zip"><img src="https://img.shields.io/badge/Download_for_macOS-FFB21A?style=for-the-badge&logo=apple&logoColor=black&labelColor=FFB21A" alt="Download for macOS"></a>
</p>
<p align="center">
  <a href="https://github.com/barkimchi/Glint/releases/latest"><img src="https://img.shields.io/github/v/release/barkimchi/Glint?style=flat-square&label=release&color=4A4D52" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-4A4D52?style=flat-square" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/notarized_by-Apple-4A4D52?style=flat-square" alt="Notarized by Apple">
  <img src="https://img.shields.io/badge/native-Swift-4A4D52?style=flat-square&logo=swift&logoColor=white" alt="Native Swift">
</p>

<p align="center">Or from the terminal: <code>npx github:barkimchi/glint-app</code></p>

<br>

## ⚡ Capture anything

<img src="docs/capture.gif" alt="Capturing an area: the screen freezes and dims, a rectangle is dragged over the dashboard's cards, and the capture appears as a thumbnail in the corner" width="100%">

The screen freezes, you drag, it's saved. Menus and hover states stay exactly where they were.

<table>
  <tr>
    <td><b>Area</b> · <b>Window</b> · <b>Fullscreen</b></td>
    <td>The classics. Window shots keep their shadow.</td>
  </tr>
  <tr>
    <td><b>Scrolling</b> · <b>Full page</b></td>
    <td>Glint scrolls for you and stitches one tall, seamless image.</td>
  </tr>
  <tr>
    <td><b>Grab text</b></td>
    <td>Drag over anything and the text lands on your clipboard. QR codes too.</td>
  </tr>
  <tr>
    <td><b>Record</b></td>
    <td>MP4 with click rings, keystrokes and audio. One click makes it a GIF.</td>
  </tr>
</table>

<br>

## 🎛️ Your popup, your way

<table>
  <tr>
    <td width="50%"><img src="docs/popup-edit.gif" alt="The popup opens, buttons show their names on hover, a long press makes them wiggle, one is dragged to a new spot, one is removed, Safari and Notes are added, and Done saves the layout" width="100%"></td>
    <td width="50%">
      <b>Middle-click anywhere</b> and your actions appear under the pointer.<br><br>
      <b>Long-press</b> and they wiggle: drag to reorder, tap ⊖ to remove, tap ＋ to add actions or <b>any app on your Mac</b>.<br><br>
      Prefer the keyboard? Every action has a shortcut. Prefer the mouse? A slim widget hugs any screen edge.
    </td>
  </tr>
</table>

<br>

## ✏️ Mark it up, then change your mind

<img src="docs/annotate.gif" alt="The annotation editor: a box and an arrow call out a card, a row is highlighted, numbered steps are placed, amounts are pixelated, then the box is selected, moved, resized and recoloured, and the image is put on a gradient background" width="100%">

Arrows, boxes, highlights, numbered steps, text, pixelate and crop. Every mark stays editable: select it to move, resize, recolour or delete.

<br>

## 🖼️ Make it presentable

<table>
  <tr>
    <td width="55%"><img src="docs/background.png" alt="A screenshot framed on a pink and orange gradient with padding, rounded corners and a soft shadow" width="100%"></td>
    <td width="45%">
      One click puts your shot on a gradient with padding, rounded corners and a soft shadow.<br><br>
      Six backgrounds, adjustable padding. Ready for a post, a deck or the docs.
    </td>
  </tr>
</table>

<br>

## 🪄 New in 0.2.3: the screenshot pile

<table>
  <tr>
    <td width="34%" align="center"><img src="docs/pile-stacked.png" alt="Three screenshots stacked in the corner with a count badge, a Copy all button and the hint: click to see all, drag to send all" width="232"></td>
    <td width="66%">
      Take a few shots in a row and they <b>stack in the corner</b>, newest on top.<br><br>
      <b>Drag the pile</b> into Claude, Slack or Finder and they all go. <b>Copy all</b> pastes every one.<br><br>
      <b>Click it</b> to lay them out and drag or right-click just one.
    </td>
  </tr>
</table>

<img src="docs/pile-fanned.png" alt="The pile laid out: three screenshots side by side with Copy all and Stack buttons" width="100%">

<br>

## 📌 And the small things

**Quick access** · every shot waits in the corner: drag it anywhere, or hover for Copy, Annotate and Pin.<br>
**Keep on top** · press ⌃⇧0 and click any window to lock it above everything, even other apps.<br>
**Trackpad edges** · slide one finger down the left edge for volume, the right edge for brightness; hold a top corner to run an action.<br>
**Pins** · float a screenshot above every window, fade it, or make it click-through.<br>
**History** · 30 days of captures, one click from the menu bar.<br>
**Welcome tour** · a quick guided start on first launch, and a What's New card after each update.<br>
**Betas** · turn on Get beta builds in Settings and new features arrive through Check for Updates first.<br>
**Private** · no account, no cloud. Everything stays on your Mac.

<br>

<details>
<summary><b>Keyboard shortcuts</b></summary>
<br>

| Shortcut | Action |
|---|---|
| ⌃⇧4 | Capture area |
| ⌃⇧5 | Capture window |
| ⌃⇧3 | Capture fullscreen |
| ⌃⇧7 | Scrolling capture |
| ⌃⇧8 | Capture full page |
| ⌃⇧2 | Grab text |
| ⌃⇧6 | Start or stop a recording |
| ⌃⇧9 | Go to Claude (or the app you pick) |
| ⌃⇧0 | Keep a window on top |

Esc cancels any selection. Change any shortcut in Settings.

<p align="center"><img src="docs/settings-window.png" alt="Glint Settings: shortcuts, the Go-to app, trackpad edge controls, recording, corner thumbnails, beta updates and save folder" width="360"></p>
</details>

<details>
<summary><b>Install, updates and permissions</b></summary>
<br>

- **Install**: unzip, drag `Glint.app` to Applications, open it. Releases are signed and notarized by Apple.
- **Updates**: Glint checks on its own and verifies each update before installing. The menu has Check for Updates too.
- **Permissions**: Screen Recording for everything. Accessibility for full-page and scrolling capture, keystrokes and the middle-click popup. Microphone only if you turn it on. Trackpad edges need nothing extra.
- **Middle click**: while the popup is on, Glint takes the middle button system-wide. Turn it off from the menu bar.
- **Files**: screenshots save to Desktop/Glint Screenshots by default. History lives in `~/Library/Application Support/Glint/History`.
</details>

<details>
<summary><b>Under the hood</b></summary>
<br>

- Swift, AppKit and SwiftUI on ScreenCaptureKit, Vision and AVFoundation. No third-party dependencies apart from Sparkle for updates.
- Full-page capture works out which rows actually scroll, so fixed toolbars appear once. The cap is 40,000 px.
- Recordings are H.264 MP4 at 30 fps; system audio and microphone mix into one AAC track. Password fields never show in the keystroke pill.
- Building, test flags, recording these GIFs and cutting a release: [docs/DEVELOPING.md](docs/DEVELOPING.md).
</details>

<details>
<summary><b>Coming next</b></summary>
<br>

- Sticky footers and content sidebars in scrolling and full-page capture
- Hide desktop icons while capturing
</details>

<br>

<p align="center"><sub>Made by <a href="https://github.com/barkimchi">Bar Kimchi</a></sub></p>
