#include <ESP_I2S.h>
#include "FS.h"
#include "SD.h"
#include "SPI.h"

const uint32_t sample_rate = 16000;
const uint16_t sample_bits = 16;
const uint32_t recording_seconds = 2;
I2SClass i2s;

void write_wav_header(File &file, uint32_t data_size) {
  const uint32_t byte_rate = sample_rate * sample_bits / 8;
  const uint16_t block_align = sample_bits / 8;
  const uint32_t riff_size = 36 + data_size;
  const uint8_t header[] = {
      'R', 'I', 'F', 'F',
      (uint8_t)riff_size, (uint8_t)(riff_size >> 8), (uint8_t)(riff_size >> 16), (uint8_t)(riff_size >> 24),
      'W', 'A', 'V', 'E', 'f', 'm', 't', ' ',
      16, 0, 0, 0, 1, 0, 1, 0,
      (uint8_t)sample_rate, (uint8_t)(sample_rate >> 8), (uint8_t)(sample_rate >> 16), (uint8_t)(sample_rate >> 24),
      (uint8_t)byte_rate, (uint8_t)(byte_rate >> 8), (uint8_t)(byte_rate >> 16), (uint8_t)(byte_rate >> 24),
      (uint8_t)block_align, 0, sample_bits, 0,
      'd', 'a', 't', 'a',
      (uint8_t)data_size, (uint8_t)(data_size >> 8), (uint8_t)(data_size >> 16), (uint8_t)(data_size >> 24),
  };
  file.write(header, sizeof(header));
}

bool mount_sd() {
  SPI.begin(7, 8, 9, 21);
  if (SD.begin(21, SPI, 20000000)) {
    Serial.println("sd: mounted with CS GPIO21");
    return true;
  }

  SPI.begin(7, 8, 9, 3);
  if (SD.begin(3, SPI, 20000000)) {
    Serial.println("sd: mounted with CS GPIO3");
    return true;
  }

  Serial.println("sd: mount failed with CS GPIO21 and GPIO3");
  return false;
}

void probe_mic() {
  int16_t minimum = 32767;
  int16_t maximum = -32768;
  const uint32_t sample_count = sample_rate / 2;

  for (uint32_t sample_index = 0; sample_index < sample_count; sample_index++) {
    while (!i2s.available()) {
      delay(1);
    }
    const int16_t sample = i2s.read();
    minimum = min(minimum, sample);
    maximum = max(maximum, sample);
  }

  Serial.printf("mic: 0.5 second probe min=%d max=%d\n", minimum, maximum);
}

String next_test_path() {
  String path = "/clippy-test.wav";
  for (uint8_t index = 2; SD.exists(path); index++) {
    path = "/clippy-test-" + String(index) + ".wav";
  }
  return path;
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("clippy: testing microphone and microSD");

  i2s.setPinsPdmRx(42, 41);
  if (!i2s.begin(I2S_MODE_PDM_RX, sample_rate, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("mic: initialization failed");
    return;
  }
  Serial.println("mic: initialized at 16 kHz mono");
  probe_mic();

  if (!mount_sd()) {
    return;
  }

  const String path = next_test_path();
  File file = SD.open(path, FILE_WRITE);
  if (!file) {
    Serial.println("sd: file creation failed");
    return;
  }

  const uint32_t data_size = sample_rate * recording_seconds * 2;
  write_wav_header(file, data_size);
  Serial.printf("mic: recording %lu seconds to %s\n", recording_seconds, path.c_str());

  for (uint32_t sample_index = 0; sample_index < sample_rate * recording_seconds; sample_index++) {
    while (!i2s.available()) {
      delay(1);
    }
    const int16_t sample = i2s.read();
    file.write((uint8_t *)&sample, sizeof(sample));
  }

  file.close();
  file = SD.open(path, FILE_READ);
  Serial.printf("sd: wrote %s (%lu bytes)\n", path.c_str(), file ? file.size() : 0UL);
  if (file) {
    file.close();
  }
  Serial.println("clippy: peripheral test complete");
}

void loop() {
  delay(1000);
}
