# Room art

When the learner says "show me how this would look in my room" or "on my wall" with a store page in Chrome's front tab, Clicky hangs that page's art on their wall in a live camera panel, at its real size, and keeps it there while the laptop turns.
The app reads the front tab and its largest picture, calls `/try-it-item` (Claude reads the kind of item, its size, and its corners) and `/room-wall` (the local depth service measures the wall) at the same time, and tracks the wall with ECC from then on.
While the wall is measured, Clicky's loop outlines the wall spot in the panel and follows it as the camera turns.
Only wall art is placed so far, so a chair or a shirt gets "I can hang wall art so far. Furniture and clothes are coming next.".

## Sub-features

- `room-art-route` is `/try-it-item`, which returns the title, the item's corners in the photo (`itemCorners`), and an `item` that names its `kind` (`wallArt`, `furniture`, `clothing`, or `other`) and holds that kind's one object.
  For wall art and furniture the object has `sizeFoundOnPage`, the size in cm, and the other sizes, and for clothing it has the garment, sleeves, size label, what the photo shows, and the print.
- `room-wall-route` is `/room-wall`, which forwards to the depth service and returns the wall plane. It answers 503 without `DEPTH_SERVICE_URL`, 422 when the service finds no bare wall or the wall is nearer than 0.3 m, farther than 12 m, or under 30% on one plane, and 502 when the service is down.
- `room-art-panel` is the camera panel: the art at its corners, the learner in front of it, and the line "Here it is at 16 by 20 inches.", with the size in inches to the nearest half inch from the measured centimeters.
- `room-art-tracking` keeps the art on the wall while the camera turns, and says "Lost the wall. Turn back, or click the wall to place it again." while the art hides.
- `room-art-loop` is Clicky's loop around the wall spot while the wall is measured: the cursor loop's line and spark in the theme's accent, following the wall as the camera turns, and leaving with a 0.35 s fade when the art shows or the measurement fails.
- `room-art-kinds` are the lines for what the page shows: "I can hang wall art so far. Furniture and clothes are coming next." for furniture and clothing, and "That doesn't look like something that hangs on a wall." for anything else.
- `room-art-picture` is the picture room art hangs and sends to `/try-it-item`: the image file the page names (downloaded over https, at most 8 MB, scaled to a long side of 1280), so a cookie banner or any other element over the photo never hangs with the art, and a screen capture of the picture only when there is no file to use.
- `room-art-checks` are the lines before the camera opens: no app secret, a page that is not https, and page text that could not be read.

## How to get to it (user POV)

- Open a store page for a framed print in Chrome, hold ctrl+option, and say "how would this look in my room".

## Driving it with verify-clicky.sh

Preconditions:

- The depth service runs: `cd tools/depth-service && DEPTH_PRO_CHECKPOINT=<path to depth_pro.pt> uv run server.py` (port 8801). `curl -s http://127.0.0.1:8801/health` prints `{"ok": true}`.
- The Worker from this checkout answers on the port the app calls (see `app-launch`), since it holds the two routes, and it has the `/try-it-item` route, not the older `/room-art`.
- Chrome's front tab shows a store page for wall art (not Hokusai's Great Wave; vary the item).

- **`/try-it-item`.** Build a body from a screenshot of the store page's photo, the page's own text, and the learner's words, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && screencapture -x -t jpg "$RUN/art.jpg" && sips -Z 1200 "$RUN/art.jpg" >/dev/null && python3 -I -c "import base64,json,subprocess,sys;size=dict(line.split(': ') for line in subprocess.check_output(['sips','-g','pixelWidth','-g','pixelHeight',sys.argv[1]],text=True).split(chr(10))[1:3]);print(json.dumps({'pageURL':sys.argv[2],'pageTitle':'Framed print','pageText':sys.argv[3],'learnerRequest':'how would this look in my room','picture':{'jpegBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'width':int(size['  pixelWidth']),'height':int(size['  pixelHeight'])}}))" "$RUN/art.jpg" "https://shop.example/print" "Framed print, 16 x 20 in, also in 11 x 14 in" > "$RUN/try-it-item-body.json"`, then `$V post /try-it-item "$RUN/try-it-item-body.json"`.
  It answers 200 with `item.kind` `wallArt`, `item.wallArt.sizeFoundOnPage` true, and `item.wallArt.size` near 40.6 by 50.8 cm.
  The same body with a `pageText` that names no size answers `sizeFoundOnPage` false.
  The same request on a page for a chair, with the learner's words "how would this chair look in my room", answers `item.kind` `furniture` with a width, height, and depth in cm.
- **`/room-wall`.** Build a body from a frame of a room video with the anchor at its center, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && ffmpeg -loglevel error -y -ss 1 -i <video of a room> -frames:v 1 "$RUN/wall.jpg" && python3 -I -c "import base64,json,subprocess,sys;size=dict(line.split(': ') for line in subprocess.check_output(['sips','-g','pixelWidth','-g','pixelHeight',sys.argv[1]],text=True).split(chr(10))[1:3]);print(json.dumps({'jpegBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'anchor':{'u':int(size['  pixelWidth'])//2,'v':int(size['  pixelHeight'])//3}}))" "$RUN/wall.jpg" > "$RUN/room-wall-body.json"`, then `$V post /room-wall "$RUN/room-wall-body.json"`.
  It answers 200 with `distanceMeters` near the real distance in about 14 s.
  With the depth service stopped it answers 502, and the app says "Is the depth service running?".
- **Panel with a recorded camera.** Run `$V app-launch --room-camera-file <video of a room> "how would this look in my room"`.
  The log shows `Room art:` lines for the page read and the wall, then `Room art: N fps, track N ms, segment N ms` every 5 s.
  Run `$V shot room-art-loop` in the first seconds, while the wall is measured: Clicky's loop outlines a bare patch of wall in the theme's accent, with the white spark on it, and it is gone about a second after the art shows.
  Run `$V shot room-art` once the line "Here it is at <size>." plays: the art hangs on the wall in the panel, and a person in the video stays in front of it.
- **Picture from the image file.** Leave a cookie banner up over the product photo, such as IKEA's, and run `$V app-launch --room-camera-file <video of a room> "how would this look in my room"`.
  The log says `Room art: used the page's image file (WxH) from <host>` with a long side of at most 1280, and `$V shot room-art` shows the art with no banner on it.
  A picture with no usable file (a CSS background, or a page whose image is not https) logs `Room art: ... so the picture is a screen capture` and falls back to the capture.
- **Tracking.** Launch with a video that turns, and once "Here it is" plays, take two shots a second apart.
  Run `$V app-launch --room-camera-file <video that turns> "how would this look in my room"`, then `$V shot room-art-tracking-1; sleep 1; $V shot room-art-tracking-2`.
  The art moves with the wall between the two shots, not with the frame, and the log has a `Room art: N fps` line every 5 s.
  When the video turns away from the wall, the status line says "Lost the wall. Turn back, or click the wall to place it again." until the wall returns.
- **Loop following the wall.** Launch with a video that turns, and take two shots a second apart while the wall is still measured, about 14 s with Depth Pro.
  Run `$V app-launch --room-camera-file <video that turns> "how would this look in my room"`, then `$V shot room-art-loop-1; sleep 1; $V shot room-art-loop-2`.
  The loop moves with the wall between the two shots, not with the frame.
- **A chair or a shirt.** With a store page for a chair in Chrome's front tab, run `$V app-launch --room-camera-file <video of a room> "how would this chair look in my room"`.
  The panel opens, the measurement runs, then Clicky says "I can hang wall art so far. Furniture and clothes are coming next.", the status line says "Only wall art so far. Furniture and clothes are coming next", and the cursor shakes once.
  With a page for a lamp, Clicky says "That doesn't look like something that hangs on a wall." instead.
- **Checks before the camera.** Run `$V app-launch --no-app-secret "how would this look in my room"`: Clicky says "Clicky needs its app secret for this. See the README's Worker setup." and no panel opens.
  With an `http://` page in Chrome's front tab, it says "I can only read store pages served over https.".
- **Worker not reachable.** `app-launch` refuses to start without the Worker it started, so this failure is driven by the unit test, not the app.
  Run `tools/swift-check.sh --filter aWorkerThatGivesNoAnswerSaysItCouldNotBeReached`, which passes when a `URLError` from either route becomes "I couldn't reach Clicky's Worker." with the status "Couldn't reach Clicky's Worker".
  Report the app surface as unverified and name this test as the layer that ran.

## Gotchas

- Depth Pro takes about 14 s warm and about 100 s for its first load, so start the service before the run.
- A second Depth Pro process on the same GPU slows both. Stop any other one first.
- The depth service refuses a request with an `Origin` header (403) or without `content-type: application/json` (415). `$V post` goes through the Worker, which sends neither an Origin header nor a non-JSON body, but a hand-written `curl` to port 8801 needs `-H 'content-type: application/json'`.
