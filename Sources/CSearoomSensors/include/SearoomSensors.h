#ifndef SEAROOM_SENSORS_H
#define SEAROOM_SENSORS_H

#include <stdbool.h>

/// Reads a representative CPU/package temperature from AppleSMC.
/// Returns false when no supported sensor can be read.
bool SRReadTemperature(double *temperature_celsius);

/// Writes currently reported fan speeds and returns the number written.
int SRReadFanSpeeds(double *speeds_rpm, int capacity);

/// Runs framework-independent fixtures for supported SMC sensor encodings.
bool SRRunSensorDecoderSelfTest(void);

#endif
