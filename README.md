# SPECTRE C2 — Arma 3 Mod

The client-side Arma 3 mod for the [SPECTRE C2](https://github.com/ArpitTeli/spectre-app) desktop app.

It is the **bridge** between Arma 3 and the app. It reports friendly and enemy unit
positions to the app and executes commands the app sends back.

It is one of three SPECTRE repos:
[spectre-app](https://github.com/ArpitTeli/spectre-app) (the C2 app, and the source of the
DLL and terrain tooling), **spectre-mod** (this repo), and
[spectre-terrain-intelligence](https://github.com/ArpitTeli/spectre-terrain-intelligence)
(training-data pipeline for the Tasking Layer model).

---

## Requirements

| Requirement | Needed for |
|---|---|
| Arma 3 (Windows, 64-bit) | Everything |
| SPECTRE C2 app | Using the bridge. The mod does nothing on its own. |
| `spectre_ext_x64.dll` | Reading commands (ships in this repo and the release) |
| **CBA_A3** | Not required. The mod starts through vanilla `postInit`. Only needed if other mods you run need it. |
| **D37_FPV** mod | Only for `FPV` units (`B_FPV_UAV`). Without it, FPV units don't exist and nothing else is affected. |

---

## Install (end user)

### 1. Download the mod
Grab the latest `spectre_bridge.pbo` from the [Releases](../../releases) page.

### 2. Put it in Arma 3
Create an `@SPECTRE` folder in your Arma 3 root directory with this layout (get `mod.cpp`
and `spectre_ext_x64.dll` from this repo's root, and the `.pbo` from step 1):

```
Arma 3\
└── @SPECTRE\
    ├── mod.cpp
    ├── spectre_ext_x64.dll
    └── addons\
        └── spectre_bridge.pbo
```

If you installed the SPECTRE C2 app, it creates this folder for you on first launch, so you can skip this step.

### 3. Launch Arma 3 with the mod
Add `@SPECTRE` in the Arma launcher, or use the command line:

```
arma3_x64.exe -mod=@SPECTRE
```

### 4. Start SPECTRE C2
1. Launch the SPECTRE app and select **Host mode**.
2. Start a mission in Arma 3. Units must be **BLUFOR / West**.
3. The app finds Arma, tails the RPT log and shows your units on the map.

Once both are running, no file paths or folders need configuring.

---

## Supported unit types

| Type | Arma classes | Notes |
|------|--------------|-------|
| **FPV** | `B_FPV_UAV` (D37_FPV mod) | Kamikaze drone with RPG, `KAMIKAZE` command |
| **UAV** | `B_UAV_01_F` (AR-2 Darter) | Recon drone |
| **STOMPER** | `B_UGV_01_rcws_F` | Armed UGV |
| **ED1** | ED-1D UGV variants | Recon mini-UGV |
| Vanilla types | MBT, IFV, APC, CAR, TRUCK, HELI, BOAT, INFANTRY | Standard classification |

Only the BLUFOR (West) side is tracked. The side filter is in `fn_bridgeInit.sqf`; the
mod has no setting for it.

---

## How it works

### Arma → SPECTRE (telemetry)
Every 0.5 s the mod writes one line per record to the Arma RPT log with `diag_log`. The
app tails the log (`%LOCALAPPDATA%\Arma 3\Arma3_x64_*.rpt`) and parses the lines.

| Prefix | Content |
|---|---|
| `SPECTRE_META:` | Mission and map metadata |
| `SPECTRE_UNIT:` | One friendly unit or vehicle: position, state, health |
| `SPECTRE_CONTACT:` | One spotted enemy (ids look like `HOSTILE-N`) |
| `SPECTRE_EVENTS:` | A bracketed, comma-joined list of events since the last tick |

The exact field layout of each record is defined by the broadcast code in
`addons/spectre_bridge/functions/fn_bridgeInit.sqf`. The app parses it in `electron/main.js`
in the spectre-app repo.

### SPECTRE → Arma (commands)
The app writes **one command per file** to `@SPECTRE\addons\spectre_cmds.sqf`. Every 0.3 s
the mod reads and clears that file through `callExtension` (`READ_CLEAR`, using
`spectre_ext_x64.dll`), so each command runs exactly once.

Leading `//` comment lines are ignored. The command is a single pipe-delimited line:

```
<id>|<TYPE>|<unitId>|<x1,y1;x2,y2;...>|<roe>|<action>
```

| Field | Meaning |
|---|---|
| `id` | Numeric command id |
| `TYPE` | Command, e.g. `MOVE_TO`, `ATTACK`, `HOLD`, `KAMIKAZE` |
| `unitId` | Target unit id, or a `HOSTILE-N` contact id for `ATTACK` / `KAMIKAZE` |
| waypoints | `;`-separated `x,y` pairs (may be empty) |
| `roe`, `action` | Optional rules-of-engagement and action label |

Fewer than 3 fields is rejected with `SPECTRE read: malformed command` in the RPT. The
full command list is in the `execCmd` function in `fn_bridgeInit.sqf`, and the command
table in the spectre-app README.

### Trust model
The mod runs whatever valid command appears in `spectre_cmds.sqf`. There is no
authentication. Anything that can write that file can control your BLUFOR units, so keep it
to a local, trusted machine and don't run it on a shared or public server.

---

## For developers

### Layout

```
addons/spectre_bridge/
├── config.cpp                 CfgPatches + CfgFunctions (vanilla postInit = 1)
├── $PBOPREFIX$                PBO prefix z\spectre\addons\spectre_bridge
├── functions/
│   ├── fn_bridgeInit.sqf      The whole bridge: broadcast, command reader/executor, KAMIKAZE, events
│   └── export_*.sqf / *.txt   One-time terrain export tools (run from the Eden debug console)
├── script/                    component.hpp, macro.hpp
└── XEH_postInit.sqf           Not referenced by config.cpp (legacy CBA entry point)
.hemtt/project.toml            HEMTT build config
create_pbo.py                  Python PBO packager
mod.cpp                        Mod descriptor
spectre_ext_x64.dll            Prebuilt callExtension file reader
```

### Building the PBO

Needs Python 3.10+ and `numpy`.

```bash
pip install numpy
python create_pbo.py "addons\spectre_bridge" "dist\spectre_bridge.pbo"
```

Copy the result to `@SPECTRE\addons\`. (`.hemtt/project.toml` is the config for the
[HEMTT](https://hemtt.dev) build tool, an alternative to `create_pbo.py`.)

### Rebuilding the DLL

The DLL source is `spectre_ext/spectre_ext.c` in the
[spectre-app](https://github.com/ArpitTeli/spectre-app) repo. This repo only holds the
prebuilt binary. Build it with MSVC from a *x64 Native Tools* prompt:

```bash
cl /LD spectre_ext.c /DEF:spectre_ext_x64.def /Fe:spectre_ext_x64.dll
```

(`spectre_ext_x64.def` sits next to the source in spectre-app.) The DLL is 64-bit only.

### Export tools

`export_*.sqf` dump terrain data (objects, roads, heightmap, cost grid) to the RPT. The
Python scripts in spectre-app's `scripts/` (`rpt_to_*.py`) turn those dumps into the map
files the app uses.

---

## Troubleshooting

**App shows "not connected" / no units appear**
- Check Arma was launched with `-mod=@SPECTRE`.
- Open the RPT log and look for `[SPECTRE]` and `SPECTRE:` lines. A healthy start logs
  `SPECTRE: Bridge running`, and the in-game hint says `SPECTRE C2 Bridge: ACTIVE`.
- Make sure the units are BLUFOR / West.
- If the bridge errors on start, restart Arma fully (not just the mission).

**Commands not reaching Arma**
- Confirm the app wrote `@SPECTRE\addons\spectre_cmds.sqf`.
- Confirm `spectre_ext_x64.dll` is in the `@SPECTRE\` root, not in `addons\`.
- Look in the RPT for `SPECTRE: Executed OK:` (success), `SPECTRE read: malformed command`
  (bad format) or `SPECTRE readCommands DLL error:` (DLL problem).

**FPV drones don't appear**
- The D37_FPV mod must be loaded as well.

---

## License

All rights reserved. Part of the SPECTRE C2 system for Arma 3.
