# ShipShape

Grid-snapped crop planting for [Windrose](https://store.steampowered.com/app/3041230/Windrose/), inspired by the Valheim [FarmGrid](https://thunderstore.io/c/valheim/p/Galateam/FarmGrid/) mod. A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod that snaps crop placement - both the ghost preview and the final planted position - to a configurable grid, so your rows come out straight.

![Preview](assets/preview.png)

## Features

- Crops snap to a grid (default 40uu) during placement
- Grid can be rotated in 15° steps to match an off-axis layout
- Ghost preview shows the snapped position in real time
- Works in multiplayer with a client-side install only: the snap is applied before the placement command is serialized, so the server receives (and replicates) the snapped coordinates

## Keybinds

| Key          | Action                              |
| ------------ | ----------------------------------- |
| `Alt+F`      | Toggle grid snapping on/off         |
| `Alt+Up`     | Increase grid size by 10uu          |
| `Alt+Down`   | Decrease grid size by 10uu (min 10) |
| `Alt+Left`   | Rotate grid 15° counter-clockwise   |
| `Alt+Right`  | Rotate grid 15° clockwise           |

## How it works

Windrose's building placement runs through the Gameplay Ability System: the placement transform travels inside a `UR5BuildingCommand_PreConstruct` object wrapped in GAS target data. The mod catches that command object on creation and snaps its transform in the `MakePreConstructRequest` pre-hook - before the ability validates and serializes it, which is why a client-side install is enough for multiplayer.

The ghost preview actor's transform is rewritten natively every tick, so the mod instead offsets the preview's mesh components by `(snapped - raw)`, which nothing races against.

Known quirk: the preview's valid/invalid (green/red) tint reflects the raw cursor position, not the snapped cell - occasionally it shows red until you nudge the mouse. Placement itself always validates against the snapped position.

## Requirements

- [UE4SS (experimental-latest)](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest)

## Install

### 1. Install UE4SS

Extract the `dwmapi.dll` and `ue4ss` folder to the `R5\Binaries\Win64` directory.

> **Linux tip:** Set your launch option to `WINEDLLOVERRIDES="dwmapi=n,b" %command%` to load UE4SS.

### 2. Configure UE4SS

Open `UE4SS-settings.ini` and update the `[EngineVersionOverride]` section:

```ini
[EngineVersionOverride]
MajorVersion = 5
MinorVersion = 6
```

### 3. Install the Mod

Download the [latest release](https://github.com/SavageCore/ShipShape/releases/latest) and extract it to `R5/Binaries/Win64/ue4ss/Mods/`.

You should end up with:

```
ue4ss/Mods/ShipShape/
├── enabled.txt
└── Scripts/
    └── main.lua
```

## Development

### Prerequisites

- `make`
- A local Windrose installation (Linux/Steam or override path)

### Build & Install

Symlink the mod directly into your game's Mods folder:

```bash
make install
```

The default install path is:

```
~/.local/share/Steam/steamapps/common/Windrose/R5/Binaries/Win64/ue4ss/Mods
```

Override it for a custom location:

```bash
make install INSTALL_DIR=/path/to/ue4ss/Mods
```

Build only (output goes to `build/ShipShape/`):

```bash
make build
```

Linting is [luacheck](https://github.com/lunarmodules/luacheck), run in CI and as a [lefthook](https://lefthook.dev) pre-commit hook:

```sh
lefthook install
```


