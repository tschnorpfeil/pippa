/* Drag geometry, independent of the DOM. The pointer keeps control of the paper. */
(function (root) {
  'use strict';
  const clamp = (n, a, b) => Math.max(a, Math.min(b, n));
  const smooth = n => n * n * (3 - 2 * n);
  const distance = (x, y, r) => Math.hypot(
    Math.max(r.left - x, 0, x - r.right),
    Math.max(r.top - y, 0, y - r.bottom)
  );

  function sample(item, target, options = {}) {
    const radius = options.radius ?? 160;
    const margin = options.margin ?? 32;
    const maxPull = options.maxPull ?? 36;
    const cx = item.centerX, cy = item.centerY;
    const dx = (target.left + target.right) / 2 - cx;
    const dy = (target.top + target.bottom) / 2 - cy;
    const length = Math.hypot(dx, dy);
    const gap = distance(cx, cy, target);
    const strength = smooth(clamp(1 - gap / radius, 0, 1));
    const dock = smooth(clamp(1 - gap / (radius * .4), 0, 1));
    // Gentle outer gravity, then partial centering. Moving away releases it
    // along the same curve: no latch, dead zone or forced destination.
    const pull = Math.min(maxPull * strength, length * (.1 + .32 * dock));
    const overlapWidth = Math.max(0, Math.min(cx + item.width / 2, target.right) - Math.max(cx - item.width / 2, target.left));
    const overlapHeight = Math.max(0, Math.min(cy + item.height / 2, target.bottom) - Math.max(cy - item.height / 2, target.top));
    const smallerArea = Math.min(item.width * item.height, (target.right - target.left) * (target.bottom - target.top));
    const overlap = smallerArea > 0 ? overlapWidth * overlapHeight / smallerArea : 0;
    // Test the unassisted position: feedback and release use exactly the same rule.
    const ready = distance(item.pointerX, item.pointerY, target) <= margin
      || distance(cx, cy, target) <= margin
      || overlap >= .25;
    return { pullX: length ? dx / length * pull : 0, pullY: length ? dy / length * pull : 0, strength, dock, ready };
  }

  const api = Object.freeze({ sample, distance });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PippaDrag = api;
})(typeof window === 'undefined' ? globalThis : window);
