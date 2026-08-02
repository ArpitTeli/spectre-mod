/*
  SPECTRE C2 Bridge - Arma 3 PBO Addon v2.3
  ===========================================
  Auto-executed via CBA XEH PostInit.
  No manual init.sqf editing needed — just enable the mod.

  HOW IT WORKS:
  Arma -> SPECTRE : diag_log writes to the Arma RPT log file.
                    SPECTRE tails that log file and parses SPECTRE_STATE: lines.
  SPECTRE -> Arma : SPECTRE writes "spectre_to_arma.sqf" into the mission folder.
                    This script reads it with loadFile + call compile every 0.75s.
*/

// ─── Rate config (globals — spawn block can't see private locals) ─────────────
SPECTRE_broadcastRate = 0.5;
SPECTRE_cmdReadRate   = 0.3;

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
SPECTRE_spottedEnemies = [];
SPECTRE_initialized    = false;
// Maps contact IDs ("HOSTILE-N") -> enemy object so ATTACK/KAMIKAZE commands
// can resolve their target by the ID the app sends. Rebuilt each broadcast.
SPECTRE_contactMap     = createHashMap;

// ─── Get map coordinate data ──────────────────────────────────────────────────
private _mapName = toLowerANSI worldName;
SPECTRE_mapData = SPECTRE_mapCoords getOrDefault [_mapName, [0, 0, 111000, 85000]];

// ─── Collect friendly units and vehicles ──────────────────────────────────────
SPECTRE_blufor = [];

// Infantry
private _infantry = allUnits select { side _x == west || side _x == blufor };
if (_infantry isEqualTo []) then {
    _infantry = allUnits select {
        isPlayer _x || (!(vehicle _x isEqualTo _x) && side _x == west)
    };
};
SPECTRE_blufor append _infantry;

// Vehicles (only crewed or player-owned)
private _vehicles = vehicles select {
    side _x == west || side _x == blufor
};
{
    if !(_x in SPECTRE_blufor) then {
        SPECTRE_blufor pushBack _x;
    };
} forEach _vehicles;

// Assign variable names to units that don't have one (for command targeting)
{
    private _vn = vehicleVarName _x;
    if (_vn isEqualTo "") then {
        _vn = format ["SPECTRE_%1", _forEachIndex];
        _x setVehicleVarName _vn;
        // Also register in missionNamespace so getVariable works
        missionNamespace setVariable [_vn, _x];
    };
    _x setVariable ["SPECTRE_spawnPos",     getPos _x,          false];
    _x setVariable ["SPECTRE_wasAlive",     alive _x,           false];
    _x setVariable ["SPECTRE_callsign",     _vn,                false];
    _x setVariable ["SPECTRE_currentOrder", "",                 false];
} forEach SPECTRE_blufor;

diag_log format ["SPECTRE: Initialized — tracking %1 blufor assets on %2", count SPECTRE_blufor, _mapName];

// ─── Vehicle type classifier ──────────────────────────────────────────────────
SPECTRE_fnc_vehicleType = {
    params ["_v"];
    private _t = typeOf _v;
    // Drones — check class name patterns first
    if ("FPV" in _t) exitWith { "FPV" };
    if (_v isKindOf "UAV_01_base_F") exitWith { "UAV" };
    if ("UGV_01" in _t) exitWith { "STOMPER" };
    if ("UGV_02" in _t) exitWith { "ED1" };
    // Conventional types
    if (_v isKindOf "Helicopter")  exitWith { "HELI" };
    if (_v isKindOf "Plane")       exitWith { "PLANE" };
    if (_v isKindOf "Ship")        exitWith { "BOAT" };
    if (_v isKindOf "Truck_F")     exitWith { "TRUCK" };
    if (_v isKindOf "Tank")        exitWith { "TANK" };
    if (_v isKindOf "Wheeled_APC_F") exitWith { "IFV" };
    if (_v isKindOf "Car")         exitWith { "CAR" };
    if (_v isKindOf "Man")         exitWith { "INFANTRY" };
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
    private _pz    = _pos select 2;
    private _hp    = round ((1 - getDammage _unit) * 100);
    private _vtype = [_unit] call SPECTRE_fnc_vehicleType;
    private _order = (_unit getVariable ["SPECTRE_currentOrder", ""]) regexReplace ["""", ""];
    private _status = if (!alive _unit) then { "DEAD" } else { "READY" };

    // Map coordinate conversion using lookup table
    private _originLat = SPECTRE_mapData select 0;
    private _originLng = SPECTRE_mapData select 1;
    private _mPerLat   = SPECTRE_mapData select 2;
    private _mPerLng   = SPECTRE_mapData select 3;
    private _lat = _originLat + (_py / _mPerLat);
    private _lng = _originLng + (_px / _mPerLng);

    // Fuel (vehicles only)
    private _fuelStr = "";
    if !(_unit isKindOf "Man") then {
        _fuelStr = format [",""fuel"":%1", round (fuel _unit * 100)];
    };

    // Speed in km/h (vehicles only)
    private _speedStr = "";
    if !(_unit isKindOf "Man") then {
        _speedStr = format [",""speed"":%1", round (speed _unit)];
    };

    // Ammo count (total magazines)
    private _ammoStr = format [",""ammo"":%1", count magazines _unit];

    // Vehicle membership (for infantry inside vehicles)
    private _vehicleStr = "";
    private _roleStr = "";
    if (_unit isKindOf "Man") then {
        private _veh = vehicle _unit;
        if !(_veh isEqualTo _unit) then {
            private _vcs = _veh getVariable ["SPECTRE_callsign", vehicleVarName _veh];
            if (_vcs isEqualTo "") then {
                _vcs = format ["UNIT_%1", SPECTRE_blufor find _veh];
            };
            _vehicleStr = format [",""vehicle"":""%1""", _vcs regexReplace ["""", ""]];
            private _role = assignedVehicleRole _unit;
            if (count _role > 0) then {
                _roleStr = format [",""vehicle_role"":""%1""", _role select 0];
            };
        };
    };

    // Crew list (for vehicles)
    private _crewStr = "";
    if !(_unit isKindOf "Man") then {
        private _crewArr = [];
        {
            private _ccs = _x getVariable ["SPECTRE_callsign", vehicleVarName _x];
            if (_ccs isEqualTo "") then {
                _ccs = format ["UNIT_%1", SPECTRE_blufor find _x];
            };
            private _crole = assignedVehicleRole _x;
            private _croleStr = if (count _crole > 0) then { _crole select 0 } else { "CARGO" };
            _crewArr pushBack format ["""%1:%2""", _ccs regexReplace ["""", ""], _croleStr];
        } forEach (crew _unit);
        if (count _crewArr > 0) then {
            _crewStr = format [",""crew"":[%1]", _crewArr joinString ","];
        };
    };

    private _orderStr = "";
    if !(_order isEqualTo "") then {
        _orderStr = format [",""order"":""%1""", _order];
    };

    format [
        "{""id"":""%1"",""vtype"":""%2"",""pos"":{""x"":%3,""y"":%4,""z"":%5,""lat"":%6,""lng"":%7},""hdg"":%8,""hp"":%9%10%11%12%13%14%15%16,""st"":""%17""}",
        _cs, _vtype,
        round _px, round _py,
        round _pz,
        _lat, _lng,
        round getDir _unit,
        _hp,
        _fuelStr,
        _speedStr,
        _ammoStr,
        _vehicleStr,
        _roleStr,
        _crewStr,
        _orderStr,
        _status
    ]
};

// ─── Serialize one enemy contact to a JSON string ────────────────────────────
SPECTRE_fnc_serializeContact = {
    params ["_unit", "_contactId"];
    if (isNull _unit) exitWith { "" }; // enemy may be deleted mid-iteration

    private _pos   = getPos _unit;
    private _px    = _pos select 0;
    private _py    = _pos select 1;
    private _type  = [_unit] call SPECTRE_fnc_vehicleType;

    private _originLat = SPECTRE_mapData select 0;
    private _originLng = SPECTRE_mapData select 1;
    private _mPerLat   = SPECTRE_mapData select 2;
    private _mPerLng   = SPECTRE_mapData select 3;
    private _lat = _originLat + (_py / _mPerLat);
    private _lng = _originLng + (_px / _mPerLng);

    format [
        "{""id"":""%1"",""type"":""%2"",""position"":{""x"":%3,""y"":%4,""lat"":%5,""lng"":%6},""state"":""CONFIRMED"",""source"":""VISUAL"",""confidence"":""HIGH""}",
        _contactId, _type,
        round _px, round _py,
        _lat, _lng
    ]
};

// ─── Artillery strike helper ──────────────────────────────────────────────────
SPECTRE_fnc_artilleryStrike = {
    params ["_unit", "_targetPos", "_rounds", "_ammoType"];
    private _veh = vehicle _unit;

    for "_i" from 1 to _rounds do {
        [_veh, [_targetPos select 0, _targetPos select 1, 0], _ammoType] spawn {
            params ["_v", "_tp", "_ammo"];
            private _delay = random 2;
            sleep _delay;
            _v doArtilleryFire [_tp, _ammo];
        };
    };
    diag_log format ["SPECTRE: Artillery %1x %2 fired at %3", _rounds, _ammoType, _targetPos];
};

// ─── Manual flight for AI-less FPV drones (D37 mod strips the pilot turret) ──
// The D37 FPV config empties class Turrets and sets hasGunner = 0, so the
// drone has no AI pilot and doMove/flyInHeight are no-ops. Steer it directly
// with setVelocity instead. Runs on real time (diag_tickTime + uiSleep).
SPECTRE_fnc_fpvFlyTo = {
    params ["_drone", "_pos", ["_speed", 45], ["_timeout", 120], ["_alt", 50]];
    private _end = diag_tickTime + _timeout;
    while { alive _drone && diag_tickTime < _end } do {
        private _dpos = getPosATL _drone;
        if (_dpos distance2D _pos < 15) exitWith {};
        private _dirVec = [_pos select 0, _pos select 1, 0] vectorDiff [_dpos select 0, _dpos select 1, 0];
        private _len = vectorMagnitude _dirVec;
        if (_len < 0.1) exitWith {};
        _dirVec = _dirVec vectorMultiply (1 / _len);
        private _targetAlt = if (count _pos > 2 && { (_pos select 2) > 1 }) then { _pos select 2 } else { _alt };
        private _vz = ((_targetAlt - (_dpos select 2)) * 0.6) max -12;
        _drone setVelocity [(_dirVec select 0) * _speed, (_dirVec select 1) * _speed, _vz];
        _drone setVectorDirAndUp [[_dirVec select 0, _dirVec select 1, 0], [0, 0, 1]];
        _drone flyInHeight 0; // keep the (absent) engine AI from interfering
        uiSleep 0.2;
    };
    _drone setVelocity [0, 0, -5];
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

    private _unit = missionNamespace getVariable [_unitId, objNull];
    diag_log format ["SPECTRE CMD: %1 -> %2 (units=%3)", _type, _unitId, count SPECTRE_blufor];

    switch (_type) do {

        case "KAMIKAZE": {
            private _drone = _unit;
            // Resolve target: contact map first (HOSTILE-N), then missionNamespace,
            // then fall back to a marker at the contact's last-known position
            // (sent by the app in _waypoints as [[x,y]]).
            private _target = SPECTRE_contactMap getOrDefault [_roe, objNull];
            if (isNull _target) then {
                _target = missionNamespace getVariable [_roe, objNull];
            };
            if (isNull _target && count _waypoints > 0) then {
                private _wp = _waypoints select 0;
                if (count _wp >= 2) then {
                    _target = "Sign_Arrow_Red_F" createVehicle [_wp select 0, _wp select 1, 0];
                };
            };
            if (!isNull _drone && !isNull _target) then {
                private _vtype = [_drone] call SPECTRE_fnc_vehicleType;
                if (_vtype == "FPV") then {
                    // D37 FPVs have no AI pilot (Turrets stripped) — steer the
                    // drone manually with setVelocity: 50m terrain-following
                    // approach, then a dive when close to the target.
                    [_drone, _target] spawn {
                        params ["_drone", "_target"];
                        private _timeout = diag_tickTime + 60;
                        diag_log format ["SPECTRE KAMIKAZE FPV chase start: drone=%1 target=%2", _drone, _target];
                        private _lastPos = getPosATL _target;
                        while {alive _drone && diag_tickTime < _timeout} do {
                            // Keep chasing the last-known position even if the
                            // target dies mid-chase.
                            if (alive _target) then { _lastPos = getPosATL _target; };
                            private _tpos = _lastPos;
                            private _dpos = getPosATL _drone;
                            private _dist = _dpos distance2D _tpos;
                            private _dirVec = [_tpos select 0, _tpos select 1, 0] vectorDiff [_dpos select 0, _dpos select 1, 0];
                            private _len = vectorMagnitude _dirVec;
                            if (_len < 0.1) exitWith {};
                            _dirVec = _dirVec vectorMultiply (1 / _len);
                            private _speed = 60;
                            // Dive profile: descend once close, otherwise hold 50m AGL
                            private _targetAlt = if (_dist < 150) then { _tpos select 2 } else { 50 };
                            private _vz = ((_targetAlt - (_dpos select 2)) * 0.8) max -25;
                            _drone setVelocity [(_dirVec select 0) * _speed, (_dirVec select 1) * _speed, _vz];
                            _drone setVectorDirAndUp [[_dirVec select 0, _dirVec select 1, 0], [0, 0, 1]];
                            _drone flyInHeight 0;
                            // Detonate on impact proximity
                            if (_dist < 10 && { (_dpos select 2) - (_tpos select 2) < 8 }) then {
                                private _shell = _drone getVariable ["attachedShell", objNull];
                                if (!isNull _shell) then { triggerAmmo _shell; };
                                _drone setDamage 1;
                            };
                            uiSleep 0.2;
                        };
                        diag_log format ["SPECTRE KAMIKAZE chase end: droneAlive=%1 targetAlive=%2", alive _drone, alive _target];
                    };
                } else {
                    if (count _waypoints > 1) then {
                        // Multi-waypoint terrain-following flight profile
                        [_drone, _target, _waypoints] spawn {
                            params ["_drone", "_target", "_wps"];
                            // UAVs need a fly height to leave the ground
                            _drone flyInHeight 50;
                            private _wpIdx = 0;
                            while {alive _drone && alive _target && _wpIdx < count _wps} do {
                                private _wp = _wps select _wpIdx;
                                private _alt = if (count _wp > 2) then { _wp select 2 } else { 50 };
                                private _pos = [_wp select 0, _wp select 1, _alt];
                                _drone doMove _pos;
                                _drone flyInHeight _alt;
                                // Wait until drone is within 40m of waypoint or dead.
                                // diag_tickTime + uiSleep are real-time: the chase
                                // keeps running even when Arma is backgrounded and
                                // the simulation is throttled.
                                private _timeout = diag_tickTime + 30;
                                while {alive _drone && (_drone distance _pos) >= 40 && diag_tickTime < _timeout} do {
                                    uiSleep 0.2;
                                };
                                _wpIdx = _wpIdx + 1;
                            };
                            // Final phase: ensure drone is heading to target ground position
                            if (alive _drone && alive _target) then {
                                _drone flyInHeight 0;
                                _drone doMove (getPos _target);
                            };
                        };
                    } else {
                        // Simple direct approach (fallback) — 60s real-time timeout
                        [_drone, _target] spawn {
                            params ["_drone", "_target"];
                            private _timeout = diag_tickTime + 60;
                            // UAVs need a fly height to leave the ground
                            _drone flyInHeight 50;
                            diag_log format ["SPECTRE KAMIKAZE chase start: drone=%1 target=%2", _drone, _target];
                            while {alive _drone && alive _target && diag_tickTime < _timeout} do {
                                _drone doMove (getPos _target);
                                _drone flyInHeight 50;
                                uiSleep 0.5;
                            };
                            diag_log format ["SPECTRE KAMIKAZE chase end: droneAlive=%1 targetAlive=%2", alive _drone, alive _target];
                        };
                    };
                };
                _drone setVariable ["SPECTRE_currentOrder", "KAMIKAZE", false];
                diag_log format ["SPECTRE KAMIKAZE [%1] -> %2 (wps=%3)", _unitId, _roe, count _waypoints];
            } else {
                if (isNull _drone) then {
                    diag_log format ["SPECTRE KAMIKAZE FAIL: drone=%1 not found", _unitId];
                } else {
                    diag_log format ["SPECTRE KAMIKAZE FAIL: target=%1 not found (no position fallback)", _roe];
                };
            };
        };

        case "HOLD": {
            if (!isNull _unit) then {
                doStop _unit;
                _unit setVariable ["SPECTRE_currentOrder", "HOLD", false];
            };
        };

        case "HOLD_ALL": {
            {
                doStop _x;
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

        case "MOVE_TO": {
            if (!isNull _unit && count _waypoints > 0) then {
                private _veh = vehicle _unit;
                private _grp = group _unit;
                private _vtype = [_veh] call SPECTRE_fnc_vehicleType;

                // Parse speed from _action param (format: "speed:120")
                private _speedStr = _action;
                private _spd = "NORMAL";
                if (_speedStr find "speed:" >= 0) then {
                    private _val = parseNumber (_speedStr select [6]);
                    if (_val > 0) then {
                        if (_val < 80) then { _spd = "LIMITED"; }
                        else { if (_val > 160) then { _spd = "FULL"; }; };
                    };
                };

                // Multi-waypoint: use group waypoint system
                if (count _waypoints > 1) then {
                    // Clear existing group waypoints
                    while { count (waypoints _grp) > 0 } do {
                        deleteWaypoint ((waypoints _grp) select 0);
                    };

                    {
                        private _wpData = _x;
                        private _alt = if (count _wpData > 2) then { _wpData select 2 } else { -1 };
                        // Bake altitude into the waypoint Z (ASL). Arma has no
                        // setWaypointAltitude command; air units follow flyInHeight.
                        private _pos = [_wpData select 0, _wpData select 1, (_alt max 0)];
                        private _newWp = _grp addWaypoint [_pos, 80];
                        _newWp setWaypointType "MOVE";
                        _newWp setWaypointSpeed _spd;
                        _newWp setWaypointStatements ["true", ""];
                        if (_alt >= 0 && { _veh isKindOf "Air" }) then {
                            _veh flyInHeight _alt;
                        };
                    } forEach _waypoints;

                    // FPV drones ignore group waypoints (no AI pilot) — fly them manually.
                    if (_vtype == "FPV") then {
                        [_veh, _waypoints, 45, 120, 50] spawn {
                            params ["_veh", "_wps", "_speed", "_timeout", "_alt"];
                            private _end = diag_tickTime + _timeout;
                            private _wpIdx = 0;
                            while { alive _veh && diag_tickTime < _end && _wpIdx < count _wps } do {
                                private _wp = _wps select _wpIdx;
                                private _wpAlt = if (count _wp > 2) then { _wp select 2 } else { _alt };
                                private _pos = [_wp select 0, _wp select 1, _wpAlt];
                                [_veh, _pos, _speed, 30, _wpAlt] call SPECTRE_fnc_fpvFlyTo;
                                _wpIdx = _wpIdx + 1;
                            };
                        };
                    };

                    _unit setVariable ["SPECTRE_currentOrder", "MOVE TO (MULTI)", false];
                    diag_log format ["SPECTRE MOVE_TO [%1]: %2 waypoints, speed %3", _unitId, count _waypoints, _spd];
                } else {
                    // Single waypoint: direct move
                    private _wp = _waypoints select 0;
                    private _pos = [_wp select 0, _wp select 1, 0];
                    if (_vtype == "FPV") then {
                        // No AI pilot on D37 FPVs — manual flight.
                        [_veh, _pos, 45, 120, 50] spawn SPECTRE_fnc_fpvFlyTo;
                    } else {
                        if (_veh isKindOf "Air") then {
                            // UAVs/helis must be commanded at vehicle level; the
                            // driver is a dummy unit that ignores doMove.
                            _veh doMove _pos;
                            _veh flyInHeight 50;
                        } else {
                            if (_veh != _unit) then {
                                private _d = driver _veh;
                                if (!isNull _d) then {
                                    _d doMove _pos;
                                } else {
                                    _unit doMove _pos;
                                };
                            } else {
                                _unit doMove _pos;
                            };
                        };
                    };
                    _unit setVariable ["SPECTRE_currentOrder", "MOVE TO", false];
                    diag_log format ["SPECTRE MOVE_TO [%1]: %2", _unitId, _pos];
                };
            };
        };

        case "ATTACK": {
            if (!isNull _unit) then {
                // Resolve target: contact map first (HOSTILE-N), then missionNamespace,
                // then fall back to a temporary target at the contact's last-known
                // position (sent by the app in _waypoints as [[x,y]]).
                private _target = SPECTRE_contactMap getOrDefault [_roe, objNull];
                if (isNull _target) then {
                    _target = missionNamespace getVariable [_roe, objNull];
                };
                if (isNull _target && count _waypoints > 0) then {
                    private _wp = _waypoints select 0;
                    if (count _wp >= 2) then {
                        _target = "Sign_Arrow_Red_F" createVehicle [_wp select 0, _wp select 1, 0];
                    };
                };
                if (isNull _target) then {
                    diag_log format ["SPECTRE ATTACK FAIL: target=%1 not found (no position fallback)", _roe];
                } else {
                    private _veh = vehicle _unit;
                    private _g = gunner _veh;
                    if (_veh != _unit && !isNull _g) then {
                        _g doTarget _target;
                        _g doFire _target;
                        // Force fire: bypasses ROE/weapons-safe stalls that block
                        // AI doFire. fireAtTarget fires the main gun directly.
                        _veh fireAtTarget [_target, "mainGun"];
                        diag_log format ["SPECTRE ATTACK FIRED [%1] -> %2", _unitId, _roe];
                    } else {
                        _unit doTarget _target;
                        _unit doFire _target;
                        diag_log format ["SPECTRE ATTACK FIRED (no gunner, direct) [%1] -> %2", _unitId, _roe];
                    };
                    _unit setVariable ["SPECTRE_currentOrder", "ATTACK", false];
                    diag_log format ["SPECTRE ATTACK [%1] -> %2", _unitId, _roe];
                };
            };
        };

        case "ATTACK_POS": {
            if (!isNull _unit && count _waypoints > 0) then {
                private _wp = _waypoints select 0;
                private _pos = [_wp select 0, _wp select 1, 0];
                private _veh = vehicle _unit;
                private _tgt = "Sign_Arrow_Red_F" createVehicle _pos;
                if (_veh != _unit) then {
                    private _g = gunner _veh;
                    if (!isNull _g) then {
                        _g doTarget _tgt;
                        _g doFire _tgt;
                    } else {
                        _unit doTarget _tgt;
                        _unit doFire _tgt;
                    };
                } else {
                    _unit doTarget _tgt;
                    _unit doFire _tgt;
                };
                [_tgt] spawn { sleep 10; deleteVehicle (_this select 0); };
                _unit setVariable ["SPECTRE_currentOrder", "FIRE AT POSITION", false];
                diag_log format ["SPECTRE ATTACK_POS [%1]: %2", _unitId, _pos];
            };
        };

        case "ARTILLERY_STRIKE": {
            if (!isNull _unit && count _waypoints > 0) then {
                private _wp = _waypoints select 0;
                private _targetPos = [_wp select 0, _wp select 1, 0];
                private _rounds = parseNumber _roe;
                if (_rounds <= 0) then { _rounds = 6; };
                private _ammo = _action;
                if (_ammo isEqualTo "") then { _ammo = "HE"; };

                private _veh = vehicle _unit;
                if (_veh != _unit) then {
                    [_veh, _targetPos, _rounds, _ammo] call SPECTRE_fnc_artilleryStrike;
                } else {
                    [_unit, _targetPos, _rounds, _ammo] call SPECTRE_fnc_artilleryStrike;
                };
                _unit setVariable ["SPECTRE_currentOrder", format ["ARTILLERY %1x %2", _rounds, _ammo], false];
                diag_log format ["SPECTRE ARTILLERY [%1]: %2 rounds %3 at %4", _unitId, _rounds, _ammo, _targetPos];
            };
        };

        case "LAND_AT": {
            if (!isNull _unit && count _waypoints > 0) then {
                private _wp = _waypoints select 0;
                private _pos = [_wp select 0, _wp select 1, 0];
                private _veh = vehicle _unit;
                if (_veh != _unit && {_veh isKindOf "Air"}) then {
                    _veh doMove _pos;
                    _veh land "LAND";
                } else {
                    _unit doMove _pos;
                };
                _unit setVariable ["SPECTRE_currentOrder", "LAND AT", false];
                diag_log format ["SPECTRE LAND_AT [%1]: %2", _unitId, _pos];
            };
        };

        case "SMOKE_AT": {
            if (!isNull _unit && count _waypoints > 0) then {
                private _wp = _waypoints select 0;
                private _pos = [_wp select 0, _wp select 1, 0];
                "SmokeShell" createVehicle _pos;
                _unit setVariable ["SPECTRE_currentOrder", "SMOKE", false];
                diag_log format ["SPECTRE SMOKE_AT [%1]: %2", _unitId, _pos];
            };
        };

        case "ADJUST_FIRE": {
            if (!isNull _unit && count _waypoints > 0) then {
                private _wp = _waypoints select 0;
                private _pos = [_wp select 0, _wp select 1, 0];
                private _veh = vehicle _unit;
                private _tgt = "Sign_Arrow_Red_F" createVehicle _pos;
                if (_veh != _unit) then {
                    private _g = gunner _veh;
                    if (!isNull _g) then {
                        _g doTarget _tgt;
                    } else {
                        _unit doTarget _tgt;
                    };
                } else {
                    _unit doTarget _tgt;
                };
                [_tgt] spawn { sleep 10; deleteVehicle (_this select 0); };
                _unit setVariable ["SPECTRE_currentOrder", "ADJUST FIRE", false];
                diag_log format ["SPECTRE ADJUST_FIRE [%1]: %2", _unitId, _pos];
            };
        };

        case "HOVER": {
            if (!isNull _unit) then {
                private _veh = vehicle _unit;
                if (_veh != _unit && {_veh isKindOf "Air"}) then {
                    _veh flyInHeight 50;
                    _unit setVariable ["SPECTRE_currentOrder", "HOVER", false];
                };
                diag_log format ["SPECTRE HOVER [%1]", _unitId];
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

    // Also detect newly spotted enemy vehicles
    {
        private _enemy    = _x;
        if (!isNull _enemy) then {
            private _enemyKey = str _enemy;

            if (!(_enemyKey in SPECTRE_spottedEnemies)) then {
                private _spotters = SPECTRE_blufor select { _x knowsAbout _enemy > 0.3 };
                if (count _spotters > 0) then {
                    SPECTRE_spottedEnemies pushBack _enemyKey;
                    if (count SPECTRE_spottedEnemies > 200) then {
                        SPECTRE_spottedEnemies = SPECTRE_spottedEnemies select [100, (count SPECTRE_spottedEnemies) - 100];
                    };
                    private _su        = _spotters select 0;
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
        };
    } forEach (vehicles select {
        private _e = _x;
        !(crew _e isEqualTo []) &&
        (side _e == east || side _e == independent) &&
        alive _e &&
        { _x knowsAbout _e > 0.3 } count SPECTRE_blufor > 0
    });

    // Enemy kill detection
    {
        private _enemy    = _x;
        private _enemyKey = str _enemy;
        private _wasAlive = _enemy getVariable ["SPECTRE_enemyWasAlive", false];

        if (_wasAlive && !alive _enemy) then {
            _enemy setVariable ["SPECTRE_enemyWasAlive", false, false];
            private _cs = [_enemy] call SPECTRE_fnc_vehicleType;
            _evts pushBack format [
                "{""type"":""ENEMY_KILLED"",""contact_type"":""%1"",""id"":""EK_%2_%3""}",
                _cs, _enemyKey, round time
            ];
        } else {
            _enemy setVariable ["SPECTRE_enemyWasAlive", alive _enemy, false];
        };
    } forEach (allUnits + vehicles) select {
        (side _x == east || side _x == independent) && !(_x isKindOf "Logic")
    };

    _evts
};

// ─── Full state broadcast via diag_log (one line per unit to avoid RPT truncation) ──
SPECTRE_fnc_broadcastState = {
    private _ts = round (time * 1000);

    // Send metadata (short line, won't truncate)
    private _mapName = worldName;
    private _mp = getMissionPath "";
    private _mf = "";
    private _fullPath = (_mp regexReplace ["\\\\$", ""]); // full path without trailing backslash
    if (count _fullPath > 0) then {
        private _parts = _fullPath splitString "\\";
        private _cnt = count _parts;
        if (_cnt >= 2) then {
            _mf = format ["%1\\%2", _parts select (_cnt - 2), _parts select (_cnt - 1)];
        } else { _mf = _fullPath; };
    };
    diag_log format ["SPECTRE_META:{""map"":""%1"",""mf"":""%2"",""path"":""%3"",""ts"":%4}", _mapName, _mf regexReplace ["\\", "\\\\"], _fullPath regexReplace ["\\", "\\\\"], _ts];

    // Send each unit on its own line (well under 1024 char RPT limit)
    {
        if (!isNull _x) then {
            diag_log format ["SPECTRE_UNIT:%1", [_x] call SPECTRE_fnc_serializeUnit];
        };
    } forEach SPECTRE_blufor;

    // Send contacts (one per line) — include both infantry and vehicles
    private _ci = 0;
    private _enemyInfantry = allUnits select {
        private _e = _x;
        (side _e == east || side _e == independent) &&
        alive _e &&
        { _x knowsAbout _e > 0.3 } count SPECTRE_blufor > 0
    };
    private _enemyVehicles = vehicles select {
        private _e = _x;
        !(crew _e isEqualTo []) &&
        (side _e == east || side _e == independent) &&
        alive _e &&
        { _x knowsAbout _e > 0.3 } count SPECTRE_blufor > 0
    };
    private _allEnemies = _enemyInfantry + _enemyVehicles;
    _allEnemies = _allEnemies arrayIntersect _allEnemies;
    // Rebuild the contact-ID -> object map so ATTACK/KAMIKAZE can resolve targets.
    // IDs are PERSISTENT per enemy object: an enemy keeps its HOSTILE-N id for
    // its whole life, so ids never shift when the enemy set changes — the app
    // can always resolve the exact target it shows on the map. (Previously the
    // ids were renumbered every 0.5s broadcast, so ATTACK/KAMIKAZE silently
    // missed: the target id the app sent had already moved or vanished.)
    SPECTRE_contactMap = createHashMap;
    {
        private _e = _x;
        if (!isNull _e) then {
            private _cid = _e getVariable ["SPECTRE_cid", ""];
            if (_cid == "") then {
                _cid = format ["HOSTILE-%1", _ci];
                _e setVariable ["SPECTRE_cid", _cid];
                _ci = _ci + 1;
            };
            SPECTRE_contactMap set [_cid, _e];
            private _contactJson = [_e, _cid] call SPECTRE_fnc_serializeContact;
            if (_contactJson != "") then {
                diag_log format ["SPECTRE_CONTACT:%1", _contactJson];
            };
        };
    } forEach _allEnemies;

    // Send events (usually few, one line)
    private _evts = call SPECTRE_fnc_detectEvents;
    if (count _evts > 0) then {
        diag_log format ["SPECTRE_EVENTS:[%1]", _evts joinString ","];
    };
};

// ─── Command reader ───────────────────────────────────────────────────────────
// Consume-once protocol: READ_CLEAR returns the file content AND truncates the
// file, so every command exists exactly once and is executed exactly once.
// No whole-file/banner state to desync — a command can never be silently lost
// or duplicated. The app only writes when the file is empty (write-if-empty)
// and re-sends unacked commands with fresh ids as a failsafe.
SPECTRE_fnc_readCommands = {
    private _result = "spectre_ext" callExtension ["READ_CLEAR", ["addons\spectre_cmds.sqf"]];
    // Robust: DLL may return ["content"] (array) or "content" (string)
    private _sqf = if (typeName _result == "ARRAY") then { if (count _result > 0) then { _result select 0 } else { "" } } else { _result };
    if (isNil "_sqf" || { _sqf isEqualTo "" }) exitWith {};
    private _dllErr = _sqf find "ERR_" == 0;
    if (_dllErr) then {
        diag_log format ["SPECTRE readCommands DLL error: %1", _sqf];
    };
    if (_dllErr) exitWith {};

    private _lines = _sqf splitString (toString [13, 10]);
    private _ran = 0;
    // Read diagnostics: log every non-empty read so the app-side can see
    // exactly what Arma's callExtension returned (bytes/lines/new executed).
    diag_log format ["SPECTRE read: bytes=%1 lines=%2", count _sqf, count _lines];

    {
        private _line = _x;
        private _callIdx = _line find " call SPECTRE_fnc_execCmd;";
        if (_callIdx >= 0) then {
            private _argsStr = _line select [0, _callIdx];
            // Trim leading whitespace so indented lines still parse.
            while { count _argsStr > 0 && { (_argsStr select [0, 1]) in [" ", toString [9]] } } do {
                _argsStr = _argsStr select [1];
            };
            if (count _argsStr > 0 && { _argsStr select [0, 1] == "[" }) then {
                private _args = call compile _argsStr;
                if (!isNil "_args" && { typeName _args == "ARRAY" } && { count _args > 0 }) then {
                    private _cmdId = _args select 0;
                    // Safety-net dedup: the file is consumed after each read,
                    // but the app's force-overwrite failsafe can re-write an
                    // unacked command, so skip anything already executed.
                    if !(_cmdId in SPECTRE_execCmdIds) then {
                        SPECTRE_execCmdIds pushBack _cmdId;
                        _args call SPECTRE_fnc_execCmd;
                        _ran = _ran + 1;
                        diag_log format ["SPECTRE: Executed OK: %1", _argsStr select [0, 50]];
                    };
                } else {
                    diag_log format ["SPECTRE: Bad args: %1", _argsStr];
                };
            };
        };
    } forEach _lines;

    // Keep the executed-id list bounded.
    if (count SPECTRE_execCmdIds > 400) then {
        SPECTRE_execCmdIds = SPECTRE_execCmdIds select [(count SPECTRE_execCmdIds) - 200];
    };

    if (_ran > 0) then {
        diag_log format ["SPECTRE: CMD batch ran %1 new command(s)", _ran];
    };
};

// ─── Main loop ────────────────────────────────────────────────────────────────
hint "SPECTRE C2 Bridge: ACTIVE";
diag_log "SPECTRE: Bridge running (wall-clock mode). Broadcasting every 0.5s, reading commands every 0.3s.";
SPECTRE_initialized = true;
SPECTRE_execCmdIds = [];

[] spawn {
    private _lastBroadcast = -999;
    private _lastHint      = -999;

    while { true } do {
        // diag_tickTime = real wall-clock time, NOT affected by Arma's
        // simulation throttle when backgrounded. This keeps broadcasts
        // running even when the user alt-tabs away from Arma.
        private _t = diag_tickTime;

        // Re-show the connection hint periodically so it stays visible
        // (Arma auto-dismisses hints after a few seconds).
        if (_t - _lastHint >= 20) then {
            _lastHint = _t;
            hintSilent "SPECTRE C2 Bridge: ACTIVE";
        };

        if (_t - _lastBroadcast >= SPECTRE_broadcastRate) then {
            _lastBroadcast = _t;
            // Wrap in try/catch so a single bad unit/contact can never kill
            // the whole bridge loop (which would silently disconnect the app).
            try {
                call SPECTRE_fnc_broadcastState;
            } catch {
                diag_log format ["SPECTRE broadcast error: %1", _exception];
            };
        };

        // uiSleep uses real time, NOT simulation time.
        // Regular sleep slows to a crawl when Arma is backgrounded.
        uiSleep 0.1;
    };
};

// ─── Command reader loop (independent from the broadcast loop) ────────────────
// Runs on its own schedule so a stall in either path can never starve the
// other. Every poll re-reads the whole command file and executes new ids
// (idempotent by design). A periodic heartbeat makes reader stalls visible
// in the RPT instead of failing silently.
[] spawn {
    private _lastRead  = -999;
    private _lastBeat  = -999;

    while { true } do {
        private _t = diag_tickTime;

        if (_t - _lastRead >= SPECTRE_cmdReadRate) then {
            _lastRead = _t;
            try {
                call SPECTRE_fnc_readCommands;
            } catch {
                diag_log format ["SPECTRE readCommands error: %1", _exception];
            };
        };

        // Heartbeat so a wedged reader is visible in the logs.
        if (_t - _lastBeat >= 30) then {
            _lastBeat = _t;
            diag_log format ["SPECTRE reader beat: cmdIds=%1", count SPECTRE_execCmdIds];
        };

        uiSleep 0.1;
    };
};
