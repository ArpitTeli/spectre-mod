// SPECTRE — terrain cost grid exporter (v8)
// Three-pass export to avoid RPT line truncation:
//   Pass 1: SPECTRE_SURFGRID — surface codes only
//   Pass 2: SPECTRE_OBJGRID — vegetation + building counts
//   Pass 3: SPECTRE_ROADGRID — road presence (0 or 1 per cell)
// All use 64m step = 128x128 grid
//
// Run in Eden Editor: execVM "x\SPECTRE\addons\functions\export_cost_grid.sqf"

private _mapSize = 8192;
private _step = 64;
private _scanRadius = 32;

hint "SPECTRE grid export (pass 1: surfaces)...";

// PASS 1: Surface codes
diag_log "SPECTRE_SURFGRID:START";
private _y = 0;
while {_y < _mapSize} do {
    private _row = "";
    private _x = 0;
    while {_x < _mapSize} do {
        private _s = surfaceType [_x, _y];
        private _c = 0;
        if (_s find "Water" >= 0 || _s find "Seabed" >= 0 || _s find "Marsh" >= 0 || _s find "Dead" >= 0) then { _c = 4; }
        else { if (_s find "ForestPine" >= 0 || _s find "Forest" >= 0 || _s find "Trees" >= 0 || _s find "Pine" >= 0) then { _c = 2; }
        else { if (_s find "Concrete" >= 0 || _s find "Tarmac" >= 0 || _s find "Asphalt" >= 0 || _s find "VRsurface" >= 0) then { _c = 3; }
        else { if (_s find "Sand" >= 0 || _s find "Dirt" >= 0 || _s find "Mud" >= 0 || _s find "Beach" >= 0 || _s find "Soil" >= 0 || _s find "Stubble" >= 0 || _s find "Field" >= 0 || _s find "WildField" >= 0 || _s find "Desert" >= 0 || _s find "RedDirt" >= 0) then { _c = 5; }
        else { if (_s find "Rock" >= 0 || _s find "Stones" >= 0 || _s find "Cliff" >= 0 || _s find "Rubble" >= 0 || _s find "Stony" >= 0 || _s find "Volcano" >= 0) then { _c = 6; }
        else { if (_s find "Grass" >= 0 || _s find "Thorn" >= 0 || _s find "Thistle" >= 0 || _s find "Weed" >= 0 || _s find "Shrub" >= 0) then { _c = 1; }; }; }; }; }; };
        _row = _row + str _c + ";";
        _x = _x + _step;
    };
    diag_log format ["SPECTRE_SURFGRID:%1", _row];
    _y = _y + _step;
    hint format ["Pass 1/3: %1/%2", round(_y / _step), round(_mapSize / _step)];
};
diag_log "SPECTRE_SURFGRID:END";

hint "SPECTRE grid export (pass 2: objects)...";

// PASS 2: Vegetation + buildings
diag_log "SPECTRE_OBJGRID:START";
_y = 0;
while {_y < _mapSize} do {
    private _row = "";
    private _x = 0;
    while {_x < _mapSize} do {
        private _veg = (count nearestTerrainObjects [[_x, _y], ["TREE","SMALL TREE","FOREST BORDER","FOREST SQUARE","FOREST TRIANGLE"], _scanRadius, false]) + (count nearestTerrainObjects [[_x, _y], ["BUSH","SMALL BUSH"], _scanRadius, false]);
        private _bldg = count nearestTerrainObjects [[_x, _y], ["BUILDING","HOUSE","WALL","FORTRESS","BUNKER","ROCK","RUINS"], _scanRadius, false];
        _row = _row + str _veg + "," + str _bldg + ";";
        _x = _x + _step;
    };
    diag_log format ["SPECTRE_OBJGRID:%1", _row];
    _y = _y + _step;
    hint format ["Pass 2/3: %1/%2", round(_y / _step), round(_mapSize / _step)];
};
diag_log "SPECTRE_OBJGRID:END";

hint "SPECTRE grid export (pass 3: roads)...";

// PASS 3: Road presence
diag_log "SPECTRE_ROADGRID:START";
_y = 0;
while {_y < _mapSize} do {
    private _row = "";
    private _x = 0;
    while {_x < _mapSize} do {
        private _roads = [_x, _y, 0] nearRoads (_step * 0.75);
        private _hasRoad = 0;
        if (count _roads > 0) then { _hasRoad = 1; };
        _row = _row + str _hasRoad + ";";
        _x = _x + _step;
    };
    diag_log format ["SPECTRE_ROADGRID:%1", _row];
    _y = _y + _step;
    hint format ["Pass 3/3: %1/%2", round(_y / _step), round(_mapSize / _step)];
};
diag_log "SPECTRE_ROADGRID:END";
hint "SPECTRE grid export complete";
