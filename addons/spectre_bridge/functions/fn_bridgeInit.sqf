/*
  SPECTRE C2 Bridge - Arma 3 PBO Addon v2.2
  ===========================================
  Auto-executed via CBA XEH PostInit.
  No manual init.sqf editing needed — just enable the mod.

  HOW IT WORKS:
  Arma -> SPECTRE : diag_log writes to the Arma RPT log file.
                    SPECTRE tails that log file and parses SPECTRE_STATE: lines.
  SPECTRE -> Arma : SPECTRE writes "spectre_to_arma.sqf" into the mission folder.
                    This script reads it with loadFile + call compile every 0.75s.
*/

// ─── Rate config ─────────────────────────────────────────────────────────────
private _broadcastRate = 1.0;
private _cmdReadRate   = 0.75;

// ─── Map coordinate lookup ────────────────────────────────────────────────────
// Format: [origin_lat, origin_lng, meters_per_lat, meters_per_lng]
SPECTRE_mapCoords = createHashMap;
SPECTRE_mapCoords set ["altis",    [39.0, 21.0, 111000, 85000]];
SPECTRE_mapCoords set ["stratis",  [39.0, 21.0, 111000, 85000]];
SPECTRE_mapCoords set ["tanoa",    [-6.0, 149.0, 111000, 111000]];
SPECTRE_mapCoords set ["livonia",  [51.0, 17.0, 111000, 63000]];
SPECTRE_mapCoords set ["malden",   [42.0, 3.0, 111000, 78000]];
SPECTRE_mapCoords set ["enoch",    [51.0, 17.0, 111000, 63000]];
SPECTRE_mapCoords set ["tem_anizay", [37.0, 71.0, 111000, 88000]];
SPECTRE_mapCoords set ["cola",     [-23.0, -68.0, 111000, 95000]];

// ─── Global state ─────────────────────────────────────────────────────────────
SPECTRE_blufor         = [];
SPECTRE_executedCmds   = [];
SPECTRE_spottedEnemies = [];
SPECTRE_initialized    = false;

// ─── Get map coordinate data ──────────────────────────────────────────────────
private _mapName = toLowerANSI worldName;
private _mapData = SPECTRE_mapCoords getOrDefault [_mapName, [0, 0, 111000, 85000]];

// ─── Collect friendly units ───────────────────────────────────────────────────
SPECTRE_blufor = allUnits select { side _x == west || side _x == blufor };

if (SPECTRE_blufor isEqualTo []) then {
    SPECTRE_blufor = allUnits select {
        isPlayer _x || (!(vehicle _x isEqualTo _x) && side _x == west)
    };
};

{
    _x setVariable ["SPECTRE_spawnPos",     getPos _x,          false];
    _x setVariable ["SPECTRE_wasAlive",     alive _x,           false];
    _x setVariable ["SPECTRE_callsign",     vehicleVarName _x,  false];
    _x setVariable ["SPECTRE_currentOrder", "",                 false];
} forEach SPECTRE_blufor;

diag_log format ["SPECTRE: Initialized — tracking %1 blufor assets on %2", count SPECTRE_blufor, _mapName];

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
    _cs = _cs regexReplace ["""", ""];

    private _pos   = getPos _unit;
    private _px    = _pos select 0;
    private _py    = _pos select 1;
    private _hp    = round ((1 - getDammage _unit) * 100);
    private _fuel  = if (_unit isKindOf "Man") then { 100 } else { round (fuel _unit * 100) };
    private _type  = if (_unit isKindOf "Man") then { "INFANTRY" } else { "VEHICLE" };
    private _vtype = [_unit] call SPECTRE_fnc_vehicleType;
    private _order = (_unit getVariable ["SPECTRE_currentOrder", ""]) regexReplace ["""", ""];
    private _status = if (!alive _unit) then { "DEAD" } else { "READY" };

    // Map coordinate conversion using lookup table
    private _originLat = _mapData select 0;
    private _originLng = _mapData select 1;
    private _mPerLat   = _mapData select 2;
    private _mPerLng   = _mapData select 3;
    private _lat = _originLat + (_py / _mPerLat);
    private _lng = _originLng + (_px / _mPerLng);

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

    private _originLat = _mapData select 0;
    private _originLng = _mapData select 1;
    private _mPerLat   = _mapData select 2;
    private _mPerLng   = _mapData select 3;
    private _lat = _originLat + (_py / _mPerLat);
    private _lng = _originLng + (_px / _mPerLng);

    format [
        "{""id"":""%1"",""type"":""%2"",""position"":{""x"":%3,""y"":%4,""lat"":%5,""lng"":%6},""state"":""CONFIRMED"",""source"":""VISUAL"",""confidence"":""HIGH""}",
        _contactId, _type,
        round _px, round _py,
        _lat, _lng
    ]
};

// ─── Command executor ─────────────────────────────────────────────────────────
SPECTRE_fnc_execCmd = {
    params [
        "_id",
        "_type",
        "_unitId",
        ["_waypoints", []],
        ["_roe",       ""],
        ["_action",    ""]
    ];

    if (_id in SPECTRE_executedCmds) exitWith {};
    SPECTRE_executedCmds pushBack _id;
    if (count SPECTRE_executedCmds > 600) then {
        SPECTRE_executedCmds = SPECTRE_executedCmds select [300, (count SPECTRE_executedCmds) - 300];
    };

    private _unit = missionNamespace getVariable [_unitId, objNull];
    diag_log format ["SPECTRE CMD: %1 -> %2", _type, _unitId];

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

        case "DISPERSE": {
            {
                private _base   = getPos _x;
                private _offset = [(random 80) - 40, (random 80) - 40, 0];
                _x doMove (_base vectorAdd _offset);
                _x setVariable ["SPECTRE_currentOrder", "DISPERSE", false];
            } forEach SPECTRE_blufor;
        };

        case "EXECUTE_ORDER": {
            if (!isNull _unit) then {
                if (!(_action isEqualTo "")) then {
                    _unit setVariable ["SPECTRE_currentOrder", _action, false];
                };

                private _grp = group _unit;
                while { count (waypoints _grp) > 0 } do {
                    deleteWaypoint [_grp, 0];
                };

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
    private _unitStrs = [];
    { if (!isNull _x) then { _unitStrs pushBack ([_x] call SPECTRE_fnc_serializeUnit); }; } forEach SPECTRE_blufor;

    private _contactStrs = [];
    {
        _contactStrs pushBack ([_x, format ["HOSTILE-%1", _forEachIndex]] call SPECTRE_fnc_serializeContact);
    } forEach (allUnits select {
        private _e = _x;
        (side _e == east || side _e == independent) &&
        alive _e &&
        { _x knowsAbout _e > 0.3 } count SPECTRE_blufor > 0
    });

    private _eventStrs = call SPECTRE_fnc_detectEvents;

    // Get mission path and map name for desktop app auto-detection
    private _missionPath = getMissionPath "";
    private _mapName     = worldName;

    // Get Arma version for compatibility check
    private _armaVersion = "unknown";
    private _versionInfo = productVersion;
    if (count _versionInfo > 1) then {
        _armaVersion = _versionInfo select 1;
    };

    private _json = format [
        "{""missionFolder"":""%1"",""mapName"":""%2"",""armaVersion"":""%3"",""units"":[%4],""contacts"":[%5],""events"":[%6],""timestamp"":%7}",
        _missionPath regexReplace ["\\", "\\\\"],
        _mapName,
        _armaVersion,
        _unitStrs    joinString ",",
        _contactStrs joinString ",",
        _eventStrs   joinString ",",
        round (time * 1000)
    ];

    diag_log format ["SPECTRE_STATE:%1", _json];
};

// ─── Command reader ───────────────────────────────────────────────────────────
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
