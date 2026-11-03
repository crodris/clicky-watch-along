// Makes a generated live scene rise out of the media it was asked about.
// Reads window.__sceneRise = { screenDataURL, sourceRect: { x, y, width, height } }, with the
// rect in page coordinates, and runs after the generated page's body.
(function () {
  var sceneRise = window.__sceneRise;
  var body = document.body;
  if (!sceneRise || !sceneRise.screenDataURL || !sceneRise.sourceRect || !body) { return; }

  var pageWidth = window.innerWidth;
  var pageHeight = window.innerHeight;
  var sourceRect = sceneRise.sourceRect;
  var sourceCenterX = sourceRect.x + sourceRect.width / 2;
  var sourceCenterY = sourceRect.y + sourceRect.height / 2;
  var sourceIsUsable = sourceRect.width >= 50 && sourceRect.height > 0 &&
    sourceCenterX >= 0 && sourceCenterX <= pageWidth &&
    sourceCenterY >= 0 && sourceCenterY <= pageHeight;
  if (!sourceIsUsable) { return; }

  var maximumSecondsToWaitForTheScene = 1.5;
  var riseSeconds = 1.6;
  var copyFadeSeconds = 0.6;
  var backdropFadeSeconds = 0.8;
  var backdropOpacity = 0.6;
  var riseEasing = 'cubic-bezier(0.65, 0, 0.35, 1)';

  // The backdrop and the copy sit outside the body, so the body transform does not move them.
  function createFixedLayer(layerId, zIndex) {
    var layer = document.createElement('div');
    layer.id = layerId;
    layer.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:' + zIndex + ';';
    document.documentElement.appendChild(layer);
    return layer;
  }

  var backdrop = createFixedLayer('scene-rise-backdrop', 0);
  backdrop.style.background = 'rgb(0, 0, 0)';
  backdrop.style.opacity = '0';

  // The full screenshot clipped to the media, so it lines up with the screen under the overlay.
  var copy = createFixedLayer('scene-rise-copy', 2);
  copy.style.backgroundImage = 'url("' + sceneRise.screenDataURL + '")';
  copy.style.backgroundSize = '100% 100%';
  copy.style.opacity = '1';
  var clipTop = Math.max(0, sourceRect.y);
  var clipLeft = Math.max(0, sourceRect.x);
  var clipRight = Math.max(0, pageWidth - (sourceRect.x + sourceRect.width));
  var clipBottom = Math.max(0, pageHeight - (sourceRect.y + sourceRect.height));
  copy.style.clipPath = 'inset(' + clipTop + 'px ' + clipRight + 'px ' + clipBottom + 'px ' + clipLeft + 'px)';

  // A body with no size of its own would not map the full page onto the rect.
  body.style.position = 'relative';
  body.style.zIndex = '1';
  body.style.margin = '0';
  body.style.width = pageWidth + 'px';
  body.style.height = pageHeight + 'px';
  body.style.transformOrigin = '0 0';
  var shrinkScale = Math.min(sourceRect.width / pageWidth, sourceRect.height / pageHeight);
  var shiftX = sourceCenterX - shrinkScale * pageWidth / 2;
  var shiftY = sourceCenterY - shrinkScale * pageHeight / 2;
  body.style.transform = 'translate(' + shiftX + 'px, ' + shiftY + 'px) scale(' + shrinkScale + ')';

  function startTheRise() {
    // Without a layout read, a first-frame start would skip the transition and jump.
    void body.offsetWidth;
    body.style.transition = 'transform ' + riseSeconds + 's ' + riseEasing;
    body.style.transform = 'none';
    copy.style.transition = 'opacity ' + copyFadeSeconds + 's';
    copy.style.opacity = '0';
    backdrop.style.transition = 'opacity ' + backdropFadeSeconds + 's';
    backdrop.style.opacity = String(backdropOpacity);
    // Mouse drag and label math must run on an untransformed page.
    setTimeout(function () {
      body.style.transition = '';
      body.style.transform = '';
      body.style.transformOrigin = '';
    }, riseSeconds * 1000 + 100);
  }

  var startedAt = performance.now();
  function waitForTheScene(now) {
    if (window.__ready === true || (now - startedAt) / 1000 >= maximumSecondsToWaitForTheScene) {
      startTheRise();
      return;
    }
    requestAnimationFrame(waitForTheScene);
  }
  requestAnimationFrame(waitForTheScene);
})();
