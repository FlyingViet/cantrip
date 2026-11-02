// The open tab's terminal under its conversation (MacTerminalPane.swift): the Mac's persistent shell for
// the tab, so cd and exports carry over and the agent's own commands show up too. Up/Down browse
// history, Ctrl+C interrupts, and the top edge drags to resize.
import type { JSX } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { RemoteSessionSummary } from "../../api/types";
import { bridge } from "../../bridge";
import * as nav from "../../state/nav";
import * as term from "../../state/terminal";
import { Icon } from "../icons";
import "./terminal.css";

const MIN_HEIGHT = 120;
/** Ctrl+` on both systems (Cmd+` cycles windows on macOS). */
export const TOGGLE_KEYS = bridge.platform === "darwin" ? "⌃`" : "Ctrl+`";

export function TerminalPane(props: { session: RemoteSessionSummary }): JSX.Element {
  const { session } = props;
  const state = term.terminal.value;
  const supported = session.supportsTerminal === true;
  const [command, setCommand] = useState("");
  const cursor = useRef(term.freshCursor());
  const output = useRef<HTMLPreElement>(null);
  const follow = useRef(true);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setCommand("");
    cursor.current = term.freshCursor();
    follow.current = true;
    if (!supported) return void term.stop();
    term.start(session.id);
    input.current?.focus();
    return () => term.stop();
  }, [session.id, supported]);

  // Follow new output unless the user scrolled up to read.
  useLayoutEffect(() => {
    const node = output.current;
    if (node && follow.current) node.scrollTop = node.scrollHeight;
  }, [state.buffer]);

  const notice = !supported
    ? session.supportsTerminal === false ? "Shell commands and tools are disabled in Private Local." : term.UNSUPPORTED
    : state.error ?? (!state.loaded ? "Connecting to the tab's shell…"
      : state.buffer.output ? null : "This tab's shell on the Mac. The agent's commands appear here too; cd, exports and variables persist.");
  const busy = term.isBusy(state);
  const ready = supported && state.loaded;

  const submit = () => {
    const line = command;
    if (!line.trim()) return;
    setCommand("");
    cursor.current = term.freshCursor();
    follow.current = true;
    void term.run(line).then((ok) => { if (!ok) setCommand(line); });
  };

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === "Enter") {
      event.preventDefault();
      submit();
    } else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      event.preventDefault();
      const step = term.historyStep(cursor.current, event.key === "ArrowUp", state.history, command);
      if (step) {
        cursor.current = step.cursor;
        setCommand(step.line);
      }
    } else if (event.key.toLowerCase() === "c" && event.ctrlKey && !event.shiftKey && !event.altKey) {
      // With text selected, Ctrl+C copies as usual.
      const field = event.currentTarget as HTMLInputElement;
      if (field.selectionStart !== field.selectionEnd) return;
      event.preventDefault();
      if (busy) void term.interrupt();
      else {
        setCommand("");
        cursor.current = term.freshCursor();
      }
    }
  };

  const startResize = (event: PointerEvent) => {
    event.preventDefault();
    const startY = event.clientY;
    const startHeight = nav.terminalHeight.value;
    const move = (moved: PointerEvent) => {
      nav.terminalHeight.value = Math.round(Math.min(900, Math.max(MIN_HEIGHT, startHeight + startY - moved.clientY)));
    };
    const end = () => {
      removeEventListener("pointermove", move);
      removeEventListener("pointerup", end);
    };
    addEventListener("pointermove", move);
    addEventListener("pointerup", end);
  };

  return (
    <section class="terminal-pane" style={{ height: `${nav.terminalHeight.value}px` }} aria-label="Terminal" data-id="terminal.pane">
      <div class="terminal-resize" role="separator" aria-orientation="horizontal" aria-label="Resize terminal" onPointerDown={startResize} />
      <header class="terminal-header">
        <span class="terminal-title"><Icon name="terminal" size={14} />Terminal</span>
        <span class="terminal-workdir truncate" title={state.workdir || session.workdir}>{state.workdir || session.workdir}</span>
        <span class="grow" />
        {busy ? <span class="spinner small" aria-label="Running" /> : null}
        {busy ? (
          <button type="button" class="icon-btn" disabled={!ready || state.sending} aria-label="Interrupt"
            title={state.isRunning ? "Interrupt the running command (Ctrl+C)" : "Stop the agent's command (Ctrl+C)"} onClick={() => void term.interrupt()}>
            <Icon name="stop.circle" size={14} />
          </button>
        ) : null}
        <button type="button" class="icon-btn" disabled={!ready || state.sending} aria-label="Clear" title="Clear the terminal on every device"
          onClick={() => void term.clear()}>
          <Icon name="eraser" size={14} />
        </button>
        <button type="button" class="icon-btn" disabled={!ready || state.sending} aria-label="Restart Shell"
          title="Restart this tab's shell on the Mac (stops its running command)" onClick={() => void term.restart()}>
          <Icon name="arrow.uturn.backward" size={14} />
        </button>
        <button type="button" class="icon-btn" aria-label="Close Terminal" title={`Hide the terminal (${TOGGLE_KEYS})`}
          onClick={() => { nav.terminalOpen.value = false; }}>
          <Icon name="xmark" size={14} />
        </button>
      </header>
      <pre ref={output} class="terminal-output selectable" data-id="terminal.output"
        onScroll={(event) => {
          const node = event.currentTarget;
          follow.current = node.scrollHeight - node.scrollTop - node.clientHeight < 24;
        }}>
        {notice ? <div class={`terminal-notice${state.error || !supported ? " orange" : ""}`}>{notice}</div> : null}
        {state.buffer.output}
      </pre>
      <label class="terminal-prompt">
        <span class="terminal-dollar" aria-hidden="true">$</span>
        <input ref={input} type="text" value={command} spellcheck={false} autocomplete="off" disabled={!ready} data-id="terminal.command"
          aria-label="Terminal command" placeholder={state.isRunning ? "input for the running command" : "command"}
          onInput={(event) => setCommand(event.currentTarget.value)} onKeyDown={onKeyDown} />
      </label>
    </section>
  );
}

/** The toolbar's Terminal toggle; orange while a command runs with the pane hidden. */
export function TerminalButton(props: { session: RemoteSessionSummary | null }): JSX.Element {
  const open = nav.terminalOpen.value;
  const busy = props.session?.terminalBusy === true && !open;
  return (
    <button type="button" class={`glass-btn${open ? " active" : ""}`} aria-pressed={open} disabled={!props.session} data-id="terminal.toggle"
      aria-label={open ? "Hide Terminal" : "Show Terminal"}
      title={busy ? `Terminal: a command is running; click to watch (${TOGGLE_KEYS})` : `Terminal: this tab's shell on the Mac (${TOGGLE_KEYS})`}
      onClick={() => { nav.terminalOpen.value = !open; }}>
      <Icon name="terminal" size={18} class={open ? "tint-accent" : busy ? "pulse tint-active" : undefined} />
    </button>
  );
}
