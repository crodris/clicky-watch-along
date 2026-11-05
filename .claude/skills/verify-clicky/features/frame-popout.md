# Frame pop-out

Saying "pop this out" over a YouTube video lifts the subject of the current frame out of the video in 3D, with every part labeled and no question.
The app grabs the frame from the `<video>` element, asks `/video-frame-parts` for the subject box and up to 8 part labels, and plays `frame-popout.html` starting exactly over the video on screen.
A frame without one clear subject, such as a chart or a person talking, returns `subjectFound: false` and nothing pops out.

## Sub-features

- `popout-voice` triggers on "pop this out", "pop out", or up to 3 words between, as in "pop this heart out".
- `popout-route` is the `/video-frame-parts` route, which returns the subject box and part points in frame pixels.
- `popout-none` returns `subjectFound: false` for a frame with no clear subject.
- `popout-in-quiz` pauses a running video quiz first.

## How to get to it (user POV)

- With a YouTube video in Chrome's front tab, hold ctrl+option and say "pop this out".

## Driving it with verify-clicky.sh

Preconditions:

- For the route: `$V worker-up` reported the Worker ready on port 8789, and an image of one clear object is on screen.
- For the app: the app preconditions in [Live scene](./live-scene.md), and a paused YouTube frame that shows one clear object, such as a heart diagram.

- **Route.** Build a body from a screenshot, then post it. Run `screencapture -x -t jpg .verify-clicky/frame.jpg && python3 -c "import base64,json,subprocess;w,h=[int(subprocess.check_output(['sips','-g',k,'.verify-clicky/frame.jpg']).split()[-1]) for k in ('pixelWidth','pixelHeight')];print(json.dumps({'frameBase64':base64.b64encode(open('.verify-clicky/frame.jpg','rb').read()).decode(),'frameWidth':w,'frameHeight':h,'subject':'','question':'','answerLabel':''}))" > .verify-clicky/frame-body.json`, then `$V post /video-frame-parts .verify-clicky/frame-body.json`. HTTP 200 with `subjectFound` true, a `subjectBox` inside the frame, and 1 to 8 `parts`.
- **Pop out in the app.** Run `$V app-launch "pop this out"`. The log shows `grabbed a WxH frame` then `Frame pop-out: lifting the subject out of the frame with N labels`. Run `$V shot popout` while the subject floats over the video.
- **Cost ceiling.** One `[/video-frame-parts]` usage line per request.

## Gotchas

- A full-screen screenshot holds many things, so the route may pick an unexpected subject. Crop to one object when the subject matters.
- `subjectFound: false` on a chart or a talking head is correct behavior, not a failure.
- The pop-out lines up with the video's on-screen rect. Moving or resizing the Chrome window during the run misplaces it.
