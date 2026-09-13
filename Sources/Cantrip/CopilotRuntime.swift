import Foundation

enum CopilotRuntime {
    // Resolve the SDK and native runtime from the same installed CLI version.
    // In particular, a custom CLI path must never silently use another install.
    static let discoveryScript = #"""
    import { existsSync, realpathSync } from 'node:fs';
    import { execFileSync } from 'node:child_process';
    import { homedir } from 'node:os';
    import { join, dirname, isAbsolute } from 'node:path';
    import { pathToFileURL } from 'node:url';

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
      return {
        sdk: pathToFileURL(join(matched, 'copilot-sdk/index.js')).href,
        runtime: join(matched, 'prebuilds', `darwin-${process.arch}`, 'copilot-runtime')
      };
    }
    """#
}
