# Reads an experiment's control panel from a Retina screenshot of the screen's lower part, for the demo drivers that
# drag its sliders with the real mouse.
#   find <screenshot.png> <top-in-points> <left-in-points>
#     prints {"run": [x, y], "tracks": [[left, right, y], ...], "thumbWidth": w} in screen points
#   thumb-x <panel.json> <state.json> <control-name> <value>
#     prints the screen point "x y" where that control's thumb sits at that value
import json, subprocess, sys

if sys.argv[1] == "thumb-x":
    panel = json.load(open(sys.argv[2]))
    state = json.loads(json.load(open(sys.argv[3]))["result"]["content"][0]["text"])["state"]
    names = [control["name"] for control in state["controls"]]
    control = state["controls"][names.index(sys.argv[4])]
    left, right, y = panel["tracks"][names.index(sys.argv[4])]
    # A range input's thumb center travels from half a thumb inside the left end to half a thumb inside the right end.
    thumb = panel["thumbWidth"] or 24
    share = (float(sys.argv[5]) - control["min"]) / (control["max"] - control["min"])
    print(round(left + thumb / 2 + share * (right - left - thumb), 1), y)
    sys.exit(0)

path, top_points, left_points = sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
size = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().split(",")
width, height = int(size[0]), int(size[1])
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
def pixel(x, y):
    offset = (y * width + x) * 3
    return raw[offset], raw[offset + 1], raw[offset + 2]

def is_run_blue(red, green, blue):
    return blue > 200 and blue - red > 70 and green > 90

# The Run button is the widest blue shape; Clicky's blue triangle is far narrower.
button_rows = [y for y in range(height) if sum(1 for x in range(0, width, 2) if is_run_blue(*pixel(x, y))) > 50]
if not button_rows:
    print(json.dumps({"error": "no Run button"})); sys.exit(1)
button_rows = [y for y in button_rows if y - button_rows[0] < 140]
button_center_y = (button_rows[0] + button_rows[-1]) // 2
button_xs = [x for x in range(width) if is_run_blue(*pixel(x, button_center_y))]
button_left = min(button_xs)
button_center_x = (button_left + max(button_xs)) / 2

def kind(red, green, blue):
    if red >= 251 and green >= 251 and blue >= 251:
        return "W"
    if abs(red - green) < 9 and abs(green - blue) < 9 and red <= 240:
        return "T"
    return "B"

def spans_in_row(y):
    kinds = [kind(*pixel(x, y)) for x in range(button_left)]
    spans, start, gap = [], None, 0
    for x, letter in enumerate(kinds + ["B"] * 40):
        if letter in "TW":
            if start is None:
                start = x
            gap, last = 0, x
        elif start is not None:
            gap += 1
            if gap >= 12:
                spans.append((start, last)); start = None
    return [(left, right) for left, right in spans if right - left > 200]

best_row, best_spans = None, []
for y in range(button_center_y - 30, min(height, button_center_y + 40)):
    spans = spans_in_row(y)
    if len(spans) > len(best_spans) or (len(spans) == len(best_spans) and spans and sum(r - l for l, r in spans) > sum(r - l for l, r in best_spans)):
        best_row, best_spans = y, spans
# The thumb is the widest white run inside the first track.
thumb_width = 0
if best_spans:
    run_length = 0
    for x in range(best_spans[0][0], best_spans[0][1]):
        run_length = run_length + 1 if kind(*pixel(x, best_row)) == "W" else 0
        thumb_width = max(thumb_width, run_length)
to_x = lambda px: round(left_points + px / 2, 1)
to_y = lambda py: round(top_points + py / 2, 1)
print(json.dumps({
    "run": [to_x(button_center_x), to_y(button_center_y)],
    "tracks": [[to_x(left), to_x(right), to_y(best_row)] for left, right in best_spans],
    "thumbWidth": round(thumb_width / 2, 1),
}))
