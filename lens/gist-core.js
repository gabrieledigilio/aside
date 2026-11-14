// Gist core: the brain. Turns a running transcript into what the lens shows.
//
// Host-agnostic on purpose. The same file runs in Node (the Mac server) and inside a web view
// (the iPhone app). A host gives it two things: `send(body)` to reach the model API, and a
// clock tick. Everything else (prompts, the two-speed loop, clamping model output to what a
// 600x600 display can hold, the standby/live/recap flow) lives here so it is tested once.
//
// No imports, no exports: it attaches GistCore to globalThis so a classic <script> tag and a
// Node `import` both work.
(function (root) {
  'use strict';

  var VERSION = '2.4';

  // ---------- small helpers ----------
  function words(s, n) {
    return String(s == null ? '' : s).replace(/\s+/g, ' ').trim().split(' ').filter(Boolean).slice(0, n).join(' ');
  }
  function countWords(s) {
    return String(s || '').trim().split(/\s+/).filter(Boolean).length;
  }
  function hasLetters(s) {
    return /[\p{L}\p{N}]{2,}/u.test(String(s || '')) || /^[\p{L}\p{N}]$/u.test(String(s || '').trim());
  }
  function list(arr, max, maxWords) {
    return (Array.isArray(arr) ? arr : [])
      .map(function (x) { return words(x, maxWords); })
      .filter(hasLetters)
      .slice(0, max);
  }
  function strip(s) {
    return String(s || '').replace(/[.\s]+$/, '');
  }

  // ---------- what the models must return (strict JSON schema: every field required) ----------
  var str = { type: 'string' };
  var strList = { type: 'array', items: str };
  function obj(props) {
    return { type: 'object', additionalProperties: false, properties: props, required: Object.keys(props) };
  }

  var FAST_SCHEMA = obj({
    move: { type: 'string', enum: ['same', 'sharper', 'new'] },
    gist: str, term_word: str, term_means: str, asked: str, replies: strList, look: { type: 'boolean' },
  });

  var DEEP_SCHEMA = obj({
    change: { type: 'string', enum: ['keep', 'grow', 'new'] },
    scene: { type: 'string', enum: ['map', 'loop', 'steps', 'compare', 'stats', 'points'] },
    title: str,
    point: str,
    nodes: { type: 'array', items: obj({ id: str, label: str }) },
    edges: { type: 'array', items: obj({ from: str, to: str, label: str }) },
    steps: strList,
    current: { type: 'integer' },
    left_title: str, left_points: strList, right_title: str, right_points: strList,
    stats: { type: 'array', items: obj({ value: str, label: str }) },
    points: strList,
    question: str,
  });

  var RECAP_SCHEMA = obj({ title: str, points: strList, actions: strList, open: str });
  var BRIEF_SCHEMA = obj({ prep: strList });
  var LOOK_SCHEMA = obj({ note: str, facts: strList });
  var TURN_SCHEMA = obj({ about: { type: 'string', enum: ['wearer', 'other', 'unknown'] }, replies: strList });

  // ---------- prompts ----------
  // What every lane is told about its input. The glasses hear the whole room, the wearer included.
  var HEARD = 'The transcript is speech-to-text from the glasses\' microphones, often in a loud room, one line per stretch of speech. ' +
    'It holds everyone\'s words, the wearer\'s own included. A line that begins "WEARER:" was said by the person wearing the glasses, and "OTHER:" by someone else ' +
    '(the glasses can tell: the wearer\'s voice is far louder at their microphones). A line with no label could be either (a new line often means someone else started talking). ' +
    'The labels are not part of what was said: never repeat them. ' +
    'Words can be wrong or missing, and stray fragments from people nearby slip in.';

  var FAST_SYSTEM = [
    'You are the fast lane of Aside, a comprehension aid shown inside smart glasses during a real conversation. Your job is to hold the thread: say what the conversation is really about right now, and not get distracted.',
    'You receive the transcript so far, then the NEWEST WORDS. ' + HEARD,
    'Reply with ONLY a JSON object:',
    '{"move": "same", "gist": "", "term_word": "", "term_means": "", "asked": "", "replies": [], "look": false}',
    '',
    '- move: decide this first. Ask yourself: is the PREVIOUS GIST still a true answer to "what are they talking about right now?"',
    '  "same": yes. The NEWEST WORDS carry nothing of substance (small talk and politeness such as "no rush", "no worries", "thanks", "sounds good"; agreement and filler; jokes; side chatter about food, breaks or the room; repeated or unfinished sentences; mis-heard words; fragments that fit nothing), or they only repeat or illustrate the point. Most short lines are "same".',
    '  "sharper": mostly. It is the same subject, but it moved forward: a new claim, problem, fix, step, number, decision or objection that the gist should now carry.',
    '  "new": no. The talk is now about something else, even something related (from one technique to another, from one problem to the next). One clear sentence about the new thing is enough.',
    '  A lone word or a short fragment is never a new subject. Speech-to-text writes words that sound alike ("gender" where "tender" was said, "bored" for "board"), so a word that does not belong in this conversation is a mishearing: read it as the word that would fit, or ignore it. The move is then "same" or "sharper", never "new".',
    '- gist: the point on the table right now: the idea, claim, plan, problem or decision being worked out, the way you would whisper it to a friend who just walked up. Max 8 words. Sentence case, no final period.',
    '  When move is "same", copy the PREVIOUS GIST word for word. When there is no PREVIOUS GIST and nothing but greetings, filler or fragments has been said, return "same" with an empty gist.',
    '  Otherwise write the point as it stands now: ONE point, the latest one of substance, never two joined by a comma or "and". Use the rest of the transcript to make it clear on its own (name the thing it is about), and keep earlier wording only where it still fits.',
    '  Say the point itself as a statement with a verb ("Rent is rising faster than wages"), not an -ing phrase ("Introducing rent", "Discussing wages"). Never say that people are talking or about to ("They discuss an idea", "Speaker explains the plan", "Rent is about to be explained"), never name who is speaking, and never echo small talk.',
    '  When a sentence has introduced a new subject ("let us talk about rent control", "so, how do you bake bread?") and nothing has been said about it yet, the gist is its name alone ("Rent control", "How to bake bread"). Do not invent a claim about it.',
    '  A question is never turned into a claim, and you never answer it yourself. When the newest words only ask something about the point already on the lens, the move is "same". When they ask about something else, the gist names what is being asked ("What happens when the Wi-Fi drops", "How tests are split across machines").',
    '  The lens must not state as true what is only someone\'s view on a matter people fight over. When the point is an accusation against a person or a group, or a claim about politics, religion, nations, groups of people or a disputed public fact, start the gist with "Claim:" ("Claim: remote work makes people lazy"). That is all it is for. Advice, taste, preferences, how-to and plans ("sear it three minutes", "it depends on your budget", "we should launch in spring"), and plain facts about the matter in hand, never get it.',
    '- term_word / term_means: only when the newest words contain jargon or an acronym a newcomer would not know. term_word is the term exactly as said; term_means is its plain meaning in max 5 short words. Otherwise both are empty strings. Never invent a term that was not said.',
    '- asked: only when the newest words END with a question or request that someone puts TO the wearer ("what do you think?", "does that make sense?", "can you take that?"). Restate it in max 8 words. Otherwise empty. It must be about the matter being discussed: small talk and logistics ("got a minute?", "how are you?", "are you getting food?") do not count. Nor does it count when the person answers it themself, or when it is the wearer\'s own question: the wearer is the one being explained to, so a question that asks for an explanation ("how does that work?", "what do you mean?") is usually theirs, and so is anything close to the QUESTION THE LENS SUGGESTED. A question on a line labelled WEARER is always the wearer\'s own: asked stays empty. A question on a line labelled OTHER that is put to the wearer counts, whatever it asks.',
    '- replies: when asked is set, 2 or 3 things the wearer could say back, each max 7 words, concrete and grounded in what was actually said: a doubt worth raising, a missing fact to request, or a clear position. When WHO IS EXPLAINING says the wearer, the question is about the wearer\'s own subject, which only the wearer knows: the replies are then reminders of things the wearer already said that answer it, in the wearer\'s words, and an empty list when the wearer said nothing that bears on it. Never invent a fact about the wearer\'s subject. When asked is empty, an empty list.',
    '- look: true only when the newest words point at something visible ("this slide", "as you can see", "look at this chart", "on the whiteboard", "this number here").',
    '',
    'Write in the language being spoken.',
  ].join('\n');

  var DEEP_SYSTEM = [
    'You are the deep lane of Aside, a comprehension aid shown inside smart glasses during a real conversation.',
    'Turn what the conversation is about into ONE small visual that makes its structure obvious, plus the single best question for the wearer to ask next.',
    HEARD,
    'The display is tiny (600x600 pixels, large type), so every label must be very short.',
    '',
    'Reply with ONLY a JSON object with exactly these fields. Fill the fields of the scene you choose and leave the rest empty ("" or [] or 0):',
    '{"change": "", "scene": "", "title": "", "point": "", "nodes": [{"id": "a", "label": ""}], "edges": [{"from": "a", "to": "b", "label": ""}], "steps": [], "current": 0, "left_title": "", "left_points": [], "right_title": "", "right_points": [], "stats": [{"value": "", "label": ""}], "points": [], "question": ""}',
    '',
    'change is one of (decide this first):',
    '- "keep": the NEWEST WORDS add nothing of substance: small talk, politeness, agreement, filler, side chatter, repeats, stray fragments. The lens then keeps the PREVIOUS VISUAL and PREVIOUS QUESTION as they are. Set scene to "points" and leave every other field empty.',
    '- "grow": still the same subject, and something of substance was added. Return the PREVIOUS VISUAL with it worked in.',
    '- "new": there is no previous visual yet, or the conversation has really moved to a different subject, or the shape of the idea has changed.',
    '',
    'scene is one of:',
    '- "map": how things connect (causes, parts, who does what). nodes: max 4, label max 3 words. edges: from/to are node ids, label max 2 words or "".',
    '- "loop": a cycle or flywheel where the last step feeds the first. nodes: 3 to 5 in order, label max 3 words. No edges.',
    '- "steps": a process, plan or timeline. steps: max 4, each max 4 words, in order. current: index (0-based) of the step being discussed now.',
    '- "compare": two options, two sides, or before and after. left_title / right_title: max 2 words. left_points / right_points: max 3 each, max 4 words each.',
    '- "stats": the talk hinges on numbers. stats: max 3. value is the number as said ("10%", "€40", "3x"); label max 3 words.',
    '- "points": none of the above fits. points: max 3, each max 6 words: the key claims.',
    '',
    'title: max 3 words naming what the visual shows.',
    'point: the idea the visual shows as one plain line, max 8 words, sentence case, no final period: what you would whisper to a friend who just walked up. Say the idea itself, never that people are talking.',
    'question: the one question the wearer should ask next, phrased as they would say it out loud, max 11 words. Aim at the weakest spot: an unstated assumption, a number that does not add up, a missing step, a vague word. Never ask something that was already answered, or that anyone in the transcript already asked or raised themself: if the PREVIOUS QUESTION now appears in the transcript, the wearer asked it, so move to the next weakest spot. With "new", write a fresh question about the new visual. With "grow", keep the PREVIOUS QUESTION word for word while it still aims at the weakest spot of what is on the table. When WHO IS EXPLAINING says the wearer, the wearer is the one presenting and the other person is listening: the question is then the one a sharp listener is most likely to ask the wearer next, phrased as that listener would say it, so the wearer can have an answer ready. It aims at the same weakest spot. A PREVIOUS QUESTION marked as the other kind no longer fits: write a new one.',
    '',
    'Rules:',
    '- Speech-to-text writes words that sound alike ("gender" where "tender" was said). A word that does not belong in this conversation is a mishearing: read it as the word that would fit, or leave it out. Never build a visual, a title or a question around one odd word.',
    '- The visual shows what the conversation is about right now: judge that from the NEWEST WORDS in the light of the whole transcript, and build it from everything of substance said about that. It is not a picture of the last sentence, and small talk never appears in it.',
    '- THE HEADLINE ON THE LENS is what the wearer reads above your visual, so the two must be about the same thing. If the headline is about something the PREVIOUS VISUAL does not show, the visual is behind: "keep" is wrong, use "grow" to work it in or "new" to draw it. The headline can also be a little behind: when the NEWEST WORDS have clearly moved to something else, even something related, draw the new thing with "new".',
    '- Pick the scene from the SHAPE of the idea: figures being quoted -> "stats"; a cycle that feeds itself -> "loop"; two options being weighed -> "compare"; a plan or sequence -> "steps"; things acting on each other -> "map". When the shape has changed since the PREVIOUS VISUAL, switch scenes, even if the previous one was good.',
    '- With "grow", keep node ids, labels and step order stable so the picture does not jump around.',
    '- Labels come from the words that were said. No placeholders, no invented facts. Numbers only if they were said or seen.',
    '- Lines like "[Seen: ...]" describe what the wearer was looking at. Treat them as part of the conversation.',
    '- Write in the language being spoken.',
  ].join('\n');

  var RECAP_SYSTEM = [
    'You are Aside, a comprehension aid in smart glasses. A conversation the wearer was part of has just ended. Below is its transcript.',
    HEARD,
    'Write what the wearer should walk away with. Reply with ONLY a JSON object:',
    '{"title": "", "points": [], "actions": [], "open": ""}',
    '- title: max 4 words naming the conversation.',
    '- points: max 3, each max 8 words: what was actually concluded or claimed, each a full plain statement that makes sense on its own. Leave out small talk and anything that reads like a stray fragment. An accusation against a person or a group, or a claim about politics, religion, nations, groups of people or a disputed public fact, is written as someone\'s claim ("Claim: ..."), never as a fact. Advice, taste, how-to and plans are never marked that way.',
    '- actions: max 3, each max 8 words, starting with a verb: things the wearer agreed to do or needs to follow up. Empty list if none.',
    '- open: the most important question that was raised and never answered, max 10 words. Check the transcript first: if an answer was given anywhere, even a rough one, it is not open. When nothing was left open, "".',
    'The recap is read by the wearer: never call them "the wearer" and never use the labels as names. Where a point is about them, say "you" ("You will send the timing data"); otherwise say the thing itself.',
    'Only use what was said. Write in the language that was spoken.',
  ].join('\n');

  var BRIEF_SYSTEM = [
    'You are Aside, a comprehension aid in smart glasses. The wearer has something coming up on their calendar. Prepare them in one glance.',
    'Reply with ONLY a JSON object: {"prep": []}',
    '- prep: max 3 items, each max 7 words: what to find out, ask, or decide there. Concrete and specific to this event and to any unfinished items listed. No generic advice ("be prepared", "take notes").',
    'Write in the language of the event title.',
  ].join('\n');

  var TURN_SYSTEM = [
    'You are Aside, a comprehension aid in smart glasses. The wearer is in a conversation and has just been asked a question. The wearer needs something good to say within seconds.',
    HEARD,
    'Reply with ONLY a JSON object: {"about": "", "replies": []}',
    '- about: decide this first. Whose subject is the question about? "wearer": it asks about something the wearer has been describing in their own WEARER lines (their product, their work, their plan), which only the wearer knows. "other": it asks what the wearer thinks of something the other person described. "unknown": the transcript has no labels, or it cannot be told.',
    '- replies: things the wearer could say back, each max 8 words.',
    '  When about is "other" or "unknown", exactly 3, in this order:',
    '  1. the sharpest doubt, as a question: aim at the weakest point (a number that does not add up, an unstated assumption, a missing step). If numbers were given, do the arithmetic and use the result.',
    '  2. a missing fact to ask for.',
    '  3. a clear position the wearer could take, with its reason.',
    '  When about is "wearer", the replies are reminders, not suggestions: up to 3 things the wearer ALREADY SAID in the transcript (WEARER lines) that answer the question, the most direct first, each max 8 words, kept close to the wearer\'s own words. Leave out anything the wearer said that does not answer this question. Never add a fact, a number, a limit or a status the wearer did not say ("not tested yet", "still measuring" are inventions), and never turn the question back on the wearer. When the wearer said nothing that answers it, return an empty list.',
    'Ground every reply in what was actually said. No generic lines. Write in the language being spoken.',
  ].join('\n');

  var LOOK_SYSTEM = [
    'The image is what the wearer of smart glasses is looking at during a conversation: a slide, a screen, a whiteboard, a document or an object.',
    'Reply with ONLY a JSON object: {"note": "", "facts": []}',
    '- note: what it is, max 8 words ("Slide: unit economics table").',
    '- facts: max 3 short facts or numbers that are readable in it, each max 6 words.',
    'If nothing in it is readable or relevant, return {"note": "", "facts": []}. Never guess text you cannot read.',
  ].join('\n');

  // The same question asked without being asked, every few seconds. Most of the time the right answer is "nothing new".
  var GLANCE_SYSTEM = [
    'The image is what the wearer of smart glasses is looking at right now, during a conversation. Nobody asked for it: the glasses take a look by themselves every few seconds.',
    'Reply with ONLY a JSON object: {"note": "", "facts": []}',
    '- note: only when something in view carries information worth reading: a slide, a screen, a whiteboard, a poster, a document, a label, a product. Say what it is in max 8 words ("Slide: unit economics table"). A person, a room, a desk, or anything with nothing readable on it gets an empty note.',
    '- facts: max 3 short facts or numbers that are readable in it, each max 6 words.',
    'ALREADY SEEN says what was read last. If the image shows that same thing and nothing new can be read, return an empty note.',
    'Never guess text you cannot read. Never describe people.',
  ].join('\n');

  // Two notes are about the same thing when they share most of their words.
  function sameNote(a, b) {
    var wa = String(a || '').toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean);
    var wb = String(b || '').toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean);
    if (!wa.length || !wb.length) return false;
    var shared = wa.filter(function (w) { return wb.indexOf(w) >= 0; }).length;
    return shared / Math.max(wa.length, wb.length) >= 0.6;
  }

  // ---------- clamp model output to what the lens can show ----------
  var SMALL_TALK = /^(no|not|rush|worries|worry|problem|problems|stress|take|your|time|thanks|thank|you|ok|okay|sure|sounds|good|all|got|it|nice|cool|great|yeah|yes|yep|right|hello|hi|hey|fine|alright|so|well|and|then|just|really|very|much|is|its|it's|that's|thats|i|see|me|too|please|sorry|bye|goodbye|cheers|welcome|you're|youre|don't|dont|of|course|a|the|bit|minute|second|moment|hold|on|wait|one|sec|at|for|to|we|have|there|hurry|need|problemo|perfect|awesome|lovely)?$/i;

  function cleanPoint(text) {
    var gist = strip(words(String(text == null ? '' : text).replace(/^\s*(WEARER|OTHER)\s*:\s*/i, ''), 9));
    // A line about someone talking is not a point; the last real headline stays instead.
    if (/^(the\s+)?speaker\b/i.test(gist) || /\b(says?|saying|begins? to say|starts? to say) something\b/i.test(gist)) gist = '';
    if (/\b(about to be|going to be|will be|is being|are being) (explained|discussed|introduced|covered|described|presented)\b/i.test(gist)) gist = '';
    var bare = gist.replace(/^(moving on to|introducing|discussing|talking about|explaining|let's talk about)\s+/i, '');
    if (bare !== gist) gist = bare.charAt(0).toUpperCase() + bare.slice(1);
    // Nor is an echo of small talk ("No rush, no worries").
    if (gist && gist.split(' ').every(function (w) { return SMALL_TALK.test(w.replace(/[^\p{L}']/gu, '')); })) gist = '';
    return gist;
  }

  function cleanFast(raw) {
    var s = raw && typeof raw === 'object' ? raw : {};
    var term = hasLetters(s.term_word) && hasLetters(s.term_means)
      ? { word: words(s.term_word, 3), means: strip(words(s.term_means, 7)) }
      : null;
    var asked = strip(words(s.asked, 10));
    var replies = list(s.replies, 3, 8).map(strip);
    var gist = cleanPoint(s.gist);
    var move = s.move === 'same' || s.move === 'new' ? s.move : 'sharper';
    return {
      move: move,
      gist: gist,
      term: term,
      turn: hasLetters(asked) ? { asked: asked, replies: replies } : null,
      look: s.look === true,
    };
  }

  function cleanDeep(raw, prev) {
    var s = raw && typeof raw === 'object' ? raw : {};
    // "keep": nothing of substance was added, so the picture and the question stay exactly as they were.
    if (s.change === 'keep' && prev && prev.scene) return { scene: prev.scene, ask: prev.ask || '', kept: true };
    var kind = String(s.scene || '');
    var title = strip(words(s.title, 4));
    var scene = null;

    if (kind === 'map' || kind === 'loop') {
      var max = kind === 'loop' ? 5 : 4;
      var seenIds = {};
      var nodes = (Array.isArray(s.nodes) ? s.nodes : [])
        .filter(function (n) { return n && n.id != null && hasLetters(n.label); })
        .map(function (n) { return { id: String(n.id), label: strip(words(n.label, 3)) }; })
        .filter(function (n) { if (seenIds[n.id]) return false; seenIds[n.id] = true; return true; })
        .slice(0, max);
      var ids = {};
      nodes.forEach(function (n) { ids[n.id] = true; });
      var edges = (Array.isArray(s.edges) ? s.edges : [])
        .filter(function (e) { return e && ids[String(e.from)] && ids[String(e.to)] && String(e.from) !== String(e.to); })
        .map(function (e) { return { from: String(e.from), to: String(e.to), label: strip(words(e.label, 2)) }; })
        .slice(0, 5);
      if (kind === 'loop' && nodes.length >= 3) scene = { kind: 'loop', title: title, nodes: nodes };
      else if (nodes.length >= 2) {
        // A map with no usable edges still reads as a set of parts; keep only connected ones if any exist.
        scene = { kind: 'map', title: title, nodes: nodes, edges: edges };
      }
    } else if (kind === 'steps') {
      var steps = list(s.steps, 4, 5).map(strip);
      if (steps.length >= 2) {
        var cur = Number.isFinite(s.current) ? Math.round(s.current) : 0;
        scene = { kind: 'steps', title: title, steps: steps, current: Math.max(0, Math.min(steps.length - 1, cur)) };
      }
    } else if (kind === 'compare') {
      var lt = strip(words(s.left_title, 3)), rt = strip(words(s.right_title, 3));
      var lp = list(s.left_points, 3, 5).map(strip), rp = list(s.right_points, 3, 5).map(strip);
      if (hasLetters(lt) && hasLetters(rt) && lp.length + rp.length > 0) {
        scene = { kind: 'compare', title: title, left: { title: lt, points: lp }, right: { title: rt, points: rp } };
      }
    } else if (kind === 'stats') {
      var stats = (Array.isArray(s.stats) ? s.stats : [])
        .filter(function (x) { return x && /\d/.test(String(x.value || '')) && hasLetters(x.label); })
        .map(function (x) { return { value: String(x.value).replace(/\s+/g, '').slice(0, 7), label: strip(words(x.label, 4)) }; })
        .slice(0, 3);
      if (stats.length >= 1) scene = { kind: 'stats', title: title, stats: stats };
    }
    if (!scene) {
      var points = list(s.points, 3, 7).map(strip);
      if (points.length >= 1) scene = { kind: 'points', title: title, points: points };
    }
    var q = strip(words(s.question, 13)).replace(/\?+$/, '');
    return {
      scene: scene || (prev && prev.scene) || null,
      ask: hasLetters(q) ? q + '?' : (prev && prev.ask) || '',
      point: scene ? cleanPoint(s.point) : '',
      fresh: !!scene && s.change === 'new',
      drew: !!scene,
    };
  }

  // The speaker labels are for the models only. If one slips into something the wearer reads, it is
  // taken out: a label at the start goes, and "the wearer" becomes "you".
  function unlabel(text) {
    var t = String(text || '').replace(/^\s*(WEARER|OTHER)\s*:\s*/i, '');
    t = t.replace(/\bdoes the wearer\b/gi, 'do you').replace(/\bis the wearer\b/gi, 'are you').replace(/\bhas the wearer\b/gi, 'have you')
      .replace(/\bthe wearer is\b/gi, 'you are').replace(/\bthe wearer has\b/gi, 'you have').replace(/\bthe wearer was\b/gi, 'you were')
      .replace(/\bthe wearer's\b/gi, 'your').replace(/\bthe wearer\b/gi, 'you')
      .replace(/^wearer's\b/i, 'Your').replace(/^wearer\b/i, 'You')
      .replace(/\bwearer's\b/gi, 'your').replace(/\bwearer\b/gi, 'you');
    return t ? t.charAt(0).toUpperCase() + t.slice(1) : t;
  }
  function cleanRecap(raw) {
    var s = raw && typeof raw === 'object' ? raw : {};
    // In a title the word is simply dropped ("Wearer listening aid demo" -> "Listening aid demo").
    var title = String(s.title || '').replace(/\b(the\s+)?wearer('s)?\s*/gi, '').replace(/^\s*(OTHER)\s*:\s*/i, '');
    title = strip(words(title, 5));
    return {
      title: (title ? title.charAt(0).toUpperCase() + title.slice(1) : '') || 'Conversation',
      points: list(s.points, 3, 9).map(strip).map(unlabel),
      actions: list(s.actions, 3, 9).map(strip).map(unlabel),
      open: hasLetters(s.open) ? unlabel(strip(words(s.open, 12))).replace(/\?*$/, '') + '?' : '',
    };
  }

  // ---------- the engine ----------
  function create(opts) {
    opts = opts || {};
    var send = opts.send;                                   // (body) -> Promise<{status, text}>
    var now = opts.now || function () { return Date.now(); };
    var onChange = opts.onChange || function () {};
    var requestLook = opts.requestLook || null;             // host can take a photo; calls core.look(base64) later
    var cfg = {
      // hedgeMs: a request that has not answered by then gets a twin, and the first answer wins.
      // On a crowded network one request in a few simply hangs, and waiting it out stalls the lens.
      fast: Object.assign({ model: 'muse-ember-1.0', effort: 'low', maxTokens: 2000, timeoutMs: 9000, hedgeMs: 3500 }, opts.fast || {}),
      deep: Object.assign({ model: 'muse-wonder-1.0', effort: 'minimal', maxTokens: 2500, timeoutMs: 30000, hedgeMs: 9000 }, opts.deep || {}),
      silenceEndMs: opts.silenceEndMs || 30000,             // this long without speech ends the conversation
      recapHoldMs: opts.recapHoldMs || 45000,
      briefHoldMs: opts.briefHoldMs || 60000,
      minWordsForRecap: opts.minWordsForRecap || 40,
      deepMinGapMs: opts.deepMinGapMs || 6000,          // while they keep talking, redraw the picture at most this often
      deepPauseGapMs: opts.deepPauseGapMs || 2000,      // when they pause, catch up sooner
      lookMinGapMs: opts.lookMinGapMs || 20000,
      headlineHoldMs: opts.headlineHoldMs == null ? 3500 : opts.headlineHoldMs,   // a headline stays at least this long, so it can be read
      headlineStaleMs: opts.headlineStaleMs || 10000,   // after this long unchanged, a new picture may correct the headline
    };

    var state = {
      v: 0, core: VERSION,
      phase: 'standby',            // standby | live | recap | brief
      listening: true,
      thinking: false,
      headline: '', term: null, scene: null, ask: '', askFor: '', turn: null, seen: null,
      recap: null, brief: null, next: null, open: [],
      notice: null,
      host: {},                    // whatever the host reports: ears, mic name, battery
      startedAt: 0,
      perf: { fastMs: [], deepMs: [], fastErr: 0, deepErr: 0, lastError: '', lastErrorAt: 0 },
    };

    var transcript = [];           // [{t, text}] for the current conversation only; dropped when it ends
    var fastUpTo = 0, fastWaiting = 0;   // transcript lines the fast lane has seen, and how many spoken ones wait for it
    var fastBusy = false, deepBusy = false, deepDirty = false;
    var lastSpeechAt = 0, lastDeepAt = 0, lastLookAt = 0, phaseAt = 0, termAt = 0, noticeUntil = 0;
    var headlineAt = 0, heldGist = '';   // a sharper wording that arrived too soon after the last one waits here
    var deepEpoch = 0;                   // bumps when the subject changes, so a picture of the old subject is dropped
    var wordsAtHeadline = 0;             // how much had been said when the headline last changed
    var emptyDeeps = 0;                  // pictures in a row that came back with nothing drawable
    var lookBusy = false;                // one photo is being read
    var wordsAtLastDeep = 0;
    var day = [];                  // [{id,title,start,end,location,notes}]
    var briefed = {};
    var preps = {};                // event id -> prep points, worked out ahead of time
    var memory = [];               // recaps kept between conversations: [{at,title,actions,open}]
    var lastAsked = '';
    var session = 0;               // bumps when a conversation starts or ends, so late model replies are dropped

    function emit() { state.v++; try { onChange(state); } catch (e) { /* a broken listener must not stop the loop */ } }
    function fail(tier, err) {
      state.perf[tier + 'Err']++;
      state.perf.lastError = String(err && err.message ? err.message : err).slice(0, 300);
      state.perf.lastErrorAt = now();
    }
    function totalWords() { return transcript.reduce(function (n, x) { return n + countWords(x.text); }, 0); }
    function lastWords(n) {
      var all = transcript.map(function (x) { return x.text; }).join(' ').split(/\s+/);
      return all.slice(-n).join(' ');
    }
    // One line per stretch of speech. Glasses that can tell the wearer's voice from others' (it is far
    // louder at their microphones) say whose each line was; without that, the pauses are the only hint.
    function labelled(x) { return (x.who === 'me' ? 'WEARER: ' : x.who === 'them' ? 'OTHER: ' : '') + x.text; }
    // Who is doing the explaining right now, counted in words over the last stretch of speech whose
    // voice is known: 'me' (the wearer), 'them', or '' for a back-and-forth or when nobody can tell.
    function explainer() {
      var mine = 0, theirs = 0, seen = 0;
      for (var i = transcript.length - 1; i >= 0 && seen < 80; i--) {
        var n = countWords(transcript[i].text);
        if (transcript[i].who === 'me') mine += n; else if (transcript[i].who === 'them') theirs += n;
        seen += n;
      }
      if (mine + theirs < 12) return '';
      return mine >= 2 * theirs ? 'me' : theirs >= 2 * mine ? 'them' : '';
    }
    // Over the whole conversation: has the wearer done most of the talking (a pitch, then questions)?
    function mostlyMine() {
      var mine = 0, theirs = 0;
      transcript.forEach(function (x) {
        var n = countWords(x.text);
        if (x.who === 'me') mine += n; else if (x.who === 'them') theirs += n;
      });
      return mine >= 20 && mine >= 1.5 * theirs;
    }
    function explainerLine(who) {
      return '\nWHO IS EXPLAINING: ' + (who === 'me' ? 'the wearer' : who === 'them' ? 'the other person' : 'not known');
    }
    function transcriptText(maxChars, upTo) {
      var all = transcript.slice(0, upTo == null ? transcript.length : upTo).map(labelled).join('\n');
      return all.length > maxChars ? '…' + all.slice(-maxChars) : all;
    }
    // The headline changes when the point moves, not on every sentence. A new subject shows at once;
    // a sharper wording of the same point waits until the last one has had time to be read.
    function setHeadline(gist, atOnce) {
      if (!gist || gist === state.headline) { heldGist = ''; return; }
      if (!atOnce && state.headline && now() - headlineAt < cfg.headlineHoldMs) { heldGist = gist; return; }
      state.headline = gist; headlineAt = now(); heldGist = ''; wordsAtHeadline = totalWords();
    }

    // One model call: build the request, survive endpoints that reject optional fields, parse the JSON out.
    function callJSON(tier, system, user, schema, name, image) {
      var m = cfg[tier];
      var modelName = m.model, timeoutMs = m.timeoutMs;
      var content = image
        ? [{ type: 'text', text: user }, { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,' + image } }]
        : user;
      var body = {
        model: m.model,
        reasoning_effort: m.effort,     // Muse models reason at their maximum unless told otherwise, and that counts against max_tokens
        max_tokens: m.maxTokens,
        response_format: { type: 'json_schema', json_schema: { name: name, strict: true, schema: schema } },
        messages: [{ role: 'system', content: system }, { role: 'user', content: content }],
      };
      var t0 = now();
      var timer;
      var timeout = new Promise(function (_, reject) {
        timer = setTimeout(function () { reject(new Error(tier + ' model timed out after ' + timeoutMs + ' ms')); }, timeoutMs);
      });
      function attempt(b, fallbacks) {
        return Promise.resolve(send(b)).then(function (r) {
          if (r && r.status === 400 && fallbacks.length) {
            var next = Object.assign({}, b);
            delete next[fallbacks[0]];
            return attempt(next, fallbacks.slice(1));
          }
          return r;
        });
      }
      function hedged() {
        var first = attempt(body, ['response_format', 'reasoning_effort']);
        if (!m.hedgeMs) return first;
        return new Promise(function (resolve, reject) {
          var settled = false, started = 1, failed = 0;
          function ok(r) { if (!settled) { settled = true; clearTimeout(twin); resolve(r); } }
          function bad(e) { failed += 1; if (!settled && failed >= started) { settled = true; clearTimeout(twin); reject(e); } }
          var twin = setTimeout(function () {
            if (settled) return;
            started = 2;
            attempt(body, ['response_format', 'reasoning_effort']).then(ok, bad);
          }, m.hedgeMs);
          first.then(ok, bad);
        });
      }
      var work = hedged().then(function (r) {
        if (!r || r.status < 200 || r.status >= 300) {
          throw new Error('Model API ' + (r ? r.status : 'no response') + ': ' + String(r && r.text || '').slice(0, 200));
        }
        var data = JSON.parse(r.text);
        var choice = data.choices && data.choices[0];
        var text = choice && choice.message && choice.message.content || '';
        if (Array.isArray(text)) text = text.map(function (p) { return p.text || ''; }).join('');
        var a = text.indexOf('{'), z = text.lastIndexOf('}');
        if (a < 0 || z <= a) throw new Error('Model returned no JSON (finish: ' + (choice && choice.finish_reason) + ')');
        return { json: JSON.parse(text.slice(a, z + 1)), ms: now() - t0, usage: data.usage || null, model: modelName };
      });
      return Promise.race([work, timeout]).finally(function () { clearTimeout(timer); });
    }

    // ----- fast lane: headline, jargon, "your turn" -----
    function pumpFast() {
      if (fastBusy || !fastWaiting || state.phase !== 'live') return;
      if (!state.headline && totalWords() < 6) return;       // two or three words are not a point yet
      var newest = transcript.slice(fastUpTo);
      var said = newest.map(function (x) { return x.text; }).join('\n');
      var chunk = newest.map(labelled).join('\n');
      // The wearer's own words are never a question put to the wearer.
      var allMine = newest.length > 0 && newest.every(function (x) { return x.who === 'me'; });
      // A word or two on their own are usually a stray fragment: wait a moment for what follows.
      if (countWords(said) < 3 && !/\?\s*$/.test(said) && now() - lastSpeechAt < 1500) return;
      fastBusy = true;
      var before = fastUpTo;
      fastUpTo = transcript.length; fastWaiting = 0;
      var mySession = session;
      var who = explainer();
      if (who !== 'me' && mostlyMine()) who = 'me';       // a pitch followed by questions is still the wearer's subject
      var user = 'TRANSCRIPT SO FAR:\n' + (transcriptText(2400, before) || '(nothing yet)') +
        '\n\nNEWEST WORDS:\n' + chunk +
        '\n\nPREVIOUS GIST: ' + (state.headline || 'none yet') +
        (state.headline && totalWords() - wordsAtHeadline >= 35
          ? '\n(That gist has stood for ' + (totalWords() - wordsAtHeadline) + ' words. Check that it still says what they are talking about now.)' : '') +
        (state.askFor === 'me'
          ? '\nQUESTION THE LENS EXPECTS THE OTHER PERSON TO ASK: ' + (state.ask || 'none')
          : '\nQUESTION THE LENS SUGGESTED: ' + (state.ask || 'none')) +
        (who ? explainerLine(who) : '');
      callJSON('fast', FAST_SYSTEM, user, FAST_SCHEMA, 'gist_fast').then(function (r) {
        state.perf.fastMs = state.perf.fastMs.concat(r.ms).slice(-12);
        if (mySession !== session) return;
        var f = cleanFast(r.json);
        if (allMine) f.turn = null;
        // Asked about their own subject, the wearer gets reminders of what they said, not suggestions.
        if (f.turn && who === 'me') f.turn.kind = 'recall';
        if (f.gist && !(f.move === 'same' && state.headline)) {
          var newSubject = f.move === 'new' && !!state.headline && f.gist !== state.headline;
          setHeadline(f.gist, f.move === 'new');
          if (newSubject) {
            // A different subject: the old picture and question would now mislead, so the stage is cleared
            // and the deep lane draws the new one straight away.
            deepEpoch += 1;
            state.scene = null; state.ask = ''; state.askFor = ''; state.term = null;
            deepDirty = true; lastDeepAt = 0;
            if (!deepBusy) pumpDeep();
          }
        }
        if (f.term) { state.term = f.term; termAt = now(); }
        state.turn = f.turn;
        if (state.notice && state.notice.kind === 'lag') state.notice = null;
        if (f.turn && f.turn.asked !== lastAsked) sharpenTurn(f.turn.asked, mySession);
        if (!f.turn) lastAsked = '';
        if (f.look && requestLook && now() - lastLookAt > cfg.lookMinGapMs) {
          lastLookAt = now();
          try { requestLook('heard'); } catch (e) { /* no camera here */ }
        }
        emit();
      }).catch(function (err) {
        fail('fast', err);
        if (mySession === session) { state.notice = { kind: 'lag', text: 'Catching up' }; emit(); }
      }).finally(function () { fastBusy = false; pumpFast(); });
    }

    // The fast lane's replies show at once; the strong model's replace them a moment later.
    function sharpenTurn(asked, mySession) {
      lastAsked = asked;
      var who = explainer();
      if (who !== 'me' && mostlyMine()) who = 'me';
      var user = 'CONVERSATION SO FAR:\n' + transcriptText(3000) + '\n\nTHEY JUST ASKED THE WEARER: ' + asked +
        '\nWHO HAS DONE MOST OF THE EXPLAINING: ' + (who === 'me' ? 'the wearer' : who === 'them' ? 'the other person' : 'not known');
      callJSON('deep', TURN_SYSTEM, user, TURN_SCHEMA, 'gist_turn').then(function (r) {
        var replies = list(r.json && r.json.replies, 3, 9).map(strip);
        var about = r.json && r.json.about;
        if (mySession !== session || !state.turn || state.turn.asked !== asked) return;
        if (about === 'wearer') {
          // Reminders of what the wearer said: fewer than three, or none, is a true answer too.
          state.turn = { asked: asked, replies: replies, kind: 'recall' };
        } else {
          if (replies.length < 2) return;
          state.turn = { asked: asked, replies: replies };
        }
        emit();
      }).catch(function (err) { fail('deep', err); });
    }

    // ----- deep lane: the visual and the question -----
    function pumpDeep(atPause) {
      if (deepBusy || !deepDirty || state.phase !== 'live') return;
      var total = totalWords();
      if (total < 10) return;
      var gap = !state.scene ? 0 : atPause === true ? cfg.deepPauseGapMs : cfg.deepMinGapMs;   // the first picture is never held back
      if (now() - lastDeepAt < gap) return;                 // tick() comes back for it
      deepBusy = true; deepDirty = false; wordsAtLastDeep = total;
      state.thinking = true; emit();
      var mySession = session, myEpoch = deepEpoch, hadScene = !!state.scene, again = false;
      var prev = state.scene ? JSON.stringify(state.scene) : 'none yet';
      var ctx = currentEvent();
      var who = explainer();
      var user = (ctx ? 'CONTEXT: the wearer\'s calendar says this is "' + ctx.title + '".\n\n' : '') +
        'CONVERSATION SO FAR:\n' + transcriptText(3000) +
        '\n\nNEWEST WORDS:\n' + lastWords(45) +
        '\n\nTHE HEADLINE ON THE LENS: ' + (heldGist || state.headline || 'none yet') +
        '\nPREVIOUS VISUAL: ' + prev +
        '\nPREVIOUS QUESTION' + (who && state.ask ? (state.askFor === 'me' ? ' (one the wearer should expect)' : ' (one for the wearer to ask)') : '') +
        ': ' + (state.ask || 'none') +
        (who ? explainerLine(who) : '');
      callJSON('deep', DEEP_SYSTEM, user, DEEP_SCHEMA, 'gist_deep').then(function (r) {
        state.perf.deepMs = state.perf.deepMs.concat(r.ms).slice(-12);
        if (mySession !== session || myEpoch !== deepEpoch) return;   // the talk has moved on since this was asked
        var d = cleanDeep(r.json, state);
        // Now and then the model announces a picture and sends none. Ask once more straight away.
        var said = r.json && r.json.change;
        if ((said === 'new' || said === 'grow') && !d.drew && emptyDeeps < 1) { emptyDeeps += 1; again = true; } else emptyDeeps = 0;
        var askBefore = state.ask;
        state.scene = d.scene; state.ask = d.ask;
        // With the wearer explaining, the question is one to expect from the listener, not one to ask.
        // When nobody can tell who is explaining, a question that stayed word for word keeps its kind.
        if (!d.ask) state.askFor = '';
        else if (d.kept) { /* as it was */ }
        else if (who === 'me') state.askFor = 'me';
        else if (who === 'them' || d.ask !== askBefore) state.askFor = '';
        // The headline and the picture must be about the same thing. When the picture starts over on its
        // own while the headline has stood still for a while (or there is no headline yet), the headline
        // follows the picture.
        if (d.point && (!state.headline || (d.fresh && hadScene && now() - headlineAt > cfg.headlineStaleMs))) setHeadline(d.point, true);
      }).catch(function (err) { fail('deep', err); })
        .finally(function () {
          deepBusy = false; lastDeepAt = now();
          if (mySession !== session) return;
          if (myEpoch !== deepEpoch || again) { lastDeepAt = 0; deepDirty = true; pumpDeep(); return; }
          state.thinking = false; emit();
        });
    }

    // ----- conversation lifecycle -----
    function startConversation() {
      session++;
      transcript = []; fastUpTo = 0; fastWaiting = 0; deepDirty = false; wordsAtLastDeep = 0; lastAsked = '';
      headlineAt = 0; heldGist = ''; wordsAtHeadline = 0;
      state.phase = 'live'; phaseAt = now(); state.startedAt = now();
      state.headline = ''; state.term = null; state.scene = null; state.ask = ''; state.askFor = ''; state.turn = null; state.seen = null;
      state.recap = null; state.brief = null; state.thinking = false; state.notice = null;
    }

    function endConversation(reason) {
      if (state.phase !== 'live') return;
      session++;
      var text = transcriptText(7000);
      var enough = totalWords() >= cfg.minWordsForRecap;
      transcript = []; fastUpTo = 0; fastWaiting = 0; deepDirty = false; heldGist = '';   // the words themselves are not kept
      state.turn = null; state.thinking = false;
      if (!enough) {
        state.headline = ''; state.term = null; state.scene = null; state.ask = ''; state.askFor = ''; state.seen = null;
        state.phase = 'standby'; phaseAt = now(); refreshNext(); emit(); return;
      }
      state.phase = 'recap'; phaseAt = now(); state.recap = null; state.thinking = true; emit();
      var mySession = session;
      callJSON('deep', RECAP_SYSTEM, 'TRANSCRIPT:\n' + text, RECAP_SCHEMA, 'gist_recap').then(function (r) {
        if (mySession !== session) return;
        var rc = cleanRecap(r.json);
        state.recap = rc;
        memory.unshift({ at: now(), title: rc.title, points: rc.points, actions: rc.actions, open: rc.open });
        memory = memory.slice(0, 8);
        refreshOpen();
        preps = {};                       // the next brief should know about what was just agreed
        if (opts.onMemory) { try { opts.onMemory(memory); } catch (e) { /* host storage is best effort */ } }
      }).catch(function (err) {
        fail('deep', err);
        if (mySession === session) state.recap = { title: state.headline || 'Conversation', points: [], actions: [], open: state.ask || '' };
      }).finally(function () {
        if (mySession === session) { state.thinking = false; phaseAt = now(); emit(); }
      });
    }

    function refreshOpen() {
      var out = [];
      memory.forEach(function (m) { (m.actions || []).forEach(function (a) { if (out.length < 3) out.push(a); }); });
      state.open = out;
    }

    // ----- the day: next event and the pre-brief -----
    function currentEvent() {
      var t = now();
      for (var i = 0; i < day.length; i++) if (day[i].start <= t + 5 * 60000 && day[i].end > t) return day[i];
      return null;
    }
    function nextEvent() {
      var t = now(), best = null;
      day.forEach(function (e) { if (e.end > t && (!best || e.start < best.start)) best = e; });
      return best;
    }
    function clock(ms) {
      var d = new Date(ms);
      return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
    }
    function refreshNext() {
      var e = nextEvent();
      state.next = e ? { id: e.id, title: words(e.title, 7), at: clock(e.start), inMin: Math.round((e.start - now()) / 60000), where: words(e.location, 4) } : null;
    }
    // What to have ready for one event. Worked out once and kept, so the brief itself is instant.
    function prepFor(e) {
      if (preps[e.id] && preps[e.id].length) return Promise.resolve(preps[e.id]);
      var user = 'EVENT: ' + e.title + '\nSTARTS: ' + clock(e.start) + (e.location ? '\nWHERE: ' + e.location : '') +
        (e.notes ? '\nNOTES: ' + String(e.notes).slice(0, 600) : '') +
        (state.open.length ? '\n\nUNFINISHED FROM EARLIER CONVERSATIONS:\n- ' + state.open.join('\n- ') : '');
      return callJSON('deep', BRIEF_SYSTEM, user, BRIEF_SCHEMA, 'gist_brief').then(function (r) {
        var prep = list(r.json && r.json.prep, 3, 8).map(strip);
        if (prep.length) preps[e.id] = prep;
        return prep;
      });
    }
    function makeBrief(e) {
      briefed[e.id] = true;
      var mySession = session;
      var ready = preps[e.id] || [];
      state.phase = 'brief'; phaseAt = now(); state.thinking = !ready.length;
      state.brief = { title: words(e.title, 7), at: clock(e.start), inMin: Math.round((e.start - now()) / 60000), where: words(e.location, 4), prep: ready };
      emit();
      if (ready.length) return;
      prepFor(e).then(function (prep) {
        if (mySession !== session || !state.brief) return;
        state.brief.prep = prep;
      }).catch(function (err) { fail('deep', err); })
        .finally(function () { if (mySession === session) { state.thinking = false; phaseAt = now(); emit(); } });
    }

    // ---------- public API ----------
    var api = {
      version: VERSION,
      state: function () { return state; },

      // New speech, already transcribed. `who` is 'me' when the host knows the words were the wearer's
      // own, 'them' when it knows they were someone else's, and anything else when it cannot tell.
      // `number` is the host's own count of the piece, so a later relabel can find it.
      heard: function (text, who, number) {
        text = String(text || '').replace(/\s+/g, ' ').trim();
        if (!text || !state.listening) return;
        if (state.phase !== 'live') startConversation();
        lastSpeechAt = now();
        transcript.push({ t: lastSpeechAt, text: text, who: who === 'me' || who === 'them' ? who : '', n: number > 0 ? number : 0 });
        fastWaiting += 1;
        deepDirty = true;
        pumpFast();
        // The deep lane waits for a little new material rather than firing on every word.
        if (totalWords() - wordsAtLastDeep >= 6 || !state.scene) pumpDeep();
      },

      // The host could not tell whose voice some earlier pieces were when it heard them, and now can
      // (it needed to hear both voices first). `labels` maps piece numbers to 'me' or 'them'. Only
      // pieces that had no label get one; nothing is redrawn, the next model call simply knows more.
      relabel: function (labels) {
        if (!labels || typeof labels !== 'object') return;
        transcript.forEach(function (x) {
          var who = x.n ? labels[x.n] : null;
          if (!x.who && (who === 'me' || who === 'them')) x.who = who;
        });
      },

      // What the wearer is looking at (JPEG, base64). Only hosts with a camera call this.
      // `quiet` is a look nobody asked for: it says nothing unless it finds something new worth reading.
      look: function (jpegBase64, quiet) {
        if (!jpegBase64 || !state.listening || lookBusy) return Promise.resolve(null);
        lookBusy = true;
        var mySession = session;
        lastLookAt = now();
        if (!quiet) { state.notice = { kind: 'look', text: 'Reading what you see' }; noticeUntil = now() + 30000; emit(); }
        var last = state.seen ? state.seen.note + (state.seen.facts.length ? ' (' + state.seen.facts.join('; ') + ')' : '') : 'nothing yet';
        var system = quiet ? GLANCE_SYSTEM : LOOK_SYSTEM;
        var user = quiet ? 'ALREADY SEEN: ' + last + '\nWhat is the wearer looking at?' : 'What is the wearer looking at?';
        return callJSON('deep', system, user, LOOK_SCHEMA, 'gist_look', jpegBase64).then(function (r) {
          var note = strip(words(r.json && r.json.note, 9));
          var facts = list(r.json && r.json.facts, 3, 7).map(strip);
          if (mySession !== session) return null;
          if (state.notice && state.notice.kind === 'look') state.notice = null;
          var again = !!state.seen && sameNote(state.seen.note, note);
          if (hasLetters(note) && !(quiet && again)) {
            state.seen = { note: note, facts: facts, at: now() };
            state.notice = { kind: 'seen', text: note }; noticeUntil = now() + 8000;
            if (state.phase === 'live' && !again) {
              transcript.push({ t: now(), text: '[Seen: ' + note + (facts.length ? ' — ' + facts.join('; ') : '') + ']' });
              deepDirty = true; wordsAtLastDeep = 0; lastDeepAt = 0; pumpDeep(true);
            }
          } else if (!quiet && !hasLetters(note)) {
            state.notice = { kind: 'look', text: 'Nothing to read there' }; noticeUntil = now() + 4000;
          }
          emit();
          return state.seen;
        }).catch(function (err) {
          fail('deep', err);
          if (state.notice && state.notice.kind === 'look') state.notice = null;
          emit(); return null;
        }).finally(function () { lookBusy = false; });
      },

      // The host is about to take a photo: say so at once, before the picture has arrived.
      lookSoon: function () {
        if (!state.listening) return;
        state.notice = { kind: 'look', text: 'Looking' }; noticeUntil = now() + 6000; emit();
      },

      // The host has something short to tell the wearer: the microphone changed, looking was paused.
      tell: function (text, ms) {
        text = strip(words(text, 8));
        if (!text) return;
        state.notice = { kind: 'host', text: text }; noticeUntil = now() + (Number(ms) || 6000); emit();
      },

      setListening: function (on) {
        on = !!on;
        if (state.listening === on) return;
        state.listening = on;
        if (!on) { fastUpTo = transcript.length; fastWaiting = 0; }   // anything not yet sent is dropped, not queued
        emit();
      },

      end: function () { endConversation('asked'); },

      setDay: function (events) {
        day = (Array.isArray(events) ? events : []).filter(function (e) { return e && e.title && e.start; }).map(function (e, i) {
          return { id: String(e.id || i), title: String(e.title), start: Number(e.start), end: Number(e.end || e.start + 3600000), location: String(e.location || ''), notes: String(e.notes || '') };
        }).sort(function (a, b) { return a.start - b.start; });
        refreshNext(); emit();
      },

      briefNow: function () {
        var e = nextEvent();
        if (e && state.phase !== 'live') makeBrief(e);
        return !!e;
      },

      // The rest of today as a list, each event with its prep, for the phone's Today view.
      // onUpdate is called with the list straight away and again as each prep arrives.
      planDay: function (onUpdate) {
        var t = now();
        var upcoming = day.filter(function (e) { return e.end > t; }).slice(0, 5);
        function snapshot() {
          return upcoming.map(function (e) {
            return { id: e.id, title: e.title, start: e.start, end: e.end, at: clock(e.start), where: e.location, prep: preps[e.id] || [] };
          });
        }
        function tell() { if (onUpdate) { try { onUpdate(snapshot()); } catch (err) { /* host is best effort */ } } }
        var chain = Promise.resolve();
        upcoming.forEach(function (e) {
          chain = chain.then(function () { return prepFor(e); }).then(tell, function (err) { fail('deep', err); });
        });
        tell();
        return chain.then(snapshot);
      },

      setHost: function (info) {
        var was = state.host && state.host.ears;
        state.host = Object.assign({}, state.host, info || {});
        // Listening has just been switched on: an old recap or brief makes way, so the wearer sees at once that it took.
        var now_ = state.host.ears;
        if (now_ && now_ !== 'none' && (!was || was === 'none') && (state.phase === 'recap' || state.phase === 'brief') && !state.thinking) {
          state.phase = 'standby'; phaseAt = now(); refreshNext();
        }
        emit();
      },

      loadMemory: function (m) { memory = Array.isArray(m) ? m.slice(0, 8) : []; refreshOpen(); emit(); },
      memory: function () { return memory; },
      forget: function () {
        session++; transcript = []; fastUpTo = 0; fastWaiting = 0; heldGist = ''; memory = []; briefed = {}; preps = {};
        state.open = []; state.recap = null; state.brief = null; state.seen = null;
        state.headline = ''; state.term = null; state.scene = null; state.ask = ''; state.askFor = ''; state.turn = null; state.thinking = false;
        state.phase = 'standby'; phaseAt = now();
        if (opts.onMemory) { try { opts.onMemory(memory); } catch (e) { /* best effort */ } }
        emit();
      },

      // Call about once a second.
      tick: function () {
        var t = now();
        if (state.term && termAt && t - termAt > 15000) { state.term = null; emit(); }
        if (state.notice && (state.notice.kind === 'seen' || state.notice.kind === 'look' || state.notice.kind === 'host') && t > noticeUntil) { state.notice = null; emit(); }
        if (state.phase === 'live' && lastSpeechAt && t - lastSpeechAt > cfg.silenceEndMs) return endConversation('silence');
        if (state.phase === 'live' && heldGist && t - headlineAt >= cfg.headlineHoldMs) { setHeadline(heldGist, true); emit(); }
        if (state.phase === 'live' && fastWaiting && !fastBusy) pumpFast();   // a short line that waited for company
        if (state.phase === 'live' && deepDirty && !deepBusy) pumpDeep(t - lastSpeechAt > 1400);   // sooner when the speaker has paused
        if (state.phase === 'recap' && !state.thinking && t - phaseAt > cfg.recapHoldMs) { state.phase = 'standby'; phaseAt = t; refreshNext(); return emit(); }
        if (state.phase === 'brief' && !state.thinking && t - phaseAt > cfg.briefHoldMs) { state.phase = 'standby'; phaseAt = t; refreshNext(); return emit(); }
        if (state.phase === 'standby') {
          var before = JSON.stringify(state.next);
          refreshNext();
          var e = nextEvent();
          if (e && state.listening && !briefed[e.id] && e.start - t <= 10 * 60000 && e.start - t > -5 * 60000) return makeBrief(e);
          if (before !== JSON.stringify(state.next)) emit();
        }
      },

      // For benchmarking a model + thinking level on a fixed input without touching the live state.
      bench: function (tier, model, effort, transcriptSample, image) {
        var saved = { model: cfg[tier].model, effort: cfg[tier].effort };
        cfg[tier].model = model || saved.model; cfg[tier].effort = effort || saved.effort;
        var p = image
          ? callJSON(tier, LOOK_SYSTEM, 'What is the wearer looking at?', LOOK_SCHEMA, 'gist_look', image)
          : tier === 'fast'
            ? callJSON('fast', FAST_SYSTEM, 'TRANSCRIPT SO FAR:\n' + transcriptSample.split(/(?<=[.!?])\s+/).slice(0, -2).join('\n') + '\n\nNEWEST WORDS:\n' + transcriptSample.split(/(?<=[.!?])\s+/).slice(-2).join('\n') + '\n\nPREVIOUS GIST: none yet\nQUESTION THE LENS SUGGESTED: none', FAST_SCHEMA, 'gist_fast')
            : callJSON('deep', DEEP_SYSTEM, 'CONVERSATION SO FAR:\n' + transcriptSample.split(/(?<=[.!?])\s+/).join('\n') + '\n\nNEWEST WORDS:\n' + transcriptSample.split(/\s+/).slice(-45).join(' ') + '\n\nTHE HEADLINE ON THE LENS: none yet\nPREVIOUS VISUAL: none yet\nPREVIOUS QUESTION: none', DEEP_SCHEMA, 'gist_deep');
        cfg[tier].model = saved.model; cfg[tier].effort = saved.effort;   // restored right away: the request body is already built
        return p.then(function (r) {
          return { ms: r.ms, model: r.model, effort: effort || saved.effort, usage: r.usage, raw: r.json, clean: image ? r.json : tier === 'fast' ? cleanFast(r.json) : cleanDeep(r.json, null) };
        });
      },

      config: function () { return { fast: cfg.fast, deep: cfg.deep }; },
      setModels: function (m) {
        if (m && m.fast) Object.assign(cfg.fast, m.fast);
        if (m && m.deep) Object.assign(cfg.deep, m.deep);
      },
    };
    return api;
  }

  // The same moment as plain text: for a display that only takes text, for a screen reader,
  // and (say) for glasses with no display at all, where the question is spoken instead.
  function sceneLine(sc) {
    if (!sc) return '';
    if (sc.kind === 'map') {
      var names = {};
      sc.nodes.forEach(function (n) { names[n.id] = n.label; });
      return sc.edges.length ? sc.edges.map(function (e) { return names[e.from] + ' → ' + names[e.to]; }).join(' · ')
        : sc.nodes.map(function (n) { return n.label; }).join(' · ');
    }
    if (sc.kind === 'loop') return sc.nodes.map(function (n) { return n.label; }).join(' → ') + ' → …';
    if (sc.kind === 'steps') return sc.steps.map(function (x, i) { return (i + 1) + ' ' + x; }).join(' › ');
    if (sc.kind === 'compare') return sc.left.title + ' vs ' + sc.right.title;
    if (sc.kind === 'stats') return sc.stats.map(function (x) { return x.value + ' ' + x.label; }).join(' · ');
    if (sc.kind === 'points') return sc.points.join(' · ');
    return '';
  }
  function plain(s) {
    var out = { title: '', sub: '', body: '', say: '' };
    if (!s) return out;
    if (s.phase === 'live' && s.turn) {
      var recall = s.turn.kind === 'recall';
      out.title = s.turn.asked; out.sub = !s.turn.replies.length ? 'They asked you' : recall ? 'You already said' : 'You could say';
      out.body = s.turn.replies.map(function (r, i) { return (i + 1) + '. ' + r; }).join('\n');
      out.say = s.turn.replies.length ? (recall ? 'You said: ' : 'You could say: ') + s.turn.replies[0] : '';
    } else if (s.phase === 'live') {
      out.title = s.headline || 'Listening for the point';
      out.sub = sceneLine(s.scene) || (s.term ? s.term.word + ': ' + s.term.means : '');
      var lead = s.askFor === 'me' ? 'Expect: ' : 'Ask: ';
      out.body = s.ask ? lead + s.ask : '';
      out.say = s.ask ? lead + s.ask : '';
    } else if (s.phase === 'brief' && s.brief) {
      out.title = s.brief.title;
      out.sub = (s.brief.inMin > 0 ? 'In ' + s.brief.inMin + ' min' : 'Now') + (s.brief.where ? ' · ' + s.brief.where : '');
      out.body = s.brief.prep.join('\n');
      out.say = s.brief.prep.length ? out.sub.replace(' · ', ', ') + ': ' + s.brief.title + '. ' + s.brief.prep[0] : '';
    } else if (s.phase === 'recap') {
      out.title = s.recap ? s.recap.title : 'Writing the recap';
      out.sub = 'Conversation ended';
      out.body = s.recap ? s.recap.points.concat(s.recap.actions.map(function (a) { return 'To do: ' + a; })).join('\n') : '';
      out.say = s.recap && s.recap.actions.length ? 'For you: ' + s.recap.actions[0] : '';
    } else {
      out.title = s.next ? s.next.at + '  ' + s.next.title : 'Standing by';
      out.sub = s.listening ? 'Listening for a conversation' : 'Paused';
      out.body = (s.open || []).map(function (a) { return 'Open: ' + a; }).join('\n');
    }
    return out;
  }

  root.GistCore = { VERSION: VERSION, create: create, cleanFast: cleanFast, cleanDeep: cleanDeep, cleanRecap: cleanRecap, plain: plain };
})(typeof globalThis !== 'undefined' ? globalThis : this);
