import Foundation

enum CopilotSessionBridge {
    static let script = CopilotRuntime.discoveryScript + "\n" + #"""
    import { createInterface } from 'node:readline';

    let client, session, runID, stopping = false, sending = 0, idle = false;
    const emit = message => process.stdout.write(JSON.stringify(message) + '\n');
    const errorText = error => String(error?.message ?? error).slice(0, 2000);
    function finishIfIdle() {
      if (!idle || sending || !runID) return;
      const completed = runID;
      runID = undefined;
      emit({ kind: 'done', runID: completed });
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
          emit({ kind: 'approval', runID, tool: request.kind,
            decision: allowed ? 'approved' : 'denied' });
          return { kind: allowed ? 'approve-once' : 'reject' };
        },
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
