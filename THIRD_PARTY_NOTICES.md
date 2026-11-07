# Third-Party Notices & Engineering References

Suyoi is an independent clean-room implementation written in Swift 6, SwiftUI, and AppKit. It does not bundle third-party libraries or runtime package dependencies. Certain engineering patterns were informed by the open-source macOS projects listed below; their full copyright and license notices are preserved here for attribution.

---

## WhatThePort — MIT License

Informed native `libproc` inspection, `ProcessTree` / `ServerResources` grouping and resource deduplication, and bounded `.git/HEAD`, worktree metadata, and manifest project resolution.

- Upstream repository: [tomjohndesign/what-the-port](https://github.com/tomjohndesign/what-the-port)

```text
MIT License

Copyright (c) 2026 Tomjohn Design LLC

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
```

---

## BlitzClean — MIT License

Informed process-instance identity verification (`pid` + `uid` + microsecond `startTime` + `executablePath`), `FileIdentity(device, inode)`, and lockfile/working-directory safety checks.

- Upstream repository: [blitzreels/blitzclean](https://github.com/blitzreels/blitzclean)

```text
MIT License

Copyright (c) 2026 BlitzReels and BlitzClean contributors
Copyright (c) 2026 Buildkeep contributors

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
```

---

## OrphanBar — MIT License

Retained as part of BlitzClean's upstream attribution chain.

```text
MIT License

Copyright (c) 2026 Mohammed M. Abdelgwad

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
```

---

## CleanMyAgent — MIT License

Informed allowlisted agent-cache catalog definitions, tri-state `lsof` open-file checks, and `git worktree list --porcelain -z` inspection.

- Upstream repository: [romainsimon/CleanMyAgent](https://github.com/romainsimon/CleanMyAgent)

```text
MIT License

Copyright (c) 2026 Romain Simon

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
```

---

## Ping Island — Conceptual Reference (Apache-2.0)

Informed high-level concepts around terminal/TTY ancestry and separating observed process state from verified session metadata. No source code, fonts, or icons from Ping Island are included in Suyoi.

- Upstream repository: [erha19/ping-island](https://github.com/erha19/ping-island) ([Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0))

---

## CodexBar — Conceptual Reference (MIT)

Informed quota window and rate-limit presentation concepts. No source code, assets, or dependencies from CodexBar are included in Suyoi.

- Upstream repository: [steipete/CodexBar](https://github.com/steipete/CodexBar)
