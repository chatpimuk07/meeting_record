# FPGA Audio DSP Bridge (UART Mode - MAX 10 `10M50DAF484C7G`)

โปรเจกต์ Quartus Prime Lite (VHDL) สำหรับนำบอร์ด **Terasic DE10-Lite (`10M50DAF484C7G`)** มาคั่นกลางระหว่างไมโครโฟนดิจิทัล **INMP441 (I2S)** กับบอร์ด **ESP32** โดยส่งข้อมูลเสียงที่ผ่านการประมวลผล DSP แล้วออกทาง **UART ความเร็ว 1,000,000 Baud (ใช้สายสัญญาณเพียง 1 เส้น)**

---

## 1. โฟลเดอร์และไฟล์ VHDL ที่ใช้งาน (เหลือเฉพาะ 4 ไฟล์หลักสำหรับ UART)

- **โปรเจกต์ Quartus Prime (`quartus/`):**
  - `fpga_mic_bridge.qpf` — ไฟล์โปรเจกต์หลัก
  - `fpga_mic_bridge.qsf` — ตั้งค่าชิป `10M50DAF484C7G` และ Pin Assignment
  - `fpga_mic_bridge.sdc` — ไฟล์ Timing Constraints (Clock 50 MHz)
- **โค้ด VHDL (`rtl/`):**
  1. `i2s_master_transceiver.vhd` — สร้างสัญญาณนาฬิกา I2S Master $16.000\text{ kHz}$ เพื่ออ่านค่าเสียง 24-bit จากไมโครโฟน INMP441
  2. `audio_dsp_processor.vhd` — วงจร DSP บนฮาร์ดแวร์: ตัดไฟตรง DC Offset + ปรับ Gain (`SW[2:1]`) + กันเสียงแตก (Saturation) + ไฟ VAD/VU Meter (`LEDR[9:0]`)
  3. `uart_frame_tx.vhd` — แพ็กเฟรม `[0xAA, 0x55, 0xAA, 0x55] + 512 samples (1024 bytes)` ส่งออกทาง `FPGA_UART_TX` ที่ `1,000,000` Baud
  4. `fpga_mic_bridge_top.vhd` — Top-Level Entity เชื่อมทั้ง 3 โมดูลเข้าด้วยกัน
- **โค้ด ESP32 (`esp32_firmware/`):**
  - `esp32_uart_from_fpga/esp32_uart_from_fpga.ino` — รับข้อมูล UART จาก FPGA ทางขา `GPIO 16 (RX2)` แล้วส่งต่อขึ้น USB-Serial เข้าโปรแกรม `main.py`

---

## 2. การต่อสาย (Pin Mapping)

### ส่วนที่ 1: ไมโครโฟน INMP441 $\rightarrow$ บอร์ด FPGA (ช่อง Arduino Header)
| ขาไมโครโฟน INMP441 | ช่อง DE10-Lite Arduino Header | เลขพิน FPGA (`10M50DAF484C7G`) | ชื่อพอร์ตใน VHDL |
| :--- | :--- | :--- | :--- |
| **WS** | **ARDUINO_IO[0]** | `PIN_AB5` | `MIC_I2S_WS` |
| **SCK** | **ARDUINO_IO[1]** | `PIN_AB6` | `MIC_I2S_SCK` |
| **SD** | **ARDUINO_IO[2]** | `PIN_AB7` | `MIC_I2S_SD` |
| **L/R** | **GND** | Board GND | ต่อลงกราวด์ (Left Channel) |
| **VDD / GND** | **3.3V / GND** | Board 3.3V / GND | ไฟเลี้ยง 3.3V และกราวด์ |

### ส่วนที่ 2: บอร์ด FPGA $\rightarrow$ บอร์ด ESP32 (UART 1 Mbps)
| ช่อง DE10-Lite Arduino Header | เลขพิน FPGA (`10M50DAF484C7G`) | ชื่อพอร์ตใน VHDL | ขา ESP32 |
| :--- | :--- | :--- | :--- |
| **ARDUINO_IO[7]** | `PIN_AA12` | `FPGA_UART_TX` | **GPIO 16 (RX2)** |
| **GND** | Board GND | - | **GND** *(กราวด์ร่วม)* |

---

## 3. สวิตช์ควบคุมและไฟ LED บนบอร์ด FPGA

| อุปกรณ์บนบอร์ด | เลขพิน FPGA | หน้าที่การทำงาน |
| :--- | :--- | :--- |
| **KEY[0]** | `PIN_B8` | ปุ่ม Reset วงจร (Active Low) |
| **SW[0]** | `PIN_C10` | `0` = รับเสียงจากไมค์ INMP441, `1` = ส่งคลื่นไซน์ทดสอบ **1.000 kHz** |
| **SW[2:1]** | `PIN_D12, PIN_C11` | ปรับระดับการขยายเสียง (Digital Gain): `00`=1x, `01`=2x, **`10`=4x (แนะนำ)**, `11`=8x |
| **SW[3]** | `PIN_C12` | `1` = เปิดระบบตัดเสียงรบกวนเบาๆ (Soft Noise Gate), `0` = ปิด |
| **LEDR[0]** | `PIN_A8` | สว่างเมื่อตรวจพบเสียงพูด (Hardware VAD Active) |
| **LEDR[1]** | `PIN_A9` | สว่างเมื่อสัญญาณเสียงดังแตะเพดาน (Clipping Indicator) |
| **LEDR[9:2]** | `PIN_B11..A10` | ไฟวิ่งแสดงระดับความดังเสียง 8 ระดับ (Real-Time VU Meter) |
| **ARDUINO_IO[8]** | `PIN_AB17` | สัญญาณคลื่นสี่เหลี่ยม **8.000 kHz** ($F_s / 2$) สำหรับวัดด้วย Oscilloscope |
