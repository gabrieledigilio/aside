# Aside

Better with every conversation. While someone explains something to you, your glasses show the point so far, a small picture of the idea that changes shape with what is being said, and the one question worth asking. When they put a question to you, Aside offers three things you could say. Afterwards it keeps a short recap and what is left for you to do, and uses that to brief you before your next event.

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

Once the glasses are in reach the lens stands by on their display, with real buttons under it that the Neural Band can move between and press: **Listen** and **Brief me** when idle; **Look**, **End talk** and **Stop** during a conversation. The phone can stay in a pocket. If you would rather give the lens the whole display while someone is talking, Settings has "During a conversation, show them only after a pinch".

**The lens as a web app on the glasses.** Double-click **Start Gist + glasses link** instead of Start Gist. It opens a temporary public address for this Mac (a Cloudflare quick tunnel; the tool is downloaded the first time) and a setup page with two QR codes: A adds Aside to the glasses, B links the iPhone app to this Mac.

## How it follows a conversation

The fast lane does not echo the words. After each stretch of speech it first decides whether the line on the glasses is still a true answer to "what are they talking about right now?". Small talk, agreement, filler and misheard fragments leave the lens alone. A new claim sharpens the line. A new subject replaces it at once and clears the picture. The deep lane draws the idea on the table, keeps the picture through chit-chat, and changes scene when the shape of the idea changes (a map, a loop, steps, two sides, numbers). The glasses hear the wearer too. With the glasses' own microphones each line is marked as the wearer's or someone else's (see below); without that, both lanes are told that the transcript holds everyone's words with no speaker labels. An opinion or a disputed claim is shown as "Claim: ...", so the lens never states as fact what is only someone's view.

## Hearing the other person

The glasses' microphones sit on the frame, a few centimetres from the wearer's mouth, so the wearer arrives much louder than the person across the table, and a speech recogniser follows the loud voice and drops the quiet one. The SDK gives an app one sound feed with two settings (sample rate and channel count); there is no way to aim it at the person in front.

So Aside evens the voices out itself before the words are recognised ("Lift quiet voices" in Settings, on by default). Ten milliseconds at a time, quiet speech is lifted towards a normal level, up to twenty-four times, and a loud voice is held down. The lift comes back within a quarter of a second after the wearer stops talking, so the first words of a reply are not lost. The room's own hum is never lifted above a low ceiling, so a silence stays a silence and is not turned into noise the recogniser would try to read.

While it listens, the phone shows what the glasses hear: the last eight seconds of sound as a row of bars, exactly as it arrived; how much it is being lifted; and, if any, how many seconds of sound went missing on the way in the last minute (seconds of sound received, set against the clock).

**Whose voice.** The same fact that makes the other person hard to hear tells the voices apart. The wearer arrives fifteen to twenty decibels louder than anyone across a table, so each finished stretch of speech is marked "wearer", "other" or left open when both spoke, with no voice model and nothing to enrol. The gap is steady but the level is not (it moved by ten decibels between two sessions on the same evening), so nothing is assumed about how loud the wearer is: in each listening session Aside waits until it has heard both a loud voice and one at least twelve decibels quieter, draws the line halfway between them, and then also marks the lines it had left open before. When in doubt it marks nothing, because the mistake that matters is taking the other person for the wearer. The brain uses it three ways: a question only counts as put to the wearer when the other person asked it; when the wearer is the one explaining, the suggested question becomes the one to expect from the listener; and when the wearer is asked about their own subject, the lens shows what they already said about it and never an invented answer. The phone shows "You:" or "Them:" in front of each line it heard, so the marking can be checked at a glance.

In a loud room nothing replaces being close. "Listen with: This iPhone's microphone" is there for that: the phone goes next to the speaker, the glasses still show the lens, and the lens says which microphone is in use.

## Looking

**Look** takes one photo with the glasses' camera and reads what is in it: a slide, a screen, a whiteboard, a label. No photo is kept, and people are never described.

Aside can also look by itself every ten seconds during a conversation ("Look by itself" in Settings). It is off to begin with, because of what the real glasses showed: the same camera stream carries the microphones, and each photo stopped the sound for three to four seconds. Hearing matters more than seeing, so if it is switched on and a photo costs more than a second and a half of sound, Aside switches it off again and says so. Look still works when you press it.

## When the network or the link is bad

- A model request that has not answered within 1.5 s is also sent over mobile data, and after 3 s on a fresh connection. The first answer is used. While the Wi-Fi keeps losing that race, mobile data sets off a quarter of a second in instead. Settings, Brain has a one-tap test of the mobile data route.
- Frames for the display get smaller when Bluetooth is slow (600, 420, 300 px, then plain text) and larger again when it recovers.
- If the display stops taking frames, Aside starts it again; if that does not help and nothing else depends on the session, it opens a fresh one.

## When the glasses change state

| What happens | What Aside does |
| --- | --- |
| You tap the side of the glasses | The glasses pause the session: display dark, microphones off. Another tap carries on, and the lens says "Listening again". The phone shows which it is. |
| You press Stop | Only the camera (and with it the microphones) is let go. The session and the display stay, so the recap appears on the glasses at once and the next Listen is quick. |
| The camera stream stops by itself | A new camera is attached, up to three times. |
| The camera stream will not start, or stays down | After a few seconds Aside listens through the glasses' Bluetooth microphone instead and says so on the lens. The display stays on. It is still the glasses that listen, never the phone. |
| The glasses say they are too warm | Aside lets the camera go before the glasses cut the session, carries on over their Bluetooth microphone, and stops looking by itself. |
| The glasses are folded, switched off or out of reach | Listening stops with a plain message. When they are back, the lens stands by on them again without being asked. |
| Another glasses app takes the display | Aside returns a few seconds after it closes. Closed three times in a row, it stays away until you ask for it. |

## Models

Two lanes, both Meta Muse through the Model API (`https://api.meta.ai/v1`):

- headline, jargon and "your turn": `muse-ember-1.0`, low effort, about a second
- the picture, the question and the recap: `muse-wonder-1.0`, minimal effort, two to four seconds

Override them in `.env` (see `.env.example`). `muse-spark-1.3` costs about a third as much for the second lane and is slower.

## What Aside keeps, and what it does not

- Audio is turned into text and thrown away at once. It is never stored. iOS does the transcription on the phone itself when it can for the language; when it cannot, it uses Apple's dictation service. The app shows which while it listens.
- The words of a conversation live in memory only while it lasts. They go to the model to be understood, and are dropped when the conversation ends.
- What is kept is the recap: a title, up to three points, what is left for you to do, and what went unanswered. "Forget everything" erases it.
- With "Glasses microphones" the capture light on the glasses stays on while Aside listens. A tap on the side of the glasses pauses everything at once.
- A photo taken for Look is shrunk, sent to the model to be read, and dropped. It is never stored, and the model is told never to describe people.
- The Mac only answers its own browser. From outside it is reachable only through the link, and only with the link's code.


## Status on 14 November 2026

**Run on Ray-Ban Display with Neural Band, two pairs, about four hours in all (afternoon and evening, in the hall at Junction):** pairing in Developer Mode; the lens standing by on the display between conversations; the glasses' microphones through the camera stream, on a session kept from the conversation before; transcription on the iPhone; Muse on the venue Wi-Fi and, by itself, over mobile data; conversations followed from the first sentence to the recap; the recap kept; Look. When the camera stream would not start, Aside carried on through the glasses' Bluetooth microphone and said so, and the conversation was still followed.

**What the real glasses showed, and what was changed the same evening:**

| Seen on the glasses | What Aside does now |
| --- | --- |
| The wearer peaks near -8 dB at the microphones; a person across a table at -25 to -35 dB. The quiet voice was being dropped. | Quiet voices are lifted before recognition, up to twenty-four times, and the lift recovers within a quarter of a second after the wearer stops. |
| That gap is wide and steady, though the level itself moved by ten decibels between sessions. | Each stretch of speech is marked as the wearer's or someone else's, from loudness alone, with the line redrawn in every session. "Your turn" only fires on the other person's questions; when the wearer is the one explaining, the question box turns into the question to expect. |
| Each photo stopped the microphones for three to four seconds. | Looking by itself is off to begin with, and switches itself off if a photo costs sound. Look by hand still works. |
| At seven video frames a second the display's pictures fell to their smallest size (300 px). | Two frames a second, the least the glasses offer. The display stays at 600 px, and measured against the clock no sound goes missing. |
| Asking for two-channel sound gave no sound, and the stream then failed until the app was restarted. | Not asked for. One channel, 16 kHz. |
| A name the iPhone has never met came out as an ordinary word. | "Names to listen for" in Settings. |

**Run on the iPhone with Meta's simulated display glasses:** the buttons under the lens and how the lens fits above them; Listen, Stop and Listen again on one session; pause and resume from the touchpad; the glasses reporting heat; the glasses switched off and back on.

**Seen on the real glasses, not yet checked line by line:** whose-voice marking (the phone showed "You:" and "Them:" on the right lines in the conversations watched; the brain's use of it was checked against the real model with marked transcripts).

**Not yet confirmed on the real glasses:** the buttons pressed with the band, and a pinch opening the menu.
