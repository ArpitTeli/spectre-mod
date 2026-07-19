class CfgPatches {
    class SPECTRE_bridge {
        name = "SPECTRE C2 Bridge";
        author = "SPECTRE";
        requiredVersion = 2.06;
        requiredAddons[] = {"CBA_A3"};
        version = "1.1.0";
        versionStr = "1.1.0";
        units[] = {};
        weapons[] = {};
    };
};

class CfgFunctions {
    class SPECTRE {
        tag = "SPECTRE";
        class bridge {
            file = "z\spectre\addons\spectre_bridge\functions";
            class bridgeInit {};
        };
    };
};

class Extended_PostInit_EventHandlers {
    class SPECTRE_bridge_postInit {
        init = "call compile preprocessFileLineNumbers '\z\spectre\addons\spectre_bridge\XEH_postInit.sqf'";
    };
};
