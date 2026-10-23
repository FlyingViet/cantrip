// Cantrip Memory (CantripMemoryView.swift): the read-only memory files saved on the Mac. A searchable
// catalog in 50-file pages ("Load more files"), grouped by category, and a reader that pages through
// a file 16 KiB at a time, pinned to the file's revision.
import type { JSX } from "preact";
import { batch, useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { api } from "../../api/client";
import type { MemoryCatalog, MemoryEntry, MemoryPage } from "../../api/types";
import { formatBytes, unixDate } from "../../state/format";
import { Icon } from "../icons";
import { FormSection, Sheet } from "../kit";
import { Caption, Loading, RefreshButton, StatusLabel, Warning, useAlive } from "./common";
import {
  EMPTY_READER, InvalidResponseError, errorText, formatDateTime, isUnsupported, memoryCatalogPath, memoryCharacterCount,
  memoryDocumentPath, memoryEntriesByCategory, memoryName, memoryTitle, mergeCatalog, readerApply, readerRequest,
  validCatalogPage, validMemoryPage, type ReaderDirection, type ReaderState,
} from "./sheetLogic";

export function MemorySheet(props: { onClose: () => void }): JSX.Element | null {
  const catalog = useSignal<MemoryCatalog | null>(null);
  const loading = useSignal(false);
  const error = useSignal<string | null>(null);
  const [query, setQuery] = useState("");
  const loadedQuery = useRef("");
  const catalogRequest = useRef(0);
  const alive = useAlive();

  const opened = useSignal<MemoryEntry | null>(null);
  const reader = useSignal<ReaderState>(EMPTY_READER);
  const readerLoading = useSignal(false);
  const readerError = useSignal<string | null>(null);
  const readerGeneration = useRef(0);
  const openerID = useRef<string | null>(null);
  const listScroll = useRef(0);
  const root = useRef<HTMLDivElement>(null);
  const backButton = useRef<HTMLButtonElement>(null);
  const body = () => root.current?.closest<HTMLElement>(".sheet-body") ?? null;

  const loadCatalog = async (text: string, more = false) => {
    if (more && (loading.value || !catalog.value?.nextCursor)) return;
    if (text !== loadedQuery.current) catalog.value = null;
    loadedQuery.current = text;
    const cursor = more ? catalog.value?.nextCursor ?? null : null;
    const request = ++catalogRequest.current;
    loading.value = true;
    try {
      const value = await api<MemoryCatalog>(memoryCatalogPath(text, cursor));
      if (!alive.current || request !== catalogRequest.current) return;
      if (!validCatalogPage(value, cursor)) throw new InvalidResponseError();
      batch(() => {
        catalog.value = mergeCatalog(catalog.value, value, more);
        error.value = null;
      });
    } catch (failure) {
      if (!alive.current || request !== catalogRequest.current) return;
      error.value = isUnsupported(failure) ? "Update and reopen Cantrip on your Mac to view its saved memory." : errorText(failure);
    } finally {
      if (request === catalogRequest.current) loading.value = false;
    }
  };

  // Each search reloads the list (`.task(id: query)`); typing settles briefly first.
  const firstLoad = useRef(true);
  useEffect(() => {
    if (firstLoad.current) {
      firstLoad.current = false;
      void loadCatalog(query);
      return;
    }
    const timer = setTimeout(() => void loadCatalog(query), 250);
    return () => clearTimeout(timer);
  }, [query]);

  const loadPage = async (direction: ReaderDirection) => {
    const entry = opened.value;
    if (!entry || readerLoading.value) return;
    const request = readerRequest(reader.value, direction);
    if (!request) return;
    const generation = readerGeneration.current;
    readerLoading.value = true;
    try {
      const page = await api<MemoryPage>(memoryDocumentPath(entry.id, request.offset, request.revision));
      if (!alive.current || generation !== readerGeneration.current) return;
      if (!validMemoryPage(page, entry.id, request.offset, request.revision)) throw new InvalidResponseError();
      batch(() => {
        reader.value = readerApply(reader.value, direction, request, page);
        readerError.value = null;
      });
    } catch (failure) {
      if (!alive.current || generation !== readerGeneration.current) return;
      readerError.value = errorText(failure);
    } finally {
      if (generation === readerGeneration.current) readerLoading.value = false;
    }
  };

  const open = (entry: MemoryEntry) => {
    readerGeneration.current++;
    openerID.current = entry.id;
    listScroll.current = body()?.scrollTop ?? 0;
    batch(() => {
      opened.value = entry;
      reader.value = EMPTY_READER;
      readerError.value = null;
      readerLoading.value = false;
    });
    void loadPage("reload");
    requestAnimationFrame(() => backButton.current?.focus());
  };

  const back = () => {
    readerGeneration.current++;
    batch(() => {
      opened.value = null;
      readerLoading.value = false;
    });
    requestAnimationFrame(() => {
      const scroller = body();
      if (scroller) scroller.scrollTop = listScroll.current;
      const id = openerID.current;
      if (id) root.current?.querySelector<HTMLElement>(`[data-entry-id="${CSS.escape(id)}"]`)?.focus();
    });
  };

  // A new page starts at its top (the reader's `.id(revision:offset)`).
  const page = reader.value.page;
  useLayoutEffect(() => {
    if (opened.value && page) body()?.scrollTo({ top: 0 });
  }, [page?.revision, page?.offset]);

  const entry = opened.value;
  if (entry) {
    const count = page ? memoryCharacterCount(page) : null;
    return (
      <Sheet title={memoryName(entry)} label={`${memoryName(entry)}, Cantrip Memory`} onClose={props.onClose} width={720} height={680}
        leading={(
          <button ref={backButton} type="button" class="btn plain sh-back" aria-label="Back to Cantrip Memory" onClick={back}>
            <Icon name="chevron.left" />
            <span>Cantrip Memory</span>
          </button>
        )}
        actions={<RefreshButton label="Reload memory file" disabled={readerLoading.value} onClick={() => void loadPage("reload")} />}
        footer={page ? (
          <div class="sh-pager grow">
            <button type="button" class="btn" disabled={readerLoading.value || reader.value.pageIndex === 0}
              onClick={() => void loadPage("previous")}>Previous</button>
            <span class="grow caption muted" aria-live="polite">Page {reader.value.pageIndex + 1}</span>
            <button type="button" class="btn" disabled={readerLoading.value || page.nextOffset === undefined}
              onClick={() => void loadPage("next")}>Next</button>
          </div>
        ) : undefined}>
        <div ref={root} class="sh-reader">
          {readerError.value ? (
            <div class="sh-stack sh-intro">
              <Warning>{readerError.value}</Warning>
              {page ? <span class="caption">Showing previously loaded text.</span> : null}
              <div><button type="button" class="btn" disabled={readerLoading.value} onClick={() => void loadPage("reload")}>Reload file</button></div>
            </div>
          ) : null}
          {readerLoading.value ? <div class="sh-intro"><Loading text="Loading saved memory..." /></div> : null}
          {page ? (
            <div class="sh-reader-text sh-stack wide">
              <MemoryRow entry={page.document} />
              {count ? <span class={`sh-caption${count.over ? " sh-warning" : ""}`}>{count.text}</span> : null}
              <pre class="sh-pre" tabIndex={0} aria-label={`${memoryName(entry)} text`}>{page.text === "" ? "(Empty file)" : page.text}</pre>
            </div>
          ) : null}
        </div>
      </Sheet>
    );
  }

  const list = catalog.value;
  const groups = list ? memoryEntriesByCategory(list) : [];
  return (
    <Sheet title="Cantrip Memory" onClose={props.onClose} width={720} height={680}
      leading={<RefreshButton label="Refresh Cantrip memory" disabled={loading.value} onClick={() => void loadCatalog(query)} />}
      actions={(
        <input type="search" class="text-field sh-search" placeholder="Find a memory file" aria-label="Find a memory file"
          value={query} maxLength={200} autocomplete="off" spellcheck={false}
          onInput={(event) => setQuery(event.currentTarget.value)} />
      )}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <div ref={root}>
        <FormSection>
          <div class="form-row">
            <div class="sh-stack grow">
              <Caption>Read-only memory saved on your connected Mac. Core memory contains facts and preferences; notes hold procedures; session history records earlier conversations.</Caption>
              {list?.enabled === false
                ? <StatusLabel icon="pause.circle" class="caption">Memory is disabled on the Mac. Saved files are still available here.</StatusLabel>
                : null}
              {loading.value ? <Loading text="Loading memory..." /> : null}
              {error.value ? (
                <>
                  <Warning>{error.value}</Warning>
                  {list ? <Caption>Showing the last loaded list.</Caption> : null}
                  <div><button type="button" class="btn" disabled={loading.value} onClick={() => void loadCatalog(query)}>Retry</button></div>
                </>
              ) : null}
            </div>
          </div>
        </FormSection>
        {list ? (
          <>
            {groups.map((group) => (
              <FormSection key={group.category} header={group.title}>
                {group.entries.map((item) => (
                  <button key={item.id} type="button" class="sh-entry" data-entry-id={item.id} onClick={() => open(item)}>
                    <MemoryRow entry={item} />
                    <Icon name="chevron.right" size={14} />
                  </button>
                ))}
              </FormSection>
            ))}
            {list.documents.length === 0 && !loading.value && error.value === null ? (
              <div class="sh-empty" role="status">
                <Icon name="brain" size={28} />
                <h3>{query === "" ? "No saved memory yet" : "No matching memory files"}</h3>
                <p>{list.exists ? "Saved Markdown files will appear here." : "Cantrip has not created its memory folder yet."}</p>
              </div>
            ) : null}
            {list.nextCursor ? (
              <div>
                <button type="button" class="btn" disabled={loading.value} onClick={() => void loadCatalog(loadedQuery.current, true)}>
                  Load more files
                </button>
              </div>
            ) : null}
          </>
        ) : null}
      </div>
    </Sheet>
  );
}

/** CantripMemoryRow. */
function MemoryRow(props: { entry: MemoryEntry }): JSX.Element {
  const { entry } = props;
  const title = memoryTitle(entry);
  const name = memoryName(entry);
  return (
    <span class="sh-stack grow">
      <span class="headline">{title}</span>
      {title !== name ? <span class="sh-caption">{name}</span> : null}
      <span class="sh-caption">Updated {formatDateTime(unixDate(entry.modifiedAt))}</span>
      <span class="sh-caption2">{formatBytes(entry.bytes)}</span>
    </span>
  );
}
