# Frame pop-out

Saying "pop this out" over a YouTube video lifts the subject of the current frame out of the video in 3D, with every part labeled and no question.
The app grabs the frame from the `<video>` element, asks `/video-frame-parts` for the subject box and up to 8 part labels, and plays `frame-popout.html` starting exactly over the video on screen.
On any other page, the same request lifts the largest visible image instead, captured from the screen under it.
A frame without one clear subject, such as a chart or a person talking, returns `subjectFound: false` and nothing pops out.

## Sub-features

- `popout-voice` triggers on "pop this out", "pop out", or up to 3 words between, as in "pop this heart out".
- `popout-route` is the `/video-frame-parts` route, which returns the subject box and part points in frame pixels.
- `popout-none` returns `subjectFound: false` for a frame with no clear subject.
- `popout-in-quiz` pauses a running video quiz first.
- `popout-image` lifts the largest visible image when Chrome's front tab is not a YouTube video.
- `popout-scene` lifts a painted scene out whole, sky included, when the route returns `wholePictureIsSubject: true`.
  Apple's subject lifting cuts out any other subject, including art of one animal on a plain background.

## How to get to it (user POV)

- With a YouTube video in Chrome's front tab, hold ctrl+option and say "pop this out".
- With a page showing an image, such as a Wikipedia diagram, in Chrome's front tab, say the same thing.

## Driving it with verify-clicky.sh

Preconditions:

- For the route, `$V worker-up` reported the Worker ready on port 8789, and an image of one clear object is on screen.
- For the app, the app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, and the YouTube frame shows one clear object, such as a heart diagram.

- **Route.** Build a body from a screenshot, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && screencapture -x -t jpg "$RUN/frame.jpg" && python3 -c "import base64,json,subprocess,sys;frame_path=sys.argv[1];frame_width,frame_height=[int(subprocess.check_output(['sips','-g',dimension_key,frame_path]).split()[-1]) for dimension_key in ('pixelWidth','pixelHeight')];print(json.dumps({'frameBase64':base64.b64encode(open(frame_path,'rb').read()).decode(),'frameWidth':frame_width,'frameHeight':frame_height,'subject':'','question':'','answerLabel':''}))" "$RUN/frame.jpg" > "$RUN/frame-body.json"`, then `$V post /video-frame-parts "$RUN/frame-body.json"`.
  The result is HTTP 200 with `subjectFound` true, a `subjectBox` inside the frame, and 1 to 8 `parts`.
- **Pop out in the app.** Run `$V app-launch "pop this out"`.
  The log shows `grabbed a WxH frame` then `Frame pop-out: lifting the subject out of the frame with N labels`.
  Run `$V shot popout` while the subject floats over the video.
- **Pop out an image in the app.** Open a page with one large image of one clear object in Chrome's front tab, such as `https://commons.wikimedia.org/wiki/File:Diagram_of_the_human_heart_(cropped).svg`.
  Run `$V app-launch "pop this out"`.
  The log shows `captured a WxH image from the screen` then `Frame pop-out: lifting the subject out of the frame with N labels`.
  Run `$V shot image-popout` while the subject floats over the image.
- **Pop out a painted scene.** Post a body built from The Starry Night, as in the route step.
  The result has `wholePictureIsSubject: true` and a `subjectBox` around the whole painting.
  Dürer's Young Hare, Stag Beetle, and Rhinoceros and a heart diagram return `wholePictureIsSubject: false`.
  In the app, the whole Starry Night lifts out, not only the cypress, and the hare lifts out without its paper.
- **Cost ceiling.** One `[/video-frame-parts]` usage line per request, with `thinking_tokens` 0 because the route runs at low effort.
  Its output ceiling is not measured yet, and the route stops at 4096 tokens, so a line near 4096 means a cut-off reply.

## Gotchas

- A full-screen screenshot holds many things, so the route may pick an unexpected subject.
  Crop to one object when the subject matters.
- `subjectFound: false` on a chart or a talking head is correct behavior, not a failure.
- The pop-out lines up with the video's or image's on-screen rect, on the display that shows it, wherever the mouse is.
  Moving or resizing the Chrome window during the run misplaces it.
- The image rect comes from the web area in Chrome's accessibility tree, so it accounts for page zoom and for side panels, vertical tabs, and docked DevTools.
  Clicky logs "Media rect: placed from Chrome's accessibility web area" when that worked.
  Without a matching web area, such as when Accessibility is off, it falls back to the page-geometry math, logs "placed from the page geometry", and gives no rect when DevTools are docked.
  The first pop-out of a Chrome session can fall back too, because Chrome builds its accessibility tree only once Clicky asks for it, and keeps it on until Chrome quits.
  Only Chrome's windows are captured, so a window of another app over Chrome does not show in the pop-out.
