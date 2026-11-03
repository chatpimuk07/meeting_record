// =========================================================================
// File        : esp32_uart_from_fpga.ino
// Description : โค้ด ESP32 สำหรับรับเฟรมเสียงจาก FPGA ผ่านสาย UART เพียงเส้นเดียว!
//               (FPGA แพ็ก [0xAA, 0x55, 0xAA, 0x55] + 512 samples ที่ 1 Mbps มาให้เสร็จสรรพ)
//
// การต่อสาย (FPGA Arduino Header -> ESP32):
//   - ARDUINO_IO[7] (PIN_AA12 : FPGA_UART_TX) ---> ESP32 GPIO 16 (RX2)
//   - GND ของ FPGA                            ---> ESP32 GND
// =========================================================================
#include <Arduino.h>

#define FPGA_UART_RX_PIN  16    // ต่อกับขา ARDUINO_IO[7] (PIN_AA12) ของบอร์ด FPGA DE10-Lite
#define FPGA_UART_TX_PIN  17    // ไม่ได้ใช้งาน (รับข้อมูลทางเดียวจาก FPGA)
#define LED_PIN           2     // ไฟ LED บนบอร์ด ESP32 (กะพริบเมื่อได้รับข้อมูลจาก FPGA)
#define BAUD_RATE         1000000

uint8_t buf[2048];
uint32_t bytes_counter = 0;

void setup() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, LOW);

    // ตั้งขนาด Buffer ให้ใหญ่พอสำหรับรับ-ส่งข้อมูลความเร็วสูง 1 Mbps แบบไม่สะดุด
    Serial.setTxBufferSize(8192);
    Serial.begin(BAUD_RATE);

    Serial2.setRxBufferSize(8192);
    Serial2.begin(BAUD_RATE, SERIAL_8N1, FPGA_UART_RX_PIN, FPGA_UART_TX_PIN);
}

void loop() {
    int avail = Serial2.available();
    if (avail > 0) {
        int to_read = min(avail, (int)sizeof(buf));
        int n = Serial2.readBytes(buf, to_read);
        if (n > 0) {
            Serial.write(buf, n);
            bytes_counter += n;
            // กะพริบไฟ LED บนบอร์ด ESP32 ทุกๆ ~16 KB (ประมาณทุก 0.5 วินาที) เพื่อบอกว่ามีข้อมูลเข้า
            digitalWrite(LED_PIN, (bytes_counter >> 14) & 1);
        }
    }
}
