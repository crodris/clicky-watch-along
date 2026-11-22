# Room art

When the learner says "show me how this would look in my room" or "on my wall" with a store page in Chrome's front tab, Clicky hangs that page's art on their wall in a live camera panel, at its real size, and keeps it there while the laptop turns.
The app reads the front tab and its largest picture, calls `/room-art` (Claude reads the size and the art's corners) and `/room-wall` (the local depth service measures the wall) at the same time, and tracks the wall with ECC from then on.

## Sub-features

- `room-art-route` is `/room-art`, which returns the title, whether the page states the size (`sizeFoundOnPage`), the chosen size in cm, the other sizes, and the art's corners in the photo.
- `room-wall-route` is `/room-wall`, which forwards to the depth service and returns the wall plane. It answers 503 without `DEPTH_SERVICE_URL`, 422 when the service finds no bare wall or the wall is nearer than 0.3 m, farther than 12 m, or under 30% on one plane, and 502 when the service is down.
- `room-art-panel` is the camera panel: the art at its corners, the learner in front of it, and the line "Here it is at 16 by 20 inches.", with the size in inches to the nearest half inch from the measured centimeters.
- `room-art-tracking` keeps the art on the wall while the camera turns, and says "Lost the wall. Turn back, or click the wall to place it again." while the art hides.
- `room-art-checks` are the lines before the camera opens: no app secret, a page that is not https, and page text that could not be read.

## How to get to it (user POV)

- Open a store page for a framed print in Chrome, hold ctrl+option, and say "how would this look in my room".

## Driving it with verify-clicky.sh

Preconditions:

- The depth service runs: `cd tools/depth-service && DEPTH_PRO_CHECKPOINT=<path to depth_pro.pt> uv run server.py` (port 8801). `curl -s http://127.0.0.1:8801/health` prints `{"ok": true}`.
- The Worker from this checkout answers on the port the app calls (see `app-launch`), since it holds the two routes.
- Chrome's front tab shows a store page for wall art (not Hokusai's Great Wave; vary the item).

- **`/room-art`.** Build a body from a screenshot of the store page's photo and the page's own text, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && screencapture -x -t jpg "$RUN/art.jpg" && sips -Z 1200 "$RUN/art.jpg" >/dev/null && python3 -I -c "import base64,json,subprocess,sys;size=dict(line.split(': ') for line in subprocess.check_output(['sips','-g','pixelWidth','-g','pixelHeight',sys.argv[1]],text=True).split(chr(10))[1:3]);print(json.dumps({'pageURL':sys.argv[2],'pageTitle':'Framed print','pageText':sys.argv[3],'picture':{'jpegBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'width':int(size['  pixelWidth']),'height':int(size['  pixelHeight'])}}))" "$RUN/art.jpg" "https://shop.example/print" "Framed print, 16 x 20 in, also in 11 x 14 in" > "$RUN/room-art-body.json"`, then `$V post /room-art "$RUN/room-art-body.json"`.
  It answers 200 with `isWallArt` true, `sizeFoundOnPage` true, and `chosenSize` near 40.6 by 50.8 cm.
  The same body with a `pageText` that names no size answers `sizeFoundOnPage` false.
- **`/room-wall`.** Build a body from a frame of a room video with the anchor at its center, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && ffmpeg -loglevel error -y -ss 1 -i <video of a room> -frames:v 1 "$RUN/wall.jpg" && python3 -I -c "import base64,json,subprocess,sys;size=dict(line.split(': ') for line in subprocess.check_output(['sips','-g','pixelWidth','-g','pixelHeight',sys.argv[1]],text=True).split(chr(10))[1:3]);print(json.dumps({'jpegBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'anchor':{'u':int(size['  pixelWidth'])//2,'v':int(size['  pixelHeight'])//3}}))" "$RUN/wall.jpg" > "$RUN/room-wall-body.json"`, then `$V post /room-wall "$RUN/room-wall-body.json"`.
  It answers 200 with `distanceMeters` near the real distance in about 14 s.
  With the depth service stopped it answers 502, and the app says "Is the depth service running?".
- **Panel with a recorded camera.** Run `$V app-launch --room-camera-file <video of a room> "how would this look in my room"`.
  The log shows `Room art:` lines for the page read and the wall, then `Room art: N fps, track N ms, segment N ms` every 5 s.
  Run `$V shot room-art` once the line "Here it is at <size>." plays: the art hangs on the wall in the panel, and a person in the video stays in front of it.
- **Tracking.** Launch with a video that turns, and once "Here it is" plays, take two shots a second apart.
  Run `$V app-launch --room-camera-file <video that turns> "how would this look in my room"`, then `$V shot room-art-tracking-1; sleep 1; $V shot room-art-tracking-2`.
  The art moves with the wall between the two shots, not with the frame, and the log has a `Room art: N fps` line every 5 s.
  When the video turns away from the wall, the status line says "Lost the wall. Turn back, or click the wall to place it again." until the wall returns.
- **Checks before the camera.** Run `$V app-launch --no-app-secret "how would this look in my room"`: Clicky says "Clicky needs its app secret for this. See the README's Worker setup." and no panel opens.
  With an `http://` page in Chrome's front tab, it says "I can only read store pages served over https.".
- **Worker not reachable.** `app-launch` refuses to start without the Worker it started, so this failure is driven by the unit test, not the app.
  Run `tools/swift-check.sh --filter aWorkerThatGivesNoAnswerSaysItCouldNotBeReached`, which passes when a `URLError` from either route becomes "I couldn't reach Clicky's Worker." with the status "Couldn't reach Clicky's Worker".

## Gotchas

- Depth Pro takes about 14 s warm and about 100 s for its first load, so start the service before the run.
- A second Depth Pro process on the same GPU slows both. Stop any other one first.
- The depth service refuses a request with an `Origin` header (403) or without `content-type: application/json` (415). `$V post` goes through the Worker, which sends neither an Origin header nor a non-JSON body, but a hand-written `curl` to port 8801 needs `-H 'content-type: application/json'`.
