// SPECTRE C2 - CBA Macros
// Standard CBA component macros for the SPECTRE bridge addon

// Component macros
#define QUOTE(var) #var
#define GVAR(var) PREFIX##_COMPONENT##_##var
#define FUNC(var) GVAR(var)

// String macros
#define STR(var) QUOTE(var)
