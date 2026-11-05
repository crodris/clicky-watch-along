# Landmark scan

When the learner says "show me" or "render this in 3D" over a YouTube frame of one famous real place, Clicky shows Google's photorealistic 3D scan of it instead of building a scene.
The app asks `/landmark` whether the frame shows a famous place and where it is.
Then `landmark-tiles.html` loads the tiles through `clicky-asset://tiles/`, which the Worker's `GET /v1/3dtiles/` route serves with the Maps key.
The scan is cut down to the structure and about 130 m around it, floating over the video.

## Sub-features

- `landmark-route` is the `/landmark` route, which returns `isFamousPlace`, `name`, `latitude`, `longitude`, `heightMeters`, and `radiusMeters`.
- `landmark-not-famous` returns `isFamousPlace: false`, and the app builds a live scene instead.
- `landmark-tiles` is `GET /v1/3dtiles/...`, which passes only `root.json` and dataset files.

## How to get to it (user POV)

- Pause a YouTube video on a famous place, such as the Eiffel Tower, hold ctrl+option, and say "show me this in 3D".

## Driving it with verify-clicky.sh

Preconditions:

- For the route, `$V worker-up` reported the Worker ready on port 8789, and `worker/.dev.vars` has `GOOGLE_MAPS_API_KEY` for the tiles.
- For the app, the app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, and Chrome's front tab is paused on a frame of one famous place.

- **Route.** Build a body from a screenshot of the place, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && screencapture -x -t jpg "$RUN/place.jpg" && python3 -c "import base64,json,sys;print(json.dumps({'frameBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'videoTitle':'Eiffel Tower tour','learnerRequest':'show me this in 3D'}))" "$RUN/place.jpg" > "$RUN/place-body.json"`, then `$V post /landmark "$RUN/place-body.json"`.
  The result is HTTP 200, `isFamousPlace` true, and the place's real coordinates.
- **Tiles.** Run `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8789/v1/3dtiles/root.json`, which prints 200.
  Any other path, such as `/v1/3dtiles/other.json`, gets 405 because only `root.json` and dataset files match the route.
- **Scan in the app.** Run `$V app-launch "show me this in 3D"`.
  The log shows `Landmark: showing Google 3D tiles of <name>`.
  Run `$V shot landmark` while the scan is up.
- **Cost ceiling.** One `[/landmark]` usage line per request, with `thinking_tokens` 0 and `output_tokens` under 300.
  The route runs at low effort and used 51 output tokens and 0 thinking on 2026-11-05.
  Tile requests spend the Maps key, not model tokens.

## Gotchas

- A frame of an ordinary street returns `isFamousPlace: false`, and the app builds a live scene with no `Landmark:` log line.
  That is correct.
- `Landmark: lookup failed, building the scene instead` means the route failed or the frame grab failed, and the live scene hides that.
  A frame grab fails when Chrome's Allow JavaScript from Apple Events is off or the Automation grant is missing.
- The tiles route spends the Google Maps key for any caller.
  Run cleanup as soon as the run ends.
