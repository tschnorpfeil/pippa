#!/usr/bin/env python3
"""Dump the real Swift declarations without starting Mail, Calendar or the app."""
import pathlib, subprocess, os
root = pathlib.Path(__file__).resolve().parents[2]
parts = ['import Foundation']
for name, file in [('PippaMCPTurnTools', 'PippaMCPTurn.swift'), ('PippaMCPWriteTools', 'PippaMCPWrite.swift'), ('PippaMCPTools', 'PippaMCPTools.swift')]:
    text = (root / 'app/Sources/PippaCore/MCP' / file).read_text()
    start = text.index('    public static func toolList()')
    end = text.index('\n    /// Arguments', start)
    # toolList is followed by unrelated methods in the readers file.
    function = text[start:end]
    extra = 'static let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]\n'
    if name == 'PippaMCPWriteTools':
        extra = 'static let hints: [String: Any] = ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]\n'
    parts.append('struct ' + name + ' {\n' + extra + function + '\n}')
parts.append('let data = try JSONSerialization.data(withJSONObject: PippaMCPTools.toolList(), options: [.sortedKeys]); print(String(decoding: data, as: UTF8.self))')
home = root / '.build/tool-choice-home'
home.mkdir(parents=True, exist_ok=True)
source = home / 'schemas.swift'
source.write_text('\n'.join(parts))
env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
subprocess.run(['swift', str(source)], env=env, check=True)
