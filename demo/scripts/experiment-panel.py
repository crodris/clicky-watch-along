# Reads an experiment's control panel from a Retina screenshot of the screen's lower part, for the demo drivers that
# drag its sliders with the real mouse.
#   find <screenshot.png> <top-in-points> <left-in-points>
#     prints {"run": [x, y], "tracks": [[left, right, y], ...], "thumbWidth": w} in screen points
#   thumb-x <panel.json> <state.json> <control-name> <value>
#     prints the screen point "x y" where that control's thumb sits at that value
# It looks for the sliders only in the Run button's row, which holds them while the panel has 1 or 2 controls. With 3
# controls the Run button wraps to its own row, so thumb-x stops with an error when the tracks found do not match the
# page's controls, and the driver stops instead of dragging the wrong slider.
import json, subprocess, sys

command = sys.argv[1]

if command == "thumb-x":
    panel_path, state_path, control_name, value_text = sys.argv[2:6]
    panel = json.load(open(panel_path))
    state = json.loads(json.load(open(state_path))["result"]["content"][0]["text"])["state"]
    control_names = [control["name"] for control in state["controls"]]
    if len(panel["tracks"]) != len(control_names):
        print(f"found {len(panel['tracks'])} slider tracks for {len(control_names)} controls", file=sys.stderr)
        sys.exit(1)
    control_index = control_names.index(control_name)
    control = state["controls"][control_index]
    track_left, track_right, track_y = panel["tracks"][control_index]
    # A range input's thumb center travels from half a thumb inside the left end to half a thumb inside the right end.
    thumb_width = panel["thumbWidth"] or 24
    share_of_range = (float(value_text) - control["min"]) / (control["max"] - control["min"])
    print(round(track_left + thumb_width / 2 + share_of_range * (track_right - track_left - thumb_width), 1), track_y)
    sys.exit(0)

screenshot_path, top_points, left_points = sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
size_fields = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", screenshot_path], capture_output=True, text=True).stdout.strip().split(",")
width, height = int(size_fields[0]), int(size_fields[1])
raw_pixels = subprocess.run(["ffmpeg", "-v", "error", "-i", screenshot_path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout

def pixel(pixel_x, pixel_y):
    offset = (pixel_y * width + pixel_x) * 3
    return raw_pixels[offset], raw_pixels[offset + 1], raw_pixels[offset + 2]

def is_run_blue(red, green, blue):
    return blue > 200 and blue - red > 70 and green > 90

# The Run button is the widest blue shape; Clicky's blue triangle is far narrower.
button_rows = [row for row in range(height) if sum(1 for column in range(0, width, 2) if is_run_blue(*pixel(column, row))) > 50]
if not button_rows:
    print(json.dumps({"error": "no Run button"}))
    sys.exit(1)
button_rows = [row for row in button_rows if row - button_rows[0] < 140]
button_center_y = (button_rows[0] + button_rows[-1]) // 2
button_columns = [column for column in range(width) if is_run_blue(*pixel(column, button_center_y))]
button_left = min(button_columns)
button_center_x = (button_left + max(button_columns)) / 2

def kind(red, green, blue):
    """W for a thumb's white, T for a gray track, B for the panel's warm background or anything else."""
    if red >= 251 and green >= 251 and blue >= 251:
        return "W"
    if abs(red - green) < 9 and abs(green - blue) < 9 and red <= 240:
        return "T"
    return "B"

def track_spans_in_row(row):
    kinds = [kind(*pixel(column, row)) for column in range(button_left)]
    spans, span_start, background_run, span_end = [], None, 0, 0
    for column, letter in enumerate(kinds + ["B"] * 40):
        if letter in "TW":
            if span_start is None:
                span_start = column
            background_run, span_end = 0, column
        elif span_start is not None:
            background_run += 1
            if background_run >= 12:
                spans.append((span_start, span_end))
                span_start = None
    return [(span_left, span_right) for span_left, span_right in spans if span_right - span_left > 200]

def total_length(spans):
    return sum(span_right - span_left for span_left, span_right in spans)

best_row, best_spans = None, []
for row in range(button_center_y - 30, min(height, button_center_y + 40)):
    spans = track_spans_in_row(row)
    if len(spans) > len(best_spans) or (len(spans) == len(best_spans) and spans and total_length(spans) > total_length(best_spans)):
        best_row, best_spans = row, spans
# The thumb is the widest white run inside the first track.
thumb_width_pixels = 0
if best_spans:
    white_run = 0
    for column in range(best_spans[0][0], best_spans[0][1]):
        white_run = white_run + 1 if kind(*pixel(column, best_row)) == "W" else 0
        thumb_width_pixels = max(thumb_width_pixels, white_run)

def to_screen_x(pixel_x):
    return round(left_points + pixel_x / 2, 1)

def to_screen_y(pixel_y):
    return round(top_points + pixel_y / 2, 1)

print(json.dumps({
    "run": [to_screen_x(button_center_x), to_screen_y(button_center_y)],
    "tracks": [[to_screen_x(span_left), to_screen_x(span_right), to_screen_y(best_row)] for span_left, span_right in best_spans],
    "thumbWidth": round(thumb_width_pixels / 2, 1),
}))
