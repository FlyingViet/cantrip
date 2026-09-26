import Foundation

enum CopilotSessionBridge {
    static let script = CopilotRuntime.discoveryScript + "\n" + #"""
    import { createInterface } from 'node:readline';
    import { randomUUID } from 'node:crypto';

    let client, session, runID, stopping = false, sending = 0, idle = false;
    const inputs = new Map();
    const emit = message => process.stdout.write(JSON.stringify(message) + '\n');
    const errorText = error => String(error?.message ?? error).slice(0, 2000);
    function finishIfIdle() {
      if (!idle || sending || inputs.size || !runID) return;
      const completed = runID;
      runID = undefined;
      emit({ kind: 'done', runID: completed });
    }
    function requestInput(kind, detail, options = {}) {
      if (!runID || stopping) return Promise.resolve({ decision: 'cancel' });
      const id = randomUUID(), owner = runID;
      return new Promise(resolve => {
        const timer = setTimeout(() => answerInput({ id, runID: owner, decision: 'cancel' }), 600000);
        inputs.set(id, { owner, resolve, timer });
        emit({ kind: 'input', runID: owner, id, inputKind: kind, detail: String(detail), ...options });
      });
    }
    function answerInput(command) {
      const pending = inputs.get(command.id);
      if (!pending || pending.owner !== command.runID) return;
      inputs.delete(command.id);clearTimeout(pending.timer);
      pending.resolve(command);
      emit({kind:'inputClosed',runID:pending.owner,id:command.id});
      finishIfIdle();
    }
    function onEvent(event) {
      if (!runID || stopping) return;
      if (event.type === 'session.idle') {
        idle = true;
        finishIfIdle();
      } else if (event.type === 'session.error') {
        emit({ kind: 'failure', runID, message: event.data.message });
        runID = undefined;
      } else {
        emit({ kind: 'event', runID, event });
      }
    }
    async function open(config) {
      const paths = resolveCopilotRuntime(config.command);
      const sdk = await import(paths.sdk);
      if (!sdk.RuntimeConnection?.forStdio || !sdk.CopilotClient) {
        throw new Error('Update Copilot CLI to a version with native session steering.');
      }
      client = new sdk.CopilotClient({
        connection: sdk.RuntimeConnection.forStdio({ path: paths.runtime }),
        workingDirectory: config.workdir, logLevel: 'none', useLoggedInUser: true
      });
      await client.start();
      session = await client.createSession({
        clientName: 'Cantrip', workingDirectory: config.workdir,
        model: config.model || undefined, reasoningEffort: config.effort || undefined,
        contextTier: config.contextTier || undefined, streaming: true,
        enableConfigDiscovery: true, remoteSession: 'off',
        availableTools: config.readOnly ? [] : config.allowTools ? undefined : ['view', 'glob', 'grep'],
        enableFileHooks: config.allowTools && !config.readOnly,
        onPermissionRequest: request => {
          const allowed = config.allowTools && !config.readOnly;
          if (allowed && !config.autoApprove && request.kind !== 'read') {
            const detail = request.fullCommandText || request.intention
              || JSON.stringify(request);
            return requestInput('approval', detail, { title: `Allow ${request.kind}?` })
              .then(answer => ({kind: answer.decision === 'approve' ? 'approve-once' : 'reject'}));
          }
          emit({ kind: 'approval', runID, tool: request.kind,
            decision: allowed ? 'approved' : 'denied' });
          return { kind: allowed ? 'approve-once' : 'reject' };
        },
        onUserInputRequest: request => requestInput('question', request.question, {
          title: 'Copilot needs your answer', choices: request.choices || [],
          allowsFreeform: request.allowFreeform !== false
        }).then(answer => {
          if (answer.decision !== 'submit') throw new Error('User cancelled the input request.');
          return {answer:answer.text,wasFreeform:!(request.choices || []).includes(answer.text)};
        }),
        onEvent
      });
      if (typeof session.send !== 'function') throw new Error('Copilot native session input is unavailable.');
    }
    async function deliver(command) {
      if (command.kind === 'start') {
        if (runID) throw new Error('A Copilot turn is already running.');
        runID = command.runID;
        idle = false;
        sending++;
        try {
          const fresh = !session;
          if (fresh) await open(command.config);
          const messageID = await session.send({
            prompt: fresh ? command.initialPrompt : command.prompt, mode: 'enqueue'
          });
          emit({ kind: 'started', runID, messageID });
        } finally {
          sending--;
          finishIfIdle();
        }
      } else if (command.kind === 'inject') {
        if (!session || runID !== command.runID) {
          emit({ kind: 'delivery', runID: command.runID, id: command.id, status: 'notSent' });
          return;
        }
        sending++;
        idle = false;
        try {
          const messageID = await session.send({ prompt: command.text, mode: 'immediate' });
          emit({ kind: 'delivery', runID: command.runID, id: command.id, status: 'accepted', messageID });
        } catch (error) {
          // An RPC error can arrive after acceptance. Never turn it into an automatic retry.
          emit({ kind: 'delivery', runID: command.runID, id: command.id,
            status: 'uncertain', message: errorText(error) });
        } finally {
          sending--;
          finishIfIdle();
        }
      } else {
        throw new Error('Invalid Cantrip session command.');
      }
    }
    async function stop() {
      if (stopping) return;
      stopping = true;
      for (const [id,pending] of inputs) answerInput({id,runID:pending.owner,decision:'cancel'});
      const deadline = setTimeout(() => process.exit(1), 2000);
      try {
        if (session && runID) await session.abort();
        if (client) await client.forceStop();
        clearTimeout(deadline);
        process.exit(0);
      } catch (error) {
        process.stderr.write('Copilot shutdown failed: ' + errorText(error) + '\n');
        process.exit(1);
      }
    }
    process.on('SIGTERM', () => { void stop(); });
    process.on('SIGINT', () => { void stop(); });
    const input = createInterface({ input: process.stdin });
    let commands = Promise.resolve();
    input.on('line', line => {
      let immediate;
      try { immediate = JSON.parse(line); }
      catch { void stop(); return; }
      // Input callbacks can be awaited by session.send: responses must bypass the send queue.
      if (immediate.kind === 'inputAnswer') { answerInput(immediate); return; }
      commands = commands.then(async () => {
        if (stopping) return;
        const command = JSON.parse(line);
        try { await deliver(command); }
        catch (error) {
          emit({ kind: 'failure', runID: command.runID, message: errorText(error) });
          await stop();
        }
      }).catch(async error => {
        emit({ kind: 'failure', runID, message: errorText(error) });
        await stop();
      });
    });
    input.on('close', () => { void stop(); });
    """#
}
