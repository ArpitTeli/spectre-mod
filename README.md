# SPECTRE C2 — Arma 3 Mod

The Arma 3 client-side mod for the [SPECTRE C2](https://github.com/ArpitTeli/spectre-app) desktop application.

This mod is the **bridge** between Arma 3 and the SPECTRE app. It broadcasts friendly/enemy unit positions to the app and executes commands received from it.

---

## Install (end user — 2 minutes)

### 1. Download the mod
Grab the latest `spectre_bridge.pbo` from the [Releases](../../releases) page.

### 2. Extract into Arma 3
Copy the `@SPECTRE` folder (or create it) into your Arma 3 root directory:

```
E:\Games\Arma 3\
└── @SPECTRE\
    ├── mod.cpp
    ├── spectre_ext_x64.dll
    └── addons\
        └── spectre_bridge.pbo
```

**Or** — if you installed SPECTRE C2 from the app installer, it does this automatically and prompts you to install the mod on first launch. This manual route is only needed if you skip that.

### 3. Install CBA (optional)
The mod no longer *requires* CBA — it uses vanilla Arma `postInit` to auto-start. CBA is only needed if other mods you run depend on it.

### 4. Launch Arma 3 with the mod
Launch Arma with the mod enabled. From the launcher, add the `@SPECTRE` mod folder, or add to the command line:

```
arma3_x64.exe -mod=@SPECTRE
```

### 5. Start SPECTRE C2
1. Launch the SPECTRE app
2. Select **Host mode**
3. In the game, start your mission (units must be **BLUFOR/West** side)
4. The app auto-detects Arma, tails the RPT log, and shows your units on the map

The bridge is fully automatic once both are running — no manual file paths or folders to configure.

---

## Supported Unit Types

| Type | Arma classes | Notes |
|------|-------------|-------|
| **FPV** | `B_FPV_UAV` (D37_FPV mod) | Kamikaze drone with RPG — `KAMIKAZE` command |
| **UAV** | `B_UAV_01_F` (AR-2 Darter) | Recon drone |
| **STOMPER** | `B_UGV_01_rcws_F` | Armed UGV |
| **ED1** | ED-1D UGV variants | Recon mini-UGV |
| + all vanilla types | MBT, IFV, APC, CAR, TRUCK, HELI, BOAT, INFANTRY | Standard classification |

---

## How It Works

**Arma → SPECTRE:** The mod writes `SPECTRE_UNIT:` / `SPECTRE_META:` / `SPECTRE_CONTACT:` / `SPECTRE_EVENTS:` lines into the Arma RPT log every 0.5s. The app tails the log and parses them.

**SPECTRE → Arma:** The app writes commands to `spectre_cmds.sqf` in the `@SPECTRE\addons\` folder. The mod polls it every 0.3s via `callExtension` (the included `spectre_ext_x64.dll`) and executes them in-game.

---

## For Developers

### Building the PBO

Requires Python 3.10+ with `numpy`.

```bash
python create_pbo.py "addons\spectre_bridge" "dist\spectre_bridge.pbo"
```

Then copy the output to your Arma mod folder.

### File layout

```
@SPECTRE/
├── mod.cpp                      # Mod descriptor
├── spectre_ext_x64.dll          # callExtension file-reader DLL
└── addons/
    └── spectre_bridge.pbo       # The bridge (built from addons/spectre_bridge/)
```

Source lives in `addons/spectre_bridge/`:
- `config.cpp` — CfgPatches + CfgFunctions (vanilla `postInit = 1` — no CBA needed)
- `$PBOPREFIX$` — PBO virtual prefix `z\spectre\addons\spectre_bridge`
- `functions/fn_bridgeInit.sqf` — the entire bridge (broadcast, command exec, KAMIKAZE, events)
- `functions/export_*.sqf` — one-time terrain export tools (Eden Editor debug console)

### Rebuilding the DLL

The DLL source is `spectre_ext/spectre_ext.c` in the main repo. It's a minimal `callExtension` file-reader. Rebuild with MSVC:

```bash
cl /LD spectre_ext.c /Fe:spectre_ext_x64.dll
```

---

## Troubleshooting

**App shows "not connected" / no units appear**
- Confirm Arma is launched with `-mod=@SPECTRE`
- Check the Arma RPT log (`%LOCALAPPDATA%\Arma 3\Arma3_x64_*.rpt`) for `[SPECTRE]` lines
- If you see `SPECTRE CLASSIFIER:` or `[SPECTRE] PostInit` errors, restart Arma fully

**Commands not reaching Arma**
- Confirm the app wrote to `@SPECTRE\addons\spectre_cmds.sqf`
- Check the mod's `spectre_ext_x64.dll` is in the `@SPECTRE\` root (not just addons/)

---

Part of the SPECTRE C2 System for Arma 3.
