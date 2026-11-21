# Room art

When the learner says "show me how this would look in my room" or "on my wall" with a store page in Chrome's front tab, Clicky hangs that page's art on their wall in a live camera panel, at its real size, and keeps it there while the laptop turns.
The app reads the front tab and its largest picture, calls `/room-art` (Claude reads the size and the art's corners) and `/room-wall` (the local depth service measures the wall) at the same time, and tracks the wall with ECC from then on.

## Sub-features

- `room-art-route` is `/room-art`, which returns the title, the chosen size in cm, the other sizes, and the art's corners in the photo.
- `room-wall-route` is `/room-wall`, which forwards to the depth service and returns the wall plane. It answers 503 without `DEPTH_SERVICE_URL` and 502 when the service is down.
- `room-art-panel` is the camera panel: the art at its corners, the learner in front of it, and the line "Here it is at <size>."
- `room-art-tracking` keeps the art on the wall while the camera turns.

## How to get to it (user POV)

- Open a store page for a framed print in Chrome, hold ctrl+option, and say "how would this look in my room".

## Driving it with verify-clicky.sh

Preconditions:

- The depth service runs: `cd tools/depth-service && DEPTH_PRO_CHECKPOINT=<path to depth_pro.pt> uv run server.py` (port 8801). `curl -s http://127.0.0.1:8801/health` prints `{"ok": true}`.
- The Worker from this checkout answers on the port the app calls (see `app-launch`), since it holds the two routes.
- Chrome's front tab shows a store page for wall art (not Hokusai's Great Wave; vary the item).

- **Routes.** Post a store page's text and photo to `/room-art`, and a frame with an anchor on bare wall to `/room-wall`.
  `/room-art` answers 200 with `isWallArt` true and the page's size, and `/room-wall` answers 200 with `distanceMeters` near the real distance in about 14 s.
- **Panel with a recorded camera.** Run `$V app-launch --room-camera-file <video of a room> "how would this look in my room"`.
  The log shows `Room art:` lines for the page read and the wall, then `Room art: N fps, track N ms, segment N ms` every 5 s.
  Run `$V shot room-art` once the line "Here it is at <size>." plays: the art hangs on the wall in the panel, and a person in the video stays in front of it.
- **Tracking.** In a video that turns, take two shots a second apart: the art moves with the wall, not with the frame.

## Gotchas

- Depth Pro takes about 14 s warm and about 100 s for its first load, so start the service before the run.
- A second Depth Pro process on the same GPU slows both. Stop any other one first.
