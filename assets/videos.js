/* ==========================================================
   tono — video player helper
   - Smart autoplay (muted, loops): desktop + wide viewport
   - Click-to-play fallback on mobile / narrow viewport
   - Custom play/pause overlay (no native controls)
   ========================================================== */
(function () {
  'use strict';

  // Desktop-only autoplay threshold: ≥ 720px wide and a fine pointer (not touch-only)
  function shouldAutoplay() {
    return window.matchMedia('(min-width: 720px) and (hover: hover) and (pointer: fine)').matches;
  }

  function setupVideo(frame) {
    var video = frame.querySelector('video');
    var overlay = frame.querySelector('.play-overlay');
    if (!video) return;

    // Mark autoplay intent before any user gesture; data attr lets per-video override
    var auto = frame.dataset.autoplay === 'true';
    var muted = frame.dataset.muted !== 'false'; // default true for autoplay safety

    video.muted = muted;
    video.loop = true;
    video.playsInline = true;
    video.preload = auto ? 'metadata' : 'none';

    var playIcon = '<svg class="icon-play" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg>';
    var pauseIcon = '<svg class="icon-pause" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M6 5h4v14H6zM14 5h4v14h-4z"/></svg>';
    var btn = frame.querySelector('.play-button');
    if (btn && !btn.innerHTML.trim()) {
      btn.innerHTML = playIcon + pauseIcon;
    }

    function setPlaying(playing) {
      frame.classList.toggle('is-playing', playing);
      if (overlay) overlay.setAttribute('aria-hidden', playing ? 'true' : 'false');
    }

    function tryPlay() {
      var p = video.play();
      if (p && typeof p.catch === 'function') {
        p.catch(function () { /* autoplay blocked — leave paused with overlay */ });
      }
    }

    function toggle(e) {
      if (e) { e.preventDefault(); e.stopPropagation(); }
      if (video.paused) { tryPlay(); } else { video.pause(); }
    }

    // Click anywhere on the frame to toggle
    frame.addEventListener('click', toggle);
    // Buttons inside the overlay forward the click to the frame
    if (btn) btn.addEventListener('click', toggle);
    if (overlay) overlay.addEventListener('click', toggle);

    video.addEventListener('play', function () { setPlaying(true); });
    video.addEventListener('pause', function () { setPlaying(false); });
    video.addEventListener('ended', function () { setPlaying(false); });

    // Smart autoplay
    if (auto && shouldAutoplay()) {
      // Wait a tick so layout settles (helps with fade-in reveals)
      setTimeout(tryPlay, 300);
    }

    // Keyboard: space / enter on focused frame toggles
    frame.setAttribute('tabindex', '0');
    frame.setAttribute('role', 'button');
    frame.addEventListener('keydown', function (e) {
      if (e.key === ' ' || e.key === 'Enter') { toggle(e); }
    });
  }

  function init() {
    var frames = document.querySelectorAll('.video-frame');
    frames.forEach(setupVideo);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();