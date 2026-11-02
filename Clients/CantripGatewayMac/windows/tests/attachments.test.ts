import { describe, expect, it } from "vitest";
import { pastedFiles } from "../src/gateway/ui/transcript/fileKinds";

function clipboard(files: File[], text = ""): Pick<DataTransfer, "files" | "types" | "getData"> {
  const types = [...(text ? ["text/plain"] : []), ...(files.length ? ["Files"] : [])];
  return {
    files: files as unknown as FileList,
    types,
    getData: (type: string) => (type === "text/plain" ? text : ""),
  };
}

const screenshot = new File([new Uint8Array([1])], "image.png", { type: "image/png" });
const pdf = new File([new Uint8Array([1])], "Report.pdf", { type: "application/pdf" });
const video = new File([new Uint8Array([1])], "Clip.mp4", { type: "video/mp4" });

describe("pastedFiles", () => {
  it("attaches a copied screenshot, video or document", () => {
    expect(pastedFiles(clipboard([screenshot]))).toEqual([screenshot]);
    expect(pastedFiles(clipboard([video, pdf]))).toEqual([video, pdf]);
  });

  it("pastes text when the only other content is a picture of it", () => {
    expect(pastedFiles(clipboard([screenshot], "A1\tB1"))).toEqual([]);
    expect(pastedFiles(clipboard([], "hello"))).toEqual([]);
  });

  it("still attaches copied documents that come with text", () => {
    expect(pastedFiles(clipboard([pdf], "Report.pdf"))).toEqual([pdf]);
  });

  it("ignores blank text and an empty clipboard", () => {
    expect(pastedFiles(clipboard([screenshot], "  "))).toEqual([screenshot]);
    expect(pastedFiles(null)).toEqual([]);
  });
});
