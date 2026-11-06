# Chessuite for KOReader

Chess on your e-reader: play bots, learn with a coach, solve Lichess puzzles, train openings and
review your games, on full-screen pages made for e-ink. Stockfish and a human-like engine run on the
device, so most of it works offline.

Chessuite is an unofficial plugin. It is not affiliated with or endorsed by Lichess or KOReader.

## Features

- **Play** against 20 bots with personalities (Pip 250 up to Stockfish 3200) or plain Stockfish levels 1 to 8.
  The beginner bots (Pip, Max, Luna, Sam) and the plain engine below 1000 play with **Maia3**, a
  human-like engine trained on millions of Lichess games: it plays the moves a player of that rating
  would make, mistakes included, instead of Stockfish with random blunders.
- **Coach that shows why**: it names the tactic behind a mistake (fork, pin, skewer, discovered
  attack, hanging or trapped piece, back-rank or smothered mate, deflection, ...) with the tagger
  Lichess uses for its puzzles, explains quiet mistakes from Stockfish 11's evaluation (king safety,
  passed pawns, ...), gives exact endgame verdicts from the Lichess tablebase, and on "see why" steps
  through the line on a board with numbered arrows and rings around the pieces that are hit.
- **Learn with Coach**: after every move the coach tells you in plain words what happened, e.g.
  *"Queen to h5 is a blunder. The problem: your opponent can answer with knight to f6, which attacks
  the queen on h5. Pawn to d4 was better."* Hints in three steps, take backs.
- **Lichess puzzles** that count for your Lichess puzzle rating (log in with a QR code and a token).
  Puzzles are cached so you can solve them offline; results are sent when you are back online.
- **Puzzles by opening**, like the Lichess app: puzzles from real games in an opening (Sicilian,
  French, ... and their variations), to learn its typical tactics. Saved for offline use.
- **Daily puzzle** without an account.
- **Analysis board**: the bundled Stockfish (local) or the Lichess cloud evaluation, and
  "Open on Lichess" with a QR code for the full server analysis.
- **Game review**: accuracy for both sides and the coach's comment on every move.
- **Play a friend** on the same device, with the board turning to the player to move.
- **Chess clock**: 3+2 up to 30 minutes, for games against bots and friends.
- **Puzzle Streak**: puzzles get harder every five, one mistake ends the run.
- **Openings**: 14 openings and 78 lines (Italian, Ruy Lopez, Queen's Gambit, Sicilian, French,
  Caro-Kann, gambits...) with the idea of every line and notes on the key moves. Learn a line with
  arrows, Practice it, Drill it with spaced repetition, or play Hyper rounds against random lines.
- **Opening explorer** in the analysis board: the moves masters and Lichess players chose (with a Lichess login).
- **Lichess Practice**: all 32 courses of lichess.org/practice (checkmates, tactics, pawn and rook
  endgames, 316 lessons), offline, played against Stockfish with Lichess' own goals.
- **My progress**: your rating chart, results with White and Black, puzzle and training records.
- **Your Lichess games**: load your last games from lichess.org and review them.
- **Lichess computer analysis** of your games (optional, experimental) through the small Android
  [companion app](#companion-app-android-optional).

Stockfish 11 and a C port of Maia3 (5M) are bundled as static binaries for ARMv7 (Kobo,
Kindle, PocketBook, ...), AArch64 and x86-64 (desktop KOReader).

The interface is in English.

## Install

1. Download `chessuite.koplugin-<version>.zip` from the
   [Releases](https://github.com/ThePixelPro366/chessuite.koplugin/releases) page and unzip it.
   You get a folder named `chessuite.koplugin`. (If you use GitHub's "Download ZIP" or "Source code"
   instead, rename the unzipped folder to `chessuite.koplugin`.)
2. Copy it into KOReader's `plugins` folder on your device
   (Kobo: `.adds/koreader/plugins/`, Kindle: `koreader/plugins/`,
   PocketBook: `applications/koreader/plugins/`).
3. Restart KOReader and open **Tools → Chess (Chessuite)** from the top menu.
   You can also assign "Chessuite" to a gesture.

Every page closes with the **X** in the top-right corner (or the Back button).

To update, replace the folder with the new one. Your settings, games and progress are kept
in KOReader's own folders (`settings/chessuite.lua` and `chessuite/`), not in the plugin folder.

**Requirements:** a recent KOReader. Playing bots, the coach, openings, Lichess Practice and
cached puzzles work offline; Lichess puzzles, the cloud evaluation, the opening explorer, the
tablebase and your Lichess games need Wi-Fi.

## Lichess login

A Lichess account is optional. You need one for rated puzzles, Puzzle Streak, the opening
explorer and loading your Lichess games.

Open *Lichess account* and scan the QR code with your phone. It opens Lichess with the
"read puzzles" and "solve puzzles" permissions already selected. Create the token and
type it in, or save it as `lichess_token.txt` in the KOReader folder and tap *Load from file*.
The token is stored on your e-reader only and is never written to the log.

## Companion app (Android, optional)

Chessuite Companion is a tiny Android app that lets Lichess run its **server computer analysis**
on your games. The Lichess API has no way to request that analysis, so the app lets you log in to
the Lichess *website* on your phone and passes that login to your e-reader over your local Wi-Fi.
Chessuite then presses "Request computer analysis" for you, the way the website does.

You don't need it for anything else: bots, the coach, puzzles, openings and the local Stockfish
analysis all work without it.

**Install and connect**

1. Put the e-reader and the phone on the same Wi-Fi.
2. On the e-reader: *Chessuite → Lichess account → Connect phone for Lichess analysis*.
3. Scan the QR code with the phone camera. If the app is not installed yet, the page offers
   it for download, served straight from your e-reader. You can also get
   `chessuite-companion.apk` from the
   [Releases](https://github.com/ThePixelPro366/chessuite.koplugin/releases) page. Allow
   installing apps from this source when Android asks.
4. Tap *Open in Chessuite Companion* and log in to Lichess in the app. The e-reader checks
   the one-time code, stores the login and stops listening.

**Privacy and caveats**

- The login only travels over your local network, to the e-reader that showed the code, and
  is stored in Chessuite's settings. *Forget phone login* removes it.
- This is an unofficial helper and not an official Lichess API. It is not affiliated with
  Lichess; use it at your own discretion.
- The app is signed with a public debug key (so that rebuilt APKs install as updates). Only
  install the APK from this repository or from your own e-reader.

More details and build instructions: [companion/README.md](companion/README.md).

## Credits and licenses

Chessuite is free software: you can redistribute it and/or modify it under the terms of the
GNU Affero General Public License, version 3 (see `LICENSE`). It comes with no warranty.

It is built on the work of many others:

- Stockfish 11: GPL-3.0, https://github.com/official-stockfish/Stockfish
  (see `bin/STOCKFISH-*.txt`; rebuild with `tools/build-stockfish.sh`).
- Maia3: University of Toronto CSSLab, https://github.com/CSSLab/maia3 (code AGPL-3.0), weights
  https://huggingface.co/UofTCSSLab/Maia3-5M. `tools/maia3/maia3.c` is a C port of its inference;
  `bin/maia3-5m.bin` holds its weights in half precision (see `bin/MAIA3-SOURCE.txt`; rebuild with
  `tools/export-maia3.py` and `tools/build-maia3.sh`).
- Bot personalities, coach wording and move classification are ported from
  chess-app by Arunav Rajkhowa (AGPL-3.0), https://github.com/ArunavRajkhowa/chess-app.
- Opening names: lichess chess-openings (CC0), https://github.com/lichess-org/chess-openings
  (rebuild with `tools/build-openings.lua`).
- Practice goals and move judging follow lila's PracticeGoal.scala, studyPracticeSuccess.ts and
  practiceCtrl.ts (AGPL-3.0).
- Opening courses: tabia by dax (MIT), https://github.com/daxaur/tabia: the opening lines, ideas and
  notes (rebuild with `tools/build-repertoire.py`), its training modes, spaced repetition and coach lines.
- Tactic names: a Lua port of the Lichess puzzle tagger (lichess-puzzler, `tagger/cook.py`, AGPL-3.0),
  https://github.com/ornicar/lichess-puzzler; `spec/tactics_spec.lua` checks it against puzzles from the
  Lichess puzzle database (CC0, https://database.lichess.org).
- Practice lessons: bundled from the Lichess mobile app's `assets/practice.json` (GPL-3.0),
  https://github.com/lichess-org/mobile (rebuild with `tools/build-practice.py`).
- Online services: the Lichess API (https://lichess.org/api) for puzzles, cloud evaluation and
  your games; the Lichess opening explorer (https://explorer.lichess.ovh) for masters' and players'
  moves; the Lichess tablebase (https://tablebase.lichess.ovh) for endgame verdicts.
- Pieces: the cburnett set by Colin M.L. Burnett (GPLv2+), via lichess.org.
- Icons: Material Symbols by Google (Apache-2.0), https://github.com/google/material-design-icons

Thanks to the Lichess team for their free and open chess platform and API.

## Development

Build the release zip (needs `zip`): `sh tools/package.sh` writes `chessuite.koplugin-<version>.zip`
with only the files the device needs. The version lives in `_meta.lua`. Running the *Release*
workflow in GitHub Actions (or pushing a tag `v<version>`) builds the zip and publishes a release
with it and the companion APK.

Run the tests from the plugin folder with LuaJIT:

    luajit spec/chess_spec.lua      # rules, perft
    luajit spec/engine_spec.lua     # real Stockfish, bots, coach
    luajit spec/tactics_spec.lua    # tactic names against Lichess puzzles
    luajit spec/puzzles_spec.lua    # puzzle logic
    luajit spec/lichess_spec.lua    # lichess client and its request log
    luajit spec/pairing_spec.lua    # companion app pairing server
    luajit spec/ui_smoke_spec.lua   # pages driven with stand-in widgets
