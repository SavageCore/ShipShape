# FarmGrid

Grid-snapped crop planting for [Windrose](https://store.steampowered.com/app/2372000/), inspired by the Valheim [FarmGrid](https://thunderstore.io/c/valheim/p/Galateam/FarmGrid/) mod. A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod that snaps crop placement - both the ghost preview and the final planted position - to a configurable grid, so your rows come out straight.

## Features

- Crops snap to a grid (default 40uu) during placement
- Ghost preview shows the snapped position in real time
- Works in multiplayer with a client-side install only: the snap is applied before the placement command is serialized, so the server receives (and replicates) the snapped coordinates

## Keybinds

| Key        | Action                              |
| ---------- | ----------------------------------- |
| `Alt+F`    | Toggle grid snapping on/off         |
| `Alt+Up`   | Increase grid size by 10uu          |
| `Alt+Down` | Decrease grid size by 10uu (min 10) |

## Install

Requires UE4SS installed in the game (`Windrose/R5/Binaries/Win64/ue4ss/`).

1. Download the zip from the [latest release](https://github.com/SavageCore/FarmGrid/releases/latest)
2. Extract it into `ue4ss/Mods/` so you end up with:

```
ue4ss/Mods/FarmGrid/
├── enabled.txt
└── Scripts/
    └── main.lua
```

## How it works

Windrose's building placement runs through the Gameplay Ability System: the placement transform travels inside a `UR5BuildingCommand_PreConstruct` object wrapped in GAS target data. The mod catches that command object on creation and snaps its transform in the `MakePreConstructRequest` pre-hook - before the ability validates and serializes it, which is why a client-side install is enough for multiplayer.

The ghost preview actor's transform is rewritten natively every tick, so the mod instead offsets the preview's mesh components by `(snapped - raw)`, which nothing races against.

Known quirk: the preview's valid/invalid (green/red) tint reflects the raw cursor position, not the snapped cell - occasionally it shows red until you nudge the mouse. Placement itself always validates against the snapped position.

## Development

`src/main.lua` is the whole mod. Symlink it into the game's `Scripts/` folder and use UE4SS's _Restart All Mods_ to iterate:

```sh
ln -s "$(pwd)/src/main.lua" \
  "$HOME/.local/share/Steam/steamapps/common/Windrose/R5/Binaries/Win64/ue4ss/Mods/FarmGrid/Scripts/main.lua"
```

Linting is [luacheck](https://github.com/lunarmodules/luacheck), run in CI and as a [lefthook](https://lefthook.dev) pre-commit hook:

```sh
lefthook install
```
