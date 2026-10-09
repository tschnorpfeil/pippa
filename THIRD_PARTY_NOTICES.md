# Third-party notices

Pippa itself is MIT-licensed (see [LICENSE](LICENSE)). `Pippa.app` ships the third-party software below; this file is copied into the app as `Contents/Resources/THIRD_PARTY_NOTICES.md`. Licences are reproduced below or shipped next to each component.

| Component | Use in Pippa | Licence |
|---|---|---|
| [Pi](https://github.com/earendil-works/pi) 1.1.0 (`@earendil-works/pi-coding-agent`, `pi-agent-core`, `pi-ai`, `pi-tui`, `pi-mcp`, `pi-codemode`, `pi-telemetry`, `chord`) | The agent. Shipped as the install payload Pippa copies to `~/.pi/agent` (`Contents/Resources/pi-payload/release`) | MIT, Copyright (c) 2025 Mario Zechner. The npm packages contain no licence file, so the text is reproduced below |
| [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk), bundled inside `@earendil-works/pi-mcp` | MCP client in Pi | MIT, Copyright (c) 2024 Anthropic, PBC; shipped in `node_modules/@earendil-works/pi-mcp/LICENSES/` |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) b11503 (`llama-server`, ggml, llama and mtmd libraries) | Runs the local language model | MIT, see below and `Contents/Resources/llama.cpp-LICENSE.txt`. Code compiled into it is listed under "Inside llama.cpp" below |
| [fd](https://github.com/sharkdp/fd) 10.3.0 (`Contents/Helpers/fd`) | File search for Pi's `find` tool | MIT or Apache 2.0, Copyright (c) 2017-present The fd developers; see `Contents/Resources/fd-LICENSE-MIT.txt` and `fd-LICENSE-APACHE.txt` |
| [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1 (`Contents/Helpers/rg`) | Content search for Pi's `grep` tool | MIT or Unlicense, Copyright (c) 2015 Andrew Gallant; see `Contents/Resources/rg-LICENSE-MIT.txt` and `rg-UNLICENSE.txt` |
| [Node.js](https://nodejs.org) 22.23.3 | Runs Pi; also copied to `~/.local/share/pi-node` for Pi in Terminal | MIT and others, see `Contents/Resources/Node-LICENSE.txt` |
| [npm](https://github.com/npm/cli) 10.9.9 (`Contents/Resources/pi-payload/lib/node_modules/npm`) | Lets `pi update` work in Terminal without a separate Node install | Artistic License 2.0, Copyright (c) npm, Inc. and Contributors; licence and its dependencies' licences shipped in that folder |
| [Sparkle](https://sparkle-project.org) 2.10.0 | Automatic updates | MIT-style, see below |
| [pi-web-access](https://github.com/nicobailon/pi-web-access) 0.37.0 (Nico Bailon) | Web search and page reading for *Check online* and approved web lookups, only in the separate fetcher process the app starts (`Contents/Resources/pippa-web/src/fetcher.mjs`, generated code in `pippa-web/src/generated/`) | MIT, see below |
| Dependencies of pi-web-access (defuddle, @mozilla/readability, turndown, linkedom, unpdf, p-limit, undici and their own dependencies) | Page reading in the fetcher process | MIT, Apache 2.0, ISC and others; each licence shipped in `Contents/Resources/pippa-web/node_modules/<package>/` |
| Other npm packages used by Pi (about 320 in `pi-payload/release/node_modules`) | Pi dependencies | MIT, ISC, Apache 2.0, BSD-2/3-Clause, BlueOak-1.0.0, 0BSD, Unlicense, CC0-1.0, CC-BY-3.0; each package's licence shipped in its folder, exceptions listed below |
| [Bagel Fat One](https://fonts.google.com/specimen/Bagel+Fat+One) | App font for the welcome headline | SIL Open Font License 1.1, Copyright 2022 The Bagel Fat Project Authors; shipped as `OFL.txt` next to the font |
| [Gochi Hand](https://fonts.google.com/specimen/Gochi+Hand) | Handwritten pill label when an answer is ready, as on the website | SIL Open Font License 1.1, Copyright 2011 Juan Pablo del Peral; shipped as `GochiHand-OFL.txt` next to the font |

Language models are not part of the app or this repository. Pippa downloads them from Hugging Face only after you agree (or reuses a copy already on the Mac), and each model comes under its own licence, named with a link in the model catalogue (`app/Sources/PippaCore/Resources/catalog.json`). All installable catalogue models are currently Apache 2.0: K2 Horizon 7B by MBZUAI and IFM, the default from 16 GB on ([model card](https://huggingface.co/IFM/K2-Horizon-7B)), and the Qwen models ([Qwen licence files](https://huggingface.co/Qwen)), among them Qwen3.5 4B for 8 GB Macs and Qwen3.6 35B-A3B for "More thorough" on 24 GB and up.

### Inside llama.cpp

The pinned llama.cpp build compiles in third-party code that carries its own notices:

- [cpp-httplib](https://github.com/yhirose/cpp-httplib) (HTTP server in `llama-server`): MIT, Copyright (c) 2017 yhirose
- [nlohmann/json](https://github.com/nlohmann/json) (JSON in llama-server and common): MIT, Copyright (c) 2013-2025 Niels Lohmann
- [stb_image](https://github.com/nothings/stb) (image decoding in libmtmd): MIT (alternatively public domain), Copyright (c) 2017 Sean Barrett
- YaRN RoPE scaling code in the Metal backend: MIT, Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng

Each is under the MIT License, whose text is reproduced under "Pi" below with the respective copyright line.

### npm packages without a licence file

These packages in the bundle declare a licence in `package.json` but ship no licence file. Their notices:

| Package | Licence | Copyright / author |
|---|---|---|
| `@aws-sdk/credential-provider-http`, `@aws-sdk/credential-provider-login`, `@aws-sdk/nested-clients` | Apache 2.0 (text shipped in `node_modules/@aws-sdk/core/LICENSE`) | Amazon.com, Inc. or its affiliates (AWS SDK for JavaScript) |
| `@sigstore/verify` | Apache 2.0 | The Sigstore Authors |
| `@npmcli/agent` | ISC | GitHub Inc. |
| `@esbuild/darwin-arm64` | MIT | Evan Wallace |
| `boolbase` | ISC | Felix Böhm |
| `data-uri-to-buffer`, `proxy-agent-negotiate` | MIT | Nathan Rajlich |
| `eastasianwidth` | MIT | Masaki Komagata |
| `err-code` | MIT | IndigoUnited |
| `imurmurhash` | MIT | Jens Taylor |
| `standardwebhooks` | MIT | Standard Webhooks |
| `spdx-exceptions` (data) | CC-BY-3.0 | The Linux Foundation and its contributors; from the [SPDX License List](https://spdx.org/licenses/exceptions-index.html), unmodified |
| `spdx-license-ids` (data) | CC0-1.0 | Shinnosuke Watanabe |

## Pi

MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
## llama.cpp

MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## pi-web-access

MIT License

Copyright (c) 2025 Nico Bailon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Sparkle

Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
