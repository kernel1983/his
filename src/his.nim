import std/[os, strutils, terminal, exitprocs, sets]
when not defined(windows):
  import std/[posix, termios]
  import std/times as dtimes
else:
  import std/winlean

type
  Stored = object
    cmd: string
    fav: bool

var
  items: seq[Stored]
  filtered: seq[int]
  cursor: int
  top: int
  filter: string
  termW, termH: int
  favPath: string
  favOrder: seq[string]
  favSet: HashSet[string]
  keyInput: File
  keyFd: cint = -1
  listTopRow = 1
  prevBlockH = 0

when not defined(windows):
  var origTermios: Termios

  proc ttyIsTTY(fd: cint): bool =
    var t: Termios
    tcGetAttr(fd, addr t) == 0

  proc setupRawMode() =
    discard tcGetAttr(keyFd, addr origTermios)
    var raw = origTermios
    raw.c_iflag = raw.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    # keep OPOST/ONLCR enabled so \n advances to a fresh column (no stray indentation)
    raw.c_cflag = (raw.c_cflag and not Cflag(CSIZE or PARENB)) or CS8
    raw.c_lflag = raw.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
    raw.c_cc[VMIN] = 1.cchar
    raw.c_cc[VTIME] = 0.cchar
    discard tcSetAttr(keyFd, TCSAFLUSH, addr raw)

  proc restoreTerminal() =
    if keyFd >= 0:
      discard tcSetAttr(keyFd, TCSAFLUSH, addr origTermios)
else:
  var origMode: DWORD
  var stdinInHandle: HANDLE

  proc setupRawMode() =
    stdinInHandle = getStdHandle(STD_INPUT_HANDLE)
    if stdinInHandle != INVALID_HANDLE_VALUE and getConsoleMode(stdinInHandle, addr origMode) != 0:
      var mode = origMode
      # Disable ENABLE_ECHO_INPUT / ENABLE_LINE_INPUT / ENABLE_PROCESSED_INPUT so we
      # get raw per-byte input; keep virtual-terminal input so arrow keys arrive
      # as ESC sequences (matches the POSIX arrow-key parser in readKey()).
      mode = (mode and not (ENABLE_ECHO_INPUT or ENABLE_LINE_INPUT or ENABLE_PROCESSED_INPUT)) or ENABLE_VIRTUAL_TERMINAL_INPUT
      discard setConsoleMode(stdinInHandle, mode)
      # Enable virtual-terminal processing on stderr so the raw ANSI escape
      # sequences used by render() are interpreted by the Windows console.
      var outMode: DWORD
      let outH = getStdHandle(STD_ERROR_HANDLE)
      if outH != INVALID_HANDLE_VALUE and getConsoleMode(outH, addr outMode) != 0:
        discard setConsoleMode(outH, outMode or ENABLE_VIRTUAL_TERMINAL_PROCESSING)

  proc restoreTerminal() =
    if stdinInHandle != INVALID_HANDLE_VALUE:
      discard setConsoleMode(stdinInHandle, origMode)

  proc isStdinTTY(): bool =
    let h = getStdHandle(STD_INPUT_HANDLE)
    var m: DWORD
    h != INVALID_HANDLE_VALUE and getConsoleMode(h, addr m) != 0

var cleaned = false

proc cleanupForExit() =
  if cleaned: return
  cleaned = true
  restoreTerminal()
  showCursor(stderr)
  stderr.resetAttributes()
  flushFile(stderr)

proc readKey(): int =
  var ch: char
  let n = readBuffer(keyInput, addr ch, 1)
  if n == 0: return -1
  let c = ord(ch)
  if c == 27: # ESC
    var buf: array[2, char]
    let n2 = readBuffer(keyInput, addr buf[0], 1)
    if n2 == 0: return 27
    if buf[0] == '[':
      let n3 = readBuffer(keyInput, addr buf[1], 1)
      if n3 == 0: return 27
      case buf[1]
      of 'A': return 1000 # Up
      of 'B': return 1001 # Down
      of 'C': return 1005 # Right
      of 'D': return 1006 # Left
      of 'H': return 1002 # Home
      of 'F': return 1003 # End
      of 'Z': return 1004 # Shift-Tab
      else: discard
    return 27
  return c

proc loadFavorites() =
  favOrder = @[]
  favSet = initHashSet[string]()
  if fileExists(favPath):
    for line in lines(favPath):
      var c = line
      while c.len > 0 and c[^1] == '\r': c.setLen(c.len - 1)
      if c.strip.len == 0: continue
      if not favSet.contains(c):
        favSet.incl c
        favOrder.add c

proc saveFavorites() =
  var f: File
  if open(f, favPath, fmWrite):
    for c in favOrder: f.writeLine c
    close(f)

proc addFavorite(cmd: string) =
  if not favSet.contains(cmd):
    favSet.incl cmd
    favOrder.add cmd
    saveFavorites()

proc removeFavorite(cmd: string) =
  if favSet.contains(cmd):
    favSet.excl cmd
    let i = favOrder.find(cmd)
    if i >= 0: favOrder.delete(i)
    saveFavorites()

proc stripHistNumber(line: string): string =
  # `history` output is "  123  command"; drop the leading line number.
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  var j = i
  while j < line.len and line[j] in {'0'..'9'}: inc j
  if j > i and j < line.len and line[j] in {' ', '\t'}:
    var k = j
    while k < line.len and line[k] in {' ', '\t'}: inc k
    return line[k .. ^1]
  return line

proc loadRawHistory(piped: bool): seq[string] =
  if piped:
    for line in stdin.lines:
      result.add stripHistNumber(line)
  else:
    let hf = getEnv("HISTFILE")
    let path = if hf.len > 0: hf else: getHomeDir() / ".bash_history"
    if fileExists(path):
      for line in lines(path):
        result.add line

proc buildItems(raw: seq[string]) =
  items = @[]
  var seen = initHashSet[string]()
  for k in countdown(raw.len - 1, 0):
    var cmd = raw[k]
    while cmd.len > 0 and cmd[^1] == '\r': cmd.setLen(cmd.len - 1)
    if cmd.strip.len == 0: continue
    if seen.contains(cmd): continue
    seen.incl cmd
    items.add Stored(cmd: cmd, fav: favSet.contains(cmd))
  # Favorites missing from the current history are still offered.
  for c in favOrder:
    if not seen.contains(c):
      seen.incl c
      items.add Stored(cmd: c, fav: true)

proc applyFilter() =
  filtered = @[]
  if filter.len > 0:
    let lf = toLowerAscii(filter)
    var prefixHits, containsHits: seq[int]
    for i, e in items:
      let ln = toLowerAscii(e.cmd)
      if ln.contains(lf):
        if ln.startsWith(lf): prefixHits.add i
        else: containsHits.add i
    filtered = prefixHits & containsHits
  else:
    for i in 0 ..< items.len: filtered.add i
  if cursor >= filtered.len:
    cursor = max(0, filtered.len - 1)
  top = 0

when not defined(windows):
  proc queryCursorRow(): int =
    # Ask the terminal for the cursor's absolute row: ESC[6n -> ESC[r;cR
    # Use the raw fd (not File's buffered input) with non-blocking reads + timeout.
    let oldFlags = fcntl(keyFd, F_GETFL, 0)
    discard fcntl(keyFd, F_SETFL, oldFlags or O_NONBLOCK)
    stderr.write "\x1b[6n"
    flushFile(stderr)
    var buf = ""
    var ch: char
    let deadline = epochTime() + 0.2
    while epochTime() < deadline:
      let n = posix.read(keyFd, addr ch, 1)
      if n == 1:
        buf.add ch
        if ch == 'R': break
        if buf.len > 32: break
      else:
        sleep(2)
    discard fcntl(keyFd, F_SETFL, oldFlags)
    let semi = buf.find(';')
    if semi < 0: return 0
    try:
      result = parseInt(buf[2 ..< semi])
    except ValueError:
      result = 0
else:
  type
    WinSmallRect = object
      wleft, wtop, wright, wbottom: int16
    ConsoleScreenBufferInfo = object
      dwSize: COORD
      dwCursorPosition: COORD
      wAttributes: int16
      srWindow: WinSmallRect
      dwMaximumWindowSize: COORD

  proc getConsoleScreenBufferInfo(h: Handle, info: ptr ConsoleScreenBufferInfo): int32 {.
      stdcall, dynlib: "kernel32", importc: "GetConsoleScreenBufferInfo".}

  proc queryCursorRow(): int =
    # Windows: read the cursor position directly from the console screen buffer.
    var csbi: ConsoleScreenBufferInfo
    if getConsoleScreenBufferInfo(getStdHandle(STD_ERROR_HANDLE), addr csbi) != 0:
      result = int(csbi.dwCursorPosition.y) + 1
    else:
      result = 0

proc listMaxRows(): int =
  # Inline, non-fullscreen: show at most a handful of rows so the widget stays a
  # compact block at the prompt instead of taking over the screen. Override with
  # HIS_LINES=N.
  var cap = min(termH - 2, 10)
  let env = getEnv("HIS_LINES")
  if env.len > 0:
    try: cap = min(termH - 2, parseInt(env))
    except ValueError: discard
  result = max(1, cap)

proc truncBytes(s: string, n: int): string =
  if n <= 0: return ""
  if s.len <= n: return s
  var endIdx = n
  while endIdx > 0 and (ord(s[endIdx]) and 0xC0) == 0x80: dec endIdx
  result = s[0 ..< endIdx]

proc render() =
  let maxVisible = listMaxRows()
  if cursor < top: top = cursor
  elif cursor >= top + maxVisible: top = cursor - maxVisible + 1
  if top < 0: top = 0
  let visibleCount = min(filtered.len - top, maxVisible)
  let blockH = visibleCount + 2
  if listTopRow + blockH - 1 > termH:
    listTopRow = max(1, termH - blockH + 1)

  # Clear only the rows this widget occupies (never the whole screen), including
  # any extra rows left over from a previously taller render.
  let clearH = max(blockH, prevBlockH)
  for r in 0 ..< clearH:
    stderr.write "\x1b[" & $(listTopRow + r) & ";1H\x1b[0K"

  stderr.write "\x1b[" & $listTopRow & ";1H"

  let title = " his "
  let filterStr = if filter.len > 0: " /" & filter & " " else: ""
  let statusStr = " " & $filtered.len & "/" & $items.len & " fav:" & $favOrder.len & " "

  stderr.setForegroundColor(fgWhite)
  stderr.setBackgroundColor(bgBlue)
  stderr.styledWriteLine(styleBright, title, " ".repeat(max(0, termW - title.len - filterStr.len - statusStr.len)), filterStr, statusStr, resetStyle)
  stderr.setBackgroundColor(bgDefault)

  if filtered.len > 0:
    for row in 0 ..< visibleCount:
      let idx = top + row
      stderr.write "\x1b[" & $(listTopRow + 1 + row) & ";1H"
      stderr.write "\x1b[0K"
      if idx >= filtered.len: continue
      let it = items[filtered[idx]]
      let isCursor = idx == cursor
      if isCursor: stderr.write "\x1b[7m"
      stderr.write(if isCursor: "> " else: "  ")
      if it.fav:
        stderr.write "\x1b[35m*\x1b[39m "
      else:
        stderr.write "  "
      stderr.write truncBytes(it.cmd, termW - 4)
      if isCursor: stderr.write "\x1b[0m"
  else:
    stderr.setForegroundColor(fgYellow)
    stderr.writeLine "  (no matches)"

  stderr.write "\x1b[" & $(listTopRow + visibleCount + 1) & ";1H"
  stderr.write "\x1b[0K"
  stderr.setForegroundColor(fgBlack, true)
  stderr.write truncBytes(" Up/Down:move  Enter:choose  Right:fav  Left:unfav  Esc:quit  type:filter ", termW)
  stderr.resetAttributes()
  flushFile(stderr)
  prevBlockH = blockH

proc handleInput() =
  render()
  while true:
    let key = readKey()
    case key
    of -1: # input closed
      cleanupForExit()
      quit(0)
    of 1000: # Up
      if cursor > 0: cursor.dec
    of 1001: # Down
      if cursor + 1 < filtered.len: cursor.inc
    of 1002: # Home
      cursor = 0
    of 1003: # End
      cursor = max(0, filtered.len - 1)
    of 1005: # Right -> favourite
      if filtered.len > 0:
        let idx = filtered[cursor]
        if not items[idx].fav:
          items[idx].fav = true
          addFavorite(items[idx].cmd)
    of 1006: # Left -> unfavourite
      if filtered.len > 0:
        let idx = filtered[cursor]
        if items[idx].fav:
          items[idx].fav = false
          removeFavorite(items[idx].cmd)
    of 13, 10: # Enter
      if filtered.len > 0:
        cleanupForExit()
        stdout.write items[filtered[cursor]].cmd
        stdout.write "\n"
        flushFile(stdout)
        quit(0)
    of 127, 8: # Backspace
      if filter.len > 0:
        filter = filter[0 .. ^2]
        applyFilter()
    of 27: # Escape
      cleanupForExit()
      quit(0)
    of 3: # Ctrl+C
      cleanupForExit()
      quit(1)
    else:
      if key >= 32 and key < 127:
        filter.add char(key)
        applyFilter()

    render()

proc main() =
  let args = commandLineParams()
  if args.len > 0 and args[0] in ["-h", "--help"]:
    echo "his - interactive shell history search"
    echo ""
    echo "Reads history from stdin (e.g. `history | his`) or, if stdin is a"
    echo "terminal, from $HISTFILE (~/.bash_history)."
    echo ""
    echo "Keys:"
    echo "  Up/Down       Move cursor"
    echo "  Home/End      Jump to first/last"
    echo "  Enter         Print selected command and quit"
    echo "  Right         Add selected command to favorites"
    echo "  Left          Remove selected command from favorites"
    echo "  Backspace     Delete filter character"
    echo "  Esc/Ctrl+C    Quit without selection"
    echo "  Any key       Filter (case-insensitive)"
    echo ""
    echo "Shows a compact inline list; set HIS_LINES=N to change its height."
    echo "Favorites are stored one per line in " & (getHomeDir() / ".his_history")
    quit(0)

  favPath = getHomeDir() / ".his_history"
  loadFavorites()

  var piped: bool
  when not defined(windows):
    piped = not ttyIsTTY(STDIN_FILENO)
    if piped:
      try:
        keyInput = open("/dev/tty", fmRead)
      except CatchableError:
        stderr.writeLine "his: requires an interactive terminal"
        quit(1)
      keyFd = cint(getFileHandle(keyInput))
      if not ttyIsTTY(keyFd):
        stderr.writeLine "his: requires an interactive terminal"
        quit(1)
    else:
      keyInput = stdin
      keyFd = STDIN_FILENO
  else:
    piped = not isStdinTTY()
    keyInput = stdin
    if not isStdinTTY():
      stderr.writeLine "his: requires an interactive terminal"
      quit(1)

  buildItems(loadRawHistory(piped))

  let (w, h) = terminalSize()
  termW = w
  termH = h

  hideCursor(stderr)
  setupRawMode()

  stderr.write "\n" # move to a fresh line
  flushFile(stderr)
  let row = queryCursorRow()
  listTopRow = if row > 0: row else: 1

  applyFilter()
  handleInput()

addExitProc proc() =
  cleanupForExit()

when isMainModule:
  main()
