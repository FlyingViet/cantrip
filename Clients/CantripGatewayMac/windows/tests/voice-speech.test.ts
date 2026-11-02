import { describe, expect, it } from "vitest";
import {
  cleanForSpeech, englishVoices, lastSpeakableCut, pickVoice, SpeechChunker, tableRowToSpeech, voiceDisplayName, voiceQuality,
} from "../src/gateway/ui/voice/speech";

describe("lastSpeakableCut", () => {
  it("cuts after the last sentence end followed by a space, newline or the end", () => {
    expect(lastSpeakableCut("Hello there. How are")).toBe(12);
    expect(lastSpeakableCut("One! Two? Three")).toBe(9);
    expect(lastSpeakableCut("Done.")).toBe(5);
    expect(lastSpeakableCut("no break yet")).toBeNull();
  });

  it("doesn't cut inside numbers or file names", () => {
    expect(lastSpeakableCut("Version 2.5 is")).toBeNull();
    expect(lastSpeakableCut("Open main.ts now")).toBeNull();
  });

  it("cuts after newlines and never at a period inside a table row", () => {
    expect(lastSpeakableCut("Para one\nPara")).toBe(9);
    expect(lastSpeakableCut("| Morning clouds. Sunny after. |")).toBeNull();
    expect(lastSpeakableCut("| a. b |\n| c. d")).toBe(9);
  });
});

describe("tableRowToSpeech", () => {
  it("reads the header, skips separators and labels later cells", () => {
    const state = { header: null as string[] | null };
    expect(tableRowToSpeech("| | Santa Clara | Mountain View |", state)).toBe("Santa Clara, Mountain View.");
    expect(tableRowToSpeech("|---|:---:|---|", state)).toBeNull();
    expect(tableRowToSpeech("| High | ~75°F | ~79°F |", state)).toBe("High: Santa Clara ~75°F, Mountain View ~79°F.");
    expect(tableRowToSpeech("| Low | | 60°F |", state)).toBe("Low: Mountain View 60°F.");
    expect(tableRowToSpeech("| Rain | | |", state)).toBe("Rain.");
  });
});

describe("cleanForSpeech", () => {
  it("strips emphasis, headings, quotes, code and list markers", () => {
    expect(cleanForSpeech("## Summary\n**Bold** and *italic* with `code`.\n> quoted")).toBe("Summary\nBold and italic with code.\nquoted");
    expect(cleanForSpeech("- first\n* second\n1. third\n2) fourth")).toBe("first\nsecond\nthird\nfourth");
  });

  it("keeps link titles, drops bare URLs, rules and code fences", () => {
    expect(cleanForSpeech("See [the docs](https://example.com/docs) or https://example.com/x now.")).toBe("See the docs or  now.");
    expect(cleanForSpeech("Above\n---\nBelow")).toBe("Above\n\nBelow");
    expect(cleanForSpeech("```swift\nlet x = 1\n```")).toBe("\nlet x = 1\n");
    expect(cleanForSpeech("![A chart](cantrip://image/1)")).toBe("A chart");
  });

  it("turns symbols into words", () => {
    expect(cleanForSpeech("Home → Tasks, ~5 min, 10–20 mph, 2026-06-10")).toBe("Home  to  Tasks, about 5 min, 10 to 20 mph, 2026-06-10");
  });

  it("reads tables as labeled sentences and forgets the header after the table", () => {
    const state = { header: null as string[] | null };
    const text = "| Day | High |\n|---|---|\n| Mon | 70 |\nAfter.\n| A | B |";
    expect(cleanForSpeech(text, state)).toBe("Day, High.\nMon: High 70.\nAfter.\nA, B.");
  });
});

describe("SpeechChunker", () => {
  it("speaks each finished sentence of a streaming reply once, then flushes the rest", () => {
    const chunker = new SpeechChunker();
    expect(chunker.next("Hello")).toBeNull();
    expect(chunker.next("Hello there. I'm")).toBe("Hello there.");
    expect(chunker.next("Hello there. I'm **Pip**.")).toBe("I'm Pip.");
    expect(chunker.next("Hello there. I'm **Pip**. Bye")).toBeNull();
    expect(chunker.next("Hello there. I'm **Pip**. Bye", true)).toBe("Bye");
    expect(chunker.next("Hello there. I'm **Pip**. Bye", true)).toBeNull();
  });

  it("keeps table headers across chunks and skips symbol-only chunks", () => {
    const chunker = new SpeechChunker();
    expect(chunker.next("| City | Temp |\n")).toBe("City, Temp.");
    expect(chunker.next("| City | Temp |\n|---|---|\n")).toBeNull();
    expect(chunker.next("| City | Temp |\n|---|---|\n| Paris | 20 |\n")).toBe("Paris: Temp 20.");
    chunker.reset();
    expect(chunker.next("Fresh.")).toBe("Fresh.");
  });
});

describe("reply voices", () => {
  const voices = [
    { name: "Microsoft Zira - English (United States)", lang: "en-US", voiceURI: "zira" },
    { name: "Microsoft Hedda - German (Germany)", lang: "de-DE", voiceURI: "hedda", default: true },
    { name: "Microsoft Aria Online (Natural) - English (United States)", lang: "en-US", voiceURI: "aria" },
    { name: "Microsoft David - English (United States)", lang: "en_US", voiceURI: "david" },
    { name: "Ava (Premium)", lang: "en-US", voiceURI: "ava" },
  ];

  it("lists English voices, best quality first, then by name", () => {
    expect(englishVoices(voices).map((voice) => voice.voiceURI)).toEqual(["ava", "aria", "david", "zira"]);
    expect(voiceQuality(voices[2])).toBe("Natural");
    expect(voiceQuality(voices[0])).toBe("Default");
  });

  it("picks the chosen voice, else the best English one, else the default", () => {
    expect(pickVoice(voices, "david")?.voiceURI).toBe("david");
    expect(pickVoice(voices, "missing")?.voiceURI).toBe("ava");
    expect(pickVoice(voices.filter((voice) => voice.voiceURI === "hedda"), "")?.voiceURI).toBe("hedda");
    expect(pickVoice([], "")).toBeNull();
  });

  it("shortens Windows voice names", () => {
    expect(voiceDisplayName(voices[0])).toBe("Microsoft Zira");
    expect(voiceDisplayName(voices[4])).toBe("Ava (Premium)");
  });
});
