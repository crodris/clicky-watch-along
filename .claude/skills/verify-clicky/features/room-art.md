# Room art

When the learner says "show me how this would look in my room", "on my wall", or "could I see this shirt on me" with a store page in Chrome's front tab, Clicky tries the item in a live camera panel: wall art hangs on their wall and furniture stands on their floor, each at its real size and kept there while the laptop turns, and a top laid flat in its photo is drawn over the shirt they wear.
The app reads the front tab and its largest picture, opens the panel, and calls `/try-it-item` (Claude reads the kind of item, its size, and its corners) while the camera starts.
The kind decides what follows: `/room-wall` for wall art, `/room-floor` for furniture (the local depth service measures the surface), each tracked with ECC from then on, and no depth call at all for a shirt.
While a surface is measured, Clicky's loop outlines the spot in the panel and follows it as the camera turns, and for a shirt it traces the learner's torso until the shirt shows.

## Sub-features

- `room-art-route` is `/try-it-item`, which returns the title, the item's corners in the photo (`itemCorners`), and an `item` that names its `kind` (`wallArt`, `furniture`, `clothing`, or `other`) and holds that kind's one object.
  For wall art and furniture the object has `sizeFoundOnPage`, the size in cm, and the other sizes, and for clothing it has the garment, sleeves, size label, what the photo shows, and the print.
- `room-wall-route` is `/room-wall`, which forwards to the depth service and returns the wall plane. It answers 503 without `DEPTH_SERVICE_URL`, 422 when the service finds no bare wall or the wall is nearer than 0.3 m, farther than 12 m, or under 30% on one plane, and 502 when the service is down.
- `room-floor-route` is `/room-floor`, the same body with the anchor where the furniture's front-bottom center stands, which returns the floor plane (`forward` and `floorTiltDegrees` in place of the wall's angle), with the same 503, 422, and 502 answers.
- `room-art-panel` is the camera panel: the art at its corners, the learner in front of it, and the line "Here it is at 16 by 20 inches.", with the size in inches to the nearest half inch from the measured centimeters. The status line says "Reading the page…" while the page is read.
- `room-art-furniture` is a piece of furniture standing on the floor. Until its painting arrives nothing is drawn: the loop stays around the footprint and the status line says "Arranging it in your room…". The painting then fades in from the bare room with the line "Here it is, 31.5 inches wide and 29.5 tall.". When no painting can come, or none came within 45 s, the render of the store's or a generated model shows. With no render, nothing is drawn, the loop stays, and Clicky says "I couldn't draw it this time. Click the floor to try again." as a failure, and a click on the floor arranges the piece again. A painting or a render that arrives later still shows the piece. When no floor is found and none can be inferred from the wall, "I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor." with the camera still running, after which a click on the floor measures there.
- `room-art-furniture-model` is the store's own 3D model, rendered and held back as the painting's fallback, shown only when no painting can come or none came within 45 s: found in the page (a store GLB on IKEA and Target; only a GLB is read, so a store with only a USDZ, such as Article, gets the generated model or the painted composite), rendered with the keyframe's camera and light, a top-down contact shadow, and the camera's grain, moving with the room. A click renders it again where the learner clicked.
- `room-art-furniture-composite` is the painted composite, the piece's first look about 20 s after the floor is measured, or a crossfade over the fallback when it comes later, only when the painted piece is no shorter than 85 percent of the measured box's front and no taller than 115 percent of its outline, measured down to the box's lowest corner, and not cut off along the top of the pasted region. The log line `the painted item is N% of the measured box's outline (painted rows ..., box outline ..., front face ...)` says where the painting sits against the box. A Debug build writes each painting to the temporary folder as `clicky-room-furniture-painting-<ms>.png`, with `-keyframe.jpg`, `-mask.png`, and `-box.json` beside it, so a refused painting can be judged again offline (`RoomFurniturePaintedComposite.itemLayers`).
- `room-art-furniture-wall` is the wall measured on the floor's keyframe from the cached depth: a floor not level with the wall is refused as a desk, and with no floor in view the piece stands against the wall on a floor inferred 1.05 m below the camera.
- `room-art-page-sizes` is the page read opening collapsed Measurements, Dimensions, Product details, and Specifications sections, so IKEA's height reaches `/try-it-item`, with only size-like pairs added from the page's structured data.
- `room-art-shirt` is a flat lay top drawn over the learner: the coaching in the status line ("I can't see you yet. Step in front of the camera." or "Stand back so I can see your shoulders and chest."), said once before the shirt shows, then "Here it is on you." and the status "On you".
- `room-art-tracking` keeps the art on the wall, or the furniture on the floor, while the camera turns, and says "Lost the wall. Turn back, or click the wall to place it again." (or the floor's line) while the item hides.
- `room-art-loop` is Clicky's loop around the wall or floor spot while it is measured, and around the learner's torso while a shirt is prepared: the cursor loop's line in the theme's accent, traced and then lapped by the theme's own cursor glyph, following the room or the body, and leaving with a 0.35 s fade when the item shows or the measurement fails.
- `room-art-kinds` are the lines for what the page cannot try: "That doesn't look like wall art, furniture, or a shirt." for a lamp, "I can try on shirts, sweaters, and jackets so far." for a dress, "I can only try on a shirt from a flat photo of it, and this photo shows it on a model." for a model photo, and "I couldn't find the size on that page." for wall art or furniture with no size.
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
  With the depth service stopped it answers 502, and the app says "I couldn't measure your room. Is the depth service running?".
- **`/room-floor`.** The same body from a frame that shows the floor, with the anchor on the floor in the lower part of the frame (`'v':int(size['  pixelHeight'])*3//4`), posted with `$V post /room-floor "$RUN/room-floor-body.json"`.
  It answers 200 with `floorTiltDegrees` under 25 and `distanceMeters` near the real distance, or 422 when no floor shows there.
- **Panel with a recorded camera.** Run `$V app-launch --room-camera-file <video of a room> "how would this look in my room"`.
  The log shows `Room art:` lines for the page read and the wall, then `Room art: N fps, track N ms, segment N ms` every 5 s.
  Run `$V shot room-art-loop` in the first seconds, while the wall is measured: Clicky's loop outlines a bare patch of wall in the theme's accent, with the theme's cursor glyph (the volleyball under a school theme, the triangle under Clicky blue) on it and no white spark, and it is gone about a second after the art shows.
  Run `$V shot room-art` once the line "Here it is at <size>." plays: the art hangs on the wall in the panel, and a person in the video stays in front of it.
- **Picture from the image file.** Leave a cookie banner up over the product photo, such as IKEA's, and run `$V app-launch --room-camera-file <video of a room> "how would this look in my room"`.
  The log says `Room art: used the page's image file (WxH) from <host>` with a long side of at most 1280, and `$V shot room-art` shows the art with no banner on it.
  A picture with no usable file (a page whose image is not https, is under 160 pixels, or is hosted on localhost or a private address) logs `Room art: ... so the picture is a screen capture` and falls back to the capture.
- **Tracking.** Launch with a video that turns, and once "Here it is" plays, take two shots a second apart.
  Run `$V app-launch --room-camera-file <video that turns> "how would this look in my room"`, then `$V shot room-art-tracking-1; sleep 1; $V shot room-art-tracking-2`.
  The art moves with the wall between the two shots, not with the frame, and the log has a `Room art: N fps` line every 5 s.
  When the video turns away from the wall, the status line says "Lost the wall. Turn back, or click the wall to place it again." until the wall returns.
- **Loop following the wall.** Launch with a video that turns, and take two shots a second apart while the wall is still measured, about 14 s with Depth Pro.
  Run `$V app-launch --room-camera-file <video that turns> "how would this look in my room"`, then `$V shot room-art-loop-1; sleep 1; $V shot room-art-loop-2`.
  The loop moves with the wall between the two shots, not with the frame.
- **Furniture on the floor.** Make a camera video from a room photo that shows the floor, such as a slow 10 s zoom with `ffmpeg -loop 1 -i room.jpg -vf "scale=1600:-2,zoompan=z='1+0.0008*on':d=300:s=1280x720:fps=30" -t 10 room-floor.mp4`, open a furniture page that states its size (IKEA's LACK side table or a POÄNG chair), and run `$V app-launch --room-camera-file room-floor.mp4 "how would this table look in my room"`.
  The log shows `Room art: "<title>" at <size>`, then `Room art: floor N m away, tilted N degrees`, and no wall line.
  Run `$V shot room-art-floor-loop` while the floor is measured: the loop outlines a wide, low patch of open floor. For furniture, the log line `moved the piece to where all of it shows` comes as the loop glides to the middle of the piece's footprint, so it fades out where the piece appears.
  While the painting comes, `$V shot` shows no piece, only the loop around the footprint and "Arranging it in your room…".
  Run `$V shot room-art-floor` once "Here it is, <width> inches wide and <height> tall." plays: the whole piece stands on the floor, at least 4 percent inside every edge of the frame, near the lower middle, with its base on the floor and a soft shadow under it, and the log says `Room furniture: moved the piece to where all of it shows`.
  A piece too big for any spot stands where most of it shows, and Clicky says "Step back so I can show the whole piece." after "Here it is".
- **The store's model and the composite.** With the same video, open IKEA's LACK side table (https://www.ikea.com/us/en/p/lack-side-table-white-30449908/), Target's Threshold chair (https://www.target.com/p/-/A-87737798), or Article's Sven sofa, and run the same `app-launch`.
  The log shows `Room art: opened N collapsed sections of the page before reading it` on IKEA, `Room furniture: the page names N model files, ...`, `found the store's own model at <host>`, `rendered in N ms`, and `rendered the storeModel from <host>, held back while the painting comes`, and the render never shows before the painting.
  About 20 s after the floor is measured the log says `showing the painted composite`, and "Here it is" plays then, and `$V shot room-art-furniture-composite` shows the painting.
  When a painting is refused (`painting 1 is shorter than the box's front, taller than its outline, or cut off, so it is not shown`), a second is asked for, and when that is refused too the log says `showing the storeModel, since no painting can come`, and `$V shot room-art-furniture-model` shows the store's model on the floor at the spot, lit like the room, with a soft shadow under it and its feet on the floor.
  On a page with no model the log says `no generated model` without a fal key, then the painting fades in from the bare room, or `nothing to draw, since ...` and the could-not-draw line when none can come.
  The gated room check renders a model on a recorded frame with no app at all: `ROOM_FURNITURE_FRAME=<frame> ROOM_FURNITURE_FLOOR_REPLY=<the /floor reply for it> ROOM_FURNITURE_MODEL=<glb> ROOM_FURNITURE_SIZE_CM=55x45x55 ROOM_FURNITURE_OUT=<folder> tools/swift-check.sh --filter RoomFurnitureRoomCheck`, which writes `<model>-composite.png` and `<model>-metrics.json`, and with `ROOM_FURNITURE_WORKER`, `ROOM_FURNITURE_APP_SECRET`, and `ROOM_FURNITURE_PRODUCT_JPEG` (the furniture's cutout over white) also `<model>-render-and-painting.png` (about $0.045).
- **A shirt on the learner.** Make a camera video from a photo of a person standing with their shoulders and chest in view (a slow zoom as above), open a flat lay shirt page (a Uniqlo UT page, whose main photo shows the shirt laid flat), and run `$V app-launch --room-camera-file standing.mp4 "could I see this shirt on me"`.
  The log shows `Room art: "<title>" is a tshirt laid flat`, and no wall or floor line.
  Run `$V shot room-art-shirt` once "Here it is on you." plays: the shirt covers the learner's own from the shoulders to the hips, the print on the chest, with no white fringe or blocky patches at its edge.
  With a page whose photo shows the shirt on a model, Clicky says "I can only try on a shirt from a flat photo of it, and this photo shows it on a model." and the cursor shakes once.
  With a page for a lamp, Clicky says "That doesn't look like wall art, furniture, or a shirt." instead.
- **Checks before the camera.** Run `$V app-launch --no-app-secret "how would this look in my room"`: Clicky says "Clicky needs its app secret for this. See the README's Worker setup." and no panel opens.
  With an `http://` page in Chrome's front tab, it says "I can only read store pages served over https.".
- **Worker not reachable.** `app-launch` refuses to start without the Worker it started, so this failure is driven by the unit test, not the app.
  Run `tools/swift-check.sh --filter aWorkerThatGivesNoAnswerSaysItCouldNotBeReached`, which passes when a `URLError` from either route becomes "I couldn't reach Clicky's Worker." with the status "Couldn't reach Clicky's Worker".
  Report the app surface as unverified and name this test as the layer that ran.

## Gotchas

- Depth Pro takes about 14 s warm and about 100 s for its first load, so start the service before the run. A shirt makes no depth call, so it needs no service.
- A Debug build draws the shirt at a few frames a second, since its frame analysis runs unoptimized; judge the shirt's look, not its frame rate, in a Debug build.
- A second Depth Pro process on the same GPU slows both. Stop any other one first.
- The depth service keeps the last two depth maps, so furniture's wall request on the floor's keyframe answers in under a second with `depthWasCached` true. A restart empties it.
- The depth service refuses a request with an `Origin` header (403) or without `content-type: application/json` (415). `$V post` goes through the Worker, which sends neither an Origin header nor a non-JSON body, but a hand-written `curl` to port 8801 needs `-H 'content-type: application/json'`.
