/**
 * PippaFilm: der kurze Film im Einstieg der Website. Ein Mac-Bildschirm, auf dem ein Zeiger Dinge
 * auf Pippas Pille legt; die Pille wird zur Karte, arbeitet sichtbar und zeigt das Ergebnis.
 * Läuft von selbst in drei Szenen, hält an, wenn der Film nicht zu sehen ist oder jemand Pause drückt.
 * Bei reduzierter Bewegung zeigt er nur das Ergebnis jeder Szene, ohne Zeiger und ohne Wechsel.
 */
(() => {
  'use strict';
  const wrap = document.querySelector('.film-wrap');
  const TEXT = {
    de: {
      menu: ['Finder', 'Ablage', 'Bearbeiten', 'Darstellung'], clock: 'Do. 18:12',
      brief: 'Brief Hausverwaltung.pdf', fotos: 'IMG_4821 und 2 weitere',
      hello: 'Leg was auf mich!', drop: 'Hier ablegen', release: 'Loslassen', what: 'Was soll ich damit machen?', done: 'Fertig',
      B: {
        chip: 'Brief · 2 Seiten', verbs: ['Was muss ich tun?', 'Frist eintragen', 'Antwort schreiben'], ask: 'Oder frag etwas zum Brief …',
        steps: [['Liest den Brief · Seite 1 von 2', .5], ['Liest den Brief · Seite 2 von 2', 1], ['Prüft Beträge und Daten', null]],
        label: 'bis 31. Okt. zahlen', h: 'Du sollst bis 31. Oktober 84,20 € nachzahlen.',
        p: 'Die Hausverwaltung rechnet die Nebenkosten 2025 ab.', beleg: 'Brief, S. 1',
        quote: '„Bitte überweisen Sie den Nachzahlungsbetrag von <mark>84,20 €</mark> bis zum <mark>31.10.2026</mark>.“',
        b2: 'Antwort schreiben', b1: 'Erinnerung eintragen', receipt: 'Erinnerung am 28. Okt. eingetragen'
      },
      F: {
        chip: '3 Fotos', verbs: ['Ein PDF daraus machen', 'Kleiner machen', 'Text herausholen'],
        steps: [['Macht ein PDF · Seite 1 von 3', 1 / 3], ['Macht ein PDF · Seite 2 von 3', 2 / 3], ['Macht ein PDF · Seite 3 von 3', 1], ['Erkennt den Text', null]],
        label: 'Mietvertrag.pdf', h: 'Dein PDF ist fertig.', file: 'Mietvertrag.pdf', meta: '3 Seiten · 1,2 MB · Text durchsuchbar',
        hint: 'Zieh es in Mail oder einen Ordner. Die Fotos bleiben, wie sie sind.', b2: 'Anders benennen', b1: 'Im Finder zeigen'
      },
      C: {
        from: 'Von: Lisa Moreau · Our visit in November',
        text: 'Hi! We’d love to stay with you from Nov 14 to 17. Would that work? We can bring the bikes and sort out dinner on Saturday.',
        copy: 'Kopieren', bubble: 'Auf Deutsch?', peek: 'Übersetzen?', yes: 'Ja', step: 'Übersetzt', label: 'übersetzt', h: 'Auf Deutsch:',
        out: 'Hallo! Wir würden gern vom 14. bis 17. November bei euch wohnen. Passt das? Wir bringen die Räder mit und kümmern uns am Samstag ums Abendessen.',
        b2: '14.–17. Nov. vormerken', b1: 'Kopieren', receipt: 'In der Zwischenablage'
      },
      pauseLabel: 'Pause', playLabel: 'Weiter'
    },
    en: {
      menu: ['Finder', 'File', 'Edit', 'View'], clock: 'Thu 6:12 PM',
      brief: 'Letter from landlord.pdf', fotos: 'IMG_4821 and 2 more',
      hello: 'Drop something on me!', drop: 'Drop here', release: 'Let go', what: 'What should I do with it?', done: 'Done',
      B: {
        chip: 'Letter · 2 pages', verbs: ['What do I need to do?', 'Add the deadline', 'Write a reply'], ask: 'Or ask something about the letter …',
        steps: [['Reading the letter · page 1 of 2', .5], ['Reading the letter · page 2 of 2', 1], ['Checking amounts and dates', null]],
        label: 'pay by Oct 31', h: 'You need to pay €84.20 by October 31.',
        p: 'Your landlord is settling the 2025 service charges.', beleg: 'Letter, p. 1',
        quote: '“Please transfer the outstanding amount of <mark>€84.20</mark> by <mark>31 Oct 2026</mark>.”',
        b2: 'Write a reply', b1: 'Add a reminder', receipt: 'Reminder added for Oct 28'
      },
      F: {
        chip: '3 photos', verbs: ['Make one PDF', 'Make them smaller', 'Pull out the text'],
        steps: [['Making a PDF · page 1 of 3', 1 / 3], ['Making a PDF · page 2 of 3', 2 / 3], ['Making a PDF · page 3 of 3', 1], ['Recognizing the text', null]],
        label: 'Lease.pdf', h: 'Your PDF is ready.', file: 'Lease.pdf', meta: '3 pages · 1.2 MB · searchable text',
        hint: 'Drag it into Mail or a folder. The photos stay as they are.', b2: 'Rename', b1: 'Show in Finder'
      },
      C: {
        from: 'From: Lisa Moreau · Besuch im November',
        text: 'Hallo! Wir würden gern vom 14. bis 17. November bei euch wohnen. Passt das? Wir bringen die Räder mit und kümmern uns am Samstag ums Abendessen.',
        copy: 'Copy', bubble: 'In English?', peek: 'Translate?', yes: 'Yes', step: 'Translating', label: 'translated', h: 'In English:',
        out: 'Hi! We’d love to stay with you from Nov 14 to 17. Does that work? We’ll bring the bikes and take care of dinner on Saturday.',
        b2: 'Save Nov 14–17', b1: 'Copy', receipt: 'Copied'
      },
      pauseLabel: 'Pause', playLabel: 'Play'
    }
  };
  const S = TEXT[document.documentElement.lang === 'en' ? 'en' : 'de'];
  if (!wrap) return;
  const fig = wrap.querySelector('.film'), view = fig.querySelector('.film-view');
  const RM = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = screen) => r.querySelector(s);
  const CANCEL = {}, STOP = {};

  const screen = document.createElement('div');
  screen.className = 'screen';
  view.appendChild(screen);
  screen.innerHTML =
    '<div class="fmb"><b>' + S.menu[0] + '</b>' + S.menu.slice(1).map(m => '<span>' + m + '</span>').join('') +
      '<i class="fmb-r"><canvas class="fmb-mk"></canvas>' + S.clock + '</i></div>' +
    '<div class="ic ic-b"><span class="fdoc"></span><span class="il">' + S.brief + '</span></div>' +
    '<div class="ic ic-f"><span class="photos"><i></i><i></i><i></i></span><span class="il">' + S.fotos + '</span></div>' +
    '<div class="mw"><div class="mw-bar"><i></i><i></i><i></i><b>Mail</b></div><div class="mw-body">' +
      '<p class="mw-from">' + S.C.from + '</p><p class="mw-text"><span class="sel">' + S.C.text + '</span></p>' +
      '<span class="fbtn mw-copy">' + S.C.copy + '</span></div></div>' +
    '<div class="dock">' + ['#5aa0f0', '#f2f2f2', '#ffcf4a', '#7ccf8a', '#f28b6e', '#b59cf0', '#3fb4c8'].map(c => '<i style="--c:' + c + '"></i>').join('') + '</div>' +
    '<div class="fbub"></div>' +
    '<div class="fp"><canvas class="fp-mk"></canvas><div class="fp-in"></div></div>' +
    '<div class="fp-measure"></div><div class="ghost"></div>' +
    '<div class="cur"><svg viewBox="0 0 22 22"><path d="M5 2.5v15.2l3.9-3.6 2.5 5.6 2.6-1.1-2.5-5.5h5.3z" fill="#fff" stroke="#000" stroke-width="1.3" stroke-linejoin="round"/></svg></div>';

  const fp = $('.fp'), inner = $('.fp-in'), meas = $('.fp-measure'), bub = $('.fbub'), cur = $('.cur'), ghost = $('.ghost'), sel = $('.sel');
  const mark = (c, size, alive) => window.PippaMark ? new PippaMark(c, { size, state: 'ruht', alive, idleSpeed: 1.3 }) : null;
  const pm = mark($('.fp-mk'), 34, true);
  mark($('.fmb-mk'), 16, false);
  const face = s => pm && pm.setState(s), pulse = () => pm && pm.pulse();

  /* Maße: breiter oder schmaler Bildschirm, als Ganzes skaliert */
  let W = 860, H = 540, narrow = false, k = 1;
  const layout = () => {
    const n = wrap.clientWidth < 560;
    const changed = n !== narrow;
    narrow = n; wrap.classList.toggle('n', n);
    W = n ? 400 : 860; H = n ? 560 : 540;
    k = view.clientWidth / W;
    screen.style.transform = 'scale(' + k + ')';
    return changed;
  };

  /* Zeit: anhaltbar und abbrechbar */
  let run = 0, userPause = false, offscreen = false;
  const paused = () => userPause || offscreen || document.hidden;
  const sleep = ms => new Promise((res, rej) => {
    const my = run;
    if (RM) return my === run ? res() : rej(CANCEL);
    let left = ms, last = performance.now();
    const step = () => {
      if (my !== run) return rej(CANCEL);
      const now = performance.now();
      if (!paused()) left -= now - last;
      last = now;
      if (left <= 0) res(); else setTimeout(step, Math.min(left, 120));
    };
    step();
  });
  // Ende einer Szene, wenn sie ihr Ergebnis zeigt. Bei reduzierter Bewegung bleibt der Film hier stehen.
  const hold = ms => RM ? Promise.reject(STOP) : sleep(ms);

  /* Pille: Inhalt messen, dann weich auf die neue Form wachsen */
  const Y0 = () => narrow ? 196 : 170;
  function show(html, o = {}) {
    const big = !!o.big;
    fp.className = 'fp' + (big ? ' big' : '') + (o.cls ? ' ' + o.cls : '');
    meas.className = 'fp-measure' + (big ? ' big' : '');
    const cw = Math.min(narrow ? W - 24 : 372, W - 24);
    meas.innerHTML = '<div class="fp-c"' + (big ? ' style="width:' + cw + 'px"' : '') + '>' + html + '</div>';
    const c = meas.firstElementChild, w = Math.min(c.offsetWidth, W - 24), h = c.offsetHeight;
    fp.style.width = w + 'px';
    fp.style.height = (big ? h : 52) + 'px';
    const y = big ? Math.max(38, Math.min(Y0() - 60, H - h - 14)) : Y0();
    fp.style.setProperty('--y', y + 'px');
    inner.innerHTML = c.outerHTML;
    if (big) inner.firstElementChild.style.width = w + 'px';
    meas.innerHTML = '';
  }
  const lab = (t, cls) => '<span class="lab' + (cls ? ' ' + cls : '') + '">' + t + '</span>';
  const ring = f => '<svg class="ring" viewBox="0 0 20 20"><circle class="rt" cx="10" cy="10" r="8"/><circle class="rp" cx="10" cy="10" r="8" stroke-dasharray="50.27" stroke-dashoffset="' + (50.27 * (1 - f)).toFixed(2) + '"/></svg>';
  const idle = () => { face('ruht'); show(lab('<span class="ft">Pippa</span>')); };
  const offer = (chip, verbs, ask) => {
    face('ruht'); pulse();
    show('<div class="fc-h">' + S.what + '</div><span class="fc-chip">' + chip + '</span>' +
      '<div class="fv">' + verbs.map((v, i) => '<span class="fbtn' + (i ? '' : ' pri') + '">' + v + '</span>').join('') + '</div>' +
      (ask ? '<div class="fask">' + ask + '</div>' : ''), { big: true });
  };
  async function work(steps) {
    face('arbeitet');
    for (const [t, f] of steps) { show(lab('<span class="shim">' + t + '</span>' + (f != null ? ring(f) : ''))); await sleep(1250); }
  }
  const finished = label => { face('offen'); pulse(); show(lab(S.done + ' <small>· ' + label + '</small>', 'ok')); };
  const receipt = t => '<div class="fdone"><span class="ck"></span><span>' + t + '</span></div>';

  /* Zeiger */
  let cx = 0, cy = 0;
  const at = el => {
    const s = view.getBoundingClientRect(), r = el.getBoundingClientRect();
    return [(r.left - s.left + r.width / 2) / k, (r.top - s.top + r.height / 2) / k];
  };
  const put = (el, x, y, ms) => { el.style.setProperty('--mv', ms + 'ms'); el.style.transform = 'translate(' + x + 'px,' + y + 'px)'; };
  async function move(x, y, ms, drag) {
    cx = x; cy = y;
    put(cur, x - 4, y - 2, ms);
    if (drag) put(ghost, x - 30, y - 30, ms);
    await sleep(ms + 40);
  }
  const to = (el, ms, dx = 0, dy = 0, drag) => { const [x, y] = at(el); return move(x + dx, y + dy, ms, drag); };
  async function click(el) {
    cur.classList.add('down'); el && el.classList.add('down');
    await sleep(160);
    cur.classList.remove('down'); el && el.classList.remove('down');
  }
  const rest = () => move(narrow ? W * .45 : W * .52, narrow ? H * .62 : H * .78, 900);

  /* Ziehen vom Schreibtisch */
  async function dragIn(icon) {
    await to(icon, 900, 0, -8);
    await click();
    ghost.innerHTML = icon.firstElementChild.outerHTML;
    ghost.classList.remove('sink');
    put(ghost, cx - 30, cy - 30, 0);
    ghost.classList.add('on'); icon.classList.add('dim');
    show(lab(S.drop), { cls: 'target' });
    await sleep(250);
    const [px, py] = at(fp);
    await move(px - 12, py + 4, 1150, true);
    show(lab(S.release, 'hl'), { cls: 'hot' });
    await sleep(420);
    ghost.classList.add('sink');
    await sleep(220);
    ghost.classList.remove('on');
  }

  /* Die drei Szenen */
  async function brief() {
    const icon = $('.ic-b');
    await dragIn(icon);
    offer('<span class="fdoc"></span>' + S.B.chip, S.B.verbs, S.B.ask);
    await sleep(1000);
    await to($('.fv .fbtn', inner), 700, -40); await click($('.fv .fbtn', inner));
    rest();
    await work(S.B.steps);
    finished(S.B.label);
    await sleep(1200);
    await to(fp, 800); await click();
    face('offen');
    const res = (quote, done) => show('<div class="fc-h">' + S.B.h + '</div><p class="fp-p">' + S.B.p + ' <span class="beleg">' + S.B.beleg + '</span></p>' +
      (quote ? '<blockquote class="fquote">' + S.B.quote + '</blockquote>' : '') +
      (done ? receipt(S.B.receipt) : '<div class="fr"><span class="fbtn">' + S.B.b2 + '</span><span class="fbtn pri">' + S.B.b1 + '</span></div>'), { big: true });
    res(RM, false);
    await sleep(1300);
    await to($('.beleg', inner), 700); await click($('.beleg', inner));
    res(true, false);
    await hold(1900);
    await to($('.fr .pri', inner), 800); await click($('.fr .pri', inner));
    res(true, true); pulse();
    await sleep(2600);
    icon.classList.remove('dim');
  }
  async function fotos() {
    const icon = $('.ic-f');
    await dragIn(icon);
    offer('<span class="photos"><i></i><i></i><i></i></span>' + S.F.chip, S.F.verbs);
    await sleep(1000);
    await to($('.fv .fbtn', inner), 700, -40); await click($('.fv .fbtn', inner));
    rest();
    await work(S.F.steps);
    finished(S.F.label);
    await sleep(1200);
    await to(fp, 800); await click();
    show('<div class="fc-h">' + S.F.h + '</div><div class="ffile"><span class="fdoc"></span><span><b>' + S.F.file + '</b><small>' + S.F.meta + '</small></span></div>' +
      '<p class="fp-p">' + S.F.hint + '</p><div class="fr"><span class="fbtn">' + S.F.b2 + '</span><span class="fbtn pri">' + S.F.b1 + '</span></div>', { big: true });
    await hold(3200);
    icon.classList.remove('dim');
  }
  async function copy() {
    const btn = $('.mw-copy');
    const res = done => show('<div class="fc-h">' + S.C.h + '</div><div class="fout">' + S.C.out + '</div>' +
      (done ? receipt(S.C.receipt) : '<div class="fr"><span class="fbtn">' + S.C.b2 + '</span><span class="fbtn pri">' + S.C.b1 + '</span></div>'), { big: true });
    if (RM) { sel.classList.add('on'); face('offen'); res(false); return hold(0); }
    const t = $('.mw-text');
    const [tx, ty] = at(t), tw = t.offsetWidth, th = t.offsetHeight;
    await move(tx - tw / 2, ty - th / 2 + 8, 900);
    await click();
    sel.classList.add('on');
    await move(tx + tw / 2 - 30, ty + th / 2 - 8, 800);
    await to(btn, 600); await click(btn);
    bub.textContent = S.C.bubble;
    show(lab(S.C.peek + ' <span class="fbtn sm pri">' + S.C.yes + '</span><span class="fbtn sm">×</span>'), { cls: 'ask' });
    pulse();
    bub.style.top = (Y0() - 54) + 'px'; bub.classList.add('on');
    await sleep(1400);
    await to($('.fbtn.pri', inner), 800); await click($('.fbtn.pri', inner));
    bub.classList.remove('on');
    rest();
    await work([[S.C.step, null], [S.C.step, null]]);
    finished(S.C.label);
    await sleep(1100);
    await to(fp, 800); await click();
    face('offen'); res(false);
    await hold(1800);
    await to($('.fr .pri', inner), 800); await click($('.fr .pri', inner));
    res(true); pulse();
    await sleep(2400);
    sel.classList.remove('on');
  }
  const SCENES = [brief, fotos, copy];

  /* Ablauf */
  const chips = [...wrap.querySelectorAll('[data-scene]')], pauseBtn = wrap.querySelector('.film-pause');
  const current = i => chips.forEach((c, j) => c.setAttribute('aria-current', String(i === j)));
  function reset() {
    bub.classList.remove('on'); sel.classList.remove('on'); ghost.classList.remove('on');
    screen.querySelectorAll('.dim').forEach(e => e.classList.remove('dim'));
    idle();
  }
  async function play(i, first) {
    const my = ++run;
    reset();
    if (!RM) {
      cur.classList.add('on');
      if (first) {
        put(cur, W * .55, H * .8, 0);
        bub.textContent = S.hello; bub.style.top = (Y0() - 54) + 'px';
        try { await sleep(700); bub.classList.add('on'); pulse(); await sleep(2000); bub.classList.remove('on'); await sleep(300); }
        catch (e) { return; }
      }
    }
    for (;;) {
      if (my !== run) return;
      current(i);
      try { await SCENES[i](); }
      catch (e) { if (e === STOP) return; if (e === CANCEL) return; throw e; }
      if (my !== run) return;
      reset();
      try { await sleep(700); } catch (e) { return; }
      i = (i + 1) % SCENES.length;
    }
  }
  chips.forEach((c, i) => c.addEventListener('click', () => play(i)));
  pauseBtn.addEventListener('click', () => {
    userPause = !userPause;
    pauseBtn.setAttribute('aria-pressed', String(userPause));
    pauseBtn.textContent = userPause ? S.playLabel : S.pauseLabel;
  });
  if (RM) pauseBtn.hidden = true;
  if ('IntersectionObserver' in window) new IntersectionObserver(es => { offscreen = !es[0].isIntersecting; }, { threshold: .2 }).observe(fig);

  layout();
  let rt;
  new ResizeObserver(() => { clearTimeout(rt); rt = setTimeout(() => { if (layout()) play(Math.max(0, chips.findIndex(c => c.getAttribute('aria-current') === 'true'))); }, 80); }).observe(wrap);
  play(0, true);
})();
