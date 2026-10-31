#!/bin/zsh
# Walks through every Claude Code alert, for screen recordings. Sends the same events Claude Code
# sends through Brim's hook. Permission and question scenes wait for your answer in the notch.
# Usage: scripts/dev/demo.sh [seconds before starting]
H=/Applications/Brim.app/Contents/Resources/claude-hook.sh
P=${0:A:h:h:h}   # project folder, so the notch shows "brim"
ev() { echo "$1" | $H >/dev/null; }
# Waits until the request is answered in the notch.
ask() { echo "$1" | $H; }
scene() { print -P "\n%B▶ $1%b"; }
pause() { sleep $1; }
# Puts a Finder window in front, so clicking the alert visibly jumps back to the terminal.
away() { open ~/Documents; sleep 1; }

print "Brim Claude Code demo. Starting in ${1:-5} s."
sleep ${1:-5}

scene "1. Permission to run a command: click ✓"
ask '{"hook_event_name":"PermissionRequest","session_id":"demo1","cwd":"'$P'","tool_name":"Bash","tool_input":{"command":"npm run build && npm test"}}'
pause 2.5

scene "2. Permission to edit a file: click ✕"
ask '{"hook_event_name":"PermissionRequest","session_id":"demo2","cwd":"'$P'","tool_name":"Edit","tool_input":{"file_path":"'$P'/Sources/Brim/IslandView.swift","old_string":"a\nb","new_string":"a\nb\nc\nd"}}'
pause 2.5

scene "3. Question with one answer: pick an option"
ask '{"hook_event_name":"PermissionRequest","session_id":"demo3","cwd":"'$P'","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which style do you prefer for the notch character?","header":"Style","multiSelect":false,"options":[{"label":"Pixelado","description":"Hard edges, like the one in the terminal"},{"label":"Smooth","description":"Rounded corners, more Apple-like"},{"label":"Both","description":"A setting to choose in Settings"}]}]}}'
pause 2.5

scene "4. Question with several answers: check two and click Send"
ask '{"hook_event_name":"PermissionRequest","session_id":"demo4","cwd":"'$P'","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which alerts should also show on the external display?","header":"Alerts","multiSelect":true,"options":[{"label":"Volume and brightness","description":"The HUD drop"},{"label":"Music","description":"Artwork and equalizer next to the notch"},{"label":"Claude","description":"The critter and its drops"},{"label":"Charging","description":"The little face when you plug in"}]}]}}'
pause 2.5

scene "5. Question too long for the notch: click it to jump to the terminal (10 s)"
away
ev '{"hook_event_name":"PreToolUse","session_id":"demo5","cwd":"'$P'","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Before going on, should alerts also appear on the external display when the lid is closed, or only on the Mac's screen, and should that be a setting?","header":"Displays","multiSelect":false,"options":[{"label":"Yes, on every display","description":""},{"label":"Only on the Mac","description":""},{"label":"Only on the external display","description":""},{"label":"Ask me later","description":""},{"label":"It depends","description":""}]}]}}'
pause 10
ev '{"hook_event_name":"SessionEnd","session_id":"demo5","cwd":"'$P'"}'
pause 2.5

scene "6. Finished: hover to read the summary (9 s)"
away
ev '{"hook_event_name":"UserPromptSubmit","session_id":"demo6","cwd":"'$P'"}'
ev '{"hook_event_name":"Stop","session_id":"demo6","cwd":"'$P'","last_assistant_message":"Done.\n\nAdded the screen recording indicator: a timer on the right and a stop button on the left. It builds and the tests pass."}'
pause 11

scene "7. Waiting for you: click it (9 s)"
away
ev '{"hook_event_name":"Notification","session_id":"demo7","cwd":"'$P'","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
pause 9
ev '{"hook_event_name":"SessionEnd","session_id":"demo7","cwd":"'$P'"}'
pause 2.5

scene "8. Error (7 s)"
ev '{"hook_event_name":"StopFailure","session_id":"demo8","cwd":"'$P'","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}'
pause 9

print -P "\n%BDone.%b"
