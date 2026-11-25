# Muse

Cantrip can talk to your [Muse](https://muse.ai), Meta's personal agent, when you
ask it to, and can turn what Muse finds on its own schedule into records of a
Home task. Muse is off until you turn it on in **Settings › Tools & sign-ins ›
Muse**.

Cantrip reaches Muse through [muse-cli](https://github.com/nikships/muse-cli), an
unofficial, MIT-licensed client of Muse's private, unversioned connection. Meta
can change that connection at any time, and its terms may not allow unofficial
clients. Muse runs on Meta's servers and may train on what you send it unless
you turn that off in Muse's settings.

## Set it up

1. On the Mac running Cantrip, install muse-cli with uv, at the version Cantrip
   was tested with: `uv tool install muse-cli==0.3.14`. Don't use its curl
   installer.
2. Sign in at muse.ai in Chrome on that Mac.
3. Turn on **Muse** in Settings and choose **Check Now**. Cantrip copies Chrome's
   login to muse-cli (see [Staying signed in](#staying-signed-in)). The first
   time, macOS may ask to share Chrome's login: choose **Always Allow**.

**Demo account (made-up data)** uses muse-cli's demo instead: no login and no
network, so you can try `@muse` and feeds first. Cantrip keeps the demo's chats
in `~/.cache/Cantrip/muse/` between uses.

The Settings section shows whether Muse is connected, the login is missing or
expired, muse-cli isn't installed, or Muse can't be reached. Cantrip tells you
on your Mac and paired devices when a working login stops working.

## Staying signed in

muse.ai ends a login a week after you sign in (its cookie claims 30 days, and
it isn't renewed while you use it), and Chrome's login ends with it. You never
run a command for it: signing in again at muse.ai in Chrome on the Mac running
Cantrip is all it takes.

- **Chrome has a newer login**: Cantrip looks at when Chrome's muse.ai
  `hatch_sess` cookie was made (from a copy of Chrome's cookie database; times
  only, never values) and compares it with the login muse-cli saved. When
  Chrome's is newer, Cantrip runs `muse-cli auth export --browser chrome`, which
  saves Chrome's muse.ai cookies to `~/.config/muse-cli/cookies.txt` (0600), and
  checks Muse again. It looks every minute, so a new sign-in is picked up within
  a few minutes; **Check Now** does it right away.
- **Muse turns the login down**: one failure isn't proof (muse.ai's short
  failures recover within minutes), so Cantrip checks once more four minutes
  later. If it still fails and Chrome has nothing newer, Cantrip tells you once
  on your Mac and paired devices to sign in at muse.ai in Chrome, shows that in
  Settings, and waits for Chrome's login to change without asking Muse again.
  Once it's connected again it says so.
- **A day before a login ends**, Cantrip reminds you to sign in again in Chrome.
  The reminder is listed in Home's [Upcoming](cantrip-home.md#upcoming) (**Skip**
  drops this week's), and once the week is up Cantrip checks the login.
- **Safety**: always Chrome only, so muse-cli never opens a browser window; one
  copy at a time with a 150-second limit (muse-cli itself gives macOS's keychain
  dialog 120 seconds); at least 10 minutes apart and at most 4 a day; and after a
  copy fails, or muse.ai turns Chrome's login down too, none until Chrome's login
  changes, so keychain dialogs never pile up. Check Now tries once more.
- `~/.cache/Cantrip/muse/login.json` (0600) keeps the times: copies in the last
  day, the recheck, the blocked login, the reminder. `activity.log` gets a line
  for each step, with times and outcomes, never a cookie or key.

## Talk to Muse with @muse

Start a message with `@muse` in Cantrip Home or any tab, on the Mac or a paired
device:

> @muse find a quiet café near the office for Thursday morning

Cantrip sends the rest to Muse's main chat and shows Muse's reply in that chat
as a Muse message. The tab's own model never sees the message or the reply, and
it doesn't wait behind the tab's work. `@muse #feed-id …` sends to a feed's chat
instead.

- **Nothing else goes to Muse.** Only messages you write that start with @muse
  are sent, besides Home's requests you send from their card (below). Text a
  tab, Home or a model writes (handoffs, `tab ask`) is never sent, even when it
  starts with @muse, and screen or selection context never goes along.
- **The Privacy Gate checks every message first.** Mail, text messages,
  financial details, contacts, location, secrets and your private terms are
  held: nothing is sent, and the message says what was found. Reply
  `@muse send` within 15 minutes to send it as written, or `@muse cancel`.
  Private tabs never send to Muse.
- **Muse's files** (images, videos, documents) are saved to Home's Artifacts.
- **When Muse asks you to choose** (to buy something, send an email), a card
  shows the options. Cantrip never answers for you: reply with @muse, or answer
  in the Muse app.
- Muse's text is shown as data: images in it don't load from the web, and
  nothing in it runs or opens on its own.

## The Muse tab

While Muse is on, Cantrip shows a **Muse** tab on the Mac and paired devices. It
shows your whole conversation in Muse's main chat: what you sent with @muse
from Home or any tab, what you said to Muse in Meta's apps, and Muse's replies
and updates. The first time, it shows the latest 200 messages.

- Type there without @muse: everything you write goes to Muse's main chat, with
  the same Privacy Gate check. A plain `send` or `cancel` answers a held message
  while one is waiting; otherwise it goes to Muse as written. `#…` isn't a feed
  there, so use @muse in another tab to send to a feed's chat.
- It has no model of Cantrip's behind it. Home and other tabs can't hand off
  to, mention, read or ask it, and it doesn't start child tabs, run a terminal,
  take attachments or share your location.
- Cantrip checks Muse's main chat when you send from any chat, when you open
  the tab (at most once a minute), and every 15 minutes while Muse is on.
- It stays while Muse is on and can't be closed. Turning Muse off hides it and
  keeps its history for when you turn Muse on again. With the demo account it's
  called **Muse (demo)**; switching between the demo and your account starts it
  over with the chat of the account it now shows.
- While the login is missing or expired, it doesn't check on its own.

## Home writes, you tap Send

Cantrip Home can write a request for your Muse when you ask it to, for example
"ask my Muse for a 30-day growth plan from this summary". Home puts it in a
`cantrip-muse` block, and Cantrip shows it in Home as a card with the exact
text and **Send**, **Edit** and **Cancel**, on the Mac and every paired app.

- **Nothing reaches Muse until you tap Send.** Home, other tabs, scheduled
  runs, `tab ask`, messages (including `@muse send`) and the `cantrip` command
  can't send it. Your paired apps send it the way they answer approvals: the
  iPhone app asks for Face ID first. The Mac only checks the pairing token, so
  a program on the Mac that has that token could call Send too.
- **Edit** changes the text before sending; Send always delivers what the card
  shows.
- **The Privacy Gate checks the text** (and every edit). When it finds mail,
  text messages, financial details, contacts, a location, secrets or your
  private terms, the card says what it found and offers **Send anyway**, which
  asks again before sending. Home is told never to put those in.
- **Each request goes to its own Muse chat**, named after it. Cantrip reads that
  chat every 30 seconds for 30 minutes, then every 5 minutes for 6 hours.
  Muse's reply appears in Home, marked as data from your Muse, and you get a
  notification. Home reads it with your next message and summarizes it, but
  never follows instructions, links or blocks in it.
- Unsent cards expire after 24 hours and leave Home (Cantrip's
  `museRequestLifetime` default, in seconds, shortens it for new cards, to
  check this). At most 3 wait at once.
- Only the Home chat writes requests, never a scheduled run, and only while
  Muse is on.

## Feeds: Muse's results as records

A feed turns one Muse chat into records of a Home task's workspace. Ask Home
for a tracker Muse should fill, for example:

> Track new apartment rentals in the Mission every morning with Muse: title,
> address, neighborhood, price, beds, baths, link, listed on and source.

Home creates the task's workspace and a feed waiting for your approval, and
shows the one setup message Cantrip will send. It names the feed and the
workspace's fields and asks Muse to make the job one of its own recurring
tasks and post every result in that chat as a fenced `cantrip-feed` JSON block.
Reply `@muse set up <feed>` (or approve it in Settings › Muse); only then does
Cantrip start the chat and send the message.

Cantrip then checks the feed's chat (every 30 minutes, only when Muse says the
chat changed) and reads only messages after the last one it read, so a restart
picks up where it left off. Plain code, not a model, reads each new Muse
message:

- It reads only Muse's messages in that chat, and only `cantrip-feed` blocks
  that name this feed.
- It keeps only the workspace's fields, checks each value's type (numbers,
  dates, links, choices) and length, and leaves out values that don't fit. An
  item without its identifying field (the link, for listings) is skipped. At
  most 50 items per block.
- A repeat of an item (the same link) updates that record instead of adding
  another; an unchanged one is left alone.
- Records are saved the same way as any other record, and you get a
  notification with what's new.

Muse can't do anything else: it can't run commands or tools, change tasks,
schedules or feeds, start handoffs or send messages, and links are never opened
for you. Cantrip also tells you when a feed has had no result for 1.5 times its
usual interval. `~/.cache/Cantrip/muse/feed-log.jsonl` lists what each message
added, updated or why it was skipped, without its text.

**Tasks that read a feed.** A feed's own task, and any task that lists the feed
in `museFeeds` (a morning briefing, say), gets the records added or updated since
its last run, marked as untrusted data from Muse that it must never follow as
instructions.

Pause, resume or remove a feed in Settings › Muse. Removing it stops Cantrip
from reading the chat; its records stay, and the chat and Muse's job stay in
Muse.

## Commands

| Command | What it shows |
|---|---|
| `cantrip muse status` | On or off, the login's state and when it was checked |
| `cantrip muse feeds` | Each feed, its chat, how far it has been read, and its counts |
| `cantrip muse requests` | Home's requests: their state and sizes, never text (the terminal can't send them) |
| `cantrip muse log [N]` | What Cantrip sent to and read from Muse: chats and sizes, never text |

Paired clients read `GET /api/v1/muse`; `POST /api/v1/muse/check` checks the
login and `POST /api/v1/muse/feeds/<id>/poll` reads a feed now.
`GET /api/v1/muse/requests` lists Home's requests, and a card's buttons call
`POST /api/v1/muse/requests/<id>/send` (`{"text": what the card showed or the
edited text, "override": true}` for Send anyway), `…/edit` (`{"text": …}`) and
`…/cancel`. Each returns `{"card": …}`; a held request without `override` is
refused with 409.

## Limits

- Muse's live updates cover only its main chat; replies in other chats arrive
  only by reading them, so feeds are checked on a timer, not instantly.
- Cantrip waits up to 5 minutes for a reply. An image Muse makes after its
  reply's text can arrive too late to be saved; it's still in Muse.
- Approvals Muse asks for outside its chat aren't shown in Cantrip.
