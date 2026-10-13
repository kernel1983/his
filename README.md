# his

An interactive shell-history search for your terminal, written in Nim. Ditch
reaching for `Ctrl-R` over and over: type to filter, arrow to your command,
and press Enter to put it back on the prompt — with **favorites** to pin the
commands you use all the time.

`his` is a fork of [lscd](https://github.com/kernel1983/lscd) reworked from a
directory browser into a history picker.

No fullscreen UI (no alternate screen buffer). The list renders inline as a
compact block at your prompt and stays on screen after you exit.

## Why this exists

`Ctrl-R` only searches backward linearly and you have to press it again and
again to find what you want. `his` shows a live, filterable list of your
history instead, and lets you favorite the commands you keep retyping.

It is written in **Nim**, whose compiler first translates code to C and then
compiles that, so the binary is roughly the same size as an equivalent C build
(here just a few hundred KB — versus multi-MB Rust alternatives). Nim's
standard library keeps this dependency-free.

The `shell/his.sh` wrapper binds `his` to your `Ctrl-R`: the chosen command is
inserted into the current prompt (editable), and a companion `h` function runs
the chosen command directly.

## Features

- **Zero dependencies** — no external libraries; only the Nim standard library.
- **Inline, non-fullscreen** TUI — a compact block at your prompt (10 rows by
  default; override with `HIS_LINES=N`), no alt-screen takeover.
- **Favorites** — press `Right` to pin the selected command, `Left` to unpin.
  Stored in `~/.his_history` (one per line) and marked with `*` in the list.
- **Two sort modes** — `Tab` toggles between **time** order and **favorites
  first** (favorites bubble to the top, relative order preserved).
- **Filter by typing** — any key filters case-insensitively; prefix matches
  rank before substring matches.
- **History from anywhere** — reads `history` piped from your shell (so the
  current session's commands are included) or falls back to `$HISTFILE`
  (`~/.bash_history`) when stdin is a terminal.
- **Clean stdout**: only the chosen command (no ANSI codes) is printed, so a
  shell wrapper can safely capture it.

## Requirements

- [Nim](https://nim-lang.org/) >= 2.2.6
- A POSIX terminal (Linux/macOS) — it uses `termios`/`posix` for raw input.
  Windows is supported via the console API.

## Install & build

```bash
git clone <repo-url> his
cd his
nimble build
```

`nimble build` compiles from `src/his.nim` and outputs the `his` binary in the
current directory.

Optionally copy the binary into your PATH:

```bash
mkdir -p ~/.local/bin
cp his ~/.local/bin/
```

Make sure `~/.local/bin` is in your `PATH` (add the line below to `~/.bashrc`,
`~/.bash_profile`, or `~/.profile`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Shell integration

Add to your `~/.bashrc`:

```bash
source /path/to/his/shell/his.sh
```

Then:

- **`Ctrl-R`** opens `his` with your full history (newest first); the chosen
  command is inserted into the current prompt, ready to edit or run.
- **`h`** opens the same picker but runs the chosen command immediately.

`his` must be on your `PATH`; override the binary path before sourcing:

```bash
export HIS_BIN=/some/other/place/his
```

### Direct usage

`his` prints the chosen command to stdout and nothing else, so it composes with
any pipeline you like:

```bash
history | his          # include the current session's commands
his                    # reads $HISTFILE / ~/.bash_history instead
```

## Usage

```text
his
history | his
```

### Keys

| Key             | Action                                   |
|-----------------|------------------------------------------|
| `Up`/`Down`     | Move cursor up/down                      |
| `Home`/`End`    | Jump to first / last entry               |
| `Enter`         | Print selected command and quit          |
| `Tab`           | Toggle sort: time ⇄ favorites first      |
| `Right`         | Add selected command to favorites        |
| `Left`          | Remove selected command from favorites   |
| `Backspace`     | Delete one filter character              |
| `Esc`/`Ctrl+C`  | Quit without selection                   |
| Any key         | Filter by substring (case-insensitive)   |

### Configuration

- `HIS_LINES=N` — max number of history rows to show (default 10).
- `~/.his_history` — favorite commands, one per line; edit it freely.

## How it works

- Raw terminal input is handled manually via `termios` (or the Windows console
  API); escape sequences are parsed to read the arrow keys.
- Rendering goes to **stderr**, so **stdout carries only the chosen command**.
- History is read from **stdin** when it is piped (`history | his`), so the
  current session's yet-unflushed commands are searchable too; otherwise it
  falls back to `$HISTFILE`. Key input then comes from the controlling terminal
  (`/dev/tty`).
- Cursor position is queried (`ESC[6n`) to anchor the list; each render clears
  only the rows the widget occupies, so it never clears the whole screen.

## License

MIT