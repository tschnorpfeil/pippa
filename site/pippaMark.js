/**
 * PippaMark: Pippas Figur. Drei organische Ringe als 2D-Röhren auf einem Canvas,
 * ohne WebGL und ohne Framework.
 *
 * Vier Zustände, alle Übergänge unterbrechbar über kritisch gedämpfte Federn:
 *  • ruht     Drei organische Kreise liegen übereinander, leicht wobbelnd, mit Leuchten.
 *  • arbeitet Die Ringe drehen nacheinander im Raum, jede Drehung um eine feste
 *             Achse aus einer festen Folge, die inneren Ringe mit Nachlauf. Vorne
 *             liegende Teile sind breiter, hinten liegende schmaler.
 *  • offen    Die Ringe werden zu einem Lächeln, in Grün.
 *  • fehler   Die Ringe werden zu einem traurigen Mund, in Rot.
 *
 * Farben kommen zur Laufzeit aus CSS-Variablen am Canvas oder einem Vorfahren
 * (beliebige CSS-Farbe): --pippa-ink, --pippa-ink-offen, --pippa-ink-fehler.
 * Ein Wechsel von class oder data-theme am Wurzelelement liest sie neu.
 *
 * Im Zustand ruht lebt die Figur leise weiter: die Kreise wobbeln, atmen (~9 s)
 * und das Leuchten pulsiert. `{ alive: false }` lässt sie stattdessen stillstehen.
 * `{ idleSpeed: 1.6 }` lässt sie lebhafter atmen (Standard 1).
 * `{ idleAmplitude: 1.25 }` verstärkt Wobble und Atem nur im Idle (Standard 1).
 * Die ganze Figur schaut, nickt und atmet: Arbeit hat einen konzentrierten
 * Rhythmus, Erfolg einen kurzen Hüpfer, Fehler ein einmaliges Kopfschütteln.
 * `{ alive: false }` lässt diese Körpersprache aus. Unsichtbare Canvas zeichnen nicht.
 * `prefers-reduced-motion` zeigt die Zielform ohne Bewegung.
 *
 * Nutzung:
 *   const mark = new PippaMark(canvas, { size: 40, state: 'ruht' });
 *   mark.setState('arbeitet');
 *   mark.pulse();     // kurzer Impuls bei neuen Befunden
 *   mark.destroy();
 */
(function (global) {
  'use strict';

  const TAU = Math.PI * 2;
  const FRAME_MS = 1000 / 30;
  const STATES = ['ruht', 'arbeitet', 'offen', 'fehler'];

  /* Kontur der ruhenden Kreise */
  const IDLE_AMP = 1.35;
  const KREIS_RADIUS = 0.34;
  const STRANG_ABSTAND = 0.016;
  const STRAENGE = [{ amp: 1.0, alpha: 1.0 }, { amp: 0.6, alpha: 0.6 }, { amp: 0.3, alpha: 0.42 }];
  const STRAND_OFFSET = 1.2;
  function kreisWobble(angle, strand, time, circleWeight = 1, amplitude = 1) {
    return 1 + circleWeight * IDLE_AMP * amplitude *
      (0.035 * Math.sin(3 * angle + time / 1400 + strand * STRAND_OFFSET) +
       0.026 * Math.sin(2 * angle - time / 2100 + strand * STRAND_OFFSET * 0.7));
  }
  const kreisStrich = size => Math.max(1.4, size * 0.052);
  function kreisGlow(size, time) {
    const oscillation = (Math.sin(time / 4500) + 1) / 2;
    return 0.5 * size * 0.16 * (0.5 + 0.5 * oscillation);
  }

  /* Bewegung */
  const TURN_MS = 2600;
  const TRAIL_MS = 240;
  function fixedAxis(degrees, depth) {
    const angle = degrees * Math.PI / 180;
    const length = Math.hypot(1, depth);
    return { x: Math.cos(angle) / length, y: Math.sin(angle) / length, z: depth / length };
  }
  // Feste Folge: eine Achse je Drehung, von den nachlaufenden Ringen geteilt.
  const ORBIT_AXES = [68, -28, 119, 24, 87, -49].map(d => fixedAxis(d, 0));
  const ORBIT_RINGS = [{ offset: 0 }, { offset: TRAIL_MS }, { offset: 2 * TRAIL_MS }];

  /** Oberer 2×2-Teil der Rodrigues-Matrix: Drehung um feste Achse, 2D-Projektion. */
  function orbitProjection(axis, angle) {
    const c = Math.cos(angle), s = Math.sin(angle), k = 1 - c;
    return {
      xx: c + axis.x * axis.x * k, xy: axis.x * axis.y * k - axis.z * s,
      yx: axis.x * axis.y * k + axis.z * s, yy: c + axis.y * axis.y * k,
      zx: axis.z * axis.x * k - axis.y * s, zy: axis.z * axis.y * k + axis.x * s,
    };
  }
  const depthWidth = (depth, strength = 0.28) => 1 + strength * Math.max(-1, Math.min(1, depth));
  const IDLE_POSE = { xx: 1, xy: 0, yx: 0, yy: 1, zx: 0, zy: 0 };
  /** Die fehlende dritte Spalte ist das Kreuzprodukt der ersten beiden. */
  function composeOrbitPose(l, r) {
    const xz = l.yx * l.zy - l.zx * l.yy;
    const yz = l.zx * l.xy - l.xx * l.zy;
    const zz = l.xx * l.yy - l.yx * l.xy;
    return {
      xx: l.xx * r.xx + l.xy * r.yx + xz * r.zx, xy: l.xx * r.xy + l.xy * r.yy + xz * r.zy,
      yx: l.yx * r.xx + l.yy * r.yx + yz * r.zx, yy: l.yx * r.xy + l.yy * r.yy + yz * r.zy,
      zx: l.zx * r.xx + l.zy * r.yx + zz * r.zx, zy: l.zx * r.xy + l.zy * r.yy + zz * r.zy,
    };
  }

  /** Exakte kritisch gedämpfte Feder: Umzielen behält Position und Geschwindigkeit. */
  function advanceMorph(spring, target, seconds, reduced = false, attenuation = Math.exp(-18 * seconds), frequency = 18) {
    if (reduced) { spring.value = target; spring.velocity = 0; return false; }
    if (seconds === 0) return Math.abs(spring.value - target) > 0.005 || Math.abs(spring.velocity) > 0.02;
    const distance = spring.value - target;
    const impulse = (spring.velocity + frequency * distance) * seconds;
    spring.value = target + (distance + impulse) * attenuation;
    spring.velocity = (spring.velocity - frequency * impulse) * attenuation;
    const moving = Math.abs(spring.value - target) > 0.005 || Math.abs(spring.velocity) > 0.02;
    if (!moving) { spring.value = target; spring.velocity = 0; }
    return moving;
  }
  const scalar = value => ({ value, velocity: 0 });

  function createOrbitOrientation() { return { channels: [0, 0, 0, 1].map(scalar) }; }
  function poseQuaternion(p) {
    const { xx, xy, yx, yy, zx, zy } = p;
    const xz = yx * zy - zx * yy, yz = zx * xy - xx * zy, zz = xx * yy - yx * xy;
    const trace = xx + yy + zz;
    if (trace > 0) { const s = Math.sqrt(trace + 1) * 2; return [(zy - yz) / s, (xz - zx) / s, (yx - xy) / s, s / 4]; }
    if (xx > yy && xx > zz) { const s = Math.sqrt(1 + xx - yy - zz) * 2; return [s / 4, (xy + yx) / s, (xz + zx) / s, (zy - yz) / s]; }
    if (yy > zz) { const s = Math.sqrt(1 + yy - xx - zz) * 2; return [(xy + yx) / s, s / 4, (yz + zy) / s, (xz - zx) / s]; }
    const s = Math.sqrt(1 + zz - xx - yy) * 2;
    return [(xz + zx) / s, (yz + zy) / s, s / 4, (yx - xy) / s];
  }
  /** Gedämpfte Orientierung mit Halbkugel-Kontinuität; Normierung erhält das Volumen des Rings. */
  function advanceOrbitOrientation(orientation, target, seconds, snap = false, frequency = 18) {
    const q = poseQuaternion(target);
    const ch = orientation.channels;
    const sign = ch.reduce((sum, c, i) => sum + c.value * q[i], 0) < 0 ? -1 : 1;
    let moving = false;
    const attenuation = Math.exp(-frequency * seconds);
    ch.forEach((c, i) => { moving = advanceMorph(c, q[i] * sign, seconds, snap, attenuation, frequency) || moving; });
    const length = Math.hypot(...ch.map(c => c.value));
    ch.forEach(c => { c.value /= length; c.velocity /= length; });
    const radial = ch.reduce((sum, c) => sum + c.value * c.velocity, 0);
    ch.forEach(c => { c.velocity -= radial * c.value; });
    const [x, y, z, w] = ch.map(c => c.value);
    return { moving, pose: {
      xx: 1 - 2 * (y * y + z * z), xy: 2 * (x * y - z * w),
      yx: 2 * (x * y + z * w), yy: 1 - 2 * (x * x + z * z),
      zx: 2 * (x * z - y * w), zy: 2 * (y * z + x * w),
    } };
  }

  /* Abgestimmte Arbeitsbewegung */
  const WORKING_MOTION = Object.freeze({
    speed: 1.6, overlap: 1000, trail: 440, response: 1, wander: 0, easing: 0.8, axisSpread: 8,
    axisRotation: 0, tempoVariation: 1, depth: 0.2, perspective: 0.025, stroke: 1.55, morph: 18, glow: 0.3,
  });
  function createTunedChoreography(settings) {
    const duration = TURN_MS + settings.overlap;
    const axes = ORBIT_RINGS.map((_, strand) => {
      const offset = (settings.axisRotation + (strand - 1) * settings.axisSpread) * Math.PI / 180;
      return ORBIT_AXES.map(a => ({ x: a.x * Math.cos(offset) - a.y * Math.sin(offset), y: a.x * Math.sin(offset) + a.y * Math.cos(offset), z: 0 }));
    });
    const prefixes = axes.map(sequence => {
      const bases = [IDLE_POSE];
      for (const axis of sequence) bases.push(composeOrbitPose(orbitProjection(axis, Math.PI), bases[bases.length - 1]));
      return bases;
    });
    const cycleAngles = prefixes.map(b => Math.atan2(b[ORBIT_AXES.length].yx, b[ORBIT_AXES.length].xx));
    const clock = t => t + settings.tempoVariation * (180 * Math.sin(t * TAU / 15600) + 75 * Math.sin(t * TAU / 10400));
    return (elapsed, strand) => {
      const latestClock = clock(elapsed);
      const latestTurn = Math.floor(latestClock / TURN_MS);
      let vx = 0, vy = 0;
      for (let turn = Math.max(0, latestTurn - 1); turn <= latestTurn; turn += 1) {
        const p = (latestClock - turn * TURN_MS) / duration;
        if (p < 0 || p > 1) continue;
        const speed = (1 - settings.easing) + settings.easing * Math.sin(Math.PI * p);
        vx += speed * ORBIT_AXES[turn % ORBIT_AXES.length].x;
        vy += speed * ORBIT_AXES[turn % ORBIT_AXES.length].y;
      }
      const factor = 1 + settings.response * (-0.25 + 0.5 * Math.min(1, Math.hypot(vx, vy))) + settings.wander * Math.sin(elapsed / 2700);
      const time = clock(Math.max(0, elapsed - strand * settings.trail * factor));
      const latest = Math.floor(time / TURN_MS);
      const completed = Math.max(0, Math.floor((time - settings.overlap) / TURN_MS));
      const step = completed % ORBIT_AXES.length;
      const cycleAngle = Math.floor(completed / ORBIT_AXES.length) * cycleAngles[strand];
      let pose = composeOrbitPose(prefixes[strand][step], { xx: Math.cos(cycleAngle), xy: -Math.sin(cycleAngle), yx: Math.sin(cycleAngle), yy: Math.cos(cycleAngle), zx: 0, zy: 0 });
      for (let turn = completed; turn <= latest; turn += 1) {
        const p = Math.max(0, Math.min(1, (time - turn * TURN_MS) / duration));
        const angle = Math.PI * ((1 - settings.easing) * p + settings.easing * (0.5 - 0.5 * Math.cos(Math.PI * p)));
        pose = composeOrbitPose(orbitProjection(axes[strand][turn % ORBIT_AXES.length], angle), pose);
      }
      return pose;
    };
  }
  const workingPose = createTunedChoreography(WORKING_MOTION);

  // One small pose per frame, shared by every vertex. Gestures happen once on
  // entry; the held expression breathes quietly instead of repeating the cue.
  function expression(state, time, idle, alive, reduced) {
    const pose = { x: 0, y: 0, angle: 0, scaleX: 1, scaleY: 1 };
    if (!alive || reduced) return pose;
    if (state === 'ruht') {
      pose.x = .022 * Math.sin(idle / 1700);
      pose.y = -.012 * (1 - Math.cos(idle / 2200));
      pose.angle = .065 * Math.sin(idle / 2100) + .025 * Math.sin(idle / 900);
    } else if (state === 'arbeitet') {
      const focus = Math.sin(time / 440);
      pose.x = .012 * Math.sin(time / 600);
      pose.y = -.014 * (1 - Math.cos(time / 320));
      pose.angle = .035 * Math.sin(time / 900);
      pose.scaleX += .018 * focus;
      pose.scaleY -= .018 * focus;
    } else if (state === 'offen') {
      const progress = Math.min(1, time / 900);
      const hop = Math.sin(Math.PI * progress) ** 2;
      const breath = .008 * Math.sin(time / 800);
      pose.y = -.055 * hop;
      pose.angle = .09 * Math.sin(TAU * progress) * hop + .015 * Math.sin(time / 1800);
      pose.scaleX += .04 * hop + breath;
      pose.scaleY += .06 * hop + breath;
    } else if (state === 'fehler') {
      const settle = Math.exp(-time / 220);
      pose.x = .055 * Math.sin(time / 55) * settle;
      pose.y = .008 * (1 - Math.cos(time / 1700));
      pose.angle = .055 * Math.sin(time / 85) * settle + .016 * Math.sin(time / 1900);
      pose.scaleY += -.025 * settle + .006 * Math.sin(time / 1100);
    }
    return pose;
  }

  /* Renderer */
  class PippaMark {
    constructor(canvas, opts) {
      opts = opts || {};
      this.canvas = canvas;
      this.size = opts.size || 40;
      this.state = STATES.includes(opts.state) ? opts.state : 'ruht';
      this.reduced = !!(global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches);
      this.options = { ...WORKING_MOTION, stroke: Number.isFinite(opts.stroke) && opts.stroke > 0 ? opts.stroke : WORKING_MOTION.stroke };
      this.alive = opts.alive !== false;
      this.idleSpeed = opts.idleSpeed > 0 ? opts.idleSpeed : 1;
      this.idleAmplitude = opts.idleAmplitude > 0 ? opts.idleAmplitude : 1;
      this.frame = 0; this.visible = true; this.lastPaint = null; this.nextPaint = 0; this.moving = true;
      this._setup();
      this._paint(0, true);
      this._wake();
      this._theme = new MutationObserver(() => { this._readColors(); this._wake(); });
      this._theme.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'data-theme'] });
      this._io = typeof IntersectionObserver === 'undefined' ? null : new IntersectionObserver(entries => {
        this.visible = entries.some(e => e.isIntersecting);
        if (!this.visible) this._stop(); else if (this._animates()) this._wake();
      });
      if (this._io) this._io.observe(canvas);
      this._vis = () => { if (document.hidden) this._stop(); else if (this._animates()) this._wake(); };
      document.addEventListener('visibilitychange', this._vis);
    }

    setState(state) {
      if (!STATES.includes(state) || state === this.state) return;
      this.state = state;
      this.engine.expression = 0;
      this._wake();
    }
    pulse() {
      if (this.reduced) return;
      this.engine.kick.velocity = Math.min(36, this.engine.kick.velocity + 18);
      if (this.state === 'offen' || this.state === 'fehler') this.engine.expression = 0;
      this._wake();
    }
    destroy() {
      this._stop();
      this._theme.disconnect();
      if (this._io) this._io.disconnect();
      document.removeEventListener('visibilitychange', this._vis);
    }

    _setup() {
      const size = this.size, canvas = this.canvas;
      this.segments = size <= 32 ? 32 : 48;
      const segments = this.segments;
      this.geometry = ORBIT_RINGS.map((ring, strand) => ({ ...ring,
        points: Array.from({ length: segments }, (_, point) => {
          const angle = point / segments * TAU;
          const organic = kreisWobble(angle, strand, 0);
          const cosine = Math.cos(angle);
          const u = (cosine + 1) / 2;
          return { x: organic * cosine, y: organic * Math.sin(angle), angle, organic, cosine,
            envelope: Math.sin(Math.PI * u), end: Math.pow(Math.abs(u - 0.5) * 2, 3) };
        }),
      }));
      const dpr = Math.min(global.devicePixelRatio || 1, 2);
      canvas.width = size * dpr; canvas.height = size * dpr;
      canvas.style.width = size + 'px'; canvas.style.height = size + 'px';
      this.ctx = canvas.getContext('2d');
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const probe = document.createElement('canvas');
      probe.width = probe.height = 1;
      this.probe = probe.getContext('2d', { willReadFrequently: true });
      this._readColors();
      this.engine = {
        orientations: ORBIT_RINGS.map(() => createOrbitOrientation()),
        vertices: this.geometry.map((ring, index) => ring.points.map(point => {
          const radius = size * (KREIS_RADIUS - index * STRANG_ABSTAND);
          return { x: scalar(size / 2 + point.x * radius), y: scalar(size / 2 + point.y * radius),
            depth: scalar(0), width: scalar(kreisStrich(size) * this.options.stroke / 2) };
        })),
        color: this.colors.primary.map(scalar), kick: scalar(0), elapsed: 0, idle: 0, expression: 0,
      };
    }

    _readColors() {
      const style = getComputedStyle(this.canvas);
      const token = (name, fallback) => {
        const p = this.probe;
        p.clearRect(0, 0, 1, 1);
        p.fillStyle = fallback;
        p.fillStyle = style.getPropertyValue(name).trim() || fallback;
        p.fillRect(0, 0, 1, 1);
        return Array.from(p.getImageData(0, 0, 1, 1).data).slice(0, 3);
      };
      this.colors = {
        primary: token('--pippa-ink', '#005bcd'),
        success: token('--pippa-ink-offen', '#0d712c'),
        destructive: token('--pippa-ink-fehler', '#c4001d'),
      };
    }

    _paint(seconds, snap = false) {
      const { ctx, size, engine, geometry, segments, reduced, colors } = this;
      const options = this.options;
      const attenuation = Math.exp(-options.morph * seconds);
      const current = this.state;
      const working = current === 'arbeitet';
      const mouth = current === 'offen' || current === 'fehler';
      if (!reduced) engine.expression += seconds * 1000;
      if (working && !reduced) engine.elapsed += seconds * 1000 * options.speed;
      // Leises Leben im Ruhezustand: Wobble und Atem auf eigener Uhr.
      const living = current === 'ruht' && this.alive && !reduced;
      if (living) engine.idle += seconds * 1000 * this.idleSpeed;
      const breath = living ? 1 + 0.025 * this.idleAmplitude * Math.sin(engine.idle / 9000 * TAU) : 1;
      const targetInk = current === 'fehler' ? colors.destructive : current === 'offen' ? colors.success : colors.primary;
      let moving = advanceMorph(engine.kick, 0, seconds, snap || reduced, attenuation, options.morph);
      const body = expression(current, engine.expression, engine.idle, this.alive, reduced);
      const cosine = Math.cos(body.angle), sine = Math.sin(body.angle);
      const emphasis = 1 + .055 * Math.max(0, engine.kick.value);
      engine.color.forEach((ch, i) => { moving = advanceMorph(ch, targetInk[i], seconds, snap || reduced, attenuation, options.morph) || moving; });
      const ink = `rgb(${engine.color.map(ch => Math.round(ch.value)).join(' ')})`;
      ctx.clearRect(0, 0, size, size);
      ctx.fillStyle = ink;
      ctx.shadowColor = ink;
      const tubes = geometry.map((ring, strand) => {
        const time = reduced ? TURN_MS * 0.35 : engine.elapsed;
        const targetPose = working ? workingPose(time, strand) : IDLE_POSE;
        const orientation = advanceOrbitOrientation(engine.orientations[strand], targetPose, seconds, snap || reduced, options.morph);
        const pose = orientation.pose;
        moving = orientation.moving || moving;
        const radius = size * (KREIS_RADIUS - strand * STRANG_ABSTAND) * (1 + 0.04 * Math.max(0, engine.kick.value)) * breath;
        const vertices = engine.vertices[strand];
        const edges = ring.points.map((point, index) => {
          const live = living ? kreisWobble(point.angle, strand, engine.idle, 1, this.idleAmplitude) / point.organic : 1;
          const px = point.x * live, py = point.y * live;
          const depth = mouth ? 0 : px * pose.zx + py * pose.zy;
          const perspective = 1 + options.perspective * depth;
          const x = mouth ? size / 2 + size * KREIS_RADIUS * point.cosine
            : size / 2 + (px * pose.xx + py * pose.xy) * radius * perspective;
          const y = mouth ? size / 2 + (current === 'offen'
            ? (size * 0.1 + strand * size * 0.016) * point.envelope - size * 0.03 * point.end
            : -(size * 0.085 + strand * size * 0.014) * point.envelope + size * 0.06 * point.end)
            : size / 2 + (px * pose.yx + py * pose.yy) * radius * perspective;
          const width = (mouth ? Math.max(1.5, size * 0.058) * options.stroke : kreisStrich(size) * options.stroke * depthWidth(depth, options.depth)) / 2;
          const sx = (x - size / 2) * body.scaleX * emphasis;
          const sy = (y - size / 2) * body.scaleY * emphasis;
          const expressiveX = size / 2 + sx * cosine - sy * sine + size * body.x;
          const expressiveY = size / 2 + sx * sine + sy * cosine + size * body.y;
          const v = vertices[index];
          moving = advanceMorph(v.x, expressiveX, seconds, snap || reduced, attenuation, options.morph) || moving;
          moving = advanceMorph(v.y, expressiveY, seconds, snap || reduced, attenuation, options.morph) || moving;
          moving = advanceMorph(v.depth, depth, seconds, snap || reduced, attenuation, options.morph) || moving;
          moving = advanceMorph(v.width, width, seconds, snap || reduced, attenuation, options.morph) || moving;
          return { x: v.x.value, y: v.y.value, depth: v.depth.value, width: v.width.value };
        });
        return { edges, alpha: STRAENGE[strand].alpha };
      });
      // Erst die hinteren, dann die vorderen Teile jedes Rings.
      for (const front of [false, true]) {
        for (const tube of tubes) {
          ctx.globalAlpha = tube.alpha;
          // Kleine Marken bleiben scharf, ohne Leuchten.
          ctx.shadowBlur = size <= 32 ? 0 : kreisGlow(size, living ? engine.idle : engine.elapsed) * tube.alpha * options.glow;
          ctx.beginPath();
          for (let position = 0; position < segments; position += 1) {
            let from = tube.edges[position];
            let to = tube.edges[(position + 1) % segments];
            const a = front ? from.depth >= 0 : from.depth < 0;
            const b = front ? to.depth >= 0 : to.depth < 0;
            if (!a && !b) continue;
            let capEnd = false;
            if (a !== b) {
              const w = from.depth / (from.depth - to.depth);
              const crossing = { x: from.x + (to.x - from.x) * w, y: from.y + (to.y - from.y) * w, depth: 0, width: from.width + (to.width - from.width) * w };
              if (a) { to = crossing; capEnd = true; } else from = crossing;
            }
            const dx = to.x - from.x, dy = to.y - from.y;
            const length = Math.max(0.0001, Math.hypot(dx, dy));
            const nx = -dy / length, ny = dx / length;
            ctx.moveTo(from.x - nx * from.width, from.y - ny * from.width);
            ctx.lineTo(to.x - nx * to.width, to.y - ny * to.width);
            ctx.lineTo(to.x + nx * to.width, to.y + ny * to.width);
            ctx.lineTo(from.x + nx * from.width, from.y + ny * from.width);
            ctx.closePath();
            ctx.moveTo(from.x + from.width, from.y);
            ctx.arc(from.x, from.y, from.width, 0, TAU);
            ctx.closePath();
            if (capEnd) {
              ctx.moveTo(to.x + to.width, to.y);
              ctx.arc(to.x, to.y, to.width, 0, TAU);
              ctx.closePath();
            }
          }
          ctx.fill();
        }
      }
      if (current === 'ruht' && !moving) engine.elapsed = 0;
      ctx.globalAlpha = 1;
      ctx.shadowBlur = 0;
      this.moving = moving;
    }

    _draw(now) {
      if (!this.canvas.isConnected) { this.destroy(); return; }
      if (document.hidden || !this.visible) { this._stop(); return; }
      const delta = this.lastPaint === null ? 0 : now - this.lastPaint;
      if (this.lastPaint === null || now + 0.5 >= this.nextPaint) {
        this._paint(Math.min(delta / 1000, 0.1));
        this.nextPaint = this.lastPaint === null ? now + FRAME_MS
          : this.nextPaint + FRAME_MS * Math.max(1, Math.floor((now - this.nextPaint) / FRAME_MS) + 1);
        this.lastPaint = now;
      }
      if (this.reduced || !this._animates()) { this.frame = 0; this.lastPaint = null; return; }
      this.frame = requestAnimationFrame(t => this._draw(t));
    }
    _wake() {
      if (this.reduced) { this._paint(0, true); return; }
      this.moving = true;
      if (!document.hidden && this.visible && this.frame === 0) this.frame = requestAnimationFrame(t => this._draw(t));
    }
    _animates() { return this.state === 'arbeitet' || this.moving || this.alive; }
    _stop() { cancelAnimationFrame(this.frame); this.frame = 0; this.lastPaint = null; }
  }

  PippaMark.STATES = STATES;
  global.PippaMark = PippaMark;
})(typeof window !== 'undefined' ? window : globalThis);
