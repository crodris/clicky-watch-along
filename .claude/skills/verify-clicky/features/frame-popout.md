# Frame pop-out

Saying "pop this out" over a YouTube video lifts the subject of the current frame out of the video in 3D, with every part labeled and no question.
The app grabs the frame from the `<video>` element, asks `/video-frame-parts` for the subject box and up to 8 part labels, and plays `frame-popout.html` starting exactly over the video on screen.
On any other page, the same request lifts the largest visible image instead, captured from the screen under it.
A frame without one clear subject, such as a chart or a person talking, returns `subjectFound: false` and nothing pops out.

## Sub-features

- `popout-voice` triggers on "pop this out", "pop out", or up to 3 words between, as in "pop this heart out".
- `popout-route` is the `/video-frame-parts` route, which returns the subject box and part points in frame pixels, `wholePictureIsSubject`, and `pictureShowsDepth`.
- `popout-none` returns `subjectFound: false` for a frame with no clear subject.
- `popout-pauses-video` pauses a playing YouTube video first, with or without a quiz, and plays it again when the pop-out clears, unless the learner had paused it.
- `popout-image` lifts the largest visible image when Chrome's front tab is not a YouTube video.
- `popout-scene` lifts a painted scene out whole, sky included, when the route returns `wholePictureIsSubject: true`.
  Apple's subject lifting cuts out any other subject, including art of one animal on a plain background.
- `popout-put-back` keeps the pop-out up through a push-to-talk tap, and sends it back into its frame when the learner says "put it back" (or "put that away"), during the tour or after it.
- `popout-depth` lifts a picture that already shows depth, such as a 3D cutaway or a photo, as a flat card that only tilts, when the route returns `pictureShowsDepth: true`.
  Flat illustrations and paintings keep the puffed-up lift.
- `popout-animation` keeps an animated page image (GIF, animated WebP, or APNG) playing on the lifted subject and on the frame behind it, when the image sits wholly inside the viewport.
  Reduce Motion keeps the still frame.
- `popout-flows` streams what flows through the picture, like air through an engine, when the learner says "animate this", "make it move", or "make it flow". It uses `/picture-flows`, and Reduce Motion holds the streams still.
- `popout-narration` speaks two or three sentences after a non-quiz pop-out's tour, one part each, and highlights each part as it is named.
  The Claude call starts when the pop-out starts, with the paused frame and the part labels from `/video-frame-parts`.
  For an image on a web page, the prompt calls it a picture, never a video.
- `popout-label-tap` explains a part when its label is clicked after the tour of a pop-out with no quiz.
  A press that moves more than 4 px is a drag that turns the model, not a click.
- `popout-cursor-points` flies the blue triangle to each part's label as the narration names it, with the sentence Clicky is speaking typed in its bubble, and back to the mouse when the narration ends or the scene clears, Escape mid-sentence included.

## How to get to it (user POV)

- With a YouTube video in Chrome's front tab, hold ctrl+option and say "pop this out".
- With a page showing an image, such as a Wikipedia diagram, in Chrome's front tab, say the same thing.

## Driving it with verify-clicky.sh

Preconditions:

- For the route, `$V worker-up` reported the Worker ready on port 8789, and an image of one clear object is on screen.
- For the app, the app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, and the YouTube frame shows one clear object, such as a heart diagram.

- **Route.** Build a body from a screenshot, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && screencapture -x -t jpg "$RUN/frame.jpg" && python3 -c "import base64,json,subprocess,sys;frame_path=sys.argv[1];frame_width,frame_height=[int(subprocess.check_output(['sips','-g',dimension_key,frame_path]).split()[-1]) for dimension_key in ('pixelWidth','pixelHeight')];print(json.dumps({'frameBase64':base64.b64encode(open(frame_path,'rb').read()).decode(),'frameWidth':frame_width,'frameHeight':frame_height,'subject':'','question':'','answerLabel':''}))" "$RUN/frame.jpg" > "$RUN/frame-body.json"`, then `$V post /video-frame-parts "$RUN/frame-body.json"`.
  The result is HTTP 200 with `subjectFound` true, a `subjectBox` inside the frame, `wholePictureIsSubject` and `pictureShowsDepth` as booleans, and 1 to 8 `parts`.
- **Pop out in the app.** Run `$V app-launch "pop this out"`.
  The log shows `grabbed a WxH frame` then `Frame pop-out: lifting the subject out of the frame with N labels`.
  Run `$V shot popout` while the subject floats over the video.
  When the tour ends, the log shows `Frame pop-out narration: N sentences for afterTour`, and Clicky speaks about the parts while each one turns yellow.
  Then click one label without moving the mouse.
  The log shows `Frame pop-out: explaining the tapped <label> label` and `Frame pop-out narration: N sentences for partTapped(label: "<label>")`.
  Drag across a label instead, and the model turns with no tap line in the log.
  While Clicky names each part, run `$V shot popout-pointing` and check that the blue triangle sits just under that label, drawn over the model, with the sentence Clicky is speaking in its bubble, wrapped onto more lines when it is long.
- **Pop out an image in the app.** Open a page with one large image of one clear object in Chrome's front tab, such as `https://commons.wikimedia.org/wiki/File:Diagram_of_the_human_heart_(cropped).svg`.
  Run `$V app-launch "pop this out"`.
  The log shows `captured a WxH image from the screen` then `Frame pop-out: lifting the subject out of the frame with N labels`.
  Run `$V shot image-popout` while the subject floats over the image.
- **Pop out a painted scene.** Post a body built from The Starry Night, as in the route step.
  The result has `wholePictureIsSubject: true` and a `subjectBox` around the whole painting.
  Do the same for a fresco of several figures, such as The Creation of Adam at the top of `https://finearttutorials.com/guide/famous-paintings/`.
  Capture only the image's screen rect with `screencapture -x -t jpg -R x,y,w,h`, since the app sends that rect and a full-screen capture adds the page around it.
  Post it 5 times, since before this fix a figure scene came back as no subject in about half the runs, and every run returns `wholePictureIsSubject: true`.
  Dürer's Young Hare, Stag Beetle, and Rhinoceros and a heart diagram return `wholePictureIsSubject: false`.
  In the app, the log shows `Frame pop-out: lifting the whole picture in Sonnet's box` for The Starry Night, and `Vision kept N of M subjects` for the hare.
  Run `$V shot scene-popout` while the painting floats over the page.
- **A tap keeps the pop-out.** Run `$V app-launch "pop this out"`.
  About 4 seconds after the narration starts speaking, run `$V key push-to-talk-tap`.
  The speech stops within a second, the log ends with `Live scene rehearsal: done, phase allLabelsShowing`, and the pop-out stays on screen.
- **Put it back.** Run `$V app-launch "pop this out|put it back"`.
  The second step logs `Live scene: put back on request`, and the subject flattens back into its frame.
  The rehearsal sends the second step as soon as the tour ends, before the narration speaks, so the tap needs the run above.
- **Pop out a picture that shows depth.** Post bodies built from the Turbofan article's lead image (`https://upload.wikimedia.org/wikipedia/commons/e/e5/Turbofan3_Labelled.gif`, converted to JPEG with `sips`), a photo of an engine (`https://commons.wikimedia.org/wiki/File:F100_F-15_engine.JPG`), and a photo of a flower (`https://commons.wikimedia.org/wiki/File:Magnolia_grandiflora_-_flower_1.jpg`), 3 times each.
  Every run returns `pictureShowsDepth: true`.
  The flower diagram (`Mature_flower_diagram.svg` on Commons), the Turbofan article's side-view schematic (`Tfan-schematic-kk-20090106.png`), a heart diagram, and The Starry Night return `pictureShowsDepth: false` every run.
  In the app, open `https://en.wikipedia.org/wiki/Turbofan` in Chrome's front tab and run `$V app-launch "pop this out"`.
  The log shows `Frame pop-out: lifting the subject out of the frame with N labels as a flat card`.
  Run `$V shot depth-popout` while the card floats over the image, and check that the engine has no smeared or stretched rim.
- **Pop out an animated image.** With `https://en.wikipedia.org/wiki/Turbofan` in Chrome's front tab and the lead GIF wholly on screen, run `$V app-launch "pop this out"`.
  The log shows `Frame pop-out: playing the page image's 21 animation frames` before `Frame pop-out: lifting the subject`.
  Run `$V shot animated-popout` twice about 0.2 seconds apart, and check that the blades and the arrows moved between the two shots with no white blobs at the engine's edge.
  Scroll so the GIF is cut off at the top of the window and pop it out again, and the log has no animation line.
- **Flows route.** Build a body like the route step's, with `partLabels` (the labels from a `/video-frame-parts` reply) in place of `subject`, `question`, and `answerLabel`, then `$V post /picture-flows "$RUN/flows-body.json"`.
  The Turbofan article's schematic and its animated cutaway each return several flows in blue and orange, a heart diagram returns red and blue, and The Starry Night returns `{"flows":[]}`.
  `node bench/bench.ts worker --label flows --runs 1 --only picture-flows-heart,picture-flows-painting` checks the same on the bench fixtures.
- **Animate in the app.** With the Turbofan article's lead GIF wholly on screen, run `$V app-launch "animate this"`.
  The log shows `Frame pop-out: lifting the subject` and then `Frame pop-out: streaming N flows`.
  Run `$V shot flows` after the tour, and check that blue and orange dashes move through the engine's channels below the labels.
  Then run `$V app-launch "pop this out|animate this"`, and the second step logs `streaming N flows` without a second `lifting the subject` line.
- **Cost ceiling.** One `[/video-frame-parts]` usage line per request, with `thinking_tokens` 0 because the route runs at low effort.
  Its output ceiling is not measured yet, and the route stops at 4096 tokens, so a line near 4096 means a cut-off reply.

## Gotchas

- A full-screen screenshot holds many things, so the route may pick an unexpected subject.
  Crop to one object when the subject matters.
- `subjectFound: false` on a chart or a talking head is correct behavior, not a failure.
- AppleScript sends "Google Chrome" commands to whichever Chrome process it finds, and a Playwright-driven Chrome counts.
  When the app log shows `javaScriptFromAppleEventsIsOff` or `noImageOrVideoToPopOut` on a page with a large image, run `pgrep -fl 'Google Chrome --disable-field-trial-config'`, and close that browser once its owner is done with it.
- The pop-out lines up with the video's or image's on-screen rect, on the display that shows it, wherever the mouse is.
  Moving or resizing the Chrome window during the run misplaces it.
- The image rect comes from the web area in Chrome's accessibility tree, so it accounts for page zoom and for side panels, vertical tabs, and docked DevTools.
  Clicky logs "Media rect: placed from Chrome's accessibility web area" when that worked.
  Without a matching web area, such as when Accessibility is off, it falls back to the page-geometry math, logs "placed from the page geometry", and gives no rect when DevTools are docked.
  The first pop-out of a Chrome session can fall back too, because Chrome builds its accessibility tree only once Clicky asks for it, and keeps it on until Chrome quits.
  Only Chrome's windows are captured, so a window of another app over Chrome does not show in the pop-out.
