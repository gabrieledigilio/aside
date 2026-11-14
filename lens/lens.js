// Gist lens: draws the brain's state on the 600x600 display, and wires up whichever host it runs in.
//
//   live    served by the Mac brain; long-polls it for state            (glasses Web App, desktop preview)
//   native  inside the iPhone app's web view; the brain runs in this page and the app photographs each frame
//   relay   inside the iPhone app, but the brain is the Mac's (?relay): the phone only lends its ears
//   show    ?show=<name> draws one built-in sample state, for looking at a single scene
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var root = $('root');
  var qs = new URLSearchParams(location.search);
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gist;
  var HOSTED = !!bridge;                                   // inside the iPhone app, whichever brain is used
  var NATIVE = (HOSTED || qs.has('native')) && !qs.has('relay');
  var SHOW = qs.get('show');
  var STILL = HOSTED || NATIVE || qs.has('still');
  var LINK = qs.get('k') || '';                            // link code: the Mac brain asks for it when reached from outside
  if (STILL) root.classList.add('still');

  var SVG = 'http://www.w3.org/2000/svg';
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function S(tag, attrs, text) {
    var e = document.createElementNS(SVG, tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    return e;
  }
  function setText(node, text) {
    if (node.textContent === text) return false;
    node.textContent = text;
    if (!STILL) { node.classList.remove('swap'); void node.offsetWidth; node.classList.add('swap'); }
    return true;
  }
  // Step the font size down until the text fits the box.
  function fit(node, sizes, maxHeight) {
    for (var i = 0; i < sizes.length; i++) {
      node.style.fontSize = sizes[i][0] + 'px';
      node.style.lineHeight = sizes[i][1] + 'px';
      if (node.scrollHeight <= maxHeight + 1) return;
    }
  }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  // ---------- scenes ----------
  var stage = $('stage');
  var lastSceneSig = '';
  var knownNodes = {};

  // Does the straight line from a to b run through the box (grown by pad)?
  function lineHitsBox(ax, ay, bx, by, box, pad) {
    var x0 = box.cx - box.w / 2 - pad, x1 = box.cx + box.w / 2 + pad, y0 = box.cy - box.h / 2 - pad, y1 = box.cy + box.h / 2 + pad;
    var t0 = 0, t1 = 1, dx = bx - ax, dy = by - ay;
    var p = [-dx, dx, -dy, dy], q = [ax - x0, x1 - ax, ay - y0, y1 - ay];
    for (var i = 0; i < 4; i++) {
      if (p[i] === 0) { if (q[i] < 0) return false; continue; }
      var r = q[i] / p[i];
      if (p[i] < 0) { if (r > t1) return false; if (r > t0) t0 = r; }
      else { if (r < t0) return false; if (r < t1) t1 = r; }
    }
    return true;
  }

  // How many wires would run through a box that is at neither of their ends. Box sizes are guessed from the labels.
  function tangles(nodes, edges, pos) {
    var boxes = {};
    nodes.forEach(function (nd) {
      var p = pos[nd.id], maxW = Math.max(110, p.maxW), need = 34 + 12 * String(nd.label).length;
      boxes[nd.id] = { cx: p.cx, cy: p.cy, w: Math.min(maxW, need), h: 22 + 26 * Math.min(3, Math.ceil(need / maxW)) };
    });
    var count = 0;
    edges.forEach(function (e) {
      var a = boxes[e.from], b = boxes[e.to];
      if (!a || !b) return;
      nodes.forEach(function (nd) {
        if (nd.id !== e.from && nd.id !== e.to && lineHitsBox(a.cx, a.cy, b.cx, b.cy, boxes[nd.id], 4)) count++;
      });
    });
    return count;
  }

  // Three or four boxes toward the corners of the stage, in the order given: across, down, back.
  // No wire between two of them can pass through a third.
  function cornerLayout(order, W, H) {
    var spots = order.length === 3 ? [[0.22, 0.24], [0.78, 0.24], [0.5, 0.78]] : [[0.25, 0.25], [0.75, 0.25], [0.75, 0.75], [0.25, 0.75]];
    var pos = {};
    order.forEach(function (nd, i) { var at = spots[i % spots.length]; pos[nd.id] = { cx: W * at[0], cy: H * at[1], maxW: W / 2 - 40 }; });
    return pos;
  }

  // Left-to-right layers by longest path. With no edges the nodes simply sit side by side.
  function layerLayout(nodes, edges, W, H) {
    var layer = {}, n = nodes.length;
    nodes.forEach(function (nd) { layer[nd.id] = 0; });
    for (var i = 0; i < n; i++) {
      edges.forEach(function (e) {
        var next = layer[e.from] + 1;
        if (layer[e.to] < next && next < n) layer[e.to] = next;
      });
    }
    if (!edges.length) nodes.forEach(function (nd, i) { layer[nd.id] = i; });
    var used = Array.from(new Set(nodes.map(function (nd) { return layer[nd.id]; }))).sort(function (a, b) { return a - b; });
    var pos = {};
    var order = nodes.slice().sort(function (a, b) { return layer[a.id] - layer[b.id]; });
    // A chain of four would be four cramped columns. Fold it into two rows: across, down, back.
    if (used.length >= 4) return cornerLayout(order.slice(0, 4), W, H);
    used.forEach(function (L, ci) {
      var col = nodes.filter(function (nd) { return layer[nd.id] === L; });
      col.forEach(function (nd, ri) {
        pos[nd.id] = { cx: W * (ci + 0.5) / used.length, cy: H * (ri + 1) / (col.length + 1), maxW: Math.min(230, W / used.length - 30) };
      });
    });
    // A wire that skips a column can run straight through the box in between. The corners never have that.
    if ((n === 3 || n === 4) && tangles(nodes, edges, pos) > 0) return cornerLayout(order, W, H);
    return pos;
  }

  // A loop: top row left to right, bottom row right to left, so following the arrows goes round.
  function ringLayout(nodes, W, H) {
    var n = nodes.length, top = Math.ceil(n / 2), bottom = n - top, pos = {};
    nodes.forEach(function (nd, i) {
      if (i < top) pos[nd.id] = { cx: W * (i + 0.5) / top, cy: H * 0.2, maxW: W / top - 34 };
      else { var j = i - top; pos[nd.id] = { cx: W * (1 - (j + 0.5) / bottom), cy: H * 0.8, maxW: W / Math.max(bottom, 1) - 34 }; }
    });
    return pos;
  }

  // The point where the line from a box's centre toward (tx, ty) leaves the box.
  function edgePoint(box, tx, ty, pad) {
    var dx = tx - box.cx, dy = ty - box.cy;
    if (!dx && !dy) return { x: box.cx, y: box.cy };
    var hw = box.w / 2 + pad, hh = box.h / 2 + pad;
    var s = Math.min(dx ? hw / Math.abs(dx) : Infinity, dy ? hh / Math.abs(dy) : Infinity);
    return { x: box.cx + dx * s, y: box.cy + dy * s };
  }

  function drawGraph(scene, isLoop) {
    var W = stage.clientWidth, H = stage.clientHeight;
    stage.textContent = '';
    var svg = S('svg', { class: 'wires', viewBox: '0 0 ' + W + ' ' + H, width: W, height: H });
    var defs = S('defs', {});
    var marker = S('marker', { id: 'arrow', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 8, markerHeight: 8, orient: 'auto-start-reverse' });
    marker.appendChild(S('path', { d: 'M0 0L10 5L0 10z', class: 'arrow' }));
    defs.appendChild(marker); svg.appendChild(defs);
    stage.appendChild(svg);

    var nodes = scene.nodes;
    var edges = isLoop
      ? nodes.map(function (nd, i) { return { from: nd.id, to: nodes[(i + 1) % nodes.length].id, label: '' }; })
      : scene.edges || [];
    var pos = isLoop ? ringLayout(nodes, W, H) : layerLayout(nodes, edges, W, H);

    if (isLoop) {
      svg.appendChild(S('rect', { class: 'orbit', x: W * 0.12, y: H * 0.2, width: W * 0.76, height: H * 0.6, rx: H * 0.3 }));
      // The hub in the middle turns: the one continuous motion on the lens, small and cheap.
      svg.appendChild(S('path', { class: 'hub', d: 'M' + (W / 2 - 13) + ' ' + (H / 2) + 'a13 13 0 0 1 22 -9M' + (W / 2 + 13) + ' ' + (H / 2) + 'a13 13 0 0 1 -22 9' }));
    }

    var boxes = {}, els = {};
    var tight = !isLoop && Object.keys(pos).some(function (id) { return pos[id].maxW < 160; });
    nodes.forEach(function (nd) {
      var d = el('div', 'node' + (tight ? ' tight' : '') + (knownNodes[nd.id] ? '' : ' enter'), nd.label);
      d.style.maxWidth = Math.max(110, pos[nd.id].maxW) + 'px';
      stage.appendChild(d); els[nd.id] = d;
      // A long single word must shrink rather than break in the middle.
      var size = parseFloat(getComputedStyle(d).fontSize);
      while (d.scrollWidth > d.clientWidth + 1 && size > 18) { size -= 1; d.style.fontSize = size + 'px'; d.style.lineHeight = size + 4 + 'px'; }
      if (d.scrollWidth > d.clientWidth + 1) d.style.overflowWrap = 'anywhere';
    });
    nodes.forEach(function (nd) {
      var d = els[nd.id], w = Math.ceil(d.offsetWidth), h = Math.ceil(d.offsetHeight), p = pos[nd.id];
      var x = clamp(Math.round(p.cx - w / 2), 1, W - w - 1), y = clamp(Math.round(p.cy - h / 2), 1, H - h - 1);
      d.style.left = x + 'px'; d.style.top = y + 'px';
      boxes[nd.id] = { x: x, y: y, w: w, h: h, cx: x + w / 2, cy: y + h / 2 };
      var c = 9;   // chamfered corners, top-left and bottom-right
      svg.appendChild(S('polygon', {
        class: 'plate' + (knownNodes[nd.id] ? '' : ' enter'),
        points: [x + c, y, x + w, y, x + w, y + h - c, x + w - c, y + h, x, y + h, x, y + c].join(' '),
      }));
    });
    edges.forEach(function (e) {
      var a = boxes[e.from], b = boxes[e.to];
      if (!a || !b) return;
      var p1 = edgePoint(a, b.cx, b.cy, 3), p2 = edgePoint(b, a.cx, a.cy, 8);
      var len = Math.hypot(p2.x - p1.x, p2.y - p1.y);
      if (len < 10) return;
      svg.appendChild(S('path', { class: 'wire enter', d: 'M' + p1.x + ' ' + p1.y + 'L' + p2.x + ' ' + p2.y, pathLength: 1, 'marker-end': 'url(#arrow)' }));
      if (e.label && len >= 100) {
        var nx = -(p2.y - p1.y) / len, ny = (p2.x - p1.x) / len;
        if (ny > 0) { nx = -nx; ny = -ny; }                    // always on the upper side of the trace
        svg.appendChild(S('text', { class: 'wire-label', x: (p1.x + p2.x) / 2 + nx * 12, y: (p1.y + p2.y) / 2 + ny * 12 }, e.label));
      }
    });
    knownNodes = {};
    nodes.forEach(function (nd) { knownNodes[nd.id] = true; });
  }

  function drawSteps(scene) {
    var ol = el('ol', 'steps');
    scene.steps.forEach(function (text, i) {
      var li = el('li', i < scene.current ? 'done' : i === scene.current ? 'now' : '');
      li.appendChild(el('span', 'mark', i < scene.current ? '✓' : String(i + 1)));
      li.appendChild(el('span', '', text));
      ol.appendChild(li);
    });
    stage.replaceChildren(ol);
  }

  function drawCompare(scene) {
    var wrap = el('div', 'compare');
    [['left', scene.left], ['right', scene.right]].forEach(function (pair, i) {
      var side = el('div', 'side ' + pair[0]);
      side.appendChild(el('h2', '', pair[1].title));
      var ul = el('ul');
      pair[1].points.forEach(function (p) { ul.appendChild(el('li', '', p)); });
      side.appendChild(ul);
      wrap.appendChild(side);
      if (i === 0) wrap.appendChild(el('div', 'spine'));
    });
    stage.replaceChildren(wrap);
  }

  function drawStats(scene) {
    var wrap = el('div', 'stats' + (scene.stats.length <= 2 ? ' few' : ''));
    scene.stats.forEach(function (st) {
      var cell = el('div', 'stat');
      cell.appendChild(el('div', 'value', st.value));
      var pct = /^(\d+(?:[.,]\d+)?)%$/.exec(st.value);
      var g = el('div', 'gauge' + (pct ? '' : ' none'));        // a percentage gets a bar that shows how much it is
      if (pct) { var fill = el('i'); fill.style.width = clamp(parseFloat(pct[1].replace(',', '.')), 2, 100) + '%'; g.appendChild(fill); }
      cell.appendChild(g);
      cell.appendChild(el('div', 'label', st.label));
      wrap.appendChild(cell);
    });
    stage.replaceChildren(wrap);
    // Long values ("€1,200") must not push into the next cell.
    Array.prototype.forEach.call(wrap.querySelectorAll('.value'), function (v) {
      var size = parseFloat(getComputedStyle(v).fontSize);
      while (v.scrollWidth > v.parentNode.clientWidth - 16 && size > 34) { size -= 4; v.style.fontSize = size + 'px'; v.style.lineHeight = size + 4 + 'px'; }
    });
  }

  function drawPoints(scene) {
    var ul = el('ul', 'points');
    scene.points.forEach(function (p) { ul.appendChild(el('li', STILL ? '' : 'enter-row', p)); });
    stage.replaceChildren(ul);
  }

  var lastSceneKind = '';
  function drawScene(scene) {
    var sig = JSON.stringify(scene || null);
    if (sig === lastSceneSig) return;
    lastSceneSig = sig;
    var kind = scene ? scene.kind : '';
    if (kind !== lastSceneKind) knownNodes = {};          // a different kind of picture: everything in it is new
    lastSceneKind = kind;
    if (!scene) {
      stage.replaceChildren(el('div', 'hint', 'Working out the shape of this'));
      $('sceneTitle').textContent = '';
      return;
    }
    $('sceneTitle').textContent = scene.title || { map: 'How it connects', loop: 'The loop', steps: 'The steps', compare: 'Two sides', stats: 'The numbers', points: 'Key points' }[scene.kind] || '';
    if (scene.kind === 'map') drawGraph(scene, false);
    else if (scene.kind === 'loop') drawGraph(scene, true);
    else if (scene.kind === 'steps') drawSteps(scene);
    else if (scene.kind === 'compare') drawCompare(scene);
    else if (scene.kind === 'stats') drawStats(scene);
    else drawPoints(scene);
  }

  // ---------- sheets: standing by, up next, recap ----------
  var sheet = $('sheet');
  function rows(items, cls) {
    var ul = el('ul', 'rows' + (cls ? ' ' + cls : ''));
    items.forEach(function (t) { ul.appendChild(el('li', '', t)); });
    return ul;
  }
  function hhmm(d) { return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); }
  function inMin(m) { return m <= 0 ? 'now' : m < 60 ? 'in ' + m + ' min' : 'in ' + Math.round(m / 60) + ' h'; }

  function drawStandby(s) {
    var box = el('div', 'sheet standby');
    box.appendChild(el('div', 'time', hhmm(new Date())));
    // Inside the iPhone app this frame goes to the glasses, where a pinch of the band opens the menu.
    var earsOff = HOSTED && s.host && s.host.ears === 'none';
    box.appendChild(el('p', 'lead', earsOff ? 'Not listening yet.' : s.listening ? 'Ready. I’ll follow when someone starts explaining.' : 'Paused. Nothing is being heard.'));
    // With the app's buttons under the lens on the glasses there is nothing to explain.
    if (HOSTED && !(s.host && s.host.buttons)) box.appendChild(el('p', 'hint', earsOff ? 'Pinch, then choose Listen' : 'Pinch for the menu'));
    if (s.next) {
      var p = el('p', 'next');
      p.appendChild(el('b', '', s.next.at));
      p.appendChild(el('i', '', inMin(s.next.inMin)));
      p.appendChild(el('span', '', s.next.title));
      box.appendChild(p);
    }
    if (s.open && s.open.length) {
      box.appendChild(el('span', 'tag quiet', 'Still open'));
      box.appendChild(rows(s.open.slice(0, 2), 'todo'));
    }
    sheet.replaceChildren(box);
  }

  function drawBrief(s) {
    var b = s.brief || {}, box = el('div', 'sheet');
    box.appendChild(el('span', 'tag', 'Up next'));
    box.appendChild(el('h1', '', b.title || ''));
    box.appendChild(el('p', 'meta', [b.at, inMin(b.inMin), b.where].filter(Boolean).join(' · ')));
    if (b.prep && b.prep.length) { box.appendChild(el('span', 'tag quiet', 'Go in knowing')); box.appendChild(rows(b.prep)); }
    else box.appendChild(el('p', 'waiting', s.thinking ? 'Preparing your brief' : ''));
    if (s.open && s.open.length) box.appendChild(el('p', 'open', 'Still open: ' + s.open[0]));
    sheet.replaceChildren(box);
  }

  function drawRecap(s) {
    var r = s.recap, box = el('div', 'sheet');
    box.appendChild(el('span', 'tag', 'Recap'));
    if (!r) {
      box.appendChild(el('h1', '', s.headline || 'That conversation'));
      box.appendChild(el('p', 'waiting', 'Writing down what matters'));
    } else {
      box.appendChild(el('h1', '', r.title));
      if (r.points.length) box.appendChild(rows(r.points));
      if (r.actions.length) { box.appendChild(el('span', 'tag quiet', 'For you')); box.appendChild(rows(r.actions, 'todo')); }
      if (r.open) box.appendChild(el('p', 'open', 'Unanswered: ' + r.open));
    }
    box.appendChild(el('p', 'foot', 'No audio was stored. Only this note is kept.'));
    sheet.replaceChildren(box);
    var h = box.querySelector('h1');
    if (h) fit(h, [[34, 40], [30, 36], [26, 32]], 80);
  }

  // ---------- the whole frame ----------
  var EARS = { glasses: 'Glasses mic', speech: 'Glasses speech', hfp: 'Glasses mic', phone: 'Phone mic', mac: 'This Mac’s mic', replay: 'Sample replay' };
  var current = null, offline = false, lastFrameSig = '';

  function render(s) {
    current = s;
    var view = s.phase === 'live' ? (s.turn ? 'turn' : 'live') : s.phase;
    root.dataset.view = view;
    root.classList.toggle('paused', !s.listening);
    root.classList.toggle('thinking', !!s.thinking);

    $('stateText').textContent = offline ? 'Reconnecting' : !s.listening ? 'Paused' :
      view === 'live' ? 'Listening' : view === 'turn' ? 'Your turn' : view === 'recap' ? 'Conversation ended' : view === 'brief' ? 'Your day' : 'Standing by';
    // With the buttons tucked away during a conversation, the strip says how to get them.
    var pinchHint = HOSTED && s.host && s.host.pinch && s.phase === 'live';
    $('ears').textContent = pinchHint ? 'Pinch for controls' : (s.host && EARS[s.host.ears] ? EARS[s.host.ears] : '');
    $('pause').textContent = s.listening ? 'Pause' : 'Resume';
    tickClock();

    if (view === 'live') {
      var h = $('headline');
      h.classList.toggle('empty', !s.headline);
      if (setText(h, s.headline || 'Listening for the point')) { if (s.headline) fit(h, [[38, 42], [33, 38], [28, 28]], 84); else { h.style.fontSize = ''; h.style.lineHeight = ''; } }
      drawScene(s.scene);
      var t = $('term');
      var chip = s.notice && s.notice.kind === 'seen' ? ['Seen', s.notice.text] : s.term ? [s.term.word, s.term.means] : null;
      var chipSig = chip ? chip.join('|') : '';
      if (t.dataset.sig !== chipSig) {          // only rebuilt when it changes, so it is not repainted on every tick
        t.dataset.sig = chipSig;
        t.replaceChildren();
        t.classList.remove('small');
        if (chip) {
          t.appendChild(el('b', '', chip[0]));
          var meaning = el('span', '', chip[1]);
          t.appendChild(meaning);
          // A long meaning steps down in size before it is cut off.
          if (meaning.scrollWidth > meaning.clientWidth + 1) t.classList.add('small');
        }
      }
      $('ask').classList.toggle('empty', !s.ask);
      // With the wearer doing the explaining, the question is the one to expect from the listener.
      var askTag = $('ask').querySelector('.tag');
      if (askTag) setText(askTag, s.ask && s.askFor === 'me' ? 'Expect' : 'Ask');
      var a = $('askText');
      if (setText(a, s.ask || 'A question to ask will appear here')) { if (s.ask) fit(a, [[28, 34], [25, 30], [22, 27]], 68); else { a.style.fontSize = ''; a.style.lineHeight = ''; } }
    } else if (view === 'turn') {
      var q = $('asked');
      if (setText(q, s.turn.asked)) fit(q, [[34, 40], [30, 36], [26, 32]], 120);
      // Asked about their own subject, the wearer sees what they already said about it.
      var rt = $('repliesTag');
      if (rt) setText(rt, !s.turn.replies.length ? '' : s.turn.kind === 'recall' ? 'You already said' : 'You could say');
      var ol = $('replies');
      var sig = s.turn.replies.join('|');
      if (ol.dataset.sig !== sig) {
        ol.dataset.sig = sig; ol.replaceChildren();
        s.turn.replies.forEach(function (r, i) {
          var li = el('li', STILL ? '' : 'enter-row');
          li.appendChild(el('span', 'n', String(i + 1))); li.appendChild(el('span', '', r));
          ol.appendChild(li);
        });
      }
      lastSceneSig = ''; lastSceneKind = '';       // the stage is redrawn when the conversation comes back
    } else {
      lastSceneSig = ''; lastSceneKind = '';
      if (view === 'standby') drawStandby(s); else if (view === 'brief') drawBrief(s); else drawRecap(s);
    }

    // Short notices ride in the status strip; nothing ever covers the question.
    var note = s.notice && s.notice.kind !== 'seen' ? s.notice.text : '';
    var n = $('notice');
    n.textContent = note;
    n.className = note ? 'on' : '';

    if (HOSTED || NATIVE) announceFrame(s, view);
  }

  // Elapsed time in the status strip. Not shown on still frames, where nothing can tick.
  function tickClock() {
    var s = current, c = $('clock');
    if (!s || STILL || !s.startedAt || (s.phase !== 'live')) { c.textContent = ''; return; }
    var sec = Math.max(0, Math.floor((Date.now() - s.startedAt) / 1000));
    c.textContent = String(Math.floor(sec / 60)).padStart(2, '0') + ':' + String(sec % 60).padStart(2, '0');
  }

  // ---------- host: native (the iPhone app) ----------
  function post(msg) { try { if (bridge) bridge.postMessage(msg); } catch (e) { /* not in the app */ } }

  function announceFrame(s, view) {
    // Tell the app a new frame is ready to photograph, but only when what is drawn actually changed.
    var sig = view + '|' + s.listening + '|' + s.thinking + '|' + root.innerText + '|' + JSON.stringify(s.scene || null);
    if (sig === lastFrameSig) return;
    lastFrameSig = sig;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        post({ type: 'frame', v: s.v, view: view });
        post({
          type: 'state', phase: s.phase, view: view, listening: s.listening, thinking: s.thinking,
          headline: s.headline, ask: s.ask, plain: GistCore.plain(s),
          next: s.next ? s.next.at + '  ' + s.next.title : '',
          error: s.perf.lastErrorAt && Date.now() - s.perf.lastErrorAt < 20000 ? s.perf.lastError : '', fastMs: s.perf.fastMs.slice(-1)[0] || 0, deepMs: s.perf.deepMs.slice(-1)[0] || 0,
        });
      });
    });
  }

  function startNative() {
    var pending = {}, seq = 0;
    // The app answers model requests here: it holds the API key, this page never sees it.
    window.__gistNet = function (id, status, text) {
      var done = pending[id];
      if (done) { delete pending[id]; done({ status: status, text: text }); }
    };
    function send(body) {
      if (!bridge) {                                           // ?native in a desktop browser: go through the Mac brain instead
        return fetch(linked('model'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then(function (r) { return r.json(); });
      }
      return new Promise(function (resolve) {
        var id = ++seq;
        pending[id] = resolve;
        post({ type: 'net', id: id, body: JSON.stringify(body) });
        setTimeout(function () { if (pending[id]) { delete pending[id]; resolve({ status: 0, text: 'The phone did not answer in time' }); } }, 45000);
      });
    }
    var core = GistCore.create({
      send: send,
      onChange: function (s) { render(s); },
      requestLook: function (why) { post({ type: 'look', reason: why }); },
      onMemory: function (m) {
        try { localStorage.setItem('gist.memory', JSON.stringify(m)); } catch (e) { /* storage can be unavailable */ }
        post({ type: 'memory', items: m });
      },
    });
    try { core.loadMemory(JSON.parse(localStorage.getItem('gist.memory') || '[]')); } catch (e) { /* nothing saved yet */ }
    window.GistNative = {
      heard: function (text, who, number) { core.heard(text, who, number); },
      relabel: function (labels) { core.relabel(labels); },
      look: function (jpegBase64, quiet) { core.look(jpegBase64, !!quiet); },
      lookSoon: function () { core.lookSoon(); },
      tell: function (text, ms) { core.tell(text, ms); },
      setListening: function (on) { core.setListening(on); },
      end: function () { core.end(); },
      setDay: function (events) { core.setDay(events); },
      briefNow: function () { return core.briefNow(); },
      setHost: function (info) { core.setHost(info); },
      configure: function (models) { core.setModels(models); },
      forget: function () { core.forget(); },
      planDay: function () { core.planDay(function (list) { post({ type: 'plan', events: list }); }); },
      state: function () { return core.state(); },
      redraw: function () { lastFrameSig = ''; render(core.state()); },
      // For test runs: the memory is put aside first and brought back afterwards, so sample
      // conversations never push the wearer's own recaps out.
      stash: function () {
        try { if (localStorage.getItem('gist.memory.stash') === null) localStorage.setItem('gist.memory.stash', JSON.stringify(core.memory())); } catch (e) { /* storage can be unavailable */ }
      },
      unstash: function () {
        try {
          var kept = localStorage.getItem('gist.memory.stash');
          if (kept === null) return;
          core.loadMemory(JSON.parse(kept));
          localStorage.setItem('gist.memory', JSON.stringify(core.memory()));
          localStorage.removeItem('gist.memory.stash');
          post({ type: 'memory', items: core.memory() });
        } catch (e) { /* storage can be unavailable */ }
      },
    };
    setInterval(function () {
      core.tick();
      // The standby clock is part of the picture, so a new minute is a new frame for the glasses.
      if (current && current.phase === 'standby') {
        var minute = hhmm(new Date());
        if (minute !== lastMinute) { lastMinute = minute; lastFrameSig = ''; render(core.state()); }
      }
    }, 1000);
    var ready = function () {
      render(core.state());
      post({ type: 'ready', core: GistCore.VERSION, brain: 'phone' });
      post({ type: 'memory', items: core.memory() });
    };
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(ready); else ready();
  }

  // ---------- host: live (served by the Mac brain) ----------
  function linked(path) { return LINK ? path + (path.indexOf('?') < 0 ? '?' : '&') + 'k=' + encodeURIComponent(LINK) : path; }
  function api(path, body) {
    return fetch(linked(path), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}) });
  }

  // Inside the iPhone app with the Mac as the brain: the app calls these exactly as it would
  // call the in-page brain, and each one becomes a request to the Mac.
  function startRelay() {
    var announced = false, lookSeen = null, lastRecap = '';
    function quiet(p) { p.catch(function () {}); }
    function fetchMemory() {
      fetch(linked('memory'), { cache: 'no-store' }).then(function (r) { return r.json(); })
        .then(function (m) { post({ type: 'memory', items: m.items || [] }); }).catch(function () {});
    }
    window.GistNative = {
      heard: function (text) { quiet(api('chunk', { text: text })); },
      look: function (jpegBase64, unasked) { quiet(api('look', { image: jpegBase64, quiet: !!unasked })); },
      setListening: function (on) { quiet(api('listening', { listening: !!on })); },
      end: function () { quiet(api('end')); },
      setDay: function (events) { quiet(api('day', { events: events })); },
      briefNow: function () { quiet(api('brief')); },
      setHost: function (info) { quiet(api('host', info)); },
      configure: function () {},
      forget: function () { quiet(api('forget').then(fetchMemory)); },
      planDay: function () {
        api('plan').then(function (r) { return r.json(); })
          .then(function (d) { post({ type: 'plan', events: d.events || [] }); }).catch(function () {});
      },
      redraw: function () { lastFrameSig = ''; if (current) render(current); },
    };
    return function onState(s) {
      if (!announced) { announced = true; post({ type: 'ready', core: s.core, brain: 'mac' }); fetchMemory(); }
      // The Mac's brain cannot take a photo itself; when it wants one it says so and the phone takes it.
      var want = s.host && s.host.lookWanted;
      if (lookSeen === null) lookSeen = want || 0;
      else if (want && want !== lookSeen) { lookSeen = want; post({ type: 'look', reason: 'heard' }); }
      // A finished recap means the Mac's memory has a new entry; fetch it once for the phone's list.
      var recapKey = s.phase === 'recap' && s.recap ? s.recap.title + '|' + s.recap.points.length : '';
      if (recapKey && recapKey !== lastRecap) { lastRecap = recapKey; setTimeout(fetchMemory, 300); }
      if (!recapKey) lastRecap = '';
    };
  }

  function startLive() {
    var v = -1, backoff = 500, parked = false;
    var relay = HOSTED ? startRelay() : null;
    function loop() {
      if (document.hidden && !HOSTED) { parked = true; return; }   // nothing is polled while the page is not visible
      fetch(linked('poll?v=' + v), { cache: 'no-store' }).then(function (r) {
        if (r.status === 401) throw new Error('link code');
        return r.json();
      }).then(function (s) {
        offline = false; backoff = 500; v = s.v;
        render(s); devInfo(s);
        if (relay) relay(s);
        loop();
      }).catch(function (err) {
        offline = true;
        if (current) render(current);
        if (err && err.message === 'link code') $('stateText').textContent = 'Scan the setup code again';
        setTimeout(loop, backoff); backoff = Math.min(backoff * 2, 5000);
      });
    }
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && parked) { parked = false; loop(); }
      if (!document.hidden) keepAwake();
    });
    $('pause').addEventListener('click', function () {
      if (!current) return;
      keepAwake();
      api('listening', { listening: !current.listening }).catch(function () {});
    });
    var clockTimer = setInterval(function () { if (!document.hidden) { tickClock(); if (current && current.phase === 'standby') drawStandbyIfMinuteChanged(); } }, 1000);
    window.addEventListener('pagehide', function () { clearInterval(clockTimer); });
    loop();
    keepAwake();
    registerVoiceTools();
    if (['localhost', '127.0.0.1'].indexOf(location.hostname) >= 0) buildDevBar();
  }

  var lastMinute = '';
  function drawStandbyIfMinuteChanged() {
    var m = hhmm(new Date());
    if (m !== lastMinute) { lastMinute = m; drawStandby(current); }
  }

  // Ask the display to stay on while Gist is listening. Not every runtime honours this.
  var wake = null;
  function keepAwake() {
    try {
      if (!navigator.wakeLock || wake) return;
      navigator.wakeLock.request('screen').then(function (w) { wake = w; w.addEventListener('release', function () { wake = null; }); }).catch(function () {});
    } catch (e) { /* unsupported */ }
  }

  // Lets the wearer talk to Gist through the glasses' own assistant ("Hey Meta, what did I miss?").
  // Additive: everything here is also reachable with the D-pad or the phone.
  function registerVoiceTools() {
    var ctx = document.modelContext;
    if (!ctx || !ctx.registerTool) return;
    function safe(tool) {
      try {
        var r = ctx.registerTool(tool);
        if (r && typeof r.then === 'function') r.then(undefined, function () {});
      } catch (e) { /* a failed registration must not break the lens */ }
    }
    safe({
      name: 'gist_catch_me_up',
      description: 'Report what the person the wearer is listening to has been saying: the current point, the best question to ask, and any recap. Read-only. Use when the wearer asks what they missed, what the point is, or what to ask.',
      inputSchema: { type: 'object', properties: {} },
      annotations: { readOnlyHint: true },
      execute: function () {
        var s = current || {};
        return JSON.stringify({
          listening: !!s.listening, point: s.headline || '', question_to_ask: s.ask || '',
          recap: s.recap ? { title: s.recap.title, points: s.recap.points, actions: s.recap.actions } : null,
          next_action: 'Say the point and the question in one short sentence each. Stop and talk.',
        });
      },
    });
    safe({
      name: 'gist_set_listening',
      description: 'Pause or resume Aside listening to the conversation. Pass "pause" or "resume".',
      inputSchema: { type: 'object', properties: { mode: { type: 'string', description: 'Either "pause" or "resume".' } }, required: ['mode'] },
      execute: function (input) {
        var on = !/pause|stop|off/i.test(String(input && input.mode));
        return api('listening', { listening: on }).then(function () {
          return JSON.stringify({ listening: on, next_action: 'Confirm in one short sentence. Stop and talk.' });
        });
      },
    });
  }

  // ---------- developer bar (localhost only) ----------
  function devInfo(s) {
    var info = $('devInfo');
    if (!info) return;
    var f = s.perf.fastMs.slice(-1)[0], d = s.perf.deepMs.slice(-1)[0];
    info.textContent = (s.mode === 'scripted' ? 'Scripted answers (no key in key.txt)' : 'Live · headline: ' + s.models.fast + (f ? ' ' + f + ' ms' : '') + ' · picture: ' + s.models.deep + (d ? ' ' + d + ' ms' : '')) +
      (s.perf.lastError ? ' · last error: ' + s.perf.lastError : '');
  }

  function buildDevBar() {
    var heard = el('div'); heard.id = 'heard';
    var bar = el('div'); bar.id = 'dev';
    function button(label, fn, cls) { var b = el('button', cls || '', label); b.type = 'button'; b.addEventListener('click', fn); bar.appendChild(b); return b; }
    var mic = button('🎙 Test with this Mac’s mic', toggleMic);
    var lang = el('select'); lang.setAttribute('aria-label', 'Spoken language');
    [['en-US', 'English'], ['it-IT', 'Italiano']].forEach(function (o) { var op = el('option', '', o[1]); op.value = o[0]; lang.appendChild(op); });
    bar.appendChild(lang);
    button('▶ Replay sample', function () { api('replay-sample'); }, 'alt');
    button('End conversation', function () { api('end'); }, 'alt');
    button('Brief me (demo day)', function () { api('demo-day'); }, 'alt');
    button('Forget everything', function () { api('forget'); }, 'alt');
    var a = el('a', 'alt', 'All scenes'); a.href = 'gallery.html'; a.target = '_blank'; bar.appendChild(a);
    var a2 = el('a', 'alt', 'Glasses setup'); a2.href = 'setup'; a2.target = '_blank'; bar.appendChild(a2);
    var info = el('span'); info.id = 'devInfo'; bar.appendChild(info);
    document.body.classList.add('dev');
    document.body.appendChild(heard); document.body.appendChild(bar);

    // Test only: speech from this computer's mic, transcribed by the browser, sent to the brain as text.
    var SR = window.SpeechRecognition || window.webkitSpeechRecognition, rec = null, on = false;
    function stopMic() { on = false; if (rec) rec.stop(); mic.classList.remove('on'); mic.textContent = '🎙 Test with this Mac’s mic'; api('host', { ears: 'none' }); }
    function toggleMic() {
      if (on) return stopMic();
      if (!SR) { heard.textContent = 'This browser has no speech recognition. Open http://localhost:8787 in Google Chrome.'; return; }
      rec = new SR(); rec.continuous = true; rec.interimResults = true; rec.lang = lang.value;
      rec.onresult = function (e) {
        var interim = '';
        for (var i = e.resultIndex; i < e.results.length; i++) {
          var t = e.results[i][0].transcript.trim();
          if (e.results[i].isFinal) { if (t) { api('chunk', { text: t }); heard.textContent = 'Heard: ' + t; } } else interim += t + ' ';
        }
        if (interim) heard.textContent = 'Hearing: ' + interim;
      };
      rec.onerror = function (e) {
        if (e.error === 'no-speech' || e.error === 'aborted') return;
        heard.textContent = e.error === 'not-allowed' ? 'Microphone permission was denied. Allow it in the address bar and try again.' : 'Mic error: ' + e.error;
        if (e.error === 'not-allowed' || e.error === 'service-not-allowed') stopMic();
      };
      rec.onend = function () { if (on) { try { rec.start(); } catch (err) { /* already starting */ } } };
      on = true; rec.start();
      mic.classList.add('on'); mic.textContent = '■ Stop mic';
      heard.textContent = 'Listening on this Mac… start explaining something.';
      api('host', { ears: 'mac' }); api('listening', { listening: true });
    }
  }

  // ---------- built-in sample states, for looking at one scene at a time ----------
  var BASE = { v: 1, phase: 'live', listening: true, thinking: false, headline: '', term: null, scene: null, ask: '', turn: null, seen: null, recap: null, brief: null, next: null, open: [], notice: null, host: { ears: 'glasses' }, startedAt: Date.now() - 134000, perf: { fastMs: [], deepMs: [], lastError: '' } };
  function sample(over) { var s = JSON.parse(JSON.stringify(BASE)); for (var k in over) s[k] = over[k]; return s; }
  var SAMPLES = {
    map: sample({ headline: 'The marketplace sits between both sides', term: { word: 'liquidity', means: 'enough buyers and sellers to trade' }, ask: 'Why don’t organizers just give the boards away?',
      scene: { kind: 'map', title: 'Who trades', nodes: [{ id: 'a', label: 'Organizers' }, { id: 'b', label: 'Marketplace' }, { id: 'c', label: 'Student teams' }], edges: [{ from: 'a', to: 'b', label: 'spare boards' }, { from: 'b', to: 'c', label: 'matches' }] } }),
    map4: sample({ headline: 'Money moves through four hands', ask: 'Who carries the risk if a box is broken?',
      scene: { kind: 'map', title: 'The chain', nodes: [{ id: 'a', label: 'Organizers' }, { id: 'b', label: 'Marketplace' }, { id: 'c', label: 'Courier' }, { id: 'd', label: 'Student teams' }], edges: [{ from: 'a', to: 'b', label: 'lists' }, { from: 'b', to: 'c', label: 'books' }, { from: 'c', to: 'd', label: 'delivers' }] } }),
    loop: sample({ headline: 'More events should feed a growth loop', term: { word: 'flywheel', means: 'growth that feeds itself' }, ask: 'Why would more students make organizers list faster?', thinking: true,
      scene: { kind: 'loop', title: 'Growth loop', nodes: [{ id: 'e', label: 'More events' }, { id: 'f', label: 'More boards' }, { id: 'g', label: 'More students' }, { id: 'h', label: 'Faster listings' }] } }),
    mapskip: sample({ headline: 'Take rate is ten percent per swap', term: { word: 'take rate', means: 'fee taken per sale' }, ask: 'Who checks the hardware works before resale?',
      scene: { kind: 'map', title: 'Leftover hardware marketplace', nodes: [{ id: 'o', label: 'Organizers' }, { id: 'n', label: 'No inventory' }, { id: 's', label: 'Student teams' }, { id: 'm', label: 'Marketplace' }],
        edges: [{ from: 'o', to: 'm', label: 'supply' }, { from: 'n', to: 'm', label: 'holds' }, { from: 'o', to: 's', label: '' }, { from: 's', to: 'm', label: '' }] } }),
    steps: sample({ headline: 'Launch at Junction, then organizers, then campuses', ask: 'What has to be true before step two?',
      scene: { kind: 'steps', title: 'Rollout', steps: ['Launch at Junction', 'Sign five organizers', 'Open to every campus'], current: 1 } }),
    compare: sample({ headline: 'Ship each box, or pick up later', term: { word: 'margin', means: 'what is left after costs' }, ask: 'Would a student wait weeks for a sensor?',
      scene: { kind: 'compare', title: 'Shipping', left: { title: 'Organizer ships', points: ['Slow', 'Eats the margin'] }, right: { title: 'Pickup at event', points: ['Free', 'Takes weeks'] } } }),
    stats: sample({ headline: 'Two hundred events a year is the market', term: { word: 'take rate', means: 'the platform’s cut per sale' }, ask: 'Four euros a swap: how many swaps per event?',
      scene: { kind: 'stats', title: 'The money', stats: [{ value: '10%', label: 'take rate' }, { value: '€40', label: 'average box' }, { value: '200', label: 'events a year' }] } }),
    points: sample({ headline: 'A marketplace for leftover hackathon hardware', ask: 'Who owns the hardware after an event?',
      scene: { kind: 'points', title: 'The idea', points: ['Events end with unclaimed boards', 'Students can’t afford their own', 'A marketplace matches the two'] } }),
    empty: sample({ headline: '', thinking: true }),
    turn: sample({ headline: 'He wants to know if you’re in', turn: { asked: 'Would you join?', replies: ['€4 a swap: how many swaps a year?', 'Who pays when shipping goes wrong?', 'I’d test pickup at one event first'] } }),
    seen: sample({ headline: 'He says the slide proves the numbers', ask: 'Which number on the slide is revenue?', notice: { kind: 'seen', text: 'Slide: revenue projection table' },
      scene: { kind: 'stats', title: 'On the slide', stats: [{ value: '2,000', label: 'swaps in year one' }, { value: '€8,000', label: 'revenue' }] } }),
    paused: sample({ listening: false, headline: 'They only match, they hold no stock', ask: 'If you only match, who checks the boards work?',
      scene: { kind: 'points', title: 'The idea', points: ['No inventory', 'Only matching'] } }),
    recap: sample({ phase: 'recap', open: ['Ask for swaps per event'], recap: { title: 'Leftover hardware marketplace', points: ['Match organizers’ spare boards with student teams', 'Ten percent of a forty euro box', 'Launch at Junction, then five organizers'], actions: ['Ask for swaps per event', 'Decide whether to join by Sunday'], open: 'Who pays when shipping goes wrong?' } }),
    brief: sample({ phase: 'brief', open: ['Ask for swaps per event'], brief: { title: 'Pitch feedback with the Meta mentors', at: '14:00', inMin: 8, where: 'Meta booth', prep: ['Ask if the display sleeps while listening', 'Check how far the mics hear', 'Book the next glasses slot'] } }),
    standby: sample({ phase: 'standby', next: { title: 'Pitch feedback with the Meta mentors', at: '14:00', inMin: 8 }, open: ['Ask for swaps per event', 'Decide whether to join by Sunday'] }),
  };
  window.GistSamples = Object.keys(SAMPLES);

  // ---------- go ----------
  function start() {
    if (SHOW && SAMPLES[SHOW]) return render(SAMPLES[SHOW]);
    if (NATIVE) return startNative();
    startLive();
  }
  if (document.fonts && document.fonts.ready && !NATIVE) document.fonts.ready.then(start); else start();
})();
