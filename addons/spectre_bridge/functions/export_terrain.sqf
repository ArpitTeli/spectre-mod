// SPECTRE — terrain heightmap exporter
// Run this in Arma 3 Eden Editor or during a mission to export terrain heights
// The output goes to the RPT log, then we extract it to build a real heightmap

#define MAP_SIZE 8192
#define STEP 8  // sample every 8 meters (1024x1024 grid)

diag_log "SPECTRE_TERRAIN:START";
for "_y" from 0 to (MAP_SIZE - STEP) step STEP do {
    private _line = "";
    for "_x" from 0 to (MAP_SIZE - STEP) step STEP do {
        private _h = getTerrainHeight [_x, _y];
        _line = _line + str round (_h * 10) + ",";
    };
    diag_log format ["SPECTRE_TERRAIN:%1", _line];
    uiSleep 0.01;
};
diag_log "SPECTRE_TERRAIN:END";
hint "Terrain export complete";
