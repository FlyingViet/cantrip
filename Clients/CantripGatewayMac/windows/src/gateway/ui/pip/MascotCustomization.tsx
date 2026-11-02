// The body of the "Customize Mascot" sheet: CantripMascotCustomizationView. A live preview, a mood
// row to try Pip's expressions, the name and the outfit ("Looks") grid. Saved on this device.
import { h, type JSX, type TargetedInputEvent } from "preact";
import { useEffect, useId, useRef, useState } from "preact/hooks";
import {
  AudioWaveform, Cog, Ear, FaceSlightlySmiling, MessageCircleQuestionMark, MessageCircleWarning, MoonStar, PenLine, Search,
  Sparkles,
} from "lucide";
import {
  DEFAULT_MASCOT_NAME, MASCOT_NAME_MAX_LENGTH, MOODS, OUTFITS, graphemes, moodTitle, outfitFor, type MascotMood,
} from "./mascot";
import { Pip } from "./Pip";
import { mascotDisplayName, mascotName, mascotOutfit, resetMascotName, setMascotName, setMascotOutfit } from "./prefs";
import "./pip.css";

type IconNode = [string, Record<string, string | number | undefined>][];

/** Lucide stand-ins for the Swift mood's `systemImage`. */
const MOOD_ICONS: Record<MascotMood, IconNode> = {
  idle: FaceSlightlySmiling, // face.smiling
  thinking: Sparkles, // sparkles
  searching: Search, // magnifyingglass
  working: Cog, // gearshape.2
  writing: PenLine, // pencil.line
  listening: Ear, // ear
  speaking: AudioWaveform, // waveform
  curious: MessageCircleQuestionMark, // questionmark.bubble
  concerned: MessageCircleWarning, // exclamationmark.bubble
  sleeping: MoonStar, // moon.zzz
};

function MoodIcon(props: { node: IconNode }): JSX.Element {
  return (
    <svg class="pip-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {props.node.map(([tag, attrs], index) => h(tag, { key: index, ...attrs }))}
    </svg>
  );
}

/** `checkmark.circle.fill` in the accent color. */
function SelectedBadge(): JSX.Element {
  return (
    <svg class="pip-check" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="11" fill="currentColor" />
      <path d="m7 12.5 3.2 3.2L17 8.8" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

/** Arrow keys, Home and End move the choice within a radio group, focusing the newly chosen item. */
function onRadioKeys(event: KeyboardEvent, count: number, current: number, choose: (index: number) => void): void {
  let next: number;
  switch (event.key) {
    case "ArrowRight":
    case "ArrowDown":
      next = (current + 1) % count;
      break;
    case "ArrowLeft":
    case "ArrowUp":
      next = (current - 1 + count) % count;
      break;
    case "Home":
      next = 0;
      break;
    case "End":
      next = count - 1;
      break;
    default:
      return;
  }
  event.preventDefault();
  choose(next);
  const group = event.currentTarget as HTMLElement;
  group.querySelectorAll<HTMLElement>('[role="radio"]')[next]?.focus();
}

export function MascotCustomization(props: { onDone: () => void }): JSX.Element {
  const outfit = outfitFor(mascotOutfit.value);
  const name = mascotDisplayName.value;
  const [previewMood, setPreviewMood] = useState<MascotMood>("idle");
  const [draft, setDraftState] = useState(() => (mascotName.peek() === "" ? DEFAULT_MASCOT_NAME : mascotDisplayName.peek()));
  const draftRef = useRef(draft);
  const inputRef = useRef<HTMLInputElement>(null);
  const moodsRef = useRef<HTMLDivElement>(null);
  const ids = useId();
  const nameHeading = `${ids}-name`;
  const nameNote = `${ids}-name-note`;
  const looksHeading = `${ids}-looks`;

  const setDraft = (value: string) => {
    draftRef.current = value;
    setDraftState(value);
  };

  const commitName = () => setDraft(setMascotName(draftRef.current));

  // `.onDisappear(perform: commitName)`
  useEffect(() => () => void setMascotName(draftRef.current), []);

  // A mouse wheel scrolls the horizontal mood row (the Mac gets this from the trackpad).
  useEffect(() => {
    const row = moodsRef.current;
    if (!row) return;
    const onWheel = (event: WheelEvent) => {
      if (event.deltaX !== 0 || event.deltaY === 0 || row.scrollWidth <= row.clientWidth) return;
      const max = row.scrollWidth - row.clientWidth;
      if ((event.deltaY < 0 && row.scrollLeft <= 0) || (event.deltaY > 0 && row.scrollLeft >= max - 1)) return;
      event.preventDefault();
      row.scrollLeft += event.deltaY;
    };
    row.addEventListener("wheel", onWheel, { passive: false });
    return () => row.removeEventListener("wheel", onWheel);
  }, []);

  const onNameInput = (event: TargetedInputEvent<HTMLInputElement>) => {
    const input = event.currentTarget;
    const characters = graphemes(input.value);
    if (characters.length > MASCOT_NAME_MAX_LENGTH) input.value = characters.slice(0, MASCOT_NAME_MAX_LENGTH).join("");
    setDraft(input.value);
  };

  const resetName = () => {
    resetMascotName();
    setDraft(DEFAULT_MASCOT_NAME);
    inputRef.current?.focus();
  };

  const done = () => {
    commitName();
    props.onDone();
  };

  const moodIndex = MOODS.indexOf(previewMood);
  const outfitIndex = OUTFITS.indexOf(outfit);

  return (
    <div class="pip-custom">
      <div class="pip-scroll">
        <div
          class="pip-preview"
          role="img"
          aria-label={`${name} in ${outfit.title}, ${moodTitle(previewMood).toLowerCase()}`}
        >
          <Pip mood={previewMood} outfit={outfit.id} size={168} />
          <div class="pip-preview-name">{name}</div>
          <div class="pip-preview-outfit">{outfit.title}</div>
        </div>

        <div
          ref={moodsRef}
          class="pip-moods"
          role="radiogroup"
          aria-label="Preview mood"
          onKeyDown={(event) => onRadioKeys(event, MOODS.length, moodIndex, (index) => setPreviewMood(MOODS[index]))}
        >
          {MOODS.map((mood) => {
            const selected = mood === previewMood;
            return (
              <button
                key={mood}
                type="button"
                role="radio"
                aria-checked={selected}
                tabIndex={selected ? 0 : -1}
                class={`pip-mood${selected ? " is-selected" : ""}`}
                aria-label={`Preview ${moodTitle(mood).toLowerCase()}`}
                onClick={() => setPreviewMood(mood)}
              >
                <MoodIcon node={MOOD_ICONS[mood]} />
                <span>{moodTitle(mood)}</span>
              </button>
            );
          })}
        </div>

        <section class="pip-section" aria-labelledby={nameHeading}>
          <h3 class="pip-heading" id={nameHeading}>Name</h3>
          <div class="pip-name-row">
            <input
              ref={inputRef}
              class="pip-name-input"
              type="text"
              value={draft}
              placeholder={DEFAULT_MASCOT_NAME}
              aria-label="Mascot name"
              aria-describedby={nameNote}
              autocomplete="off"
              autocapitalize="words"
              spellcheck={false}
              onInput={onNameInput}
              onBlur={commitName}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.isComposing) {
                  event.preventDefault();
                  commitName();
                }
              }}
            />
            {name !== DEFAULT_MASCOT_NAME ? (
              <button type="button" class="pip-reset" aria-label={`Reset name to ${DEFAULT_MASCOT_NAME}`} onClick={resetName}>
                Reset
              </button>
            ) : null}
          </div>
          <p class="pip-footnote" id={nameNote}>Shown in the Cantrip Home header and chat.</p>
        </section>

        <section class="pip-section" aria-labelledby={looksHeading}>
          <h3 class="pip-heading" id={looksHeading}>Looks</h3>
          <div
            class="pip-outfits"
            role="radiogroup"
            aria-labelledby={looksHeading}
            onKeyDown={(event) => onRadioKeys(event, OUTFITS.length, outfitIndex, (index) => setMascotOutfit(OUTFITS[index].id))}
          >
            {OUTFITS.map((option) => {
              const selected = option.id === outfit.id;
              return (
                <button
                  key={option.id}
                  type="button"
                  role="radio"
                  aria-checked={selected}
                  tabIndex={selected ? 0 : -1}
                  class={`pip-outfit${selected ? " is-selected" : ""}`}
                  aria-labelledby={`${ids}-${option.id}-title`}
                  aria-describedby={`${ids}-${option.id}-summary`}
                  onClick={() => setMascotOutfit(option.id)}
                >
                  <Pip mood="idle" outfit={option.id} size={92} frameTime={1} />
                  <span class="pip-outfit-title" id={`${ids}-${option.id}-title`}>{option.title}</span>
                  <span class="pip-outfit-summary" id={`${ids}-${option.id}-summary`}>{option.summary}</span>
                  {selected ? <SelectedBadge /> : null}
                </button>
              );
            })}
          </div>
          <p class="pip-footnote">Your choice is saved on this device and shows in Cantrip Home.</p>
        </section>
      </div>

      <div class="pip-footer">
        <button type="button" class="pip-done" onClick={done}>Done</button>
      </div>
    </div>
  );
}
