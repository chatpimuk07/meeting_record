#include <Arduino.h>
#include "driver/i2s.h"

#define I2S_WS_PIN   25
#define I2S_SCK_PIN  32
#define I2S_SD_PIN   33

#define SAMPLE_RATE  16000
#define BLOCK_SIZE   512
#define BAUD_RATE    1000000

const uint8_t SYNC_HEADER[4] = {0xAA, 0x55, 0xAA, 0x55};

void setupI2S() {
    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = BLOCK_SIZE,
        .use_apll = true
    };

    i2s_pin_config_t pin_config = {
        .bck_io_num = I2S_SCK_PIN,
        .ws_io_num = I2S_WS_PIN,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = I2S_SD_PIN
    };

    i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
    i2s_set_pin(I2S_NUM_0, &pin_config);
    i2s_zero_dma_buffer(I2S_NUM_0);
}

void setup() {
    Serial.begin(BAUD_RATE);
    setupI2S();
}

void loop() {
    int32_t raw_samples[BLOCK_SIZE];
    int16_t pcm_samples[BLOCK_SIZE];
    size_t bytes_read = 0;

    i2s_read(I2S_NUM_0, (void*)raw_samples, sizeof(raw_samples), &bytes_read, portMAX_DELAY);
    int samples_read = bytes_read / sizeof(int32_t);

    if (samples_read > 0) {
        for (int i = 0; i < samples_read; i++) {
            // เลื่อนบิต >> 14 เพื่อให้ได้ความดังของเสียงพูดที่เหมาะสม และจำกัดค่าป้องกันสัญญาณล้น (Clipping)
            int32_t val = raw_samples[i] >> 14;
            if (val > 32767) val = 32767;
            else if (val < -32768) val = -32768;
            pcm_samples[i] = (int16_t)val;
        }

        // ส่ง Sync Header 4 ไบต์ ตามด้วยข้อมูลเสียง PCM 16-bit เพื่อป้องกันไบต์เลื่อน (MSB/LSB Swap)
        Serial.write(SYNC_HEADER, sizeof(SYNC_HEADER));
        Serial.write((uint8_t*)pcm_samples, samples_read * sizeof(int16_t));
    }
}
