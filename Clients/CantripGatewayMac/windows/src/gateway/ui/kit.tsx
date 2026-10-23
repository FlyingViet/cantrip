// Shared controls: popover menus, sheets, confirmation dialogs and toasts (Mac-style, dark).
import { signal } from "@preact/signals";
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { Icon, type IconName } from "./icons";

// MARK: Menus

export type MenuEntry =
  | {
    kind?: "item"; label: string; icon?: IconName; shortcut?: string; disabled?: boolean; destructive?: boolean;
    checked?: boolean; onSelect: () => void; id?: string;
  }
  | { kind: "separator" }
  | { kind: "header"; label: string };

interface OpenMenu {
  entries: MenuEntry[];
  /** Anchor rectangle (button) or point (context menu). */
  rect: { left: number; top: number; right: number; bottom: number };
  align: "start" | "end";
  restore: HTMLElement | null;
  label: string;
  onClose?: () => void;
}

export const activeMenu = signal<OpenMenu | null>(null);

export function openMenu(
  anchor: HTMLElement | { x: number; y: number },
  entries: MenuEntry[],
  options: { align?: "start" | "end"; label?: string; onClose?: () => void } = {},
): void {
  const rect = anchor instanceof HTMLElement
    ? anchor.getBoundingClientRect()
    : { left: anchor.x, right: anchor.x, top: anchor.y, bottom: anchor.y };
  activeMenu.value = {
    entries: entries.filter((entry, index, all) =>
      // No leading, trailing or doubled separators.
      entry.kind !== "separator" || (index > 0 && index < all.length - 1 && all[index - 1].kind !== "separator")),
    rect: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
    align: options.align ?? (anchor instanceof HTMLElement ? "end" : "start"),
    restore: anchor instanceof HTMLElement ? anchor : (document.activeElement as HTMLElement | null),
    label: options.label ?? "Menu",
    onClose: options.onClose,
  };
}

export function closeMenu(restoreFocus = true): void {
  const menu = activeMenu.value;
  if (!menu) return;
  activeMenu.value = null;
  menu.onClose?.();
  if (restoreFocus) menu.restore?.focus?.();
}

/** A toolbar or inline button that opens a menu; aria-expanded tracks it. */
export function MenuButton(props: {
  entries: () => MenuEntry[];
  class?: string;
  label: string;
  title?: string;
  disabled?: boolean;
  align?: "start" | "end";
  children: ComponentChildren;
  id?: string;
}): JSX.Element {
  const ref = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  return (
    <button
      ref={ref}
      id={props.id}
      type="button"
      class={props.class ?? "glass-btn"}
      aria-label={props.label}
      title={props.title ?? props.label}
      aria-haspopup="menu"
      aria-expanded={open ? "true" : "false"}
      disabled={props.disabled}
      onPointerDown={(event) => {
        if (activeMenu.value?.restore === ref.current) event.preventDefault();
      }}
      onClick={() => {
        if (!ref.current) return;
        if (activeMenu.value?.restore === ref.current) { closeMenu(); return; }
        setOpen(true);
        openMenu(ref.current, props.entries(), { align: props.align, label: props.label, onClose: () => setOpen(false) });
      }}
      onKeyDown={(event) => {
        if (event.key === "ArrowDown" && ref.current) {
          event.preventDefault();
          setOpen(true);
          openMenu(ref.current, props.entries(), { align: props.align, label: props.label, onClose: () => setOpen(false) });
        }
      }}
    >
      {props.children}
    </button>
  );
}

export function MenuLayer(): JSX.Element | null {
  const menu = activeMenu.value;
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ left: number; top: number } | null>(null);

  useLayoutEffect(() => {
    if (!menu || !ref.current) { setPosition(null); return; }
    const box = ref.current.getBoundingClientRect();
    const margin = 8;
    let left = menu.align === "end" ? menu.rect.right - box.width : menu.rect.left;
    let top = menu.rect.bottom + 4;
    if (top + box.height > innerHeight - margin) top = Math.max(margin, menu.rect.top - box.height - 4);
    left = Math.min(Math.max(margin, left), innerWidth - box.width - margin);
    setPosition({ left, top });
    requestAnimationFrame(() => ref.current?.querySelector<HTMLButtonElement>(".menu-item:not(:disabled)")?.focus());
  }, [menu]);

  useEffect(() => {
    if (!menu) return;
    const close = () => closeMenu(false);
    addEventListener("resize", close);
    addEventListener("blur", close);
    return () => { removeEventListener("resize", close); removeEventListener("blur", close); };
  }, [menu]);

  if (!menu) return null;
  const items = () => Array.from(ref.current?.querySelectorAll<HTMLButtonElement>(".menu-item:not(:disabled)") ?? []);
  const onKeyDown = (event: KeyboardEvent) => {
    const list = items();
    const index = list.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === "Escape") { event.preventDefault(); closeMenu(); }
    else if (event.key === "ArrowDown") { event.preventDefault(); list[(index + 1) % list.length]?.focus(); }
    else if (event.key === "ArrowUp") { event.preventDefault(); list[(index - 1 + list.length) % list.length]?.focus(); }
    else if (event.key === "Home") { event.preventDefault(); list[0]?.focus(); }
    else if (event.key === "End") { event.preventDefault(); list[list.length - 1]?.focus(); }
    else if (event.key === "Tab") { event.preventDefault(); closeMenu(); }
  };
  return (
    <div class="menu-layer" onPointerDown={(event) => { if (event.target === event.currentTarget) closeMenu(false); }}
      onContextMenu={(event) => { event.preventDefault(); closeMenu(false); }}>
      <div ref={ref} class="menu" role="menu" aria-label={menu.label} onKeyDown={onKeyDown}
        style={position ? { left: `${position.left}px`, top: `${position.top}px` } : { left: "-9999px", top: "0px" }}>
        {menu.entries.map((entry, index) => {
          if (entry.kind === "separator") return <div key={index} class="menu-sep" role="separator" />;
          if (entry.kind === "header") return <div key={index} class="menu-header" role="presentation">{entry.label}</div>;
          const hasChecks = menu.entries.some((item) => (item.kind ?? "item") === "item" && (item as { checked?: boolean }).checked !== undefined);
          return (
            <button key={index} type="button" class={`menu-item${entry.destructive ? " destructive" : ""}`}
              role={entry.checked !== undefined ? "menuitemcheckbox" : "menuitem"}
              aria-checked={entry.checked}
              id={entry.id}
              disabled={entry.disabled}
              onClick={() => { closeMenu(); entry.onSelect(); }}>
              {hasChecks && <span class="check">{entry.checked ? <Icon name="checkmark" size={14} /> : null}</span>}
              {entry.icon ? <Icon name={entry.icon} /> : null}
              <span class="grow">{entry.label}</span>
              {entry.shortcut ? <span class="shortcut">{entry.shortcut}</span> : null}
            </button>
          );
        })}
      </div>
    </div>
  );
}

// MARK: Sheets

const FOCUSABLE = "button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex='-1'])";

/** Open sheets, topmost last: Escape and focus belong to the top one even when focus fell to the page. */
const sheetStack: { node: () => HTMLElement | null; close: () => void; locked: () => boolean }[] = [];

function setBackgroundInert(inert: boolean): void {
  for (const element of document.querySelectorAll<HTMLElement>(".window > .sidebar, .window > .detail, .settings-window > .settings-titlebar, .settings-window > .settings-body")) {
    element.inert = inert;
  }
}

document.addEventListener("keydown", (event) => {
  const top = sheetStack[sheetStack.length - 1];
  if (!top || event.defaultPrevented) return;
  const node = top.node();
  if (event.key === "Escape" && !activeMenu.value) {
    if (!top.locked()) top.close();
    event.preventDefault();
  } else if (event.key === "Tab" && node && !node.contains(document.activeElement)) {
    event.preventDefault();
    (node.querySelector<HTMLElement>(FOCUSABLE) ?? node).focus();
  }
});

export function Sheet(props: {
  title: ComponentChildren;
  /** Shown before the title (for example a Back button). */
  leading?: ComponentChildren;
  /** Toolbar items at the right of the header. */
  actions?: ComponentChildren;
  footer?: ComponentChildren;
  onClose: () => void;
  width?: number;
  height?: number;
  /** Size to content (up to the window) instead of a fixed height. */
  fit?: boolean;
  /** Escape and clicks outside are ignored (for example while saving). */
  locked?: boolean;
  label?: string;
  class?: string;
  bodyClass?: string;
  children: ComponentChildren;
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null);
  const restore = useRef<HTMLElement | null>(null);
  const lockedRef = useRef(props.locked);
  lockedRef.current = props.locked;
  const closeRef = useRef(props.onClose);
  closeRef.current = props.onClose;

  useEffect(() => {
    restore.current = document.activeElement as HTMLElement | null;
    const entry = { node: () => ref.current, close: () => closeRef.current(), locked: () => Boolean(lockedRef.current) };
    sheetStack.push(entry);
    setBackgroundInert(true);
    requestAnimationFrame(() => {
      const node = ref.current;
      const first = node?.querySelector<HTMLElement>("[autofocus], [data-autofocus]") ?? node?.querySelector<HTMLElement>(FOCUSABLE);
      (first ?? node)?.focus();
    });
    return () => {
      sheetStack.splice(sheetStack.indexOf(entry), 1);
      if (!sheetStack.length) setBackgroundInert(false);
      if (restore.current?.isConnected) restore.current.focus();
    };
  }, []);

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      // The document listener closes the topmost sheet.
      return;
    } else if (event.key === "Tab" && ref.current) {
      const list = Array.from(ref.current.querySelectorAll<HTMLElement>(FOCUSABLE)).filter((el) => el.offsetParent !== null);
      if (!list.length) return;
      const first = list[0];
      const last = list[list.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  };
  const style: Record<string, string> = {};
  if (props.width) style["--sheet-w"] = `${props.width}px`;
  if (props.height) style["--sheet-h"] = `${props.height}px`;
  return (
    <div class="sheet-backdrop" onKeyDown={onKeyDown}>
      <div ref={ref} class={`sheet${props.fit ? " fit" : ""}${props.class ? ` ${props.class}` : ""}`} role="dialog" aria-modal="true"
        aria-label={props.label ?? (typeof props.title === "string" ? props.title : undefined)} tabIndex={-1} style={style}>
        <div class="sheet-header">
          {props.leading}
          <h2>{props.title}</h2>
          {props.actions}
        </div>
        <div class={`sheet-body${props.bodyClass ? ` ${props.bodyClass}` : ""}`}>{props.children}</div>
        {props.footer ? <div class="sheet-footer">{props.footer}</div> : null}
      </div>
    </div>
  );
}

// MARK: Confirmation dialogs (macOS alerts)

interface PendingConfirm {
  title: string;
  message?: string;
  confirm: string;
  cancel: string;
  destructive: boolean;
  resolve: (value: boolean) => void;
}

const pendingConfirm = signal<PendingConfirm | null>(null);

export function confirmDialog(options: { title: string; message?: string; confirm?: string; cancel?: string; destructive?: boolean }): Promise<boolean> {
  return new Promise((resolve) => {
    pendingConfirm.value?.resolve(false);
    pendingConfirm.value = {
      title: options.title, message: options.message, confirm: options.confirm ?? "OK", cancel: options.cancel ?? "Cancel",
      destructive: options.destructive ?? false, resolve,
    };
  });
}

/** An alert with only an OK button. */
export function alertDialog(title: string, message?: string): Promise<boolean> {
  return confirmDialog({ title, message, confirm: "OK", cancel: "" });
}

export function ConfirmLayer(): JSX.Element | null {
  const pending = pendingConfirm.value;
  if (!pending) return null;
  const finish = (value: boolean) => {
    pendingConfirm.value = null;
    pending.resolve(value);
  };
  return (
    <Sheet title={pending.title} onClose={() => finish(false)} width={420} fit class="alert-sheet"
      footer={<>
        {pending.cancel ? <button type="button" class="btn" onClick={() => finish(false)}>{pending.cancel}</button> : null}
        <button type="button" class={`btn primary${pending.destructive ? " destructive" : ""}`} data-autofocus onClick={() => finish(true)}>
          {pending.confirm}
        </button>
      </>}>
      {pending.message ? <p class="selectable" style={{ whiteSpace: "pre-wrap", margin: "0 0 4px" }}>{pending.message}</p> : null}
    </Sheet>
  );
}

// MARK: Toasts

const toasts = signal<{ id: number; text: string }[]>([]);
let toastID = 0;

export function toast(text: string, milliseconds = 3200): void {
  const id = ++toastID;
  toasts.value = [...toasts.value, { id, text }];
  setTimeout(() => { toasts.value = toasts.value.filter((item) => item.id !== id); }, milliseconds);
}

export function ToastLayer(): JSX.Element {
  return (
    <div class="toast-layer" role="status" aria-live="polite">
      {toasts.value.map((item) => <div key={item.id} class="toast">{item.text}</div>)}
    </div>
  );
}

// MARK: Small pieces

export function Spinner(props: { size?: "small" | "large"; tint?: "accent" | "tint"; label?: string }): JSX.Element {
  return <span class={`spinner${props.size ? ` ${props.size}` : ""}${props.tint ? ` ${props.tint}` : ""}`}
    role={props.label ? "progressbar" : undefined} aria-label={props.label} aria-hidden={props.label ? undefined : "true"} />;
}

export function FormSection(props: { header?: ComponentChildren; footer?: ComponentChildren; children: ComponentChildren; class?: string }): JSX.Element {
  return (
    <section class={`form-section${props.class ? ` ${props.class}` : ""}`}>
      {props.header ? <div class="form-header">{props.header}</div> : null}
      <div class="form-group">{props.children}</div>
      {props.footer ? <div class="form-footer">{props.footer}</div> : null}
    </section>
  );
}

export function FormRow(props: { label?: ComponentChildren; children?: ComponentChildren; stack?: boolean; class?: string }): JSX.Element {
  return (
    <div class={`form-row${props.stack ? " stack" : ""}${props.class ? ` ${props.class}` : ""}`}>
      {props.label !== undefined ? <div class="form-label">{props.label}</div> : null}
      {props.children}
    </div>
  );
}
