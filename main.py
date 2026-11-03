import sys
import time
import wave
import csv
from collections import deque
import numpy as np
import serial
import serial.tools.list_ports

from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QComboBox, QGroupBox, QFileDialog, QMessageBox
)
from PyQt5.QtCore import QThread, QTimer, Qt
import pyqtgraph as pg

# --- การตั้งค่าสัญญาณและเกณฑ์ VAD ---
SAMPLE_RATE = 16000     # 16 kHz
FRAME_SIZE = 512        # 32 ms ต่อเฟรม
BYTES_PER_FRAME = FRAME_SIZE * 2
BAUD_RATE = 1000000     # 1 Mbps (ป้องกันปัญหา Baud Rate 921600 เพี้ยนบนชิป USB-Serial CH9102)
SYNC_HEADER = b'\xaa\x55\xaa\x55'
AUDIO_GAIN = 1.5        # ลด Gain ซอฟต์แวร์ลงเพราะ FPGA ขยายสัญญาณมาให้แล้ว (ป้องกันเสียงแตก Clipping ±32767)

# ปรับ Threshold ให้เหมาะกับสัญญาณที่สะอาดแล้ว (หลังแก้ปัญหา Static Noise จากไบต์เลื่อน)
ENERGY_THRESH = 0.004   # เกณฑ์พลังงาน STE ขั้นต่ำสำหรับเสียงพูด
ZCR_THRESH = 0.15       # เกณฑ์การตัดศูนย์ ZCR
HANGOVER_TIME_SEC = 1.0 # ช่วงหน่วงก่อนตัดเป็นเงียบ
HANGOVER_FRAMES = int(HANGOVER_TIME_SEC * SAMPLE_RATE / FRAME_SIZE)


# ==========================================
# Worker Thread: รับข้อมูลและประมวลผล DSP/VAD
# ==========================================
class AudioWorker(QThread):
    def __init__(self, port, baud_rate=BAUD_RATE):
        super().__init__()
        self.port = port
        self.baud_rate = baud_rate
        self.is_running = True
        self.dc_offset = None
        self.noise_energy_est = None
        self.prev_tail = np.zeros(4, dtype=np.float32)
        self.sync_locked = False
        
        # Audio Buffer (Thread-Safe Queues)
        self.raw_audio_queue = deque(maxlen=SAMPLE_RATE * 2) # เก็บคลื่นเสียง 2 วินาทีล่าสุด
        self.spec_history = deque(maxlen=60)                 # เก็บคอลัมน์ความถี่ 60 เฟรม
        self.recorded_pcm = []
        self.pre_buffer = deque(maxlen=int(0.5 * SAMPLE_RATE / FRAME_SIZE)) # Buffer 500 ms กันหัวคำขาด

        # สถานะและสถิติ
        self.state = "Listening"
        self.silence_counter = 0
        self.start_meeting_time = 0
        self.speech_start_time = 0
        self.total_speech_duration = 0.0
        self.speech_turn_count = 0
        self.events_log = []

    def run(self):
        try:
            ser = serial.Serial(self.port, self.baud_rate, timeout=0.1)
            time.sleep(0.1)
            ser.reset_input_buffer()
        except Exception as e:
            print(f"Error opening port: {e}")
            return

        self.start_meeting_time = time.time()
        byte_buffer = bytearray()
        packet_size = len(SYNC_HEADER) + BYTES_PER_FRAME

        while self.is_running:
            raw_data = ser.read(ser.in_waiting or 1)
            if raw_data:
                byte_buffer.extend(raw_data)

            while len(byte_buffer) >= packet_size:
                header_idx = byte_buffer.find(SYNC_HEADER)

                if header_idx != -1:
                    self.sync_locked = True
                    # พบ Sync Header: ทิ้งไบต์ขยะก่อนหน้า Header เพื่อล็อกตำแหน่ง LSB/MSB ให้ตรงเสมอ
                    if header_idx > 0:
                        del byte_buffer[:header_idx]
                    if len(byte_buffer) < packet_size:
                        break

                    frame_bytes = bytes(byte_buffer[len(SYNC_HEADER):packet_size])
                    del byte_buffer[:packet_size]
                    frame = np.frombuffer(frame_bytes, dtype='<i2')
                    self.process_dsp_vad(frame)
                elif self.sync_locked:
                    # เคยล็อก Sync Header ได้แล้ว แต่รอบนี้ Header อยู่คาบเกี่ยวท้าย Buffer:
                    # เก็บ 3 ไบต์สุดท้ายไว้รอประกอบกับไบต์ถัดไป (ห้ามตัด 1024 ไบต์สุ่ม เพราะจะทำให้ LSB/MSB สลับกัน)
                    if len(byte_buffer) > 3:
                        del byte_buffer[:-3]
                    break
                else:
                    # รอให้มีข้อมูลอย่างน้อย 2 เฟรมก่อนตัดสินใจว่าไม่มี Sync Header จริงๆ
                    if len(byte_buffer) < packet_size * 2:
                        break
                    # กรณีใช้โค้ด ESP32 เดิมที่ยังไม่มี Sync Header: ตรวจสอบและแก้ปัญหาไบต์เลื่อน (MSB/LSB Swap) อัตโนมัติ
                    if len(byte_buffer) >= BYTES_PER_FRAME + 2:
                        s0 = np.frombuffer(byte_buffer[:BYTES_PER_FRAME], dtype='<i2').astype(np.float32)
                        s1 = np.frombuffer(byte_buffer[1:1 + BYTES_PER_FRAME], dtype='<i2').astype(np.float32)
                        if np.mean(np.abs(np.diff(s1))) * 1.5 < np.mean(np.abs(np.diff(s0))):
                            del byte_buffer[:1]

                    frame_bytes = bytes(byte_buffer[:BYTES_PER_FRAME])
                    del byte_buffer[:BYTES_PER_FRAME]
                    frame = np.frombuffer(frame_bytes, dtype='<i2')
                    self.process_dsp_vad(frame)

        # หากกดหยุดขณะกำลัง Recording ให้สรุปเวลาพูดของรอบสุดท้ายด้วย
        if self.state == "Recording":
            duration = max(0.0, time.time() - self.speech_start_time)
            self.total_speech_duration += duration
            self.events_log.append({"turn": self.speech_turn_count, "duration": round(duration, 2)})
            self.state = "Paused"

        ser.close()

    def process_dsp_vad(self, frame):
        # 1. กรอง Spike / Bit-Glitch จากสายสัญญาณ I2S (3-Tap Median + Clamped Despiker)
        frame_float = frame.astype(np.float32)
        ext = np.concatenate([self.prev_tail[-2:], frame_float])
        med = np.sort(np.vstack([ext[:-2], ext[1:-1], ext[2:]]), axis=0)[1]
        # แทนที่จุดที่เกิด Clipping เต็มสเกล (±32767) หรือ Spike กระโดดเกินจริงด้วยค่า Median
        spike_mask = (np.abs(frame_float) >= 32760.0) | (np.abs(frame_float - med) > 3500.0)
        frame_despiked = np.where(spike_mask, med, frame_float)

        # 2. กรองความถี่สูงเกินย่านเสียงพูด (>3.5 kHz Low-Pass Filter แบบไร้รอยต่อระหว่างเฟรม)
        ext_lpf = np.concatenate([self.prev_tail[-3:], frame_despiked])
        self.prev_tail = frame_despiked[-4:].copy()
        kernel = np.array([0.15, 0.35, 0.35, 0.15], dtype=np.float32)
        frame_filtered = np.convolve(ext_lpf, kernel, mode='valid')

        # 3. หักล้าง DC Offset แบบต่อเนื่อง (ใช้ Median เพื่อไม่ให้ Spike ดึงกราฟเบี้ยว) และขยายสัญญาณ
        curr_mean = float(np.median(frame_filtered))
        if self.dc_offset is None:
            self.dc_offset = curr_mean
            prev_dc = curr_mean
        else:
            prev_dc = self.dc_offset
            self.dc_offset = 0.95 * self.dc_offset + 0.05 * curr_mean

        dc_curve = np.linspace(prev_dc, self.dc_offset, len(frame_filtered), dtype=np.float32)
        frame_clean = (frame_filtered - dc_curve) * AUDIO_GAIN
        frame_clean = np.clip(frame_clean, -32768.0, 32767.0)
        pcm_clean = frame_clean.astype(np.int16)
        norm_frame = frame_clean / 32768.0

        # 4. คำนวณ STE และ Adaptive Noise Threshold (ป้องกัน VAD ค้างที่ Recording ตลอดเวลาเมื่อมี Noise พื้นหลัง)
        ste = float(np.mean(norm_frame ** 2))  # Short-Time Energy
        zcr = float(np.mean(np.abs(np.diff(np.sign(norm_frame)))) / 2.0)  # Zero-Crossing Rate

        if self.noise_energy_est is None:
            self.noise_energy_est = ste
        elif ste < self.noise_energy_est * 2.0:
            self.noise_energy_est = 0.95 * self.noise_energy_est + 0.05 * ste
        else:
            self.noise_energy_est = 0.995 * self.noise_energy_est + 0.005 * ste

        dynamic_thresh = max(ENERGY_THRESH, self.noise_energy_est * 3.0)
        is_speech = (ste > dynamic_thresh) and (zcr < 0.42)
        now = time.time()

        # 3. State Machine สำหรับบันทึกเสียง (บันทึกสัญญาณ pcm_clean ที่ตัด DC Offset และขยายเสียงแล้ว)
        if self.state == "Listening":
            self.pre_buffer.append(pcm_clean)
            if is_speech:
                self.state = "Recording"
                self.speech_turn_count += 1
                self.speech_start_time = now
                while self.pre_buffer:
                    self.recorded_pcm.extend(self.pre_buffer.popleft())
                self.recorded_pcm.extend(pcm_clean)
                self.silence_counter = 0

        elif self.state == "Recording":
            self.recorded_pcm.extend(pcm_clean)
            if is_speech:
                self.silence_counter = 0
            else:
                self.silence_counter += 1
                if self.silence_counter > HANGOVER_FRAMES:
                    self.state = "Paused"
                    duration = max(0.0, now - self.speech_start_time - HANGOVER_TIME_SEC)
                    self.total_speech_duration += duration
                    self.events_log.append({"turn": self.speech_turn_count, "duration": round(duration, 2)})

        elif self.state == "Paused":
            self.pre_buffer.append(pcm_clean)
            if is_speech:
                self.state = "Recording"
                self.speech_turn_count += 1
                self.speech_start_time = now
                while self.pre_buffer:
                    self.recorded_pcm.extend(self.pre_buffer.popleft())
                self.recorded_pcm.extend(pcm_clean)
                self.silence_counter = 0

        # 4. บันทึกลงคิวสำหรับการแสดงผล
        self.raw_audio_queue.extend(frame_clean)
        
        # คำนวณ Spectrogram (dB) จากเฟรมที่ถูก Normalize แล้ว
        windowed = norm_frame * np.hanning(len(norm_frame))
        mag = np.abs(np.fft.rfft(windowed)) / len(norm_frame)
        mag_db = 20 * np.log10(mag + 1e-5)  # ขอบเขตประมาณ -100 ถึง 0 dB
        self.spec_history.append(mag_db)

    def get_realtime_metrics(self):
        now = time.time()
        active_speech = 0.0
        if self.state == "Recording":
            active_speech = max(0.0, now - self.speech_start_time)

        curr_speaking_time = self.total_speech_duration + active_speech
        total_time = max(0.0, now - self.start_meeting_time) if self.start_meeting_time else 0.0
        curr_silence_time = max(0.0, total_time - curr_speaking_time)

        return self.state, curr_speaking_time, curr_silence_time, self.speech_turn_count

    def stop(self):
        self.is_running = False
        self.wait()


# ==========================================
# Main GUI: อัปเดตด้วย QTimer (แก้ปัญหาค้าง)[span_15](start_span)[span_15](end_span)
# ==========================================
class SmartMeetingRecorderGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Smart Meeting Recorder - DSP Group 8")
        self.resize(1000, 750)
        self.worker = None

        self.init_ui()

        # ใช้ Timer รีเฟรชหน้าจอที่ 25 FPS (ทุก 40 ms) ป้องกัน UI ค้าง
        self.ui_timer = QTimer()
        self.ui_timer.timeout.connect(self.update_plots)

    def init_ui(self):
        main_layout = QVBoxLayout()

        # แถบควบคุม Serial
        conn_group = QGroupBox("Device Connection")
        conn_layout = QHBoxLayout()

        self.port_combo = QComboBox()
        self.refresh_ports()
        conn_layout.addWidget(QLabel("Serial Port:"))
        conn_layout.addWidget(self.port_combo)

        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh_ports)
        conn_layout.addWidget(self.refresh_btn)

        self.start_btn = QPushButton("Start Listening")
        self.start_btn.setStyleSheet("background-color: #2e7d32; color: white; font-weight: bold;")
        self.start_btn.clicked.connect(self.toggle_session)
        conn_layout.addWidget(self.start_btn)

        self.save_btn = QPushButton("Save Meeting (WAV & CSV)")  # ฟีเจอร์ที่ 4[span_16](start_span)[span_16](end_span)
        self.save_btn.setStyleSheet("background-color: #1565c0; color: white; font-weight: bold;")
        self.save_btn.clicked.connect(self.save_meeting_data)
        self.save_btn.setEnabled(False)
        conn_layout.addWidget(self.save_btn)

        conn_group.setLayout(conn_layout)
        main_layout.addWidget(conn_group)

        # ฟีเจอร์ที่ 1: สถานะการบันทึก[span_17](start_span)[span_17](end_span)
        status_group = QGroupBox("System Status")
        status_layout = QHBoxLayout()
        self.status_label = QLabel("DISCONNECTED")
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setStyleSheet("font-size: 20px; font-weight: bold; color: gray; padding: 6px;")
        status_layout.addWidget(self.status_label)
        status_group.setLayout(status_layout)
        main_layout.addWidget(status_group)

        # ฟีเจอร์ที่ 2: Live Waveform และ Spectrogram[span_18](start_span)[span_18](end_span)
        pg.setConfigOptions(antialias=False)  # ปิด antialias เพื่อความลื่นไหล
        self.plot_layout = pg.GraphicsLayoutWidget()

        # กราฟคลื่นเสียง
        self.wave_plot = self.plot_layout.addPlot(title="Live Audio Waveform (Time Domain)")
        self.wave_plot.setYRange(-30000, 30000)
        self.wave_plot.setXRange(0, 1000)  # แสดงผล 1000 จุดหลัง Downsample
        self.wave_plot.showGrid(x=True, y=True, alpha=0.3)
        self.wave_curve = self.wave_plot.plot(pen=pg.mkPen('#00e5ff', width=1))

        self.plot_layout.nextRow()

        # กราฟ Spectrogram (0-8 kHz)[span_19](start_span)[span_19](end_span)[span_20](start_span)[span_20](end_span)
        self.spec_plot = self.plot_layout.addPlot(title="Live Spectrogram (0-8 kHz)")
        self.spec_plot.setLabel('left', 'Frequency Bin')
        self.spec_plot.setLabel('bottom', 'Time Frame')
        self.spec_image = pg.ImageItem()
        self.spec_plot.addItem(self.spec_image)

        colormap = pg.colormap.get('viridis')
        self.spec_image.setColorMap(colormap)

        main_layout.addWidget(self.plot_layout)

        # ฟีเจอร์ที่ 3: สรุปเวลาการพูดแบบสด[span_21](start_span)[span_21](end_span)
        report_group = QGroupBox("Speaking Time Report (Real-Time)")
        report_layout = QHBoxLayout()

        self.speak_time_lbl = QLabel("Speaking Time: 0.0 s")
        self.speak_time_lbl.setStyleSheet("font-size: 14px; font-weight: bold; color: #2e7d32;")
        report_layout.addWidget(self.speak_time_lbl)

        self.silence_time_lbl = QLabel("Silence Time: 0.0 s")
        self.silence_time_lbl.setStyleSheet("font-size: 14px; font-weight: bold; color: #c62828;")
        report_layout.addWidget(self.silence_time_lbl)

        self.turns_lbl = QLabel("Speaking Turns: 0")
        self.turns_lbl.setStyleSheet("font-size: 14px; font-weight: bold; color: #0277bd;")
        report_layout.addWidget(self.turns_lbl)

        report_group.setLayout(report_layout)
        main_layout.addWidget(report_group)

        container = QWidget()
        container.setLayout(main_layout)
        self.setCentralWidget(container)

    def refresh_ports(self):
        self.port_combo.clear()
        ports = serial.tools.list_ports.comports()
        for p in ports:
            self.port_combo.addItem(p.device)

    def toggle_session(self):
        if self.worker is None or not self.worker.isRunning():
            port = self.port_combo.currentText()
            if not port:
                QMessageBox.warning(self, "Warning", "กรุณาเลือก Serial Port ก่อนเริ่มทำงาน")
                return

            self.worker = AudioWorker(port=port)
            self.worker.start()
            self.ui_timer.start(40)  # รีเฟรชทุก 40 ms (25 FPS)

            self.start_btn.setText("Stop Listening")
            self.start_btn.setStyleSheet("background-color: #c62828; color: white; font-weight: bold;")
            self.save_btn.setEnabled(False)
            self.port_combo.setEnabled(False)
            self.refresh_btn.setEnabled(False)
        else:
            self.ui_timer.stop()
            self.worker.stop()

            self.start_btn.setText("Start Listening")
            self.start_btn.setStyleSheet("background-color: #2e7d32; color: white; font-weight: bold;")
            self.save_btn.setEnabled(True)
            self.port_combo.setEnabled(True)
            self.refresh_btn.setEnabled(True)
            self.status_label.setText("STOPPED")
            self.status_label.setStyleSheet("font-size: 20px; font-weight: bold; color: gray;")

    def update_plots(self):
        if not self.worker:
            return

        # 1. ดึงสถิติและอัปเดตป้ายสถานะ[span_22](start_span)[span_22](end_span)
        state, speak_time, silence_time, turns = self.worker.get_realtime_metrics()
        self.speak_time_lbl.setText(f"Speaking Time: {speak_time:.1f} s")
        self.silence_time_lbl.setText(f"Silence Time: {silence_time:.1f} s")
        self.turns_lbl.setText(f"Speaking Turns: {turns}")

        if state == "Recording":
            self.status_label.setText("● RECORDING (กำลังบันทึกเสียง)")
            self.status_label.setStyleSheet("font-size: 20px; font-weight: bold; color: #00e676; background-color: #1b5e20; border-radius: 5px;")
        elif state == "Listening":
            self.status_label.setText("🎧 LISTENING (กำลังรอตรวจจับเสียง)")
            self.status_label.setStyleSheet("font-size: 20px; font-weight: bold; color: #ffeb3b; background-color: #f57f17; border-radius: 5px;")
        elif state == "Paused":
            self.status_label.setText("⏸ PAUSED (ช่วงเงียบ - พักบันทึกชั่วคราว)")
            self.status_label.setStyleSheet("font-size: 20px; font-weight: bold; color: #ff9800; background-color: #e65100; border-radius: 5px;")

        # 2. อัปเดต Waveform แบบ Downsample (นำ 32,000 จุด มาเฉลี่ยแสดงผล 1,000 จุด เพื่อความลื่นไหล)[span_23](start_span)[span_23](end_span)
        if len(self.worker.raw_audio_queue) > 1000:
            raw_arr = np.array(self.worker.raw_audio_queue)
            downsampled = raw_arr[::len(raw_arr)//1000][:1000]
            self.wave_curve.setData(downsampled)

        # 3. อัปเดต Spectrogram (สเกล -60 dB ถึง -10 dB ไม่ให้สีล้นเป็นสีเหลือง)[span_24](start_span)[span_24](end_span)[span_25](start_span)[span_25](end_span)
        if len(self.worker.spec_history) > 0:
            spec_matrix = np.array(self.worker.spec_history).T
            self.spec_image.setImage(spec_matrix, levels=[-60, -10])

    def save_meeting_data(self):
        # ฟีเจอร์ที่ 4: บันทึก WAV และรายงาน CSV[span_26](start_span)[span_26](end_span)
        if not self.worker or not self.worker.recorded_pcm:
            QMessageBox.information(self, "Notice", "ไม่พบข้อมูลเสียงที่บันทึกไว้")
            return

        wav_path, _ = QFileDialog.getSaveFileName(self, "Save Meeting Audio", "meeting_record.wav", "WAV Audio (*.wav)")
        if wav_path:
            audio_float = np.array(self.worker.recorded_pcm, dtype=np.float32)
            audio_float = audio_float - np.mean(audio_float)
            peak = np.max(np.abs(audio_float)) if len(audio_float) > 0 else 0.0
            if peak > 100.0:
                norm_gain = min(4.0, 26000.0 / peak)
                audio_float = np.clip(audio_float * norm_gain, -32768.0, 32767.0)
            audio_array = audio_float.astype(np.int16)

            with wave.open(wav_path, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(SAMPLE_RATE)
                wf.writeframes(audio_array.tobytes())

            csv_path = wav_path.rsplit('.', 1)[0] + "_report.csv"
            with open(csv_path, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(["Meeting Metric", "Value"])
                writer.writerow(["Total Speaking Time (s)", f"{self.worker.total_speech_duration:.2f}"])
                writer.writerow(["Total Speaking Turns", self.worker.speech_turn_count])
                writer.writerow([])
                writer.writerow(["Turn", "Speaking Duration (s)"])
                for ev in self.worker.events_log:
                    writer.writerow([ev["turn"], ev["duration"]])

            QMessageBox.information(self, "Success", f"บันทึกไฟล์เรียบร้อยแล้ว:\n- {wav_path}\n- {csv_path}")


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = SmartMeetingRecorderGUI()
    window.show()
    sys.exit(app.exec_())
