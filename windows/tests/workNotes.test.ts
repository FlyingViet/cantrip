import { describe, expect, it } from "vitest";
import { latestNote, workFold, workLabel } from "../src/shared/home";

const NOTES = "Checking the build log first.\n\nFound the **failing** step.";
const ANSWER = "The build passed.\n\n```sh\nmake test\n\nmake app\n```\n\n- one fix";

describe("Home progress notes", () => {
  it("folds the Mac's note blocks above the answer", () => {
    const fold = workFold(`${NOTES}\n\n${ANSWER}`, { noteBlocks: 2, notes: 2, steps: 5, hasAnswer: true }, false);
    expect(fold).toMatchObject({ notes: NOTES, answer: ANSWER, working: false });
    expect(workLabel(fold!)).toBe("2 notes · 5 steps");
    expect(workLabel(workFold(`${NOTES}\n\n${ANSWER}`, { noteBlocks: 1, notes: 1, steps: 1, hasAnswer: true }, false)!))
      .toBe("1 note · 1 step");
  });

  it("reads Working with the latest note while the reply runs", () => {
    const fold = workFold(NOTES, { noteBlocks: 2, notes: 2, steps: 3, hasAnswer: false }, true);
    expect(fold && workLabel(fold)).toBe("Working · 3 steps");
    expect(latestNote(fold!.notes)).toBe("Found the **failing** step.");
  });

  it("leaves replies alone without a split, or when a finished reply has nothing after its notes", () => {
    expect(workFold(`${NOTES}\n\n${ANSWER}`, undefined, false)).toBeNull();
    expect(workFold(NOTES, { noteBlocks: 2, notes: 2, steps: 3, hasAnswer: false }, false)).toBeNull();
    expect(workFold(ANSWER, { noteBlocks: 0, notes: 0, steps: 2, hasAnswer: true }, false)).toBeNull();
  });
});
