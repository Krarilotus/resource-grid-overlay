# UCP integration review

The grid settings now work with standard UCP controls and have short text in every launcher language.

Replaces the unsupported Number control with a standard Slider, declares UCP dependencies, adds aligned defaults and excludes bench/research code from runtime packaging. Overlay behavior and existing bindings are unchanged.

## Remaining native work

The direct native Windows-message patch bypasses winProcHandler; its key belongs to Custom Hotkeys. The shared screen-change hook explicitly lets the first module win, which can disable Zoom reset or overlay invalidation. Rendering bounds, buffer format and measured hot-path cost still need acceptance. Keep this in map-editor/interface tooling, not the default Fixes bundle.

Inspected upstream parent: `c403e8271b3734bdbad183725cbc6040d21700b6`. Launcher locales follow
`UCP3-GUI/resources/lang/languages.yaml` (de, en, fr, ru, hu, tr, ch, es, fa).
Category identities follow the current Legacy/GUI catalog, including its existing
English category fallback; setting and description text has full locale entries.
Human translation review and installed GUI/RTL layout checks are pending.

Offline checks passed: YAML/default consistency, actual GUI control types,
all referenced locale keys, Lua 5.4 syntax and runtime package inputs. Runtime
allowlists exclude research/bench Python. These are not game/editor/save/replay
acceptance. Multiplayer testing belongs to players. No Store release is claimed.
