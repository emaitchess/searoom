#include "SearoomSensors.h"

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

enum {
    kSMCUserClientOpen = 0,
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent = 2,
    kSMCCmdReadBytes = 5,
    kSMCCmdReadKeyFromIndex = 8,
    kSMCCmdReadKeyInfo = 9
};

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t bytes[32];
} SMCValue;

static uint32_t four_char_code(const char key[5]) {
    return ((uint32_t)(uint8_t)key[0] << 24)
        | ((uint32_t)(uint8_t)key[1] << 16)
        | ((uint32_t)(uint8_t)key[2] << 8)
        | (uint32_t)(uint8_t)key[3];
}

static void key_name(uint32_t key, char name[5]) {
    name[0] = (char)(key >> 24);
    name[1] = (char)(key >> 16);
    name[2] = (char)(key >> 8);
    name[3] = (char)key;
    name[4] = '\0';
}

static io_connect_t smc_connection(void) {
    static io_connect_t connection = IO_OBJECT_NULL;
    static bool attempted = false;
    if (attempted) return connection;
    attempted = true;

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) return IO_OBJECT_NULL;

    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) connection = IO_OBJECT_NULL;
    return connection;
}

static bool read_key(const char key[5], SMCValue *value) {
    io_connect_t connection = smc_connection();
    if (connection == IO_OBJECT_NULL || value == NULL) return false;

    SMCKeyData input = {0};
    SMCKeyData output = {0};
    size_t output_size = sizeof(output);
    input.key = four_char_code(key);
    input.data8 = kSMCCmdReadKeyInfo;

    kern_return_t result = IOConnectCallStructMethod(
        connection,
        kSMCHandleYPCEvent,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0 || output.keyInfo.dataSize == 0) {
        return false;
    }

    const SMCKeyInfoData key_info = output.keyInfo;
    if (key_info.dataSize > sizeof(value->bytes)) return false;

    input.keyInfo.dataSize = key_info.dataSize;
    input.data8 = kSMCCmdReadBytes;
    memset(&output, 0, sizeof(output));
    output_size = sizeof(output);
    result = IOConnectCallStructMethod(
        connection,
        kSMCHandleYPCEvent,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0) return false;

    value->dataSize = key_info.dataSize;
    value->dataType = key_info.dataType;
    memcpy(value->bytes, output.bytes, key_info.dataSize);
    return true;
}

static double decode_value(const SMCValue *value) {
    if (value == NULL || value->dataSize == 0) return NAN;
    uint32_t type = value->dataType;

    if (type == four_char_code("sp78") && value->dataSize >= 2) {
        int16_t raw = (int16_t)(((uint16_t)value->bytes[0] << 8) | value->bytes[1]);
        return (double)raw / 256.0;
    }
    if (type == four_char_code("fpe2") && value->dataSize >= 2) {
        uint16_t raw = ((uint16_t)value->bytes[0] << 8) | value->bytes[1];
        return (double)raw / 4.0;
    }
    if (type == four_char_code("flt ") && value->dataSize >= 4) {
        float decoded;
        // AppleSMC's `flt ` payload is the processor's native IEEE 754 float.
        // memcpy avoids alignment and strict-aliasing problems on the byte buffer.
        memcpy(&decoded, value->bytes, sizeof(decoded));
        return decoded;
    }
    if (type == four_char_code("ui16") && value->dataSize >= 2) {
        return (double)(((uint16_t)value->bytes[0] << 8) | value->bytes[1]);
    }
    if (type == four_char_code("ui8 ") && value->dataSize >= 1) {
        return value->bytes[0];
    }
    return NAN;
}

bool SRReadTemperature(double *temperature_celsius) {
    if (temperature_celsius == NULL) return false;

    // Intel package/proximity keys followed by Apple Silicon performance-core keys.
    // The Tp indices differ across M-series generations; M5 Pro (macOS 27)
    // exposes its package sensors at Tp04, Tp08 and Tp0C, all `flt ` payloads
    // that track load between 52 and 72 Celsius on identified hardware. They
    // join the earlier M-series keys so each generation finds its own first.
    static const char *keys[] = {
        "TC0P", "TC0E", "TC0F", "TC0D", "TC0H", "TC0C",
        "Tp01", "Tp05", "Tp09", "Tp0P", "Tp04", "Tp08", "Tp0C", "Te05", "Te0P"
    };
    static int selected_key = -1;
    static bool sensor_search_complete = false;

    if (selected_key >= 0) {
        SMCValue value = {0};
        if (!read_key(keys[selected_key], &value)) return false;
        double temperature = decode_value(&value);
        if (isfinite(temperature) && temperature >= 10 && temperature <= 125) {
            *temperature_celsius = temperature;
            return true;
        }
        return false;
    }
    if (sensor_search_complete) return false;

    sensor_search_complete = true;
    for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
        SMCValue value = {0};
        if (!read_key(keys[index], &value)) continue;
        double temperature = decode_value(&value);
        if (isfinite(temperature) && temperature >= 10 && temperature <= 125) {
            selected_key = (int)index;
            *temperature_celsius = temperature;
            return true;
        }
    }
    return false;
}

// GPU sensors are the `flt ` keys named Tg??, whose suffixes differ on every
// chip, so they are discovered by prefix rather than listed. Apple documents
// none of them: that `Tg` is the GPU is community knowledge, checked here by
// watching the sensors follow GPU load. On Mac17,9 (M5 Pro, macOS 27.3) all 42
// rose 18 to 28 degrees under a Metal compute loop. On Mac16,10 (M4, macOS
// 27.2.1) all 18 read -4.5 or 0.8 while the GPU was off and 46 to 62 under the
// same loop. On the M4 each sensor is published twice, 5.3 degrees apart, and
// nothing says which is right, so the mean sits between the two.
enum { kMaximumGPUSensors = 128 };

static uint32_t gpu_sensor_keys[kMaximumGPUSensors];
static int gpu_sensor_count = 0;
static bool gpu_sensor_search_complete = false;

static bool is_plausible_temperature(double celsius) {
    // A powered-down GPU reports zero or below, which is not a temperature.
    return isfinite(celsius) && celsius >= 10 && celsius <= 125;
}

static bool is_gpu_sensor_key(uint32_t key) {
    return (key >> 16) == (((uint32_t)'T' << 8) | 'g');
}

// Walks the key table once per process. On an M5 Pro with 3,613 keys the first
// read took about 25 to 35 ms with the walk, and later ones about 8 ms: each
// sensor is a real SMC round trip of about 0.2 ms.
static void discover_gpu_sensors(void) {
    if (gpu_sensor_search_complete) return;
    gpu_sensor_search_complete = true;

    io_connect_t connection = smc_connection();
    SMCValue count_value = {0};
    if (connection == IO_OBJECT_NULL || !read_key("#KEY", &count_value)) return;
    if (count_value.dataSize < 4) return;
    const uint32_t key_count = ((uint32_t)count_value.bytes[0] << 24)
        | ((uint32_t)count_value.bytes[1] << 16)
        | ((uint32_t)count_value.bytes[2] << 8)
        | (uint32_t)count_value.bytes[3];
    if (key_count > 65536) return;

    for (uint32_t index = 0; index < key_count && gpu_sensor_count < kMaximumGPUSensors; index++) {
        SMCKeyData input = {0};
        SMCKeyData output = {0};
        input.data8 = kSMCCmdReadKeyFromIndex;
        input.data32 = index;
        size_t output_size = sizeof(output);
        if (IOConnectCallStructMethod(
                connection, kSMCHandleYPCEvent,
                &input, sizeof(input), &output, &output_size
            ) != KERN_SUCCESS || output.result != 0) {
            continue;
        }
        if (!is_gpu_sensor_key(output.key)) continue;

        SMCValue value = {0};
        char name[5];
        key_name(output.key, name);
        if (!read_key(name, &value)) continue;
        if (value.dataType != four_char_code("flt ") || value.dataSize != 4) continue;
        gpu_sensor_keys[gpu_sensor_count++] = output.key;
    }
}

// Kept apart from the SMC read so fixtures can pin how gated sensors and an
// all-gated GPU behave.
bool SRAverageTemperatures(const double *readings, int count, double *average_celsius) {
    if (average_celsius == NULL) return false;
    if (readings == NULL && count > 0) return false;
    double sum = 0;
    int plausible = 0;
    for (int index = 0; index < count; index++) {
        if (!is_plausible_temperature(readings[index])) continue;
        sum += readings[index];
        plausible++;
    }
    if (plausible == 0) return false;
    *average_celsius = sum / plausible;
    return true;
}

bool SRReadGPUTemperature(double *average_celsius) {
    if (average_celsius == NULL) return false;
    discover_gpu_sensors();
    double readings[kMaximumGPUSensors];
    int count = 0;
    for (int index = 0; index < gpu_sensor_count; index++) {
        char name[5];
        key_name(gpu_sensor_keys[index], name);
        SMCValue value = {0};
        if (!read_key(name, &value)) continue;
        readings[count++] = decode_value(&value);
    }
    return SRAverageTemperatures(readings, count, average_celsius);
}

static bool is_plausible_power(double watts) {
    // A running Mac never draws nothing, and no Mac's supply exceeds this.
    return isfinite(watts) && watts > 0 && watts <= 2000;
}

// PSTR is the SMC's whole-system power rail, a `flt ` in watts. Apple does not
// document it. Verified on Mac17,9 (M5 Pro, macOS 27.3), 5 to 11 W idle and 42
// to 47 W with every core busy; and on Mac16,10 (M4, macOS 27.2.1), 1.3 W idle
// and 13.8 W with ten busy cores, where it matched macmon's sys_power.
bool SRReadSystemPower(double *watts) {
    if (watts == NULL) return false;
    SMCValue value = {0};
    if (!read_key("PSTR", &value)) return false;
    const double reading = decode_value(&value);
    if (!is_plausible_power(reading)) return false;
    *watts = reading;
    return true;
}

static bool is_plausible_fan_limit(double minimum, double maximum) {
    return isfinite(minimum) && isfinite(maximum)
        && minimum >= 0 && maximum > minimum && maximum < 20000;
}

// F<n>Mn and F<n>Mx are constant per fan, so they are kept once read. A failed
// read is retried rather than remembered: it costs microseconds, on the same
// six-second cadence as the speeds.
static void read_fan_limits(int fan, SRFanReading *reading) {
    static double minimums[10];
    static double maximums[10];
    static int known_limits = 0;

    if ((known_limits & (1 << fan)) == 0) {
        char minimum_key[5] = {'F', (char)('0' + fan), 'M', 'n', '\0'};
        char maximum_key[5] = {'F', (char)('0' + fan), 'M', 'x', '\0'};
        SMCValue minimum_value = {0};
        SMCValue maximum_value = {0};
        if (!read_key(minimum_key, &minimum_value) || !read_key(maximum_key, &maximum_value)) return;
        const double minimum = decode_value(&minimum_value);
        const double maximum = decode_value(&maximum_value);
        if (!is_plausible_fan_limit(minimum, maximum)) return;
        minimums[fan] = minimum;
        maximums[fan] = maximum;
        known_limits |= 1 << fan;
    }
    reading->has_limits = true;
    reading->minimum_rpm = minimums[fan];
    reading->maximum_rpm = maximums[fan];
}

int SRReadFans(SRFanReading *fans, int capacity) {
    if (fans == NULL || capacity <= 0) return 0;
    static int discovered_fans = 0;
    static bool fan_search_complete = false;
    int count = 0;
    for (int fan = 0; fan < 10 && count < capacity; fan++) {
        if (fan_search_complete && (discovered_fans & (1 << fan)) == 0) continue;
        char key[5] = {'F', (char)('0' + fan), 'A', 'c', '\0'};
        SMCValue value = {0};
        if (!read_key(key, &value)) continue;
        double speed = decode_value(&value);
        if (isfinite(speed) && speed >= 0 && speed < 20000) {
            discovered_fans |= 1 << fan;
            SRFanReading reading = {.index = fan, .speed_rpm = speed};
            read_fan_limits(fan, &reading);
            fans[count++] = reading;
        }
    }
    fan_search_complete = true;
    return count;
}

bool SRRunSensorDecoderSelfTest(void) {
    const SMCValue m5_fan = {
        .dataSize = 4,
        .dataType = four_char_code("flt "),
        .bytes = {0x00, 0xe8, 0x9a, 0x45}
    };
    const SMCValue fixed_fan = {
        .dataSize = 2,
        .dataType = four_char_code("fpe2"),
        .bytes = {0x5d, 0xc0}
    };
    const SMCValue fan_count = {
        .dataSize = 1,
        .dataType = four_char_code("ui8 "),
        .bytes = {0x02}
    };
    const SMCValue invalid = {
        .dataSize = 0,
        .dataType = four_char_code("flt ")
    };
    const bool decodes = fabs(decode_value(&m5_fan) - 4957.0) < 0.001
        && fabs(decode_value(&fixed_fan) - 6000.0) < 0.001
        && decode_value(&fan_count) == 2.0
        && isnan(decode_value(&invalid));

    // A gated sensor must leave the mean alone, and a GPU with nothing plausible
    // has no reading at all. The figures are what an M4 published while its GPU
    // was off and while a Metal loop ran.
    double average = 0;
    const double mixed[] = {-4.5, 40.0, 0.8, 50.0, 300.0, NAN};
    const double gated[] = {-4.5, 0.8, 0.0};
    const bool averages = SRAverageTemperatures(mixed, 6, &average)
        && fabs(average - 45.0) < 0.001
        && !SRAverageTemperatures(gated, 3, &average)
        && !SRAverageTemperatures(gated, 0, &average);

    const bool classifies = is_gpu_sensor_key(four_char_code("Tg0C"))
        && !is_gpu_sensor_key(four_char_code("Tp04"))
        && !is_gpu_sensor_key(four_char_code("PSTR"));

    const bool bounds = is_plausible_power(7.5)
        && !is_plausible_power(0)
        && !is_plausible_power(NAN)
        && !is_plausible_power(5000)
        && is_plausible_fan_limit(2317, 7826)
        && !is_plausible_fan_limit(4900, 1000)
        && !is_plausible_fan_limit(0, 0);

    return decodes && averages && classifies && bounds;
}
