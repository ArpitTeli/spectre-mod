class CfgPatches {
    class SPECTRE_bridge {
        name = "SPECTRE C2 Bridge";
        author = "SPECTRE";
        requiredVersion = 2.06;
        requiredAddons[] = {};
        version = "1.2.0";
        versionStr = "1.2.0";
        units[] = {};
        weapons[] = {};
    };
};

class CfgFunctions {
    class SPECTRE {
        tag = "SPECTRE";
        class bridge {
            file = "z\spectre\addons\spectre_bridge\functions";
            // postInit = 1 auto-runs SPECTRE_fnc_bridgeInit at mission start.
            // This is the vanilla (no-CBA) replacement for the old
            // Extended_PostInit_EventHandlers block. No mission init.sqf needed.
            class bridgeInit { postInit = 1; };
        };
    };
};
