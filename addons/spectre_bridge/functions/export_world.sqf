// SPECTRE — World export for 3D viewer
// Run in Eden Editor (Stratis), debug console:
//   execVM "x\SPECTRE\addons\functions\export_world.sqf"
// or paste into Execute field, click Local Exec

hint "SPECTRE export starting...";

private _list = nearestTerrainObjects [[4096,4096], ["BUILDING","HOUSE","CHURCH","CHAPEL","FUELSTATION","HANGAR","BUNKER","TOWER","FORTRESS","WALL","FENCE","ROCK"], 20000];

diag_log "SPECTRE_WORLD:START";
diag_log format ["SPECTRE_WORLD:COUNT:%1", count _list];

{
    if (!(_x isKindOf "Building" || _x isKindOf "House" || _x isKindOf "Static")) exitWith {};
    private _p = getPosATL _x;
    private _b = boundingBoxReal _x;
    private _w = abs ((_b select 1 select 0) - (_b select 0 select 0));
    private _h = abs ((_b select 1 select 1) - (_b select 0 select 1));
    private _d = abs ((_b select 1 select 2) - (_b select 0 select 2));
    diag_log format ["SPECTRE_WORLD:B,%1,%2,%3,%4,%5,%6,%7,%8",
        _p select 0, _p select 1, _p select 2, getDir _x,
        _w, _h, _d, typeOf _x, surfaceType _x];
} forEach _list;

diag_log "SPECTRE_WORLD:END";
hint "SPECTRE export done - check RPT";
