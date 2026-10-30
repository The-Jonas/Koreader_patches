#!/bin/bash
# Usage: shot.sh <output.png> [seconds] [folder or book] — opens KOReader in Xvfb with a Paperwhite 11 screen and saves a screenshot
OUT=$1; WAIT=${2:-12}; DIR=${3:-$HOME/emu/books}
export EMULATE_READER_W=1236 EMULATE_READER_H=1648 EMULATE_READER_DPI=300 KO_MULTIUSER=1 SDL_AUDIODRIVER=dummy
Xvfb :77 -screen 0 1236x1648x24 >/dev/null 2>&1 & XP=$!
sleep 1
cd $HOME/emu/lib/koreader && DISPLAY=:77 ./reader.lua "$DIR" > $HOME/emu/ko.log 2>&1 & KP=$!
sleep $WAIT
DISPLAY=:77 import -window root "$OUT"
kill $KP 2>/dev/null; sleep 1; kill -9 $KP 2>/dev/null; kill $XP 2>/dev/null
