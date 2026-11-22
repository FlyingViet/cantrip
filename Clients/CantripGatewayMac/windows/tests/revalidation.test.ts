import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("../src/gateway/bridge", () => ({
  bridge: { key: "gateway-key", version: "test", platform: "win32", server: "", focused: true },
  isWindows: true,
}));

import { api, APIError, clearRevalidatedReads, REVALIDATED_READS } from "../src/gateway/api/client";

// The Mac tags successful JSON reads (a weak ETag of the body) and answers 304 with no body while the
// request's If-None-Match still matches. Fake tab list.
const listing = (title: string) => JSON.stringify({ sessions: [{ id: "tab-1", title }] });
const tag = (body: string) => `W/"${body.length.toString(16)}-${[...body].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7).toString(16)}"`;

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

function answer(status: number, body: string, etag?: string) {
  return Promise.resolve({
    ok: status >= 200 && status < 300, status,
    headers: new Headers(etag ? { etag } : {}),
    text: async () => body,
  });
}

/** A Mac holding `current`: 304 when the request names its tag, else the body and its tag. */
function mac(current: () => string) {
  fetchMock.mockImplementation((_url: string, init: RequestInit) => {
    const sent = (init.headers as Record<string, string>)["if-none-match"];
    const body = current();
    return sent === tag(body) ? answer(304, "", tag(body)) : answer(200, body, tag(body));
  });
}

const sentTag = (index: number) => ((fetchMock.mock.calls[index][1] as RequestInit).headers as Record<string, string>)["if-none-match"];

afterEach(() => {
  fetchMock.mockReset();
  clearRevalidatedReads();
});

describe("revalidated reads (If-None-Match)", () => {
  it("polls the tab list with the tag it holds and reuses the kept answer on 304", async () => {
    let body = listing("Garden");
    mac(() => body);
    expect(await api("/api/v1/sessions")).toEqual(JSON.parse(listing("Garden")));
    expect(sentTag(0)).toBeUndefined();

    expect(await api("/api/v1/sessions")).toEqual(JSON.parse(listing("Garden")));
    expect(sentTag(1)).toBe(tag(listing("Garden")));
    expect((await fetchMock.mock.results[1].value).status).toBe(304);

    // A 304 that doesn't repeat the tag keeps the one it confirmed.
    fetchMock.mockImplementationOnce(() => answer(304, ""));
    expect(await api("/api/v1/sessions")).toEqual(JSON.parse(listing("Garden")));
    await api("/api/v1/sessions");
    expect(sentTag(3)).toBe(tag(listing("Garden")));

    body = listing("Garden (renamed)");
    expect(await api("/api/v1/sessions")).toEqual(JSON.parse(listing("Garden (renamed)")));
    await api("/api/v1/sessions");
    expect(sentTag(5)).toBe(tag(listing("Garden (renamed)")));
    expect((await fetchMock.mock.results[5].value).status).toBe(304);
  });

  it("never tags writes, forgets failed reads and a new pairing, and keeps a bounded number", async () => {
    mac(() => listing("Garden"));
    await api("/api/v1/sessions");
    await api("/api/v1/sessions/tab-1/metadata", { method: "POST", body: { customTitle: "x" } });
    expect(sentTag(1)).toBeUndefined();

    fetchMock.mockImplementationOnce(() => answer(500, JSON.stringify({ error: "Busy" })));
    await expect(api("/api/v1/sessions")).rejects.toBeInstanceOf(APIError);
    await api("/api/v1/sessions");
    expect(sentTag(3)).toBeUndefined();

    await api("/api/v1/sessions");
    expect(sentTag(4)).toBe(tag(listing("Garden")));
    clearRevalidatedReads();
    await api("/api/v1/sessions");
    expect(sentTag(5)).toBeUndefined();

    for (let i = 0; i <= REVALIDATED_READS; i++) await api(`/api/v1/home/views/v${i}`);
    const before = fetchMock.mock.calls.length;
    await api("/api/v1/home/views/v0");
    expect(sentTag(before)).toBeUndefined();
    await api(`/api/v1/home/views/v${REVALIDATED_READS}`);
    expect(sentTag(before + 1)).toBe(tag(listing("Garden")));
  });
});
