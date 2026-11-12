// SPECTRE C2 Bridge - PostInit
// Runs after mission is fully loaded (after init.sqf)
// NOT USED: config.cpp starts the bridge through vanilla CfgFunctions postInit, and CBA is not required.
// Kept only as a reference for a CBA-based start. Safe to delete.

diag_log "[SPECTRE] PostInit - Bridge starting...";
call SPECTRE_fnc_bridgeInit;
