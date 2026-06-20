#ifndef ZigBridge_h
#define ZigBridge_h

/*
 * Bridging header for the SwiftUI app. The app uses the Zig transliteration
 * engine (via ZigTransliterator.swift) but does NOT link riti, so it imports
 * only byakaron.h — unlike the IME's BridgeHeader.h which pulls in both.
 */
#include "byakaron.h"

#endif /* ZigBridge_h */
