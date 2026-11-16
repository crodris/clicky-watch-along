#!/usr/bin/env bash
# Runs beside record-shot.sh for the "let me try it" trebuchet shot. The rehearsal speaks the first run ("set the angle
# to 45 degrees and run it"), so the clip shows a run set by voice. This driver then plays the second explore run and
# the challenge with the real mouse, dragging the panel's sliders and clicking Run, so the clip also shows them set by
# hand. Clicky's blue triangle follows the mouse, so the drags show on camera although the recording hides the pointer.
# It reads the controls and the challenge through the Debug app's voice tool endpoint, and finds the sliders in a
# screenshot with experiment-panel.py. The challenge target is new in every build, so the first try sets the angle to
# 45 degrees and scales the launch speed from the last trial (range grows with speed squared and with sin(2 * angle)),
# overshooting once on purpose, then each correction works from the miss's measured landing distance until a run
# lands in the ring, up to 3 more times.
# Usage, from the checkout's root, started just before record-shot.sh:
#   <this script> demo/public/trebuchet.events.txt.raw &
set -u
raw_events_path="$1"
rm -f "$raw_events_path"
endpoint="http://127.0.0.1:8790/mcp"
scripts_folder="$(cd "$(dirname "$0")" && pwd)"
work_folder="$(mktemp -d)"
mouse="$work_folder/mouse"
swiftc -O "$scripts_folder/mouse/mouse.swift" -o "$mouse" || { echo "driver: could not build the mouse tool" >&2; exit 1; }
# The panel sits in the lower half of the MacBook screen, which is 1710 by 1107 points.
screenshot_top=550
# Where the mouse rests between moves: right of the panel, so the blue triangle never covers it.
resting_point="1180 760"

wait_for_log_line() {
  for _ in $(seq 1 1600); do
    grep -q "$1" "$raw_events_path" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "driver: gave up waiting for: $1" >&2
  return 1
}

call_tool() {
  curl -s -X POST "$endpoint" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}

# Prints: angle-name angle speed-name speed target. mode "first" plans an overshoot from the last trial, mode "correct"
# plans the hit from the last trial, which is the miss.
plan_run() {
  python3 -I -c '
import json, math, sys
mode = sys.argv[1]
state = json.loads(json.loads(sys.argv[2])["result"]["content"][0]["text"])["state"]
controls = state["controls"]
def find(words, units):
    for control in controls:
        text = (control["name"] + " " + control["label"]).lower()
        if any(word in text for word in words) or control["unit"] in units:
            return control
    return None
angle = find(["angle"], ["°", "deg", "degrees"])
speed = find(["speed", "velocity"], ["m/s"])
challenge = state["challenge"]
target = challenge["target"]
wanted = challenge["readoutLabel"].strip().lower()
last = state["pastRuns"][0]
measured = next(r["value"] for r in last["readouts"] if r["label"].strip().lower() == wanted)
def control_value(run, control):
    return next(c["value"] for c in run["controls"] if c["label"] == control["label"])
last_angle = control_value(last, angle)
last_speed = control_value(last, speed)
def on_slider(control, value):
    step = control["step"]
    return min(max(round(round(value / step) * step, 3), control["min"]), control["max"])
if mode == "first":
    new_angle = on_slider(angle, 45)
    scale = math.sin(math.radians(2 * last_angle)) / math.sin(math.radians(2 * new_angle))
    new_speed = on_slider(speed, last_speed * math.sqrt(target / measured * scale) * 1.12)
else:
    # Range grows with speed squared, and the speed slider moves in coarse steps, so the angle takes up what is left.
    # Rounding the speed up keeps the predicted range past the target, so a lower angle can bring it back to the ring.
    exact_speed = last_speed * math.sqrt(target / measured * math.sin(math.radians(2 * last_angle)))
    new_speed = min(math.ceil(exact_speed / speed["step"] - 1e-9) * speed["step"], speed["max"])
    # The range at 45 degrees with the new speed, from the last run scaled by speed squared and sin(2 * angle).
    predicted = measured * (new_speed / last_speed) ** 2 / math.sin(math.radians(2 * last_angle))
    wanted_sine = min(target / predicted, 1)
    new_angle = on_slider(angle, math.degrees(math.asin(wanted_sine)) / 2)
print(angle["name"], new_angle, speed["name"], new_speed, target)
' "$1" "$2"
}

# Drags one control's slider thumb from where it is to the value, then checks the value the page took, since a
# thumb lands on the nearest step. A miss of a step or two gets a short second drag, and set_control only as a last
# resort, so every change the clip shows comes from the mouse.
drag_control_to() {
  local control_name="$1" wanted_value="$2"
  screencapture -x -R"0,$screenshot_top,1710,$((1107 - screenshot_top))" "$work_folder/panel.png"
  python3 -I "$scripts_folder/experiment-panel.py" find "$work_folder/panel.png" "$screenshot_top" 0 >"$work_folder/panel.json" || { echo "driver: no panel found" >&2; return 1; }
  call_tool zoom '{"factor":1}' >"$work_folder/state.json"
  local current_value
  current_value="$(python3 -I -c 'import json,sys; s=json.loads(json.load(open(sys.argv[1]))["result"]["content"][0]["text"])["state"]; print(next(c["value"] for c in s["controls"] if c["name"]==sys.argv[2]))' "$work_folder/state.json" "$control_name")"
  local aim_value="$wanted_value"
  for attempt in 1 2 3; do
    read -r from_x from_y <<<"$(python3 -I "$scripts_folder/experiment-panel.py" thumb-x "$work_folder/panel.json" "$work_folder/state.json" "$control_name" "$current_value")"
    read -r to_x to_y <<<"$(python3 -I "$scripts_folder/experiment-panel.py" thumb-x "$work_folder/panel.json" "$work_folder/state.json" "$control_name" "$aim_value")"
    "$mouse" drag "$from_x" "$from_y" "$to_x" "$to_y" 0.9
    sleep 0.5
    call_tool zoom '{"factor":1}' >"$work_folder/state.json"
    current_value="$(python3 -I -c 'import json,sys; s=json.loads(json.load(open(sys.argv[1]))["result"]["content"][0]["text"])["state"]; print(next(c["value"] for c in s["controls"] if c["name"]==sys.argv[2]))' "$work_folder/state.json" "$control_name")"
    echo "driver: dragged $control_name toward $wanted_value, the page took $current_value" >&2
    python3 -I -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 1e-6 else 1)' "$current_value" "$wanted_value" && return 0
    # Aim past the miss by the size of the miss, since the thumb's travel differs a little from the estimate.
    aim_value="$(python3 -I -c 'import sys; w,c,a=map(float,sys.argv[1:]); print(a + (w - c))' "$wanted_value" "$current_value" "$aim_value")"
  done
  echo "driver: the drag missed $control_name, setting it through the endpoint" >&2
  call_tool set_control "{\"name\":\"$control_name\",\"value\":$wanted_value}" >/dev/null
}

click_run() {
  screencapture -x -R"0,$screenshot_top,1710,$((1107 - screenshot_top))" "$work_folder/panel.png"
  python3 -I "$scripts_folder/experiment-panel.py" find "$work_folder/panel.png" "$screenshot_top" 0 >"$work_folder/panel.json" || return 1
  read -r run_x run_y <<<"$(python3 -I -c 'import json,sys; print(*json.load(open(sys.argv[1]))["run"])' "$work_folder/panel.json")"
  "$mouse" click "$run_x" "$run_y"
  sleep 0.3
  "$mouse" move $resting_point 0.7
}

run_with() {
  read -r angle_name angle_value speed_name speed_value target <<<"$1"
  echo "driver: target $target, running $angle_name=$angle_value $speed_name=$speed_value" >&2
  drag_control_to "$angle_name" "$angle_value"
  sleep 0.4
  drag_control_to "$speed_name" "$speed_value"
  sleep 0.6
  click_run
}

# The page words its own question, such as 40 against 60 degrees or a faster release, so the two explore runs are
# planned from the question Clicky spoke: the control it names and the two values it gives, or a step up from now.
plan_explore_runs() {
  python3 -I -c '
import json, re, sys
question = next(line for line in open(sys.argv[1]) if "What" in line and "guess?" in line)
state = json.loads(json.loads(sys.argv[2])["result"]["content"][0]["text"])["state"]
controls = state["controls"]
speed_words = ("speed", "fast", "velocity")
# The question names the control it tests first, as in "changing the release angle ... keep its speed the same".
first_place = lambda words: min([question.lower().find(w) for w in words if w in question.lower()] or [len(question)])
wants_speed = first_place(speed_words) < first_place(("angle", "degree"))
control = next(c for c in controls if (any(w in (c["name"] + c["label"]).lower() for w in speed_words)) == wants_speed)
numbers = [float(n) for n in re.findall(r"(\d+(?:\.\d+)?)\s*(?:-|\s)?(?:degree|m/s|meters per second)", question)]
if len(numbers) >= 2:
    first, second = numbers[0], numbers[1]
elif wants_speed:
    first, second = control["value"], min(control["max"], control["value"] * 1.4)
else:
    first, second = 45, 70
snap = lambda value: min(max(round(round(value / control["step"]) * control["step"], 3), control["min"]), control["max"])
print(control["name"], snap(first), snap(second))
' "$raw_events_path" "$1"
}

# The rehearsal speaks the first run, so the second one, at the other value the question names, is set by hand.
wait_for_log_line "guess check skipped after run 1" || exit 1
"$mouse" move $resting_point 0.8
sleep 4.5
read -r explore_name explore_first explore_second <<<"$(plan_explore_runs "$(call_tool zoom '{"factor":1}')")"
# The voice run used 45 degrees, so a question about 30 against 45 takes its other value instead.
[[ "$explore_name" == *angle* && "$explore_second" == 45* ]] && explore_second="$explore_first"
echo "driver: second explore run $explore_name = $explore_second" >&2
drag_control_to "$explore_name" "$explore_second"
sleep 0.6
click_run

wait_for_log_line "Simulation: challenge started" || exit 1
# The challenge prompt is spoken next. A press during it would cut it off, so wait for its line and its audio.
wait_for_log_line "earlier runs to aim" || exit 1
sleep 7

plan="$(plan_run first "$(call_tool zoom '{"factor":1}')")" || { echo "driver: could not plan the first try" >&2; exit 1; }
run_with "$plan"
wait_for_log_line "Try again" || wait_for_log_line "You hit the target" || exit 1
grep -q "You hit the target" "$raw_events_path" && { echo "driver: hit on the first try" >&2; exit 0; }
sleep 5

for try_number in 2 3 4; do
  plan="$(plan_run correct "$(call_tool zoom '{"factor":1}')")" || { echo "driver: could not plan the correction" >&2; exit 1; }
  misses_before="$(grep -c "Try again" "$raw_events_path")"
  run_with "$plan"
  for _ in $(seq 1 120); do
    grep -q "You hit the target" "$raw_events_path" && { echo "driver: hit on try $try_number" >&2; exit 0; }
    (( $(grep -c "Try again" "$raw_events_path") > misses_before )) && break
    sleep 0.25
  done
  sleep 5
done
echo "driver: no hit after 4 tries" >&2
exit 1
