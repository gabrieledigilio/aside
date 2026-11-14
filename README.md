# Aside

Comprehension, not captions. While someone explains something to you, your glasses show the point so far, a small picture of the idea that changes shape with what is being said, and the one question worth asking. When they put a question to you, Aside offers three things you could say. Afterwards it keeps a short recap and what is left for you to do, and uses that to brief you before your next event.

Built for Meta Ray-Ban Display (and, by voice, for Ray-Ban Meta Gen 2) at Junction 2026.

## What is in this folder

| Folder | What it is |
| --- | --- |
| `lens/` | The lens: one web page, 600×600, that draws the HUD. `gist-core.js` is the brain (prompts, model calls, the conversation's life cycle). The same files run on the Mac, in the iPhone app and in the glasses' own browser. |
| `brain/` | The Mac host: serves the lens, talks to the model with the key in `key.txt`, and can open an outside link for the glasses. No dependencies beyond Node 20. |
| `ios/` | The iPhone app. Listens through the glasses, turns speech into text on the phone, runs the same brain, and puts the lens on the glasses' display. |
| `samples/` | A sample explanation and the scripted answers used when there is no key. |

## Try it on the Mac

1. Double-click **Start Gist**. A browser opens on the lens.
2. Paste your Meta Model API key into `key.txt` (the key alone, nothing else) and save. Without a key Aside uses scripted answers, so the preview still works.
3. Press **Replay sample**, or **Test with this Mac's mic** and explain something.

`http://localhost:8787/gallery.html` shows every scene the lens can draw.

## Put it on the glasses

There are two ways, and they can be used together.

**The iPhone app** (`ios/Gist.xcodeproj`). Open it in Xcode, pick your team under Signing & Capabilities, choose your iPhone and press Run. In the app, tap *Connect glasses* (the Meta AI app must have Developer Mode on), then *Start listening*. Settings lists four ways to listen; "Glasses microphones" is the default. The model key goes into Settings, or is borrowed from the Mac by scanning code B below.

**The lens as a web app on the glasses.** Double-click **Start Gist + glasses link** instead of Start Gist. It opens a temporary public address for this Mac (a Cloudflare quick tunnel; the tool is downloaded the first time) and a setup page with two QR codes: A adds Aside to the glasses, B links the iPhone app to this Mac.

## How it follows a conversation

The fast lane does not caption. After each stretch of speech it first decides whether the line on the glasses is still a true answer to "what are they talking about right now?". Small talk, agreement, filler and misheard fragments leave the lens alone. A new claim sharpens the line. A new subject replaces it at once and clears the picture. The deep lane draws the idea on the table, keeps the picture through chit-chat, and changes scene when the shape of the idea changes (a map, a loop, steps, two sides, numbers). The glasses hear the wearer too, so both lanes are told that the transcript holds everyone's words with no speaker labels.

## When the network or the link is bad

- A model request that has not answered within 1.5 s is also sent over mobile data, and after 3 s on a fresh connection. The first answer is used. Settings, Brain has a one-tap test of the mobile data route.
- Frames for the display get smaller when Bluetooth is slow (600, 420, 300 px, then plain text) and larger again when it recovers.
- If the glasses' microphone goes away, Aside stops and says so. It never switches to the phone's microphone by itself.

## Models

Two lanes, both Meta Muse through the Model API (`https://api.meta.ai/v1`):

- headline, jargon and "your turn": `muse-ember-1.0`, low effort, about a second
- the picture, the question and the recap: `muse-wonder-1.0`, minimal effort, two to four seconds

Override them in `.env` (see `.env.example`). `muse-spark-1.3` costs about a third as much for the second lane and is slower.

## What Aside keeps, and what it does not

- Audio is turned into text and thrown away at once. It is never stored. iOS does the transcription on the phone itself when it can for the language; when it cannot, it uses Apple's dictation service. The app shows which while it listens.
- The words of a conversation live in memory only while it lasts. They go to the model to be understood, and are dropped when the conversation ends.
- What is kept is the recap: a title, up to three points, what is left for you to do, and what went unanswered. "Forget everything" erases it.
- With "Glasses microphones" the capture light on the glasses stays on while Aside listens. Pause is one tap on the phone.
- The Mac only answers its own browser. From outside it is reachable only through the link, and only with the link's code.


## Status on 14 November 2026

Run for two hours on a Ray-Ban Display with Neural Band: pairing in Developer Mode, the glasses' microphones through the camera stream, transcription on the iPhone, Muse, and the lens on the display at about half a second per frame. Not yet confirmed on the hardware: the pinch menu on the glasses, Look with the glasses' camera, and the mobile data route.
