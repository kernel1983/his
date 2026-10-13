#!/bin/bash
# his shell integration for bash
#   source /path/to/his/shell/his.sh
#
# Bind Ctrl-R to a fuzzy-ish history search backed by `his`.
# While the picker is open:
#   Up/Down   move      Enter  choose
#   Right     favourite  Left   unfavourite
#   type      filter     Esc    cancel

# Location of the `his` binary; override before sourcing if needed.
: "${HIS_BIN:=his}"

# Ctrl-R action: insert the chosen command into the current prompt.
_his_widget() {
  local selected
  selected=$(HISTTIMEFORMAT= history | command "$HIS_BIN")
  if [[ -n "$selected" ]]; then
    READLINE_LINE="$selected"
    READLINE_POINT=${#READLINE_LINE}
  fi
}

bind -x '"\C-r":_his_widget' 2>/dev/null

# `h`: pick a command and run it immediately.
h() {
  local selected
  selected=$(HISTTIMEFORMAT= history | command "$HIS_BIN")
  if [[ -n "$selected" ]]; then
    eval "$selected"
  fi
}
