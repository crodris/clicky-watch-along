# Landmark scan

When the learner says "show me" or "render this in 3D" over a YouTube frame of one famous real place, Clicky shows Google's photorealistic 3D scan of it instead of building a scene.
The app asks `/landmark` whether the frame shows a famous place and where it is, then `landmark-tiles.html` loads the tiles through `clicky-asset://tiles/`, which the Worker's `GET /v1/3dtiles/` route serves with the Maps key.
The scan is cut down to the structure and about 130 m around it, floating over the video.

## Sub-features

- `landmark-route` is the `/landmark` route, which returns `isFamousPlace`, `name`, `latitude`, `longitude`, `heightMeters`, and `radiusMeters`.
- `landmark-not-famous` returns `isFamousPlace: false`, and the app builds a live scene instead.
- `landmark-tiles` is `GET /v1/3dtiles/...`, which passes only `root.json` and dataset files.

## How to get to it (user POV)

- Pause a YouTube video on a famous place, such as the Eiffel Tower, hold ctrl+option, and say "show me this in 3D".

## Driving it with verify-clicky.sh

Preconditions:

- For the route: `$V worker-up` reported the Worker ready on port 8789, and `worker/.dev.vars` has `GOOGLE_MAPS_API_KEY` for the tiles.
- For the app: the app preconditions in [Live scene](./live-scene.md), and Chrome's front tab paused on a frame of one famous place.

- **Route.** Build a body from a screenshot of the place, then post it. Run `screencapture -x -t jpg .verify-clicky/place.jpg && python3 -c "import base64,json;print(json.dumps({'frameBase64':base64.b64encode(open('.verify-clicky/place.jpg','rb').read()).decode(),'videoTitle':'Eiffel Tower tour','learnerRequest':'show me this in 3D'}))" > .verify-clicky/place-body.json`, then `$V post /landmark .verify-clicky/place-body.json`. HTTP 200, `isFamousPlace` true, and the place's real coordinates.
- **Tiles.** Run `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8789/v1/3dtiles/root.json`. It prints 200. Any other path, such as `/v1/3dtiles/other.json`, gets 405 because only `root.json` and dataset files match the route.
- **Scan in the app.** Run `$V app-launch "show me this in 3D"`. The log shows `Landmark: showing Google 3D tiles of <name>`. Run `$V shot landmark` while the scan is up.
- **Cost ceiling.** One `[/landmark]` usage line per request. Tile requests spend the Maps key, not model tokens.

## Gotchas

- A frame of an ordinary street returns `isFamousPlace: false`, and the app logs nothing from `Landmark:` before building a live scene. That is correct.
- `Landmark: lookup failed, building the scene instead` means the route failed, and the live scene hides that. Check for it.
- The tiles route spends the Google Maps key for any caller. Do not leave a Worker on 8789 running after the run.
