/*
  SPECTRE C2 Bridge - Arma 3 SQF v2.1
  =====================================

  SETUP (do once per mission):
  1. Copy this file into your Arma 3 mission folder:
       Documents\Arma 3\missions\YourMission.Altis\SPECTRE_bridge.sqf

  2. Add to init.sqf (create it if it doesn't exist):
       [] execVM "SPECTRE_bridge.sqf";

  3. Give your units variable names in the editor (Alpha_1, Bravo_1, etc.)

  4. Open SPECTRE → Settings → set "Mission Folder" to the full path of this
     mission folder (e.g. C:\Users\You\Documents\Arma 3\missions\MyMission.Altis)

  5. Start SPECTRE first, then launch the Arma mission.

  HOW IT WORKS:
  Arma → SPECTRE : diag_log writes to the Arma RPT log file.
                   SPECTRE tails that log file and parses SPECTRE_STATE: lines.
  SPECTRE → Arma : SPECTRE writes "spectre_to_arma.sqf" into the mission folder.
                   This script reads it with loadFile + call compile every 0.75s.
                   (loadFile resolves relative to the mission folder — no mods needed.)
*/

// ─── Rate config ─────────────────────────────────────────────────────────────
private _broadcastRate = 1.0;   // seconds between state updates sent to SPECTRE
private _cmdReadRate   = 0.75;  // seconds between command polls from SPECTRE

// ─── Global state ─────────────────────────────────────────────────────────────
SPECTRE_blufor         = [];
SPECTRE_executedCmds   = [];  // IDs of commands already executed (deduplication)
SPECTRE_spottedEnemies = [];  // string keys of enemies already reported as spotted
SPECTRE_initialized    = false;

// ─── Collect friendly units ───────────────────────────────────────────────────
SPECTRE_blufor = allUnits select { side _x == west || side _x == blufor };

// Fallback for edge-case mission setups
if (SPECTRE_blufor isEqualTo []) then {
    SPECTRE_blufor = allUnits select {
        isPlayer _x || (!(vehicle _x isEqualTo _x) && side _x == west)
    };
};

// Tag each unit with initial bookkeeping data
{
    _x setVariable ["SPECTRE_spawnPos",     getPos _x,          false];
    _x setVariable ["SPECTRE_wasAlive",     alive _x,           false];
    _x setVariable ["SPECTRE_callsign",     vehicleVarName _x,  false];
    _x setVariable ["SPECTRE_currentOrder", "",                 false];
} forEach SPECTRE_blufor;

diag_log format ["SPECTRE: Initialized — tracking %1 blufor assets", count SPECTRE_blufor];

// ─── Vehicle type classifier ──────────────────────────────────────────────────
SPECTRE_fnc_vehicleType = {
    params ["_v"];
    if (_v isKindOf "Tank")       exitWith { "MBT"      };
    if (_v isKindOf "Helicopter") exitWith { "HELI"     };
    if (_v isKindOf "Plane")      exitWith { "PLANE"    };
    if (_v isKindOf "APC_Wheeled_01_base_F") exitWith { "APC" };
    if (_v isKindOf "IFV_01_base_F"         ||
        _v isKindOf "IFV_02_base_F"         ||
        _v isKindOf "IFV_03_base_F"         ||
        _v isKindOf "APC_Tracked_01_base_F" ||
        _v isKindOf "APC_Tracked_02_base_F" ||
        _v isKindOf "APC_Tracked_03_base_F") exitWith { "IFV" };
    if (_v isKindOf "Car")   exitWith { "RECON"    };
    if (_v isKindOf "Truck_F") exitWith { "TRUCK"  };
    if (_v isKindOf "Man")   exitWith { "INFANTRY" };
    "VEHICLE"
};

// ─── Serialize one unit to a JSON string ──────────────────────────────────────
SPECTRE_fnc_serializeUnit = {
    params ["_unit"];

    private _cs = _unit getVariable ["SPECTRE_callsign", vehicleVarName _unit];
    if (_cs isEqualTo "") then {
        _cs = format ["UNIT_%1", SPECTRE_blufor find _unit];
    };
    _cs = _cs regexReplace ["""", ""];  // strip embedded quotes to stay JSON-safe

    private _pos   = getPos _unit;
    private _px    = _pos select 0;
    private _py    = _pos select 1;
    private _hp    = round ((1 - getDammage _unit) * 100);
    private _fuel  = if (_unit isKindOf "Man") then { 100 } else { round (fuel _unit * 100) };
    private _type  = if (_unit isKindOf "Man") then { "INFANTRY" } else { "VEHICLE" };
    private _vtype = [_unit] call SPECTRE_fnc_vehicleType;
    private _order = (_unit getVariable ["SPECTRE_currentOrder", ""]) regexReplace ["""", ""];
    private _status = if (!alive _unit) then { "DEAD" } else { "READY" };

    // Altis lat/lng approximation for Leaflet
    private _lat = 39.0 + (_py / 111000.0);
    private _lng = 21.0 + (_px / 85000.0);

    format [
        "{""id"":""%1"",""callsign"":""%2"",""type"":""%3"",""vehicle_type"":""%4"",""position"":{""x"":%5,""y"":%6,""lat"":%7,""lng"":%8},""heading"":%9,""health"":%10,""fuel"":%11,""ammo"":100,""status"":""%12"",""current_order"":""%13""}",
        _cs, _cs,
        _type, _vtype,
        round _px, round _py,
        _lat, _lng,
        round getDir _unit,
        _hp, _fuel,
        _status, _order
    ]
};

// ─── Serialize one enemy contact to a JSON string ────────────────────────────
SPECTRE_fnc_serializeContact = {
    params ["_unit", "_contactId"];

    private _pos   = getPos _unit;
    private _px    = _pos select 0;
    private _py    = _pos select 1;
    private _type  = [_unit] call SPECTRE_fnc_vehicleType;
    private _lat   = 39.0 + (_py / 111000.0);
    private _lng   = 21.0 + (_px / 85000.0);

    format [
        "{""id"":""%1"",""type"":""%2"",""position"":{""x"":%3,""y"":%4,""lat"":%5,""lng"":%6},""state"":""CONFIRMED"",""source"":""VISUAL"",""confidence"":""HIGH""}",
        _contactId, _type,
        round _px, round _py,
        _lat, _lng
    ]
};

// ─── Command executor ─────────────────────────────────────────────────────────
// Invoked from the generated SQF as:
//   [cmdId, "TYPE", "unit_id"]                          call SPECTRE_fnc_execCmd
//   [cmdId, "EXECUTE_ORDER", "uid", [[wx,wy]], "ROE", "action"] call SPECTRE_fnc_execCmd
//
// All parameters after the first three are optional.
SPECTRE_fnc_execCmd = {
    params [
        "_id",
        "_type",
        "_unitId",
        ["_waypoints", []],
        ["_roe",       ""],
        ["_action",    ""]
    ];

    // ── Deduplication — skip commands we've already run ───────────────────
    if (_id in SPECTRE_executedCmds) exitWith {};
    SPECTRE_executedCmds pushBack _id;
    if (count SPECTRE_executedCmds > 600) then {
        SPECTRE_executedCmds = SPECTRE_executedCmds select [300, (count SPECTRE_executedCmds) - 300];
    };

    private _unit = missionNamespace getVariable [_unitId, objNull];
    diag_log format ["SPECTRE CMD: %1 → %2", _type, _unitId];

    switch (_type) do {

        case "HOLD": {
            if (!isNull _unit) then {
                _unit doStop _unit;
                _unit setVariable ["SPECTRE_currentOrder", "HOLD", false];
            };
        };

        case "HOLD_ALL": {
            {
                _x doStop _x;
                _x setVariable ["SPECTRE_currentOrder", "HOLD", false];
            } forEach SPECTRE_blufor;
        };

        case "RTB": {
            if (!isNull _unit) then {
                private _sp = _unit getVariable ["SPECTRE_spawnPos", getPos _unit];
                _unit doMove _sp;
                _unit setVariable ["SPECTRE_currentOrder", "RTB", false];
            };
        };

        case "RTB_ALL": {
            {
                private _sp = _x getVariable ["SPECTRE_spawnPos", getPos _x];
                _x doMove _sp;
                _x setVariable ["SPECTRE_currentOrder", "RTB", false];
            } forEach SPECTRE_blufor;
        };

        case "WEAPONS_FREE": {
            {
                _x setCombatMode "RED";
                _x setBehaviour "COMBAT";
                _x setVariable ["SPECTRE_currentOrder", "WEAPONS FREE", false];
            } forEach SPECTRE_blufor;
        };

        case "WEAPONS_SAFE": {
            {
                _x setCombatMode "BLUE";
                _x setBehaviour "AWARE";
                _x setVariable ["SPECTRE_currentOrder", "WEAPONS SAFE", false];
            } forEach SPECTRE_blufor;
        };

        // Rally all alive units to the position of the first alive unit
        case "FORM_UP": {
            private _alive = SPECTRE_blufor select { alive _x };
            if (count _alive > 0) then {
                private _rallyPos = getPos (_alive select 0);
                {
                    _x doMove _rallyPos;
                    _x setVariable ["SPECTRE_currentOrder", "FORM UP", false];
                } forEach _alive;
            };
        };

        // Send each unit to a random position 0-40m from their current spot
        case "DISPERSE": {
            {
                private _base   = getPos _x;
                private _offset = [(random 80) - 40, (random 80) - 40, 0];
                _x doMove (_base vectorAdd _offset);
                _x setVariable ["SPECTRE_currentOrder", "DISPERSE", false];
            } forEach SPECTRE_blufor;
        };

        // Execute a specific mission order with optional waypoints + ROE
        case "EXECUTE_ORDER": {
            if (!isNull _unit) then {
                if (!(_action isEqualTo "")) then {
                    _unit setVariable ["SPECTRE_currentOrder", _action, false];
                };

                // Clear all existing waypoints first
                private _grp = group _unit;
                while { count (waypoints _grp) > 0 } do {
                    deleteWaypoint [_grp, 0];
                };

                // Add the waypoints SPECTRE generated
                {
                    private _wp = _x;
                    private _wx = _wp select 0;
                    private _wy = _wp select 1;
                    if (_wx != 0 || _wy != 0) then {
                        private _newWP = _grp addWaypoint [[_wx, _wy, 0], 0];
                        _newWP setWaypointType             "MOVE";
                        _newWP setWaypointCompletionRadius 15;
                        _newWP setWaypointBehaviour        "COMBAT";
                        _newWP setWaypointSpeed            "FULL";
                    };
                } forEach _waypoints;

                // Apply ROE
                switch (true) do {
                    case (_roe find "HOLD" >= 0): {
                        _unit setCombatMode "BLUE";
                        _unit setBehaviour  "AWARE";
                    };
                    case (_roe find "ENGAGE IF FIRED" >= 0): {
                        _unit setCombatMode "YELLOW";
                        _unit setBehaviour  "AWARE";
                    };
                    default {
                        _unit setCombatMode "RED";
                        _unit setBehaviour  "COMBAT";
                    };
                };
            };
        };

        // Custom text order — sets the display label on the unit
        case "CUSTOM": {
            if (!isNull _unit) then {
                _unit setVariable ["SPECTRE_currentOrder", _action, false];
                diag_log format ["SPECTRE CUSTOM [%1]: %2", _unitId, _action];
            };
        };
    };
};

// ─── Detect events since last poll ────────────────────────────────────────────
SPECTRE_fnc_detectEvents = {
    private _evts = [];

    // Deaths and vehicle destructions
    {
        private _unit = _x;
        if (!alive _unit && (_unit getVariable ["SPECTRE_wasAlive", true])) then {
            _unit setVariable ["SPECTRE_wasAlive", false, false];
            private _cs      = _unit getVariable ["SPECTRE_callsign", vehicleVarName _unit];
            private _evtType = if (_unit isKindOf "Man") then { "UNIT_KIA" } else { "VEHICLE_DESTROYED" };
            _evts pushBack format [
                "{""type"":""%1"",""unit"":""%2"",""id"":""%1_%2_%3""}",
                _evtType, _cs, round time
            ];
        };
    } forEach SPECTRE_blufor;

    // Newly spotted enemies
    // FIX: use _enemy (not _x or _this) inside the inner count block
    //      to avoid variable shadowing between the outer forEach and inner count.
    {
        private _enemy    = _x;
        private _enemyKey = str _enemy;

        if (!(_enemyKey in SPECTRE_spottedEnemies)) then {
            private _spotters = SPECTRE_blufor select { _x knowsAbout _enemy > 0.3 };
            if (count _spotters > 0) then {
                SPECTRE_spottedEnemies pushBack _enemyKey;
                if (count SPECTRE_spottedEnemies > 200) then {
                    SPECTRE_spottedEnemies = SPECTRE_spottedEnemies select [100, (count SPECTRE_spottedEnemies) - 100];
                };
                private _su       = _spotters select 0;
                private _spotterCs = _su getVariable ["SPECTRE_callsign", vehicleVarName _su];
                _evts pushBack format [
                    "{""type"":""CONTACT_SPOTTED"",""unit"":""%1"",""contact_type"":""%2"",""id"":""CS_%3_%4""}",
                    _spotterCs,
                    [_enemy] call SPECTRE_fnc_vehicleType,
                    SPECTRE_blufor find _su,
                    round time
                ];
            };
        };
    // FIX: use private _e in the outer select so the inner count block
    //      can use _x as its own iteration variable without collision.
    } forEach (allUnits select {
        private _e = _x;
        (side _e == east || side _e == independent) &&
        alive _e &&
        { _x knowsAbout _e > 0.3 } count SPECTRE_blufor > 0
    });

    _evts
};

// ─── Full state broadcast via diag_log ────────────────────────────────────────
SPECTRE_fnc_broadcastState = {
    // Friendly units
    private _unitStrs = [];
    { if (!isNull _x) then { _unitStrs pushBack ([_x] call SPECTRE_fnc_serializeUnit); }; } forEach SPECTRE_blufor;

    // Visible enemy contacts
    // FIX: same scoping fix — private _e in outer select, _x free for inner count
    private _contactStrs = [];
    {
        _contactStrs pushBack ([_x, format ["HOSTILE-%1", _forEachIndex]] call SPECTRE_fnc_serializeContact);
    } forEach (allUnits select {
        private _e = _x;
        (side _e == east || side _e == independent) &&
        alive _e &&
        { _x knowsAbout _e > 0.3 } count SPECTRE_blufor > 0
    });

    // Events
    private _eventStrs = call SPECTRE_fnc_detectEvents;

    private _json = format [
        "{""units"":[%1],""contacts"":[%2],""events"":[%3],""timestamp"":%4}",
        _unitStrs    joinString ",",
        _contactStrs joinString ",",
        _eventStrs   joinString ",",
        round (time * 1000)
    ];

    diag_log format ["SPECTRE_STATE:%1", _json];
};

// ─── Command reader ───────────────────────────────────────────────────────────
// SPECTRE writes valid SQF into spectre_to_arma.sqf (in the mission folder).
// loadFile with a relative path resolves relative to the mission folder — the
// same place this script lives, so no absolute paths needed.
// call compile "" is a safe no-op when the file is empty or doesn't exist yet.
SPECTRE_fnc_readCommands = {
    private _sqf = loadFile "spectre_to_arma.sqf";
    if (!(_sqf isEqualTo "")) then {
        call compile _sqf;
    };
};

// ─── Per-unit event handlers (immediate, not waiting for the poll loop) ───────
{
    private _u = _x;
    _u addEventHandler ["Killed", {
        params ["_killed"];
        private _cs = _killed getVariable ["SPECTRE_callsign", vehicleVarName _killed];
        private _t  = if (_killed isKindOf "Man") then { "UNIT_KIA" } else { "VEHICLE_DESTROYED" };
        diag_log format [
            "SPECTRE_EVENT:{""type"":""%1"",""unit"":""%2"",""id"":""%1_%2_%3""}",
            _t, _cs, round time
        ];
    }];
} forEach SPECTRE_blufor;

// ─── Main loop ────────────────────────────────────────────────────────────────
hint "SPECTRE C2 Bridge: ACTIVE";
diag_log "SPECTRE: Bridge running. Broadcasting every 1s, reading commands every 0.75s.";
SPECTRE_initialized = true;

private _lastBroadcast = -999;
private _lastCmdRead   = -999;

while { true } do {
    private _t = time;

    if (_t - _lastBroadcast >= _broadcastRate) then {
        _lastBroadcast = _t;
        call SPECTRE_fnc_broadcastState;
    };

    if (_t - _lastCmdRead >= _cmdReadRate) then {
        _lastCmdRead = _t;
        call SPECTRE_fnc_readCommands;
    };

    sleep 0.1;
};
