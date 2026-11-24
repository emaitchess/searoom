#ifndef SEAROOM_SENSORS_H
#define SEAROOM_SENSORS_H

#include <stdbool.h>

/// One fan as AppleSMC reports it. `index` is the SMC fan number, so a fan that
/// cannot be read never shifts another fan's limits onto it.
typedef struct {
    int index;
    double speed_rpm;
    bool has_limits;
    double minimum_rpm;
    double maximum_rpm;
} SRFanReading;

/// Reads a representative CPU/package temperature from AppleSMC.
/// Returns false when no supported sensor can be read.
bool SRReadTemperature(double *temperature_celsius);

/// Averages the GPU sensors that read plausibly. Returns false when the Mac
/// publishes none, or when none reads plausibly, as when the GPU is powered down.
bool SRReadGPUTemperature(double *average_celsius);

/// Folds raw readings the way SRReadGPUTemperature does, for fixtures.
bool SRAverageTemperatures(const double *readings, int count, double *average_celsius);

/// Reads the whole-Mac power draw in watts.
/// Returns false when the key is absent or its value is implausible.
bool SRReadSystemPower(double *watts);

/// Writes currently reported fans and returns the number written.
int SRReadFans(SRFanReading *fans, int capacity);

/// Runs framework-independent fixtures for supported SMC sensor encodings.
bool SRRunSensorDecoderSelfTest(void);

#endif
