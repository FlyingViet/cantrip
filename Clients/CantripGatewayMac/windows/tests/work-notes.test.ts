import { describe, expect, it } from "vitest";
import { latestNote, workFold, workSummary } from "../src/gateway/ui/transcript/workNotes";

const NOTES = "Checking the build log first.\n\nFound the **failing** step.";
const ANSWER = "The build passed.\n\n```sh\nmake test\n\nmake app\n```\n\n- one fix";

describe("progress notes fold above the answer", () => {
  it("cuts at the Mac's note blocks and counts notes and steps", () => {
    const fold = workFold(`${NOTES}\n\n${ANSWER}`, { noteBlocks: 2, notes: 2, steps: 5, hasAnswer: true }, false);
    expect(fold).toMatchObject({ notes: NOTES, answer: ANSWER, noteBlocks: 2, working: false });
    expect(workSummary(fold!.work)).toBe("2 notes · 5 steps");
    expect(workSummary({ noteBlocks: 1, notes: 1, steps: 1, hasAnswer: true })).toBe("1 note · 1 step");
  });

  it("shows Working and the latest note while the reply runs", () => {
    const fold = workFold(NOTES, { noteBlocks: 2, notes: 2, steps: 3, hasAnswer: false }, true);
    expect(fold?.working).toBe(true);
    expect(fold?.answer).toBe("");
    expect(latestNote(fold!.notes)).toBe("Found the **failing** step.");
  });

  it("leaves replies alone without a split, or when a finished run wrote nothing after its notes", () => {
    expect(workFold(`${NOTES}\n\n${ANSWER}`, undefined, false)).toBeNull();
    expect(workFold(NOTES, { noteBlocks: 2, notes: 2, steps: 3, hasAnswer: false }, false)).toBeNull();
    expect(workFold(ANSWER, { noteBlocks: 0, notes: 0, steps: 2, hasAnswer: true }, false)).toBeNull();
  });
});
