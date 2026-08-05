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

    return fabs(decode_value(&m5_fan) - 4957.0) < 0.001
        && fabs(decode_value(&fixed_fan) - 6000.0) < 0.001
        && decode_value(&fan_count) == 2.0
        && isnan(decode_value(&invalid));
}

bool SRReadTemperature(double *temperature_celsius) {
    if (temperature_celsius == NULL) return false;

    // Intel package/proximity keys followed by Apple Silicon performance-core keys.
    static const char *keys[] = {
        "TC0P", "TC0E", "TC0F", "TC0D", "TC0H", "TC0C",
        "Tp01", "Tp05", "Tp09", "Tp0P", "Te05", "Te0P"
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

int SRReadFanSpeeds(double *speeds_rpm, int capacity) {
    if (speeds_rpm == NULL || capacity <= 0) return 0;
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
            speeds_rpm[count++] = speed;
        }
    }
    fan_search_complete = true;
    return count;
}
