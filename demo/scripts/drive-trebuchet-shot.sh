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
# The folder holds the built mouse tool and screenshots of the screen, so it goes when the driver ends.
trap 'rm -rf "$work_folder"' EXIT
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

# The endpoint has no state-only tool, and every page tool returns the page's state, so a zoom by a factor of 1 reads
# the controls, the trials, and the challenge without changing the view.
read_page_state() {
  call_tool zoom '{"factor":1}'
}

# Prints one control's current value from a saved state reply.
control_value_in() {
  python3 -I -c '
import json, sys
state_path, control_name = sys.argv[1], sys.argv[2]
state = json.loads(json.load(open(state_path))["result"]["content"][0]["text"])["state"]
print(next(control["value"] for control in state["controls"] if control["name"] == control_name))
' "$1" "$2"
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
measured = next(readout["value"] for readout in last["readouts"] if readout["label"].strip().lower() == wanted)
def control_value(run, control):
    return next(run_control["value"] for run_control in run["controls"] if run_control["label"] == control["label"])
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
  read_page_state >"$work_folder/state.json"
  local current_value aim_value="$wanted_value" from_x from_y to_x to_y
  current_value="$(control_value_in "$work_folder/state.json" "$control_name")" || { echo "driver: no control named $control_name" >&2; return 1; }
  for attempt in 1 2 3; do
    read -r from_x from_y <<<"$(python3 -I "$scripts_folder/experiment-panel.py" thumb-x "$work_folder/panel.json" "$work_folder/state.json" "$control_name" "$current_value")" || return 1
    read -r to_x to_y <<<"$(python3 -I "$scripts_folder/experiment-panel.py" thumb-x "$work_folder/panel.json" "$work_folder/state.json" "$control_name" "$aim_value")" || return 1
    "$mouse" drag "$from_x" "$from_y" "$to_x" "$to_y" 0.9 || return 1
    sleep 0.5
    read_page_state >"$work_folder/state.json"
    current_value="$(control_value_in "$work_folder/state.json" "$control_name")" || return 1
    echo "driver: dragged $control_name toward $wanted_value, the page took $current_value" >&2
    python3 -I -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 1e-6 else 1)' "$current_value" "$wanted_value" && return 0
    # Aim past the miss by the size of the miss, since the thumb's travel differs a little from the estimate.
    aim_value="$(python3 -I -c 'import sys; wanted, taken, aimed = map(float, sys.argv[1:]); print(aimed + (wanted - taken))' "$wanted_value" "$current_value" "$aim_value")"
  done
  echo "driver: the drag missed $control_name, setting it through the endpoint" >&2
  call_tool set_control "{\"name\":\"$control_name\",\"value\":$wanted_value}" >/dev/null
}

click_run() {
  local run_x run_y
  screencapture -x -R"0,$screenshot_top,1710,$((1107 - screenshot_top))" "$work_folder/panel.png"
  python3 -I "$scripts_folder/experiment-panel.py" find "$work_folder/panel.png" "$screenshot_top" 0 >"$work_folder/panel.json" || { echo "driver: no Run button found" >&2; return 1; }
  read -r run_x run_y <<<"$(python3 -I -c 'import json,sys; print(*json.load(open(sys.argv[1]))["run"])' "$work_folder/panel.json")"
  "$mouse" click "$run_x" "$run_y" || return 1
  sleep 0.3
  "$mouse" move $resting_point 0.7
}

run_with() {
  local angle_name angle_value speed_name speed_value target
  read -r angle_name angle_value speed_name speed_value target <<<"$1"
  echo "driver: target $target, running $angle_name=$angle_value $speed_name=$speed_value" >&2
  drag_control_to "$angle_name" "$angle_value" || return 1
  sleep 0.4
  drag_control_to "$speed_name" "$speed_value" || return 1
  sleep 0.6
  click_run
}

# Waits for the run's spoken result: 0 for a hit, 1 for a miss, 2 when neither comes, so a first-try hit ends at once.
wait_for_try_result() {
  local misses_before="$1" misses_now
  for _ in $(seq 1 120); do
    grep -q "You hit the target" "$raw_events_path" 2>/dev/null && return 0
    misses_now="$(grep -c "Try again" "$raw_events_path" 2>/dev/null)"
    (( ${misses_now:-0} > misses_before )) && return 1
    sleep 0.25
  done
  return 2
}

# The page words its own question, such as 40 against 60 degrees or a faster release, so the two explore runs are
# planned from the question Clicky spoke: the control it names first and the two values it gives, or a step up from
# now. A control whose name or label appears in the question wins, and the angle or speed words decide otherwise.
plan_explore_runs() {
  python3 -I -c '
import json, re, sys
question = next((line for line in open(sys.argv[1]) if "What" in line and "guess?" in line), None)
if question is None:
    sys.exit("no guess question in the app log")
lowered_question = question.lower()
state = json.loads(json.loads(sys.argv[2])["result"]["content"][0]["text"])["state"]
controls = state["controls"]
speed_words = ("speed", "fast", "velocity")
def first_place(words):
    places = [lowered_question.find(word) for word in words if word in lowered_question]
    return min(places) if places else len(question)
# The question names the control it tests first, as in "changing the release angle ... keep its speed the same".
named_controls = sorted(
    (first_place((control["label"].lower(), control["name"].lower())), index)
    for index, control in enumerate(controls)
    if first_place((control["label"].lower(), control["name"].lower())) < len(question)
)
if named_controls:
    control = controls[named_controls[0][1]]
    wants_speed = any(word in (control["name"] + control["label"]).lower() for word in speed_words)
else:
    wants_speed = first_place(speed_words) < first_place(("angle", "degree"))
    def is_speed_control(candidate):
        return any(word in (candidate["name"] + candidate["label"]).lower() for word in speed_words)
    def is_angle_control(candidate):
        return any(word in (candidate["name"] + candidate["label"] + candidate["unit"]).lower() for word in ("angle", "deg"))
    if wants_speed:
        control = next((candidate for candidate in controls if is_speed_control(candidate)), None)
    else:
        control = next((candidate for candidate in controls if is_angle_control(candidate)), None)
        control = control or next((candidate for candidate in controls if not is_speed_control(candidate)), None)
if control is None:
    sys.exit("no control matches the question")
is_angle = not wants_speed and any(word in (control["name"] + control["label"] + control["unit"]).lower() for word in ("angle", "deg"))
# Only numbers in the unit of the control count, so "40 degrees" never sets a speed.
unit_pattern = r"degree" if is_angle else r"m/s|meters per second" if wants_speed else re.escape(control["unit"].lower() or "\x00")
numbers = [float(number) for number in re.findall(r"(\d+(?:\.\d+)?)\s*(?:-|\s)?(?:" + unit_pattern + ")", lowered_question)]
if len(numbers) >= 2:
    first, second = numbers[0], numbers[1]
elif is_angle:
    first, second = 45, 70
else:
    first, second = control["value"], min(control["max"], control["value"] * 1.4)
snap = lambda value: min(max(round(round(value / control["step"]) * control["step"], 3), control["min"]), control["max"])
print(control["name"], snap(first), snap(second))
' "$raw_events_path" "$1"
}

# The rehearsal speaks the first run, so the second one, at the other value the question names, is set by hand.
wait_for_log_line "guess check skipped after run 1" || exit 1
"$mouse" move $resting_point 0.8
sleep 4.5
explore_plan="$(plan_explore_runs "$(read_page_state)")" || { echo "driver: could not plan the second explore run" >&2; exit 1; }
read -r explore_name explore_first explore_second <<<"$explore_plan"
# The voice run used 45 degrees, so a question about 30 against 45 takes its other value instead.
[[ "$explore_name" == *angle* && "$explore_second" == 45* ]] && explore_second="$explore_first"
echo "driver: second explore run $explore_name = $explore_second" >&2
drag_control_to "$explore_name" "$explore_second" || exit 1
sleep 0.6
click_run || exit 1

wait_for_log_line "Simulation: challenge started" || exit 1
# The challenge prompt is spoken next. A press during it would cut it off, so wait for its line and its audio.
wait_for_log_line "earlier runs to aim" || exit 1
sleep 7

for try_number in 1 2 3 4; do
  # The first try overshoots on purpose from the explore runs, and each later one corrects from the miss before it.
  plan_mode=correct
  (( try_number == 1 )) && plan_mode=first
  plan="$(plan_run "$plan_mode" "$(read_page_state)")" || { echo "driver: could not plan try $try_number" >&2; exit 1; }
  misses_before="$(grep -c "Try again" "$raw_events_path")"
  run_with "$plan" || exit 1
  wait_for_try_result "$misses_before"
  case $? in
    0) echo "driver: hit on try $try_number" >&2; exit 0 ;;
    2) echo "driver: no result after try $try_number" >&2; exit 1 ;;
  esac
  sleep 5
done
echo "driver: no hit after 4 tries" >&2
exit 1
