# Smart Meeting Recorder (FPGA MAX10 + ESP32 + Python DSP/VAD)

ระบบบันทึกและวิเคราะห์เสียงการประชุมอัจฉริยะแบบ Real-Time ที่ผสานการทำงานร่วมกันระหว่างฮาร์ดแวร์ **FPGA (Intel MAX 10 DE10-Lite)**, ไมโครคอนโทรลเลอร์ **ESP32**, และแอปพลิเคชันเดสก์ท็อป **Python (PyQt5 + PyQtGraph)** สำหรับตรวจจับเสียงพูด (Voice Activity Detection - VAD), กรองสัญญาณรบกวน (DSP), แสดงกราฟคลื่นเสียง/สเปกโตรแกรมแบบสด และสรุปสถิติเวลาพูดพร้อมส่งออกไฟล์ `.wav` และ `.csv`

---

## สถาปัตยกรรมระบบ (System Architecture)

```text
[ ไมโครโฟน INMP441 ]
        │  (I2S: 16 kHz, 24-bit)
        ▼
[ บอร์ด FPGA DE10-Lite (MAX 10: 10M50DAF484C7G) ]
  ├─ I2S Master Transceiver (สร้าง Clock แม่นยำ 16.000 kHz)
  ├─ Hardware Audio DSP (DC Blocker, Digital Gain, Soft Noise Gate, Saturation, VU Meter)
  └─ UART Frame Transmitter (แพ็ก Sync Header 0xAA 0x55 0xAA 0x55 + 512 samples)
        │  (UART TX: 1,000,000 Baud)
        ▼
[ บอร์ด ESP32 (UART-to-USB Bridge) ]
        │  (USB Serial: 1,000,000 Baud)
        ▼
[ โปรแกรม Python (main.py) บนคอมพิวเตอร์ ]
  ├─ Software DSP (3-Tap Median Despiker, 3.5 kHz Low-Pass Filter, Continuous DC Removal)
  ├─ Adaptive VAD (Short-Time Energy + Zero-Crossing Rate + Pre-Buffer 500 ms + Hangover 1 s)
  └─ Real-Time GUI (Live Waveform, 0–8 kHz Spectrogram, Speaking Metrics, WAV & CSV Export)
```

---

## โครงสร้างโปรเจกต์ (Project Structure)

```text
meeting_record/
├── main.py                                 # โปรแกรมหลัก Python GUI + DSP + Adaptive VAD
├── fpga_max10_bridge/                      # โปรเจกต์ FPGA (VHDL) และเฟิร์มแวร์ ESP32
│   ├── README.md                           # รายละเอียดเชิงลึกของฝั่ง FPGA และการตั้งค่าพิน
│   ├── rtl/                                # โค้ด VHDL สังเคราะห์วงจร (Synthesizable RTL)
│   │   ├── fpga_mic_bridge_top.vhd         # Top-Level Entity
│   │   ├── i2s_master_transceiver.vhd      # โมดูลรับสัญญาณเสียง I2S Master (16 kHz)
│   │   ├── audio_dsp_processor.vhd         # โมดูลประมวลผลสัญญาณเสียงบน FPGA
│   │   └── uart_frame_tx.vhd               # โมดูลจัดเฟรมข้อมูลและส่งออกทาง UART 1 Mbps
│   ├── quartus/                            # ไฟล์โปรเจกต์สำหรับ Intel Quartus Prime Lite
│   │   ├── fpga_mic_bridge.qpf
│   │   ├── fpga_mic_bridge.qsf             # Pin Assignment สำหรับบอร์ด DE10-Lite
│   │   └── fpga_mic_bridge.sdc             # Timing Constraints (50 MHz Clock)
│   ├── sim/                                # ไฟล์จำลองการทำงาน (Testbench)
│   │   ├── tb_fpga_mic_bridge.vhd
│   │   └── run_sim.sh                      # สคริปต์รันจำลองด้วย NVC Simulator
│   └── esp32_firmware/                     # โค้ด Arduino IDE สำหรับ ESP32
│       └── esp32_uart_from_fpga/
│           └── esp32_uart_from_fpga.ino    # รับเฟรม UART จาก FPGA ส่งต่อเข้าคอมพิวเตอร์
└── .gitignore
```

---

## การต่อวงจรฮาร์ดแวร์ (Hardware Pin Mapping)

### 1. ไมโครโฟนดิจิทัล INMP441 $\rightarrow$ บอร์ด FPGA DE10-Lite
| ขาไมโครโฟน INMP441 | ช่อง DE10-Lite (Arduino Header) | เลขพิน FPGA (`10M50DAF484C7G`) | ชื่อพอร์ตใน VHDL |
| :--- | :--- | :--- | :--- |
| **WS** | `ARDUINO_IO[0]` | `PIN_AB5` | `MIC_I2S_WS` |
| **SCK** | `ARDUINO_IO[1]` | `PIN_AB6` | `MIC_I2S_SCK` |
| **SD** | `ARDUINO_IO[2]` | `PIN_AB7` | `MIC_I2S_SD` |
| **L/R** | `GND` | Board GND | เลือกช่องสัญญาณซ้าย (Left Channel) |
| **VDD / GND** | `3.3V / GND` | Board 3.3V / GND | ไฟเลี้ยง 3.3V และกราวด์ |

### 2. บอร์ด FPGA DE10-Lite $\rightarrow$ บอร์ด ESP32
| ช่อง DE10-Lite (Arduino Header) | เลขพิน FPGA (`10M50DAF484C7G`) | ชื่อพอร์ตใน VHDL | ขาของบอร์ด ESP32 |
| :--- | :--- | :--- | :--- |
| **ARDUINO_IO[7]** | `PIN_AA12` | `FPGA_UART_TX` | **GPIO 16 (RX2)** |
| **GND** | Board GND | - | **GND** *(ต่อกราวด์ร่วมกัน)* |

### 3. สวิตช์ควบคุมและไฟแสดงผลบนบอร์ด FPGA DE10-Lite
| อุปกรณ์บนบอร์ด | เลขพิน FPGA | หน้าที่การทำงาน |
| :--- | :--- | :--- |
| **KEY[0]** | `PIN_B8` | ปุ่ม Reset วงจร (Active Low) |
| **SW[0]** | `PIN_C10` | `0` = รับเสียงจากไมค์ INMP441, `1` = โหมดส่งคลื่นไซน์ทดสอบ **1.000 kHz** |
| **SW[2:1]** | `PIN_D12, PIN_C11` | ปรับระดับการขยายเสียง (Digital Gain): `00`=1x, `01`=2x, **`10`=4x (แนะนำ)**, `11`=8x |
| **SW[3]** | `PIN_C12` | `1` = เปิดระบบตัดเสียงรบกวนเบาๆ (Soft Noise Gate), `0` = ปิด |
| **LEDR[0]** | `PIN_A8` | สว่างเมื่อตรวจพบเสียงพูด (Hardware VAD Indicator) |
| **LEDR[1]** | `PIN_A9` | สว่างเมื่อสัญญาณเสียงดังแตะเพดาน (Clipping Indicator) |
| **LEDR[9:2]** | `PIN_B11..A10` | ไฟวิ่งแสดงระดับความดังเสียง 8 ระดับ (Real-Time VU Meter) |
| **ARDUINO_IO[8]** | `PIN_AB17` | สัญญาณคลื่นสี่เหลี่ยม **8.000 kHz** ($F_s / 2$) สำหรับตรวจสอบความถี่ด้วย Oscilloscope |

---

## วิธีติดตั้งและใช้งาน (Getting Started)

### ขั้นตอนที่ 1: อัปโหลดวงจรลงบอร์ด FPGA (Intel Quartus Prime)
1. เปิดโปรแกรม **Intel Quartus Prime Lite**
2. เปิดไฟล์โปรเจกต์ที่ `fpga_max10_bridge/quartus/fpga_mic_bridge.qpf`
3. กด **Compile Design** และใช้เครื่องมือ **Programmer** อัปโหลดไฟล์ `.sof` ลงบอร์ด DE10-Lite
4. ตั้งสวิตช์แนะนำเริ่มต้น: `SW[0]=0`, `SW[2:1]=10` (Gain 4x), `SW[3]=1` (เปิด Noise Gate)

### ขั้นตอนที่ 2: อัปโหลดเฟิร์มแวร์ลงบอร์ด ESP32 (Arduino IDE)
1. เปิดไฟล์ `fpga_max10_bridge/esp32_firmware/esp32_uart_from_fpga/esp32_uart_from_fpga.ino` ด้วย Arduino IDE
2. เลือกบอร์ด **ESP32 Dev Module** และพอร์ต USB ที่เชื่อมต่อ แล้วกด **Upload**
3. เมื่อได้รับข้อมูลจาก FPGA ไฟ LED บนบอร์ด ESP32 (GPIO 2) จะกะพริบต่อเนื่องทุกๆ ~0.5 วินาที

### ขั้นตอนที่ 3: รันโปรแกรม Smart Meeting Recorder (Python)
1. ติดตั้งไลบรารีที่จำเป็น (แนะนำให้ใช้ Python 3.9 ขึ้นไป):
   ```bash
   pip install numpy pyserial PyQt5 pyqtgraph
   ```
2. รันโปรแกรมหลัก:
   ```bash
   python main.py
   ```
3. ในหน้าต่างโปรแกรม:
   - เลือก **Serial Port** ของบอร์ด ESP32 แล้วกดปุ่ม **Start Listening**
   - ระบบจะตรวจจับเสียงพูดอัตโนมัติ (แสดงสถานะ `LISTENING` / `RECORDING` / `PAUSED`) พร้อมแสดงกราฟคลื่นเสียง, Spectrogram (0–8 kHz) และสรุปเวลาพูดแบบ Real-Time
   - เมื่อเสร็จสิ้นการประชุม ให้กด **Stop Listening** แล้วกด **Save Meeting (WAV & CSV)** เพื่อบันทึกไฟล์เสียงเฉพาะช่วงที่มีการพูด (`.wav`) และไฟล์สรุปรายงานสถิติการพูดแต่ละรอบ (`_report.csv`)

---

## การจำลองการทำงานของ VHDL (Simulation)
หากติดตั้ง **NVC (VHDL Simulator)** ไว้ในเครื่อง สามารถรัน Testbench เพื่อตรวจสอบการทำงานของวงจร FPGA ได้โดยตรง:
```bash
cd fpga_max10_bridge/sim
./run_sim.sh
```
