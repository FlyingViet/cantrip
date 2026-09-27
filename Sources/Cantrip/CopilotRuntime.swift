import Foundation

enum CopilotRuntime {
    // Resolve the SDK and native runtime from the same installed CLI version.
    // In particular, a custom CLI path must never silently use another install.
    static let discoveryScript = #"""
    import { existsSync, realpathSync, openSync, readSync, closeSync } from 'node:fs';
    import { execFileSync } from 'node:child_process';
    import { homedir } from 'node:os';
    import { join, dirname, isAbsolute } from 'node:path';
    import { pathToFileURL } from 'node:url';

    function isMachO(path) {
      let fd;
      try {
        fd = openSync(path, 'r');
        const magic = Buffer.alloc(4);
        if (readSync(fd, magic, 0, 4, 0) !== 4) return false;
        return ['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca'].includes(magic.toString('hex'));
      } catch { return false; }
      finally { if (fd !== undefined) closeSync(fd); }
    }

    function resolveCopilotRuntime(configured = 'copilot') {
      const command = isAbsolute(configured) ? configured
        : (process.env.PATH ?? '').split(':').filter(Boolean)
            .map(directory => join(directory, configured)).find(path => existsSync(path));
      if (!command || !existsSync(command)) throw new Error('Copilot CLI not found. Check its path in Settings.');
      const version = execFileSync(command, ['--version'], {
        encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore']
      }).match(/(?:Copilot CLI|copilot)\s+(\d+\.\d+\.\d+)/i)?.[1];
      if (!version) throw new Error('Cannot identify the configured Copilot CLI version.');
      const root = dirname(realpathSync(command));
      const roots = [root, dirname(root),
        join(homedir(), 'Library/Caches/copilot/pkg', `darwin-${process.arch}`, version)];
      const matched = roots.find(directory => existsSync(join(directory, 'copilot-sdk/index.js'))
        && existsSync(join(directory, 'prebuilds', `darwin-${process.arch}`, 'copilot-runtime')));
      if (!matched) throw new Error('Update Copilot CLI: its matching SDK/runtime is unavailable.');
      const runtime = join(matched, 'prebuilds', `darwin-${process.arch}`, 'copilot-runtime');
      // `/mcp auth` saves MCP OAuth tokens in Keychain items readable only by the
      // signed CLI binary, so chat sessions run it (npm or native install) to reuse them.
      const cli = [realpathSync(command),
        join(root, 'node_modules', '@github', `copilot-darwin-${process.arch}`, 'copilot')]
        .find(isMachO);
      return {
        sdk: pathToFileURL(join(matched, 'copilot-sdk/index.js')).href,
        runtime, sessionRuntime: cli ?? runtime
      };
    }
    """#
}
