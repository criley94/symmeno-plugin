#!/bin/sh
# Launches the sc reply-tag hook (reply_tag.py) quietly. hooks.json runs it on each of the person's turns and after a
# compaction or a resume. stdout carries the hook's one JSON answer, or nothing; stderr stays silent; exit is always 0.
# No python3 here, or on a Mac only Apple's stand-in that would ask to install the developer tools: nothing at all.
py=$(command -v python3 2>/dev/null) || exit 0
if [ "$py" = /usr/bin/python3 ] && [ -x /usr/bin/xcode-select ]; then
  /usr/bin/xcode-select -p >/dev/null 2>&1 || exit 0
fi
case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
"$py" -I "$here/reply_tag.py" 2>/dev/null
exit 0
