#include <ESP_I2S.h>

const uint32_t sample_rate = 16000;
I2SClass i2s;

void setup() {
  Serial.begin(115200);
  delay(500);
  i2s.setPinsPdmRx(42, 41);
  if (!i2s.begin(I2S_MODE_PDM_RX, sample_rate, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("mic: initialization failed");
    while (true) {
      delay(1000);
    }
  }
  Serial.println("mic: continuous probe ready");
}

void loop() {
  int32_t total_absolute = 0;
  int16_t minimum = 32767;
  int16_t maximum = -32768;

  for (uint16_t index = 0; index < 1600; index++) {
    while (!i2s.available()) {
      delay(1);
    }
    const int16_t sample = i2s.read();
    minimum = min(minimum, sample);
    maximum = max(maximum, sample);
    total_absolute += abs(sample);
  }

  Serial.printf(
      "mic: min=%d max=%d average-absolute=%ld\n",
      minimum,
      maximum,
      total_absolute / 1600);
}
