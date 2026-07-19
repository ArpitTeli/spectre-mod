// SPECTRE C2 Bridge - PostInit
// Runs after mission is fully loaded (after init.sqf)
// Auto-executed via CBA XEH - no manual init.sqf editing needed

diag_log "[SPECTRE] PostInit - Bridge starting...";
call SPECTRE_fnc_bridgeInit;
